//! The launcher window: a gtk4-layer-shell overlay with two floating pieces,
//! the search bar and the results (with an optional detail pane), plus the
//! action panel.
//!
//! One instance lives for the whole daemon; showing and hiding the window is
//! what the global hotkey does. This file holds the window's state and its
//! top-level flow; the parts of that flow live beside it:
//!
//!   show / setView   a view opens: its candidates load (search.loadBase)
//!                    and the window fits it (window_layout.layoutFor);
//!   refresh          each keystroke: search.fill picks the rows, row_list
//!                    builds them and selects one, detail_pane shows it;
//!   keyboard         keys move the selection and run actions (perform);
//!   config           settings.conf, init.lua's overrides, CSS and themes;
//!   dump             `lumen --dump`, the text the end-to-end tests read.
//!
//! The views with state of their own (settings, extensions, preferences,
//! forms, dmenu) are in *_view.zig and dmenu.zig. Main thread only (GTK).

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
pub const View = item_mod.View;
const Db = @import("../sys/Db.zig");
const hypr = @import("../sys/hypr.zig");
const Apps = @import("../providers/Apps.zig");
const run = @import("../actions.zig");
const index = @import("index");
const stats = @import("../stats.zig");
pub const ContentSearch = @import("ContentSearch.zig");
const settings_mod = @import("../settings.zig");
const Settings = settings_mod.Settings;
const widgets = @import("widgets.zig");
const labels = @import("labels.zig");
const settings_view = @import("settings_view.zig");
const choose_view = @import("choose_view.zig");
const file_results = @import("file_results.zig");
const detail_pane = @import("detail_pane.zig");
const backdrop = @import("backdrop.zig");
const keyboard = @import("keyboard.zig");
pub const ext_view = @import("ext_view.zig");
pub const dmenu = @import("dmenu.zig");
pub const installer = @import("installer.zig");
const prefs_view = @import("prefs_view.zig");
const form_view = @import("form_view.zig");
const config = @import("config.zig");
const row_list = @import("row_list.zig");
const search = @import("search.zig");
const window_layout = @import("window_layout.zig");
const ExtHost = @import("../ext/Host.zig");
const ipc = @import("../ipc.zig");
const layout_mod = @import("../layout.zig");
const Inflight = @import("inflight.zig").Inflight;
const ActionPanel = @import("ActionPanel.zig");
const Kind = core.file_kind.Kind;

const Ui = @This();

/// For main: GLib signal connection, the content worker's callback, and
/// the end-to-end tests' `lumen --dump` and `lumen --key`.
pub const connect = widgets.connect;
pub const onContentResult = file_results.onContentResult;
pub const dump = @import("dump.zig").dump;
pub const injectKey = keyboard.injectKey;

// ------------------------------------------------------------ services

gpa: std.mem.Allocator,
io: std.Io,
app: *c.GtkApplication,
db: Db,
apps: Apps,
/// Coalesces the app monitor's bursts (onAppsChanged).
apps_reload_timer: c_uint = 0,
/// File index, started by main once the window exists.
files: ?*index.Service = null,
/// Content (full-text) index, started by main after `files`.
contents: ?*index.ContentService = null,
/// Runs content queries off the UI thread (null: run them inline).
content_search: ?*ContentSearch = null,

// ------------------------------------------------------------- widgets

