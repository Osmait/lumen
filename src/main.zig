//! Lumen — a native launcher for Linux.
//!
//!   lumen              toggle the window (starts the daemon if needed)
//!   lumen --daemon     start hidden (for `exec-once`)
//!   lumen --show | --hide | --quit
//!   lumen --stats      memory, index and latency numbers of the running daemon
//!   lumen --view clipboard --query foo   open a view, prefilled
//!   lumen --command github.prs           open an extension's command
//!   lumen --reload     load init.lua and the extensions again
//!   lumen --dmenu [--prompt TEXT]   pick a line of stdin, print it
//!   lumen --install URL [--as NAME] | --update [NAME] | --uninstall NAME
//!   lumen --clip-store  internal: `wl-paste --watch` hands a copy on stdin

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const c = @import("c");
const Db = @import("sys/Db.zig");
const Ui = @import("ui/Ui.zig");
const index = @import("index");
const stats = @import("stats.zig");
const Settings = @import("settings.zig").Settings;
const ipc = @import("ipc.zig");
const cli = @import("cli.zig");
const ipc_server = @import("sys/ipc_server.zig");
const proc = @import("sys/proc.zig");

const version_line = std.fmt.comptimePrint("{s}\n", .{@import("build_options").version});

pub const std_options: std.Options = .{
    .log_level = .info,
    // A 256 KB alternate signal stack in every thread's TLS (GTK's, the
    // driver's too: ~8 MB), only for stack traces on stack overflow.
    .signal_stack_size = null,
};

const log = std.log.scoped(.main);

/// The daemon's state, reached from GLib callbacks that carry no user
/// data; main thread only. The only global of this file.
const Daemon = struct {
    app: *c.GApplication = undefined,
    /// LUMEN_APP_ID lets end-to-end tests run a second, isolated instance
    /// (GApplication is single-instance per id; the socket is per id too).
    app_id: [:0]const u8 = ipc.default_app_id,
    /// Built in `onStartup`; see `readyUi`.
    ui: Ui = undefined,
    ui_ready: bool = false,
    shutting_down: bool = false,
    clipboard_watcher: ClipboardWatcher = .{},
};

var daemon: Daemon = .{};

/// The window, or null when it was never built: before `onStartup`, or
/// when the database could not be opened. Commands that need it fail then.
fn readyUi() ?*Ui {
    return if (daemon.ui_ready) &daemon.ui else null;
}

/// `wl-paste --watch lumen --clip-store`, restarted with a backoff when it
/// dies on its own (wl-paste losing the compositor, a crash): without a
/// restart the history silently stopped growing.
const ClipboardWatcher = struct {
    /// 0 when no watcher runs.
    pid: c.GPid = 0,
    started_ns: u64 = 0,
    backoff_ms: c_uint = backoff_ms_min,

    /// 1, 2, 4... up to 60 s, so a permanent failure does not spin.
    const backoff_ms_min = 1000;
    const backoff_ms_max = 60_000;
    /// A watcher that lived this long was healthy: the backoff starts over.
    const healthy_after_ns = 60 * std.time.ns_per_s;

    fn running(watcher: *const ClipboardWatcher) bool {
        return watcher.pid != 0;
    }
};

/// What `onStartup` needs from `main`, handed over as its user data (main's
/// stack outlives the GTK main loop).
const Start = struct { gpa: std.mem.Allocator, io: std.Io };

extern fn mallopt(param: c_int, value: c_int) c_int;
const M_MMAP_THRESHOLD: c_int = -3;
const M_ARENA_MAX: c_int = -8;

