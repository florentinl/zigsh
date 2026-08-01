const std = @import("std");
pub const protocol = @import("protocol.zig");
const runtime = @import("runtime.zig");
const zle_events = @import("../zle_events.zig");
const zle_hooks = @import("../zle_hooks.zig");

pub const CompletionCallback = *const fn (*const protocol.Frame) zle_hooks.Effects;

pub const CompletionSubscription = struct {
    callback: CompletionCallback,
    registered: bool = false,

    pub fn init(callback: CompletionCallback) CompletionSubscription {
        return .{ .callback = callback };
    }

    pub fn register(self: *CompletionSubscription) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
        if (self.registered) return;
        try add(self.callback);
        self.registered = true;
    }

    pub fn unregister(self: *CompletionSubscription) void {
        if (!self.registered) return;
        remove(self.callback);
        self.registered = false;
    }
};

const callback_capacity = 4;
const allocator = std.heap.c_allocator;

var client: runtime.Client = .{};
var response_subscription = zle_events.Subscription.init(onReadable);
var callbacks: [callback_capacity]?CompletionCallback = @splat(null);
var callback_count: usize = 0;
var worker_epoch: u64 = 0;
var active_job: ?struct { job: protocol.Job, generation: u64 } = null;

pub fn setup() c_int {
    client.start() catch return 1;
    response_subscription.register(client.responseFd().?) catch {
        client.stop();
        return 1;
    };
    advanceEpoch();
    return 0;
}

pub fn cleanup() void {
    response_subscription.unregister();
    callbacks = @splat(null);
    callback_count = 0;
    client.stop();
    active_job = null;
}

pub fn epoch() u64 {
    return worker_epoch;
}

pub fn busy() bool {
    return active_job != null;
}

pub fn activeJob() ?protocol.Job {
    return if (active_job) |active| active.job else null;
}

pub fn submit(
    job: protocol.Job,
    generation: u64,
    payload: []const u8,
    deadline_ns: u64,
) runtime.SubmitError!void {
    client.submit(job, generation, payload, deadline_ns) catch |err| {
        recoverWorker() catch {};
        return err;
    };
    active_job = .{ .job = job, .generation = generation };
}

pub fn submitAndWait(
    job: protocol.Job,
    generation: u64,
    payload: []const u8,
    deadline_ns: u64,
) !?protocol.Frame {
    try submit(job, generation, payload, deadline_ns);
    while (try client.waitUntilReadable(deadline_ns)) {
        var frame = (try receive()) orelse continue;
        if (frame.header.job == job and frame.header.generation == generation) return frame;
        _ = dispatch(&frame);
        frame.deinit(allocator);
    }
    return null;
}

pub fn cancelAndRestart() bool {
    recoverWorker() catch return false;
    return true;
}

pub fn deadlineAfter(duration_ns: u64) u64 {
    return runtime.monotonicNanoseconds() +| duration_ns;
}

fn recoverWorker() !void {
    response_subscription.unregister();
    active_job = null;
    client.restart() catch return error.RestartFailed;
    response_subscription.register(client.responseFd().?) catch {
        client.stop();
        return error.RestartFailed;
    };
    advanceEpoch();
}

fn advanceEpoch() void {
    worker_epoch +%= 1;
    if (worker_epoch == 0) worker_epoch = 1;
}

fn onReadable() zle_hooks.Effects {
    var effects: zle_hooks.Effects = .{};
    while (true) {
        var frame = receive() catch {
            _ = recoverWorker() catch {};
            break;
        } orelse break;
        effects.merge(dispatch(&frame));
        frame.deinit(allocator);
    }
    return effects;
}

fn receive() !?protocol.Frame {
    const frame = try client.receive(allocator) orelse return null;
    if (active_job) |active| {
        if (frame.header.job == active.job and frame.header.generation == active.generation) active_job = null;
    }
    return frame;
}

fn dispatch(frame: *const protocol.Frame) zle_hooks.Effects {
    var effects: zle_hooks.Effects = .{};
    for (callbacks[0..callback_count]) |callback| effects.merge(callback.?(frame));
    return effects;
}

fn add(callback: CompletionCallback) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
    if (indexOf(callback) != null) return error.CallbackAlreadyRegistered;
    if (callback_count == callbacks.len) return error.CapacityExceeded;
    callbacks[callback_count] = callback;
    callback_count += 1;
}

fn remove(callback: CompletionCallback) void {
    const index = indexOf(callback) orelse return;
    var current = index;
    while (current + 1 < callback_count) : (current += 1) callbacks[current] = callbacks[current + 1];
    callback_count -= 1;
    callbacks[callback_count] = null;
}

fn indexOf(callback: CompletionCallback) ?usize {
    for (callbacks[0..callback_count], 0..) |registered, index| {
        if (registered.? == callback) return index;
    }
    return null;
}

var test_calls: usize = 0;

fn testCallback(frame: *const protocol.Frame) zle_hooks.Effects {
    if (frame.header.job == .ping) test_calls += 1;
    return .{ .regions_changed = true };
}

test "completion subscriptions are owned and idempotent" {
    callbacks = @splat(null);
    callback_count = 0;
    defer {
        callbacks = @splat(null);
        callback_count = 0;
    }
    var subscription = CompletionSubscription.init(testCallback);
    try subscription.register();
    try subscription.register();
    try std.testing.expectEqual(@as(usize, 1), callback_count);
    subscription.unregister();
    subscription.unregister();
    try std.testing.expectEqual(@as(usize, 0), callback_count);
}

test "completion dispatch merges product effects" {
    callbacks = @splat(null);
    callback_count = 0;
    test_calls = 0;
    defer {
        callbacks = @splat(null);
        callback_count = 0;
    }
    try add(testCallback);
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
    const effects = dispatch(&frame);
    try std.testing.expectEqual(@as(usize, 1), test_calls);
    try std.testing.expect(effects.regions_changed);
}
