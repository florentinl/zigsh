const std = @import("std");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Thin adapter for byte strings and C-compatible data whose ownership may
/// cross into Zsh. Every returned pointer is the exact result of `zalloc`.
pub const permanent: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn alloc(
    _: *anyopaque,
    len: usize,
    _: Alignment,
    _: usize,
) ?[*]u8 {
    const memory = zsh.zalloc(len) orelse return null;
    return @ptrCast(memory);
}

fn resize(
    _: *anyopaque,
    _: []u8,
    _: Alignment,
    _: usize,
    _: usize,
) bool {
    return false;
}

fn remap(
    _: *anyopaque,
    _: []u8,
    _: Alignment,
    _: usize,
    _: usize,
) ?[*]u8 {
    return null;
}

fn free(
    _: *anyopaque,
    memory: []u8,
    _: Alignment,
    _: usize,
) void {
    zsh.zfree(memory.ptr, 0);
}
