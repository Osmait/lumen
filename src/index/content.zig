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
const paths = @import("paths.zig");
const assert = std.debug.assert;
const linux = std.os.linux;
const Pool = @import("Pool.zig");
const sys = @import("os");
const format = @import("format.zig");
const alignUp = format.alignUp;
const Bytes = format.Bytes;
const BytesConst = format.BytesConst;
const corpusEntry = format.corpusEntry;
const fold = @import("core").fold;
const utf8 = @import("core").utf8;
const recency = @import("recency.zig");
const content_find = @import("content_find.zig");

pub const Span = content_find.Span;
pub const findFold = content_find.findFold;
pub const findCI = content_find.findCI;
const content_format = @import("content_format.zig");
const magic = content_format.magic;
const header_size = content_format.header_size;
const Header = content_format.Header;
const SegmentEntry = content_format.SegmentEntry;
const doc_size = content_format.doc_size;
const flag_removed = content_format.flag_removed;
pub const path_bytes_max = content_format.path_bytes_max;
pub const Source = content_format.Source;
pub const DocIn = content_format.DocIn;
const Trigrams = content_format.Trigrams;
pub const trigram_chars = content_format.trigram_chars;
const trigram_bits = content_format.trigram_bits;
const trigram_mask = content_format.trigram_mask;
const trigrams_count = content_format.trigrams_count;
const ListReader = content_format.ListReader;
const writeVarint = content_format.writeVarint;
const decodeAll = content_format.decodeAll;
const intersect = content_format.intersect;
const sliceAt = content_format.sliceAt;
const dedupSorted = content_format.dedupSorted;
const strictlyAscending = content_format.strictlyAscending;

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
            if (@as(u64, path_offset) + path_size > file.len) return error.BadIndex;
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
    bytes: Bytes,
    backing: format.Backing,
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
        format.release(index.bytes, index.backing, gpa);
        index.* = undefined;
    }

    pub fn path(index: *const Index, doc: u32) []const u8 {
        assert(doc < index.docs_count);
        return index.file[index.path_offsets[doc]..][0..index.path_sizes[doc]];
    }

    pub fn removed(index: *const Index, doc: u32) bool {
        assert(doc < index.docs_count);
        return index.flags[doc] & flag_removed != 0;
    }

    /// Documents a query can find.
    pub fn live(index: *const Index) usize {
        assert(index.docs_removed_count <= index.docs_count);
        return index.docs_count - index.docs_removed_count;
    }

    /// Whether document `doc` is still indexed and its text was extracted
    /// (a PDF, an Office file) rather than read from the file itself.
    pub fn extractedLive(index: *const Index, doc: u32) bool {
        return !index.removed(doc) and
            index.sources[doc] == @backingInt(Source.extracted);
    }

    /// How many documents `extractedLive` is true for.
    pub fn extractedCount(index: *const Index) usize {
        var count: usize = 0;
        for (0..index.docs_count) |doc_index| {
            count += @intFromBool(index.extractedLive(@intCast(doc_index)));
        }
        return count;
    }

    pub fn docIn(index: *const Index, doc: u32) DocIn {
        assert(doc < index.docs_count);
        return .{
            .path = index.path(doc),
            .mtime = index.mtimes[doc],
            .size = index.sizes[doc],
            .source = @fromBackingInt(@intCast(index.sources[doc])),
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
    pub fn parse(whole: Bytes, backing: format.Backing) error{BadIndex}!Index {
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
        const segments_count: usize = @intCast(header.segments_count);

        const columns = try DocColumns.parse(file, docs_offset, docs_count);

        const segments = sliceAt(SegmentEntry, file, directory_offset, segments_count);
        var bytes_live = header_size + docs_count * doc_size + columns.paths_size_total +
            segments_count * @sizeOf(SegmentEntry);
        for (segments) |segment| {
            try checkSegment(file, segment);
            const keys_count: usize = @intCast(segment.keys_count);
            // Keys, and one more offset than keys.
            bytes_live += keys_count * @sizeOf(u32) + (keys_count + 1) * @sizeOf(u32);
            bytes_live += @intCast(segment.postings_size);
        }

        return .{
            .bytes = whole,
            .backing = backing,
            .docs_count = docs_count,
            .segments_count = segments_count,
            .mtimes = columns.mtimes,
            .sizes = columns.sizes,
            .path_offsets = columns.path_offsets,
            .path_sizes = columns.path_sizes,
            .sources = columns.sources,
            .flags = columns.flags,
            .file = file,
            .segments = segments,
            .docs_removed_count = columns.docs_removed_count,
            .bytes_live = bytes_live,
        };
    }

    /// Writes the index to `path_z` atomically (see `sys.writeFileAtomic`).
    pub fn save(index: *const Index, path_z: [:0]const u8) sys.Error!void {
        try sys.writeFileAtomic(path_z, index.bytes);
    }

    pub fn open(path_z: [:0]const u8) (sys.Error || error{BadIndex})!Index {
        const mapped = try sys.mapPrivate(path_z);
        errdefer sys.unmap(mapped);
        return parse(mapped, .mapped);
    }

    /// Posting list bytes of `key` in segment `segment_index` (empty if
    /// absent).
    fn list(index: *const Index, segment_index: usize, key: u32) []const u8 {
        const segment = index.segments[segment_index];
        const keys = sliceAt(u32, index.bytes, segment.keys_offset, segment.keys_count);
        var low: usize = 0;
        var high: usize = keys.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (keys[middle] < key) low = middle + 1 else high = middle;
        }
        if (low == keys.len) return &.{};
        if (keys[low] != key) return &.{};
        const offsets = sliceAt(u32, index.bytes, segment.offsets_offset, segment.keys_count + 1);
        const postings_offset = segment.postings_offset;
        return index.bytes[postings_offset + offsets[low] .. postings_offset + offsets[low + 1]];
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

    pub fn postingBytes(index: *const Index) usize {
        var postings_size: usize = 0;
        for (index.segments) |segment| postings_size += segment.postings_size;
        return postings_size;
    }
};

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

fn checkSegment(file: BytesConst, segment: SegmentEntry) error{BadIndex}!void {
    const keys_offset = try region(file.len, segment.keys_offset, segment.keys_count, 4, 4);
    const keys_count: usize = @intCast(segment.keys_count); // Fits: bounded by file.len.
    const offsets_count = std.math.add(u64, segment.keys_count, 1) catch return error.BadIndex;
    const offsets_offset = try region(file.len, segment.offsets_offset, offsets_count, 4, 4);
    _ = try region(file.len, segment.postings_offset, segment.postings_size, 1, 1);
    const keys = sliceAt(u32, @constCast(file), keys_offset, keys_count);
    const offsets = sliceAt(u32, @constCast(file), offsets_offset, keys_count + 1);
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

// --------------------------------------------------------------- building

/// Reads a document's text into `text` for indexing or verifying: false when
/// it has none to index (gone, binary, too big). `extracted` documents are
/// read from the text cache by the caller-provided resolver. Running out of
/// memory is an error, never "no text": the index would keep the document
/// empty until it changed.
pub const TextFn = *const fn (
    context: *anyopaque,
    doc: DocIn,
    text: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!bool;

/// A `TextFn` and the context it is called with.
pub const TextReader = struct {
    read: TextFn,
    context: *anyopaque,
    /// Most bytes of text `read` gives for an extracted document (its text
    /// is not the size of the file, the size of the cached text is). When it
    /// is null, `extracted_bytes_max`.
    extracted_bytes: ?*const fn (context: *anyopaque, doc: DocIn) u64 = null,

    /// Most (trigram, doc) pairs reading `doc` can give: one per byte of
    /// text.
    fn mostPairs(reader: TextReader, doc: DocIn) usize {
        const text_size = switch (doc.source) {
            .plain => @min(doc.size, text_bytes_max),
            .extracted => if (reader.extracted_bytes) |extracted_bytes|
                @min(extracted_bytes(reader.context, doc), extracted_bytes_max)
            else
                extracted_bytes_max,
        };
        return @intCast(@min(text_size, trigrams_count));
    }
};

/// Plain text of a file: up to `text_bytes_max` bytes, rejected if binary
/// (a NUL in the first 8 KB, git's rule).
pub fn readPlain(
    gpa: std.mem.Allocator,
    path: []const u8,
    text: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    text.clearRetainingCapacity();
    var path_buffer: paths.Buffer = undefined;
    const path_z = std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0) catch return false;
    // Not a plain open: the path may have become a FIFO since it was indexed.
    const fd = sys.openRegular(path_z) catch return false;
    defer sys.close(fd);
    // One byte past the limit tells a file over it.
    sys.readUpTo(gpa, fd, text, text_bytes_max + 1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Part of the file is not its text: left out, as if unreadable.
        error.ReadFailed => return false,
    };
    if (text.items.len > text_bytes_max) return false;
    const head = text.items[0..@min(text.items.len, 8000)];
    return std.mem.findScalar(u8, head, 0) == null;
}

/// One round of reading: documents `start..end`, each taken by the next free
/// task (no fixed shares, so nobody waits for the slowest file of a share).
const ExtractRound = struct {
    gpa: std.mem.Allocator,
    docs: []const DocIn,
    start: usize,
    end: usize,
    text: TextReader,
    /// Per task: the (trigram, doc) pairs of the documents it read, in the
    /// order read.
    task_pairs: []std.ArrayList(u64),
    /// Per document of the round: where its pairs are in `task_pairs`.
    spans: []Pairs,
    next: std.atomic.Value(usize),
    /// Set by a task that ran out of memory: the build fails (and is retried
    /// later) instead of indexing its documents as empty.
    out_of_memory: std.atomic.Value(bool) = .init(false),
};

/// Where one document's pairs are: `task_pairs[task][start..][0..count]`.
const Pairs = struct { task: usize, start: usize, count: usize };

fn extractTask(round: *ExtractRound, task: usize) void {
    extractTaskOrFail(round, task) catch round.out_of_memory.store(true, .release);
}

fn extractTaskOrFail(round: *ExtractRound, task: usize) std.mem.Allocator.Error!void {
    const gpa = round.gpa;
    // One bit per possible trigram: dedup in O(n) without sorting. Made on
    // the first document with text, then reused and cleared key by key.
    var seen: std.DynamicBitSetUnmanaged = .{};
    defer seen.deinit(gpa);
    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const out = &round.task_pairs[task];
    while (true) {
        const doc = round.next.fetchAdd(1, .monotonic);
        if (doc >= round.end) return;
        const start = out.items.len;
        defer round.spans[doc - round.start] = .{
            .task = task,
            .start = start,
            .count = out.items.len - start,
        };
        if (!try round.text.read(round.text.context, round.docs[doc], &text, gpa)) continue;
        if (seen.bit_length == 0) seen = try .initEmpty(gpa, trigrams_count);
        keys.clearRetainingCapacity();
        var trigrams: Trigrams = .{ .text = text.items };
        while (trigrams.next()) |key| {
            if (seen.isSet(key)) continue;
            seen.set(key);
            try keys.append(gpa, key);
        }
        for (keys.items) |key| seen.unset(key);
        try out.ensureUnusedCapacity(gpa, keys.items.len);
        for (keys.items) |key| out.appendAssumeCapacity(pairOf(key, @intCast(doc)));
    }
}

pub const BuildStats = struct {
    docs_indexed: usize = 0,
    pairs: usize = 0,
    segments: usize = 0,
    elapsed_ns: u64 = 0,
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
    var file = (try sys.AppendFile.open(path_z, old.bytes.len)) orelse return null;
    defer file.deinit();
    var sink: Sink = .{ .gpa = gpa, .append_file = &file, .written_bytes = file.len };
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
    var directory: std.ArrayList(SegmentEntry) = .empty;
    defer directory.deinit(gpa);
    // Where they are: the file only grows.
    try directory.appendSlice(gpa, old.segments[0..segments_kept_count]);
    var pairs_merged: std.ArrayList(u64) = .empty;
    defer pairs_merged.deinit(gpa);
    for (old.segments[segments_kept_count..]) |segment| {
        try segmentPairs(gpa, old, segment, flags, &pairs_merged);
    }
    try indexDocs(
        sink,
        pool,
        &directory,
        docs,
        old.docs_count,
        text,
        &build_stats,
        pairs_merged.items,
    );
    const table = try writeDocs(sink, docs, .{
        .flags = flags,
        .header = .none,
        .path_offsets_reused = old.path_offsets,
    });
    build_stats.docs_indexed = added.len;
    return finish(sink, directory.items, docs.len, table, start_ns, &build_stats, stats);
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
    const keys = sliceAt(u32, index.bytes, @intCast(segment.keys_offset), keys_count);
    const offsets = sliceAt(u32, index.bytes, @intCast(segment.offsets_offset), keys_count + 1);
    const postings_offset: usize = @intCast(segment.postings_offset);
    const postings = index.bytes[postings_offset..][0..@intCast(segment.postings_size)];
    for (keys, 0..) |key, key_index| {
        var reader: ListReader = .{
            .list_encoded = postings[offsets[key_index]..offsets[key_index + 1]],
            .docs_count = index.docs_count,
        };
        while (reader.next()) |doc| {
            if (flags[doc] & flag_removed != 0) continue;
            try out.append(gpa, pairOf(key, doc));
        }
    }
}

/// Where an index is written: memory, where it becomes the index, or a file,
/// keeping only what is not written yet. Offsets are positions in the whole.
const Sink = struct {
    gpa: std.mem.Allocator,
    file: ?*sys.AtomicFile = null,
    /// Or the end of an existing file (`appendFile`).
    append_file: ?*sys.AppendFile = null,
    /// What is not in the file yet; in memory, the whole index.
    bytes: BytesAligned8 = .empty,
    /// Bytes already in the file.
    written_bytes: usize = 0,

    /// Larger pieces go to the file directly instead of through `bytes`.
    const direct_bytes_min = 64 * 1024;

    fn deinit(sink: *Sink) void {
        sink.bytes.deinit(sink.gpa);
    }

    fn position(sink: *const Sink) usize {
        return sink.written_bytes + sink.bytes.items.len;
    }

    fn append(sink: *Sink, bytes: []const u8) FileError!void {
        const to_file = sink.file != null or sink.append_file != null;
        if (to_file and bytes.len >= direct_bytes_min) {
            try sink.flush();
            try sink.put(bytes);
            sink.written_bytes += bytes.len;
            return;
        }
        try sink.bytes.appendSlice(sink.gpa, bytes);
    }

    fn put(sink: *Sink, bytes: []const u8) FileError!void {
        if (sink.file) |file| return file.write(bytes);
        if (sink.append_file) |file| return file.write(bytes);
    }

    fn zeros(sink: *Sink, count: usize) FileError!void {
        try sink.bytes.appendNTimes(sink.gpa, 0, count);
    }

    /// Zeros up to the next multiple of `format.alignment_bytes`.
    fn padToAlignment(sink: *Sink) FileError!void {
        try sink.zeros(alignUp(sink.position()) - sink.position());
        assert(sink.position() % format.alignment_bytes == 0);
    }

    /// Writes what is buffered (file mode only).
    fn flush(sink: *Sink) FileError!void {
        if (sink.file == null and sink.append_file == null) return;
        try sink.put(sink.bytes.items);
        sink.written_bytes += sink.bytes.items.len;
        sink.bytes.clearRetainingCapacity();
    }
};

/// A sink without a file never fails to write one.
fn memoryOnly(err: FileError) BuildError {
    return switch (err) {
        error.OutOfMemory, error.BadIndex, error.IndexTooLarge => |kept| kept,
        else => unreachable,
    };
}

fn toMemory(sink: *Sink, header: Header) BuildError!Index {
    @memcpy(sink.bytes.items[0..header_size], &header.encode());
    const bytes = try sink.bytes.toOwnedSlice(sink.gpa);
    errdefer sink.gpa.free(bytes);
    return Index.parse(bytes, .heap);
}

fn toFile(sink: *Sink, header: Header, path_z: [:0]const u8) FileError!Index {
    try sink.flush();
    const file = sink.file.?;
    try file.writeAt(&header.encode(), 0);
    try file.commit();
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
    var directory: std.ArrayList(SegmentEntry) = .empty;
    defer directory.deinit(sink.gpa);
    const table = try writeDocs(sink, docs, .{
        .flags = null,
        .header = .reserve,
        .path_offsets_reused = &.{},
    });
    try indexDocs(sink, pool, &directory, docs, 0, text, &build_stats, &.{});
    build_stats.docs_indexed = docs.len;
    return finish(sink, directory.items, docs.len, table, start_ns, &build_stats, stats);
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

    var directory: std.ArrayList(SegmentEntry) = .empty;
    defer directory.deinit(gpa);
    const table = try writeDocs(sink, docs, .{
        .flags = flags,
        .header = .reserve,
        .path_offsets_reused = &.{},
    });
    for (old.segments) |segment| try copySegment(sink, &directory, old.bytes, segment);
    try indexDocs(sink, pool, &directory, docs, old.docs_count, text, &build_stats, &.{});
    build_stats.docs_indexed = added.len;
    return finish(sink, directory.items, docs.len, table, start_ns, &build_stats, stats);
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
        .none => assert(sink.position() >= header_size),
    }
    try sink.padToAlignment();
    var paths_size: usize = 0;
    for (docs[reused.len..]) |doc| paths_size += doc.path.len;
    // The path size column is u16; `DocIn.path` promises that it fits.
    for (docs) |doc| assert(doc.path.len <= path_bytes_max);
    const docs_offset = sink.position();
    const paths_offset = docs_offset + docs.len * doc_size;
    // Path offsets are stored as u32, so the doc table and its paths must
    // end below 4 GiB.
    if (paths_offset + paths_size > std.math.maxInt(u32)) return error.IndexTooLarge;

    // Built in the buffer: nothing is written before the doc table is done.
    const table_start = sink.bytes.items.len;
    try sink.zeros(alignUp(docs.len * doc_size + paths_size));
    const table = sink.bytes.items;
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
    directory: *std.ArrayList(SegmentEntry),
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
    const task_pairs = try gpa.alloc(std.ArrayList(u64), tasks);
    defer {
        for (task_pairs) |*out| out.deinit(gpa);
        gpa.free(task_pairs);
    }
    for (task_pairs) |*out| out.* = .empty;
    const spans = try gpa.alloc(Pairs, round_docs_max);
    defer gpa.free(spans);

    var round_start = from;
    while (round_start < docs.len) {
        const round_end = roundEnd(docs, round_start, text);
        var round: ExtractRound = .{
            .gpa = gpa,
            .docs = docs,
            .start = round_start,
            .end = round_end,
            .text = text,
            .task_pairs = task_pairs,
            .spans = spans,
            .next = .init(round_start),
        };
        pool.run(@min(tasks, round_end - round_start), &round, extractTask);
        if (round.out_of_memory.load(.acquire)) return error.OutOfMemory;
        // In doc order, which the stable radix sort turns into (key, doc).
        for (spans[0 .. round_end - round_start]) |span| {
            try pairs.appendSlice(gpa, task_pairs[span.task].items[span.start..][0..span.count]);
            if (pairs.items.len >= segment_pairs_max) {
                try closePairs(sink, directory, &pairs, &scratch, build_stats);
            }
        }
        // What a task kept from a large round would add up across rounds.
        for (task_pairs) |*out| {
            if (out.capacity > round_pairs_max / tasks) {
                out.clearAndFree(gpa);
            } else {
                out.clearRetainingCapacity();
            }
        }
        round_start = round_end;
    }
    if (pairs.items.len > 0) try closePairs(sink, directory, &pairs, &scratch, build_stats);
}

/// Where the round of documents from `start` ends: `round_docs_max`
/// documents, or fewer when their text could give more than
/// `round_pairs_max` pairs (one document at least).
fn roundEnd(docs: []const DocIn, start: usize, text: TextReader) usize {
    var end = start;
    var pairs_most: usize = 0;
    while (end < docs.len and end - start < round_docs_max) : (end += 1) {
        pairs_most += text.mostPairs(docs[end]);
        if (end > start and pairs_most > round_pairs_max) break;
    }
    return end;
}

fn closePairs(
    sink: *Sink,
    directory: *std.ArrayList(SegmentEntry),
    pairs: *std.ArrayList(u64),
    scratch: *std.ArrayList(u64),
    build_stats: *BuildStats,
) FileError!void {
    build_stats.pairs += pairs.items.len;
    try closeSegment(sink, directory, pairs.items, scratch);
    build_stats.segments += 1;
    pairs.clearRetainingCapacity();
    try sink.flush();
}

/// A segment of another index, as it is.
fn copySegment(
    sink: *Sink,
    directory: *std.ArrayList(SegmentEntry),
    from: BytesConst,
    segment: SegmentEntry,
) FileError!void {
    const keys_count: usize = @intCast(segment.keys_count);
    const postings_size: usize = @intCast(segment.postings_size);
    try sink.padToAlignment();
    const keys_offset = sink.position();
    try sink.append(from[@intCast(segment.keys_offset)..][0 .. keys_count * @sizeOf(u32)]);
    try sink.padToAlignment();
    const offsets_offset = sink.position();
    const offsets_size = (keys_count + 1) * @sizeOf(u32);
    try sink.append(from[@intCast(segment.offsets_offset)..][0..offsets_size]);
    const postings_offset = sink.position();
    try sink.append(from[@intCast(segment.postings_offset)..][0..postings_size]);
    try directory.append(sink.gpa, .{
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
    directory: []const SegmentEntry,
    docs_count: usize,
    table: DocTableWritten,
    start_ns: u64,
    build_stats: *BuildStats,
    stats: ?*BuildStats,
) FileError!Header {
    try sink.padToAlignment();
    const directory_offset = sink.position();
    try sink.append(std.mem.sliceAsBytes(directory));
    const size_total = sink.position();
    build_stats.elapsed_ns = sys.monotonicNs() - start_ns;
    if (stats) |out| out.* = build_stats.*;

    assert(docs_count <= std.math.maxInt(u32));
    assert(table.offset >= header_size);
    assert(table.offset % format.alignment_bytes == 0);
    assert(table.offset + docs_count * doc_size + table.paths_size <= directory_offset);
    assert(directory_offset % format.alignment_bytes == 0);
    for (directory) |segment| {
        assert(segment.keys_offset % @alignOf(u32) == 0);
        assert(segment.offsets_offset % @alignOf(u32) == 0);
        assert(segment.postings_offset + segment.postings_size <= directory_offset);
    }
    return .{
        .magic = magic.*,
        .docs_count = docs_count,
        .segments_count = directory.len,
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
    directory: *std.ArrayList(SegmentEntry),
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

    try sink.padToAlignment();
    const keys_offset = sink.position();
    try sink.append(std.mem.sliceAsBytes(lists.keys.items));
    try sink.padToAlignment();
    const offsets_offset = sink.position();
    try sink.append(std.mem.sliceAsBytes(lists.offsets.items));
    const postings_offset = sink.position();
    try sink.append(lists.postings.items);
    try directory.append(gpa, .{
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
            const key = pairKey(pairs[i]);
            if (lists.keys.getLastOrNull()) |key_previous| {
                if (key_previous >= key) return false;
            }
            try lists.keys.append(gpa, key);
            try lists.offsets.append(gpa, @intCast(lists.postings.items.len));
            var doc_previous: u32 = 0;
            var first = true;
            while (i < pairs.len and pairKey(pairs[i]) == key) : (i += 1) {
                const doc = pairDoc(pairs[i]);
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

/// A (trigram, doc) pair packed in a u64, the trigram in the high half:
/// sorting the numbers sorts by trigram, then by doc.
const pair_key_shift = @bitSizeOf(u32);

inline fn pairOf(key: u32, doc: u32) u64 {
    assert(key <= trigram_mask);
    return @as(u64, key) << pair_key_shift | doc;
}

inline fn pairKey(pair: u64) u32 {
    return @intCast(pair >> pair_key_shift);
}

inline fn pairDoc(pair: u64) u32 {
    return @truncate(pair);
}

/// The radix sort takes the bits of a trigram in two passes.
const radix_bits = 12;
const radix_buckets = 1 << radix_bits;

comptime {
    assert(2 * radix_bits == trigram_bits);
    assert(radix_buckets - 1 == trigram_mask >> radix_bits);
}

/// LSD radix sort on the trigram half of each pair, two stable passes of
/// `radix_bits` bits. `scratch` is as long as `pairs` and left garbled.
fn radixByKey(pairs: []u64, scratch: []u64) void {
    assert(scratch.len == pairs.len);
    var source = pairs;
    var target = scratch;
    inline for (.{ pair_key_shift, pair_key_shift + radix_bits }) |shift| {
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

pub const Verified = struct { count: u32, line: u32, snippet: []const u8, phrase: bool };

/// A hit further into its line than `snippet_lead_bytes_max` bytes starts the
/// snippet `snippet_lead_bytes` bytes before it, so that it shows.
const snippet_lead_bytes_max = 60;
const snippet_lead_bytes = 40;
const snippet_bytes_max = 200;

comptime {
    assert(snippet_lead_bytes <= snippet_lead_bytes_max);
    assert(snippet_lead_bytes < snippet_bytes_max);
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
    const hit_start = hit.start;
    // The ranking stops caring after `count_cap` hits; so does counting
    // (in a 4 MB book, "the" would otherwise scan the whole text).
    var count: u32 = 0;
    var occurrence = hit;
    while (count < count_cap) {
        count += 1;
        occurrence = findFold(text, counted, occurrence.end) orelse break;
    }
    const newline_before = std.mem.findScalarLast(u8, text[0..hit_start], '\n');
    const line_start = if (newline_before) |newline| newline + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, text, hit_start, '\n') orelse text.len;
    const line_number: u32 = @intCast(std.mem.count(u8, text[0..hit_start], "\n") + 1);
    // Keep the hit visible: start the snippet a little before it.
    const hit_far_into_line = hit_start - line_start > snippet_lead_bytes_max;
    const snippet_start = if (hit_far_into_line) hit_start - snippet_lead_bytes else line_start;
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

test {
    _ = content_find;
    _ = content_format;
}

/// Texts by document: a document's path is the index of its text.
const TestDocs = struct {
    texts: []const []const u8,

    fn readText(
        context: *anyopaque,
        doc: DocIn,
        text: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!bool {
        const test_docs: *TestDocs = @ptrCast(@alignCast(context));
        const text_index = std.fmt.parseInt(usize, doc.path, 10) catch return false;
        text.clearRetainingCapacity();
        try text.appendSlice(gpa, test_docs.texts[text_index]);
        return true;
    }
};

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
    var mapped = try Index.open(index_path);
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
    const reader: TextReader = .{ .read = TestDocs.readText, .context = &before };
    var index = try build(gpa, pool, &docs, reader, null);
    defer index.deinit(gpa);

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
    var stats: BuildStats = .{};
    var updated = try update(
        gpa,
        pool,
        &index,
        &.{ 1, 2 },
        &added,
        .{ .read = TestDocs.readText, .context = &after },
        &stats,
    );
    defer updated.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), stats.docs_indexed);
    try testing.expectEqual(index.segments_count + 1, updated.segments_count);

    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try test_dir.path(&index_path_buffer, "content.idx");
    try updated.save(index_path);
    var mapped = try Index.open(index_path);
    defer mapped.deinit(gpa);

    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    for ([_]*const Index{ &updated, &mapped }) |version| {
        try testing.expectEqual(@as(usize, 5), version.docs_count);
        try testing.expectEqual(@as(usize, 3), version.live());
        try testing.expect(version.removed(1));
        try testing.expect(version.removed(2));
        try testing.expect(!version.removed(0));
        try testing.expectEqualStrings("1", version.path(3));
        try testing.expectEqual(@as(i64, 2), version.mtimes[3]);
        try version.candidates(gpa, &.{"zanzibar"}, &got);
        try testing.expectEqualSlices(u32, &.{0}, got.items);
        try version.candidates(gpa, &.{"kilimanjaro"}, &got);
        try testing.expectEqual(@as(usize, 0), got.items.len);
        try version.candidates(gpa, &.{"okavango"}, &got);
        try testing.expectEqualSlices(u32, &.{ 3, 4 }, got.items);
    }

    // Written to a file as they grow: the same bytes. The update overwrites
    // the file its old index is mapped from, as the service does.
    var streamed_path_buffer: paths.Buffer = undefined;
    const streamed_path = try test_dir.path(&streamed_path_buffer, "streamed.idx");
    var built = try buildFile(
        gpa,
        pool,
        &docs,
        .{ .read = TestDocs.readText, .context = &before },
        streamed_path,
        null,
    );
    defer built.deinit(gpa);
    try testing.expect(built.backing == .mapped);
    try testing.expectEqualSlices(u8, index.bytes, built.bytes);
    var streamed = try updateFile(
        gpa,
        pool,
        &built,
        &.{ 1, 2 },
        &added,
        .{ .read = TestDocs.readText, .context = &after },
        streamed_path,
        null,
    );
    defer streamed.deinit(gpa);
    try testing.expectEqualSlices(u8, updated.bytes, streamed.bytes);
    try testing.expectEqualStrings("0", built.path(0));

    // Updated again, with only a removal: no new segment.
    var again = try update(
        gpa,
        pool,
        &mapped,
        &.{0},
        &.{},
        .{ .read = TestDocs.readText, .context = &after },
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
    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try test_dir.path(&index_path_buffer, "content.idx");

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
    var test_docs: TestDocs = .{ .texts = &texts };
    const reader: TextReader = .{ .read = TestDocs.readText, .context = &test_docs };
    var first = [_]DocIn{
        .{ .path = "0", .mtime = 1, .size = 1 },
        .{ .path = "1", .mtime = 1, .size = 1 },
        .{ .path = "2", .mtime = 1, .size = 1 },
    };
    var current = try buildFile(gpa, pool, &first, reader, index_path, null);
    defer current.deinit(gpa);
    var in_memory = try build(gpa, pool, &first, reader, null);
    defer in_memory.deinit(gpa);

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
        var name_buffer: [8]u8 = undefined;
        const added = [_]DocIn{.{
            .path = try std.mem.print(&name_buffer, "{d}", .{round}),
            .mtime = 2,
            .size = 1,
        }};
        const gone = [_]u32{@intCast(round - 3)};
        const next = (try appendFile(
            gpa,
            pool,
            &current,
            &gone,
            &added,
            reader,
            index_path,
            null,
        )).?;
        const next_in_memory = try update(gpa, pool, &in_memory, &gone, &added, reader, null);
        // The old mapping still answers as before the append.
        try current.candidates(gpa, &.{"zanzibar"}, &got);
        try in_memory.candidates(gpa, &.{"zanzibar"}, &want);
        try testing.expectEqualSlices(u32, want.items, got.items);
        current.deinit(gpa);
        in_memory.deinit(gpa);
        current = next;
        in_memory = next_in_memory;
        try testing.expectEqual(in_memory.docs_count, current.docs_count);
        try testing.expectEqualSlices(u8, in_memory.flags, current.flags);
        for (0..current.docs_count) |i| try testing.expectEqualStrings(
            in_memory.path(@intCast(i)),
            current.path(@intCast(i)),
        );
        for (words) |word| {
            try current.candidates(gpa, &.{word}, &got);
            try in_memory.candidates(gpa, &.{word}, &want);
            try testing.expectEqualSlices(u32, want.items, got.items);
        }
    }
    // Six updates of tiny segments: merged, not six more segments.
    try testing.expect(current.segments_count < in_memory.segments_count);
    try testing.expect(current.bytes.len > current.bytes_live);

    // An append whose header never got written (a crash): the file still
    // opens as it was.
    {
        const opened = linux.open(index_path, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
        const fd: i32 = @intCast(opened);
        defer sys.close(fd);
        const garbage = "garbage after the end";
        try testing.expectEqual(garbage.len, linux.write(fd, garbage, garbage.len));
    }
    var reopened = try Index.open(index_path);
    defer reopened.deinit(gpa);
    try testing.expectEqual(current.docs_count, reopened.docs_count);
    try reopened.candidates(gpa, &.{"okavango"}, &got);
    try in_memory.candidates(gpa, &.{"okavango"}, &want);
    try testing.expectEqualSlices(u32, want.items, got.items);
    // And the next append is not fooled by it: the file is longer than the
    // index that was mapped, so it says so (the service rewrites instead).
    const appended = try appendFile(gpa, pool, &current, &.{}, &.{}, reader, index_path, null);
    try testing.expect(appended == null);
}

test "verify finds the line and counts hits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "first line\n  const a = ArenaAllocator.init(gpa);\nArenaAllocator again\n";
    const verified = verify(text, &.{"arenaallocator"}, "arenaallocator", true, arena.allocator()).?;
    try testing.expectEqual(@as(u32, 2), verified.line);
    try testing.expectEqual(@as(u32, 2), verified.count);
    try testing.expectEqualStrings("const a = ArenaAllocator.init(gpa);", verified.snippet);
    try testing.expect(
        verify(text, &.{ "arena", "missing" }, "arena missing", true, arena.allocator()) == null,
    );
    // The phrase wins over the first word's first occurrence.
    const phrase_verified = verify(
        "again here\nsee ArenaAllocator again\n",
        &.{ "arenaallocator", "again" },
        "arenaallocator again",
        true,
        arena.allocator(),
    ).?;
    try testing.expectEqual(@as(u32, 2), phrase_verified.line);
    try testing.expect(phrase_verified.phrase);
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
pub const PathFn = *const fn (context: *anyopaque, doc: DocIn, path_buffer: []u8) ?[:0]const u8;

pub const SearchOptions = struct {
    /// Matches wanted, best first.
    limit: usize,
    /// Where each document's text is read from, and its context.
    text_path: PathFn,
    text_context: *anyopaque,
    /// Set by another thread once the answer is not wanted any more (a
    /// newer query waits): verification stops at the next candidate, and
    /// the matches so far are returned.
    stop: ?*const std.atomic.Value(bool) = null,
};

/// For plain documents only (benchmarks, tests).
pub fn plainPath(_: *anyopaque, doc: DocIn, path_buffer: []u8) ?[:0]const u8 {
    if (doc.source != .plain) return null;
    return std.mem.printSentinel(path_buffer, "{s}", .{doc.path}, 0) catch null;
}

/// A candidate in verification order: by `bound`, the most its score can
/// be once its text is read.
const Candidate = struct { doc: u32, bound: i32, maybe_phrase: bool };

/// Verification shared by the pool's threads: each takes the next candidate
/// (no batches, so nobody waits for the slowest file of a batch) until the
/// next one's bound cannot beat the `limit`-th match so far.
const VerifyContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    index: *const Index,
    words: []const []const u8,
    phrase: []const u8,
    candidates: []const Candidate,
    text_path: PathFn,
    text_context: *anyopaque,
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
    out_of_memory: std.atomic.Value(bool) = .init(false),

    fn offer(context: *VerifyContext, match: Match) void {
        context.lock.lockUncancelable(context.io);
        defer context.lock.unlock(context.io);
        assert(context.top_count <= context.top.len);
        var slot = context.top_count;
        if (context.top_count == context.top.len) {
            slot = worst(context.top);
            if (!matchRanksBefore(match, context.top[slot])) return;
        }
        var copy = match;
        copy.snippet = context.arena.dupe(u8, match.snippet) catch {
            context.out_of_memory.store(true, .release);
            return;
        };
        context.top[slot] = copy;
        if (context.top_count < context.top.len) context.top_count += 1;
        if (context.top_count == context.top.len) {
            context.floor.store(context.top[worst(context.top)].score, .release);
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

fn verifyTask(context: *VerifyContext, task: usize) void {
    var path_buffer: paths.Buffer = undefined;
    var plain_text: std.ArrayList(u8) = .empty;
    defer plain_text.deinit(context.gpa);
    const arena = context.arenas[task].allocator();
    while (true) {
        if (context.stop) |stop| {
            if (stop.load(.acquire)) return;
        }
        const candidate_index = context.next.fetchAdd(1, .monotonic);
        if (candidate_index >= context.candidates.len) return;
        const candidate = context.candidates[candidate_index];
        // Candidates come by bound: none after this one can enter either.
        if (candidate.bound < context.floor.load(.acquire)) {
            context.next.store(context.candidates.len, .monotonic);
            return;
        }
        defer _ = context.arenas[task].reset(.retain_capacity);
        const doc = context.index.docIn(candidate.doc);
        const text_context = context.text_context;
        const text_path = context.text_path(text_context, doc, &path_buffer) orelse continue;
        // Plain files (1 MB at most) are read into a reused buffer: cheaper
        // than map + unmap, whose TLB shootdown hits every core of a
        // 24-thread process. Extracted texts run to megabytes and usually
        // match early, so those are mapped and only touched where scanned.
        var mapped: ?Bytes = null;
        defer if (mapped) |bytes| sys.unmap(bytes);
        const text: []const u8 = switch (doc.source) {
            .plain => blk: {
                // Out of memory: this candidate is left out of the results.
                const has_text = readPlain(context.gpa, text_path, &plain_text) catch false;
                if (!has_text) continue;
                break :blk plain_text.items;
            },
            .extracted => blk: {
                mapped = sys.mapPrivate(text_path) catch continue;
                break :blk mapped.?;
            },
        };
        const maybe_phrase = candidate.maybe_phrase;
        const verified = verify(text, context.words, context.phrase, maybe_phrase, arena) orelse
            continue;
        const phrase_bonus: i32 = if (verified.phrase) phrase_max else 0;
        context.offer(.{
            .doc = candidate.doc,
            .count = verified.count,
            .line = verified.line,
            .snippet = verified.snippet,
            .score = rank(doc, verified.count, context.words, context.now_s) + phrase_bonus,
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
    const name = std.Io.Dir.path.basename(doc.path);
    for (words) |word| {
        if (findFold(name, word, 0) != null) score += name_word_score;
    }
    // Saturating: mtimes come from the index file, which may be damaged.
    score += recency.bonus(now_s -| doc.mtime);
    score -= @intCast(paths.depth(doc.path) * depth_penalty);
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
    options: SearchOptions,
    out: *std.ArrayList(Match),
) std.mem.Allocator.Error!void {
    const limit = options.limit;
    const text_path = options.text_path;
    const text_context = options.text_context;
    out.clearRetainingCapacity();
    if (limit == 0) return;
    const words = try splitWords(arena, query);
    const phrase = try fold.foldAlloc(arena, std.mem.trim(u8, query, " \t"));
    var longest: usize = 0;
    for (words) |word| longest = @max(longest, word.len);
    // Nothing a trigram can narrow.
    if (longest < trigram_chars) return;
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
    var context: VerifyContext = .{
        .gpa = gpa,
        .io = pool.io,
        .index = index,
        .words = words,
        .phrase = phrase,
        .candidates = ordered[0..@min(ordered.len, candidates_verified_max)],
        .text_path = text_path,
        .text_context = text_context,
        .stop = options.stop,
        .arenas = arenas,
        .now_s = now_s,
        .top = top,
        .arena = arena,
    };
    pool.run(@min(tasks, context.candidates.len), &context, verifyTask);
    if (context.out_of_memory.load(.acquire)) return error.OutOfMemory;
    try out.appendSlice(arena, top[0..context.top_count]);
    sortMatches(out.items);
}

fn sortMatches(matches: []Match) void {
    std.mem.sort(Match, matches, {}, struct {
        fn before(_: void, a: Match, b: Match) bool {
            return matchRanksBefore(a, b);
        }
    }.before);
}

test "verify: folded matches, line and snippet from the original text" {
    const text = "Primera línea\nUna ACCIÓN rápida\nel Ñandú corre\n3×4 y 3x4\n";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "accion", "ACCIÓN", "acción" }) |query| {
        const words = try splitWords(arena, query);
        const verified = verify(text, words, words[0], true, arena).?;
        try testing.expectEqual(@as(u32, 2), verified.line);
        try testing.expectEqualStrings("Una ACCIÓN rápida", verified.snippet);
    }
    const verified = verify(
        text,
        try splitWords(arena, "nandu corre"),
        try fold.foldAlloc(arena, "nandu corre"),
        true,
        arena,
    ).?;
    try testing.expectEqual(@as(u32, 3), verified.line);
    try testing.expect(verified.phrase);
    // Two hits of different lengths, counted without overlap.
    try testing.expectEqual(
        @as(u32, 3),
        verify("acción accion ACCIÓN", &.{"accion"}, "accion", true, arena).?.count,
    );
}

const FileDocs = struct {
    fn readText(
        _: *anyopaque,
        doc: DocIn,
        text: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!bool {
        return readPlain(gpa, doc.path, text);
    }
};

test "search: the top matches equal reading every document and ranking them all" {
    const gpa = testing.allocator;
    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Few words, so documents share them, phrases occur by chance, and
    // scores tie (recency and depth vary too).
    const vocab = [_][]const u8{
        "select", "from", "where", "fn", "main", "the", "lumen", "index", "*", "use", "state",
        "café",
    };
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    const docs_count = 400;
    var docs: [docs_count]DocIn = undefined;
    const now = sys.nowSeconds();
    try test_dir.mkdir("deep/er");
    for (&docs, 0..) |*doc, i| {
        var text: std.ArrayList(u8) = .empty;
        for (0..random.intRangeAtMost(usize, 3, 40)) |_| {
            try text.appendSlice(arena, vocab[random.uintLessThan(usize, vocab.len)]);
            try text.append(arena, if (random.uintLessThan(u8, 6) == 0) '\n' else ' ');
        }
        const folder = if (i % 3 == 0) "/deep/er" else "";
        const path = try arena.print("{s}{s}/{s}{d}.txt", .{
            test_dir.absolute,
            folder,
            if (i % 7 == 0) "main" else "doc",
            i,
        });
        var path_buffer: paths.Buffer = undefined;
        try sys.writeFile(try std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0), text.items);
        const ages_days = [_]i64{ 0, 3, 20, 100, 300, 900 };
        const age_s = ages_days[i % ages_days.len] * std.time.s_per_day;
        doc.* = .{ .path = path, .mtime = now - age_s, .size = text.items.len };
    }
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var dummy: u8 = 0;
    const reader: TextReader = .{ .read = FileDocs.readText, .context = &dummy };
    var index = try build(gpa, pool, &docs, reader, null);
    defer index.deinit(gpa);

    var out: std.ArrayList(Match) = .empty;
    var want: std.ArrayList(Match) = .empty;
    var doc_text: std.ArrayList(u8) = .empty;
    defer doc_text.deinit(gpa);
    const queries = [_][]const u8{
        "select * from", "fn main",           "use state", "the lumen", "lumen", "where",
        "café index",
        "main",          "from where select",
    };
    for (queries) |query| for ([_]usize{ 5, 20 }) |limit| {
        try search(
            &index,
            gpa,
            arena,
            pool,
            query,
            .{ .limit = limit, .text_path = plainPath, .text_context = &dummy },
            &out,
        );
        // Every document read and ranked.
        want.clearRetainingCapacity();
        const words = try splitWords(arena, query);
        const phrase = try fold.foldAlloc(arena, std.mem.trim(u8, query, " \t"));
        for (docs, 0..) |doc, i| {
            if (!try readPlain(gpa, doc.path, &doc_text)) continue;
            const verified = verify(doc_text.items, words, phrase, true, arena) orelse continue;
            const bonus: i32 = if (verified.phrase) phrase_max else 0;
            try want.append(arena, .{
                .doc = @intCast(i),
                .count = verified.count,
                .line = verified.line,
                .snippet = verified.snippet,
                .score = rank(doc, verified.count, words, now) + bonus,
            });
        }
        sortMatches(want.items);
        want.shrinkRetainingCapacity(@min(want.items.len, limit));
        try testing.expectEqual(want.items.len, out.items.len);
        for (want.items, out.items) |wanted, found| {
            try testing.expectEqual(wanted.doc, found.doc);
            try testing.expectEqual(wanted.score, found.score);
            try testing.expectEqual(wanted.line, found.line);
            try testing.expectEqualStrings(wanted.snippet, found.snippet);
        }
    };
}

test "search: unaccented and capital queries find accented text" {
    const gpa = testing.allocator;
    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    const texts = [_][]const u8{
        "notas\nLa acción empieza aquí.\nfin\n",
        "el ÑANDÚ es un ave\n",
        "nothing to see\naccidental cion\n",
        "Configuración del sistema\n",
    };
    var test_paths: [texts.len][]u8 = undefined;
    var docs: [texts.len]DocIn = undefined;
    for (texts, 0..) |text, i| {
        test_paths[i] = try gpa.print("{s}/doc{d}.txt", .{ test_dir.absolute, i });
        var path_buffer: paths.Buffer = undefined;
        const path = try std.mem.printSentinel(&path_buffer, "{s}", .{test_paths[i]}, 0);
        try sys.writeFile(path, text);
        docs[i] = .{ .path = test_paths[i], .mtime = 0, .size = text.len };
    }
    defer for (test_paths) |path| gpa.free(path);
    const pool = try Pool.create(gpa, testing.io, 2);
    defer pool.destroy();
    var dummy: u8 = 0;
    const reader: TextReader = .{ .read = FileDocs.readText, .context = &dummy };
    var index = try build(gpa, pool, &docs, reader, null);
    defer index.deinit(gpa);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(Match) = .empty;
    const cases = [_]struct { query: []const u8, doc: u32, line: u32, snippet: []const u8 }{
        .{ .query = "accion", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .query = "ACCIÓN", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .query = "acción", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .query = "nandu", .doc = 1, .line = 1, .snippet = "el ÑANDÚ es un ave" },
        .{ .query = "ñandú ave", .doc = 1, .line = 1, .snippet = "el ÑANDÚ es un ave" },
        .{ .query = "configuracion", .doc = 3, .line = 1, .snippet = "Configuración del sistema" },
        .{ .query = "aqui", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
    };
    for (cases) |case| {
        try search(
            &index,
            gpa,
            arena.allocator(),
            pool,
            case.query,
            .{ .limit = 10, .text_path = plainPath, .text_context = &dummy },
            &out,
        );
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(case.doc, out.items[0].doc);
        try testing.expectEqual(case.line, out.items[0].line);
        try testing.expectEqualStrings(case.snippet, out.items[0].snippet);
    }
    try search(
        &index,
        gpa,
        arena.allocator(),
        pool,
        "×yz",
        .{ .limit = 10, .text_path = plainPath, .text_context = &dummy },
        &out,
    );
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // Not wanted any more (a newer query waits): no file is read.
    var stop: std.atomic.Value(bool) = .init(true);
    try search(
        &index,
        gpa,
        arena.allocator(),
        pool,
        "accion",
        .{ .limit = 10, .text_path = plainPath, .text_context = &dummy, .stop = &stop },
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
    var test_paths: [60][]const u8 = undefined;
    var docs: [60]DocIn = undefined;
    var made_count: usize = 0;
    defer for (texts[0..made_count], test_paths[0..made_count]) |text, path| {
        gpa.free(text);
        gpa.free(path);
    };
    var prng = std.Random.DefaultPrng.init(5);
    const random = prng.random();
    for (0..texts.len) |i| {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        for (0..random.intRangeAtMost(usize, 1, 6)) |_| {
            try text.appendSlice(gpa, vocab[random.uintLessThan(usize, vocab.len)]);
            try text.append(gpa, ' ');
        }
        const path = try gpa.print("{d}", .{i});
        texts[i] = text.toOwnedSlice(gpa) catch |err| {
            gpa.free(path);
            return err;
        };
        test_paths[i] = path;
        made_count += 1;
        docs[i] = .{
            .path = path,
            .mtime = @intCast(i),
            .size = i,
            .source = if (i % 7 == 0) .extracted else .plain,
        };
    }
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var test_docs: TestDocs = .{ .texts = &texts };
    return build(gpa, pool, &docs, .{ .read = TestDocs.readText, .context = &test_docs }, null);
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
    for (queries) |words| {
        try index.candidates(gpa, words, &got);
        try testing.expect(strictlyAscending(u32, got.items));
        for (got.items) |doc| {
            try testing.expect(doc < index.docs_count);
            const source: Source = @fromBackingInt(@intCast(index.sources[doc]));
            sum +%= index.path(doc).len +% @as(
                usize,
                @bitCast(index.mtimes[doc]),
            ) +% index.sizes[doc] +% @backingInt(source);
        }
    }
    for (0..index.docs_count) |doc| sum +%= index.path(@intCast(doc)).len;
    std.mem.doNotOptimizeAway(sum);
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
        Index.parse(good[0..cut], .heap),
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
        .{ .offset = docs_offset + docs_count * 16, .value = 0xffff_fff0, .wide = false },
        .{ .offset = docs_offset + docs_count * 22, .value = 9, .wide = false },
        // Keys out of order (binary search would miss), offsets going back.
        .{ .offset = segment.keys_offset, .value = 0xffff_ff, .wide = false },
        .{ .offset = segment.offsets_offset + 4, .value = 0xffff_ffff, .wide = false },
    };
    for (cases, 0..) |case, i| {
        @memcpy(bad, good);
        if (case.offset == docs_offset + docs_count * 22) {
            bad[case.offset] = @intCast(case.value);
        } else if (case.wide) {
            Patch.write64(bad, case.offset, case.value);
        } else {
            Patch.write32(bad, case.offset, @intCast(case.value));
        }
        if (Index.parse(bad, .heap)) |_| {
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
    var index = try smallIndex(gpa);
    errdefer index.deinit(gpa);
    var test_docs: TestDocs = .{ .texts = &update_texts };
    for (0..segments_small_merge_min) |i| {
        var name_buffer: [8]u8 = undefined;
        const added = [_]DocIn{.{
            .path = try std.mem.print(&name_buffer, "{d}", .{i}),
            .mtime = 100,
            .size = 1,
        }};
        const next = try update(gpa, pool, &index, &.{}, &added, .{
            .read = TestDocs.readText,
            .context = &test_docs,
        }, null);
        index.deinit(gpa);
        index = next;
    }
    return index;
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
    var sink: Sink = .{ .gpa = gpa, .written_bytes = old.bytes.len };
    defer sink.deinit();
    const header = appendInto(&sink, pool, old, gone, added, text, null) catch |err|
        return memoryOnly(err);
    const bytes = try gpa.alignedAlloc(u8, .@"8", old.bytes.len + sink.bytes.items.len);
    errdefer gpa.free(bytes);
    @memcpy(bytes[0..old.bytes.len], old.bytes);
    @memcpy(bytes[old.bytes.len..], sink.bytes.items);
    @memcpy(bytes[0..header_size], &header.encode());
    return Index.parse(bytes, .heap);
}

/// What the service does with the index it mapped: updates it and appends
/// to it. Must never crash on an index that `parse` accepted, and must give
/// one that parses and answers.
fn exerciseUpdates(index: *const Index, gpa: std.mem.Allocator, pool: *Pool) !void {
    var test_docs: TestDocs = .{ .texts = &update_texts };
    const reader: TextReader = .{ .read = TestDocs.readText, .context = &test_docs };
    const added = [_]DocIn{
        .{ .path = "0", .mtime = 200, .size = 1 },
        .{ .path = "3", .mtime = 200, .size = 1 },
    };
    const gone: []const u32 = if (index.docs_count > 0) &.{0} else &.{};
    var updated = try update(gpa, pool, index, gone, &added, reader, null);
    defer updated.deinit(gpa);
    try exerciseIndex(&updated, gpa);
    var appended = try appendMemory(gpa, pool, index, gone, &added, reader);
    defer appended.deinit(gpa);
    try exerciseIndex(&appended, gpa);
}

test "segments that repeat or reorder doc ids (a damaged file): queries, updates and appends cope" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var index = try segmentedIndex(gpa, pool);
    defer index.deinit(gpa);
    try testing.expectEqual(@as(usize, 5), index.segments_count);
    // The last segment holds document 63 ("config arena zig") alone: each
    // of its lists is that id, one byte. Make it 61 ("token arena
    // parser"): "arena" lists 61 in segment 2 and again in segment 4, and
    // "zig" lists 62 in segment 3, then 61. Nothing `parse` checks.
    const last = index.segments[4];
    @memset(index.bytes[@intCast(last.postings_offset)..][0..@intCast(last.postings_size)], 61);
    _ = try Index.parse(index.bytes, .heap);

    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    try index.candidates(gpa, &.{"arena"}, &got);
    try testing.expect(strictlyAscending(u32, got.items));
    try testing.expect(std.mem.findScalar(u32, got.items, 61) != null);
    try index.candidates(gpa, &.{"zig"}, &got);
    try testing.expect(strictlyAscending(u32, got.items));

    // Appended: the small segments (all five) are decoded and merged. That
    // asserted (a crash loop with safety checks, a wrapped delta and lost
    // results without).
    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try test_dir.path(&index_path_buffer, "content.idx");
    try index.save(index_path);
    var mapped = try Index.open(index_path);
    defer mapped.deinit(gpa);
    var test_docs: TestDocs = .{ .texts = &update_texts };
    const added = [_]DocIn{.{ .path = "0", .mtime = 300, .size = 1 }};
    var appended = (try appendFile(
        gpa,
        pool,
        &mapped,
        &.{},
        &added,
        .{ .read = TestDocs.readText, .context = &test_docs },
        index_path,
        null,
    )).?;
    defer appended.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), appended.segments_count);
    try appended.candidates(gpa, &.{"zig"}, &got);
    try testing.expect(strictlyAscending(u32, got.items));
    // 61 by the damage, 62, and 64 (the new "arena zig élan").
    for ([_]u32{ 61, 62, 64 }) |doc| {
        try testing.expect(std.mem.findScalar(u32, got.items, doc) != null);
    }
    try exerciseUpdates(&index, gpa, pool);
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

    fn alloc(context: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        const memory = peak_allocator.child.rawAlloc(len, a, ra) orelse return null;
        peak_allocator.count(len, 0);
        return memory;
    }

    fn resize(context: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        if (!peak_allocator.child.rawResize(m, a, n, ra)) return false;
        peak_allocator.count(n, m.len);
        return true;
    }

    fn remap(context: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        const memory = peak_allocator.child.rawRemap(m, a, n, ra) orelse return null;
        peak_allocator.count(n, m.len);
        return memory;
    }

    fn free(context: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        peak_allocator.child.rawFree(m, a, ra);
        peak_allocator.count(0, m.len);
    }
};

test "a round reads no more than round_pairs_max of possible text, one document at least" {
    var dummy: u8 = 0;
    const reader: TextReader = .{ .read = TestDocs.readText, .context = &dummy };
    var docs: [2000]DocIn = undefined;
    for (&docs) |*doc| doc.* = .{ .path = "", .mtime = 0, .size = 4096 };
    // Small files: `round_docs_max` a round, and what is left at the end.
    try testing.expectEqual(@as(usize, round_docs_max), roundEnd(&docs, 0, reader));
    try testing.expectEqual(docs.len, roundEnd(&docs, docs.len - 5, reader));
    // Files of `text_bytes_max` or more (no more than that is read).
    for (&docs) |*doc| doc.size = 1 << 30;
    const round_docs_expected: usize = round_pairs_max / text_bytes_max;
    try testing.expectEqual(round_docs_expected, roundEnd(&docs, 0, reader));
    // Extracted text: as long as the reader says, else the most kept.
    for (&docs) |*doc| doc.source = .extracted;
    try testing.expectEqual(@as(usize, 1), roundEnd(&docs, 0, reader));
    const ExtractedBytes = struct {
        fn small(_: *anyopaque, _: DocIn) u64 {
            return 1000;
        }
    };
    var known = reader;
    known.extracted_bytes = ExtractedBytes.small;
    try testing.expectEqual(@as(usize, round_docs_max), roundEnd(&docs, 0, known));
}

test "building high-entropy text: memory stays bounded by rounds and segments" {
    // 24 files of 1 MB of random bytes: ~1 M distinct trigrams each, 24 M
    // pairs. Read in one round, they were all held three times at once
    // (per task, gathered, sorting); with rounds of 1024 files, any number
    // of such files was. Rounds bounded by documents only peak at ~380 MB
    // here (twice as much with twice the files), bounded by pairs ~200 MB,
    // whatever the number of files.
    const files_count = 24;
    var prng = std.Random.DefaultPrng.init(77);
    var texts: [files_count][]const u8 = undefined;
    var made: usize = 0;
    defer for (texts[0..made]) |text| testing.allocator.free(text);
    var docs: [files_count]DocIn = undefined;
    var names: [files_count][8]u8 = undefined;
    for (&texts, &docs, &names, 0..) |*text, *doc, *name, i| {
        const bytes = try testing.allocator.alloc(u8, text_bytes_max);
        prng.random().bytes(bytes);
        text.* = bytes;
        made += 1;
        doc.* = .{ .path = try std.mem.print(name, "{d}", .{i}), .mtime = 0, .size = text_bytes_max };
    }
    var peak_allocator: PeakAllocator = .{ .child = testing.allocator };
    const gpa = peak_allocator.allocator();
    const pool = try Pool.create(testing.allocator, testing.io, 3);
    defer pool.destroy();
    var test_docs: TestDocs = .{ .texts = &texts };
    var stats: BuildStats = .{};
    // Written as it grows, like the service does: the index is not held.
    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try test_dir.path(&index_path_buffer, "content.idx");
    const reader: TextReader = .{ .read = TestDocs.readText, .context = &test_docs };
    var index = try buildFile(gpa, pool, &docs, reader, index_path, &stats);
    defer index.deinit(gpa);
    try testing.expect(stats.pairs > 20 << 20);
    try testing.expect(stats.segments >= 5);
    // A round (4 M pairs, plus growth), a segment (4 M and a document's
    // 1 M) and the sort's scratch, at 8 bytes a pair; the encoded segment
    // before it is written; per task a 2 MB trigram map and a text.
    try testing.expect(peak_allocator.peak < 250 << 20);
}

test "random byte flips in a content index never crash, nor updating it" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var index = try segmentedIndex(gpa, pool);
    defer index.deinit(gpa);
    const bad = try gpa.alignedAlloc(u8, .@"8", index.bytes.len);
    defer gpa.free(bad);
    var prng = std.Random.DefaultPrng.init(23);
    const random = prng.random();
    var accepted: usize = 0;
    for (0..3000) |_| {
        @memcpy(bad, index.bytes);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            bad[random.uintLessThan(usize, bad.len)] = random.int(u8);
        }
        if (Index.parse(bad, .heap)) |parsed| {
            try exerciseIndex(&parsed, gpa);
            try exerciseUpdates(&parsed, gpa, pool);
            accepted += 1;
        } else |_| {}
    }
    try testing.expect(accepted > 0);
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
    const index = Index.parse(input, .heap) catch return;
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

const FlipsContext = struct { good: []const u8, pool: *Pool };

fn fuzzFlips(context: FlipsContext, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    const good = context.good;
    const bytes = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(bytes);
    @memcpy(bytes, good);
    const flips = smith.valueRangeAtMost(u8, 0, 8);
    for (0..flips) |_| bytes[smith.index(bytes.len)] = smith.value(u8);
    // Sometimes a whole u32 or u64 field, aligned like the real ones.
    if (smith.boolWeighted(3, 1)) {
        const offset = smith.index(bytes.len / 4) * 4;
        std.mem.writeInt(u32, bytes[offset..][0..4], smith.value(u32), .little);
    }
    const cut = if (smith.boolWeighted(7, 1)) smith.index(bytes.len + 1) else bytes.len;
    const index = Index.parse(bytes[0..cut], .heap) catch return;
    try exerciseIndex(&index, gpa);
    try exerciseUpdates(&index, gpa, context.pool);
}

test "fuzz: a real content index with random damage never crashes, nor updating it" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var index = try segmentedIndex(gpa, pool);
    defer index.deinit(gpa);
    try testing.fuzz(FlipsContext{ .good = index.bytes, .pool = pool }, fuzzFlips, .{});
}

fn fuzzVerify(_: void, smith: *testing.Smith) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const weights: []const testing.Smith.Weight = &.{
        .value(u8, 'a', 20),
        .value(u8, 'b', 10),
        .value(u8, ' ', 8),
        .value(u8, '\n', 4),
        .rangeAtMost(u8, 0x80, 0xff, 1),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var text: [600]u8 = undefined;
    var query: [16]u8 = undefined;
    const text_used = text[0..smith.sliceWeightedBytes(&text, weights)];
    const query_used = query[0..smith.sliceWeightedBytes(&query, weights)];
    const words = try splitWords(arena, query_used);
    const phrase = try fold.foldAlloc(arena, std.mem.trim(u8, query_used, " \t"));
    if (verify(text_used, words, phrase, true, arena)) |verified| {
        try testing.expect(std.unicode.utf8ValidateSlice(verified.snippet));
        try testing.expect(verified.count >= 1);
        try testing.expect(verified.count <= count_cap);
        try testing.expect(verified.line >= 1);
    }
}

test "fuzz: verify on arbitrary text and queries" {
    try testing.fuzz({}, fuzzVerify, .{ .corpus = &.{
        "\x0d\x00\x00\x00ab\nxx ab ab b" ++ "\x05\x00\x00\x00ab  b",
    } });
}
