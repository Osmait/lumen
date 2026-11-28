//! The clipboard view's filter: up to 5,000 entries of up to 2,000 bytes,
//! scored on every keystroke on the GTK thread. Each entry's text is folded
//! once, at the first query (`core.fuzzy.Text`), not again per keystroke,
//! and a query typed on from the last one is scored only against the
//! entries that one matched: whatever a query matches, the queries it
//! starts with match too (MYP-613).
//!
//! Lives with `Ui.base` (`reset` when it is loaded again); its memory is
//! the view's arena's.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const fuzzy = core.fuzzy;
const item_mod = @import("../item.zig");
const Item = item_mod.Item;

const ClipFilter = @This();

/// Each entry's text folded, by index in the entries; empty until a query.
texts: []fuzzy.Text = &.{},
/// Indices of the entries the last query matched, ascending, in
/// `matched[0..matched_len]`.
matched: []u32 = &.{},
matched_len: usize = 0,
/// The last query scored, as typed and folded; `query_len` 0 when there
/// is none to narrow from.
query_buffer: [fuzzy.text_chars_max]u8 = undefined,
query_len: usize = 0,
folded_buffer: [fuzzy.text_chars_max]u8 = undefined,
folded_len: usize = 0,

/// Forgets everything: the entries are about to be loaded again.
pub fn reset(filter: *ClipFilter) void {
    filter.* = .{};
}

/// The text of `item` the filter scores: the head of the entry, up to
/// `detail_bytes_max`, or the title of an item without one.
pub fn scoredText(item: Item, detail_bytes_max: usize) []const u8 {
    if (item.detail.len == 0) return item.title;
    return item.detail[0..@min(item.detail.len, detail_bytes_max)];
}

/// Appends to `hits` the entries of `items` matching `query_text`
/// (`query` folded, not empty), each with its score, in their order; as
/// scoring `scoredText` and the subtitle with `fuzzy.scoreFieldsQuery`
/// does. An entry `matchesBeyond` says holds the query past its scored
/// text gets `beyond_score` when it does not match otherwise; one that
/// holds a query must hold each start of it too (a substring search does).
/// False when out of memory, nothing appended: the caller scores the plain
/// way.
/// The folded texts go in `view_arena`, which holds `items`; `hits` in
/// `arena`.
pub fn score(
    filter: *ClipFilter,
    view_arena: std.mem.Allocator,
    arena: std.mem.Allocator,
    items: []const Item,
    detail_bytes_max: usize,
    query_text: []const u8,
    query: fuzzy.Query,
    context: anytype,
    comptime matchesBeyond: fn (@TypeOf(context), Item) bool,
    beyond_score: i32,
    hits: *std.ArrayList(Item),
) bool {
    assert(query.folded.len > 0);
    assert(beyond_score != fuzzy.no_match);
    if (filter.texts.len != items.len) {
        filter.fold(view_arena, items, detail_bytes_max) catch {
            filter.reset();
            return false;
        };
    }
    assert(filter.texts.len == items.len and filter.matched.len == items.len);
    // Typed on from the last query: as typed for `matchesBeyond`, folded
    // for the scores.
    const narrowing = filter.query_len > 0 and
        std.mem.startsWith(u8, query_text, filter.query_buffer[0..filter.query_len]) and
        std.mem.startsWith(u8, query.folded, filter.folded_buffer[0..filter.folded_len]);
    const candidates_count = if (narrowing) filter.matched_len else items.len;
    const hits_before = hits.items.len;
    var kept: usize = 0;
    for (0..candidates_count) |candidate| {
        const item_index: usize = if (narrowing) filter.matched[candidate] else candidate;
        const item = items[item_index];
        var item_score = fuzzy.scoreText(query, &filter.texts[item_index]);
        if (item.subtitle.len > 0) {
            // As the second of `scoreFieldsQuery`'s fields.
            const subtitle_score = fuzzy.scoreFieldsQuery(query, &.{ "", item.subtitle });
            item_score = @max(item_score, subtitle_score);
        }
        if (item_score == fuzzy.no_match and matchesBeyond(context, item)) {
            item_score = beyond_score;
        }
        if (item_score == fuzzy.no_match) continue;
        var copy = item;
        copy.score = item_score;
        hits.append(arena, copy) catch {
            hits.shrinkRetainingCapacity(hits_before);
            filter.query_len = 0;
            return false;
        };
        // In place: `kept` never passes `candidate`.
        assert(kept <= candidate);
        filter.matched[kept] = @intCast(item_index);
        kept += 1;
    }
    filter.matched_len = kept;
    // A query longer than kept is not narrowed from.
    const kept_whole = query_text.len <= filter.query_buffer.len;
    filter.query_len = if (kept_whole) query_text.len else 0;
    @memcpy(filter.query_buffer[0..filter.query_len], query_text[0..filter.query_len]);
    assert(query.folded.len <= filter.folded_buffer.len);
    @memcpy(filter.folded_buffer[0..query.folded.len], query.folded);
    filter.folded_len = query.folded.len;
    return true;
}

