//! Lumen — a native launcher for Linux.
//!
//!   lumen              toggle the window (starts the daemon if needed)
//!   lumen --daemon     start hidden (for `exec-once`)
//!   lumen --show | --hide | --quit
//!   lumen --stats      memory, index and latency numbers of the running daemon
//!   lumen --view clipboard --query foo   open a view, prefilled
//!   lumen --clip-store  internal: `wl-paste --watch` hands a copy on stdin

const std = @import("std");
const c = @import("c");
const Db = @import("sys/db.zig").Db;
const Ui = @import("ui/Ui.zig");
const index = @import("index");
const stats = @import("stats.zig");
const Settings = @import("settings.zig").Settings;

pub const std_options: std.Options = .{ .log_level = .info };

/// LUMEN_APP_ID lets end-to-end tests run a second, isolated instance
/// (GApplication is single-instance per id).
const default_app_id = "dev.osmait.Lumen";

var ui: Ui = undefined;
var ui_ready = false;
var watcher_pid: c.GPid = 0;
var io_global: std.Io = undefined;

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
    io_global = init.io;
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(init.gpa);
    var it = init.minimal.args.iterate();
    while (it.next()) |arg| try argv.append(init.gpa, arg.ptr);

    if (argv.items.len > 1 and std.mem.eql(u8, std.mem.span(argv.items[1].?), "--clip-store")) {
        return clipStore(init);
    }

    const app_id: [*:0]const u8 = c.g_getenv("LUMEN_APP_ID") orelse default_app_id;
    // Commands that only talk to a running daemon must not become one: with
    // none running GApplication makes the caller the primary instance, so
    // `lumen --stats` would start a whole new daemon and never return. As a
    // launcher it never takes the bus name either (taking it even briefly
    // made a daemon starting at the same moment fail to register).
    const client_only = argv.items.len > 1 and clientOnly(std.mem.span(argv.items[1].?));
    const flags = c.G_APPLICATION_HANDLES_COMMAND_LINE | if (client_only) c.G_APPLICATION_IS_LAUNCHER else 0;
    const app = c.gtk_application_new(app_id, flags);
    defer c.g_object_unref(app);
    Ui.connect(app, "startup", &onStartup, null);
    Ui.connect(app, "command-line", &onCommandLine, null);
    Ui.connect(app, "shutdown", &onShutdown, null);

    if (client_only) {
        if (c.g_application_register(@ptrCast(app), null, null) == 0 or c.g_application_get_is_remote(@ptrCast(app)) == 0) {
            std.debug.print("lumen is not running\n", .{});
            std.process.exit(1);
        }
    }
    const status = c.g_application_run(@ptrCast(app), @intCast(argv.items.len), @ptrCast(argv.items.ptr));
    std.process.exit(@intCast(status));
}

/// Runs once, in the primary instance.
fn onStartup(app: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const path = dbPath() orelse {
        std.log.err("cannot create the data directory", .{});
        return;
    };
    defer c.g_free(path);
    const db = Db.open(std.mem.span(path)) catch {
        std.log.err("cannot open {s}", .{path});
        return;
    };
    ui = Ui.init(std.heap.c_allocator, app, db);
    ui.build();
    ui.on_settings_changed = &onSettingsChanged;
    ui_ready = true;
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
    stats.startup_ns = stats.now() - stats.started_ns;
}

