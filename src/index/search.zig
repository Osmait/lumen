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
//!   3. Cheap score (`cheap.zig`, one greedy pass), keeping a top-K per
//!      chunk.
//!   4. Fine score (`fine.zig`, fzf-style alignment) over the finalists only.
//!   + Recency: mtime of the head of the list breaks ties among equals.

const std = @import("std");
const paths = @import("paths.zig");
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Pool = @import("Pool.zig");
const cheap = @import("cheap.zig");
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
const per_chunk_factor = 1;
/// Finalists that reach the fine scorer, in multiples of `limit`. The Rust
/// version measured 100% recall with 16 on its author's disk; `zig build
/// perf` (1M synthetic names built from 24 words, full of near-ties) found
/// "hndlr" at 3/20 with 16, 8/20 with 32 and 20/20 with 64, for ~0.3 ms
/// more per query. Near-ties are where cheap and fine scores disagree most.
const finalist_factor = 64;
/// Recency `stat` cap, in multiples of `limit`.
const recency_factor = 16;
/// Candidate sets larger than this are not cached for refinement.
const cache_entries_max = 100_000;
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
    fn better(pair: Pair, other: Pair) bool {
        return pair.score > other.score or (pair.score == other.score and pair.id < other.id);
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
        query: []const u8,
        options: Options,
        out: *std.ArrayList(Hit),
    ) std.mem.Allocator.Error!void {
        const limit = options.limit;
        out.clearRetainingCapacity();
        var query_packed_buffer: [query_bytes_max]u8 = undefined;
        const query_packed = packQuery(query, &query_packed_buffer);
        if (query_packed.len == 0 or limit == 0 or store.len() == 0) {
            engine.reset();
            return;
        }
        // Everything below compares folded bytes: "Español" -> "espanol".
        var query_folded_buffer: [query_bytes_max]u8 = undefined;
        const query_folded = fold.foldInto(&query_folded_buffer, query_packed);
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
        var fine_context: FineContext = .{
            .store = store,
            .query_folded = query_folded,
            .finalists = finalists.items,
            .hits = hits.items,
        };
        pool.runBlocks(finalists.items.len, fine_block_entries, &fine_context, FineContext.block);
        std.mem.sort(Pair, hits.items, {}, lessThan);

        if (options.recency) byRecency(pool, store, hits.items, limit, options.no_stat);

        const take = @min(limit, hits.items.len);
        try out.ensureTotalCapacity(gpa, take);
        for (hits.items[0..take]) |hit| {
            out.appendAssumeCapacity(.{ .id = hit.id, .score = hit.score });
        }
        assertRanked(out.items, store, limit);

        const candidates_fit = sifted.candidates.items.len <= cache_entries_max;
        if (cacheable and !sifted.overflow and candidates_fit) {
            try engine.remember(gpa, query_folded, sifted.candidates.items);
        } else engine.cache_valid = false;
    }

    /// Keeps `candidates`, the matches of `query_folded`, to refine on the
    /// next keystroke.
    fn remember(
        engine: *Engine,
        gpa: std.mem.Allocator,
        query_folded: []const u8,
        candidates: []const u32,
    ) std.mem.Allocator.Error!void {
        // Invalid until both are in: a failed append must not leave the
        // previous query's flag on a half-written cache.
        engine.cache_valid = false;
        engine.last_query.clearRetainingCapacity();
        try engine.last_query.appendSlice(gpa, query_folded);
        engine.last_candidates.clearRetainingCapacity();
        try engine.last_candidates.appendSlice(gpa, candidates);
        engine.cache_valid = true;
    }

    const SiftOptions = struct {
        /// Hits the search returns; `limit * finalist_factor` finalists are kept.
        limit: usize,
        /// Sift the last query's candidates instead of the whole store.
        refine: bool,
        /// Keep every match as the next keystroke's candidates.
        cacheable: bool,
    };

    const Sifted = struct {
        /// The best `limit * finalist_factor` by cheap score.
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
        const keep = limit * finalist_factor;
        const source_count: usize = if (refine) engine.last_candidates.items.len else store.len();
        // Fewer chunks when refining: split the finalist budget among them,
        // or the incremental case runs short of finalists (recall fell to
        // 52% with a fixed K in the Rust version).
        const chunks_count = @max(std.math.divCeil(usize, source_count, chunk_entries) catch 1, 1);
        const kept_max = @max(
            limit * per_chunk_factor,
            std.math.divCeil(usize, keep, chunks_count) catch keep,
        );
        const partials = try gpa.alloc(Partial, chunks_count);
        defer {
            for (partials) |*partial| partial.deinit(gpa);
            gpa.free(partials);
        }
        for (partials) |*partial| partial.* = .{};
        var context: SiftContext = .{
            .gpa = gpa,
            .store = store,
            .ids = if (refine) engine.last_candidates.items else null,
            .source_count = source_count,
            .query_mask = query_mask,
            .query_folded = query_folded,
            .kept_max = kept_max,
            .candidates_max = if (cacheable) cache_entries_max else 0,
            .partials = partials,
        };
        pool.runBlocks(source_count, chunk_entries, &context, siftChunkCallback);

        var sifted: Sifted = .{};
        errdefer sifted.deinit(gpa);
        for (partials) |*partial| {
            try sifted.finalists.appendSlice(gpa, partial.top.items);
            sifted.overflow = sifted.overflow or partial.overflow;
        }
        if (cacheable and !sifted.overflow) {
            for (partials) |*partial| {
                try sifted.candidates.appendSlice(gpa, partial.candidates.items);
            }
        }
        if (sifted.finalists.items.len > keep) {
            selectTop(sifted.finalists.items, keep);
            sifted.finalists.shrinkRetainingCapacity(keep);
        }
        return sifted;
    }
};

