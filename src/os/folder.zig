//! Folders: opening them (following a link or refusing one), reading
//! their entries straight from getdents64, making them, and making them
//! owner-only.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const os = @import("root.zig");
const syscall = @import("syscall.zig");
const Error = syscall.Error;
const check = syscall.check;
const close = syscall.close;

const log = std.log.scoped(.os);

pub fn openDir(path: [*:0]const u8) Error!i32 {
    const fd = try check(linux.open(
        path,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
        0,
    ));
    return @intCast(fd);
}

/// `openDir` that refuses a symbolic link. The file index uses it below its
/// root: a folder swapped for a link to `/` between the event and the read
/// was walked whole, under the lock searches wait on.
pub fn openDirNoFollow(path: [*:0]const u8) Error!i32 {
    const fd = try check(linux.open(
        path,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true },
        0,
    ));
    return @intCast(fd);
}

/// What getdents64 fills per call: a few hundred entries.
const dir_entries_buffer_bytes = 32 << 10;

/// Entries of an open directory, from the kernel's getdents64 buffer: name and
/// d_type come for free, no stat per entry.
pub const DirIter = struct {
    fd: i32,
    entries: [dir_entries_buffer_bytes]u8 align(8) = undefined,
    /// Where the next entry starts in `entries`.
    entry_offset: usize = 0,
    /// Where the bytes the kernel filled end.
    entries_end: usize = 0,

    pub const Entry = struct { name: []const u8, kind: u8 };

    pub fn next(iterator: *DirIter) Error!?Entry {
        while (true) {
            if (iterator.entry_offset == iterator.entries_end) {
                const entries = &iterator.entries;
                const bytes_read = try check(linux.getdents64(iterator.fd, entries, entries.len));
                if (bytes_read == 0) return null;
                iterator.entry_offset = 0;
                iterator.entries_end = bytes_read;
            }
            const entry_start = iterator.entry_offset;
            const dirent: *align(1) linux.dirent64 = @ptrCast(&iterator.entries[entry_start]);
            // A zero-length record would never advance: a bug in the
            // kernel's buffer, or in this walk of it.
            assert(dirent.reclen > 0);
            iterator.entry_offset += dirent.reclen;
            assert(iterator.entry_offset <= iterator.entries_end);
            const name_offset = entry_start + @offsetOf(linux.dirent64, "name");
            const name_z: [*:0]const u8 = @ptrCast(&iterator.entries[name_offset]);
            const name = std.mem.span(name_z);
            if (std.mem.eql(u8, name, ".")) continue;
            if (std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .kind = dirent.type };
        }
    }
};

/// Names of the folders directly in `path` (links to folders count), that
/// `keep` accepts, sorted, in `arena`. Hidden ones are skipped. Empty when
/// the folder cannot be read; out of memory, the ones found so far.
pub fn subdirs(
    arena: std.mem.Allocator,
    path: [:0]const u8,
    keep: *const fn ([]const u8) bool,
) []const [:0]const u8 {
    const fd = openDir(path) catch return &.{};
    defer close(fd);
    var iterator: DirIter = .{ .fd = fd };
    var names: std.ArrayList([:0]const u8) = .empty;
    while (iterator.next() catch null) |entry| {
        if (entry.name[0] == '.') continue;
        if (!keep(entry.name)) continue;
        if (!isDirEntry(path, entry)) continue;
        const name = arena.dupeSentinel(u8, entry.name, 0) catch break;
        names.append(arena, name) catch break;
    }
    std.mem.sort([:0]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: [:0]const u8, right: [:0]const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return names.items;
}

/// Whether `entry` of the folder at `path` is a folder, following a link
/// (and asking the file system when d_type is unknown).
fn isDirEntry(path: [:0]const u8, entry: DirIter.Entry) bool {
    if (entry.kind == os.Kind.directory) return true;
    if (entry.kind != os.Kind.symlink and entry.kind != os.Kind.unknown) return false;
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full = std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ path, entry.name }, 0) catch {
        return false;
    };
    const entry_info = os.info(full) orelse return false;
    return entry_info.is_dir;
}

