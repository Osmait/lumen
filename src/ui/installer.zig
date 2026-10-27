//! Extensions from git: `lumen --install URL [--as NAME]`, `--update
//! [NAME]`, `--uninstall NAME`. git (and rm) run as a GSubprocess, so the
//! daemon never waits on the network; the caller's command line is held
//! until the job is done, then gets the outcome printed and an exit code
//! (like dmenu). The extensions reload after every change.

const std = @import("std");
const c = @import("c");
const Host = @import("../ext/Host.zig");
const index = @import("index");
const Ui = @import("Ui.zig");
const ext_view = @import("ext_view.zig");

const log = std.log.scoped(.install);

const Kind = enum { install, update, uninstall };

const Job = struct {
    ui: *Ui,
    cmdline: *c.GApplicationCommandLine,
    sp: *c.GSubprocess,
    kind: Kind,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    dir: [4096]u8 = undefined,
    dir_len: usize = 0,

    fn nameSlice(j: *const Job) []const u8 {
        return j.name[0..j.name_len];
    }
    fn dirZ(j: *Job) [:0]const u8 {
        return j.dir[0..j.dir_len :0];
    }
};

/// The folder an extension `name` lives in, in `buf`.
fn extDir(ui: *Ui, buf: []u8, name: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/extensions/{s}", .{ ui.config_dir, name }, 0) catch null;
}

/// "https://github.com/me/lumen-weather.git" → "weather".
pub fn nameFromUrl(buf: []u8, url: []const u8) []const u8 {
    var s = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];
    if (std.mem.findLastAny(u8, s, "/:")) |i| s = s[i + 1 ..];
    for ([_][]const u8{ "lumen-ext-", "lumen-extension-", "lumen-" }) |p| {
        if (std.mem.startsWith(u8, s, p) and s.len > p.len) {
            s = s[p.len..];
            break;
        }
    }
    if (std.mem.endsWith(u8, s, "-lumen") and s.len > 6) s = s[0 .. s.len - 6];
    const n = @min(s.len, buf.len);
    for (s[0..n], buf[0..n]) |ch, *o| {
        const l = std.ascii.toLower(ch);
        o.* = if (std.ascii.isAlphanumeric(l) or l == '-' or l == '_') l else '-';
    }
    return buf[0..n];
}

fn fail(cmdline: *c.GApplicationCommandLine, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "lumen: " ++ fmt ++ "\n", args, 0) catch "lumen: failed\n";
    c.g_application_command_line_printerr(cmdline, "%s", msg.ptr);
    c.g_application_command_line_set_exit_status(cmdline, 1);
}

pub fn install(ui: *Ui, cmdline: *c.GApplicationCommandLine, url: []const u8, as: ?[]const u8) void {
    var nbuf: [64]u8 = undefined;
    const name = as orelse nameFromUrl(&nbuf, url);
    if (!Host.validId(name)) return fail(cmdline, "\"{s}\" cannot be an extension name (a-z, 0-9, - and _); pick one with --as NAME", .{name});
    var dbuf: [4096]u8 = undefined;
    const dir = extDir(ui, &dbuf, name) orelse return fail(cmdline, "path too long", .{});
    if (index.sys.info(dir) != null) return fail(cmdline, "{s} already exists: lumen --update {s}, or --as another name", .{ dir, name });
    index.sys.mkdirP(dir[0 .. std.mem.findScalarLast(u8, dir, '/') orelse dir.len]);
    var ubuf: [2048]u8 = undefined;
    const url_z = std.fmt.bufPrintSentinel(&ubuf, "{s}", .{url}, 0) catch return fail(cmdline, "URL too long", .{});
    // "--": a URL starting with "-" is not an option.
    var argv = [_:null]?[*:0]const u8{ "git", "clone", "--depth", "1", "--", url_z.ptr, dir.ptr };
    start(ui, cmdline, .install, name, dir, &argv);
}

