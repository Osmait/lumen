//! Temporary folders for tests, with their absolute or build-root-relative
//! paths, and a check for the raw syscalls a test sets itself up with.

const std = @import("std");
const linux = std.os.linux;
const os = @import("root.zig");

/// A testing tmp dir with its absolute path (tests run from the build
/// root; what they test often takes absolute paths), and files in it.
pub const TestDir = struct {
    folder: std.testing.TmpDir,
    absolute: []u8,

    pub fn init() !TestDir {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        var relative_buffer: [256]u8 = undefined;
        const relative = try tmpDirPath(&tmp_dir, &relative_buffer);
        const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
        defer std.testing.allocator.free(cwd);
        const absolute = try std.testing.allocator.print("{s}/{s}", .{ cwd, relative });
        return .{ .folder = tmp_dir, .absolute = absolute };
    }

    pub fn deinit(test_dir: *TestDir) void {
        std.testing.allocator.free(test_dir.absolute);
        test_dir.folder.cleanup();
    }

    /// Absolute path of `name`, in the caller's `path_buffer`.
    pub fn path(test_dir: *const TestDir, path_buffer: []u8, name: []const u8) ![:0]u8 {
        return std.mem.printSentinel(path_buffer, "{s}/{s}", .{ test_dir.absolute, name }, 0);
    }

    /// Writes `name` (creating parent dirs) with `data`.
    pub fn write(test_dir: *const TestDir, name: []const u8, data: []const u8) !void {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const file_path = try test_dir.path(&path_buffer, name);
        if (std.mem.findScalarLast(u8, file_path, '/')) |slash| try os.mkdirP(file_path[0..slash]);
        try os.writeFile(file_path, data);
    }

    pub fn mkdir(test_dir: *const TestDir, name: []const u8) !void {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try os.mkdirP(try test_dir.path(&path_buffer, name));
    }
};

/// Absolute path of a testing tmp dir, in `path_buffer`.
pub fn tmpDirAbs(tmp_dir: *std.testing.TmpDir, path_buffer: []u8) ![]const u8 {
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = std.mem.sliceTo(cwd_buffer[0..linux.getcwd(&cwd_buffer, cwd_buffer.len)], 0);
    var relative_buffer: [256]u8 = undefined;
    const relative = try tmpDirPath(tmp_dir, &relative_buffer);
    return std.mem.print(path_buffer, "{s}/{s}", .{ cwd, relative });
}

/// Path of a testing tmp dir relative to the build root (where tests run),
/// in `path_buffer`.
pub fn tmpDirPath(
    tmp_dir: *std.testing.TmpDir,
    path_buffer: []u8,
) std.mem.PrintError![]const u8 {
    return std.mem.print(path_buffer, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
}

/// Fails the test when a setup call (a link, a FIFO, a chmod) fails: the
/// test would go on to check something that was never there.
pub fn expectSuccess(result: usize) !void {
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
}
