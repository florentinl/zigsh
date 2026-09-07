const std = @import("std");
const async_manager = @import("../async/manager.zig");
const zle_hooks = @import("../zle_hooks.zig");
const regions = @import("zsh59_regions.zig");
const wire = @import("wire.zig");

const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

pub const Engine = @import("engine.zig").Engine;
pub const Metrics = @import("engine.zig").Metrics;
pub const Result = @import("engine.zig").Result;
pub const Snapshot = @import("snapshot.zig").Snapshot;
pub const Span = @import("span.zig").Span;
pub const Style = @import("style.zig").Style;

var active = false;
var regions_enabled = false;
var regions_current = false;
var current_source: ?[]u8 = null;
var current_commands: [][]u8 = &.{};
var desired_snapshot: ?Snapshot = null;
var inflight_snapshot: ?Snapshot = null;
var inflight_generation: ?u64 = null;
var inflight_worker_epoch: u64 = 0;
var warm_generation: ?u64 = null;
var generation: u64 = 0;
var preprompt_registered = false;
var redraw_subscription = zle_hooks.Subscription.init(linePreRedraw);
var highlight_job = async_manager.Job.init(.line_analysis, workerCompleted);

const warm_budget_ns = 3 * std.time.ns_per_ms;
const submission_deadline_ns = std.time.ns_per_ms; // Never a foreground wait.
const allocator = std.heap.c_allocator;

pub const AnalysisCallback = *const fn () zle_hooks.Effects;

pub const AnalysisSubscription = struct {
    callback: AnalysisCallback,
    registered: bool = false,

    pub fn init(callback: AnalysisCallback) AnalysisSubscription {
        return .{ .callback = callback };
    }

    pub fn register(self: *AnalysisSubscription) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
        if (self.registered) return;
        try addAnalysisCallback(self.callback);
        self.registered = true;
    }

    pub fn unregister(self: *AnalysisSubscription) void {
        if (!self.registered) return;
        removeAnalysisCallback(self.callback);
        self.registered = false;
    }
};

const analysis_callback_capacity = 4;
var analysis_callbacks: [analysis_callback_capacity]?AnalysisCallback = @splat(null);
var analysis_callback_count: usize = 0;

pub fn currentCommands() []const []const u8 {
    return current_commands;
}

pub fn setup() c_int {
    if (active) return 0;

    regions_enabled = !highlightingDisabled();
    if (regions_enabled) regions.setup() catch {
        regions.resetTheme();
        regions_enabled = false;
        return 1;
    };
    redraw_subscription.register() catch {
        if (regions_enabled) regions.cleanup();
        regions_enabled = false;
        return 1;
    };
    highlight_job.register() catch {
        redraw_subscription.unregister();
        if (regions_enabled) regions.cleanup();
        regions_enabled = false;
        return 1;
    };
    zsh.addprepromptfn(refreshWorker);
    preprompt_registered = true;
    active = true;
    regions_current = false;
    return 0;
}

pub fn cleanup() void {
    if (!active) return;
    if (preprompt_registered) {
        zsh.delprepromptfn(refreshWorker);
        preprompt_registered = false;
    }
    highlight_job.unregister();
    redraw_subscription.unregister();
    if (regions_enabled) regions.cleanup();
    clearDesired();
    clearInflight();
    clearCurrentSource();
    _ = clearCurrentCommands();
    active = false;
    regions_enabled = false;
    regions_current = false;
    warm_generation = null;
    analysis_callbacks = @splat(null);
    analysis_callback_count = 0;
}

fn refreshWorker() callconv(.c) void {
    clearDesired();
    clearInflight();
    clearCurrentSource();
    _ = clearCurrentCommands();
    regions_current = false;
    warm_generation = null;
    if (!highlight_job.cancelAndRestart()) return;

    generation +%= 1;
    if (generation == 0) generation = 1;
    warm_generation = generation;
    const deadline = async_manager.deadlineAfter(warm_budget_ns);
    highlight_job.submit(generation, &.{}, deadline) catch {
        warm_generation = null;
        return;
    };
}

