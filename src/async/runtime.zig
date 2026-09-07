const std = @import("std");
const jobs = @import("jobs.zig");
const protocol = @import("protocol.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("pthread.h");
    @cInclude("signal.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const allocator = std.heap.c_allocator;
const receive_budget = 64 * 1024;

pub const SubmitError = error{ InvalidPayload, Busy, OutOfMemory, WorkerClosed, WriteFailed } || StartError;
pub const ReceiveError = error{
    InvalidFrame,
    OutOfMemory,
    PayloadTooLarge,
    ReadFailed,
    UnsupportedVersion,
    WorkerClosed,
    WriteFailed,
};
pub const StartError = error{
    ConfigureFailed,
    ForkFailed,
    ProcessGroupFailed,
    SocketPairFailed,
    ReaperUnavailable,
};

pub const Client = struct {
    fd: c_int = -1,
    worker_pid: c.pid_t = -1,
    worker_pgid: c.pid_t = -1,
    owner_pid: c.pid_t = -1,
    retirement: ?usize = null,
    request: ?[]u8 = null,
    request_written: usize = 0,
    unacknowledged: usize = 0,
    active: bool = false,
    decoder: Decoder = .{},

    pub fn start(self: *Client) StartError!void {
        const current_pid = c.getpid();
        if (self.owner_pid != -1 and self.owner_pid != current_pid) self.abandonInherited();
        if (self.fd >= 0) return;

        // Reserve before forking: cancellation must never need to allocate or wait for room.
        const retirement = try reaper.reserve();
        var owns_retirement = true;
        errdefer if (owns_retirement) reaper.release(retirement);
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
            _ = c.kill(-pid, c.SIGKILL);
            _ = c.kill(pid, c.SIGKILL);
            reaper.retire(retirement, pid);
            owns_retirement = false;
            return error.ProcessGroupFailed;
        }

        _ = c.close(sockets[1]);
        self.fd = sockets[0];
        self.worker_pid = pid;
        self.worker_pgid = pid;
        self.owner_pid = current_pid;
        self.retirement = retirement;
    }

    pub fn stop(self: *Client) void {
        if (self.owner_pid != -1 and self.owner_pid != c.getpid()) {
            self.abandonInherited();
            return;
        }
        self.fd = closeFd(self.fd);
        if (self.worker_pid > 0) {
            // Read-only jobs need no graceful shutdown. Kill the group even if its
            // leader has already exited, so grandchildren cannot outlive recovery.
            _ = c.kill(if (self.worker_pgid > 0) -self.worker_pgid else self.worker_pid, c.SIGKILL);
            if (self.retirement) |index| reaper.retire(index, self.worker_pid);
        }
        self.clearBuffers();
        self.* = .{};
    }

    pub fn restart(self: *Client) StartError!void {
        self.stop();
        try self.start();
    }

    /// Queues at most one bounded request. The legacy deadline is not an IO wait.
    /// Credits read by receive() drive the remaining writes via ZLE readability.
    pub fn submit(self: *Client, job: protocol.Job, generation: u64, payload: []const u8, deadline_ns: u64) SubmitError!void {
        _ = deadline_ns;
        if (payload.len > protocol.max_payload_length) return error.InvalidPayload;
        try self.start();
        if (self.active) return error.Busy;
        const bytes = try allocator.alloc(u8, protocol.header_length + payload.len);
        const header = (protocol.Header{
            .message = .request,
            .job = job,
            .status = .ok,
            .generation = generation,
            .payload_length = @intCast(payload.len),
        }).encode();
        @memcpy(bytes[0..protocol.header_length], &header);
        @memcpy(bytes[protocol.header_length..], payload);
        self.request = bytes;
        self.request_written = 0;
        self.unacknowledged = 0;
        self.active = true;
        self.flushRequest() catch |err| {
            self.stop();
            return err;
        };
    }

    fn flushRequest(self: *Client) error{WriteFailed}!void {
        const request = self.request orelse return;
        const length = @min(request.len - self.request_written, protocol.request_credit - self.unacknowledged);
        if (length == 0) return;
        const count = send(self.fd, request[self.request_written..][0..length]);
        if (count > 0) {
            self.request_written += @intCast(count);
            self.unacknowledged += @intCast(count);
            return;
        }
        // When bytes are outstanding another credit will wake us. With none,
        // there can be no future wakeup: fail instead of stranding the request.
        if (count < 0 and isRetryable() and self.unacknowledged != 0) return;
        return error.WriteFailed;
    }

    pub fn receive(self: *Client, result_allocator: std.mem.Allocator) ReceiveError!?protocol.Frame {
        if (self.owner_pid != -1 and self.owner_pid != c.getpid()) self.abandonInherited();
        if (self.fd < 0) return null;
        var budget: usize = receive_budget;
        while (budget > 0) {
            const header = self.decoder.header orelse blk: {
                if (!try readPart(self.fd, &self.decoder.header_bytes, &self.decoder.header_read, &budget)) return null;
                const decoded = try protocol.Header.decode(&self.decoder.header_bytes);
                if (decoded.message != .response and decoded.message != .credit) return error.InvalidFrame;
                if (decoded.message == .credit) {
                    if (decoded.payload_length != 0 or decoded.status != .ok or decoded.generation == 0 or
                        decoded.generation > self.unacknowledged) return error.InvalidFrame;
                    self.unacknowledged -= @intCast(decoded.generation);
                    self.decoder.header_read = 0;
                    try self.flushRequest();
                    continue;
                }
                self.decoder.payload = try allocator.alloc(u8, decoded.payload_length);
                self.decoder.header = decoded;
                break :blk decoded;
            };
            if (!try readPart(self.fd, self.decoder.payload.?, &self.decoder.payload_read, &budget)) return null;
            const payload = try result_allocator.dupe(u8, self.decoder.payload.?);
            self.decoder.reset();
            if (self.request) |request| allocator.free(request);
            self.request = null;
            self.active = false;
            return .{ .header = header, .payload = payload };
        }
        return null;
    }

    /// For non-ZLE callers only. Submission and receive never call poll.
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
            // Drain buffered data before reporting EOF, including POLLIN|POLLHUP.
            if (descriptor.revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) return true;
            return error.WorkerClosed;
        }
    }

    pub fn responseFd(self: Client) ?c_int {
        if (self.owner_pid != c.getpid() or self.fd < 0) return null;
        return self.fd;
    }

    fn clearBuffers(self: *Client) void {
        if (self.request) |request| allocator.free(request);
        self.decoder.reset();
    }

    fn abandonInherited(self: *Client) void {
        _ = closeFd(self.fd);
        self.clearBuffers();
        self.* = .{};
    }
};

