//! The Settings, Change Theme and Default Apps views: their rows and what
//! picking one does (`performSetting`). A row with values to pick from
//! opens the choose view (choose_view.zig).

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const run = @import("../actions.zig");
const os = @import("os");
const styles = @import("styles");
const settings_mod = @import("../settings.zig");
const ext_view = @import("ext_view.zig");
const Settings = settings_mod.Settings;
const themes = @import("themes.zig");
const Kind = core.file_kind.Kind;
const config = @import("config.zig");
const Ui = @import("Ui.zig");
const prefs_view = @import("prefs_view.zig");
const form_view = @import("form_view.zig");
const choose_view = @import("choose_view.zig");

const log = std.log.scoped(.ui);
const labels = @import("labels.zig");

/// The item key of the Settings row for setting `name`.
pub fn settingKey(arena: std.mem.Allocator, name: []const u8) []const u8 {
    return arena.print("set:{s}", .{name}) catch "";
}

/// Where a settings row's value and action come from.
const RowSource = union(enum) {
    theme,
    default_apps,
    choice: settings_mod.Choice,
    toggle: settings_mod.Toggle,
};

/// A row: title, icon, source, and extra words it is found by.
const RowSpec = struct { [:0]const u8, [:0]const u8, RowSource, []const u8 };

/// The Settings view, section by section; a section's rows share a color.
const setting_rows = [_]struct { [:0]const u8, item_mod.Color, []const RowSpec }{
    .{ "Appearance", .purple, &.{
        .{ "Theme", "applications-graphics-symbolic", .theme, "color dark light appearance" },
        .{ "Text Size", "preferences-desktop-font-symbolic", .{ .choice = .text_size }, "font scale zoom bigger smaller" },
        .{ "Window Opacity", "display-brightness-symbolic", .{ .choice = .opacity }, "transparency translucent background" },
        .{ "Window Position", "preferences-desktop-display-symbolic", .{ .choice = .position }, "center top place" },
        .{ "Icon Theme", "preferences-desktop-icons-symbolic", .{ .choice = .icon_theme }, "icons pack papirus adwaita" },
    } },
    .{ "Layout", .green, &.{
        .{ "Window Width", "view-dual-symbolic", .{ .choice = .width }, "size wide narrow layout" },
        .{ "Window Height", "view-list-symbolic", .{ .choice = .height }, "size tall short rows results layout" },
        .{ "Density", "view-grid-symbolic", .{ .choice = .density }, "compact comfortable spacing icons rows layout" },
    } },
    .{ "Search", .orange, &.{
        .{ "Show Files in Main Search", "folder-saved-search-symbolic", .{ .toggle = .files_in_root }, "results" },
        .{ "Show Suggestions", "starred-symbolic", .{ .toggle = .suggestions }, "frecency recent most used" },
    } },
    .{ "Clipboard", .red, &.{
        .{ "Clipboard History", "edit-paste-symbolic", .{ .toggle = .clipboard }, "copy paste record" },
        .{ "Clipboard Entries to Keep", "document-open-recent-symbolic", .{ .choice = .clipboard_keep }, "history size limit" },
    } },
    .{ "Apps", .blue, &.{
        .{ "Default Apps", "applications-system-symbolic", .default_apps, "open with file types associations mime" },
        .{ "Terminal", "utilities-terminal-symbolic", .{ .choice = .terminal }, "console shell emulator" },
        .{ "Editor for Open at Line", "accessories-text-editor-symbolic", .{ .choice = .editor }, "code vim nvim" },
    } },
};

/// A row of `setting_rows`, its value as it is now. Rows are found again by
/// their setting's name (`settingKey`).
fn settingRow(
    ui: *Ui,
    arena: std.mem.Allocator,
    section: [:0]const u8,
    color: item_mod.Color,
    row: RowSpec,
) Item {
    const title, const icon, const source, const keywords = row;
    const custom_themes = config.customThemes(ui);
    const name: []const u8, const value: [:0]const u8, const action: item_mod.Setting =
        switch (source) {
            .theme => .{
                "theme",
                themes.displayName(arena, ui.settings.theme, config.preferDark(ui), custom_themes),
                .{ .go = .themes },
            },
            .default_apps => .{
                "default_apps",
                defaultAppsSummary(ui, arena),
                .{ .go = .default_apps },
            },
            .choice => |choice| .{
                @tagName(choice),
                choose_view.choiceLabel(ui, arena, choice),
                .{ .choose = choice },
            },
            .toggle => |toggle| .{
                @tagName(toggle),
                if (ui.settings.get(toggle)) "On" else "Off",
                .{ .toggle = toggle },
            },
        };
    return .{
        .key = settingKey(arena, name),
        .section = section,
        .title = title,
        .accessory = value,
        .icon = .{ .tile = .{ .name = icon, .color = color } },
        .action = .{ .setting = action },
        .keywords = keywords,
    };
}

