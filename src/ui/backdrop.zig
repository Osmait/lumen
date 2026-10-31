//! Closing on a click outside: clear full-screen layers under the window,
//! one per monitor, and the clear part of the window itself.

const c = @import("c");
const gtk = @import("gtk.zig");
const item_mod = @import("../item.zig");
const Ui = @import("Ui.zig");
const widgets = @import("widgets.zig");

/// The backdrops' CSS class and their layer-shell namespace (compositor
/// rules can match it).
const backdrop_name = "lumen-backdrop";

pub fn makeBackdrop(ui: *Ui) *c.GtkWindow {
    const window = gtk.plainWindow();
    gtk.addClass(window, backdrop_name);
    c.gtk_window_set_decorated(window, 0);
    c.gtk_layer_init_for_window(window);
    c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
    c.gtk_layer_set_namespace(window, backdrop_name);
    const edges = [_]c_int{
        c.GTK_LAYER_SHELL_EDGE_LEFT,
        c.GTK_LAYER_SHELL_EDGE_RIGHT,
        c.GTK_LAYER_SHELL_EDGE_TOP,
        c.GTK_LAYER_SHELL_EDGE_BOTTOM,
    };
    for (edges) |edge| c.gtk_layer_set_anchor(window, edge, 1);
    // Over the bars too: a click on them closes Lumen as well.
    c.gtk_layer_set_exclusive_zone(window, -1);
    const click = c.gtk_gesture_click_new();
    widgets.connect(click, "pressed", &onBackdropPressed, ui);
    c.gtk_widget_add_controller(gtk.widget(window), click);
    return window;
}

/// One backdrop per monitor, mapped before the window so they stack under it.
/// Makes and realizes one per monitor, hidden: the first show used to create
/// each full-screen layer (its surface and renderer) while the user waited.
pub fn prewarmBackdrops(ui: *Ui) void {
    if (Ui.testMode()) return;
    const monitors = c.gdk_display_get_monitors(c.gdk_display_get_default() orelse return);
    const monitor_count = @min(c.g_list_model_get_n_items(monitors), ui.backdrops.len);
    for (ui.backdrops[0..monitor_count], 0..) |*slot, i| {
        if (slot.* != null) continue;
        const item = c.g_list_model_get_item(monitors, @intCast(i)) orelse continue;
        defer c.g_object_unref(item);
        // The display's monitor list holds GdkMonitors only.
        const monitor: *c.GdkMonitor = @ptrCast(item);
        const backdrop = makeBackdrop(ui);
        slot.* = backdrop;
        c.gtk_layer_set_monitor(backdrop, monitor);
        c.gtk_widget_realize(gtk.widget(backdrop));
    }
}

pub fn showBackdrops(ui: *Ui) void {
    if (Ui.testMode()) return;
    const monitors = c.gdk_display_get_monitors(c.gdk_display_get_default() orelse return);
    const monitor_count = @min(c.g_list_model_get_n_items(monitors), ui.backdrops.len);
    for (&ui.backdrops, 0..) |*slot, i| {
        if (i >= monitor_count) {
            if (slot.*) |backdrop| gtk.setVisible(backdrop, false);
            continue;
        }
        const item = c.g_list_model_get_item(monitors, @intCast(i)) orelse continue;
        defer c.g_object_unref(item);
        // The display's monitor list holds GdkMonitors only.
        const monitor: *c.GdkMonitor = @ptrCast(item);
        const backdrop = slot.* orelse makeBackdrop(ui);
        slot.* = backdrop;
        c.gtk_layer_set_monitor(backdrop, monitor);
        gtk.setVisible(backdrop, true);
    }
}

pub fn hideBackdrops(ui: *Ui) void {
    for (ui.backdrops) |slot| if (slot) |backdrop| gtk.setVisible(backdrop, false);
}

/// Whether the window point (x, y) falls on `w` (shown).
pub fn isOn(ui: *Ui, piece: anytype, x: f64, y: f64) bool {
    const widget = gtk.widget(piece);
    if (!gtk.isVisible(widget)) return false;
    var bounds: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(widget, gtk.widget(ui.window), &bounds) == 0) return false;
    const inside_x = x >= bounds.origin.x and x < bounds.origin.x + bounds.size.width;
    const inside_y = y >= bounds.origin.y and y < bounds.origin.y + bounds.size.height;
    return inside_x and inside_y;
}

pub fn onWindowPressed(
    _: *c.GtkEventController,
    _: c_int,
    x: f64,
    y: f64,
    data: ?*anyopaque,
) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const on_pieces = isOn(self, self.search_bar.box, x, y) or isOn(self, self.results, x, y);
    if (self.panel.open) {
        if (isOn(self, gtk.widget(self.panel.box), x, y)) return;
        // Outside the action panel but on Lumen: only the panel closes.
        if (on_pieces) return self.panel.close();
    }
    if (!on_pieces) self.hide();
}

pub fn onBackdropPressed(
    _: *c.GtkEventController,
    _: c_int,
    _: f64,
    _: f64,
    data: ?*anyopaque,
) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    self.hide();
}
