//! The `lumen` module extensions see (`local lumen = require("lumen")`).
//! EXTENSIONS.md documents it; keep the two in step.

const std = @import("std");
const lua = @import("luart").lua;
const c = lua.c;
const Host = @import("Host.zig");
const json = @import("luart").json;
const proc = @import("../sys/proc.zig");
const themes = @import("../ui/themes.zig");
const os = @import("os");
const exec = os.child;
const gtk = @import("c");
const Settings = @import("../settings.zig").Settings;
const layout_mod = @import("../layout.zig");

const log = std.log.scoped(.ext);

fn extOf(L: *lua.State) *Host.Ext {
    return @fieldParentPtr("budget", lua.budgetOf(L));
}

/// Sets up `lumen` (also a global), `require` for the extension's own
/// modules, and `print` (to Lumen's log). Inside `protect`.
pub fn install(L: *lua.State, e: *Host.Ext) void {
    // require("x") finds x.lua and x/init.lua in the extension's folder.
    _ = c.lua_getglobal(L, "package");
    var buf: [4200]u8 = undefined;
    const path = std.mem.printSentinel(
        &buf,
        "{s}/?.lua;{s}/?/init.lua",
        .{ e.dir, e.dir },
        0,
    ) catch lua.raise(L, "extension path too long", .{});
    _ = c.lua_pushstring(L, path.ptr);
    c.lua_setfield(L, -2, "path");
    c.lua_settop(L, -2);

    c.lua_createtable(L, 0, 16);
    lua.setFuncs(L, &.{
        .{ "exec", execFn },
        .{ "notify", notify },
        .{ "log", logFn },
        .{ "theme", theme },
        .{ "keymap", keymap },
        .{ "set", set },
        .{ "layout", layout },
        .{ "icons", icons },
    });
    _ = c.lua_pushstring(L, e.data.ptr);
    c.lua_setfield(L, -2, "data_dir");
    _ = c.lua_pushstring(L, e.dir.ptr);
    c.lua_setfield(L, -2, "dir");
    _ = c.lua_pushstring(L, e.id.ptr);
    c.lua_setfield(L, -2, "id");

    c.lua_createtable(L, 0, 4);
    lua.setFuncs(L, &.{
        .{ "open", actionOpen },
        .{ "copy", actionCopy },
        .{ "paste", actionPaste },
        .{ "exec", actionExec },
    });
    c.lua_setfield(L, -2, "action");

    c.lua_createtable(L, 0, 2);
    lua.setFuncs(L, &.{ .{ "decode", jsonDecode }, .{ "encode", jsonEncode } });
    c.lua_setfield(L, -2, "json");

    _ = c.lua_getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "loaded");
    c.lua_pushvalue(L, -3);
    c.lua_setfield(L, -2, "lumen");
    c.lua_settop(L, -3);
    c.lua_setglobal(L, "lumen");

    c.lua_pushcclosure(L, lua.wrap(logFn), 0);
    c.lua_setglobal(L, "print");

    // The parts written in Lua: lumen.extension, preferences, storage.
    if (c.luaL_loadbufferx(
        L,
        prelude.ptr,
        prelude.len,
        "=lumen",
        "t",
    ) != c.LUA_OK) _ = c.lua_error(L);
    _ = c.lua_getglobal(L, "lumen");
    c.lua_callk(L, 1, 0, 0, null);
}

