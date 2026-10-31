//! What a path is, without opening it: its kind, size and modification
//! time (statx), whether it exists, and a `Stamp` that tells whether it
//! changed since it was last looked at.

const std = @import("std");
const linux = std.os.linux;

/// A file's identity for "did it change?": modification time to the
/// nanosecond, size and inode (editors that save by renaming a new file).
pub const Stamp = struct {
    mtime_s: i64 = -1,
    mtime_subsecond_ns: u32 = 0,
    size: u64 = 0,
    inode: u64 = 0,

    /// What no file has: the first look always counts as a change.
    pub const none: Stamp = .{};

    pub fn of(path: [*:0]const u8) Stamp {
        var stx: linux.Statx = undefined;
        const result = linux.statx(
            linux.AT.FDCWD,
            path,
            0,
            .{ .SIZE = true, .MTIME = true, .INO = true },
            &stx,
        );
        if (linux.errno(result) != .SUCCESS) return .{};
        return .{
            .mtime_s = stx.mtime.sec,
            .mtime_subsecond_ns = stx.mtime.nsec,
            .size = stx.size,
            .inode = stx.ino,
        };
    }

    pub fn eql(left: Stamp, right: Stamp) bool {
        return std.meta.eql(left, right);
    }
};

pub const Kind = struct {
    pub const directory = linux.DT.DIR;
    pub const symlink = linux.DT.LNK;
    pub const unknown = linux.DT.UNKNOWN;
};

/// d_type is UNKNOWN on some filesystems: then a statx tells.
pub fn kindOf(path: [*:0]const u8) u8 {
    var stx: linux.Statx = undefined;
    const result = linux.statx(
        linux.AT.FDCWD,
        path,
        linux.AT.SYMLINK_NOFOLLOW,
        .{ .TYPE = true },
        &stx,
    );
    if (linux.errno(result) != .SUCCESS) return Kind.unknown;
    return switch (stx.mode & linux.S.IFMT) {
        linux.S.IFDIR => Kind.directory,
        linux.S.IFLNK => Kind.symlink,
        else => linux.DT.REG,
    };
}

/// True for a regular file (not a FIFO, device, socket or directory).
pub fn isRegular(path: [*:0]const u8) bool {
    var stx: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &stx);
    return linux.errno(result) == .SUCCESS and stx.mode & linux.S.IFMT == linux.S.IFREG;
}

pub fn exists(path: [*:0]const u8) bool {
    return linux.errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0)) == .SUCCESS;
}

/// Modification time in unix seconds, or null.
pub fn mtime(path: [*:0]const u8) ?i64 {
    var stx: linux.Statx = undefined;
    const result = linux.statx(
        linux.AT.FDCWD,
        path,
        linux.AT.SYMLINK_NOFOLLOW,
        .{ .MTIME = true },
        &stx,
    );
    if (linux.errno(result) != .SUCCESS) return null;
    return stx.mtime.sec;
}

pub const Info = struct { size: u64, mtime: i64, is_dir: bool };

pub fn info(path: [*:0]const u8) ?Info {
    var stx: linux.Statx = undefined;
    const result = linux.statx(
        linux.AT.FDCWD,
        path,
        0,
        .{ .TYPE = true, .SIZE = true, .MTIME = true },
        &stx,
    );
    if (linux.errno(result) != .SUCCESS) return null;
    return .{
        .size = stx.size,
        .mtime = stx.mtime.sec,
        .is_dir = stx.mode & linux.S.IFMT == linux.S.IFDIR,
    };
}
