//! Running other programs, through GLib so the GTK main loop stays in charge.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const os = @import("os");

const log = std.log.scoped(.proc);

/// Longest argv the spawn functions take (the program included).
pub const max_args = 32;

/// Fire and forget. Logs and gives up on failure, or when `argv` has more
/// than `max_args` entries.
pub fn spawn(argv: []const [:0]const u8) void {
    var buf: Argv = undefined;
    const ptr = buf.of(argv) orelse return;
    var err: ?*c.GError = null;
    // Reaped here rather than by an intermediate child: GLib otherwise forks
    // the daemon twice (a ~200 MB process) for every command it starts.
    var pid: c.GPid = 0;
    const ok = c.g_spawn_async(
        null,
        ptr,
        null,
        c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_DO_NOT_REAP_CHILD,
        null,
        null,
        &pid,
        &err,
    );
    if (ok == 0) return logError("spawn", argv[0], err);
    _ = c.g_child_watch_add(pid, &reap, null);
}

fn reap(pid: c.GPid, _: c_int, _: ?*anyopaque) callconv(.c) void {
    c.g_spawn_close_pid(pid);
}

/// `sh -c <cmd>`, fire and forget.
pub fn shell(cmd: [:0]const u8) void {
    spawn(&.{ "sh", "-c", cmd });
}

/// How long `output` waits for a program's output: it runs on the main loop.
const output_ms = 2000;

/// What `output` allocates with.
const alloc = std.heap.c_allocator;

/// Runs to completion and returns stdout, or null when it could not run or
/// was still writing after `output_ms` (then it is killed). Caller owns the
/// result and frees it with `free`.
pub fn output(argv: []const [:0]const u8) ?[:0]u8 {
    return outputWithin(argv, output_ms);
}

fn outputWithin(argv: []const [:0]const u8, limit_ms: u64) ?[:0]u8 {
    var buf: Argv = undefined;
    const ptr = buf.of(argv) orelse return null;
    var pid: c.GPid = 0;
    var out_fd: c_int = -1;
    var err: ?*c.GError = null;
    if (c.g_spawn_async_with_pipes(
        null,
        ptr,
        null,
        c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_STDERR_TO_DEV_NULL | c.G_SPAWN_DO_NOT_REAP_CHILD,
        null,
        null,
        &pid,
        null,
        &out_fd,
        null,
        &err,
    ) == 0) {
        logError("run", argv[0], err);
        return null;
    }
    // Reaped whenever it exits: until then its pid is not reused, so the
    // kill below cannot hit another process.
    _ = c.g_child_watch_add(pid, &reap, null);
    defer _ = linux.close(out_fd);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const deadline_ns = os.monotonicNs() + limit_ms * std.time.ns_per_ms;
    while (true) {
        var chunk: [16 * 1024]u8 = undefined;
        const n = os.unix.readSome(out_fd, &chunk, deadline_ns) catch |e| {
            if (e == error.Timeout) {
                log.warn("{s}: no answer in {d} ms, stopped", .{ argv[0], limit_ms });
                _ = linux.kill(pid, .KILL);
            }
            return null;
        };
        if (n == 0) break;
        out.appendSlice(alloc, chunk[0..n]) catch return null;
    }
    return out.toOwnedSliceSentinel(alloc, 0) catch null;
}

pub fn free(s: [:0]u8) void {
    alloc.free(s);
}

/// Runs `argv` with `input` on its stdin, without waiting for it to exit
/// (wl-copy keeps serving the selection in the background). The input is
/// written from the main loop as the program reads it, so one that does not
/// read cannot hold the window.
pub fn pipeTo(argv: []const [:0]const u8, input: []const u8) void {
    var buf: Argv = undefined;
    const ptr = buf.of(argv) orelse return;
    var err: ?*c.GError = null;
    const sp = c.g_subprocess_newv(ptr, c.G_SUBPROCESS_FLAGS_STDIN_PIPE, &err) orelse {
        logError("pipe", argv[0], err);
        return;
    };
    // A copy: `input` is the caller's only until this returns.
    const bytes = c.g_bytes_new(input.ptr, input.len);
    defer c.g_bytes_unref(bytes);
    // `sp` is released once the program has its input and has exited.
    c.g_subprocess_communicate_async(sp, bytes, null, &onPiped, null);
}

fn onPiped(source: ?*c.GObject, res: *c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const sp: *c.GSubprocess = @ptrCast(source.?);
    defer c.g_object_unref(sp);
    var err: ?*c.GError = null;
    if (c.g_subprocess_communicate_finish(sp, res, null, null, &err) == 0)
        warnError(.proc, err, "write to a program", .{});
}

/// Whether `name` is on PATH.
pub fn have(name: [:0]const u8) bool {
    const p = c.g_find_program_in_path(name.ptr) orelse return false;
    c.g_free(p);
    return true;
}

/// A NULL-terminated argv for GLib, on the caller's stack.
const Argv = struct {
    ptrs: [max_args:null]?[*:0]const u8,

    fn of(buf: *Argv, argv: []const [:0]const u8) ?[*:null]const ?[*:0]const u8 {
        if (argv.len == 0) return null;
        if (argv.len > max_args) {
            log.warn("{s}: {d} arguments, more than {d}", .{ argv[0], argv.len, max_args });
            return null;
        }
        for (argv, 0..) |a, i| buf.ptrs[i] = a.ptr;
        buf.ptrs[argv.len] = null;
        return &buf.ptrs;
    }
};

fn logError(what: []const u8, prog: []const u8, err: ?*c.GError) void {
    warnError(.proc, err, "{s} {s}", .{ what, prog });
}

/// Logs a GError, if there is one, as a warning under `scope` ("<what>:
/// <its message>"), and frees it.
pub fn warnError(
    comptime scope: @TypeOf(.enum_literal),
    err: ?*c.GError,
    comptime what: []const u8,
    args: anytype,
) void {
    const e = err orelse return;
    defer c.g_error_free(e);
    std.log.scoped(scope).warn(what ++ ": {s}", args ++ .{e.message});
}

/// The display's context for launching apps (startup notification, the
/// right screen); null without a display. The caller unrefs it.
pub fn launchContext() ?*c.GAppLaunchContext {
    const display = c.gdk_display_get_default() orelse return null;
    return @ptrCast(c.gdk_display_get_app_launch_context(display));
}

test "argv longer than the buffer is refused, not overflowed" {
    var long: [max_args + 1][:0]const u8 = @splat("x");
    var buf: Argv = undefined;
    try std.testing.expect(buf.of(&long) == null);
    const ok = buf.of(long[0..max_args]) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ok[max_args] == null);
    try std.testing.expect(buf.of(&.{}) == null);
}

test "output: what a program prints, or nothing once it takes too long" {
    const out = output(&.{ "sh", "-c", "echo hi" }) orelse return error.TestUnexpectedResult;
    defer free(out);
    try std.testing.expectEqualStrings("hi\n", out);

    const t0 = os.monotonicNs();
    try std.testing.expect(outputWithin(&.{ "sh", "-c", "echo partial; exec sleep 30" }, 100) == null);
    try std.testing.expect(os.monotonicNs() - t0 < std.time.ns_per_s);
}
