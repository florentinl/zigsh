const std = @import("std");
const AliasEngine = @import("alias_expansion.zig").Engine;
const corpus = @import("corpus.zig");
const Engine = @import("engine.zig").Engine;
const max_capture_count = @import("engine.zig").max_capture_count;
const semantic = @import("semantic.zig");
const Snapshot = @import("snapshot.zig").Snapshot;
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

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

test "semantic scanner classifies commands, precommands, aliases, and paths" {
    const source = "ll README.md; sudo -u root print G !42; helper; reserved; hashed; external; auto-dir; snapshot.txt; missing";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "ll", .alias);
    try expectSemanticSpan(source, actual, "README.md", .path);
    try expectSemanticSpan(source, actual, "sudo", .precommand);
    try expectSemanticSpan(source, actual, "print", .builtin);
    try expectSemanticSpan(source, actual, "G", .global_alias);
    try expectSemanticSpan(source, actual, "!42", .history_expansion);
    try expectSemanticSpan(source, actual, "helper", .shell_function);
    try expectSemanticSpan(source, actual, "reserved", .keyword);
    try expectSemanticSpan(source, actual, "hashed", .hashed_command);
    try expectSemanticSpan(source, actual, "external", .external_command);
    try expectSemanticSpan(source, actual, "auto-dir", .auto_directory);
    try expectSemanticSpan(source, actual, "snapshot.txt", .suffix_alias);
    try expectSemanticSpan(source, actual, "missing", .unknown_command);
}

test "history expansion scanner respects quoting and escaping" {
    const source = "print foo!$ \"!42\" '!no' \\!escaped";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "!$", .history_expansion);
    try expectSemanticSpan(source, actual, "!42", .history_expansion);

    var history_span_count: usize = 0;
    for (actual) |span| {
        if (span.style == .history_expansion) history_span_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), history_span_count);
}

test "aliases take precedence over reserved words" {
    const source = "time external";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "time", .alias);
    try expectNoSemanticSpan(source, actual, "time", .keyword);
}

test "aliases may contain parameter syntax" {
    const source = "$foo";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "$foo", .alias);
}

test "alias expansion projects changed command context onto original tokens" {
    const source = "separator missing; redirect output; print PIPE external; cycle-a";
    var alias_engine = try AliasEngine.init(std.testing.allocator);
    defer alias_engine.deinit();

    const state = FakeSemanticState{};
    const actual = try alias_engine.highlight(source, &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "missing", .unknown_command);
    try expectSemanticSpan(source, actual, "output", .path);
    try expectSemanticSpan(source, actual, "external", .external_command);
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

fn expectStyle(spans: []const Span, expected: Style) !void {
    for (spans) |span| {
        if (span.style == expected) return;
    }
    return error.StyleNotFound;
}

fn expectSemanticSpan(source: []const u8, spans: []const Span, text: []const u8, style: Style) !void {
    const start = std.mem.indexOf(u8, source, text) orelse return error.TextNotFound;
    for (spans) |span| {
        if (span.start_byte == start and span.end_byte == start + text.len and span.style == style) return;
    }
    return error.SemanticSpanNotFound;
}

fn expectNoSemanticSpan(source: []const u8, spans: []const Span, text: []const u8, style: Style) !void {
    const start = std.mem.indexOf(u8, source, text) orelse return error.TextNotFound;
    for (spans) |span| {
        if (span.start_byte == start and span.end_byte == start + text.len and span.style == style) {
            return error.UnexpectedSemanticSpan;
        }
    }
}

const FakeSemanticState = struct {
    pub fn aliasKind(_: *const FakeSemanticState, word: []const u8, command_position: bool) ?semantic.AliasKind {
        if (std.mem.eql(u8, word, "G")) return .global;
        if (std.mem.eql(u8, word, "PIPE")) return .global;
        if (command_position and std.mem.eql(u8, word, "ll")) return .regular;
        if (command_position and
            (std.mem.eql(u8, word, "separator") or
                std.mem.eql(u8, word, "redirect") or
                std.mem.eql(u8, word, "cycle-a") or
                std.mem.eql(u8, word, "cycle-b") or
                std.mem.eql(u8, word, "time") or
                std.mem.eql(u8, word, "$foo"))) return .regular;
        if (command_position and std.mem.endsWith(u8, word, ".txt")) return .suffix;
        return null;
    }

    pub fn commandKind(_: *const FakeSemanticState, word: []const u8) semantic.CommandKind {
        if (std.mem.eql(u8, word, "sudo") or
            std.mem.eql(u8, word, "print") or
            std.mem.eql(u8, word, "ll")) return .builtin;
        if (std.mem.eql(u8, word, "helper")) return .shell_function;
        if (std.mem.eql(u8, word, "reserved")) return .reserved_word;
        if (std.mem.eql(u8, word, "hashed")) return .hashed_command;
        if (std.mem.eql(u8, word, "external")) return .external_command;
        if (std.mem.eql(u8, word, "auto-dir")) return .auto_directory;
        return .unknown;
    }

    pub fn regularAliasExpandsNext(_: *const FakeSemanticState, word: []const u8) bool {
        return std.mem.eql(u8, word, "ll");
    }

    pub fn aliasExpansion(
        _: *const FakeSemanticState,
        allocator: std.mem.Allocator,
        word: []const u8,
        _: semantic.AliasKind,
    ) !?[]u8 {
        const expansion = if (std.mem.eql(u8, word, "separator"))
            "print ok;"
        else if (std.mem.eql(u8, word, "redirect"))
            "print hi >"
        else if (std.mem.eql(u8, word, "PIPE"))
            "|"
        else if (std.mem.eql(u8, word, "cycle-a"))
            "cycle-b"
        else if (std.mem.eql(u8, word, "cycle-b"))
            "cycle-a"
        else if (std.mem.eql(u8, word, "$foo"))
            "print alias"
        else
            return null;
        return try allocator.dupe(u8, expansion);
    }

    pub fn pathKind(_: *const FakeSemanticState, word: []const u8, _: bool, _: bool) semantic.PathKind {
        return if (std.mem.eql(u8, word, "README.md") or std.mem.eql(u8, word, "output")) .path else .none;
    }

    pub fn historyEnabled(_: *const FakeSemanticState) bool {
        return true;
    }

    pub fn historyCharacter(_: *const FakeSemanticState) u8 {
        return '!';
    }
};

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

test "semantic scanner releases every allocator-owned partial result" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runSemanticAllocationSequence,
        .{},
    );
}

test "alias expansion releases every allocator-owned partial result" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runAliasExpansionAllocationSequence,
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

fn runSemanticAllocationSequence(allocator: std.mem.Allocator) !void {
    const source = "ll README.md; sudo -u root print G !42; helper; reserved; hashed; external; auto-dir; snapshot.txt; missing";
    var engine = try Engine.init(allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(allocator);

    const state = FakeSemanticState{};
    const semantic_spans = try semantic.highlight(allocator, source, try engine.rootNode(), &state);
    defer allocator.free(semantic_spans);
}

fn runAliasExpansionAllocationSequence(allocator: std.mem.Allocator) !void {
    const source = "separator missing; redirect output; print PIPE external; cycle-a";
    var alias_engine = try AliasEngine.init(allocator);
    defer alias_engine.deinit();

    const state = FakeSemanticState{};
    const projected = try alias_engine.highlight(source, &state);
    defer allocator.free(projected);
}
