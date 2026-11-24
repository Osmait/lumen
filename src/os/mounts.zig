//! Mount points whose file system can hang a `stat` (network ones and
//! FUSE), read from /proc/self/mountinfo, so the file index can stay out
//! of them.

const std = @import("std");
const linux = std.os.linux;
const os = @import("root.zig");
const log = std.log.scoped(.os);

/// mountinfo is a line per mount: a few hundred of them take ~50 KB.
const mountinfo_bytes_max = 4 << 20;

/// Mount points at or below `under` whose file system can hang a `stat`:
/// network file systems and FUSE (sshfs, rclone), where a server that stops
/// answering blocks every call into the mount. Resolves symlinks on `under`
/// (such as `$HOME`) before matching against `/proc/self/mountinfo`, and
/// returns paths rooted under `under`. Empty when mountinfo cannot be read.
/// Free with `freeList`.
pub fn slowMounts(gpa: std.mem.Allocator, under: []const u8) std.mem.Allocator.Error![][]u8 {
    const fd = os.openRegular("/proc/self/mountinfo") catch return &.{};
    defer os.close(fd);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    // One byte past the limit tells a list longer than it.
    os.readUpTo(gpa, fd, &text, mountinfo_bytes_max + 1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Part of the list would leave mounts out: none, as if unreadable.
        error.ReadFailed => return &.{},
    };
    if (text.items.len > mountinfo_bytes_max) {
        // Thousands of mounts (containers): the complete lines read are
        // still what they say, and leaving them out would leave the slow
        // mounts among them in. The cut last line is not one of them.
        log.warn("/proc/self/mountinfo is over {d} bytes: the mounts past them are not checked", .{
            mountinfo_bytes_max,
        });
        const last_newline = std.mem.findScalarLast(
            u8,
            text.items[0..mountinfo_bytes_max],
            '\n',
        ) orelse 0;
        text.shrinkRetainingCapacity(last_newline);
    }
    var resolved_buffer: [4096]u8 = undefined;
    const resolved_under = resolvePath(under, &resolved_buffer) orelse under;
    return parseSlowMounts(gpa, text.items, under, resolved_under);
}

/// Resolves symlinks on `path` using `O_PATH` + `/proc/self/fd`, without libc.
/// Returns null if `path` does not exist or exceeds the buffer.
fn resolvePath(path: []const u8, buffer: *[4096]u8) ?[]const u8 {
    var path_buffer: [4096]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0) catch return null;
    const open_res = linux.open(path_z, .{ .PATH = true, .CLOEXEC = true }, 0);
    if (linux.errno(open_res) != .SUCCESS) return null;
    const fd: i32 = @intCast(open_res);
    defer os.close(fd);
    var fd_path_buf: [64]u8 = undefined;
    const fd_path = std.mem.printSentinel(&fd_path_buf, "/proc/self/fd/{d}", .{fd}, 0) catch
        return null;
    const readlink_res = linux.readlink(fd_path, buffer, buffer.len);
    if (linux.errno(readlink_res) != .SUCCESS) return null;
    if (readlink_res == 0 or readlink_res >= buffer.len) return null;
    return buffer[0..readlink_res];
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len <= 1) return path;
    return std.mem.trimEnd(u8, path, "/");
}

/// Parses `mountinfo`, matching canonical mount points against `resolved_under`
/// and mapping matches back under `under` (so callers compare against the
/// prefix they index).
fn parseSlowMounts(
    gpa: std.mem.Allocator,
    mountinfo: []const u8,
    under: []const u8,
    resolved_under: []const u8,
) std.mem.Allocator.Error![][]u8 {
    const under_clean = trimTrailingSlash(under);
    const resolved_clean = trimTrailingSlash(resolved_under);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |mount| gpa.free(mount);
        out.deinit(gpa);
    }
    var lines = std.mem.tokenizeScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        // A line reads "id parent dev root MOUNT options... - FSTYPE source options".
        const dash = std.mem.find(u8, line, " - ") orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[0..dash], ' ');
        for (0..4) |_| _ = fields.next();
        const escaped = fields.next() orelse continue;
        var tail = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
        if (!mayHang(tail.next() orelse continue)) continue;
        const mount = try unescapeMount(gpa, escaped) orelse continue;
        if (!isAtOrBelow(mount, resolved_clean)) {
            gpa.free(mount);
            continue;
        }
        const entry = if (std.mem.eql(u8, under_clean, resolved_clean))
            mount
        else blk: {
            defer gpa.free(mount);
            const suffix = if (std.mem.eql(u8, resolved_clean, "/"))
                (if (mount.len > 1) mount else "")
            else
                mount[resolved_clean.len..];
            break :blk if (std.mem.eql(u8, under_clean, "/"))
                try gpa.dupe(u8, if (suffix.len > 0) suffix else "/")
            else
                try std.mem.concat(gpa, u8, &.{ under_clean, suffix });
        };
        out.append(gpa, entry) catch |err| {
            gpa.free(entry);
            return err;
        };
    }
    return out.toOwnedSlice(gpa);
}

/// `path` is `root` itself or inside it ("/home/u" is below "/home", and
/// "/homework" is not).
pub fn isAtOrBelow(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (std.mem.endsWith(u8, root, "/")) return true;
    return path[root.len] == '/';
}

pub fn freeList(gpa: std.mem.Allocator, list: []const []u8) void {
    for (list) |item| gpa.free(item);
    gpa.free(list);
}

