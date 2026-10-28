//! An extension's form: a row per field showing its value, and a last row
//! that submits. Fields are edited like preferences: Enter flips a toggle,
//! lists a choice's values, or opens the input view for text. Submitting
//! calls the command's `submit(values)` on the extension thread.

const std = @import("std");
const c = @import("c");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const Host = @import("../ext/Host.zig");
const Ui = @import("Ui.zig");
const prefs_view = @import("prefs_view.zig");
const settings_view = @import("settings_view.zig");

fn command(ui: *Ui) ?*const Host.Command {
    const reg = ui.ext_registry orelse return null;
    if (ui.form_cmd >= reg.commands.len) return null;
    const cmd = &reg.commands[ui.form_cmd];
    return if (cmd.mode == .form) cmd else null;
}

/// Opens form `i` with its fields at their defaults.
pub fn open(ui: *Ui, i: u16) void {
    ui.form_cmd = i;
    reset(ui);
    ui.navigate(.form);
}

/// Every field back to its default.
pub fn reset(ui: *Ui) void {
    clear(ui);
    const cmd = command(ui) orelse return;
    for (cmd.fields) |f| {
        const v = ui.gpa.dupeSentinel(u8, f.default, 0) catch return;
        ui.form_values.append(ui.gpa, v) catch {
            ui.gpa.free(v);
            return;
        };
    }
}

fn clear(ui: *Ui) void {
    for (ui.form_values.items) |v| ui.gpa.free(v);
    ui.form_values.clearRetainingCapacity();
}

fn value(ui: *Ui, i: usize) [:0]const u8 {
    return if (i < ui.form_values.items.len) ui.form_values.items[i] else "";
}

pub fn setValue(ui: *Ui, i: usize, v: []const u8) void {
    if (i >= ui.form_values.items.len) return;
    const copy = ui.gpa.dupeSentinel(u8, v, 0) catch return;
    ui.gpa.free(ui.form_values.items[i]);
    ui.form_values.items[i] = copy;
}

pub fn title(ui: *Ui) [*:0]const u8 {
    const cmd = command(ui) orelse return "Form";
    return cmd.title.ptr;
}

pub fn field(ui: *Ui, i: usize) ?*const Host.Pref {
    const cmd = command(ui) orelse return null;
    return if (i < cmd.fields.len) &cmd.fields[i] else null;
}

pub fn candidates(ui: *Ui, a: std.mem.Allocator) []Item {
    const cmd = command(ui) orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (cmd.fields, 0..) |*f, i| {
        out.append(a, .{
            .key = a.print("field:{s}", .{f.name}) catch continue,
            .title = if (f.required) a.printSentinel(
                "{s} *",
                .{f.title},
                0,
            ) catch f.title else f.title,
            .subtitle = f.description,
            .accessory = prefs_view.display(a, f, value(ui, i)),
            .icon = prefs_view.iconOf(f.kind),
            .action = .{ .setting = .{ .field = @intCast(i) } },
        }) catch break;
    }
    out.append(a, .{
        .key = "form:submit",
        .title = cmd.submit_title,
        .icon = .{ .tile = .{ .name = "document-send-symbolic", .color = .blue } },
        .action = .{ .setting = .submit_form },
    }) catch {};
    return out.items;
}

/// Enter on field `i`.
pub fn edit(ui: *Ui, i: u16) void {
    const f = field(ui, i) orelse return;
    prefs_view.editValue(ui, .{ .field = i }, f, value(ui, i));
}

/// The values of choice field `i`, for the choose view.
pub fn choiceCandidates(ui: *Ui, a: std.mem.Allocator, out: *std.ArrayList(Item), i: u16) void {
    const f = field(ui, i) orelse return;
    for (f.choices) |ch| out.append(a, settings_view.pickRow(a, ch, value(ui, i)) catch return) catch return;
}

pub fn pick(ui: *Ui, i: u16, v: []const u8) void {
    setValue(ui, i, v);
    ui.goBack();
}

/// The Submit row: required fields first, then the extension's submit.
pub fn submit(ui: *Ui) void {
    const cmd = command(ui) orelse return;
    const h = ui.ext_host orelse return;
    const reg = ui.ext_registry orelse return;
    var buf: [20]Host.FormValue = undefined;
    for (cmd.fields, 0..) |*f, i| {
        const v = value(ui, i);
        if (f.required and v.len == 0) {
            const msg = ui.query_arena.allocator().printSentinel(
                "Fill in {s} first",
                .{f.title},
                0,
            ) catch "Fill in the required fields";
            return ui.showFailure(msg);
        }
        buf[i] = .{ .name = f.name, .value = v, .toggle = f.kind == .toggle };
    }
    ui.ext_act_gen = h.submit(reg.gen, ui.form_cmd, buf[0..cmd.fields.len]);
    ui.showRunning();
}
