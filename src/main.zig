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

pub const std_options: std.Options = .{
    .log_level = .info,
    // A 256 KB alternate signal stack in every thread's TLS (GTK's, the
    // driver's too: ~8 MB), only for stack traces on stack overflow.
    .signal_stack_size = null,
};

const log = std.log.scoped(.main);
const proc = @import("sys/proc.zig");

// The daemon's state, reached from GLib callbacks; main thread only.
var ui: Ui = undefined;
var the_app: *c.GApplication = undefined;
/// LUMEN_APP_ID lets end-to-end tests run a second, isolated instance
/// (GApplication is single-instance per id; the socket is per id too).
var app_id: [:0]const u8 = ipc.default_app_id;
var ui_ready = false;
var watcher_pid: c.GPid = 0;

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
    var it = init.minimal.args.iterate();
    while (it.next()) |arg| try argv.append(init.gpa, arg.ptr);

    if (argv.items.len > 1 and cli.parse(std.mem.span(argv.items[1].?)) == .clip_store) {
        return clipStore(init);
    }
    // Never a reason to start or ask a daemon.
    for (argv.items[1..]) |arg| if (cli.parse(std.mem.span(arg.?)) == .help) {
        std.Io.File.stdout().writeStreamingAll(init.io, cli.usage) catch {};
        return;
    };

    if (c.g_getenv("LUMEN_APP_ID")) |id| app_id = std.mem.span(id);
    // Commands that only talk to a running daemon must not become one: with
    // none running GApplication makes the caller the primary instance, so
    // `lumen --stats` would start a whole new daemon and never return. As a
    // launcher it never takes the bus name either (taking it even briefly
    // made a daemon starting at the same moment fail to register).
    const client_only = argv.items.len > 1 and if (cli.parse(std.mem.span(argv.items[1].?))) |f|
        cli.specs.get(f).needs_daemon
    else
        false;
    const launcher = if (client_only) c.G_APPLICATION_IS_LAUNCHER else 0;
    const flags = c.G_APPLICATION_HANDLES_COMMAND_LINE | launcher;
    const app = c.gtk_application_new(app_id.ptr, flags);
    the_app = @ptrCast(app);
    defer c.g_object_unref(app);
    // Zig's default in ReleaseSafe is a checking allocator over mmap (every
    // allocation of 6 KB or more a fresh mapping); glibc's, tuned above, is
    // what the measurements were made with. Debug builds keep the checks.
    const gpa = if (builtin.mode == .debug) init.gpa else std.heap.c_allocator;
    var start: Start = .{ .gpa = gpa, .io = init.io };
    Ui.connect(app, "startup", &onStartup, &start);
    Ui.connect(app, "command-line", &onCommandLine, null);
    Ui.connect(app, "shutdown", &onShutdown, null);

    if (client_only) {
        if (c.g_application_register(
            @ptrCast(app),
            null,
            null,
        ) == 0 or c.g_application_get_is_remote(@ptrCast(app)) == 0)
            std.process.fatal("lumen is not running", .{});
    }
    const argc = std.math.cast(c_int, argv.items.len) orelse std.process.fatal(
        "too many arguments",
        .{},
    );
    const status = c.g_application_run(@ptrCast(app), argc, @ptrCast(argv.items.ptr));
    std.process.exit(std.math.cast(u8, status) orelse 1);
}

