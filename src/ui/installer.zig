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

/// A folder's path, as Job keeps it: whole, never cut.
const path_bytes_max = std.Io.Dir.max_path_bytes;
/// The longest URL `--install` takes.
const url_bytes_max = 2048;
/// What makes a clone an extension.
const init_lua = "/init.lua";

/// How much of a job's output is kept: its end, more than any message
/// shows (`print_bytes_max`).
const output_kept_bytes = 16 << 10;
/// What one read of that output takes.
const output_chunk_bytes = 4096;

comptime {
    assert(output_kept_bytes >= print_bytes_max);
}

const Job = struct {
    ui: *Ui,
    /// The caller's command line; null when started from Settings.
    caller: ?*c.GApplicationCommandLine,
    subprocess: *c.GSubprocess,
    kind: Kind,
    name: core.FixedStr(extension_name_bytes_max) = .{},
    /// The folder the job is about: the extension's (or extensions/, for
    /// the update of every one). Marked busy (`busy`) while the job runs.
    folder: core.FixedStr(std.Io.Dir.max_path_bytes) = .{},
    /// The folder the command writes, and what removeTreeThenReload deletes
    /// on failure: whole, never cut (see `start`). An install clones into a
    /// folder of its own (`installingFolder`), renamed into place once it
    /// is an extension: a failure never deletes a folder another job made.
    work: core.FixedStr(std.Io.Dir.max_path_bytes) = .{},
    /// Cancels the read of the output when `timer` fires.
    cancellable: *c.GCancellable,
    /// `job_timeout_s` from the start; 0 once fired or removed.
    timer: c_uint = 0,
    timed_out: bool = false,
    /// The end of what the job printed: only its last lines are ever shown,
    /// and git's output is not bounded (a clone with progress, a pull
    /// over many extensions).
    output: [output_kept_bytes]u8 = undefined,
    output_len: usize = 0,
    /// Where the next read lands.
    chunk: [output_chunk_bytes]u8 = undefined,

    /// Keeps `bytes` after what is kept, dropping the oldest to stay
    /// within `output_kept_bytes`.
    fn keepOutput(job: *Job, bytes: []const u8) void {
        if (bytes.len >= job.output.len) {
            @memcpy(&job.output, bytes[bytes.len - job.output.len ..]);
            job.output_len = job.output.len;
            return;
        }
        const room = job.output.len - job.output_len;
        if (bytes.len > room) {
            const dropped = bytes.len - room;
            std.mem.copyForwards(
                u8,
                job.output[0 .. job.output_len - dropped],
                job.output[dropped..job.output_len],
            );
            job.output_len -= dropped;
        }
        @memcpy(job.output[job.output_len..][0..bytes.len], bytes);
        job.output_len += bytes.len;
        assert(job.output_len <= job.output.len);
    }

    fn nameSlice(job: *const Job) []const u8 {
        return job.name.slice();
    }

    fn folderPath(job: *Job) [:0]const u8 {
        return job.folder.slice();
    }

    fn workPath(job: *Job) [:0]const u8 {
        return job.work.slice();
    }
};

/// How long a job may run: git asking nothing (see `start`) still waited on
/// a remote that stopped answering, and the caller's `lumen --install`
/// with it.
const job_timeout_s = 600;

/// Folders a job is working on (`Job.folder`), in `std.heap.c_allocator`.
/// Main thread only. Two installs of one name at once had the second's
/// failure delete the first's clone.
var busy: std.ArrayList([]u8) = .empty;

/// Whether a job works on `folder`, on a folder in it, or on one it is in
/// (the update of every extension against any other job).
fn busyWith(folder: []const u8) bool {
    for (busy.items) |held| {
        if (os.isAtOrBelow(held, folder) or os.isAtOrBelow(folder, held)) return true;
    }
    return false;
}

fn markBusy(folder: []const u8) std.mem.Allocator.Error!void {
    const gpa = std.heap.c_allocator;
    const owned = try gpa.dupe(u8, folder);
    errdefer gpa.free(owned);
    try busy.append(gpa, owned);
}

