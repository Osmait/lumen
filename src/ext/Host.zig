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

/// Limits for each extension's Lua state: the memory it may hold, and how
/// long a load, a list or an action may run before the instruction hook
/// stops it.
const memory_bytes_max = 64 << 20;
const load_budget_ns = 5 * std.time.ns_per_s;
const list_budget_ns = 10 * std.time.ns_per_s;
const act_budget_ns = 30 * std.time.ns_per_s;
/// For anything Lua still runs as a state closes (lumen.exec waits no
/// longer than this).
const close_budget_ns = 1 * std.time.ns_per_s;

/// The most rows one list answer takes.
pub const items_max = 1000;
/// The most actions one row takes.
pub const actions_max = 9;
/// The most rows one command adds to the root search, so that a single
/// extension cannot push the others' rows out.
pub const root_search_items_max = 8;
const root_search_budget_ns = 3 * std.time.ns_per_s;
/// The most of a query a search command or a root search gets.
const query_bytes_max = 1024;

/// A row's one-line texts (title, subtitle, accessory, section, id): longer
/// is unreadable in a row, and a label of megabytes takes seconds to lay out.
const line_bytes_max = 1024;
const keywords_bytes_max = 4096;
const path_bytes_max = 4096;
/// A row's `detail` or `markdown`.
const detail_bytes_max = 128 << 10;
/// What one answer's rows take in all. They are copied out of the state, so
/// its memory cap does not hold them: one string that 1000 rows refer to
/// becomes 1000 copies.
const rows_bytes_max = 16 << 20;
const rows_too_big = std.fmt.comptimePrint(
    "the rows take more than {d} MB",
    .{rows_bytes_max >> 20},
);
/// Label and value pairs of a row's `metadata`.
const meta_max = item_mod.meta_max;
/// Fields of one form.
const form_fields_max = 20;
/// An extension's folder name, a command's or a field's name.
const id_bytes_max = 40;
/// A grid command's cells to a line.
const grid_columns_min = 2;
const grid_columns_max = 10;
/// A short text that starts with a byte past ASCII is an emoji icon; any
/// other text names an icon.
const emoji_bytes_max = 32;

comptime {
    assert(root_search_items_max <= items_max);
    // `Entry.index` holds an action's index.
    assert(actions_max <= std.math.maxInt(@FieldType(item_mod.Entry, "index")));
    // Each of the first two actions has its keys (`keysFor`).
    assert(actions_max >= 2);
    assert(grid_columns_min <= grid_columns_max);
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
request_gen_last: u32 = 0,
/// Under `lock`.
pending: Pending = .{},
/// The style to load before init.lua; empty is none. Under `lock`.
style: core.FixedStr(64) = .{},

// Worker thread only.
extensions: std.ArrayList(*Ext) = .empty,
/// Where the worker finds each command of the current registry, in the
/// registry's order.
worker_commands: []WorkerCommand = &.{},
registry_gen: u32 = 0,
/// Extension ids and folders; reset on reload.
worker_arena: std.heap.ArenaAllocator,

// ------------------------------------------------------------- results

pub const Mode = enum {
    /// `items`: listed once when the command opens, filtered by Lumen.
    list,
    /// `search`: asked again for every query.
    search,
    /// `run`: no list; Enter runs it.
    run,
    /// Only `root`: rows in the root search, not a command of its own.
    provider,
    /// `fields` and `submit`: a form.
    form,
};

pub const Command = struct {
    /// "<extension>.<name>"; what keymaps and `lumen --command` name.
    id: [:0]const u8,
    title: [:0]const u8,
    subtitle: [:0]const u8,
    icon: item_mod.Icon,
    keywords: []const u8,
    placeholder: [:0]const u8,
    mode: Mode,
    /// Show the detail pane (the selected row's `detail`).
    detail: bool,
    /// It answers root searches too (`root = function(query)`).
    root: bool,
    /// A form's fields, in order (preferences' types).
    fields: []const Pref = &.{},
    /// The form's last row ("Submit").
    submit_title: [:0]const u8 = "Submit",
    /// Rows as a grid of cells (`grid = true`), this many to a line.
    grid: bool = false,
    columns: u8 = 5,
};

pub const Keymap = struct {
    /// As written: "ctrl+g", "alt+shift+p".
    keys: [:0]const u8,
    /// Parsed: the key (lower case) and the modifiers.
    keyval: c_uint,
    mods: c_uint,
    /// A command id, or a built-in view name ("clipboard").
    target: [:0]const u8,
    /// Where it was defined, for error messages.
    ext: [:0]const u8,
};

pub const PrefKind = enum { toggle, choice, text, password };

/// A preference an extension declares; Settings edits it, Lua reads it as
/// `lumen.preferences.<name>`.
pub const Pref = struct {
    /// The extension's id and title.
    ext: [:0]const u8,
    ext_title: [:0]const u8,
    /// Where Settings writes the values: <data>/preferences.json.
    file: [:0]const u8,
    name: [:0]const u8,
    title: [:0]const u8,
    description: [:0]const u8,
    kind: PrefKind,
    /// As JSON would spell it for a toggle ("true"), else the text.
    default: [:0]const u8,
    choices: []const PrefChoice = &.{},
    /// Form fields: submitting needs a value.
    required: bool = false,
};

pub const PrefChoice = struct { value: [:0]const u8, label: [:0]const u8 };

/// `lumen.icons { ["cmd:clipboard"] = "📋" }`: an item's icon replaced.
pub const IconOverride = struct { key: [:0]const u8, icon: item_mod.Icon };

/// `lumen.set { width = "wide" }`: a setting init.lua fixes.
pub const SettingOverride = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

/// An extension that loaded, for Settings > Extensions.
pub const ExtInfo = struct { id: [:0]const u8, title: [:0]const u8, commands: u16 };

/// A file that did not load, or loaded only in part, and why.
pub const Problem = struct {
    ext: [:0]const u8,
    message: [:0]const u8,
};

/// Everything the files define. Owned by the receiver: `destroy`.
pub const Registry = struct {
    gen: u32,
    commands: []const Command = &.{},
    themes: []const themes.Theme = &.{},
    keymaps: []const Keymap = &.{},
    settings: []const SettingOverride = &.{},
    prefs: []const Pref = &.{},
    icons: []const IconOverride = &.{},
    /// The extensions that loaded (init.lua not included).
    extensions: []const ExtInfo = &.{},
    /// lumen.set in the style: defaults the UI applies when the style is
    /// chosen (unlike init.lua's, they fix nothing).
    style_settings: []const SettingOverride = &.{},
    /// `lumen.layout { ... }`: the window's structure.
    layout: layout_mod.Layout = .{},
    /// Whether any file called lumen.layout (its size and place then win
    /// over Settings).
    has_layout: bool = false,
    problems: []const Problem = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn destroy(registry: *Registry, gpa: std.mem.Allocator) void {
        registry.arena.deinit();
        gpa.destroy(registry);
    }
};

/// A command's rows. Owned by the receiver: `destroy`.
pub const ListResult = struct {
    gen: u32,
    command: u16,
    query: []const u8,
    items: []Item = &.{},
    err: ?[:0]const u8 = null,
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
    gen: u32,
    outcome: Outcome = .close,
    err: ?[:0]const u8 = null,
    arena: std.heap.ArenaAllocator,

    pub fn destroy(result: *ActResult, gpa: std.mem.Allocator) void {
        result.arena.deinit();
        gpa.destroy(result);
    }
};

/// Rows extensions give for a root search, a section per command.
/// Owned by the receiver: `destroy`.
pub const RootResult = struct {
    gen: u32,
    query: []const u8,
    sections: []const RootSection = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn destroy(result: *RootResult, gpa: std.mem.Allocator) void {
        result.arena.deinit();
        gpa.destroy(result);
    }
};

pub const RootSection = struct { command: u16, items: []Item };

/// Called on the GTK main loop; each takes ownership of its result.
pub const Callbacks = struct {
    ctx: ?*anyopaque,
    registry: *const fn (*Registry, ?*anyopaque) void,
    list: *const fn (*ListResult, ?*anyopaque) void,
    act: *const fn (*ActResult, ?*anyopaque) void,
    root: *const fn (*RootResult, ?*anyopaque) void,
};

/// A form's values, as the UI hands them over.
pub const FormValue = struct { name: []const u8, value: []const u8, toggle: bool };

// ------------------------------------------------- the worker's own types

/// One loaded file and its Lua state. Worker thread only.
pub const Ext = struct {
    budget: lua.Budget = .{ .bytes_max = memory_bytes_max },
    L: *lua.State = undefined,
    host: *Host,
    id: [:0]const u8,
    dir: [:0]const u8,
    /// Its storage and preferences: $XDG_DATA_HOME/lumen/extensions/<id>.
    data: [:0]const u8,
    /// Set only while this extension's file runs: `lumen.theme`,
    /// `lumen.keymap`, `lumen.set`, `lumen.layout` and `lumen.icons` add
    /// to it. Null at any other time, which those functions report as an
    /// error.
    load: ?*Load = null,

    pub fn gpa(extension: *Ext) std.mem.Allocator {
        return extension.host.gpa;
    }

    pub fn io(extension: *Ext) std.Io {
        return extension.host.io;
    }

    /// Runs `handler` in this state, protected, with `budget_ns` to finish
    /// (the instruction hook stops it past that). Its error, or null.
    fn run(
        extension: *Ext,
        arena: std.mem.Allocator,
        budget_ns: u64,
        comptime Context: type,
        context: *Context,
        comptime handler: fn (*lua.State, *Context) void,
    ) ?[:0]const u8 {
        extension.budget.deadline_ns = os.monotonicNs() + budget_ns;
        defer extension.budget.deadline_ns = std.math.maxInt(u64);
        return lua.protect(extension.L, arena, Context, context, handler);
    }

    /// Closes its state. Closing runs the finalizers left, with the
    /// instruction hook off (Lua turns hooks off in `__gc`); extensions
    /// cannot set any (lua.openLibs), and lumen.exec gets a deadline anyway.
    fn close(extension: *Ext) void {
        extension.budget.deadline_ns = os.monotonicNs() + close_budget_ns;
        lua.c.lua_close(extension.L);
    }
};

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
    prefs: std.ArrayList(Pref) = .empty,
    icons: std.ArrayList(IconOverride) = .empty,
    extensions: std.ArrayList(ExtInfo) = .empty,
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
        "prefs",
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
    spec_ref: c_int,
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
    ref: c_int = c_noref,
    /// The request that produced it.
    list_gen: u32 = 0,
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
    registry_gen: u32,
    command: u16,
    request_gen: u32,
    query: core.FixedStr(query_bytes_max),
};

