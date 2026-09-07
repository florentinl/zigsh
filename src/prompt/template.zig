const std = @import("std");
const config = @import("config.zig");
const segment = @import("segment.zig");
const style = @import("style.zig");

const max_depth = 8;

comptime {
    @setEvalBranchQuota(50_000);
    validate(config.top_template);
    validate(config.bottom_template);
    validate(config.right_template);
}

pub fn measure(template: []const u8, values: []const segment.Output) usize {
    var cursor: usize = 0;
    var enabled = [_]bool{true} ** max_depth;
    var depth: usize = 0;
    var width: usize = 0;
    while (next(template, &cursor)) |part| {
        switch (part) {
            .literal => |text| {
                if (enabled[depth]) width += displayWidth(text);
            },
            .tag => |tag| {
                if (std.mem.eql(u8, tag, "/if")) {
                    if (depth > 0) depth -= 1;
                } else if (std.mem.startsWith(u8, tag, "if.")) {
                    if (depth + 1 < max_depth) {
                        depth += 1;
                        enabled[depth] = enabled[depth - 1] and present(tag[3..], values);
                    }
                } else if (enabled[depth]) {
                    if (std.meta.stringToEnum(segment.Name, tag)) |name| {
                        if (values[@intFromEnum(name)].text) |text| width += displayWidth(text);
                    }
                }
            },
        }
    }
    return width;
}

pub fn render(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    source: []const u8,
    values: []const segment.Output,
    fill_width: usize,
) !void {
    var cursor: usize = 0;
    var enabled = [_]bool{true} ** max_depth;
    var depth: usize = 0;
    var styles = [_]?style.Name{null} ** max_depth;
    var style_depth: usize = 0;

    while (next(source, &cursor)) |part| {
        switch (part) {
            .literal => |text| {
                if (enabled[depth]) try appendLiteral(output, allocator, text);
            },
            .tag => |tag| {
                if (std.mem.eql(u8, tag, "/if")) {
                    if (depth > 0) depth -= 1;
                } else if (std.mem.startsWith(u8, tag, "if.")) {
                    if (depth + 1 < max_depth) {
                        depth += 1;
                        enabled[depth] = enabled[depth - 1] and present(tag[3..], values);
                    }
                } else if (std.mem.eql(u8, tag, "/style")) {
                    if (enabled[depth] and style_depth > 0) {
                        style_depth -= 1;
                        try appendReset(output, allocator);
                        if (style_depth > 0) if (styles[style_depth - 1]) |name| try appendStyle(output, allocator, name);
                    }
                } else if (std.mem.startsWith(u8, tag, "style.")) {
                    if (enabled[depth] and style_depth + 1 < max_depth) {
                        const name = std.meta.stringToEnum(style.Name, tag[6..]) orelse continue;
                        styles[style_depth] = name;
                        style_depth += 1;
                        try appendStyle(output, allocator, name);
                    }
                } else if (std.mem.eql(u8, tag, "fill")) {
                    if (enabled[depth]) try output.appendNTimes(allocator, ' ', fill_width);
                } else if (enabled[depth]) {
                    if (std.meta.stringToEnum(segment.Name, tag)) |name| {
                        if (values[@intFromEnum(name)].text) |text| {
                            if (values[@intFromEnum(name)].style_name) |name_style| {
                                try appendReset(output, allocator);
                                try appendStyle(output, allocator, name_style);
                                try appendLiteral(output, allocator, text);
                                try appendReset(output, allocator);
                                if (style_depth > 0) if (styles[style_depth - 1]) |outer| try appendStyle(output, allocator, outer);
                            } else {
                                try appendLiteral(output, allocator, text);
                            }
                        }
                    }
                }
            },
        }
    }
    while (style_depth > 0) : (style_depth -= 1) try appendReset(output, allocator);
}

const Part = union(enum) {
    literal: []const u8,
    tag: []const u8,
};

