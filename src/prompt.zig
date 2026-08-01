const std = @import("std");

const zsh = @cImport({
    @cInclude("zsh.mdh");
});

const config = @import("prompt/config.zig");
const clock = @import("prompt/clock.zig");
const context = @import("prompt/context.zig");
pub const metrics = @import("prompt/metrics.zig");
const segment = @import("prompt/segment.zig");
const template = @import("prompt/template.zig");
const character = @import("prompt/segments/character.zig");
const directory = @import("prompt/segments/directory.zig");
const git_branch = @import("prompt/segments/git_branch.zig");
const git_commit = @import("prompt/segments/git_commit.zig");
const git_provider = @import("prompt/segments/git_provider.zig");
const git_state = @import("prompt/segments/git_state.zig");
const git_status = @import("prompt/segments/git_status.zig");
const os = @import("prompt/segments/os.zig");
const resize = @import("prompt/resize.zig");
const status = @import("prompt/segments/status.zig");
const sudo = @import("prompt/segments/sudo.zig");
const zle_hooks = @import("zle_hooks.zig");

const allocator = std.heap.c_allocator;
const Context = context.Context;
const segment_count = @typeInfo(segment.Name).@"enum".fields.len;

const definitions = [_]segment.Definition{
    .{ .name = .os, .render = os.render },
    .{ .name = .directory, .render = directory.render },
    .{ .name = .git_provider, .render = git_provider.render },
    .{ .name = .git_branch, .render = git_branch.render },
    .{ .name = .git_commit, .render = git_commit.render },
    .{ .name = .git_state, .render = git_state.render },
    .{ .name = .git_status, .render = git_status.render },
    .{ .name = .status, .render = status.render },
    .{ .name = .sudo, .render = sudo.render },
    .{ .name = .character, .render = character.render },
};

var preprompt_registered = false;
var last_columns: usize = 0;
var redraw_subscription = zle_hooks.Subscription.init(redrawBeforeZle);

pub fn setup() c_int {
    if (preprompt_registered) return 0;

    zsh.opts[zsh.PROMPTSUBST] = 0;
    zsh.rprompt_indent = 0;
    renderPrompt();
    zsh.addprepromptfn(renderPrompt);
    preprompt_registered = true;

    redraw_subscription.register() catch {
        cleanup();
        return 1;
    };
    if (resize.setup(redrawAfterResize) != 0) {
        cleanup();
        return 1;
    }
    return 0;
}

pub fn cleanup() void {
    resize.cleanup();
    redraw_subscription.unregister();
    if (preprompt_registered) {
        zsh.delprepromptfn(renderPrompt);
        preprompt_registered = false;
    }
    last_columns = 0;
    metrics.clear();
}

fn redrawAfterResize() bool {
    return updatePromptForColumnChange();
}

fn redrawBeforeZle() zle_hooks.Effects {
    return if (updatePromptForColumnChange()) .{ .prompt_changed = true } else .{};
}

fn updatePromptForColumnChange() bool {
    const columns = terminalColumns();
    if (columns == last_columns) return false;

    return updatePrompt();
}

fn renderPrompt() callconv(.c) void {
    _ = updatePrompt();
}

