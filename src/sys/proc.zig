//! Running other programs, through GLib so the GTK main loop stays in charge.

const std = @import("std");
const linux = std.os.linux;
const c = @import("c");
const os = @import("os");

const log = std.log.scoped(.proc);

/// Longest argv the spawn functions take (the program included).
pub const argv_max = 32;

/// Fire and forget. Logs and gives up on failure, or when `argv` has more
/// than `argv_max` entries.
pub fn spawn(argv: []const [:0]const u8) void {
    var argv_buffer: Argv = undefined;
    const argv_z = argv_buffer.of(argv) orelse return;
    var err: ?*c.GError = null;
    // Reaped here rather than by an intermediate child: GLib otherwise forks
    // the daemon twice (a ~200 MB process) for every command it starts.
    var pid: c.GPid = 0;
    const spawned = c.g_spawn_async(
        null,
        argv_z,
        null,
        c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_DO_NOT_REAP_CHILD,
        null,
        null,
        &pid,
        &err,
    );
    if (spawned == 0) return logError("spawn", argv[0], err);
    _ = c.g_child_watch_add(pid, &reapCallback, null);
}

/// Reaps a child spawned without GLib's intermediate one, when it exits.
fn reapCallback(pid: c.GPid, _: c_int, _: ?*anyopaque) callconv(.c) void {
    c.g_spawn_close_pid(pid);
}

/// `sh -c <command>`, fire and forget.
pub fn shell(command: [:0]const u8) void {
    spawn(&.{ "sh", "-c", command });
}

/// How long `output` waits for a program's output: it runs on the main loop.
const output_timeout_ms = 2000;
/// What one read of that output takes (hyprctl's JSON is a few KB).
const output_chunk_bytes = 16 << 10;
/// Most output `output` keeps: past it the program is killed and dropped
/// (`hyprctl -j clients` with 200 windows is ~300 KB).
const output_bytes_max = 16 << 20;

/// Runs to completion and returns stdout, or null when it could not run,
/// was still writing after `output_timeout_ms` or wrote more than
/// `output_bytes_max` (then it is killed). Caller owns the
/// result and frees it with `free`.
pub fn output(gpa: std.mem.Allocator, argv: []const [:0]const u8) ?[:0]u8 {
    return outputWithin(gpa, argv, output_timeout_ms, output_bytes_max);
}

/// Like `output`, with an explicit timeout in milliseconds.
pub fn outputTimeout(gpa: std.mem.Allocator, argv: []const [:0]const u8, timeout_ms: u64) ?[:0]u8 {
    return outputWithin(gpa, argv, timeout_ms, output_bytes_max);
}

fn outputWithin(
    gpa: std.mem.Allocator,
    argv: []const [:0]const u8,
    timeout_ms: u64,
    bytes_max: usize,
) ?[:0]u8 {
    var argv_buffer: Argv = undefined;
    const argv_z = argv_buffer.of(argv) orelse return null;
    var pid: c.GPid = 0;
    var stdout_fd: c_int = -1;
    var err: ?*c.GError = null;
    const spawned = c.g_spawn_async_with_pipes(
        null,
        argv_z,
        null,
        c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_STDERR_TO_DEV_NULL | c.G_SPAWN_DO_NOT_REAP_CHILD,
        null,
        null,
        &pid,
        null,
        &stdout_fd,
        null,
        &err,
    );
    if (spawned == 0) {
        logError("run", argv[0], err);
        return null;
    }
    // Reaped whenever it exits: until then its pid is not reused, so the
    // kill below cannot hit another process.
    _ = c.g_child_watch_add(pid, &reapCallback, null);
    defer _ = linux.close(stdout_fd);
    // Any way out but the end of its output (deadline, failed read, cap, no
    // memory) kills it. Not reaped yet (see above), so the kill cannot miss.
    var output_ended = false;
    defer if (!output_ended) {
        _ = linux.kill(pid, .KILL);
    };
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(gpa);
    const deadline_ns = os.monotonicNs() + timeout_ms * std.time.ns_per_ms;
    while (true) {
        var chunk: [output_chunk_bytes]u8 = undefined;
        const chunk_len = os.unix.readSome(stdout_fd, &chunk, deadline_ns) catch |read_err| {
            switch (read_err) {
                error.Timeout => log.warn(
                    "{s}: no answer in {d} ms, stopped",
                    .{ argv[0], timeout_ms },
                ),
                error.Syscall => log.warn("{s}: reading its output failed, stopped", .{argv[0]}),
            }
            return null;
        };
        if (chunk_len == 0) break;
        if (chunk_len > bytes_max - stdout.items.len) {
            log.warn("{s}: output over {d} bytes, stopped", .{ argv[0], bytes_max });
            return null;
        }
        stdout.appendSlice(gpa, chunk[0..chunk_len]) catch return null;
    }
    output_ended = true;
    return stdout.toOwnedSliceSentinel(gpa, 0) catch null;
}

