//! Extension preferences in Settings: a row per extension that declares
//! some, a list of its preferences, and the input view text values are
//! typed in. Values go to the extension's preferences.json, which Lua reads
//! as `lumen.preferences`; saving reloads the extensions.

const std = @import("std");
const c = @import("c");
const gtk = @import("gtk.zig");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const Host = @import("../ext/Host.zig");
const os = @import("os");
const Ui = @import("Ui.zig");
const settings_view = @import("settings_view.zig");
const form_view = @import("form_view.zig");

const log = std.log.scoped(.prefs);

/// Settings > Extensions: every installed extension, those that failed to
/// load too (to update or remove them).
pub fn extensionRows(ui: *Ui, arena: std.mem.Allocator, out: *std.ArrayList(Item)) void {
    const registry = ui.ext_registry orelse return;
    for (registry.extensions) |extension| {
        var count: usize = 0;
        for (registry.prefs) |query| {
            count += @intFromBool(std.mem.eql(u8, query.ext, extension.id));
        }
        out.append(arena, .{
            .key = arena.print("set:ext:{s}", .{extension.id}) catch continue,
            .section = "Extensions",
            .title = extension.title,
            .subtitle = extension.id,
            .accessory = (if (count > 0)
                arena.printSentinel(
                    "{d} {s}",
                    .{ count, if (count == 1) "setting" else "settings" },
                    0,
                )
            else
                arena.printSentinel(
                    "{d} {s}",
                    .{ extension.commands, if (extension.commands == 1) "command" else "commands" },
                    0,
                )) catch "",
            .icon = .{ .tile = .{ .name = "application-x-addon-symbolic", .color = .purple } },
            .keywords = "extension preferences update uninstall",
            .action = .{ .setting = .{ .ext_prefs = extension.id } },
        }) catch return;
    }
    for (registry.problems) |problem| {
        if (std.mem.eql(u8, problem.ext, Host.config_extension_id)) continue;
        out.append(arena, .{
            .key = arena.print("set:ext:{s}", .{problem.ext}) catch continue,
            .section = "Extensions",
            .title = problem.ext,
            .subtitle = "Failed to load",
            .icon = .{ .tile = .{ .name = "dialog-warning-symbolic", .color = .red } },
            .keywords = "extension error update uninstall",
            .action = .{ .setting = .{ .ext_prefs = problem.ext } },
        }) catch return;
    }
}

/// Opens the preferences of extension `id`.
pub fn open(ui: *Ui, id: []const u8) void {
    ui.prefs_ext.set(id);
    ui.reselect.clear();
    ui.navigate(.prefs);
}

fn extId(ui: *Ui) []const u8 {
    return ui.prefs_ext.slice();
}

pub fn title(ui: *Ui) [*:0]const u8 {
    const registry = ui.ext_registry orelse return "Extension";
    for (registry.extensions) |extension| {
        if (std.mem.eql(u8, extension.id, extId(ui))) return extension.title.ptr;
    }
    for (registry.problems) |problem| {
        if (std.mem.eql(u8, problem.ext, extId(ui))) return problem.ext.ptr;
    }
    return "Extension";
}

/// The open extension's preferences.
pub fn candidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    const registry = ui.ext_registry orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (registry.prefs, 0..) |preference, i| {
        if (!std.mem.eql(u8, preference.ext, extId(ui))) continue;
        out.append(arena, .{
            .key = arena.print("pref:{s}", .{preference.name}) catch continue,
            .section = "Preferences",
            .title = preference.title,
            .subtitle = preference.description,
            .accessory = display(arena, &preference, current(arena, &preference)),
            .icon = iconOf(preference.kind),
            .action = .{ .setting = .{ .pref = .from(i) } },
        }) catch break;
    }
    manageRows(ui, arena, &out);
    return out.items;
}

/// The extension's folder, git pull when it is a checkout, removal.
fn manageRows(ui: *Ui, arena: std.mem.Allocator, out: *std.ArrayList(Item)) void {
    const id = arena.dupeSentinel(u8, extId(ui), 0) catch return;
    const dir = arena.printSentinel("{s}/extensions/{s}", .{ ui.config_dir, id }, 0) catch return;
    const git = arena.printSentinel("{s}/.git", .{dir}, 0) catch return;
    out.append(arena, .{
        .key = "manage:open",
        .section = "Manage",
        .title = "Open Folder",
        .subtitle = dir,
        .icon = .{ .tile = .{ .name = "folder-open-symbolic", .color = .blue } },
        .action = .{ .setting = .{ .ext_open = dir } },
    }) catch return;
    if (os.info(git) != null) out.append(arena, .{
        .key = "manage:update",
        .section = "Manage",
        .title = "Update",
        .subtitle = "git pull",
        .icon = .{ .tile = .{ .name = "view-refresh-symbolic", .color = .green } },
        .action = .{ .setting = .{ .ext_update = id } },
    }) catch return;
    out.append(arena, .{
        .key = "manage:uninstall",
        .section = "Manage",
        .title = "Uninstall",
        .subtitle = "Removes its folder",
        .icon = .{ .tile = .{ .name = "user-trash-symbolic", .color = .red } },
        .confirm = true,
        .action = .{ .setting = .{ .ext_uninstall = id } },
    }) catch return;
}

