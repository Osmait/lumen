//! The launcher window: a gtk4-layer-shell overlay with two floating pieces,
//! the search bar and the results (with an optional detail pane), plus the
//! action panel.
//!
//! One instance lives for the whole daemon; showing and hiding the window is
//! what the global hotkey does.

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
const commands = @import("../providers/commands.zig");
const scripts = @import("../providers/scripts.zig");
const run = @import("../actions.zig");
const index = @import("index");
const os = @import("os");
const styles = @import("styles");
const stats = @import("../stats.zig");
pub const ContentSearch = @import("ContentSearch.zig");
const settings_mod = @import("../settings.zig");
const Settings = settings_mod.Settings;
const themes = @import("themes.zig");
const widgets = @import("widgets.zig");
const labels = @import("labels.zig");
const settings_view = @import("settings_view.zig");
const file_results = @import("file_results.zig");
const detail_pane = @import("detail_pane.zig");
const backdrop = @import("backdrop.zig");
const keyboard = @import("keyboard.zig");
pub const ext_view = @import("ext_view.zig");
pub const dmenu = @import("dmenu.zig");
pub const installer = @import("installer.zig");
const prefs_view = @import("prefs_view.zig");
const form_view = @import("form_view.zig");
const ExtHost = @import("../ext/Host.zig");
const ipc = @import("../ipc.zig");
const layout_mod = @import("../layout.zig");
const Inflight = @import("inflight.zig").Inflight;
const ActionPanel = @import("ActionPanel.zig");
const Kind = core.file_kind.Kind;

const Ui = @This();

/// For main: GLib signal connection and the content worker's callback.
pub const connect = widgets.connect;
pub const onContentResult = file_results.onContentResult;

const log = std.log.scoped(.ui);

/// Sizes style.css sets that the window's arithmetic depends on. The test
/// "style.css has the sizes Ui computes with" reads the stylesheet and
/// fails when one side changes without the other.
const style_css = struct {
    /// `.search { min-height }`.
    const search_height_px = 56;
    /// `.results-island { padding; border }`, on each side.
    const results_padding_px = 6;
    const results_border_px = 1;
    /// `.shell { margin }`: clear space around the pieces for their shadows.
    const shell_margin_px = 48;
    /// `.grid > flowboxchild { padding }`, on the left and on the right.
    const grid_cell_padding_px = 6;
    /// The undershoot fade at the list's edges (`background-size`).
    const results_fade_px = 20;
};

/// Between the pieces of a split layout: the column's spacing.
const pieces_gap_px = 10;
/// The footer bar's height (lumen.layout's footer).
const footer_height_px = 40;
/// Between the grid's cells, across and down.
const grid_spacing_px = 6;
/// What the grid loses to the island's and its own padding, both sides.
const grid_frame_px = 24;
/// Room kept above the selection when scrolling up, so the section title
/// over the first item of a section stays in view.
const scroll_section_title_px = 30;
/// How close to the top edge a row may be before the list scrolls up.
const scroll_top_slack_px = 4;
/// Frames to wait for a new row's place before giving up scrolling to it.
const scroll_frames_max = 10;
/// Rows built per idle callback after the first frame (see `eager_rows`).
const pending_rows_per_idle = 16;
/// The app monitor fires in bursts (an install touches many .desktop files):
/// the list is read once this long after the last one.
const apps_reload_delay_ms = 500;

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
/// Bytes of an extension query kept with its request (`Inflight.asked`).
const ext_query_bytes_max = 256;
/// The keys that open the action panel and run the selection, as the
/// search bar's chip, the footer and the rows show them.
const actions_keys_text = "Ctrl K";
const enter_key_text = "↵";
/// The footer's two labels: what Enter does, and "Actions".
const footer_action_class = "footer-action";
/// Monitors that get a backdrop; past these, a click on one more monitor
/// does not close Lumen.
const backdrops_max = 8;
/// An extension's id, with room to spare over the longest one Host accepts.
const extension_id_bytes_max = 64;

comptime {
    assert(extension_id_bytes_max >= ExtHost.id_bytes_max);
}
/// A message kept for the row after a reload (a failed install's reason).
const after_reload_message_bytes_max = 160;
/// The choose view's title ("Open Markdown With", a setting's name).
const choose_title_bytes_max = 96;
/// An item's key kept across a rebuild, to select that row again: the row
/// to reselect, and each view on the navigation stack. A key longer than
/// this (a deep file path) is cut, and the row is then not found again:
/// the first row is selected instead.
const ItemKey = core.FixedStr(80);
/// Where Center and Upper Third put the pieces: the room above them, in
/// tenths of the room the monitor leaves above and below.
const position_center_tenths = 5;
const position_upper_third_tenths = 3;

gpa: std.mem.Allocator,
io: std.Io,
app: *c.GtkApplication,
db: Db,
apps: Apps,
/// Coalesces the app monitor's bursts (onAppsChanged).
apps_reload_timer: c_uint = 0,

window: *c.GtkWindow = undefined,
/// The search bar and the results, sized by the layout settings.
column: *c.GtkBox = undefined,
/// lumen.layout from init.lua (defaults until the files load).
layout: layout_mod.Layout = .{},
/// Takes the room above the results when the search bar is at the bottom.
spacer: *c.GtkBox = undefined,
/// The bar under the results (lumen.layout's footer).
footer: Footer = undefined,
search_bar: SearchBar = undefined,
/// True once `build` has made the widgets; until then every widget field is
/// undefined. `build` reads the settings before it makes them, so
/// `applyLayout` waits for this, and the functions that touch the widgets
/// assert it.
built: bool = false,
list: *c.GtkListBox = undefined,
/// Extension commands with `grid = true` show their rows here instead.
grid: *c.GtkFlowBox = undefined,
grid_mode: bool = false,
grid_columns: c_int = ExtHost.grid_columns_default,
scroller: *c.GtkScrolledWindow = undefined,
detail: detail_pane.DetailPane = .{},
/// File index, started by main once the window exists.
files: ?*index.Service = null,
/// Content (full-text) index, started by main after `files`.
contents: ?*index.ContentService = null,
/// Runs content queries off the UI thread (null: run them inline).
content_search: ?*ContentSearch = null,
/// Queries sent to `content_search` and their answers. A keystroke that
/// only sends a new query keeps the rows built from `shown` on screen until
/// its answer arrives.
content_query: Inflight(ContentSearch.Result, ContentSearch.query_bytes_max) = .{},
/// Time spent searching during the current refresh (for `lumen --stats`).
search_ns: u64 = 0,
frame_clock_hooked: bool = false,
/// Icons made for the current rows; released on the next refresh.
icons: std.ArrayList(*c.GIcon) = .empty,
/// The island holding the results (and the detail pane).
results: *c.GtkBox = undefined,
/// Clear full-screen layers under the window, one per monitor: a click on
/// one (anywhere outside Lumen) hides it.
backdrops: [backdrops_max]?*c.GtkWindow = @splat(null),
/// What Enter does on the selected row, shown inside it.
primary: [:0]const u8 = "",
/// The action panel (Ctrl K).
panel: ActionPanel = .{},

view: View = .root,
/// Lives until the view changes: clipboard entries, window list, scripts.
data_arena: std.heap.ArenaAllocator,
/// Lives until the next keystroke: the visible items and rows.
query_arena: std.heap.ArenaAllocator,
/// Frecency values, reloaded each time the window opens.
frecency_arena: std.heap.ArenaAllocator,
frecency: std.StringHashMapUnmanaged(f64) = .empty,

/// Candidates of the current view before filtering.
base: []Item = &.{},
/// Visible items, in row order.
items: std.ArrayList(Item) = .empty,
rows: std.ArrayList(Row) = .empty,
/// Rows past the first `eager_rows`, built after the frame (`ensureRows`
/// when something needs them sooner). In `query_arena`.
pending: std.ArrayList(Pending) = .empty,
pending_idle: c_uint = 0,
selected: ?usize = null,

/// Key of the destructive item waiting for its second Enter.
confirm_key: []const u8 = "",

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
appearance: Appearance = .{},
/// A style was chosen: its lumen.set applies when its registry arrives.
style_defaults_pending: bool = false,
scroll: Scroll = .{},

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
/// How result rows look, for the row builders in widgets.zig.
row_look: widgets.RowLook = .{},
/// ~/.config/lumen/icons as last read (row_look.renamed points into it).
icon_arena: ?std.heap.ArenaAllocator = null,
/// A message to show on the selected row after the next extension reload.
/// The reload rebuilds every row, so a message set before it would be lost.
after_reload: core.FixedStr(after_reload_message_bytes_max) = .{},
/// True while `after_reload` waits for the next reload. The text itself is
/// never cleared, only replaced, because the row may still point at it.
after_reload_pending: bool = false,
/// `lumen --dmenu` waiting for an answer.
picker: ?*dmenu.Session = null,
/// What the choose view lists values for.
choosing: Choosing = .none,
choose_title: [choose_title_bytes_max:0]u8 = @splat(0),
/// Views to go back to (Escape, Backspace, the back arrow).
navigation: Navigation = .{},
/// Row to select once the view is built (by its item key).
reselect: ItemKey = .{},

/// The back arrow, magnifier, prompt, scope chip, text field and Ctrl K chip.
const SearchBar = struct {
    box: *c.GtkBox,
    back: *c.GtkWidget,
    /// The magnifier before the text.
    icon: *c.GtkWidget,
    /// lumen.layout's prompt (rofi's "drun"), before the text.
    prompt: *c.GtkLabel,
    /// The view's name (hidden in the root view).
    scope: *c.GtkLabel,
    entry: *c.GtkText,
    key_chip: *c.GtkWidget,
};

/// The view's name, what Enter does, and Actions.
const Footer = struct {
    box: *c.GtkBox,
    title: *c.GtkLabel,
    action: *c.GtkLabel,
    enter: *c.GtkLabel,
    separator: *c.GtkLabel,

    /// What Enter does on the selected row, or a warning waiting for Enter.
    fn setAction(footer: *const Footer, text: [:0]const u8, tone: HintTone) void {
        const warn = tone == .warning;
        c.gtk_label_set_text(footer.action, text.ptr);
        gtk.setClass(footer.action, widgets.css_class.warn, warn);
        const any = text.len > 0;
        gtk.setVisible(footer.action, any);
        gtk.setVisible(footer.enter, any and !warn);
        gtk.setVisible(footer.separator, any);
    }
};

