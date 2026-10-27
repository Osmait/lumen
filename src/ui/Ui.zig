//! The launcher window: a gtk4-layer-shell overlay with two floating pieces,
//! the search bar and the results (with an optional detail pane), plus the
//! action panel.
//!
//! One instance lives for the whole daemon; showing and hiding the window is
//! what the global hotkey does.

const std = @import("std");
const c = @import("c");
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
const layout_mod = @import("../layout.zig");
const Kind = core.file_kind.Kind;

const Ui = @This();

/// For main: GLib signal connection and the content worker's callback.
pub const connect = widgets.connect;
pub const onContentResult = file_results.onContentResult;

const log = std.log.scoped(.ui);

/// The window's pieces: lumen.layout's pixels, else the Width and Height
/// settings.
fn panelW(self: *const Ui) c_int {
    if (self.layout.width) |w| return w;
    return switch (self.settings.width) {
        .narrow => 620,
        .default => 750,
        .wide => 920,
    };
}
fn panelH(self: *const Ui) c_int {
    if (self.layout.height) |h| return h;
    return switch (self.settings.height) {
        .short => 380,
        .default => 474,
        .tall => 640,
    };
}
/// The list's height limit: what is left beside the search bar (56), the
/// results' padding and border (14), the footer (40) and the gaps between
/// pieces (10, none in a single panel).
fn listMaxH(self: *const Ui) c_int {
    const gap: c_int = if (self.layout.panels == .split) 10 else 0;
    const footer: c_int = if (self.layout.footer) footer_h + gap else 0;
    return self.panelH() - 56 - 14 - gap - footer;
}
const footer_h = 40;
/// Clear space around the pieces for their shadows (`.shell` in style.css).
const shell_margin = 48;
const max_results = 60;

gpa: std.mem.Allocator,
io: std.Io,
app: *c.GtkApplication,
db: Db,
apps: Apps,

window: *c.GtkWidget = undefined,
/// The search bar and the results, sized by the layout settings.
column: *c.GtkWidget = undefined,
/// lumen.layout from init.lua (defaults until the files load).
layout: layout_mod.Layout = .{},
/// Takes the room above the results when the search bar is at the bottom.
spacer: *c.GtkWidget = undefined,
/// The bar under the results (lumen.layout's footer): the view's name,
/// what Enter does, and Actions.
footer: *c.GtkWidget = undefined,
footer_title: *c.GtkWidget = undefined,
footer_action: *c.GtkWidget = undefined,
footer_enter: *c.GtkWidget = undefined,
footer_sep: *c.GtkWidget = undefined,
/// The "Ctrl K" chip in the search bar, and the magnifier before the text.
key_chip: *c.GtkWidget = undefined,
search_icon: *c.GtkWidget = undefined,
/// lumen.layout's prompt (rofi's "drun"), before the text.
prompt_label: *c.GtkWidget = undefined,
/// The widgets exist (settings read before `build` made them wait).
built: bool = false,
entry: *c.GtkWidget = undefined,
back: *c.GtkWidget = undefined,
list: *c.GtkWidget = undefined,
/// Extension commands with `grid = true` show their rows here instead.
grid: *c.GtkWidget = undefined,
grid_mode: bool = false,
grid_columns: c_int = 5,
scroller: *c.GtkWidget = undefined,
detail: *c.GtkWidget = undefined,
detail_text: *c.GtkWidget = undefined,
detail_picture: *c.GtkWidget = undefined,
/// The "Information" block under the preview (hidden for extensions).
detail_meta: *c.GtkWidget = undefined,
meta_keys: [4]*c.GtkWidget = undefined,
/// The rows of the Information block (extensions show as many as they give).
meta_lines: [4]*c.GtkWidget = undefined,
meta_values: [4]*c.GtkWidget = undefined,
/// File index, started by main once the window exists.
files: ?*index.Service = null,
/// Content (full-text) index, started by main after `files`.
contents: ?*index.ContentService = null,
/// Runs content queries off the UI thread (null: run them inline).
content_search: ?*ContentSearch = null,
/// The latest content result applied; its arena backs the rows shown.
content_result: ?*ContentSearch.Result = null,
/// Generation of the last query submitted; older results are dropped.
content_gen: u32 = 0,
content_pending: bool = false,
/// Time spent searching during the current refresh (for `lumen --stats`).
search_ns: u64 = 0,
frame_clock_hooked: bool = false,
/// Icons made for the current rows; released on the next refresh.
icons: std.ArrayList(*c.GIcon) = .empty,
/// The view's name, a chip in the search bar (hidden in the root view).
scope: *c.GtkWidget = undefined,
/// The island holding the results (and the detail pane).
results: *c.GtkWidget = undefined,
search_bar: *c.GtkWidget = undefined,
/// Clear full-screen layers under the window, one per monitor: a click on
/// one (anywhere outside Lumen) hides it.
backdrops: [8]?*c.GtkWidget = @splat(null),
/// What Enter does on the selected row, shown inside it.
primary: [:0]const u8 = "",
panel: *c.GtkWidget = undefined,
panel_list: *c.GtkWidget = undefined,

view: View = .root,
/// Lives until the view changes: clipboard entries, window list, scripts.
data_arena: std.heap.ArenaAllocator,
/// Lives until the next keystroke: the visible items and rows.
query_arena: std.heap.ArenaAllocator,
/// Frecency values, reloaded each time the window opens.
frec_arena: std.heap.ArenaAllocator,
frec: std.StringHashMapUnmanaged(f64) = .empty,

/// Candidates of the current view before filtering.
base: []Item = &.{},
/// Visible items, in row order.
items: std.ArrayList(Item) = .empty,
rows: std.ArrayList(Row) = .empty,
selected: ?usize = null,

panel_open: bool = false,
panel_entries: []const item_mod.Entry = &.{},
panel_selected: usize = 0,
/// Key of the destructive item waiting for its second Enter.
confirm_key: []const u8 = "",

settings: Settings,
/// $XDG_CONFIG_HOME/lumen: settings, init.lua, extensions, style.css.
config_dir: [:0]const u8 = "",
settings_path: [:0]const u8 = "",
/// The settings file as last read or written: a different one on disk was
/// edited by hand.
settings_stamp: settings_mod.Stamp = .none,
/// Called after the settings change (main starts or stops the clipboard
/// watcher).
on_settings_changed: ?*const fn () void = null,
css: *c.GtkCssProvider = undefined,
css_hash: u64 = 0,
/// The user's style.css as last read (it is applied after Lumen's).
user_css_stamp: settings_mod.Stamp = .none,

/// Lua extensions and init.lua (null when they could not start).
ext_host: ?*ExtHost = null,
/// What the files define; rows and themes point into it.
ext_registry: ?*ExtHost.Registry = null,
/// The files as last loaded (ExtHost.stamp).
ext_stamp: u64 = 0,
/// The command the ext view shows (its index in the registry).
ext_cmd: u16 = 0,
/// Its latest rows; they point into it.
ext_result: ?*ExtHost.ListResult = null,
/// Generation of the last list asked for; older answers are dropped.
ext_gen: u32 = 0,
ext_pending: bool = false,
/// The query of the last list asked for.
ext_asked: [256]u8 = undefined,
ext_asked_len: usize = 0,
/// Extension rows for the root search, and the query last asked for.
ext_root: ?*ExtHost.RootResult = null,
ext_root_gen: u32 = 0,
ext_root_pending: bool = false,
ext_root_asked: [256]u8 = undefined,
ext_root_asked_len: usize = 0,
/// The Lua action running (0: none); its answer decides what happens.
ext_act_gen: u32 = 0,
/// The extension whose preferences the prefs view lists.
prefs_ext: [64]u8 = undefined,
prefs_ext_len: usize = 0,
/// What the input view edits: a preference (index in the registry) or a
/// field of the open form.
input: union(enum) { pref: u16, field: u16 } = .{ .pref = 0 },
/// The open form (index in the registry) and its fields' values (gpa).
form_cmd: u16 = 0,
form_values: std.ArrayList([:0]u8) = .empty,
/// ~/.config/lumen/icons as last read (widgets.renamed points into it).
icon_arena: ?std.heap.ArenaAllocator = null,
/// `lumen --dmenu` waiting for an answer.
picker: ?*dmenu.Session = null,
/// Search highlight colours of the theme, for Pango markup.
hl_fg: [8]u8 = "#ffffff\x00".*,
hl_bg: [8]u8 = "#ff6363\x00".*,
/// org.gnome.desktop.interface, for the "Automatic" theme.
interface_settings: ?*c.GSettings = null,
/// What the choose view lists values for.
choosing: Choosing = .none,
choose_title: [96:0]u8 = @splat(0),
/// Views to go back to (Escape, Backspace, the back arrow), each with the
/// row that was selected there.
nav: [8]struct { view: View, key: [80]u8, key_len: usize } = undefined,
nav_len: usize = 0,
/// Row to select once the view is built (by its item key).
reselect: [80]u8 = undefined,
reselect_len: usize = 0,

pub const Choosing = union(enum) {
    none,
    setting: settings_mod.Choice,
    kind: Kind,
    /// Open With for one file; both strings are owned by `gpa`.
    file: struct { path: [:0]u8, mime: [:0]u8 },
    /// A choice preference of an extension (index in the registry).
    pref: u16,
    /// A choice field of the open form.
    field: u16,
};

