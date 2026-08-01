const std = @import("std");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

pub fn operatorSpan(source: []const u8, start_byte: u32, end_byte: u32) ?Span {
    const start: usize = start_byte;
    const limit: usize = @min(end_byte, source.len);
    const end = operatorEnd(source, start, limit) orelse return null;
    return .{
        .start_byte = start_byte,
        .end_byte = @intCast(end),
        .style = .redirection,
    };
}

fn operatorEnd(source: []const u8, start: usize, limit: usize) ?usize {
    var index = start;
    while (index < limit and std.ascii.isDigit(source[index])) : (index += 1) {}
    if (index == limit) return null;

    return switch (source[index]) {
        '<' => inputEnd(source, index, limit),
        '>' => outputEnd(source, index, limit),
        '&' => combinedOutputEnd(source, index, limit),
        else => null,
    };
}

fn inputEnd(source: []const u8, start: usize, limit: usize) ?usize {
    var index = start + 1;
    if (index == limit) return index;
    switch (source[index]) {
        '&', '>' => return index + 1,
        '<' => {
            index += 1;
            if (index < limit and (source[index] == '<' or source[index] == '-')) index += 1;
            return index;
        },
        else => return index,
    }
}

fn outputEnd(source: []const u8, start: usize, limit: usize) ?usize {
    var index = start + 1;
    if (index < limit and source[index] == '>') index += 1;
    if (index < limit and source[index] == '&') index += 1;
    if (index < limit and (source[index] == '|' or source[index] == '!')) index += 1;
    return index;
}

fn combinedOutputEnd(source: []const u8, start: usize, limit: usize) ?usize {
    var index = start + 1;
    if (index == limit or source[index] != '>') return null;
    index += 1;
    if (index < limit and source[index] == '>') index += 1;
    if (index < limit and (source[index] == '|' or source[index] == '!')) index += 1;
    return index;
}

test "redirection operators include source descriptors and clobber modifiers" {
    const cases = [_]struct { source: []const u8, expected_end: u32 }{
        .{ .source = "<foo", .expected_end = 1 },
        .{ .source = "9<>foo", .expected_end = 3 },
        .{ .source = ">!foo", .expected_end = 2 },
        .{ .source = ">>&!foo", .expected_end = 4 },
        .{ .source = "&>>|foo", .expected_end = 4 },
        .{ .source = "<<<foo", .expected_end = 3 },
        .{ .source = "<&-", .expected_end = 2 },
    };

    for (cases) |case| {
        const actual = operatorSpan(case.source, 0, @intCast(case.source.len)).?;
        try std.testing.expectEqual(@as(u32, 0), actual.start_byte);
        try std.testing.expectEqual(case.expected_end, actual.end_byte);
        try std.testing.expectEqual(Style.redirection, actual.style);
    }
}
