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
//!   header | docs (mtime, size, path, kind) | paths | segment directory |
//!   segments: sorted trigram keys, offsets, posting lists (varint deltas)
//!
//! Segments keep the build's memory bounded: pairs (trigram, doc) are
//! collected for a run of documents, radix-sorted, encoded, dropped. Doc ids
//! are global and increase across segments, so a trigram's full list is its
//! lists in segment order.

const std = @import("std");
const linux = std.os.linux;
const Pool = @import("Pool.zig");
const sys = @import("sys.zig");
const fold = @import("core").fold;

/// 02: trigrams of folded text (accents and case, `core.fold`).
const magic = "LUMCTX02";
const header_len = 64;

/// Plain text files above this are not indexed (logs, dumps, data).
pub const max_text = 1 << 20;
/// A segment is closed past this many (trigram, doc) pairs: 128 MB of pairs.
const segment_pairs = 16 << 20;
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
    paths: []const u8,
    segs: []const SegEntry,

    pub fn deinit(ix: *Index, gpa: std.mem.Allocator) void {
        if (ix.mapped) _ = linux.munmap(ix.buf.ptr, ix.buf.len) else gpa.free(ix.buf);
        ix.* = undefined;
    }

    pub fn path(ix: *const Index, doc: u32) []const u8 {
        return ix.paths[ix.path_off[doc]..][0..ix.path_len[doc]];
    }

    /// Checks that `buf` is a well-formed index and wraps it without copying
    /// (`mapped` says how `deinit` releases it).
    ///
    /// The file comes from disk: it may be truncated, from another version or
    /// garbage. Everything later accesses index with is checked here, in
    /// linear passes over the doc table and the segment keys (no posting list
    /// is decoded; the decoders are bounds-safe instead): header offsets in
    /// bounds and aligned, every path inside the paths blob, every source a
    /// known kind, every segment's arrays in bounds, keys strictly ascending
    /// (binary search), offsets non-decreasing and within the postings.
    pub fn parse(buf: []align(8) u8, mapped: bool) error{BadIndex}!Index {
        if (buf.len < header_len or !std.mem.eql(u8, buf[0..8], magic)) return error.BadIndex;
        const rd = struct {
            fn u(b: []const u8, at: usize) u64 {
                return std.mem.readInt(u64, b[at..][0..8], .little);
            }
        }.u;
        const n64 = rd(buf, 8);
        const n_segs64 = rd(buf, 16);
        const paths_len64 = rd(buf, 24);
        const docs_off64 = rd(buf, 32);
        const dir_off64 = rd(buf, 40);
        if (rd(buf, 48) != buf.len) return error.BadIndex;
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
        const paths = buf[o..][0..paths_len];
        for (po, pl) |off, l| if (@as(u64, off) + l > paths_len) return error.BadIndex;
        for (src) |k| if (std.enums.fromInt(Source, k) == null) return error.BadIndex;

        const segs = sliceAt(SegEntry, buf, dir_off, n_segs);
        for (segs) |seg| try checkSegment(buf, seg);

        return .{
            .buf = buf,
            .mapped = mapped,
            .n_docs = n,
            .n_segs = n_segs,
            .mtimes = mt,
            .sizes = sz,
            .path_off = po,
            .path_len = pl,
            .sources = src,
            .paths = paths,
            .segs = segs,
        };
    }

    /// Writes the index to `path_z` atomically (see `sys.writeFileAtomic`).
    pub fn save(ix: *const Index, path_z: [:0]const u8) sys.Error!void {
        try sys.writeFileAtomic(path_z, ix.buf);
    }

    pub fn open(path_z: [:0]const u8) !Index {
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
    pub fn candidates(ix: *const Index, gpa: std.mem.Allocator, words: []const []const u8, out: *std.ArrayList(u32)) !void {
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
            try out.appendSlice(gpa, cur.items);
        }
    }

    pub fn postingBytes(ix: *const Index) usize {
        var n: usize = 0;
        for (ix.segs) |s| n += s.post_len;
        return n;
    }
};

