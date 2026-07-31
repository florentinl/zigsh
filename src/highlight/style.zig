const std = @import("std");

pub const Style = enum {
    string,
    punctuation,
    operator,
    number,
    keyword,
    function,
    variable,
    comment,
    parse_error,

    pub fn priority(self: Style) u8 {
        return switch (self) {
            .string => 10,
            .punctuation => 20,
            .operator => 30,
            .number => 40,
            .keyword => 50,
            .function => 60,
            .variable => 70,
            .comment => 80,
            .parse_error => 90,
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
    .{ .name = "keyword", .style = .keyword },
    .{ .name = "function", .style = .function },
    .{ .name = "variable", .style = .variable },
    .{ .name = "comment", .style = .comment },
    .{ .name = "error", .style = .parse_error },
};

test "capture names map to styles" {
    try std.testing.expectEqual(Style.keyword, Style.fromCapture("keyword"));
    try std.testing.expectEqual(null, Style.fromCapture("not-owned"));
}
