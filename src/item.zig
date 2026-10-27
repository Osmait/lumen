//! What a row in the list is, and what can be done with it.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const settings = @import("settings.zig");

pub const Color = enum { red, orange, yellow, green, blue, purple, pink, gray };

pub const Icon = union(enum) {
    /// An icon given by name: "*-symbolic" on a grey tile, anything else in
    /// full colour. `name` must outlive the icon.
    pub fn byName(name: [:0]const u8) Icon {
        return if (std.mem.endsWith(u8, name, "-symbolic")) .{ .tile = .{ .name = name, .color = .gray } } else .{ .named = name };
    }

    none,
    /// App icon from its .desktop file.
    gicon: *c.GIcon,
    /// Symbolic icon on a coloured tile (built-in commands).
    tile: struct { name: [:0]const u8, color: Color },
    /// A full-colour icon from the icon theme ("firefox"), at full size.
    named: [:0]const u8,
    emoji: [:0]const u8,
    /// File extension on a coloured tile ("GO", "ZIG").
    badge: struct { text: [:0]const u8, color: core.file_badge.Color },
    /// A language's official logo (`ui/logos.zig`).
    logo: core.file_badge.Logo,
    /// A theme's colours, as a small preview tile.
    swatch: struct { id: []const u8, bg: u24, fg: u24, accent: u24 },
};

/// `ext`: the list of an extension command (which one is in the UI).
/// `dmenu`: lines from `lumen --dmenu`. `prefs`: an extension's preferences;
/// `input`: typing a preference's value.
pub const View = enum { root, clipboard, windows, files, contents, settings, themes, default_apps, choose, ext, dmenu, prefs, input };

pub const System = enum {
    lock,
    sleep,
    restart,
    shutdown,
    logout,
    volume_up,
    volume_down,
    volume_mute,
    mic_mute,
    play_pause,
    next_track,
    prev_track,
    toggle_dark,
    empty_trash,
};

pub const WindowOp = enum { toggle_floating, toggle_fullscreen, toggle_maximize, pin, close, next_workspace, prev_workspace, move_next_monitor };

pub const Action = union(enum) {
    app: *c.GAppInfo,
    view: View,
    system: System,
    layout: core.geometry.Layout,
    window_op: WindowOp,
    /// Hyprland window address.
    focus_window: [:0]const u8,
    /// Row id in the clipboard table; the text is in `Item.detail`.
    clip: i64,
    script: struct { path: [:0]const u8, mode: core.script_meta.Mode },
    /// Calculator result; `Item.detail` holds the plain value to copy.
    calc,
    setting: Setting,
    /// A file or directory from the index.
    file: struct {
        path: [:0]const u8,
        is_dir: bool,
        /// Line of a content match (0: not from a content search).
        line: u32 = 0,
        /// The match is in text extracted from a PDF/Office document.
        extracted: bool = false,
    },
    /// An extension command (its index in the extension registry): opens
    /// its list, or runs it when it has no list.
    ext_command: struct { index: u16, run: bool },
    /// A row listed by an extension command.
    ext_item: ExtItem,
    /// An extension that failed to load; `Item.detail` holds the error.
    ext_problem,
    /// A line given to `lumen --dmenu` (its index).
    pick: struct { index: u32, selectable: bool },
};

pub const ExtItem = struct {
    /// The list result it came from: its Lua actions run against that one.
    gen: u32,
    /// Position in the list the extension returned.
    index: u32,
    actions: []const ExtAction,
    /// Labels and keys of `actions`, in the same order.
    entries: []const Entry,
};

/// What an extension row's action does. All but `lua` run in the UI
/// without a trip to the extension thread.
pub const ExtAction = union(enum) {
    /// A Lua function, run on the extension thread.
    lua,
    /// A URL, or a path (with the Default Apps from Settings).
    open: [:0]const u8,
    copy: []const u8,
    paste: []const u8,
    exec: []const [:0]const u8,
};

/// Rows of the Settings views.
pub const Setting = union(enum) {
    toggle: settings.Toggle,
    /// Opens the list of values for a setting.
    choose: settings.Choice,
    /// Opens the list of apps for a file kind.
    kind: core.file_kind.Kind,
    /// A value in that list ("large", a desktop file id; "" is automatic).
    pick: [:0]const u8,
    theme: []const u8,
    /// Opens another settings list (themes, default apps).
    go: View,
    /// Open With: open the file being chosen for with this app (desktop id).
    open_with: [:0]const u8,
    open_file,
    reset,
    /// Opens an extension's preferences (its id).
    ext_prefs: [:0]const u8,
    /// Changes one preference (its index in the extension registry).
    pref: u16,
    /// Saves what was typed in the input view.
    save_input,
};

pub const Item = struct {
    /// Frecency key ("app:firefox.desktop"); empty when not tracked.
    key: []const u8 = "",
    title: [:0]const u8,
    subtitle: [:0]const u8 = "",
    accessory: [:0]const u8 = "",
    icon: Icon = .none,
    /// Extra words the search matches on.
    keywords: []const u8 = "",
    action: Action,
    /// Destructive: needs a second Enter.
    confirm: bool = false,
    /// Full text for the detail pane / the value to copy.
    detail: []const u8 = "",
    /// Shown only in the detail pane: the folder, and a short fact (e.g.
    /// "line 58 · 10 matches"), when the list row has no room for them.
    where: [:0]const u8 = "",
    fact: [:0]const u8 = "",
    /// Section header above the row in lists grouped by section.
    section: [:0]const u8 = "",
    score: i32 = 0,
};

