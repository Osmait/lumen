//! Cascaded fuzzy search over the index.
//!
//! Measured in the Rust version over 941k entries, worst query "ca":
//!   mask only ........ 0.12 ms
//!   mask + cheap ..... 1.70 ms
//!   mask + nucleo ... 16.80 ms
//! so each layer filters what the next could not afford:
//!
//!   1. Incremental refinement: "carg" -> "cargo" only rescans the hits of
//!      "carg" (a longer query matches a subset).
//!   2. Mask prefilter: one AND rejects names missing a query character.
//!   3. Cheap score: one greedy pass, keeping a top-K per chunk.
//!   4. Fine score (`fine.zig`, fzf-style alignment) over the finalists only.
//!   + Recency: mtime of the head of the list breaks ties among equals.

const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Pool = @import("Pool.zig");
const fine = @import("fine.zig");
const sys = @import("sys.zig");
const fold = @import("core").fold;

const chunk = 8192;
/// Floor of candidates kept per chunk, in multiples of `limit`: keeping
/// `limit` per chunk guarantees the global top-`limit` by cheap score is
/// never lost (an item in the global top-`limit` is beaten by at most
/// `limit-1` others, so it is in its own chunk's top-`limit`).
const per_chunk_mul = 1;
/// Finalists that reach the fine scorer, in multiples of `limit`. The Rust
/// version measured 100% recall with 16 on its author's disk; `zig build
/// perf` (1M synthetic names built from 24 words, full of near-ties) found
/// "hndlr" at 3/20 with 16, 8/20 with 32 and 20/20 with 64, for ~0.3 ms
/// more per query. Near-ties are where cheap and fine scores disagree most.
const finalist_mul = 64;
/// Recency `stat` cap, in multiples of `limit`.
const recency_mul = 16;
/// Candidate sets larger than this are not cached for refinement.
const cache_max = 100_000;
/// Ceiling of the recency bonus; bounds how many results need a `stat`.
pub const recency_max = 300;
/// Longest query, in bytes once spaces are dropped: the longest file name.
pub const max_query = 255;

pub const Hit = struct { id: u32, score: i32 };

pub const Options = struct {
    /// Hits wanted, best first.
    limit: usize,
    /// Recent files rank higher (costs a statx per finalist).
    recency: bool = true,
};

const Pair = struct {
    score: i32,
    id: u32,

    /// Higher score first, then lower id: a total order, so results are
    /// deterministic.
    fn better(a: Pair, b: Pair) bool {
        return a.score > b.score or (a.score == b.score and a.id < b.id);
    }
};

