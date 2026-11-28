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
    // Defaults: `activewindow` answers `{}` when no window has the focus.
    address: []const u8 = "",
    title: []const u8 = "",
    class: []const u8 = "",
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
    const json = request(arena, what) orelse
        (proc.outputTimeout(arena, &.{ "hyprctl", "-j", what }, 300) orelse return null);
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

/// Whether `address` is a lowercase hexadecimal Hyprland window address (`0x[0-9a-f]+`).
pub fn validAddress(address: []const u8) bool {
    if (address.len < 3 or !std.mem.startsWith(u8, address, "0x")) return false;
    for (address[2..]) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    }
    return true;
}

pub fn activeWindow(arena: std.mem.Allocator) ?Client {
    const window = query(arena, Client, "activewindow") orelse return null;
    // No window focused (empty address) or malformed address: ignore.
    if (!validAddress(window.address)) return null;
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

/// Connects to one of Hyprland's sockets; null without Hyprland or if peer UID differs.
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
    const fd = os.unix.connect(path, options) orelse return null;
    if (os.unix.peerUid(fd) != linux.getuid()) {
        log.warn("refused Hyprland socket {s} owned by another user", .{path});
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// A compositor that does not answer must not freeze the window.
const answer_timeout_ns = 150 * std.time.ns_per_ms;
/// Nor one that never stops: `j/clients` with 200 windows is ~300 KB.
const answer_bytes_max = 16 << 20;
/// How much more room the answer gets each time it fills up.
const answer_chunk_bytes = 16 << 10;

comptime {
    assert(answer_chunk_bytes < answer_bytes_max);
}

/// Sends `message` to the request socket and reads the whole answer.
fn talk(arena: std.mem.Allocator, message: []const u8) ?[]const u8 {
    const fd = connect(.requests, .{}) orelse return null;
    defer _ = linux.close(fd);
    if (!os.unix.sendAll(fd, message)) return null;
    const deadline_ns = os.monotonicNs() + answer_timeout_ns;
    var answer: std.ArrayList(u8) = .empty;
    while (true) {
        if (answer.items.len >= answer_bytes_max) {
            log.warn("{s}: answer over {d} bytes, dropped", .{ message, answer_bytes_max });
            return null;
        }
        const room = answer_bytes_max - answer.items.len;
        answer.ensureUnusedCapacity(arena, @min(answer_chunk_bytes, room)) catch return null;
        const spare = answer.unusedCapacitySlice()[0..@min(answer.unusedCapacitySlice().len, room)];
        const chunk_len = os.unix.readSome(fd, spare, deadline_ns) catch return null;
        if (chunk_len == 0) break;
        answer.items.len += chunk_len;
    }
    return if (answer.items.len > 0) answer.items else null;
}

const dispatch_reply_timeout_ms = 500;

const ReplyMode = enum { async, sync };

fn isAllOk(reply: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, reply, "\r\n");
    if (trimmed.len == 0 or trimmed.len % 2 != 0) return false;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 2) {
        if (!std.mem.eql(u8, trimmed[i..][0..2], "ok")) return false;
    }
    return true;
}

const DispatchReply = struct {
    fd: linux.fd_t,
    watch_source: c_uint = 0,
    timer_source: c_uint = 0,
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn finish(reply: *DispatchReply) void {
        if (reply.watch_source != 0) _ = c.g_source_remove(reply.watch_source);
        if (reply.timer_source != 0) _ = c.g_source_remove(reply.timer_source);
        reply.watch_source = 0;
        reply.timer_source = 0;
        if (reply.fd >= 0) _ = linux.close(reply.fd);
        reply.fd = -1;
        const text = reply.buf[0..reply.len];
        if (text.len > 0 and !isAllOk(text)) {
            log.warn("Hyprland dispatch reply: {s}", .{std.mem.trimEnd(u8, text, "\r\n")});
        }
        for (active_replies.items, 0..) |item, i| {
            if (item == reply) {
                _ = active_replies.swapRemove(i);
                break;
            }
        }
        std.heap.c_allocator.destroy(reply);
    }
};

