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
const linux = std.os.linux;
const Pool = @import("Pool.zig");
const sys = @import("os");
const fold = @import("core").fold;

/// 02: trigrams of folded text (accents and case, `core.fold`).
/// 03: a flags column (documents removed by an incremental update).
/// 04: path offsets are positions in the file, so an appended doc table
/// refers to the paths already there instead of writing them all again.
const magic = "LUMCTX04";
const header_len = 64;

/// Plain text files above this are not indexed (logs, dumps, data).
pub const max_text = 1 << 20;
/// A segment is closed past this many (trigram, doc) pairs: 32 MB of pairs
/// and as much again to sort them. 16 M pairs made the build peak at 585 MB
/// (49 k documents) for no faster queries; 4 M peaks at ~346 MB, for 12
/// segments instead of 4 and an index 8 % larger.
const segment_pairs = 4 << 20;
/// Documents read in parallel per round.
const batch_docs = 1024;

/// Where a document's text comes from: the file itself, or text extracted
/// from it (PDF, Office) and cached on disk.
pub const Source = enum(u8) { plain = 0, extracted = 1 };

pub const DocIn = struct {
    path: []const u8,
    mtime: i64,
    size: u64,
    source: Source = .plain,
};

/// Trigrams of folded text, packed in 24 bits each: "Acción" gives "acc",
/// "cci", "cio", "ion", the same as "accion" or "ACCION". A folded character
/// is one byte, so a trigram is three folded characters.
const Trigrams = struct {
    s: []const u8,
    i: usize = 0,
    window: u32 = 0,
    seen: u2 = 0,

    fn next(t: *Trigrams) ?u32 {
        while (t.i < t.s.len) {
            t.window = (t.window << 8 | fold.step(t.s, &t.i)) & 0xff_ffff;
            if (t.seen == 2) return t.window;
            t.seen += 1;
        }
        return null;
    }
};

fn align8(x: usize) usize {
    return (x + 7) & ~@as(usize, 7);
}

const SegEntry = extern struct {
    n_keys: u64,
    keys_off: u64,
    offs_off: u64,
    post_off: u64,
    post_len: u64,
};

pub const Index = struct {
    buf: []align(8) u8,
    mapped: bool,
    n_docs: usize,
    n_segs: usize,
    mtimes: []const i64,
    sizes: []const u64,
    path_off: []const u32,
    path_len: []const u16,
    sources: []const u8,
    flags: []const u8,
    /// The file up to `total`: paths are found at their offsets in it.
    file: []const u8,
    segs: []const SegEntry,
    /// Documents flagged removed: their ids stay, queries skip them.
    n_removed: usize,
    /// Bytes the header refers to; the rest of the file is what updates
    /// left behind (old doc tables, merged segments).
    live_bytes: usize,

    pub fn deinit(ix: *Index, gpa: std.mem.Allocator) void {
        if (ix.mapped) _ = linux.munmap(ix.buf.ptr, ix.buf.len) else gpa.free(ix.buf);
        ix.* = undefined;
    }

    pub fn path(ix: *const Index, doc: u32) []const u8 {
        return ix.file[ix.path_off[doc]..][0..ix.path_len[doc]];
    }

    pub fn removed(ix: *const Index, doc: u32) bool {
        return ix.flags[doc] & flag_removed != 0;
    }

    /// Documents a query can find.
    pub fn live(ix: *const Index) usize {
        return ix.n_docs - ix.n_removed;
    }

    pub fn docIn(ix: *const Index, d: u32) DocIn {
        return .{
            .path = ix.path(d),
            .mtime = ix.mtimes[d],
            .size = ix.sizes[d],
            .source = @fromBackingInt(@intCast(ix.sources[d])),
        };
    }

    /// Checks that `buf` is a well-formed index and wraps it without copying
    /// (`mapped` says how `deinit` releases it).
    ///
    /// The file comes from disk: it may be truncated, from another version or
    /// garbage. Everything later accesses index with is checked here, in
    /// linear passes over the doc table and the segment keys (no posting list
    /// is decoded; the decoders are bounds-safe instead): header offsets in
    /// bounds and aligned, every path inside the file, every source a
    /// known kind, every segment's arrays in bounds, keys strictly ascending
    /// (binary search), offsets non-decreasing and within the postings.
    pub fn parse(whole: []align(8) u8, mapped: bool) error{BadIndex}!Index {
        if (whole.len < header_len or !std.mem.eql(u8, whole[0..8], magic)) return error.BadIndex;
        const rd = struct {
            fn u(b: []const u8, at: usize) u64 {
                return std.mem.readInt(u64, b[at..][0..8], .little);
            }
        }.u;
        // Updates append, then point the header at what they added: bytes
        // past `total` are an update whose header never got written.
        const total64 = rd(whole, 48);
        if (total64 > whole.len or total64 < header_len) return error.BadIndex;
        const buf = whole[0..@intCast(total64)];
        const n64 = rd(buf, 8);
        const n_segs64 = rd(buf, 16);
        const paths_len64 = rd(buf, 24);
        const docs_off64 = rd(buf, 32);
        const dir_off64 = rd(buf, 40);
        // Doc ids are u32 in posting lists and results.
        if (n64 > std.math.maxInt(u32)) return error.BadIndex;
        const n: usize = @intCast(n64);
        const docs_off = try region(buf.len, docs_off64, n, doc_bytes, 8);
        if (docs_off < header_len) return error.BadIndex;
        const paths_off = docs_off + n * doc_bytes;
        if (paths_len64 > buf.len - paths_off) return error.BadIndex;
        const paths_len: usize = @intCast(paths_len64);
        const dir_off = try region(buf.len, dir_off64, n_segs64, @sizeOf(SegEntry), 8);
        const n_segs: usize = @intCast(n_segs64);

        var o = docs_off;
        const mt = sliceAt(i64, buf, o, n);
        o += n * 8;
        const sz = sliceAt(u64, buf, o, n);
        o += n * 8;
        const po = sliceAt(u32, buf, o, n);
        o += n * 4;
        const pl = sliceAt(u16, buf, o, n);
        o += n * 2;
        const src = buf[o..][0..n];
        o += n;
        const fl = buf[o..][0..n];
        o += n;
        o += paths_len;
        var all_paths: usize = 0;
        for (po, pl) |off, l| {
            if (@as(u64, off) + l > buf.len) return error.BadIndex;
            all_paths += l;
        }
        for (src) |k| if (std.enums.fromInt(Source, k) == null) return error.BadIndex;
        var n_removed: usize = 0;
        for (fl) |f| {
            if (f & ~flag_removed != 0) return error.BadIndex;
            n_removed += f & flag_removed;
        }

        const segs = sliceAt(SegEntry, buf, dir_off, n_segs);
        var used = header_len + n * doc_bytes + all_paths + n_segs * @sizeOf(SegEntry);
        for (segs) |seg| {
            try checkSegment(buf, seg);
            used += @as(usize, @intCast(seg.n_keys)) * 8 + 4 + @as(usize, @intCast(seg.post_len));
        }

        return .{
            .buf = whole,
            .mapped = mapped,
            .n_docs = n,
            .n_segs = n_segs,
            .mtimes = mt,
            .sizes = sz,
            .path_off = po,
            .path_len = pl,
            .sources = src,
            .flags = fl,
            .file = buf,
            .segs = segs,
            .n_removed = n_removed,
            .live_bytes = used,
        };
    }

    /// Writes the index to `path_z` atomically (see `sys.writeFileAtomic`).
    pub fn save(ix: *const Index, path_z: [:0]const u8) sys.Error!void {
        try sys.writeFileAtomic(path_z, ix.buf);
    }

    pub fn open(path_z: [:0]const u8) (sys.Error || error{BadIndex})!Index {
        const buf = try sys.mapPrivate(path_z);
        errdefer _ = linux.munmap(buf.ptr, buf.len);
        return parse(buf, true);
    }

    /// Posting list bytes of `key` in segment `s` (empty if absent).
    fn list(ix: *const Index, s: usize, key: u32) []const u8 {
        const seg = ix.segs[s];
        const keys = sliceAt(u32, ix.buf, seg.keys_off, seg.n_keys);
        var lo: usize = 0;
        var hi: usize = keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (keys[mid] < key) lo = mid + 1 else hi = mid;
        }
        if (lo == keys.len or keys[lo] != key) return &.{};
        const offs = sliceAt(u32, ix.buf, seg.offs_off, seg.n_keys + 1);
        return ix.buf[seg.post_off + offs[lo] .. seg.post_off + offs[lo + 1]];
    }

    /// Documents containing every trigram of every word, folded (words of 3+
    /// folded characters; shorter ones cannot narrow anything and are checked
    /// on verify).
    /// Appends doc ids, ascending, to `out`.
    pub fn candidates(
        ix: *const Index,
        gpa: std.mem.Allocator,
        words: []const []const u8,
        out: *std.ArrayList(u32),
    ) std.mem.Allocator.Error!void {
        out.clearRetainingCapacity();
        var keys: std.ArrayList(u32) = .empty;
        defer keys.deinit(gpa);
        for (words) |w| {
            var it: Trigrams = .{ .s = w };
            while (it.next()) |k| try keys.append(gpa, k);
        }
        if (keys.items.len == 0) return;
        std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
        const uniq = dedupSorted(keys.items);

        var lists = try gpa.alloc([]const u8, uniq.len);
        defer gpa.free(lists);
        var cur: std.ArrayList(u32) = .empty;
        defer cur.deinit(gpa);
        var next: std.ArrayList(u32) = .empty;
        defer next.deinit(gpa);

        for (0..ix.n_segs) |s| {
            var empty = false;
            for (uniq, 0..) |k, i| {
                lists[i] = ix.list(s, k);
                if (lists[i].len == 0) empty = true;
            }
            if (empty) continue;
            // Shortest list first: every intersection only shrinks the set.
            std.mem.sort([]const u8, lists, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return a.len < b.len;
                }
            }.lt);
            cur.clearRetainingCapacity();
            try decodeAll(gpa, lists[0], ix.n_docs, &cur);
            for (lists[1..]) |l| {
                if (cur.items.len == 0) break;
                next.clearRetainingCapacity();
                try intersect(gpa, cur.items, l, ix.n_docs, &next);
                std.mem.swap(std.ArrayList(u32), &cur, &next);
            }
            for (cur.items) |d| if (!ix.removed(d)) try out.append(gpa, d);
        }
    }

    pub fn postingBytes(ix: *const Index) usize {
        var n: usize = 0;
        for (ix.segs) |s| n += s.post_len;
        return n;
    }
};

