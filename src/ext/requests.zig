//! The worker's side of the requests the window makes: what is pending,
//! and how each kind runs in its extension's Lua state.
//!
//! The window posts requests through Host (`list`, `root`, `act`,
//! `submit`); the worker's loop takes them from `Host.pending` and calls
//! the `*Execute` function of each here. Each one checks that the request
//! was made against the current registry, runs the command's Lua under a
//! deadline, copies what it returned into an answer and delivers it.
//!
//! A list's rows keep their Lua table alive (`Kept`, one for the command's
//! list and one for its root-search rows), so that an action later runs
//! against the very row it was listed as. Worker thread only, except for
//! the request types, which the main thread fills.

const std = @import("std");
const lua = @import("luart").lua;
const core = @import("core");
const Host = @import("Host.zig");
const Extension = @import("Extension.zig");
const rows_mod = @import("rows.zig");
const registry_mod = @import("registry.zig");
const generation_mod = @import("generation.zig");
const Item = @import("../item.zig").Item;

const log = std.log.scoped(.ext);
const assert = std.debug.assert;

const Mode = registry_mod.Mode;
const CommandIndex = registry_mod.CommandIndex;
const RegistryGeneration = generation_mod.RegistryGeneration;
const RequestGeneration = generation_mod.RequestGeneration;
const FormValue = Host.FormValue;
const ListResult = Host.ListResult;
const ActResult = Host.ActResult;
const RootResult = Host.RootResult;
const RootSection = Host.RootSection;
const Outcome = Host.Outcome;

/// How long a list, a root search (each command's) or an action may run
/// before the instruction hook stops it.
const list_budget_ns = 10 * std.time.ns_per_s;
const act_budget_ns = 30 * std.time.ns_per_s;
const root_search_budget_ns = 3 * std.time.ns_per_s;
/// The most of a query a search command or a root search gets.
const query_bytes_max = 1024;

/// What one answer's rows take in all. They are copied out of the state, so
/// its memory cap does not hold them: one string that 1000 rows refer to
/// becomes 1000 copies.
const rows_bytes_max = 16 << 20;
pub const rows_too_big = std.fmt.comptimePrint(
    "the rows take more than {d} MB",
    .{rows_bytes_max >> 20},
);

const c_noref = lua.c.LUA_NOREF;

/// Where the worker finds a command: its state and its spec table, and the
/// lists its rows came from (their actions run there).
pub const WorkerCommand = struct {
    /// Its file's state, in `Host.extensions`.
    extension_index: u16,
    /// The command's table (registry reference).
    spec_reference: c_int,
    mode: Mode,
    answers_root_search: bool,
    /// The list its last `items` or `search` returned.
    list_kept: Kept = .{},
    /// The list its last `root` returned.
    root_search_kept: Kept = .{},
};

/// A Lua list kept alive in the registry so that its rows' actions can run
/// later. An action for a row of another list is refused: the row it
/// names may be gone, or another row now.
pub const Kept = struct {
    reference: c_int = c_noref,
    /// The request that produced it.
    list_generation: RequestGeneration = .none,
};

/// Requests the worker has not taken yet. A newer request of a kind
/// replaces one not started.
pub const Pending = struct {
    reload: bool = false,
    list: ?ListRequest = null,
    root_search: ?RootSearchRequest = null,
    act: ?ActRequest = null,
    /// Owned: freed once it ran, or by the submit that replaces it.
    submit: ?*SubmitRequest = null,
};

pub const ListRequest = struct {
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    request_generation: RequestGeneration,
    query: core.FixedStr(query_bytes_max),
};

pub const RootSearchRequest = struct {
    registry_generation: RegistryGeneration,
    request_generation: RequestGeneration,
    query: core.FixedStr(query_bytes_max),
};

pub const ActRequest = struct {
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    request_generation: RequestGeneration,
    target: Target,

    pub const Target = union(enum) {
        /// The command's own `run`.
        command_run,
        /// An action of a row the command listed.
        row_action: RowAction,
    };

    pub const RowAction = struct {
        /// The row came from the root search, not from the command's list.
        from_root_search: bool,
        /// The list the row came from.
        list_generation: RequestGeneration,
        row_index: u32,
        action_index: u8,
    };
};

