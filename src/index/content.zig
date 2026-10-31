//! Content index: which documents contain which trigrams, like plocate and
//! Google's Code Search. For *names* trigrams were measured and
//! dropped (no help for 1-2 letters, useless for fuzzy matches, 3x the
//! memory). Text inside files is the opposite case: people search exact
//! fragments of 3+ characters, and scanning 1 GB per keystroke with ripgrep
//! costs ~200 ms on every core. Here a query reads a few posting lists and
//! then verifies a few hundred candidates.
//!
//! One file, mapped like `files.idx`:
//!
//!   header | docs (mtime, size, path offset and length, kind, flags) | paths |
//!   segments: sorted trigram keys, offsets, posting lists (varint deltas) |
//!   segment directory
//!
//! A few changed files do not rebuild it (`update`): their old versions are
//! flagged removed and skipped by queries, the new ones are appended with
//! new ids in a segment of their own. The service rebuilds it whole once
//! removed documents or segments pile up.
//!
//! Segments keep the build's memory bounded: pairs (trigram, doc) are
//! collected for a run of documents, radix-sorted, encoded, dropped. Doc ids
//! are global and increase across segments, so a trigram's full list is its
//! lists in segment order.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const Pool = @import("Pool.zig");
const sys = @import("os");
const format = @import("format.zig");
const align8 = format.align8;
const corpusEntry = format.corpusEntry;
const fold = @import("core").fold;
const utf8 = @import("core").utf8;

/// 02: trigrams of folded text (accents and case, `core.fold`).
/// 03: a flags column (documents removed by an incremental update).
/// 04: path offsets are positions in the file, so an appended doc table
/// refers to the paths already there instead of writing them all again.
const magic = "LUMCTX04";
const header_size = 64;

/// Plain text files above this are not indexed (logs, dumps, data).
pub const text_bytes_max = 1 << 20;
/// Extracted text kept per document (PDF, Office).
pub const extracted_bytes_max = 4 << 20;
/// A segment is closed past this many (trigram, doc) pairs: 32 MB of pairs
/// and as much again to sort them. 16 M pairs made the build peak at 585 MB
/// (49 k documents) for no faster queries; 4 M peaks at ~346 MB, for 12
/// segments instead of 4 and an index 8 % larger.
const segment_pairs_max = 4 << 20;
/// Documents read in parallel per round, at most.
const round_docs_max = 1024;
/// And at most as many as could give this many pairs (one per byte of
/// text): a round of 1024 high-entropy 1 MB files once held a billion
/// pairs, 8 GB, and as much again to sort them. Ordinary text gives a pair
/// per ~9 bytes, so a round still reads hundreds of files.
const round_pairs_max = segment_pairs_max;

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
const Trigrams = struct {
    text: []const u8,
    position: usize = 0,
    window: u32 = 0,
    /// Folded characters in `window` so far, until it holds three.
    seen: u2 = 0,

    fn next(trigrams: *Trigrams) ?u32 {
        while (trigrams.position < trigrams.text.len) {
            const folded = fold.step(trigrams.text, &trigrams.position);
            trigrams.window = (trigrams.window << 8 | folded) & trigram_mask;
            if (trigrams.seen == 2) return trigrams.window;
            trigrams.seen += 1;
        }
        return null;
    }
};

/// Three folded characters of one byte each.
const trigram_mask: u32 = 0xff_ffff;

/// The first bytes of the file. The doc table's columns and the segments'
/// arrays are read in place, in the host's byte order, and so is this: the
/// format is little-endian, and so must the host be (asserted).
const Header = extern struct {
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

    fn encode(header: Header) [header_size]u8 {
        assert(std.mem.eql(u8, &header.magic, magic));
        return std.mem.toBytes(header);
    }

    fn decode(bytes: *const [header_size]u8) Header {
        return std.mem.bytesToValue(Header, bytes);
    }
};

/// One segment's arrays, as the segment directory lists them.
const SegmentEntry = extern struct {
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
const doc_size = @sizeOf(i64) + @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u16) + 1 + 1;

comptime {
    // The columns go from the widest to the narrowest, so each one stays
    // aligned whatever `docs_count` is, as long as the table starts
    // 8-aligned.
    assert(doc_size == 24);
}

/// The doc table of an index file, checked: every path inside the file,
/// every source a known kind, no unknown flag.
const DocColumns = struct {
    mtimes: []const i64,
    sizes: []const u64,
    path_offsets: []const u32,
    path_sizes: []const u16,
    sources: []const u8,
    flags: []u8,
    /// Bytes of all paths, and documents marked removed.
    paths_size_total: usize,
    docs_removed_count: usize,

    fn parse(
        buf: []align(8) u8,
        docs_offset: usize,
        docs_count: usize,
    ) error{BadIndex}!DocColumns {
        assert(docs_offset % 8 == 0);
        assert(docs_offset + docs_count * doc_size <= buf.len);
        var cursor = docs_offset;
        var columns: DocColumns = undefined;
        columns.mtimes = sliceAt(i64, buf, cursor, docs_count);
        cursor += docs_count * @sizeOf(i64);
        columns.sizes = sliceAt(u64, buf, cursor, docs_count);
        cursor += docs_count * @sizeOf(u64);
        columns.path_offsets = sliceAt(u32, buf, cursor, docs_count);
        cursor += docs_count * @sizeOf(u32);
        columns.path_sizes = sliceAt(u16, buf, cursor, docs_count);
        cursor += docs_count * @sizeOf(u16);
        columns.sources = buf[cursor..][0..docs_count];
        cursor += docs_count;
        columns.flags = buf[cursor..][0..docs_count];
        cursor += docs_count;
        assert(cursor == docs_offset + docs_count * doc_size);

        columns.paths_size_total = 0;
        for (columns.path_offsets, columns.path_sizes) |path_offset, path_size| {
            if (@as(u64, path_offset) + path_size > buf.len) return error.BadIndex;
            columns.paths_size_total += path_size;
        }
        for (columns.sources) |source| {
            if (std.enums.fromInt(Source, source) == null) return error.BadIndex;
        }
        columns.docs_removed_count = 0;
        for (columns.flags) |flags| {
            if (flags & ~flag_removed != 0) return error.BadIndex;
            columns.docs_removed_count += flags & flag_removed;
        }
        return columns;
    }
};

pub const Index = struct {
    buf: []align(8) u8,
    mapped: bool,
    docs_count: usize,
    segments_count: usize,
    mtimes: []const i64,
    sizes: []const u64,
    path_offsets: []const u32,
    path_sizes: []const u16,
    sources: []const u8,
    flags: []const u8,
    /// The file up to `Header.size_total`: paths are found at their offsets
    /// in it.
    file: []const u8,
    segments: []const SegmentEntry,
    /// Documents flagged removed: their ids stay, queries skip them.
    docs_removed_count: usize,
    /// Bytes the header refers to; the rest of the file is what updates
    /// left behind (old doc tables, merged segments).
    bytes_live: usize,

    pub fn deinit(index: *Index, gpa: std.mem.Allocator) void {
        format.release(index.buf, index.mapped, gpa);
        index.* = undefined;
    }

    pub fn path(index: *const Index, doc: u32) []const u8 {
        return index.file[index.path_offsets[doc]..][0..index.path_sizes[doc]];
    }

    pub fn removed(index: *const Index, doc: u32) bool {
        return index.flags[doc] & flag_removed != 0;
    }

    /// Documents a query can find.
    pub fn live(index: *const Index) usize {
        return index.docs_count - index.docs_removed_count;
    }

    pub fn docIn(index: *const Index, doc: u32) DocIn {
        return .{
            .path = index.path(doc),
            .mtime = index.mtimes[doc],
            .size = index.sizes[doc],
            .source = @fromBackingInt(@intCast(index.sources[doc])),
        };
    }

    /// Checks that `whole` is a well-formed index and wraps it without
    /// copying (`mapped` says how `deinit` releases it).
    ///
    /// The file comes from disk: it may be truncated, from another version or
    /// garbage. Everything later accesses index with is checked here, in
    /// linear passes over the doc table and the segment keys (no posting list
    /// is decoded; the decoders are bounds-safe instead): header offsets in
    /// bounds and aligned, every path inside the file, every source a
    /// known kind, every segment's arrays in bounds, keys strictly ascending
    /// (binary search) and trigrams (24 bits), offsets non-decreasing and
    /// within the postings.
    ///
    /// That doc ids rise from one segment to the next is not checked: it
    /// would mean decoding every list on open. Whatever reads lists across
    /// segments copes with ids that repeat or go back instead (`candidates`,
    /// `closeSegment`).
    pub fn parse(whole: []align(8) u8, mapped: bool) error{BadIndex}!Index {
        if (whole.len < header_size) return error.BadIndex;
        const header = Header.decode(whole[0..header_size]);
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadIndex;
        if (header.size_total > whole.len) return error.BadIndex;
        if (header.size_total < header_size) return error.BadIndex;
        const buf = whole[0..@intCast(header.size_total)];
        // Doc ids are u32 in posting lists and results.
        if (header.docs_count > std.math.maxInt(u32)) return error.BadIndex;
        const docs_count: usize = @intCast(header.docs_count);
        const docs_offset = try region(buf.len, header.docs_offset, docs_count, doc_size, 8);
        if (docs_offset < header_size) return error.BadIndex;
        const paths_offset = docs_offset + docs_count * doc_size;
        if (header.paths_size > buf.len - paths_offset) return error.BadIndex;
        const directory_offset = try region(
            buf.len,
            header.directory_offset,
            header.segments_count,
            @sizeOf(SegmentEntry),
            8,
        );
        const segments_count: usize = @intCast(header.segments_count);

        const columns = try DocColumns.parse(buf, docs_offset, docs_count);

        const segments = sliceAt(SegmentEntry, buf, directory_offset, segments_count);
        var bytes_live = header_size + docs_count * doc_size + columns.paths_size_total +
            segments_count * @sizeOf(SegmentEntry);
        for (segments) |segment| {
            try checkSegment(buf, segment);
            const keys_count: usize = @intCast(segment.keys_count);
            // Keys, and one more offset than keys.
            bytes_live += keys_count * @sizeOf(u32) + (keys_count + 1) * @sizeOf(u32);
            bytes_live += @intCast(segment.postings_size);
        }

        return .{
            .buf = whole,
            .mapped = mapped,
            .docs_count = docs_count,
            .segments_count = segments_count,
            .mtimes = columns.mtimes,
            .sizes = columns.sizes,
            .path_offsets = columns.path_offsets,
            .path_sizes = columns.path_sizes,
            .sources = columns.sources,
            .flags = columns.flags,
            .file = buf,
            .segments = segments,
            .docs_removed_count = columns.docs_removed_count,
            .bytes_live = bytes_live,
        };
    }

    /// Writes the index to `path_z` atomically (see `sys.writeFileAtomic`).
    pub fn save(index: *const Index, path_z: [:0]const u8) sys.Error!void {
        try sys.writeFileAtomic(path_z, index.buf);
    }

    pub fn open(path_z: [:0]const u8) (sys.Error || error{BadIndex})!Index {
        const buf = try sys.mapPrivate(path_z);
        errdefer sys.unmap(buf);
        return parse(buf, true);
    }

    /// Posting list bytes of `key` in segment `segment_index` (empty if
    /// absent).
    fn list(index: *const Index, segment_index: usize, key: u32) []const u8 {
        const segment = index.segments[segment_index];
        const keys = sliceAt(u32, index.buf, segment.keys_offset, segment.keys_count);
        var lo: usize = 0;
        var hi: usize = keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (keys[mid] < key) lo = mid + 1 else hi = mid;
        }
        if (lo == keys.len) return &.{};
        if (keys[lo] != key) return &.{};
        const offsets = sliceAt(u32, index.buf, segment.offsets_offset, segment.keys_count + 1);
        const postings_offset = segment.postings_offset;
        return index.buf[postings_offset + offsets[lo] .. postings_offset + offsets[lo + 1]];
    }

    /// Documents containing every trigram of every word, folded (words of 3+
    /// folded characters; shorter ones cannot narrow anything and are checked
    /// on verify).
    /// Appends doc ids, ascending, to `out`.
    pub fn candidates(
        index: *const Index,
        gpa: std.mem.Allocator,
        words: []const []const u8,
        out: *std.ArrayList(u32),
    ) std.mem.Allocator.Error!void {
        out.clearRetainingCapacity();
        var keys: std.ArrayList(u32) = .empty;
        defer keys.deinit(gpa);
        for (words) |word| {
            var trigrams: Trigrams = .{ .text = word };
            while (trigrams.next()) |key| try keys.append(gpa, key);
        }
        if (keys.items.len == 0) return;
        std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
        const keys_unique = dedupSorted(u32, keys.items);

        var lists = try gpa.alloc([]const u8, keys_unique.len);
        defer gpa.free(lists);
        var docs_matching: std.ArrayList(u32) = .empty;
        defer docs_matching.deinit(gpa);
        var docs_next: std.ArrayList(u32) = .empty;
        defer docs_next.deinit(gpa);

        for (0..index.segments_count) |segment_index| {
            var some_list_empty = false;
            for (keys_unique, lists) |key, *list_of_key| {
                list_of_key.* = index.list(segment_index, key);
                if (list_of_key.len == 0) some_list_empty = true;
            }
            if (some_list_empty) continue;
            // Shortest list first: every intersection only shrinks the set.
            std.mem.sort([]const u8, lists, {}, struct {
                fn shorter(_: void, a: []const u8, b: []const u8) bool {
                    return a.len < b.len;
                }
            }.shorter);
            docs_matching.clearRetainingCapacity();
            try decodeAll(gpa, lists[0], index.docs_count, &docs_matching);
            for (lists[1..]) |list_encoded| {
                if (docs_matching.items.len == 0) break;
                docs_next.clearRetainingCapacity();
                try intersect(gpa, docs_matching.items, list_encoded, index.docs_count, &docs_next);
                std.mem.swap(std.ArrayList(u32), &docs_matching, &docs_next);
            }
            for (docs_matching.items) |doc| {
                if (index.removed(doc)) continue;
                try out.append(gpa, doc);
            }
        }
        // Ids rise across the segments of an index this code wrote; a
        // damaged one may repeat or reorder them, and callers count on ids
        // ascending.
        if (!strictlyAscending(u32, out.items)) {
            std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
            out.shrinkRetainingCapacity(dedupSorted(u32, out.items).len);
        }
    }

    pub fn postingBytes(index: *const Index) usize {
        var postings_size: usize = 0;
        for (index.segments) |segment| postings_size += segment.postings_size;
        return postings_size;
    }
};

/// A document whose old version an update replaced, or that is gone.
const flag_removed: u8 = 1;

