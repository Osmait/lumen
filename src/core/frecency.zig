//! Frecency: how often and how recently something was opened, folded into
//! one number. Each use counts less as it ages (half-life of a week).

const std = @import("std");
const assert = std.debug.assert;

const half_life_s: f64 = 7 * 24 * 3600;

/// The boost grows by this much each time the frecency doubles...
const boost_per_doubling = 120;
/// ...up to this, so a clearly better text match still wins.
const boost_max = 600;

/// `count` uses, the last one at `last_used` (unix seconds), seen at `now`.
pub fn value(count: u32, last_used: i64, now: i64) f64 {
    if (count == 0) return 0;
    // Saturating: `last_used` comes from the database file.
    const age_s: f64 = @floatFromInt(@max(now -| last_used, 0));
    const decay = std.math.pow(f64, 0.5, age_s / half_life_s);
    const result = @as(f64, @floatFromInt(count)) * decay;
    assert(result >= 0);
    return result;
}

/// Ranking bonus added to a fuzzy score: grows with use but saturates so a
/// clearly better text match still wins.
pub fn boost(frecency: f64) i32 {
    if (frecency <= 0) return 0;
    const result: i32 = @intFromFloat(@min(@log2(1 + frecency) * boost_per_doubling, boost_max));
    assert(result >= 0);
    assert(result <= boost_max);
    return result;
}

test "recent beats old with same count" {
    const now: i64 = 1_000_000_000;
    try std.testing.expect(value(5, now - 60, now) > value(5, now - 30 * 24 * 3600, now));
}

test "boost saturates" {
    try std.testing.expectEqual(@as(i32, boost_max), boost(1e9));
    try std.testing.expectEqual(@as(i32, 0), boost(0));
}
