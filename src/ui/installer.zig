//! Extensions from git: `lumen --install URL [--as NAME]`, `--update
//! [NAME]`, `--uninstall NAME`. git (and rm) run as a GSubprocess, so the
//! daemon never waits on the network; the caller's command line is held
//! until the job is done, then gets the outcome printed and an exit code
//! (like dmenu). From Settings there is no caller: the outcome shows on the
//! selected row. The extensions reload after every change.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const Host = @import("../ext/Host.zig");
const os = @import("os");
const core = @import("core");
const Ui = @import("Ui.zig");
const ext_view = @import("ext_view.zig");

const log = std.log.scoped(.install);
const proc = @import("../sys/proc.zig");

const Kind = enum { install, update, uninstall };

/// The name an extension is installed under (its folder), with room to
/// spare over the longest id Host accepts.
const extension_name_bytes_max = 64;

comptime {
    std.debug.assert(extension_name_bytes_max >= Host.id_bytes_max);
}

const Job = struct {
    ui: *Ui,
    /// Null when started from Settings.
    caller: ?*c.GApplicationCommandLine,
    subprocess: *c.GSubprocess,
    kind: Kind,
    name: core.FixedStr(extension_name_bytes_max) = .{},
    /// What removeTree deletes on failure: whole, never cut (see `start`).
    folder: core.FixedStr(std.Io.Dir.max_path_bytes) = .{},

    fn nameSlice(job: *const Job) []const u8 {
        return job.name.slice();
    }

    fn folderPath(job: *Job) [:0]const u8 {
        return job.folder.slice();
    }
};

/// The folder an extension `name` lives in, written to `out`.
fn extensionFolder(ui: *Ui, out: []u8, name: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(out, "{s}/extensions/{s}", .{ ui.config_dir, name }, 0) catch null;
}

/// What a repository's name carries that its extension's name does not:
/// git's suffix, and the project's name before or after it. The prefixes
/// go longest first, so "lumen-ext-x" loses "lumen-ext-", not "lumen-".
const git_suffix = ".git";
const repository_prefixes = [_][]const u8{ "lumen-ext-", "lumen-extension-", "lumen-" };
const repository_suffix = "-lumen";

/// "https://github.com/me/lumen-weather.git" → "weather".
pub fn nameFromUrl(out: []u8, url: []const u8) []const u8 {
    var trimmed = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, trimmed, git_suffix)) {
        trimmed = trimmed[0 .. trimmed.len - git_suffix.len];
    }
    if (std.mem.findLastAny(u8, trimmed, "/:")) |i| trimmed = trimmed[i + 1 ..];
    for (repository_prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix) and trimmed.len > prefix.len) {
            trimmed = trimmed[prefix.len..];
            break;
        }
    }
    const with_suffix = std.mem.endsWith(u8, trimmed, repository_suffix);
    if (with_suffix and trimmed.len > repository_suffix.len) {
        trimmed = trimmed[0 .. trimmed.len - repository_suffix.len];
    }
    const length = @min(trimmed.len, out.len);
    for (trimmed[0..length], out[0..length]) |character, *name_character| {
        const lower = std.ascii.toLower(character);
        const kept = std.ascii.isAlphanumeric(lower) or lower == '-' or lower == '_';
        name_character.* = if (kept) lower else '-';
    }
    return out[0..length];
}

/// `fmt` written to `out`, cut to what fits, as valid UTF-8: it goes to the
/// caller over D-Bus, whose strings must be.
fn format(out: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    var writer: std.Io.Writer = .fixed(out[0 .. out.len - 1]);
    // Full: what fits is kept, which is the cut this function promises.
    writer.print(fmt, args) catch {};
    const valid_length = core.utf8.validPrefix(writer.buffered()).len;
    out[valid_length] = 0;
    return out[0..valid_length :0];
}

