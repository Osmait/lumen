//! Running other programs, through GLib so the GTK main loop stays in charge.

const std = @import("std");
const c = @import("c");

/// Fire and forget. `argv` entries must be NUL-terminated.
pub fn spawn(argv: []const [:0]const u8) void {
    var buf: [32:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| buf[i] = a.ptr;
    buf[argv.len] = null;
    var err: ?*c.GError = null;
    const ok = c.g_spawn_async(null, @ptrCast(&buf), null, c.G_SPAWN_SEARCH_PATH, null, null, null, &err);
    if (ok == 0) logError("spawn", argv[0], err);
}

/// `sh -c <cmd>`, fire and forget.
pub fn shell(cmd: [:0]const u8) void {
    spawn(&.{ "sh", "-c", cmd });
}

/// Runs to completion and returns stdout (g_free it with `free`), or null.
pub fn output(argv: []const [:0]const u8) ?[:0]u8 {
    var buf: [32:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| buf[i] = a.ptr;
    var out: [*c]u8 = null;
    var status: c_int = 0;
    var err: ?*c.GError = null;
    const ok = c.g_spawn_sync(null, @ptrCast(&buf), null, c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_STDERR_TO_DEV_NULL, null, null, &out, null, &status, &err);
    if (ok == 0) {
        logError("run", argv[0], err);
        return null;
    }
    if (out == null) return null;
    return std.mem.span(@as([*:0]u8, @ptrCast(out)));
}

pub fn free(s: [:0]u8) void {
    c.g_free(s.ptr);
}

/// Runs `argv` with `input` on its stdin, without waiting for it to exit
/// (wl-copy keeps serving the selection in the background).
pub fn pipeTo(argv: []const [:0]const u8, input: []const u8) void {
    var buf: [32:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| buf[i] = a.ptr;
    var err: ?*c.GError = null;
    const sp = c.g_subprocess_newv(@ptrCast(&buf), c.G_SUBPROCESS_FLAGS_STDIN_PIPE, &err) orelse {
        logError("pipe", argv[0], err);
        return;
    };
    defer c.g_object_unref(sp);
    const stdin = c.g_subprocess_get_stdin_pipe(sp);
    var written: usize = 0;
    _ = c.g_output_stream_write_all(stdin, input.ptr, input.len, &written, null, null);
    _ = c.g_output_stream_close(stdin, null, null);
}

/// Whether `name` is on PATH.
pub fn have(name: [:0]const u8) bool {
    const p = c.g_find_program_in_path(name.ptr);
    if (p == null) return false;
    c.g_free(p);
    return true;
}

fn logError(what: []const u8, prog: []const u8, err: ?*c.GError) void {
    if (err) |e| {
        std.log.warn("{s} {s}: {s}", .{ what, prog, e.message });
        c.g_error_free(e);
    }
}
