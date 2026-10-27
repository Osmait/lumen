//! Extension preferences in Settings: a row per extension that declares
//! some, a list of its preferences, and the input view text values are
//! typed in. Values go to the extension's preferences.json, which Lua reads
//! as `lumen.preferences`; saving reloads the extensions.

const std = @import("std");
const c = @import("c");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const Host = @import("../ext/Host.zig");
const index = @import("index");
const Ui = @import("Ui.zig");
const settings_view = @import("settings_view.zig");
const form_view = @import("form_view.zig");

const log = std.log.scoped(.prefs);

/// Settings > Extensions: one row per extension with preferences.
pub fn extensionRows(ui: *Ui, a: std.mem.Allocator, out: *std.ArrayList(Item)) void {
    const reg = ui.ext_registry orelse return;
    for (reg.prefs, 0..) |p, i| {
        // First preference of its extension only.
        if (i > 0 and std.mem.eql(u8, reg.prefs[i - 1].ext, p.ext)) continue;
        var n: usize = 0;
        for (reg.prefs) |q| n += @intFromBool(std.mem.eql(u8, q.ext, p.ext));
        out.append(a, .{
            .key = std.fmt.allocPrint(a, "set:ext:{s}", .{p.ext}) catch continue,
            .section = "Extensions",
            .title = p.ext_title,
            .accessory = std.fmt.allocPrintSentinel(a, "{d} {s}", .{ n, if (n == 1) "setting" else "settings" }, 0) catch "",
            .icon = .{ .tile = .{ .name = "application-x-addon-symbolic", .color = .purple } },
            .keywords = "extension preferences",
            .action = .{ .setting = .{ .ext_prefs = p.ext } },
        }) catch return;
    }
}

/// Opens the preferences of extension `id`.
pub fn open(ui: *Ui, id: []const u8) void {
    const n = @min(id.len, ui.prefs_ext.len);
    @memcpy(ui.prefs_ext[0..n], id[0..n]);
    ui.prefs_ext_len = n;
    ui.reselect_len = 0;
    ui.navigate(.prefs);
}

fn extId(ui: *Ui) []const u8 {
    return ui.prefs_ext[0..ui.prefs_ext_len];
}

pub fn title(ui: *Ui) [*:0]const u8 {
    const reg = ui.ext_registry orelse return "Extension";
    for (reg.prefs) |p| if (std.mem.eql(u8, p.ext, extId(ui))) return p.ext_title.ptr;
    return "Extension";
}

/// The open extension's preferences.
pub fn candidates(ui: *Ui, a: std.mem.Allocator) []Item {
    const reg = ui.ext_registry orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (reg.prefs, 0..) |p, i| {
        if (!std.mem.eql(u8, p.ext, extId(ui))) continue;
        out.append(a, .{
            .key = std.fmt.allocPrint(a, "pref:{s}", .{p.name}) catch continue,
            .title = p.title,
            .subtitle = p.description,
            .accessory = display(a, &p, current(a, &p)),
            .icon = iconOf(p.kind),
            .action = .{ .setting = .{ .pref = @intCast(i) } },
        }) catch break;
    }
    return out.items;
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
        .text => if (value.len == 0) "Not set" else a.dupeSentinel(u8, value[0..@min(value.len, 40)], 0) catch "",
        .password => if (value.len == 0) "Not set" else "••••••••",
    };
}

/// The saved value as text ("true"/"false" for toggles), else the default.
pub fn current(a: std.mem.Allocator, p: *const Host.Pref) []const u8 {
    const buf = a.alloc(u8, 64 * 1024) catch return p.default;
    const text = index.sys.readHead(p.file.ptr, buf);
    if (text.len == 0) return p.default;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return p.default;
    if (parsed != .object) return p.default;
    const v = parsed.object.get(p.name) orelse return p.default;
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
    const value = current(arena.allocator(), p);
    switch (p.kind) {
        .toggle => {
            save(ui, p, .{ .bool = !std.mem.eql(u8, value, "true") });
            ui.setReselect("pref:{s}", .{p.name});
            ui.rebuild();
        },
        .choice => {
            settings_view.setChoosing(ui, .{ .pref = i });
            ui.setReselect("pick:{s}", .{value});
            ui.navigate(.choose);
        },
        .text, .password => {
            ui.input = .{ .pref = i };
            ui.navigate(.input);
            // After the view change, which clears the search bar.
            const z = arena.allocator().dupeSentinel(u8, value, 0) catch return;
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
    for (p.choices) |ch| {
        out.append(a, .{
            .key = std.fmt.allocPrint(a, "pick:{s}", .{ch.value}) catch continue,
            .title = ch.label,
            .accessory = if (std.mem.eql(u8, ch.value, value)) "✓" else "",
            .icon = .{ .tile = .{ .name = "object-select-symbolic", .color = .gray } },
            .action = .{ .setting = .{ .pick = ch.value } },
        }) catch return;
    }
}

/// A value picked in the choose view.
pub fn pick(ui: *Ui, i: u16, value: []const u8) void {
    const reg = ui.ext_registry orelse return;
    if (i >= reg.prefs.len) return;
    save(ui, &reg.prefs[i], .{ .string = value });
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
        .title = if (ui.input == .field) std.fmt.allocPrintSentinel(a, "Set {s}", .{p.title}, 0) catch "Set" else std.fmt.allocPrintSentinel(a, "Save {s}", .{p.title}, 0) catch "Save",
        .subtitle = if (p.description.len > 0) p.description else "Type the value above",
        .icon = iconOf(p.kind),
        .action = .{ .setting = .save_input },
    };
    return row;
}

pub fn saveInput(ui: *Ui) void {
    const p = inputPref(ui) orelse return;
    switch (ui.input) {
        .pref => save(ui, p, .{ .string = ui.query() }),
        .field => |i| form_view.setValue(ui, i, ui.query()),
    }
    ui.goBack();
}

/// Writes one value into the extension's preferences.json (atomically,
/// owner-only), then reloads the extensions so Lua sees it.
fn save(ui: *Ui, p: *const Host.Pref, value: std.json.Value) void {
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = a.alloc(u8, 64 * 1024) catch return;
    const text = index.sys.readHead(p.file.ptr, buf);
    var obj: std.json.ObjectMap = .empty;
    if (text.len > 0) if (std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})) |v| {
        if (v == .object) obj = v.object;
    } else |_| {};
    obj.put(a, p.name, value) catch return;
    const json = std.json.Stringify.valueAlloc(a, std.json.Value{ .object = obj }, .{ .whitespace = .indent_2 }) catch return;
    if (std.mem.findScalarLast(u8, p.file, '/')) |s| index.sys.mkdirP(p.file[0..s]);
    index.sys.writeFileAtomic(p.file, json) catch |err| {
        log.warn("{s}: {t}", .{ p.file, err });
        ui.showFailure("Could not save the setting");
        return;
    };
    if (ui.ext_host) |h| h.reload();
}