pub const Op = enum {
    open,
    run,
    copy_name,
    copy_path,
    reset_ranking,
    focus,
    close_window,
    clip_paste,
    clip_copy,
    clip_delete,
    clip_clear,
    calc_copy,
    calc_paste,
    show_in_folder,
    copy_file,
    trash,
    open_at_line,
    open_with,
    always_use,
    copy_detail,
    /// An extension action: `Entry.index` says which.
    ext,
    /// `lumen --dmenu`: answer with the text typed instead of a line.
    pick_typed,
};

pub const Entry = struct {
    label: [:0]const u8,
    /// Shown as key caps, e.g. "↵", "Ctrl ↵", "Ctrl X".
    keys: [:0]const u8,
    op: Op,
    /// For `Op.ext`: which of the row's actions.
    index: u8 = 0,
};

/// Actions for the action panel (Ctrl+K). The first is Enter, the second
/// Ctrl+Enter.
pub fn actionsFor(item: *const Item) []const Entry {
    return switch (item.action) {
        .app => &.{
            .{ .label = "Open Application", .keys = "↵", .op = .open },
            .{ .label = "Copy Name", .keys = "Ctrl ↵", .op = .copy_name },
            .{ .label = "Copy Desktop File Path", .keys = "Ctrl Shift C", .op = .copy_path },
            .{ .label = "Reset Ranking", .keys = "", .op = .reset_ranking },
        },
        .view => &.{
            .{ .label = "Open Command", .keys = "↵", .op = .open },
            .{ .label = "Reset Ranking", .keys = "", .op = .reset_ranking },
        },
        .system, .layout, .window_op, .script => &.{
            .{ .label = "Run Command", .keys = "↵", .op = .run },
            .{ .label = "Reset Ranking", .keys = "", .op = .reset_ranking },
        },
        .focus_window => &.{
            .{ .label = "Switch to Window", .keys = "↵", .op = .focus },
            .{ .label = "Close Window", .keys = "Ctrl ↵", .op = .close_window },
        },
        .clip => &.{
            .{ .label = "Paste to Active App", .keys = "↵", .op = .clip_paste },
            .{ .label = "Copy to Clipboard", .keys = "Ctrl ↵", .op = .clip_copy },
            .{ .label = "Delete Entry", .keys = "Ctrl X", .op = .clip_delete },
            .{ .label = "Delete All Entries", .keys = "Ctrl Shift X", .op = .clip_clear },
        },
        .file => |f| if (f.line > 0 and !f.extracted) &.{
            .{ .label = "Open at Line", .keys = "↵", .op = .open_at_line },
            .{ .label = "Open", .keys = "Ctrl ↵", .op = .open },
            .{ .label = "Open With...", .keys = "Ctrl O", .op = .open_with },
            .{ .label = "Show in Folder", .keys = "", .op = .show_in_folder },
            .{ .label = "Copy Path", .keys = "Ctrl Shift C", .op = .copy_path },
            .{ .label = "Copy File", .keys = "Ctrl Shift F", .op = .copy_file },
        } else &.{
            .{ .label = "Open", .keys = "↵", .op = .open },
            .{ .label = "Show in Folder", .keys = "Ctrl ↵", .op = .show_in_folder },
            .{ .label = "Open With...", .keys = "Ctrl O", .op = .open_with },
            .{ .label = "Copy Path", .keys = "Ctrl Shift C", .op = .copy_path },
            .{ .label = "Copy File", .keys = "Ctrl Shift F", .op = .copy_file },
            .{ .label = "Move to Trash", .keys = "Ctrl X", .op = .trash },
        },
        .setting => |s| switch (s) {
            .toggle => &.{.{ .label = "Toggle", .keys = "↵", .op = .run }},
            .choose, .kind, .go => &.{.{ .label = "Change", .keys = "↵", .op = .run }},
            .pick => &.{.{ .label = "Select", .keys = "↵", .op = .run }},
            .theme => &.{.{ .label = "Use Theme", .keys = "↵", .op = .run }},
            .open_with => &.{
                .{ .label = "Open", .keys = "↵", .op = .run },
                .{ .label = "Open and Always Use", .keys = "Ctrl ↵", .op = .always_use },
            },
            .open_file => &.{.{ .label = "Open Settings File", .keys = "↵", .op = .run }},
            .reset => &.{.{ .label = "Reset All Settings", .keys = "↵", .op = .run }},
            .ext_prefs, .pref => &.{.{ .label = "Change", .keys = "↵", .op = .run }},
            .save_input => &.{.{ .label = "Save", .keys = "↵", .op = .run }},
        },
        .calc => &.{
            .{ .label = "Copy Answer", .keys = "↵", .op = .calc_copy },
            .{ .label = "Paste Answer", .keys = "Ctrl ↵", .op = .calc_paste },
        },
        .ext_command => |x| if (x.run) &.{
            .{ .label = "Run Command", .keys = "↵", .op = .run },
            .{ .label = "Reset Ranking", .keys = "", .op = .reset_ranking },
        } else &.{
            .{ .label = "Open Command", .keys = "↵", .op = .open },
            .{ .label = "Reset Ranking", .keys = "", .op = .reset_ranking },
        },
        .ext_item => |x| x.entries,
        .ext_problem => &.{.{ .label = "Copy Error", .keys = "↵", .op = .copy_detail }},
        .pick => |p| if (p.selectable) &.{
            .{ .label = "Select", .keys = "↵", .op = .run },
            .{ .label = "Use Typed Text", .keys = "Ctrl ↵", .op = .pick_typed },
        } else &.{
            .{ .label = "Use Typed Text", .keys = "Ctrl ↵", .op = .pick_typed },
        },
    };
}
