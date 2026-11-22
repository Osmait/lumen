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
    /// untrusted input (a crafted PDF), whose memory, CPU and writes must
    /// not reach the rest of the machine. Null: none.
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
    /// Killed at `output_bytes_max` (`at_cap = .kill`).
    capped: bool = false,

    pub fn deinit(result: *Result, gpa: std.mem.Allocator) void {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
};

pub const Error = std.process.SpawnError || std.mem.Allocator.Error || error{Syscall};

/// Runs `argv` (PATH searched, environment inherited) to completion or to
/// the deadline. The child is always reaped and its pipes closed.
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
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = if (options.environ == .empty) &empty_environment else null,
        .stdin = switch (options.stdin) {
            .bytes => |bytes| if (bytes.len > 0) .pipe else .ignore,
            .fd => |fd| .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } },
        },
        .stdout = .pipe,
        .stderr = if (options.stderr == .collect) .pipe else .ignore,
    });
    if (options.limits) |limits| applyLimits(child.id.?, limits);
    // `kill` sends SIGTERM and waits: after a SIGKILL it only reaps. The
    // child is not reaped yet, so the SIGKILL cannot miss it.
    defer if (child.id) |pid| {
        _ = linux.kill(pid, .KILL);
        child.kill(io);
    };

    var pump: Pump = .{
        .gpa = gpa,
        .io = io,
        .child = &child,
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

    // Both outputs closed, but the program may live on (it closed them, or
    // a background child holds them): wait for its exit up to the deadline.
    const timed_out = end == .timed_out or
        (end == .closed and !waitExit(child.id.?, &options));
    var code: ?u8 = null;
    if (end == .closed and !timed_out) {
        // A wait that fails leaves the code unknown, as a signal does; the
        // deferred kill reaps the child either way.
        if (child.wait(io)) |termination| switch (termination) {
            .exited => |exit_code| code = exit_code,
            else => {},
        } else |_| {}
    }
    const stdout = try pump.stdout.toOwnedSlice(gpa);
    errdefer gpa.free(stdout);
    const stderr = try pump.stderr.toOwnedSlice(gpa);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .code = code,
        .timed_out = timed_out,
        .capped = end == .capped,
    };
}

/// How often a run that can be cancelled looks at its `cancel` flag.
const cancel_poll_ms = 100;

/// Whether the program exited before its deadline, looked at every
/// `cancel_poll_ms` when it can be cancelled.
fn waitExit(pid: linux.pid_t, options: *const Options) bool {
    return os.waitExitCancelable(pid, options.deadline_ns, options.cancel, cancel_poll_ms);
}

/// A running program's pipes: stdin written and both outputs read in one
/// poll loop, so a program that answers before reading all its input
/// cannot deadlock it.
const Pump = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    options: *const Options,
    stdin_bytes: []const u8,
    written: usize = 0,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_open: bool = true,
    stderr_open: bool,

    const End = enum { closed, timed_out, capped };

    fn loop(pump: *Pump) Error!End {
        // A blocking stdin would let one write stall the whole poll loop,
        // deadline included: if it cannot be made non-blocking, give up.
        if (pump.child.stdin) |stdin| try setNonblocking(stdin.handle);
        while (pump.stdout_open or pump.stderr_open) {
            const now_ns = os.monotonicNs();
            if (now_ns >= pump.options.deadline_ns) return .timed_out;
            if (pump.cancelled()) return .timed_out;
            var poll_fds: [3]linux.pollfd = undefined;
            const poll_fds_count = pump.pollFds(&poll_fds);
            const ready_count = linux.poll(&poll_fds, poll_fds_count, pump.pollTimeoutMs(now_ns));
            switch (linux.errno(ready_count)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.Syscall,
            }
            for (poll_fds[0..poll_fds_count]) |poll_fd| {
                if (poll_fd.revents == 0) continue;
                if (poll_fd.events == linux.POLL.OUT) {
                    pump.feed();
                } else if (try pump.drain(poll_fd.fd)) {
                    return .capped;
                }
            }
        }
        return .closed;
    }

    fn cancelled(pump: *const Pump) bool {
        const cancel = pump.options.cancel orelse return false;
        return cancel.load(.acquire);
    }

    /// The open outputs to read and, while there is input left, stdin to
    /// write; how many were filled in.
    fn pollFds(pump: *const Pump, poll_fds: *[3]linux.pollfd) usize {
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
        assert(count > 0);
        return count;
    }

    fn pollFd(fd: i32, events: i16) linux.pollfd {
        return .{ .fd = fd, .events = events, .revents = 0 };
    }

    /// Until the deadline; in slices of `cancel_poll_ms` when the run can
    /// be cancelled, so a cancel is seen in time.
    fn pollTimeoutMs(pump: *const Pump, now_ns: u64) i32 {
        assert(now_ns < pump.options.deadline_ns);
        const left_ms = (pump.options.deadline_ns - now_ns) / std.time.ns_per_ms + 1;
        const cancellable = pump.options.cancel != null;
        const slice_ms: u64 = if (cancellable) cancel_poll_ms else std.math.maxInt(i32);
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
        const keep = @min(bytes_read, output_bytes_max -| output.items.len);
        try output.appendSlice(pump.gpa, chunk[0..keep]);
        assert(output.items.len <= output_bytes_max);
        return pump.options.at_cap == .kill and output.items.len == output_bytes_max;
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
