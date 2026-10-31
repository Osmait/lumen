//! Reloading, on the worker: every state of the last load is closed, then
//! each file runs in a new one (the style, init.lua, each extension in
//! turn), and what they defined becomes a new registry for the window.
//!
//! A file that fails (an error, its deadline, out of memory) is reported
//! as a problem and leaves nothing behind: what it added to the `Load` is
//! rolled back and its state closed. The others load regardless.

const std = @import("std");
const lua = @import("luart").lua;
const os = @import("os");
const styles = @import("styles");
const Host = @import("Host.zig");
const Extension = @import("Extension.zig");
const Load = @import("Load.zig");
const api = @import("api.zig");
const spec = @import("spec.zig");
const registry_mod = @import("registry.zig");
const WorkerCommand = @import("requests.zig").WorkerCommand;

const log = std.log.scoped(.ext);
const assert = std.debug.assert;

const Registry = registry_mod.Registry;
const config_extension_id = registry_mod.config_extension_id;
const style_extension_id = registry_mod.style_extension_id;

/// How long a file may run as it loads before the instruction hook stops
/// it.
const load_budget_ns = 5 * std.time.ns_per_s;

/// Closes every state and forgets the commands of the registry they made.
pub fn closeAll(host: *Host) void {
    for (host.extensions.items) |extension| extension.destroy();
    host.extensions.clearRetainingCapacity();
    host.gpa.free(host.worker_commands);
    host.worker_commands = &.{};
    _ = host.worker_arena.reset(.retain_capacity);
}

/// Loads every file again into new states, and delivers the new registry.
pub fn reloadExecute(host: *Host) void {
    closeAll(host);
    host.registry_generation = host.registry_generation.next();
    const registry = host.answerCreate(Registry, "reload", .{
        .generation = host.registry_generation,
        .arena = .init(host.gpa),
    }) orelse return;
    var load: Load = .{ .arena = registry.arena.allocator() };
    loadAll(host, &load);
    registryFill(host, registry, &load);
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
            load.problem(style_extension_id, "out of memory");
            break :blk "";
        };
    };
    if (style.len > 0) loadStyle(host, load, style);

    if (worker_arena.printSentinel("{s}/init.lua", .{host.config_dir}, 0)) |path| {
        if (os.info(path) != null) {
            loadSource(host, load, config_extension_id, host.config_dir, path, null);
        }
    } else |_| {
        load.problem(config_extension_id, "out of memory");
    }

    for (extensionDirs(host, worker_arena)) |id| loadExtension(host, load, id);
}

/// The extension in extensions/<id>, when its folder name is one.
fn loadExtension(host: *Host, load: *Load, id: [:0]const u8) void {
    const worker_arena = host.worker_arena.allocator();
    if (!Host.validId(id)) {
        load.problem(id, "extension folder names may use only a-z, 0-9, - and _");
        return;
    }
    if (Host.reservedId(id)) {
        const message =
            "\"config\" and \"style\" are taken (init.lua and the style); rename the folder";
        load.problem(id, message);
        return;
    }
    const folder_format = "{s}/extensions/{s}";
    const folder = worker_arena.printSentinel(folder_format, .{ host.config_dir, id }, 0) catch {
        load.problem(id, "out of memory");
        return;
    };
    const path = worker_arena.printSentinel("{s}/init.lua", .{folder}, 0) catch {
        load.problem(id, "out of memory");
        return;
    };
    if (os.info(path) == null) {
        load.problem(id, "no init.lua in the extension's folder");
        return;
    }
    loadSource(host, load, id, folder, path, null);
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

/// A style: <config>/styles/<name>/init.lua, else the built-in one. Its
/// file runs as the extension "style".
fn loadStyle(host: *Host, load: *Load, name: []const u8) void {
    const worker_arena = host.worker_arena.allocator();
    const folder = worker_arena.printSentinel("{s}/styles/{s}", .{ host.config_dir, name }, 0) catch
        return;
    const path = worker_arena.printSentinel("{s}/init.lua", .{folder}, 0) catch return;
    if (os.info(path) != null) {
        loadSource(host, load, style_extension_id, folder, path, null);
    } else if (os.info(folder) != null) {
        // A style folder may hold only a style.css.
    } else if (styles.find(name)) |built_in| {
        loadSource(host, load, style_extension_id, host.config_dir, "=style", built_in.lua);
    } else {
        load.problem(style_extension_id, "no such style");
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
        load.problem(id, "out of memory");
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
            if (!Host.reservedId(id)) {
                load.extensionLoaded(id, context.title, load.commandsSince(before));
            }
            return;
        } else |_| {
            // Out of memory: undone below, like a file that failed.
        }
    }
    load.rollback(before);
    load.problem(id, failure orelse "out of memory");
    extension.destroy();
}

pub const LoadContext = struct {
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
            lua.c.LUA_TTABLE => spec.parseExtension(L, context, lua.absIndex(L, -1)),
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
