//! What a reload collects from the files as they run: commands, themes,
//! keymaps, setting overrides, preferences, icons, the layout, the
//! extensions that loaded and the problems found. It becomes the new
//! registry (`Host.Registry`), and lives in that registry's arena.
//!
//! Worker thread only. A file adds to it while it runs (api.zig's
//! `lumen.theme`, `lumen.set`... and spec.zig for what `lumen.extension`
//! returned); `mark` and `rollback` drop what a file added if it fails
//! half-way, so a broken extension leaves nothing behind.

const std = @import("std");
const Theme = @import("../ui/themes.zig").Theme;
const layout_mod = @import("../layout.zig");
const registry_mod = @import("registry.zig");
const WorkerCommand = @import("requests.zig").WorkerCommand;

const Load = @This();

const log = std.log.scoped(.ext);
const assert = std.debug.assert;

const Command = registry_mod.Command;
const Keymap = registry_mod.Keymap;
const SettingOverride = registry_mod.SettingOverride;
const Preference = registry_mod.Preference;
const IconOverride = registry_mod.IconOverride;
const ExtensionInfo = registry_mod.ExtensionInfo;
const Problem = registry_mod.Problem;

arena: std.mem.Allocator,
commands: std.ArrayList(Command) = .empty,
/// Parallel to `commands`: where the worker finds each one.
worker_commands: std.ArrayList(WorkerCommand) = .empty,
themes: std.ArrayList(Theme) = .empty,
keymaps: std.ArrayList(Keymap) = .empty,
settings: std.ArrayList(SettingOverride) = .empty,
preferences: std.ArrayList(Preference) = .empty,
icons: std.ArrayList(IconOverride) = .empty,
extensions: std.ArrayList(ExtensionInfo) = .empty,
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
    "preferences",
    "icons",
    "style_settings",
};

/// How far each list of `undone` had grown before a file ran.
pub const Mark = struct {
    lengths: [undone.len]usize,
    layout: layout_mod.Layout,
    has_layout: bool,
};

pub fn mark(load: *const Load) Mark {
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
pub fn rollback(load: *Load, saved: Mark) void {
    inline for (undone, 0..) |field, index| {
        assert(saved.lengths[index] <= @field(load, field).items.len);
        @field(load, field).shrinkRetainingCapacity(saved.lengths[index]);
    }
    load.layout = saved.layout;
    load.has_layout = saved.has_layout;
    assert(load.commands.items.len == load.worker_commands.items.len);
}

/// The commands added since `saved`.
pub fn commandsSince(load: *const Load, saved: Mark) usize {
    comptime assert(std.mem.eql(u8, undone[0], "commands"));
    return load.commands.items.len - saved.lengths[0];
}

/// Reports what went wrong with a file in Settings > Extensions. Out of
/// memory, the report goes to the log instead, so it is never lost.
pub fn problem(load: *Load, extension_id: []const u8, message: []const u8) void {
    load.problemAppend(extension_id, message) catch {
        log.warn("{s}: {s} (not shown in Settings: out of memory)", .{ extension_id, message });
    };
}

fn problemAppend(
    load: *Load,
    extension_id: []const u8,
    message: []const u8,
) error{OutOfMemory}!void {
    const extension_id_copy = try load.arena.dupeSentinel(u8, extension_id, 0);
    const message_copy = try load.arena.dupeSentinel(u8, message, 0);
    try load.problems.append(load.arena, .{
        .extension = extension_id_copy,
        .message = message_copy,
    });
}

/// Lists an extension that loaded in Settings > Extensions. Out of memory,
/// it is reported as a problem instead: an entry with an empty id would
/// reach the views that act on an extension by its id.
pub fn extensionLoaded(
    load: *Load,
    id: []const u8,
    title: [:0]const u8,
    commands_count: usize,
) void {
    load.extensionLoadedAppend(id, title, commands_count) catch {
        load.problem(id, "loaded, but out of memory to list it");
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