fn unmarkBusy(folder: []const u8) void {
    for (busy.items, 0..) |held, i| {
        if (!std.mem.eql(u8, held, folder)) continue;
        std.heap.c_allocator.free(busy.swapRemove(i));
        return;
    }
}

/// Where an install of `name` clones before it is an extension: beside
/// extensions/ (on the same file system, so the rename is atomic), outside
/// it (a reload in between does not load half a clone).
fn installingFolder(ui: *Ui, out: []u8, name: []const u8) ?[:0]const u8 {
    return std.mem.printSentinel(
        out,
        "{s}/.installing-{s}",
        .{ ui.config_dir, name },
        0,
    ) catch null;
}

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
    var name_bytes: [extension_name_bytes_max]u8 = undefined;
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
    var folder_bytes: [path_bytes_max]u8 = undefined;
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
    var url_buffer: [url_bytes_max]u8 = undefined;
    const url_z = std.mem.printSentinel(&url_buffer, "{s}", .{url}, 0) catch {
        return fail(ui, caller, "URL too long", .{});
    };
    var installing_bytes: [path_bytes_max]u8 = undefined;
    const installing = installingFolder(ui, &installing_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    if (!busyWith(folder) and os.info(installing) != null) {
        const left = "{s} is left from an install that stopped: remove it, then install again";
        return fail(ui, caller, left, .{installing});
    }
    // "--": a URL starting with "-" is not an option.
    var argv = [_:null]?[*:0]const u8{
        "git", "clone", "--depth", "1", "--", url_z.ptr, installing.ptr,
    };
    start(ui, caller, .install, name, folder, installing, &argv);
}

pub fn update(ui: *Ui, caller: ?*c.GApplicationCommandLine, name: ?[]const u8) void {
    var folder_bytes: [path_bytes_max]u8 = undefined;
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
        return start(ui, caller, .update, extension_name, folder, folder, &argv);
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
        \\  before=$(git -C "$d" rev-parse HEAD 2>/dev/null)
        \\  if git -C "$d" pull --ff-only --quiet; then
        \\    if [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$before" ]; then
        \\      echo up to date
        \\    else
        \\      echo updated
        \\    fi
        \\  else
        \\    status=1
        \\  fi
        \\done
        \\exit $status
        ,
        "lumen-update", folder.ptr,
    };
    start(ui, caller, .update, "", folder, folder, &argv);
}