/// lumen.extension (it notes the preferences' defaults), lumen.preferences
/// and lumen.storage. Both files live in the extension's data folder
/// (lumen.data_dir): storage.json is the extension's, preferences.json is
/// written by Settings. A file that is there but does not read as a JSON
/// object is never written over: that would lose every value in it.
const prelude =
    \\local lumen = ...
    \\-- The object in the file: {} when there is none yet, nil and why when
    \\-- it cannot be read as one.
    \\local function read_json(path)
    \\  local f, err, code = io.open(path, "r")
    \\  if not f then
    \\    if code == 2 then return {} end -- ENOENT
    \\    return nil, err
    \\  end
    \\  local text = f:read("a")
    \\  f:close()
    \\  if text and not text:find("%S") then return {} end
    \\  local ok, value = pcall(lumen.json.decode, text or "")
    \\  if ok and type(value) == "table" then return value end
    \\  return nil, path .. " is not a JSON object"
    \\end
    \\local function write_file(path, text)
    \\  local f, err = io.open(path .. ".tmp", "w")
    \\  if not f then return nil, err end
    \\  local wrote, werr = f:write(text)
    \\  local closed, cerr = f:close()
    \\  if not wrote or not closed then return nil, werr or cerr end
    \\  return os.rename(path .. ".tmp", path)
    \\end
    \\
    \\local defaults = {}
    \\function lumen.extension(spec)
    \\  if type(spec) ~= "table" then error("lumen.extension: a table expected", 2) end
    \\  for _, p in ipairs(type(spec.preferences) == "table" and spec.preferences or {}) do
    \\    if type(p) == "table" and type(p.name) == "string" then
    \\      local d = p.default
    \\      if d == nil and p.type == "toggle" then d = false end
    \\      if d == nil and p.type == "choice" and type(p.choices) == "table" then
    \\        local first = p.choices[1]
    \\        d = type(first) == "table" and first.value or first
    \\      end
    \\      if d == nil then d = "" end
    \\      defaults[p.name] = d
    \\    end
    \\  end
    \\  return spec
    \\end
    \\
    \\local saved
    \\lumen.preferences = setmetatable({}, {
    \\  __index = function(_, name)
    \\    if not saved then
    \\      local values, err = read_json(lumen.data_dir .. "/preferences.json")
    \\      if not values then lumen.log("ignoring " .. err) end
    \\      saved = values or {}
    \\    end
    \\    local v = saved[name]
    \\    if v == nil then v = defaults[name] end
    \\    return v
    \\  end,
    \\  __newindex = function() error("lumen.preferences is read-only: change them in Settings", 2) end,
    \\})
    \\
    \\local storage, data, unreadable = {}, nil, nil
    \\local function load()
    \\  if not data then
    \\    local values, err = read_json(lumen.data_dir .. "/storage.json")
    \\    if not values then lumen.log("ignoring " .. err) unreadable = err end
    \\    data = values or {}
    \\  end
    \\  return data
    \\end
    \\-- Sets the key and writes the file; when either fails, nothing changes.
    \\local function save(key, value)
    \\  local d = load()
    \\  if unreadable then error("lumen.storage: " .. unreadable .. "; not overwritten", 3) end
    \\  local old = d[key]
    \\  d[key] = value
    \\  local encoded, text = pcall(lumen.json.encode, d)
    \\  local done, err = false, text
    \\  if encoded then done, err = write_file(lumen.data_dir .. "/storage.json", text) end
    \\  if not done then
    \\    d[key] = old
    \\    error("lumen.storage: " .. tostring(err), 3)
    \\  end
    \\end
    \\local function check(key)
    \\  if type(key) ~= "string" then error("lumen.storage: keys are strings, not " .. type(key), 3) end
    \\end
    \\function storage.get(key) check(key) return load()[key] end
    \\function storage.set(key, value) check(key) save(key, value) end
    \\function storage.remove(key) check(key) save(key, nil) end
    \\function storage.all()
    \\  local copy = {}
    \\  for k, v in pairs(load()) do copy[k] = v end
    \\  return copy
    \\end
    \\lumen.storage = storage
;

/// The most words a program's argv takes, in `lumen.exec` and in
/// `lumen.action.exec`.
pub const argv_max = 64;

/// lumen.exec's arguments, checked.
const ExecArgs = struct { argc: usize, stdin: []const u8, timeout_ns: u64 };

