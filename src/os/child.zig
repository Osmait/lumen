//! Run a program, feed it stdin, collect its output, never wait past a
//! deadline: `lumen.exec` for extensions, and the tools text extraction
//! runs (pdftotext, unzip).

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const os = @import("root.zig");

pub const Stdin = union(enum) {
    /// Written while the output is read, so a program that answers before
    /// reading all its input cannot deadlock it. Empty: no stdin.
    bytes: []const u8,
    /// An open descriptor the program reads itself (it stays the caller's).
    fd: i32,
};

pub const Options = struct {
    stdin: Stdin = .{ .bytes = "" },
    stderr: enum { collect, ignore } = .collect,
    /// Monotonic ns: past it the program is killed.
    deadline_ns: u64,
    /// Output kept per stream. Past it the rest is dropped while the
    /// program runs on (`drop`), or the program is killed (`kill`: a
    /// tool whose output only grows).
    output_bytes_max: usize = 16 << 20,
    at_cap: enum { drop, kill } = .drop,
    /// Lumen's environment, or none (what a tool prints must not depend
    /// on the user's locale or settings).
    environ: enum { inherit, empty } = .inherit,
    /// Set: the program is killed as if past its deadline, within 100 ms
    /// (a service shutting down does not wait for its tools).
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Put on the program as soon as it is started: for tools run on
    /// untrusted input (a crafted PDF), whose memory and CPU must not reach
    /// the rest of the machine. Resource limits, not a sandbox: they keep a
    /// file from growing, not from being deleted, emptied or renamed, and
    /// leave sockets open to it. Null: none.
    limits: ?Limits = null,
};

/// Resource limits for a program (`Options.limits`), set with prlimit right
/// after it starts: std.process.spawn runs nothing in the child before
/// exec. Lowering a limit below what the program uses already only makes
/// its next allocations fail, which is what is wanted.
pub const Limits = struct {
    /// RLIMIT_AS: its whole address space.
    memory_bytes_max: u64,
    /// RLIMIT_CPU: past it, SIGXCPU then SIGKILL.
    cpu_s_max: u64,
    /// RLIMIT_FSIZE: the largest file it may write (0: none; pipes are not
    /// files, so its output still flows).
    file_bytes_max: u64 = 0,
    /// Its nice value (higher: lower priority), and the idle I/O class.
    nice: i32 = 10,
};

/// Applies `limits` to process `pid`. Best effort: a limit that cannot be
/// set (an old kernel) leaves the deadline and the output cap in force.
fn applyLimits(pid: linux.pid_t, limits: Limits) void {
    const pairs = [_]struct { linux.rlimit_resource, u64 }{
        .{ .AS, limits.memory_bytes_max },
        .{ .CPU, limits.cpu_s_max },
        .{ .FSIZE, limits.file_bytes_max },
    };
    for (pairs) |pair| {
        const resource, const value = pair;
        const limit: linux.rlimit = .{ .cur = value, .max = value };
        _ = linux.prlimit(pid, resource, &limit, null);
    }
    const prio_process = 0;
    const pid_word: usize = @bitCast(@as(isize, pid));
    const nice_word: usize = @bitCast(@as(isize, limits.nice));
    _ = linux.syscall3(.setpriority, prio_process, pid_word, nice_word);
    const ioprio_who_process = 1;
    const ioprio_class_idle: usize = 3;
    const ioprio_class_shift = 13;
    _ = linux.syscall3(
        .ioprio_set,
        ioprio_who_process,
        pid_word,
        ioprio_class_idle << ioprio_class_shift,
    );
}

/// What one read of a program's output takes: a pipe holds 64 KB.
const read_chunk_bytes = 64 << 10;

/// Owned by the caller: free with `deinit`.
pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    /// Exit code; null when killed by a signal, the deadline or the cap.
    code: ?u8,
    timed_out: bool,
    /// Killed because `options.cancel` was set rather than hitting the deadline.
    cancelled: bool = false,
    /// Killed at `output_bytes_max` (`at_cap = .kill`).
    capped: bool = false,

    pub fn deinit(result: *Result, gpa: std.mem.Allocator) void {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
};

pub const Error = std.process.SpawnError || std.mem.Allocator.Error || error{Syscall};

