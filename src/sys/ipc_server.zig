//! The daemon's end of the socket `lumen` talks to (src/ipc.zig): a Unix
//! socket in $XDG_RUNTIME_DIR/lumen, owner-only, watched by the GTK main
//! loop. Each connection is one request, read whole (the client shuts its
//! side when done), answered, closed.
//!
//! Nothing here waits on a client: a connection is read as its bytes arrive
//! and answered as fast as the client takes it, each within a deadline, so
//! a slow or stuck client costs a buffer, never the window.

const std = @import("std");
const assert = std.debug.assert;
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

/// The listening socket and its connections. One per daemon, reached from
/// GLib callbacks; main thread only.
const Server = struct {
    listen_fd: linux.fd_t = -1,
    accepting: Accepting = .paused,
    path_buffer: [256]u8 = undefined,
    path: [:0]const u8 = "",
    handler: Handler = undefined,
    gpa: std.mem.Allocator = undefined,
    connections_open: usize = 0,

    /// What brings the listening socket's watch back.
    const Accepting = union(enum) {
        /// Not watched: before listening starts, after it stops, or at
        /// `connections_max` until a connection ends (`Connection.close`).
        paused,
        /// Watched for connections: the GLib source.
        watching: c_uint,
        /// Out of descriptors: the GLib timer that watches it again.
        backing_off: c_uint,
    };

    fn listening(listener: *const Server) bool {
        return listener.listen_fd >= 0;
    }
};

/// The daemon listens on one socket, so there is one server. GLib's watch
/// callbacks reach it here; main thread only.
var server: Server = .{};

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
pub fn start(allocator: std.mem.Allocator, app_id: []const u8, handler: Handler) void {
    const runtime_dir_z = c.g_getenv(ipc.env.runtime_dir);
    const runtime_dir = if (runtime_dir_z) |value| std.mem.span(value) else "";
    listenIn(allocator, runtime_dir, app_id, handler) catch |err| {
        log.warn("no socket ({t}): `lumen` goes through lumen-gtk, slower", .{err});
    };
}

fn listenIn(
    allocator: std.mem.Allocator,
    runtime_dir: []const u8,
    app_id: []const u8,
    handler: Handler,
) ListenError!void {
    assert(!server.listening());
    if (runtime_dir.len == 0) return error.NoRuntimeDir;
    var dir_buffer: [256]u8 = undefined;
    const dir = ipc.folderPath(&dir_buffer, runtime_dir) orelse return error.PathTooLong;
    // A folder that could not be made fails the check below.
    os.mkdirP(dir) catch |err| log.warn("{s}: {t}", .{ dir, err });
    if (!isPrivateDir(dir)) {
        log.warn("{s} is not a folder of ours alone", .{dir});
        return error.FolderNotPrivate;
    }
    const socket_path = ipc.socketPath(&server.path_buffer, runtime_dir, app_id) orelse {
        return error.PathTooLong;
    };
    const socket_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    if (failed(socket_result)) |errno| {
        log.warn("socket: {t}", .{errno});
        return error.Socket;
    }
    const fd: linux.fd_t = @intCast(socket_result);
    errdefer _ = linux.close(fd);
    // A socket left by a daemon that crashed; only the primary instance
    // gets here, so it is not a live one. Usually there is none; one that
    // cannot be removed makes the bind below fail, and that is logged.
    _ = linux.unlink(socket_path.ptr);
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(address.path[0..socket_path.len], socket_path);
    if (failed(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un)))) |errno| {
        log.warn("bind {s}: {t}", .{ socket_path, errno });
        return error.Bind;
    }
    if (failed(linux.listen(fd, connections_max))) |errno| {
        log.warn("listen {s}: {t}", .{ socket_path, errno });
        return error.Listen;
    }
    // The folder is owner-only already: a chmod that fails leaves the
    // socket no more open than that, so it is only logged.
    if (failed(linux.chmod(socket_path.ptr, 0o600))) |errno| {
        log.warn("could not make {s} owner-only: {t}", .{ socket_path, errno });
    }
    server.path = socket_path;
    server.listen_fd = fd;
    server.handler = handler;
    server.gpa = allocator;
    watchSocket();
}

