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

const std = @import("std");
const c = @import("c");
const lua = @import("lua.zig");
const api = @import("api.zig");
const index = @import("index");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const themes = @import("../ui/themes.zig");

const Host = @This();

const log = std.log.scoped(.ext);

/// Per Lua state.
const memory_limit = 64 << 20;
const load_budget_ns = 5 * std.time.ns_per_s;
const list_budget_ns = 10 * std.time.ns_per_s;
const act_budget_ns = 30 * std.time.ns_per_s;
pub const max_items = 1000;
pub const max_actions = 9;
const max_query = 1024;

// ------------------------------------------------------------- results

pub const Mode = enum {
    /// `items`: listed once when the command opens, filtered by Lumen.
    list,
    /// `search`: asked again for every query.
    search,
    /// `run`: no list; Enter runs it.
    run,
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

/// `lumen.set { width = "wide" }`: a setting init.lua fixes.
pub const SettingOverride = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

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
    problems: []const Problem = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn destroy(r: *Registry, gpa: std.mem.Allocator) void {
        r.arena.deinit();
        gpa.destroy(r);
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

    pub fn destroy(r: *ListResult, gpa: std.mem.Allocator) void {
        r.arena.deinit();
        gpa.destroy(r);
    }
};

pub const Outcome = enum { close, stay, refresh };

/// What a Lua action asked for. Owned by the receiver: `destroy`.
pub const ActResult = struct {
    gen: u32,
    outcome: Outcome = .close,
    err: ?[:0]const u8 = null,
    arena: std.heap.ArenaAllocator,

    pub fn destroy(r: *ActResult, gpa: std.mem.Allocator) void {
        r.arena.deinit();
        gpa.destroy(r);
    }
};

/// Called on the GTK main loop; each takes ownership of its result.
pub const Callbacks = struct {
    ctx: ?*anyopaque,
    registry: *const fn (*Registry, ?*anyopaque) void,
    list: *const fn (*ListResult, ?*anyopaque) void,
    act: *const fn (*ActResult, ?*anyopaque) void,
};

// ---------------------------------------------------------- the worker

/// One loaded file and its Lua state. Worker thread only.
pub const Ext = struct {
    budget: lua.Budget = .{ .max = memory_limit },
    L: *lua.State = undefined,
    host: *Host,
    id: [:0]const u8,
    dir: [:0]const u8,
    /// While its file runs: where `lumen.theme` and `lumen.keymap` go.
    load: ?*Load = null,
    /// The table its last list returned, for the rows' actions.
    last_ref: c_int = c_noref,
    last_gen: u32 = 0,
    last_cmd: u16 = 0,

    pub fn gpa(e: *Ext) std.mem.Allocator {
        return e.host.gpa;
    }
    pub fn io(e: *Ext) std.Io {
        return e.host.io;
    }
};

const c_noref = lua.c.LUA_NOREF;

/// What a reload collects; lives in the new registry's arena.
pub const Load = struct {
    a: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    wcmds: std.ArrayList(WorkerCommand) = .empty,
    themes: std.ArrayList(themes.Theme) = .empty,
    keymaps: std.ArrayList(Keymap) = .empty,
    settings: std.ArrayList(SettingOverride) = .empty,
    problems: std.ArrayList(Problem) = .empty,
};

/// Where the worker finds a command: its state and its spec table.
const WorkerCommand = struct { ext: u16, ref: c_int, mode: Mode };

const ListReq = struct { registry: u32, command: u16, gen: u32, query_len: usize };
const ActReq = struct { registry: u32, command: u16, list_gen: u32, item: ?u32, action: u8, gen: u32 };

gpa: std.mem.Allocator,
io: std.Io,
config_dir: [:0]const u8,
cb: Callbacks,
thread: std.Thread = undefined,
lock: std.Io.Mutex = .init,
/// Bumped by every request; the worker sleeps on it.
seq: std.atomic.Value(u32) = .init(0),
stop: std.atomic.Value(bool) = .init(false),
/// Request numbers handed out (main thread).
next_gen: u32 = 0,

// Requests, under `lock`.
want_reload: bool = false,
list_req: ?ListReq = null,
list_query: [max_query]u8 = undefined,
act_req: ?ActReq = null,

// Worker thread only.
exts: std.ArrayList(*Ext) = .empty,
wcmds: []WorkerCommand = &.{},
registry_gen: u32 = 0,
/// Extension ids and dirs; reset on reload.
warena: std.heap.ArenaAllocator,

pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError;

/// Starts the worker; call `reload` to load the files. `config_dir` is
/// copied.
pub fn start(gpa: std.mem.Allocator, io: std.Io, config_dir: []const u8, cb: Callbacks) StartError!*Host {
    const h = try gpa.create(Host);
    errdefer gpa.destroy(h);
    const dir = try gpa.dupeSentinel(u8, config_dir, 0);
    errdefer gpa.free(dir);
    h.* = .{ .gpa = gpa, .io = io, .config_dir = dir, .cb = cb, .warena = .init(gpa) };
    h.thread = try std.Thread.spawn(.{}, run, .{h});
    h.thread.setName(io, "lm-ext") catch {};
    return h;
}

/// Stops and joins the worker and closes every state. Call once the GTK
/// main loop has stopped (a queued result would reach a freed host).
pub fn shutdown(h: *Host) void {
    h.stop.store(true, .release);
    h.wake();
    h.thread.join();
    h.closeAll();
    h.exts.deinit(h.gpa);
    h.warena.deinit();
    h.gpa.free(h.config_dir);
    h.gpa.destroy(h);
}

/// Loads every file again; the new registry arrives through the callback.
pub fn reload(h: *Host) void {
    {
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        h.want_reload = true;
    }
    h.wake();
}

/// Asks for command `command`'s rows (`query` for search commands; longer
/// queries are cut). Returns the request's generation; a newer list request
/// replaces one not started yet.
pub fn list(h: *Host, registry: u32, command: u16, query: []const u8) u32 {
    h.next_gen +%= 1;
    const q = query[0..@min(query.len, max_query)];
    {
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        @memcpy(h.list_query[0..q.len], q);
        h.list_req = .{ .registry = registry, .command = command, .gen = h.next_gen, .query_len = q.len };
    }
    h.wake();
    return h.next_gen;
}

/// Runs a Lua action: action `action` of row `item` of the list with
/// generation `list_gen`, or the command's own `run` when `item` is null.
pub fn act(h: *Host, registry: u32, command: u16, list_gen: u32, item: ?u32, action: u8) u32 {
    h.next_gen +%= 1;
    {
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        h.act_req = .{ .registry = registry, .command = command, .list_gen = list_gen, .item = item, .action = action, .gen = h.next_gen };
    }
    h.wake();
    return h.next_gen;
}

fn wake(h: *Host) void {
    _ = h.seq.fetchAdd(1, .release);
    h.io.futexWake(u32, &h.seq.raw, 1);
}

fn run(h: *Host) void {
    var seen: u32 = 0;
    var query: [max_query]u8 = undefined;
    while (true) {
        while (h.seq.load(.acquire) == seen and !h.stop.load(.acquire)) {
            h.io.futexWaitUncancelable(u32, &h.seq.raw, seen);
        }
        if (h.stop.load(.acquire)) return;
        seen = h.seq.load(.acquire);

        var reload_now = false;
        var lreq: ?ListReq = null;
        var areq: ?ActReq = null;
        {
            h.lock.lockUncancelable(h.io);
            defer h.lock.unlock(h.io);
            reload_now = h.want_reload;
            h.want_reload = false;
            lreq = h.list_req;
            h.list_req = null;
            areq = h.act_req;
            h.act_req = null;
            if (lreq) |r| @memcpy(query[0..r.query_len], h.list_query[0..r.query_len]);
        }
        if (reload_now) h.doReload();
        if (areq) |r| h.doAct(r);
        if (lreq) |r| h.doList(r, query[0..r.query_len]);
    }
}

// --------------------------------------------------------------- reload

fn closeAll(h: *Host) void {
    for (h.exts.items) |e| {
        lua.c.lua_close(e.L);
        h.gpa.destroy(e);
    }
    h.exts.clearRetainingCapacity();
    h.gpa.free(h.wcmds);
    h.wcmds = &.{};
    _ = h.warena.reset(.retain_capacity);
}

fn doReload(h: *Host) void {
    h.closeAll();
    h.registry_gen +%= 1;
    const reg = h.gpa.create(Registry) catch {
        log.warn("reload: out of memory", .{});
        return;
    };
    reg.* = .{ .gen = h.registry_gen, .arena = .init(h.gpa) };
    var load: Load = .{ .a = reg.arena.allocator() };

    const wa = h.warena.allocator();
    if (std.fmt.allocPrintSentinel(wa, "{s}/init.lua", .{h.config_dir}, 0)) |path| {
        if (index.sys.info(path) != null) h.loadFile(&load, "config", h.config_dir, path);
    } else |_| {}
    for (h.extensionDirs(wa)) |id| {
        const dir = std.fmt.allocPrintSentinel(wa, "{s}/extensions/{s}", .{ h.config_dir, id }, 0) catch continue;
        const path = std.fmt.allocPrintSentinel(wa, "{s}/init.lua", .{dir}, 0) catch continue;
        if (!validId(id)) {
            problem(&load, id, "extension folder names may use only a-z, 0-9, - and _");
            continue;
        }
        if (index.sys.info(path) == null) {
            problem(&load, id, "no init.lua in the extension's folder");
            continue;
        }
        h.loadFile(&load, id, dir, path);
    }

    h.wcmds = h.gpa.dupe(WorkerCommand, load.wcmds.items) catch &.{};
    if (h.wcmds.len != load.commands.items.len) load.commands.clearRetainingCapacity();
    reg.commands = load.commands.items;
    reg.themes = load.themes.items;
    reg.keymaps = load.keymaps.items;
    reg.settings = load.settings.items;
    reg.problems = load.problems.items;
    for (reg.problems) |p| log.warn("{s}: {s}", .{ p.ext, p.message });
    h.deliver(.{ .registry = reg });
}

/// Names of the folders under extensions/, sorted, in `a`.
fn extensionDirs(h: *Host, a: std.mem.Allocator) []const [:0]const u8 {
    const path = std.fmt.allocPrintSentinel(a, "{s}/extensions", .{h.config_dir}, 0) catch return &.{};
    const d = c.g_dir_open(path.ptr, 0, null) orelse return &.{};
    defer c.g_dir_close(d);
    var names: std.ArrayList([:0]const u8) = .empty;
    while (c.g_dir_read_name(d)) |n| {
        const name = std.mem.span(n);
        if (name.len == 0 or name[0] == '.') continue;
        const full = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, name }, 0) catch continue;
        const info = index.sys.info(full) orelse continue;
        if (!info.is_dir) continue;
        names.append(a, a.dupeSentinel(u8, name, 0) catch continue) catch continue;
    }
    std.mem.sort([:0]const u8, names.items, {}, struct {
        fn lt(_: void, x: [:0]const u8, y: [:0]const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return names.items;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 40) return false;
    for (id) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn problem(load: *Load, ext: []const u8, message: []const u8) void {
    load.problems.append(load.a, .{
        .ext = load.a.dupeSentinel(u8, ext, 0) catch return,
        .message = load.a.dupeSentinel(u8, message, 0) catch return,
    }) catch {};
}

fn loadFile(h: *Host, load: *Load, id: []const u8, dir: []const u8, path: [:0]const u8) void {
    const wa = h.warena.allocator();
    const e = h.gpa.create(Ext) catch return problem(load, id, "out of memory");
    e.* = .{
        .host = h,
        .id = wa.dupeSentinel(u8, id, 0) catch "",
        .dir = wa.dupeSentinel(u8, dir, 0) catch "",
    };
    e.L = lua.newState(&e.budget) orelse {
        h.gpa.destroy(e);
        return problem(load, id, "out of memory");
    };
    // What this file adds is dropped again if it fails half-way.
    const marks = .{ load.commands.items.len, load.wcmds.items.len, load.themes.items.len, load.keymaps.items.len, load.settings.items.len };
    e.load = load;
    e.budget.deadline_ns = index.sys.monotonicNs() + load_budget_ns;
    var ctx: LoadCtx = .{ .e = e, .load = load, .path = path, .ext_index = @intCast(h.exts.items.len) };
    const err = lua.protect(e.L, load.a, LoadCtx, &ctx, LoadCtx.run);
    e.load = null;
    e.budget.deadline_ns = std.math.maxInt(u64);
    if (err == null) if (h.exts.append(h.gpa, e)) return else |_| {};
    load.commands.shrinkRetainingCapacity(marks[0]);
    load.wcmds.shrinkRetainingCapacity(marks[1]);
    load.themes.shrinkRetainingCapacity(marks[2]);
    load.keymaps.shrinkRetainingCapacity(marks[3]);
    load.settings.shrinkRetainingCapacity(marks[4]);
    problem(load, id, err orelse "out of memory");
    lua.c.lua_close(e.L);
    h.gpa.destroy(e);
}

const LoadCtx = struct {
    e: *Ext,
    load: *Load,
    path: [:0]const u8,
    ext_index: u16,

    fn run(L: *lua.State, ctx: *LoadCtx) void {
        lua.openLibs(L);
        api.install(L, ctx.e);
        if (lua.c.luaL_loadfilex(L, ctx.path.ptr, "t") != lua.c.LUA_OK) _ = lua.c.lua_error(L);
        lua.c.lua_callk(L, 0, 1, 0, null);
        switch (lua.c.lua_type(L, -1)) {
            lua.c.LUA_TNIL => {},
            lua.c.LUA_TTABLE => parseExtension(L, ctx, lua.absIndex(L, -1)),
            else => lua.raise(L, "init.lua must return lumen.extension{{...}} or nothing, not a {s}", .{lua.typeName(L, -1)}),
        }
    }
};

fn parseExtension(L: *lua.State, ctx: *LoadCtx, t: c_int) void {
    const a = ctx.load.a;
    const title = lua.fieldString(L, a, t, "title", "extension") orelse ctx.e.id;
    var default_icon: item_mod.Icon = .{ .tile = .{ .name = "application-x-addon-symbolic", .color = .purple } };
    _ = lua.getField(L, t, "icon");
    if (parseIcon(L, a, -1, "extension.icon")) |icon| default_icon = icon;
    lua.c.lua_settop(L, -2);

    if (lua.getField(L, t, "commands") != lua.c.LUA_TTABLE)
        lua.raise(L, "extension.commands: a list of commands expected, got {s}", .{lua.typeName(L, -1)});
    const cmds = lua.absIndex(L, -1);
    const n = lua.c.lua_rawlen(L, cmds);
    for (1..n + 1) |i| {
        var where_buf: [32]u8 = undefined;
        const where = std.fmt.bufPrint(&where_buf, "commands[{d}]", .{i}) catch "commands";
        if (lua.c.lua_rawgeti(L, cmds, @intCast(i)) != lua.c.LUA_TTABLE)
            lua.raise(L, "{s}: table expected, got {s}", .{ where, lua.typeName(L, -1) });
        parseCommand(L, ctx, lua.absIndex(L, -1), where, title, default_icon);
        lua.c.lua_settop(L, -2);
    }
    lua.c.lua_settop(L, -2);
}

fn parseCommand(L: *lua.State, ctx: *LoadCtx, t: c_int, where: []const u8, ext_title: [:0]const u8, default_icon: item_mod.Icon) void {
    const a = ctx.load.a;
    const name = lua.fieldString(L, a, t, "name", where) orelse lua.raise(L, "{s}.name is missing", .{where});
    if (!validId(name)) lua.raise(L, "{s}.name: use only a-z, 0-9, - and _ (got \"{s}\")", .{ where, name });
    const title = lua.fieldString(L, a, t, "title", where) orelse lua.raise(L, "{s}.title is missing", .{where});
    const id = std.fmt.allocPrintSentinel(a, "{s}.{s}", .{ ctx.e.id, name }, 0) catch lua.raise(L, "not enough memory", .{});
    for (ctx.load.commands.items) |cmd| if (std.mem.eql(u8, cmd.id, id)) lua.raise(L, "two commands named \"{s}\"", .{name});

    var mode: ?Mode = null;
    const kinds = [_]struct { [:0]const u8, Mode, bool }{ .{ "items", .list, true }, .{ "search", .search, false }, .{ "run", .run, false } };
    for (kinds) |k| {
        const ty = lua.getField(L, t, k[0]);
        defer lua.c.lua_settop(L, -2);
        if (ty == lua.c.LUA_TNIL) continue;
        const ok = ty == lua.c.LUA_TFUNCTION or (k[2] and ty == lua.c.LUA_TTABLE);
        if (!ok) lua.raise(L, "{s}.{s}: {s} expected, got {s}", .{ where, k[0], if (k[2]) "function or table" else "function", lua.typeName(L, -1) });
        if (mode != null) lua.raise(L, "{s}: give it one of items, search or run, not several", .{where});
        mode = k[1];
    }

    var icon = default_icon;
    _ = lua.getField(L, t, "icon");
    if (parseIcon(L, a, -1, where)) |x| icon = x;
    lua.c.lua_settop(L, -2);

    const cmd: Command = .{
        .id = id,
        .title = title,
        .subtitle = lua.fieldString(L, a, t, "subtitle", where) orelse ext_title,
        .icon = icon,
        .keywords = keywords(L, a, t, where),
        .placeholder = lua.fieldString(L, a, t, "placeholder", where) orelse "",
        .mode = mode orelse lua.raise(L, "{s}: give it items, search or run", .{where}),
        .detail = lua.fieldBool(L, t, "detail", false, where),
    };
    if (ctx.load.commands.items.len >= std.math.maxInt(u16)) lua.raise(L, "too many commands", .{});
    lua.c.lua_pushvalue(L, t);
    const r = lua.ref(L);
    ctx.load.wcmds.append(a, .{ .ext = ctx.ext_index, .ref = r, .mode = cmd.mode }) catch lua.raise(L, "not enough memory", .{});
    ctx.load.commands.append(a, cmd) catch lua.raise(L, "not enough memory", .{});
}

/// `keywords`: a string, or a list of strings joined with spaces.
fn keywords(L: *lua.State, a: std.mem.Allocator, t: c_int, where: []const u8) []const u8 {
    defer lua.c.lua_settop(L, -2);
    switch (lua.getField(L, t, "keywords")) {
        lua.c.LUA_TNIL => return "",
        lua.c.LUA_TSTRING => return a.dupe(u8, lua.toSlice(L, -1).?) catch "",
        lua.c.LUA_TTABLE => {
            var out: std.ArrayList(u8) = .empty;
            const n = lua.c.lua_rawlen(L, -1);
            for (1..n + 1) |i| {
                _ = lua.c.lua_rawgeti(L, -1, @intCast(i));
                defer lua.c.lua_settop(L, -2);
                const s = lua.toSlice(L, -1) orelse lua.raise(L, "{s}.keywords[{d}]: string expected", .{ where, i });
                if (out.items.len > 0) out.append(a, ' ') catch {};
                out.appendSlice(a, s) catch {};
            }
            return out.items;
        },
        else => lua.raise(L, "{s}.keywords: string or list expected, got {s}", .{ where, lua.typeName(L, -1) }),
    }
}

/// An icon: an emoji ("🐙"), an icon name ("folder-symbolic") on a grey
/// tile, or `{ name = ..., color = "blue" }`. Null for nil.
pub fn parseIcon(L: *lua.State, a: std.mem.Allocator, idx: c_int, where: []const u8) ?item_mod.Icon {
    const t = lua.absIndex(L, idx);
    switch (lua.c.lua_type(L, t)) {
        lua.c.LUA_TNIL => return null,
        lua.c.LUA_TSTRING => {
            const s = lua.toSlice(L, t).?;
            const copy = a.dupeSentinel(u8, s, 0) catch lua.raise(L, "not enough memory", .{});
            if (s.len > 0 and s.len <= 32 and s[0] >= 0x80) return .{ .emoji = copy };
            return .{ .tile = .{ .name = copy, .color = .gray } };
        },
        lua.c.LUA_TTABLE => {
            const name = lua.fieldString(L, a, t, "name", where) orelse lua.raise(L, "{s}.icon.name is missing", .{where});
            const color_name = lua.fieldString(L, a, t, "color", where) orelse "gray";
            const color = std.meta.stringToEnum(item_mod.Color, color_name) orelse
                lua.raise(L, "{s}.icon.color: one of red, orange, yellow, green, blue, purple, pink, gray (got \"{s}\")", .{ where, color_name });
            return .{ .tile = .{ .name = name, .color = color } };
        },
        else => lua.raise(L, "{s}.icon: string or table expected, got {s}", .{ where, lua.typeName(L, t) }),
    }
}

// ----------------------------------------------------------------- list

fn doList(h: *Host, req: ListReq, query: []const u8) void {
    const res = h.gpa.create(ListResult) catch return;
    res.* = .{ .gen = req.gen, .command = req.command, .query = "", .arena = .init(h.gpa) };
    const a = res.arena.allocator();
    res.query = a.dupe(u8, query) catch "";
    defer h.deliver(.{ .list = res });
    if (req.registry != h.registry_gen or req.command >= h.wcmds.len) {
        res.err = "Extensions were reloaded";
        return;
    }
    const wc = h.wcmds[req.command];
    const e = h.exts.items[wc.ext];
    e.budget.deadline_ns = index.sys.monotonicNs() + list_budget_ns;
    defer e.budget.deadline_ns = std.math.maxInt(u64);
    var ctx: ListCtx = .{ .e = e, .wc = wc, .req = req, .res = res, .query = query };
    res.err = lua.protect(e.L, a, ListCtx, &ctx, ListCtx.run);
}

const ListCtx = struct {
    e: *Ext,
    wc: WorkerCommand,
    req: ListReq,
    res: *ListResult,
    query: []const u8,

    fn run(L: *lua.State, ctx: *ListCtx) void {
        _ = lua.pushRef(L, ctx.wc.ref);
        const spec = lua.absIndex(L, -1);
        switch (ctx.wc.mode) {
            .list => if (lua.getField(L, spec, "items") == lua.c.LUA_TFUNCTION) lua.c.lua_callk(L, 0, 1, 0, null),
            .search => {
                _ = lua.getField(L, spec, "search");
                lua.pushString(L, ctx.query);
                lua.c.lua_callk(L, 1, 1, 0, null);
            },
            .run => lua.raise(L, "this command has no list", .{}),
        }
        const list_idx = lua.absIndex(L, -1);
        switch (lua.c.lua_type(L, list_idx)) {
            lua.c.LUA_TNIL => return,
            lua.c.LUA_TTABLE => {},
            else => lua.raise(L, "items: a list expected, got {s}", .{lua.typeName(L, list_idx)}),
        }
        // Kept for the rows' actions until the next list.
        const e = ctx.e;
        if (e.last_ref != c_noref) {
            lua.unref(L, e.last_ref);
            e.last_ref = c_noref;
        }
        lua.c.lua_pushvalue(L, list_idx);
        e.last_ref = lua.ref(L);
        e.last_gen = ctx.req.gen;
        e.last_cmd = ctx.req.command;
        ctx.res.items = parseItems(L, ctx.res.arena.allocator(), list_idx, ctx.req.gen, ctx.e.id);
    }
};

fn parseItems(L: *lua.State, a: std.mem.Allocator, list_idx: c_int, gen: u32, ext_id: []const u8) []Item {
    const n = @min(lua.c.lua_rawlen(L, list_idx), max_items);
    const items = a.alloc(Item, n) catch lua.raise(L, "not enough memory", .{});
    for (items, 1..) |*it, i| {
        var where_buf: [24]u8 = undefined;
        const where = std.fmt.bufPrint(&where_buf, "items[{d}]", .{i}) catch "items";
        _ = lua.c.lua_rawgeti(L, list_idx, @intCast(i));
        defer lua.c.lua_settop(L, -2);
        it.* = parseItem(L, a, lua.absIndex(L, -1), where, gen, @intCast(i - 1), ext_id);
    }
    return items;
}

fn parseItem(L: *lua.State, a: std.mem.Allocator, t: c_int, where: []const u8, gen: u32, pos: u32, ext_id: []const u8) Item {
    // A plain string is a row with that title.
    if (lua.toSlice(L, t)) |s| {
        const title = a.dupeSentinel(u8, s, 0) catch lua.raise(L, "not enough memory", .{});
        return .{ .key = key(a, ext_id, title), .title = title, .action = .{ .ext_item = defaultActions(a, L, gen, pos, title) } };
    }
    if (lua.c.lua_type(L, t) != lua.c.LUA_TTABLE) lua.raise(L, "{s}: table or string expected, got {s}", .{ where, lua.typeName(L, t) });
    const title = lua.fieldString(L, a, t, "title", where) orelse lua.raise(L, "{s}.title is missing", .{where});
    var it: Item = .{
        .key = key(a, ext_id, lua.fieldString(L, a, t, "id", where) orelse title),
        .title = title,
        .subtitle = lua.fieldString(L, a, t, "subtitle", where) orelse "",
        .accessory = lua.fieldString(L, a, t, "accessory", where) orelse "",
        .keywords = keywords(L, a, t, where),
        .detail = lua.fieldString(L, a, t, "detail", where) orelse "",
        .section = lua.fieldString(L, a, t, "section", where) orelse "",
        .confirm = lua.fieldBool(L, t, "confirm", false, where),
        .action = undefined,
    };
    _ = lua.getField(L, t, "icon");
    if (parseIcon(L, a, -1, where)) |icon| it.icon = icon;
    lua.c.lua_settop(L, -2);

    if (lua.getField(L, t, "actions") == lua.c.LUA_TNIL) {
        lua.c.lua_settop(L, -2);
        it.action = .{ .ext_item = defaultActions(a, L, gen, pos, title) };
        return it;
    }
    const acts_idx = lua.absIndex(L, -1);
    if (lua.c.lua_type(L, acts_idx) != lua.c.LUA_TTABLE) lua.raise(L, "{s}.actions: a list expected, got {s}", .{ where, lua.typeName(L, acts_idx) });
    const n = @min(lua.c.lua_rawlen(L, acts_idx), max_actions);
    if (n == 0) lua.raise(L, "{s}.actions is empty", .{where});
    const actions = a.alloc(item_mod.ExtAction, n) catch lua.raise(L, "not enough memory", .{});
    const entries = a.alloc(item_mod.Entry, n) catch lua.raise(L, "not enough memory", .{});
    for (actions, entries, 0..) |*act_out, *entry, j| {
        var wbuf: [48]u8 = undefined;
        const awhere = std.fmt.bufPrint(&wbuf, "{s}.actions[{d}]", .{ where, j + 1 }) catch where;
        _ = lua.c.lua_rawgeti(L, acts_idx, @intCast(j + 1));
        defer lua.c.lua_settop(L, -2);
        const at = lua.absIndex(L, -1);
        if (lua.c.lua_type(L, at) != lua.c.LUA_TTABLE) lua.raise(L, "{s}: table expected, got {s}", .{ awhere, lua.typeName(L, at) });
        const parsed = parseAction(L, a, at, awhere);
        act_out.* = parsed.action;
        entry.* = .{ .label = parsed.label, .keys = keysFor(j), .op = .ext, .index = @intCast(j) };
    }
    lua.c.lua_settop(L, -2);
    it.action = .{ .ext_item = .{ .gen = gen, .index = pos, .actions = actions, .entries = entries } };
    return it;
}

fn key(a: std.mem.Allocator, ext_id: []const u8, id: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "x:{s}:{s}", .{ ext_id, id }) catch "";
}

fn keysFor(j: usize) [:0]const u8 {
    return switch (j) {
        0 => "↵",
        1 => "Ctrl ↵",
        else => "",
    };
}

/// A row without actions copies its title.
fn defaultActions(a: std.mem.Allocator, L: *lua.State, gen: u32, pos: u32, title: [:0]const u8) item_mod.ExtItem {
    const actions = a.dupe(item_mod.ExtAction, &.{.{ .copy = title }}) catch lua.raise(L, "not enough memory", .{});
    const entries = a.dupe(item_mod.Entry, &.{.{ .label = "Copy to Clipboard", .keys = "↵", .op = .ext }}) catch lua.raise(L, "not enough memory", .{});
    return .{ .gen = gen, .index = pos, .actions = actions, .entries = entries };
}

const ParsedAction = struct { action: item_mod.ExtAction, label: [:0]const u8 };

fn parseAction(L: *lua.State, a: std.mem.Allocator, t: c_int, where: []const u8) ParsedAction {
    const title = lua.fieldString(L, a, t, "title", where);
    {
        const ty = lua.getField(L, t, "run");
        defer lua.c.lua_settop(L, -2);
        if (ty == lua.c.LUA_TFUNCTION) return .{ .action = .lua, .label = title orelse "Run" };
        if (ty != lua.c.LUA_TNIL) lua.raise(L, "{s}.run: function expected, got {s}", .{ where, lua.typeName(L, -1) });
    }
    const kind = lua.fieldString(L, a, t, "kind", where) orelse
        lua.raise(L, "{s}: give it a run function, or make it with lumen.action.*", .{where});
    if (std.mem.eql(u8, kind, "open")) {
        const target = lua.fieldString(L, a, t, "target", where) orelse lua.raise(L, "{s}.target is missing", .{where});
        return .{ .action = .{ .open = target }, .label = title orelse "Open" };
    }
    if (std.mem.eql(u8, kind, "copy") or std.mem.eql(u8, kind, "paste")) {
        const text = lua.fieldString(L, a, t, "text", where) orelse lua.raise(L, "{s}.text is missing", .{where});
        return if (kind[0] == 'c')
            .{ .action = .{ .copy = text }, .label = title orelse "Copy to Clipboard" }
        else
            .{ .action = .{ .paste = text }, .label = title orelse "Paste to Active App" };
    }
    if (std.mem.eql(u8, kind, "exec")) {
        if (lua.getField(L, t, "argv") != lua.c.LUA_TTABLE) lua.raise(L, "{s}.argv: a list of strings expected", .{where});
        defer lua.c.lua_settop(L, -2);
        const n = lua.c.lua_rawlen(L, -1);
        if (n == 0 or n > 32) lua.raise(L, "{s}.argv: 1 to 32 strings expected", .{where});
        const argv = a.alloc([:0]const u8, n) catch lua.raise(L, "not enough memory", .{});
        for (argv, 1..) |*arg, i| {
            _ = lua.c.lua_rawgeti(L, -1, @intCast(i));
            defer lua.c.lua_settop(L, -2);
            const s = lua.toSlice(L, -1) orelse lua.raise(L, "{s}.argv[{d}]: string expected", .{ where, i });
            arg.* = a.dupeSentinel(u8, s, 0) catch lua.raise(L, "not enough memory", .{});
        }
        return .{ .action = .{ .exec = argv }, .label = title orelse "Run" };
    }
    lua.raise(L, "{s}.kind: unknown \"{s}\"", .{ where, kind });
}

// ------------------------------------------------------------------ act

fn doAct(h: *Host, req: ActReq) void {
    const res = h.gpa.create(ActResult) catch return;
    res.* = .{ .gen = req.gen, .arena = .init(h.gpa) };
    defer h.deliver(.{ .act = res });
    if (req.registry != h.registry_gen or req.command >= h.wcmds.len) {
        res.err = "Extensions were reloaded";
        return;
    }
    const wc = h.wcmds[req.command];
    const e = h.exts.items[wc.ext];
    e.budget.deadline_ns = index.sys.monotonicNs() + act_budget_ns;
    defer e.budget.deadline_ns = std.math.maxInt(u64);
    var ctx: ActCtx = .{ .e = e, .wc = wc, .req = req, .res = res };
    res.err = lua.protect(e.L, res.arena.allocator(), ActCtx, &ctx, ActCtx.run);
}

const ActCtx = struct {
    e: *Ext,
    wc: WorkerCommand,
    req: ActReq,
    res: *ActResult,

    fn run(L: *lua.State, ctx: *ActCtx) void {
        const req = ctx.req;
        if (req.item) |item| {
            const e = ctx.e;
            if (e.last_ref == c_noref or e.last_gen != req.list_gen or e.last_cmd != req.command)
                lua.raise(L, "the list changed meanwhile; try again", .{});
            _ = lua.pushRef(L, e.last_ref);
            if (lua.c.lua_rawgeti(L, -1, @intCast(item + 1)) != lua.c.LUA_TTABLE) lua.raise(L, "that row has no actions", .{});
            const row = lua.absIndex(L, -1);
            _ = lua.getField(L, row, "actions");
            _ = lua.c.lua_rawgeti(L, -1, @as(c_int, req.action) + 1);
            if (lua.c.lua_type(L, -1) != lua.c.LUA_TTABLE or lua.getField(L, -1, "run") != lua.c.LUA_TFUNCTION)
                lua.raise(L, "that action is not a Lua function", .{});
            lua.c.lua_pushvalue(L, row);
            lua.c.lua_callk(L, 1, 1, 0, null);
        } else {
            _ = lua.pushRef(L, ctx.wc.ref);
            if (lua.getField(L, -1, "run") != lua.c.LUA_TFUNCTION) lua.raise(L, "this command has no run function", .{});
            lua.c.lua_callk(L, 0, 1, 0, null);
        }
        ctx.res.outcome = switch (lua.c.lua_type(L, -1)) {
            lua.c.LUA_TNIL => .close,
            lua.c.LUA_TSTRING => std.meta.stringToEnum(Outcome, lua.toSlice(L, -1).?) orelse
                lua.raise(L, "run must return nothing, \"close\", \"stay\" or \"refresh\" (got \"{s}\")", .{lua.toSlice(L, -1).?}),
            else => lua.raise(L, "run must return nothing, \"close\", \"stay\" or \"refresh\", not a {s}", .{lua.typeName(L, -1)}),
        };
    }
};

// ------------------------------------------------------------- delivery

const Hop = struct {
    h: *Host,
    what: union(enum) { registry: *Registry, list: *ListResult, act: *ActResult },
};

fn deliver(h: *Host, what: @FieldType(Hop, "what")) void {
    const hop = h.gpa.create(Hop) catch {
        switch (what) {
            inline else => |r| r.destroy(h.gpa),
        }
        return;
    };
    hop.* = .{ .h = h, .what = what };
    _ = c.g_idle_add(&onIdle, hop);
}

fn onIdle(data: ?*anyopaque) callconv(.c) c.gboolean {
    const hop: *Hop = @ptrCast(@alignCast(data.?));
    const h = hop.h;
    defer h.gpa.destroy(hop);
    switch (hop.what) {
        .registry => |r| h.cb.registry(r, h.cb.ctx),
        .list => |r| h.cb.list(r, h.cb.ctx),
        .act => |r| h.cb.act(r, h.cb.ctx),
    }
    return 0;
}

// ----------------------------------------------------------------- stamp

/// Changes when init.lua or any .lua file in an extension's folder (not
/// subfolders) is added, removed or edited: then the files are reloaded.
pub fn stamp(config_dir: []const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&buf, "{s}/init.lua", .{config_dir}, 0)) |p| hashFile(&hasher, p) else |_| {}
    const ext_dir = std.fmt.bufPrintSentinel(&buf, "{s}/extensions", .{config_dir}, 0) catch return hasher.final();
    const d = c.g_dir_open(ext_dir.ptr, 0, null) orelse return hasher.final();
    defer c.g_dir_close(d);
    while (c.g_dir_read_name(d)) |n| {
        var sub_buf: [4096]u8 = undefined;
        const sub = std.fmt.bufPrintSentinel(&sub_buf, "{s}/extensions/{s}", .{ config_dir, std.mem.span(n) }, 0) catch continue;
        hasher.update(sub);
        const sd = c.g_dir_open(sub.ptr, 0, null) orelse continue;
        defer c.g_dir_close(sd);
        while (c.g_dir_read_name(sd)) |fname| {
            const f = std.mem.span(fname);
            if (!std.mem.endsWith(u8, f, ".lua")) continue;
            var fbuf: [4096]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&fbuf, "{s}/{s}", .{ sub, f }, 0) catch continue;
            hashFile(&hasher, p);
        }
    }
    return hasher.final();
}

