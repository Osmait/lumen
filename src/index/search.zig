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
const paths = @import("paths.zig");
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Pool = @import("Pool.zig");
const fine = @import("fine.zig");
const sys = @import("os");
const fold = @import("core").fold;
const recency = @import("recency.zig");

/// Candidates one pool task scores.
const chunk_entries = 8192;
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
/// Shorter queries are not cached: with one or two letters almost every
/// name matches.
const cache_query_bytes_min = 3;
/// Ceiling of the recency bonus; bounds how many results need a `stat`.
pub const recency_max = recency.bonus_max;
/// Longest query, in bytes once spaces are dropped: the longest file name.
pub const query_bytes_max = 255;

comptime {
    // Two limits, not one: the fine scorer's is the smaller, and a query
    // between the two is still searched, ranked by its cheap score alone.
    assert(fine.query_letters_max <= query_bytes_max);
}

pub const Hit = struct { id: u32, score: i32 };

pub const Options = struct {
    /// Hits wanted, best first.
    limit: usize,
    /// Recent files rank higher (costs a statx per finalist).
    recency: bool = true,
    /// Folders whose files get no recency, never stat'ed: mounts that can
    /// hang (`sys.slowMounts`). A search runs on the UI thread with the
    /// index locked, and a stat on an NFS or sshfs mount whose server went
    /// away blocks until it answers.
    no_stat: []const []const u8 = &.{},
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

/// Remembers the previous query's candidates to refine them on the next
/// keystroke. Not thread-safe: the owner serializes searches (Service holds
/// its lock).
pub const Engine = struct {
    pub const empty: Engine = .{};

    last_query: std.ArrayList(u8) = .empty,
    last_candidates: std.ArrayList(u32) = .empty,
    cache_valid: bool = false,

    pub fn deinit(engine: *Engine, gpa: std.mem.Allocator) void {
        engine.last_query.deinit(gpa);
        engine.last_candidates.deinit(gpa);
        engine.* = undefined;
    }

    pub fn reset(engine: *Engine) void {
        engine.last_query.clearRetainingCapacity();
        engine.last_candidates.clearRetainingCapacity();
        engine.cache_valid = false;
    }

    /// Whether `query_folded` only narrows the last query, so that its
    /// candidates are a subset of the cached ones: "espa" -> "españ"
    /// ("espan" extends "espa"), and "Carg" -> "cargo".
    fn refines(engine: *const Engine, query_folded: []const u8) bool {
        if (!engine.cache_valid) return false;
        const last = engine.last_query.items;
        if (last.len == 0) return false;
        if (query_folded.len <= last.len) return false;
        return std.mem.startsWith(u8, query_folded, last);
    }

    /// Top `limit` hits for `query`, appended to `out` (cleared first).
    pub fn search(
        engine: *Engine,
        gpa: std.mem.Allocator,
        pool: *Pool,
        store: *const Store,
        query_in: []const u8,
        opts: Options,
        out: *std.ArrayList(Hit),
    ) std.mem.Allocator.Error!void {
        const limit = opts.limit;
        out.clearRetainingCapacity();
        var packed_buf: [query_bytes_max]u8 = undefined;
        const query = packQuery(query_in, &packed_buf);
        if (query.len == 0 or limit == 0 or store.len() == 0) {
            engine.reset();
            return;
        }
        // Everything below compares folded bytes: "Español" -> "espanol".
        var query_folded_buffer: [query_bytes_max]u8 = undefined;
        const query_folded = fold.foldInto(&query_folded_buffer, query);
        const query_mask = store_mod.charMask(query_folded);
        // With 1-2 letters almost everything matches: caching half a million
        // ids would not speed anything up.
        const cacheable = query_folded.len >= cache_query_bytes_min;

        // On folded queries (see `refines`).
        const refine = engine.refines(query_folded);

        var sifted = try engine.sift(gpa, pool, store, query_folded, query_mask, .{
            .limit = limit,
            .refine = refine,
            .cacheable = cacheable,
        });
        defer sifted.deinit(gpa);
        const finalists = &sifted.finalists;

        // Layer 4: the fine scorer ranks, with no volume pressure left. In
        // blocks on the pool: the UI's 60 results make 3840 finalists, ~1.2
        // ms on one core.
        var hits: std.ArrayList(Pair) = .empty;
        defer hits.deinit(gpa);
        try hits.resize(gpa, finalists.items.len);
        var fine_context: FineCtx = .{
            .store = store,
            .q = query_folded,
            .in = finalists.items,
            .out = hits.items,
        };
        pool.runBlocks(finalists.items.len, fine_block, &fine_context, FineCtx.block);
        std.mem.sort(Pair, hits.items, {}, lessThan);

        if (opts.recency) byRecency(pool, store, hits.items, limit, opts.no_stat);

        const take = @min(limit, hits.items.len);
        try out.ensureTotalCapacity(gpa, take);
        for (hits.items[0..take]) |hit| out.appendAssumeCapacity(.{ .id = hit.id, .score = hit.score });
        // Best first, the recency bonus included: `byRecency` re-sorts the
        // head, and nothing below its cut can climb past it.
        assert(out.items.len <= limit);
        for (out.items) |hit| assert(hit.id < store.len());
        if (out.items.len > 1) {
            for (out.items[0 .. out.items.len - 1], out.items[1..]) |better, worse| {
                assert(better.score >= worse.score);
            }
        }

        if (cacheable and !sifted.overflow and sifted.candidates.items.len <= cache_max) {
            engine.last_query.clearRetainingCapacity();
            try engine.last_query.appendSlice(gpa, query_folded);
            engine.last_candidates.clearRetainingCapacity();
            try engine.last_candidates.appendSlice(gpa, sifted.candidates.items);
            engine.cache_valid = true;
        } else engine.cache_valid = false;
    }

    const SiftOptions = struct {
        /// Hits the search returns; `limit * finalist_mul` finalists are kept.
        limit: usize,
        /// Sift the last query's candidates instead of the whole store.
        refine: bool,
        /// Keep every match as the next keystroke's candidates.
        cacheable: bool,
    };

    const Sifted = struct {
        /// The best `limit * finalist_mul` by cheap score.
        finalists: std.ArrayList(Pair) = .empty,
        /// Every entry that matched, for refining the next keystroke.
        candidates: std.ArrayList(u32) = .empty,
        /// Some chunk ran out of memory: `candidates` is incomplete.
        overflow: bool = false,

        fn deinit(sifted: *Sifted, gpa: std.mem.Allocator) void {
            sifted.finalists.deinit(gpa);
            sifted.candidates.deinit(gpa);
        }
    };

    /// Layers 2 and 3 over the index (or the last query's candidates when
    /// refining), chunk by chunk on the pool, then the chunks' tops merged.
    fn sift(
        engine: *const Engine,
        gpa: std.mem.Allocator,
        pool: *Pool,
        store: *const Store,
        query_folded: []const u8,
        query_mask: u64,
        options: SiftOptions,
    ) std.mem.Allocator.Error!Sifted {
        const limit = options.limit;
        const refine = options.refine;
        const cacheable = options.cacheable;
        const keep = limit * finalist_mul;
        const source_len: usize = if (refine) engine.last_candidates.items.len else store.len();
        // Fewer chunks when refining: split the finalist budget among them,
        // or the incremental case runs short of finalists (recall fell to
        // 52% with a fixed K in the Rust version).
        const n_chunks = @max(std.math.divCeil(usize, source_len, chunk_entries) catch 1, 1);
        const per_chunk = @max(
            limit * per_chunk_mul,
            std.math.divCeil(usize, keep, n_chunks) catch keep,
        );
        const partials = try gpa.alloc(Partial, n_chunks);
        defer {
            for (partials) |*partial| partial.deinit(gpa);
            gpa.free(partials);
        }
        for (partials) |*partial| partial.* = .{};
        var ctx: SiftCtx = .{
            .gpa = gpa,
            .store = store,
            .ids = if (refine) engine.last_candidates.items else null,
            .source_len = source_len,
            .query_mask = query_mask,
            .q = query_folded,
            .per_chunk = per_chunk,
            .cache_cap = if (cacheable) cache_max else 0,
            .partials = partials,
        };
        pool.runBlocks(source_len, chunk_entries, &ctx, siftChunk);

        var out: Sifted = .{};
        errdefer out.deinit(gpa);
        for (partials) |*partial| {
            try out.finalists.appendSlice(gpa, partial.top.items);
            out.overflow = out.overflow or partial.overflow;
        }
        if (cacheable and !out.overflow) {
            for (partials) |*partial| try out.candidates.appendSlice(gpa, partial.candidates.items);
        }
        if (out.finalists.items.len > keep) {
            selectTop(out.finalists.items, keep);
            out.finalists.shrinkRetainingCapacity(keep);
        }
        return out;
    }
};

/// Spaces separate words but are not part of what is matched: "cargo toml"
/// becomes "cargotoml", a subsequence of "Cargo.toml" (the Rust version
/// matched the space literally, so multi-word queries found nothing).
/// Longer than `query_bytes_max`: nothing (no name can match it).
fn packQuery(query: []const u8, buf: *[query_bytes_max]u8) []const u8 {
    var packed_count: usize = 0;
    for (query) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (packed_count == buf.len) return buf[0..0];
        buf[packed_count] = byte;
        packed_count += 1;
    }
    return buf[0..packed_count];
}

