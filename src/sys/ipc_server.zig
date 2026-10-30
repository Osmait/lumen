//! The daemon's end of the socket `lumen` talks to (src/ipc.zig): a Unix
//! socket in $XDG_RUNTIME_DIR/lumen, owner-only, watched by the GTK main
//! loop. Each connection is one request, read whole (the client shuts its
//! side when done), answered, closed.
//!
//! Nothing here waits on a client: a connection is read as its bytes arrive
//! and answered as fast as the client takes it, each within a deadline, so
//! a slow or stuck client costs a buffer, never the window.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const ipc = @import("../ipc.zig");
const os = @import("os");
const failed = os.unix.failed;

const log = std.log.scoped(.ipc);

/// Runs a request: `args` without the program name, `payload` what came
/// after them. Writes what goes to stdout and stderr; returns the status.
pub const Handler = *const fn (
    args: []const [:0]const u8,
    payload: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) u8;

var listen_fd: linux.fd_t = -1;
/// The socket's watch; while accepting is paused, the timer that resumes it
/// (or 0 until a connection ends).
var listen_source: c_uint = 0;
var path_buf: [256]u8 = undefined;
var path: [:0]const u8 = "";
var handler: Handler = undefined;
var gpa: std.mem.Allocator = undefined;
var conns_open: usize = 0;

pub const ListenError = error{
    /// $XDG_RUNTIME_DIR is not set.
    NoRuntimeDir,
    /// The socket's folder or path does not fit (a sockaddr_un holds 108
    /// bytes).
    PathTooLong,
    /// The socket's folder is a link, someone else's, or open to others.
    FolderNotPrivate,
    Socket,
    Bind,
    Listen,
};

/// Listens on $XDG_RUNTIME_DIR/lumen/<app_id>.sock. Without the socket
/// `lumen` still works, through lumen-gtk, only slower: a failure is
/// logged here, and the daemon runs on.
pub fn start(allocator: std.mem.Allocator, app_id: []const u8, h: Handler) void {
    const runtime_dir = if (c.g_getenv("XDG_RUNTIME_DIR")) |dir| std.mem.span(dir) else "";
    listenIn(allocator, runtime_dir, app_id, h) catch |err| {
        log.warn("no socket ({t}): `lumen` goes through lumen-gtk, slower", .{err});
    };
}

fn listenIn(
    allocator: std.mem.Allocator,
    runtime_dir: []const u8,
    app_id: []const u8,
    h: Handler,
) ListenError!void {
    if (runtime_dir.len == 0) return error.NoRuntimeDir;
    var dir_buf: [256]u8 = undefined;
    const dir = ipc.dir(&dir_buf, runtime_dir) orelse return error.PathTooLong;
    os.mkdirP(dir);
    if (!isPrivateDir(dir)) {
        log.warn("{s} is not a folder of ours alone", .{dir});
        return error.FolderNotPrivate;
    }
    const socket_path = ipc.socketPath(&path_buf, runtime_dir, app_id) orelse {
        return error.PathTooLong;
    };
    const rc = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (failed(rc)) |errno| {
        log.warn("socket: {t}", .{errno});
        return error.Socket;
    }
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    // A socket left by a daemon that crashed; only the primary instance
    // gets here, so it is not a live one.
    _ = linux.unlink(socket_path.ptr);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    if (failed(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)))) |errno| {
        log.warn("bind {s}: {t}", .{ socket_path, errno });
        return error.Bind;
    }
    if (failed(linux.listen(fd, 16))) |errno| {
        log.warn("listen {s}: {t}", .{ socket_path, errno });
        return error.Listen;
    }
    _ = linux.chmod(socket_path.ptr, 0o600);
    path = socket_path;
    listen_fd = fd;
    handler = h;
    gpa = allocator;
    watchSocket();
}

pub fn stop() void {
    if (listen_fd < 0) return;
    if (listen_source != 0) _ = c.g_source_remove(listen_source);
    listen_source = 0;
    _ = linux.close(listen_fd);
    listen_fd = -1;
    _ = linux.unlink(path.ptr);
}

/// Whether `dir` is a real folder (not a link to one), ours, and owner-only;
/// one that is ours but open to others is made owner-only. In a runtime
/// folder others can write to, someone else's would let them replace the
/// socket with theirs.
fn isPrivateDir(dir: [:0]const u8) bool {
    const rc = linux.open(
        dir.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true },
        0,
    );
    if (failed(rc) != null) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var stx: linux.Statx = undefined;
    if (failed(linux.statx(
        fd,
        "",
        linux.AT.EMPTY_PATH,
        .{ .TYPE = true, .MODE = true, .UID = true },
        &stx,
    )) != null) return false;
    if (stx.uid != linux.getuid() or stx.mode & linux.S.IFMT != linux.S.IFDIR) return false;
    return stx.mode & 0o777 == 0o700 or failed(linux.fchmod(fd, 0o700)) == null;
}