/// Lumen's CSS and what it was built from.
const Appearance = struct {
    css: *c.GtkCssProvider = undefined,
    css_hash: u64 = 0,
    /// The user's style.css as last read (it is applied after Lumen's).
    user_css_stamp: settings_mod.Stamp = .none,
    /// The style folder's style.css, likewise (built-in styles have none).
    style_css_stamp: settings_mod.Stamp = .none,
    /// Search highlight colours of the theme, for Pango markup.
    highlight_foreground: [8]u8 = "#ffffff\x00".*,
    highlight_background: [8]u8 = "#ff6363\x00".*,
    /// org.gnome.desktop.interface, for the "Automatic" theme.
    interface_settings: ?*c.GSettings = null,
};

/// Scrolling to the selection once the rebuilt list has its layout.
const Scroll = struct {
    /// The tick callback waiting for the layout (0: none).
    tick: c_uint = 0,
    /// Set while `refresh` selects the first row (see there).
    suppressed: bool = false,
    tries: u8 = 0,
};

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

/// `hint` shows the primary action while the row is selected, in place of
/// `accessory`.
const Row = struct {
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
const Pending = union(enum) { item: usize, section: [:0]const u8 };

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

/// The settings lumen.layout can fix with its own pixels and place.
const LayoutSetting = enum { width, height, position };

/// The values `color_scheme_key` takes. "default" is the desktop's own
/// default, which is light.
const ColorScheme = enum { default, @"prefer-dark", @"prefer-light" };

/// How a filtered list shows with nothing typed: the clipboard in Today,
/// Yesterday and Earlier, the windows as they come.
const Grouping = enum { by_day, flat };

/// A hint says what Enter does, or warns that Enter is waiting for a
/// second press (a destructive action) or that something failed.
const HintTone = enum { action, warning };

/// The pieces' width in px: lumen.layout's, else the Width setting's.
fn panelWidth(self: *const Ui) c_int {
    if (self.layout.width) |width_px| return width_px;
    return switch (self.settings.width) {
        .narrow => 620,
        .default => 750,
        .wide => 920,
    };
}

/// The pieces' height in px: lumen.layout's, else the Height setting's.
fn panelHeight(self: *const Ui) c_int {
    if (self.layout.height) |height_px| return height_px;
    return switch (self.settings.height) {
        .short => 380,
        .default => 474,
        .tall => 640,
    };
}

/// The list's height limit: what is left beside the search bar, the
/// results' padding and border, the footer and the gaps between pieces
/// (none in a single panel).
fn listHeightMax(self: *const Ui) c_int {
    const gap_px: c_int = if (self.layout.panels == .split) pieces_gap_px else 0;
    const footer_px: c_int = if (self.layout.footer) footer_height_px + gap_px else 0;
    const results_frame_px = 2 * (style_css.results_padding_px + style_css.results_border_px);
    return self.panelHeight() - style_css.search_height_px - results_frame_px - gap_px - footer_px;
}

/// Rows built in the keystroke's frame: the ~8 the list shows and a few to
/// scroll into. Building all 61 file rows (~430 widgets) per key cost ~14 of
/// the view's 23 ms, because GTK laid out every one.
const eager_rows = 14;

comptime {
    // The first screen of every search is built in the keystroke's frame.
    assert(eager_rows > 0);
    assert(eager_rows <= content_results_max);
    assert(root_results_before_files_max <= root_results_max);
    assert(root_files_max <= file_results_max);
    assert(Navigation.capacity > 0);
    assert(suggestions_max <= root_results_max);
    // Rows built after the first frame come in smaller batches than the
    // first frame's, or an idle callback would take a frame of its own.
    assert(pending_rows_per_idle <= eager_rows + 2);
    assert(position_upper_third_tenths < position_center_tenths);
    assert(position_center_tenths <= 10); // Tenths: 10 is the whole room.
    assert(content_query_bytes_min <= ContentSearch.query_bytes_max);
}

/// What the view and query arenas keep for next time when reset. They kept
/// all they had ever held: a view that once needed hundreds of MB (the
/// clipboard history loaded whole) held on to them while hidden.
const arena_keep: std.heap.ArenaAllocator.ResetMode = .{ .retain_with_limit = 4 << 20 };

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

pub fn build(self: *Ui) void {
    self.apps.reload();
    const monitor = c.g_app_info_monitor_get();
    widgets.connect(monitor, "changed", &onAppsChanged, self);

    self.loadCss();
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
    self.watchColorScheme();
    self.reloadSettings();

    const overlay = self.buildWindow();
    // Two pieces on a transparent surface: the search bar and, below it, the
    // results, as tall as their rows (the rest of the surface stays clear).
    const column = widgets.vbox(10);
    self.column = column;
    gtk.addClass(column, "shell");
    gtk.setSizeRequest(column, self.panelWidth(), self.panelHeight());
    c.gtk_overlay_set_child(overlay, gtk.widget(column));

    self.buildSearchBar(column);
    self.buildResults(column);
    self.buildFooter(column);
    self.panel.build(self, overlay);
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    widgets.connect(keys, "key-pressed", &onKey, self);
    c.gtk_widget_add_controller(gtk.widget(self.window), keys);

    // A click on the clear part of the surface hides the window, like one on
    // the backdrop. Capture phase: it sees every press, and claims none.
    const click = c.gtk_gesture_click_new();
    c.gtk_event_controller_set_propagation_phase(click, c.GTK_PHASE_CAPTURE);
    widgets.connect(click, "pressed", &backdrop.onWindowPressed, self);
    c.gtk_widget_add_controller(gtk.widget(self.window), click);
    self.built = true;
    self.scanIconDir();
    self.applyStructure();
}

/// The layer-shell window and the overlay everything goes in.
fn buildWindow(self: *Ui) *c.GtkOverlay {
    const window = gtk.window(self.app);
    self.window = window;
    gtk.addClass(window, "lumen");
    c.gtk_window_set_title(window, "Lumen");
    c.gtk_window_set_resizable(window, 0);
    c.gtk_window_set_decorated(window, 0);
    // A fixed size: the layer surface would otherwise grow to its content's
    // natural size (a large image preview, a long path).
    c.gtk_window_set_default_size(
        window,
        self.panelWidth() + 2 * style_css.shell_margin_px,
        self.panelHeight() + 2 * style_css.shell_margin_px,
    );

    c.gtk_layer_init_for_window(window);
    c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    const keyboard_mode = if (testMode())
        c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE
    else
        c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE;
    c.gtk_layer_set_keyboard_mode(window, keyboard_mode);
    c.gtk_layer_set_namespace(window, "lumen");
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, 1);

    const overlay = gtk.overlay();
    c.gtk_window_set_child(window, gtk.widget(overlay));
    return overlay;
}