/// The end of `text` in at most `bytes_max` bytes, from a character on,
/// after "..." when cut: the last lines git prints say why it failed. Formats as two
/// strings: `"{s}{s}"`.
fn tail(text: []const u8, bytes_max: usize) struct { []const u8, []const u8 } {
    assert(bytes_max > 0);
    if (text.len <= bytes_max) return .{ "", text };
    var tail_start = text.len - bytes_max;
    // Past UTF-8 continuation bytes (10xxxxxx), to a character's start.
    while (tail_start < text.len and text[tail_start] & 0xC0 == 0x80) tail_start += 1;
    return .{ "...", text[tail_start..] };
}

/// A failure: to the caller's stderr (exit 1), or on the selected row.
fn fail(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var message_bytes: [failure_bytes_max]u8 = undefined;
    const message = format(&message_bytes, fmt, args);
    const command_line = caller orelse return note(ui, message);
    c.g_application_command_line_printerr(command_line, "lumen: %s\n", message.ptr);
    c.g_application_command_line_set_exit_status(command_line, 1);
}

/// The first line of `message` on the selected row (Settings has no
/// caller), now and again once the extensions have reloaded.
fn note(ui: *Ui, message: []const u8) void {
    const line_end = std.mem.findScalar(u8, message, '\n') orelse message.len;
    const line = std.mem.trim(u8, message[0..line_end], " ");
    ui.after_reload.set(line);
    ui.after_reload_pending = true;
    ui.showFailure(ui.after_reload.slice());
}

pub fn install(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    url: []const u8,
    name_given: ?[]const u8,
) void {
    var name_bytes: [64]u8 = undefined;
    const name = name_given orelse nameFromUrl(&name_bytes, url);
    if (!Host.validId(name)) {
        return fail(
            ui,
            caller,
            "\"{s}\" cannot be an extension name (a-z, 0-9, - and _); pick one with --as NAME",
            .{name},
        );
    }
    if (Host.reservedId(name)) {
        return fail(
            ui,
            caller,
            "\"{s}\" is taken (init.lua and the style run as it); pick another with --as NAME",
            .{name},
        );
    }
    var folder_bytes: [4096]u8 = undefined;
    const folder = extensionFolder(ui, &folder_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    if (os.info(folder) != null) {
        return fail(ui, caller, "{s} already exists: lumen --update {s}, or --as another name", .{
            folder,
            name,
        });
    }
    const parent = folder[0 .. std.mem.findScalarLast(u8, folder, '/') orelse folder.len];
    os.mkdirP(parent) catch |err| {
        return fail(ui, caller, "Could not make {s}: {t}", .{ parent, err });
    };
    var url_buffer: [2048]u8 = undefined;
    const url_z = std.mem.printSentinel(&url_buffer, "{s}", .{url}, 0) catch {
        return fail(ui, caller, "URL too long", .{});
    };
    // "--": a URL starting with "-" is not an option.
    var argv = [_:null]?[*:0]const u8{ "git", "clone", "--depth", "1", "--", url_z.ptr, folder.ptr };
    start(ui, caller, .install, name, folder, &argv);
}

pub fn update(ui: *Ui, caller: ?*c.GApplicationCommandLine, name: ?[]const u8) void {
    var folder_bytes: [4096]u8 = undefined;
    if (name) |extension_name| {
        if (!Host.validId(extension_name)) {
            return fail(ui, caller, "no extension named \"{s}\"", .{extension_name});
        }
        const folder = extensionFolder(ui, &folder_bytes, extension_name) orelse {
            return fail(ui, caller, "path too long", .{});
        };
        if (os.info(folder) == null) {
            return fail(ui, caller, "no extension named \"{s}\"", .{extension_name});
        }
        var argv = [_:null]?[*:0]const u8{ "git", "-C", folder.ptr, "pull", "--ff-only" };
        return start(ui, caller, .update, extension_name, folder, &argv);
    }
    // Every extension that is a git checkout.
    const folder = std.mem.printSentinel(
        &folder_bytes,
        "{s}/extensions",
        .{ui.config_dir},
        0,
    ) catch return fail(ui, caller, "path too long", .{});
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
        "lumen-update", folder.ptr,
    };
    start(ui, caller, .update, "", folder, &argv);
}