/// A form submitted; owns copies of its values.
pub const SubmitRequest = struct {
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    request_generation: RequestGeneration,
    values: []FormValue,
    arena: std.heap.ArenaAllocator,

    /// A submit request owning copies of `values`. All of them or none: half
    /// copied values would reach the extension as if the user had left fields
    /// empty.
    pub fn create(
        gpa: std.mem.Allocator,
        registry_generation: RegistryGeneration,
        command: CommandIndex,
        request_generation: RequestGeneration,
        values: []const FormValue,
    ) error{OutOfMemory}!*SubmitRequest {
        const request = try gpa.create(SubmitRequest);
        request.* = .{
            .registry_generation = registry_generation,
            .command = command,
            .request_generation = request_generation,
            .values = &.{},
            .arena = .init(gpa),
        };
        errdefer request.destroy(gpa);
        const arena = request.arena.allocator();
        const copies = try arena.alloc(FormValue, values.len);
        for (copies, values) |*copy, value| {
            copy.* = .{
                .name = try arena.dupe(u8, value.name),
                .value = try arena.dupe(u8, value.value),
                .toggle = value.toggle,
            };
        }
        request.values = copies;
        return request;
    }

    pub fn destroy(request: *SubmitRequest, gpa: std.mem.Allocator) void {
        request.arena.deinit();
        gpa.destroy(request);
    }
};

/// The error a request gets when the files were reloaded after it was made.
const reloaded = "Extensions were reloaded";

/// The command a request names; null when the files were reloaded after
/// the request was made (its command index is from a registry that is
/// gone, and may name another command now).
fn requested(
    host: *Host,
    registry_generation: RegistryGeneration,
    command: CommandIndex,
) ?*WorkerCommand {
    if (registry_generation != host.registry_generation) return null;
    // The registry the UI holds has as many commands as there are worker
    // commands; anything past them is not a command of this registry.
    if (command.position() >= host.worker_commands.len) return null;
    const worker_command = &host.worker_commands[command.position()];
    assert(worker_command.extension_index < host.extensions.items.len);
    return worker_command;
}

/// The extension that defined `worker_command`.
fn extensionOf(host: *const Host, worker_command: *const WorkerCommand) *Extension {
    assert(worker_command.extension_index < host.extensions.items.len);
    return host.extensions.items[worker_command.extension_index];
}

pub fn listExecute(host: *Host, request: *const ListRequest) void {
    const result = host.answerCreate(ListResult, "list", .{
        .generation = request.request_generation,
        .command = request.command,
        .query = "",
        .arena = .init(host.gpa),
    }) orelse return;
    defer host.deliver(.{ .list = result });
    const arena = result.arena.allocator();
    const query = request.query.slice();
    result.query = arena.dupe(u8, query) catch {
        // An answer for "" would pass for the answer to an empty query.
        result.error_message = "out of memory";
        return;
    };
    const worker_command = requested(host, request.registry_generation, request.command) orelse {
        result.error_message = reloaded;
        return;
    };
    const extension = extensionOf(host, worker_command);
    var rows: lua.Capped = .{ .child = arena, .bytes_max = rows_bytes_max };
    var context: ListContext = .{
        .extension = extension,
        .worker_command = worker_command,
        .request = request,
        .result = result,
        .rows_arena = rows.allocator(),
    };
    result.error_message = extension.run(
        arena,
        list_budget_ns,
        ListContext,
        &context,
        ListContext.run,
    );
    if (result.error_message != null and rows.refused) result.error_message = rows_too_big;
}

const ListContext = struct {
    extension: *Extension,
    worker_command: *WorkerCommand,
    request: *const ListRequest,
    result: *ListResult,
    /// The result's arena, up to `rows_bytes_max`.
    rows_arena: std.mem.Allocator,

    fn run(L: *lua.State, context: *ListContext) void {
        _ = lua.pushRef(L, context.worker_command.spec_reference);
        const spec = lua.absIndex(L, -1);
        switch (context.worker_command.mode) {
            .list => {
                // `items` is a function to call, or the list itself.
                const items_type = lua.getField(L, spec, "items");
                if (items_type == lua.c.LUA_TFUNCTION) lua.c.lua_callk(L, 0, 1, 0, null);
            },
            .search => {
                _ = lua.getField(L, spec, "search");
                lua.pushString(L, context.request.query.slice());
                lua.c.lua_callk(L, 1, 1, 0, null);
            },
            .run, .provider, .form => lua.raise(L, "this command has no list", .{}),
        }
        const rows = lua.absIndex(L, -1);
        switch (lua.c.lua_type(L, rows)) {
            lua.c.LUA_TNIL => return,
            lua.c.LUA_TTABLE => {},
            else => lua.raise(L, "items: a list expected, got {s}", .{lua.typeName(L, rows)}),
        }
        keep(L, &context.worker_command.list_kept, rows, context.request.request_generation);
        context.result.items = rows_mod.parseItems(L, context.rows_arena, rows, .{
            .list_generation = context.request.request_generation,
            .command = context.request.command,
            .extension_id = context.extension.id,
        }, Host.items_max);
    }
};

/// Keeps the list at `rows` for its rows' actions, until the next one.
fn keep(L: *lua.State, kept: *Kept, rows: c_int, list_generation: RequestGeneration) void {
    if (kept.reference != c_noref) {
        lua.unref(L, kept.reference);
        kept.reference = c_noref;
    }
    lua.c.lua_pushvalue(L, rows);
    kept.reference = lua.ref(L);
    kept.list_generation = list_generation;
}

