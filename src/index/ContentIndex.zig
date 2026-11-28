//! A content index file, mapped or in memory, checked once on open
//! (`parse`) and then read in place: the doc table's columns, and per
//! segment the sorted trigram keys and their posting lists
//! (`content_format.zig` has the layout). `candidates` answers the first
//! half of a query, which documents hold every trigram of every word;
//! `content_search.zig` verifies and ranks them.
//!
//! Read-only once made, so any number of threads may read it at once.

const std = @import("std");
const assert = std.debug.assert;
const sys = @import("os");
const format = @import("format.zig");
const Bytes = format.Bytes;
const BytesConst = format.BytesConst;
const alignUp = format.alignUp;
const corpusEntry = format.corpusEntry;
const content_format = @import("content_format.zig");
const magic = content_format.magic;
const header_size = content_format.header_size;
const Header = content_format.Header;
const SegmentEntry = content_format.SegmentEntry;
const doc_size = content_format.doc_size;
const flag_removed = content_format.flag_removed;
const DocIn = content_format.DocIn;
const Source = content_format.Source;
const Trigrams = content_format.Trigrams;
const trigram_mask = content_format.trigram_mask;
const decodeAll = content_format.decodeAll;
const intersect = content_format.intersect;
const sliceAt = content_format.sliceAt;
const sliceAtConst = content_format.sliceAtConst;
const dedupSorted = content_format.dedupSorted;
const strictlyAscending = content_format.strictlyAscending;

const ContentIndex = @This();

/// Max segments cached inline in the struct so reads of a segment
/// (`segmentAt`) never re-read the segment directory from a `MAP_PRIVATE`
/// mapping. Above `ContentService.Options.segments_max`.
const segments_inline_max = 64;

bytes: Bytes,
backing: format.Backing,
file_id: ?sys.FileId = null,
docs_count: usize,
segments_count: usize,
/// Of `segments_count`, those the last whole build made (0: not known, a
/// file from before it was kept); the rest were added by updates.
whole_segments_count: usize = 0,
mtimes: []const i64,
sizes: []const u64,
ctimes: []const i64,
path_offsets: []const u32,
path_sizes: []const u16,
sources: []const u8,
flags: []const u8,
/// The file up to `Header.size_total`: paths are found at their offsets
/// in it.
file: BytesConst,
segments: []const SegmentEntry,
segments_inline: [segments_inline_max]SegmentEntry = undefined,
segments_copied: usize = 0,
/// Documents flagged removed: their ids stay, queries skip them.
docs_removed_count: usize,
/// Live documents whose text was extracted (`extractedLive`).
extracted_live_count: usize,
/// Bytes the header refers to; the rest of the file is what updates
/// left behind (old doc tables, merged segments).
bytes_live: usize,

