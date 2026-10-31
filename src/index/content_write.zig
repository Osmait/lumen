//! Writing a content index (`content_format.zig` has the layout): a `Sink`
//! that keeps the bytes in memory or streams them to a file, and the pieces
//! written to it in order, the doc table and its paths, each segment (its
//! (trigram, doc) pairs radix-sorted and encoded, or copied from another
//! index), then the directory, which also gives the header to put first.
//!
//! What `ContentIndex.parse` checks on reading is asserted here on writing,
//! so a file this code wrote and one the reader rejects can only differ by
//! damage. `content_build.zig` decides what goes in; this file only lays it
//! out.

const std = @import("std");
const assert = std.debug.assert;
const sys = @import("os");
const format = @import("format.zig");
const alignUp = format.alignUp;
const BytesConst = format.BytesConst;
const content_format = @import("content_format.zig");
const magic = content_format.magic;
const header_size = content_format.header_size;
const Header = content_format.Header;
const SegmentEntry = content_format.SegmentEntry;
const doc_size = content_format.doc_size;
const path_bytes_max = content_format.path_bytes_max;
const DocIn = content_format.DocIn;
const trigram_bits = content_format.trigram_bits;
const trigram_mask = content_format.trigram_mask;
const writeVarint = content_format.writeVarint;
const dedupSorted = content_format.dedupSorted;

pub const WriteError = std.mem.Allocator.Error || sys.Error || error{
    /// A doc table and its paths that end past what u32 path offsets reach
    /// (4 GiB).
    IndexTooLarge,
};

const BytesAligned8 = std.array_list.Aligned(u8, .@"8");

/// Where an index is written: memory, where it becomes the index, or a file,
/// keeping only what is not written yet. Offsets are positions in the whole.
pub const Sink = struct {
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

    pub fn deinit(sink: *Sink) void {
        sink.bytes.deinit(sink.gpa);
    }

    fn position(sink: *const Sink) usize {
        return sink.written_bytes + sink.bytes.items.len;
    }

    fn append(sink: *Sink, bytes: []const u8) WriteError!void {
        const to_file = sink.file != null or sink.append_file != null;
        if (to_file and bytes.len >= direct_bytes_min) {
            try sink.flush();
            try sink.put(bytes);
            sink.written_bytes += bytes.len;
            return;
        }
        try sink.bytes.appendSlice(sink.gpa, bytes);
    }

    fn put(sink: *Sink, bytes: []const u8) WriteError!void {
        if (sink.file) |file| return file.write(bytes);
        if (sink.append_file) |file| return file.write(bytes);
    }

    fn zeros(sink: *Sink, count: usize) WriteError!void {
        try sink.bytes.appendNTimes(sink.gpa, 0, count);
    }

    /// Zeros up to the next multiple of `format.alignment_bytes`.
    fn padToAlignment(sink: *Sink) WriteError!void {
        try sink.zeros(alignUp(sink.position()) - sink.position());
        assert(sink.position() % format.alignment_bytes == 0);
    }

    /// Writes what is buffered (file mode only).
    pub fn flush(sink: *Sink) WriteError!void {
        if (sink.file == null and sink.append_file == null) return;
        try sink.put(sink.bytes.items);
        sink.written_bytes += sink.bytes.items.len;
        sink.bytes.clearRetainingCapacity();
    }
};

/// Where `writeDocs` put the doc table, and how many bytes of paths it
/// added after it.
pub const DocTableWritten = struct { offset: usize, paths_size: usize };

pub const WriteDocsOptions = struct {
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
pub fn writeDocs(
    sink: *Sink,
    docs: []const DocIn,
    options: WriteDocsOptions,
) WriteError!DocTableWritten {
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

/// A segment of another index, as it is.
pub fn copySegment(
    sink: *Sink,
    directory: *std.ArrayList(SegmentEntry),
    from: BytesConst,
    segment: SegmentEntry,
) WriteError!void {
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

/// Sorts a segment's pairs by trigram (stable, so docs stay ascending) and
/// appends keys, offsets and varint-delta lists.
///
/// Pairs decoded from a file (`appendFile` merges its last segments) are
/// not trusted to be in order: in a damaged file a later segment may list
/// a document again, or one lower than an earlier segment did. Those are
/// sorted whole and deduplicated, never encoded as wrapped deltas.
pub fn closeSegment(
    sink: *Sink,
    directory: *std.ArrayList(SegmentEntry),
    pairs: []u64,
    scratch: *std.ArrayList(u64),
) WriteError!void {
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

pub inline fn pairOf(key: u32, doc: u32) u64 {
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

/// The segment directory; returns the header to put first.
///
/// What `ContentIndex.parse` checks on reading is asserted here on
/// writing (see the top of the file).
pub fn finish(
    sink: *Sink,
    directory: []const SegmentEntry,
    docs_count: usize,
    table: DocTableWritten,
) WriteError!Header {
    try sink.padToAlignment();
    const directory_offset = sink.position();
    try sink.append(std.mem.sliceAsBytes(directory));
    const size_total = sink.position();

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