fn highlightingDisabled() bool {
    const value = zsh.getsparam(@constCast("ZIGSH_SYNTAX_HIGHLIGHTING")) orelse return false;
    const setting = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    return std.mem.eql(u8, setting, "0") or
        std.ascii.eqlIgnoreCase(setting, "false") or
        std.ascii.eqlIgnoreCase(setting, "off");
}

fn linePreRedraw() zle_hooks.Effects {
    if (inflight_generation != null and inflight_worker_epoch != highlight_job.epoch()) clearInflight();
    if (zsh.zlecontext == zsh.ZLCON_SELECT or zsh.zlecontext == zsh.ZLCON_VARED) {
        clearDesired();
        clearInflight();
        var effects = zle_hooks.Effects{ .regions_changed = clearRegions() };
        if (clearCurrentCommands()) effects.merge(notifyAnalysisCallbacks());
        return effects;
    }

    const line_length = std.math.cast(usize, zsh.zlell) orelse {
        clearDesired();
        clearInflight();
        var effects = zle_hooks.Effects{ .regions_changed = clearRegions() };
        if (clearCurrentCommands()) effects.merge(notifyAnalysisCallbacks());
        return effects;
    };
    const line: []const zsh.ZLE_CHAR_T = if (line_length == 0)
        &.{}
    else
        zsh.zleline[0..line_length];
    var snapshot = Snapshot.fromCodepoints(allocator, line) catch {
        clearDesired();
        clearInflight();
        var effects = zle_hooks.Effects{ .regions_changed = clearRegions() };
        if (clearCurrentCommands()) effects.merge(notifyAnalysisCallbacks());
        return effects;
    };
    if (desired_snapshot != null and std.mem.eql(u8, desired_snapshot.?.bytes, snapshot.bytes)) {
        snapshot.deinit(allocator);
        const matches_current = current_source != null and
            std.mem.eql(u8, current_source.?, desired_snapshot.?.bytes);
        if (inflight_generation == null and !matches_current) {
            _ = startDesired() catch {};
        }
        return .{};
    }

    clearDesired();
    desired_snapshot = snapshot;
    const matches_current = current_source != null and
        std.mem.eql(u8, current_source.?, desired_snapshot.?.bytes);
    const cleared = if (matches_current) false else clearRegions();

    if (inflight_generation != null) return .{ .regions_changed = cleared };
    if (matches_current) return .{ .regions_changed = cleared };

    _ = startDesired() catch return .{ .regions_changed = cleared };
    return .{ .regions_changed = cleared };
}

fn workerCompleted(frame: *const async_manager.protocol.Frame) zle_hooks.Effects {
    if (frame.header.job != .line_analysis) return .{};
    if (frame.header.generation == warm_generation) {
        warm_generation = null;
        _ = startDesired() catch null;
        return .{};
    }
    return installResult(frame);
}

fn installResult(frame: *const async_manager.protocol.Frame) zle_hooks.Effects {
    if (frame.header.message != .response or
        inflight_generation == null or
        frame.header.generation != inflight_generation.? or
        inflight_worker_epoch != highlight_job.epoch()) return .{};
    const snapshot = if (inflight_snapshot) |*value| value else return .{};
    const is_desired = desired_snapshot != null and
        std.mem.eql(u8, desired_snapshot.?.bytes, snapshot.bytes);
    if (frame.header.status != .ok) {
        if (!is_desired) {
            clearInflight();
            _ = startDesired() catch null;
            return .{};
        }
        return discardResult();
    }

    if (!is_desired) {
        clearInflight();
        _ = startDesired() catch null;
        return .{};
    }
    var result = wire.decode(allocator, frame.payload) catch return discardResult();
    defer result.deinit(allocator);
    for (result.spans) |span| {
        if (span.end_byte > snapshot.bytes.len) return discardResult();
    }
    var effects: zle_hooks.Effects = .{};
    if (regions_enabled) {
        regions.apply(snapshot.*, result.spans) catch return discardResult();
        effects.regions_changed = true;
        regions_current = true;
    }

    // Transfer ownership instead of copying the source and every command on
    // the editor thread after they have already been decoded.
    clearCurrentSource();
    current_source = snapshot.bytes;
    snapshot.bytes = &.{};
    const commands_changed = replaceCurrentCommands(&result);
    if (commands_changed) effects.merge(notifyAnalysisCallbacks());
    clearInflight();
    return effects;
}

