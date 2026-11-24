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
//!     `tryCall`, before anything else touches the stack. A frame that owns
//!     nothing to clean up (no `defer`, no `errdefer`, its memory in an
//!     arena) may also raise directly, through the readers below that do
//!     (`fail`, `fieldStringMax`, `fieldBool`...): `lumen.theme`,
//!     `lumen.icons` do. Adding a `defer` to such a frame means moving its
//!     raising calls out first.
//!   - Every state has a memory cap and an instruction-count hook that stops
//!     code still running past its deadline.

const std = @import("std");
pub const c = @import("lua");
const os = @import("os");
const assert = std.debug.assert;

comptime {
    if (c.LUA_VERSION_NUM != 504) @compileError("Lumen needs Lua 5.4");
}

pub const State = c.lua_State;

/// A state's limits; it is the state's allocator data, so it outlives it.
pub const Budget = struct {
    used_bytes: usize = 0,
    bytes_max: usize,
    /// Monotonic ns; code still running then is stopped with an error.
    deadline_ns: u64 = std.math.maxInt(u64),
    /// Set once the deadline expires so `pcall`/`xpcall`/coroutines cannot
    /// swallow the timeout and keep spinning.
    timed_out: bool = false,
    /// Set by another thread (a shutdown): code running stops as if past
    /// its deadline, at the next check.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Files the state holds open (`io.open`, lfiles.c), up to
    /// `open_files_max`.
    open_files: u32 = 0,

    /// Past its deadline, timed out already, or cancelled.
    fn expired(budget: *const Budget) bool {
        if (budget.timed_out) return true;
        if (budget.cancel) |cancel| {
            if (cancel.load(.acquire)) return true;
        }
        return os.monotonicNs() > budget.deadline_ns;
    }
};

/// The most of an error message kept (`protect`): an extension raising a
/// 30 MB string sent it whole to the window and the log.
const error_message_bytes_max = 4096;

/// Files one state may hold open at once: each takes one of the daemon's
/// descriptors, which its socket, SQLite and GTK need too (the soft limit
/// is usually 1024).
pub const open_files_max = 64;

/// The budget a state was made with (its allocator's user data).
pub fn budgetOf(L: *State) *Budget {
    var user_data: ?*anyopaque = null;
    _ = c.lua_getallocf(L, &user_data);
    return @ptrCast(@alignCast(user_data.?));
}

/// Instructions between deadline checks under normal execution.
const hook_instruction_count = 10_000;

/// A new state with the standard libraries minus what could take the
/// daemon down, or null when out of memory. `budget` must outlive it.
/// Main use is through `protect`; close it with `c.lua_close`.
pub fn newState(budget: *Budget) ?*State {
    const L = c.lua_newstate(&alloc, budget) orelse return null;
    _ = c.lua_atpanic(L, &panic);
    // Every 10k instructions: a few µs apart, cheap next to the work.
    c.lua_sethook(L, &hook, c.LUA_MASKCOUNT, hook_instruction_count);
    return L;
}

/// Opens the libraries, then removes what an extension must not reach:
/// exiting the process, blocking shell calls without a timeout (`lumen.exec`
/// has one), native modules, binary bytecode chunks (Lua 5.4 does not verify
/// them), and `debug` (it could unset the time limit).
/// What the time limit cannot stop goes too: `__gc` metamethods (Lua runs
/// finalizers with hooks off, so a loop in one would never end; it marks an
/// object for finalization only when its metatable has `__gc` as
/// `setmetatable` runs, and the files' metatable is hidden so its `__gc`
/// cannot be replaced), catching timeouts with `pcall`/`xpcall`/coroutines,
/// loops in C the hook never interrupts (`table.move` over a huge range runs
/// in slices of 4096 elements; the pattern functions check the deadline
/// themselves, lstrmatch.c), the daemon's standard input, and opening a
/// FIFO, a socket or a device
/// that a read or write could wait on forever (including through `require`).
/// Extensions are still trusted code: they run as the user.
/// Call inside `protect`.
pub fn openLibs(L: *State) void {
    c.luaL_openlibs(L);
    // Before the sandbox below: it keeps no reference to the originals.
    _ = luart_open_patterns(L);
    _ = luart_open_files(L);
    const prelude = sandbox_prelude;
    if (c.luaL_loadbufferx(L, prelude.ptr, prelude.len, "=sandbox", "t") != c.LUA_OK) {
        _ = c.lua_error(L);
    }
    c.lua_pushcclosure(L, wrap(refuseOpen), 0);
    c.lua_pushcclosure(L, wrap(isTimedOut), 0);
    c.lua_pushcclosure(L, wrap(armThreadHook), 0);
    c.lua_callk(L, 3, 0, 0, null);
}