/// Bytes per document in the doc table (mtime, size, path_off, path_len,
/// source, flags).
const doc_bytes = 8 + 8 + 4 + 2 + 1 + 1;

/// A document whose old version an update replaced, or that is gone.
const flag_removed: u8 = 1;

/// Checks that `count` items of `size` bytes at `off` fit in a buffer of
/// `len` bytes, with `off` a multiple of `alignment`; returns `off`. Done in
/// u64 with overflow checks: every operand comes from the file.
fn region(len: usize, off: u64, count: u64, size: u64, alignment: u64) error{BadIndex}!usize {
    if (off % alignment != 0 or off > len) return error.BadIndex;
    const bytes = std.math.mul(u64, count, size) catch return error.BadIndex;
    if (bytes > len - off) return error.BadIndex;
    return @intCast(off);
}

fn checkSegment(buf: []align(8) const u8, seg: SegEntry) error{BadIndex}!void {
    const keys_off = try region(buf.len, seg.keys_off, seg.n_keys, 4, 4);
    const n_keys: usize = @intCast(seg.n_keys); // fits: bounded by buf.len
    const n_offs = std.math.add(u64, seg.n_keys, 1) catch return error.BadIndex;
    const offs_off = try region(buf.len, seg.offs_off, n_offs, 4, 4);
    _ = try region(buf.len, seg.post_off, seg.post_len, 1, 1);
    const keys = sliceAt(u32, @constCast(buf), keys_off, n_keys);
    const offs = sliceAt(u32, @constCast(buf), offs_off, n_keys + 1);
    if (n_keys > 1) {
        for (keys[0 .. n_keys - 1], keys[1..]) |a, b| if (a >= b) return error.BadIndex;
    }
    var prev: u32 = 0;
    for (offs) |x| {
        if (x < prev) return error.BadIndex;
        prev = x;
    }
    if (offs[n_keys] > seg.post_len) return error.BadIndex;
}

fn sliceAt(comptime T: type, buf: []align(8) u8, off: usize, n: usize) []T {
    const p: [*]T = @ptrCast(@alignCast(buf.ptr + off));
    return p[0..n];
}

fn dedupSorted(xs: []u32) []u32 {
    if (xs.len == 0) return xs;
    var w: usize = 1;
    for (xs[1..]) |x| {
        if (x != xs[w - 1]) {
            xs[w] = x;
            w += 1;
        }
    }
    return xs[0..w];
}

/// Next varint of `b` from `pos`, or null at the end of the list or on a
/// malformed one: cut off by the end of the list (continuation bit on the
/// last byte) or longer than a u32 needs. Never reads past `b`.
fn readVarint(b: []const u8, pos: *usize) ?u32 {
    var v: u32 = 0;
    var shift: u5 = 0;
    var i = pos.*;
    while (i < b.len) : (i += 1) {
        const byte = b[i];
        // The 5th byte holds the top 4 bits and ends the number.
        if (shift == 28 and byte > 0x0f) return null;
        v |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            pos.* = i + 1;
            return v;
        }
        shift += 7;
    }
    return null;
}

