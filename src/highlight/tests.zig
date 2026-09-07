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
    _ = @import("redirection.zig");
    _ = @import("recovery.zig");
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

test "AST-driven recovery keeps valid Zsh extensions highlighted" {
    const source = "() { external }\n{ ls } always { pwd }\n: \"$$\"";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    var result = try engine.highlight(source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.has_parse_error);
    try expectStyle(result.spans, .recovered_keyword);
    try expectStyle(result.spans, .recovered_variable);
}

test "AST-driven recovery ignores extension-shaped text in literals" {
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    var result = try engine.highlight("print '() { external }'");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.has_parse_error);
    try expectNoStyle(result.spans, .recovered_keyword);
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

test "semantic analysis exposes expansion intent independently from styles" {
    const source = "ll; $context";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    var analysis = try semantic.analyze(std.testing.allocator, source, try engine.rootNode(), &state);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), analysis.expansion_candidates.len);
    try std.testing.expectEqual(@as(u32, 0), analysis.expansion_candidates[0].start_byte);
    try std.testing.expectEqual(@as(u32, 2), analysis.expansion_candidates[0].end_byte);
    try std.testing.expectEqual(semantic.AliasKind.regular, analysis.expansion_candidates[0].kind.alias);
    try std.testing.expectEqual(@as(u32, 4), analysis.expansion_candidates[1].start_byte);
    try std.testing.expectEqual(@as(u32, 12), analysis.expansion_candidates[1].end_byte);
    try std.testing.expect(analysis.expansion_candidates[1].kind == .safe_scalar_parameter);
}

test "semantic analysis exposes only shell command positions" {
    const source = "python myscript.py; echo python; echo quoted | python3; echo $(python2 task.py)";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    var analysis = try semantic.analyze(std.testing.allocator, source, try engine.rootNode(), &state);
    defer analysis.deinit(std.testing.allocator);

    const expected = [_][]const u8{ "python", "echo", "echo", "python3", "echo", "python2" };
    try std.testing.expectEqual(expected.len, analysis.commands.len);
    for (analysis.commands, expected) |command, expected_text| {
        try std.testing.expectEqualStrings(expected_text, command.text(source).?);
    }
}

test "command words deduplicate in first-occurrence order at paste scale" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    var commands: std.ArrayList(semantic.Command) = .empty;
    defer commands.deinit(allocator);
    for (0..20_000) |index| {
        var buffer: [32]u8 = undefined;
        const word = try std.fmt.bufPrint(&buffer, "command{d}", .{index});
        const start = source.items.len;
        try source.appendSlice(allocator, word);
        try commands.append(allocator, .{ .start_byte = @intCast(start), .end_byte = @intCast(source.items.len) });
        try source.append(allocator, ';');
    }
    for (0..10) |index| try commands.append(allocator, commands.items[index]);
    const words = try semantic.copyCommandWords(allocator, source.items, commands.items);
    defer {
        for (words) |word| allocator.free(word);
        allocator.free(words);
    }
    try std.testing.expectEqual(@as(usize, 20_000), words.len);
    try std.testing.expectEqualStrings("command0", words[0]);
    try std.testing.expectEqualStrings("command19999", words[words.len - 1]);
}

test "recovered command positions feed command metadata too" {
    for ([_][]const u8{ "`external README.md", "() external", "foo=bar ! external" }) |source| {
        var engine = try Engine.init(std.testing.allocator);
        defer engine.deinit();
        var syntax = try engine.highlight(source);
        defer syntax.deinit(std.testing.allocator);
        const state = FakeSemanticState{};
        var analysis = try semantic.analyze(std.testing.allocator, source, try engine.rootNode(), &state);
        defer analysis.deinit(std.testing.allocator);
        var found = false;
        for (analysis.commands) |command| {
            if (command.text(source)) |word| {
                if (std.mem.eql(u8, word, "external")) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "quoted command words retain command semantics" {
    const source = "\"missing\"";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "\"missing\"", .unknown_command);
}

test "unclosed backquotes recover their command and path context" {
    const source = "`external README.md";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "external", .recovered_command);
    try expectSemanticSpan(source, actual, "README.md", .recovered_path);
}

test "anonymous function markers recover their immediate command" {
    const source = "() external";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "external", .recovered_command);
}

test "assignments before brace groups retain structural error context" {
    const source = "foo=bar { :; }";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "{", .recovered_unknown);
    try expectSemanticSpan(source, actual, "}", .recovered_keyword);
}

