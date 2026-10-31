//! The choose view: the values one thing can take, to pick one. What it
//! lists for is `Ui.choosing` (set with `setChoosing`): a setting's choices,
//! the apps for a file kind (Default Apps) or for one file (Open With), or
//! a choice preference or form field of an extension (prefs_view.zig and
//! form_view.zig fill those rows with `pickRow`). Picking a row (`pick`)
//! stores the value where it belongs and goes back.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const proc = @import("../sys/proc.zig");
const run = @import("../actions.zig");
const os = @import("os");
const settings_mod = @import("../settings.zig");
const Settings = settings_mod.Settings;
const Host = @import("../ext/Host.zig");
const config = @import("config.zig");
const form_view = @import("form_view.zig");
const labels = @import("labels.zig");
const prefs_view = @import("prefs_view.zig");
const settings_view = @import("settings_view.zig");
const appendRow = settings_view.appendRow;
const Ui = @import("Ui.zig");

const log = std.log.scoped(.ui);

/// What the choose view lists values for next; frees the file it chose for.
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
    const title_length = core.utf8.validPrefix(writer.buffered()).len;
    ui.choose_title[title_length] = 0;
}

/// The choose view's title for what it lists values for.
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
            if (registry.preference(pref_index)) |preference| try writer.writeAll(preference.title);
        },
        .field => |field_index| if (form_view.field(ui, field_index)) |form_field| {
            try writer.writeAll(form_field.title);
        },
    }
}