/// Runs once, in the primary instance.
fn onStartup(app: *c.GtkApplication, data: ?*anyopaque) callconv(.c) void {
    const start: *const Start = @ptrCast(@alignCast(data.?));
    const path = dbPath() orelse {
        log.err("cannot create the data directory", .{});
        return;
    };
    defer c.g_free(path);
    var db = Db.open(std.mem.span(path)) catch |err| {
        log.err("cannot open {s}: {t}", .{ path, err });
        return;
    };
    db.pruneFrecency(@divTrunc(c.g_get_real_time(), std.time.us_per_s)) catch {};
    ui = Ui.init(start.gpa, start.io, app, db);
    ui.build();
    ui.on_settings_changed = &onSettingsChanged;
    ui_ready = true;
    Ui.ext_view.start(&ui);
    c.g_application_hold(@ptrCast(app));
    // Tests feed the clipboard store directly (`--clip-store`).
    if (c.g_getenv("LUMEN_TEST") == null) {
        if (ui.settings.clipboard) startClipboardWatcher();
    } else {
        // A test instance takes no keyboard, so nobody can close it by hand:
        // if its script dies, it must not stay on screen. Five minutes is
        // far beyond any test run.
        _ = c.g_timeout_add_seconds(300, &testWatchdog, app);
    }
    startFileIndex();
    // `lumen` (src/client.zig) reaches us here without loading GTK.
    ipc_server.start(start.gpa, app_id, &onSocket);
    // Once the main loop runs, so starting is not slower.
    _ = c.g_idle_add(&prewarm, null);
    stats.startup_ns = stats.now() - stats.started_ns;
}

/// Where a command's answer goes: the GApplication client that ran it, or
/// the socket `lumen` asked through.
const Out = struct {
    cmdline: ?*c.GApplicationCommandLine = null,
    out: ?*std.Io.Writer = null,
    err: ?*std.Io.Writer = null,
    /// What followed the arguments on the socket (a copy, --clip-store).
    payload: ?[]const u8 = null,

    fn print(o: *const Out, text: [:0]const u8) void {
        if (o.cmdline) |cl| c.g_application_command_line_print(
            cl,
            "%s",
            text.ptr,
        ) else if (o.out) |w| w.writeAll(text) catch {};
    }

    fn printErr(o: *const Out, text: [:0]const u8) void {
        if (o.cmdline) |cl| c.g_application_command_line_printerr(
            cl,
            "%s",
            text.ptr,
        ) else if (o.err) |w| w.writeAll(text) catch {};
    }
};

/// Every invocation through GApplication (the first one, and those `lumen`
/// hands to lumen-gtk) lands here.
fn onCommandLine(
    app: *c.GApplication,
    cmdline: *c.GApplicationCommandLine,
    _: ?*anyopaque,
) callconv(.c) c_int {
    var argc: c_int = 0;
    const argv = c.g_application_command_line_get_arguments(cmdline, &argc);
    defer c.g_strfreev(argv);
    var args: [ipc.max_args][:0]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 1;
    while (i < argc and n < args.len) : (i += 1) {
        args[n] = std.mem.span(argv[i] orelse continue);
        n += 1;
    }
    return run(app, args[0..n], &.{ .cmdline = cmdline });
}

/// Every invocation through the socket.
fn onSocket(
    args: []const [:0]const u8,
    payload: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) u8 {
    const status = run(the_app, args, &.{ .out = out, .err = err, .payload = payload });
    return std.math.cast(u8, status) orelse 1;
}

