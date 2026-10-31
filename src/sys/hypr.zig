//! Hyprland, for the window switcher, window layouts and pasting into the
//! window that had the focus.
//!
//! - Queries (`clients`, `activeWindow`, `monitor`) ask Hyprland's request
//!   socket for JSON, or run `hyprctl -j` when it cannot be reached.
//! - Dispatches (`batch`, `dispatch`) are queued, not sent: one that goes
//!   while Lumen's layer still has the focus is undone when it hides. The
//!   queue is sent once Hyprland gives the focus back (`sendAfterHide`,
//!   which waits for `activewindow` on the event socket), or on the next
//!   idle if the window does not hide.
//! - `afterFocusChange` is that wait, for anyone else too (a paste).
//! - Layouts turn a `geometry.Layout` into dispatches for the active window.
//!
//! The queue and the wait are one each, driven by GLib sources: main
//! thread only.
//!
//! Parsing and command building are pure functions over the JSON text, so
//! they are tested against recorded output (testdata/) instead of a live
//! compositor.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const c = @import("c");
const os = @import("os");
const proc = @import("proc.zig");
const ipc = @import("../ipc.zig");
const geometry = @import("core").geometry;

const log = std.log.scoped(.hypr);

// ---------------------------------------------------------------- queries

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
        const output = proc.output(&.{ "hyprctl", "-j", what }) orelse return null;
        defer proc.free(output);
        break :blk arena.dupe(u8, output) catch return null;
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
    var message_buffer: [64]u8 = undefined;
    const message = std.mem.print(&message_buffer, "j/{s}", .{what}) catch return null;
    return talk(arena, message);
}

/// Windows ordered by last focus, most recent first; they live in `arena`.
pub fn clients(arena: std.mem.Allocator) []Client {
    const all = query(arena, []Client, "clients") orelse return &.{};
    sortByFocus(all);
    return all;
}

/// Most recently focused first.
pub fn sortByFocus(all: []Client) void {
    std.mem.sort(Client, all, {}, struct {
        fn lessThan(_: void, left: Client, right: Client) bool {
            return left.focusHistoryID < right.focusHistoryID;
        }
    }.lessThan);
}

pub fn activeWindow(arena: std.mem.Allocator) ?Client {
    const window = query(arena, Client, "activewindow") orelse return null;
    // No window focused: Hyprland answers with an empty one.
    if (window.address.len == 0) return null;
    return window;
}

pub fn monitor(arena: std.mem.Allocator, id: i64) ?geometry.Monitor {
    return findMonitor(query(arena, []MonitorJson, "monitors") orelse return null, id);
}

pub fn findMonitor(all: []const MonitorJson, id: i64) ?geometry.Monitor {
    for (all) |monitor_json| {
        if (monitor_json.id != id) continue;
        const found = monitorFromJson(monitor_json);
        // The geometry runs without overflow checks (core is ReleaseFast):
        // a broken reply stops here, never reaching its arithmetic.
        if (!found.plausible()) return null;
        return found;
    }
    return null;
}

fn monitorFromJson(monitor_json: MonitorJson) geometry.Monitor {
    return .{
        .x = monitor_json.x,
        .y = monitor_json.y,
        .width = monitor_json.width,
        .height = monitor_json.height,
        .scale = monitor_json.scale,
        .transform = monitor_json.transform,
        .reserved = monitor_json.reserved,
    };
}

/// Connector name of the focused monitor ("DP-1").
pub fn focusedMonitorName(arena: std.mem.Allocator) ?[]const u8 {
    return focusedName(query(arena, []MonitorJson, "monitors") orelse return null);
}

pub fn focusedName(all: []const MonitorJson) ?[]const u8 {
    for (all) |monitor_json| {
        if (monitor_json.focused) return monitor_json.name;
    }
    return null;
}

// ---------------------------------------------------------------- sockets

