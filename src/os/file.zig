//! Regular files: opened only when they are regular (a FIFO would block),
//! read whole or in part, written whole, replaced atomically
//! (`AtomicFile`), grown in place (`AppendFile`) and mapped. Every file
//! Lumen writes is owner-only.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const os = @import("root.zig");
const syscall = @import("syscall.zig");
const Error = syscall.Error;
const check = syscall.check;
const close = syscall.close;

/// How much more room `readUpTo` makes each time its buffer fills.
const read_chunk_bytes = 64 << 10;

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
    const result = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stx);
    if (linux.errno(result) != .SUCCESS or stx.mode & linux.S.IFMT != linux.S.IFREG) {
        close(fd);
        return error.NotRegular;
    }
    return fd;
}

/// The first bytes of a file (previews, script headers). Empty for anything
/// not a regular file or if reading fails before EOF.
pub fn readHead(path: [*:0]const u8, head_buffer: []u8) []const u8 {
    const fd = openRegular(path) catch return "";
    defer close(fd);
    var total: usize = 0;
    while (total < head_buffer.len) {
        const rest = head_buffer[total..];
        const bytes_read = linux.read(fd, rest.ptr, rest.len);
        switch (linux.errno(bytes_read)) {
            .SUCCESS => {
                if (bytes_read == 0) break;
                total += bytes_read;
            },
            .INTR => continue,
            else => return "",
        }
    }
    return head_buffer[0..total];
}

/// Ensures `path` is a regular file (never following symlinks) and owner-only
/// (0600). When `create` is true, creates it atomically as 0600 if missing;
/// when `create` is false, a missing file succeeds cleanly.
pub fn ensurePrivateFile(path: [*:0]const u8, create: bool) Error!void {
    const open_result = linux.open(
        path,
        .{
            .ACCMODE = .RDONLY,
            .CREAT = create,
            .NOFOLLOW = true,
            .CLOEXEC = true,
            .NONBLOCK = true,
            .NOCTTY = true,
        },
        0o600,
    );
    switch (linux.errno(open_result)) {
        .SUCCESS => {},
        .NOENT => if (!create) return else return error.NotFound,
        else => {
            _ = try check(open_result);
            unreachable;
        },
    }
    const fd: i32 = @intCast(open_result);
    defer close(fd);
    var stx: linux.Statx = undefined;
    const stx_result = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stx);
    if (linux.errno(stx_result) != .SUCCESS or stx.mode & linux.S.IFMT != linux.S.IFREG) {
        return error.NotRegular;
    }
    _ = try check(linux.fchmod(fd, 0o600));
}

/// Lumen's own files (indexes, extracted text) hold the names and text of
/// the user's documents: owner-only, never world-readable, never following
/// a symbolic link.
pub fn writeFile(path: [*:0]const u8, data: []const u8) Error!void {
    const fd: i32 = @intCast(try check(linux.open(
        path,
        .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        },
        0o600,
    )));
    defer close(fd);
    _ = try check(linux.fchmod(fd, 0o600));
    try writeAll(fd, data);
}

/// Writes all of `data` at the descriptor's position.
pub fn writeAll(fd: i32, data: []const u8) Error!void {
    return writeAllAt(fd, data, null);
}

/// Writes all of `data` at `offset` (pwrite), or at the descriptor's
/// position when it is null.
pub fn writeAllAt(fd: i32, data: []const u8, offset: ?usize) Error!void {
    var written: usize = 0;
    while (written < data.len) {
        const rest = data[written..];
        const result = if (offset) |start|
            linux.pwrite(fd, rest.ptr, rest.len, @intCast(start + written))
        else
            linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(result)) {
            .INTR => continue,
            // A descriptor someone left non-blocking (a pipe from a parent):
            // wait until it takes more, as a blocking one would.
            .AGAIN => {
                // Failed: the write says why.
                _ = os.pollUntil(fd, linux.POLL.OUT, os.deadline_ns_none);
                continue;
            },
            else => {},
        }
        written += try check(result);
    }
    assert(written == data.len);
}

pub const ReadUpToError = std.mem.Allocator.Error || error{ReadFailed};