/// Run by `openLibs` once the libraries are open, with `refuseOpen`,
/// `isTimedOut` and `armThreadHook` as its arguments: what it replaces and
/// why is said there.
const sandbox_prelude =
    \\local refuse, timed_out, arm_hook = ...
    \\debug = nil; package.loaded.debug = nil
    \\os.exit, os.execute, os.setlocale = nil, nil, nil
    \\io.popen = nil
    \\package.loadlib = nil; package.cpath = ""
    \\package.searchers[4] = nil; package.searchers[3] = nil
    \\local setmt, rawget, type, error, tostring, select =
    \\  setmetatable, rawget, type, error, tostring, select
    \\function setmetatable(t, mt)
    \\  if type(mt) == "table" and rawget(mt, "__gc") ~= nil then
    \\    error("setmetatable: __gc is not available (finalizers run past the time limit)", 2)
    \\  end
    \\  return setmt(t, mt)
    \\end
    \\getmetatable(io.stdout).__metatable = false
    \\pcall(io.input, "/dev/null")
    \\io.stdin = nil
    \\local function check_path(path)
    \\  if type(path) == "number" then path = tostring(path) end
    \\  return path, refuse(path)
    \\end
    \\local open = io.open
    \\local raw_input, raw_output, raw_lines = io.input, io.output, io.lines
    \\local function opened(path, mode)
    \\  local f, err = open(path, mode)
    \\  if not f then error(err, 3) end
    \\  return f
    \\end
    \\local function named(path) return type(path) == "string" or type(path) == "number" end
    \\function io.input(path)
    \\  if named(path) then return raw_input(opened(path, "r")) end
    \\  return raw_input(path)
    \\end
    \\function io.output(path)
    \\  if named(path) then return raw_output(opened(path, "w")) end
    \\  return raw_output(path)
    \\end
    \\function io.lines(path, ...)
    \\  if path == nil then return raw_lines(nil, ...) end
    \\  local f = opened(path, "r")
    \\  local next_line = f:lines(...)
    \\  local done = false
    \\  local function finish(...)
    \\    if (...) == nil then done = true; f:close() end
    \\    return ...
    \\  end
    \\  return function()
    \\    if done then return nil end
    \\    return finish(next_line())
    \\  end, nil, nil, f
    \\end
    \\local raw_move, tointeger, maxinteger = table.move, math.tointeger, math.maxinteger
    \\local move_chunk = 4096
    \\function table.move(a1, f, e, t, a2)
    \\  if a2 == nil then a2 = a1 end
    \\  local fi, ei, ti = tointeger(f), tointeger(e), tointeger(t)
    \\  if not (fi and ei and ti) or ei - fi < move_chunk or not (fi > 0 or ei < maxinteger + fi) then
    \\    return raw_move(a1, f, e, t, a2)
    \\  end
    \\  local count = ei - fi + 1
    \\  if ti > maxinteger - count + 1 then return raw_move(a1, f, e, t, a2) end
    \\  if ti > ei or ti <= fi or a1 ~= a2 then
    \\    local from = fi
    \\    while from <= ei do
    \\      local last = from + move_chunk - 1
    \\      if last > ei then last = ei end
    \\      raw_move(a1, from, last, ti + (from - fi), a2)
    \\      from = last + 1
    \\    end
    \\  else
    \\    local last = ei
    \\    while last >= fi do
    \\      local from = last - move_chunk + 1
    \\      if from < fi then from = fi end
    \\      raw_move(a1, from, last, ti + (from - fi), a2)
    \\      last = from - 1
    \\    end
    \\  end
    \\  return a2
    \\end
    \\local raw_load = load
    \\function load(chunk, chunkname, mode, ...)
    \\  if mode ~= nil and mode ~= "t" then
    \\    return nil, "load: binary chunks are not allowed"
    \\  end
    \\  if select("#", ...) > 0 then
    \\    return raw_load(chunk, chunkname, "t", ...)
    \\  end
    \\  return raw_load(chunk, chunkname, "t")
    \\end
    \\local raw_loadfile = loadfile
    \\function loadfile(path, mode, ...)
    \\  if path == nil then error("loadfile: a file name expected", 2) end
    \\  local checked, why = check_path(path)
    \\  if why then error(why, 2) end
    \\  if mode ~= nil and mode ~= "t" then
    \\    return nil, "loadfile: binary chunks are not allowed"
    \\  end
    \\  if select("#", ...) > 0 then
    \\    return raw_loadfile(checked, "t", ...)
    \\  end
    \\  return raw_loadfile(checked, "t")
    \\end
    \\function dofile(path)
    \\  if path == nil then error("dofile: a file name expected", 2) end
    \\  local chunk, err = loadfile(path, "t")
    \\  if not chunk then error(err, 2) end
    \\  return chunk()
    \\end
    \\local concat = table.concat
    \\function package.searchpath(name, path, sep, rep)
    \\  if type(name) ~= "string" then error("bad argument #1 to 'searchpath' (string expected)", 2) end
    \\  if type(path) ~= "string" then error("bad argument #2 to 'searchpath' (string expected)", 2) end
    \\  sep = sep or "."
    \\  rep = rep or "/"
    \\  if sep ~= "" then
    \\    local esc = sep:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    \\    local rep_esc = rep:gsub("%%", "%%%%")
    \\    name = name:gsub(esc, rep_esc)
    \\  end
    \\  local repl = name:gsub("%%", "%%%%")
    \\  local msg = {}
    \\  for template in (path .. ";"):gmatch("([^;]*);") do
    \\    if template ~= "" then
    \\      local filename = template:gsub("%?", repl)
    \\      local checked, why = check_path(filename)
    \\      if why then
    \\        msg[#msg + 1] = "\n\t" .. why
    \\      else
    \\        local f = open(checked, "r")
    \\        if f then
    \\          f:close()
    \\          return checked
    \\        end
    \\        msg[#msg + 1] = "\n\tno file '" .. checked .. "'"
    \\      end
    \\    end
    \\  end
    \\  return nil, concat(msg)
    \\end
    \\local searchpath = package.searchpath
    \\package.searchers[2] = function(name)
    \\  local filename, err = searchpath(name, package.path)
    \\  if not filename then return err end
    \\  local checked, why = check_path(filename)
    \\  if why then error(why, 2) end
    \\  local chunk, lerr = raw_loadfile(checked, "t")
    \\  if not chunk then
    \\    error("error loading module '" .. tostring(name) .. "' from file '" .. checked .. "':\n\t" .. tostring(lerr), 2)
    \\  end
    \\  return chunk, checked
    \\end
    \\local function rethrow_if_timed_out(ok, ...)
    \\  if not ok and timed_out() then error("timed out", 0) end
    \\  return ok, ...
    \\end
    \\local raw_pcall, raw_xpcall = pcall, xpcall
    \\function pcall(...)
    \\  if timed_out() then error("timed out", 0) end
    \\  return rethrow_if_timed_out(raw_pcall(...))
    \\end
    \\function xpcall(...)
    \\  if timed_out() then error("timed out", 0) end
    \\  return rethrow_if_timed_out(raw_xpcall(...))
    \\end
    \\if type(coroutine) == "table" then
    \\  local raw_create, raw_resume, raw_close = coroutine.create, coroutine.resume, coroutine.close
    \\  function coroutine.create(f)
    \\    local co = raw_create(f)
    \\    arm_hook(co)
    \\    return co
    \\  end
    \\  function coroutine.wrap(f)
    \\    local co = raw_create(f)
    \\    arm_hook(co)
    \\    local function unwrap(ok, ...)
    \\      if not ok then
    \\        if timed_out() then error("timed out", 0) end
    \\        error((...), 2)
    \\      end
    \\      return ...
    \\    end
    \\    return function(...)
    \\      if timed_out() then error("timed out", 0) end
    \\      arm_hook(co)
    \\      return unwrap(raw_resume(co, ...))
    \\    end
    \\  end
    \\  function coroutine.resume(co, ...)
    \\    if timed_out() then error("timed out", 0) end
    \\    arm_hook(co)
    \\    return rethrow_if_timed_out(raw_resume(co, ...))
    \\  end
    \\  if raw_close then
    \\    function coroutine.close(...)
    \\      if timed_out() then error("timed out", 0) end
    \\      return rethrow_if_timed_out(raw_close(...))
    \\    end
    \\  end
    \\end
;

fn isTimedOut(L: *State) Error!c_int {
    c.lua_pushboolean(L, @intFromBool(budgetOf(L).timed_out));
    return 1;
}

fn armThreadHook(L: *State) Error!c_int {
    if (c.lua_tothread(L, 1)) |co| {
        const count: c_int = if (budgetOf(L).timed_out) 1 else hook_instruction_count;
        c.lua_sethook(co, &hook, c.LUA_MASKCOUNT, count);
    }
    return 0;
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
    const reason = "Lumen does not open FIFOs, sockets, devices or a process's memory";
    pushFmt(L, "{s}: not a regular file ({s})", .{ path, reason });
    return 1;
}

/// Whether an already-opened descriptor `fd` is safe for an extension to
/// hold: a regular file or folder, or one of the non-blocking memory
/// devices (`MemoryDevice`), and never a procfs process memory file or a
/// writable procfs file (even through a symlink, since `/proc/self/fd/<fd>`
/// resolves the open target).
fn fdAllowed(fd: i32) bool {
    const linux = std.os.linux;
    var status: linux.Statx = undefined;
    const result = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &status);
    if (linux.errno(result) != .SUCCESS) return false;
    var proc_status: linux.Statx = undefined;
    const proc_result = linux.statx(linux.AT.FDCWD, "/proc", 0, .{ .TYPE = true }, &proc_status);
    if (linux.errno(proc_result) != .SUCCESS) return false;
    if (status.dev_major == proc_status.dev_major and status.dev_minor == proc_status.dev_minor) {
        const flags = linux.fcntl(fd, linux.F.GETFL, 0);
        if (linux.errno(flags) != .SUCCESS) return false;
        const o_flags: linux.O = @bitCast(@as(u32, @truncate(flags)));
        if (o_flags.ACCMODE != .RDONLY) return false;
        var fd_path_buf: [32]u8 = undefined;
        const fd_path = std.mem.printSentinel(&fd_path_buf, "/proc/self/fd/{d}", .{fd}, 0) catch {
            return false;
        };
        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = linux.readlink(fd_path.ptr, &target_buf, target_buf.len);
        if (linux.errno(len) != .SUCCESS or len == 0) return false;
        const base = std.fs.path.basename(target_buf[0..len]);
        if (std.mem.eql(u8, base, "mem") or std.mem.startsWith(u8, base, "mem ")) return false;
    }
    return switch (status.mode & linux.S.IFMT) {
        linux.S.IFREG, linux.S.IFDIR => true,
        // The memory devices: null, zero, full, random and urandom.
        linux.S.IFCHR => status.rdev_major == memory_device_major and
            std.enums.fromInt(MemoryDevice, status.rdev_minor) != null,
        else => false,
    };
}

/// For io.open (lfiles.c): nonzero when `fd` may be wrapped in a Lua stream.
export fn luart_fd_allowed(fd: c_int) c_int {
    return @intFromBool(fdAllowed(fd));
}

/// Linux's memory devices (major 1) that Lua's file functions may open,
/// by minor number (Documentation/admin-guide/devices.txt).
const memory_device_major = 1;
const MemoryDevice = enum(u32) { null = 3, zero = 5, full = 7, random = 8, urandom = 9 };

fn opensSafely(path: [*:0]const u8) bool {
    const linux = std.os.linux;
    const result = linux.open(
        path,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true },
        0,
    );
    switch (linux.errno(result)) {
        .SUCCESS => {
            const fd: i32 = @intCast(result);
            defer os.close(fd);
            return fdAllowed(fd);
        },
        .NXIO => return false,
        // Missing, out of reach, or ELOOP/ENAMETOOLONG: the caller reports it.
        else => return true,
    }
}