/// Stateful: remembers the previous query's candidates to refine them.
/// One query's refinement cache. Not thread-safe: the owner serializes
/// searches (Service holds its lock).
pub const Engine = struct {
    pub const empty: Engine = .{};

    last_query: std.ArrayList(u8) = .empty,
    last_candidates: std.ArrayList(u32) = .empty,
    cache_valid: bool = false,

    pub fn deinit(e: *Engine, gpa: std.mem.Allocator) void {
        e.last_query.deinit(gpa);
        e.last_candidates.deinit(gpa);
        e.* = undefined;
    }

    pub fn reset(e: *Engine) void {
        e.last_query.clearRetainingCapacity();
        e.last_candidates.clearRetainingCapacity();
        e.cache_valid = false;
    }

    /// Top `limit` hits for `query`, appended to `out` (cleared first).
    pub fn search(e: *Engine, gpa: std.mem.Allocator, pool: *Pool, store: *const Store, query_in: []const u8, opts: Options, out: *std.ArrayList(Hit)) std.mem.Allocator.Error!void {
        const limit = opts.limit;
        out.clearRetainingCapacity();
        var packed_buf: [max_query]u8 = undefined;
        const query = packQuery(query_in, &packed_buf);
        if (query.len == 0 or limit == 0 or store.len() == 0) {
            e.reset();
            return;
        }
        // Everything below compares folded bytes: "Español" -> "espanol".
        var qbuf: [max_query]u8 = undefined;
        const ql = fold.foldInto(&qbuf, query);
        const qmask = store_mod.charMask(ql);
        // With 1-2 letters almost everything matches: caching half a million
        // ids would not speed anything up.
        const cacheable = ql.len > 2;

        // On folded queries: "espa" -> "españ" refines ("espan" extends
        // "espa"), and so does "Carg" -> "cargo".
        const refine = e.cache_valid and e.last_query.items.len > 0 and
            ql.len > e.last_query.items.len and std.mem.startsWith(u8, ql, e.last_query.items);

        const keep = limit * finalist_mul;
        const source_len: usize = if (refine) e.last_candidates.items.len else store.len();
        // Fewer chunks when refining: split the finalist budget among them,
        // or the incremental case runs short of finalists (recall fell to
        // 52% with a fixed K in the Rust version).
        const n_chunks = @max(std.math.divCeil(usize, source_len, chunk) catch 1, 1);
        const per_chunk = @max(limit * per_chunk_mul, std.math.divCeil(usize, keep, n_chunks) catch keep);

        const partials = try gpa.alloc(Partial, n_chunks);
        defer {
            for (partials) |*p| p.deinit(gpa);
            gpa.free(partials);
        }
        for (partials) |*p| p.* = .{};
        var ctx: SiftCtx = .{
            .gpa = gpa,
            .store = store,
            .ids = if (refine) e.last_candidates.items else null,
            .source_len = source_len,
            .qmask = qmask,
            .q = ql,
            .per_chunk = per_chunk,
            .cache_cap = if (cacheable) cache_max else 0,
            .partials = partials,
        };
        pool.run(n_chunks, &ctx, siftChunk);

        // Merge the per-chunk tops and keep the finalists.
        var finalists: std.ArrayList(Pair) = .empty;
        defer finalists.deinit(gpa);
        var cands: std.ArrayList(u32) = .empty;
        defer cands.deinit(gpa);
        var overflow = false;
        for (partials) |*p| {
            try finalists.appendSlice(gpa, p.top.items);
            overflow = overflow or p.overflow;
        }
        if (cacheable and !overflow) {
            for (partials) |*p| try cands.appendSlice(gpa, p.cands.items);
        }
        if (finalists.items.len > keep) {
            selectTop(finalists.items, keep);
            finalists.shrinkRetainingCapacity(keep);
        }

        // Layer 4: the fine scorer ranks, with no volume pressure left. In
        // blocks on the pool: the UI's 60 results make 3840 finalists, ~1.2
        // ms on one core.
        var hits: std.ArrayList(Pair) = .empty;
        defer hits.deinit(gpa);
        try hits.resize(gpa, finalists.items.len);
        var fctx: FineCtx = .{ .store = store, .q = ql, .in = finalists.items, .out = hits.items };
        pool.run(std.math.divCeil(usize, finalists.items.len, fine_block) catch 1, &fctx, FineCtx.block);
        std.mem.sort(Pair, hits.items, {}, lessThan);

        // Without this the thousands of "Cargo.toml" tie and their order is
        // arbitrary; the mtime decides which one you meant. A stat costs ~1 us
        // so only the head is checked: with the bonus capped at
        // `recency_max`, nothing below `cut - recency_max` can climb into the
        // top `limit`. The cut comes from position `limit`, not further down.
        if (opts.recency and hits.items.len > 0) {
            const cut = hits.items[@min(limit, hits.items.len) - 1].score;
            const floor = cut -| recency_max;
            var n: usize = 0;
            while (n < hits.items.len and hits.items[n].score >= floor) n += 1;
            n = @min(n, limit * recency_mul);
            // Up to 960 path rebuilds and stats for the UI's 60: on the pool.
            var rctx: RecencyCtx = .{ .store = store, .hits = hits.items[0..n], .now = sys.nowSeconds() };
            pool.run(std.math.divCeil(usize, n, recency_block) catch 1, &rctx, RecencyCtx.block);
            std.mem.sort(Pair, hits.items[0..n], {}, lessThan);
        }

        const take = @min(limit, hits.items.len);
        try out.ensureTotalCapacity(gpa, take);
        for (hits.items[0..take]) |h| out.appendAssumeCapacity(.{ .id = h.id, .score = h.score });

        if (cacheable and !overflow and cands.items.len <= cache_max) {
            e.last_query.clearRetainingCapacity();
            try e.last_query.appendSlice(gpa, ql);
            e.last_candidates.clearRetainingCapacity();
            try e.last_candidates.appendSlice(gpa, cands.items);
            e.cache_valid = true;
        } else e.cache_valid = false;
    }
};

