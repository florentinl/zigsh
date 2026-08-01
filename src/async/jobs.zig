const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const clock = @import("../prompt/clock.zig");
const git = @import("../prompt/git.zig");
const git_wire = @import("../prompt/git_wire.zig");
const alias_expansion = @import("../highlight/alias_expansion.zig");
const highlight_engine = @import("../highlight/engine.zig");
const highlight_wire = @import("../highlight/wire.zig");
const semantic = @import("../highlight/semantic.zig");
const spans = @import("../highlight/span.zig");
const zsh_state = @import("../highlight/zsh_state.zig");

pub const State = struct {
    highlight: ?highlight_engine.Engine = null,
    aliases: ?alias_expansion.Engine = null,

    pub fn deinit(self: *State) void {
        if (self.aliases) |*engine| engine.deinit();
        if (self.highlight) |*engine| engine.deinit();
        self.* = .{};
    }

    pub fn run(
        self: *State,
        allocator: std.mem.Allocator,
        job: protocol.Job,
        payload: []const u8,
    ) ![]u8 {
        return switch (job) {
            .ping => allocator.dupe(u8, payload),
            .prompt_git => inspectGit(allocator, payload),
            .highlight => if (builtin.is_test)
                error.UnsupportedJob
            else
                self.highlightSource(allocator, payload),
        };
    }

    fn highlightSource(self: *State, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        if (self.highlight == null) self.highlight = try highlight_engine.Engine.init(allocator);
        if (self.aliases == null) self.aliases = try alias_expansion.Engine.init(allocator);

        var syntax = try self.highlight.?.highlight(source);
        defer syntax.deinit(allocator);
        const state = zsh_state.State{ .allocator = allocator };
        var semantic_analysis = try semantic.analyze(
            allocator,
            source,
            try self.highlight.?.rootNode(),
            &state,
        );
        defer semantic_analysis.deinit(allocator);

        const expanded = if (semantic_analysis.expansion_candidates.len == 0)
            null
        else
            try self.aliases.?.highlight(source, &state);
        defer if (expanded) |owned| allocator.free(owned);
        const expanded_count = if (expanded) |owned| owned.len else 0;

        const candidates = try allocator.alloc(
            spans.Span,
            syntax.spans.len + semantic_analysis.spans.len + expanded_count,
        );
        defer allocator.free(candidates);
        const syntax_end = syntax.spans.len;
        const semantic_end = syntax_end + semantic_analysis.spans.len;
        @memcpy(candidates[0..syntax_end], syntax.spans);
        @memcpy(candidates[syntax_end..semantic_end], semantic_analysis.spans);
        if (expanded) |owned| @memcpy(candidates[semantic_end..], owned);

        const composed = try spans.compose(allocator, @intCast(source.len), candidates);
        defer allocator.free(composed);
        return highlight_wire.encode(allocator, composed);
    }
};

fn inspectGit(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0 or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidWorkingDirectory;
    const started = clock.nowNanoseconds();
    var result = git_wire.Result{
        .info = try git.inspect(
            allocator,
            std.Io.Threaded.global_single_threaded.io(),
            cwd,
        ),
        .duration_ns = clock.elapsedSince(started),
    };
    defer result.deinit(allocator);
    return git_wire.encode(allocator, &result);
}
