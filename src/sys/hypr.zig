//! Hyprland through `hyprctl -j` (read) and `hyprctl dispatch` (act).
//! Parsing and command building are pure functions over the JSON text, so
//! they are tested against recorded output (testdata/) instead of a live
//! compositor.

const std = @import("std");
const proc = @import("proc.zig");
const geometry = @import("core").geometry;

pub const Client = struct {
    address: []const u8,
    title: []const u8,
    class: []const u8,
    workspace: struct { id: i64 = 0, name: []const u8 = "" } = .{},
    at: [2]i32 = .{ 0, 0 },
    size: [2]i32 = .{ 0, 0 },
    floating: bool = false,
    fullscreen: i64 = 0,
    monitor: i64 = 0,
    focusHistoryID: i64 = 0,
    mapped: bool = true,
    hidden: bool = false,
};

pub const MonitorJson = struct {
    id: i64,
    name: []const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    scale: f64,
    transform: i32 = 0,
    reserved: [4]i32 = .{ 0, 0, 0, 0 },
    focused: bool = false,
};

/// `hyprctl -j` output as `T`, or null if it does not parse (new Hyprland
/// fields are ignored; missing optional ones take their defaults). Out of
/// memory is null too: every caller works without Hyprland's answer.
pub fn parse(comptime T: type, arena: std.mem.Allocator, json: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

fn query(arena: std.mem.Allocator, comptime T: type, what: [:0]const u8) ?T {
    const out = proc.output(&.{ "hyprctl", "-j", what }) orelse return null;
    defer proc.free(out);
    return parse(T, arena, out) orelse {
        std.log.warn("hyprctl {s}: unexpected JSON", .{what});
        return null;
    };
}

/// Most recently focused first.
pub fn sortByFocus(all: []Client) void {
    std.mem.sort(Client, all, {}, struct {
        fn lt(_: void, a: Client, b: Client) bool {
            return a.focusHistoryID < b.focusHistoryID;
        }
    }.lt);
}

/// Windows ordered by last focus, most recent first.
pub fn clients(arena: std.mem.Allocator) []Client {
    const all = query(arena, []Client, "clients") orelse return &.{};
    sortByFocus(all);
    return all;
}

pub fn activeWindow(arena: std.mem.Allocator) ?Client {
    const w = query(arena, Client, "activewindow") orelse return null;
    if (w.address.len == 0) return null;
    return w;
}

pub fn monitor(arena: std.mem.Allocator, id: i64) ?geometry.Monitor {
    return findMonitor(query(arena, []MonitorJson, "monitors") orelse return null, id);
}

pub fn findMonitor(all: []const MonitorJson, id: i64) ?geometry.Monitor {
    for (all) |m| {
        // Sizes are divided by the scale: a zero, negative or NaN one from a
        // broken reply would make the geometry meaningless.
        if (m.id == id and !(m.scale > 0 and std.math.isFinite(m.scale))) return null;
        if (m.id == id) return .{
            .x = m.x,
            .y = m.y,
            .width = m.width,
            .height = m.height,
            .scale = m.scale,
            .transform = m.transform,
            .reserved = m.reserved,
        };
    }
    return null;
}

/// Connector name of the focused monitor ("DP-1").
pub fn focusedMonitorName(arena: std.mem.Allocator) ?[]const u8 {
    return focusedName(query(arena, []MonitorJson, "monitors") orelse return null);
}

pub fn focusedName(all: []const MonitorJson) ?[]const u8 {
    for (all) |m| if (m.focused) return m.name;
    return null;
}

/// The argument of `hyprctl --batch`: "dispatch a ; dispatch b".
pub fn batchString(gpa: std.mem.Allocator, commands: []const []const u8) ![:0]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(gpa);
    for (commands, 0..) |command, i| {
        if (i > 0) try cmd.appendSlice(gpa, " ; ");
        try cmd.appendSlice(gpa, "dispatch ");
        try cmd.appendSlice(gpa, command);
    }
    return cmd.toOwnedSliceSentinel(gpa, 0);
}

pub fn batch(gpa: std.mem.Allocator, commands: []const []const u8) void {
    const z = batchString(gpa, commands) catch return;
    defer gpa.free(z);
    proc.spawn(&.{ "hyprctl", "--batch", z });
}

pub fn dispatch(gpa: std.mem.Allocator, command: []const u8) void {
    batch(gpa, &.{command});
}