/// Spaces separate words but are not part of what is matched: "cargo toml"
/// becomes "cargotoml", a subsequence of "Cargo.toml" (the Rust version
/// matched the space literally, so multi-word queries found nothing).
/// Longer than `max_query`: nothing (no name can match it).
fn packQuery(q: []const u8, buf: *[max_query]u8) []const u8 {
    var n: usize = 0;
    for (q) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (n == buf.len) return buf[0..0];
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

fn lessThan(_: void, a: Pair, b: Pair) bool {
    return Pair.better(a, b);
}

const Partial = struct {
    top: std.ArrayList(Pair) = .empty,
    cands: std.ArrayList(u32) = .empty,
    overflow: bool = false,

    fn deinit(p: *Partial, gpa: std.mem.Allocator) void {
        p.top.deinit(gpa);
        p.cands.deinit(gpa);
    }
};

const SiftCtx = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    /// Candidate ids when refining; null = every entry.
    ids: ?[]const u32,
    source_len: usize,
    qmask: u64,
    q: []const u8,
    per_chunk: usize,
    cache_cap: usize,
    partials: []Partial,
};

fn siftChunk(ctx: *SiftCtx, ci: usize) void {
    const lo = ci * chunk;
    const hi = @min(lo + chunk, ctx.source_len);
    // Out of memory: the chunk's candidates are incomplete, so they must not
    // be refined on the next keystroke as if they were all of them.
    sift(ctx, ci, lo, hi) catch {
        ctx.partials[ci].overflow = true;
    };
}

/// Layers 2 and 3 over one chunk: mask, cheap score, local top-K. Only what
/// can still fight for the chunk's top-K is pushed (the Rust profile showed
/// unselective queries spending their time pushing entries to throw away
/// 99.98% of them).
fn sift(ctx: *SiftCtx, ci: usize, lo: usize, hi: usize) !void {
    const p = &ctx.partials[ci];
    const masks = ctx.store.masks();
    const k = ctx.per_chunk;
    const compact_at = k * 2;
    try p.top.ensureTotalCapacity(ctx.gpa, compact_at);
    var threshold: i32 = std.math.minInt(i32);

    var idx = lo;
    while (idx < hi) : (idx += 1) {
        const id: u32 = if (ctx.ids) |ids| ids[idx] else @intCast(idx);
        if (masks[id] & ctx.qmask != ctx.qmask) continue;
        const cheap = cheapScoreMasked(ctx.store.name(id), ctx.q, masks[id]) orelse continue;
        const s = adjust(ctx.store, id, cheap);
        // `>=`: on equal scores the id breaks the tie, so an equal can still
        // displace the k-th.
        if (s >= threshold) {
            p.top.appendAssumeCapacity(.{ .score = s, .id = id });
            if (p.top.items.len == compact_at) {
                selectTop(p.top.items, k);
                p.top.shrinkRetainingCapacity(k);
                threshold = worst(p.top.items).score;
            }
        }
        if (ctx.cache_cap > 0) {
            if (p.cands.items.len < ctx.cache_cap) try p.cands.append(ctx.gpa, id) else p.overflow = true;
        }
    }
    if (p.top.items.len > k) {
        selectTop(p.top.items, k);
        p.top.shrinkRetainingCapacity(k);
    }
}

fn worst(items: []const Pair) Pair {
    var w = items[0];
    for (items[1..]) |it| if (Pair.better(w, it)) {
        w = it;
    };
    return w;
}

