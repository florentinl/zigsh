const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");
const util = @import("util.zig");

pub fn render(allocator: std.mem.Allocator, _: *const context.Context) !segment.Output {
    if (std.c.geteuid() != 0) return .{};
    return util.output(allocator, "# ", .sudo);
}
