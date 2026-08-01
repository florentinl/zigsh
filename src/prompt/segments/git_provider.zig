const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");
const util = @import("util.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    const info = current.git orelse return .{};
    const symbol = switch (info.provider) {
        .github => "  ",
        .gitlab => "  ",
        .generic => "  ",
    };
    return util.output(allocator, symbol, .git);
}
