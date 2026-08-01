const std = @import("std");
const segment = @import("segment.zig");

const allocator = std.heap.c_allocator;
const segment_count = @typeInfo(segment.Name).@"enum".fields.len;
pub const max_lines = segment_count;

pub const Trigger = enum { preprompt, async_completion, resize };

pub const Phases = struct {
    context_ns: u64 = 0,
    sync_wait_ns: u64 = 0,
    cache_ns: u64 = 0,
    segments_ns: u64 = 0,
    layout_ns: u64 = 0,
    assignment_ns: u64 = 0,
    render_total_ns: u64 = 0,
    initial_total_ns: u64 = 0,
    git_worker_ns: u64 = 0,
    settled_after_ns: u64 = 0,
};

pub const Entry = struct {
    duration_ns: u64 = 0,
    text: ?[]u8 = null,

    pub fn deinit(self: *Entry) void {
        if (self.text) |text| allocator.free(text);
        self.* = .{};
    }
};

pub const Snapshot = struct {
    segments: [segment_count]Entry = [_]Entry{.{}} ** segment_count,
    phases: Phases = .{},
    trigger: Trigger = .preprompt,
    prompt_changed: bool = false,

    pub fn deinit(self: *Snapshot) void {
        for (&self.segments) |*entry| entry.deinit();
        self.* = .{};
    }

    pub fn recordSegment(self: *Snapshot, name: segment.Name, duration_ns: u64, text: ?[]const u8) !void {
        const entry = &self.segments[@intFromEnum(name)];
        entry.duration_ns = duration_ns;
        if (text) |value| entry.text = try printableCopy(value);
    }
};

pub const Line = struct {
    name: []const u8,
    duration_ns: u64,
    text: ?[]const u8 = null,
};

var latest_snapshot: Snapshot = .{};
var has_snapshot = false;

pub fn replace(next: *Snapshot) void {
    latest_snapshot.deinit();
    latest_snapshot = next.*;
    next.* = .{};
    has_snapshot = true;
}

pub fn clear() void {
    latest_snapshot.deinit();
    has_snapshot = false;
}

pub fn latest() ?*const Snapshot {
    return if (has_snapshot) &latest_snapshot else null;
}

pub fn collect(snapshot: *const Snapshot, output: []Line) []Line {
    var count: usize = 0;
    inline for (@typeInfo(segment.Name).@"enum".fields) |field| {
        const name: segment.Name = @enumFromInt(field.value);
        const entry = snapshot.segments[@intFromEnum(name)];
        appendIfRelevant(output, &count, .{
            .name = field.name,
            .duration_ns = entry.duration_ns,
            .text = entry.text,
        });
    }
    sortByDuration(output[0..count]);
    return output[0..count];
}

fn appendIfRelevant(output: []Line, count: *usize, line: Line) void {
    if (line.duration_ns < std.time.ns_per_ms and line.text == null) return;
    appendLine(output, count, line);
}

fn appendLine(output: []Line, count: *usize, line: Line) void {
    output[count.*] = line;
    count.* += 1;
}

fn sortByDuration(lines: []Line) void {
    for (1..lines.len) |index| {
        const value = lines[index];
        var cursor = index;
        while (cursor > 0 and lines[cursor - 1].duration_ns < value.duration_ns) : (cursor -= 1) {
            lines[cursor] = lines[cursor - 1];
        }
        lines[cursor] = value;
    }
}

fn printableCopy(text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (text) |byte| {
        switch (byte) {
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '"' => try output.appendSlice(allocator, "\\\""),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...0x1f, 0x7f => try output.append(allocator, '?'),
            else => try output.append(allocator, byte),
        }
    }
    return output.toOwnedSlice(allocator);
}

test "collect filters empty fast modules and sorts the rest by duration" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit();
    snapshot.segments[@intFromEnum(segment.Name.git_status)].duration_ns = 12 * std.time.ns_per_ms;
    snapshot.segments[@intFromEnum(segment.Name.directory)].duration_ns = 2 * std.time.ns_per_ms;
    snapshot.segments[@intFromEnum(segment.Name.os)].duration_ns = std.time.ns_per_ms - 1;
    snapshot.segments[@intFromEnum(segment.Name.character)].text = try allocator.dupe(u8, " ");

    var storage: [segment_count]Line = undefined;
    const lines = collect(&snapshot, &storage);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("git_status", lines[0].name);
    try std.testing.expectEqualStrings("directory", lines[1].name);
    try std.testing.expectEqualStrings("character", lines[2].name);
}

test "recordSegment escapes quoted output" {
    var snapshot: Snapshot = .{};
    defer snapshot.deinit();

    try snapshot.recordSegment(.directory, 0, "a\\b\n\"c\"");

    try std.testing.expectEqualStrings(
        "a\\\\b\\n\\\"c\\\"",
        snapshot.segments[@intFromEnum(segment.Name.directory)].text.?,
    );
}

test "snapshots retain prompt phase diagnostics" {
    var snapshot: Snapshot = .{
        .phases = .{
            .context_ns = 2 * std.time.ns_per_ms,
            .render_total_ns = 3 * std.time.ns_per_ms,
            .git_worker_ns = 2 * std.time.ns_per_s,
        },
        .trigger = .async_completion,
        .prompt_changed = true,
    };
    defer snapshot.deinit();

    try std.testing.expectEqual(Trigger.async_completion, snapshot.trigger);
    try std.testing.expect(snapshot.prompt_changed);
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), snapshot.phases.git_worker_ns);
}
