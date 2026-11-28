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
    /// Cancels `g_subprocess_wait_async` only on daemon shutdown, never on
    /// timeout, so `onDone` waits for the killed process to exit before `rm -rf`.
    wait_cancellable: *c.GCancellable,
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
var active_jobs: std.ArrayList(*Job) = .empty;
var active_removals: std.ArrayList(*Removal) = .empty;
var shutting_down = false;

/// Stops all active installer subprocesses, timers, and removals on shutdown
/// and frees installer tracking state. Main thread.
pub fn shutdown() void {
    os.assertMainThread();
    shutting_down = true;
    for (active_jobs.items) |job| {
        if (job.timer != 0) {
            _ = c.g_source_remove(job.timer);
            job.timer = 0;
        }
        c.g_cancellable_cancel(job.cancellable);
        c.g_cancellable_cancel(job.wait_cancellable);
        killJobGroup(job.subprocess);
        if (job.caller) |command_line| {
            c.g_application_command_line_set_exit_status(command_line, 1);
            c.g_object_unref(command_line);
            job.caller = null;
        }
    }
    for (active_removals.items) |removal| {
        c.g_cancellable_cancel(removal.cancellable);
        if (removal.subprocess) |sub| killJobGroup(sub);
    }
    for (busy.items) |held| std.heap.c_allocator.free(held);
    busy.deinit(std.heap.c_allocator);
    busy = .empty;
    active_jobs.deinit(std.heap.c_allocator);
    active_jobs = .empty;
    active_removals.deinit(std.heap.c_allocator);
    active_removals = .empty;
}

fn untrackJob(job: *Job) void {
    for (active_jobs.items, 0..) |tracked, i| {
        if (tracked == job) {
            _ = active_jobs.swapRemove(i);
            return;
        }
    }
}

fn untrackRemoval(removal: *Removal) void {
    for (active_removals.items, 0..) |tracked, i| {
        if (tracked == removal) {
            _ = active_removals.swapRemove(i);
            return;
        }
    }
}

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

