const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");
const util = @import("util.zig");

pub fn render(allocator: std.mem.Allocator, _: *const context.Context) !segment.Output {
    const symbol = switch (@import("builtin").os.tag) {
        .macos => " ",
        .linux => " ",
        .windows => " ",
        else => "● ",
    };
    return util.output(allocator, symbol, .os);
}