/// `args` without the program's name.
fn run(app: *c.GApplication, args: []const [:0]const u8, out: *const Out) c_int {
    var mode: enum { toggle, show, hide, daemon } = .toggle;
    var view: ?Ui.View = null;
    var command: ?[]const u8 = null;
    var pick = false;
    var prompt: ?[]const u8 = null;
    var job: ?enum { install, update, uninstall } = null;
    var job_arg: ?[]const u8 = null;
    var as: ?[]const u8 = null;
    var query: ?[*:0]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = cli.parse(args[i]) orelse return usage(out);
        const value: [:0]const u8 = switch (cli.specs.get(flag).value) {
            .none => "",
            .required => if (i + 1 < args.len) v: {
                i += 1;
                break :v args[i];
            } else return usage(out),
            // Not the next flag.
            .optional => if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) v: {
                i += 1;
                break :v args[i];
            } else "",
        };
        switch (flag) {
            .dump => {
                if (!ui_ready) return 1;
                const text = ui.dump(ui.gpa) catch return 1;
                defer ui.gpa.free(text);
                out.print(text);
                return 0;
            },
            .key => {
                if (!ui_ready) return 1;
                if (!ui.injectKey(value)) return usage(out);
                return 0;
            },
            .stats => {
                if (!ui_ready) return 1;
                const text = stats.report(ui.gpa, ui.files, ui.contents) catch return 1;
                defer ui.gpa.free(text);
                out.print(text);
                return 0;
            },
            .text => {
                // Types into the search bar of the view shown (tests).
                if (!ui_ready) return 1;
                c.gtk_editable_set_text(@ptrCast(ui.entry), value.ptr);
                return 0;
            },
            .reload => {
                if (!ui_ready) return 1;
                Ui.ext_view.reload(&ui);
                return 0;
            },
            .help => {
                out.print(cli.usage);
                return 0;
            },
            .install => {
                job = .install;
                job_arg = value;
            },
            .uninstall => {
                job = .uninstall;
                job_arg = value;
            },
            .update => {
                job = .update;
                // The name is optional: without it, every git extension.
                if (value.len > 0) job_arg = value;
            },
            .as => as = value,
            .dmenu => pick = true,
            .prompt => prompt = value,
            .command => command = value,
            .quit => {
                c.g_application_quit(app);
                return 0;
            },
            .daemon => mode = .daemon,
            .show => mode = .show,
            .hide => mode = .hide,
            .toggle => mode = .toggle,
            .query => query = value.ptr,
            .view => {
                view = std.meta.stringToEnum(Ui.View, value) orelse return usage(out);
                if (view == .ext) return usage(out);
            },
            .clip_store => {
                storeClip(out.payload orelse return usage(out));
                return 0;
            },
        }
    }
    if (!ui_ready) return 1;
    // Answered later, through the GApplication client (lumen-gtk).
    const cmdline = out.cmdline orelse if (job != null or pick) {
        out.printErr("lumen: --dmenu and installs go through lumen-gtk\n");
        return 1;
    } else null;
    if (job) |j| {
        // The answer comes when git is done; the job holds `cmdline`.
        switch (j) {
            .install => Ui.installer.install(&ui, cmdline, job_arg.?, as),
            .update => Ui.installer.update(&ui, cmdline, job_arg),
            .uninstall => Ui.installer.uninstall(&ui, cmdline, job_arg.?),
        }
        return 1;
    }
    if (pick) {
        // The answer comes later: the session keeps `cmdline` until then.
        Ui.dmenu.start(&ui, cmdline.?, prompt, query);
        return 1;
    }
    if (command) |id| {
        if (Ui.ext_view.openTarget(&ui, id, query)) return 0;
        var buf: [256]u8 = undefined;
        out.printErr(
            std.mem.printSentinel(
                &buf,
                "lumen: no command \"{s}\"\n",
                .{id[0..@min(id.len, 200)]},
                0,
            ) catch "lumen: no such command\n",
        );
        return 1;
    }
    // A view or a query always means "show me this".
    if (view != null or query != null) mode = .show;
    switch (mode) {
        .daemon => {},
        .hide => ui.hide(),
        .show => ui.showWith(view orelse .root, query),
        .toggle => ui.toggle(),
    }
    return 0;
}

fn usage(out: *const Out) c_int {
    out.printErr(cli.usage);
    return 2;
}

fn onShutdown(_: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    shutting_down = true;
    ipc_server.stop();
    if (watcher_pid != 0) _ = c.kill(watcher_pid, c.SIGTERM);
    if (ui_ready) Ui.ext_view.shutdown(&ui);
    // Saves what the index learned this session, so it is there tomorrow.
    if (ui_ready) if (ui.content_search) |w| {
        ui.content_search = null;
        w.shutdown();
    };
    if (ui_ready) if (ui.contents) |cs| {
        ui.contents = null;
        cs.shutdown();
    };
    if (ui_ready) if (ui.files) |f| {
        ui.files = null;
        f.shutdown();
    };
}