var active_replies: std.ArrayList(*DispatchReply) = .empty;

fn setNonblocking(fd: linux.fd_t) bool {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (os.unix.failed(flags) != null) return false;
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    return os.unix.failed(linux.fcntl(fd, linux.F.SETFL, flags | nonblock)) == null;
}

fn onDispatchReply(fd: c_int, condition: c_uint, data: ?*anyopaque) callconv(.c) c.gboolean {
    const reply: *DispatchReply = @ptrCast(@alignCast(data.?));
    while (reply.len < reply.buf.len) {
        const res = linux.read(fd, reply.buf[reply.len..].ptr, reply.buf.len - reply.len);
        if (os.unix.failed(res)) |errno| switch (errno) {
            .INTR => continue,
            .AGAIN => {
                if (condition & (c.G_IO_HUP | c.G_IO_ERR) != 0) break;
                return 1;
            },
            else => break,
        };
        if (res == 0) break;
        reply.len += res;
    }
    reply.watch_source = 0;
    reply.finish();
    return 0;
}

fn onDispatchReplyTimeout(data: ?*anyopaque) callconv(.c) c.gboolean {
    const reply: *DispatchReply = @ptrCast(@alignCast(data.?));
    reply.timer_source = 0;
    reply.finish();
    return 0;
}

fn readReplySync(fd: linux.fd_t) void {
    const deadline_ns = os.monotonicNs() + dispatch_reply_timeout_ms * std.time.ns_per_ms;
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = os.unix.readSome(fd, buf[len..], deadline_ns) catch break;
        if (n == 0) break;
        len += n;
    }
    const text = buf[0..len];
    if (text.len > 0 and !isAllOk(text)) {
        log.warn("Hyprland dispatch reply: {s}", .{std.mem.trimEnd(u8, text, "\r\n")});
    }
}

fn finishDispatchFd(fd: linux.fd_t, mode: ReplyMode) void {
    if (mode == .sync or !setNonblocking(fd)) {
        defer _ = linux.close(fd);
        readReplySync(fd);
        return;
    }
    const reply = std.heap.c_allocator.create(DispatchReply) catch {
        defer _ = linux.close(fd);
        readReplySync(fd);
        return;
    };
    reply.* = .{ .fd = fd };
    active_replies.append(std.heap.c_allocator, reply) catch {
        std.heap.c_allocator.destroy(reply);
        defer _ = linux.close(fd);
        readReplySync(fd);
        return;
    };
    reply.watch_source = c.g_unix_fd_add(
        fd,
        c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
        &onDispatchReply,
        reply,
    );
    reply.timer_source = c.g_timeout_add(
        dispatch_reply_timeout_ms,
        &onDispatchReplyTimeout,
        reply,
    );
}

/// Sends dispatches over `fd` and keeps the socket open until Hyprland replies
/// (or times out), because Hyprland drops requests whose client closes first.
/// False only when nothing was sent so hyprctl may try instead.
fn dispatchOverFd(fd: linux.fd_t, message: []const u8, mode: ReplyMode) bool {
    const written = while (true) {
        const result = os.unix.send(fd, message);
        if (os.unix.failed(result)) |errno| switch (errno) {
            .INTR => continue,
            else => {
                _ = linux.close(fd);
                return false;
            },
        };
        break result;
    };
    if (written == 0) {
        _ = linux.close(fd);
        return false;
    }
    // Partly sent: the rest goes too, never again from the start.
    if (written < message.len and !os.unix.sendAll(fd, message[written..])) {
        log.warn("dispatch partly sent: {d} of {d} bytes", .{ written, message.len });
        _ = linux.close(fd);
        return true;
    }
    finishDispatchFd(fd, mode);
    return true;
}

