const std = @import("std");
const context = @import("context.zig");
const style = @import("style.zig");

pub const Name = enum {
    os,
    directory,
    git_provider,
    git_branch,
    git_commit,
    git_state,
    git_status,
    status,
    sudo,
    character,
};

/// A segment returns an owned value. The prompt renderer frees every value
/// after applying the compiled template, so renderers never borrow stack or
/// context storage across the C/Zsh boundary.
pub const Output = struct {
    text: ?[]u8 = null,
    style_name: ?style.Name = null,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.* = .{};
    }
};

pub const Renderer = *const fn (std.mem.Allocator, *const context.Context) anyerror!Output;