const RootSearchRequest = struct {
    registry_gen: u32,
    request_gen: u32,
    query: core.FixedStr(query_bytes_max),
};

const ActRequest = struct {
    registry_gen: u32,
    command: u16,
    request_gen: u32,
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
        list_gen: u32,
        row_index: u32,
        action_index: u8,
    };
};

/// A form submitted; owns copies of its values.
const SubmitRequest = struct {
    registry_gen: u32,
    command: u16,
    request_gen: u32,
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
pub fn list(host: *Host, registry_gen: u32, command: u16, query: []const u8) u32 {
    const request_gen = host.requestGenNext();
    var request: ListRequest = .{
        .registry_gen = registry_gen,
        .command = command,
        .request_gen = request_gen,
        .query = .{},
    };
    request.query.set(query);
    {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        host.pending.list = request;
    }
    host.wake();
    return request_gen;
}

/// Calls form `command`'s submit with `values` (copied). Its answer comes
/// like an action's.
pub fn submit(host: *Host, registry_gen: u32, command: u16, values: []const FormValue) u32 {
    const request_gen = host.requestGenNext();
    const request = submitRequestCreate(
        host.gpa,
        registry_gen,
        command,
        request_gen,
        values,
    ) catch {
        log.warn("submit: out of memory, not sent", .{});
        return request_gen;
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
    return request_gen;
}

/// A submit request owning copies of `values`. All of them or none: half
/// copied values would reach the extension as if the user had left fields
/// empty.
fn submitRequestCreate(
    gpa: std.mem.Allocator,
    registry_gen: u32,
    command: u16,
    request_gen: u32,
    values: []const FormValue,
) error{OutOfMemory}!*SubmitRequest {
    const request = try gpa.create(SubmitRequest);
    request.* = .{
        .registry_gen = registry_gen,
        .command = command,
        .request_gen = request_gen,
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
pub fn root(host: *Host, registry_gen: u32, query: []const u8) u32 {
    const request_gen = host.requestGenNext();
    var request: RootSearchRequest = .{
        .registry_gen = registry_gen,
        .request_gen = request_gen,
        .query = .{},
    };
    request.query.set(query);
    {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        host.pending.root_search = request;
    }
    host.wake();
    return request_gen;
}

/// What `act` runs: a command's own `run`, or one action of a row the
/// command listed (in its list or in the root search).
pub const ActTarget = ActRequest.Target;

/// Runs a Lua action of `command`; see `ActTarget`.
pub fn act(host: *Host, registry_gen: u32, command: u16, target: ActTarget) u32 {
    const request_gen = host.requestGenNext();
    {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        host.pending.act = .{
            .registry_gen = registry_gen,
            .command = command,
            .request_gen = request_gen,
            .target = target,
        };
    }
    host.wake();
    return request_gen;
}

/// The window keeps 0 for "no request pending" (`ext_act_gen`), so 0 is
/// never handed out, even after the counter wraps.
fn requestGenNext(host: *Host) u32 {
    host.request_gen_last +%= 1;
    if (host.request_gen_last == 0) host.request_gen_last = 1;
    assert(host.request_gen_last != 0);
    return host.request_gen_last;
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
    for (host.extensions.items) |extension| {
        extension.close();
        host.gpa.destroy(extension);
    }
    host.extensions.clearRetainingCapacity();
    host.gpa.free(host.worker_commands);
    host.worker_commands = &.{};
    _ = host.worker_arena.reset(.retain_capacity);
}

fn reloadExecute(host: *Host) void {
    host.closeAll();
    host.registry_gen +%= 1;
    const registry = host.gpa.create(Registry) catch {
        log.warn("reload: out of memory", .{});
        return;
    };
    registry.* = .{ .gen = host.registry_gen, .arena = .init(host.gpa) };
    var load: Load = .{ .arena = registry.arena.allocator() };
    host.loadAll(&load);
    host.registryFill(registry, &load);
    for (registry.problems) |file_problem| {
        log.warn("{s}: {s}", .{ file_problem.ext, file_problem.message });
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
            problem(load, "style", "out of memory");
            break :blk "";
        };
    };
    if (style.len > 0) host.loadStyle(load, style);

    if (worker_arena.printSentinel("{s}/init.lua", .{host.config_dir}, 0)) |path| {
        if (os.info(path) != null) host.loadSource(load, "config", host.config_dir, path, null);
    } else |_| {
        problem(load, "config", "out of memory");
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
    const dir_format = "{s}/extensions/{s}";
    const dir = worker_arena.printSentinel(dir_format, .{ host.config_dir, id }, 0) catch {
        problem(load, id, "out of memory");
        return;
    };
    const path = worker_arena.printSentinel("{s}/init.lua", .{dir}, 0) catch {
        problem(load, id, "out of memory");
        return;
    };
    if (os.info(path) == null) {
        problem(load, id, "no init.lua in the extension's folder");
        return;
    }
    host.loadSource(load, id, dir, path, null);
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
    registry.prefs = load.prefs.items;
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
    return std.mem.eql(u8, id, "config") or std.mem.eql(u8, id, "style");
}

/// Reports what went wrong with a file in Settings > Extensions. Out of
/// memory, the report goes to the log instead, so it is never lost.
fn problem(load: *Load, ext: []const u8, message: []const u8) void {
    problemAppend(load, ext, message) catch {
        log.warn("{s}: {s} (not shown in Settings: out of memory)", .{ ext, message });
    };
}

fn problemAppend(load: *Load, ext: []const u8, message: []const u8) error{OutOfMemory}!void {
    const ext_copy = try load.arena.dupeSentinel(u8, ext, 0);
    const message_copy = try load.arena.dupeSentinel(u8, message, 0);
    try load.problems.append(load.arena, .{ .ext = ext_copy, .message = message_copy });
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
    const dir = worker_arena.printSentinel("{s}/styles/{s}", .{ host.config_dir, name }, 0) catch
        return;
    const path = worker_arena.printSentinel("{s}/init.lua", .{dir}, 0) catch return;
    if (os.info(path) != null) {
        host.loadSource(load, "style", dir, path, null);
    } else if (os.info(dir) != null) {
        // A style folder may hold only a style.css.
    } else if (styles.find(name)) |built_in| {
        host.loadSource(load, "style", host.config_dir, "=style", built_in.lua);
    } else {
        problem(load, "style", "no such style");
    }
}

/// Runs a file (`path`), or `source` (then `path` names it in errors).
fn loadSource(
    host: *Host,
    load: *Load,
    id: []const u8,
    dir: []const u8,
    path: [:0]const u8,
    source: ?[:0]const u8,
) void {
    const extension = host.extensionCreate(id, dir) orelse {
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
    const err = extension.run(load.arena, load_budget_ns, LoadContext, &context, LoadContext.run);
    extension.load = null;
    if (err == null) {
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
    problem(load, id, err orelse "out of memory");
    extension.close();
    host.gpa.destroy(extension);
}

/// A new state for the file of extension `id` in `dir`; null when out of
/// memory.
fn extensionCreate(host: *Host, id: []const u8, dir: []const u8) ?*Ext {
    const worker_arena = host.worker_arena.allocator();
    // Never an empty data folder: its storage would go to "/storage.json".
    const data = worker_arena.printSentinel("{s}/extensions/{s}", .{ host.data_dir, id }, 0) catch
        return null;
    const id_copy = worker_arena.dupeSentinel(u8, id, 0) catch return null;
    const dir_copy = worker_arena.dupeSentinel(u8, dir, 0) catch return null;
    const extension = host.gpa.create(Ext) catch return null;
    extension.* = .{ .host = host, .id = id_copy, .dir = dir_copy, .data = data };
    os.mkdirP(extension.data);
    extension.L = lua.newState(&extension.budget) orelse {
        host.gpa.destroy(extension);
        return null;
    };
    return extension;
}

const LoadContext = struct {
    extension: *Ext,
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
    const default_icon = fieldIcon(L, arena, spec, "extension.icon") orelse addon_icon;
    parsePreferences(L, context, spec, title);
    parseCommands(L, context, spec, title, default_icon);
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
        context.load.prefs.append(context.load.arena, preference) catch lua.oom(L);
    }
}

fn preferenceDeclared(load: *const Load, extension_id: []const u8, name: []const u8) bool {
    for (load.prefs.items) |preference| {
        if (!std.mem.eql(u8, preference.ext, extension_id)) continue;
        if (std.mem.eql(u8, preference.name, name)) return true;
    }
    return false;
}

fn parseCommands(
    L: *lua.State,
    context: *LoadContext,
    spec: c_int,
    extension_title: [:0]const u8,
    default_icon: item_mod.Icon,
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
        parseCommand(L, context, command_table, where, extension_title, default_icon);
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
) []const PrefChoice {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const choice_list = lua.fieldList(L, field_table, "choices", where) orelse
        lua.raise(L, "{s}.choices: a list expected for a choice", .{where});
    const choices_count = lua.c.lua_rawlen(L, choice_list);
    if (choices_count == 0) lua.raise(L, "{s}.choices is empty", .{where});
    const choices = arena.alloc(PrefChoice, choices_count) catch lua.oom(L);
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
) Pref {
    const arena = context.load.arena;
    const name = fieldName(L, arena, field_table, where);
    const kind_name = lua.fieldString(L, arena, field_table, "type", where) orelse "text";
    const kind = std.meta.stringToEnum(PrefKind, kind_name) orelse lua.raise(
        L,
        "{s}.type: toggle, choice, text or password (got \"{s}\")",
        .{ where, kind_name },
    );
    const file = arena.printSentinel("{s}/preferences.json", .{context.extension.data}, 0) catch
        lua.oom(L);
    var preference: Pref = .{
        .ext = context.extension.id,
        .ext_title = extension_title,
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
        .toggle => if (lua.fieldBool(L, field_table, "default", false, where)) "true" else "false",
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
) []const Pref {
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
    const fields = context.load.arena.alloc(Pref, fields_count) catch lua.oom(L);
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
    default_icon: item_mod.Icon,
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
    }) orelse 5;

    const command: Command = .{
        .id = id,
        .title = title,
        .subtitle = lua.fieldString(L, arena, command_table, "subtitle", where) orelse
            extension_title,
        .icon = fieldIcon(L, arena, command_table, where) orelse default_icon,
        .keywords = keywords(L, arena, command_table, where),
        .placeholder = lua.fieldString(L, arena, command_table, "placeholder", where) orelse "",
        .mode = mode,
        .detail = lua.fieldBool(L, command_table, "detail", false, where),
        .root = answers_root_search,
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
    const spec_ref = lua.ref(L);
    context.load.worker_commands.append(arena, .{
        .extension_index = context.extension_index,
        .spec_ref = spec_ref,
        .mode = mode,
        .answers_root_search = answers_root_search,
    }) catch lua.oom(L);
    context.load.commands.append(arena, command) catch lua.oom(L);
    assert(context.load.worker_commands.items.len == context.load.commands.items.len);
}

/// `keywords`: a string, or a list of strings joined with spaces; up to
/// `keywords_bytes_max`.
fn keywords(L: *lua.State, arena: std.mem.Allocator, table: c_int, where: []const u8) []const u8 {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    switch (lua.getField(L, table, "keywords")) {
        lua.c.LUA_TNIL => return "",
        lua.c.LUA_TSTRING => {
            const text = lua.cut(lua.toSlice(L, -1).?, keywords_bytes_max);
            return arena.dupe(u8, text) catch lua.oom(L);
        },
        lua.c.LUA_TTABLE => return keywordsJoined(L, arena, lua.absIndex(L, -1), where),
        else => {
            const type_name = lua.typeName(L, -1);
            lua.raise(L, "{s}.keywords: string or list expected, got {s}", .{ where, type_name });
        },
    }
}

/// The strings of the list at `keyword_list`, joined with spaces, as many
/// as fit in `keywords_bytes_max`.
fn keywordsJoined(
    L: *lua.State,
    arena: std.mem.Allocator,
    keyword_list: c_int,
    where: []const u8,
) []const u8 {
    var joined: std.ArrayList(u8) = .empty;
    const keywords_count = lua.c.lua_rawlen(L, keyword_list);
    for (1..keywords_count + 1) |keyword_number| {
        const mark: lua.StackMark = .init(L);
        defer mark.restore(L);
        _ = lua.c.lua_rawgeti(L, keyword_list, @intCast(keyword_number));
        const keyword = lua.toSlice(L, -1) orelse
            lua.raise(L, "{s}.keywords[{d}]: string expected", .{ where, keyword_number });
        if (joined.items.len + 1 + keyword.len > keywords_bytes_max) break;
        if (joined.items.len > 0) joined.append(arena, ' ') catch lua.oom(L);
        joined.appendSlice(arena, keyword) catch lua.oom(L);
    }
    assert(joined.items.len <= keywords_bytes_max);
    return joined.items;
}

/// `table.icon` (see `parseIcon`), or null when it has none.
fn fieldIcon(
    L: *lua.State,
    arena: std.mem.Allocator,
    table: c_int,
    where: []const u8,
) ?item_mod.Icon {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    _ = lua.getField(L, table, "icon");
    return parseIcon(L, arena, -1, where);
}

/// An icon: an emoji ("🐙"), an icon name ("folder-symbolic") on a grey
/// tile, or `{ name = ..., color = "blue" }`. Null for nil. Leaves the
/// stack as it found it.
pub fn parseIcon(
    L: *lua.State,
    arena: std.mem.Allocator,
    index: c_int,
    where: []const u8,
) ?item_mod.Icon {
    const mark: lua.StackMark = .init(L);
    defer mark.expectPushed(L, 0);
    const icon = lua.absIndex(L, index);
    switch (lua.c.lua_type(L, icon)) {
        lua.c.LUA_TNIL => return null,
        lua.c.LUA_TSTRING => {
            const text = lua.toSlice(L, icon).?;
            // "~/icons/x.svg": a file in the home folder.
            const in_home = std.mem.startsWith(u8, text, "~/");
            const copy = if (in_home)
                arena.printSentinel("{s}/{s}", .{ std.mem.span(c.g_get_home_dir()), text[2..] }, 0)
            else
                arena.dupeSentinel(u8, text, 0);
            const name = copy catch lua.oom(L);
            const is_emoji = text.len > 0 and text.len <= emoji_bytes_max and text[0] >= 0x80;
            if (is_emoji) return .{ .emoji = name };
            return .byName(name);
        },
        lua.c.LUA_TTABLE => {
            const name = lua.fieldString(L, arena, icon, "name", where) orelse
                lua.raise(L, "{s}.icon.name is missing", .{where});
            const color_name = lua.fieldString(L, arena, icon, "color", where) orelse "gray";
            const color = std.meta.stringToEnum(item_mod.Color, color_name) orelse lua.raise(
                L,
                "{s}.icon.color: one of red, orange, yellow, green, blue, purple, pink, gray (got \"{s}\")",
                .{ where, color_name },
            );
            return .{ .tile = .{ .name = name, .color = color } };
        },
        else => {
            const type_name = lua.typeName(L, icon);
            lua.raise(L, "{s}.icon: string or table expected, got {s}", .{ where, type_name });
        },
    }
}

// ----------------------------------------------------------------- list

/// The error a request gets when the files were reloaded after it was made.
const reloaded = "Extensions were reloaded";

/// The command a request names; null when the files were reloaded after
/// the request was made (its command index is from a registry that is
/// gone, and may name another command now).
fn requested(host: *Host, registry_gen: u32, command: u16) ?*WorkerCommand {
    if (registry_gen != host.registry_gen) return null;
    // The registry the UI holds has as many commands as there are worker
    // commands; anything past them is not a command of this registry.
    if (command >= host.worker_commands.len) return null;
    const worker_command = &host.worker_commands[command];
    assert(worker_command.extension_index < host.extensions.items.len);
    return worker_command;
}

fn listExecute(host: *Host, request: *const ListRequest) void {
    const result = host.gpa.create(ListResult) catch {
        log.warn("list: out of memory, no answer", .{});
        return;
    };
    result.* = .{
        .gen = request.request_gen,
        .command = request.command,
        .query = "",
        .arena = .init(host.gpa),
    };
    defer host.deliver(.{ .list = result });
    const arena = result.arena.allocator();
    const query = request.query.slice();
    result.query = arena.dupe(u8, query) catch {
        // An answer for "" would pass for the answer to an empty query.
        result.err = "out of memory";
        return;
    };
    const worker_command = host.requested(request.registry_gen, request.command) orelse {
        result.err = reloaded;
        return;
    };
    const extension = host.extensions.items[worker_command.extension_index];
    var rows: lua.Capped = .{ .child = arena, .bytes_max = rows_bytes_max };
    var context: ListContext = .{
        .extension = extension,
        .worker_command = worker_command,
        .request = request,
        .result = result,
        .rows_arena = rows.allocator(),
    };
    result.err = extension.run(arena, list_budget_ns, ListContext, &context, ListContext.run);
    if (result.err != null and rows.refused) result.err = rows_too_big;
}

const ListContext = struct {
    extension: *Ext,
    worker_command: *WorkerCommand,
    request: *const ListRequest,
    result: *ListResult,
    /// The result's arena, up to `rows_bytes_max`.
    rows_arena: std.mem.Allocator,

    fn run(L: *lua.State, context: *ListContext) void {
        _ = lua.pushRef(L, context.worker_command.spec_ref);
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
        keep(L, &context.worker_command.list_kept, rows, context.request.request_gen);
        context.result.items = parseItems(L, context.rows_arena, rows, .{
            .list_gen = context.request.request_gen,
            .command = context.request.command,
            .extension_id = context.extension.id,
        }, items_max);
    }
};

/// Keeps the list at `rows` for its rows' actions, until the next one.
fn keep(L: *lua.State, kept: *Kept, rows: c_int, list_gen: u32) void {
    if (kept.ref != c_noref) {
        lua.unref(L, kept.ref);
        kept.ref = c_noref;
    }
    lua.c.lua_pushvalue(L, rows);
    kept.ref = lua.ref(L);
    kept.list_gen = list_gen;
}

/// Where a list's rows came from: enough to run their actions later, and to
/// key them.
const RowsOrigin = struct {
    /// The request that listed them (`ExtItem.gen`).
    list_gen: u32,
    command: u16,
    from_root_search: bool = false,
    extension_id: []const u8,
};

/// One row of a list: where its list came from, its place in it, and how
/// errors name it.
const RowSource = struct {
    origin: RowsOrigin,
    /// Its position in the list, from 0.
    row_index: u32,
    /// "items[3]".
    where: []const u8,
};

fn parseItems(
    L: *lua.State,
    arena: std.mem.Allocator,
    rows: c_int,
    origin: RowsOrigin,
    rows_max: usize,
) []Item {
    assert(rows_max <= items_max);
    const rows_count = @min(lua.c.lua_rawlen(L, rows), rows_max);
    const items = arena.alloc(Item, rows_count) catch lua.oom(L);
    for (items, 0..) |*item, row_index| {
        const mark: lua.StackMark = .init(L);
        defer mark.restore(L);
        var where_buffer: [24]u8 = undefined;
        const where = std.mem.print(&where_buffer, "items[{d}]", .{row_index + 1}) catch "items";
        _ = lua.c.lua_rawgeti(L, rows, @intCast(row_index + 1));
        item.* = parseItem(L, arena, lua.absIndex(L, -1), .{
            .origin = origin,
            .row_index = @intCast(row_index),
            .where = where,
        });
    }
    assert(items.len <= rows_max);
    return items;
}

fn parseItem(L: *lua.State, arena: std.mem.Allocator, row: c_int, source: RowSource) Item {
    const where = source.where;
    // A plain string is a row with that title.
    if (lua.toSlice(L, row)) |text| {
        const title = arena.dupeSentinel(u8, lua.cut(text, line_bytes_max), 0) catch lua.oom(L);
        return .{
            .key = rankingKey(L, arena, source.origin.extension_id, title),
            .title = title,
            .action = .{ .ext_item = defaultActions(L, arena, source, title) },
        };
    }
    if (lua.c.lua_type(L, row) != lua.c.LUA_TTABLE) {
        const type_name = lua.typeName(L, row);
        lua.raise(L, "{s}: table or string expected, got {s}", .{ where, type_name });
    }
    const title = line(L, arena, row, "title", where) orelse
        lua.raise(L, "{s}.title is missing", .{where});
    const id = line(L, arena, row, "id", where) orelse title;
    var item: Item = .{
        .key = rankingKey(L, arena, source.origin.extension_id, id),
        .title = title,
        .subtitle = line(L, arena, row, "subtitle", where) orelse "",
        .accessory = line(L, arena, row, "accessory", where) orelse "",
        .keywords = keywords(L, arena, row, where),
        .detail = lua.fieldStringMax(L, arena, row, "detail", where, detail_bytes_max) orelse "",
        .section = line(L, arena, row, "section", where) orelse "",
        .confirm = lua.fieldBool(L, row, "confirm", false, where),
        .action = undefined,
    };
    if (fieldIcon(L, arena, row, where)) |icon| item.icon = icon;
    if (lua.fieldStringMax(L, arena, row, "markdown", where, detail_bytes_max)) |markdown| {
        var markup: std.Io.Writer.Allocating = .init(arena);
        core.markdown.toMarkup(&markup.writer, markdown) catch lua.oom(L);
        item.detail = markup.written();
        item.markup = true;
    }
    item.meta = metadata(L, arena, row, where);
    item.image = lua.fieldStringMax(L, arena, row, "image", where, path_bytes_max) orelse "";
    item.action = .{ .ext_item = rowActions(L, arena, row, source, title) };
    return item;
}

/// A row's one-line text `row[name]`, cut to `line_bytes_max`.
fn line(
    L: *lua.State,
    arena: std.mem.Allocator,
    row: c_int,
    name: [:0]const u8,
    where: []const u8,
) ?[:0]const u8 {
    return lua.fieldStringMax(L, arena, row, name, where, line_bytes_max);
}

/// A row's `actions` (up to `actions_max`, Lua functions or lumen.action
/// values), or the default ones when it has none.
fn rowActions(
    L: *lua.State,
    arena: std.mem.Allocator,
    row: c_int,
    source: RowSource,
    title: [:0]const u8,
) item_mod.ExtItem {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const action_list = lua.fieldList(L, row, "actions", source.where) orelse
        return defaultActions(L, arena, source, title);
    const actions_count = @min(lua.c.lua_rawlen(L, action_list), actions_max);
    if (actions_count == 0) lua.raise(L, "{s}.actions is empty", .{source.where});
    const actions = arena.alloc(item_mod.ExtAction, actions_count) catch lua.oom(L);
    const entries = arena.alloc(item_mod.Entry, actions_count) catch lua.oom(L);
    for (actions, entries, 0..) |*action, *entry, action_index| {
        const action_mark: lua.StackMark = .init(L);
        defer action_mark.restore(L);
        var where_buffer: [48]u8 = undefined;
        const action_where = std.mem.print(
            &where_buffer,
            "{s}.actions[{d}]",
            .{ source.where, action_index + 1 },
        ) catch source.where;
        const action_table = lua.tableAt(L, action_list, action_index + 1, action_where);
        const parsed = parseAction(L, arena, action_table, action_where);
        action.* = parsed.action;
        entry.* = .{
            .label = parsed.label,
            .keys = keysFor(action_index),
            .op = .ext,
            .index = @intCast(action_index),
        };
    }
    return extItem(source, actions, entries);
}

/// A row without actions copies its title.
fn defaultActions(
    L: *lua.State,
    arena: std.mem.Allocator,
    source: RowSource,
    title: [:0]const u8,
) item_mod.ExtItem {
    const actions = arena.dupe(item_mod.ExtAction, &.{.{ .copy = title }}) catch lua.oom(L);
    const entries = arena.dupe(item_mod.Entry, &.{.{
        .label = "Copy to Clipboard",
        .keys = "↵",
        .op = .ext,
    }}) catch lua.oom(L);
    return extItem(source, actions, entries);
}

fn extItem(
    source: RowSource,
    actions: []const item_mod.ExtAction,
    entries: []const item_mod.Entry,
) item_mod.ExtItem {
    assert(actions.len == entries.len);
    assert(actions.len >= 1);
    assert(actions.len <= actions_max);
    return .{
        .command = source.origin.command,
        .root = source.origin.from_root_search,
        .gen = source.origin.list_gen,
        .index = source.row_index,
        .actions = actions,
        .entries = entries,
    };
}

/// `metadata = { { "Label", "value" }, { label = "Size", value = 42 } }`:
/// up to `meta_max` pairs for the detail pane.
fn metadata(
    L: *lua.State,
    arena: std.mem.Allocator,
    row: c_int,
    where: []const u8,
) []const item_mod.Meta {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const pairs = lua.fieldList(L, row, "metadata", where) orelse return &.{};
    const pairs_count = @min(lua.c.lua_rawlen(L, pairs), meta_max);
    const metas = arena.alloc(item_mod.Meta, pairs_count) catch lua.oom(L);
    for (metas, 1..) |*meta, pair_number| {
        const pair_mark: lua.StackMark = .init(L);
        defer pair_mark.restore(L);
        var where_buffer: [48]u8 = undefined;
        const pair_where = std.mem.print(
            &where_buffer,
            "{s}.metadata[{d}]",
            .{ where, pair_number },
        ) catch where;
        const pair = lua.tableAt(L, pairs, pair_number, pair_where);
        meta.* = .{
            .label = line(L, arena, pair, "label", pair_where) orelse
                pairPart(L, arena, pair, 1, pair_where),
            .value = line(L, arena, pair, "value", pair_where) orelse
                pairPart(L, arena, pair, 2, pair_where),
        };
    }
    assert(metas.len <= meta_max);
    return metas;
}

/// `pair[part_number]` as text (numbers too), cut to `line_bytes_max`.
fn pairPart(
    L: *lua.State,
    arena: std.mem.Allocator,
    pair: c_int,
    part_number: c_int,
    where: []const u8,
) [:0]const u8 {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    switch (lua.c.lua_rawgeti(L, pair, part_number)) {
        lua.c.LUA_TSTRING, lua.c.LUA_TNUMBER => {
            var len: usize = 0;
            const bytes = lua.c.lua_tolstring(L, -1, &len);
            const text = lua.cut(bytes[0..len], line_bytes_max);
            return arena.dupeSentinel(u8, text, 0) catch lua.oom(L);
        },
        else => lua.raise(L, "{s}: {{ label, value }} expected", .{where}),
    }
}

/// The key a row's use is ranked by. Raises when out of memory: an empty
/// key would merge rows' rankings.
fn rankingKey(
    L: *lua.State,
    arena: std.mem.Allocator,
    extension_id: []const u8,
    id: []const u8,
) []const u8 {
    return arena.print("x:{s}:{s}", .{ extension_id, id }) catch lua.oom(L);
}

/// The key caps shown for a row's first two actions; the rest have none.
fn keysFor(action_index: usize) [:0]const u8 {
    return switch (action_index) {
        0 => "↵",
        1 => "Ctrl ↵",
        else => "",
    };
}

const ParsedAction = struct { action: item_mod.ExtAction, label: [:0]const u8 };

/// What `lumen.action.*` makes: `kind` says which.
const ActionKind = enum { open, copy, paste, exec };

fn parseAction(
    L: *lua.State,
    arena: std.mem.Allocator,
    action_table: c_int,
    where: []const u8,
) ParsedAction {
    const title = lua.fieldString(L, arena, action_table, "title", where);
    if (actionHasRun(L, action_table, where)) {
        return .{ .action = .lua, .label = title orelse "Run" };
    }
    const kind_name = lua.fieldString(L, arena, action_table, "kind", where) orelse
        lua.raise(L, "{s}: give it a run function, or make it with lumen.action.*", .{where});
    const kind = std.meta.stringToEnum(ActionKind, kind_name) orelse
        lua.raise(L, "{s}.kind: unknown \"{s}\"", .{ where, kind_name });
    switch (kind) {
        .open => {
            const target = lua.fieldString(L, arena, action_table, "target", where) orelse
                lua.raise(L, "{s}.target is missing", .{where});
            return .{ .action = .{ .open = target }, .label = title orelse "Open" };
        },
        .copy => {
            const text = actionText(L, arena, action_table, where);
            return .{ .action = .{ .copy = text }, .label = title orelse "Copy to Clipboard" };
        },
        .paste => {
            const text = actionText(L, arena, action_table, where);
            return .{ .action = .{ .paste = text }, .label = title orelse "Paste to Active App" };
        },
        .exec => {
            const argv = actionArgv(L, arena, action_table, where);
            return .{ .action = .{ .exec = argv }, .label = title orelse "Run" };
        },
    }
}

/// Whether the action is a Lua function (`run`).
fn actionHasRun(L: *lua.State, action_table: c_int, where: []const u8) bool {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const run_type = lua.getField(L, action_table, "run");
    if (run_type == lua.c.LUA_TFUNCTION) return true;
    if (run_type != lua.c.LUA_TNIL) {
        lua.raise(L, "{s}.run: function expected, got {s}", .{ where, lua.typeName(L, -1) });
    }
    return false;
}

fn actionText(
    L: *lua.State,
    arena: std.mem.Allocator,
    action_table: c_int,
    where: []const u8,
) [:0]const u8 {
    return lua.fieldString(L, arena, action_table, "text", where) orelse
        lua.raise(L, "{s}.text is missing", .{where});
}

/// `lumen.action.exec`'s argv: 1 to `api.argv_max` strings.
fn actionArgv(
    L: *lua.State,
    arena: std.mem.Allocator,
    action_table: c_int,
    where: []const u8,
) []const [:0]const u8 {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    if (lua.getField(L, action_table, "argv") != lua.c.LUA_TTABLE) {
        lua.raise(L, "{s}.argv: a list of strings expected", .{where});
    }
    const words = lua.absIndex(L, -1);
    const words_count = lua.c.lua_rawlen(L, words);
    if (words_count == 0 or words_count > api.argv_max) {
        lua.raise(L, "{s}.argv: 1 to {d} strings expected", .{ where, api.argv_max });
    }
    const argv = arena.alloc([:0]const u8, words_count) catch lua.oom(L);
    for (argv, 1..) |*word, word_number| {
        const word_mark: lua.StackMark = .init(L);
        defer word_mark.restore(L);
        _ = lua.c.lua_rawgeti(L, words, @intCast(word_number));
        const text = lua.toSlice(L, -1) orelse
            lua.raise(L, "{s}.argv[{d}]: string expected", .{ where, word_number });
        word.* = arena.dupeSentinel(u8, text, 0) catch lua.oom(L);
    }
    return argv;
}

// ----------------------------------------------------------------- root

fn rootSearchExecute(host: *Host, request: *const RootSearchRequest) void {
    const result = host.gpa.create(RootResult) catch {
        log.warn("root: out of memory, no answer", .{});
        return;
    };
    result.* = .{ .gen = request.request_gen, .query = "", .arena = .init(host.gpa) };
    defer host.deliver(.{ .root = result });
    const arena = result.arena.allocator();
    const query = request.query.slice();
    // Out of memory, no rows: an answer for "" would show no rows anyway.
    result.query = arena.dupe(u8, query) catch return;
    if (request.registry_gen != host.registry_gen) return;
    var sections: std.ArrayList(RootSection) = .empty;
    // Every provider's rows together.
    var rows: lua.Capped = .{ .child = arena, .bytes_max = rows_bytes_max };
    for (host.worker_commands, 0..) |*worker_command, command_index| {
        if (!worker_command.answers_root_search) continue;
        // A newer query came in: this one is already stale.
        if (host.rootSearchSuperseded()) break;
        const command: u16 = @intCast(command_index);
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
    command: u16,
    request: *const RootSearchRequest,
) []Item {
    const extension = host.extensions.items[worker_command.extension_index];
    var context: RootSearchContext = .{
        .extension = extension,
        .worker_command = worker_command,
        .command = command,
        .request = request,
        .rows_arena = rows.allocator(),
    };
    const err = extension.run(
        arena,
        root_search_budget_ns,
        RootSearchContext,
        &context,
        RootSearchContext.run,
    ) orelse return context.items;
    log.warn("{s}: root search: {s}", .{ extension.id, if (rows.refused) rows_too_big else err });
    rows.refused = false;
    return &.{};
}

fn rootSearchSuperseded(host: *Host) bool {
    host.lock.lockUncancelable(host.io);
    defer host.lock.unlock(host.io);
    return host.pending.root_search != null;
}

const RootSearchContext = struct {
    extension: *Ext,
    worker_command: *WorkerCommand,
    command: u16,
    request: *const RootSearchRequest,
    rows_arena: std.mem.Allocator,
    items: []Item = &.{},

    fn run(L: *lua.State, context: *RootSearchContext) void {
        _ = lua.pushRef(L, context.worker_command.spec_ref);
        _ = lua.getField(L, -1, "root");
        lua.pushString(L, context.request.query.slice());
        lua.c.lua_callk(L, 1, 1, 0, null);
        const rows = lua.absIndex(L, -1);
        switch (lua.c.lua_type(L, rows)) {
            lua.c.LUA_TNIL => return,
            lua.c.LUA_TTABLE => {},
            else => lua.raise(L, "root: a list expected, got {s}", .{lua.typeName(L, rows)}),
        }
        keep(L, &context.worker_command.root_search_kept, rows, context.request.request_gen);
        context.items = parseItems(L, context.rows_arena, rows, .{
            .list_gen = context.request.request_gen,
            .command = context.command,
            .from_root_search = true,
            .extension_id = context.extension.id,
        }, root_search_items_max);
    }
};

// --------------------------------------------------------------- submit

fn submitExecute(host: *Host, request: *SubmitRequest) void {
    defer request.destroy(host.gpa);
    const result = host.gpa.create(ActResult) catch {
        log.warn("submit: out of memory, no answer", .{});
        return;
    };
    result.* = .{ .gen = request.request_gen, .arena = .init(host.gpa) };
    defer host.deliver(.{ .act = result });
    const worker_command = host.requested(request.registry_gen, request.command) orelse {
        result.err = reloaded;
        return;
    };
    assert(request.values.len <= form_fields_max);
    const extension = host.extensions.items[worker_command.extension_index];
    var context: SubmitContext = .{
        .worker_command = worker_command,
        .request = request,
        .result = result,
    };
    const arena = result.arena.allocator();
    result.err = extension.run(arena, act_budget_ns, SubmitContext, &context, SubmitContext.run);
}

const SubmitContext = struct {
    worker_command: *WorkerCommand,
    request: *SubmitRequest,
    result: *ActResult,

    fn run(L: *lua.State, context: *SubmitContext) void {
        _ = lua.pushRef(L, context.worker_command.spec_ref);
        if (lua.getField(L, -1, "submit") != lua.c.LUA_TFUNCTION) {
            lua.raise(L, "this command has no submit function", .{});
        }
        const values = context.request.values;
        lua.c.lua_createtable(L, 0, @intCast(values.len));
        for (values) |value| {
            if (value.toggle) {
                const on = std.mem.eql(u8, value.value, "true");
                lua.c.lua_pushboolean(L, @intFromBool(on));
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
    const result = host.gpa.create(ActResult) catch {
        log.warn("action: out of memory, no answer", .{});
        return;
    };
    result.* = .{ .gen = request.request_gen, .arena = .init(host.gpa) };
    defer host.deliver(.{ .act = result });
    const worker_command = host.requested(request.registry_gen, request.command) orelse {
        result.err = reloaded;
        return;
    };
    const extension = host.extensions.items[worker_command.extension_index];
    var context: ActContext = .{
        .worker_command = worker_command,
        .request = request,
        .result = result,
    };
    const arena = result.arena.allocator();
    result.err = extension.run(arena, act_budget_ns, ActContext, &context, ActContext.run);
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
    _ = lua.pushRef(L, worker_command.spec_ref);
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
    if (kept.ref == c_noref or kept.list_gen != row_action.list_gen) {
        lua.raise(L, "the list changed meanwhile; try again", .{});
    }
    _ = lua.pushRef(L, kept.ref);
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
        .registry => |registry| callbacks.registry(registry, callbacks.ctx),
        .list => |result| callbacks.list(result, callbacks.ctx),
        .act => |result| callbacks.act(result, callbacks.ctx),
        .root => |result| callbacks.root(result, callbacks.ctx),
    }
    return 0;
}

// ----------------------------------------------------------------- stamp

/// Changes when init.lua or any .lua file in an extension's folder (not
/// subfolders) is added, removed or edited: then the files are reloaded.
/// `style`: the style in use; edits to the others' files change nothing.
pub fn stamp(config_dir: []const u8, style: []const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    var path_buffer: [4096]u8 = undefined;
    if (std.mem.printSentinel(&path_buffer, "{s}/init.lua", .{config_dir}, 0)) |path| {
        hashFile(&hasher, path);
    } else |_| {
        // A config folder that long cannot hold a file anyway.
    }
    hashFolders(&hasher, config_dir, "extensions");
    hasher.update(style);
    if (style.len > 0) {
        const style_dir = std.mem.printSentinel(
            &path_buffer,
            "{s}/styles/{s}",
            .{ config_dir, style },
            0,
        ) catch return hasher.final();
        hashLua(&hasher, style_dir);
    }
    return hasher.final();
}

/// The most entries `stamp` reads from one folder. It runs each time the
/// window opens, on the main thread: a folder of a million files (a
/// mistaken copy into extensions/) must not hold the window that long.
/// Past it, edits to the files left out do not reload anything.
const stamp_entries_max = 1024;

/// The .lua files directly in `dir`.
fn hashLua(hasher: *std.hash.Wyhash, dir: [:0]const u8) void {
    hasher.update(dir);
    const dir_handle = c.g_dir_open(dir.ptr, 0, null) orelse return;
    defer c.g_dir_close(dir_handle);
    var entries_count: usize = 0;
    while (c.g_dir_read_name(dir_handle)) |file_name_c| : (entries_count += 1) {
        if (entries_count == stamp_entries_max) break;
        const file_name = std.mem.span(file_name_c);
        if (!std.mem.endsWith(u8, file_name, ".lua")) continue;
        var path_buffer: [4096]u8 = undefined;
        const path = std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ dir, file_name }, 0) catch
            continue;
        hashFile(hasher, path);
    }
}

/// The .lua files in each folder of <config>/<kind>.
fn hashFolders(hasher: *std.hash.Wyhash, config_dir: []const u8, kind: []const u8) void {
    var top_buffer: [4096]u8 = undefined;
    const top = std.mem.printSentinel(&top_buffer, "{s}/{s}", .{ config_dir, kind }, 0) catch
        return;
    const dir_handle = c.g_dir_open(top.ptr, 0, null) orelse return;
    defer c.g_dir_close(dir_handle);
    var entries_count: usize = 0;
    while (c.g_dir_read_name(dir_handle)) |folder_name_c| : (entries_count += 1) {
        if (entries_count == stamp_entries_max) break;
        const folder_name = std.mem.span(folder_name_c);
        var folder_buffer: [4096]u8 = undefined;
        const folder = std.mem.printSentinel(
            &folder_buffer,
            "{s}/{s}",
            .{ top, folder_name },
            0,
        ) catch continue;
        hashLua(hasher, folder);
    }
}

fn hashFile(hasher: *std.hash.Wyhash, path: [:0]const u8) void {
    hasher.update(path);
    const file_stamp = os.Stamp.of(path.ptr);
    hasher.update(std.mem.asBytes(&.{ file_stamp.sec, file_stamp.size, file_stamp.ino }));
    hasher.update(std.mem.asBytes(&file_stamp.nsec));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Collects what the host delivers; the test pumps GLib's main loop.
const Probe = struct {
    reg: ?*Registry = null,
    res: ?*ListResult = null,
    act: ?*ActResult = null,
    root: ?*RootResult = null,

    fn onRegistry(r: *Registry, ctx: ?*anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        if (p.reg) |o| o.destroy(testing.allocator);
        p.reg = r;
    }
    fn onList(r: *ListResult, ctx: ?*anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        if (p.res) |o| o.destroy(testing.allocator);
        p.res = r;
    }
    fn onAct(r: *ActResult, ctx: ?*anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        if (p.act) |o| o.destroy(testing.allocator);
        p.act = r;
    }
    fn onRoot(r: *RootResult, ctx: ?*anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        if (p.root) |o| o.destroy(testing.allocator);
        p.root = r;
    }
    fn deinit(p: *Probe) void {
        if (p.root) |r| r.destroy(testing.allocator);
        if (p.reg) |r| r.destroy(testing.allocator);
        if (p.res) |r| r.destroy(testing.allocator);
        if (p.act) |r| r.destroy(testing.allocator);
    }
    /// Pumps the main loop until `field` is set (up to 10 s).
    fn wait(p: *Probe, comptime field: []const u8) !void {
        const until = os.monotonicNs() + 10 * std.time.ns_per_s;
        while (@field(p, field) == null) {
            if (os.monotonicNs() > until) return error.Timeout;
            // Nothing ready: a 1 ms nap (poll with no descriptors).
            if (c.g_main_context_iteration(null, 0) == 0) _ = std.os.linux.poll(
                &[0]std.os.linux.pollfd{},
                0,
                1,
            );
        }
    }
    fn take(p: *Probe, comptime field: []const u8) !@TypeOf(@field(p, field).?) {
        try p.wait(field);
        const r = @field(p, field).?;
        @field(p, field) = null;
        return r;
    }
};

fn writeTestFile(dir: []const u8, name: []const u8, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    if (std.mem.findScalarLast(u8, p, '/')) |s| os.mkdirP(p[0..s]);
    try os.writeFile(p, data);
}

fn testHost(probe: *Probe, dir: []const u8) !*Host {
    var buf: [4096]u8 = undefined;
    const data = try std.mem.print(&buf, "{s}/data", .{dir});
    return start(testing.allocator, testing.io, dir, data, .{
        .ctx = probe,
        .registry = &Probe.onRegistry,
        .list = &Probe.onList,
        .act = &Probe.onAct,
        .root = &Probe.onRoot,
    });
}

test "request generations skip 0, which the window keeps for none pending" {
    var host: Host = undefined;
    host.request_gen_last = std.math.maxInt(u32);
    try testing.expectEqual(1, host.requestGenNext());
    try testing.expectEqual(2, host.requestGenNext());
}

test "extensions load, list, search and run actions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp, &dbuf);
    try writeTestFile(dir, "init.lua",
        \\lumen.theme { id = "mine", name = "Mine", bg = "#101010", fg = "#f0f0f0", accent = "#ff8800" }
        \\lumen.keymap("ctrl+g", "demo.fruits")
        \\lumen.set { width = "wide", suggestions = false, opacity = 90 }
        \\lumen.layout { width = 820, panels = "single", footer = true }
        \\lumen.layout { rows = "inline", show = { icons = false } }
        \\return lumen.extension { commands = { { name = "hello", title = "Say Hello", run = function() return "stay" end } } }
    );
    try writeTestFile(dir, "extensions/demo/init.lua",
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
    try writeTestFile(dir, "extensions/demo/util.lua", "return {}");
    try writeTestFile(
        dir,
        "extensions/broken/init.lua",
        "return lumen.extension { commands = { { name = 'x' } } }",
    );

    var probe: Probe = .{};
    defer probe.deinit();
    const h = try testHost(&probe, dir);
    defer h.shutdown();
    h.reload();
    try probe.wait("reg");
    const reg = probe.reg.?;

    try testing.expectEqual(@as(usize, 5), reg.commands.len);
    try testing.expectEqual(Mode.provider, reg.commands[4].mode);
    try testing.expect(reg.commands[4].root and !reg.commands[1].root);
    try testing.expectEqualStrings("config.hello", reg.commands[0].id);
    try testing.expectEqual(Mode.run, reg.commands[0].mode);
    try testing.expectEqualStrings("demo.fruits", reg.commands[1].id);
    try testing.expectEqualStrings("Demo", reg.commands[1].subtitle);
    try testing.expectEqualStrings("🍎", reg.commands[1].icon.emoji);
    try testing.expect(reg.commands[1].detail);
    try testing.expectEqual(Mode.search, reg.commands[2].mode);
    try testing.expectEqual(@as(usize, 1), reg.themes.len);
    try testing.expectEqual(@as(u24, 0xff8800), reg.themes[0].accent);
    try testing.expectEqual(@as(u24, 0x101010), reg.themes[0].surface);
    try testing.expectEqual(@as(usize, 1), reg.keymaps.len);
    try testing.expectEqualStrings("demo.fruits", reg.keymaps[0].target);
    try testing.expectEqual(@as(usize, 3), reg.settings.len);
    // Several lumen.layout calls add up.
    try testing.expect(reg.has_layout);
    try testing.expectEqual(@as(?u16, 820), reg.layout.width);
    try testing.expect(
        reg.layout.footer and reg.layout.panels == .single and reg.layout.rows == .inline_,
    );
    try testing.expect(!reg.layout.show.icons and reg.layout.show.subtitles);
    for (reg.settings) |o| {
        const want: []const u8 = if (std.mem.eql(u8, o.key, "width")) "wide" else if (std.mem.eql(
            u8,
            o.key,
            "suggestions",
        )) "false" else "90";
        try testing.expectEqualStrings(want, o.value);
    }
    // The broken one is reported, the others load.
    try testing.expectEqual(@as(usize, 1), reg.problems.len);
    try testing.expectEqualStrings("broken", reg.problems[0].ext);
    try testing.expect(std.mem.find(u8, reg.problems[0].message, "title is missing") != null);

    // A list command's rows.
    const g1 = h.list(reg.gen, 1, "");
    const fruits = try probe.take("res");
    defer fruits.destroy(testing.allocator);
    try testing.expectEqual(g1, fruits.gen);
    try testing.expect(fruits.err == null);
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
    const ga = h.act(reg.gen, 1, .{ .row_action = .{
        .from_root_search = false,
        .list_gen = fruits.gen,
        .row_index = 1,
        .action_index = 1,
    } });
    const done = try probe.take("act");
    defer done.destroy(testing.allocator);
    try testing.expectEqual(ga, done.gen);
    try testing.expect(done.err == null);
    try testing.expectEqual(Outcome.close, done.outcome);
    // The action took its row's actions away: pressing it again is an
    // error, not a read of whatever `row.actions` is now.
    _ = h.act(reg.gen, 1, .{ .row_action = .{
        .from_root_search = false,
        .list_gen = fruits.gen,
        .row_index = 1,
        .action_index = 1,
    } });
    const again = try probe.take("act");
    defer again.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, again.err.?, "no actions") != null);
    _ = h.list(reg.gen, 3, "");
    const eaten = try probe.take("res");
    defer eaten.destroy(testing.allocator);
    try testing.expectEqualStrings("Banana", eaten.items[0].title);

    // A search command gets the query, and lumen.exec runs programs.
    _ = h.list(reg.gen, 2, "it's \"quoted\"");
    const echo = try probe.take("res");
    defer echo.destroy(testing.allocator);
    try testing.expect(echo.err == null);
    try testing.expectEqualStrings("you typed it's \"quoted\"", echo.items[0].title);

    // A run command's return value.
    _ = h.act(reg.gen, 0, .command_run);
    const hello = try probe.take("act");
    defer hello.destroy(testing.allocator);
    try testing.expectEqual(Outcome.stay, hello.outcome);

    // Root search: rows from providers, their Lua actions run there.
    const gr = h.root(reg.gen, "21");
    const r21 = try probe.take("root");
    defer r21.destroy(testing.allocator);
    try testing.expectEqual(gr, r21.gen);
    try testing.expectEqual(@as(usize, 1), r21.sections.len);
    try testing.expectEqual(@as(u16, 4), r21.sections[0].command);
    const doubled = r21.sections[0].items[0];
    try testing.expectEqualStrings("42", doubled.title);
    try testing.expect(doubled.action.ext_item.root);
    _ = h.act(reg.gen, 4, .{ .row_action = .{
        .from_root_search = true,
        .list_gen = doubled.action.ext_item.gen,
        .row_index = 0,
        .action_index = 0,
    } });
    (try probe.take("act")).destroy(testing.allocator);
    _ = h.list(reg.gen, 3, "");
    const noted = try probe.take("res");
    defer noted.destroy(testing.allocator);
    try testing.expectEqualStrings("42", noted.items[0].title);
    _ = h.root(reg.gen, "not a number");
    const none = try probe.take("root");
    defer none.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.sections.len);

    // An action against a list that has been replaced is refused.
    _ = h.list(reg.gen, 1, "");
    (try probe.take("res")).destroy(testing.allocator);
    _ = h.act(reg.gen, 1, .{ .row_action = .{
        .from_root_search = false,
        .list_gen = fruits.gen,
        .row_index = 1,
        .action_index = 1,
    } });
    const stale = try probe.take("act");
    defer stale.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, stale.err.?, "changed") != null);

    // After a reload, requests against the old registry are refused.
    h.reload();
    try probe.wait("reg");
    _ = h.list(reg.gen, 1, "");
    const old = try probe.take("res");
    defer old.destroy(testing.allocator);
    try testing.expectEqualStrings("Extensions were reloaded", old.err.?);
}

test "errors in extensions come back as messages" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp, &dbuf);
    try writeTestFile(dir, "extensions/bad/init.lua",
        \\return lumen.extension { commands = {
        \\  { name = "boom", title = "Boom", items = function() error("kaboom") end },
        \\  { name = "loop", title = "Loop", search = function() while true do end end },
        \\  { name = "badrow", title = "Bad Row", items = { { subtitle = "no title" } } },
        \\  { name = "badret", title = "Bad Return", run = function() return 42 end },
        \\} }
    );
    try writeTestFile(dir, "extensions/syntax/init.lua", "return lumen.extension {");
    try writeTestFile(dir, "extensions/Bad Name/init.lua", "return nil");
    try writeTestFile(dir, "extensions/keys/init.lua", "lumen.keymap('g', 'x.y')");
    try writeTestFile(dir, "extensions/sets/init.lua", "lumen.set { widht = 'wide' }");
    try writeTestFile(dir, "extensions/lay/init.lua", "lumen.layout { panels = 'triple' }");

    var probe: Probe = .{};
    defer probe.deinit();
    const h = try testHost(&probe, dir);
    defer h.shutdown();
    h.reload();
    try probe.wait("reg");
    const reg = probe.reg.?;
    try testing.expectEqual(@as(usize, 4), reg.commands.len);
    try testing.expectEqual(@as(usize, 5), reg.problems.len);
    try testing.expect(!reg.has_layout);
    for (reg.problems) |p| {
        const want: []const u8 = if (std.mem.eql(
            u8,
            p.ext,
            "Bad Name",
        )) "folder names" else if (std.mem.eql(
            u8,
            p.ext,
            "keys",
        )) "needs ctrl" else if (std.mem.eql(
            u8,
            p.ext,
            "sets",
        )) "no setting named \"widht\"" else if (std.mem.eql(
            u8,
            p.ext,
            "lay",
        )) "bad value for panels" else "unexpected symbol near <eof>";
        if (std.mem.find(u8, p.message, want) == null) {
            std.debug.print("{s}: {s}\n", .{ p.ext, p.message });
            return error.TestUnexpectedResult;
        }
    }

    _ = h.list(reg.gen, 0, "");
    const boom = try probe.take("res");
    defer boom.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, boom.err.?, "kaboom") != null);

    _ = h.list(reg.gen, 2, "");
    const badrow = try probe.take("res");
    defer badrow.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, badrow.err.?, "items[1].title is missing") != null);

    _ = h.act(reg.gen, 3, .command_run);
    const badret = try probe.take("act");
    defer badret.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, badret.err.?, "must return") != null);
}