/// lumen.exec's arguments: the argv list (into `argv`) and the options
/// table. The strings stay on the stack, so they live until lumen.exec
/// returns: reading the options can run Lua code (an `__index`), which may
/// empty the argv table and let the collector free strings still in use.
fn execArgs(L: *lua.State, argv: *[argv_max][]const u8) lua.Error!ExecArgs {
    const n = c.lua_rawlen(L, 1);
    if (n == 0 or n > argv.len) return lua.fail(
        L,
        "lumen.exec: argv needs 1 to {d} strings",
        .{argv.len},
    );
    if (c.lua_checkstack(L, @intCast(n + 4)) == 0) return lua.fail(L, "Lua stack overflow", .{});
    // The options at 2 (nil when not given), the strings from 3 on.
    c.lua_settop(L, 2);
    for (argv[0..n], 1..) |*arg, i| {
        _ = c.lua_rawgeti(L, 1, @intCast(i));
        arg.* = lua.toSlice(L, -1) orelse return lua.fail(
            L,
            "lumen.exec: argv[{d}] is a {s}, not a string",
            .{ i, lua.typeName(L, -1) },
        );
    }
    var stdin: []const u8 = "";
    var timeout_ns: u64 = std.math.maxInt(u64);
    switch (c.lua_type(L, 2)) {
        c.LUA_TNONE, c.LUA_TNIL => {},
        c.LUA_TTABLE => {
            // Left on the stack, like argv's strings.
            if (c.lua_getfield(L, 2, "stdin") != c.LUA_TNIL)
                stdin = lua.toSlice(L, -1) orelse return lua.fail(
                    L,
                    "lumen.exec: stdin must be a string",
                    .{},
                );
            if (c.lua_getfield(L, 2, "timeout") != c.LUA_TNIL) {
                const s = c.lua_tonumberx(L, -1, null);
                if (!(s > 0)) return lua.fail(
                    L,
                    "lumen.exec: timeout must be a positive number of seconds",
                    .{},
                );
                timeout_ns = @intFromFloat(@min(s, 3600) * std.time.ns_per_s);
            }
            c.lua_settop(L, -2);
        },
        else => return lua.fail(
            L,
            "bad argument #2 to 'lumen.exec' (table expected, got {s})",
            .{lua.typeName(L, 2)},
        ),
    }
    return .{ .argc = n, .stdin = stdin, .timeout_ns = timeout_ns };
}

/// `lumen.exec(argv [, { stdin = "", timeout = seconds }])` returns
/// stdout, exit code (nil when killed) and stderr; or nil and a message
/// when it cannot run or times out.
fn execFn(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.exec");
    var argv: [argv_max][]const u8 = undefined;
    const req = try execArgs(L, &argv);
    const n = req.argc;
    const stdin = req.stdin;
    const timeout_ns = req.timeout_ns;

    const e = extOf(L);
    // Never past the deadline of the call that runs it.
    const deadline = @min(e.budget.deadline_ns, os.monotonicNs() +| timeout_ns);
    var r = exec.run(e.gpa(), e.io(), argv[0..n], .{
        .stdin = .{ .bytes = stdin },
        .deadline_ns = deadline,
    }) catch |err| {
        c.lua_pushnil(L);
        lua.pushFmt(L, "lumen.exec: {s}: {s}", .{ argv[0], switch (err) {
            error.FileNotFound => "not found",
            error.AccessDenied => "permission denied",
            else => @errorName(err),
        } });
        return 2;
    };
    // Freed before anything is pushed outside tryCall: a push can raise (the
    // memory cap) and a raise skips defers (lua.zig), leaking the output.
    if (r.timed_out) {
        r.deinit(e.gpa());
        c.lua_pushnil(L);
        lua.pushFmt(L, "lumen.exec: {s} timed out", .{argv[0]});
        return 2;
    }
    const pushed = lua.tryCall(L, exec.Result, &r, pushExec, 0, 3);
    r.deinit(e.gpa());
    if (!pushed) return error.Raise;
    return 3;
}

