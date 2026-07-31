const std = @import("std");
const tree_sitter = @import("tree-sitter");

pub fn between(old_source: []const u8, new_source: []const u8) ?tree_sitter.InputEdit {
    if (std.mem.eql(u8, old_source, new_source)) return null;

    var start = commonPrefixLength(old_source, new_source);
    while (start > 0 and !isCodepointBoundary(old_source, start)) start -= 1;
    while (start > 0 and !isCodepointBoundary(new_source, start)) start -= 1;

    var suffix = commonSuffixLength(old_source[start..], new_source[start..]);
    while (suffix > 0 and
        (!isCodepointBoundary(old_source, old_source.len - suffix) or
            !isCodepointBoundary(new_source, new_source.len - suffix)))
    {
        suffix -= 1;
    }

    const old_end = old_source.len - suffix;
    const new_end = new_source.len - suffix;

    return .{
        .start_byte = @intCast(start),
        .old_end_byte = @intCast(old_end),
        .new_end_byte = @intCast(new_end),
        .start_point = pointAt(old_source, start),
        .old_end_point = pointAt(old_source, old_end),
        .new_end_point = pointAt(new_source, new_end),
    };
}

fn commonPrefixLength(left: []const u8, right: []const u8) usize {
    const limit = @min(left.len, right.len);
    var index: usize = 0;
    while (index < limit and left[index] == right[index]) : (index += 1) {}
    return index;
}

fn commonSuffixLength(left: []const u8, right: []const u8) usize {
    const limit = @min(left.len, right.len);
    var length: usize = 0;
    while (length < limit and left[left.len - length - 1] == right[right.len - length - 1]) : (length += 1) {}
    return length;
}

fn isCodepointBoundary(source: []const u8, offset: usize) bool {
    return offset == source.len or source[offset] & 0b1100_0000 != 0b1000_0000;
}

fn pointAt(source: []const u8, offset: usize) tree_sitter.Point {
    var row: u32 = 0;
    var column: u32 = 0;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            row += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    return .{ .row = row, .column = column };
}

test "edit describes a multiline replacement" {
    const edit = between("echo one\necho two", "echo one\nprintf two").?;
    try std.testing.expectEqual(@as(u32, 9), edit.start_byte);
    try std.testing.expectEqual(tree_sitter.Point{ .row = 1, .column = 0 }, edit.start_point);
    try std.testing.expectEqual(tree_sitter.Point{ .row = 1, .column = 4 }, edit.old_end_point);
    try std.testing.expectEqual(tree_sitter.Point{ .row = 1, .column = 6 }, edit.new_end_point);
}

test "edit boundaries never split UTF-8 codepoints" {
    const edit = between("print é", "print ê").?;
    try std.testing.expectEqual(@as(u32, 6), edit.start_byte);
    try std.testing.expectEqual(@as(u32, 8), edit.old_end_byte);
    try std.testing.expectEqual(@as(u32, 8), edit.new_end_byte);
}
