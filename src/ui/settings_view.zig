//! The Settings, Change Theme, Default Apps and choose views: their rows
//! and what picking one does.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const proc = @import("../sys/proc.zig");
const Apps = @import("../providers/Apps.zig");
const run = @import("../actions.zig");
const index = @import("index");
const os = @import("os");
const styles = @import("styles");
const settings_mod = @import("../settings.zig");
const ext_view = @import("ext_view.zig");
const Settings = settings_mod.Settings;
const themes = @import("themes.zig");
const Kind = core.file_kind.Kind;
const Ui = @import("Ui.zig");
const prefs_view = @import("prefs_view.zig");
const Host = @import("../ext/Host.zig");
const form_view = @import("form_view.zig");

const log = std.log.scoped(.ui);
const labels = @import("labels.zig");

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
    const name: []const u8, const value: [:0]const u8, const action: item_mod.Setting =
        switch (source) {
            .theme => .{
                "theme",
                themes.displayName(arena, ui.settings.theme, ui.preferDark(), ui.customThemes()),
                .{ .go = .themes },
            },
            .default_apps => .{
                "default_apps",
                defaultAppsSummary(ui, arena),
                .{ .go = .default_apps },
            },
            .choice => |choice| .{ @tagName(choice), choiceLabel(
                ui,
                arena,
                choice,
            ), .{ .choose = choice } },
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

pub fn settingsCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (setting_rows) |sec| for (sec[2]) |row| {
        out.append(arena, settingRow(ui, arena, sec[0], sec[1], row)) catch break;
    };
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
        if (ui.overridden(key)) item.subtitle = "Set in init.lua";
    }
    return out.items;
}

/// The settings.conf key a Settings row changes, if any.
fn settingName(s: item_mod.Setting) ?[]const u8 {
    return switch (s) {
        .toggle => |toggle| @tagName(toggle),
        .choose => |choice| @tagName(choice),
        else => null,
    };
}

const Option = Host.PrefChoice;

/// A row of the choose view: `o`, checked when it is the `current` value.
pub fn pickRow(
    arena: std.mem.Allocator,
    option: Option,
    current: []const u8,
) std.mem.Allocator.Error!Item {
    return .{
        .key = try arena.print("pick:{s}", .{option.value}),
        .title = option.label,
        .accessory = if (std.mem.eql(u8, option.value, current)) "✓" else "",
        .icon = .{ .tile = .{ .name = "object-select-symbolic", .color = .gray } },
        .action = .{ .setting = .{ .pick = option.value } },
    };
}

/// Appends one row (or option, or folder) to a list being built for a view.
/// Out of memory, the list shows without it: it is built again on the next
/// keystroke, and the log says what happened.
fn appendRow(
    comptime Row: type,
    arena: std.mem.Allocator,
    list: *std.ArrayList(Row),
    row: Row,
) void {
    list.append(arena, row) catch log.warn("out of memory: a row is left out", .{});
}

