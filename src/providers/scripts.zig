//! Script commands from ~/.config/lumen/scripts.

const std = @import("std");
const c = @import("c");
const script_meta = @import("core").script_meta;
const os = @import("os");
const Item = @import("../item.zig").Item;

/// How much of a script is read for its metadata: script_meta reads at most
/// 40 lines of header comments, which fit in it.
const script_header_bytes_max = 4096;

/// ~/.config/lumen/scripts, in `arena`; null only when out of memory.
pub fn dir(arena: std.mem.Allocator) ?[:0]const u8 {
    const config = std.mem.span(c.g_get_user_config_dir());
    return arena.printSentinel("{s}/lumen/scripts", .{config}, 0) catch null;
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

/// The cached item with its strings in `arena`.
fn copy(arena: std.mem.Allocator, cached: Item) std.mem.Allocator.Error!Item {
    var copied = cached;
    copied.key = try arena.dupe(u8, cached.key);
    copied.title = try arena.dupeSentinel(u8, cached.title, 0);
    copied.subtitle = try arena.dupeSentinel(u8, cached.subtitle, 0);
    copied.keywords = try arena.dupe(u8, cached.keywords);
    if (cached.icon == .emoji) {
        copied.icon = .{ .emoji = try arena.dupeSentinel(u8, cached.icon.emoji, 0) };
    }
    copied.action = .{ .script = .{
        .path = try arena.dupeSentinel(u8, cached.action.script.path, 0),
        .mode = cached.action.script.mode,
    } };
    return copied;
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
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
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

/// Scans the scripts directory at `path`. Everything lives in `arena`.
fn scan(arena: std.mem.Allocator, path: [:0]const u8) []Item {
    const dir_handle = c.g_dir_open(path.ptr, 0, null) orelse return &.{};
    defer c.g_dir_close(dir_handle);

    var items: std.ArrayList(Item) = .empty;
    var dropped: usize = 0;
    defer if (dropped > 0) log.warn("{d} scripts left out: out of memory", .{dropped});
    while (c.g_dir_read_name(dir_handle)) |name_c| {
        const name = std.mem.span(name_c);
        if (name.len == 0 or name[0] == '.') continue;
        const item = (itemOf(arena, path, name) catch {
            dropped += 1;
            continue;
        }) orelse continue;
        items.append(arena, item) catch {
            dropped += 1;
            continue;
        };
    }
    return items.toOwnedSlice(arena) catch items.items;
}

/// The row for the script `name` in the folder at `path`, or null when the
/// file is not a script command (no title in its header).
fn itemOf(
    arena: std.mem.Allocator,
    path: [:0]const u8,
    name: []const u8,
) std.mem.Allocator.Error!?Item {
    const file_path = try arena.printSentinel("{s}/{s}", .{ path, name }, 0);
    // Only the header is read: script metadata lives in its comments.
    var head_buf: [script_header_bytes_max]u8 = undefined;
    const head = os.readHead(file_path.ptr, &head_buf);
    const meta = script_meta.parse(head) orelse return null;
    const subtitle = if (meta.package_name.len > 0) meta.package_name else "Script Command";
    return .{
        .key = try arena.print("script:{s}", .{name}),
        .title = try arena.dupeSentinel(u8, meta.title, 0),
        .subtitle = try arena.dupeSentinel(u8, subtitle, 0),
        .accessory = "Script",
        .keywords = try arena.dupe(u8, meta.description),
        .confirm = meta.needs_confirmation,
        .icon = if (looksLikeEmoji(meta.icon))
            .{ .emoji = try arena.dupeSentinel(u8, meta.icon, 0) }
        else
            .{ .tile = .{ .name = "utilities-terminal-symbolic", .color = .gray } },
        .action = .{ .script = .{ .path = file_path, .mode = meta.mode } },
    };
}

/// Non-ASCII and short: an emoji, not an icon name.
fn looksLikeEmoji(icon: []const u8) bool {
    if (icon.len == 0) return false;
    if (icon.len > 8) return false;
    return icon[0] >= 0x80;
}

test "a missing folder and an empty one stamp differently, and edits show" {
    var test_dir = try os.TestDir.init();
    defer test_dir.deinit();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

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
