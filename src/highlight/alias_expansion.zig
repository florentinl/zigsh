const std = @import("std");
const tree_sitter = @import("tree-sitter");
const semantic = @import("semantic.zig");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

extern fn tree_sitter_zsh() callconv(.c) *const tree_sitter.Language;

pub const max_expansion_depth = 16;
pub const max_expansion_count = 128;
pub const max_virtual_source_bytes = 256 * 1024;

pub const Result = struct {
    spans: []Span,
    commands: [][]u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.spans);
        for (self.commands) |command| allocator.free(command);
        allocator.free(self.commands);
        self.* = undefined;
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    parser: *tree_sitter.Parser,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        const language = tree_sitter_zsh();
        const abi_version = language.abiVersion();
        if (abi_version < tree_sitter.MIN_COMPATIBLE_LANGUAGE_VERSION or
            abi_version > tree_sitter.LANGUAGE_VERSION)
        {
            return error.IncompatibleLanguage;
        }
        const parser = tree_sitter.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language);
        return .{ .allocator = allocator, .parser = parser };
    }

    pub fn deinit(self: *Engine) void {
        self.parser.destroy();
        self.* = undefined;
    }

    pub fn highlight(self: *Engine, source: []const u8, state: anytype) ![]Span {
        var result = try self.analyze(source, state);
        for (result.commands) |command| self.allocator.free(command);
        self.allocator.free(result.commands);
        const projected = result.spans;
        result.spans = &.{};
        return projected;
    }

    pub fn analyze(self: *Engine, source: []const u8, state: anytype) !Result {
        var virtual = try VirtualSource.init(self.allocator, source);
        defer virtual.deinit(self.allocator);

        var lineages = std.ArrayList(Lineage).empty;
        defer lineages.deinit(self.allocator);
        try lineages.append(self.allocator, .root);

        var expansion_count: usize = 0;
        const source_limit = virtualSourceLimit(source.len);
        var unsafe_aliases = std.ArrayList(Span).empty;
        defer unsafe_aliases.deinit(self.allocator);
        while (true) {
            const tree = self.parser.parseString(virtual.bytes, null) orelse return error.ParseFailed;
            defer tree.destroy();

            var analysis = try semantic.analyze(
                self.allocator,
                virtual.bytes,
                tree.rootNode(),
                state,
            );
            defer analysis.deinit(self.allocator);

            if (expansion_count == max_expansion_count) {
                return self.finishAnalysis(
                    self.allocator,
                    virtual,
                    &analysis,
                    lineages.items,
                    unsafe_aliases.items,
                );
            }

            var replacements = try self.collectReplacements(
                virtual,
                analysis.expansion_candidates,
                state,
                &lineages,
                &unsafe_aliases,
                max_expansion_count - expansion_count,
                source_limit,
            );
            defer replacements.deinit(self.allocator);

            if (replacements.len() == 0) {
                return self.finishAnalysis(
                    self.allocator,
                    virtual,
                    &analysis,
                    lineages.items,
                    unsafe_aliases.items,
                );
            }

            const next = try virtual.replaced(self.allocator, replacements.slice());
            virtual.deinit(self.allocator);
            virtual = next;
            expansion_count += replacements.len();
        }
    }

    fn finishAnalysis(
        self: *Engine,
        allocator: std.mem.Allocator,
        virtual: VirtualSource,
        analysis: *const semantic.Analysis,
        lineages: []const Lineage,
        unsafe_aliases: []const Span,
    ) !Result {
        _ = self;
        const projected = try project(
            allocator,
            analysis.spans,
            virtual.origins,
            virtual.lineages,
            lineages,
            unsafe_aliases,
        );
        errdefer allocator.free(projected);
        const commands = try semantic.copyCommandWords(allocator, virtual.bytes, analysis.commands);
        return .{ .spans = projected, .commands = commands };
    }

    fn collectReplacements(
        self: *Engine,
        virtual: VirtualSource,
        expansion_candidates: []const semantic.ExpansionCandidate,
        state: anytype,
        lineages: *std.ArrayList(Lineage),
        unsafe_aliases: *std.ArrayList(Span),
        remaining_expansions: usize,
        source_limit: usize,
    ) !ReplacementList {
        var aliases = std.ArrayList(semantic.ExpansionCandidate).empty;
        defer aliases.deinit(self.allocator);
        for (expansion_candidates) |candidate| {
            if (candidateAliasKind(candidate.kind) != null) try aliases.append(self.allocator, candidate);
        }
        std.mem.sort(semantic.ExpansionCandidate, aliases.items, {}, candidateLessThan);

        var replacements = ReplacementList{};
        errdefer replacements.deinit(self.allocator);
        var previous_end: u32 = 0;
        var projected_length = virtual.bytes.len;

        for (aliases.items) |candidate| {
            if (replacements.len() == remaining_expansions) break;
            if (candidate.start_byte < previous_end or candidate.start_byte >= candidate.end_byte) continue;
            if (candidate.end_byte > virtual.bytes.len) continue;
            if (replacements.last()) |previous| {
                if (previous.start_byte == candidate.start_byte and previous.end_byte == candidate.end_byte) continue;
            }

            const lineage_id = uniformLineage(virtual.lineages, candidate) orelse continue;
            const word = virtual.bytes[candidate.start_byte..candidate.end_byte];
            const kind = candidateAliasKind(candidate.kind).?;
            const alias_hash = aliasHash(kind, word);
            if (lineages.items[lineage_id].depth == max_expansion_depth or
                containsAlias(lineages.items, lineage_id, alias_hash)) continue;

            const expansion = try state.aliasExpansion(self.allocator, word, kind) orelse continue;
            errdefer self.allocator.free(expansion);
            const origin = sourceOrigin(virtual.origins, candidate) orelse lineages.items[lineage_id].origin;
            if (immediatelyUnsafe(state, expansion)) {
                if (origin) |unsafe_alias| try unsafe_aliases.append(self.allocator, .{
                    .start_byte = unsafe_alias.start_byte,
                    .end_byte = unsafe_alias.end_byte,
                    .style = .unknown_token,
                });
                self.allocator.free(expansion);
                continue;
            }
            const removed_length = candidate.end_byte - candidate.start_byte;
            projected_length = projected_length - removed_length + expansion.len;
            if (projected_length > source_limit) {
                self.allocator.free(expansion);
                break;
            }
            if (lineages.items.len == std.math.maxInt(u16)) {
                self.allocator.free(expansion);
                break;
            }

            const replacement_lineage: u16 = @intCast(lineages.items.len);
            try lineages.append(self.allocator, .{
                .parent = lineage_id,
                .alias_hash = alias_hash,
                .depth = lineages.items[lineage_id].depth + 1,
                .origin = origin,
            });
            try replacements.append(self.allocator, .{
                .start_byte = candidate.start_byte,
                .end_byte = candidate.end_byte,
                .bytes = expansion,
                .lineage = replacement_lineage,
            });
            previous_end = candidate.end_byte;
        }
        try self.collectParameterReplacements(
            virtual,
            expansion_candidates,
            state,
            lineages,
            &replacements,
            remaining_expansions,
            source_limit,
            &projected_length,
        );
        std.mem.sort(Replacement, replacements.list.items, {}, replacementLessThan);
        return replacements;
    }

    fn collectParameterReplacements(
        self: *Engine,
        virtual: VirtualSource,
        expansion_candidates: []const semantic.ExpansionCandidate,
        state: anytype,
        lineages: *std.ArrayList(Lineage),
        replacements: *ReplacementList,
        remaining_expansions: usize,
        source_limit: usize,
        projected_length: *usize,
    ) !void {
        for (expansion_candidates) |candidate| {
            if (replacements.len() == remaining_expansions) return;
            if (!isParameterCandidate(candidate.kind)) continue;
            if (candidate.start_byte >= candidate.end_byte or candidate.end_byte > virtual.bytes.len) continue;
            if (overlapsReplacement(replacements.slice(), candidate)) continue;

            const lineage_id = uniformLineage(virtual.lineages, candidate) orelse continue;
            const word = virtual.bytes[candidate.start_byte..candidate.end_byte];
            const expansion_hash = parameterHash(word);
            if (lineages.items[lineage_id].depth == max_expansion_depth or
                containsAlias(lineages.items, lineage_id, expansion_hash)) continue;

            const expansion = try state.commandParameterExpansion(self.allocator, word) orelse continue;
            errdefer self.allocator.free(expansion);
            const removed_length = candidate.end_byte - candidate.start_byte;
            const next_length = projected_length.* - removed_length + expansion.len;
            if (next_length > source_limit or lineages.items.len == std.math.maxInt(u16)) {
                self.allocator.free(expansion);
                continue;
            }

            const replacement_lineage: u16 = @intCast(lineages.items.len);
            try lineages.append(self.allocator, .{
                .parent = lineage_id,
                .alias_hash = expansion_hash,
                .depth = lineages.items[lineage_id].depth + 1,
                .origin = sourceOrigin(virtual.origins, candidate) orelse lineages.items[lineage_id].origin,
            });
            try replacements.append(self.allocator, .{
                .start_byte = candidate.start_byte,
                .end_byte = candidate.end_byte,
                .bytes = expansion,
                .lineage = replacement_lineage,
            });
            projected_length.* = next_length;
        }
    }
};

