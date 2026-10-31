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

/// Static buffers: the client has no allocator (no libc, nothing to free
/// before exit_group).
var request: [ipc.request_bytes_max]u8 = undefined;
/// The longest answer read; past it the rest is cut. `--stats` and `--dump`
/// answer a few KB, an extension's command at most a few hundred.
const answer_bytes_max = 8 << 20;
var answer_buffer: [answer_bytes_max]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) void {
    const argv = init.args.vector;
    const envp: [*:null]const ?[*:0]const u8 = init.environ.block.slice.ptr;
    const arguments = argv[1..];
    const only_flag: ?cli.Flag = if (arguments.len == 1)
        cli.parse(std.mem.span(arguments[0]))
    else
        null;
    // --help is answered here: it needs neither a daemon nor GTK.
    if (only_flag == .help) {
        _ = writeAll(1, cli.usage);
        linux.exit_group(0);
    }
    if (only_flag == .version) printVersion(init.environ);
    const getEnv = std.process.Environ.getPosix;
    if (getEnv(init.environ, ipc.env.runtime_dir)) |runtime_dir| {
        const app_id = getEnv(init.environ, ipc.env.app_id) orelse ipc.app_id_default;
        if (only_flag == .clip_store) {
            // wl-clipboard says when a copy is a password manager's or a clear.
            if (getEnv(init.environ, ipc.env.clipboard_state)) |state| {
                if (!ipc.keepsCopy(state)) linux.exit_group(0);
            }
            storeCopy(runtime_dir, app_id, argv, envp);
        }
        if (passable(arguments)) {
            if (encodeArguments(arguments)) |request_head| {
                if (ask(runtime_dir, app_id, request_head)) |status| linux.exit_group(status);
            }
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
    const head = encodeArguments(argv[1..]) orelse runFull(argv, envp);
    const copy_buffer = request[head.len..];
    const copy_bytes = unix.readAll(0, copy_buffer, unix.no_deadline) catch linux.exit_group(1);
    // A copy too large to keep is dropped here, as lumen-gtk would.
    if (copy_bytes == copy_buffer.len) linux.exit_group(0);
    const request_bytes = head.len + copy_bytes;
    if (ask(runtime_dir, app_id, request[0..request_bytes])) |status| linux.exit_group(status);
    stdinFrom(copy_buffer[0..copy_bytes]);
    runFull(argv, envp);
}

/// Makes `bytes` this process's stdin (a memfd: a pipe would need a reader
/// before it could hold them all), for the program it execs next.
fn stdinFrom(bytes: []const u8) void {
    if (!memfdStdin(bytes)) {
        _ = writeAll(2, "lumen: cannot hand the copy over to lumen-gtk\n");
        linux.exit_group(1);
    }
}

fn memfdStdin(bytes: []const u8) bool {
    const memfd_result = linux.memfd_create("lumen-copy", linux.MFD.CLOEXEC);
    if (failed(memfd_result) != null) return false;
    const fd: linux.fd_t = @intCast(memfd_result);
    if (!writeAll(fd, bytes)) return false;
    if (failed(linux.lseek(fd, 0, linux.SEEK.SET)) != null) return false;
    return failed(linux.dup2(fd, 0)) == null;
}

/// The request head for `arguments`, in `request`; null when they do not
/// fit.
fn encodeArguments(arguments: []const [*:0]const u8) ?[]const u8 {
    var spans: [ipc.arguments_max][]const u8 = undefined;
    if (arguments.len > spans.len) return null;
    for (arguments, spans[0..arguments.len]) |argument, *span| span.* = std.mem.span(argument);
    return ipc.encode(&request, spans[0..arguments.len]);
}

/// Every flag one the daemon's socket takes, with its value.
fn passable(arguments: []const [*:0]const u8) bool {
    var argument_index: usize = 0;
    while (argument_index < arguments.len) : (argument_index += 1) {
        const flag = cli.parse(std.mem.span(arguments[argument_index])) orelse return false;
        const spec = cli.specs.get(flag);
        if (!spec.socket) return false;
        if (spec.value == .required) {
            if (argument_index + 1 == arguments.len) return false;
            argument_index += 1;
        }
    }
    return true;
}

/// Its own version, then the running daemon's: after an update the daemon
/// started before it still runs the old one until it is restarted.
fn printVersion(environ: std.process.Environ) noreturn {
    _ = writeAll(1, "lumen " ++ version ++ "\n");
    const getEnv = std.process.Environ.getPosix;
    const runtime_dir = getEnv(environ, ipc.env.runtime_dir) orelse linux.exit_group(0);
    const app_id = getEnv(environ, ipc.env.app_id) orelse ipc.app_id_default;
    const request_head = encodeArguments(&.{"--version"}) orelse linux.exit_group(0);
    const answer = exchange(runtime_dir, app_id, request_head) orelse linux.exit_group(0);
    const theirs = std.mem.trim(u8, answer.stdout, " \n");
    const restart = "restart it: lumen --quit; lumen --daemon\n";
    if (answer.status != 0) {
        // A daemon from before 0.1.0 does not know the option.
        _ = writeAll(2, "lumen: the running daemon is older; " ++ restart);
        linux.exit_group(0);
    }
    _ = writeAll(1, "daemon ");
    _ = writeAll(1, theirs);
    _ = writeAll(1, "\n");
    if (!std.mem.eql(u8, theirs, version)) {
        _ = writeAll(2, "lumen: the daemon runs another version; " ++ restart);
    }
    linux.exit_group(0);
}

/// The daemon's exit status, or null when there is no daemon to ask.
/// What it printed goes to this process's stdout and stderr; a write that
/// fails there has nobody to tell.
fn ask(runtime_dir: []const u8, app_id: []const u8, request_bytes: []const u8) ?u8 {
    const answer = exchange(runtime_dir, app_id, request_bytes) orelse return null;
    _ = writeAll(1, answer.stdout);
    _ = writeAll(2, answer.stderr);
    return answer.status;
}

/// Sends a request (src/ipc.zig) to the daemon and returns its answer, in
/// `answer_buffer`; null when there is no daemon of ours to ask.
fn exchange(runtime_dir: []const u8, app_id: []const u8, request_bytes: []const u8) ?ipc.Answer {
    var path_buffer: [256]u8 = undefined;
    const path = ipc.socketPath(&path_buffer, runtime_dir, app_id) orelse return null;
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
    if (!unix.sendAll(fd, request_bytes)) {
        return failedAnswer("lumen: the daemon closed the connection\n");
    }
    _ = linux.shutdown(fd, linux.SHUT.WR);
    // The daemon answers when it is done, however long that takes.
    const answer_bytes = unix.readAll(fd, &answer_buffer, unix.no_deadline) catch 0;
    _ = linux.close(fd);
    if (answer_bytes < ipc.answer_header_bytes) {
        return failedAnswer("lumen: no answer from the daemon\n");
    }
    return ipc.parseAnswer(answer_buffer[0..answer_bytes]) orelse
        failedAnswer("lumen: a truncated answer from the daemon\n");
}

fn failedAnswer(message: []const u8) ipc.Answer {
    return .{ .status = 1, .stdout = "", .stderr = message };
}

/// lumen-gtk beside this file, else on PATH.
fn runFull(argv: []const [*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    const argv_terminated: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);
    var self_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var candidate_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // An execve that returns failed: the next place is tried.
    const self_path_bytes = linux.readlink(
        "/proc/self/exe",
        &self_path_buffer,
        self_path_buffer.len,
    );
    if (failed(self_path_bytes) == null and self_path_bytes < self_path_buffer.len) {
        const self_path = self_path_buffer[0..self_path_bytes];
        const self_dir = std.Io.Dir.path.dirname(self_path) orelse "/";
        const format = "{s}/lumen-gtk";
        if (std.mem.printSentinel(&candidate_buffer, format, .{self_dir}, 0)) |candidate| {
            _ = linux.execve(candidate.ptr, argv_terminated, envp);
        } else |_| {}
    }
    var env_index: usize = 0;
    while (envp[env_index]) |env_entry_terminated| : (env_index += 1) {
        const env_entry = std.mem.span(env_entry_terminated);
        if (!std.mem.startsWith(u8, env_entry, "PATH=")) continue;
        var path_dirs = std.mem.tokenizeScalar(u8, env_entry["PATH=".len..], ':');
        while (path_dirs.next()) |path_dir| {
            const format = "{s}/lumen-gtk";
            const print = std.mem.printSentinel;
            const candidate = print(&candidate_buffer, format, .{path_dir}, 0) catch continue;
            _ = linux.execve(candidate.ptr, argv_terminated, envp);
        }
    }
    _ = writeAll(2, "lumen: cannot find lumen-gtk (it is installed beside lumen)\n");
    linux.exit_group(exit_command_not_found);
}

/// The shell's status for a program it cannot find.
const exit_command_not_found = 127;

test "what goes over the socket" {
    const ok = [_][*:0]const u8{ "--view", "clipboard", "--query", "" };
    try std.testing.expect(passable(&ok));
    try std.testing.expect(passable(&.{}));
    try std.testing.expect(!passable(&.{"--daemon"}));
    try std.testing.expect(!passable(&.{ "--dmenu", "--prompt", "x" }));
    try std.testing.expect(!passable(&.{"--view"}));
    try std.testing.expect(!passable(&.{ "--install", "https://example.com/x.git" }));
    try std.testing.expectEqual(cli.Flag.clip_store, cli.parse("--clip-store").?);
}