/// Sends dispatches over Hyprland's request socket, waiting for the reply
/// without blocking GTK (in `.async` mode). False only when nothing was sent.
fn dispatchOver(message: []const u8, mode: ReplyMode) bool {
    const fd = connect(.requests, .{}) orelse return false;
    return dispatchOverFd(fd, message, mode);
}

// ---------------------------------------------------------------- dispatches

/// `batch` of one command.
pub fn dispatch(gpa: std.mem.Allocator, command: []const u8) void {
    os.assertMainThread();
    batch(gpa, &.{command});
}

/// Queues `commands` ("focuswindow address:0x..."): they go on the next
/// idle, or once the window has hidden and the focus is back
/// (`sendAfterHide`).
pub fn batch(gpa: std.mem.Allocator, commands: []const []const u8) void {
    os.assertMainThread();
    batchWith(gpa, commands, &sendQueued, &spawnBatch);
}

fn spawnBatch(gpa: std.mem.Allocator, commands: []const []const u8) void {
    const batch_z = batchString(gpa, commands) catch return;
    defer gpa.free(batch_z);
    _ = proc.spawn(&.{ "hyprctl", "--batch", batch_z });
}

fn batchWith(
    gpa: std.mem.Allocator,
    commands: []const []const u8,
    flush_queued: *const fn () void,
    send_direct: *const fn (std.mem.Allocator, []const []const u8) void,
) void {
    if (!dispatch_queue.append(commands)) {
        // Flush queued commands first so the oversized batch never overtakes them.
        if (dispatch_queue.len > 0) {
            dispatch_queue.cancelIdle();
            flush_queued();
            if (dispatch_queue.append(commands)) {
                if (dispatch_queue.idle_source == 0) {
                    dispatch_queue.idle_source = c.g_idle_add(&batchIdleCallback, null);
                }
                return;
            }
        }
        // Too long to queue even alone: run hyprctl now (slower, but never dropped).
        send_direct(gpa, commands);
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
    os.assertMainThread();
    if (dispatch_queue.len == 0) return;
    dispatch_queue.cancelIdle();
    afterFocusChange(&sendQueuedCallback, 0, focus_fallback_ms);
}

fn sendQueuedCallback(_: usize) void {
    sendQueued();
}

/// Sends what `batch` queued; hyprctl if the socket cannot be reached.
/// At shutdown: dispatches still queued go synchronously, and any open
/// reply watches and the event socket this file holds are let go.
pub fn shutdown() void {
    os.assertMainThread();
    dispatch_queue.cancelIdle();
    sendQueuedMode(.sync);
    while (active_replies.items.len > 0) {
        active_replies.items[active_replies.items.len - 1].finish();
    }
    active_replies.deinit(std.heap.c_allocator);
    active_replies = .empty;
    focus_waiter.stop();
}

pub fn sendQueued() void {
    sendQueuedMode(.async);
}

fn sendQueuedMode(mode: ReplyMode) void {
    os.assertMainThread();
    if (dispatch_queue.len == 0) return;
    const queued = dispatch_queue.buffer[0..dispatch_queue.len];
    dispatch_queue.len = 0;
    if (dispatchOver(queued, mode)) return;
    assert(std.mem.startsWith(u8, queued, batch_prefix));
    // The queue without its prefix, and the terminating zero.
    var batch_buffer: [dispatch_queue_bytes_max]u8 = undefined;
    const commands = queued[batch_prefix.len..];
    const batch_z = std.mem.printSentinel(&batch_buffer, "{s}", .{commands}, 0) catch return;
    _ = proc.spawn(&.{ "hyprctl", "--batch", batch_z });
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

const FocusCallback = struct {
    callback: *const fn (usize) void,
    context: usize,
};

/// Waits for Hyprland to give a window the focus (`activewindow` on its
/// event socket), then calls back whoever asked. Main thread only.
const FocusWaiter = struct {
    callbacks: [4]FocusCallback = undefined,
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
        for (callbacks[0..callbacks_count]) |entry| entry.callback(entry.context);
    }
};

/// One wait for the focus at a time, which every callback asked for in the
/// meantime shares. Main thread only.
var focus_waiter: FocusWaiter = .{};

/// Calls `callback(context)` once Hyprland gives a window the focus, else after
/// `fallback_ms`: a paste right after Lumen hides waited a fixed 120 ms,
/// and the focus is back in ~2.
pub fn afterFocusChange(
    callback: *const fn (usize) void,
    context: usize,
    fallback_ms: c_uint,
) void {
    os.assertMainThread();
    const waiter = &focus_waiter;
    for (waiter.callbacks[0..waiter.callbacks_count]) |*entry| {
        if (entry.callback == callback) {
            entry.context = context;
            if (waiter.timer_source != 0) {
                _ = c.g_source_remove(waiter.timer_source);
                waiter.timer_source = c.g_timeout_add(
                    fallback_ms,
                    &afterFocusChangeTimeoutCallback,
                    null,
                );
            }
            return;
        }
    }
    if (waiter.callbacks_count == waiter.callbacks.len) {
        log.debug("{d} callbacks already wait for the focus: called now", .{
            waiter.callbacks_count,
        });
        return callback(context);
    }
    waiter.callbacks[waiter.callbacks_count] = .{ .callback = callback, .context = context };
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
    var closed = false;
    for (0..events_reads_max) |_| {
        if (waiter.events_len == waiter.events_buffer.len) {
            compactEvents(&waiter.events_buffer, &waiter.events_len);
        }
        const spare = waiter.events_buffer[waiter.events_len..];
        const bytes_read = linux.read(fd, spare.ptr, spare.len);
        switch (linux.errno(bytes_read)) {
            .SUCCESS => {
                if (bytes_read == 0) {
                    closed = true;
                    break;
                }
                waiter.events_len += bytes_read;
                if (focusEvent(waiter.events_buffer[0..waiter.events_len])) {
                    // The source ends with this call: fire must not remove it again.
                    waiter.watch_source = 0;
                    waiter.fire();
                    return 0;
                }
            },
            .AGAIN => break,
            .INTR => continue,
            else => {
                closed = true;
                break;
            },
        }
    }
    if (closed) {
        // Detach the dead socket so GLib does not busy-spin on EOF/HUP;
        // the fallback timer still fires on schedule.
        waiter.watch_source = 0;
        if (waiter.events_fd >= 0) {
            _ = linux.close(waiter.events_fd);
            waiter.events_fd = -1;
        }
        return 0;
    }
    return 1;
}

/// Compacts a full event buffer after `focusEvent` found no match, keeping any
/// trailing incomplete line so an event split across the buffer boundary is
/// still recognized on the next read.
fn compactEvents(buffer: []u8, len: *usize) void {
    const used = buffer[0..len.*];
    if (std.mem.findScalarLast(u8, used, '\n')) |last_newline| {
        const tail = used[last_newline + 1 ..];
        std.mem.copyForwards(u8, buffer[0..tail.len], tail);
        len.* = tail.len;
    } else {
        // A single line longer than the buffer did not start with
        // "activewindow>>"; keep one non-matching byte so its continuation
        // cannot be mistaken for the start of a new line.
        buffer[0] = ' ';
        len.* = 1;
    }
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

    // Split across a buffer compaction boundary: trailing partial line is kept.
    var buffer: [32]u8 = undefined;
    const part1 = "openlayer>>lumen\nactivew";
    @memcpy(buffer[0..part1.len], part1);
    var len: usize = part1.len;
    try std.testing.expect(!focusEvent(buffer[0..len]));
    compactEvents(&buffer, &len);
    const part2 = "indow>>kitty,~\n";
    @memcpy(buffer[len..][0..part2.len], part2);
    len += part2.len;
    try std.testing.expect(focusEvent(buffer[0..len]));

    // Oversized line without newline: continuation cannot false-match.
    @memset(&buffer, 'x');
    len = buffer.len;
    compactEvents(&buffer, &len);
    const fake = "activewindow>>fake\n";
    @memcpy(buffer[len..][0..fake.len], fake);
    len += fake.len;
    try std.testing.expect(!focusEvent(buffer[0..len]));

    // EOF on the event socket removes the watch instead of spinning.
    var pair: [2]i32 = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.socketpair(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            0,
            &pair,
        )),
    );
    _ = linux.close(pair[1]);
    focus_waiter = .{ .events_fd = pair[0], .watch_source = 1 };
    defer focus_waiter.stop();
    try std.testing.expectEqual(
        @as(c.gboolean, 0),
        afterFocusChangeEventsCallback(pair[0], 0, null),
    );
    try std.testing.expectEqual(@as(c_uint, 0), focus_waiter.watch_source);
    try std.testing.expectEqual(@as(linux.fd_t, -1), focus_waiter.events_fd);
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
    if (!validAddress(window.address)) return &.{};
    const current_size: geometry.Size = .{ .width = window.size[0], .height = window.size[1] };
    const placed = geometry.place(layout, monitor_area.usable(), current_size, layout_gap_px);
    var commands: std.ArrayList([]const u8) = .empty;
    if (window.fullscreen != 0) try commands.append(arena, "fullscreenstate 0 0");
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

