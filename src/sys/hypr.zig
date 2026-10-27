//! Hyprland through its request socket (read; `hyprctl -j` if it cannot be
//! reached) and `hyprctl dispatch` (act).
//! Parsing and command building are pure functions over the JSON text, so
//! they are tested against recorded output (testdata/) instead of a live
//! compositor.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const proc = @import("proc.zig");
const geometry = @import("core").geometry;

const log = std.log.scoped(.hypr);

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
    const json = request(arena, what) orelse blk: {
        const out = proc.output(&.{ "hyprctl", "-j", what }) orelse return null;
        defer proc.free(out);
        break :blk arena.dupe(u8, out) catch return null;
    };
    return parse(T, arena, json) orelse {
        log.warn("hyprctl {s}: unexpected JSON", .{what});
        return null;
    };
}

/// What `hyprctl -j <what>` prints, straight from Hyprland's socket: every
/// show asks for the focused monitor, and starting hyprctl for it took ~4 ms
/// against 0.04. Null when the socket cannot be reached.
fn request(arena: std.mem.Allocator, what: []const u8) ?[]const u8 {
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "j/{s}", .{what}) catch return null;
    return talk(arena, msg);
}

/// Connects to one of Hyprland's sockets (".socket.sock" for requests,
/// ".socket2.sock" for events); null without Hyprland.
fn connect(which: []const u8, flags: u32) ?linux.fd_t {
    const sig = std.mem.span(c.g_getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return null);
    const rt = std.mem.span(c.g_getenv("XDG_RUNTIME_DIR") orelse return null);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = std.fmt.bufPrint(addr.path[0 .. addr.path.len - 1], "{s}/hypr/{s}/{s}", .{ rt, sig, which }) catch return null;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | flags, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// Sends `msg` to the request socket and reads the whole answer.
fn talk(arena: std.mem.Allocator, msg: []const u8) ?[]const u8 {
    const fd = connect(".socket.sock", 0) orelse return null;
    defer _ = linux.close(fd);
    // A compositor that does not answer must not freeze the window.
    const timeout: linux.timeval = .{ .sec = 1, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&timeout), @sizeOf(linux.timeval));
    if (linux.errno(linux.write(fd, msg.ptr, msg.len)) != .SUCCESS) return null;
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        out.ensureUnusedCapacity(arena, 16 * 1024) catch return null;
        const n = linux.read(fd, out.unusedCapacitySlice().ptr, out.unusedCapacitySlice().len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return null;
        if (n == 0) break;
        out.items.len += n;
    }
    return if (out.items.len > 0) out.items else null;
}

/// Most recently focused first.
pub fn sortByFocus(all: []Client) void {
    std.mem.sort(Client, all, {}, struct {
        fn lt(_: void, a: Client, b: Client) bool {
            return a.focusHistoryID < b.focusHistoryID;
        }
    }.lt);
}

/// Windows ordered by last focus, most recent first; they live in `arena`.
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

/// The argument of `hyprctl --batch`: "dispatch a ; dispatch b". Caller owns
/// it.
pub fn batchString(gpa: std.mem.Allocator, commands: []const []const u8) std.mem.Allocator.Error![:0]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(gpa);
    for (commands, 0..) |command, i| {
        if (i > 0) try cmd.appendSlice(gpa, " ; ");
        try cmd.appendSlice(gpa, "dispatch ");
        try cmd.appendSlice(gpa, command);
    }
    return cmd.toOwnedSliceSentinel(gpa, 0);
}

/// Dispatches waiting for the window to hide: sent before Hyprland gave the
/// focus back from Lumen's layer, a `focuswindow` is undone by that (seen:
/// the focus stayed put). Sent once the focus is back (`sendAfterHide`).
/// Starting hyprctl for them took ~4 ms; the socket, ~0.05.
var queued_buf: [8192]u8 = undefined;
var queued_len: usize = 0;
var queued_idle: c_uint = 0;

pub fn batch(gpa: std.mem.Allocator, commands: []const []const u8) void {
    var w: std.Io.Writer = .fixed(queued_buf[queued_len..]);
    const ok = blk: {
        for (commands) |command| {
            w.writeAll(if (queued_len + w.end == 0) "[[BATCH]]dispatch " else ";dispatch ") catch break :blk false;
            w.writeAll(command) catch break :blk false;
        }
        break :blk true;
    };
    if (!ok) {
        // Too long to queue: the old way.
        const z = batchString(gpa, commands) catch return;
        defer gpa.free(z);
        proc.spawn(&.{ "hyprctl", "--batch", z });
        return;
    }
    queued_len += w.end;
    // Not every action hides the window.
    if (queued_idle == 0) queued_idle = c.g_idle_add(&sendQueuedIdle, null);
}

fn sendQueuedIdle(_: ?*anyopaque) callconv(.c) c.gboolean {
    queued_idle = 0;
    sendQueued();
    return 0;
}

