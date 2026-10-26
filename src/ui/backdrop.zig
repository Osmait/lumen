//! Closing on a click outside: clear full-screen layers under the window,
//! one per monitor, and the clear part of the window itself.

const c = @import("c");
const item_mod = @import("../item.zig");
const Ui = @import("Ui.zig");
const widgets = @import("widgets.zig");

pub fn makeBackdrop(ui: *Ui) *c.GtkWidget {
    const win = c.gtk_window_new();
    c.gtk_widget_add_css_class(win, "lumen-backdrop");
    c.gtk_window_set_decorated(@ptrCast(win), 0);
    const w: *c.GtkWindow = @ptrCast(win);
    c.gtk_layer_init_for_window(w);
    c.gtk_layer_set_layer(w, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    c.gtk_layer_set_keyboard_mode(w, c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
    c.gtk_layer_set_namespace(w, "lumen-backdrop");
    const edges = [_]c_int{ c.GTK_LAYER_SHELL_EDGE_LEFT, c.GTK_LAYER_SHELL_EDGE_RIGHT, c.GTK_LAYER_SHELL_EDGE_TOP, c.GTK_LAYER_SHELL_EDGE_BOTTOM };
    for (edges) |edge| c.gtk_layer_set_anchor(w, edge, 1);
    // Over the bars too: a click on them closes Lumen as well.
    c.gtk_layer_set_exclusive_zone(w, -1);
    const click = c.gtk_gesture_click_new();
    widgets.connect(click, "pressed", &onBackdropPressed, ui);
    c.gtk_widget_add_controller(win, click);
    return win;
}

/// One backdrop per monitor, mapped before the window so they stack under it.
pub fn showBackdrops(ui: *Ui) void {
    if (Ui.testMode()) return;
    const monitors = c.gdk_display_get_monitors(c.gdk_display_get_default() orelse return);
    const n = @min(c.g_list_model_get_n_items(monitors), ui.backdrops.len);
    for (&ui.backdrops, 0..) |*slot, i| {
        if (i >= n) {
            if (slot.*) |b| c.gtk_widget_set_visible(b, 0);
            continue;
        }
        const obj = c.g_list_model_get_item(monitors, @intCast(i)) orelse continue;
        defer c.g_object_unref(obj);
        const b = slot.* orelse makeBackdrop(ui);
        slot.* = b;
        c.gtk_layer_set_monitor(@ptrCast(b), @ptrCast(obj));
        c.gtk_widget_set_visible(b, 1);
    }
}

pub fn hideBackdrops(ui: *Ui) void {
    for (ui.backdrops) |slot| if (slot) |b| c.gtk_widget_set_visible(b, 0);
}

/// Whether the window point (x, y) falls on `w` (shown).
pub fn isOn(ui: *Ui, w: *c.GtkWidget, x: f64, y: f64) bool {
    if (c.gtk_widget_get_visible(w) == 0) return false;
    var b: c.graphene_rect_t = undefined;
    if (c.gtk_widget_compute_bounds(w, ui.window, &b) == 0) return false;
    return x >= b.origin.x and x < b.origin.x + b.size.width and y >= b.origin.y and y < b.origin.y + b.size.height;
}

pub fn onWindowPressed(_: *c.GtkEventController, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    const on_pieces = isOn(self, self.search_bar, x, y) or isOn(self, self.results, x, y);
    if (self.panel_open) {
        if (isOn(self, self.panel, x, y)) return;
        // Outside the action panel but on Lumen: only the panel closes.
        if (on_pieces) return self.closePanel();
    }
    if (!on_pieces) self.hide();
}

pub fn onBackdropPressed(_: *c.GtkEventController, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const self: *Ui = @ptrCast(@alignCast(data));
    self.hide();
}
