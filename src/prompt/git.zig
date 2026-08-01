const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

pub const Provider = enum { github, gitlab, generic };

pub const Counts = struct {
    staged: usize = 0,
    modified: usize = 0,
    deleted: usize = 0,
    renamed: usize = 0,
    untracked: usize = 0,
    stashed: usize = 0,
    ahead: usize = 0,
    behind: usize = 0,
};

pub const Info = struct {
    root: []u8,
    dir: []u8,
    branch: ?[]u8 = null,
    commit: ?[]u8 = null,
    tag: ?[]u8 = null,
    operation: ?[]u8 = null,
    provider: Provider = .generic,
    counts: Counts = .{},

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        allocator.free(self.dir);
        if (self.branch) |value| allocator.free(value);
        if (self.commit) |value| allocator.free(value);
        if (self.tag) |value| allocator.free(value);
        if (self.operation) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn inspect(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?Info {
    const status = try runGit(allocator, io, cwd, &.{ "status", "--porcelain=v2", "--branch", "--show-stash", "--untracked-files=all" }) orelse return null;
    defer allocator.free(status);

    const paths = try runGit(allocator, io, cwd, &.{ "rev-parse", "--show-toplevel", "--absolute-git-dir" }) orelse return null;
    defer allocator.free(paths);
    var path_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, paths, "\r\n"), '\n');
    const root = path_lines.next() orelse return null;
    const dir = path_lines.next() orelse return null;

    const owned_root = try allocator.dupe(u8, root);
    errdefer allocator.free(owned_root);
    const owned_dir = try allocator.dupe(u8, dir);
    var info = Info{ .root = owned_root, .dir = owned_dir };
    errdefer info.deinit(allocator);
    try parseStatus(allocator, status, &info);

    if (try runGit(allocator, io, cwd, &.{ "rev-parse", "--short", "HEAD" })) |commit| {
        defer allocator.free(commit);
        const trimmed = std.mem.trim(u8, commit, "\r\n");
        if (trimmed.len != 0) info.commit = try allocator.dupe(u8, trimmed);
    }
    if (try runGit(allocator, io, cwd, &.{ "tag", "--points-at", "HEAD" })) |tags| {
        defer allocator.free(tags);
        const tag = std.mem.trim(u8, tags, "\r\n");
        if (tag.len != 0) {
            const end = std.mem.indexOfScalar(u8, tag, '\n') orelse tag.len;
            info.tag = try allocator.dupe(u8, tag[0..end]);
        }
    }
    if (try runGit(allocator, io, cwd, &.{ "remote", "-v" })) |remotes| {
        defer allocator.free(remotes);
        if (std.mem.indexOf(u8, remotes, "github") != null) info.provider = .github else if (std.mem.indexOf(u8, remotes, "gitlab") != null) info.provider = .gitlab;
    }
    info.operation = try operation(allocator, info.dir);
    return info;
}

fn runGit(allocator: std.mem.Allocator, _: std.Io, cwd: []const u8, args: []const []const u8) !?[]u8 {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);
    try command.appendSlice(allocator, "git -C ");
    try appendShellQuoted(&command, allocator, cwd);
    for (args) |arg| {
        try command.append(allocator, ' ');
        try appendShellQuoted(&command, allocator, arg);
    }
    try command.appendSlice(allocator, " 2>/dev/null");
    try command.append(allocator, 0);

    const pipe = c.popen(command.items.ptr, "r") orelse return error.ProcessUnavailable;
    var pipe_open = true;
    defer {
        if (pipe_open) _ = c.pclose(pipe);
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = c.fread(&buffer, 1, buffer.len, pipe);
        if (count != 0) {
            if (output.items.len + count > 128 * 1024) return error.StreamTooLong;
            try output.appendSlice(allocator, buffer[0..count]);
        }
        if (count < buffer.len) {
            if (c.ferror(pipe) != 0) return error.ReadFailed;
            break;
        }
    }

    const status = c.pclose(pipe);
    pipe_open = false;
    if (status != 0) return null;
    return try output.toOwnedSlice(allocator);
}