/// Reads `fd` into `text` until its end or `text` holds `bytes_max`, never
/// more: each read asks only for the room left. A read that fails is
/// `error.ReadFailed`, with what was read before it left in `text`: it is
/// not the whole file, so it must not be taken for it.
pub fn readUpTo(
    gpa: std.mem.Allocator,
    fd: i32,
    text: *std.ArrayList(u8),
    bytes_max: usize,
) ReadUpToError!void {
    while (text.items.len < bytes_max) {
        const room = bytes_max - text.items.len;
        try text.ensureUnusedCapacity(gpa, @min(read_chunk_bytes, room));
        const spare = text.unusedCapacitySlice()[0..@min(text.unusedCapacitySlice().len, room)];
        const bytes_read = linux.read(fd, spare.ptr, spare.len);
        switch (linux.errno(bytes_read)) {
            .SUCCESS => {
                if (bytes_read == 0) return;
                text.items.len += bytes_read;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
}

pub fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) Error!void {
    _ = try check(linux.rename(old_path, new_path));
}

/// Writes `path` whole through `<path>.<pid>.<seq>.tmp`, fsync and rename: a
/// crash or a full disk never leaves a truncated `path` behind, and a failed
/// write leaves no `.tmp`. Owner-only.
pub fn writeFileAtomic(path: []const u8, data: []const u8) Error!void {
    var file = try AtomicFile.create(path);
    errdefer file.abort();
    try file.write(data);
    try file.commit();
}

/// Writes `path` atomically and returns a private writable mapping of the exact
/// inode written, before any external writer can replace `path`. Where the
/// file system can clone (`publishClone`), `path` gets a clone and the
/// mapped inode no name, so writing to `path` never reaches the mapping.
pub fn writeFileAtomicMapped(path: []const u8, data: []const u8) Error!MappedBytes {
    if (data.len == 0) return error.NotFound;
    const print = std.mem.printSentinel;
    var final_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var temp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const final_path = print(&final_buf, "{s}", .{path}, 0) catch return error.NameTooLong;
    const pid = linux.getpid();
    const flags: linux.O = .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };
    var fd: i32 = -1;
    var temp_path: [:0]const u8 = "";
    var last_result: usize = 0;
    for (0..AtomicFile.create_attempts_max) |_| {
        const seq = temp_sequence.fetchAdd(1, .monotonic);
        const candidate = print(&temp_buf, "{s}.{d}.{d}.tmp", .{ path, pid, seq }, 0) catch
            return error.NameTooLong;
        const result = linux.open(candidate, flags, 0o600);
        if (linux.errno(result) == .EXIST) {
            last_result = result;
            continue;
        }
        fd = @intCast(try check(result));
        temp_path = candidate;
        break;
    }
    if (fd < 0) {
        _ = try check(last_result);
        unreachable;
    }
    defer close(fd);
    var committed = false;
    errdefer if (!committed) {
        _ = linux.unlink(temp_path);
    };
    try writeAll(fd, data);
    _ = try check(linux.fsync(fd));
    if (publishClone(path, fd)) {
        // `path` is a clone: the inode mapped below has no name left, and
        // nobody can truncate it under the mapping (`cp` or `rsync
        // --inplace` over `path` made every later read of a page past the
        // new end a SIGBUS).
        _ = linux.unlink(temp_path);
    } else {
        // No reflinks here (ext4, tmpfs): `path` is the mapped inode itself.
        try rename(temp_path, final_path);
        fsyncParentDir(path);
    }
    committed = true;
    const mapping_address = try check(linux.mmap(
        null,
        data.len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ));
    const mapping: [*]align(mapping_alignment_bytes) u8 = @ptrFromInt(mapping_address);
    return mapping[0..data.len];
}

/// FICLONE (`_IOW(0x94, 9, int)`): the destination shares the source's
/// extents, nothing is copied.
const ficlone_request: u32 = 0x40049409;

/// Replaces `path` atomically with a reflink clone of the file open as
/// `source_fd` (btrfs, XFS, bcachefs: shared extents, no data copied).
/// False when the file system cannot clone, nothing left behind.
fn publishClone(path: []const u8, source_fd: i32) bool {
    var clone = AtomicFile.create(path) catch return false;
    const result = linux.ioctl(clone.fd, ficlone_request, @intCast(source_fd));
    if (linux.errno(result) != .SUCCESS) {
        clone.abort();
        return false;
    }
    clone.commit() catch return false;
    return true;
}

/// Best-effort directory sync after `rename` so the new directory entry
/// persists across power loss on filesystems without implicit ordering.
fn fsyncParentDir(path: []const u8) void {
    const dir_slice = std.Io.Dir.path.dirname(path) orelse ".";
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_z = std.mem.printSentinel(&dir_buf, "{s}", .{dir_slice}, 0) catch return;
    const dir_fd = os.openDir(dir_z) catch return;
    defer close(dir_fd);
    _ = linux.fsync(dir_fd);
}

/// Per-process sequence for unique temporary file names in `AtomicFile`.
var temp_sequence: std.atomic.Value(u64) = .init(0);

/// `writeFileAtomic` a piece at a time: a unique `<path>.<pid>.<seq>.tmp`,
/// written in order, a header patched in at the end, fsync and rename on
/// `commit`; `abort` (or a failed commit) leaves `path` as it was.
pub const AtomicFile = struct {
    fd: i32,
    temporary_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    final_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    temporary_path_len: usize = 0,
    final_path_len: usize = 0,

    const create_attempts_max = 64;

    pub fn create(path: []const u8) Error!AtomicFile {
        var file: AtomicFile = .{ .fd = -1 };
        const print = std.mem.printSentinel;
        const final_path = print(&file.final_path, "{s}", .{path}, 0) catch {
            return error.NameTooLong;
        };
        assert(final_path.len > 0);
        file.final_path_len = final_path.len;

        const pid = linux.getpid();
        const flags: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        };
        var last_result: usize = 0;
        for (0..create_attempts_max) |_| {
            const seq = temp_sequence.fetchAdd(1, .monotonic);
            const temporary_path = print(
                &file.temporary_path,
                "{s}.{d}.{d}.tmp",
                .{ path, pid, seq },
                0,
            ) catch return error.NameTooLong;
            assert(temporary_path.len > final_path.len);
            const result = linux.open(temporary_path, flags, 0o600);
            if (linux.errno(result) == .EXIST) {
                last_result = result;
                continue;
            }
            file.temporary_path_len = temporary_path.len;
            file.fd = @intCast(try check(result));
            return file;
        }
        _ = try check(last_result);
        unreachable;
    }

    pub fn write(file: *AtomicFile, data: []const u8) Error!void {
        assert(file.fd >= 0);
        try writeAll(file.fd, data);
    }

    pub fn writeAt(file: *AtomicFile, data: []const u8, offset: usize) Error!void {
        assert(file.fd >= 0);
        try writeAllAt(file.fd, data, offset);
    }

    pub fn commit(file: *AtomicFile) Error!void {
        assert(file.fd >= 0);
        errdefer file.abort();
        _ = try check(linux.fsync(file.fd));
        close(file.fd);
        file.fd = -1;
        try rename(
            file.temporary_path[0..file.temporary_path_len :0],
            file.final_path[0..file.final_path_len :0],
        );
        fsyncParentDir(file.final_path[0..file.final_path_len]);
    }

    /// Safe to call after a failed `commit` (it already aborted).
    pub fn abort(file: *AtomicFile) void {
        if (file.fd >= 0) close(file.fd);
        file.fd = -1;
        // There may be no temporary left to remove: nothing to report.
        _ = linux.unlink(file.temporary_path[0..file.temporary_path_len :0]);
    }
};

