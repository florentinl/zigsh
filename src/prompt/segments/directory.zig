const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");
const util = @import("util.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "  ");

    if (current.git) |git| {
        try text.appendSlice(allocator, std.fs.path.basename(git.root));
        if (current.cwd.len > git.root.len) {
            try text.append(allocator, '/');
            try text.appendSlice(allocator, current.cwd[git.root.len + 1 ..]);
        }
    } else if (std.c.getenv("HOME")) |pointer| {
        const home = std.mem.span(pointer);
        if (context.isPathPrefix(home, current.cwd)) {
            try text.append(allocator, '~');
            if (current.cwd.len > home.len) try text.appendSlice(allocator, current.cwd[home.len..]);
        } else {
            try text.appendSlice(allocator, current.cwd);
        }
    } else {
        try text.appendSlice(allocator, current.cwd);
    }
    try text.append(allocator, ' ');
    return util.output(allocator, text.items, .directory);
}