test "preferences read Settings' file over their defaults; storage persists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp, &dbuf);
    try writeTestFile(dir, "extensions/kv/init.lua",
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
    try writeTestFile(dir, "data/extensions/kv/preferences.json", "{\"loud\": true}");

    var probe: Probe = .{};
    defer probe.deinit();
    const h = try testHost(&probe, dir);
    defer h.shutdown();
    h.reload();
    try probe.wait("reg");
    const reg = probe.reg.?;
    try testing.expectEqual(@as(usize, 3), reg.prefs.len);
    try testing.expectEqual(PrefKind.toggle, reg.prefs[1].kind);
    try testing.expectEqualStrings("false", reg.prefs[1].default);
    try testing.expectEqualStrings("s", reg.prefs[2].default);
    try testing.expectEqualStrings("Medium", reg.prefs[2].choices[1].label);
    try testing.expect(std.mem.endsWith(
        u8,
        reg.prefs[0].file,
        "data/extensions/kv/preferences.json",
    ));

    _ = h.list(reg.gen, 0, "");
    const before = try probe.take("res");
    defer before.destroy(testing.allocator);
    const want = [_][]const u8{ "nobody", "true", "s", "nil", "false" };
    try testing.expect(before.err == null);
    for (want, before.items) |w, it| try testing.expectEqualStrings(w, it.title);

    _ = h.act(reg.gen, 1, .command_run);
    (try probe.take("act")).destroy(testing.allocator);
    _ = h.act(reg.gen, 1, .command_run);
    (try probe.take("act")).destroy(testing.allocator);
    // Storage outlives a reload (a new Lua state reads the file).
    probe.reg = null;
    defer reg.destroy(testing.allocator);
    h.reload();
    try probe.wait("reg");
    const reg2 = probe.reg.?;
    _ = h.list(reg2.gen, 0, "");
    const after = try probe.take("res");
    defer after.destroy(testing.allocator);
    try testing.expectEqualStrings("2", after.items[3].title);
}

