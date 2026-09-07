const std = @import("std");
const async_manager = @import("async/manager.zig");
const line_analysis = @import("highlight/mod.zig");

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
const aws = @import("prompt/segments/aws.zig");
const directory = @import("prompt/segments/directory.zig");
const git_branch = @import("prompt/segments/git_branch.zig");
const git_commit = @import("prompt/segments/git_commit.zig");
const git_provider = @import("prompt/segments/git_provider.zig");
const git_state = @import("prompt/segments/git_state.zig");
const git_status = @import("prompt/segments/git_status.zig");
const git = @import("prompt/git.zig");
const git_wire = @import("prompt/git_wire.zig");
const os = @import("prompt/segments/os.zig");
const python = @import("prompt/segments/python.zig");
const kubernetes = @import("prompt/segments/kubernetes.zig");
const kubernetes_provider = @import("prompt/kubernetes.zig");
const resize = @import("prompt/resize.zig");
const status = @import("prompt/segments/status.zig");
const sudo = @import("prompt/segments/sudo.zig");
const zle_hooks = @import("zle_hooks.zig");

const allocator = std.heap.c_allocator;
const Context = context.Context;
const segment_count = @typeInfo(segment.Name).@"enum".fields.len;
// Submission is nonblocking. These deadlines are not foreground wait budgets.
const submission_deadline_ns = std.time.ns_per_ms;

const renderers = std.EnumArray(segment.Name, segment.Renderer).init(.{
    .os = os.render,
    .directory = directory.render,
    .git_provider = git_provider.render,
    .git_branch = git_branch.render,
    .git_commit = git_commit.render,
    .git_state = git_state.render,
    .git_status = git_status.render,
    .status = status.render,
    .python = python.render,
    .kubernetes = kubernetes.render,
    .aws = aws.render,
    .sudo = sudo.render,
    .character = character.render,
});

const visibility = std.EnumArray(segment.Name, segment.Visibility).init(.{
    .os = .always,
    .directory = .always,
    .git_provider = .always,
    .git_branch = .always,
    .git_commit = .always,
    .git_state = .always,
    .git_status = .always,
    .status = .always,
    .python = .always,
    .kubernetes = .{ .commands = kubernetes.matchesCommand },
    .aws = .{ .commands = aws.matchesCommand },
    .sudo = .always,
    .character = .always,
});

var preprompt_registered = false;
var last_columns: usize = 0;
var last_prompt: ?[]u8 = null;
var last_rprompt: ?[]u8 = null;
var redraw_subscription = zle_hooks.Subscription.init(redrawBeforeZle);
var analysis_subscription = line_analysis.AnalysisSubscription.init(lineAnalysisUpdated);
var git_job = async_manager.Job.init(.prompt_git, workerCompleted);
var kubernetes_job = async_manager.Job.init(.prompt_kubernetes, kubernetesCompleted);
var kubernetes_generation: u64 = 0;
var pending_kubernetes_generation: ?u64 = null;
var pending_kubernetes_epoch: u64 = 0;
var kubernetes_requested = false;
var kubernetes_text: ?[]u8 = null;
var last_visibility: [segment_count]bool = @splat(false);
var git_generation: u64 = 0;
var pending_git_generation: ?u64 = null;
var pending_git_cwd: ?[]u8 = null;
var pending_git_started_ns: u64 = 0;
var pending_git_worker_epoch: u64 = 0;
var git_cache: ?GitCache = null;
var last_initial_total_ns: u64 = 0;
var last_sync_wait_ns: u64 = 0;

const GitCache = struct {
    cwd: []u8,
    info: ?git.Info,
    duration_ns: u64,
    latency_ns: u64,

    fn deinit(self: *GitCache) void {
        allocator.free(self.cwd);
        if (self.info) |*info| info.deinit(allocator);
        self.* = undefined;
    }
};

pub fn setup() c_int {
    if (preprompt_registered) return 0;

    git_job.register() catch return 1;
    kubernetes_job.register() catch {
        git_job.unregister();
        return 1;
    };
    analysis_subscription.register() catch {
        kubernetes_job.unregister();
        git_job.unregister();
        return 1;
    };
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
    git_job.unregister();
    kubernetes_job.unregister();
    clearKubernetes();
    kubernetes_requested = false;
    last_visibility = @splat(false);
    analysis_subscription.unregister();
    redraw_subscription.unregister();
    if (preprompt_registered) {
        zsh.delprepromptfn(renderPrompt);
        preprompt_registered = false;
    }
    last_columns = 0;
    last_initial_total_ns = 0;
    last_sync_wait_ns = 0;
    clearRenderedPrompts();
    clearPendingGit();
    if (git_cache) |*cache| cache.deinit();
    git_cache = null;
    metrics.clear();
}