/// Spaces separate words but are not part of what is matched: "cargo toml"
/// becomes "cargotoml", a subsequence of "Cargo.toml" (the Rust version
/// matched the space literally, so multi-word queries found nothing).
/// Longer than `query_bytes_max`: nothing (no name can match it).
fn packQuery(query: []const u8, query_packed: *[query_bytes_max]u8) []const u8 {
    var packed_count: usize = 0;
    for (query) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (packed_count == query_packed.len) return query_packed[0..0];
        query_packed[packed_count] = byte;
        packed_count += 1;
    }
    return query_packed[0..packed_count];
}

/// What `Engine.search` returns: at most `limit` hits of `store`, best
/// first, the recency bonus included (`byRecency` re-sorts the head, and
/// nothing below its cut can climb past it).
fn assertRanked(hits: []const Hit, store: *const Store, limit: usize) void {
    assert(hits.len <= limit);
    for (hits) |hit| assert(hit.id < store.len());
    if (hits.len > 1) {
        for (hits[0 .. hits.len - 1], hits[1..]) |better, worse| {
            assert(better.score >= worse.score);
        }
    }
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

const SiftContext = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    /// Candidate ids when refining; null = every entry.
    ids: ?[]const u32,
    source_count: usize,
    query_mask: u64,
    query_folded: []const u8,
    kept_max: usize,
    candidates_max: usize,
    partials: []Partial,
};

fn siftChunkCallback(context: *SiftContext, start: usize, end: usize) void {
    const chunk_index = start / chunk_entries;
    // Out of memory: the chunk's candidates are incomplete, so they must not
    // be refined on the next keystroke as if they were all of them.
    siftChunk(context, chunk_index, start, end) catch {
        context.partials[chunk_index].overflow = true;
    };
}

