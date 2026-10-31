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
    if (failed(linux.connect(fd, &address, @sizeOf(linux.sockaddr.un))) != null) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
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
pub const no_deadline: u64 = std.math.maxInt(u64);

/// One read into `bytes` once `fd` is readable, waiting until `deadline_ns`
/// (monotonic) at most: 0 at end of input.
pub fn readSome(fd: linux.fd_t, bytes: []u8, deadline_ns: u64) ReadError!usize {
    while (true) {
        if (deadline_ns != no_deadline) {
            const now_ns = os.monotonicNs();
            if (now_ns >= deadline_ns) return error.Timeout;
            const left_ms: i32 = @intCast(@min(
                (deadline_ns - now_ns) / std.time.ns_per_ms + 1,
                std.math.maxInt(i32),
            ));
            if (!os.waitReadable(fd, left_ms)) continue;
        }
        const bytes_read = linux.read(fd, bytes.ptr, bytes.len);
        if (failed(bytes_read)) |errno| switch (errno) {
            .INTR => continue,
            // A non-blocking descriptor with nothing yet (a stdin left
            // O_NONBLOCK): wait for it rather than spin on read.
            .AGAIN => {
                if (deadline_ns == no_deadline) _ = os.waitReadable(fd, -1);
                continue;
            },
            else => return error.Syscall,
        };
        return bytes_read;
    }
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
    const received_len = try readAll(fds[0], &received, no_deadline);
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
