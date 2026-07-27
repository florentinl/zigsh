const std = @import("std");
const allocators = @import("allocator.zig");
const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

var count: u64 = 0;

fn initPrompt(new_prompt: [:0]const u8) void {
    zsh.zsfree(zsh.prompt);
    zsh.prompt = zsh.ztrdup_metafy(new_prompt);
}

fn updatePrompt(new_prompt: [:0]u8) void {
    zsh.zsfree(zsh.prompt);
    zsh.prompt = zsh.metafy(
        new_prompt.ptr,
        @intCast(new_prompt.len),
        zsh.META_REALLOC,
    );
}

pub fn setup() c_int {
    zsh.opts[zsh.PROMPTSUBST] = 0;
    zsh.rprompt_indent = 0;
    initPrompt("welcome to zig -> ");
    _ = zsh.addzlefunction(@constCast("zle-line-pre-redraw"), linePreRedraw, 0);
    return 0;
}

pub fn linePreRedraw(_: [*c][*c]u8) callconv(.c) c_int {
    count += 1;
    const new_prompt: [:0]u8 = std.fmt.allocPrintSentinel(
        allocators.permanent,
        "welcome to zig (render: {d}) -> ",
        .{count},
        0,
    ) catch return 1;

    updatePrompt(new_prompt);
    zsh.zle_resetprompt();
    return 0;
}