/// Runs `argv` (PATH searched, environment inherited) until it exits or
/// the deadline. The child is always reaped and its pipes closed.
///
/// The run ends when the program itself exits, even if a program it left
/// in the background (`gio open`, `sh -c "app &"`) still holds its outputs
/// open: that one lives on. Its process group is killed only when the run
/// is cut short (deadline, cancel, output cap).
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    options: Options,
) Error!Result {
    var empty_environment = std.process.Environ.Map.init(gpa);
    defer empty_environment.deinit();
    const stdin_bytes = switch (options.stdin) {
        .bytes => |bytes| bytes,
        .fd => "",
    };
    // A library may have set SIGPIPE to SIG_IGN since `main` (GDBus does on
    // its first connection), and spawn keeps an ignored signal ignored:
    // `cmd | head` would then run on to the deadline. The empty handler is
    // reset by execve.
    os.unix.ignoreSigpipe();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = if (options.environ == .empty) &empty_environment else null,
        .stdin = switch (options.stdin) {
            .bytes => |bytes| if (bytes.len > 0) .pipe else .ignore,
            .fd => |fd| .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } },
        },
        .stdout = .pipe,
        .stderr = if (options.stderr == .collect) .pipe else .ignore,
        // Run in its own process group so timeouts kill grandchildren too.
        .pgid = 0,
    });
    const pid = child.id.?;
    if (options.limits) |limits| applyLimits(pid, limits);
    // Readable once the program exits. Without one (an old kernel, no free
    // descriptor), the pump looks with waitid instead.
    const pidfd = os.openPidfd(pid);
    defer if (pidfd) |fd| os.close(fd);
    // Only a run cut short leaves the child unreaped here: `wait` clears
    // `child.id`. `kill` sends SIGTERM and waits: after a SIGKILL it only
    // reaps. The child is not reaped yet, so the SIGKILL cannot miss it.
    defer if (child.id) |unreaped_pid| {
        // Negative pid signals the child's entire process group so
        // grandchildren (e.g. spawned by `sh -c`) cannot outlive a timeout,
        // cancel or output cap.
        _ = linux.kill(-unreaped_pid, .KILL);
        _ = linux.kill(unreaped_pid, .KILL);
        child.kill(io);
    };

    var pump: Pump = .{
        .gpa = gpa,
        .io = io,
        .child = &child,
        .pid = pid,
        .pidfd = pidfd,
        .options = &options,
        .stdin_bytes = stdin_bytes,
        .stderr_open = options.stderr == .collect,
    };
    errdefer pump.stdout.deinit(gpa);
    errdefer pump.stderr.deinit(gpa);
    const end = try pump.loop();
    // Outputs closed with input still unwritten: a program that now waits
    // for EOF on its stdin would otherwise hang until the deadline.
    if (child.stdin) |stdin| {
        stdin.close(io);
        child.stdin = null;
    }

    // Both outputs closed, but the program may live on (it closed them):
    // wait for its exit up to the deadline.
    const exited = switch (end) {
        .exited => true,
        .closed => waitExit(pid, &options),
        .timed_out, .cancelled, .capped => false,
    };
    const cancelled = end == .cancelled or
        (end == .closed and !exited and options.cancel != null and options.cancel.?.load(.acquire));
    const timed_out = end == .timed_out or cancelled or (end == .closed and !exited);
    var code: ?u8 = null;
    if (exited) {
        // A wait that fails leaves the code unknown, as a signal does. It
        // also clears `child.id` (the deferred kill skips it), so the
        // child, which has exited, is reaped here.
        if (child.wait(io)) |termination| switch (termination) {
            .exited => |exit_code| code = exit_code,
            else => {},
        } else |_| reap(pid);
    }
    const stdout = try pump.stdout.toOwnedSlice(gpa);
    errdefer gpa.free(stdout);
    const stderr = try pump.stderr.toOwnedSlice(gpa);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .code = code,
        .timed_out = timed_out,
        .cancelled = cancelled,
        .capped = end == .capped,
    };
}

/// Reaps child `pid`, which has exited: the wait does not block.
fn reap(pid: linux.pid_t) void {
    var status: i32 = 0;
    while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
}

/// How often a run that can be cancelled looks at its `cancel` flag.
const cancel_poll_ms = 100;

/// Once the program exited, how long what it wrote last is still read
/// while a program it left in the background holds its outputs open.
const exit_drain_ms = 50;

/// Without a pidfd, how often the pump looks whether the program exited.
const exit_check_ms = 50;

