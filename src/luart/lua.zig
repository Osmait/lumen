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
/// Extensions are still trusted code: they run as the user.
/// Call inside `protect`.
pub fn openLibs(L: *State) void {
    c.luaL_openlibs(L);
    const sandbox =
        \\debug = nil; package.loaded.debug = nil
        \\os.exit, os.execute, os.setlocale = nil, nil, nil
        \\io.popen = nil
        \\package.loadlib = nil; package.cpath = ""
        \\package.searchers[4] = nil; package.searchers[3] = nil
    ;
    if (c.luaL_loadstring(L, sandbox) != c.LUA_OK) _ = c.lua_error(L);
    c.lua_callk(L, 0, 0, 0, null);
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
    if (os.monotonicNs() > budgetOf(L.?).deadline_ns) _ = c.luaL_error(L, "timed out");
}

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
    defer c.lua_settop(L, -2);
    return switch (getField(L, t, name)) {
        c.LUA_TNIL => null,
        c.LUA_TSTRING => a.dupeSentinel(u8, toSlice(L, -1).?, 0) catch raise(
            L,
            "not enough memory",
            .{},
        ),
        // A number reads as text: `subtitle = 42` is fine.
        c.LUA_TNUMBER => blk: {
            var len: usize = 0;
            const p = c.lua_tolstring(L, -1, &len);
            break :blk a.dupeSentinel(u8, p[0..len], 0) catch raise(L, "not enough memory", .{});
        },
        else => raise(L, "{s}.{s}: string expected, got {s}", .{ where, name, typeName(L, -1) }),
    };
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
