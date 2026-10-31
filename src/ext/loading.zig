//! Reloading, on the worker: every state of the last load is closed, then
//! each file runs in a new one (the style, init.lua, each extension in
//! turn), and what they defined becomes a new registry for the window.
//!
//! A file that fails (an error, its deadline, out of memory) is reported
//! as a problem and leaves nothing behind: what it added to the `Load` is
//! rolled back and its state closed. The others load regardless.

const std = @import("std");
const lua = @import("luart").lua;
const os = @import("os");
const styles = @import("styles");
const Host = @import("Host.zig");
const Extension = @import("Extension.zig");
const Load = @import("Load.zig");
const api = @import("api.zig");
const rows_mod = @import("rows.zig");
const registry_mod = @import("registry.zig");
const item_mod = @import("../item.zig");
const WorkerCommand = @import("requests.zig").WorkerCommand;

const log = std.log.scoped(.ext);
const assert = std.debug.assert;

const Registry = registry_mod.Registry;
const Command = registry_mod.Command;
const Mode = registry_mod.Mode;
const Preference = registry_mod.Preference;
const PreferenceKind = registry_mod.PreferenceKind;
const PreferenceChoice = registry_mod.PreferenceChoice;
const config_extension_id = registry_mod.config_extension_id;
const style_extension_id = registry_mod.style_extension_id;

/// How long a file may run as it loads before the instruction hook stops
/// it.
const load_budget_ns = 5 * std.time.ns_per_s;
/// A grid command's cells to a line.
const grid_columns_min = 2;
const grid_columns_max = 10;

comptime {
    assert(grid_columns_min <= grid_columns_max);
    assert(registry_mod.grid_columns_default >= grid_columns_min);
    assert(registry_mod.grid_columns_default <= grid_columns_max);
    assert(grid_columns_max <= std.math.maxInt(@FieldType(Command, "columns")));
}

/// Closes every state and forgets the commands of the registry they made.
pub fn closeAll(host: *Host) void {
    for (host.extensions.items) |extension| extension.destroy();
    host.extensions.clearRetainingCapacity();
    host.gpa.free(host.worker_commands);
    host.worker_commands = &.{};
    _ = host.worker_arena.reset(.retain_capacity);
}

/// Loads every file again into new states, and delivers the new registry.
pub fn reloadExecute(host: *Host) void {
    closeAll(host);
    host.registry_generation = host.registry_generation.next();
    const registry = host.answerCreate(Registry, "reload", .{
        .generation = host.registry_generation,
        .arena = .init(host.gpa),
    }) orelse return;
    var load: Load = .{ .arena = registry.arena.allocator() };
    loadAll(host, &load);
    registryFill(host, registry, &load);
    for (registry.problems) |file_problem| {
        log.warn("{s}: {s}", .{ file_problem.extension, file_problem.message });
    }
    host.deliver(.{ .registry = registry });
}

/// The style first (init.lua may adjust it), then init.lua, then each
/// extension.
fn loadAll(host: *Host, load: *Load) void {
    const worker_arena = host.worker_arena.allocator();
    const style = blk: {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        break :blk worker_arena.dupe(u8, host.style.slice()) catch {
            load.problem(style_extension_id, "out of memory");
            break :blk "";
        };
    };
    if (style.len > 0) loadStyle(host, load, style);

    if (worker_arena.printSentinel("{s}/init.lua", .{host.config_dir}, 0)) |path| {
        if (os.info(path) != null) {
            loadSource(host, load, config_extension_id, host.config_dir, path, null);
        }
    } else |_| {
        load.problem(config_extension_id, "out of memory");
    }

    for (extensionDirs(host, worker_arena)) |id| loadExtension(host, load, id);
}

