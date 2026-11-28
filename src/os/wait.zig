//! Waiting on descriptors with poll: until one is readable, a wake-up
//! descriptor is written, or a child exits (through its pidfd).

const std = @import("std");
const linux = std.os.linux;
const os = @import("root.zig");

const log = std.log.scoped(.os);

/// Waits for child `pid` to exit, until `deadline_ns` (monotonic): true when
/// it did (it is left to be reaped). Without a pidfd (a kernel before 5.3,
/// no free descriptor) it looks every `exit_poll_ms` instead.
pub fn waitExit(pid: linux.pid_t, deadline_ns: u64) bool {
    return waitExitCancelable(pid, deadline_ns, null, 0);
}

/// Like `waitExit`, opening `pidfd_open` once and checking `cancel` every
/// `poll_ms` ms when `cancel` is non-null. Never busy-spins: a `poll` that
/// fails gives up (false), and without a pidfd it falls back to
/// `waitExitPolling`, so a program that exited is not taken for one that
/// hung (and killed with its process group).
pub fn waitExitCancelable(
    pid: linux.pid_t,
    deadline_ns: u64,
    cancel: ?*const std.atomic.Value(bool),
    poll_ms: u64,
) bool {
    const fd = openPidfd(pid) orelse return waitExitPolling(pid, deadline_ns, cancel);
    defer os.close(fd);
    const pidfd: i32 = fd;
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

/// Whether `pidfd_open` failed once already: said in the log only once.
var pidfd_failure_logged: std.atomic.Value(bool) = .init(false);

/// A pidfd for process `pid` (readable once it exits), or null when the
/// kernel gives none: logged once, since without it waits fall back to
/// polling.
pub fn openPidfd(pid: linux.pid_t) ?i32 {
    const result = linux.pidfd_open(pid, 0);
    const errno = linux.errno(result);
    if (errno == .SUCCESS) return @intCast(result);
    // Not a process (pid <= 0, gone): nothing worth a warning.
    if (errno != .INVAL and errno != .SRCH and !pidfd_failure_logged.swap(true, .monotonic)) {
        log.warn("pidfd_open: {t}; waiting for programs by polling", .{errno});
    }
    return null;
}

/// How often `waitExitPolling` looks whether the child exited.
const exit_poll_ms = 10;

/// What `childState` found.
pub const ChildState = enum {
    running,
    /// Exited (or killed), left to be reaped.
    exited,
    /// Not a child of this process, or reaped already.
    gone,
};

/// Whether child `pid` has exited, without reaping it (WNOWAIT) and
/// without waiting.
pub fn childState(pid: linux.pid_t) ChildState {
    var info: linux.siginfo_t = undefined;
    @memset(std.mem.asBytes(&info), 0);
    const flags = linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT;
    while (true) {
        const result = linux.waitid(.PID, pid, &info, flags, null);
        switch (linux.errno(result)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return .gone,
        }
    }
    // With WNOHANG and nothing to report, the kernel leaves the pid zero.
    return if (info.fields.common.first.piduid.pid == 0) .running else .exited;
}

/// `waitExitCancelable` without a pidfd: looks every `exit_poll_ms` whether
/// child `pid` exited, until `deadline_ns` or `cancel`. True when it did (it
/// is left to be reaped).
pub fn waitExitPolling(
    pid: linux.pid_t,
    deadline_ns: u64,
    cancel: ?*const std.atomic.Value(bool),
) bool {
    while (true) {
        switch (childState(pid)) {
            .exited => return true,
            .gone => return false,
            .running => {},
        }
        if (cancel) |flag| if (flag.load(.acquire)) return false;
        const now_ns = os.monotonicNs();
        if (now_ns >= deadline_ns) return false;
        const left_us = (deadline_ns - now_ns + std.time.ns_per_us - 1) / std.time.ns_per_us;
        os.sleepUs(@min(left_us, exit_poll_ms * std.time.us_per_ms));
    }
}

pub const EventWait = enum { ready, woken, mounts_changed, timed_out, failed };

/// Waits until `fd` is readable (`.ready`) or `wake` is written (`.woken`).
/// Without `wake`, gives up every 100 ms so the caller can look around.
pub fn waitEvents(fd: i32, wake: ?i32) EventWait {
    return waitEventsTimeout(fd, wake, -1);
}

/// Like `waitEvents`, but waits at most `timeout_ms` ms when `timeout_ms >= 0`.
pub fn waitEventsTimeout(fd: i32, wake: ?i32, timeout_ms: i32) EventWait {
    return waitServiceEvents(fd, wake, null, timeout_ms);
}

/// Like `waitEventsTimeout`, also watching `mountinfo` for `POLLPRI` changes
/// (`/proc/self/mountinfo` signals mount table updates via exceptional events).
pub fn waitServiceEvents(fd: i32, wake: ?i32, mountinfo: ?i32, timeout_ms: i32) EventWait {
    if (fd < 0) return .failed;
    const effective_timeout_ms: i32 = if (wake == null)
        (if (timeout_ms >= 0 and timeout_ms < 100) timeout_ms else 100)
    else
        timeout_ms;
    const deadline_ns: ?u64 = if (effective_timeout_ms >= 0)
        os.monotonicNs() + @as(u64, @intCast(effective_timeout_ms)) * std.time.ns_per_ms
    else
        null;
    var poll_fds: [3]linux.pollfd = undefined;
    poll_fds[0] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    var poll_fds_count: usize = 1;
    const wake_slot: ?usize = if (wake) |wake_fd| blk: {
        const idx = poll_fds_count;
        poll_fds[idx] = .{ .fd = wake_fd, .events = linux.POLL.IN, .revents = 0 };
        poll_fds_count += 1;
        break :blk idx;
    } else null;
    const mount_slot: ?usize = if (mountinfo) |mount_fd| blk: {
        const idx = poll_fds_count;
        poll_fds[idx] = .{ .fd = mount_fd, .events = linux.POLL.PRI, .revents = 0 };
        poll_fds_count += 1;
        break :blk idx;
    } else null;
    while (true) {
        const remaining_ms: i32 = if (deadline_ns) |limit| blk: {
            if (effective_timeout_ms == 0) break :blk 0;
            const now_ns = os.monotonicNs();
            if (now_ns >= limit) return .timed_out;
            const left_ms = (limit - now_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
            break :blk @intCast(@min(left_ms, std.math.maxInt(i32)));
        } else -1;
        for (poll_fds[0..poll_fds_count]) |*pfd| pfd.revents = 0;
        const ready_count = linux.poll(&poll_fds, poll_fds_count, remaining_ms);
        switch (linux.errno(ready_count)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .failed,
        }
        if (ready_count == 0) return .timed_out;
        if (poll_fds[0].revents & linux.POLL.NVAL != 0) return .failed;
        if (wake_slot) |slot| {
            if (poll_fds[slot].revents & linux.POLL.NVAL != 0) return .failed;
            if (poll_fds[slot].revents & linux.POLL.IN != 0) return .woken;
        }
        if (mount_slot) |slot| {
            if (poll_fds[slot].revents & (linux.POLL.PRI | linux.POLL.ERR) != 0) {
                return .mounts_changed;
            }
        }
        if (poll_fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP) != 0 and
            poll_fds[0].revents & linux.POLL.IN == 0)
        {
            return .failed;
        }
        if (poll_fds[0].revents & linux.POLL.IN != 0) return .ready;
        return .failed;
    }
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

test "waitExitCancelable returns at once for a pid that is not a child" {
    var cancel: std.atomic.Value(bool) = .init(false);
    const start_ns = os.monotonicNs();
    const ok = waitExitCancelable(-1, start_ns + 5 * std.time.ns_per_s, &cancel, 50);
    try std.testing.expect(!ok);
    try std.testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);
}

test "without a pidfd, a child that exits is still seen to exit" {
    const fork_result = linux.fork();
    try std.testing.expectEqual(.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        os.sleepUs(50 * std.time.us_per_ms);
        linux.exit_group(0);
    }
    const pid: linux.pid_t = @intCast(fork_result);
    try std.testing.expectEqual(ChildState.running, childState(pid));
    const start_ns = os.monotonicNs();
    try std.testing.expect(waitExitPolling(pid, start_ns + 5 * std.time.ns_per_s, null));
    try std.testing.expect(os.monotonicNs() - start_ns < 2 * std.time.ns_per_s);
    // Left to be reaped: seen exited again, then reaped once.
    try std.testing.expectEqual(ChildState.exited, childState(pid));
    var status: i32 = 0;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.wait4(pid, &status, 0, null)));
    try std.testing.expectEqual(ChildState.gone, childState(pid));
    try std.testing.expect(!waitExitPolling(pid, os.monotonicNs() + std.time.ns_per_s, null));
}