/// Checks that `count` items of `size` bytes at `offset` fit in a buffer of
/// `buffer_size` bytes, with `offset` a multiple of `alignment`; returns
/// `offset`. Done in u64 with overflow checks: every operand comes from the
/// file.
fn region(
    buffer_size: usize,
    offset: u64,
    count: u64,
    size: u64,
    alignment: u64,
) error{BadIndex}!usize {
    if (offset % alignment != 0) return error.BadIndex;
    if (offset > buffer_size) return error.BadIndex;
    const bytes = std.math.mul(u64, count, size) catch return error.BadIndex;
    if (bytes > buffer_size - offset) return error.BadIndex;
    return @intCast(offset);
}

fn checkSegment(buf: []align(8) const u8, segment: SegmentEntry) error{BadIndex}!void {
    const keys_offset = try region(buf.len, segment.keys_offset, segment.keys_count, 4, 4);
    const keys_count: usize = @intCast(segment.keys_count); // Fits: bounded by buf.len.
    const offsets_count = std.math.add(u64, segment.keys_count, 1) catch return error.BadIndex;
    const offsets_offset = try region(buf.len, segment.offsets_offset, offsets_count, 4, 4);
    _ = try region(buf.len, segment.postings_offset, segment.postings_size, 1, 1);
    const keys = sliceAt(u32, @constCast(buf), keys_offset, keys_count);
    const offsets = sliceAt(u32, @constCast(buf), offsets_offset, keys_count + 1);
    if (!strictlyAscending(u32, keys)) return error.BadIndex;
    // Ascending: the last key is the largest.
    if (keys_count > 0 and keys[keys_count - 1] > trigram_mask) return error.BadIndex;
    var offset_previous: u32 = 0;
    for (offsets) |offset| {
        if (offset < offset_previous) return error.BadIndex;
        offset_previous = offset;
    }
    if (offsets[keys_count] > segment.postings_size) return error.BadIndex;
}

fn sliceAt(comptime T: type, buf: []align(8) u8, offset: usize, count: usize) []T {
    assert(offset % @alignOf(T) == 0);
    assert(offset + count * @sizeOf(T) <= buf.len);
    const items: [*]T = @ptrCast(@alignCast(buf.ptr + offset));
    return items[0..count];
}

fn dedupSorted(comptime T: type, items: []T) []T {
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

fn strictlyAscending(comptime T: type, items: []const T) bool {
    if (items.len < 2) return true;
    for (items[0 .. items.len - 1], items[1..]) |a, b| {
        if (a >= b) return false;
    }
    return true;
}

/// Next varint of `bytes` from `position`, or null at the end of the list or
/// on a malformed one: cut off by the end of the list (continuation bit on
/// the last byte) or longer than a u32 needs. Never reads past `bytes`.
fn readVarint(bytes: []const u8, position: *usize) ?u32 {
    var value: u32 = 0;
    var shift: u5 = 0;
    var i = position.*;
    while (i < bytes.len) : (i += 1) {
        const byte = bytes[i];
        // The 5th byte holds the top 4 bits and ends the number.
        if (shift == 28 and byte > 0x0f) return null;
        value |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            position.* = i + 1;
            return value;
        }
        shift += 7;
    }
    return null;
}