const Decoder = struct {
    header_bytes: [protocol.header_length]u8 = undefined,
    header_read: usize = 0,
    header: ?protocol.Header = null,
    payload: ?[]u8 = null,
    payload_read: usize = 0,

    fn reset(self: *Decoder) void {
        if (self.payload) |payload| allocator.free(payload);
        self.* = .{};
    }
};

fn readPart(fd: c_int, bytes: []u8, offset: *usize, budget: *usize) ReceiveError!bool {
    while (offset.* < bytes.len and budget.* != 0) {
        const count = c.read(fd, bytes[offset.*..].ptr, @min(bytes.len - offset.*, budget.*));
        if (count > 0) {
            offset.* += @intCast(count);
            budget.* -= @intCast(count);
        } else if (count == 0) {
            return error.WorkerClosed;
        } else if (isRetryable()) {
            return false;
        } else return error.ReadFailed;
    }
    return offset.* == bytes.len;
}

fn isRetryable() bool {
    const err = std.c._errno().*;
    return err == c.EAGAIN or err == c.EWOULDBLOCK or err == c.EINTR;
}

fn prepareWorkerProcess() void {
    var empty_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &empty_mask, null);
    const action = std.posix.Sigaction{ .handler = .{ .handler = null }, .mask = empty_mask, .flags = 0 };
    std.posix.sigaction(.HUP, &action, null);
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.ALRM, &action, null);
}

fn configureSocket(fd: c_int, nonblocking: bool) StartError!void {
    const descriptor_flags = c.fcntl(fd, c.F_GETFD);
    if (descriptor_flags < 0 or c.fcntl(fd, c.F_SETFD, descriptor_flags | c.FD_CLOEXEC) < 0) return error.ConfigureFailed;
    if (nonblocking) {
        const status_flags = c.fcntl(fd, c.F_GETFL);
        if (status_flags < 0 or c.fcntl(fd, c.F_SETFL, status_flags | c.O_NONBLOCK) < 0) return error.ConfigureFailed;
    }
    if (@hasDecl(c, "SO_NOSIGPIPE")) {
        var enabled: c_int = 1;
        if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) return error.ConfigureFailed;
    }
}