/// Lua's allocator (`lua_Alloc`; `osize` and `nsize` are its manual's
/// names): realloc, under the state's memory cap.
fn alloc(
    user_data: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    const budget: *Budget = @ptrCast(@alignCast(user_data.?));
    // Without a block, osize is the kind of object being made, not a size.
    const old_bytes = if (ptr != null) osize else 0;
    assert(budget.used_bytes >= old_bytes);
    if (nsize == 0) {
        std.c.free(ptr);
        budget.used_bytes -= old_bytes;
        return null;
    }
    const base = budget.used_bytes - old_bytes;
    const used_bytes_after = std.math.add(usize, base, nsize) catch return null;
    if (nsize > old_bytes and used_bytes_after > budget.bytes_max) return null;
    const block = std.c.realloc(ptr, nsize) orelse return null;
    budget.used_bytes = used_bytes_after;
    return block;
}

extern fn luart_open_patterns(L: *State) c_int;
extern fn luart_open_files(L: *State) c_int;

/// For io.open (lfiles.c): takes one of the state's `open_files_max`
/// slots; 0 when none is left.
export fn luart_file_opened(L: *State) c_int {
    const budget = budgetOf(L);
    if (budget.open_files >= open_files_max) return 0;
    budget.open_files += 1;
    return 1;
}

/// For io.open (lfiles.c): a file was closed or never opened.
export fn luart_file_closed(L: *State) void {
    const budget = budgetOf(L);
    assert(budget.open_files > 0);
    budget.open_files -= 1;
}

/// For the pattern matcher (lstrmatch.c), every few thousand steps: its
/// backtracking runs in C, where `hook` never does. Nonzero once the
/// deadline has passed; the matcher then raises "timed out", and every
/// instruction after it raises again, as after `hook`.
export fn luart_match_timed_out(L: *State) c_int {
    const budget = budgetOf(L);
    if (!budget.expired()) return 0;
    budget.timed_out = true;
    c.lua_sethook(L, &hook, c.LUA_MASKCOUNT, 1);
    return 1;
}

fn hook(L: ?*State, _: ?*c.lua_Debug) callconv(.c) void {
    const state = L.?;
    const budget = budgetOf(state);
    if (budget.expired()) {
        budget.timed_out = true;
        c.lua_sethook(state, &hook, c.LUA_MASKCOUNT, 1);
        _ = c.luaL_error(state, "timed out");
    }
}

/// Whether the code running in `L` is past its deadline: for long work in
/// Zig, where the instruction hook does not run.
pub fn pastDeadline(L: *State) bool {
    const budget = budgetOf(L);
    if (!budget.expired()) return false;
    budget.timed_out = true;
    return true;
}

