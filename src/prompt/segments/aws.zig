const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");

const commands = [_][]const u8{ "aws", "aws-vault" };

pub fn render(allocator: std.mem.Allocator, _: *const context.Context) !segment.Output {
    return .{
        .text = try allocator.dupe(u8, "  aws "),
        .style_name = .aws,
    };
}

pub fn matchesCommand(command: []const u8) bool {
    return segment.matchesCommandBasename(command, &commands);
}

test "AWS segment matches command basenames" {
    for ([_][]const u8{ "aws", "aws-vault", "/opt/bin/aws-vault" }) |command| {
        try std.testing.expect(matchesCommand(command));
    }
    for ([_][]const u8{ "echo", "awslocal", "aws-vaulted" }) |command| {
        try std.testing.expect(!matchesCommand(command));
    }
}