/// Hyprland's two sockets: one for requests (dispatches, queries), one it
/// writes its events to.
const Socket = enum {
    requests,
    events,

    fn fileName(socket: Socket) []const u8 {
        return switch (socket) {
            .requests => ".socket.sock",
            .events => ".socket2.sock",
        };
    }
};

/// Connects to one of Hyprland's sockets; null without Hyprland.
fn connect(socket: Socket, options: os.unix.ConnectOptions) ?linux.fd_t {
    const signature_z = c.g_getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return null;
    const runtime_dir_z = c.g_getenv(ipc.env.runtime_dir) orelse return null;
    const instance_signature = std.mem.span(signature_z);
    const runtime_dir = std.mem.span(runtime_dir_z);
    var path_buffer: [@sizeOf(@FieldType(linux.sockaddr.un, "path"))]u8 = undefined;
    const path = std.mem.print(
        &path_buffer,
        "{s}/hypr/{s}/{s}",
        .{ runtime_dir, instance_signature, socket.fileName() },
    ) catch return null;
    return os.unix.connect(path, options);
}

/// A compositor that does not answer must not freeze the window.
const answer_timeout_ns = std.time.ns_per_s;
/// Nor one that never stops: `j/clients` with 200 windows is ~300 KB.
const answer_bytes_max = 16 << 20;
/// How much more room the answer gets each time it fills up.
const answer_chunk_bytes = 16 << 10;
/// The answer to dispatches is only read to its end, never kept: "ok" per
/// dispatch.
const ok_answer_bytes_max = 256;

comptime {
    assert(answer_chunk_bytes < answer_bytes_max);
}

/// Sends `message` to the request socket and reads the whole answer.
fn talk(arena: std.mem.Allocator, message: []const u8) ?[]const u8 {
    const fd = connect(.requests, .{}) orelse return null;
    defer _ = linux.close(fd);
    if (!os.unix.writeAll(fd, message)) return null;
    const deadline_ns = os.monotonicNs() + answer_timeout_ns;
    var answer: std.ArrayList(u8) = .empty;
    while (true) {
        if (answer.items.len >= answer_bytes_max) {
            log.warn("{s}: answer over {d} bytes, dropped", .{ message, answer_bytes_max });
            return null;
        }
        answer.ensureUnusedCapacity(arena, answer_chunk_bytes) catch return null;
        const spare = answer.unusedCapacitySlice();
        const chunk_len = os.unix.readSome(fd, spare, deadline_ns) catch return null;
        if (chunk_len == 0) break;
        answer.items.len += chunk_len;
    }
    return if (answer.items.len > 0) answer.items else null;
}

/// Sends dispatches and waits until Hyprland has run them. False only when
/// nothing was sent (no socket), so hyprctl may try instead: once sent, a
/// dispatch must never go twice (a toggle would undo itself). What Hyprland
/// answers ("ok" per dispatch) does not matter.
fn dispatchOver(message: []const u8) bool {
    const fd = connect(.requests, .{}) orelse return false;
    defer _ = linux.close(fd);
    const written = linux.write(fd, message.ptr, message.len);
    if (os.unix.failed(written) != null) return false;
    if (written == 0) return false;
    // Partly sent: the rest goes too, never again from the start.
    if (written < message.len and !os.unix.writeAll(fd, message[written..])) {
        log.warn("dispatch partly sent: {d} of {d} bytes", .{ written, message.len });
    }
    const deadline_ns = os.monotonicNs() + answer_timeout_ns;
    var answer: [ok_answer_bytes_max]u8 = undefined;
    while (os.unix.readSome(fd, &answer, deadline_ns)) |answer_len| {
        if (answer_len == 0) break;
    } else |_| {}
    return true;
}

// ---------------------------------------------------------------- dispatches

/// `batch` of one command.
pub fn dispatch(gpa: std.mem.Allocator, command: []const u8) void {
    batch(gpa, &.{command});
}