/// Closes the socket and removes its file; the connections still open end
/// on their own. Safe to call when not listening.
pub fn stop() void {
    if (!server.listening()) return;
    switch (server.accepting) {
        .paused => {},
        .watching, .backing_off => |source| _ = c.g_source_remove(source),
    }
    server.accepting = .paused;
    _ = linux.close(server.listen_fd);
    server.listen_fd = -1;
    _ = linux.unlink(server.path.ptr);
}

/// Whether `dir` is a real folder (not a link to one), ours, and owner-only;
/// one that is ours but open to others is made owner-only. In a runtime
/// folder others can write to, someone else's would let them replace the
/// socket with theirs.
fn isPrivateDir(dir: [:0]const u8) bool {
    const open_result = linux.open(
        dir.ptr,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true },
        0,
    );
    if (failed(open_result) != null) return false;
    const fd: linux.fd_t = @intCast(open_result);
    defer _ = linux.close(fd);
    var stx: linux.Statx = undefined;
    const statx_result = linux.statx(
        fd,
        "",
        linux.AT.EMPTY_PATH,
        .{ .TYPE = true, .MODE = true, .UID = true },
        &stx,
    );
    if (failed(statx_result) != null) return false;
    if (stx.uid != linux.getuid() or stx.mode & linux.S.IFMT != linux.S.IFDIR) return false;
    return stx.mode & 0o777 == 0o700 or failed(linux.fchmod(fd, 0o700)) == null;
}

/// Connections taken per turn of the main loop: the rest wait for the
/// next, so a flood of them cannot hold the window.
const accepts_max = 16;
/// How much more room a connection's buffer gets each time it fills, up to
/// ipc.request_bytes_max.
const read_chunk_bytes = 64 << 10;

comptime {
    std.debug.assert(read_chunk_bytes <= ipc.request_bytes_max);
}
/// Connections open at once; past it the socket is left alone until one
/// ends (each may hold a request up to ipc.request_bytes_max). Also the
/// listen backlog.
const connections_max = 16;
/// How long a client has to send its request, and again to take the answer.
const client_timeout_ms = 10_000;
/// Out of descriptors: how long to wait before accepting again.
const backoff_ms = 500;

fn watchSocket() void {
    assert(server.listening());
    assert(server.accepting == .paused);
    const source = c.g_unix_fd_add(server.listen_fd, c.G_IO_IN, &acceptCallback, null);
    server.accepting = .{ .watching = source };
}

fn acceptCallback(fd: c_int, _: c_uint, _: ?*anyopaque) callconv(.c) c.gboolean {
    assert(server.accepting == .watching);
    for (0..accepts_max) |_| {
        if (server.connections_open == connections_max) return pauseUntilRoom();
        const accepted = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
        if (failed(accepted)) |errno| switch (errno) {
            // The connection stays queued and the socket readable: watching
            // it now would wake the main loop again at once, forever.
            .MFILE, .NFILE, .NOBUFS, .NOMEM => {
                log.warn("cannot accept a connection: {t}", .{errno});
                return backOff();
            },
            else => break,
        };
        Connection.open(@intCast(accepted));
    }
    return 1;
}

/// Stops watching the socket until a connection ends. Returns what removes
/// the socket's current watch.
fn pauseUntilRoom() c.gboolean {
    server.accepting = .paused;
    return 0;
}

/// Stops watching the socket for `backoff_ms`. Returns what removes the
/// socket's current watch.
fn backOff() c.gboolean {
    server.accepting = .{ .backing_off = c.g_timeout_add(backoff_ms, &backOffCallback, null) };
    return 0;
}

fn backOffCallback(_: ?*anyopaque) callconv(.c) c.gboolean {
    assert(server.accepting == .backing_off);
    // The source ends with this call: watchSocket must see it gone.
    server.accepting = .paused;
    watchSocket();
    return 0;
}

