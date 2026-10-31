//! An extension's form: a row per field showing its value, and a last row
//! that submits. Fields are edited like preferences: Enter flips a toggle,
//! lists a choice's values, or opens the input view for text. Submitting
//! calls the command's `submit(values)` on the extension thread.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const Host = @import("../ext/Host.zig");
const Ui = @import("Ui.zig");
const prefs_view = @import("prefs_view.zig");
const settings_view = @import("settings_view.zig");

const log = std.log.scoped(.ext);

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

pub fn setValue(ui: *Ui, field_index: usize, field_value: []const u8) void {
    if (field_index >= ui.form_values.items.len) return;
    const copy = ui.gpa.dupeSentinel(u8, field_value, 0) catch return;
    ui.gpa.free(ui.form_values.items[field_index]);
    ui.form_values.items[field_index] = copy;
}

pub fn title(ui: *Ui) [*:0]const u8 {
    const cmd = command(ui) orelse return "Form";
    return cmd.title.ptr;
}

pub fn field(ui: *Ui, field_index: usize) ?*const Host.Pref {
    const cmd = command(ui) orelse return null;
    return if (field_index < cmd.fields.len) &cmd.fields[field_index] else null;
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
    // Without its Submit row the form cannot be sent: say so in the log
    // (the next keystroke builds the rows again).
    out.append(arena, .{
        .key = "form:submit",
        .title = cmd.submit_title,
        .icon = .{ .tile = .{ .name = "document-send-symbolic", .color = .blue } },
        .action = .{ .setting = .submit_form },
    }) catch log.warn("out of memory: the form has no Submit row", .{});
    return out.items;
}

/// Enter on field `field_index`.
pub fn edit(ui: *Ui, field_index: u16) void {
    const form_field = field(ui, field_index) orelse return;
    prefs_view.editValue(ui, .{ .field = field_index }, form_field, value(ui, field_index));
}

/// The values of choice field `field_index`, for the choose view.
pub fn choiceCandidates(
    ui: *Ui,
    arena: std.mem.Allocator,
    out: *std.ArrayList(Item),
    field_index: u16,
) void {
    const form_field = field(ui, field_index) orelse return;
    for (form_field.choices) |choice| out.append(
        arena,
        settings_view.pickRow(arena, choice, value(ui, field_index)) catch return,
    ) catch return;
}

pub fn pick(ui: *Ui, field_index: u16, field_value: []const u8) void {
    setValue(ui, field_index, field_value);
    ui.goBack();
}

/// Fields a form has at most. Host refuses a command with more when it
/// loads the files, so `submit` never runs out.
const form_fields_max = Host.form_fields_max;

/// The Submit row: required fields first, then the extension's submit.
pub fn submit(ui: *Ui) void {
    const cmd = command(ui) orelse return;
    const host = ui.ext_host orelse return;
    const registry = ui.ext_registry orelse return;
    var buf: [form_fields_max]Host.FormValue = undefined;
    assert(cmd.fields.len <= buf.len);
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
