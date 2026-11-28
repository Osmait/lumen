//! Script commands from ~/.config/lumen/scripts.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const script_meta = @import("core").script_meta;
const os = @import("os");
const Item = @import("../item.zig").Item;
const labels = @import("../ui/labels.zig");

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
        .cwd = try arena.dupeSentinel(u8, cached.action.script.cwd, 0),
    } };
    return copied;
}

/// What the scripts folder looked like: whether it exists, and a hash of
/// its files' names, sizes, mtimes, inodes and modes. A tagged union rather than special
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
        // chmod +x changes none of the above, and it decides whether the
        // file is a command (`itemOf`).
        const file_mode = modeOf(file_path.ptr);
        hasher.update(std.mem.asBytes(&file_mode));
        files_sum +%= hasher.final();
    }
    return .{ .hashed = files_sum };
}

/// The type and permission bits of the file at `path` (followed when a
/// link), or 0 when it cannot be read.
fn modeOf(path: [*:0]const u8) u16 {
    var stx: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true, .MODE = true }, &stx);
    if (linux.errno(result) != .SUCCESS) return 0;
    return stx.mode;
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
/// file is not a script command (no title in its header) or needs
/// arguments, which there is no prompt for: run without them, `$1` is
/// empty, and `rm -rf "$HOME/Downloads/$1"` removes the whole folder.
fn itemOf(
    arena: std.mem.Allocator,
    path: [:0]const u8,
    name: []const u8,
) std.mem.Allocator.Error!?Item {
    const file_path = try arena.printSentinel("{s}/{s}", .{ path, name }, 0);
    var stx: linux.Statx = undefined;
    const stat_res = linux.statx(
        linux.AT.FDCWD,
        file_path.ptr,
        0,
        .{ .TYPE = true, .MODE = true },
        &stx,
    );
    if (linux.errno(stat_res) != .SUCCESS) return null;
    if ((stx.mode & linux.S.IFMT) != linux.S.IFREG) return null;
    if ((stx.mode & 0o111) == 0) return null;
    // Only the header is read: script metadata lives in its comments.
    var head_buffer: [script_header_bytes_max]u8 = undefined;
    const head = os.readHead(file_path.ptr, &head_buffer);
    const metadata = script_meta.parse(head) orelse return null;
    if (metadata.needs_arguments) {
        log.info("{s}: left out, it needs arguments (@raycast.argumentN)", .{name});
        return null;
    }
    const subtitle = if (metadata.package_name.len > 0) metadata.package_name else "Script Command";
    return .{
        .key = try arena.print("script:{s}", .{name}),
        .title = labels.displayText(arena, metadata.title),
        .subtitle = labels.displayText(arena, subtitle),
        .accessory = "Script",
        .keywords = try arena.dupe(u8, metadata.description),
        .confirm = metadata.needs_confirmation,
        .icon = if (looksLikeEmoji(metadata.icon))
            .{ .emoji = try arena.dupeSentinel(u8, metadata.icon, 0) }
        else
            .{ .tile = .{ .name = "utilities-terminal-symbolic", .color = .gray } },
        .action = .{ .script = .{
            .path = file_path,
            .mode = metadata.mode,
            .cwd = try workingFolder(arena, path, metadata.current_directory_path),
        } },
    };
}