pub fn update(ui: *Ui, cmdline: *c.GApplicationCommandLine, name: ?[]const u8) void {
    var dbuf: [4096]u8 = undefined;
    if (name) |n| {
        if (!Host.validId(n)) return fail(cmdline, "no extension named \"{s}\"", .{n});
        const dir = extDir(ui, &dbuf, n) orelse return fail(cmdline, "path too long", .{});
        if (index.sys.info(dir) == null) return fail(cmdline, "no extension named \"{s}\"", .{n});
        var argv = [_:null]?[*:0]const u8{ "git", "-C", dir.ptr, "pull", "--ff-only" };
        return start(ui, cmdline, .update, n, dir, &argv);
    }
    // Every extension that is a git checkout.
    const dir = std.fmt.bufPrintSentinel(&dbuf, "{s}/extensions", .{ui.config_dir}, 0) catch return fail(cmdline, "path too long", .{});
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

pub fn uninstall(ui: *Ui, cmdline: *c.GApplicationCommandLine, name: []const u8) void {
    if (!Host.validId(name)) return fail(cmdline, "no extension named \"{s}\"", .{name});
    var dbuf: [4096]u8 = undefined;
    const dir = extDir(ui, &dbuf, name) orelse return fail(cmdline, "path too long", .{});
    if (index.sys.info(dir) == null) return fail(cmdline, "no extension named \"{s}\"", .{name});
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", dir.ptr };
    start(ui, cmdline, .uninstall, name, dir, &argv);
}

fn start(ui: *Ui, cmdline: *c.GApplicationCommandLine, kind: Kind, name: []const u8, dir: []const u8, argv: [*:null]?[*:0]const u8) void {
    var err: ?*c.GError = null;
    const sp = c.g_subprocess_newv(argv, c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_MERGE, &err) orelse {
        const msg: []const u8 = if (err) |e| std.mem.span(e.message) else "cannot start";
        fail(cmdline, "{s}: {s}", .{ std.mem.span(argv[0].?), msg });
        if (err) |e| c.g_error_free(e);
        return;
    };
    const job = ui.gpa.create(Job) catch {
        c.g_object_unref(sp);
        return fail(cmdline, "out of memory", .{});
    };
    job.* = .{ .ui = ui, .cmdline = @ptrCast(c.g_object_ref(cmdline)), .sp = sp, .kind = kind };
    job.name_len = @min(name.len, job.name.len);
    @memcpy(job.name[0..job.name_len], name[0..job.name_len]);
    job.dir_len = @min(dir.len, job.dir.len - 1);
    @memcpy(job.dir[0..job.dir_len], dir[0..job.dir_len]);
    job.dir[job.dir_len] = 0;
    c.g_subprocess_communicate_utf8_async(sp, null, null, &onDone, job);
}

fn onDone(_: ?*c.GObject, res: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    const ui = job.ui;
    const cmdline = job.cmdline;
    defer {
        c.g_object_unref(job.sp);
        // The caller's `lumen --install` returns once this is released.
        c.g_object_unref(cmdline);
        ui.gpa.destroy(job);
    }
    var out: ?[*:0]u8 = null;
    var err: ?*c.GError = null;
    const ran = c.g_subprocess_communicate_utf8_finish(job.sp, res, &out, null, &err) != 0;
    defer if (out) |o| c.g_free(o);
    if (err) |e| {
        fail(cmdline, "{s}", .{std.mem.span(e.message)});
        c.g_error_free(e);
        return;
    }
    const output: []const u8 = if (out) |o| std.mem.span(o) else "";
    const ok = ran and c.g_subprocess_get_successful(job.sp) != 0;
    if (!ok) {
        if (job.kind == .install) {
            // A failed clone can leave half a folder behind.
            removeTree(job.dirZ());
        }
        return fail(cmdline, "{s} failed:\n{s}", .{ @tagName(job.kind), std.mem.trim(u8, output, " \n") });
    }
    switch (job.kind) {
        .install => {
            var buf: [4200]u8 = undefined;
            const init = std.fmt.bufPrintSentinel(&buf, "{s}/init.lua", .{job.dirZ()}, 0) catch "";
            if (index.sys.info(init) == null) {
                removeTree(job.dirZ());
                return fail(cmdline, "{s} has no init.lua: it is not a Lumen extension", .{job.nameSlice()});
            }
            print(cmdline, "Installed {s} in {s}\nExtensions run as you: read its init.lua to know what it does.\n", .{ job.nameSlice(), job.dirZ() });
        },
        .update => print(cmdline, "{s}", .{if (output.len > 0) output else "Up to date\n"}),
        .uninstall => print(cmdline, "Removed {s}\n", .{job.nameSlice()}),
    }
    c.g_application_command_line_set_exit_status(cmdline, 0);
    ext_view.reload(ui);
}

fn print(cmdline: *c.GApplicationCommandLine, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    c.g_application_command_line_print(cmdline, "%s", msg.ptr);
}

/// rm -rf, waited for (a fresh clone: small and local).
fn removeTree(dir: [:0]const u8) void {
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", dir.ptr };
    var err: ?*c.GError = null;
    if (c.g_spawn_sync(null, @ptrCast(&argv), null, c.G_SPAWN_SEARCH_PATH, null, null, null, null, null, &err) == 0) {
        if (err) |e| {
            log.warn("rm {s}: {s}", .{ dir, e.message });
            c.g_error_free(e);
        }
    }
}

test "extension names come from the repository" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("weather", nameFromUrl(&buf, "https://github.com/me/lumen-weather.git"));
    try std.testing.expectEqualStrings("github", nameFromUrl(&buf, "git@github.com:me/lumen-ext-github"));
    try std.testing.expectEqualStrings("todo", nameFromUrl(&buf, "https://codeberg.org/x/todo-lumen/"));
    try std.testing.expectEqualStrings("my-tool", nameFromUrl(&buf, "/home/me/src/My.Tool"));
    try std.testing.expectEqualStrings("lumen", nameFromUrl(&buf, "https://github.com/x/lumen"));
}