/// True once `build` has made the widgets; until then every widget field is
/// undefined. `build` reads the settings before it makes them, so
/// `applyLayout` waits for this, and the functions that touch the widgets
/// assert it.
built: bool = false,
window: *c.GtkWindow = undefined,
/// The search bar and the results, sized by the layout settings.
column: *c.GtkBox = undefined,
/// lumen.layout from init.lua (defaults until the files load).
layout: layout_mod.Layout = .{},
/// Takes the room above the results when the search bar is at the bottom.
spacer: *c.GtkBox = undefined,
search_bar: window_layout.SearchBar = undefined,
/// The island holding the results (and the detail pane).
results: *c.GtkBox = undefined,
scroller: *c.GtkScrolledWindow = undefined,
list: *c.GtkListBox = undefined,
/// Extension commands with `grid = true` show their rows here instead.
grid: *c.GtkFlowBox = undefined,
detail: detail_pane.DetailPane = .{},
/// The bar under the results (lumen.layout's footer).
footer: window_layout.Footer = undefined,
/// The action panel (Ctrl K).
panel: ActionPanel = .{},
/// Clear full-screen layers under the window, one per monitor: a click on
/// one (anywhere outside Lumen) hides it.
backdrops: [backdrops_max]?*c.GtkWindow = @splat(null),
frame_clock_hooked: bool = false,

// ------------------------------------------------- the view and its rows

view: View = .root,
/// Views to go back to (Escape, Backspace, the back arrow).
navigation: Navigation = .{},
/// Row to select once the view is built (by its item key).
reselect: ItemKey = .{},
/// Lives until the view changes: clipboard entries, window list, scripts.
data_arena: std.heap.ArenaAllocator,
/// Candidates of the current view before filtering.
base: []Item = &.{},
/// Lives until the next keystroke: the visible items and rows.
query_arena: std.heap.ArenaAllocator,
/// Visible items, in row order.
items: std.ArrayList(Item) = .empty,
rows: std.ArrayList(row_list.Row) = .empty,
/// Rows past the first `row_list.eager_rows`, built after the frame
/// (`row_list.ensureRows` when something needs them sooner). In
/// `query_arena`.
pending: std.ArrayList(row_list.Pending) = .empty,
pending_idle: c_uint = 0,
selected: ?usize = null,
scroll: row_list.Scroll = .{},
/// True while the ext view's command shows its rows in `grid`, of
/// `grid_columns` cells across (window_layout.layoutFor sets both).
grid_mode: bool = false,
grid_columns: c_int = ExtHost.grid_columns_default,
/// How result rows look, for the row builders in widgets.zig.
row_look: widgets.RowLook = .{},
/// Icons made for the current rows; released on the next refresh.
icons: std.ArrayList(*c.GIcon) = .empty,
/// What Enter does on the selected row, shown inside it.
primary: [:0]const u8 = "",
/// Key of the destructive item waiting for its second Enter.
confirm_key: []const u8 = "",
/// Frecency values, reloaded each time the window opens.
frecency_arena: std.heap.ArenaAllocator,
frecency: std.StringHashMapUnmanaged(f64) = .empty,
/// Queries sent to `content_search` and their answers. A keystroke that
/// only sends a new query keeps the rows built from `shown` on screen until
/// its answer arrives.
content_query: Inflight(ContentSearch.Result, ContentSearch.query_bytes_max) = .{},
/// Time spent searching during the current refresh (for `lumen --stats`).
search_ns: u64 = 0,

// ------------------------------------------------- settings and looks

settings: Settings,
/// $XDG_CONFIG_HOME/lumen: settings, init.lua, extensions, style.css.
config_dir: [:0]const u8 = "",
settings_path: [:0]const u8 = "",
/// The settings file's stamp when Lumen last read or wrote it. A different
/// stamp on disk means the file was edited by hand.
settings_stamp: settings_mod.Stamp = .none,
/// Called after the settings change (main starts or stops the clipboard
/// watcher).
on_settings_changed: ?*const fn () void = null,
appearance: config.Appearance = .{},
/// A style was chosen: its lumen.set applies when its registry arrives.
style_defaults_pending: bool = false,
/// ~/.config/lumen/icons as last read (row_look.renamed points into it).
icon_arena: ?std.heap.ArenaAllocator = null,

// ---------------------------------------------------------- extensions