fn updatePrompt() bool {
    var snapshot: metrics.Snapshot = .{};
    defer snapshot.deinit();

    var current = Context.init() catch return false;
    defer current.deinit();

    var values: [segment_count]segment.Output = [_]segment.Output{.{}} ** segment_count;
    defer for (&values) |*value| value.deinit(allocator);
    for (definitions) |definition| {
        const segment_started = clock.nowNanoseconds();
        values[@intFromEnum(definition.name)] = definition.render(allocator, &current) catch return false;
        const dependency_duration = if (definition.name == .git_status) current.git_duration_ns else 0;
        const rendered_text: ?[]const u8 = if (values[@intFromEnum(definition.name)].text) |text|
            text
        else if (definition.name == .git_status and current.git != null)
            ""
        else
            null;
        snapshot.recordSegment(
            definition.name,
            clock.elapsedSince(segment_started) +| dependency_duration,
            rendered_text,
        ) catch return false;
    }

    const columns = terminalColumns();
    fitToWidth(&values, columns);

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);
    if (template.measure(config.top_template, &values) > columns) {
        template.render(&prompt, allocator, "{{character}}", &values, 0) catch return false;
    } else {
        const top_width = template.measure(config.top_template, &values);
        template.render(&prompt, allocator, config.top_template, &values, columns - top_width) catch return false;
        prompt.append(allocator, '\n') catch return false;
        template.render(&prompt, allocator, config.bottom_template, &values, 0) catch return false;
    }

    var rprompt: std.ArrayList(u8) = .empty;
    defer rprompt.deinit(allocator);
    const right_width = template.measure(config.right_template, &values);
    if (right_width < columns and template.measure(config.top_template, &values) < columns) {
        template.render(&rprompt, allocator, config.right_template, &values, 0) catch return false;
    }

    assignPrompt("PROMPT", prompt.items);
    assignPrompt("RPROMPT", rprompt.items);
    last_columns = columns;
    metrics.replace(&snapshot);
    return true;
}

fn fitToWidth(values: *[segment_count]segment.Output, columns: usize) void {
    for (config.collapse_order) |name| {
        if (template.measure(config.top_template, values) <= columns) break;
        values[@intFromEnum(name)].deinit(allocator);
    }

    if (template.measure(config.top_template, values) > columns) {
        shrinkValue(values, .git_branch, columns, false);
    }
    if (template.measure(config.top_template, values) > columns) {
        shrinkValue(values, .directory, columns, true);
    }
}

fn shrinkValue(
    values: *[segment_count]segment.Output,
    name: segment.Name,
    columns: usize,
    preserve_last_component: bool,
) void {
    const output = &values[@intFromEnum(name)];
    const text = output.text orelse return;
    const total_width = template.measure(config.top_template, values);
    const available = columns -| (total_width - template.displayWidth(text));
    if (available == 0) {
        output.deinit(allocator);
        return;
    }
    if (preserve_last_component) compactPath(output, available) else truncateOutput(output, available);
}

fn compactPath(output: *segment.Output, available: usize) void {
    const text = output.text orelse return;
    const trimmed = std.mem.trimEnd(u8, text, " ");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| {
        const compact = std.fmt.allocPrint(allocator, "…/{s} ", .{trimmed[slash + 1 ..]}) catch return;
        if (template.displayWidth(compact) < template.displayWidth(text)) {
            allocator.free(text);
            output.text = compact;
        } else {
            allocator.free(compact);
        }
    }
    truncateOutput(output, available);
}

fn truncateOutput(output: *segment.Output, available: usize) void {
    const text = output.text orelse return;
    if (template.displayWidth(text) <= available) return;
    if (available <= 1) {
        allocator.free(text);
        output.text = allocator.dupe(u8, "…") catch null;
        return;
    }

    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var used: usize = 0;
    var end: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        const width: usize = if (codepoint >= 0x1100) 2 else 1;
        if (used + width > available - 1) break;
        used += width;
        end = iterator.i;
    }
    const compact = std.fmt.allocPrint(allocator, "{s}…", .{text[0..end]}) catch return;
    allocator.free(text);
    output.text = compact;
}

fn terminalColumns() usize {
    return if (zsh.zterm_columns > 2) @intCast(zsh.zterm_columns) else 2;
}

fn assignPrompt(name: [:0]const u8, value: []const u8) void {
    const terminated = allocator.dupeZ(u8, value) catch return;
    // The normal special-parameter setter owns the metafied duplicate and
    // disposes of the previous PROMPT/RPROMPT allocation.
    _ = zsh.setsparam(@constCast(name.ptr), zsh.ztrdup_metafy(terminated.ptr));
    allocator.free(terminated);
}