fn lessThan(_: void, a: Pair, b: Pair) bool {
    return Pair.better(a, b);
}

const Partial = struct {
    top: std.ArrayList(Pair) = .empty,
    candidates: std.ArrayList(u32) = .empty,
    overflow: bool = false,

    fn deinit(partial: *Partial, gpa: std.mem.Allocator) void {
        partial.top.deinit(gpa);
        partial.candidates.deinit(gpa);
    }
};

const SiftCtx = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    /// Candidate ids when refining; null = every entry.
    ids: ?[]const u32,
    source_len: usize,
    query_mask: u64,
    q: []const u8,
    per_chunk: usize,
    cache_cap: usize,
    partials: []Partial,
};

fn siftChunk(ctx: *SiftCtx, lo: usize, hi: usize) void {
    const chunk_index = lo / chunk_entries;
    // Out of memory: the chunk's candidates are incomplete, so they must not
    // be refined on the next keystroke as if they were all of them.
    sift(ctx, chunk_index, lo, hi) catch {
        ctx.partials[chunk_index].overflow = true;
    };
}

/// Layers 2 and 3 over one chunk: mask, cheap score, local top-K. Only what
/// can still fight for the chunk's top-K is pushed (the Rust profile showed
/// unselective queries spending their time pushing entries to throw away
/// 99.98% of them).
fn sift(ctx: *SiftCtx, chunk_index: usize, lo: usize, hi: usize) !void {
    const partial = &ctx.partials[chunk_index];
    const masks = ctx.store.masks();
    const kept_max = ctx.per_chunk;
    const compact_at = kept_max * 2;
    try partial.top.ensureTotalCapacity(ctx.gpa, compact_at);
    // Room for the chunk's candidates at once, not grown one by one.
    if (ctx.cache_cap > 0) try partial.candidates.ensureTotalCapacity(ctx.gpa, @min(hi - lo, ctx.cache_cap));
    var threshold: i32 = std.math.minInt(i32);

    var idx = lo;
    while (idx < hi) : (idx += 1) {
        const id: u32 = if (ctx.ids) |ids| ids[idx] else @intCast(idx);
        if (masks[id] & ctx.query_mask != ctx.query_mask) continue;
        const cheap = cheapScoreMasked(ctx.store.name(id), ctx.q, masks[id]) orelse continue;
        const score = adjust(ctx.store, id, cheap);
        // `>=`: on equal scores the id breaks the tie, so an equal can still
        // displace the k-th.
        if (score >= threshold) {
            partial.top.appendAssumeCapacity(.{ .score = score, .id = id });
            if (partial.top.items.len == compact_at) {
                selectTop(partial.top.items, kept_max);
                partial.top.shrinkRetainingCapacity(kept_max);
                threshold = worst(partial.top.items).score;
            }
        }
        if (ctx.cache_cap > 0) {
            if (partial.candidates.items.len < ctx.cache_cap) {
                try partial.candidates.append(ctx.gpa, id);
            } else {
                partial.overflow = true;
            }
        }
    }
    if (partial.top.items.len > kept_max) {
        selectTop(partial.top.items, kept_max);
        partial.top.shrinkRetainingCapacity(kept_max);
    }
}

