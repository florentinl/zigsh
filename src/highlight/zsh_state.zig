const std = @import("std");
const semantic = @import("semantic.zig");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

pub const State = struct {
    allocator: std.mem.Allocator,

    pub fn aliasKind(_: *const State, word: []const u8, command_position: bool) ?semantic.AliasKind {
        if (lookupEnabled(zsh.aliastab, word)) |node| {
            if ((node.*.flags & zsh.ALIAS_GLOBAL) != 0) return .global;
            if (command_position) return .regular;
        }
        if (!command_position) return null;
        const suffix = suffixOf(word) orelse return null;
        return if (lookupEnabled(zsh.sufaliastab, suffix) != null) .suffix else null;
    }

    pub fn commandKind(self: *const State, word: []const u8) semantic.CommandKind {
        if (lookupEnabled(zsh.reswdtab, word) != null) return .reserved_word;
        if (lookupEnabled(zsh.shfunctab, word) != null) return .shell_function;
        if (lookupEnabled(zsh.builtintab, word) != null) return .builtin;
        if (lookupEnabled(zsh.cmdnamtab, word)) |node| {
            return if ((node.*.flags & zsh.HASHED) != 0) .hashed_command else .external_command;
        }
        if (self.commandPathExists(word)) return .external_command;
        if (optionEnabled(zsh.AUTOCD) and self.directoryExists(word, true)) return .auto_directory;
        return .unknown;
    }

    pub fn regularAliasExpandsNext(_: *const State, word: []const u8) bool {
        const node = lookupEnabled(zsh.aliastab, word) orelse return false;
        if ((node.*.flags & zsh.ALIAS_GLOBAL) != 0) return false;
        const alias: zsh.Alias = @ptrCast(@alignCast(node));
        if (alias.*.text == null) return false;
        const expansion = std.mem.span(alias.*.text);
        return expansion.len > 0 and std.ascii.isWhitespace(expansion[expansion.len - 1]);
    }

    pub fn pathKind(self: *const State, word: []const u8, allow_prefix: bool, command_position: bool) semantic.PathKind {
        const path = self.expandSimplePath(word) orelse return .none;
        defer self.allocator.free(path);
        if (command_position) {
            return if (allow_prefix and pathPrefixExists(self.allocator, path)) .prefix else .none;
        }
        if (pathExists(self.allocator, path)) return .path;
        if (!std.fs.path.isAbsolute(path) and self.cdPathExists(path)) return .path;
        if (allow_prefix and pathPrefixExists(self.allocator, path)) return .prefix;
        return .none;
    }

    pub fn historyEnabled(_: *const State) bool {
        return optionEnabled(zsh.BANGHIST);
    }

    pub fn historyCharacter(_: *const State) u8 {
        return zsh.bangchar;
    }

    fn commandPathExists(self: *const State, word: []const u8) bool {
        if (std.mem.indexOfScalar(u8, word, '/') != null) {
            if (isExecutableFile(self.allocator, word)) return true;
            if (std.fs.path.isAbsolute(word) or
                std.mem.startsWith(u8, word, "./") or
                std.mem.startsWith(u8, word, "../") or
                !optionEnabled(zsh.PATHDIRS)) return false;
        }

        var path_index: usize = 0;
        while (zsh.path[path_index] != null) : (path_index += 1) {
            const directory = copyUnmetafied(self.allocator, zsh.path[path_index]) catch continue;
            defer self.allocator.free(directory);
            const candidate = if (directory.len == 0)
                self.allocator.dupe(u8, word) catch continue
            else
                std.fs.path.join(self.allocator, &.{ directory, word }) catch continue;
            defer self.allocator.free(candidate);
            if (isExecutableFile(self.allocator, candidate)) return true;
        }
        return false;
    }

    fn directoryExists(self: *const State, word: []const u8, use_cdpath: bool) bool {
        const path = self.expandSimplePath(word) orelse return false;
        defer self.allocator.free(path);
        if (isSearchableDirectory(self.allocator, path)) return true;
        return use_cdpath and !std.fs.path.isAbsolute(path) and self.cdPathExists(path);
    }

    fn cdPathExists(self: *const State, path: []const u8) bool {
        var index: usize = 0;
        while (zsh.cdpath[index] != null) : (index += 1) {
            const directory = copyUnmetafied(self.allocator, zsh.cdpath[index]) catch continue;
            defer self.allocator.free(directory);
            const candidate = std.fs.path.join(self.allocator, &.{ directory, path }) catch continue;
            defer self.allocator.free(candidate);
            if (isSearchableDirectory(self.allocator, candidate)) return true;
        }
        return false;
    }

    fn expandSimplePath(self: *const State, word: []const u8) ?[]u8 {
        const unquoted = simpleUnquote(word) orelse return null;
        if (std.mem.eql(u8, unquoted, "~")) return copyUnmetafied(self.allocator, zsh.home) catch null;
        if (std.mem.startsWith(u8, unquoted, "~/")) {
            const home = copyUnmetafied(self.allocator, zsh.home) catch return null;
            defer self.allocator.free(home);
            return std.fs.path.join(self.allocator, &.{ home, unquoted[2..] }) catch null;
        }
        if (std.mem.startsWith(u8, unquoted, "~")) return self.expandNamedDirectory(unquoted);
        if (std.mem.indexOfAny(u8, unquoted, "$`*?[]{}()<>|;&!") != null) return null;
        return self.allocator.dupe(u8, unquoted) catch null;
    }

    fn expandNamedDirectory(self: *const State, word: []const u8) ?[]u8 {
        const slash = std.mem.indexOfScalar(u8, word, '/') orelse word.len;
        const name = word[1..slash];
        if (name.len == 0) return null;
        const node = lookupEnabled(zsh.nameddirtab, name) orelse return null;
        const named_directory: zsh.Nameddir = @ptrCast(@alignCast(node));
        const directory = copyUnmetafied(self.allocator, named_directory.*.dir) catch return null;
        if (slash == word.len) return directory;
        defer self.allocator.free(directory);
        return std.fs.path.join(self.allocator, &.{ directory, word[slash + 1 ..] }) catch null;
    }
};