fn workerLoop(fd: c_int) c_int {
    var state: jobs.State = .{};
    defer state.deinit();
    while (true) {
        var header_bytes: [protocol.header_length]u8 = undefined;
        readRequest(fd, &header_bytes) catch return 0;
        const header = protocol.Header.decode(&header_bytes) catch return 1;
        if (header.message != .request) return 1;
        const payload = allocator.alloc(u8, header.payload_length) catch return 1;
        defer allocator.free(payload);
        readRequest(fd, payload) catch return 0;

        // Only execution is timed. The shell may be outside ZLE while requests
        // or responses wait for credits; that must not time out a healthy job.
        _ = c.alarm(if (header.job == .prompt_git) 30 else 5);
        defer _ = c.alarm(0);
        const result = state.run(allocator, header.job, payload) catch |err| {
            _ = c.alarm(0);
            writeResponse(fd, header, .failed, @errorName(err)) catch return 0;
            continue;
        };
        defer allocator.free(result);
        _ = c.alarm(0);
        writeResponse(fd, header, .ok, result) catch return 0;
    }
}

// Acknowledge every read, not only complete chunks: even a short nonblocking
// parent write must have a readable wakeup to make further progress.
fn readRequest(fd: c_int, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.read(fd, bytes[offset..].ptr, @min(bytes.len - offset, protocol.request_credit));
        if (count > 0) {
            offset += @intCast(count);
            const credit = (protocol.Header{
                .message = .credit,
                .job = .ping,
                .status = .ok,
                .generation = @intCast(count),
                .payload_length = 0,
            }).encode();
            try writeBlocking(fd, &credit);
        } else if (count == 0) return error.WorkerClosed else if (std.c._errno().* != c.EINTR) return error.ReadFailed;
    }
}

fn writeResponse(fd: c_int, request: protocol.Header, status: protocol.Status, payload: []const u8) !void {
    const oversized = payload.len > protocol.max_payload_length;
    const body = if (oversized) "PayloadTooLarge" else payload;
    const header = (protocol.Header{
        .message = .response,
        .job = request.job,
        .status = if (oversized) .failed else status,
        .generation = request.generation,
        .payload_length = @intCast(body.len),
    }).encode();
    try writeBlocking(fd, &header);
    try writeBlocking(fd, body);
}

fn send(fd: c_int, bytes: []const u8) isize {
    return c.send(fd, bytes.ptr, bytes.len, if (@hasDecl(c, "MSG_NOSIGNAL")) c.MSG_NOSIGNAL else 0);
}

fn writeBlocking(fd: c_int, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const count = send(fd, bytes[written..]);
        if (count > 0) written += @intCast(count) else if (count < 0 and std.c._errno().* == c.EINTR) continue else return error.WriteFailed;
    }
}

fn closeFd(fd: c_int) c_int {
    if (fd >= 0) _ = c.close(fd);
    return -1;
}

fn remainingMilliseconds(deadline_ns: u64) ?c_int {
    const now = monotonicNanoseconds();
    if (now >= deadline_ns) return null;
    const milliseconds = (deadline_ns - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@min(milliseconds, @as(u64, std.math.maxInt(c_int))));
}

pub fn monotonicNanoseconds() u64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0) return 0;
    return @as(u64, @intCast(value.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(value.tv_nsec));
}

