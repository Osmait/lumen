//! Image files decoded for the window: previews, grid pictures, icons.
//!
//! A 1.1 MB PNG can declare 20000×20000 pixels: 1.2 GB once decoded.
//! gdk-pixbuf cannot be stopped part way any more (with glycin,
//! `size-prepared` comes after the decode and a size of 0 no longer aborts
//! it; scaling on load decodes at full size first), so the size is read
//! from the file's header (image_size.zig) and a larger image is not
//! decoded at all.
//! Previews, grid pictures and rows' icons are decoded on a worker, one at
//! a time.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const os = @import("os");
const image_size = @import("image_size.zig");

pub const Limits = struct {
    bytes: usize,
    pixels: u64,
    /// An SVG's own cap: its size says nothing of what drawing it costs
    /// (parsing, paths, filters).
    svg_bytes: usize,
};

/// Previews, grid pictures and rows' icons: a 48 MP photo fits; 256 MB at most while it
/// decodes, one at a time.
pub const picture_limits: Limits = .{
    .bytes = 64 << 20,
    .pixels = 8192 * 8192,
    .svg_bytes = 8 << 20,
};

/// What `decodeImage` reads before it looks at the header: where every
/// format `image_size` knows keeps its size, but for a JPEG with more
/// metadata than this (then the whole file is read and looked at again).
const header_probe_bytes = 64 << 10;

/// `path` decoded to fit `width_px`×`height_px` (never larger than it is), or null: not a
/// regular file, over `limits`, or not an image whose size `image_size`
/// reads (SVG excepted: it is drawn at the size asked for, which must be
/// within `limits.pixels`, from no more than `limits.svg_bytes`). Thread-safe.
/// The bytes come from a descriptor opened non-blocking and checked to be a
/// regular file: decoding by path opened the file again, and a FIFO swapped
/// in meanwhile blocked forever.
pub fn decodeImage(
    path: [*:0]const u8,
    width_px: c_int,
    height_px: c_int,
    limits: Limits,
) ?*c.GdkPixbuf {
    const gpa = std.heap.c_allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    {
        const fd = os.openRegular(path) catch return null;
        defer os.close(fd);
        // The header first: an image over the pixel limit is refused
        // without reading the whole file (a 4 MB photo for a 32 px icon).
        const head_bytes = @min(limits.bytes + 1, header_probe_bytes);
        os.readUpTo(gpa, fd, &data, head_bytes) catch return null;
        if (data.items.len == head_bytes) {
            if (image_size.read(data.items)) |size| {
                if (size.width_px * size.height_px > limits.pixels) return null;
            }
            os.readUpTo(gpa, fd, &data, limits.bytes + 1) catch return null;
        }
    }
    if (data.items.len > limits.bytes) return null;
    const size = decodeSize(data.items, width_px, height_px, limits) orelse return null;
    const stream = c.g_memory_input_stream_new_from_data(
        data.items.ptr,
        @intCast(data.items.len),
        null,
    );
    defer c.g_object_unref(stream);
    return c.gdk_pixbuf_new_from_stream_at_scale(stream, size[0], size[1], 1, null, null);
}

/// Width and height to decode `data` at, within `width_px`×`height_px`; null: not to be
/// decoded.
fn decodeSize(data: []const u8, width_px: c_int, height_px: c_int, limits: Limits) ?[2]c_int {
    if (image_size.read(data)) |size| {
        if (size.width_px * size.height_px > limits.pixels) return null;
        // GTK scales up as it draws; a bigger copy would only cost memory.
        return .{
            @intCast(@min(size.width_px, @as(u64, @intCast(width_px)))),
            @intCast(@min(size.height_px, @as(u64, @intCast(height_px)))),
        };
    }
    if (!isSvg(data)) return null;
    // Drawn at the size asked for, whatever width and height it declares:
    // that size, and the text drawn from, are what it costs.
    if (data.len > limits.svg_bytes) return null;
    if (width_px <= 0 or height_px <= 0) return null;
    const pixels = @as(u64, @intCast(width_px)) * @as(u64, @intCast(height_px));
    if (pixels > limits.pixels) return null;
    return .{ width_px, height_px };
}

/// How far into a file `isSvg` looks for the `<svg` tag: past an XML
/// declaration, a doctype and comments, which come first.
const svg_sniff_bytes_max = 4096;

/// Whether `data` starts like an SVG document.
fn isSvg(data: []const u8) bool {
    const head = data[0..@min(data.len, svg_sniff_bytes_max)];
    const text = std.mem.trimStart(u8, head, " \t\r\n\xef\xbb\xbf");
    return std.mem.startsWith(u8, text, "<") and std.mem.find(u8, head, "<svg") != null;
}