/// Moves and resizes the active window for `layout`, floating it first.
pub fn applyLayout(gpa: std.mem.Allocator, layout: geometry.Layout) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const win = activeWindow(arena) orelse return;
    const mon = monitor(arena, win.monitor) orelse return;
    batch(gpa, layoutCommands(arena, win, mon, layout) catch return);
}

/// The dispatches that put `win` where `layout` says on `mon`. Pixel moves
/// need a floating window (and fullscreen windows ignore them), hence the
/// first two. `fullscreen` only acts on the active window, which `win` is.
pub fn layoutCommands(arena: std.mem.Allocator, win: Client, mon: geometry.Monitor, layout: geometry.Layout) ![]const []const u8 {
    const r = geometry.place(layout, mon.usable(), win.size[0], win.size[1], 8);
    var cmds: std.ArrayList([]const u8) = .empty;
    if (win.fullscreen != 0) try cmds.append(arena, "fullscreen 0");
    if (!win.floating) try cmds.append(arena, try std.fmt.allocPrint(arena, "setfloating address:{s}", .{win.address}));
    try cmds.append(arena, try std.fmt.allocPrint(arena, "resizewindowpixel exact {d} {d},address:{s}", .{ r.w, r.h, win.address }));
    try cmds.append(arena, try std.fmt.allocPrint(arena, "movewindowpixel exact {d} {d},address:{s}", .{ r.x, r.y, win.address }));
    return cmds.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "clients: recorded output, extra fields ignored, ordered by focus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const all = parse([]Client, arena.allocator(), @embedFile("testdata/hypr_clients.json")).?;
    try testing.expectEqual(@as(usize, 3), all.len);
    sortByFocus(all);
    try testing.expectEqualStrings("com.mitchellh.ghostty", all[0].class);
    try testing.expectEqualStrings("🔊 voice | Server - Discord", all[2].title);
    try testing.expect(!all[1].mapped); // the special-workspace one: the UI skips it
    try testing.expectEqual(@as(i64, -99), all[1].workspace.id);
}

test "monitors: rotation and scale give the usable area" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mons = parse([]MonitorJson, arena.allocator(), @embedFile("testdata/hypr_monitors.json")).?;
    try testing.expectEqualStrings("DP-1", focusedName(mons).?);
    // HDMI-A-1: 1600x900 rotated 270° -> 900x1600 logical, bar on top.
    const hdmi = findMonitor(mons, 0).?.usable();
    try testing.expectEqual(geometry.Rect{ .x = 4307, .y = 38, .w = 900, .h = 1562 }, hdmi);
    // DP-1: 1920x1080 at scale 1.25 -> 1536x864 logical.
    const dp = findMonitor(mons, 1).?.usable();
    try testing.expectEqual(geometry.Rect{ .x = 2387, .y = 38, .w = 1536, .h = 826 }, dp);
    try testing.expect(findMonitor(mons, 7) == null);
}

test "layout commands: tiled window floats first, fullscreen leaves first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mons = parse([]MonitorJson, a, @embedFile("testdata/hypr_monitors.json")).?;
    const all = parse([]Client, a, @embedFile("testdata/hypr_clients.json")).?;
    const discord = all[0]; // tiled, on DP-1
    const cmds = try layoutCommands(a, discord, findMonitor(mons, discord.monitor).?, .left_half);
    try testing.expectEqual(@as(usize, 3), cmds.len);
    try testing.expectEqualStrings("setfloating address:0x5600000000a0", cmds[0]);
    try testing.expectEqualStrings("resizewindowpixel exact 756 810,address:0x5600000000a0", cmds[1]);
    try testing.expectEqualStrings("movewindowpixel exact 2395 46,address:0x5600000000a0", cmds[2]);

    var full = all[1];
    full.fullscreen = 1;
    full.floating = true;
    const fc = try layoutCommands(a, full, findMonitor(mons, 0).?, .maximize);
    try testing.expectEqualStrings("fullscreen 0", fc[0]);
    try testing.expectEqual(@as(usize, 3), fc.len);

    const joined = try batchString(testing.allocator, cmds[0..2]);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("dispatch setfloating address:0x5600000000a0 ; dispatch resizewindowpixel exact 756 810,address:0x5600000000a0", joined);
}

test "garbage or a changed shape does not crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(parse([]Client, arena.allocator(), "not json") == null);
    try testing.expect(parse([]Client, arena.allocator(), "{\"address\": 3}") == null);
    try testing.expect(parse([]MonitorJson, arena.allocator(), "[{\"name\":\"x\"}]") == null);
}
