const std = @import("std");
const semantic = @import("semantic.zig");
const spans = @import("span.zig");
const zle_hooks = @import("../zle_hooks.zig");
const regions = @import("zsh59_regions.zig");
const zsh_state = @import("zsh_state.zig");

const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

pub const Engine = @import("engine.zig").Engine;
pub const Metrics = @import("engine.zig").Metrics;
pub const Result = @import("engine.zig").Result;
pub const Snapshot = @import("snapshot.zig").Snapshot;
pub const Span = @import("span.zig").Span;
pub const Style = @import("style.zig").Style;

var engine: ?Engine = null;
var active = false;
var regions_current = false;

pub fn setup() c_int {
    if (active or highlightingDisabled()) return 0;

    engine = Engine.init(std.heap.c_allocator) catch return 1;
    regions.setup() catch {
        engine.?.deinit();
        engine = null;
        regions.resetTheme();
        return 1;
    };
    zle_hooks.add(linePreRedraw) catch {
        engine.?.deinit();
        engine = null;
        regions.resetTheme();
        return 1;
    };
    active = true;
    regions_current = false;
    return 0;
}

pub fn cleanup() void {
    if (!active) return;
    zle_hooks.remove(linePreRedraw);
    regions.cleanup();
    if (engine) |*active_engine| active_engine.deinit();
    engine = null;
    active = false;
    regions_current = false;
}

fn highlightingDisabled() bool {
    const value = zsh.getsparam(@constCast("ZIGSH_SYNTAX_HIGHLIGHTING")) orelse return false;
    const setting = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
    return std.mem.eql(u8, setting, "0") or
        std.ascii.eqlIgnoreCase(setting, "false") or
        std.ascii.eqlIgnoreCase(setting, "off");
}

fn linePreRedraw() c_int {
    if (zsh.zlecontext == zsh.ZLCON_SELECT or zsh.zlecontext == zsh.ZLCON_VARED) {
        clearRegions();
        return 0;
    }

    const line_length = std.math.cast(usize, zsh.zlell) orelse {
        clearRegions();
        return 0;
    };
    const line: []const zsh.ZLE_CHAR_T = if (line_length == 0)
        &.{}
    else
        zsh.zleline[0..line_length];
    var snapshot = Snapshot.fromCodepoints(std.heap.c_allocator, line) catch {
        clearRegions();
        return 0;
    };
    defer snapshot.deinit(std.heap.c_allocator);

    const active_engine = if (engine) |*value| value else return 0;
    if (regions_current and active_engine.isCurrentSource(snapshot.bytes)) return 0;

    var result = active_engine.highlight(snapshot.bytes) catch {
        clearRegions();
        return 0;
    };
    defer result.deinit(std.heap.c_allocator);

    const state = zsh_state.State{ .allocator = std.heap.c_allocator };
    const semantic_spans = semantic.highlight(
        std.heap.c_allocator,
        snapshot.bytes,
        active_engine.rootNode() catch {
            clearRegions();
            return 0;
        },
        &state,
    ) catch {
        clearRegions();
        return 0;
    };
    defer std.heap.c_allocator.free(semantic_spans);

    const candidates = std.heap.c_allocator.alloc(Span, result.spans.len + semantic_spans.len) catch {
        clearRegions();
        return 0;
    };
    defer std.heap.c_allocator.free(candidates);
    @memcpy(candidates[0..result.spans.len], result.spans);
    @memcpy(candidates[result.spans.len..], semantic_spans);

    const composed = spans.compose(std.heap.c_allocator, @intCast(snapshot.bytes.len), candidates) catch {
        clearRegions();
        return 0;
    };
    std.heap.c_allocator.free(result.spans);
    result.spans = composed;

    regions.apply(snapshot, result.spans) catch {
        clearRegions();
        return 0;
    };
    regions_current = true;
    return 0;
}

fn clearRegions() void {
    regions.clear();
    regions_current = false;
}
