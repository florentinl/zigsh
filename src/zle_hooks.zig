const std = @import("std");
const zle = @import("zle.zig");

pub const Effects = struct {
    prompt_changed: bool = false,

    fn merge(self: *Effects, next: Effects) void {
        self.prompt_changed = self.prompt_changed or next.prompt_changed;
    }
};

pub const Callback = *const fn () Effects;

pub const Subscription = struct {
    callback: Callback,
    registered: bool = false,

    pub fn init(callback: Callback) Subscription {
        return .{ .callback = callback };
    }

    pub fn register(self: *Subscription) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
        if (self.registered) return;
        try add(self.callback);
        self.registered = true;
    }

    pub fn unregister(self: *Subscription) void {
        if (!self.registered) return;
        remove(self.callback);
        self.registered = false;
    }
};

const hook_name: [:0]const u8 = "zle-line-pre-redraw";
const callback_capacity = 8;

var widget: zle.Widget = .{};
var callbacks: [callback_capacity]?Callback = @splat(null);
var callback_count: usize = 0;
var dispatching = false;

pub fn setup() c_int {
    widget.register(hook_name, dispatch) catch return 1;
    return 0;
}

pub fn cleanup() void {
    resetCallbacks();
    widget.unregister();
}

fn resetCallbacks() void {
    callback_count = 0;
    callbacks = @splat(null);
    dispatching = false;
}

fn add(callback: Callback) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
    if (indexOf(callback) != null) return error.CallbackAlreadyRegistered;
    if (callback_count == callbacks.len) return error.CapacityExceeded;
    callbacks[callback_count] = callback;
    callback_count += 1;
}

fn remove(callback: Callback) void {
    const index = indexOf(callback) orelse return;
    var current = index;
    while (current + 1 < callback_count) : (current += 1) {
        callbacks[current] = callbacks[current + 1];
    }
    callback_count -= 1;
    callbacks[callback_count] = null;
}

fn indexOf(callback: Callback) ?usize {
    for (callbacks[0..callback_count], 0..) |registered, index| {
        if (registered.? == callback) return index;
    }
    return null;
}

fn dispatch(_: [*c][*c]u8) callconv(.c) c_int {
    if (dispatching) return 0;
    dispatching = true;
    defer dispatching = false;

    const effects = runCallbacks();
    if (effects.prompt_changed) {
        // redrawhook() is always followed by Zsh's normal zrefresh(). Update
        // its cached prompt buffers here without starting a nested refresh.
        zle.reexpandPrompt();
    }
    return 0;
}

fn runCallbacks() Effects {
    var effects: Effects = .{};
    for (callbacks[0..callback_count]) |callback| {
        effects.merge(callback.?());
    }
    return effects;
}

var test_order: [2]u8 = undefined;
var test_order_count: usize = 0;

fn testPromptCallback() Effects {
    test_order[test_order_count] = 1;
    test_order_count += 1;
    return .{ .prompt_changed = true };
}

fn testHighlightCallback() Effects {
    test_order[test_order_count] = 2;
    test_order_count += 1;
    return .{};
}

test "callbacks share one ordered dispatch and merge redraw effects" {
    resetCallbacks();
    defer resetCallbacks();
    test_order_count = 0;

    try add(testPromptCallback);
    try add(testHighlightCallback);
    try std.testing.expectError(error.CallbackAlreadyRegistered, add(testPromptCallback));

    const effects = runCallbacks();

    try std.testing.expect(effects.prompt_changed);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, test_order[0..test_order_count]);
}

test "subscriptions own idempotent registration and removal" {
    resetCallbacks();
    defer resetCallbacks();
    var subscription = Subscription.init(testPromptCallback);

    try subscription.register();
    try subscription.register();
    try std.testing.expectEqual(@as(usize, 1), callback_count);

    subscription.unregister();
    subscription.unregister();
    try std.testing.expectEqual(@as(usize, 0), callback_count);
}