/// An allocator over `child` that holds at most `bytes_max` bytes at once:
/// for Zig memory a state's work takes outside the state's own cap (JSON
/// text and trees, the rows a list returns).
pub const Capped = struct {
    child: std.mem.Allocator,
    bytes_max: usize,
    used_bytes: usize = 0,
    /// An allocation was refused for going over `bytes_max`.
    refused: bool = false,

    /// What is left under the state's own cap: whatever the work makes has
    /// to fit in there in the end.
    pub fn leftIn(L: *State, child: std.mem.Allocator) Capped {
        const budget = budgetOf(L);
        return .{ .child = child, .bytes_max = budget.bytes_max -| budget.used_bytes };
    }

    pub fn allocator(self: *Capped) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = cappedAlloc,
            .resize = cappedResize,
            .remap = cappedRemap,
            .free = cappedFree,
        } };
    }

    /// Whether a block may go from `old_bytes` to `new_bytes`.
    fn fits(self: *Capped, old_bytes: usize, new_bytes: usize) bool {
        assert(self.used_bytes >= old_bytes);
        if (new_bytes <= old_bytes) return true;
        const base = self.used_bytes - old_bytes;
        const after = std.math.add(usize, base, new_bytes) catch {
            self.refused = true;
            return false;
        };
        if (after <= self.bytes_max) return true;
        self.refused = true;
        return false;
    }

    fn cappedAlloc(
        context: *anyopaque,
        bytes: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Capped = @ptrCast(@alignCast(context));
        if (!self.fits(0, bytes)) return null;
        const block = self.child.rawAlloc(bytes, alignment, return_address) orelse return null;
        self.used_bytes += bytes;
        return block;
    }

    fn cappedResize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_bytes: usize,
        return_address: usize,
    ) bool {
        const self: *Capped = @ptrCast(@alignCast(context));
        if (!self.fits(memory.len, new_bytes)) return false;
        if (!self.child.rawResize(memory, alignment, new_bytes, return_address)) return false;
        self.used_bytes = self.used_bytes - memory.len + new_bytes;
        return true;
    }

    fn cappedRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_bytes: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Capped = @ptrCast(@alignCast(context));
        if (!self.fits(memory.len, new_bytes)) return null;
        const remapped = self.child.rawRemap(memory, alignment, new_bytes, return_address);
        const block = remapped orelse return null;
        self.used_bytes = self.used_bytes - memory.len + new_bytes;
        return block;
    }

    fn cappedFree(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *Capped = @ptrCast(@alignCast(context));
        assert(self.used_bytes >= memory.len);
        self.child.rawFree(memory, alignment, return_address);
        self.used_bytes -= memory.len;
    }
};

/// Only reached by a Lua error outside every protected call: a bug here.
fn panic(L: ?*State) callconv(.c) c_int {
    const message = toSlice(L.?, -1) orelse "?";
    std.debug.panic("Lua error outside a protected call: {s}", .{message});
}

// ------------------------------------------------------------ protected

/// Runs `handler(L, context)` in protected mode. Returns null on success,
/// else the error message with a traceback, in `arena`. The stack is left
/// as found, also when the handler raised: that is what lets handlers pop
/// with `defer` and `StackMark` (a raise skips their defers; this restores
/// the stack in their place).
pub fn protect(
    L: *State,
    arena: std.mem.Allocator,
    comptime Context: type,
    context: *Context,
    comptime handler: fn (*State, *Context) void,
) ?[:0]const u8 {
    const budget = budgetOf(L);
    budget.timed_out = false;
    c.lua_sethook(L, &hook, c.LUA_MASKCOUNT, hook_instruction_count);
    defer {
        budget.timed_out = false;
        c.lua_sethook(L, &hook, c.LUA_MASKCOUNT, hook_instruction_count);
    }
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    if (c.lua_checkstack(L, 3) == 0) return "Lua stack overflow";
    c.lua_pushcclosure(L, &traceback, 0);
    c.lua_pushcclosure(L, &Trampoline(Context, handler).call, 0);
    c.lua_pushlightuserdata(L, context);
    if (c.lua_pcallk(L, 1, 0, top + 1, 0, null) == c.LUA_OK) return null;
    var message: []const u8 = toSlice(L, -1) orelse "error (not a string)";
    // Raised by Lumen's own checks, with no Lua code on the way: the
    // traceback says nothing.
    const empty_trace = "\nstack traceback:\n\t[C]: in ?";
    if (std.mem.endsWith(u8, message, empty_trace)) {
        message = message[0 .. message.len - empty_trace.len];
    }
    return arena.dupeSentinel(u8, cut(message, error_message_bytes_max), 0) catch
        "error (out of memory)";
}

pub const TryCallResult = enum { ok, raised, stack_overflow };

/// Calls `handler(L, context)` in protected mode with the top
/// `arguments_count` values as its arguments (at stack index 2 on). Never
/// longjmps:
/// - `.ok`: leaves `results_count` values on the stack.
/// - `.raised`: leaves the error value on the stack (`return error.Raise`).
/// - `.stack_overflow`: pops the arguments and pushes nothing (pushing in
///   OOM could longjmp and skip caller defers); free Zig resources first,
///   then `return lua.fail(L, "Lua stack overflow", .{})`.
pub fn tryCall(
    L: *State,
    comptime Context: type,
    context: *Context,
    comptime handler: fn (*State, *Context) void,
    arguments_count: c_int,
    results_count: c_int,
) TryCallResult {
    assert(arguments_count >= 0);
    assert(arguments_count <= c.lua_gettop(L));
    assert(results_count >= 0);
    if (c.lua_checkstack(L, 2) == 0) {
        pop(L, arguments_count);
        return .stack_overflow;
    }
    c.lua_pushcclosure(L, &Trampoline(Context, handler).call, 0);
    c.lua_pushlightuserdata(L, context);
    // The function and its context go under the arguments.
    c.lua_rotate(L, -arguments_count - 2, 2);
    return if (c.lua_pcallk(L, arguments_count + 1, results_count, 0, 0, null) == c.LUA_OK)
        .ok
    else
        .raised;
}

/// The C function `protect` and `tryCall` call. Its context is its first
/// argument, so the caller's arguments start at `trampoline_first_argument`.
fn Trampoline(comptime Context: type, comptime handler: fn (*State, *Context) void) type {
    return struct {
        fn call(L: ?*State) callconv(.c) c_int {
            const context: *Context = @ptrCast(@alignCast(c.lua_touserdata(L, 1)));
            const top_before = c.lua_gettop(L);
            handler(L.?, context);
            // Results are whatever `handler` left above its arguments.
            assert(c.lua_gettop(L) >= top_before);
            return c.lua_gettop(L) - top_before;
        }
    };
}

/// The stack index of the first argument a `tryCall` handler gets: index 1
/// holds the trampoline's context.
pub const trampoline_first_argument = 2;

fn traceback(L: ?*State) callconv(.c) c_int {
    const message = c.lua_tolstring(L, 1, null);
    if (message == null) {
        _ = c.lua_pushstring(L, "error (not a string)");
        return 1;
    }
    c.luaL_traceback(L, L, message, 1);
    return 1;
}

// ------------------------------------------- functions called from Lua

/// The error value (a message) is on the stack: raise it.
pub const Error = error{Raise};

/// A C function for Lua from `function`, which returns how many results it
/// pushed or `error.Raise` with the error message on the stack.
pub fn wrap(comptime function: fn (*State) Error!c_int) c.lua_CFunction {
    return &struct {
        fn call(L: ?*State) callconv(.c) c_int {
            const results_count = function(L.?) catch {
                // `fail` pushed the message raised.
                assert(c.lua_gettop(L) >= 1);
                return c.lua_error(L);
            };
            // Lua takes the top `results_count` values as the results,
            // unchecked in distribution builds: they must be there.
            assert(results_count >= 0);
            assert(results_count <= c.lua_gettop(L));
            return results_count;
        }
    }.call;
}

