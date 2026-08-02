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
var regions_current = false;
var current_source: ?[]u8 = null;
var desired_snapshot: ?Snapshot = null;
var inflight_snapshot: ?Snapshot = null;
var inflight_generation: ?u64 = null;
var inflight_worker_epoch: u64 = 0;
var warm_generation: ?u64 = null;
var generation: u64 = 0;
var preprompt_registered = false;
var redraw_subscription = zle_hooks.Subscription.init(linePreRedraw);
var highlight_job = async_manager.Job.init(.highlight, workerCompleted);

const foreground_budget_ns = 3 * std.time.ns_per_ms;
const warm_budget_ns = 3 * std.time.ns_per_ms;
const allocator = std.heap.c_allocator;

pub fn setup() c_int {
    if (active or highlightingDisabled()) return 0;

    regions.setup() catch {
        regions.resetTheme();
        return 1;
    };
    redraw_subscription.register() catch {
        regions.resetTheme();
        return 1;
    };
    highlight_job.register() catch {
        redraw_subscription.unregister();
        regions.resetTheme();
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
    regions.cleanup();
    clearDesired();
    clearInflight();
    clearCurrentSource();
    active = false;
    regions_current = false;
    warm_generation = null;
}

fn refreshWorker() callconv(.c) void {
    clearDesired();
    clearInflight();
    clearCurrentSource();
    regions_current = false;
    warm_generation = null;
    if (!highlight_job.cancelAndRestart()) return;

    generation +%= 1;
    if (generation == 0) generation = 1;
    warm_generation = generation;
    const deadline = async_manager.deadlineAfter(warm_budget_ns);
    var frame = highlight_job.submitAndWait(generation, &.{}, deadline) catch {
        warm_generation = null;
        return;
    } orelse return;
    defer frame.deinit(allocator);
    warm_generation = null;
}

fn highlightingDisabled() bool {
    const value = zsh.getsparam(@constCast("ZIGSH_SYNTAX_HIGHLIGHTING")) orelse return false;
    const setting = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    return std.mem.eql(u8, setting, "0") or
        std.ascii.eqlIgnoreCase(setting, "false") or
        std.ascii.eqlIgnoreCase(setting, "off");
}

fn linePreRedraw() zle_hooks.Effects {
    if (zsh.zlecontext == zsh.ZLCON_SELECT or zsh.zlecontext == zsh.ZLCON_VARED) {
        clearDesired();
        clearInflight();
        return .{ .regions_changed = clearRegions() };
    }

    const line_length = std.math.cast(usize, zsh.zlell) orelse {
        clearDesired();
        clearInflight();
        return .{ .regions_changed = clearRegions() };
    };
    const line: []const zsh.ZLE_CHAR_T = if (line_length == 0)
        &.{}
    else
        zsh.zleline[0..line_length];
    var snapshot = Snapshot.fromCodepoints(allocator, line) catch {
        clearDesired();
        clearInflight();
        return .{ .regions_changed = clearRegions() };
    };
    if (desired_snapshot != null and std.mem.eql(u8, desired_snapshot.?.bytes, snapshot.bytes)) {
        snapshot.deinit(allocator);
        return .{};
    }

    clearDesired();
    desired_snapshot = snapshot;
    const matches_current = regions_current and current_source != null and
        std.mem.eql(u8, current_source.?, desired_snapshot.?.bytes);
    const cleared = if (matches_current) false else clearRegions();

    if (inflight_generation != null and inflight_worker_epoch != highlight_job.epoch()) {
        clearInflight();
    }
    if (inflight_generation != null) return .{ .regions_changed = cleared };
    if (matches_current) return .{ .regions_changed = cleared };

    var frame = (startDesired(true) catch return .{ .regions_changed = cleared }) orelse
        return .{ .regions_changed = cleared };
    defer frame.deinit(allocator);
    const applied = installResult(&frame);
    return .{ .regions_changed = cleared or applied };
}

fn workerCompleted(frame: *const async_manager.protocol.Frame) zle_hooks.Effects {
    if (frame.header.job != .highlight) return .{};
    if (frame.header.generation == warm_generation) {
        warm_generation = null;
        _ = startDesired(false) catch null;
        return .{};
    }
    return .{ .regions_changed = installResult(frame) };
}

fn installResult(frame: *const async_manager.protocol.Frame) bool {
    if (frame.header.message != .response or
        inflight_generation == null or
        frame.header.generation != inflight_generation.? or
        inflight_worker_epoch != highlight_job.epoch()) return false;
    if (frame.header.status != .ok) {
        std.log.err("highlight worker failed: {s}", .{frame.payload});
        clearInflight();
        return false;
    }

    const snapshot = if (inflight_snapshot) |*value| value else return false;
    const is_desired = desired_snapshot != null and
        std.mem.eql(u8, desired_snapshot.?.bytes, snapshot.bytes);
    if (!is_desired) {
        clearInflight();
        _ = startDesired(false) catch null;
        return false;
    }
    const result = wire.decode(allocator, frame.payload) catch {
        clearInflight();
        return false;
    };
    defer allocator.free(result);
    for (result) |span| {
        if (span.end_byte > snapshot.bytes.len) {
            clearInflight();
            return false;
        }
    }
    regions.apply(snapshot.*, result) catch {
        clearInflight();
        _ = clearRegions();
        return false;
    };

    const source = allocator.dupe(u8, snapshot.bytes) catch {
        clearInflight();
        _ = clearRegions();
        return false;
    };
    clearCurrentSource();
    current_source = source;
    regions_current = true;
    clearInflight();
    return true;
}

fn startDesired(wait: bool) !?async_manager.protocol.Frame {
    const desired = desired_snapshot orelse return null;
    if (inflight_generation != null) return null;
    inflight_snapshot = try Snapshot.fromUtf8(allocator, desired.bytes);
    errdefer clearInflight();
    generation +%= 1;
    if (generation == 0) generation = 1;
    inflight_generation = generation;
    inflight_worker_epoch = highlight_job.epoch();
    const deadline = async_manager.deadlineAfter(if (wait) foreground_budget_ns else std.time.ns_per_ms);
    if (wait) return try highlight_job.submitAndWait(generation, desired.bytes, deadline);
    try highlight_job.submit(generation, desired.bytes, deadline);
    return null;
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
    regions.clear();
    regions_current = false;
    clearCurrentSource();
    return changed;
}
