//! The parts of Lua 5.4's C API that Lumen uses, and the rules that keep
//! Lua's errors from breaking Zig code.
//!
//! Lua raises errors with longjmp, which skips Zig's `defer` and `errdefer`.
//! So:
//!   - Lumen enters a state only through `protect`: a protected call around
//!     a handler. Inside it any Lua call may raise; the handler's frames must
//!     own nothing that needs cleaning up (their memory comes from an arena
//!     owned by the caller of `protect`).
//!   - Functions Lua calls (`wrap`) check their arguments first, do their
//!     work, and report failure by returning `error.Raise` with the message
//!     pushed; `wrap` raises it once their frames are gone. Work that must
//!     clean up (a child process, a buffer) is finished, or moved under
//!     `tryCall`, before anything else touches the stack.
//!   - Every state has a memory cap and an instruction-count hook that stops
//!     code still running past its deadline.

const std = @import("std");
pub const c = @import("lua");
const os = @import("os");

comptime {
    if (c.LUA_VERSION_NUM != 504) @compileError("Lumen needs Lua 5.4");
}

pub const State = c.lua_State;

/// A state's limits; it is the state's allocator data, so it outlives it.
pub const Budget = struct {
    used: usize = 0,
    max: usize,
    /// Monotonic ns; code still running then is stopped with an error.
    deadline_ns: u64 = std.math.maxInt(u64),
};

pub fn budgetOf(L: *State) *Budget {
    var ud: ?*anyopaque = null;
    _ = c.lua_getallocf(L, &ud);
    return @ptrCast(@alignCast(ud.?));
}

/// A new state with the standard libraries minus what could take the
/// daemon down, or null when out of memory. `budget` must outlive it.
/// Main use is through `protect`; close it with `c.lua_close`.
pub fn newState(budget: *Budget) ?*State {
    const L = c.lua_newstate(&alloc, budget) orelse return null;
    _ = c.lua_atpanic(L, &panic);
    // Every 10k instructions: a few µs apart, cheap next to the work.
    c.lua_sethook(L, &hook, c.LUA_MASKCOUNT, 10_000);
    return L;
}

/// Opens the libraries, then removes what an extension must not reach:
/// exiting the process, blocking shell calls without a timeout (`lumen.exec`
/// has one), native modules, and `debug` (it could unset the time limit).
/// What the time limit cannot stop goes too: `__gc` metamethods (Lua runs
/// finalizers with hooks off, so a loop in one would never end; it marks an
/// object for finalization only when its metatable has `__gc` as
/// `setmetatable` runs, and the files' metatable is hidden so its `__gc`
/// cannot be replaced), the daemon's standard input, and opening a FIFO, a
/// socket or a device that a read or write could wait on forever.
/// Extensions are still trusted code: they run as the user.
/// Call inside `protect`.
pub fn openLibs(L: *State) void {
    c.luaL_openlibs(L);
    const sandbox =
        \\local refuse = ...
        \\debug = nil; package.loaded.debug = nil
        \\os.exit, os.execute, os.setlocale = nil, nil, nil
        \\io.popen = nil
        \\package.loadlib = nil; package.cpath = ""
        \\package.searchers[4] = nil; package.searchers[3] = nil
        \\local setmt, rawget, type, error = setmetatable, rawget, type, error
        \\function setmetatable(t, mt)
        \\  if type(mt) == "table" and rawget(mt, "__gc") ~= nil then
        \\    error("setmetatable: __gc is not available (finalizers run past the time limit)", 2)
        \\  end
        \\  return setmt(t, mt)
        \\end
        \\getmetatable(io.stdout).__metatable = false
        \\pcall(io.input, "/dev/null")
        \\io.stdin = nil
        \\local open = io.open
        \\function io.open(path, ...)
        \\  local why = refuse(path)
        \\  if why then return nil, why end
        \\  return open(path, ...)
        \\end
        \\local by_name = {
        \\  { io, "lines" }, { io, "input" }, { io, "output" }, { _G, "loadfile" }, { _G, "dofile" },
        \\}
        \\for _, lib in ipairs(by_name) do
        \\  local t, name = lib[1], lib[2]
        \\  local f = t[name]
        \\  t[name] = function(path, ...)
        \\    -- Without a file name, loadfile and dofile read standard input.
        \\    if path == nil and t == _G then error(name .. ": a file name expected", 2) end
        \\    local why = refuse(path)
        \\    if why then error(why, 2) end
        \\    return f(path, ...)
        \\  end
        \\end
    ;
    if (c.luaL_loadstring(L, sandbox) != c.LUA_OK) _ = c.lua_error(L);
    c.lua_pushcclosure(L, wrap(refuseOpen), 0);
    c.lua_callk(L, 1, 0, 0, null);
}

