//! The launcher window: a gtk4-layer-shell overlay with a search bar, a list
//! of results, an optional detail pane, a footer and the action panel.
//!
//! One instance lives for the whole daemon; showing and hiding the window is
//! what the global hotkey does.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
pub const View = item_mod.View;
const Db = @import("../sys/db.zig").Db;
const hypr = @import("../sys/hypr.zig");
const proc = @import("../sys/proc.zig");
const Apps = @import("../providers/apps.zig").Apps;
const commands = @import("../providers/commands.zig");
const scripts = @import("../providers/scripts.zig");
const run = @import("../actions.zig");
const index = @import("index");
const logos = @import("logos.zig");
const stats = @import("../stats.zig");
pub const ContentSearch = @import("ContentSearch.zig");
const settings_mod = @import("../settings.zig");
const Settings = settings_mod.Settings;
const themes = @import("themes.zig");
const Kind = core.file_kind.Kind;

const Ui = @This();

const panel_w = 750;
const panel_h = 474;
const max_results = 60;

gpa: std.mem.Allocator,
app: *c.GtkApplication,
db: Db,
apps: Apps,

window: *c.GtkWidget = undefined,
entry: *c.GtkWidget = undefined,
back: *c.GtkWidget = undefined,
list: *c.GtkWidget = undefined,
scroller: *c.GtkWidget = undefined,
detail: *c.GtkWidget = undefined,
detail_text: *c.GtkWidget = undefined,
detail_picture: *c.GtkWidget = undefined,
meta_keys: [4]*c.GtkWidget = undefined,
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
footer_icon: *c.GtkWidget = undefined,
footer_title: *c.GtkWidget = undefined,
primary_label: *c.GtkWidget = undefined,
primary_keys: *c.GtkWidget = undefined,
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
settings_path: [:0]const u8 = "",
/// The settings file as last read or written: a different one on disk was
/// edited by hand.
settings_stamp: settings_mod.Stamp = .{},
/// Called after the settings change (main starts or stops the clipboard
/// watcher).
on_settings_changed: ?*const fn () void = null,
css: *c.GtkCssProvider = undefined,
css_hash: u64 = 0,
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

const Choosing = union(enum) {
    none,
    setting: settings_mod.Choice,
    kind: Kind,
    /// Open With for one file; both strings are owned by `gpa`.
    file: struct { path: [:0]u8, mime: [:0]u8 },
};

const Row = struct { widget: *c.GtkWidget, item: ?usize, section: [:0]const u8 = "" };

/// End-to-end tests run a second, isolated Lumen (LUMEN_TEST=1): it must not
/// take the keyboard from the session, nor ask Hyprland where to go.
fn testMode() bool {
    return c.g_getenv("LUMEN_TEST") != null;
}

pub fn init(gpa: std.mem.Allocator, app: *c.GtkApplication, db: Db) Ui {
    return .{
        .gpa = gpa,
        .app = app,
        .db = db,
        .apps = Apps.init(gpa),
        .settings = Settings.init(gpa),
        .data_arena = std.heap.ArenaAllocator.init(gpa),
        .query_arena = std.heap.ArenaAllocator.init(gpa),
        .frec_arena = std.heap.ArenaAllocator.init(gpa),
    };
}

// ------------------------------------------------------------ building

pub fn build(self: *Ui) void {
    self.apps.reload();
    const monitor = c.g_app_info_monitor_get();
    connect(monitor, "changed", &onAppsChanged, self);

    self.loadCss();
    self.settings_path = std.fmt.allocPrintSentinel(self.gpa, "{s}/lumen/settings.conf", .{std.mem.span(c.g_get_user_config_dir())}, 0) catch "";
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
    c.gtk_window_set_default_size(@ptrCast(win), panel_w + 36, panel_h + 36);

    const w: *c.GtkWindow = @ptrCast(win);
    c.gtk_layer_init_for_window(w);
    c.gtk_layer_set_layer(w, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    c.gtk_layer_set_keyboard_mode(w, if (testMode()) c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE else c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
    c.gtk_layer_set_namespace(w, "lumen");
    c.gtk_layer_set_anchor(w, c.GTK_LAYER_SHELL_EDGE_TOP, 1);

    const overlay = c.gtk_overlay_new();
    c.gtk_window_set_child(w, overlay);

    const panel = vbox(0);
    c.gtk_widget_add_css_class(panel, "panel");
    c.gtk_widget_set_size_request(panel, panel_w, panel_h);
    c.gtk_overlay_set_child(@ptrCast(overlay), panel);

    // search bar
    const search = hbox(0);
    c.gtk_widget_add_css_class(search, "search");
    self.back = c.gtk_image_new_from_icon_name("go-previous-symbolic");
    c.gtk_widget_add_css_class(self.back, "back");
    c.gtk_widget_set_valign(self.back, c.GTK_ALIGN_CENTER);
    // An image has no click of its own: a gesture makes it the back button.
    c.gtk_widget_set_cursor_from_name(self.back, "pointer");
    const back_click = c.gtk_gesture_click_new();
    connect(back_click, "released", &onBackClicked, self);
    c.gtk_widget_add_controller(self.back, back_click);
    c.gtk_box_append(@ptrCast(search), self.back);
    self.entry = c.gtk_text_new();
    c.gtk_widget_add_css_class(self.entry, "query");
    c.gtk_widget_set_hexpand(self.entry, 1);
    c.gtk_widget_set_valign(self.entry, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(search), self.entry);
    connect(self.entry, "changed", &onChanged, self);
    c.gtk_box_append(@ptrCast(panel), search);
    c.gtk_box_append(@ptrCast(panel), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

    // body: results + detail
    const body = hbox(0);
    c.gtk_widget_set_vexpand(body, 1);
    self.scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(self.scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_hexpand(self.scroller, 1);
    self.list = c.gtk_list_box_new();
    c.gtk_widget_add_css_class(self.list, "results");
    c.gtk_list_box_set_selection_mode(@ptrCast(self.list), c.GTK_SELECTION_SINGLE);
    c.gtk_widget_set_focusable(self.list, 0);
    connect(self.list, "row-activated", &onRowActivated, self);
    c.gtk_scrolled_window_set_child(@ptrCast(self.scroller), self.list);
    c.gtk_box_append(@ptrCast(body), self.scroller);
    self.buildDetail();
    c.gtk_box_append(@ptrCast(body), self.detail);
    c.gtk_box_append(@ptrCast(panel), body);

    // footer
    const footer = hbox(8);
    c.gtk_widget_add_css_class(footer, "footer");
    self.footer_icon = c.gtk_image_new_from_icon_name("system-search-symbolic");
    c.gtk_image_set_pixel_size(@ptrCast(self.footer_icon), 12);
    c.gtk_widget_add_css_class(self.footer_icon, "tile");
    c.gtk_widget_add_css_class(self.footer_icon, "tile-red");
    c.gtk_widget_set_valign(self.footer_icon, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(footer), self.footer_icon);
    self.footer_title = label("Lumen", null);
    c.gtk_widget_set_hexpand(self.footer_title, 1);
    c.gtk_box_append(@ptrCast(footer), self.footer_title);
    self.primary_label = label("Open", "primary");
    c.gtk_box_append(@ptrCast(footer), self.primary_label);
    self.primary_keys = label("↵", "kbd");
    c.gtk_widget_set_valign(self.primary_keys, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(footer), self.primary_keys);
    const vsep = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL);
    c.gtk_widget_set_margin_top(vsep, 12);
    c.gtk_widget_set_margin_bottom(vsep, 12);
    c.gtk_box_append(@ptrCast(footer), vsep);
    c.gtk_box_append(@ptrCast(footer), label("Actions", null));
    const k = label("⌃ K", "kbd");
    c.gtk_widget_set_valign(k, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(footer), k);
    c.gtk_box_append(@ptrCast(panel), footer);

    // action panel, floating over the bottom right corner
    self.panel = vbox(0);
    c.gtk_widget_add_css_class(self.panel, "actions");
    c.gtk_widget_set_halign(self.panel, c.GTK_ALIGN_END);
    c.gtk_widget_set_valign(self.panel, c.GTK_ALIGN_END);
    c.gtk_box_append(@ptrCast(self.panel), label("Actions", "actions-title"));
    self.panel_list = c.gtk_list_box_new();
    c.gtk_widget_set_focusable(self.panel_list, 0);
    connect(self.panel_list, "row-activated", &onPanelRowActivated, self);
    c.gtk_box_append(@ptrCast(self.panel), self.panel_list);
    c.gtk_widget_set_visible(self.panel, 0);
    c.gtk_overlay_add_overlay(@ptrCast(overlay), self.panel);

    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    connect(keys, "key-pressed", &onKey, self);
    c.gtk_widget_add_controller(win, keys);
}

fn buildDetail(self: *Ui) void {
    self.detail = vbox(0);
    c.gtk_widget_add_css_class(self.detail, "detail");
    c.gtk_widget_set_hexpand(self.detail, 1);

    // Image previews (files view).
    self.detail_picture = c.gtk_picture_new();
    c.gtk_picture_set_content_fit(@ptrCast(self.detail_picture), c.GTK_CONTENT_FIT_SCALE_DOWN);
    c.gtk_widget_set_vexpand(self.detail_picture, 1);
    c.gtk_widget_add_css_class(self.detail_picture, "preview");
    c.gtk_box_append(@ptrCast(self.detail), self.detail_picture);

    const sc = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(sc), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_vexpand(sc, 1);
    self.detail_text = label("", "detail-text");
    c.gtk_label_set_wrap(@ptrCast(self.detail_text), 1);
    c.gtk_label_set_wrap_mode(@ptrCast(self.detail_text), c.PANGO_WRAP_WORD_CHAR);
    // A wrapping label asks for its unwrapped width unless told otherwise;
    // this lets the list keep its share of the row.
    c.gtk_label_set_max_width_chars(@ptrCast(self.detail_text), 1);
    c.gtk_widget_set_hexpand(self.detail_text, 1);
    c.gtk_label_set_yalign(@ptrCast(self.detail_text), 0);
    c.gtk_widget_set_valign(self.detail_text, c.GTK_ALIGN_START);
    c.gtk_scrolled_window_set_child(@ptrCast(sc), self.detail_text);
    c.gtk_box_append(@ptrCast(self.detail), sc);

    const meta = vbox(4);
    c.gtk_widget_add_css_class(meta, "meta");
    c.gtk_box_append(@ptrCast(meta), label("Information", "meta-header"));
    const keys = [_][:0]const u8{ "Content type", "Characters", "Words", "Copied" };
    for (keys, 0..) |key, i| {
        const line = hbox(12);
        self.meta_keys[i] = label(key, "meta-key");
        c.gtk_box_append(@ptrCast(line), self.meta_keys[i]);
        const spacer = hbox(0);
        c.gtk_widget_set_hexpand(spacer, 1);
        c.gtk_box_append(@ptrCast(line), spacer);
        self.meta_values[i] = label("", "meta-value");
        c.gtk_label_set_ellipsize(@ptrCast(self.meta_values[i]), c.PANGO_ELLIPSIZE_START);
        // The layer surface grows to its content's natural width; a long path
        // here would widen the whole window.
        c.gtk_label_set_max_width_chars(@ptrCast(self.meta_values[i]), 30);
        c.gtk_box_append(@ptrCast(line), self.meta_values[i]);
        c.gtk_box_append(@ptrCast(meta), line);
    }
    c.gtk_box_append(@ptrCast(self.detail), meta);
    c.gtk_widget_set_visible(self.detail, 0);
}

fn loadCss(self: *Ui) void {
    self.css = c.gtk_css_provider_new();
    c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), @ptrCast(self.css), c.GTK_STYLE_PROVIDER_PRIORITY_USER);
}

// ------------------------------------------------------------ settings

/// Reads the settings file again and applies it.
fn reloadSettings(self: *Ui) void {
    const fresh = Settings.load(self.gpa, self.settings_path.ptr);
    self.settings.deinit();
    self.settings = fresh;
    self.settings_stamp = settings_mod.Stamp.of(self.settings_path.ptr);
    self.applyAppearance(null);
    if (self.on_settings_changed) |f| f();
}

fn saveSettings(self: *Ui) void {
    self.settings.save(self.gpa, self.settings_path) catch |err| std.log.warn("saving settings: {s}", .{@errorName(err)});
    self.settings_stamp = settings_mod.Stamp.of(self.settings_path.ptr);
    self.applyAppearance(null);
    if (self.on_settings_changed) |f| f();
}

fn currentTheme(self: *Ui) *const themes.Theme {
    return themes.find(self.settings.theme, self.preferDark());
}

/// Theme variables + style.css, reloaded only when they changed. `preview`
/// paints a theme without choosing it (moving through Change Theme).
fn applyAppearance(self: *Ui, preview: ?*const themes.Theme) void {
    const t = preview orelse self.currentTheme();
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    themes.css(&out.writer, t, &self.settings) catch return;
    out.writer.writeAll(@embedFile("style.css")) catch return;
    out.writer.writeByte(0) catch return;
    const text = out.written();
    _ = themes.hex(&self.hl_fg, t.fg);
    _ = themes.hex(&self.hl_bg, t.accent);
    const h = std.hash.Wyhash.hash(0, text);
    if (h == self.css_hash) return;
    self.css_hash = h;
    c.gtk_css_provider_load_from_string(self.css, @ptrCast(text.ptr));
}

/// The desktop's light/dark preference (dark when it cannot be read).
fn preferDark(self: *Ui) bool {
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
    connect(self.interface_settings.?, "changed::color-scheme", &onColorScheme, self);
}

fn onColorScheme(_: *c.GSettings, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    if (!std.mem.eql(u8, self.settings.theme, themes.auto_id)) return;
    self.applyAppearance(null);
    if (self.view == .settings or self.view == .themes) self.rebuild();
}

fn settingKey(a: std.mem.Allocator, name: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "set:{s}", .{name}) catch "";
}