/// Reorders `items` so its first `k` are the best `k` (in any order):
/// quickselect, linear on average.
fn selectTop(items: []Pair, k: usize) void {
    if (k == 0 or k >= items.len) return;
    var lo: usize = 0;
    var hi: usize = items.len - 1;
    const target = k - 1;
    while (lo < hi) {
        // Median of three as the pivot.
        const mid = lo + (hi - lo) / 2;
        if (Pair.better(items[mid], items[lo])) std.mem.swap(Pair, &items[mid], &items[lo]);
        if (Pair.better(items[hi], items[lo])) std.mem.swap(Pair, &items[hi], &items[lo]);
        if (Pair.better(items[hi], items[mid])) std.mem.swap(Pair, &items[hi], &items[mid]);
        const pivot = items[mid];
        var i = lo;
        var j = hi;
        while (i <= j) {
            while (Pair.better(items[i], pivot)) i += 1;
            while (Pair.better(pivot, items[j])) j -= 1;
            if (i <= j) {
                std.mem.swap(Pair, &items[i], &items[j]);
                i += 1;
                if (j == 0) break;
                j -= 1;
            }
        }
        if (target <= j) hi = j else if (target >= i) lo = i else return;
    }
}

/// One pass over the name: greedy subsequence with bonuses for runs and word
/// boundaries. It does not find the best alignment (the fine layer does);
/// it only has to be cheap and not lose good candidates.
///
/// `q` is folded (`core.fold`); the name is compared folded. Pure ASCII
/// names (nearly all of them) are lowercased on the fly; the first byte
/// >= 0x80 sends the name to a folded copy that keeps the original case
/// for camelCase. Both give the same score on an ASCII name.
pub fn cheapScore(name: []const u8, q: []const u8) ?i32 {
    if (name.len < q.len) return null;
    return cheapCore(.ascii, name, &.{}, q) catch cheapFolded(name, q);
}

/// `cheapScore` with the name's mask from the store: its `mask_non_ascii`
/// says which path to take, so an ASCII name never has its tail checked
/// after the match (measurable on "c", where nearly every name matches at
/// its first letters).
pub fn cheapScoreMasked(name: []const u8, q: []const u8, mask: u64) ?i32 {
    if (name.len < q.len) return null;
    if (mask & store_mod.mask_non_ascii != 0) return cheapFolded(name, q);
    // The same loop as before folding existed. A damaged mapped mask could
    // only score a non-ASCII name as plain bytes: never unsafe.
    return cheapCore(.known_ascii, name, &.{}, q) catch unreachable; // NonAscii comes only from .ascii mode
}

// Out of line: its 2 KB of buffers stay off the hot loop's stack frame.
noinline fn cheapFolded(name: []const u8, q: []const u8) ?i32 {
    var buf: [max_folded]u8 = undefined;
    var upper: [max_folded]bool = undefined;
    const n = fold.foldCase(&buf, &upper, name);
    return cheapCore(.folded, buf[0..n], upper[0..n], q) catch unreachable; // NonAscii comes only from .ascii mode
}

/// Longest name folded for `cheapScore`; a longer non-ASCII name is scored
/// on its first `max_folded` characters (Linux names stop at 255 bytes).
const max_folded = 1024;

const CheapMode = enum {
    /// `name` is the original, known to be ASCII (its mask says so):
    /// lowercased on the fly.
    known_ascii,
    /// Same, but fails on any non-ASCII byte, before or after the match.
    ascii,
    /// `name` is already folded; `upper` says which characters were capitals.
    folded,
};

