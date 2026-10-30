//! Image files decoded for the window: previews, grid pictures, icons.
//!
//! A 1.1 MB PNG can declare 20000×20000 pixels: 1.2 GB once decoded.
//! gdk-pixbuf cannot be stopped part way any more (with glycin,
//! `size-prepared` comes after the decode and a size of 0 no longer aborts
//! it; scaling on load decodes at full size first), so the size is read
//! from the file's header and a larger image is not decoded at all.
//! Previews and grid pictures are decoded on a worker, one at a time.

const std = @import("std");
const c = @import("c");
const os = @import("os");

pub const Limits = struct { bytes: usize, pixels: u64 };

/// Previews and grid pictures: a 48 MP photo fits; 256 MB at most while it
/// decodes, one at a time.
pub const picture_limits: Limits = .{ .bytes = 64 << 20, .pixels = 8192 * 8192 };
/// Icons in rows, decoded on the UI thread.
pub const icon_limits: Limits = .{ .bytes = 4 << 20, .pixels = 2048 * 2048 };

/// `path` decoded to fit `w`×`h` (never larger than it is), or null: not a
/// regular file, over `limits`, or not an image whose size `imageSize`
/// reads (SVG excepted: it is drawn at the size asked for). Thread-safe.
/// The bytes come from a descriptor opened non-blocking and checked to be a
/// regular file: decoding by path opened the file again, and a FIFO swapped
/// in meanwhile blocked forever.
pub fn decodeImage(path: [*:0]const u8, w: c_int, h: c_int, limits: Limits) ?*c.GdkPixbuf {
    const gpa = std.heap.c_allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    {
        const fd = os.openRegular(path) catch return null;
        defer os.close(fd);
        os.readUpTo(gpa, fd, &data, limits.bytes + 1) catch return null;
    }
    if (data.items.len > limits.bytes) return null;
    const size = decodeSize(data.items, w, h, limits) orelse return null;
    const stream = c.g_memory_input_stream_new_from_data(
        data.items.ptr,
        @intCast(data.items.len),
        null,
    );
    defer c.g_object_unref(stream);
    return c.gdk_pixbuf_new_from_stream_at_scale(stream, size[0], size[1], 1, null, null);
}

/// Width and height to decode `data` at, within `w`×`h`; null: not to be
/// decoded.
fn decodeSize(data: []const u8, w: c_int, h: c_int, limits: Limits) ?[2]c_int {
    if (imageSize(data)) |s| {
        if (s.w * s.h > limits.pixels) return null;
        // GTK scales up as it draws; a bigger copy would only cost memory.
        return .{
            @intCast(@min(s.w, @as(u64, @intCast(w)))),
            @intCast(@min(s.h, @as(u64, @intCast(h)))),
        };
    }
    return if (isSvg(data)) .{ w, h } else null;
}

fn isSvg(data: []const u8) bool {
    const head = data[0..@min(data.len, 4096)];
    const text = std.mem.trimStart(u8, head, " \t\r\n\xef\xbb\xbf");
    return std.mem.startsWith(u8, text, "<") and std.mem.find(u8, head, "<svg") != null;
}

pub const Size = struct { w: u64, h: u64 };

/// The size an image file declares, which is what a decoder allocates:
/// PNG, JPEG, GIF (every frame), WebP, BMP, TIFF (every directory),
/// HEIF/AVIF and QOI. Null for anything else, or a size of zero.
pub fn imageSize(data: []const u8) ?Size {
    const s = headerSize(data) orelse return null;
    return if (s.w == 0 or s.h == 0) null else s;
}

