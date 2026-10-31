//! One loaded file (init.lua, the style or an extension) and its Lua state.
//! Worker thread only.
//!
//! The host creates one per file on reload, keeps those whose file ran in
//! `Host.extensions` and destroys them all on the next reload. Every call
//! into the state goes through `run`, which gives it a deadline and a
//! protected call. api.zig finds its extension from the state's registry
//! (`lumen` functions run on behalf of it).

const std = @import("std");
const lua = @import("luart").lua;
const os = @import("os");
const Host = @import("Host.zig");
const Load = @import("Load.zig");

const Extension = @This();

const log = std.log.scoped(.ext);

/// The memory each state may hold.
const memory_bytes_max = 64 << 20;
/// For anything Lua still runs as a state closes (lumen.exec waits no
/// longer than this).
const close_budget_ns = 1 * std.time.ns_per_s;

budget: lua.Budget = .{ .bytes_max = memory_bytes_max },
L: *lua.State = undefined,
host: *Host,
id: [:0]const u8,
folder: [:0]const u8,
/// Its storage and preferences: $XDG_DATA_HOME/lumen/extensions/<id>.
data: [:0]const u8,
/// Set only while this extension's file runs: `lumen.theme`,
/// `lumen.keymap`, `lumen.set`, `lumen.layout` and `lumen.icons` add
/// to it. Null at any other time, which those functions report as an
/// error.
load: ?*Load = null,

/// A new state for the file of extension `id` in `folder`; null when out of
/// memory. Its names live in the host's worker arena, so until the next
/// reload.
pub fn create(host: *Host, id: []const u8, folder: []const u8) ?*Extension {
    const worker_arena = host.worker_arena.allocator();
    // Never an empty data folder: its storage would go to "/storage.json".
    const data = worker_arena.printSentinel("{s}/extensions/{s}", .{ host.data_dir, id }, 0) catch
        return null;
    const id_copy = worker_arena.dupeSentinel(u8, id, 0) catch return null;
    const folder_copy = worker_arena.dupeSentinel(u8, folder, 0) catch return null;
    const extension = host.gpa.create(Extension) catch return null;
    extension.* = .{ .host = host, .id = id_copy, .folder = folder_copy, .data = data };
    // Without it, the extension runs; lumen.storage fails and says so.
    os.mkdirP(extension.data) catch |err| log.warn("{s}: {t}", .{ extension.data, err });
    extension.L = lua.newState(&extension.budget) orelse {
        host.gpa.destroy(extension);
        return null;
    };
    return extension;
}

/// Closes its state and frees it. Closing runs the finalizers left, with
/// the instruction hook off (Lua turns hooks off in `__gc`); extensions
/// cannot set any (lua.openLibs), and lumen.exec gets a deadline anyway.
pub fn destroy(extension: *Extension) void {
    extension.budget.deadline_ns = os.monotonicNs() + close_budget_ns;
    lua.c.lua_close(extension.L);
    extension.host.gpa.destroy(extension);
}

pub fn gpa(extension: *Extension) std.mem.Allocator {
    return extension.host.gpa;
}

pub fn io(extension: *Extension) std.Io {
    return extension.host.io;
}

/// Runs `handler` in this state, protected, with `budget_ns` to finish
/// (the instruction hook stops it past that). Its error, or null.
pub fn run(
    extension: *Extension,
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