/// The values a choice can take, in the order they are listed.
pub fn choiceOptions(
    ui: *Ui,
    arena: std.mem.Allocator,
    choice: settings_mod.Choice,
) []const Option {
    _ = ui;
    return switch (choice) {
        .text_size => enumOptions(settings_mod.TextSize, .{
            .small = "Small",
            .default = "Default",
            .large = "Large",
        }),
        .position => enumOptions(settings_mod.Position, .{
            .upper_third = "Upper Third",
            .center = "Center",
        }),
        .width => enumOptions(settings_mod.Width, .{
            .narrow = "Narrow",
            .default = "Default",
            .wide = "Wide",
        }),
        .height => enumOptions(settings_mod.Height, .{
            .short = "Short",
            .default = "Default",
            .tall = "Tall",
        }),
        .density => enumOptions(settings_mod.Density, .{
            .compact = "Compact",
            .default = "Default",
            .comfortable = "Comfortable",
        }),
        .opacity => numberOptions(&settings_mod.opacity_choices, &.{
            "100% (Opaque)",
            "97%",
            "90%",
            "80%",
        }),
        .clipboard_keep => numberOptions(&settings_mod.keep_choices, &.{
            "100 entries",
            "500 entries",
            "1,000 entries",
            "5,000 entries",
        }),
        .icon_theme => iconThemes(arena),
        .terminal, .editor => blk: {
            var out: std.ArrayList(Option) = .empty;
            const terminal = choice == .terminal;
            const list: []const settings_mod.Program = if (terminal)
                &settings_mod.terminals
            else
                &settings_mod.editors;
            const auto_cmd: []const u8 = if (terminal) run.autoTerminal() else run.autoEditor();
            const auto_base = std.Io.Dir.path.basename(auto_cmd);
            var auto_name: []const u8 = auto_base;
            for (list) |program| if (std.mem.eql(u8, program.command, auto_base)) {
                auto_name = program.title;
            };
            appendRow(Option, arena, &out, .{
                .value = "",
                .label = arena.printSentinel("Automatic ({s})", .{auto_name}, 0) catch "Automatic",
            });
            for (list) |program| {
                if (proc.have(program.command)) {
                    appendRow(Option, arena, &out, .{
                        .value = program.command,
                        .label = program.title,
                    });
                }
            }
            break :blk out.items;
        },
    };
}

/// The options of a setting stored as one of `Enum`'s tags, in the tags'
/// order. The values are the tags' own names, so they cannot drift from
/// what Settings parses; each tag needs a label.
fn enumOptions(
    comptime Enum: type,
    comptime option_labels: std.enums.EnumFieldStruct(Enum, [:0]const u8, null),
) []const Option {
    const options = comptime blk: {
        const tags = std.enums.values(Enum);
        var built: [tags.len]Option = undefined;
        for (tags, &built) |tag, *option| {
            option.* = .{ .value = @tagName(tag), .label = @field(option_labels, @tagName(tag)) };
        }
        break :blk built;
    };
    return &options;
}

/// The options of a number setting: the values Settings offers, written
/// as Settings reads them back, with a label for each in the same order.
fn numberOptions(
    comptime values: anytype,
    comptime value_labels: []const [:0]const u8,
) []const Option {
    const options = comptime blk: {
        std.debug.assert(values.len == value_labels.len);
        var built: [value_labels.len]Option = undefined;
        for (values, value_labels, &built) |value, label, *option| {
            option.* = .{ .value = std.fmt.comptimePrint("{d}", .{value}), .label = label };
        }
        break :blk built;
    };
    return &options;
}

/// Folders under the icon directories that are not themes to pick:
/// hicolor is every theme's fallback, and "default" is the cursor theme's
/// alias.
const icon_folders_not_themes = [_][]const u8{ "hicolor", "default" };

fn notAnIconTheme(name: []const u8) bool {
    for (icon_folders_not_themes) |folder| {
        if (std.mem.eql(u8, name, folder)) return true;
    }
    return false;
}