pub fn uninstall(ui: *Ui, caller: ?*c.GApplicationCommandLine, name: []const u8) void {
    if (!Host.validId(name)) return fail(ui, caller, "no extension named \"{s}\"", .{name});
    var folder_bytes: [4096]u8 = undefined;
    const folder = extensionFolder(ui, &folder_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    if (os.info(folder) == null) {
        return fail(ui, caller, "no extension named \"{s}\"", .{name});
    }
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", folder.ptr };
    start(ui, caller, .uninstall, name, folder, &argv);
}

fn start(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    kind: Kind,
    name: []const u8,
    folder: []const u8,
    argv: [*:null]?[*:0]const u8,
) void {
    var err: ?*c.GError = null;
    const subprocess = c.g_subprocess_newv(
        argv,
        c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_MERGE,
        &err,
    ) orelse {
        const reason: []const u8 = if (err) |gerror| std.mem.span(gerror.message) else "cannot start";
        fail(ui, caller, "{s}: {s}", .{ std.mem.span(argv[0].?), reason });
        if (err) |gerror| c.g_error_free(gerror);
        return;
    };
    const job = ui.gpa.create(Job) catch {
        c.g_object_unref(subprocess);
        return fail(ui, caller, "out of memory", .{});
    };
    job.* = .{
        .ui = ui,
        .caller = if (caller) |command_line| @ptrCast(c.g_object_ref(command_line)) else null,
        .subprocess = subprocess,
        .kind = kind,
    };
    job.name.set(name);
    // extensionFolder builds it in a buffer of this size: it always fits.
    std.debug.assert(folder.len <= @TypeOf(job.folder).capacity);
    job.folder.set(folder);
    // As bytes: git prints file names and messages in any encoding, and the
    // UTF-8 variant fails on the first byte that is not.
    c.g_subprocess_communicate_async(subprocess, null, null, &onDone, job);
}

/// What the job printed, as UTF-8 (U+FFFD for what is not, NUL included):
/// it goes to the caller over D-Bus and onto a row. Free with g_free.
fn outputText(bytes: ?*c.GBytes) [:0]u8 {
    var length: usize = 0;
    const received = if (bytes) |output| c.g_bytes_get_data(output, &length) else null;
    const data: [*]const u8 = received orelse "";
    return std.mem.span(c.g_utf8_make_valid(data, @intCast(length)));
}

/// What git says last on a failure, in bytes: the message has to fit 1 KB.
const failure_output_bytes_max = 800;

fn onDone(_: ?*c.GObject, async_result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    const ui = job.ui;
    const caller = job.caller;
    defer {
        c.g_object_unref(job.subprocess);
        // The caller's `lumen --install` returns once this is released.
        if (caller) |command_line| c.g_object_unref(command_line);
        ui.gpa.destroy(job);
    }
    var out: ?*c.GBytes = null;
    var err: ?*c.GError = null;
    const finished = c.g_subprocess_communicate_finish(
        job.subprocess,
        async_result,
        &out,
        null,
        &err,
    );
    const ran = finished != 0;
    defer if (err) |gerror| c.g_error_free(gerror);
    defer if (out) |output_bytes| c.g_bytes_unref(output_bytes);
    const output = outputText(out);
    defer c.g_free(output.ptr);
    // Failed or not, the files may have changed (half a pull, a clone
    // removed again): the extensions load again, after the message.
    defer ext_view.reload(ui);
    const succeeded = ran and err == null and c.g_subprocess_get_successful(job.subprocess) != 0;
    if (!succeeded) {
        // A failed clone can leave half a folder behind, and the next
        // install would find it there.
        if (job.kind == .install) removeTree(job.folderPath());
        const why = if (err) |gerror|
            std.mem.span(gerror.message)
        else
            std.mem.trim(u8, output, " \n");
        const end = tail(why, failure_output_bytes_max);
        return fail(ui, caller, "{s} failed:\n{s}{s}", .{ @tagName(job.kind), end[0], end[1] });
    }
    reportSuccess(job, output);
}

/// The outcome of a job that succeeded: to the caller, or on the selected
/// row.
fn reportSuccess(job: *Job, output: [:0]const u8) void {
    const ui = job.ui;
    const caller = job.caller;
    switch (job.kind) {
        .install => {
            var init_path_bytes: [4200]u8 = undefined;
            const init_path = std.mem.printSentinel(
                &init_path_bytes,
                "{s}/init.lua",
                .{job.folderPath()},
                0,
            ) catch "";
            if (os.info(init_path) == null) {
                removeTree(job.folderPath());
                return fail(
                    ui,
                    caller,
                    "{s} has no init.lua: it is not a Lumen extension",
                    .{job.nameSlice()},
                );
            }
            print(
                ui,
                caller,
                "Installed {s} in {s}\nExtensions run as you: read its init.lua to know what it does.\n",
                .{ job.nameSlice(), job.folderPath() },
            );
        },
        .update => if (caller != null) {
            const end = tail(if (output.len > 0) output else "Up to date\n", print_bytes_max - 8);
            print(ui, caller, "{s}{s}", .{ end[0], end[1] });
        } else {
            // git's own lines are too long for a row: a summary.
            const none = output.len == 0 or std.mem.find(u8, output, "Already up to date") != null;
            note(ui, if (none) "Already up to date" else "Updated");
        },
        .uninstall => print(ui, caller, "Removed {s}\n", .{job.nameSlice()}),
    }
    if (caller) |command_line| c.g_application_command_line_set_exit_status(command_line, 0);
    // From Settings: the removed extension's page has nothing left to show.
    if (caller == null and job.kind == .uninstall and ui.view == .prefs) ui.goBack();
}

/// What an install, update or removal prints: the success line and git's
/// output, or the failure and its reason.
const print_bytes_max = 8192;
const failure_bytes_max = 1024;

/// Success: to the caller's stdout, or on the selected row.
fn print(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var message_bytes: [print_bytes_max]u8 = undefined;
    const message = format(&message_bytes, fmt, args);
    const command_line = caller orelse return note(ui, message);
    c.g_application_command_line_print(command_line, "%s", message.ptr);
}

/// rm -rf, waited for (a fresh clone: small and local).
fn removeTree(folder: [:0]const u8) void {
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", folder.ptr };
    var err: ?*c.GError = null;
    const spawned = c.g_spawn_sync(
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
    );
    if (spawned == 0) proc.warnError(.install, err, "rm {s}", .{folder});
}

test "long output keeps its end, and messages stay valid UTF-8" {
    const short = tail("fatal: no such repo", 100);
    try std.testing.expectEqualStrings("", short[0]);
    try std.testing.expectEqualStrings("fatal: no such repo", short[1]);
    // Cut before "é" would split it: from the next character on.
    const cut = tail("aaaaé fatal", 7);
    try std.testing.expectEqualStrings("...", cut[0]);
    try std.testing.expectEqualStrings(" fatal", cut[1]);
    var message_bytes: [8]u8 = undefined;
    // Too long: what fits, never half a character.
    try std.testing.expectEqualStrings("abcdé", format(&message_bytes, "{s}", .{"abcdéé"}));
    try std.testing.expectEqualStrings("ok", format(&message_bytes, "{s}", .{"ok"}));
}

test "extension names come from the repository" {
    var name_bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("weather", nameFromUrl(
        &name_bytes,
        "https://github.com/me/lumen-weather.git",
    ));
    try std.testing.expectEqualStrings("github", nameFromUrl(
        &name_bytes,
        "git@github.com:me/lumen-ext-github",
    ));
    try std.testing.expectEqualStrings("todo", nameFromUrl(
        &name_bytes,
        "https://codeberg.org/x/todo-lumen/",
    ));
    try std.testing.expectEqualStrings("my-tool", nameFromUrl(&name_bytes, "/home/me/src/My.Tool"));
    try std.testing.expectEqualStrings("lumen", nameFromUrl(&name_bytes, "https://github.com/x/lumen"));
}