pub fn main(init: std.process.Init) !void {
    stats.started_ns = stats.now();
    // glibc raises its mmap threshold every time a large mmap'd block is
    // freed, so after one index build every later big buffer comes from the
    // heap and is never returned (measured: 133 MB free but kept). A fixed
    // threshold keeps big buffers in mmap, released on free. Fewer arenas
    // (one per thread by default, 24 threads here) fragment less.
    _ = mallopt(M_MMAP_THRESHOLD, 256 * 1024);
    _ = mallopt(M_ARENA_MAX, 4);
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(init.gpa);
    var args_iterator = init.minimal.args.iterate();
    while (args_iterator.next()) |arg| try argv.append(init.gpa, arg.ptr);

    const args = argv.items[1..];
    const first_flag: ?cli.Flag = if (args.len > 0) cli.parse(std.mem.span(args[0].?)) else null;
    if (first_flag == .clip_store) return clipStore(init);
    // --help never needs a daemon: print the usage here, before
    // GApplication can start one.
    for (args) |arg| {
        if (cli.parse(std.mem.span(arg.?)) == .help) return printToStdout(init.io, cli.usage);
    }
    if (args.len == 1 and first_flag == .version) return printToStdout(init.io, version_line);

    if (c.g_getenv(ipc.env.app_id)) |app_id| daemon.app_id = std.mem.span(app_id);
    // Commands that only talk to a running daemon must not become one: with
    // none running GApplication makes the caller the primary instance, so
    // `lumen --stats` would start a whole new daemon and never return. As a
    // launcher it never takes the bus name either (taking it even briefly
    // made a daemon starting at the same moment fail to register).
    const client_only = if (first_flag) |flag| cli.specs.get(flag).needs_daemon else false;
    const launcher = if (client_only) c.G_APPLICATION_IS_LAUNCHER else 0;
    const flags = c.G_APPLICATION_HANDLES_COMMAND_LINE | launcher;
    const gtk_app = c.gtk_application_new(daemon.app_id.ptr, flags);
    defer c.g_object_unref(gtk_app);
    daemon.app = @ptrCast(gtk_app);
    // Zig's default in ReleaseSafe is a checking allocator over mmap (every
    // allocation of 6 KB or more a fresh mapping); glibc's, tuned above, is
    // what the measurements were made with. Debug builds keep the checks.
    const gpa = if (builtin.mode == .debug) init.gpa else std.heap.c_allocator;
    var start: Start = .{ .gpa = gpa, .io = init.io };
    Ui.connect(gtk_app, "startup", &startupCallback, &start);
    Ui.connect(gtk_app, "command-line", &commandLineCallback, null);
    Ui.connect(gtk_app, "shutdown", &shutdownCallback, null);

    if (client_only and !daemonIsRunning()) std.process.fatal("lumen is not running", .{});
    const argc = std.math.cast(c_int, argv.items.len) orelse {
        std.process.fatal("too many arguments", .{});
    };
    const status = c.g_application_run(daemon.app, argc, @ptrCast(argv.items.ptr));
    std.process.exit(std.math.cast(u8, status) orelse 1);
}

/// Registers with the bus as a launcher: true when another instance (the
/// daemon) is the primary one.
fn daemonIsRunning() bool {
    if (c.g_application_register(daemon.app, null, null) == 0) return false;
    return c.g_application_get_is_remote(daemon.app) != 0;
}