/// For the sandbox's io.open and the others that open a file by name: a
/// message when `path` (argument 1) is something a read or write may wait
/// on forever (a FIFO, a socket, a terminal or another device), else
/// nothing. Regular files, folders, missing paths and the devices that
/// never wait pass. Arguments that are not strings pass too: the function
/// they go to reports them.
fn refuseOpen(L: *State) Error!c_int {
    const path = toSlice(L, 1) orelse return 0;
    if (opensSafely(path)) return 0;
    pushFmt(L, "{s}: not a regular file (Lumen does not open FIFOs, sockets or devices)", .{path});
    return 1;
}

fn opensSafely(path: [*:0]const u8) bool {
    const linux = std.os.linux;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &stx);
    // Missing, or out of reach: the open fails on its own.
    if (linux.errno(rc) != .SUCCESS) return true;
    return switch (stx.mode & linux.S.IFMT) {
        linux.S.IFREG, linux.S.IFDIR => true,
        // The memory devices: null, zero, full, random and urandom.
        linux.S.IFCHR => stx.rdev_major == 1 and switch (stx.rdev_minor) {
            3, 5, 7, 8, 9 => true,
            else => false,
        },
        else => false,
    };
}

fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const b: *Budget = @ptrCast(@alignCast(ud.?));
    // Without a block, osize is the kind of object being made, not a size.
    const old = if (ptr != null) osize else 0;
    if (nsize == 0) {
        std.c.free(ptr);
        b.used -= old;
        return null;
    }
    if (nsize > old and b.used - old + nsize > b.max) return null;
    const p = std.c.realloc(ptr, nsize) orelse return null;
    b.used = b.used - old + nsize;
    return p;
}

fn hook(L: ?*State, _: ?*c.lua_Debug) callconv(.c) void {
    if (pastDeadline(L.?)) _ = c.luaL_error(L, "timed out");
}

/// Whether the code running in `L` is past its deadline: for long work in
/// Zig, where the instruction hook does not run.
pub fn pastDeadline(L: *State) bool {
    return os.monotonicNs() > budgetOf(L).deadline_ns;
}

/// An allocator over `child` that holds at most `max` bytes at once: for
/// Zig memory a state's work takes outside the state's own cap (JSON text
/// and trees, the rows a list returns).
pub const Capped = struct {
    child: std.mem.Allocator,
    max: usize,
    used: usize = 0,
    /// An allocation was refused for going over `max`.
    refused: bool = false,

    /// What is left under the state's own cap: whatever the work makes has
    /// to fit in there in the end.
    pub fn leftIn(L: *State, child: std.mem.Allocator) Capped {
        const b = budgetOf(L);
        return .{ .child = child, .max = b.max -| b.used };
    }

    pub fn allocator(self: *Capped) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = cappedAlloc,
            .resize = cappedResize,
            .remap = cappedRemap,
            .free = cappedFree,
        } };
    }

    /// Whether a block may go from `old` to `new` bytes.
    fn fits(self: *Capped, old: usize, new: usize) bool {
        if (new <= old or self.used - old + new <= self.max) return true;
        self.refused = true;
        return false;
    }

    fn cappedAlloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        if (!self.fits(0, len)) return null;
        const p = self.child.rawAlloc(len, al, ra) orelse return null;
        self.used += len;
        return p;
    }

    fn cappedResize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        if (!self.fits(m.len, len) or !self.child.rawResize(m, al, len, ra)) return false;
        self.used = self.used - m.len + len;
        return true;
    }

    fn cappedRemap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        if (!self.fits(m.len, len)) return null;
        const p = self.child.rawRemap(m, al, len, ra) orelse return null;
        self.used = self.used - m.len + len;
        return p;
    }

    fn cappedFree(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, al, ra);
        self.used -= m.len;
    }
};