fn hashFile(hasher: *std.hash.Wyhash, path: [:0]const u8) void {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    hasher.update(path);
    if (linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .SIZE = true, .MTIME = true, .INO = true }, &st)) != .SUCCESS) return;
    hasher.update(std.mem.asBytes(&st.mtime.sec));
    hasher.update(std.mem.asBytes(&st.mtime.nsec));
    hasher.update(std.mem.asBytes(&st.size));
    hasher.update(std.mem.asBytes(&st.ino));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Collects what the host delivers; the test pumps GLib's main loop.
const Probe = struct {
    reg: ?*Registry = null,
    res: ?*ListResult = null,
    act: ?*ActResult = null,

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
    fn deinit(p: *Probe) void {
        if (p.reg) |r| r.destroy(testing.allocator);
        if (p.res) |r| r.destroy(testing.allocator);
        if (p.act) |r| r.destroy(testing.allocator);
    }
    /// Pumps the main loop until `field` is set (up to 10 s).
    fn wait(p: *Probe, comptime field: []const u8) !void {
        const until = index.sys.monotonicNs() + 10 * std.time.ns_per_s;
        while (@field(p, field) == null) {
            if (index.sys.monotonicNs() > until) return error.Timeout;
            // Nothing ready: a 1 ms nap (poll with no descriptors).
            if (c.g_main_context_iteration(null, 0) == 0) _ = std.os.linux.poll(&[0]std.os.linux.pollfd{}, 0, 1);
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
    const p = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    if (std.mem.findScalarLast(u8, p, '/')) |s| index.sys.mkdirP(p[0..s]);
    try index.sys.writeFile(p, data);
}

fn testHost(probe: *Probe, dir: []const u8) !*Host {
    return start(testing.allocator, testing.io, dir, .{ .ctx = probe, .registry = &Probe.onRegistry, .list = &Probe.onList, .act = &Probe.onAct });
}

test "extensions load, list, search and run actions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try index.sys.tmpDirPath(&tmp, &dbuf);
    try writeTestFile(dir, "init.lua",
        \\lumen.theme { id = "mine", name = "Mine", bg = "#101010", fg = "#f0f0f0", accent = "#ff8800" }
        \\lumen.keymap("ctrl+g", "demo.fruits")
        \\lumen.set { width = "wide", suggestions = false, opacity = 90 }
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
        \\          actions = { lumen.action.copy("banana"), { title = "Eat", run = function(row) util.eaten = row.title end } } },
        \\    } },
        \\    { name = "echo", title = "Echo", search = function(q)
        \\        local out = lumen.exec({ "sh", "-c", "printf %s \"$1\"", "sh", q })
        \\        return { { title = "you typed " .. out } }
        \\    end },
        \\    { name = "eaten", title = "Eaten", items = function() return { util.eaten or "nothing" } end },
        \\  },
        \\}
    );
    try writeTestFile(dir, "extensions/demo/util.lua", "return {}");
    try writeTestFile(dir, "extensions/broken/init.lua", "return lumen.extension { commands = { { name = 'x' } } }");

    var probe: Probe = .{};
    defer probe.deinit();
    const h = try testHost(&probe, dir);
    defer h.shutdown();
    h.reload();
    try probe.wait("reg");
    const reg = probe.reg.?;

    try testing.expectEqual(@as(usize, 4), reg.commands.len);
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
    for (reg.settings) |o| {
        const want: []const u8 = if (std.mem.eql(u8, o.key, "width")) "wide" else if (std.mem.eql(u8, o.key, "suggestions")) "false" else "90";
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
    try testing.expectEqualStrings("Copy to Clipboard", fruits.items[0].action.ext_item.entries[0].label);
    const banana = fruits.items[1];
    try testing.expectEqualStrings("yellow", banana.subtitle);
    try testing.expectEqualStrings("Long", banana.section);
    try testing.expectEqualStrings("a long fruit", banana.detail);
    try testing.expectEqualStrings("banana", banana.action.ext_item.actions[0].copy);
    try testing.expectEqual(item_mod.ExtAction.lua, banana.action.ext_item.actions[1]);
    try testing.expectEqualStrings("Ctrl ↵", banana.action.ext_item.entries[1].keys);

    // Its Lua action runs against that list, and changes state other
    // commands of the extension see.
    const ga = h.act(reg.gen, 1, fruits.gen, 1, 1);
    const done = try probe.take("act");
    defer done.destroy(testing.allocator);
    try testing.expectEqual(ga, done.gen);
    try testing.expect(done.err == null);
    try testing.expectEqual(Outcome.close, done.outcome);
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
    _ = h.act(reg.gen, 0, 0, null, 0);
    const hello = try probe.take("act");
    defer hello.destroy(testing.allocator);
    try testing.expectEqual(Outcome.stay, hello.outcome);

    // An action against a list that has been replaced is refused.
    _ = h.act(reg.gen, 1, fruits.gen, 1, 1);
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
    const dir = try index.sys.tmpDirPath(&tmp, &dbuf);
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

    var probe: Probe = .{};
    defer probe.deinit();
    const h = try testHost(&probe, dir);
    defer h.shutdown();
    h.reload();
    try probe.wait("reg");
    const reg = probe.reg.?;
    try testing.expectEqual(@as(usize, 4), reg.commands.len);
    try testing.expectEqual(@as(usize, 4), reg.problems.len);
    for (reg.problems) |p| {
        const want: []const u8 = if (std.mem.eql(u8, p.ext, "Bad Name")) "folder names" else if (std.mem.eql(u8, p.ext, "keys")) "needs ctrl" else if (std.mem.eql(u8, p.ext, "sets")) "no setting named \"widht\"" else "unexpected symbol near <eof>";
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

    _ = h.act(reg.gen, 3, 0, null, 0);
    const badret = try probe.take("act");
    defer badret.destroy(testing.allocator);
    try testing.expect(std.mem.find(u8, badret.err.?, "must return") != null);
}