const no_origin = std.math.maxInt(u32);

const VirtualSource = struct {
    bytes: []u8,
    origins: []u32,
    lineages: []u16,

    fn init(allocator: std.mem.Allocator, source: []const u8) !VirtualSource {
        const bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(bytes);
        const origins = try allocator.alloc(u32, source.len);
        errdefer allocator.free(origins);
        const lineages = try allocator.alloc(u16, source.len);
        for (origins, 0..) |*origin, index| origin.* = @intCast(index);
        @memset(lineages, 0);
        return .{ .bytes = bytes, .origins = origins, .lineages = lineages };
    }

    fn deinit(self: *VirtualSource, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.origins);
        allocator.free(self.lineages);
        self.* = undefined;
    }

    fn replaced(
        self: VirtualSource,
        allocator: std.mem.Allocator,
        replacements: []const Replacement,
    ) !VirtualSource {
        var length = self.bytes.len;
        for (replacements) |replacement| {
            length = length - (replacement.end_byte - replacement.start_byte) + replacement.bytes.len;
        }

        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        const origins = try allocator.alloc(u32, length);
        errdefer allocator.free(origins);
        const lineages = try allocator.alloc(u16, length);
        errdefer allocator.free(lineages);

        var source_offset: usize = 0;
        var target_offset: usize = 0;
        for (replacements) |replacement| {
            const unchanged_length = replacement.start_byte - source_offset;
            @memcpy(bytes[target_offset..][0..unchanged_length], self.bytes[source_offset..replacement.start_byte]);
            @memcpy(origins[target_offset..][0..unchanged_length], self.origins[source_offset..replacement.start_byte]);
            @memcpy(lineages[target_offset..][0..unchanged_length], self.lineages[source_offset..replacement.start_byte]);
            target_offset += unchanged_length;

            @memcpy(bytes[target_offset..][0..replacement.bytes.len], replacement.bytes);
            @memset(origins[target_offset..][0..replacement.bytes.len], no_origin);
            @memset(lineages[target_offset..][0..replacement.bytes.len], replacement.lineage);
            target_offset += replacement.bytes.len;
            source_offset = replacement.end_byte;
        }

        const remaining_length = self.bytes.len - source_offset;
        @memcpy(bytes[target_offset..][0..remaining_length], self.bytes[source_offset..]);
        @memcpy(origins[target_offset..][0..remaining_length], self.origins[source_offset..]);
        @memcpy(lineages[target_offset..][0..remaining_length], self.lineages[source_offset..]);
        return .{ .bytes = bytes, .origins = origins, .lineages = lineages };
    }
};