/// `hint` shows the primary action while the row is selected, in place of
/// `accessory`.
const Row = struct { widget: *c.GtkWidget, item: ?usize, section: [:0]const u8 = "", hint: ?*c.GtkWidget = null, accessory: ?*c.GtkWidget = null };

/// End-to-end tests run a second, isolated Lumen (LUMEN_TEST=1): it must not
/// take the keyboard from the session, nor ask Hyprland where to go.
pub fn testMode() bool {
    return c.g_getenv("LUMEN_TEST") != null;
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
        .frec_arena = .init(gpa),
    };
}

// ------------------------------------------------------------ building

pub fn build(self: *Ui) void {
    self.apps.reload();
    const monitor = c.g_app_info_monitor_get();
    widgets.connect(monitor, "changed", &onAppsChanged, self);

    self.loadCss();
    self.config_dir = std.fmt.allocPrintSentinel(self.gpa, "{s}/lumen", .{std.mem.span(c.g_get_user_config_dir())}, 0) catch "";
    self.settings_path = std.fmt.allocPrintSentinel(self.gpa, "{s}/settings.conf", .{self.config_dir}, 0) catch "";
    self.watchColorScheme();
    self.reloadSettings();

    const win = c.gtk_application_window_new(self.app);
    self.window = win;
    c.gtk_widget_add_css_class(win, "lumen");
    c.gtk_window_set_title(@ptrCast(win), "Lumen");
    c.gtk_window_set_resizable(@ptrCast(win), 0);
    c.gtk_window_set_decorated(@ptrCast(win), 0);
    // A fixed size: the layer surface would otherwise grow to its content's
    // natural size (a large image preview, a long path).
    c.gtk_window_set_default_size(@ptrCast(win), self.panelW() + 2 * shell_margin, self.panelH() + 2 * shell_margin);

    const w: *c.GtkWindow = @ptrCast(win);
    c.gtk_layer_init_for_window(w);
    c.gtk_layer_set_layer(w, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    c.gtk_layer_set_keyboard_mode(w, if (testMode()) c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE else c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
    c.gtk_layer_set_namespace(w, "lumen");
    c.gtk_layer_set_anchor(w, c.GTK_LAYER_SHELL_EDGE_TOP, 1);

    const overlay = c.gtk_overlay_new();
    c.gtk_window_set_child(w, overlay);

    // Two pieces on a transparent surface: the search bar and, below it, the
    // results, as tall as their rows (the rest of the surface stays clear).
    const column = widgets.vbox(10);
    self.column = column;
    c.gtk_widget_add_css_class(column, "shell");
    c.gtk_widget_set_size_request(column, self.panelW(), self.panelH());
    c.gtk_overlay_set_child(@ptrCast(overlay), column);

    // search bar
    const search = widgets.hbox(0);
    c.gtk_widget_add_css_class(search, "search");
    self.search_bar = search;
    self.back = c.gtk_image_new_from_icon_name("go-previous-symbolic");
    c.gtk_widget_add_css_class(self.back, "back");
    c.gtk_widget_set_valign(self.back, c.GTK_ALIGN_CENTER);
    // An image has no click of its own: a gesture makes it the back button.
    c.gtk_widget_set_cursor_from_name(self.back, "pointer");
    const back_click = c.gtk_gesture_click_new();
    widgets.connect(back_click, "released", &onBackClicked, self);
    c.gtk_widget_add_controller(self.back, back_click);
    c.gtk_box_append(@ptrCast(search), self.back);
    self.search_icon = c.gtk_image_new_from_icon_name("system-search-symbolic");
    c.gtk_widget_add_css_class(self.search_icon, "search-icon");
    c.gtk_widget_set_valign(self.search_icon, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_visible(self.search_icon, 0);
    c.gtk_box_append(@ptrCast(search), self.search_icon);
    self.prompt_label = widgets.label("", "prompt");
    c.gtk_widget_set_valign(self.prompt_label, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_visible(self.prompt_label, 0);
    c.gtk_box_append(@ptrCast(search), self.prompt_label);
    self.scope = widgets.label("", "scope");
    c.gtk_widget_set_valign(self.scope, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_visible(self.scope, 0);
    c.gtk_box_append(@ptrCast(search), self.scope);
    self.entry = c.gtk_text_new();
    c.gtk_widget_add_css_class(self.entry, "query");
    c.gtk_widget_set_hexpand(self.entry, 1);
    c.gtk_widget_set_valign(self.entry, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(search), self.entry);
    widgets.connect(self.entry, "changed", &onChanged, self);
    const k = widgets.label("Ctrl K", "kbd");
    self.key_chip = k;
    c.gtk_widget_set_valign(k, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_tooltip_text(k, "Actions");
    c.gtk_box_append(@ptrCast(search), k);
    self.spacer = widgets.vbox(0);
    c.gtk_widget_set_vexpand(self.spacer, 1);
    c.gtk_widget_set_visible(self.spacer, 0);
    c.gtk_box_append(@ptrCast(column), self.spacer);
    c.gtk_box_append(@ptrCast(column), search);

    // results + detail
    const body = widgets.hbox(0);
    c.gtk_widget_add_css_class(body, "results-island");
    self.results = body;
    self.scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(self.scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    // As tall as the rows, up to the space left under the search bar.
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(self.scroller), 1);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(self.scroller), self.listMaxH());
    c.gtk_widget_set_hexpand(self.scroller, 1);
    self.list = c.gtk_list_box_new();
    c.gtk_widget_add_css_class(self.list, "results");
    c.gtk_list_box_set_selection_mode(@ptrCast(self.list), c.GTK_SELECTION_SINGLE);
    c.gtk_widget_set_focusable(self.list, 0);
    widgets.connect(self.list, "row-activated", &onRowActivated, self);
    self.grid = c.gtk_flow_box_new();
    c.gtk_widget_add_css_class(self.grid, "grid");
    c.gtk_flow_box_set_selection_mode(@ptrCast(self.grid), c.GTK_SELECTION_SINGLE);
    c.gtk_flow_box_set_homogeneous(@ptrCast(self.grid), 1);
    c.gtk_flow_box_set_activate_on_single_click(@ptrCast(self.grid), 1);
    c.gtk_flow_box_set_row_spacing(@ptrCast(self.grid), 6);
    c.gtk_flow_box_set_column_spacing(@ptrCast(self.grid), 6);
    c.gtk_widget_set_focusable(self.grid, 0);
    c.gtk_widget_set_valign(self.grid, c.GTK_ALIGN_START);
    c.gtk_widget_set_visible(self.grid, 0);
    widgets.connect(self.grid, "child-activated", &onGridActivated, self);
    // Both in the scroller; one shows at a time.
    const lists = widgets.vbox(0);
    c.gtk_box_append(@ptrCast(lists), self.list);
    c.gtk_box_append(@ptrCast(lists), self.grid);
    c.gtk_scrolled_window_set_child(@ptrCast(self.scroller), lists);
    c.gtk_box_append(@ptrCast(body), self.scroller);
    detail_pane.buildDetail(self);
    c.gtk_box_append(@ptrCast(body), self.detail);
    c.gtk_box_append(@ptrCast(column), body);

    // footer (lumen.layout { footer = true })
    self.footer = widgets.hbox(8);
    c.gtk_widget_add_css_class(self.footer, "footer");
    c.gtk_widget_set_size_request(self.footer, -1, footer_h);
    self.footer_title = widgets.label("Lumen", "footer-title");
    c.gtk_widget_set_hexpand(self.footer_title, 1);
    c.gtk_label_set_xalign(@ptrCast(self.footer_title), 0);
    c.gtk_label_set_ellipsize(@ptrCast(self.footer_title), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(self.footer), self.footer_title);
    self.footer_action = widgets.label("", "footer-action");
    c.gtk_box_append(@ptrCast(self.footer), self.footer_action);
    self.footer_enter = widgets.label("↵", "kbd");
    c.gtk_widget_set_valign(self.footer_enter, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(self.footer), self.footer_enter);
    self.footer_sep = widgets.label("", "footer-sep");
    c.gtk_widget_set_valign(self.footer_sep, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(self.footer), self.footer_sep);
    c.gtk_box_append(@ptrCast(self.footer), widgets.label("Actions", "footer-action"));
    const fk = widgets.label("Ctrl K", "kbd");
    c.gtk_widget_set_valign(fk, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(self.footer), fk);
    c.gtk_widget_set_visible(self.footer, 0);
    c.gtk_box_append(@ptrCast(column), self.footer);

    // action panel, floating over the top right corner of the results
    self.panel = widgets.vbox(0);
    c.gtk_widget_add_css_class(self.panel, "actions");
    c.gtk_widget_set_halign(self.panel, c.GTK_ALIGN_END);
    c.gtk_widget_set_valign(self.panel, c.GTK_ALIGN_START);
    c.gtk_box_append(@ptrCast(self.panel), widgets.label("Actions", "actions-title"));
    self.panel_list = c.gtk_list_box_new();
    c.gtk_widget_set_focusable(self.panel_list, 0);
    widgets.connect(self.panel_list, "row-activated", &onPanelRowActivated, self);
    c.gtk_box_append(@ptrCast(self.panel), self.panel_list);
    c.gtk_widget_set_visible(self.panel, 0);
    c.gtk_overlay_add_overlay(@ptrCast(overlay), self.panel);

    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    widgets.connect(keys, "key-pressed", &onKey, self);
    c.gtk_widget_add_controller(win, keys);

    // A click on the clear part of the surface hides the window, like one on
    // the backdrop. Capture phase: it sees every press, and claims none.
    const click = c.gtk_gesture_click_new();
    c.gtk_event_controller_set_propagation_phase(click, c.GTK_PHASE_CAPTURE);
    widgets.connect(click, "pressed", &backdrop.onWindowPressed, self);
    c.gtk_widget_add_controller(win, click);
    self.built = true;
    self.scanIconDir();
    self.applyStructure();
}

/// ~/.config/lumen/icons/<name>.svg|png replaces the icon <name> everywhere
/// (widgets.renamed). Read when the window opens: a handful of files.
fn scanIconDir(self: *Ui) void {
    widgets.renamed = .empty;
    if (self.icon_arena) |*ar| _ = ar.reset(.retain_capacity) else self.icon_arena = .init(self.gpa);
    const a = self.icon_arena.?.allocator();
    const dir = std.fmt.allocPrintSentinel(a, "{s}/icons", .{self.config_dir}, 0) catch return;
    const d = c.g_dir_open(dir.ptr, 0, null) orelse return;
    defer c.g_dir_close(d);
    while (c.g_dir_read_name(d)) |n| {
        const name = std.mem.span(n);
        const dot = std.mem.findScalarLast(u8, name, '.') orelse continue;
        const ext = name[dot + 1 ..];
        if (!(std.ascii.eqlIgnoreCase(ext, "svg") or std.ascii.eqlIgnoreCase(ext, "png"))) continue;
        const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0) catch continue;
        widgets.renamed.put(a, a.dupe(u8, name[0..dot]) catch continue, path) catch continue;
    }
}

/// The icon init.lua gave the item with `key` (lumen.icons), if any.
pub fn keyIcon(self: *const Ui, key: []const u8) ?item_mod.Icon {
    const reg = self.ext_registry orelse return null;
    if (key.len == 0) return null;
    for (reg.icons) |o| if (std.mem.eql(u8, o.key, key)) return o.icon;
    return null;
}

fn cssClass(w: *c.GtkWidget, name: [*:0]const u8, on: bool) void {
    if (on) c.gtk_widget_add_css_class(w, name) else c.gtk_widget_remove_css_class(w, name);
}

fn barWidget(self: *Ui, part: layout_mod.BarPart) *c.GtkWidget {
    return switch (part) {
        .back => self.back,
        .icon => self.search_icon,
        .prompt => self.prompt_label,
        .scope => self.scope,
        .entry => self.entry,
        .keys => self.key_chip,
    };
}

/// lumen.layout: the pieces' order, one panel or two, the footer, the
/// detail pane's side, what rows show; then the size. The caller rebuilds
/// the rows.
pub fn applyStructure(self: *Ui) void {
    const l = self.layout;
    widgets.show = l.show;
    widgets.rows_inline = l.rows == .inline_;
    widgets.row_parts = l.row;
    // The search bar's parts in order; setView decides which of them show.
    const bar: *c.GtkBox = @ptrCast(self.search_bar);
    var prev: ?*c.GtkWidget = null;
    for (l.searchbar.slice()) |part| {
        const w = self.barWidget(part);
        c.gtk_box_reorder_child_after(bar, w, prev);
        prev = w;
    }
    c.gtk_label_set_text(@ptrCast(self.prompt_label), l.prompt.ptr);
    c.gtk_widget_set_visible(self.prompt_label, @intFromBool(l.prompt.len > 0 and l.searchbar.has(.prompt)));
    c.gtk_widget_set_visible(self.search_icon, @intFromBool(l.show.search_icon and l.searchbar.has(.icon)));
    const col: *c.GtkBox = @ptrCast(self.column);
    c.gtk_box_set_spacing(col, if (l.panels == .single) 0 else 10);
    cssClass(self.column, "single", l.panels == .single);
    cssClass(self.column, "search-bottom", l.search == .bottom);
    cssClass(self.column, "with-footer", l.footer);
    // spacer, then search and results in the chosen order, footer last.
    c.gtk_box_reorder_child_after(col, self.spacer, null);
    const first, const second = if (l.search == .bottom) .{ self.results, self.search_bar } else .{ self.search_bar, self.results };
    c.gtk_box_reorder_child_after(col, first, self.spacer);
    c.gtk_box_reorder_child_after(col, second, first);
    c.gtk_box_reorder_child_after(col, self.footer, second);
    c.gtk_widget_set_visible(self.spacer, @intFromBool(l.search == .bottom));
    c.gtk_widget_set_visible(self.footer, @intFromBool(l.footer));
    c.gtk_widget_set_visible(self.key_chip, @intFromBool(l.show.key_hints and l.searchbar.has(.keys)));
    // With a footer, or the search bar at the bottom, the action panel opens
    // down there, above them.
    c.gtk_widget_set_valign(self.panel, if (l.footer or l.search == .bottom) c.GTK_ALIGN_END else c.GTK_ALIGN_START);
    cssClass(self.panel, "from-footer", l.footer);
    cssClass(self.panel, "from-bottom", l.search == .bottom);

    const island: *c.GtkBox = @ptrCast(self.results);
    c.gtk_orientable_set_orientation(self.results, if (l.detail == .bottom) c.GTK_ORIENTATION_VERTICAL else c.GTK_ORIENTATION_HORIZONTAL);
    if (l.detail == .left) c.gtk_box_reorder_child_after(island, self.detail, null) else c.gtk_box_reorder_child_after(island, self.detail, self.scroller);
    cssClass(self.results, "detail-left", l.detail == .left);
    cssClass(self.results, "detail-bottom", l.detail == .bottom);
    self.applyLayout();
}

/// Width, height and density from the settings. A layer surface takes its
/// size when it is mapped: a change while it shows maps it again.
fn applyLayout(self: *Ui) void {
    widgets.icon_px = switch (self.settings.density) {
        .compact => 26,
        .default => 32,
        .comfortable => 38,
    };
    if (!self.built) return;
    const w = self.panelW();
    const h = self.panelH();
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(self.scroller), self.listMaxH());
    var cw: c_int = 0;
    var ch: c_int = 0;
    c.gtk_widget_get_size_request(self.column, &cw, &ch);
    if (cw == w and ch == h) return;
    c.gtk_widget_set_size_request(self.column, w, h);
    c.gtk_window_set_default_size(@ptrCast(self.window), w + 2 * shell_margin, h + 2 * shell_margin);
    if (c.gtk_widget_get_visible(self.window) != 0) {
        c.gtk_widget_set_visible(self.window, 0);
        c.gtk_widget_set_visible(self.window, 1);
        _ = c.gtk_widget_grab_focus(self.entry);
    }
    // The list beside a detail pane keeps ~40% of the width.
    if (c.gtk_widget_get_visible(self.detail) != 0) c.gtk_widget_set_size_request(self.scroller, @divTrunc(w * 2, 5), -1);
}

fn loadCss(self: *Ui) void {
    self.css = c.gtk_css_provider_new();
    const display = c.gdk_display_get_default() orelse return;
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(self.css), c.GTK_STYLE_PROVIDER_PRIORITY_USER);
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
    if (self.on_settings_changed) |f| f();
}

/// The Icon Theme setting, for Lumen's process only.
fn applyIconTheme(self: *Ui) void {
    const gs = c.gtk_settings_get_default() orelse return;
    if (self.settings.icon_theme.len == 0) return c.gtk_settings_reset_property(gs, "gtk-icon-theme-name");
    var buf: [128]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&buf, "{s}", .{self.settings.icon_theme}, 0) catch return;
    c.g_object_set(gs, "gtk-icon-theme-name", name.ptr, @as(?*anyopaque, null));
}

/// Writes the settings; what init.lua fixes keeps its value in the file.
pub fn saveSettings(self: *Ui) void {
    var kept: [32][]const u8 = undefined;
    var n: usize = 0;
    if (self.ext_registry) |reg| for (reg.settings) |o| if (n < kept.len) {
        kept[n] = o.key;
        n += 1;
    };
    self.settings.save(self.gpa, self.settings_path, kept[0..n]) catch |err| log.warn("saving settings: {t}", .{err});
    self.settings_stamp = settings_mod.Stamp.of(self.settings_path.ptr);
    self.applyAppearance(null);
    self.applyLayout();
    self.applyIconTheme();
    if (self.on_settings_changed) |f| f();
}

/// `lumen.set` in init.lua, over the file's values.
pub fn applyOverrides(self: *Ui) void {
    const reg = self.ext_registry orelse return;
    for (reg.settings) |o| _ = self.settings.set(o.key, o.value);
}

/// Set by init.lua: Settings shows it but cannot change it.
pub fn overridden(self: *const Ui, key: []const u8) bool {
    // lumen.layout's pixels and place win over these.
    if (std.mem.eql(u8, key, "width") and self.layout.width != null) return true;
    if (std.mem.eql(u8, key, "height") and self.layout.height != null) return true;
    if (std.mem.eql(u8, key, "position") and self.layout.position != null) return true;
    const reg = self.ext_registry orelse return false;
    for (reg.settings) |o| if (std.mem.eql(u8, o.key, key)) return true;
    return false;
}

fn currentTheme(self: *Ui) *const themes.Theme {
    return themes.find(self.settings.theme, self.preferDark());
}

/// Theme variables + style.css + the user's style.css, reloaded only when
/// they changed. `preview` paints a theme without choosing it (moving
/// through Change Theme).
pub fn applyAppearance(self: *Ui, preview: ?*const themes.Theme) void {
    const t = preview orelse self.currentTheme();
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    themes.css(&out.writer, t, &self.settings) catch return;
    out.writer.writeAll(@embedFile("style.css")) catch return;
    self.appendUserCss(&out.writer) catch return;
    out.writer.writeByte(0) catch return;
    const text = out.written();
    _ = themes.hex(&self.hl_fg, t.fg);
    _ = themes.hex(&self.hl_bg, t.accent);
    const h = std.hash.Wyhash.hash(0, text);
    if (h == self.css_hash) return;
    self.css_hash = h;
    c.gtk_css_provider_load_from_string(self.css, @ptrCast(text.ptr));
}

/// $XDG_CONFIG_HOME/lumen/style.css, after Lumen's rules so it wins. The
/// classes it can use are listed in EXTENSIONS.md.
fn appendUserCss(self: *Ui, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/style.css", .{self.config_dir}, 0) catch return;
    self.user_css_stamp = settings_mod.Stamp.of(path.ptr);
    var contents: ?[*:0]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(path.ptr, &contents, &len, null) == 0) return;
    defer c.g_free(contents);
    try w.writeAll("\n/* ~/.config/lumen/style.css */\n");
    try w.writeAll(contents.?[0..len]);
    try w.writeByte('\n');
}