test "storage never writes over what it cannot read, and reads back what it wrote" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp, &dbuf);
    const read_back =
        \\local function file() local f = io.open(lumen.data_dir .. "/storage.json") local t = f:read("a") f:close() return t end
        \\local ok, err = pcall(lumen.storage.set, "k", "v")
        \\local back = ok and lumen.json.decode(file()).k
        \\return lumen.extension { commands = { { name = "show", title = "Show", items = {
        \\  tostring(ok), (tostring(err):find("not overwritten") and "not overwritten" or tostring(err)),
        \\  file(), tostring(lumen.storage.get("k")), tostring(back),
        \\} } } }
    ;
    try writeTestFile(dir, "extensions/broken/init.lua", read_back);
    try writeTestFile(dir, "data/extensions/broken/storage.json", "{\"a\": 1, oops");
    // Bytes that are not UTF-8 are stored as U+FFFD, so the file still reads.
    try writeTestFile(dir, "extensions/bytes/init.lua", "lumen.storage.set('x', 'a\\xffb')\n" ++ read_back);
    // Folders named like init.lua and the style would share their files.
    try writeTestFile(dir, "extensions/config/init.lua", "return nil");
    try writeTestFile(dir, "extensions/style/init.lua", "return nil");

    var probe: Probe = .{};
    defer probe.deinit();
    const h = try testHost(&probe, dir);
    defer h.shutdown();
    h.reload();
    try probe.wait("reg");
    const reg = probe.reg.?;
    try testing.expectEqual(@as(usize, 2), reg.problems.len);
    for (reg.problems) |p| try testing.expect(std.mem.find(u8, p.message, "are taken") != null);

    _ = h.list(reg.gen, 0, "");
    const broken = try probe.take("res");
    defer broken.destroy(testing.allocator);
    try testing.expect(broken.err == null);
    const want = [_][]const u8{ "false", "not overwritten", "{\"a\": 1, oops", "nil" };
    for (want, broken.items[0..want.len]) |w, it| try testing.expectEqualStrings(w, it.title);

    _ = h.list(reg.gen, 1, "");
    const bytes = try probe.take("res");
    defer bytes.destroy(testing.allocator);
    try testing.expect(bytes.err == null);
    try testing.expectEqualStrings("true", bytes.items[0].title);
    try testing.expectEqualStrings("v", bytes.items[4].title);
    try testing.expect(std.mem.find(u8, bytes.items[2].title, "\"a\u{FFFD}b\"") != null);
}

