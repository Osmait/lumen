//! Frecency: how often and how recently something was opened, folded into
//! one number. Each use counts less as it ages (half-life of a week).

const std = @import("std");
const assert = std.debug.assert;

const half_life_s: f64 = 7 * 24 * 3600;

/// The boost grows by this much each time the frecency doubles...
const boost_per_doubling = 120;
/// ...up to this, so a clearly better text match still wins.
const boost_max = 600;

/// `score` accumulated up to `last_used` (unix seconds), decayed to `now`.
pub fn value(score: f64, last_used: i64, now: i64) f64 {
    if (!(score > 0) or !std.math.isFinite(score)) return 0;
    // Saturating: `last_used` comes from the database file.
    const age_s: f64 = @floatFromInt(@max(now -| last_used, 0));
    const decay = std.math.pow(f64, 0.5, age_s / half_life_s);
    const result = score * decay;
    assert(result >= 0);
    return result;
}

/// Decays `score` from `last_used` to `now`, then adds one use. Each prior
/// use keeps its own age rather than being resurrected by a newer one.
pub fn addUse(score: f64, last_used: i64, now: i64) f64 {
    return value(score, last_used, now) + 1.0;
}

/// Ranking bonus added to a fuzzy score: grows with use but saturates so a
/// clearly better text match still wins.
pub fn boost(frecency: f64) i32 {
    // Written so that NaN gets nothing: `NaN <= 0` is false, and it got
    // the most.
    if (!(frecency > 0)) return 0;
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

test "a NaN frecency gets no boost, not the most" {
    try std.testing.expectEqual(@as(i32, 0), boost(std.math.nan(f64)));
    try std.testing.expectEqual(@as(i32, 0), boost(-1));
    try std.testing.expect(boost(10) > 0);
}

test "one new use does not resurrect old uses" {
    const day = 86_400;
    const now: i64 = 1_000_000_000;
    // 200 uses a year ago, then one use today: the old history decayed to ~0.
    const old_then_one = addUse(200.0, now - 365 * day, now);
    try std.testing.expect(old_then_one < 1.0001);
    try std.testing.expect(old_then_one >= 1.0);
    // 20 uses a couple of days ago easily outrank it.
    const recent = value(20.0, now - 2 * day, now);
    try std.testing.expect(boost(recent) > boost(old_then_one));
}
