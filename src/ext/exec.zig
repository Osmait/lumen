//! `lumen.exec`: run a program, feed it stdin, collect its output, never
//! wait past a deadline. Runs on the extension thread.

const std = @import("std");
const linux = std.os.linux;
const index = @import("index");

pub const Options = struct {
    stdin: []const u8 = "",
    /// Monotonic ns: past it the program is killed.
    deadline_ns: u64,
    /// Output beyond this (per stream) is dropped; the program keeps running.
    max_output: usize = 16 << 20,
};

/// Owned by the caller: free with `deinit`.
pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    /// Exit code; null when killed by a signal or the deadline.
    code: ?u8,
    timed_out: bool,

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
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (opts.stdin.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // `kill` sends SIGTERM and waits: after a SIGKILL it only reaps.
    defer if (child.id) |pid| {
        _ = linux.kill(pid, .KILL);
        child.kill(io);
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var err: std.ArrayList(u8) = .empty;
    errdefer err.deinit(gpa);

    // Writing stdin and reading both outputs in one poll loop: a program
    // that answers before reading all its input cannot deadlock us.
    var stdin_fd: i32 = -1;
    if (child.stdin) |f| {
        stdin_fd = f.handle;
        const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
        _ = linux.fcntl(
            stdin_fd,
            linux.F.SETFL,
            linux.fcntl(stdin_fd, linux.F.GETFL, 0) | nonblock,
        );
    }
    var written: usize = 0;
    var out_open = true;
    var err_open = true;
    var timed_out = false;
    while (out_open or err_open) {
        const now = index.sys.monotonicNs();
        if (now >= opts.deadline_ns) {
            timed_out = true;
            break;
        }
        var fds: [3]linux.pollfd = undefined;
        var n: usize = 0;
        if (out_open) {
            fds[n] = .{ .fd = child.stdout.?.handle, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (err_open) {
            fds[n] = .{ .fd = child.stderr.?.handle, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (stdin_fd >= 0) {
            fds[n] = .{ .fd = stdin_fd, .events = linux.POLL.OUT, .revents = 0 };
            n += 1;
        }
        const left_ms: i32 = @intCast(@min(
            (opts.deadline_ns - now) / std.time.ns_per_ms + 1,
            std.math.maxInt(i32),
        ));
        const rc = linux.poll(&fds, n, left_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Syscall,
        }
        for (fds[0..n]) |p| {
            if (p.revents == 0) continue;
            if (p.fd == stdin_fd) {
                const rest = opts.stdin[written..];
                const w = linux.write(stdin_fd, rest.ptr, rest.len);
                switch (linux.errno(w)) {
                    .SUCCESS => written += w,
                    .AGAIN, .INTR => {},
                    // The program closed its stdin: it does not want the rest.
                    else => written = opts.stdin.len,
                }
                if (written == opts.stdin.len) {
                    child.stdin.?.close(io);
                    child.stdin = null;
                    stdin_fd = -1;
                }
                continue;
            }
            const is_out = child.stdout != null and p.fd == child.stdout.?.handle;
            const list = if (is_out) &out else &err;
            var buf: [64 * 1024]u8 = undefined;
            const r = linux.read(p.fd, &buf, buf.len);
            switch (linux.errno(r)) {
                .SUCCESS => if (r == 0) {
                    if (is_out) out_open = false else err_open = false;
                } else {
                    const keep = @min(r, opts.max_output -| list.items.len);
                    try list.appendSlice(gpa, buf[0..keep]);
                },
                .AGAIN, .INTR => {},
                else => return error.Syscall,
            }
        }
    }

    // Both outputs closed, but the program may live on (it closed them, or
    // a background child holds them): wait for its exit up to the deadline.
    if (!timed_out and !index.sys.waitExit(child.id.?, opts.deadline_ns)) timed_out = true;
    var code: ?u8 = null;
    if (!timed_out) {
        if (child.wait(io)) |term| switch (term) {
            .exited => |x| code = x,
            else => {},
        } else |_| {}
    }
    return .{
        .stdout = try out.toOwnedSlice(gpa),
        .stderr = try err.toOwnedSlice(gpa),
        .code = code,
        .timed_out = timed_out,
    };
}

const testing = std.testing;

fn deadline(ms: u64) u64 {
    return index.sys.monotonicNs() + ms * std.time.ns_per_ms;
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
        .stdin = big,
        .deadline_ns = deadline(5000),
    });
    defer w.deinit(testing.allocator);
    try testing.expectEqualStrings("300000", std.mem.trim(u8, w.stdout, " \n"));
}

test "a program past its deadline is killed" {
    const t0 = index.sys.monotonicNs();
    var r = try run(testing.allocator, testing.io, &.{ "sleep", "30" }, .{
        .deadline_ns = deadline(100),
    });
    defer r.deinit(testing.allocator);
    try testing.expect(r.timed_out);
    try testing.expectEqual(@as(?u8, null), r.code);
    try testing.expect(index.sys.monotonicNs() - t0 < 2 * std.time.ns_per_s);
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