/// The extension in extensions/<id>, when its folder name is one.
fn loadExtension(host: *Host, load: *Load, id: [:0]const u8) void {
    const worker_arena = host.worker_arena.allocator();
    if (!Host.validId(id)) {
        load.problem(id, "extension folder names may use only a-z, 0-9, - and _");
        return;
    }
    if (Host.reservedId(id)) {
        const message =
            "\"config\" and \"style\" are taken (init.lua and the style); rename the folder";
        load.problem(id, message);
        return;
    }
    const folder_format = "{s}/extensions/{s}";
    const folder = worker_arena.printSentinel(folder_format, .{ host.config_dir, id }, 0) catch {
        load.problem(id, "out of memory");
        return;
    };
    const path = worker_arena.printSentinel("{s}/init.lua", .{folder}, 0) catch {
        load.problem(id, "out of memory");
        return;
    };
    if (os.info(path) == null) {
        load.problem(id, "no init.lua in the extension's folder");
        return;
    }
    loadSource(host, load, id, folder, path, null);
}

/// Hands what the files defined to the registry. A command reaches the UI
/// only with a worker command to run it.
fn registryFill(host: *Host, registry: *Registry, load: *Load) void {
    assert(load.worker_commands.items.len == load.commands.items.len);
    host.worker_commands = host.gpa.dupe(WorkerCommand, load.worker_commands.items) catch blk: {
        log.warn("reload: out of memory, extension commands left out", .{});
        load.commands.clearRetainingCapacity();
        break :blk &.{};
    };
    assert(host.worker_commands.len == load.commands.items.len);
    registry.commands = load.commands.items;
    registry.themes = load.themes.items;
    registry.keymaps = load.keymaps.items;
    registry.settings = load.settings.items;
    registry.preferences = load.preferences.items;
    registry.icons = load.icons.items;
    registry.extensions = load.extensions.items;
    registry.style_settings = load.style_settings.items;
    registry.layout = load.layout;
    registry.has_layout = load.has_layout;
    registry.problems = load.problems.items;
}

/// Names of the folders under extensions/, sorted, in `arena`.
fn extensionDirs(host: *Host, arena: std.mem.Allocator) []const [:0]const u8 {
    const path = arena.printSentinel("{s}/extensions", .{host.config_dir}, 0) catch return &.{};
    return os.subdirs(arena, path, anyName);
}

fn anyName(_: []const u8) bool {
    return true;
}

/// A style: <config>/styles/<name>/init.lua, else the built-in one. Its
/// file runs as the extension "style".
fn loadStyle(host: *Host, load: *Load, name: []const u8) void {
    const worker_arena = host.worker_arena.allocator();
    const folder = worker_arena.printSentinel("{s}/styles/{s}", .{ host.config_dir, name }, 0) catch
        return;
    const path = worker_arena.printSentinel("{s}/init.lua", .{folder}, 0) catch return;
    if (os.info(path) != null) {
        loadSource(host, load, style_extension_id, folder, path, null);
    } else if (os.info(folder) != null) {
        // A style folder may hold only a style.css.
    } else if (styles.find(name)) |built_in| {
        loadSource(host, load, style_extension_id, host.config_dir, "=style", built_in.lua);
    } else {
        load.problem(style_extension_id, "no such style");
    }
}

/// Runs a file (`path`), or `source` (then `path` names it in errors).
fn loadSource(
    host: *Host,
    load: *Load,
    id: []const u8,
    folder: []const u8,
    path: [:0]const u8,
    source: ?[:0]const u8,
) void {
    const extension = Extension.create(host, id, folder) orelse {
        load.problem(id, "out of memory");
        return;
    };
    const before = load.mark();
    extension.load = load;
    var context: LoadContext = .{
        .extension = extension,
        .load = load,
        .path = path,
        .source = source,
        .extension_index = @intCast(host.extensions.items.len),
    };
    const failure = extension.run(
        load.arena,
        load_budget_ns,
        LoadContext,
        &context,
        LoadContext.run,
    );
    extension.load = null;
    if (failure == null) {
        if (host.extensions.append(host.gpa, extension)) {
            // init.lua and the style are not extensions to list.
            if (!Host.reservedId(id)) {
                load.extensionLoaded(id, context.title, load.commandsSince(before));
            }
            return;
        } else |_| {
            // Out of memory: undone below, like a file that failed.
        }
    }
    load.rollback(before);
    load.problem(id, failure orelse "out of memory");
    extension.destroy();
}

