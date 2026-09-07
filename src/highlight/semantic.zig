const std = @import("std");
const tree_sitter = @import("tree-sitter");
const redirection = @import("redirection.zig");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

pub const AliasKind = enum { regular, global, suffix };

pub const CommandKind = enum {
    reserved_word,
    shell_function,
    builtin,
    hashed_command,
    external_command,
    auto_directory,
    unknown,
};

pub const PathKind = enum { none, path, prefix, invalid };

pub const ExpansionKind = union(enum) {
    alias: AliasKind,
    safe_scalar_parameter,
};

pub const ExpansionCandidate = struct {
    start_byte: u32,
    end_byte: u32,
    kind: ExpansionKind,
};

pub const Command = struct {
    start_byte: u32,
    end_byte: u32,

    pub fn text(self: Command, source: []const u8) ?[]const u8 {
        if (self.start_byte > self.end_byte or self.end_byte > source.len) return null;
        return literalCommandWord(source[self.start_byte..self.end_byte]);
    }
};

pub const Analysis = struct {
    spans: []Span,
    expansion_candidates: []ExpansionCandidate,
    commands: []Command,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.spans);
        allocator.free(self.expansion_candidates);
        allocator.free(self.commands);
        self.* = undefined;
    }
};

pub fn copyCommandWords(
    allocator: std.mem.Allocator,
    source: []const u8,
    commands: []const Command,
) ![][]u8 {
    var words = std.ArrayList([]u8).empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }
    // Keys borrow from source for this call only; output strings remain owned.
    // Keep first-occurrence order without quadratic scans on large pastes.
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (commands) |command| {
        const word = command.text(source) orelse continue;
        const entry = try seen.getOrPut(word);
        if (!entry.found_existing) {
            const owned = try allocator.dupe(u8, word);
            errdefer allocator.free(owned);
            try words.append(allocator, owned);
        }
    }
    return words.toOwnedSlice(allocator);
}

const Token = struct {
    node: ?tree_sitter.Node = null,
    start_byte: u32,
    end_byte: u32,

    fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start_byte..self.end_byte];
    }
};

pub fn highlight(
    allocator: std.mem.Allocator,
    source: []const u8,
    root: tree_sitter.Node,
    state: anytype,
) ![]Span {
    const analysis = try analyze(allocator, source, root, state);
    defer allocator.free(analysis.expansion_candidates);
    defer allocator.free(analysis.commands);
    return analysis.spans;
}

pub fn analyze(
    allocator: std.mem.Allocator,
    source: []const u8,
    root: tree_sitter.Node,
    state: anytype,
) !Analysis {
    var scanner = Scanner(@TypeOf(state)){
        .allocator = allocator,
        .source = source,
        .state = state,
    };
    errdefer scanner.spans.deinit(allocator);
    errdefer scanner.expansion_candidates.deinit(allocator);
    errdefer scanner.commands.deinit(allocator);
    try scanner.visit(root);
    const spans = try scanner.spans.toOwnedSlice(allocator);
    errdefer allocator.free(spans);
    const expansion_candidates = try scanner.expansion_candidates.toOwnedSlice(allocator);
    errdefer allocator.free(expansion_candidates);
    const commands = try scanner.commands.toOwnedSlice(allocator);
    return .{ .spans = spans, .expansion_candidates = expansion_candidates, .commands = commands };
}