/// Whether the program exited before its deadline, looked at every
/// `cancel_poll_ms` when it can be cancelled.
fn waitExit(pid: linux.pid_t, options: *const Options) bool {
    return os.waitExitCancelable(pid, options.deadline_ns, options.cancel, cancel_poll_ms);
}

/// A running program's pipes: stdin written and both outputs read in one
/// poll loop, so a program that answers before reading all its input
/// cannot deadlock it. The program's pidfd is in the loop too, so its exit
/// ends the run even while its outputs stay open.
const Pump = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    pid: linux.pid_t,
    /// Null: no pidfd; exits are looked for every `exit_check_ms`.
    pidfd: ?i32,
    options: *const Options,
    stdin_bytes: []const u8,
    written: usize = 0,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_open: bool = true,
    stderr_open: bool,
    /// Monotonic ns at which the program was seen to exit.
    exited_ns: ?u64 = null,

    const End = enum {
        /// Both outputs closed; the program may still be running.
        closed,
        /// The program exited (left to be reaped); its outputs may still
        /// be held open by programs it left in the background.
        exited,
        timed_out,
        cancelled,
        capped,
    };

    fn loop(pump: *Pump) Error!End {
        // A blocking stdin would let one write stall the whole poll loop,
        // deadline included: if it cannot be made non-blocking, give up.
        if (pump.child.stdin) |stdin| try setNonblocking(stdin.handle);
        while (pump.stdout_open or pump.stderr_open) {
            const now_ns = os.monotonicNs();
            if (pump.exited_ns) |exited_ns| {
                // It exited in time: what is left past the drain is not its.
                const drained = now_ns >= exited_ns + exit_drain_ms * std.time.ns_per_ms;
                if (drained or now_ns >= pump.options.deadline_ns) return .exited;
            } else {
                if (now_ns >= pump.options.deadline_ns) return .timed_out;
                if (pump.cancelled()) return .cancelled;
            }
            var poll_fds: [4]linux.pollfd = undefined;
            const poll_fds_count = pump.pollFds(&poll_fds);
            const ready_count = linux.poll(&poll_fds, poll_fds_count, pump.pollTimeoutMs(now_ns));
            switch (linux.errno(ready_count)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.Syscall,
            }
            for (poll_fds[0..poll_fds_count]) |poll_fd| {
                if (poll_fd.revents == 0) continue;
                if (pump.pidfd != null and poll_fd.fd == pump.pidfd.?) {
                    pump.exited_ns = os.monotonicNs();
                } else if (poll_fd.events == linux.POLL.OUT) {
                    pump.feed();
                } else if (try pump.drain(poll_fd.fd)) {
                    return .capped;
                }
            }
            if (pump.pidfd == null and pump.exited_ns == null and
                os.childState(pump.pid) == .exited)
            {
                pump.exited_ns = os.monotonicNs();
            }
        }
        // Closed as it exited, or closed with the program still running:
        // then its exit is waited for after.
        return if (pump.exited_ns != null) .exited else .closed;
    }

    fn cancelled(pump: *const Pump) bool {
        const cancel = pump.options.cancel orelse return false;
        return cancel.load(.acquire);
    }

    /// The open outputs to read, while there is input left stdin to write,
    /// and until it exits the program's pidfd; how many were filled in.
    fn pollFds(pump: *const Pump, poll_fds: *[4]linux.pollfd) usize {
        var count: usize = 0;
        if (pump.stdout_open) {
            poll_fds[count] = pollFd(pump.child.stdout.?.handle, linux.POLL.IN);
            count += 1;
        }
        if (pump.stderr_open) {
            poll_fds[count] = pollFd(pump.child.stderr.?.handle, linux.POLL.IN);
            count += 1;
        }
        if (pump.child.stdin) |stdin| {
            poll_fds[count] = pollFd(stdin.handle, linux.POLL.OUT);
            count += 1;
        }
        if (pump.exited_ns == null) if (pump.pidfd) |pidfd| {
            poll_fds[count] = pollFd(pidfd, linux.POLL.IN);
            count += 1;
        };
        assert(count > 0);
        return count;
    }

    fn pollFd(fd: i32, events: i16) linux.pollfd {
        return .{ .fd = fd, .events = events, .revents = 0 };
    }

    /// Until the deadline; in slices of `cancel_poll_ms` when the run can
    /// be cancelled, so a cancel is seen in time, and of `exit_check_ms`
    /// without a pidfd, so an exit is. Once the program exited, until the
    /// end of the drain.
    fn pollTimeoutMs(pump: *const Pump, now_ns: u64) i32 {
        if (pump.exited_ns) |exited_ns| {
            const drain_end_ns = @min(
                exited_ns + exit_drain_ms * std.time.ns_per_ms,
                pump.options.deadline_ns,
            );
            assert(now_ns < drain_end_ns);
            return @intCast((drain_end_ns - now_ns) / std.time.ns_per_ms + 1);
        }
        assert(now_ns < pump.options.deadline_ns);
        const left_ms = (pump.options.deadline_ns - now_ns) / std.time.ns_per_ms + 1;
        const cancellable = pump.options.cancel != null;
        var slice_ms: u64 = if (cancellable) cancel_poll_ms else std.math.maxInt(i32);
        if (pump.pidfd == null) slice_ms = @min(slice_ms, exit_check_ms);
        return @intCast(@min(left_ms, slice_ms));
    }

    /// Writes what stdin can take; closes it once all is written.
    fn feed(pump: *Pump) void {
        const fd = pump.child.stdin.?.handle;
        const rest = pump.stdin_bytes[pump.written..];
        const bytes_written = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(bytes_written)) {
            .SUCCESS => pump.written += bytes_written,
            .AGAIN, .INTR => {},
            // The program closed its stdin: it does not want the rest.
            else => pump.written = pump.stdin_bytes.len,
        }
        assert(pump.written <= pump.stdin_bytes.len);
        if (pump.written == pump.stdin_bytes.len) {
            pump.child.stdin.?.close(pump.io);
            pump.child.stdin = null;
        }
    }

    /// Reads what output `fd` has. True when the program is to be killed
    /// at the cap.
    fn drain(pump: *Pump, fd: i32) Error!bool {
        const is_stdout = fd == pump.child.stdout.?.handle;
        const output = if (is_stdout) &pump.stdout else &pump.stderr;
        var chunk: [read_chunk_bytes]u8 = undefined;
        const bytes_read = linux.read(fd, &chunk, chunk.len);
        switch (linux.errno(bytes_read)) {
            .SUCCESS => {},
            .AGAIN, .INTR => return false,
            else => return error.Syscall,
        }
        if (bytes_read == 0) {
            if (is_stdout) pump.stdout_open = false else pump.stderr_open = false;
            return false;
        }
        const output_bytes_max = pump.options.output_bytes_max;
        const room = output_bytes_max -| output.items.len;
        const keep = @min(bytes_read, room);
        const exceeded = bytes_read > room;
        try output.appendSlice(pump.gpa, chunk[0..keep]);
        assert(output.items.len <= output_bytes_max);
        return pump.options.at_cap == .kill and exceeded;
    }
};

