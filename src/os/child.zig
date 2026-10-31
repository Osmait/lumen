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
};

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
    return .{
        .stdout = try pump.stdout.toOwnedSlice(gpa),
        .stderr = try pump.stderr.toOwnedSlice(gpa),
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
    const cancel = options.cancel orelse return os.waitExit(pid, options.deadline_ns);
    while (!cancel.load(.acquire)) {
        const now_ns = os.monotonicNs();
        if (now_ns >= options.deadline_ns) return false;
        const slice_ns = cancel_poll_ms * std.time.ns_per_ms;
        const slice_end_ns = @min(options.deadline_ns, now_ns + slice_ns);
        if (os.waitExit(pid, slice_end_ns)) return true;
    }
    return false;
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