/// Connections taken per turn of the main loop: the rest wait for the
/// next, so a flood of them cannot hold the window.
const accepts_max = 16;
/// Connections open at once; past it the socket is left alone until one
/// ends (each may hold a request up to ipc.max_request_bytes).
const conns_max = 16;
/// How long a client has to send its request, and again to take the answer.
const client_ms = 10_000;
/// Out of descriptors: how long to wait before accepting again.
const backoff_ms = 500;

fn watchSocket() void {
    listen_source = c.g_unix_fd_add(listen_fd, c.G_IO_IN, &onReady, null);
}

fn onReady(fd: c_int, _: c_uint, _: ?*anyopaque) callconv(.c) c.gboolean {
    for (0..accepts_max) |_| {
        if (conns_open == conns_max) return pause(0);
        const rc = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
        if (failed(rc)) |e| switch (e) {
            // The connection stays queued and the socket readable: watching
            // it now would wake the main loop again at once, forever.
            .MFILE, .NFILE, .NOBUFS, .NOMEM => {
                log.warn("cannot accept a connection: {t}", .{e});
                return pause(backoff_ms);
            },
            else => break,
        };
        Conn.open(@intCast(rc));
    }
    return 1;
}

/// Stops watching the socket: for `ms`, or until a connection ends (0).
/// Returns what removes the socket's current watch.
fn pause(ms: c_uint) c.gboolean {
    listen_source = if (ms == 0) 0 else c.g_timeout_add(ms, &onResume, null);
    return 0;
}

fn onResume(_: ?*anyopaque) callconv(.c) c.gboolean {
    watchSocket();
    return 0;
}

/// One client: its request as it arrives, then the answer as it leaves.
const Conn = struct {
    fd: linux.fd_t,
    phase: enum { request, answer } = .request,
    /// The request, then the answer.
    buf: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    watch: c_uint = 0,
    timer: c_uint = 0,

    fn open(fd: linux.fd_t) void {
        // Only our own user (the folder is owner-only already).
        if (os.unix.peerUid(fd) != linux.getuid()) {
            _ = linux.close(fd);
            return;
        }
        const self = gpa.create(Conn) catch {
            _ = linux.close(fd);
            return;
        };
        self.* = .{ .fd = fd };
        conns_open += 1;
        self.watch = c.g_unix_fd_add(fd, c.G_IO_IN, &onReadable, self);
        self.timer = c.g_timeout_add(client_ms, &onTimeout, self);
    }

    /// Ends the connection, from anywhere, its own callbacks included (a
    /// source removed while it runs is safe in GLib).
    fn close(self: *Conn) void {
        if (self.watch != 0) _ = c.g_source_remove(self.watch);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        _ = linux.close(self.fd);
        self.buf.deinit(gpa);
        gpa.destroy(self);
        conns_open -= 1;
        // Paused at conns_max: there is room again.
        if (listen_fd >= 0 and listen_source == 0) watchSocket();
    }

    fn onReadable(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Conn = @ptrCast(@alignCast(data));
        switch (self.read()) {
            .more => return 1,
            .failed => self.close(),
            .done => self.answer(),
        }
        return 0;
    }

    fn onWritable(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Conn = @ptrCast(@alignCast(data));
        self.flush();
        return 1;
    }

    fn onTimeout(data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Conn = @ptrCast(@alignCast(data));
        log.warn("dropped a client too slow to {s}", .{switch (self.phase) {
            .request => "send its request",
            .answer => "take the answer",
        }});
        self.close();
        return 0;
    }

    /// Reads what the client has sent so far; done at the end of its input
    /// or when the buffer is full (the client sends no more than that).
    fn read(self: *Conn) enum { more, done, failed } {
        while (self.buf.items.len < ipc.max_request_bytes) {
            self.buf.ensureUnusedCapacity(gpa, 64 * 1024) catch return .failed;
            const spare = self.buf.unusedCapacitySlice();
            const room = @min(spare.len, ipc.max_request_bytes - self.buf.items.len);
            const n = linux.read(self.fd, spare.ptr, room);
            if (failed(n)) |e| switch (e) {
                .AGAIN => return .more,
                .INTR => continue,
                else => {
                    log.warn("dropped a request: {t}", .{e});
                    return .failed;
                },
            };
            if (n == 0) return .done;
            self.buf.items.len += n;
        }
        return .done;
    }

    /// Runs the request and starts sending the answer.
    fn answer(self: *Conn) void {
        _ = c.g_source_remove(self.watch);
        _ = c.g_source_remove(self.timer);
        self.watch = 0;
        self.timer = 0;
        self.phase = .answer;
        const req = ipc.parse(self.buf.items) orelse return self.close();

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const args = a.alloc([:0]const u8, req.argc) catch return self.close();
        for (req.args[0..req.argc], args) |src, *dst|
            dst.* = a.dupeSentinel(u8, src, 0) catch return self.close();
        var out: std.Io.Writer.Allocating = .init(a);
        var err: std.Io.Writer.Allocating = .init(a);
        const status = handler(args, req.payload, &out.writer, &err.writer);

        // The request is done with: the buffer takes the answer.
        self.buf.clearRetainingCapacity();
        var head: [5]u8 = undefined;
        head[0] = status;
        std.mem.writeInt(u32, head[1..5], @intCast(out.written().len), .little);
        self.buf.appendSlice(gpa, &head) catch return self.close();
        self.buf.appendSlice(gpa, out.written()) catch return self.close();
        self.buf.appendSlice(gpa, err.written()) catch return self.close();
        self.flush();
    }

    /// Sends what the client takes now, and the rest when it can take more;
    /// closes once all is sent.
    fn flush(self: *Conn) void {
        while (self.sent < self.buf.items.len) {
            const n = os.unix.send(self.fd, self.buf.items[self.sent..]);
            if (failed(n)) |e| switch (e) {
                .INTR => continue,
                .AGAIN => {
                    if (self.watch == 0) {
                        self.watch = c.g_unix_fd_add(self.fd, c.G_IO_OUT, &onWritable, self);
                        self.timer = c.g_timeout_add(client_ms, &onTimeout, self);
                    }
                    return;
                },
                // The client has gone (EPIPE): nothing to answer.
                else => return self.close(),
            };
            self.sent += n;
        }
        self.close();
    }
};

