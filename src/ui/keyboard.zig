//! The keyboard: navigation, actions, the action panel.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const item_mod = @import("../item.zig");
const Ui = @import("Ui.zig");

/// A key press, real or from `lumen --key`; true (1) when Lumen handled it.
pub fn handleKey(ui: *Ui, keyval: c_uint, state: c.GdkModifierType) c.gboolean {
    const key: KeyPress = .decode(keyval, state, .{ .panel_open = ui.panel.open });

    if (ui.panel.open) {
        panelKey(ui, key);
        return 1;
    }
    if (key.keyval == c.GDK_KEY_Escape) {
        escape(ui);
        return 1;
    }
    if (move(ui, key)) return 1;
    if (key.ctrl and key.keyval == c.GDK_KEY_k) {
        ui.openPanel();
        return 1;
    }
    // In dmenu, Ctrl+Enter (or Enter when no row matches) answers with the
    // typed text instead of a row.
    if (key.enter and ui.view == .dmenu and (key.ctrl or ui.selectedItem() == null)) {
        Ui.dmenu.chooseTyped(ui);
        return 1;
    }
    if (key.enter) {
        const item = ui.selectedItem() orelse return 1;
        const actions = item_mod.actionsFor(item);
        assert(actions.len > 0);
        if (key.ctrl and actions.len > 1) {
            ui.performEntry(actions[1]);
        } else {
            ui.performEntry(actions[0]);
        }
        return 1;
    }
    if (itemShortcut(ui, key)) return 1;
    if (key.keyval == c.GDK_KEY_BackSpace and ui.query().len == 0 and ui.view != .root) {
        ui.goBack();
        return 1;
    }
    // Keymaps from init.lua and extensions.
    if (Ui.ext_view.keymap(ui, keyval, state)) return 1;
    return 0;
}

/// A key press decoded once: the key, the modifiers held, and what it means
/// for moving and running. The functions below read these instead of each
/// taking four booleans.
const KeyPress = struct {
    keyval: c_uint,
    ctrl: bool,
    shift: bool,
    /// Up or Down, the arrows or their chords: Ctrl+P and Ctrl+N, Ctrl+K
    /// and Ctrl+J. Ctrl+K moves up only while the action panel is open:
    /// otherwise it opens the panel.
    vertical: ?Vertical,
    /// Return or the keypad's Enter.
    enter: bool,

    const Vertical = enum { up, down };

    fn decode(
        keyval: c_uint,
        state: c.GdkModifierType,
        context: struct { panel_open: bool },
    ) KeyPress {
        const ctrl = state & c.GDK_CONTROL_MASK != 0;
        const down = keyval == c.GDK_KEY_Down or
            (ctrl and (keyval == c.GDK_KEY_n or keyval == c.GDK_KEY_j));
        const up = keyval == c.GDK_KEY_Up or
            (ctrl and (keyval == c.GDK_KEY_p or keyval == c.GDK_KEY_k and context.panel_open));
        // No key is both: a chord names one letter.
        assert(!(down and up));
        return .{
            .keyval = keyval,
            .ctrl = ctrl,
            .shift = state & c.GDK_SHIFT_MASK != 0,
            .vertical = if (down) .down else if (up) .up else null,
            .enter = keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter,
        };
    }

    /// -1 for up, +1 for down: how `Ui.nextSelectable` steps.
    fn step(vertical: Vertical) i32 {
        return switch (vertical) {
            .up => -1,
            .down => 1,
        };
    }
};

/// Rows Page Up and Page Down move by: about what the list shows.
const page_rows = 8;

/// Keys while the action panel is open: they all go to it.
fn panelKey(ui: *Ui, key: KeyPress) void {
    assert(ui.panel.open);
    assert(ui.panel.entries.len > 0);
    assert(ui.panel.selected < ui.panel.entries.len);
    const closes = key.keyval == c.GDK_KEY_Escape or
        (key.ctrl and key.keyval == c.GDK_KEY_k and key.vertical == null);
    if (closes) {
        ui.panel.close();
    } else if (key.vertical) |vertical| switch (vertical) {
        .down => ui.panel.select(@min(ui.panel.selected + 1, ui.panel.entries.len - 1)),
        .up => ui.panel.select(ui.panel.selected -| 1),
    } else if (key.enter) {
        ui.performEntry(ui.panel.entries[ui.panel.selected]);
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
        c.gtk_editable_set_text(gtk.editable(ui.search_bar.entry), "");
    } else if (ui.view != .root) ui.goBack() else ui.hide();
}

/// Moving the selection: by row, by page, or across the grid. True when
/// the key was one of those.
fn move(ui: *Ui, key: KeyPress) bool {
    const horizontal = key.keyval == c.GDK_KEY_Left or key.keyval == c.GDK_KEY_Right;
    // A grid moves in two directions: a line is `grid_columns` cells.
    if (ui.grid_mode and ui.rows.items.len > 0 and (key.vertical != null or horizontal)) {
        const cell_count: i64 = @intCast(ui.rows.items.len);
        const current: i64 = if (ui.selected) |selected| @intCast(selected) else 0;
        const step: i64 = if (key.vertical) |vertical|
            KeyPress.step(vertical) * ui.grid_columns
        else if (key.keyval == c.GDK_KEY_Right)
            1
        else
            -1;
        const next = current + step;
        if (next >= 0 and next < cell_count) ui.select(@intCast(next));
        return true;
    }
    if (key.vertical) |vertical| {
        ui.select(ui.nextSelectable(ui.selected, KeyPress.step(vertical)));
        return true;
    }
    if (key.keyval == c.GDK_KEY_Page_Down or key.keyval == c.GDK_KEY_Page_Up) {
        const direction: i32 = if (key.keyval == c.GDK_KEY_Page_Down) 1 else -1;
        var target = ui.selected;
        for (0..page_rows) |_| target = ui.nextSelectable(target, direction);
        ui.select(target);
        return true;
    }
    return false;
}

/// Ctrl+letter (and Ctrl+Shift+letter) on the selected row: the action
/// whose keys say that chord in the action panel ("Ctrl X", "Ctrl Shift C"),
/// so what the panel shows is what the keys do. True when one ran.
fn itemShortcut(ui: *Ui, key: KeyPress) bool {
    const ascii_max = 0x7f;
    if (!key.ctrl or key.keyval > ascii_max) return false;
    if (!std.ascii.isAlphabetic(@intCast(key.keyval))) return false;
    const letter = std.ascii.toUpper(@intCast(key.keyval));
    var chord_bytes: ["Ctrl Shift X".len]u8 = undefined;
    const chord = std.mem.print(&chord_bytes, "Ctrl {s}{c}", .{
        if (key.shift) "Shift " else "",
        letter,
    }) catch return false;
    const item = ui.selectedItem() orelse return false;
    for (item_mod.actionsFor(item)) |entry| {
        if (std.mem.eql(u8, entry.keys, chord)) {
            ui.performEntry(entry);
            return true;
        }
    }
    return false;
}
