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
const cli = @import("cli.zig");
const version = @import("build_options").version;
const unix = @import("os").unix;
const failed = unix.failed;
const writeAll = unix.writeAll;

var request: [ipc.max_request_bytes]u8 = undefined;
var answer: [8 << 20]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) void {
    const argv = init.args.vector;
    const envp: [*:null]const ?[*:0]const u8 = init.environ.block.slice.ptr;
    const args = argv[1..];
    // No daemon, no GTK needed for it.
    if (args.len == 1 and cli.parse(std.mem.span(args[0])) == .help) {
        _ = writeAll(1, cli.usage);
        linux.exit_group(0);
    }
    if (args.len == 1 and cli.parse(std.mem.span(args[0])) == .version) printVersion(init.environ);
    if (std.process.Environ.getPosix(init.environ, "XDG_RUNTIME_DIR")) |rt| {
        const app_id = std.process.Environ.getPosix(
            init.environ,
            "LUMEN_APP_ID",
        ) orelse ipc.default_app_id;
        if (clipStore(args)) {
            // wl-clipboard says when a copy is a password manager's or a clear.
            if (std.process.Environ.getPosix(init.environ, "CLIPBOARD_STATE")) |state|
                if (!std.mem.eql(u8, state, "data")) linux.exit_group(0);
            storeCopy(rt, app_id, argv, envp);
        } else if (passable(args)) {
            if (encodeArgs(args)) |req|
                if (ask(rt, app_id, req)) |status| linux.exit_group(status);
        }
    }
    runFull(argv, envp);
}

/// `--clip-store`: the copy is read whole before the daemon is asked, so an
/// app slow to hand it over keeps this process waiting, not the daemon's
/// main loop. With no daemon to take it, lumen-gtk gets it as its stdin.
fn storeCopy(
    runtime_dir: []const u8,
    app_id: []const u8,
    argv: []const [*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    const head = encodeArgs(argv[1..]) orelse runFull(argv, envp);
    const len = head.len + (unix.readAll(0, request[head.len..], unix.no_deadline) catch
        linux.exit_group(1));
    // A copy too large to keep is dropped here, as lumen-gtk would.
    if (len == request.len) linux.exit_group(0);
    if (ask(runtime_dir, app_id, request[0..len])) |status| linux.exit_group(status);
    stdinFrom(request[head.len..len]);
    runFull(argv, envp);
}

/// Makes `bytes` this process's stdin (a memfd: a pipe would need a reader
/// before it could hold them all), for the program it execs next.
fn stdinFrom(bytes: []const u8) void {
    const rc = linux.memfd_create("lumen-copy", linux.MFD.CLOEXEC);
    if (failed(rc) == null) {
        const fd: linux.fd_t = @intCast(rc);
        if (writeAll(fd, bytes) and
            failed(linux.lseek(fd, 0, linux.SEEK.SET)) == null and
            failed(linux.dup2(fd, 0)) == null) return;
    }
    _ = writeAll(2, "lumen: cannot hand the copy over to lumen-gtk\n");
    linux.exit_group(1);
}

/// The request head for `args`, in `request`; null when they do not fit.
fn encodeArgs(args: []const [*:0]const u8) ?[]const u8 {
    var spans: [ipc.max_args][]const u8 = undefined;
    if (args.len > spans.len) return null;
    for (args, 0..) |a, i| spans[i] = std.mem.span(a);
    return ipc.encode(&request, spans[0..args.len]);
}

fn clipStore(args: []const [*:0]const u8) bool {
    return args.len == 1 and std.mem.eql(u8, std.mem.span(args[0]), "--clip-store");
}

/// Every flag one the daemon's socket takes, with its value.
fn passable(args: []const [*:0]const u8) bool {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = cli.parse(std.mem.span(args[i])) orelse return false;
        const spec = cli.specs.get(flag);
        if (!spec.socket) return false;
        if (spec.value == .required) {
            if (i + 1 == args.len) return false;
            i += 1;
        }
    }
    return true;
}

/// Its own version, then the running daemon's: after an update the daemon
/// started before it still runs the old one until it is restarted.
fn printVersion(environ: std.process.Environ) noreturn {
    _ = writeAll(1, "lumen " ++ version ++ "\n");
    const rt = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR") orelse linux.exit_group(0);
    const app_id = std.process.Environ.getPosix(environ, "LUMEN_APP_ID") orelse ipc.default_app_id;
    const req = encodeArgs(&.{"--version"}) orelse linux.exit_group(0);
    const a = exchange(rt, app_id, req) orelse linux.exit_group(0);
    const theirs = std.mem.trim(u8, a.out, " \n");
    if (a.status != 0) {
        // A daemon from before 0.1.0 does not know the option.
        _ = writeAll(2, "lumen: the running daemon is older; restart it: lumen --quit; lumen --daemon\n");
        linux.exit_group(0);
    }
    _ = writeAll(1, "daemon ");
    _ = writeAll(1, theirs);
    _ = writeAll(1, "\n");
    if (!std.mem.eql(u8, theirs, version))
        _ = writeAll(2, "lumen: the daemon runs another version; restart it: lumen --quit; lumen --daemon\n");
    linux.exit_group(0);
}

/// The daemon's exit status, or null when there is no daemon to ask.
fn ask(runtime_dir: []const u8, app_id: []const u8, req: []const u8) ?u8 {
    const a = exchange(runtime_dir, app_id, req) orelse return null;
    _ = writeAll(1, a.out);
    _ = writeAll(2, a.err);
    return a.status;
}

const Answer = struct { status: u8, out: []const u8, err: []const u8 };

/// Sends a request (src/ipc.zig) to the daemon and returns its answer, in
/// `answer`; null when there is no daemon of ours to ask.
fn exchange(runtime_dir: []const u8, app_id: []const u8, req: []const u8) ?Answer {
    var path_buf: [256]u8 = undefined;
    const path = ipc.socketPath(&path_buf, runtime_dir, app_id) orelse return null;
    const fd = unix.connect(path, .{}) orelse return null;
    // Our own daemon only: in a runtime folder others can write to, someone
    // else's socket would get the arguments and the copy.
    if (unix.peerUid(fd) != linux.getuid()) {
        _ = linux.close(fd);
        _ = writeAll(2, "lumen: the daemon's socket belongs to another user; not using it\n");
        return null;
    }
    // From here on there is no going back to lumen-gtk: the daemon may act
    // on what it gets.
    if (!unix.sendAll(fd, req)) return failedAnswer("lumen: the daemon closed the connection\n");
    _ = linux.shutdown(fd, linux.SHUT.WR);
    // The daemon answers when it is done, however long that takes.
    const got = unix.readAll(fd, &answer, unix.no_deadline) catch 0;
    _ = linux.close(fd);
    if (got < 5) return failedAnswer("lumen: no answer from the daemon\n");
    const out_len = std.mem.readInt(u32, answer[1..5], .little);
    if (out_len > got - 5) return failedAnswer("lumen: a truncated answer from the daemon\n");
    return .{ .status = answer[0], .out = answer[5..][0..out_len], .err = answer[5 + out_len .. got] };
}

fn failedAnswer(msg: []const u8) Answer {
    return .{ .status = 1, .out = "", .err = msg };
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