const testing = std.testing;

test "the socket's folder must be ours alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const root = try os.tmpDirPath(&tmp, &buf);
    var pbuf: [512]u8 = undefined;

    // Ours but open to others: made owner-only.
    const open_dir = try std.mem.printSentinel(&pbuf, "{s}/open", .{root}, 0);
    try testing.expect(failed(linux.mkdir(open_dir, 0o755)) == null);
    try testing.expect(failed(linux.chmod(open_dir, 0o755)) == null);
    try testing.expect(isPrivateDir(open_dir));
    var stx: linux.Statx = undefined;
    try testing.expect(failed(linux.statx(
        linux.AT.FDCWD,
        open_dir,
        0,
        .{ .MODE = true },
        &stx,
    )) == null);
    try testing.expectEqual(@as(u16, 0o700), stx.mode & 0o777);

    // A link, even to a folder of ours: where it points can change.
    var lbuf: [512]u8 = undefined;
    const link = try std.mem.printSentinel(&lbuf, "{s}/link", .{root}, 0);
    try testing.expect(failed(linux.symlink("open", link)) == null);
    try testing.expect(!isPrivateDir(link));

    const file = try std.mem.printSentinel(&pbuf, "{s}/file", .{root}, 0);
    try os.writeFile(file, "x");
    try testing.expect(!isPrivateDir(file));
    const missing = try std.mem.printSentinel(&pbuf, "{s}/missing", .{root}, 0);
    try testing.expect(!isPrivateDir(missing));
}

/// A client on its own thread: sends a request whole, reads the answer
/// (after `wait_ms`).
const TestClient = struct {
    path: [:0]const u8,
    arg: []const u8 = "--x",
    wait_ms: u64 = 0,
    got: []u8,
    len: usize = 0,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *TestClient) void {
        defer self.done.store(true, .release);
        const fd = os.unix.connect(self.path, .{}) orelse return;
        defer _ = linux.close(fd);
        var req: [64]u8 = undefined;
        const head = ipc.encode(&req, &.{self.arg}).?;
        @memcpy(req[head.len..][0..4], "copy");
        if (!os.unix.sendAll(fd, req[0 .. head.len + 4])) return;
        _ = linux.shutdown(fd, linux.SHUT.WR);
        os.sleepUs(self.wait_ms * std.time.us_per_ms);
        const deadline_ns = os.monotonicNs() + 2 * std.time.ns_per_s;
        self.len = os.unix.readAll(fd, self.got, deadline_ns) catch 0;
    }

    fn start(self: *TestClient) !std.Thread {
        Done.flag = &self.done;
        return std.Thread.spawn(.{}, run, .{self});
    }
};