fn pushExec(L: *lua.State, r: *exec.Result) void {
    lua.pushString(L, r.stdout);
    if (r.code) |code| c.lua_pushinteger(L, code) else c.lua_pushnil(L);
    lua.pushString(L, r.stderr);
}

/// `lumen.notify(title [, body])`: a desktop notification.
fn notify(L: *lua.State) lua.Error!c_int {
    const title = try lua.argString(L, 1, "lumen.notify");
    const body: [:0]const u8 = if (c.lua_type(L, 2) <= 0) "" else try lua.argString(
        L,
        2,
        "lumen.notify",
    );
    proc.spawn(&notifyArgv(title, body));
    return 0;
}

/// notify-send parses options after the summary too: "--" first, so a body
/// like "--help" or "-i x" is text.
fn notifyArgv(title: [:0]const u8, body: [:0]const u8) [6][:0]const u8 {
    return .{ "notify-send", "-a", "Lumen", "--", title, body };
}

/// `lumen.log(...)` and `print(...)`: to Lumen's log, tagged with the
/// extension.
fn logFn(L: *lua.State) lua.Error!c_int {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const n = c.lua_gettop(L);
    var i: c_int = 1;
    while (i <= n) : (i += 1) {
        var len: usize = 0;
        const s = c.luaL_tolstring(L, i, &len);
        if (i > 1) w.writeByte('\t') catch {};
        w.writeAll(s[0..len]) catch {};
        c.lua_settop(L, -2);
    }
    log.info("[{s}] {s}", .{ extOf(L).id, w.buffered() });
    return 0;
}

/// `lumen.theme{ id, name, dark, bg, fg, accent [, surface, ink] }`: a
/// theme for Change Theme. Colours are "#rrggbb". init.lua only.
fn theme(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.theme");
    const e = extOf(L);
    const load = e.load orelse return lua.fail(L, "lumen.theme works only while a file loads", .{});
    const a = load.a;
    const id = lua.fieldString(L, a, 1, "id", "theme") orelse return lua.fail(
        L,
        "theme.id is missing",
        .{},
    );
    if (!Host.validId(id) or std.mem.eql(u8, id, themes.auto_id)) return lua.fail(
        L,
        "theme.id: use a-z, 0-9, - and _ (got \"{s}\")",
        .{id},
    );
    for (themes.all) |t| if (std.mem.eql(u8, t.id, id)) return lua.fail(
        L,
        "theme.id \"{s}\" is a built-in theme",
        .{id},
    );
    for (load.themes.items) |t| if (std.mem.eql(u8, t.id, id)) return lua.fail(
        L,
        "two themes named \"{s}\"",
        .{id},
    );
    const name = lua.fieldString(L, a, 1, "name", "theme") orelse return lua.fail(
        L,
        "theme.name is missing",
        .{},
    );
    const bg = try color(L, a, "bg", null);
    const fg = try color(L, a, "fg", null);
    const t: themes.Theme = .{
        .id = id,
        .name = name,
        .dark = lua.fieldBool(L, 1, "dark", true, "theme"),
        .bg = bg,
        .surface = try color(L, a, "surface", bg),
        .fg = fg,
        .ink = try color(L, a, "ink", fg),
        .accent = try color(L, a, "accent", null),
        .from_style = std.mem.eql(u8, e.id, "style"),
    };
    load.themes.append(a, t) catch return lua.failOom(L);
    return 0;
}

fn color(L: *lua.State, a: std.mem.Allocator, field: [:0]const u8, default: ?u24) lua.Error!u24 {
    const s = lua.fieldString(L, a, 1, field, "theme") orelse {
        if (default) |d| return d;
        return lua.fail(L, "theme.{s} is missing", .{field});
    };
    return parseHex(s) orelse lua.fail(
        L,
        "theme.{s}: \"#rrggbb\" expected (got \"{s}\")",
        .{ field, s },
    );
}

