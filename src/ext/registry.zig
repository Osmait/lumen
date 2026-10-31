//! What the extension files define, as the window receives it after a
//! reload: commands, keymaps, preferences, themes, setting overrides, the
//! layout, and the problems found on the way. Built by Host's worker in
//! the registry's arena; the window owns it once delivered.

const std = @import("std");
const item_mod = @import("../item.zig");
const themes = @import("../ui/themes.zig");
const layout_mod = @import("../layout.zig");
const RegistryGeneration = @import("generation.zig").RegistryGeneration;
const indexes = @import("indexes.zig");
pub const CommandIndex = indexes.CommandIndex;
pub const PreferenceIndex = indexes.PreferenceIndex;
pub const FieldIndex = indexes.FieldIndex;

/// Cells to a line in a grid command that does not say.
pub const grid_columns_default = 5;

/// The extension id init.lua runs as.
pub const config_extension_id = "config";
/// The extension id the chosen style's file runs as.
pub const style_extension_id = "style";

/// A toggle's value as text, as preferences.json, form values and
/// `Preference.default` hold it.
pub fn toggleText(is_on: bool) [:0]const u8 {
    return if (is_on) "true" else "false";
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
    answers_root_search: bool,
    /// A form's fields, in order (preferences' types).
    fields: []const Preference = &.{},
    /// The form's last row ("Submit").
    submit_title: [:0]const u8 = "Submit",
    /// Rows as a grid of cells (`grid = true`), this many to a line.
    grid: bool = false,
    columns: u8 = grid_columns_default,

    /// Field `index` of the form, or null when it has no such field.
    pub fn field(command: *const Command, index: FieldIndex) ?*const Preference {
        return index.in(Preference, command.fields);
    }
};

pub const Keymap = struct {
    /// As written: "ctrl+g", "alt+shift+p".
    keys: [:0]const u8,
    /// Parsed: the key (lower case) and the modifiers.
    keyval: c_uint,
    modifiers: c_uint,
    /// A command id, or a built-in view name ("clipboard").
    target: [:0]const u8,
    /// Where it was defined, for error messages.
    extension: [:0]const u8,
};

pub const PreferenceKind = enum { toggle, choice, text, password };

/// A preference an extension declares; Settings edits it, Lua reads it as
/// `lumen.preferences.<name>`.
pub const Preference = struct {
    /// The extension's id and title.
    extension: [:0]const u8,
    extension_title: [:0]const u8,
    /// Where Settings writes the values: <data>/preferences.json.
    file: [:0]const u8,
    name: [:0]const u8,
    title: [:0]const u8,
    description: [:0]const u8,
    kind: PreferenceKind,
    /// As JSON would spell it for a toggle ("true"), else the text.
    default: [:0]const u8,
    choices: []const PreferenceChoice = &.{},
    /// Form fields: submitting needs a value.
    required: bool = false,
};

pub const PreferenceChoice = struct { value: [:0]const u8, label: [:0]const u8 };

/// `lumen.icons { ["cmd:clipboard"] = "📋" }`: an item's icon replaced.
pub const IconOverride = struct { key: [:0]const u8, icon: item_mod.Icon };

/// `lumen.set { width = "wide" }`: a setting init.lua fixes.
pub const SettingOverride = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

/// An extension that loaded, for Settings > Extensions.
pub const ExtensionInfo = struct { id: [:0]const u8, title: [:0]const u8, commands: u16 };

/// A file that did not load, or loaded only in part, and why.
pub const Problem = struct {
    extension: [:0]const u8,
    message: [:0]const u8,
};

/// Everything the files define. Owned by the receiver: `destroy`.
pub const Registry = struct {
    generation: RegistryGeneration,
    commands: []const Command = &.{},
    themes: []const themes.Theme = &.{},
    keymaps: []const Keymap = &.{},
    settings: []const SettingOverride = &.{},
    preferences: []const Preference = &.{},
    icons: []const IconOverride = &.{},
    /// The extensions that loaded (init.lua not included).
    extensions: []const ExtensionInfo = &.{},
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

    /// Command `index`, or null when this registry has no such command.
    pub fn command(registry: *const Registry, index: CommandIndex) ?*const Command {
        return index.in(Command, registry.commands);
    }

    /// Preference `index`, or null when this registry has no such one.
    pub fn preference(registry: *const Registry, index: PreferenceIndex) ?*const Preference {
        return index.in(Preference, registry.preferences);
    }
};