fn setReselect(self: *Ui, comptime fmt: []const u8, args: anytype) void {
    const k = std.fmt.bufPrint(&self.reselect, fmt, args) catch "";
    self.reselect_len = k.len;
}

fn settingsCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    const st = &self.settings;
    const S = struct {
        fn row(al: std.mem.Allocator, section: [:0]const u8, name: []const u8, title: [:0]const u8, value: [:0]const u8, icon: [:0]const u8, color: item_mod.Color, action: item_mod.Setting, keywords: []const u8) Item {
            return .{ .key = settingKey(al, name), .section = section, .title = title, .accessory = value, .icon = .{ .tile = .{ .name = icon, .color = color } }, .action = .{ .setting = action }, .keywords = keywords };
        }
        fn onOff(b: bool) [:0]const u8 {
            return if (b) "On" else "Off";
        }
    };
    const choose = struct {
        fn f(ch: settings_mod.Choice) item_mod.Setting {
            return .{ .choose = ch };
        }
    }.f;
    out.append(a, S.row(a, "Appearance", "theme", "Theme", themes.displayName(a, st.theme, self.preferDark()), "applications-graphics-symbolic", .purple, .{ .go = .themes }, "color dark light appearance")) catch {};
    out.append(a, S.row(a, "Appearance", "text_size", "Text Size", self.choiceLabel(a, .text_size), "preferences-desktop-font-symbolic", .purple, choose(.text_size), "font scale zoom bigger smaller")) catch {};
    out.append(a, S.row(a, "Appearance", "opacity", "Window Opacity", self.choiceLabel(a, .opacity), "display-brightness-symbolic", .purple, choose(.opacity), "transparency translucent background")) catch {};
    out.append(a, S.row(a, "Appearance", "position", "Window Position", self.choiceLabel(a, .position), "preferences-desktop-display-symbolic", .purple, choose(.position), "center top place")) catch {};
    out.append(a, S.row(a, "Search", "files_in_root", "Show Files in Main Search", S.onOff(st.files_in_root), "folder-saved-search-symbolic", .orange, .{ .toggle = .files_in_root }, "results")) catch {};
    out.append(a, S.row(a, "Search", "suggestions", "Show Suggestions", S.onOff(st.suggestions), "starred-symbolic", .orange, .{ .toggle = .suggestions }, "frecency recent most used")) catch {};
    out.append(a, S.row(a, "Clipboard", "clipboard", "Clipboard History", S.onOff(st.clipboard), "edit-paste-symbolic", .red, .{ .toggle = .clipboard }, "copy paste record")) catch {};
    out.append(a, S.row(a, "Clipboard", "clipboard_keep", "Clipboard Entries to Keep", self.choiceLabel(a, .clipboard_keep), "document-open-recent-symbolic", .red, choose(.clipboard_keep), "history size limit")) catch {};
    out.append(a, S.row(a, "Apps", "default_apps", "Default Apps", self.defaultAppsSummary(a), "applications-system-symbolic", .blue, .{ .go = .default_apps }, "open with file types associations mime")) catch {};
    out.append(a, S.row(a, "Apps", "terminal", "Terminal", self.choiceLabel(a, .terminal), "utilities-terminal-symbolic", .blue, choose(.terminal), "console shell emulator")) catch {};
    out.append(a, S.row(a, "Apps", "editor", "Editor for Open at Line", self.choiceLabel(a, .editor), "accessories-text-editor-symbolic", .blue, choose(.editor), "code vim nvim")) catch {};
    var file_item = S.row(a, "Lumen", "open_file", "Open Settings File", "", "document-edit-symbolic", .gray, .open_file, "config edit text");
    file_item.subtitle = homeRelative(a, self.settings_path);
    out.append(a, file_item) catch {};
    var reset = S.row(a, "Lumen", "reset", "Reset All Settings", "", "edit-undo-symbolic", .gray, .reset, "defaults restore");
    reset.confirm = true;
    out.append(a, reset) catch {};
    return out.items;
}

const Option = struct { value: [:0]const u8, label: [:0]const u8 };

/// The values a choice can take, in the order they are listed.
fn choiceOptions(self: *Ui, a: std.mem.Allocator, ch: settings_mod.Choice) []const Option {
    _ = self;
    return switch (ch) {
        .text_size => &.{ .{ .value = "small", .label = "Small" }, .{ .value = "default", .label = "Default" }, .{ .value = "large", .label = "Large" } },
        .position => &.{ .{ .value = "upper_third", .label = "Upper Third" }, .{ .value = "center", .label = "Center" } },
        .opacity => &.{ .{ .value = "100", .label = "100% (Opaque)" }, .{ .value = "97", .label = "97%" }, .{ .value = "90", .label = "90%" }, .{ .value = "80", .label = "80%" } },
        .clipboard_keep => &.{ .{ .value = "100", .label = "100 entries" }, .{ .value = "500", .label = "500 entries" }, .{ .value = "1000", .label = "1,000 entries" }, .{ .value = "5000", .label = "5,000 entries" } },
        .terminal, .editor => blk: {
            var out: std.ArrayList(Option) = .empty;
            const list: []const [2][:0]const u8 = if (ch == .terminal) &settings_mod.terminals else &settings_mod.editors;
            const auto_cmd: []const u8 = if (ch == .terminal) run.autoTerminal() else run.autoEditor();
            const auto_base = std.fs.path.basename(auto_cmd);
            var auto_name: []const u8 = auto_base;
            for (list) |e| if (std.mem.eql(u8, e[0], auto_base)) {
                auto_name = e[1];
            };
            out.append(a, .{ .value = "", .label = std.fmt.allocPrintSentinel(a, "Automatic ({s})", .{auto_name}, 0) catch "Automatic" }) catch {};
            for (list) |e| if (proc.have(e[0])) out.append(a, .{ .value = e[0], .label = e[1] }) catch {};
            break :blk out.items;
        },
    };
}