/// Queues `commands` ("focuswindow address:0x..."): they go on the next
/// idle, or once the window has hidden and the focus is back
/// (`sendAfterHide`).
pub fn batch(gpa: std.mem.Allocator, commands: []const []const u8) void {
    if (!dispatch_queue.append(commands)) {
        // Too long to queue: run hyprctl now (slower, but never dropped).
        const batch_z = batchString(gpa, commands) catch return;
        defer gpa.free(batch_z);
        proc.spawn(&.{ "hyprctl", "--batch", batch_z });
        return;
    }
    // Send on the next idle, in case the action does not hide the window;
    // sendAfterHide replaces this when it does.
    if (dispatch_queue.idle_source == 0) {
        dispatch_queue.idle_source = c.g_idle_add(&batchIdleCallback, null);
    }
}

fn batchIdleCallback(_: ?*anyopaque) callconv(.c) c.gboolean {
    dispatch_queue.idle_source = 0;
    sendQueued();
    return 0;
}

/// Dispatches queued for the window to hide (`DispatchQueue`). A layout is
/// four short commands; a batch that does not fit runs through hyprctl.
const dispatch_queue_bytes_max = 8192;

/// What `hyprctl --batch` sends ahead of "dispatch a;dispatch b".
const batch_prefix = "[[BATCH]]";
/// Between two commands of a batch.
const batch_separator = ";";
/// Ahead of each dispatcher and its arguments ("dispatch exit").
const dispatch_keyword = "dispatch ";

comptime {
    // `sendQueued` copies the queue without its prefix and adds a zero.
    assert(batch_prefix.len >= 1);
}

/// Dispatches waiting for the window to hide: sent before Hyprland gave the
/// focus back from Lumen's layer, a `focuswindow` is undone by that (seen:
/// the focus stayed put). Sent once the focus is back (`sendAfterHide`).
/// Starting hyprctl for them took ~4 ms; the socket, ~0.05. Main thread
/// only, like the GLib sources it uses.
const DispatchQueue = struct {
    /// "[[BATCH]]dispatch a;dispatch b", as `hyprctl --batch` would send.
    buffer: [dispatch_queue_bytes_max]u8 = undefined,
    len: usize = 0,
    /// The idle source that sends the queue if the window does not hide.
    idle_source: c_uint = 0,

    /// Appends `commands`; false when they do not fit, and then nothing of
    /// them was queued.
    fn append(queue: *DispatchQueue, commands: []const []const u8) bool {
        var writer: std.Io.Writer = .fixed(queue.buffer[queue.len..]);
        for (commands) |command| {
            const empty = queue.len + writer.end == 0;
            const separator = if (empty)
                batch_prefix ++ dispatch_keyword
            else
                batch_separator ++ dispatch_keyword;
            writer.writeAll(separator) catch return false;
            writer.writeAll(command) catch return false;
        }
        queue.len += writer.end;
        assert(std.mem.startsWith(u8, queue.buffer[0..queue.len], batch_prefix));
        return true;
    }

    fn cancelIdle(queue: *DispatchQueue) void {
        if (queue.idle_source != 0) _ = c.g_source_remove(queue.idle_source);
        queue.idle_source = 0;
    }
};

/// One queue for the one window that hides. Main thread only.
var dispatch_queue: DispatchQueue = .{};

/// After this long without a focus event, queued dispatches go anyway.
const focus_fallback_ms = 60;

/// Before the window hides: queued dispatches go once Hyprland has given
/// the focus back (or after `focus_fallback_ms`). Listening starts now, so
/// the event that the hide causes is not missed.
pub fn sendAfterHide() void {
    if (dispatch_queue.len == 0) return;
    dispatch_queue.cancelIdle();
    afterFocusChange(&sendQueued, focus_fallback_ms);
}