/// Decodes a posting list (first id, then deltas). A list from a damaged
/// file ends at the first id that is malformed, not increasing, overflowing
/// or not a document of the index: what comes out is always strictly
/// ascending and below `n_docs`, so callers can index the doc table with it.
const ListReader = struct {
    b: []const u8,
    n_docs: usize,
    pos: usize = 0,
    doc: u32 = 0,
    started: bool = false,

    fn next(r: *ListReader) ?u32 {
        const d = readVarint(r.b, &r.pos) orelse return r.stop();
        if (r.started) {
            if (d == 0) return r.stop();
            r.doc = std.math.add(u32, r.doc, d) catch return r.stop();
        } else {
            r.doc = d;
            r.started = true;
        }
        if (r.doc >= r.n_docs) return r.stop();
        return r.doc;
    }

    fn stop(r: *ListReader) ?u32 {
        r.pos = r.b.len;
        return null;
    }
};

fn writeVarint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v0: u32) !void {
    var v = v0;
    while (v >= 0x80) {
        try out.append(gpa, @intCast(v & 0x7f | 0x80));
        v >>= 7;
    }
    try out.append(gpa, @intCast(v));
}

fn decodeAll(gpa: std.mem.Allocator, b: []const u8, n_docs: usize, out: *std.ArrayList(u32)) !void {
    var r: ListReader = .{ .b = b, .n_docs = n_docs };
    while (r.next()) |doc| try out.append(gpa, doc);
}

/// `a` (sorted ids) ∩ the encoded list `b`, decoded on the fly.
fn intersect(
    gpa: std.mem.Allocator,
    a: []const u32,
    b: []const u8,
    n_docs: usize,
    out: *std.ArrayList(u32),
) !void {
    var r: ListReader = .{ .b = b, .n_docs = n_docs };
    var doc: u32 = 0;
    var i: usize = 0;
    var have = false;
    while (i < a.len) {
        if (!have) {
            doc = r.next() orelse return;
            have = true;
        }
        if (a[i] < doc) {
            i += 1;
        } else if (a[i] > doc) {
            have = false;
        } else {
            try out.append(gpa, doc);
            i += 1;
            have = false;
        }
    }
}

// --------------------------------------------------------------- building

/// Reads a document's text into `buf` for indexing or verifying: false when
/// it has none to index (gone, binary, too big). `extracted` documents are
/// read from the text cache by the caller-provided resolver. Running out of
/// memory is an error, never "no text": the index would keep the document
/// empty until it changed.
pub const TextFn = *const fn (ctx: *anyopaque, doc: DocIn, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) std.mem.Allocator.Error!bool;

/// A `TextFn` and the context it is called with.
pub const TextReader = struct { read: TextFn, ctx: *anyopaque };

/// Plain text of a file: up to `max_text` bytes, rejected if binary (a NUL in
/// the first 8 KB, git's rule).
pub fn readPlain(
    gpa: std.mem.Allocator,
    path: []const u8,
    buf: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    buf.clearRetainingCapacity();
    var zbuf: [4096]u8 = undefined;
    const z = std.mem.printSentinel(&zbuf, "{s}", .{path}, 0) catch return false;
    // Not a plain open: the path may have become a FIFO since it was indexed.
    const fd = sys.openRegular(z) catch return false;
    defer sys.close(fd);
    try buf.ensureTotalCapacity(gpa, 16 * 1024);
    while (buf.items.len <= max_text) {
        try buf.ensureUnusedCapacity(gpa, 64 * 1024);
        const spare = buf.unusedCapacitySlice();
        const n = linux.read(fd, spare.ptr, spare.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        buf.items.len += n;
    }
    if (buf.items.len > max_text) return false;
    const head = buf.items[0..@min(buf.items.len, 8000)];
    return std.mem.findScalar(u8, head, 0) == null;
}

const ExtractCtx = struct {
    gpa: std.mem.Allocator,
    docs: []const DocIn,
    lo: usize,
    text: TextFn,
    text_ctx: *anyopaque,
    /// Per task: trigram keys of each of its documents, concatenated.
    out: []std.ArrayList(u64),
    tasks: usize,
    batch_hi: usize,
    /// Set by a task that ran out of memory: the build fails (and is retried
    /// later) instead of indexing its documents as empty.
    oom: std.atomic.Value(bool) = .init(false),
};

fn extractTask(ctx: *ExtractCtx, t: usize) void {
    extractTaskOrFail(ctx, t) catch ctx.oom.store(true, .release);
}

fn extractTaskOrFail(ctx: *ExtractCtx, t: usize) std.mem.Allocator.Error!void {
    const gpa = ctx.gpa;
    const n = ctx.batch_hi - ctx.lo;
    const per = std.math.divCeil(usize, n, ctx.tasks) catch unreachable; // tasks > 0
    const from = ctx.lo + t * per;
    const to = @min(from + per, ctx.batch_hi);
    if (from >= to) return;
    // One bit per possible trigram: dedup in O(n) without sorting.
    const seen = try gpa.alloc(u64, (1 << 24) / 64);
    defer gpa.free(seen);
    @memset(seen, 0);
    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (from..to) |d| {
        if (!try ctx.text(ctx.text_ctx, ctx.docs[d], &text, gpa)) continue;
        keys.clearRetainingCapacity();
        var it: Trigrams = .{ .s = text.items };
        while (it.next()) |k| {
            const word = k >> 6;
            const bit = @as(u64, 1) << @intCast(k & 63);
            if (seen[word] & bit != 0) continue;
            seen[word] |= bit;
            try keys.append(gpa, k);
        }
        for (keys.items) |k| seen[k >> 6] &= ~(@as(u64, 1) << @intCast(k & 63));
        try ctx.out[t].ensureUnusedCapacity(gpa, keys.items.len);
        for (keys.items) |k| ctx.out[t].appendAssumeCapacity(@as(u64, k) << 32 | d);
    }
}

pub const BuildStats = struct { docs_indexed: usize = 0, pairs: usize = 0, segments: usize = 0, ns: u64 = 0 };

pub const BuildError = std.mem.Allocator.Error || error{BadIndex};
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
/// (`live_bytes` says how much is still used). A run of small segments at
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
    const h = try appendInto(&sink, pool, old, gone, added, text, stats);
    try sink.flush();
    // Everything the header will point at is on disk before it does.
    try file.sync();
    try file.writeAt(&headerBytes(h), 0);
    try file.sync();
    return try Index.open(path_z);
}

