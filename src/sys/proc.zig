//! Running other programs, through GLib so the GTK main loop stays in charge.

const std = @import("std");
const c = @import("c");

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
    const ok = c.g_spawn_async(null, ptr, null, c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_DO_NOT_REAP_CHILD, null, null, &pid, &err);
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

/// Runs to completion and returns stdout, or null when it could not run.
/// Caller owns the result and frees it with `free`.
pub fn output(argv: []const [:0]const u8) ?[:0]u8 {
    var buf: Argv = undefined;
    const ptr = buf.of(argv) orelse return null;
    var out: ?[*:0]u8 = null;
    var status: c_int = 0;
    var err: ?*c.GError = null;
    const ok = c.g_spawn_sync(null, ptr, null, c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_STDERR_TO_DEV_NULL, null, null, &out, null, &status, &err);
    if (ok == 0) {
        logError("run", argv[0], err);
        return null;
    }
    return std.mem.span(out orelse return null);
}

pub fn free(s: [:0]u8) void {
    c.g_free(s.ptr);
}

/// Runs `argv` with `input` on its stdin, without waiting for it to exit
/// (wl-copy keeps serving the selection in the background).
pub fn pipeTo(argv: []const [:0]const u8, input: []const u8) void {
    var buf: Argv = undefined;
    const ptr = buf.of(argv) orelse return;
    var err: ?*c.GError = null;
    const sp = c.g_subprocess_newv(ptr, c.G_SUBPROCESS_FLAGS_STDIN_PIPE, &err) orelse {
        logError("pipe", argv[0], err);
        return;
    };
    defer c.g_object_unref(sp);
    // Not null: the process was started with a stdin pipe.
    const stdin = c.g_subprocess_get_stdin_pipe(sp);
    var written: usize = 0;
    if (c.g_output_stream_write_all(stdin, input.ptr, input.len, &written, null, &err) == 0) logError("write to", argv[0], err);
    _ = c.g_output_stream_close(stdin, null, null);
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
    if (err) |e| {
        log.warn("{s} {s}: {s}", .{ what, prog, e.message });
        c.g_error_free(e);
    }
}

test "argv longer than the buffer is refused, not overflowed" {
    var long: [max_args + 1][:0]const u8 = @splat("x");
    var buf: Argv = undefined;
    try std.testing.expect(buf.of(&long) == null);
    const ok = buf.of(long[0..max_args]) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ok[max_args] == null);
    try std.testing.expect(buf.of(&.{}) == null);
}
