const std = @import("std");
const Span = @import("span.zig").Span;

pub fn appendOperators(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    start_byte: u32,
    end_byte: u32,
) !void {
    const text = source[start_byte..end_byte];
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len) {
            index += 2;
            continue;
        }

        const operator_end = switch (text[index]) {
            '*' => stars: {
                var end = index + 1;
                while (end < text.len and text[end] == '*') : (end += 1) {}
                break :stars end;
            },
            '?' => index + 1,
            '[' => closingDelimiter(text, index, ']') orelse index + 1,
            '<' => closingDelimiter(text, index, '>') orelse index + 1,
            '{' => closingDelimiter(text, index, '}') orelse index + 1,
            '(' => closingDelimiter(text, index, ')') orelse index + 1,
            else => {
                index += 1;
                continue;
            },
        };
        try spans.append(allocator, .{
            .start_byte = start_byte + @as(u32, @intCast(index)),
            .end_byte = start_byte + @as(u32, @intCast(operator_end)),
            .style = .globbing,
        });
        index = operator_end;
    }
}

fn closingDelimiter(text: []const u8, start: usize, delimiter: u8) ?usize {
    var index = start + 1;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\\') {
            index += 1;
            continue;
        }
        if (text[index] == delimiter) return index + 1;
    }
    return null;
}

test "globbing highlights operators without coloring literal text" {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try appendOperators(&spans, std.testing.allocator, "foo/*.zig", 0, 9);
    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 4, .end_byte = 5, .style = .globbing },
    }, spans.items);
}

test "globbing keeps compound operators together and skips escapes" {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try appendOperators(&spans, std.testing.allocator, "\\* ** [ab]", 0, 10);
    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 3, .end_byte = 5, .style = .globbing },
        .{ .start_byte = 6, .end_byte = 10, .style = .globbing },
    }, spans.items);
}
