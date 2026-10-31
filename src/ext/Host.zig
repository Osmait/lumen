//! Lua extensions and init.lua, run on one worker thread.
//!
//! Files: $XDG_CONFIG_HOME/lumen/init.lua (extension id "config") and
//! $XDG_CONFIG_HOME/lumen/extensions/<id>/init.lua. Each file runs in its
//! own Lua state, so one extension cannot reach another's globals, and a
//! broken one does not stop the rest from loading.
//!
//! The UI never waits on Lua. It posts requests (reload everything, list a
//! command's items, run an action) and gets the results on the GTK main
//! loop through g_idle_add, like ContentSearch. A request made against an
//! older registry (the files were reloaded since) is answered with an
//! error, never run against the wrong command.
//!
//! A request goes: `list` (main thread) → `run` (the worker's loop) →
//! `listExecute` → `ListContext.run` (inside Lua) → `deliver` →
//! `deliverCallback` (main loop) → `Callbacks.list` (the UI). `act`,
//! `submit`, `root` and `reload` go the same way.

const std = @import("std");
const c = @import("c");
const lua = @import("luart").lua;
const api = @import("api.zig");
const rows_mod = @import("rows.zig");
const registry_mod = @import("registry.zig");
const generation_mod = @import("generation.zig");
const stamp_mod = @import("stamp.zig");
pub const Extension = @import("Extension.zig");
const os = @import("os");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const themes = @import("../ui/themes.zig");
const layout_mod = @import("../layout.zig");
const styles = @import("styles");

const Host = @This();

const log = std.log.scoped(.ext);
const assert = std.debug.assert;

/// How long a load, a list or an action may run before the instruction
/// hook stops it.
const load_budget_ns = 5 * std.time.ns_per_s;
const list_budget_ns = 10 * std.time.ns_per_s;
const act_budget_ns = 30 * std.time.ns_per_s;

/// The most rows one list answer takes, and actions one row takes.
pub const items_max = rows_mod.items_max;
pub const actions_max = rows_mod.actions_max;
/// The most rows one command adds to the root search, so that a single
/// extension cannot push the others' rows out.
pub const root_search_items_max = 8;
const root_search_budget_ns = 3 * std.time.ns_per_s;
/// The most of a query a search command or a root search gets.
const query_bytes_max = 1024;

/// What one answer's rows take in all. They are copied out of the state, so
/// its memory cap does not hold them: one string that 1000 rows refer to
/// becomes 1000 copies.
const rows_bytes_max = 16 << 20;
const rows_too_big = std.fmt.comptimePrint(
    "the rows take more than {d} MB",
    .{rows_bytes_max >> 20},
);
/// Fields of one form.
pub const form_fields_max = 20;
/// An extension's folder name, a command's or a field's name.
pub const id_bytes_max = 40;
/// A grid command's cells to a line.
const grid_columns_min = 2;
const grid_columns_max = 10;

comptime {
    assert(root_search_items_max <= items_max);
    assert(grid_columns_min <= grid_columns_max);
    assert(registry_mod.grid_columns_default >= grid_columns_min);
    assert(registry_mod.grid_columns_default <= grid_columns_max);
    assert(grid_columns_max <= std.math.maxInt(@FieldType(Command, "columns")));
}

gpa: std.mem.Allocator,
io: std.Io,
config_dir: [:0]const u8,
/// Where extensions keep data: <data_dir>/extensions/<id>.
data_dir: [:0]const u8,
callbacks: Callbacks,
thread: std.Thread = undefined,
/// Guards `pending` and `style`, which the main thread writes and the
/// worker reads.
lock: std.Io.Mutex = .init,
/// Bumped by every request; the worker sleeps on it (a futex).
wake_sequence: std.atomic.Value(u32) = .init(0),
stop: std.atomic.Value(bool) = .init(false),
/// The last request number handed out. Main thread only.
request_generation_last: RequestGeneration = .none,
/// Under `lock`.
pending: Pending = .{},
/// The style to load before init.lua; empty is none. Under `lock`.
style: core.FixedStr(64) = .{},

// Worker thread only.
extensions: std.ArrayList(*Extension) = .empty,
/// Where the worker finds each command of the current registry, in the
/// registry's order.
worker_commands: []WorkerCommand = &.{},
registry_generation: RegistryGeneration = .none,
/// Extension ids and folders; reset on reload.
worker_arena: std.heap.ArenaAllocator,

// ------------------------------------------------------------- results

/// The registry's types live in registry.zig; they are re-exported here
/// because the window names them through Host.
pub const Mode = registry_mod.Mode;
pub const RegistryGeneration = generation_mod.RegistryGeneration;
pub const RequestGeneration = generation_mod.RequestGeneration;
pub const CommandIndex = registry_mod.CommandIndex;
pub const PreferenceIndex = registry_mod.PreferenceIndex;
pub const FieldIndex = registry_mod.FieldIndex;
pub const config_extension_id = registry_mod.config_extension_id;
pub const grid_columns_default = registry_mod.grid_columns_default;
pub const style_extension_id = registry_mod.style_extension_id;
pub const toggleText = registry_mod.toggleText;
pub const toggleIsOn = registry_mod.toggleIsOn;
pub const Command = registry_mod.Command;
pub const Keymap = registry_mod.Keymap;
pub const PreferenceKind = registry_mod.PreferenceKind;
pub const Preference = registry_mod.Preference;
pub const PreferenceChoice = registry_mod.PreferenceChoice;
pub const IconOverride = registry_mod.IconOverride;
pub const SettingOverride = registry_mod.SettingOverride;
pub const ExtensionInfo = registry_mod.ExtensionInfo;
pub const Problem = registry_mod.Problem;
pub const Registry = registry_mod.Registry;
pub const stamp = stamp_mod.stamp;

/// A command's rows. Owned by the receiver: `destroy`.
pub const ListResult = struct {
    generation: RequestGeneration,
    command: CommandIndex,
    query: []const u8,
    items: []Item = &.{},
    error_message: ?[:0]const u8 = null,
    arena: std.heap.ArenaAllocator,

    pub fn destroy(result: *ListResult, gpa: std.mem.Allocator) void {
        result.arena.deinit();
        gpa.destroy(result);
    }
};

/// What a run, an action or a submit asks the window to do afterwards.
pub const Outcome = enum { close, stay, refresh };

/// What a Lua action asked for. Owned by the receiver: `destroy`.
pub const ActResult = struct {
    generation: RequestGeneration,
    outcome: Outcome = .close,
    error_message: ?[:0]const u8 = null,
    arena: std.heap.ArenaAllocator,

    pub fn destroy(result: *ActResult, gpa: std.mem.Allocator) void {
        result.arena.deinit();
        gpa.destroy(result);
    }
};