pub fn iconOf(kind: Host.PrefKind) item_mod.Icon {
    return switch (kind) {
        .toggle => .{ .tile = .{ .name = "emblem-ok-symbolic", .color = .green } },
        .choice => .{ .tile = .{ .name = "view-list-symbolic", .color = .blue } },
        .text => .{ .tile = .{ .name = "document-edit-symbolic", .color = .orange } },
        .password => .{ .tile = .{ .name = "dialog-password-symbolic", .color = .red } },
    };
}

/// A text preference shows this much of its value on its row.
const text_value_bytes_shown = 40;

/// How a value shows on the right of its row.
pub fn display(
    arena: std.mem.Allocator,
    preference: *const Host.Pref,
    value: []const u8,
) [:0]const u8 {
    return switch (preference.kind) {
        .toggle => if (Host.toggleIsOn(value)) "On" else "Off",
        .choice => for (preference.choices) |choice| {
            if (std.mem.eql(u8, choice.value, value)) break choice.label;
        } else arena.dupeSentinel(u8, value, 0) catch "",
        .text => if (value.len == 0) "Not set" else arena.dupeSentinel(
            u8,
            core.utf8.validPrefix(value[0..@min(value.len, text_value_bytes_shown)]),
            0,
        ) catch "",
        .password => if (value.len == 0) "Not set" else "••••••••",
    };
}

/// The saved value as text ("true"/"false" for toggles), else the default.
/// An extension's preferences.json: absent is empty; anything else that
/// does not read as one JSON object is `unreadable`, never treated as empty
/// (saving over it would lose every other value).
const Stored = union(enum) { absent, unreadable, values: std.json.ObjectMap };

/// Lumen never writes a preferences file this large, so a larger one is
/// refused instead of parsed.
const prefs_bytes_max = 1 << 20;

fn readStored(arena: std.mem.Allocator, file: [:0]const u8) Stored {
    if (os.info(file.ptr) == null) return .absent;
    var contents: ?[*:0]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(file.ptr, &contents, &len, null) == 0) return .unreadable;
    defer c.g_free(contents);
    if (len > prefs_bytes_max) return .unreadable;
    const text = contents.?[0..len];
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .absent;
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        text,
        .{ .allocate = .alloc_always },
    ) catch return .unreadable;
    return if (parsed == .object) .{ .values = parsed.object } else .unreadable;
}

pub fn current(arena: std.mem.Allocator, preference: *const Host.Pref) []const u8 {
    const stored = switch (readStored(arena, preference.file)) {
        .values => |values| values,
        .absent, .unreadable => return preference.default,
    };
    const stored_value = stored.get(preference.name) orelse return preference.default;
    return switch (stored_value) {
        .bool => |flag| Host.toggleText(flag),
        .string => |text| text,
        else => preference.default,
    };
}

/// Enter on a preference: flips a toggle, lists a choice's values, or
/// opens the input view for text.
pub fn edit(ui: *Ui, pref_index: Host.PrefIndex) void {
    const registry = ui.ext_registry orelse return;
    const preference = registry.pref(pref_index) orelse return;
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    editValue(ui, .{ .pref = pref_index }, preference, current(arena.allocator(), preference));
}

/// Enter on a preference or a form field whose value is `value`: flips a
/// toggle, lists a choice's values, or opens the input view for text.
pub fn editValue(ui: *Ui, target: Ui.Edited, preference: *const Host.Pref, value: []const u8) void {
    switch (preference.kind) {
        .toggle => {
            const on = !Host.toggleIsOn(value);
            switch (target) {
                // The value was not saved; the row's hint already says why.
                .pref => if (!save(ui, preference, .{ .bool = on })) return,
                .field => |field_index| {
                    form_view.setValue(ui, field_index, Host.toggleText(on));
                },
            }
            // Row keys are "pref:<name>" and "field:<name>".
            ui.setReselect("{t}:{s}", .{ target, preference.name });
            ui.rebuild();
        },
        .choice => {
            settings_view.setChoosing(ui, switch (target) {
                .pref => |pref_index| .{ .pref = pref_index },
                .field => |field_index| .{ .field = field_index },
            });
            ui.setReselect("pick:{s}", .{value});
            ui.navigate(.choose);
        },
        .text, .password => {
            ui.input = target;
            ui.navigate(.input);
            // After the view change, which clears the search bar.
            const value_z = ui.gpa.dupeSentinel(u8, value, 0) catch return;
            defer ui.gpa.free(value_z);
            c.gtk_editable_set_text(gtk.editable(ui.search_bar.entry), value_z.ptr);
            c.gtk_editable_set_position(gtk.editable(ui.search_bar.entry), -1);
        },
    }
}

