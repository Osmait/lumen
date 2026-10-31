//! The content index file's layout, which the writer (`content_write.zig`)
//! and the reader (`ContentIndex.zig`) share:
//!
//!   header | doc table (columns: mtime, size, path offset, path size,
//!   source, flags) | paths | segments (sorted trigram keys, list offsets,
//!   posting lists) | segment directory
//!
//! and what goes in it: documents (`DocIn`), trigrams of folded text, and
//! posting lists of doc ids as varint deltas. A list read from disk is
//! decoded defensively (`ListReader`): whatever the bytes, the ids that
//! come out are ascending and name documents of the index.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const format = @import("format.zig");
const Bytes = format.Bytes;
const fold = @import("core").fold;

/// 02: trigrams of folded text (accents and case, `core.fold`).
/// 03: a flags column (documents removed by an incremental update).
/// 04: path offsets are positions in the file, so an appended doc table
/// refers to the paths already there instead of writing them all again.
pub const magic = "LUMCTX04";
pub const header_size = 64;

/// The first bytes of the file. The doc table's columns and the segments'
/// arrays are read in place, in the host's byte order, and so is this: the
/// format is little-endian, and so must the host be (asserted).
pub const Header = extern struct {
    magic: [8]u8,
    docs_count: u64,
    segments_count: u64,
    /// Bytes of the paths the doc table added (an appended table refers to
    /// the paths already in the file and adds only its new documents').
    paths_size: u64,
    docs_offset: u64,
    /// Where the segment directory starts: `segments_count` entries.
    directory_offset: u64,
    /// Bytes the header refers to. An update appends, then points the
    /// header at what it added: bytes past this are an update whose header
    /// never got written.
    size_total: u64,
    reserved: [8]u8,

    comptime {
        assert(builtin.cpu.arch.endian() == .little);
        assert(@sizeOf(Header) == header_size);
        assert(@offsetOf(Header, "docs_count") == 8);
        assert(@offsetOf(Header, "segments_count") == 16);
        assert(@offsetOf(Header, "paths_size") == 24);
        assert(@offsetOf(Header, "docs_offset") == 32);
        assert(@offsetOf(Header, "directory_offset") == 40);
        assert(@offsetOf(Header, "size_total") == 48);
    }

    pub fn encode(header: Header) [header_size]u8 {
        assert(std.mem.eql(u8, &header.magic, magic));
        return std.mem.toBytes(header);
    }

    pub fn decode(bytes: *const [header_size]u8) Header {
        return std.mem.bytesToValue(Header, bytes);
    }
};

/// One segment's arrays, as the segment directory lists them.
pub const SegmentEntry = extern struct {
    keys_count: u64,
    /// `keys_count` trigrams, u32, strictly ascending.
    keys_offset: u64,
    /// `keys_count + 1` u32 offsets into the postings, one list per key.
    offsets_offset: u64,
    postings_offset: u64,
    postings_size: u64,

    comptime {
        assert(@sizeOf(SegmentEntry) == 5 * @sizeOf(u64));
    }
};

/// The doc table's columns, one after another, each `docs_count` long:
/// mtime, size, path offset, path size, source, flags. `writeDocs` writes
/// them in this order and `DocColumns.parse` reads them back.
pub const doc_size = @sizeOf(i64) + @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u16) + 1 + 1;

comptime {
    // The columns go from the widest to the narrowest, so each one stays
    // aligned whatever `docs_count` is, as long as the table starts
    // 8-aligned.
    assert(doc_size == 24);
}

/// A document whose old version an update replaced, or that is gone.
pub const flag_removed: u8 = 1;

/// The doc table stores each path's length as a u16.
pub const path_bytes_max = std.math.maxInt(u16);

/// Where a document's text comes from: the file itself, or text extracted
/// from it (PDF, Office) and cached on disk.
pub const Source = enum(u8) { plain = 0, extracted = 1 };

pub const DocIn = struct {
    /// At most `path_bytes_max` bytes (Linux paths stop at 4096).
    path: []const u8,
    mtime: i64,
    size: u64,
    source: Source = .plain,
};

/// Trigrams of folded text, packed in 24 bits each: "Acción" gives "acc",
/// "cci", "cio", "ion", the same as "accion" or "ACCION". A folded character
/// is one byte, so a trigram is three folded characters.
pub const Trigrams = struct {
    text: []const u8,
    position: usize = 0,
    window: u32 = 0,
    /// Folded characters in `window` so far, until it holds three.
    seen: u2 = 0,

    pub fn next(trigrams: *Trigrams) ?u32 {
        while (trigrams.position < trigrams.text.len) {
            const folded = fold.step(trigrams.text, &trigrams.position);
            trigrams.window = (trigrams.window << @bitSizeOf(u8) | folded) & trigram_mask;
            if (trigrams.seen == trigram_chars - 1) return trigrams.window;
            trigrams.seen += 1;
        }
        return null;
    }
};

