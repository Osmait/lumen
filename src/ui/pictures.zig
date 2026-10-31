//! Image files decoded for the window: previews, grid pictures, icons.
//!
//! A 1.1 MB PNG can declare 20000×20000 pixels: 1.2 GB once decoded.
//! gdk-pixbuf cannot be stopped part way any more (with glycin,
//! `size-prepared` comes after the decode and a size of 0 no longer aborts
//! it; scaling on load decodes at full size first), so the size is read
//! from the file's header and a larger image is not decoded at all.
//! Previews and grid pictures are decoded on a worker, one at a time.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const os = @import("os");

pub const Limits = struct { bytes: usize, pixels: u64 };

/// Previews and grid pictures: a 48 MP photo fits; 256 MB at most while it
/// decodes, one at a time.
pub const picture_limits: Limits = .{ .bytes = 64 << 20, .pixels = 8192 * 8192 };
/// Icons in rows, decoded on the UI thread.
pub const icon_limits: Limits = .{ .bytes = 4 << 20, .pixels = 2048 * 2048 };

/// `path` decoded to fit `width_px`×`height_px` (never larger than it is), or null: not a
/// regular file, over `limits`, or not an image whose size `imageSize`
/// reads (SVG excepted: it is drawn at the size asked for). Thread-safe.
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
        os.readUpTo(gpa, fd, &data, limits.bytes + 1) catch return null;
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
    if (imageSize(data)) |size| {
        if (size.width_px * size.height_px > limits.pixels) return null;
        // GTK scales up as it draws; a bigger copy would only cost memory.
        return .{
            @intCast(@min(size.width_px, @as(u64, @intCast(width_px)))),
            @intCast(@min(size.height_px, @as(u64, @intCast(height_px)))),
        };
    }
    return if (isSvg(data)) .{ width_px, height_px } else null;
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

pub const Size = struct { width_px: u64, height_px: u64 };

/// The size an image file declares, which is what a decoder allocates:
/// PNG, JPEG, GIF (every frame), WebP, BMP, TIFF (every directory),
/// HEIF/AVIF and QOI. Null for anything else, or a size of zero.
pub fn imageSize(data: []const u8) ?Size {
    const size = headerSize(data) orelse return null;
    return if (size.width_px == 0 or size.height_px == 0) null else size;
}

/// Where each format keeps what `headerSize` reads, as byte offsets from the
/// start of the file (or of the structure named), from each format's
/// specification.
const png = struct {
    const signature = "\x89PNG\r\n\x1a\n";
    /// The first chunk must be IHDR: its type, then width and height.
    const ihdr_type_offset = 12;
    const ihdr_type = "IHDR";
    const width_offset = 16;
    const height_offset = 20;
    const header_bytes = 24;
};

const bmp = struct {
    const signature = "BM";
    /// The info header's own size says which kind it is.
    const info_size_offset = 14;
    /// OS/2 1.x: 16-bit width and height.
    const os2_info_size = 12;
    const os2_width_offset = 18;
    const os2_height_offset = 20;
    /// Windows and later: signed 32-bit, negative height for top-down.
    const width_offset = 18;
    const height_offset = 22;
};

const qoi = struct {
    const signature = "qoif";
    const width_offset = 4;
    const height_offset = 8;
    const header_bytes = 12;
};

const riff = struct {
    const signature = "RIFF";
    const form_offset = 8;
    const webp_form = "WEBP";
    /// The first chunk's type (VP8, VP8L or VP8X) follows the form.
    const chunk_type_offset = 12;
    const chunk_type_bytes = 4;
};

/// ISO base media (HEIF, AVIF): a box's size, then its type.
const iso_box = struct {
    const type_offset = 4;
    const ftyp = "ftyp";
    const header_bytes = 8;
    /// A size of 1: a 64-bit size follows the type.
    const large_size_marker = 1;
    const large_header_bytes = 16;
    /// A size of 0: the box runs to the end of its parent.
    const to_end_marker = 0;
    /// A full box (meta) has its version and flags before its children.
    const full_box_bytes = 4;
    /// `ispe`: version and flags, then width and height.
    const ispe_width_offset = 4;
    const ispe_height_offset = 8;
    const ispe_bytes = 12;
    /// The boxes on the way to an image's size, and the size itself.
    const meta = "meta";
    const item_properties = "iprp";
    const property_container = "ipco";
    const spatial_extent = "ispe";
    /// Boxes nest at most this deep before `ispe` (meta, iprp, ipco): a
    /// deeper file is cut short, not followed.
    const depth_max = 4;
};