/// A segment smaller than this is merged with the next update's.
const small_postings = 1 << 20;
/// How many small segments at the end make a merge.
const merge_small = 4;

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
    const t0 = sys.monotonicNs();
    var st: BuildStats = .{};
    const n = old.n_docs + added.len;
    if (n > std.math.maxInt(u32)) return error.OutOfMemory;
    const docs = try gpa.alloc(DocIn, n);
    defer gpa.free(docs);
    for (docs[0..old.n_docs], 0..) |*d, i| d.* = old.docIn(@intCast(i));
    @memcpy(docs[old.n_docs..], added);
    const flags = try gpa.alloc(u8, n);
    defer gpa.free(flags);
    @memcpy(flags[0..old.n_docs], old.flags);
    @memset(flags[old.n_docs..], 0);
    for (gone) |id| flags[id] |= flag_removed;

    var keep = old.segs.len;
    while (keep > 0 and old.segs[keep - 1].post_len < small_postings) keep -= 1;
    if (old.segs.len - keep < merge_small) keep = old.segs.len;
    var dir: std.ArrayList(SegEntry) = .empty;
    defer dir.deinit(gpa);
    // Where they are: the file only grows.
    try dir.appendSlice(gpa, old.segs[0..keep]);
    var merged: std.ArrayList(u64) = .empty;
    defer merged.deinit(gpa);
    for (old.segs[keep..]) |seg| try segmentPairs(gpa, old, seg, flags, &merged);
    try indexDocs(sink, pool, &dir, docs, old.n_docs, text, &st, merged.items);
    const table = try writeDocs(sink, docs, flags, false, old.path_off);
    st.docs_indexed = added.len;
    return finish(sink, dir.items, docs.len, table, t0, &st, stats);
}

/// A segment's (trigram, doc) pairs, by trigram then doc, without the
/// documents `flags` mark removed.
fn segmentPairs(
    gpa: std.mem.Allocator,
    ix: *const Index,
    seg: SegEntry,
    flags: []const u8,
    out: *std.ArrayList(u64),
) std.mem.Allocator.Error!void {
    const n_keys: usize = @intCast(seg.n_keys);
    const keys = sliceAt(u32, ix.buf, @intCast(seg.keys_off), n_keys);
    const offs = sliceAt(u32, ix.buf, @intCast(seg.offs_off), n_keys + 1);
    const post = ix.buf[@intCast(seg.post_off)..][0..@intCast(seg.post_len)];
    for (keys, 0..) |k, i| {
        var r: ListReader = .{ .b = post[offs[i]..offs[i + 1]], .n_docs = ix.n_docs };
        while (r.next()) |doc| if (flags[doc] & flag_removed == 0) try out.append(
            gpa,
            @as(u64, k) << 32 | doc,
        );
    }
}

/// Where an index is written: memory, where it becomes the index, or a file,
/// keeping only what is not written yet. Offsets are positions in the whole.
const Sink = struct {
    gpa: std.mem.Allocator,
    file: ?*sys.AtomicFile = null,
    /// Or the end of an existing file (`appendFile`).
    app: ?*sys.AppendFile = null,
    buf: Out = .empty,
    /// Bytes already in the file.
    written: usize = 0,

    /// Larger pieces go to the file directly instead of through `buf`.
    const direct = 64 * 1024;

    fn deinit(k: *Sink) void {
        k.buf.deinit(k.gpa);
    }

    fn pos(k: *const Sink) usize {
        return k.written + k.buf.items.len;
    }

    fn append(k: *Sink, bytes: []const u8) FileError!void {
        if ((k.file != null or k.app != null) and bytes.len >= direct) {
            try k.flush();
            try k.put(bytes);
            k.written += bytes.len;
            return;
        }
        try k.buf.appendSlice(k.gpa, bytes);
    }

    fn put(k: *Sink, bytes: []const u8) FileError!void {
        if (k.file) |f| return f.write(bytes);
        if (k.app) |f| return f.write(bytes);
    }

    fn zeros(k: *Sink, n: usize) FileError!void {
        try k.buf.appendNTimes(k.gpa, 0, n);
    }

    fn pad8(k: *Sink) FileError!void {
        while (k.pos() % 8 != 0) try k.buf.append(k.gpa, 0);
    }

    /// Writes what is buffered (file mode only).
    fn flush(k: *Sink) FileError!void {
        if (k.file == null and k.app == null) return;
        try k.put(k.buf.items);
        k.written += k.buf.items.len;
        k.buf.clearRetainingCapacity();
    }
};

/// The header, once everything after it is written.
const Header = struct { n: usize, n_segs: usize, paths_len: usize, docs_off: usize, dir_off: usize, total: usize };

fn headerBytes(h: Header) [header_len]u8 {
    var b: [header_len]u8 = @splat(0);
    @memcpy(b[0..8], magic);
    std.mem.writeInt(u64, b[8..16], h.n, .little);
    std.mem.writeInt(u64, b[16..24], h.n_segs, .little);
    std.mem.writeInt(u64, b[24..32], h.paths_len, .little);
    std.mem.writeInt(u64, b[32..40], h.docs_off, .little);
    std.mem.writeInt(u64, b[40..48], h.dir_off, .little);
    std.mem.writeInt(u64, b[48..56], h.total, .little);
    return b;
}

/// A sink without a file never fails to write one.
fn memoryOnly(err: FileError) BuildError {
    return switch (err) {
        error.OutOfMemory, error.BadIndex => |e| e,
        else => unreachable,
    };
}

fn toMemory(sink: *Sink, h: Header) BuildError!Index {
    @memcpy(sink.buf.items[0..header_len], &headerBytes(h));
    const buf = try sink.buf.toOwnedSlice(sink.gpa);
    errdefer sink.gpa.free(buf);
    return Index.parse(buf, false);
}

fn toFile(sink: *Sink, h: Header, path_z: [:0]const u8) FileError!Index {
    try sink.flush();
    const f = sink.file.?;
    try f.writeAt(&headerBytes(h), 0);
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
    const t0 = sys.monotonicNs();
    var st: BuildStats = .{};
    var dir: std.ArrayList(SegEntry) = .empty;
    defer dir.deinit(sink.gpa);
    const table = try writeDocs(sink, docs, null, true, &.{});
    try indexDocs(sink, pool, &dir, docs, 0, text, &st, &.{});
    st.docs_indexed = docs.len;
    return finish(sink, dir.items, docs.len, table, t0, &st, stats);
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
    const t0 = sys.monotonicNs();
    var st: BuildStats = .{};
    const n = old.n_docs + added.len;
    if (n > std.math.maxInt(u32)) return error.OutOfMemory;
    const docs = try gpa.alloc(DocIn, n);
    defer gpa.free(docs);
    for (docs[0..old.n_docs], 0..) |*d, i| d.* = old.docIn(@intCast(i));
    @memcpy(docs[old.n_docs..], added);
    const flags = try gpa.alloc(u8, n);
    defer gpa.free(flags);
    @memcpy(flags[0..old.n_docs], old.flags);
    @memset(flags[old.n_docs..], 0);
    for (gone) |id| flags[id] |= flag_removed;

    var dir: std.ArrayList(SegEntry) = .empty;
    defer dir.deinit(gpa);
    const table = try writeDocs(sink, docs, flags, true, &.{});
    for (old.segs) |seg| try copySegment(sink, &dir, old.buf, seg);
    try indexDocs(sink, pool, &dir, docs, old.n_docs, text, &st, &.{});
    st.docs_indexed = added.len;
    return finish(sink, dir.items, docs.len, table, t0, &st, stats);
}

