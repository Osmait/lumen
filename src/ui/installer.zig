//! Extensions from git: `lumen --install URL [--as NAME]`, `--update
//! [NAME]`, `--uninstall NAME`. git (and rm) run as a GSubprocess, so the
//! daemon never waits on the network; the caller's command line is held
//! until the job is done, then gets the outcome printed and an exit code
//! (like dmenu). From Settings there is no caller: the outcome shows on the
//! selected row. The extensions reload after every change.

const std = @import("std");
const c = @import("c");
const Host = @import("../ext/Host.zig");
const os = @import("os");
const core = @import("core");
const Ui = @import("Ui.zig");
const ext_view = @import("ext_view.zig");

const log = std.log.scoped(.install);
const proc = @import("../sys/proc.zig");

const Kind = enum { install, update, uninstall };

const Job = struct {
    ui: *Ui,
    /// Null when started from Settings.
    cmdline: ?*c.GApplicationCommandLine,
    sp: *c.GSubprocess,
    kind: Kind,
    name: core.FixedStr(64) = .{},
    /// What removeTree deletes on failure: whole, never cut (see `start`).
    dir: core.FixedStr(4096) = .{},

    fn nameSlice(j: *const Job) []const u8 {
        return j.name.slice();
    }
    fn dirZ(j: *Job) [:0]const u8 {
        return j.dir.slice();
    }
};

/// The folder an extension `name` lives in, in `buf`.
fn extDir(ui: *Ui, buf: []u8, name: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/extensions/{s}", .{ ui.config_dir, name }, 0) catch null;
}

/// "https://github.com/me/lumen-weather.git" → "weather".
pub fn nameFromUrl(buf: []u8, url: []const u8) []const u8 {
    var trimmed = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, trimmed, ".git")) trimmed = trimmed[0 .. trimmed.len - 4];
    if (std.mem.findLastAny(u8, trimmed, "/:")) |i| trimmed = trimmed[i + 1 ..];
    for ([_][]const u8{ "lumen-ext-", "lumen-extension-", "lumen-" }) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix) and trimmed.len > prefix.len) {
            trimmed = trimmed[prefix.len..];
            break;
        }
    }
    if (std.mem.endsWith(u8, trimmed, "-lumen") and trimmed.len > 6) {
        trimmed = trimmed[0 .. trimmed.len - 6];
    }
    const length = @min(trimmed.len, buf.len);
    for (trimmed[0..length], buf[0..length]) |ch, *o| {
        const lower = std.ascii.toLower(ch);
        o.* = if (std.ascii.isAlphanumeric(lower) or lower == '-' or lower == '_') lower else '-';
    }
    return buf[0..length];
}

/// `fmt` in `buf`, cut to what fits, as valid UTF-8: it goes to the caller
/// over D-Bus, whose strings must be.
fn format(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    writer.print(fmt, args) catch {};
    const valid_len = core.utf8.validPrefix(writer.buffered()).len;
    buf[valid_len] = 0;
    return buf[0..valid_len :0];
}

/// The end of `s` in at most `max` bytes, from a character on, after "..."
/// when cut: the last lines git prints say why it failed. Formats as two
/// strings: `"{s}{s}"`.
fn tail(text: []const u8, max: usize) struct { []const u8, []const u8 } {
    if (text.len <= max) return .{ "", text };
    var i = text.len - max;
    while (i < text.len and text[i] & 0xC0 == 0x80) i += 1;
    return .{ "...", text[i..] };
}

/// A failure: to the caller's stderr (exit 1), or on the selected row.
fn fail(
    ui: *Ui,
    cmdline: ?*c.GApplicationCommandLine,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [1024]u8 = undefined;
    const msg = format(&buf, fmt, args);
    const cl = cmdline orelse return note(ui, msg);
    c.g_application_command_line_printerr(cl, "lumen: %s\n", msg.ptr);
    c.g_application_command_line_set_exit_status(cl, 1);
}

/// The first line of `msg` on the selected row (Settings has no caller),
/// now and again once the extensions have reloaded.
fn note(ui: *Ui, msg: []const u8) void {
    const line = std.mem.trim(u8, msg[0 .. std.mem.findScalar(u8, msg, '\n') orelse msg.len], " ");
    ui.after_reload.set(line);
    ui.after_reload_pending = true;
    ui.showFailure(ui.after_reload.slice());
}

