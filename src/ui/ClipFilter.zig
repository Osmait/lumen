//! The clipboard view's filter: up to 5,000 entries of up to 2,000 bytes.
//! Each entry's text is folded once, at the first query (`core.fuzzy.Text`),
//! not again per keystroke, and a query typed on from the last one is scored
//! only against the entries that one matched: whatever a query matches, the
//! queries it starts with match too. Long queries still took up to ~145 ms
//! over a full history, so the ClipSearch worker scores them off the GTK
//! thread (MYP-613); `run` is the same job wherever it runs.
//!
//! The entries live in a `Corpus`, shared by the view (`Ui.base` points into
//! it) and the worker scoring it: it is reference counted, so an entry
//! deleted, and the view loaded again, while a query is scored frees nothing
//! the worker reads. A corpus never changes once loaded, except for this
//! filter's state, which only the thread scoring it touches: the worker, or
//! the GTK thread when it scores in place (`Corpus.scoredInPlace`), never
//! both for one corpus.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const fuzzy = core.fuzzy;
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const ClipId = @import("../sys/Db.zig").ClipId;

const ClipFilter = @This();

/// Each entry's text folded, by index in the entries; empty until a query.
texts: []fuzzy.Text = &.{},
/// Indices of the entries the last query scored to the end matched,
/// ascending, in `matched[0..matched_len]`.
matched: []u32 = &.{},
matched_len: usize = 0,
/// Where the query being scored puts its matches: they replace `matched`
/// only when it is scored to the end, so a query stopped half way
/// (`Cancel`, out of memory) leaves the last one to narrow from.
matching: []u32 = &.{},
/// The last query scored to the end, as typed and folded; `query_len` 0
/// when there is none to narrow from.
query_buffer: [fuzzy.text_chars_max]u8 = undefined,
query_len: usize = 0,
folded_buffer: [fuzzy.text_chars_max]u8 = undefined,
folded_len: usize = 0,

/// The score of an entry that holds the query past the bytes the filter
/// scores (`Job.beyond`): below any fuzzy match (those start at 0).
pub const beyond_score = -1;

/// Entries scored between two looks at `Cancel`: ~2 ms of the slowest
/// queries over 2,000-byte entries.
const cancel_check_entries = 64;

/// Set from another thread to stop a job early (a newer query came).
pub const Cancel = std.atomic.Value(bool);

/// An entry a query matched, as `run` gives it.
pub const Hit = struct { id: ClipId, score: i32 };

/// An entry matched, by index, while scoring.
const Scored = struct { index: u32, score: i32 };

pub const RunError = error{Canceled} || std.mem.Allocator.Error;

/// A query to score against a corpus.
pub const Job = struct {
    /// As typed (trimmed): not empty.
    query_text: []const u8,
    /// The entries that hold the query past their scored text, sorted
    /// (`orderClipId`): they match with `beyond_score` when they do not
    /// otherwise. One that holds a query must hold each start of it too (a
    /// substring search does).
    beyond: []const ClipId = &.{},
    /// Hits kept at most, the best.
    results_max: usize,
    cancel: ?*const Cancel = null,
};

/// The entries of the clipboard view and what the filter keeps of them.
pub const Corpus = struct {
    gpa: std.mem.Allocator,
    /// The entries' memory, and the filter's.
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(1),
    /// Tells corpora apart: an address can be used again.
    serial: u64,
    items: []Item = &.{},
    /// The bytes of each entry's text that are scored.
    detail_bytes_max: usize = 0,
    /// The bytes all entries have scored: how long a query can take.
    scored_bytes: usize = 0,
    /// Each entry's index in `items`.
    index_of: std.AutoHashMapUnmanaged(ClipId, u32) = .empty,
    /// The scoring thread's alone (see the top of the file).
    filter: ClipFilter = .{},

    var serial_last: std.atomic.Value(u64) = .init(0);

    /// An empty corpus, its one reference the caller's: fill it with
    /// `setItems`, its memory from `allocator`.
    pub fn create(gpa: std.mem.Allocator) std.mem.Allocator.Error!*Corpus {
        const corpus = try gpa.create(Corpus);
        corpus.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .serial = serial_last.fetchAdd(1, .monotonic) + 1,
        };
        return corpus;
    }

    pub fn allocator(corpus: *Corpus) std.mem.Allocator {
        return corpus.arena.allocator();
    }

    /// `items` (in `allocator`'s memory, each with a `.clip` action) are
    /// the entries from now on; `detail_bytes_max` of each is scored.
    pub fn setItems(
        corpus: *Corpus,
        items: []Item,
        detail_bytes_max: usize,
    ) std.mem.Allocator.Error!void {
        assert(corpus.items.len == 0);
        assert(items.len <= std.math.maxInt(u32));
        const arena = corpus.arena.allocator();
        try corpus.index_of.ensureTotalCapacity(arena, @intCast(items.len));
        var scored_bytes: usize = 0;
        for (items, 0..) |item, i| {
            corpus.index_of.putAssumeCapacity(item.action.clip, @intCast(i));
            scored_bytes += scoredText(item, detail_bytes_max).len;
        }
        corpus.items = items;
        corpus.detail_bytes_max = detail_bytes_max;
        corpus.scored_bytes = scored_bytes;
    }

    pub fn retain(corpus: *Corpus) void {
        const refs = corpus.refs.fetchAdd(1, .monotonic);
        assert(refs > 0);
    }

    /// Frees it with the last reference: from any thread.
    pub fn release(corpus: *Corpus) void {
        const refs = corpus.refs.fetchSub(1, .acq_rel);
        assert(refs > 0);
        if (refs > 1) return;
        corpus.arena.deinit();
        corpus.gpa.destroy(corpus);
    }

    /// The entry `id`, if listed.
    pub fn itemOf(corpus: *const Corpus, id: ClipId) ?Item {
        const index = corpus.index_of.get(id) orelse return null;
        return corpus.items[index];
    }
};