fn headerSize(data: []const u8) ?Size {
    const starts = std.mem.startsWith;
    if (starts(u8, data, png.signature)) {
        if (data.len < png.header_bytes) return null;
        const ihdr = data[png.ihdr_type_offset..][0..png.ihdr_type.len];
        if (!std.mem.eql(u8, ihdr, png.ihdr_type)) return null;
        return .{
            .width_px = int(u32, data, png.width_offset, .big).?,
            .height_px = int(u32, data, png.height_offset, .big).?,
        };
    }
    if (starts(u8, data, jpeg.start_of_image)) return jpegSize(data);
    if (starts(u8, data, gif.signature_87a) or starts(u8, data, gif.signature_89a)) {
        return gifSize(data);
    }
    if (starts(u8, data, riff.signature) and data.len >= riff.chunk_type_offset) {
        const form = data[riff.form_offset..riff.chunk_type_offset];
        if (std.mem.eql(u8, form, riff.webp_form)) return webpSize(data);
    }
    if (starts(u8, data, bmp.signature)) return bmpSize(data);
    if (starts(u8, data, tiff.signature_little)) return tiffSize(data, .little);
    if (starts(u8, data, tiff.signature_big)) return tiffSize(data, .big);
    if (starts(u8, data, qoi.signature)) {
        if (data.len < qoi.header_bytes) return null;
        return .{
            .width_px = int(u32, data, qoi.width_offset, .big).?,
            .height_px = int(u32, data, qoi.height_offset, .big).?,
        };
    }
    const box_type_end = iso_box.type_offset + iso_box.ftyp.len;
    if (data.len >= box_type_end) {
        if (std.mem.eql(u8, data[iso_box.type_offset..box_type_end], iso_box.ftyp)) {
            var size: Size = .{ .width_px = 0, .height_px = 0 };
            heifSizes(data, 0, data.len, 0, &size);
            return size;
        }
    }
    return null;
}

fn bmpSize(data: []const u8) ?Size {
    const info_size = int(u32, data, bmp.info_size_offset, .little) orelse return null;
    if (info_size == bmp.os2_info_size) {
        return .{
            .width_px = int(u16, data, bmp.os2_width_offset, .little) orelse return null,
            .height_px = int(u16, data, bmp.os2_height_offset, .little) orelse return null,
        };
    }
    return .{
        .width_px = @abs(int(i32, data, bmp.width_offset, .little) orelse return null),
        .height_px = @abs(int(i32, data, bmp.height_offset, .little) orelse return null),
    };
}

/// A `T` at `at`, or null past the end.
fn int(comptime T: type, data: []const u8, at: usize, endian: std.builtin.Endian) ?T {
    const int_bytes = @divExact(@typeInfo(T).int.bits, 8);
    if (at > data.len or data.len - at < int_bytes) return null;
    return std.mem.readInt(T, data[at..][0..int_bytes], endian);
}

const jpeg = struct {
    const start_of_image = "\xff\xd8";
    const marker_prefix = 0xff;
    /// Markers are two bytes; most are followed by a 16-bit length that
    /// counts itself.
    const marker_bytes = 2;
    const length_bytes = 2;
    /// A fill byte, and the markers that have no length (TEM, RST0-7, SOI).
    const fill = 0xff;
    const temporary = 0x01;
    const restart_first = 0xd0;
    const start_of_image_marker = 0xd8;
    /// The image's end and the start of its data: no frame header after.
    const end_of_image = 0xd9;
    const start_of_scan = 0xda;
    /// SOF0 to SOF15, without the three markers in that range that are not
    /// frame headers: DHT, JPG and DAC.
    const frame_first = 0xc0;
    const frame_last = 0xcf;
    const huffman_table = 0xc4;
    const extension = 0xc8;
    const arithmetic_conditioning = 0xcc;
    /// In a frame header, after the marker: length, precision, height,
    /// width.
    const frame_height_offset = 5;
    const frame_width_offset = 7;
};

