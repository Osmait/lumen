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

/// The first bytes of a file (previews). Empty for anything not a regular
/// file.
pub fn readHead(path: [*:0]const u8, head_buffer: []u8) []const u8 {
    const fd = openRegular(path) catch return "";
    defer close(fd);
    const bytes_read = linux.read(fd, head_buffer.ptr, head_buffer.len);
    if (linux.errno(bytes_read) != .SUCCESS) return "";
    return head_buffer[0..bytes_read];
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
        if (linux.errno(result) == .INTR) continue;
        written += try check(result);
    }
    assert(written == data.len);
}

pub const ReadUpToError = std.mem.Allocator.Error || error{ReadFailed};

/// Reads `fd` into `text` until its end or `text` holds `bytes_max` (it can
/// hold a little more: a read is not cut short). A read that fails is
/// `error.ReadFailed`, with what was read before it left in `text`: it is
/// not the whole file, so it must not be taken for it.
pub fn readUpTo(
    gpa: std.mem.Allocator,
    fd: i32,
    text: *std.ArrayList(u8),
    bytes_max: usize,
) ReadUpToError!void {
    while (text.items.len < bytes_max) {
        try text.ensureUnusedCapacity(gpa, read_chunk_bytes);
        const spare = text.unusedCapacitySlice();
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
    temporary_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    final_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    temporary_path_len: usize = 0,
    final_path_len: usize = 0,

    pub fn create(path: []const u8) Error!AtomicFile {
        var file: AtomicFile = .{ .fd = -1 };
        const print = std.mem.printSentinel;
        const final_path = print(&file.final_path, "{s}", .{path}, 0) catch {
            return error.NameTooLong;
        };
        const temporary_path = print(&file.temporary_path, "{s}.tmp", .{path}, 0) catch {
            return error.NameTooLong;
        };
        assert(final_path.len > 0);
        assert(temporary_path.len > final_path.len);
        file.final_path_len = final_path.len;
        file.temporary_path_len = temporary_path.len;
        file.fd = try openTemporary(temporary_path);
        return file;
    }

    /// A new file, never one that is there: `O_TRUNC` wrote through a link
    /// planted at `<path>.tmp`. One left by a crash midway is removed first.
    fn openTemporary(temporary_path: [*:0]const u8) Error!i32 {
        const flags: linux.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        };
        var result = linux.open(temporary_path, flags, 0o600);
        if (linux.errno(result) == .EXIST) {
            // Whether the unlink worked, the second open tells.
            _ = linux.unlink(temporary_path);
            result = linux.open(temporary_path, flags, 0o600);
        }
        return @intCast(try check(result));
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
    const fd = try openRegular(path);
    defer close(fd);
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
    return mapping[0..size];
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
    try std.testing.expect(!os.isRegular(fifo));
    try std.testing.expectEqualStrings("", readHead("/dev/null", &head_buffer));
    try std.testing.expect(os.isRegular("/proc/self/status"));
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
    const temporary = try std.mem.printSentinel(&path_z_buffer, "{s}.tmp", .{path}, 0);
    try std.testing.expect(!os.exists(temporary));
    // A directory that is not there: an error, and nothing left over.
    const bad = try std.mem.print(&path_buffer, "{s}/missing/f.conf", .{dir});
    try std.testing.expectError(error.NotFound, writeFileAtomic(bad, "x"));
}

test "atomic writes never write through a temporary left in the way" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try os.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/f.idx", .{dir});
    var temporary_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temporary = try std.mem.printSentinel(&temporary_buffer, "{s}.tmp", .{path}, 0);
    var victim_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const victim = try std.mem.printSentinel(&victim_buffer, "{s}/victim", .{dir}, 0);
    var head_buffer: [16]u8 = undefined;
    var path_z_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = try std.mem.printSentinel(&path_z_buffer, "{s}", .{path}, 0);

    // A link to someone else's file: replaced, the file untouched.
    try writeFile(victim, "keep");
    try expectSuccess(linux.symlink(victim, temporary));
    try writeFileAtomic(path, "new");
    try std.testing.expectEqualStrings("keep", readHead(victim, &head_buffer));
    try std.testing.expectEqualStrings("new", readHead(path_z, &head_buffer));
    try std.testing.expect(!os.exists(temporary));

    // A crash's leftover: removed, the write goes through.
    try writeFile(temporary, "half a file");
    try writeFileAtomic(path, "newer");
    try std.testing.expectEqualStrings("newer", readHead(path_z, &head_buffer));
    try std.testing.expect(!os.exists(temporary));
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