/// "Automatic", then the icon themes installed (folders under the icon
/// directories with an index.theme that lists icon directories: cursor
/// themes have none), by their names.
fn iconThemes(arena: std.mem.Allocator) []const Option {
    var out: std.ArrayList(Option) = .empty;
    out.append(
        arena,
        .{ .value = "", .label = "Automatic (the desktop's)" },
    ) catch return out.items;
    // Out of memory, a folder is left out of the list: the themes in the
    // others still show.
    var roots: std.ArrayList([]const u8) = .empty;
    const home = std.mem.span(c.g_get_home_dir());
    const user_data_dir = std.mem.span(c.g_get_user_data_dir());
    appendRow([]const u8, arena, &roots, arena.print("{s}/.icons", .{home}) catch "");
    appendRow([]const u8, arena, &roots, arena.print("{s}/icons", .{user_data_dir}) catch "");
    var system_data_dirs = c.g_get_system_data_dirs();
    while (system_data_dirs[0]) |data_dir| : (system_data_dirs += 1) {
        const root = arena.print("{s}/icons", .{std.mem.span(data_dir)}) catch "";
        appendRow([]const u8, arena, &roots, root);
    }
    for (roots.items) |root| {
        const root_z = arena.dupeSentinel(u8, root, 0) catch continue;
        const dir = c.g_dir_open(root_z.ptr, 0, null) orelse continue;
        defer c.g_dir_close(dir);
        while (c.g_dir_read_name(dir)) |name_c| {
            const name = std.mem.span(name_c);
            if (notAnIconTheme(name)) continue;
            var dup = false;
            for (out.items) |option| dup = dup or std.mem.eql(u8, option.value, name);
            if (dup) continue;
            const index_path = arena.printSentinel(
                "{s}/{s}/index.theme",
                .{ root, name },
                0,
            ) catch continue;
            var buf: [8192]u8 = undefined;
            const text = os.readHead(index_path.ptr, &buf);
            if (std.mem.find(u8, text, "\nDirectories=") == null) continue;
            var label: []const u8 = name;
            if (std.mem.find(u8, text, "\nName=")) |at| {
                const rest = text[at + 6 ..];
                label = rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len];
            }
            out.append(arena, .{
                .value = arena.dupeSentinel(u8, name, 0) catch continue,
                .label = arena.dupeSentinel(u8, label, 0) catch continue,
            }) catch break;
        }
    }
    return out.items;
}

/// The current value of a choice, as shown.
pub fn choiceLabel(ui: *Ui, arena: std.mem.Allocator, choice: settings_mod.Choice) [:0]const u8 {
    var buf: [32]u8 = undefined;
    const value = ui.settings.choiceValue(choice, &buf);
    for (choiceOptions(ui, arena, choice)) |option| {
        if (std.mem.eql(u8, option.value, value)) return option.label;
    }
    // Set by hand to something not offered (not installed, unusual value).
    return arena.dupeSentinel(u8, value, 0) catch "";
}

pub fn chooseTitle(choice: settings_mod.Choice) []const u8 {
    return switch (choice) {
        .text_size => "Text Size",
        .opacity => "Window Opacity",
        .position => "Window Position",
        .width => "Window Width",
        .height => "Window Height",
        .density => "Density",
        .icon_theme => "Icon Theme",
        .clipboard_keep => "Clipboard Entries to Keep",
        .terminal => "Terminal",
        .editor => "Editor for Open at Line",
    };
}

fn writeChooseTitle(
    ui: *Ui,
    writer: *std.Io.Writer,
    choosing: Ui.Choosing,
) std.Io.Writer.Error!void {
    switch (choosing) {
        .none => {},
        .setting => |choice| try writer.writeAll(chooseTitle(choice)),
        .kind => |kind| try writer.print("Open {s} With", .{kind.title()}),
        .file => |file| {
            try writer.print("Open {s} With", .{std.Io.Dir.path.basename(file.path)});
        },
        .pref => |pref_index| if (ui.ext_registry) |registry| {
            if (registry.pref(pref_index)) |preference| try writer.writeAll(preference.title);
        },
        .field => |field_index| if (form_view.field(ui, field_index)) |form_field| {
            try writer.writeAll(form_field.title);
        },
    }
}

pub fn setChoosing(ui: *Ui, next: Ui.Choosing) void {
    if (ui.choosing == .file) {
        ui.gpa.free(ui.choosing.file.path);
        ui.gpa.free(ui.choosing.file.mime);
    }
    ui.choosing = next;
    var writer: std.Io.Writer = .fixed(ui.choose_title[0 .. ui.choose_title.len - 1]);
    // A title longer than the buffer is cut on a character boundary rather
    // than dropped, because an empty title tells the user nothing: the
    // writer is full, and what it holds is kept.
    writeChooseTitle(ui, &writer, next) catch {};
    const title_len = core.utf8.validPrefix(writer.buffered()).len;
    ui.choose_title[title_len] = 0;
}

