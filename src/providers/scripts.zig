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
/// Null until the first scan.
var cache_stamp: ?FolderStamp = null;

const log = std.log.scoped(.scripts);

/// The scripts, in `arena`: scanned again only when a file in the folder
/// was added, removed, renamed or written since the last time.
pub fn load(arena: std.mem.Allocator) []Item {
    const path = dir(arena) orelse return &.{};
    const folder_stamp = stamp(path);
    const cached = if (cache_stamp) |last| std.meta.eql(last, folder_stamp) else false;
    if (!cached) {
        _ = cache_arena.reset(.retain_capacity);
        cache_items = scan(cache_arena.allocator(), path);
        cache_stamp = folder_stamp;
    }
    const items = arena.alloc(Item, cache_items.len) catch return &.{};
    for (cache_items, items, 0..) |cached_item, *item, copied| {
        item.* = copy(arena, cached_item) catch {
            log.warn("out of memory: {d} of {d} scripts listed", .{ copied, items.len });
            return items[0..copied];
        };
    }
    return items;
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

/// What the scripts folder looked like: whether it exists, and a hash of
/// its files' names, sizes and mtimes. A tagged union rather than special
/// hash values: any u64 is a possible hash.
const FolderStamp = union(enum) {
    missing,
    hashed: u64,
};

/// The folder at `path` as it is now.
fn stamp(path: [:0]const u8) FolderStamp {
    const dir_handle = c.g_dir_open(path.ptr, 0, null) orelse return .missing;
    defer c.g_dir_close(dir_handle);
    var hasher: std.hash.Wyhash = .init(0);
    var path_buffer: [4096]u8 = undefined;
    while (c.g_dir_read_name(dir_handle)) |name_c| {
        const name = std.mem.span(name_c);
        hasher.update(name);
        const file_path = std.mem.printSentinel(
            &path_buffer,
            "{s}/{s}",
            .{ path, name },
            0,
        ) catch continue;
        if (os.info(file_path)) |file_info| {
            hasher.update(std.mem.asBytes(&.{ file_info.mtime, file_info.size }));
        }
    }
    return .{ .hashed = hasher.final() };
}

/// Scans the scripts directory at `path`. Everything lives in `a`.
fn scan(a: std.mem.Allocator, path: [:0]const u8) []Item {
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

test "a missing folder and an empty one stamp differently, and edits show" {
    var test_dir = try os.TestDir.init();
    defer test_dir.deinit();
    var path_buffer: [4096]u8 = undefined;

    const missing = try test_dir.path(&path_buffer, "scripts");
    try std.testing.expectEqual(FolderStamp.missing, stamp(missing));

    try test_dir.mkdir("scripts");
    const empty = stamp(missing);
    try std.testing.expect(empty == .hashed);

    try test_dir.write("scripts/hello.sh", "#!/bin/sh\n");
    const one_file = stamp(missing);
    try std.testing.expect(one_file == .hashed);
    try std.testing.expect(!std.meta.eql(empty, one_file));
    try std.testing.expect(std.meta.eql(one_file, stamp(missing)));
}
