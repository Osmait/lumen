//! Run a program, feed it stdin, collect its output, never wait past a
//! deadline: `lumen.exec` for extensions, and the tools text extraction
//! runs (pdftotext, unzip).

const std = @import("std");
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
    max_output_bytes: usize = 16 << 20,
    at_cap: enum { drop, kill } = .drop,
    /// Lumen's environment, or none (what a tool prints must not depend
    /// on the user's locale or settings).
    environ: enum { inherit, empty } = .inherit,
};

/// Owned by the caller: free with `deinit`.
pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    /// Exit code; null when killed by a signal, the deadline or the cap.
    code: ?u8,
    timed_out: bool,
    /// Killed at `max_output_bytes` (`at_cap = .kill`).
    capped: bool = false,

    pub fn deinit(r: *Result, gpa: std.mem.Allocator) void {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
};

pub const Error = std.process.SpawnError || std.mem.Allocator.Error || error{Syscall};

/// Runs `argv` (PATH searched, environment inherited) to completion or to
/// the deadline. The child is always reaped and its pipes closed.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    opts: Options,
) Error!Result {
    var empty_env = std.process.Environ.Map.init(gpa);
    defer empty_env.deinit();
    const stdin_bytes = switch (opts.stdin) {
        .bytes => |b| b,
        .fd => "",
    };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = if (opts.environ == .empty) &empty_env else null,
        .stdin = switch (opts.stdin) {
            .bytes => |b| if (b.len > 0) .pipe else .ignore,
            .fd => |fd| .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } },
        },
        .stdout = .pipe,
        .stderr = if (opts.stderr == .collect) .pipe else .ignore,
    });
    // `kill` sends SIGTERM and waits: after a SIGKILL it only reaps.
    defer if (child.id) |pid| {
        _ = linux.kill(pid, .KILL);
        child.kill(io);
    };

    var p: Pump = .{
        .gpa = gpa,
        .io = io,
        .child = &child,
        .opts = &opts,
        .stdin_bytes = stdin_bytes,
        .err_open = opts.stderr == .collect,
    };
    errdefer p.out.deinit(gpa);
    errdefer p.err.deinit(gpa);
    const end = try p.loop();

    // Both outputs closed, but the program may live on (it closed them, or
    // a background child holds them): wait for its exit up to the deadline.
    const timed_out = end == .timed_out or
        (end == .closed and !os.waitExit(child.id.?, opts.deadline_ns));
    var code: ?u8 = null;
    if (end == .closed and !timed_out) {
        if (child.wait(io)) |term| switch (term) {
            .exited => |x| code = x,
            else => {},
        } else |_| {}
    }
    return .{
        .stdout = try p.out.toOwnedSlice(gpa),
        .stderr = try p.err.toOwnedSlice(gpa),
        .code = code,
        .timed_out = timed_out,
        .capped = end == .capped,
    };
}

