//! What each view lists: its candidates, read once when the view opens
//! (`loadBase`, kept in `Ui.base`), and the rows a query picks from them,
//! on every keystroke (`fill`).
//!
//! The root search scores apps, commands, scripts and extension items, and
//! mixes in the calculator, extensions' answers and the best files; the
//! clipboard and windows views filter their lists; settings-like views
//! filter by section. Files and contents are searched straight from the
//! index, the contents view through the ContentSearch worker: its answers
//! arrive later and refresh again. Main thread only.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const hypr = @import("../sys/hypr.zig");
const commands = @import("../providers/commands.zig");
const scripts = @import("../providers/scripts.zig");
const stats = @import("../stats.zig");
const dmenu = @import("dmenu.zig");
const ext_view = @import("ext_view.zig");
const file_results = @import("file_results.zig");
const form_view = @import("form_view.zig");
const labels = @import("labels.zig");
const prefs_view = @import("prefs_view.zig");
const row_list = @import("row_list.zig");
const settings_view = @import("settings_view.zig");
const ContentSearch = @import("ContentSearch.zig");
const Ui = @import("Ui.zig");

const log = std.log.scoped(.ui);

/// Rows a search shows at most, per view. More would only cost building
/// them: nobody scrolls past the first screens of a ranked list.
const root_results_max = 60;
const file_results_max = 60;
const content_results_max = 50;

/// Clipboard and window searches: the lists are short already.
const filtered_results_max = 200;

/// Clipboard entries the clipboard view loads, newest first.
const clipboard_rows_max = 500;

/// Files in the root search, after this many of the best other results.
const root_files_max = 5;
const root_results_before_files_max = 6;

/// The most used items shown with nothing typed.
const suggestions_max = 6;

/// Files join the root search from this many bytes typed: shorter queries
/// match half the disk.
const root_files_query_bytes_min = 3;

/// A content query needs a whole trigram: the content index looks up
/// three-character pieces.
pub const content_query_bytes_min = 3;

/// How much of a clipboard entry's text the filter scores. Each keystroke
/// scores every entry on the main thread.
const filtered_detail_bytes_max = 2000;

/// Frecency is a small float (core.frecency); scores are integers. Scaled
/// by this, suggestions keep three decimals of their order.
const frecency_score_scale = 1000;

/// How a filtered list shows with nothing typed: the clipboard in Today,
/// Yesterday and Earlier, the windows as they come.
const Grouping = enum { by_day, flat };

comptime {
    assert(row_list.eager_rows <= content_results_max);
    assert(root_results_before_files_max <= root_results_max);
    assert(root_files_max <= file_results_max);
    assert(suggestions_max <= root_results_max);
    assert(content_query_bytes_min <= ContentSearch.query_bytes_max);
}

/// The view's candidates before filtering, in `arena` (the view's).
pub fn loadBase(ui: *Ui, arena: std.mem.Allocator) []Item {
    return switch (ui.view) {
        .root => rootCandidates(ui, arena),
        .clipboard => clipCandidates(ui, arena),
        .windows => windowCandidates(ui, arena),
        // Searched on every keystroke, straight from the index.
        .files, .contents => &.{},
        .settings => settings_view.settingsCandidates(ui, arena),
        .themes => settings_view.themeCandidates(ui, arena),
        .default_apps => settings_view.defaultAppsCandidates(ui, arena),
        .choose => settings_view.chooseCandidates(ui, arena),
        .ext => ext_view.base(ui),
        // The rows are filtered straight from the session's lines.
        .dmenu => &.{},
        .prefs => prefs_view.candidates(ui, arena),
        .input => prefs_view.inputCandidates(ui, arena),
        .form => form_view.candidates(ui, arena),
    };
}

fn rootCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    const sources = [_][]const Item{
        ui.apps.items,
        &commands.all,
        scripts.load(arena),
        ext_view.rootItems(ui, arena),
    };
    var item_count: usize = 0;
    for (sources) |source| item_count += source.len;
    const all = arena.alloc(Item, item_count) catch {
        log.warn("out of memory: the root search lists no apps or commands", .{});
        return &.{};
    };
    var filled: usize = 0;
    for (sources) |source| {
        @memcpy(all[filled..][0..source.len], source);
        filled += source.len;
    }
    assert(filled == all.len);
    return all;
}

