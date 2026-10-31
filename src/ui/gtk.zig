//! Widgets made with their own GTK type.
//!
//! GTK's constructors return GtkWidget*, and the bindings in c.zig give each
//! class an opaque type of its own, so a list made with gtk_list_box_new
//! needed an unchecked @ptrCast at every gtk_list_box_* call: nothing
//! stopped a label being cast to a list. Here a widget is made as what it
//! is, and the casts left are upcasts (`widget`, `editable`), which are
//! valid for every type they accept.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");

/// The GTK classes Lumen makes; all of them are GtkWidgets.
const widget_types = [_]type{
    c.GtkWidget,
    c.GtkWindow,
    c.GtkBox,
    c.GtkLabel,
    c.GtkImage,
    c.GtkPicture,
    c.GtkText,
    c.GtkListBox,
    c.GtkListBoxRow,
    c.GtkFlowBox,
    c.GtkFlowBoxChild,
    c.GtkScrolledWindow,
    c.GtkOverlay,
};

fn isWidgetType(comptime T: type) bool {
    inline for (widget_types) |Widget| {
        if (T == Widget) return true;
    }
    return false;
}

/// `object` as the GtkWidget it is, for the gtk_widget_* calls.
pub fn widget(object: anytype) *c.GtkWidget {
    const Object = @typeInfo(@TypeOf(object)).pointer.child;
    comptime assert(isWidgetType(Object));
    return @ptrCast(object);
}

/// A text field's GtkEditable interface, which GtkText implements.
pub fn editable(text_field: *c.GtkText) *c.GtkEditable {
    return @ptrCast(text_field);
}

// The gtk_widget_* calls Lumen makes, for any widget type, with booleans
// as `bool` instead of gboolean.

pub fn setVisible(object: anytype, visible: bool) void {
    c.gtk_widget_set_visible(widget(object), @intFromBool(visible));
}

pub fn isVisible(object: anytype) bool {
    return c.gtk_widget_get_visible(widget(object)) != 0;
}

pub fn addClass(object: anytype, class: [*:0]const u8) void {
    c.gtk_widget_add_css_class(widget(object), class);
}

/// Adds or removes the CSS class `class`.
pub fn setClass(object: anytype, class: [*:0]const u8, on: bool) void {
    if (on) {
        c.gtk_widget_add_css_class(widget(object), class);
    } else {
        c.gtk_widget_remove_css_class(widget(object), class);
    }
}

pub fn setHexpand(object: anytype, expand: bool) void {
    c.gtk_widget_set_hexpand(widget(object), @intFromBool(expand));
}

pub fn setVexpand(object: anytype, expand: bool) void {
    c.gtk_widget_set_vexpand(widget(object), @intFromBool(expand));
}

pub fn setHalign(object: anytype, alignment: c_int) void {
    c.gtk_widget_set_halign(widget(object), alignment);
}

pub fn setValign(object: anytype, alignment: c_int) void {
    c.gtk_widget_set_valign(widget(object), alignment);
}

pub fn setFocusable(object: anytype, focusable: bool) void {
    c.gtk_widget_set_focusable(widget(object), @intFromBool(focusable));
}

pub fn setSizeRequest(object: anytype, width_px: c_int, height_px: c_int) void {
    c.gtk_widget_set_size_request(widget(object), width_px, height_px);
}

pub fn append(box: *c.GtkBox, child: anytype) void {
    c.gtk_box_append(box, widget(child));
}

pub fn hbox(spacing_px: c_int) *c.GtkBox {
    return @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, spacing_px));
}

pub fn vbox(spacing_px: c_int) *c.GtkBox {
    return @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, spacing_px));
}

pub fn label(text: ?[*:0]const u8) *c.GtkLabel {
    return @ptrCast(c.gtk_label_new(text));
}

pub fn listBox() *c.GtkListBox {
    return @ptrCast(c.gtk_list_box_new());
}

pub fn listBoxRow() *c.GtkListBoxRow {
    return @ptrCast(c.gtk_list_box_row_new());
}

pub fn flowBox() *c.GtkFlowBox {
    return @ptrCast(c.gtk_flow_box_new());
}

pub fn scrolledWindow() *c.GtkScrolledWindow {
    return @ptrCast(c.gtk_scrolled_window_new());
}

pub fn textField() *c.GtkText {
    return @ptrCast(c.gtk_text_new());
}

pub fn picture() *c.GtkPicture {
    return @ptrCast(c.gtk_picture_new());
}

pub fn imageFromPaintable(paintable: anytype) *c.GtkImage {
    return @ptrCast(c.gtk_image_new_from_paintable(paintable));
}

pub fn imageFromGicon(icon: *c.GIcon) *c.GtkImage {
    return @ptrCast(c.gtk_image_new_from_gicon(icon));
}

pub fn imageFromIconName(name: ?[*:0]const u8) *c.GtkImage {
    return @ptrCast(c.gtk_image_new_from_icon_name(name));
}

pub fn pictureFromPaintable(paintable: anytype) *c.GtkPicture {
    return @ptrCast(c.gtk_picture_new_for_paintable(paintable));
}

pub fn overlay() *c.GtkOverlay {
    return @ptrCast(c.gtk_overlay_new());
}

pub fn window(application: *c.GtkApplication) *c.GtkWindow {
    return @ptrCast(c.gtk_application_window_new(application));
}

test "gtk: only widget classes upcast to GtkWidget" {
    comptime assert(isWidgetType(c.GtkLabel));
    comptime assert(!isWidgetType(c.GtkCssProvider));
    comptime assert(!isWidgetType(c.GtkAdjustment));
}