pub fn chooseCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    switch (ui.choosing) {
        .none => {},
        .setting => |choice| {
            var buf: [32]u8 = undefined;
            const current = ui.settings.choiceValue(choice, &buf);
            for (choiceOptions(ui, arena, choice)) |option| out.append(
                arena,
                pickRow(arena, option, current) catch break,
            ) catch break;
        },
        .kind => |kind| appOptions(
            ui,
            arena,
            &out,
            kind.sampleMime(),
            ui.settings.open_with.get(@tagName(kind)),
            false,
        ),
        .file => |file| appOptions(ui, arena, &out, file.mime, null, true),
        .pref => |pref_index| prefs_view.choiceCandidates(ui, arena, &out, pref_index),
        .field => |field_index| form_view.choiceCandidates(ui, arena, &out, field_index),
    }
    return out.items;
}

/// Apps for `mime`: those that declare it first, then every other app (any
/// app can be told to open anything). `open_now`: rows open the file
/// instead of saving a choice.
pub fn appOptions(
    self: *Ui,
    arena: std.mem.Allocator,
    out: *std.ArrayList(Item),
    mime: [:0]const u8,
    current: ?[]const u8,
    open_now: bool,
) void {
    if (!open_now) {
        const def = c.g_app_info_get_default_for_type(mime, 0);
        defer if (def) |default_app| c.g_object_unref(default_app);
        const name: [:0]const u8 = if (def) |default_app| (arena.dupeSentinel(
            u8,
            std.mem.span(c.g_app_info_get_display_name(default_app) orelse ""),
            0,
        ) catch "") else "none set";
        out.append(arena, .{
            .key = "pick:",
            .title = "System Default",
            .subtitle = name,
            .accessory = if (current == null) "✓" else "",
            .icon = .{ .tile = .{ .name = "emblem-default-symbolic", .color = .gray } },
            .action = .{ .setting = .{ .pick = "" } },
        }) catch return;
    }
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    if (c.g_app_info_get_all_for_type(mime)) |list| {
        defer c.g_list_free_full(list, &c.g_object_unref);
        var node: ?*c.GList = list;
        while (node) |list_node| : (node = list_node.next) {
            const info: *c.GAppInfo = @ptrCast(@alignCast(list_node.data));
            const id = arena.dupe(u8, std.mem.span(
                c.g_app_info_get_id(info) orelse continue,
            )) catch continue;
            declared.put(arena, id, {}) catch {
                log.warn("out of memory: an app may list under Other Apps", .{});
            };
        }
    }
    for ([_]bool{ true, false }) |want_declared| {
        for (self.apps.items) |app| {
            const info = app.action.app;
            const id = std.mem.span(c.g_app_info_get_id(info) orelse continue);
            if (declared.contains(id) != want_declared) continue;
            const idz = arena.dupeSentinel(u8, id, 0) catch continue;
            out.append(arena, .{
                .key = arena.print("pick:{s}", .{id}) catch "",
                .section = if (want_declared) "Recommended" else "Other Apps",
                .title = app.title,
                .subtitle = app.subtitle,
                .accessory = if (current != null and std.mem.eql(u8, current.?, id)) "✓" else "",
                .icon = app.icon,
                .keywords = app.keywords,
                .action = .{ .setting = if (open_now) .{ .open_with = idz } else .{ .pick = idz } },
            }) catch return;
        }
    }
}

pub fn appName(ui: *Ui, arena: std.mem.Allocator, id: []const u8) [:0]const u8 {
    for (ui.apps.items) |app| {
        const aid = std.mem.span(c.g_app_info_get_id(app.action.app) orelse continue);
        if (std.mem.eql(u8, aid, id)) return app.title;
    }
    return arena.dupeSentinel(u8, id, 0) catch "";
}

pub fn defaultAppsSummary(ui: *Ui, arena: std.mem.Allocator) [:0]const u8 {
    const count = ui.settings.open_with.count();
    if (count == 0) return "System Defaults";
    return arena.printSentinel("{d} chosen", .{count}, 0) catch "";
}