fn appendShellQuoted(command: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try command.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try command.appendSlice(allocator, "'\\''");
        } else {
            try command.append(allocator, byte);
        }
    }
    try command.append(allocator, '\'');
}

fn parseStatus(allocator: std.mem.Allocator, output: []const u8, info: *Info) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            const branch = line[14..];
            if (!std.mem.eql(u8, branch, "(detached)")) info.branch = try allocator.dupe(u8, branch);
        } else if (std.mem.startsWith(u8, line, "# branch.ab +")) {
            var values = std.mem.splitScalar(u8, line[13..], ' ');
            info.counts.ahead = std.fmt.parseInt(usize, values.next() orelse "0", 10) catch 0;
            const behind = values.next() orelse "-0";
            info.counts.behind = std.fmt.parseInt(usize, std.mem.trimStart(u8, behind, "-"), 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "# stash ")) {
            info.counts.stashed = std.fmt.parseInt(usize, line[8..], 10) catch 0;
        } else if (line.len >= 4 and (line[0] == '1' or line[0] == '2' or line[0] == 'u') and line[1] == ' ') {
            countPair(line[2], line[3], &info.counts);
        } else if (std.mem.startsWith(u8, line, "? ")) {
            info.counts.untracked += 1;
        }
    }
}

fn countPair(index: u8, worktree: u8, counts: *Counts) void {
    if (index != '.' and index != ' ') counts.staged += 1;
    switch (worktree) {
        'D' => counts.deleted += 1,
        'R' => counts.renamed += 1,
        '.', ' ' => {},
        else => counts.modified += 1,
    }
}

fn operation(allocator: std.mem.Allocator, dir: []const u8) !?[]u8 {
    const candidates = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "MERGE_HEAD", .value = "merge" },
        .{ .name = "CHERRY_PICK_HEAD", .value = "cherry-pick" },
        .{ .name = "REVERT_HEAD", .value = "revert" },
        .{ .name = "rebase-merge", .value = "rebase" },
        .{ .name = "rebase-apply", .value = "rebase" },
        .{ .name = "BISECT_LOG", .value = "bisect" },
    };
    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ dir, candidate.name });
        defer allocator.free(path);
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return try allocator.dupe(u8, candidate.value);
    }
    return null;
}

test "parses porcelain v2 branch and status data" {
    const allocator = std.testing.allocator;
    var info = Info{
        .root = try allocator.dupe(u8, "/repo"),
        .dir = try allocator.dupe(u8, "/repo/.git"),
    };
    defer info.deinit(allocator);

    try parseStatus(
        allocator,
        "# branch.oid abcdef\n# branch.head feature/prompt\n# branch.ab +2 -3\n# stash 1\n1 M. N... 100644 100644 100644 a b file\n1 .M N... 100644 100644 100644 a b changed\n1 .D N... 100644 100644 100644 a b gone\n2 .R N... 100644 100644 100644 a b R100 new\told\n? new-file\n",
        &info,
    );

    try std.testing.expectEqualStrings("feature/prompt", info.branch.?);
    try std.testing.expectEqual(@as(usize, 2), info.counts.ahead);
    try std.testing.expectEqual(@as(usize, 3), info.counts.behind);
    try std.testing.expectEqual(@as(usize, 1), info.counts.staged);
    try std.testing.expectEqual(@as(usize, 1), info.counts.modified);
    try std.testing.expectEqual(@as(usize, 1), info.counts.deleted);
    try std.testing.expectEqual(@as(usize, 1), info.counts.renamed);
    try std.testing.expectEqual(@as(usize, 1), info.counts.untracked);
}

test "inspects the repository containing the test process" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);

    var info = (try inspect(allocator, io, cwd)) orelse return error.TestUnexpectedResult;
    defer info.deinit(allocator);

    try std.testing.expect(info.branch != null or info.commit != null);
}