fn headerSize(d: []const u8) ?Size {
    const starts = std.mem.startsWith;
    if (starts(u8, d, "\x89PNG\r\n\x1a\n")) {
        if (d.len < 24 or !std.mem.eql(u8, d[12..16], "IHDR")) return null;
        return .{ .w = int(u32, d, 16, .big).?, .h = int(u32, d, 20, .big).? };
    }
    if (starts(u8, d, "\xff\xd8")) return jpegSize(d);
    if (starts(u8, d, "GIF87a") or starts(u8, d, "GIF89a")) return gifSize(d);
    if (starts(u8, d, "RIFF") and d.len >= 12 and std.mem.eql(u8, d[8..12], "WEBP")) {
        return webpSize(d);
    }
    if (starts(u8, d, "BM")) {
        // OS/2 1.x headers hold 16-bit sizes; later ones signed 32-bit
        // (negative: stored top-down).
        if ((int(u32, d, 14, .little) orelse return null) == 12) return .{
            .w = int(u16, d, 18, .little) orelse return null,
            .h = int(u16, d, 20, .little) orelse return null,
        };
        return .{
            .w = @abs(int(i32, d, 18, .little) orelse return null),
            .h = @abs(int(i32, d, 22, .little) orelse return null),
        };
    }
    if (starts(u8, d, "II*\x00")) return tiffSize(d, .little);
    if (starts(u8, d, "MM\x00*")) return tiffSize(d, .big);
    if (starts(u8, d, "qoif")) {
        if (d.len < 12) return null;
        return .{ .w = int(u32, d, 4, .big).?, .h = int(u32, d, 8, .big).? };
    }
    if (d.len >= 8 and std.mem.eql(u8, d[4..8], "ftyp")) {
        var s: Size = .{ .w = 0, .h = 0 };
        heifSizes(d, 0, d.len, 0, &s);
        return s;
    }
    return null;
}

/// A `T` at `at`, or null past the end.
fn int(comptime T: type, d: []const u8, at: usize, endian: std.builtin.Endian) ?T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    if (at > d.len or d.len - at < n) return null;
    return std.mem.readInt(T, d[at..][0..n], endian);
}

/// The first frame header (SOFn), past the segments before it (EXIF and
/// its thumbnail included).
fn jpegSize(d: []const u8) ?Size {
    var i: usize = 2;
    while (i + 4 <= d.len) {
        if (d[i] != 0xff) return null;
        const marker = d[i + 1];
        switch (marker) {
            // Fill byte; markers without a length.
            0xff => i += 1,
            0x01, 0xd0...0xd8 => i += 2,
            // The image data or its end, and no frame header before them.
            0xd9, 0xda => return null,
            else => {
                // Every SOFn but DHT (c4), JPG (c8) and DAC (cc).
                if (marker >= 0xc0 and marker <= 0xcf and
                    marker != 0xc4 and marker != 0xc8 and marker != 0xcc)
                {
                    return .{
                        .w = int(u16, d, i + 7, .big) orelse return null,
                        .h = int(u16, d, i + 5, .big) orelse return null,
                    };
                }
                const len = int(u16, d, i + 2, .big) orelse return null;
                if (len < 2) return null;
                i += 2 + len;
            },
        }
    }
    return null;
}

/// The logical screen, grown to hold every frame: a frame can be larger.
fn gifSize(d: []const u8) ?Size {
    if (d.len < 13) return null;
    var s: Size = .{
        .w = int(u16, d, 6, .little) orelse return null,
        .h = int(u16, d, 8, .little) orelse return null,
    };
    var i: usize = 13;
    if (d[10] & 0x80 != 0) i += @as(usize, 3) << @intCast((d[10] & 7) + 1);
    while (i < d.len) switch (d[i]) {
        // An image: left, top, width, height, then its colour table and data.
        0x2c => {
            const left = int(u16, d, i + 1, .little) orelse break;
            const top = int(u16, d, i + 3, .little) orelse break;
            s.w = @max(s.w, @as(u64, left) + (int(u16, d, i + 5, .little) orelse break));
            s.h = @max(s.h, @as(u64, top) + (int(u16, d, i + 7, .little) orelse break));
            const flags = if (i + 9 < d.len) d[i + 9] else break;
            i += 10;
            if (flags & 0x80 != 0) i += @as(usize, 3) << @intCast((flags & 7) + 1);
            // The LZW code size, then the data.
            i = skipGifBlocks(d, i + 1) orelse break;
        },
        0x21 => i = skipGifBlocks(d, i + 2) orelse break,
        // The trailer, or something no decoder reads past either.
        else => break,
    };
    return s;
}

fn skipGifBlocks(d: []const u8, from: usize) ?usize {
    var i = from;
    while (i < d.len) {
        const n = d[i];
        i += 1 + @as(usize, n);
        if (n == 0) return i;
    }
    return null;
}