/// Every invocation (the first one and the ones that follow) lands here.
fn onCommandLine(app: *c.GApplication, cmdline: *c.GApplicationCommandLine, _: ?*anyopaque) callconv(.c) c_int {
    var argc: c_int = 0;
    const args = c.g_application_command_line_get_arguments(cmdline, &argc);
    defer c.g_strfreev(@ptrCast(args));

    var mode: enum { toggle, show, hide, daemon } = .toggle;
    var view: ?Ui.View = null;
    var query: ?[*:0]const u8 = null;
    var i: usize = 1;
    while (i < argc) : (i += 1) {
        const a = std.mem.span(args[i]);
        const next: ?[*:0]const u8 = if (i + 1 < argc) args[i + 1] else null;
        if (std.mem.eql(u8, a, "--dump")) {
            if (!ui_ready) return 1;
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const text = ui.dump(arena.allocator()) catch return 1;
            c.g_application_command_line_print(cmdline, "%s", text.ptr);
            return 0;
        } else if (std.mem.eql(u8, a, "--key") and next != null) {
            if (!ui_ready) return 1;
            if (!ui.injectKey(std.mem.span(next.?))) return usage(cmdline);
            return 0;
        } else if (std.mem.eql(u8, a, "--stats")) {
            if (!ui_ready) return 1;
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const text = stats.report(arena.allocator(), ui.files, ui.contents) catch return 1;
            c.g_application_command_line_print(cmdline, "%s", text.ptr);
            return 0;
        } else if (std.mem.eql(u8, a, "--quit")) {
            c.g_application_quit(app);
            return 0;
        } else if (std.mem.eql(u8, a, "--daemon")) {
            mode = .daemon;
        } else if (std.mem.eql(u8, a, "--show")) {
            mode = .show;
        } else if (std.mem.eql(u8, a, "--hide")) {
            mode = .hide;
        } else if (std.mem.eql(u8, a, "--toggle")) {
            mode = .toggle;
        } else if (std.mem.eql(u8, a, "--query") and next != null) {
            query = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--view") and next != null) {
            view = std.meta.stringToEnum(Ui.View, std.mem.span(next.?)) orelse return usage(cmdline);
            i += 1;
        } else return usage(cmdline);
    }
    if (!ui_ready) return 1;
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

fn clientOnly(flag: []const u8) bool {
    const flags = [_][]const u8{ "--dump", "--key", "--stats", "--hide", "--quit" };
    for (flags) |f| if (std.mem.eql(u8, flag, f)) return true;
    return false;
}

fn usage(cmdline: *c.GApplicationCommandLine) c_int {
    c.g_application_command_line_printerr(cmdline,
        \\usage: lumen [--toggle | --show | --hide | --daemon | --quit | --stats | --dump]
        \\             [--key down|up|enter|ctrl+enter|ctrl+k|escape|backspace|pagedown|pageup|ctrl+x|ctrl+o]
        \\             [--view root|clipboard|windows|files|contents|settings|themes|default_apps]
        \\             [--query TEXT]
        \\
    );
    return 2;
}

fn onShutdown(_: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    shutting_down = true;
    if (watcher_pid != 0) _ = c.kill(watcher_pid, c.SIGTERM);
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
    const cache = std.fmt.bufPrint(&buf, "{s}/lumen/files.idx", .{std.mem.span(c.g_get_user_cache_dir())}) catch return;
    ui.files = index.Service.start(std.heap.c_allocator, io_global, home, cache) catch |err| {
        std.log.warn("file index: {s}", .{@errorName(err)});
        return;
    };
    // The content index shares the file index's thread pools.
    const files = ui.files.?;
    const cache_dir = std.fmt.bufPrint(&buf, "{s}/lumen", .{std.mem.span(c.g_get_user_cache_dir())}) catch return;
    ui.contents = index.ContentService.start(std.heap.c_allocator, io_global, home, cache_dir, files.search_pool, files.scan_pool) catch |err| {
        std.log.warn("content index: {s}", .{@errorName(err)});
        return;
    };
    ui.content_search = Ui.ContentSearch.start(std.heap.c_allocator, io_global, ui.contents.?, 50, &Ui.onContentResult, &ui) catch null;
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
    var argv = [_:null]?[*:0]const u8{ "wl-paste", "--type", "text", "--watch", self_exe, "--clip-store" };
    var err: ?*c.GError = null;
    if (c.g_spawn_async(null, @ptrCast(&argv), null, c.G_SPAWN_SEARCH_PATH | c.G_SPAWN_DO_NOT_REAP_CHILD, &dieWithParent, null, &watcher_pid, &err) == 0) {
        if (err) |e| {
            std.log.warn("clipboard watcher: {s}", .{e.message});
            c.g_error_free(e);
        }
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
    std.log.warn("clipboard watcher exited ({d}); restarting in {d} ms", .{ status, watcher_backoff_ms });
    _ = c.g_timeout_add(watcher_backoff_ms, &restartWatcher, null);
    watcher_backoff_ms = @min(watcher_backoff_ms * 2, 60_000);
}

fn testWatchdog(app: ?*anyopaque) callconv(.c) c.gboolean {
    std.log.warn("test instance alive for 5 minutes: quitting", .{});
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

/// Reads one clipboard copy from stdin and stores it.
fn clipStore(init: std.process.Init) !void {
    // wl-clipboard tells us about password managers and cleared selections.
    if (init.environ_map.get("CLIPBOARD_STATE")) |state| {
        if (!std.mem.eql(u8, state, "data")) return;
    }
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(init.gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (data.items.len <= Db.max_bytes) {
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) break;
        try data.appendSlice(init.gpa, buf[0..@intCast(n)]);
    }
    if (data.items.len > Db.max_bytes) return;
    if (!std.unicode.utf8ValidateSlice(data.items)) return;

    // History off in Settings (a copy can race the watcher being stopped).
    var cbuf: [4096]u8 = undefined;
    const conf = try std.fmt.bufPrintZ(&cbuf, "{s}/lumen/settings.conf", .{std.mem.span(c.g_get_user_config_dir())});
    var settings = Settings.load(init.gpa, conf);
    defer settings.deinit();
    if (!settings.clipboard) return;

    const path = dbPath() orelse return error.DataDir;
    defer c.g_free(path);
    var db = try Db.open(std.mem.span(path));
    defer db.close();
    db.addClip(data.items, @divTrunc(c.g_get_real_time(), std.time.us_per_s), settings.clipboard_keep);
}

test {
    _ = @import("sys/db.zig");
    _ = @import("sys/hypr.zig");
    _ = @import("ui/Ui.zig");
    _ = @import("actions.zig");
    _ = @import("settings.zig");
    _ = @import("ui/themes.zig");
}

test {
    _ = @import("ui/logos.zig");
}