/// Bytes per document in the doc table (mtime, size, path_off, path_len,
/// source).
const doc_bytes = 8 + 8 + 4 + 2 + 1;

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
fn intersect(gpa: std.mem.Allocator, a: []const u32, b: []const u8, n_docs: usize, out: *std.ArrayList(u32)) !void {
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

/// Plain text of a file: up to `max_text` bytes, rejected if binary (a NUL in
/// the first 8 KB, git's rule).
pub fn readPlain(gpa: std.mem.Allocator, path: []const u8, buf: *std.ArrayList(u8)) std.mem.Allocator.Error!bool {
    buf.clearRetainingCapacity();
    var zbuf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return false;
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

/// Builds the index of `docs` (their order defines doc ids). `text` gives
/// each document's text; documents it rejects are kept (their path still
/// resolves) but have no postings.
pub fn build(gpa: std.mem.Allocator, pool: *Pool, docs: []const DocIn, text: TextFn, text_ctx: *anyopaque, stats: ?*BuildStats) !Index {
    const t0 = sys.monotonicNs();
    var st: BuildStats = .{};

    // Header, documents and paths first; segments are appended as they close.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendNTimes(gpa, 0, header_len);
    var paths_len: usize = 0;
    for (docs) |d| paths_len += d.path.len;
    const docs_off = out.items.len;
    const n = docs.len;
    try out.appendNTimes(gpa, 0, align8(n * doc_bytes + paths_len));
    {
        var o = docs_off;
        for (docs) |d| {
            std.mem.writeInt(i64, out.items[o..][0..8], d.mtime, .little);
            o += 8;
        }
        for (docs) |d| {
            std.mem.writeInt(u64, out.items[o..][0..8], d.size, .little);
            o += 8;
        }
        var po: u32 = 0;
        for (docs) |d| {
            std.mem.writeInt(u32, out.items[o..][0..4], po, .little);
            po += @intCast(d.path.len);
            o += 4;
        }
        for (docs) |d| {
            std.mem.writeInt(u16, out.items[o..][0..2], @intCast(@min(d.path.len, std.math.maxInt(u16))), .little);
            o += 2;
        }
        for (docs) |d| {
            out.items[o] = @intFromEnum(d.source);
            o += 1;
        }
        for (docs) |d| {
            @memcpy(out.items[o..][0..d.path.len], d.path);
            o += d.path.len;
        }
    }

    var dir: std.ArrayList(SegEntry) = .empty;
    defer dir.deinit(gpa);
    var pairs: std.ArrayList(u64) = .empty;
    defer pairs.deinit(gpa);
    var scratch: std.ArrayList(u64) = .empty;
    defer scratch.deinit(gpa);

    const tasks = pool.threads.len + 1;
    const task_out = try gpa.alloc(std.ArrayList(u64), tasks);
    defer {
        for (task_out) |*t| t.deinit(gpa);
        gpa.free(task_out);
    }
    for (task_out) |*t| t.* = .empty;

    var lo: usize = 0;
    while (lo < n) {
        const hi = @min(lo + batch_docs, n);
        var ctx: ExtractCtx = .{ .gpa = gpa, .docs = docs, .lo = lo, .text = text, .text_ctx = text_ctx, .out = task_out, .tasks = tasks, .batch_hi = hi };
        pool.run(tasks, &ctx, extractTask);
        if (ctx.oom.load(.acquire)) return error.OutOfMemory;
        // Task ranges are contiguous and in order: concatenating keeps pairs
        // in doc order, which the stable radix sort turns into (key, doc).
        for (task_out) |*t| {
            try pairs.appendSlice(gpa, t.items);
            t.clearRetainingCapacity();
        }
        lo = hi;
        if (pairs.items.len >= segment_pairs or lo == n) {
            if (pairs.items.len > 0) {
                st.pairs += pairs.items.len;
                try closeSegment(gpa, &out, &dir, pairs.items, &scratch);
                pairs.clearRetainingCapacity();
            }
        }
    }
    st.segments = dir.items.len;

    // Segment directory, then the header.
    while (out.items.len % 8 != 0) try out.append(gpa, 0);
    const dir_off = out.items.len;
    try out.appendSlice(gpa, std.mem.sliceAsBytes(dir.items));
    const total = out.items.len;
    @memcpy(out.items[0..8], magic);
    std.mem.writeInt(u64, out.items[8..16], n, .little);
    std.mem.writeInt(u64, out.items[16..24], dir.items.len, .little);
    std.mem.writeInt(u64, out.items[24..32], paths_len, .little);
    std.mem.writeInt(u64, out.items[32..40], docs_off, .little);
    std.mem.writeInt(u64, out.items[40..48], dir_off, .little);
    std.mem.writeInt(u64, out.items[48..56], total, .little);

    const buf = try gpa.alignedAlloc(u8, .@"8", total);
    errdefer gpa.free(buf);
    @memcpy(buf, out.items);
    st.docs_indexed = n;
    st.ns = sys.monotonicNs() - t0;
    if (stats) |s| s.* = st;
    return Index.parse(buf, false);
}

/// Sorts a segment's pairs by trigram (stable, so docs stay ascending) and
/// appends keys, offsets and varint-delta lists to `out`.
fn closeSegment(gpa: std.mem.Allocator, out: *std.ArrayList(u8), dir: *std.ArrayList(SegEntry), pairs: []u64, scratch: *std.ArrayList(u64)) !void {
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

    while (out.items.len % 8 != 0) try out.append(gpa, 0);
    const keys_off = out.items.len;
    try out.appendSlice(gpa, std.mem.sliceAsBytes(keys.items));
    while (out.items.len % 8 != 0) try out.append(gpa, 0);
    const offs_off = out.items.len;
    try out.appendSlice(gpa, std.mem.sliceAsBytes(offs.items));
    const post_off = out.items.len;
    try out.appendSlice(gpa, post.items);
    try dir.append(gpa, .{ .n_keys = keys.items.len, .keys_off = keys_off, .offs_off = offs_off, .post_off = post_off, .post_len = post.items.len });
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

fn findFoldImpl(comptime kind: NeedleKind, hay: []const u8, needle: []const u8, n_folded: usize, from: usize) ?Span {
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
inline fn matchAt(comptime kind: NeedleKind, hay: []const u8, at: usize, needle: []const u8, from: usize) ?usize {
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
    const at = std.mem.indexOf(u8, folded.items, fneedle) orelse return null;
    return .{ .start = origin.items[at], .end = origin.items[at + fneedle.len] };
}

pub const Verified = struct { count: u32, line: u32, snippet: []const u8, phrase: bool };

/// Checks that `text` holds every word and describes the first hit. With
/// several words, the whole `phrase` (the query as typed) is looked for
/// first: when present, that is the hit shown. Matching is folded
/// (`findFold`); line and snippet come from the original text.
pub fn verify(text: []const u8, words: []const []const u8, phrase: []const u8, arena: std.mem.Allocator) ?Verified {
    if (words.len == 0) return null;
    for (words) |w| if (findFold(text, w, 0) == null) return null;
    const phrase_hit = if (words.len > 1) findFold(text, phrase, 0) else null;
    const w0 = if (phrase_hit != null) phrase else words[0];
    const hit = phrase_hit orelse findFold(text, w0, 0).?;
    const at = hit.start;
    // The ranking stops caring after `count_cap` hits; so does counting
    // (in a 4 MB book, "the" would otherwise scan the whole text).
    var count: u32 = 0;
    var p = hit;
    while (count < count_cap) {
        count += 1;
        p = findFold(text, w0, p.end) orelse break;
    }
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    const line_no: u32 = @intCast(std.mem.count(u8, text[0..at], "\n") + 1);
    // Keep the hit visible: start the snippet a little before it.
    const start = if (at - line_start > 60) at - 40 else line_start;
    const raw = std.mem.trim(u8, text[start..@min(line_end, start + 200)], " \t\r");
    return .{ .count = count, .line = line_no, .snippet = arena.dupe(u8, validUtf8(raw)) catch "", .phrase = phrase_hit != null };
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
    fn text(ctx: *anyopaque, d: DocIn, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
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
    const vocab = [_][]const u8{ "arena", "allocator", "Config", "trigram", "posting", "lumen", "zig", "parser", "token", "Hyprland", "window", "élan" };
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
        try docs.append(gpa, .{ .path = try std.fmt.allocPrint(gpa, "{d}", .{i}), .mtime = 0, .size = 0 });
    }
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var td: TestDocs = .{ .texts = texts.items };
    var ix = try build(gpa, pool, docs.items, TestDocs.text, &td, null);
    defer ix.deinit(gpa);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&pbuf, "{s}/content.idx", .{dir});
    try ix.save(p);
    var mapped = try Index.open(p);
    defer mapped.deinit(gpa);
    try testing.expectEqualStrings("2999", mapped.path(2999));

    const queries = [_][]const []const u8{ &.{"arena"}, &.{"ALLOC"}, &.{ "trigram", "lumen" }, &.{"hyprland window"}, &.{"élan"}, &.{"nothing here"} };
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
            if (all) try testing.expect(std.mem.indexOfScalar(u32, got.items, @intCast(i)) != null);
        }
    }
}

test "verify finds the line and counts hits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "first line\n  const a = ArenaAllocator.init(gpa);\nArenaAllocator again\n";
    const v = verify(text, &.{"arenaallocator"}, "arenaallocator", arena.allocator()).?;
    try testing.expectEqual(@as(u32, 2), v.line);
    try testing.expectEqual(@as(u32, 2), v.count);
    try testing.expectEqualStrings("const a = ArenaAllocator.init(gpa);", v.snippet);
    try testing.expect(verify(text, &.{ "arena", "missing" }, "arena missing", arena.allocator()) == null);
    // The phrase wins over the first word's first occurrence.
    const p = verify("again here\nsee ArenaAllocator again\n", &.{ "arenaallocator", "again" }, "arenaallocator again", arena.allocator()).?;
    try testing.expectEqual(@as(u32, 2), p.line);
    try testing.expect(p.phrase);
}