// Only this thread polls retired PIDs. It never calls Zsh, allocates, or waits
// for child exit. An interruptible condition wait makes module unload independent
// of child exit; any children still pending after the final nonblocking sweep
// (including uninterruptible tasks) remain for Zsh/the OS to reap.
const Reaper = struct {
    const capacity = 256;
    const Entry = struct { reserved: bool = false, pid: c.pid_t = -1 };
    owner_pid: c.pid_t = -1,
    mutex: c.pthread_mutex_t = undefined,
    condition: c.pthread_cond_t = undefined,
    thread: c.pthread_t = undefined,
    stopping: bool = false,
    entries: [capacity]Entry = @splat(.{}),

    fn ensure(self: *Reaper) StartError!void {
        const pid = c.getpid();
        if (self.owner_pid == pid) return;
        // Never lock or destroy synchronization inherited from another process.
        self.* = .{};
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.ReaperUnavailable;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.condition, null) != 0) return error.ReaperUnavailable;
        errdefer _ = c.pthread_cond_destroy(&self.condition);
        var blocked: c.sigset_t = undefined;
        var previous: c.sigset_t = undefined;
        _ = c.sigfillset(&blocked);
        _ = c.pthread_sigmask(c.SIG_SETMASK, &blocked, &previous);
        defer _ = c.pthread_sigmask(c.SIG_SETMASK, &previous, null);
        if (c.pthread_create(&self.thread, null, run, self) != 0) return error.ReaperUnavailable;
        self.owner_pid = pid;
    }

    fn reserve(self: *Reaper) StartError!usize {
        try self.ensure();
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        for (&self.entries, 0..) |*entry, index| {
            if (!entry.reserved) {
                entry.reserved = true;
                return index;
            }
        }
        return error.ReaperUnavailable;
    }

    fn release(self: *Reaper, index: usize) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.entries[index] = .{};
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn retire(self: *Reaper, index: usize, pid: c.pid_t) void {
        if (self.owner_pid != c.getpid()) return;
        _ = c.pthread_mutex_lock(&self.mutex);
        self.entries[index].pid = pid;
        _ = c.pthread_cond_signal(&self.condition);
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn run(context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Reaper = @ptrCast(@alignCast(context.?));
        _ = c.pthread_mutex_lock(&self.mutex);
        while (true) {
            const snapshot = self.entries;
            _ = c.pthread_mutex_unlock(&self.mutex);
            var reaped: [capacity]bool = @splat(false);
            for (snapshot, 0..) |entry, index| {
                if (entry.pid <= 0) continue;
                var status: c_int = 0;
                const waited = c.waitpid(entry.pid, &status, c.WNOHANG);
                reaped[index] = waited == entry.pid or (waited < 0 and std.c._errno().* == c.ECHILD);
            }
            _ = c.pthread_mutex_lock(&self.mutex);
            for (reaped, 0..) |done, index| {
                if (done and self.entries[index].pid == snapshot[index].pid) self.entries[index] = .{};
            }
            if (self.stopping) break;
            var pending = false;
            for (self.entries) |entry| pending = pending or entry.pid > 0;
            if (pending) {
                var until: c.struct_timespec = undefined;
                _ = c.clock_gettime(c.CLOCK_REALTIME, &until);
                until.tv_nsec += 50 * std.time.ns_per_ms;
                if (until.tv_nsec >= std.time.ns_per_s) {
                    until.tv_sec += 1;
                    until.tv_nsec -= std.time.ns_per_s;
                }
                _ = c.pthread_cond_timedwait(&self.condition, &self.mutex, &until);
            } else _ = c.pthread_cond_wait(&self.condition, &self.mutex);
        }
        _ = c.pthread_mutex_unlock(&self.mutex);
        return null;
    }

    fn shutdown(self: *Reaper) void {
        if (self.owner_pid != c.getpid()) return;
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stopping = true;
        _ = c.pthread_cond_signal(&self.condition);
        _ = c.pthread_mutex_unlock(&self.mutex);
        _ = c.pthread_join(self.thread, null);
        _ = c.pthread_cond_destroy(&self.condition);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.* = .{};
    }
};

var reaper: Reaper = .{};

/// Call after stopping all clients, before unloading module code.
pub fn cleanup() void {
    reaper.shutdown();
}

fn testFrame(client: *Client) !protocol.Frame {
    const deadline = monotonicNanoseconds() + 5 * std.time.ns_per_s;
    while (try client.waitUntilReadable(deadline)) {
        if (try client.receive(std.testing.allocator)) |frame| return frame;
    }
    return error.TestUnexpectedResult;
}

fn testSocketPair() ![2]c_int {
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    errdefer {
        _ = c.close(sockets[0]);
        _ = c.close(sockets[1]);
    }
    try configureSocket(sockets[0], true);
    try configureSocket(sockets[1], false);
    return sockets;
}

fn testHeader(length: u32) protocol.Header {
    return .{ .message = .response, .job = .ping, .status = .ok, .generation = 7, .payload_length = length };
}

