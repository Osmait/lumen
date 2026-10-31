//! Window layouts (halves, maximize, center...) as rectangles inside a
//! monitor's usable area. Pure math so it can be tested without Hyprland.

const std = @import("std");
const assert = std.debug.assert;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Size = struct { w: i32, h: i32 };

pub const Monitor = struct {
    x: i32,
    y: i32,
    /// Mode size in physical pixels, before rotation and scale.
    width: i32,
    height: i32,
    scale: f64,
    /// wl_output transform: odd values (90°/270°) swap width and height.
    transform: i32,
    /// Space taken by bars: left, top, right, bottom (logical pixels).
    reserved: [4]i32,

    /// Bounds no real monitor reaches, so nothing below can overflow
    /// (checked where the numbers come in: Hyprland's reply).
    pub const pixels_max = 1 << 16;
    pub const position_max = 1 << 20;
    /// Hyprland's own range for a monitor's scale.
    pub const scale_min = 0.1;
    pub const scale_max = 16;

    /// Whether the numbers are within what a real monitor reports. Checked
    /// where they come in (`hypr.findMonitor`) and asserted where they are
    /// used (`usable`).
    pub fn plausible(monitor: Monitor) bool {
        // Written so that a NaN scale fails too.
        if (!(monitor.scale >= scale_min and monitor.scale <= scale_max)) return false;
        if (!inRange(monitor.width, 1, pixels_max)) return false;
        if (!inRange(monitor.height, 1, pixels_max)) return false;
        if (@abs(monitor.x) > position_max) return false;
        if (@abs(monitor.y) > position_max) return false;
        for (monitor.reserved) |reserved| {
            if (!inRange(reserved, 0, pixels_max)) return false;
        }
        return true;
    }

    fn inRange(value: i32, min: i32, max: i32) bool {
        return value >= min and value <= max;
    }

    /// The area windows may use, in global layout coordinates.
    pub fn usable(monitor: Monitor) Rect {
        assert(plausible(monitor));
        var width: f64 = @floatFromInt(monitor.width);
        var height: f64 = @floatFromInt(monitor.height);
        if (@mod(monitor.transform, 2) == 1) std.mem.swap(f64, &width, &height);
        const logical_width: i32 = @intFromFloat(@round(width / monitor.scale));
        const logical_height: i32 = @intFromFloat(@round(height / monitor.scale));
        const reserved_left, const reserved_top, const reserved_right, const reserved_bottom =
            monitor.reserved;
        return .{
            .x = monitor.x + reserved_left,
            .y = monitor.y + reserved_top,
            .w = logical_width - reserved_left - reserved_right,
            .h = logical_height - reserved_top - reserved_bottom,
        };
    }
};

pub const Layout = enum {
    left_half,
    right_half,
    top_half,
    bottom_half,
    maximize,
    almost_maximize,
    center,
    first_third,
    center_third,
    last_third,
};

/// Where a window of size `current` goes for `layout`, with `gap_px`
/// pixels kept around it.
pub fn place(layout: Layout, outer: Rect, current: Size, gap_px: i32) Rect {
    assert(gap_px >= 0);
    const area: Rect = .{
        .x = outer.x + gap_px,
        .y = outer.y + gap_px,
        .w = outer.w - 2 * gap_px,
        .h = outer.h - 2 * gap_px,
    };
    const half_w = @divTrunc(area.w - gap_px, 2);
    const half_h = @divTrunc(area.h - gap_px, 2);
    const third = @divTrunc(area.w - 2 * gap_px, 3);
    const placed: Rect = switch (layout) {
        .left_half => .{ .x = area.x, .y = area.y, .w = half_w, .h = area.h },
        .right_half => .{ .x = area.x + area.w - half_w, .y = area.y, .w = half_w, .h = area.h },
        .top_half => .{ .x = area.x, .y = area.y, .w = area.w, .h = half_h },
        .bottom_half => .{ .x = area.x, .y = area.y + area.h - half_h, .w = area.w, .h = half_h },
        .maximize => area,
        .almost_maximize => shrinkCentered(area, 0.9),
        .center => centered(area, @min(current.w, area.w), @min(current.h, area.h)),
        .first_third => .{ .x = area.x, .y = area.y, .w = third, .h = area.h },
        .center_third => .{ .x = area.x + third + gap_px, .y = area.y, .w = third, .h = area.h },
        .last_third => .{ .x = area.x + area.w - third, .y = area.y, .w = third, .h = area.h },
    };
    // On any area with room for the gaps, the window stays inside it.
    if (third >= 0 and half_w >= 0 and half_h >= 0) assert(contains(area, placed));
    return placed;
}

/// Whether `inner` lies within `outer`, edges included.
fn contains(outer: Rect, inner: Rect) bool {
    if (inner.x < outer.x) return false;
    if (inner.y < outer.y) return false;
    if (inner.x + inner.w > outer.x + outer.w) return false;
    if (inner.y + inner.h > outer.y + outer.h) return false;
    return true;
}

fn shrinkCentered(area: Rect, factor: f64) Rect {
    const w: i32 = @intFromFloat(@as(f64, @floatFromInt(area.w)) * factor);
    const h: i32 = @intFromFloat(@as(f64, @floatFromInt(area.h)) * factor);
    return centered(area, w, h);
}

/// A rectangle of `w` by `h` in the middle of `area`.
fn centered(area: Rect, w: i32, h: i32) Rect {
    return .{
        .x = area.x + @divTrunc(area.w - w, 2),
        .y = area.y + @divTrunc(area.h - h, 2),
        .w = w,
        .h = h,
    };
}

test "usable area honours rotation and bars" {
    // The rotated 1600x900 monitor on this machine, bar on top.
    const monitor: Monitor = .{
        .x = 4307,
        .y = 0,
        .width = 1600,
        .height = 900,
        .scale = 1,
        .transform = 3,
        .reserved = .{ 0, 38, 0, 0 },
    };
    const usable = monitor.usable();
    try std.testing.expectEqual(Rect{ .x = 4307, .y = 38, .w = 900, .h = 1562 }, usable);
}

test "halves split the area without overlap" {
    const area: Rect = .{ .x = 0, .y = 38, .w = 1920, .h = 1042 };
    const left = place(.left_half, area, .{ .w = 0, .h = 0 }, 8);
    const right = place(.right_half, area, .{ .w = 0, .h = 0 }, 8);
    try std.testing.expect(left.x + left.w <= right.x);
    try std.testing.expectEqual(left.w, right.w);
    try std.testing.expectEqual(@as(i32, 8 + 1920 - 8), right.x + right.w + 8);
}

test "center keeps size" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const center = place(.center, area, .{ .w = 400, .h = 300 }, 0);
    try std.testing.expectEqual(Rect{ .x = 300, .y = 250, .w = 400, .h = 300 }, center);
}