/// Rows extensions give for a root search, a section per command.
/// Owned by the receiver: `destroy`.
pub const RootResult = struct {
    generation: RequestGeneration,
    query: []const u8,
    sections: []const RootSection = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn destroy(result: *RootResult, gpa: std.mem.Allocator) void {
        result.arena.deinit();
        gpa.destroy(result);
    }
};

pub const RootSection = struct { command: CommandIndex, items: []Item };

/// Called on the GTK main loop; each takes ownership of its result.
/// Each request's answer is handed to its callback on the GTK main loop,
/// with `context`: `reload` to `registry_callback`, `list` to
/// `list_callback`, `act` and `submit` to `act_callback`, `root` to
/// `root_callback`.
pub const Callbacks = struct {
    context: ?*anyopaque,
    registry_callback: *const fn (*Registry, ?*anyopaque) void,
    list_callback: *const fn (*ListResult, ?*anyopaque) void,
    act_callback: *const fn (*ActResult, ?*anyopaque) void,
    root_callback: *const fn (*RootResult, ?*anyopaque) void,
};

/// A form's values, as the UI hands them over.
pub const FormValue = struct { name: []const u8, value: []const u8, toggle: bool };

// ------------------------------------------------- the worker's own types

const c_noref = lua.c.LUA_NOREF;

/// What a reload collects; lives in the new registry's arena.
pub const Load = struct {
    arena: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    /// Parallel to `commands`: where the worker finds each one.
    worker_commands: std.ArrayList(WorkerCommand) = .empty,
    themes: std.ArrayList(themes.Theme) = .empty,
    keymaps: std.ArrayList(Keymap) = .empty,
    settings: std.ArrayList(SettingOverride) = .empty,
    preferences: std.ArrayList(Preference) = .empty,
    icons: std.ArrayList(IconOverride) = .empty,
    extensions: std.ArrayList(ExtensionInfo) = .empty,
    style_settings: std.ArrayList(SettingOverride) = .empty,
    layout: layout_mod.Layout = .{},
    has_layout: bool = false,
    problems: std.ArrayList(Problem) = .empty,

    /// What a file adds, dropped again if it fails half-way (its problem
    /// and its extension entry are added after it ran).
    const undone = .{
        "commands",
        "worker_commands",
        "themes",
        "keymaps",
        "settings",
        "preferences",
        "icons",
        "style_settings",
    };

    /// How far each list of `undone` had grown before a file ran.
    const Mark = struct {
        lengths: [undone.len]usize,
        layout: layout_mod.Layout,
        has_layout: bool,
    };

    fn mark(load: *const Load) Mark {
        var saved: Mark = .{
            .lengths = undefined,
            .layout = load.layout,
            .has_layout = load.has_layout,
        };
        inline for (undone, 0..) |field, index| {
            saved.lengths[index] = @field(load, field).items.len;
        }
        return saved;
    }

    /// Drops what was added since `saved`. Lists only grow while a file
    /// runs, so none can be shorter than it was.
    fn rollback(load: *Load, saved: Mark) void {
        inline for (undone, 0..) |field, index| {
            assert(saved.lengths[index] <= @field(load, field).items.len);
            @field(load, field).shrinkRetainingCapacity(saved.lengths[index]);
        }
        load.layout = saved.layout;
        load.has_layout = saved.has_layout;
        assert(load.commands.items.len == load.worker_commands.items.len);
    }

    /// The commands added since `saved`.
    fn commandsSince(load: *const Load, saved: Mark) usize {
        comptime assert(std.mem.eql(u8, undone[0], "commands"));
        return load.commands.items.len - saved.lengths[0];
    }
};

