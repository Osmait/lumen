//! The clipboard view: its entries, loaded into a `ClipFilter.Corpus`
//! (`candidates`), and the rows a query picks from them.
//!
//! A long history is scored by the ClipSearch worker, off the GTK thread
//! (MYP-613): a keystroke only asks, the rows on screen stay until the
//! answer comes (`answerPending`), and then they are built again
//! (`onResult`). A short one is scored in place, in less than a
//! millisecond. Answers name entries by id: rows built from an answer to
//! entries loaded before (an entry deleted since) list only those still
//! there. Main thread only.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const Db = @import("../sys/Db.zig");
const settings_mod = @import("../settings.zig");
const stats = @import("../stats.zig");
const Inflight = @import("inflight.zig").Inflight;
const ClipFilter = @import("ClipFilter.zig");
const Corpus = ClipFilter.Corpus;
const ClipSearch = @import("ClipSearch.zig");
const labels = @import("labels.zig");
const row_list = @import("row_list.zig");
const Ui = @import("Ui.zig");

const log = std.log.scoped(.ui);

/// Entries the view loads, newest first: the largest `clipboard_keep`, so
/// every entry kept is searchable.
pub const rows_max = settings_mod.clipboard_keep_max;

/// How much of an entry's text the filter scores.
pub const detail_bytes_max = 2000;

/// Rows a query shows at most: nobody scrolls past the first screens.
pub const results_max = 200;

/// Histories with no more text than this to score are scored in place:
/// under a millisecond for the slowest queries (~15 ns a byte).
const in_place_bytes_max = 64 * 1024;

/// What is kept of a query to tell its answer (`State`).
const query_bytes_max = 1024;

pub const State = struct {
    /// The entries listed (`Ui.base` points into them): the view's
    /// reference to them.
    corpus: ?*Corpus = null,
    /// Started for the first long history filtered.
    search: ?*ClipSearch = null,
    /// The worker could not start, or has shut down: every query is scored
    /// in place.
    worker_off: bool = false,
    /// Queries asked of `search`, and their answers.
    query: Inflight(ClipSearch.Result, query_bytes_max) = .{},
    /// The corpus the query in flight scores (`query.asking` knows only
    /// its text).
    asked_serial: u64 = 0,
    /// The rows on screen were built from `corpus`: false from loading it
    /// until they are.
    rows_current: bool = false,
    /// What was typed when the rows on screen were built.
    rows_query: core.FixedStr(query_bytes_max) = .{},
    /// `Ui.reselect_row` when the rows went empty waiting for an answer:
    /// the place is kept for it (`Ui.keepPlace`, MYP-536).
    place: ?usize = null,
};

comptime {
    assert(rows_max <= std.math.maxInt(u32));
    assert(in_place_bytes_max < rows_max * detail_bytes_max);
}

/// The view's entries, newest first. Call `reset` before: the last ones
/// go with it.
pub fn candidates(ui: *Ui) []Item {
    assert(ui.clip.corpus == null);
    const corpus = load(ui) catch |err| {
        log.warn("clipboard history: {t}", .{err});
        return &.{};
    };
    ui.clip.corpus = corpus;
    return corpus.items;
}

fn load(ui: *Ui) !*Corpus {
    const corpus = try Corpus.create(ui.gpa);
    errdefer corpus.release();
    const arena = corpus.allocator();
    const clips = try ui.db.recentClips(arena, rows_max);
    const items = try arena.alloc(Item, clips.len);
    for (clips, items) |clip, *item| {
        item.* = .{
            .title = labels.firstLine(arena, clip.head),
            .icon = .{ .tile = .{ .name = "edit-copy-symbolic", .color = .gray } },
            // The head only: the detail pane and the actions read the whole
            // entry (`clipContent`).
            .action = .{ .clip = clip.id },
            .detail = clip.head,
            .time_s = clip.last_copied,
        };
    }
    try corpus.setItems(items, detail_bytes_max);
    return corpus;
}

/// The entries are about to be loaded again, or another view's: the query
/// in flight is not wanted, and the entries go once the worker is done
/// with them.
pub fn reset(ui: *Ui) void {
    const state = &ui.clip;
    stopAsking(state);
    if (state.corpus) |corpus| corpus.release();
    state.corpus = null;
    state.rows_current = false;
    state.place = null;
}

