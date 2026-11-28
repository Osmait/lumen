//! The keyboard: navigation, actions, the action panel, and the keys
//! `lumen --key` injects for the end-to-end tests.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const item_mod = @import("../item.zig");
const row_list = @import("row_list.zig");
const Ui = @import("Ui.zig");

/// Synthetic / test key handling (`lumen --key`).
pub fn handleKey(ui: *Ui, keyval: c_uint, state: c.GdkModifierType) c.gboolean {
    return handleKeyEvent(ui, keyval, state, false);
}

/// Real or synthetic key press; `from_keyboard` enables repeat-guarding Backspace
/// so holding Backspace to clear a query never exits a view or aborts `--dmenu`.
pub fn handleKeyEvent(
    ui: *Ui,
    keyval: c_uint,
    state: c.GdkModifierType,
    from_keyboard: bool,
) c.gboolean {
    ui.suppress_next_activate = false;
    const key: KeyPress = .decode(keyval, state, .{ .panel_open = ui.panel.isOpen() });
    const previous_keyval = ui.active_keyboard_keyval;
    ui.active_keyboard_keyval = if (from_keyboard) key.keyval else null;
    defer ui.active_keyboard_keyval = previous_keyval;

    if (ui.panel.isOpen()) {
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
    // Text selected in the search bar: Ctrl+X cuts it, as in any text
    // field, instead of trashing the selected file (MYP-567).
    if (editsSelection(ui, key)) return 0;
    if (itemShortcut(ui, key)) return 1;
    if (key.keyval == c.GDK_KEY_BackSpace) {
        const query_empty = ui.query().len == 0;
        switch (backspaceAction(ui.view, query_empty, &ui.backspace_guard, from_keyboard)) {
            .type => {},
            .swallow => return 1,
            .go_back => {
                ui.goBack();
                // The new view cleared the guard: the repeats of this press
                // must neither go back again nor edit its query (MYP-535).
                if (from_keyboard) ui.backspace_guard = .went_back;
                return 1;
            },
        }
    }
    // Then the keymaps from init.lua and extensions. Not in dmenu: opening
    // another view answers the script with nothing and leaves the launcher
    // open (MYP-596).
    if (ui.view != .dmenu and Ui.ext_view.keymap(ui, keyval, state)) return 1;
    if (typeAltChord(ui, keyval, state)) return 1;
    return 0;
}

pub fn handleKeyReleased(ui: *Ui, keyval: c_uint) void {
    if (keyval == c.GDK_KEY_BackSpace) ui.backspace_guard = .free;
    const lower = c.gdk_keyval_to_lower(keyval);
    if (ui.confirm_repeat_keyval == lower) ui.confirm_repeat_keyval = null;
}

/// Backspace held down, from a physical keyboard: its repeats come until it
/// is released.
pub const BackspaceGuard = enum {
    /// Not held (or released since).
    free,
    /// Held while deleting text: reaching an empty bar does not go back.
    held,
    /// Held after it went back: its repeats do nothing at all, neither go
    /// back again nor delete the query the view came back with.
    went_back,
};

/// What a Backspace press does.
pub const Backspace = enum { type, go_back, swallow };

/// What a Backspace press does: delete text (`type`), go back a view, or
/// nothing. Never leaves `.root` or `.dmenu`, and from a physical keyboard
/// (`from_keyboard = true`) ignores held repeats until Backspace is released
/// and pressed again on an empty bar. Going back sets no guard itself: the
/// new view clears it, so the caller sets `.went_back` once there.
pub fn backspaceAction(
    view: Ui.View,
    query_empty: bool,
    guard: *BackspaceGuard,
    from_keyboard: bool,
) Backspace {
    if (from_keyboard and guard.* == .went_back) return .swallow;
    if (view == .root or view == .dmenu) return .type;
    if (!query_empty) {
        if (from_keyboard) guard.* = .held;
        return .type;
    }
    if (from_keyboard and guard.* == .held) return .type;
    return .go_back;
}

/// The chords a text field uses on its selection: cut, copy, paste over,
/// select all, undo and redo.
fn isSelectionChord(key: KeyPress) bool {
    if (!key.ctrl) return false;
    return switch (key.keyval) {
        c.GDK_KEY_x, c.GDK_KEY_c, c.GDK_KEY_v, c.GDK_KEY_a => !key.shift,
        c.GDK_KEY_z => true,
        else => false,
    };
}

/// True when `key` is for the text selected in the focused search bar, not
/// for the selected row's shortcuts.
fn editsSelection(ui: *Ui, key: KeyPress) bool {
    if (!isSelectionChord(key)) return false;
    const entry = ui.search_bar.entry;
    if (c.gtk_widget_has_focus(gtk.widget(entry)) == 0) return false;
    var start: c_int = 0;
    var end: c_int = 0;
    return c.gtk_editable_get_selection_bounds(gtk.editable(entry), &start, &end) != 0;
}

/// Keyvals from here up to `unicode_keyval_min` name keys, not characters
/// (arrows, Enter, modifiers, function keys); from there up they are
/// Unicode characters (0x01000000 plus the code point).
const key_keyval_min = 0xfe00;
const unicode_keyval_min = 0x01000000;
/// Layouts (xkb groups) a keymap holds at most.
const layout_groups_max = 4;

/// With Ctrl (or Super) held on a layout without Latin letters (Russian,
/// Greek), the Latin letter the same key types in another layout: Ctrl+K
/// there is Cyrillic_el, and Ctrl+K, Ctrl+N and the row and init.lua
/// shortcuts did nothing (MYP-562). `keyval` otherwise.
pub fn shortcutKeyval(keyval: c_uint, keycode: c_uint, state: c.GdkModifierType) c_uint {
    if (state & (c.GDK_CONTROL_MASK | c.GDK_SUPER_MASK) == 0) return keyval;
    return latinKeyval(keyval, keycode, state);
}

/// `keyval`, or when it is a letter of a non-Latin layout, the ASCII letter
/// its key (`keycode`) has in the first layout that has one.
pub fn latinKeyval(keyval: c_uint, keycode: c_uint, state: c.GdkModifierType) c_uint {
    if (!isNonLatinCharacter(c.gdk_keyval_to_lower(keyval))) return keyval;
    const display = c.gdk_display_get_default() orelse return keyval;
    for (0..layout_groups_max) |group| {
        var translated: c_uint = 0;
        const known = c.gdk_display_translate_key(
            display,
            keycode,
            state,
            @intCast(group),
            &translated,
            null,
            null,
            null,
        ) != 0;
        const letter = translated < 0x80 and std.ascii.isAlphabetic(@intCast(translated));
        if (known and letter) return translated;
    }
    return keyval;
}

/// A character past Latin-1: a letter of Cyrillic, Greek, Hebrew, Arabic and
/// the like. Latin layouts' own letters (ñ, ö, é) are kept as they are.
fn isNonLatinCharacter(keyval: c_uint) bool {
    const latin1_max = 0xff;
    if (keyval <= latin1_max) return false;
    return keyval < key_keyval_min or keyval >= unicode_keyval_min;
}

/// A printable key with Alt alone (no Ctrl or Super) types its character,
/// which GTK's text field would drop: a split keyboard's thumb key held a
/// little long sends Right Alt instead of a space, and the digits typed
/// before it is let go were lost ("10 * 10" became "10 * ").
fn typeAltChord(ui: *Ui, keyval: c_uint, state: c.GdkModifierType) bool {
    if (state & c.GDK_ALT_MASK == 0) return false;
    if (state & (c.GDK_CONTROL_MASK | c.GDK_SUPER_MASK) != 0) return false;
    const code_point = c.gdk_keyval_to_unicode(keyval);
    const printable = code_point >= ' ' and code_point != 0x7f;
    if (!printable) return false;
    // Only into the search field: a form's own fields get keys as GTK gives them.
    if (c.gtk_widget_has_focus(gtk.widget(ui.search_bar.entry)) == 0) return false;
    var utf8_bytes: [4]u8 = undefined;
    const scalar = std.math.cast(u21, code_point) orelse return false;
    const length = std.unicode.utf8Encode(scalar, &utf8_bytes) catch return false;
    const field = gtk.editable(ui.search_bar.entry);
    var position = c.gtk_editable_get_position(field);
    c.gtk_editable_insert_text(field, &utf8_bytes, @intCast(length), &position);
    c.gtk_editable_set_position(field, position);
    return true;
}

/// `lumen --key NAME`: the same handling as a real key press, for tests.
/// Names: down, up, enter, ctrl+enter, ctrl+k, escape, backspace, pagedown,
/// pageup, ctrl+x, ctrl+o, left, right, and any keymap ("ctrl+g").
pub fn injectKey(ui: *Ui, name: []const u8) bool {
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
        _ = handleKey(ui, key[1], key[2]);
        return true;
    };
    // Anything else written like a keymap ("ctrl+g").
    const parsed = Ui.ext_view.parseKey(name) orelse return false;
    _ = handleKey(ui, parsed.keyval, parsed.modifiers);
    return true;
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
        const lower = c.gdk_keyval_to_lower(keypadAsMain(keyval));
        const ctrl = state & c.GDK_CONTROL_MASK != 0;
        const down = lower == c.GDK_KEY_Down or
            (ctrl and (lower == c.GDK_KEY_n or lower == c.GDK_KEY_j));
        const up = lower == c.GDK_KEY_Up or
            (ctrl and (lower == c.GDK_KEY_p or lower == c.GDK_KEY_k and context.panel_open));
        // No key is both: a chord names one letter.
        assert(!(down and up));
        return .{
            .keyval = lower,
            .ctrl = ctrl,
            .shift = state & c.GDK_SHIFT_MASK != 0,
            .vertical = if (down) .down else if (up) .up else null,
            .enter = lower == c.GDK_KEY_Return or lower == c.GDK_KEY_KP_Enter,
        };
    }

    /// The keypad's arrows and page keys (NumLock off) as the main ones:
    /// they moved nothing, while its Enter worked (MYP-595).
    fn keypadAsMain(keyval: c_uint) c_uint {
        return switch (keyval) {
            c.GDK_KEY_KP_Up => c.GDK_KEY_Up,
            c.GDK_KEY_KP_Down => c.GDK_KEY_Down,
            c.GDK_KEY_KP_Left => c.GDK_KEY_Left,
            c.GDK_KEY_KP_Right => c.GDK_KEY_Right,
            c.GDK_KEY_KP_Page_Up => c.GDK_KEY_Page_Up,
            c.GDK_KEY_KP_Page_Down => c.GDK_KEY_Page_Down,
            else => keyval,
        };
    }

    /// -1 for up, +1 for down: how `row_list.nextSelectable` steps.
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
    assert(ui.panel.isOpen());
    assert(ui.panel.entries.len > 0);
    assert(ui.panel.selected < ui.panel.entries.len);
    // Ctrl+K inside the panel moves up (`decode`); Escape closes it.
    if (key.keyval == c.GDK_KEY_Escape) {
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
    // A dmenu caller is waiting: Esc answers "nothing" and hides, filter
    // typed or not, as dmenu and rofi do (MYP-487).
    if (ui.view == .dmenu) {
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
        if (next >= 0 and next < cell_count) row_list.select(ui, @intCast(next));
        return true;
    }
    if (key.vertical) |vertical| {
        row_list.select(ui, row_list.nextSelectable(ui, ui.selected, KeyPress.step(vertical)));
        return true;
    }
    if (key.keyval == c.GDK_KEY_Page_Down or key.keyval == c.GDK_KEY_Page_Up) {
        const direction: i32 = if (key.keyval == c.GDK_KEY_Page_Down) 1 else -1;
        var target = ui.selected;
        for (0..page_rows) |_| target = row_list.nextSelectable(ui, target, direction);
        row_list.select(ui, target);
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

/// True when `keyval` is a modifier or lock key alone (Shift, Ctrl, Alt,
/// Super, Hyper, ISO level/group shifts, Mode_switch, Num_Lock): pressing
/// the hotkey's modifier to close Lumen must not count as recent typing.
pub fn isModifierKey(keyval: c_uint) bool {
    return switch (keyval) {
        c.GDK_KEY_Shift_L...c.GDK_KEY_Hyper_R,
        c.GDK_KEY_ISO_Lock...c.GDK_KEY_ISO_Group_Lock,
        c.GDK_KEY_ISO_Level5_Shift...c.GDK_KEY_ISO_Level5_Lock,
        c.GDK_KEY_Mode_switch,
        c.GDK_KEY_Num_Lock,
        => true,
        else => false,
    };
}

test "modifier keys are excluded from recent typing while normal keys count" {
    const modifiers = [_]c_uint{
        c.GDK_KEY_Shift_L,
        c.GDK_KEY_Control_L,
        c.GDK_KEY_Alt_L,
        c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L,
        c.GDK_KEY_Hyper_R,
        c.GDK_KEY_ISO_Level3_Shift,
        c.GDK_KEY_ISO_Level5_Shift,
        c.GDK_KEY_Mode_switch,
        c.GDK_KEY_Num_Lock,
    };
    for (modifiers) |keyval| try std.testing.expect(isModifierKey(keyval));

    const keys = [_]c_uint{
        'a',
        ' ',
        c.GDK_KEY_Return,
        c.GDK_KEY_Escape,
        c.GDK_KEY_BackSpace,
        c.GDK_KEY_Down,
    };
    for (keys) |keyval| try std.testing.expect(!isModifierKey(keyval));
}

test "held backspace never exits a view or aborts dmenu" {
    var guard: BackspaceGuard = .free;
    // Holding Backspace while deleting text sets the guard, then hitting empty still refuses exit.
    try std.testing.expectEqual(Backspace.type, backspaceAction(.settings, false, &guard, true));
    try std.testing.expectEqual(BackspaceGuard.held, guard);
    try std.testing.expectEqual(Backspace.type, backspaceAction(.settings, true, &guard, true));
    // Releasing Backspace clears the guard; pressing again on empty navigates back once.
    guard = .free;
    try std.testing.expectEqual(Backspace.go_back, backspaceAction(.settings, true, &guard, true));
    // dmenu and root never navigate back on Backspace.
    guard = .free;
    try std.testing.expectEqual(Backspace.type, backspaceAction(.dmenu, true, &guard, true));
    try std.testing.expectEqual(Backspace.type, backspaceAction(.dmenu, true, &guard, false));
    try std.testing.expectEqual(Backspace.type, backspaceAction(.root, true, &guard, false));
    // Synthetic `--key backspace` continues to navigate back on non-dmenu subviews.
    try std.testing.expectEqual(Backspace.go_back, backspaceAction(.settings, true, &guard, false));
}

test "held backspace goes back once, and leaves the query gone back to (MYP-535)" {
    // Gone back (handleKeyEvent sets `went_back` once the view changed).
    var guard: BackspaceGuard = .went_back;
    // Repeats on an empty view do not go back again...
    try std.testing.expectEqual(Backspace.swallow, backspaceAction(.default_apps, true, &guard, true));
    try std.testing.expectEqual(Backspace.swallow, backspaceAction(.settings, true, &guard, true));
    // ...nor delete the query restored ("report" in Files).
    try std.testing.expectEqual(Backspace.swallow, backspaceAction(.files, false, &guard, true));
    try std.testing.expectEqual(BackspaceGuard.went_back, guard);
    // Released, a press deletes the restored query again.
    guard = .free;
    try std.testing.expectEqual(Backspace.type, backspaceAction(.files, false, &guard, true));
}

test "the keypad's arrows and page keys move like the main ones (MYP-595)" {
    try std.testing.expectEqual(@as(?KeyPress.Vertical, .down), KeyPress.decode(c.GDK_KEY_KP_Down, 0, .{ .panel_open = false }).vertical);
    try std.testing.expectEqual(@as(?KeyPress.Vertical, .up), KeyPress.decode(c.GDK_KEY_KP_Up, 0, .{ .panel_open = false }).vertical);
    try std.testing.expectEqual(c.GDK_KEY_Left, KeyPress.decode(c.GDK_KEY_KP_Left, 0, .{ .panel_open = false }).keyval);
    try std.testing.expectEqual(c.GDK_KEY_Right, KeyPress.decode(c.GDK_KEY_KP_Right, 0, .{ .panel_open = false }).keyval);
    try std.testing.expectEqual(c.GDK_KEY_Page_Up, KeyPress.decode(c.GDK_KEY_KP_Page_Up, 0, .{ .panel_open = false }).keyval);
    try std.testing.expectEqual(c.GDK_KEY_Page_Down, KeyPress.decode(c.GDK_KEY_KP_Page_Down, 0, .{ .panel_open = false }).keyval);
    try std.testing.expect(KeyPress.decode(c.GDK_KEY_KP_Enter, 0, .{ .panel_open = false }).enter);
}

test "a text field's chords on a selection are left to the search bar (MYP-567)" {
    const ctrl = c.GDK_CONTROL_MASK;
    const shift = c.GDK_SHIFT_MASK;
    try std.testing.expect(isSelectionChord(.decode(c.GDK_KEY_x, ctrl, .{ .panel_open = false })));
    try std.testing.expect(isSelectionChord(.decode('X', ctrl, .{ .panel_open = false })));
    try std.testing.expect(isSelectionChord(.decode(c.GDK_KEY_c, ctrl, .{ .panel_open = false })));
    try std.testing.expect(isSelectionChord(.decode(c.GDK_KEY_z, ctrl | shift, .{ .panel_open = false })));
    // The row's own chords: Delete All Entries, Copy Path, Open With.
    try std.testing.expect(!isSelectionChord(.decode('X', ctrl | shift, .{ .panel_open = false })));
    try std.testing.expect(!isSelectionChord(.decode('C', ctrl | shift, .{ .panel_open = false })));
    try std.testing.expect(!isSelectionChord(.decode(c.GDK_KEY_o, ctrl, .{ .panel_open = false })));
    try std.testing.expect(!isSelectionChord(.decode(c.GDK_KEY_x, 0, .{ .panel_open = false })));
}

test "only letters of non-Latin layouts are looked up in another layout (MYP-562)" {
    const cyrillic_el = 0x6cc;
    const greek_kappa = 0x7ea;
    const armenian_ke = unicode_keyval_min + 0x584;
    try std.testing.expect(isNonLatinCharacter(cyrillic_el));
    try std.testing.expect(isNonLatinCharacter(greek_kappa));
    try std.testing.expect(isNonLatinCharacter(armenian_ke));
    try std.testing.expect(!isNonLatinCharacter(c.GDK_KEY_k));
    try std.testing.expect(!isNonLatinCharacter(0xf1)); // ñ
    try std.testing.expect(!isNonLatinCharacter(c.GDK_KEY_Return));
    try std.testing.expect(!isNonLatinCharacter(c.GDK_KEY_Escape));
    // Without Ctrl or Super, keys are typed as they are.
    try std.testing.expectEqual(@as(c_uint, cyrillic_el), shortcutKeyval(cyrillic_el, 45, 0));
}

test "KeyPress.decode handles uppercase Ctrl letters when Caps Lock is active" {
    const ctrl_n = KeyPress.decode('N', c.GDK_CONTROL_MASK, .{ .panel_open = false });
    try std.testing.expectEqual(@as(?KeyPress.Vertical, .down), ctrl_n.vertical);

    const ctrl_j = KeyPress.decode('J', c.GDK_CONTROL_MASK, .{ .panel_open = false });
    try std.testing.expectEqual(@as(?KeyPress.Vertical, .down), ctrl_j.vertical);

    const ctrl_p = KeyPress.decode('P', c.GDK_CONTROL_MASK, .{ .panel_open = false });
    try std.testing.expectEqual(@as(?KeyPress.Vertical, .up), ctrl_p.vertical);

    const ctrl_k_closed = KeyPress.decode('K', c.GDK_CONTROL_MASK, .{ .panel_open = false });
    try std.testing.expectEqual(@as(c_uint, c.GDK_KEY_k), ctrl_k_closed.keyval);
    try std.testing.expectEqual(@as(?KeyPress.Vertical, null), ctrl_k_closed.vertical);

    const ctrl_k_open = KeyPress.decode('K', c.GDK_CONTROL_MASK, .{ .panel_open = true });
    try std.testing.expectEqual(@as(?KeyPress.Vertical, .up), ctrl_k_open.vertical);
}