pub fn parseHex(s: []const u8) ?u24 {
    if (s.len != 7 or s[0] != '#') return null;
    return std.fmt.parseInt(u24, s[1..], 16) catch null;
}

/// `lumen.keymap("ctrl+g", "github.prs")`: a key that opens a command (or
/// a built-in view: "clipboard", "files"...) while the window shows.
fn keymap(L: *lua.State) lua.Error!c_int {
    const keys = try lua.argString(L, 1, "lumen.keymap");
    const target = try lua.argString(L, 2, "lumen.keymap");
    const e = extOf(L);
    const load = e.load orelse return lua.fail(
        L,
        "lumen.keymap works only while a file loads",
        .{},
    );
    const parsed = parseKeys(keys) orelse return lua.fail(
        L,
        "lumen.keymap: \"{s}\" is not a key (write it like \"ctrl+g\" or \"alt+shift+F5\")",
        .{keys},
    );
    if (parsed.mods & (gtk.GDK_CONTROL_MASK | gtk.GDK_ALT_MASK | gtk.GDK_SUPER_MASK) == 0)
        return lua.fail(
            L,
            "lumen.keymap: \"{s}\" needs ctrl, alt or super (plain keys type into the search)",
            .{keys},
        );
    const a = load.a;
    load.keymaps.append(a, .{
        .keyval = parsed.keyval,
        .mods = parsed.mods,
        .keys = a.dupeSentinel(u8, keys, 0) catch return lua.failOom(L),
        .target = a.dupeSentinel(u8, target, 0) catch return lua.failOom(L),
        .ext = a.dupeSentinel(u8, e.id, 0) catch return lua.failOom(L),
    }) catch return lua.failOom(L);
    return 0;
}

pub const Keys = struct { keyval: c_uint, mods: gtk.GdkModifierType };

/// "ctrl+shift+g", "alt+F5", "super+space": modifiers, then a key named as
/// GDK names it (letters in either case). Null when it is not a key.
pub fn parseKeys(s: []const u8) ?Keys {
    var mods: gtk.GdkModifierType = 0;
    var it = std.mem.splitScalar(u8, s, '+');
    var key: []const u8 = "";
    while (it.next()) |part| {
        if (it.peek() == null) {
            key = part;
            break;
        }
        const names = [_]struct { []const u8, gtk.GdkModifierType }{
            .{ "ctrl", gtk.GDK_CONTROL_MASK }, .{ "control", gtk.GDK_CONTROL_MASK },
            .{ "alt", gtk.GDK_ALT_MASK },      .{ "shift", gtk.GDK_SHIFT_MASK },
            .{ "super", gtk.GDK_SUPER_MASK },
        };
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(part, n[0])) {
                mods |= n[1];
                break;
            }
        } else return null;
    }
    if (key.len == 0 or key.len > 31) return null;
    var buf: [32:0]u8 = @splat(0);
    @memcpy(buf[0..key.len], key);
    if (key.len == 1) buf[0] = std.ascii.toLower(key[0]);
    const kv = gtk.gdk_keyval_from_name(&buf);
    if (kv == 0 or kv == gtk.GDK_KEY_VoidSymbol) return null;
    return .{ .keyval = gtk.gdk_keyval_to_lower(kv), .mods = mods };
}

