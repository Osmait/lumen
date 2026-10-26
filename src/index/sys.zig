//! The few Linux calls the index makes, straight through `std.os.linux`.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ Syscall, NotFound, Access, NotRegular };

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT, .NOTDIR => error.NotFound,
        .ACCES, .PERM => error.Access,
        else => error.Syscall,
    };
}

pub fn openDir(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0));
    return @intCast(rc);
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

/// Entries of an open directory, from the kernel's getdents64 buffer: name and
/// d_type come for free, no stat per entry.
pub const DirIter = struct {
    fd: i32,
    buf: [32 * 1024]u8 align(8) = undefined,
    pos: usize = 0,
    end: usize = 0,

    pub const Entry = struct { name: []const u8, kind: u8 };

    pub fn next(it: *DirIter) Error!?Entry {
        while (true) {
            if (it.pos >= it.end) {
                const n = try check(linux.getdents64(it.fd, &it.buf, it.buf.len));
                if (n == 0) return null;
                it.pos = 0;
                it.end = n;
            }
            const d: *align(1) linux.dirent64 = @ptrCast(&it.buf[it.pos]);
            it.pos += d.reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(&it.buf[it.pos - d.reclen + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .kind = d.type };
        }
    }
};

pub const Kind = struct {
    pub const dir = linux.DT.DIR;
    pub const symlink = linux.DT.LNK;
    pub const unknown = linux.DT.UNKNOWN;
};

/// d_type is UNKNOWN on some filesystems: then a statx tells.
pub fn kindOf(path: [*:0]const u8) u8 {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return Kind.unknown;
    return switch (stx.mode & linux.S.IFMT) {
        linux.S.IFDIR => Kind.dir,
        linux.S.IFLNK => Kind.symlink,
        else => linux.DT.REG,
    };
}

extern fn malloc_trim(pad: usize) c_int;

/// Hands freed heap back to the kernel. glibc keeps freed blocks for reuse;
/// after a rebuild (hundreds of MB of temporary pairs) that is memory the
/// daemon would otherwise sit on until it exits.
pub fn trimHeap() void {
    _ = malloc_trim(0);
}

/// True for a regular file (not a FIFO, device, socket or directory).
pub fn isRegular(path: [*:0]const u8) bool {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &stx);
    return linux.errno(rc) == .SUCCESS and stx.mode & linux.S.IFMT == linux.S.IFREG;
}

pub fn exists(path: [*:0]const u8) bool {
    return linux.errno(linux.faccessat(linux.AT.FDCWD, path, linux.F_OK, 0)) == .SUCCESS;
}

/// Modification time in unix seconds, or null.
pub fn mtime(path: [*:0]const u8) ?i64 {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .MTIME = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.mtime.sec;
}

pub const Info = struct { size: u64, mtime: i64, is_dir: bool };

pub fn info(path: [*:0]const u8) ?Info {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .size = stx.size, .mtime = stx.mtime.sec, .is_dir = stx.mode & linux.S.IFMT == linux.S.IFDIR };
}

/// Opens a file for reading only if it is a regular file. The index can
/// point at a path that has since become a FIFO or a device: a blocking open
/// of a FIFO waits for a writer forever, and that froze the whole launcher
/// (search verification runs while the UI waits). O_NONBLOCK makes the open
/// return at once; then fstat decides.
pub fn openRegular(path: [*:0]const u8) Error!i32 {
    const fd: i32 = @intCast(try check(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true }, 0)));
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stx);
    if (linux.errno(rc) != .SUCCESS or stx.mode & linux.S.IFMT != linux.S.IFREG) {
        close(fd);
        return error.NotRegular;
    }
    return fd;
}

/// The first bytes of a file (previews). Empty for anything not a regular
/// file.
pub fn readHead(path: [*:0]const u8, buf: []u8) []const u8 {
    const fd = openRegular(path) catch return "";
    defer close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return "";
    return buf[0..n];
}

pub fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleepUs(us: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(us / std.time.us_per_s), .nsec = @intCast((us % std.time.us_per_s) * 1000) };
    _ = linux.nanosleep(&ts, null);
}

/// Lumen's own files (indexes, extracted text) hold the names and text of
/// the user's documents: owner-only, never world-readable.
pub fn writeFile(path: [*:0]const u8, data: []const u8) Error!void {
    const fd: i32 = @intCast(try check(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600)));
    defer close(fd);
    var off: usize = 0;
    while (off < data.len) {
        off += try check(linux.write(fd, data[off..].ptr, data.len - off));
    }
}

pub fn rename(from: [*:0]const u8, to: [*:0]const u8) Error!void {
    _ = try check(linux.rename(from, to));
}

/// Creates missing directories, owner-only (existing ones are untouched).
pub fn mkdirP(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = linux.mkdir(@ptrCast(&buf), 0o700);
        }
    }
}

/// Makes an existing directory of Lumen's owner-only: caches made by
/// earlier versions were 0755, with world-readable files inside.
pub fn makePrivate(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = linux.chmod(z, 0o700);
}

/// Private, writable (copy-on-write) mapping of a whole file.
pub fn mapPrivate(path: [*:0]const u8) Error![]align(8) u8 {
    const fd = try openRegular(path);
    defer close(fd);
    const size = try check(linux.lseek(fd, 0, linux.SEEK.END));
    if (size == 0) return error.NotFound;
    const addr = try check(linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, fd, 0));
    const p: [*]align(8) u8 = @ptrFromInt(addr);
    return p[0..size];
}

/// Absolute-enough path of a testing tmp dir (tests run from the build root).
pub fn tmpDirPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

pub fn waitReadable(fd: i32, timeout_ms: i32) bool {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&pfd, 1, timeout_ms);
    return linux.errno(rc) == .SUCCESS and rc > 0;
}

test "special files are refused without blocking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const fifo = try std.fmt.bufPrintZ(&pbuf, "{s}/pipe", .{dir});
    _ = linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0);
    var buf: [64]u8 = undefined;
    // Each of these used to block forever on a FIFO with no writer.
    try std.testing.expectEqualStrings("", readHead(fifo, &buf));
    try std.testing.expectError(error.NotRegular, mapPrivate(fifo));
    try std.testing.expect(!isRegular(fifo));
    try std.testing.expectEqualStrings("", readHead("/dev/null", &buf));
    try std.testing.expect(isRegular("/proc/self/status"));
}

test "Lumen's files and directories are owner-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const sub = try std.fmt.bufPrint(&pbuf, "{s}/cache/lumen", .{dir});
    mkdirP(sub);
    var fbuf: [4096]u8 = undefined;
    const f = try std.fmt.bufPrintZ(&fbuf, "{s}/x.idx", .{sub});
    try writeFile(f, "data");
    const mode = struct {
        fn of(p: [*:0]const u8) u32 {
            var stx: linux.Statx = undefined;
            _ = linux.statx(linux.AT.FDCWD, p, 0, .{ .MODE = true }, &stx);
            return stx.mode & 0o777;
        }
    }.of;
    var zbuf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0o700), mode(try std.fmt.bufPrintZ(&zbuf, "{s}", .{sub})));
    try std.testing.expectEqual(@as(u32, 0o600), mode(f));
    _ = linux.chmod(try std.fmt.bufPrintZ(&zbuf, "{s}", .{sub}), 0o755);
    makePrivate(sub);
    try std.testing.expectEqual(@as(u32, 0o700), mode(try std.fmt.bufPrintZ(&zbuf, "{s}", .{sub})));
}