fn clipCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    const clips = ui.db.recentClips(arena, clipboard_rows_max) catch return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (clips) |clip| {
        out.append(arena, .{
            .title = labels.firstLine(arena, clip.head),
            .icon = .{ .tile = .{ .name = "edit-copy-symbolic", .color = .gray } },
            // The head only: the detail pane and the actions read the whole
            // entry (`clipContent`).
            .action = .{ .clip = clip.id },
            .detail = clip.head,
            .time_s = clip.last_copied,
        }) catch break;
    }
    return out.items;
}

fn windowCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (hypr.clients(arena)) |client| {
        if (!client.mapped or client.address.len == 0) continue;
        const icon: item_mod.Icon = if (ui.apps.iconForClass(client.class)) |gicon|
            .{ .gicon = gicon }
        else
            .{ .tile = .{ .name = "focus-windows-symbolic", .color = .blue } };
        out.append(arena, .{
            .title = labels.displayText(
                arena,
                if (client.title.len > 0) client.title else client.class,
            ),
            .subtitle = labels.displayText(arena, client.class),
            .accessory = arena.printSentinel("Workspace {s}", .{client.workspace.name}, 0) catch "",
            .icon = icon,
            .action = .{ .focus_window = arena.dupeSentinel(u8, client.address, 0) catch continue },
        }) catch break;
    }
    return out.items;
}

/// The rows on screen stay while the answer to a new query is on its way
/// (it refreshes again when it comes): building them again cost a frame
/// per keystroke. True when that is the case and the query was sent.
pub fn answerPending(ui: *Ui, start_ns: u64) bool {
    const query_text = std.mem.trim(u8, ui.query(), " ");
    // An extension's search command keeps its rows until it answers.
    if (ui.view == .ext and ext_view.waitingForSearch(ui, query_text)) return true;
    // In the contents view, the rows on screen are the last result's.
    if (ui.view != .contents) return false;
    const content_search = ui.content_search orelse return false;
    if (query_text.len < content_query_bytes_min) return false;
    if (!ui.content_query.showingLatest()) return false;
    const latest = ui.content_query.latest.?;
    if (std.mem.eql(u8, latest.query, ContentSearch.clip(query_text))) return false;
    ui.content_query.sent(content_search.submit(query_text, start_ns), query_text);
    return true;
}

/// Builds the current view's rows for `query_text`.
pub fn fill(ui: *Ui, arena: std.mem.Allocator, query_text: []const u8, start_ns: u64) void {
    switch (ui.view) {
        .root => fillRoot(ui, arena, query_text),
        .clipboard => fillFiltered(ui, arena, query_text, .by_day),
        .windows => fillFiltered(ui, arena, query_text, .flat),
        .files => if (query_text.len > 0) {
            row_list.addSection(ui, "Files");
            for (file_results.fileItems(ui, arena, query_text, file_results_max)) |item| {
                row_list.addItem(ui, item);
            }
        },
        .contents => if (query_text.len >= content_query_bytes_min) {
            fillContents(ui, arena, query_text, start_ns);
        },
        .settings, .themes, .default_apps, .choose => fillSectioned(ui, arena, query_text),
        // A search command is asked for the query; a list command's rows are
        // filtered here.
        .ext => {
            fillSectioned(ui, arena, if (ext_view.prepare(ui, query_text)) query_text else "");
            ui.ext_list.shown = ui.ext_list.latest;
        },
        .dmenu => dmenu.fill(ui, arena, query_text),
        .prefs => fillSectioned(ui, arena, query_text),
        // In the input view the typed text is the value being edited, so it
        // does not filter the rows.
        .input => fillSectioned(ui, arena, ""),
        .form => fillSectioned(ui, arena, query_text),
    }
}