const Lineage = struct {
    parent: u16,
    alias_hash: u64,
    depth: u8,
    origin: ?Span,

    const root = Lineage{ .parent = 0, .alias_hash = 0, .depth = 0, .origin = null };
};

const Replacement = struct {
    start_byte: u32,
    end_byte: u32,
    bytes: []u8,
    lineage: u16,
};

const ReplacementList = struct {
    list: std.ArrayList(Replacement) = .empty,

    fn append(self: *ReplacementList, allocator: std.mem.Allocator, replacement: Replacement) !void {
        try self.list.append(allocator, replacement);
    }

    fn len(self: ReplacementList) usize {
        return self.list.items.len;
    }

    fn slice(self: ReplacementList) []const Replacement {
        return self.list.items;
    }

    fn last(self: ReplacementList) ?Replacement {
        if (self.list.items.len == 0) return null;
        return self.list.items[self.list.items.len - 1];
    }

    fn deinit(self: *ReplacementList, allocator: std.mem.Allocator) void {
        for (self.list.items) |replacement| allocator.free(replacement.bytes);
        self.list.deinit(allocator);
        self.* = undefined;
    }
};

fn virtualSourceLimit(source_length: usize) usize {
    const scaled = std.math.mul(usize, source_length, 8) catch max_virtual_source_bytes;
    const with_slack = std.math.add(usize, scaled, 4096) catch max_virtual_source_bytes;
    return @min(max_virtual_source_bytes, with_slack);
}

fn candidateAliasKind(kind: semantic.ExpansionKind) ?semantic.AliasKind {
    return switch (kind) {
        .alias => |alias| alias,
        .safe_scalar_parameter => null,
    };
}