/// Grows a file in place: what is written goes past its current end, then
/// `writeAt` patches the start (a header pointing at it) and `sync` makes it
/// durable. Nothing written before is touched but what `writeAt` patches,
/// so mappings of it stay valid for everything else. Locked (flock) while
/// it is open.
/// flock(2)'s LOCK_EX.
const lock_exclusive = 2;

/// Device + inode identity of an opened regular file.
pub const FileId = struct {
    dev: u64,
    ino: u64,

    pub fn eql(a: FileId, b: FileId) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

/// Returns the `(dev, ino)` identity of `fd` after verifying it is a regular file.
pub fn fdIdentity(fd: i32) Error!FileId {
    var stx: linux.Statx = undefined;
    const stx_result = linux.statx(
        fd,
        "",
        linux.AT.EMPTY_PATH,
        .{ .TYPE = true, .INO = true },
        &stx,
    );
    if (linux.errno(stx_result) != .SUCCESS or stx.mode & linux.S.IFMT != linux.S.IFREG) {
        return error.NotRegular;
    }
    return .{
        .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
        .ino = stx.ino,
    };
}

/// Advisory exclusive flock on `<target_path>.lock` used to serialize both
/// whole-file atomic rewrites and in-place appends across processes.
pub const LockFile = struct {
    fd: i32,

    pub fn acquire(target_path: []const u8) Error!LockFile {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const lock_path = std.mem.printSentinel(&buf, "{s}.lock", .{target_path}, 0) catch
            return error.NameTooLong;
        const open_result = linux.open(
            lock_path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .NOFOLLOW = true,
                .CLOEXEC = true,
                .NOCTTY = true,
            },
            0o600,
        );
        switch (linux.errno(open_result)) {
            .LOOP, .ISDIR => return error.NotRegular,
            else => {},
        }
        const fd: i32 = @intCast(try check(open_result));
        errdefer close(fd);
        _ = try fdIdentity(fd);
        while (true) {
            const lock_result = linux.flock(fd, lock_exclusive);
            if (linux.errno(lock_result) != .INTR) {
                _ = try check(lock_result);
                break;
            }
        }
        return .{ .fd = fd };
    }

    pub fn release(lock: *LockFile) void {
        close(lock.fd);
        lock.fd = -1;
    }
};