/// Adds O_NONBLOCK to `fd`'s status flags, keeping the others.
fn setNonblocking(fd: i32) error{Syscall}!void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.Syscall;
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    const set_result = linux.fcntl(fd, linux.F.SETFL, flags | nonblock);
    if (linux.errno(set_result) != .SUCCESS) return error.Syscall;
}

const testing = std.testing;

/// The monotonic time `duration_ms` from now, in ns.
fn deadline(duration_ms: u64) u64 {
    return os.monotonicNs() + duration_ms * std.time.ns_per_ms;
}

test "output, exit code and stdin" {
    var result = try run(
        testing.allocator,
        testing.io,
        &.{ "sh", "-c", "echo out; echo err >&2; exit 3" },
        .{ .deadline_ns = deadline(5000) },
    );
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("out\n", result.stdout);
    try testing.expectEqualStrings("err\n", result.stderr);
    try testing.expectEqual(@as(?u8, 3), result.code);

    // More input than a pipe holds: written while the output is read.
    const big = try testing.allocator.alloc(u8, 300_000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    var counted = try run(testing.allocator, testing.io, &.{ "wc", "-c" }, .{
        .stdin = .{ .bytes = big },
        .deadline_ns = deadline(5000),
    });
    defer counted.deinit(testing.allocator);
    try testing.expectEqualStrings("300000", std.mem.trim(u8, counted.stdout, " \n"));
}

test "a program past its deadline is killed" {
    const start_ns = os.monotonicNs();
    var result = try run(testing.allocator, testing.io, &.{ "sleep", "30" }, .{
        .deadline_ns = deadline(100),
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.timed_out);
    try testing.expectEqual(@as(?u8, null), result.code);
    try testing.expect(os.monotonicNs() - start_ns < 2 * std.time.ns_per_s);
}

test "a program that closes its output but keeps running still times out" {
    const argv = &.{ "sh", "-c", "exec >&- 2>&-; sleep 30" };
    var result = try run(testing.allocator, testing.io, argv, .{ .deadline_ns = deadline(150) });
    defer result.deinit(testing.allocator);
    try testing.expect(result.timed_out);
}

test "input left once the outputs close is ended, not held until the deadline" {
    // More than a pipe holds, read only after both outputs are closed: it
    // exits on EOF, which comes only if stdin is closed after the loop.
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const argv = &.{ "sh", "-c", "exec >&- 2>&-; sleep 0.2; cat >/dev/null" };
    const start_ns = os.monotonicNs();
    var result = try run(testing.allocator, testing.io, argv, .{
        .stdin = .{ .bytes = big },
        .deadline_ns = deadline(5000),
    });
    defer result.deinit(testing.allocator);
    try testing.expect(!result.timed_out);
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(os.monotonicNs() - start_ns < 3 * std.time.ns_per_s);
}

test "limits are put on the program" {
    // Read after a pause: the limits are set right after the start.
    const argv = &.{ "sh", "-c", "sleep 0.3; cat /proc/$$/limits" };
    var result = try run(testing.allocator, testing.io, argv, .{
        .deadline_ns = deadline(5000),
        .limits = .{ .memory_bytes_max = 512 << 20, .cpu_s_max = 7 },
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), result.code);
    const address_space = std.mem.find(u8, result.stdout, "Max address space") orelse
        return error.TestUnexpectedResult;
    const line_end = std.mem.findScalarPos(u8, result.stdout, address_space, '\n') orelse
        result.stdout.len;
    try testing.expect(std.mem.find(
        u8,
        result.stdout[address_space..line_end],
        "536870912",
    ) != null);
    const cpu = std.mem.find(
        u8,
        result.stdout,
        "Max cpu time",
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, result.stdout[cpu..][0..60], " 7 ") != null);
}

test "a descriptor that cannot be made non-blocking is an error" {
    try testing.expectError(error.Syscall, setNonblocking(-1));

    var pipe: [2]i32 = undefined;
    try testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer for (pipe) |fd| os.close(fd);
    try setNonblocking(pipe[1]);
    const flags = linux.fcntl(pipe[1], linux.F.GETFL, 0);
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    try testing.expect(flags & nonblock != 0);
}

test "a missing program is an error, not a crash" {
    try testing.expectError(error.FileNotFound, run(
        testing.allocator,
        testing.io,
        &.{"lumen-no-such-program-xyz"},
        .{ .deadline_ns = deadline(1000) },
    ));
}

test "children start with SIGPIPE at its default, even after a library ignored it" {
    // What GDBus does on its first connection, after `main` installed the
    // empty handler.
    const ignore: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.PIPE, &ignore, null);
    defer os.unix.ignoreSigpipe();
    const start_ns = os.monotonicNs();
    var result = try run(testing.allocator, testing.io, &.{
        "sh",
        "-c",
        "grep '^SigIgn:' /proc/self/status; while :; do echo x; done | head -n 1",
    }, .{ .deadline_ns = deadline(3000) });
    defer result.deinit(testing.allocator);
    try testing.expect(!result.timed_out);
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(os.monotonicNs() - start_ns < 2 * std.time.ns_per_s);
    const sigign_line_end = std.mem.findScalar(u8, result.stdout, '\n') orelse result.stdout.len;
    const prefix = "SigIgn:\t";
    try testing.expect(std.mem.startsWith(u8, result.stdout[0..sigign_line_end], prefix));
    const mask_hex = std.mem.trim(u8, result.stdout[prefix.len..sigign_line_end], " \t\r");
    const sigign = try std.fmt.parseInt(u64, mask_hex, 16);
    // SIGPIPE is signal 13 -> bit 12 (0x1000).
    try testing.expectEqual(@as(u64, 0), sigign & (@as(u64, 1) << 12));
}