/// The doc table of an index file, checked: every path inside the file,
/// every source a known kind, no unknown flag.
const DocColumns = struct {
    mtimes: []const i64,
    sizes: []const u64,
    ctimes: []const i64,
    path_offsets: []const u32,
    path_sizes: []const u16,
    sources: []const u8,
    flags: []u8,
    /// Bytes of all paths, documents marked removed, and live documents
    /// whose text was extracted.
    paths_size_total: usize,
    docs_removed_count: usize,
    extracted_live_count: usize,

    fn parse(
        file: Bytes,
        docs_offset: usize,
        docs_count: usize,
    ) error{BadIndex}!DocColumns {
        assert(docs_offset % format.alignment_bytes == 0);
        assert(docs_offset + docs_count * doc_size <= file.len);
        var cursor = docs_offset;
        var columns: DocColumns = undefined;
        columns.mtimes = sliceAt(i64, file, cursor, docs_count);
        cursor += docs_count * @sizeOf(i64);
        columns.sizes = sliceAt(u64, file, cursor, docs_count);
        cursor += docs_count * @sizeOf(u64);
        columns.ctimes = sliceAt(i64, file, cursor, docs_count);
        cursor += docs_count * @sizeOf(i64);
        columns.path_offsets = sliceAt(u32, file, cursor, docs_count);
        cursor += docs_count * @sizeOf(u32);
        columns.path_sizes = sliceAt(u16, file, cursor, docs_count);
        cursor += docs_count * @sizeOf(u16);
        columns.sources = file[cursor..][0..docs_count];
        cursor += docs_count;
        columns.flags = file[cursor..][0..docs_count];
        cursor += docs_count;
        assert(cursor == docs_offset + docs_count * doc_size);

        columns.paths_size_total = 0;
        for (columns.path_offsets, columns.path_sizes) |path_offset, path_size| {
            if (path_size > 0 and path_offset < header_size) return error.BadIndex;
            if (@as(u64, path_offset) + path_size > file.len) return error.BadIndex;
            columns.paths_size_total = std.math.add(
                usize,
                columns.paths_size_total,
                path_size,
            ) catch
                return error.BadIndex;
            if (columns.paths_size_total > file.len) return error.BadIndex;
        }
        for (columns.sources) |source| {
            if (std.enums.fromInt(Source, source) == null) return error.BadIndex;
        }
        columns.docs_removed_count = 0;
        columns.extracted_live_count = 0;
        for (columns.flags, columns.sources) |flags, source| {
            if (flags & ~flag_removed != 0) return error.BadIndex;
            columns.docs_removed_count += flags & flag_removed;
            const extracted = source == @backingInt(Source.extracted);
            columns.extracted_live_count += @intFromBool(extracted and flags & flag_removed == 0);
        }
        return columns;
    }
};

/// Whether its file was truncated under it (`format.damaged`).
pub fn damaged(index: *const ContentIndex) bool {
    return format.damaged(index.bytes, index.backing);
}

pub fn deinit(index: *ContentIndex, gpa: std.mem.Allocator) void {
    format.release(index.bytes, index.backing, gpa);
    index.* = undefined;
}

pub fn path(index: *const ContentIndex, doc: u32) []const u8 {
    assert(doc < index.docs_count);
    const offset = index.path_offsets[doc];
    const size = index.path_sizes[doc];
    if (@as(u64, offset) + size > index.file.len) return "";
    return index.file[offset..][0..size];
}

pub fn removed(index: *const ContentIndex, doc: u32) bool {
    assert(doc < index.docs_count);
    return index.flags[doc] & flag_removed != 0;
}

/// Documents a query can find.
pub fn live(index: *const ContentIndex) usize {
    assert(index.docs_removed_count <= index.docs_count);
    return index.docs_count - index.docs_removed_count;
}

/// Whether document `doc` is still indexed and its text was extracted
/// (a PDF, an Office file) rather than read from the file itself.
pub fn extractedLive(index: *const ContentIndex, doc: u32) bool {
    return !index.removed(doc) and
        index.sources[doc] == @backingInt(Source.extracted);
}

/// How many documents `extractedLive` is true for: counted once, when
/// the index is parsed (it never changes after), not on every status.
pub fn extractedCount(index: *const ContentIndex) usize {
    assert(index.extracted_live_count <= index.live());
    return index.extracted_live_count;
}

pub fn docIn(index: *const ContentIndex, doc: u32) DocIn {
    assert(doc < index.docs_count);
    return .{
        .path = index.path(doc),
        .mtime = index.mtimes[doc],
        .size = index.sizes[doc],
        .source = std.enums.fromInt(Source, index.sources[doc]) orelse .plain,
        .ctime = index.ctimes[doc],
    };
}