fn userCssChanged(self: *Ui) bool {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/style.css", .{self.config_dir}, 0) catch return false;
    return !settings_mod.Stamp.of(path.ptr).eql(self.user_css_stamp);
}

/// The desktop's light/dark preference (dark when it cannot be read).
pub fn preferDark(self: *Ui) bool {
    const gs = self.interface_settings orelse return true;
    const v = c.g_settings_get_string(gs, "color-scheme");
    defer c.g_free(v);
    return !std.mem.eql(u8, std.mem.span(v), "prefer-light") and !std.mem.eql(u8, std.mem.span(v), "default");
}

fn watchColorScheme(self: *Ui) void {
    const source = c.g_settings_schema_source_get_default() orelse return;
    // Looking the schema up first: g_settings_new aborts on a missing one.
    const schema = c.g_settings_schema_source_lookup(source, "org.gnome.desktop.interface", 1) orelse return;
    defer c.g_settings_schema_unref(schema);
    if (c.g_settings_schema_has_key(schema, "color-scheme") == 0) return;
    self.interface_settings = c.g_settings_new("org.gnome.desktop.interface");
    widgets.connect(self.interface_settings.?, "changed::color-scheme", &onColorScheme, self);
}

fn onColorScheme(_: *c.GSettings, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    if (!std.mem.eql(u8, self.settings.theme, themes.auto_id)) return;
    self.applyAppearance(null);
    if (self.view == .settings or self.view == .themes) self.rebuild();
}

