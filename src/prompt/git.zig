const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

pub const Provider = enum { unknown, github, gitlab, generic };

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
    provider: Provider = .unknown,
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

    pub fn clone(self: Info, allocator: std.mem.Allocator) !Info {
        var copy = Info{
            .root = try allocator.dupe(u8, self.root),
            .dir = undefined,
            .provider = self.provider,
            .counts = self.counts,
        };
        errdefer copy.deinit(allocator);
        copy.dir = try allocator.dupe(u8, self.dir);
        if (self.branch) |value| copy.branch = try allocator.dupe(u8, value);
        if (self.commit) |value| copy.commit = try allocator.dupe(u8, value);
        if (self.tag) |value| copy.tag = try allocator.dupe(u8, value);
        if (self.operation) |value| copy.operation = try allocator.dupe(u8, value);
        return copy;
    }
};

pub fn inspect(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?Info {
    var info = (try inspectFast(allocator, io, cwd)) orelse return null;
    errdefer info.deinit(allocator);

    const status = try runGit(allocator, io, cwd, &.{ "status", "--porcelain=v2", "--branch", "--show-stash", "--untracked-files=all" }) orelse return null;
    defer allocator.free(status);
    if (info.branch) |branch| allocator.free(branch);
    info.branch = null;
    try parseStatus(allocator, status, &info);

    if (info.branch == null) {
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
    }
    info.operation = try operation(allocator, info.dir);
    return info;
}

pub fn inspectFast(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?Info {
    const repository = (try findRepository(allocator, io, cwd)) orelse return null;
    var info = Info{ .root = repository.root, .dir = repository.git_dir };
    errdefer info.deinit(allocator);

    const head_path = try std.fs.path.join(allocator, &.{ info.dir, "HEAD" });
    defer allocator.free(head_path);
    if (try readMetadataFile(allocator, io, head_path, 64 * 1024)) |head| {
        defer allocator.free(head);
        const value = std.mem.trim(u8, head, " \t\r\n");
        const prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, value, prefix) and value.len > prefix.len) {
            info.branch = try allocator.dupe(u8, value[prefix.len..]);
        }
    }

    const common_dir = try resolveCommonDir(allocator, io, info.dir);
    defer allocator.free(common_dir);
    const config_path = try std.fs.path.join(allocator, &.{ common_dir, "config" });
    defer allocator.free(config_path);
    if (try readMetadataFile(allocator, io, config_path, 1024 * 1024)) |config| {
        defer allocator.free(config);
        info.provider = providerFromRemotes(config);
    }
    return info;
}

const Repository = struct {
    root: []u8,
    git_dir: []u8,
};