/// Where the worker finds a command: its state and its spec table, and the
/// lists its rows came from (their actions run there).
const WorkerCommand = struct {
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
const Kept = struct {
    reference: c_int = c_noref,
    /// The request that produced it.
    list_generation: RequestGeneration = .none,
};

/// Requests the worker has not taken yet. A newer request of a kind
/// replaces one not started.
const Pending = struct {
    reload: bool = false,
    list: ?ListRequest = null,
    root_search: ?RootSearchRequest = null,
    act: ?ActRequest = null,
    /// Owned: freed once it ran, or by the submit that replaces it.
    submit: ?*SubmitRequest = null,
};

const ListRequest = struct {
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    request_generation: RequestGeneration,
    query: core.FixedStr(query_bytes_max),
};

const RootSearchRequest = struct {
    registry_generation: RegistryGeneration,
    request_generation: RequestGeneration,
    query: core.FixedStr(query_bytes_max),
};

const ActRequest = struct {
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
const SubmitRequest = struct {
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    request_generation: RequestGeneration,
    values: []FormValue,
    arena: std.heap.ArenaAllocator,

    fn destroy(request: *SubmitRequest, gpa: std.mem.Allocator) void {
        request.arena.deinit();
        gpa.destroy(request);
    }
};

// ------------------------------------------------------- the main thread

pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError;

/// Starts the worker; call `reload` to load the files. `config_dir`
/// ($XDG_CONFIG_HOME/lumen) and `data_dir` ($XDG_DATA_HOME/lumen) are
/// copied.
pub fn start(
    gpa: std.mem.Allocator,
    io: std.Io,
    config_dir: []const u8,
    data_dir: []const u8,
    callbacks: Callbacks,
) StartError!*Host {
    const host = try gpa.create(Host);
    errdefer gpa.destroy(host);
    const config_dir_copy = try gpa.dupeSentinel(u8, config_dir, 0);
    errdefer gpa.free(config_dir_copy);
    const data_dir_copy = try gpa.dupeSentinel(u8, data_dir, 0);
    errdefer gpa.free(data_dir_copy);
    host.* = .{
        .gpa = gpa,
        .io = io,
        .config_dir = config_dir_copy,
        .data_dir = data_dir_copy,
        .callbacks = callbacks,
        .worker_arena = .init(gpa),
    };
    host.thread = try std.Thread.spawn(.{}, run, .{host});
    // Cosmetic: the name only shows in tools like top.
    host.thread.setName(io, "lm-ext") catch {};
    return host;
}

/// Stops and joins the worker and closes every state. Call once the GTK
/// main loop has stopped (a queued result would reach a freed host).
pub fn shutdown(host: *Host) void {
    host.stop.store(true, .release);
    host.wake();
    host.thread.join();
    if (host.pending.submit) |request| request.destroy(host.gpa);
    host.closeAll();
    host.extensions.deinit(host.gpa);
    host.worker_arena.deinit();
    host.gpa.free(host.config_dir);
    host.gpa.free(host.data_dir);
    host.gpa.destroy(host);
}

/// The style loaded before init.lua from the next reload on: a folder in
/// <config>/styles, else a built-in one; empty for none. False when it was
/// that one already.
pub fn setStyle(host: *Host, name: []const u8) bool {
    host.lock.lockUncancelable(host.io);
    defer host.lock.unlock(host.io);
    var next: core.FixedStr(64) = .{};
    next.set(name);
    if (host.style.eql(next.slice())) return false;
    host.style = next;
    return true;
}

/// Loads every file again; the new registry arrives through the callback.
pub fn reload(host: *Host) void {
    {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        host.pending.reload = true;
    }
    host.wake();
}

/// Asks for command `command`'s rows (`query` for search commands; longer
/// queries are cut). Returns the request's generation; a newer list request
/// replaces one not started yet.
pub fn list(
    host: *Host,
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    query: []const u8,
) RequestGeneration {
    const request_generation = host.requestGenerationNext();
    var request: ListRequest = .{
        .registry_generation = registry_generation,
        .command = command,
        .request_generation = request_generation,
        .query = .{},
    };
    request.query.set(query);
    {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        host.pending.list = request;
    }
    host.wake();
    return request_generation;
}

/// Calls form `command`'s submit with `values` (copied). Its answer comes
/// like an action's.
pub fn submit(
    host: *Host,
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    values: []const FormValue,
) RequestGeneration {
    // The window sends one value per field of the form, and a form has at
    // most `form_fields_max`.
    assert(values.len >= 1);
    assert(values.len <= form_fields_max);
    const request_generation = host.requestGenerationNext();
    const request = submitRequestCreate(
        host.gpa,
        registry_generation,
        command,
        request_generation,
        values,
    ) catch {
        log.warn("submit: out of memory, not sent", .{});
        return request_generation;
    };
    const replaced = blk: {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        const replaced = host.pending.submit;
        host.pending.submit = request;
        break :blk replaced;
    };
    if (replaced) |old_request| old_request.destroy(host.gpa);
    host.wake();
    return request_generation;
}

/// A submit request owning copies of `values`. All of them or none: half
/// copied values would reach the extension as if the user had left fields
/// empty.
fn submitRequestCreate(
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

/// Asks every command with `root` for rows for `query`; a newer root
/// request replaces one not started yet.
pub fn root(
    host: *Host,
    registry_generation: RegistryGeneration,
    query: []const u8,
) RequestGeneration {
    const request_generation = host.requestGenerationNext();
    var request: RootSearchRequest = .{
        .registry_generation = registry_generation,
        .request_generation = request_generation,
        .query = .{},
    };
    request.query.set(query);
    {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        host.pending.root_search = request;
    }
    host.wake();
    return request_generation;
}

/// What `act` runs: a command's own `run`, or one action of a row the
/// command listed (in its list or in the root search).
pub const ActTarget = ActRequest.Target;

/// Runs a Lua action of `command`; see `ActTarget`.
pub fn act(
    host: *Host,
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    target: ActTarget,
) RequestGeneration {
    const request_generation = host.requestGenerationNext();
    {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        host.pending.act = .{
            .registry_generation = registry_generation,
            .command = command,
            .request_generation = request_generation,
            .target = target,
        };
    }
    host.wake();
    return request_generation;
}

/// The window keeps 0 for "no request pending" (`ext_act_generation`), so 0 is
/// never handed out, even after the counter wraps.
fn requestGenerationNext(host: *Host) RequestGeneration {
    host.request_generation_last = host.request_generation_last.next();
    return host.request_generation_last;
}

/// Wakes the worker: bumps the sequence it sleeps on.
fn wake(host: *Host) void {
    _ = host.wake_sequence.fetchAdd(1, .release);
    host.io.futexWake(u32, &host.wake_sequence.raw, 1);
}

// ------------------------------------------------------------ the worker

/// The worker's loop. It sleeps until a request comes, takes every pending
/// request under the lock, then runs them outside it, in this order: a
/// reload first, so that requests made against the old registry are
/// refused; then an action and a submit, so that the lists asked for with
/// them show what they changed; then the lists.
fn run(host: *Host) void {
    var wake_sequence_seen: u32 = 0;
    while (host.waitForWork(wake_sequence_seen)) |wake_sequence| {
        wake_sequence_seen = wake_sequence;
        const pending = host.pendingTake();
        if (pending.reload) host.reloadExecute();
        if (pending.act) |request| host.actExecute(request);
        if (pending.submit) |request| host.submitExecute(request);
        if (pending.list) |request| host.listExecute(&request);
        if (pending.root_search) |request| host.rootSearchExecute(&request);
    }
}

/// Sleeps until a request comes, and returns the wake sequence then; null
/// once `shutdown` asks the worker to stop.
fn waitForWork(host: *Host, wake_sequence_seen: u32) ?u32 {
    while (true) {
        if (host.stop.load(.acquire)) return null;
        const wake_sequence = host.wake_sequence.load(.acquire);
        if (wake_sequence != wake_sequence_seen) return wake_sequence;
        host.io.futexWaitUncancelable(u32, &host.wake_sequence.raw, wake_sequence_seen);
    }
}

fn pendingTake(host: *Host) Pending {
    host.lock.lockUncancelable(host.io);
    defer host.lock.unlock(host.io);
    const pending = host.pending;
    host.pending = .{};
    return pending;
}

// --------------------------------------------------------------- reload

fn closeAll(host: *Host) void {
    for (host.extensions.items) |extension| extension.destroy();
    host.extensions.clearRetainingCapacity();
    host.gpa.free(host.worker_commands);
    host.worker_commands = &.{};
    _ = host.worker_arena.reset(.retain_capacity);
}

fn reloadExecute(host: *Host) void {
    host.closeAll();
    host.registry_generation = host.registry_generation.next();
    const registry = host.answerCreate(Registry, "reload", .{
        .generation = host.registry_generation,
        .arena = .init(host.gpa),
    }) orelse return;
    var load: Load = .{ .arena = registry.arena.allocator() };
    host.loadAll(&load);
    host.registryFill(registry, &load);
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
            problem(load, style_extension_id, "out of memory");
            break :blk "";
        };
    };
    if (style.len > 0) host.loadStyle(load, style);

    if (worker_arena.printSentinel("{s}/init.lua", .{host.config_dir}, 0)) |path| {
        if (os.info(path) != null) {
            host.loadSource(load, config_extension_id, host.config_dir, path, null);
        }
    } else |_| {
        problem(load, config_extension_id, "out of memory");
    }

    for (host.extensionDirs(worker_arena)) |id| host.loadExtension(load, id);
}

/// The extension in extensions/<id>, when its folder name is one.
fn loadExtension(host: *Host, load: *Load, id: [:0]const u8) void {
    const worker_arena = host.worker_arena.allocator();
    if (!validId(id)) {
        problem(load, id, "extension folder names may use only a-z, 0-9, - and _");
        return;
    }
    if (reservedId(id)) {
        const message =
            "\"config\" and \"style\" are taken (init.lua and the style); rename the folder";
        problem(load, id, message);
        return;
    }
    const folder_format = "{s}/extensions/{s}";
    const folder = worker_arena.printSentinel(folder_format, .{ host.config_dir, id }, 0) catch {
        problem(load, id, "out of memory");
        return;
    };
    const path = worker_arena.printSentinel("{s}/init.lua", .{folder}, 0) catch {
        problem(load, id, "out of memory");
        return;
    };
    if (os.info(path) == null) {
        problem(load, id, "no init.lua in the extension's folder");
        return;
    }
    host.loadSource(load, id, folder, path, null);
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

/// Whether `id` may name an extension's folder, a command or a field:
/// 1 to `id_bytes_max` of a-z, 0-9, - and _.
pub fn validId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (id.len > id_bytes_max) return false;
    for (id) |character| {
        if (!isIdCharacter(character)) return false;
    }
    return true;
}

fn isIdCharacter(character: u8) bool {
    return std.ascii.isLower(character) or std.ascii.isDigit(character) or
        character == '-' or character == '_';
}

/// The ids init.lua and the style run as. An extension named so would share
/// their preferences and storage, and its themes and settings would pass
/// for theirs.
pub fn reservedId(id: []const u8) bool {
    return std.mem.eql(u8, id, config_extension_id) or std.mem.eql(u8, id, style_extension_id);
}

/// Reports what went wrong with a file in Settings > Extensions. Out of
/// memory, the report goes to the log instead, so it is never lost.
fn problem(load: *Load, extension_id: []const u8, message: []const u8) void {
    problemAppend(load, extension_id, message) catch {
        log.warn("{s}: {s} (not shown in Settings: out of memory)", .{ extension_id, message });
    };
}

fn problemAppend(
    load: *Load,
    extension_id: []const u8,
    message: []const u8,
) error{OutOfMemory}!void {
    const extension_id_copy = try load.arena.dupeSentinel(u8, extension_id, 0);
    const message_copy = try load.arena.dupeSentinel(u8, message, 0);
    try load.problems.append(load.arena, .{
        .extension = extension_id_copy,
        .message = message_copy,
    });
}

/// Lists an extension that loaded in Settings > Extensions. Out of memory,
/// it is reported as a problem instead: an entry with an empty id would
/// reach the views that act on an extension by its id.
fn extensionLoaded(load: *Load, id: []const u8, title: [:0]const u8, commands_count: usize) void {
    extensionLoadedAppend(load, id, title, commands_count) catch {
        problem(load, id, "loaded, but out of memory to list it");
    };
}

fn extensionLoadedAppend(
    load: *Load,
    id: []const u8,
    title: [:0]const u8,
    commands_count: usize,
) error{OutOfMemory}!void {
    const id_copy = try load.arena.dupeSentinel(u8, id, 0);
    try load.extensions.append(load.arena, .{
        .id = id_copy,
        .title = if (title.len > 0) title else id_copy,
        .commands = @intCast(commands_count),
    });
}

/// A style: <config>/styles/<name>/init.lua, else the built-in one. Its
/// file runs as the extension "style".
fn loadStyle(host: *Host, load: *Load, name: []const u8) void {
    const worker_arena = host.worker_arena.allocator();
    const folder = worker_arena.printSentinel("{s}/styles/{s}", .{ host.config_dir, name }, 0) catch
        return;
    const path = worker_arena.printSentinel("{s}/init.lua", .{folder}, 0) catch return;
    if (os.info(path) != null) {
        host.loadSource(load, style_extension_id, folder, path, null);
    } else if (os.info(folder) != null) {
        // A style folder may hold only a style.css.
    } else if (styles.find(name)) |built_in| {
        host.loadSource(load, style_extension_id, host.config_dir, "=style", built_in.lua);
    } else {
        problem(load, style_extension_id, "no such style");
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
        problem(load, id, "out of memory");
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
            if (!reservedId(id)) {
                extensionLoaded(load, id, context.title, load.commandsSince(before));
            }
            return;
        } else |_| {
            // Out of memory: undone below, like a file that failed.
        }
    }
    load.rollback(before);
    problem(load, id, failure orelse "out of memory");
    extension.destroy();
}

