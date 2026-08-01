const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");
const util = @import("util.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    if (current.status == 0) return util.output(allocator, " ", .success);
    const text = try std.fmt.allocPrint(allocator, "✗ {d} ", .{current.status});
    return .{ .text = text, .style_name = .@"error" };
}