/// Pushes a message for `error.Raise`. Call it before acquiring anything
/// that needs cleaning up: pushing can itself raise (out of memory).
pub fn fail(L: *State, comptime format: []const u8, args: anytype) Error {
    pushFmt(L, format, args);
    return error.Raise;
}

/// Pushes a formatted string (cut at 512 bytes, between UTF-8 characters).
pub fn pushFmt(L: *State, comptime format: []const u8, args: anytype) void {
    var message_buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&message_buffer);
    writer.print(format, args) catch |err| switch (err) {
        error.WriteFailed => {},
    };
    const message = dropPartialTail(writer.buffered());
    _ = c.lua_pushlstring(L, message.ptr, message.len);
}

/// Drops an incomplete UTF-8 sequence at the very end of `text` (from a
/// fixed-buffer print that stopped mid-character).
fn dropPartialTail(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    var start = text.len - 1;
    var steps: usize = 0;
    while (start > 0 and steps < 3 and text[start] & 0xC0 == 0x80) {
        start -= 1;
        steps += 1;
    }
    const expected = std.unicode.utf8ByteSequenceLength(text[start]) catch return text;
    if (start + expected > text.len) return text[0..start];
    return text;
}

/// Raises a formatted error now. Only inside `protect` handlers and from
/// frames that own nothing.
pub fn raise(L: *State, comptime format: []const u8, args: anytype) noreturn {
    pushFmt(L, format, args);
    _ = c.lua_error(L);
    unreachable;
}

/// A function for `setFuncs`, written `.{ "name", function }` like the C
/// API's luaL_Reg.
pub const NamedFunction = struct { [:0]const u8, (fn (*State) Error!c_int) };

/// Sets each function, wrapped (`wrap`), as a field of the table on top.
pub fn setFuncs(L: *State, comptime functions: []const NamedFunction) void {
    inline for (functions) |entry| {
        const name, const function = entry;
        c.lua_pushcclosure(L, wrap(function), 0);
        c.lua_setfield(L, -2, name.ptr);
    }
}

