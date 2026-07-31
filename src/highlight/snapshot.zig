const std = @import("std");

pub const Snapshot = struct {
    bytes: []u8,
    character_start_bytes: []u32,

    pub fn fromCodepoints(allocator: std.mem.Allocator, codepoints: anytype) !Snapshot {
        var bytes = try std.ArrayList(u8).initCapacity(allocator, codepoints.len);
        errdefer bytes.deinit(allocator);
        var starts = try std.ArrayList(u32).initCapacity(allocator, codepoints.len + 1);
        errdefer starts.deinit(allocator);

        starts.appendAssumeCapacity(0);
        for (codepoints) |wide_codepoint| {
            var encoded: [4]u8 = undefined;
            const codepoint = validCodepoint(wide_codepoint);
            const encoded_length = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
            try bytes.appendSlice(allocator, encoded[0..encoded_length]);
            starts.appendAssumeCapacity(@intCast(bytes.items.len));
        }

        const owned_bytes = try bytes.toOwnedSlice(allocator);
        errdefer allocator.free(owned_bytes);
        const owned_starts = try starts.toOwnedSlice(allocator);
        return .{ .bytes = owned_bytes, .character_start_bytes = owned_starts };
    }

    pub fn fromUtf8(allocator: std.mem.Allocator, source: []const u8) !Snapshot {
        const view = try std.unicode.Utf8View.init(source);
        var starts = std.ArrayList(u32).empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);

        var iterator = view.iterator();
        while (iterator.nextCodepointSlice()) |codepoint| {
            try starts.append(allocator, starts.items[starts.items.len - 1] + @as(u32, @intCast(codepoint.len)));
        }

        const bytes = try allocator.dupe(u8, source);
        errdefer allocator.free(bytes);
        const character_start_bytes = try starts.toOwnedSlice(allocator);
        return .{ .bytes = bytes, .character_start_bytes = character_start_bytes };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.character_start_bytes);
        self.* = undefined;
    }

    pub fn zleOffset(self: Snapshot, byte_offset: u32) error{InvalidByteOffset}!u32 {
        var lower: usize = 0;
        var upper = self.character_start_bytes.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            const candidate = self.character_start_bytes[middle];
            if (candidate < byte_offset) {
                lower = middle + 1;
            } else {
                upper = middle;
            }
        }

        if (lower == self.character_start_bytes.len or
            self.character_start_bytes[lower] != byte_offset)
        {
            return error.InvalidByteOffset;
        }
        return @intCast(lower);
    }
};

fn validCodepoint(wide_codepoint: anytype) u21 {
    const value = std.math.cast(u32, wide_codepoint) orelse return 0xfffd;
    if (value > 0x10ffff or value >= 0xd800 and value <= 0xdfff) return 0xfffd;
    return @intCast(value);
}

test "snapshot encodes wide characters and maps byte boundaries" {
    const codepoints = [_]u32{ 'a', 0x00e9, 0x1f642 };
    var snapshot = try Snapshot.fromCodepoints(std.testing.allocator, &codepoints);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("aé🙂", snapshot.bytes);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3, 7 }, snapshot.character_start_bytes);
    try std.testing.expectEqual(@as(u32, 2), try snapshot.zleOffset(3));
    try std.testing.expectError(error.InvalidByteOffset, snapshot.zleOffset(2));
}

test "invalid wide characters become replacement characters" {
    const codepoints = [_]u32{0x110000};
    var snapshot = try Snapshot.fromCodepoints(std.testing.allocator, &codepoints);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("�", snapshot.bytes);
}

test "snapshot construction releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        createTestSnapshots,
        .{},
    );
}

fn createTestSnapshots(allocator: std.mem.Allocator) !void {
    const codepoints = [_]u32{ 'a', 0x00e9, 0x1f642 };
    var wide_snapshot = try Snapshot.fromCodepoints(allocator, &codepoints);
    defer wide_snapshot.deinit(allocator);

    var utf8_snapshot = try Snapshot.fromUtf8(allocator, "aé🙂");
    defer utf8_snapshot.deinit(allocator);
}
