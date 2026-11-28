//! Whether the extension files changed since they were loaded: a hash of
//! the stat of init.lua, of each extension's .lua files and of the style's.
//! The window computes it on the main thread each time it opens and reloads
//! the host when it differs, so it reads no file contents and a bounded
//! number of folder entries.

const std = @import("std");
const c = @import("c");
const os = @import("os");

/// Changes when init.lua or any .lua file in an extension's folder or
/// non-hidden subfolders is added, removed or edited: then the files are
/// reloaded. `style`: the style in use; edits to the others' files change
/// nothing.
pub fn stamp(config_dir: []const u8, style: []const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    var path_buffer: [4096]u8 = undefined;
    if (std.mem.printSentinel(&path_buffer, "{s}/init.lua", .{config_dir}, 0)) |path| {
        hashFile(&hasher, path);
    } else |_| {
        // A config folder that long cannot hold a file anyway.
    }
    hashFolders(&hasher, config_dir, "extensions");
    hasher.update(style);
    if (style.len > 0 and !std.mem.eql(u8, style, ".") and !std.mem.eql(u8, style, "..") and
        std.mem.findScalar(u8, style, '/') == null)
    {
        const style_dir = std.mem.printSentinel(
            &path_buffer,
            "{s}/styles/{s}",
            .{ config_dir, style },
            0,
        ) catch return hasher.final();
        hashLua(&hasher, style_dir);
    }
    return hasher.final();
}

/// The most entries `stamp` reads from one folder. It runs each time the
/// window opens, on the main thread: a folder of a million files (a
/// mistaken copy into extensions/) must not hold the window that long.
/// Past it, edits to the files left out do not reload anything.
const stamp_entries_max = 1024;
const stamp_depth_max = 8;

/// The `.lua` files in `folder` and its non-hidden subdirectories up to
/// `stamp_depth_max`. Each file is hashed on its own and the hashes summed:
/// readdir's order is the file system's, and hashing in it made the same
/// files stamp differently (a reload for nothing).
fn hashLua(hasher: *std.hash.Wyhash, folder: [:0]const u8) void {
    hasher.update(folder);
    // init.lua by name, whatever `stamp_entries_max` leaves out: on btrfs
    // readdir lists files in the order they were made, and a checkout (or
    // an editor's save, a new file renamed over it) put it after a folder
    // of a thousand icons.
    var init_buffer: [4096]u8 = undefined;
    if (std.mem.printSentinel(&init_buffer, "{s}/init.lua", .{folder}, 0)) |path| {
        hashFile(hasher, path);
    } else |_| {}
    var entries_seen: usize = 0;
    const files_sum = hashLuaDir(folder, 0, &entries_seen);
    hasher.update(std.mem.asBytes(&files_sum));
}

