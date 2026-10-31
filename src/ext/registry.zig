//! What the extension files define, as the window receives it after a
//! reload: commands, keymaps, preferences, themes, setting overrides, the
//! layout, and the problems found on the way. Built by Host's worker in
//! the registry's arena; the window owns it once delivered.

const std = @import("std");
const item_mod = @import("../item.zig");
const themes = @import("../ui/themes.zig");
const layout_mod = @import("../layout.zig");

/// Cells to a line in a grid command that does not say.
pub const grid_columns_default = 5;

/// The extension id init.lua runs as.
pub const config_extension_id = "config";
/// The extension id the chosen style's file runs as.
pub const style_extension_id = "style";

/// A toggle's value as text, as preferences.json, form values and
/// `Pref.default` hold it.
pub fn toggleText(on: bool) [:0]const u8 {
    return if (on) "true" else "false";
}

/// Whether a toggle's text value is on; anything but `toggleText(true)` is
/// off.
pub fn toggleIsOn(text: []const u8) bool {
    return std.mem.eql(u8, text, toggleText(true));
}

pub const Mode = enum {
    /// `items`: listed once when the command opens, filtered by Lumen.
    list,
    /// `search`: asked again for every query.
    search,
    /// `run`: no list; Enter runs it.
    run,
    /// Only `root`: rows in the root search, not a command of its own.
    provider,
    /// `fields` and `submit`: a form.
    form,
};

pub const Command = struct {
    /// "<extension>.<name>"; what keymaps and `lumen --command` name.
    id: [:0]const u8,
    title: [:0]const u8,
    subtitle: [:0]const u8,
    icon: item_mod.Icon,
    keywords: []const u8,
    placeholder: [:0]const u8,
    mode: Mode,
    /// Show the detail pane (the selected row's `detail`).
    detail: bool,
    /// It answers root searches too (`root = function(query)`).
    root: bool,
    /// A form's fields, in order (preferences' types).
    fields: []const Pref = &.{},
    /// The form's last row ("Submit").
    submit_title: [:0]const u8 = "Submit",
    /// Rows as a grid of cells (`grid = true`), this many to a line.
    grid: bool = false,
    columns: u8 = grid_columns_default,
};

pub const Keymap = struct {
    /// As written: "ctrl+g", "alt+shift+p".
    keys: [:0]const u8,
    /// Parsed: the key (lower case) and the modifiers.
    keyval: c_uint,
    mods: c_uint,
    /// A command id, or a built-in view name ("clipboard").
    target: [:0]const u8,
    /// Where it was defined, for error messages.
    ext: [:0]const u8,
};

pub const PrefKind = enum { toggle, choice, text, password };

/// A preference an extension declares; Settings edits it, Lua reads it as
/// `lumen.preferences.<name>`.
pub const Pref = struct {
    /// The extension's id and title.
    ext: [:0]const u8,
    ext_title: [:0]const u8,
    /// Where Settings writes the values: <data>/preferences.json.
    file: [:0]const u8,
    name: [:0]const u8,
    title: [:0]const u8,
    description: [:0]const u8,
    kind: PrefKind,
    /// As JSON would spell it for a toggle ("true"), else the text.
    default: [:0]const u8,
    choices: []const PrefChoice = &.{},
    /// Form fields: submitting needs a value.
    required: bool = false,
};

pub const PrefChoice = struct { value: [:0]const u8, label: [:0]const u8 };

/// `lumen.icons { ["cmd:clipboard"] = "📋" }`: an item's icon replaced.
pub const IconOverride = struct { key: [:0]const u8, icon: item_mod.Icon };

/// `lumen.set { width = "wide" }`: a setting init.lua fixes.
pub const SettingOverride = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

/// An extension that loaded, for Settings > Extensions.
pub const ExtInfo = struct { id: [:0]const u8, title: [:0]const u8, commands: u16 };

/// A file that did not load, or loaded only in part, and why.
pub const Problem = struct {
    ext: [:0]const u8,
    message: [:0]const u8,
};

/// Everything the files define. Owned by the receiver: `destroy`.
pub const Registry = struct {
    gen: u32,
    commands: []const Command = &.{},
    themes: []const themes.Theme = &.{},
    keymaps: []const Keymap = &.{},
    settings: []const SettingOverride = &.{},
    prefs: []const Pref = &.{},
    icons: []const IconOverride = &.{},
    /// The extensions that loaded (init.lua not included).
    extensions: []const ExtInfo = &.{},
    /// lumen.set in the style: defaults the UI applies when the style is
    /// chosen (unlike init.lua's, they fix nothing).
    style_settings: []const SettingOverride = &.{},
    /// `lumen.layout { ... }`: the window's structure.
    layout: layout_mod.Layout = .{},
    /// Whether any file called lumen.layout (its size and place then win
    /// over Settings).
    has_layout: bool = false,
    problems: []const Problem = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn destroy(registry: *Registry, gpa: std.mem.Allocator) void {
        registry.arena.deinit();
        gpa.destroy(registry);
    }
};
