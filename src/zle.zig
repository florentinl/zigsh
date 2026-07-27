const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

pub const BindKeyError = error{
    KeymapNotFound,
    WidgetNotFound,
    ImmutableKeymap,
    EmptyKeySequence,
};

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