/// At shutdown: the worker stops, and what is left is scored in place.
pub fn shutdown(ui: *Ui) void {
    const state = &ui.clip;
    state.worker_off = true;
    const search = state.search orelse return;
    state.search = null;
    search.shutdown();
    if (state.query.forget()) |latest| latest.destroy(ui.gpa);
}

/// True when a long history's rows for `query_text` are on their way and
/// the rows on screen stay until they come: a keystroke does not wait for
/// the worker.
pub fn answerPending(ui: *Ui, query_text: []const u8, start_ns: u64) bool {
    if (ui.view != .clipboard or query_text.len == 0) return false;
    const state = &ui.clip;
    // The entries were loaded again: the rows on screen go now.
    if (!state.rows_current) return false;
    const corpus = state.corpus orelse return false;
    const search = worker(ui, corpus) orelse return false;
    if (answered(state, corpus, query_text)) return false;
    return ask(ui, search, corpus, ui.query_arena.allocator(), query_text, start_ns);
}

/// Nothing typed: every entry is listed, and a query in flight is not
/// wanted.
pub fn nothingTyped(ui: *Ui) void {
    assert(ui.view == .clipboard);
    const state = &ui.clip;
    stopAsking(state);
    state.rows_current = true;
    state.rows_query.clear();
    state.place = null;
}

/// The rows for `query_text` (not empty): scored in place, or the worker's
/// answer. Until it comes, the last answer to the same text, for entries
/// loaded since (those still listed), or no rows.
pub fn fill(ui: *Ui, arena: std.mem.Allocator, query_text: []const u8, start_ns: u64) void {
    assert(ui.view == .clipboard and query_text.len > 0);
    const state = &ui.clip;
    state.rows_current = true;
    state.rows_query.set(query_text);
    state.place = null;
    const corpus = state.corpus orelse return;
    const search_start_ns = stats.now();
    defer ui.search_ns += stats.now() - search_start_ns;
    const search = worker(ui, corpus) orelse {
        const hits = ClipFilter.run(corpus, arena, .{
            .query_text = query_text,
            .beyond = clipsMatchingPastScored(ui, arena, query_text),
            .results_max = results_max,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                log.warn("clipboard filter: out of memory", .{});
                return;
            },
            // Nothing cancels a job in place.
            error.Canceled => unreachable,
        };
        return addHits(ui, corpus, hits);
    };
    if (answered(state, corpus, query_text)) {
        stopAsking(state);
        return addHits(ui, corpus, state.query.latest.?.hits);
    }
    _ = ask(ui, search, corpus, arena, query_text, start_ns);
    if (state.query.latest) |latest| {
        if (std.mem.eql(u8, latest.query, query_text)) return addHits(ui, corpus, latest.hits);
    }
    state.place = ui.reselect_row;
}

/// True while the rows wait for the worker's answer.
pub fn searching(ui: *const Ui) bool {
    return ui.view == .clipboard and ui.clip.query.pending;
}

/// The worker's answer, on the GTK main loop.
pub fn onResult(result: *ClipSearch.Result, context: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(context.?));
    const state = &ui.clip;
    if (!state.query.current(result)) {
        result.destroy(ui.gpa);
        return;
    }
    if (result.err) |err| log.warn("clipboard filter for \"{s}\": {t}", .{ result.query, err });
    // No row points into an answer: the one replaced goes now.
    if (state.query.take(result)) |replaced| replaced.destroy(ui.gpa);
    const corpus = state.corpus orelse return;
    const query_text = std.mem.trim(u8, ui.query(), " ");
    const answers_rows = ui.view == .clipboard and result.serial == corpus.serial and
        std.mem.eql(u8, result.query, query_text);
    if (!answers_rows) return;
    // The rows on screen are for this text already (an answer to entries
    // loaded before): the selected row stays where it is, and the list
    // where it was scrolled.
    const searched_again = state.rows_current and state.rows_query.eql(result.query);
    if (searched_again) {
        if (ui.items.items.len > 0 and listsHits(ui, corpus, result.hits)) return;
        ui.reselect_row = ui.selected orelse state.place;
        const adjustment = c.gtk_scrolled_window_get_vadjustment(ui.scroller);
        ui.reselect_scroll = c.gtk_adjustment_get_value(adjustment);
    }
    ui.refresh();
    // Latency from the keystroke that asked, not from this rebuild.
    if (stats.pending) |*pending_stats| {
        pending_stats.start_ns = result.start_ns;
        pending_stats.search_ns = result.search_ns;
    }
}

