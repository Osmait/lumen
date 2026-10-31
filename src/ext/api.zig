//! The `lumen` module extensions see (`local lumen = require("lumen")`).
//! EXTENSIONS.md documents it; keep the two in step.
//!
//! `lua.c` is Lua's C API; `gtk` is GTK and GLib (what other files call
//! `c`).

const std = @import("std");
const lua = @import("luart").lua;
const Host = @import("Host.zig");
const rows = @import("rows.zig");
const json = @import("luart").json;
const proc = @import("../sys/proc.zig");
const themes = @import("../ui/themes.zig");
const os = @import("os");
const child = os.child;
const gtk = @import("c");
const Settings = @import("../settings.zig").Settings;
const layout_mod = @import("../layout.zig");

const log = std.log.scoped(.ext);
const assert = std.debug.assert;

/// The most words a program's argv takes, in `lumen.exec` and in
/// `lumen.action.exec`.
pub const argv_max = 64;
/// The longest `timeout` lumen.exec takes; a longer one is cut to it.
const exec_timeout_s_max = 3600;
/// A theme colour as written in Lua: "#" and six hex digits.
const color_hex_example = "#rrggbb";
/// A layout's prompt or placeholder: a few words in the search bar.
const layout_text_bytes_max = 64;
/// The longest key name GDK knows is shorter.
const key_name_bytes_max = 31;
/// One `print` or `lumen.log` line; longer output is cut, as a log line is
/// not a dump.
const log_line_bytes_max = 2048;

/// The extension whose state `L` is: its budget is the state's allocator
/// data, and a field of the extension.
fn extensionOf(L: *lua.State) *Host.Extension {
    return @fieldParentPtr("budget", lua.budgetOf(L));
}

/// The file being loaded, or an error for a function only a file being
/// loaded may call (`function_name` names it).
fn loadOf(L: *lua.State, function_name: []const u8) lua.Error!*Host.Load {
    const format = "{s} works only while a file loads";
    return extensionOf(L).load orelse lua.fail(L, format, .{function_name});
}

/// Sets up `lumen` (also a global), `require` for the extension's own
/// modules, and `print` (to Lumen's log). Inside `protect`; leaves the
/// stack as it found it.
pub fn install(L: *lua.State, extension: *Host.Extension) void {
    const mark: lua.StackMark = .init(L);
    defer mark.expectPushed(L, 0);
    setRequirePath(L, extension.folder);

    lua.c.lua_createtable(L, 0, 16);
    const lumen = lua.absIndex(L, -1);
    lua.setFuncs(L, &.{
        .{ "exec", lumenExec },
        .{ "notify", notify },
        .{ "log", lumenLog },
        .{ "theme", theme },
        .{ "keymap", keymap },
        .{ "set", set },
        .{ "layout", layout },
        .{ "icons", icons },
    });
    setStringField(L, lumen, "data_dir", extension.data);
    setStringField(L, lumen, "dir", extension.folder);
    setStringField(L, lumen, "id", extension.id);

    lua.c.lua_createtable(L, 0, 4);
    lua.setFuncs(L, &.{
        .{ "open", actionOpen },
        .{ "copy", actionCopy },
        .{ "paste", actionPaste },
        .{ "exec", actionExec },
    });
    lua.c.lua_setfield(L, lumen, "action");

    lua.c.lua_createtable(L, 0, 2);
    lua.setFuncs(L, &.{ .{ "decode", jsonDecode }, .{ "encode", jsonEncode } });
    lua.c.lua_setfield(L, lumen, "json");

    // require("lumen") finds the same table as the global.
    _ = lua.c.lua_getglobal(L, "package");
    _ = lua.c.lua_getfield(L, -1, "loaded");
    lua.c.lua_pushvalue(L, lumen);
    lua.c.lua_setfield(L, -2, "lumen");
    lua.c.lua_settop(L, lumen);
    lua.c.lua_setglobal(L, "lumen");

    lua.c.lua_pushcclosure(L, lua.wrap(lumenLog), 0);
    lua.c.lua_setglobal(L, "print");

    runPrelude(L);
}

