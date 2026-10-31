//! Mount points whose file system can hang a `stat` (network ones and
//! FUSE), read from /proc/self/mountinfo, so the file index can stay out
//! of them.

const std = @import("std");
const os = @import("root.zig");

/// mountinfo is a line per mount: a few hundred of them take ~50 KB.
const mountinfo_bytes_max = 4 << 20;

/// Mount points at or below `under` whose file system can hang a `stat`:
/// network file systems and FUSE (sshfs, rclone), where a server that stops
/// answering blocks every call into the mount. From /proc/self/mountinfo;
/// empty when it cannot be read. Free with `freeList`.
pub fn slowMounts(gpa: std.mem.Allocator, under: []const u8) std.mem.Allocator.Error![][]u8 {
    const fd = os.openRegular("/proc/self/mountinfo") catch return &.{};
    defer os.close(fd);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    os.readUpTo(gpa, fd, &text, mountinfo_bytes_max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Part of the list would leave mounts out: none, as if unreadable.
        error.ReadFailed => return &.{},
    };
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |mount| gpa.free(mount);
        out.deinit(gpa);
    }
    var lines = std.mem.tokenizeScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        // A line reads "id parent dev root MOUNT options... - FSTYPE source options".
        const dash = std.mem.find(u8, line, " - ") orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[0..dash], ' ');
        for (0..4) |_| _ = fields.next();
        const escaped = fields.next() orelse continue;
        var tail = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
        if (!mayHang(tail.next() orelse continue)) continue;
        const mount = try unescapeMount(gpa, escaped);
        if (!isAtOrBelow(mount, under)) {
            gpa.free(mount);
            continue;
        }
        out.append(gpa, mount) catch |err| {
            gpa.free(mount);
            return err;
        };
    }
    return out.toOwnedSlice(gpa);
}

/// `path` is `root` itself or inside it ("/home/u" is below "/home", and
/// "/homework" is not).
fn isAtOrBelow(path: []const u8, root: []const u8) bool {
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
fn unescapeMount(gpa: std.mem.Allocator, escaped: []const u8) std.mem.Allocator.Error![]u8 {
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
    return gpa.dupe(u8, unescaped[0..unescaped_len]);
}

test "slow mounts: escapes undone, only below the root" {
    const gpa = std.testing.allocator;
    const mount = try unescapeMount(gpa, "/home/u/my\\040share");
    defer gpa.free(mount);
    try std.testing.expectEqualStrings("/home/u/my share", mount);
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