pub const LoadContext = struct {
    extension: *Extension,
    load: *Load,
    path: [:0]const u8,
    /// Code to run instead of the file (a built-in style).
    source: ?[:0]const u8 = null,
    extension_index: u16,
    /// lumen.extension's title, once parsed.
    title: [:0]const u8 = "",

    fn run(L: *lua.State, context: *LoadContext) void {
        lua.openLibs(L);
        api.install(L, context.extension);
        const loaded = if (context.source) |source|
            lua.c.luaL_loadbufferx(L, source.ptr, source.len, context.path.ptr, "t")
        else
            lua.c.luaL_loadfilex(L, context.path.ptr, "t");
        if (loaded != lua.c.LUA_OK) _ = lua.c.lua_error(L);
        lua.c.lua_callk(L, 0, 1, 0, null);
        switch (lua.c.lua_type(L, -1)) {
            lua.c.LUA_TNIL => {},
            lua.c.LUA_TTABLE => parseExtension(L, context, lua.absIndex(L, -1)),
            else => {
                const type_name = lua.typeName(L, -1);
                lua.raise(
                    L,
                    "init.lua must return lumen.extension{{...}} or nothing, not a {s}",
                    .{type_name},
                );
            },
        }
    }
};

/// What `lumen.extension { ... }` returned: its title, icon, preferences
/// and commands.
fn parseExtension(L: *lua.State, context: *LoadContext, spec: c_int) void {
    const arena = context.load.arena;
    const title = lua.fieldString(L, arena, spec, "title", "extension") orelse
        context.extension.id;
    context.title = title;
    const icon_default = rows_mod.fieldIcon(L, arena, spec, "extension.icon") orelse addon_icon;
    parsePreferences(L, context, spec, title);
    parseCommands(L, context, spec, title, icon_default);
}

/// The icon of an extension's commands when neither it nor they name one.
const addon_icon: item_mod.Icon = .{ .tile = .{
    .name = "application-x-addon-symbolic",
    .color = .purple,
} };

fn parsePreferences(
    L: *lua.State,
    context: *LoadContext,
    spec: c_int,
    extension_title: [:0]const u8,
) void {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const preferences = lua.fieldList(L, spec, "preferences", "extension") orelse return;
    const preferences_count = lua.c.lua_rawlen(L, preferences);
    for (1..preferences_count + 1) |preference_number| {
        const preference_mark: lua.StackMark = .init(L);
        defer preference_mark.restore(L);
        var where_buffer: [32]u8 = undefined;
        const where = std.mem.print(&where_buffer, "preferences[{d}]", .{preference_number}) catch
            "preferences";
        const field_table = lua.tableAt(L, preferences, preference_number, where);
        const preference = parseField(L, context, field_table, where, extension_title);
        if (preferenceDeclared(context.load, context.extension.id, preference.name)) {
            lua.raise(L, "two preferences named \"{s}\"", .{preference.name});
        }
        context.load.preferences.append(context.load.arena, preference) catch lua.oom(L);
    }
}

fn preferenceDeclared(load: *const Load, extension_id: []const u8, name: []const u8) bool {
    for (load.preferences.items) |preference| {
        if (!std.mem.eql(u8, preference.extension, extension_id)) continue;
        if (std.mem.eql(u8, preference.name, name)) return true;
    }
    return false;
}

