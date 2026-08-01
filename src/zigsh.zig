const history = @import("history.zig");
const highlight = @import("highlight/mod.zig");
const prompt = @import("prompt.zig");
const std = @import("std");
const async_manager = @import("async/manager.zig");
const zle_hooks = @import("zle_hooks.zig");
const zle_events = @import("zle_events.zig");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

fn zigsh(
    _: [*c]u8,
    args: [*c][*c]u8,
    _: zsh.Options,
    _: c_int,
) callconv(.c) c_int {
    if (args[0] != null and std.mem.eql(u8, std.mem.span(args[0]), "timings")) {
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

    _ = zsh.printf(
        "Prompt pipeline (latest render: %s, changed: %s):\n",
        triggerName(snapshot.trigger),
        changedName(snapshot.prompt_changed),
    );
    const phases = snapshot.phases;
    if (!printDurationLine("render_total", phases.render_total_ns, null)) return 1;
    if (!printDurationLine("initial_total", phases.initial_total_ns, "last preprompt")) return 1;
    if (!printDurationLine("context", phases.context_ns, "cwd + fast Git")) return 1;
    if (!printDurationLine("sync_wait", phases.sync_wait_ns, "8ms budget")) return 1;
    if (!printDurationLine("cache", phases.cache_ns, null)) return 1;
    if (!printDurationLine("segments", phases.segments_ns, null)) return 1;
    if (!printDurationLine("layout", phases.layout_ns, "measure + render")) return 1;
    if (!printDurationLine("assignment", phases.assignment_ns, "PROMPT + RPROMPT")) return 1;
    _ = zsh.printf("Background dependencies:\n");
    if (!printDurationLine("git_worker", phases.git_worker_ns, null)) return 1;
    if (!printDurationLine("settled_after", phases.settled_after_ns, "request to applied result")) return 1;

    var lines: [prompt.metrics.max_lines]prompt.metrics.Line = undefined;
    const collected = prompt.metrics.collect(snapshot, &lines);
    _ = zsh.printf("Segment renderers (>=1ms or output; dependencies excluded):\n");
    for (collected) |line| {
        const rendered = formatTimingLine(line) catch return 1;
        defer std.heap.c_allocator.free(rendered);
        if (!printLine(rendered)) return 1;
    }
    return 0;
}

fn triggerName(trigger: prompt.metrics.Trigger) [*:0]const u8 {
    return switch (trigger) {
        .preprompt => "preprompt",
        .async_completion => "async completion",
        .resize => "resize",
    };
}

fn changedName(changed: bool) [*:0]const u8 {
    return if (changed) "yes" else "no";
}

fn printDurationLine(name: []const u8, duration_ns: u64, note: ?[]const u8) bool {
    const rendered = formatDurationLine(name, duration_ns, note) catch return false;
    defer std.heap.c_allocator.free(rendered);
    return printLine(rendered);
}

fn printLine(line: []const u8) bool {
    const terminated = std.heap.c_allocator.dupeZ(u8, line) catch return false;
    defer std.heap.c_allocator.free(terminated);
    _ = zsh.printf("%s\n", terminated.ptr);
    return true;
}

fn formatDurationLine(name: []const u8, duration_ns: u64, note: ?[]const u8) ![]u8 {
    const allocator = std.heap.c_allocator;
    const duration = try formatDuration(duration_ns);
    defer allocator.free(duration);
    if (note) |value| return std.fmt.allocPrint(allocator, " {s: <16} - {s: >9}  ({s})", .{ name, duration, value });
    return std.fmt.allocPrint(allocator, " {s: <16} - {s: >9}", .{ name, duration });
}

fn formatDuration(duration_ns: u64) ![]u8 {
    const allocator = std.heap.c_allocator;
    if (duration_ns >= std.time.ns_per_ms) {
        const whole_ms = duration_ns / std.time.ns_per_ms;
        const fractional = (duration_ns % std.time.ns_per_ms) / (std.time.ns_per_ms / 100);
        return std.fmt.allocPrint(allocator, "{d}.{d:0>2}ms", .{ whole_ms, fractional });
    }
    if (duration_ns >= std.time.ns_per_us) return std.fmt.allocPrint(allocator, "{d}us", .{duration_ns / std.time.ns_per_us});
    return std.fmt.allocPrint(allocator, "{d}ns", .{duration_ns});
}

fn formatTimingLine(line: prompt.metrics.Line) ![]u8 {
    const allocator = std.heap.c_allocator;
    const duration = try formatDuration(line.duration_ns);
    defer allocator.free(duration);
    const base = try std.fmt.allocPrint(allocator, " {s: <16} - {s: >9}", .{ line.name, duration });
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

    const events_result = zle_events.setup();
    if (events_result != 0) {
        zle_hooks.cleanup();
        history.cleanup();
        return events_result;
    }

    const async_result = async_manager.setup();
    if (async_result != 0) {
        zle_events.cleanup();
        zle_hooks.cleanup();
        history.cleanup();
        return async_result;
    }

    const prompt_result = prompt.setup();
    if (prompt_result != 0) {
        async_manager.cleanup();
        zle_events.cleanup();
        zle_hooks.cleanup();
        history.cleanup();
        return prompt_result;
    }

    const highlight_result = highlight.setup();
    if (highlight_result != 0) {
        prompt.cleanup();
        async_manager.cleanup();
        zle_events.cleanup();
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
    async_manager.cleanup();
    zle_events.cleanup();
    zle_hooks.cleanup();
    history.cleanup();
    return zsh.setfeatureenables(module, &module_features, null);
}

pub export fn finish_(_: zsh.Module) callconv(.c) c_int {
    return 0;
}
