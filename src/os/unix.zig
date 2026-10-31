//! Unix stream sockets and whole reads and writes on descriptors, for the
//! client, the daemon's socket and Hyprland's. Reads take a deadline for
//! the whole read, not one per call (a peer sending a byte a second would
//! hold a per-call timeout forever).

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const os = @import("root.zig");

/// The errno of a raw syscall result, null when it succeeded.
pub fn failed(rc: usize) ?linux.E {
    const errno = linux.errno(rc);
    return if (errno == .SUCCESS) null else errno;
}

pub const ConnectOptions = struct { nonblock: bool = false };

/// A connected socket at `path`, or null (nothing listening, no such path).
pub fn connect(path: []const u8, opts: ConnectOptions) ?linux.fd_t {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    // The path must leave room for its terminating zero.
    if (path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    const flags: u32 = if (opts.nonblock) linux.SOCK.NONBLOCK else 0;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | flags, 0);
    if (failed(rc) != null) return null;
    const fd: linux.fd_t = @intCast(rc);
    if (failed(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != null) {
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
        const rc = send(fd, bytes[sent..]);
        if (failed(rc)) |errno| switch (errno) {
            .INTR => continue,
            else => return false,
        };
        sent += rc;
    }
    return true;
}

/// struct ucred (SO_PEERCRED).
const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

/// The user on the other end of a connected Unix socket, as the kernel saw
/// it connect (or listen); null when it cannot tell.
pub fn peerUid(fd: linux.fd_t) ?u32 {
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
    if (failed(rc) != null) return null;
    if (len != @sizeOf(Ucred)) return null;
    return cred.uid;
}

pub const ReadError = error{ Timeout, Syscall };

/// No deadline: wait as long as the peer takes.
pub const no_deadline: u64 = std.math.maxInt(u64);

/// One read into `buf` once `fd` is readable, waiting until `deadline_ns`
/// (monotonic) at most: 0 at end of input.
pub fn readSome(fd: linux.fd_t, buf: []u8, deadline_ns: u64) ReadError!usize {
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
        const rc = linux.read(fd, buf.ptr, buf.len);
        if (failed(rc)) |errno| switch (errno) {
            .INTR => continue,
            // A non-blocking descriptor with nothing yet (a stdin left
            // O_NONBLOCK): wait for it rather than spin on read.
            .AGAIN => {
                if (deadline_ns == no_deadline) _ = os.waitReadable(fd, -1);
                continue;
            },
            else => return error.Syscall,
        };
        return rc;
    }
}

/// Reads until end of input or `buf` is full; the bytes read.
pub fn readAll(fd: linux.fd_t, buf: []u8, deadline_ns: u64) ReadError!usize {
    var bytes_read: usize = 0;
    while (bytes_read < buf.len) {
        const chunk_len = try readSome(fd, buf[bytes_read..], deadline_ns);
        if (chunk_len == 0) break;
        bytes_read += chunk_len;
    }
    assert(bytes_read <= buf.len);
    return bytes_read;
}

test "whole reads and writes over a socket pair" {
    var fds: [2]i32 = undefined;
    try std.testing.expect(
        failed(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) == null,
    );
    defer _ = linux.close(fds[0]);
    try std.testing.expect(writeAll(fds[1], "hello"));
    _ = linux.shutdown(fds[1], linux.SHUT.WR);
    var buf: [16]u8 = undefined;
    const n = try readAll(fds[0], &buf, os.monotonicNs() + std.time.ns_per_s);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
    _ = linux.close(fds[1]);

    // A peer that sends nothing and never closes: the deadline ends it.
    try std.testing.expect(
        failed(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) == null,
    );
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    const t0 = os.monotonicNs();
    try std.testing.expectError(error.Timeout, readAll(fds[0], &buf, t0 + 50 * std.time.ns_per_ms));
    try std.testing.expect(os.monotonicNs() - t0 < std.time.ns_per_s);

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
    const t = try std.Thread.spawn(.{}, Late.write, .{fds[1]});
    defer t.join();
    var buf: [16]u8 = undefined;
    const n = try readAll(fds[0], &buf, no_deadline);
    try std.testing.expectEqualStrings("late", buf[0..n]);
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
