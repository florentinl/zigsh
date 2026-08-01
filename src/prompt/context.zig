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
    status: c_long,

    pub fn init() !Context {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(cwd);

        const git_started = clock.nowNanoseconds();
        const repository = git.inspect(allocator, io, cwd) catch null;
        return .{
            .cwd = cwd,
            .git = repository,
            .git_duration_ns = clock.elapsedSince(git_started),
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