/// The Settings view: `setting_rows`, the extensions, then Lumen's own rows.
pub fn settingsCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (setting_rows) |section| {
        const section_title, const color, const rows = section;
        for (rows) |row| {
            out.append(arena, settingRow(ui, arena, section_title, color, row)) catch break;
        }
    }
    prefs_view.extensionRows(ui, arena, &out);
    appendRow(Item, arena, &out, .{
        .key = settingKey(arena, "open_file"),
        .section = "Lumen",
        .title = "Open Settings File",
        .subtitle = labels.homeRelative(arena, ui.settings_path),
        .icon = .{ .tile = .{ .name = "document-edit-symbolic", .color = .gray } },
        .action = .{ .setting = .open_file },
        .keywords = "config edit text",
    });
    appendRow(Item, arena, &out, .{
        .key = settingKey(arena, "reset"),
        .section = "Lumen",
        .title = "Reset All Settings",
        .icon = .{ .tile = .{ .name = "edit-undo-symbolic", .color = .gray } },
        .action = .{ .setting = .reset },
        .keywords = "defaults restore",
        .confirm = true,
    });
    // What init.lua fixes cannot be changed here.
    for (out.items) |*item| {
        const key = settingName(item.action.setting) orelse continue;
        if (config.overridden(ui, key)) item.subtitle = "Set in init.lua";
    }
    return out.items;
}

/// The settings.conf key a Settings row changes, if any.
fn settingName(setting: item_mod.Setting) ?[]const u8 {
    return switch (setting) {
        .toggle => |toggle| @tagName(toggle),
        .choose => |choice| @tagName(choice),
        else => null,
    };
}

/// Appends one row (or option, or folder) to a list being built for a view.
/// Out of memory, the list shows without it: it is built again on the next
/// keystroke, and the log says what happened.
pub fn appendRow(
    comptime Row: type,
    arena: std.mem.Allocator,
    list: *std.ArrayList(Row),
    row: Row,
) void {
    list.append(arena, row) catch log.warn("out of memory: a row is left out", .{});
}

/// The name of the app with desktop id `id`, else the id itself.
pub fn appName(ui: *Ui, arena: std.mem.Allocator, id: []const u8) [:0]const u8 {
    for (ui.apps.items) |app| {
        const app_id = std.mem.span(c.g_app_info_get_id(app.action.app) orelse continue);
        if (std.mem.eql(u8, app_id, id)) return app.title;
    }
    return arena.dupeSentinel(u8, id, 0) catch "";
}

/// The Default Apps row's value: how many kinds have an app chosen.
pub fn defaultAppsSummary(ui: *Ui, arena: std.mem.Allocator) [:0]const u8 {
    const count = ui.settings.open_with.count();
    if (count == 0) return "System Defaults";
    return arena.printSentinel("{d} chosen", .{count}, 0) catch "";
}

/// The Default Apps view: a row per file kind, then the extensions the
/// settings file names.
pub fn defaultAppsCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (std.enums.values(Kind)) |kind| {
        const chosen = ui.settings.open_with.get(@tagName(kind));
        const accessory: [:0]const u8 = if (chosen) |id| appName(ui, arena, id) else blk: {
            const mime = kind.sampleMime();
            const system_default = c.g_app_info_get_default_for_type(mime, 0) orelse {
                break :blk "System Default";
            };
            defer c.g_object_unref(system_default);
            break :blk arena.printSentinel(
                "System: {s}",
                .{c.g_app_info_get_display_name(system_default) orelse ""},
                0,
            ) catch "";
        };
        out.append(arena, .{
            .key = arena.print("kind:{t}", .{kind}) catch "",
            .section = "File Kinds",
            .title = kind.title(),
            .accessory = accessory,
            .icon = .{ .tile = .{
                .name = kind.icon(),
                .color = if (chosen != null) .blue else .gray,
            } },
            .keywords = @tagName(kind),
            .action = .{ .setting = .{ .kind = kind } },
        }) catch break;
    }
    // Extensions set by hand in the file: shown, changed there.
    var open_with_iterator = ui.settings.open_with.iterator();
    while (open_with_iterator.next()) |open_with_entry| {
        if (open_with_entry.key_ptr.*[0] != '.') continue;
        out.append(arena, .{
            .section = "Extensions (edit in the settings file)",
            .title = arena.dupeSentinel(u8, open_with_entry.key_ptr.*, 0) catch continue,
            .accessory = appName(ui, arena, open_with_entry.value_ptr.*),
            .icon = .{ .tile = .{ .name = "text-x-generic-symbolic", .color = .blue } },
            .action = .{ .setting = .open_file },
        }) catch break;
    }
    return out.items;
}