/// Deletes the `<path>.<pid>.<seq>.tmp` that `AtomicFile`s of processes
/// gone since left next to `path`: a SIGKILL, a crash or a power cut in the
/// middle of a write leaves one (a content index's is ~80 MB), and nothing
/// else ever deletes it, the next run writing under another pid. With
/// `path`'s `LockFile` held, so that no writer that takes it is in the
/// middle of one; a temporary whose pid still runs (this process, or one
/// that reuses the number) is left alone. Best effort.
pub fn removeAbandonedTemporaries(path: []const u8) void {
    var lock = LockFile.acquire(path) catch return;
    defer lock.release();
    const directory = std.Io.Dir.path.dirname(path) orelse ".";
    const base = std.Io.Dir.path.basename(path);
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_z = std.mem.printSentinel(&directory_buffer, "{s}", .{directory}, 0) catch
        return;
    const fd = os.openDir(directory_z) catch return;
    defer close(fd);
    var iterator: os.DirIter = .{ .fd = fd };
    while (iterator.next() catch return) |entry| {
        const pid = temporaryOwner(entry.name, base) orelse continue;
        if (processRuns(pid)) continue;
        var name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const name = std.mem.printSentinel(&name_buffer, "{s}", .{entry.name}, 0) catch continue;
        _ = linux.unlinkat(fd, name, 0);
    }
}

/// The pid in `name` when it is an `AtomicFile` temporary of `base`
/// (`<base>.<pid>.<seq>.tmp`).
fn temporaryOwner(name: []const u8, base: []const u8) ?linux.pid_t {
    if (!std.mem.startsWith(u8, name, base)) return null;
    const rest = name[base.len..];
    if (rest.len == 0 or rest[0] != '.') return null;
    if (!std.mem.endsWith(u8, rest, ".tmp")) return null;
    const numbers = rest[1 .. rest.len - ".tmp".len];
    const dot = std.mem.findScalar(u8, numbers, '.') orelse return null;
    const pid = std.fmt.parseInt(linux.pid_t, numbers[0..dot], 10) catch return null;
    _ = std.fmt.parseInt(u64, numbers[dot + 1 ..], 10) catch return null;
    if (pid <= 0) return null;
    return pid;
}

/// Whether a process `pid` exists (one of another user's included).
fn processRuns(pid: linux.pid_t) bool {
    if (pid == linux.getpid()) return true;
    // Signal 0: only whether it could be sent.
    return linux.errno(linux.kill(pid, @fromBackingInt(@intCast(0)))) != .SRCH;
}