fn Scanner(comptime State: type) type {
    return struct {
        allocator: std.mem.Allocator,
        source: []const u8,
        state: State,
        spans: std.ArrayList(Span) = .empty,
        expansion_candidates: std.ArrayList(ExpansionCandidate) = .empty,
        commands: std.ArrayList(Command) = .empty,

        const Self = @This();

        fn visit(self: *Self, node: tree_sitter.Node) !void {
            if (std.mem.eql(u8, node.kind(), "ERROR")) {
                try self.scanError(node);
                return;
            }
            if (std.mem.eql(u8, node.kind(), "command")) {
                try self.scanCommand(node);
                if (hasLeadingVariableAssignment(node)) {
                    try self.scanAssignmentBeforeReservedWord(
                        node.startByte(),
                        self.commandLineEnd(node.startByte()),
                    );
                }
            }
            if (std.mem.eql(u8, node.kind(), "file_redirect")) try self.scanRedirect(node);
            if (isReservedWord(node.kind())) try self.scanReservedWord(node);

            var child_index: u32 = 0;
            while (child_index < node.childCount()) : (child_index += 1) {
                try self.visit(node.child(child_index).?);
            }
        }

        fn scanReservedWord(self: *Self, node: tree_sitter.Node) !void {
            const token = tokenFor(node);
            if (self.state.aliasKind(token.text(self.source), true)) |kind| {
                try self.addAlias(token, kind);
                return;
            }
            try self.add(token, styleForCommandKind(self.state.commandKind(token.text(self.source))));
        }

        fn scanCommand(self: *Self, node: tree_sitter.Node) !void {
            const name_node = node.childByFieldName("name") orelse return;
            const name = tokenFor(name_node);
            var arguments = std.ArrayList(Token).empty;
            defer arguments.deinit(self.allocator);

            var child_index: u32 = 0;
            while (child_index < node.childCount()) : (child_index += 1) {
                const field_name = node.fieldNameForChild(child_index) orelse continue;
                if (!std.mem.eql(u8, field_name, "argument")) continue;
                try arguments.append(self.allocator, tokenFor(node.child(child_index).?));
            }

            var command_index: ?usize = null;
            var argument_start: usize = 0;
            var alias_argument_count: usize = 0;
            if (self.precommand(name)) |definition| {
                try self.add(name, .precommand);
                command_index = definition.followingCommand(arguments.items, self.source);
            } else {
                try self.scanCommandToken(name, true);
                try self.addCommand(name);
                if (self.state.aliasKind(name.text(self.source), true) == .regular and
                    self.state.regularAliasExpandsNext(name.text(self.source)))
                {
                    alias_argument_count = try self.scanFollowingAliases(arguments.items);
                }
            }

            while (command_index) |index| {
                const command = arguments.items[index];
                argument_start = index + 1;
                if (self.precommand(command)) |definition| {
                    try self.add(command, .precommand);
                    const relative = definition.followingCommand(arguments.items[index + 1 ..], self.source) orelse break;
                    command_index = index + 1 + relative;
                } else {
                    try self.scanCommandToken(command, false);
                    try self.addCommand(command);
                    break;
                }
            }

            const downstream_index: ?usize = if (argument_start == 0) null else argument_start - 1;
            for (arguments.items, 0..) |argument, index| {
                if (index < alias_argument_count) continue;
                if (downstream_index == null or index != downstream_index.?) {
                    try self.scanExpansions(argument);
                }
            }
            const path_argument_start = @max(argument_start, alias_argument_count);
            for (arguments.items[path_argument_start..]) |argument| {
                try self.scanPath(argument);
            }
        }

        fn scanFollowingAliases(self: *Self, arguments: []const Token) !usize {
            var count: usize = 0;
            while (count < arguments.len) {
                const argument = arguments[count];
                const text = argument.text(self.source);
                const kind = self.state.aliasKind(text, true) orelse break;
                if (kind == .suffix) break;
                try self.addAlias(argument, kind);
                count += 1;
                if (kind != .regular or !self.state.regularAliasExpandsNext(text)) break;
            }
            return count;
        }

        fn scanCommandToken(self: *Self, token: Token, allow_regular_alias: bool) !void {
            const text = token.text(self.source);
            if (self.state.aliasKind(text, allow_regular_alias)) |kind| {
                try self.addAlias(token, kind);
                return;
            }

            if (isSimpleParameterExpression(text)) {
                try self.add(token, .variable);
                try self.addParameterExpansion(token);
                return;
            }

            const command = literalCommandWord(text) orelse return;

            const command_kind = self.state.commandKind(command);
            if (command_kind == .unknown) {
                switch (self.state.pathKind(command, token.end_byte == self.source.len, true)) {
                    .path => {
                        try self.add(token, .external_command);
                        return;
                    },
                    .prefix => {
                        try self.add(token, .path_prefix);
                        return;
                    },
                    .none, .invalid => {},
                }
            }

            try self.add(token, styleForCommandKind(command_kind));
        }

        fn scanExpansions(self: *Self, token: Token) !void {
            const text = token.text(self.source);
            if (isLiteralWord(text)) {
                if (self.state.aliasKind(text, false)) |kind| {
                    if (kind == .global) try self.addAlias(token, kind);
                }
            }

            if (self.state.historyEnabled()) try self.scanHistory(token.node.?);
        }

        fn scanPath(self: *Self, token: Token) !void {
            const text = token.text(self.source);
            if (text.len > 1 and text[0] == '-') return;

            switch (self.state.pathKind(text, token.end_byte == self.source.len, false)) {
                .none => {},
                .path => try self.add(token, .path),
                .prefix => try self.add(token, .path_prefix),
                .invalid => try self.add(token, .unknown_token),
            }
        }

        fn scanRedirect(self: *Self, node: tree_sitter.Node) !void {
            if (redirection.operatorSpan(self.source, node.startByte(), node.endByte())) |operator| {
                try self.spans.append(self.allocator, operator);
            }
            var child_index: u32 = 0;
            while (child_index < node.childCount()) : (child_index += 1) {
                const field_name = node.fieldNameForChild(child_index) orelse continue;
                if (!std.mem.eql(u8, field_name, "destination")) continue;
                const destination = tokenFor(node.child(child_index).?);
                if (self.redirectTargetStyle(node, destination)) |style| {
                    try self.add(destination, style);
                    continue;
                }
                try self.scanExpansions(destination);
                switch (self.state.pathKind(destination.text(self.source), destination.end_byte == self.source.len, false)) {
                    .none => {},
                    .path => try self.add(destination, .path),
                    .prefix => try self.add(destination, .path_prefix),
                    .invalid => try self.add(destination, .unknown_token),
                }
            }
        }

        fn redirectTargetStyle(self: *Self, redirect: tree_sitter.Node, destination: Token) ?Style {
            const operator = self.source[redirect.startByte()..destination.start_byte];
            if (!std.mem.endsWith(u8, operator, "&")) return null;

            const target = destination.text(self.source);
            if (std.mem.eql(u8, target, "p") or std.mem.eql(u8, target, "-")) return .redirection;
            if (isDecimal(target)) return .plain;
            return null;
        }

        fn scanHistory(self: *Self, node: tree_sitter.Node) !void {
            const token = tokenFor(node);
            const text = token.text(self.source);
            const history_character = self.state.historyCharacter();
            var index: usize = 0;
            while (index < text.len) : (index += 1) {
                const source_index = token.start_byte + @as(u32, @intCast(index));
                if (text[index] != history_character or
                    isEscaped(text, index) or
                    historyDisabledAt(node, source_index)) continue;
                const end = historyExpansionEnd(text, index);
                try self.spans.append(self.allocator, .{
                    .start_byte = source_index,
                    .end_byte = token.start_byte + @as(u32, @intCast(end)),
                    .style = .history_expansion,
                });
                index = end - 1;
            }
        }

        fn scanError(self: *Self, node: tree_sitter.Node) !void {
            const start = node.startByte();
            const end = node.endByte();
            try self.scanUnclosedBackquotes(start, end);
            try self.scanAnonymousFunctionBodies(start, end);
        }

        fn commandLineEnd(self: *Self, start: usize) usize {
            return std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
        }

        fn scanUnclosedBackquotes(self: *Self, start: usize, end: usize) !void {
            var opening = start;
            while (opening < end) : (opening += 1) {
                if (self.source[opening] != '`' or isEscaped(self.source, opening)) continue;
                if (closingBackquoteBefore(self.source, opening + 1, end) != null) continue;

                const command_start = nextNonWhitespaceBefore(self.source, opening + 1, end) orelse return;
                const command_end = shellWordEndBefore(self.source, command_start, end);
                const command = Token{
                    .start_byte = @intCast(command_start),
                    .end_byte = @intCast(command_end),
                };
                if (isLiteralWord(command.text(self.source))) {
                    if (self.state.commandKind(command.text(self.source)) != .unknown) {
                        try self.add(command, .recovered_command);
                        try self.addCommand(command);
                    }
                }

                const argument_start = nextNonWhitespaceBefore(self.source, command_end, end) orelse return;
                const argument_end = shellWordEndBefore(self.source, argument_start, end);
                const argument = Token{
                    .start_byte = @intCast(argument_start),
                    .end_byte = @intCast(argument_end),
                };
                switch (self.state.pathKind(argument.text(self.source), true, false)) {
                    .path, .prefix => try self.add(argument, .recovered_path),
                    .none, .invalid => {},
                }
                return;
            }
        }

        fn scanAnonymousFunctionBodies(self: *Self, start: usize, end: usize) !void {
            var search_start = start;
            while (std.mem.indexOfPos(u8, self.source[0..end], search_start, "()")) |marker| {
                search_start = marker + 2;
                var command_start = nextNonWhitespaceBefore(self.source, search_start, end) orelse continue;
                if (self.source[command_start] == '{') {
                    command_start = nextNonWhitespaceBefore(self.source, command_start + 1, end) orelse continue;
                }
                const command_end = shellWordEndBefore(self.source, command_start, end);
                if (command_start == command_end) continue;
                const command = Token{
                    .start_byte = @intCast(command_start),
                    .end_byte = @intCast(command_end),
                };
                if (isLiteralWord(command.text(self.source)) and
                    self.state.commandKind(command.text(self.source)) != .unknown)
                {
                    try self.add(command, .recovered_command);
                    try self.addCommand(command);
                }
            }
        }

        fn scanAssignmentBeforeReservedWord(self: *Self, start: usize, end: usize) !void {
            const assignment_end = shellWordEndBefore(self.source, start, end);
            if (!isAssignment(self.source[start..assignment_end])) return;

            const opening = nextNonWhitespaceBefore(self.source, assignment_end, end) orelse return;
            switch (self.source[opening]) {
                '{' => {
                    try self.addRecoveredUnknown(opening, opening + 1);
                    const closing = start + (std.mem.lastIndexOfScalar(u8, self.source[start..end], '}') orelse return);
                    try self.addRecoveredKeyword(closing, closing + 1);
                },
                '(' => {
                    const arithmetic = opening + 1 < end and self.source[opening + 1] == '(';
                    const closing = if (arithmetic)
                        std.mem.lastIndexOf(u8, self.source[start..end], "))")
                    else
                        std.mem.lastIndexOfScalar(u8, self.source[start..end], ')');
                    if (arithmetic) {
                        const arithmetic_end = start + (closing orelse end - start);
                        try self.addRecoveredUnknown(opening, arithmetic_end + @min(@as(usize, 2), end - arithmetic_end));
                    } else {
                        try self.addRecoveredUnknown(opening, opening + 1);
                        if (closing) |offset| {
                            const closing_byte = start + offset;
                            try self.addRecoveredUnknown(closing_byte, closing_byte + 1);
                        }
                        try self.scanRecoveredCommand(opening + 1, end);
                    }
                },
                '!' => {
                    try self.addRecoveredUnknown(opening, opening + 1);
                    try self.scanRecoveredCommand(opening + 1, end);
                },
                '[' => {
                    if (opening + 1 >= end or self.source[opening + 1] != '[') return;
                    const closing = start + (std.mem.lastIndexOf(u8, self.source[start..end], "]]") orelse return);
                    try self.addRecoveredUnknown(opening, opening + 2);
                    try self.spans.append(self.allocator, .{
                        .start_byte = @intCast(opening + 2),
                        .end_byte = @intCast(closing),
                        .style = .recovered_plain,
                    });
                    const option_start = nextNonWhitespaceBefore(self.source, opening + 2, end) orelse return;
                    const option_end = shellWordEndBefore(self.source, option_start, end);
                    if (option_start < option_end and self.source[option_start] == '-') {
                        try self.spans.append(self.allocator, .{
                            .start_byte = @intCast(option_start),
                            .end_byte = @intCast(option_end),
                            .style = .test_option,
                        });
                    }
                    try self.addRecoveredKeyword(closing, closing + 2);
                },
                else => {},
            }
        }

        fn scanRecoveredCommand(self: *Self, start: usize, end: usize) !void {
            const command_start = nextNonWhitespaceBefore(self.source, start, end) orelse return;
            const command_end = shellWordEndBefore(self.source, command_start, end);
            if (command_start == command_end) return;
            const command = Token{
                .start_byte = @intCast(command_start),
                .end_byte = @intCast(command_end),
            };
            if (isLiteralWord(command.text(self.source)) and
                self.state.commandKind(command.text(self.source)) != .unknown)
            {
                try self.add(command, .recovered_command);
                try self.addCommand(command);
            }
        }

        fn addRecoveredUnknown(self: *Self, start: usize, end: usize) !void {
            try self.spans.append(self.allocator, .{
                .start_byte = @intCast(start),
                .end_byte = @intCast(end),
                .style = .recovered_unknown,
            });
        }

        fn addRecoveredKeyword(self: *Self, start: usize, end: usize) !void {
            try self.spans.append(self.allocator, .{
                .start_byte = @intCast(start),
                .end_byte = @intCast(end),
                .style = .recovered_keyword,
            });
        }

        fn precommand(self: *Self, token: Token) ?Precommand {
            const text = token.text(self.source);
            if (!isLiteralWord(text)) return null;
            const definition = Precommand.forName(text) orelse return null;
            if (std.mem.eql(u8, text, "-")) return definition;
            return if (self.state.commandKind(text) == .unknown) null else definition;
        }

        fn add(self: *Self, token: Token, style: Style) !void {
            try self.spans.append(self.allocator, .{
                .start_byte = token.start_byte,
                .end_byte = token.end_byte,
                .style = style,
            });
        }

        fn addAlias(self: *Self, token: Token, kind: AliasKind) !void {
            try self.add(token, switch (kind) {
                .regular => .alias,
                .global => .global_alias,
                .suffix => .suffix_alias,
            });
            try self.expansion_candidates.append(self.allocator, .{
                .start_byte = token.start_byte,
                .end_byte = token.end_byte,
                .kind = .{ .alias = kind },
            });
        }

        fn addParameterExpansion(self: *Self, token: Token) !void {
            try self.expansion_candidates.append(self.allocator, .{
                .start_byte = token.start_byte,
                .end_byte = token.end_byte,
                .kind = .safe_scalar_parameter,
            });
        }

        fn addCommand(self: *Self, token: Token) !void {
            if (literalCommandWord(token.text(self.source)) == null) return;
            try self.commands.append(self.allocator, .{
                .start_byte = token.start_byte,
                .end_byte = token.end_byte,
            });
        }
    };
}