/// Nobody is told when stdout is closed (`lumen --help | head -0`): there
/// is no one left to read it.
fn printToStdout(io: std.Io, text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

/// A test instance takes no keyboard, so nobody can close it by hand: if
/// its script dies, it must not stay on screen. Far beyond any test run.
const test_instance_lifetime_s = 300;

/// Runs once, in the primary instance.
fn startupCallback(gtk_app: *c.GtkApplication, data: ?*anyopaque) callconv(.c) void {
    const start: *const Start = @ptrCast(@alignCast(data.?));
    assert(!daemon.ui_ready);
    const path = dbPath() orelse {
        log.err("cannot create the data directory", .{});
        return;
    };
    defer c.g_free(path);
    var db = Db.open(std.mem.span(path)) catch |err| {
        log.err("cannot open {s}: {t}", .{ path, err });
        return;
    };
    db.pruneFrecency(nowSeconds()) catch |err| {
        // Only the table grows until the next start; Db logged SQLite's word.
        log.warn("frecency prune: {t}", .{err});
    };
    daemon.ui = Ui.init(start.gpa, start.io, gtk_app, db);
    const ui = &daemon.ui;
    ui.build();
    ui.on_settings_changed = &settingsChangedCallback;
    daemon.ui_ready = true;
    Ui.ext_view.start(ui);
    c.g_application_hold(daemon.app);
    if (c.g_getenv(ipc.env.test_mode) == null) {
        if (ui.settings.clipboard) startClipboardWatcher();
    } else {
        // Tests feed the clipboard store directly (`--clip-store`).
        _ = c.g_timeout_add_seconds(test_instance_lifetime_s, &testWatchdogCallback, null);
    }
    startFileIndex(ui);
    // The socket lets `lumen` (src/client.zig) reach the daemon without
    // loading GTK (~40 ms per keypress).
    ipc_server.start(start.gpa, daemon.app_id, &socketCallback);
    // Prewarm once the main loop is idle, so it does not delay startup.
    _ = c.g_idle_add(&prewarmCallback, null);
    stats.startup_ns = stats.now() - stats.started_ns;
}

fn nowSeconds() i64 {
    return @divTrunc(c.g_get_real_time(), std.time.us_per_s);
}

/// Where a command's answer goes: the GApplication command line that ran
/// it, or the socket `lumen` asked through.
const Reply = struct {
    command_line: ?*c.GApplicationCommandLine = null,
    stdout: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,
    /// What followed the arguments on the socket (a copy, --clip-store).
    payload: ?[]const u8 = null,

    /// False when the text could not be written (the socket's writer ran
    /// out of memory): the command then fails rather than answer nothing
    /// with success.
    fn print(reply: *const Reply, text: [:0]const u8) bool {
        if (reply.command_line) |command_line| {
            c.g_application_command_line_print(command_line, "%s", text.ptr);
            return true;
        }
        const writer = reply.stdout orelse return true;
        writer.writeAll(text) catch return false;
        return true;
    }

    fn printErr(reply: *const Reply, text: [:0]const u8) void {
        if (reply.command_line) |command_line| {
            c.g_application_command_line_printerr(command_line, "%s", text.ptr);
            return;
        }
        const writer = reply.stderr orelse return;
        writer.writeAll(text) catch log.warn("an error message for the client was lost", .{});
    }
};

/// Every invocation through GApplication (the first one, and those `lumen`
/// hands to lumen-gtk) lands here.
fn commandLineCallback(
    _: *c.GApplication,
    command_line: *c.GApplicationCommandLine,
    _: ?*anyopaque,
) callconv(.c) c_int {
    var argc: c_int = 0;
    const argv = c.g_application_command_line_get_arguments(command_line, &argc);
    defer c.g_strfreev(argv);
    var args: [ipc.args_max][:0]const u8 = undefined;
    var args_count: usize = 0;
    // From 1: without the program's name.
    var argv_index: usize = 1;
    while (argv_index < argc and args_count < args.len) : (argv_index += 1) {
        args[args_count] = std.mem.span(argv[argv_index] orelse continue);
        args_count += 1;
    }
    return run(args[0..args_count], &.{ .command_line = command_line });
}

/// Every invocation through the socket.
fn socketCallback(
    args: []const [:0]const u8,
    payload: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) u8 {
    const status = run(args, &.{ .stdout = stdout, .stderr = stderr, .payload = payload });
    return std.math.cast(u8, status) orelse 1;
}

const status_ok: c_int = 0;
const status_failed: c_int = 1;
const status_usage: c_int = 2;
/// --dmenu and extension jobs answer when they finish, through the
/// GApplicationCommandLine that lumen-gtk holds open; its exit status is
/// set then.
const status_answered_later: c_int = 1;

/// What one invocation asks for, parsed and checked before anything runs.
const Request = union(enum) {
    /// Answered at once; flags after it are not read (`--dump --view x`
    /// dumps).
    now: Now,
    /// Everything else, once all flags are read: what the window does.
    window: Window,

    const Now = union(enum) {
        dump,
        key: [:0]const u8,
        stats,
        /// Types into the search bar of the view shown (tests).
        text: [:0]const u8,
        reload,
        help,
        version,
        quit,
        clip_store,
    };

    const Window = struct {
        mode: enum { toggle, show, hide, daemon } = .toggle,
        view: ?Ui.View = null,
        command: ?[]const u8 = null,
        query: ?[*:0]const u8 = null,
        dmenu: bool = false,
        prompt: ?[]const u8 = null,
        extension_job: ?enum { install, update, uninstall } = null,
        /// The repository to install, or the extension to update or remove.
        extension_name: ?[]const u8 = null,
        install_as: ?[]const u8 = null,
    };
};

/// `args` (without the program's name) as a Request; null when they are
/// not a valid command line. Pure: it neither reads nor changes the UI.
fn parseRequest(args: []const [:0]const u8) ?Request {
    var window: Request.Window = .{};
    var arg_index: usize = 0;
    while (arg_index < args.len) : (arg_index += 1) {
        const flag = cli.parse(args[arg_index]) orelse return null;
        const value: [:0]const u8 = switch (cli.specs.get(flag).value) {
            .none => "",
            .required => value: {
                if (arg_index + 1 == args.len) return null;
                arg_index += 1;
                break :value args[arg_index];
            },
            // An optional value is taken only when the next argument is
            // not itself a flag ("--update --quit" updates every extension).
            .optional => value: {
                if (arg_index + 1 == args.len) break :value "";
                if (std.mem.startsWith(u8, args[arg_index + 1], "-")) break :value "";
                arg_index += 1;
                break :value args[arg_index];
            },
        };
        switch (flag) {
            .dump => return .{ .now = .dump },
            .key => return .{ .now = .{ .key = value } },
            .stats => return .{ .now = .stats },
            .text => return .{ .now = .{ .text = value } },
            .reload => return .{ .now = .reload },
            .help => return .{ .now = .help },
            // What `lumen --version` compares with its own.
            .version => return .{ .now = .version },
            .quit => return .{ .now = .quit },
            .clip_store => return .{ .now = .clip_store },
            .install => {
                window.extension_job = .install;
                window.extension_name = value;
            },
            .uninstall => {
                window.extension_job = .uninstall;
                window.extension_name = value;
            },
            .update => {
                window.extension_job = .update;
                // The name is optional: without it, every git extension.
                if (value.len > 0) window.extension_name = value;
            },
            .as => window.install_as = value,
            .dmenu => window.dmenu = true,
            .prompt => window.prompt = value,
            .command => window.command = value,
            .daemon => window.mode = .daemon,
            .show => window.mode = .show,
            .hide => window.mode = .hide,
            .toggle => window.mode = .toggle,
            .query => window.query = value.ptr,
            .view => {
                const view = std.meta.stringToEnum(Ui.View, value) orelse return null;
                // An extension's view opens with --command.
                if (view == .ext) return null;
                window.view = view;
            },
        }
    }
    return .{ .window = window };
}

fn run(args: []const [:0]const u8, reply: *const Reply) c_int {
    const request = parseRequest(args) orelse return usage(reply);
    return switch (request) {
        .now => |now| runNow(now, reply),
        .window => |window| runWindow(window, reply),
    };
}

fn runNow(now: Request.Now, reply: *const Reply) c_int {
    switch (now) {
        .help => return printed(reply.print(cli.usage)),
        .version => return printed(reply.print(version_line)),
        .quit => {
            c.g_application_quit(daemon.app);
            return status_ok;
        },
        .clip_store => {
            storeClip(reply.payload orelse return usage(reply));
            return status_ok;
        },
        else => {},
    }
    const ui = readyUi() orelse return status_failed;
    switch (now) {
        .dump => {
            const text = ui.dump(ui.gpa) catch return status_failed;
            defer ui.gpa.free(text);
            return printed(reply.print(text));
        },
        .stats => {
            const text = stats.report(ui.gpa, ui.files, ui.contents) catch return status_failed;
            defer ui.gpa.free(text);
            return printed(reply.print(text));
        },
        .key => |key| {
            if (!ui.injectKey(key)) return usage(reply);
            return status_ok;
        },
        .text => |text| {
            c.gtk_editable_set_text(@ptrCast(ui.entry), text.ptr);
            return status_ok;
        },
        .reload => {
            Ui.ext_view.reload(ui);
            return status_ok;
        },
        .help, .version, .quit, .clip_store => unreachable,
    }
}

fn printed(ok: bool) c_int {
    return if (ok) status_ok else status_failed;
}

fn runWindow(window: Request.Window, reply: *const Reply) c_int {
    const ui = readyUi() orelse return status_failed;
    if (window.extension_job != null or window.dmenu) {
        const command_line = reply.command_line orelse {
            reply.printErr("lumen: --dmenu and installs go through lumen-gtk\n");
            return status_failed;
        };
        // The job or the dmenu session holds `command_line` until it ends.
        if (window.extension_job) |job| {
            switch (job) {
                .install => {
                    const url = window.extension_name.?;
                    Ui.installer.install(ui, command_line, url, window.install_as);
                },
                .update => Ui.installer.update(ui, command_line, window.extension_name),
                .uninstall => Ui.installer.uninstall(ui, command_line, window.extension_name.?),
            }
        } else {
            Ui.dmenu.start(ui, command_line, window.prompt, window.query);
        }
        return status_answered_later;
    }
    if (window.command) |command_id| {
        if (Ui.ext_view.openTarget(ui, command_id, window.query)) return status_ok;
        var buf: [256]u8 = undefined;
        const id_shown = command_id[0..@min(command_id.len, 200)];
        const message = std.mem.printSentinel(
            &buf,
            "lumen: no command \"{s}\"\n",
            .{id_shown},
            0,
        ) catch "lumen: no such command\n";
        reply.printErr(message);
        return status_failed;
    }
    // A view or a query always means "show me this".
    const show = window.view != null or window.query != null;
    switch (if (show) .show else window.mode) {
        .daemon => {},
        .hide => ui.hide(),
        .show => ui.showWith(window.view orelse .root, window.query),
        .toggle => ui.toggle(),
    }
    return status_ok;
}

fn usage(reply: *const Reply) c_int {
    reply.printErr(cli.usage);
    return status_usage;
}

fn shutdownCallback(_: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    daemon.shutting_down = true;
    ipc_server.stop();
    const watcher = &daemon.clipboard_watcher;
    if (watcher.running()) _ = c.kill(watcher.pid, c.SIGTERM);
    const ui = readyUi() orelse return;
    Ui.ext_view.shutdown(ui);
    // Saves what the index learned this session, so it is there tomorrow.
    if (ui.content_search) |content_search| {
        ui.content_search = null;
        content_search.shutdown();
    }
    if (ui.contents) |content_service| {
        ui.contents = null;
        content_service.shutdown();
    }
    if (ui.files) |file_service| {
        ui.files = null;
        file_service.shutdown();
    }
}

/// Content results a query shows at most.
const content_results_max = 50;

/// $HOME, indexed in the background; searchable at once from the mapped
/// snapshot in $XDG_CACHE_HOME/lumen/files.idx.
fn startFileIndex(ui: *Ui) void {
    const home = std.mem.span(c.g_get_home_dir());
    const cache_home = std.mem.span(c.g_get_user_cache_dir());
    var buf: [4096]u8 = undefined;
    const index_path = std.mem.print(&buf, "{s}/lumen/files.idx", .{cache_home}) catch return;
    const file_service = index.Service.start(ui.gpa, ui.io, home, index_path) catch |err| {
        log.warn("file index: {t}", .{err});
        return;
    };
    ui.files = file_service;
    const cache_dir = std.mem.print(&buf, "{s}/lumen", .{cache_home}) catch return;
    // The content index borrows thread pools the file index keeps for it:
    // sharing the file index's own froze the UI behind content work. It
    // asks the file index (`names`) whether a full listing is needed again.
    const content_service = index.ContentService.startWith(
        ui.gpa,
        ui.io,
        home,
        cache_dir,
        file_service.contentPools(),
        .{ .names = file_service },
    ) catch |err| {
        log.warn("content index: {t}", .{err});
        return;
    };
    ui.contents = content_service;
    // Without it, content queries run on the UI thread (still correct).
    ui.content_search = Ui.ContentSearch.start(
        ui.gpa,
        ui.io,
        content_service,
        content_results_max,
        &Ui.onContentResult,
        ui,
    ) catch |err| blk: {
        log.warn("content search worker: {t}", .{err});
        break :blk null;
    };
}

fn dbPath() ?[*:0]u8 {
    const dir = c.g_build_filename(c.g_get_user_data_dir(), "lumen", @as(?*const anyopaque, null));
    defer c.g_free(dir);
    if (c.g_mkdir_with_parents(dir, 0o700) != 0) return null;
    // Owner-only even if it already existed (made by hand or by another
    // tool); one that is not ours stays as it is (EPERM).
    _ = std.os.linux.chmod(dir, 0o700);
    return c.g_build_filename(dir, "lumen.db", @as(?*const anyopaque, null));
}

/// `wl-paste --watch lumen --clip-store`: one short-lived process per copy.
/// The watcher dies with us (PR_SET_PDEATHSIG) so restarts never pile up.
/// DO_NOT_REAP_CHILD matters: without it GLib double-forks, the watcher's
/// parent is a helper that exits at once, and the death signal fires.
fn startClipboardWatcher() void {
    const watcher = &daemon.clipboard_watcher;
    assert(!watcher.running());
    const self_exe = c.g_file_read_link("/proc/self/exe", null) orelse return;
    defer c.g_free(self_exe);
    var client_buffer: [4096]u8 = undefined;
    var argv = [_:null]?[*:0]const u8{
        "wl-paste",
        "--type",
        "text",
        "--watch",
        clipboardClientPath(&client_buffer, self_exe),
        "--clip-store",
    };
    var err: ?*c.GError = null;
    if (c.g_spawn_async(
        null,
        @ptrCast(&argv),
        null,
        c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_DO_NOT_REAP_CHILD,
        &dieWithParent,
        null,
        &watcher.pid,
        &err,
    ) == 0) {
        proc.warnError(.main, err, "clipboard watcher", .{});
        return;
    }
    assert(watcher.running());
    watcher.started_ns = stats.now();
    _ = c.g_child_watch_add(watcher.pid, &clipboardWatcherExitCallback, null);
}

/// Prefer the small `lumen` client beside this binary: wl-paste runs it
/// once per copy, and lumen-gtk would load GTK each time.
fn clipboardClientPath(buf: []u8, self_exe: [*:0]const u8) [*:0]const u8 {
    const self_dir = std.Io.Dir.path.dirname(std.mem.span(self_exe)) orelse "/";
    const client = std.mem.printSentinel(buf, "{s}/lumen", .{self_dir}, 0) catch return self_exe;
    if (std.os.linux.access(client.ptr, std.os.linux.X_OK) != 0) return self_exe;
    return client.ptr;
}

fn clipboardWatcherExitCallback(pid: c.GPid, status: c_int, _: ?*anyopaque) callconv(.c) void {
    c.g_spawn_close_pid(pid);
    const watcher = &daemon.clipboard_watcher;
    if (pid == watcher.pid) watcher.pid = 0;
    // Stopped on purpose: shutting down, or history turned off.
    if (daemon.shutting_down) return;
    const ui = readyUi() orelse return;
    if (!ui.settings.clipboard) return;
    if (stats.now() - watcher.started_ns > ClipboardWatcher.healthy_after_ns) {
        watcher.backoff_ms = ClipboardWatcher.backoff_ms_min;
    }
    log.warn(
        "clipboard watcher exited ({d}); restarting in {d} ms",
        .{ status, watcher.backoff_ms },
    );
    _ = c.g_timeout_add(watcher.backoff_ms, &clipboardWatcherRestartCallback, null);
    watcher.backoff_ms = @min(watcher.backoff_ms * 2, ClipboardWatcher.backoff_ms_max);
}

fn clipboardWatcherRestartCallback(_: ?*anyopaque) callconv(.c) c.gboolean {
    // Meanwhile Settings may have turned the history off, or on again
    // (which started a watcher of its own).
    if (daemon.shutting_down) return 0;
    if (daemon.clipboard_watcher.running()) return 0;
    const ui = readyUi() orelse return 0;
    if (ui.settings.clipboard) startClipboardWatcher();
    return 0;
}

/// Clipboard History on/off in Settings starts or stops the watcher.
fn settingsChangedCallback() void {
    if (c.g_getenv(ipc.env.test_mode) != null) return;
    if (daemon.shutting_down) return;
    const ui = readyUi() orelse return;
    const watcher = &daemon.clipboard_watcher;
    if (ui.settings.clipboard) {
        if (!watcher.running()) {
            watcher.backoff_ms = ClipboardWatcher.backoff_ms_min;
            startClipboardWatcher();
        }
    } else {
        if (watcher.running()) _ = c.kill(watcher.pid, c.SIGTERM);
    }
}

fn dieWithParent(_: ?*anyopaque) callconv(.c) void {
    _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGTERM));
}

