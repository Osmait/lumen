//! Building a content index, whole (`build`, `buildFile`) or from the last
//! one and what changed (`update`, `updateFile`, `appendFile`).
//!
//! Documents are read in rounds on the pool: each task takes the next
//! document, reads its text (`TextReader`), and keeps its distinct trigrams
//! as (trigram, doc) pairs. Pairs join the open segment in doc order, and a
//! segment is closed (sorted, encoded, written: `content_write.zig`) once it
//! holds `segment_pairs_max` of them. A round reads no more documents than
//! could fill a segment, so memory stays bounded whatever the text.
//!
//! An update keeps the old index's doc ids: the documents that changed or
//! went are flagged removed, and the new versions get new ids after the
//! others, in segments of their own.

const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const Pool = @import("Pool.zig");
const sys = @import("os");
const content_format = @import("content_format.zig");
const header_size = content_format.header_size;
const Header = content_format.Header;
const SegmentEntry = content_format.SegmentEntry;
const flag_removed = content_format.flag_removed;
const DocIn = content_format.DocIn;
const Trigrams = content_format.Trigrams;
const trigrams_count = content_format.trigrams_count;
const ListReader = content_format.ListReader;
const sliceAt = content_format.sliceAt;
const Index = @import("ContentIndex.zig");
const content_write = @import("content_write.zig");
const Sink = content_write.Sink;
const writeDocs = content_write.writeDocs;
const copySegment = content_write.copySegment;
const closeSegment = content_write.closeSegment;
const finish = content_write.finish;
const pairOf = content_write.pairOf;

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

pub const BuildStats = struct {
    docs_indexed: usize = 0,
    pairs: usize = 0,
    segments: usize = 0,
    elapsed_ns: u64 = 0,

    /// Times the build that started at `start_ns` and hands the statistics
    /// to the caller, if it asked for them.
    fn report(build_stats: *BuildStats, start_ns: u64, stats: ?*BuildStats) void {
        build_stats.elapsed_ns = sys.monotonicNs() - start_ns;
        if (stats) |out| out.* = build_stats.*;
    }
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
    const header = try finish(sink, directory.items, docs.len, table);
    build_stats.report(start_ns, stats);
    return header;
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
    const header = try finish(sink, directory.items, docs.len, table);
    build_stats.report(start_ns, stats);
    return header;
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
    const header = try finish(sink, directory.items, docs.len, table);
    build_stats.report(start_ns, stats);
    return header;
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

// ---------------------------------------------------------------- tests

const testing = std.testing;
const linux = std.os.linux;
const strictlyAscending = content_format.strictlyAscending;
const content_testing = @import("content_testing.zig");
const TestDocs = content_testing.TestDocs;
const smallIndex = content_testing.smallIndex;
const exerciseIndex = content_testing.exerciseIndex;

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

    fn alloc(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        const child = peak_allocator.child;
        const memory = child.rawAlloc(length, alignment, return_address) orelse return null;
        peak_allocator.count(length, 0);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        length_new: usize,
        return_address: usize,
    ) bool {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        const child = peak_allocator.child;
        if (!child.rawResize(memory, alignment, length_new, return_address)) return false;
        peak_allocator.count(length_new, memory.len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        length_new: usize,
        return_address: usize,
    ) ?[*]u8 {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        const child = peak_allocator.child;
        const remapped = child.rawRemap(memory, alignment, length_new, return_address) orelse
            return null;
        peak_allocator.count(length_new, memory.len);
        return remapped;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const peak_allocator: *PeakAllocator = @ptrCast(@alignCast(context));
        peak_allocator.child.rawFree(memory, alignment, return_address);
        peak_allocator.count(0, memory.len);
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