/// The current value of a choice, as shown.
fn choiceLabel(self: *Ui, a: std.mem.Allocator, ch: settings_mod.Choice) [:0]const u8 {
    var buf: [32]u8 = undefined;
    const value = self.settings.choiceValue(ch, &buf);
    for (self.choiceOptions(a, ch)) |o| if (std.mem.eql(u8, o.value, value)) return o.label;
    // Set by hand to something not offered (not installed, unusual value).
    return a.dupeZ(u8, value) catch "";
}

fn chooseTitle(ch: settings_mod.Choice) []const u8 {
    return switch (ch) {
        .text_size => "Text Size",
        .opacity => "Window Opacity",
        .position => "Window Position",
        .clipboard_keep => "Clipboard Entries to Keep",
        .terminal => "Terminal",
        .editor => "Editor for Open at Line",
    };
}

fn setChoosing(self: *Ui, next: Choosing) void {
    if (self.choosing == .file) {
        self.gpa.free(self.choosing.file.path);
        self.gpa.free(self.choosing.file.mime);
    }
    self.choosing = next;
    const title: []const u8 = switch (next) {
        .none => "",
        .setting => |ch| chooseTitle(ch),
        .kind => |k| std.fmt.bufPrint(&self.choose_title, "Open {s} With", .{k.title()}) catch "",
        .file => |f| std.fmt.bufPrint(&self.choose_title, "Open {s} With", .{std.fs.path.basename(f.path)}) catch "",
    };
    const n = @min(title.len, self.choose_title.len);
    std.mem.copyForwards(u8, self.choose_title[0..n], title[0..n]);
    self.choose_title[n] = 0;
}

fn chooseCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    switch (self.choosing) {
        .none => {},
        .setting => |ch| {
            var buf: [32]u8 = undefined;
            const current = self.settings.choiceValue(ch, &buf);
            for (self.choiceOptions(a, ch)) |o| {
                out.append(a, .{
                    .key = std.fmt.allocPrint(a, "pick:{s}", .{o.value}) catch "",
                    .title = o.label,
                    .accessory = if (std.mem.eql(u8, o.value, current)) "✓" else "",
                    .icon = .{ .tile = .{ .name = "object-select-symbolic", .color = .gray } },
                    .action = .{ .setting = .{ .pick = o.value } },
                }) catch break;
            }
        },
        .kind => |k| self.appOptions(a, &out, k.sampleMime(), self.settings.open_with.get(@tagName(k)), false),
        .file => |f| self.appOptions(a, &out, f.mime, null, true),
    }
    return out.items;
}

/// Apps for `mime`: those that declare it first, then every other app (any
/// app can be told to open anything). `open_now`: rows open the file
/// instead of saving a choice.
fn appOptions(self: *Ui, a: std.mem.Allocator, out: *std.ArrayList(Item), mime: [:0]const u8, current: ?[]const u8, open_now: bool) void {
    if (!open_now) {
        const def = c.g_app_info_get_default_for_type(mime, 0);
        defer if (def) |d| c.g_object_unref(d);
        const name: [:0]const u8 = if (def) |d| (a.dupeZ(u8, std.mem.span(c.g_app_info_get_display_name(d) orelse "")) catch "") else "none set";
        out.append(a, .{
            .key = "pick:",
            .title = "System Default",
            .subtitle = name,
            .accessory = if (current == null) "✓" else "",
            .icon = .{ .tile = .{ .name = "emblem-default-symbolic", .color = .gray } },
            .action = .{ .setting = .{ .pick = "" } },
        }) catch return;
    }
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    if (c.g_app_info_get_all_for_type(mime)) |list| {
        defer c.g_list_free_full(list, &c.g_object_unref);
        var node: ?*c.GList = list;
        while (node) |n| : (node = n.next) {
            const info: *c.GAppInfo = @ptrCast(@alignCast(n.data));
            const id = a.dupe(u8, std.mem.span(c.g_app_info_get_id(info) orelse continue)) catch continue;
            declared.put(a, id, {}) catch {};
        }
    }
    for ([_]bool{ true, false }) |want_declared| {
        for (self.apps.items) |app| {
            const info = app.action.app;
            const id = std.mem.span(c.g_app_info_get_id(info) orelse continue);
            if (declared.contains(id) != want_declared) continue;
            const idz = a.dupeZ(u8, id) catch continue;
            out.append(a, .{
                .key = std.fmt.allocPrint(a, "pick:{s}", .{id}) catch "",
                .section = if (want_declared) "Recommended" else "Other Apps",
                .title = app.title,
                .subtitle = app.subtitle,
                .accessory = if (current != null and std.mem.eql(u8, current.?, id)) "✓" else "",
                .icon = app.icon,
                .keywords = app.keywords,
                .action = .{ .setting = if (open_now) .{ .open_with = idz } else .{ .pick = idz } },
            }) catch return;
        }
    }
}

fn appName(self: *Ui, a: std.mem.Allocator, id: []const u8) [:0]const u8 {
    for (self.apps.items) |app| {
        const aid = std.mem.span(c.g_app_info_get_id(app.action.app) orelse continue);
        if (std.mem.eql(u8, aid, id)) return app.title;
    }
    return a.dupeZ(u8, id) catch "";
}

fn defaultAppsSummary(self: *Ui, a: std.mem.Allocator) [:0]const u8 {
    const n = self.settings.open_with.count();
    if (n == 0) return "System Defaults";
    return std.fmt.allocPrintSentinel(a, "{d} chosen", .{n}, 0) catch "";
}

fn defaultAppsCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (std.enums.values(Kind)) |k| {
        const chosen = self.settings.open_with.get(@tagName(k));
        const accessory: [:0]const u8 = if (chosen) |id| self.appName(a, id) else blk: {
            const def = c.g_app_info_get_default_for_type(k.sampleMime(), 0) orelse break :blk "System Default";
            defer c.g_object_unref(def);
            break :blk std.fmt.allocPrintSentinel(a, "System: {s}", .{c.g_app_info_get_display_name(def) orelse ""}, 0) catch "";
        };
        out.append(a, .{
            .key = std.fmt.allocPrint(a, "kind:{t}", .{k}) catch "",
            .section = "File Kinds",
            .title = k.title(),
            .accessory = accessory,
            .icon = .{ .tile = .{ .name = k.icon(), .color = if (chosen != null) .blue else .gray } },
            .keywords = @tagName(k),
            .action = .{ .setting = .{ .kind = k } },
        }) catch break;
    }
    // Extensions set by hand in the file: shown, changed there.
    var it = self.settings.open_with.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.*[0] != '.') continue;
        out.append(a, .{
            .section = "Extensions (edit in the settings file)",
            .title = a.dupeZ(u8, e.key_ptr.*) catch continue,
            .accessory = self.appName(a, e.value_ptr.*),
            .icon = .{ .tile = .{ .name = "text-x-generic-symbolic", .color = .blue } },
            .action = .{ .setting = .open_file },
        }) catch break;
    }
    return out.items;
}

fn themeCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    const dark = self.preferDark();
    const auto_theme = themes.find(themes.auto_id, dark);
    out.append(a, .{
        .key = "theme:auto",
        .title = "Automatic",
        .subtitle = "Lumen Dark or Light, following the system",
        .accessory = if (std.mem.eql(u8, self.settings.theme, themes.auto_id)) "✓" else "",
        .icon = swatchOf(auto_theme),
        .action = .{ .setting = .{ .theme = themes.auto_id } },
    }) catch {};
    for ([_]bool{ true, false }) |want_dark| {
        for (&themes.all) |*t| {
            if (t.dark != want_dark) continue;
            out.append(a, .{
                .key = std.fmt.allocPrint(a, "theme:{s}", .{t.id}) catch "",
                .section = if (want_dark) "Dark" else "Light",
                .title = t.name,
                .accessory = if (std.mem.eql(u8, self.settings.theme, t.id)) "✓" else "",
                .icon = swatchOf(t),
                .action = .{ .setting = .{ .theme = t.id } },
            }) catch break;
        }
    }
    return out.items;
}

fn swatchOf(t: *const themes.Theme) item_mod.Icon {
    return .{ .swatch = .{ .id = t.id, .bg = t.bg, .fg = t.fg, .accent = t.accent } };
}

/// A small picture of a theme: its background, two lines of text and an
/// accent dot. Made once per theme and kept.
fn swatchTexture(id: []const u8, bg: u24, fg: u24, accent: u24) ?*c.GdkTexture {
    const Cache = struct {
        var textures: [themes.all.len + 1]?*c.GdkTexture = @splat(null);
    };
    var slot: usize = themes.all.len;
    for (themes.all, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) {
        slot = i;
        break;
    };
    if (slot < themes.all.len) if (Cache.textures[slot]) |t| return t;
    const n = 44;
    var px: [n * n * 4]u8 = undefined;
    const r: f32 = 10;
    for (0..n) |y| for (0..n) |x| {
        const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        // Rounded square: distance outside the inner rectangle.
        const dx = @max(@max(r - fx, fx - (n - r)), 0);
        const dy = @max(@max(r - fy, fy - (n - r)), 0);
        const d = @sqrt(dx * dx + dy * dy);
        const inside = std.math.clamp(r - d + 0.5, 0, 1);
        const edge = d > r - 1.5;
        var color = bg;
        if (y >= 12 and y < 16 and x >= 9 and x < 31) color = fg;
        if (y >= 20 and y < 24 and x >= 9 and x < 23) color = fg;
        const cx = fx - 30;
        const cy = fy - 31;
        if (cx * cx + cy * cy <= 36) color = accent;
        const o = (y * n + x) * 4;
        px[o] = @intCast(color >> 16);
        px[o + 1] = @intCast((color >> 8) & 0xff);
        px[o + 2] = @intCast(color & 0xff);
        // A faint outline so dark swatches show on a dark window.
        if (edge) {
            for (0..3) |k| px[o + k] = @intCast((@as(u16, px[o + k]) * 3 + 128) / 4);
        }
        px[o + 3] = @intFromFloat(inside * 255);
    };
    const bytes = c.g_bytes_new(&px, px.len);
    defer c.g_bytes_unref(bytes);
    const tex = c.gdk_memory_texture_new(n, n, c.GDK_MEMORY_R8G8B8A8, bytes, n * 4);
    if (slot < themes.all.len) Cache.textures[slot] = tex;
    return tex;
}

