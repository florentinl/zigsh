const std = @import("std");
const git = @import("git.zig");

pub const Result = struct {
    info: ?git.Info,
    duration_ns: u64,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.info) |*info| info.deinit(allocator);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendInt(&output, allocator, u64, result.duration_ns);
    try output.append(allocator, if (result.info != null) 1 else 0);
    if (result.info) |info| {
        try appendString(&output, allocator, info.root);
        try appendString(&output, allocator, info.dir);
        try appendOptionalString(&output, allocator, info.branch);
        try appendOptionalString(&output, allocator, info.commit);
        try appendOptionalString(&output, allocator, info.tag);
        try appendOptionalString(&output, allocator, info.operation);
        try output.append(allocator, @intFromEnum(info.provider));
        inline for (@typeInfo(git.Counts).@"struct".fields) |field| {
            try appendInt(&output, allocator, u64, @intCast(@field(info.counts, field.name)));
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Result {
    var reader = Reader{ .bytes = bytes };
    const duration_ns = try reader.readInt(u64);
    const has_info = try reader.readByte();
    if (has_info > 1) return error.InvalidPayload;
    if (has_info == 0) {
        try reader.expectEnd();
        return .{ .info = null, .duration_ns = duration_ns };
    }

    var info = git.Info{
        .root = try reader.readString(allocator),
        .dir = undefined,
    };
    errdefer info.deinit(allocator);
    info.dir = try reader.readString(allocator);
    info.branch = try reader.readOptionalString(allocator);
    info.commit = try reader.readOptionalString(allocator);
    info.tag = try reader.readOptionalString(allocator);
    info.operation = try reader.readOptionalString(allocator);
    info.provider = std.enums.fromInt(git.Provider, try reader.readByte()) orelse return error.InvalidPayload;
    inline for (@typeInfo(git.Counts).@"struct".fields) |field| {
        @field(info.counts, field.name) = std.math.cast(usize, try reader.readInt(u64)) orelse
            return error.InvalidPayload;
    }
    try reader.expectEnd();
    return .{ .info = info, .duration_ns = duration_ns };
}

fn appendString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (value.len > std.math.maxInt(u32)) return error.ValueTooLong;
    try appendInt(output, allocator, u32, @intCast(value.len));
    try output.appendSlice(allocator, value);
}

fn appendOptionalString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: ?[]const u8) !void {
    try output.append(allocator, if (value != null) 1 else 0);
    if (value) |present| try appendString(output, allocator, present);
}

fn appendInt(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime Int: type,
    value: Int,
) !void {
    var bytes: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn readByte(self: *Reader) !u8 {
        if (self.offset == self.bytes.len) return error.InvalidPayload;
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    fn readInt(self: *Reader, comptime Int: type) !Int {
        const end = std.math.add(usize, self.offset, @sizeOf(Int)) catch return error.InvalidPayload;
        if (end > self.bytes.len) return error.InvalidPayload;
        defer self.offset = end;
        return std.mem.readInt(Int, self.bytes[self.offset..end][0..@sizeOf(Int)], .little);
    }

    fn readString(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        const length = try self.readInt(u32);
        const end = std.math.add(usize, self.offset, length) catch return error.InvalidPayload;
        if (end > self.bytes.len) return error.InvalidPayload;
        defer self.offset = end;
        return allocator.dupe(u8, self.bytes[self.offset..end]);
    }

    fn readOptionalString(self: *Reader, allocator: std.mem.Allocator) !?[]u8 {
        return switch (try self.readByte()) {
            0 => null,
            1 => try self.readString(allocator),
            else => error.InvalidPayload,
        };
    }

    fn expectEnd(self: Reader) !void {
        if (self.offset != self.bytes.len) return error.InvalidPayload;
    }
};

test "git results round trip through the worker protocol" {
    const allocator = std.testing.allocator;
    var original = Result{
        .info = .{
            .root = try allocator.dupe(u8, "/repo"),
            .dir = try allocator.dupe(u8, "/repo/.git"),
            .branch = try allocator.dupe(u8, "feature/async"),
            .provider = .github,
            .counts = .{ .modified = 2, .untracked = 1 },
        },
        .duration_ns = 17,
    };
    defer original.deinit(allocator);

    const encoded = try encode(allocator, &original);
    defer allocator.free(encoded);
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 17), decoded.duration_ns);
    try std.testing.expectEqualStrings("/repo", decoded.info.?.root);
    try std.testing.expectEqualStrings("feature/async", decoded.info.?.branch.?);
    try std.testing.expectEqual(git.Provider.github, decoded.info.?.provider);
    try std.testing.expectEqual(@as(usize, 2), decoded.info.?.counts.modified);
    try std.testing.expectEqual(@as(usize, 1), decoded.info.?.counts.untracked);
}

test "git result decoding rejects truncation" {
    try std.testing.expectError(error.InvalidPayload, decode(std.testing.allocator, &.{ 0, 1 }));
}