fn procAlive(status_path: [:0]const u8) bool {
    const fd = os.openRegular(status_path) catch return false;
    defer os.close(fd);
    var buf: [512]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return false;
    const text = buf[0..n];
    // Killed orphans stay as zombies in containers whose PID 1 does not reap.
    if (std.mem.find(u8, text, "State:\tZ") != null) return false;
    if (std.mem.find(u8, text, "State:\tX") != null) return false;
    return true;
}

test "timing out kills grandchildren in the child's process group" {
    const argv = &.{ "sh", "-c", "sleep 30 & echo $!; wait" };
    var result = try run(testing.allocator, testing.io, argv, .{ .deadline_ns = deadline(150) });
    defer result.deinit(testing.allocator);
    try testing.expect(result.timed_out);
    const pid_text = std.mem.trim(u8, result.stdout, " \t\r\n");
    try testing.expect(pid_text.len > 0);
    _ = try std.fmt.parseInt(linux.pid_t, pid_text, 10);

    var proc_buffer: [64]u8 = undefined;
    const status_path = try std.mem.printSentinel(&proc_buffer, "/proc/{s}/status", .{pid_text}, 0);
    // Wait briefly for the kernel to transition the killed grandchild out of live state.
    const wait_deadline = os.monotonicNs() + 500 * std.time.ns_per_ms;
    while (procAlive(status_path) and os.monotonicNs() < wait_deadline) {
        os.sleepUs(10_000);
    }
    try testing.expect(!procAlive(status_path));
}

