//! How much a recent edit lifts a match. The name search (search.zig) and
//! the content search (content.zig) rank by the same table, so a file
//! edited today outranks the same match edited last year by the same
//! amount in both.

const std = @import("std");
const assert = std.debug.assert;

/// The bonus of a file edited today (or in the future: clocks disagree).
/// It bounds how many results need a `stat` in the name search.
pub const bonus_max = 300;

/// The first day of an age band, and the bonus from that day on.
const Band = struct { age_days_min: i64, bonus: i32 };

/// Coarse on purpose: today, this week, this month, this half-year, this
/// year, older.
const bands = [_]Band{
    .{ .age_days_min = 1, .bonus = 220 },
    .{ .age_days_min = 7, .bonus = 140 },
    .{ .age_days_min = 30, .bonus = 60 },
    .{ .age_days_min = 180, .bonus = 20 },
    .{ .age_days_min = 365, .bonus = 0 },
};

comptime {
    // Older never earns more, and the last band is no bonus at all.
    var previous: Band = .{ .age_days_min = 0, .bonus = bonus_max };
    for (bands) |band| {
        assert(band.age_days_min > previous.age_days_min);
        assert(band.bonus < previous.bonus);
        previous = band;
    }
    assert(bands[bands.len - 1].bonus == 0);
}

/// The bonus for a file last edited `age_s` seconds ago. A negative age (an
/// mtime in the future) counts as today. Whole days, rounded down.
pub fn bonus(age_s: i64) i32 {
    const age_days = @divFloor(age_s, std.time.s_per_day);
    if (age_days < bands[0].age_days_min) return bonus_max;
    var result: i32 = bonus_max;
    for (bands) |band| {
        if (age_days < band.age_days_min) break;
        result = band.bonus;
    }
    assert(result >= 0);
    assert(result <= bonus_max);
    return result;
}

test "recency bands" {
    const day = std.time.s_per_day;
    try std.testing.expectEqual(bonus_max, bonus(-5 * day));
    try std.testing.expectEqual(bonus_max, bonus(0));
    try std.testing.expectEqual(bonus_max, bonus(day - 1));
    try std.testing.expectEqual(220, bonus(day));
    try std.testing.expectEqual(220, bonus(6 * day));
    try std.testing.expectEqual(140, bonus(7 * day));
    try std.testing.expectEqual(140, bonus(29 * day));
    try std.testing.expectEqual(60, bonus(30 * day));
    try std.testing.expectEqual(60, bonus(179 * day));
    try std.testing.expectEqual(20, bonus(180 * day));
    try std.testing.expectEqual(20, bonus(364 * day));
    try std.testing.expectEqual(0, bonus(365 * day));
    try std.testing.expectEqual(0, bonus(std.math.maxInt(i64)));
}
