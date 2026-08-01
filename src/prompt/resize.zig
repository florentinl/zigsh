const std = @import("std");
const zle_events = @import("../zle_events.zig");
const zle_hooks = @import("../zle_hooks.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const zsh = @cImport({
    @cInclude("zsh.mdh");
});

pub const Callback = *const fn () bool;

var callback: ?Callback = null;
var fd_subscription = zle_events.Subscription.init(handleReadablePipe);
var pipe_fds = [2]c_int{ -1, -1 };
var previous_action: std.posix.Sigaction = undefined;
var signal_handler_installed = false;

pub fn setup(on_resize: Callback) c_int {
    if (callback != null) return 0;

    setupFallible(on_resize) catch {
        cleanup();
        return 1;
    };
    return 0;
}

fn setupFallible(on_resize: Callback) error{SetupFailed}!void {
    if (c.pipe(&pipe_fds) != 0) return error.SetupFailed;
    zsh.addmodulefd(pipe_fds[0], zsh.FDT_MODULE);
    zsh.addmodulefd(pipe_fds[1], zsh.FDT_MODULE);

    if (!configurePipeEnd(pipe_fds[0]) or !configurePipeEnd(pipe_fds[1])) return error.SetupFailed;

    fd_subscription.register(pipe_fds[0]) catch return error.SetupFailed;

    var blocked_signals = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked_signals, .WINCH);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked_signals, &previous_mask);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);

    std.posix.sigaction(.WINCH, null, &previous_action);
    if (previous_action.flags & std.posix.SA.SIGINFO != 0) return error.SetupFailed;

    callback = on_resize;
    var action = previous_action;
    action.handler.handler = resizeSignal;
    std.posix.sigaction(.WINCH, &action, null);
    signal_handler_installed = true;
}

pub fn cleanup() void {
    restoreSignalHandler();
    fd_subscription.unregister();
    closePipe();
    callback = null;
}

fn configurePipeEnd(fd: c_int) bool {
    const status_flags = c.fcntl(fd, c.F_GETFL);
    if (status_flags < 0 or c.fcntl(fd, c.F_SETFL, status_flags | c.O_NONBLOCK) < 0) return false;

    const descriptor_flags = c.fcntl(fd, c.F_GETFD);
    return descriptor_flags >= 0 and c.fcntl(fd, c.F_SETFD, descriptor_flags | c.FD_CLOEXEC) >= 0;
}

fn resizeSignal(signal: std.posix.SIG) callconv(.c) void {
    const saved_errno = std.c._errno().*;
    defer std.c._errno().* = saved_errno;

    const write_fd = @as(*const volatile c_int, @ptrCast(&pipe_fds[1])).*;
    if (write_fd >= 0) {
        const wakeup = [_]u8{1};
        _ = c.write(write_fd, &wakeup, wakeup.len);
    }

    if (previous_action.handler.handler) |previous_handler| {
        if (previous_handler != resizeSignal and @intFromPtr(previous_handler) > 1) previous_handler(signal);
    }
}

fn handleReadablePipe() zle_hooks.Effects {
    drainPipe();
    if (callback) |on_resize| {
        if (on_resize()) return .{ .prompt_changed = true };
    }
    return .{};
}

fn drainPipe() void {
    var buffer: [64]u8 = undefined;
    while (c.read(pipe_fds[0], &buffer, buffer.len) > 0) {}
}

fn restoreSignalHandler() void {
    if (!signal_handler_installed) return;

    var blocked_signals = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked_signals, .WINCH);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked_signals, &previous_mask);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);

    var current_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.WINCH, null, &current_action);
    if (current_action.handler.handler == resizeSignal) {
        std.posix.sigaction(.WINCH, &previous_action, null);
    }
    signal_handler_installed = false;
}

fn closePipe() void {
    for (&pipe_fds) |*fd| {
        if (fd.* >= 0) {
            _ = zsh.zclose(fd.*);
            fd.* = -1;
        }
    }
}