pub fn setReselect(self: *Ui, comptime fmt: []const u8, args: anytype) void {
    const k = std.fmt.bufPrint(&self.reselect, fmt, args) catch "";
    self.reselect_len = k.len;
}

pub fn actionCtx(self: *Ui) run.Ctx {
    return .{ .gpa = self.gpa, .db = &self.db, .settings = &self.settings };
}

// --------------------------------------------------------- show / hide

pub fn toggle(self: *Ui) void {
    if (c.gtk_widget_get_visible(self.window) != 0) self.hide() else self.show();
}

pub fn show(self: *Ui) void {
    self.showWith(.root, null);
}

/// Shows `view`, optionally with `text` already typed in the search bar.
pub fn showWith(self: *Ui, view: View, text: ?[*:0]const u8) void {
    const t_show = stats.now();
    const was_hidden = c.gtk_widget_get_visible(self.window) == 0;
    _ = self.frec_arena.reset(.retain_capacity);
    // Without it, results are ranked by match quality alone.
    self.frec = self.db.loadFrecency(self.frec_arena.allocator(), labels.now()) catch .empty;
    if (c.gtk_widget_get_visible(self.window) == 0) {
        // Edited by hand since the last look?
        if (!settings_mod.Stamp.of(self.settings_path.ptr).eql(self.settings_stamp)) self.reloadSettings();
        if (self.userCssChanged()) self.applyAppearance(null);
        self.scanIconDir();
        ext_view.checkReload(self);
        self.placeOnFocusedMonitor();
        // Opening is a good moment to look for edited files.
        if (self.contents) |cs| cs.poke();
    }
    self.nav_len = 0;
    // The choose view only means something reached from a setting, the
    // ext view from a command.
    self.setView(if (view == .choose and self.choosing == .none) .settings else if (view == .ext and ext_view.command(self) == null) .root else view);
    if (text) |t| c.gtk_editable_set_text(@ptrCast(self.entry), t);
    if (was_hidden) backdrop.showBackdrops(self);
    c.gtk_widget_set_visible(self.window, 1);
    c.gtk_window_present(@ptrCast(self.window));
    _ = c.gtk_widget_grab_focus(self.entry);
    // Focusing selects the text; put the cursor at the end instead.
    c.gtk_editable_set_position(@ptrCast(self.entry), -1);

    // Time to the first painted frame (the frame clock exists once the
    // window is realized, so it is hooked on the first show).
    if (!self.frame_clock_hooked) {
        if (c.gtk_widget_get_frame_clock(self.window)) |clock| {
            widgets.connect(clock, "after-paint", &onAfterPaint, null);
            self.frame_clock_hooked = true;
        }
    }
    if (was_hidden) {
        if (stats.pending) |*p| {
            p.t0 = t_show;
            p.is_show = true;
        }
    }
}

fn onAfterPaint(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    stats.onPainted();
}

pub fn hide(self: *Ui) void {
    dmenu.finish(self, null);
    // A theme previewed but not chosen.
    if (self.view == .themes) self.applyAppearance(null);
    self.closePanel();
    self.confirm_key = "";
    c.gtk_widget_set_visible(self.window, 0);
    backdrop.hideBackdrops(self);
}

/// Puts the window on the monitor Hyprland has focused, a bit above centre.
fn placeOnFocusedMonitor(self: *Ui) void {
    if (testMode()) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const name = hypr.focusedMonitorName(arena.allocator()) orelse return;
    const monitors = c.gdk_display_get_monitors(c.gdk_display_get_default() orelse return);
    const n = c.g_list_model_get_n_items(monitors);
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        const obj = c.g_list_model_get_item(monitors, i) orelse continue;
        defer c.g_object_unref(obj);
        const mon: *c.GdkMonitor = @ptrCast(obj);
        const conn = c.gdk_monitor_get_connector(mon) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(conn), name)) continue;
        c.gtk_layer_set_monitor(@ptrCast(self.window), mon);
        var geo: c.GdkRectangle = undefined;
        c.gdk_monitor_get_geometry(mon, &geo);
        const w: *c.GtkWindow = @ptrCast(self.window);
        const pos: layout_mod.Position = self.layout.position orelse switch (self.settings.position) {
            .upper_third => .upper_third,
            .center => .center,
        };
        const off: c_int = self.layout.offset;
        // The pieces sit `shell_margin` inside the surface (room for shadows).
        const at_bottom = pos == .bottom;
        c.gtk_layer_set_anchor(w, c.GTK_LAYER_SHELL_EDGE_TOP, @intFromBool(!at_bottom));
        c.gtk_layer_set_anchor(w, c.GTK_LAYER_SHELL_EDGE_BOTTOM, @intFromBool(at_bottom));
        const margin: c_int = switch (pos) {
            .top, .bottom => off - shell_margin,
            .upper_third, .center => @max(@divTrunc((geo.height - self.panelH()) * @as(c_int, if (pos == .center) 5 else 3), 10) - shell_margin, 0) + off,
        };
        c.gtk_layer_set_margin(w, if (at_bottom) c.GTK_LAYER_SHELL_EDGE_BOTTOM else c.GTK_LAYER_SHELL_EDGE_TOP, margin);
        return;
    }
}

// --------------------------------------------------------------- views

/// Opens `view`, remembering where to go back to.
pub fn navigate(self: *Ui, view: View) void {
    if (self.nav_len < self.nav.len) {
        const e = &self.nav[self.nav_len];
        e.view = self.view;
        const key = if (self.selectedItem()) |it| it.key else "";
        e.key_len = @min(key.len, e.key.len);
        @memcpy(e.key[0..e.key_len], key[0..e.key_len]);
        self.nav_len += 1;
    }
    self.setView(view);
}

