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
const choose_view = @import("choose_view.zig");

const log = std.log.scoped(.ext);

/// The open form's command, while it is still a form in the registry.
fn command(ui: *Ui) ?*const Host.Command {
    const registry = ui.ext_registry orelse return null;
    const form = registry.command(ui.form_command) orelse return null;
    return if (form.mode == .form) form else null;
}

/// Opens form `index` with its fields at their defaults.
pub fn open(ui: *Ui, index: Host.CommandIndex) void {
    ui.form_command = index;
    reset(ui);
    ui.navigate(.form);
}

/// Every field back to its default.
pub fn reset(ui: *Ui) void {
    clear(ui);
    const form = command(ui) orelse return;
    for (form.fields) |form_field| {
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

/// The open form's values, one per field, by position.
fn value(ui: *Ui, field_index: Host.FieldIndex) [:0]const u8 {
    const values = ui.form_values.items;
    return if (field_index.position() < values.len) values[field_index.position()] else "";
}

pub fn setValue(ui: *Ui, field_index: Host.FieldIndex, field_value: []const u8) void {
    const values = ui.form_values.items;
    if (field_index.position() >= values.len) return;
    const copy = ui.gpa.dupeSentinel(u8, field_value, 0) catch return;
    ui.gpa.free(values[field_index.position()]);
    values[field_index.position()] = copy;
}

pub fn title(ui: *Ui) [*:0]const u8 {
    const form = command(ui) orelse return "Form";
    return form.title.ptr;
}

pub fn field(ui: *Ui, field_index: Host.FieldIndex) ?*const Host.Preference {
    const form = command(ui) orelse return null;
    return form.field(field_index);
}

/// A row per field with its value, then the Submit row.
pub fn candidates(ui: *Ui, arena: std.mem.Allocator) []Item {
    const form = command(ui) orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (form.fields, 0..) |*form_field, i| {
        // A required field is marked with a star after its title.
        const field_title = if (form_field.required)
            arena.printSentinel("{s} *", .{form_field.title}, 0) catch form_field.title
        else
            form_field.title;
        out.append(arena, .{
            .key = arena.print("field:{s}", .{form_field.name}) catch continue,
            .title = field_title,
            .subtitle = form_field.description,
            .accessory = prefs_view.display(arena, form_field, value(ui, .from(i))),
            .icon = prefs_view.iconOf(form_field.kind),
            .action = .{ .setting = .{ .field = .from(i) } },
        }) catch break;
    }
    // Without its Submit row the form cannot be sent: say so in the log
    // (the next keystroke builds the rows again).
    out.append(arena, .{
        .key = "form:submit",
        .title = form.submit_title,
        .icon = .{ .tile = .{ .name = "document-send-symbolic", .color = .blue } },
        .action = .{ .setting = .submit_form },
    }) catch log.warn("out of memory: the form has no Submit row", .{});
    return out.items;
}

/// Enter on field `field_index`.
pub fn edit(ui: *Ui, field_index: Host.FieldIndex) void {
    const form_field = field(ui, field_index) orelse return;
    prefs_view.editValue(ui, .{ .field = field_index }, form_field, value(ui, field_index));
}

/// The values of choice field `field_index`, for the choose view.
pub fn choiceCandidates(
    ui: *Ui,
    arena: std.mem.Allocator,
    out: *std.ArrayList(Item),
    field_index: Host.FieldIndex,
) void {
    const form_field = field(ui, field_index) orelse return;
    for (form_field.choices) |choice| out.append(
        arena,
        choose_view.pickRow(arena, choice, value(ui, field_index)) catch return,
    ) catch return;
}

pub fn pick(ui: *Ui, field_index: Host.FieldIndex, field_value: []const u8) void {
    setValue(ui, field_index, field_value);
    ui.goBack();
}

/// Fields a form has at most. Host refuses a command with more when it
/// loads the files, so `submit` never runs out.
const form_fields_max = Host.form_fields_max;

/// The Submit row: required fields first, then the extension's submit.
pub fn submit(ui: *Ui) void {
    const form = command(ui) orelse return;
    const host = ui.ext_host orelse return;
    const registry = ui.ext_registry orelse return;
    var values: [form_fields_max]Host.FormValue = undefined;
    assert(form.fields.len <= values.len);
    for (form.fields, 0..) |*form_field, i| {
        const field_value = value(ui, .from(i));
        if (form_field.required and field_value.len == 0) {
            const message = ui.query_arena.allocator().printSentinel(
                "Fill in {s} first",
                .{form_field.title},
                0,
            ) catch "Fill in the required fields";
            return ui.showFailure(message);
        }
        values[i] = .{
            .name = form_field.name,
            .value = field_value,
            .toggle = form_field.kind == .toggle,
        };
    }
    const form_values = values[0..form.fields.len];
    ui.ext_act_generation = host.submit(registry.generation, ui.form_command, form_values);
    ui.showRunning();
}