/// $HOME, indexed in the background; searchable at once from the mapped
/// snapshot in $XDG_CACHE_HOME/lumen/files.idx.
fn startFileIndex() void {
    const home = std.mem.span(c.g_get_home_dir());
    var buf: [4096]u8 = undefined;
    const cache = std.mem.print(&buf, "{s}/lumen/files.idx", .{
        std.mem.span(c.g_get_user_cache_dir()),
    }) catch return;
    ui.files = index.Service.start(ui.gpa, ui.io, home, cache) catch |err| {
        log.warn("file index: {t}", .{err});
        return;
    };
    // The content index shares the file index's thread pools.
    const files = ui.files.?;
    const cache_dir = std.mem.print(&buf, "{s}/lumen", .{
        std.mem.span(c.g_get_user_cache_dir()),
    }) catch return;
    // The name index tells it when listing every file again is needed.
    ui.contents = index.ContentService.startWith(
        ui.gpa,
        ui.io,
        home,
        cache_dir,
        .{ .search = files.search_pool, .build = files.scan_pool },
        .{ .names = files },
    ) catch |err| {
        log.warn("content index: {t}", .{err});
        return;
    };
    // Without it, content queries run on the UI thread (still correct).
    ui.content_search = Ui.ContentSearch.start(
        ui.gpa,
        ui.io,
        ui.contents.?,
        50,
        &Ui.onContentResult,
        &ui,
    ) catch |err| blk: {
        log.warn("content search worker: {t}", .{err});
        break :blk null;
    };
}

fn dbPath() ?[*:0]u8 {
    const dir = c.g_build_filename(c.g_get_user_data_dir(), "lumen", @as(?*const anyopaque, null));
    defer c.g_free(dir);
    if (c.g_mkdir_with_parents(dir, 0o700) != 0) return null;
    return c.g_build_filename(dir, "lumen.db", @as(?*const anyopaque, null));
}

/// `wl-paste --watch lumen --clip-store`: one short-lived process per copy.
/// The watcher dies with us (PR_SET_PDEATHSIG) so restarts never pile up.
/// DO_NOT_REAP_CHILD matters: without it GLib double-forks, the watcher's
/// parent is a helper that exits at once, and the death signal fires.
fn startClipboardWatcher() void {
    const self_exe = c.g_file_read_link("/proc/self/exe", null) orelse return;
    defer c.g_free(self_exe);
    // `lumen` beside us hands each copy over without loading GTK.
    var buf: [4096]u8 = undefined;
    const client = if (std.mem.printSentinel(
        &buf,
        "{s}/lumen",
        .{std.Io.Dir.path.dirname(std.mem.span(self_exe)) orelse "/"},
        0,
    )) |p|
        (if (std.os.linux.access(p.ptr, std.os.linux.X_OK) == 0) p.ptr else self_exe)
    else |_|
        self_exe;
    var argv = [_:null]?[*:0]const u8{
        "wl-paste",
        "--type",
        "text",
        "--watch",
        client,
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
        &watcher_pid,
        &err,
    ) == 0) {
        proc.warnError(.main, err, "clipboard watcher", .{});
        return;
    }
    watcher_started_ns = stats.now();
    _ = c.g_child_watch_add(watcher_pid, &onWatcherExit, null);
}

var shutting_down = false;
var watcher_started_ns: u64 = 0;
var watcher_backoff_ms: c_uint = 1000;

/// The watcher can die (wl-paste losing the compositor, a crash): without a
/// restart the history silently stopped growing. Back off 1, 2, 4... up to
/// 60 s so a permanent failure does not spin; a watcher that lived a minute
/// resets the backoff.
fn onWatcherExit(pid: c.GPid, status: c_int, _: ?*anyopaque) callconv(.c) void {
    c.g_spawn_close_pid(pid);
    if (pid == watcher_pid) watcher_pid = 0;
    // Stopped on purpose: shutting down, or history turned off.
    if (shutting_down or !ui.settings.clipboard) return;
    if (stats.now() - watcher_started_ns > 60 * std.time.ns_per_s) watcher_backoff_ms = 1000;
    log.warn(
        "clipboard watcher exited ({d}); restarting in {d} ms",
        .{ status, watcher_backoff_ms },
    );
    _ = c.g_timeout_add(watcher_backoff_ms, &restartWatcher, null);
    watcher_backoff_ms = @min(watcher_backoff_ms * 2, 60_000);
}