/// Makes `path` and the folders above it that are missing, owner-only
/// (existing ones are untouched). Succeeds when `path` exists afterwards,
/// made here or before.
pub fn mkdirP(path: []const u8) Error!void {
    var prefix_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= prefix_buffer.len) return error.NameTooLong;
    if (path.len == 0) return error.NotFound;
    // Each prefix that ends a component, the whole path last. A parent that
    // cannot be made (it exists, or it is not ours to make, like /home) is
    // not an error by itself: only the whole path's mkdir decides.
    var end: usize = 1;
    while (end <= path.len) : (end += 1) {
        if (end != path.len and path[end] != '/') continue;
        @memcpy(prefix_buffer[0..end], path[0..end]);
        prefix_buffer[end] = 0;
        const result = linux.mkdir(@ptrCast(&prefix_buffer), 0o700);
        if (end < path.len) continue;
        if (linux.errno(result) == .EXIST) return;
        _ = try check(result);
    }
}

/// Makes an existing directory of Lumen's owner-only: caches made by
/// earlier versions were 0755, with world-readable files inside. A failure
/// is logged: the files written inside are owner-only all the same.
pub fn makePrivate(path: []const u8) void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0) catch {
        log.warn("could not make {s} owner-only: the path is too long", .{path});
        return;
    };
    switch (linux.errno(linux.chmod(path_z, 0o700))) {
        .SUCCESS => {},
        else => |errno| log.warn("could not make {s} owner-only: {t}", .{ path, errno }),
    }
}

const expectSuccess = @import("test_dir.zig").expectSuccess;

test "subdirs: folders and links to them, sorted, filtered" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var root_buffer: [256]u8 = undefined;
    const root = try os.tmpDirPath(&tmp_dir, &root_buffer);
    var path_buffer: [512]u8 = undefined;
    for ([_][]const u8{ "b", "a", ".hidden", "skip" }) |name| {
        try mkdirP(try std.mem.print(&path_buffer, "{s}/{s}", .{ root, name }));
    }
    try os.writeFile(try std.mem.printSentinel(&path_buffer, "{s}/file", .{root}, 0), "x");
    const link = try std.mem.printSentinel(&path_buffer, "{s}/c", .{root}, 0);
    try expectSuccess(linux.symlink("a", link));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root_z = try arena.allocator().dupeSentinel(u8, root, 0);
    const names = subdirs(arena.allocator(), root_z, struct {
        fn keep(name: []const u8) bool {
            return !std.mem.eql(u8, name, "skip");
        }
    }.keep);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    for ([_][]const u8{
        "a",
        "b",
        "c",
    }, names) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "openDirNoFollow refuses a link to a folder, openDir follows it" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var real_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real = try std.mem.printSentinel(&real_buffer, "{s}/real", .{dir}, 0);
    try mkdirP(real);
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buffer, "{s}/link", .{dir}, 0);
    try expectSuccess(linux.symlink("real", link));
    close(try openDirNoFollow(real));
    close(try openDir(link));
    if (openDirNoFollow(link)) |fd| {
        close(fd);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "mkdirP makes the missing folders, and says when it could not" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deep = try std.mem.print(&path_buffer, "{s}/a/b/c", .{dir});
    try mkdirP(deep);
    // Again: it exists, which is what was asked.
    try mkdirP(deep);
    var file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.printSentinel(&file_buffer, "{s}/file", .{dir}, 0);
    try os.writeFile(file, "x");
    var under_file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const under_file = try std.mem.print(&under_file_buffer, "{s}/file/sub", .{dir});
    try std.testing.expectError(error.NotFound, mkdirP(under_file));
}

test "Lumen's files and directories are owner-only" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var sub_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sub = try std.mem.printSentinel(&sub_buffer, "{s}/cache/lumen", .{dir}, 0);
    try mkdirP(sub);
    var file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.printSentinel(&file_buffer, "{s}/x.idx", .{sub}, 0);
    try os.writeFile(file, "data");
    const mode = struct {
        fn of(path: [*:0]const u8) !u32 {
            var stx: linux.Statx = undefined;
            try expectSuccess(linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &stx));
            return stx.mode & 0o777;
        }
    }.of;
    try std.testing.expectEqual(@as(u32, 0o700), try mode(sub));
    try std.testing.expectEqual(@as(u32, 0o600), try mode(file));
    try expectSuccess(linux.chmod(sub, 0o755));
    makePrivate(sub);
    try std.testing.expectEqual(@as(u32, 0o700), try mode(sub));
}