fn webpSize(d: []const u8) ?Size {
    const chunk = d[12..@min(d.len, 16)];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        // A key frame: 3 bytes of tag, a start code, 14-bit sizes.
        if (!std.mem.eql(u8, d[@min(d.len, 23)..@min(d.len, 26)], "\x9d\x01\x2a")) return null;
        return .{
            .w = (int(u16, d, 26, .little) orelse return null) & 0x3fff,
            .h = (int(u16, d, 28, .little) orelse return null) & 0x3fff,
        };
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (d.len < 25 or d[20] != 0x2f) return null;
        const bits = int(u32, d, 21, .little) orelse return null;
        return .{ .w = (bits & 0x3fff) + 1, .h = ((bits >> 14) & 0x3fff) + 1 };
    }
    if (std.mem.eql(u8, chunk, "VP8X")) return .{
        .w = @as(u64, int(u24, d, 24, .little) orelse return null) + 1,
        .h = @as(u64, int(u24, d, 27, .little) orelse return null) + 1,
    };
    return null;
}

/// The largest width and height in any directory (pages, reduced copies).
fn tiffSize(d: []const u8, endian: std.builtin.Endian) ?Size {
    var s: Size = .{ .w = 0, .h = 0 };
    var at: usize = int(u32, d, 4, endian) orelse return null;
    // Directories link to the next; a loop is cut short.
    var dirs: usize = 0;
    while (at != 0 and dirs < 64) : (dirs += 1) {
        const count = int(u16, d, at, endian) orelse break;
        for (0..count) |e| {
            const entry = at + 2 + e * 12;
            const tag = int(u16, d, entry, endian) orelse break;
            if (tag != 256 and tag != 257) continue;
            // SHORT or LONG.
            const value: u64 = switch (int(u16, d, entry + 2, endian) orelse break) {
                3 => int(u16, d, entry + 8, endian) orelse break,
                4 => int(u32, d, entry + 8, endian) orelse break,
                else => continue,
            };
            if (tag == 256) s.w = @max(s.w, value) else s.h = @max(s.h, value);
        }
        at = int(u32, d, at + 2 + @as(usize, count) * 12, endian) orelse break;
    }
    return s;
}

/// HEIF and AVIF keep each image's size in an `ispe` box (meta, iprp,
/// ipco); a picture made of tiles has one for the whole. The largest.
fn heifSizes(d: []const u8, from: usize, end: usize, depth: u8, s: *Size) void {
    if (depth > 4) return;
    var i = from;
    while (i + 8 <= end) {
        var size: u64 = int(u32, d, i, .big) orelse return;
        var header: usize = 8;
        if (size == 1) {
            size = int(u64, d, i + 8, .big) orelse return;
            header = 16;
        } else if (size == 0) size = end - i;
        if (size < header or size > end - i) return;
        const kind = d[i + 4 .. i + 8];
        const body = i + header;
        const next = i + @as(usize, @intCast(size));
        if (std.mem.eql(u8, kind, "meta")) {
            // A full box: version and flags first.
            heifSizes(d, body + 4, next, depth + 1, s);
        } else if (std.mem.eql(u8, kind, "iprp") or std.mem.eql(u8, kind, "ipco")) {
            heifSizes(d, body, next, depth + 1, s);
        } else if (std.mem.eql(u8, kind, "ispe") and next >= body + 12) {
            s.w = @max(s.w, int(u32, d, body + 4, .big).?);
            s.h = @max(s.h, int(u32, d, body + 8, .big).?);
        }
        i = next;
    }
}

/// What a picture is for. Moving it on (`forget`) drops the requests made
/// for it before that are not decoded yet: the selection moved, the grid
/// was built again. Read by the decoding thread.
pub const Lane = struct {
    gen: std.atomic.Value(u32) = .init(0),

    pub fn forget(l: *Lane) void {
        _ = l.gen.fetchAdd(1, .release);
    }

    fn current(l: *const Lane) u32 {
        return l.gen.load(.acquire);
    }
};

/// The detail pane's image preview.
pub var preview_lane: Lane = .{};
pub var grid_lane: Lane = .{};

/// Called on the main thread once per request with the picture (borrowed:
/// take a reference to keep it) or null. `current`: its lane has not moved
/// on since it was asked; when it has, a null may only mean it was dropped.
pub const Done = *const fn (ctx: ?*anyopaque, pixbuf: ?*c.GdkPixbuf, current: bool) void;