/// The Change Theme view: the styles, Automatic, then the themes by section.
pub fn themeCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    styleCandidates(ui, arena, &out);
    const dark = config.preferDark(ui);
    const auto_theme = themes.find(themes.auto_id, dark, &.{});
    appendRow(Item, arena, &out, .{
        .key = "theme:auto",
        .title = "Automatic",
        .subtitle = "Lumen Dark or Light, following the system",
        .accessory = if (std.mem.eql(u8, ui.settings.theme, themes.auto_id)) "✓" else "",
        .icon = swatchOf(auto_theme),
        .action = .{ .setting = .{ .theme = themes.auto_id } },
    });
    for ([_]bool{ true, false }) |want_dark| {
        for (&themes.all) |*theme| {
            if (theme.dark != want_dark) continue;
            out.append(
                arena,
                themeItem(ui, arena, theme, if (want_dark) "Dark" else "Light"),
            ) catch break;
        }
    }
    const style_section = arena.printSentinel(
        "{s} Themes",
        .{styleTitle(arena, ui.settings.style)},
        0,
    ) catch "Style Themes";
    for (config.customThemes(ui)) |*theme| {
        if (!theme.from_style) continue;
        out.append(arena, themeItem(ui, arena, theme, style_section)) catch break;
    }
    for (config.customThemes(ui)) |*theme| {
        if (theme.from_style) continue;
        out.append(arena, themeItem(ui, arena, theme, "Your Themes")) catch break;
    }
    return out.items;
}

/// Styles: the built-in ones, then "Custom", the folders in
/// ~/.config/lumen/styles (one named like a built-in style replaces it).
fn styleCandidates(ui: *Ui, arena: std.mem.Allocator, out: *std.ArrayList(Item)) void {
    const custom = customStyles(ui, arena);
    const current = if (ui.settings.style.len > 0) ui.settings.style else "lumen";
    for (&styles.all) |*style| {
        if (has(custom, style.id)) continue;
        out.append(
            arena,
            styleItem(arena, style.id, style.name, style.description, "Styles", current),
        ) catch return;
    }
    for (custom) |name| {
        const subtitle = arena.printSentinel("~/.config/lumen/styles/{s}", .{name}, 0) catch "";
        out.append(
            arena,
            styleItem(arena, name, titleOf(arena, name), subtitle, "Custom", current),
        ) catch return;
    }
}

/// A style's name: the built-in one's, else its folder's ("my-style" is
/// "My Style").
fn styleTitle(arena: std.mem.Allocator, id: []const u8) [:0]const u8 {
    if (id.len == 0) return "Lumen";
    if (styles.find(id)) |style| return style.name;
    return titleOf(arena, id);
}

/// A folder name as a title: "my-style" is "My Style".
fn titleOf(arena: std.mem.Allocator, name: []const u8) [:0]const u8 {
    const out = arena.allocSentinel(u8, name.len, 0) catch return "";
    var start = true;
    for (name, 0..) |character, i| {
        const separator = character == '-' or character == '_';
        out[i] = if (separator) ' ' else if (start) std.ascii.toUpper(character) else character;
        start = separator;
    }
    return out;
}

/// Whether `name` is one of `names`.
fn has(names: []const [:0]const u8, name: []const u8) bool {
    for (names) |known| if (std.mem.eql(u8, known, name)) return true;
    return false;
}

fn styleItem(
    arena: std.mem.Allocator,
    id: []const u8,
    name: [:0]const u8,
    description: [:0]const u8,
    section: [:0]const u8,
    current: []const u8,
) Item {
    return .{
        .key = arena.print("style:{s}", .{id}) catch "",
        .section = section,
        .title = name,
        .subtitle = description,
        .accessory = if (std.mem.eql(u8, current, id)) "✓" else "",
        .icon = .{ .tile = .{ .name = "applications-graphics-symbolic", .color = .purple } },
        .action = .{ .setting = .{ .style = id } },
    };
}

