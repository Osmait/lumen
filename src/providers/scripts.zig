//! Script commands from ~/.config/lumen/scripts.

const std = @import("std");
const c = @import("c");
const script_meta = @import("core").script_meta;
const os = @import("os");
const Item = @import("../item.zig").Item;

/// How much of a script is read for its metadata: script_meta reads at most
/// 40 lines of header comments, which fit in it.
const script_header_bytes_max = 4096;
/// Bound entries inspected/loaded per scripts directory scan.
const scripts_entries_max = 512;

/// ~/.config/lumen/scripts, in `arena`; null only when out of memory.
pub fn folderPath(arena: std.mem.Allocator) ?[:0]const u8 {
    const config = std.mem.span(c.g_get_user_config_dir());
    return arena.printSentinel("{s}/lumen/scripts", .{config}, 0) catch null;
}

/// The last scan's scripts, and what the folder looked like then: the root
/// view is built on every show, and each scan read every script.
const Cache = struct {
    arena: ?std.heap.ArenaAllocator = null,
    items: []Item = &.{},
    /// Null until the first scan.
    stamp: ?FolderStamp = null,
};

/// The process's one cache. Main thread only, like `load`.
var cache: Cache = .{};

const log = std.log.scoped(.scripts);

/// Frees the cached scripts arena on shutdown. Main thread only.
pub fn shutdown() void {
    os.assertMainThread();
    if (cache.arena) |*arena| arena.deinit();
    cache = .{};
}

