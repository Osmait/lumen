//! Unix stream sockets and whole reads and writes on descriptors, for the
//! client, the daemon's socket and Hyprland's. Reads take a deadline for
//! the whole read, not one per call (a peer sending a byte a second would
//! hold a per-call timeout forever).

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const os = @import("root.zig");

/// The errno of a raw syscall result, null when it succeeded.
pub fn failed(result: usize) ?linux.E {
    const errno = linux.errno(result);
    return if (errno == .SUCCESS) null else errno;
}

pub const ConnectOptions = struct { nonblock: bool = false };

/// A connected socket at `path`, or null (nothing listening, no such path).
pub fn connect(path: []const u8, options: ConnectOptions) ?linux.fd_t {
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    // The path must leave room for its terminating zero.
    if (path.len >= address.path.len) return null;
    @memcpy(address.path[0..path.len], path);
    const flags: u32 = if (options.nonblock) linux.SOCK.NONBLOCK else 0;
    const socket_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | flags,
        0,
    );
    if (failed(socket_result) != null) return null;
    const fd: linux.fd_t = @intCast(socket_result);
    if (!connectTo(fd, &address)) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// How many times a connect the listener's full backlog turned away
/// (EAGAIN, non-blocking) or a signal cut short (EINTR) is tried again.
const connect_attempts_max = 5;
/// The pause between those attempts.
const connect_retry_ms = 10;
/// How long a connect still in progress (EINPROGRESS) is waited for.
const connect_wait_ms = 1000;

fn connectTo(fd: linux.fd_t, address: *const linux.sockaddr.un) bool {
    var attempt: usize = 0;
    while (attempt < connect_attempts_max) : (attempt += 1) {
        const errno = failed(linux.connect(fd, address, @sizeOf(linux.sockaddr.un))) orelse
            return true;
        switch (errno) {
            // A retried connect that the first one completed.
            .ISCONN => return true,
            .INTR => continue,
            .AGAIN => os.sleepUs(connect_retry_ms * std.time.us_per_ms),
            .INPROGRESS, .ALREADY => return connectFinished(fd),
            else => return false,
        }
    }
    return false;
}

/// Waits for a connect in progress on `fd`; whether it succeeded.
fn connectFinished(fd: linux.fd_t) bool {
    const deadline_ns = os.monotonicNs() + connect_wait_ms * std.time.ns_per_ms;
    while (true) {
        const now_ns = os.monotonicNs();
        if (now_ns >= deadline_ns) return false;
        const left_ms: i32 = @intCast((deadline_ns - now_ns) / std.time.ns_per_ms + 1);
        var poll_fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
        const ready_count = linux.poll(&poll_fds, 1, left_ms);
        if (failed(ready_count)) |errno| switch (errno) {
            .INTR => continue,
            else => return false,
        };
        if (ready_count > 0) break;
    }
    var socket_error: i32 = 0;
    var socket_error_len: linux.socklen_t = @sizeOf(i32);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        @ptrCast(&socket_error),
        &socket_error_len,
    );
    return failed(result) == null and socket_error == 0;
}

/// Ignores SIGPIPE process-wide so writing to a closed pipe or socket
/// returns EPIPE instead of killing the process (Zig's start code no longer
/// ignores it).
pub fn ignoreSigpipe() void {
    const action: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.PIPE, &action, null);
}

/// Writes all of `bytes`; false when the descriptor failed first.
pub fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    os.writeAll(fd, bytes) catch return false;
    return true;
}

/// One write to a socket, as a raw syscall result: a peer that has gone is
/// EPIPE, not the SIGPIPE that kills the process (Zig's start code no longer
/// ignores it).
pub fn send(fd: linux.fd_t, bytes: []const u8) usize {
    return linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
}

/// Sends all of `bytes` on a blocking socket; false when the peer went first.
pub fn sendAll(fd: linux.fd_t, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const bytes_sent = send(fd, bytes[sent..]);
        if (failed(bytes_sent)) |errno| switch (errno) {
            .INTR => continue,
            else => return false,
        };
        sent += bytes_sent;
    }
    return true;
}

/// struct ucred (SO_PEERCRED).
const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

/// The user on the other end of a connected Unix socket, as the kernel saw
/// it connect (or listen); null when it cannot tell.
pub fn peerUid(fd: linux.fd_t) ?u32 {
    var credentials: Ucred = undefined;
    var credentials_len: linux.socklen_t = @sizeOf(Ucred);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        @ptrCast(&credentials),
        &credentials_len,
    );
    if (failed(result) != null) return null;
    if (credentials_len != @sizeOf(Ucred)) return null;
    return credentials.uid;
}

pub const ReadError = error{ Timeout, Syscall };

/// No deadline: wait as long as the peer takes.
pub const deadline_ns_none: u64 = std.math.maxInt(u64);