fn prewarmCallback(_: ?*anyopaque) callconv(.c) c.gboolean {
    if (readyUi()) |ui| ui.prewarm();
    return 0;
}

fn testWatchdogCallback(_: ?*anyopaque) callconv(.c) c.gboolean {
    log.warn("test instance alive for {d} s: quitting", .{test_instance_lifetime_s});
    c.g_application_quit(daemon.app);
    return 0;
}

/// Stores a copy handed over the socket by `lumen --clip-store`.
fn storeClip(content: []const u8) void {
    const ui = readyUi() orelse return;
    if (!ui.settings.clipboard) return;
    if (!std.unicode.utf8ValidateSlice(content)) return;
    ui.db.addClip(content, nowSeconds(), ui.settings.clipboard_keep) catch |err| {
        log.warn("clipboard: {t}", .{err});
    };
}

/// `lumen-gtk --clip-store`, when no daemon took the copy: straight into the
/// database.
fn clipStore(init: std.process.Init) !void {
    // wl-clipboard tells us about password managers and cleared selections.
    if (init.environ_map.get(ipc.env.clipboard_state)) |state| {
        if (!ipc.keepsCopy(state)) return;
    }
    var buf: [16 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &buf);
    // Larger copies are not kept (images, huge selections).
    const content = stdin.interface.allocRemaining(
        init.gpa,
        .limited(Db.clip_bytes_max),
    ) catch |err| switch (err) {
        error.StreamTooLong => return,
        error.ReadFailed => return stdin.err.?,
        else => |e| return e,
    };
    defer init.gpa.free(content);
    if (!std.unicode.utf8ValidateSlice(content)) return;

    // History off in Settings (a copy can race the watcher being stopped).
    var settings_path_buffer: [4096]u8 = undefined;
    const settings_path = try std.mem.printSentinel(
        &settings_path_buffer,
        "{s}/lumen/settings.conf",
        .{std.mem.span(c.g_get_user_config_dir())},
        0,
    );
    var settings = Settings.load(init.gpa, settings_path);
    defer settings.deinit();
    if (!settings.clipboard) return;

    const path = dbPath() orelse return error.DataDir;
    defer c.g_free(path);
    var db = try Db.open(std.mem.span(path));
    defer db.close();
    try db.addClip(content, nowSeconds(), settings.clipboard_keep);
}