/// The back arrow, magnifier, prompt, scope, entry and Ctrl K chip.
fn buildSearchBar(self: *Ui, column: *c.GtkBox) void {
    const search = widgets.hbox(0);
    gtk.addClass(search, "search");
    self.search_bar.box = search;
    self.search_bar.back = c.gtk_image_new_from_icon_name("go-previous-symbolic");
    gtk.addClass(self.search_bar.back, "back");
    gtk.setValign(self.search_bar.back, c.GTK_ALIGN_CENTER);
    // An image has no click of its own: a gesture makes it the back button.
    c.gtk_widget_set_cursor_from_name(self.search_bar.back, "pointer");
    const back_click = c.gtk_gesture_click_new();
    widgets.connect(back_click, "released", &onBackClicked, self);
    c.gtk_widget_add_controller(self.search_bar.back, back_click);
    gtk.append(search, self.search_bar.back);
    self.search_bar.icon = c.gtk_image_new_from_icon_name("system-search-symbolic");
    gtk.addClass(self.search_bar.icon, "search-icon");
    gtk.setValign(self.search_bar.icon, c.GTK_ALIGN_CENTER);
    gtk.setVisible(self.search_bar.icon, false);
    gtk.append(search, self.search_bar.icon);
    self.search_bar.prompt = widgets.label("", "prompt");
    gtk.setValign(self.search_bar.prompt, c.GTK_ALIGN_CENTER);
    gtk.setVisible(self.search_bar.prompt, false);
    gtk.append(search, self.search_bar.prompt);
    self.search_bar.scope = widgets.label("", "scope");
    gtk.setValign(self.search_bar.scope, c.GTK_ALIGN_CENTER);
    gtk.setVisible(self.search_bar.scope, false);
    gtk.append(search, self.search_bar.scope);
    self.search_bar.entry = gtk.textField();
    gtk.addClass(self.search_bar.entry, "query");
    gtk.setHexpand(self.search_bar.entry, true);
    gtk.setValign(self.search_bar.entry, c.GTK_ALIGN_CENTER);
    gtk.append(search, self.search_bar.entry);
    widgets.connect(self.search_bar.entry, "changed", &onChanged, self);
    const key_chip = widgets.label(actions_keys_text, widgets.css_class.keys);
    self.search_bar.key_chip = gtk.widget(key_chip);
    gtk.setValign(key_chip, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_tooltip_text(gtk.widget(key_chip), "Actions");
    gtk.append(search, key_chip);
    self.spacer = widgets.vbox(0);
    gtk.setVexpand(self.spacer, true);
    gtk.setVisible(self.spacer, false);
    gtk.append(column, self.spacer);
    gtk.append(column, search);
}

/// The list and the grid in their scroller, beside the detail pane.
fn buildResults(self: *Ui, column: *c.GtkBox) void {
    const body = widgets.hbox(0);
    gtk.addClass(body, "results-island");
    self.results = body;
    self.scroller = gtk.scrolledWindow();
    c.gtk_scrolled_window_set_policy(
        self.scroller,
        c.GTK_POLICY_NEVER,
        c.GTK_POLICY_AUTOMATIC,
    );
    // As tall as the rows, up to the space left under the search bar.
    c.gtk_scrolled_window_set_propagate_natural_height(self.scroller, 1);
    c.gtk_scrolled_window_set_max_content_height(self.scroller, self.listHeightMax());
    gtk.setHexpand(self.scroller, true);
    self.list = gtk.listBox();
    gtk.addClass(self.list, "results");
    c.gtk_list_box_set_selection_mode(self.list, c.GTK_SELECTION_SINGLE);
    gtk.setFocusable(self.list, false);
    widgets.connect(self.list, "row-activated", &onRowActivated, self);
    self.grid = gtk.flowBox();
    gtk.addClass(self.grid, "grid");
    c.gtk_flow_box_set_selection_mode(self.grid, c.GTK_SELECTION_SINGLE);
    c.gtk_flow_box_set_homogeneous(self.grid, 1);
    c.gtk_flow_box_set_activate_on_single_click(self.grid, 1);
    c.gtk_flow_box_set_row_spacing(self.grid, grid_spacing_px);
    c.gtk_flow_box_set_column_spacing(self.grid, grid_spacing_px);
    gtk.setFocusable(self.grid, false);
    gtk.setValign(self.grid, c.GTK_ALIGN_START);
    gtk.setVisible(self.grid, false);
    widgets.connect(self.grid, "child-activated", &onGridActivated, self);
    // The list and the grid share the scroller; showEmptyOrResults shows one
    // of them at a time.
    const lists = widgets.vbox(0);
    gtk.append(lists, self.list);
    gtk.append(lists, self.grid);
    c.gtk_scrolled_window_set_child(self.scroller, gtk.widget(lists));
    gtk.append(body, self.scroller);
    detail_pane.buildDetail(self);
    gtk.append(body, self.detail.box);
    gtk.append(column, body);
}

/// The footer (lumen.layout { footer = true }): title, action, keys.
fn buildFooter(self: *Ui, column: *c.GtkBox) void {
    self.footer.box = widgets.hbox(8);
    gtk.addClass(self.footer.box, "footer");
    gtk.setSizeRequest(self.footer.box, -1, footer_height_px);
    self.footer.title = widgets.label("Lumen", "footer-title");
    gtk.setHexpand(self.footer.title, true);
    c.gtk_label_set_xalign(self.footer.title, 0);
    c.gtk_label_set_ellipsize(self.footer.title, c.PANGO_ELLIPSIZE_END);
    gtk.append(self.footer.box, self.footer.title);
    self.footer.action = widgets.label("", footer_action_class);
    gtk.append(self.footer.box, self.footer.action);
    self.footer.enter = widgets.label(enter_key_text, widgets.css_class.keys);
    gtk.setValign(self.footer.enter, c.GTK_ALIGN_CENTER);
    gtk.append(self.footer.box, self.footer.enter);
    self.footer.separator = widgets.label("", "footer-sep");
    gtk.setValign(self.footer.separator, c.GTK_ALIGN_CENTER);
    gtk.append(self.footer.box, self.footer.separator);
    gtk.append(self.footer.box, widgets.label("Actions", footer_action_class));
    const actions_key_label = widgets.label(actions_keys_text, widgets.css_class.keys);
    gtk.setValign(actions_key_label, c.GTK_ALIGN_CENTER);
    gtk.append(self.footer.box, actions_key_label);
    gtk.setVisible(self.footer.box, false);
    gtk.append(column, self.footer.box);
}

/// ~/.config/lumen/icons/<name>.svg|png replaces the icon <name> everywhere
/// (row_look.renamed). Read when the window opens: a handful of files.
fn scanIconDir(self: *Ui) void {
    self.row_look.renamed = .empty;
    if (self.icon_arena) |*icon_arena| {
        _ = icon_arena.reset(.retain_capacity);
    } else {
        self.icon_arena = .init(self.gpa);
    }
    const arena = self.icon_arena.?.allocator();
    const icons_path = arena.printSentinel("{s}/icons", .{self.config_dir}, 0) catch return;
    const icons_folder = c.g_dir_open(icons_path.ptr, 0, null) orelse return;
    defer c.g_dir_close(icons_folder);
    while (c.g_dir_read_name(icons_folder)) |name_z| {
        const name = std.mem.span(name_z);
        const dot = std.mem.findScalarLast(u8, name, '.') orelse continue;
        const extension = name[dot + 1 ..];
        const svg = std.ascii.eqlIgnoreCase(extension, "svg");
        const png = std.ascii.eqlIgnoreCase(extension, "png");
        if (!svg and !png) continue;
        const path = arena.printSentinel("{s}/{s}", .{ icons_path, name }, 0) catch continue;
        self.row_look.renamed.put(
            arena,
            arena.dupe(u8, name[0..dot]) catch continue,
            path,
        ) catch continue;
    }
}

/// The icon init.lua gave the item with `key` (lumen.icons), if any.
pub fn keyIcon(self: *const Ui, key: []const u8) ?item_mod.Icon {
    const registry = self.ext_registry orelse return null;
    if (key.len == 0) return null;
    for (registry.icons) |override| if (std.mem.eql(u8, override.key, key)) return override.icon;
    return null;
}

/// The search bar's widget for `part`.
fn barWidget(self: *Ui, part: layout_mod.BarPart) *c.GtkWidget {
    return switch (part) {
        .back => self.search_bar.back,
        .icon => self.search_bar.icon,
        .prompt => gtk.widget(self.search_bar.prompt),
        .scope => gtk.widget(self.search_bar.scope),
        .entry => gtk.widget(self.search_bar.entry),
        .keys => self.search_bar.key_chip,
    };
}

/// lumen.layout: the pieces' order, one panel or two, the footer, the
/// detail pane's side, what rows show; then the size. The caller rebuilds
/// the rows.
pub fn applyStructure(self: *Ui) void {
    assert(self.built);
    const layout = self.layout;
    self.row_look.show = layout.show;
    self.row_look.rows_inline = layout.rows == .@"inline";
    self.row_look.parts = layout.row;
    // The search bar's parts in order; setView decides which of them show.
    const bar: *c.GtkBox = self.search_bar.box;
    var previous: ?*c.GtkWidget = null;
    for (layout.searchbar.slice()) |part| {
        const widget = self.barWidget(part);
        c.gtk_box_reorder_child_after(bar, widget, previous);
        previous = widget;
    }
    c.gtk_label_set_text(self.search_bar.prompt, layout.prompt.ptr);
    c.gtk_widget_set_visible(gtk.widget(self.search_bar.prompt), @intFromBool(
        layout.prompt.len > 0 and layout.searchbar.has(.prompt),
    ));
    c.gtk_widget_set_visible(self.search_bar.icon, @intFromBool(
        layout.show.search_icon and layout.searchbar.has(.icon),
    ));
    const column_box: *c.GtkBox = self.column;
    c.gtk_box_set_spacing(column_box, if (layout.panels == .single) 0 else pieces_gap_px);
    gtk.setClass(self.column, "single", layout.panels == .single);
    gtk.setClass(self.column, "search-bottom", layout.search == .bottom);
    gtk.setClass(self.column, "with-footer", layout.footer);
    // The spacer first, then the search bar and the results in the chosen
    // order, the footer last.
    c.gtk_box_reorder_child_after(column_box, gtk.widget(self.spacer), null);
    const first, const second = if (layout.search == .bottom)
        .{ self.results, self.search_bar.box }
    else
        .{ self.search_bar.box, self.results };
    c.gtk_box_reorder_child_after(column_box, gtk.widget(first), gtk.widget(self.spacer));
    c.gtk_box_reorder_child_after(column_box, gtk.widget(second), gtk.widget(first));
    c.gtk_box_reorder_child_after(column_box, gtk.widget(self.footer.box), gtk.widget(second));
    gtk.setVisible(self.spacer, layout.search == .bottom);
    gtk.setVisible(self.footer.box, layout.footer);
    c.gtk_widget_set_visible(self.search_bar.key_chip, @intFromBool(
        layout.show.key_hints and layout.searchbar.has(.keys),
    ));
    // With a footer, or the search bar at the bottom, the action panel opens
    // down there, above them.
    c.gtk_widget_set_valign(
        gtk.widget(self.panel.box),
        if (layout.footer or layout.search == .bottom) c.GTK_ALIGN_END else c.GTK_ALIGN_START,
    );
    gtk.setClass(self.panel.box, "from-footer", layout.footer);
    gtk.setClass(self.panel.box, "from-bottom", layout.search == .bottom);

    const island: *c.GtkBox = self.results;
    c.gtk_orientable_set_orientation(
        self.results,
        if (layout.detail == .bottom) c.GTK_ORIENTATION_VERTICAL else c.GTK_ORIENTATION_HORIZONTAL,
    );
    // Null puts the detail pane first: on the left of the list.
    const detail_after: ?*c.GtkWidget = switch (layout.detail) {
        .left => null,
        else => gtk.widget(self.scroller),
    };
    c.gtk_box_reorder_child_after(island, gtk.widget(self.detail.box), detail_after);
    gtk.setClass(self.results, "detail-left", layout.detail == .left);
    gtk.setClass(self.results, "detail-bottom", layout.detail == .bottom);
    self.applyLayout();
}

/// Width, height and density from the settings. A layer surface takes its
/// size when it is mapped: a change while it shows maps it again.
fn applyLayout(self: *Ui) void {
    self.row_look.icon_px = themes.densitySizes(self.settings.density).icon_px;
    if (!self.built) return;
    const width_px = self.panelWidth();
    const height_px = self.panelHeight();
    c.gtk_scrolled_window_set_max_content_height(self.scroller, self.listHeightMax());
    var width_current_px: c_int = 0;
    var height_current_px: c_int = 0;
    c.gtk_widget_get_size_request(gtk.widget(self.column), &width_current_px, &height_current_px);
    if (width_current_px == width_px and height_current_px == height_px) return;
    gtk.setSizeRequest(self.column, width_px, height_px);
    c.gtk_window_set_default_size(
        self.window,
        width_px + 2 * style_css.shell_margin_px,
        height_px + 2 * style_css.shell_margin_px,
    );
    if (gtk.isVisible(self.window)) {
        gtk.setVisible(self.window, false);
        gtk.setVisible(self.window, true);
        _ = c.gtk_widget_grab_focus(gtk.widget(self.search_bar.entry));
    }
    // The list beside a detail pane keeps ~40% of the width.
    if (gtk.isVisible(self.detail.box)) {
        gtk.setSizeRequest(self.scroller, @divTrunc(width_px * 2, 5), -1);
    }
}

fn loadCss(self: *Ui) void {
    self.appearance.css = c.gtk_css_provider_new();
    const display = c.gdk_display_get_default() orelse return;
    c.gtk_style_context_add_provider_for_display(
        display,
        @ptrCast(self.appearance.css),
        c.GTK_STYLE_PROVIDER_PRIORITY_USER,
    );
}

// ------------------------------------------------------------ settings

/// Reads the settings file again and applies it, init.lua's settings over it.
pub fn reloadSettings(self: *Ui) void {
    const fresh = Settings.load(self.gpa, self.settings_path.ptr);
    self.settings.deinit();
    self.settings = fresh;
    self.settings_stamp = settings_mod.Stamp.of(self.settings_path.ptr);
    self.applyOverrides();
    self.applyAppearance(null);
    self.applyLayout();
    self.applyIconTheme();
    // The style may have changed in the file, or from init.lua.
    ext_view.syncStyle(self);
    if (self.on_settings_changed) |callback| callback();
}

/// The Icon Theme setting, for Lumen's process only.
fn applyIconTheme(self: *Ui) void {
    const gtk_settings = c.gtk_settings_get_default() orelse return;
    if (self.settings.icon_theme.len == 0) {
        return c.gtk_settings_reset_property(gtk_settings, gtk_icon_theme_property);
    }
    var name_bytes: [icon_theme_name_bytes_max]u8 = undefined;
    const theme_name = self.settings.icon_theme;
    const name = std.mem.printSentinel(&name_bytes, "{s}", .{theme_name}, 0) catch return;
    c.g_object_set(gtk_settings, gtk_icon_theme_property, name.ptr, @as(?*anyopaque, null));
}

/// GtkSettings' property the Icon Theme setting sets for Lumen's process.
const gtk_icon_theme_property = "gtk-icon-theme-name";
/// An icon theme's folder name; a longer one is left to GTK's default.
const icon_theme_name_bytes_max = 128;

/// Keys init.lua can fix at once: more than Settings has.
const kept_keys_max = 32;

comptime {
    assert(@typeInfo(Settings).@"struct".field_names.len <= kept_keys_max);
}

/// Writes the settings; what init.lua fixes keeps its value in the file.
pub fn saveSettings(self: *Ui) void {
    var kept: [kept_keys_max][]const u8 = undefined;
    var kept_count: usize = 0;
    if (self.ext_registry) |registry| {
        for (registry.settings) |override| {
            if (kept_count == kept.len) break;
            kept[kept_count] = override.key;
            kept_count += 1;
        }
    }
    self.settings.save(
        self.gpa,
        self.settings_path,
        kept[0..kept_count],
    ) catch |err| log.warn("saving settings: {t}", .{err});
    self.settings_stamp = settings_mod.Stamp.of(self.settings_path.ptr);
    self.applyAppearance(null);
    self.applyLayout();
    self.applyIconTheme();
    if (self.on_settings_changed) |callback| callback();
}

/// `lumen.set` in init.lua, over the file's values.
pub fn applyOverrides(self: *Ui) void {
    const registry = self.ext_registry orelse return;
    for (registry.settings) |override| _ = self.settings.set(override.key, override.value);
}

/// Set by init.lua: Settings shows it but cannot change it.
pub fn overridden(self: *const Ui, key: []const u8) bool {
    // lumen.layout's pixels and place win over these.
    if (std.meta.stringToEnum(LayoutSetting, key)) |layout_setting| {
        const fixed = switch (layout_setting) {
            .width => self.layout.width != null,
            .height => self.layout.height != null,
            .position => self.layout.position != null,
        };
        if (fixed) return true;
    }
    const registry = self.ext_registry orelse return false;
    for (registry.settings) |override| if (std.mem.eql(u8, override.key, key)) return true;
    return false;
}

fn currentTheme(self: *Ui) *const themes.Theme {
    return themes.find(self.settings.theme, self.preferDark(), self.customThemes());
}

/// Theme variables + style.css + the user's style.css, reloaded only when
/// they changed. `preview` paints a theme without choosing it (moving
/// through Change Theme).
pub fn applyAppearance(self: *Ui, preview: ?*const themes.Theme) void {
    const theme = preview orelse self.currentTheme();
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    themes.css(&out.writer, theme, &self.settings) catch return;
    out.writer.writeAll(@embedFile("style.css")) catch return;
    self.appendStyleCss(&out.writer) catch return;
    self.appendUserCss(&out.writer) catch return;
    out.writer.writeByte(0) catch return;
    const text = out.written();
    _ = themes.hex(&self.appearance.highlight_foreground, theme.foreground);
    _ = themes.hex(&self.appearance.highlight_background, theme.accent);
    const hash = std.hash.Wyhash.hash(0, text);
    if (hash == self.appearance.css_hash) return;
    self.appearance.css_hash = hash;
    c.gtk_css_provider_load_from_string(self.appearance.css, @ptrCast(text.ptr));
}

/// The style's CSS, between Lumen's and the user's: styles/<name>/style.css,
/// else the built-in style's.
fn appendStyleCss(self: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    self.appearance.style_css_stamp = .none;
    const name = self.settings.style;
    if (name.len == 0) return;
    var folder_bytes: [4096]u8 = undefined;
    const folder = std.mem.printSentinel(
        &folder_bytes,
        "{s}/styles/{s}",
        .{ self.config_dir, name },
        0,
    ) catch return;
    if (os.info(folder) == null) {
        const style = styles.find(name) orelse return;
        try writer.print("\n/* style {s} */\n", .{name});
        return writer.writeAll(style.css);
    }
    var path_bytes: [4096]u8 = undefined;
    const path = std.mem.printSentinel(&path_bytes, "{s}/style.css", .{folder}, 0) catch return;
    self.appearance.style_css_stamp = settings_mod.Stamp.of(path.ptr);
    var contents: ?[*:0]u8 = null;
    var length: usize = 0;
    if (c.g_file_get_contents(path.ptr, &contents, &length, null) == 0) return;
    defer c.g_free(contents);
    try writer.print("\n/* {s} */\n", .{path});
    try writer.writeAll(contents.?[0..length]);
    try writer.writeByte('\n');
}

/// $XDG_CONFIG_HOME/lumen/style.css, after Lumen's rules so it wins. The
/// classes it can use are listed in EXTENSIONS.md.
fn appendUserCss(self: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var path_bytes: [4096]u8 = undefined;
    const path = std.mem.printSentinel(
        &path_bytes,
        "{s}/style.css",
        .{self.config_dir},
        0,
    ) catch return;
    self.appearance.user_css_stamp = settings_mod.Stamp.of(path.ptr);
    var contents: ?[*:0]u8 = null;
    var length: usize = 0;
    if (c.g_file_get_contents(path.ptr, &contents, &length, null) == 0) return;
    defer c.g_free(contents);
    try writer.writeAll("\n/* ~/.config/lumen/style.css */\n");
    try writer.writeAll(contents.?[0..length]);
    try writer.writeByte('\n');
}

/// Whether the user's or the style's style.css changed since it was read.
fn userCssChanged(self: *Ui) bool {
    var path_bytes: [4096]u8 = undefined;
    const path = std.mem.printSentinel(
        &path_bytes,
        "{s}/style.css",
        .{self.config_dir},
        0,
    ) catch return false;
    if (!settings_mod.Stamp.of(path.ptr).eql(self.appearance.user_css_stamp)) return true;
    if (self.settings.style.len == 0) return false;
    const style = std.mem.printSentinel(
        &path_bytes,
        "{s}/styles/{s}/style.css",
        .{ self.config_dir, self.settings.style },
        0,
    ) catch return false;
    return !settings_mod.Stamp.of(style.ptr).eql(self.appearance.style_css_stamp);
}

/// init.lua's and the style's themes (`lumen.theme`), from the registry.
pub fn customThemes(self: *const Ui) []const themes.Theme {
    const registry = self.ext_registry orelse return &.{};
    return registry.themes;
}

/// Where the desktop keeps its light or dark preference.
const interface_schema = "org.gnome.desktop.interface";
const color_scheme_key = "color-scheme";

/// The desktop's light/dark preference (dark when it cannot be read, or
/// says something new).
pub fn preferDark(self: *Ui) bool {
    const interface_settings = self.appearance.interface_settings orelse return true;
    const value = c.g_settings_get_string(interface_settings, color_scheme_key);
    defer c.g_free(value);
    const color_scheme = std.meta.stringToEnum(ColorScheme, std.mem.span(value)) orelse {
        return true;
    };
    return switch (color_scheme) {
        .@"prefer-dark" => true,
        .default, .@"prefer-light" => false,
    };
}

fn watchColorScheme(self: *Ui) void {
    const source = c.g_settings_schema_source_get_default() orelse return;
    // Looking the schema up first: g_settings_new aborts on a missing one.
    const recursive = 1;
    const schema = c.g_settings_schema_source_lookup(source, interface_schema, recursive) orelse {
        return;
    };
    defer c.g_settings_schema_unref(schema);
    if (c.g_settings_schema_has_key(schema, color_scheme_key) == 0) return;
    const interface_settings = c.g_settings_new(interface_schema);
    self.appearance.interface_settings = interface_settings;
    const signal = "changed::" ++ color_scheme_key;
    widgets.connect(interface_settings, signal, &onColorScheme, self);
}

fn onColorScheme(_: *c.GSettings, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    if (!std.mem.eql(u8, self.settings.theme, themes.auto_id)) return;
    self.applyAppearance(null);
    if (self.view == .settings or self.view == .themes) self.rebuild();
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
        if (!settings_stamp.eql(self.settings_stamp)) self.reloadSettings();
        if (self.userCssChanged()) self.applyAppearance(null);
        self.scanIconDir();
        ext_view.checkReload(self);
        self.placeOnFocusedMonitor();
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
    if (self.view == .themes) self.applyAppearance(null);
    self.panel.close();
    self.confirm_key = "";
    gtk.setVisible(self.window, false);
    backdrop.hideBackdrops(self);
}

/// Puts the window on the monitor Hyprland has focused, a bit above centre.
fn placeOnFocusedMonitor(self: *Ui) void {
    if (testMode()) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const name = hypr.focusedMonitorName(arena.allocator()) orelse return;
    const monitors = c.gdk_display_get_monitors(c.gdk_display_get_default() orelse return);
    const monitor_count = c.g_list_model_get_n_items(monitors);
    var i: c_uint = 0;
    while (i < monitor_count) : (i += 1) {
        const monitor_object = c.g_list_model_get_item(monitors, i) orelse continue;
        defer c.g_object_unref(monitor_object);
        // The display's monitor list holds GdkMonitors only.
        const monitor: *c.GdkMonitor = @ptrCast(monitor_object);
        const connector = c.gdk_monitor_get_connector(monitor) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(connector), name)) continue;
        c.gtk_layer_set_monitor(self.window, monitor);
        var geometry: c.GdkRectangle = undefined;
        c.gdk_monitor_get_geometry(monitor, &geometry);
        const window: *c.GtkWindow = self.window;
        const chosen: layout_mod.Position = switch (self.settings.position) {
            .upper_third => .upper_third,
            .center => .center,
        };
        const position = self.layout.position orelse chosen;
        const offset_px: c_int = self.layout.offset;
        // The pieces sit `style_css.shell_margin_px` inside the surface, room
        // for their shadows, so the margin is the pieces' place minus that.
        const at_bottom = position == .bottom;
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, @intFromBool(!at_bottom));
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_BOTTOM, @intFromBool(at_bottom));
        const room_px = geometry.height - self.panelHeight();
        const room_above_tenths: c_int = switch (position) {
            .center => position_center_tenths,
            .upper_third => position_upper_third_tenths,
            .top, .bottom => 0,
        };
        const room_above_px = @divTrunc(room_px * room_above_tenths, 10);
        const margin_px: c_int = switch (position) {
            .top, .bottom => offset_px - style_css.shell_margin_px,
            .upper_third, .center => @max(room_above_px - style_css.shell_margin_px, 0) + offset_px,
        };
        c.gtk_layer_set_margin(
            window,
            if (at_bottom) c.GTK_LAYER_SHELL_EDGE_BOTTOM else c.GTK_LAYER_SHELL_EDGE_TOP,
            margin_px,
        );
        return;
    }
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
    self.base = self.loadBase(self.data_arena.allocator());
    self.refresh();
    // The rows were built again from the current app list, so the lists an
    // earlier reload replaced can be freed.
    self.apps.dropStale();
}