pub fn free(gpa: std.mem.Allocator, text: [:0]u8) void {
    gpa.free(text);
}

/// Runs `argv` with `input` on its stdin, without waiting for it to exit
/// (wl-copy keeps serving the selection in the background). The input is
/// written from the main loop as the program reads it, so one that does not
/// read cannot hold the window.
pub fn pipeTo(argv: []const [:0]const u8, input: []const u8) void {
    var argv_buffer: Argv = undefined;
    const argv_z = argv_buffer.of(argv) orelse return;
    var err: ?*c.GError = null;
    const flags = c.G_SUBPROCESS_FLAGS_STDIN_PIPE;
    const subprocess = c.g_subprocess_newv(argv_z, flags, &err) orelse {
        logError("pipe", argv[0], err);
        return;
    };
    const bytes = c.g_bytes_new(input.ptr, input.len);
    defer c.g_bytes_unref(bytes);
    c.g_subprocess_communicate_async(subprocess, bytes, null, &pipeToCallback, null);
}

/// Called once a `pipeToThen` program has taken all its input and exited
/// (successfully or not, `ok` says), with the context it was given.
pub const Then = struct {
    callback: *const fn (context: usize, ok: bool) void,
    context: usize,
};

const ThenOwned = struct {
    gpa: std.mem.Allocator,
    then: Then,
};

/// `pipeTo`, then `then` once the program is done: wl-copy exits once it
/// owns the selection, so a paste sent after it pastes this text.
pub fn pipeToThen(
    gpa: std.mem.Allocator,
    argv: []const [:0]const u8,
    input: []const u8,
    then: ?Then,
) void {
    var argv_buffer: Argv = undefined;
    const argv_z = argv_buffer.of(argv) orelse {
        if (then) |done| done.callback(done.context, false);
        return;
    };
    // Reserve the completion box before spawning so OOM notifies without
    // launching a child whose outcome would otherwise be dropped or misreported.
    const then_owned: ?*ThenOwned = if (then) |done| blk: {
        const owned = gpa.create(ThenOwned) catch {
            done.callback(done.context, false);
            return;
        };
        owned.* = .{ .gpa = gpa, .then = done };
        break :blk owned;
    } else null;
    var err: ?*c.GError = null;
    const flags = c.G_SUBPROCESS_FLAGS_STDIN_PIPE;
    const subprocess = c.g_subprocess_newv(argv_z, flags, &err) orelse {
        if (then_owned) |owned| {
            const done = owned.then;
            owned.gpa.destroy(owned);
            logError("pipe", argv[0], err);
            done.callback(done.context, false);
            return;
        }
        logError("pipe", argv[0], err);
        return;
    };
    // A copy: `input` is the caller's only until this returns.
    const bytes = c.g_bytes_new(input.ptr, input.len);
    defer c.g_bytes_unref(bytes);
    // `subprocess` is released once the program has its input and exited.
    c.g_subprocess_communicate_async(subprocess, bytes, null, &pipeToCallback, then_owned);
}

fn pipeToCallback(
    source: ?*c.GObject,
    result: *c.GAsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const subprocess: *c.GSubprocess = @ptrCast(source.?);
    defer c.g_object_unref(subprocess);
    var err: ?*c.GError = null;
    const finished = c.g_subprocess_communicate_finish(subprocess, result, null, null, &err) != 0;
    if (!finished) warnError(.proc, err, "write to a program", .{});
    const owned: *ThenOwned = @ptrCast(@alignCast(data orelse return));
    const then = owned.then;
    owned.gpa.destroy(owned);
    const ok = finished and c.g_subprocess_get_successful(subprocess) != 0;
    then.callback(then.context, ok);
}

/// Whether `name` is on PATH.
pub fn have(name: [:0]const u8) bool {
    const program_path = c.g_find_program_in_path(name.ptr) orelse return false;
    c.g_free(program_path);
    return true;
}

/// A NULL-terminated argv for GLib, on the caller's stack.
const Argv = struct {
    pointers: [argv_max:null]?[*:0]const u8,

    fn of(buffer: *Argv, argv: []const [:0]const u8) ?[*:null]const ?[*:0]const u8 {
        if (argv.len == 0) return null;
        if (argv.len > argv_max) {
            log.warn("{s}: {d} arguments, more than {d}", .{ argv[0], argv.len, argv_max });
            return null;
        }
        for (argv, buffer.pointers[0..argv.len]) |arg, *pointer| pointer.* = arg.ptr;
        buffer.pointers[argv.len] = null;
        return &buffer.pointers;
    }
};

