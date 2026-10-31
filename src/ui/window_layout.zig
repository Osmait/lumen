//! The window's widgets: making them (`build`), arranging them as
//! lumen.layout says (`applyStructure`), sizing them from the settings
//! (`applyLayout`), fitting them to a view (`layoutFor`) and placing the
//! surface on the focused monitor.
//!
//! The widgets themselves live in Ui's fields; this file owns the
//! arithmetic between them: the pieces' size, the list's height limit, the
//! grid's cells, and the sizes in style.css that arithmetic depends on.
//! Main thread only (GTK).

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const hypr = @import("../sys/hypr.zig");
const layout_mod = @import("../layout.zig");
const backdrop = @import("backdrop.zig");
const detail_pane = @import("detail_pane.zig");
const ext_view = @import("ext_view.zig");
const keyboard = @import("keyboard.zig");
const row_list = @import("row_list.zig");
const themes = @import("themes.zig");
const widgets = @import("widgets.zig");
const Ui = @import("Ui.zig");
const View = Ui.View;

/// Sizes style.css sets that the window's arithmetic depends on. The test
/// "style.css has the sizes the window computes with" reads the stylesheet and
/// fails when one side changes without the other.
pub const style_css = struct {
    /// `.search { min-height }`.
    pub const search_height_px = 56;
    /// `.results-island { padding; border }`, on each side.
    pub const results_padding_px = 6;
    pub const results_border_px = 1;
    /// `.shell { margin }`: clear space around the pieces for their shadows.
    pub const shell_margin_px = 48;
    /// `.grid > flowboxchild { padding }`, on the left and on the right.
    pub const grid_cell_padding_px = 6;
    /// The undershoot fade at the list's edges (`background-size`).
    pub const results_fade_px = 20;
};

/// Between the pieces of a split layout: the column's spacing.
const pieces_gap_px = 10;

/// The footer bar's height (lumen.layout's footer).
const footer_height_px = 40;

/// Between the grid's cells, across and down.
const grid_spacing_px = 6;

/// What the grid loses to the island's and its own padding, both sides.
const grid_frame_px = 24;

/// The keys that open the action panel and run the selection, as the
/// search bar's chip, the footer and the rows show them.
const actions_keys_text = "Ctrl K";
pub const enter_key_text = "↵";

/// The footer's two labels: what Enter does, and "Actions".
const footer_action_class = "footer-action";

/// Where Center and Upper Third put the pieces: the room above them, in
/// tenths of the room the monitor leaves above and below.
const position_center_tenths = 5;
const position_upper_third_tenths = 3;

comptime {
    assert(position_upper_third_tenths < position_center_tenths);
    assert(position_center_tenths <= 10); // Tenths: 10 is the whole room.
}

