//! The result rows: building them for the visible items, selecting one, and
//! scrolling it into view.
//!
//! A refresh calls `addSection` and `addItem` in row order. The first
//! `eager_rows` rows are built in the keystroke's frame; the rest wait in
//! `Ui.pending` and are built a few at a time after it (`onPendingRows`), or
//! all at once when something needs them sooner (`ensureRows`). Every row
//! has an entry in `Ui.rows`, in the same order as the widgets, and an item
//! row points at its item in `Ui.items`: the two lists, the widgets and the
//! selection move together, and the assertions here keep them so.
//!
//! In a grid (`Ui.grid_mode`) every cell is built at once and there are no
//! section rows, so a cell's index is its item's. Main thread only (GTK).

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const detail_pane = @import("detail_pane.zig");
const themes = @import("themes.zig");
const widgets = @import("widgets.zig");
const window_layout = @import("window_layout.zig");
const HintTone = window_layout.HintTone;
const config = @import("config.zig");
const search = @import("search.zig");
const Ui = @import("Ui.zig");

/// `hint` shows the primary action while the row is selected, in place of
/// `accessory`.
pub const Row = struct {
    widget: RowWidget,
    item: ?usize,
    section: [:0]const u8 = "",
    hint: ?*c.GtkLabel = null,
    accessory: ?*c.GtkWidget = null,
};

/// The GObject data an item's list row carries: its index in `rows` plus
/// one, since a pointer of 0 reads back as no data.
const row_index_data_key = "lumen-row";

/// A row of the list, or a cell of the grid (`grid_mode`).
const RowWidget = union(enum) {
    list_row: *c.GtkListBoxRow,
    grid_cell: *c.GtkFlowBoxChild,

    fn widget(row_widget: RowWidget) *c.GtkWidget {
        return switch (row_widget) {
            inline else => |typed| gtk.widget(typed),
        };
    }
};

/// A row not built yet: an item (its index) or a section title.
pub const Pending = union(enum) { item: usize, section: [:0]const u8 };

/// Rows built in the keystroke's frame: the ~8 the list shows and a few to
/// scroll into. Building all 61 file rows (~430 widgets) per key cost ~14 of
/// the view's 23 ms, because GTK laid out every one.
pub const eager_rows = 14;

/// Rows built per idle callback after the first frame (see `eager_rows`).
const pending_rows_per_idle = 16;

/// Room kept above the selection when scrolling up, so the section title
/// over the first item of a section stays in view.
const scroll_section_title_px = 30;

/// How close to the top edge a row may be before the list scrolls up.
const scroll_top_slack_px = 4;

/// Frames to wait for a new row's place before giving up scrolling to it.
const scroll_frames_max = 10;

comptime {
    // The first screen of every search is built in the keystroke's frame.
    assert(eager_rows > 0);
    // Rows built after the first frame come in smaller batches than the
    // first frame's, or an idle callback would take a frame of its own.
    assert(pending_rows_per_idle <= eager_rows + 2);
}

/// Scrolling to the selection once the rebuilt list has its layout.
pub const Scroll = struct {
    /// The tick callback waiting for the layout (0: none).
    tick: c_uint = 0,
    /// Set while `selectAfterRefresh` selects the first row (see there).
    suppressed: bool = false,
    tries: u8 = 0,
};

/// No rows (what they pointed to is going away).
pub fn clearRows(ui: *Ui) void {
    resetRows(ui);
    ui.primary = "";
}

/// Forgets the rows and the items behind them, and anything queued to
/// build them.
pub fn resetRows(ui: *Ui) void {
    _ = ui.query_arena.reset(Ui.arena_keep);
    ui.items = .empty;
    ui.rows = .empty;
    ui.pending = .empty;
    if (ui.pending_idle != 0) _ = c.g_source_remove(ui.pending_idle);
    ui.pending_idle = 0;
    ui.content_query.shown = null;
    ui.ext_list.shown = null;
    ui.selected = null;
    c.gtk_list_box_remove_all(ui.list);
}