fn logError(what: []const u8, program: []const u8, err: ?*c.GError) void {
    warnError(.proc, err, "{s} {s}", .{ what, program });
}

/// Logs a GError, if there is one, as a warning under `scope` ("<what>:
/// <its message>"), and frees it.
pub fn warnError(
    comptime scope: @TypeOf(.enum_literal),
    err: ?*c.GError,
    comptime what: []const u8,
    args: anytype,
) void {
    const gerror = err orelse return;
    defer c.g_error_free(gerror);
    std.log.scoped(scope).warn(what ++ ": {s}", args ++ .{gerror.message});
}

/// The display's context for launching apps (startup notification, the
/// right screen); null without a display. The caller unrefs it.
pub fn launchContext() ?*c.GAppLaunchContext {
    const display = c.gdk_display_get_default() orelse return null;
    return @ptrCast(c.gdk_display_get_app_launch_context(display));
}

test "argv longer than the buffer is refused, not overflowed" {
    var long: [argv_max + 1][:0]const u8 = @splat("x");
    var argv_buffer: Argv = undefined;
    try std.testing.expect(argv_buffer.of(&long) == null);
    const argv_z = argv_buffer.of(long[0..argv_max]) orelse return error.TestUnexpectedResult;
    try std.testing.expect(argv_z[argv_max] == null);
    try std.testing.expect(argv_buffer.of(&.{}) == null);
}

test "output: what a program prints, or nothing once it takes too long" {
    const printed = output(std.testing.allocator, &.{ "sh", "-c", "echo hi" }) orelse
        return error.TestUnexpectedResult;
    defer free(std.testing.allocator, printed);
    try std.testing.expectEqualStrings("hi\n", printed);

    const start_ns = os.monotonicNs();
    const argv = &.{ "sh", "-c", "echo partial; exec sleep 30" };
    try std.testing.expect(outputWithin(std.testing.allocator, argv, 100, output_bytes_max) == null);
    try std.testing.expect(os.monotonicNs() - start_ns < std.time.ns_per_s);
}

test "output: a program that writes past the cap is stopped and dropped" {
    const start_ns = os.monotonicNs();
    // Would write forever: only the cap (or the kill after it) ends it.
    const argv = &.{ "sh", "-c", "exec yes" };
    try std.testing.expect(outputWithin(std.testing.allocator, argv, 5000, 64 << 10) == null);
    try std.testing.expect(os.monotonicNs() - start_ns < 5 * std.time.ns_per_s);
}

test "pipeToThen calls back once the program has its input and exited" {
    const Seen = struct {
        var calls: usize = 0;
        var ok_last = false;
        fn done(context: usize, ok: bool) void {
            std.debug.assert(context == 42);
            calls += 1;
            ok_last = ok;
        }
    };
    const then: Then = .{ .callback = &Seen.done, .context = 42 };
    const cases = [_]struct { argv: []const [:0]const u8, ok: bool }{
        .{ .argv = &.{ "sh", "-c", "cat >/dev/null" }, .ok = true },
        .{ .argv = &.{ "sh", "-c", "cat >/dev/null; exit 3" }, .ok = false },
    };
    for (cases, 1..) |case, calls_expected| {
        pipeToThen(std.testing.allocator, case.argv, "hello", then);
        const deadline_ns = os.monotonicNs() + 5 * std.time.ns_per_s;
        while (Seen.calls < calls_expected and os.monotonicNs() < deadline_ns) {
            _ = c.g_main_context_iteration(null, 1);
        }
        try std.testing.expectEqual(calls_expected, Seen.calls);
        try std.testing.expectEqual(case.ok, Seen.ok_last);
    }
}

test "pipeToThen calls back with ok = false on invalid argv or OOM without leaking" {
    const Seen = struct {
        var calls: usize = 0;
        var ok_last = true;
        fn done(context: usize, ok: bool) void {
            std.debug.assert(context == 99);
            calls += 1;
            ok_last = ok;
        }
    };
    const then: Then = .{ .callback = &Seen.done, .context = 99 };

    // Empty argv is refused synchronously with ok = false.
    pipeToThen(std.testing.allocator, &.{}, "hello", then);
    try std.testing.expectEqual(@as(usize, 1), Seen.calls);
    try std.testing.expect(!Seen.ok_last);

    // OOM allocating ThenOwned triggers callback synchronously without spawning.
    Seen.ok_last = true;
    pipeToThen(std.testing.failing_allocator, &.{"true"}, "hello", then);
    try std.testing.expectEqual(@as(usize, 2), Seen.calls);
    try std.testing.expect(!Seen.ok_last);
}