/// The text of `item` the filter scores: the head of the entry, up to
/// `detail_bytes_max`, or the title of an item without one.
pub fn scoredText(item: Item, detail_bytes_max: usize) []const u8 {
    if (item.detail.len == 0) return item.title;
    return item.detail[0..@min(item.detail.len, detail_bytes_max)];
}

pub fn orderClipId(wanted: ClipId, id: ClipId) std.math.Order {
    return std.math.order(@backingInt(wanted), @backingInt(id));
}

/// The entries of `corpus` that match `job`, best first (as `sortByScore`
/// orders rows), at most `job.results_max`, in `arena`: what scoring each
/// entry's `scoredText` and subtitle with `fuzzy.scoreFieldsQuery` gives.
/// Called by the corpus's scoring thread only. `error.Canceled` when
/// `job.cancel` was set: the corpus keeps what the last query scored to the
/// end left to narrow from.
pub fn run(corpus: *Corpus, arena: std.mem.Allocator, job: Job) RunError![]Hit {
    assert(job.query_text.len > 0);
    var query_buffer: [fuzzy.text_chars_max]u8 = undefined;
    const query = fuzzy.prepare(&query_buffer, job.query_text);
    var scored: std.ArrayList(Scored) = .empty;
    const narrowed = query.folded.len > 0 and
        try corpus.filter.score(corpus, arena, job, query, &scored);
    // Out of memory for what it keeps, or nothing to score after folding:
    // every entry, the plain way.
    if (!narrowed) {
        scored.clearRetainingCapacity();
        try scorePlain(corpus, arena, job, query, &scored);
    }
    std.mem.sort(Scored, scored.items, @as([]const Item, corpus.items), better);
    const kept = scored.items[0..@min(scored.items.len, job.results_max)];
    const hits = try arena.alloc(Hit, kept.len);
    for (kept, hits) |entry, *hit| {
        hit.* = .{ .id = corpus.items[entry.index].action.clip, .score = entry.score };
    }
    return hits;
}

/// Best first; equal scores by title (`search.sortByScore`'s order).
fn better(items: []const Item, x: Scored, y: Scored) bool {
    if (x.score != y.score) return x.score > y.score;
    return std.mem.order(u8, items[x.index].title, items[y.index].title) == .lt;
}

fn holdsBeyond(job: Job, item: Item) bool {
    if (item.action != .clip) return false;
    return std.sort.binarySearch(ClipId, job.beyond, item.action.clip, orderClipId) != null;
}

fn canceled(job: Job, scored_count: usize) bool {
    if (scored_count % cancel_check_entries != 0) return false;
    const cancel = job.cancel orelse return false;
    return cancel.load(.monotonic);
}

/// Every entry with `fuzzy.scoreFieldsQuery`: as the filter scored before
/// it kept anything. Out of memory, the hits so far.
fn scorePlain(
    corpus: *const Corpus,
    arena: std.mem.Allocator,
    job: Job,
    query: fuzzy.Query,
    scored: *std.ArrayList(Scored),
) error{Canceled}!void {
    for (corpus.items, 0..) |item, i| {
        if (canceled(job, i)) return error.Canceled;
        const fields = [_][]const u8{ scoredText(item, corpus.detail_bytes_max), item.subtitle };
        var item_score = fuzzy.scoreFieldsQuery(query, &fields);
        if (item_score == fuzzy.no_match and holdsBeyond(job, item)) item_score = beyond_score;
        if (item_score == fuzzy.no_match) continue;
        scored.append(arena, .{ .index = @intCast(i), .score = item_score }) catch break;
    }
}