/// Pushes element `number` (1-based) of the list at `list` and returns its
/// absolute index; raises unless it is a table (`where` names it).
pub fn tableAt(L: *State, list: c_int, number: usize, where: []const u8) c_int {
    if (c.lua_rawgeti(L, list, @intCast(number)) != c.LUA_TTABLE) {
        raise(L, "{s}: table expected, got {s}", .{ where, typeName(L, -1) });
    }
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

pub fn typeName(L: *State, index: c_int) []const u8 {
    return std.mem.span(c.lua_typename(L, c.lua_type(L, index)));
}

/// Whether nothing, or nil, is at `index` (Lua's `lua_isnoneornil`): an
/// optional argument left out.
pub fn isNoneOrNil(L: *State, index: c_int) bool {
    return c.lua_type(L, index) <= c.LUA_TNIL;
}

/// The string at `index` (not converted from a number), valid while the
/// value stays reachable.
pub fn toSlice(L: *State, index: c_int) ?[:0]const u8 {
    if (c.lua_type(L, index) != c.LUA_TSTRING) return null;
    var length: usize = 0;
    const bytes = c.lua_tolstring(L, index, &length) orelse return null;
    return bytes[0..length :0];
}

pub fn argString(L: *State, argument: c_int, function_name: []const u8) Error![:0]const u8 {
    return toSlice(L, argument) orelse fail(
        L,
        "bad argument #{d} to '{s}' (string expected, got {s})",
        .{ argument, function_name, typeName(L, argument) },
    );
}

pub fn argTable(L: *State, argument: c_int, function_name: []const u8) Error!void {
    if (c.lua_type(L, argument) == c.LUA_TTABLE) return;
    const type_name = typeName(L, argument);
    const format = "bad argument #{d} to '{s}' (table expected, got {s})";
    return fail(L, format, .{ argument, function_name, type_name });
}

pub fn pushString(L: *State, text: []const u8) void {
    _ = c.lua_pushlstring(L, text.ptr, text.len);
}

// ------------------------------------------------- reading Lua tables
// For `protect` handlers: these raise on a value of the wrong type, with
// `where` ("items[3]") in the message. Each one's doc comment says what it
// leaves on the stack: `getField`, `fieldList`, `tableAt` and `pushRef`
// push one value (`fieldList` none for nil); the readers of plain values
// (`fieldString`, `fieldBool`, `fieldNumber`) leave the stack as they
// found it.

/// The stack's height when a function started. A function that reads Lua
/// tables takes a mark first, then gives the stack back as it found it
/// (`defer mark.restore(L)`) or checks that it leaves what its caller
/// expects (`mark.expectPushed(L, count)`), instead of popping values one
/// by one with counts that are right only if every helper pushed what it
/// seemed to.
///
/// A `raise` (longjmp) skips the defers, `restore` included. That is safe
/// inside `protect`: it sets the stack back to its own entry height, which
/// is below every mark taken in the handler.
pub const StackMark = struct {
    top: c_int,

    pub fn init(L: *State) StackMark {
        return .{ .top = c.lua_gettop(L) };
    }

    /// Pops what was pushed since the mark. Never pops below it.
    pub fn restore(mark: StackMark, L: *State) void {
        assert(c.lua_gettop(L) >= mark.top);
        c.lua_settop(L, mark.top);
    }

    /// For a function whose contract is to leave `count` values pushed.
    pub fn expectPushed(mark: StackMark, L: *State, count: c_int) void {
        assert(c.lua_gettop(L) == mark.top + count);
    }
};

/// Pops `count` values, like the C API's `lua_pop` macro (translate-c does
/// not carry it over). For values a loop takes off one by one, such as the
/// value `lua_next` leaves above its key; a function that only has to leave
/// the stack as it found it uses `StackMark`.
pub fn pop(L: *State, count: c_int) void {
    assert(count >= 0);
    assert(c.lua_gettop(L) >= count);
    c.lua_settop(L, -count - 1);
}

/// Pushes `table[name]` and returns its type.
pub fn getField(L: *State, table: c_int, name: [:0]const u8) c_int {
    return c.lua_getfield(L, table, name.ptr);
}

/// Pushes `table[name]` when it is a table and returns its absolute index;
/// null, with nothing pushed, when it is nil. Raises on any other type.
pub fn fieldList(L: *State, table: c_int, name: [:0]const u8, where: []const u8) ?c_int {
    switch (getField(L, table, name)) {
        c.LUA_TTABLE => return c.lua_gettop(L),
        c.LUA_TNIL => {
            pop(L, 1);
            return null;
        },
        else => raise(L, "{s}.{s}: a list expected, got {s}", .{ where, name, typeName(L, -1) }),
    }
}

/// `table[name]` as a string copied into `arena`, or null when nil.
pub fn fieldString(
    L: *State,
    arena: std.mem.Allocator,
    table: c_int,
    name: [:0]const u8,
    where: []const u8,
) ?[:0]const u8 {
    return fieldStringMax(L, arena, table, name, where, std.math.maxInt(usize));
}

/// `fieldString` cut to at most `bytes_max` bytes, between UTF-8
/// characters.
pub fn fieldStringMax(
    L: *State,
    arena: std.mem.Allocator,
    table: c_int,
    name: [:0]const u8,
    where: []const u8,
    bytes_max: usize,
) ?[:0]const u8 {
    const mark: StackMark = .init(L);
    defer mark.restore(L);
    switch (getField(L, table, name)) {
        c.LUA_TNIL => return null,
        // A number reads as text: `subtitle = 42` is fine.
        c.LUA_TSTRING, c.LUA_TNUMBER => {},
        else => raise(L, "{s}.{s}: string expected, got {s}", .{ where, name, typeName(L, -1) }),
    }
    var length: usize = 0;
    const bytes = c.lua_tolstring(L, -1, &length);
    return arena.dupeSentinel(u8, cut(bytes[0..length], bytes_max), 0) catch oom(L);
}

/// `text` cut to at most `bytes_max` bytes, before the UTF-8 character
/// `bytes_max` falls in.
pub fn cut(text: []const u8, bytes_max: usize) []const u8 {
    if (text.len <= bytes_max) return text;
    var length = bytes_max;
    while (length > 0 and text[length] & 0xC0 == 0x80) length -= 1;
    return text[0..length];
}

/// `table[name]` as a boolean (nil is `default`).
pub fn fieldBool(
    L: *State,
    table: c_int,
    name: [:0]const u8,
    default: bool,
    where: []const u8,
) bool {
    const mark: StackMark = .init(L);
    defer mark.restore(L);
    return switch (getField(L, table, name)) {
        c.LUA_TNIL => default,
        c.LUA_TBOOLEAN => c.lua_toboolean(L, -1) != 0,
        else => raise(L, "{s}.{s}: boolean expected, got {s}", .{ where, name, typeName(L, -1) }),
    };
}

/// `table[name]` as a number (nil is null).
pub fn fieldNumber(L: *State, table: c_int, name: [:0]const u8, where: []const u8) ?f64 {
    const mark: StackMark = .init(L);
    defer mark.restore(L);
    return switch (getField(L, table, name)) {
        c.LUA_TNIL => null,
        c.LUA_TNUMBER => c.lua_tonumberx(L, -1, null),
        else => raise(L, "{s}.{s}: number expected, got {s}", .{ where, name, typeName(L, -1) }),
    };
}

/// `table[name]` as a number from `range.min` to `range.max` (inclusive),
/// or null when nil; raises otherwise.
pub fn fieldNumberIn(
    L: *State,
    table: c_int,
    name: [:0]const u8,
    where: []const u8,
    range: struct { min: f64, max: f64 },
) ?f64 {
    const number = fieldNumber(L, table, name, where) orelse return null;
    if (!inRange(number, range.min, range.max)) {
        raise(L, "{s}.{s}: {d} to {d}", .{ where, name, range.min, range.max });
    }
    return number;
}

/// Whether `number` is from `min` to `max`. False for NaN, which Lua
/// numbers may be (0/0): written the other way round, `number < min or
/// number > max` lets NaN through, and turning it into an integer is then
/// illegal behaviour.
pub fn inRange(number: f64, min: f64, max: f64) bool {
    return number >= min and number <= max;
}

pub fn absIndex(L: *State, index: c_int) c_int {
    return c.lua_absindex(L, index);
}

/// A reference to the value on top (popped), for `pushRef` later.
pub fn ref(L: *State) c_int {
    return c.luaL_ref(L, c.LUA_REGISTRYINDEX);
}

pub fn unref(L: *State, reference: c_int) void {
    c.luaL_unref(L, c.LUA_REGISTRYINDEX, reference);
}

/// Pushes the value `reference` names and returns its type.
pub fn pushRef(L: *State, reference: c_int) c_int {
    return c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, reference);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testState(budget: *Budget) !*State {
    const L = newState(budget) orelse return error.OutOfMemory;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Handler = struct {
        fn open(state: *State, _: *u8) void {
            openLibs(state);
        }
    };
    var unused: u8 = 0;
    if (protect(L, arena.allocator(), u8, &unused, Handler.open)) |message| {
        std.debug.print("{s}\n", .{message});
        return error.TestUnexpectedResult;
    }
    return L;
}

/// Runs `code` and returns its error message (null when it succeeded).
fn runCode(L: *State, arena: std.mem.Allocator, code: [:0]const u8) ?[:0]const u8 {
    const Context = struct {
        code: [:0]const u8,
        fn run(state: *State, context: *@This()) void {
            if (c.luaL_loadstring(state, context.code.ptr) != c.LUA_OK) _ = c.lua_error(state);
            c.lua_callk(state, 0, 0, 0, null);
        }
    };
    var context: Context = .{ .code = code };
    return protect(L, arena, Context, &context, Context.run);
}

test "errors come back as messages, and the sandbox holds" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(runCode(L, arena, "x = 1 + 1") == null);
    const message = runCode(L, arena, "error('boom')").?;
    try testing.expect(std.mem.find(u8, message, "boom") != null);
    try testing.expect(std.mem.find(u8, message, "traceback") != null);
    // Nothing that ends the daemon or runs native code is reachable.
    try testing.expect(
        runCode(
            L,
            arena,
            "assert(os.exit == nil and os.execute == nil and io.popen == nil)",
        ) == null,
    );
    try testing.expect(
        runCode(
            L,
            arena,
            "assert(debug == nil and package.loadlib == nil and package.cpath == '')",
        ) == null,
    );
    try testing.expect(
        runCode(L, arena, "assert(string.format('%d', 3) == '3' and os.time() > 0)") == null,
    );
    try testing.expectEqual(@as(c_int, 0), c.lua_gettop(L));
}