/// The choose view's rows: the values of what it was opened for.
pub fn candidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    switch (ui.choosing) {
        .none => {},
        .setting => |choice| {
            var value_bytes: [32]u8 = undefined;
            const current = ui.settings.choiceValue(choice, &value_bytes);
            for (choiceOptions(arena, choice)) |option| {
                const row = pickRow(arena, option, current) catch break;
                out.append(arena, row) catch break;
            }
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

/// A value picked in the choose view, for what it was opened for.
pub fn pick(ui: *Ui, value: [:0]const u8) void {
    switch (ui.choosing) {
        .setting => |choice| {
            _ = ui.settings.setChoice(choice, value);
            config.saveSettings(ui);
            ui.goBack();
        },
        .kind => |kind| {
            if (ui.settings.setOpenWith(@tagName(kind), value)) {
                config.saveSettings(ui);
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

const Option = Host.PreferenceChoice;

/// A row of the choose view: `option`, checked when it is the `current`
/// value.
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

/// The values a choice can take, in the order they are listed.
pub fn choiceOptions(arena: std.mem.Allocator, choice: settings_mod.Choice) []const Option {
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
        .terminal => programOptions(arena, &settings_mod.terminals, run.autoTerminal()),
        .editor => programOptions(arena, &settings_mod.editors, run.autoEditor()),
    };
}

/// "Automatic" with the program it finds (`automatic_command`), then the
/// programs of `programs` that are installed.
fn programOptions(
    arena: std.mem.Allocator,
    programs: []const settings_mod.Program,
    automatic_command: []const u8,
) []const Option {
    var out: std.ArrayList(Option) = .empty;
    const automatic_base = std.Io.Dir.path.basename(automatic_command);
    var automatic_name: []const u8 = automatic_base;
    for (programs) |program| if (std.mem.eql(u8, program.command, automatic_base)) {
        automatic_name = program.title;
    };
    appendRow(Option, arena, &out, .{
        .value = "",
        .label = arena.printSentinel("Automatic ({s})", .{automatic_name}, 0) catch "Automatic",
    });
    for (programs) |program| {
        if (proc.have(program.command)) {
            appendRow(Option, arena, &out, .{
                .value = program.command,
                .label = program.title,
            });
        }
    }
    return out.items;
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

/// Whether the icon folder `name` is one of `icon_folders_not_themes`.
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
        const folder = c.g_dir_open(root_z.ptr, 0, null) orelse continue;
        defer c.g_dir_close(folder);
        while (c.g_dir_read_name(folder)) |name_z| {
            const name = std.mem.span(name_z);
            if (notAnIconTheme(name)) continue;
            var listed = false;
            for (out.items) |option| listed = listed or std.mem.eql(u8, option.value, name);
            if (listed) continue;
            const index_path = arena.printSentinel(
                "{s}/{s}/index.theme",
                .{ root, name },
                0,
            ) catch continue;
            var index_head: [8192]u8 = undefined;
            const text = os.readHead(index_path.ptr, &index_head);
            if (std.mem.find(u8, text, "\nDirectories=") == null) continue;
            var label: []const u8 = name;
            const name_key = "\nName=";
            if (std.mem.find(u8, text, name_key)) |name_at| {
                const rest = text[name_at + name_key.len ..];
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
    var value_bytes: [32]u8 = undefined;
    const value = ui.settings.choiceValue(choice, &value_bytes);
    for (choiceOptions(arena, choice)) |option| {
        if (std.mem.eql(u8, option.value, value)) return option.label;
    }
    // Set by hand to something not offered (not installed, unusual value).
    return arena.dupeSentinel(u8, value, 0) catch "";
}

/// The choose view's title for a setting: the setting's row title.
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

/// Apps for `mime`: those that declare it first, then every other app (any
/// app can be told to open anything). `open_now`: rows open the file
/// instead of saving a choice.
pub fn appOptions(
    ui: *Ui,
    arena: std.mem.Allocator,
    out: *std.ArrayList(Item),
    mime: [:0]const u8,
    current: ?[]const u8,
    open_now: bool,
) void {
    if (!open_now) {
        const system_default = c.g_app_info_get_default_for_type(mime, 0);
        defer if (system_default) |app_info| c.g_object_unref(app_info);
        const name: [:0]const u8 = if (system_default) |app_info| blk: {
            const display_name = c.g_app_info_get_display_name(app_info) orelse "";
            break :blk arena.dupeSentinel(u8, std.mem.span(display_name), 0) catch "";
        } else "none set";
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
            const app_info: *c.GAppInfo = @ptrCast(@alignCast(list_node.data));
            const app_id = c.g_app_info_get_id(app_info) orelse continue;
            const id = arena.dupe(u8, std.mem.span(app_id)) catch continue;
            declared.put(arena, id, {}) catch {
                log.warn("out of memory: an app may list under Other Apps", .{});
            };
        }
    }
    for ([_]bool{ true, false }) |want_declared| {
        for (ui.apps.items) |app| {
            const app_info = app.action.app;
            const id = std.mem.span(c.g_app_info_get_id(app_info) orelse continue);
            if (declared.contains(id) != want_declared) continue;
            const id_z = arena.dupeSentinel(u8, id, 0) catch continue;
            out.append(arena, .{
                .key = arena.print("pick:{s}", .{id}) catch "",
                .section = if (want_declared) "Recommended" else "Other Apps",
                .title = app.title,
                .subtitle = app.subtitle,
                .accessory = if (current != null and std.mem.eql(u8, current.?, id)) "✓" else "",
                .icon = app.icon,
                .keywords = app.keywords,
                .action = .{
                    .setting = if (open_now) .{ .open_with = id_z } else .{ .pick = id_z },
                },
            }) catch return;
        }
    }
}

/// Open With once, or Open and Always Use: the app becomes the default
/// for the file's kind (or its extension).
pub const OpenWithChoice = enum { once, as_default };

/// Opens the file being chosen for with app `id`.
pub fn openWith(ui: *Ui, id: [:0]const u8, choice: OpenWithChoice) void {
    if (ui.choosing != .file) return;
    const file = ui.choosing.file;
    if (choice == .as_default) {
        const name = std.Io.Dir.path.basename(file.path);
        var extension_bytes: [16]u8 = undefined;
        const key: []const u8 = if (core.file_kind.of(file.mime, name, .file)) |kind|
            @tagName(kind)
        else
            core.file_kind.extensionKey(&extension_bytes, name);
        if (key.len > 0) {
            if (ui.settings.setOpenWith(key, id)) {
                config.saveSettings(ui);
            } else |err| {
                log.warn("default app for {s}: {t}", .{ key, err });
            }
        }
    }
    if (!run.openWith(file.path, id)) return;
    ui.hide();
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
        const options = choiceOptions(std.testing.allocator, choice);
        try std.testing.expect(options.len > 0);
        for (options) |option| {
            try std.testing.expect(settings.setChoice(choice, option.value));
        }
    }
}