pub const AppendFile = struct {
    fd: i32,
    /// Where the next `write` goes.
    len: usize,
    id: FileId,

    /// Null when the file is not `expect_len` bytes long or its `(dev, ino)`
    /// differs from `expect_id` (someone else rewrote/replaced it): the caller
    /// rewrites it whole instead.
    pub fn open(path: [*:0]const u8, expect_len: usize, expect_id: ?FileId) Error!?AppendFile {
        const open_result = linux.open(
            path,
            .{
                .ACCMODE = .WRONLY,
                .CLOEXEC = true,
                .NOFOLLOW = true,
                .NONBLOCK = true,
                .NOCTTY = true,
            },
            0,
        );
        // O_WRONLY|O_NONBLOCK on a FIFO with no reader returns ENXIO; O_NOFOLLOW
        // on a symlink returns ELOOP; a directory returns EISDIR.
        switch (linux.errno(open_result)) {
            .NXIO, .LOOP, .ISDIR => return error.NotRegular,
            else => {},
        }
        const fd: i32 = @intCast(try check(open_result));
        errdefer close(fd);
        _ = try fdIdentity(fd);
        // Held until `deinit`: a second process appending at once (the
        // daemon and lumen-find on one cache) wrote at the same offset, and
        // the header written last pointed at the other one's bytes. It waits
        // here, then checks `(dev, ino)` and length after locking.
        while (true) {
            const lock_result = linux.flock(fd, lock_exclusive);
            if (linux.errno(lock_result) != .INTR) {
                _ = try check(lock_result);
                break;
            }
        }
        const id = try fdIdentity(fd);
        if (expect_id) |want| {
            if (!id.eql(want)) {
                close(fd);
                return null;
            }
        }
        const size = try check(linux.lseek(fd, 0, linux.SEEK.END));
        if (size != expect_len) {
            close(fd);
            return null;
        }
        return .{ .fd = fd, .len = size, .id = id };
    }

    pub fn write(file: *AppendFile, data: []const u8) Error!void {
        try file.writeAt(data, file.len);
        file.len += data.len;
    }

    pub fn writeAt(file: *AppendFile, data: []const u8, offset: usize) Error!void {
        try writeAllAt(file.fd, data, offset);
    }

    pub fn sync(file: *AppendFile) Error!void {
        _ = try check(linux.fsync(file.fd));
    }

    pub fn deinit(file: *AppendFile) void {
        close(file.fd);
    }
};

/// The alignment `mapPrivate` promises. A mapping starts on a page, far
/// beyond this; 8 is what readers of typed columns (u64, i64) need.
pub const mapping_alignment_bytes = 8;
/// The bytes of a mapping made by `mapPrivate`.
pub const MappedBytes = []align(mapping_alignment_bytes) u8;

/// Unmaps what `mapPrivate` mapped. munmap fails only on a range that is
/// not a mapping, and `MappedBytes` always is one.
pub fn unmap(mapping: MappedBytes) void {
    _ = linux.munmap(mapping.ptr, mapping.len);
}

/// Private, writable (copy-on-write) mapping of a whole file.
pub fn mapPrivate(path: [*:0]const u8) Error!MappedBytes {
    return (try mapPrivateWithId(path)).bytes;
}

/// Like `mapPrivate`, also returning the opened file's `(dev, ino)` identity.
pub fn mapPrivateWithId(path: [*:0]const u8) Error!struct { bytes: MappedBytes, id: FileId } {
    const fd = try openRegular(path);
    defer close(fd);
    const id = try fdIdentity(fd);
    const size = try check(linux.lseek(fd, 0, linux.SEEK.END));
    if (size == 0) return error.NotFound;
    const mapping_address = try check(linux.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ));
    const mapping: [*]align(mapping_alignment_bytes) u8 = @ptrFromInt(mapping_address);
    return .{ .bytes = mapping[0..size], .id = id };
}

const expectSuccess = @import("test_dir.zig").expectSuccess;

