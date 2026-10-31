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
//! This file is the host's public side and its thread: the types the
//! window receives, the requests it posts (main thread), the worker's loop
//! that takes them, and the delivery of answers to the main loop. What the
//! worker does with a request is in files of its own:
//!
//!   loading.zig    reload: each file in a new Lua state, a new registry
//!   spec.zig       what `lumen.extension { ... }` returns, read into a Load
//!   Load.zig       what a reload collects; undone for a file that fails
//!   Extension.zig  one file's Lua state, and running Lua in it
//!   requests.zig   list, root search, act and submit, run in that state
//!   api.zig        the `lumen` module the files call
//!   rows.zig       rows Lua returns, read into Items
//!   registry.zig   what the window gets from a reload
//!   stamp.zig      whether the files changed (the window asks, main thread)
//!
//! A request goes: `list` (main thread) → `post` → `run` (the worker's
//! loop) → `requests.listExecute` → `ListContext.run` (inside Lua) →
//! `deliver` → `deliverCallback` (main loop) → `Callbacks.list_callback`
//! (the UI). `act`, `submit` and `root` go the same way; `reload` runs
//! `loading.reloadExecute`.

const std = @import("std");
const c = @import("c");
const os = @import("os");
const core = @import("core");
const rows_mod = @import("rows.zig");
const registry_mod = @import("registry.zig");
const generation_mod = @import("generation.zig");
const stamp_mod = @import("stamp.zig");
const requests = @import("requests.zig");
const loading = @import("loading.zig");
pub const Extension = @import("Extension.zig");
pub const Load = @import("Load.zig");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;

const Host = @This();

const log = std.log.scoped(.ext);
const assert = std.debug.assert;

/// The most rows one list answer takes, and actions one row takes.
pub const items_max = rows_mod.items_max;
pub const actions_max = rows_mod.actions_max;
/// The most rows one command adds to the root search, so that a single
/// extension cannot push the others' rows out.
pub const root_search_items_max = 8;
/// Fields of one form.
pub const form_fields_max = 20;
/// An extension's folder name, a command's or a field's name.
pub const id_bytes_max = 40;
comptime {
    assert(root_search_items_max <= items_max);
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
pending: requests.Pending = .{},
/// The style to load before init.lua; empty is none. Under `lock`.
style: core.FixedStr(64) = .{},

// Worker thread only.
extensions: std.ArrayList(*Extension) = .empty,
/// Where the worker finds each command of the current registry, in the
/// registry's order.
worker_commands: []requests.WorkerCommand = &.{},
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

/// Each request's answer is handed to its callback on the GTK main loop,
/// with `context`, and the callback owns it from then on: `reload`'s to
/// `registry_callback`, `list`'s to `list_callback`, `act`'s and `submit`'s
/// to `act_callback`, `root`'s to `root_callback`.
pub const Callbacks = struct {
    context: ?*anyopaque,
    registry_callback: *const fn (*Registry, ?*anyopaque) void,
    list_callback: *const fn (*ListResult, ?*anyopaque) void,
    act_callback: *const fn (*ActResult, ?*anyopaque) void,
    root_callback: *const fn (*RootResult, ?*anyopaque) void,
};

/// A form's values, as the UI hands them over.
pub const FormValue = struct { name: []const u8, value: []const u8, toggle: bool };

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
    loading.closeAll(host);
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
    _ = host.post(.reload, true);
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
    var request: requests.ListRequest = .{
        .registry_generation = registry_generation,
        .command = command,
        .request_generation = request_generation,
        .query = .{},
    };
    request.query.set(query);
    _ = host.post(.list, request);
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
    const request = requests.SubmitRequest.create(
        host.gpa,
        registry_generation,
        command,
        request_generation,
        values,
    ) catch {
        log.warn("submit: out of memory, not sent", .{});
        return request_generation;
    };
    // The request it replaces never ran, and nothing else frees it.
    if (host.post(.submit, request)) |replaced| replaced.destroy(host.gpa);
    return request_generation;
}

/// Asks every command with `root` for rows for `query`; a newer root
/// request replaces one not started yet.
pub fn root(
    host: *Host,
    registry_generation: RegistryGeneration,
    query: []const u8,
) RequestGeneration {
    const request_generation = host.requestGenerationNext();
    var request: requests.RootSearchRequest = .{
        .registry_generation = registry_generation,
        .request_generation = request_generation,
        .query = .{},
    };
    request.query.set(query);
    _ = host.post(.root_search, request);
    return request_generation;
}

/// What `act` runs: a command's own `run`, or one action of a row the
/// command listed (in its list or in the root search).
pub const ActTarget = requests.ActRequest.Target;

/// Runs a Lua action of `command`; see `ActTarget`.
pub fn act(
    host: *Host,
    registry_generation: RegistryGeneration,
    command: CommandIndex,
    target: ActTarget,
) RequestGeneration {
    const request_generation = host.requestGenerationNext();
    _ = host.post(.act, .{
        .registry_generation = registry_generation,
        .command = command,
        .request_generation = request_generation,
        .target = target,
    });
    return request_generation;
}

/// The window keeps 0 for "no request pending" (`ext_act_generation`), so 0 is
/// never handed out, even after the counter wraps.
fn requestGenerationNext(host: *Host) RequestGeneration {
    host.request_generation_last = host.request_generation_last.next();
    return host.request_generation_last;
}

/// Hands `request` to the worker as the pending request of its kind, and
/// wakes it. Returns the request it replaced (one the worker had not taken
/// yet), if any.
fn post(
    host: *Host,
    comptime kind: std.meta.FieldEnum(requests.Pending),
    request: @FieldType(requests.Pending, @tagName(kind)),
) @FieldType(requests.Pending, @tagName(kind)) {
    const replaced = blk: {
        host.lock.lockUncancelable(host.io);
        defer host.lock.unlock(host.io);
        const replaced = @field(host.pending, @tagName(kind));
        @field(host.pending, @tagName(kind)) = request;
        break :blk replaced;
    };
    host.wake();
    return replaced;
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
        if (pending.reload) loading.reloadExecute(host);
        if (pending.act) |request| requests.actExecute(host, request);
        if (pending.submit) |request| requests.submitExecute(host, request);
        if (pending.list) |request| requests.listExecute(host, &request);
        if (pending.root_search) |request| requests.rootSearchExecute(host, &request);
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

fn pendingTake(host: *Host) requests.Pending {
    host.lock.lockUncancelable(host.io);
    defer host.lock.unlock(host.io);
    const pending = host.pending;
    host.pending = .{};
    return pending;
}

// ------------------------------------------------------------- delivery

/// An answer for the window (a Registry, ListResult, ActResult or
/// RootResult), owned by it once delivered. Null when out of memory: the
/// request then gets no answer, as if a newer one had replaced it, and the
/// log says which kind was dropped.
pub fn answerCreate(host: *Host, comptime T: type, what: []const u8, answer: T) ?*T {
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
pub const Answer = union(enum) {
    registry: *Registry,
    list: *ListResult,
    act: *ActResult,
    root: *RootResult,
};

const Delivery = struct { host: *Host, answer: Answer };

/// Hands `answer` to its callback on the GTK main loop. Worker thread only.
pub fn deliver(host: *Host, answer: Answer) void {
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
    _ = loading;
    _ = requests;
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
    try testing.expectEqualStrings(requests.rows_too_big, big.error_message.?);

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
