const std = @import("std");
const builtin = @import("builtin");

const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

pub const BindKeyError = error{
    KeymapNotFound,
    WidgetNotFound,
    ImmutableKeymap,
    EmptyKeySequence,
};

pub const WidgetCallback = *const fn ([*c][*c]u8) callconv(.c) c_int;

pub const Widget = struct {
    handle: zsh.Widget = null,

    pub fn register(self: *Widget, name: [:0]const u8, callback: WidgetCallback) error{RegistrationFailed}!void {
        if (self.handle != null) return;
        self.handle = zsh.addzlefunction(@constCast(name.ptr), callback, 0);
        if (self.handle == null) return error.RegistrationFailed;
    }

    pub fn unregister(self: *Widget) void {
        if (self.handle) |registered| zsh.deletezlefunction(registered);
        self.handle = null;
    }
};

/// Installs or replaces the `zle -F -w FD WIDGET` association without parsing
/// shell source. `bin_zle` is ZLE's exported builtin handler; it owns the
/// watch registry and its allocation/lifecycle rules.
pub fn watchFd(fd: c_int, widget_name: [:0]const u8) FdWatchError!void {
    try invokeFdBuiltin(fd, widget_name);
}

/// Removes the `zle -F FD` association without parsing shell source.
pub fn unwatchFd(fd: c_int) FdWatchError!void {
    try invokeFdBuiltin(fd, null);
}

pub const FdWatchError = error{
    InvalidFileDescriptor,
    RegistrationFailed,
    RemovalFailed,
};

fn invokeFdBuiltin(fd: c_int, widget_name: ?[:0]const u8) FdWatchError!void {
    if (fd < 0) return error.InvalidFileDescriptor;
    // Unit tests exercise the subscription registry without loading ZLE.
    if (builtin.is_test) return;

    var fd_buffer: [32]u8 = undefined;
    const fd_text = std.fmt.bufPrintZ(&fd_buffer, "{d}", .{fd}) catch unreachable;
    var arguments = [_][*c]u8{ fd_text.ptr, null, null };
    var options: zsh.struct_options = std.mem.zeroes(zsh.struct_options);
    options.ind['F'] = 1;
    if (widget_name) |name| {
        arguments[1] = @constCast(name.ptr);
        options.ind['w'] = 1;
    }

    const status = zsh.bin_zle(@constCast("zle"), &arguments, &options, 0);
    if (status != 0) return if (widget_name == null) error.RemovalFailed else error.RegistrationFailed;
}

/// Refresh ZLE's cached prompt expansion without drawing the screen. The
/// caller must already be in a path, such as zle-line-pre-redraw, that Zsh
/// follows with its normal refresh.
pub fn reexpandPrompt() void {
    zsh.reexpandprompt();
}

/// Re-expand the prompt and redisplay immediately. Do not call this from
/// zle-line-pre-redraw: Zsh already refreshes after that hook, so use
/// reexpandPrompt there to avoid a nested refresh.
pub fn resetPrompt() void {
    zsh.zle_resetprompt();
}

/// Redisplay the current edit buffer without rebuilding the prompt. External
/// event callbacks use this when only region highlights changed.
pub fn refresh() void {
    zsh.zrefresh();
}

/// Bind a raw key sequence to an existing widget in ZLE's `main` keymap.
pub fn bindKey(sequence: []const u8, widget_name: [:0]const u8) BindKeyError!void {
    return bindKeyInMap("main", sequence, widget_name);
}

/// Bind an arbitrary raw sequence of one or more keys to an existing widget.
pub fn bindKeyInMap(
    keymap_name: [:0]const u8,
    sequence: []const u8,
    widget_name: [:0]const u8,
) BindKeyError!void {
    const keymap = zsh.openkeymap(@constCast(keymap_name.ptr)) orelse
        return error.KeymapNotFound;
    const widget_node = zsh.gethashnode(zsh.thingytab, widget_name.ptr) orelse
        return error.WidgetNotFound;

    const widget = zsh.refthingy(@ptrCast(widget_node));
    errdefer zsh.unrefthingy(widget);

    const metafied_sequence = zsh.metafy(
        @constCast(sequence.ptr),
        @intCast(sequence.len),
        zsh.META_DUP,
    );
    defer zsh.zsfree(metafied_sequence);

    switch (zsh.bindkey(keymap, metafied_sequence, widget, null)) {
        0 => {},
        1 => return error.ImmutableKeymap,
        2 => return error.EmptyKeySequence,
        else => unreachable,
    }
}
