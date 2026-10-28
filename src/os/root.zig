//! The Linux calls Lumen makes itself, straight through `std.os.linux`:
//! files, time, sockets, waiting on descriptors. No libc, so the static
//! `lumen` client uses it too.

const std = @import("std");
const linux = std.os.linux;

pub const unix = @import("unix.zig");
pub const child = @import("child.zig");

pub const Error = error{ Syscall, NotFound, Access, NotRegular, NameTooLong };

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOENT, .NOTDIR => error.NotFound,
        .ACCES, .PERM => error.Access,
        else => error.Syscall,
    };
}

pub fn openDir(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.open(
        path,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
        0,
    ));
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
            const name_ptr: [*:0]const u8 = @ptrCast(
                &it.buf[it.pos - d.reclen + @offsetOf(linux.dirent64, "name")],
            );
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .kind = d.type };
        }
    }
};

/// Names of the folders directly in `path` (links to folders count), that
/// `keep` accepts, sorted, in `a`. Hidden ones are skipped. Empty when the
/// folder cannot be read; out of memory, the ones found so far.
pub fn subdirs(a: std.mem.Allocator, path: [:0]const u8, keep: *const fn ([]const u8) bool) []const [:0]const u8 {
    const fd = openDir(path) catch return &.{};
    defer close(fd);
    var it: DirIter = .{ .fd = fd };
    var names: std.ArrayList([:0]const u8) = .empty;
    while (it.next() catch null) |e| {
        if (e.name[0] == '.' or !keep(e.name)) continue;
        if (e.kind != Kind.dir) {
            if (e.kind != Kind.symlink and e.kind != Kind.unknown) continue;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full = std.mem.printSentinel(&buf, "{s}/{s}", .{ path, e.name }, 0) catch continue;
            const i = info(full) orelse continue;
            if (!i.is_dir) continue;
        }
        names.append(a, a.dupeSentinel(u8, e.name, 0) catch break) catch break;
    }
    std.mem.sort([:0]const u8, names.items, {}, struct {
        fn lt(_: void, x: [:0]const u8, y: [:0]const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return names.items;
}

/// A file's identity for "did it change?": modification time to the
/// nanosecond, size and inode (editors that save by renaming a new file).
pub const Stamp = struct {
    /// What no file has: the first look always counts as a change.
    pub const none: Stamp = .{};

    sec: i64 = -1,
    nsec: u32 = 0,
    size: u64 = 0,
    ino: u64 = 0,

    pub fn of(path: [*:0]const u8) Stamp {
        var st: linux.Statx = undefined;
        const rc = linux.statx(
            linux.AT.FDCWD,
            path,
            0,
            .{ .SIZE = true, .MTIME = true, .INO = true },
            &st,
        );
        if (linux.errno(rc) != .SUCCESS) return .{};
        return .{ .sec = st.mtime.sec, .nsec = st.mtime.nsec, .size = st.size, .ino = st.ino };
    }

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.sec == b.sec and a.nsec == b.nsec and a.size == b.size and a.ino == b.ino;
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
    const rc = linux.statx(
        linux.AT.FDCWD,
        path,
        linux.AT.SYMLINK_NOFOLLOW,
        .{ .TYPE = true },
        &stx,
    );
    if (linux.errno(rc) != .SUCCESS) return Kind.unknown;
    return switch (stx.mode & linux.S.IFMT) {
        linux.S.IFDIR => Kind.dir,
        linux.S.IFLNK => Kind.symlink,
        else => linux.DT.REG,
    };
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
    const rc = linux.statx(
        linux.AT.FDCWD,
        path,
        linux.AT.SYMLINK_NOFOLLOW,
        .{ .MTIME = true },
        &stx,
    );
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.mtime.sec;
}

pub const Info = struct { size: u64, mtime: i64, is_dir: bool };

pub fn info(path: [*:0]const u8) ?Info {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(
        linux.AT.FDCWD,
        path,
        0,
        .{ .TYPE = true, .SIZE = true, .MTIME = true },
        &stx,
    );
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{
        .size = stx.size,
        .mtime = stx.mtime.sec,
        .is_dir = stx.mode & linux.S.IFMT == linux.S.IFDIR,
    };
}

/// Opens a file for reading only if it is a regular file. The index can
/// point at a path that has since become a FIFO or a device: a blocking open
/// of a FIFO waits for a writer forever, and that froze the whole launcher
/// (search verification runs while the UI waits). O_NONBLOCK makes the open
/// return at once; then fstat decides.
pub fn openRegular(path: [*:0]const u8) Error!i32 {
    const fd: i32 = @intCast(try check(linux.open(
        path,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true },
        0,
    )));
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
    const ts: linux.timespec = .{ .sec = @intCast(us / std.time.us_per_s), .nsec = @intCast(
        (us % std.time.us_per_s) * 1000,
    ) };
    _ = linux.nanosleep(&ts, null);
}

/// Lumen's own files (indexes, extracted text) hold the names and text of
/// the user's documents: owner-only, never world-readable.
pub fn writeFile(path: [*:0]const u8, data: []const u8) Error!void {
    const fd: i32 = @intCast(try check(linux.open(
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o600,
    )));
    defer close(fd);
    try writeAll(fd, data);
}

/// Writes all of `data` at the descriptor's position, or at `at` (pwrite).
pub fn writeAll(fd: i32, data: []const u8) Error!void {
    return writeAllAt(fd, data, null);
}

pub fn writeAllAt(fd: i32, data: []const u8, at: ?usize) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const rest = data[off..];
        const rc = if (at) |a|
            linux.pwrite(fd, rest.ptr, rest.len, @intCast(a + off))
        else
            linux.write(fd, rest.ptr, rest.len);
        if (linux.errno(rc) == .INTR) continue;
        off += try check(rc);
    }
}