/// A trigram is this many folded characters of one byte each: queries
/// shorter than that cannot be narrowed by the index.
pub const trigram_chars = 3;
pub const trigram_bits = trigram_chars * @bitSizeOf(u8);
pub const trigram_mask: u32 = (1 << trigram_bits) - 1;
/// Every possible trigram: the most distinct (trigram, doc) pairs a single
/// document can give.
pub const trigrams_count = trigram_mask + 1;

/// Varints are unsigned LEB128: seven bits of the number per byte, low bits
/// first, the high bit set on every byte but the last.
const varint_payload_bits = 7;
const varint_payload_mask: u8 = (1 << varint_payload_bits) - 1;
const varint_continues: u8 = 1 << varint_payload_bits;
/// A u32 takes five bytes at most; the fifth carries the top four bits.
const varint_last_shift = 4 * varint_payload_bits;
const varint_last_payload_max: u8 = (1 << (@bitSizeOf(u32) - varint_last_shift)) - 1;

/// Next varint of `bytes` from `position`, or null at the end of the list or
/// on a malformed one: cut off by the end of the list (continuation bit on
/// the last byte) or longer than a u32 needs. Never reads past `bytes`.
fn readVarint(bytes: []const u8, position: *usize) ?u32 {
    var value: u32 = 0;
    var shift: u5 = 0;
    var i = position.*;
    while (i < bytes.len) : (i += 1) {
        const byte = bytes[i];
        if (shift == varint_last_shift and byte > varint_last_payload_max) return null;
        value |= @as(u32, byte & varint_payload_mask) << shift;
        if (byte & varint_continues == 0) {
            position.* = i + 1;
            return value;
        }
        shift += varint_payload_bits;
    }
    return null;
}

/// Decodes a posting list (first id, then deltas). A list from a damaged
/// file ends at the first id that is malformed, not increasing, overflowing
/// or not a document of the index: what comes out is always strictly
/// ascending and below `docs_count`, so callers can index the doc table
/// with it.
pub const ListReader = struct {
    list_encoded: []const u8,
    docs_count: usize,
    position: usize = 0,
    doc: u32 = 0,
    started: bool = false,

    pub fn next(reader: *ListReader) ?u32 {
        const delta = readVarint(reader.list_encoded, &reader.position) orelse return reader.stop();
        if (reader.started) {
            if (delta == 0) return reader.stop();
            reader.doc = std.math.add(u32, reader.doc, delta) catch return reader.stop();
        } else {
            reader.doc = delta;
            reader.started = true;
        }
        if (reader.doc >= reader.docs_count) return reader.stop();
        return reader.doc;
    }

    fn stop(reader: *ListReader) ?u32 {
        reader.position = reader.list_encoded.len;
        return null;
    }
};

/// Appends `value` to `out` as a varint.
pub fn writeVarint(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: u32,
) std.mem.Allocator.Error!void {
    var rest = value;
    while (rest >= varint_continues) {
        try out.append(gpa, @as(u8, @intCast(rest & varint_payload_mask)) | varint_continues);
        rest >>= varint_payload_bits;
    }
    try out.append(gpa, @intCast(rest));
}

/// Appends the ids of a posting list to `out` (see `ListReader`).
pub fn decodeAll(
    gpa: std.mem.Allocator,
    list_encoded: []const u8,
    docs_count: usize,
    out: *std.ArrayList(u32),
) std.mem.Allocator.Error!void {
    var reader: ListReader = .{ .list_encoded = list_encoded, .docs_count = docs_count };
    while (reader.next()) |doc| try out.append(gpa, doc);
}

/// `docs_sorted` ∩ `list_encoded`, decoded on the fly.
pub fn intersect(
    gpa: std.mem.Allocator,
    docs_sorted: []const u32,
    list_encoded: []const u8,
    docs_count: usize,
    out: *std.ArrayList(u32),
) std.mem.Allocator.Error!void {
    var reader: ListReader = .{ .list_encoded = list_encoded, .docs_count = docs_count };
    var doc_listed: u32 = 0;
    var i: usize = 0;
    var have_listed = false;
    while (i < docs_sorted.len) {
        if (!have_listed) {
            doc_listed = reader.next() orelse return;
            have_listed = true;
        }
        if (docs_sorted[i] < doc_listed) {
            i += 1;
        } else if (docs_sorted[i] > doc_listed) {
            have_listed = false;
        } else {
            try out.append(gpa, doc_listed);
            i += 1;
            have_listed = false;
        }
    }
}

pub fn sliceAt(comptime T: type, bytes: Bytes, offset: usize, count: usize) []T {
    assert(offset % @alignOf(T) == 0);
    assert(offset + count * @sizeOf(T) <= bytes.len);
    const items: [*]T = @ptrCast(@alignCast(bytes.ptr + offset));
    return items[0..count];
}