test "special files are refused without blocking" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var fifo_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fifo = try std.mem.printSentinel(&fifo_buffer, "{s}/pipe", .{dir}, 0);
    try expectSuccess(linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0));
    var head_buffer: [64]u8 = undefined;
    // Each of these used to block forever on a FIFO with no writer.
    try std.testing.expectEqualStrings("", readHead(fifo, &head_buffer));
    try std.testing.expectError(error.NotRegular, mapPrivate(fifo));
    try std.testing.expectError(error.NotRegular, AppendFile.open(fifo, 0, null));
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buffer, "{s}/link", .{dir}, 0);
    try expectSuccess(linux.symlink(fifo, link));
    try std.testing.expectError(error.NotRegular, AppendFile.open(link, 0, null));
    try std.testing.expect(!os.isRegular(fifo));
    try std.testing.expectEqualStrings("", readHead("/dev/null", &head_buffer));
    try std.testing.expect(os.isRegular("/proc/self/status"));
}

test "a mapped atomic write survives the file being truncated where it can clone" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/files.idx", .{dir}, 0);
    // Several pages, so a truncated file would leave most of them past its end.
    const data = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');
    const mapping = try writeFileAtomicMapped(path, data);
    defer unmap(mapping);
    // Only a clone protects the mapping: without one, `path` is the mapped
    // inode and truncating it is the SIGBUS this guards against.
    var probe_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const probe = try std.mem.printSentinel(&probe_buffer, "{s}/probe", .{dir}, 0);
    try writeFileAtomic(probe, "probe");
    const probe_fd = try openRegular(probe);
    defer close(probe_fd);
    var clone_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const clone = try std.mem.print(&clone_buffer, "{s}/clone", .{dir});
    if (!publishClone(clone, probe_fd)) return error.SkipZigTest;
    // `cp` over it: O_TRUNC, then a few bytes.
    const truncated = linux.open(path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, 0);
    try expectSuccess(truncated);
    try writeAll(@intCast(truncated), "new");
    close(@intCast(truncated));
    var sum: usize = 0;
    for (mapping) |byte| sum += byte;
    try std.testing.expectEqual(@as(usize, 'x') * data.len, sum);
}

test "atomic writes replace the file and leave no temporary behind" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/f.conf", .{dir});
    try writeFileAtomic(path, "old");
    try writeFileAtomic(path, "new");
    var head_buffer: [16]u8 = undefined;
    var path_z_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("new", readHead(
        try std.mem.printSentinel(&path_z_buffer, "{s}", .{path}, 0),
        &head_buffer,
    ));
    var dir_z_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_fd = try os.openDir(try std.mem.printSentinel(&dir_z_buffer, "{s}", .{dir}, 0));
    defer close(dir_fd);
    var iter: os.DirIter = .{ .fd = dir_fd };
    var count: usize = 0;
    while (try iter.next()) |entry| {
        try std.testing.expectEqualStrings("f.conf", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    // A directory that is not there: an error, and nothing left over.
    const bad = try std.mem.print(&path_buffer, "{s}/missing/f.conf", .{dir});
    try std.testing.expectError(error.NotFound, writeFileAtomic(bad, "x"));
}

test "removeAbandonedTemporaries: only the temporaries of processes gone" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    // Above any pid a 64-bit kernel hands out (pid_max is at most 2^22).
    const gone: linux.pid_t = 1 << 22;
    try std.testing.expect(!processRuns(gone));
    const own = linux.getpid();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/content.idx", .{dir});
    // `<head><pid><tail>`.
    const Planted = struct { head: []const u8, pid: linux.pid_t, tail: []const u8, deleted: bool };
    const planted = [_]Planted{
        .{ .head = "content.idx.", .pid = gone, .tail = ".7.tmp", .deleted = true },
        .{ .head = "content.idx.", .pid = own, .tail = ".8.tmp", .deleted = false },
        .{ .head = "content.idx.", .pid = gone, .tail = ".tmp", .deleted = false },
        .{ .head = "content.idx.", .pid = gone, .tail = ".x.tmp", .deleted = false },
        .{ .head = "contentXidx.", .pid = gone, .tail = ".1.tmp", .deleted = false },
        .{ .head = "files.idx.", .pid = gone, .tail = ".1.tmp", .deleted = false },
        .{ .head = "content.idx.", .pid = gone, .tail = ".1.tmpx", .deleted = false },
    };
    var names: [planted.len][std.Io.Dir.max_path_bytes]u8 = undefined;
    var name_lengths: [planted.len]usize = undefined;
    for (planted, 0..) |plant, index| {
        const name = try std.mem.printSentinel(
            &names[index],
            "{s}/{s}{d}{s}",
            .{ dir, plant.head, plant.pid, plant.tail },
            0,
        );
        name_lengths[index] = name.len;
        try writeFile(name, "x");
    }

    var index_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const index_path = try std.mem.printSentinel(&index_buffer, "{s}", .{path}, 0);
    try writeFile(index_path, "index");
    removeAbandonedTemporaries(path);
    for (planted, 0..) |plant, index| {
        const name = names[index][0..name_lengths[index] :0];
        try std.testing.expectEqual(!plant.deleted, os.exists(name));
    }
    try std.testing.expect(os.exists(index_path));
}

