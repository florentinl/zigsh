const std = @import("std");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

pub fn appendUnclosedQuote(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    start_byte: u32,
    end_byte: u32,
) !bool {
    const text = source[start_byte..end_byte];
    if (std.mem.startsWith(u8, text, "$'")) {
        try spans.append(allocator, .{
            .start_byte = start_byte,
            .end_byte = end_byte,
            .style = .string,
        });
        try appendAnsiCEscapes(spans, allocator, source, start_byte, end_byte);
        return true;
    }
    if (text.len == 0 or text[0] != '"') return false;

    const command_substitution = unescapedCommandSubstitution(text);
    try spans.append(allocator, .{
        .start_byte = start_byte,
        .end_byte = start_byte + @as(u32, @intCast(command_substitution orelse text.len)),
        .style = .string,
    });
    if (command_substitution) |index| {
        try spans.append(allocator, .{
            .start_byte = start_byte + @as(u32, @intCast(index)),
            .end_byte = start_byte + @as(u32, @intCast(index + 2)),
            .style = .punctuation,
        });
        return true;
    }
    try appendDoubleQuotedParameters(spans, allocator, text, start_byte);
    return true;
}

pub fn appendAnsiCEscapes(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    start_byte: u32,
    end_byte: u32,
) !void {
    const text = source[start_byte..end_byte];
    if (text.len < 3 or !std.mem.startsWith(u8, text, "$'")) return;

    var index: usize = 2;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] != '\\') continue;
        const escape = text[index + 1];
        const escape_length = switch (escape) {
            'x' => hexadecimalEscapeLength(text[index + 2 ..], 2),
            'u' => hexadecimalEscapeLength(text[index + 2 ..], 4),
            'U' => hexadecimalEscapeLength(text[index + 2 ..], 8),
            else => continue,
        };
        const style: Style = if (escape_length != null) .variable else .unknown_token;
        const length = escape_length orelse 0;
        const end = index + 2 + length;
        try spans.append(allocator, .{
            .start_byte = start_byte + @as(u32, @intCast(index)),
            .end_byte = start_byte + @as(u32, @intCast(end)),
            .style = style,
        });
        index = end - 1;
    }
}

fn appendDoubleQuotedParameters(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    text: []const u8,
    start_byte: u32,
) !void {
    var index: usize = 1;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] == '\\') {
            index += 1;
            continue;
        }
        if (text[index] != '$' or !isParameterStart(text[index + 1])) continue;

        var end = index + 2;
        while (end < text.len and isParameterContinue(text[end])) : (end += 1) {}
        try spans.append(allocator, .{
            .start_byte = start_byte + @as(u32, @intCast(index)),
            .end_byte = start_byte + @as(u32, @intCast(end)),
            .style = .variable,
        });
        index = end - 1;
    }
}

fn unescapedCommandSubstitution(text: []const u8) ?usize {
    var index: usize = 1;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] == '\\') {
            index += 1;
            continue;
        }
        if (text[index] == '$' and text[index + 1] == '(') return index;
    }
    return null;
}

fn hexadecimalEscapeLength(text: []const u8, required_digits: usize) ?usize {
    if (text.len < required_digits) return null;
    for (text[0..required_digits]) |byte| {
        if (!std.ascii.isHex(byte)) return null;
    }
    return required_digits;
}

fn isParameterStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isParameterContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "unclosed double quotes retain variable highlighting" {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try std.testing.expect(try appendUnclosedQuote(&spans, std.testing.allocator, "\"foo$bar", 0, 8));
    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 0, .end_byte = 8, .style = .string },
        .{ .start_byte = 4, .end_byte = 8, .style = .variable },
    }, spans.items);
}

test "unclosed quotes preserve command substitution delimiters" {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try std.testing.expect(try appendUnclosedQuote(&spans, std.testing.allocator, "\"foo$( ", 0, 7));
    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 0, .end_byte = 4, .style = .string },
        .{ .start_byte = 4, .end_byte = 6, .style = .punctuation },
    }, spans.items);
}

test "ANSI-C quotes distinguish valid and invalid unicode escapes" {
    const source = "$'foo\\xbar\\udeadbeef\\uzzzz'";
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try appendAnsiCEscapes(&spans, std.testing.allocator, source, 0, source.len);
    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 5, .end_byte = 9, .style = .variable },
        .{ .start_byte = 10, .end_byte = 16, .style = .variable },
        .{ .start_byte = 20, .end_byte = 22, .style = .unknown_token },
    }, spans.items);
}