test "activewindow with no window focused parses as an empty client" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // What Hyprland answers when nothing has the focus.
    const window = parse(Client, arena.allocator(), "{}") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", window.address);
    try testing.expectEqualStrings("", window.class);
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
    try testing.expectEqualStrings("fullscreenstate 0 0", full_commands[0]);
    try testing.expectEqual(@as(usize, 3), full_commands.len);
    for ([_]i64{ 1, 2, 3 }) |state| {
        full.fullscreen = state;
        const state_cmds = try layoutCommands(allocator, full, full_monitor, .left_half);
        try testing.expectEqualStrings("fullscreenstate 0 0", state_cmds[0]);
    }

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

test "validAddress accepts only 0x lowercase hex addresses" {
    try testing.expect(validAddress("0x5600000000a0"));
    try testing.expect(!validAddress(""));
    try testing.expect(!validAddress("0x"));
    try testing.expect(!validAddress("0X5600"));
    try testing.expect(!validAddress("0x56;dispatch exec x"));
    try testing.expect(!validAddress("5600"));
}

test "batch flushes queued commands before overflowing and afterFocusChange updates context" {
    dispatch_queue.cancelIdle();
    dispatch_queue.len = 0;
    defer {
        dispatch_queue.cancelIdle();
        dispatch_queue.len = 0;
        focus_waiter.stop();
    }

    const Stub = struct {
        var seq: usize = 0;
        var flush_count: usize = 0;
        var flush_order: usize = 0;
        var direct_count: usize = 0;
        var direct_order: usize = 0;

        fn reset() void {
            seq = 0;
            flush_count = 0;
            flush_order = 0;
            direct_count = 0;
            direct_order = 0;
        }

        fn flush() void {
            seq += 1;
            flush_count += 1;
            flush_order = seq;
            dispatch_queue.len = 0;
        }

        fn direct(_: std.mem.Allocator, _: []const []const u8) void {
            seq += 1;
            direct_count += 1;
            direct_order = seq;
        }
    };

    // 1. Overflow with a command that fits after flushing clears the queue and re-queues.
    Stub.reset();
    var fill_buf: [dispatch_queue_bytes_max - 32]u8 = undefined;
    @memset(&fill_buf, 'x');
    batchWith(testing.allocator, &.{&fill_buf}, &Stub.flush, &Stub.direct);
    try testing.expectEqual(@as(usize, 0), Stub.flush_count);
    try testing.expectEqual(@as(usize, 0), Stub.direct_count);
    try testing.expect(dispatch_queue.len > 0);

    var small_next: [64]u8 = undefined;
    @memset(&small_next, 'y');
    batchWith(testing.allocator, &.{&small_next}, &Stub.flush, &Stub.direct);
    try testing.expectEqual(@as(usize, 1), Stub.flush_count);
    try testing.expectEqual(@as(usize, 0), Stub.direct_count);
    try testing.expect(dispatch_queue.len > 0);

    // 2. Oversized command (> queue capacity) flushes queued commands BEFORE send_direct.
    Stub.reset();
    var big_cmd_buf: [dispatch_queue_bytes_max]u8 = undefined;
    @memset(&big_cmd_buf, 'a');
    batchWith(testing.allocator, &.{&big_cmd_buf}, &Stub.flush, &Stub.direct);
    try testing.expectEqual(@as(usize, 1), Stub.flush_count);
    try testing.expectEqual(@as(usize, 1), Stub.direct_count);
    try testing.expect(Stub.flush_order < Stub.direct_order);
    try testing.expectEqual(@as(usize, 0), dispatch_queue.len);
    dispatch_queue.cancelIdle();

    // 3. afterFocusChange updates context and resets timer on duplicate callback registration.
    const Seen = struct {
        var ctx: usize = 0;
        fn onFocus(value: usize) void {
            ctx = value;
        }
    };
    afterFocusChange(&Seen.onFocus, 1, 5000);
    const first_timer = focus_waiter.timer_source;
    try testing.expect(first_timer != 0);
    afterFocusChange(&Seen.onFocus, 2, 5000);
    try testing.expectEqual(@as(usize, 1), focus_waiter.callbacks_count);
    try testing.expectEqual(@as(usize, 2), focus_waiter.callbacks[0].context);
    try testing.expect(focus_waiter.timer_source != 0);
    try testing.expect(focus_waiter.timer_source != first_timer);
    focus_waiter.fire();
    try testing.expectEqual(@as(usize, 2), Seen.ctx);
}