/// Applies what a settings row does.
fn performSetting(self: *Ui, s: item_mod.Setting, op: item_mod.Op) void {
    switch (s) {
        .toggle => |t| {
            self.settings.setToggle(t, !self.settings.get(t));
            self.saveSettings();
            self.setReselect("set:{t}", .{t});
            self.rebuild();
        },
        .choose => |ch| {
            self.setChoosing(.{ .setting = ch });
            var buf: [32]u8 = undefined;
            self.setReselect("pick:{s}", .{self.settings.choiceValue(ch, &buf)});
            self.navigate(.choose);
        },
        .kind => |k| {
            self.setChoosing(.{ .kind = k });
            self.setReselect("pick:{s}", .{self.settings.open_with.get(@tagName(k)) orelse ""});
            self.navigate(.choose);
        },
        .pick => |v| switch (self.choosing) {
            .setting => |ch| {
                _ = self.settings.setChoice(ch, v);
                self.saveSettings();
                self.goBack();
            },
            .kind => |k| {
                self.settings.setOpenWith(@tagName(k), v) catch {};
                self.saveSettings();
                self.goBack();
            },
            else => {},
        },
        .go => |v| {
            self.reselect_len = 0;
            self.navigate(v);
        },
        .theme => |id| {
            _ = self.settings.set("theme", id);
            self.saveSettings();
            self.goBack();
        },
        .open_with => |id| {
            if (self.choosing != .file) return;
            const f = self.choosing.file;
            if (op == .always_use) {
                const name = std.fs.path.basename(f.path);
                var ebuf: [16]u8 = undefined;
                const key: []const u8 = if (core.file_kind.of(f.mime, name, false)) |k| @tagName(k) else core.file_kind.extKey(&ebuf, name);
                if (key.len > 0) {
                    self.settings.setOpenWith(key, id) catch {};
                    self.saveSettings();
                }
            }
            if (!run.openWith(f.path, id)) return;
            self.hide();
        },
        .open_file => {
            // Write the defaults first: an empty editor helps nobody.
            if (index.sys.info(self.settings_path.ptr) == null) self.saveSettings();
            run.openFile(self.actionCtx(), self.settings_path, false);
            self.hide();
        },
        .reset => {
            self.settings.deinit();
            self.settings = Settings.init(self.gpa);
            self.saveSettings();
            self.setReselect("set:reset", .{});
            self.rebuild();
        },
    }
}

/// Open With for a file from the files or contents view.
fn chooseAppFor(self: *Ui, path: [:0]const u8) void {
    const guessed = c.g_content_type_guess(path, null, 0, null);
    defer if (guessed) |g| c.g_free(g);
    const mime = self.gpa.dupeZ(u8, if (guessed) |g| std.mem.span(g) else "application/octet-stream") catch return;
    const owned = self.gpa.dupeZ(u8, path) catch {
        self.gpa.free(mime);
        return;
    };
    self.setChoosing(.{ .file = .{ .path = owned, .mime = mime } });
    self.reselect_len = 0;
    self.navigate(.choose);
}

fn actionCtx(self: *Ui) run.Ctx {
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
    self.frec = self.db.loadFrecency(self.frec_arena.allocator(), now()) catch .empty;
    if (c.gtk_widget_get_visible(self.window) == 0) {
        // Edited by hand since the last look?
        if (!settings_mod.Stamp.of(self.settings_path.ptr).eql(self.settings_stamp)) self.reloadSettings();
        self.placeOnFocusedMonitor();
        // Opening is a good moment to look for edited files.
        if (self.contents) |cs| cs.poke();
    }
    self.nav_len = 0;
    // The choose view only means something reached from a setting.
    self.setView(if (view == .choose and self.choosing == .none) .settings else view);
    if (text) |t| c.gtk_editable_set_text(@ptrCast(self.entry), t);
    c.gtk_widget_set_visible(self.window, 1);
    c.gtk_window_present(@ptrCast(self.window));
    _ = c.gtk_widget_grab_focus(self.entry);
    // Focusing selects the text; put the cursor at the end instead.
    c.gtk_editable_set_position(@ptrCast(self.entry), -1);

    // Time to the first painted frame (the frame clock exists once the
    // window is realized, so it is hooked on the first show).
    if (!self.frame_clock_hooked) {
        if (c.gtk_widget_get_frame_clock(self.window)) |clock| {
            connect(clock, "after-paint", &onAfterPaint, null);
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
    // A theme previewed but not chosen.
    if (self.view == .themes) self.applyAppearance(null);
    self.closePanel();
    self.confirm_key = "";
    c.gtk_widget_set_visible(self.window, 0);
}

/// Puts the window on the monitor Hyprland has focused, a bit above centre.
fn placeOnFocusedMonitor(self: *Ui) void {
    if (testMode()) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const name = hypr.focusedMonitorName(arena.allocator()) orelse return;
    const monitors = c.gdk_display_get_monitors(c.gdk_display_get_default());
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
        const tenths: c_int = if (self.settings.position == .center) 5 else 3;
        const margin = @max(@divTrunc((geo.height - panel_h) * tenths, 10), 40);
        c.gtk_layer_set_margin(@ptrCast(self.window), c.GTK_LAYER_SHELL_EDGE_TOP, margin);
        return;
    }
}

// --------------------------------------------------------------- views

/// Opens `view`, remembering where to go back to.
fn navigate(self: *Ui, view: View) void {
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
fn goBack(self: *Ui) void {
    if (self.nav_len == 0) return self.setView(.root);
    self.nav_len -= 1;
    const e = &self.nav[self.nav_len];
    @memcpy(self.reselect[0..e.key_len], e.key[0..e.key_len]);
    self.reselect_len = e.key_len;
    self.setView(e.view);
}

/// The view's rows again, query and place kept (a setting changed).
fn rebuild(self: *Ui) void {
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
        .settings => self.settingsCandidates(a),
        .themes => self.themeCandidates(a),
        .default_apps => self.defaultAppsCandidates(a),
        .choose => self.chooseCandidates(a),
    };
}

fn setView(self: *Ui, view: View) void {
    const leaving_themes = self.view == .themes and view != .themes;
    // Change Theme starts on the theme in use.
    if (view == .themes and self.reselect_len == 0) self.setReselect("theme:{s}", .{self.settings.theme});
    self.view = view;
    if (view == .root) self.nav_len = 0;
    if (leaving_themes) self.applyAppearance(null);
    self.closePanel();
    self.confirm_key = "";
    _ = self.data_arena.reset(.retain_capacity);
    self.base = self.loadBase(self.data_arena.allocator());

    const has_detail = view == .clipboard or view == .files or view == .contents;
    c.gtk_widget_set_visible(self.back, @intFromBool(view != .root));
    c.gtk_widget_set_visible(self.detail, @intFromBool(has_detail));
    // With the detail pane, the list takes ~40%.
    c.gtk_widget_set_size_request(self.scroller, if (has_detail) 300 else -1, -1);
    c.gtk_widget_set_hexpand(self.scroller, @intFromBool(!has_detail));
    const keys: [4][:0]const u8 = switch (view) {
        .files => .{ "Kind", "Size", "Modified", "Where" },
        .contents => .{ "Kind", "Matches", "Modified", "Where" },
        else => .{ "Content type", "Characters", "Words", "Copied" },
    };
    for (self.meta_keys, keys) |w, k| c.gtk_label_set_text(@ptrCast(w), k);
    // Code previews do not wrap, they clip long lines like an editor: a
    // wrapping label makes GTK lay its text out at several widths per frame
    // (~30 ms measured with `lumen --stats`). Clipboard text is prose: wrap.
    const wrap = view == .clipboard;
    c.gtk_label_set_wrap(@ptrCast(self.detail_text), @intFromBool(wrap));
    c.gtk_label_set_ellipsize(@ptrCast(self.detail_text), if (wrap) c.PANGO_ELLIPSIZE_NONE else c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_visible(self.detail_picture, 0);
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
    });
    const tile: struct { [:0]const u8, [:0]const u8, [:0]const u8 } = switch (view) {
        .root => .{ "system-search-symbolic", "tile-red", "Lumen" },
        .clipboard => .{ "edit-paste-symbolic", "tile-red", "Clipboard History" },
        .windows => .{ "focus-windows-symbolic", "tile-blue", "Search Windows" },
        .files => .{ "folder-saved-search-symbolic", "tile-orange", "Search Files" },
        .contents => .{ "edit-find-symbolic", "tile-purple", "Search File Contents" },
        .settings, .choose => .{ "emblem-system-symbolic", "tile-gray", "Settings" },
        .themes => .{ "applications-graphics-symbolic", "tile-purple", "Change Theme" },
        .default_apps => .{ "applications-system-symbolic", "tile-blue", "Default Apps" },
    };
    c.gtk_image_set_from_icon_name(@ptrCast(self.footer_icon), tile[0]);
    inline for (.{ "tile-red", "tile-blue", "tile-orange", "tile-purple", "tile-gray" }) |cls| c.gtk_widget_remove_css_class(self.footer_icon, cls);
    c.gtk_widget_add_css_class(self.footer_icon, tile[1]);
    c.gtk_label_set_text(@ptrCast(self.footer_title), tile[2]);
    c.gtk_widget_remove_css_class(self.footer_title, "warn");

    // Setting the text triggers `changed`, which refreshes.
    if (c.gtk_editable_get_text(@ptrCast(self.entry))[0] == 0) self.refresh() else c.gtk_editable_set_text(@ptrCast(self.entry), "");
}

fn rootCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    var all: std.ArrayList(Item) = .empty;
    all.appendSlice(a, self.apps.items) catch {};
    all.appendSlice(a, &commands.all) catch {};
    all.appendSlice(a, scripts.load(a)) catch {};
    return all.items;
}

