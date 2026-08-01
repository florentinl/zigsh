const segment = @import("segment.zig");
const style = @import("style.zig");

/// This is intentionally ordinary Zig: changing the prompt means editing this
/// file and rebuilding the module. There is no runtime config file or loader.
pub const styles = .{
    .line = style.Style{ .foreground = .{ .red = 0x44, .green = 0x44, .blue = 0x44 } },
    .panel = style.Style{ .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .separator = style.Style{ .foreground = .{ .red = 0x30, .green = 0x30, .blue = 0x30 } },
    .cap_left = style.Style{ .foreground = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .cap_right = style.Style{ .foreground = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .os = style.Style{ .foreground = .{ .red = 0xee, .green = 0xee, .blue = 0xe7 }, .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .directory = style.Style{ .foreground = .{ .red = 0x00, .green = 0xff, .blue = 0xff }, .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .git = style.Style{ .foreground = .{ .red = 0x55, .green = 0xdd, .blue = 0x88 }, .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .git_state = style.Style{ .foreground = .{ .red = 0xff, .green = 0x66, .blue = 0x66 }, .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .git_status = style.Style{ .foreground = .{ .red = 0xff, .green = 0xde, .blue = 0x57 }, .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .success = style.Style{ .foreground = .{ .red = 0x55, .green = 0xdd, .blue = 0x88 }, .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .@"error" = style.Style{ .foreground = .{ .red = 0xff, .green = 0x66, .blue = 0x66 }, .background = .{ .red = 0x1c, .green = 0x1c, .blue = 0x1c } },
    .sudo = style.Style{ .foreground = .{ .red = 0xff, .green = 0xde, .blue = 0x57 } },
    .character = style.Style{ .foreground = .{ .red = 0x55, .green = 0xdd, .blue = 0x88 }, .bold = true },
};

/// Template tags: {{segment}}, {{if.segment}}...{{/if}},
/// {{style.name}}...{{/style}}, and {{fill}}. Literal text is safe by default.
pub const top_template =
    "{{style.line}}╭─{{/style}}{{style.panel}} {{os}}{{if.directory}}{{style.separator}} {{/style}}{{directory}}{{/if}}{{if.git}}{{style.separator}} {{/style}}{{git_provider}}{{git_branch}}{{git_commit}}{{git_state}}{{git_status}}{{/if}}{{/style}}{{style.cap_right}}{{/style}}{{fill}}{{style.cap_left}}{{/style}}{{status}}{{style.line}}─╮{{/style}}";
pub const bottom_template = "{{style.line}}╰─{{/style}}{{sudo}}{{character}}";
pub const right_template = "{{style.line}}─╯{{/style}}";

/// Lowest priority entries disappear first. Directory and Git operation state
/// are deliberately absent: they are retained until the emergency fallback.
pub const collapse_order = &[_]segment.Name{
    .git_provider,
    .git_commit,
    .git_status,
    .os,
    .status,
};