/// What a picture is for. Moving it on (`forget`) drops the requests made
/// for it before that are not decoded yet: the selection moved, the grid
/// was built again. Read by the decoding thread.
pub const Lane = struct {
    generation: std.atomic.Value(u32) = .init(0),

    /// Requests made so far are no longer wanted.
    pub fn forget(lane: *Lane) void {
        _ = lane.generation.fetchAdd(1, .release);
    }

    fn current(lane: *const Lane) u32 {
        return lane.generation.load(.acquire);
    }
};

// The decoder is one per process, like the GTask pool it runs on: its two
// lanes and its queue below are module state, used from the main thread
// only (the workers hand back through it).

/// The detail pane's image preview.
pub var preview_lane: Lane = .{};
/// The grid's cell pictures.
pub var grid_lane: Lane = .{};
/// Rows' icons given as image files (dmenu's `icon\x1f/path`, an
/// extension's `icon = "/path"`).
pub var icon_lane: Lane = .{};

/// Called on the main thread once per request with the picture (borrowed:
/// take a reference to keep it) or null. `current`: its lane has not moved
/// on since it was asked; when it has, a null may only mean it was dropped.
pub const Done = *const fn (context: ?*anyopaque, pixbuf: ?*c.GdkPixbuf, current: bool) void;

const Request = struct {
    path: [:0]u8,
    width_px: c_int,
    height_px: c_int,
    lane: *Lane,
    generation: u32,
    done: Done,
    context: ?*anyopaque,
};

/// Requests not started yet, and whether one is decoding (main thread).
/// One at a time: each can take `picture_limits` × 4 bytes while it
/// decodes, and GLib's pool ran one per selection change at once (an
/// arrow key held over a folder of photos).
var waiting: std.ArrayList(*Request) = .empty;
var decoding = false;

/// Where a request joins the queue: a preview goes ahead of what waits
/// (it is what is being looked at), grid pictures behind.
pub const QueuePlace = enum { front, back };

/// Decodes `path` to fit `width_px`×`height_px` on a worker thread, within
/// `picture_limits`, and calls `done`. Main thread.
pub fn requestPicture(
    path: []const u8,
    width_px: c_int,
    height_px: c_int,
    lane: *Lane,
    place: QueuePlace,
    done: Done,
    context: ?*anyopaque,
) void {
    os.assertMainThread();
    // A size of 0 would make the decoder scale to nothing.
    assert(width_px > 0);
    assert(height_px > 0);
    const gpa = std.heap.c_allocator;
    // Out of memory: as good as dropped (nothing is learnt about the file).
    const request = gpa.create(Request) catch return done(context, null, false);
    request.* = .{
        .path = gpa.dupeSentinel(u8, path, 0) catch {
            gpa.destroy(request);
            return done(context, null, false);
        },
        .width_px = width_px,
        .height_px = height_px,
        .lane = lane,
        .generation = lane.current(),
        .done = done,
        .context = context,
    };
    const queued = switch (place) {
        .front => waiting.insert(gpa, 0, request),
        .back => waiting.append(gpa, request),
    };
    queued catch return finishRequest(request, null, false);
    startNext();
}

fn startNext() void {
    os.assertMainThread();
    while (!decoding and waiting.items.len > 0) {
        const request = waiting.orderedRemove(0);
        if (request.generation != request.lane.current()) {
            finishRequest(request, null, false);
            continue;
        }
        decoding = true;
        const task = c.g_task_new(null, null, &onDecoded, request);
        c.g_task_set_task_data(task, request, null);
        c.g_task_run_in_thread(task, &decodeRequest);
        c.g_object_unref(task);
    }
}

fn decodeRequest(
    task: *c.GTask,
    _: ?*c.GObject,
    data: ?*anyopaque,
    _: ?*c.GCancellable,
) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(data.?));
    // Its lane moved on while it waited for a thread.
    if (request.generation != request.lane.current()) {
        return c.g_task_return_pointer(task, null, null);
    }
    const pixbuf = decodeImage(
        request.path.ptr,
        request.width_px,
        request.height_px,
        picture_limits,
    );
    c.g_task_return_pointer(task, pixbuf, &unrefObject);
}

fn unrefObject(pointer: ?*anyopaque) callconv(.c) void {
    if (pointer) |object| c.g_object_unref(object);
}

fn onDecoded(_: ?*c.GObject, result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    os.assertMainThread();
    const request: *Request = @ptrCast(@alignCast(data.?));
    decoding = false;
    const pixbuf: ?*c.GdkPixbuf = @ptrCast(c.g_task_propagate_pointer(@ptrCast(result), null));
    defer unrefObject(pixbuf);
    finishRequest(request, pixbuf, request.generation == request.lane.current());
    startNext();
}

