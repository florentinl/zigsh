const std = @import("std");
const semantic = @import("semantic.zig");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

pub const State = struct {
    allocator: std.mem.Allocator,

    pub fn aliasKind(_: *const State, word: []const u8, command_position: bool) ?semantic.AliasKind {
        if (!optionEnabled(zsh.ALIASESOPT)) return null;
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
        if (lookupEnabled(zsh.shfunctab, word)) |node| {
            if (self.shellFunctionAvailable(word, node)) return .shell_function;
        }
        if (lookupEnabled(zsh.builtintab, word) != null) return .builtin;
        if (lookupEnabled(zsh.cmdnamtab, word)) |node| {
            return if ((node.*.flags & zsh.HASHED) != 0) .hashed_command else .external_command;
        }
        if (self.commandPathExists(word)) return .external_command;
        if (optionEnabled(zsh.AUTOCD) and self.directoryExists(word, true)) return .auto_directory;
        return .unknown;
    }

    pub fn regularAliasExpandsNext(_: *const State, word: []const u8) bool {
        if (!optionEnabled(zsh.ALIASESOPT)) return false;
        const node = lookupEnabled(zsh.aliastab, word) orelse return false;
        if ((node.*.flags & zsh.ALIAS_GLOBAL) != 0) return false;
        const alias: zsh.Alias = @ptrCast(@alignCast(node));
        if (alias.*.text == null) return false;
        const expansion = std.mem.span(alias.*.text);
        return expansion.len > 0 and std.ascii.isWhitespace(expansion[expansion.len - 1]);
    }

    pub fn aliasExpansion(
        _: *const State,
        allocator: std.mem.Allocator,
        word: []const u8,
        kind: semantic.AliasKind,
    ) !?[]u8 {
        const node = switch (kind) {
            .regular, .global => lookupEnabled(zsh.aliastab, word),
            .suffix => lookupEnabled(zsh.sufaliastab, suffixOf(word) orelse return null),
        } orelse return null;
        const alias: zsh.Alias = @ptrCast(@alignCast(node));
        const expansion = try copyUnmetafied(allocator, alias.*.text);
        if (kind != .suffix) return expansion;
        defer allocator.free(expansion);
        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ expansion, word });
    }

    pub fn pathKind(self: *const State, word: []const u8, allow_prefix: bool, command_position: bool) semantic.PathKind {
        const path = self.expandSimplePath(word) orelse {
            return if (isEqualsExpression(word) and optionEnabled(zsh.EQUALS)) .invalid else .none;
        };
        defer self.allocator.free(path);
        if (command_position) {
            if (isEqualsExpression(word) and isExecutableFile(self.allocator, path)) return .path;
            if (allow_prefix and isSearchableDirectory(self.allocator, path)) return .prefix;
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

    pub fn commandParameterExpansion(self: *const State, _: std.mem.Allocator, word: []const u8) !?[]u8 {
        if (!isSimpleParameterExpression(word)) return null;
        return self.expandParameters(word);
    }

    pub fn commentsEnabled(_: *const State) bool {
        return optionEnabled(zsh.INTERACTIVECOMMENTS);
    }

    fn commandPathExists(self: *const State, word: []const u8) bool {
        const path = self.findCommandPath(word) orelse return false;
        self.allocator.free(path);
        return true;
    }

    fn shellFunctionAvailable(self: *const State, word: []const u8, node: zsh.HashNode) bool {
        if ((node.*.flags & zsh.PM_UNDEFINED) == 0) return true;
        const function: zsh.Shfunc = @ptrCast(@alignCast(node));
        if (function.*.filename != null and
            std.fs.path.isAbsolute(std.mem.span(function.*.filename)) and
            (node.*.flags & zsh.PM_LOADDIR) != 0)
        {
            const directory = copyUnmetafied(self.allocator, function.*.filename) catch return false;
            defer self.allocator.free(directory);
            return self.functionFileExists(directory, word);
        }

        var index: usize = 0;
        while (zsh.fpath[index] != null) : (index += 1) {
            const directory = copyUnmetafied(self.allocator, zsh.fpath[index]) catch continue;
            defer self.allocator.free(directory);
            if (self.functionFileExists(directory, word)) return true;
        }
        return false;
    }

    fn functionFileExists(self: *const State, directory: []const u8, word: []const u8) bool {
        const candidate = if (directory.len == 0)
            self.allocator.dupe(u8, word) catch return false
        else
            std.fs.path.join(self.allocator, &.{ directory, word }) catch return false;
        defer self.allocator.free(candidate);
        if (isReadableFile(self.allocator, candidate)) return true;

        const compiled = std.fmt.allocPrint(self.allocator, "{s}.zwc", .{candidate}) catch return false;
        defer self.allocator.free(compiled);
        return isReadableFile(self.allocator, compiled);
    }

    fn findCommandPath(self: *const State, word: []const u8) ?[]u8 {
        if (std.mem.indexOfScalar(u8, word, '/') != null) {
            if (isExecutableFile(self.allocator, word)) return self.allocator.dupe(u8, word) catch null;
            if (std.fs.path.isAbsolute(word) or
                std.mem.startsWith(u8, word, "./") or
                std.mem.startsWith(u8, word, "../") or
                !optionEnabled(zsh.PATHDIRS)) return null;
        }

        if (lookupEnabled(zsh.cmdnamtab, word)) |node| {
            const command: zsh.Cmdnam = @ptrCast(@alignCast(node));
            if ((node.*.flags & zsh.HASHED) != 0) {
                return copyUnmetafied(self.allocator, command.*.u.cmd) catch null;
            }
            const directory = if (command.*.u.name == null)
                self.allocator.alloc(u8, 0) catch return null
            else
                copyUnmetafied(self.allocator, command.*.u.name.*) catch return null;
            defer self.allocator.free(directory);
            return if (directory.len == 0)
                self.allocator.dupe(u8, word) catch null
            else
                std.fs.path.join(self.allocator, &.{ directory, word }) catch null;
        }

        var path_index: usize = 0;
        while (zsh.path[path_index] != null) : (path_index += 1) {
            const directory = copyUnmetafied(self.allocator, zsh.path[path_index]) catch continue;
            defer self.allocator.free(directory);
            const candidate = if (directory.len == 0)
                self.allocator.dupe(u8, word) catch continue
            else
                std.fs.path.join(self.allocator, &.{ directory, word }) catch continue;
            if (isExecutableFile(self.allocator, candidate)) return candidate;
            self.allocator.free(candidate);
        }
        return null;
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
        const simple_word = SimpleWord.parse(word) orelse return null;
        if (simple_word.literal) return self.allocator.dupe(u8, simple_word.text) catch null;

        const expanded_parameters = self.expandParameters(simple_word.text) orelse return null;
        defer self.allocator.free(expanded_parameters);
        if (isEqualsExpression(expanded_parameters) and optionEnabled(zsh.EQUALS)) {
            return self.expandEquals(expanded_parameters);
        }
        if (std.mem.eql(u8, expanded_parameters, "~") and simple_word.expand_tilde) {
            return copyUnmetafied(self.allocator, zsh.home) catch null;
        }
        if (std.mem.startsWith(u8, expanded_parameters, "~/") and simple_word.expand_tilde) {
            const home = copyUnmetafied(self.allocator, zsh.home) catch return null;
            defer self.allocator.free(home);
            return std.fs.path.join(self.allocator, &.{ home, expanded_parameters[2..] }) catch null;
        }
        if (std.mem.startsWith(u8, expanded_parameters, "~") and simple_word.expand_tilde) {
            return self.expandNamedDirectory(expanded_parameters);
        }
        if (std.mem.indexOfAny(u8, expanded_parameters, "`*?[]{}()<>|;&!") != null) return null;
        return self.allocator.dupe(u8, expanded_parameters) catch null;
    }

    fn expandParameters(self: *const State, word: []const u8) ?[]u8 {
        var expanded = std.ArrayList(u8).empty;
        defer expanded.deinit(self.allocator);
        var offset: usize = 0;
        while (offset < word.len) {
            const dollar = std.mem.indexOfScalarPos(u8, word, offset, '$') orelse {
                expanded.appendSlice(self.allocator, word[offset..]) catch return null;
                break;
            };
            expanded.appendSlice(self.allocator, word[offset..dollar]) catch return null;
            const parameter = parameterAt(word, dollar) orelse return null;
            const value = self.safeScalar(parameter.name) orelse return null;
            defer self.allocator.free(value);
            expanded.appendSlice(self.allocator, value) catch return null;
            offset = parameter.end;
        }
        return expanded.toOwnedSlice(self.allocator) catch null;
    }

    fn safeScalar(self: *const State, name: []const u8) ?[]u8 {
        if (std.mem.eql(u8, name, "HOME")) return copyUnmetafied(self.allocator, zsh.home) catch null;
        if (std.mem.eql(u8, name, "PWD")) return copyUnmetafied(self.allocator, zsh.pwd) catch null;

        const node = lookupEnabled(zsh.paramtab, name) orelse return null;
        const parameter: zsh.Param = @ptrCast(@alignCast(node));
        if (zsh.PM_TYPE(parameter.*.node.flags) != zsh.PM_SCALAR or
            (parameter.*.node.flags & (zsh.PM_SPECIAL | zsh.PM_UNSET | zsh.PM_HIDEVAL)) != 0 or
            parameter.*.u.str == null) return null;
        return copyUnmetafied(self.allocator, parameter.*.u.str) catch null;
    }

    fn expandEquals(self: *const State, word: []const u8) ?[]u8 {
        const slash = std.mem.indexOfScalar(u8, word, '/') orelse word.len;
        const command = word[1..slash];
        if (command.len == 0) return null;
        const command_path = self.findCommandPath(command) orelse return null;
        if (slash == word.len) return command_path;
        defer self.allocator.free(command_path);
        return std.fs.path.join(self.allocator, &.{ command_path, word[slash + 1 ..] }) catch null;
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

const SimpleWord = struct {
    text: []const u8,
    literal: bool,
    expand_tilde: bool,

    fn parse(word: []const u8) ?SimpleWord {
        if (word.len >= 2 and word[0] == '\'' and word[word.len - 1] == '\'') {
            return .{ .text = word[1 .. word.len - 1], .literal = true, .expand_tilde = false };
        }
        if (word.len >= 2 and word[0] == '"' and word[word.len - 1] == '"') {
            const text = word[1 .. word.len - 1];
            if (std.mem.indexOfAny(u8, text, "\\`") != null) return null;
            return .{ .text = text, .literal = false, .expand_tilde = false };
        }
        if (std.mem.indexOfAny(u8, word, "'\"\\") != null) return null;
        return .{ .text = word, .literal = false, .expand_tilde = true };
    }
};

const Parameter = struct { name: []const u8, end: usize };

fn parameterAt(word: []const u8, dollar: usize) ?Parameter {
    var start = dollar + 1;
    if (start == word.len) return null;
    const braced = word[start] == '{';
    if (braced) start += 1;
    if (start == word.len or !(std.ascii.isAlphabetic(word[start]) or word[start] == '_')) return null;

    var end = start + 1;
    while (end < word.len and (std.ascii.isAlphanumeric(word[end]) or word[end] == '_')) : (end += 1) {}
    const name_end = end;
    if (braced) {
        if (end == word.len or word[end] != '}') return null;
        end += 1;
    }
    return .{ .name = word[start..name_end], .end = end };
}

fn isSimpleParameterExpression(word: []const u8) bool {
    const parameter = parameterAt(word, 0) orelse return false;
    return parameter.end == word.len;
}

fn isEqualsExpression(word: []const u8) bool {
    return word.len > 1 and word[0] == '=' and word[1] != '(';
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

fn isReadableFile(allocator: std.mem.Allocator, path: []const u8) bool {
    const terminated = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(terminated);
    var status: zsh.struct_stat = undefined;
    return zsh.access(terminated.ptr, zsh.R_OK) == 0 and
        zsh.stat(terminated.ptr, &status) == 0 and
        zsh.S_ISREG(status.st_mode);
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
    try std.testing.expectEqualStrings("hello world", SimpleWord.parse("'hello world'").?.text);
    try std.testing.expect(SimpleWord.parse("foo\\ bar") == null);
}
