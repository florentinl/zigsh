const std = @import("std");
const jobs = @import("jobs.zig");
const protocol = @import("protocol.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const allocator = std.heap.c_allocator;
const terminate_grace_ns = 25 * std.time.ns_per_ms;
const kill_grace_ns = 100 * std.time.ns_per_ms;
const reap_poll_us = 1000;

pub const SubmitError = error{
    InvalidPayload,
    PollFailed,
    TimedOut,
    WorkerClosed,
    WriteFailed,
} || StartError;

pub const ReceiveError = error{
    InvalidFrame,
    OutOfMemory,
    PayloadTooLarge,
    ReadFailed,
    UnsupportedVersion,
    WouldBlock,
    WorkerClosed,
};

pub const StartError = error{
    ConfigureFailed,
    ForkFailed,
    ProcessGroupFailed,
    SocketPairFailed,
};

pub const Client = struct {
    fd: c_int = -1,
    worker_pid: c.pid_t = -1,
    worker_pgid: c.pid_t = -1,
    owner_pid: c.pid_t = -1,

    pub fn start(self: *Client) StartError!void {
        const current_pid = c.getpid();
        if (self.owner_pid != -1 and self.owner_pid != current_pid) self.abandonInherited();
        if (self.fd >= 0) return;

        var sockets = [2]c_int{ -1, -1 };
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets) != 0) return error.SocketPairFailed;
        errdefer {
            if (sockets[0] >= 0) _ = c.close(sockets[0]);
            if (sockets[1] >= 0) _ = c.close(sockets[1]);
        }
        try configureSocket(sockets[0], true);
        try configureSocket(sockets[1], false);

        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = c.close(sockets[0]);
            if (c.setpgid(0, 0) != 0) c._exit(1);
            prepareWorkerProcess();
            const status = workerLoop(sockets[1]);
            _ = c.close(sockets[1]);
            c._exit(status);
        }

        if (c.setpgid(pid, pid) != 0) {
            terminateAndReap(pid, pid);
            return error.ProcessGroupFailed;
        }

        _ = c.close(sockets[1]);
        sockets[1] = -1;
        self.fd = sockets[0];
        sockets[0] = -1;
        self.worker_pid = pid;
        self.worker_pgid = pid;
        self.owner_pid = current_pid;
    }

    pub fn stop(self: *Client) void {
        if (self.owner_pid != -1 and self.owner_pid != c.getpid()) {
            self.abandonInherited();
            return;
        }
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.worker_pid > 0) {
            const target = if (self.worker_pgid > 0) -self.worker_pgid else self.worker_pid;
            terminateAndReap(self.worker_pid, target);
        }
        self.worker_pid = -1;
        self.worker_pgid = -1;
        self.owner_pid = -1;
    }

    pub fn restart(self: *Client) StartError!void {
        self.stop();
        try self.start();
    }

    pub fn submit(
        self: *Client,
        job: protocol.Job,
        generation: u64,
        payload: []const u8,
        deadline_ns: u64,
    ) SubmitError!void {
        if (payload.len > protocol.max_payload_length) return error.InvalidPayload;
        try self.start();
        const header = (protocol.Header{
            .message = .request,
            .job = job,
            .status = .ok,
            .generation = generation,
            .payload_length = @intCast(payload.len),
        }).encode();
        try writeBefore(self.fd, &header, deadline_ns);
        try writeBefore(self.fd, payload, deadline_ns);
    }

    pub fn receive(self: *Client, result_allocator: std.mem.Allocator) ReceiveError!?protocol.Frame {
        if (self.owner_pid != -1 and self.owner_pid != c.getpid()) self.abandonInherited();
        if (self.fd < 0) return null;

        var available: c_int = 0;
        if (c.ioctl(self.fd, c.FIONREAD, &available) != 0) return error.ReadFailed;
        if (available == 0) return null;
        if (available < protocol.header_length) return null;

        var header_bytes: [protocol.header_length]u8 = undefined;
        const peeked = c.recv(self.fd, &header_bytes, header_bytes.len, c.MSG_PEEK);
        if (peeked == 0) return error.WorkerClosed;
        if (peeked < 0) return error.ReadFailed;
        if (peeked < header_bytes.len) return null;
        const header = try protocol.Header.decode(&header_bytes);
        const total_length = protocol.header_length + @as(usize, header.payload_length);
        if (available < total_length) return null;

        try readExact(self.fd, &header_bytes);
        const payload = try result_allocator.alloc(u8, header.payload_length);
        errdefer result_allocator.free(payload);
        try readExact(self.fd, payload);
        return .{ .header = header, .payload = payload };
    }

    pub fn waitUntilReadable(self: *Client, deadline_ns: u64) error{ PollFailed, WorkerClosed }!bool {
        if (self.owner_pid != -1 and self.owner_pid != c.getpid()) self.abandonInherited();
        if (self.fd < 0) return error.WorkerClosed;
        while (true) {
            const remaining = remainingMilliseconds(deadline_ns) orelse return false;
            var descriptor = c.pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&descriptor, 1, remaining);
            if (ready == 0) return false;
            if (ready < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return error.PollFailed;
            }
            if (descriptor.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.WorkerClosed;
            return descriptor.revents & c.POLLIN != 0;
        }
    }

    pub fn responseFd(self: Client) ?c_int {
        if (self.owner_pid != c.getpid() or self.fd < 0) return null;
        return self.fd;
    }

    fn abandonInherited(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.* = .{};
    }
};

