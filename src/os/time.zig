//! Clocks and sleeping. The monotonic clock, in ns, is what deadlines
//! across Lumen are measured in.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub fn nowSeconds() i64 {
    var now: linux.timespec = undefined;
    // These clocks exist on every Linux Lumen runs on: a failure is a bug.
    assert(linux.errno(linux.clock_gettime(.REALTIME, &now)) == .SUCCESS);
    return now.sec;
}

pub fn monotonicNs() u64 {
    var now: linux.timespec = undefined;
    assert(linux.errno(linux.clock_gettime(.MONOTONIC, &now)) == .SUCCESS);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// Sleeps `duration_us` microseconds. A signal may cut it short, the one
/// way nanosleep fails here, so its result is not needed.
pub fn sleepUs(duration_us: u64) void {
    const duration: linux.timespec = .{
        .sec = @intCast(duration_us / std.time.us_per_s),
        .nsec = @intCast((duration_us % std.time.us_per_s) * std.time.ns_per_us),
    };
    _ = linux.nanosleep(&duration, null);
}
