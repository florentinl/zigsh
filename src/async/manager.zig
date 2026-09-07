const std = @import("std");
pub const protocol = @import("protocol.zig");
const runtime = @import("runtime.zig");
const zle_events = @import("../zle_events.zig");
const zle_hooks = @import("../zle_hooks.zig");
const unistd = @cImport({
    @cInclude("unistd.h");
});

pub const CompletionCallback = *const fn (*const protocol.Frame) zle_hooks.Effects;

pub const Job = struct {
    kind: protocol.Job,
    callback: CompletionCallback,
    registered: bool = false,

    pub fn init(kind: protocol.Job, callback: CompletionCallback) Job {
        return .{ .kind = kind, .callback = callback };
    }

    pub fn register(self: *Job) RegisterError!void {
        if (self.registered) return;
        try registerJob(self.kind, self.callback);
        self.registered = true;
    }

    pub fn unregister(self: *Job) void {
        if (!self.registered) return;
        unregisterJob(self.kind, self.callback);
        self.registered = false;
    }

    pub fn epoch(self: Job) u64 {
        return slotFor(self.kind).epoch;
    }

    pub fn busy(self: Job) bool {
        return slotFor(self.kind).active_generation != null;
    }

    pub fn cancelAndRestart(self: Job) bool {
        recoverWorker(self.kind) catch return false;
        return true;
    }

    /// May restart a failed worker. Capture epoch() after successful submission.
    pub fn submit(
        self: Job,
        generation: u64,
        payload: []const u8,
        deadline_ns: u64,
    ) SubmitError!void {
        try submitJob(self.kind, generation, payload, deadline_ns);
    }

    /// Blocking compatibility helper for non-ZLE callers only.
    pub fn submitAndWait(
        self: Job,
        generation: u64,
        payload: []const u8,
        deadline_ns: u64,
    ) !?protocol.Frame {
        return submitJobAndWait(self.kind, generation, payload, deadline_ns);
    }
};

const RegisterError = runtime.StartError || error{
    AlreadyRegistered,
    CallbackAlreadyRegistered,
    CapacityExceeded,
    WatchFailed,
};

const SubmitError = runtime.SubmitError || error{
    Busy,
    NotRegistered,
    RestartFailed,
};

const Slot = struct {
    client: runtime.Client = .{},
    callback: ?CompletionCallback = null,
    active_generation: ?u64 = null,
    epoch: u64 = 0,
};

const allocator = std.heap.c_allocator;

var slots = std.EnumArray(protocol.Job, Slot).initFill(.{});
var response_subscriptions = std.EnumArray(protocol.Job, zle_events.Subscription).initFill(
    zle_events.Subscription.init(onReadable),
);

pub fn setup() c_int {
    return 0;
}

pub fn cleanup() void {
    var iterator = slots.iterator();
    while (iterator.next()) |entry| resetSlot(entry.key, entry.value);
    runtime.cleanup();
}

pub fn deadlineAfter(duration_ns: u64) u64 {
    return runtime.monotonicNanoseconds() +| duration_ns;
}

fn registerJob(kind: protocol.Job, callback: CompletionCallback) RegisterError!void {
    const slot = slotFor(kind);
    if (slot.callback != null) return error.AlreadyRegistered;
    slot.callback = callback;
    errdefer slot.callback = null;
    try slot.client.start();
    errdefer slot.client.stop();
    try responseSubscriptionFor(kind).register(slot.client.responseFd().?);
    advanceEpoch(slot);
}

fn unregisterJob(kind: protocol.Job, callback: CompletionCallback) void {
    const slot = slotFor(kind);
    if (slot.callback != callback) return;
    resetSlot(kind, slot);
}

fn resetSlot(kind: protocol.Job, slot: *Slot) void {
    responseSubscriptionFor(kind).unregister();
    slot.client.stop();
    slot.callback = null;
    slot.active_generation = null;
}

fn submitJob(
    kind: protocol.Job,
    generation: u64,
    payload: []const u8,
    deadline_ns: u64,
) SubmitError!void {
    const slot = slotFor(kind);
    if (slot.callback == null) return error.NotRegistered;
    if (slot.active_generation != null) return error.Busy;
    if (slot.client.responseFd() == null) recoverWorker(kind) catch return error.RestartFailed;
    slot.client.submit(kind, generation, payload, deadline_ns) catch |err| {
        recoverWorker(kind) catch {};
        return err;
    };
    slot.active_generation = generation;
}