/// Decodes a posting list (first id, then deltas). A list from a damaged
/// file ends at the first id that is malformed, not increasing, overflowing
/// or not a document of the index: what comes out is always strictly
/// ascending and below `docs_count`, so callers can index the doc table
/// with it.
const ListReader = struct {
    list_encoded: []const u8,
    docs_count: usize,
    position: usize = 0,
    doc: u32 = 0,
    started: bool = false,

    fn next(reader: *ListReader) ?u32 {
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

fn writeVarint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var rest = value;
    while (rest >= 0x80) {
        try out.append(gpa, @intCast(rest & 0x7f | 0x80));
        rest >>= 7;
    }
    try out.append(gpa, @intCast(rest));
}

fn decodeAll(
    gpa: std.mem.Allocator,
    list_encoded: []const u8,
    docs_count: usize,
    out: *std.ArrayList(u32),
) !void {
    var reader: ListReader = .{ .list_encoded = list_encoded, .docs_count = docs_count };
    while (reader.next()) |doc| try out.append(gpa, doc);
}

/// `docs_sorted` ∩ `list_encoded`, decoded on the fly.
fn intersect(
    gpa: std.mem.Allocator,
    docs_sorted: []const u32,
    list_encoded: []const u8,
    docs_count: usize,
    out: *std.ArrayList(u32),
) !void {
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

// --------------------------------------------------------------- building

/// Reads a document's text into `buf` for indexing or verifying: false when
/// it has none to index (gone, binary, too big). `extracted` documents are
/// read from the text cache by the caller-provided resolver. Running out of
/// memory is an error, never "no text": the index would keep the document
/// empty until it changed.
pub const TextFn = *const fn (
    ctx: *anyopaque,
    doc: DocIn,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!bool;

/// A `TextFn` and the context it is called with.
pub const TextReader = struct {
    read: TextFn,
    ctx: *anyopaque,
    /// Most bytes of text `read` gives for an extracted document (its text
    /// is not the size of the file, the size of the cached text is); null:
    /// `extracted_bytes_max`.
    extracted_len: ?*const fn (ctx: *anyopaque, doc: DocIn) u64 = null,

    /// Most (trigram, doc) pairs reading `doc` can give: one per byte of
    /// text.
    fn mostPairs(reader: TextReader, doc: DocIn) usize {
        const text_size = switch (doc.source) {
            .plain => @min(doc.size, text_bytes_max),
            .extracted => if (reader.extracted_len) |extracted_len|
                @min(extracted_len(reader.ctx, doc), extracted_bytes_max)
            else
                extracted_bytes_max,
        };
        return @intCast(@min(text_size, 1 << 24));
    }
};

/// Plain text of a file: up to `text_bytes_max` bytes, rejected if binary
/// (a NUL in the first 8 KB, git's rule).
pub fn readPlain(
    gpa: std.mem.Allocator,
    path: []const u8,
    buf: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    buf.clearRetainingCapacity();
    var path_buffer: [4096]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0) catch return false;
    // Not a plain open: the path may have become a FIFO since it was indexed.
    const fd = sys.openRegular(path_z) catch return false;
    defer sys.close(fd);
    // One byte past the limit tells a file over it.
    try sys.readUpTo(gpa, fd, buf, text_bytes_max + 1);
    if (buf.items.len > text_bytes_max) return false;
    const head = buf.items[0..@min(buf.items.len, 8000)];
    return std.mem.findScalar(u8, head, 0) == null;
}

/// One round of reading: documents `lo..hi`, each taken by the next free
/// task (no fixed shares, so nobody waits for the slowest file of a share).
const ExtractCtx = struct {
    gpa: std.mem.Allocator,
    docs: []const DocIn,
    lo: usize,
    hi: usize,
    text: TextReader,
    /// Per task: trigram keys of the documents it read, in the order read.
    out: []std.ArrayList(u64),
    /// Per document of the round: where its pairs are in `out`.
    spans: []Pairs,
    next: std.atomic.Value(usize),
    /// Set by a task that ran out of memory: the build fails (and is retried
    /// later) instead of indexing its documents as empty.
    oom: std.atomic.Value(bool) = .init(false),
};

/// Where one document's pairs are: `out[task][start..][0..len]`.
const Pairs = struct { task: usize, start: usize, len: usize };

fn extractTask(ctx: *ExtractCtx, task: usize) void {
    extractTaskOrFail(ctx, task) catch ctx.oom.store(true, .release);
}

fn extractTaskOrFail(ctx: *ExtractCtx, task: usize) std.mem.Allocator.Error!void {
    const gpa = ctx.gpa;
    // One bit per possible trigram: dedup in O(n) without sorting.
    var seen: []u64 = &.{};
    defer gpa.free(seen);
    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const out = &ctx.out[task];
    while (true) {
        const doc = ctx.next.fetchAdd(1, .monotonic);
        if (doc >= ctx.hi) return;
        const start = out.items.len;
        defer ctx.spans[doc - ctx.lo] = .{
            .task = task,
            .start = start,
            .len = out.items.len - start,
        };
        if (!try ctx.text.read(ctx.text.ctx, ctx.docs[doc], &text, gpa)) continue;
        if (seen.len == 0) {
            seen = try gpa.alloc(u64, @divExact(trigram_mask + 1, 64));
            @memset(seen, 0);
        }
        keys.clearRetainingCapacity();
        var trigrams: Trigrams = .{ .text = text.items };
        while (trigrams.next()) |key| {
            const word = key >> 6;
            const bit = @as(u64, 1) << @intCast(key & 63);
            if (seen[word] & bit != 0) continue;
            seen[word] |= bit;
            try keys.append(gpa, key);
        }
        for (keys.items) |key| seen[key >> 6] &= ~(@as(u64, 1) << @intCast(key & 63));
        try out.ensureUnusedCapacity(gpa, keys.items.len);
        for (keys.items) |key| out.appendAssumeCapacity(@as(u64, key) << 32 | doc);
    }
}

pub const BuildStats = struct {
    docs_indexed: usize = 0,
    pairs: usize = 0,
    segments: usize = 0,
    ns: u64 = 0,
};

pub const BuildError = std.mem.Allocator.Error || error{
    BadIndex,
    /// More documents than u32 doc ids can number, or a doc table and its
    /// paths that end past what u32 path offsets reach (4 GiB).
    IndexTooLarge,
};
pub const FileError = BuildError || sys.Error;

/// Builds the index of `docs` (their order defines doc ids). `text` gives
/// each document's text; documents it rejects are kept (their path still
/// resolves) but have no postings.
pub fn build(
    gpa: std.mem.Allocator,
    pool: *Pool,
    docs: []const DocIn,
    text: TextReader,
    stats: ?*BuildStats,
) BuildError!Index {
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    return toMemory(
        &sink,
        buildInto(&sink, pool, docs, text, stats) catch |err| return memoryOnly(err),
    );
}

/// `build`, written to `path` as it grows (atomically, see
/// `sys.AtomicFile`) and returned mapped: the finished index (~80 MB for
/// 49 k files) is never whole in memory.
pub fn buildFile(
    gpa: std.mem.Allocator,
    pool: *Pool,
    docs: []const DocIn,
    text: TextReader,
    path_z: [:0]const u8,
    stats: ?*BuildStats,
) FileError!Index {
    var file = try sys.AtomicFile.create(path_z);
    errdefer file.abort();
    var sink: Sink = .{ .gpa = gpa, .file = &file };
    defer sink.deinit();
    return toFile(&sink, try buildInto(&sink, pool, docs, text, stats), path_z);
}

/// `old` with the documents `gone` (ids) marked removed and `added`
/// appended, indexed in segments of their own; `old`'s segments are copied
/// as they are. A few edited files cost reading those files, not the
/// thousands of others (a full build: ~1.1 s and ~270 MB for 49 k). Doc ids
/// of `old` keep their meaning, so lists stay ascending across segments.
pub fn update(
    gpa: std.mem.Allocator,
    pool: *Pool,
    old: *const Index,
    gone: []const u32,
    added: []const DocIn,
    text: TextReader,
    stats: ?*BuildStats,
) BuildError!Index {
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();
    return toMemory(
        &sink,
        updateInto(&sink, pool, old, gone, added, text, stats) catch |err| return memoryOnly(err),
    );
}

/// `update`, written to `path` (it may be the file `old` is mapped from:
/// that mapping keeps the old file) and returned mapped. `old`'s segments go
/// from its mapping to the file without passing through the heap.
pub fn updateFile(
    gpa: std.mem.Allocator,
    pool: *Pool,
    old: *const Index,
    gone: []const u32,
    added: []const DocIn,
    text: TextReader,
    path_z: [:0]const u8,
    stats: ?*BuildStats,
) FileError!Index {
    var file = try sys.AtomicFile.create(path_z);
    errdefer file.abort();
    var sink: Sink = .{ .gpa = gpa, .file = &file };
    defer sink.deinit();
    return toFile(&sink, try updateInto(&sink, pool, old, gone, added, text, stats), path_z);
}

/// `update` written at the end of the file `old` is mapped from, instead of
/// rewriting all of it (79 MB and an fsync for 49 k documents, every time
/// a few files changed): the new documents' segment, a new doc table and a
/// directory that refers to `old`'s segments where they are; then the
/// header, last. Bytes already there never change, so `old`'s mapping stays
/// good; what the previous table and directory took is left behind
/// (`bytes_live` says how much is still used). A run of small segments at
/// the end (one per update) is merged into the new one, without the
/// postings of removed documents. Null when the file is not as `old` saw it.
pub fn appendFile(
    gpa: std.mem.Allocator,
    pool: *Pool,
    old: *const Index,
    gone: []const u32,
    added: []const DocIn,
    text: TextReader,
    path_z: [:0]const u8,
    stats: ?*BuildStats,
) FileError!?Index {
    var file = (try sys.AppendFile.open(path_z, old.buf.len)) orelse return null;
    defer file.deinit();
    var sink: Sink = .{ .gpa = gpa, .app = &file, .written = file.len };
    defer sink.deinit();
    const header = try appendInto(&sink, pool, old, gone, added, text, stats);
    try sink.flush();
    // Everything the header will point at is on disk before it does.
    try file.sync();
    try file.writeAt(&header.encode(), 0);
    try file.sync();
    const index = try Index.open(path_z);
    // Read back as written (the pair of `finish`'s assertions).
    assert(index.docs_count == header.docs_count);
    assert(index.segments_count == header.segments_count);
    assert(index.file.len == header.size_total);
    return index;
}

/// A segment smaller than this is merged with the next update's.
const segment_small_size_max = 1 << 20;
/// How many small segments at the end make a merge.
const segments_small_merge_min = 4;

/// The old index's documents then `added` (ids are positions), and their
/// flags with `gone` marked removed.
const Merged = struct {
    docs: []DocIn,
    flags: []u8,

    fn deinit(merged: Merged, gpa: std.mem.Allocator) void {
        gpa.free(merged.docs);
        gpa.free(merged.flags);
    }
};

fn mergeDocs(
    gpa: std.mem.Allocator,
    old: *const Index,
    gone: []const u32,
    added: []const DocIn,
) (std.mem.Allocator.Error || error{IndexTooLarge})!Merged {
    const docs_count = old.docs_count + added.len;
    // Doc ids are u32 in posting lists and results.
    if (docs_count > std.math.maxInt(u32)) return error.IndexTooLarge;
    const docs = try gpa.alloc(DocIn, docs_count);
    errdefer gpa.free(docs);
    for (docs[0..old.docs_count], 0..) |*doc, id| doc.* = old.docIn(@intCast(id));
    @memcpy(docs[old.docs_count..], added);
    const flags = try gpa.alloc(u8, docs_count);
    @memcpy(flags[0..old.docs_count], old.flags);
    @memset(flags[old.docs_count..], 0);
    for (gone) |id| {
        assert(id < old.docs_count);
        flags[id] |= flag_removed;
    }
    return .{ .docs = docs, .flags = flags };
}

fn appendInto(
    sink: *Sink,
    pool: *Pool,
    old: *const Index,
    gone: []const u32,
    added: []const DocIn,
    text: TextReader,
    stats: ?*BuildStats,
) FileError!Header {
    const gpa = sink.gpa;
    const start_ns = sys.monotonicNs();
    var build_stats: BuildStats = .{};
    const merged = try mergeDocs(gpa, old, gone, added);
    defer merged.deinit(gpa);
    const docs = merged.docs;
    const flags = merged.flags;

    // The run of small segments at the end is merged into the new one, if
    // it is long enough to be worth it; the others stay where they are.
    var segments_kept_count = old.segments.len;
    while (segments_kept_count > 0) : (segments_kept_count -= 1) {
        const segment = old.segments[segments_kept_count - 1];
        if (segment.postings_size >= segment_small_size_max) break;
    }
    if (old.segments.len - segments_kept_count < segments_small_merge_min) {
        segments_kept_count = old.segments.len;
    }
    var dir: std.ArrayList(SegmentEntry) = .empty;
    defer dir.deinit(gpa);
    // Where they are: the file only grows.
    try dir.appendSlice(gpa, old.segments[0..segments_kept_count]);
    var pairs_merged: std.ArrayList(u64) = .empty;
    defer pairs_merged.deinit(gpa);
    for (old.segments[segments_kept_count..]) |segment| {
        try segmentPairs(gpa, old, segment, flags, &pairs_merged);
    }
    try indexDocs(sink, pool, &dir, docs, old.docs_count, text, &build_stats, pairs_merged.items);
    const table = try writeDocs(sink, docs, .{
        .flags = flags,
        .header = .none,
        .path_offsets_reused = old.path_offsets,
    });
    build_stats.docs_indexed = added.len;
    return finish(sink, dir.items, docs.len, table, start_ns, &build_stats, stats);
}

/// A segment's (trigram, doc) pairs, by trigram then doc, without the
/// documents `flags` mark removed.
fn segmentPairs(
    gpa: std.mem.Allocator,
    index: *const Index,
    segment: SegmentEntry,
    flags: []const u8,
    out: *std.ArrayList(u64),
) std.mem.Allocator.Error!void {
    const keys_count: usize = @intCast(segment.keys_count);
    const keys = sliceAt(u32, index.buf, @intCast(segment.keys_offset), keys_count);
    const offsets = sliceAt(u32, index.buf, @intCast(segment.offsets_offset), keys_count + 1);
    const postings_offset: usize = @intCast(segment.postings_offset);
    const postings = index.buf[postings_offset..][0..@intCast(segment.postings_size)];
    for (keys, 0..) |key, key_index| {
        var reader: ListReader = .{
            .list_encoded = postings[offsets[key_index]..offsets[key_index + 1]],
            .docs_count = index.docs_count,
        };
        while (reader.next()) |doc| {
            if (flags[doc] & flag_removed != 0) continue;
            try out.append(gpa, @as(u64, key) << 32 | doc);
        }
    }
}

/// Where an index is written: memory, where it becomes the index, or a file,
/// keeping only what is not written yet. Offsets are positions in the whole.
const Sink = struct {
    gpa: std.mem.Allocator,
    file: ?*sys.AtomicFile = null,
    /// Or the end of an existing file (`appendFile`).
    app: ?*sys.AppendFile = null,
    buf: BytesAligned8 = .empty,
    /// Bytes already in the file.
    written: usize = 0,

    /// Larger pieces go to the file directly instead of through `buf`.
    const direct = 64 * 1024;

    fn deinit(sink: *Sink) void {
        sink.buf.deinit(sink.gpa);
    }

    fn pos(sink: *const Sink) usize {
        return sink.written + sink.buf.items.len;
    }

    fn append(sink: *Sink, bytes: []const u8) FileError!void {
        if ((sink.file != null or sink.app != null) and bytes.len >= direct) {
            try sink.flush();
            try sink.put(bytes);
            sink.written += bytes.len;
            return;
        }
        try sink.buf.appendSlice(sink.gpa, bytes);
    }

    fn put(sink: *Sink, bytes: []const u8) FileError!void {
        if (sink.file) |f| return f.write(bytes);
        if (sink.app) |f| return f.write(bytes);
    }

    fn zeros(sink: *Sink, n: usize) FileError!void {
        try sink.buf.appendNTimes(sink.gpa, 0, n);
    }

    fn pad8(sink: *Sink) FileError!void {
        while (sink.pos() % 8 != 0) try sink.buf.append(sink.gpa, 0);
    }

    /// Writes what is buffered (file mode only).
    fn flush(sink: *Sink) FileError!void {
        if (sink.file == null and sink.app == null) return;
        try sink.put(sink.buf.items);
        sink.written += sink.buf.items.len;
        sink.buf.clearRetainingCapacity();
    }
};

/// A sink without a file never fails to write one.
fn memoryOnly(err: FileError) BuildError {
    return switch (err) {
        error.OutOfMemory, error.BadIndex, error.IndexTooLarge => |e| e,
        else => unreachable,
    };
}

fn toMemory(sink: *Sink, header: Header) BuildError!Index {
    @memcpy(sink.buf.items[0..header_size], &header.encode());
    const buf = try sink.buf.toOwnedSlice(sink.gpa);
    errdefer sink.gpa.free(buf);
    return Index.parse(buf, false);
}

fn toFile(sink: *Sink, header: Header, path_z: [:0]const u8) FileError!Index {
    try sink.flush();
    const f = sink.file.?;
    try f.writeAt(&header.encode(), 0);
    try f.commit();
    return Index.open(path_z);
}

fn buildInto(
    sink: *Sink,
    pool: *Pool,
    docs: []const DocIn,
    text: TextReader,
    stats: ?*BuildStats,
) FileError!Header {
    const start_ns = sys.monotonicNs();
    var build_stats: BuildStats = .{};
    var dir: std.ArrayList(SegmentEntry) = .empty;
    defer dir.deinit(sink.gpa);
    const table = try writeDocs(sink, docs, .{
        .flags = null,
        .header = .reserve,
        .path_offsets_reused = &.{},
    });
    try indexDocs(sink, pool, &dir, docs, 0, text, &build_stats, &.{});
    build_stats.docs_indexed = docs.len;
    return finish(sink, dir.items, docs.len, table, start_ns, &build_stats, stats);
}

fn updateInto(
    sink: *Sink,
    pool: *Pool,
    old: *const Index,
    gone: []const u32,
    added: []const DocIn,
    text: TextReader,
    stats: ?*BuildStats,
) FileError!Header {
    const gpa = sink.gpa;
    const start_ns = sys.monotonicNs();
    var build_stats: BuildStats = .{};
    const merged = try mergeDocs(gpa, old, gone, added);
    defer merged.deinit(gpa);
    const docs = merged.docs;
    const flags = merged.flags;

    var dir: std.ArrayList(SegmentEntry) = .empty;
    defer dir.deinit(gpa);
    const table = try writeDocs(sink, docs, .{
        .flags = flags,
        .header = .reserve,
        .path_offsets_reused = &.{},
    });
    for (old.segments) |segment| try copySegment(sink, &dir, old.buf, segment);
    try indexDocs(sink, pool, &dir, docs, old.docs_count, text, &build_stats, &.{});
    build_stats.docs_indexed = added.len;
    return finish(sink, dir.items, docs.len, table, start_ns, &build_stats, stats);
}

/// Where `writeDocs` put the doc table, and how many bytes of paths it
/// added after it.
const DocTableWritten = struct { offset: usize, paths_size: usize };

const WriteDocsOptions = struct {
    /// Each document's flags; none set when null.
    flags: ?[]const u8,
    /// A new file starts with room for the header; an append does not.
    header: enum { reserve, none },
    /// The first `path_offsets_reused.len` documents' paths are already in
    /// the file, at these offsets (an appended table); the others' are
    /// written after the table.
    path_offsets_reused: []const u32,
};

/// The doc table, then the paths it adds.
fn writeDocs(
    sink: *Sink,
    docs: []const DocIn,
    options: WriteDocsOptions,
) FileError!DocTableWritten {
    const reused = options.path_offsets_reused;
    assert(reused.len <= docs.len);
    if (options.flags) |flags| assert(flags.len == docs.len);
    switch (options.header) {
        .reserve => try sink.zeros(header_size),
        .none => assert(sink.pos() >= header_size),
    }
    try sink.pad8();
    var paths_size: usize = 0;
    for (docs[reused.len..]) |doc| paths_size += doc.path.len;
    // The path size column is u16; `DocIn.path` promises that it fits.
    for (docs) |doc| assert(doc.path.len <= path_bytes_max);
    const docs_offset = sink.pos();
    const paths_offset = docs_offset + docs.len * doc_size;
    // Path offsets are stored as u32, so the doc table and its paths must
    // end below 4 GiB.
    if (paths_offset + paths_size > std.math.maxInt(u32)) return error.IndexTooLarge;

    // Built in the buffer: nothing is written before the doc table is done.
    const table_start = sink.buf.items.len;
    try sink.zeros(align8(docs.len * doc_size + paths_size));
    const table = sink.buf.items;
    var cursor = table_start;
    for (docs) |doc| {
        std.mem.writeInt(i64, table[cursor..][0..8], doc.mtime, .little);
        cursor += @sizeOf(i64);
    }
    for (docs) |doc| {
        std.mem.writeInt(u64, table[cursor..][0..8], doc.size, .little);
        cursor += @sizeOf(u64);
    }
    var path_offset: usize = paths_offset;
    for (docs, 0..) |doc, doc_index| {
        if (doc_index < reused.len) {
            std.mem.writeInt(u32, table[cursor..][0..4], reused[doc_index], .little);
        } else {
            std.mem.writeInt(u32, table[cursor..][0..4], @intCast(path_offset), .little);
            path_offset += doc.path.len;
        }
        cursor += @sizeOf(u32);
    }
    for (docs) |doc| {
        std.mem.writeInt(u16, table[cursor..][0..2], @intCast(doc.path.len), .little);
        cursor += @sizeOf(u16);
    }
    for (docs) |doc| {
        table[cursor] = @backingInt(doc.source);
        cursor += 1;
    }
    if (options.flags) |flags| @memcpy(table[cursor..][0..docs.len], flags);
    cursor += docs.len;
    assert(cursor == table_start + docs.len * doc_size);

    for (docs[reused.len..]) |doc| {
        @memcpy(table[cursor..][0..doc.path.len], doc.path);
        cursor += doc.path.len;
    }
    assert(path_offset == paths_offset + paths_size);
    return .{ .offset = docs_offset, .paths_size = paths_size };
}

/// Indexes `docs[from..]` (ids are positions in `docs`), closing segments as
/// they fill; `initial` pairs (decoded from segments being merged, lower
/// ids) go first.
///
/// Memory stays bounded whatever the text: a round reads no more documents
/// than could give `round_pairs_max` pairs, and its pairs join the segment one
/// document at a time, closing it as soon as it is full. Pairs held: the
/// round's, the segment's (`segment_pairs_max` and one document's at most) and
/// as many to sort them.
fn indexDocs(
    sink: *Sink,
    pool: *Pool,
    dir: *std.ArrayList(SegmentEntry),
    docs: []const DocIn,
    from: usize,
    text: TextReader,
    build_stats: *BuildStats,
    initial: []const u64,
) FileError!void {
    const gpa = sink.gpa;
    var pairs: std.ArrayList(u64) = .empty;
    defer pairs.deinit(gpa);
    try pairs.appendSlice(gpa, initial);
    var scratch: std.ArrayList(u64) = .empty;
    defer scratch.deinit(gpa);
    const tasks = pool.threads.len + 1;
    const task_out = try gpa.alloc(std.ArrayList(u64), tasks);
    defer {
        for (task_out) |*out| out.deinit(gpa);
        gpa.free(task_out);
    }
    for (task_out) |*out| out.* = .empty;
    const spans = try gpa.alloc(Pairs, round_docs_max);
    defer gpa.free(spans);

    var lo = from;
    while (lo < docs.len) {
        const hi = roundEnd(docs, lo, text);
        var ctx: ExtractCtx = .{
            .gpa = gpa,
            .docs = docs,
            .lo = lo,
            .hi = hi,
            .text = text,
            .out = task_out,
            .spans = spans,
            .next = .init(lo),
        };
        pool.run(@min(tasks, hi - lo), &ctx, extractTask);
        if (ctx.oom.load(.acquire)) return error.OutOfMemory;
        // In doc order, which the stable radix sort turns into (key, doc).
        for (spans[0 .. hi - lo]) |span| {
            try pairs.appendSlice(gpa, task_out[span.task].items[span.start..][0..span.len]);
            if (pairs.items.len >= segment_pairs_max) {
                try closePairs(sink, dir, &pairs, &scratch, build_stats);
            }
        }
        // What a task kept from a large round would add up across rounds.
        for (task_out) |*out| {
            if (out.capacity > round_pairs_max / tasks) {
                out.clearAndFree(gpa);
            } else {
                out.clearRetainingCapacity();
            }
        }
        lo = hi;
    }
    if (pairs.items.len > 0) try closePairs(sink, dir, &pairs, &scratch, build_stats);
}

/// Where the round of documents from `lo` ends: `round_docs_max` documents, or
/// fewer when their text could give more than `round_pairs_max` pairs (one
/// document at least).
fn roundEnd(docs: []const DocIn, lo: usize, text: TextReader) usize {
    var hi = lo;
    var pairs_most: usize = 0;
    while (hi < docs.len and hi - lo < round_docs_max) : (hi += 1) {
        pairs_most += text.mostPairs(docs[hi]);
        if (hi > lo and pairs_most > round_pairs_max) break;
    }
    return hi;
}

fn closePairs(
    sink: *Sink,
    dir: *std.ArrayList(SegmentEntry),
    pairs: *std.ArrayList(u64),
    scratch: *std.ArrayList(u64),
    build_stats: *BuildStats,
) FileError!void {
    build_stats.pairs += pairs.items.len;
    try closeSegment(sink, dir, pairs.items, scratch);
    build_stats.segments += 1;
    pairs.clearRetainingCapacity();
    try sink.flush();
}

/// A segment of another index, as it is.
fn copySegment(
    sink: *Sink,
    dir: *std.ArrayList(SegmentEntry),
    from: []align(8) const u8,
    segment: SegmentEntry,
) FileError!void {
    const keys_count: usize = @intCast(segment.keys_count);
    const postings_size: usize = @intCast(segment.postings_size);
    try sink.pad8();
    const keys_offset = sink.pos();
    try sink.append(from[@intCast(segment.keys_offset)..][0 .. keys_count * @sizeOf(u32)]);
    try sink.pad8();
    const offsets_offset = sink.pos();
    const offsets_size = (keys_count + 1) * @sizeOf(u32);
    try sink.append(from[@intCast(segment.offsets_offset)..][0..offsets_size]);
    const postings_offset = sink.pos();
    try sink.append(from[@intCast(segment.postings_offset)..][0..postings_size]);
    try dir.append(sink.gpa, .{
        .keys_count = segment.keys_count,
        .keys_offset = keys_offset,
        .offsets_offset = offsets_offset,
        .postings_offset = postings_offset,
        .postings_size = segment.postings_size,
    });
}

/// The segment directory; returns the header to put first.
///
/// What `Index.parse` checks on reading is asserted here on writing, so a
/// file this code wrote and one it rejects can only differ by damage.
fn finish(
    sink: *Sink,
    dir: []const SegmentEntry,
    docs_count: usize,
    table: DocTableWritten,
    start_ns: u64,
    build_stats: *BuildStats,
    stats: ?*BuildStats,
) FileError!Header {
    try sink.pad8();
    const directory_offset = sink.pos();
    try sink.append(std.mem.sliceAsBytes(dir));
    const size_total = sink.pos();
    build_stats.ns = sys.monotonicNs() - start_ns;
    if (stats) |out| out.* = build_stats.*;

    assert(docs_count <= std.math.maxInt(u32));
    assert(table.offset >= header_size);
    assert(table.offset % 8 == 0);
    assert(table.offset + docs_count * doc_size + table.paths_size <= directory_offset);
    assert(directory_offset % 8 == 0);
    for (dir) |segment| {
        assert(segment.keys_offset % 4 == 0);
        assert(segment.offsets_offset % 4 == 0);
        assert(segment.postings_offset + segment.postings_size <= directory_offset);
    }
    return .{
        .magic = magic.*,
        .docs_count = docs_count,
        .segments_count = dir.len,
        .paths_size = table.paths_size,
        .docs_offset = table.offset,
        .directory_offset = directory_offset,
        .size_total = size_total,
        .reserved = @splat(0),
    };
}

const BytesAligned8 = std.array_list.Aligned(u8, .@"8");

/// Sorts a segment's pairs by trigram (stable, so docs stay ascending) and
/// appends keys, offsets and varint-delta lists.
///
/// Pairs decoded from a file (`appendFile` merges its last segments) are
/// not trusted to be in order: in a damaged file a later segment may list
/// a document again, or one lower than an earlier segment did. Those are
/// sorted whole and deduplicated, never encoded as wrapped deltas.
fn closeSegment(
    sink: *Sink,
    dir: *std.ArrayList(SegmentEntry),
    pairs: []u64,
    scratch: *std.ArrayList(u64),
) FileError!void {
    const gpa = sink.gpa;
    try scratch.resize(gpa, pairs.len);
    radixByKey(pairs, scratch.items);

    var lists: Lists = .{};
    defer lists.deinit(gpa);
    if (!try lists.encode(gpa, pairs)) {
        // A pair is its key then its doc, so a plain sort orders both.
        std.mem.sort(u64, pairs, {}, std.sort.asc(u64));
        lists.clear();
        const encoded = try lists.encode(gpa, dedupSorted(u64, pairs));
        assert(encoded);
    }

    try sink.pad8();
    const keys_offset = sink.pos();
    try sink.append(std.mem.sliceAsBytes(lists.keys.items));
    try sink.pad8();
    const offsets_offset = sink.pos();
    try sink.append(std.mem.sliceAsBytes(lists.offsets.items));
    const postings_offset = sink.pos();
    try sink.append(lists.postings.items);
    try dir.append(gpa, .{
        .keys_count = lists.keys.items.len,
        .keys_offset = keys_offset,
        .offsets_offset = offsets_offset,
        .postings_offset = postings_offset,
        .postings_size = lists.postings.items.len,
    });
}

/// A segment's keys, list offsets and posting lists, as they are written.
const Lists = struct {
    keys: std.ArrayList(u32) = .empty,
    /// One more than `keys`: list `i` is `postings[offsets[i]..offsets[i + 1]]`.
    offsets: std.ArrayList(u32) = .empty,
    postings: std.ArrayList(u8) = .empty,

    fn deinit(lists: *Lists, gpa: std.mem.Allocator) void {
        lists.keys.deinit(gpa);
        lists.offsets.deinit(gpa);
        lists.postings.deinit(gpa);
    }

    fn clear(lists: *Lists) void {
        lists.keys.clearRetainingCapacity();
        lists.offsets.clearRetainingCapacity();
        lists.postings.clearRetainingCapacity();
    }

    /// Encodes `pairs`, sorted by key. What `parse` checks on open is made
    /// sure of here: keys strictly ascending (binary search), each list's
    /// docs too (deltas never wrap). False, half done, when they are not.
    fn encode(
        lists: *Lists,
        gpa: std.mem.Allocator,
        pairs: []const u64,
    ) std.mem.Allocator.Error!bool {
        var i: usize = 0;
        while (i < pairs.len) {
            const key: u32 = @intCast(pairs[i] >> 32);
            if (lists.keys.getLastOrNull()) |key_previous| {
                if (key_previous >= key) return false;
            }
            try lists.keys.append(gpa, key);
            try lists.offsets.append(gpa, @intCast(lists.postings.items.len));
            var doc_previous: u32 = 0;
            var first = true;
            while (i < pairs.len and pairs[i] >> 32 == key) : (i += 1) {
                const doc: u32 = @truncate(pairs[i]);
                if (!first and doc <= doc_previous) return false;
                first = false;
                try writeVarint(gpa, &lists.postings, doc - doc_previous);
                doc_previous = doc;
            }
        }
        try lists.offsets.append(gpa, @intCast(lists.postings.items.len));
        assert(lists.offsets.items.len == lists.keys.items.len + 1);
        return true;
    }
};

/// The radix sort takes the 24 bits of a trigram in two passes.
const radix_bits = 12;
const radix_buckets = 1 << radix_bits;

comptime {
    assert(2 * radix_bits == 24);
    assert(radix_buckets - 1 == trigram_mask >> radix_bits);
}

/// LSD radix sort on bits 32..55 (the trigram), two stable passes of
/// `radix_bits` bits. `scratch` is as long as `pairs` and left garbled.
fn radixByKey(pairs: []u64, scratch: []u64) void {
    assert(scratch.len == pairs.len);
    var source = pairs;
    var target = scratch;
    inline for (.{ 32, 32 + radix_bits }) |shift| {
        var count: [radix_buckets + 1]usize = @splat(0);
        for (source) |pair| {
            const bucket: usize = @intCast((pair >> shift) & (radix_buckets - 1));
            count[bucket + 1] += 1;
        }
        for (1..radix_buckets + 1) |j| count[j] += count[j - 1];
        for (source) |pair| {
            const bucket: usize = @intCast((pair >> shift) & (radix_buckets - 1));
            target[count[bucket]] = pair;
            count[bucket] += 1;
        }
        std.mem.swap([]u64, &source, &target);
    }
    // Two passes: the result is back in `pairs`.
}

// -------------------------------------------------------------- verifying

pub const Match = struct {
    doc: u32,
    /// Occurrences of the first word (capped).
    count: u32,
    /// 1-based line of the first occurrence, and that line's text.
    line: u32,
    snippet: []const u8,
    score: i32,
};

/// Where a folded match lies in the ORIGINAL text: [start, end). Folding
/// changes lengths ("acción" is 7 bytes, its folded "accion" 6), so the end
/// is not start + needle.len.
pub const Span = struct { start: usize, end: usize };

/// Case- and accent-insensitive search (`core.fold`) for `needle` in `hay`,
/// from `from`: "accion", "ACCIÓN" and "acción" all find "Acción". Matches
/// start at a character, never inside a two-byte letter.
///
/// Verification reads whole documents (extracted PDFs run to megabytes), so
/// this is the hot loop of a content query. It looks for the needle's first
/// folded character 32 bytes at a time: either case of it when it is a
/// letter, plus the lead bytes of accented letters (0xC3-0xC5); the full
/// needle is compared, folded, only at those positions.
pub fn findFold(hay: []const u8, needle: []const u8, from: usize) ?Span {
    if (needle.len == 0) return null;
    // Folded once here, so the comparisons below read one byte per
    // character. An ASCII folded needle (nearly every query) gets the
    // tightest loop; a long one is folded on the fly instead.
    var needle_folded_buffer: [256]u8 = undefined;
    if (needle.len <= needle_folded_buffer.len) {
        const needle_folded = fold.foldInto(&needle_folded_buffer, needle);
        const count = needle_folded.len;
        if (fold.isAscii(needle_folded)) {
            return findFoldImpl(.ascii, hay, needle_folded, count, from);
        }
        return findFoldImpl(.folded, hay, needle_folded, count, from);
    }
    return findFoldImpl(.raw, hay, needle, fold.foldedLen(needle), from);
}

const NeedleKind = enum {
    /// Folded, every byte < 0x80.
    ascii,
    /// Folded: one byte per character.
    folded,
    /// As given: folded on the fly.
    raw,
};

fn findFoldImpl(
    comptime kind: NeedleKind,
    hay: []const u8,
    needle: []const u8,
    needle_folded_count: usize,
    from: usize,
) ?Span {
    // Each folded character takes at least one byte of `hay`.
    if (hay.len < needle_folded_count) return null;
    if (from > hay.len - needle_folded_count) return null;
    var j: usize = 0;
    const first = fold.step(needle, &j);
    const letter = first >= 'a' and first <= 'z';
    const last_start = hay.len - needle_folded_count;
    const V = @Vector(32, u8);
    var i = from;
    while (i + 32 <= last_start + 1) : (i += 32) {
        const v: V = hay[i..][0..32].*;
        var mask: u32 = undefined;
        if (letter) {
            // For a letter, `v | 0x20 == first` holds exactly for its two
            // cases (cheaper than folding A-Z first); plus every lead byte
            // of an accented letter (0xC3-0xC5, one unsigned compare).
            const cases: u32 = @bitCast(v | @as(V, @splat(0x20)) == @as(V, @splat(first)));
            const lead: u32 = @bitCast(v -% @as(V, @splat(0xC3)) <= @as(V, @splat(2)));
            mask = cases | lead;
        } else {
            // Nothing else folds: the byte itself.
            mask = @bitCast(v == @as(V, @splat(first)));
        }
        while (mask != 0) {
            const at = i + @ctz(mask);
            if (matchAt(kind, hay, at, needle, from)) |end| return .{ .start = at, .end = end };
            mask &= mask - 1;
        }
    }
    while (i <= last_start) : (i += 1) {
        const byte = hay[i];
        const candidate = std.ascii.toLower(byte) == first or
            (letter and byte >= 0xC3 and byte <= 0xC5);
        if (!candidate) continue;
        if (matchAt(kind, hay, i, needle, from)) |end| return .{ .start = i, .end = end };
    }
    return null;
}

/// End in `hay` of `needle` matched, folded, at `at`; null if it does not
/// match there or `at` is inside a two-byte letter (`from` starts a
/// character by definition).
inline fn matchAt(
    comptime kind: NeedleKind,
    hay: []const u8,
    at: usize,
    needle: []const u8,
    from: usize,
) ?usize {
    var k = at;
    var j: usize = 0;
    while (j < needle.len) {
        if (k >= hay.len) return null;
        switch (kind) {
            .ascii => {
                const h = hay[k];
                if (h < 0x80) {
                    if (std.ascii.toLower(h) != needle[j]) return null;
                    k += 1;
                } else if (fold.step(hay, &k) != needle[j]) return null;
                j += 1;
            },
            .folded => {
                if (fold.step(hay, &k) != needle[j]) return null;
                j += 1;
            },
            .raw => if (fold.step(hay, &k) != fold.step(needle, &j)) return null,
        }
    }
    if (at > from and fold.insideLetter(hay, at)) return null;
    return k;
}

/// `findFold`, start only.
pub fn findCI(hay: []const u8, needle: []const u8, from: usize) ?usize {
    const span = findFold(hay, needle, from) orelse return null;
    return span.start;
}

/// Reference for `findFold`: fold `hay[from..]` whole (remembering where
/// each folded character came from) and look for the folded needle in it.
fn findFoldNaive(gpa: std.mem.Allocator, hay: []const u8, needle: []const u8, from: usize) !?Span {
    if (needle.len == 0 or from > hay.len) return null;
    var folded: std.ArrayList(u8) = .empty;
    defer folded.deinit(gpa);
    var origin: std.ArrayList(usize) = .empty;
    defer origin.deinit(gpa);
    var i = from;
    while (i < hay.len) {
        try origin.append(gpa, i);
        try folded.append(gpa, fold.step(hay, &i));
    }
    try origin.append(gpa, hay.len);
    const fneedle = try fold.foldAlloc(gpa, needle);
    defer gpa.free(fneedle);
    const at = std.mem.find(u8, folded.items, fneedle) orelse return null;
    return .{ .start = origin.items[at], .end = origin.items[at + fneedle.len] };
}

pub const Verified = struct { count: u32, line: u32, snippet: []const u8, phrase: bool };

/// A hit further into its line than `snippet_lead_max` bytes starts the
/// snippet `snippet_lead` bytes before it, so that it shows.
const snippet_lead_max = 60;
const snippet_lead = 40;
const snippet_bytes_max = 200;

comptime {
    assert(snippet_lead <= snippet_lead_max);
    assert(snippet_lead < snippet_bytes_max);
}

/// Checks that `text` holds every word and describes the first hit. With
/// several words, the whole `phrase` (the query as typed) is looked for
/// first: when present, that is the hit shown. Matching is folded
/// (`findFold`); line and snippet come from the original text.
pub fn verify(
    text: []const u8,
    words: []const []const u8,
    phrase: []const u8,
    maybe_phrase: bool,
    arena: std.mem.Allocator,
) ?Verified {
    if (words.len == 0) return null;
    // The phrase holds every word: found, they need no looking for. Not
    // looked for where its trigrams are not all present (`maybe_phrase`).
    const phrase_hit = if (words.len > 1 and maybe_phrase) findFold(text, phrase, 0) else null;
    var first = phrase_hit;
    if (phrase_hit == null) {
        for (words, 0..) |word, word_index| {
            const word_hit = findFold(text, word, 0) orelse return null;
            if (word_index == 0) first = word_hit;
        }
    }
    const counted = if (phrase_hit != null) phrase else words[0];
    const hit = first.?;
    const at = hit.start;
    // The ranking stops caring after `count_cap` hits; so does counting
    // (in a 4 MB book, "the" would otherwise scan the whole text).
    var count: u32 = 0;
    var occurrence = hit;
    while (count < count_cap) {
        count += 1;
        occurrence = findFold(text, counted, occurrence.end) orelse break;
    }
    const newline_before = std.mem.findScalarLast(u8, text[0..at], '\n');
    const line_start = if (newline_before) |newline| newline + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
    const line_number: u32 = @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
    // Keep the hit visible: start the snippet a little before it.
    const snippet_start = if (at - line_start > snippet_lead_max) at - snippet_lead else line_start;
    const snippet_end = @min(line_end, snippet_start + snippet_bytes_max);
    const snippet = std.mem.trim(u8, text[snippet_start..snippet_end], " \t\r");
    return .{
        .count = count,
        .line = line_number,
        .snippet = arena.dupe(u8, utf8.validWindow(snippet)) catch "",
        .phrase = phrase_hit != null,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const TestDocs = struct {
    texts: []const []const u8,
    fn text(
        ctx: *anyopaque,
        d: DocIn,
        buf: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!bool {
        const self: *TestDocs = @ptrCast(@alignCast(ctx));
        const i = std.fmt.parseInt(usize, d.path, 10) catch return false;
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, self.texts[i]);
        return true;
    }
};

test "varint round trip and intersection" {
    const gpa = testing.allocator;
    var enc: std.ArrayList(u8) = .empty;
    defer enc.deinit(gpa);
    const ids = [_]u32{ 3, 4, 200, 70000, 70001, 5_000_000 };
    var prev: u32 = 0;
    for (ids) |d| {
        try writeVarint(gpa, &enc, d - prev);
        prev = d;
    }
    var dec: std.ArrayList(u32) = .empty;
    defer dec.deinit(gpa);
    try decodeAll(gpa, enc.items, 10_000_000, &dec);
    try testing.expectEqualSlices(u32, &ids, dec.items);
    var inter: std.ArrayList(u32) = .empty;
    defer inter.deinit(gpa);
    try intersect(gpa, &.{ 1, 4, 70000, 5_000_000, 6_000_000 }, enc.items, 10_000_000, &inter);
    try testing.expectEqualSlices(u32, &.{ 4, 70000, 5_000_000 }, inter.items);
}

test "candidates equal a brute-force scan, across segments, after save/open" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(9);
    const r = prng.random();
    const vocab = [_][]const u8{
        "arena", "allocator", "Config", "trigram", "posting", "lumen", "zig", "parser", "token", "Hyprland", "window",
        "élan",
    };
    var texts: std.ArrayList([]const u8) = .empty;
    defer {
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    var docs: std.ArrayList(DocIn) = .empty;
    defer {
        for (docs.items) |d| gpa.free(d.path);
        docs.deinit(gpa);
    }
    for (0..3000) |i| {
        var t: std.ArrayList(u8) = .empty;
        for (0..r.intRangeAtMost(usize, 1, 30)) |_| {
            try t.appendSlice(gpa, vocab[r.uintLessThan(usize, vocab.len)]);
            try t.append(gpa, if (r.boolean()) ' ' else '\n');
        }
        try texts.append(gpa, try t.toOwnedSlice(gpa));
        try docs.append(gpa, .{ .path = try gpa.print("{d}", .{i}), .mtime = 0, .size = 0 });
    }
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var td: TestDocs = .{ .texts = texts.items };
    var ix = try build(gpa, pool, docs.items, .{ .read = TestDocs.text, .ctx = &td }, null);
    defer ix.deinit(gpa);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&pbuf, "{s}/content.idx", .{dir}, 0);
    try ix.save(p);
    var mapped = try Index.open(p);
    defer mapped.deinit(gpa);
    try testing.expectEqualStrings("2999", mapped.path(2999));

    const queries = [_][]const []const u8{
        &.{"arena"},        &.{"ALLOC"}, &.{ "trigram", "lumen" }, &.{"hyprland window"},
        &.{"élan"},
        &.{"nothing here"},
    };
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    for (queries) |words| {
        try mapped.candidates(gpa, words, &got);
        // Every true match must be a candidate (no false negatives).
        for (texts.items, 0..) |t, i| {
            var all = true;
            for (words) |w| if (findCI(t, w, 0) == null) {
                all = false;
            };
            if (all) try testing.expect(std.mem.findScalar(u32, got.items, @intCast(i)) != null);
        }
    }
}

test "update: edited and deleted documents leave, new ones join, old ids keep their meaning" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 2);
    defer pool.destroy();
    var before: TestDocs = .{ .texts = &.{
        "alpha zanzibar",
        "bravo kilimanjaro",
        "charlie zanzibar",
    } };
    const docs = [_]DocIn{
        .{ .path = "0", .mtime = 1, .size = 1 },
        .{ .path = "1", .mtime = 1, .size = 1 },
        .{ .path = "2", .mtime = 1, .size = 1 },
    };
    var ix = try build(gpa, pool, &docs, .{ .read = TestDocs.text, .ctx = &before }, null);
    defer ix.deinit(gpa);

    // "1" edited, "2" deleted, "3" new. TestDocs reads a path's number as
    // the index of its text, so the edit is "1" with another text.
    var after: TestDocs = .{ .texts = &.{
        "alpha zanzibar",
        "delta okavango",
        "charlie zanzibar",
        "echo okavango",
    } };
    const added = [_]DocIn{ .{ .path = "1", .mtime = 2, .size = 1 }, .{
        .path = "3",
        .mtime = 2,
        .size = 1,
    } };
    var st: BuildStats = .{};
    var up = try update(
        gpa,
        pool,
        &ix,
        &.{ 1, 2 },
        &added,
        .{ .read = TestDocs.text, .ctx = &after },
        &st,
    );
    defer up.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), st.docs_indexed);
    try testing.expectEqual(ix.segments_count + 1, up.segments_count);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&pbuf, "{s}/content.idx", .{dir}, 0);
    try up.save(p);
    var mapped = try Index.open(p);
    defer mapped.deinit(gpa);

    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    for ([_]*const Index{ &up, &mapped }) |x| {
        try testing.expectEqual(@as(usize, 5), x.docs_count);
        try testing.expectEqual(@as(usize, 3), x.live());
        try testing.expect(x.removed(1) and x.removed(2) and !x.removed(0));
        try testing.expectEqualStrings("1", x.path(3));
        try testing.expectEqual(@as(i64, 2), x.mtimes[3]);
        try x.candidates(gpa, &.{"zanzibar"}, &got);
        try testing.expectEqualSlices(u32, &.{0}, got.items);
        try x.candidates(gpa, &.{"kilimanjaro"}, &got);
        try testing.expectEqual(@as(usize, 0), got.items.len);
        try x.candidates(gpa, &.{"okavango"}, &got);
        try testing.expectEqualSlices(u32, &.{ 3, 4 }, got.items);
    }

    // Written to a file as they grow: the same bytes. The update overwrites
    // the file its old index is mapped from, as the service does.
    const fp = try std.mem.printSentinel(&pbuf, "{s}/streamed.idx", .{dir}, 0);
    var built = try buildFile(
        gpa,
        pool,
        &docs,
        .{ .read = TestDocs.text, .ctx = &before },
        fp,
        null,
    );
    defer built.deinit(gpa);
    try testing.expect(built.mapped);
    try testing.expectEqualSlices(u8, ix.buf, built.buf);
    var streamed = try updateFile(
        gpa,
        pool,
        &built,
        &.{ 1, 2 },
        &added,
        .{ .read = TestDocs.text, .ctx = &after },
        fp,
        null,
    );
    defer streamed.deinit(gpa);
    try testing.expectEqualSlices(u8, up.buf, streamed.buf);
    try testing.expectEqualStrings("0", built.path(0));

    // Updated again, with only a removal: no new segment.
    var again = try update(
        gpa,
        pool,
        &mapped,
        &.{0},
        &.{},
        .{ .read = TestDocs.text, .ctx = &after },
        null,
    );
    defer again.deinit(gpa);
    try testing.expectEqual(mapped.segments_count, again.segments_count);
    try testing.expectEqual(@as(usize, 2), again.live());
    try again.candidates(gpa, &.{"zanzibar"}, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);
    try again.candidates(gpa, &.{"okavango"}, &got);
    try testing.expectEqualSlices(u32, &.{ 3, 4 }, got.items);
}