pub fn defaultAppsCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (std.enums.values(Kind)) |k| {
        const chosen = ui.settings.open_with.get(@tagName(k));
        const accessory: [:0]const u8 = if (chosen) |id| appName(ui, arena, id) else blk: {
            const def = c.g_app_info_get_default_for_type(
                k.sampleMime(),
                0,
            ) orelse break :blk "System Default";
            defer c.g_object_unref(def);
            break :blk arena.printSentinel(
                "System: {s}",
                .{c.g_app_info_get_display_name(def) orelse ""},
                0,
            ) catch "";
        };
        out.append(arena, .{
            .key = arena.print("kind:{t}", .{k}) catch "",
            .section = "File Kinds",
            .title = k.title(),
            .accessory = accessory,
            .icon = .{ .tile = .{
                .name = k.icon(),
                .color = if (chosen != null) .blue else .gray,
            } },
            .keywords = @tagName(k),
            .action = .{ .setting = .{ .kind = k } },
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

pub fn themeCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    styleCandidates(ui, arena, &out);
    const dark = ui.preferDark();
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
    for (ui.customThemes()) |*theme| {
        if (!theme.from_style) continue;
        out.append(arena, themeItem(ui, arena, theme, style_section)) catch break;
    }
    for (ui.customThemes()) |*theme| {
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
        const sub = arena.printSentinel("~/.config/lumen/styles/{s}", .{name}, 0) catch "";
        out.append(
            arena,
            styleItem(arena, name, titleOf(arena, name), sub, "Custom", current),
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

fn titleOf(arena: std.mem.Allocator, name: []const u8) [:0]const u8 {
    const out = arena.allocSentinel(u8, name.len, 0) catch return "";
    var start = true;
    for (name, 0..) |choice, i| {
        out[i] = if (choice == '-' or choice == '_') ' ' else if (start) std.ascii.toUpper(
            choice,
        ) else choice;
        start = choice == '-' or choice == '_';
    }
    return out;
}

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

pub fn swatchOf(theme: *const themes.Theme) item_mod.Icon {
    return .{ .swatch = .{
        .id = theme.id,
        .bg = theme.bg,
        .fg = theme.fg,
        .accent = theme.accent,
    } };
}

/// Applies what a settings row does.
/// A value picked in the choose view, for what it was opened for.
fn pick(ui: *Ui, value: [:0]const u8) void {
    switch (ui.choosing) {
        .setting => |choice| {
            _ = ui.settings.setChoice(choice, value);
            ui.saveSettings();
            ui.goBack();
        },
        .kind => |kind| {
            if (ui.settings.setOpenWith(@tagName(kind), value)) {
                ui.saveSettings();
            } else |err| {
                log.warn("default app for {t}: {t}", .{ kind, err });
            }
            ui.goBack();
        },
        .pref => |pref_index| prefs_view.pick(ui, pref_index, value),
        .field => |field_index| form_view.pick(ui, field_index, value),
        .none, .file => {},
    }
}

/// Open With once, or Open and Always Use: the app becomes the default
/// for the file's kind (or its extension).
const OpenWithChoice = enum { once, as_default };

/// Opens the file being chosen for with app `id`.
fn openWith(ui: *Ui, id: [:0]const u8, choice: OpenWithChoice) void {
    if (ui.choosing != .file) return;
    const file = ui.choosing.file;
    if (choice == .as_default) {
        const name = std.Io.Dir.path.basename(file.path);
        var extension_buf: [16]u8 = undefined;
        const key: []const u8 = if (core.file_kind.of(file.mime, name, .file)) |kind|
            @tagName(kind)
        else
            core.file_kind.extKey(&extension_buf, name);
        if (key.len > 0) {
            if (ui.settings.setOpenWith(key, id)) {
                ui.saveSettings();
            } else |err| {
                log.warn("default app for {s}: {t}", .{ key, err });
            }
        }
    }
    if (!run.openWith(file.path, id)) return;
    ui.hide();
}

pub fn performSetting(ui: *Ui, setting: item_mod.Setting, op: item_mod.Op) void {
    const locked: ?[]const u8 = switch (setting) {
        .theme => @tagName(settings_mod.Text.theme),
        .style => @tagName(settings_mod.Text.style),
        else => settingName(setting),
    };
    if (locked) |key| if (ui.overridden(key)) return ui.showFailure("Set in init.lua");
    switch (setting) {
        .toggle => |toggle| {
            ui.settings.setToggle(toggle, !ui.settings.get(toggle));
            ui.saveSettings();
            ui.setReselect("set:{t}", .{toggle});
            ui.rebuild();
        },
        .choose => |choice| {
            setChoosing(ui, .{ .setting = choice });
            var buf: [32]u8 = undefined;
            ui.setReselect("pick:{s}", .{ui.settings.choiceValue(choice, &buf)});
            ui.navigate(.choose);
        },
        .kind => |kind| {
            setChoosing(ui, .{ .kind = kind });
            ui.setReselect("pick:{s}", .{ui.settings.open_with.get(@tagName(kind)) orelse ""});
            ui.navigate(.choose);
        },
        .pick => |value| pick(ui, value),
        .go => |target| {
            ui.reselect.clear();
            ui.navigate(target);
        },
        .theme => |id| {
            _ = ui.settings.setTextValue(.theme, id);
            ui.saveSettings();
            ui.goBack();
        },
        .style => |id| {
            // Its CSS now, its Lua (layout, themes, lumen.set) on the reload.
            _ = ui.settings.setTextValue(.style, id);
            ui.saveSettings();
            ui.style_defaults_pending = true;
            ext_view.syncStyle(ui);
            ui.setReselect("style:{s}", .{id});
            ui.rebuild();
        },
        .open_with => |id| openWith(ui, id, if (op == .always_use) .as_default else .once),
        .open_file => {
            // Write the defaults first: an empty editor helps nobody.
            if (os.info(ui.settings_path.ptr) == null) ui.saveSettings();
            run.openFile(ui.actionCtx(), ui.settings_path, .file);
            ui.hide();
        },
        .ext_prefs => |id| prefs_view.open(ui, id),
        .pref => |pref_index| prefs_view.edit(ui, pref_index),
        .save_input => prefs_view.saveInput(ui),
        .field => |field_index| form_view.edit(ui, field_index),
        .submit_form => form_view.submit(ui),
        .ext_open => |dir| {
            run.openFile(ui.actionCtx(), dir, .folder);
            ui.hide();
        },
        .ext_update => |id| {
            ui.showFailure("Updating...");
            Ui.installer.update(ui, null, id);
        },
        .ext_uninstall => |id| Ui.installer.uninstall(ui, null, id),
        .reset => {
            ui.settings.deinit();
            ui.settings = Settings.init(ui.gpa);
            ui.applyOverrides();
            ui.saveSettings();
            ui.setReselect("set:reset", .{});
            ui.rebuild();
        },
    }
}

/// Open With for a file from the files or contents view.
pub fn chooseAppFor(ui: *Ui, path: [:0]const u8) void {
    const guessed = c.g_content_type_guess(path, null, 0, null);
    defer if (guessed) |guessed_type| c.g_free(guessed_type);
    const mime = ui.gpa.dupeSentinel(
        u8,
        if (guessed) |guessed_type| std.mem.span(guessed_type) else labels.mime_unknown,
        0,
    ) catch return;
    const owned = ui.gpa.dupeSentinel(u8, path, 0) catch {
        ui.gpa.free(mime);
        return;
    };
    setChoosing(ui, .{ .file = .{ .path = owned, .mime = mime } });
    ui.reselect.clear();
    ui.navigate(.choose);
}

test "every listed choice is a value Settings accepts" {
    var settings = Settings.init(std.testing.allocator);
    defer settings.deinit();
    const fixed_choices = [_]settings_mod.Choice{
        .text_size, .opacity, .position, .width, .height, .density, .clipboard_keep,
    };
    for (fixed_choices) |choice| {
        const options = choiceOptions(undefined, std.testing.allocator, choice);
        try std.testing.expect(options.len > 0);
        for (options) |option| {
            try std.testing.expect(settings.setChoice(choice, option.value));
        }
    }
}