fn testWaitReaped(pid: c.pid_t) !void {
    const deadline = monotonicNanoseconds() + std.time.ns_per_s;
    while (monotonicNanoseconds() < deadline) {
        var status: c_int = 0;
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid or (waited < 0 and std.c._errno().* == c.ECHILD)) return;
        _ = c.usleep(1000);
    }
    return error.TestUnexpectedResult;
}

test "runtime receives fragmented headers and payloads without waiting" {
    const sockets = try testSocketPair();
    defer _ = c.close(sockets[1]);
    var client = Client{ .fd = sockets[0], .owner_pid = c.getpid() };
    defer client.stop();
    const header = testHeader(5).encode();
    for (header) |byte| {
        try writeBlocking(sockets[1], &.{byte});
        try std.testing.expect(try client.receive(std.testing.allocator) == null);
    }
    for ("hello"[0..4]) |byte| {
        try writeBlocking(sockets[1], &.{byte});
        try std.testing.expect(try client.receive(std.testing.allocator) == null);
    }
    try writeBlocking(sockets[1], "o");
    var frame = (try client.receive(std.testing.allocator)).?;
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", frame.payload);
    try std.testing.expectEqual(@as(u64, 7), frame.header.generation);
    try std.testing.expect(try client.receive(std.testing.allocator) == null);
}

test "runtime reports EOF before a response and after partial headers or payloads" {
    const header = testHeader(5).encode();
    for ([_]usize{ 0, 1, protocol.header_length - 1, protocol.header_length, protocol.header_length + 2 }) |length| {
        const sockets = try testSocketPair();
        var client = Client{ .fd = sockets[0], .owner_pid = c.getpid() };
        defer client.stop();
        var bytes: [protocol.header_length + 5]u8 = undefined;
        @memcpy(bytes[0..protocol.header_length], &header);
        @memcpy(bytes[protocol.header_length..], "hello");
        try writeBlocking(sockets[1], bytes[0..length]);
        // Persist partial state across readiness turns before observing EOF.
        try std.testing.expect(try client.receive(std.testing.allocator) == null);
        _ = c.close(sockets[1]);
        try std.testing.expectError(error.WorkerClosed, client.receive(std.testing.allocator));
    }
}

test "runtime drains a complete response before reporting EOF" {
    const sockets = try testSocketPair();
    var client = Client{ .fd = sockets[0], .owner_pid = c.getpid() };
    defer client.stop();
    try writeResponse(sockets[1], testHeader(0), .ok, "done");
    _ = c.close(sockets[1]);
    var frame = try testFrame(&client);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("done", frame.payload);
    try std.testing.expectError(error.WorkerClosed, client.receive(std.testing.allocator));
}

test "runtime transports requests and replies larger than socket capacity using readable credits" {
    defer cleanup();
    var client: Client = .{};
    defer client.stop();
    try client.start();
    var capacity: c_int = 8192;
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(client.fd, c.SOL_SOCKET, c.SO_SNDBUF, &capacity, @sizeOf(c_int)));
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(client.fd, c.SOL_SOCKET, c.SO_RCVBUF, &capacity, @sizeOf(c_int)));
    const payload = try std.testing.allocator.alloc(u8, protocol.max_payload_length);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index);
    // Even an already-expired legacy deadline must not turn into an IO wait.
    try client.submit(.ping, 7, payload, 0);
    try std.testing.expect(client.request_written <= protocol.request_credit);
    var frame = try testFrame(&client);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Status.ok, frame.header.status);
    try std.testing.expectEqualSlices(u8, payload, frame.payload);
    try std.testing.expect(!client.active);
    try std.testing.expect(client.request == null);
    try client.submit(.ping, 8, "next", 0);
    var next = try testFrame(&client);
    defer next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("next", next.payload);
}