/// require("x") finds x.lua and x/init.lua in the extension's folder.
fn setRequirePath(L: *lua.State, folder: [:0]const u8) void {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    _ = lua.c.lua_getglobal(L, "package");
    // A folder path twice, and the pattern around it.
    var path_buffer: [2 * std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    const path = std.mem.printSentinel(
        &path_buffer,
        "{s}/?.lua;{s}/?/init.lua",
        .{ folder, folder },
        0,
    ) catch lua.raise(L, "extension path too long", .{});
    _ = lua.c.lua_pushstring(L, path.ptr);
    lua.c.lua_setfield(L, -2, "path");
}

fn setStringField(L: *lua.State, table: c_int, name: [:0]const u8, value: [:0]const u8) void {
    _ = lua.c.lua_pushstring(L, value.ptr);
    lua.c.lua_setfield(L, table, name.ptr);
}

/// Runs `prelude` with the `lumen` table as its argument.
fn runPrelude(L: *lua.State) void {
    const loaded = lua.c.luaL_loadbufferx(L, prelude.ptr, prelude.len, "=lumen", "t");
    if (loaded != lua.c.LUA_OK) _ = lua.c.lua_error(L);
    _ = lua.c.lua_getglobal(L, "lumen");
    lua.c.lua_callk(L, 1, 0, 0, null);
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

/// lumen.exec's arguments, checked.
const ExecArguments = struct { words_count: usize, stdin: []const u8, timeout_ns: u64 };

/// lumen.exec's arguments: the argv list (into `argv`) and the options
/// table. The strings stay on the stack, so they live until lumen.exec
/// returns: reading the options can run Lua code (an `__index`), which may
/// empty the argv table and let the collector free strings still in use.
fn execArguments(L: *lua.State, argv: *[argv_max][]const u8) lua.Error!ExecArguments {
    const words_count = lua.c.lua_rawlen(L, 1);
    if (words_count == 0 or words_count > argv.len) {
        return lua.fail(L, "lumen.exec: argv needs 1 to {d} strings", .{argv.len});
    }
    if (lua.c.lua_checkstack(L, @intCast(words_count + 4)) == 0) {
        return lua.fail(L, "Lua stack overflow", .{});
    }
    // The options at 2 (nil when not given), the strings from 3 on.
    lua.c.lua_settop(L, 2);
    for (argv[0..words_count], 1..) |*word, word_number| {
        _ = lua.c.lua_rawgeti(L, 1, @intCast(word_number));
        word.* = lua.toSlice(L, -1) orelse {
            const type_name = lua.typeName(L, -1);
            return lua.fail(
                L,
                "lumen.exec: argv[{d}] is a {s}, not a string",
                .{ word_number, type_name },
            );
        };
    }
    var stdin: []const u8 = "";
    var timeout_ns: u64 = std.math.maxInt(u64);
    switch (lua.c.lua_type(L, 2)) {
        lua.c.LUA_TNONE, lua.c.LUA_TNIL => {},
        lua.c.LUA_TTABLE => {
            // Left on the stack, like argv's strings.
            if (lua.c.lua_getfield(L, 2, "stdin") != lua.c.LUA_TNIL) {
                stdin = lua.toSlice(L, -1) orelse
                    return lua.fail(L, "lumen.exec: stdin must be a string", .{});
            }
            if (lua.c.lua_getfield(L, 2, "timeout") != lua.c.LUA_TNIL) {
                const timeout_s = lua.c.lua_tonumberx(L, -1, null);
                // Written so that NaN is refused too (lua.inRange).
                if (!(timeout_s > 0)) {
                    return lua.fail(
                        L,
                        "lumen.exec: timeout must be a positive number of seconds",
                        .{},
                    );
                }
                timeout_ns = @intFromFloat(@min(timeout_s, exec_timeout_s_max) * std.time.ns_per_s);
            }
            lua.pop(L, 1);
        },
        else => return lua.fail(
            L,
            "bad argument #2 to 'lumen.exec' (table expected, got {s})",
            .{lua.typeName(L, 2)},
        ),
    }
    return .{ .words_count = words_count, .stdin = stdin, .timeout_ns = timeout_ns };
}

/// `lumen.exec(argv [, { stdin = "", timeout = seconds }])` returns
/// stdout, exit code (nil when killed) and stderr; or nil and a message
/// when it cannot run or times out.
fn lumenExec(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.exec");
    var argv: [argv_max][]const u8 = undefined;
    const arguments = try execArguments(L, &argv);

    const extension = extensionOf(L);
    // Never past the deadline of the call that runs it.
    const timeout_end_ns = os.monotonicNs() +| arguments.timeout_ns;
    const deadline_ns = @min(extension.budget.deadline_ns, timeout_end_ns);
    var result = child.run(extension.gpa(), extension.io(), argv[0..arguments.words_count], .{
        .stdin = .{ .bytes = arguments.stdin },
        .deadline_ns = deadline_ns,
    }) catch |err| {
        const why = switch (err) {
            error.FileNotFound => "not found",
            error.AccessDenied => "permission denied",
            else => @errorName(err),
        };
        lua.c.lua_pushnil(L);
        lua.pushFmt(L, "lumen.exec: {s}: {s}", .{ argv[0], why });
        return 2;
    };
    // Freed before anything is pushed outside tryCall: a push can raise (the
    // memory cap) and a raise skips defers (lua.zig), leaking the output.
    if (result.timed_out) {
        result.deinit(extension.gpa());
        lua.c.lua_pushnil(L);
        lua.pushFmt(L, "lumen.exec: {s} timed out", .{argv[0]});
        return 2;
    }
    const pushed = lua.tryCall(L, child.Result, &result, pushExec, 0, 3);
    result.deinit(extension.gpa());
    if (!pushed) return error.Raise;
    return 3;
}

fn pushExec(L: *lua.State, result: *child.Result) void {
    lua.pushString(L, result.stdout);
    if (result.code) |code| lua.c.lua_pushinteger(L, code) else lua.c.lua_pushnil(L);
    lua.pushString(L, result.stderr);
}

/// `lumen.notify(title [, body])`: a desktop notification.
fn notify(L: *lua.State) lua.Error!c_int {
    const title = try lua.argString(L, 1, "lumen.notify");
    const body: [:0]const u8 = if (lua.isNoneOrNil(L, 2))
        ""
    else
        try lua.argString(L, 2, "lumen.notify");
    proc.spawn(&notifyArgv(title, body));
    return 0;
}

/// notify-send parses options after the summary too: "--" first, so a body
/// like "--help" or "-i x" is text.
fn notifyArgv(title: [:0]const u8, body: [:0]const u8) [6][:0]const u8 {
    return .{ "notify-send", "-a", "Lumen", "--", title, body };
}

/// `lumen.log(...)` and `print(...)`: to Lumen's log, tagged with the
/// extension. A line longer than `log_line_bytes_max` is cut.
fn lumenLog(L: *lua.State) lua.Error!c_int {
    var line_buffer: [log_line_bytes_max]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buffer);
    const arguments_count = lua.c.lua_gettop(L);
    var argument: c_int = 1;
    while (argument <= arguments_count) : (argument += 1) {
        var length: usize = 0;
        const text = lua.c.luaL_tolstring(L, argument, &length);
        if (argument > 1) writeCut(&line, "\t");
        writeCut(&line, text[0..length]);
        lua.pop(L, 1);
    }
    log.info("[{s}] {s}", .{ extensionOf(L).id, line.buffered() });
    return 0;
}

/// Writes as much of `bytes` as `line` has room for: a log line too long
/// is cut, as `log_line_bytes_max` says, not dropped.
fn writeCut(line: *std.Io.Writer, bytes: []const u8) void {
    const fitting = bytes[0..@min(bytes.len, line.unusedCapacityLen())];
    // A fixed writer with room for every byte cannot fail.
    line.writeAll(fitting) catch unreachable;
}

/// `lumen.theme{ id, name, dark, bg, fg, accent [, surface, ink] }`: a
/// theme for Change Theme. Colours are "#rrggbb". init.lua only.
fn theme(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.theme");
    const extension = extensionOf(L);
    const load = try loadOf(L, "lumen.theme");
    const arena = load.arena;
    const id = lua.fieldString(L, arena, 1, "id", "theme") orelse
        return lua.fail(L, "theme.id is missing", .{});
    if (!Host.validId(id) or std.mem.eql(u8, id, themes.auto_id)) {
        return lua.fail(L, "theme.id: use a-z, 0-9, - and _ (got \"{s}\")", .{id});
    }
    for (themes.all) |built_in| {
        if (std.mem.eql(u8, built_in.id, id)) {
            return lua.fail(L, "theme.id \"{s}\" is a built-in theme", .{id});
        }
    }
    for (load.themes.items) |declared| {
        if (std.mem.eql(u8, declared.id, id)) {
            return lua.fail(L, "two themes named \"{s}\"", .{id});
        }
    }
    const name = lua.fieldString(L, arena, 1, "name", "theme") orelse
        return lua.fail(L, "theme.name is missing", .{});
    const background = try color(L, arena, "bg", null);
    const foreground = try color(L, arena, "fg", null);
    const new_theme: themes.Theme = .{
        .id = id,
        .name = name,
        .dark = lua.fieldBool(L, 1, "dark", true, "theme"),
        .bg = background,
        .surface = try color(L, arena, "surface", background),
        .fg = foreground,
        .ink = try color(L, arena, "ink", foreground),
        .accent = try color(L, arena, "accent", null),
        .from_style = std.mem.eql(u8, extension.id, Host.style_extension_id),
    };
    load.themes.append(arena, new_theme) catch return lua.failOom(L);
    return 0;
}

/// The theme's colour `field` (argument 1), or `default` when it has none.
fn color(
    L: *lua.State,
    arena: std.mem.Allocator,
    field: [:0]const u8,
    default: ?u24,
) lua.Error!u24 {
    const text = lua.fieldString(L, arena, 1, field, "theme") orelse {
        if (default) |default_color| return default_color;
        return lua.fail(L, "theme.{s} is missing", .{field});
    };
    return parseHex(text) orelse
        lua.fail(L, "theme.{s}: \"#rrggbb\" expected (got \"{s}\")", .{ field, text });
}

pub fn parseHex(text: []const u8) ?u24 {
    if (text.len != color_hex_example.len or text[0] != '#') return null;
    return std.fmt.parseInt(u24, text[1..], 16) catch null;
}

/// `lumen.keymap("ctrl+g", "github.prs")`: a key that opens a command (or
/// a built-in view: "clipboard", "files"...) while the window shows.
fn keymap(L: *lua.State) lua.Error!c_int {
    const keys = try lua.argString(L, 1, "lumen.keymap");
    const target = try lua.argString(L, 2, "lumen.keymap");
    const extension = extensionOf(L);
    const load = try loadOf(L, "lumen.keymap");
    const parsed = parseKeys(keys) orelse return lua.fail(
        L,
        "lumen.keymap: \"{s}\" is not a key (write it like \"ctrl+g\" or \"alt+shift+F5\")",
        .{keys},
    );
    const modifiers_required = gtk.GDK_CONTROL_MASK | gtk.GDK_ALT_MASK | gtk.GDK_SUPER_MASK;
    if (parsed.mods & modifiers_required == 0) {
        return lua.fail(
            L,
            "lumen.keymap: \"{s}\" needs ctrl, alt or super (plain keys type into the search)",
            .{keys},
        );
    }
    const arena = load.arena;
    load.keymaps.append(arena, .{
        .keyval = parsed.keyval,
        .mods = parsed.mods,
        .keys = arena.dupeSentinel(u8, keys, 0) catch return lua.failOom(L),
        .target = arena.dupeSentinel(u8, target, 0) catch return lua.failOom(L),
        .ext = arena.dupeSentinel(u8, extension.id, 0) catch return lua.failOom(L),
    }) catch return lua.failOom(L);
    return 0;
}

pub const Keys = struct { keyval: c_uint, mods: gtk.GdkModifierType };

const Modifier = struct { name: []const u8, mask: gtk.GdkModifierType };

const modifiers = [_]Modifier{
    .{ .name = "ctrl", .mask = gtk.GDK_CONTROL_MASK },
    .{ .name = "control", .mask = gtk.GDK_CONTROL_MASK },
    .{ .name = "alt", .mask = gtk.GDK_ALT_MASK },
    .{ .name = "shift", .mask = gtk.GDK_SHIFT_MASK },
    .{ .name = "super", .mask = gtk.GDK_SUPER_MASK },
};

/// "ctrl+shift+g", "alt+F5", "super+space": modifiers, then a key named as
/// GDK names it (letters in either case). Null when it is not a key.
pub fn parseKeys(text: []const u8) ?Keys {
    var modifiers_mask: gtk.GdkModifierType = 0;
    var parts = std.mem.splitScalar(u8, text, '+');
    var key_name: []const u8 = "";
    while (parts.next()) |part| {
        if (parts.peek() == null) {
            key_name = part;
            break;
        }
        modifiers_mask |= modifierMask(part) orelse return null;
    }
    if (key_name.len == 0 or key_name.len > key_name_bytes_max) return null;
    var name_terminated: [key_name_bytes_max + 1:0]u8 = @splat(0);
    @memcpy(name_terminated[0..key_name.len], key_name);
    if (key_name.len == 1) name_terminated[0] = std.ascii.toLower(key_name[0]);
    const keyval = gtk.gdk_keyval_from_name(&name_terminated);
    if (keyval == 0 or keyval == gtk.GDK_KEY_VoidSymbol) return null;
    return .{ .keyval = gtk.gdk_keyval_to_lower(keyval), .mods = modifiers_mask };
}

fn modifierMask(name: []const u8) ?gtk.GdkModifierType {
    for (modifiers) |modifier| {
        if (std.ascii.eqlIgnoreCase(name, modifier.name)) return modifier.mask;
    }
    return null;
}

/// `lumen.set { width = "wide", density = "compact", suggestions = false }`:
/// settings init.lua fixes (Settings shows them as set here). Keys and
/// values are those of settings.conf.
fn set(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.set");
    const extension = extensionOf(L);
    const load = try loadOf(L, "lumen.set");
    const arena = load.arena;
    // A style's settings are defaults for when it is chosen; init.lua's fix them.
    const settings = if (std.mem.eql(u8, extension.id, Host.style_extension_id))
        &load.style_settings
    else
        &load.settings;
    lua.c.lua_pushnil(L);
    while (lua.c.lua_next(L, 1) != 0) {
        const key = lua.toSlice(L, -2) orelse {
            const type_name = lua.typeName(L, -2);
            return lua.fail(L, "lumen.set: keys are setting names, not {s}", .{type_name});
        };
        var number_buffer: [64]u8 = undefined;
        const value: []const u8 = switch (lua.c.lua_type(L, -1)) {
            lua.c.LUA_TBOOLEAN => Host.toggleText(lua.c.lua_toboolean(L, -1) != 0),
            lua.c.LUA_TSTRING => lua.toSlice(L, -1).?,
            lua.c.LUA_TNUMBER => blk: {
                const integer = lua.c.lua_tointegerx(L, -1, null);
                // 64 bytes hold any integer.
                break :blk std.mem.print(&number_buffer, "{d}", .{integer}) catch unreachable;
            },
            else => {
                const type_name = lua.typeName(L, -1);
                return lua.fail(L, "lumen.set: {s} cannot be a {s}", .{ key, type_name });
            },
        };
        switch (Settings.check(key, value)) {
            .ok => {},
            .unknown_key => return lua.fail(L, "lumen.set: no setting named \"{s}\"", .{key}),
            .bad_value => {
                return lua.fail(L, "lumen.set: \"{s}\" is not a value for {s}", .{ value, key });
            },
        }
        settings.append(arena, .{
            .key = arena.dupeSentinel(u8, key, 0) catch return lua.failOom(L),
            .value = arena.dupeSentinel(u8, value, 0) catch return lua.failOom(L),
        }) catch return lua.failOom(L);
        // Pops the value; `lua_next` takes the key off next.
        lua.pop(L, 1);
    }
    return 0;
}

/// The keys of `lumen.layout` that this file reads itself; layout.set
/// takes the others.
const LayoutKey = enum { searchbar, row, prompt, placeholder, show };

/// `lumen.layout { width = 820, panels = "single", footer = true, show = {
/// hints = false } }`: the window's structure. Several calls add up.
fn layout(L: *lua.State) lua.Error!c_int {
    try lua.argTable(L, 1, "lumen.layout");
    const load = try loadOf(L, "lumen.layout");
    var layout_new = load.layout;
    lua.c.lua_pushnil(L);
    while (lua.c.lua_next(L, 1) != 0) {
        const key = lua.toSlice(L, -2) orelse
            return lua.fail(L, "lumen.layout: keys are names ({s})", .{layout_mod.keys});
        if (std.meta.stringToEnum(LayoutKey, key)) |layout_key| switch (layout_key) {
            .searchbar => try layoutParts(L, layout_mod.BarPart, &layout_new.searchbar, key),
            .row => try layoutParts(L, layout_mod.RowPart, &layout_new.row, key),
            .prompt => layout_new.prompt = try layoutText(L, load.arena, key),
            .placeholder => layout_new.placeholder = try layoutText(L, load.arena, key),
            .show => try layoutShow(L, &layout_new.show),
        } else {
            try layoutValue(L, &layout_new, key);
        }
        // Pops the value; `lua_next` takes the key off next.
        lua.pop(L, 1);
    }
    load.layout = layout_new;
    load.has_layout = true;
    return 0;
}

/// `prompt` or `placeholder` (on top of the stack), cut to
/// `layout_text_bytes_max`.
fn layoutText(L: *lua.State, arena: std.mem.Allocator, key: []const u8) lua.Error![:0]const u8 {
    const text = lua.toSlice(L, -1) orelse
        return lua.fail(L, "lumen.layout: {s} is a string", .{key});
    return arena.dupeSentinel(u8, lua.cut(text, layout_text_bytes_max), 0) catch
        lua.failOom(L);
}

/// `searchbar` or `row` (on top of the stack): the parts in order, each at
/// most once.
fn layoutParts(
    L: *lua.State,
    comptime Part: type,
    parts: *layout_mod.Parts(Part),
    key: []const u8,
) lua.Error!void {
    if (lua.c.lua_type(L, -1) != lua.c.LUA_TTABLE) {
        return lua.fail(L, "lumen.layout: {s} is a list of part names", .{key});
    }
    const part_names = @typeInfo(Part).@"enum".field_names;
    var names: [part_names.len][]const u8 = undefined;
    const names_count = lua.c.lua_rawlen(L, -1);
    if (names_count == 0 or names_count > names.len) {
        return lua.fail(L, "lumen.layout: {s} lists 1 to {d} parts", .{ key, names.len });
    }
    for (names[0..names_count], 1..) |*name, name_number| {
        _ = lua.c.lua_rawgeti(L, -1, @intCast(name_number));
        name.* = lua.toSlice(L, -1) orelse
            return lua.fail(L, "lumen.layout: {s}[{d}] is a part name", .{ key, name_number });
        lua.pop(L, 1);
    }
    const required: Part = if (Part == layout_mod.BarPart) .entry else .text;
    layout_mod.setParts(Part, parts, names[0..names_count], required) catch {
        const all = comptime partNames(Part);
        return lua.fail(
            L,
            "lumen.layout: {s} takes each of {s} at most once, {s} included",
            .{ key, all, @tagName(required) },
        );
    };
}

/// "back, icon, prompt": the names of a kind of part, for messages.
fn partNames(comptime Part: type) []const u8 {
    var all: []const u8 = "";
    for (@typeInfo(Part).@"enum".field_names, 0..) |name, index| {
        all = all ++ (if (index > 0) ", " else "") ++ name;
    }
    return all;
}

/// `show` (on top of the stack): which parts of the window show.
fn layoutShow(L: *lua.State, show: *layout_mod.Show) lua.Error!void {
    if (lua.c.lua_type(L, -1) != lua.c.LUA_TTABLE) {
        return lua.fail(L, "lumen.layout: show is a table of true/false", .{});
    }
    const show_table = lua.absIndex(L, -1);
    lua.c.lua_pushnil(L);
    while (lua.c.lua_next(L, show_table) != 0) {
        const show_key = lua.toSlice(L, -2) orelse
            return lua.fail(L, "lumen.layout: show's keys are {s}", .{layout_mod.show_keys});
        if (lua.c.lua_type(L, -1) != lua.c.LUA_TBOOLEAN) {
            return lua.fail(L, "lumen.layout: show.{s} is true or false", .{show_key});
        }
        const shown = lua.c.lua_toboolean(L, -1) != 0;
        layout_mod.setShow(show, show_key, shown) catch return lua.fail(
            L,
            "lumen.layout: show has no \"{s}\" (it has {s})",
            .{ show_key, layout_mod.show_keys },
        );
        // Pops the value; `lua_next` takes the key off next.
        lua.pop(L, 1);
    }
}

/// Any other key: a number, string or boolean setting.
fn layoutValue(L: *lua.State, layout_new: *layout_mod.Layout, key: []const u8) lua.Error!void {
    const value: layout_mod.Value = switch (lua.c.lua_type(L, -1)) {
        lua.c.LUA_TNUMBER => .{ .number = lua.c.lua_tonumberx(L, -1, null) },
        lua.c.LUA_TSTRING => .{ .string = lua.toSlice(L, -1).? },
        lua.c.LUA_TBOOLEAN => .{ .boolean = lua.c.lua_toboolean(L, -1) != 0 },
        else => .{},
    };
    layout_mod.set(layout_new, key, value) catch |err| return switch (err) {
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
    const load = try loadOf(L, "lumen.icons");
    const arena = load.arena;
    lua.c.lua_pushnil(L);
    while (lua.c.lua_next(L, 1) != 0) {
        const key = lua.toSlice(L, -2) orelse return lua.fail(
            L,
            "lumen.icons: keys are item keys like \"app:firefox\" or \"cmd:clipboard\"",
            .{},
        );
        if (std.mem.findScalar(u8, key, ':') == null) {
            return lua.fail(
                L,
                "lumen.icons: \"{s}\" is not a key (app:, cmd:, sys:, win:, script:, ext:, file:)",
                .{key},
            );
        }
        const icon = rows.parseIcon(L, arena, -1, "lumen.icons") orelse
            return lua.fail(L, "lumen.icons: no icon for {s}", .{key});
        const full_key = iconKey(arena, key) catch return lua.failOom(L);
        load.icons.append(arena, .{ .key = full_key, .icon = icon }) catch
            return lua.failOom(L);
        // Pops the value; `lua_next` takes the key off next.
        lua.pop(L, 1);
    }
    return 0;
}

/// An item key as rows have it: "app:firefox" means firefox.desktop.
fn iconKey(arena: std.mem.Allocator, key: []const u8) error{OutOfMemory}![:0]const u8 {
    const is_app = std.mem.startsWith(u8, key, "app:");
    if (is_app and !std.mem.endsWith(u8, key, ".desktop")) {
        return arena.printSentinel("{s}.desktop", .{key}, 0);
    }
    return arena.dupeSentinel(u8, key, 0);
}

// lumen.action.*: tables a row's `actions` list takes.

/// `{ kind = kind, [field] = argument 1, title = argument 2 }`: what
/// `lumen.action.<kind>` returns. `field` is a list for exec, else a string.
fn actionOf(
    L: *lua.State,
    kind: [:0]const u8,
    field: [:0]const u8,
    function_name: []const u8,
) lua.Error!c_int {
    if (std.mem.eql(u8, field, "argv")) {
        try lua.argTable(L, 1, function_name);
    } else {
        _ = try lua.argString(L, 1, function_name);
    }
    const has_title = !lua.isNoneOrNil(L, 2);
    if (has_title) _ = try lua.argString(L, 2, function_name);
    lua.c.lua_createtable(L, 0, 3);
    _ = lua.c.lua_pushstring(L, kind.ptr);
    lua.c.lua_setfield(L, -2, "kind");
    lua.c.lua_pushvalue(L, 1);
    lua.c.lua_setfield(L, -2, field.ptr);
    if (has_title) {
        lua.c.lua_pushvalue(L, 2);
        lua.c.lua_setfield(L, -2, "title");
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
    try json.decode(L, extensionOf(L).gpa(), text);
    return 1;
}

fn jsonEncode(L: *lua.State) lua.Error!c_int {
    if (lua.c.lua_type(L, 1) == lua.c.LUA_TNONE) {
        return lua.fail(L, "bad argument #1 to 'lumen.json.encode' (value expected)", .{});
    }
    try json.encode(L, extensionOf(L).gpa(), 1);
    return 1;
}

test "keys parse like ctrl+g" {
    const ctrl_g = parseKeys("ctrl+g").?;
    try std.testing.expectEqual(gtk.GDK_CONTROL_MASK, ctrl_g.mods);
    try std.testing.expectEqual(@as(c_uint, 'g'), ctrl_g.keyval);
    try std.testing.expectEqual(parseKeys("Ctrl+Shift+G").?.keyval, ctrl_g.keyval);
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