/// Where extension `name` keeps its storage and preferences (passwords
/// among them), written to `out`: `Extension.data`.
fn extensionDataFolder(ui: *Ui, out: []u8, name: []const u8) ?[:0]const u8 {
    if (ui.ext_host) |host| {
        return std.mem.printSentinel(out, "{s}/extensions/{s}", .{ host.data_dir, name }, 0) catch null;
    }
    // As `ext_view.start` gives the host.
    const data_home = std.mem.span(c.g_get_user_data_dir());
    return std.mem.printSentinel(out, "{s}/lumen/extensions/{s}", .{ data_home, name }, 0) catch null;
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
/// caller over D-Bus, whose strings must be. A byte that is not UTF-8 (in
/// a path) shows as U+FFFD; it cut the message there (MYP-533).
fn format(out: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    assert(out.len <= print_bytes_max);
    var raw: [print_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(raw[0 .. out.len - 1]);
    // Full: what fits is kept, which is the cut this function promises.
    writer.print(fmt, args) catch {};
    const shown = core.utf8.sanitizeCut(out[0 .. out.len - 1], writer.buffered());
    out[shown.len] = 0;
    return out[0..shown.len :0];
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
    failImpl(ui, caller, false, fmt, args);
}

/// Like `fail`, keeping the message across a reload that is already in flight.
fn failAndReload(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    comptime fmt: []const u8,
    args: anytype,
) void {
    failImpl(ui, caller, true, fmt, args);
}

fn failImpl(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    pending_reload: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var message_bytes: [failure_bytes_max]u8 = undefined;
    const message = format(&message_bytes, fmt, args);
    const command_line = caller orelse return note(ui, message, pending_reload);
    c.g_application_command_line_printerr(command_line, "lumen: %s\n", message.ptr);
    c.g_application_command_line_set_exit_status(command_line, 1);
}

/// Returns the last non-empty trimmed line of `message` so multi-line git
/// failure notices surface the actual error instead of the header prefix.
fn lastUsefulLine(message: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, message, '\n');
    while (it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return std.mem.trim(u8, message, " \t\r");
}

/// Shows `message` on the selected row (Settings has no caller); keeps it in
/// `ui.after_reload` only when `pending_reload` is true.
fn note(ui: *Ui, message: []const u8, pending_reload: bool) void {
    const line = lastUsefulLine(message);
    ui.after_reload.set(line);
    ui.after_reload_pending = pending_reload;
    ui.showFailure(ui.after_reload.slice());
}

fn validInstallName(name: []const u8) bool {
    if (!Host.validId(name)) return false;
    if (name[0] == '-') return false;
    for (name) |ch| {
        if (std.ascii.isAlphanumeric(ch)) return true;
    }
    return false;
}

fn isRelativeLocalPath(url: []const u8) bool {
    if (url.len == 0 or url[0] == '/' or url[0] == '~') return false;
    if (std.mem.find(u8, url, "://") != null) return false;
    const colon = std.mem.findScalar(u8, url, ':');
    const slash = std.mem.findScalar(u8, url, '/');
    if (colon) |c_pos| {
        if (slash == null or c_pos < slash.?) return false;
    }
    return true;
}

fn resolveLocalUrl(out: *[url_bytes_max]u8, url: []const u8, cwd: ?[]const u8) ?[]const u8 {
    if (!isRelativeLocalPath(url)) return url;
    const base = cwd orelse return url;
    if (base.len == 0) return url;
    const clean_rel = if (std.mem.eql(u8, url, "."))
        ""
    else if (std.mem.startsWith(u8, url, "./"))
        url[2..]
    else
        url;
    if (clean_rel.len == 0) return std.fmt.bufPrint(out, "{s}", .{base}) catch null;
    const clean_base = std.mem.trimEnd(u8, base, "/");
    return std.fmt.bufPrint(out, "{s}/{s}", .{ clean_base, clean_rel }) catch null;
}

pub fn install(
    ui: *Ui,
    caller: ?*c.GApplicationCommandLine,
    url: []const u8,
    name_given: ?[]const u8,
) void {
    var resolved_buf: [url_bytes_max]u8 = undefined;
    const cwd: ?[]const u8 = if (caller) |command_line|
        (if (c.g_application_command_line_get_cwd(command_line)) |ptr| std.mem.span(ptr) else null)
    else
        null;
    const effective_url = resolveLocalUrl(&resolved_buf, url, cwd) orelse {
        return fail(ui, caller, "URL too long", .{});
    };
    var name_bytes: [extension_name_bytes_max]u8 = undefined;
    const name = name_given orelse nameFromUrl(&name_bytes, effective_url);
    if (!validInstallName(name)) {
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
    // Not followed: a dangling link there is taken too, and the rename at
    // the end of the clone would fail on it.
    if (os.existsAtNoFollow(std.os.linux.AT.FDCWD, folder)) {
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
    const url_z = std.mem.printSentinel(&url_buffer, "{s}", .{effective_url}, 0) catch {
        return fail(ui, caller, "URL too long", .{});
    };
    var installing_bytes: [path_bytes_max]u8 = undefined;
    const installing = installingFolder(ui, &installing_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    if (!busyWith(folder) and os.existsAtNoFollow(std.os.linux.AT.FDCWD, installing)) {
        const left = "{s} is left from an install that stopped: remove it, then install again";
        return fail(ui, caller, left, .{installing});
    }
    // An extension of this name was there once (removed by hand, or by a
    // version that kept its data): its preferences, passwords included,
    // would go to this one.
    var data_bytes: [path_bytes_max]u8 = undefined;
    const data = extensionDataFolder(ui, &data_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    if (os.existsAtNoFollow(std.os.linux.AT.FDCWD, data)) {
        const left = "{s} holds the data of an earlier extension named {s}: " ++
            "remove it, or install with --as another name";
        return fail(ui, caller, left, .{ data, name });
    }
    var clone_buf: [20]?[*:0]const u8 = undefined;
    const allow_file = Ui.testMode() or isLocalUrl(effective_url);
    const argv = gitCloneArgv(&clone_buf, url_z.ptr, installing.ptr, allow_file);
    start(ui, caller, .install, name, folder, installing, argv);
}

/// A repository on this machine, as `--install` was given it (a path, made
/// absolute by `resolveLocalUrl`, or a file:// URL): cloned with git's
/// file transport, which `protocol.allow=never` blocked, so that every
/// local install failed outside the tests (MYP-528). Anything else keeps
/// to https and ssh.
fn isLocalUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "/") or std.mem.startsWith(u8, url, "file://");
}

fn gitCloneArgv(
    out: *[20]?[*:0]const u8,
    url: [*:0]const u8,
    dest: [*:0]const u8,
    allow_file: bool,
) [*:null]?[*:0]const u8 {
    var i: usize = 0;
    const base = [_][*:0]const u8{
        "git",
        "-c",
        "protocol.allow=never",
        "-c",
        "protocol.https.allow=always",
        "-c",
        "protocol.ssh.allow=always",
    };
    for (base) |arg| {
        out[i] = arg;
        i += 1;
    }
    if (allow_file) {
        out[i] = "-c";
        out[i + 1] = "protocol.file.allow=always";
        i += 2;
    }
    const tail_args = [_][*:0]const u8{
        "clone",
        "--depth",
        "1",
        "--no-recurse-submodules",
        "--",
        url,
        dest,
    };
    for (tail_args) |arg| {
        out[i] = arg;
        i += 1;
    }
    out[i] = null;
    return @ptrCast(out.ptr);
}

/// Single-extension update script: refuses to walk up into a parent git
/// repository when the extension folder itself is not a git worktree root.
const update_one_script =
    \\unset CDPATH
    \\top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || { printf '%s is not a git repository\n' "$2"; exit 1; }
    \\dir=$(cd -- "$1" && pwd -P) || exit 1
    \\if [ "$top" != "$dir" ]; then
    \\  printf '%s is not a git repository\n' "$2"
    \\  exit 1
    \\fi
    \\file_allow=${3:-never}
    \\case $(git -C "$1" ls-remote --get-url 2>/dev/null) in
    \\/*|file://*) file_allow=always ;;
    \\esac
    \\before=$(git -C "$1" rev-parse HEAD 2>/dev/null || true)
    \\git -C "$1" -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always -c "protocol.file.allow=$file_allow" -c submodule.recurse=false pull --ff-only || exit 1
    \\after=$(git -C "$1" rev-parse HEAD 2>/dev/null || true)
    \\if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    \\  echo "lumen: updated"
    \\  git -C "$1" log --oneline --no-decorate -n 20 "$before..$after" 2>/dev/null || true
    \\else
    \\  echo "lumen: up to date"
    \\fi
;

/// A regular file at `path` itself: not a link (one in a clone can point
/// anywhere outside it), a folder or a FIFO.
fn isPlainFile(path: [*:0]const u8) bool {
    return os.kindOf(path) != os.Kind.symlink and os.isRegular(path);
}

fn hasGitMarker(folder: []const u8) bool {
    var marker_buffer: [path_bytes_max + "/.git".len]u8 = undefined;
    const marker = std.mem.printSentinel(&marker_buffer, "{s}/.git", .{folder}, 0) catch return false;
    return os.info(marker) != null;
}

/// The commit checked out in `folder`, for lumen.lock: read from its files
/// (`gitHeadSha`), else asked of git. A reftable repository (git 3's
/// default) keeps its refs where those files are not, and nothing was
/// recorded (MYP-529). git runs on the GTK thread, but only after an
/// install or update, locally, and for `rev_parse_timeout_ns` at most.
fn headSha(gpa: std.mem.Allocator, io: std.Io, folder: []const u8, out: *[64]u8) ?[]const u8 {
    if (gitHeadSha(folder, out)) |sha| return sha;
    return revParseHead(gpa, io, folder, out) orelse {
        log.warn("{s}: no commit checked out found: lumen.lock does not record it", .{folder});
        return null;
    };
}

const rev_parse_timeout_ns = 2 * std.time.ns_per_s;

/// `git rev-parse HEAD` in `folder`, into `out`.
fn revParseHead(gpa: std.mem.Allocator, io: std.Io, folder: []const u8, out: *[64]u8) ?[]const u8 {
    const argv = [_][]const u8{ "git", "-C", folder, "rev-parse", "--verify", "--quiet", "HEAD" };
    var result = os.child.run(gpa, io, &argv, .{
        .deadline_ns = os.monotonicNs() + rev_parse_timeout_ns,
        .stderr = .ignore,
        .output_bytes_max = 4096,
    }) catch return null;
    defer result.deinit(gpa);
    if (result.code != 0) return null;
    const sha = std.mem.trim(u8, result.stdout, "\r\n ");
    if (sha.len < 40 or sha.len > out.len) return null;
    for (sha) |character| if (!std.ascii.isHex(character)) return null;
    @memcpy(out[0..sha.len], sha);
    return out[0..sha.len];
}

/// Reads the commit SHA pointed to by HEAD in git repository/worktree `folder`.
fn gitHeadSha(folder: []const u8, out: *[64]u8) ?[]const u8 {
    var path_buf: [path_bytes_max + 64]u8 = undefined;
    var dotgit_buf: [path_bytes_max + 16]u8 = undefined;
    var gitdir_buf: [path_bytes_max]u8 = undefined;
    var common_buf: [path_bytes_max]u8 = undefined;
    const dotgit_path = std.mem.printSentinel(&dotgit_buf, "{s}/.git", .{folder}, 0) catch return null;
    var gitdir: []const u8 = dotgit_path;
    if (os.isRegular(dotgit_path)) {
        var buf: [path_bytes_max]u8 = undefined;
        const text = os.readHead(dotgit_path, &buf);
        const trimmed = std.mem.trim(u8, text, "\r\n \t");
        if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
        const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
        gitdir = if (std.mem.startsWith(u8, target, "/"))
            std.mem.print(&gitdir_buf, "{s}", .{target}) catch return null
        else
            std.mem.print(&gitdir_buf, "{s}/{s}", .{ folder, target }) catch return null;
    }
    var commondir: []const u8 = gitdir;
    const commondir_file = std.mem.printSentinel(&path_buf, "{s}/commondir", .{gitdir}, 0) catch return null;
    if (os.isRegular(commondir_file)) {
        var cbuf: [path_bytes_max]u8 = undefined;
        const rel = std.mem.trim(u8, os.readHead(commondir_file, &cbuf), "\r\n \t");
        if (rel.len > 0) {
            commondir = if (std.mem.startsWith(u8, rel, "/"))
                std.mem.print(&common_buf, "{s}", .{rel}) catch return null
            else
                std.mem.print(&common_buf, "{s}/{s}", .{ gitdir, rel }) catch return null;
        }
    }
    const head_path = std.mem.printSentinel(&path_buf, "{s}/HEAD", .{gitdir}, 0) catch return null;
    var head_buf: [512]u8 = undefined;
    const head = std.mem.trim(u8, os.readHead(head_path, &head_buf), "\r\n \t");
    if (head.len == 0) return null;
    if (std.mem.startsWith(u8, head, "ref:")) {
        const ref = std.mem.trim(u8, head["ref:".len..], " \t");
        for ([_][]const u8{ gitdir, commondir }) |base| {
            const ref_path = std.mem.printSentinel(&path_buf, "{s}/{s}", .{ base, ref }, 0) catch continue;
            var sha_buf: [128]u8 = undefined;
            const direct = std.mem.trim(u8, os.readHead(ref_path, &sha_buf), "\r\n \t");
            if (direct.len >= 40 and direct.len <= out.len) {
                @memcpy(out[0..direct.len], direct);
                return out[0..direct.len];
            }
            const packed_path = std.mem.printSentinel(&path_buf, "{s}/packed-refs", .{base}, 0) catch continue;
            if (os.openRegular(packed_path)) |fd| {
                defer os.close(fd);
                var contents: std.ArrayList(u8) = .empty;
                defer contents.deinit(std.heap.c_allocator);
                os.readUpTo(std.heap.c_allocator, fd, &contents, 1 << 20) catch continue;
                var lines = std.mem.splitScalar(u8, contents.items, '\n');
                while (lines.next()) |line| {
                    const clean = std.mem.trim(u8, line, "\r \t");
                    if (clean.len == 0 or clean[0] == '#' or clean[0] == '^') continue;
                    const sp = std.mem.findScalar(u8, clean, ' ') orelse continue;
                    if (std.mem.eql(u8, clean[sp + 1 ..], ref) and sp >= 40 and sp <= out.len) {
                        @memcpy(out[0..sp], clean[0..sp]);
                        return out[0..sp];
                    }
                }
            } else |_| {}
        }
        return null;
    }
    if (head.len < 40 or head.len > out.len) return null;
    @memcpy(out[0..head.len], head);
    return out[0..head.len];
}

fn lockPath(config_dir: []const u8, buf: *[path_bytes_max]u8) ?[:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/extensions/lumen.lock", .{config_dir}, 0) catch null;
}

fn updateLockFile(
    gpa: std.mem.Allocator,
    config_dir: []const u8,
    ext_name: []const u8,
    sha: ?[]const u8,
) void {
    var path_buf: [path_bytes_max]u8 = undefined;
    const path = lockPath(config_dir, &path_buf) orelse return;
    var existing: std.ArrayList(u8) = .empty;
    defer existing.deinit(gpa);
    if (os.openRegular(path)) |fd| {
        defer os.close(fd);
        os.readUpTo(gpa, fd, &existing, 1 << 20) catch {};
    } else |_| {}

    const Entry = struct { name: []const u8, sha: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    var replaced = false;
    var lines = std.mem.splitScalar(u8, existing.items, '\n');
    while (lines.next()) |line| {
        const clean = std.mem.trim(u8, line, "\r \t");
        if (clean.len == 0) continue;
        const sp = std.mem.findScalar(u8, clean, ' ') orelse continue;
        const k = clean[0..sp];
        const v = std.mem.trim(u8, clean[sp + 1 ..], " \t");
        if (std.mem.eql(u8, k, ext_name)) {
            replaced = true;
            if (sha) |new_sha| entries.append(gpa, .{ .name = ext_name, .sha = new_sha }) catch {};
        } else {
            entries.append(gpa, .{ .name = k, .sha = v }) catch {};
        }
    }
    if (!replaced) {
        if (sha) |new_sha| entries.append(gpa, .{ .name = ext_name, .sha = new_sha }) catch {};
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (entries.items) |entry| {
        out.appendSlice(gpa, entry.name) catch return;
        out.append(gpa, ' ') catch return;
        out.appendSlice(gpa, entry.sha) catch return;
        out.append(gpa, '\n') catch return;
    }
    os.writeFileAtomic(path, out.items) catch |err| {
        log.warn("writing {s}: {t}", .{ path, err });
    };
}

fn recordAllLocks(gpa: std.mem.Allocator, io: std.Io, config_dir: []const u8) void {
    var ext_dir_buf: [path_bytes_max]u8 = undefined;
    const ext_dir = std.mem.printSentinel(
        &ext_dir_buf,
        "{s}/extensions",
        .{config_dir},
        0,
    ) catch return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (os.subdirs(arena.allocator(), ext_dir, Host.validId)) |name| {
        var folder_buf: [path_bytes_max]u8 = undefined;
        const folder = std.mem.printSentinel(
            &folder_buf,
            "{s}/{s}",
            .{ ext_dir, name },
            0,
        ) catch continue;
        if (!hasGitMarker(folder)) continue;
        var sha_buf: [64]u8 = undefined;
        if (headSha(gpa, io, folder, &sha_buf)) |sha| updateLockFile(gpa, config_dir, name, sha);
    }
}

/// The commits an update left checked out, into lumen.lock: the one
/// extension it named, or every one.
fn recordUpdateLocks(job: *Job) void {
    const ui = job.ui;
    if (job.nameSlice().len == 0) return recordAllLocks(ui.gpa, ui.io, ui.config_dir);
    var sha_buf: [64]u8 = undefined;
    if (headSha(ui.gpa, ui.io, job.folderPath(), &sha_buf)) |sha| {
        updateLockFile(ui.gpa, ui.config_dir, job.nameSlice(), sha);
    }
}

pub fn update(ui: *Ui, caller: ?*c.GApplicationCommandLine, name: ?[]const u8) void {
    var folder_bytes: [path_bytes_max]u8 = undefined;
    const file_allow: [*:0]const u8 = if (Ui.testMode()) "always" else "never";
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
        if (!hasGitMarker(folder)) {
            return fail(ui, caller, "{s} is not a git repository", .{extension_name});
        }
        var name_buffer: [extension_name_bytes_max + 1]u8 = undefined;
        const name_z = std.mem.printSentinel(&name_buffer, "{s}", .{extension_name}, 0) catch {
            return fail(ui, caller, "no extension named \"{s}\"", .{extension_name});
        };
        var argv = [_:null]?[*:0]const u8{
            "sh",
            "-c",
            update_one_script,
            "lumen-update",
            folder.ptr,
            name_z.ptr,
            file_allow,
        };
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
        \\unset CDPATH
        \\cd -- "$1" || exit 1
        \\file_allow=${2:-never}
        \\status=0
        \\for d in */; do
        \\  [ -e "./${d}.git" ] || continue
        \\  [ "$(git -C "./$d" rev-parse --show-toplevel 2>/dev/null)" = "$(cd -- "./$d" && pwd -P)" ] || continue
        \\  printf '%s: ' "${d%/}"
        \\  allow=$file_allow
        \\  case $(git -C "./$d" ls-remote --get-url 2>/dev/null) in
        \\  /*|file://*) allow=always ;;
        \\  esac
        \\  before=$(git -C "./$d" rev-parse HEAD 2>/dev/null)
        \\  if git -C "./$d" -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always -c "protocol.file.allow=$allow" -c submodule.recurse=false pull --ff-only --quiet; then
        \\    after=$(git -C "./$d" rev-parse HEAD 2>/dev/null)
        \\    if [ "$after" = "$before" ]; then
        \\      echo up to date
        \\    else
        \\      echo "updated (${before%"${before#???????}"}..${after%"${after#???????}"})"
        \\    fi
        \\  else
        \\    status=1
        \\  fi
        \\done
        \\exit $status
        ,
        "lumen-update", folder.ptr,
        file_allow,
    };
    start(ui, caller, .update, "", folder, folder, &argv);
}

pub fn uninstall(ui: *Ui, caller: ?*c.GApplicationCommandLine, name: []const u8) void {
    if (!Host.validId(name)) return fail(ui, caller, "no extension named \"{s}\"", .{name});
    var folder_bytes: [path_bytes_max]u8 = undefined;
    const folder = extensionFolder(ui, &folder_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    // A dangling link is still there to remove.
    if (!os.existsAtNoFollow(std.os.linux.AT.FDCWD, folder)) {
        return fail(ui, caller, "no extension named \"{s}\"", .{name});
    }
    // Its data goes with it: the next extension of this name would get its
    // preferences, passwords included.
    var data_bytes: [path_bytes_max]u8 = undefined;
    const data = extensionDataFolder(ui, &data_bytes, name) orelse {
        return fail(ui, caller, "path too long", .{});
    };
    var argv = [_:null]?[*:0]const u8{ "rm", "-rf", "--", folder.ptr, data.ptr };
    start(ui, caller, .uninstall, name, folder, folder, &argv);
}

fn childSetSid(_: ?*anyopaque) callconv(.c) void {
    _ = std.os.linux.setsid();
}

fn killJobGroup(subprocess: *c.GSubprocess) void {
    if (c.g_subprocess_get_identifier(subprocess)) |ident| {
        if (std.fmt.parseInt(i32, std.mem.span(ident), 10)) |pid| {
            if (pid > 0) _ = std.os.linux.kill(-pid, .KILL);
        } else |_| {}
    }
    c.g_subprocess_force_exit(subprocess);
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
    // Nobody can answer a prompt, keep git messages in English, and isolate
    // the child in its own session/process group so timeouts kill grandchildren too.
    // Without a terminal (setsid) and with stdin on /dev/null, ssh cannot
    // ask either, and SSH_ASKPASS_REQUIRE=never keeps it from a window. The
    // user's own ssh command stays (GIT_SSH_COMMAND, core.sshCommand: the
    // key a private repository needs); `ssh -oBatchMode=yes` set here
    // replaced it (MYP-614).
    c.g_subprocess_launcher_setenv(launcher, "GIT_TERMINAL_PROMPT", "0", 1);
    c.g_subprocess_launcher_setenv(launcher, "SSH_ASKPASS_REQUIRE", "never", 1);
    c.g_subprocess_launcher_setenv(launcher, "LC_ALL", "C", 1);
    c.g_subprocess_launcher_unsetenv(launcher, "CDPATH");
    c.g_subprocess_launcher_set_child_setup(launcher, &childSetSid, null, null);
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
        killJobGroup(subprocess);
        c.g_object_unref(subprocess);
        return fail(ui, caller, "out of memory", .{});
    };
    job.* = .{
        .ui = ui,
        .caller = if (caller) |command_line| @ptrCast(c.g_object_ref(command_line)) else null,
        .subprocess = subprocess,
        .kind = kind,
        .cancellable = c.g_cancellable_new(),
        .wait_cancellable = c.g_cancellable_new(),
    };
    job.name.set(name);
    // extensionFolder builds them in buffers of this size: they always fit.
    std.debug.assert(folder.len <= @TypeOf(job.folder).capacity);
    std.debug.assert(work.len <= @TypeOf(job.work).capacity);
    job.folder.set(folder);
    job.work.set(work);
    active_jobs.append(std.heap.c_allocator, job) catch {};
    job.timer = c.g_timeout_add_seconds(job_timeout_s, &onTimeout, job);
    // Read as bytes, chunk by chunk, keeping only the end: git prints file
    // names and messages in any encoding, and how much it prints has no
    // bound (communicate kept all of it).
    readOutput(job);
}

fn readOutput(job: *Job) void {
    const stdout = c.g_subprocess_get_stdout_pipe(job.subprocess) orelse {
        c.g_subprocess_wait_async(job.subprocess, job.wait_cancellable, &onDone, job);
        return;
    };
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
    if (shutting_down) return 0;
    job.timed_out = true;
    killJobGroup(job.subprocess);
    c.g_cancellable_cancel(job.cancellable);
    return 0;
}

fn onOutput(_: ?*c.GObject, async_result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(data.?));
    var err: ?*c.GError = null;
    if (c.g_subprocess_get_stdout_pipe(job.subprocess)) |stdout| {
        const bytes_read = c.g_input_stream_read_finish(stdout, async_result, &err);
        if (bytes_read > 0 and !shutting_down) {
            job.keepOutput(job.chunk[0..@intCast(bytes_read)]);
            return readOutput(job);
        }
        // The end of the output, or a read that failed: the exit decides. A
        // failed read closes the pipe, or a program still writing would block
        // on it and never exit.
        if (err != null or shutting_down) _ = c.g_input_stream_close(stdout, null, null);
        if (job.timed_out) {
            if (err) |gerror| c.g_error_free(gerror);
        } else {
            proc.warnError(.install, err, "reading {s}'s output", .{@tagName(job.kind)});
        }
    }
    if (shutting_down) {
        if (job.timer != 0) _ = c.g_source_remove(job.timer);
        c.g_object_unref(job.cancellable);
        c.g_object_unref(job.wait_cancellable);
        c.g_object_unref(job.subprocess);
        if (job.caller) |command_line| c.g_object_unref(command_line);
        job.ui.gpa.destroy(job);
        return;
    }
    c.g_subprocess_wait_async(job.subprocess, job.wait_cancellable, &onDone, job);
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
        if (!shutting_down) untrackJob(job);
        if (job.timer != 0) _ = c.g_source_remove(job.timer);
        c.g_object_unref(job.cancellable);
        c.g_object_unref(job.wait_cancellable);
        if (!shutting_down and !busy_handed_over) unmarkBusy(job.folderPath());
        c.g_object_unref(job.subprocess);
        // The caller's `lumen --install` returns once this is released.
        if (caller) |command_line| c.g_object_unref(command_line);
        ui.gpa.destroy(job);
    }
    var err: ?*c.GError = null;
    const ran = c.g_subprocess_wait_finish(job.subprocess, async_result, &err) != 0;
    defer if (err) |gerror| c.g_error_free(gerror);
    if (shutting_down) return;
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
            // The update of all fails when one does: the others pulled
            // already, and the lock follows what is checked out.
            if (job.kind == .update) recordUpdateLocks(job);
            ext_view.reload(ui);
        }
        if (job.timed_out) {
            const stopped = "{s} stopped: no end after {d} s";
            return failAndReload(ui, caller, stopped, .{ @tagName(job.kind), job_timeout_s });
        }
        const why = if (err) |gerror|
            std.mem.span(gerror.message)
        else
            std.mem.trim(u8, output, " \n");
        const end = tail(why, failure_output_bytes_max);
        return failAndReload(ui, caller, "{s} failed:\n{s}{s}", .{ @tagName(job.kind), end[0], end[1] });
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
            var init_path_bytes: [path_bytes_max + init_lua.len + 1]u8 = undefined;
            const init_path = std.mem.printSentinel(
                &init_path_bytes,
                "{s}" ++ init_lua,
                .{job.workPath()},
                0,
            ) catch {
                removeTreeThenReload(ui, job.workPath(), job.folderPath());
                fail(ui, caller, "{s}: path too long to check its init.lua", .{job.workPath()});
                return true;
            };
            if (!isPlainFile(init_path)) {
                removeTreeThenReload(ui, job.workPath(), job.folderPath());
                failAndReload(ui, caller, "{s} has no init.lua: it is not a Lumen extension", .{job.nameSlice()});
                return true;
            }
            // Into place, whole: until now nothing loaded it.
            os.rename(job.workPath(), job.folderPath()) catch |err| {
                removeTreeThenReload(ui, job.workPath(), job.folderPath());
                failAndReload(
                    ui,
                    caller,
                    "could not move the clone to {s}: {t}",
                    .{ job.folderPath(), err },
                );
                return true;
            };
            var sha_buf: [64]u8 = undefined;
            if (headSha(ui.gpa, ui.io, job.folderPath(), &sha_buf)) |sha| {
                updateLockFile(ui.gpa, ui.config_dir, job.nameSlice(), sha);
            }
            print(
                ui,
                caller,
                "Installed {s} in {s}\nExtensions run as you: read its init.lua to know what it does.\n",
                .{ job.nameSlice(), job.folderPath() },
            );
        },
        .update => {
            recordUpdateLocks(job);
            if (caller != null) {
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
                    true,
                );
            }
        },
        .uninstall => {
            updateLockFile(ui.gpa, ui.config_dir, job.nameSlice(), null);
            print(ui, caller, "Removed {s}\n", .{job.nameSlice()});
        },
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
/// update of every extension (`all`), or our HEAD-diff marker for one.
fn anyUpdated(all: bool, output: []const u8) bool {
    if (all) return std.mem.find(u8, output, ": updated") != null;
    if (std.mem.find(u8, output, "lumen: updated") != null) return true;
    if (std.mem.find(u8, output, "lumen: up to date") != null) return false;
    return output.len > 0 and
        std.mem.find(u8, output, "Already up to date") == null and
        std.mem.find(u8, output, "Already up-to-date") == null;
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
    const command_line = caller orelse return note(ui, message, true);
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
    removal.* = .{ .ui = ui, .cancellable = c.g_cancellable_new() };
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
    removal.subprocess = subprocess;
    active_removals.append(std.heap.c_allocator, removal) catch {};
    c.g_subprocess_wait_check_async(subprocess, removal.cancellable, &onRemoved, removal);
}

const Removal = struct {
    ui: *Ui,
    cancellable: *c.GCancellable,
    subprocess: ?*c.GSubprocess = null,
    busy_folder: core.FixedStr(std.Io.Dir.max_path_bytes) = .{},

    fn finish(removal: *Removal) void {
        if (!shutting_down) {
            untrackRemoval(removal);
            unmarkBusy(removal.busy_folder.slice());
            ext_view.reload(removal.ui);
        }
        c.g_object_unref(removal.cancellable);
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
        if (!shutting_down) proc.warnError(.install, err, "rm", .{}) else if (err) |e| c.g_error_free(e);
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
    // A byte that is not UTF-8 midway: the rest still shows (MYP-533).
    try std.testing.expectEqualStrings("a\u{FFFD}bc", format(&message_bytes, "{s}", .{"a\xffbc"}));
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
    try std.testing.expect(!anyUpdated(false, "Ya está actualizado.\nlumen: up to date\n"));
    try std.testing.expect(anyUpdated(false, "lumen: updated\nabc1234 feat: x\n"));
    try std.testing.expect(anyUpdated(false, "Updating 1a2b..3c4d\nFast-forward\n"));
}

test "installer helpers resolve relative paths, validate names, and pick last useful error line" {
    try std.testing.expectEqualStrings(
        "fatal: repository not found",
        lastUsefulLine("update failed:\nfatal: repository not found\n  \n"),
    );
    try std.testing.expectEqualStrings("Updated", lastUsefulLine("Updated"));

    var resolved_buf: [url_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/work/repos/ext",
        resolveLocalUrl(&resolved_buf, "./repos/ext", "/work").?,
    );
    try std.testing.expectEqualStrings(
        "/work/ext",
        resolveLocalUrl(&resolved_buf, "ext", "/work").?,
    );
    try std.testing.expectEqualStrings(
        "git@github.com:me/ext.git",
        resolveLocalUrl(&resolved_buf, "git@github.com:me/ext.git", "/work").?,
    );
    try std.testing.expect(!validInstallName("-"));
    try std.testing.expect(!validInstallName("---"));
    try std.testing.expect(!validInstallName("_"));
    try std.testing.expect(validInstallName("my-ext_1"));
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

test "updating a manual folder inside a parent git repo leaves the parent intact; worktrees update" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const io = testing.io;
    const deadline_ns = os.monotonicNs() + 10 * std.time.ns_per_s;

    const runGit = struct {
        fn call(alloc: std.mem.Allocator, io_ctx: std.Io, deadline: u64, argv: []const []const u8) ![]u8 {
            const res = try os.child.run(alloc, io_ctx, argv, .{ .deadline_ns = deadline });
            defer alloc.free(res.stderr);
            if (res.code != 0) {
                std.debug.print("git failed: {s}\n", .{res.stderr});
                alloc.free(res.stdout);
                return error.GitFailed;
            }
            return res.stdout;
        }
    }.call;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [path_bytes_max]u8 = undefined;
    const root = try os.tmpDirAbs(&tmp, &root_buf);

    var remote_buf: [path_bytes_max]u8 = undefined;
    const remote = try std.fmt.bufPrint(&remote_buf, "{s}/remote.git", .{root});
    var seed_buf: [path_bytes_max]u8 = undefined;
    const seed = try std.fmt.bufPrint(&seed_buf, "{s}/seed", .{root});
    var parent_buf: [path_bytes_max]u8 = undefined;
    const parent = try std.fmt.bufPrint(&parent_buf, "{s}/parent", .{root});
    var manual_buf: [path_bytes_max]u8 = undefined;
    const manual = try std.fmt.bufPrint(&manual_buf, "{s}/parent/extensions/manual", .{root});
    var wt_buf: [path_bytes_max]u8 = undefined;
    const wt = try std.fmt.bufPrint(&wt_buf, "{s}/worktree", .{root});

    // Bare remote + initial commit via seed.
    gpa.free(try runGit(gpa, io, deadline_ns, &.{ "git", "init", "--bare", remote }));
    gpa.free(try runGit(gpa, io, deadline_ns, &.{ "git", "clone", remote, seed }));
    gpa.free(try runGit(gpa, io, deadline_ns, &.{
        "git", "-C", seed, "-c", "user.name=T", "-c", "user.email=t@e", "commit", "--allow-empty", "-m", "c1",
    }));
    const branch_out = try runGit(gpa, io, deadline_ns, &.{ "git", "-C", seed, "branch", "--show-current" });
    defer gpa.free(branch_out);
    const branch = std.mem.trimEnd(u8, branch_out, "\r\n ");
    gpa.free(try runGit(gpa, io, deadline_ns, &.{ "git", "-C", seed, "push", "-u", "origin", branch }));

    // Clone parent repo at c1, add a manual extension folder (no .git of its own).
    gpa.free(try runGit(gpa, io, deadline_ns, &.{ "git", "clone", remote, parent }));
    try os.mkdirP(manual);
    try testing.expect(!hasGitMarker(manual));

    // Create a linked git worktree at c1 on a tracking branch.
    gpa.free(try runGit(gpa, io, deadline_ns, &.{
        "git", "-C", seed, "worktree", "add", "-b", "wt-branch", wt, branch,
    }));
    var wt_upstream_buf: [128]u8 = undefined;
    const wt_upstream = try std.fmt.bufPrint(&wt_upstream_buf, "origin/{s}", .{branch});
    gpa.free(try runGit(gpa, io, deadline_ns, &.{
        "git", "-C", wt, "branch", "--set-upstream-to", wt_upstream,
    }));
    try testing.expect(hasGitMarker(wt));

    // Advance remote to c2.
    gpa.free(try runGit(gpa, io, deadline_ns, &.{
        "git", "-C", seed, "-c", "user.name=T", "-c", "user.email=t@e", "commit", "--allow-empty", "-m", "c2",
    }));
    gpa.free(try runGit(gpa, io, deadline_ns, &.{ "git", "-C", seed, "push", "origin", branch }));

    const parent_head_before = try runGit(gpa, io, deadline_ns, &.{ "git", "-C", parent, "rev-parse", "HEAD" });
    defer gpa.free(parent_head_before);
    const seed_head = try runGit(gpa, io, deadline_ns, &.{ "git", "-C", seed, "rev-parse", "HEAD" });
    defer gpa.free(seed_head);

    // 1. Updating the manual folder via update_one_script must fail and NOT pull parent!
    var manual_res = try os.child.run(gpa, io, &.{
        "sh", "-c", update_one_script, "lumen-update", manual, "manual",
    }, .{ .deadline_ns = deadline_ns });
    defer manual_res.deinit(gpa);
    try testing.expect(manual_res.code != 0);
    try testing.expect(std.mem.find(u8, manual_res.stdout, "is not a git repository") != null);
    const parent_head_after = try runGit(gpa, io, deadline_ns, &.{ "git", "-C", parent, "rev-parse", "HEAD" });
    defer gpa.free(parent_head_after);
    try testing.expectEqualStrings(parent_head_before, parent_head_after);

    // 2. Updating a valid git worktree must succeed when file:// is allowed in test mode.
    var wt_res = try os.child.run(gpa, io, &.{
        "sh", "-c", update_one_script, "lumen-update", wt, "worktree", "always",
    }, .{ .deadline_ns = deadline_ns });
    defer wt_res.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), wt_res.code);
    const wt_head_after = try runGit(gpa, io, deadline_ns, &.{ "git", "-C", wt, "rev-parse", "HEAD" });
    defer gpa.free(wt_head_after);
    try testing.expectEqualStrings(seed_head, wt_head_after);

    // 3. An extension installed from a path on this machine updates outside
    // test mode too: its origin is local (MYP-528).
    var local_res = try os.child.run(gpa, io, &.{
        "sh", "-c", update_one_script, "lumen-update", wt, "worktree", "never",
    }, .{ .deadline_ns = deadline_ns });
    defer local_res.deinit(gpa);
    try testing.expectEqual(@as(?u8, 0), local_res.code);
    // Any other remote keeps to https and ssh.
    gpa.free(try runGit(gpa, io, deadline_ns, &.{
        "git", "-C", wt, "remote", "set-url", "origin", "ext::sh -c false",
    }));
    var blocked_res = try os.child.run(gpa, io, &.{
        "sh", "-c", update_one_script, "lumen-update", wt, "worktree", "never",
    }, .{ .deadline_ns = deadline_ns });
    defer blocked_res.deinit(gpa);
    try testing.expect(blocked_res.code != 0);
    try testing.expect(std.mem.find(u8, blocked_res.stderr, "not allowed") != null);

    // 4. gitHeadSha + lockfile record/remove work on both normal repos and worktrees.
    var sha_buf: [64]u8 = undefined;
    const wt_sha = gitHeadSha(wt, &sha_buf).?;
    const expected_sha = std.mem.trim(u8, seed_head, "\r\n ");
    try testing.expectEqualStrings(expected_sha, wt_sha);
    const parent_sha = gitHeadSha(parent, &sha_buf).?;
    try testing.expectEqualStrings(std.mem.trim(u8, parent_head_before, "\r\n "), parent_sha);

    try os.mkdirP(manual);
    updateLockFile(gpa, parent, "alpha", wt_sha);
    updateLockFile(gpa, parent, "beta", parent_sha);
    var lock_buf: [path_bytes_max]u8 = undefined;
    const lp = lockPath(parent, &lock_buf).?;
    const lfd = try os.openRegular(lp);
    defer os.close(lfd);
    var content_buf: [512]u8 = undefined;
    const ltext = os.readHead(lp, &content_buf);
    try testing.expect(std.mem.find(u8, ltext, "alpha ") != null);
    try testing.expect(std.mem.find(u8, ltext, "beta ") != null);
    updateLockFile(gpa, parent, "alpha", null);
    const ltext2 = os.readHead(lp, &content_buf);
    try testing.expect(std.mem.find(u8, ltext2, "alpha ") == null);
    try testing.expect(std.mem.find(u8, ltext2, "beta ") != null);
}

test "gitCloneArgv restricts git protocols and disables submodules" {
    var buf: [20]?[*:0]const u8 = undefined;
    const prod = gitCloneArgv(&buf, "https://example.com/ext.git", "/tmp/dest", false);
    var saw_never = false;
    var saw_https = false;
    var saw_file = false;
    var saw_no_sub = false;
    var i: usize = 0;
    while (prod[i]) |arg| : (i += 1) {
        const s = std.mem.span(arg);
        if (std.mem.eql(u8, s, "protocol.allow=never")) saw_never = true;
        if (std.mem.eql(u8, s, "protocol.https.allow=always")) saw_https = true;
        if (std.mem.eql(u8, s, "protocol.file.allow=always")) saw_file = true;
        if (std.mem.eql(u8, s, "--no-recurse-submodules")) saw_no_sub = true;
    }
    try std.testing.expect(saw_never and saw_https and !saw_file and saw_no_sub);

    const test_only = gitCloneArgv(&buf, "/tmp/repo", "/tmp/dest", true);
    var saw_test_file = false;
    i = 0;
    while (test_only[i]) |arg| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(arg), "protocol.file.allow=always")) saw_test_file = true;
    }
    try std.testing.expect(saw_test_file);
}

test "a repository on this machine is cloned with the file transport outside test mode (MYP-528)" {
    try std.testing.expect(isLocalUrl("/home/me/ext"));
    try std.testing.expect(isLocalUrl("file:///home/me/ext"));
    try std.testing.expect(!isLocalUrl("https://example.com/ext.git"));
    try std.testing.expect(!isLocalUrl("git@example.com:me/ext.git"));
    try std.testing.expect(!isLocalUrl("ext::sh -c false"));
    // A relative path is made absolute from the caller's folder first.
    var resolved_buf: [url_bytes_max]u8 = undefined;
    const resolved = resolveLocalUrl(&resolved_buf, "./ext", "/home/me").?;
    try std.testing.expect(isLocalUrl(resolved));

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const deadline_ns = os.monotonicNs() + 15 * std.time.ns_per_s;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [path_bytes_max]u8 = undefined;
    const root = try os.tmpDirAbs(&tmp, &root_buf);
    var seed_buf: [path_bytes_max:0]u8 = undefined;
    const seed = try std.fmt.bufPrintSentinel(&seed_buf, "{s}/seed", .{root}, 0);
    var dest_buf: [path_bytes_max:0]u8 = undefined;
    const dest = try std.fmt.bufPrintSentinel(&dest_buf, "{s}/dest", .{root}, 0);
    const setup = [_][]const []const u8{
        &.{ "git", "init", "-q", seed },
        &.{ "git", "-C", seed, "-c", "user.name=T", "-c", "user.email=t@e", "commit", "-q", "--allow-empty", "-m", "c1" },
    };
    for (setup) |argv| {
        var res = try os.child.run(gpa, io, argv, .{ .deadline_ns = deadline_ns });
        defer res.deinit(gpa);
        try std.testing.expectEqual(@as(?u8, 0), res.code);
    }
    // The argv `install` runs, as outside the tests.
    var clone_buf: [20]?[*:0]const u8 = undefined;
    const argv_z = gitCloneArgv(&clone_buf, seed.ptr, dest.ptr, isLocalUrl(seed));
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var i: usize = 0;
    while (argv_z[i]) |arg| : (i += 1) try argv.append(gpa, std.mem.span(arg));
    var clone_res = try os.child.run(gpa, io, argv.items, .{ .deadline_ns = deadline_ns });
    defer clone_res.deinit(gpa);
    try std.testing.expectEqual(@as(?u8, 0), clone_res.code);
}

test "lumen.lock records the commit of a reftable repository (MYP-529)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const deadline_ns = os.monotonicNs() + 15 * std.time.ns_per_s;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [path_bytes_max]u8 = undefined;
    const root = try os.tmpDirAbs(&tmp, &root_buf);
    var repo_buf: [path_bytes_max]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repo_buf, "{s}/repo", .{root});
    {
        // A git without reftable (before 2.45) has nothing to test.
        var res = try os.child.run(gpa, io, &.{
            "git", "-c", "init.defaultRefFormat=reftable", "init", "-q", "--ref-format=reftable", repo,
        }, .{ .deadline_ns = deadline_ns });
        defer res.deinit(gpa);
        if (res.code != 0) return error.SkipZigTest;
    }
    var commit_res = try os.child.run(gpa, io, &.{
        "git", "-C", repo, "-c", "user.name=T", "-c", "user.email=t@e", "commit", "-q", "--allow-empty", "-m", "c1",
    }, .{ .deadline_ns = deadline_ns });
    defer commit_res.deinit(gpa);
    try std.testing.expectEqual(@as(?u8, 0), commit_res.code);
    var head_res = try os.child.run(gpa, io, &.{ "git", "-C", repo, "rev-parse", "HEAD" }, .{
        .deadline_ns = deadline_ns,
    });
    defer head_res.deinit(gpa);
    const expected = std.mem.trim(u8, head_res.stdout, "\r\n ");

    var sha_buf: [64]u8 = undefined;
    // Its files do not say (HEAD names "refs/heads/.invalid")...
    try std.testing.expect(gitHeadSha(repo, &sha_buf) == null);
    // ...git does.
    try std.testing.expectEqualStrings(expected, headSha(gpa, io, repo, &sha_buf).?);
}

test "update scripts work with CDPATH set and dash-prefixed extension folders" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const deadline_ns = os.monotonicNs() + 15 * std.time.ns_per_s;

    const runGit = struct {
        fn call(alloc: std.mem.Allocator, io_ctx: std.Io, deadline: u64, argv: []const []const u8) ![]u8 {
            const res = try os.child.run(alloc, io_ctx, argv, .{ .deadline_ns = deadline });
            defer alloc.free(res.stderr);
            if (res.code != 0) {
                std.debug.print("git failed: {s}\n", .{res.stderr});
                alloc.free(res.stdout);
                return error.GitFailed;
            }
            return res.stdout;
        }
    }.call;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [path_bytes_max]u8 = undefined;
    const root = try os.tmpDirAbs(&tmp, &root_buf);

    var seed_buf: [path_bytes_max]u8 = undefined;
    const seed = try std.fmt.bufPrint(&seed_buf, "{s}/seed", .{root});
    var exts_buf: [path_bytes_max]u8 = undefined;
    const exts = try std.fmt.bufPrint(&exts_buf, "{s}/extensions", .{root});
    var dash_buf: [path_bytes_max]u8 = undefined;
    const dash = try std.fmt.bufPrint(&dash_buf, "{s}/-dash-ext", .{exts});
    try os.mkdirP(seed);
    try os.mkdirP(exts);

    gpa.free(try runGit(gpa, io, deadline_ns, &.{ "git", "init", seed }));
    {
        var init_lua_buf: [path_bytes_max]u8 = undefined;
        const init_path = try std.fmt.bufPrintSentinel(&init_lua_buf, "{s}/init.lua", .{seed}, 0);
        try os.writeFile(init_path, "return {}\n");
    }
    gpa.free(try runGit(gpa, io, deadline_ns, &.{ "git", "-C", seed, "add", "init.lua" }));
    gpa.free(try runGit(gpa, io, deadline_ns, &.{
        "git", "-C", seed, "-c", "user.name=T", "-c", "user.email=t@e", "commit", "-m", "c1",
    }));
    gpa.free(try runGit(gpa, io, deadline_ns, &.{
        "git", "-c", "protocol.file.allow=always", "clone", seed, dash,
    }));

    // Both update-one and update-all scripts must work even with CDPATH set.
    var one_res = try os.child.run(gpa, io, &.{
        "sh",
        "-c",
        "export CDPATH=\".:/tmp\"; " ++ update_one_script,
        "lumen-update",
        dash,
        "-dash-ext",
        "always",
    }, .{ .deadline_ns = deadline_ns });
    defer one_res.deinit(gpa);
    try std.testing.expectEqual(@as(?u8, 0), one_res.code);
    try std.testing.expect(std.mem.find(u8, one_res.stdout, "up to date") != null);

    const all_script =
        \\export CDPATH=".:/tmp"
        \\unset CDPATH
        \\cd -- "$1" || exit 1
        \\file_allow=${2:-never}
        \\status=0
        \\for d in */; do
        \\  [ -e "./${d}.git" ] || continue
        \\  [ "$(git -C "./$d" rev-parse --show-toplevel 2>/dev/null)" = "$(cd -- "./$d" && pwd -P)" ] || continue
        \\  printf '%s: ' "${d%/}"
        \\  git -C "./$d" -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always -c "protocol.file.allow=$file_allow" -c submodule.recurse=false pull --ff-only --quiet || status=1
        \\  echo up to date
        \\done
        \\exit $status
    ;
    var all_res = try os.child.run(gpa, io, &.{
        "sh", "-c", all_script, "lumen-update", exts, "always",
    }, .{ .deadline_ns = deadline_ns });
    defer all_res.deinit(gpa);
    try std.testing.expectEqual(@as(?u8, 0), all_res.code);
    try std.testing.expect(std.mem.find(u8, all_res.stdout, "-dash-ext: up to date") != null);
}

test "g_subprocess_wait_async waits for killed process exit when wait_cancellable is uncancelled" {
    const State = struct {
        done: bool = false,
        ran: bool = false,
        alive_after_done: bool = true,
        pid: i32 = 0,
        fn onWaitDone(source: ?*c.GObject, res: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            const sub: *c.GSubprocess = @ptrCast(source.?);
            var err: ?*c.GError = null;
            self.ran = c.g_subprocess_wait_finish(sub, res, &err) != 0;
            if (err) |gerror| c.g_error_free(gerror);
            self.alive_after_done = self.pid > 0 and
                std.os.linux.errno(std.os.linux.kill(self.pid, @fromBackingInt(@intCast(0)))) == .SUCCESS;
            self.done = true;
        }
    };
    const flags = c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_MERGE;
    const launcher = c.g_subprocess_launcher_new(flags);
    defer c.g_object_unref(launcher);
    var argv = [_:null]?[*:0]const u8{ "sh", "-c", "sleep 30" };
    var err: ?*c.GError = null;
    const sub = c.g_subprocess_launcher_spawnv(launcher, &argv, &err) orelse {
        if (err) |gerror| c.g_error_free(gerror);
        return error.TestUnexpectedResult;
    };
    defer c.g_object_unref(sub);
    const read_cancel = c.g_cancellable_new();
    defer c.g_object_unref(read_cancel);
    const wait_cancel = c.g_cancellable_new();
    defer c.g_object_unref(wait_cancel);

    var state: State = .{};
    if (c.g_subprocess_get_identifier(sub)) |ident| {
        state.pid = std.fmt.parseInt(i32, std.mem.span(ident), 10) catch 0;
    }
    c.g_subprocess_force_exit(sub);
    c.g_cancellable_cancel(read_cancel);
    c.g_subprocess_wait_async(sub, wait_cancel, &State.onWaitDone, &state);

    const deadline_ns = os.monotonicNs() + 5 * std.time.ns_per_s;
    while (!state.done and os.monotonicNs() < deadline_ns) {
        _ = c.g_main_context_iteration(null, 1);
    }
    try std.testing.expect(state.done);
    try std.testing.expect(state.ran);
    try std.testing.expect(!state.alive_after_done);
}

test "an init.lua must be a file of the clone itself, and a dangling link is an entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [path_bytes_max]u8 = undefined;
    const root = try os.tmpDirAbs(&tmp, &root_buf);
    var plain_buf: [path_bytes_max]u8 = undefined;
    const plain = try std.mem.printSentinel(&plain_buf, "{s}/plain.lua", .{root}, 0);
    try os.writeFile(plain, "return {}\n");
    try std.testing.expect(isPlainFile(plain));

    // A link to a file outside the clone reads like one, and is not.
    var link_buf: [path_bytes_max]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buf, "{s}/init.lua", .{root}, 0);
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.symlink(plain, link));
    try std.testing.expect(os.info(link) != null);
    try std.testing.expect(!isPlainFile(link));

    var folder_buf: [path_bytes_max]u8 = undefined;
    const folder = try std.mem.printSentinel(&folder_buf, "{s}/folder.lua", .{root}, 0);
    try os.mkdirP(folder);
    try std.testing.expect(!isPlainFile(folder));

    // A dangling link: `os.info` does not see it, an install or uninstall must.
    var dangling_buf: [path_bytes_max]u8 = undefined;
    const dangling = try std.mem.printSentinel(&dangling_buf, "{s}/gone", .{root}, 0);
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.symlink("nowhere", dangling));
    try std.testing.expect(!isPlainFile(dangling));
    try std.testing.expect(os.info(dangling) == null);
    try std.testing.expect(os.existsAtNoFollow(std.os.linux.AT.FDCWD, dangling));
}