fn cheapCore(comptime mode: CheapMode, name: []const u8, upper: []const bool, q: []const u8) error{NonAscii}!?i32 {
    const ascii = mode != .folded;
    var qi: usize = 0;
    var s: i32 = 0;
    var prev_hit: usize = std.math.maxInt(usize);
    var first_hit: usize = std.math.maxInt(usize);
    // A `for`, not a `while` over an index: measured 8% faster on "ca"
    // over 1.6M names.
    var seen = name.len;
    for (name, 0..) |raw, i| {
        if (qi == q.len) {
            seen = i;
            break;
        }
        if (mode == .ascii and raw >= 0x80) return error.NonAscii;
        const h = if (ascii) std.ascii.toLower(raw) else raw;
        if (h != q[qi]) continue;
        if (first_hit == std.math.maxInt(usize)) first_hit = i;
        if (prev_hit +% 1 == i) s += 30;
        if (i == 0) {
            s += 45;
        } else {
            const prev = name[i - 1];
            if (prev == '_' or prev == '-' or prev == '.' or prev == ' ' or prev == '/') {
                s += 28;
            } else if (if (ascii)
                std.ascii.isLower(prev) and std.ascii.isUpper(raw)
            else
                std.ascii.isLower(prev) and !upper[i - 1] and upper[i]) s += 22;
        }
        prev_hit = i;
        qi += 1;
    }
    if (qi < q.len) return null;
    // The lengths below are folded lengths: an unseen tail must be ASCII
    // too for the original's to be the same.
    if (mode == .ascii and !fold.isAscii(name[seen..])) return error.NonAscii;
    s -= @as(i32, @intCast(@min(first_hit, 64))) * 2;
    s -= @as(i32, @intCast(name.len / 4));
    // The name IS the query, with or without its extension: people type
    // "readme" for README.md as much as for README.
    const stem_len = std.mem.findScalarLast(u8, name, '.') orelse name.len;
    if (name.len == q.len or (stem_len > 0 and stem_len == q.len)) s += 120;
    return s;
}

/// Metadata adjustments, shared by the cascade and the exhaustive reference
/// (the Rust version learned to keep them in one place the hard way).
fn adjust(store: *const Store, id: u32, cheap: i32) i32 {
    const fl = store.flags()[id];
    var s = cheap;
    if (fl & store_mod.flag_dir != 0) s += 15;
    // Must outweigh the recency bonus: an active cache is touched every day.
    if (fl & store_mod.flag_hidden != 0) s -= recency_max + 60;
    // Twelve levels down is rarely what you were after.
    return s - @as(i32, store.depths()[id]) * 3;
}

/// Coarse on purpose: today vs this month vs old.
const fine_block = 256;
const recency_block = 64;

const FineCtx = struct {
    store: *const Store,
    q: []const u8,
    in: []const Pair,
    out: []Pair,

    fn block(ctx: *FineCtx, b: usize) void {
        const lo = b * fine_block;
        for (ctx.in[lo..@min(lo + fine_block, ctx.in.len)], ctx.out[lo..@min(lo + fine_block, ctx.in.len)]) |f, *h| {
            const fs = fine.score(ctx.store.name(f.id), ctx.q) orelse 0;
            h.* = .{ .score = fs * 4 + f.score, .id = f.id };
        }
    }
};

const RecencyCtx = struct {
    store: *const Store,
    hits: []Pair,
    now: i64,

    fn block(ctx: *RecencyCtx, b: usize) void {
        var buf: [4096]u8 = undefined;
        const lo = b * recency_block;
        for (ctx.hits[lo..@min(lo + recency_block, ctx.hits.len)]) |*h| h.score += recencyBonus(ctx.store, h.id, ctx.now, &buf);
    }
};

fn recencyBonus(store: *const Store, id: u32, now: i64, buf: *[4096]u8) i32 {
    const p = store.path(id, buf[0 .. buf.len - 1]);
    if (p.len == 0) return 0;
    buf[p.len] = 0;
    const mt = sys.mtime(buf[0..p.len :0]) orelse return 0;
    if (mt > now) return recency_max;
    return switch (@divTrunc(now - mt, 86_400)) {
        0 => 300,
        1...6 => 220,
        7...29 => 140,
        30...179 => 60,
        180...364 => 20,
        else => 0,
    };
}