// ---------------------------------------------------------------- search

/// Words of a query: split on spaces, folded (`core.fold`) into `arena`.
pub fn splitWords(arena: std.mem.Allocator, q: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, q, " \t");
    while (it.next()) |w| try words.append(arena, try fold.foldAlloc(arena, w));
    return words.items;
}

/// The file that holds a document's text: the document itself, or its
/// extracted text in a cache. Verification maps it instead of reading it,
/// so a hit on page 1 of a 4 MB book touches a few pages, not the book.
pub const PathFn = *const fn (ctx: *anyopaque, doc: DocIn, buf: []u8) ?[:0]const u8;

/// For plain documents only (benchmarks, tests).
pub fn plainPath(_: *anyopaque, doc: DocIn, buf: []u8) ?[:0]const u8 {
    if (doc.source != .plain) return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{doc.path}) catch null;
}

const VerifyCtx = struct {
    gpa: std.mem.Allocator,
    ix: *const Index,
    words: []const []const u8,
    phrase: []const u8,
    cands: []const u32,
    text_path: PathFn,
    text_ctx: *anyopaque,
    results: []?Match,
    arenas: []std.heap.ArenaAllocator,
    chunk: usize,
    now: i64,
};

fn verifyTask(ctx: *VerifyCtx, t: usize) void {
    const a = ctx.arenas[t].allocator();
    var pbuf: [4096]u8 = undefined;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    const from = t * ctx.chunk;
    const to = @min(from + ctx.chunk, ctx.cands.len);
    var i = from;
    while (i < to) : (i += 1) {
        const doc = ctx.cands[i];
        const d: DocIn = .{ .path = ctx.ix.path(doc), .mtime = ctx.ix.mtimes[doc], .size = ctx.ix.sizes[doc], .source = @enumFromInt(ctx.ix.sources[doc]) };
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
        const v = verify(text, ctx.words, ctx.phrase, a) orelse continue;
        const phrase_bonus: i32 = if (v.phrase) phrase_max else 0;
        ctx.results[i] = .{ .doc = doc, .count = v.count, .line = v.line, .snippet = v.snippet, .score = rank(d, v.count, ctx.words, ctx.now) + phrase_bonus };
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
pub fn search(ix: *const Index, gpa: std.mem.Allocator, arena: std.mem.Allocator, pool: *Pool, query: []const u8, limit: usize, text_path: PathFn, text_ctx: *anyopaque, out: *std.ArrayList(Match)) !void {
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

    // Order candidates by what is known without reading them (recency,
    // depth, name), so verification can stop early: once `limit` matches
    // are in, a candidate whose static score plus the best possible hit
    // count cannot beat the limit-th is never opened.
    const Cand = struct { doc: u32, static: i32 };
    const ordered = try gpa.alloc(Cand, cands.items.len);
    defer gpa.free(ordered);
    for (cands.items, ordered) |doc, *o| {
        const d: DocIn = .{ .path = ix.path(doc), .mtime = ix.mtimes[doc], .size = ix.sizes[doc] };
        o.* = .{ .doc = doc, .static = staticScore(d, words, now) };
    }
    std.mem.sort(Cand, ordered, {}, struct {
        fn gt(_: void, x: Cand, y: Cand) bool {
            return x.static > y.static or (x.static == y.static and x.doc < y.doc);
        }
    }.gt);
    const n_cands = @min(ordered.len, max_candidates);
    const docs = try gpa.alloc(u32, n_cands);
    defer gpa.free(docs);
    for (ordered[0..n_cands], docs) |o, *d| d.* = o.doc;

    // The most a candidate can still gain once read: hits, and the phrase
    // bonus only when there are several words to form a phrase.
    const best_extra: i32 = count_max + if (words.len > 1) phrase_max else 0;
    const tasks = pool.threads.len + 1;
    const arenas = try gpa.alloc(std.heap.ArenaAllocator, tasks);
    defer {
        for (arenas) |*x| x.deinit();
        gpa.free(arenas);
    }
    for (arenas) |*x| x.* = std.heap.ArenaAllocator.init(gpa);
    const batch = @max(tasks * 16, limit * 2);
    const results = try gpa.alloc(?Match, batch);
    defer gpa.free(results);

    var lo: usize = 0;
    while (lo < n_cands) {
        if (out.items.len >= limit) {
            sortMatches(out.items);
            const floor = out.items[limit - 1].score;
            if (ordered[lo].static + best_extra < floor) break;
        }
        const hi = @min(lo + batch, n_cands);
        const slice = docs[lo..hi];
        @memset(results[0..slice.len], null);
        var ctx: VerifyCtx = .{ .gpa = gpa, .ix = ix, .words = words, .phrase = phrase, .cands = slice, .text_path = text_path, .text_ctx = text_ctx, .results = results[0..slice.len], .arenas = arenas, .chunk = std.math.divCeil(usize, slice.len, tasks) catch slice.len, .now = now };
        pool.run(@min(tasks, slice.len), &ctx, verifyTask);
        for (results[0..slice.len]) |r| if (r) |m| {
            var copy = m;
            copy.snippet = try arena.dupe(u8, m.snippet);
            try out.append(arena, copy);
        };
        for (arenas) |*x| _ = x.reset(.retain_capacity);
        lo = hi;
    }
    sortMatches(out.items);
    out.shrinkRetainingCapacity(@min(out.items.len, limit));
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
    const pieces = [_][]const u8{ "a", "b", "c", "A", "B", " ", "C", "\n", ".", "z", "Z", "á", "Á", "ñ", "Ñ", "×", "\xC3", "\xA1", "n" };
    for (0..150) |_| {
        const want = r.intRangeAtMost(usize, 0, hay.len - 2);
        var n: usize = 0;
        while (n < want) {
            const p = pieces[r.uintLessThan(usize, pieces.len)];
            @memcpy(hay[n .. n + p.len], p);
            n += p.len;
        }
        const needles = [_][]const u8{ "a", "ab", "AbC", "zz", "c\n.", "B C a", "á", "ÁB", "n", "ñ a", "×", "\xA1", "\xC3", "aaaaaaaa", "ÑAN" };
        for (needles) |nd| {
            var from: usize = 0;
            while (from <= n) : (from += 37) {
                try testing.expectEqual(try findFoldNaive(testing.allocator, hay[0..n], nd, from), findFold(hay[0..n], nd, from));
            }
        }
    }
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
    const long_needle = "Á" ** 150 ++ "B";
    const long_hay = "x" ** 40 ++ "a" ** 160 ++ "b" ++ "á" ** 150 ++ "b";
    try testing.expectEqual(try findFoldNaive(testing.allocator, long_hay, long_needle, 0), findFold(long_hay, long_needle, 0));
    try testing.expectEqual(@as(?Span, .{ .start = 50, .end = 201 }), findFold(long_hay, long_needle, 0));
    try testing.expectEqual(@as(?Span, .{ .start = 201, .end = long_hay.len }), findFold(long_hay, long_needle, 51));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "accion", "ACCIÓN", "acción" }) |q| {
        const words = try splitWords(a, q);
        const v = verify(text, words, words[0], a).?;
        try testing.expectEqual(@as(u32, 2), v.line);
        try testing.expectEqualStrings("Una ACCIÓN rápida", v.snippet);
    }
    const v = verify(text, try splitWords(a, "nandu corre"), try fold.foldAlloc(a, "nandu corre"), a).?;
    try testing.expectEqual(@as(u32, 3), v.line);
    try testing.expect(v.phrase);
    // Two hits of different lengths, counted without overlap.
    try testing.expectEqual(@as(u32, 3), verify("acción accion ACCIÓN", &.{"accion"}, "accion", a).?.count);
}

