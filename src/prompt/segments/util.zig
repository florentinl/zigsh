const std = @import("std");
const segment = @import("../segment.zig");
const style = @import("../style.zig");

pub fn output(allocator: std.mem.Allocator, text: []const u8, style_name: ?style.Name) !segment.Output {
    if (text.len == 0) return .{};
    return .{ .text = try allocator.dupe(u8, text), .style_name = style_name };
}

pub fn appendCount(list: *std.ArrayList(u8), allocator: std.mem.Allocator, symbol: []const u8, count: usize) !void {
    if (count == 0) return;
    try list.appendSlice(allocator, symbol);
    const rendered = try std.fmt.allocPrint(allocator, "{d} ", .{count});
    defer allocator.free(rendered);
    try list.appendSlice(allocator, rendered);
}