fn findRepository(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?Repository {
    var current = cwd;
    while (true) {
        const marker = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(marker);
        if (std.Io.Dir.cwd().statFile(io, marker, .{})) |stat| {
            const git_dir = switch (stat.kind) {
                .directory => try allocator.dupe(u8, marker),
                .file => try resolveGitFile(allocator, io, current, marker) orelse return null,
                else => return null,
            };
            errdefer allocator.free(git_dir);
            return .{
                .root = try allocator.dupe(u8, current),
                .git_dir = git_dir,
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

fn resolveGitFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    marker: []const u8,
) !?[]u8 {
    const contents = (try readMetadataFile(allocator, io, marker, 64 * 1024)) orelse return null;
    defer allocator.free(contents);
    const value = std.mem.trim(u8, contents, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const path = std.mem.trim(u8, value[prefix.len..], " \t");
    if (path.len == 0) return null;
    const joined = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ root, path });
    defer allocator.free(joined);
    return try realPathOwned(allocator, io, joined);
}

fn resolveCommonDir(allocator: std.mem.Allocator, io: std.Io, git_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ git_dir, "commondir" });
    defer allocator.free(path);
    const contents = (try readMetadataFile(allocator, io, path, 64 * 1024)) orelse {
        return try allocator.dupe(u8, git_dir);
    };
    defer allocator.free(contents);
    const value = std.mem.trim(u8, contents, " \t\r\n");
    if (value.len == 0) return try allocator.dupe(u8, git_dir);
    const joined = if (std.fs.path.isAbsolute(value))
        try allocator.dupe(u8, value)
    else
        try std.fs.path.join(allocator, &.{ git_dir, value });
    defer allocator.free(joined);
    return try realPathOwned(allocator, io, joined);
}

fn realPathOwned(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(resolved);
    return try allocator.dupe(u8, resolved);
}

fn readMetadataFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn providerFromRemotes(remotes: []const u8) Provider {
    if (std.mem.indexOf(u8, remotes, "github") != null) return .github;
    if (std.mem.indexOf(u8, remotes, "gitlab") != null) return .gitlab;
    return .generic;
}

test "provider detection is available to the fast metadata path" {
    try std.testing.expectEqual(Provider.github, providerFromRemotes("origin git@github.com:owner/repo.git"));
    try std.testing.expectEqual(Provider.gitlab, providerFromRemotes("origin https://gitlab.com/owner/repo.git"));
    try std.testing.expectEqual(Provider.generic, providerFromRemotes("origin ssh://git.example/repo.git"));
}

test "fast inspection reads nested repository metadata without spawning git" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var git_dir = try tmp.dir.createDirPathOpen(io, "repo/.git", .{});
    git_dir.close(io);
    var nested = try tmp.dir.createDirPathOpen(io, "repo/a/b", .{});
    nested.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.git/HEAD",
        .data = "ref: refs/heads/feature/direct-metadata\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/.git/config",
        .data = "[remote \"origin\"]\n\turl = git@github.com:owner/repo.git\n",
    });

    const cwd = try tmp.dir.realPathFileAlloc(io, "repo/a/b", allocator);
    defer allocator.free(cwd);
    const root = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root);
    const expected_git_dir = try tmp.dir.realPathFileAlloc(io, "repo/.git", allocator);
    defer allocator.free(expected_git_dir);

    var info = (try inspectFast(allocator, io, cwd)) orelse return error.TestUnexpectedResult;
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings(root, info.root);
    try std.testing.expectEqualStrings(expected_git_dir, info.dir);
    try std.testing.expectEqualStrings("feature/direct-metadata", info.branch.?);
    try std.testing.expectEqual(Provider.github, info.provider);
}

test "fast inspection resolves worktree gitdir and common config" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var worktree = try tmp.dir.createDirPathOpen(io, "worktree", .{});
    worktree.close(io);
    var worktree_git = try tmp.dir.createDirPathOpen(io, "common/worktrees/feature", .{});
    worktree_git.close(io);
    try tmp.dir.writeFile(io, .{
        .sub_path = "worktree/.git",
        .data = "gitdir: ../common/worktrees/feature\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "common/worktrees/feature/HEAD",
        .data = "ref: refs/heads/worktree-branch\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "common/worktrees/feature/commondir",
        .data = "../..\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "common/config",
        .data = "[remote \"origin\"]\n\turl = https://gitlab.com/owner/repo.git\n",
    });

    const cwd = try tmp.dir.realPathFileAlloc(io, "worktree", allocator);
    defer allocator.free(cwd);
    var info = (try inspectFast(allocator, io, cwd)) orelse return error.TestUnexpectedResult;
    defer info.deinit(allocator);
    try std.testing.expectEqualStrings("worktree-branch", info.branch.?);
    try std.testing.expectEqual(Provider.gitlab, info.provider);
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

test "fast inspection finds repository root and branch metadata" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);

    var info = (try inspectFast(allocator, io, cwd)) orelse return error.TestUnexpectedResult;
    defer info.deinit(allocator);

    try std.testing.expect(contextPathContains(info.root, cwd));
    try std.testing.expect(info.provider != .unknown);
}

fn contextPathContains(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or
        (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/');
}