fn parseCommands(
    L: *lua.State,
    context: *LoadContext,
    spec: c_int,
    extension_title: [:0]const u8,
    icon_default: item_mod.Icon,
) void {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    if (lua.getField(L, spec, "commands") != lua.c.LUA_TTABLE) {
        const type_name = lua.typeName(L, -1);
        lua.raise(L, "extension.commands: a list of commands expected, got {s}", .{type_name});
    }
    const commands = lua.absIndex(L, -1);
    const commands_count = lua.c.lua_rawlen(L, commands);
    for (1..commands_count + 1) |command_number| {
        const command_mark: lua.StackMark = .init(L);
        defer command_mark.restore(L);
        var where_buffer: [32]u8 = undefined;
        const where = std.mem.print(&where_buffer, "commands[{d}]", .{command_number}) catch
            "commands";
        const command_table = lua.tableAt(L, commands, command_number, where);
        parseCommand(L, context, command_table, where, extension_title, icon_default);
    }
}

/// A command's or a field's `name`: present, and a-z, 0-9, - and _ only.
fn fieldName(
    L: *lua.State,
    arena: std.mem.Allocator,
    table: c_int,
    where: []const u8,
) [:0]const u8 {
    const name = lua.fieldString(L, arena, table, "name", where) orelse
        lua.raise(L, "{s}.name is missing", .{where});
    if (!Host.validId(name)) {
        lua.raise(L, "{s}.name: use only a-z, 0-9, - and _ (got \"{s}\")", .{ where, name });
    }
    return name;
}

/// A choice's `choices`: strings, or tables with a value and a title.
fn prefChoices(
    L: *lua.State,
    arena: std.mem.Allocator,
    field_table: c_int,
    where: []const u8,
) []const PreferenceChoice {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const choice_list = lua.fieldList(L, field_table, "choices", where) orelse
        lua.raise(L, "{s}.choices: a list expected for a choice", .{where});
    const choices_count = lua.c.lua_rawlen(L, choice_list);
    if (choices_count == 0) lua.raise(L, "{s}.choices is empty", .{where});
    const choices = arena.alloc(PreferenceChoice, choices_count) catch lua.oom(L);
    for (choices, 1..) |*choice, choice_number| {
        const choice_mark: lua.StackMark = .init(L);
        defer choice_mark.restore(L);
        _ = lua.c.lua_rawgeti(L, choice_list, @intCast(choice_number));
        if (lua.toSlice(L, -1)) |text| {
            const value = arena.dupeSentinel(u8, text, 0) catch lua.oom(L);
            choice.* = .{ .value = value, .label = value };
        } else if (lua.c.lua_type(L, -1) == lua.c.LUA_TTABLE) {
            const value = lua.fieldString(L, arena, -1, "value", where) orelse
                lua.raise(L, "{s}.choices[{d}].value is missing", .{ where, choice_number });
            const label = lua.fieldString(L, arena, -1, "title", where) orelse value;
            choice.* = .{ .value = value, .label = label };
        } else {
            lua.raise(L, "{s}.choices[{d}]: string or table expected", .{ where, choice_number });
        }
    }
    return choices;
}

/// A preference, or a form field: the two take the same fields.
fn parseField(
    L: *lua.State,
    context: *LoadContext,
    field_table: c_int,
    where: []const u8,
    extension_title: [:0]const u8,
) Preference {
    const arena = context.load.arena;
    const name = fieldName(L, arena, field_table, where);
    const kind_name = lua.fieldString(L, arena, field_table, "type", where) orelse "text";
    const kind = std.meta.stringToEnum(PreferenceKind, kind_name) orelse lua.raise(
        L,
        "{s}.type: toggle, choice, text or password (got \"{s}\")",
        .{ where, kind_name },
    );
    const file = arena.printSentinel("{s}/preferences.json", .{context.extension.data}, 0) catch
        lua.oom(L);
    var preference: Preference = .{
        .extension = context.extension.id,
        .extension_title = extension_title,
        .file = file,
        .name = name,
        .title = lua.fieldString(L, arena, field_table, "title", where) orelse name,
        .description = lua.fieldString(L, arena, field_table, "description", where) orelse "",
        .kind = kind,
        .default = "",
        .required = lua.fieldBool(L, field_table, "required", false, where),
    };
    if (kind == .choice) preference.choices = prefChoices(L, arena, field_table, where);
    preference.default = switch (kind) {
        .toggle => registry_mod.toggleText(lua.fieldBool(L, field_table, "default", false, where)),
        .choice => lua.fieldString(L, arena, field_table, "default", where) orelse
            preference.choices[0].value,
        .text, .password => lua.fieldString(L, arena, field_table, "default", where) orelse "",
    };
    return preference;
}