test "appended updates: same results as rewritten ones, old mappings stay good, small segments merge" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 2);
    defer pool.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&pbuf, "{s}/content.idx", .{dir}, 0);

    // Texts by id: 0-2 at first, then one edit or new file per round.
    const texts = [_][]const u8{
        "alpha zanzibar",
        "bravo kilimanjaro",
        "charlie zanzibar",
        "delta okavango",
        "echo zanzibar",
        "foxtrot serengeti",
        "golf okavango",
        "hotel kalahari",
        "india zanzibar",
    };
    var td: TestDocs = .{ .texts = &texts };
    const reader: TextReader = .{ .read = TestDocs.text, .ctx = &td };
    var first = [_]DocIn{
        .{ .path = "0", .mtime = 1, .size = 1 },
        .{ .path = "1", .mtime = 1, .size = 1 },
        .{ .path = "2", .mtime = 1, .size = 1 },
    };
    var cur = try buildFile(gpa, pool, &first, reader, p, null);
    defer cur.deinit(gpa);
    var mem = try build(gpa, pool, &first, reader, null);
    defer mem.deinit(gpa);

    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    var want: std.ArrayList(u32) = .empty;
    defer want.deinit(gpa);
    const words = [_][]const u8{
        "zanzibar",
        "okavango",
        "kilimanjaro",
        "serengeti",
        "kalahari",
        "alpha",
    };
    // Each round replaces document `round - 3` (gone) by a new one (added).
    var round: usize = 3;
    while (round < texts.len) : (round += 1) {
        var nbuf: [8]u8 = undefined;
        const added = [_]DocIn{.{
            .path = try std.mem.print(&nbuf, "{d}", .{round}),
            .mtime = 2,
            .size = 1,
        }};
        const gone = [_]u32{@intCast(round - 3)};
        const next = (try appendFile(gpa, pool, &cur, &gone, &added, reader, p, null)).?;
        const next_mem = try update(gpa, pool, &mem, &gone, &added, reader, null);
        // The old mapping still answers as before the append.
        try cur.candidates(gpa, &.{"zanzibar"}, &got);
        try mem.candidates(gpa, &.{"zanzibar"}, &want);
        try testing.expectEqualSlices(u32, want.items, got.items);
        cur.deinit(gpa);
        mem.deinit(gpa);
        cur = next;
        mem = next_mem;
        try testing.expectEqual(mem.docs_count, cur.docs_count);
        try testing.expectEqualSlices(u8, mem.flags, cur.flags);
        for (0..cur.docs_count) |i| try testing.expectEqualStrings(
            mem.path(@intCast(i)),
            cur.path(@intCast(i)),
        );
        for (words) |w| {
            try cur.candidates(gpa, &.{w}, &got);
            try mem.candidates(gpa, &.{w}, &want);
            try testing.expectEqualSlices(u32, want.items, got.items);
        }
    }
    // Six updates of tiny segments: merged, not six more segments.
    try testing.expect(cur.segments_count < mem.segments_count);
    try testing.expect(cur.buf.len > cur.bytes_live);

    // An append whose header never got written (a crash): the file still
    // opens as it was.
    {
        const fd: i32 = @intCast(linux.open(p, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0));
        defer _ = linux.close(fd);
        _ = linux.write(fd, "garbage after the end", 21);
    }
    var reopened = try Index.open(p);
    defer reopened.deinit(gpa);
    try testing.expectEqual(cur.docs_count, reopened.docs_count);
    try reopened.candidates(gpa, &.{"okavango"}, &got);
    try mem.candidates(gpa, &.{"okavango"}, &want);
    try testing.expectEqualSlices(u32, want.items, got.items);
    // And the next append is not fooled by it: the file is longer than the
    // index that was mapped, so it says so (the service rewrites instead).
    try testing.expect((try appendFile(gpa, pool, &cur, &.{}, &.{}, reader, p, null)) == null);
}

