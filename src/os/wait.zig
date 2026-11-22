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
    var poll_fds = [2]linux.pollfd{
        .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = wake orelse -1, .events = linux.POLL.IN, .revents = 0 },
    };
    const poll_fds_count: usize = if (wake == null) 1 else 2;
    const timeout_ms: i32 = if (wake == null) 100 else -1;
    const ready_count = linux.poll(&poll_fds, poll_fds_count, timeout_ms);
    if (linux.errno(ready_count) != .SUCCESS) return false;
    return ready_count > 0 and poll_fds[0].revents & linux.POLL.IN != 0;
}

/// Waits until `fd` is readable (up to `timeout_ms`; negative waits forever),
/// retrying on `EINTR` with the remaining timeout.
pub fn waitReadable(fd: i32, timeout_ms: i32) bool {
    const deadline_ns: ?u64 = if (timeout_ms > 0)
        os.monotonicNs() + @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms
    else
        null;
    while (true) {
        const left_ms: i32 = if (deadline_ns) |limit_ns| blk: {
            const now_ns = os.monotonicNs();
            if (now_ns >= limit_ns) return false;
            const left_ns = limit_ns - now_ns;
            break :blk @intCast(@min(
                (left_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms,
                std.math.maxInt(i32),
            ));
        } else timeout_ms;
        var poll_fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const ready_count = linux.poll(&poll_fds, 1, left_ms);
        switch (linux.errno(ready_count)) {
            .SUCCESS => return ready_count > 0,
            .INTR => continue,
            else => return false,
        }
    }
}

test "waitExitCancelable returns immediately when pidfd_open fails" {
    var cancel: std.atomic.Value(bool) = .init(false);
    const start_ns = os.monotonicNs();
    const ok = waitExitCancelable(-1, start_ns + 5 * std.time.ns_per_s, &cancel, 50);
    try std.testing.expect(!ok);
    try std.testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);
}