test "atomic writes use unique temporaries and never clobber concurrent writers or links" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/f.idx", .{dir});
    var victim_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const victim = try std.mem.printSentinel(&victim_buffer, "{s}/victim", .{dir}, 0);
    var head_buffer: [16]u8 = undefined;
    var path_z_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = try std.mem.printSentinel(&path_z_buffer, "{s}", .{path}, 0);

    // Plant a symlink at the very next temporary name: create skips it without
    // touching the symlink or its target.
    try writeFile(victim, "keep");
    var planted_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const next_seq = temp_sequence.load(.monotonic);
    const planted = try std.mem.printSentinel(
        &planted_buffer,
        "{s}.{d}.{d}.tmp",
        .{ path, linux.getpid(), next_seq },
        0,
    );
    try expectSuccess(linux.symlink(victim, planted));
    try writeFileAtomic(path, "new");
    try std.testing.expectEqualStrings("keep", readHead(victim, &head_buffer));
    try std.testing.expectEqualStrings("new", readHead(path_z, &head_buffer));
    // Two concurrent AtomicFiles targeting the same path get distinct temp files.
    var first = try AtomicFile.create(path);
    errdefer first.abort();
    var second = try AtomicFile.create(path);
    errdefer second.abort();
    try first.write("first");
    try second.write("second");
    try first.commit();
    try second.commit();
    try std.testing.expectEqualStrings("second", readHead(path_z, &head_buffer));
}

test "writeFile enforces 0600 on existing files and refuses symlinks" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.printSentinel(&path_buffer, "{s}/secret", .{dir}, 0);
    try writeFile(file, "old");
    try expectSuccess(linux.chmod(file, 0o644));
    try writeFile(file, "new");
    var stx: linux.Statx = undefined;
    try expectSuccess(linux.statx(linux.AT.FDCWD, file, 0, .{ .MODE = true }, &stx));
    try std.testing.expectEqual(@as(u16, 0o600), stx.mode & 0o777);

    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buffer, "{s}/link", .{dir}, 0);
    try expectSuccess(linux.symlink(file, link));
    try std.testing.expectError(error.IsLink, writeFile(link, "evil"));
    var head_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new", readHead(file, &head_buffer));
}

test "readUpTo tells a failed read from the end of the file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.printSentinel(&file_buffer, "{s}/text", .{dir}, 0);
    try writeFile(file, "hello");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    const file_fd = try openRegular(file);
    defer close(file_fd);
    try readUpTo(std.testing.allocator, file_fd, &text, 1024);
    try std.testing.expectEqualStrings("hello", text.items);
    // A folder opens, but reading it fails (EISDIR): not an empty file.
    var dir_z_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_fd = try os.openDir(try std.mem.printSentinel(&dir_z_buffer, "{s}", .{dir}, 0));
    defer close(dir_fd);
    text.clearRetainingCapacity();
    try std.testing.expectError(
        error.ReadFailed,
        readUpTo(std.testing.allocator, dir_fd, &text, 1024),
    );
}

test "readUpTo never reads past bytes_max" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var file_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.printSentinel(&file_buffer, "{s}/big", .{dir}, 0);
    const data = try std.testing.allocator.alloc(u8, read_chunk_bytes * 3);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');
    try writeFile(file, data);
    const file_fd = try openRegular(file);
    defer close(file_fd);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    // Not a multiple of the chunk: the last read must be cut to what is left.
    const bytes_max = read_chunk_bytes + 100;
    try readUpTo(std.testing.allocator, file_fd, &text, bytes_max);
    try std.testing.expectEqual(bytes_max, text.items.len);
}