/// Lua extensions and init.lua (null when they could not start).
ext_host: ?*ExtHost = null,
/// What the files define; rows and themes point into it.
ext_registry: ?*ExtHost.Registry = null,
/// The files as last loaded (ExtHost.stamp).
ext_stamp: u64 = 0,
/// The command the ext view shows (its index in the registry).
ext_command: ExtHost.CommandIndex = .from(0),
/// Lists asked of `ext_command` and their answers. The visible items point
/// into the latest one, so it is destroyed only after the rows are built
/// again.
ext_list: Inflight(ExtHost.ListResult, ext_query_bytes_max) = .{},
/// Extension rows asked for the root search, and their answers.
ext_root_search: Inflight(ExtHost.RootResult, ext_query_bytes_max) = .{},
/// The Lua action running (0: none); its answer decides what happens.
ext_act_generation: ExtHost.RequestGeneration = .none,
/// The extension whose preferences the prefs view lists.
prefs_ext: core.FixedStr(extension_id_bytes_max) = .{},
/// What the input view edits: a preference (index in the registry) or a
/// field of the open form.
input: Edited = .{ .pref = .from(0) },
/// The open form (index in the registry) and its fields' values (gpa).
form_command: ExtHost.CommandIndex = .from(0),
form_values: std.ArrayList([:0]u8) = .empty,
/// A message to show on the selected row after the next extension reload.
/// The reload rebuilds every row, so a message set before it would be lost.
after_reload: core.FixedStr(after_reload_message_bytes_max) = .{},
/// True while `after_reload` waits for the next reload. The text itself is
/// never cleared, only replaced, because the row may still point at it.
after_reload_pending: bool = false,

// ---------------------------------------------------------- other views

/// `lumen --dmenu` waiting for an answer.
picker: ?*dmenu.Session = null,
/// What the choose view lists values for.
choosing: Choosing = .none,
choose_title: [choose_title_bytes_max:0]u8 = @splat(0),

/// A value being edited: an extension's preference or a field of the open
/// form (indexes in the registry and the form).
pub const Edited = union(enum) { pref: ExtHost.PreferenceIndex, field: ExtHost.FieldIndex };

pub const Choosing = union(enum) {
    none,
    setting: settings_mod.Choice,
    kind: Kind,
    /// Open With for one file; both strings are owned by `gpa`.
    file: struct { path: [:0]u8, mime: [:0]u8 },
    /// A choice preference of an extension (index in the registry).
    pref: ExtHost.PreferenceIndex,
    /// A choice field of the open form.
    field: ExtHost.FieldIndex,
};

/// The views to go back to, each with the key of the row that was selected
/// there. When it is full, the oldest view is forgotten, so going back
/// always returns through the views left most recently.
const Navigation = struct {
    entries: [capacity]Entry = undefined,
    count: usize = 0,

    const capacity = 8;
    const Entry = struct { view: View, key: ItemKey };

    fn push(navigation: *Navigation, view: View, selected_key: []const u8) void {
        assert(navigation.count <= capacity);
        if (navigation.count == capacity) {
            std.mem.copyForwards(
                Entry,
                navigation.entries[0 .. capacity - 1],
                navigation.entries[1..],
            );
            navigation.count -= 1;
        }
        const entry = &navigation.entries[navigation.count];
        entry.* = .{ .view = view, .key = .{} };
        entry.key.set(selected_key);
        navigation.count += 1;
        assert(navigation.count <= capacity);
    }

    fn pop(navigation: *Navigation) ?Entry {
        assert(navigation.count <= capacity);
        if (navigation.count == 0) return null;
        navigation.count -= 1;
        return navigation.entries[navigation.count];
    }

    fn clear(navigation: *Navigation) void {
        navigation.count = 0;
    }
};

/// The app monitor fires in bursts (an install touches many .desktop files):
/// the list is read once this long after the last one.
const apps_reload_delay_ms = 500;
/// Bytes of an extension query kept with its request (`Inflight.asked`).
const ext_query_bytes_max = 256;
/// Monitors that get a backdrop; past these, a click on one more monitor
/// does not close Lumen.
const backdrops_max = 8;
/// An extension's id, with room to spare over the longest one Host accepts.
const extension_id_bytes_max = 64;
/// A message kept for the row after a reload (a failed install's reason).
const after_reload_message_bytes_max = 160;
/// The choose view's title ("Open Markdown With", a setting's name).
const choose_title_bytes_max = 96;
/// An item's key kept across a rebuild, to select that row again: the row
/// to reselect, and each view on the navigation stack. A key longer than
/// this (a deep file path) is cut, and the row is then not found again:
/// the first row is selected instead.
const ItemKey = core.FixedStr(80);