test "assignments before escaped negation recover the following command" {
    const source = "foo=bar ! :";
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    var syntax = try engine.highlight(source);
    defer syntax.deinit(std.testing.allocator);

    const state = FakeSemanticState{};
    const actual = try semantic.highlight(std.testing.allocator, source, try engine.rootNode(), &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "!", .recovered_unknown);
    try expectSemanticSpan(source, actual, ":", .recovered_command);
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

test "alias analysis reports commands after bounded expansion" {
    var alias_engine = try AliasEngine.init(std.testing.allocator);
    defer alias_engine.deinit();
    const state = FakeSemanticState{};

    var direct = try alias_engine.analyze("py app.py", &state);
    defer direct.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), direct.commands.len);
    try std.testing.expectEqualStrings("python", direct.commands[0]);

    var argument = try alias_engine.analyze("say", &state);
    defer argument.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), argument.commands.len);
    try std.testing.expectEqualStrings("print", argument.commands[0]);
}

test "safe scalar parameters may reveal a following command" {
    const source = "$context external";
    var alias_engine = try AliasEngine.init(std.testing.allocator);
    defer alias_engine.deinit();

    const state = FakeSemanticState{};
    const actual = try alias_engine.highlight(source, &state);
    defer std.testing.allocator.free(actual);

    try expectSemanticSpan(source, actual, "external", .recovered_command);
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

fn expectNoStyle(spans: []const Span, unexpected: Style) !void {
    for (spans) |span| {
        if (span.style == unexpected) return error.UnexpectedStyle;
    }
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
                std.mem.eql(u8, word, "py") or
                std.mem.eql(u8, word, "say") or
                std.mem.eql(u8, word, "redirect") or
                std.mem.eql(u8, word, "cycle-a") or
                std.mem.eql(u8, word, "cycle-b") or
                std.mem.eql(u8, word, "time") or
                std.mem.eql(u8, word, "$foo"))) return .regular;
        if (command_position and std.mem.endsWith(u8, word, ".txt")) return .suffix;
        return null;
    }

    pub fn commandKind(_: *const FakeSemanticState, word: []const u8) semantic.CommandKind {
        if (std.mem.eql(u8, word, ":") or
            std.mem.eql(u8, word, "sudo") or
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
        else if (std.mem.eql(u8, word, "py"))
            "python"
        else if (std.mem.eql(u8, word, "say"))
            "print python"
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

    pub fn commandParameterExpansion(_: *const FakeSemanticState, allocator: std.mem.Allocator, word: []const u8) !?[]u8 {
        if (!std.mem.eql(u8, word, "$context")) return null;
        return try allocator.dupe(u8, "()");
    }

    pub fn commentsEnabled(_: *const FakeSemanticState) bool {
        return false;
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
    var analysis = try semantic.analyze(allocator, source, try engine.rootNode(), &state);
    defer analysis.deinit(allocator);
}

fn runAliasExpansionAllocationSequence(allocator: std.mem.Allocator) !void {
    const source = "separator missing; redirect output; print PIPE external; cycle-a";
    var alias_engine = try AliasEngine.init(allocator);
    defer alias_engine.deinit();

    const state = FakeSemanticState{};
    const projected = try alias_engine.highlight(source, &state);
    defer allocator.free(projected);
}