fn redrawAfterResize() bool {
    return updatePromptForColumnChange();
}

fn redrawBeforeZle() zle_hooks.Effects {
    return if (updatePromptForColumnChange()) .{ .prompt_changed = true } else .{};
}

fn lineAnalysisUpdated() zle_hooks.Effects {
    // Most edits change a command word, not segment visibility. Avoid rebuilding
    // the whole prompt for every letter of an unrelated command.
    const next = currentVisibility();
    if (std.mem.eql(bool, &last_visibility, &next)) return .{};
    return if (updatePrompt(.async_completion)) .{ .prompt_changed = true } else .{};
}

fn currentVisibility() [segment_count]bool {
    var result: [segment_count]bool = undefined;
    inline for (std.enums.values(segment.Name)) |name| {
        result[@intFromEnum(name)] = visibility.get(name).visible(line_analysis.currentCommands());
    }
    return result;
}

fn updatePromptForColumnChange() bool {
    const columns = terminalColumns();
    if (columns == last_columns) return false;

    return updatePrompt(.resize);
}

fn renderPrompt() callconv(.c) void {
    _ = updatePrompt(.preprompt);
}

fn updatePrompt(trigger: metrics.Trigger) bool {
    const render_started = clock.nowNanoseconds();
    var snapshot: metrics.Snapshot = .{};
    defer snapshot.deinit();
    snapshot.trigger = trigger;

    const context_started = clock.nowNanoseconds();
    var current = Context.initFast() catch return false;
    defer current.deinit();
    snapshot.phases.context_ns = clock.elapsedSince(context_started);
    if (trigger == .preprompt) {
        refreshGit(current.cwd);
        refreshKubernetes();
        last_sync_wait_ns = 0;
    }
    const next_visibility = currentVisibility();
    if (next_visibility[@intFromEnum(segment.Name.kubernetes)]) requestKubernetes();
    const cache_started = clock.nowNanoseconds();
    attachCachedGit(&current) catch return false;
    current.kubernetes_text = kubernetes_text;
    snapshot.phases.cache_ns = clock.elapsedSince(cache_started);

    var values: [segment_count]segment.Output = [_]segment.Output{.{}} ** segment_count;
    defer for (&values) |*value| value.deinit(allocator);
    const segments_started = clock.nowNanoseconds();
    inline for (std.enums.values(segment.Name)) |name| {
        const segment_started = clock.nowNanoseconds();
        if (next_visibility[@intFromEnum(name)]) {
            values[@intFromEnum(name)] = renderers.get(name)(allocator, &current) catch return false;
        }
        const rendered_text: ?[]const u8 = if (values[@intFromEnum(name)].text) |text|
            text
        else if (name == .git_status and current.git != null)
            ""
        else
            null;
        snapshot.recordSegment(
            name,
            clock.elapsedSince(segment_started),
            rendered_text,
        ) catch return false;
    }
    snapshot.phases.segments_ns = clock.elapsedSince(segments_started);

    const layout_started = clock.nowNanoseconds();
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
    snapshot.phases.layout_ns = clock.elapsedSince(layout_started);

    const assignment_started = clock.nowNanoseconds();
    const prompt_changed = assignPromptIfChanged("PROMPT", prompt.items, &last_prompt) catch return false;
    const rprompt_changed = assignPromptIfChanged("RPROMPT", rprompt.items, &last_rprompt) catch return false;
    snapshot.phases.assignment_ns = clock.elapsedSince(assignment_started);
    last_columns = columns;
    last_visibility = next_visibility;
    snapshot.prompt_changed = prompt_changed or rprompt_changed;
    snapshot.phases.render_total_ns = clock.elapsedSince(render_started);
    if (trigger == .preprompt) last_initial_total_ns = snapshot.phases.render_total_ns;
    snapshot.phases.initial_total_ns = last_initial_total_ns;
    snapshot.phases.sync_wait_ns = last_sync_wait_ns;
    snapshot.phases.git_worker_ns = current.git_duration_ns;
    snapshot.phases.settled_after_ns = current.git_latency_ns;
    const changed = snapshot.prompt_changed;
    metrics.replace(&snapshot);
    return changed;
}

fn refreshGit(cwd: []const u8) void {
    // Always refresh after a command, even if an earlier inspection of this
    // directory is still running. Cancellation/reaping must not wait in ZLE.
    if (!git_job.cancelAndRestart()) {
        clearPendingGit();
        return;
    }
    clearPendingGit();

    git_generation +%= 1;
    if (git_generation == 0) git_generation = 1;
    pending_git_cwd = allocator.dupe(u8, cwd) catch return;
    pending_git_generation = git_generation;
    pending_git_started_ns = clock.nowNanoseconds();
    git_job.submit(git_generation, cwd, async_manager.deadlineAfter(submission_deadline_ns)) catch {
        clearPendingGit();
        return;
    };
    pending_git_worker_epoch = git_job.epoch();
}