/// The folders in ~/.config/lumen/styles, sorted.
fn customStyles(ui: *Ui, arena: std.mem.Allocator) []const [:0]const u8 {
    const path = arena.printSentinel("{s}/styles", .{ui.config_dir}, 0) catch return &.{};
    return os.subdirs(arena, path, settings_mod.isToken);
}

fn themeItem(
    ui: *Ui,
    arena: std.mem.Allocator,
    theme: *const themes.Theme,
    section: [:0]const u8,
) Item {
    return .{
        .key = arena.print("theme:{s}", .{theme.id}) catch "",
        .section = section,
        .title = theme.name,
        .accessory = if (std.mem.eql(u8, ui.settings.theme, theme.id)) "✓" else "",
        .icon = swatchOf(theme),
        .action = .{ .setting = .{ .theme = theme.id } },
    };
}

/// A theme's colours as a row icon.
pub fn swatchOf(theme: *const themes.Theme) item_mod.Icon {
    return .{ .swatch = .{
        .id = theme.id,
        .background = theme.background,
        .foreground = theme.foreground,
        .accent = theme.accent,
    } };
}

/// The settings key a row changes, when it changes one: init.lua may have
/// fixed it.
fn lockKey(setting: item_mod.Setting) ?[]const u8 {
    return switch (setting) {
        .theme => @tagName(settings_mod.Text.theme),
        .style => @tagName(settings_mod.Text.style),
        else => settingName(setting),
    };
}

/// Applies what a settings row does.
pub fn performSetting(ui: *Ui, setting: item_mod.Setting, operation: item_mod.Operation) void {
    if (lockKey(setting)) |key| {
        if (config.overridden(ui, key)) return ui.showFailure("Set in init.lua");
    }
    switch (setting) {
        .toggle => |toggle| {
            ui.settings.setToggle(toggle, !ui.settings.get(toggle));
            config.saveSettings(ui);
            ui.setReselect("set:{t}", .{toggle});
            ui.rebuild();
        },
        .choose => |choice| {
            choose_view.setChoosing(ui, .{ .setting = choice });
            var value_bytes: [32]u8 = undefined;
            ui.setReselect("pick:{s}", .{ui.settings.choiceValue(choice, &value_bytes)});
            ui.navigate(.choose);
        },
        .kind => |kind| {
            choose_view.setChoosing(ui, .{ .kind = kind });
            ui.setReselect("pick:{s}", .{ui.settings.open_with.get(@tagName(kind)) orelse ""});
            ui.navigate(.choose);
        },
        .pick => |value| choose_view.pick(ui, value),
        .go => |target| {
            ui.reselect.clear();
            ui.navigate(target);
        },
        .theme => |id| {
            _ = ui.settings.setTextValue(.theme, id);
            config.saveSettings(ui);
            ui.goBack();
        },
        .style => |id| {
            // Its CSS now, its Lua (layout, themes, lumen.set) on the reload.
            _ = ui.settings.setTextValue(.style, id);
            config.saveSettings(ui);
            ui.style_defaults_pending = true;
            ext_view.syncStyle(ui);
            ui.setReselect("style:{s}", .{id});
            ui.rebuild();
        },
        .open_with => |id| {
            choose_view.openWith(ui, id, if (operation == .always_use) .as_default else .once);
        },
        .open_file => {
            // Write the defaults first: an empty editor helps nobody.
            if (os.info(ui.settings_path.ptr) == null) config.saveSettings(ui);
            run.openFile(ui.actionContext(), ui.settings_path, .file);
            ui.hide();
        },
        .ext_prefs => |id| prefs_view.open(ui, id),
        .pref => |pref_index| prefs_view.edit(ui, pref_index),
        .save_input => prefs_view.saveInput(ui),
        .field => |field_index| form_view.edit(ui, field_index),
        .submit_form => form_view.submit(ui),
        .ext_open => |folder| {
            run.openFile(ui.actionContext(), folder, .folder);
            ui.hide();
        },
        .ext_update => |id| {
            ui.showFailure("Updating...");
            Ui.installer.update(ui, null, id);
        },
        .ext_uninstall => |id| Ui.installer.uninstall(ui, null, id),
        .reset => resetSettings(ui),
    }
}

/// Every setting back to its default, but for what init.lua fixes.
fn resetSettings(ui: *Ui) void {
    ui.settings.deinit();
    ui.settings = Settings.init(ui.gpa);
    config.applyOverrides(ui);
    config.saveSettings(ui);
    ui.setReselect("set:reset", .{});
    ui.rebuild();
}