/// One client: its request as it arrives, then the answer as it leaves.
const Connection = struct {
    fd: linux.fd_t,
    phase: enum { request, answer } = .request,
    /// The request, then the answer.
    bytes: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    watch: c_uint = 0,
    timer: c_uint = 0,

    fn open(fd: linux.fd_t) void {
        // Only our own user (the folder is owner-only already).
        if (os.unix.peerUid(fd) != linux.getuid()) {
            log.warn("refused a connection from another user", .{});
            _ = linux.close(fd);
            return;
        }
        const self = server.gpa.create(Connection) catch {
            log.warn("out of memory: a connection refused", .{});
            _ = linux.close(fd);
            return;
        };
        self.* = .{ .fd = fd };
        server.connections_open += 1;
        assert(server.connections_open <= connections_max);
        self.watch = c.g_unix_fd_add(fd, c.G_IO_IN, &readableCallback, self);
        self.timer = c.g_timeout_add(client_timeout_ms, &timeoutCallback, self);
    }

    /// Ends the connection, from anywhere, its own callbacks included (a
    /// source removed while it runs is safe in GLib).
    fn close(self: *Connection) void {
        if (self.watch != 0) _ = c.g_source_remove(self.watch);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        _ = linux.close(self.fd);
        self.bytes.deinit(server.gpa);
        server.gpa.destroy(self);
        assert(server.connections_open > 0);
        server.connections_open -= 1;
        // Paused at connections_max: there is room again.
        if (server.listening() and server.accepting == .paused) watchSocket();
    }

    fn readableCallback(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Connection = @ptrCast(@alignCast(data));
        switch (self.read()) {
            .more => return 1,
            .failed => self.close(),
            .done => self.answer(),
        }
        return 0;
    }

    fn writableCallback(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Connection = @ptrCast(@alignCast(data));
        self.flush();
        return 1;
    }

    fn timeoutCallback(data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Connection = @ptrCast(@alignCast(data));
        log.warn("dropped a client too slow to {s}", .{switch (self.phase) {
            .request => "send its request",
            .answer => "take the answer",
        }});
        self.close();
        return 0;
    }

    /// Reads what the client has sent so far; done at the end of its input
    /// or when the buffer is full (the client sends no more than that).
    fn read(self: *Connection) enum { more, done, failed } {
        while (self.bytes.items.len < ipc.request_bytes_max) {
            self.bytes.ensureUnusedCapacity(server.gpa, read_chunk_bytes) catch return .failed;
            const spare = self.bytes.unusedCapacitySlice();
            const room = @min(spare.len, ipc.request_bytes_max - self.bytes.items.len);
            const bytes_read = linux.read(self.fd, spare.ptr, room);
            if (failed(bytes_read)) |errno| switch (errno) {
                .AGAIN => return .more,
                .INTR => continue,
                else => {
                    log.warn("dropped a request: {t}", .{errno});
                    return .failed;
                },
            };
            if (bytes_read == 0) return .done;
            self.bytes.items.len += bytes_read;
        }
        return .done;
    }

    /// Runs the request and starts sending the answer.
    fn answer(self: *Connection) void {
        _ = c.g_source_remove(self.watch);
        _ = c.g_source_remove(self.timer);
        self.watch = 0;
        self.timer = 0;
        self.phase = .answer;
        const request = ipc.parse(self.bytes.items) orelse {
            log.warn("dropped a malformed request", .{});
            return self.close();
        };

        var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const arguments_count = request.arguments_count;
        const arguments = arena.alloc([:0]const u8, arguments_count) catch return self.close();
        for (request.arguments[0..arguments_count], arguments) |argument, *argument_z| {
            argument_z.* = arena.dupeSentinel(u8, argument, 0) catch return self.close();
        }
        var stdout: std.Io.Writer.Allocating = .init(arena);
        var stderr: std.Io.Writer.Allocating = .init(arena);
        const status = server.handler(arguments, request.payload, &stdout.writer, &stderr.writer);

        // The request is done with: the buffer takes the answer.
        self.bytes.clearRetainingCapacity();
        const stdout_len = std.math.cast(u32, stdout.written().len) orelse {
            log.warn("an answer over 4 GiB, dropped", .{});
            return self.close();
        };
        const header = ipc.encodeAnswerHeader(status, stdout_len);
        self.bytes.appendSlice(server.gpa, &header) catch return self.close();
        self.bytes.appendSlice(server.gpa, stdout.written()) catch return self.close();
        self.bytes.appendSlice(server.gpa, stderr.written()) catch return self.close();
        self.flush();
    }

    /// Sends what the client takes now, and the rest when it can take more;
    /// closes once all is sent.
    fn flush(self: *Connection) void {
        while (self.sent < self.bytes.items.len) {
            const bytes_sent = os.unix.send(self.fd, self.bytes.items[self.sent..]);
            if (failed(bytes_sent)) |errno| switch (errno) {
                .INTR => continue,
                .AGAIN => return self.watchWritable(),
                // The client has gone (EPIPE, or Ctrl-C): nothing to answer.
                else => {
                    log.debug("the client left before its answer: {t}", .{errno});
                    return self.close();
                },
            };
            self.sent += bytes_sent;
        }
        assert(self.sent == self.bytes.items.len);
        self.close();
    }

    /// The client takes no more for now: `flush` again once it can. The
    /// first time only; the deadline covers the whole answer.
    fn watchWritable(self: *Connection) void {
        assert(self.phase == .answer);
        if (self.watch != 0) return;
        self.watch = c.g_unix_fd_add(self.fd, c.G_IO_OUT, &writableCallback, self);
        self.timer = c.g_timeout_add(client_timeout_ms, &timeoutCallback, self);
    }
};

