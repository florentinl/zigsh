const std = @import("std");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

const allocator = std.heap.c_allocator;
const io = std.Io.Threaded.global_single_threaded.io();

const Position = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

const Cache = struct {
    key: u64 = 0,
    value: ?[]u8 = null,

    fn getOrUpdate(
        self: *Cache,
        key: u64,
        next_value: []const u8,
    ) ![]const u8 {
        if (self.value != null and self.key == key) return self.value.?;

        const replacement = try allocator.dupe(u8, next_value);
        if (self.value) |value| allocator.free(value);
        self.key = key;
        self.value = replacement;
        return replacement;
    }

    fn deinit(self: *Cache) void {
        if (self.value) |value| allocator.free(value);
        self.* = .{};
    }
};

const Segment = struct {
    position: Position,
    cache: Cache = .{},
    render: *const fn (*Segment, *const Context) anyerror![]const u8,

    fn deinit(self: *Segment) void {
        self.cache.deinit();
    }
};

const Git = struct {
    root: []const u8,
    dir: []const u8,
    head: []const u8,

    fn deinit(self: *Git) void {
        allocator.free(self.root);
        allocator.free(self.dir);
        allocator.free(self.head);
    }
};

const Context = struct {
    cwd: []const u8,
    git: ?Git,
    status: c_long,

    fn init() !Context {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(cwd);

        return .{
            .cwd = cwd,
            .git = try findGit(cwd),
            .status = zsh.lastval,
        };
    }

    fn deinit(self: *Context) void {
        allocator.free(self.cwd);
        if (self.git) |*git| git.deinit();
    }
};

var segments = [_]Segment{
    .{ .position = .top_left, .render = renderOs },
    .{ .position = .top_left, .render = renderDirectory },
    .{ .position = .top_left, .render = renderBranch },
    .{ .position = .top_left, .render = renderGitStatus },
    .{ .position = .top_right, .render = renderLastStatus },
    .{ .position = .bottom_left, .render = renderArrow },
    .{ .position = .bottom_right, .render = renderEmpty },
};

var preprompt_registered = false;

pub fn setup() c_int {
    // Prompt content is fully rendered by this module; `%` escapes remain
    // disabled so Zsh never evaluates shell substitutions while drawing it.
    zsh.opts[zsh.PROMPTSUBST] = 0;
    zsh.rprompt_indent = 0;

    renderPrompt();
    zsh.addprepromptfn(renderPrompt);
    preprompt_registered = true;
    return 0;
}

pub fn cleanup() void {
    if (preprompt_registered) {
        zsh.delprepromptfn(renderPrompt);
        preprompt_registered = false;
    }
    for (&segments) |*segment| segment.deinit();
}

fn renderPrompt() callconv(.c) void {
    var context = Context.init() catch return;
    defer context.deinit();

    var top_left: std.ArrayList(u8) = .empty;
    defer top_left.deinit(allocator);
    var top_right: std.ArrayList(u8) = .empty;
    defer top_right.deinit(allocator);
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);
    var rprompt: std.ArrayList(u8) = .empty;
    defer rprompt.deinit(allocator);

    appendPosition(&top_left, .top_left, &context) catch return;
    appendPosition(&top_right, .top_right, &context) catch return;
    appendTopRow(&prompt, top_left.items, top_right.items) catch return;
    prompt.append(allocator, '\n') catch return;
    appendPosition(&prompt, .bottom_left, &context) catch return;
    appendPosition(&rprompt, .bottom_right, &context) catch return;

    assignPrompt("PROMPT", prompt.items);
    assignPrompt("RPROMPT", rprompt.items);
}

fn appendTopRow(output: *std.ArrayList(u8), left: []const u8, right: []const u8) !void {
    try output.appendSlice(allocator, left);
    if (right.len == 0) return;

    const columns: usize = if (zsh.zterm_columns > 0) @intCast(zsh.zterm_columns) else 80;
    const used = displayWidth(left) + displayWidth(right);
    const padding = if (columns > used) columns - used else 1;
    try output.appendNTimes(allocator, ' ', padding);
    try output.appendSlice(allocator, right);
}

fn appendPosition(
    output: *std.ArrayList(u8),
    position: Position,
    context: *const Context,
) !void {
    var wrote_segment = false;
    for (&segments) |*segment| {
        if (segment.position != position) continue;

        const value = try segment.render(segment, context);
        if (value.len == 0) continue;
        if (wrote_segment) try output.append(allocator, ' ');
        try output.appendSlice(allocator, value);
        wrote_segment = true;
    }
}

fn assignPrompt(name: [:0]const u8, value: []const u8) void {
    const terminated = allocator.dupeZ(u8, value) catch return;
    // setsparam follows Zsh's parameter setter and transfers this allocation
    // to the shell, including replacement of the old prompt buffer.
    _ = zsh.setsparam(@constCast(name.ptr), zsh.ztrdup_metafy(terminated.ptr));
    allocator.free(terminated);
}

fn renderOs(segment: *Segment, _: *const Context) ![]const u8 {
    return segment.cache.getOrUpdate(0, "");
}