/// Reference: scores every entry with the fine scorer, no cascade, no cuts.
/// Defines the correct answer the cascade's recall is measured against.
pub fn searchExhaustive(gpa: std.mem.Allocator, store: *const Store, query_in: []const u8, limit: usize, out: *std.ArrayList(Hit)) !void {
    out.clearRetainingCapacity();
    var packed_buf: [max_query]u8 = undefined;
    const query = packQuery(query_in, &packed_buf);
    if (query.len == 0) return;
    var qbuf: [max_query]u8 = undefined;
    const ql = fold.foldInto(&qbuf, query);
    const qmask = store_mod.charMask(ql);
    var all: std.ArrayList(Pair) = .empty;
    defer all.deinit(gpa);
    for (store.masks(), 0..) |m, i| {
        if (m & qmask != qmask) continue;
        const id: u32 = @intCast(i);
        const cheap = cheapScoreMasked(store.name(id), ql, m) orelse continue;
        const fs = fine.score(store.name(id), ql) orelse 0;
        try all.append(gpa, .{ .score = fs * 4 + adjust(store, id, cheap), .id = id });
    }
    std.mem.sort(Pair, all.items, {}, lessThan);
    for (all.items[0..@min(limit, all.items.len)]) |h| try out.append(gpa, .{ .id = h.id, .score = h.score });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "selectTop keeps the best k" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var items: [500]Pair = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .score = r.intRangeAtMost(i32, -50, 50), .id = @intCast(i) };
    var sorted = items;
    std.mem.sort(Pair, &sorted, {}, lessThan);
    selectTop(&items, 37);
    std.mem.sort(Pair, items[0..37], {}, lessThan);
    try testing.expectEqualSlices(Pair, sorted[0..37], items[0..37]);
}

fn synthetic(gpa: std.mem.Allocator, n_dirs: usize) !Store {
    var b: store_mod.Builder = .empty;
    const words = [_][]const u8{ "cargo", "config", "main", "readme", "notes", "src", "test", "build", "lib", "index", "photo", "draft", "Configuración", "español", "ÑANDÚ", "über", "AñoNuevo" };
    const exts = [_][]const u8{ ".toml", ".rs", ".md", ".zig", ".json", ".png", "" };
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const root = try b.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    // Level 1 dirs, then files under each: BFS order, parents sorted.
    var dirs: std.ArrayList(u32) = .empty;
    defer dirs.deinit(gpa);
    for (0..n_dirs) |i| {
        var nb: [32]u8 = undefined;
        const nm = try std.fmt.bufPrint(&nb, "{s}{d}", .{ words[r.uintLessThan(usize, words.len)], i });
        try dirs.append(gpa, try b.push(gpa, nm, root, store_mod.flag_dir, 1));
    }
    for (dirs.items) |d| {
        for (0..40) |_| {
            var nb: [48]u8 = undefined;
            const nm = try std.fmt.bufPrint(&nb, "{s}_{s}{s}", .{ words[r.uintLessThan(usize, words.len)], words[r.uintLessThan(usize, words.len)], exts[r.uintLessThan(usize, exts.len)] });
            _ = try b.push(gpa, nm, d, 0, 2);
        }
    }
    return b.finish(gpa);
}

test "cascade matches the exhaustive reference (recall 100%)" {
    const gpa = testing.allocator;
    var s = try synthetic(gpa, 2000); // ~82k entries: several chunks
    defer s.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var e: Engine = .empty;
    defer e.deinit(gpa);
    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(gpa);
    var want: std.ArrayList(Hit) = .empty;
    defer want.deinit(gpa);

    // Typed letter by letter, so refinement is exercised too.
    const queries = [_][]const u8{ "c", "ca", "car", "carg", "cargo", "cargo.t", "m", "mai", "main.rs", "rdm", "cfg", "photo_d", "zz", "photo draft", "cargo toml" } ++
        // Accents and case, both ways, typed letter by letter.
        [_][]const u8{ "e", "es", "esp", "espa", "españ", "español", "espanol_", "configuracion", "CONFIGURACIÓN", "configuración.md", "nandu", "Ñandú", "uber", "an", "anonuevo", "ÜBER_ÑAN" };
    for (queries) |q| {
        try e.search(gpa, pool, &s, q, .{ .limit = 20, .recency = false }, &got);
        try searchExhaustive(gpa, &s, q, 20, &want);
        try testing.expectEqual(want.items.len, got.items.len);
        for (want.items, got.items) |w, g| try testing.expectEqual(w.score, g.score);
    }
}

fn smallStore(gpa: std.mem.Allocator, names: []const []const u8) !Store {
    var b: store_mod.Builder = .empty;
    const root = try b.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    for (names) |n| _ = try b.push(gpa, n, root, 0, 1);
    return b.finish(gpa);
}

