const std = @import("std");
const git = @import("git.zig");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

const allocator = std.heap.c_allocator;
const io = std.Io.Threaded.global_single_threaded.io();

pub const Context = struct {
    cwd: []u8,
    git: ?git.Info,
    status: c_long,

    pub fn init() !Context {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(cwd);

        return .{
            .cwd = cwd,
            .git = git.inspect(allocator, io, cwd) catch null,
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