test "requests: flags in order, values, and what is refused" {
    const expectEqual = std.testing.expectEqual;
    const window = parseRequest(&.{ "--view", "clipboard", "--query", "foo" }).?.window;
    try expectEqual(Ui.View.clipboard, window.view.?);
    try std.testing.expectEqualStrings("foo", std.mem.span(window.query.?));

    // A flag answered at once ends the parse: what follows is not read.
    try std.testing.expect(parseRequest(&.{ "--dump", "--view", "nope" }).?.now == .dump);
    // An optional value is not the next flag: --update alone, then --quit.
    try std.testing.expect(parseRequest(&.{ "--update", "--quit" }).?.now == .quit);
    const update = parseRequest(&.{ "--update", "notes" }).?.window;
    try std.testing.expectEqualStrings("notes", update.extension_name.?);

    try std.testing.expect(parseRequest(&.{"--bogus"}) == null);
    try std.testing.expect(parseRequest(&.{"--key"}) == null);
    try std.testing.expect(parseRequest(&.{ "--view", "ext" }) == null);
    try std.testing.expect(parseRequest(&.{ "--view", "nope", "--dump" }) == null);
    try std.testing.expect(parseRequest(&.{}).?.window.mode == .toggle);
}

test {
    _ = @import("ipc.zig");
    _ = @import("sys/Db.zig");
    _ = @import("sys/proc.zig");
    _ = @import("sys/ipc_server.zig");
    _ = @import("sys/hypr.zig");
    _ = @import("ui/Ui.zig");
    _ = @import("ui/labels.zig");
    _ = @import("ui/widgets.zig");
    _ = @import("ui/settings_view.zig");
    _ = @import("ui/file_results.zig");
    _ = @import("ui/detail_pane.zig");
    _ = @import("ui/backdrop.zig");
    _ = @import("ui/keyboard.zig");
    _ = @import("actions.zig");
    _ = @import("settings.zig");
    _ = @import("ui/themes.zig");
}

test {
    _ = @import("ui/logos.zig");
    _ = @import("cli.zig");
    _ = @import("ext/api.zig");
    _ = @import("ext/Host.zig");
    _ = @import("ui/ext_view.zig");
    _ = @import("ui/installer.zig");
    _ = @import("layout.zig");
    _ = @import("providers/scripts.zig");
    _ = @import("stats.zig");
}

test "the views the usage lists open" {
    var views = std.mem.tokenizeAny(u8, cli.views, ", \n");
    while (views.next()) |view| {
        try std.testing.expect(std.meta.stringToEnum(Ui.View, view) != null);
    }
}