fn prepareWorkerProcess() void {
    var empty_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &empty_mask, null);
    const action = std.posix.Sigaction{
        .handler = .{ .handler = null },
        .mask = empty_mask,
        .flags = 0,
    };
    std.posix.sigaction(.HUP, &action, null);
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn configureSocket(fd: c_int, nonblocking: bool) StartError!void {
    const descriptor_flags = c.fcntl(fd, c.F_GETFD);
    if (descriptor_flags < 0 or c.fcntl(fd, c.F_SETFD, descriptor_flags | c.FD_CLOEXEC) < 0) {
        return error.ConfigureFailed;
    }
    if (nonblocking) {
        const status_flags = c.fcntl(fd, c.F_GETFL);
        if (status_flags < 0 or c.fcntl(fd, c.F_SETFL, status_flags | c.O_NONBLOCK) < 0) {
            return error.ConfigureFailed;
        }
    }
    if (@hasDecl(c, "SO_NOSIGPIPE")) {
        var enabled: c_int = 1;
        if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) {
            return error.ConfigureFailed;
        }
    }
}

fn workerLoop(fd: c_int) c_int {
    var state: jobs.State = .{};
    defer state.deinit();
    while (true) {
        var header_bytes: [protocol.header_length]u8 = undefined;
        readExact(fd, &header_bytes) catch return 0;
        const header = protocol.Header.decode(&header_bytes) catch return 1;
        if (header.message != .request) return 1;

        const payload = allocator.alloc(u8, header.payload_length) catch return 1;
        defer allocator.free(payload);
        readExact(fd, payload) catch return 0;

        const result = state.run(allocator, header.job, payload) catch |err| {
            const error_name = @errorName(err);
            writeResponse(fd, header, .failed, error_name) catch return 0;
            continue;
        };
        defer allocator.free(result);
        writeResponse(fd, header, .ok, result) catch return 0;
    }
}

fn writeResponse(fd: c_int, request: protocol.Header, status: protocol.Status, payload: []const u8) !void {
    if (payload.len > protocol.max_payload_length) return error.PayloadTooLarge;
    const header = (protocol.Header{
        .message = .response,
        .job = request.job,
        .status = status,
        .generation = request.generation,
        .payload_length = @intCast(payload.len),
    }).encode();
    try writeBlocking(fd, &header);
    try writeBlocking(fd, payload);
}

fn writeBefore(fd: c_int, bytes: []const u8, deadline_ns: u64) SubmitError!void {
    var written: usize = 0;
    while (written < bytes.len) {
        var descriptor = c.pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        const remaining = remainingMilliseconds(deadline_ns) orelse return error.TimedOut;
        const ready = c.poll(&descriptor, 1, remaining);
        if (ready == 0) return error.TimedOut;
        if (ready < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.PollFailed;
        }
        if (descriptor.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.WorkerClosed;

        const count = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (count > 0) {
            written += @intCast(count);
            continue;
        }
        if (count < 0 and (std.c._errno().* == c.EAGAIN or std.c._errno().* == c.EINTR)) continue;
        return error.WriteFailed;
    }
}

fn writeBlocking(fd: c_int, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const count = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (count > 0) {
            written += @intCast(count);
            continue;
        }
        if (count < 0 and std.c._errno().* == c.EINTR) continue;
        return error.WriteFailed;
    }
}

fn readExact(fd: c_int, bytes: []u8) !void {
    var read: usize = 0;
    while (read < bytes.len) {
        const count = c.read(fd, bytes[read..].ptr, bytes.len - read);
        if (count > 0) {
            read += @intCast(count);
            continue;
        }
        if (count == 0) return error.WorkerClosed;
        if (std.c._errno().* == c.EINTR) continue;
        if (std.c._errno().* == c.EAGAIN) return error.WouldBlock;
        return error.ReadFailed;
    }
}

fn remainingMilliseconds(deadline_ns: u64) ?c_int {
    const now = monotonicNanoseconds();
    if (now >= deadline_ns) return null;
    const remaining_ns = deadline_ns - now;
    const milliseconds = (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@min(milliseconds, @as(u64, std.math.maxInt(c_int))));
}

pub fn monotonicNanoseconds() u64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0) return 0;
    return @as(u64, @intCast(value.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(value.tv_nsec));
}

fn terminateAndReap(pid: c.pid_t, signal_target: c.pid_t) void {
    _ = c.kill(signal_target, c.SIGTERM);
    if (waitForExit(pid, terminate_grace_ns)) return;

    _ = c.kill(signal_target, c.SIGKILL);
    _ = waitForExit(pid, kill_grace_ns);
}

