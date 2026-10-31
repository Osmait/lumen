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
    const fd = linux.pidfd_open(pid, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer os.close(@intCast(fd));
    const left_ns = deadline_ns -| os.monotonicNs();
    const left_ms: i32 = @intCast(@min(left_ns / std.time.ns_per_ms, std.math.maxInt(i32)));
    return waitReadable(@intCast(fd), left_ms);
}

/// Waits until `fd` is readable (true) or `wake` is written (false). Without
/// `wake` (-1), it gives up every 100 ms so the caller can look around.
pub fn waitEvents(fd: i32, wake: i32) bool {
    var poll_fds = [2]linux.pollfd{
        .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = wake, .events = linux.POLL.IN, .revents = 0 },
    };
    const poll_fds_count: usize = if (wake < 0) 1 else 2;
    const timeout_ms: i32 = if (wake < 0) 100 else -1;
    const ready_count = linux.poll(&poll_fds, poll_fds_count, timeout_ms);
    if (linux.errno(ready_count) != .SUCCESS) return false;
    return ready_count > 0 and poll_fds[0].revents & linux.POLL.IN != 0;
}

pub fn waitReadable(fd: i32, timeout_ms: i32) bool {
    var poll_fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const ready_count = linux.poll(&poll_fds, 1, timeout_ms);
    return linux.errno(ready_count) == .SUCCESS and ready_count > 0;
}
