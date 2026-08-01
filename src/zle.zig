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