/// What the view and query arenas keep for next time when reset. They kept
/// all they had ever held: a view that once needed hundreds of MB (the
/// clipboard history loaded whole) held on to them while hidden.
pub const arena_keep: std.heap.ArenaAllocator.ResetMode = .{ .retain_with_limit = 4 << 20 };

comptime {
    assert(extension_id_bytes_max >= ExtHost.id_bytes_max);
    assert(Navigation.capacity > 0);
}

/// End-to-end tests run a second, isolated Lumen (LUMEN_TEST=1): it must not
/// take the keyboard from the session, nor ask Hyprland where to go.
pub fn testMode() bool {
    return c.g_getenv(ipc.env.test_mode) != null;
}

/// Takes `db`. Call `build` before anything else: the widgets are made
/// there. Main thread only (GTK), like every method of Ui.
pub fn init(gpa: std.mem.Allocator, io: std.Io, app: *c.GtkApplication, db: Db) Ui {
    return .{
        .gpa = gpa,
        .io = io,
        .app = app,
        .db = db,
        .apps = .init(gpa),
        .settings = .init(gpa),
        .data_arena = .init(gpa),
        .query_arena = .init(gpa),
        .frecency_arena = .init(gpa),
    };
}

// ------------------------------------------------------------ building

/// Reads the apps and the settings, then makes the window (hidden).
pub fn build(self: *Ui) void {
    self.apps.reload();
    const monitor = c.g_app_info_monitor_get();
    widgets.connect(monitor, "changed", &onAppsChanged, self);

    config.loadCss(self);
    self.config_dir = self.gpa.printSentinel(
        "{s}/lumen",
        .{std.mem.span(c.g_get_user_config_dir())},
        0,
    ) catch "";
    self.settings_path = self.gpa.printSentinel(
        "{s}/settings.conf",
        .{self.config_dir},
        0,
    ) catch "";
    config.watchColorScheme(self);
    config.reloadSettings(self);

    window_layout.build(self);
    self.built = true;
    config.scanIconDir(self);
    window_layout.applyStructure(self);
}

/// After the next rebuild, the row selected now is selected again (by its
/// key), wherever it moved.
pub fn keepSelection(self: *Ui) void {
    if (self.selectedItem()) |item| self.setReselect("{s}", .{item.key});
}

pub fn setReselect(self: *Ui, comptime fmt: []const u8, args: anytype) void {
    self.reselect.print(fmt, args);
}

pub fn actionContext(self: *Ui) run.Context {
    return .{ .gpa = self.gpa, .db = &self.db, .settings = &self.settings };
}

// --------------------------------------------------------- show / hide

pub fn toggle(self: *Ui) void {
    if (gtk.isVisible(self.window)) self.hide() else self.show();
}

pub fn show(self: *Ui) void {
    self.showWith(.root, null);
}

