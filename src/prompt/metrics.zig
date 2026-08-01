const std = @import("std");
const segment = @import("segment.zig");

const allocator = std.heap.c_allocator;
const segment_count = @typeInfo(segment.Name).@"enum".fields.len;

pub const Entry = struct {
    duration_ns: u64 = 0,
    text: ?[]u8 = null,

    pub fn deinit(self: *Entry) void {
        if (self.text) |text| allocator.free(text);
        self.* = .{};
    }
};

pub const Snapshot = struct {
    total_ns: u64 = 0,
    context_ns: u64 = 0,
    git_ns: u64 = 0,
    layout_ns: u64 = 0,
    segments: [segment_count]Entry = [_]Entry{.{}} ** segment_count,

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

pub fn latest() ?*const Snapshot {
    return if (has_snapshot) &latest_snapshot else null;
}

pub fn collect(snapshot: *const Snapshot, output: []Line) []Line {
    var count: usize = 0;
    appendLine(output, &count, .{ .name = "prompt", .duration_ns = snapshot.total_ns });
    appendIfRelevant(output, &count, .{ .name = "context", .duration_ns = snapshot.context_ns });
    appendIfRelevant(output, &count, .{ .name = "git", .duration_ns = snapshot.git_ns });
    appendIfRelevant(output, &count, .{ .name = "layout", .duration_ns = snapshot.layout_ns });
    inline for (@typeInfo(segment.Name).@"enum".fields) |field| {
        const name: segment.Name = @enumFromInt(field.value);
        const entry = snapshot.segments[@intFromEnum(name)];
        appendIfRelevant(output, &count, .{
            .name = field.name,
            .duration_ns = entry.duration_ns,
            .text = entry.text,
        });
    }
    sortByDuration(output[1..count]);
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
        if (byte < 0x20 or byte == 0x7f) {
            try output.append(allocator, '?');
        } else {
            try output.append(allocator, byte);
        }
    }
    return output.toOwnedSlice(allocator);
}