pub fn addSection(ui: *Ui, title: [:0]const u8) void {
    // A grid has no sections: rows and items stay one to one there.
    if (ui.grid_mode or !ui.layout.show.section_titles) return;
    if (deferRow(ui, .{ .section = title })) return;
    buildSection(ui, title);
}

/// Queues the row and returns true when `eager_rows` rows are built already.
/// Returns false when the caller must build it now.
fn deferRow(ui: *Ui, pending_row: Pending) bool {
    const eager = ui.rows.items.len < eager_rows and ui.pending.items.len == 0;
    if (ui.grid_mode or eager) return false;
    ui.pending.append(ui.query_arena.allocator(), pending_row) catch return false;
    if (ui.pending_idle == 0) {
        ui.pending_idle = c.g_idle_add_full(c.G_PRIORITY_LOW, &onPendingRows, ui, null);
    }
    return true;
}

/// The item of the last row that has one.
fn lastItemRow(ui: *const Ui) ?usize {
    var i = ui.rows.items.len;
    while (i > 0) {
        i -= 1;
        if (ui.rows.items[i].item) |item| return item;
    }
    return null;
}

/// Builds every queued row now.
pub fn ensureRows(ui: *Ui) void {
    if (ui.pending_idle != 0) _ = c.g_source_remove(ui.pending_idle);
    ui.pending_idle = 0;
    buildPending(ui, ui.pending.items.len);
}

/// Builds up to `row_count_max` of the queued rows, oldest first.
fn buildPending(ui: *Ui, row_count_max: usize) void {
    const built_count = @min(row_count_max, ui.pending.items.len);
    for (ui.pending.items[0..built_count]) |pending_row| switch (pending_row) {
        .item => |item_index| buildItemRow(ui, item_index),
        .section => |title| buildSection(ui, title),
    };
    // What is left moves to the front.
    @memmove(
        ui.pending.items[0 .. ui.pending.items.len - built_count],
        ui.pending.items[built_count..],
    );
    ui.pending.items.len -= built_count;
}

/// After the frame: the queued rows a few at a time, so a keystroke that
/// comes meanwhile is not kept waiting (it drops them).
fn onPendingRows(data: ?*anyopaque) callconv(.c) c.gboolean {
    const ui: *Ui = @ptrCast(@alignCast(data));
    buildPending(ui, pending_rows_per_idle);
    if (ui.pending.items.len > 0) return 1;
    ui.pending_idle = 0;
    return 0;
}

fn buildSection(ui: *Ui, title: [:0]const u8) void {
    // Room first: a widget without its `rows` entry would shift every later
    // row's index.
    ui.rows.ensureUnusedCapacity(ui.query_arena.allocator(), 1) catch return;
    const row = gtk.listBoxRow();
    gtk.addClass(row, "section");
    c.gtk_list_box_row_set_selectable(row, 0);
    c.gtk_list_box_row_set_activatable(row, 0);
    c.gtk_list_box_row_set_child(row, gtk.widget(widgets.label(title, "section-title")));
    c.gtk_list_box_append(ui.list, gtk.widget(row));
    ui.rows.appendAssumeCapacity(.{
        .widget = .{ .list_row = row },
        .item = null,
        .section = title,
    });
}

pub fn addItem(ui: *Ui, item_given: Item) void {
    var item = item_given;
    if (config.keyIcon(ui, item.key)) |icon| item.icon = icon;
    const arena = ui.query_arena.allocator();
    const item_index = ui.items.items.len;
    ui.items.append(arena, item) catch return;
    if (deferRow(ui, .{ .item = item_index })) return;
    buildItemRow(ui, item_index);
}