fn clipCandidates(self: *Ui, a: std.mem.Allocator) []Item {
    const clips = self.db.recentClips(a, 500) catch return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (clips) |clip| {
        out.append(a, .{
            .title = firstLine(a, clip.content),
            .icon = .{ .tile = .{ .name = "edit-copy-symbolic", .color = .gray } },
            .action = .{ .clip = clip.id },
            .detail = clip.content,
            .score = @intCast(@min(clip.last_copied, std.math.maxInt(i32))),
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
            .title = displayText(a, if (cl.title.len > 0) cl.title else cl.class),
            .subtitle = displayText(a, cl.class),
            .accessory = std.fmt.allocPrintSentinel(a, "Workspace {s}", .{cl.workspace.name}, 0) catch "",
            .icon = icon,
            .action = .{ .focus_window = a.dupeZ(u8, cl.address) catch continue },
        }) catch break;
    }
    return out.items;
}

// ------------------------------------------------------------- refresh

fn query(self: *Ui) []const u8 {
    return std.mem.span(c.gtk_editable_get_text(@ptrCast(self.entry)));
}

fn refresh(self: *Ui) void {
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
            for (self.fileItems(a, q, 60)) |it| self.addItem(it);
        },
        .contents => if (q.len >= 3) {
            if (self.content_search) |cs| {
                // Ask the worker unless the result for this exact query is
                // already here; meanwhile keep showing the last result.
                const fresh = if (self.content_result) |r| std.mem.eql(u8, r.query, q) else false;
                if (!fresh) self.content_gen = cs.submit(q, t0);
                self.content_pending = !fresh;
                if (self.content_result) |r| {
                    self.addSection("Matches");
                    for (self.itemsFromHits(a, r.hits)) |it| self.addItem(it);
                }
            } else {
                self.addSection("Matches");
                for (self.contentItems(a, q, 50)) |it| self.addItem(it);
            }
        },
        .settings, .themes, .default_apps, .choose => self.fillSectioned(a, q),
    }
    const searching = self.view == .files or self.view == .contents;
    if (self.rows.items.len == 0 or (searching and self.items.items.len == 0)) {
        if (self.rows.items.len > 0) c.gtk_list_box_remove_all(@ptrCast(self.list));
        self.rows.clearRetainingCapacity();
        const empty = self.emptyText(a);
        const row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_selectable(@ptrCast(row), 0);
        c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
        c.gtk_list_box_row_set_child(@ptrCast(row), label(empty, "empty"));
        c.gtk_list_box_append(@ptrCast(self.list), row);
    }

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
    if (hits.items.len > 0) self.addSection("Results");
    for (hits.items) |it| self.addItem(it);
}

fn fillRoot(self: *Ui, a: std.mem.Allocator, q: []const u8) void {
    if (q.len == 0) {
        // Suggestions: what was used most, then every command.
        var used: std.ArrayList(Item) = .empty;
        for (self.base) |it| {
            const v = self.frec.get(it.key) orelse continue;
            var copy = it;
            copy.score = @intFromFloat(v * 1000);
            used.append(a, copy) catch break;
        }
        sortByScore(used.items);
        if (used.items.len > 0 and self.settings.suggestions) {
            self.addSection("Suggestions");
            for (used.items[0..@min(used.items.len, 6)]) |it| self.addItem(it);
        }
        self.addSection("Commands");
        for (self.base) |it| {
            if (it.action == .view or it.action == .script) self.addItem(it);
        }
        return;
    }

    if (core.calc.evaluate(q)) |r| {
        self.addSection("Calculator");
        var buf: [64]u8 = undefined;
        const plain = a.dupe(u8, core.calc.formatPlain(&buf, r.value)) catch "";
        self.addItem(.{
            .title = a.dupeZ(u8, q) catch "",
            .subtitle = a.dupeZ(u8, r.from_unit) catch "",
            .accessory = a.dupeZ(u8, r.unit) catch "",
            .action = .calc,
            .detail = plain,
        });
    }

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
    const files = if (q.len >= 3 and self.settings.files_in_root) self.fileItems(a, q, 5) else &.{};
    const shown = @min(hits.items.len, max_results);
    const head = if (files.len > 0) @min(shown, 6) else shown;
    if (head > 0) self.addSection("Results");
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
            const today = startOfToday();
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
            self.addSection("Windows");
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
    self.addSection("Results");
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

fn addSection(self: *Ui, title: [:0]const u8) void {
    const row = c.gtk_list_box_row_new();
    c.gtk_widget_add_css_class(row, "section");
    c.gtk_list_box_row_set_selectable(@ptrCast(row), 0);
    c.gtk_list_box_row_set_activatable(@ptrCast(row), 0);
    c.gtk_list_box_row_set_child(@ptrCast(row), label(title, "section-title"));
    c.gtk_list_box_append(@ptrCast(self.list), row);
    self.rows.append(self.query_arena.allocator(), .{ .widget = row, .item = null, .section = title }) catch {};
}

fn addItem(self: *Ui, it: Item) void {
    const a = self.query_arena.allocator();
    const item_index = self.items.items.len;
    self.items.append(a, it) catch return;
    const row = if (it.action == .calc) calcRow(it) else itemRow(it);
    c.g_object_set_data(@ptrCast(row), "lumen-row", @ptrFromInt(self.rows.items.len + 1));
    c.gtk_list_box_append(@ptrCast(self.list), row);
    self.rows.append(a, .{ .widget = row, .item = item_index }) catch {};
}

fn itemRow(it: Item) *c.GtkWidget {
    const row = c.gtk_list_box_row_new();
    const box = hbox(10);
    c.gtk_box_append(@ptrCast(box), iconWidget(it.icon, 22));
    const title = label(it.title, "title");
    c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_max_width_chars(@ptrCast(title), 48);
    // Without a subtitle the title may use the whole row (clipboard list).
    if (it.subtitle.len == 0 and it.accessory.len == 0) c.gtk_widget_set_hexpand(title, 1);
    c.gtk_box_append(@ptrCast(box), title);
    if (it.subtitle.len > 0) {
        const sub = label(it.subtitle, "subtitle");
        c.gtk_label_set_ellipsize(@ptrCast(sub), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(sub), 40);
        c.gtk_box_append(@ptrCast(box), sub);
    }
    const spacer = hbox(0);
    c.gtk_widget_set_hexpand(spacer, 1);
    c.gtk_box_append(@ptrCast(box), spacer);
    if (it.accessory.len > 0) c.gtk_box_append(@ptrCast(box), label(it.accessory, "accessory"));
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    return row;
}

fn calcRow(it: Item) *c.GtkWidget {
    const row = c.gtk_list_box_row_new();
    c.gtk_widget_add_css_class(row, "calc");
    const box = hbox(0);
    c.gtk_box_set_homogeneous(@ptrCast(box), 1);

    var buf: [80:0]u8 = undefined;
    const value = std.fmt.parseFloat(f64, it.detail) catch 0;
    const shown = core.calc.formatDisplay(&buf, value);
    buf[shown.len] = 0;

    const left_tag: [:0]const u8 = if (it.subtitle.len > 0) it.subtitle else "Expression";
    const right_tag: [:0]const u8 = if (it.accessory.len > 0) it.accessory else "Answer";
    c.gtk_box_append(@ptrCast(box), calcSide(it.title, left_tag));
    const arrow = label("→", "calc-arrow");
    c.gtk_label_set_xalign(@ptrCast(arrow), 0.5);
    c.gtk_box_append(@ptrCast(box), arrow);
    c.gtk_box_append(@ptrCast(box), calcSide(buf[0..shown.len :0], right_tag));
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    return row;
}

fn calcSide(value: [:0]const u8, tag: [:0]const u8) *c.GtkWidget {
    const side = vbox(10);
    c.gtk_widget_set_valign(side, c.GTK_ALIGN_CENTER);
    const v = label(value, "calc-value");
    c.gtk_label_set_xalign(@ptrCast(v), 0.5);
    c.gtk_label_set_ellipsize(@ptrCast(v), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(side), v);
    const t = label(tag, "calc-label");
    c.gtk_widget_set_halign(t, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(side), t);
    return side;
}

fn iconWidget(icon: item_mod.Icon, size: c_int) *c.GtkWidget {
    switch (icon) {
        .logo => |l| {
            const t = logos.texture(std.heap.c_allocator, l.name) orelse return iconWidget(.none, size);
            const img = c.gtk_image_new_from_paintable(t);
            c.gtk_image_set_pixel_size(@ptrCast(img), if (l.on_light) size - 6 else size);
            c.gtk_widget_add_css_class(img, if (l.on_light) "logo-plate" else "logo");
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .gicon => |g| {
            const img = c.gtk_image_new_from_gicon(g);
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            return img;
        },
        .tile => |t| {
            const img = c.gtk_image_new_from_icon_name(t.name);
            c.gtk_image_set_pixel_size(@ptrCast(img), @divTrunc(size * 6, 10));
            c.gtk_widget_add_css_class(img, "tile");
            var cls: [24:0]u8 = undefined;
            const name = std.fmt.bufPrintZ(&cls, "tile-{t}", .{t.color}) catch "tile-gray";
            c.gtk_widget_add_css_class(img, name.ptr);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .emoji => |e| return label(e, "emoji"),
        .swatch => |sw| {
            const t = swatchTexture(sw.id, sw.bg, sw.fg, sw.accent) orelse return iconWidget(.none, size);
            const img = c.gtk_image_new_from_paintable(@ptrCast(t));
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .badge => |b| {
            const l = label(b.text, "badge");
            c.gtk_label_set_xalign(@ptrCast(l), 0.5);
            var cls: [24:0]u8 = undefined;
            const name = std.fmt.bufPrintZ(&cls, "badge-{t}", .{b.color}) catch "badge-gray";
            c.gtk_widget_add_css_class(l, name.ptr);
            // Longer extensions get a smaller font so the tile keeps its size.
            if (b.text.len >= 4) c.gtk_widget_add_css_class(l, "badge-long");
            c.gtk_widget_set_valign(l, c.GTK_ALIGN_CENTER);
            return l;
        },
        .none => {
            const img = c.gtk_image_new_from_icon_name("application-x-executable");
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            return img;
        },
    }
}

// ----------------------------------------------------------- selection

fn nextSelectable(self: *Ui, from: ?usize, dir: i32) ?usize {
    const n = self.rows.items.len;
    if (n == 0) return null;
    var i: i64 = if (from) |f| @as(i64, @intCast(f)) + dir else if (dir > 0) 0 else @as(i64, @intCast(n)) - 1;
    while (i >= 0 and i < n) : (i += dir) {
        if (self.rows.items[@intCast(i)].item != null) return @intCast(i);
    }
    return from;
}

fn select(self: *Ui, row_index: ?usize) void {
    self.selected = row_index;
    self.confirm_key = "";
    c.gtk_widget_remove_css_class(self.footer_title, "warn");
    c.gtk_label_set_text(@ptrCast(self.footer_title), self.viewTitle());
    const ri = row_index orelse {
        c.gtk_list_box_unselect_all(@ptrCast(self.list));
        c.gtk_widget_set_visible(self.primary_label, 0);
        c.gtk_widget_set_visible(self.primary_keys, 0);
        self.showDetail(null);
        return;
    };
    const row = self.rows.items[ri];
    c.gtk_list_box_select_row(@ptrCast(self.list), @ptrCast(row.widget));
    self.scrollTo(row.widget);
    const it = &self.items.items[row.item.?];
    const actions = item_mod.actionsFor(it);
    c.gtk_label_set_text(@ptrCast(self.primary_label), actions[0].label);
    c.gtk_widget_set_visible(self.primary_label, 1);
    c.gtk_widget_set_visible(self.primary_keys, 1);
    self.showDetail(it);
    // Change Theme shows each theme as the selection moves over it.
    if (self.view == .themes and it.action == .setting and it.action.setting == .theme)
        self.applyAppearance(themes.find(it.action.setting.theme, self.preferDark()));
}

fn scrollTo(self: *Ui, row: *c.GtkWidget) void {
    var b: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(row, self.list, &b) == 0) return;
    const adj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(self.scroller));
    const value = c.gtk_adjustment_get_value(adj);
    const page = c.gtk_adjustment_get_page_size(adj);
    const top: f64 = b.origin.y;
    const bottom: f64 = top + b.size.height;
    // Keep a section header above the first item visible.
    if (top < value + 4) c.gtk_adjustment_set_value(adj, @max(top - 30, 0)) else if (bottom > value + page) c.gtk_adjustment_set_value(adj, bottom - page + 6);
}

fn selectedItem(self: *Ui) ?*Item {
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
    };
}

// ------------------------------------------------------------- contents

/// Files whose text contains the query, with the matching line.
fn contentItems(self: *Ui, a: std.mem.Allocator, q: []const u8, limit: usize) []Item {
    const t0 = stats.now();
    defer self.search_ns += stats.now() - t0;
    const service = self.contents orelse return &.{};
    var hits: std.ArrayList(index.ContentService.Hit) = .empty;
    service.search(a, q, limit, &hits) catch return &.{};
    return self.itemsFromHits(a, hits.items);
}

/// A content result arrived from the worker (on the GTK main loop).
pub fn onContentResult(result: *ContentSearch.Result, ctx: ?*anyopaque) void {
    const self: *Ui = @ptrCast(@alignCast(ctx.?));
    if (result.gen != self.content_gen) {
        result.destroy(self.gpa);
        return;
    }
    const old = self.content_result;
    self.content_result = result;
    self.content_pending = false;
    if (self.view == .contents) {
        self.refresh();
        // Latency from the keystroke that asked, not from this rebuild.
        if (stats.pending) |*p| {
            p.t0 = result.t0;
            p.search = result.search_ns;
        }
    }
    if (old) |o| o.destroy(self.gpa);
}

fn itemsFromHits(self: *Ui, a: std.mem.Allocator, hits: []const index.ContentService.Hit) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (hits) |h| {
        const path = a.dupeZ(u8, h.path) catch continue;
        const slash = std.mem.lastIndexOfScalar(u8, h.path, '/') orelse 0;
        out.append(a, .{
            .title = displayText(a, h.path[slash + 1 ..]),
            // The list is narrow beside the preview: the folder goes to the
            // detail pane, the name keeps the room.
            .accessory = std.fmt.allocPrintSentinel(a, "line {d}", .{h.line}, 0) catch "",
            .where = homeRelative(a, h.path[0..slash]),
            .fact = (if (h.count > 1)
                std.fmt.allocPrintSentinel(a, "line {d} · {d}{s} matches", .{ h.line, h.count, if (h.count >= index.content.count_cap) "+" else "" }, 0)
            else
                std.fmt.allocPrintSentinel(a, "line {d}", .{h.line}, 0)) catch "",
            .icon = self.fileIcon(path, false),
            .action = .{ .file = .{ .path = path, .is_dir = false, .line = h.line, .extracted = h.extracted } },
            .detail = h.snippet,
            .score = @intCast(@min(h.mtime, std.math.maxInt(i32))),
        }) catch break;
    }
    return out.items;
}