/// The first frame header (SOFn), past the segments before it (EXIF and
/// its thumbnail included).
fn jpegSize(data: []const u8) ?Size {
    var at: usize = jpeg.start_of_image.len;
    while (at + jpeg.marker_bytes + jpeg.length_bytes <= data.len) {
        if (data[at] != jpeg.marker_prefix) return null;
        const marker = data[at + 1];
        switch (marker) {
            jpeg.fill => at += 1,
            jpeg.temporary, jpeg.restart_first...jpeg.start_of_image_marker => {
                at += jpeg.marker_bytes;
            },
            jpeg.end_of_image, jpeg.start_of_scan => return null,
            else => {
                const in_frame_range = marker >= jpeg.frame_first and marker <= jpeg.frame_last;
                const not_a_frame = marker == jpeg.huffman_table or
                    marker == jpeg.extension or marker == jpeg.arithmetic_conditioning;
                if (in_frame_range and !not_a_frame) {
                    const width_at = at + jpeg.frame_width_offset;
                    const height_at = at + jpeg.frame_height_offset;
                    return .{
                        .width_px = int(u16, data, width_at, .big) orelse return null,
                        .height_px = int(u16, data, height_at, .big) orelse return null,
                    };
                }
                const length = int(u16, data, at + jpeg.marker_bytes, .big) orelse return null;
                if (length < jpeg.length_bytes) return null;
                at += jpeg.marker_bytes + length;
            },
        }
    }
    return null;
}

const gif = struct {
    const signature_87a = "GIF87a";
    const signature_89a = "GIF89a";
    /// The logical screen descriptor, after the signature.
    const screen_width_offset = 6;
    const screen_height_offset = 8;
    const screen_flags_offset = 10;
    const header_bytes = 13;
    /// In the screen's and an image's flags: a colour table follows, of
    /// 3 << (size + 1) bytes.
    const color_table_flag = 0x80;
    const color_table_size_mask = 7;
    const color_entry_bytes = 3;
    const image_separator = 0x2c;
    const extension_introducer = 0x21;
    /// An image descriptor, after its separator: left, top, width, height
    /// (16-bit each), then flags.
    const image_left_offset = 1;
    const image_top_offset = 3;
    const image_width_offset = 5;
    const image_height_offset = 7;
    const image_flags_offset = 9;
    const image_descriptor_bytes = 10;
    /// The LZW minimum code size byte before an image's data blocks.
    const lzw_size_bytes = 1;
    /// An extension's introducer and label before its data blocks.
    const extension_header_bytes = 2;

    fn colorTableBytes(flags: u8) usize {
        return @as(usize, color_entry_bytes) << @intCast((flags & color_table_size_mask) + 1);
    }
};

/// The logical screen, grown to hold every frame: a frame can be larger.
fn gifSize(data: []const u8) ?Size {
    if (data.len < gif.header_bytes) return null;
    var size: Size = .{
        .width_px = int(u16, data, gif.screen_width_offset, .little) orelse return null,
        .height_px = int(u16, data, gif.screen_height_offset, .little) orelse return null,
    };
    var at: usize = gif.header_bytes;
    const screen_flags = data[gif.screen_flags_offset];
    if (screen_flags & gif.color_table_flag != 0) at += gif.colorTableBytes(screen_flags);
    while (at < data.len) switch (data[at]) {
        gif.image_separator => {
            const left = int(u16, data, at + gif.image_left_offset, .little) orelse break;
            const top = int(u16, data, at + gif.image_top_offset, .little) orelse break;
            const width = int(u16, data, at + gif.image_width_offset, .little) orelse break;
            const height = int(u16, data, at + gif.image_height_offset, .little) orelse break;
            size.width_px = @max(size.width_px, @as(u64, left) + width);
            size.height_px = @max(size.height_px, @as(u64, top) + height);
            const flags_at = at + gif.image_flags_offset;
            const flags = if (flags_at < data.len) data[flags_at] else break;
            at += gif.image_descriptor_bytes;
            if (flags & gif.color_table_flag != 0) at += gif.colorTableBytes(flags);
            at = skipGifBlocks(data, at + gif.lzw_size_bytes) orelse break;
        },
        gif.extension_introducer => {
            at = skipGifBlocks(data, at + gif.extension_header_bytes) orelse break;
        },
        // The trailer, or something no decoder reads past either.
        else => break,
    };
    return size;
}