/// Back to the previous view, on the row it was left from.
pub fn goBack(self: *Ui) void {
    if (self.nav_len == 0) return self.setView(.root);
    self.nav_len -= 1;
    const e = &self.nav[self.nav_len];
    @memcpy(self.reselect[0..e.key_len], e.key[0..e.key_len]);
    self.reselect_len = e.key_len;
    self.setView(e.view);
}

/// The view's rows again, query and place kept (a setting changed).
pub fn rebuild(self: *Ui) void {
    _ = self.data_arena.reset(.retain_capacity);
    self.base = self.loadBase(self.data_arena.allocator());
    self.refresh();
}

fn loadBase(self: *Ui, a: std.mem.Allocator) []Item {
    return switch (self.view) {
        .root => self.rootCandidates(a),
        .clipboard => self.clipCandidates(a),
        .windows => self.windowCandidates(a),
        // Searched on every keystroke, straight from the index.
        .files, .contents => &.{},
        .settings => settings_view.settingsCandidates(self, a),
        .themes => settings_view.themeCandidates(self, a),
        .default_apps => settings_view.defaultAppsCandidates(self, a),
        .choose => settings_view.chooseCandidates(self, a),
        .ext => ext_view.base(self),
        // Filtered straight from the session's lines.
        .dmenu => &.{},
        .prefs => prefs_view.candidates(self, a),
        .input => prefs_view.inputCandidates(self, a),
        .form => form_view.candidates(self, a),
    };
}

pub fn setView(self: *Ui, view: View) void {
    const leaving_themes = self.view == .themes and view != .themes;
    // Somewhere else now: the dmenu caller gets no answer.
    if (self.view == .dmenu and view != .dmenu) dmenu.finish(self, null);
    // Change Theme starts on the theme in use.
    if (view == .themes and self.reselect_len == 0) self.setReselect("theme:{s}", .{self.settings.theme});
    self.view = view;
    if (view == .root) self.nav_len = 0;
    if (leaving_themes) self.applyAppearance(null);
    self.closePanel();
    self.confirm_key = "";
    _ = self.data_arena.reset(.retain_capacity);
    if (view == .ext) ext_view.enter(self);
    // Passwords are typed unseen.
    c.gtk_text_set_visibility(@ptrCast(self.entry), @intFromBool(!(view == .input and prefs_view.isPassword(self))));
    self.base = self.loadBase(self.data_arena.allocator());

    const has_detail = view == .clipboard or view == .files or view == .contents or
        (view == .ext and if (ext_view.command(self)) |cmd| cmd.detail else false);
    self.grid_mode = view == .ext and if (ext_view.command(self)) |cmd| cmd.grid else false;
    if (self.grid_mode) {
        self.grid_columns = ext_view.command(self).?.columns;
        c.gtk_flow_box_set_min_children_per_line(@ptrCast(self.grid), @intCast(self.grid_columns));
        c.gtk_flow_box_set_max_children_per_line(@ptrCast(self.grid), @intCast(self.grid_columns));
    }
    c.gtk_widget_set_visible(self.detail_meta, @intFromBool(view != .ext));
    for (self.meta_lines) |l| c.gtk_widget_set_visible(l, 1);
    const bar = self.layout.searchbar;
    const back_shows = view != .root and self.layout.show.back and bar.has(.back);
    c.gtk_widget_set_visible(self.back, @intFromBool(back_shows));
    // The magnifier gives way to the back arrow inside a view.
    c.gtk_widget_set_visible(self.search_icon, @intFromBool(self.layout.show.search_icon and bar.has(.icon) and !back_shows));
    c.gtk_widget_set_visible(self.detail, @intFromBool(has_detail));
    // A preview needs room: the results take the full height then.
    c.gtk_widget_set_vexpand(self.results, @intFromBool(has_detail));
    // With the detail pane, the list takes ~40%.
    // Beside the detail pane the list takes ~40%; above it, ~half the height.
    const detail_below = self.layout.detail == .bottom;
    c.gtk_widget_set_size_request(self.scroller, if (has_detail and !detail_below) @divTrunc(self.panelW() * 2, 5) else -1, -1);
    c.gtk_widget_set_hexpand(self.scroller, @intFromBool(!has_detail or detail_below));
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(self.scroller), if (has_detail and detail_below) @divTrunc(self.listMaxH(), 2) else self.listMaxH());
    const keys: [4][:0]const u8 = switch (view) {
        .files => .{ "Kind", "Size", "Modified", "Where" },
        .contents => .{ "Kind", "Matches", "Modified", "Where" },
        else => .{ "Content type", "Characters", "Words", "Copied" },
    };
    for (self.meta_keys, keys) |w, k| c.gtk_label_set_text(@ptrCast(w), k);
    // Code previews do not wrap, they clip long lines like an editor: a
    // wrapping widgets.label makes GTK lay its text out at several widths per frame
    // (~30 ms measured with `lumen --stats`). Clipboard text is prose: wrap.
    const wrap = view == .clipboard or view == .ext;
    c.gtk_label_set_wrap(@ptrCast(self.detail_text), @intFromBool(wrap));
    c.gtk_label_set_ellipsize(@ptrCast(self.detail_text), if (wrap) c.PANGO_ELLIPSIZE_NONE else c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_visible(self.detail_picture, 0);
    var placeholder_buf: [128]u8 = undefined;
    c.gtk_text_set_placeholder_text(@ptrCast(self.entry), switch (view) {
        .root => "Search for apps and commands...",
        .clipboard => "Type to filter entries...",
        .windows => "Search windows...",
        .files => "Search files...",
        .contents => "Search text inside files...",
        .settings => "Search settings...",
        .themes => "Search themes...",
        .default_apps => "Search file kinds...",
        .choose => if (self.choosing == .setting) "Filter values..." else "Search apps...",
        .ext => ext_view.placeholder(self, &placeholder_buf),
        .dmenu => "Filter...",
        .prefs => "Search preferences...",
        .input => prefs_view.inputTitle(self),
        .form => "Search fields...",
    });
    c.gtk_label_set_text(@ptrCast(self.scope), self.viewTitle());
    c.gtk_widget_set_visible(self.scope, @intFromBool(view != .root and self.layout.show.scope and bar.has(.scope)));
    c.gtk_label_set_text(@ptrCast(self.footer_title), self.viewTitle());

    // Setting the text triggers `changed`, which refreshes.
    if (c.gtk_editable_get_text(@ptrCast(self.entry))[0] == 0) self.refresh() else c.gtk_editable_set_text(@ptrCast(self.entry), "");
}

fn rootCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    var all: std.ArrayList(Item) = .empty;
    all.appendSlice(a, self.apps.items) catch {};
    all.appendSlice(a, &commands.all) catch {};
    all.appendSlice(a, scripts.load(a)) catch {};
    all.appendSlice(a, ext_view.rootItems(self, a)) catch {};
    return all.items;
}

fn clipCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    const clips = self.db.recentClips(a, 500) catch return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (clips) |clip| {
        out.append(a, .{
            .title = labels.firstLine(a, clip.content),
            .icon = .{ .tile = .{ .name = "edit-copy-symbolic", .color = .gray } },
            .action = .{ .clip = clip.id },
            .detail = clip.content,
            .score = std.math.lossyCast(i32, clip.last_copied),
        }) catch break;
    }
    return out.items;
}

fn windowCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (hypr.clients(a)) |cl| {
        if (!cl.mapped or cl.address.len == 0) continue;
        const icon: item_mod.Icon = if (self.apps.iconForClass(cl.class)) |g|
            .{ .gicon = g }
        else
            .{ .tile = .{ .name = "focus-windows-symbolic", .color = .blue } };
        out.append(a, .{
            .title = labels.displayText(a, if (cl.title.len > 0) cl.title else cl.class),
            .subtitle = labels.displayText(a, cl.class),
            .accessory = std.fmt.allocPrintSentinel(a, "Workspace {s}", .{cl.workspace.name}, 0) catch "",
            .icon = icon,
            .action = .{ .focus_window = a.dupeSentinel(u8, cl.address, 0) catch continue },
        }) catch break;
    }
    return out.items;
}

// ------------------------------------------------------------- refresh

pub fn query(self: *Ui) []const u8 {
    return std.mem.span(c.gtk_editable_get_text(@ptrCast(self.entry)));
}

/// No rows (what they pointed to is going away).
pub fn clearRows(self: *Ui) void {
    _ = self.query_arena.reset(.retain_capacity);
    self.items = .empty;
    self.rows = .empty;
    self.selected = null;
    self.primary = "";
    c.gtk_list_box_remove_all(@ptrCast(self.list));
}