/// `--big` answers 1 MiB, more than a socket holds; anything else, itself.
fn testHandler(
    args: []const [:0]const u8,
    payload: []const u8,
    out: *std.Io.Writer,
    _: *std.Io.Writer,
) u8 {
    if (std.mem.eql(u8, args[0], "--big")) {
        out.splatByteAll('x', 1 << 20) catch {};
    } else out.print("{s} {s}", .{ args[0], payload }) catch {};
    return 7;
}

const Done = struct {
    var flag: *std.atomic.Value(bool) = undefined;
    fn answered() bool {
        return flag.load(.acquire);
    }
    fn closed() bool {
        return conns_open == 0;
    }
};

/// Runs the main loop until `done` says so, or a second has passed; the
/// longest one turn took.
fn iterateUntil(done: *const fn () bool) u64 {
    const t0 = os.monotonicNs();
    var longest_ns: u64 = 0;
    while (!done() and os.monotonicNs() - t0 < std.time.ns_per_s) {
        const turn_ns = os.monotonicNs();
        const busy = c.g_main_context_iteration(null, 0) != 0;
        longest_ns = @max(longest_ns, os.monotonicNs() - turn_ns);
        if (!busy) os.sleepUs(500);
    }
    return longest_ns;
}

/// Listens in a fresh folder; the socket's path, in `buf`.
fn testListen(tmp: *std.testing.TmpDir, buf: []u8) ![:0]const u8 {
    var rt_buf: [256]u8 = undefined;
    // Relative: a socket's path must fit in 108 bytes.
    const rt = try os.tmpDirPath(tmp, &rt_buf);
    try listenIn(testing.allocator, rt, "t", &testHandler);
    try testing.expect(listen_fd >= 0);
    return ipc.socketPath(buf, rt, "t").?;
}

test "each reason not to listen is an error of its own" {
    try testing.expectError(error.NoRuntimeDir, listenIn(testing.allocator, "", "t", &testHandler));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var runtime_buffer: [256]u8 = undefined;
    const runtime_dir = try os.tmpDirPath(&tmp, &runtime_buffer);
    const app_id_too_long: [120]u8 = @splat('x');
    try testing.expectError(
        error.PathTooLong,
        listenIn(testing.allocator, runtime_dir, &app_id_too_long, &testHandler),
    );

    // The folder is a link: refused, whatever it points at.
    var link_buffer: [512]u8 = undefined;
    const link_runtime = try std.mem.printSentinel(&link_buffer, "{s}/link", .{runtime_dir}, 0);
    var folder_buffer: [512]u8 = undefined;
    const link_folder = try std.mem.printSentinel(&folder_buffer, "{s}/lumen", .{link_runtime}, 0);
    try testing.expect(failed(linux.mkdir(link_runtime, 0o700)) == null);
    try testing.expect(failed(linux.symlink("/tmp", link_folder)) == null);
    try testing.expectError(
        error.FolderNotPrivate,
        listenIn(testing.allocator, link_runtime, "t", &testHandler),
    );
    try testing.expect(listen_fd < 0);
}

test "a client that sends nothing holds neither the main loop nor the others" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [256]u8 = undefined;
    const sock = try testListen(&tmp, &pbuf);
    defer stop();

    const stalled = os.unix.connect(sock, .{}).?;
    var got: [64]u8 = undefined;
    var client: TestClient = .{ .path = sock, .got = &got };
    const t0 = os.monotonicNs();
    const thread = try client.start();
    _ = iterateUntil(&Done.answered);
    thread.join();
    // Served at once: a server waiting on the silent one would not be.
    try testing.expect(os.monotonicNs() - t0 < 300 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 5 + 8), client.len);
    try testing.expectEqual(@as(u8, 7), got[0]);
    try testing.expectEqualStrings("--x copy", got[5..client.len]);
    try testing.expectEqual(@as(usize, 1), conns_open);

    // It hangs up without a request: dropped, nothing left behind.
    _ = linux.close(stalled);
    _ = iterateUntil(&Done.closed);
    try testing.expectEqual(@as(usize, 0), conns_open);
}

test "a large answer goes out as the client takes it, the main loop turning" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [256]u8 = undefined;
    const sock = try testListen(&tmp, &pbuf);
    defer stop();

    const got = try testing.allocator.alloc(u8, 2 << 20);
    defer testing.allocator.free(got);
    var client: TestClient = .{ .path = sock, .arg = "--big", .wait_ms = 200, .got = got };
    const thread = try client.start();
    const longest_ns = iterateUntil(&Done.answered);
    thread.join();
    try testing.expectEqual(@as(usize, 5 + (1 << 20)), client.len);
    // Not one turn spent waiting for the client to read.
    try testing.expect(longest_ns < 100 * std.time.ns_per_ms);
    _ = iterateUntil(&Done.closed);
    try testing.expectEqual(@as(usize, 0), conns_open);
}