pub fn install(
    ui: *Ui,
    cmdline: ?*c.GApplicationCommandLine,
    url: []const u8,
    as: ?[]const u8,
) void {
    var nbuf: [64]u8 = undefined;
    const name = as orelse nameFromUrl(&nbuf, url);
    if (!Host.validId(name)) {
        return fail(
            ui,
            cmdline,
            "\"{s}\" cannot be an extension name (a-z, 0-9, - and _); pick one with --as NAME",
            .{name},
        );
    }
    if (Host.reservedId(name)) {
        return fail(
            ui,
            cmdline,
            "\"{s}\" is taken (init.lua and the style run as it); pick another with --as NAME",
            .{name},
        );
    }
    var dbuf: [4096]u8 = undefined;
    const dir = extDir(ui, &dbuf, name) orelse return fail(ui, cmdline, "path too long", .{});
    if (os.info(dir) != null) {
        return fail(ui, cmdline, "{s} already exists: lumen --update {s}, or --as another name", .{
            dir,
            name,
        });
    }
    os.mkdirP(dir[0 .. std.mem.findScalarLast(u8, dir, '/') orelse dir.len]);
    var url_buffer: [2048]u8 = undefined;
    const url_z = std.mem.printSentinel(&url_buffer, "{s}", .{url}, 0) catch {
        return fail(ui, cmdline, "URL too long", .{});
    };
    // "--": a URL starting with "-" is not an option.
    var argv = [_:null]?[*:0]const u8{ "git", "clone", "--depth", "1", "--", url_z.ptr, dir.ptr };
    start(ui, cmdline, .install, name, dir, &argv);
}

pub fn update(ui: *Ui, cmdline: ?*c.GApplicationCommandLine, name: ?[]const u8) void {
    var dbuf: [4096]u8 = undefined;
    if (name) |extension_name| {
        if (!Host.validId(extension_name)) {
            return fail(ui, cmdline, "no extension named \"{s}\"", .{extension_name});
        }
        const dir = extDir(ui, &dbuf, extension_name) orelse return fail(
            ui,
            cmdline,
            "path too long",
            .{},
        );
        if (os.info(dir) == null) {
            return fail(ui, cmdline, "no extension named \"{s}\"", .{extension_name});
        }
        var argv = [_:null]?[*:0]const u8{ "git", "-C", dir.ptr, "pull", "--ff-only" };
        return start(ui, cmdline, .update, extension_name, dir, &argv);
    }
    // Every extension that is a git checkout.
    const dir = std.mem.printSentinel(
        &dbuf,
        "{s}/extensions",
        .{ui.config_dir},
        0,
    ) catch return fail(ui, cmdline, "path too long", .{});
    var argv = [_:null]?[*:0]const u8{
        "sh",           "-c",
        \\cd "$1" || exit 1
        \\status=0
        \\for d in */; do
        \\  [ -d "$d.git" ] || continue
        \\  printf '%s: ' "${d%/}"
        \\  git -C "$d" pull --ff-only --quiet && echo up to date || status=1
        \\done
        \\exit $status
        ,
        "lumen-update", dir.ptr,
    };
    start(ui, cmdline, .update, "", dir, &argv);
}

pub fn uninstall(ui: *Ui, cmdline: ?*c.GApplicationCommandLine, name: []const u8) void {
    if (!Host.validId(name)) return fail(ui, cmdline, "no extension named \"{s}\"", .{name});
    var dbuf: [4096]u8 = undefined;
    const dir = extDir(ui, &dbuf, name) orelse return fail(ui, cmdline, "path too long", .{});
    if (os.info(dir) == null) {
        return fail(ui, cmdline, "no extension named \"{s}\"", .{name});
    }
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", dir.ptr };
    start(ui, cmdline, .uninstall, name, dir, &argv);
}

fn start(
    ui: *Ui,
    cmdline: ?*c.GApplicationCommandLine,
    kind: Kind,
    name: []const u8,
    dir: []const u8,
    argv: [*:null]?[*:0]const u8,
) void {
    var err: ?*c.GError = null;
    const sp = c.g_subprocess_newv(
        argv,
        c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_MERGE,
        &err,
    ) orelse {
        const msg: []const u8 = if (err) |gerror| std.mem.span(gerror.message) else "cannot start";
        fail(ui, cmdline, "{s}: {s}", .{ std.mem.span(argv[0].?), msg });
        if (err) |gerror| c.g_error_free(gerror);
        return;
    };
    const job = ui.gpa.create(Job) catch {
        c.g_object_unref(sp);
        return fail(ui, cmdline, "out of memory", .{});
    };
    job.* = .{
        .ui = ui,
        .cmdline = if (cmdline) |cl| @ptrCast(c.g_object_ref(cl)) else null,
        .sp = sp,
        .kind = kind,
    };
    job.name.set(name);
    // extDir builds it in a buffer of this size: it always fits.
    std.debug.assert(dir.len <= @TypeOf(job.dir).capacity);
    job.dir.set(dir);
    // As bytes: git prints file names and messages in any encoding, and the
    // UTF-8 variant fails on the first byte that is not.
    c.g_subprocess_communicate_async(sp, null, null, &onDone, job);
}

/// What the job printed, as UTF-8 (U+FFFD for what is not, NUL included):
/// it goes to the caller over D-Bus and onto a row. Free with g_free.
fn outputText(bytes: ?*c.GBytes) [:0]u8 {
    var len: usize = 0;
    const data: [*]const u8 = if (bytes) |data_bytes| c.g_bytes_get_data(
        data_bytes,
        &len,
    ) orelse "" else "";
    return std.mem.span(c.g_utf8_make_valid(data, @intCast(len)));
}

/// What git says last on a failure, in bytes: the message has to fit 1 KB.
const max_failure_output = 800;