fn contentsHint(self: *Ui, a: std.mem.Allocator, typed: usize) [:0]const u8 {
    const service = self.contents orelse return "Content index unavailable";
    const st = service.status();
    if (!st.ready) return "Indexing the text of your files...";
    if (typed > 0) return "Type at least 3 characters";
    var buf: [32]u8 = undefined;
    const n = core.calc.formatDisplay(&buf, @floatFromInt(st.docs));
    return std.fmt.allocPrintSentinel(a, "Search inside {s} files", .{n}, 0) catch "";
}

fn homeRelative(a: std.mem.Allocator, dir: []const u8) [:0]const u8 {
    const home = std.mem.span(c.g_get_home_dir());
    const shown = (if (std.mem.startsWith(u8, dir, home))
        std.fmt.allocPrint(a, "~{s}", .{dir[home.len..]})
    else
        a.dupe(u8, dir)) catch return "";
    return displayText(a, shown);
}

/// Text fit for a label. Linux file names are bytes: they can hold invalid
/// UTF-8 (Pango then warns and draws garbage, and `--dump` failed outright)
/// or a newline (a two-line row). Invalid sequences become U+FFFD and
/// control characters a space. Only for display: actions keep the raw path.
fn displayText(a: std.mem.Allocator, raw: []const u8) [:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(a, raw.len + 1) catch return "";
    var i: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch 0;
        if (n == 0 or i + n > raw.len or !std.unicode.utf8ValidateSlice(raw[i .. i + n])) {
            out.appendSlice(a, "\u{FFFD}") catch return "";
            i += 1;
            continue;
        }
        if (n == 1 and (raw[i] < 0x20 or raw[i] == 0x7f)) {
            out.append(a, ' ') catch return "";
        } else out.appendSlice(a, raw[i .. i + n]) catch return "";
        i += n;
    }
    return out.toOwnedSliceSentinel(a, 0) catch "";
}

/// The lines around the match, words highlighted.
fn showContentDetail(self: *Ui, it: *const Item) void {
    const f = it.action.file;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    c.gtk_widget_set_visible(self.detail_picture, 0);

    const info = index.sys.info(f.path);
    const service = self.contents orelse return;
    const text = service.readText(a, f.path, if (info) |i| i.mtime else 0, f.extracted) orelse it.detail;
    const words = index.content.splitWords(a, self.query()) catch return;
    // The theme's accent behind matches, its text colour on top.
    const hl_open = std.fmt.allocPrint(a, "<span background=\"{s}\" bgalpha=\"40%\" foreground=\"{s}\">", .{ std.mem.sliceTo(&self.hl_bg, 0), std.mem.sliceTo(&self.hl_fg, 0) }) catch return;
    c.gtk_label_set_markup(@ptrCast(self.detail_text), contextMarkup(a, text, f.line, words, hl_open).ptr);

    const ctype = c.g_content_type_guess(f.path, null, 0, null);
    defer if (ctype) |t| c.g_free(t);
    c.gtk_label_set_text(@ptrCast(self.meta_values[0]), kindLabel(a, f.path, false, ctype).ptr);
    c.gtk_label_set_text(@ptrCast(self.meta_values[1]), it.fact.ptr);
    c.gtk_label_set_text(@ptrCast(self.meta_values[2]), if (info) |i| formatWhen(a, i.mtime).ptr else "—");
    c.gtk_label_set_text(@ptrCast(self.meta_values[3]), it.where.ptr);
}

/// Pango markup of the lines around `line` (1-based), with line numbers and
/// every occurrence of `words` highlighted.
fn contextMarkup(a: std.mem.Allocator, text: []const u8, line: u32, words: []const []const u8, hl_open: []const u8) [:0]const u8 {
    const before = 6;
    const after = 14;
    const first = if (line > before) line - before else 1;
    var out: std.ArrayList(u8) = .empty;
    var n: u32 = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| : (n += 1) {
        if (n < first) continue;
        if (n > line + after) break;
        const l = validUtf8Prefix(raw[0..@min(raw.len, 240)]);
        const num = std.fmt.allocPrint(a, "<span alpha=\"45%\">{d: >4}  </span>", .{n}) catch return "";
        out.appendSlice(a, num) catch return "";
        if (n == line) out.appendSlice(a, "<b>") catch return "";
        // Escape piece by piece, wrapping each hit.
        var pos: usize = 0;
        while (pos < l.len) {
            // Folded matches: "accion" highlights "ACCIÓN", whose length differs.
            var hit: ?index.content.Span = null;
            for (words) |w| {
                if (index.content.findFold(l, w, pos)) |m| {
                    if (hit == null or m.start < hit.?.start) hit = m;
                }
            }
            const end = if (hit) |m| m.start else l.len;
            appendEscaped(a, &out, l[pos..end]);
            if (hit) |m| {
                out.appendSlice(a, hl_open) catch return "";
                appendEscaped(a, &out, l[m.start..m.end]);
                out.appendSlice(a, "</span>") catch return "";
                pos = m.end;
            } else pos = l.len;
        }
        if (n == line) out.appendSlice(a, "</b>") catch return "";
        out.append(a, '\n') catch return "";
    }
    return a.dupeZ(u8, out.items) catch "";
}