const LoadContext = struct {
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
    if (!validId(name)) {
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
    if (fields_count == 0 or fields_count > form_fields_max) {
        lua.raise(L, "{s}.fields: 1 to {d} fields", .{ where, form_fields_max });
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
    assert(fields.len <= form_fields_max);
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

// ----------------------------------------------------------------- list

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

fn listExecute(host: *Host, request: *const ListRequest) void {
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
    const worker_command = host.requested(request.registry_generation, request.command) orelse {
        result.error_message = reloaded;
        return;
    };
    const extension = host.extensionOf(worker_command);
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
        }, items_max);
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

// ----------------------------------------------------------------- root

fn rootSearchExecute(host: *Host, request: *const RootSearchRequest) void {
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
        if (host.rootSearchSuperseded()) break;
        const command: CommandIndex = .from(command_index);
        const items = host.rootSearchCommand(arena, &rows, worker_command, command, request);
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
    const extension = host.extensionOf(worker_command);
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
        }, root_search_items_max);
    }
};

// --------------------------------------------------------------- submit

fn submitExecute(host: *Host, request: *SubmitRequest) void {
    defer request.destroy(host.gpa);
    const result = host.answerCreate(ActResult, "submit", .{
        .generation = request.request_generation,
        .arena = .init(host.gpa),
    }) orelse return;
    defer host.deliver(.{ .act = result });
    const worker_command = host.requested(request.registry_generation, request.command) orelse {
        result.error_message = reloaded;
        return;
    };
    assert(request.values.len <= form_fields_max);
    const extension = host.extensionOf(worker_command);
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

// ------------------------------------------------------------------ act

fn actExecute(host: *Host, request: ActRequest) void {
    const result = host.answerCreate(ActResult, "action", .{
        .generation = request.request_generation,
        .arena = .init(host.gpa),
    }) orelse return;
    defer host.deliver(.{ .act = result });
    const worker_command = host.requested(request.registry_generation, request.command) orelse {
        result.error_message = reloaded;
        return;
    };
    const extension = host.extensionOf(worker_command);
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

// ------------------------------------------------------------- delivery

/// An answer for the window (a Registry, ListResult, ActResult or
/// RootResult), owned by it once delivered. Null when out of memory: the
/// request then gets no answer, as if a newer one had replaced it, and the
/// log says which kind was dropped.
fn answerCreate(host: *Host, comptime T: type, what: []const u8, answer: T) ?*T {
    comptime assert(@hasField(T, "generation"));
    comptime assert(@hasField(T, "arena"));
    const created = host.gpa.create(T) catch {
        log.warn("{s}: out of memory, no answer", .{what});
        return null;
    };
    created.* = answer;
    return created;
}

/// An answer the worker hands to the main loop, which owns it from then on.
const Answer = union(enum) {
    registry: *Registry,
    list: *ListResult,
    act: *ActResult,
    root: *RootResult,
};

const Delivery = struct { host: *Host, answer: Answer };

fn deliver(host: *Host, answer: Answer) void {
    const delivery = host.gpa.create(Delivery) catch {
        log.warn("out of memory: an answer for the window is dropped", .{});
        switch (answer) {
            inline else => |result| result.destroy(host.gpa),
        }
        return;
    };
    delivery.* = .{ .host = host, .answer = answer };
    _ = c.g_idle_add(&deliverCallback, delivery);
}

/// On the GTK main loop: hands the answer to its callback.
fn deliverCallback(data: ?*anyopaque) callconv(.c) c.gboolean {
    const delivery: *Delivery = @ptrCast(@alignCast(data.?));
    const host = delivery.host;
    defer host.gpa.destroy(delivery);
    const callbacks = host.callbacks;
    switch (delivery.answer) {
        .registry => |registry| callbacks.registry_callback(registry, callbacks.context),
        .list => |result| callbacks.list_callback(result, callbacks.context),
        .act => |result| callbacks.act_callback(result, callbacks.context),
        .root => |result| callbacks.root_callback(result, callbacks.context),
    }
    return 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Collects what the host delivers; the test pumps GLib's main loop.
const Probe = struct {
    registry: ?*Registry = null,
    list: ?*ListResult = null,
    act: ?*ActResult = null,
    root: ?*RootResult = null,

    fn registryCallback(answer: *Registry, context: ?*anyopaque) void {
        const probe: *Probe = @ptrCast(@alignCast(context.?));
        if (probe.registry) |old| old.destroy(testing.allocator);
        probe.registry = answer;
    }
    fn listCallback(answer: *ListResult, context: ?*anyopaque) void {
        const probe: *Probe = @ptrCast(@alignCast(context.?));
        if (probe.list) |old| old.destroy(testing.allocator);
        probe.list = answer;
    }
    fn actCallback(answer: *ActResult, context: ?*anyopaque) void {
        const probe: *Probe = @ptrCast(@alignCast(context.?));
        if (probe.act) |old| old.destroy(testing.allocator);
        probe.act = answer;
    }
    fn rootCallback(answer: *RootResult, context: ?*anyopaque) void {
        const probe: *Probe = @ptrCast(@alignCast(context.?));
        if (probe.root) |old| old.destroy(testing.allocator);
        probe.root = answer;
    }
    fn deinit(probe: *Probe) void {
        if (probe.root) |answer| answer.destroy(testing.allocator);
        if (probe.registry) |answer| answer.destroy(testing.allocator);
        if (probe.list) |answer| answer.destroy(testing.allocator);
        if (probe.act) |answer| answer.destroy(testing.allocator);
    }
    /// Pumps the main loop until `field` is set (up to 10 s).
    fn wait(probe: *Probe, comptime field: []const u8) !void {
        const until_ns = os.monotonicNs() + 10 * std.time.ns_per_s;
        while (@field(probe, field) == null) {
            if (os.monotonicNs() > until_ns) return error.Timeout;
            // Nothing is ready: nap for 1 ms (a poll with no descriptors).
            if (c.g_main_context_iteration(null, 0) == 0) {
                _ = std.os.linux.poll(&[0]std.os.linux.pollfd{}, 0, 1);
            }
        }
    }
    fn take(probe: *Probe, comptime field: []const u8) !@TypeOf(@field(probe, field).?) {
        try probe.wait(field);
        const answer = @field(probe, field).?;
        @field(probe, field) = null;
        return answer;
    }
};

fn writeTestFile(folder: []const u8, name: []const u8, data: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    const path = try std.mem.printSentinel(&buffer, "{s}/{s}", .{ folder, name }, 0);
    if (std.mem.findScalarLast(u8, path, '/')) |slash| try os.mkdirP(path[0..slash]);
    try os.writeFile(path, data);
}

fn testHost(probe: *Probe, folder: []const u8) !*Host {
    var data_path_buffer: [4096]u8 = undefined;
    const data = try std.mem.print(&data_path_buffer, "{s}/data", .{folder});
    return start(testing.allocator, testing.io, folder, data, .{
        .context = probe,
        .registry_callback = &Probe.registryCallback,
        .list_callback = &Probe.listCallback,
        .act_callback = &Probe.actCallback,
        .root_callback = &Probe.rootCallback,
    });
}

test "request generations skip none, which the window keeps for nothing pending" {
    var host: Host = undefined;
    host.request_generation_last = @fromBackingInt(@intCast(std.math.maxInt(u32)));
    const first: RequestGeneration = @fromBackingInt(@intCast(1));
    const second: RequestGeneration = @fromBackingInt(@intCast(2));
    try testing.expectEqual(first, host.requestGenerationNext());
    try testing.expectEqual(second, host.requestGenerationNext());
}

test {
    _ = generation_mod;
    _ = stamp_mod;
}

test "extensions load, list, search and run actions" {
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const folder = try os.tmpDirPath(&test_dir, &path_buffer);
    try writeTestFile(folder, "init.lua",
        \\lumen.theme { id = "mine", name = "Mine", bg = "#101010", fg = "#f0f0f0", accent = "#ff8800" }
        \\lumen.keymap("ctrl+g", "demo.fruits")
        \\lumen.set { width = "wide", suggestions = false, opacity = 90 }
        \\lumen.layout { width = 820, panels = "single", footer = true }
        \\lumen.layout { rows = "inline", show = { icons = false } }
        \\return lumen.extension { commands = { { name = "hello", title = "Say Hello", run = function() return "stay" end } } }
    );
    try writeTestFile(folder, "extensions/demo/init.lua",
        \\local lumen = require("lumen")
        \\local util = require("util")
        \\return lumen.extension {
        \\  title = "Demo", icon = "🍎",
        \\  commands = {
        \\    { name = "fruits", title = "Fruits", detail = true, items = {
        \\        "Apple",
        \\        { title = "Banana", subtitle = "yellow", section = "Long", detail = "a long fruit",
        \\          actions = { lumen.action.copy("banana"), { title = "Eat", run = function(row) util.eaten = row.title; row.actions = nil end } } },
        \\    } },
        \\    { name = "echo", title = "Echo", search = function(q)
        \\        local out = lumen.exec({ "sh", "-c", "printf %s \"$1\"", "sh", q })
        \\        return { { title = "you typed " .. out } }
        \\    end },
        \\    { name = "eaten", title = "Eaten", items = function() return { util.eaten or "nothing" } end },
        \\    { name = "double", title = "Doubler", root = function(q)
        \\        local n = tonumber(q)
        \\        if not n then return nil end
        \\        return { { title = tostring(n * 2), actions = { { title = "Note", run = function(row) util.eaten = row.title end } } } }
        \\    end },
        \\  },
        \\}
    );
    try writeTestFile(folder, "extensions/demo/util.lua", "return {}");
    try writeTestFile(
        folder,
        "extensions/broken/init.lua",
        "return lumen.extension { commands = { { name = 'x' } } }",
    );

    var probe: Probe = .{};
    defer probe.deinit();
    const host = try testHost(&probe, folder);
    defer host.shutdown();
    host.reload();
    try probe.wait("registry");
    const registry = probe.registry.?;

    try testing.expectEqual(@as(usize, 5), registry.commands.len);
    try testing.expectEqual(Mode.provider, registry.commands[4].mode);
    try testing.expect(registry.commands[4].answers_root_search);
    try testing.expect(!registry.commands[1].answers_root_search);
    try testing.expectEqualStrings("config.hello", registry.commands[0].id);
    try testing.expectEqual(Mode.run, registry.commands[0].mode);
    try testing.expectEqualStrings("demo.fruits", registry.commands[1].id);
    try testing.expectEqualStrings("Demo", registry.commands[1].subtitle);
    try testing.expectEqualStrings("🍎", registry.commands[1].icon.emoji);
    try testing.expect(registry.commands[1].detail);
    try testing.expectEqual(Mode.search, registry.commands[2].mode);
    try testing.expectEqual(@as(usize, 1), registry.themes.len);
    try testing.expectEqual(@as(u24, 0xff8800), registry.themes[0].accent);
    try testing.expectEqual(@as(u24, 0x101010), registry.themes[0].surface);
    try testing.expectEqual(@as(usize, 1), registry.keymaps.len);
    try testing.expectEqualStrings("demo.fruits", registry.keymaps[0].target);
    try testing.expectEqual(@as(usize, 3), registry.settings.len);
    // Several lumen.layout calls add up.
    try testing.expect(registry.has_layout);
    try testing.expectEqual(@as(?u16, 820), registry.layout.width);
    try testing.expect(registry.layout.footer);
    try testing.expect(registry.layout.panels == .single);
    try testing.expect(registry.layout.rows == .@"inline");
    try testing.expect(!registry.layout.show.icons and registry.layout.show.subtitles);
    const settings_expected = std.StaticStringMap([]const u8).initComptime(.{
        .{ "width", "wide" },
        .{ "suggestions", "false" },
        .{ "opacity", "90" },
    });
    try testing.expectEqual(settings_expected.kvs.len, registry.settings.len);
    for (registry.settings) |setting| {
        try testing.expectEqualStrings(settings_expected.get(setting.key).?, setting.value);
    }
    // The broken one is reported, the others load.
    try testing.expectEqual(@as(usize, 1), registry.problems.len);
    try testing.expectEqualStrings("broken", registry.problems[0].extension);
    try testing.expect(std.mem.find(u8, registry.problems[0].message, "title is missing") != null);

    // A list command's rows.
    const fruits_generation = host.list(registry.generation, .from(1), "");
    const fruits = try probe.take("list");
    defer fruits.destroy(testing.allocator);
    try testing.expectEqual(fruits_generation, fruits.generation);
    try testing.expect(fruits.error_message == null);
    try testing.expectEqual(@as(usize, 2), fruits.items.len);
    try testing.expectEqualStrings("Apple", fruits.items[0].title);
    try testing.expectEqualStrings(
        "Copy to Clipboard",
        fruits.items[0].action.ext_item.entries[0].label,
    );
    const banana = fruits.items[1];
    try testing.expectEqualStrings("yellow", banana.subtitle);
    try testing.expectEqualStrings("Long", banana.section);
    try testing.expectEqualStrings("a long fruit", banana.detail);
    try testing.expectEqualStrings("banana", banana.action.ext_item.actions[0].copy);
    try testing.expectEqual(item_mod.ExtAction.lua, banana.action.ext_item.actions[1]);
    try testing.expectEqualStrings("Ctrl ↵", banana.action.ext_item.entries[1].keys);

    // Its Lua action runs against that list, and changes state other
    // commands of the extension see.
    const action_generation = host.act(registry.generation, .from(1), .{ .row_action = .{
        .from_root_search = false,
        .list_generation = fruits.generation,
        .row_index = 1,
        .action_index = 1,
    } });
    const done = try probe.take("act");
    defer done.destroy(testing.allocator);
    try testing.expectEqual(action_generation, done.generation);
    try testing.expect(done.error_message == null);
    try testing.expectEqual(Outcome.close, done.outcome);
    // The action took its row's actions away: pressing it again is an
    // error, not a read of whatever `row.actions` is now.
    _ = host.act(registry.generation, .from(1), .{ .row_action = .{
        .from_root_search = false,
        .list_generation = fruits.generation,
        .row_index = 1,
        .action_index = 1,
    } });
    const again = try probe.take("act");
    defer again.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, again.error_message.?, "no actions") != null);
    _ = host.list(registry.generation, .from(3), "");
    const eaten = try probe.take("list");
    defer eaten.destroy(testing.allocator);
    try testing.expectEqualStrings("Banana", eaten.items[0].title);

    // A search command gets the query, and lumen.exec runs programs.
    _ = host.list(registry.generation, .from(2), "it's \"quoted\"");
    const echo = try probe.take("list");
    defer echo.destroy(testing.allocator);
    try testing.expect(echo.error_message == null);
    try testing.expectEqualStrings("you typed it's \"quoted\"", echo.items[0].title);

    // A run command's return value.
    _ = host.act(registry.generation, .from(0), .command_run);
    const hello = try probe.take("act");
    defer hello.destroy(testing.allocator);
    try testing.expectEqual(Outcome.stay, hello.outcome);

    // Root search: rows from providers, their Lua actions run there.
    const root_generation = host.root(registry.generation, "21");
    const root_answer = try probe.take("root");
    defer root_answer.destroy(testing.allocator);
    try testing.expectEqual(root_generation, root_answer.generation);
    try testing.expectEqual(@as(usize, 1), root_answer.sections.len);
    try testing.expectEqual(CommandIndex.from(4), root_answer.sections[0].command);
    const doubled = root_answer.sections[0].items[0];
    try testing.expectEqualStrings("42", doubled.title);
    try testing.expect(doubled.action.ext_item.from_root_search);
    _ = host.act(registry.generation, .from(4), .{ .row_action = .{
        .from_root_search = true,
        .list_generation = doubled.action.ext_item.list_generation,
        .row_index = 0,
        .action_index = 0,
    } });
    (try probe.take("act")).destroy(testing.allocator);
    _ = host.list(registry.generation, .from(3), "");
    const noted = try probe.take("list");
    defer noted.destroy(testing.allocator);
    try testing.expectEqualStrings("42", noted.items[0].title);
    _ = host.root(registry.generation, "not a number");
    const none = try probe.take("root");
    defer none.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.sections.len);

    // An action against a list that has been replaced is refused.
    _ = host.list(registry.generation, .from(1), "");
    (try probe.take("list")).destroy(testing.allocator);
    _ = host.act(registry.generation, .from(1), .{ .row_action = .{
        .from_root_search = false,
        .list_generation = fruits.generation,
        .row_index = 1,
        .action_index = 1,
    } });
    const stale = try probe.take("act");
    defer stale.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, stale.error_message.?, "changed") != null);

    // After a reload, requests against the old registry are refused.
    host.reload();
    try probe.wait("registry");
    _ = host.list(registry.generation, .from(1), "");
    const old = try probe.take("list");
    defer old.destroy(testing.allocator);
    try testing.expectEqualStrings("Extensions were reloaded", old.error_message.?);
}