test "writeAll waits on a non-blocking descriptor instead of failing" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(
        .SUCCESS,
        linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })),
    );
    defer close(fds[0]);
    const Reader = struct {
        fn drain(fd: i32, total: *usize) void {
            var buffer: [4096]u8 = undefined;
            while (true) {
                const result = linux.read(fd, &buffer, buffer.len);
                switch (linux.errno(result)) {
                    .SUCCESS => {
                        if (result == 0) return;
                        total.* += result;
                    },
                    .AGAIN, .INTR => os.sleepUs(1000),
                    else => return,
                }
            }
        }
    };
    var total: usize = 0;
    const thread = try std.Thread.spawn(.{}, Reader.drain, .{ fds[0], &total });
    // More than a pipe holds: EAGAIN until the reader makes room.
    const data = try std.testing.allocator.alloc(u8, 256 << 10);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');
    try writeAll(fds[1], data);
    close(fds[1]);
    thread.join();
    try std.testing.expectEqual(data.len, total);
}

test "a second append waits for the first, then sees the file grew" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/index", .{dir}, 0);
    try writeFile(path, "0123456789");
    const mapped = try mapPrivateWithId(path);
    defer unmap(mapped.bytes);
    var first = (try AppendFile.open(path, 10, mapped.id)).?;
    const Second = struct {
        fn run(file_path: [:0]const u8, expect_id: FileId, result: *?bool) void {
            const opened = AppendFile.open(file_path, 10, expect_id) catch {
                result.* = null;
                return;
            };
            result.* = opened != null;
            if (opened) |file| {
                var owned = file;
                owned.deinit();
            }
        }
    };
    var second_opened: ?bool = null;
    const thread = try std.Thread.spawn(.{}, Second.run, .{ path, mapped.id, &second_opened });
    // The second one is blocked on the lock meanwhile.
    os.sleepUs(100 * std.time.us_per_ms);
    try first.write("abc");
    first.deinit();
    thread.join();
    // Not 10 bytes any more: it rewrites instead of appending over these.
    try std.testing.expectEqual(@as(?bool, false), second_opened);

    // Replacing atomically with another file of identical length still rejects append via (dev, ino).
    try writeFileAtomic(path, "abcdefghij");
    const mapped2 = try mapPrivateWithId(path);
    defer unmap(mapped2.bytes);
    try std.testing.expect(!mapped.id.eql(mapped2.id));
    try std.testing.expectEqual(@as(?AppendFile, null), try AppendFile.open(path, 10, mapped.id));
}

test "ensurePrivateFile creates, tightens permissions, skips absent, rejects links" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const absent = try std.mem.printSentinel(&path_buffer, "{s}/missing", .{dir}, 0);
    try ensurePrivateFile(absent, false);
    try std.testing.expectError(error.NotFound, openRegular(absent));

    const created = try std.mem.printSentinel(&path_buffer, "{s}/created", .{dir}, 0);
    try ensurePrivateFile(created, true);
    var stx: linux.Statx = undefined;
    try expectSuccess(linux.statx(linux.AT.FDCWD, created, 0, .{ .MODE = true }, &stx));
    try std.testing.expectEqual(@as(u16, 0o600), stx.mode & 0o777);

    try expectSuccess(linux.chmod(created, 0o644));
    try ensurePrivateFile(created, false);
    try expectSuccess(linux.statx(linux.AT.FDCWD, created, 0, .{ .MODE = true }, &stx));
    try std.testing.expectEqual(@as(u16, 0o600), stx.mode & 0o777);

    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buffer, "{s}/link", .{dir}, 0);
    try expectSuccess(linux.symlink(created, link));
    try std.testing.expectError(error.IsLink, ensurePrivateFile(link, false));

    var head_buffer: [16]u8 = undefined;
    try writeFile(created, "abcdef");
    try std.testing.expectEqualStrings("abcdef", readHead(created, &head_buffer));
}