/// What `hashLua` sums for `folder` (`depth` 0 is the extension's or the
/// style's own): its files first, then its subfolders, so the `.lua` files
/// beside a big subfolder are never the ones `stamp_entries_max` leaves out.
fn hashLuaDir(folder: [:0]const u8, depth: usize, entries_seen: *usize) u64 {
    // The extension's own folder may be a link (to where it is written);
    // links below it are not followed.
    const opened = if (depth == 0) os.openDir(folder.ptr) else os.openDirNoFollow(folder.ptr);
    const fd = opened catch return 0;
    defer os.close(fd);
    var iter: os.DirIter = .{ .fd = fd };
    var sum: u64 = 0;
    var entries_here: usize = 0;
    var has_subfolders = false;
    while (iter.next() catch null) |entry| {
        if (entries_seen.* >= stamp_entries_max) break;
        entries_seen.* += 1;
        entries_here += 1;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        // Hashed by `hashLua` already.
        if (depth == 0 and std.mem.eql(u8, entry.name, "init.lua")) continue;
        var path_buffer: [4096]u8 = undefined;
        const path = std.mem.printSentinel(
            &path_buffer,
            "{s}/{s}",
            .{ folder, entry.name },
            0,
        ) catch continue;
        if (isFolder(entry, path)) {
            has_subfolders = true;
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;
        var file_hasher: std.hash.Wyhash = .init(0);
        hashFile(&file_hasher, path);
        sum +%= file_hasher.final();
    }
    if (!has_subfolders or depth + 1 >= stamp_depth_max) return sum;
    // Again from the start, for the subfolders among the entries read.
    const linux = std.os.linux;
    if (linux.errno(linux.lseek(fd, 0, linux.SEEK.SET)) != .SUCCESS) return sum;
    iter = .{ .fd = fd };
    var index: usize = 0;
    while (index < entries_here) : (index += 1) {
        const entry = (iter.next() catch null) orelse break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        var path_buffer: [4096]u8 = undefined;
        const path = std.mem.printSentinel(
            &path_buffer,
            "{s}/{s}",
            .{ folder, entry.name },
            0,
        ) catch continue;
        if (!isFolder(entry, path)) continue;
        var dir_hasher: std.hash.Wyhash = .init(0);
        dir_hasher.update(path);
        const sub_sum = hashLuaDir(path, depth + 1, entries_seen);
        dir_hasher.update(std.mem.asBytes(&sub_sum));
        sum +%= dir_hasher.final();
    }
    return sum;
}

fn isFolder(entry: os.DirIter.Entry, path: [:0]const u8) bool {
    return switch (entry.kind) {
        os.Kind.directory => true,
        os.Kind.unknown => if (os.info(path)) |entry_info| entry_info.is_dir else false,
        else => false,
    };
}

/// The .lua files in each folder of <config>/<kind>.
fn hashFolders(hasher: *std.hash.Wyhash, config_dir: []const u8, kind: []const u8) void {
    var top_buffer: [4096]u8 = undefined;
    const top = std.mem.printSentinel(&top_buffer, "{s}/{s}", .{ config_dir, kind }, 0) catch
        return;
    const folder_handle = c.g_dir_open(top.ptr, 0, null) orelse return;
    defer c.g_dir_close(folder_handle);
    var folders_sum: u64 = 0;
    var entries_count: usize = 0;
    while (c.g_dir_read_name(folder_handle)) |folder_name_c| : (entries_count += 1) {
        if (entries_count == stamp_entries_max) break;
        const folder_name = std.mem.span(folder_name_c);
        var folder_buffer: [4096]u8 = undefined;
        const folder = std.mem.printSentinel(
            &folder_buffer,
            "{s}/{s}",
            .{ top, folder_name },
            0,
        ) catch continue;
        // Summed, as in `hashLua`: the folders' order is readdir's too.
        var folder_hasher: std.hash.Wyhash = .init(0);
        hashLua(&folder_hasher, folder);
        folders_sum +%= folder_hasher.final();
    }
    hasher.update(std.mem.asBytes(&folders_sum));
}

fn hashFile(hasher: *std.hash.Wyhash, path: [:0]const u8) void {
    hasher.update(path);
    const file_stamp = os.Stamp.of(path.ptr);
    hasher.update(std.mem.asBytes(&.{ file_stamp.mtime_s, file_stamp.size, file_stamp.inode }));
    hasher.update(std.mem.asBytes(&file_stamp.mtime_subsecond_ns));
}

test "stamp tracks nested lua modules and ignores directory symlinks" {
    var test_dir = try os.TestDir.init();
    defer test_dir.deinit();
    try test_dir.write("extensions/demo/init.lua", "return {}\n");
    try test_dir.write("extensions/demo/helper/init.lua", "return { v = 1 }\n");

    const before = stamp(test_dir.absolute, "");
    try test_dir.write("extensions/demo/helper/init.lua", "return { v = 22 }\n");
    const after = stamp(test_dir.absolute, "");
    try std.testing.expect(before != after);

    // Symlink cycle inside extension folder must not loop infinitely.
    var link_buf: [4096]u8 = undefined;
    const link_path = try test_dir.path(&link_buf, "extensions/demo/helper/loop");
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.symlink("..", link_path)));
    _ = stamp(test_dir.absolute, "");
}

test "stamp sees an extension's own .lua files past a big folder beside them" {
    var test_dir = try os.TestDir.init();
    defer test_dir.deinit();
    // Made first, so readdir lists them first where it keeps that order.
    var name_buffer: [64]u8 = undefined;
    for (0..stamp_entries_max + 100) |number| {
        const name = try std.fmt.bufPrint(&name_buffer, "extensions/demo/assets/{d}.svg", .{number});
        try test_dir.write(name, "<svg/>");
    }
    try test_dir.write("extensions/demo/init.lua", "return {}\n");
    try test_dir.write("extensions/demo/util.lua", "return 1\n");

    const before = stamp(test_dir.absolute, "");
    try test_dir.write("extensions/demo/init.lua", "return { edited = true }\n");
    const after_init = stamp(test_dir.absolute, "");
    try std.testing.expect(before != after_init);
    try test_dir.write("extensions/demo/util.lua", "return 22\n");
    try std.testing.expect(stamp(test_dir.absolute, "") != after_init);
}

test "stamp follows an extension folder that is a link" {
    var test_dir = try os.TestDir.init();
    defer test_dir.deinit();
    try test_dir.write("code/demo/init.lua", "return {}\n");
    try test_dir.write("code/demo/lib/helper.lua", "return 1\n");
    try test_dir.mkdir("extensions");
    var target_buffer: [4096]u8 = undefined;
    const target = try test_dir.path(&target_buffer, "code/demo");
    var link_buffer: [4096]u8 = undefined;
    const link = try test_dir.path(&link_buffer, "extensions/demo");
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.symlink(target, link)));

    const before = stamp(test_dir.absolute, "");
    try test_dir.write("code/demo/init.lua", "return { edited = true }\n");
    const after_init = stamp(test_dir.absolute, "");
    try std.testing.expect(before != after_init);
    try test_dir.write("code/demo/lib/helper.lua", "return 22\n");
    try std.testing.expect(stamp(test_dir.absolute, "") != after_init);
}