test "loops in C stop at the deadline too: table.move and patterns" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Each of these ran in C for seconds to forever, never reaching the
    // instruction hook.
    const runaways = [_][:0]const u8{
        "table.move({}, 1, math.maxinteger - 1, 2)",
        "string.find(('a'):rep(40), ('a-'):rep(20) .. 'b')",
        "string.match(('a'):rep(40), ('a-'):rep(20) .. 'b')",
        "for _ in string.gmatch(('a'):rep(40), ('a-'):rep(20) .. 'b') do end",
        "string.gsub(('a'):rep(40), ('a-'):rep(20) .. 'b', '')",
        "local s = ('a'):rep(40) s:find(('a-'):rep(20) .. 'b')",
        "('a'):rep(1e6):find(('a'):rep(1e5) .. 'b', 1, true)",
        "('a'):rep(1e6):find(('a'):rep(1e5) .. 'b')",
        "('('):rep(1e6):find('%b()')",
        "('a'):rep(1e6):find('a*b')",
    };
    for (runaways) |code| {
        budget.deadline_ns = os.monotonicNs() + 50 * std.time.ns_per_ms;
        const start_ns = os.monotonicNs();
        const message = runCode(L, arena, code) orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.find(u8, message, "timed out") != null);
        try testing.expect(os.monotonicNs() - start_ns < 2 * std.time.ns_per_s);
    }
    // With time left they work as before, overlapping moves included.
    budget.deadline_ns = std.math.maxInt(u64);
    const checks =
        \\local t = {} for i = 1, 10000 do t[i] = i end
        \\table.move(t, 1, 9000, 2)
        \\assert(t[1] == 1 and t[2] == 1 and t[9001] == 9000 and t[10000] == 10000)
        \\table.move(t, 2, 9001, 1)
        \\assert(t[1] == 1 and t[9000] == 9000)
        \\local u = table.move(t, 1, 5000, 1, {})
        \\assert(#u == 5000 and u[5000] == 5000)
        \\assert(("hello world"):find("o w") == 5)
        \\assert(("key=value"):match("(%w+)=(%w+)") == "key")
        \\assert(select(2, ("a,b,c"):gsub(",", ";")) == 2)
        \\local n = 0 for w in ("one two three"):gmatch("%a+") do n = n + 1 end
        \\assert(n == 3)
        \\assert(("x"):rep(3):find("x", 1, true) == 1)
    ;
    try testing.expect(runCode(L, arena, checks) == null);
}

/// Descriptors of this process without close-on-exec.
fn inheritableFds() usize {
    const linux = std.os.linux;
    var count: usize = 0;
    var fd: i32 = 0;
    while (fd < 4096) : (fd += 1) {
        const flags = linux.fcntl(fd, linux.F.GETFD, 0);
        if (linux.errno(flags) != .SUCCESS) continue;
        if (flags & linux.FD_CLOEXEC == 0) count += 1;
    }
    return count;
}

test "a process's memory under /proc is not opened, even through a symlink" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buffer: [512]u8 = undefined;
    const dir_path = try os.tmpDirPath(&test_dir, &path_buffer);
    const link = try std.fmt.allocPrintSentinel(arena, "{s}/x", .{dir_path}, 0);
    const linux = std.os.linux;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlink("/proc/self/mem", link)));

    const code = try std.fmt.allocPrintSentinel(arena,
        \\local link = "{s}"
        \\for _, path in ipairs({{ "/proc/self/mem", link }}) do
        \\  for _, mode in ipairs({{ "r+", "r", "w" }}) do
        \\    local f, why = io.open(path, mode)
        \\    assert(f == nil and why:find("not a regular file"), tostring(why))
        \\  end
        \\  local lok, lwhy = pcall(loadfile, path)
        \\  assert(not lok and tostring(lwhy):find("not a regular file"), tostring(lwhy))
        \\  local ok, derr = pcall(dofile, path)
        \\  assert(not ok and tostring(derr):find("not a regular file"), tostring(derr))
        \\end
        \\assert(io.open("/proc/self/status", "r")):close()
    , .{link}, 0);
    if (runCode(L, arena, code)) |message| {
        std.debug.print("{s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

test "extensions open files close-on-exec, and only so many at once" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inheritable_before = inheritableFds();
    const fill =
        \\files = {}
        \\for i = 1, 64 do files[i] = assert(io.open("/dev/null")) end
        \\local extra, why = io.open("/dev/null")
        \\assert(extra == nil and why:find("too many files"))
        \\assert(io.tmpfile() == nil)
    ;
    try testing.expect(runCode(L, arena, fill) == null);
    try testing.expectEqual(@as(u32, open_files_max), budget.open_files);
    // None of them reaches a program lumen.exec starts.
    try testing.expectEqual(inheritable_before, inheritableFds());
    const release =
        \\files[1]:close(); io.close(files[2]); files[3] = nil
        \\collectgarbage()
        \\local again = assert(io.open("/dev/null")); again:close()
        \\for i = 4, 64 do files[i]:close() end
        \\files = nil
        \\local n = 0 for _ in io.lines("/proc/self/status") do n = n + 1 end
        \\assert(n > 0)
        \\for line in io.lines("/proc/self/status") do break end
    ;
    try testing.expect(runCode(L, arena, release) == null);
    _ = c.lua_gc(L, c.LUA_GCCOLLECT, @as(c_int, 0));
    // Closed, collected, or read to their end: every slot came back.
    try testing.expectEqual(@as(u32, 0), budget.open_files);

    // io.tmpfile opens atomically close-on-exec, is usable for R/W, and is counted.
    const tmp_check =
        \\local f = assert(io.tmpfile())
        \\assert(f:write("tmp-ok"))
        \\assert(f:seek("set", 0))
        \\assert(f:read("*a") == "tmp-ok")
        \\tmp_held = f
    ;
    try testing.expect(runCode(L, arena, tmp_check) == null);
    try testing.expectEqual(@as(u32, 1), budget.open_files);
    try testing.expectEqual(inheritable_before, inheritableFds());
    try testing.expect(runCode(L, arena, "tmp_held:close(); tmp_held = nil") == null);
    try testing.expectEqual(@as(u32, 0), budget.open_files);
}

test "a cancelled state stops at once, and long errors are cut" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel: std.atomic.Value(bool) = .init(true);
    budget.cancel = &cancel;
    const start_ns = os.monotonicNs();
    const stopped = runCode(L, arena, "while true do end") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.find(u8, stopped, "timed out") != null);
    try testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);
    cancel.store(false, .release);
    const long = runCode(
        L,
        arena,
        "error(('x'):rep(1000000))",
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(long.len <= error_message_bytes_max);
}

test "a runaway loop stops at its deadline" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    budget.deadline_ns = os.monotonicNs() + 50 * std.time.ns_per_ms;
    const start_ns = os.monotonicNs();
    const message = runCode(L, arena_state.allocator(), "while true do end").?;
    try testing.expect(std.mem.find(u8, message, "timed out") != null);
    try testing.expect(os.monotonicNs() - start_ns < 2 * std.time.ns_per_s);

    // `pcall`, `xpcall`, and coroutines cannot swallow a timeout.
    budget.deadline_ns = os.monotonicNs() + 50 * std.time.ns_per_ms;
    const pcall_msg = runCode(
        L,
        arena_state.allocator(),
        "repeat local ok = pcall(function() while true do end end) until ok",
    ).?;
    try testing.expect(std.mem.find(u8, pcall_msg, "timed out") != null);

    budget.deadline_ns = os.monotonicNs() + 50 * std.time.ns_per_ms;
    const co_msg = runCode(
        L,
        arena_state.allocator(),
        "local co = coroutine.create(function() while true do end end) repeat local ok = coroutine.resume(co) until ok",
    ).?;
    try testing.expect(std.mem.find(u8, co_msg, "timed out") != null);

    // State remains usable once deadline is restored.
    budget.deadline_ns = std.math.maxInt(u64);
    try testing.expect(runCode(
        L,
        arena_state.allocator(),
        "assert(pcall(function() return 1 end))",
    ) == null);
}