/// One read into `bytes` once `fd` is readable, waiting until `deadline_ns`
/// (monotonic) at most: 0 at end of input. A descriptor poll cannot wait on
/// (closed, invalid) is `error.Syscall`, not a wait that spins.
pub fn readSome(fd: linux.fd_t, bytes: []u8, deadline_ns: u64) ReadError!usize {
    while (true) {
        if (deadline_ns != deadline_ns_none) {
            const now_ns = os.monotonicNs();
            if (now_ns >= deadline_ns) return error.Timeout;
            const left_ms: i32 = @intCast(@min(
                (deadline_ns - now_ns) / std.time.ns_per_ms + 1,
                std.math.maxInt(i32),
            ));
            switch (pollReadable(fd, left_ms)) {
                .ready => {},
                .not_yet => continue,
                .failed => return error.Syscall,
            }
        }
        const bytes_read = linux.read(fd, bytes.ptr, bytes.len);
        if (failed(bytes_read)) |errno| switch (errno) {
            .INTR => continue,
            // A non-blocking descriptor with nothing yet (a stdin left
            // O_NONBLOCK): wait for it rather than spin on read.
            .AGAIN => {
                if (deadline_ns == deadline_ns_none and pollReadable(fd, -1) == .failed) {
                    return error.Syscall;
                }
                continue;
            },
            else => return error.Syscall,
        };
        return bytes_read;
    }
}

const Readiness = enum { ready, not_yet, failed };

/// One poll for input on `fd`, up to `timeout_ms` (-1: no limit). A signal
/// or the timeout is `not_yet`; a descriptor poll rejects is `failed`.
fn pollReadable(fd: linux.fd_t, timeout_ms: i32) Readiness {
    var poll_fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const ready_count = linux.poll(&poll_fds, 1, timeout_ms);
    if (failed(ready_count)) |errno| return if (errno == .INTR) .not_yet else .failed;
    if (ready_count == 0) return .not_yet;
    // Not open: a read would fail every time.
    if (poll_fds[0].revents & linux.POLL.NVAL != 0) return .failed;
    return .ready;
}

/// Reads until end of input or `bytes` is full; how many bytes it read.
pub fn readAll(fd: linux.fd_t, bytes: []u8, deadline_ns: u64) ReadError!usize {
    var bytes_read: usize = 0;
    while (bytes_read < bytes.len) {
        const chunk_len = try readSome(fd, bytes[bytes_read..], deadline_ns);
        if (chunk_len == 0) break;
        bytes_read += chunk_len;
    }
    assert(bytes_read <= bytes.len);
    return bytes_read;
}

test "whole reads and writes over a socket pair" {
    var fds: [2]i32 = undefined;
    try std.testing.expect(
        failed(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) == null,
    );
    defer _ = linux.close(fds[0]);
    try std.testing.expect(writeAll(fds[1], "hello"));
    try std.testing.expect(failed(linux.shutdown(fds[1], linux.SHUT.WR)) == null);
    var received: [16]u8 = undefined;
    const received_len = try readAll(fds[0], &received, os.monotonicNs() + std.time.ns_per_s);
    try std.testing.expectEqualStrings("hello", received[0..received_len]);
    _ = linux.close(fds[1]);

    // A peer that sends nothing and never closes: the deadline ends it.
    try std.testing.expect(
        failed(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) == null,
    );
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    const start_ns = os.monotonicNs();
    const deadline_ns = start_ns + 50 * std.time.ns_per_ms;
    try std.testing.expectError(error.Timeout, readAll(fds[0], &received, deadline_ns));
    try std.testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);

    try std.testing.expect(connect("/nonexistent/lumen.sock", .{}) == null);
}

test "a descriptor poll rejects fails the read instead of spinning to the deadline" {
    var fds: [2]i32 = undefined;
    try std.testing.expect(failed(linux.pipe2(&fds, .{ .CLOEXEC = true })) == null);
    _ = linux.close(fds[1]);
    // Closed: poll answers POLLNVAL for it at once, every time.
    _ = linux.close(fds[0]);
    var received: [16]u8 = undefined;
    const start_ns = os.monotonicNs();
    const deadline_ns = start_ns + 5 * std.time.ns_per_s;
    try std.testing.expectError(error.Syscall, readSome(fds[0], &received, deadline_ns));
    try std.testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);
}

test "a non-blocking descriptor is waited on, without a deadline too" {
    var fds: [2]i32 = undefined;
    try std.testing.expect(failed(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK,
        0,
        &fds,
    )) == null);
    defer _ = linux.close(fds[0]);
    // Written later, from another thread: until then each read is EAGAIN.
    const Late = struct {
        fn write(fd: i32) void {
            os.sleepUs(50 * std.time.us_per_ms);
            _ = writeAll(fd, "late");
            _ = linux.close(fd);
        }
    };
    const writer = try std.Thread.spawn(.{}, Late.write, .{fds[1]});
    defer writer.join();
    var received: [16]u8 = undefined;
    const received_len = try readAll(fds[0], &received, deadline_ns_none);
    try std.testing.expectEqualStrings("late", received[0..received_len]);
}

test "a send to a peer that has gone fails, the process lives" {
    var fds: [2]i32 = undefined;
    try std.testing.expect(
        failed(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) == null,
    );
    defer _ = linux.close(fds[1]);
    try std.testing.expectEqual(linux.getuid(), peerUid(fds[1]).?);
    _ = linux.close(fds[0]);
    try std.testing.expect(!sendAll(fds[1], "anyone there"));
}
