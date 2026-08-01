const std = @import("std");
const context = @import("../context.zig");
const segment = @import("../segment.zig");
const util = @import("util.zig");

pub fn render(allocator: std.mem.Allocator, current: *const context.Context) !segment.Output {
    const git = current.git orelse return .{};
    const counts = git.counts;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try util.appendCount(&text, allocator, "+", counts.staged);
    try util.appendCount(&text, allocator, "!", counts.modified);
    try util.appendCount(&text, allocator, "-", counts.deleted);
    try util.appendCount(&text, allocator, "~", counts.renamed);
    try util.appendCount(&text, allocator, "?", counts.untracked);
    try util.appendCount(&text, allocator, "*", counts.stashed);
    try util.appendCount(&text, allocator, "⇡", counts.ahead);
    try util.appendCount(&text, allocator, "⇣", counts.behind);
    return util.output(allocator, text.items, .git_status);
}