test "memory is capped per state" {
    var budget: Budget = .{ .bytes_max = 4 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const message = runCode(
        L,
        arena_state.allocator(),
        "local t = {} for i = 1, 1e8 do t[i] = ('x'):rep(100) .. i end",
    ).?;
    try testing.expect(std.mem.find(u8, message, "memory") != null);
    try testing.expect(budget.used_bytes <= budget.bytes_max);
    // Still usable afterwards.
    try testing.expect(runCode(L, arena_state.allocator(), "x = 1") == null);
}

test "what the time limit cannot stop is out of reach" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A finalizer runs with the instruction hook off: none can be set.
    const finalizer = "setmetatable({}, { __gc = function() while true do end end })";
    const gc_error = runCode(L, arena, finalizer).?;
    try testing.expect(std.mem.find(u8, gc_error, "__gc is not available") != null);
    try testing.expect(runCode(L, arena, "setmetatable({}, { __gc = false })") != null);
    try testing.expect(runCode(
        L,
        arena,
        "local t = setmetatable({}, { __index = string }) assert(t.rep == string.rep)",
    ) == null);
    // Nor through the files' metatable, which every open file is marked by.
    try testing.expect(runCode(L, arena, "assert(getmetatable(io.stdout) == false)") == null);
    try testing.expect(runCode(L, arena, "io.stdout:write('')") == null);
    // The daemon's standard input reads as empty.
    try testing.expect(runCode(
        L,
        arena,
        "assert(io.stdin == nil and io.read() == nil and io.lines()() == nil)",
    ) == null);
    const dofile_error = runCode(L, arena, "dofile()").?;
    try testing.expect(std.mem.find(u8, dofile_error, "file name expected") != null);

    // A FIFO would wait for a writer forever; regular and missing files
    // behave as usual.
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buffer: [512]u8 = undefined;
    const dir_path = try os.tmpDirPath(&test_dir, &path_buffer);
    const fifo = try std.fmt.allocPrintSentinel(arena, "{s}/fifo", .{dir_path}, 0);
    const linux = std.os.linux;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(
        linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0),
    ));
    const code = try std.fmt.allocPrintSentinel(arena,
        \\local fifo = "{s}"
        \\local f, err = io.open(fifo)
        \\assert(f == nil and err:find("not a regular file"), err)
        \\local fw, werr = io.open(fifo, "w")
        \\assert(fw == nil and werr:find("not a regular file"), werr)
        \\assert(not pcall(io.lines, fifo) and not pcall(io.output, fifo) and not pcall(dofile, fifo))
        \\local mf, merr, mcode = io.open(fifo .. ".missing")
        \\assert(mf == nil and mcode == 2)
        \\local w = assert(io.open(fifo .. ".txt", "w")) w:write("hi") w:close()
        \\assert(io.open(fifo .. ".txt"):read("a") == "hi")
        \\assert(io.open("/dev/null"):read("a") == "")
        \\-- Binary bytecode is refused by load, loadfile, dofile and require.
        \\local bin = string.dump(function() return 1 end)
        \\assert(load(bin) == nil)
        \\assert(load(bin, "x", "b") == nil)
        \\assert(load(bin, "x", "bt") == nil)
        \\local bf = assert(io.open(fifo .. ".luac", "wb")) bf:write(bin) bf:close()
        \\assert(loadfile(fifo .. ".luac") == nil)
        \\assert(loadfile(fifo .. ".luac", "bt") == nil)
        \\assert(not pcall(dofile, fifo .. ".luac"))
        \\package.path = fifo .. ".?"
        \\assert(not pcall(require, "luac"))
        \\-- require also refuses FIFOs.
        \\package.path = fifo
        \\local rok, rerr = pcall(require, "anything")
        \\assert(not rok and tostring(rerr):find("not a regular file"), tostring(rerr))
    , .{fifo}, 0);
    if (runCode(L, arena, code)) |message| {
        std.debug.print("{s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

test "a capped allocator holds no more than its cap" {
    var capped: Capped = .{ .child = testing.allocator, .bytes_max = 1000 };
    const allocator = capped.allocator();
    const first = try allocator.alloc(u8, 600);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 600));
    try testing.expect(capped.refused);
    allocator.free(first);
    try testing.expectEqual(@as(usize, 0), capped.used_bytes);
    // Growing counts too.
    var second = try allocator.alloc(u8, 900);
    try testing.expectError(error.OutOfMemory, allocator.realloc(second, 1200));
    second = try allocator.realloc(second, 1000);
    try testing.expectEqual(@as(usize, 1000), capped.used_bytes);
    allocator.free(second);
    try testing.expectEqual(@as(usize, 0), capped.used_bytes);
}

test "NaN is in no range" {
    try testing.expect(inRange(2, 2, 10));
    try testing.expect(!inRange(11, 2, 10));
    try testing.expect(!inRange(std.math.nan(f64), 2, 10));
}

test "strings are cut between characters" {
    try testing.expectEqualStrings("abc", cut("abc", 5));
    try testing.expectEqualStrings("ab", cut("abc", 2));
    // "é" is two bytes: cutting inside it drops it whole.
    try testing.expectEqualStrings("a", cut("aé", 2));
    try testing.expectEqualStrings("aé", cut("aéz", 3));
}

test "pushFmt never reads uninitialized tail bytes and keeps UTF-8 valid" {
    var budget: Budget = .{ .bytes_max = 8 << 20 };
    const L = try testState(&budget);
    defer c.lua_close(L);

    // 510 'a' bytes + 3-byte '€' overflows the 512-byte buffer mid-character.
    var prefix: [510]u8 = @splat('a');
    pushFmt(L, "{s}€", .{&prefix});
    const pushed = toSlice(L, -1).?;
    try testing.expectEqual(@as(usize, 510), pushed.len);
    try testing.expect(std.unicode.utf8ValidateSlice(pushed));
    pop(L, 1);

    // A number that fails to fit near the end leaves only the written prefix.
    var prefix2: [508]u8 = @splat('b');
    pushFmt(L, "{s}{d}", .{ &prefix2, @as(u64, 1234567890) });
    const pushed2 = toSlice(L, -1).?;
    try testing.expect(pushed2.len >= 508 and pushed2.len <= 512);
    try testing.expectEqualStrings(&prefix2, pushed2[0..508]);
    for (pushed2[508..]) |ch| try testing.expect(std.ascii.isDigit(ch));
    pop(L, 1);
}