/// Shows `view`, optionally with `text` already typed in the search bar.
pub fn showWith(self: *Ui, view: View, text: ?[*:0]const u8) void {
    assert(self.built);
    const show_start_ns = stats.now();
    const was_hidden = !gtk.isVisible(self.window);
    _ = self.frecency_arena.reset(.retain_capacity);
    // Without it, results are ranked by match quality alone.
    const frecency_arena = self.frecency_arena.allocator();
    self.frecency = self.db.loadFrecency(frecency_arena, labels.now()) catch .empty;
    if (!gtk.isVisible(self.window)) {
        // The settings file may have been edited by hand since the window
        // last opened.
        const settings_stamp = settings_mod.Stamp.of(self.settings_path.ptr);
        if (!settings_stamp.eql(self.settings_stamp)) config.reloadSettings(self);
        if (config.userCssChanged(self)) config.applyAppearance(self, null);
        config.scanIconDir(self);
        ext_view.checkReload(self);
        window_layout.placeOnFocusedMonitor(self);
        // Opening is a good moment to look for edited files.
        if (self.contents) |content_service| content_service.poke();
    }
    self.navigation.clear();
    // The choose view needs a setting to choose for, and the ext view a
    // command to show; without one, their parent view opens instead.
    const choose_has_nothing = view == .choose and self.choosing == .none;
    const ext_has_nothing = view == .ext and ext_view.command(self) == null;
    self.setView(if (choose_has_nothing) .settings else if (ext_has_nothing) .root else view);
    if (text) |initial| c.gtk_editable_set_text(gtk.editable(self.search_bar.entry), initial);
    if (was_hidden) backdrop.showBackdrops(self);
    gtk.setVisible(self.window, true);
    c.gtk_window_present(self.window);
    _ = c.gtk_widget_grab_focus(gtk.widget(self.search_bar.entry));
    // Focusing selects the text; put the cursor at the end instead.
    c.gtk_editable_set_position(gtk.editable(self.search_bar.entry), -1);

    // Time to the first painted frame (the frame clock exists once the
    // window is realized, so it is hooked on the first show).
    if (!self.frame_clock_hooked) {
        if (c.gtk_widget_get_frame_clock(gtk.widget(self.window))) |clock| {
            widgets.connect(clock, "after-paint", &onAfterPaint, null);
            self.frame_clock_hooked = true;
        }
    }
    if (was_hidden) {
        if (stats.pending) |*pending_stats| {
            pending_stats.start_ns = show_start_ns;
            pending_stats.is_show = true;
        }
    }
}

fn onAfterPaint(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    stats.onPainted();
}

/// What the first show used to do while the user waited (~175 ms of it,
/// against ~7 for later shows): the window's surface and its renderer (a
/// Vulkan device), and the root view's rows, styles and text measured. Now
/// ~31 ms. Runs once, hidden, right after the daemon starts.
pub fn prewarm(self: *Ui) void {
    if (gtk.isVisible(self.window)) return;
    c.gtk_widget_realize(gtk.widget(self.window));
    backdrop.prewarmBackdrops(self);
    self.setView(.root);
    var size_px: c_int = 0;
    const window = gtk.widget(self.window);
    c.gtk_widget_measure(window, c.GTK_ORIENTATION_HORIZONTAL, -1, &size_px, null, null, null);
    c.gtk_widget_measure(window, c.GTK_ORIENTATION_VERTICAL, -1, &size_px, null, null, null);
}

pub fn hide(self: *Ui) void {
    assert(self.built);
    // Window actions wait for Hyprland to give the focus back.
    hypr.sendAfterHide();
    dmenu.finish(self, null);
    // Moving through Change Theme previews each theme; hiding without
    // choosing one puts back the theme in use.
    if (self.view == .themes) config.applyAppearance(self, null);
    self.panel.close();
    self.confirm_key = "";
    gtk.setVisible(self.window, false);
    backdrop.hideBackdrops(self);
}

// --------------------------------------------------------------- views

/// Opens `view`, remembering where to go back to.
pub fn navigate(self: *Ui, view: View) void {
    const selected_key = if (self.selectedItem()) |item| item.key else "";
    self.navigation.push(self.view, selected_key);
    self.setView(view);
}

/// Back to the previous view, on the row it was left from.
pub fn goBack(self: *Ui) void {
    const entry = self.navigation.pop() orelse return self.setView(.root);
    self.reselect = entry.key;
    self.setView(entry.view);
}

/// The view's rows again, query and place kept (a setting changed).
pub fn rebuild(self: *Ui) void {
    _ = self.data_arena.reset(arena_keep);
    self.base = search.loadBase(self, self.data_arena.allocator());
    self.refresh();
    // The rows were built again from the current app list, so the lists an
    // earlier reload replaced can be freed.
    self.apps.dropStale();
}