/// Sends what `batch` queued; hyprctl if the socket cannot be reached.
pub fn sendQueued() void {
    if (dispatch_queue.len == 0) return;
    const queued = dispatch_queue.buffer[0..dispatch_queue.len];
    dispatch_queue.len = 0;
    if (dispatchOver(queued)) return;
    assert(std.mem.startsWith(u8, queued, batch_prefix));
    // The queue without its prefix, and the terminating zero.
    var batch_buffer: [dispatch_queue_bytes_max]u8 = undefined;
    const commands = queued[batch_prefix.len..];
    const batch_z = std.mem.printSentinel(&batch_buffer, "{s}", .{commands}, 0) catch return;
    proc.spawn(&.{ "hyprctl", "--batch", batch_z });
}

/// The argument of `hyprctl --batch`: "dispatch a ; dispatch b". Caller owns
/// it.
pub fn batchString(
    gpa: std.mem.Allocator,
    commands: []const []const u8,
) std.mem.Allocator.Error![:0]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    for (commands, 0..) |command, i| {
        if (i > 0) try joined.appendSlice(gpa, " " ++ batch_separator ++ " ");
        try joined.appendSlice(gpa, dispatch_keyword);
        try joined.appendSlice(gpa, command);
    }
    return joined.toOwnedSliceSentinel(gpa, 0);
}

// ---------------------------------------------------------------- focus

/// Room for the event lines read and not yet ended by a newline. An event
/// is one short line ("activewindow>>class,title").
const events_buffer_bytes = 4096;

/// Waits for Hyprland to give a window the focus (`activewindow` on its
/// event socket), then calls back whoever asked. Main thread only.
const FocusWaiter = struct {
    callbacks: [4]*const fn () void = undefined,
    callbacks_count: usize = 0,
    events_fd: linux.fd_t = -1,
    /// The event socket's watch and the fallback timer; 0 when not set.
    watch_source: c_uint = 0,
    timer_source: c_uint = 0,
    /// Events read so far; a line may arrive in pieces.
    events_buffer: [events_buffer_bytes]u8 = undefined,
    events_len: usize = 0,

    fn waiting(waiter: *const FocusWaiter) bool {
        return waiter.timer_source != 0;
    }

    fn stop(waiter: *FocusWaiter) void {
        if (waiter.watch_source != 0) _ = c.g_source_remove(waiter.watch_source);
        if (waiter.timer_source != 0) _ = c.g_source_remove(waiter.timer_source);
        if (waiter.events_fd >= 0) _ = linux.close(waiter.events_fd);
        waiter.watch_source = 0;
        waiter.timer_source = 0;
        waiter.events_fd = -1;
    }

    /// Stops waiting and calls everyone who asked, once each.
    fn fire(waiter: *FocusWaiter) void {
        waiter.stop();
        assert(!waiter.waiting());
        // A callback may ask again: it gets a fresh list.
        const callbacks = waiter.callbacks;
        const callbacks_count = waiter.callbacks_count;
        waiter.callbacks_count = 0;
        for (callbacks[0..callbacks_count]) |callback| callback();
    }
};

/// One wait for the focus at a time, which every callback asked for in the
/// meantime shares. Main thread only.
var focus_waiter: FocusWaiter = .{};

/// Calls `callback` once Hyprland gives a window the focus, else after
/// `fallback_ms`: a paste right after Lumen hides waited a fixed 120 ms,
/// and the focus is back in ~2.
pub fn afterFocusChange(callback: *const fn () void, fallback_ms: c_uint) void {
    const waiter = &focus_waiter;
    for (waiter.callbacks[0..waiter.callbacks_count]) |waiting_callback| {
        if (waiting_callback == callback) return;
    }
    if (waiter.callbacks_count == waiter.callbacks.len) {
        log.debug("{d} callbacks already wait for the focus: called now", .{
            waiter.callbacks_count,
        });
        return callback();
    }
    waiter.callbacks[waiter.callbacks_count] = callback;
    waiter.callbacks_count += 1;
    // Already waiting: one event serves all.
    if (waiter.waiting()) return;
    waiter.events_len = 0;
    if (connect(.events, .{ .nonblock = true })) |fd| {
        waiter.events_fd = fd;
        waiter.watch_source = c.g_unix_fd_add(fd, c.G_IO_IN, &afterFocusChangeEventsCallback, null);
    }
    waiter.timer_source = c.g_timeout_add(fallback_ms, &afterFocusChangeTimeoutCallback, null);
}

