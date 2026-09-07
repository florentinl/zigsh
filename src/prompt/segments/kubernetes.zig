const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");

const commands = [_][]const u8{ "kubectl", "helm" };

/// Pure rendering of worker-owned cached data. No filesystem or process I/O.
pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    const text = current.kubernetes_text orelse return .{};
    return .{ .text = try allocator.dupe(u8, text), .style_name = .kubernetes };
}

pub fn matchesCommand(command: []const u8) bool {
    return segment.matchesCommandBasename(command, &commands);
}

test "Kubernetes segment matches command basenames" {
    for ([_][]const u8{ "kubectl", "helm", "/usr/local/bin/kubectl" }) |command| {
        try std.testing.expect(matchesCommand(command));
    }
    for ([_][]const u8{ "echo", "kubectl-neat", "helmfile" }) |command| {
        try std.testing.expect(!matchesCommand(command));
    }
}
