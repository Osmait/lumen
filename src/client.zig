//! `lumen`, the command a keyboard shortcut runs. It hands its arguments to
//! the running daemon over a Unix socket (src/ipc.zig) and prints the
//! answer. It loads no GTK: a GTK4 program spends ~40 ms just loading its
//! libraries, which every press of the shortcut used to pay before the
//! window could open. Static, no libc.
//!
//! Anything it does not pass on runs lumen-gtk, the whole program, next to
//! it, with the same arguments: no daemon yet (that starts one), --daemon,
//! --dmenu, installs, mistakes (lumen-gtk prints the usage).

const std = @import("std");
const linux = std.os.linux;
const ipc = @import("ipc.zig");

/// Flags passed on as they are, and those taking a value.
const plain = [_][]const u8{ "--toggle", "--show", "--hide", "--quit", "--reload", "--stats", "--dump" };
const valued = [_][]const u8{ "--key", "--text", "--view", "--query", "--command" };

var request: [ipc.max_request]u8 = undefined;
var answer: [8 << 20]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) void {
    const argv = init.args.vector;
    const envp: [*:null]const ?[*:0]const u8 = init.environ.block.slice.ptr;
    const args = argv[1..];
    if (std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR")) |rt| {
        const app_id = std.process.Environ.getPosix(init.environ, "LUMEN_APP_ID") orelse ipc.default_app_id;
        if (clipStore(args)) {
            // wl-clipboard says when a copy is a password manager's or a clear.
            if (std.process.Environ.getPosix(init.environ, "CLIPBOARD_STATE")) |state|
                if (!std.mem.eql(u8, state, "data")) linux.exit_group(0);
            if (ask(rt, app_id, args, true)) |status| linux.exit_group(status);
        } else if (passable(args)) {
            if (ask(rt, app_id, args, false)) |status| linux.exit_group(status);
        }
    }
    runFull(argv, envp);
}

fn clipStore(args: []const [*:0]const u8) bool {
    return args.len == 1 and std.mem.eql(u8, std.mem.span(args[0]), "--clip-store");
}

fn passable(args: []const [*:0]const u8) bool {
    var i: usize = 0;
    next: while (i < args.len) : (i += 1) {
        const a = std.mem.span(args[i]);
        for (plain) |f| if (std.mem.eql(u8, a, f)) continue :next;
        for (valued) |f| if (std.mem.eql(u8, a, f) and i + 1 < args.len) {
            i += 1;
            continue :next;
        };
        return false;
    }
    return true;
}

/// The daemon's exit status, or null when there is no daemon to ask.
fn ask(runtime_dir: []const u8, app_id: []const u8, args: []const [*:0]const u8, with_stdin: bool) ?u8 {
    var path_buf: [256]u8 = undefined;
    const path = ipc.socketPath(&path_buf, runtime_dir, app_id) orelse return null;
    var spans: [ipc.max_args][]const u8 = undefined;
    if (args.len > spans.len) return null;
    for (args, 0..) |a, i| spans[i] = std.mem.span(a);
    const head = ipc.encode(&request, spans[0..args.len]) orelse return null;
    var len = head.len;

    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (failed(rc) != null) return null;
    const fd: linux.fd_t = @intCast(rc);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (failed(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != null) {
        _ = linux.close(fd);
        return null;
    }
    // From here on there is no going back to lumen-gtk: stdin is read, and
    // the daemon may have acted.
    if (with_stdin) {
        // A copy too large to keep is dropped here, as lumen-gtk would.
        while (true) {
            if (len == request.len) linux.exit_group(0);
            const n = linux.read(0, request[len..].ptr, request.len - len);
            if (failed(n)) |e| {
                if (e == .INTR) continue;
                linux.exit_group(1);
            }
            if (n == 0) break;
            len += n;
        }
    }
    if (!writeAll(fd, request[0..len])) return fail("lumen: the daemon closed the connection\n");
    _ = linux.shutdown(fd, linux.SHUT.WR);
    var got: usize = 0;
    while (got < answer.len) {
        const n = linux.read(fd, answer[got..].ptr, answer.len - got);
        if (failed(n)) |e| {
            if (e == .INTR) continue;
            break;
        }
        if (n == 0) break;
        got += n;
    }
    _ = linux.close(fd);
    if (got < 5) return fail("lumen: no answer from the daemon\n");
    const out_len = std.mem.readInt(u32, answer[1..5], .little);
    if (out_len > got - 5) return fail("lumen: a truncated answer from the daemon\n");
    _ = writeAll(1, answer[5..][0..out_len]);
    _ = writeAll(2, answer[5 + out_len .. got]);
    return answer[0];
}

/// lumen-gtk beside this file, else on PATH.
fn runFull(argv: []const [*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);
    var self_buf: [4096]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &self_buf, self_buf.len);
    if (failed(n) == null and n < self_buf.len) {
        const dir = std.Io.Dir.path.dirname(self_buf[0..n]) orelse "/";
        if (std.mem.printSentinel(&path_buf, "{s}/lumen-gtk", .{dir}, 0)) |p| {
            _ = linux.execve(p.ptr, argv_z, envp);
        } else |_| {}
    }
    var i: usize = 0;
    while (envp[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (!std.mem.startsWith(u8, e, "PATH=")) continue;
        var dirs = std.mem.tokenizeScalar(u8, e[5..], ':');
        while (dirs.next()) |d| {
            const p = std.mem.printSentinel(&path_buf, "{s}/lumen-gtk", .{d}, 0) catch continue;
            _ = linux.execve(p.ptr, argv_z, envp);
        }
    }
    _ = writeAll(2, "lumen: cannot find lumen-gtk (it is installed beside lumen)\n");
    linux.exit_group(127);
}

fn fail(msg: []const u8) u8 {
    _ = writeAll(2, msg);
    return 1;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = linux.write(fd, bytes[at..].ptr, bytes.len - at);
        if (failed(n)) |e| {
            if (e == .INTR) continue;
            return false;
        }
        at += n;
    }
    return true;
}

fn failed(rc: usize) ?linux.E {
    const e = linux.errno(rc);
    return if (e == .SUCCESS) null else e;
}

test "what goes over the socket" {
    const ok = [_][*:0]const u8{ "--view", "clipboard", "--query", "" };
    try std.testing.expect(passable(&ok));
    try std.testing.expect(passable(&.{}));
    try std.testing.expect(!passable(&.{"--daemon"}));
    try std.testing.expect(!passable(&.{ "--dmenu", "--prompt", "x" }));
    try std.testing.expect(!passable(&.{"--view"}));
    try std.testing.expect(!passable(&.{ "--install", "https://example.com/x.git" }));
    try std.testing.expect(clipStore(&.{"--clip-store"}));
}