/// The field of a command that sets its mode.
const ModeField = struct {
    name: [:0]const u8,
    mode: Mode,
    /// A table is allowed too (a fixed list), not only a function.
    table_allowed: bool,
};

const mode_fields = [_]ModeField{
    .{ .name = "items", .mode = .list, .table_allowed = true },
    .{ .name = "search", .mode = .search, .table_allowed = false },
    .{ .name = "run", .mode = .run, .table_allowed = false },
    .{ .name = "submit", .mode = .form, .table_allowed = false },
};

/// Which of items, search, run or submit the command has (at most one);
/// null for none.
fn commandMode(L: *lua.State, command_table: c_int, where: []const u8) ?Mode {
    var mode: ?Mode = null;
    for (mode_fields) |mode_field| {
        const mark: lua.StackMark = .init(L);
        defer mark.restore(L);
        const value_type = lua.getField(L, command_table, mode_field.name);
        if (value_type == lua.c.LUA_TNIL) continue;
        const is_function = value_type == lua.c.LUA_TFUNCTION;
        const is_list = mode_field.table_allowed and value_type == lua.c.LUA_TTABLE;
        if (!is_function and !is_list) {
            const expected = if (mode_field.table_allowed) "function or table" else "function";
            const type_name = lua.typeName(L, -1);
            lua.raise(
                L,
                "{s}.{s}: {s} expected, got {s}",
                .{ where, mode_field.name, expected, type_name },
            );
        }
        if (mode != null) {
            lua.raise(L, "{s}: give it one of items, search or run, not several", .{where});
        }
        mode = mode_field.mode;
    }
    return mode;
}

/// A form's fields (1 to `form_fields_max`, names unique); none for another
/// command, which must not have any.
fn formFields(
    L: *lua.State,
    context: *LoadContext,
    command_table: c_int,
    is_form: bool,
    where: []const u8,
    extension_title: [:0]const u8,
) []const Preference {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const field_list_type = lua.getField(L, command_table, "fields");
    if (!is_form) {
        if (field_list_type != lua.c.LUA_TNIL) {
            lua.raise(L, "{s}.fields: a form needs submit too", .{where});
        }
        return &.{};
    }
    if (field_list_type != lua.c.LUA_TTABLE) {
        lua.raise(L, "{s}.fields: a list of fields expected for a form", .{where});
    }
    const field_list = lua.absIndex(L, -1);
    const fields_count = lua.c.lua_rawlen(L, field_list);
    if (fields_count == 0 or fields_count > Host.form_fields_max) {
        lua.raise(L, "{s}.fields: 1 to {d} fields", .{ where, Host.form_fields_max });
    }
    const fields = context.load.arena.alloc(Preference, fields_count) catch lua.oom(L);
    for (fields, 1..) |*field, field_number| {
        const field_mark: lua.StackMark = .init(L);
        defer field_mark.restore(L);
        var where_buffer: [48]u8 = undefined;
        const field_where = std.mem.print(
            &where_buffer,
            "{s}.fields[{d}]",
            .{ where, field_number },
        ) catch where;
        const field_table = lua.tableAt(L, field_list, field_number, field_where);
        field.* = parseField(L, context, field_table, field_where, extension_title);
        for (fields[0 .. field_number - 1]) |previous| {
            if (std.mem.eql(u8, previous.name, field.name)) {
                lua.raise(L, "{s}: two fields named \"{s}\"", .{ where, field.name });
            }
        }
    }
    assert(fields.len <= Host.form_fields_max);
    return fields;
}

