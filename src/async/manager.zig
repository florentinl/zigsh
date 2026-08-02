const std = @import("std");
pub const protocol = @import("protocol.zig");
const runtime = @import("runtime.zig");
const zle_events = @import("../zle_events.zig");
const zle_hooks = @import("../zle_hooks.zig");

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

    pub fn submit(
        self: Job,
        generation: u64,
        payload: []const u8,
        deadline_ns: u64,
    ) SubmitError!void {
        try submitJob(self.kind, generation, payload, deadline_ns);
    }

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
    while (try slot.client.waitUntilReadable(deadline_ns)) {
        var frame = (try receive(kind)) orelse continue;
        if (frame.header.generation == generation) return frame;
        _ = dispatch(kind, &frame);
        frame.deinit(allocator);
    }
    return null;
}

fn recoverWorker(kind: protocol.Job) !void {
    const slot = slotFor(kind);
    if (slot.callback == null) return error.NotRegistered;
    responseSubscriptionFor(kind).unregister();
    slot.active_generation = null;
    slot.client.restart() catch return error.RestartFailed;
    responseSubscriptionFor(kind).register(slot.client.responseFd().?) catch {
        slot.client.stop();
        return error.RestartFailed;
    };
    advanceEpoch(slot);
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
        while (true) {
            var frame = receive(entry.key) catch {
                _ = recoverWorker(entry.key) catch {};
                break;
            } orelse break;
            effects.merge(dispatch(entry.key, &frame));
            frame.deinit(allocator);
        }
    }
    return effects;
}

fn receive(kind: protocol.Job) !?protocol.Frame {
    const slot = slotFor(kind);
    var frame = try slot.client.receive(allocator) orelse return null;
    errdefer frame.deinit(allocator);
    if (frame.header.job != kind) return error.UnexpectedJob;
    if (frame.header.generation == slot.active_generation) slot.active_generation = null;
    return frame;
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
    try std.testing.expect(slotFor(.highlight).callback == null);
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
    try std.testing.expect(!Job.init(.highlight, testCallback).busy());
}
