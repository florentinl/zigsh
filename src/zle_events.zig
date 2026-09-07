const std = @import("std");
const zle = @import("zle.zig");
const zle_hooks = @import("zle_hooks.zig");

pub const Callback = *const fn () zle_hooks.Effects;

pub const Subscription = struct {
    callback: Callback,
    fd: c_int = -1,

    pub fn init(callback: Callback) Subscription {
        return .{ .callback = callback };
    }

    pub fn register(self: *Subscription, fd: c_int) error{
        CallbackAlreadyRegistered,
        CapacityExceeded,
        WatchFailed,
    }!void {
        if (self.fd == fd) return;
        if (self.fd >= 0) self.unregister();
        try add(fd, self.callback);
        errdefer remove(fd, self.callback);
        zle.watchFd(fd, widget_name) catch return error.WatchFailed;
        self.fd = fd;
    }

    pub fn unregister(self: *Subscription) void {
        if (self.fd < 0) return;
        zle.unwatchFd(self.fd) catch {};
        remove(self.fd, self.callback);
        self.fd = -1;
    }
};

const Entry = struct {
    fd: c_int,
    callback: Callback,
};

const widget_name: [:0]const u8 = "zigsh-fd-event";
const entry_capacity = 8;

var widget: zle.Widget = .{};
var entries: [entry_capacity]?Entry = @splat(null);
var entry_count: usize = 0;
var dispatching = false;

pub fn setup() c_int {
    widget.register(widget_name, dispatch) catch return 1;
    return 0;
}

pub fn cleanup() void {
    while (entry_count != 0) {
        const entry = entries[entry_count - 1].?;
        zle.unwatchFd(entry.fd) catch {};
        entry_count -= 1;
        entries[entry_count] = null;
    }
    dispatching = false;
    widget.unregister();
}

fn add(fd: c_int, callback: Callback) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
    if (indexOf(fd, callback) != null) return error.CallbackAlreadyRegistered;
    if (entry_count == entries.len) return error.CapacityExceeded;
    entries[entry_count] = .{ .fd = fd, .callback = callback };
    entry_count += 1;
}

fn remove(fd: c_int, callback: Callback) void {
    const index = indexOf(fd, callback) orelse return;
    var current = index;
    while (current + 1 < entry_count) : (current += 1) entries[current] = entries[current + 1];
    entry_count -= 1;
    entries[entry_count] = null;
}

fn indexOf(fd: c_int, callback: Callback) ?usize {
    for (entries[0..entry_count], 0..) |registered, index| {
        if (registered.?.fd == fd and registered.?.callback == callback) return index;
    }
    return null;
}

fn dispatch(_: [*c][*c]u8) callconv(.c) c_int {
    if (dispatching) return 0;
    dispatching = true;
    defer dispatching = false;

    zle_hooks.applyExternal(runCallbacks());
    return 0;
}

fn runCallbacks() zle_hooks.Effects {
    var effects: zle_hooks.Effects = .{};
    // Recovery can remove/re-register subscriptions during a callback. Iterate
    // a snapshot and call shared dispatchers only once per readiness event.
    const snapshot = entries;
    const count = entry_count;
    var called: [entry_capacity]Callback = undefined;
    var called_count: usize = 0;
    for (snapshot[0..count]) |entry| {
        const current = entry.?;
        if (indexOf(current.fd, current.callback) == null) continue;
        var already_called = false;
        for (called[0..called_count]) |callback| {
            if (callback == current.callback) already_called = true;
        }
        if (already_called) continue;
        called[called_count] = current.callback;
        called_count += 1;
        effects.merge(current.callback());
    }
    return effects;
}

var test_order: [2]u8 = undefined;
var test_count: usize = 0;

fn firstTestCallback() zle_hooks.Effects {
    test_order[test_count] = 1;
    test_count += 1;
    return .{ .regions_changed = true };
}

fn secondTestCallback() zle_hooks.Effects {
    test_order[test_count] = 2;
    test_count += 1;
    return .{ .prompt_changed = true };
}

test "fd sources share ordered dispatch and merged effects" {
    entries = @splat(null);
    entry_count = 0;
    test_count = 0;
    defer {
        entries = @splat(null);
        entry_count = 0;
    }

    try add(10, firstTestCallback);
    try add(11, secondTestCallback);
    const effects = runCallbacks();

    try std.testing.expect(effects.prompt_changed);
    try std.testing.expect(effects.regions_changed);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, test_order[0..test_count]);
}

fn removingTestCallback() zle_hooks.Effects {
    test_count += 1;
    remove(10, removingTestCallback);
    remove(11, secondTestCallback);
    return .{};
}

test "fd dispatcher tolerates removal of subscriptions during callbacks" {
    entries = @splat(null);
    entry_count = 0;
    test_count = 0;
    defer {
        entries = @splat(null);
        entry_count = 0;
    }
    try add(10, removingTestCallback);
    try add(11, secondTestCallback);
    _ = runCallbacks();
    try std.testing.expectEqual(@as(usize, 1), test_count);
    try std.testing.expectEqual(@as(usize, 0), entry_count);
}

test "fd dispatcher invokes a shared callback once per event" {
    entries = @splat(null);
    entry_count = 0;
    test_count = 0;
    defer {
        entries = @splat(null);
        entry_count = 0;
    }
    try add(10, firstTestCallback);
    try add(11, firstTestCallback);
    _ = runCallbacks();
    try std.testing.expectEqual(@as(usize, 1), test_count);
}