fn appendEscaped(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    if (s.len == 0) return;
    const e = c.g_markup_escape_text(s.ptr, @intCast(s.len));
    defer c.g_free(e);
    out.appendSlice(a, std.mem.span(e)) catch {};
}

// ---------------------------------------------------------------- files

/// Files matching `q`, from the index, as rows.
fn fileItems(self: *Ui, a: std.mem.Allocator, q: []const u8, limit: usize) []Item {
    const t0 = stats.now();
    defer self.search_ns += stats.now() - t0;
    const service = self.files orelse return &.{};
    var hits: std.ArrayList(index.Live.Hit) = .empty;
    service.search(a, q, limit, &hits) catch return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (hits.items) |h| {
        const path = a.dupeZ(u8, h.path) catch continue;
        const slash = std.mem.lastIndexOfScalar(u8, h.path, '/') orelse 0;
        const where = homeRelative(a, h.path[0..slash]);
        out.append(a, .{
            .key = std.fmt.allocPrint(a, "file:{s}", .{h.path}) catch "",
            .title = displayText(a, h.path[slash + 1 ..]),
            .subtitle = where,
            .icon = self.fileIcon(path, h.is_dir),
            .action = .{ .file = .{ .path = path, .is_dir = h.is_dir } },
            .score = h.score,
        }) catch break;
    }
    return out.items;
}

/// Icon for a file's type, guessed from its name (no I/O): the extension
/// badge for code and text, the theme's icon for the rest.
fn fileIcon(self: *Ui, path: [:0]const u8, is_dir: bool) item_mod.Icon {
    if (!is_dir) {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const name = if (slash) |s| path[s + 1 ..] else path;
        if (core.file_badge.logoOf(name)) |l| return .{ .logo = l };
        var upper: [4]u8 = undefined;
        if (core.file_badge.of(name, &upper)) |b| {
            const text = self.query_arena.allocator().dupeZ(u8, b.text) catch return .none;
            return .{ .badge = .{ .text = text, .color = b.color } };
        }
    }
    const ctype = if (is_dir) null else c.g_content_type_guess(path, null, 0, null);
    defer if (ctype) |t| c.g_free(t);
    const icon = c.g_content_type_get_icon(if (ctype) |t| t else "inode/directory");
    self.icons.append(self.gpa, icon) catch {
        c.g_object_unref(icon);
        return .none;
    };
    return .{ .gicon = icon };
}

fn filesHint(self: *Ui, a: std.mem.Allocator) [:0]const u8 {
    const service = self.files orelse return "File index unavailable";
    const st = service.status();
    if (st.entries == 0) return "Indexing your files...";
    var buf: [32]u8 = undefined;
    const n = core.calc.formatDisplay(&buf, @floatFromInt(st.entries));
    return std.fmt.allocPrintSentinel(a, "Type to search {s} files", .{n}, 0) catch "";
}

fn showFileDetail(self: *Ui, it: *const Item) void {
    const f = it.action.file;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const ctype = if (f.is_dir) null else c.g_content_type_guess(f.path, null, 0, null);
    defer if (ctype) |t| c.g_free(t);
    const ct: [*:0]const u8 = if (ctype) |t| t else "inode/directory";

    // Only regular files: GTK reads the picture synchronously, and a FIFO
    // named *.png would block the UI.
    const image = (c.g_content_type_is_a(ct, "image/*") != 0 or std.mem.startsWith(u8, std.mem.span(ct), "image/")) and index.sys.isRegular(f.path);
    const info = index.sys.info(f.path);
    c.gtk_widget_set_visible(self.detail_picture, @intFromBool(image));
    c.gtk_picture_set_filename(@ptrCast(self.detail_picture), if (image) f.path.ptr else null);

    // Text preview: the head of anything that is valid UTF-8.
    var text: []const u8 = "";
    if (!image and !f.is_dir) {
        const head = index.sys.readHead(f.path, a.alloc(u8, 4096) catch return);
        const valid = validUtf8Prefix(head);
        if (valid.len + 4 >= head.len and std.mem.indexOfScalar(u8, valid, 0) == null) text = firstLines(valid, preview_lines);
    }
    c.gtk_label_set_text(@ptrCast(self.detail_text), (a.dupeZ(u8, text) catch return).ptr);

    c.gtk_label_set_text(@ptrCast(self.meta_values[0]), kindLabel(a, f.path, f.is_dir, ct).ptr);
    if (info) |inf| {
        c.gtk_label_set_text(@ptrCast(self.meta_values[1]), if (f.is_dir) "—" else formatSize(a, inf.size).ptr);
        c.gtk_label_set_text(@ptrCast(self.meta_values[2]), formatWhen(a, inf.mtime).ptr);
    } else {
        c.gtk_label_set_text(@ptrCast(self.meta_values[1]), "—");
        c.gtk_label_set_text(@ptrCast(self.meta_values[2]), "—");
    }
    c.gtk_label_set_text(@ptrCast(self.meta_values[3]), it.subtitle.ptr);
}

/// "Kind" in the detail pane. GLib guesses from the extension and is wrong
/// for some source files: .zig is "unknown", .mts is a video ("MPEG-2
/// transport stream"). A file with a code badge is named after it then.
fn kindLabel(a: std.mem.Allocator, path: []const u8, is_dir: bool, ctype: ?[*:0]const u8) [:0]const u8 {
    if (is_dir) return "Folder";
    const desc = if (ctype) |t| c.g_content_type_get_description(t) else null;
    defer if (desc) |d| c.g_free(d);
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    var upper: [4]u8 = undefined;
    if (core.file_badge.of(name, &upper)) |b| {
        const t = if (ctype) |t| std.mem.span(t) else "";
        // octet-stream is GLib's "no idea" (e.g. no shared-mime-info data).
        const media = std.mem.startsWith(u8, t, "video/") or std.mem.startsWith(u8, t, "audio/") or std.mem.eql(u8, t, "application/octet-stream");
        const unknown = desc == null or std.ascii.eqlIgnoreCase(std.mem.span(desc.?), "unknown");
        if (media or unknown) return std.fmt.allocPrintSentinel(a, "{s} file", .{b.text}, 0) catch "File";
    }
    return if (desc) |d| a.dupeZ(u8, std.mem.span(d)) catch "File" else "File";
}

/// Lines of a file preview. The pane shows ~14; GTK wraps and measures all
/// of the label's text at several widths, and 4 KB (~100 lines) of it cost
/// ~50 ms per frame (measured with `lumen --stats`).
const preview_lines = 40;

fn firstLines(text: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch != '\n') continue;
        count += 1;
        if (count == n) return text[0..i];
    }
    return text;
}

fn formatSize(a: std.mem.Allocator, bytes: u64) [:0]const u8 {
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    return (if (u == 0)
        std.fmt.allocPrintSentinel(a, "{d} bytes", .{bytes}, 0)
    else
        std.fmt.allocPrintSentinel(a, "{d:.1} {s}", .{ v, units[u] }, 0)) catch "";
}

fn showDetail(self: *Ui, it: ?*const Item) void {
    if (self.view == .files or self.view == .contents) {
        if (it) |i| if (i.action == .file) {
            return if (self.view == .contents) self.showContentDetail(i) else self.showFileDetail(i);
        };
        c.gtk_widget_set_visible(self.detail_picture, 0);
        c.gtk_label_set_text(@ptrCast(self.detail_text), "");
        for (self.meta_values) |v| c.gtk_label_set_text(@ptrCast(v), "");
        return;
    }
    if (self.view != .clipboard) return;
    const i = it orelse {
        c.gtk_label_set_text(@ptrCast(self.detail_text), "");
        for (self.meta_values) |v| c.gtk_label_set_text(@ptrCast(v), "");
        return;
    };
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = i.detail[0..@min(i.detail.len, 20_000)];
    c.gtk_label_set_text(@ptrCast(self.detail_text), (a.dupeZ(u8, validUtf8Prefix(text)) catch return).ptr);
    c.gtk_label_set_text(@ptrCast(self.meta_values[0]), "Text");
    const chars = std.unicode.utf8CountCodepoints(i.detail) catch i.detail.len;
    var words: usize = 0;
    var tok = std.mem.tokenizeAny(u8, i.detail, " \t\r\n");
    while (tok.next()) |_| words += 1;
    c.gtk_label_set_text(@ptrCast(self.meta_values[1]), (std.fmt.allocPrintSentinel(a, "{d}", .{chars}, 0) catch return).ptr);
    c.gtk_label_set_text(@ptrCast(self.meta_values[2]), (std.fmt.allocPrintSentinel(a, "{d}", .{words}, 0) catch return).ptr);
    c.gtk_label_set_text(@ptrCast(self.meta_values[3]), formatWhen(a, i.score).ptr);
}

// --------------------------------------------------------- action panel

