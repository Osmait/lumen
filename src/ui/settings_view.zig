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

pub fn settingKey(a: std.mem.Allocator, name: []const u8) []const u8 {
    return a.print("set:{s}", .{name}) catch "";
}

pub fn settingsCandidates(ui: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    const st = &ui.settings;
    const S = struct {
        const Row = struct {
            section: [:0]const u8,
            /// The key the row is found by again (reselect).
            name: []const u8,
            title: [:0]const u8,
            /// The current value, shown on the right.
            value: [:0]const u8,
            icon: [:0]const u8,
            color: item_mod.Color,
            action: item_mod.Setting,
            /// Extra words it is found by.
            keywords: []const u8 = "",
        };
        fn row(al: std.mem.Allocator, r: Row) Item {
            return .{
                .key = settingKey(al, r.name),
                .section = r.section,
                .title = r.title,
                .accessory = r.value,
                .icon = .{ .tile = .{ .name = r.icon, .color = r.color } },
                .action = .{ .setting = r.action },
                .keywords = r.keywords,
            };
        }
        fn onOff(b: bool) [:0]const u8 {
            return if (b) "On" else "Off";
        }
    };
    const choose = struct {
        fn f(ch: settings_mod.Choice) item_mod.Setting {
            return .{ .choose = ch };
        }
    }.f;
    out.append(a, S.row(a, .{
        .section = "Appearance",
        .name = "theme",
        .title = "Theme",
        .value = themes.displayName(a, st.theme, ui.preferDark()),
        .icon = "applications-graphics-symbolic",
        .color = .purple,
        .action = .{ .go = .themes },
        .keywords = "color dark light appearance",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Appearance",
        .name = "text_size",
        .title = "Text Size",
        .value = choiceLabel(ui, a, .text_size),
        .icon = "preferences-desktop-font-symbolic",
        .color = .purple,
        .action = choose(.text_size),
        .keywords = "font scale zoom bigger smaller",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Appearance",
        .name = "opacity",
        .title = "Window Opacity",
        .value = choiceLabel(ui, a, .opacity),
        .icon = "display-brightness-symbolic",
        .color = .purple,
        .action = choose(.opacity),
        .keywords = "transparency translucent background",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Appearance",
        .name = "position",
        .title = "Window Position",
        .value = choiceLabel(ui, a, .position),
        .icon = "preferences-desktop-display-symbolic",
        .color = .purple,
        .action = choose(.position),
        .keywords = "center top place",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Appearance",
        .name = "icon_theme",
        .title = "Icon Theme",
        .value = choiceLabel(ui, a, .icon_theme),
        .icon = "preferences-desktop-icons-symbolic",
        .color = .purple,
        .action = choose(.icon_theme),
        .keywords = "icons pack papirus adwaita",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Layout",
        .name = "width",
        .title = "Window Width",
        .value = choiceLabel(ui, a, .width),
        .icon = "view-dual-symbolic",
        .color = .green,
        .action = choose(.width),
        .keywords = "size wide narrow layout",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Layout",
        .name = "height",
        .title = "Window Height",
        .value = choiceLabel(ui, a, .height),
        .icon = "view-list-symbolic",
        .color = .green,
        .action = choose(.height),
        .keywords = "size tall short rows results layout",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Layout",
        .name = "density",
        .title = "Density",
        .value = choiceLabel(ui, a, .density),
        .icon = "view-grid-symbolic",
        .color = .green,
        .action = choose(.density),
        .keywords = "compact comfortable spacing icons rows layout",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Search",
        .name = "files_in_root",
        .title = "Show Files in Main Search",
        .value = S.onOff(st.files_in_root),
        .icon = "folder-saved-search-symbolic",
        .color = .orange,
        .action = .{ .toggle = .files_in_root },
        .keywords = "results",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Search",
        .name = "suggestions",
        .title = "Show Suggestions",
        .value = S.onOff(st.suggestions),
        .icon = "starred-symbolic",
        .color = .orange,
        .action = .{ .toggle = .suggestions },
        .keywords = "frecency recent most used",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Clipboard",
        .name = "clipboard",
        .title = "Clipboard History",
        .value = S.onOff(st.clipboard),
        .icon = "edit-paste-symbolic",
        .color = .red,
        .action = .{ .toggle = .clipboard },
        .keywords = "copy paste record",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Clipboard",
        .name = "clipboard_keep",
        .title = "Clipboard Entries to Keep",
        .value = choiceLabel(ui, a, .clipboard_keep),
        .icon = "document-open-recent-symbolic",
        .color = .red,
        .action = choose(.clipboard_keep),
        .keywords = "history size limit",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Apps",
        .name = "default_apps",
        .title = "Default Apps",
        .value = defaultAppsSummary(ui, a),
        .icon = "applications-system-symbolic",
        .color = .blue,
        .action = .{ .go = .default_apps },
        .keywords = "open with file types associations mime",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Apps",
        .name = "terminal",
        .title = "Terminal",
        .value = choiceLabel(ui, a, .terminal),
        .icon = "utilities-terminal-symbolic",
        .color = .blue,
        .action = choose(.terminal),
        .keywords = "console shell emulator",
    })) catch {};
    out.append(a, S.row(a, .{
        .section = "Apps",
        .name = "editor",
        .title = "Editor for Open at Line",
        .value = choiceLabel(ui, a, .editor),
        .icon = "accessories-text-editor-symbolic",
        .color = .blue,
        .action = choose(.editor),
        .keywords = "code vim nvim",
    })) catch {};
    prefs_view.extensionRows(ui, a, &out);
    var file_item = S.row(a, .{
        .section = "Lumen",
        .name = "open_file",
        .title = "Open Settings File",
        .value = "",
        .icon = "document-edit-symbolic",
        .color = .gray,
        .action = .open_file,
        .keywords = "config edit text",
    });
    file_item.subtitle = labels.homeRelative(a, ui.settings_path);
    out.append(a, file_item) catch {};
    var reset = S.row(a, .{
        .section = "Lumen",
        .name = "reset",
        .title = "Reset All Settings",
        .value = "",
        .icon = "edit-undo-symbolic",
        .color = .gray,
        .action = .reset,
        .keywords = "defaults restore",
    });
    reset.confirm = true;
    out.append(a, reset) catch {};
    // What init.lua fixes cannot be changed here.
    for (out.items) |*it| {
        const key = settingName(it.action.setting) orelse continue;
        if (ui.overridden(key)) it.subtitle = "Set in init.lua";
    }
    return out.items;
}