fn submitJobAndWait(
    kind: protocol.Job,
    generation: u64,
    payload: []const u8,
    deadline_ns: u64,
) !?protocol.Frame {
    try submitJob(kind, generation, payload, deadline_ns);
    const slot = slotFor(kind);
    errdefer recoverWorker(kind) catch {};
    while (try slot.client.waitUntilReadable(deadline_ns)) {
        var frame = (try receive(kind)) orelse continue;
        if (frame.header.generation == generation) return frame;
        _ = dispatch(kind, &frame);
        frame.deinit(allocator);
    }
    recoverWorker(kind) catch {};
    return null;
}

fn recoverWorker(kind: protocol.Job) !void {
    const slot = slotFor(kind);
    if (slot.callback == null) return error.NotRegistered;
    responseSubscriptionFor(kind).unregister();
    slot.active_generation = null;
    // Zsh suppresses POLLIN after HUP when the replacement watch has the same
    // fd number. Keep that number occupied until the new socket is allocated.
    const previous_fd = detachFd(&slot.client);
    defer if (previous_fd >= 0) {
        _ = unistd.close(previous_fd);
    };
    advanceEpoch(slot);
    slot.client.restart() catch return error.RestartFailed;
    responseSubscriptionFor(kind).register(slot.client.responseFd().?) catch {
        slot.client.stop();
        return error.RestartFailed;
    };
}

fn advanceEpoch(slot: *Slot) void {
    slot.epoch +%= 1;
    if (slot.epoch == 0) slot.epoch = 1;
}

fn onReadable() zle_hooks.Effects {
    var effects: zle_hooks.Effects = .{};
    var iterator = slots.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.callback == null) continue;
        // One bounded receive turn per slot. Partial frames/credits leave the
        // descriptor readable (or the worker sends the next credit/response).
        var frame = receive(entry.key) catch |err| {
            effects.merge(failWorker(entry.key, @errorName(err)));
            continue;
        } orelse continue;
        effects.merge(dispatch(entry.key, &frame));
        frame.deinit(allocator);
    }
    return effects;
}

fn receive(kind: protocol.Job) !?protocol.Frame {
    const slot = slotFor(kind);
    var frame = try slot.client.receive(allocator) orelse return null;
    errdefer frame.deinit(allocator);
    if (frame.header.job != kind) return error.UnexpectedJob;
    if (frame.header.generation != slot.active_generation) return error.UnexpectedGeneration;
    slot.active_generation = null;
    return frame;
}

fn failWorker(kind: protocol.Job, message: []const u8) zle_hooks.Effects {
    const slot = slotFor(kind);
    const generation = slot.active_generation;
    responseSubscriptionFor(kind).unregister();
    // Hold through the callback too: it may itself submit or re-register a job.
    const failed_fd = detachFd(&slot.client);
    defer if (failed_fd >= 0) {
        _ = unistd.close(failed_fd);
    };
    slot.client.stop();
    slot.active_generation = null;
    // Complete against the old epoch, so consumers accept the failure. A
    // callback may submit immediately; submitJob then restarts before queuing.
    const effects = if (generation) |active| dispatchFailure(kind, active, message) else zle_hooks.Effects{};
    if (slot.callback != null and slot.client.responseFd() == null) recoverWorker(kind) catch {};
    return effects;
}

fn detachFd(client: *runtime.Client) c_int {
    const fd = client.fd;
    client.fd = -1;
    return fd;
}

fn dispatchFailure(kind: protocol.Job, generation: u64, message: []const u8) zle_hooks.Effects {
    const frame = protocol.Frame{
        .header = .{
            .message = .response,
            .job = kind,
            .status = .failed,
            .generation = generation,
            .payload_length = @intCast(message.len),
        },
        .payload = @constCast(message),
    };
    return dispatch(kind, &frame);
}

fn dispatch(kind: protocol.Job, frame: *const protocol.Frame) zle_hooks.Effects {
    return if (slotFor(kind).callback) |callback| callback(frame) else .{};
}

fn slotFor(kind: protocol.Job) *Slot {
    return slots.getPtr(kind);
}

fn responseSubscriptionFor(kind: protocol.Job) *zle_events.Subscription {
    return response_subscriptions.getPtr(kind);
}

var test_calls: usize = 0;

fn testCallback(frame: *const protocol.Frame) zle_hooks.Effects {
    if (frame.header.job == .ping) test_calls += 1;
    return .{ .regions_changed = true };
}