fn prewarm(_: ?*anyopaque) callconv(.c) c.gboolean {
    if (ui_ready) ui.prewarm();
    return 0;
}

fn testWatchdog(app: ?*anyopaque) callconv(.c) c.gboolean {
    log.warn("test instance alive for 5 minutes: quitting", .{});
    c.g_application_quit(@ptrCast(app.?));
    return 0;
}

fn restartWatcher(_: ?*anyopaque) callconv(.c) c.gboolean {
    if (!shutting_down and watcher_pid == 0 and ui.settings.clipboard) startClipboardWatcher();
    return 0;
}

/// Clipboard History on/off in Settings starts or stops the watcher.
fn onSettingsChanged() void {
    if (c.g_getenv("LUMEN_TEST") != null or shutting_down) return;
    if (ui.settings.clipboard) {
        if (watcher_pid == 0) {
            watcher_backoff_ms = 1000;
            startClipboardWatcher();
        }
    } else if (watcher_pid != 0) _ = c.kill(watcher_pid, c.SIGTERM);
}

fn dieWithParent(_: ?*anyopaque) callconv(.c) void {
    _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGTERM));
}

/// Stores a copy handed over the socket by `lumen --clip-store`.
fn storeClip(content: []const u8) void {
    if (!ui_ready or !ui.settings.clipboard) return;
    if (!std.unicode.utf8ValidateSlice(content)) return;
    ui.db.addClip(
        content,
        @divTrunc(c.g_get_real_time(), std.time.us_per_s),
        ui.settings.clipboard_keep,
    ) catch |err|
        log.warn("clipboard: {t}", .{err});
}

/// `lumen-gtk --clip-store`, when no daemon took the copy: straight into the
/// database.
fn clipStore(init: std.process.Init) !void {
    // wl-clipboard tells us about password managers and cleared selections.
    if (init.environ_map.get("CLIPBOARD_STATE")) |state| {
        if (!std.mem.eql(u8, state, "data")) return;
    }
    var buf: [16 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &buf);
    // Larger copies are not kept (images, huge selections).
    const content = stdin.interface.allocRemaining(
        init.gpa,
        .limited(Db.max_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => return,
        error.ReadFailed => return stdin.err.?,
        else => |e| return e,
    };
    defer init.gpa.free(content);
    if (!std.unicode.utf8ValidateSlice(content)) return;

    // History off in Settings (a copy can race the watcher being stopped).
    var cbuf: [4096]u8 = undefined;
    const conf = try std.mem.printSentinel(
        &cbuf,
        "{s}/lumen/settings.conf",
        .{std.mem.span(c.g_get_user_config_dir())},
        0,
    );
    var settings = Settings.load(init.gpa, conf);
    defer settings.deinit();
    if (!settings.clipboard) return;

    const path = dbPath() orelse return error.DataDir;
    defer c.g_free(path);
    var db = try Db.open(std.mem.span(path));
    defer db.close();
    try db.addClip(
        content,
        @divTrunc(c.g_get_real_time(), std.time.us_per_s),
        settings.clipboard_keep,
    );
}

test {
    _ = @import("ipc.zig");
    _ = @import("sys/Db.zig");
    _ = @import("sys/proc.zig");
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
}

test "the views the usage lists open" {
    var it = std.mem.tokenizeAny(u8, cli.views, ", \n");
    while (it.next()) |v| try std.testing.expect(std.meta.stringToEnum(Ui.View, v) != null);
}