fn buildItemRow(ui: *Ui, item_index: usize) void {
    // Rows follow the items in order: a row queued for an earlier list
    // would point at the wrong item.
    assert(item_index < ui.items.items.len);
    if (lastItemRow(ui)) |previous| assert(previous < item_index);
    // The grid has no section rows: a child's index is its item's.
    if (ui.grid_mode) assert(ui.rows.items.len == item_index);
    const arena = ui.query_arena.allocator();
    const item = ui.items.items[item_index];
    // Room first: a widget without its `rows` entry would shift every later
    // row's index (and `onRowActivated` would select the wrong item).
    ui.rows.ensureUnusedCapacity(arena, 1) catch return;
    if (ui.grid_mode) {
        const cell_width_px = window_layout.gridCellWidth(ui);
        const cell = widgets.gridCell(&ui.row_look, item, cell_width_px);
        c.gtk_flow_box_append(ui.grid, cell);
        const child = c.gtk_flow_box_get_child_at_index(
            ui.grid,
            @intCast(item_index),
        ) orelse return;
        ui.rows.appendAssumeCapacity(.{ .widget = .{ .grid_cell = child }, .item = item_index });
        return;
    }
    var parts: widgets.RowParts = .{};
    const row = if (item.action == .calc)
        widgets.calcRow(item)
    else
        widgets.itemRow(&ui.row_look, item, &parts);
    const row_tag = ui.rows.items.len + 1;
    c.g_object_set_data(gtk.widget(row), row_index_data_key, @ptrFromInt(row_tag));
    c.gtk_list_box_append(ui.list, gtk.widget(row));
    ui.rows.appendAssumeCapacity(.{
        .widget = .{ .list_row = row },
        .item = item_index,
        .hint = parts.hint,
        .accessory = parts.accessory,
    });
}

/// "No Results" (or the view's empty text) when there is nothing to show,
/// and which of the list, the grid and the results panel show.
pub fn showEmptyOrResults(ui: *Ui, arena: std.mem.Allocator, query_text: []const u8) void {
    const searching = ui.view == .files or ui.view == .contents;
    if (ui.rows.items.len == 0 or (searching and ui.items.items.len == 0)) {
        if (ui.rows.items.len > 0) c.gtk_list_box_remove_all(ui.list);
        ui.rows.clearRetainingCapacity();
        const empty = search.emptyText(ui, arena);
        const row = gtk.listBoxRow();
        c.gtk_list_box_row_set_selectable(row, 0);
        c.gtk_list_box_row_set_activatable(row, 0);
        c.gtk_list_box_row_set_child(row, gtk.widget(widgets.label(empty, "empty")));
        c.gtk_list_box_append(ui.list, gtk.widget(row));
    }
    // A grid shows its cells; the list is there for the "No Results" row.
    gtk.setVisible(ui.grid, ui.grid_mode and ui.items.items.len > 0);
    gtk.setVisible(ui.list, !ui.grid_mode or ui.items.items.len == 0);
    // Nothing typed and nothing to suggest: only the search bar shows.
    const alone = ui.view == .root and query_text.len == 0 and ui.items.items.len == 0;
    gtk.setVisible(ui.results, !alone);
    // One panel with only the search bar showing rounds all its corners.
    gtk.setClass(ui.column, "alone", alone);
}

/// Selects the first row, or the one asked for with `setReselect`.
pub fn selectAfterRefresh(ui: *Ui) void {
    const adjustment = c.gtk_scrolled_window_get_vadjustment(ui.scroller);
    c.gtk_adjustment_set_value(adjustment, 0);
    var first = nextSelectable(ui, null, 1);
    const top = first;
    if (ui.reselect.len > 0) {
        // The row to select back may be any of them.
        ensureRows(ui);
        // A copy: clearing writes into the buffer `slice` points at.
        const reselect = ui.reselect;
        ui.reselect.clear();
        const wanted_key = reselect.slice();
        for (ui.rows.items, 0..) |row, i| {
            const item_index = row.item orelse continue;
            if (std.mem.eql(u8, ui.items.items[item_index].key, wanted_key)) {
                first = i;
                break;
            }
        }
    }
    assert(ui.reselect.len == 0);
    if (first) |row_first| assert(ui.rows.items[row_first].item != null);
    // The list was just scrolled to the top, where the first row is: no
    // need to wait a frame for its place to scroll to it.
    ui.scroll.suppressed = first == top;
    select(ui, first);
    ui.scroll.suppressed = false;
}

