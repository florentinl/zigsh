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
    virtual_env: ?[]u8,
    /// Borrowed from the prompt's worker cache; renderers never perform I/O.
    kubernetes_text: ?[]const u8 = null,

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

    /// Snapshot shell-owned values only. Even realpath/stat can block on a
    /// remote filesystem, so repository discovery belongs to the Git worker.
    pub fn initFast() !Context {
        const cwd = try parameterValue(allocator, "PWD") orelse try allocator.dupe(u8, ".");
        errdefer allocator.free(cwd);
        const virtual_env = try virtualEnvName();
        errdefer if (virtual_env) |name| allocator.free(name);
        return .{
            .cwd = cwd,
            .git = null,
            .git_duration_ns = 0,
            .git_latency_ns = 0,
            .status = zsh.lastval,
            .virtual_env = virtual_env,
        };
    }

    pub fn deinit(self: *Context) void {
        allocator.free(self.cwd);
        if (self.git) |*info| info.deinit(allocator);
        if (self.virtual_env) |name| allocator.free(name);
    }
};

pub fn parameterValue(output_allocator: std.mem.Allocator, name: [:0]const u8) !?[]u8 {
    const value = zsh.getsparam(@constCast(name.ptr)) orelse return null;
    const encoded = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    const copy = try output_allocator.dupeZ(u8, encoded);
    defer output_allocator.free(copy);
    var length: c_int = @intCast(encoded.len);
    _ = zsh.unmetafy(copy.ptr, &length);
    return try output_allocator.dupe(u8, copy[0..@intCast(length)]);
}

fn virtualEnvName() !?[]u8 {
    const value = try parameterValue(allocator, "VIRTUAL_ENV") orelse return null;
    defer allocator.free(value);
    const name = virtualEnvDisplayName(value) orelse return null;
    if (name.len == 0) return null;
    return try allocator.dupe(u8, name);
}

pub fn virtualEnvDisplayName(path: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return null;
    const name = std.fs.path.basename(trimmed);
    if (!std.mem.eql(u8, name, ".venv")) return name;

    const parent = std.fs.path.dirname(trimmed) orelse return name;
    const parent_name = std.fs.path.basename(std.mem.trimEnd(u8, parent, "/"));
    return if (parent_name.len == 0 or std.mem.eql(u8, parent_name, "/")) name else parent_name;
}

test "virtualenv display names use the project name for dot-venv" {
    try std.testing.expectEqualStrings("project", virtualEnvDisplayName("/work/project/.venv").?);
    try std.testing.expectEqualStrings("named-env", virtualEnvDisplayName("/work/named-env/").?);
    try std.testing.expectEqualStrings(".venv", virtualEnvDisplayName("/.venv").?);
    try std.testing.expect(virtualEnvDisplayName("") == null);
}

pub fn isPathPrefix(prefix: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, prefix, path) or
        (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}