fn workerCompleted(frame: *const async_manager.protocol.Frame) zle_hooks.Effects {
    if (frame.header.job != .prompt_git) return .{};
    const installed = installGitResult(frame) catch {
        clearPendingGit();
        return .{};
    };
    if (!installed) return .{};
    return if (updatePrompt(.async_completion)) .{ .prompt_changed = true } else .{};
}

fn installGitResult(frame: *const async_manager.protocol.Frame) !bool {
    if (frame.header.message != .response or
        pending_git_generation == null or
        frame.header.generation != pending_git_generation.? or
        pending_git_worker_epoch != git_job.epoch()) return false;
    if (frame.header.status != .ok) {
        clearPendingGit();
        return false;
    }

    var decoded = try git_wire.decode(allocator, frame.payload);
    defer decoded.deinit(allocator);
    const cwd = try allocator.dupe(u8, pending_git_cwd.?);
    errdefer allocator.free(cwd);
    const next = GitCache{
        .cwd = cwd,
        .info = decoded.info,
        .duration_ns = decoded.duration_ns,
        .latency_ns = clock.elapsedSince(pending_git_started_ns),
    };
    decoded.info = null;

    if (git_cache) |*cache| cache.deinit();
    git_cache = next;
    clearPendingGit();
    return true;
}

fn attachCachedGit(current: *Context) !void {
    const cache = if (git_cache) |*value| value else return;
    if (!std.mem.eql(u8, cache.cwd, current.cwd)) return;
    if (cache.info) |info| {
        const replacement = try info.clone(allocator);
        if (current.git) |*existing| existing.deinit(allocator);
        current.git = replacement;
    }
    current.git_duration_ns = cache.duration_ns;
    current.git_latency_ns = cache.latency_ns;
}

fn clearPendingGit() void {
    if (pending_git_cwd) |cwd| allocator.free(cwd);
    pending_git_cwd = null;
    pending_git_generation = null;
    pending_git_started_ns = 0;
    pending_git_worker_epoch = 0;
}

fn clearKubernetes() void {
    if (kubernetes_text) |text| allocator.free(text);
    kubernetes_text = null;
    pending_kubernetes_generation = null;
}

fn refreshKubernetes() void {
    clearKubernetes();
    kubernetes_requested = false;
    // Refresh the fork's cwd and shell parameters, but defer config I/O until
    // a relevant command is typed. Results are cached for this prompt only.
    if (!kubernetes_job.cancelAndRestart()) kubernetes_requested = true;
}

fn requestKubernetes() void {
    if (kubernetes_requested) return;
    kubernetes_requested = true;
    kubernetes_generation +%= 1;
    if (kubernetes_generation == 0) kubernetes_generation = 1;
    pending_kubernetes_generation = kubernetes_generation;
    kubernetes_job.submit(kubernetes_generation, &.{}, async_manager.deadlineAfter(submission_deadline_ns)) catch {
        pending_kubernetes_generation = null;
        return;
    };
    pending_kubernetes_epoch = kubernetes_job.epoch();
}

fn kubernetesCompleted(frame: *const async_manager.protocol.Frame) zle_hooks.Effects {
    if (frame.header.message != .response or pending_kubernetes_generation == null or
        frame.header.generation != pending_kubernetes_generation.? or
        pending_kubernetes_epoch != kubernetes_job.epoch()) return .{};
    clearKubernetes();
    if (frame.header.status == .ok and frame.payload.len != 0 and
        frame.payload.len <= kubernetes_provider.max_text_bytes and
        std.unicode.utf8ValidateSlice(frame.payload) and std.mem.indexOfScalar(u8, frame.payload, 0) == null)
    {
        kubernetes_text = allocator.dupe(u8, frame.payload) catch null;
    }
    return if (updatePrompt(.async_completion)) .{ .prompt_changed = true } else .{};
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

fn assignPromptIfChanged(name: [:0]const u8, value: []const u8, cached: *?[]u8) !bool {
    if (cached.*) |previous| if (std.mem.eql(u8, previous, value)) return false;
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    const terminated = try allocator.dupeZ(u8, value);
    defer allocator.free(terminated);
    // The normal special-parameter setter owns the metafied duplicate and
    // disposes of the previous PROMPT/RPROMPT allocation.
    _ = zsh.setsparam(@constCast(name.ptr), zsh.ztrdup_metafy(terminated.ptr));
    if (cached.*) |previous| allocator.free(previous);
    cached.* = owned;
    return true;
}

fn clearRenderedPrompts() void {
    if (last_prompt) |value| allocator.free(value);
    if (last_rprompt) |value| allocator.free(value);
    last_prompt = null;
    last_rprompt = null;
}