fn loadBase(self: *Ui, arena: std.mem.Allocator) []Item {
    return switch (self.view) {
        .root => self.rootCandidates(arena),
        .clipboard => self.clipCandidates(arena),
        .windows => self.windowCandidates(arena),
        // Searched on every keystroke, straight from the index.
        .files, .contents => &.{},
        .settings => settings_view.settingsCandidates(self, arena),
        .themes => settings_view.themeCandidates(self, arena),
        .default_apps => settings_view.defaultAppsCandidates(self, arena),
        .choose => settings_view.chooseCandidates(self, arena),
        .ext => ext_view.base(self),
        // The rows are filtered straight from the session's lines.
        .dmenu => &.{},
        .prefs => prefs_view.candidates(self, arena),
        .input => prefs_view.inputCandidates(self, arena),
        .form => form_view.candidates(self, arena),
    };
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
    if (leaving_themes) self.applyAppearance(null);
    self.panel.close();
    self.confirm_key = "";
    _ = self.data_arena.reset(arena_keep);
    if (view == .ext) ext_view.enter(self);
    // A password preference hides what is typed.
    c.gtk_text_set_visibility(self.search_bar.entry, @intFromBool(
        !(view == .input and prefs_view.isPassword(self)),
    ));
    self.base = self.loadBase(self.data_arena.allocator());

    self.layoutFor(view);
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

/// The window's parts for `view`: the detail pane and what it shows, the
/// grid, the back arrow and the magnifier, the list's size.
fn layoutFor(self: *Ui, view: View) void {
    const open_command = if (view == .ext) ext_view.command(self) else null;
    const ext_detail = if (open_command) |shown| shown.detail else false;
    const has_detail = view == .clipboard or view == .files or view == .contents or ext_detail;
    self.grid_mode = if (open_command) |shown| shown.grid else false;
    if (self.grid_mode) {
        self.grid_columns = ext_view.command(self).?.columns;
        c.gtk_flow_box_set_min_children_per_line(self.grid, @intCast(self.grid_columns));
        c.gtk_flow_box_set_max_children_per_line(self.grid, @intCast(self.grid_columns));
    }
    const bar = self.layout.searchbar;
    const back_shows = view != .root and self.layout.show.back and bar.has(.back);
    gtk.setVisible(self.search_bar.back, back_shows);
    // The magnifier gives way to the back arrow inside a view.
    c.gtk_widget_set_visible(self.search_bar.icon, @intFromBool(
        self.layout.show.search_icon and bar.has(.icon) and !back_shows,
    ));
    gtk.setVisible(self.detail.box, has_detail);
    // A preview needs room: the results take the full height then.
    gtk.setVexpand(self.results, has_detail);
    // Beside the detail pane the list takes ~40%; above it, ~half the height.
    const detail_below = self.layout.detail == .bottom;
    c.gtk_widget_set_size_request(
        gtk.widget(self.scroller),
        if (has_detail and !detail_below) @divTrunc(self.panelWidth() * 2, 5) else -1,
        -1,
    );
    gtk.setHexpand(self.scroller, !has_detail or detail_below);
    const list_height_max = self.listHeightMax();
    c.gtk_scrolled_window_set_max_content_height(
        self.scroller,
        if (has_detail and detail_below) @divTrunc(list_height_max, 2) else list_height_max,
    );
    detail_pane.prepareFor(&self.detail, view);
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

fn rootCandidates(self: *Ui, arena: std.mem.Allocator) []Item {
    const sources = [_][]const Item{
        self.apps.items,
        &commands.all,
        scripts.load(arena),
        ext_view.rootItems(self, arena),
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

fn clipCandidates(self: *Ui, arena: std.mem.Allocator) []Item {
    const clips = self.db.recentClips(arena, clipboard_rows_max) catch return &.{};
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

fn windowCandidates(self: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (hypr.clients(arena)) |client| {
        if (!client.mapped or client.address.len == 0) continue;
        const icon: item_mod.Icon = if (self.apps.iconForClass(client.class)) |gicon|
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

// ------------------------------------------------------------- refresh

pub fn query(self: *Ui) []const u8 {
    return std.mem.span(c.gtk_editable_get_text(gtk.editable(self.search_bar.entry)));
}

/// No rows (what they pointed to is going away).
pub fn clearRows(self: *Ui) void {
    self.resetRows();
    self.primary = "";
}

/// Forgets the rows and the items behind them, and anything queued to
/// build them.
fn resetRows(self: *Ui) void {
    _ = self.query_arena.reset(arena_keep);
    self.items = .empty;
    self.rows = .empty;
    self.pending = .empty;
    if (self.pending_idle != 0) _ = c.g_source_remove(self.pending_idle);
    self.pending_idle = 0;
    self.content_query.shown = null;
    self.ext_list.shown = null;
    self.selected = null;
    c.gtk_list_box_remove_all(self.list);
}

pub fn refresh(self: *Ui) void {
    assert(self.built);
    const start_ns = stats.now();
    if (self.answerPending(start_ns)) return;
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
    self.resetRows();
    self.confirm_key = "";
    c.gtk_flow_box_remove_all(self.grid);
    widgets.forgetGridPictures();
    // The rows holding the previous icons are gone; GtkImage kept its refs.
    for (self.icons.items) |icon| c.g_object_unref(icon);
    self.icons.clearRetainingCapacity();

    const arena = self.query_arena.allocator();
    const query_text = std.mem.trim(u8, self.query(), " ");
    self.fill(arena, query_text, start_ns);
    self.showEmptyOrResults(arena, query_text);
    self.selectAfterRefresh();
    // The grid builds every cell at once: nothing of it waits in `pending`.
    if (self.grid_mode) assert(self.pending.items.len == 0);
    if (self.selected) |row_selected| assert(row_selected < self.rows.items.len);
}

/// The rows on screen stay while the answer to a new query is on its way
/// (it refreshes again when it comes): building them again cost a frame
/// per keystroke. True when that is the case and the query was sent.
fn answerPending(self: *Ui, start_ns: u64) bool {
    const query_text = std.mem.trim(u8, self.query(), " ");
    // An extension's search command keeps its rows until it answers.
    if (self.view == .ext and ext_view.waitingForSearch(self, query_text)) return true;
    // In the contents view, the rows on screen are the last result's.
    if (self.view != .contents) return false;
    const content_search = self.content_search orelse return false;
    if (query_text.len < content_query_bytes_min) return false;
    if (!self.content_query.showingLatest()) return false;
    const latest = self.content_query.latest.?;
    if (std.mem.eql(u8, latest.query, ContentSearch.clip(query_text))) return false;
    self.content_query.sent(content_search.submit(query_text, start_ns), query_text);
    return true;
}

/// Builds the current view's rows for `query_text`.
fn fill(self: *Ui, arena: std.mem.Allocator, query_text: []const u8, start_ns: u64) void {
    switch (self.view) {
        .root => self.fillRoot(arena, query_text),
        .clipboard => self.fillFiltered(arena, query_text, .by_day),
        .windows => self.fillFiltered(arena, query_text, .flat),
        .files => if (query_text.len > 0) {
            self.addSection("Files");
            for (file_results.fileItems(self, arena, query_text, file_results_max)) |item| {
                self.addItem(item);
            }
        },
        .contents => if (query_text.len >= content_query_bytes_min) {
            self.fillContents(arena, query_text, start_ns);
        },
        .settings, .themes, .default_apps, .choose => self.fillSectioned(arena, query_text),
        // A search command is asked for the query; a list command's rows are
        // filtered here.
        .ext => {
            self.fillSectioned(arena, if (ext_view.prepare(self, query_text)) query_text else "");
            self.ext_list.shown = self.ext_list.latest;
        },
        .dmenu => dmenu.fill(self, arena, query_text),
        .prefs => self.fillSectioned(arena, query_text),
        // In the input view the typed text is the value being edited, so it
        // does not filter the rows.
        .input => self.fillSectioned(arena, ""),
        .form => self.fillSectioned(arena, query_text),
    }
}

fn fillContents(self: *Ui, arena: std.mem.Allocator, query_text: []const u8, start_ns: u64) void {
    const content_search = self.content_search orelse {
        self.addSection("Matches");
        for (file_results.contentItems(self, arena, query_text, content_results_max)) |item| {
            self.addItem(item);
        }
        return;
    };
    // Ask the worker unless the result for this exact query is already
    // here; meanwhile keep showing the last result. The worker searches the
    // clipped query: compare with that, or a query longer than the clip
    // never counts as answered.
    const fresh = if (self.content_query.latest) |latest|
        std.mem.eql(u8, latest.query, ContentSearch.clip(query_text))
    else
        false;
    if (fresh) {
        self.content_query.answered();
    } else {
        self.content_query.sent(content_search.submit(query_text, start_ns), query_text);
    }
    if (self.content_query.latest) |latest| {
        self.addSection("Matches");
        for (file_results.itemsFromHits(self, arena, latest.hits)) |item| self.addItem(item);
        self.content_query.shown = latest;
    }
}

/// "No Results" (or the view's empty text) when there is nothing to show,
/// and which of the list, the grid and the results panel show.
fn showEmptyOrResults(self: *Ui, arena: std.mem.Allocator, query_text: []const u8) void {
    const searching = self.view == .files or self.view == .contents;
    if (self.rows.items.len == 0 or (searching and self.items.items.len == 0)) {
        if (self.rows.items.len > 0) c.gtk_list_box_remove_all(self.list);
        self.rows.clearRetainingCapacity();
        const empty = self.emptyText(arena);
        const row = gtk.listBoxRow();
        c.gtk_list_box_row_set_selectable(row, 0);
        c.gtk_list_box_row_set_activatable(row, 0);
        c.gtk_list_box_row_set_child(row, gtk.widget(widgets.label(empty, "empty")));
        c.gtk_list_box_append(self.list, gtk.widget(row));
    }
    // A grid shows its cells; the list is there for the "No Results" row.
    gtk.setVisible(self.grid, self.grid_mode and self.items.items.len > 0);
    gtk.setVisible(self.list, !self.grid_mode or self.items.items.len == 0);
    // Nothing typed and nothing to suggest: only the search bar shows.
    const alone = self.view == .root and query_text.len == 0 and self.items.items.len == 0;
    gtk.setVisible(self.results, !alone);
    // One panel with only the search bar showing rounds all its corners.
    gtk.setClass(self.column, "alone", alone);
}

/// Selects the first row, or the one asked for with `setReselect`.
fn selectAfterRefresh(self: *Ui) void {
    const adjustment = c.gtk_scrolled_window_get_vadjustment(self.scroller);
    c.gtk_adjustment_set_value(adjustment, 0);
    var first = self.nextSelectable(null, 1);
    const top = first;
    if (self.reselect.len > 0) {
        // The row to select back may be any of them.
        self.ensureRows();
        // A copy: clearing writes into the buffer `slice` points at.
        const reselect = self.reselect;
        self.reselect.clear();
        const wanted_key = reselect.slice();
        for (self.rows.items, 0..) |row, i| {
            const item_index = row.item orelse continue;
            if (std.mem.eql(u8, self.items.items[item_index].key, wanted_key)) {
                first = i;
                break;
            }
        }
    }
    assert(self.reselect.len == 0);
    if (first) |row_first| assert(self.rows.items[row_first].item != null);
    // The list was just scrolled to the top, where the first row is: no
    // need to wait a frame for its place to scroll to it.
    self.scroll.suppressed = first == top;
    self.select(first);
    self.scroll.suppressed = false;
}

/// Settings-style lists: grouped by section, filtered by typing.
fn fillSectioned(self: *Ui, arena: std.mem.Allocator, query_text: []const u8) void {
    if (query_text.len == 0) {
        var last: ?[]const u8 = null;
        for (self.base) |item| {
            if (last == null or !std.mem.eql(u8, last.?, item.section)) {
                if (item.section.len > 0) self.addSection(item.section);
                last = item.section;
            }
            self.addItem(item);
        }
        return;
    }
    var hits: std.ArrayList(Item) = .empty;
    for (self.base) |item| {
        const fields = [_][]const u8{ item.title, item.keywords, item.subtitle, item.accessory };
        const score = core.fuzzy.scoreFields(query_text, &fields);
        if (score == core.fuzzy.no_match) continue;
        var copy = item;
        copy.score = score;
        hits.append(arena, copy) catch break;
    }
    sortByScore(hits.items);
    for (hits.items) |item| self.addItem(item);
}

/// Nothing typed: what was used most, then every command.
fn fillSuggestions(self: *Ui, arena: std.mem.Allocator) void {
    var used: std.ArrayList(Item) = .empty;
    for (self.base) |item| {
        const frecency = self.frecency.get(item.key) orelse continue;
        var copy = item;
        copy.score = std.math.lossyCast(i32, frecency * frecency_score_scale);
        used.append(arena, copy) catch break;
    }
    sortByScore(used.items);
    if (used.items.len > 0 and self.settings.suggestions) {
        self.addSection("Suggestions");
        for (used.items[0..@min(used.items.len, suggestions_max)]) |item| self.addItem(item);
    }
    self.addSection("Commands");
    for (self.base) |item| {
        switch (item.action) {
            .view, .script, .ext_command, .ext_problem => self.addItem(item),
            else => {},
        }
    }
}

fn fillRoot(self: *Ui, arena: std.mem.Allocator, query_text: []const u8) void {
    if (query_text.len == 0) return self.fillSuggestions(arena);

    if (core.calc.evaluate(query_text)) |answer| {
        self.addSection("Calculator");
        var plain_bytes: [64]u8 = undefined;
        const plain = arena.dupe(u8, core.calc.formatPlain(&plain_bytes, answer.value)) catch "";
        self.addItem(.{
            .title = arena.dupeSentinel(u8, query_text, 0) catch "",
            .subtitle = arena.dupeSentinel(u8, answer.from_unit, 0) catch "",
            .accessory = arena.dupeSentinel(u8, answer.unit, 0) catch "",
            .action = .calc,
            .detail = plain,
        });
    }
    // Extensions' answers (rows from `root = function(query)`).
    ext_view.addRootSections(self, query_text);

    // Scoring and sorting only: rows are timed apart, and fileItems times
    // itself (a deferred timer here counted it twice).
    const search_start_ns = stats.now();
    var hits: std.ArrayList(Item) = .empty;
    for (self.base) |item| {
        const fields = [_][]const u8{ item.title, item.keywords, item.subtitle };
        const score = core.fuzzy.scoreFields(query_text, &fields);
        if (score == core.fuzzy.no_match) continue;
        var copy = item;
        copy.score = score + core.frecency.boost(self.frecency.get(item.key) orelse 0);
        hits.append(arena, copy) catch break;
    }
    sortByScore(hits.items);
    self.search_ns += stats.now() - search_start_ns;
    // Files from 3 letters on, right after the best few results so they are
    // visible without scrolling; the rest of the results follow.
    const files_wanted = query_text.len >= root_files_query_bytes_min and
        self.settings.files_in_root;
    const files = if (files_wanted)
        file_results.fileItems(self, arena, query_text, root_files_max)
    else
        &.{};
    const shown = @min(hits.items.len, root_results_max);
    const head = if (files.len > 0) @min(shown, root_results_before_files_max) else shown;
    for (hits.items[0..head]) |item| self.addItem(item);
    if (files.len > 0) {
        self.addSection("Files");
        for (files) |item| self.addItem(item);
        if (shown > head) self.addSection("More Results");
        for (hits.items[head..shown]) |item| self.addItem(item);
    }
}

fn fillFiltered(
    self: *Ui,
    arena: std.mem.Allocator,
    query_text: []const u8,
    grouping: Grouping,
) void {
    if (query_text.len == 0) {
        if (grouping == .by_day) {
            const today_s = labels.startOfToday();
            var last: ?[:0]const u8 = null;
            for (self.base) |item| {
                const section: [:0]const u8 = if (item.time_s >= today_s)
                    "Today"
                else if (item.time_s >= today_s - std.time.s_per_day)
                    "Yesterday"
                else
                    "Earlier";
                if (last == null or !std.mem.eql(u8, last.?, section)) {
                    self.addSection(section);
                    last = section;
                }
                self.addItem(item);
            }
        } else {
            for (self.base) |item| self.addItem(item);
        }
        return;
    }
    const search_start_ns = stats.now();
    var hits: std.ArrayList(Item) = .empty;
    for (self.base) |item| {
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
    self.search_ns += stats.now() - search_start_ns;
    for (hits.items[0..@min(hits.items.len, filtered_results_max)]) |item| self.addItem(item);
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

pub fn addSection(self: *Ui, title: [:0]const u8) void {
    // A grid has no sections: rows and items stay one to one there.
    if (self.grid_mode or !self.layout.show.section_titles) return;
    if (self.deferRow(.{ .section = title })) return;
    self.buildSection(title);
}

/// Queues the row and returns true when `eager_rows` rows are built already.
/// Returns false when the caller must build it now.
fn deferRow(self: *Ui, pending_row: Pending) bool {
    const eager = self.rows.items.len < eager_rows and self.pending.items.len == 0;
    if (self.grid_mode or eager) return false;
    self.pending.append(self.query_arena.allocator(), pending_row) catch return false;
    if (self.pending_idle == 0) {
        self.pending_idle = c.g_idle_add_full(c.G_PRIORITY_LOW, &onPendingRows, self, null);
    }
    return true;
}

/// The item of the last row that has one.
fn lastItemRow(self: *const Ui) ?usize {
    var i = self.rows.items.len;
    while (i > 0) {
        i -= 1;
        if (self.rows.items[i].item) |item| return item;
    }
    return null;
}

/// Builds every queued row now.
pub fn ensureRows(self: *Ui) void {
    if (self.pending_idle != 0) _ = c.g_source_remove(self.pending_idle);
    self.pending_idle = 0;
    self.buildPending(self.pending.items.len);
}

/// Builds up to `row_count_max` of the queued rows, oldest first.
fn buildPending(self: *Ui, row_count_max: usize) void {
    const built_count = @min(row_count_max, self.pending.items.len);
    for (self.pending.items[0..built_count]) |pending_row| switch (pending_row) {
        .item => |item_index| self.buildItemRow(item_index),
        .section => |title| self.buildSection(title),
    };
    // What is left moves to the front.
    @memmove(
        self.pending.items[0 .. self.pending.items.len - built_count],
        self.pending.items[built_count..],
    );
    self.pending.items.len -= built_count;
}

/// After the frame: the queued rows a few at a time, so a keystroke that
/// comes meanwhile is not kept waiting (it drops them).
fn onPendingRows(data: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Ui = @ptrCast(@alignCast(data));
    self.buildPending(pending_rows_per_idle);
    if (self.pending.items.len > 0) return 1;
    self.pending_idle = 0;
    return 0;
}

fn buildSection(self: *Ui, title: [:0]const u8) void {
    // Room first: a widget without its `rows` entry would shift every later
    // row's index.
    self.rows.ensureUnusedCapacity(self.query_arena.allocator(), 1) catch return;
    const row = gtk.listBoxRow();
    gtk.addClass(row, "section");
    c.gtk_list_box_row_set_selectable(row, 0);
    c.gtk_list_box_row_set_activatable(row, 0);
    c.gtk_list_box_row_set_child(row, gtk.widget(widgets.label(title, "section-title")));
    c.gtk_list_box_append(self.list, gtk.widget(row));
    self.rows.appendAssumeCapacity(.{
        .widget = .{ .list_row = row },
        .item = null,
        .section = title,
    });
}

pub fn addItem(self: *Ui, item_given: Item) void {
    var item = item_given;
    if (self.keyIcon(item.key)) |icon| item.icon = icon;
    const arena = self.query_arena.allocator();
    const item_index = self.items.items.len;
    self.items.append(arena, item) catch return;
    if (self.deferRow(.{ .item = item_index })) return;
    self.buildItemRow(item_index);
}

fn buildItemRow(self: *Ui, item_index: usize) void {
    // Rows follow the items in order: a row queued for an earlier list
    // would point at the wrong item.
    assert(item_index < self.items.items.len);
    if (self.lastItemRow()) |previous| assert(previous < item_index);
    // The grid has no section rows: a child's index is its item's.
    if (self.grid_mode) assert(self.rows.items.len == item_index);
    const arena = self.query_arena.allocator();
    const item = self.items.items[item_index];
    // Room first: a widget without its `rows` entry would shift every later
    // row's index (and `onRowActivated` would select the wrong item).
    self.rows.ensureUnusedCapacity(arena, 1) catch return;
    if (self.grid_mode) {
        const gaps_px = grid_spacing_px * (self.grid_columns - 1) + grid_frame_px;
        const cell_px = @divTrunc(self.panelWidth() - gaps_px, self.grid_columns);
        // At least a pixel: lumen.layout's width and a command's columns can leave
        // no room, and a cell of no width would ask for pictures of no size.
        const cell_width_px = @max(cell_px - 2 * style_css.grid_cell_padding_px, 1);
        const cell = widgets.gridCell(&self.row_look, item, cell_width_px);
        c.gtk_flow_box_append(self.grid, cell);
        const child = c.gtk_flow_box_get_child_at_index(
            self.grid,
            @intCast(item_index),
        ) orelse return;
        self.rows.appendAssumeCapacity(.{ .widget = .{ .grid_cell = child }, .item = item_index });
        return;
    }
    var parts: widgets.RowParts = .{};
    const row = if (item.action == .calc)
        widgets.calcRow(item)
    else
        widgets.itemRow(&self.row_look, item, &parts);
    const row_tag = self.rows.items.len + 1;
    c.g_object_set_data(gtk.widget(row), row_index_data_key, @ptrFromInt(row_tag));
    c.gtk_list_box_append(self.list, gtk.widget(row));
    self.rows.appendAssumeCapacity(.{
        .widget = .{ .list_row = row },
        .item = item_index,
        .hint = parts.hint,
        .accessory = parts.accessory,
    });
}

// ----------------------------------------------------------- selection

/// The first row after `from` (or from either end, when null) in
/// `direction` that shows an item; `from` when there is none.
pub fn nextSelectable(self: *Ui, from: ?usize, direction: i32) ?usize {
    assert(direction == 1 or direction == -1);
    if (from) |start| assert(start < self.rows.items.len);
    // Moving up from the end, or down past the last row built so far, needs
    // the rows that are still queued.
    if (self.pending.items.len > 0) {
        const up_from_end = from == null and direction < 0;
        const down_past_built = if (from) |start|
            direction > 0 and start + 1 >= self.rows.items.len
        else
            false;
        if (up_from_end or down_past_built) self.ensureRows();
    }
    const row_count = self.rows.items.len;
    if (row_count == 0) return null;
    var i: i64 = if (from) |start|
        @as(i64, @intCast(start)) + direction
    else if (direction > 0)
        0
    else
        @as(i64, @intCast(row_count)) - 1;
    while (i >= 0 and i < row_count) : (i += direction) {
        if (self.rows.items[@intCast(i)].item != null) return @intCast(i);
    }
    return from;
}

pub fn select(self: *Ui, row_index: ?usize) void {
    assert(self.built);
    if (row_index) |row_given| assert(row_given < self.rows.items.len);
    defer assert(self.selected == row_index);
    if (self.selected) |previous| if (previous < self.rows.items.len) {
        const row_old = self.rows.items[previous];
        if (row_old.hint) |hint| gtk.setVisible(hint, false);
        if (row_old.accessory) |accessory| gtk.setVisible(accessory, true);
    };
    self.selected = row_index;
    self.confirm_key = "";
    self.primary = "";
    const selected_index = row_index orelse {
        self.setFooterAction("", .action);
        c.gtk_list_box_unselect_all(self.list);
        c.gtk_flow_box_unselect_all(self.grid);
        detail_pane.showDetail(self, null);
        return;
    };
    const row = self.rows.items[selected_index];
    // Section titles are never selected (nextSelectable skips them).
    assert(row.item != null);
    assert(row.item.? < self.items.items.len);
    assert(self.grid_mode == (row.widget == .grid_cell));
    switch (row.widget) {
        .grid_cell => |cell| c.gtk_flow_box_select_child(self.grid, cell),
        .list_row => |list_row| c.gtk_list_box_select_row(self.list, list_row),
    }
    if (!self.scroll.suppressed) self.scrollTo(row.widget.widget());
    const item = &self.items.items[row.item.?];
    self.primary = item_mod.actionsFor(item)[0].label;
    self.setHint(self.primary, .action);
    detail_pane.showDetail(self, item);
    // Change Theme shows each theme as the selection moves over it, and the
    // theme in use on a style.
    if (self.view == .themes) {
        const is_theme = item.action == .setting and item.action.setting == .theme;
        const preview: ?*const themes.Theme = if (is_theme)
            themes.find(item.action.setting.theme, self.preferDark(), self.customThemes())
        else
            null;
        self.applyAppearance(preview);
    }
}

/// The footer's "what Enter does" (hidden with nothing selected).
fn setFooterAction(self: *Ui, text: []const u8, tone: HintTone) void {
    const text_z = self.query_arena.allocator().dupeSentinel(u8, text, 0) catch return;
    self.footer.setAction(text_z, tone);
}

/// The selected row's hint: "Open ↵", or a warning waiting for Enter (and
/// the footer's, which says the same).
fn setHint(self: *Ui, text: []const u8, tone: HintTone) void {
    const warn = tone == .warning;
    self.setFooterAction(text, tone);
    if (!self.layout.show.hints and !warn) return;
    const row_index = self.selected orelse return;
    const row = self.rows.items[row_index];
    const hint = row.hint orelse return;
    if (row.accessory) |accessory| gtk.setVisible(accessory, false);
    // Beside the detail pane the list is narrow: the action's name would
    // squeeze the title to a few letters, so only the key shows there.
    const narrow = gtk.isVisible(self.detail.box);
    const arena = self.query_arena.allocator();
    const shown = if (warn)
        text
    else if (narrow)
        enter_key_text
    else
        arena.print("{s}  " ++ enter_key_text, .{text}) catch return;
    const text_z = arena.dupeSentinel(u8, shown, 0) catch return;
    c.gtk_label_set_text(hint, text_z.ptr);
    gtk.setClass(hint, widgets.css_class.warn, warn);
    gtk.setVisible(hint, true);
}

fn scrollTo(self: *Ui, row: *c.GtkWidget) void {
    var bounds: c.graphene_rect_t = undefined;
    // A row just added has no place yet: it is scrolled to on a later frame,
    // once the list's layout is done.
    const container = if (self.grid_mode) gtk.widget(self.grid) else gtk.widget(self.list);
    const has_bounds = c.gtk_widget_compute_bounds(row, container, &bounds) != 0;
    const placed = has_bounds and bounds.size.height != 0;
    if (!placed) {
        if (self.scroll.tick == 0) {
            self.scroll.tries = 0;
            self.scroll.tick = c.gtk_widget_add_tick_callback(
                gtk.widget(self.scroller),
                &onScrollTick,
                self,
                null,
            );
        }
        return;
    }
    const adjustment = c.gtk_scrolled_window_get_vadjustment(self.scroller);
    const shown_top = c.gtk_adjustment_get_value(adjustment);
    const shown_height = c.gtk_adjustment_get_page_size(adjustment);
    const top: f64 = bounds.origin.y;
    const bottom: f64 = top + bounds.size.height;
    // Keep a section header above the first item visible, and the selection
    // clear of the fade at the bottom edge (style.css, undershoot).
    const fade_px = style_css.results_fade_px;
    if (top < shown_top + scroll_top_slack_px) {
        c.gtk_adjustment_set_value(adjustment, @max(top - scroll_section_title_px, 0));
    } else if (bottom > shown_top + shown_height - fade_px) {
        c.gtk_adjustment_set_value(adjustment, bottom - shown_height + fade_px);
    }
}

fn onScrollTick(_: ?*c.GtkWidget, _: ?*c.GdkFrameClock, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Ui = @ptrCast(@alignCast(data.?));
    self.scroll.tries += 1;
    const row_index = self.selected orelse {
        self.scroll.tick = 0;
        return 0;
    };
    if (row_index >= self.rows.items.len) {
        self.scroll.tick = 0;
        return 0;
    }
    const row = self.rows.items[row_index].widget.widget();
    var bounds: c.graphene_rect_t = undefined;
    const container = if (self.grid_mode) gtk.widget(self.grid) else gtk.widget(self.list);
    const has_bounds = c.gtk_widget_compute_bounds(row, container, &bounds) != 0;
    const placed = has_bounds and bounds.size.height > 0;
    if (!placed and self.scroll.tries < scroll_frames_max) return 1;
    self.scroll.tick = 0;
    if (placed) self.scrollTo(row);
    return 0;
}

pub fn selectedItem(self: *Ui) ?*Item {
    const row_index = self.selected orelse return null;
    return &self.items.items[self.rows.items[row_index].item orelse return null];
}

fn viewTitle(self: *Ui) [*:0]const u8 {
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

// --------------------------------------------------------- action panel

pub fn openPanel(self: *Ui) void {
    assert(self.built);
    const item = self.selectedItem() orelse return;
    self.panel.show(item_mod.actionsFor(item));
}

// ------------------------------------------------------------- actions

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
    self.setHint(self.primary, .warning);
    return true;
}

/// It did not work: say so on the selected row. `message` must outlive the
/// rows.
pub fn showFailure(self: *Ui, message: [:0]const u8) void {
    self.primary = message;
    self.setHint(message, .warning);
}

/// A Lua action is running.
pub fn showRunning(self: *Ui) void {
    self.primary = "Running...";
    self.setHint(self.primary, .action);
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
        .choose_app => |path| settings_view.chooseAppFor(self, path),
        .failed => |message| self.showFailure(message),
    }
}

// ----------------------------------------------------------- callbacks

fn onChanged(_: *c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    self.refresh();
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const row_tag = @intFromPtr(c.g_object_get_data(row, row_index_data_key));
    // 0 is no data at all: a row Lumen did not build (the empty text).
    if (row_tag == 0) return;
    self.select(row_tag - 1);
    const item = self.selectedItem() orelse return;
    self.performEntry(item_mod.actionsFor(item)[0]);
}

fn onGridActivated(
    _: *c.GtkFlowBox,
    child: *c.GtkFlowBoxChild,
    data: ?*anyopaque,
) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const cell_index = c.gtk_flow_box_child_get_index(child);
    if (cell_index < 0 or cell_index >= self.rows.items.len) return;
    self.select(@intCast(cell_index));
    const item = self.selectedItem() orelse return;
    self.performEntry(item_mod.actionsFor(item)[0]);
}

fn onBackClicked(
    _: *c.GtkEventController,
    _: c_int,
    _: f64,
    _: f64,
    data: ?*anyopaque,
) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    if (self.view != .root) self.goBack();
    _ = c.gtk_widget_grab_focus(gtk.widget(self.search_bar.entry));
}

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
        self.clearRows();
        self.base = &.{};
        self.apps.dropStale();
    }
    return 0;
}

fn onKey(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    data: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self: *Ui = @ptrCast(@alignCast(data));
    return keyboard.handleKey(self, keyval, state);
}

/// `lumen --key NAME`: the same handling as a real key press, for tests.
/// Names: down, up, enter, ctrl+enter, ctrl+k, escape, backspace, pagedown,
/// pageup, ctrl+x, ctrl+o, left, right, and any keymap ("ctrl+g").
pub fn injectKey(self: *Ui, name: []const u8) bool {
    const keys = [_]struct { []const u8, c_uint, c.GdkModifierType }{
        .{ "down", c.GDK_KEY_Down, 0 },                 .{ "up", c.GDK_KEY_Up, 0 },
        .{ "enter", c.GDK_KEY_Return, 0 },
        .{
            "ctrl+enter",
            c.GDK_KEY_Return,
            c.GDK_CONTROL_MASK,
        },
        .{ "ctrl+k", c.GDK_KEY_k, c.GDK_CONTROL_MASK }, .{ "escape", c.GDK_KEY_Escape, 0 },
        .{ "backspace", c.GDK_KEY_BackSpace, 0 },       .{ "pagedown", c.GDK_KEY_Page_Down, 0 },
        .{ "pageup", c.GDK_KEY_Page_Up, 0 },
        .{
            "ctrl+x",
            c.GDK_KEY_x,
            c.GDK_CONTROL_MASK,
        },
        .{ "ctrl+o", c.GDK_KEY_o, c.GDK_CONTROL_MASK }, .{ "left", c.GDK_KEY_Left, 0 },
        .{ "right", c.GDK_KEY_Right, 0 },
    };
    for (keys) |key| if (std.mem.eql(u8, key[0], name)) {
        _ = keyboard.handleKey(self, key[1], key[2]);
        return true;
    };
    // Anything else written like a keymap ("ctrl+g").
    const parsed = ext_view.parseKey(name) orelse return false;
    _ = keyboard.handleKey(self, parsed.keyval, parsed.modifiers);
    return true;
}

/// `lumen --dump`: what the window shows, as text (for end-to-end tests).
/// Caller owns the result, allocated with `gpa`.
pub fn dump(
    self: *Ui,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || std.mem.Allocator.Error)![:0]u8 {
    assert(self.built);
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const arena = scratch_state.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;
    try self.dumpWindow(writer);
    try self.dumpRows(writer, arena);
    if (gtk.isVisible(self.detail.box)) try self.dumpDetail(writer);
    if (self.panel.isOpen()) {
        try writer.print("panel:\n", .{});
        for (self.panel.entries, 0..) |entry, i| try writer.print("  {s} {s} [{s}]\n", .{
            if (i == self.panel.selected) ">" else " ",
            entry.label,
            entry.keys,
        });
    }
    return out.toOwnedSliceSentinel(0);
}

/// The dump's first lines: the view, the query, the layout and the footer.
fn dumpWindow(self: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("view: {t}\nvisible: {}\nquery: {s}\n", .{
        self.view,
        gtk.isVisible(self.window),
        self.query(),
    });
    try writer.print("title: {s}\nprimary: {s}\n", .{ self.viewTitle(), self.primary });
    const layout = self.layout;
    try writer.print(
        "style: {s}\n",
        .{if (self.settings.style.len > 0) self.settings.style else "-"},
    );
    try writer.print("layout: {d}x{d} panels={t} search={t} detail={t} rows={t} footer={}", .{
        self.panelWidth(),
        self.panelHeight(),
        layout.panels,
        layout.search,
        layout.detail,
        layout.rows,
        layout.footer,
    });
    try writer.writeAll(" bar=");
    for (layout.searchbar.slice(), 0..) |part, i| {
        try writer.print("{s}{t}", .{ if (i > 0) "," else "", part });
    }
    try writer.writeAll(" row=");
    for (layout.row.slice(), 0..) |part, i| {
        try writer.print("{s}{t}", .{ if (i > 0) "," else "", part });
    }
    try writer.print(" prompt={s} placeholder={s}\n", .{ layout.prompt, layout.placeholder });
    if (layout.footer) {
        try writer.print("footer: {s} | {s}\n", .{
            c.gtk_label_get_text(self.footer.title),
            c.gtk_label_get_text(self.footer.action),
        });
    }
}

/// One line per row: the selection mark, the texts, the icon and the key.
fn dumpRows(self: *Ui, writer: *std.Io.Writer, arena: std.mem.Allocator) std.Io.Writer.Error!void {
    try writer.print("rows:\n", .{});
    self.ensureRows();
    if (self.rows.items.len == 0) try writer.print("  (empty) {s}\n", .{self.emptyText(arena)});
    for (self.rows.items, 0..) |row, i| {
        const item_index = row.item orelse {
            try writer.print("  # {s}\n", .{row.section});
            continue;
        };
        const item = self.items.items[item_index];
        const mark: []const u8 = if (self.selected == i) ">" else " ";
        try writer.print(
            "  {s} {s} | {s} | {s} | ",
            .{ mark, item.title, item.subtitle, item.accessory },
        );
        switch (item.icon) {
            .logo => |logo| try writer.print("logo:{s}", .{logo.name}),
            .badge => |badge| try writer.print("badge:{s}", .{badge.text}),
            .tile => |tile| try writer.print("tile:{s}", .{tile.name}),
            .gicon => try writer.print("gicon", .{}),
            .emoji => |emoji| try writer.print("emoji:{s}", .{emoji}),
            .file => |file_path| try writer.print(
                "file:{s}",
                .{std.Io.Dir.path.basename(file_path)},
            ),
            .swatch => |swatch| try writer.print("swatch:{s}", .{swatch.id}),
            .named => |name| try writer.print("icon:{s}", .{name}),
            .none => try writer.print("none", .{}),
        }
        // The key, for lumen.icons (empty for rows without one). A file's is
        // its path, which need not be UTF-8: the dump must stay text.
        try writer.print(
            " | {s}\n",
            .{if (std.unicode.utf8ValidateSlice(item.key)) item.key else "?"},
        );
    }
}

/// The detail pane: an extension's first line of text, and the metadata.
fn dumpDetail(self: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("detail:\n", .{});
    if (self.view == .ext) {
        const text = std.mem.span(c.gtk_label_get_text(self.detail.text));
        try writer.print("  text = {s}\n", .{
            text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len],
        });
    }
    if (gtk.isVisible(self.detail.meta)) {
        const detail = &self.detail;
        for (detail.meta_lines, detail.meta_keys, detail.meta_values) |line, key, value| {
            if (!gtk.isVisible(line)) continue;
            try writer.print("  {s} = {s}\n", .{
                c.gtk_label_get_text(key),
                c.gtk_label_get_text(value),
            });
        }
    }
}

/// The placeholder row's text when nothing is listed.
fn emptyText(self: *Ui, arena: std.mem.Allocator) [:0]const u8 {
    const query_text = std.mem.trim(u8, self.query(), " ");
    if (self.view == .files and query_text.len == 0) return file_results.filesHint(self, arena);
    if (self.view == .contents and query_text.len < content_query_bytes_min) {
        return file_results.contentsHint(self, arena, query_text.len);
    }
    if (self.view == .contents and self.content_query.pending) return "Searching...";
    const content_error = if (self.content_query.latest) |result| result.err else null;
    if (self.view == .contents and content_error != null) {
        return arena.printSentinel(
            "Content search failed ({t})",
            .{content_error.?},
            0,
        ) catch "Content search failed";
    }
    const clipboard_off = self.view == .clipboard and !self.settings.clipboard;
    if (clipboard_off and query_text.len == 0) {
        return "Clipboard history is off: turn it on in Settings";
    }
    if (self.view == .ext) return ext_view.emptyText(self, arena, query_text);
    if (self.view == .dmenu) return dmenu.emptyText(self);
    return "No Results";
}

test {
    _ = @import("dmenu.zig");
    _ = @import("inflight.zig");
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

test "style.css has the sizes Ui computes with" {
    const stylesheet = @embedFile("style.css");
    const Check = struct { selector: []const u8, property: []const u8, value: []const u8 };
    const checks = [_]Check{
        .{
            .selector = ".search {",
            .property = "min-height",
            .value = pxText(style_css.search_height_px),
        },
        .{
            .selector = ".results-island {",
            .property = "padding",
            .value = pxText(style_css.results_padding_px),
        },
        .{
            .selector = ".shell {",
            .property = "margin",
            .value = pxText(style_css.shell_margin_px),
        },
        .{
            .selector = ".grid > flowboxchild {",
            .property = "padding",
            .value = "8px " ++ pxText(style_css.grid_cell_padding_px),
        },
        .{
            .selector = "> undershoot.bottom {",
            .property = "background-size",
            .value = "100% " ++ pxText(style_css.results_fade_px),
        },
    };
    for (checks) |check| {
        const value = cssValue(stylesheet, check.selector, check.property) orelse {
            std.debug.print("style.css: no {s} in {s}\n", .{ check.property, check.selector });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(check.value, value);
    }
    const border = cssValue(stylesheet, ".results-island {", "border").?;
    const border_width = pxText(style_css.results_border_px) ++ " ";
    try std.testing.expect(std.mem.startsWith(u8, border, border_width));
}

/// "6px" for 6, as style.css writes it.
inline fn pxText(comptime size_px: comptime_int) []const u8 {
    return std.fmt.comptimePrint("{d}px", .{size_px});
}

/// The value of `property` in the first rule whose selector ends in
/// `selector` ("... {"), for the test above.
fn cssValue(stylesheet: []const u8, selector: []const u8, property: []const u8) ?[]const u8 {
    const rule_start = std.mem.find(u8, stylesheet, selector) orelse return null;
    const body_start = rule_start + selector.len;
    const body_end = std.mem.findScalarPos(u8, stylesheet, body_start, '}') orelse return null;
    var declarations = std.mem.splitScalar(u8, stylesheet[body_start..body_end], ';');
    while (declarations.next()) |declaration| {
        const colon = std.mem.findScalar(u8, declaration, ':') orelse continue;
        const name = std.mem.trim(u8, declaration[0..colon], " \t\n");
        if (std.mem.eql(u8, name, property)) {
            return std.mem.trim(u8, declaration[colon + 1 ..], " \t\n");
        }
    }
    return null;
}
