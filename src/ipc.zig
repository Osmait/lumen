//! The socket between `lumen` (src/client.zig) and the daemon: where it is,
//! and what goes through it. No dependencies, so the client stays small.
//!
//! A request is the arguments, each as a little-endian u32 length and its
//! bytes after a u32 count, then the rest of the stream: a payload (the copy
//! `--clip-store` hands over). The client shuts its side down when done.
//! The answer is a status byte, the u32 length of what goes to stdout, that
//! text, and what goes to stderr until the end.

const std = @import("std");
const assert = std.debug.assert;

pub const default_app_id = "dev.osmait.Lumen";

/// Environment variables the client and the daemon both read.
pub const env = struct {
    /// Another app id runs a second, isolated instance (end-to-end tests).
    pub const app_id = "LUMEN_APP_ID";
    /// Set by end-to-end tests: no keyboard grab, no clipboard watcher.
    pub const test_mode = "LUMEN_TEST";
    /// Where the socket lives.
    pub const runtime_dir = "XDG_RUNTIME_DIR";
    /// wl-clipboard's verdict on the copy `--clip-store` is handed.
    pub const clipboard_state = "CLIPBOARD_STATE";
};

/// What wl-clipboard puts in CLIPBOARD_STATE. Only `data` is an ordinary
/// copy: `sensitive` comes from a password manager, and `clear` and `nil`
/// are no copy at all.
pub const ClipboardState = enum { data, sensitive, clear, nil };

/// Whether a copy whose CLIPBOARD_STATE is `state` is kept. An unknown
/// state is not, so a state added later never stores a secret by mistake.
pub fn keepsCopy(state: []const u8) bool {
    return std.meta.stringToEnum(ClipboardState, state) == .data;
}

/// Arguments and payload together; a copy larger than this is not kept
/// anyway (Db.clip_bytes_max).
pub const request_bytes_max = (1 << 20) + 64 * 1024;
pub const args_max = 64;

/// What a sockaddr_un holds of a path, its terminating zero included.
const socket_path_bytes = @sizeOf(@FieldType(std.os.linux.sockaddr.un, "path"));

/// $XDG_RUNTIME_DIR/lumen/<app id>.sock
pub fn socketPath(buf: []u8, runtime_dir: []const u8, app_id: []const u8) ?[:0]const u8 {
    if (runtime_dir.len == 0) return null;
    if (app_id.len == 0) return null;
    const format = "{s}/lumen/{s}.sock";
    const path = std.mem.printSentinel(buf, format, .{ runtime_dir, app_id }, 0) catch return null;
    return if (path.len < socket_path_bytes) path else null;
}

pub fn dir(buf: []u8, runtime_dir: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/lumen", .{runtime_dir}, 0) catch null;
}

pub const Request = struct {
    args: [args_max][]const u8 = undefined,
    argc: usize = 0,
    payload: []const u8 = "",
};

/// Splits a request; null when it is malformed.
pub fn parse(bytes: []const u8) ?Request {
    var request: Request = .{};
    if (bytes.len < 4) return null;
    const args_count = std.mem.readInt(u32, bytes[0..4], .little);
    if (args_count > args_max) return null;
    var offset: usize = 4;
    for (0..args_count) |arg_index| {
        if (bytes.len - offset < 4) return null;
        const arg_len = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        offset += 4;
        if (bytes.len - offset < arg_len) return null;
        request.args[arg_index] = bytes[offset .. offset + arg_len];
        offset += arg_len;
    }
    assert(offset <= bytes.len);
    request.argc = args_count;
    request.payload = bytes[offset..];
    return request;
}

/// Writes the request head (the arguments) into `buf`.
pub fn encode(buf: []u8, args: []const []const u8) ?[]const u8 {
    if (args.len > args_max) return null;
    if (buf.len < 4) return null;
    std.mem.writeInt(u32, buf[0..4], @intCast(args.len), .little);
    var offset: usize = 4;
    for (args) |arg| {
        if (buf.len - offset < 4 + arg.len) return null;
        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(arg.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + arg.len], arg);
        offset += arg.len;
    }
    // What is written is what the daemon will read.
    if (std.debug.runtime_safety) {
        const decoded = parse(buf[0..offset]).?;
        assert(decoded.argc == args.len);
        assert(decoded.payload.len == 0);
        for (decoded.args[0..decoded.argc], args) |got, want| {
            assert(std.mem.eql(u8, got, want));
        }
    }
    return buf[0..offset];
}

/// The answer's head: the status byte, then the length of stdout's text.
pub const answer_header_bytes = 1 + 4;

/// The head of an answer whose stdout is `stdout_len` bytes; stdout's text
/// and then stderr's follow it.
pub fn encodeAnswerHeader(status: u8, stdout_len: u32) [answer_header_bytes]u8 {
    var header: [answer_header_bytes]u8 = undefined;
    header[0] = status;
    std.mem.writeInt(u32, header[1..5], stdout_len, .little);
    return header;
}

pub const Answer = struct { status: u8, stdout: []const u8, stderr: []const u8 };

/// Splits an answer; null when it is shorter than its head says.
pub fn parseAnswer(bytes: []const u8) ?Answer {
    if (bytes.len < answer_header_bytes) return null;
    const stdout_len = std.mem.readInt(u32, bytes[1..5], .little);
    const rest = bytes[answer_header_bytes..];
    if (stdout_len > rest.len) return null;
    return .{ .status = bytes[0], .stdout = rest[0..stdout_len], .stderr = rest[stdout_len..] };
}

test "answers round-trip, and a truncated one is refused" {
    var buf: [64]u8 = undefined;
    const header = encodeAnswerHeader(7, 3);
    @memcpy(buf[0..answer_header_bytes], &header);
    @memcpy(buf[answer_header_bytes..][0..7], "outerr!");
    const answer = parseAnswer(buf[0 .. answer_header_bytes + 7]).?;
    try std.testing.expectEqual(@as(u8, 7), answer.status);
    try std.testing.expectEqualStrings("out", answer.stdout);
    try std.testing.expectEqualStrings("err!", answer.stderr);

    try std.testing.expect(parseAnswer(buf[0 .. answer_header_bytes + 2]) == null);
    try std.testing.expect(parseAnswer(buf[0..4]) == null);
}

test "requests round-trip, empty arguments included" {
    var buf: [256]u8 = undefined;
    const head = encode(&buf, &.{ "--view", "root", "--query", "" }).?;
    var full: [300]u8 = undefined;
    @memcpy(full[0..head.len], head);
    @memcpy(full[head.len..][0..5], "hello");
    const request = parse(full[0 .. head.len + 5]).?;
    try std.testing.expectEqual(@as(usize, 4), request.argc);
    try std.testing.expectEqualStrings("--query", request.args[2]);
    try std.testing.expectEqualStrings("", request.args[3]);
    try std.testing.expectEqualStrings("hello", request.payload);
}

test "malformed requests are refused" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse(&.{ 1, 0, 0, 0, 9, 0, 0, 0, 'a' }) == null);
    try std.testing.expect(parse(&.{ 200, 0, 0, 0 }) == null);
}

test "socket paths" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/run/user/1000/lumen/dev.osmait.Lumen.sock",
        socketPath(&buf, "/run/user/1000", default_app_id).?,
    );
    try std.testing.expect(socketPath(&buf, "", default_app_id) == null);
    var long: [121]u8 = @splat('x');
    long[0] = '/';
    try std.testing.expect(socketPath(&buf, &long, default_app_id) == null);
}
