const std = @import("std");
const corpus = @import("corpus.zig");
const Engine = @import("engine.zig").Engine;
const max_capture_count = @import("engine.zig").max_capture_count;
const Snapshot = @import("snapshot.zig").Snapshot;
const Span = @import("span.zig").Span;

test {
    _ = @import("edit.zig");
    _ = @import("snapshot.zig");
    _ = @import("span.zig");
    _ = @import("style.zig");
}

test "engine produces structural highlights" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    var result = try engine.highlight("if true; then echo \"hello $USER\"; fi # note");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.has_parse_error);
    try expectStyle(result.spans, .keyword);
    try expectStyle(result.spans, .function);
    try expectStyle(result.spans, .string);
    try expectStyle(result.spans, .variable);
    try expectStyle(result.spans, .comment);
}

test "baseline corpus parses within structural limits" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    for (corpus.cases) |case| {
        var result = try engine.highlight(case.source);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.metrics.capture_count <= max_capture_count);
        try std.testing.expect(result.spans.len <= max_capture_count);
        for (result.spans) |span| {
            try std.testing.expect(span.start_byte < span.end_byte);
            try std.testing.expect(span.end_byte <= case.source.len);
        }
    }
}

test "incremental parsing agrees with a clean parse" {
    var incremental = try Engine.init(std.testing.allocator);
    defer incremental.deinit();
    var clean = try Engine.init(std.testing.allocator);
    defer clean.deinit();

    var first = try incremental.highlight("echo one\necho two");
    first.deinit(std.testing.allocator);
    var edited = try incremental.highlight("echo one\nprintf \"two $USER\"");
    defer edited.deinit(std.testing.allocator);

    var expected = try clean.highlight("echo one\nprintf \"two $USER\"");
    defer expected.deinit(std.testing.allocator);

    try std.testing.expect(edited.metrics.incremental);
    try std.testing.expectEqualSlices(Span, expected.spans, edited.spans);
}

test "incremental trees agree with clean parses across edit positions" {
    const inputs = [_][]const u8{
        "echo one\necho two",
        "echo one\necho three",
        "if true; then echo one\necho three; fi",
        "if true; then print one\necho three; fi",
        "if true; then print 'é🙂'\necho three; fi",
        "print 'é🙂'",
        "",
    };

    var incremental = try Engine.init(std.testing.allocator);
    defer incremental.deinit();

    for (inputs) |source| {
        var incremental_result = try incremental.highlight(source);
        defer incremental_result.deinit(std.testing.allocator);

        var clean = try Engine.init(std.testing.allocator);
        defer clean.deinit();
        var clean_result = try clean.highlight(source);
        defer clean_result.deinit(std.testing.allocator);

        try std.testing.expectEqualSlices(Span, clean_result.spans, incremental_result.spans);

        const incremental_tree = try incremental.treeSExpression(std.testing.allocator);
        defer std.testing.allocator.free(incremental_tree);
        const clean_tree = try clean.treeSExpression(std.testing.allocator);
        defer std.testing.allocator.free(clean_tree);
        try std.testing.expectEqualStrings(clean_tree, incremental_tree);
    }
}

test "known scanner overflow input is safe" {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);
    for (0..256) |_| try source.appendSlice(std.testing.allocator, "${");

    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var result = try engine.highlight(source.items);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.has_parse_error);
}

test "empty no-slash regex token cannot wedge the parser" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var result = try engine.highlight("c=${x//[^)]}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.spans.len > 0);
}

test "repeated incremental edits retain stable offsets" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const inputs = [_][]const u8{
        "e",
        "ec",
        "ech",
        "echo",
        "echo ",
        "echo $",
        "echo $U",
        "echo $US",
        "echo $USE",
        "echo $USER",
        "echo \"$USER\"",
        "if echo \"$USER\"; then print ok; fi",
    };

    for (inputs) |source| {
        var result = try engine.highlight(source);
        defer result.deinit(std.testing.allocator);
        for (result.spans) |span| {
            try std.testing.expect(span.start_byte < span.end_byte);
            try std.testing.expect(span.end_byte <= source.len);
        }
    }
}

fn expectStyle(spans: []const Span, expected: @import("style.zig").Style) !void {
    for (spans) |span| {
        if (span.style == expected) return;
    }
    return error.StyleNotFound;
}

test "UTF-8 snapshots expose character offsets for regions" {
    var snapshot = try Snapshot.fromUtf8(std.testing.allocator, "echo \"é🙂\"");
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 8), try snapshot.zleOffset(12));
}

test "engine releases every allocator-owned partial result" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runHighlightAllocationSequence,
        .{},
    );
}

fn runHighlightAllocationSequence(allocator: std.mem.Allocator) !void {
    var engine = try Engine.init(allocator);
    defer engine.deinit();

    var first = try engine.highlight("echo one");
    first.deinit(allocator);
    var second = try engine.highlight("if true; then echo \"$USER\"; fi");
    defer second.deinit(allocator);
}