pub fn setView(self: *Ui, view: View) void {
    assert(self.built);
    const leaving_themes = self.view == .themes and view != .themes;
    // Leaving the dmenu view answers the waiting `lumen --dmenu` with
    // nothing.
    if (self.view == .dmenu and view != .dmenu) dmenu.finish(self, null);
    // Change Theme starts on the theme in use.
    if (view == .themes and self.reselect.len == 0) {
        self.setReselect("theme:{s}", .{self.settings.theme});
    }
    self.view = view;
    if (view == .root) self.navigation.clear();
    if (leaving_themes) config.applyAppearance(self, null);
    self.panel.close();
    self.confirm_key = "";
    _ = self.data_arena.reset(arena_keep);
    if (view == .ext) ext_view.enter(self);
    // A password preference hides what is typed.
    c.gtk_text_set_visibility(self.search_bar.entry, @intFromBool(
        !(view == .input and prefs_view.isPassword(self)),
    ));
    self.base = search.loadBase(self, self.data_arena.allocator());

    window_layout.layoutFor(self, view);
    var placeholder_bytes: [128]u8 = undefined;
    c.gtk_text_set_placeholder_text(
        self.search_bar.entry,
        self.placeholderFor(view, &placeholder_bytes),
    );
    c.gtk_label_set_text(self.search_bar.scope, self.viewTitle());
    c.gtk_widget_set_visible(gtk.widget(self.search_bar.scope), @intFromBool(
        view != .root and self.layout.show.scope and self.layout.searchbar.has(.scope),
    ));
    c.gtk_label_set_text(self.footer.title, self.viewTitle());

    // Clearing the text emits `changed`, which refreshes; an entry that is
    // already empty emits nothing, so it is refreshed here.
    const entry_empty = c.gtk_editable_get_text(gtk.editable(self.search_bar.entry))[0] == 0;
    if (entry_empty) {
        self.refresh();
    } else {
        c.gtk_editable_set_text(gtk.editable(self.search_bar.entry), "");
    }
    // The rows are this base's now: nothing points into replaced app lists.
    self.apps.dropStale();
}

/// The view's name: the search bar's scope chip and the footer's title.
pub fn viewTitle(self: *Ui) [*:0]const u8 {
    return switch (self.view) {
        .root => "Lumen",
        .clipboard => "Clipboard History",
        .windows => "Search Windows",
        .files => "Search Files",
        .contents => "Search File Contents",
        .settings => "Settings",
        .themes => "Change Theme",
        .default_apps => "Default Apps",
        .choose => &self.choose_title,
        .ext => if (ext_view.command(self)) |shown| shown.title else "Extension",
        .dmenu => dmenu.title(self),
        .prefs => prefs_view.title(self),
        .input => prefs_view.inputTitle(self),
        .form => form_view.title(self),
    };
}

/// The search bar's text while empty, for `view` (`out` may hold it).
fn placeholderFor(self: *Ui, view: View, out: *[128]u8) [*:0]const u8 {
    // lumen.layout's placeholder: "Go…" at the root, "<view>…" elsewhere.
    if (self.layout.placeholder.len > 0) {
        if (view == .root) return self.layout.placeholder.ptr;
        const title = std.mem.span(self.viewTitle());
        const text = std.mem.printSentinel(out, "{s}…", .{title}, 0) catch return "…";
        return text.ptr;
    }
    return switch (view) {
        .root => "Search for apps and commands...",
        .clipboard => "Type to filter entries...",
        .windows => "Search windows...",
        .files => "Search files...",
        .contents => "Search text inside files...",
        .settings => "Search settings...",
        .themes => "Search themes...",
        .default_apps => "Search file kinds...",
        .choose => if (self.choosing == .setting) "Filter values..." else "Search apps...",
        .ext => ext_view.placeholder(self, out),
        .dmenu => "Filter...",
        .prefs => "Search preferences...",
        .input => prefs_view.inputTitle(self),
        .form => "Search fields...",
    };
}