/// Reads `fd` into `buf` until its end or `buf` holds `max_bytes` (it can
/// hold a little more: a read is not cut short). A read error ends it.
pub fn readUpTo(gpa: std.mem.Allocator, fd: i32, buf: *std.ArrayList(u8), max_bytes: usize) std.mem.Allocator.Error!void {
    while (buf.items.len < max_bytes) {
        try buf.ensureUnusedCapacity(gpa, 64 * 1024);
        const spare = buf.unusedCapacitySlice();
        const n = linux.read(fd, spare.ptr, spare.len);
        switch (linux.errno(n)) {
            .SUCCESS => if (n == 0) return else {
                buf.items.len += n;
            },
            .INTR => {},
            else => return,
        }
    }
}

pub fn rename(from: [*:0]const u8, to: [*:0]const u8) Error!void {
    _ = try check(linux.rename(from, to));
}

/// Writes `path` whole through `<path>.tmp`, fsync and rename: a crash or a
/// full disk never leaves a truncated `path` behind, and a failed write
/// leaves no `.tmp`. Owner-only.
pub fn writeFileAtomic(path: []const u8, data: []const u8) Error!void {
    var f = try AtomicFile.create(path);
    errdefer f.abort();
    try f.write(data);
    try f.commit();
}

/// `writeFileAtomic` a piece at a time: `<path>.tmp`, written in order, a
/// header patched in at the end, fsync and rename on `commit`; `abort` (or
/// a failed commit) leaves `path` as it was.
pub const AtomicFile = struct {
    fd: i32,
    tmp: [4096]u8 = undefined,
    final: [4096]u8 = undefined,
    tmp_len: usize = 0,
    final_len: usize = 0,

    pub fn create(path: []const u8) Error!AtomicFile {
        var f: AtomicFile = .{ .fd = -1 };
        const final = std.mem.printSentinel(
            &f.final,
            "{s}",
            .{path},
            0,
        ) catch return error.NameTooLong;
        const tmp = std.mem.printSentinel(
            &f.tmp,
            "{s}.tmp",
            .{path},
            0,
        ) catch return error.NameTooLong;
        f.final_len = final.len;
        f.tmp_len = tmp.len;
        f.fd = @intCast(try check(linux.open(
            tmp,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            0o600,
        )));
        return f;
    }

    pub fn write(f: *AtomicFile, data: []const u8) Error!void {
        try writeAll(f.fd, data);
    }

    pub fn writeAt(f: *AtomicFile, data: []const u8, at: usize) Error!void {
        try writeAllAt(f.fd, data, at);
    }

    pub fn commit(f: *AtomicFile) Error!void {
        errdefer f.abort();
        _ = try check(linux.fsync(f.fd));
        close(f.fd);
        f.fd = -1;
        try rename(f.tmp[0..f.tmp_len :0], f.final[0..f.final_len :0]);
    }

    pub fn abort(f: *AtomicFile) void {
        if (f.fd >= 0) close(f.fd);
        f.fd = -1;
        _ = linux.unlink(f.tmp[0..f.tmp_len :0]);
    }
};