pub fn refresh(self: *Ui) void {
    const t0 = stats.now();
    self.search_ns = 0;
    defer {
        const total = stats.now() - t0;
        stats.pending = .{ .t0 = t0, .view = self.view, .search = self.search_ns, .rows = total -| self.search_ns, .is_show = false };
    }
    _ = self.query_arena.reset(.retain_capacity);
    const a = self.query_arena.allocator();
    self.items = .empty;
    self.rows = .empty;
    self.selected = null;
    self.confirm_key = "";
    c.gtk_list_box_remove_all(@ptrCast(self.list));
    c.gtk_flow_box_remove_all(@ptrCast(self.grid));
    // The rows holding the previous icons are gone; GtkImage kept its refs.
    for (self.icons.items) |icon| c.g_object_unref(icon);
    self.icons.clearRetainingCapacity();

    const q = std.mem.trim(u8, self.query(), " ");
    switch (self.view) {
        .root => self.fillRoot(a, q),
        .clipboard => self.fillFiltered(a, q, true),
        .windows => self.fillFiltered(a, q, false),
        .files => if (q.len > 0) {
            self.addSection("Files");
            for (file_results.fileItems(self, a, q, 60)) |it| self.addItem(it);
        },
        .contents => if (q.len >= 3) {
            if (self.content_search) |cs| {
                // Ask the worker unless the result for this exact query is
                // already here; meanwhile keep showing the last result.
                // The worker searches the clipped query: compare with that,
                // or a query longer than the clip never counts as answered.
                const fresh = if (self.content_result) |r| std.mem.eql(u8, r.query, ContentSearch.clip(q)) else false;
                if (!fresh) self.content_gen = cs.submit(q, t0);
                self.content_pending = !fresh;
                if (self.content_result) |r| {
                    self.addSection("Matches");
                    for (file_results.itemsFromHits(self, a, r.hits)) |it| self.addItem(it);
                }
            } else {
                self.addSection("Matches");
                for (file_results.contentItems(self, a, q, 50)) |it| self.addItem(it);
            }
        },
        .settings, .themes, .default_apps, .choose => self.fillSectioned(a, q),
        // Search commands are asked for `q`; list commands filter here.
        .ext => self.fillSectioned(a, if (ext_view.prepare(self, q)) q else ""),
        .dmenu => dmenu.fill(self, a, q),
        .prefs => self.fillSectioned(a, q),
        // What is typed is the value, not a filter.
        .input => self.fillSectioned(a, ""),
        .form => self.fillSectioned(a, q),
    }
    const searching = self.view == .files or self.view == .contents;
    if (self.rows.items.len == 0 or (searching and self.items.items.len == 0)) {
        if (self.rows.items.len > 0) c.gtk_list_box_remove_all(@ptrCast(self.list));
        self.rows.clearRetainingCapacity();
        const empty = self.emptyText(a);
        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_selectable(@ptrCast(row), 0);
        c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
        c.gtk_list_box_row_set_child(@ptrCast(row), widgets.label(empty, "empty"));
        c.gtk_list_box_append(@ptrCast(self.list), row);
    }
    // A grid shows its cells; the list is there for the "No Results" row.
    c.gtk_widget_set_visible(self.grid, @intFromBool(self.grid_mode and self.items.items.len > 0));
    c.gtk_widget_set_visible(self.list, @intFromBool(!self.grid_mode or self.items.items.len == 0));
    // Nothing typed and nothing to suggest: only the search bar shows.
    const alone = self.view == .root and q.len == 0 and self.items.items.len == 0;
    c.gtk_widget_set_visible(self.results, @intFromBool(!alone));
    // One panel with only the search bar showing rounds all its corners.
    cssClass(self.column, "alone", alone);

    const adj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(self.scroller));
    c.gtk_adjustment_set_value(adj, 0);
    var first = self.nextSelectable(null, 1);
    if (self.reselect_len > 0) {
        const want = self.reselect[0..self.reselect_len];
        self.reselect_len = 0;
        for (self.rows.items, 0..) |row, i| {
            const ii = row.item orelse continue;
            if (std.mem.eql(u8, self.items.items[ii].key, want)) {
                first = i;
                break;
            }
        }
    }
    self.select(first);
}

/// Settings-style lists: grouped by section, filtered by typing.
fn fillSectioned(self: *Ui, a: std.mem.Allocator, q: []const u8) void {
    if (q.len == 0) {
        var last: ?[]const u8 = null;
        for (self.base) |it| {
            if (last == null or !std.mem.eql(u8, last.?, it.section)) {
                if (it.section.len > 0) self.addSection(it.section);
                last = it.section;
            }
            self.addItem(it);
        }
        return;
    }
    var hits: std.ArrayList(Item) = .empty;
    for (self.base) |it| {
        const fields = [_][]const u8{ it.title, it.keywords, it.subtitle, it.accessory };
        const sc = core.fuzzy.scoreFields(q, &fields);
        if (sc == core.fuzzy.no_match) continue;
        var copy = it;
        copy.score = sc;
        hits.append(a, copy) catch break;
    }
    sortByScore(hits.items);
    for (hits.items) |it| self.addItem(it);
}

fn fillRoot(self: *Ui, a: std.mem.Allocator, q: []const u8) void {
    if (q.len == 0) {
        // Suggestions: what was used most, then every command.
        var used: std.ArrayList(Item) = .empty;
        for (self.base) |it| {
            const v = self.frec.get(it.key) orelse continue;
            var copy = it;
            copy.score = std.math.lossyCast(i32, v * 1000);
            used.append(a, copy) catch break;
        }
        sortByScore(used.items);
        if (used.items.len > 0 and self.settings.suggestions) {
            self.addSection("Suggestions");
            for (used.items[0..@min(used.items.len, 6)]) |it| self.addItem(it);
        }
        self.addSection("Commands");
        for (self.base) |it| {
            switch (it.action) {
                .view, .script, .ext_command, .ext_problem => self.addItem(it),
                else => {},
            }
        }
        return;
    }

    if (core.calc.evaluate(q)) |r| {
        self.addSection("Calculator");
        var buf: [64]u8 = undefined;
        const plain = a.dupe(u8, core.calc.formatPlain(&buf, r.value)) catch "";
        self.addItem(.{
            .title = a.dupeSentinel(u8, q, 0) catch "",
            .subtitle = a.dupeSentinel(u8, r.from_unit, 0) catch "",
            .accessory = a.dupeSentinel(u8, r.unit, 0) catch "",
            .action = .calc,
            .detail = plain,
        });
    }
    // Extensions' answers (rows from `root = function(query)`).
    ext_view.addRootSections(self, q);

    const t_search = stats.now();
    defer self.search_ns += stats.now() - t_search;
    var hits: std.ArrayList(Item) = .empty;
    for (self.base) |it| {
        const fields = [_][]const u8{ it.title, it.keywords, it.subtitle };
        const s = core.fuzzy.scoreFields(q, &fields);
        if (s == core.fuzzy.no_match) continue;
        var copy = it;
        copy.score = s + core.frecency.boost(self.frec.get(it.key) orelse 0);
        hits.append(a, copy) catch break;
    }
    sortByScore(hits.items);
    // Files from 3 letters on, right after the best few results so they are
    // visible without scrolling; the rest of the results follow.
    const files = if (q.len >= 3 and self.settings.files_in_root) file_results.fileItems(self, a, q, 5) else &.{};
    const shown = @min(hits.items.len, max_results);
    const head = if (files.len > 0) @min(shown, 6) else shown;
    for (hits.items[0..head]) |it| self.addItem(it);
    if (files.len > 0) {
        self.addSection("Files");
        for (files) |it| self.addItem(it);
        if (shown > head) self.addSection("More Results");
        for (hits.items[head..shown]) |it| self.addItem(it);
    }
}

fn fillFiltered(self: *Ui, a: std.mem.Allocator, q: []const u8, by_day: bool) void {
    if (q.len == 0) {
        if (by_day) {
            const today = labels.startOfToday();
            var last: ?[:0]const u8 = null;
            for (self.base) |it| {
                // `score` holds the last-copied time until a query re-scores.
                const section: [:0]const u8 = if (it.score >= today) "Today" else if (it.score >= today - 86400) "Yesterday" else "Earlier";
                if (last == null or !std.mem.eql(u8, last.?, section)) {
                    self.addSection(section);
                    last = section;
                }
                self.addItem(it);
            }
        } else {
            for (self.base) |it| self.addItem(it);
        }
        return;
    }
    const t_search = stats.now();
    defer self.search_ns += stats.now() - t_search;
    var hits: std.ArrayList(Item) = .empty;
    for (self.base) |it| {
        const text = if (it.detail.len > 0) it.detail[0..@min(it.detail.len, 2000)] else it.title;
        const fields = [_][]const u8{ text, it.subtitle };
        const s = core.fuzzy.scoreFields(q, &fields);
        if (s == core.fuzzy.no_match) continue;
        var copy = it;
        copy.score = s;
        hits.append(a, copy) catch break;
    }
    sortByScore(hits.items);
    for (hits.items[0..@min(hits.items.len, 200)]) |it| self.addItem(it);
}

/// Best first; equal scores by title, so the order never depends on the
/// sort's whims (two apps tied for "e2e" swapped between runs).
fn sortByScore(items: []Item) void {
    std.mem.sort(Item, items, {}, struct {
        fn gt(_: void, x: Item, y: Item) bool {
            if (x.score != y.score) return x.score > y.score;
            return std.mem.order(u8, x.title, y.title) == .lt;
        }
    }.gt);
}

pub fn addSection(self: *Ui, title: [:0]const u8) void {
    // A grid has no sections: rows and items stay one to one there.
    if (self.grid_mode or !self.layout.show.section_titles) return;
    // Room first: a widget without its `rows` entry would shift every later
    // row's index.
    self.rows.ensureUnusedCapacity(self.query_arena.allocator(), 1) catch return;
    const row = c.gtk_list_box_row_new();
    c.gtk_widget_add_css_class(row, "section");
    c.gtk_list_box_row_set_selectable(@ptrCast(row), 0);
    c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
    c.gtk_list_box_row_set_child(@ptrCast(row), widgets.label(title, "section-title"));
    c.gtk_list_box_append(@ptrCast(self.list), row);
    self.rows.appendAssumeCapacity(.{ .widget = row, .item = null, .section = title });
}

