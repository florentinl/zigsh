const std = @import("std");
const Snapshot = @import("snapshot.zig").Snapshot;
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

const zsh = @cImport({
    @cInclude("Zle/zle.mdh");
});

const special_region_count: usize = zsh.N_SPECIAL_HIGHLIGHTS;
const style_count = @typeInfo(Style).@"enum".fields.len;

const style_specs: [style_count][:0]const u8 = .{
    "fg=yellow",
    "fg=magenta",
    "fg=blue",
    "fg=magenta",
    "fg=yellow,bold",
    "fg=green",
    "fg=cyan",
    "fg=black,bold",
    "fg=red,bold",
};

var attributes: [style_count]zsh.zattr = @splat(0);
var theme_ready = false;

pub fn setup() error{ UnsupportedZshVersion, InvalidStyle }!void {
    try requireZsh59();

    for (style_specs, 0..) |spec, index| {
        const remaining = zsh.match_highlight(spec.ptr, &attributes[index]);
        if (remaining[0] != 0) return error.InvalidStyle;
    }
    theme_ready = true;
}

pub fn cleanup() void {
    clear();
    resetTheme();
}

pub fn resetTheme() void {
    attributes = @splat(0);
    theme_ready = false;
}

pub fn apply(snapshot: Snapshot, spans: []const Span) error{ InvalidRegionState, InvalidByteOffset }!void {
    if (!theme_ready) return error.InvalidRegionState;
    for (spans) |span| {
        _ = try snapshot.zleOffset(span.start_byte);
        _ = try snapshot.zleOffset(span.end_byte);
    }
    try resize(spans.len);

    for (spans, 0..) |span, index| {
        const start = try snapshot.zleOffset(span.start_byte);
        const end = try snapshot.zleOffset(span.end_byte);
        zsh.region_highlights[special_region_count + index] = .{
            .atr = attributes[@intFromEnum(span.style)],
            .start = @intCast(start),
            .start_meta = @intCast(start),
            .end = @intCast(end),
            .end_meta = @intCast(end),
            .flags = 0,
            .memo = null,
        };
    }
}

pub fn clear() void {
    if (zsh.region_highlights == null) return;
    resize(0) catch {};
}

fn resize(region_count: usize) error{InvalidRegionState}!void {
    if (zsh.region_highlights == null) {
        if (zsh.n_region_highlights != 0) return error.InvalidRegionState;
        zsh.region_highlights = @ptrCast(@alignCast(zsh.zshcalloc(
            special_region_count * @sizeOf(zsh.struct_region_highlight),
        )));
        zsh.n_region_highlights = @intCast(special_region_count);
    }
    if (zsh.n_region_highlights < special_region_count) return error.InvalidRegionState;

    freeTailMemos();

    const total_count = special_region_count + region_count;
    if (total_count != @as(usize, @intCast(zsh.n_region_highlights))) {
        zsh.region_highlights = @ptrCast(@alignCast(zsh.zrealloc(
            zsh.region_highlights,
            total_count * @sizeOf(zsh.struct_region_highlight),
        )));
        zsh.n_region_highlights = @intCast(total_count);
    }
}

fn freeTailMemos() void {
    const count: usize = @intCast(zsh.n_region_highlights);
    for (zsh.region_highlights[special_region_count..count]) |region| {
        if (region.memo) |memo| zsh.zfree(@constCast(memo), 0);
    }
}

fn requireZsh59() error{UnsupportedZshVersion}!void {
    const version = zsh.getsparam(@constCast("ZSH_VERSION")) orelse
        return error.UnsupportedZshVersion;
    const version_string = std.mem.span(@as([*:0]const u8, @ptrCast(version)));
    if (!std.mem.eql(u8, version_string, "5.9")) return error.UnsupportedZshVersion;
}

comptime {
    if (@offsetOf(zsh.struct_region_highlight, "atr") != 0 or
        @offsetOf(zsh.struct_region_highlight, "start") != 8 or
        @offsetOf(zsh.struct_region_highlight, "start_meta") != 12 or
        @offsetOf(zsh.struct_region_highlight, "end") != 16 or
        @offsetOf(zsh.struct_region_highlight, "end_meta") != 20 or
        @offsetOf(zsh.struct_region_highlight, "flags") != 24 or
        @offsetOf(zsh.struct_region_highlight, "memo") != 32 or
        @sizeOf(zsh.struct_region_highlight) != 40)
    {
        @compileError("unsupported Zsh 5.9 region_highlight layout");
    }
}