const DocTable = struct { off: usize, paths_len: usize };

/// Header room (a new file), then the doc table and the paths it adds.
/// The first `reuse.len` documents' paths are already in the file, at those
/// offsets (an appended table); the others' are written after the table.
fn writeDocs(
    sink: *Sink,
    docs: []const DocIn,
    flags: ?[]const u8,
    header_room: bool,
    reuse: []const u32,
) FileError!DocTable {
    if (header_room) try sink.zeros(header_len);
    try sink.pad8();
    var paths_len: usize = 0;
    for (docs[reuse.len..]) |d| paths_len += d.path.len;
    const docs_off = sink.pos();
    const paths_at = docs_off + docs.len * doc_bytes;
    // Offsets are u32.
    if (paths_at + paths_len > std.math.maxInt(u32)) return error.OutOfMemory;
    // Built in the buffer: nothing is written before the doc table is done.
    const at = sink.buf.items.len;
    try sink.zeros(align8(docs.len * doc_bytes + paths_len));
    const b = sink.buf.items;
    var o = at;
    for (docs) |d| {
        std.mem.writeInt(i64, b[o..][0..8], d.mtime, .little);
        o += 8;
    }
    for (docs) |d| {
        std.mem.writeInt(u64, b[o..][0..8], d.size, .little);
        o += 8;
    }
    var po: usize = paths_at;
    for (docs, 0..) |d, i| {
        if (i < reuse.len) {
            std.mem.writeInt(u32, b[o..][0..4], reuse[i], .little);
        } else {
            std.mem.writeInt(u32, b[o..][0..4], @intCast(po), .little);
            po += d.path.len;
        }
        o += 4;
    }
    for (docs) |d| {
        std.mem.writeInt(
            u16,
            b[o..][0..2],
            @intCast(@min(d.path.len, std.math.maxInt(u16))),
            .little,
        );
        o += 2;
    }
    for (docs) |d| {
        b[o] = @backingInt(d.source);
        o += 1;
    }
    if (flags) |f| @memcpy(b[o..][0..docs.len], f);
    o += docs.len;
    for (docs[reuse.len..]) |d| {
        @memcpy(b[o..][0..d.path.len], d.path);
        o += d.path.len;
    }
    return .{ .off = docs_off, .paths_len = paths_len };
}

/// Indexes `docs[from..]` (ids are positions in `docs`), closing segments as
/// they fill; `initial` pairs (decoded from segments being merged, lower
/// ids) go first.
fn indexDocs(
    sink: *Sink,
    pool: *Pool,
    dir: *std.ArrayList(SegEntry),
    docs: []const DocIn,
    from: usize,
    text: TextReader,
    st: *BuildStats,
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
        for (task_out) |*t| t.deinit(gpa);
        gpa.free(task_out);
    }
    for (task_out) |*t| t.* = .empty;

    const n = docs.len;
    var lo = from;
    while (lo < n) {
        const hi = @min(lo + batch_docs, n);
        var ctx: ExtractCtx = .{
            .gpa = gpa,
            .docs = docs,
            .lo = lo,
            .text = text.read,
            .text_ctx = text.ctx,
            .out = task_out,
            .tasks = tasks,
            .batch_hi = hi,
        };
        pool.run(tasks, &ctx, extractTask);
        if (ctx.oom.load(.acquire)) return error.OutOfMemory;
        // Task ranges are contiguous and in order: concatenating keeps pairs
        // in doc order, which the stable radix sort turns into (key, doc).
        for (task_out) |*t| {
            try pairs.appendSlice(gpa, t.items);
            t.clearRetainingCapacity();
        }
        lo = hi;
        if (pairs.items.len >= segment_pairs) try closePairs(sink, dir, &pairs, &scratch, st);
    }
    if (pairs.items.len > 0) try closePairs(sink, dir, &pairs, &scratch, st);
}

fn closePairs(
    sink: *Sink,
    dir: *std.ArrayList(SegEntry),
    pairs: *std.ArrayList(u64),
    scratch: *std.ArrayList(u64),
    st: *BuildStats,
) FileError!void {
    st.pairs += pairs.items.len;
    try closeSegment(sink, dir, pairs.items, scratch);
    st.segments += 1;
    pairs.clearRetainingCapacity();
    try sink.flush();
}

/// A segment of another index, as it is.
fn copySegment(
    sink: *Sink,
    dir: *std.ArrayList(SegEntry),
    from: []align(8) const u8,
    seg: SegEntry,
) FileError!void {
    const n_keys: usize = @intCast(seg.n_keys);
    try sink.pad8();
    const keys_off = sink.pos();
    try sink.append(from[@intCast(seg.keys_off)..][0 .. n_keys * 4]);
    try sink.pad8();
    const offs_off = sink.pos();
    try sink.append(from[@intCast(seg.offs_off)..][0 .. (n_keys + 1) * 4]);
    const post_off = sink.pos();
    try sink.append(from[@intCast(seg.post_off)..][0..@intCast(seg.post_len)]);
    try dir.append(sink.gpa, .{
        .n_keys = seg.n_keys,
        .keys_off = keys_off,
        .offs_off = offs_off,
        .post_off = post_off,
        .post_len = seg.post_len,
    });
}

/// The segment directory; returns the header to put first.
fn finish(
    sink: *Sink,
    dir: []const SegEntry,
    n_docs: usize,
    table: DocTable,
    t0: u64,
    st: *BuildStats,
    stats: ?*BuildStats,
) FileError!Header {
    try sink.pad8();
    const dir_off = sink.pos();
    try sink.append(std.mem.sliceAsBytes(dir));
    st.ns = sys.monotonicNs() - t0;
    if (stats) |s| s.* = st.*;
    return .{
        .n = n_docs,
        .n_segs = dir.len,
        .paths_len = table.paths_len,
        .docs_off = table.off,
        .dir_off = dir_off,
        .total = sink.pos(),
    };
}

const Out = std.array_list.Aligned(u8, .@"8");

/// Sorts a segment's pairs by trigram (stable, so docs stay ascending) and
/// appends keys, offsets and varint-delta lists.
fn closeSegment(
    sink: *Sink,
    dir: *std.ArrayList(SegEntry),
    pairs: []u64,
    scratch: *std.ArrayList(u64),
) FileError!void {
    const gpa = sink.gpa;
    try scratch.resize(gpa, pairs.len);
    radixByKey(pairs, scratch.items);

    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    var offs: std.ArrayList(u32) = .empty;
    defer offs.deinit(gpa);
    var post: std.ArrayList(u8) = .empty;
    defer post.deinit(gpa);
    var i: usize = 0;
    while (i < pairs.len) {
        const k: u32 = @intCast(pairs[i] >> 32);
        try keys.append(gpa, k);
        try offs.append(gpa, @intCast(post.items.len));
        var prev: u32 = 0;
        while (i < pairs.len and pairs[i] >> 32 == k) : (i += 1) {
            const d: u32 = @truncate(pairs[i]);
            try writeVarint(gpa, &post, d - prev);
            prev = d;
        }
    }
    try offs.append(gpa, @intCast(post.items.len));

    try sink.pad8();
    const keys_off = sink.pos();
    try sink.append(std.mem.sliceAsBytes(keys.items));
    try sink.pad8();
    const offs_off = sink.pos();
    try sink.append(std.mem.sliceAsBytes(offs.items));
    const post_off = sink.pos();
    try sink.append(post.items);
    try dir.append(gpa, .{
        .n_keys = keys.items.len,
        .keys_off = keys_off,
        .offs_off = offs_off,
        .post_off = post_off,
        .post_len = post.items.len,
    });
}