pub fn addItem(self: *Ui, it_in: Item) void {
    var it = it_in;
    if (self.keyIcon(it.key)) |icon| it.icon = icon;
    const a = self.query_arena.allocator();
    const item_index = self.items.items.len;
    // Room first: a widget without its `rows` entry would shift every later
    // row's index (and `onRowActivated` would select the wrong item).
    self.rows.ensureUnusedCapacity(a, 1) catch return;
    self.items.append(a, it) catch return;
    if (self.grid_mode) {
        const gap = 6 * (self.grid_columns - 1) + 24;
        const cell = widgets.gridCell(it, @divTrunc(self.panelW() - gap, self.grid_columns) - 12);
        c.gtk_flow_box_append(@ptrCast(self.grid), cell);
        const child = c.gtk_flow_box_get_child_at_index(@ptrCast(self.grid), @intCast(item_index)) orelse return;
        self.rows.appendAssumeCapacity(.{ .widget = @ptrCast(child), .item = item_index });
        return;
    }
    var parts: widgets.RowParts = .{};
    const row = if (it.action == .calc) widgets.calcRow(it) else widgets.itemRow(it, &parts);
    c.g_object_set_data(@ptrCast(row), "lumen-row", @ptrFromInt(self.rows.items.len + 1));
    c.gtk_list_box_append(@ptrCast(self.list), row);
    self.rows.appendAssumeCapacity(.{ .widget = row, .item = item_index, .hint = parts.hint, .accessory = parts.accessory });
}

// ----------------------------------------------------------- selection

pub fn nextSelectable(self: *Ui, from: ?usize, dir: i32) ?usize {
    const n = self.rows.items.len;
    if (n == 0) return null;
    var i: i64 = if (from) |f| @as(i64, @intCast(f)) + dir else if (dir > 0) 0 else @as(i64, @intCast(n)) - 1;
    while (i >= 0 and i < n) : (i += dir) {
        if (self.rows.items[@intCast(i)].item != null) return @intCast(i);
    }
    return from;
}

pub fn select(self: *Ui, row_index: ?usize) void {
    if (self.selected) |old| if (old < self.rows.items.len) {
        const r = self.rows.items[old];
        if (r.hint) |h| c.gtk_widget_set_visible(h, 0);
        if (r.accessory) |acc| c.gtk_widget_set_visible(acc, 1);
    };
    self.selected = row_index;
    self.confirm_key = "";
    self.primary = "";
    const ri = row_index orelse {
        self.setFooterAction("", false);
        c.gtk_list_box_unselect_all(@ptrCast(self.list));
        c.gtk_flow_box_unselect_all(@ptrCast(self.grid));
        detail_pane.showDetail(self, null);
        return;
    };
    const row = self.rows.items[ri];
    if (self.grid_mode)
        c.gtk_flow_box_select_child(@ptrCast(self.grid), @ptrCast(row.widget))
    else
        c.gtk_list_box_select_row(@ptrCast(self.list), @ptrCast(row.widget));
    self.scrollTo(row.widget);
    const it = &self.items.items[row.item.?];
    self.primary = item_mod.actionsFor(it)[0].label;
    self.setHint(self.primary, false);
    detail_pane.showDetail(self, it);
    // Change Theme shows each theme as the selection moves over it.
    if (self.view == .themes and it.action == .setting and it.action.setting == .theme)
        self.applyAppearance(themes.find(it.action.setting.theme, self.preferDark()));
}

/// The footer's "what Enter does" (hidden with nothing selected).
fn setFooterAction(self: *Ui, text: []const u8, warn: bool) void {
    const z = self.query_arena.allocator().dupeSentinel(u8, text, 0) catch return;
    c.gtk_label_set_text(@ptrCast(self.footer_action), z.ptr);
    cssClass(self.footer_action, "warn", warn);
    const any = text.len > 0;
    c.gtk_widget_set_visible(self.footer_action, @intFromBool(any));
    c.gtk_widget_set_visible(self.footer_enter, @intFromBool(any and !warn));
    c.gtk_widget_set_visible(self.footer_sep, @intFromBool(any));
}

/// The selected row's hint: "Open ↵", or a warning waiting for Enter (and
/// the footer's, which says the same).
fn setHint(self: *Ui, text: []const u8, warn: bool) void {
    self.setFooterAction(text, warn);
    if (!self.layout.show.hints and !warn) return;
    const ri = self.selected orelse return;
    const row = self.rows.items[ri];
    const h = row.hint orelse return;
    if (row.accessory) |acc| c.gtk_widget_set_visible(acc, 0);
    // Beside the detail pane the list is narrow: the action's name would
    // squeeze the title to a few letters, so only the key shows there.
    const narrow = c.gtk_widget_get_visible(self.detail) != 0;
    const shown = if (warn) text else if (narrow) "↵" else std.fmt.allocPrint(self.query_arena.allocator(), "{s}  ↵", .{text}) catch return;
    const z = self.query_arena.allocator().dupeSentinel(u8, shown, 0) catch return;
    c.gtk_label_set_text(@ptrCast(h), z.ptr);
    if (warn) c.gtk_widget_add_css_class(h, "warn") else c.gtk_widget_remove_css_class(h, "warn");
    c.gtk_widget_set_visible(h, 1);
}

fn scrollTo(self: *Ui, row: *c.GtkWidget) void {
    var b: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(row, if (self.grid_mode) self.grid else self.list, &b) == 0) return;
    const adj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(self.scroller));
    const value = c.gtk_adjustment_get_value(adj);
    const page = c.gtk_adjustment_get_page_size(adj);
    const top: f64 = b.origin.y;
    const bottom: f64 = top + b.size.height;
    // Keep a section header above the first item visible, and the selection
    // clear of the fade at the bottom edge (style.css, undershoot).
    if (top < value + 4) c.gtk_adjustment_set_value(adj, @max(top - 30, 0)) else if (bottom > value + page - 20) c.gtk_adjustment_set_value(adj, bottom - page + 20);
}

pub fn selectedItem(self: *Ui) ?*Item {
    const ri = self.selected orelse return null;
    return &self.items.items[self.rows.items[ri].item orelse return null];
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
        .ext => if (ext_view.command(self)) |cmd| cmd.title else "Extension",
        .dmenu => dmenu.title(self),
        .prefs => prefs_view.title(self),
        .input => prefs_view.inputTitle(self),
        .form => form_view.title(self),
    };
}

// --------------------------------------------------------- action panel

pub fn openPanel(self: *Ui) void {
    const it = self.selectedItem() orelse return;
    self.panel_entries = item_mod.actionsFor(it);
    c.gtk_list_box_remove_all(@ptrCast(self.panel_list));
    for (self.panel_entries) |e| {
        const row = c.gtk_list_box_row_new();
        const box = widgets.hbox(8);
        const l = widgets.label(e.label, null);
        c.gtk_widget_set_hexpand(l, 1);
        c.gtk_box_append(@ptrCast(box), l);
        if (e.keys.len > 0) {
            const k = widgets.label(e.keys, "kbd");
            c.gtk_widget_set_valign(k, c.GTK_ALIGN_CENTER);
            c.gtk_box_append(@ptrCast(box), k);
        }
        c.gtk_list_box_row_set_child(@ptrCast(row), box);
        c.gtk_list_box_append(@ptrCast(self.panel_list), row);
    }
    self.panel_selected = 0;
    self.panel_open = true;
    self.selectPanel(0);
    c.gtk_widget_set_visible(self.panel, 1);
}

pub fn closePanel(self: *Ui) void {
    self.panel_open = false;
    c.gtk_widget_set_visible(self.panel, 0);
}

pub fn selectPanel(self: *Ui, i: usize) void {
    self.panel_selected = i;
    const row = c.gtk_list_box_get_row_at_index(@ptrCast(self.panel_list), @intCast(i));
    c.gtk_list_box_select_row(@ptrCast(self.panel_list), row);
}

// ------------------------------------------------------------- actions

/// Runs one of the selected row's actions (a row of the action panel, or
/// what Enter and Ctrl+Enter do).
pub fn performEntry(self: *Ui, e: item_mod.Entry) void {
    if (e.op == .ext) return ext_view.perform(self, e.index);
    self.perform(e.op);
}

/// Destructive commands need a second Enter: true while waiting for it
/// (the row says so).
pub fn needsConfirm(self: *Ui, it: *const Item) bool {
    if (std.mem.eql(u8, self.confirm_key, it.key)) return false;
    self.confirm_key = it.key;
    self.primary = std.fmt.allocPrintSentinel(self.query_arena.allocator(), "Press ↵ again to {s}", .{it.title}, 0) catch return true;
    self.setHint(self.primary, true);
    return true;
}

/// It did not work: say so on the selected row. `msg` must outlive the rows.
pub fn showFailure(self: *Ui, msg: [:0]const u8) void {
    self.primary = msg;
    self.setHint(msg, true);
}