fn fold(
    filter: *ClipFilter,
    arena: std.mem.Allocator,
    items: []const Item,
    detail_bytes_max: usize,
) std.mem.Allocator.Error!void {
    assert(items.len <= std.math.maxInt(u32));
    const texts = try arena.alloc(fuzzy.Text, items.len);
    for (items, texts) |item, *text| text.* = try .init(arena, scoredText(item, detail_bytes_max));
    filter.* = .{ .texts = texts, .matched = try arena.alloc(u32, items.len) };
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn plainScores(
    items: []const Item,
    query: fuzzy.Query,
    beyond: []const usize,
    out: *std.ArrayList(Item),
) !void {
    for (items, 0..) |item, i| {
        const fields = [_][]const u8{ scoredText(item, test_detail_bytes_max), item.subtitle };
        var item_score = fuzzy.scoreFieldsQuery(query, &fields);
        if (item_score == fuzzy.no_match and std.mem.findScalar(usize, beyond, i) != null) {
            item_score = -1;
        }
        if (item_score == fuzzy.no_match) continue;
        var copy = item;
        copy.score = item_score;
        try out.append(testing.allocator, copy);
    }
}

const test_detail_bytes_max = 40;

const Beyond = struct {
    items: []const Item,
    indices: []const usize,

    fn has(beyond: Beyond, item: Item) bool {
        for (beyond.indices) |i| {
            if (beyond.items[i].action.clip == item.action.clip) return true;
        }
        return false;
    }
};

test "the clipboard filter matches and scores as scoring every entry does (MYP-613)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(613);
    const random = prng.random();
    const words = [_][]const u8{ "Config", "user", "tóken", "request", "zig", "café", "x", "-", "/" };
    var items: [300]Item = undefined;
    for (&items, 0..) |*item, i| {
        var text: std.ArrayList(u8) = .empty;
        const words_count = random.uintAtMost(usize, 12);
        for (0..words_count) |_| {
            try text.appendSlice(arena, words[random.uintLessThan(usize, words.len)]);
            try text.append(arena, ' ');
        }
        const detail = text.items;
        item.* = .{
            .title = "",
            .detail = detail,
            .subtitle = if (i % 7 == 0) "Request" else "",
            .action = .{ .clip = @fromBackingInt(@intCast(i + 1)) },
        };
        // Some without a head: their title is scored.
        if (i % 11 == 0) item.* = .{ .title = "user café", .action = .{ .clip = @fromBackingInt(@intCast(i + 1)) } };
    }
    const beyond_indices = [_]usize{ 3, 50, 299 };
    const beyond: Beyond = .{ .items = &items, .indices = &beyond_indices };
    // Typed on, typed over, typed back: each a query of its own.
    const typed = [_][]const u8{
        "u",       "us",  "use", "user", "user ", "user t", "user to", "user tok",
        "use",     "us",  "R",   "re",   "req",   "reQu",   "requ",    "c",
        "ca",      "caf",
        "café",
        "cafe",    "z",   "zi",  "zx",   "zig c", "",       "nothing", "nothin",
        "/",       "/ z", "-",   "ct",   "ctr",
        "ü",
        "user tóq",
        "user to", "x",
    };
    var filter: ClipFilter = .{};
    var hits: std.ArrayList(Item) = .empty;
    var expected: std.ArrayList(Item) = .empty;
    defer expected.deinit(testing.allocator);
    for (typed) |typed_query| {
        var query_buffer: [fuzzy.text_chars_max]u8 = undefined;
        const query = fuzzy.prepare(&query_buffer, typed_query);
        // Nothing typed lists everything, scoring nothing.
        if (query.folded.len == 0) continue;
        hits.clearRetainingCapacity();
        try testing.expect(filter.score(
            arena,
            arena,
            &items,
            test_detail_bytes_max,
            typed_query,
            query,
            beyond,
            Beyond.has,
            -1,
            &hits,
        ));
        expected.clearRetainingCapacity();
        try plainScores(&items, query, &beyond_indices, &expected);
        try testing.expectEqual(expected.items.len, hits.items.len);
        for (expected.items, hits.items) |want, got| {
            try testing.expectEqual(want.action.clip, got.action.clip);
            try testing.expectEqual(want.score, got.score);
        }
    }
    // Loaded again: folded again.
    filter.reset();
    try testing.expectEqual(@as(usize, 0), filter.texts.len);
}