/// `lumen.set { width = "wide", density = "compact", suggestions = false }`:
/// settings init.lua fixes (Settings shows them as set here). Keys and
/// values are those of settings.conf.
fn set(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.set");
    const e = extOf(L);
    const load = e.load orelse return lua.fail(L, "lumen.set works only while a file loads", .{});
    const a = load.a;
    c.lua_pushnil(L);
    while (c.lua_next(L, 1) != 0) {
        const key = lua.toSlice(L, -2) orelse return lua.fail(
            L,
            "lumen.set: keys are setting names, not {s}",
            .{lua.typeName(L, -2)},
        );
        var buf: [64]u8 = undefined;
        const value: []const u8 = switch (c.lua_type(L, -1)) {
            c.LUA_TBOOLEAN => if (c.lua_toboolean(L, -1) != 0) "true" else "false",
            c.LUA_TSTRING => lua.toSlice(L, -1).?,
            c.LUA_TNUMBER => std.mem.print(&buf, "{d}", .{c.lua_tointegerx(L, -1, null)}) catch "",
            else => return lua.fail(
                L,
                "lumen.set: {s} cannot be a {s}",
                .{ key, lua.typeName(L, -1) },
            ),
        };
        switch (Settings.check(key, value)) {
            .ok => {},
            .unknown_key => return lua.fail(L, "lumen.set: no setting named \"{s}\"", .{key}),
            .bad_value => return lua.fail(
                L,
                "lumen.set: \"{s}\" is not a value for {s}",
                .{ value, key },
            ),
        }
        // A style's settings are defaults for when it is chosen; init.lua's fix them.
        const list = if (std.mem.eql(u8, e.id, "style")) &load.style_settings else &load.settings;
        list.append(a, .{
            .key = a.dupeSentinel(u8, key, 0) catch return lua.failOom(L),
            .value = a.dupeSentinel(u8, value, 0) catch return lua.failOom(L),
        }) catch return lua.failOom(L);
        c.lua_settop(L, -2);
    }
    return 0;
}

/// `lumen.layout { width = 820, panels = "single", footer = true, show = {
/// hints = false } }`: the window's structure. Several calls add up.
fn layout(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.layout");
    const e = extOf(L);
    const load = e.load orelse return lua.fail(
        L,
        "lumen.layout works only while a file loads",
        .{},
    );
    var l = load.layout;
    c.lua_pushnil(L);
    while (c.lua_next(L, 1) != 0) {
        const key = lua.toSlice(L, -2) orelse return lua.fail(
            L,
            "lumen.layout: keys are names ({s})",
            .{layout_mod.keys},
        );
        if (std.mem.eql(u8, key, "searchbar") or std.mem.eql(u8, key, "row")) {
            try layoutParts(L, &l, key);
        } else if (std.mem.eql(u8, key, "prompt") or std.mem.eql(u8, key, "placeholder")) {
            const p = lua.toSlice(L, -1) orelse return lua.fail(
                L,
                "lumen.layout: {s} is a string",
                .{key},
            );
            const text = load.a.dupeSentinel(
                u8,
                p[0..@min(p.len, 64)],
                0,
            ) catch return lua.failOom(L);
            if (key[1] == 'r') l.prompt = text else l.placeholder = text;
        } else if (std.mem.eql(u8, key, "show")) {
            try layoutShow(L, &l);
        } else {
            try layoutValue(L, &l, key);
        }
        c.lua_settop(L, -2);
    }
    load.layout = l;
    load.has_layout = true;
    return 0;
}

/// `searchbar` or `row` (on top of the stack): the parts in order.
fn layoutParts(L: *lua.State, l: *layout_mod.Layout, key: []const u8) lua.Error!void {
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return lua.fail(
        L,
        "lumen.layout: {s} is a list of part names",
        .{key},
    );
    // The longer of the two orders: a part may appear at most once.
    var names: [@typeInfo(layout_mod.BarPart).@"enum".field_names.len][]const u8 = undefined;
    comptime std.debug.assert(names.len >= @typeInfo(layout_mod.RowPart).@"enum".field_names.len);
    const n = c.lua_rawlen(L, -1);
    if (n == 0 or n > names.len) {
        return lua.fail(L, "lumen.layout: {s} lists 1 to {d} parts", .{ key, names.len });
    }
    for (names[0..n], 1..) |*name, i| {
        _ = c.lua_rawgeti(L, -1, @intCast(i));
        name.* = lua.toSlice(L, -1) orelse return lua.fail(
            L,
            "lumen.layout: {s}[{d}] is a part name",
            .{ key, i },
        );
        c.lua_settop(L, -2);
    }
    const is_bar = key[0] == 's';
    const ok = if (is_bar)
        layout_mod.setParts(layout_mod.BarPart, &l.searchbar, names[0..n], .entry)
    else
        layout_mod.setParts(layout_mod.RowPart, &l.row, names[0..n], .text);
    ok catch return lua.fail(L, "lumen.layout: {s} takes each of {s} at most once, {s} included", .{
        key,
        if (is_bar) "back, icon, prompt, scope, entry, keys" else "icon, text, accessory, hint",
        if (is_bar) "entry" else "text",
    });
}