fn waitForExit(pid: c.pid_t, timeout_ns: u64) bool {
    const deadline_ns = monotonicNanoseconds() +| timeout_ns;
    const max_polls = timeout_ns / (reap_poll_us * std.time.ns_per_us) + 1;
    var status: c_int = 0;
    for (0..max_polls) |_| {
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid) return true;
        if (waited < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return std.c._errno().* == c.ECHILD;
        }
        if (monotonicNanoseconds() >= deadline_ns) return false;
        _ = c.usleep(reap_poll_us);
    }
    return false;
}

fn reap(pid: c.pid_t) void {
    _ = waitForExit(pid, kill_grace_ns);
}

test "per-process worker transports framed jobs" {
    var client: Client = .{};
    defer client.stop();
    try client.start();

    const deadline = monotonicNanoseconds() + std.time.ns_per_s;
    try client.submit(.ping, 7, "worker-ready", deadline);

    var descriptor = c.pollfd{ .fd = client.responseFd().?, .events = c.POLLIN, .revents = 0 };
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&descriptor, 1, 1000));
    var response = (try client.receive(std.testing.allocator)).?;
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(protocol.Message.response, response.header.message);
    try std.testing.expectEqual(protocol.Job.ping, response.header.job);
    try std.testing.expectEqual(protocol.Status.ok, response.header.status);
    try std.testing.expectEqual(@as(u64, 7), response.header.generation);
    try std.testing.expectEqualStrings("worker-ready", response.payload);
}

test "worker has an isolated process group for descendant cancellation" {
    var client: Client = .{};
    defer client.stop();
    try client.start();

    try std.testing.expectEqual(client.worker_pid, client.worker_pgid);
    try std.testing.expectEqual(client.worker_pgid, c.getpgid(client.worker_pid));
    try std.testing.expect(client.worker_pgid != c.getpgrp());
}

test "stopping a worker terminates every process in its cancellation group" {
    var client: Client = .{};
    try client.start();
    defer client.stop();

    var ready = [2]c_int{ -1, -1 };
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&ready));
    defer {
        if (ready[0] >= 0) _ = c.close(ready[0]);
        if (ready[1] >= 0) _ = c.close(ready[1]);
    }

    const member = c.fork();
    try std.testing.expect(member >= 0);
    if (member == 0) {
        _ = c.close(ready[0]);
        if (c.setpgid(0, client.worker_pgid) != 0) c._exit(2);
        const byte: u8 = 1;
        if (c.write(ready[1], &byte, 1) != 1) c._exit(3);
        while (true) _ = c.pause();
    }

    _ = c.close(ready[1]);
    ready[1] = -1;
    var byte: u8 = 0;
    if (c.read(ready[0], &byte, 1) != 1) {
        reap(member);
        return error.TestUnexpectedResult;
    }

    var member_reaped = false;
    defer if (!member_reaped) {
        _ = c.kill(member, c.SIGKILL);
        reap(member);
    };
    client.stop();

    var status: c_int = 0;
    for (0..100) |_| {
        const waited = c.waitpid(member, &status, c.WNOHANG);
        if (waited == member) {
            member_reaped = true;
            break;
        }
        try std.testing.expect(waited >= 0);
        _ = c.usleep(10 * 1000);
    }
    try std.testing.expect(member_reaped);
}

test "worker termination escalates when SIGTERM cannot terminate the child" {
    var ready = [2]c_int{ -1, -1 };
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&ready));
    defer {
        if (ready[0] >= 0) _ = c.close(ready[0]);
        if (ready[1] >= 0) _ = c.close(ready[1]);
    }

    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        _ = c.close(ready[0]);
        if (c.setpgid(0, 0) != 0) c._exit(2);
        var blocked = std.posix.sigemptyset();
        std.posix.sigaddset(&blocked, .TERM);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, null);
        const byte: u8 = 1;
        if (c.write(ready[1], &byte, 1) != 1) c._exit(3);
        while (true) _ = c.pause();
    }

    _ = c.close(ready[1]);
    ready[1] = -1;
    var byte: u8 = 0;
    try std.testing.expectEqual(@as(isize, 1), c.read(ready[0], &byte, 1));

    const started = monotonicNanoseconds();
    terminateAndReap(child, -child);
    const elapsed = monotonicNanoseconds() - started;

    try std.testing.expect(elapsed >= terminate_grace_ns);
    try std.testing.expect(elapsed < std.time.ns_per_s);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c.pid_t, -1), c.waitpid(child, &status, c.WNOHANG));
    try std.testing.expectEqual(c.ECHILD, std.c._errno().*);
}

test "worker clients abandon inherited ownership without signalling the parent worker" {
    var client = Client{ .fd = -1, .worker_pid = 123, .worker_pgid = 123, .owner_pid = c.getpid() + 1 };
    try std.testing.expect(client.responseFd() == null);
    _ = client.receive(std.testing.allocator) catch unreachable;
    try std.testing.expectEqual(@as(c.pid_t, -1), client.worker_pid);
    try std.testing.expectEqual(@as(c.pid_t, -1), client.worker_pgid);
    try std.testing.expectEqual(@as(c.pid_t, -1), client.owner_pid);
}