/// Data sub-blocks: a length byte and that many bytes, until a length of 0.
fn skipGifBlocks(data: []const u8, from: usize) ?usize {
    var at = from;
    while (at < data.len) {
        const block_bytes = data[at];
        at += 1 + @as(usize, block_bytes);
        if (block_bytes == 0) return at;
    }
    return null;
}

const webp = struct {
    /// Lossy: a key frame's 3-byte tag, a start code, 14-bit sizes.
    const lossy_chunk = "VP8 ";
    const lossy_start_code_offset = 23;
    const lossy_start_code = "\x9d\x01\x2a";
    const lossy_width_offset = 26;
    const lossy_height_offset = 28;
    const lossy_size_mask = 0x3fff;
    /// Lossless: a signature byte, then width - 1 and height - 1 in 14 bits
    /// each.
    const lossless_chunk = "VP8L";
    const lossless_signature_offset = 20;
    const lossless_signature = 0x2f;
    const lossless_bits_offset = 21;
    const lossless_header_bytes = 25;
    const lossless_size_bits = 14;
    const lossless_size_mask = 0x3fff;
    /// Extended: width - 1 and height - 1 in 24 bits each.
    const extended_chunk = "VP8X";
    const extended_width_offset = 24;
    const extended_height_offset = 27;
};

fn webpSize(data: []const u8) ?Size {
    const chunk_end = @min(data.len, riff.chunk_type_offset + riff.chunk_type_bytes);
    const chunk = data[riff.chunk_type_offset..chunk_end];
    if (std.mem.eql(u8, chunk, webp.lossy_chunk)) {
        const code_start = @min(data.len, webp.lossy_start_code_offset);
        const code_end = @min(data.len, webp.lossy_start_code_offset + webp.lossy_start_code.len);
        if (!std.mem.eql(u8, data[code_start..code_end], webp.lossy_start_code)) return null;
        const width = int(u16, data, webp.lossy_width_offset, .little) orelse return null;
        const height = int(u16, data, webp.lossy_height_offset, .little) orelse return null;
        return .{
            .width_px = width & webp.lossy_size_mask,
            .height_px = height & webp.lossy_size_mask,
        };
    }
    if (std.mem.eql(u8, chunk, webp.lossless_chunk)) {
        if (data.len < webp.lossless_header_bytes) return null;
        if (data[webp.lossless_signature_offset] != webp.lossless_signature) return null;
        const bits = int(u32, data, webp.lossless_bits_offset, .little) orelse return null;
        return .{
            .width_px = (bits & webp.lossless_size_mask) + 1,
            .height_px = ((bits >> webp.lossless_size_bits) & webp.lossless_size_mask) + 1,
        };
    }
    if (std.mem.eql(u8, chunk, webp.extended_chunk)) {
        const width = int(u24, data, webp.extended_width_offset, .little) orelse return null;
        const height = int(u24, data, webp.extended_height_offset, .little) orelse return null;
        return .{ .width_px = @as(u64, width) + 1, .height_px = @as(u64, height) + 1 };
    }
    return null;
}

const tiff = struct {
    const signature_little = "II*\x00";
    const signature_big = "MM\x00*";
    const first_directory_offset = 4;
    /// A directory: a 16-bit entry count, 12-byte entries, then the next
    /// directory's offset (0: none).
    const entry_count_bytes = 2;
    const entry_bytes = 12;
    /// An entry: tag, type, count, then the value itself when it fits.
    const entry_type_offset = 2;
    const entry_value_offset = 8;
    const tag_image_width = 256;
    const tag_image_length = 257;
    const type_short = 3;
    const type_long = 4;
    /// Directories link to the next; a loop is cut short after this many.
    const directories_max = 64;
};

