const std = @import("std");
const Style = @import("style.zig").Style;

pub const Span = struct {
    start_byte: u32,
    end_byte: u32,
    style: Style,
};

const Event = struct {
    offset: u32,
    style: Style,
    delta: i8,

    fn lessThan(_: void, left: Event, right: Event) bool {
        return left.offset < right.offset;
    }
};

pub fn compose(
    allocator: std.mem.Allocator,
    source_length: u32,
    input: []const Span,
) ![]Span {
    var events = try std.ArrayList(Event).initCapacity(allocator, input.len * 2);
    defer events.deinit(allocator);

    for (input) |span| {
        const start = @min(span.start_byte, source_length);
        const end = @min(span.end_byte, source_length);
        if (start >= end) continue;

        events.appendAssumeCapacity(.{ .offset = start, .style = span.style, .delta = 1 });
        events.appendAssumeCapacity(.{ .offset = end, .style = span.style, .delta = -1 });
    }

    if (events.items.len == 0) return allocator.alloc(Span, 0);
    std.mem.sort(Event, events.items, {}, Event.lessThan);

    var result = std.ArrayList(Span).empty;
    errdefer result.deinit(allocator);

    var active: [style_count]u32 = @splat(0);
    var previous_offset = events.items[0].offset;
    var event_index: usize = 0;

    while (event_index < events.items.len) {
        const offset = events.items[event_index].offset;
        if (previous_offset < offset) {
            if (highestPriorityStyle(active)) |style| {
                try appendOrExtend(&result, allocator, .{
                    .start_byte = previous_offset,
                    .end_byte = offset,
                    .style = style,
                });
            }
        }

        while (event_index < events.items.len and events.items[event_index].offset == offset) : (event_index += 1) {
            const event = events.items[event_index];
            const style_index = @intFromEnum(event.style);
            if (event.delta > 0) {
                active[style_index] += 1;
            } else {
                std.debug.assert(active[style_index] > 0);
                active[style_index] -= 1;
            }
        }
        previous_offset = offset;
    }

    return result.toOwnedSlice(allocator);
}

const style_count = @typeInfo(Style).@"enum".fields.len;

fn highestPriorityStyle(active: [style_count]u32) ?Style {
    var selected: ?Style = null;
    for (active, 0..) |count, index| {
        if (count == 0) continue;
        const candidate: Style = @enumFromInt(index);
        if (selected == null or candidate.priority() > selected.?.priority()) {
            selected = candidate;
        }
    }
    return selected;
}

fn appendOrExtend(
    result: *std.ArrayList(Span),
    allocator: std.mem.Allocator,
    span: Span,
) !void {
    if (result.items.len > 0) {
        const previous = &result.items[result.items.len - 1];
        if (previous.end_byte == span.start_byte and previous.style == span.style) {
            previous.end_byte = span.end_byte;
            return;
        }
    }
    try result.append(allocator, span);
}

test "higher priority spans replace lower priority intervals" {
    const input = [_]Span{
        .{ .start_byte = 0, .end_byte = 10, .style = .string },
        .{ .start_byte = 2, .end_byte = 5, .style = .variable },
    };
    const actual = try compose(std.testing.allocator, 10, &input);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 0, .end_byte = 2, .style = .string },
        .{ .start_byte = 2, .end_byte = 5, .style = .variable },
        .{ .start_byte = 5, .end_byte = 10, .style = .string },
    }, actual);
}

test "composition clips, drops, and merges spans" {
    const input = [_]Span{
        .{ .start_byte = 0, .end_byte = 2, .style = .keyword },
        .{ .start_byte = 2, .end_byte = 4, .style = .keyword },
        .{ .start_byte = 8, .end_byte = 20, .style = .comment },
        .{ .start_byte = 9, .end_byte = 9, .style = .parse_error },
    };
    const actual = try compose(std.testing.allocator, 10, &input);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualSlices(Span, &.{
        .{ .start_byte = 0, .end_byte = 4, .style = .keyword },
        .{ .start_byte = 8, .end_byte = 10, .style = .comment },
    }, actual);
}