/// Grows a file in place: what is written goes past its current end, then
/// `writeAt` patches the start (a header pointing at it) and `sync` makes it
/// durable. Nothing written before is touched, so mappings of it stay valid.
pub const AppendFile = struct {
    fd: i32,
    /// Where the next `write` goes.
    len: usize,

    /// Null when the file is not `expect_len` bytes long (someone else wrote
    /// it): the caller rewrites it whole instead.
    pub fn open(path: [*:0]const u8, expect_len: usize) Error!?AppendFile {
        const fd: i32 = @intCast(try check(linux.open(
            path,
            .{ .ACCMODE = .WRONLY, .CLOEXEC = true },
            0,
        )));
        errdefer close(fd);
        const size = try check(linux.lseek(fd, 0, linux.SEEK.END));
        if (size != expect_len) {
            close(fd);
            return null;
        }
        return .{ .fd = fd, .len = size };
    }

    pub fn write(f: *AppendFile, data: []const u8) Error!void {
        try f.writeAt(data, f.len);
        f.len += data.len;
    }

    pub fn writeAt(f: *AppendFile, data: []const u8, at: usize) Error!void {
        try writeAllAt(f.fd, data, at);
    }

    pub fn sync(f: *AppendFile) Error!void {
        _ = try check(linux.fsync(f.fd));
    }

    pub fn deinit(f: *AppendFile) void {
        close(f.fd);
    }
};

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
    const z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return;
    _ = linux.chmod(z, 0o700);
}

pub fn unmap(buf: []align(8) u8) void {
    _ = linux.munmap(buf.ptr, buf.len);
}

/// Private, writable (copy-on-write) mapping of a whole file.
pub fn mapPrivate(path: [*:0]const u8) Error![]align(8) u8 {
    const fd = try openRegular(path);
    defer close(fd);
    const size = try check(linux.lseek(fd, 0, linux.SEEK.END));
    if (size == 0) return error.NotFound;
    const addr = try check(linux.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ));
    const p: [*]align(8) u8 = @ptrFromInt(addr);
    return p[0..size];
}

/// A testing tmp dir with its absolute path (tests run from the build
/// root; what they test often takes absolute paths), and files in it.
pub const TestDir = struct {
    tmp: std.testing.TmpDir,
    abs: []u8,

    pub fn init() !TestDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var rel_buf: [256]u8 = undefined;
        const rel = try tmpDirPath(&tmp, &rel_buf);
        const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
        defer std.testing.allocator.free(cwd);
        return .{ .tmp = tmp, .abs = try std.testing.allocator.print("{s}/{s}", .{ cwd, rel }) };
    }

    pub fn deinit(t: *TestDir) void {
        std.testing.allocator.free(t.abs);
        t.tmp.cleanup();
    }

    /// Absolute path of `name` (static buffer per call site is the caller's).
    pub fn path(t: *const TestDir, buf: []u8, name: []const u8) ![:0]u8 {
        return std.mem.printSentinel(buf, "{s}/{s}", .{ t.abs, name }, 0);
    }

    /// Writes `name` (creating parent dirs) with `data`.
    pub fn write(t: *const TestDir, name: []const u8, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const p = try t.path(&buf, name);
        if (std.mem.findScalarLast(u8, p, '/')) |slash| mkdirP(p[0..slash]);
        try writeFile(p, data);
    }

    pub fn mkdir(t: *const TestDir, name: []const u8) !void {
        var buf: [4096]u8 = undefined;
        mkdirP(try t.path(&buf, name));
    }
};

/// Absolute path of a testing tmp dir, in `buf`.
pub fn tmpDirAbs(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = std.mem.sliceTo(cwd_buf[0..linux.getcwd(&cwd_buf, cwd_buf.len)], 0);
    var rel_buf: [256]u8 = undefined;
    return std.mem.print(buf, "{s}/{s}", .{ cwd, try tmpDirPath(tmp, &rel_buf) });
}

