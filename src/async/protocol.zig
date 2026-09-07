const std = @import("std");

pub const magic: u32 = 0x4853_475a;
pub const version: u8 = 1;
pub const header_length = 20;
pub const max_payload_length = 1024 * 1024;
// Maximum unacknowledged request bytes, including the header. Credits are
// zero-payload headers whose generation contains the number of bytes consumed.
pub const request_credit = 4096;

pub const Message = enum(u8) {
    request = 1,
    response = 2,
    credit = 3,
};

pub const Job = enum(u8) {
    ping = 1,
    prompt_git = 2,
    line_analysis = 3,
    prompt_kubernetes = 4,
};

pub const Status = enum(u8) {
    ok = 0,
    cancelled = 1,
    failed = 2,
};

pub const Header = struct {
    message: Message,
    job: Job,
    status: Status,
    generation: u64,
    payload_length: u32,

    pub fn encode(self: Header) [header_length]u8 {
        var bytes: [header_length]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0..4], magic, .little);
        bytes[4] = version;
        bytes[5] = @intFromEnum(self.message);
        bytes[6] = @intFromEnum(self.job);
        bytes[7] = @intFromEnum(self.status);
        std.mem.writeInt(u64, bytes[8..16], self.generation, .little);
        std.mem.writeInt(u32, bytes[16..20], self.payload_length, .little);
        return bytes;
    }

    pub fn decode(bytes: *const [header_length]u8) error{ InvalidFrame, UnsupportedVersion, PayloadTooLarge }!Header {
        if (std.mem.readInt(u32, bytes[0..4], .little) != magic) return error.InvalidFrame;
        if (bytes[4] != version) return error.UnsupportedVersion;
        const message = std.enums.fromInt(Message, bytes[5]) orelse return error.InvalidFrame;
        const job = std.enums.fromInt(Job, bytes[6]) orelse return error.InvalidFrame;
        const status = std.enums.fromInt(Status, bytes[7]) orelse return error.InvalidFrame;
        const payload_length = std.mem.readInt(u32, bytes[16..20], .little);
        if (payload_length > max_payload_length) return error.PayloadTooLarge;
        return .{
            .message = message,
            .job = job,
            .status = status,
            .generation = std.mem.readInt(u64, bytes[8..16], .little),
            .payload_length = payload_length,
        };
    }
};

pub const Frame = struct {
    header: Header,
    payload: []u8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

test "frame headers have a stable endian-independent encoding" {
    const expected = Header{
        .message = .request,
        .job = .line_analysis,
        .status = .ok,
        .generation = 0x0102_0304_0506_0708,
        .payload_length = 42,
    };
    const encoded = expected.encode();
    const actual = try Header.decode(&encoded);

    try std.testing.expectEqual(expected.message, actual.message);
    try std.testing.expectEqual(expected.job, actual.job);
    try std.testing.expectEqual(expected.status, actual.status);
    try std.testing.expectEqual(expected.generation, actual.generation);
    try std.testing.expectEqual(expected.payload_length, actual.payload_length);
    try std.testing.expectEqualSlices(u8, &.{ 0x5a, 0x47, 0x53, 0x48 }, encoded[0..4]);
}

test "frame headers reject oversized payloads" {
    var encoded = (Header{
        .message = .request,
        .job = .ping,
        .status = .ok,
        .generation = 1,
        .payload_length = 0,
    }).encode();
    std.mem.writeInt(u32, encoded[16..20], max_payload_length + 1, .little);
    try std.testing.expectError(error.PayloadTooLarge, Header.decode(&encoded));
}

test "credit headers carry consumed request bytes without a payload" {
    const encoded = (Header{
        .message = .credit,
        .job = .ping,
        .status = .ok,
        .generation = request_credit,
        .payload_length = 0,
    }).encode();
    const decoded = try Header.decode(&encoded);
    try std.testing.expectEqual(Message.credit, decoded.message);
    try std.testing.expectEqual(@as(u64, request_credit), decoded.generation);
    try std.testing.expectEqual(@as(u32, 0), decoded.payload_length);
}