/// Layers 2 and 3 over one chunk: mask, cheap score, local top-K. Only what
/// can still fight for the chunk's top-K is pushed (the Rust profile showed
/// unselective queries spending their time pushing entries to throw away
/// 99.98% of them).
fn siftChunk(
    context: *SiftContext,
    chunk_index: usize,
    start: usize,
    end: usize,
) std.mem.Allocator.Error!void {
    const partial = &context.partials[chunk_index];
    const masks = context.store.masks();
    const query_folded = context.query_folded;
    const kept_max = context.kept_max;
    const compact_at = kept_max * 2;
    try partial.top.ensureTotalCapacity(context.gpa, compact_at);
    // Room for the chunk's candidates at once, not grown one by one.
    if (context.candidates_max > 0) {
        const candidates_room = @min(end - start, context.candidates_max);
        try partial.candidates.ensureTotalCapacity(context.gpa, candidates_room);
    }
    var threshold: i32 = std.math.minInt(i32);

    var position = start;
    while (position < end) : (position += 1) {
        const id: u32 = if (context.ids) |ids| ids[position] else @intCast(position);
        if (masks[id] & context.query_mask != context.query_mask) continue;
        const name = context.store.name(id);
        const cheap_score = cheap.scoreMasked(name, query_folded, masks[id]) orelse continue;
        const score = adjust(context.store, id, cheap_score);
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
        if (context.candidates_max > 0) {
            if (partial.candidates.items.len < context.candidates_max) {
                try partial.candidates.append(context.gpa, id);
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

/// Reorders `items` so its first `count` are the best `count` (in any
/// order): quickselect, linear on average.
fn selectTop(items: []Pair, count: usize) void {
    if (count == 0 or count >= items.len) return;
    var lo: usize = 0;
    var hi: usize = items.len - 1;
    const target = count - 1;
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

/// Metadata adjustments, shared by the cascade and the exhaustive reference
/// (the Rust version learned to keep them in one place the hard way).
fn adjust(store: *const Store, id: u32, cheap_score: i32) i32 {
    const entry_flags = store.flags()[id];
    var score = cheap_score;
    if (entry_flags & store_mod.flag_dir != 0) score += metadata_weight.directory;
    if (entry_flags & store_mod.flag_hidden != 0) {
        score -= recency_max + metadata_weight.hidden_beyond_recency;
    }
    return score - @as(i32, store.depths()[id]) * metadata_weight.per_depth;
}

/// Finalists per pool task for the fine scorer and the recency stats.
const fine_block_entries = 256;
const recency_block_entries = 64;

const FineContext = struct {
    store: *const Store,
    query_folded: []const u8,
    finalists: []const Pair,
    hits: []Pair,

    fn block(context: *FineContext, start: usize, end: usize) void {
        for (context.finalists[start..end], context.hits[start..end]) |finalist, *hit| {
            const name = context.store.name(finalist.id);
            const fine_score = fine.score(name, context.query_folded) orelse 0;
            hit.* = .{ .score = fine_score * fine_weight + finalist.score, .id = finalist.id };
        }
    }
};

const RecencyContext = struct {
    store: *const Store,
    hits: []Pair,
    now: i64,
    no_stat: []const []const u8,

    fn block(context: *RecencyContext, start: usize, end: usize) void {
        var path_buffer: paths.Buffer = undefined;
        for (context.hits[start..end]) |*hit| {
            hit.score += recencyBonus(context, hit.id, &path_buffer);
        }
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
    stat_count = @min(stat_count, limit * recency_factor);
    // Up to 960 path rebuilds and stats for the UI's 60: on the pool.
    var recency_context: RecencyContext = .{
        .store = store,
        .hits = hits[0..stat_count],
        .now = sys.nowSeconds(),
        .no_stat = no_stat,
    };
    pool.runBlocks(stat_count, recency_block_entries, &recency_context, RecencyContext.block);
    std.mem.sort(Pair, hits[0..stat_count], {}, lessThan);
}

/// Coarse on purpose: today vs this month vs old.
fn recencyBonus(context: *const RecencyContext, id: u32, path_buffer: *paths.Buffer) i32 {
    const now = context.now;
    const path = context.store.path(id, path_buffer[0 .. path_buffer.len - 1]) orelse return 0;
    if (path.len == 0) return 0;
    for (context.no_stat) |folder| if (paths.isUnder(path, folder)) return 0;
    path_buffer[path.len] = 0;
    const mtime = sys.mtime(path_buffer[0..path.len :0]) orelse return 0;
    // Saturating: an mtime is whatever the file system says.
    return recency.bonus(now -| mtime);
}

/// Reference: scores every entry with the fine scorer, no cascade, no cuts.
/// Defines the correct answer the cascade's recall is measured against.
pub fn searchExhaustive(
    gpa: std.mem.Allocator,
    store: *const Store,
    query: []const u8,
    limit: usize,
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    var query_packed_buffer: [query_bytes_max]u8 = undefined;
    const query_packed = packQuery(query, &query_packed_buffer);
    if (query_packed.len == 0) return;
    var query_folded_buffer: [query_bytes_max]u8 = undefined;
    const query_folded = fold.foldInto(&query_folded_buffer, query_packed);
    const query_mask = store_mod.charMask(query_folded);
    var all: std.ArrayList(Pair) = .empty;
    defer all.deinit(gpa);
    for (store.masks(), 0..) |mask, i| {
        if (mask & query_mask != query_mask) continue;
        const id: u32 = @intCast(i);
        const cheap_score = cheap.scoreMasked(store.name(id), query_folded, mask) orelse continue;
        const fine_score = fine.score(store.name(id), query_folded) orelse 0;
        const score = fine_score * fine_weight + adjust(store, id, cheap_score);
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
    const random = prng.random();
    var items: [500]Pair = undefined;
    for (&items, 0..) |*item, i| item.* = .{
        .score = random.intRangeAtMost(i32, -50, 50),
        .id = @intCast(i),
    };
    var sorted = items;
    std.mem.sort(Pair, &sorted, {}, lessThan);
    selectTop(&items, 37);
    std.mem.sort(Pair, items[0..37], {}, lessThan);
    try testing.expectEqualSlices(Pair, sorted[0..37], items[0..37]);
}

fn synthetic(gpa: std.mem.Allocator, directories_count: usize) !Store {
    var builder: store_mod.Builder = .empty;
    const words = [_][]const u8{
        "cargo", "config", "main", "readme", "notes", "src", "test", "build", "lib", "index", "photo", "draft",
        "Configuración",
        "español",
        "ÑANDÚ",
        "über",
        "AñoNuevo",
    };
    const extensions = [_][]const u8{ ".toml", ".rs", ".md", ".zig", ".json", ".png", "" };
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const root = try builder.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    // Level 1 dirs, then files under each: BFS order, parents sorted.
    var directories: std.ArrayList(u32) = .empty;
    defer directories.deinit(gpa);
    for (0..directories_count) |i| {
        var name_text: [32]u8 = undefined;
        const entry_name = try std.mem.print(&name_text, "{s}{d}", .{
            words[random.uintLessThan(usize, words.len)],
            i,
        });
        try directories.append(gpa, try builder.push(gpa, entry_name, root, store_mod.flag_dir, 1));
    }
    for (directories.items) |directory| {
        for (0..40) |_| {
            var name_text: [48]u8 = undefined;
            const entry_name = try std.mem.print(&name_text, "{s}_{s}{s}", .{
                words[random.uintLessThan(usize, words.len)],
                words[random.uintLessThan(usize, words.len)],
                extensions[random.uintLessThan(usize, extensions.len)],
            });
            _ = try builder.push(gpa, entry_name, directory, 0, 2);
        }
    }
    return builder.finish(gpa);
}

test "cascade matches the exhaustive reference (recall 100%)" {
    const gpa = testing.allocator;
    // About 82k entries: several chunks.
    var store = try synthetic(gpa, 2000);
    defer store.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var engine: Engine = .empty;
    defer engine.deinit(gpa);
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
    for (queries) |query| {
        try engine.search(gpa, pool, &store, query, .{ .limit = 20, .recency = false }, &got);
        try searchExhaustive(gpa, &store, query, 20, &want);
        try testing.expectEqual(want.items.len, got.items.len);
        for (want.items, got.items) |wanted, found| {
            try testing.expectEqual(wanted.score, found.score);
        }
    }
}

fn smallStore(gpa: std.mem.Allocator, names: []const []const u8) !Store {
    var builder: store_mod.Builder = .empty;
    const root = try builder.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    for (names) |name| _ = try builder.push(gpa, name, root, 0, 1);
    return builder.finish(gpa);
}

fn topName(
    gpa: std.mem.Allocator,
    pool: *Pool,
    store: *const Store,
    query: []const u8,
) ![]const u8 {
    var engine: Engine = .empty;
    defer engine.deinit(gpa);
    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(gpa);
    try engine.search(gpa, pool, store, query, .{ .limit = 10, .recency = false }, &got);
    if (got.items.len == 0) return "";
    return store.name(got.items[0].id);
}

test "accents and case fold both ways in name search" {
    const gpa = testing.allocator;
    var store = try smallStore(gpa, &.{
        "notes.md",    "espanol.txt", "configuration.txt",
        "Configuración.md",
        "español-viejo.txt",
        "Ñandú.png",
        "config.toml",
        "3×4.md",
        "x.md",
    });
    defer store.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    try testing.expectEqualStrings("espanol.txt", try topName(gpa, pool, &store, "español"));
    try testing.expectEqualStrings("espanol.txt", try topName(gpa, pool, &store, "ESPANOL"));
    try testing.expectEqualStrings("español-viejo.txt", try topName(
        gpa,
        pool,
        &store,
        "espanol viejo",
    ));
    for ([_][]const u8{ "configuracion", "CONFIGURACIÓN" }) |query| {
        try testing.expectEqualStrings("Configuración.md", try topName(gpa, pool, &store, query));
    }
    try testing.expectEqualStrings("Ñandú.png", try topName(gpa, pool, &store, "nandu"));
    // A symbol is not a letter: "×" is not an "x".
    try testing.expectEqualStrings("x.md", try topName(gpa, pool, &store, "x"));
    try testing.expectEqualStrings("3×4.md", try topName(gpa, pool, &store, "3×4"));
    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(gpa);
    try searchExhaustive(gpa, &store, "x", 10, &got);
    for (got.items) |hit| try testing.expect(!std.mem.eql(u8, store.name(hit.id), "3×4.md"));
    try searchExhaustive(gpa, &store, "×", 10, &got);
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqualStrings("3×4.md", store.name(got.items[0].id));
}

test "a 100-character name is found and ranked first by its full name" {
    const gpa = testing.allocator;
    const long = "a_rather_long_file_name_that_someone_typed_in_full_to_find_it_again_quickly_2026_final_version_2.txt";
    try testing.expectEqual(@as(usize, 100), long.len);
    var store = try smallStore(gpa, &.{
        "notes.md",
        long ++ ".bak",
        "x" ++ long,
        long,
        "a_rather_long_file_name.txt",
    });
    defer store.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    try testing.expectEqualStrings(long, try topName(gpa, pool, &store, long));
    var upper: [long.len]u8 = undefined;
    try testing.expectEqualStrings(long, try topName(
        gpa,
        pool,
        &store,
        std.ascii.upperString(&upper, long),
    ));
    // Longer than any file name: nothing, not a crash.
    try testing.expectEqualStrings("", try topName(gpa, pool, &store, long ++ long ++ long));
}

test "recency: nothing under a slow mount is stat'ed" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try sys.tmpDirAbs(&temporary, &directory_buffer);
    var path_buffer: paths.Buffer = undefined;
    const note_path = try std.mem.printSentinel(
        &path_buffer,
        "{s}/recent_note.txt",
        .{directory},
        0,
    );
    try sys.writeFile(note_path, "x");
    var builder: store_mod.Builder = .empty;
    const root = try builder.push(gpa, directory, store_mod.no_parent, store_mod.flag_dir, 0);
    _ = try builder.push(gpa, "recent_note.txt", root, 0, 1);
    var store = try builder.finish(gpa);
    defer store.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var engine: Engine = .empty;
    defer engine.deinit(gpa);
    var got: std.ArrayList(Hit) = .empty;
    defer got.deinit(gpa);

    try engine.search(gpa, pool, &store, "recent_note", .{ .limit = 5, .recency = false }, &got);
    const plain = got.items[0].score;
    engine.reset();
    try engine.search(gpa, pool, &store, "recent_note", .{ .limit = 5 }, &got);
    try testing.expectEqual(plain + recency_max, got.items[0].score);
    engine.reset();
    const slow = &.{directory};
    try engine.search(gpa, pool, &store, "recent_note", .{ .limit = 5, .no_stat = slow }, &got);
    try testing.expectEqual(plain, got.items[0].score);
}