fn lookup(table: zsh.HashTable, word: []const u8) zsh.HashNode {
    if (table == null or word.len == 0) return null;
    const key = zsh.metafy(@ptrCast(@constCast(word.ptr)), @intCast(word.len), zsh.META_DUP);
    if (key == null) return null;
    defer zsh.zsfree(key);
    return table.*.getnode.?(table, key);
}

fn lookupEnabled(table: zsh.HashTable, word: []const u8) zsh.HashNode {
    const node = lookup(table, word) orelse return null;
    return if ((node.*.flags & zsh.DISABLED) == 0) node else null;
}

fn suffixOf(word: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, word, '.') orelse return null;
    if (dot + 1 == word.len or std.mem.indexOfScalar(u8, word[dot + 1 ..], '/') != null) return null;
    return word[dot + 1 ..];
}

fn optionEnabled(option: c_int) bool {
    return option >= 0 and @as(usize, @intCast(option)) < zsh.opts.len and zsh.opts[@intCast(option)] != 0;
}

fn simpleUnquote(word: []const u8) ?[]const u8 {
    if (word.len < 2) return word;
    const first = word[0];
    if ((first == '\'' or first == '"') and word[word.len - 1] == first) return word[1 .. word.len - 1];
    if (std.mem.indexOfAny(u8, word, "'\"\\") != null) return null;
    return word;
}

fn copyUnmetafied(allocator: std.mem.Allocator, value: [*c]u8) ![]u8 {
    if (value == null) return allocator.alloc(u8, 0);
    const encoded = std.mem.span(value);
    const copy = try allocator.dupeZ(u8, encoded);
    defer allocator.free(copy);
    var length: c_int = @intCast(encoded.len);
    _ = zsh.unmetafy(copy.ptr, &length);
    return allocator.dupe(u8, copy[0..@intCast(length)]);
}

fn pathExists(allocator: std.mem.Allocator, path: []const u8) bool {
    const terminated = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(terminated);
    var status: zsh.struct_stat = undefined;
    return zsh.lstat(terminated.ptr, &status) == 0;
}

fn isExecutableFile(allocator: std.mem.Allocator, path: []const u8) bool {
    const terminated = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(terminated);
    var status: zsh.struct_stat = undefined;
    return zsh.access(terminated.ptr, zsh.X_OK) == 0 and
        zsh.stat(terminated.ptr, &status) == 0 and
        zsh.S_ISREG(status.st_mode);
}

fn isSearchableDirectory(allocator: std.mem.Allocator, path: []const u8) bool {
    const terminated = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(terminated);
    var status: zsh.struct_stat = undefined;
    return zsh.access(terminated.ptr, zsh.X_OK) == 0 and
        zsh.stat(terminated.ptr, &status) == 0 and
        zsh.S_ISDIR(status.st_mode);
}

fn pathPrefixExists(allocator: std.mem.Allocator, path: []const u8) bool {
    const directory_name = std.fs.path.dirname(path) orelse ".";
    const prefix = std.fs.path.basename(path);
    if (prefix.len == 0) return false;

    const directory = allocator.dupeZ(u8, directory_name) catch return false;
    defer allocator.free(directory);
    const handle = zsh.opendir(directory.ptr) orelse return false;
    defer _ = zsh.closedir(handle);
    while (zsh.readdir(handle)) |entry| {
        const bytes = entry.*.d_name[0..];
        const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
        const name = bytes[0..end];
        if (!std.mem.eql(u8, name, prefix) and std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

test "simple path quoting is conservative" {
    try std.testing.expectEqualStrings("hello world", simpleUnquote("'hello world'").?);
    try std.testing.expect(simpleUnquote("foo\\ bar") == null);
}
