//! The size an image file declares in its header, read without decoding
//! it: what a decoder would allocate, so pictures.zig can refuse an image
//! too large to decode before gdk-pixbuf sees it. Each format's offsets are
//! named in a struct of their own, from the format's specification.
//! Pure functions on the file's bytes; thread-safe.

const std = @import("std");

pub const Size = struct { width_px: u64, height_px: u64 };

/// The size an image file declares, which is what a decoder allocates:
/// PNG, JPEG, GIF (every frame), WebP, BMP, TIFF (every directory),
/// HEIF/AVIF and QOI. Null for anything else, or a size of zero.
pub fn read(data: []const u8) ?Size {
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
    if (starts(u8, data, png.signature)) return pngSize(data);
    if (starts(u8, data, jpeg.start_of_image)) return jpegSize(data);
    if (starts(u8, data, gif.signature_87a) or starts(u8, data, gif.signature_89a)) {
        return gifSize(data);
    }
    if (isWebp(data)) return webpSize(data);
    if (starts(u8, data, bmp.signature)) return bmpSize(data);
    if (starts(u8, data, tiff.signature_little)) return tiffSize(data, .little);
    if (starts(u8, data, tiff.signature_big)) return tiffSize(data, .big);
    if (starts(u8, data, qoi.signature)) return qoiSize(data);
    if (isHeif(data)) return heifSize(data);
    return null;
}

fn pngSize(data: []const u8) ?Size {
    if (data.len < png.header_bytes) return null;
    const ihdr = data[png.ihdr_type_offset..][0..png.ihdr_type.len];
    if (!std.mem.eql(u8, ihdr, png.ihdr_type)) return null;
    return .{
        .width_px = int(u32, data, png.width_offset, .big).?,
        .height_px = int(u32, data, png.height_offset, .big).?,
    };
}

fn qoiSize(data: []const u8) ?Size {
    if (data.len < qoi.header_bytes) return null;
    return .{
        .width_px = int(u32, data, qoi.width_offset, .big).?,
        .height_px = int(u32, data, qoi.height_offset, .big).?,
    };
}

/// A RIFF file whose form is WebP.
fn isWebp(data: []const u8) bool {
    if (!std.mem.startsWith(u8, data, riff.signature)) return false;
    if (data.len < riff.chunk_type_offset) return false;
    return std.mem.eql(u8, data[riff.form_offset..riff.chunk_type_offset], riff.webp_form);
}

/// An ISO base media file: its first box is `ftyp`.
fn isHeif(data: []const u8) bool {
    const box_type_end = iso_box.type_offset + iso_box.ftyp.len;
    if (data.len < box_type_end) return false;
    return std.mem.eql(u8, data[iso_box.type_offset..box_type_end], iso_box.ftyp);
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
                if (isJpegFrame(marker)) return jpegFrameSize(data, at);
                const length = int(u16, data, at + jpeg.marker_bytes, .big) orelse return null;
                if (length < jpeg.length_bytes) return null;
                at += jpeg.marker_bytes + length;
            },
        }
    }
    return null;
}

/// SOF0 to SOF15, without the three markers in that range that are not
/// frame headers.
fn isJpegFrame(marker: u8) bool {
    const in_frame_range = marker >= jpeg.frame_first and marker <= jpeg.frame_last;
    const not_a_frame = marker == jpeg.huffman_table or
        marker == jpeg.extension or marker == jpeg.arithmetic_conditioning;
    return in_frame_range and !not_a_frame;
}

/// The size in the frame header whose marker is at `at`.
fn jpegFrameSize(data: []const u8, at: usize) ?Size {
    return .{
        .width_px = int(u16, data, at + jpeg.frame_width_offset, .big) orelse return null,
        .height_px = int(u16, data, at + jpeg.frame_height_offset, .big) orelse return null,
    };
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
        directory = tiffDirectory(data, directory, endian, &size) orelse break;
    }
    return size;
}

/// Grows `size` to the width and height in the directory at `directory`.
/// Returns where the next directory is (0: none), or null when the file
/// ends first.
fn tiffDirectory(
    data: []const u8,
    directory: usize,
    endian: std.builtin.Endian,
    size: *Size,
) ?usize {
    const entry_count = int(u16, data, directory, endian) orelse return null;
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
    const next = int(u32, data, next_at, endian) orelse return null;
    return next;
}