/// LSD radix sort on bits 32..55 (the trigram), two stable passes of 12 bits.
fn radixByKey(a: []u64, tmp: []u64) void {
    var src = a;
    var dst = tmp;
    inline for (.{ 32, 44 }) |shift| {
        var count: [4097]usize = @splat(0);
        for (src) |v| count[@as(usize, @intCast((v >> shift) & 0xfff)) + 1] += 1;
        for (1..4097) |j| count[j] += count[j - 1];
        for (src) |v| {
            const b: usize = @intCast((v >> shift) & 0xfff);
            dst[count[b]] = v;
            count[b] += 1;
        }
        std.mem.swap([]u64, &src, &dst);
    }
    // Two passes: the result is back in `a`.
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
    var nbuf: [256]u8 = undefined;
    if (needle.len <= nbuf.len) {
        const f = fold.foldInto(&nbuf, needle);
        if (fold.isAscii(f)) return findFoldImpl(.ascii, hay, f, f.len, from);
        return findFoldImpl(.folded, hay, f, f.len, from);
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
    n_folded: usize,
    from: usize,
) ?Span {
    // Each folded character takes at least one byte of `hay`.
    if (hay.len < n_folded or from > hay.len - n_folded) return null;
    var j: usize = 0;
    const first = fold.step(needle, &j);
    const letter = first >= 'a' and first <= 'z';
    const last_start = hay.len - n_folded;
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
            if (matchAt(kind, hay, at, needle, from)) |e| return .{ .start = at, .end = e };
            mask &= mask - 1;
        }
    }
    while (i <= last_start) : (i += 1) {
        const c = hay[i];
        if (std.ascii.toLower(c) != first and !(letter and c >= 0xC3 and c <= 0xC5)) continue;
        if (matchAt(kind, hay, i, needle, from)) |e| return .{ .start = i, .end = e };
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
    return if (findFold(hay, needle, from)) |m| m.start else null;
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
    if (phrase_hit == null) for (words, 0..) |w, i| {
        const h = findFold(text, w, 0) orelse return null;
        if (i == 0) first = h;
    };
    const w0 = if (phrase_hit != null) phrase else words[0];
    const hit = first.?;
    const at = hit.start;
    // The ranking stops caring after `count_cap` hits; so does counting
    // (in a 4 MB book, "the" would otherwise scan the whole text).
    var count: u32 = 0;
    var p = hit;
    while (count < count_cap) {
        count += 1;
        p = findFold(text, w0, p.end) orelse break;
    }
    const line_start = if (std.mem.findScalarLast(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, text, at, '\n') orelse text.len;
    const line_no: u32 = @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
    // Keep the hit visible: start the snippet a little before it.
    const start = if (at - line_start > 60) at - 40 else line_start;
    const raw = std.mem.trim(u8, text[start..@min(line_end, start + 200)], " \t\r");
    return .{
        .count = count,
        .line = line_no,
        .snippet = arena.dupe(u8, validUtf8(raw)) catch "",
        .phrase = phrase_hit != null,
    };
}

fn validUtf8(s: []const u8) []const u8 {
    var lo: usize = 0;
    while (lo < s.len and lo < 4 and s[lo] & 0xc0 == 0x80) lo += 1;
    var end = s.len;
    while (end > lo and !std.unicode.utf8ValidateSlice(s[lo..end])) end -= 1;
    return s[lo..end];
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
    try testing.expectEqual(ix.n_segs + 1, up.n_segs);

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
        try testing.expectEqual(@as(usize, 5), x.n_docs);
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
    try testing.expectEqual(mapped.n_segs, again.n_segs);
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
        try testing.expectEqual(mem.n_docs, cur.n_docs);
        try testing.expectEqualSlices(u8, mem.flags, cur.flags);
        for (0..cur.n_docs) |i| try testing.expectEqualStrings(
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
    try testing.expect(cur.n_segs < mem.n_segs);
    try testing.expect(cur.buf.len > cur.live_bytes);

    // An append whose header never got written (a crash): the file still
    // opens as it was.
    {
        const fd: i32 = @intCast(linux.open(p, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0));
        defer _ = linux.close(fd);
        _ = linux.write(fd, "garbage after the end", 21);
    }
    var reopened = try Index.open(p);
    defer reopened.deinit(gpa);
    try testing.expectEqual(cur.n_docs, reopened.n_docs);
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
    q: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, q, " \t");
    while (it.next()) |w| try words.append(arena, try fold.foldAlloc(arena, w));
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
};

/// For plain documents only (benchmarks, tests).
pub fn plainPath(_: *anyopaque, doc: DocIn, buf: []u8) ?[:0]const u8 {
    if (doc.source != .plain) return null;
    return std.mem.printSentinel(buf, "{s}", .{doc.path}, 0) catch null;
}

/// A candidate in verification order: by `bound`, the most its score can
/// be once its text is read.
const Cand = struct { doc: u32, bound: i32, maybe_phrase: bool };

/// Verification shared by the pool's threads: each takes the next candidate
/// (no batches, so nobody waits for the slowest file of a batch) until the
/// next one's bound cannot beat the `limit`-th match so far.
const VerifyCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ix: *const Index,
    words: []const []const u8,
    phrase: []const u8,
    cands: []const Cand,
    text_path: PathFn,
    text_ctx: *anyopaque,
    arenas: []std.heap.ArenaAllocator,
    now: i64,
    next: std.atomic.Value(usize) = .init(0),
    /// The worst score among the best `top.len`, once there are that many.
    floor: std.atomic.Value(i32) = .init(std.math.minInt(i32)),
    /// Under `lock`: the best matches so far, snippets in `arena`.
    lock: std.Io.Mutex = .init,
    top: []Match,
    n_top: usize = 0,
    arena: std.mem.Allocator,
    oom: std.atomic.Value(bool) = .init(false),

    fn offer(ctx: *VerifyCtx, m: Match) void {
        ctx.lock.lockUncancelable(ctx.io);
        defer ctx.lock.unlock(ctx.io);
        var slot = ctx.n_top;
        if (ctx.n_top == ctx.top.len) {
            slot = worst(ctx.top);
            if (!better(m, ctx.top[slot])) return;
        }
        var copy = m;
        copy.snippet = ctx.arena.dupe(u8, m.snippet) catch {
            ctx.oom.store(true, .release);
            return;
        };
        ctx.top[slot] = copy;
        if (ctx.n_top < ctx.top.len) ctx.n_top += 1;
        if (ctx.n_top == ctx.top.len) ctx.floor.store(ctx.top[worst(ctx.top)].score, .release);
    }
};