/// A Lua action is running.
pub fn showRunning(self: *Ui) void {
    self.primary = "Running...";
    self.setHint(self.primary, false);
}

pub fn perform(self: *Ui, op: item_mod.Op) void {
    const it = self.selectedItem() orelse return;
    if (it.confirm and (op == .run or op == .open) and self.needsConfirm(it)) return;
    self.closePanel();
    // Ranking only (Db logs failures): the action goes ahead regardless.
    if (it.key.len > 0 and it.action != .setting and (op == .run or op == .open)) self.db.recordUse(it.key, labels.now()) catch {};
    if (it.action == .ext_command and (op == .run or op == .open)) return ext_view.activate(self, it.action.ext_command.index);
    if (it.action == .pick) return if (op == .pick_typed) dmenu.chooseTyped(self) else dmenu.choose(self, it.action.pick.index);

    const outcome = run.perform(self.actionCtx(), it, op);
    switch (outcome) {
        .hide => self.hide(),
        .stay => {},
        .refresh_view => self.setView(self.view),
        .open_view => |v| self.navigate(v),
        .setting => |sa| settings_view.performSetting(self, sa.setting, sa.op),
        .choose_app => |path| settings_view.chooseAppFor(self, path),
        .failed => |msg| {
            self.primary = msg;
            self.setHint(msg, true);
        },
    }
}

// ----------------------------------------------------------- callbacks

fn onChanged(_: *c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    self.refresh();
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const tag = @intFromPtr(c.g_object_get_data(@ptrCast(row), "lumen-row"));
    if (tag == 0) return;
    self.select(tag - 1);
    const it = self.selectedItem() orelse return;
    self.performEntry(item_mod.actionsFor(it)[0]);
}

fn onGridActivated(_: *c.GtkFlowBox, child: *c.GtkFlowBoxChild, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const i = c.gtk_flow_box_child_get_index(child);
    if (i < 0 or i >= self.rows.items.len) return;
    self.select(@intCast(i));
    const it = self.selectedItem() orelse return;
    self.performEntry(item_mod.actionsFor(it)[0]);
}

fn onPanelRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const i: usize = @intCast(c.gtk_list_box_row_get_index(row));
    if (i < self.panel_entries.len) self.performEntry(self.panel_entries[i]);
}

fn onBackClicked(_: *c.GtkEventController, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    if (self.view != .root) self.goBack();
    _ = c.gtk_widget_grab_focus(self.entry);
}

fn onAppsChanged(_: *c.GAppInfoMonitor, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    self.apps.reload();
    if (self.view == .root) self.setView(.root);
}

fn onKey(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Ui = @ptrCast(@alignCast(data));
    return keyboard.handleKey(self, keyval, state);
}

/// `lumen --key NAME`: the same handling as a real key press, for tests.
/// Names: down, up, enter, ctrl+enter, ctrl+k, escape, backspace, pagedown,
/// pageup, ctrl+x.
pub fn injectKey(self: *Ui, name: []const u8) bool {
    const keys = [_]struct { []const u8, c_uint, c.GdkModifierType }{
        .{ "down", c.GDK_KEY_Down, 0 },                 .{ "up", c.GDK_KEY_Up, 0 },
        .{ "enter", c.GDK_KEY_Return, 0 },              .{ "ctrl+enter", c.GDK_KEY_Return, c.GDK_CONTROL_MASK },
        .{ "ctrl+k", c.GDK_KEY_k, c.GDK_CONTROL_MASK }, .{ "escape", c.GDK_KEY_Escape, 0 },
        .{ "backspace", c.GDK_KEY_BackSpace, 0 },       .{ "pagedown", c.GDK_KEY_Page_Down, 0 },
        .{ "pageup", c.GDK_KEY_Page_Up, 0 },            .{ "ctrl+x", c.GDK_KEY_x, c.GDK_CONTROL_MASK },
        .{ "ctrl+o", c.GDK_KEY_o, c.GDK_CONTROL_MASK }, .{ "left", c.GDK_KEY_Left, 0 },
        .{ "right", c.GDK_KEY_Right, 0 },
    };
    for (keys) |k| if (std.mem.eql(u8, k[0], name)) {
        _ = keyboard.handleKey(self, k[1], k[2]);
        return true;
    };
    // Anything else written like a keymap ("ctrl+g").
    const parsed = ext_view.parseKey(name) orelse return false;
    _ = keyboard.handleKey(self, parsed.keyval, parsed.mods);
    return true;
}

/// `lumen --dump`: what the window shows, as text (for end-to-end tests).
/// Caller owns the result, allocated with `gpa`.
pub fn dump(self: *Ui, gpa: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)![:0]u8 {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const a = scratch_state.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("view: {t}\nvisible: {}\nquery: {s}\n", .{ self.view, c.gtk_widget_get_visible(self.window) != 0, self.query() });
    try w.print("title: {s}\nprimary: {s}\n", .{ self.viewTitle(), self.primary });
    const lay = self.layout;
    try w.print("layout: {d}x{d} panels={t} search={t} detail={t} rows={s} footer={}", .{ self.panelW(), self.panelH(), lay.panels, lay.search, lay.detail, if (lay.rows == .inline_) "inline" else "stacked", lay.footer });
    try w.writeAll(" bar=");
    for (lay.searchbar.slice(), 0..) |p, i| try w.print("{s}{t}", .{ if (i > 0) "," else "", p });
    try w.writeAll(" row=");
    for (lay.row.slice(), 0..) |p, i| try w.print("{s}{t}", .{ if (i > 0) "," else "", p });
    try w.print(" prompt={s}\n", .{lay.prompt});
    if (lay.footer) try w.print("footer: {s} | {s}\n", .{ c.gtk_label_get_text(@ptrCast(self.footer_title)), c.gtk_label_get_text(@ptrCast(self.footer_action)) });
    try w.print("rows:\n", .{});
    if (self.rows.items.len == 0) try w.print("  (empty) {s}\n", .{self.emptyText(a)});
    for (self.rows.items, 0..) |row, i| {
        const it_index = row.item orelse {
            try w.print("  # {s}\n", .{row.section});
            continue;
        };
        const it = self.items.items[it_index];
        const mark: []const u8 = if (self.selected == i) ">" else " ";
        try w.print("  {s} {s} | {s} | {s} | ", .{ mark, it.title, it.subtitle, it.accessory });
        switch (it.icon) {
            .logo => |l| try w.print("logo:{s}", .{l.name}),
            .badge => |b| try w.print("badge:{s}", .{b.text}),
            .tile => |t| try w.print("tile:{s}", .{t.name}),
            .gicon => try w.print("gicon", .{}),
            .emoji => |e| try w.print("emoji:{s}", .{e}),
            .file => |f| try w.print("file:{s}", .{std.Io.Dir.path.basename(f)}),
            .swatch => |sw| try w.print("swatch:{s}", .{sw.id}),
            .named => |n| try w.print("icon:{s}", .{n}),
            .none => try w.print("none", .{}),
        }
        // The key, for lumen.icons (empty for rows without one). A file's is
        // its path, which need not be UTF-8: the dump must stay text.
        try w.print(" | {s}\n", .{if (std.unicode.utf8ValidateSlice(it.key)) it.key else "?"});
    }
    if (c.gtk_widget_get_visible(self.detail) != 0) {
        try w.print("detail:\n", .{});
        if (self.view == .ext) {
            const text = std.mem.span(c.gtk_label_get_text(@ptrCast(self.detail_text)));
            try w.print("  text = {s}\n", .{text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len]});
        }
        if (c.gtk_widget_get_visible(self.detail_meta) != 0) {
            for (self.meta_lines, self.meta_keys, self.meta_values) |l, k, v| {
                if (c.gtk_widget_get_visible(l) == 0) continue;
                try w.print("  {s} = {s}\n", .{ c.gtk_label_get_text(@ptrCast(k)), c.gtk_label_get_text(@ptrCast(v)) });
            }
        }
    }
    if (self.panel_open) {
        try w.print("panel:\n", .{});
        for (self.panel_entries, 0..) |e, i| try w.print("  {s} {s} [{s}]\n", .{ if (i == self.panel_selected) ">" else " ", e.label, e.keys });
    }
    return out.toOwnedSliceSentinel(0);
}

/// The placeholder row's text when nothing is listed.
fn emptyText(self: *Ui, a: std.mem.Allocator) [:0]const u8 {
    const q = std.mem.trim(u8, self.query(), " ");
    if (self.view == .files and q.len == 0) return file_results.filesHint(self, a);
    if (self.view == .contents and q.len < 3) return file_results.contentsHint(self, a, q.len);
    if (self.view == .contents and self.content_pending) return "Searching...";
    if (self.view == .contents) if (self.content_result) |r| if (r.err) |err|
        return std.fmt.allocPrintSentinel(a, "Content search failed ({t})", .{err}, 0) catch "Content search failed";
    if (self.view == .clipboard and q.len == 0 and !self.settings.clipboard) return "Clipboard history is off: turn it on in Settings";
    if (self.view == .ext) return ext_view.emptyText(self, a, q);
    if (self.view == .dmenu) return dmenu.emptyText(self);
    return "No Results";
}