/// The largest width and height in any directory (pages, reduced copies).
fn tiffSize(data: []const u8, endian: std.builtin.Endian) ?Size {
    var size: Size = .{ .width_px = 0, .height_px = 0 };
    var directory: usize = int(u32, data, tiff.first_directory_offset, endian) orelse return null;
    var directory_count: usize = 0;
    while (directory != 0 and directory_count < tiff.directories_max) : (directory_count += 1) {
        const entry_count = int(u16, data, directory, endian) orelse break;
        const entries_at = directory + tiff.entry_count_bytes;
        for (0..entry_count) |entry_index| {
            const entry = entries_at + entry_index * tiff.entry_bytes;
            const tag = int(u16, data, entry, endian) orelse break;
            if (tag != tiff.tag_image_width and tag != tiff.tag_image_length) continue;
            const value_at = entry + tiff.entry_value_offset;
            const value_type = int(u16, data, entry + tiff.entry_type_offset, endian) orelse break;
            const value: u64 = switch (value_type) {
                tiff.type_short => int(u16, data, value_at, endian) orelse break,
                tiff.type_long => int(u32, data, value_at, endian) orelse break,
                else => continue,
            };
            if (tag == tiff.tag_image_width) {
                size.width_px = @max(size.width_px, value);
            } else {
                size.height_px = @max(size.height_px, value);
            }
        }
        const next_at = entries_at + @as(usize, entry_count) * tiff.entry_bytes;
        directory = int(u32, data, next_at, endian) orelse break;
    }
    return size;
}

/// HEIF and AVIF keep each image's size in an `ispe` box (meta, iprp,
/// ipco); a picture made of tiles has one for the whole. The largest.
fn heifSizes(data: []const u8, from: usize, end: usize, depth: u8, size: *Size) void {
    if (depth > iso_box.depth_max) return;
    var at = from;
    while (at + iso_box.header_bytes <= end) {
        var box_bytes: u64 = int(u32, data, at, .big) orelse return;
        var header_bytes: usize = iso_box.header_bytes;
        if (box_bytes == iso_box.large_size_marker) {
            box_bytes = int(u64, data, at + iso_box.header_bytes, .big) orelse return;
            header_bytes = iso_box.large_header_bytes;
        } else if (box_bytes == iso_box.to_end_marker) {
            box_bytes = end - at;
        }
        if (box_bytes < header_bytes or box_bytes > end - at) return;
        const kind = data[at + iso_box.type_offset .. at + iso_box.header_bytes];
        const body = at + header_bytes;
        const next = at + @as(usize, @intCast(box_bytes));
        const container = std.mem.eql(u8, kind, iso_box.item_properties) or
            std.mem.eql(u8, kind, iso_box.property_container);
        const spatial_extent = std.mem.eql(u8, kind, iso_box.spatial_extent) and
            next >= body + iso_box.ispe_bytes;
        if (std.mem.eql(u8, kind, iso_box.meta)) {
            heifSizes(data, body + iso_box.full_box_bytes, next, depth + 1, size);
        } else if (container) {
            heifSizes(data, body, next, depth + 1, size);
        } else if (spatial_extent) {
            const width = int(u32, data, body + iso_box.ispe_width_offset, .big).?;
            const height = int(u32, data, body + iso_box.ispe_height_offset, .big).?;
            size.width_px = @max(size.width_px, width);
            size.height_px = @max(size.height_px, height);
        }
        at = next;
    }
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
    const request: *Request = @ptrCast(@alignCast(data.?));
    decoding = false;
    const pixbuf: ?*c.GdkPixbuf = @ptrCast(c.g_task_propagate_pointer(@ptrCast(result), null));
    defer unrefObject(pixbuf);
    finishRequest(request, pixbuf, request.generation == request.lane.current());
    startNext();
}

fn finishRequest(request: *Request, pixbuf: ?*c.GdkPixbuf, current: bool) void {
    const gpa = std.heap.c_allocator;
    defer {
        gpa.free(request.path);
        gpa.destroy(request);
    }
    request.done(request.context, pixbuf, current);
}