test "verify finds the line and counts hits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "first line\n  const a = ArenaAllocator.init(gpa);\nArenaAllocator again\n";
    const v = verify(text, &.{"arenaallocator"}, "arenaallocator", true, arena.allocator()).?;
    try testing.expectEqual(@as(u32, 2), v.line);
    try testing.expectEqual(@as(u32, 2), v.count);
    try testing.expectEqualStrings("const a = ArenaAllocator.init(gpa);", v.snippet);
    try testing.expect(
        verify(text, &.{ "arena", "missing" }, "arena missing", true, arena.allocator()) == null,
    );
    // The phrase wins over the first word's first occurrence.
    const p = verify(
        "again here\nsee ArenaAllocator again\n",
        &.{ "arenaallocator", "again" },
        "arenaallocator again",
        true,
        arena.allocator(),
    ).?;
    try testing.expectEqual(@as(u32, 2), p.line);
    try testing.expect(p.phrase);
}

// ---------------------------------------------------------------- search

/// Words of a query: split on spaces, folded (`core.fold`) into `arena`.
pub fn splitWords(
    arena: std.mem.Allocator,
    query: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, query, " \t");
    while (tokens.next()) |word| try words.append(arena, try fold.foldAlloc(arena, word));
    return words.items;
}

/// The file that holds a document's text: the document itself, or its
/// extracted text in a cache. Verification maps it instead of reading it,
/// so a hit on page 1 of a 4 MB book touches a few pages, not the book.
pub const PathFn = *const fn (ctx: *anyopaque, doc: DocIn, buf: []u8) ?[:0]const u8;

pub const SearchOptions = struct {
    /// Matches wanted, best first.
    limit: usize,
    /// Where each document's text is read from, and its context.
    text_path: PathFn,
    text_ctx: *anyopaque,
    /// Set by another thread once the answer is not wanted any more (a
    /// newer query waits): verification stops at the next candidate, and
    /// the matches so far are returned.
    stop: ?*const std.atomic.Value(bool) = null,
};

/// For plain documents only (benchmarks, tests).
pub fn plainPath(_: *anyopaque, doc: DocIn, buf: []u8) ?[:0]const u8 {
    if (doc.source != .plain) return null;
    return std.mem.printSentinel(buf, "{s}", .{doc.path}, 0) catch null;
}

/// A candidate in verification order: by `bound`, the most its score can
/// be once its text is read.
const Candidate = struct { doc: u32, bound: i32, maybe_phrase: bool };

/// Verification shared by the pool's threads: each takes the next candidate
/// (no batches, so nobody waits for the slowest file of a batch) until the
/// next one's bound cannot beat the `limit`-th match so far.
const VerifyCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    index: *const Index,
    words: []const []const u8,
    phrase: []const u8,
    candidates: []const Candidate,
    text_path: PathFn,
    text_ctx: *anyopaque,
    stop: ?*const std.atomic.Value(bool),
    arenas: []std.heap.ArenaAllocator,
    now_s: i64,
    next: std.atomic.Value(usize) = .init(0),
    /// The worst score among the best `top.len`, once there are that many.
    floor: std.atomic.Value(i32) = .init(std.math.minInt(i32)),
    /// Under `lock`: the best matches so far, snippets in `arena`.
    lock: std.Io.Mutex = .init,
    top: []Match,
    top_count: usize = 0,
    arena: std.mem.Allocator,
    oom: std.atomic.Value(bool) = .init(false),

    fn offer(ctx: *VerifyCtx, match: Match) void {
        ctx.lock.lockUncancelable(ctx.io);
        defer ctx.lock.unlock(ctx.io);
        assert(ctx.top_count <= ctx.top.len);
        var slot = ctx.top_count;
        if (ctx.top_count == ctx.top.len) {
            slot = worst(ctx.top);
            if (!matchRanksBefore(match, ctx.top[slot])) return;
        }
        var copy = match;
        copy.snippet = ctx.arena.dupe(u8, match.snippet) catch {
            ctx.oom.store(true, .release);
            return;
        };
        ctx.top[slot] = copy;
        if (ctx.top_count < ctx.top.len) ctx.top_count += 1;
        if (ctx.top_count == ctx.top.len) {
            ctx.floor.store(ctx.top[worst(ctx.top)].score, .release);
        }
    }
};