fn afterFocusChangeTimeoutCallback(_: ?*anyopaque) callconv(.c) c.gboolean {
    // The source ends with this call: fire must not remove it again.
    focus_waiter.timer_source = 0;
    focus_waiter.fire();
    return 0;
}

/// Reads at most this many times per turn of the main loop: a burst of
/// events is read over several turns, never holding the window.
const events_reads_max = 64;

fn afterFocusChangeEventsCallback(fd: c_int, _: c_uint, _: ?*anyopaque) callconv(.c) c.gboolean {
    const waiter = &focus_waiter;
    for (0..events_reads_max) |_| {
        // Full without a focus event: what came so far is of no use.
        if (waiter.events_len == waiter.events_buffer.len) waiter.events_len = 0;
        const spare = waiter.events_buffer[waiter.events_len..];
        const bytes_read = linux.read(fd, spare.ptr, spare.len);
        if (linux.errno(bytes_read) != .SUCCESS) break;
        if (bytes_read == 0) break;
        waiter.events_len += bytes_read;
    }
    if (focusEvent(waiter.events_buffer[0..waiter.events_len])) {
        // The source ends with this call: fire must not remove it again.
        waiter.watch_source = 0;
        waiter.fire();
        return 0;
    }
    return 1;
}

/// Whether Hyprland's event text holds a focus change.
fn focusEvent(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "activewindow>>")) return true;
    }
    return false;
}

test "a focus change among Hyprland's events" {
    try std.testing.expect(focusEvent("closelayer>>lumen\nactivewindow>>kitty,~\n"));
    try std.testing.expect(!focusEvent("closelayer>>lumen\nactivewindowv2>>5619ce\n"));
    try std.testing.expect(!focusEvent("openlayer>>lumen\n"));
}

// ---------------------------------------------------------------- layouts

/// Moves and resizes the active window for `layout`, floating it first.
pub fn applyLayout(gpa: std.mem.Allocator, layout: geometry.Layout) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const window = activeWindow(arena) orelse return;
    const window_monitor = monitor(arena, window.monitor) orelse return;
    const commands = layoutCommands(arena, window, window_monitor, layout) catch return;
    batch(gpa, commands);
}

/// Pixels kept between a placed window and the edges, and between halves.
const layout_gap_px = 8;

/// The dispatches that put `window` where `layout` says on `monitor_area`.
/// Pixel moves need a floating window (and fullscreen windows ignore them),
/// hence the first two. `fullscreen` only acts on the active window, which
/// `window` is. The commands live in `arena`.
pub fn layoutCommands(
    arena: std.mem.Allocator,
    window: Client,
    monitor_area: geometry.Monitor,
    layout: geometry.Layout,
) std.mem.Allocator.Error![]const []const u8 {
    // activeWindow returns no window without an address.
    assert(window.address.len > 0);
    const current_size: geometry.Size = .{ .width = window.size[0], .height = window.size[1] };
    const placed = geometry.place(layout, monitor_area.usable(), current_size, layout_gap_px);
    var commands: std.ArrayList([]const u8) = .empty;
    if (window.fullscreen != 0) try commands.append(arena, "fullscreen 0");
    if (!window.floating) {
        try commands.append(arena, try arena.print("setfloating address:{s}", .{window.address}));
    }
    try commands.append(arena, try arena.print(
        "resizewindowpixel exact {d} {d},address:{s}",
        .{ placed.width, placed.height, window.address },
    ));
    try commands.append(arena, try arena.print(
        "movewindowpixel exact {d} {d},address:{s}",
        .{ placed.x, placed.y, window.address },
    ));
    return commands.items;
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
    // The one on the special workspace is not mapped: the UI skips it.
    try testing.expect(!all[1].mapped);
    try testing.expectEqual(@as(i64, -99), all[1].workspace.id);
}

