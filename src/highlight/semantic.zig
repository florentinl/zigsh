const std = @import("std");
const tree_sitter = @import("tree-sitter");
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

pub fn containsAlias(spans: []const Span) bool {
    for (spans) |span| {
        switch (span.style) {
            .alias, .global_alias, .suffix_alias => return true,
            else => {},
        }
    }
    return false;
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
    var scanner = Scanner(@TypeOf(state)){
        .allocator = allocator,
        .source = source,
        .state = state,
    };
    errdefer scanner.spans.deinit(allocator);
    try scanner.visit(root);
    return scanner.spans.toOwnedSlice(allocator);
}

fn Scanner(comptime State: type) type {
    return struct {
        allocator: std.mem.Allocator,
        source: []const u8,
        state: State,
        spans: std.ArrayList(Span) = .empty,

        const Self = @This();

        fn visit(self: *Self, node: tree_sitter.Node) !void {
            if (std.mem.eql(u8, node.kind(), "command")) try self.scanCommand(node);
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
                try self.add(token, switch (kind) {
                    .regular => .alias,
                    .global => .global_alias,
                    .suffix => .suffix_alias,
                });
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
                try self.add(argument, if (kind == .global) .global_alias else .alias);
                count += 1;
                if (kind != .regular or !self.state.regularAliasExpandsNext(text)) break;
            }
            return count;
        }

        fn scanCommandToken(self: *Self, token: Token, allow_regular_alias: bool) !void {
            const text = token.text(self.source);
            if (self.state.aliasKind(text, allow_regular_alias)) |kind| {
                try self.add(token, switch (kind) {
                    .regular => .alias,
                    .global => .global_alias,
                    .suffix => .suffix_alias,
                });
                return;
            }

            if (!isLiteralWord(text)) return;

            const command_kind = self.state.commandKind(text);
            if (command_kind == .unknown) {
                switch (self.state.pathKind(text, token.end_byte == self.source.len, true)) {
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
                    if (kind == .global) try self.add(token, .global_alias);
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

fn isEscaped(text: []const u8, index: usize) bool {
    var backslash_count: usize = 0;
    var cursor = index;
    while (cursor > 0 and text[cursor - 1] == '\\') {
        backslash_count += 1;
        cursor -= 1;
    }
    return backslash_count % 2 != 0;
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