// ------------------------------------------------------------- refresh

/// The search bar's text, as typed.
pub fn query(self: *Ui) []const u8 {
    return std.mem.span(c.gtk_editable_get_text(gtk.editable(self.search_bar.entry)));
}

/// The rows again for the query: on every keystroke, and when an answer
/// the rows wait for arrives.
pub fn refresh(self: *Ui) void {
    assert(self.built);
    const start_ns = stats.now();
    if (search.answerPending(self, start_ns)) return;
    self.search_ns = 0;
    defer {
        const elapsed_ns = stats.now() - start_ns;
        stats.pending = .{
            .start_ns = start_ns,
            .view = self.view,
            .search_ns = self.search_ns,
            .rows_ns = elapsed_ns -| self.search_ns,
            .is_show = false,
        };
    }
    // The panel lists the actions of a row that is about to go. Keys go to
    // the panel while it is open, so only an answer arriving (a list, the
    // root search, content, an extension reload, an app reload) gets here
    // with it open; an extension row's actions live in that answer's
    // predecessor, which is freed once the rows are rebuilt, and Enter
    // would have run them on whatever row is selected then.
    if (self.panel.isOpen()) self.panel.close();
    assert(!self.panel.isOpen());
    row_list.resetRows(self);
    self.confirm_key = "";
    c.gtk_flow_box_remove_all(self.grid);
    widgets.forgetGridPictures();
    // The rows holding the previous icons are gone; GtkImage kept its refs.
    for (self.icons.items) |icon| c.g_object_unref(icon);
    self.icons.clearRetainingCapacity();

    const arena = self.query_arena.allocator();
    const query_text = std.mem.trim(u8, self.query(), " ");
    search.fill(self, arena, query_text, start_ns);
    row_list.showEmptyOrResults(self, arena, query_text);
    row_list.selectAfterRefresh(self);
    // The grid builds every cell at once: nothing of it waits in `pending`.
    if (self.grid_mode) assert(self.pending.items.len == 0);
    if (self.selected) |row_selected| assert(row_selected < self.rows.items.len);
}

pub fn selectedItem(self: *Ui) ?*Item {
    const row_index = self.selected orelse return null;
    return &self.items.items[self.rows.items[row_index].item orelse return null];
}

// ------------------------------------------------------------- actions

/// Opens the action panel on the selected row's actions.
pub fn openPanel(self: *Ui) void {
    assert(self.built);
    const item = self.selectedItem() orelse return;
    self.panel.show(item_mod.actionsFor(item));
}

/// Runs one of the selected row's actions (a row of the action panel, or
/// what Enter and Ctrl+Enter do).
pub fn performEntry(self: *Ui, entry: item_mod.Entry) void {
    if (entry.operation == .ext) return ext_view.perform(self, entry.index);
    self.perform(entry.operation);
}

/// Destructive commands need a second Enter: true while waiting for it
/// (the row says so).
pub fn needsConfirm(self: *Ui, item: *const Item) bool {
    if (std.mem.eql(u8, self.confirm_key, item.key)) return false;
    self.confirm_key = item.key;
    self.primary = self.query_arena.allocator().printSentinel(
        "Press ↵ again to {s}",
        .{item.title},
        0,
    ) catch return true;
    row_list.setHint(self, self.primary, .warning);
    return true;
}

/// It did not work: say so on the selected row. `message` must outlive the
/// rows.
pub fn showFailure(self: *Ui, message: [:0]const u8) void {
    self.primary = message;
    row_list.setHint(self, message, .warning);
}

/// A Lua action is running.
pub fn showRunning(self: *Ui) void {
    self.primary = "Running...";
    row_list.setHint(self, self.primary, .action);
}