fn fillContents(ui: *Ui, arena: std.mem.Allocator, query_text: []const u8, start_ns: u64) void {
    const content_search = ui.content_search orelse {
        row_list.addSection(ui, "Matches");
        for (file_results.contentItems(ui, arena, query_text, content_results_max)) |item| {
            row_list.addItem(ui, item);
        }
        return;
    };
    // Ask the worker unless the result for this exact query is already
    // here; meanwhile keep showing the last result. The worker searches the
    // clipped query: compare with that, or a query longer than the clip
    // never counts as answered.
    const fresh = if (ui.content_query.latest) |latest|
        std.mem.eql(u8, latest.query, ContentSearch.clip(query_text))
    else
        false;
    if (fresh) {
        ui.content_query.answered();
    } else {
        ui.content_query.sent(content_search.submit(query_text, start_ns), query_text);
    }
    if (ui.content_query.latest) |latest| {
        row_list.addSection(ui, "Matches");
        for (file_results.itemsFromHits(ui, arena, latest.hits)) |item| row_list.addItem(ui, item);
        ui.content_query.shown = latest;
    }
}

/// Settings-style lists: grouped by section, filtered by typing.
fn fillSectioned(ui: *Ui, arena: std.mem.Allocator, query_text: []const u8) void {
    if (query_text.len == 0) {
        var last: ?[]const u8 = null;
        for (ui.base) |item| {
            if (last == null or !std.mem.eql(u8, last.?, item.section)) {
                if (item.section.len > 0) row_list.addSection(ui, item.section);
                last = item.section;
            }
            row_list.addItem(ui, item);
        }
        return;
    }
    var hits: std.ArrayList(Item) = .empty;
    for (ui.base) |item| {
        const fields = [_][]const u8{ item.title, item.keywords, item.subtitle, item.accessory };
        const score = core.fuzzy.scoreFields(query_text, &fields);
        if (score == core.fuzzy.no_match) continue;
        var copy = item;
        copy.score = score;
        hits.append(arena, copy) catch break;
    }
    sortByScore(hits.items);
    for (hits.items) |item| row_list.addItem(ui, item);
}

/// Nothing typed: what was used most, then every command.
fn fillSuggestions(ui: *Ui, arena: std.mem.Allocator) void {
    var used: std.ArrayList(Item) = .empty;
    for (ui.base) |item| {
        const frecency = ui.frecency.get(item.key) orelse continue;
        var copy = item;
        copy.score = std.math.lossyCast(i32, frecency * frecency_score_scale);
        used.append(arena, copy) catch break;
    }
    sortByScore(used.items);
    if (used.items.len > 0 and ui.settings.suggestions) {
        row_list.addSection(ui, "Suggestions");
        for (used.items[0..@min(used.items.len, suggestions_max)]) |item| row_list.addItem(ui, item);
    }
    row_list.addSection(ui, "Commands");
    for (ui.base) |item| {
        switch (item.action) {
            .view, .script, .ext_command, .ext_problem => row_list.addItem(ui, item),
            else => {},
        }
    }
}

fn fillRoot(ui: *Ui, arena: std.mem.Allocator, query_text: []const u8) void {
    if (query_text.len == 0) return fillSuggestions(ui, arena);

    if (core.calc.evaluate(query_text)) |answer| {
        row_list.addSection(ui, "Calculator");
        var plain_bytes: [64]u8 = undefined;
        const plain = arena.dupe(u8, core.calc.formatPlain(&plain_bytes, answer.value)) catch "";
        row_list.addItem(ui, .{
            .title = arena.dupeSentinel(u8, query_text, 0) catch "",
            .subtitle = arena.dupeSentinel(u8, answer.from_unit, 0) catch "",
            .accessory = arena.dupeSentinel(u8, answer.unit, 0) catch "",
            .action = .calc,
            .detail = plain,
        });
    }
    // Extensions' answers (rows from `root = function(query)`).
    ext_view.addRootSections(ui, query_text);

    // Scoring and sorting only: rows are timed apart, and fileItems times
    // itself (a deferred timer here counted it twice).
    const search_start_ns = stats.now();
    var hits: std.ArrayList(Item) = .empty;
    for (ui.base) |item| {
        const fields = [_][]const u8{ item.title, item.keywords, item.subtitle };
        const score = core.fuzzy.scoreFields(query_text, &fields);
        if (score == core.fuzzy.no_match) continue;
        var copy = item;
        copy.score = score + core.frecency.boost(ui.frecency.get(item.key) orelse 0);
        hits.append(arena, copy) catch break;
    }
    sortByScore(hits.items);
    ui.search_ns += stats.now() - search_start_ns;
    // Files from 3 letters on, right after the best few results so they are
    // visible without scrolling; the rest of the results follow.
    const files_wanted = query_text.len >= root_files_query_bytes_min and
        ui.settings.files_in_root;
    const files = if (files_wanted)
        file_results.fileItems(ui, arena, query_text, root_files_max)
    else
        &.{};
    const shown = @min(hits.items.len, root_results_max);
    const head = if (files.len > 0) @min(shown, root_results_before_files_max) else shown;
    for (hits.items[0..head]) |item| row_list.addItem(ui, item);
    if (files.len > 0) {
        row_list.addSection(ui, "Files");
        for (files) |item| row_list.addItem(ui, item);
        if (shown > head) row_list.addSection(ui, "More Results");
        for (hits.items[head..shown]) |item| row_list.addItem(ui, item);
    }
}