const testing = std.testing;

test "the socket's folder must be ours alone" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var root_buffer: [256]u8 = undefined;
    const root = try os.tmpDirPath(&tmp_dir, &root_buffer);
    var path_buffer: [512]u8 = undefined;

    // Ours but open to others: made owner-only.
    const open_dir = try std.mem.printSentinel(&path_buffer, "{s}/open", .{root}, 0);
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
    var link_buffer: [512]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buffer, "{s}/link", .{root}, 0);
    try testing.expect(failed(linux.symlink("open", link)) == null);
    try testing.expect(!isPrivateDir(link));

    const file = try std.mem.printSentinel(&path_buffer, "{s}/file", .{root}, 0);
    try os.writeFile(file, "x");
    try testing.expect(!isPrivateDir(file));
    const missing = try std.mem.printSentinel(&path_buffer, "{s}/missing", .{root}, 0);
    try testing.expect(!isPrivateDir(missing));
}

/// A client on its own thread: sends a request whole, reads the answer
/// (after `wait_ms`).
const TestClient = struct {
    path: [:0]const u8,
    arg: []const u8 = "--x",
    wait_ms: u64 = 0,
    got: []u8,
    got_len: usize = 0,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *TestClient) void {
        defer self.done.store(true, .release);
        const fd = os.unix.connect(self.path, .{}) orelse return;
        defer _ = linux.close(fd);
        var request: [64]u8 = undefined;
        const head = ipc.encode(&request, &.{self.arg}).?;
        @memcpy(request[head.len..][0..4], "copy");
        if (!os.unix.sendAll(fd, request[0 .. head.len + 4])) return;
        if (failed(linux.shutdown(fd, linux.SHUT.WR)) != null) return;
        os.sleepUs(self.wait_ms * std.time.us_per_ms);
        const deadline_ns = os.monotonicNs() + 2 * std.time.ns_per_s;
        self.got_len = os.unix.readAll(fd, self.got, deadline_ns) catch 0;
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
    // Out of memory, the answer would be cut short: another status says so.
    if (std.mem.eql(u8, args[0], "--big")) {
        out.splatByteAll('x', 1 << 20) catch return 1;
    } else {
        out.print("{s} {s}", .{ args[0], payload }) catch return 1;
    }
    return 7;
}

