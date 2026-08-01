const history = @import("history.zig");
const highlight = @import("highlight/mod.zig");
const prompt = @import("prompt.zig");
const std = @import("std");
const zle_hooks = @import("zle_hooks.zig");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

fn zigsh(
    _: [*c]u8,
    args: [*c][*c]u8,
    _: zsh.Options,
    _: c_int,
) callconv(.c) c_int {
    if (args[0] != null and std.mem.eql(u8, std.mem.span(args[0]), "timing")) {
        return printTimings();
    }
    _ = zsh.printf("Hello from Zig!\n");
    return 0;
}

fn printTimings() c_int {
    const snapshot = prompt.metrics.latest() orelse {
        _ = zsh.printf("No prompt render has completed yet.\n");
        return 1;
    };

    var lines: [14]prompt.metrics.Line = undefined;
    const collected = prompt.metrics.collect(snapshot, &lines);
    _ = zsh.printf("Prompt timings from the last render (>=1ms or output):\n");
    for (collected) |line| {
        const rendered = formatTimingLine(line) catch return 1;
        defer std.heap.c_allocator.free(rendered);
        const terminated = std.heap.c_allocator.dupeZ(u8, rendered) catch return 1;
        defer std.heap.c_allocator.free(terminated);
        _ = zsh.printf("%s\n", terminated.ptr);
    }
    return 0;
}

fn formatTimingLine(line: prompt.metrics.Line) ![]u8 {
    const allocator = std.heap.c_allocator;
    const milliseconds = line.duration_ns / std.time.ns_per_ms;
    const base = if (milliseconds == 0)
        try std.fmt.allocPrint(allocator, "{s: >12}  -  <1ms", .{line.name})
    else
        try std.fmt.allocPrint(allocator, "{s: >12}  -  {d: >4}ms", .{ line.name, milliseconds });
    defer allocator.free(base);
    if (line.text) |text| return std.fmt.allocPrint(allocator, "{s}  -   \"{s}\"", .{ base, text });
    return allocator.dupe(u8, base);
}

var builtins = [_]zsh.struct_builtin{.{
    .node = .{
        .next = null,
        .nam = @constCast("zigsh"),
        .flags = 0,
    },
    .handlerfunc = &zigsh,
    .minargs = 0,
    .maxargs = -1,
    .funcid = 0,
    .optstr = null,
    .defopts = null,
}};

var module_features = zsh.struct_features{
    .bn_list = &builtins,
    .bn_size = builtins.len,
    .cd_list = null,
    .cd_size = 0,
    .mf_list = null,
    .mf_size = 0,
    .pd_list = null,
    .pd_size = 0,
    .n_abstract = 0,
};

pub export fn setup_(_: zsh.Module) callconv(.c) c_int {
    const history_result = history.setup();
    if (history_result != 0) return history_result;

    const hooks_result = zle_hooks.setup();
    if (hooks_result != 0) {
        history.cleanup();
        return hooks_result;
    }

    const prompt_result = prompt.setup();
    if (prompt_result != 0) {
        zle_hooks.cleanup();
        history.cleanup();
        return prompt_result;
    }

    const highlight_result = highlight.setup();
    if (highlight_result != 0) {
        prompt.cleanup();
        zle_hooks.cleanup();
        history.cleanup();
        return highlight_result;
    }
    return 0;
}

pub export fn features_(module: zsh.Module, out: [*c][*c][*c]u8) callconv(.c) c_int {
    out.* = zsh.featuresarray(module, &module_features);
    return 0;
}

pub export fn enables_(module: zsh.Module, out: [*c][*c]c_int) callconv(.c) c_int {
    return zsh.handlefeatures(module, &module_features, out);
}

pub export fn boot_(_: zsh.Module) callconv(.c) c_int {
    return 0;
}

pub export fn cleanup_(module: zsh.Module) callconv(.c) c_int {
    highlight.cleanup();
    prompt.cleanup();
    zle_hooks.cleanup();
    history.cleanup();
    return zsh.setfeatureenables(module, &module_features, null);
}

pub export fn finish_(_: zsh.Module) callconv(.c) c_int {
    return 0;
}