/// A running program's pipes: stdin written and both outputs read in one
/// poll loop, so a program that answers before reading all its input
/// cannot deadlock it.
const Pump = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    opts: *const Options,
    stdin_bytes: []const u8,
    written: usize = 0,
    out: std.ArrayList(u8) = .empty,
    err: std.ArrayList(u8) = .empty,
    out_open: bool = true,
    err_open: bool,

    const End = enum { closed, timed_out, capped };

    fn loop(p: *Pump) Error!End {
        if (p.child.stdin) |f| {
            const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
            _ = linux.fcntl(f.handle, linux.F.SETFL, linux.fcntl(f.handle, linux.F.GETFL, 0) | nonblock);
        }
        while (p.out_open or p.err_open) {
            const now_ns = os.monotonicNs();
            if (now_ns >= p.opts.deadline_ns) return .timed_out;
            var fds: [3]linux.pollfd = undefined;
            var n: usize = 0;
            if (p.out_open) {
                fds[n] = .{ .fd = p.child.stdout.?.handle, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            }
            if (p.err_open) {
                fds[n] = .{ .fd = p.child.stderr.?.handle, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            }
            if (p.child.stdin) |f| {
                fds[n] = .{ .fd = f.handle, .events = linux.POLL.OUT, .revents = 0 };
                n += 1;
            }
            const left_ms: i32 = @intCast(@min(
                (p.opts.deadline_ns - now_ns) / std.time.ns_per_ms + 1,
                std.math.maxInt(i32),
            ));
            switch (linux.errno(linux.poll(&fds, n, left_ms))) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.Syscall,
            }
            for (fds[0..n]) |pfd| {
                if (pfd.revents == 0) continue;
                if (pfd.events == linux.POLL.OUT) p.feed() else if (try p.drain(pfd.fd)) return .capped;
            }
        }
        return .closed;
    }

    /// Writes what stdin can take; closes it once all is written.
    fn feed(p: *Pump) void {
        const fd = p.child.stdin.?.handle;
        const rest = p.stdin_bytes[p.written..];
        const w = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(w)) {
            .SUCCESS => p.written += w,
            .AGAIN, .INTR => {},
            // The program closed its stdin: it does not want the rest.
            else => p.written = p.stdin_bytes.len,
        }
        if (p.written == p.stdin_bytes.len) {
            p.child.stdin.?.close(p.io);
            p.child.stdin = null;
        }
    }

    /// Reads what output `fd` has. True when the program is to be killed
    /// at the cap.
    fn drain(p: *Pump, fd: i32) Error!bool {
        const is_out = fd == p.child.stdout.?.handle;
        const list = if (is_out) &p.out else &p.err;
        var buf: [64 * 1024]u8 = undefined;
        const r = linux.read(fd, &buf, buf.len);
        switch (linux.errno(r)) {
            .SUCCESS => if (r == 0) {
                if (is_out) p.out_open = false else p.err_open = false;
            } else {
                const keep = @min(r, p.opts.max_output_bytes -| list.items.len);
                try list.appendSlice(p.gpa, buf[0..keep]);
                return p.opts.at_cap == .kill and list.items.len == p.opts.max_output_bytes;
            },
            .AGAIN, .INTR => {},
            else => return error.Syscall,
        }
        return false;
    }
};

const testing = std.testing;

fn deadline(ms: u64) u64 {
    return os.monotonicNs() + ms * std.time.ns_per_ms;
}

test "output, exit code and stdin" {
    var r = try run(
        testing.allocator,
        testing.io,
        &.{ "sh", "-c", "echo out; echo err >&2; exit 3" },
        .{ .deadline_ns = deadline(5000) },
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("out\n", r.stdout);
    try testing.expectEqualStrings("err\n", r.stderr);
    try testing.expectEqual(@as(?u8, 3), r.code);

    // More input than a pipe holds: written while the output is read.
    const big = try testing.allocator.alloc(u8, 300_000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    var w = try run(testing.allocator, testing.io, &.{ "wc", "-c" }, .{
        .stdin = .{ .bytes = big },
        .deadline_ns = deadline(5000),
    });
    defer w.deinit(testing.allocator);
    try testing.expectEqualStrings("300000", std.mem.trim(u8, w.stdout, " \n"));
}

test "a program past its deadline is killed" {
    const t0 = os.monotonicNs();
    var r = try run(testing.allocator, testing.io, &.{ "sleep", "30" }, .{
        .deadline_ns = deadline(100),
    });
    defer r.deinit(testing.allocator);
    try testing.expect(r.timed_out);
    try testing.expectEqual(@as(?u8, null), r.code);
    try testing.expect(os.monotonicNs() - t0 < 2 * std.time.ns_per_s);
}

test "a program that closes its output but keeps running still times out" {
    var r = try run(testing.allocator, testing.io, &.{ "sh", "-c", "exec >&- 2>&-; sleep 30" }, .{
        .deadline_ns = deadline(150),
    });
    defer r.deinit(testing.allocator);
    try testing.expect(r.timed_out);
}

test "a missing program is an error, not a crash" {
    try testing.expectError(error.FileNotFound, run(
        testing.allocator,
        testing.io,
        &.{"lumen-no-such-program-xyz"},
        .{ .deadline_ns = deadline(1000) },
    ));
}
