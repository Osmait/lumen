//! Unix stream sockets and whole reads and writes on descriptors, for the
//! client, the daemon's socket and Hyprland's. Reads take a deadline for
//! the whole read, not one per call (a peer sending a byte a second would
//! hold a per-call timeout forever).

const std = @import("std");
const linux = std.os.linux;
const os = @import("root.zig");

/// The errno of a raw syscall result, null when it succeeded.
pub fn failed(rc: usize) ?linux.E {
    const e = linux.errno(rc);
    return if (e == .SUCCESS) null else e;
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
        const n = linux.read(fd, buf.ptr, buf.len);
        if (failed(n)) |e| switch (e) {
            .INTR, .AGAIN => continue,
            else => return error.Syscall,
        };
        return n;
    }
}

/// Reads until end of input or `buf` is full; the bytes read.
pub fn readAll(fd: linux.fd_t, buf: []u8, deadline_ns: u64) ReadError!usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try readSome(fd, buf[got..], deadline_ns);
        if (n == 0) break;
        got += n;
    }
    return got;
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