/// Checks that `whole` is a well-formed index and wraps it without
/// copying (`backing` says how `deinit` releases it).
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
pub fn parse(whole: Bytes, backing: format.Backing) error{BadIndex}!ContentIndex {
    if (whole.len < header_size) return error.BadIndex;
    const header = Header.decode(whole[0..header_size]);
    if (!std.mem.eql(u8, &header.magic, magic)) return error.BadIndex;
    if (header.size_total > whole.len) return error.BadIndex;
    if (header.size_total < header_size) return error.BadIndex;
    const file = whole[0..@intCast(header.size_total)];
    // Doc ids are u32 in posting lists and results.
    if (header.docs_count > std.math.maxInt(u32)) return error.BadIndex;
    const docs_count: usize = @intCast(header.docs_count);
    const docs_offset = try region(
        file.len,
        header.docs_offset,
        docs_count,
        doc_size,
        format.alignment_bytes,
    );
    if (docs_offset < header_size) return error.BadIndex;
    const paths_offset = docs_offset + docs_count * doc_size;
    if (header.paths_size > file.len - paths_offset) return error.BadIndex;
    const directory_offset = try region(
        file.len,
        header.directory_offset,
        header.segments_count,
        @sizeOf(SegmentEntry),
        format.alignment_bytes,
    );
    if (directory_offset < header_size) return error.BadIndex;
    const segments_count: usize = @intCast(header.segments_count);

    const columns = try DocColumns.parse(file, docs_offset, docs_count);

    const segments = sliceAt(SegmentEntry, file, directory_offset, segments_count);
    var bytes_live: usize = header_size;
    bytes_live = std.math.add(usize, bytes_live, docs_count * doc_size) catch return error.BadIndex;
    bytes_live = std.math.add(
        usize,
        bytes_live,
        columns.paths_size_total,
    ) catch return error.BadIndex;
    bytes_live = std.math.add(usize, bytes_live, segments_count * @sizeOf(SegmentEntry)) catch
        return error.BadIndex;
    if (bytes_live > file.len) return error.BadIndex;
    bytes_live = try addSegments(file, segments, bytes_live);

    var out: ContentIndex = .{
        .bytes = whole,
        .backing = backing,
        .docs_count = docs_count,
        .segments_count = segments_count,
        .whole_segments_count = @intCast(@min(header.whole_segments_count, segments_count)),
        .mtimes = columns.mtimes,
        .sizes = columns.sizes,
        .ctimes = columns.ctimes,
        .path_offsets = columns.path_offsets,
        .path_sizes = columns.path_sizes,
        .sources = columns.sources,
        .flags = columns.flags,
        .file = file,
        .segments = segments,
        .segments_copied = @min(segments_count, segments_inline_max),
        .docs_removed_count = columns.docs_removed_count,
        .extracted_live_count = columns.extracted_live_count,
        .bytes_live = bytes_live,
    };
    @memcpy(out.segments_inline[0..out.segments_copied], segments[0..out.segments_copied]);
    return out;
}

/// Writes the index to `path_z` atomically (`sys.writeFileAtomic`): its
/// file up to `Header.size_total`, not whatever follows in `bytes` (what an
/// aborted append left behind).
pub fn save(index: *const ContentIndex, path_z: [:0]const u8) sys.Error!void {
    try sys.writeFileAtomic(path_z, index.file);
}

pub fn open(path_z: [:0]const u8) (sys.Error || error{BadIndex})!ContentIndex {
    const mapped = try sys.mapPrivateWithId(path_z);
    errdefer sys.unmap(mapped.bytes);
    var parsed = try parse(mapped.bytes, .mapped);
    parsed.file_id = mapped.id;
    return parsed;
}

/// Directory entry of segment `segment_index`: the copy `parse` made of
/// it when there is one, the mapping otherwise (checked where it is used,
/// `segmentAt`).
pub fn segmentEntry(index: *const ContentIndex, segment_index: usize) SegmentEntry {
    assert(segment_index < index.segments_count);
    if (segment_index < index.segments_copied) return index.segments_inline[segment_index];
    return index.segments[segment_index];
}