/// Ranking order: score, then doc id.
fn matchRanksBefore(a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.doc < b.doc;
}

/// Verification order: bound, then doc id.
fn candidateRanksBefore(a: Candidate, b: Candidate) bool {
    if (a.bound != b.bound) return a.bound > b.bound;
    return a.doc < b.doc;
}

fn worst(matches: []const Match) usize {
    assert(matches.len > 0);
    var worst_index: usize = 0;
    for (matches[1..], 1..) |match, match_index| {
        if (matchRanksBefore(matches[worst_index], match)) worst_index = match_index;
    }
    return worst_index;
}

fn verifyTask(ctx: *VerifyCtx, task: usize) void {
    var path_buffer: [4096]u8 = undefined;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    const arena = ctx.arenas[task].allocator();
    while (true) {
        if (ctx.stop) |stop| {
            if (stop.load(.acquire)) return;
        }
        const candidate_index = ctx.next.fetchAdd(1, .monotonic);
        if (candidate_index >= ctx.candidates.len) return;
        const candidate = ctx.candidates[candidate_index];
        // Candidates come by bound: none after this one can enter either.
        if (candidate.bound < ctx.floor.load(.acquire)) {
            ctx.next.store(ctx.candidates.len, .monotonic);
            return;
        }
        defer _ = ctx.arenas[task].reset(.retain_capacity);
        const doc = ctx.index.docIn(candidate.doc);
        const text_path = ctx.text_path(ctx.text_ctx, doc, &path_buffer) orelse continue;
        // Plain files (1 MB at most) are read into a reused buffer: cheaper
        // than map + unmap, whose TLB shootdown hits every core of a
        // 24-thread process. Extracted texts run to megabytes and usually
        // match early, so those are mapped and only touched where scanned.
        var mapped: ?[]align(8) u8 = null;
        defer if (mapped) |bytes| sys.unmap(bytes);
        const text: []const u8 = switch (doc.source) {
            .plain => blk: {
                // Out of memory: this candidate is left out of the results.
                const has_text = readPlain(ctx.gpa, text_path, &buf) catch false;
                if (!has_text) continue;
                break :blk buf.items;
            },
            .extracted => blk: {
                mapped = sys.mapPrivate(text_path) catch continue;
                break :blk mapped.?;
            },
        };
        const verified = verify(text, ctx.words, ctx.phrase, candidate.maybe_phrase, arena) orelse
            continue;
        const phrase_bonus: i32 = if (verified.phrase) phrase_max else 0;
        ctx.offer(.{
            .doc = candidate.doc,
            .count = verified.count,
            .line = verified.line,
            .snippet = verified.snippet,
            .score = rank(doc, verified.count, ctx.words, ctx.now_s) + phrase_bonus,
        });
    }
}

/// Hits counted per document; more do not change the ranking.
pub const count_cap = 10;
/// Score of each hit counted.
const count_score = 20;
/// Most of the hit count's weight in the final score.
const count_max: i32 = count_cap * count_score;
/// Bonus when several words appear together, exactly as typed.
const phrase_max: i32 = 250;
/// Bonus for each word that the file's name contains.
const name_word_score = 150;
/// Penalty for each folder between the root and the file.
const depth_penalty = 5;

/// More hits, a matching file name, recent edits and shallow paths first.
fn rank(doc: DocIn, count: u32, words: []const []const u8, now_s: i64) i32 {
    const counted: i32 = @intCast(@min(count, count_cap));
    return counted * count_score + staticScore(doc, words, now_s);
}

/// The part of the score known without opening the file.
fn staticScore(doc: DocIn, words: []const []const u8, now_s: i64) i32 {
    var score: i32 = 0;
    const slash = std.mem.findScalarLast(u8, doc.path, '/') orelse 0;
    const name = doc.path[slash + 1 ..];
    for (words) |word| {
        if (findFold(name, word, 0) != null) score += name_word_score;
    }
    // Saturating: mtimes come from the index file, which may be damaged.
    // Whole days: one edited in the future counts as today.
    const age_days = @divFloor(now_s -| doc.mtime, std.time.s_per_day);
    score += switch (age_days) {
        std.math.minInt(i64)...0 => 300,
        1...6 => 220,
        7...29 => 140,
        30...179 => 60,
        180...364 => 20,
        else => 0,
    };
    score -= @intCast(std.mem.count(u8, doc.path, "/") * depth_penalty);
    return score;
}

pub const candidates_verified_max = 4000;

/// The candidates, best bound first: what is known without reading them
/// (recency, depth, name) plus the most reading can add, so verification
/// stops as soon as the next one cannot beat the `limit`-th match. Owned
/// by `gpa`.
fn orderCandidates(
    index: *const Index,
    gpa: std.mem.Allocator,
    words: []const []const u8,
    phrase: []const u8,
    docs: []const u32,
    now_s: i64,
) std.mem.Allocator.Error![]Candidate {
    // Only documents holding every trigram of the whole phrase (spaces
    // included) can get its bonus: the others' bound leaves it out, so they
    // need not be read once enough better matches are in. Too short to
    // have trigrams, the phrase could be anywhere.
    const several = words.len > 1;
    var phrase_docs: std.ArrayList(u32) = .empty;
    defer phrase_docs.deinit(gpa);
    const phrase_known = several and phrase.len >= 3;
    if (phrase_known) try index.candidates(gpa, &.{phrase}, &phrase_docs);

    const ordered = try gpa.alloc(Candidate, docs.len);
    errdefer gpa.free(ordered);
    var phrase_index: usize = 0;
    for (docs, ordered) |doc, *candidate| {
        // Both lists ascend.
        const phrase_items = phrase_docs.items;
        while (phrase_index < phrase_items.len and phrase_items[phrase_index] < doc) {
            phrase_index += 1;
        }
        const phrase_has_doc = phrase_index < phrase_items.len and
            phrase_items[phrase_index] == doc;
        const maybe_phrase = several and (!phrase_known or phrase_has_doc);
        const bound_phrase: i32 = if (maybe_phrase) phrase_max else 0;
        candidate.* = .{
            .doc = doc,
            .maybe_phrase = maybe_phrase,
            .bound = staticScore(index.docIn(doc), words, now_s) + count_max + bound_phrase,
        };
    }
    std.mem.sort(Candidate, ordered, {}, struct {
        fn before(_: void, a: Candidate, b: Candidate) bool {
            return candidateRanksBefore(a, b);
        }
    }.before);
    return ordered;
}

/// Full query: candidates from the trigram lists, verified in parallel by
/// reading each file, ranked. Snippets live in `arena`; at most `limit`.
pub fn search(
    index: *const Index,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pool: *Pool,
    query: []const u8,
    opts: SearchOptions,
    out: *std.ArrayList(Match),
) std.mem.Allocator.Error!void {
    const limit = opts.limit;
    const text_path = opts.text_path;
    const text_ctx = opts.text_ctx;
    out.clearRetainingCapacity();
    if (limit == 0) return;
    const words = try splitWords(arena, query);
    const phrase = try fold.foldAlloc(arena, std.mem.trim(u8, query, " \t"));
    var longest: usize = 0;
    for (words) |word| longest = @max(longest, word.len);
    // Nothing a trigram can narrow.
    if (longest < 3) return;
    var docs: std.ArrayList(u32) = .empty;
    defer docs.deinit(gpa);
    try index.candidates(gpa, words, &docs);
    if (docs.items.len == 0) return;
    const now_s = sys.nowSeconds();

    const ordered = try orderCandidates(index, gpa, words, phrase, docs.items, now_s);
    defer gpa.free(ordered);

    const tasks = pool.threads.len + 1;
    const arenas = try gpa.alloc(std.heap.ArenaAllocator, tasks);
    defer {
        for (arenas) |*task_arena| task_arena.deinit();
        gpa.free(arenas);
    }
    for (arenas) |*task_arena| task_arena.* = .init(gpa);
    const top = try gpa.alloc(Match, limit);
    defer gpa.free(top);
    var ctx: VerifyCtx = .{
        .gpa = gpa,
        .io = pool.io,
        .index = index,
        .words = words,
        .phrase = phrase,
        .candidates = ordered[0..@min(ordered.len, candidates_verified_max)],
        .text_path = text_path,
        .text_ctx = text_ctx,
        .stop = opts.stop,
        .arenas = arenas,
        .now_s = now_s,
        .top = top,
        .arena = arena,
    };
    pool.run(@min(tasks, ctx.candidates.len), &ctx, verifyTask);
    if (ctx.oom.load(.acquire)) return error.OutOfMemory;
    try out.appendSlice(arena, top[0..ctx.top_count]);
    sortMatches(out.items);
}

fn sortMatches(matches: []Match) void {
    std.mem.sort(Match, matches, {}, struct {
        fn before(_: void, a: Match, b: Match) bool {
            return matchRanksBefore(a, b);
        }
    }.before);
}

test "SIMD findFold agrees with the naive folded scan" {
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    var hay: [400]u8 = undefined;
    // ASCII, accented letters (two bytes), a symbol, and stray UTF-8 bytes.
    const pieces = [_][]const u8{
        "a",    "b",    "c", "A", "B", " ", "C", "\n", ".", "z", "Z",
        "á",
        "Á",
        "ñ",
        "Ñ",
        "×",
        "\xC3", "\xA1", "n",
    };
    for (0..150) |_| {
        const want = r.intRangeAtMost(usize, 0, hay.len - 2);
        var n: usize = 0;
        while (n < want) {
            const p = pieces[r.uintLessThan(usize, pieces.len)];
            @memcpy(hay[n .. n + p.len], p);
            n += p.len;
        }
        const needles = [_][]const u8{
            "a",    "ab",   "AbC",      "zz", "c\n.", "B C a",
            "á",
            "ÁB",
            "n",
            "ñ a",
            "×",
            "\xA1", "\xC3", "aaaaaaaa",
            "ÑAN",
        };
        for (needles) |nd| {
            var from: usize = 0;
            while (from <= n) : (from += 37) {
                try testing.expectEqual(
                    try findFoldNaive(testing.allocator, hay[0..n], nd, from),
                    findFold(hay[0..n], nd, from),
                );
            }
        }
    }
}

/// `s` repeated `n` times, at comptime (Zig 0.17 has no `**`).
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const done = comptime blk: {
        @setEvalBranchQuota(n * 10 + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        break :blk out;
    };
    return &done;
}

test "folded search: accents and case, both ways, positions in the original" {
    const text = "Primera línea\nUna ACCIÓN rápida\nel Ñandú corre\n3×4 y 3x4\n";
    for ([_][]const u8{ "accion", "ACCIÓN", "acción", "Accion" }) |q| {
        const m = findFold(text, q, 0).?;
        try testing.expectEqualStrings("ACCIÓN", text[m.start..m.end]);
    }
    try testing.expectEqualStrings("Ñandú", blk: {
        const m = findFold(text, "nandu", 0).?;
        break :blk text[m.start..m.end];
    });
    try testing.expectEqualStrings("Ñandú", blk: {
        const m = findFold(text, "ÑANDÚ", 0).?;
        break :blk text[m.start..m.end];
    });
    try testing.expectEqualStrings("linea", blk: {
        const m = findFold("linea", "línea", 0).?;
        break :blk "linea"[m.start..m.end];
    });
    // A symbol is not a letter.
    const times = findFold(text, "×", 0).?;
    try testing.expectEqualStrings("×", text[times.start..times.end]);
    try testing.expectEqual(@as(?Span, null), findFold("3×4", "x", 0));
    try testing.expectEqual(@as(?Span, null), findFold("3x4", "×", 0));
    // Never from inside a two-byte letter.
    try testing.expectEqual(@as(?Span, null), findFold("á", "\xA1", 0));
    // A needle too long to fold up front (> 256 bytes) is folded on the fly.
    const long_needle = repeat("Á", 150) ++ "B";
    const long_hay = repeat("x", 40) ++ repeat("a", 160) ++ "b" ++ repeat("á", 150) ++ "b";
    try testing.expectEqual(
        try findFoldNaive(testing.allocator, long_hay, long_needle, 0),
        findFold(long_hay, long_needle, 0),
    );
    try testing.expectEqual(
        @as(?Span, .{ .start = 50, .end = 201 }),
        findFold(long_hay, long_needle, 0),
    );
    try testing.expectEqual(
        @as(?Span, .{ .start = 201, .end = long_hay.len }),
        findFold(long_hay, long_needle, 51),
    );

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "accion", "ACCIÓN", "acción" }) |q| {
        const words = try splitWords(a, q);
        const v = verify(text, words, words[0], true, a).?;
        try testing.expectEqual(@as(u32, 2), v.line);
        try testing.expectEqualStrings("Una ACCIÓN rápida", v.snippet);
    }
    const v = verify(
        text,
        try splitWords(a, "nandu corre"),
        try fold.foldAlloc(a, "nandu corre"),
        true,
        a,
    ).?;
    try testing.expectEqual(@as(u32, 3), v.line);
    try testing.expect(v.phrase);
    // Two hits of different lengths, counted without overlap.
    try testing.expectEqual(
        @as(u32, 3),
        verify("acción accion ACCIÓN", &.{"accion"}, "accion", true, a).?.count,
    );
}