test "errors in extensions come back as messages" {
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const folder = try os.tmpDirPath(&test_dir, &path_buffer);
    try writeTestFile(folder, "extensions/bad/init.lua",
        \\return lumen.extension { commands = {
        \\  { name = "boom", title = "Boom", items = function() error("kaboom") end },
        \\  { name = "loop", title = "Loop", search = function() while true do end end },
        \\  { name = "badrow", title = "Bad Row", items = { { subtitle = "no title" } } },
        \\  { name = "badret", title = "Bad Return", run = function() return 42 end },
        \\} }
    );
    try writeTestFile(folder, "extensions/syntax/init.lua", "return lumen.extension {");
    try writeTestFile(folder, "extensions/Bad Name/init.lua", "return nil");
    try writeTestFile(folder, "extensions/keys/init.lua", "lumen.keymap('g', 'x.y')");
    try writeTestFile(folder, "extensions/sets/init.lua", "lumen.set { widht = 'wide' }");
    try writeTestFile(folder, "extensions/lay/init.lua", "lumen.layout { panels = 'triple' }");

    var probe: Probe = .{};
    defer probe.deinit();
    const host = try testHost(&probe, folder);
    defer host.shutdown();
    host.reload();
    try probe.wait("registry");
    const registry = probe.registry.?;
    try testing.expectEqual(@as(usize, 4), registry.commands.len);
    try testing.expectEqual(@as(usize, 5), registry.problems.len);
    try testing.expect(!registry.has_layout);
    // What each broken extension's report says; the one not listed is the
    // file with a syntax error.
    const messages_expected = std.StaticStringMap([]const u8).initComptime(.{
        .{ "Bad Name", "folder names" },
        .{ "keys", "needs ctrl" },
        .{ "sets", "no setting named \"widht\"" },
        .{ "lay", "bad value for panels" },
    });
    for (registry.problems) |problem_reported| {
        const message_expected = messages_expected.get(problem_reported.extension) orelse
            "unexpected symbol near <eof>";
        if (std.mem.find(u8, problem_reported.message, message_expected) == null) {
            const extension_id = problem_reported.extension;
            std.debug.print("{s}: {s}\n", .{ extension_id, problem_reported.message });
            return error.TestUnexpectedResult;
        }
    }

    _ = host.list(registry.generation, .from(0), "");
    const boom = try probe.take("list");
    defer boom.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, boom.error_message.?, "kaboom") != null);

    _ = host.list(registry.generation, .from(2), "");
    const bad_row = try probe.take("list");
    defer bad_row.destroy(testing.allocator);
    const bad_row_message = bad_row.error_message.?;
    try testing.expect(std.mem.find(u8, bad_row_message, "items[1].title is missing") != null);

    _ = host.act(registry.generation, .from(3), .command_run);
    const bad_return = try probe.take("act");
    defer bad_return.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, bad_return.error_message.?, "must return") != null);
}