const Request = struct {
    path: [:0]u8,
    w: c_int,
    h: c_int,
    lane: *Lane,
    gen: u32,
    done: Done,
    ctx: ?*anyopaque,
};

/// Requests not started yet, and whether one is decoding (main thread).
/// One at a time: each can take `picture_limits` × 4 bytes while it
/// decodes, and GLib's pool ran one per selection change at once (an
/// arrow key held over a folder of photos).
var waiting: std.ArrayList(*Request) = .empty;
var decoding = false;

/// Decodes `path` to fit `w`×`h` on a worker thread, within
/// `picture_limits`, and calls `done`. `first` goes ahead of what waits
/// (the preview being looked at). Main thread.
pub fn requestPicture(
    path: []const u8,
    w: c_int,
    h: c_int,
    lane: *Lane,
    first: bool,
    done: Done,
    ctx: ?*anyopaque,
) void {
    const gpa = std.heap.c_allocator;
    // Out of memory: as good as dropped (nothing is learnt about the file).
    const r = gpa.create(Request) catch return done(ctx, null, false);
    r.* = .{
        .path = gpa.dupeSentinel(u8, path, 0) catch {
            gpa.destroy(r);
            return done(ctx, null, false);
        },
        .w = w,
        .h = h,
        .lane = lane,
        .gen = lane.current(),
        .done = done,
        .ctx = ctx,
    };
    (if (first) waiting.insert(gpa, 0, r) else waiting.append(gpa, r)) catch
        return finishRequest(r, null, false);
    startNext();
}

