//! The Linux calls Lumen makes itself, straight through `std.os.linux`:
//! files, time, sockets, waiting on descriptors. No libc, so the static
//! `lumen` client uses it too.

const std = @import("std");
const assert = std.debug.assert;
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

/// `openDir` that refuses a symbolic link. The file index uses it below its
/// root: a folder swapped for a link to `/` between the event and the read
/// was walked whole, under the lock searches wait on.
pub fn openDirNoFollow(path: [*:0]const u8) Error!i32 {
    const rc = try check(linux.open(
        path,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true },
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

    pub fn next(iterator: *DirIter) Error!?Entry {
        while (true) {
            if (iterator.pos == iterator.end) {
                const buf = &iterator.buf;
                const bytes_read = try check(linux.getdents64(iterator.fd, buf, buf.len));
                if (bytes_read == 0) return null;
                iterator.pos = 0;
                iterator.end = bytes_read;
            }
            const entry_start = iterator.pos;
            const dirent: *align(1) linux.dirent64 = @ptrCast(&iterator.buf[entry_start]);
            // A zero-length record would never advance: a bug in the
            // kernel's buffer, or in this walk of it.
            assert(dirent.reclen > 0);
            iterator.pos += dirent.reclen;
            assert(iterator.pos <= iterator.end);
            const name_offset = entry_start + @offsetOf(linux.dirent64, "name");
            const name_ptr: [*:0]const u8 = @ptrCast(&iterator.buf[name_offset]);
            const name = std.mem.span(name_ptr);
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
    if (entry.kind == Kind.dir) return true;
    if (entry.kind != Kind.symlink and entry.kind != Kind.unknown) return false;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full = std.mem.printSentinel(&buf, "{s}/{s}", .{ path, entry.name }, 0) catch {
        return false;
    };
    const entry_info = info(full) orelse return false;
    return entry_info.is_dir;
}

/// A file's identity for "did it change?": modification time to the
/// nanosecond, size and inode (editors that save by renaming a new file).
pub const Stamp = struct {
    sec: i64 = -1,
    nsec: u32 = 0,
    size: u64 = 0,
    ino: u64 = 0,

    /// What no file has: the first look always counts as a change.
    pub const none: Stamp = .{};

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

    pub fn eql(left: Stamp, right: Stamp) bool {
        return std.meta.eql(left, right);
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

/// Mount points at or below `under` whose file system can hang a `stat`:
/// network file systems and FUSE (sshfs, rclone), where a server that stops
/// answering blocks every call into the mount. From /proc/self/mountinfo;
/// empty when it cannot be read. Free with `freeList`.
pub fn slowMounts(gpa: std.mem.Allocator, under: []const u8) std.mem.Allocator.Error![][]u8 {
    const fd = openRegular("/proc/self/mountinfo") catch return &.{};
    defer close(fd);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try readUpTo(gpa, fd, &text, 4 << 20);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |mount| gpa.free(mount);
        out.deinit(gpa);
    }
    var lines = std.mem.tokenizeScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        // "id parent dev root MOUNT options... - FSTYPE source options"
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

fn mayHang(fstype: []const u8) bool {
    // Plain "fuseblk" is a local disk (ntfs-3g).
    if (std.mem.startsWith(u8, fstype, "fuse.")) return true;
    if (std.mem.eql(u8, fstype, "fuse")) return true;
    const network = [_][]const u8{
        "nfs",  "nfs4",      "cifs",   "smb3", "smbfs", "9p",
        "ceph", "glusterfs", "lustre", "afs",  "davfs", "ncpfs",
    };
    for (network) |network_fstype| {
        if (std.mem.eql(u8, fstype, network_fstype)) return true;
    }
    return false;
}

/// mountinfo writes space, tab, newline and backslash as `\ooo`.
fn unescapeMount(gpa: std.mem.Allocator, escaped: []const u8) std.mem.Allocator.Error![]u8 {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var pos: usize = 0;
    while (pos < escaped.len and len < buf.len) : (len += 1) {
        if (escaped[pos] == '\\' and pos + 3 < escaped.len) {
            if (std.fmt.parseInt(u8, escaped[pos + 1 .. pos + 4], 8)) |byte| {
                buf[len] = byte;
                pos += 4;
                continue;
            } else |_| {}
        }
        buf[len] = escaped[pos];
        pos += 1;
    }
    return gpa.dupe(u8, buf[0..len]);
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

pub fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    // These clocks exist on every Linux Lumen runs on: a failure is a bug.
    assert(linux.errno(linux.clock_gettime(.REALTIME, &ts)) == .SUCCESS);
    return ts.sec;
}

pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    assert(linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) == .SUCCESS);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Sleeps `us` microseconds; a signal may cut it short.
pub fn sleepUs(us: u64) void {
    const nsec = (us % std.time.us_per_s) * std.time.ns_per_us;
    const ts: linux.timespec = .{ .sec = @intCast(us / std.time.us_per_s), .nsec = @intCast(nsec) };
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
    var written: usize = 0;
    while (written < data.len) {
        const rest = data[written..];
        const rc = if (at) |offset|
            linux.pwrite(fd, rest.ptr, rest.len, @intCast(offset + written))
        else
            linux.write(fd, rest.ptr, rest.len);
        if (linux.errno(rc) == .INTR) continue;
        written += try check(rc);
    }
    assert(written == data.len);
}

/// Reads `fd` into `buf` until its end or `buf` holds `max_bytes` (it can
/// hold a little more: a read is not cut short). A read error ends it.
pub fn readUpTo(
    gpa: std.mem.Allocator,
    fd: i32,
    buf: *std.ArrayList(u8),
    max_bytes: usize,
) std.mem.Allocator.Error!void {
    while (buf.items.len < max_bytes) {
        try buf.ensureUnusedCapacity(gpa, 64 * 1024);
        const spare = buf.unusedCapacitySlice();
        const bytes_read = linux.read(fd, spare.ptr, spare.len);
        switch (linux.errno(bytes_read)) {
            .SUCCESS => {
                if (bytes_read == 0) return;
                buf.items.len += bytes_read;
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
    var file = try AtomicFile.create(path);
    errdefer file.abort();
    try file.write(data);
    try file.commit();
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
        var file: AtomicFile = .{ .fd = -1 };
        const print = std.mem.printSentinel;
        const final = print(&file.final, "{s}", .{path}, 0) catch return error.NameTooLong;
        const tmp = print(&file.tmp, "{s}.tmp", .{path}, 0) catch return error.NameTooLong;
        assert(final.len > 0);
        assert(tmp.len > final.len);
        file.final_len = final.len;
        file.tmp_len = tmp.len;
        file.fd = try openTemp(tmp);
        return file;
    }

    /// A new file, never one that is there: `O_TRUNC` wrote through a link
    /// planted at `<path>.tmp`. One left by a crash midway is removed first.
    fn openTemp(tmp: [*:0]const u8) Error!i32 {
        const flags: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        };
        var rc = linux.open(tmp, flags, 0o600);
        if (linux.errno(rc) == .EXIST) {
            _ = linux.unlink(tmp);
            rc = linux.open(tmp, flags, 0o600);
        }
        return @intCast(try check(rc));
    }

    pub fn write(file: *AtomicFile, data: []const u8) Error!void {
        assert(file.fd >= 0);
        try writeAll(file.fd, data);
    }

    pub fn writeAt(file: *AtomicFile, data: []const u8, at: usize) Error!void {
        assert(file.fd >= 0);
        try writeAllAt(file.fd, data, at);
    }

    pub fn commit(file: *AtomicFile) Error!void {
        assert(file.fd >= 0);
        errdefer file.abort();
        _ = try check(linux.fsync(file.fd));
        close(file.fd);
        file.fd = -1;
        try rename(file.tmp[0..file.tmp_len :0], file.final[0..file.final_len :0]);
    }

    /// Safe to call after a failed `commit` (it already aborted).
    pub fn abort(file: *AtomicFile) void {
        if (file.fd >= 0) close(file.fd);
        file.fd = -1;
        _ = linux.unlink(file.tmp[0..file.tmp_len :0]);
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

    pub fn write(file: *AppendFile, data: []const u8) Error!void {
        try file.writeAt(data, file.len);
        file.len += data.len;
    }

    pub fn writeAt(file: *AppendFile, data: []const u8, at: usize) Error!void {
        try writeAllAt(file.fd, data, at);
    }

    pub fn sync(file: *AppendFile) Error!void {
        _ = try check(linux.fsync(file.fd));
    }

    pub fn deinit(file: *AppendFile) void {
        close(file.fd);
    }
};

/// Creates missing directories, owner-only (existing ones are untouched).
pub fn mkdirP(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return;
    // Each prefix that ends a component, the whole path last. A mkdir that
    // fails (it exists, or a parent could not be made) is left for the
    // caller's next step to notice.
    var end: usize = 1;
    while (end <= path.len) : (end += 1) {
        if (end == path.len or path[end] == '/') {
            @memcpy(buf[0..end], path[0..end]);
            buf[end] = 0;
            _ = linux.mkdir(@ptrCast(&buf), 0o700);
        }
    }
}

/// Makes an existing directory of Lumen's owner-only: caches made by
/// earlier versions were 0755, with world-readable files inside.
pub fn makePrivate(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path_z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return;
    _ = linux.chmod(path_z, 0o700);
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
    const mapping: [*]align(8) u8 = @ptrFromInt(addr);
    return mapping[0..size];
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

    pub fn deinit(test_dir: *TestDir) void {
        std.testing.allocator.free(test_dir.abs);
        test_dir.tmp.cleanup();
    }

    /// Absolute path of `name`, in the caller's `buf`.
    pub fn path(test_dir: *const TestDir, buf: []u8, name: []const u8) ![:0]u8 {
        return std.mem.printSentinel(buf, "{s}/{s}", .{ test_dir.abs, name }, 0);
    }

    /// Writes `name` (creating parent dirs) with `data`.
    pub fn write(test_dir: *const TestDir, name: []const u8, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const file_path = try test_dir.path(&buf, name);
        if (std.mem.findScalarLast(u8, file_path, '/')) |slash| mkdirP(file_path[0..slash]);
        try writeFile(file_path, data);
    }

    pub fn mkdir(test_dir: *const TestDir, name: []const u8) !void {
        var buf: [4096]u8 = undefined;
        mkdirP(try test_dir.path(&buf, name));
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
    for ([_][]const u8{ "b", "a", ".hidden", "skip" }) |d| mkdirP(try std.mem.print(
        &pbuf,
        "{s}/{s}",
        .{ root, d },
    ));
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
    for ([_][]const u8{
        "a",
        "b",
        "c",
    }, names) |want, got| try std.testing.expectEqualStrings(want, got);
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

test "atomic writes never write through a temporary left in the way" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpDirPath(&tmp, &dbuf);
    var pbuf: [4096]u8 = undefined;
    const p = try std.mem.print(&pbuf, "{s}/f.idx", .{dir});
    var tbuf: [4096]u8 = undefined;
    const t = try std.mem.printSentinel(&tbuf, "{s}.tmp", .{p}, 0);
    var vbuf: [4096]u8 = undefined;
    const victim = try std.mem.printSentinel(&vbuf, "{s}/victim", .{dir}, 0);
    var rbuf: [16]u8 = undefined;
    var zbuf: [4096]u8 = undefined;
    const pz = try std.mem.printSentinel(&zbuf, "{s}", .{p}, 0);

    // A link to someone else's file: replaced, the file untouched.
    try writeFile(victim, "keep");
    _ = linux.symlink(victim, t);
    try writeFileAtomic(p, "new");
    try std.testing.expectEqualStrings("keep", readHead(victim, &rbuf));
    try std.testing.expectEqualStrings("new", readHead(pz, &rbuf));
    try std.testing.expect(!exists(t));

    // A crash's leftover: removed, the write goes through.
    try writeFile(t, "half a file");
    try writeFileAtomic(p, "newer");
    try std.testing.expectEqualStrings("newer", readHead(pz, &rbuf));
    try std.testing.expect(!exists(t));
}

test "openDirNoFollow refuses a link to a folder, openDir follows it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpDirPath(&tmp, &dbuf);
    var abuf: [4096]u8 = undefined;
    const real = try std.mem.printSentinel(&abuf, "{s}/real", .{dir}, 0);
    mkdirP(real);
    var lbuf: [4096]u8 = undefined;
    const link = try std.mem.printSentinel(&lbuf, "{s}/link", .{dir}, 0);
    _ = linux.symlink("real", link);
    close(try openDirNoFollow(real));
    close(try openDir(link));
    if (openDirNoFollow(link)) |fd| {
        close(fd);
        return error.TestUnexpectedResult;
    } else |_| {}
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