/// Ranking order: score, then doc id.
fn better(x: Match, y: Match) bool {
    return x.score > y.score or (x.score == y.score and x.doc < y.doc);
}

fn worst(ms: []const Match) usize {
    var w: usize = 0;
    for (ms[1..], 1..) |m, i| if (better(ms[w], m)) {
        w = i;
    };
    return w;
}

fn verifyTask(ctx: *VerifyCtx, t: usize) void {
    var pbuf: [4096]u8 = undefined;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    const a = ctx.arenas[t].allocator();
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.cands.len) return;
        const cand = ctx.cands[i];
        // Candidates come by bound: none after this one can enter either.
        if (cand.bound < ctx.floor.load(.acquire)) {
            ctx.next.store(ctx.cands.len, .monotonic);
            return;
        }
        defer _ = ctx.arenas[t].reset(.retain_capacity);
        const doc = cand.doc;
        const d = ctx.ix.docIn(doc);
        const p = ctx.text_path(ctx.text_ctx, d, &pbuf) orelse continue;
        // Plain files (1 MB at most) are read into a reused buffer: cheaper
        // than map + unmap, whose TLB shootdown hits every core of a
        // 24-thread process. Extracted texts run to megabytes and usually
        // match early, so those are mapped and only touched where scanned.
        var mapped: ?[]align(8) u8 = null;
        defer if (mapped) |m| {
            _ = linux.munmap(m.ptr, m.len);
        };
        const text: []const u8 = if (d.source == .plain) blk: {
            // Out of memory: this candidate is left out of the results.
            if (!(readPlain(ctx.gpa, p, &buf) catch false)) continue;
            break :blk buf.items;
        } else blk: {
            mapped = sys.mapPrivate(p) catch continue;
            break :blk mapped.?;
        };
        const v = verify(text, ctx.words, ctx.phrase, cand.maybe_phrase, a) orelse continue;
        const phrase_bonus: i32 = if (v.phrase) phrase_max else 0;
        ctx.offer(.{
            .doc = doc,
            .count = v.count,
            .line = v.line,
            .snippet = v.snippet,
            .score = rank(d, v.count, ctx.words, ctx.now) + phrase_bonus,
        });
    }
}

/// Hits counted per document; more do not change the ranking.
pub const count_cap = 10;
/// Most of the hit count's weight in the final score.
const count_max: i32 = count_cap * 20;
/// Bonus when several words appear together, exactly as typed.
const phrase_max: i32 = 250;

/// More hits, a matching file name, recent edits and shallow paths first.
fn rank(d: DocIn, count: u32, words: []const []const u8, now: i64) i32 {
    return @as(i32, @intCast(@min(count, count_cap))) * 20 + staticScore(d, words, now);
}

/// The part of the score known without opening the file.
fn staticScore(d: DocIn, words: []const []const u8, now: i64) i32 {
    var s: i32 = 0;
    const slash = std.mem.findScalarLast(u8, d.path, '/') orelse 0;
    const name = d.path[slash + 1 ..];
    for (words) |w| if (findFold(name, w, 0) != null) {
        s += 150;
    };
    // Saturating: mtimes come from the index file, which may be damaged.
    const age_days = @divTrunc(now -| d.mtime, 86_400);
    s += if (age_days < 1) 300 else if (age_days < 7) 220 else if (age_days < 30) 140 else if (age_days < 180) 60 else if (age_days < 365) 20 else 0;
    s -= @intCast(std.mem.count(u8, d.path, "/") * 5);
    return s;
}

pub const max_candidates = 4000;

/// Full query: candidates from the trigram lists, verified in parallel by
/// reading each file, ranked. Snippets live in `arena`; at most `limit`.
pub fn search(
    ix: *const Index,
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
    for (words) |w| longest = @max(longest, w.len);
    if (longest < 3) return; // nothing a trigram can narrow
    var cands: std.ArrayList(u32) = .empty;
    defer cands.deinit(gpa);
    try ix.candidates(gpa, words, &cands);
    if (cands.items.len == 0) return;
    const now = sys.nowSeconds();

    // Only documents holding every trigram of the whole phrase (spaces
    // included) can get its bonus: the others' bound leaves it out, so they
    // need not be read once enough better matches are in. Too short to
    // have trigrams, the phrase could be anywhere.
    const several = words.len > 1;
    var phrase_docs: std.ArrayList(u32) = .empty;
    defer phrase_docs.deinit(gpa);
    const phrase_known = several and phrase.len >= 3;
    if (phrase_known) try ix.candidates(gpa, &.{phrase}, &phrase_docs);

    // Order candidates by what is known without reading them (recency,
    // depth, name) plus the most reading can add, so verification stops
    // as soon as the next one cannot beat the `limit`-th match.
    const ordered = try gpa.alloc(Cand, cands.items.len);
    defer gpa.free(ordered);
    var pi: usize = 0;
    for (cands.items, ordered) |doc, *o| {
        // Both lists ascend.
        while (pi < phrase_docs.items.len and phrase_docs.items[pi] < doc) pi += 1;
        const maybe_phrase = several and (!phrase_known or (pi < phrase_docs.items.len and phrase_docs.items[pi] == doc));
        const d: DocIn = .{ .path = ix.path(doc), .mtime = ix.mtimes[doc], .size = ix.sizes[doc] };
        o.* = .{
            .doc = doc,
            .maybe_phrase = maybe_phrase,
            .bound = staticScore(d, words, now) + count_max + if (maybe_phrase) phrase_max else 0,
        };
    }
    std.mem.sort(Cand, ordered, {}, struct {
        fn gt(_: void, x: Cand, y: Cand) bool {
            return x.bound > y.bound or (x.bound == y.bound and x.doc < y.doc);
        }
    }.gt);

    const tasks = pool.threads.len + 1;
    const arenas = try gpa.alloc(std.heap.ArenaAllocator, tasks);
    defer {
        for (arenas) |*x| x.deinit();
        gpa.free(arenas);
    }
    for (arenas) |*x| x.* = .init(gpa);
    const top = try gpa.alloc(Match, limit);
    defer gpa.free(top);
    var ctx: VerifyCtx = .{
        .gpa = gpa,
        .io = pool.io,
        .ix = ix,
        .words = words,
        .phrase = phrase,
        .cands = ordered[0..@min(ordered.len, max_candidates)],
        .text_path = text_path,
        .text_ctx = text_ctx,
        .arenas = arenas,
        .now = now,
        .top = top,
        .arena = arena,
    };
    pool.run(@min(tasks, ctx.cands.len), &ctx, verifyTask);
    if (ctx.oom.load(.acquire)) return error.OutOfMemory;
    try out.appendSlice(arena, top[0..ctx.n_top]);
    sortMatches(out.items);
}