fn next(source: []const u8, cursor: *usize) ?Part {
    if (cursor.* >= source.len) return null;
    const start = cursor.*;
    if (std.mem.startsWith(u8, source[start..], "{{")) {
        const end = std.mem.indexOf(u8, source[start + 2 ..], "}}") orelse return .{ .literal = source[start..] };
        cursor.* = start + 2 + end + 2;
        return .{ .tag = source[start + 2 .. start + 2 + end] };
    }
    const end = std.mem.indexOf(u8, source[start..], "{{") orelse source.len - start;
    cursor.* = start + end;
    return .{ .literal = source[start .. start + end] };
}

fn present(name: []const u8, values: []const segment.Output) bool {
    if (std.mem.eql(u8, name, "git")) {
        inline for ([_]segment.Name{ .git_provider, .git_branch, .git_commit, .git_state, .git_status }) |entry| {
            if (values[@intFromEnum(entry)].text != null) return true;
        }
        return false;
    }
    const entry = std.meta.stringToEnum(segment.Name, name) orelse return false;
    return values[@intFromEnum(entry)].text != null;
}

fn appendLiteral(output: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        if (byte == '%') {
            try output.appendSlice(allocator, "%%");
        } else if (byte < 0x20 or byte == 0x7f) {
            try output.append(allocator, '?');
        } else {
            try output.append(allocator, byte);
        }
    }
}

fn appendStyle(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: style.Name) !void {
    const value = switch (name) {
        .line => config.styles.line,
        .panel => config.styles.panel,
        .separator => config.styles.separator,
        .cap_left => config.styles.cap_left,
        .cap_right => config.styles.cap_right,
        .os => config.styles.os,
        .directory => config.styles.directory,
        .git => config.styles.git,
        .git_state => config.styles.git_state,
        .git_status => config.styles.git_status,
        .success => config.styles.success,
        .@"error" => config.styles.@"error",
        .python_cap_left => config.styles.python_cap_left,
        .python => config.styles.python,
        .python_cap_right => config.styles.python_cap_right,
        .kubernetes => config.styles.kubernetes,
        .aws => config.styles.aws,
        .sudo => config.styles.sudo,
        .character => config.styles.character,
        .character_error => config.styles.character_error,
    };
    var buffer: [64]u8 = undefined;
    var sequence: std.ArrayList(u8) = .empty;
    defer sequence.deinit(allocator);
    try sequence.appendSlice(allocator, "%{\x1b[");
    var wrote = false;
    if (value.bold) {
        try sequence.append(allocator, '1');
        wrote = true;
    }
    if (value.foreground) |color| {
        if (wrote) try sequence.append(allocator, ';');
        const text = try std.fmt.bufPrint(&buffer, "38;2;{d};{d};{d}", .{ color.red, color.green, color.blue });
        try sequence.appendSlice(allocator, text);
        wrote = true;
    }
    if (value.background) |color| {
        if (wrote) try sequence.append(allocator, ';');
        const text = try std.fmt.bufPrint(&buffer, "48;2;{d};{d};{d}", .{ color.red, color.green, color.blue });
        try sequence.appendSlice(allocator, text);
    }
    try sequence.appendSlice(allocator, "m%}");
    try output.appendSlice(allocator, sequence.items);
}

fn appendReset(output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try output.appendSlice(allocator, "%{\x1b[0m%}");
}

pub fn displayWidth(text: []const u8) usize {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var width: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        width += codepointWidth(codepoint);
    }
    return width;
}

/// Zsh uses terminal cell widths, not UTF-8 byte lengths. In particular,
/// Nerd Font glyphs live in the private-use area and occupy one cell; treating
/// all non-ASCII characters as wide moves the right-hand card left.
fn codepointWidth(codepoint: u21) usize {
    if (codepoint == 0 or (codepoint >= 0x0300 and codepoint <= 0x036f)) return 0;
    return if ((codepoint >= 0x1100 and codepoint <= 0x115f) or
        (codepoint >= 0x2329 and codepoint <= 0x232a) or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf and codepoint != 0x303f) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1faff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd)) 2 else 1;
}

