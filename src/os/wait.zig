//! Waiting on descriptors with poll: until one is readable, a wake-up
//! descriptor is written, or a child exits (through its pidfd).

const std = @import("std");
const linux = std.os.linux;
const os = @import("root.zig");

/// Waits for child `pid` to exit, until `deadline_ns` (monotonic): true when
/// it did (it is left to be reaped). Without a pidfd (old kernel, no free
/// descriptor) it does not wait: false, so the caller kills it, and
/// reaping a killed child cannot hang.
pub fn waitExit(pid: linux.pid_t, deadline_ns: u64) bool {
    return waitExitCancelable(pid, deadline_ns, null, 0);
}

/// Like `waitExit`, opening `pidfd_open` once and checking `cancel` every
/// `poll_ms` ms when `cancel` is non-null. Returns false immediately if
/// `pidfd_open` fails or `poll` errors, never busy-spinning.
pub fn waitExitCancelable(
    pid: linux.pid_t,
    deadline_ns: u64,
    cancel: ?*const std.atomic.Value(bool),
    poll_ms: u64,
) bool {
    const fd = linux.pidfd_open(pid, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer os.close(@intCast(fd));
    const pidfd: i32 = @intCast(fd);
    while (true) {
        if (cancel) |flag| if (flag.load(.acquire)) return false;
        const now_ns = os.monotonicNs();
        if (now_ns >= deadline_ns) return false;
        const left_ns = deadline_ns - now_ns;
        const slice_ns = if (cancel != null and poll_ms > 0)
            @min(left_ns, poll_ms * std.time.ns_per_ms)
        else
            left_ns;
        const slice_ms: i32 = @intCast(@min(
            (slice_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
            std.math.maxInt(i32),
        ));
        var poll_fds = [1]linux.pollfd{.{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 }};
        const ready_count = linux.poll(&poll_fds, 1, slice_ms);
        switch (linux.errno(ready_count)) {
            .SUCCESS => {
                if (ready_count > 0) return true;
                if (cancel == null) return false;
            },
            .INTR => continue,
            else => return false,
        }
    }
}

/// Waits until `fd` is readable (true) or `wake` is written (false). Without
/// `wake`, it gives up every 100 ms so the caller can look around.
pub fn waitEvents(fd: i32, wake: ?i32) bool {
    return waitEventsTimeout(fd, wake, -1);
}

/// Like `waitEvents`, but waits at most `timeout_ms` ms when `timeout_ms >= 0`.
pub fn waitEventsTimeout(fd: i32, wake: ?i32, timeout_ms: i32) bool {
    var poll_fds = [2]linux.pollfd{
        .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = wake orelse -1, .events = linux.POLL.IN, .revents = 0 },
    };
    const poll_fds_count: usize = if (wake == null) 1 else 2;
    const effective_timeout_ms: i32 = if (wake == null)
        (if (timeout_ms >= 0 and timeout_ms < 100) timeout_ms else 100)
    else
        timeout_ms;
    const ready_count = linux.poll(&poll_fds, poll_fds_count, effective_timeout_ms);
    if (linux.errno(ready_count) != .SUCCESS) return false;
    return ready_count > 0 and poll_fds[0].revents & linux.POLL.IN != 0;
}

/// No deadline: `pollUntil` waits as long as it takes.
pub const deadline_ns_none: u64 = std.math.maxInt(u64);

pub const Readiness = enum {
    ready,
    timed_out,
    /// poll refused `fd` (closed, invalid: POLLNVAL) or failed: waiting
    /// again would fail again.
    failed,
};

/// Polls `fd` for `events` until it has one or `deadline_ns` (monotonic;
/// `deadline_ns_none`: no limit) passes, retrying signals with the time
/// left. The one place Lumen waits on a single descriptor: the copies it
/// replaced rounded the time left each their own way, and one spun on a
/// descriptor poll refused.
pub fn pollUntil(fd: i32, events: i16, deadline_ns: u64) Readiness {
    while (true) {
        const timeout_ms: i32 = if (deadline_ns == deadline_ns_none) -1 else blk: {
            const now_ns = os.monotonicNs();
            if (now_ns >= deadline_ns) break :blk 0;
            // Rounded up: a deadline 0.4 ms away is waited for, not spun on.
            const left_ms = (deadline_ns - now_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
            break :blk @intCast(@min(left_ms, std.math.maxInt(i32)));
        };
        var poll_fds = [1]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const ready_count = linux.poll(&poll_fds, 1, timeout_ms);
        switch (linux.errno(ready_count)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .failed,
        }
        if (ready_count == 0) {
            if (timeout_ms == 0 or os.monotonicNs() >= deadline_ns) return .timed_out;
            continue;
        }
        if (poll_fds[0].revents & linux.POLL.NVAL != 0) return .failed;
        return .ready;
    }
}

/// Waits until `fd` is readable (up to `timeout_ms`; negative waits forever,
/// 0 only looks).
pub fn waitReadable(fd: i32, timeout_ms: i32) bool {
    const deadline_ns = if (timeout_ms < 0)
        deadline_ns_none
    else
        os.monotonicNs() + @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
    return pollUntil(fd, linux.POLL.IN, deadline_ns) == .ready;
}

test "waitExitCancelable returns immediately when pidfd_open fails" {
    var cancel: std.atomic.Value(bool) = .init(false);
    const start_ns = os.monotonicNs();
    const ok = waitExitCancelable(-1, start_ns + 5 * std.time.ns_per_s, &cancel, 50);
    try std.testing.expect(!ok);
    try std.testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);
}