/// The scripts, in `arena`: scanned again only when a file in the folder
/// was added, removed, renamed or written since the last time.
pub fn load(gpa: std.mem.Allocator, arena: std.mem.Allocator) []Item {
    os.assertMainThread();
    if (cache.arena == null) cache.arena = .init(gpa);
    const path = folderPath(arena) orelse return &.{};
    const folder_stamp = stamp(path);
    const cached = if (cache.stamp) |last| std.meta.eql(last, folder_stamp) else false;
    if (!cached) {
        const cache_arena = &cache.arena.?;
        _ = cache_arena.reset(.retain_capacity);
        cache.items = scan(cache_arena.allocator(), path);
        cache.stamp = folder_stamp;
    }
    const items = arena.alloc(Item, cache.items.len) catch return &.{};
    for (cache.items, items, 0..) |cached_item, *item, copied| {
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
    // Each file hashed on its own, the hashes summed: readdir gives them in
    // the file system's order, which can differ for the same files.
    var files_sum: u64 = 0;
    var entries_seen: usize = 0;
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (c.g_dir_read_name(dir_handle)) |name_terminated| {
        if (entries_seen >= scripts_entries_max) break;
        entries_seen += 1;
        const name = std.mem.span(name_terminated);
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(name);
        const file_path = std.mem.printSentinel(
            &path_buffer,
            "{s}/{s}",
            .{ path, name },
            0,
        ) catch continue;
        const file_stamp = os.Stamp.of(file_path.ptr);
        hasher.update(std.mem.asBytes(&file_stamp.mtime_s));
        hasher.update(std.mem.asBytes(&file_stamp.mtime_subsecond_ns));
        hasher.update(std.mem.asBytes(&file_stamp.size));
        hasher.update(std.mem.asBytes(&file_stamp.inode));
        files_sum +%= hasher.final();
    }
    return .{ .hashed = files_sum };
}

/// Scans the scripts directory at `path`. Everything lives in `arena`.
fn scan(arena: std.mem.Allocator, path: [:0]const u8) []Item {
    const dir_handle = c.g_dir_open(path.ptr, 0, null) orelse return &.{};
    defer c.g_dir_close(dir_handle);

    var items: std.ArrayList(Item) = .empty;
    var dropped: usize = 0;
    var entries_seen: usize = 0;
    defer if (dropped > 0) log.warn("{d} scripts left out: out of memory", .{dropped});
    while (c.g_dir_read_name(dir_handle)) |name_terminated| {
        if (entries_seen >= scripts_entries_max) break;
        entries_seen += 1;
        const name = std.mem.span(name_terminated);
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
    var head_buffer: [script_header_bytes_max]u8 = undefined;
    const head = os.readHead(file_path.ptr, &head_buffer);
    const metadata = script_meta.parse(head) orelse return null;
    const subtitle = if (metadata.package_name.len > 0) metadata.package_name else "Script Command";
    return .{
        .key = try arena.print("script:{s}", .{name}),
        .title = try arena.dupeSentinel(u8, metadata.title, 0),
        .subtitle = try arena.dupeSentinel(u8, subtitle, 0),
        .accessory = "Script",
        .keywords = try arena.dupe(u8, metadata.description),
        .confirm = metadata.needs_confirmation,
        .icon = if (looksLikeEmoji(metadata.icon))
            .{ .emoji = try arena.dupeSentinel(u8, metadata.icon, 0) }
        else
            .{ .tile = .{ .name = "utilities-terminal-symbolic", .color = .gray } },
        .action = .{ .script = .{ .path = file_path, .mode = metadata.mode } },
    };
}

/// The longest emoji taken, in bytes: a family or a flag with joiners and
/// modifiers runs to ~30 ("👨‍👩‍👧‍👦" is 25).
const emoji_bytes_max = 64;

/// An emoji, not an icon name: one that starts with an emoji character and
/// has no letter or digit after (joiners, variation selectors and skin
/// tones are fine). "Ñandú" starts with a non-ASCII letter: not an emoji.
fn looksLikeEmoji(icon: []const u8) bool {
    if (icon.len == 0 or icon.len > emoji_bytes_max) return false;
    const view = std.unicode.Utf8View.init(icon) catch return false;
    var codepoints = view.iterator();
    const first = codepoints.nextCodepoint() orelse return false;
    if (!isEmojiStart(first)) return false;
    while (codepoints.nextCodepoint()) |codepoint| {
        if (codepoint < 0x80 and std.ascii.isAlphanumeric(@intCast(codepoint))) return false;
    }
    return true;
}

/// The blocks emoji start in: pictographs, symbols, dingbats, arrows,
/// geometric shapes and the few older ones (©, ™, ‼...).
fn isEmojiStart(codepoint: u21) bool {
    return switch (codepoint) {
        0x1F000...0x1FAFF, // pictographs, emoticons, flags, transport...
        0x2600...0x27BF, // miscellaneous symbols, dingbats
        0x2300...0x23FF, // technical (⌚, ⏰)
        0x2B00...0x2BFF, // arrows and stars (⭐)
        0x2190...0x21FF, // arrows
        0x25A0...0x25FF, // geometric shapes (▶)
        0x2900...0x297F, // supplemental arrows
        0x00A9,
        0x00AE,
        0x203C,
        0x2049,
        0x2122,
        0x2139,
        0x3030,
        0x303D,
        0x3297,
        0x3299,
        => true,
        else => false,
    };
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

    // Atomic replacement of same size within the same second alters inode / nsec stamp.
    const script_path = try test_dir.path(&path_buffer, "scripts/hello.sh");
    try os.writeFileAtomic(script_path, "#!/bin/ba\n");
    try std.testing.expect(!std.meta.eql(one_file, stamp(missing)));
}

test "emoji icons, joined ones included, and names that are not" {
    try std.testing.expect(looksLikeEmoji("🚀"));
    try std.testing.expect(looksLikeEmoji("👨‍💻"));
    try std.testing.expect(looksLikeEmoji("🏳️‍🌈"));
    try std.testing.expect(looksLikeEmoji("👍🏽"));
    try std.testing.expect(looksLikeEmoji("⭐"));
    try std.testing.expect(!looksLikeEmoji("Ñandú"));
    try std.testing.expect(!looksLikeEmoji("émoji"));
    try std.testing.expect(!looksLikeEmoji("utilities-terminal"));
    try std.testing.expect(!looksLikeEmoji(""));
    try std.testing.expect(!looksLikeEmoji("\xff\xfe"));
}