fn startNext() void {
    while (!decoding and waiting.items.len > 0) {
        const r = waiting.orderedRemove(0);
        if (r.gen != r.lane.current()) {
            finishRequest(r, null, false);
            continue;
        }
        decoding = true;
        const task = c.g_task_new(null, null, &onDecoded, r);
        c.g_task_set_task_data(task, r, null);
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
    const r: *Request = @ptrCast(@alignCast(data.?));
    // Its lane moved on while it waited for a thread.
    if (r.gen != r.lane.current()) return c.g_task_return_pointer(task, null, null);
    const pb = decodeImage(r.path.ptr, r.w, r.h, picture_limits);
    c.g_task_return_pointer(task, pb, &unrefObject);
}

fn unrefObject(p: ?*anyopaque) callconv(.c) void {
    if (p) |o| c.g_object_unref(o);
}

fn onDecoded(_: ?*c.GObject, res: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const r: *Request = @ptrCast(@alignCast(data.?));
    decoding = false;
    const pb: ?*c.GdkPixbuf = @ptrCast(c.g_task_propagate_pointer(@ptrCast(res), null));
    defer unrefObject(pb);
    finishRequest(r, pb, r.gen == r.lane.current());
    startNext();
}

fn finishRequest(r: *Request, pb: ?*c.GdkPixbuf, current: bool) void {
    const gpa = std.heap.c_allocator;
    defer {
        gpa.free(r.path);
        gpa.destroy(r);
    }
    r.done(r.ctx, pb, current);
}

test "image sizes are read from headers" {
    const t = std.testing;
    // PNG: IHDR right after the signature.
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x4e\x20\x00\x00\x4e\x20\x08\x02";
    try t.expectEqual(Size{ .w = 20000, .h = 20000 }, imageSize(png).?);
    // JPEG: an APP1 segment, then SOF0 (height before width).
    const jpeg = "\xff\xd8\xff\xe1\x00\x04ab\xff\xc0\x00\x11\x08\x0b\xb8\x0f\xa0\x03";
    try t.expectEqual(Size{ .w = 4000, .h = 3000 }, imageSize(jpeg).?);
    try t.expect(imageSize("\xff\xd8\xff\xda\x00\x04") == null);
    // GIF: a 1×1 screen, a 300×200 frame at (10, 5).
    const gif = "GIF89a\x01\x00\x01\x00\x00\x00\x00" ++
        "\x2c\x0a\x00\x05\x00\x2c\x01\xc8\x00\x00\x02\x01\x00\x00\x3b";
    try t.expectEqual(Size{ .w = 310, .h = 205 }, imageSize(gif).?);
    // WebP, lossless: 14 bits each, minus one.
    const webp = "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\x2f" ++ "\x63\x00\x19\x00";
    try t.expectEqual(Size{ .w = 100, .h = 101 }, imageSize(webp).?);
    const webpx = "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00" ++
        "\x1f\x4e\x00\x1f\x4e\x00";
    try t.expectEqual(Size{ .w = 20000, .h = 20000 }, imageSize(webpx).?);
    // BMP, stored top-down.
    const bmp = "BM" ++ @as([12]u8, @splat(0)) ++ "\x28\x00\x00\x00" ++ "\x20\x4e\x00\x00" ++
        "\xe0\xb1\xff\xff";
    try t.expectEqual(Size{ .w = 20000, .h = 20000 }, imageSize(bmp).?);
    // TIFF, little-endian: one directory, width SHORT, height LONG.
    const tiff = "II*\x00\x08\x00\x00\x00" ++ "\x02\x00" ++
        "\x00\x01\x03\x00\x01\x00\x00\x00\x40\x1f\x00\x00" ++
        "\x01\x01\x04\x00\x01\x00\x00\x00\x40\x1f\x00\x00" ++ "\x00\x00\x00\x00";
    try t.expectEqual(Size{ .w = 8000, .h = 8000 }, imageSize(tiff).?);
    // HEIF: ftyp, then meta > iprp > ipco > ispe.
    const ispe = "\x00\x00\x00\x14ispe\x00\x00\x00\x00\x00\x00\x30\x00\x00\x00\x20\x00";
    const ipco = "\x00\x00\x00\x1cipco" ++ ispe;
    const iprp = "\x00\x00\x00\x24iprp" ++ ipco;
    const heif = "\x00\x00\x00\x10ftypheic\x00\x00\x00\x00" ++
        "\x00\x00\x00\x30meta\x00\x00\x00\x00" ++ iprp;
    try t.expectEqual(Size{ .w = 0x3000, .h = 0x2000 }, imageSize(heif).?);
    // Not an image, cut short, or empty.
    try t.expect(imageSize("hello") == null);
    try t.expect(imageSize(png[0..20]) == null);
    try t.expect(imageSize("GIF89a\x00\x00\x00\x00\x00\x00\x00") == null);
}

test "a picture over the limits is never decoded" {
    const t = std.testing;
    const limits: Limits = .{ .bytes = 1 << 20, .pixels = 4096 * 4096 };
    const bomb = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x4e\x20\x00\x00\x4e\x20\x08\x02";
    try t.expect(decodeSize(bomb, 512, 512, limits) == null);
    // Within the limits: never decoded larger than it is.
    const small = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x10\x00\x00\x00\x20\x08\x02";
    try t.expectEqual([2]c_int{ 16, 32 }, decodeSize(small, 512, 512, limits).?);
    try t.expectEqual([2]c_int{ 16, 20 }, decodeSize(small, 512, 20, limits).?);
    // SVG is drawn at the size asked for; an unknown format is not decoded.
    const svg = "\xef\xbb\xbf<?xml version=\"1.0\"?>\n<svg width=\"30000\" height=\"30000\"/>";
    try t.expectEqual([2]c_int{ 64, 64 }, decodeSize(svg, 64, 64, limits).?);
    try t.expect(decodeSize("P6 30000 30000 255 ", 64, 64, limits) == null);

    var dir: os.TestDir = try .init();
    defer dir.deinit();
    var buf: [4096]u8 = undefined;
    // Refused from its header: gdk-pixbuf is never called.
    try dir.write("bomb.png", bomb);
    try t.expect(decodeImage(try dir.path(&buf, "bomb.png"), 64, 64, limits) == null);
    // Larger than `bytes`.
    const big = try t.allocator.alloc(u8, limits.bytes + 1);
    defer t.allocator.free(big);
    @memset(big, 0);
    @memcpy(big[0..small.len], small);
    try dir.write("big.png", big);
    try t.expect(decodeImage(try dir.path(&buf, "big.png"), 64, 64, limits) == null);
    // A FIFO named like a picture: refused at once, not waited on.
    const fifo = try dir.path(&buf, "fifo.png");
    try t.expect(std.os.linux.mknod(fifo, std.os.linux.S.IFIFO | 0o600, 0) == 0);
    try t.expect(decodeImage(fifo, 64, 64, limits) == null);
}