/// Runs `operation` on the selected row.
pub fn perform(self: *Ui, operation: item_mod.Operation) void {
    const item = self.selectedItem() orelse return;
    const primary = operation == .run or operation == .open;
    if (item.confirm and primary and self.needsConfirm(item)) return;
    self.panel.close();
    // Ranking only, and Db logs its own failures: the action goes ahead
    // whether or not the use was recorded.
    if (primary and item.key.len > 0 and item.action != .setting) {
        self.db.recordUse(item.key, labels.now()) catch {};
    }
    if (primary and item.action == .ext_command) {
        return ext_view.activate(self, item.action.ext_command.index);
    }
    if (item.action == .pick) {
        if (operation == .pick_typed) return dmenu.chooseTyped(self);
        return dmenu.choose(self, item.action.pick.index);
    }

    // A clipboard row holds the head of its entry: what is pasted or copied
    // is all of it, read now.
    var whole = item.*;
    var clip_arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer clip_arena.deinit();
    const uses_text = switch (operation) {
        .run, .open, .clip_paste, .clip_copy => true,
        else => false,
    };
    if (item.action == .clip and uses_text) {
        const content = self.db.clipContent(clip_arena.allocator(), item.action.clip) catch null;
        whole.detail = content orelse return self.showFailure("Could not read the entry");
    }
    const outcome = run.perform(self.actionContext(), &whole, operation);
    switch (outcome) {
        .hide => self.hide(),
        .stay => {},
        .refresh_view => self.setView(self.view),
        .open_view => |view| self.navigate(view),
        .setting => |setting_action| {
            settings_view.performSetting(self, setting_action.setting, setting_action.operation);
        },
        .choose_app => |path| choose_view.chooseAppFor(self, path),
        .failed => |message| self.showFailure(message),
    }
}

// ----------------------------------------------------------------- apps

/// An install or update changes many .desktop files: one reload (~5 ms of
/// parsing) for the burst. Hidden, the next show builds its view anew.
fn onAppsChanged(_: *c.GAppInfoMonitor, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    if (self.apps_reload_timer == 0) {
        self.apps_reload_timer = c.g_timeout_add(apps_reload_delay_ms, &reloadApps, self);
    }
}

fn reloadApps(data: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Ui = @ptrCast(@alignCast(data));
    self.apps_reload_timer = 0;
    self.apps.reload();
    if (gtk.isVisible(self.window)) {
        self.keepSelection();
        self.rebuild();
    } else {
        // Hidden, nothing needs the replaced list before the next show
        // builds its view anew: it goes now, with the rows and candidates
        // pointing into it (their widgets hold their own references). Each
        // reload while hidden kept one more until then, and a long upgrade
        // reloads many times.
        row_list.clearRows(self);
        self.base = &.{};
        self.apps.dropStale();
    }
    return 0;
}

test {
    _ = @import("dmenu.zig");
    _ = @import("inflight.zig");
    _ = @import("window_layout.zig");
    _ = @import("row_list.zig");
    _ = @import("search.zig");
    _ = @import("config.zig");
    _ = @import("dump.zig");
    _ = @import("ActionPanel.zig");
    _ = @import("choose_view.zig");
}

test "Navigation forgets the oldest view when it is full" {
    var navigation: Navigation = .{};
    const views = [_]View{
        .settings, .themes, .files, .contents, .clipboard,
        .windows,  .prefs,  .form,  .choose,   .input,
    };
    for (views, 0..) |view, i| {
        var key_buffer: [8]u8 = undefined;
        navigation.push(view, try std.fmt.bufPrint(&key_buffer, "row{d}", .{i}));
    }
    try std.testing.expectEqual(Navigation.capacity, navigation.count);
    // The last `capacity` views come back newest first.
    var expected = views.len;
    while (navigation.pop()) |entry| {
        expected -= 1;
        try std.testing.expectEqual(views[expected], entry.view);
        var key_buffer: [8]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&key_buffer, "row{d}", .{expected}),
            entry.key.slice(),
        );
    }
    try std.testing.expectEqual(views.len - Navigation.capacity, expected);
}
