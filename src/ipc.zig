//! The socket between `lumen` (src/client.zig) and the daemon: where it is,
//! and what goes through it. No dependencies, so the client stays small.
//!
//! A request is the arguments, each as a little-endian u32 length and its
//! bytes after a u32 count, then the rest of the stream: a payload (the copy
//! `--clip-store` hands over). The client shuts its side down when done.
//! The answer is a status byte, the u32 length of what goes to stdout, that
//! text, and what goes to stderr until the end.

const std = @import("std");

pub const default_app_id = "dev.osmait.Lumen";

/// Arguments and payload together; a copy larger than this is not kept
/// anyway (Db.max_bytes).
pub const max_request_bytes = (1 << 20) + 64 * 1024;
pub const max_args = 64;

/// $XDG_RUNTIME_DIR/lumen/<app id>.sock
pub fn socketPath(buf: []u8, runtime_dir: []const u8, app_id: []const u8) ?[:0]const u8 {
    if (runtime_dir.len == 0 or app_id.len == 0) return null;
    // sockaddr_un holds 108 bytes.
    const p = std.mem.printSentinel(buf, "{s}/lumen/{s}.sock", .{ runtime_dir, app_id }, 0) catch return null;
    return if (p.len < 108) p else null;
}

pub fn dir(buf: []u8, runtime_dir: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/lumen", .{runtime_dir}, 0) catch null;
}

pub const Request = struct {
    args: [max_args][]const u8 = undefined,
    argc: usize = 0,
    payload: []const u8 = "",
};

/// Splits a request; null when it is malformed.
pub fn parse(bytes: []const u8) ?Request {
    var r: Request = .{};
    if (bytes.len < 4) return null;
    const n = std.mem.readInt(u32, bytes[0..4], .little);
    if (n > max_args) return null;
    var at: usize = 4;
    for (0..n) |i| {
        if (bytes.len - at < 4) return null;
        const len = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (bytes.len - at < len) return null;
        r.args[i] = bytes[at .. at + len];
        at += len;
    }
    r.argc = n;
    r.payload = bytes[at..];
    return r;
}

/// Writes the request head (the arguments) into `buf`.
pub fn encode(buf: []u8, args: []const []const u8) ?[]const u8 {
    if (args.len > max_args) return null;
    var at: usize = 0;
    if (buf.len < 4) return null;
    std.mem.writeInt(u32, buf[0..4], @intCast(args.len), .little);
    at = 4;
    for (args) |a| {
        if (buf.len - at < 4 + a.len) return null;
        std.mem.writeInt(u32, buf[at..][0..4], @intCast(a.len), .little);
        at += 4;
        @memcpy(buf[at .. at + a.len], a);
        at += a.len;
    }
    return buf[0..at];
}

test "requests round-trip, empty arguments included" {
    var buf: [256]u8 = undefined;
    const head = encode(&buf, &.{ "--view", "root", "--query", "" }).?;
    var full: [300]u8 = undefined;
    @memcpy(full[0..head.len], head);
    @memcpy(full[head.len..][0..5], "hello");
    const r = parse(full[0 .. head.len + 5]).?;
    try std.testing.expectEqual(@as(usize, 4), r.argc);
    try std.testing.expectEqualStrings("--query", r.args[2]);
    try std.testing.expectEqualStrings("", r.args[3]);
    try std.testing.expectEqualStrings("hello", r.payload);
}

test "malformed requests are refused" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse(&.{ 1, 0, 0, 0, 9, 0, 0, 0, 'a' }) == null);
    try std.testing.expect(parse(&.{ 200, 0, 0, 0 }) == null);
}

test "socket paths" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/run/user/1000/lumen/dev.osmait.Lumen.sock", socketPath(&buf, "/run/user/1000", default_app_id).?);
    try std.testing.expect(socketPath(&buf, "", default_app_id) == null);
    var long: [121]u8 = @splat('x');
    long[0] = '/';
    try std.testing.expect(socketPath(&buf, &long, default_app_id) == null);
}