test "isAllOk accepts concatenated ok replies and rejects errors" {
    try testing.expect(isAllOk("ok"));
    try testing.expect(isAllOk("okokok\n"));
    try testing.expect(!isAllOk(""));
    try testing.expect(!isAllOk("o"));
    try testing.expect(!isAllOk("Invalid dispatcher"));
}

test "dispatchOverFd keeps socket open until peer replies in sync and async modes" {
    defer {
        while (active_replies.items.len > 0) {
            active_replies.items[active_replies.items.len - 1].finish();
        }
        active_replies.deinit(std.heap.c_allocator);
        active_replies = .empty;
    }
    const Peer = struct {
        fd: linux.fd_t,
        reply_ok: bool = false,
        got_msg: bool = false,

        fn run(peer: *@This()) void {
            defer _ = linux.close(peer.fd);
            var buf: [128]u8 = undefined;
            const n = linux.read(peer.fd, &buf, buf.len);
            if (os.unix.failed(n) != null or n == 0) return;
            peer.got_msg = std.mem.eql(u8, buf[0..n], "[[BATCH]]dispatch closewindow");
            os.sleepUs(20 * std.time.us_per_ms);
            const sent = linux.sendto(peer.fd, "ok", 2, linux.MSG.NOSIGNAL, null, 0);
            peer.reply_ok = os.unix.failed(sent) == null and sent == 2;
        }
    };

    for ([_]ReplyMode{ .sync, .async }) |mode| {
        var pair: [2]i32 = undefined;
        try testing.expectEqual(
            linux.E.SUCCESS,
            linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)),
        );
        var peer: Peer = .{ .fd = pair[1] };
        const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});
        try testing.expect(dispatchOverFd(pair[0], "[[BATCH]]dispatch closewindow", mode));
        if (mode == .async) {
            const deadline_ns = os.monotonicNs() + 2 * std.time.ns_per_s;
            while (active_replies.items.len > 0 and os.monotonicNs() < deadline_ns) {
                _ = c.g_main_context_iteration(null, 1);
            }
            try testing.expectEqual(@as(usize, 0), active_replies.items.len);
        }
        thread.join();
        try testing.expect(peer.got_msg);
        try testing.expect(peer.reply_ok);
    }
}
