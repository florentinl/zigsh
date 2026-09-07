//! Worker-only Kubernetes provider. Delegate YAML parsing and KUBECONFIG merge
//! semantics to kubectl; never inspect config files or launch a process in ZLE.
const std = @import("std");
const context = @import("context.zig");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const max_config_bytes = 1024 * 1024;
pub const max_text_bytes = 4096;

/// Called only in the dedicated, time-limited worker process. This is a local
/// config read, not a cluster request; no exec credential plugin is invoked.
/// Empty output means unavailable (including an absent kubectl executable).
pub fn inspect(allocator: std.mem.Allocator) ![]u8 {
    // Respect even unexported Zsh parameters in the forked shell snapshot.
    inline for (.{ "HOME", "KUBECONFIG", "PATH" }) |name| {
        const value = try context.parameterValue(allocator, name);
        defer if (value) |owned| allocator.free(owned);
        if (value) |text| {
            const terminated = try allocator.dupeZ(u8, text);
            defer allocator.free(terminated);
            if (c.setenv(name, terminated.ptr, 1) != 0) return error.EnvironmentUnavailable;
        } else if (c.unsetenv(name) != 0) return error.EnvironmentUnavailable;
    }

    // Constant argv: config paths and names are never interpolated into shell
    // code. pclose and all file/process waits occur in the worker, not ZLE.
    const pipe = c.popen("kubectl config view -o json 2>/dev/null", "r") orelse return error.ProcessUnavailable;
    var open = true;
    defer if (open) {
        _ = c.pclose(pipe);
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = c.fread(&buffer, 1, buffer.len, pipe);
        if (count == 0) break;
        if (count > max_config_bytes - output.items.len) return error.ConfigTooLarge;
        try output.appendSlice(allocator, buffer[0..count]);
    }
    if (c.ferror(pipe) != 0) return error.ConfigReadFailed;
    const status = c.pclose(pipe);
    open = false;
    if (status != 0) return allocator.dupe(u8, "");
    return textFromConfig(allocator, output.items);
}

const Config = struct {
    @"current-context": []const u8 = "",
    contexts: ?[]const Entry = null,

    const Entry = struct {
        name: []const u8,
        context: struct { namespace: []const u8 = "" } = .{},
    };
};

fn textFromConfig(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Config, allocator, source, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const selected = parsed.value.@"current-context";
    if (selected.len == 0) return allocator.dupe(u8, "");
    for (parsed.value.contexts orelse &.{}) |entry| {
        if (!std.mem.eql(u8, entry.name, selected)) continue;
        const namespace = entry.context.namespace;
        // Bound the result before allocating/returning it to the shell.
        if (selected.len > max_text_bytes / 2 or namespace.len > max_text_bytes / 2 - 16) return error.LabelTooLong;
        return if (namespace.len == 0)
            std.fmt.allocPrint(allocator, "󱃾  {s} ", .{selected})
        else
            std.fmt.allocPrint(allocator, "󱃾  {s} {s} ", .{ selected, namespace });
    }
    // Do not present a name that has no corresponding context as trustworthy.
    return allocator.dupe(u8, "");
}

test "Kubernetes provider selects from canonical merged JSON" {
    const source =
        \\{"current-context":"local # literal","contexts":[
        \\ {"name":"other","context":{"namespace":"wrong"}},
        \\ {"name":"local # literal","context":{"namespace":"development","cluster":"local"}}
        \\],"clusters":[],"users":[]}
    ;
    const text = try textFromConfig(std.testing.allocator, source);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("󱃾  local # literal development ", text);
}

test "Kubernetes provider handles omitted namespace and unavailable contexts" {
    const text = try textFromConfig(std.testing.allocator,
        \\{"current-context":"local","contexts":[{"name":"local","context":{}}]}
    );
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("󱃾  local ", text);
    for ([_][]const u8{ "{}", "{\"contexts\":null}", "{\"current-context\":\"missing\"}" }) |source| {
        const hidden = try textFromConfig(std.testing.allocator, source);
        defer std.testing.allocator.free(hidden);
        try std.testing.expectEqualStrings("", hidden);
    }
}

test "Kubernetes provider rejects malformed JSON" {
    try std.testing.expectError(error.SyntaxError, textFromConfig(std.testing.allocator, "not JSON"));
}