/// Appends to `scored` the entries matching `query` (folded, not empty),
/// in their order, as `scorePlain` does. False when out of memory for what
/// the filter keeps: the caller scores the plain way.
fn score(
    filter: *ClipFilter,
    corpus: *Corpus,
    arena: std.mem.Allocator,
    job: Job,
    query: fuzzy.Query,
    scored: *std.ArrayList(Scored),
) error{Canceled}!bool {
    assert(query.folded.len > 0);
    const items = corpus.items;
    if (filter.texts.len != items.len) {
        filter.fold(corpus) catch {
            filter.* = .{};
            return false;
        };
    }
    assert(filter.texts.len == items.len);
    assert(filter.matched.len == items.len and filter.matching.len == items.len);
    // Typed on from the last query: as typed for `job.beyond`, folded for
    // the scores.
    const narrowing = filter.query_len > 0 and
        std.mem.startsWith(u8, job.query_text, filter.query_buffer[0..filter.query_len]) and
        std.mem.startsWith(u8, query.folded, filter.folded_buffer[0..filter.folded_len]);
    const candidates_count = if (narrowing) filter.matched_len else items.len;
    var kept: usize = 0;
    for (0..candidates_count) |candidate| {
        if (canceled(job, candidate)) return error.Canceled;
        const item_index: usize = if (narrowing) filter.matched[candidate] else candidate;
        const item = items[item_index];
        var item_score = fuzzy.scoreText(query, &filter.texts[item_index]);
        if (item.subtitle.len > 0) {
            // As the second of `scoreFieldsQuery`'s fields.
            const subtitle_score = fuzzy.scoreFieldsQuery(query, &.{ "", item.subtitle });
            item_score = @max(item_score, subtitle_score);
        }
        if (item_score == fuzzy.no_match and holdsBeyond(job, item)) item_score = beyond_score;
        if (item_score == fuzzy.no_match) continue;
        scored.append(arena, .{ .index = @intCast(item_index), .score = item_score }) catch {
            return false;
        };
        filter.matching[kept] = @intCast(item_index);
        kept += 1;
    }
    std.mem.swap([]u32, &filter.matched, &filter.matching);
    filter.matched_len = kept;
    // A query longer than kept is not narrowed from.
    const kept_whole = job.query_text.len <= filter.query_buffer.len;
    filter.query_len = if (kept_whole) job.query_text.len else 0;
    @memcpy(filter.query_buffer[0..filter.query_len], job.query_text[0..filter.query_len]);
    assert(query.folded.len <= filter.folded_buffer.len);
    @memcpy(filter.folded_buffer[0..query.folded.len], query.folded);
    filter.folded_len = query.folded.len;
    return true;
}