test "image sizes are read from headers" {
    const testing = std.testing;
    // PNG: IHDR right after the signature.
    const png_file = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x4e\x20\x00\x00\x4e\x20\x08\x02";
    try testing.expectEqual(Size{ .width_px = 20000, .height_px = 20000 }, imageSize(png_file).?);
    // JPEG: an APP1 segment, then SOF0 (height before width).
    const jpeg_file = "\xff\xd8\xff\xe1\x00\x04ab\xff\xc0\x00\x11\x08\x0b\xb8\x0f\xa0\x03";
    try testing.expectEqual(Size{ .width_px = 4000, .height_px = 3000 }, imageSize(jpeg_file).?);
    try testing.expect(imageSize("\xff\xd8\xff\xda\x00\x04") == null);
    // GIF: a 1×1 screen, a 300×200 frame at (10, 5).
    const gif_file = "GIF89a\x01\x00\x01\x00\x00\x00\x00" ++
        "\x2c\x0a\x00\x05\x00\x2c\x01\xc8\x00\x00\x02\x01\x00\x00\x3b";
    try testing.expectEqual(Size{ .width_px = 310, .height_px = 205 }, imageSize(gif_file).?);
    // WebP, lossless: 14 bits each, minus one.
    const webp_file = "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\x2f" ++ "\x63\x00\x19\x00";
    try testing.expectEqual(Size{ .width_px = 100, .height_px = 101 }, imageSize(webp_file).?);
    const webp_extended_file = "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00" ++
        "\x1f\x4e\x00\x1f\x4e\x00";
    const webp_extended_size = imageSize(webp_extended_file).?;
    try testing.expectEqual(Size{ .width_px = 20000, .height_px = 20000 }, webp_extended_size);
    // BMP, stored top-down.
    const bmp_file = "BM" ++ @as([12]u8, @splat(0)) ++ "\x28\x00\x00\x00" ++ "\x20\x4e\x00\x00" ++
        "\xe0\xb1\xff\xff";
    try testing.expectEqual(Size{ .width_px = 20000, .height_px = 20000 }, imageSize(bmp_file).?);
    // TIFF, little-endian: one directory, width SHORT, height LONG.
    const tiff_file = "II*\x00\x08\x00\x00\x00" ++ "\x02\x00" ++
        "\x00\x01\x03\x00\x01\x00\x00\x00\x40\x1f\x00\x00" ++
        "\x01\x01\x04\x00\x01\x00\x00\x00\x40\x1f\x00\x00" ++ "\x00\x00\x00\x00";
    try testing.expectEqual(Size{ .width_px = 8000, .height_px = 8000 }, imageSize(tiff_file).?);
    // HEIF: ftyp, then meta > iprp > ipco > ispe.
    const ispe = "\x00\x00\x00\x14ispe\x00\x00\x00\x00\x00\x00\x30\x00\x00\x00\x20\x00";
    const ipco = "\x00\x00\x00\x1cipco" ++ ispe;
    const iprp = "\x00\x00\x00\x24iprp" ++ ipco;
    const heif = "\x00\x00\x00\x10ftypheic\x00\x00\x00\x00" ++
        "\x00\x00\x00\x30meta\x00\x00\x00\x00" ++ iprp;
    try testing.expectEqual(Size{ .width_px = 0x3000, .height_px = 0x2000 }, imageSize(heif).?);
    // Not an image, cut short, or empty.
    try testing.expect(imageSize("hello") == null);
    try testing.expect(imageSize(png_file[0..20]) == null);
    try testing.expect(imageSize("GIF89a\x00\x00\x00\x00\x00\x00\x00") == null);
}

test "a picture over the limits is never decoded" {
    const testing = std.testing;
    const limits: Limits = .{ .bytes = 1 << 20, .pixels = 4096 * 4096 };
    const bomb = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x4e\x20\x00\x00\x4e\x20\x08\x02";
    try testing.expect(decodeSize(bomb, 512, 512, limits) == null);
    // Within the limits: never decoded larger than it is.
    const small = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x10\x00\x00\x00\x20\x08\x02";
    try testing.expectEqual([2]c_int{ 16, 32 }, decodeSize(small, 512, 512, limits).?);
    try testing.expectEqual([2]c_int{ 16, 20 }, decodeSize(small, 512, 20, limits).?);
    // SVG is drawn at the size asked for; an unknown format is not decoded.
    const svg = "\xef\xbb\xbf<?xml version=\"1.0\"?>\n<svg width=\"30000\" height=\"30000\"/>";
    try testing.expectEqual([2]c_int{ 64, 64 }, decodeSize(svg, 64, 64, limits).?);
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
    // A FIFO named like a picture: refused at once, not waited on.
    const fifo = try test_dir.path(&path_bytes, "fifo.png");
    try testing.expect(std.os.linux.mknod(fifo, std.os.linux.S.IFIFO | 0o600, 0) == 0);
    try testing.expect(decodeImage(fifo, 64, 64, limits) == null);
}