/// The settings.conf key a Settings row changes, if any.
fn settingName(s: item_mod.Setting) ?[]const u8 {
    return switch (s) {
        .toggle => |t| @tagName(t),
        .choose => |ch| @tagName(ch),
        else => null,
    };
}

const Option = Host.PrefChoice;

/// A row of the choose view: `o`, checked when it is the `current` value.
pub fn pickRow(a: std.mem.Allocator, o: Option, current: []const u8) std.mem.Allocator.Error!Item {
    return .{
        .key = try a.print("pick:{s}", .{o.value}),
        .title = o.label,
        .accessory = if (std.mem.eql(u8, o.value, current)) "✓" else "",
        .icon = .{ .tile = .{ .name = "object-select-symbolic", .color = .gray } },
        .action = .{ .setting = .{ .pick = o.value } },
    };
}

/// The values a choice can take, in the order they are listed.
pub fn choiceOptions(ui: *Ui, a: std.mem.Allocator, ch: settings_mod.Choice) []const Option {
    _ = ui;
    return switch (ch) {
        .text_size => &.{
            .{ .value = "small", .label = "Small" },
            .{ .value = "default", .label = "Default" },
            .{ .value = "large", .label = "Large" },
        },
        .position => &.{ .{ .value = "upper_third", .label = "Upper Third" }, .{
            .value = "center",
            .label = "Center",
        } },
        .width => &.{
            .{ .value = "narrow", .label = "Narrow" },
            .{ .value = "default", .label = "Default" },
            .{ .value = "wide", .label = "Wide" },
        },
        .height => &.{
            .{ .value = "short", .label = "Short" },
            .{ .value = "default", .label = "Default" },
            .{ .value = "tall", .label = "Tall" },
        },
        .density => &.{
            .{ .value = "compact", .label = "Compact" },
            .{ .value = "default", .label = "Default" },
            .{ .value = "comfortable", .label = "Comfortable" },
        },
        .opacity => &.{
            .{ .value = "100", .label = "100% (Opaque)" },
            .{ .value = "97", .label = "97%" },
            .{ .value = "90", .label = "90%" },
            .{ .value = "80", .label = "80%" },
        },
        .clipboard_keep => &.{
            .{ .value = "100", .label = "100 entries" },
            .{ .value = "500", .label = "500 entries" },
            .{ .value = "1000", .label = "1,000 entries" },
            .{ .value = "5000", .label = "5,000 entries" },
        },
        .icon_theme => iconThemes(a),
        .terminal, .editor => blk: {
            var out: std.ArrayList(Option) = .empty;
            const list: []const [2][:0]const u8 = if (ch == .terminal) &settings_mod.terminals else &settings_mod.editors;
            const auto_cmd: []const u8 = if (ch == .terminal) run.autoTerminal() else run.autoEditor();
            const auto_base = std.Io.Dir.path.basename(auto_cmd);
            var auto_name: []const u8 = auto_base;
            for (list) |e| if (std.mem.eql(u8, e[0], auto_base)) {
                auto_name = e[1];
            };
            out.append(a, .{
                .value = "",
                .label = a.printSentinel("Automatic ({s})", .{auto_name}, 0) catch "Automatic",
            }) catch {};
            for (list) |e| if (proc.have(e[0])) out.append(a, .{
                .value = e[0],
                .label = e[1],
            }) catch {};
            break :blk out.items;
        },
    };
}

