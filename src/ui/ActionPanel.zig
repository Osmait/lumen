//! The action panel (Ctrl K): the selected row's actions, floating over the
//! results. Ui owns one; `Ui.openPanel` fills it from the selection, the
//! keyboard moves in it while it is open, and Enter or a click runs the
//! chosen entry through `Ui.performEntry`.
//!
//! It is open exactly while it lists entries: they may point into an
//! extension's answer that is freed when the rows are rebuilt, so closing
//! forgets them.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const item_mod = @import("../item.zig");
const widgets = @import("widgets.zig");
const Ui = @import("Ui.zig");

const ActionPanel = @This();

box: *c.GtkBox = undefined,
list: *c.GtkListBox = undefined,
/// The actions listed, empty while closed.
entries: []const item_mod.Entry = &.{},
selected: usize = 0,

/// Makes the panel's widgets, hidden, over the top right corner of the
/// results. A click on a row runs it on `ui`'s selection.
pub fn build(panel: *ActionPanel, ui: *Ui, overlay: *c.GtkOverlay) void {
    panel.box = widgets.vbox(0);
    gtk.addClass(panel.box, "actions");
    gtk.setHalign(panel.box, c.GTK_ALIGN_END);
    gtk.setValign(panel.box, c.GTK_ALIGN_START);
    gtk.append(panel.box, widgets.label("Actions", "actions-title"));
    panel.list = gtk.listBox();
    gtk.setFocusable(panel.list, false);
    widgets.connect(panel.list, "row-activated", &onRowActivated, ui);
    gtk.append(panel.box, panel.list);
    gtk.setVisible(panel.box, false);
    c.gtk_overlay_add_overlay(overlay, gtk.widget(panel.box));
}

pub fn isOpen(panel: *const ActionPanel) bool {
    return panel.entries.len > 0;
}

/// Lists `entries` and opens on the first.
pub fn show(panel: *ActionPanel, entries: []const item_mod.Entry) void {
    // Every item has a primary action: the panel is never empty, and the
    // keys that move in it count on that.
    assert(entries.len > 0);
    panel.entries = entries;
    c.gtk_list_box_remove_all(panel.list);
    for (entries) |entry| {
        const row = gtk.listBoxRow();
        const box = widgets.hbox(8);
        const label_widget = widgets.label(entry.label, null);
        gtk.setHexpand(label_widget, true);
        gtk.append(box, label_widget);
        if (entry.keys.len > 0) {
            const keys_label = widgets.label(entry.keys, widgets.css_class.keys);
            gtk.setValign(keys_label, c.GTK_ALIGN_CENTER);
            gtk.append(box, keys_label);
        }
        c.gtk_list_box_row_set_child(row, gtk.widget(box));
        c.gtk_list_box_append(panel.list, gtk.widget(row));
    }
    assert(panel.isOpen());
    panel.select(0);
    gtk.setVisible(panel.box, true);
}

pub fn close(panel: *ActionPanel) void {
    panel.entries = &.{};
    gtk.setVisible(panel.box, false);
    assert(!panel.isOpen());
}

pub fn select(panel: *ActionPanel, entry_index: usize) void {
    assert(entry_index < panel.entries.len);
    panel.selected = entry_index;
    const row = c.gtk_list_box_get_row_at_index(panel.list, @intCast(entry_index));
    c.gtk_list_box_select_row(panel.list, row);
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    const entry_index: usize = @intCast(c.gtk_list_box_row_get_index(row));
    if (entry_index < ui.panel.entries.len) ui.performEntry(ui.panel.entries[entry_index]);
}