fn validate(comptime source: []const u8) void {
    var cursor: usize = 0;
    var condition_depth: usize = 0;
    var style_depth: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "{{")) |start| {
        const close = std.mem.indexOfPos(u8, source, start + 2, "}}") orelse @compileError("prompt template has an unclosed tag");
        const tag = source[start + 2 .. close];
        cursor = close + 2;
        if (std.mem.eql(u8, tag, "fill")) continue;
        if (std.mem.eql(u8, tag, "/if")) {
            if (condition_depth == 0) @compileError("prompt template closes an unopened conditional");
            condition_depth -= 1;
            continue;
        }
        if (std.mem.startsWith(u8, tag, "if.")) {
            if (std.mem.eql(u8, tag[3..], "git")) {
                condition_depth += 1;
                continue;
            }
            if (std.meta.stringToEnum(segment.Name, tag[3..]) == null) @compileError("prompt template references an unknown conditional segment");
            condition_depth += 1;
            continue;
        }
        if (std.mem.eql(u8, tag, "/style")) {
            if (style_depth == 0) @compileError("prompt template closes an unopened style");
            style_depth -= 1;
            continue;
        }
        if (std.mem.startsWith(u8, tag, "style.")) {
            if (std.meta.stringToEnum(style.Name, tag[6..]) == null) @compileError("prompt template references an unknown style");
            style_depth += 1;
            continue;
        }
        if (std.meta.stringToEnum(segment.Name, tag) == null) @compileError("prompt template references an unknown segment");
    }
    if (condition_depth != 0) @compileError("prompt template has an unclosed conditional");
    if (style_depth != 0) @compileError("prompt template has an unclosed style");
}

test "template escapes dynamic percent signs and honors conditionals" {
    const allocator = std.testing.allocator;
    const count = @typeInfo(segment.Name).@"enum".fields.len;
    var values: [count]segment.Output = [_]segment.Output{.{}} ** count;
    defer for (&values) |*value| value.deinit(allocator);
    values[@intFromEnum(segment.Name.os)] = .{ .text = try allocator.dupe(u8, "mac%os") };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try render(&output, allocator, "{{if.os}}[{{os}}]{{/if}}{{fill}}", &values, 2);
    try std.testing.expectEqualStrings("[mac%%os]  ", output.items);
}

test "closing a style restores its parent instead of leaking color" {
    const allocator = std.testing.allocator;
    const count = @typeInfo(segment.Name).@"enum".fields.len;
    const values: [count]segment.Output = [_]segment.Output{.{}} ** count;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try render(&output, allocator, "{{style.line}}x{{/style}}y", &values, 0);
    try std.testing.expect(std.mem.endsWith(u8, output.items, "%{\x1b[0m%}y"));
}

test "Nerd Font glyphs occupy one terminal cell" {
    try std.testing.expectEqual(@as(usize, 3), displayWidth(""));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("界"));
}

test "character separator remains outside the error background" {
    const allocator = std.testing.allocator;
    const count = @typeInfo(segment.Name).@"enum".fields.len;
    var values: [count]segment.Output = [_]segment.Output{.{}} ** count;
    defer for (&values) |*value| value.deinit(allocator);
    values[@intFromEnum(segment.Name.character)] = .{
        .text = try allocator.dupe(u8, "❯"),
        .style_name = .character_error,
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try render(&output, allocator, "{{character}} ", &values, 0);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "48;2") == null);
    try std.testing.expect(std.mem.endsWith(u8, output.items, "%{\x1b[0m%} "));
}

test "disabled conditional styles cannot leak a panel background into fill" {
    const allocator = std.testing.allocator;
    const count = @typeInfo(segment.Name).@"enum".fields.len;
    const values: [count]segment.Output = [_]segment.Output{.{}} ** count;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try render(
        &output,
        allocator,
        "{{style.panel}}x{{if.git}}{{style.separator}}y{{/style}}{{/if}}{{/style}}{{fill}}z",
        &values,
        3,
    );

    try std.testing.expect(std.mem.endsWith(u8, output.items, "%{\x1b[0m%}   z"));
}