const FileDocs = struct {
    fn text(_: *anyopaque, d: DocIn, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
        return readPlain(gpa, d.path, buf);
    }
};

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
        paths[i] = try std.fmt.allocPrint(gpa, "{s}/doc{d}.txt", .{ dir, i });
        var zb: [4096]u8 = undefined;
        try sys.writeFile(try std.fmt.bufPrintZ(&zb, "{s}", .{paths[i]}), t);
        docs[i] = .{ .path = paths[i], .mtime = 0, .size = t.len };
    }
    defer for (paths) |p| gpa.free(p);
    const pool = try Pool.create(gpa, testing.io, 2);
    defer pool.destroy();
    var dummy: u8 = 0;
    var ix = try build(gpa, pool, &docs, FileDocs.text, &dummy, null);
    defer ix.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
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
        try search(&ix, gpa, arena.allocator(), pool, c.q, 10, plainPath, &dummy, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(c.doc, out.items[0].doc);
        try testing.expectEqual(c.line, out.items[0].line);
        try testing.expectEqualStrings(c.snippet, out.items[0].snippet);
    }
    try search(&ix, gpa, arena.allocator(), pool, "×yz", 10, plainPath, &dummy, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// ------------------------------------------------- corrupt indexes, fuzzing

/// A small real index: 60 documents from a fixed vocabulary.
fn smallIndex(gpa: std.mem.Allocator) !Index {
    const vocab = [_][]const u8{ "arena", "allocator", "Config", "trigram", "posting", "lumen", "zig", "parser", "token", "élan" };
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
        const p = try std.fmt.allocPrint(gpa, "{d}", .{i});
        texts[i] = t.toOwnedSlice(gpa) catch |e| {
            gpa.free(p);
            return e;
        };
        paths[i] = p;
        n_made += 1;
        docs[i] = .{ .path = p, .mtime = @intCast(i), .size = i, .source = if (i % 7 == 0) .extracted else .plain };
    }
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var td: TestDocs = .{ .texts = &texts };
    return build(gpa, pool, &docs, TestDocs.text, &td, null);
}

