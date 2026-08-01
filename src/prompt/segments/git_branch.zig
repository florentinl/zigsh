const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    const git = current.git orelse return .{};
    const branch = git.branch orelse return .{};
    const text = try std.fmt.allocPrint(allocator, "{s} ", .{branch});
    return .{ .text = text, .style_name = .git };
}