/// The first row after `from` (or from either end, when null) in
/// `direction` that shows an item; `from` when there is none.
pub fn nextSelectable(ui: *Ui, from: ?usize, direction: i32) ?usize {
    assert(direction == 1 or direction == -1);
    if (from) |start| assert(start < ui.rows.items.len);
    // Moving up from the end, or down past the last row built so far, needs
    // the rows that are still queued.
    if (ui.pending.items.len > 0) {
        const up_from_end = from == null and direction < 0;
        const down_past_built = if (from) |start|
            direction > 0 and start + 1 >= ui.rows.items.len
        else
            false;
        if (up_from_end or down_past_built) ensureRows(ui);
    }
    const row_count = ui.rows.items.len;
    if (row_count == 0) return null;
    var i: i64 = if (from) |start|
        @as(i64, @intCast(start)) + direction
    else if (direction > 0)
        0
    else
        @as(i64, @intCast(row_count)) - 1;
    while (i >= 0 and i < row_count) : (i += direction) {
        if (ui.rows.items[@intCast(i)].item != null) return @intCast(i);
    }
    return from;
}

pub fn select(ui: *Ui, row_index: ?usize) void {
    assert(ui.built);
    if (row_index) |row_given| assert(row_given < ui.rows.items.len);
    defer assert(ui.selected == row_index);
    if (ui.selected) |previous| if (previous < ui.rows.items.len) {
        const row_old = ui.rows.items[previous];
        if (row_old.hint) |hint| gtk.setVisible(hint, false);
        if (row_old.accessory) |accessory| gtk.setVisible(accessory, true);
    };
    ui.selected = row_index;
    ui.confirm_key = "";
    ui.primary = "";
    const selected_index = row_index orelse {
        setFooterAction(ui, "", .action);
        c.gtk_list_box_unselect_all(ui.list);
        c.gtk_flow_box_unselect_all(ui.grid);
        detail_pane.showDetail(ui, null);
        return;
    };
    const row = ui.rows.items[selected_index];
    // Section titles are never selected (nextSelectable skips them).
    assert(row.item != null);
    assert(row.item.? < ui.items.items.len);
    assert(ui.grid_mode == (row.widget == .grid_cell));
    switch (row.widget) {
        .grid_cell => |cell| c.gtk_flow_box_select_child(ui.grid, cell),
        .list_row => |list_row| c.gtk_list_box_select_row(ui.list, list_row),
    }
    if (!ui.scroll.suppressed) scrollTo(ui, row.widget.widget());
    const item = &ui.items.items[row.item.?];
    ui.primary = item_mod.actionsFor(item)[0].label;
    setHint(ui, ui.primary, .action);
    detail_pane.showDetail(ui, item);
    // Change Theme shows each theme as the selection moves over it, and the
    // theme in use on a style.
    if (ui.view == .themes) {
        const is_theme = item.action == .setting and item.action.setting == .theme;
        const preview: ?*const themes.Theme = if (is_theme)
            themes.find(item.action.setting.theme, config.preferDark(ui), config.customThemes(ui))
        else
            null;
        config.applyAppearance(ui, preview);
    }
}

/// The footer's "what Enter does" (hidden with nothing selected).
fn setFooterAction(ui: *Ui, text: []const u8, tone: HintTone) void {
    const text_z = ui.query_arena.allocator().dupeSentinel(u8, text, 0) catch return;
    ui.footer.setAction(text_z, tone);
}

/// The selected row's hint: "Open ↵", or a warning waiting for Enter (and
/// the footer's, which says the same).
pub fn setHint(ui: *Ui, text: []const u8, tone: HintTone) void {
    const warn = tone == .warning;
    setFooterAction(ui, text, tone);
    if (!ui.layout.show.hints and !warn) return;
    const row_index = ui.selected orelse return;
    const row = ui.rows.items[row_index];
    const hint = row.hint orelse return;
    if (row.accessory) |accessory| gtk.setVisible(accessory, false);
    // Beside the detail pane the list is narrow: the action's name would
    // squeeze the title to a few letters, so only the key shows there.
    const narrow = gtk.isVisible(ui.detail.box);
    const arena = ui.query_arena.allocator();
    const shown = if (warn)
        text
    else if (narrow)
        window_layout.enter_key_text
    else
        arena.print("{s}  " ++ window_layout.enter_key_text, .{text}) catch return;
    const text_z = arena.dupeSentinel(u8, shown, 0) catch return;
    c.gtk_label_set_text(hint, text_z.ptr);
    gtk.setClass(hint, widgets.css_class.warn, warn);
    gtk.setVisible(hint, true);
}