fn topName(gpa: std.mem.Allocator, pool: *Pool, s: *const Store, q: []const u8) ![]const u8 {
    var e: Engine = .empty;
    defer e.deinit(gpa);
    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(gpa);
    try e.search(gpa, pool, s, q, .{ .limit = 10, .recency = false }, &got);
    if (got.items.len == 0) return "";
    return s.name(got.items[0].id);
}

test "accents and case fold both ways in name search" {
    const gpa = testing.allocator;
    var s = try smallStore(gpa, &.{ "notes.md", "espanol.txt", "configuration.txt", "Configuración.md", "español-viejo.txt", "Ñandú.png", "config.toml", "3×4.md", "x.md" });
    defer s.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    try testing.expectEqualStrings("espanol.txt", try topName(gpa, pool, &s, "español"));
    try testing.expectEqualStrings("espanol.txt", try topName(gpa, pool, &s, "ESPANOL"));
    try testing.expectEqualStrings("español-viejo.txt", try topName(gpa, pool, &s, "espanol viejo"));
    try testing.expectEqualStrings("Configuración.md", try topName(gpa, pool, &s, "configuracion"));
    try testing.expectEqualStrings("Configuración.md", try topName(gpa, pool, &s, "CONFIGURACIÓN"));
    try testing.expectEqualStrings("Ñandú.png", try topName(gpa, pool, &s, "nandu"));
    // A symbol is not a letter: "×" is not an "x".
    try testing.expectEqualStrings("x.md", try topName(gpa, pool, &s, "x"));
    try testing.expectEqualStrings("3×4.md", try topName(gpa, pool, &s, "3×4"));
    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(gpa);
    try searchExhaustive(gpa, &s, "x", 10, &got);
    for (got.items) |h| try testing.expect(!std.mem.eql(u8, s.name(h.id), "3×4.md"));
    try searchExhaustive(gpa, &s, "×", 10, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqualStrings("3×4.md", s.name(got.items[0].id));
}

test "cheap score: an ASCII name scores the same down both paths" {
    const names = [_][]const u8{ "Cargo.toml", "fileManager.rs", "README", "my_report.md", "a.b-c d/e" };
    const qs = [_][]const u8{ "c", "cargo", "fm", "readme", "mr", "abcde", "zz" };
    for (names) |n| for (qs) |q| {
        var buf: [64]u8 = undefined;
        var up: [64]bool = undefined;
        const len = fold.foldCase(&buf, &up, n);
        try testing.expectEqual(try cheapCore(.ascii, n, &.{}, q), try cheapCore(.folded, buf[0..len], up[0..len], q));
        try testing.expectEqual(cheapScore(n, q), cheapScoreMasked(n, q, store_mod.charMask(n)));
    };
    // Same letters with accents: same score as the unaccented name.
    try testing.expectEqual(cheapScore("ArbolEpico.md", "ae"), cheapScore("ÁrbolÉpico.md", "ae"));
    try testing.expectEqual(cheapScore("configuracion.md", "configuracion"), cheapScore("Configuración.md", "configuracion"));
    // A non-ASCII byte after the match still counts in the folded length.
    try testing.expectEqual(cheapScore("ab-ene", "ab"), cheapScore("ab-eñe", "ab"));
    try testing.expectEqual(cheapScore("ab-eñe", "ab"), cheapScoreMasked("ab-eñe", "ab", store_mod.charMask("ab-eñe")));
}

test "a 100-character name is found and ranked first by its full name" {
    const gpa = testing.allocator;
    const long = "a_rather_long_file_name_that_someone_typed_in_full_to_find_it_again_quickly_2026_final_version_2.txt";
    try testing.expectEqual(@as(usize, 100), long.len);
    var s = try smallStore(gpa, &.{ "notes.md", long ++ ".bak", "x" ++ long, long, "a_rather_long_file_name.txt" });
    defer s.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    try testing.expectEqualStrings(long, try topName(gpa, pool, &s, long));
    var upper: [long.len]u8 = undefined;
    try testing.expectEqualStrings(long, try topName(gpa, pool, &s, std.ascii.upperString(&upper, long)));
    // Longer than any file name: nothing, not a crash.
    try testing.expectEqualStrings("", try topName(gpa, pool, &s, long ++ long ++ long));
}