fn openPanel(self: *Ui) void {
    const it = self.selectedItem() orelse return;
    self.panel_entries = item_mod.actionsFor(it);
    c.gtk_list_box_remove_all(@ptrCast(self.panel_list));
    for (self.panel_entries) |e| {
        const row = c.gtk_list_box_row_new();
        const box = hbox(8);
        const l = label(e.label, null);
        c.gtk_widget_set_hexpand(l, 1);
        c.gtk_box_append(@ptrCast(box), l);
        if (e.keys.len > 0) {
            const k = label(e.keys, "kbd");
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

fn closePanel(self: *Ui) void {
    self.panel_open = false;
    c.gtk_widget_set_visible(self.panel, 0);
}

fn selectPanel(self: *Ui, i: usize) void {
    self.panel_selected = i;
    const row = c.gtk_list_box_get_row_at_index(@ptrCast(self.panel_list), @intCast(i));
    c.gtk_list_box_select_row(@ptrCast(self.panel_list), row);
}

// ------------------------------------------------------------- actions

fn perform(self: *Ui, op: item_mod.Op) void {
    const it = self.selectedItem() orelse return;
    // Destructive commands need a second Enter.
    if (it.confirm and (op == .run or op == .open) and !std.mem.eql(u8, self.confirm_key, it.key)) {
        self.confirm_key = it.key;
        c.gtk_label_set_text(@ptrCast(self.footer_title), (std.fmt.allocPrintSentinel(self.query_arena.allocator(), "Press ↵ again to {s}", .{it.title}, 0) catch return).ptr);
        c.gtk_widget_add_css_class(self.footer_title, "warn");
        return;
    }
    self.closePanel();
    if (it.key.len > 0 and it.action != .setting and (op == .run or op == .open)) self.db.recordUse(it.key, now());

    const outcome = run.perform(self.actionCtx(), it, op);
    switch (outcome) {
        .hide => self.hide(),
        .stay => {},
        .refresh_view => self.setView(self.view),
        .open_view => |v| self.navigate(v),
        .setting => |sa| self.performSetting(sa.setting, sa.op),
        .choose_app => |path| self.chooseAppFor(path),
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
    self.perform(item_mod.actionsFor(it)[0].op);
}

fn onPanelRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const i: usize = @intCast(c.gtk_list_box_row_get_index(row));
    if (i < self.panel_entries.len) self.perform(self.panel_entries[i].op);
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
    return self.handleKey(keyval, state);
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
        .{ "ctrl+o", c.GDK_KEY_o, c.GDK_CONTROL_MASK },
    };
    for (keys) |k| if (std.mem.eql(u8, k[0], name)) {
        _ = self.handleKey(k[1], k[2]);
        return true;
    };
    return false;
}

/// `lumen --dump`: what the window shows, as text (for end-to-end tests).
pub fn dump(self: *Ui, a: std.mem.Allocator) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("view: {t}\nvisible: {}\nquery: {s}\n", .{ self.view, c.gtk_widget_get_visible(self.window) != 0, self.query() });
    try w.print("footer: {s}\nprimary: {s}\n", .{ c.gtk_label_get_text(@ptrCast(self.footer_title)), if (self.selected != null) c.gtk_label_get_text(@ptrCast(self.primary_label)) else "" });
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
            .logo => |l| try w.print("logo:{s}\n", .{l.name}),
            .badge => |b| try w.print("badge:{s}\n", .{b.text}),
            .tile => |t| try w.print("tile:{s}\n", .{t.name}),
            .gicon => try w.print("gicon\n", .{}),
            .emoji => |e| try w.print("emoji:{s}\n", .{e}),
            .swatch => |sw| try w.print("swatch:{s}\n", .{sw.id}),
            .none => try w.print("none\n", .{}),
        }
    }
    if (c.gtk_widget_get_visible(self.detail) != 0) {
        try w.print("detail:\n", .{});
        for (self.meta_keys, self.meta_values) |k, v| try w.print("  {s} = {s}\n", .{ c.gtk_label_get_text(@ptrCast(k)), c.gtk_label_get_text(@ptrCast(v)) });
    }
    if (self.panel_open) {
        try w.print("panel:\n", .{});
        for (self.panel_entries, 0..) |e, i| try w.print("  {s} {s} [{s}]\n", .{ if (i == self.panel_selected) ">" else " ", e.label, e.keys });
    }
    try w.writeByte(0);
    const bytes = out.written();
    return bytes[0 .. bytes.len - 1 :0];
}

/// The placeholder row's text when nothing is listed.
fn emptyText(self: *Ui, a: std.mem.Allocator) [:0]const u8 {
    const q = std.mem.trim(u8, self.query(), " ");
    if (self.view == .files and q.len == 0) return self.filesHint(a);
    if (self.view == .contents and q.len < 3) return self.contentsHint(a, q.len);
    if (self.view == .contents and self.content_pending) return "Searching...";
    if (self.view == .clipboard and q.len == 0 and !self.settings.clipboard) return "Clipboard history is off: turn it on in Settings";
    return "No Results";
}

fn handleKey(self: *Ui, keyval: c_uint, state: c.GdkModifierType) c.gboolean {
    const ctrl = state & c.GDK_CONTROL_MASK != 0;
    const shift = state & c.GDK_SHIFT_MASK != 0;
    const down = keyval == c.GDK_KEY_Down or (ctrl and (keyval == c.GDK_KEY_n or keyval == c.GDK_KEY_j));
    const up = keyval == c.GDK_KEY_Up or (ctrl and (keyval == c.GDK_KEY_p or keyval == c.GDK_KEY_k and self.panel_open));
    const enter = keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter;

    if (self.panel_open) {
        if (keyval == c.GDK_KEY_Escape or (ctrl and keyval == c.GDK_KEY_k and !up)) {
            self.closePanel();
        } else if (down) {
            self.selectPanel(@min(self.panel_selected + 1, self.panel_entries.len - 1));
        } else if (up) {
            self.selectPanel(self.panel_selected -| 1);
        } else if (enter) {
            self.perform(self.panel_entries[self.panel_selected].op);
        }
        return 1;
    }

    if (keyval == c.GDK_KEY_Escape) {
        if (self.query().len > 0) {
            c.gtk_editable_set_text(@ptrCast(self.entry), "");
        } else if (self.view != .root) self.goBack() else self.hide();
        return 1;
    }
    if (down) {
        self.select(self.nextSelectable(self.selected, 1));
        return 1;
    }
    if (up) {
        self.select(self.nextSelectable(self.selected, -1));
        return 1;
    }
    if (keyval == c.GDK_KEY_Page_Down or keyval == c.GDK_KEY_Page_Up) {
        const dir: i32 = if (keyval == c.GDK_KEY_Page_Down) 1 else -1;
        var target = self.selected;
        for (0..8) |_| target = self.nextSelectable(target, dir);
        self.select(target);
        return 1;
    }
    if (ctrl and keyval == c.GDK_KEY_k) {
        self.openPanel();
        return 1;
    }
    if (enter) {
        const it = self.selectedItem() orelse return 1;
        const actions = item_mod.actionsFor(it);
        if (ctrl and actions.len > 1) self.perform(actions[1].op) else self.perform(actions[0].op);
        return 1;
    }
    if (ctrl and (keyval == c.GDK_KEY_x or keyval == c.GDK_KEY_X)) {
        const it = self.selectedItem() orelse return 1;
        if (it.action == .clip) self.perform(if (shift) .clip_clear else .clip_delete);
        if (it.action == .file) self.perform(.trash);
        return 1;
    }
    if (ctrl and shift and (keyval == c.GDK_KEY_c or keyval == c.GDK_KEY_C)) {
        const it = self.selectedItem() orelse return 1;
        if (it.action == .app or it.action == .file) self.perform(.copy_path);
        return 1;
    }
    if (ctrl and shift and (keyval == c.GDK_KEY_f or keyval == c.GDK_KEY_F)) {
        const it = self.selectedItem() orelse return 1;
        if (it.action == .file) self.perform(.copy_file);
        return 1;
    }
    if (keyval == c.GDK_KEY_BackSpace and self.query().len == 0 and self.view != .root) {
        self.goBack();
        return 1;
    }
    if (ctrl and (keyval == c.GDK_KEY_o or keyval == c.GDK_KEY_O)) {
        const it = self.selectedItem() orelse return 1;
        if (it.action == .file) self.perform(.open_with);
        return 1;
    }
    return 0;
}

// -------------------------------------------------------------- helpers

pub fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = c.g_signal_connect_data(@ptrCast(instance), signal, @ptrCast(handler), data, null, 0);
}

fn hbox(spacing: c_int) *c.GtkWidget {
    return c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, spacing);
}

fn vbox(spacing: c_int) *c.GtkWidget {
    return c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, spacing);
}

fn label(text: [*:0]const u8, css: ?[*:0]const u8) *c.GtkWidget {
    const l = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(l), 0);
    if (css) |cls| c.gtk_widget_add_css_class(l, cls);
    return l;
}

fn now() i64 {
    return @divTrunc(c.g_get_real_time(), std.time.us_per_s);
}

fn startOfToday() i64 {
    const dt = c.g_date_time_new_now_local();
    defer c.g_date_time_unref(dt);
    const midnight = c.g_date_time_new_local(c.g_date_time_get_year(dt), c.g_date_time_get_month(dt), c.g_date_time_get_day_of_month(dt), 0, 0, 0);
    defer c.g_date_time_unref(midnight);
    return c.g_date_time_to_unix(midnight);
}

fn formatWhen(a: std.mem.Allocator, unix: i64) [:0]const u8 {
    const dt = c.g_date_time_new_from_unix_local(unix) orelse return "";
    defer c.g_date_time_unref(dt);
    const today = startOfToday();
    const fmt: [*:0]const u8 = if (unix >= today) "Today at %H:%M" else if (unix >= today - 86400) "Yesterday at %H:%M" else "%b %e at %H:%M";
    const s = c.g_date_time_format(dt, fmt) orelse return "";
    defer c.g_free(s);
    return a.dupeZ(u8, std.mem.span(s)) catch "";
}

/// First non-blank line, collapsed and capped, for a clipboard row title.
fn firstLine(a: std.mem.Allocator, text: []const u8) [:0]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len == 0) continue;
        return a.dupeZ(u8, validUtf8Prefix(t[0..@min(t.len, 120)])) catch "";
    }
    return "";
}

/// Longest prefix of `s` that is valid UTF-8 (cuts never split a character).
fn validUtf8Prefix(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(s[0..end])) end -= 1;
    return s[0..end];
}

test "displayText makes any file name safe for a label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("bad-\u{FFFD}\u{FFFD}-name.txt", displayText(a, "bad-\xff\xfe-name.txt"));
    try std.testing.expectEqualStrings("line1 line2.txt", displayText(a, "line1\nline2.txt"));
    try std.testing.expectEqualStrings("acción ñandú 🔊", displayText(a, "acción ñandú 🔊"));
    try std.testing.expectEqualStrings("trunc\u{FFFD}", displayText(a, "trunc\xc3"));
}