fn worst(items: []const Pair) Pair {
    var result = items[0];
    for (items[1..]) |item| if (Pair.better(result, item)) {
        result = item;
    };
    return result;
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
    return cheapCore(
        .known_ascii,
        name,
        &.{},
        q,
    ) catch unreachable; // NonAscii comes only from .ascii mode
}

// Out of line: its 2 KB of buffers stay off the hot loop's stack frame.
noinline fn cheapFolded(name: []const u8, q: []const u8) ?i32 {
    var buf: [folded_bytes_max]u8 = undefined;
    var upper: [folded_bytes_max]bool = undefined;
    const folded_count = fold.foldCase(&buf, &upper, name);
    return cheapCore(
        .folded,
        buf[0..folded_count],
        upper[0..folded_count],
        q,
    ) catch unreachable; // NonAscii comes only from .ascii mode
}

/// Longest name folded for `cheapScore`; a longer non-ASCII name is scored
/// on its first `folded_bytes_max` characters (Linux names stop at 255 bytes).
const folded_bytes_max = 1024;

/// What each property of a match is worth to the cheap scorer. Together
/// they order the names the fine scorer then looks at.
const cheap_weight = struct {
    /// A matched character right after the previous match.
    const consecutive = 30;
    /// A match on the name's first character.
    const name_start = 45;
    /// A match right after a separator (`isWordSeparator`).
    const word_start = 28;
    /// A match on a camelCase boundary.
    const camel_start = 22;
    /// Taken per byte before the first match, up to `before_first_bytes_max`.
    const before_first_per_byte = 2;
    const before_first_bytes_max = 64;
    /// One point taken per this many bytes of name: shorter names first.
    const name_bytes_per_point = 4;
    /// The name is the query, with or without its extension: people type
    /// "readme" for README.md as much as for README.
    const whole_name = 120;
};

