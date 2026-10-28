//! Extension preferences in Settings: a row per extension that declares
//! some, a list of its preferences, and the input view text values are
//! typed in. Values go to the extension's preferences.json, which Lua reads
//! as `lumen.preferences`; saving reloads the extensions.

const std = @import("std");
const c = @import("c");
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
pub fn extensionRows(ui: *Ui, a: std.mem.Allocator, out: *std.ArrayList(Item)) void {
    const reg = ui.ext_registry orelse return;
    for (reg.extensions) |e| {
        var n: usize = 0;
        for (reg.prefs) |q| n += @intFromBool(std.mem.eql(u8, q.ext, e.id));
        out.append(a, .{
            .key = a.print("set:ext:{s}", .{e.id}) catch continue,
            .section = "Extensions",
            .title = e.title,
            .subtitle = e.id,
            .accessory = (if (n > 0)
                a.printSentinel("{d} {s}", .{ n, if (n == 1) "setting" else "settings" }, 0)
            else
                a.printSentinel(
                    "{d} {s}",
                    .{ e.commands, if (e.commands == 1) "command" else "commands" },
                    0,
                )) catch "",
            .icon = .{ .tile = .{ .name = "application-x-addon-symbolic", .color = .purple } },
            .keywords = "extension preferences update uninstall",
            .action = .{ .setting = .{ .ext_prefs = e.id } },
        }) catch return;
    }
    for (reg.problems) |p| {
        if (std.mem.eql(u8, p.ext, "config")) continue;
        out.append(a, .{
            .key = a.print("set:ext:{s}", .{p.ext}) catch continue,
            .section = "Extensions",
            .title = p.ext,
            .subtitle = "Failed to load",
            .icon = .{ .tile = .{ .name = "dialog-warning-symbolic", .color = .red } },
            .keywords = "extension error update uninstall",
            .action = .{ .setting = .{ .ext_prefs = p.ext } },
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
    const reg = ui.ext_registry orelse return "Extension";
    for (reg.extensions) |e| if (std.mem.eql(u8, e.id, extId(ui))) return e.title.ptr;
    for (reg.problems) |p| if (std.mem.eql(u8, p.ext, extId(ui))) return p.ext.ptr;
    return "Extension";
}

/// The open extension's preferences.
pub fn candidates(ui: *Ui, a: std.mem.Allocator) []Item {
    const reg = ui.ext_registry orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (reg.prefs, 0..) |p, i| {
        if (!std.mem.eql(u8, p.ext, extId(ui))) continue;
        out.append(a, .{
            .key = a.print("pref:{s}", .{p.name}) catch continue,
            .section = "Preferences",
            .title = p.title,
            .subtitle = p.description,
            .accessory = display(a, &p, current(a, &p)),
            .icon = iconOf(p.kind),
            .action = .{ .setting = .{ .pref = @intCast(i) } },
        }) catch break;
    }
    manageRows(ui, a, &out);
    return out.items;
}

/// The extension's folder, git pull when it is a checkout, removal.
fn manageRows(ui: *Ui, a: std.mem.Allocator, out: *std.ArrayList(Item)) void {
    const id = a.dupeSentinel(u8, extId(ui), 0) catch return;
    const dir = a.printSentinel("{s}/extensions/{s}", .{ ui.config_dir, id }, 0) catch return;
    const git = a.printSentinel("{s}/.git", .{dir}, 0) catch return;
    out.append(a, .{
        .key = "manage:open",
        .section = "Manage",
        .title = "Open Folder",
        .subtitle = dir,
        .icon = .{ .tile = .{ .name = "folder-open-symbolic", .color = .blue } },
        .action = .{ .setting = .{ .ext_open = dir } },
    }) catch return;
    if (os.info(git) != null) out.append(a, .{
        .key = "manage:update",
        .section = "Manage",
        .title = "Update",
        .subtitle = "git pull",
        .icon = .{ .tile = .{ .name = "view-refresh-symbolic", .color = .green } },
        .action = .{ .setting = .{ .ext_update = id } },
    }) catch return;
    out.append(a, .{
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

/// How a value shows on the right of its row.
pub fn display(a: std.mem.Allocator, p: *const Host.Pref, value: []const u8) [:0]const u8 {
    return switch (p.kind) {
        .toggle => if (std.mem.eql(u8, value, "true")) "On" else "Off",
        .choice => for (p.choices) |ch| {
            if (std.mem.eql(u8, ch.value, value)) break ch.label;
        } else a.dupeSentinel(u8, value, 0) catch "",
        .text => if (value.len == 0) "Not set" else a.dupeSentinel(
            u8,
            value[0..@min(value.len, 40)],
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

/// Larger is not a preferences file Lumen wrote.
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
    const v = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        text,
        .{ .allocate = .alloc_always },
    ) catch return .unreadable;
    return if (v == .object) .{ .values = v.object } else .unreadable;
}

pub fn current(a: std.mem.Allocator, p: *const Host.Pref) []const u8 {
    const stored = switch (readStored(a, p.file)) {
        .values => |o| o,
        .absent, .unreadable => return p.default,
    };
    const v = stored.get(p.name) orelse return p.default;
    return switch (v) {
        .bool => |b| if (b) "true" else "false",
        .string => |s| s,
        else => p.default,
    };
}

/// Enter on a preference: flips a toggle, lists a choice's values, or
/// opens the input view for text.
pub fn edit(ui: *Ui, i: u16) void {
    const reg = ui.ext_registry orelse return;
    if (i >= reg.prefs.len) return;
    const p = &reg.prefs[i];
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    editValue(ui, .{ .pref = i }, p, current(arena.allocator(), p));
}

/// Enter on a preference or a form field whose value is `value`: flips a
/// toggle, lists a choice's values, or opens the input view for text.
pub fn editValue(ui: *Ui, target: Ui.Edited, p: *const Host.Pref, value: []const u8) void {
    switch (p.kind) {
        .toggle => {
            const on = !std.mem.eql(u8, value, "true");
            switch (target) {
                // Not saved: the row keeps saying why.
                .pref => if (!save(ui, p, .{ .bool = on })) return,
                .field => |i| form_view.setValue(ui, i, if (on) "true" else "false"),
            }
            // Row keys are "pref:<name>" and "field:<name>".
            ui.setReselect("{t}:{s}", .{ target, p.name });
            ui.rebuild();
        },
        .choice => {
            settings_view.setChoosing(ui, switch (target) {
                .pref => |i| .{ .pref = i },
                .field => |i| .{ .field = i },
            });
            ui.setReselect("pick:{s}", .{value});
            ui.navigate(.choose);
        },
        .text, .password => {
            ui.input = target;
            ui.navigate(.input);
            // After the view change, which clears the search bar.
            const z = ui.gpa.dupeSentinel(u8, value, 0) catch return;
            defer ui.gpa.free(z);
            c.gtk_editable_set_text(@ptrCast(ui.entry), z.ptr);
            c.gtk_editable_set_position(@ptrCast(ui.entry), -1);
        },
    }
}

/// The values of a choice preference, for the choose view.
pub fn choiceCandidates(ui: *Ui, a: std.mem.Allocator, out: *std.ArrayList(Item), i: u16) void {
    const reg = ui.ext_registry orelse return;
    if (i >= reg.prefs.len) return;
    const p = &reg.prefs[i];
    const value = current(a, p);
    for (p.choices) |ch| out.append(
        a,
        settings_view.pickRow(a, ch, value) catch return,
    ) catch return;
}

/// A value picked in the choose view.
pub fn pick(ui: *Ui, i: u16, value: []const u8) void {
    const reg = ui.ext_registry orelse return;
    if (i >= reg.prefs.len) return;
    if (!save(ui, &reg.prefs[i], .{ .string = value })) return;
    ui.goBack();
}

pub fn inputTitle(ui: *Ui) [*:0]const u8 {
    const p = inputPref(ui) orelse return "Value";
    return p.title.ptr;
}

/// What the input view edits: a preference, or a field of the open form.
fn inputPref(ui: *Ui) ?*const Host.Pref {
    switch (ui.input) {
        .pref => |i| {
            const reg = ui.ext_registry orelse return null;
            return if (i < reg.prefs.len) &reg.prefs[i] else null;
        },
        .field => |i| return form_view.field(ui, i),
    }
}

pub fn isPassword(ui: *Ui) bool {
    const p = inputPref(ui) orelse return false;
    return p.kind == .password;
}

/// The input view's one row: Enter saves what is typed.
pub fn inputCandidates(ui: *Ui, a: std.mem.Allocator) []Item {
    const p = inputPref(ui) orelse return &.{};
    const row = a.alloc(Item, 1) catch return &.{};
    row[0] = .{
        .key = "input:save",
        .title = if (ui.input == .field) a.printSentinel(
            "Set {s}",
            .{p.title},
            0,
        ) catch "Set" else a.printSentinel(
            "Save {s}",
            .{p.title},
            0,
        ) catch "Save",
        .subtitle = if (p.description.len > 0) p.description else "Type the value above",
        .icon = iconOf(p.kind),
        .action = .{ .setting = .save_input },
    };
    return row;
}

pub fn saveInput(ui: *Ui) void {
    const p = inputPref(ui) orelse return;
    switch (ui.input) {
        .pref => if (!save(ui, p, .{ .string = ui.query() })) return,
        .field => |i| form_view.setValue(ui, i, ui.query()),
    }
    ui.goBack();
}

/// Writes one value into the extension's preferences.json (atomically,
/// owner-only), then reloads the extensions so Lua sees it. False when it
/// was not saved; the selected row says why.
fn save(ui: *Ui, p: *const Host.Pref, value: std.json.Value) bool {
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = switch (readStored(a, p.file)) {
        .absent => .empty,
        .values => |o| o,
        .unreadable => {
            log.warn("{s}: not a JSON object Lumen can read; not overwritten", .{p.file});
            ui.showFailure("Could not read the preferences file");
            return false;
        },
    };
    obj.put(a, p.name, value) catch {
        ui.showFailure("Could not save the setting");
        return false;
    };
    const json = std.json.Stringify.valueAlloc(
        a,
        std.json.Value{ .object = obj },
        .{ .whitespace = .indent_2 },
    ) catch {
        ui.showFailure("Could not save the setting");
        return false;
    };
    if (std.mem.findScalarLast(u8, p.file, '/')) |s| os.mkdirP(p.file[0..s]);
    os.writeFileAtomic(p.file, json) catch |err| {
        log.warn("{s}: {t}", .{ p.file, err });
        ui.showFailure("Could not save the setting");
        return false;
    };
    if (ui.ext_host) |h| h.reload();
    return true;
}