test "runtime oversize response is a failed frame followed by a good job" {
    defer cleanup();
    const sockets = try testSocketPair();
    const reservation = try reaper.reserve();
    const oversized = try std.testing.allocator.alloc(u8, protocol.max_payload_length + 1);
    defer std.testing.allocator.free(oversized);
    const pid = c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = c.close(sockets[0]);
        if (c.setpgid(0, 0) != 0) c._exit(2);
        prepareWorkerProcess();
        // Simulate a job whose result expands beyond the input frame limit,
        // then resume the real worker loop on the very same connection.
        writeResponse(sockets[1], testHeader(0), .ok, oversized) catch c._exit(3);
        c._exit(workerLoop(sockets[1]));
    }
    _ = c.close(sockets[1]);
    var client = Client{
        .fd = sockets[0],
        .owner_pid = c.getpid(),
        .worker_pid = pid,
        .worker_pgid = pid,
        .retirement = reservation,
    };
    defer client.stop();
    var failed = try testFrame(&client);
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Status.failed, failed.header.status);
    try std.testing.expectEqualStrings("PayloadTooLarge", failed.payload);
    try client.submit(.ping, 8, "good", 0);
    var good = try testFrame(&client);
    defer good.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Status.ok, good.header.status);
    try std.testing.expectEqual(@as(u64, 8), good.header.generation);
    try std.testing.expectEqualStrings("good", good.payload);
}

test "runtime backpressured submission and cancellation do not wait on the worker" {
    defer cleanup();
    var client: Client = .{};
    defer client.stop();
    try client.start();
    const pid = client.worker_pid;
    try std.testing.expectEqual(@as(c_int, 0), c.kill(pid, c.SIGSTOP));
    const payload = try std.testing.allocator.alloc(u8, protocol.max_payload_length);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const started = monotonicNanoseconds();
    try client.submit(.ping, 1, payload, started + std.time.ns_per_s);
    try std.testing.expect(monotonicNanoseconds() - started < 50 * std.time.ns_per_ms);
    try std.testing.expect(client.request_written <= protocol.request_credit);
    try std.testing.expectError(error.Busy, client.submit(.ping, 2, "busy", 0));
    const stopped = monotonicNanoseconds();
    client.stop();
    try std.testing.expect(monotonicNanoseconds() - stopped < 25 * std.time.ns_per_ms);
    try testWaitReaped(pid);
}

test "runtime failed initial nonblocking write cannot strand a queued request" {
    const sockets = try testSocketPair();
    defer _ = c.close(sockets[1]);
    var client = Client{ .fd = sockets[0], .owner_pid = c.getpid() };
    defer client.stop();
    const bytes: [4096]u8 = @splat(0);
    while (send(client.fd, &bytes) > 0) {}
    try std.testing.expectError(error.WriteFailed, client.submit(.ping, 1, "full", 0));
    try std.testing.expect(client.responseFd() == null);
    try std.testing.expect(!client.active);
}

test "runtime rejects invalid credits rather than leaving a busy request" {
    const sockets = try testSocketPair();
    defer _ = c.close(sockets[1]);
    var client = Client{ .fd = sockets[0], .owner_pid = c.getpid() };
    defer client.stop();
    var credit = testHeader(0);
    credit.message = .credit;
    const encoded = credit.encode();
    try writeBlocking(sockets[1], &encoded);
    try std.testing.expectError(error.InvalidFrame, client.receive(std.testing.allocator));
}

test "runtime cancellation kills descendants even when the group leader already exited" {
    defer cleanup();
    var ready: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&ready));
    defer _ = c.close(ready[0]);
    const reservation = try reaper.reserve();
    const pid = c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = c.close(ready[0]);
        if (c.setpgid(0, 0) != 0) c._exit(2);
        const descendant = c.fork();
        if (descendant < 0) c._exit(3);
        if (descendant > 0) c._exit(0);
        var blocked = std.posix.sigemptyset();
        std.posix.sigaddset(&blocked, .TERM);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, null);
        const byte: u8 = 1;
        if (c.write(ready[1], &byte, 1) != 1) c._exit(4);
        while (true) _ = c.pause();
    }
    _ = c.close(ready[1]);
    var client = Client{ .worker_pid = pid, .worker_pgid = pid, .owner_pid = c.getpid(), .retirement = reservation };
    defer client.stop();
    var byte: u8 = 0;
    try std.testing.expectEqual(@as(isize, 1), c.read(ready[0], &byte, 1));
    // Reap the leader first: cancellation must still target its surviving group.
    var status: c_int = 0;
    try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
    const started = monotonicNanoseconds();
    client.stop();
    try std.testing.expect(monotonicNanoseconds() - started < 25 * std.time.ns_per_ms);
    var descriptor = c.pollfd{ .fd = ready[0], .events = c.POLLIN, .revents = 0 };
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&descriptor, 1, 1000));
    try std.testing.expectEqual(@as(isize, 0), c.read(ready[0], &byte, 1));
}

