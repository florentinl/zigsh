const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    const virtual_env = current.virtual_env orelse return .{};
    return .{
        .text = try std.fmt.allocPrint(allocator, " {s} ", .{virtual_env}),
        .style_name = .python,
    };
}

test "Python segment requires an active virtual environment" {
    var current = context.Context{
        .cwd = @constCast(""[0..]),
        .git = null,
        .git_duration_ns = 0,
        .git_latency_ns = 0,
        .status = 0,
        .virtual_env = null,
    };
    var hidden = try render(std.testing.allocator, &current);
    defer hidden.deinit(std.testing.allocator);
    try std.testing.expect(hidden.text == null);

    current.virtual_env = @constCast("venv-yellow"[0..]);
    var visible = try render(std.testing.allocator, &current);
    defer visible.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(" venv-yellow ", visible.text.?);
}