/// A segment's arrays, in the file.
pub const Segment = struct {
    entry: SegmentEntry,
    keys: []const u32,
    /// One more than `keys`: list `k` is `postings[offsets[k]..offsets[k + 1]]`,
    /// once `listAt` has checked those against `postings` again.
    offsets: []const u32,
    postings: []const u8,

    /// Posting list bytes of the `key_index`th key; null when its offsets
    /// are out of order or out of the postings.
    pub fn listAt(view: Segment, key_index: usize) ?[]const u8 {
        assert(key_index < view.keys.len);
        const start = view.offsets[key_index];
        const end = view.offsets[key_index + 1];
        if (start > end or end > view.postings.len) return null;
        return view.postings[start..end];
    }
};

/// Segment `segment_index`, its bounds checked again. The one rule every
/// read of a segment follows: `parse` checked the mapping once, but a
/// private mapping still shows what another process writes to the file
/// afterwards (pages not yet copied), and a merge or an update that trusted
/// it crashed the daemon (`error.BadIndex` instead: the update fails and the
/// next one rebuilds).
pub fn segmentAt(index: *const ContentIndex, segment_index: usize) error{BadIndex}!Segment {
    if (segment_index >= index.segments_count) return error.BadIndex;
    const entry = index.segmentEntry(segment_index);
    const file = index.file;
    const keys_offset = try region(file.len, entry.keys_offset, entry.keys_count, 4, 4);
    const keys_count: usize = @intCast(entry.keys_count);
    const offsets_count = std.math.add(u64, entry.keys_count, 1) catch return error.BadIndex;
    const offsets_offset = try region(file.len, entry.offsets_offset, offsets_count, 4, 4);
    const postings_offset = try region(file.len, entry.postings_offset, entry.postings_size, 1, 1);
    return .{
        .entry = entry,
        .keys = sliceAtConst(u32, file, keys_offset, keys_count),
        .offsets = sliceAtConst(u32, file, offsets_offset, keys_count + 1),
        .postings = file[postings_offset..][0..@intCast(entry.postings_size)],
    };
}

/// Posting list bytes of `key` in segment `segment_index` (empty if
/// absent or if bounds are violated by an external write to the mapping).
fn list(index: *const ContentIndex, segment_index: usize, key: u32) []const u8 {
    const found = index.segmentAt(segment_index) catch return &.{};
    const keys = found.keys;
    var low: usize = 0;
    var high: usize = keys.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (keys[middle] < key) low = middle + 1 else high = middle;
    }
    if (low == keys.len) return &.{};
    if (keys[low] != key) return &.{};
    return found.listAt(low) orelse &.{};
}

