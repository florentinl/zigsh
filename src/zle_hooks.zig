const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

pub const Callback = *const fn () c_int;

const hook_name: [:0]const u8 = "zle-line-pre-redraw";
const callback_capacity = 8;

var widget: zsh.Widget = null;
var callbacks: [callback_capacity]?Callback = @splat(null);
var callback_count: usize = 0;
var dispatching = false;

pub fn setup() c_int {
    if (widget != null) return 0;
    widget = zsh.addzlefunction(@constCast(hook_name.ptr), dispatch, 0);
    return if (widget == null) 1 else 0;
}

pub fn cleanup() void {
    callback_count = 0;
    callbacks = @splat(null);
    dispatching = false;
    if (widget) |registered_widget| {
        zsh.deletezlefunction(registered_widget);
        widget = null;
    }
}

pub fn add(callback: Callback) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
    if (indexOf(callback) != null) return error.CallbackAlreadyRegistered;
    if (callback_count == callbacks.len) return error.CapacityExceeded;
    callbacks[callback_count] = callback;
    callback_count += 1;
}

pub fn remove(callback: Callback) void {
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

    for (callbacks[0..callback_count]) |callback| {
        const result = callback.?();
        if (result != 0) return result;
    }
    return 0;
}