/// Whether a match right after `byte` starts a word. A switch, not a
/// search in a string: it runs once per matched byte of every candidate.
inline fn isWordSeparator(byte: u8) bool {
    return switch (byte) {
        '_', '-', '.', ' ', '/' => true,
        else => false,
    };
}

/// What the entry's metadata adds to its cheap score (`adjust`).
const metadata_weight = struct {
    const directory = 15;
    /// Taken from a hidden entry on top of the whole recency bonus, so that
    /// a cache touched every day still ranks below a plain file.
    const hidden_beyond_recency = 60;
    /// Taken per level of depth: twelve levels down is rarely what you
    /// were after.
    const per_depth = 3;
};

/// The fine score counts this many times the cheap one in the final score.
const fine_weight = 4;

comptime {
    // A hidden entry with the full recency bonus still loses to the same
    // name unhidden and not recent.
    assert(metadata_weight.hidden_beyond_recency > 0);
}

const CheapMode = enum {
    /// `name` is the original, known to be ASCII (its mask says so):
    /// lowercased on the fly.
    known_ascii,
    /// Same, but fails on any non-ASCII byte, before or after the match.
    ascii,
    /// `name` is already folded; `upper` says which characters were capitals.
    folded,
};

fn cheapCore(
    comptime mode: CheapMode,
    name: []const u8,
    upper: []const bool,
    q: []const u8,
) error{NonAscii}!?i32 {
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
        if (mode == .ascii and !std.ascii.isAscii(raw)) return error.NonAscii;
        const h = if (ascii) std.ascii.toLower(raw) else raw;
        if (h != q[qi]) continue;
        if (first_hit == std.math.maxInt(usize)) first_hit = i;
        if (prev_hit +% 1 == i) s += cheap_weight.consecutive;
        if (i == 0) {
            s += cheap_weight.name_start;
        } else {
            const prev = name[i - 1];
            const camel_boundary = if (ascii)
                std.ascii.isLower(prev) and std.ascii.isUpper(raw)
            else
                std.ascii.isLower(prev) and !upper[i - 1] and upper[i];
            if (isWordSeparator(prev)) {
                s += cheap_weight.word_start;
            } else if (camel_boundary) {
                s += cheap_weight.camel_start;
            }
        }
        prev_hit = i;
        qi += 1;
    }
    if (qi < q.len) return null;
    // The lengths below are folded lengths: an unseen tail must be ASCII
    // too for the original's to be the same.
    if (mode == .ascii and !fold.isAscii(name[seen..])) return error.NonAscii;
    const before_first: i32 = @intCast(@min(first_hit, cheap_weight.before_first_bytes_max));
    s -= before_first * cheap_weight.before_first_per_byte;
    s -= @as(i32, @intCast(name.len / cheap_weight.name_bytes_per_point));
    const stem_len = std.mem.findScalarLast(u8, name, '.') orelse name.len;
    if (name.len == q.len or (stem_len > 0 and stem_len == q.len)) s += cheap_weight.whole_name;
    return s;
}

