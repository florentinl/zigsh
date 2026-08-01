const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");
const util = @import("util.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    return util.output(allocator, "❯ ", if (current.status == 0) .character else .@"error");
}
