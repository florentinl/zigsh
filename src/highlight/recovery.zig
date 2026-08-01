const std = @import("std");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

pub fn append(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
) !void {
    try appendAnonymousFunctionMarker(spans, allocator, source);
    try appendAlwaysBlocks(spans, allocator, source);
    try appendDoubleDollarParameters(spans, allocator, source);
}

fn appendDoubleDollarParameters(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
) !void {
    var opening: ?usize = null;
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            continue;
        }
        if (source[index] != '"') continue;
        if (opening) |start| {
            try appendDoubleDollarQuote(spans, allocator, source, start, index + 1);
            opening = null;
        } else {
            opening = index;
        }
    }
}

fn appendDoubleDollarQuote(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
) !void {
    const text = source[start..end];
    if (std.mem.indexOf(u8, text, "$$") == null) return;

    try spans.append(allocator, .{
        .start_byte = @intCast(start),
        .end_byte = @intCast(end),
        .style = .recovered_string,
    });
    var index: usize = start + 1;
    while (index + 1 < end) : (index += 1) {
        if (source[index] != '$' or source[index + 1] != '$') continue;
        try spans.append(allocator, .{
            .start_byte = @intCast(index),
            .end_byte = @intCast(index + 2),
            .style = .recovered_variable,
        });
        index += 1;
    }
}

fn appendAnonymousFunctionMarker(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
) !void {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_start, "()")) |marker| {
        search_start = marker + 2;
        if (!isAnonymousFunctionMarker(source, marker)) continue;
        try appendKeyword(spans, allocator, marker, marker + 2);

        const open = nextNonWhitespace(source, marker + 2) orelse continue;
        if (source[open] != '{') continue;
        try appendKeyword(spans, allocator, open, open + 1);
        if (nextCloseBrace(source, open + 1)) |close| {
            try appendKeyword(spans, allocator, close, close + 1);
        }
    }
}

fn isAnonymousFunctionMarker(source: []const u8, marker: usize) bool {
    if (marker == 0) return true;
    return switch (source[marker - 1]) {
        ' ', '\t', '\r', '\n', ';', '|', '&', '{', '}' => true,
        else => false,
    };
}

fn appendAlwaysBlocks(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
) !void {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_start, "always")) |start| {
        search_start = start + "always".len;
        if (!isWordBoundary(source, start, search_start)) continue;

        const close = previousNonWhitespace(source, start) orelse continue;
        if (source[close] != '}') continue;
        const open = previousOpenBrace(source, close) orelse continue;
        if (!isCommandBoundary(source, open)) continue;
        const next_open = nextNonWhitespace(source, search_start) orelse continue;
        if (source[next_open] != '{') continue;
        const next_close = nextCloseBrace(source, next_open + 1) orelse continue;

        try appendKeyword(spans, allocator, open, open + 1);
        try appendKeyword(spans, allocator, close, close + 1);
        try appendKeyword(spans, allocator, start, search_start);
        try appendKeyword(spans, allocator, next_open, next_open + 1);
        try appendKeyword(spans, allocator, next_close, next_close + 1);
    }
}

fn appendKeyword(spans: *std.ArrayList(Span), allocator: std.mem.Allocator, start: usize, end: usize) !void {
    try spans.append(allocator, .{
        .start_byte = @intCast(start),
        .end_byte = @intCast(end),
        .style = .recovered_keyword,
    });
}

fn isWordBoundary(source: []const u8, start: usize, end: usize) bool {
    return (start == 0 or !isWordCharacter(source[start - 1])) and
        (end == source.len or !isWordCharacter(source[end]));
}

fn isWordCharacter(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn previousNonWhitespace(source: []const u8, start: usize) ?usize {
    var index = start;
    while (index > 0) {
        index -= 1;
        if (!std.ascii.isWhitespace(source[index])) return index;
    }
    return null;
}

fn nextNonWhitespace(source: []const u8, start: usize) ?usize {
    var index = start;
    while (index < source.len) : (index += 1) {
        if (!std.ascii.isWhitespace(source[index])) return index;
    }
    return null;
}

fn previousOpenBrace(source: []const u8, close: usize) ?usize {
    var index = close;
    while (index > 0) {
        index -= 1;
        if (source[index] == '{') return index;
    }
    return null;
}

fn nextCloseBrace(source: []const u8, start: usize) ?usize {
    for (source[start..], start..) |byte, index| {
        if (byte == '}') return index;
    }
    return null;
}

fn isCommandBoundary(source: []const u8, open: usize) bool {
    const previous = previousNonWhitespace(source, open) orelse return true;
    return switch (source[previous]) {
        ';', '\n', '{', '}', '(', ')', '|', '&' => true,
        else => false,
    };
}

test "always blocks recover only from command-position brace groups" {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try append(&spans, std.testing.allocator, "{ ls } always { pwd }");
    try std.testing.expectEqual(@as(usize, 5), spans.items.len);

    spans.clearRetainingCapacity();
    try append(&spans, std.testing.allocator, "echo { foo } always { bar }");
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "anonymous function markers recover at the start of a buffer" {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try append(&spans, std.testing.allocator, "() { echo foo )");
    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 0, .end_byte = 2, .style = .recovered_keyword },
        .{ .start_byte = 3, .end_byte = 4, .style = .recovered_keyword },
    }, spans.items);
}

test "double dollars retain their quoted string and parameter layers" {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(std.testing.allocator);

    try append(&spans, std.testing.allocator, ": \"$$ $$foo\"");
    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 2, .end_byte = 12, .style = .recovered_string },
        .{ .start_byte = 3, .end_byte = 5, .style = .recovered_variable },
        .{ .start_byte = 6, .end_byte = 8, .style = .recovered_variable },
    }, spans.items);
}