/// The worker for `corpus`, started if need be; null when it is scored in
/// place. The same for a corpus all its life: never both scoring it.
fn worker(ui: *Ui, corpus: *const Corpus) ?*ClipSearch {
    const state = &ui.clip;
    if (corpus.scored_bytes <= in_place_bytes_max) return null;
    if (state.search) |search| return search;
    if (state.worker_off) return null;
    state.search = ClipSearch.start(ui.gpa, ui.io, results_max, &onResult, ui) catch |err| {
        log.warn("clipboard filter worker: {t}; filtering in place", .{err});
        state.worker_off = true;
        return null;
    };
    return state.search;
}

/// Whether the latest answer is `query_text`'s, for `corpus`.
fn answered(state: *const State, corpus: *const Corpus, query_text: []const u8) bool {
    const latest = state.query.latest orelse return false;
    return latest.serial == corpus.serial and std.mem.eql(u8, latest.query, query_text);
}

/// Asks the worker for `query_text` unless it is asked already; false
/// when it could not be.
fn ask(
    ui: *Ui,
    search: *ClipSearch,
    corpus: *Corpus,
    arena: std.mem.Allocator,
    query_text: []const u8,
    start_ns: u64,
) bool {
    const state = &ui.clip;
    if (state.query.asking(query_text) and state.asked_serial == corpus.serial) return true;
    const beyond = clipsMatchingPastScored(ui, arena, query_text);
    const generation = search.submit(corpus, query_text, beyond, start_ns) catch |err| {
        log.warn("clipboard filter: {t}", .{err});
        return false;
    };
    state.query.sent(generation, query_text);
    state.asked_serial = corpus.serial;
    return true;
}

fn stopAsking(state: *State) void {
    if (!state.query.pending) return;
    state.query.drop();
    if (state.search) |search| search.cancel();
}

fn addHits(ui: *Ui, corpus: *const Corpus, hits: []const ClipFilter.Hit) void {
    for (hits) |hit| {
        var item = corpus.itemOf(hit.id) orelse continue;
        item.score = hit.score;
        row_list.addItem(ui, item);
    }
}

/// Whether the rows on screen list `hits`' entries still listed, in order.
fn listsHits(ui: *const Ui, corpus: *const Corpus, hits: []const ClipFilter.Hit) bool {
    const shown = ui.items.items;
    var listed: usize = 0;
    for (hits) |hit| {
        if (corpus.itemOf(hit.id) == null) continue;
        if (listed == shown.len) return false;
        const item = shown[listed];
        if (item.action != .clip or item.action.clip != hit.id) return false;
        listed += 1;
    }
    return listed == shown.len;
}

/// The entries longer than the filter scores (`detail_bytes_max`) that
/// hold `query_text` further on, sorted (`ClipFilter.Job.beyond`). Asked
/// of the database only when an entry that long is listed (MYP-491).
fn clipsMatchingPastScored(ui: *Ui, arena: std.mem.Allocator, query_text: []const u8) []Db.ClipId {
    for (ui.base) |item| {
        if (item.action == .clip and item.detail.len >= detail_bytes_max) break;
    } else return &.{};
    const ids = ui.db.clipsContaining(arena, query_text, detail_bytes_max) catch |err| {
        log.warn("clipboard search past each entry's head: {t}", .{err});
        return &.{};
    };
    std.mem.sort(Db.ClipId, ids, {}, struct {
        fn lessThan(_: void, x: Db.ClipId, y: Db.ClipId) bool {
            return ClipFilter.orderClipId(x, y) == .lt;
        }
    }.lessThan);
    return ids;
}