/// Before the window hides: queued dispatches go once Hyprland has given
/// the focus back (or after 60 ms). Listening starts now, so the event that
/// the hide causes is not missed.
pub fn sendAfterHide() void {
    if (queued_len == 0) return;
    if (queued_idle != 0) _ = c.g_source_remove(queued_idle);
    queued_idle = 0;
    afterFocusChange(&sendQueued, 60);
}

/// Sends what `batch` queued; hyprctl if the socket cannot be reached.
pub fn sendQueued() void {
    if (queued_len == 0) return;
    const msg = queued_buf[0..queued_len];
    queued_len = 0;
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    if (talk(fba.allocator(), msg) != null) return;
    // "[[BATCH]]dispatch a;dispatch b" is what `hyprctl --batch` sends.
    var zbuf: [8192]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{msg["[[BATCH]]".len..]}, 0) catch return;
    proc.spawn(&.{ "hyprctl", "--batch", z });
}

/// Calls `cb` once Hyprland gives a window the focus (`activewindow` on its
/// event socket), else after `fallback_ms`: a paste right after Lumen hides
/// waited a fixed 120 ms, and the focus is back in ~2.
pub fn afterFocusChange(cb: *const fn () void, fallback_ms: c_uint) void {
    for (focus_cbs[0..n_focus_cbs]) |x| if (x == cb) return;
    if (n_focus_cbs == focus_cbs.len) return cb();
    focus_cbs[n_focus_cbs] = cb;
    n_focus_cbs += 1;
    if (events_timer != 0) return; // already waiting: one event serves all
    events_len = 0;
    if (connect(".socket2.sock", linux.SOCK.NONBLOCK)) |fd| {
        events_fd = fd;
        events_watch = c.g_unix_fd_add(fd, c.G_IO_IN, &onEvents, null);
    }
    events_timer = c.g_timeout_add(fallback_ms, &onFallback, null);
}

var focus_cbs: [4]*const fn () void = undefined;
var n_focus_cbs: usize = 0;
var events_fd: linux.fd_t = -1;
var events_watch: c_uint = 0;
var events_timer: c_uint = 0;
var events_buf: [4096]u8 = undefined;
var events_len: usize = 0;

fn stopWaiting() void {
    if (events_watch != 0) _ = c.g_source_remove(events_watch);
    if (events_timer != 0) _ = c.g_source_remove(events_timer);
    if (events_fd >= 0) _ = linux.close(events_fd);
    events_watch = 0;
    events_timer = 0;
    events_fd = -1;
}

fn fire() void {
    stopWaiting();
    const cbs = focus_cbs;
    const n = n_focus_cbs;
    n_focus_cbs = 0;
    for (cbs[0..n]) |cb| cb();
}

fn onFallback(_: ?*anyopaque) callconv(.c) c.gboolean {
    events_timer = 0;
    fire();
    return 0;
}

fn onEvents(fd: c_int, _: c_uint, _: ?*anyopaque) callconv(.c) c.gboolean {
    while (true) {
        if (events_len == events_buf.len) events_len = 0;
        const n = linux.read(fd, events_buf[events_len..].ptr, events_buf.len - events_len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        events_len += n;
    }
    if (focusEvent(events_buf[0..events_len])) {
        // fire() removes this source: say so instead of removing it twice.
        events_watch = 0;
        fire();
        return 0;
    }
    return 1;
}

/// Whether Hyprland's event text holds a focus change.
fn focusEvent(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "activewindow>>")) return true;
    return false;
}

test "a focus change among Hyprland's events" {
    try std.testing.expect(focusEvent("closelayer>>lumen\nactivewindow>>kitty,~\n"));
    try std.testing.expect(!focusEvent("closelayer>>lumen\nactivewindowv2>>5619ce\n"));
    try std.testing.expect(!focusEvent("openlayer>>lumen\n"));
}

pub fn dispatch(gpa: std.mem.Allocator, command: []const u8) void {
    batch(gpa, &.{command});
}

/// Moves and resizes the active window for `layout`, floating it first.
pub fn applyLayout(gpa: std.mem.Allocator, layout: geometry.Layout) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const win = activeWindow(arena) orelse return;
    const mon = monitor(arena, win.monitor) orelse return;
    batch(gpa, layoutCommands(arena, win, mon, layout) catch return);
}

/// The dispatches that put `win` where `layout` says on `mon`. Pixel moves
/// need a floating window (and fullscreen windows ignore them), hence the
/// first two. `fullscreen` only acts on the active window, which `win` is.
/// The commands live in `arena`.
pub fn layoutCommands(arena: std.mem.Allocator, win: Client, mon: geometry.Monitor, layout: geometry.Layout) std.mem.Allocator.Error![]const []const u8 {
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(parse([]Client, arena.allocator(), "not json") == null);
    try testing.expect(parse([]Client, arena.allocator(), "{\"address\": 3}") == null);
    try testing.expect(parse([]MonitorJson, arena.allocator(), "[{\"name\":\"x\"}]") == null);
}