fn renderDirectory(segment: *Segment, context: *const Context) ![]const u8 {
    const root = if (context.git) |git| git.root else null;
    const key = hashPathPair(context.cwd, root);
    if (segment.cache.value != null and segment.cache.key == key) return segment.cache.value.?;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    if (root) |git_root| {
        try output.appendSlice(allocator, std.fs.path.basename(git_root));
        if (context.cwd.len > git_root.len) {
            try output.append(allocator, '/');
            try output.appendSlice(allocator, context.cwd[git_root.len + 1 ..]);
        }
    } else if (std.c.getenv("HOME")) |home_pointer| {
        const home = std.mem.span(home_pointer);
        if (isPathPrefix(home, context.cwd)) {
            try output.append(allocator, '~');
            if (context.cwd.len > home.len) try output.appendSlice(allocator, context.cwd[home.len..]);
        } else {
            try output.appendSlice(allocator, context.cwd);
        }
    } else {
        try output.appendSlice(allocator, context.cwd);
    }

    return segment.cache.getOrUpdate(key, output.items);
}

fn renderBranch(segment: *Segment, context: *const Context) ![]const u8 {
    const git = context.git orelse return segment.cache.getOrUpdate(0, "");
    const key = hashPathPair(git.dir, git.head);
    const branch = branchName(git.head);
    return segment.cache.getOrUpdate(key, branch);
}

fn renderGitStatus(segment: *Segment, context: *const Context) ![]const u8 {
    const git = context.git orelse return segment.cache.getOrUpdate(0, "");

    // These repository-operation files are cheap native checks and provide a
    // useful first status signal without running Git or a shell command.
    const operation = if (try fileExists(git.dir, "MERGE_HEAD")) "merge" else if (try fileExists(git.dir, "CHERRY_PICK_HEAD")) "cherry-pick" else if (try fileExists(git.dir, "REVERT_HEAD")) "revert" else if (try fileExists(git.dir, "rebase-merge")) "rebase" else if (try fileExists(git.dir, "rebase-apply")) "rebase" else "";
    return segment.cache.getOrUpdate(hashPathPair(git.dir, operation), operation);
}

fn renderLastStatus(segment: *Segment, context: *const Context) ![]const u8 {
    var buffer: [32]u8 = undefined;
    const text = if (context.status == 0)
        "ok"
    else
        try std.fmt.bufPrint(&buffer, "exit {d}", .{context.status});
    return segment.cache.getOrUpdate(@bitCast(context.status), text);
}

fn renderArrow(segment: *Segment, _: *const Context) ![]const u8 {
    return segment.cache.getOrUpdate(0, "--> ");
}

fn renderEmpty(segment: *Segment, _: *const Context) ![]const u8 {
    return segment.cache.getOrUpdate(0, "");
}

fn findGit(cwd: []const u8) !?Git {
    var directory = cwd;
    while (true) {
        const dot_git = try std.fs.path.join(allocator, &.{ directory, ".git" });
        defer allocator.free(dot_git);

        if (try gitDirectory(dot_git)) |git_dir| {
            errdefer allocator.free(git_dir);
            const head_path = try std.fs.path.join(allocator, &.{ git_dir, "HEAD" });
            defer allocator.free(head_path);
            const head = std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096)) catch {
                allocator.free(git_dir);
                return null;
            };
            return .{
                .root = try allocator.dupe(u8, directory),
                .dir = git_dir,
                .head = head,
            };
        }

        directory = std.fs.path.dirname(directory) orelse return null;
    }
}

fn gitDirectory(dot_git: []const u8) !?[]u8 {
    if (try directoryExists(dot_git)) return @as(?[]u8, try allocator.dupe(u8, dot_git));

    const contents = std.Io.Dir.cwd().readFileAlloc(io, dot_git, allocator, .limited(4096)) catch return null;
    defer allocator.free(contents);
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, contents, prefix)) return null;

    const path = std.mem.trimEnd(u8, contents[prefix.len..], "\r\n");
    if (std.fs.path.isAbsolute(path)) return @as(?[]u8, try allocator.dupe(u8, path));
    return @as(?[]u8, try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(dot_git).?, path }));
}

fn branchName(head: []const u8) []const u8 {
    const reference_prefix = "ref: refs/heads/";
    const trimmed = std.mem.trimEnd(u8, head, "\r\n");
    if (std.mem.startsWith(u8, trimmed, reference_prefix)) return trimmed[reference_prefix.len..];
    return if (trimmed.len > 7) trimmed[0..7] else trimmed;
}

fn directoryExists(path: []const u8) !bool {
    const status = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return status.kind == .directory;
}

fn fileExists(directory: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn isPathPrefix(prefix: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, prefix, path) or
        (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}

fn hashPathPair(first: []const u8, second: ?[]const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(first);
    if (second) |value| hasher.update(value);
    return hasher.final();
}

fn displayWidth(text: []const u8) usize {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var width: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        width += if (codepoint >= 0x1100) 2 else 1;
    }
    return width;
}