/// Touches everything a reader of an index may touch: must never crash on
/// an index that `parse` accepted.
fn exerciseIndex(ix: *const Index, gpa: std.mem.Allocator) !void {
    const queries = [_][]const []const u8{ &.{"arena"}, &.{ "zig", "token" }, &.{"lumen config"}, &.{"élan"}, &.{"xyzzy"}, &.{ "pos", "ing" } };
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    var sum: usize = ix.postingBytes();
    for (queries) |q| {
        try ix.candidates(gpa, q, &got);
        for (got.items) |d| {
            try testing.expect(d < ix.n_docs);
            const src: Source = @enumFromInt(ix.sources[d]);
            sum +%= ix.path(d).len +% @as(usize, @bitCast(ix.mtimes[d])) +% ix.sizes[d] +% @intFromEnum(src);
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
    for (0..good.len) |cut| try testing.expectError(error.BadIndex, Index.parse(good[0..cut], false));

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
        // A path past the paths blob, an unknown document kind.
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
    try testing.expectEqual(@as(?u32, null), readVarint(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, &pos));
    pos = 0;
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), readVarint(&.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, &pos));
    try testing.expectEqual(@as(usize, 5), pos);

    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    // Truncated last id: the ids before it survive.
    try decodeAll(gpa, &.{ 3, 4, 0x80 }, 100, &out);
    try testing.expectEqualSlices(u32, &.{ 3, 7 }, out.items);
    // A delta that overflows u32, a zero delta (not increasing), an id past
    // the documents: the list ends there.
    for ([_][]const u8{ &.{ 3, 0xff, 0xff, 0xff, 0xff, 0x0f, 1 }, &.{ 3, 0, 1 }, &.{ 3, 98, 1 } }) |l| {
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
        const paths_len = smith.valueRangeAtMost(u32, 0, @intCast(b.len - header_len - n * doc_bytes));
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
    const w: []const testing.Smith.Weight = &.{ .value(u8, 'a', 20), .value(u8, 'A', 20), .value(u8, 'b', 10), .value(u8, 'B', 10), .value(u8, ' ', 5), .value(u8, '\n', 3), .value(u8, 0xC3, 10), .value(u8, 0xA1, 6), .value(u8, 0x81, 4), .value(u8, 0x97, 2), .value(u8, 0xC5, 2), .rangeAtMost(u8, 0, 255, 1) };
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w: []const testing.Smith.Weight = &.{ .value(u8, 'a', 20), .value(u8, 'b', 10), .value(u8, ' ', 8), .value(u8, '\n', 4), .rangeAtMost(u8, 0x80, 0xff, 1), .rangeAtMost(u8, 0, 255, 1) };
    var text: [600]u8 = undefined;
    var query: [16]u8 = undefined;
    const t = text[0..smith.sliceWeightedBytes(&text, w)];
    const q = query[0..smith.sliceWeightedBytes(&query, w)];
    const words = try splitWords(a, q);
    const phrase = try fold.foldAlloc(a, std.mem.trim(u8, q, " \t"));
    if (verify(t, words, phrase, a)) |v| {
        try testing.expect(std.unicode.utf8ValidateSlice(v.snippet));
        try testing.expect(v.count >= 1 and v.count <= count_cap and v.line >= 1);
    }
}

test "fuzz: verify on arbitrary text and queries" {
    try testing.fuzz({}, fuzzVerify, .{ .corpus = &.{
        "\x0d\x00\x00\x00ab\nxx ab ab b" ++ "\x05\x00\x00\x00ab  b",
    } });
}
