const std = @import("std");
const tree_sitter = @import("tree-sitter");
const clock = @import("clock.zig");
const edits = @import("edit.zig");
const spans = @import("span.zig");
const Span = spans.Span;
const Style = @import("style.zig").Style;

extern fn tree_sitter_zsh() callconv(.c) *const tree_sitter.Language;

const query_source = @embedFile("zsh-highlights.scm");
pub const max_capture_count = 65_536;
pub const max_match_count = 1024;

pub const Metrics = struct {
    parse_nanoseconds: u64,
    query_nanoseconds: u64,
    compose_nanoseconds: u64,
    capture_count: usize,
    region_count: usize,
    incremental: bool,

    pub fn totalNanoseconds(self: Metrics) u64 {
        return self.parse_nanoseconds + self.query_nanoseconds + self.compose_nanoseconds;
    }
};

pub const Result = struct {
    spans: []Span,
    has_parse_error: bool,
    metrics: Metrics,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.spans);
        self.* = undefined;
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    parser: *tree_sitter.Parser,
    query: *tree_sitter.Query,
    query_cursor: *tree_sitter.QueryCursor,
    tree: ?*tree_sitter.Tree = null,
    source: []u8,

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

        var query_error_offset: u32 = 0;
        const query = tree_sitter.Query.create(language, query_source, &query_error_offset) catch |query_error| {
            std.log.err("invalid Zsh highlight query at byte {d}", .{query_error_offset});
            return query_error;
        };
        errdefer query.destroy();

        const query_cursor = tree_sitter.QueryCursor.create();
        errdefer query_cursor.destroy();
        query_cursor.setMatchLimit(max_match_count);

        const source = try allocator.alloc(u8, 0);

        return .{
            .allocator = allocator,
            .parser = parser,
            .query = query,
            .query_cursor = query_cursor,
            .source = source,
        };
    }

    pub fn deinit(self: *Engine) void {
        if (self.tree) |tree| tree.destroy();
        self.query_cursor.destroy();
        self.query.destroy();
        self.parser.destroy();
        self.allocator.free(self.source);
        self.* = undefined;
    }

    pub fn highlight(self: *Engine, source: []const u8) !Result {
        const had_tree = self.tree != null;
        const parse_start = clock.nowNanoseconds();
        const tree = try self.parse(source);
        const parse_end = clock.nowNanoseconds();

        const query_start = parse_end;
        var captures = try self.collectCaptures(tree.rootNode());
        defer captures.deinit(self.allocator);
        const query_end = clock.nowNanoseconds();

        const composed = try spans.compose(self.allocator, @intCast(source.len), captures.items);
        const compose_end = clock.nowNanoseconds();

        return .{
            .spans = composed,
            .has_parse_error = tree.rootNode().hasError(),
            .metrics = .{
                .parse_nanoseconds = parse_end -| parse_start,
                .query_nanoseconds = query_end -| query_start,
                .compose_nanoseconds = compose_end -| query_end,
                .capture_count = captures.items.len,
                .region_count = composed.len,
                .incremental = had_tree,
            },
        };
    }

    pub fn isCurrentSource(self: Engine, source: []const u8) bool {
        return self.tree != null and std.mem.eql(u8, self.source, source);
    }

    pub fn treeSExpression(self: Engine, allocator: std.mem.Allocator) ![]u8 {
        const tree = self.tree orelse return error.NoTree;
        return tree.rootNode().toSexp(allocator);
    }

    pub fn rootNode(self: Engine) error{NoTree}!tree_sitter.Node {
        const tree = self.tree orelse return error.NoTree;
        return tree.rootNode();
    }

    fn parse(self: *Engine, source: []const u8) !*tree_sitter.Tree {
        if (self.tree != null and std.mem.eql(u8, self.source, source)) return self.tree.?;

        const next_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(next_source);

        if (self.tree) |old_tree| {
            const edit = edits.between(self.source, source) orelse unreachable;
            old_tree.edit(edit);
        }

        const next_tree = self.parser.parseString(source, self.tree) orelse {
            self.parser.reset();
            if (self.tree) |old_tree| old_tree.destroy();
            self.tree = null;
            return error.ParseFailed;
        };

        if (self.tree) |old_tree| old_tree.destroy();
        self.allocator.free(self.source);
        self.tree = next_tree;
        self.source = next_source;
        return next_tree;
    }

    fn collectCaptures(self: *Engine, root: tree_sitter.Node) !std.ArrayList(Span) {
        var captures = std.ArrayList(Span).empty;
        errdefer captures.deinit(self.allocator);

        self.query_cursor.exec(self.query, root);
        while (self.query_cursor.nextCapture()) |entry| {
            if (captures.items.len == max_capture_count) return error.CaptureLimitExceeded;

            const capture = entry[1].captures[entry[0]];
            const capture_name = self.query.captureNameForId(capture.index) orelse continue;
            const style = Style.fromCapture(capture_name) orelse continue;
            try captures.append(self.allocator, .{
                .start_byte = capture.node.startByte(),
                .end_byte = capture.node.endByte(),
                .style = style,
            });
        }

        if (self.query_cursor.didExceedMatchLimit()) return error.QueryMatchLimitExceeded;
        return captures;
    }
};