/// `show` (on top of the stack): which parts of the window show.
fn layoutShow(L: *lua.State, l: *layout_mod.Layout) lua.Error!void {
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return lua.fail(
        L,
        "lumen.layout: show is a table of true/false",
        .{},
    );
    const show = lua.absIndex(L, -1);
    c.lua_pushnil(L);
    while (c.lua_next(L, show) != 0) {
        const sk = lua.toSlice(L, -2) orelse return lua.fail(
            L,
            "lumen.layout: show's keys are {s}",
            .{layout_mod.show_keys},
        );
        if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return lua.fail(
            L,
            "lumen.layout: show.{s} is true or false",
            .{sk},
        );
        layout_mod.setShow(&l.show, sk, c.lua_toboolean(L, -1) != 0) catch return lua.fail(
            L,
            "lumen.layout: show has no \"{s}\" (it has {s})",
            .{ sk, layout_mod.show_keys },
        );
        c.lua_settop(L, -2);
    }
}

/// Any other key: a number, string or boolean setting.
fn layoutValue(L: *lua.State, l: *layout_mod.Layout, key: []const u8) lua.Error!void {
    const value: layout_mod.Value = switch (c.lua_type(L, -1)) {
        c.LUA_TNUMBER => .{ .number = c.lua_tonumberx(L, -1, null) },
        c.LUA_TSTRING => .{ .string = lua.toSlice(L, -1).? },
        c.LUA_TBOOLEAN => .{ .boolean = c.lua_toboolean(L, -1) != 0 },
        else => .{},
    };
    layout_mod.set(l, key, value) catch |err| return switch (err) {
        error.UnknownKey => lua.fail(
            L,
            "lumen.layout: no \"{s}\" (it has {s})",
            .{ key, layout_mod.keys },
        ),
        error.BadValue => lua.fail(
            L,
            "lumen.layout: bad value for {s} (see EXTENSIONS.md)",
            .{key},
        ),
    };
}

/// `lumen.icons { ["app:firefox"] = "~/icons/fox.svg", ["cmd:clipboard"] =
/// "📋", ["file:pdf"] = { name = "x-office-document-symbolic", color = "red" } }`:
/// icons of apps, commands and file kinds replaced. Several calls add up.
fn icons(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.icons");
    const e = extOf(L);
    const load = e.load orelse return lua.fail(L, "lumen.icons works only while a file loads", .{});
    const a = load.a;
    c.lua_pushnil(L);
    while (c.lua_next(L, 1) != 0) {
        const key = lua.toSlice(L, -2) orelse return lua.fail(
            L,
            "lumen.icons: keys are item keys like \"app:firefox\" or \"cmd:clipboard\"",
            .{},
        );
        if (std.mem.findScalar(u8, key, ':') == null)
            return lua.fail(
                L,
                "lumen.icons: \"{s}\" is not a key (app:, cmd:, sys:, win:, script:, ext:, file:)",
                .{key},
            );
        const icon = Host.parseIcon(L, a, -1, "lumen.icons") orelse return lua.fail(
            L,
            "lumen.icons: no icon for {s}",
            .{key},
        );
        // "app:firefox" means firefox.desktop.
        const full = if (std.mem.startsWith(u8, key, "app:") and !std.mem.endsWith(
            u8,
            key,
            ".desktop",
        ))
            a.printSentinel("{s}.desktop", .{key}, 0)
        else
            a.dupeSentinel(u8, key, 0);
        load.icons.append(a, .{
            .key = full catch return lua.failOom(L),
            .icon = icon,
        }) catch
            return lua.failOom(L);
        c.lua_settop(L, -2);
    }
    return 0;
}