pub fn dedupSorted(comptime T: type, items: []T) []T {
    if (items.len == 0) return items;
    var unique_count: usize = 1;
    for (items[1..]) |item| {
        if (item != items[unique_count - 1]) {
            items[unique_count] = item;
            unique_count += 1;
        }
    }
    return items[0..unique_count];
}

pub fn strictlyAscending(comptime T: type, items: []const T) bool {
    if (items.len < 2) return true;
    for (items[0 .. items.len - 1], items[1..]) |item, item_next| {
        if (item >= item_next) return false;
    }
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "varint round trip and intersection" {
    const gpa = testing.allocator;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    const ids = [_]u32{ 3, 4, 200, 70000, 70001, 5_000_000 };
    var id_previous: u32 = 0;
    for (ids) |id| {
        try writeVarint(gpa, &encoded, id - id_previous);
        id_previous = id;
    }
    var decoded: std.ArrayList(u32) = .empty;
    defer decoded.deinit(gpa);
    try decodeAll(gpa, encoded.items, 10_000_000, &decoded);
    try testing.expectEqualSlices(u32, &ids, decoded.items);
    var intersection: std.ArrayList(u32) = .empty;
    defer intersection.deinit(gpa);
    const ids_wanted = [_]u32{ 1, 4, 70000, 5_000_000, 6_000_000 };
    try intersect(gpa, &ids_wanted, encoded.items, 10_000_000, &intersection);
    try testing.expectEqualSlices(u32, &.{ 4, 70000, 5_000_000 }, intersection.items);
}

test "malformed posting lists end, never over-read" {
    const gpa = testing.allocator;
    var position: usize = 0;
    // Continuation bit on the last byte of a list.
    try testing.expectEqual(@as(?u32, null), readVarint(&.{0x80}, &position));
    position = 0;
    try testing.expectEqual(@as(?u32, 5), readVarint(&.{ 0x05, 0xff }, &position));
    try testing.expectEqual(@as(?u32, null), readVarint(&.{ 0x05, 0xff }, &position));
    try testing.expectEqual(@as(usize, 1), position);
    // Longer than a u32, or a 5th byte with more than 4 bits.
    position = 0;
    try testing.expectEqual(@as(?u32, null), readVarint(
        &.{ 0xff, 0xff, 0xff, 0xff, 0x1f },
        &position,
    ));
    position = 0;
    try testing.expectEqual(@as(?u32, null), readVarint(
        &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 },
        &position,
    ));
    position = 0;
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), readVarint(
        &.{ 0xff, 0xff, 0xff, 0xff, 0x0f },
        &position,
    ));
    try testing.expectEqual(@as(usize, 5), position);

    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    // Truncated last id: the ids before it survive.
    try decodeAll(gpa, &.{ 3, 4, 0x80 }, 100, &out);
    try testing.expectEqualSlices(u32, &.{ 3, 7 }, out.items);
    // A delta that overflows u32, a zero delta (not increasing), an id past
    // the documents: the list ends there.
    for ([_][]const u8{
        &.{ 3, 0xff, 0xff, 0xff, 0xff, 0x0f, 1 },
        &.{ 3, 0, 1 },
        &.{ 3, 98, 1 },
    }) |list| {
        out.clearRetainingCapacity();
        try decodeAll(gpa, list, 100, &out);
        try testing.expectEqualSlices(u32, &.{3}, out.items);
        out.clearRetainingCapacity();
        try intersect(gpa, &.{ 3, 4, 5, 99, 100, 101 }, list, 100, &out);
        try testing.expectEqualSlices(u32, &.{3}, out.items);
    }
}

test "content: the header struct lays out the bytes LUMCTX04 always had" {
    const header: Header = .{
        .magic = magic.*,
        .docs_count = 1,
        .segments_count = 2,
        .paths_size = 3,
        .docs_offset = 4,
        .directory_offset = 5,
        .size_total = 6,
        .reserved = @splat(0),
    };
    // The layout as it was written field by field before `Header` existed.
    var expected: [header_size]u8 = @splat(0);
    @memcpy(expected[0..8], magic);
    std.mem.writeInt(u64, expected[8..16], 1, .little);
    std.mem.writeInt(u64, expected[16..24], 2, .little);
    std.mem.writeInt(u64, expected[24..32], 3, .little);
    std.mem.writeInt(u64, expected[32..40], 4, .little);
    std.mem.writeInt(u64, expected[40..48], 5, .little);
    std.mem.writeInt(u64, expected[48..56], 6, .little);
    try testing.expectEqualSlices(u8, &expected, &header.encode());
    try testing.expectEqual(header, Header.decode(&expected));
}