pub fn rootSearchExecute(host: *Host, request: *const RootSearchRequest) void {
    const result = host.answerCreate(RootResult, "root", .{
        .generation = request.request_generation,
        .query = "",
        .arena = .init(host.gpa),
    }) orelse return;
    defer host.deliver(.{ .root = result });
    const arena = result.arena.allocator();
    const query = request.query.slice();
    // Out of memory, no rows: an answer for "" would show no rows anyway.
    result.query = arena.dupe(u8, query) catch return;
    if (request.registry_generation != host.registry_generation) return;
    var sections: std.ArrayList(RootSection) = .empty;
    // Every provider's rows together.
    var rows: lua.Capped = .{ .child = arena, .bytes_max = rows_bytes_max };
    for (host.worker_commands, 0..) |*worker_command, command_index| {
        if (!worker_command.answers_root_search) continue;
        // A newer query came in: this one is already stale.
        if (rootSearchSuperseded(host)) break;
        const command: CommandIndex = .from(command_index);
        const items = rootSearchCommand(host, arena, &rows, worker_command, command, request);
        if (items.len == 0) continue;
        sections.append(arena, .{ .command = command, .items = items }) catch {
            log.warn("root search: out of memory, rows left out", .{});
            break;
        };
    }
    result.sections = sections.items;
}

/// One command's rows for a root search; none when it failed (logged: one
/// provider failing must not hide the others' rows).
fn rootSearchCommand(
    host: *Host,
    arena: std.mem.Allocator,
    rows: *lua.Capped,
    worker_command: *WorkerCommand,
    command: CommandIndex,
    request: *const RootSearchRequest,
) []Item {
    const extension = extensionOf(host, worker_command);
    var context: RootSearchContext = .{
        .extension = extension,
        .worker_command = worker_command,
        .command = command,
        .request = request,
        .rows_arena = rows.allocator(),
    };
    const failure = extension.run(
        arena,
        root_search_budget_ns,
        RootSearchContext,
        &context,
        RootSearchContext.run,
    ) orelse return context.items;
    const message = if (rows.refused) rows_too_big else failure;
    log.warn("{s}: root search: {s}", .{ extension.id, message });
    rows.refused = false;
    return &.{};
}

fn rootSearchSuperseded(host: *Host) bool {
    host.lock.lockUncancelable(host.io);
    defer host.lock.unlock(host.io);
    return host.pending.root_search != null;
}

const RootSearchContext = struct {
    extension: *Extension,
    worker_command: *WorkerCommand,
    command: CommandIndex,
    request: *const RootSearchRequest,
    rows_arena: std.mem.Allocator,
    items: []Item = &.{},

    fn run(L: *lua.State, context: *RootSearchContext) void {
        _ = lua.pushRef(L, context.worker_command.spec_reference);
        _ = lua.getField(L, -1, "root");
        lua.pushString(L, context.request.query.slice());
        lua.c.lua_callk(L, 1, 1, 0, null);
        const rows = lua.absIndex(L, -1);
        switch (lua.c.lua_type(L, rows)) {
            lua.c.LUA_TNIL => return,
            lua.c.LUA_TTABLE => {},
            else => lua.raise(L, "root: a list expected, got {s}", .{lua.typeName(L, rows)}),
        }
        keep(L, &context.worker_command.root_search_kept, rows, context.request.request_generation);
        context.items = rows_mod.parseItems(L, context.rows_arena, rows, .{
            .list_generation = context.request.request_generation,
            .command = context.command,
            .from_root_search = true,
            .extension_id = context.extension.id,
        }, Host.root_search_items_max);
    }
};

pub fn submitExecute(host: *Host, request: *SubmitRequest) void {
    defer request.destroy(host.gpa);
    const result = host.answerCreate(ActResult, "submit", .{
        .generation = request.request_generation,
        .arena = .init(host.gpa),
    }) orelse return;
    defer host.deliver(.{ .act = result });
    const worker_command = requested(host, request.registry_generation, request.command) orelse {
        result.error_message = reloaded;
        return;
    };
    assert(request.values.len <= Host.form_fields_max);
    const extension = extensionOf(host, worker_command);
    var context: SubmitContext = .{
        .worker_command = worker_command,
        .request = request,
        .result = result,
    };
    const arena = result.arena.allocator();
    result.error_message = extension.run(
        arena,
        act_budget_ns,
        SubmitContext,
        &context,
        SubmitContext.run,
    );
}