test "preferences read Settings' file over their defaults; storage persists" {
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const folder = try os.tmpDirPath(&test_dir, &path_buffer);
    try writeTestFile(folder, "extensions/kv/init.lua",
        \\return lumen.extension {
        \\  preferences = {
        \\    { name = "who", title = "Who", type = "text", default = "nobody" },
        \\    { name = "loud", title = "Loud", type = "toggle" },
        \\    { name = "size", title = "Size", type = "choice", choices = { "s", { value = "m", title = "Medium" } } },
        \\  },
        \\  commands = {
        \\    { name = "show", title = "Show", items = function()
        \\        local ok = pcall(function() lumen.preferences.who = "x" end)
        \\        return { lumen.preferences.who, tostring(lumen.preferences.loud), lumen.preferences.size,
        \\                 tostring(lumen.storage.get("count")), tostring(ok) }
        \\    end },
        \\    { name = "bump", title = "Bump", run = function()
        \\        lumen.storage.set("count", (lumen.storage.get("count") or 0) + 1)
        \\    end },
        \\  },
        \\}
    );
    // What Settings writes.
    try writeTestFile(folder, "data/extensions/kv/preferences.json", "{\"loud\": true}");

    var probe: Probe = .{};
    defer probe.deinit();
    const host = try testHost(&probe, folder);
    defer host.shutdown();
    host.reload();
    try probe.wait("registry");
    const registry = probe.registry.?;
    try testing.expectEqual(@as(usize, 3), registry.preferences.len);
    try testing.expectEqual(PreferenceKind.toggle, registry.preferences[1].kind);
    try testing.expectEqualStrings("false", registry.preferences[1].default);
    try testing.expectEqualStrings("s", registry.preferences[2].default);
    try testing.expectEqualStrings("Medium", registry.preferences[2].choices[1].label);
    try testing.expect(std.mem.endsWith(
        u8,
        registry.preferences[0].file,
        "data/extensions/kv/preferences.json",
    ));

    _ = host.list(registry.generation, .from(0), "");
    const before = try probe.take("list");
    defer before.destroy(testing.allocator);
    const want = [_][]const u8{ "nobody", "true", "s", "nil", "false" };
    try testing.expect(before.error_message == null);
    for (want, before.items) |wanted, row| try testing.expectEqualStrings(wanted, row.title);

    _ = host.act(registry.generation, .from(1), .command_run);
    (try probe.take("act")).destroy(testing.allocator);
    _ = host.act(registry.generation, .from(1), .command_run);
    (try probe.take("act")).destroy(testing.allocator);
    // Storage outlives a reload (a new Lua state reads the file).
    probe.registry = null;
    defer registry.destroy(testing.allocator);
    host.reload();
    try probe.wait("registry");
    const registry_reloaded = probe.registry.?;
    _ = host.list(registry_reloaded.generation, .from(0), "");
    const after = try probe.take("list");
    defer after.destroy(testing.allocator);
    try testing.expectEqualStrings("2", after.items[3].title);
}