fn isParameterCandidate(kind: semantic.ExpansionKind) bool {
    return switch (kind) {
        .alias => false,
        .safe_scalar_parameter => true,
    };
}

fn candidateLessThan(
    _: void,
    left: semantic.ExpansionCandidate,
    right: semantic.ExpansionCandidate,
) bool {
    if (left.start_byte != right.start_byte) return left.start_byte < right.start_byte;
    return left.end_byte < right.end_byte;
}

fn uniformLineage(lineages: []const u16, candidate: anytype) ?u16 {
    const lineage = lineages[candidate.start_byte];
    for (lineages[candidate.start_byte..candidate.end_byte]) |candidate_lineage| {
        if (candidate_lineage != lineage) return null;
    }
    return lineage;
}

fn aliasHash(kind: semantic.AliasKind, word: []const u8) u64 {
    return std.hash.Wyhash.hash(@intFromEnum(kind), word);
}

fn parameterHash(word: []const u8) u64 {
    return std.hash.Wyhash.hash(3, word);
}

fn replacementLessThan(_: void, left: Replacement, right: Replacement) bool {
    return left.start_byte < right.start_byte;
}

fn overlapsReplacement(replacements: []const Replacement, candidate: anytype) bool {
    for (replacements) |replacement| {
        if (candidate.start_byte < replacement.end_byte and replacement.start_byte < candidate.end_byte) return true;
    }
    return false;
}

fn containsAlias(lineages: []const Lineage, start: u16, alias_hash: u64) bool {
    var lineage = start;
    while (lineage != 0) {
        if (lineages[lineage].alias_hash == alias_hash) return true;
        lineage = lineages[lineage].parent;
    }
    return false;
}

fn project(
    allocator: std.mem.Allocator,
    spans: []const Span,
    origins: []const u32,
    source_lineages: []const u16,
    lineages: []const Lineage,
    unsafe_aliases: []const Span,
) ![]Span {
    var projected = std.ArrayList(Span).empty;
    errdefer projected.deinit(allocator);

    for (spans) |span| {
        var index: usize = span.start_byte;
        while (index < span.end_byte) {
            while (index < span.end_byte and origins[index] == no_origin) {
                const lineage = source_lineages[index];
                while (index < span.end_byte and
                    origins[index] == no_origin and
                    source_lineages[index] == lineage) : (index += 1)
                {}
                if (unsafeAliasOutcome(span.style)) {
                    if (lineages[lineage].origin) |origin| {
                        try projected.append(allocator, .{
                            .start_byte = origin.start_byte,
                            .end_byte = origin.end_byte,
                            .style = .unknown_token,
                        });
                    }
                }
            }
            if (index == span.end_byte) break;

            const original_start = origins[index];
            var original_end = original_start + 1;
            index += 1;
            while (index < span.end_byte and origins[index] == original_end) : (index += 1) {
                original_end += 1;
            }
            try projected.append(allocator, .{
                .start_byte = original_start,
                .end_byte = original_end,
                .style = span.style,
            });
        }
    }
    try projected.appendSlice(allocator, unsafe_aliases);
    return projected.toOwnedSlice(allocator);
}

fn immediatelyUnsafe(state: anytype, expansion: []const u8) bool {
    const command = std.mem.trim(u8, expansion, " \t\r\n");
    if (command.len == 0) return false;
    if (command[0] == '#') return !state.commentsEnabled();
    if (!isBareWord(command)) return false;
    if (state.aliasKind(command, true) != null) return false;
    if (!(std.mem.startsWith(u8, command, "/") or
        std.mem.startsWith(u8, command, "./") or
        std.mem.startsWith(u8, command, "../"))) return false;
    return state.commandKind(command) == .unknown and state.pathKind(command, false, true) == .none;
}

fn isBareWord(word: []const u8) bool {
    return std.mem.indexOfAny(u8, word, " \t\r\n'\"\\$`*?[]{}()<>|;&!") == null;
}

fn sourceOrigin(origins: []const u32, candidate: anytype) ?Span {
    if (candidate.start_byte >= candidate.end_byte or origins[candidate.start_byte] == no_origin) return null;
    const start = origins[candidate.start_byte];
    var expected = start;
    for (origins[candidate.start_byte..candidate.end_byte]) |origin| {
        if (origin != expected) return null;
        expected += 1;
    }
    return .{ .start_byte = start, .end_byte = expected, .style = .plain };
}

fn unsafeAliasOutcome(style: Style) bool {
    return switch (style) {
        .unknown_command, .unknown_token, .parse_error, .comment => true,
        else => false,
    };
}