const SubmitContext = struct {
    worker_command: *WorkerCommand,
    request: *SubmitRequest,
    result: *ActResult,

    fn run(L: *lua.State, context: *SubmitContext) void {
        _ = lua.pushRef(L, context.worker_command.spec_reference);
        if (lua.getField(L, -1, "submit") != lua.c.LUA_TFUNCTION) {
            lua.raise(L, "this command has no submit function", .{});
        }
        const values = context.request.values;
        lua.c.lua_createtable(L, 0, @intCast(values.len));
        for (values) |value| {
            if (value.toggle) {
                const is_on = registry_mod.toggleIsOn(value.value);
                lua.c.lua_pushboolean(L, @intFromBool(is_on));
            } else {
                lua.pushString(L, value.value);
            }
            lua.pushString(L, value.name);
            // The name under its value: table[name] = value.
            lua.c.lua_rotate(L, -2, 1);
            lua.c.lua_rawset(L, -3);
        }
        lua.c.lua_callk(L, 1, 1, 0, null);
        context.result.outcome = outcomeOf(L);
    }
};

/// What a run, an action or a submit returned.
fn outcomeOf(L: *lua.State) Outcome {
    switch (lua.c.lua_type(L, -1)) {
        lua.c.LUA_TNIL => return .close,
        lua.c.LUA_TSTRING => {
            const text = lua.toSlice(L, -1).?;
            return std.meta.stringToEnum(Outcome, text) orelse lua.raise(
                L,
                "run must return nothing, \"close\", \"stay\" or \"refresh\" (got \"{s}\")",
                .{text},
            );
        },
        else => lua.raise(
            L,
            "run must return nothing, \"close\", \"stay\" or \"refresh\", not a {s}",
            .{lua.typeName(L, -1)},
        ),
    }
}

pub fn actExecute(host: *Host, request: ActRequest) void {
    const result = host.answerCreate(ActResult, "action", .{
        .generation = request.request_generation,
        .arena = .init(host.gpa),
    }) orelse return;
    defer host.deliver(.{ .act = result });
    const worker_command = requested(host, request.registry_generation, request.command) orelse {
        result.error_message = reloaded;
        return;
    };
    const extension = extensionOf(host, worker_command);
    var context: ActContext = .{
        .worker_command = worker_command,
        .request = request,
        .result = result,
    };
    const arena = result.arena.allocator();
    result.error_message = extension.run(
        arena,
        act_budget_ns,
        ActContext,
        &context,
        ActContext.run,
    );
}

const ActContext = struct {
    worker_command: *WorkerCommand,
    request: ActRequest,
    result: *ActResult,

    fn run(L: *lua.State, context: *ActContext) void {
        switch (context.request.target) {
            .command_run => {
                pushCommandRun(L, context.worker_command);
                lua.c.lua_callk(L, 0, 1, 0, null);
            },
            .row_action => |row_action| {
                pushRowAction(L, context.worker_command, row_action);
                lua.c.lua_callk(L, 1, 1, 0, null);
            },
        }
        context.result.outcome = outcomeOf(L);
    }
};

/// Pushes the command's `run` function.
fn pushCommandRun(L: *lua.State, worker_command: *const WorkerCommand) void {
    _ = lua.pushRef(L, worker_command.spec_reference);
    if (lua.getField(L, -1, "run") != lua.c.LUA_TFUNCTION) {
        lua.raise(L, "this command has no run function", .{});
    }
}

/// Pushes a row's action function, then the row (its argument). What it
/// read on the way stays below them; `protect` clears it.
fn pushRowAction(
    L: *lua.State,
    worker_command: *const WorkerCommand,
    row_action: ActRequest.RowAction,
) void {
    const kept = if (row_action.from_root_search)
        &worker_command.root_search_kept
    else
        &worker_command.list_kept;
    if (kept.reference == c_noref or kept.list_generation != row_action.list_generation) {
        lua.raise(L, "the list changed meanwhile; try again", .{});
    }
    _ = lua.pushRef(L, kept.reference);
    const rows = lua.absIndex(L, -1);
    if (lua.c.lua_rawgeti(L, rows, @intCast(row_action.row_index + 1)) != lua.c.LUA_TTABLE) {
        lua.raise(L, "that row has no actions", .{});
    }
    const row = lua.absIndex(L, -1);
    // The row is a live table the extension may have changed since:
    // rawgeti on a non-table reads garbage (no API checks in distribution
    // builds of Lua).
    if (lua.getField(L, row, "actions") != lua.c.LUA_TTABLE) {
        lua.raise(L, "that row has no actions", .{});
    }
    const action_number = @as(c_int, row_action.action_index) + 1;
    if (lua.c.lua_rawgeti(L, -1, action_number) != lua.c.LUA_TTABLE) {
        lua.raise(L, "that action is not a Lua function", .{});
    }
    if (lua.getField(L, -1, "run") != lua.c.LUA_TFUNCTION) {
        lua.raise(L, "that action is not a Lua function", .{});
    }
    lua.c.lua_pushvalue(L, row);
}
