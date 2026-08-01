const std = @import("std");

pub const Style = enum {
    plain,
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
    unknown_token,
    unknown_command,
    comment,
    parse_error,
    recovered_keyword,
    recovered_plain,
    recovered_punctuation,
    recovered_command,
    recovered_path,
    recovered_string,
    recovered_variable,
    recovered_unknown,
    test_option,

    pub fn priority(self: Style) u8 {
        return switch (self) {
            .plain => 106,
            .path => 70,
            .path_prefix => 71,
            .punctuation => 105,
            .operator => 30,
            .number => 40,
            .redirection => 135,
            .keyword => 50,
            .function => 60,
            .alias,
            .suffix_alias,
            .global_alias,
            => 126,
            .shell_function,
            .builtin,
            .hashed_command,
            .external_command,
            .precommand,
            .auto_directory,
            => 65,
            .globbing => 75,
            .unknown_command => 125,
            .string => 100,
            .variable => 110,
            .history_expansion => 115,
            .comment => 120,
            .unknown_token => 127,
            .parse_error => 130,
            .recovered_keyword => 137,
            .recovered_plain => 135,
            .recovered_punctuation => 136,
            .recovered_command, .recovered_path => 137,
            .recovered_string => 135,
            .recovered_variable => 137,
            .recovered_unknown => 137,
            .test_option => 138,
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