test "storage never writes over what it cannot read, and reads back what it wrote" {
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const folder = try os.tmpDirPath(&test_dir, &path_buffer);
    const read_back =
        \\local function file() local f = io.open(lumen.data_dir .. "/storage.json") local t = f:read("a") f:close() return t end
        \\local ok, err = pcall(lumen.storage.set, "k", "v")
        \\local back = ok and lumen.json.decode(file()).k
        \\return lumen.extension { commands = { { name = "show", title = "Show", items = {
        \\  tostring(ok), (tostring(err):find("not overwritten") and "not overwritten" or tostring(err)),
        \\  file(), tostring(lumen.storage.get("k")), tostring(back),
        \\} } } }
    ;
    try writeTestFile(folder, "extensions/broken/init.lua", read_back);
    try writeTestFile(folder, "data/extensions/broken/storage.json", "{\"a\": 1, oops");
    // Bytes that are not UTF-8 are stored as U+FFFD, so the file still reads.
    try writeTestFile(folder, "extensions/bytes/init.lua", "lumen.storage.set('x', 'a\\xffb')\n" ++ read_back);
    // Folders named like init.lua and the style would share their files.
    try writeTestFile(folder, "extensions/config/init.lua", "return nil");
    try writeTestFile(folder, "extensions/style/init.lua", "return nil");

    var probe: Probe = .{};
    defer probe.deinit();
    const host = try testHost(&probe, folder);
    defer host.shutdown();
    host.reload();
    try probe.wait("registry");
    const registry = probe.registry.?;
    try testing.expectEqual(@as(usize, 2), registry.problems.len);
    for (registry.problems) |registry_problem| {
        try testing.expect(std.mem.find(u8, registry_problem.message, "are taken") != null);
    }

    _ = host.list(registry.generation, .from(0), "");
    const broken = try probe.take("list");
    defer broken.destroy(testing.allocator);
    try testing.expect(broken.error_message == null);
    const want = [_][]const u8{ "false", "not overwritten", "{\"a\": 1, oops", "nil" };
    for (want, broken.items[0..want.len]) |wanted, row| {
        try testing.expectEqualStrings(wanted, row.title);
    }

    _ = host.list(registry.generation, .from(1), "");
    const bytes = try probe.take("list");
    defer bytes.destroy(testing.allocator);
    try testing.expect(bytes.error_message == null);
    try testing.expectEqualStrings("true", bytes.items[0].title);
    try testing.expectEqualStrings("v", bytes.items[4].title);
    try testing.expect(std.mem.find(u8, bytes.items[2].title, "\"a\u{FFFD}b\"") != null);
}