const Done = struct {
    var flag: *std.atomic.Value(bool) = undefined;
    fn answered() bool {
        return flag.load(.acquire);
    }
    fn closed() bool {
        return server.connections_open == 0;
    }
};

/// Runs the main loop until `done` says so, or a second has passed; the
/// longest one turn took.
fn iterateUntil(done: *const fn () bool) u64 {
    const start_ns = os.monotonicNs();
    var longest_ns: u64 = 0;
    while (!done() and os.monotonicNs() - start_ns < std.time.ns_per_s) {
        const turn_ns = os.monotonicNs();
        const busy = c.g_main_context_iteration(null, 0) != 0;
        longest_ns = @max(longest_ns, os.monotonicNs() - turn_ns);
        if (!busy) os.sleepUs(500);
    }
    return longest_ns;
}

/// Listens in a fresh folder; the socket's path, in `socket_path_buffer`.
fn testListen(tmp_dir: *std.testing.TmpDir, socket_path_buffer: []u8) ![:0]const u8 {
    var runtime_buffer: [256]u8 = undefined;
    // Relative: a socket's path must fit in 108 bytes.
    const runtime_dir = try os.tmpDirPath(tmp_dir, &runtime_buffer);
    try listenIn(testing.allocator, runtime_dir, "t", &testHandler);
    try testing.expect(server.listen_fd >= 0);
    return ipc.socketPath(socket_path_buffer, runtime_dir, "t").?;
}

test "each reason not to listen is an error of its own" {
    try testing.expectError(error.NoRuntimeDir, listenIn(testing.allocator, "", "t", &testHandler));

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var runtime_buffer: [256]u8 = undefined;
    const runtime_dir = try os.tmpDirPath(&tmp_dir, &runtime_buffer);
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
    try testing.expect(!server.listening());
}

test "a client that sends nothing holds neither the main loop nor the others" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var socket_path_buffer: [256]u8 = undefined;
    const socket_path = try testListen(&tmp_dir, &socket_path_buffer);
    defer stop();

    const stalled = os.unix.connect(socket_path, .{}).?;
    var got: [64]u8 = undefined;
    var client: TestClient = .{ .path = socket_path, .got = &got };
    const start_ns = os.monotonicNs();
    const thread = try client.start();
    _ = iterateUntil(&Done.answered);
    thread.join();
    // Served at once: a server waiting on the silent one would not be.
    try testing.expect(os.monotonicNs() - start_ns < 300 * std.time.ns_per_ms);
    const answer = ipc.parseAnswer(got[0..client.got_len]).?;
    try testing.expectEqual(@as(u8, 7), answer.status);
    try testing.expectEqualStrings("--x copy", answer.stdout);
    try testing.expectEqual(@as(usize, 1), server.connections_open);

    // It hangs up without a request: dropped, nothing left behind.
    _ = linux.close(stalled);
    _ = iterateUntil(&Done.closed);
    try testing.expectEqual(@as(usize, 0), server.connections_open);
}

test "a large answer goes out as the client takes it, the main loop turning" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var socket_path_buffer: [256]u8 = undefined;
    const socket_path = try testListen(&tmp_dir, &socket_path_buffer);
    defer stop();

    const got = try testing.allocator.alloc(u8, 2 << 20);
    defer testing.allocator.free(got);
    var client: TestClient = .{ .path = socket_path, .arg = "--big", .wait_ms = 200, .got = got };
    const thread = try client.start();
    const longest_ns = iterateUntil(&Done.answered);
    thread.join();
    try testing.expectEqual(@as(usize, ipc.answer_header_bytes + (1 << 20)), client.got_len);
    // Not one turn spent waiting for the client to read.
    try testing.expect(longest_ns < 100 * std.time.ns_per_ms);
    _ = iterateUntil(&Done.closed);
    try testing.expectEqual(@as(usize, 0), server.connections_open);
}