/// "Automatic", then the icon themes installed (folders under the icon
/// directories with an index.theme that lists icon directories: cursor
/// themes have none), by their names.
fn iconThemes(a: std.mem.Allocator) []const Option {
    var out: std.ArrayList(Option) = .empty;
    out.append(a, .{ .value = "", .label = "Automatic (the desktop's)" }) catch return out.items;
    var roots: std.ArrayList([]const u8) = .empty;
    const home = std.mem.span(c.g_get_home_dir());
    roots.append(a, a.print("{s}/.icons", .{home}) catch "") catch {};
    roots.append(
        a,
        a.print("{s}/icons", .{std.mem.span(c.g_get_user_data_dir())}) catch "",
    ) catch {};
    var dirs = c.g_get_system_data_dirs();
    while (dirs[0]) |d| : (dirs += 1) roots.append(
        a,
        a.print("{s}/icons", .{std.mem.span(d)}) catch "",
    ) catch {};
    for (roots.items) |root| {
        const rz = a.dupeSentinel(u8, root, 0) catch continue;
        const dir = c.g_dir_open(rz.ptr, 0, null) orelse continue;
        defer c.g_dir_close(dir);
        while (c.g_dir_read_name(dir)) |n| {
            const name = std.mem.span(n);
            if (std.mem.eql(u8, name, "hicolor") or std.mem.eql(u8, name, "default")) continue;
            var dup = false;
            for (out.items) |o| dup = dup or std.mem.eql(u8, o.value, name);
            if (dup) continue;
            const index_path = a.printSentinel(
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
            out.append(a, .{
                .value = a.dupeSentinel(u8, name, 0) catch continue,
                .label = a.dupeSentinel(u8, label, 0) catch continue,
            }) catch break;
        }
    }
    return out.items;
}

/// The current value of a choice, as shown.
pub fn choiceLabel(ui: *Ui, a: std.mem.Allocator, ch: settings_mod.Choice) [:0]const u8 {
    var buf: [32]u8 = undefined;
    const value = ui.settings.choiceValue(ch, &buf);
    for (choiceOptions(ui, a, ch)) |o| if (std.mem.eql(u8, o.value, value)) return o.label;
    // Set by hand to something not offered (not installed, unusual value).
    return a.dupeSentinel(u8, value, 0) catch "";
}

pub fn chooseTitle(ch: settings_mod.Choice) []const u8 {
    return switch (ch) {
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

pub fn setChoosing(ui: *Ui, next: Ui.Choosing) void {
    if (ui.choosing == .file) {
        ui.gpa.free(ui.choosing.file.path);
        ui.gpa.free(ui.choosing.file.mime);
    }
    ui.choosing = next;
    // A name too long for the buffer is cut (on a character boundary), not
    // dropped: an empty title helped nobody.
    var w: std.Io.Writer = .fixed(ui.choose_title[0 .. ui.choose_title.len - 1]);
    switch (next) {
        .none => {},
        .setting => |ch| w.writeAll(chooseTitle(ch)) catch {},
        .kind => |k| w.print("Open {s} With", .{k.title()}) catch {},
        .file => |f| w.print("Open {s} With", .{std.Io.Dir.path.basename(f.path)}) catch {},
        .pref => |i| if (ui.ext_registry) |reg| if (i < reg.prefs.len) w.writeAll(
            reg.prefs[i].title,
        ) catch {},
        .field => |i| if (form_view.field(ui, i)) |f| w.writeAll(f.title) catch {},
    }
    const n = core.utf8.validPrefix(w.buffered()).len;
    ui.choose_title[n] = 0;
}

pub fn chooseCandidates(ui: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    switch (ui.choosing) {
        .none => {},
        .setting => |ch| {
            var buf: [32]u8 = undefined;
            const current = ui.settings.choiceValue(ch, &buf);
            for (choiceOptions(ui, a, ch)) |o| out.append(a, pickRow(a, o, current) catch break) catch break;
        },
        .kind => |k| appOptions(
            ui,
            a,
            &out,
            k.sampleMime(),
            ui.settings.open_with.get(@tagName(k)),
            false,
        ),
        .file => |f| appOptions(ui, a, &out, f.mime, null, true),
        .pref => |i| prefs_view.choiceCandidates(ui, a, &out, i),
        .field => |i| form_view.choiceCandidates(ui, a, &out, i),
    }
    return out.items;
}

/// Apps for `mime`: those that declare it first, then every other app (any
/// app can be told to open anything). `open_now`: rows open the file
/// instead of saving a choice.
pub fn appOptions(
    self: *Ui,
    a: std.mem.Allocator,
    out: *std.ArrayList(Item),
    mime: [:0]const u8,
    current: ?[]const u8,
    open_now: bool,
) void {
    if (!open_now) {
        const def = c.g_app_info_get_default_for_type(mime, 0);
        defer if (def) |d| c.g_object_unref(d);
        const name: [:0]const u8 = if (def) |d| (a.dupeSentinel(
            u8,
            std.mem.span(c.g_app_info_get_display_name(d) orelse ""),
            0,
        ) catch "") else "none set";
        out.append(a, .{
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
        while (node) |n| : (node = n.next) {
            const info: *c.GAppInfo = @ptrCast(@alignCast(n.data));
            const id = a.dupe(u8, std.mem.span(
                c.g_app_info_get_id(info) orelse continue,
            )) catch continue;
            declared.put(a, id, {}) catch {};
        }
    }
    for ([_]bool{ true, false }) |want_declared| {
        for (self.apps.items) |app| {
            const info = app.action.app;
            const id = std.mem.span(c.g_app_info_get_id(info) orelse continue);
            if (declared.contains(id) != want_declared) continue;
            const idz = a.dupeSentinel(u8, id, 0) catch continue;
            out.append(a, .{
                .key = a.print("pick:{s}", .{id}) catch "",
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

pub fn appName(ui: *Ui, a: std.mem.Allocator, id: []const u8) [:0]const u8 {
    for (ui.apps.items) |app| {
        const aid = std.mem.span(c.g_app_info_get_id(app.action.app) orelse continue);
        if (std.mem.eql(u8, aid, id)) return app.title;
    }
    return a.dupeSentinel(u8, id, 0) catch "";
}

pub fn defaultAppsSummary(ui: *Ui, a: std.mem.Allocator) [:0]const u8 {
    const n = ui.settings.open_with.count();
    if (n == 0) return "System Defaults";
    return a.printSentinel("{d} chosen", .{n}, 0) catch "";
}

pub fn defaultAppsCandidates(ui: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (std.enums.values(Kind)) |k| {
        const chosen = ui.settings.open_with.get(@tagName(k));
        const accessory: [:0]const u8 = if (chosen) |id| appName(ui, a, id) else blk: {
            const def = c.g_app_info_get_default_for_type(
                k.sampleMime(),
                0,
            ) orelse break :blk "System Default";
            defer c.g_object_unref(def);
            break :blk a.printSentinel(
                "System: {s}",
                .{c.g_app_info_get_display_name(def) orelse ""},
                0,
            ) catch "";
        };
        out.append(a, .{
            .key = a.print("kind:{t}", .{k}) catch "",
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
    var it = ui.settings.open_with.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.*[0] != '.') continue;
        out.append(a, .{
            .section = "Extensions (edit in the settings file)",
            .title = a.dupeSentinel(u8, e.key_ptr.*, 0) catch continue,
            .accessory = appName(ui, a, e.value_ptr.*),
            .icon = .{ .tile = .{ .name = "text-x-generic-symbolic", .color = .blue } },
            .action = .{ .setting = .open_file },
        }) catch break;
    }
    return out.items;
}

pub fn themeCandidates(ui: *Ui, a: std.mem.Allocator) []Item {
    var out: std.ArrayList(Item) = .empty;
    styleCandidates(ui, a, &out);
    const dark = ui.preferDark();
    const auto_theme = themes.find(themes.auto_id, dark);
    out.append(a, .{
        .key = "theme:auto",
        .title = "Automatic",
        .subtitle = "Lumen Dark or Light, following the system",
        .accessory = if (std.mem.eql(u8, ui.settings.theme, themes.auto_id)) "✓" else "",
        .icon = swatchOf(auto_theme),
        .action = .{ .setting = .{ .theme = themes.auto_id } },
    }) catch {};
    for ([_]bool{ true, false }) |want_dark| {
        for (&themes.all) |*t| {
            if (t.dark != want_dark) continue;
            out.append(a, themeItem(ui, a, t, if (want_dark) "Dark" else "Light")) catch break;
        }
    }
    const style_section = a.printSentinel(
        "{s} Themes",
        .{styleTitle(a, ui.settings.style)},
        0,
    ) catch "Style Themes";
    for (themes.custom) |*t| if (t.from_style) out.append(
        a,
        themeItem(ui, a, t, style_section),
    ) catch break;
    for (themes.custom) |*t| if (!t.from_style) out.append(
        a,
        themeItem(ui, a, t, "Your Themes"),
    ) catch break;
    return out.items;
}

/// Styles: the built-in ones, then "Custom", the folders in
/// ~/.config/lumen/styles (one named like a built-in style replaces it).
fn styleCandidates(ui: *Ui, a: std.mem.Allocator, out: *std.ArrayList(Item)) void {
    const custom = customStyles(ui, a);
    const current = if (ui.settings.style.len > 0) ui.settings.style else "lumen";
    for (&styles.all) |*s| {
        if (has(custom, s.id)) continue;
        out.append(a, styleItem(a, s.id, s.name, s.description, "Styles", current)) catch return;
    }
    for (custom) |name| {
        const sub = a.printSentinel("~/.config/lumen/styles/{s}", .{name}, 0) catch "";
        out.append(a, styleItem(a, name, titleOf(a, name), sub, "Custom", current)) catch return;
    }
}

/// A style's name: the built-in one's, else its folder's ("my-style" is
/// "My Style").
fn styleTitle(a: std.mem.Allocator, id: []const u8) [:0]const u8 {
    if (id.len == 0) return "Lumen";
    if (styles.find(id)) |s| return s.name;
    return titleOf(a, id);
}

fn titleOf(a: std.mem.Allocator, name: []const u8) [:0]const u8 {
    const out = a.allocSentinel(u8, name.len, 0) catch return "";
    var start = true;
    for (name, 0..) |ch, i| {
        out[i] = if (ch == '-' or ch == '_') ' ' else if (start) std.ascii.toUpper(ch) else ch;
        start = ch == '-' or ch == '_';
    }
    return out;
}

fn has(names: []const [:0]const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn styleItem(
    a: std.mem.Allocator,
    id: []const u8,
    name: [:0]const u8,
    description: [:0]const u8,
    section: [:0]const u8,
    current: []const u8,
) Item {
    return .{
        .key = a.print("style:{s}", .{id}) catch "",
        .section = section,
        .title = name,
        .subtitle = description,
        .accessory = if (std.mem.eql(u8, current, id)) "✓" else "",
        .icon = .{ .tile = .{ .name = "applications-graphics-symbolic", .color = .purple } },
        .action = .{ .setting = .{ .style = id } },
    };
}

/// The folders in ~/.config/lumen/styles, sorted.
fn customStyles(ui: *Ui, a: std.mem.Allocator) []const [:0]const u8 {
    const path = a.printSentinel("{s}/styles", .{ui.config_dir}, 0) catch return &.{};
    return os.subdirs(a, path, settings_mod.isToken);
}

fn themeItem(ui: *Ui, a: std.mem.Allocator, t: *const themes.Theme, section: [:0]const u8) Item {
    return .{
        .key = a.print("theme:{s}", .{t.id}) catch "",
        .section = section,
        .title = t.name,
        .accessory = if (std.mem.eql(u8, ui.settings.theme, t.id)) "✓" else "",
        .icon = swatchOf(t),
        .action = .{ .setting = .{ .theme = t.id } },
    };
}

pub fn swatchOf(t: *const themes.Theme) item_mod.Icon {
    return .{ .swatch = .{ .id = t.id, .bg = t.bg, .fg = t.fg, .accent = t.accent } };
}

/// Applies what a settings row does.
pub fn performSetting(ui: *Ui, s: item_mod.Setting, op: item_mod.Op) void {
    const locked: ?[]const u8 = switch (s) {
        .theme => "theme",
        .style => "style",
        else => settingName(s),
    };
    if (locked) |key| if (ui.overridden(key)) return ui.showFailure("Set in init.lua");
    switch (s) {
        .toggle => |t| {
            ui.settings.setToggle(t, !ui.settings.get(t));
            ui.saveSettings();
            ui.setReselect("set:{t}", .{t});
            ui.rebuild();
        },
        .choose => |ch| {
            setChoosing(ui, .{ .setting = ch });
            var buf: [32]u8 = undefined;
            ui.setReselect("pick:{s}", .{ui.settings.choiceValue(ch, &buf)});
            ui.navigate(.choose);
        },
        .kind => |k| {
            setChoosing(ui, .{ .kind = k });
            ui.setReselect("pick:{s}", .{ui.settings.open_with.get(@tagName(k)) orelse ""});
            ui.navigate(.choose);
        },
        .pick => |v| switch (ui.choosing) {
            .setting => |ch| {
                _ = ui.settings.setChoice(ch, v);
                ui.saveSettings();
                ui.goBack();
            },
            .kind => |k| {
                if (ui.settings.setOpenWith(@tagName(k), v)) ui.saveSettings() else |err| log.warn(
                    "default app for {t}: {t}",
                    .{ k, err },
                );
                ui.goBack();
            },
            .pref => |i| prefs_view.pick(ui, i, v),
            .field => |i| form_view.pick(ui, i, v),
            else => {},
        },
        .go => |v| {
            ui.reselect_len = 0;
            ui.navigate(v);
        },
        .theme => |id| {
            _ = ui.settings.set("theme", id);
            ui.saveSettings();
            ui.goBack();
        },
        .style => |id| {
            // Its CSS now, its Lua (layout, themes, lumen.set) on the reload.
            _ = ui.settings.set("style", id);
            ui.saveSettings();
            ui.style_defaults_pending = true;
            ext_view.syncStyle(ui);
            ui.setReselect("style:{s}", .{id});
            ui.rebuild();
        },
        .open_with => |id| {
            if (ui.choosing != .file) return;
            const f = ui.choosing.file;
            if (op == .always_use) {
                const name = std.Io.Dir.path.basename(f.path);
                var ebuf: [16]u8 = undefined;
                const key: []const u8 = if (core.file_kind.of(
                    f.mime,
                    name,
                    false,
                )) |k| @tagName(k) else core.file_kind.extKey(&ebuf, name);
                if (key.len > 0) {
                    if (ui.settings.setOpenWith(key, id)) ui.saveSettings() else |err| log.warn(
                        "default app for {s}: {t}",
                        .{ key, err },
                    );
                }
            }
            if (!run.openWith(f.path, id)) return;
            ui.hide();
        },
        .open_file => {
            // Write the defaults first: an empty editor helps nobody.
            if (os.info(ui.settings_path.ptr) == null) ui.saveSettings();
            run.openFile(ui.actionCtx(), ui.settings_path, false);
            ui.hide();
        },
        .ext_prefs => |id| prefs_view.open(ui, id),
        .pref => |i| prefs_view.edit(ui, i),
        .save_input => prefs_view.saveInput(ui),
        .field => |i| form_view.edit(ui, i),
        .submit_form => form_view.submit(ui),
        .ext_open => |dir| {
            run.openFile(ui.actionCtx(), dir, true);
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
    defer if (guessed) |g| c.g_free(g);
    const mime = ui.gpa.dupeSentinel(
        u8,
        if (guessed) |g| std.mem.span(g) else "application/octet-stream",
        0,
    ) catch return;
    const owned = ui.gpa.dupeSentinel(u8, path, 0) catch {
        ui.gpa.free(mime);
        return;
    };
    setChoosing(ui, .{ .file = .{ .path = owned, .mime = mime } });
    ui.reselect_len = 0;
    ui.navigate(.choose);
}