/// Path of a testing tmp dir relative to the build root (where tests run).
pub fn tmpDirPath(tmp: *std.testing.TmpDir, buf: []u8) std.mem.PrintError![]const u8 {
    return std.mem.print(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

/// Waits for child `pid` to exit, until `deadline_ns` (monotonic): true when
/// it did (it is left to be reaped). Without a pidfd (old kernel, no free
/// descriptor) it does not wait: false, so the caller kills it, and
/// reaping a killed child cannot hang.
pub fn waitExit(pid: linux.pid_t, deadline_ns: u64) bool {
    const fd = linux.pidfd_open(pid, 0);
    if (linux.errno(fd) != .SUCCESS) return false;
    defer close(@intCast(fd));
    const left_ns = deadline_ns -| monotonicNs();
    const left_ms: i32 = @intCast(@min(left_ns / std.time.ns_per_ms, std.math.maxInt(i32)));
    return waitReadable(@intCast(fd), left_ms);
}

/// Waits until `fd` is readable (true) or `wake` is written (false). Without
/// `wake` (-1), it gives up every 100 ms so the caller can look around.
pub fn waitEvents(fd: i32, wake: i32) bool {
    var pfd = [2]linux.pollfd{
        .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = wake, .events = linux.POLL.IN, .revents = 0 },
    };
    const n: usize = if (wake < 0) 1 else 2;
    const rc = linux.poll(&pfd, n, if (wake < 0) 100 else -1);
    return linux.errno(rc) == .SUCCESS and rc > 0 and pfd[0].revents & linux.POLL.IN != 0;
}

pub fn waitReadable(fd: i32, timeout_ms: i32) bool {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&pfd, 1, timeout_ms);
    return linux.errno(rc) == .SUCCESS and rc > 0;
}

test "subdirs: folders and links to them, sorted, filtered" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const root = try tmpDirPath(&tmp, &buf);
    var pbuf: [512]u8 = undefined;
    for ([_][]const u8{ "b", "a", ".hidden", "skip" }) |d| mkdirP(try std.mem.print(&pbuf, "{s}/{s}", .{ root, d }));
    try writeFile(try std.mem.printSentinel(&pbuf, "{s}/file", .{root}, 0), "x");
    var lbuf: [512]u8 = undefined;
    _ = linux.symlink("a", try std.mem.printSentinel(&lbuf, "{s}/c", .{root}, 0));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root_z = try arena.allocator().dupeSentinel(u8, root, 0);
    const names = subdirs(arena.allocator(), root_z, struct {
        fn keep(n: []const u8) bool {
            return !std.mem.eql(u8, n, "skip");
        }
    }.keep);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    for ([_][]const u8{ "a", "b", "c" }, names) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "special files are refused without blocking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const fifo = try std.mem.printSentinel(&pbuf, "{s}/pipe", .{dir}, 0);
    _ = linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0);
    var buf: [64]u8 = undefined;
    // Each of these used to block forever on a FIFO with no writer.
    try std.testing.expectEqualStrings("", readHead(fifo, &buf));
    try std.testing.expectError(error.NotRegular, mapPrivate(fifo));
    try std.testing.expect(!isRegular(fifo));
    try std.testing.expectEqualStrings("", readHead("/dev/null", &buf));
    try std.testing.expect(isRegular("/proc/self/status"));
}

test "atomic writes replace the file and leave no temporary behind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.mem.print(&pbuf, "{s}/f.conf", .{dir});
    try writeFileAtomic(p, "old");
    try writeFileAtomic(p, "new");
    var rbuf: [16]u8 = undefined;
    var zbuf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("new", readHead(
        try std.mem.printSentinel(&zbuf, "{s}", .{p}, 0),
        &rbuf,
    ));
    try std.testing.expect(!exists(try std.mem.printSentinel(&zbuf, "{s}.tmp", .{p}, 0)));
    // A directory that is not there: an error, and nothing left over.
    const bad = try std.mem.print(&pbuf, "{s}/missing/f.conf", .{dir});
    try std.testing.expectError(error.NotFound, writeFileAtomic(bad, "x"));
}

test "Lumen's files and directories are owner-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const sub = try std.mem.print(&pbuf, "{s}/cache/lumen", .{dir});
    mkdirP(sub);
    var fbuf: [4096]u8 = undefined;
    const f = try std.mem.printSentinel(&fbuf, "{s}/x.idx", .{sub}, 0);
    try writeFile(f, "data");
    const mode = struct {
        fn of(p: [*:0]const u8) u32 {
            var stx: linux.Statx = undefined;
            _ = linux.statx(linux.AT.FDCWD, p, 0, .{ .MODE = true }, &stx);
            return stx.mode & 0o777;
        }
    }.of;
    var zbuf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0o700), mode(
        try std.mem.printSentinel(&zbuf, "{s}", .{sub}, 0),
    ));
    try std.testing.expectEqual(@as(u32, 0o600), mode(f));
    _ = linux.chmod(try std.mem.printSentinel(&zbuf, "{s}", .{sub}, 0), 0o755);
    makePrivate(sub);
    try std.testing.expectEqual(@as(u32, 0o700), mode(
        try std.mem.printSentinel(&zbuf, "{s}", .{sub}, 0),
    ));
}

test {
    std.testing.refAllDecls(@This());
}
