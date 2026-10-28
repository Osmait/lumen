//! The keyboard: navigation, actions, the action panel.

const std = @import("std");
const c = @import("c");
const item_mod = @import("../item.zig");
const Ui = @import("Ui.zig");

/// A key press, real or from `lumen --key`; true (1) when Lumen handled it.
pub fn handleKey(ui: *Ui, keyval: c_uint, state: c.GdkModifierType) c.gboolean {
    const ctrl = state & c.GDK_CONTROL_MASK != 0;
    const shift = state & c.GDK_SHIFT_MASK != 0;
    const down = keyval == c.GDK_KEY_Down or
        (ctrl and (keyval == c.GDK_KEY_n or keyval == c.GDK_KEY_j));
    const up = keyval == c.GDK_KEY_Up or
        (ctrl and (keyval == c.GDK_KEY_p or keyval == c.GDK_KEY_k and ui.panel_open));
    const enter = keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter;

    if (ui.panel_open) {
        panelKey(ui, keyval, ctrl, down, up, enter);
        return 1;
    }
    if (keyval == c.GDK_KEY_Escape) {
        escape(ui);
        return 1;
    }
    if (move(ui, keyval, down, up)) return 1;
    if (ctrl and keyval == c.GDK_KEY_k) {
        ui.openPanel();
        return 1;
    }
    // dmenu: Ctrl+Enter, or Enter with nothing matching, answers with the
    // text typed.
    if (enter and ui.view == .dmenu and (ctrl or ui.selectedItem() == null)) {
        Ui.dmenu.chooseTyped(ui);
        return 1;
    }
    if (enter) {
        const it = ui.selectedItem() orelse return 1;
        const actions = item_mod.actionsFor(it);
        if (ctrl and actions.len > 1) ui.performEntry(actions[1]) else ui.performEntry(actions[0]);
        return 1;
    }
    if (itemShortcut(ui, keyval, ctrl, shift)) return 1;
    if (keyval == c.GDK_KEY_BackSpace and ui.query().len == 0 and ui.view != .root) {
        ui.goBack();
        return 1;
    }
    // Keymaps from init.lua and extensions.
    if (Ui.ext_view.keymap(ui, keyval, state)) return 1;
    return 0;
}

/// Keys while the action panel is open: they all go to it.
fn panelKey(ui: *Ui, keyval: c_uint, ctrl: bool, down: bool, up: bool, enter: bool) void {
    if (keyval == c.GDK_KEY_Escape or (ctrl and keyval == c.GDK_KEY_k and !up)) {
        ui.closePanel();
    } else if (down) {
        ui.selectPanel(@min(ui.panel_selected + 1, ui.panel_entries.len - 1));
    } else if (up) {
        ui.selectPanel(ui.panel_selected -| 1);
    } else if (enter) {
        ui.performEntry(ui.panel_entries[ui.panel_selected]);
    }
}

/// Esc: clears what is typed, then goes back a view, then hides.
fn escape(ui: *Ui) void {
    // A dmenu caller is waiting: Esc answers "nothing" and hides.
    if (ui.view == .dmenu and ui.query().len == 0) {
        ui.hide();
    } else if (ui.view == .input) {
        // The text is the value being edited: Esc leaves it unsaved.
        ui.goBack();
    } else if (ui.query().len > 0) {
        c.gtk_editable_set_text(@ptrCast(ui.entry), "");
    } else if (ui.view != .root) ui.goBack() else ui.hide();
}

/// Moving the selection: by row, by page, or across the grid. True when
/// the key was one of those.
fn move(ui: *Ui, keyval: c_uint, down: bool, up: bool) bool {
    // A grid moves in two directions: a line is `grid_columns` cells.
    if (ui.grid_mode and ui.rows.items.len > 0 and
        (down or up or keyval == c.GDK_KEY_Left or keyval == c.GDK_KEY_Right))
    {
        const n: i64 = @intCast(ui.rows.items.len);
        const cur: i64 = if (ui.selected) |s| @intCast(s) else 0;
        const step: i64 = if (down)
            ui.grid_columns
        else if (up)
            -ui.grid_columns
        else if (keyval == c.GDK_KEY_Right)
            1
        else
            -1;
        const next = cur + step;
        if (next >= 0 and next < n) ui.select(@intCast(next));
        return true;
    }
    if (down or up) {
        ui.select(ui.nextSelectable(ui.selected, if (down) 1 else -1));
        return true;
    }
    if (keyval == c.GDK_KEY_Page_Down or keyval == c.GDK_KEY_Page_Up) {
        const dir: i32 = if (keyval == c.GDK_KEY_Page_Down) 1 else -1;
        var target = ui.selected;
        for (0..8) |_| target = ui.nextSelectable(target, dir);
        ui.select(target);
        return true;
    }
    return false;
}

/// Ctrl+letter (and Ctrl+Shift+letter) on the selected row: the action
/// whose keys say that chord in the action panel ("Ctrl X", "Ctrl Shift C"),
/// so what the panel shows is what the keys do. True when one ran.
fn itemShortcut(ui: *Ui, keyval: c_uint, ctrl: bool, shift: bool) bool {
    if (!ctrl or keyval > 0x7f or !std.ascii.isAlphabetic(@intCast(keyval))) return false;
    const letter = std.ascii.toUpper(@intCast(keyval));
    var buf: [16]u8 = undefined;
    const chord = std.mem.print(&buf, "Ctrl {s}{c}", .{
        if (shift) "Shift " else "",
        letter,
    }) catch return false;
    const it = ui.selectedItem() orelse return false;
    for (item_mod.actionsFor(it)) |e| if (std.mem.eql(u8, e.keys, chord)) {
        ui.performEntry(e);
        return true;
    };
    return false;
}