fn sortMatches(items: []Match) void {
    std.mem.sort(Match, items, {}, struct {
        fn gt(_: void, x: Match, y: Match) bool {
            return x.score > y.score or (x.score == y.score and x.doc < y.doc);
        }
    }.gt);
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
fn exerciseIndex(ix: *const Index, gpa: std.mem.Allocator) !void {
    const queries = [_][]const []const u8{
        &.{"arena"}, &.{ "zig", "token" }, &.{"lumen config"},
        &.{"élan"},
        &.{"xyzzy"}, &.{ "pos", "ing" },
    };
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    var sum: usize = ix.postingBytes();
    for (queries) |q| {
        try ix.candidates(gpa, q, &got);
        for (got.items) |d| {
            try testing.expect(d < ix.n_docs);
            const src: Source = @fromBackingInt(@intCast(ix.sources[d]));
            sum +%= ix.path(d).len +% @as(
                usize,
                @bitCast(ix.mtimes[d]),
            ) +% ix.sizes[d] +% @backingInt(src);
        }
    }
    for (0..ix.n_docs) |d| sum +%= ix.path(@intCast(d)).len;
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

    const docs_off = std.mem.readInt(u64, good[32..40], .little);
    const dir_off = std.mem.readInt(u64, good[40..48], .little);
    const n = ix.n_docs;
    const seg = ix.segs[0];
    const max = std.math.maxInt(u64);
    const Case = struct { at: usize, v: u64, wide: bool = true };
    const cases = [_]Case{
        .{ .at = 0, .v = 0x3130585443_4d554c }, // magic of another version (LUMCTX01)
        .{ .at = 8, .v = max }, // doc count: overflows the layout
        .{ .at = 8, .v = n + 1 }, // count off by one: the arrays shift onto other data
        .{ .at = 8, .v = @as(u64, std.math.maxInt(u32)) + 1 },
        .{ .at = 16, .v = max / 8 }, // segment count
        .{ .at = 16, .v = ix.n_segs + 1 },
        .{ .at = 24, .v = good.len }, // paths blob past the end
        .{ .at = 32, .v = docs_off + 4 }, // misaligned doc table
        .{ .at = 32, .v = good.len + 8 }, // past the end
        .{ .at = 32, .v = 0 }, // over the header
        .{ .at = 40, .v = dir_off + 4 }, // misaligned directory
        .{ .at = 40, .v = good.len - 8 }, // directory past the end
        .{ .at = 48, .v = good.len - 1 }, // total length
        // Segment directory entry.
        .{ .at = dir_off, .v = max }, // n_keys: overflows
        .{ .at = dir_off, .v = seg.n_keys * 100 }, // keys past the end
        .{ .at = dir_off + 8, .v = seg.keys_off + 2 }, // misaligned keys
        .{ .at = dir_off + 8, .v = good.len }, // keys past the end
        .{ .at = dir_off + 16, .v = good.len - 4 }, // offsets past the end
        .{ .at = dir_off + 24, .v = good.len }, // postings past the end
        .{ .at = dir_off + 32, .v = good.len }, // postings longer than the file
        .{ .at = dir_off + 32, .v = 0 }, // offsets beyond the postings
        // A path past the end of the file, an unknown document kind.
        .{ .at = docs_off + n * 16, .v = 0xffff_fff0, .wide = false },
        .{ .at = docs_off + n * 22, .v = 9, .wide = false },
        // Keys out of order (binary search would miss), offsets going back.
        .{ .at = seg.keys_off, .v = 0xffff_ff, .wide = false },
        .{ .at = seg.offs_off + 4, .v = 0xffff_ffff, .wide = false },
    };
    for (cases, 0..) |c, i| {
        @memcpy(bad, good);
        if (c.at == docs_off + n * 22) {
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
    const seg = ix.segs[0];
    const offs = sliceAt(u32, ix.buf, seg.offs_off, seg.n_keys + 1);
    for (offs[1..]) |o| if (o > 0) {
        ix.buf[seg.post_off + o - 1] |= 0x80;
    };
    try exerciseIndex(&ix, gpa);
    // And with garbage postings: ids past the documents never come out.
    @memset(ix.buf[seg.post_off..][0..seg.post_len], 0x7f);
    try exerciseIndex(&ix, gpa);
}

test "random byte flips in a content index never crash" {
    const gpa = testing.allocator;
    var ix = try smallIndex(gpa);
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
            accepted += 1;
        } else |_| {}
    }
    try testing.expect(accepted > 0);
}

/// Smith input for a fuzz test that starts with one `slice()`.
fn corpusEntry(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const e = try gpa.alloc(u8, 4 + bytes.len);
    std.mem.writeInt(u32, e[0..4], @intCast(bytes.len), .little);
    @memcpy(e[4..], bytes);
    return e;
}

fn fuzzParseBytes(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [16384]u8 align(8) = undefined;
    const b = buf[0..smith.slice(&buf)];
    // Often make the header plausible, so the fuzzer reaches the checks
    // behind it.
    if (b.len >= header_len and smith.value(bool)) {
        @memcpy(b[0..8], magic);
        const room = (b.len - header_len) / doc_bytes;
        const n = smith.valueRangeAtMost(u32, 0, @intCast(@min(room, 1000)));
        const paths_len = smith.valueRangeAtMost(u32, 0, @intCast(
            b.len - header_len - n * doc_bytes,
        ));
        const dir_off = align8(header_len + n * doc_bytes + paths_len);
        std.mem.writeInt(u64, b[8..16], n, .little);
        std.mem.writeInt(u64, b[16..24], smith.valueRangeAtMost(u8, 0, 4), .little);
        std.mem.writeInt(u64, b[24..32], paths_len, .little);
        std.mem.writeInt(u64, b[32..40], header_len, .little);
        std.mem.writeInt(u64, b[40..48], dir_off, .little);
        std.mem.writeInt(u64, b[48..56], b.len, .little);
    }
    if (Index.parse(b, false)) |ix| try exerciseIndex(&ix, testing.allocator) else |_| {}
}

test "fuzz: parsing arbitrary bytes as a content index never crashes" {
    const gpa = testing.allocator;
    var ix = try smallIndex(gpa);
    defer ix.deinit(gpa);
    const seed = try corpusEntry(gpa, ix.buf);
    defer gpa.free(seed);
    try testing.fuzz({}, fuzzParseBytes, .{ .corpus = &.{seed} });
}

fn fuzzFlips(good: []const u8, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
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
    if (Index.parse(buf[0..cut], false)) |ix| try exerciseIndex(&ix, gpa) else |_| {}
}

test "fuzz: a real content index with random damage never crashes" {
    const gpa = testing.allocator;
    var ix = try smallIndex(gpa);
    defer ix.deinit(gpa);
    try testing.fuzz(@as([]const u8, ix.buf), fuzzFlips, .{});
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