fn fillFiltered(
    ui: *Ui,
    arena: std.mem.Allocator,
    query_text: []const u8,
    grouping: Grouping,
) void {
    if (query_text.len == 0) {
        if (grouping == .by_day) {
            const today_s = labels.startOfToday();
            var last: ?[:0]const u8 = null;
            for (ui.base) |item| {
                const section: [:0]const u8 = if (item.time_s >= today_s)
                    "Today"
                else if (item.time_s >= today_s - std.time.s_per_day)
                    "Yesterday"
                else
                    "Earlier";
                if (last == null or !std.mem.eql(u8, last.?, section)) {
                    row_list.addSection(ui, section);
                    last = section;
                }
                row_list.addItem(ui, item);
            }
        } else {
            for (ui.base) |item| row_list.addItem(ui, item);
        }
        return;
    }
    const search_start_ns = stats.now();
    var hits: std.ArrayList(Item) = .empty;
    for (ui.base) |item| {
        const detail_scored = item.detail[0..@min(item.detail.len, filtered_detail_bytes_max)];
        const text = if (item.detail.len > 0) detail_scored else item.title;
        const fields = [_][]const u8{ text, item.subtitle };
        const score = core.fuzzy.scoreFields(query_text, &fields);
        if (score == core.fuzzy.no_match) continue;
        var copy = item;
        copy.score = score;
        hits.append(arena, copy) catch break;
    }
    sortByScore(hits.items);
    ui.search_ns += stats.now() - search_start_ns;
    for (hits.items[0..@min(hits.items.len, filtered_results_max)]) |item| row_list.addItem(ui, item);
}

/// Best first; equal scores by title, so the order never depends on the
/// sort's whims (two apps tied for "e2e" swapped between runs).
fn sortByScore(items: []Item) void {
    std.mem.sort(Item, items, {}, struct {
        fn better(_: void, x: Item, y: Item) bool {
            if (x.score != y.score) return x.score > y.score;
            return std.mem.order(u8, x.title, y.title) == .lt;
        }
    }.better);
}

/// The placeholder row's text when nothing is listed.
pub fn emptyText(ui: *Ui, arena: std.mem.Allocator) [:0]const u8 {
    const query_text = std.mem.trim(u8, ui.query(), " ");
    if (ui.view == .files and query_text.len == 0) return file_results.filesHint(ui, arena);
    if (ui.view == .contents and query_text.len < content_query_bytes_min) {
        return file_results.contentsHint(ui, arena, query_text.len);
    }
    if (ui.view == .contents and ui.content_query.pending) return "Searching...";
    const content_error = if (ui.content_query.latest) |result| result.err else null;
    if (ui.view == .contents and content_error != null) {
        return arena.printSentinel(
            "Content search failed ({t})",
            .{content_error.?},
            0,
        ) catch "Content search failed";
    }
    const clipboard_off = ui.view == .clipboard and !ui.settings.clipboard;
    if (clipboard_off and query_text.len == 0) {
        return "Clipboard history is off: turn it on in Settings";
    }
    if (ui.view == .ext) return ext_view.emptyText(ui, arena, query_text);
    if (ui.view == .dmenu) return dmenu.emptyText(ui);
    return "No Results";
}