// lumen.action.*: tables a row's `actions` list takes.

fn actionOf(
    L: *lua.State,
    kind: [:0]const u8,
    field: [:0]const u8,
    func: []const u8,
) lua.Error!c_int {
    if (std.mem.eql(
        u8,
        field,
        "argv",
    )) try lua.argTable(L, 1, func) else _ = try lua.argString(L, 1, func);
    const has_title = c.lua_type(L, 2) > 0;
    if (has_title) _ = try lua.argString(L, 2, func);
    c.lua_createtable(L, 0, 3);
    _ = c.lua_pushstring(L, kind.ptr);
    c.lua_setfield(L, -2, "kind");
    c.lua_pushvalue(L, 1);
    c.lua_setfield(L, -2, field.ptr);
    if (has_title) {
        c.lua_pushvalue(L, 2);
        c.lua_setfield(L, -2, "title");
    }
    return 1;
}

fn actionOpen(L: *lua.State) lua.Error!c_int {
    return actionOf(L, "open", "target", "lumen.action.open");
}
fn actionCopy(L: *lua.State) lua.Error!c_int {
    return actionOf(L, "copy", "text", "lumen.action.copy");
}
fn actionPaste(L: *lua.State) lua.Error!c_int {
    return actionOf(L, "paste", "text", "lumen.action.paste");
}
fn actionExec(L: *lua.State) lua.Error!c_int {
    return actionOf(L, "exec", "argv", "lumen.action.exec");
}

fn jsonDecode(L: *lua.State) lua.Error!c_int {
    const text = try lua.argString(L, 1, "lumen.json.decode");
    try json.decode(L, extOf(L).gpa(), text);
    return 1;
}

fn jsonEncode(L: *lua.State) lua.Error!c_int {
    if (c.lua_type(L, 1) == c.LUA_TNONE) return lua.fail(
        L,
        "bad argument #1 to 'lumen.json.encode' (value expected)",
        .{},
    );
    try json.encode(L, extOf(L).gpa(), 1);
    return 1;
}

test "keys parse like ctrl+g" {
    const g = parseKeys("ctrl+g").?;
    try std.testing.expectEqual(gtk.GDK_CONTROL_MASK, g.mods);
    try std.testing.expectEqual(@as(c_uint, 'g'), g.keyval);
    try std.testing.expectEqual(parseKeys("Ctrl+Shift+G").?.keyval, g.keyval);
    try std.testing.expectEqual(
        gtk.GDK_CONTROL_MASK | gtk.GDK_SHIFT_MASK,
        parseKeys("ctrl+shift+g").?.mods,
    );
    try std.testing.expectEqual(gtk.GDK_KEY_Return, parseKeys("alt+Return").?.keyval);
    try std.testing.expect(parseKeys("hyper+g") == null);
    try std.testing.expect(parseKeys("ctrl+nosuchkey") == null);
    try std.testing.expect(parseKeys("ctrl+") == null);
}

test "a notification's text is never read as options" {
    const argv = notifyArgv("-u critical", "--help");
    try std.testing.expectEqualStrings("--", argv[3]);
    try std.testing.expectEqualStrings("-u critical", argv[4]);
    try std.testing.expectEqualStrings("--help", argv[5]);
}

test "theme colours parse as #rrggbb" {
    try std.testing.expectEqual(@as(?u24, 0x1e1e2e), parseHex("#1e1e2e"));
    try std.testing.expectEqual(@as(?u24, 0xFFAA00), parseHex("#FFAA00"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("1e1e2e"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("#12345"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("#zzzzzz"));
}
