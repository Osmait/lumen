//! Script commands from ~/.config/lumen/scripts.

const std = @import("std");
const c = @import("c");
const script_meta = @import("core").script_meta;
const os = @import("os");
const Item = @import("../item.zig").Item;

/// ~/.config/lumen/scripts, in `a`; null only when out of memory.
pub fn dir(a: std.mem.Allocator) ?[:0]const u8 {
    const config = std.mem.span(c.g_get_user_config_dir());
    return a.printSentinel("{s}/lumen/scripts", .{config}, 0) catch null;
}

/// The last scan's scripts, and what the folder looked like then: the root
/// view is built on every show, and each scan read every script. Main
/// thread only.
var cache_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
var cache_items: []Item = &.{};
var cache_stamp: ?u64 = null;

/// The scripts, in `a`: scanned again only when a file in the folder was
/// added, removed, renamed or written since the last time.
pub fn load(a: std.mem.Allocator) []Item {
    const now = stamp(a);
    if (cache_stamp == null or cache_stamp.? != now) {
        _ = cache_arena.reset(.retain_capacity);
        cache_items = scan(cache_arena.allocator());
        cache_stamp = now;
    }
    const out = a.alloc(Item, cache_items.len) catch return &.{};
    for (cache_items, out) |it, *o| o.* = copy(a, it) catch return out[0..0];
    return out;
}

/// The cached item with its strings in `a`.
fn copy(a: std.mem.Allocator, it: Item) std.mem.Allocator.Error!Item {
    var o = it;
    o.key = try a.dupe(u8, it.key);
    o.title = try a.dupeSentinel(u8, it.title, 0);
    o.subtitle = try a.dupeSentinel(u8, it.subtitle, 0);
    o.keywords = try a.dupe(u8, it.keywords);
    if (it.icon == .emoji) o.icon = .{ .emoji = try a.dupeSentinel(u8, it.icon.emoji, 0) };
    o.action = .{ .script = .{
        .path = try a.dupeSentinel(u8, it.action.script.path, 0),
        .mode = it.action.script.mode,
    } };
    return o;
}

/// Names, sizes and mtimes of the folder's files.
fn stamp(a: std.mem.Allocator) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    const path = dir(a) orelse return 0;
    const d = c.g_dir_open(path.ptr, 0, null) orelse return 1;
    defer c.g_dir_close(d);
    var buf: [4096]u8 = undefined;
    while (c.g_dir_read_name(d)) |name_c| {
        const name = std.mem.span(name_c);
        hasher.update(name);
        const full = std.mem.printSentinel(&buf, "{s}/{s}", .{ path, name }, 0) catch continue;
        if (os.info(full)) |i| hasher.update(std.mem.asBytes(&.{ i.mtime, i.size }));
    }
    return hasher.final();
}

/// Scans the scripts directory. Everything lives in `a`.
fn scan(a: std.mem.Allocator) []Item {
    const path = dir(a) orelse return &.{};
    const d = c.g_dir_open(path.ptr, 0, null) orelse return &.{};
    defer c.g_dir_close(d);

    var items: std.ArrayList(Item) = .empty;
    while (c.g_dir_read_name(d)) |name_c| {
        const name = std.mem.span(name_c);
        if (name.len == 0 or name[0] == '.') continue;
        const full = a.printSentinel("{s}/{s}", .{ path, name }, 0) catch continue;

        // The header is all that is read of it.
        var head_buf: [4096]u8 = undefined;
        const head = os.readHead(full.ptr, &head_buf);
        const meta = script_meta.parse(head) orelse continue;

        const emoji = meta.icon.len > 0 and meta.icon.len <= 8 and meta.icon[0] >= 0x80;
        items.append(a, .{
            .key = a.print("script:{s}", .{name}) catch continue,
            .title = a.dupeSentinel(u8, meta.title, 0) catch continue,
            .subtitle = a.dupeSentinel(
                u8,
                if (meta.package_name.len > 0) meta.package_name else "Script Command",
                0,
            ) catch continue,
            .accessory = "Script",
            .keywords = a.dupe(u8, meta.description) catch "",
            .confirm = meta.needs_confirmation,
            .icon = if (emoji)
                .{ .emoji = a.dupeSentinel(u8, meta.icon, 0) catch "" }
            else
                .{ .tile = .{ .name = "utilities-terminal-symbolic", .color = .gray } },
            .action = .{ .script = .{ .path = full, .mode = meta.mode } },
        }) catch continue;
    }
    return items.toOwnedSlice(a) catch &.{};
}