/// File systems whose calls may block for as long as a server takes to
/// answer: network ones, and FUSE (any user program behind it).
const fstypes_that_may_hang: std.StaticStringMap(void) = .initComptime(.{
    .{"fuse"},      .{"nfs"},  .{"nfs4"},   .{"cifs"}, .{"smb3"},  .{"smbfs"},
    .{"9p"},        .{"ceph"}, .{"lustre"}, .{"afs"},  .{"davfs"}, .{"ncpfs"},
    .{"glusterfs"},
});

/// FUSE file systems report themselves as "fuse.<name>" ("fuse.sshfs").
/// Plain "fuseblk" is a local disk (ntfs-3g) and does not match.
const fuse_subtype_prefix = "fuse.";

fn mayHang(fstype: []const u8) bool {
    if (std.mem.startsWith(u8, fstype, fuse_subtype_prefix)) return true;
    return fstypes_that_may_hang.has(fstype);
}

/// mountinfo writes space, tab, newline and backslash as `\ooo`.
/// Null for a path longer than a path can be: cut, it would name another.
fn unescapeMount(gpa: std.mem.Allocator, escaped: []const u8) std.mem.Allocator.Error!?[]u8 {
    var unescaped: [4096]u8 = undefined;
    var unescaped_len: usize = 0;
    var escaped_index: usize = 0;
    while (escaped_index < escaped.len and unescaped_len < unescaped.len) : (unescaped_len += 1) {
        const rest = escaped[escaped_index..];
        if (rest[0] == '\\' and rest.len > 3) {
            if (std.fmt.parseInt(u8, rest[1..4], 8)) |byte| {
                unescaped[unescaped_len] = byte;
                escaped_index += 4;
                continue;
            } else |_| {}
        }
        unescaped[unescaped_len] = rest[0];
        escaped_index += 1;
    }
    if (escaped_index < escaped.len) return null;
    return try gpa.dupe(u8, unescaped[0..unescaped_len]);
}

test "slow mounts: escapes undone, only below the root" {
    const gpa = std.testing.allocator;
    const mount = (try unescapeMount(gpa, "/home/u/my\\040share")).?;
    defer gpa.free(mount);
    try std.testing.expectEqualStrings("/home/u/my share", mount);
    // Longer than a path can be: skipped, not cut into another path.
    const long = try gpa.alloc(u8, 5000);
    defer gpa.free(long);
    @memset(long, 'a');
    try std.testing.expect(try unescapeMount(gpa, long) == null);
    for ([_][]const u8{ "fuse.sshfs", "nfs4" }) |fstype| try std.testing.expect(mayHang(fstype));
    for ([_][]const u8{ "fuseblk", "ext4", "btrfs", "tmpfs" }) |fstype| {
        try std.testing.expect(!mayHang(fstype));
    }
    try std.testing.expect(isAtOrBelow("/home", "/home"));
    try std.testing.expect(isAtOrBelow("/home/u", "/home"));
    try std.testing.expect(isAtOrBelow("/home/u", "/home/"));
    try std.testing.expect(!isAtOrBelow("/homework", "/home"));
    // Whatever this machine mounts, nothing is outside what was asked for.
    const list = try slowMounts(gpa, "/home");
    defer freeList(gpa, list);
    for (list) |item| try std.testing.expect(std.mem.startsWith(u8, item, "/home"));
}

test "slow mounts: symlinked root resolves and maps mounts back under requested prefix" {
    const gpa = std.testing.allocator;
    var tree = try os.TestDir.init();
    defer tree.deinit();
    try tree.mkdir("real/sub");
    var real_buf: [4096]u8 = undefined;
    var link_buf: [4096]u8 = undefined;
    const real_path = try tree.path(&real_buf, "real");
    const link_path = try tree.path(&link_buf, "sym");
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlink(real_path, link_path)));

    var resolved_buf: [4096]u8 = undefined;
    const resolved_sym = resolvePath(link_path, &resolved_buf).?;
    const resolved_real = resolvePath(real_path, &real_buf).?;
    try std.testing.expectEqualStrings(resolved_real, resolved_sym);

    const sample =
        "10 1 0:1 / /data/home/u/nas rw - nfs4 server:/nas rw\n" ++
        "11 1 0:2 / /data/home/u/my\\040fuse rw - fuse.sshfs u@host: rw\n" ++
        "12 1 0:3 / /data/home/u2/nas rw - nfs4 server:/other rw\n" ++
        "13 1 0:4 / /data/home/u/local rw - ext4 /dev/sda1 rw\n" ++
        "14 1 0:5 / /data/home/u rw - nfs server:/home rw\n";

    const mapped = try parseSlowMounts(gpa, sample, "/home/u", "/data/home/u");
    defer freeList(gpa, mapped);
    try std.testing.expectEqual(@as(usize, 3), mapped.len);
    try std.testing.expectEqualStrings("/home/u/nas", mapped[0]);
    try std.testing.expectEqualStrings("/home/u/my fuse", mapped[1]);
    try std.testing.expectEqualStrings("/home/u", mapped[2]);

    // Trailing slash on `under` does not double slashes.
    const mapped_slash = try parseSlowMounts(gpa, sample, "/home/u/", "/data/home/u");
    defer freeList(gpa, mapped_slash);
    try std.testing.expectEqual(@as(usize, 3), mapped_slash.len);
    try std.testing.expectEqualStrings("/home/u/nas", mapped_slash[0]);
    try std.testing.expectEqualStrings("/home/u", mapped_slash[2]);
}