fn scrollTo(ui: *Ui, row: *c.GtkWidget) void {
    var bounds: c.graphene_rect_t = undefined;
    // A row just added has no place yet: it is scrolled to on a later frame,
    // once the list's layout is done.
    const container = if (ui.grid_mode) gtk.widget(ui.grid) else gtk.widget(ui.list);
    const has_bounds = c.gtk_widget_compute_bounds(row, container, &bounds) != 0;
    const placed = has_bounds and bounds.size.height != 0;
    if (!placed) {
        if (ui.scroll.tick == 0) {
            ui.scroll.tries = 0;
            ui.scroll.tick = c.gtk_widget_add_tick_callback(
                gtk.widget(ui.scroller),
                &onScrollTick,
                ui,
                null,
            );
        }
        return;
    }
    const adjustment = c.gtk_scrolled_window_get_vadjustment(ui.scroller);
    const shown_top = c.gtk_adjustment_get_value(adjustment);
    const shown_height = c.gtk_adjustment_get_page_size(adjustment);
    const top: f64 = bounds.origin.y;
    const bottom: f64 = top + bounds.size.height;
    // Keep a section header above the first item visible, and the selection
    // clear of the fade at the bottom edge (style.css, undershoot).
    const fade_px = window_layout.style_css.results_fade_px;
    if (top < shown_top + scroll_top_slack_px) {
        c.gtk_adjustment_set_value(adjustment, @max(top - scroll_section_title_px, 0));
    } else if (bottom > shown_top + shown_height - fade_px) {
        c.gtk_adjustment_set_value(adjustment, bottom - shown_height + fade_px);
    }
}

fn onScrollTick(_: ?*c.GtkWidget, _: ?*c.GdkFrameClock, data: ?*anyopaque) callconv(.c) c.gboolean {
    const ui: *Ui = @ptrCast(@alignCast(data.?));
    ui.scroll.tries += 1;
    const row_index = ui.selected orelse {
        ui.scroll.tick = 0;
        return 0;
    };
    if (row_index >= ui.rows.items.len) {
        ui.scroll.tick = 0;
        return 0;
    }
    const row = ui.rows.items[row_index].widget.widget();
    var bounds: c.graphene_rect_t = undefined;
    const container = if (ui.grid_mode) gtk.widget(ui.grid) else gtk.widget(ui.list);
    const has_bounds = c.gtk_widget_compute_bounds(row, container, &bounds) != 0;
    const placed = has_bounds and bounds.size.height > 0;
    if (!placed and ui.scroll.tries < scroll_frames_max) return 1;
    ui.scroll.tick = 0;
    if (placed) scrollTo(ui, row);
    return 0;
}

pub fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    const row_tag = @intFromPtr(c.g_object_get_data(row, row_index_data_key));
    // 0 is no data at all: a row Lumen did not build (the empty text).
    if (row_tag == 0) return;
    select(ui, row_tag - 1);
    const item = ui.selectedItem() orelse return;
    ui.performEntry(item_mod.actionsFor(item)[0]);
}

pub fn onGridActivated(
    _: *c.GtkFlowBox,
    child: *c.GtkFlowBoxChild,
    data: ?*anyopaque,
) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    const cell_index = c.gtk_flow_box_child_get_index(child);
    if (cell_index < 0 or cell_index >= ui.rows.items.len) return;
    select(ui, @intCast(cell_index));
    const item = ui.selectedItem() orelse return;
    ui.performEntry(item_mod.actionsFor(item)[0]);
}