/// The values of a choice preference, for the choose view.
pub fn choiceCandidates(
    ui: *Ui,
    arena: std.mem.Allocator,
    out: *std.ArrayList(Item),
    pref_index: Host.PrefIndex,
) void {
    const registry = ui.ext_registry orelse return;
    const preference = registry.pref(pref_index) orelse return;
    const value = current(arena, preference);
    for (preference.choices) |choice| out.append(
        arena,
        settings_view.pickRow(arena, choice, value) catch return,
    ) catch return;
}

/// A value picked in the choose view.
pub fn pick(ui: *Ui, pref_index: Host.PrefIndex, value: []const u8) void {
    const registry = ui.ext_registry orelse return;
    const preference = registry.pref(pref_index) orelse return;
    if (!save(ui, preference, .{ .string = value })) return;
    ui.goBack();
}

pub fn inputTitle(ui: *Ui) [*:0]const u8 {
    const preference = inputPref(ui) orelse return "Value";
    return preference.title.ptr;
}

/// What the input view edits: a preference, or a field of the open form.
fn inputPref(ui: *Ui) ?*const Host.Pref {
    switch (ui.input) {
        .pref => |pref_index| {
            const registry = ui.ext_registry orelse return null;
            return registry.pref(pref_index);
        },
        .field => |field_index| return form_view.field(ui, field_index),
    }
}

pub fn isPassword(ui: *Ui) bool {
    const preference = inputPref(ui) orelse return false;
    return preference.kind == .password;
}

/// The input view's one row: Enter saves what is typed.
pub fn inputCandidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    const preference = inputPref(ui) orelse return &.{};
    const row = arena.alloc(Item, 1) catch return &.{};
    // A form's field is only set until the form is submitted; a
    // preference is saved at once.
    const verb: [:0]const u8 = if (ui.input == .field) "Set" else "Save";
    row[0] = .{
        .key = "input:save",
        .title = arena.printSentinel("{s} {s}", .{ verb, preference.title }, 0) catch verb,
        .subtitle = if (preference.description.len > 0)
            preference.description
        else
            "Type the value above",
        .icon = iconOf(preference.kind),
        .action = .{ .setting = .save_input },
    };
    return row;
}

pub fn saveInput(ui: *Ui) void {
    const preference = inputPref(ui) orelse return;
    switch (ui.input) {
        .pref => if (!save(ui, preference, .{ .string = ui.query() })) return,
        .field => |field_index| form_view.setValue(ui, field_index, ui.query()),
    }
    ui.goBack();
}

/// Writes one value into the extension's preferences.json (atomically,
/// owner-only), then reloads the extensions so Lua sees it. False when it
/// was not saved; the selected row says why.
fn save(ui: *Ui, preference: *const Host.Pref, value: std.json.Value) bool {
    var arena_instance: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    var obj: std.json.ObjectMap = switch (readStored(arena, preference.file)) {
        .absent => .empty,
        .values => |values| values,
        .unreadable => {
            log.warn("{s}: not a JSON object Lumen can read; not overwritten", .{preference.file});
            ui.showFailure("Could not read the preferences file");
            return false;
        },
    };
    obj.put(arena, preference.name, value) catch {
        ui.showFailure("Could not save the setting");
        return false;
    };
    const json = std.json.Stringify.valueAlloc(
        arena,
        std.json.Value{ .object = obj },
        .{ .whitespace = .indent_2 },
    ) catch {
        ui.showFailure("Could not save the setting");
        return false;
    };
    if (std.mem.findScalarLast(u8, preference.file, '/')) |slash| {
        os.mkdirP(preference.file[0..slash]) catch |err| {
            log.warn("{s}: {t}", .{ preference.file[0..slash], err });
            ui.showFailure("Could not save the setting");
            return false;
        };
    }
    os.writeFileAtomic(preference.file, json) catch |err| {
        log.warn("{s}: {t}", .{ preference.file, err });
        ui.showFailure("Could not save the setting");
        return false;
    };
    if (ui.ext_host) |host| host.reload();
    return true;
}
