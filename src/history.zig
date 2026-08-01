const zle = @import("zle.zig");

const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

const up_widget_name: [:0]const u8 = "zigsh-up-line-or-beginning-search";
const down_widget_name: [:0]const u8 = "zigsh-down-line-or-beginning-search";

var up_widget: zle.Widget = .{};
var down_widget: zle.Widget = .{};
var searching_widget: zsh.Thingy = null;
var saved_cursor: c_int = 0;

pub fn setup() c_int {
    configureHistory();

    up_widget.register(up_widget_name, upLineOrBeginningSearch) catch return 1;

    down_widget.register(down_widget_name, downLineOrBeginningSearch) catch {
        cleanup();
        return 1;
    };

    bindNavigationKeys() catch {
        cleanup();
        return 1;
    };
    return 0;
}

pub fn cleanup() void {
    searching_widget = null;

    down_widget.unregister();
    up_widget.unregister();
}

fn configureHistory() void {
    zsh.opts[zsh.EXTENDEDHISTORY] = 1;
    zsh.opts[zsh.HISTEXPIREDUPSFIRST] = 1;
    zsh.opts[zsh.HISTIGNOREDUPS] = 1;
    zsh.opts[zsh.HISTIGNORESPACE] = 1;
    zsh.opts[zsh.HISTVERIFY] = 1;
    zsh.opts[zsh.SHAREHISTORY] = 1;

    const histfile = zsh.getsparam(@constCast("HISTFILE"));
    if (histfile == null or histfile[0] == 0) {
        const home = zsh.getsparam(@constCast("HOME"));
        const value = zsh.tricat(
            if (home == null) "" else home,
            "/",
            ".zsh_history",
        );
        _ = zsh.setsparam(@constCast("HISTFILE"), value);
    }

    if (zsh.getiparam(@constCast("HISTSIZE")) < 50_000) {
        _ = zsh.setiparam(@constCast("HISTSIZE"), 50_000);
    }
    if (zsh.getiparam(@constCast("SAVEHIST")) < 10_000) {
        _ = zsh.setiparam(@constCast("SAVEHIST"), 10_000);
    }
}

fn bindNavigationKeys() zle.BindKeyError!void {
    const normal_cursor_up = "\x1b[A";
    const normal_cursor_down = "\x1b[B";
    const application_cursor_up = "\x1bOA";
    const application_cursor_down = "\x1bOB";

    try zle.bindKeyInMap("emacs", normal_cursor_up, up_widget_name);
    try zle.bindKeyInMap("emacs", normal_cursor_down, down_widget_name);
    try zle.bindKeyInMap("emacs", application_cursor_up, up_widget_name);
    try zle.bindKeyInMap("emacs", application_cursor_down, down_widget_name);

    try zle.bindKeyInMap("viins", normal_cursor_up, up_widget_name);
    try zle.bindKeyInMap("viins", normal_cursor_down, down_widget_name);
    try zle.bindKeyInMap("viins", application_cursor_up, up_widget_name);
    try zle.bindKeyInMap("viins", application_cursor_down, down_widget_name);

    try zle.bindKeyInMap("vicmd", normal_cursor_up, up_widget_name);
    try zle.bindKeyInMap("vicmd", normal_cursor_down, down_widget_name);
    try zle.bindKeyInMap("vicmd", application_cursor_up, up_widget_name);
    try zle.bindKeyInMap("vicmd", application_cursor_down, down_widget_name);
}

fn upLineOrBeginningSearch(args: [*c][*c]u8) callconv(.c) c_int {
    if (containsNewline(0, zsh.zlecs)) {
        searching_widget = null;
        return zsh.uplineorhistory(args);
    }

    restoreSearchCursor();
    saved_cursor = zsh.zlecs;
    searching_widget = zsh.bindk;

    _ = zsh.historybeginningsearchbackward(args);
    return zsh.endofline(args);
}

fn downLineOrBeginningSearch(args: [*c][*c]u8) callconv(.c) c_int {
    const continued_search =
        searching_widget != null and zsh.lbindk == searching_widget;
    const right_buffer_has_newline = containsNewline(zsh.zlecs, zsh.zlell);
    const has_numeric_argument = (zsh.zmod.flags & zsh.MOD_MULT) != 0;

    if (!has_numeric_argument and
        (continued_search or !right_buffer_has_newline))
    {
        restoreSearchCursor();
        searching_widget = zsh.bindk;
        saved_cursor = zsh.zlecs;

        if (zsh.historybeginningsearchforward(args) == 0) {
            if (!containsNewline(zsh.zlecs, zsh.zlell)) {
                return zsh.endofline(args);
            }
            return 0;
        }
        if (!containsNewline(zsh.zlecs, zsh.zlell)) return 1;
    }

    searching_widget = null;
    return zsh.downlineorhistory(args);
}

fn restoreSearchCursor() void {
    if (searching_widget != null and zsh.lbindk == searching_widget) {
        zsh.zlecs = saved_cursor;
    }
}

fn containsNewline(start: c_int, end: c_int) bool {
    var index = start;
    while (index < end) : (index += 1) {
        if (zsh.zleline[@intCast(index)] == '\n') return true;
    }
    return false;
}