/// The back arrow, magnifier, prompt, scope chip, text field and Ctrl K chip.
pub const SearchBar = struct {
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
pub const Footer = struct {
    box: *c.GtkBox,
    title: *c.GtkLabel,
    action: *c.GtkLabel,
    enter: *c.GtkLabel,
    separator: *c.GtkLabel,

    /// What Enter does on the selected row, or a warning waiting for Enter.
    pub fn setAction(footer: *const Footer, text: [:0]const u8, tone: HintTone) void {
        const warn = tone == .warning;
        c.gtk_label_set_text(footer.action, text.ptr);
        gtk.setClass(footer.action, widgets.css_class.warn, warn);
        const any = text.len > 0;
        gtk.setVisible(footer.action, any);
        gtk.setVisible(footer.enter, any and !warn);
        gtk.setVisible(footer.separator, any);
    }
};

/// A hint says what Enter does, or warns that Enter is waiting for a
/// second press (a destructive action) or that something failed.
pub const HintTone = enum { action, warning };

/// The pieces' width in px: lumen.layout's, else the Width setting's.
pub fn panelWidth(ui: *const Ui) c_int {
    if (ui.layout.width) |width_px| return width_px;
    return switch (ui.settings.width) {
        .narrow => 620,
        .default => 750,
        .wide => 920,
    };
}

/// The pieces' height in px: lumen.layout's, else the Height setting's.
pub fn panelHeight(ui: *const Ui) c_int {
    if (ui.layout.height) |height_px| return height_px;
    return switch (ui.settings.height) {
        .short => 380,
        .default => 474,
        .tall => 640,
    };
}

/// The list's height limit: what is left beside the search bar, the
/// results' padding and border, the footer and the gaps between pieces
/// (none in a single panel).
fn listHeightMax(ui: *const Ui) c_int {
    const gap_px: c_int = if (ui.layout.panels == .split) pieces_gap_px else 0;
    const footer_px: c_int = if (ui.layout.footer) footer_height_px + gap_px else 0;
    const results_frame_px = 2 * (style_css.results_padding_px + style_css.results_border_px);
    return panelHeight(ui) - style_css.search_height_px - results_frame_px - gap_px - footer_px;
}

/// A grid cell's content width for `ui.grid_columns` cells across the
/// pieces' width: at least a pixel, since lumen.layout's width and a
/// command's columns can leave no room, and a cell of no width would ask
/// for pictures of no size.
pub fn gridCellWidth(ui: *const Ui) c_int {
    const gaps_px = grid_spacing_px * (ui.grid_columns - 1) + grid_frame_px;
    const cell_px = @divTrunc(panelWidth(ui) - gaps_px, ui.grid_columns);
    return @max(cell_px - 2 * style_css.grid_cell_padding_px, 1);
}

/// Makes the window and every widget in it, hidden. The settings are read
/// already: the pieces take their size from them.
pub fn build(ui: *Ui) void {
    const overlay = buildWindow(ui);
    // Two pieces on a transparent surface: the search bar and, below it, the
    // results, as tall as their rows (the rest of the surface stays clear).
    const column = widgets.vbox(10);
    ui.column = column;
    gtk.addClass(column, "shell");
    gtk.setSizeRequest(column, panelWidth(ui), panelHeight(ui));
    c.gtk_overlay_set_child(overlay, gtk.widget(column));

    buildSearchBar(ui, column);
    buildResults(ui, column);
    buildFooter(ui, column);
    ui.panel.build(ui, overlay);
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    widgets.connect(keys, "key-pressed", &onKey, ui);
    c.gtk_widget_add_controller(gtk.widget(ui.window), keys);

    // A click on the clear part of the surface hides the window, like one on
    // the backdrop. Capture phase: it sees every press, and claims none.
    const click = c.gtk_gesture_click_new();
    c.gtk_event_controller_set_propagation_phase(click, c.GTK_PHASE_CAPTURE);
    widgets.connect(click, "pressed", &backdrop.onWindowPressed, ui);
    c.gtk_widget_add_controller(gtk.widget(ui.window), click);
}

/// The layer-shell window and the overlay everything goes in.
fn buildWindow(ui: *Ui) *c.GtkOverlay {
    const window = gtk.window(ui.app);
    ui.window = window;
    gtk.addClass(window, "lumen");
    c.gtk_window_set_title(window, "Lumen");
    c.gtk_window_set_resizable(window, 0);
    c.gtk_window_set_decorated(window, 0);
    // A fixed size: the layer surface would otherwise grow to its content's
    // natural size (a large image preview, a long path).
    c.gtk_window_set_default_size(
        window,
        panelWidth(ui) + 2 * style_css.shell_margin_px,
        panelHeight(ui) + 2 * style_css.shell_margin_px,
    );

    c.gtk_layer_init_for_window(window);
    c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    const keyboard_mode = if (Ui.testMode())
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
fn buildSearchBar(ui: *Ui, column: *c.GtkBox) void {
    const search = widgets.hbox(0);
    gtk.addClass(search, "search");
    ui.search_bar.box = search;
    ui.search_bar.back = c.gtk_image_new_from_icon_name("go-previous-symbolic");
    gtk.addClass(ui.search_bar.back, "back");
    gtk.setValign(ui.search_bar.back, c.GTK_ALIGN_CENTER);
    // An image has no click of its own: a gesture makes it the back button.
    c.gtk_widget_set_cursor_from_name(ui.search_bar.back, "pointer");
    const back_click = c.gtk_gesture_click_new();
    widgets.connect(back_click, "released", &onBackClicked, ui);
    c.gtk_widget_add_controller(ui.search_bar.back, back_click);
    gtk.append(search, ui.search_bar.back);
    ui.search_bar.icon = c.gtk_image_new_from_icon_name("system-search-symbolic");
    gtk.addClass(ui.search_bar.icon, "search-icon");
    gtk.setValign(ui.search_bar.icon, c.GTK_ALIGN_CENTER);
    gtk.setVisible(ui.search_bar.icon, false);
    gtk.append(search, ui.search_bar.icon);
    ui.search_bar.prompt = widgets.label("", "prompt");
    gtk.setValign(ui.search_bar.prompt, c.GTK_ALIGN_CENTER);
    gtk.setVisible(ui.search_bar.prompt, false);
    gtk.append(search, ui.search_bar.prompt);
    ui.search_bar.scope = widgets.label("", "scope");
    gtk.setValign(ui.search_bar.scope, c.GTK_ALIGN_CENTER);
    gtk.setVisible(ui.search_bar.scope, false);
    gtk.append(search, ui.search_bar.scope);
    ui.search_bar.entry = gtk.textField();
    gtk.addClass(ui.search_bar.entry, "query");
    gtk.setHexpand(ui.search_bar.entry, true);
    gtk.setValign(ui.search_bar.entry, c.GTK_ALIGN_CENTER);
    gtk.append(search, ui.search_bar.entry);
    widgets.connect(ui.search_bar.entry, "changed", &onChanged, ui);
    const key_chip = widgets.label(actions_keys_text, widgets.css_class.keys);
    ui.search_bar.key_chip = gtk.widget(key_chip);
    gtk.setValign(key_chip, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_tooltip_text(gtk.widget(key_chip), "Actions");
    gtk.append(search, key_chip);
    ui.spacer = widgets.vbox(0);
    gtk.setVexpand(ui.spacer, true);
    gtk.setVisible(ui.spacer, false);
    gtk.append(column, ui.spacer);
    gtk.append(column, search);
}

/// The list and the grid in their scroller, beside the detail pane.
fn buildResults(ui: *Ui, column: *c.GtkBox) void {
    const body = widgets.hbox(0);
    gtk.addClass(body, "results-island");
    ui.results = body;
    ui.scroller = gtk.scrolledWindow();
    c.gtk_scrolled_window_set_policy(
        ui.scroller,
        c.GTK_POLICY_NEVER,
        c.GTK_POLICY_AUTOMATIC,
    );
    // As tall as the rows, up to the space left under the search bar.
    c.gtk_scrolled_window_set_propagate_natural_height(ui.scroller, 1);
    c.gtk_scrolled_window_set_max_content_height(ui.scroller, listHeightMax(ui));
    gtk.setHexpand(ui.scroller, true);
    ui.list = gtk.listBox();
    gtk.addClass(ui.list, "results");
    c.gtk_list_box_set_selection_mode(ui.list, c.GTK_SELECTION_SINGLE);
    gtk.setFocusable(ui.list, false);
    widgets.connect(ui.list, "row-activated", &row_list.onRowActivated, ui);
    ui.grid = gtk.flowBox();
    gtk.addClass(ui.grid, "grid");
    c.gtk_flow_box_set_selection_mode(ui.grid, c.GTK_SELECTION_SINGLE);
    c.gtk_flow_box_set_homogeneous(ui.grid, 1);
    c.gtk_flow_box_set_activate_on_single_click(ui.grid, 1);
    c.gtk_flow_box_set_row_spacing(ui.grid, grid_spacing_px);
    c.gtk_flow_box_set_column_spacing(ui.grid, grid_spacing_px);
    gtk.setFocusable(ui.grid, false);
    gtk.setValign(ui.grid, c.GTK_ALIGN_START);
    gtk.setVisible(ui.grid, false);
    widgets.connect(ui.grid, "child-activated", &row_list.onGridActivated, ui);
    // The list and the grid share the scroller; showEmptyOrResults shows one
    // of them at a time.
    const lists = widgets.vbox(0);
    gtk.append(lists, ui.list);
    gtk.append(lists, ui.grid);
    c.gtk_scrolled_window_set_child(ui.scroller, gtk.widget(lists));
    gtk.append(body, ui.scroller);
    detail_pane.buildDetail(ui);
    gtk.append(body, ui.detail.box);
    gtk.append(column, body);
}

/// The footer (lumen.layout { footer = true }): title, action, keys.
fn buildFooter(ui: *Ui, column: *c.GtkBox) void {
    ui.footer.box = widgets.hbox(8);
    gtk.addClass(ui.footer.box, "footer");
    gtk.setSizeRequest(ui.footer.box, -1, footer_height_px);
    ui.footer.title = widgets.label("Lumen", "footer-title");
    gtk.setHexpand(ui.footer.title, true);
    c.gtk_label_set_xalign(ui.footer.title, 0);
    c.gtk_label_set_ellipsize(ui.footer.title, c.PANGO_ELLIPSIZE_END);
    gtk.append(ui.footer.box, ui.footer.title);
    ui.footer.action = widgets.label("", footer_action_class);
    gtk.append(ui.footer.box, ui.footer.action);
    ui.footer.enter = widgets.label(enter_key_text, widgets.css_class.keys);
    gtk.setValign(ui.footer.enter, c.GTK_ALIGN_CENTER);
    gtk.append(ui.footer.box, ui.footer.enter);
    ui.footer.separator = widgets.label("", "footer-sep");
    gtk.setValign(ui.footer.separator, c.GTK_ALIGN_CENTER);
    gtk.append(ui.footer.box, ui.footer.separator);
    gtk.append(ui.footer.box, widgets.label("Actions", footer_action_class));
    const actions_key_label = widgets.label(actions_keys_text, widgets.css_class.keys);
    gtk.setValign(actions_key_label, c.GTK_ALIGN_CENTER);
    gtk.append(ui.footer.box, actions_key_label);
    gtk.setVisible(ui.footer.box, false);
    gtk.append(column, ui.footer.box);
}

/// The search bar's widget for `part`.
fn barWidget(ui: *Ui, part: layout_mod.BarPart) *c.GtkWidget {
    return switch (part) {
        .back => ui.search_bar.back,
        .icon => ui.search_bar.icon,
        .prompt => gtk.widget(ui.search_bar.prompt),
        .scope => gtk.widget(ui.search_bar.scope),
        .entry => gtk.widget(ui.search_bar.entry),
        .keys => ui.search_bar.key_chip,
    };
}

/// lumen.layout: the pieces' order, one panel or two, the footer, the
/// detail pane's side, what rows show; then the size. The caller rebuilds
/// the rows.
pub fn applyStructure(ui: *Ui) void {
    assert(ui.built);
    const layout = ui.layout;
    ui.row_look.show = layout.show;
    ui.row_look.rows_inline = layout.rows == .@"inline";
    ui.row_look.parts = layout.row;
    // The search bar's parts in order; setView decides which of them show.
    const bar: *c.GtkBox = ui.search_bar.box;
    var previous: ?*c.GtkWidget = null;
    for (layout.searchbar.slice()) |part| {
        const widget = barWidget(ui, part);
        c.gtk_box_reorder_child_after(bar, widget, previous);
        previous = widget;
    }
    c.gtk_label_set_text(ui.search_bar.prompt, layout.prompt.ptr);
    c.gtk_widget_set_visible(gtk.widget(ui.search_bar.prompt), @intFromBool(
        layout.prompt.len > 0 and layout.searchbar.has(.prompt),
    ));
    c.gtk_widget_set_visible(ui.search_bar.icon, @intFromBool(
        layout.show.search_icon and layout.searchbar.has(.icon),
    ));
    const column_box: *c.GtkBox = ui.column;
    c.gtk_box_set_spacing(column_box, if (layout.panels == .single) 0 else pieces_gap_px);
    gtk.setClass(ui.column, "single", layout.panels == .single);
    gtk.setClass(ui.column, "search-bottom", layout.search == .bottom);
    gtk.setClass(ui.column, "with-footer", layout.footer);
    // The spacer first, then the search bar and the results in the chosen
    // order, the footer last.
    c.gtk_box_reorder_child_after(column_box, gtk.widget(ui.spacer), null);
    const first, const second = if (layout.search == .bottom)
        .{ ui.results, ui.search_bar.box }
    else
        .{ ui.search_bar.box, ui.results };
    c.gtk_box_reorder_child_after(column_box, gtk.widget(first), gtk.widget(ui.spacer));
    c.gtk_box_reorder_child_after(column_box, gtk.widget(second), gtk.widget(first));
    c.gtk_box_reorder_child_after(column_box, gtk.widget(ui.footer.box), gtk.widget(second));
    gtk.setVisible(ui.spacer, layout.search == .bottom);
    gtk.setVisible(ui.footer.box, layout.footer);
    c.gtk_widget_set_visible(ui.search_bar.key_chip, @intFromBool(
        layout.show.key_hints and layout.searchbar.has(.keys),
    ));
    // With a footer, or the search bar at the bottom, the action panel opens
    // down there, above them.
    c.gtk_widget_set_valign(
        gtk.widget(ui.panel.box),
        if (layout.footer or layout.search == .bottom) c.GTK_ALIGN_END else c.GTK_ALIGN_START,
    );
    gtk.setClass(ui.panel.box, "from-footer", layout.footer);
    gtk.setClass(ui.panel.box, "from-bottom", layout.search == .bottom);

    const island: *c.GtkBox = ui.results;
    c.gtk_orientable_set_orientation(
        ui.results,
        if (layout.detail == .bottom) c.GTK_ORIENTATION_VERTICAL else c.GTK_ORIENTATION_HORIZONTAL,
    );
    // Null puts the detail pane first: on the left of the list.
    const detail_after: ?*c.GtkWidget = switch (layout.detail) {
        .left => null,
        else => gtk.widget(ui.scroller),
    };
    c.gtk_box_reorder_child_after(island, gtk.widget(ui.detail.box), detail_after);
    gtk.setClass(ui.results, "detail-left", layout.detail == .left);
    gtk.setClass(ui.results, "detail-bottom", layout.detail == .bottom);
    applyLayout(ui);
}

/// Width, height and density from the settings. A layer surface takes its
/// size when it is mapped: a change while it shows maps it again.
pub fn applyLayout(ui: *Ui) void {
    ui.row_look.icon_px = themes.densitySizes(ui.settings.density).icon_px;
    if (!ui.built) return;
    const width_px = panelWidth(ui);
    const height_px = panelHeight(ui);
    c.gtk_scrolled_window_set_max_content_height(ui.scroller, listHeightMax(ui));
    var width_current_px: c_int = 0;
    var height_current_px: c_int = 0;
    c.gtk_widget_get_size_request(gtk.widget(ui.column), &width_current_px, &height_current_px);
    if (width_current_px == width_px and height_current_px == height_px) return;
    gtk.setSizeRequest(ui.column, width_px, height_px);
    c.gtk_window_set_default_size(
        ui.window,
        width_px + 2 * style_css.shell_margin_px,
        height_px + 2 * style_css.shell_margin_px,
    );
    if (gtk.isVisible(ui.window)) {
        gtk.setVisible(ui.window, false);
        gtk.setVisible(ui.window, true);
        _ = c.gtk_widget_grab_focus(gtk.widget(ui.search_bar.entry));
    }
    // The list beside a detail pane keeps ~40% of the width.
    if (gtk.isVisible(ui.detail.box)) {
        gtk.setSizeRequest(ui.scroller, @divTrunc(width_px * 2, 5), -1);
    }
}

/// The window's parts for `view`: the detail pane and what it shows, the
/// grid, the back arrow and the magnifier, the list's size.
pub fn layoutFor(ui: *Ui, view: View) void {
    const open_command = if (view == .ext) ext_view.command(ui) else null;
    const ext_detail = if (open_command) |shown| shown.detail else false;
    const has_detail = view == .clipboard or view == .files or view == .contents or ext_detail;
    ui.grid_mode = if (open_command) |shown| shown.grid else false;
    if (ui.grid_mode) {
        ui.grid_columns = ext_view.command(ui).?.columns;
        c.gtk_flow_box_set_min_children_per_line(ui.grid, @intCast(ui.grid_columns));
        c.gtk_flow_box_set_max_children_per_line(ui.grid, @intCast(ui.grid_columns));
    }
    const bar = ui.layout.searchbar;
    const back_shows = view != .root and ui.layout.show.back and bar.has(.back);
    gtk.setVisible(ui.search_bar.back, back_shows);
    // The magnifier gives way to the back arrow inside a view.
    c.gtk_widget_set_visible(ui.search_bar.icon, @intFromBool(
        ui.layout.show.search_icon and bar.has(.icon) and !back_shows,
    ));
    gtk.setVisible(ui.detail.box, has_detail);
    // A preview needs room: the results take the full height then.
    gtk.setVexpand(ui.results, has_detail);
    // Beside the detail pane the list takes ~40%; above it, ~half the height.
    const detail_below = ui.layout.detail == .bottom;
    c.gtk_widget_set_size_request(
        gtk.widget(ui.scroller),
        if (has_detail and !detail_below) @divTrunc(panelWidth(ui) * 2, 5) else -1,
        -1,
    );
    gtk.setHexpand(ui.scroller, !has_detail or detail_below);
    const list_height_max = listHeightMax(ui);
    c.gtk_scrolled_window_set_max_content_height(
        ui.scroller,
        if (has_detail and detail_below) @divTrunc(list_height_max, 2) else list_height_max,
    );
    detail_pane.prepareFor(&ui.detail, view);
}

/// Puts the window on the monitor Hyprland has focused, a bit above centre.
pub fn placeOnFocusedMonitor(ui: *Ui) void {
    if (Ui.testMode()) return;
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
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
        c.gtk_layer_set_monitor(ui.window, monitor);
        var geometry: c.GdkRectangle = undefined;
        c.gdk_monitor_get_geometry(monitor, &geometry);
        const window: *c.GtkWindow = ui.window;
        const chosen: layout_mod.Position = switch (ui.settings.position) {
            .upper_third => .upper_third,
            .center => .center,
        };
        const position = ui.layout.position orelse chosen;
        const offset_px: c_int = ui.layout.offset;
        // The pieces sit `style_css.shell_margin_px` inside the surface, room
        // for their shadows, so the margin is the pieces' place minus that.
        const at_bottom = position == .bottom;
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, @intFromBool(!at_bottom));
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_BOTTOM, @intFromBool(at_bottom));
        const room_px = geometry.height - panelHeight(ui);
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

fn onChanged(_: *c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    ui.refresh();
}

fn onBackClicked(
    _: *c.GtkEventController,
    _: c_int,
    _: f64,
    _: f64,
    data: ?*anyopaque,
) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    if (ui.view != .root) ui.goBack();
    _ = c.gtk_widget_grab_focus(gtk.widget(ui.search_bar.entry));
}

fn onKey(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    data: ?*anyopaque,
) callconv(.c) c.gboolean {
    const ui: *Ui = @ptrCast(@alignCast(data));
    return keyboard.handleKey(ui, keyval, state);
}

test "style.css has the sizes the window computes with" {
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