pub fn uninstall(ui: *Ui, caller: ?*c.GApplicationCommandLine, name: []const u8) void {
    if (!Host.validId(name)) return fail(ui, caller, "no extension named \"{s}\"", .{name});
    var folder_bytes: [path_bytes_max]u8 = undefined;
    const folder = extensionFolder(ui, &folder_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    if (os.info(folder) == null) {
        return fail(ui, caller, "no extension named \"{s}\"", .{name});
    }
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", folder.ptr };
    start(ui, caller, .uninstall, name, folder, folder, &argv);
}

fn start(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    kind: Kind,
    name: []const u8,
    folder: []const u8,
    work: []const u8,
    argv: [*:null]?[*:0]const u8,
) void {
    if (busyWith(folder)) {
        return fail(ui, caller, "{s}: another install, update or removal is running on it", .{folder});
    }
    markBusy(folder) catch return fail(ui, caller, "out of memory", .{});
    const flags = c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_MERGE;
    const launcher = c.g_subprocess_launcher_new(flags);
    defer c.g_object_unref(launcher);
    // Nobody can answer a prompt: git asked for credentials or a host key
    // on the terminal the daemon was started from, and waited for ever.
    c.g_subprocess_launcher_setenv(launcher, "GIT_TERMINAL_PROMPT", "0", 1);
    c.g_subprocess_launcher_setenv(launcher, "GIT_SSH_COMMAND", "ssh -oBatchMode=yes", 1);
    var err: ?*c.GError = null;
    const subprocess = c.g_subprocess_launcher_spawnv(launcher, argv, &err) orelse {
        unmarkBusy(folder);
        const reason = if (err) |gerror| std.mem.span(gerror.message) else "cannot start";
        fail(ui, caller, "{s}: {s}", .{ std.mem.span(argv[0].?), reason });
        if (err) |gerror| c.g_error_free(gerror);
        return;
    };
    const job = ui.gpa.create(Job) catch {
        unmarkBusy(folder);
        c.g_subprocess_force_exit(subprocess);
        c.g_object_unref(subprocess);
        return fail(ui, caller, "out of memory", .{});
    };
    job.* = .{
        .ui = ui,
        .caller = if (caller) |command_line| @ptrCast(c.g_object_ref(command_line)) else null,
        .subprocess = subprocess,
        .kind = kind,
        .cancellable = c.g_cancellable_new(),
    };
    job.name.set(name);
    // extensionFolder builds them in buffers of this size: they always fit.
    std.debug.assert(folder.len <= @TypeOf(job.folder).capacity);
    std.debug.assert(work.len <= @TypeOf(job.work).capacity);
    job.folder.set(folder);
    job.work.set(work);
    job.timer = c.g_timeout_add_seconds(job_timeout_s, &onTimeout, job);
    // Read as bytes, chunk by chunk, keeping only the end: git prints file
    // names and messages in any encoding, and how much it prints has no
    // bound (communicate kept all of it).
    readOutput(job);
}

fn readOutput(job: *Job) void {
    const stdout = c.g_subprocess_get_stdout_pipe(job.subprocess);
    c.g_input_stream_read_async(
        stdout,
        &job.chunk,
        job.chunk.len,
        c.G_PRIORITY_DEFAULT,
        job.cancellable,
        &onOutput,
        job,
    );
}

/// Past `job_timeout_s`: the command is killed and the read of its output
/// given up (a child of git's may hold the pipe open), so the job ends.
fn onTimeout(data: ?*anyopaque) callconv(.c) c.gboolean {
    const job: *Job = @ptrCast(@alignCast(data.?));
    job.timer = 0;
    job.timed_out = true;
    c.g_subprocess_force_exit(job.subprocess);
    c.g_cancellable_cancel(job.cancellable);
    return 0;
}

fn onOutput(_: ?*c.GObject, async_result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    var err: ?*c.GError = null;
    const stdout = c.g_subprocess_get_stdout_pipe(job.subprocess);
    const bytes_read = c.g_input_stream_read_finish(stdout, async_result, &err);
    if (bytes_read > 0) {
        job.keepOutput(job.chunk[0..@intCast(bytes_read)]);
        return readOutput(job);
    }
    // The end of the output, or a read that failed: the exit decides. A
    // failed read closes the pipe, or a program still writing would block
    // on it and never exit.
    if (err != null) _ = c.g_input_stream_close(stdout, null, null);
    proc.warnError(.install, err, "reading {s}'s output", .{@tagName(job.kind)});
    c.g_subprocess_wait_async(job.subprocess, null, &onDone, job);
}

/// What the job printed, as UTF-8 (U+FFFD for what is not, NUL included):
/// it goes to the caller over D-Bus and onto a row. Free with g_free.
fn outputText(job: *const Job) [:0]u8 {
    return std.mem.span(c.g_utf8_make_valid(&job.output, @intCast(job.output_len)));
}

/// What git says last on a failure, in bytes: the message has to fit 1 KB.
const failure_output_bytes_max = 800;

fn onDone(_: ?*c.GObject, async_result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    const ui = job.ui;
    const caller = job.caller;
    // Unless the removal of a failed clone has it now (`removeTreeThenReload`).
    var busy_handed_over = false;
    defer {
        if (job.timer != 0) _ = c.g_source_remove(job.timer);
        c.g_object_unref(job.cancellable);
        if (!busy_handed_over) unmarkBusy(job.folderPath());
        c.g_object_unref(job.subprocess);
        // The caller's `lumen --install` returns once this is released.
        if (caller) |command_line| c.g_object_unref(command_line);
        ui.gpa.destroy(job);
    }
    var err: ?*c.GError = null;
    const ran = c.g_subprocess_wait_finish(job.subprocess, async_result, &err) != 0;
    defer if (err) |gerror| c.g_error_free(gerror);
    const output = outputText(job);
    defer c.g_free(output.ptr);
    const succeeded = !job.timed_out and ran and err == null and
        c.g_subprocess_get_successful(job.subprocess) != 0;
    if (!succeeded) {
        // A failed clone can leave half a folder behind, and the next
        // install would find it there. The extensions reload once it is
        // gone; otherwise now: half a pull changed files too.
        if (job.kind == .install) {
            removeTreeThenReload(ui, job.workPath(), job.folderPath());
            busy_handed_over = true;
        } else {
            ext_view.reload(ui);
        }
        if (job.timed_out) {
            const stopped = "{s} stopped: no end after {d} s";
            return fail(ui, caller, stopped, .{ @tagName(job.kind), job_timeout_s });
        }
        const why = if (err) |gerror|
            std.mem.span(gerror.message)
        else
            std.mem.trim(u8, output, " \n");
        const end = tail(why, failure_output_bytes_max);
        return fail(ui, caller, "{s} failed:\n{s}{s}", .{ @tagName(job.kind), end[0], end[1] });
    }
    busy_handed_over = reportSuccess(job, output);
}

/// The outcome of a job that succeeded: to the caller, or on the selected
/// row. True when it handed the job's folder over to a removal
/// (`removeTreeThenReload`), which marks it free once done.
fn reportSuccess(job: *Job, output: [:0]const u8) bool {
    const ui = job.ui;
    const caller = job.caller;
    switch (job.kind) {
        .install => {
            var init_path_bytes: [path_bytes_max + init_lua.len]u8 = undefined;
            const init_path = std.mem.printSentinel(
                &init_path_bytes,
                "{s}" ++ init_lua,
                .{job.workPath()},
                0,
            ) catch {
                // Not known to be missing: the clone stays where it is.
                fail(ui, caller, "{s}: path too long to check its init.lua", .{job.workPath()});
                return false;
            };
            if (os.info(init_path) == null) {
                removeTreeThenReload(ui, job.workPath(), job.folderPath());
                fail(ui, caller, "{s} has no init.lua: it is not a Lumen extension", .{job.nameSlice()});
                return true;
            }
            // Into place, whole: until now nothing loaded it.
            os.rename(job.workPath(), job.folderPath()) catch |err| {
                removeTreeThenReload(ui, job.workPath(), job.folderPath());
                fail(
                    ui,
                    caller,
                    "could not move the clone to {s}: {t}",
                    .{ job.folderPath(), err },
                );
                return true;
            };
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
            // git's own lines are too long for a row: a summary shows instead.
            note(
                ui,
                if (anyUpdated(
                    job.nameSlice().len == 0,
                    output,
                )) "Updated" else "Already up to date",
            );
        },
        .uninstall => print(ui, caller, "Removed {s}\n", .{job.nameSlice()}),
    }
    ext_view.reload(ui);
    if (caller) |command_line| c.g_application_command_line_set_exit_status(command_line, 0);
    // From Settings: the removed extension's page, if it is still the one
    // shown, has nothing left to show.
    const on_its_page = ui.view == .prefs and std.mem.eql(
        u8,
        ui.prefs_ext.slice(),
        job.nameSlice(),
    );
    if (caller == null and job.kind == .uninstall and on_its_page) ui.goBack();
    return false;
}

/// Whether an update changed anything: a line "NAME: updated" from the
/// update of every extension (`all`), or git's own output for one.
fn anyUpdated(all: bool, output: []const u8) bool {
    if (all) return std.mem.find(u8, output, ": updated\n") != null;
    return output.len > 0 and std.mem.find(u8, output, "Already up to date") == null;
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

/// Removes `folder` like rm -rf without waiting for it (the GTK thread
/// must not: a large tree takes seconds), then reloads the extensions and
/// marks `busy_folder` free (it stays busy meanwhile: a new install of the
/// same name would clone where this removal deletes).
fn removeTreeThenReload(ui: *Ui, folder: [:0]const u8, busy_folder: []const u8) void {
    const removal = std.heap.c_allocator.create(Removal) catch {
        unmarkBusy(busy_folder);
        return ext_view.reload(ui);
    };
    removal.* = .{ .ui = ui };
    removal.busy_folder.set(busy_folder);
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", folder.ptr };
    var err: ?*c.GError = null;
    const subprocess = c.g_subprocess_newv(
        @ptrCast(&argv),
        c.G_SUBPROCESS_FLAGS_NONE,
        &err,
    ) orelse {
        proc.warnError(.install, err, "rm {s}", .{folder});
        return removal.finish();
    };
    c.g_subprocess_wait_check_async(subprocess, null, &onRemoved, removal);
}

const Removal = struct {
    ui: *Ui,
    busy_folder: core.FixedStr(std.Io.Dir.max_path_bytes) = .{},

    fn finish(removal: *Removal) void {
        unmarkBusy(removal.busy_folder.slice());
        ext_view.reload(removal.ui);
        std.heap.c_allocator.destroy(removal);
    }
};

fn onRemoved(
    source: ?*c.GObject,
    async_result: *c.GAsyncResult,
    data: ?*anyopaque,
) callconv(.c) void {
    const removal: *Removal = @ptrCast(@alignCast(data.?));
    const subprocess: *c.GSubprocess = @ptrCast(source.?);
    defer c.g_object_unref(subprocess);
    var err: ?*c.GError = null;
    if (c.g_subprocess_wait_check_finish(subprocess, async_result, &err) == 0) {
        proc.warnError(.install, err, "rm", .{});
    }
    removal.finish();
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
    var name_bytes: [extension_name_bytes_max]u8 = undefined;
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
    try std.testing.expectEqualStrings("lumen", nameFromUrl(
        &name_bytes,
        "https://github.com/x/lumen",
    ));
}

test "a job keeps the end of its output, whatever its length" {
    const job = try std.testing.allocator.create(Job);
    defer std.testing.allocator.destroy(job);
    job.output_len = 0;
    job.keepOutput("hello ");
    job.keepOutput("world");
    try std.testing.expectEqualStrings("hello world", job.output[0..job.output_len]);
    // Past the cap: the oldest bytes go, the newest stay.
    const long = try std.testing.allocator.alloc(u8, output_kept_bytes - 3);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    job.keepOutput(long);
    try std.testing.expectEqual(@as(usize, output_kept_bytes), job.output_len);
    // 11 + (cap - 3) bytes: the first 8 went, "rld" leads.
    try std.testing.expectEqualStrings("rldxx", job.output[0..5]);
    const huge = try std.testing.allocator.alloc(u8, output_kept_bytes * 2);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'y');
    huge[huge.len - 1] = 'z';
    job.keepOutput(huge);
    try std.testing.expectEqual(@as(usize, output_kept_bytes), job.output_len);
    try std.testing.expectEqual(@as(u8, 'z'), job.output[output_kept_bytes - 1]);
}

test "an update says Updated only when something changed" {
    try std.testing.expect(!anyUpdated(true, "a: up to date\nb: up to date\n"));
    try std.testing.expect(anyUpdated(true, "a: up to date\nb: updated\n"));
    try std.testing.expect(!anyUpdated(false, ""));
    try std.testing.expect(!anyUpdated(false, "Already up to date.\n"));
    try std.testing.expect(anyUpdated(false, "Updating 1a2b..3c4d\nFast-forward\n"));
}

test "busy folders: one job per folder, and the update of all against any" {
    defer {
        for (busy.items) |held| std.heap.c_allocator.free(held);
        busy.clearAndFree(std.heap.c_allocator);
    }
    try markBusy("/c/extensions/weather");
    try std.testing.expect(busyWith("/c/extensions/weather"));
    try std.testing.expect(busyWith("/c/extensions"));
    try std.testing.expect(!busyWith("/c/extensions/clock"));
    unmarkBusy("/c/extensions/weather");
    try std.testing.expect(!busyWith("/c/extensions"));
}