/// Metadata adjustments, shared by the cascade and the exhaustive reference
/// (the Rust version learned to keep them in one place the hard way).
fn adjust(store: *const Store, id: u32, cheap: i32) i32 {
    const entry_flags = store.flags()[id];
    var score = cheap;
    if (entry_flags & store_mod.flag_dir != 0) score += metadata_weight.directory;
    if (entry_flags & store_mod.flag_hidden != 0) score -= recency_max + metadata_weight.hidden_beyond_recency;
    return score - @as(i32, store.depths()[id]) * metadata_weight.per_depth;
}

/// Finalists per pool task for the fine scorer and the recency stats.
const fine_block = 256;
const recency_block = 64;

const FineCtx = struct {
    store: *const Store,
    q: []const u8,
    in: []const Pair,
    out: []Pair,

    fn block(ctx: *FineCtx, lo: usize, hi: usize) void {
        for (ctx.in[lo..hi], ctx.out[lo..hi]) |f, *h| {
            const fs = fine.score(ctx.store.name(f.id), ctx.q) orelse 0;
            h.* = .{ .score = fs * fine_weight + f.score, .id = f.id };
        }
    }
};

const RecencyCtx = struct {
    store: *const Store,
    hits: []Pair,
    now: i64,
    no_stat: []const []const u8,

    fn block(ctx: *RecencyCtx, lo: usize, hi: usize) void {
        var buf: paths.Buffer = undefined;
        for (ctx.hits[lo..hi]) |*h| h.score += recencyBonus(ctx, h.id, &buf);
    }
};

/// Without this the thousands of "Cargo.toml" tie and their order is
/// arbitrary; the mtime decides which one you meant. A stat costs ~1 us so
/// only the head of `hits` (sorted) is checked: with the bonus capped at
/// `recency_max`, nothing below `cut - recency_max` can climb into the top
/// `limit`. The cut comes from position `limit`, not further down.
fn byRecency(
    pool: *Pool,
    store: *const Store,
    hits: []Pair,
    limit: usize,
    no_stat: []const []const u8,
) void {
    if (hits.len == 0) return;
    const cut = hits[@min(limit, hits.len) - 1].score;
    const floor = cut -| recency_max;
    var stat_count: usize = 0;
    while (stat_count < hits.len and hits[stat_count].score >= floor) stat_count += 1;
    stat_count = @min(stat_count, limit * recency_mul);
    // Up to 960 path rebuilds and stats for the UI's 60: on the pool.
    var recency_context: RecencyCtx = .{
        .store = store,
        .hits = hits[0..stat_count],
        .now = sys.nowSeconds(),
        .no_stat = no_stat,
    };
    pool.runBlocks(stat_count, recency_block, &recency_context, RecencyCtx.block);
    std.mem.sort(Pair, hits[0..stat_count], {}, lessThan);
}

/// Whether `path` is folder `dir` or below it ("/a/bc" is not below "/a/b").
pub fn isUnder(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len) return true;
    return path[dir.len] == paths.separator or std.mem.endsWith(u8, dir, paths.separator_str);
}

/// Coarse on purpose: today vs this month vs old.
fn recencyBonus(ctx: *const RecencyCtx, id: u32, buf: *paths.Buffer) i32 {
    const now = ctx.now;
    const path = ctx.store.path(id, buf[0 .. buf.len - 1]) orelse return 0;
    if (path.len == 0) return 0;
    for (ctx.no_stat) |dir| if (isUnder(path, dir)) return 0;
    buf[path.len] = 0;
    const mtime = sys.mtime(buf[0..path.len :0]) orelse return 0;
    // Saturating: an mtime is whatever the file system says.
    return recency.bonus(now -| mtime);
}