test "rows are kept to a size, and lumen.exec's strings outlive its options" {
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const folder = try os.tmpDirPath(&test_dir, &path_buffer);
    try writeTestFile(folder, "extensions/odd/init.lua",
        \\return lumen.extension { commands = {
        \\  { name = "big", title = "Big", items = function()
        \\      local s = string.rep("x", 5 << 20)
        \\      local rows = {}
        \\      for i = 1, 1000 do rows[i] = { title = "r" .. i, actions = { lumen.action.copy(s) } } end
        \\      return rows
        \\  end },
        \\  { name = "long", title = "Long", items = function()
        \\      return { { title = string.rep("é", 1000), detail = string.rep("d", 1 << 20),
        \\                 metadata = { { "k", string.rep("v", 5000) } } } }
        \\  end },
        \\  { name = "exec", title = "Exec", items = function()
        \\      -- Long strings are not interned: `want` is another string, and
        \\      -- once argv lets go, argv[3] can be collected.
        \\      local argv = { "printf", "%s", string.rep("x", 200) .. "z" }
        \\      local want = string.rep("x", 200) .. "z"
        \\      local opts = setmetatable({}, { __index = function()
        \\          argv[1], argv[2], argv[3] = nil, nil, nil
        \\          collectgarbage() collectgarbage()
        \\          for i = 1, 2000 do local _ = string.rep("y", 201) .. i end
        \\      end })
        \\      return { tostring(lumen.exec(argv, opts) == want) }
        \\  end },
        \\} }
    );

    var probe: Probe = .{};
    defer probe.deinit();
    const host = try testHost(&probe, folder);
    defer host.shutdown();
    host.reload();
    try probe.wait("registry");
    const registry = probe.registry.?;

    // One string 1000 rows copy: 5 GB outside the state's memory cap.
    _ = host.list(registry.generation, .from(0), "");
    const big = try probe.take("list");
    defer big.destroy(testing.allocator);
    try testing.expectEqualStrings(rows_too_big, big.error_message.?);

    _ = host.list(registry.generation, .from(1), "");
    const long = try probe.take("list");
    defer long.destroy(testing.allocator);
    try testing.expect(long.error_message == null);
    const row = long.items[0];
    // Cut between characters: 512 "é" of two bytes each.
    try testing.expectEqual(@as(usize, rows_mod.line_bytes_max), row.title.len);
    try testing.expectEqual(@as(usize, rows_mod.detail_bytes_max), row.detail.len);
    try testing.expectEqual(@as(usize, rows_mod.line_bytes_max), row.meta[0].value.len);

    _ = host.list(registry.generation, .from(2), "");
    const ran = try probe.take("list");
    defer ran.destroy(testing.allocator);
    try testing.expect(ran.error_message == null);
    try testing.expectEqualStrings("true", ran.items[0].title);
}
