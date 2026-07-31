const std = @import("std");

pub const Style = enum {
    path,
    path_prefix,
    string,
    punctuation,
    operator,
    number,
    redirection,
    keyword,
    function,
    alias,
    suffix_alias,
    global_alias,
    shell_function,
    builtin,
    hashed_command,
    external_command,
    precommand,
    auto_directory,
    globbing,
    history_expansion,
    variable,
    unknown_command,
    comment,
    parse_error,

    pub fn priority(self: Style) u8 {
        return switch (self) {
            .path => 70,
            .path_prefix => 71,
            .punctuation => 20,
            .operator => 30,
            .number => 40,
            .redirection => 45,
            .keyword => 50,
            .function => 60,
            .alias,
            .suffix_alias,
            .global_alias,
            .shell_function,
            .builtin,
            .hashed_command,
            .external_command,
            .precommand,
            .auto_directory,
            => 65,
            .globbing => 75,
            .unknown_command => 85,
            .string => 100,
            .variable => 110,
            .history_expansion => 115,
            .comment => 120,
            .parse_error => 130,
        };
    }

    pub fn fromCapture(capture_name: []const u8) ?Style {
        inline for (capture_styles) |entry| {
            if (std.mem.eql(u8, entry.name, capture_name)) return entry.style;
        }
        return null;
    }
};

const capture_styles = [_]struct { name: []const u8, style: Style }{
    .{ .name = "string", .style = .string },
    .{ .name = "punctuation", .style = .punctuation },
    .{ .name = "operator", .style = .operator },
    .{ .name = "number", .style = .number },
    .{ .name = "redirection", .style = .redirection },
    .{ .name = "keyword", .style = .keyword },
    .{ .name = "function", .style = .function },
    .{ .name = "globbing", .style = .globbing },
    .{ .name = "variable", .style = .variable },
    .{ .name = "comment", .style = .comment },
    .{ .name = "error", .style = .parse_error },
};

test "capture names map to styles" {
    try std.testing.expectEqual(Style.keyword, Style.fromCapture("keyword"));
    try std.testing.expectEqual(null, Style.fromCapture("not-owned"));
}
