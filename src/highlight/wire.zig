const std = @import("std");
const Span = @import("span.zig").Span;
const Style = @import("style.zig").Style;

const encoded_span_length = 9;

pub const Result = struct {
    spans: []Span,
    commands: [][]u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.spans);
        for (self.commands) |command| allocator.free(command);
        allocator.free(self.commands);
        self.* = undefined;
    }
};

pub fn encode(
    allocator: std.mem.Allocator,
    spans: []const Span,
    commands: []const []const u8,
    max_payload_length: usize,
) ![]u8 {
    if (spans.len > std.math.maxInt(u32) or commands.len > std.math.maxInt(u32)) return error.ResultTooLarge;
    var length: usize = 8;
    length = std.math.add(
        usize,
        length,
        std.math.mul(usize, spans.len, encoded_span_length) catch return error.ResultTooLarge,
    ) catch return error.ResultTooLarge;
    for (commands) |command| {
        if (command.len > std.math.maxInt(u32) or std.mem.indexOfScalar(u8, command, 0) != null) {
            return error.InvalidCommand;
        }
        length = std.math.add(usize, length, 4 + command.len) catch return error.ResultTooLarge;
    }

    // Fail inside the job, so the worker can send a compact failed response
    // instead of dying when the transport rejects an oversized result.
    if (length > max_payload_length) return error.ResultTooLarge;
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
    std.mem.writeInt(u32, output[offset..][0..4], @intCast(commands.len), .little);
    offset += 4;
    for (commands) |command| {
        std.mem.writeInt(u32, output[offset..][0..4], @intCast(command.len), .little);
        offset += 4;
        @memcpy(output[offset..][0..command.len], command);
        offset += command.len;
    }
    return output;
}

pub fn decode(allocator: std.mem.Allocator, payload: []const u8) !Result {
    if (payload.len < 8) return error.InvalidPayload;
    const span_count = std.mem.readInt(u32, payload[0..4], .little);
    const span_bytes = std.math.mul(usize, span_count, encoded_span_length) catch return error.InvalidPayload;
    var offset = std.math.add(usize, 4, span_bytes) catch return error.InvalidPayload;
    if (offset > payload.len or payload.len - offset < 4) return error.InvalidPayload;

    const result_spans = try allocator.alloc(Span, span_count);
    errdefer allocator.free(result_spans);
    var span_offset: usize = 4;
    for (result_spans) |*span| {
        const style = std.enums.fromInt(Style, payload[span_offset + 8]) orelse return error.InvalidPayload;
        const start_byte = std.mem.readInt(u32, payload[span_offset..][0..4], .little);
        const end_byte = std.mem.readInt(u32, payload[span_offset + 4 ..][0..4], .little);
        if (start_byte > end_byte) return error.InvalidPayload;
        span.* = .{ .start_byte = start_byte, .end_byte = end_byte, .style = style };
        span_offset += encoded_span_length;
    }

    const command_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
    offset += 4;
    // Every command needs at least a length field. Validate before allocating
    // from an untrusted count (an eight-byte frame must not request 64 GiB).
    if (command_count > (payload.len - offset) / 4) return error.InvalidPayload;
    const result_commands = try allocator.alloc([]u8, command_count);
    var initialized: usize = 0;
    errdefer {
        for (result_commands[0..initialized]) |command| allocator.free(command);
        allocator.free(result_commands);
    }
    while (initialized < result_commands.len) : (initialized += 1) {
        if (offset > payload.len or payload.len - offset < 4) return error.InvalidPayload;
        const command_length = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;
        if (command_length > payload.len - offset) return error.InvalidPayload;
        const command = payload[offset..][0..command_length];
        if (std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidPayload;
        result_commands[initialized] = try allocator.dupe(u8, command);
        offset += command_length;
    }
    if (offset != payload.len) return error.InvalidPayload;
    return .{ .spans = result_spans, .commands = result_commands };
}

test "line analysis round trips spans and commands" {
    const original = [_]Span{
        .{ .start_byte = 0, .end_byte = 4, .style = .builtin },
        .{ .start_byte = 5, .end_byte = 10, .style = .string },
    };
    const commands = [_][]const u8{ "echo", "python3.12" };
    const payload = try encode(std.testing.allocator, &original, &commands, 1024);
    defer std.testing.allocator.free(payload);
    var decoded = try decode(std.testing.allocator, payload);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Span, &original, decoded.spans);
    try std.testing.expectEqualStrings("echo", decoded.commands[0]);
    try std.testing.expectEqualStrings("python3.12", decoded.commands[1]);
}

test "line analysis rejects malformed ranges and lengths" {
    var payload = try encode(std.testing.allocator, &.{.{
        .start_byte = 2,
        .end_byte = 3,
        .style = .plain,
    }}, &.{"echo"}, 1024);
    defer std.testing.allocator.free(payload);
    std.mem.writeInt(u32, payload[4..8], 4, .little);
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, payload));
    // Restore the range: truncation must exercise command decoding, not fail
    // for the unrelated corrupt span above.
    std.mem.writeInt(u32, payload[4..8], 2, .little);
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, payload[0 .. payload.len - 1]));
}

test "line analysis checks response budget before allocation" {
    var storage: [0]u8 = .{};
    var bounded = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.ResultTooLarge, encode(bounded.allocator(), &.{}, &.{"echo"}, 15));
    const payload = try encode(std.testing.allocator, &.{}, &.{"echo"}, 16);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(@as(usize, 16), payload.len);
}

test "line analysis rejects impossible command counts before allocation" {
    var storage: [0]u8 = .{};
    var bounded = std.heap.FixedBufferAllocator.init(&storage);
    const payload = [_]u8{ 0, 0, 0, 0, 255, 255, 255, 255 };
    try std.testing.expectError(error.InvalidPayload, decode(bounded.allocator(), &payload));
}

test "line analysis rejects corrupt command length NUL and trailing bytes" {
    const payload = try encode(std.testing.allocator, &.{}, &.{"echo"}, 1024);
    defer std.testing.allocator.free(payload);
    std.mem.writeInt(u32, payload[8..12], 5, .little);
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, payload));
    std.mem.writeInt(u32, payload[8..12], 4, .little);
    payload[12] = 0;
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, payload));
    payload[12] = 'e';
    std.mem.writeInt(u32, payload[8..12], 3, .little);
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, payload));
}

test "line analysis decode cleans up partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeWithAllocator, .{});
}

fn decodeWithAllocator(allocator: std.mem.Allocator) !void {
    const payload = try encode(std.testing.allocator, &.{.{ .start_byte = 0, .end_byte = 4, .style = .builtin }}, &.{ "echo", "kubectl" }, 1024);
    defer std.testing.allocator.free(payload);
    var result = try decode(allocator, payload);
    defer result.deinit(allocator);
}