test "rows are kept to a size, and lumen.exec's strings outlive its options" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp, &dbuf);
    try writeTestFile(dir, "extensions/odd/init.lua",
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
    const h = try testHost(&probe, dir);
    defer h.shutdown();
    h.reload();
    try probe.wait("reg");
    const reg = probe.reg.?;

    // One string 1000 rows copy: 5 GB outside the state's memory cap.
    _ = h.list(reg.gen, 0, "");
    const big = try probe.take("res");
    defer big.destroy(testing.allocator);
    try testing.expectEqualStrings(rows_too_big, big.err.?);

    _ = h.list(reg.gen, 1, "");
    const long = try probe.take("res");
    defer long.destroy(testing.allocator);
    try testing.expect(long.err == null);
    const row = long.items[0];
    // Cut between characters: 512 "é" of two bytes each.
    try testing.expectEqual(@as(usize, line_bytes_max), row.title.len);
    try testing.expectEqual(@as(usize, detail_bytes_max), row.detail.len);
    try testing.expectEqual(@as(usize, line_bytes_max), row.meta[0].value.len);

    _ = h.list(reg.gen, 2, "");
    const ran = try probe.take("res");
    defer ran.destroy(testing.allocator);
    try testing.expect(ran.err == null);
    try testing.expectEqualStrings("true", ran.items[0].title);
}