/// HEIF and AVIF keep each image's size in an `ispe` box (meta, iprp,
/// ipco); a picture made of tiles has one for the whole. The largest.
fn heifSize(data: []const u8) Size {
    var size: Size = .{ .width_px = 0, .height_px = 0 };
    heifSizes(data, 0, data.len, 0, &size);
    return size;
}

/// The boxes between `from` and `end`, `depth` boxes deep: grows `size` to
/// each `ispe` found in them.
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

test "image sizes are read from headers" {
    const testing = std.testing;
    // PNG: IHDR right after the signature.
    const png_file = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x4e\x20\x00\x00\x4e\x20\x08\x02";
    try testing.expectEqual(Size{ .width_px = 20000, .height_px = 20000 }, read(png_file).?);
    // JPEG: an APP1 segment, then SOF0 (height before width).
    const jpeg_file = "\xff\xd8\xff\xe1\x00\x04ab\xff\xc0\x00\x11\x08\x0b\xb8\x0f\xa0\x03";
    try testing.expectEqual(Size{ .width_px = 4000, .height_px = 3000 }, read(jpeg_file).?);
    try testing.expect(read("\xff\xd8\xff\xda\x00\x04") == null);
    // GIF: a 1×1 screen, a 300×200 frame at (10, 5).
    const gif_file = "GIF89a\x01\x00\x01\x00\x00\x00\x00" ++
        "\x2c\x0a\x00\x05\x00\x2c\x01\xc8\x00\x00\x02\x01\x00\x00\x3b";
    try testing.expectEqual(Size{ .width_px = 310, .height_px = 205 }, read(gif_file).?);
    // WebP, lossless: 14 bits each, minus one.
    const webp_file = "RIFF\x00\x00\x00\x00WEBPVP8L\x00\x00\x00\x00\x2f" ++ "\x63\x00\x19\x00";
    try testing.expectEqual(Size{ .width_px = 100, .height_px = 101 }, read(webp_file).?);
    const webp_extended_file = "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00" ++
        "\x1f\x4e\x00\x1f\x4e\x00";
    const webp_extended_size = read(webp_extended_file).?;
    try testing.expectEqual(Size{ .width_px = 20000, .height_px = 20000 }, webp_extended_size);
    // BMP, stored top-down.
    const bmp_file = "BM" ++ @as([12]u8, @splat(0)) ++ "\x28\x00\x00\x00" ++ "\x20\x4e\x00\x00" ++
        "\xe0\xb1\xff\xff";
    try testing.expectEqual(Size{ .width_px = 20000, .height_px = 20000 }, read(bmp_file).?);
    // TIFF, little-endian: one directory, width SHORT, height LONG.
    const tiff_file = "II*\x00\x08\x00\x00\x00" ++ "\x02\x00" ++
        "\x00\x01\x03\x00\x01\x00\x00\x00\x40\x1f\x00\x00" ++
        "\x01\x01\x04\x00\x01\x00\x00\x00\x40\x1f\x00\x00" ++ "\x00\x00\x00\x00";
    try testing.expectEqual(Size{ .width_px = 8000, .height_px = 8000 }, read(tiff_file).?);
    // HEIF: ftyp, then meta > iprp > ipco > ispe.
    const ispe = "\x00\x00\x00\x14ispe\x00\x00\x00\x00\x00\x00\x30\x00\x00\x00\x20\x00";
    const ipco = "\x00\x00\x00\x1cipco" ++ ispe;
    const iprp = "\x00\x00\x00\x24iprp" ++ ipco;
    const heif = "\x00\x00\x00\x10ftypheic\x00\x00\x00\x00" ++
        "\x00\x00\x00\x30meta\x00\x00\x00\x00" ++ iprp;
    try testing.expectEqual(Size{ .width_px = 0x3000, .height_px = 0x2000 }, read(heif).?);
    // Not an image, cut short, or empty.
    try testing.expect(read("hello") == null);
    try testing.expect(read(png_file[0..20]) == null);
    try testing.expect(read("GIF89a\x00\x00\x00\x00\x00\x00\x00") == null);
}