/// Reference: scores every entry with the fine scorer, no cascade, no cuts.
/// Defines the correct answer the cascade's recall is measured against.
pub fn searchExhaustive(
    gpa: std.mem.Allocator,
    store: *const Store,
    query_in: []const u8,
    limit: usize,
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    var packed_buf: [query_bytes_max]u8 = undefined;
    const query = packQuery(query_in, &packed_buf);
    if (query.len == 0) return;
    var query_folded_buffer: [query_bytes_max]u8 = undefined;
    const query_folded = fold.foldInto(&query_folded_buffer, query);
    const query_mask = store_mod.charMask(query_folded);
    var all: std.ArrayList(Pair) = .empty;
    defer all.deinit(gpa);
    for (store.masks(), 0..) |mask, i| {
        if (mask & query_mask != query_mask) continue;
        const id: u32 = @intCast(i);
        const cheap = cheapScoreMasked(store.name(id), query_folded, mask) orelse continue;
        const fine_score = fine.score(store.name(id), query_folded) orelse 0;
        const score = fine_score * fine_weight + adjust(store, id, cheap);
        try all.append(gpa, .{ .score = score, .id = id });
    }
    std.mem.sort(Pair, all.items, {}, lessThan);
    for (all.items[0..@min(limit, all.items.len)]) |hit| try out.append(gpa, .{
        .id = hit.id,
        .score = hit.score,
    });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "selectTop keeps the best k" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var items: [500]Pair = undefined;
    for (&items, 0..) |*it, i| it.* = .{
        .score = r.intRangeAtMost(i32, -50, 50),
        .id = @intCast(i),
    };
    var sorted = items;
    std.mem.sort(Pair, &sorted, {}, lessThan);
    selectTop(&items, 37);
    std.mem.sort(Pair, items[0..37], {}, lessThan);
    try testing.expectEqualSlices(Pair, sorted[0..37], items[0..37]);
}