const Precommand = struct {
    flags_with_argument: []const u8 = "",
    flags_sans_argument: []const u8 = "",
    flags_solo: []const u8 = "",
    permits_assignment: bool = false,

    fn forName(name: []const u8) ?Precommand {
        inline for (precommands) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.definition;
        }
        return null;
    }

    fn followingCommand(self: Precommand, arguments: []const Token, source: []const u8) ?usize {
        var index: usize = 0;
        while (index < arguments.len) {
            const argument = arguments[index].text(source);
            if (self.permits_assignment and isAssignment(argument)) {
                index += 1;
                continue;
            }
            if (std.mem.eql(u8, argument, "--")) return if (index + 1 < arguments.len) index + 1 else null;
            if (argument.len < 2 or (argument[0] != '-' and argument[0] != '+')) return index;

            var flag_index: usize = 1;
            while (flag_index < argument.len) : (flag_index += 1) {
                const flag = argument[flag_index];
                if (std.mem.indexOfScalar(u8, self.flags_solo, flag) != null) return null;
                if (std.mem.indexOfScalar(u8, self.flags_with_argument, flag) != null) {
                    if (flag_index + 1 == argument.len) index += 1;
                    break;
                }
                if (std.mem.indexOfScalar(u8, self.flags_sans_argument, flag) == null) break;
            }
            index += 1;
        }
        return null;
    }
};