/// "<extension>.<name>" from the command's `name`, checked and unique.
fn commandId(
    L: *lua.State,
    context: *LoadContext,
    command_table: c_int,
    where: []const u8,
) [:0]const u8 {
    const arena = context.load.arena;
    const name = fieldName(L, arena, command_table, where);
    const id = arena.printSentinel("{s}.{s}", .{ context.extension.id, name }, 0) catch
        lua.oom(L);
    for (context.load.commands.items) |command| {
        if (std.mem.eql(u8, command.id, id)) lua.raise(L, "two commands named \"{s}\"", .{name});
    }
    return id;
}

/// Whether the command has a `root` function (it answers root searches).
fn commandAnswersRootSearch(L: *lua.State, command_table: c_int, where: []const u8) bool {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const root_type = lua.getField(L, command_table, "root");
    if (root_type == lua.c.LUA_TNIL) return false;
    if (root_type != lua.c.LUA_TFUNCTION) {
        lua.raise(L, "{s}.root: function expected, got {s}", .{ where, lua.typeName(L, -1) });
    }
    return true;
}

fn parseCommand(
    L: *lua.State,
    context: *LoadContext,
    command_table: c_int,
    where: []const u8,
    extension_title: [:0]const u8,
    icon_default: item_mod.Icon,
) void {
    const arena = context.load.arena;
    const id = commandId(L, context, command_table, where);
    const title = lua.fieldString(L, arena, command_table, "title", where) orelse
        lua.raise(L, "{s}.title is missing", .{where});
    const answers_root_search = commandAnswersRootSearch(L, command_table, where);
    const mode_given = commandMode(L, command_table, where);
    const mode = mode_given orelse if (answers_root_search)
        Mode.provider
    else
        lua.raise(L, "{s}: give it items, search or run", .{where});
    const columns = lua.fieldNumberIn(L, command_table, "columns", where, .{
        .min = grid_columns_min,
        .max = grid_columns_max,
    }) orelse registry_mod.grid_columns_default;

    const command: Command = .{
        .id = id,
        .title = title,
        .subtitle = lua.fieldString(L, arena, command_table, "subtitle", where) orelse
            extension_title,
        .icon = rows_mod.fieldIcon(L, arena, command_table, where) orelse icon_default,
        .keywords = rows_mod.keywords(L, arena, command_table, where),
        .placeholder = lua.fieldString(L, arena, command_table, "placeholder", where) orelse "",
        .mode = mode,
        .detail = lua.fieldBool(L, command_table, "detail", false, where),
        .answers_root_search = answers_root_search,
        .fields = formFields(L, context, command_table, mode == .form, where, extension_title),
        .submit_title = lua.fieldString(L, arena, command_table, "submit_title", where) orelse
            "Submit",
        .grid = lua.fieldBool(L, command_table, "grid", false, where),
        .columns = @intFromFloat(columns),
    };
    // A command's index in the registry is a u16 everywhere.
    if (context.load.commands.items.len >= std.math.maxInt(u16)) {
        lua.raise(L, "too many commands", .{});
    }
    lua.c.lua_pushvalue(L, command_table);
    const spec_reference = lua.ref(L);
    context.load.worker_commands.append(arena, .{
        .extension_index = context.extension_index,
        .spec_reference = spec_reference,
        .mode = mode,
        .answers_root_search = answers_root_search,
    }) catch lua.oom(L);
    context.load.commands.append(arena, command) catch lua.oom(L);
    assert(context.load.worker_commands.items.len == context.load.commands.items.len);
}