fn synthetic(gpa: std.mem.Allocator, n_dirs: usize) !Store {
    var b: store_mod.Builder = .empty;
    const words = [_][]const u8{
        "cargo", "config", "main", "readme", "notes", "src", "test", "build", "lib", "index", "photo", "draft",
        "Configuración",
        "español",
        "ÑANDÚ",
        "über",
        "AñoNuevo",
    };
    const exts = [_][]const u8{ ".toml", ".rs", ".md", ".zig", ".json", ".png", "" };
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const root = try b.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    // Level 1 dirs, then files under each: BFS order, parents sorted.
    var dirs: std.ArrayList(u32) = .empty;
    defer dirs.deinit(gpa);
    for (0..n_dirs) |i| {
        var nb: [32]u8 = undefined;
        const nm = try std.mem.print(&nb, "{s}{d}", .{
            words[r.uintLessThan(usize, words.len)],
            i,
        });
        try dirs.append(gpa, try b.push(gpa, nm, root, store_mod.flag_dir, 1));
    }
    for (dirs.items) |d| {
        for (0..40) |_| {
            var nb: [48]u8 = undefined;
            const nm = try std.mem.print(&nb, "{s}_{s}{s}", .{
                words[r.uintLessThan(usize, words.len)],
                words[r.uintLessThan(usize, words.len)],
                exts[r.uintLessThan(usize, exts.len)],
            });
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
    const queries = [_][]const u8{
        "c",
        "ca",
        "car",
        "carg",
        "cargo",
        "cargo.t",
        "m",
        "mai",
        "main.rs",
        "rdm",
        "cfg",
        "photo_d",
        "zz",
        "photo draft",
        "cargo toml",
    } ++
        // Accents and case, both ways, typed letter by letter.
        [_][]const u8{
            "e",        "es",            "esp",      "espa",
            "españ",
            "español",
            "espanol_", "configuracion",
            "CONFIGURACIÓN",
            "configuración.md",
            "nandu",
            "Ñandú",
            "uber",     "an",            "anonuevo",
            "ÜBER_ÑAN",
        };
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
    var s = try smallStore(gpa, &.{
        "notes.md",    "espanol.txt", "configuration.txt",
        "Configuración.md",
        "español-viejo.txt",
        "Ñandú.png",
        "config.toml",
        "3×4.md",
        "x.md",
    });
    defer s.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    try testing.expectEqualStrings("espanol.txt", try topName(gpa, pool, &s, "español"));
    try testing.expectEqualStrings("espanol.txt", try topName(gpa, pool, &s, "ESPANOL"));
    try testing.expectEqualStrings("español-viejo.txt", try topName(
        gpa,
        pool,
        &s,
        "espanol viejo",
    ));
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
    const names = [_][]const u8{
        "Cargo.toml",
        "fileManager.rs",
        "README",
        "my_report.md",
        "a.b-c d/e",
    };
    const qs = [_][]const u8{ "c", "cargo", "fm", "readme", "mr", "abcde", "zz" };
    for (names) |n| for (qs) |q| {
        var buf: [64]u8 = undefined;
        var up: [64]bool = undefined;
        const len = fold.foldCase(&buf, &up, n);
        try testing.expectEqual(try cheapCore(.ascii, n, &.{}, q), try cheapCore(
            .folded,
            buf[0..len],
            up[0..len],
            q,
        ));
        try testing.expectEqual(cheapScore(n, q), cheapScoreMasked(n, q, store_mod.charMask(n)));
    };
    // Same letters with accents: same score as the unaccented name.
    try testing.expectEqual(cheapScore("ArbolEpico.md", "ae"), cheapScore("ÁrbolÉpico.md", "ae"));
    try testing.expectEqual(cheapScore("configuracion.md", "configuracion"), cheapScore(
        "Configuración.md",
        "configuracion",
    ));
    // A non-ASCII byte after the match still counts in the folded length.
    try testing.expectEqual(cheapScore("ab-ene", "ab"), cheapScore("ab-eñe", "ab"));
    try testing.expectEqual(cheapScore("ab-eñe", "ab"), cheapScoreMasked(
        "ab-eñe",
        "ab",
        store_mod.charMask("ab-eñe"),
    ));
}

test "a 100-character name is found and ranked first by its full name" {
    const gpa = testing.allocator;
    const long = "a_rather_long_file_name_that_someone_typed_in_full_to_find_it_again_quickly_2026_final_version_2.txt";
    try testing.expectEqual(@as(usize, 100), long.len);
    var s = try smallStore(gpa, &.{
        "notes.md",
        long ++ ".bak",
        "x" ++ long,
        long,
        "a_rather_long_file_name.txt",
    });
    defer s.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    try testing.expectEqualStrings(long, try topName(gpa, pool, &s, long));
    var upper: [long.len]u8 = undefined;
    try testing.expectEqualStrings(long, try topName(
        gpa,
        pool,
        &s,
        std.ascii.upperString(&upper, long),
    ));
    // Longer than any file name: nothing, not a crash.
    try testing.expectEqualStrings("", try topName(gpa, pool, &s, long ++ long ++ long));
}

test "recency: nothing under a slow mount is stat'ed" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: paths.Buffer = undefined;
    const dir = try sys.tmpDirAbs(&tmp, &dbuf);
    var pbuf: paths.Buffer = undefined;
    try sys.writeFile(try std.mem.printSentinel(&pbuf, "{s}/recent_note.txt", .{dir}, 0), "x");
    var b: store_mod.Builder = .empty;
    const root = try b.push(gpa, dir, store_mod.no_parent, store_mod.flag_dir, 0);
    _ = try b.push(gpa, "recent_note.txt", root, 0, 1);
    var s = try b.finish(gpa);
    defer s.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var e: Engine = .empty;
    defer e.deinit(gpa);
    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(gpa);

    try e.search(gpa, pool, &s, "recent_note", .{ .limit = 5, .recency = false }, &got);
    const plain = got.items[0].score;
    e.reset();
    try e.search(gpa, pool, &s, "recent_note", .{ .limit = 5 }, &got);
    try testing.expectEqual(plain + recency_max, got.items[0].score);
    e.reset();
    try e.search(gpa, pool, &s, "recent_note", .{ .limit = 5, .no_stat = &.{dir} }, &got);
    try testing.expectEqual(plain, got.items[0].score);

    try testing.expect(isUnder("/h/u/nfs", "/h/u/nfs"));
    try testing.expect(isUnder("/h/u/nfs/a", "/h/u/nfs"));
    try testing.expect(!isUnder("/h/u/nfs2/a", "/h/u/nfs"));
    try testing.expect(isUnder("/a", "/"));
}