test "runtime cleanup wakes and joins reaper without waiting for a live retired child" {
    defer cleanup();
    const reservation = try reaper.reserve();
    const pid = c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) while (true) {
        _ = c.pause();
    };
    defer {
        _ = c.kill(pid, c.SIGKILL);
        testWaitReaped(pid) catch {};
    }
    // Models SIGKILL pending on an uninterruptible child. Unload must not wait
    // for this PID, and no detached thread may keep executing module code.
    reaper.retire(reservation, pid);
    const started = monotonicNanoseconds();
    cleanup();
    try std.testing.expect(monotonicNanoseconds() - started < 50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(c.pid_t, -1), reaper.owner_pid);
    // Re-initialization after module reload remains possible.
    const next = try reaper.reserve();
    reaper.release(next);
}

test "runtime worker clients abandon inherited ownership without signalling parent workers" {
    defer cleanup();
    var client: Client = .{};
    defer client.stop();
    try client.start();
    const original = client.worker_pid;
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        if (client.responseFd() != null) c._exit(2);
        client.stop();
        cleanup(); // Must not touch inherited pthread state.
        if (client.worker_pid != -1) c._exit(3);
        client.start() catch c._exit(4);
        client.stop();
        cleanup();
        c._exit(0);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expectEqual(original, c.getpgid(original));
    try std.testing.expect(original != c.getpgrp());
    try client.submit(.ping, 7, "still-alive", 0);
    var frame = try testFrame(&client);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("still-alive", frame.payload);
}

test "runtime worker resets inherited alarm handler and signal mask" {
    const child = c.fork();
    try std.testing.expect(child >= 0);
    if (child == 0) {
        var blocked = std.posix.sigemptyset();
        std.posix.sigaddset(&blocked, .ALRM);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, null);
        const ignore = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = blocked, .flags = 0 };
        std.posix.sigaction(.ALRM, &ignore, null);
        prepareWorkerProcess();
        _ = c.raise(c.SIGALRM);
        c._exit(3);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, c.waitpid(child, &status, 0));
    try std.testing.expectEqual(@as(c_int, c.SIGALRM), status & 0x7f);
}

test "runtime retired workers are reaped asynchronously without shell waitpid" {
    defer cleanup();
    var client: Client = .{};
    defer client.stop();
    try client.start();
    const pid = client.worker_pid;
    const index = client.retirement.?;
    client.stop();
    const deadline = monotonicNanoseconds() + std.time.ns_per_s;
    var reserved = true;
    while (monotonicNanoseconds() < deadline) {
        _ = c.pthread_mutex_lock(&reaper.mutex);
        reserved = reaper.entries[index].reserved;
        _ = c.pthread_mutex_unlock(&reaper.mutex);
        if (!reserved) break;
        _ = c.usleep(1000);
    }
    try std.testing.expect(!reserved);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c.pid_t, -1), c.waitpid(pid, &status, c.WNOHANG));
    try std.testing.expectEqual(c.ECHILD, std.c._errno().*);
}

test "runtime fragmented credits drive a partially queued submission" {
    const sockets = try testSocketPair();
    defer _ = c.close(sockets[1]);
    var client = Client{ .fd = sockets[0], .owner_pid = c.getpid() };
    defer client.stop();
    const payload: [protocol.request_credit * 2]u8 = @splat('x');
    try client.submit(.ping, 1, &payload, 0);
    const first_written = client.request_written;
    var consumed: [protocol.request_credit]u8 = undefined;
    try std.testing.expectEqual(@as(isize, @intCast(first_written)), c.read(sockets[1], &consumed, first_written));
    var credit = testHeader(0);
    credit.message = .credit;
    credit.generation = first_written;
    const encoded = credit.encode();
    for (encoded[0 .. encoded.len - 1]) |byte| {
        try writeBlocking(sockets[1], &.{byte});
        try std.testing.expect(try client.receive(std.testing.allocator) == null);
        try std.testing.expectEqual(first_written, client.request_written);
    }
    try writeBlocking(sockets[1], encoded[encoded.len - 1 ..]);
    try std.testing.expect(try client.receive(std.testing.allocator) == null);
    try std.testing.expect(client.request_written > first_written);
    try std.testing.expect(client.unacknowledged <= protocol.request_credit);
}
