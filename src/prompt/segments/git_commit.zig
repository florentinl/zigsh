const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    const git = current.git orelse return .{};
    if (git.branch != null) return .{};
    const commit = git.commit orelse return .{};
    const text = if (git.tag) |tag|
        try std.fmt.allocPrint(allocator, "({s} {s}) ", .{ commit, tag })
    else
        try std.fmt.allocPrint(allocator, "{s} ", .{commit});
    return .{ .text = text, .style_name = .git };
}