fn onDone(_: ?*c.GObject, async_result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    const ui = job.ui;
    const cmdline = job.cmdline;
    defer {
        c.g_object_unref(job.sp);
        // The caller's `lumen --install` returns once this is released.
        if (cmdline) |cl| c.g_object_unref(cl);
        ui.gpa.destroy(job);
    }
    var out: ?*c.GBytes = null;
    var err: ?*c.GError = null;
    const ran = c.g_subprocess_communicate_finish(job.sp, async_result, &out, null, &err) != 0;
    defer if (err) |gerror| c.g_error_free(gerror);
    defer if (out) |output_bytes| c.g_bytes_unref(output_bytes);
    const output = outputText(out);
    defer c.g_free(output.ptr);
    // Failed or not, the files may have changed (half a pull, a clone
    // removed again): the extensions load again, after the message.
    defer ext_view.reload(ui);
    const ok = ran and err == null and c.g_subprocess_get_successful(job.sp) != 0;
    if (!ok) {
        // A failed clone can leave half a folder behind, and the next
        // install would find it there.
        if (job.kind == .install) removeTree(job.dirZ());
        const why = if (err) |gerror| std.mem.span(gerror.message) else std.mem.trim(
            u8,
            output,
            " \n",
        );
        const end = tail(why, max_failure_output);
        return fail(ui, cmdline, "{s} failed:\n{s}{s}", .{ @tagName(job.kind), end[0], end[1] });
    }
    switch (job.kind) {
        .install => {
            var buf: [4200]u8 = undefined;
            const init = std.mem.printSentinel(&buf, "{s}/init.lua", .{job.dirZ()}, 0) catch "";
            if (os.info(init) == null) {
                removeTree(job.dirZ());
                return fail(
                    ui,
                    cmdline,
                    "{s} has no init.lua: it is not a Lumen extension",
                    .{job.nameSlice()},
                );
            }
            print(
                ui,
                cmdline,
                "Installed {s} in {s}\nExtensions run as you: read its init.lua to know what it does.\n",
                .{ job.nameSlice(), job.dirZ() },
            );
        },
        .update => if (cmdline != null) {
            const end = tail(if (output.len > 0) output else "Up to date\n", max_print - 8);
            print(ui, cmdline, "{s}{s}", .{ end[0], end[1] });
        } else {
            // git's own lines are too long for a row: a summary.
            const none = output.len == 0 or std.mem.find(u8, output, "Already up to date") != null;
            note(ui, if (none) "Already up to date" else "Updated");
        },
        .uninstall => print(ui, cmdline, "Removed {s}\n", .{job.nameSlice()}),
    }
    if (cmdline) |cl| c.g_application_command_line_set_exit_status(cl, 0);
    // From Settings: the removed extension's page has nothing left to show.
    if (cmdline == null and job.kind == .uninstall and ui.view == .prefs) ui.goBack();
}

const max_print = 8192;

/// Success: to the caller's stdout, or on the selected row.
fn print(
    ui: *Ui,
    cmdline: ?*c.GApplicationCommandLine,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [max_print]u8 = undefined;
    const msg = format(&buf, fmt, args);
    const cl = cmdline orelse return note(ui, msg);
    c.g_application_command_line_print(cl, "%s", msg.ptr);
}

/// rm -rf, waited for (a fresh clone: small and local).
fn removeTree(dir: [:0]const u8) void {
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", dir.ptr };
    var err: ?*c.GError = null;
    if (c.g_spawn_sync(
        null,
        @ptrCast(&argv),
        null,
        c.G_SPAWN_SEARCH_PATH,
        null,
        null,
        null,
        null,
        null,
        &err,
    ) == 0) {
        proc.warnError(.install, err, "rm {s}", .{dir});
    }
}

test "long output keeps its end, and messages stay valid UTF-8" {
    const short = tail("fatal: no such repo", 100);
    try std.testing.expectEqualStrings("", short[0]);
    try std.testing.expectEqualStrings("fatal: no such repo", short[1]);
    // Cut before "é" would split it: from the next character on.
    const cut = tail("aaaaé fatal", 7);
    try std.testing.expectEqualStrings("...", cut[0]);
    try std.testing.expectEqualStrings(" fatal", cut[1]);
    var buf: [8]u8 = undefined;
    // Too long: what fits, never half a character.
    try std.testing.expectEqualStrings("abcdé", format(&buf, "{s}", .{"abcdéé"}));
    try std.testing.expectEqualStrings("ok", format(&buf, "{s}", .{"ok"}));
}

test "extension names come from the repository" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("weather", nameFromUrl(
        &buf,
        "https://github.com/me/lumen-weather.git",
    ));
    try std.testing.expectEqualStrings("github", nameFromUrl(
        &buf,
        "git@github.com:me/lumen-ext-github",
    ));
    try std.testing.expectEqualStrings("todo", nameFromUrl(
        &buf,
        "https://codeberg.org/x/todo-lumen/",
    ));
    try std.testing.expectEqualStrings("my-tool", nameFromUrl(&buf, "/home/me/src/My.Tool"));
    try std.testing.expectEqualStrings("lumen", nameFromUrl(&buf, "https://github.com/x/lumen"));
}