/// Only reached by a Lua error outside every protected call: a bug here.
fn panic(L: ?*State) callconv(.c) c_int {
    const msg = toSlice(L.?, -1) orelse "?";
    std.debug.panic("Lua error outside a protected call: {s}", .{msg});
}

// ------------------------------------------------------------ protected

/// Runs `handler(L, ctx)` in protected mode. Returns null on success, else
/// the error message with a traceback, in `a`. The stack is left as found.
pub fn protect(
    L: *State,
    a: std.mem.Allocator,
    comptime T: type,
    ctx: *T,
    comptime handler: fn (*State, *T) void,
) ?[:0]const u8 {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    if (c.lua_checkstack(L, 3) == 0) return "Lua stack overflow";
    c.lua_pushcclosure(L, &traceback, 0);
    c.lua_pushcclosure(L, &Trampoline(T, handler).call, 0);
    c.lua_pushlightuserdata(L, ctx);
    if (c.lua_pcallk(L, 1, 0, top + 1, 0, null) == c.LUA_OK) return null;
    var msg: []const u8 = toSlice(L, -1) orelse "error (not a string)";
    // Raised by Lumen's own checks, with no Lua code on the way: the
    // traceback says nothing.
    const empty_trace = "\nstack traceback:\n\t[C]: in ?";
    if (std.mem.endsWith(u8, msg, empty_trace)) msg = msg[0 .. msg.len - empty_trace.len];
    return a.dupeSentinel(u8, msg, 0) catch "error (out of memory)";
}

/// Calls `f(L, ctx)` in protected mode with the top `nargs` values as its
/// arguments (at stack index 2 on). On success leaves `nresults` values and
/// returns true; on a Lua error leaves the error value and returns false.
/// For Zig functions called from Lua that hold resources: free them, then
/// raise the error (`return error.Raise`).
pub fn tryCall(
    L: *State,
    comptime T: type,
    ctx: *T,
    comptime f: fn (*State, *T) void,
    nargs: c_int,
    nresults: c_int,
) bool {
    std.debug.assert(nargs >= 0 and nargs <= c.lua_gettop(L));
    if (c.lua_checkstack(L, 2) == 0) {
        c.lua_settop(L, -nargs - 1);
        _ = c.lua_pushstring(L, "Lua stack overflow");
        return false;
    }
    c.lua_pushcclosure(L, &Trampoline(T, f).call, 0);
    c.lua_pushlightuserdata(L, ctx);
    // The function and its context go under the arguments.
    c.lua_rotate(L, -nargs - 2, 2);
    return c.lua_pcallk(L, nargs + 1, nresults, 0, 0, null) == c.LUA_OK;
}

fn Trampoline(comptime T: type, comptime f: fn (*State, *T) void) type {
    return struct {
        fn call(L: ?*State) callconv(.c) c_int {
            const ctx: *T = @ptrCast(@alignCast(c.lua_touserdata(L, 1)));
            const before = c.lua_gettop(L);
            f(L.?, ctx);
            // Results are whatever `f` left above its arguments.
            return c.lua_gettop(L) - before;
        }
    };
}

fn traceback(L: ?*State) callconv(.c) c_int {
    const msg = c.lua_tolstring(L, 1, null);
    if (msg == null) {
        _ = c.lua_pushstring(L, "error (not a string)");
        return 1;
    }
    c.luaL_traceback(L, L, msg, 1);
    return 1;
}

// ------------------------------------------- functions called from Lua

/// The error value (a message) is on the stack: raise it.
pub const Error = error{Raise};

/// A C function for Lua from `f`, which returns how many results it pushed
/// or `error.Raise` with the error message on the stack.
pub fn wrap(comptime f: fn (*State) Error!c_int) c.lua_CFunction {
    return &struct {
        fn call(L: ?*State) callconv(.c) c_int {
            const n = f(L.?) catch {
                // `fail` pushed the message raised.
                std.debug.assert(c.lua_gettop(L) >= 1);
                return c.lua_error(L);
            };
            // Lua takes the top `n` values as the results, unchecked in
            // distribution builds: they must be there.
            std.debug.assert(n >= 0 and n <= c.lua_gettop(L));
            return n;
        }
    }.call;
}