const FileDocs = struct {
    fn text(
        _: *anyopaque,
        d: DocIn,
        buf: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!bool {
        return readPlain(gpa, d.path, buf);
    }
};

test "search: the top matches equal reading every document and ranking them all" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Few words, so documents share them, phrases occur by chance, and
    // scores tie (recency and depth vary too).
    const vocab = [_][]const u8{
        "select", "from", "where", "fn", "main", "the", "lumen", "index", "*", "use", "state",
        "café",
    };
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    const n = 400;
    var docs: [n]DocIn = undefined;
    const now = sys.nowSeconds();
    for (&docs, 0..) |*d, i| {
        var t: std.ArrayList(u8) = .empty;
        for (0..r.intRangeAtMost(usize, 3, 40)) |_| {
            try t.appendSlice(a, vocab[r.uintLessThan(usize, vocab.len)]);
            try t.append(a, if (r.uintLessThan(u8, 6) == 0) '\n' else ' ');
        }
        const sub = if (i % 3 == 0) "/deep/er" else "";
        if (sub.len > 0) {
            var mb: [4096]u8 = undefined;
            _ = linux.mkdir(try std.mem.printSentinel(&mb, "{s}/deep", .{dir}, 0), 0o700);
            _ = linux.mkdir(try std.mem.printSentinel(&mb, "{s}/deep/er", .{dir}, 0), 0o700);
        }
        const path = try a.print("{s}{s}/{s}{d}.txt", .{
            dir,
            sub,
            if (i % 7 == 0) "main" else "doc",
            i,
        });
        var zb: [4096]u8 = undefined;
        try sys.writeFile(try std.mem.printSentinel(&zb, "{s}", .{path}, 0), t.items);
        const ages = [_]i64{ 0, 3, 20, 100, 300, 900 };
        d.* = .{ .path = path, .mtime = now - ages[i % ages.len] * 86_400, .size = t.items.len };
    }
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var dummy: u8 = 0;
    var ix = try build(gpa, pool, &docs, .{ .read = FileDocs.text, .ctx = &dummy }, null);
    defer ix.deinit(gpa);

    var out: std.ArrayList(Match) = .empty;
    var want: std.ArrayList(Match) = .empty;
    var tbuf: std.ArrayList(u8) = .empty;
    defer tbuf.deinit(gpa);
    const queries = [_][]const u8{
        "select * from", "fn main",           "use state", "the lumen", "lumen", "where",
        "café index",
        "main",          "from where select",
    };
    for (queries) |q| for ([_]usize{ 5, 20 }) |limit| {
        try search(
            &ix,
            gpa,
            a,
            pool,
            q,
            .{ .limit = limit, .text_path = plainPath, .text_ctx = &dummy },
            &out,
        );
        // Every document read and ranked.
        want.clearRetainingCapacity();
        const words = try splitWords(a, q);
        const phrase = try fold.foldAlloc(a, std.mem.trim(u8, q, " \t"));
        for (docs, 0..) |d, i| {
            if (!try readPlain(gpa, d.path, &tbuf)) continue;
            const v = verify(tbuf.items, words, phrase, true, a) orelse continue;
            const bonus: i32 = if (v.phrase) phrase_max else 0;
            try want.append(a, .{
                .doc = @intCast(i),
                .count = v.count,
                .line = v.line,
                .snippet = v.snippet,
                .score = rank(d, v.count, words, now) + bonus,
            });
        }
        sortMatches(want.items);
        want.shrinkRetainingCapacity(@min(want.items.len, limit));
        try testing.expectEqual(want.items.len, out.items.len);
        for (want.items, out.items) |w, o| {
            try testing.expectEqual(w.doc, o.doc);
            try testing.expectEqual(w.score, o.score);
            try testing.expectEqual(w.line, o.line);
            try testing.expectEqualStrings(w.snippet, o.snippet);
        }
    };
}

test "search: unaccented and capital queries find accented text" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    const texts = [_][]const u8{
        "notas\nLa acción empieza aquí.\nfin\n",
        "el ÑANDÚ es un ave\n",
        "nothing to see\naccidental cion\n",
        "Configuración del sistema\n",
    };
    var paths: [texts.len][]u8 = undefined;
    var docs: [texts.len]DocIn = undefined;
    for (texts, 0..) |t, i| {
        paths[i] = try gpa.print("{s}/doc{d}.txt", .{ dir, i });
        var zb: [4096]u8 = undefined;
        try sys.writeFile(try std.mem.printSentinel(&zb, "{s}", .{paths[i]}, 0), t);
        docs[i] = .{ .path = paths[i], .mtime = 0, .size = t.len };
    }
    defer for (paths) |p| gpa.free(p);
    const pool = try Pool.create(gpa, testing.io, 2);
    defer pool.destroy();
    var dummy: u8 = 0;
    var ix = try build(gpa, pool, &docs, .{ .read = FileDocs.text, .ctx = &dummy }, null);
    defer ix.deinit(gpa);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(Match) = .empty;
    const cases = [_]struct { q: []const u8, doc: u32, line: u32, snippet: []const u8 }{
        .{ .q = "accion", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .q = "ACCIÓN", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .q = "acción", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .q = "nandu", .doc = 1, .line = 1, .snippet = "el ÑANDÚ es un ave" },
        .{ .q = "ñandú ave", .doc = 1, .line = 1, .snippet = "el ÑANDÚ es un ave" },
        .{ .q = "configuracion", .doc = 3, .line = 1, .snippet = "Configuración del sistema" },
        .{ .q = "aqui", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
    };
    for (cases) |c| {
        try search(
            &ix,
            gpa,
            arena.allocator(),
            pool,
            c.q,
            .{ .limit = 10, .text_path = plainPath, .text_ctx = &dummy },
            &out,
        );
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(c.doc, out.items[0].doc);
        try testing.expectEqual(c.line, out.items[0].line);
        try testing.expectEqualStrings(c.snippet, out.items[0].snippet);
    }
    try search(
        &ix,
        gpa,
        arena.allocator(),
        pool,
        "×yz",
        .{ .limit = 10, .text_path = plainPath, .text_ctx = &dummy },
        &out,
    );
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // Not wanted any more (a newer query waits): no file is read.
    var stop: std.atomic.Value(bool) = .init(true);
    try search(
        &ix,
        gpa,
        arena.allocator(),
        pool,
        "accion",
        .{ .limit = 10, .text_path = plainPath, .text_ctx = &dummy, .stop = &stop },
        &out,
    );
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// ------------------------------------------------- corrupt indexes, fuzzing

/// A small real index: 60 documents from a fixed vocabulary.
fn smallIndex(gpa: std.mem.Allocator) !Index {
    const vocab = [_][]const u8{
        "arena", "allocator", "Config", "trigram", "posting", "lumen", "zig", "parser", "token",
        "élan",
    };
    var texts: [60][]const u8 = undefined;
    var paths: [60][]const u8 = undefined;
    var docs: [60]DocIn = undefined;
    var n_made: usize = 0;
    defer for (texts[0..n_made], paths[0..n_made]) |t, p| {
        gpa.free(t);
        gpa.free(p);
    };
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    for (0..texts.len) |i| {
        var t: std.ArrayList(u8) = .empty;
        errdefer t.deinit(gpa);
        for (0..r.intRangeAtMost(usize, 1, 6)) |_| {
            try t.appendSlice(gpa, vocab[r.uintLessThan(usize, vocab.len)]);
            try t.append(gpa, ' ');
        }
        const p = try gpa.print("{d}", .{i});
        texts[i] = t.toOwnedSlice(gpa) catch |e| {
            gpa.free(p);
            return e;
        };
        paths[i] = p;
        n_made += 1;
        docs[i] = .{
            .path = p,
            .mtime = @intCast(i),
            .size = i,
            .source = if (i % 7 == 0) .extracted else .plain,
        };
    }
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var td: TestDocs = .{ .texts = &texts };
    return build(gpa, pool, &docs, .{ .read = TestDocs.text, .ctx = &td }, null);
}

/// Touches everything a reader of an index may touch: must never crash on
/// an index that `parse` accepted.
fn exerciseIndex(index: *const Index, gpa: std.mem.Allocator) !void {
    const queries = [_][]const []const u8{
        &.{"arena"}, &.{ "zig", "token" }, &.{"lumen config"},
        &.{"élan"},
        &.{"xyzzy"}, &.{ "pos", "ing" },
    };
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    var sum: usize = index.postingBytes();
    for (queries) |q| {
        try index.candidates(gpa, q, &got);
        try testing.expect(strictlyAscending(u32, got.items));
        for (got.items) |d| {
            try testing.expect(d < index.docs_count);
            const src: Source = @fromBackingInt(@intCast(index.sources[d]));
            sum +%= index.path(d).len +% @as(
                usize,
                @bitCast(index.mtimes[d]),
            ) +% index.sizes[d] +% @backingInt(src);
        }
    }
    for (0..index.docs_count) |d| sum +%= index.path(@intCast(d)).len;
    std.mem.doNotOptimizeAway(sum);
}

test "corrupt content indexes are rejected, not trusted" {
    const gpa = testing.allocator;
    var ix = try smallIndex(gpa);
    defer ix.deinit(gpa);
    const good = ix.buf;
    try exerciseIndex(&ix, gpa);

    const bad = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(bad);
    const H = struct {
        fn put(b: []u8, at: usize, v: u64) void {
            std.mem.writeInt(u64, b[at..][0..8], v, .little);
        }
        fn put32(b: []u8, at: usize, v: u32) void {
            std.mem.writeInt(u32, b[at..][0..4], v, .little);
        }
    };

    // Truncated anywhere, or empty: the total length no longer matches.
    for (0..good.len) |cut| try testing.expectError(
        error.BadIndex,
        Index.parse(good[0..cut], false),
    );

    const docs_offset = std.mem.readInt(u64, good[32..40], .little);
    const directory_offset = std.mem.readInt(u64, good[40..48], .little);
    const n = ix.docs_count;
    const seg = ix.segments[0];
    const max = std.math.maxInt(u64);
    const Case = struct { at: usize, v: u64, wide: bool = true };
    const cases = [_]Case{
        .{ .at = 0, .v = 0x3130585443_4d554c }, // magic of another version (LUMCTX01)
        .{ .at = 8, .v = max }, // doc count: overflows the layout
        .{ .at = 8, .v = n + 1 }, // count off by one: the arrays shift onto other data
        .{ .at = 8, .v = @as(u64, std.math.maxInt(u32)) + 1 },
        .{ .at = 16, .v = max / 8 }, // segment count
        .{ .at = 16, .v = ix.segments_count + 1 },
        .{ .at = 24, .v = good.len }, // paths blob past the end
        .{ .at = 32, .v = docs_offset + 4 }, // misaligned doc table
        .{ .at = 32, .v = good.len + 8 }, // past the end
        .{ .at = 32, .v = 0 }, // over the header
        .{ .at = 40, .v = directory_offset + 4 }, // misaligned directory
        .{ .at = 40, .v = good.len - 8 }, // directory past the end
        .{ .at = 48, .v = good.len - 1 }, // total length
        // Segment directory entry.
        .{ .at = directory_offset, .v = max }, // keys_count: overflows
        .{ .at = directory_offset, .v = seg.keys_count * 100 }, // keys past the end
        .{ .at = directory_offset + 8, .v = seg.keys_offset + 2 }, // misaligned keys
        .{ .at = directory_offset + 8, .v = good.len }, // keys past the end
        .{ .at = directory_offset + 16, .v = good.len - 4 }, // offsets past the end
        .{ .at = directory_offset + 24, .v = good.len }, // postings past the end
        .{ .at = directory_offset + 32, .v = good.len }, // postings longer than the file
        .{ .at = directory_offset + 32, .v = 0 }, // offsets beyond the postings
        // A path past the end of the file, an unknown document kind.
        .{ .at = docs_offset + n * 16, .v = 0xffff_fff0, .wide = false },
        .{ .at = docs_offset + n * 22, .v = 9, .wide = false },
        // Keys out of order (binary search would miss), offsets going back.
        .{ .at = seg.keys_offset, .v = 0xffff_ff, .wide = false },
        .{ .at = seg.offsets_offset + 4, .v = 0xffff_ffff, .wide = false },
    };
    for (cases, 0..) |c, i| {
        @memcpy(bad, good);
        if (c.at == docs_offset + n * 22) {
            bad[c.at] = @intCast(c.v);
        } else if (c.wide) H.put(bad, c.at, c.v) else H.put32(bad, c.at, @intCast(c.v));
        if (Index.parse(bad, false)) |_| {
            std.debug.print("case {d} accepted\n", .{i});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "malformed posting lists end, never over-read" {
    const gpa = testing.allocator;
    var pos: usize = 0;
    // Continuation bit on the last byte of a list.
    try testing.expectEqual(@as(?u32, null), readVarint(&.{0x80}, &pos));
    pos = 0;
    try testing.expectEqual(@as(?u32, 5), readVarint(&.{ 0x05, 0xff }, &pos));
    try testing.expectEqual(@as(?u32, null), readVarint(&.{ 0x05, 0xff }, &pos));
    try testing.expectEqual(@as(usize, 1), pos);
    // Longer than a u32, or a 5th byte with more than 4 bits.
    pos = 0;
    try testing.expectEqual(@as(?u32, null), readVarint(&.{ 0xff, 0xff, 0xff, 0xff, 0x1f }, &pos));
    pos = 0;
    try testing.expectEqual(@as(?u32, null), readVarint(
        &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 },
        &pos,
    ));
    pos = 0;
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), readVarint(
        &.{ 0xff, 0xff, 0xff, 0xff, 0x0f },
        &pos,
    ));
    try testing.expectEqual(@as(usize, 5), pos);

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
    }) |l| {
        out.clearRetainingCapacity();
        try decodeAll(gpa, l, 100, &out);
        try testing.expectEqualSlices(u32, &.{3}, out.items);
        out.clearRetainingCapacity();
        try intersect(gpa, &.{ 3, 4, 5, 99, 100, 101 }, l, 100, &out);
        try testing.expectEqualSlices(u32, &.{3}, out.items);
    }

    // The same inside a real index: every posting list's last byte gets
    // its continuation bit (each list now ends in a truncated varint).
    var ix = try smallIndex(gpa);
    defer ix.deinit(gpa);
    const seg = ix.segments[0];
    const offs = sliceAt(u32, ix.buf, seg.offsets_offset, seg.keys_count + 1);
    for (offs[1..]) |o| if (o > 0) {
        ix.buf[seg.postings_offset + o - 1] |= 0x80;
    };
    try exerciseIndex(&ix, gpa);
    // And with garbage postings: ids past the documents never come out.
    @memset(ix.buf[seg.postings_offset..][0..seg.postings_size], 0x7f);
    try exerciseIndex(&ix, gpa);
}

/// Texts of the documents tests add by updates: they share words with
/// `smallIndex`'s and with each other.
const update_texts = [_][]const u8{
    "arena zig élan",
    "token arena parser",
    "zig lumen posting",
    "config arena zig",
};

/// `smallIndex` (60 documents) updated four times, a document each (ids
/// 60-63): five segments, the last four small, which the next append
/// merges.
fn segmentedIndex(gpa: std.mem.Allocator, pool: *Pool) !Index {
    var ix = try smallIndex(gpa);
    errdefer ix.deinit(gpa);
    var td: TestDocs = .{ .texts = &update_texts };
    for (0..segments_small_merge_min) |i| {
        var nbuf: [8]u8 = undefined;
        const added = [_]DocIn{.{
            .path = try std.mem.print(&nbuf, "{d}", .{i}),
            .mtime = 100,
            .size = 1,
        }};
        const next = try update(gpa, pool, &ix, &.{}, &added, .{
            .read = TestDocs.text,
            .ctx = &td,
        }, null);
        ix.deinit(gpa);
        ix = next;
    }
    return ix;
}

