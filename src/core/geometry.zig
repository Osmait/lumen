//! Window layouts (halves, maximize, center...) as rectangles inside a
//! monitor's usable area. Pure math so it can be tested without Hyprland.

const std = @import("std");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

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

    /// The area windows may use, in global layout coordinates.
    pub fn usable(m: Monitor) Rect {
        var w: f64 = @floatFromInt(m.width);
        var h: f64 = @floatFromInt(m.height);
        if (@mod(m.transform, 2) == 1) std.mem.swap(f64, &w, &h);
        const lw: i32 = @intFromFloat(@round(w / m.scale));
        const lh: i32 = @intFromFloat(@round(h / m.scale));
        return .{
            .x = m.x + m.reserved[0],
            .y = m.y + m.reserved[1],
            .w = lw - m.reserved[0] - m.reserved[2],
            .h = lh - m.reserved[1] - m.reserved[3],
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

/// Where a window of size `current` (w, h) goes for `layout`, with `gap`
/// pixels kept around it.
pub fn place(layout: Layout, area: Rect, current_w: i32, current_h: i32, gap: i32) Rect {
    const a: Rect = .{
        .x = area.x + gap,
        .y = area.y + gap,
        .w = area.w - 2 * gap,
        .h = area.h - 2 * gap,
    };
    const half_w = @divTrunc(a.w - gap, 2);
    const half_h = @divTrunc(a.h - gap, 2);
    const third = @divTrunc(a.w - 2 * gap, 3);
    return switch (layout) {
        .left_half => .{ .x = a.x, .y = a.y, .w = half_w, .h = a.h },
        .right_half => .{ .x = a.x + a.w - half_w, .y = a.y, .w = half_w, .h = a.h },
        .top_half => .{ .x = a.x, .y = a.y, .w = a.w, .h = half_h },
        .bottom_half => .{ .x = a.x, .y = a.y + a.h - half_h, .w = a.w, .h = half_h },
        .maximize => a,
        .almost_maximize => shrinkCentered(a, 0.9),
        .center => blk: {
            const w = @min(current_w, a.w);
            const h = @min(current_h, a.h);
            break :blk .{
                .x = a.x + @divTrunc(a.w - w, 2),
                .y = a.y + @divTrunc(a.h - h, 2),
                .w = w,
                .h = h,
            };
        },
        .first_third => .{ .x = a.x, .y = a.y, .w = third, .h = a.h },
        .center_third => .{ .x = a.x + third + gap, .y = a.y, .w = third, .h = a.h },
        .last_third => .{ .x = a.x + a.w - third, .y = a.y, .w = third, .h = a.h },
    };
}

fn shrinkCentered(a: Rect, f: f64) Rect {
    const w: i32 = @intFromFloat(@as(f64, @floatFromInt(a.w)) * f);
    const h: i32 = @intFromFloat(@as(f64, @floatFromInt(a.h)) * f);
    return .{ .x = a.x + @divTrunc(a.w - w, 2), .y = a.y + @divTrunc(a.h - h, 2), .w = w, .h = h };
}

test "usable area honours rotation and bars" {
    // The rotated 1600x900 monitor on this machine, bar on top.
    const m: Monitor = .{
        .x = 4307,
        .y = 0,
        .width = 1600,
        .height = 900,
        .scale = 1,
        .transform = 3,
        .reserved = .{ 0, 38, 0, 0 },
    };
    const u = m.usable();
    try std.testing.expectEqual(Rect{ .x = 4307, .y = 38, .w = 900, .h = 1562 }, u);
}

test "halves split the area without overlap" {
    const area: Rect = .{ .x = 0, .y = 38, .w = 1920, .h = 1042 };
    const l = place(.left_half, area, 0, 0, 8);
    const r = place(.right_half, area, 0, 0, 8);
    try std.testing.expect(l.x + l.w <= r.x);
    try std.testing.expectEqual(l.w, r.w);
    try std.testing.expectEqual(@as(i32, 8 + 1920 - 8), r.x + r.w + 8);
}

test "center keeps size" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const c = place(.center, area, 400, 300, 0);
    try std.testing.expectEqual(Rect{ .x = 300, .y = 250, .w = 400, .h = 300 }, c);
}