/// Pushes a message for `error.Raise`. Call it before acquiring anything
/// that needs cleaning up: pushing can itself raise (out of memory).
pub fn fail(L: *State, comptime fmt: []const u8, args: anytype) Error {
    pushFmt(L, fmt, args);
    return error.Raise;
}

/// Pushes a formatted string (cut at 512 bytes).
pub fn pushFmt(L: *State, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.mem.print(&buf, fmt, args) catch buf[0..];
    _ = c.lua_pushlstring(L, msg.ptr, msg.len);
}

/// Raises a formatted error now. Only inside `protect` handlers and from
/// frames that own nothing.
pub fn raise(L: *State, comptime fmt: []const u8, args: anytype) noreturn {
    pushFmt(L, fmt, args);
    _ = c.lua_error(L);
    unreachable;
}

pub const Fn = struct { [:0]const u8, (fn (*State) Error!c_int) };

/// Sets each function, wrapped (`wrap`), as a field of the table on top.
pub fn setFuncs(L: *State, comptime fns: []const Fn) void {
    inline for (fns) |f| {
        c.lua_pushcclosure(L, wrap(f[1]), 0);
        c.lua_setfield(L, -2, f[0].ptr);
    }
}

/// Pushes element `i` (1-based) of the list at `list` and returns its
/// absolute index; raises unless it is a table (`where` names it).
pub fn tableAt(L: *State, list: c_int, i: usize, where: []const u8) c_int {
    if (c.lua_rawgeti(L, list, @intCast(i)) != c.LUA_TTABLE)
        raise(L, "{s}: table expected, got {s}", .{ where, typeName(L, -1) });
    return c.lua_gettop(L);
}

/// Raises Lua's own "not enough memory", for a Zig allocation that failed
/// inside a protected call.
pub fn oom(L: *State) noreturn {
    raise(L, "not enough memory", .{});
}

/// `oom` for a function Lua calls: pushes the message, for `wrap` to raise.
pub fn failOom(L: *State) Error {
    return fail(L, "not enough memory", .{});
}

pub fn typeName(L: *State, idx: c_int) []const u8 {
    return std.mem.span(c.lua_typename(L, c.lua_type(L, idx)));
}

/// The string at `idx` (not converted from a number), valid while the
/// value stays reachable.
pub fn toSlice(L: *State, idx: c_int) ?[:0]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len :0];
}

pub fn argString(L: *State, arg: c_int, func: []const u8) Error![:0]const u8 {
    return toSlice(L, arg) orelse fail(
        L,
        "bad argument #{d} to '{s}' (string expected, got {s})",
        .{ arg, func, typeName(L, arg) },
    );
}

pub fn argTable(L: *State, arg: c_int, func: []const u8) Error!void {
    if (c.lua_type(L, arg) != c.LUA_TTABLE)
        return fail(L, "bad argument #{d} to '{s}' (table expected, got {s})", .{
            arg,
            func,
            typeName(L, arg),
        });
}

pub fn pushString(L: *State, s: []const u8) void {
    _ = c.lua_pushlstring(L, s.ptr, s.len);
}

// ------------------------------------------------- reading Lua tables
// For `protect` handlers: these raise on a value of the wrong type, with
// `where` ("items[3]") in the message.

/// Pushes `t[name]` and returns its type.
pub fn getField(L: *State, t: c_int, name: [:0]const u8) c_int {
    return c.lua_getfield(L, t, name.ptr);
}

/// `t[name]` as a string copied into `a`, or null when nil.
pub fn fieldString(
    L: *State,
    a: std.mem.Allocator,
    t: c_int,
    name: [:0]const u8,
    where: []const u8,
) ?[:0]const u8 {
    return fieldStringMax(L, a, t, name, where, std.math.maxInt(usize));
}