const precommands = [_]struct { name: []const u8, definition: Precommand }{
    .{ .name = "-", .definition = .{} },
    .{ .name = "builtin", .definition = .{} },
    .{ .name = "command", .definition = .{ .flags_sans_argument = "pvV", .flags_solo = "vV" } },
    .{ .name = "exec", .definition = .{ .flags_with_argument = "a", .flags_sans_argument = "cl" } },
    .{ .name = "noglob", .definition = .{} },
    .{ .name = "nice", .definition = .{ .flags_with_argument = "n" } },
    .{ .name = "nohup", .definition = .{} },
    .{ .name = "pkexec", .definition = .{} },
    .{ .name = "eatmydata", .definition = .{} },
    .{ .name = "catchsegv", .definition = .{} },
    .{ .name = "setsid", .definition = .{ .flags_sans_argument = "fwc" } },
    .{ .name = "stdbuf", .definition = .{ .flags_with_argument = "ioe" } },
    .{ .name = "sudo", .definition = .{ .flags_with_argument = "Cgprtu", .flags_sans_argument = "AEHPSbilns", .flags_solo = "eKkVv" } },
    .{ .name = "doas", .definition = .{ .flags_with_argument = "aCu", .flags_sans_argument = "Lns" } },
    .{ .name = "env", .definition = .{ .flags_with_argument = "u", .flags_sans_argument = "i", .permits_assignment = true } },
    .{ .name = "ionice", .definition = .{ .flags_with_argument = "cn", .flags_sans_argument = "t", .flags_solo = "pPu" } },
    .{ .name = "strace", .definition = .{ .flags_with_argument = "IbeaosXPpEuOS", .flags_sans_argument = "ACdfhikqrtTvVxyDc" } },
    .{ .name = "proxychains", .definition = .{ .flags_with_argument = "f", .flags_sans_argument = "q" } },
    .{ .name = "torsocks", .definition = .{ .flags_with_argument = "idq", .flags_sans_argument = "upaP" } },
    .{ .name = "torify", .definition = .{ .flags_with_argument = "idq", .flags_sans_argument = "upaP" } },
    .{ .name = "ssh-agent", .definition = .{ .flags_with_argument = "aEPt", .flags_sans_argument = "csDd", .flags_solo = "k" } },
    .{ .name = "tabbed", .definition = .{ .flags_with_argument = "gnprtTuU", .flags_sans_argument = "cdfhs", .flags_solo = "v" } },
    .{ .name = "chronic", .definition = .{ .flags_sans_argument = "ev" } },
    .{ .name = "ifne", .definition = .{ .flags_sans_argument = "n" } },
    .{ .name = "grc", .definition = .{ .flags_sans_argument = "se" } },
    .{ .name = "cpulimit", .definition = .{ .flags_with_argument = "elp", .flags_sans_argument = "ivz" } },
    .{ .name = "ktrace", .definition = .{ .flags_with_argument = "fgpt", .flags_sans_argument = "aBCcdiT" } },
    .{ .name = "caffeinate", .definition = .{ .flags_with_argument = "tw", .flags_sans_argument = "dimsu" } },
};

