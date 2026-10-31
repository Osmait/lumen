//! Whether the extension files changed since they were loaded: a hash of
//! the stat of init.lua, of each extension's .lua files and of the style's.
//! The window computes it on the main thread each time it opens and reloads
//! the host when it differs, so it reads no file contents and a bounded
//! number of folder entries.

const std = @import("std");
const c = @import("c");
const os = @import("os");

/// Changes when init.lua or any .lua file in an extension's folder (not
/// subfolders) is added, removed or edited: then the files are reloaded.
/// `style`: the style in use; edits to the others' files change nothing.
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
    if (style.len > 0) {
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

/// The .lua files directly in `folder`.
fn hashLua(hasher: *std.hash.Wyhash, folder: [:0]const u8) void {
    hasher.update(folder);
    const folder_handle = c.g_dir_open(folder.ptr, 0, null) orelse return;
    defer c.g_dir_close(folder_handle);
    var entries_count: usize = 0;
    while (c.g_dir_read_name(folder_handle)) |file_name_c| : (entries_count += 1) {
        if (entries_count == stamp_entries_max) break;
        const file_name = std.mem.span(file_name_c);
        if (!std.mem.endsWith(u8, file_name, ".lua")) continue;
        var path_buffer: [4096]u8 = undefined;
        const path = std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ folder, file_name }, 0) catch
            continue;
        hashFile(hasher, path);
    }
}

/// The .lua files in each folder of <config>/<kind>.
fn hashFolders(hasher: *std.hash.Wyhash, config_dir: []const u8, kind: []const u8) void {
    var top_buffer: [4096]u8 = undefined;
    const top = std.mem.printSentinel(&top_buffer, "{s}/{s}", .{ config_dir, kind }, 0) catch
        return;
    const folder_handle = c.g_dir_open(top.ptr, 0, null) orelse return;
    defer c.g_dir_close(folder_handle);
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
        hashLua(hasher, folder);
    }
}

fn hashFile(hasher: *std.hash.Wyhash, path: [:0]const u8) void {
    hasher.update(path);
    const file_stamp = os.Stamp.of(path.ptr);
    hasher.update(std.mem.asBytes(&.{ file_stamp.mtime_s, file_stamp.size, file_stamp.inode }));
    hasher.update(std.mem.asBytes(&file_stamp.mtime_subsecond_ns));
}