/// `appendFile` without the file: `old`'s bytes, then what it appends.
fn appendMemory(
    gpa: std.mem.Allocator,
    pool: *Pool,
    old: *const Index,
    gone: []const u32,
    added: []const DocIn,
    text: TextReader,
) !Index {
    var sink: Sink = .{ .gpa = gpa, .written = old.buf.len };
    defer sink.deinit();
    const h = appendInto(&sink, pool, old, gone, added, text, null) catch |err|
        return memoryOnly(err);
    const buf = try gpa.alignedAlloc(u8, .@"8", old.buf.len + sink.buf.items.len);
    errdefer gpa.free(buf);
    @memcpy(buf[0..old.buf.len], old.buf);
    @memcpy(buf[old.buf.len..], sink.buf.items);
    @memcpy(buf[0..header_size], &h.encode());
    return Index.parse(buf, false);
}

/// What the service does with the index it mapped: updates it and appends
/// to it. Must never crash on an index that `parse` accepted, and must give
/// one that parses and answers.
fn exerciseUpdates(index: *const Index, gpa: std.mem.Allocator, pool: *Pool) !void {
    var td: TestDocs = .{ .texts = &update_texts };
    const reader: TextReader = .{ .read = TestDocs.text, .ctx = &td };
    const added = [_]DocIn{
        .{ .path = "0", .mtime = 200, .size = 1 },
        .{ .path = "3", .mtime = 200, .size = 1 },
    };
    const gone: []const u32 = if (index.docs_count > 0) &.{0} else &.{};
    var up = try update(gpa, pool, index, gone, &added, reader, null);
    defer up.deinit(gpa);
    try exerciseIndex(&up, gpa);
    var app = try appendMemory(gpa, pool, index, gone, &added, reader);
    defer app.deinit(gpa);
    try exerciseIndex(&app, gpa);
}

test "segments that repeat or reorder doc ids (a damaged file): queries, updates and appends cope" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var ix = try segmentedIndex(gpa, pool);
    defer ix.deinit(gpa);
    try testing.expectEqual(@as(usize, 5), ix.segments_count);
    // The last segment holds document 63 ("config arena zig") alone: each
    // of its lists is that id, one byte. Make it 61 ("token arena
    // parser"): "arena" lists 61 in segment 2 and again in segment 4, and
    // "zig" lists 62 in segment 3, then 61. Nothing `parse` checks.
    const last = ix.segments[4];
    @memset(ix.buf[@intCast(last.postings_offset)..][0..@intCast(last.postings_size)], 61);
    _ = try Index.parse(ix.buf, false);

    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    try ix.candidates(gpa, &.{"arena"}, &got);
    try testing.expect(strictlyAscending(u32, got.items));
    try testing.expect(std.mem.findScalar(u32, got.items, 61) != null);
    try ix.candidates(gpa, &.{"zig"}, &got);
    try testing.expect(strictlyAscending(u32, got.items));

    // Appended: the small segments (all five) are decoded and merged. That
    // asserted (a crash loop with safety checks, a wrapped delta and lost
    // results without).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&pbuf, "{s}/content.idx", .{dir}, 0);
    try ix.save(p);
    var mapped = try Index.open(p);
    defer mapped.deinit(gpa);
    var td: TestDocs = .{ .texts = &update_texts };
    const added = [_]DocIn{.{ .path = "0", .mtime = 300, .size = 1 }};
    var app = (try appendFile(
        gpa,
        pool,
        &mapped,
        &.{},
        &added,
        .{ .read = TestDocs.text, .ctx = &td },
        p,
        null,
    )).?;
    defer app.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), app.segments_count);
    try app.candidates(gpa, &.{"zig"}, &got);
    try testing.expect(strictlyAscending(u32, got.items));
    // 61 by the damage, 62, and 64 (the new "arena zig élan").
    for ([_]u32{ 61, 62, 64 }) |d| {
        try testing.expect(std.mem.findScalar(u32, got.items, d) != null);
    }
    try exerciseUpdates(&ix, gpa, pool);
}

/// Counts the bytes it holds and the most it held at once. Thread-safe.
const PeakAllocator = struct {
    child: std.mem.Allocator,
    lock: std.Io.Mutex = .init,
    held: usize = 0,
    peak: usize = 0,

    fn allocator(peak: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = peak, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn count(peak: *PeakAllocator, add: usize, sub: usize) void {
        peak.lock.lockUncancelable(testing.io);
        defer peak.lock.unlock(testing.io);
        peak.held = peak.held + add - sub;
        peak.peak = @max(peak.peak, peak.held);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const pa: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const p = pa.child.rawAlloc(len, a, ra) orelse return null;
        pa.count(len, 0);
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const pa: *PeakAllocator = @ptrCast(@alignCast(ctx));
        if (!pa.child.rawResize(m, a, n, ra)) return false;
        pa.count(n, m.len);
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const pa: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const p = pa.child.rawRemap(m, a, n, ra) orelse return null;
        pa.count(n, m.len);
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const pa: *PeakAllocator = @ptrCast(@alignCast(ctx));
        pa.child.rawFree(m, a, ra);
        pa.count(0, m.len);
    }
};

test "a round reads no more than round_pairs_max of possible text, one document at least" {
    var dummy: u8 = 0;
    const reader: TextReader = .{ .read = TestDocs.text, .ctx = &dummy };
    var docs: [2000]DocIn = undefined;
    for (&docs) |*d| d.* = .{ .path = "", .mtime = 0, .size = 4096 };
    // Small files: `round_docs_max` a round, and what is left at the end.
    try testing.expectEqual(@as(usize, round_docs_max), roundEnd(&docs, 0, reader));
    try testing.expectEqual(docs.len, roundEnd(&docs, docs.len - 5, reader));
    // Files of `text_bytes_max` or more (no more than that is read).
    for (&docs) |*d| d.size = 1 << 30;
    const round_docs_expected: usize = round_pairs_max / text_bytes_max;
    try testing.expectEqual(round_docs_expected, roundEnd(&docs, 0, reader));
    // Extracted text: as long as the reader says, else the most kept.
    for (&docs) |*d| d.source = .extracted;
    try testing.expectEqual(@as(usize, 1), roundEnd(&docs, 0, reader));
    const Len = struct {
        fn small(_: *anyopaque, _: DocIn) u64 {
            return 1000;
        }
    };
    var known = reader;
    known.extracted_len = Len.small;
    try testing.expectEqual(@as(usize, round_docs_max), roundEnd(&docs, 0, known));
}

test "building high-entropy text: memory stays bounded by rounds and segments" {
    // 24 files of 1 MB of random bytes: ~1 M distinct trigrams each, 24 M
    // pairs. Read in one round, they were all held three times at once
    // (per task, gathered, sorting); with rounds of 1024 files, any number
    // of such files was. Rounds bounded by documents only peak at ~380 MB
    // here (twice as much with twice the files), bounded by pairs ~200 MB,
    // whatever the number of files.
    const n = 24;
    var prng = std.Random.DefaultPrng.init(77);
    var texts: [n][]const u8 = undefined;
    var made: usize = 0;
    defer for (texts[0..made]) |t| testing.allocator.free(t);
    var docs: [n]DocIn = undefined;
    var names: [n][8]u8 = undefined;
    for (&texts, &docs, &names, 0..) |*t, *d, *name, i| {
        const b = try testing.allocator.alloc(u8, text_bytes_max);
        prng.random().bytes(b);
        t.* = b;
        made += 1;
        d.* = .{ .path = try std.mem.print(name, "{d}", .{i}), .mtime = 0, .size = text_bytes_max };
    }
    var pa: PeakAllocator = .{ .child = testing.allocator };
    const gpa = pa.allocator();
    const pool = try Pool.create(testing.allocator, testing.io, 3);
    defer pool.destroy();
    var td: TestDocs = .{ .texts = &texts };
    var st: BuildStats = .{};
    // Written as it grows, like the service does: the index is not held.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&pbuf, "{s}/content.idx", .{dir}, 0);
    const reader: TextReader = .{ .read = TestDocs.text, .ctx = &td };
    var ix = try buildFile(gpa, pool, &docs, reader, p, &st);
    defer ix.deinit(gpa);
    try testing.expect(st.pairs > 20 << 20);
    try testing.expect(st.segments >= 5);
    // A round (4 M pairs, plus growth), a segment (4 M and a document's
    // 1 M) and the sort's scratch, at 8 bytes a pair; the encoded segment
    // before it is written; per task a 2 MB trigram map and a text.
    try testing.expect(pa.peak < 250 << 20);
}

test "random byte flips in a content index never crash, nor updating it" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var ix = try segmentedIndex(gpa, pool);
    defer ix.deinit(gpa);
    const bad = try gpa.alignedAlloc(u8, .@"8", ix.buf.len);
    defer gpa.free(bad);
    var prng = std.Random.DefaultPrng.init(23);
    const r = prng.random();
    var accepted: usize = 0;
    for (0..3000) |_| {
        @memcpy(bad, ix.buf);
        for (0..r.intRangeAtMost(usize, 1, 4)) |_| bad[r.uintLessThan(usize, bad.len)] = r.int(u8);
        if (Index.parse(bad, false)) |m| {
            try exerciseIndex(&m, gpa);
            try exerciseUpdates(&m, gpa, pool);
            accepted += 1;
        } else |_| {}
    }
    try testing.expect(accepted > 0);
}

fn fuzzParseBytes(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [16384]u8 align(8) = undefined;
    const b = buf[0..smith.slice(&buf)];
    // Often make the header plausible, so the fuzzer reaches the checks
    // behind it.
    if (b.len >= header_size and smith.value(bool)) {
        @memcpy(b[0..8], magic);
        const room = (b.len - header_size) / doc_size;
        const n = smith.valueRangeAtMost(u32, 0, @intCast(@min(room, 1000)));
        const paths_size = smith.valueRangeAtMost(u32, 0, @intCast(
            b.len - header_size - n * doc_size,
        ));
        const directory_offset = align8(header_size + n * doc_size + paths_size);
        std.mem.writeInt(u64, b[8..16], n, .little);
        std.mem.writeInt(u64, b[16..24], smith.valueRangeAtMost(u8, 0, 4), .little);
        std.mem.writeInt(u64, b[24..32], paths_size, .little);
        std.mem.writeInt(u64, b[32..40], header_size, .little);
        std.mem.writeInt(u64, b[40..48], directory_offset, .little);
        std.mem.writeInt(u64, b[48..56], b.len, .little);
    }
    if (Index.parse(b, false)) |ix| try exerciseIndex(&ix, testing.allocator) else |_| {}
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

test "fuzz: parsing arbitrary bytes as a content index never crashes" {
    const gpa = testing.allocator;
    var ix = try smallIndex(gpa);
    defer ix.deinit(gpa);
    const seed = try corpusEntry(gpa, ix.buf);
    defer gpa.free(seed);
    try testing.fuzz({}, fuzzParseBytes, .{ .corpus = &.{seed} });
}

const FlipsCtx = struct { good: []const u8, pool: *Pool };

fn fuzzFlips(ctx: FlipsCtx, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    const good = ctx.good;
    const buf = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(buf);
    @memcpy(buf, good);
    const flips = smith.valueRangeAtMost(u8, 0, 8);
    for (0..flips) |_| buf[smith.index(buf.len)] = smith.value(u8);
    // Sometimes a whole u32 or u64 field, aligned like the real ones.
    if (smith.boolWeighted(3, 1)) {
        const at = smith.index(buf.len / 4) * 4;
        std.mem.writeInt(u32, buf[at..][0..4], smith.value(u32), .little);
    }
    const cut = if (smith.boolWeighted(7, 1)) smith.index(buf.len + 1) else buf.len;
    const ix = Index.parse(buf[0..cut], false) catch return;
    try exerciseIndex(&ix, gpa);
    try exerciseUpdates(&ix, gpa, ctx.pool);
}

test "fuzz: a real content index with random damage never crashes, nor updating it" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var ix = try segmentedIndex(gpa, pool);
    defer ix.deinit(gpa);
    try testing.fuzz(FlipsCtx{ .good = ix.buf, .pool = pool }, fuzzFlips, .{});
}

fn fuzzFindFold(_: void, smith: *testing.Smith) anyerror!void {
    // Few distinct bytes, mixed case, and the bytes of accented letters
    // (0xC3 + 0xA1 = á, 0x81 = Á, 0x97 = ×), so folded matches are common.
    const w: []const testing.Smith.Weight = &.{
        .value(u8, 'a', 20),
        .value(u8, 'A', 20),
        .value(u8, 'b', 10),
        .value(u8, 'B', 10),
        .value(u8, ' ', 5),
        .value(u8, '\n', 3),
        .value(u8, 0xC3, 10),
        .value(u8, 0xA1, 6),
        .value(u8, 0x81, 4),
        .value(u8, 0x97, 2),
        .value(u8, 0xC5, 2),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var hay: [300]u8 = undefined;
    var needle: [12]u8 = undefined;
    const h = hay[0..smith.sliceWeightedBytes(&hay, w)];
    const n = needle[0..smith.sliceWeightedBytes(&needle, w)];
    const from = smith.valueRangeAtMost(u32, 0, @intCast(h.len + 2));
    try testing.expectEqual(try findFoldNaive(testing.allocator, h, n, from), findFold(h, n, from));
}

test "fuzz: findFold agrees with the naive folded scan" {
    try testing.fuzz({}, fuzzFindFold, .{ .corpus = &.{
        "\x40\x00\x00\x00" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaAb" ++ "\x02\x00\x00\x00ab",
        "\x40\x00\x00\x00" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xC3\x81\xC3\xA1b \xC3\x97" ++ "\x03\x00\x00\x00aAb",
        "\x10\x00\x00\x00" ++ "xx\xC3\xA1\xC3\xA1\xC3\x97\xA1\xC3\xC3\xA1bb" ++ "\x02\x00\x00\x00\xC3\x97",
    } });
}

fn fuzzVerify(_: void, smith: *testing.Smith) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w: []const testing.Smith.Weight = &.{
        .value(u8, 'a', 20),
        .value(u8, 'b', 10),
        .value(u8, ' ', 8),
        .value(u8, '\n', 4),
        .rangeAtMost(u8, 0x80, 0xff, 1),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var text: [600]u8 = undefined;
    var query: [16]u8 = undefined;
    const t = text[0..smith.sliceWeightedBytes(&text, w)];
    const q = query[0..smith.sliceWeightedBytes(&query, w)];
    const words = try splitWords(a, q);
    const phrase = try fold.foldAlloc(a, std.mem.trim(u8, q, " \t"));
    if (verify(t, words, phrase, true, a)) |v| {
        try testing.expect(std.unicode.utf8ValidateSlice(v.snippet));
        try testing.expect(v.count >= 1 and v.count <= count_cap and v.line >= 1);
    }
}

test "fuzz: verify on arbitrary text and queries" {
    try testing.fuzz({}, fuzzVerify, .{ .corpus = &.{
        "\x0d\x00\x00\x00ab\nxx ab ab b" ++ "\x05\x00\x00\x00ab  b",
    } });
}