fn fold(filter: *ClipFilter, corpus: *Corpus) std.mem.Allocator.Error!void {
    const arena = corpus.arena.allocator();
    const items = corpus.items;
    const texts = try arena.alloc(fuzzy.Text, items.len);
    for (items, texts) |item, *text| {
        text.* = try .init(arena, scoredText(item, corpus.detail_bytes_max));
    }
    filter.* = .{
        .texts = texts,
        .matched = try arena.alloc(u32, items.len),
        .matching = try arena.alloc(u32, items.len),
    };
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

/// What the filter gives, worked out the plain way: every entry scored
/// with `scoreFieldsQuery`, sorted as `search.sortByScore` sorts rows.
pub fn plainHits(
    gpa: std.mem.Allocator,
    items: []const Item,
    detail_bytes_max: usize,
    query_text: []const u8,
    beyond: []const ClipId,
    results_max: usize,
) ![]Hit {
    var query_buffer: [fuzzy.text_chars_max]u8 = undefined;
    const query = fuzzy.prepare(&query_buffer, query_text);
    var matched: std.ArrayList(Item) = .empty;
    defer matched.deinit(gpa);
    for (items) |item| {
        const fields = [_][]const u8{ scoredText(item, detail_bytes_max), item.subtitle };
        var item_score = fuzzy.scoreFieldsQuery(query, &fields);
        const held = std.sort.binarySearch(ClipId, beyond, item.action.clip, orderClipId) != null;
        if (item_score == fuzzy.no_match and held) item_score = beyond_score;
        if (item_score == fuzzy.no_match) continue;
        var copy = item;
        copy.score = item_score;
        try matched.append(gpa, copy);
    }
    std.mem.sort(Item, matched.items, {}, struct {
        fn better(_: void, x: Item, y: Item) bool {
            if (x.score != y.score) return x.score > y.score;
            return std.mem.order(u8, x.title, y.title) == .lt;
        }
    }.better);
    const kept = matched.items[0..@min(matched.items.len, results_max)];
    const hits = try gpa.alloc(Hit, kept.len);
    for (kept, hits) |item, *hit| hit.* = .{ .id = item.action.clip, .score = item.score };
    return hits;
}

pub const test_detail_bytes_max = 40;

/// `count` entries of random words, some with a subtitle, some with no
/// head (their title is scored), and a few titles alike (ties are broken
/// by title, then by order).
pub fn testCorpus(gpa: std.mem.Allocator, count: usize, seed: u64) !*Corpus {
    const corpus = try Corpus.create(gpa);
    errdefer corpus.release();
    const arena = corpus.allocator();
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const words = [_][]const u8{ "Config", "user", "tóken", "request", "zig", "café", "x", "-", "/" };
    const items = try arena.alloc(Item, count);
    for (items, 0..) |*item, i| {
        var text: std.ArrayList(u8) = .empty;
        const words_count = random.uintAtMost(usize, 12);
        for (0..words_count) |_| {
            try text.appendSlice(arena, words[random.uintLessThan(usize, words.len)]);
            try text.append(arena, ' ');
        }
        const id: ClipId = @fromBackingInt(@intCast(i + 1));
        item.* = .{
            .title = if (i % 5 == 0) "same" else try arena.dupeSentinel(u8, text.items[0..@min(text.items.len, 9)], 0),
            .detail = text.items,
            .subtitle = if (i % 7 == 0) "Request" else "",
            .action = .{ .clip = id },
        };
        // Some without a head: their title is scored.
        if (i % 11 == 0) item.* = .{ .title = "user café", .action = .{ .clip = id } };
    }
    try corpus.setItems(items, test_detail_bytes_max);
    return corpus;
}

/// Typed on, typed over, typed back: each a query of its own.
pub const test_typed = [_][]const u8{
    "u",       "us",  "use",     "user", "user ", "user t",  "user to", "user tok",
    "use",     "us",  "R",       "re",   "req",   "reQu",    "requ",    "c",
    "ca",      "caf",
    "café",
    "cafe",    "z",   "zi",      "zx",   "zig c", "nothing", "nothin",  "/",
    "/ z",     "-",   "ct",      "ctr",
    "ü",
    "user tóq",
    "user to", "x",   "\u{301}",
};

pub fn expectHits(want: []const Hit, got: []const Hit) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |want_hit, got_hit| {
        try testing.expectEqual(want_hit.id, got_hit.id);
        try testing.expectEqual(want_hit.score, got_hit.score);
    }
}

test "the clipboard filter matches, scores and orders as scoring every entry does (MYP-613)" {
    const corpus = try testCorpus(testing.allocator, 300, 613);
    defer corpus.release();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const beyond = [_]ClipId{ @fromBackingInt(4), @fromBackingInt(51), @fromBackingInt(300) };
    for ([_]usize{ 1000, 20 }) |results_max| {
        for (test_typed) |typed_query| {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            const job: Job = .{ .query_text = typed_query, .beyond = &beyond, .results_max = results_max };
            const got = try run(corpus, arena, job);
            const want = try plainHits(arena, corpus.items, test_detail_bytes_max, typed_query, &beyond, results_max);
            try expectHits(want, got);
        }
    }
    try testing.expectEqual(@as(usize, 300), corpus.filter.texts.len);
}

test "a query stopped half way leaves the last one to narrow from (MYP-613)" {
    const corpus = try testCorpus(testing.allocator, 300, 7);
    defer corpus.release();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try run(corpus, arena, .{ .query_text = "us", .results_max = 1000 });
    var cancel: Cancel = .init(true);
    const stopped: Job = .{ .query_text = "user", .results_max = 1000, .cancel = &cancel };
    try testing.expectError(error.Canceled, run(corpus, arena, stopped));
    try testing.expectEqualStrings("us", corpus.filter.query_buffer[0..corpus.filter.query_len]);
    // Narrowed from "us", as if "user" had never been asked.
    for ([_][]const u8{ "use", "user", "x" }) |typed_query| {
        const got = try run(corpus, arena, .{ .query_text = typed_query, .results_max = 1000 });
        const want = try plainHits(arena, corpus.items, test_detail_bytes_max, typed_query, &.{}, 1000);
        try expectHits(want, got);
    }
}

test "a corpus is freed with its last reference" {
    const corpus = try testCorpus(testing.allocator, 20, 1);
    corpus.retain();
    corpus.release();
    try testing.expect(corpus.itemOf(@fromBackingInt(1)) != null);
    try testing.expect(corpus.itemOf(@fromBackingInt(21)) == null);
    // The testing allocator reports the leak if this one does not free it.
    corpus.release();
}
