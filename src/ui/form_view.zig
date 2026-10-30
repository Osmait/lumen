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
    const registry = ui.ext_registry orelse return null;
    if (ui.form_cmd >= registry.commands.len) return null;
    const cmd = &registry.commands[ui.form_cmd];
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
    for (cmd.fields) |form_field| {
        const field_value = ui.gpa.dupeSentinel(u8, form_field.default, 0) catch return;
        ui.form_values.append(ui.gpa, field_value) catch {
            ui.gpa.free(field_value);
            return;
        };
    }
}

fn clear(ui: *Ui) void {
    for (ui.form_values.items) |field_value| ui.gpa.free(field_value);
    ui.form_values.clearRetainingCapacity();
}

fn value(ui: *Ui, i: usize) [:0]const u8 {
    return if (i < ui.form_values.items.len) ui.form_values.items[i] else "";
}

pub fn setValue(ui: *Ui, i: usize, field_value: []const u8) void {
    if (i >= ui.form_values.items.len) return;
    const copy = ui.gpa.dupeSentinel(u8, field_value, 0) catch return;
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

pub fn candidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    const cmd = command(ui) orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (cmd.fields, 0..) |*form_field, i| {
        // A required field is marked with a star after its title.
        const field_title = if (form_field.required) arena.printSentinel(
            "{s} *",
            .{form_field.title},
            0,
        ) catch form_field.title else form_field.title;
        out.append(arena, .{
            .key = arena.print("field:{s}", .{form_field.name}) catch continue,
            .title = field_title,
            .subtitle = form_field.description,
            .accessory = prefs_view.display(arena, form_field, value(ui, i)),
            .icon = prefs_view.iconOf(form_field.kind),
            .action = .{ .setting = .{ .field = @intCast(i) } },
        }) catch break;
    }
    out.append(arena, .{
        .key = "form:submit",
        .title = cmd.submit_title,
        .icon = .{ .tile = .{ .name = "document-send-symbolic", .color = .blue } },
        .action = .{ .setting = .submit_form },
    }) catch {};
    return out.items;
}

/// Enter on field `i`.
pub fn edit(ui: *Ui, i: u16) void {
    const form_field = field(ui, i) orelse return;
    prefs_view.editValue(ui, .{ .field = i }, form_field, value(ui, i));
}

/// The values of choice field `i`, for the choose view.
pub fn choiceCandidates(ui: *Ui, arena: std.mem.Allocator, out: *std.ArrayList(Item), i: u16) void {
    const form_field = field(ui, i) orelse return;
    for (form_field.choices) |choice| out.append(
        arena,
        settings_view.pickRow(arena, choice, value(ui, i)) catch return,
    ) catch return;
}

pub fn pick(ui: *Ui, i: u16, field_value: []const u8) void {
    setValue(ui, i, field_value);
    ui.goBack();
}

/// The Submit row: required fields first, then the extension's submit.
pub fn submit(ui: *Ui) void {
    const cmd = command(ui) orelse return;
    const host = ui.ext_host orelse return;
    const registry = ui.ext_registry orelse return;
    var buf: [20]Host.FormValue = undefined;
    for (cmd.fields, 0..) |*form_field, i| {
        const field_value = value(ui, i);
        if (form_field.required and field_value.len == 0) {
            const msg = ui.query_arena.allocator().printSentinel(
                "Fill in {s} first",
                .{form_field.title},
                0,
            ) catch "Fill in the required fields";
            return ui.showFailure(msg);
        }
        buf[i] = .{
            .name = form_field.name,
            .value = field_value,
            .toggle = form_field.kind == .toggle,
        };
    }
    ui.ext_act_gen = host.submit(registry.gen, ui.form_cmd, buf[0..cmd.fields.len]);
    ui.showRunning();
}