fn discardResult() zle_hooks.Effects {
    var effects = zle_hooks.Effects{ .regions_changed = clearRegions() };
    // Remember a failed snapshot, so an over-limit or timed-out input does not
    // create a retry/redraw storm. A changed buffer or next prompt can retry.
    if (inflight_snapshot) |*snapshot| {
        current_source = snapshot.bytes;
        snapshot.bytes = &.{};
    }
    clearInflight();
    if (clearCurrentCommands()) effects.merge(notifyAnalysisCallbacks());
    return effects;
}

fn startDesired() !void {
    const desired = desired_snapshot orelse return;
    if (inflight_generation != null or highlight_job.busy()) return;
    inflight_snapshot = try Snapshot.fromUtf8(allocator, desired.bytes);
    errdefer clearInflight();
    generation +%= 1;
    if (generation == 0) generation = 1;
    inflight_generation = generation;
    const deadline = async_manager.deadlineAfter(submission_deadline_ns);
    try highlight_job.submit(generation, desired.bytes, deadline);
    // Submission may lazily restart a worker after a failure callback.
    inflight_worker_epoch = highlight_job.epoch();
}

fn clearDesired() void {
    if (desired_snapshot) |*snapshot| snapshot.deinit(allocator);
    desired_snapshot = null;
}

fn clearInflight() void {
    if (inflight_snapshot) |*snapshot| snapshot.deinit(allocator);
    inflight_snapshot = null;
    inflight_generation = null;
    inflight_worker_epoch = 0;
}

fn clearCurrentSource() void {
    if (current_source) |source| allocator.free(source);
    current_source = null;
}

fn clearRegions() bool {
    const changed = regions_current;
    if (regions_enabled) regions.clear();
    regions_current = false;
    clearCurrentSource();
    return changed;
}

fn replaceCurrentCommands(result: *wire.Result) bool {
    if (commandListsEqual(current_commands, result.commands)) return false;
    _ = clearCurrentCommands();
    current_commands = result.commands;
    result.commands = &.{};
    return true;
}

fn clearCurrentCommands() bool {
    if (current_commands.len == 0) return false;
    for (current_commands) |command| allocator.free(command);
    allocator.free(current_commands);
    current_commands = &.{};
    return true;
}

fn commandListsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_command, right_command| {
        if (!std.mem.eql(u8, left_command, right_command)) return false;
    }
    return true;
}

fn notifyAnalysisCallbacks() zle_hooks.Effects {
    var effects: zle_hooks.Effects = .{};
    for (analysis_callbacks[0..analysis_callback_count]) |callback| effects.merge(callback.?());
    return effects;
}

fn addAnalysisCallback(callback: AnalysisCallback) error{ CallbackAlreadyRegistered, CapacityExceeded }!void {
    if (analysisCallbackIndex(callback) != null) return error.CallbackAlreadyRegistered;
    if (analysis_callback_count == analysis_callbacks.len) return error.CapacityExceeded;
    analysis_callbacks[analysis_callback_count] = callback;
    analysis_callback_count += 1;
}

fn removeAnalysisCallback(callback: AnalysisCallback) void {
    const index = analysisCallbackIndex(callback) orelse return;
    var current = index;
    while (current + 1 < analysis_callback_count) : (current += 1) {
        analysis_callbacks[current] = analysis_callbacks[current + 1];
    }
    analysis_callback_count -= 1;
    analysis_callbacks[analysis_callback_count] = null;
}

fn analysisCallbackIndex(callback: AnalysisCallback) ?usize {
    for (analysis_callbacks[0..analysis_callback_count], 0..) |registered, index| {
        if (registered.? == callback) return index;
    }
    return null;
}