test "a program that exits ends the run while what it left behind holds its outputs" {
    // `gio open`, `xdg-open`: the app started inherits stdout and stderr.
    const argv = &.{ "sh", "-c", "sleep 30 & echo $!; echo done >&2; exit 4" };
    const start_ns = os.monotonicNs();
    var result = try run(testing.allocator, testing.io, argv, .{ .deadline_ns = deadline(5000) });
    defer result.deinit(testing.allocator);
    try testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);
    try testing.expect(!result.timed_out);
    try testing.expectEqual(@as(?u8, 4), result.code);
    try testing.expectEqualStrings("done\n", result.stderr);
    const pid_text = std.mem.trim(u8, result.stdout, " \t\r\n");
    const background_pid = try std.fmt.parseInt(linux.pid_t, pid_text, 10);
    defer _ = linux.kill(background_pid, .KILL);

    // Not killed with the process group: it lives on.
    var proc_buffer: [64]u8 = undefined;
    const status_path = try std.mem.printSentinel(&proc_buffer, "/proc/{s}/status", .{pid_text}, 0);
    try testing.expect(procAlive(status_path));
}

test "reap collects a program that exited, as after a wait that failed" {
    const fork_result = linux.fork();
    try testing.expectEqual(.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) linux.exit_group(0);
    const pid: linux.pid_t = @intCast(fork_result);
    try testing.expect(os.waitExit(pid, deadline(5000)));
    reap(pid);
    try testing.expectEqual(os.ChildState.gone, os.childState(pid));
}

test "at_cap .kill kills only when output strictly exceeds output_bytes_max" {
    var exact = try run(testing.allocator, testing.io, &.{ "sh", "-c", "printf '12345'" }, .{
        .deadline_ns = deadline(5000),
        .output_bytes_max = 5,
        .at_cap = .kill,
    });
    defer exact.deinit(testing.allocator);
    try testing.expect(!exact.capped);
    try testing.expect(!exact.timed_out);
    try testing.expectEqual(@as(?u8, 0), exact.code);
    try testing.expectEqualStrings("12345", exact.stdout);

    var over = try run(testing.allocator, testing.io, &.{ "sh", "-c", "printf '123456'" }, .{
        .deadline_ns = deadline(5000),
        .output_bytes_max = 5,
        .at_cap = .kill,
    });
    defer over.deinit(testing.allocator);
    try testing.expect(over.capped);
    try testing.expectEqual(@as(?u8, null), over.code);
    try testing.expectEqualStrings("12345", over.stdout);
}

test "cancel sets cancelled=true while real deadline timeout sets cancelled=false" {
    var timeout_res = try run(testing.allocator, testing.io, &.{ "sh", "-c", "sleep 5" }, .{
        .deadline_ns = deadline(50),
    });
    defer timeout_res.deinit(testing.allocator);
    try testing.expect(timeout_res.timed_out);
    try testing.expect(!timeout_res.cancelled);

    var stop: std.atomic.Value(bool) = .init(true);
    var cancel_res = try run(testing.allocator, testing.io, &.{ "sh", "-c", "sleep 5" }, .{
        .deadline_ns = deadline(5000),
        .cancel = &stop,
    });
    defer cancel_res.deinit(testing.allocator);
    try testing.expect(cancel_res.timed_out);
    try testing.expect(cancel_res.cancelled);
}
