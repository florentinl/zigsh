const std = @import("std");
const zle = @import("../zle.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const zsh = @cImport({
    @cInclude("zsh.mdh");
});

pub const Callback = *const fn () bool;

const widget_name: [:0]const u8 = "zigsh-resize";

var callback: ?Callback = null;
var widget: zle.Widget = .{};
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

    widget.register(widget_name, handleReadablePipe) catch return error.SetupFailed;

    if (!setFdWatch(true)) return error.SetupFailed;

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
    if (pipe_fds[0] >= 0) _ = setFdWatch(false);
    deleteWidget();
    closePipe();
    callback = null;
}

fn configurePipeEnd(fd: c_int) bool {
    const status_flags = c.fcntl(fd, c.F_GETFL);
    if (status_flags < 0 or c.fcntl(fd, c.F_SETFL, status_flags | c.O_NONBLOCK) < 0) return false;

    const descriptor_flags = c.fcntl(fd, c.F_GETFD);
    return descriptor_flags >= 0 and c.fcntl(fd, c.F_SETFD, descriptor_flags | c.FD_CLOEXEC) >= 0;
}

fn setFdWatch(enable: bool) bool {
    var command_buffer: [96]u8 = undefined;
    const command = if (enable)
        std.fmt.bufPrintZ(&command_buffer, "zle -F -w {d} {s}", .{ pipe_fds[0], widget_name }) catch return false
    else
        std.fmt.bufPrintZ(&command_buffer, "zle -F {d} 2>/dev/null", .{pipe_fds[0]}) catch return false;

    const saved_status = zsh.lastval;
    zsh.execstring(@constCast(command.ptr), 1, 0, @constCast("zigsh-resize"));
    const succeeded = zsh.lastval == 0;
    zsh.lastval = saved_status;
    return succeeded;
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

fn handleReadablePipe(_: [*c][*c]u8) callconv(.c) c_int {
    drainPipe();
    if (callback) |on_resize| {
        if (on_resize()) zle.resetPrompt();
    }
    return 0;
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

fn deleteWidget() void {
    widget.unregister();
}

fn closePipe() void {
    for (&pipe_fds) |*fd| {
        if (fd.* >= 0) {
            _ = zsh.zclose(fd.*);
            fd.* = -1;
        }
    }
}