fn tokenFor(node: tree_sitter.Node) Token {
    return .{ .node = node, .start_byte = node.startByte(), .end_byte = node.endByte() };
}

fn hasLeadingVariableAssignment(node: tree_sitter.Node) bool {
    const first = node.child(0) orelse return false;
    return std.mem.eql(u8, first.kind(), "variable_assignment");
}

fn isEscaped(text: []const u8, index: usize) bool {
    var backslash_count: usize = 0;
    var cursor = index;
    while (cursor > 0 and text[cursor - 1] == '\\') {
        backslash_count += 1;
        cursor -= 1;
    }
    return backslash_count % 2 != 0;
}

fn closingBackquoteBefore(source: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (source[index] == '`' and !isEscaped(source, index)) return index;
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

fn shellWordEndBefore(source: []const u8, start: usize, end: usize) usize {
    var index = start;
    while (index < end and
        !std.ascii.isWhitespace(source[index]) and
        std.mem.indexOfScalar(u8, "`;(){}|&", source[index]) == null) : (index += 1)
    {}
    return index;
}

fn historyDisabledAt(node: tree_sitter.Node, source_index: u32) bool {
    if (source_index < node.startByte() or source_index >= node.endByte()) return false;
    const kind = node.kind();
    if (std.mem.eql(u8, kind, "raw_string") or std.mem.eql(u8, kind, "ansi_c_string")) return true;

    var child_index: u32 = 0;
    while (child_index < node.namedChildCount()) : (child_index += 1) {
        const child = node.namedChild(child_index).?;
        if (source_index >= child.startByte() and source_index < child.endByte()) {
            return historyDisabledAt(child, source_index);
        }
    }
    return false;
}

fn historyExpansionEnd(text: []const u8, start: usize) usize {
    if (start + 1 >= text.len) return text.len;
    const designator = text[start + 1];
    if (std.mem.indexOfScalar(u8, "!#$*%", designator) != null) return start + 2;
    if (designator == '?') {
        const closing = std.mem.indexOfScalarPos(u8, text, start + 2, '?') orelse return text.len;
        return closing + 1;
    }
    if (designator == '{') {
        const closing = std.mem.indexOfScalarPos(u8, text, start + 2, '}') orelse return text.len;
        return closing + 1;
    }

    var end = start + 1;
    if (text[end] == '-') end += 1;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_')) : (end += 1) {}
    return @max(end, start + 2);
}

fn isLiteralWord(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |byte| {
        if (std.ascii.isWhitespace(byte)) return false;
        if (std.mem.indexOfScalar(u8, "'\"\\$`*?[]{}()<>|;&!", byte) != null) return false;
    }
    return true;
}

fn literalCommandWord(word: []const u8) ?[]const u8 {
    if (isLiteralWord(word)) return word;
    if (word.len >= 2 and word[0] == '\'' and word[word.len - 1] == '\'') return word[1 .. word.len - 1];
    if (word.len >= 2 and word[0] == '"' and word[word.len - 1] == '"') {
        const contents = word[1 .. word.len - 1];
        if (std.mem.indexOfAny(u8, contents, "\\$`") == null) return contents;
    }
    if (word.len > 1 and word[0] == '\\' and isLiteralWord(word[1..])) return word[1..];
    return null;
}

fn isReservedWord(kind: []const u8) bool {
    inline for (reserved_words) |word| {
        if (std.mem.eql(u8, kind, word)) return true;
    }
    return false;
}

const reserved_words = [_][]const u8{
    "case",  "coproc",    "do",     "done",   "elif",    "else",     "end",
    "esac",  "export",    "fi",     "for",    "foreach", "function", "if",
    "in",    "nocorrect", "repeat", "select", "then",    "time",     "until",
    "while", "unset",
};

fn styleForCommandKind(kind: CommandKind) Style {
    return switch (kind) {
        .reserved_word => .keyword,
        .shell_function => .shell_function,
        .builtin => .builtin,
        .hashed_command => .hashed_command,
        .external_command => .external_command,
        .auto_directory => .auto_directory,
        .unknown => .unknown_command,
    };
}

fn isAssignment(word: []const u8) bool {
    const equal = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (equal == 0) return false;
    const name = word[0..equal];
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn isSimpleParameterExpression(word: []const u8) bool {
    if (word.len < 2 or word[0] != '$') return false;
    var index: usize = 1;
    const braced = word[index] == '{';
    if (braced) index += 1;
    if (index == word.len or !(std.ascii.isAlphabetic(word[index]) or word[index] == '_')) return false;
    index += 1;
    while (index < word.len and (std.ascii.isAlphanumeric(word[index]) or word[index] == '_')) : (index += 1) {}
    if (!braced) return index == word.len;
    return index + 1 == word.len and word[index] == '}';
}

fn isDecimal(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

test "precommand option parsing finds the downstream command" {
    const arguments = [_]Token{
        .{ .start_byte = 5, .end_byte = 7 },
        .{ .start_byte = 8, .end_byte = 12 },
        .{ .start_byte = 13, .end_byte = 18 },
    };
    const source = "sudo -u root print";
    try std.testing.expectEqual(@as(?usize, 2), Precommand.forName("sudo").?.followingCommand(&arguments, source));
}

test "env skips flags, their arguments, and assignments" {
    const source = "env -u OLD NEW=value print";
    const arguments = [_]Token{
        .{ .start_byte = 4, .end_byte = 6 },
        .{ .start_byte = 7, .end_byte = 10 },
        .{ .start_byte = 11, .end_byte = 20 },
        .{ .start_byte = 21, .end_byte = 26 },
    };
    try std.testing.expectEqual(@as(?usize, 3), Precommand.forName("env").?.followingCommand(&arguments, source));
}
