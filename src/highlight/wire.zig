const std = @import("std");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

const encoded_span_length = 9;

pub fn encode(allocator: std.mem.Allocator, spans: []const Span) ![]u8 {
    if (spans.len > std.math.maxInt(u32)) return error.TooManySpans;
    const length = std.math.add(
        usize,
        @sizeOf(u32),
        std.math.mul(usize, spans.len, encoded_span_length) catch return error.TooManySpans,
    ) catch return error.TooManySpans;
    const output = try allocator.alloc(u8, length);
    errdefer allocator.free(output);
    std.mem.writeInt(u32, output[0..4], @intCast(spans.len), .little);
    var offset: usize = 4;
    for (spans) |span| {
        std.mem.writeInt(u32, output[offset..][0..4], span.start_byte, .little);
        std.mem.writeInt(u32, output[offset + 4 ..][0..4], span.end_byte, .little);
        output[offset + 8] = @intFromEnum(span.style);
        offset += encoded_span_length;
    }
    return output;
}

pub fn decode(allocator: std.mem.Allocator, payload: []const u8) ![]Span {
    if (payload.len < 4) return error.InvalidPayload;
    const count = std.mem.readInt(u32, payload[0..4], .little);
    const expected = std.math.add(
        usize,
        4,
        std.math.mul(usize, count, encoded_span_length) catch return error.InvalidPayload,
    ) catch return error.InvalidPayload;
    if (payload.len != expected) return error.InvalidPayload;

    const result = try allocator.alloc(Span, count);
    errdefer allocator.free(result);
    var offset: usize = 4;
    for (result) |*span| {
        const style = std.enums.fromInt(Style, payload[offset + 8]) orelse return error.InvalidPayload;
        const start_byte = std.mem.readInt(u32, payload[offset..][0..4], .little);
        const end_byte = std.mem.readInt(u32, payload[offset + 4 ..][0..4], .little);
        if (start_byte > end_byte) return error.InvalidPayload;
        span.* = .{ .start_byte = start_byte, .end_byte = end_byte, .style = style };
        offset += encoded_span_length;
    }
    return result;
}

test "highlight spans round trip through the worker protocol" {
    const original = [_]Span{
        .{ .start_byte = 0, .end_byte = 4, .style = .builtin },
        .{ .start_byte = 5, .end_byte = 10, .style = .string },
    };
    const payload = try encode(std.testing.allocator, &original);
    defer std.testing.allocator.free(payload);
    const decoded = try decode(std.testing.allocator, payload);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(Span, &original, decoded);
}

test "highlight spans reject malformed ranges and lengths" {
    var payload = try encode(std.testing.allocator, &.{.{
        .start_byte = 2,
        .end_byte = 3,
        .style = .plain,
    }});
    defer std.testing.allocator.free(payload);
    std.mem.writeInt(u32, payload[4..8], 4, .little);
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, payload));
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, payload[0 .. payload.len - 1]));
}