test "monitors: rotation and scale give the usable area" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const monitors_json = @embedFile("testdata/hypr_monitors.json");
    const monitors = parse([]MonitorJson, arena.allocator(), monitors_json).?;
    try testing.expectEqualStrings("DP-1", focusedName(monitors).?);
    // HDMI-A-1: 1600x900 rotated 270° -> 900x1600 logical, bar on top.
    const hdmi = findMonitor(monitors, 0).?.usable();
    const hdmi_want: geometry.Rect = .{ .x = 4307, .y = 38, .width = 900, .height = 1562 };
    try testing.expectEqual(hdmi_want, hdmi);
    // DP-1: 1920x1080 at scale 1.25 -> 1536x864 logical.
    const display_port = findMonitor(monitors, 1).?.usable();
    const display_port_want: geometry.Rect = .{ .x = 2387, .y = 38, .width = 1536, .height = 826 };
    try testing.expectEqual(display_port_want, display_port);
    try testing.expect(findMonitor(monitors, 7) == null);

    // Replies no monitor gives are refused, not computed with.
    var bad = monitors[1];
    for ([_]f64{ 0, -1, 1e-300, std.math.nan(f64), std.math.inf(f64) }) |scale| {
        bad.scale = scale;
        try testing.expect(findMonitor(&.{bad}, bad.id) == null);
    }
    bad = monitors[1];
    bad.width = std.math.maxInt(i32);
    try testing.expect(findMonitor(&.{bad}, bad.id) == null);
    bad = monitors[1];
    bad.reserved[0] = -5;
    try testing.expect(findMonitor(&.{bad}, bad.id) == null);
}

test "layout commands: tiled window floats first, fullscreen leaves first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const monitors_json = @embedFile("testdata/hypr_monitors.json");
    const monitors = parse([]MonitorJson, allocator, monitors_json).?;
    const all = parse([]Client, allocator, @embedFile("testdata/hypr_clients.json")).?;
    // Discord's window is tiled, on DP-1.
    const discord = all[0];
    const discord_monitor = findMonitor(monitors, discord.monitor).?;
    const commands = try layoutCommands(allocator, discord, discord_monitor, .left_half);
    try testing.expectEqual(@as(usize, 3), commands.len);
    try testing.expectEqualStrings("setfloating address:0x5600000000a0", commands[0]);
    try testing.expectEqualStrings(
        "resizewindowpixel exact 756 810,address:0x5600000000a0",
        commands[1],
    );
    try testing.expectEqualStrings(
        "movewindowpixel exact 2395 46,address:0x5600000000a0",
        commands[2],
    );

    var full = all[1];
    full.fullscreen = 1;
    full.floating = true;
    const full_monitor = findMonitor(monitors, 0).?;
    const full_commands = try layoutCommands(allocator, full, full_monitor, .maximize);
    try testing.expectEqualStrings("fullscreen 0", full_commands[0]);
    try testing.expectEqual(@as(usize, 3), full_commands.len);

    const joined = try batchString(testing.allocator, commands[0..2]);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings(
        "dispatch setfloating address:0x5600000000a0 ; dispatch resizewindowpixel exact 756 810,address:0x5600000000a0",
        joined,
    );
}

test "garbage or a changed shape does not crash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(parse([]Client, arena.allocator(), "not json") == null);
    try testing.expect(parse([]Client, arena.allocator(), "{\"address\": 3}") == null);
    try testing.expect(parse([]MonitorJson, arena.allocator(), "[{\"name\":\"x\"}]") == null);
}