test "job handles are enum-keyed and dispatch only their callback" {
    const slot = slotFor(.ping);
    slot.callback = testCallback;
    test_calls = 0;
    defer slot.callback = null;

    const frame = protocol.Frame{
        .header = .{
            .message = .response,
            .job = .ping,
            .status = .ok,
            .generation = 1,
            .payload_length = 0,
        },
        .payload = &.{},
    };
    const effects = dispatch(.ping, &frame);

    try std.testing.expectEqual(@as(usize, 1), test_calls);
    try std.testing.expect(effects.regions_changed);
    try std.testing.expect(slotFor(.line_analysis).callback == null);
}

test "job handles expose in-flight state per key" {
    const slot = slotFor(.ping);
    slot.callback = testCallback;
    slot.active_generation = 7;
    defer {
        slot.callback = null;
        slot.active_generation = null;
    }

    const job = Job.init(.ping, testCallback);
    try std.testing.expect(job.busy());
    try std.testing.expect(!Job.init(.line_analysis, testCallback).busy());
}

const TestCompletion = struct {
    calls: usize = 0,
    generation: u64 = 0,
    status: protocol.Status = .ok,
    epoch: u64 = 0,
    busy: bool = false,
    submit_next: bool = false,
    submitted: bool = false,
    submitted_epoch: u64 = 0,
};
var test_completion: TestCompletion = .{};

fn testCompletion(frame: *const protocol.Frame) zle_hooks.Effects {
    test_completion.calls += 1;
    test_completion.generation = frame.header.generation;
    test_completion.status = frame.header.status;
    const job = Job.init(.ping, testCompletion);
    test_completion.epoch = job.epoch();
    test_completion.busy = job.busy();
    if (test_completion.submit_next) {
        test_completion.submit_next = false;
        job.submit(frame.header.generation + 1, "next", 0) catch return .{};
        test_completion.submitted = true;
        test_completion.submitted_epoch = job.epoch();
    }
    return .{ .regions_changed = true };
}

fn testDispatchUntilCompletion() !void {
    const before = test_completion.calls;
    const deadline = deadlineAfter(std.time.ns_per_s);
    while (test_completion.calls == before and try slotFor(.ping).client.waitUntilReadable(deadline)) {
        _ = onReadable();
    }
    try std.testing.expectEqual(before + 1, test_completion.calls);
}

test "manager EOF completes the failed generation at its epoch and recovers" {
    const c = @cImport({
        @cInclude("signal.h");
    });
    test_completion = .{};
    var job = Job.init(.ping, testCompletion);
    defer cleanup();
    try job.register();
    defer job.unregister();
    const epoch = job.epoch();
    const pid = slotFor(.ping).client.worker_pid;
    try std.testing.expectEqual(@as(c_int, 0), c.kill(pid, c.SIGSTOP));
    try job.submit(17, "cannot-complete", 0);
    try std.testing.expect(job.busy());
    try std.testing.expectEqual(@as(c_int, 0), c.kill(pid, c.SIGKILL));
    try testDispatchUntilCompletion();
    try std.testing.expectEqual(protocol.Status.failed, test_completion.status);
    try std.testing.expectEqual(@as(u64, 17), test_completion.generation);
    try std.testing.expectEqual(epoch, test_completion.epoch);
    try std.testing.expect(!test_completion.busy);
    try std.testing.expect(!job.busy());
    try std.testing.expect(job.epoch() != epoch);
    try job.submit(18, "recovered", 0);
    try testDispatchUntilCompletion();
    try std.testing.expectEqual(protocol.Status.ok, test_completion.status);
    try std.testing.expectEqual(@as(u64, 18), test_completion.generation);
}

test "manager failure callback can immediately queue the next generation" {
    test_completion = .{ .submit_next = true };
    var job = Job.init(.ping, testCompletion);
    defer cleanup();
    try job.register();
    defer job.unregister();
    try job.submit(27, "cancelled", 0);
    const epoch = job.epoch();
    const previous_fd = slotFor(.ping).client.fd;
    _ = failWorker(.ping, "WorkerClosed");
    try std.testing.expectEqual(protocol.Status.failed, test_completion.status);
    try std.testing.expectEqual(epoch, test_completion.epoch);
    try std.testing.expect(test_completion.submitted);
    const new_epoch = job.epoch();
    try std.testing.expect(new_epoch != epoch);
    try std.testing.expectEqual(new_epoch, test_completion.submitted_epoch);
    try std.testing.expect(slotFor(.ping).client.fd != previous_fd);
    try std.testing.expect(job.busy());
    try testDispatchUntilCompletion();
    try std.testing.expectEqual(protocol.Status.ok, test_completion.status);
    try std.testing.expectEqual(@as(u64, 28), test_completion.generation);
    try std.testing.expectEqual(new_epoch, test_completion.epoch);
    try std.testing.expect(!job.busy());
}