/// `fieldString` cut to at most `max` bytes, between UTF-8 characters.
pub fn fieldStringMax(
    L: *State,
    a: std.mem.Allocator,
    t: c_int,
    name: [:0]const u8,
    where: []const u8,
    max: usize,
) ?[:0]const u8 {
    defer c.lua_settop(L, -2);
    switch (getField(L, t, name)) {
        c.LUA_TNIL => return null,
        // A number reads as text: `subtitle = 42` is fine.
        c.LUA_TSTRING, c.LUA_TNUMBER => {},
        else => raise(L, "{s}.{s}: string expected, got {s}", .{ where, name, typeName(L, -1) }),
    }
    var len: usize = 0;
    const p = c.lua_tolstring(L, -1, &len);
    return a.dupeSentinel(u8, cut(p[0..len], max), 0) catch oom(L);
}

/// `s` cut to at most `max` bytes, before the UTF-8 character `max` falls
/// in.
pub fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

/// `t[name]` as a boolean (nil is `default`).
pub fn fieldBool(L: *State, t: c_int, name: [:0]const u8, default: bool, where: []const u8) bool {
    defer c.lua_settop(L, -2);
    return switch (getField(L, t, name)) {
        c.LUA_TNIL => default,
        c.LUA_TBOOLEAN => c.lua_toboolean(L, -1) != 0,
        else => raise(L, "{s}.{s}: boolean expected, got {s}", .{ where, name, typeName(L, -1) }),
    };
}

/// `t[name]` as a number (nil is null).
pub fn fieldNumber(L: *State, t: c_int, name: [:0]const u8, where: []const u8) ?f64 {
    defer c.lua_settop(L, -2);
    return switch (getField(L, t, name)) {
        c.LUA_TNIL => null,
        c.LUA_TNUMBER => c.lua_tonumberx(L, -1, null),
        else => raise(L, "{s}.{s}: number expected, got {s}", .{ where, name, typeName(L, -1) }),
    };
}

pub fn absIndex(L: *State, idx: c_int) c_int {
    return c.lua_absindex(L, idx);
}

/// A reference to the value on top (popped), for `c.lua_rawgeti` later.
pub fn ref(L: *State) c_int {
    return c.luaL_ref(L, c.LUA_REGISTRYINDEX);
}

pub fn unref(L: *State, r: c_int) void {
    c.luaL_unref(L, c.LUA_REGISTRYINDEX, r);
}

pub fn pushRef(L: *State, r: c_int) c_int {
    return c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, r);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testState(budget: *Budget) !*State {
    const L = newState(budget) orelse return error.OutOfMemory;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Ctx = struct {
        fn open(Ls: *State, _: *u8) void {
            openLibs(Ls);
        }
    };
    var dummy: u8 = 0;
    if (protect(L, arena.allocator(), u8, &dummy, Ctx.open)) |msg| {
        std.debug.print("{s}\n", .{msg});
        return error.TestUnexpectedResult;
    }
    return L;
}

/// Runs `code` and returns its error message (null when it succeeded).
fn runCode(L: *State, a: std.mem.Allocator, code: [:0]const u8) ?[:0]const u8 {
    const Ctx = struct {
        code: [:0]const u8,
        fn run(Ls: *State, ctx: *@This()) void {
            if (c.luaL_loadstring(Ls, ctx.code.ptr) != c.LUA_OK) _ = c.lua_error(Ls);
            c.lua_callk(Ls, 0, 0, 0, null);
        }
    };
    var ctx: Ctx = .{ .code = code };
    return protect(L, a, Ctx, &ctx, Ctx.run);
}

