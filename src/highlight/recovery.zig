const std = @import("std");
const tree_sitter = @import("tree-sitter");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

pub fn append(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
) !void {
    try appendInRange(spans, allocator, source, 0, source.len);
}

pub fn appendFromTree(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    root: tree_sitter.Node,
) !void {
    try appendForNode(spans, allocator, source, root);
}

fn appendForNode(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    node: tree_sitter.Node,
) !void {
    const start = node.startByte();
    const end = node.endByte();
    if (std.mem.eql(u8, node.kind(), "ERROR")) {
        try appendInRange(spans, allocator, source, start, end);
        return;
    }
    if (std.mem.eql(u8, node.kind(), "function_definition")) {
        try appendAnonymousFunctionMarker(spans, allocator, source, start, end);
    }
    if (std.mem.eql(u8, node.kind(), "always_clause")) {
        try appendAlwaysBlocks(spans, allocator, source, start, end);
    }
    if (std.mem.eql(u8, node.kind(), "string")) {
        try appendDoubleDollarParameters(spans, allocator, source, start, end);
    }

    var child_index: u32 = 0;
    while (child_index < node.childCount()) : (child_index += 1) {
        try appendForNode(spans, allocator, source, node.child(child_index).?);
    }
}

fn appendInRange(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
) !void {
    try appendAnonymousFunctionMarker(spans, allocator, source, start, end);
    try appendAlwaysBlocks(spans, allocator, source, start, end);
    try appendDoubleDollarParameters(spans, allocator, source, start, end);
}

fn appendDoubleDollarParameters(
    spans: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
) !void {
    var opening: ?usize = null;
    var index: usize = start;
    while (index < end) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            continue;
        }
        if (source[index] != '"') continue;
        if (opening) |opening_start| {
            try appendDoubleDollarQuote(spans, allocator, source, opening_start, index + 1);
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
    start: usize,
    end: usize,
) !void {
    var search_start = start;
    while (std.mem.indexOfPos(u8, source[0..end], search_start, "()")) |marker| {
        search_start = marker + 2;
        if (!isAnonymousFunctionMarker(source, marker)) continue;
        try appendKeyword(spans, allocator, marker, marker + 2);

        const open = nextNonWhitespaceBefore(source, marker + 2, end) orelse continue;
        if (source[open] != '{') continue;
        try appendKeyword(spans, allocator, open, open + 1);
        if (nextCloseBraceBefore(source, open + 1, end)) |close| {
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
    range_start: usize,
    range_end: usize,
) !void {
    var search_start = range_start;
    while (std.mem.indexOfPos(u8, source[0..range_end], search_start, "always")) |start| {
        search_start = start + "always".len;
        if (!isWordBoundary(source, start, search_start)) continue;

        const close = previousNonWhitespace(source, start) orelse continue;
        if (source[close] != '}') continue;
        const open = previousOpenBrace(source, close) orelse continue;
        if (!isCommandBoundary(source, open)) continue;
        const next_open = nextNonWhitespaceBefore(source, search_start, range_end) orelse continue;
        if (source[next_open] != '{') continue;
        const next_close = nextCloseBraceBefore(source, next_open + 1, range_end) orelse continue;

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

fn nextNonWhitespaceBefore(source: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
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

fn nextCloseBraceBefore(source: []const u8, start: usize, end: usize) ?usize {
    for (source[start..end], start..) |byte, index| {
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