/// Documents containing every trigram of every word, folded (words of 3+
/// folded characters; shorter ones cannot narrow anything and are checked
/// on verify).
/// Appends doc ids, ascending, to `out`.
pub fn candidates(
    index: *const ContentIndex,
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
        // A key with no list here: the segment has no candidate, and the
        // keys after it need no looking up.
        const some_list_empty = for (keys_unique, lists) |key, *list_of_key| {
            list_of_key.* = index.list(segment_index, key);
            if (list_of_key.len == 0) break true;
        } else false;
        if (some_list_empty) continue;
        // Shortest list first: every intersection only shrinks the set.
        std.mem.sort([]const u8, lists, {}, struct {
            fn shorter(_: void, list_a: []const u8, list_b: []const u8) bool {
                return list_a.len < list_b.len;
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
    assert(strictlyAscending(u32, out.items));
    if (out.getLastOrNull()) |doc_last| assert(doc_last < index.docs_count);
}

pub fn postingBytes(index: *const ContentIndex) usize {
    var postings_size: u64 = 0;
    for (0..index.segments_count) |segment_index| {
        postings_size +|= index.segmentEntry(segment_index).postings_size;
    }
    return @intCast(@min(postings_size, std.math.maxInt(usize)));
}

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

/// `bytes_live` with what each of `segments` takes, each checked to lie
/// inside `file` (`checkSegment`).
fn addSegments(file: BytesConst, segments: []const SegmentEntry, bytes_live_before: usize) error{BadIndex}!usize {
    var bytes_live = bytes_live_before;
    for (segments) |segment| {
        try checkSegment(file, segment);
        const keys_count: usize = @intCast(segment.keys_count);
        // Keys, and one more offset than keys.
        const tables_bytes = std.math.add(
            usize,
            keys_count * @sizeOf(u32),
            (keys_count + 1) * @sizeOf(u32),
        ) catch return error.BadIndex;
        const postings_bytes: usize = @intCast(segment.postings_size);
        const segment_bytes = std.math.add(usize, tables_bytes, postings_bytes) catch
            return error.BadIndex;
        bytes_live = std.math.add(usize, bytes_live, segment_bytes) catch return error.BadIndex;
        // Overlapping segments in a corrupt index must not inflate bytes_live
        // past the file itself.
        if (bytes_live > file.len) return error.BadIndex;
    }
    return bytes_live;
}

fn checkSegment(file: BytesConst, segment: SegmentEntry) error{BadIndex}!void {
    const keys_offset = try region(file.len, segment.keys_offset, segment.keys_count, 4, 4);
    const keys_count: usize = @intCast(segment.keys_count); // Fits: bounded by file.len.
    const offsets_count = std.math.add(u64, segment.keys_count, 1) catch return error.BadIndex;
    const offsets_offset = try region(file.len, segment.offsets_offset, offsets_count, 4, 4);
    const postings_offset = try region(
        file.len,
        segment.postings_offset,
        segment.postings_size,
        1,
        1,
    );
    if (keys_offset < header_size) return error.BadIndex;
    if (offsets_offset < header_size) return error.BadIndex;
    if (postings_offset < header_size) return error.BadIndex;
    const keys = sliceAtConst(u32, file, keys_offset, keys_count);
    const offsets = sliceAtConst(u32, file, offsets_offset, keys_count + 1);
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

// ---------------------------------------------------------------- tests

const testing = std.testing;
const content_testing = @import("content_testing.zig");
const smallIndex = content_testing.smallIndex;
const exerciseIndex = content_testing.exerciseIndex;
const TestDocs = content_testing.TestDocs;
const paths = @import("paths.zig");
const Pool = @import("Pool.zig");
const build = @import("content_build.zig").build;
const TextReader = @import("content_build.zig").TextReader;
const findCI = @import("content_find.zig").findCI;

test "candidates equal a brute-force scan, across segments, after save/open" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(9);
    const random = prng.random();
    const vocab = [_][]const u8{
        "arena", "allocator", "Config", "trigram", "posting", "lumen", "zig", "parser", "token", "Hyprland", "window",
        "élan",
    };
    var texts: std.ArrayList([]const u8) = .empty;
    defer {
        for (texts.items) |text| gpa.free(text);
        texts.deinit(gpa);
    }
    var docs: std.ArrayList(DocIn) = .empty;
    defer {
        for (docs.items) |doc| gpa.free(doc.path);
        docs.deinit(gpa);
    }
    for (0..3000) |i| {
        var text: std.ArrayList(u8) = .empty;
        for (0..random.intRangeAtMost(usize, 1, 30)) |_| {
            try text.appendSlice(gpa, vocab[random.uintLessThan(usize, vocab.len)]);
            try text.append(gpa, if (random.boolean()) ' ' else '\n');
        }
        try texts.append(gpa, try text.toOwnedSlice(gpa));
        try docs.append(gpa, .{ .path = try gpa.print("{d}", .{i}), .mtime = 0, .size = 0 });
    }
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var test_docs: TestDocs = .{ .texts = texts.items };
    const reader: TextReader = .{ .read = TestDocs.readText, .context = &test_docs };
    var index = try build(gpa, pool, docs.items, reader, null);
    defer index.deinit(gpa);

    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try test_dir.path(&index_path_buffer, "content.idx");
    try index.save(index_path);
    var mapped = try ContentIndex.open(index_path);
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
        for (texts.items, 0..) |text, i| {
            var all = true;
            for (words) |word| {
                if (findCI(text, word, 0) == null) all = false;
            }
            if (all) try testing.expect(std.mem.findScalar(u32, got.items, @intCast(i)) != null);
        }
    }
}

test "corrupt content indexes are rejected, not trusted" {
    const gpa = testing.allocator;
    var index = try smallIndex(gpa);
    defer index.deinit(gpa);
    const good = index.bytes;
    try exerciseIndex(&index, gpa);

    const bad = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(bad);
    const Patch = struct {
        fn write64(bytes: []u8, offset: usize, value: u64) void {
            std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
        }
        fn write32(bytes: []u8, offset: usize, value: u32) void {
            std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
        }
    };

    // Truncated anywhere, or empty: the total length no longer matches.
    for (0..good.len) |cut| try testing.expectError(
        error.BadIndex,
        ContentIndex.parse(good[0..cut], .heap),
    );

    const docs_offset = std.mem.readInt(u64, good[32..40], .little);
    const directory_offset = std.mem.readInt(u64, good[40..48], .little);
    const docs_count = index.docs_count;
    const segment = index.segments[0];
    const u64_max = std.math.maxInt(u64);
    const Case = struct { offset: usize, value: u64, wide: bool = true };
    const cases = [_]Case{
        .{ .offset = 0, .value = 0x3130585443_4d554c }, // magic of another version (LUMCTX01)
        .{ .offset = 8, .value = u64_max }, // Doc count: overflows the layout.
        .{ .offset = 8, .value = docs_count + 1 }, // One too many: the arrays shift onto others.
        .{ .offset = 8, .value = @as(u64, std.math.maxInt(u32)) + 1 },
        .{ .offset = 16, .value = u64_max / 8 }, // Segment count.
        .{ .offset = 16, .value = index.segments_count + 1 },
        .{ .offset = 24, .value = good.len }, // Paths blob past the end.
        .{ .offset = 32, .value = docs_offset + 4 }, // Misaligned doc table.
        .{ .offset = 32, .value = good.len + 8 }, // Past the end.
        .{ .offset = 32, .value = 0 }, // Over the header.
        .{ .offset = 40, .value = directory_offset + 4 }, // Misaligned directory.
        .{ .offset = 40, .value = good.len - 8 }, // Directory past the end.
        .{ .offset = 48, .value = good.len - 1 }, // Total length.
        // Segment directory entry.
        .{ .offset = directory_offset, .value = u64_max }, // `keys_count`: overflows.
        .{ .offset = directory_offset, .value = segment.keys_count * 100 }, // Keys past the end.
        .{ .offset = directory_offset + 8, .value = segment.keys_offset + 2 }, // Misaligned keys.
        .{ .offset = directory_offset + 8, .value = good.len }, // Keys past the end.
        .{ .offset = directory_offset + 16, .value = good.len - 4 }, // Offsets past the end.
        .{ .offset = directory_offset + 24, .value = good.len }, // Postings past the end.
        .{ .offset = directory_offset + 32, .value = good.len }, // Postings longer than the file.
        .{ .offset = directory_offset + 32, .value = 0 }, // Offsets beyond the postings.
        // A path past the end of the file, an unknown document kind.
        .{ .offset = docs_offset + docs_count * 24, .value = 0xffff_fff0, .wide = false },
        .{ .offset = docs_offset + docs_count * 30, .value = 9, .wide = false },
        // Keys out of order (binary search would miss), offsets going back.
        .{ .offset = segment.keys_offset, .value = 0xffff_ff, .wide = false },
        .{ .offset = segment.offsets_offset + 4, .value = 0xffff_ffff, .wide = false },
    };
    for (cases, 0..) |case, i| {
        @memcpy(bad, good);
        if (case.offset == docs_offset + docs_count * 30) {
            bad[case.offset] = @intCast(case.value);
        } else if (case.wide) {
            Patch.write64(bad, case.offset, case.value);
        } else {
            Patch.write32(bad, case.offset, @intCast(case.value));
        }
        if (ContentIndex.parse(bad, .heap)) |_| {
            std.debug.print("case {d} accepted\n", .{i});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "malformed posting lists in a real index end, never over-read" {
    const gpa = testing.allocator;
    // Every posting list's last byte gets its continuation bit (each list
    // now ends in a truncated varint).
    var index = try smallIndex(gpa);
    defer index.deinit(gpa);
    const segment = index.segments[0];
    const offsets = sliceAt(u32, index.bytes, segment.offsets_offset, segment.keys_count + 1);
    for (offsets[1..]) |offset| {
        if (offset > 0) index.bytes[segment.postings_offset + offset - 1] |= 0x80;
    }
    try exerciseIndex(&index, gpa);
    // And with garbage postings: ids past the documents never come out.
    @memset(index.bytes[segment.postings_offset..][0..segment.postings_size], 0x7f);
    try exerciseIndex(&index, gpa);
}

fn fuzzParseBytes(_: void, smith: *testing.Smith) anyerror!void {
    var input_buffer: [16384]u8 align(format.alignment_bytes) = undefined;
    const input = input_buffer[0..smith.slice(&input_buffer)];
    // Often make the header plausible, so the fuzzer reaches the checks
    // behind it.
    if (input.len >= header_size and smith.value(bool)) {
        @memcpy(input[0..8], magic);
        const room = (input.len - header_size) / doc_size;
        const docs_count = smith.valueRangeAtMost(u32, 0, @intCast(@min(room, 1000)));
        const paths_size = smith.valueRangeAtMost(u32, 0, @intCast(
            input.len - header_size - docs_count * doc_size,
        ));
        const directory_offset = alignUp(header_size + docs_count * doc_size + paths_size);
        std.mem.writeInt(u64, input[8..16], docs_count, .little);
        std.mem.writeInt(u64, input[16..24], smith.valueRangeAtMost(u8, 0, 4), .little);
        std.mem.writeInt(u64, input[24..32], paths_size, .little);
        std.mem.writeInt(u64, input[32..40], header_size, .little);
        std.mem.writeInt(u64, input[40..48], directory_offset, .little);
        std.mem.writeInt(u64, input[48..56], input.len, .little);
    }
    const index = ContentIndex.parse(input, .heap) catch return;
    try exerciseIndex(&index, testing.allocator);
}

test "fuzz: parsing arbitrary bytes as a content index never crashes" {
    const gpa = testing.allocator;
    var index = try smallIndex(gpa);
    defer index.deinit(gpa);
    const seed = try corpusEntry(gpa, index.bytes);
    defer gpa.free(seed);
    try testing.fuzz({}, fuzzParseBytes, .{ .corpus = &.{seed} });
}

test "post-parse mutations to mmap buffer are rejected safely" {
    const gpa = testing.allocator;
    var index = try smallIndex(gpa);
    defer index.deinit(gpa);

    // Mutate path_offset, path_size, source enum, and posting end offset after parse().
    const bad = try gpa.alignedAlloc(u8, .@"8", index.bytes.len);
    defer gpa.free(bad);
    @memcpy(bad, index.bytes);

    var mutated = try ContentIndex.parse(bad, .heap);
    // Do not call mutated.deinit(gpa) since bad is freed above; replace backing fields cleanly.
    const docs_offset = std.mem.readInt(u64, bad[32..40], .little);
    const docs_count = mutated.docs_count;
    // Corrupt doc 0 path offset past EOF and doc 1 source to invalid enum 99.
    std.mem.writeInt(u32, bad[docs_offset + docs_count * 24 ..][0..4], 0xffff_ff00, .little);
    bad[docs_offset + docs_count * 30 + 1] = 99;
    // Corrupt posting offset end in segment 0 backwards (start > end).
    const segment = mutated.segments_inline[0];
    if (segment.keys_count > 0) {
        std.mem.writeInt(u32, bad[@intCast(segment.offsets_offset + 4)..][0..4], 0, .little);
    }

    try testing.expectEqualStrings("", mutated.path(0));
    try testing.expectEqual(Source.plain, mutated.docIn(1).source);
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    try mutated.candidates(gpa, &.{"arena"}, &got);
    mutated.bytes = &.{};
}