test "errors come back as messages, and the sandbox holds" {
    var budget: Budget = .{ .max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(runCode(L, a, "x = 1 + 1") == null);
    const msg = runCode(L, a, "error('boom')").?;
    try testing.expect(std.mem.find(u8, msg, "boom") != null);
    try testing.expect(std.mem.find(u8, msg, "traceback") != null);
    // Nothing that ends the daemon or runs native code is reachable.
    try testing.expect(
        runCode(L, a, "assert(os.exit == nil and os.execute == nil and io.popen == nil)") == null,
    );
    try testing.expect(
        runCode(
            L,
            a,
            "assert(debug == nil and package.loadlib == nil and package.cpath == '')",
        ) == null,
    );
    try testing.expect(
        runCode(L, a, "assert(string.format('%d', 3) == '3' and os.time() > 0)") == null,
    );
    try testing.expectEqual(@as(c_int, 0), c.lua_gettop(L));
}

test "a runaway loop stops at its deadline" {
    var budget: Budget = .{ .max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    budget.deadline_ns = os.monotonicNs() + 50 * std.time.ns_per_ms;
    const t0 = os.monotonicNs();
    const msg = runCode(L, arena.allocator(), "while true do end").?;
    try testing.expect(std.mem.find(u8, msg, "timed out") != null);
    try testing.expect(os.monotonicNs() - t0 < 2 * std.time.ns_per_s);
}

test "memory is capped per state" {
    var budget: Budget = .{ .max = 4 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msg = runCode(
        L,
        arena.allocator(),
        "local t = {} for i = 1, 1e8 do t[i] = ('x'):rep(100) .. i end",
    ).?;
    try testing.expect(std.mem.find(u8, msg, "memory") != null);
    try testing.expect(budget.used <= budget.max);
    // Still usable afterwards.
    try testing.expect(runCode(L, arena.allocator(), "x = 1") == null);
}

test "what the time limit cannot stop is out of reach" {
    var budget: Budget = .{ .max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A finalizer runs with the instruction hook off: none can be set.
    const gc = runCode(L, a, "setmetatable({}, { __gc = function() while true do end end })").?;
    try testing.expect(std.mem.find(u8, gc, "__gc is not available") != null);
    try testing.expect(runCode(L, a, "setmetatable({}, { __gc = false })") != null);
    try testing.expect(runCode(
        L,
        a,
        "local t = setmetatable({}, { __index = string }) assert(t.rep == string.rep)",
    ) == null);
    // Nor through the files' metatable, which every open file is marked by.
    try testing.expect(runCode(L, a, "assert(getmetatable(io.stdout) == false)") == null);
    try testing.expect(runCode(L, a, "io.stdout:write('')") == null);
    // The daemon's standard input reads as empty.
    try testing.expect(runCode(
        L,
        a,
        "assert(io.stdin == nil and io.read() == nil and io.lines()() == nil)",
    ) == null);
    try testing.expect(std.mem.find(u8, runCode(L, a, "dofile()").?, "file name expected") != null);

    // A FIFO would wait for a writer forever; regular and missing files
    // behave as usual.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [512]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp, &dbuf);
    const fifo = try std.fmt.allocPrintSentinel(a, "{s}/fifo", .{dir}, 0);
    const linux = std.os.linux;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(
        linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0),
    ));
    const code = try std.fmt.allocPrintSentinel(a,
        \\local fifo = "{s}"
        \\local f, err = io.open(fifo)
        \\assert(f == nil and err:find("not a regular file"), err)
        \\assert(not pcall(io.lines, fifo) and not pcall(io.output, fifo) and not pcall(dofile, fifo))
        \\assert(io.open(fifo .. ".missing") == nil)
        \\local w = assert(io.open(fifo .. ".txt", "w")) w:write("hi") w:close()
        \\assert(io.open(fifo .. ".txt"):read("a") == "hi")
        \\assert(io.open("/dev/null"):read("a") == "")
    , .{fifo}, 0);
    if (runCode(L, a, code)) |msg| {
        std.debug.print("{s}\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

test "a capped allocator holds no more than its cap" {
    var capped: Capped = .{ .child = testing.allocator, .max = 1000 };
    const a = capped.allocator();
    const x = try a.alloc(u8, 600);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 600));
    try testing.expect(capped.refused);
    a.free(x);
    try testing.expectEqual(@as(usize, 0), capped.used);
    // Growing counts too.
    var y = try a.alloc(u8, 900);
    try testing.expectError(error.OutOfMemory, a.realloc(y, 1200));
    y = try a.realloc(y, 1000);
    try testing.expectEqual(@as(usize, 1000), capped.used);
    a.free(y);
    try testing.expectEqual(@as(usize, 0), capped.used);
}

test "strings are cut between characters" {
    try testing.expectEqualStrings("abc", cut("abc", 5));
    try testing.expectEqualStrings("ab", cut("abc", 2));
    // "é" is two bytes: cutting inside it drops it whole.
    try testing.expectEqualStrings("a", cut("aé", 2));
    try testing.expectEqualStrings("aé", cut("aéz", 3));
}