/// The folder a script runs in: its `currentDirectoryPath`, with `~`
/// expanded and a relative one taken from the scripts folder at `path`, or
/// that folder when there is none. Not checked here: a folder that does not
/// exist makes the run fail, never run it somewhere else.
fn workingFolder(
    arena: std.mem.Allocator,
    path: [:0]const u8,
    current_directory_path: []const u8,
) std.mem.Allocator.Error![:0]const u8 {
    const folder = current_directory_path;
    if (folder.len == 0) return arena.dupeSentinel(u8, path, 0);
    if (std.mem.eql(u8, folder, "~") or std.mem.startsWith(u8, folder, "~/")) {
        const home = std.mem.span(c.g_get_home_dir());
        return arena.printSentinel("{s}{s}", .{ home, folder[1..] }, 0);
    }
    if (folder[0] == '/') return arena.dupeSentinel(u8, folder, 0);
    return arena.printSentinel("{s}/{s}", .{ path, folder }, 0);
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
    // Its own buffer: `missing` lives in `path_buffer` (sharing it made
    // `missing` name the script, and every stamp after this `.missing`).
    var script_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const script_path = try test_dir.path(&script_path_buffer, "scripts/hello.sh");
    try os.writeFileAtomic(script_path, "#!/bin/ba\n");
    try std.testing.expect(!std.meta.eql(one_file, stamp(missing)));

    // chmod +x alone changes the stamp: it decides whether the script is
    // a command (MYP-493).
    const before_chmod = stamp(missing);
    try std.testing.expect(before_chmod == .hashed);
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.fchmodat(linux.AT.FDCWD, script_path, 0o755)),
    );
    try std.testing.expect(!std.meta.eql(before_chmod, stamp(missing)));
}

test "scan skips non-executable files and sanitizes title and subtitle" {
    var test_dir = try os.TestDir.init();
    defer test_dir.deinit();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try test_dir.mkdir("scripts");

    try test_dir.write("scripts/notes.sh",
        \\#!/bin/sh
        \\# @raycast.title Non Exec
    );
    try test_dir.write("scripts/run.sh", "#!/bin/sh\n# @raycast.title Hello\rWorld\n# @raycast.packageName Dev\tTools\n");
    const run_path = try test_dir.path(&path_buffer, "scripts/run.sh");
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmodat(linux.AT.FDCWD, run_path, 0o755)));

    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const scripts_dir = try test_dir.path(&dir_buffer, "scripts");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const items = scan(arena_state.allocator(), scripts_dir);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Hello World", items[0].title);
    try std.testing.expectEqualStrings("Dev Tools", items[0].subtitle);
}

test "scripts that need arguments are left out; the folder they run in" {
    var test_dir = try os.TestDir.init();
    defer test_dir.deinit();
    try test_dir.mkdir("scripts");
    const scripts = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "remove.sh", .source =
        \\#!/bin/sh
        \\# @raycast.title Remove
        \\# @raycast.argument1 {"type":"text","placeholder":"folder"}
        \\rm -rf "$HOME/Downloads/$1"
        },
        .{ .name = "sync.sh", .source =
        \\#!/bin/sh
        \\# @raycast.title Sync
        \\# @raycast.currentDirectoryPath /srv/app
        \\# @raycast.argument1 {"type":"text","placeholder":"branch","optional":true}
        },
    };
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (scripts) |script| {
        var name_buffer: [64]u8 = undefined;
        const relative = try std.fmt.bufPrint(&name_buffer, "scripts/{s}", .{script.name});
        try test_dir.write(relative, script.source);
        const script_path = try test_dir.path(&path_buffer, relative);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmodat(linux.AT.FDCWD, script_path, 0o755)));
    }

    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const scripts_dir = try test_dir.path(&dir_buffer, "scripts");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = scan(arena, scripts_dir);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Sync", items[0].title);
    try std.testing.expectEqualStrings("/srv/app", items[0].action.script.cwd);

    try std.testing.expectEqualStrings("/s", try workingFolder(arena, "/s", ""));
    try std.testing.expectEqualStrings("/s/sub", try workingFolder(arena, "/s", "sub"));
    const home = std.mem.span(c.g_get_home_dir());
    const projects = try workingFolder(arena, "/s", "~/Projects/app");
    try std.testing.expect(std.mem.startsWith(u8, projects, home));
    try std.testing.expect(std.mem.endsWith(u8, projects, "/Projects/app"));
    try std.testing.expectEqualStrings(home, try workingFolder(arena, "/s", "~"));
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