test "waitEventsTimeout distinguishes ready, woken, timed_out and POLLNVAL" {
    try std.testing.expectEqual(EventWait.failed, waitEventsTimeout(-1, null, 0));

    var event_pipe: [2]i32 = undefined;
    var wake_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&event_pipe, .{ .CLOEXEC = true })));
    defer for (event_pipe) |p| os.close(p);
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&wake_pipe, .{ .CLOEXEC = true })));
    defer for (wake_pipe) |p| os.close(p);

    try std.testing.expectEqual(EventWait.timed_out, waitEventsTimeout(event_pipe[0], wake_pipe[0], 0));

    var one: [1]u8 = .{'w'};
    _ = linux.write(wake_pipe[1], &one, 1);
    try std.testing.expectEqual(EventWait.woken, waitEventsTimeout(event_pipe[0], wake_pipe[0], 100));

    var drain: [1]u8 = undefined;
    _ = linux.read(wake_pipe[0], &drain, 1);
    _ = linux.write(event_pipe[1], &one, 1);
    try std.testing.expectEqual(EventWait.ready, waitEventsTimeout(event_pipe[0], wake_pipe[0], 100));

    // A closed positive fd yields POLLNVAL -> .failed.
    var bad_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.pipe2(&bad_pipe, .{ .CLOEXEC = true })));
    const closed_fd = bad_pipe[0];
    os.close(closed_fd);
    os.close(bad_pipe[1]);
    try std.testing.expectEqual(EventWait.failed, waitEventsTimeout(closed_fd, null, 0));

    // Drain `event_pipe` and verify polling /proc/self/mountinfo with POLLPRI
    // does not spuriously wake when mountinfo has not changed.
    _ = linux.read(event_pipe[0], &drain, 1);
    const mountinfo_res = linux.open("/proc/self/mountinfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(mountinfo_res) == .SUCCESS) {
        const mountinfo_fd: i32 = @intCast(mountinfo_res);
        defer os.close(mountinfo_fd);
        try std.testing.expectEqual(
            EventWait.timed_out,
            waitServiceEvents(event_pipe[0], wake_pipe[0], mountinfo_fd, 0),
        );
    }
}