/// Drops pending requests and forgets all picture lanes at shutdown so in-flight
/// worker results are ignored once the UI tears down. Main thread.
pub fn shutdown() void {
    os.assertMainThread();
    preview_lane.forget();
    grid_lane.forget();
    icon_lane.forget();
    while (waiting.items.len > 0) {
        const request = waiting.orderedRemove(0);
        finishRequest(request, null, false);
    }
    waiting.deinit(std.heap.c_allocator);
    waiting = .empty;
}

fn finishRequest(request: *Request, pixbuf: ?*c.GdkPixbuf, current: bool) void {
    const gpa = std.heap.c_allocator;
    defer {
        gpa.free(request.path);
        gpa.destroy(request);
    }
    request.done(request.context, pixbuf, current);
}

test "a picture over the limits is never decoded" {
    const testing = std.testing;
    const limits: Limits = .{ .bytes = 1 << 20, .pixels = 4096 * 4096, .svg_bytes = 64 << 10 };
    const bomb = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x4e\x20\x00\x00\x4e\x20\x08\x02";
    try testing.expect(decodeSize(bomb, 512, 512, limits) == null);
    // Within the limits: never decoded larger than it is.
    const small = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x10\x00\x00\x00\x20\x08\x02";
    try testing.expectEqual([2]c_int{ 16, 32 }, decodeSize(small, 512, 512, limits).?);
    try testing.expectEqual([2]c_int{ 16, 20 }, decodeSize(small, 512, 20, limits).?);
    // SVG is drawn at the size asked for; an unknown format is not decoded.
    const svg = "\xef\xbb\xbf<?xml version=\"1.0\"?>\n<svg width=\"30000\" height=\"30000\"/>";
    try testing.expectEqual([2]c_int{ 64, 64 }, decodeSize(svg, 64, 64, limits).?);
    // ...but not at a size over the pixel limit, nor from too much text.
    try testing.expect(decodeSize(svg, 8192, 8192, limits) == null);
    try testing.expect(decodeSize(svg, 0, 64, limits) == null);
    const svg_big = try testing.allocator.alloc(u8, limits.svg_bytes + 1);
    defer testing.allocator.free(svg_big);
    @memset(svg_big, ' ');
    @memcpy(svg_big[0..svg.len], svg);
    try testing.expect(decodeSize(svg_big, 64, 64, limits) == null);
    try testing.expect(decodeSize("P6 30000 30000 255 ", 64, 64, limits) == null);

    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    var path_bytes: [4096]u8 = undefined;
    // Refused from its header: gdk-pixbuf is never called.
    try test_dir.write("bomb.png", bomb);
    const bomb_path = try test_dir.path(&path_bytes, "bomb.png");
    try testing.expect(decodeImage(bomb_path, 64, 64, limits) == null);
    // A file larger than `bytes` is not decoded either.
    const big = try testing.allocator.alloc(u8, limits.bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 0);
    @memcpy(big[0..small.len], small);
    try test_dir.write("big.png", big);
    const big_path = try test_dir.path(&path_bytes, "big.png");
    try testing.expect(decodeImage(big_path, 64, 64, limits) == null);
    // Larger than the header probe: refused from its first bytes alone.
    const padded = try testing.allocator.alloc(u8, header_probe_bytes * 2);
    defer testing.allocator.free(padded);
    @memset(padded, 0);
    @memcpy(padded[0..bomb.len], bomb);
    try test_dir.write("padded.png", padded);
    const padded_path = try test_dir.path(&path_bytes, "padded.png");
    try testing.expect(decodeImage(padded_path, 64, 64, limits) == null);
    // A FIFO named like a picture: refused at once, not waited on.
    const fifo = try test_dir.path(&path_bytes, "fifo.png");
    try testing.expect(std.os.linux.mknod(fifo, std.os.linux.S.IFIFO | 0o600, 0) == 0);
    try testing.expect(decodeImage(fifo, 64, 64, limits) == null);
}

test {
    _ = image_size;
}

test "pictures shutdown forgets lanes and drains queued requests" {
    const Counter = struct {
        called: usize = 0,
        last_current: bool = true,
        fn cb(context: ?*anyopaque, _: ?*c.GdkPixbuf, is_current: bool) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.called += 1;
            self.last_current = is_current;
        }
    };
    const gpa = std.heap.c_allocator;
    var counter: Counter = .{};
    const req = try gpa.create(Request);
    req.* = .{
        .path = try gpa.dupeSentinel(u8, "/tmp/nonexistent.png", 0),
        .width_px = 32,
        .height_px = 32,
        .lane = &preview_lane,
        .generation = preview_lane.current(),
        .done = &Counter.cb,
        .context = &counter,
    };
    const gen_before = preview_lane.current();
    try waiting.append(gpa, req);
    shutdown();
    try std.testing.expect(preview_lane.current() != gen_before);
    try std.testing.expectEqual(@as(usize, 0), waiting.items.len);
    try std.testing.expectEqual(@as(usize, 1), counter.called);
    try std.testing.expect(!counter.last_current);
}
