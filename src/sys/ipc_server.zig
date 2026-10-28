//! The daemon's end of the socket `lumen` talks to (src/ipc.zig): a Unix
//! socket in $XDG_RUNTIME_DIR/lumen, owner-only, watched by the GTK main
//! loop. Each connection is one request, read whole (the client writes it
//! at once and shuts its side), answered, closed.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const ipc = @import("../ipc.zig");
const os = @import("os");

const log = std.log.scoped(.ipc);

/// Runs a request: `args` without the program name, `payload` what came
/// after them. Writes what goes to stdout and stderr; returns the status.
pub const Handler = *const fn (
    args: []const [:0]const u8,
    payload: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) u8;

/// struct ucred (SO_PEERCRED).
const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

var listen_fd: linux.fd_t = -1;
var path_buf: [256]u8 = undefined;
var path: [:0]const u8 = "";
var handler: Handler = undefined;
var gpa: std.mem.Allocator = undefined;

pub fn start(allocator: std.mem.Allocator, app_id: []const u8, h: Handler) void {
    const rt = std.mem.span(c.g_getenv("XDG_RUNTIME_DIR") orelse return);
    var dir_buf: [256]u8 = undefined;
    const dir = ipc.dir(&dir_buf, rt) orelse return;
    if (c.g_mkdir_with_parents(dir.ptr, 0o700) != 0) return;
    path = ipc.socketPath(&path_buf, rt, app_id) orelse return;
    const rc = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    // A socket left by a daemon that crashed; only the primary instance
    // gets here, so it is not a live one.
    _ = linux.unlink(path.ptr);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS or
        linux.errno(linux.listen(fd, 16)) != .SUCCESS)
    {
        log.warn("cannot listen on {s}", .{path});
        _ = linux.close(fd);
        path = "";
        return;
    }
    _ = linux.chmod(path.ptr, 0o600);
    listen_fd = fd;
    handler = h;
    gpa = allocator;
    _ = c.g_unix_fd_add(fd, c.G_IO_IN, &onReady, null);
}

pub fn stop() void {
    if (listen_fd < 0) return;
    _ = linux.close(listen_fd);
    listen_fd = -1;
    _ = linux.unlink(path.ptr);
}

/// Connections served per turn of the main loop: the rest wait for the
/// next, so a flood of them cannot hold the window.
const accepts_max = 16;

fn onReady(fd: c_int, _: c_uint, _: ?*anyopaque) callconv(.c) c.gboolean {
    for (0..accepts_max) |_| {
        const rc = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) break;
        const conn: linux.fd_t = @intCast(rc);
        serve(conn);
        _ = linux.close(conn);
    }
    return 1;
}

fn serve(conn: linux.fd_t) void {
    // Only our own user (the folder is owner-only already).
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    if (linux.errno(linux.getsockopt(
        conn,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        @ptrCast(&cred),
        &len,
    )) != .SUCCESS or
        cred.uid != linux.getuid()) return;
    // The client writes everything at once; a stuck one cannot hold the
    // main loop for long. Large enough for a copy; mmap'd (Lumen's malloc
    // threshold), so only what is read is touched, and it goes back to the
    // system after.
    const deadline_ns = os.monotonicNs() + 500 * std.time.ns_per_ms;
    const buf = gpa.alloc(u8, ipc.max_request_bytes) catch return;
    defer gpa.free(buf);
    const got = os.unix.readAll(conn, buf, deadline_ns) catch |err| {
        log.warn("dropped a request: {t}", .{err});
        return;
    };
    const req = ipc.parse(buf[0..got]) orelse return;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = a.alloc([:0]const u8, req.argc) catch return;
    for (req.args[0..req.argc], args) |src, *dst| dst.* = a.dupeSentinel(u8, src, 0) catch return;
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    const status = handler(args, req.payload, &out.writer, &err.writer);
    var head: [5]u8 = undefined;
    head[0] = status;
    std.mem.writeInt(u32, head[1..5], @intCast(out.written().len), .little);
    _ = os.unix.writeAll(conn, &head) and
        os.unix.writeAll(conn, out.written()) and
        os.unix.writeAll(conn, err.written());
}
