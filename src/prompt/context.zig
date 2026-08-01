const std = @import("std");
const clock = @import("clock.zig");
const git = @import("git.zig");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

const allocator = std.heap.c_allocator;
const io = std.Io.Threaded.global_single_threaded.io();

pub const Context = struct {
    cwd: []u8,
    git: ?git.Info,
    git_duration_ns: u64,
    git_latency_ns: u64,
    status: c_long,

    pub fn init() !Context {
        var result = try initFast();
        errdefer result.deinit();

        const git_started = clock.nowNanoseconds();
        const complete_git = git.inspect(allocator, io, result.cwd) catch null;
        if (result.git) |*info| info.deinit(allocator);
        result.git = complete_git;
        result.git_duration_ns = clock.elapsedSince(git_started);
        return result;
    }

    pub fn initFast() !Context {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(cwd);
        return .{
            .cwd = cwd,
            .git = git.inspectFast(allocator, io, cwd) catch null,
            .git_duration_ns = 0,
            .git_latency_ns = 0,
            .status = zsh.lastval,
        };
    }

    pub fn deinit(self: *Context) void {
        allocator.free(self.cwd);
        if (self.git) |*info| info.deinit(allocator);
    }
};

pub fn isPathPrefix(prefix: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, prefix, path) or
        (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}
