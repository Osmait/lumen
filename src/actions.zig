//! What each action does to the system. The UI decides what happens to the
//! window afterwards from the returned `Outcome`.

const std = @import("std");
const c = @import("c");
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const Db = @import("sys/Db.zig");
const proc = @import("sys/proc.zig");
const hypr = @import("sys/hypr.zig");
const core = @import("core");
const settings_mod = @import("settings.zig");
const Settings = settings_mod.Settings;

const log = std.log.scoped(.actions);

pub const Outcome = union(enum) {
    hide,
    stay,
    refresh_view,
    open_view: item_mod.View,
    /// The UI owns the settings: it applies these.
    setting: struct { setting: item_mod.Setting, op: item_mod.Op },
    /// Show the apps that can open this file.
    choose_app: [:0]const u8,
    /// It did not work: the UI says so on the row and stays.
    failed: [:0]const u8,
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    db: *Db,
    settings: *const Settings,
};

pub fn perform(ctx: Ctx, it: *const Item, op: item_mod.Op) Outcome {
    switch (op) {
        .open, .run => return primary(ctx, it),
        .open_with => if (it.action == .file) return .{ .choose_app = it.action.file.path },
        .always_use => if (it.action == .setting) return .{ .setting = .{ .setting = it.action.setting, .op = op } },
        .copy_name => copy(it.title),
        .copy_path => switch (it.action) {
            .app => |info| {
                const dai: *c.GDesktopAppInfo = @ptrCast(info);
                if (c.g_desktop_app_info_get_filename(dai)) |f| copy(std.mem.span(f));
            },
            .file => |f| copy(f.path),
            else => {},
        },
        .show_in_folder => if (it.action == .file) showInFolder(ctx, it.action.file.path),
        .open_at_line => if (it.action == .file) openAtLine(ctx, it.action.file.path, it.action.file.line),
        .copy_file => if (it.action == .file) copyFile(ctx, it.action.file.path),
        .trash => if (it.action == .file) {
            const f = c.g_file_new_for_path(it.action.file.path);
            defer c.g_object_unref(f);
            var err: ?*c.GError = null;
            if (c.g_file_trash(f, null, &err) == 0) {
                if (err) |e| {
                    log.warn("trash {s}: {s}", .{ it.action.file.path, e.message });
                    c.g_error_free(e);
                }
                return .{ .failed = "Could not move it to the trash" };
            }
            return .refresh_view;
        },
        .reset_ranking => {
            ctx.db.forget(it.key) catch return .{ .failed = "Could not reset the ranking" };
            return .stay;
        },
        .focus => focusWindow(ctx, it),
        .close_window => {
            if (it.action == .focus_window) {
                var buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, "closewindow address:{s}", .{it.action.focus_window}) catch return .stay;
                hypr.dispatch(ctx.gpa, cmd);
            }
            return .refresh_view;
        },
        .clip_paste => {
            // Recency only: the paste goes ahead even if this fails.
            ctx.db.touchClip(it.action.clip, now()) catch {};
            pasteText(it.detail);
        },
        .clip_copy => {
            ctx.db.touchClip(it.action.clip, now()) catch {};
            copy(it.detail);
        },
        .clip_delete => {
            ctx.db.deleteClip(it.action.clip) catch return .{ .failed = "Could not delete the entry" };
            return .refresh_view;
        },
        .clip_clear => {
            ctx.db.clearClips() catch return .{ .failed = "Could not clear the history" };
            return .refresh_view;
        },
        .calc_copy => copy(it.detail),
        .calc_paste => pasteText(it.detail),
    }
    return .hide;
}

fn primary(ctx: Ctx, it: *const Item) Outcome {
    switch (it.action) {
        .app => |info| launch(info),
        .view => |v| return .{ .open_view = v },
        .system => |s| system(ctx, s),
        .layout => |l| hypr.applyLayout(ctx.gpa, l),
        .window_op => |w| windowOp(ctx, w),
        .focus_window => focusWindow(ctx, it),
        .clip => {
            ctx.db.touchClip(it.action.clip, now()) catch {};
            pasteText(it.detail);
        },
        .script => |s| runScript(s.path, s.mode, it.title),
        .calc => copy(it.detail),
        .file => |f| openFile(ctx, f.path, f.is_dir),
        .setting => |s| return .{ .setting = .{ .setting = s, .op = .run } },
    }
    return .hide;
}

/// Opens with the app chosen in Settings > Default Apps for the file's
/// extension or kind, else the system default for its type (directories in
/// the file manager).
pub fn openFile(ctx: Ctx, path: [:0]const u8, is_dir: bool) void {
    const slash = std.mem.findScalarLast(u8, path, '/');
    const name = if (slash) |s| path[s + 1 ..] else path;
    const mime = if (is_dir) null else c.g_content_type_guess(path, null, 0, null);
    defer if (mime) |m| c.g_free(m);
    const kind = core.file_kind.of(if (mime) |m| std.mem.span(m) else "", name, is_dir);
    var ebuf: [16]u8 = undefined;
    const ext = if (is_dir) "" else core.file_kind.extKey(&ebuf, name);
    if (ctx.settings.appFor(ext, kind)) |app| {
        var idbuf: [256]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&idbuf, "{s}", .{app}, 0) catch "";
        if (openWith(path, id)) return;
        // Uninstalled since it was chosen: the system default still works.
        log.warn("open with {s}: app not found, using the default", .{app});
    }
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const lctx = c.gdk_display_get_app_launch_context(c.gdk_display_get_default() orelse return);
    defer c.g_object_unref(lctx);
    _ = c.g_app_info_launch_default_for_uri(uri, @ptrCast(lctx), null);
}

/// Opens `path` with the app whose desktop file id is `app_id`; false when
/// there is no such app.
pub fn openWith(path: [:0]const u8, app_id: [:0]const u8) bool {
    const dai = c.g_desktop_app_info_new(app_id) orelse return false;
    defer c.g_object_unref(dai);
    const uri = c.g_filename_to_uri(path, null, null) orelse return false;
    defer c.g_free(uri);
    const uris = c.g_list_append(null, uri);
    defer c.g_list_free(uris);
    const lctx = c.gdk_display_get_app_launch_context(c.gdk_display_get_default() orelse return false);
    defer c.g_object_unref(lctx);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch_uris(@ptrCast(dai), uris, @ptrCast(lctx), &err) == 0) {
        if (err) |e| {
            log.warn("open with {s}: {s}", .{ app_id, e.message });
            c.g_error_free(e);
        }
    }
    return true;
}

/// The editor from Settings (else $VISUAL/$EDITOR, else nvim) at `line`:
/// GUI editors directly, terminal ones inside the terminal from Settings
/// (else $TERMINAL, else the first one installed).
fn openAtLine(ctx: Ctx, path: [:0]const u8, line: u32) void {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const editor = a.dupeSentinel(u8, resolveEditor(ctx.settings), 0) catch return;
    var argv: std.ArrayList([:0]const u8) = .empty;
    const cmd = editorCommand(a, editor, path, line) catch return;
    if (cmd.in_terminal) argv.appendSlice(a, terminalPrefix(a, resolveTerminal(ctx.settings)) catch return) catch return;
    argv.appendSlice(a, cmd.argv) catch return;
    proc.spawn(argv.items);
}

fn resolveEditor(s: *const Settings) []const u8 {
    return if (s.editor.len > 0) s.editor else autoEditor();
}

/// What "Automatic" means for the editor: $VISUAL, $EDITOR, else nvim.
pub fn autoEditor() [:0]const u8 {
    const env = c.g_getenv("VISUAL") orelse c.g_getenv("EDITOR");
    return if (env) |e| std.mem.span(e) else "nvim";
}

fn resolveTerminal(s: *const Settings) [:0]const u8 {
    for (settings_mod.terminals) |t| if (std.mem.eql(u8, t[0], s.terminal)) return t[0];
    return autoTerminal();
}

/// What "Automatic" means for the terminal: $TERMINAL, else the first one
/// installed.
pub fn autoTerminal() [:0]const u8 {
    if (c.g_getenv("TERMINAL")) |t| return std.mem.span(t);
    for (settings_mod.terminals) |t| if (proc.have(t[0])) return t[0];
    return "xterm";
}

pub const EditorCommand = struct { argv: []const [:0]const u8, in_terminal: bool };

/// How each editor is told to open a file at a line.
pub fn editorCommand(a: std.mem.Allocator, editor: [:0]const u8, path: [:0]const u8, line: u32) std.mem.Allocator.Error!EditorCommand {
    const base = if (std.mem.findScalarLast(u8, editor, '/')) |s| editor[s + 1 ..] else editor;
    const at = try std.fmt.allocPrintSentinel(a, "{s}:{d}", .{ path, line }, 0);
    const plus = try std.fmt.allocPrintSentinel(a, "+{d}", .{line}, 0);
    const n = try std.fmt.allocPrintSentinel(a, "{d}", .{line}, 0);
    const is = struct {
        fn any(x: []const u8, names: []const []const u8) bool {
            for (names) |name| if (std.mem.eql(u8, x, name)) return true;
            return false;
        }
    }.any;
    if (is(base, &.{ "code", "codium", "code-oss" })) return .{ .argv = try a.dupe([:0]const u8, &.{ editor, "-g", at }), .in_terminal = false };
    if (is(base, &.{ "zed", "zeditor", "subl" })) return .{ .argv = try a.dupe([:0]const u8, &.{ editor, at }), .in_terminal = false };
    if (is(base, &.{"kate"})) return .{ .argv = try a.dupe([:0]const u8, &.{ editor, "-l", n, path }), .in_terminal = false };
    if (is(base, &.{ "gedit", "gnome-text-editor", "emacs" })) return .{ .argv = try a.dupe([:0]const u8, &.{ editor, plus, path }), .in_terminal = false };
    if (is(base, &.{ "hx", "helix", "micro" })) return .{ .argv = try a.dupe([:0]const u8, &.{ editor, at }), .in_terminal = true };
    // vi, vim, nvim, nano, and anything unknown: `+LINE path` in a terminal.
    return .{ .argv = try a.dupe([:0]const u8, &.{ editor, plus, path }), .in_terminal = true };
}

/// The words that make a terminal run a command (most take `-e`), in `a`.
pub fn terminalPrefix(a: std.mem.Allocator, term: [:0]const u8) std.mem.Allocator.Error![]const [:0]const u8 {
    const base = if (std.mem.findScalarLast(u8, term, '/')) |s| term[s + 1 ..] else term;
    if (std.mem.eql(u8, base, "kitty") or std.mem.eql(u8, base, "foot")) return a.dupe([:0]const u8, &.{term});
    if (std.mem.eql(u8, base, "wezterm")) return a.dupe([:0]const u8, &.{ term, "start", "--" });
    if (std.mem.eql(u8, base, "gnome-terminal")) return a.dupe([:0]const u8, &.{ term, "--" });
    return a.dupe([:0]const u8, &.{ term, "-e" });
}

/// The file manager, with the file selected (org.freedesktop.FileManager1,
/// spoken by Dolphin, Nautilus, Thunar...).
fn showInFolder(ctx: Ctx, path: [:0]const u8) void {
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const arg = std.fmt.allocPrintSentinel(ctx.gpa, "['{s}']", .{uri}, 0) catch return;
    defer ctx.gpa.free(arg);
    proc.spawn(&.{ "gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1", "--object-path", "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowItems", arg, "" });
}

/// Puts the file itself on the clipboard (paste it in a file manager or a
/// chat), as a text/uri-list.
fn copyFile(ctx: Ctx, path: [:0]const u8) void {
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const list = std.fmt.allocPrint(ctx.gpa, "{s}\r\n", .{uri}) catch return;
    defer ctx.gpa.free(list);
    proc.pipeTo(&.{ "wl-copy", "--type", "text/uri-list" }, list);
}

fn launch(info: *c.GAppInfo) void {
    const ctx = c.gdk_display_get_app_launch_context(c.gdk_display_get_default() orelse return);
    defer c.g_object_unref(ctx);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch(info, null, @ptrCast(ctx), &err) == 0) {
        if (err) |e| {
            log.warn("launch: {s}", .{e.message});
            c.g_error_free(e);
        }
    }
}

fn focusWindow(ctx: Ctx, it: *const Item) void {
    var buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "focuswindow address:{s}", .{it.action.focus_window}) catch return;
    hypr.dispatch(ctx.gpa, cmd);
}

fn system(ctx: Ctx, s: item_mod.System) void {
    switch (s) {
        .lock => if (proc.have("hyprlock")) proc.spawn(&.{"hyprlock"}) else proc.spawn(&.{ "loginctl", "lock-session" }),
        .sleep => proc.spawn(&.{ "systemctl", "suspend" }),
        .restart => proc.spawn(&.{ "systemctl", "reboot" }),
        .shutdown => proc.spawn(&.{ "systemctl", "poweroff" }),
        .logout => hypr.dispatch(ctx.gpa, "exit"),
        .volume_up => proc.spawn(&.{ "wpctl", "set-volume", "-l", "1.5", "@DEFAULT_AUDIO_SINK@", "5%+" }),
        .volume_down => proc.spawn(&.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-" }),
        .volume_mute => proc.spawn(&.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" }),
        .mic_mute => proc.spawn(&.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" }),
        .play_pause => proc.spawn(&.{ "playerctl", "play-pause" }),
        .next_track => proc.spawn(&.{ "playerctl", "next" }),
        .prev_track => proc.spawn(&.{ "playerctl", "previous" }),
        .toggle_dark => proc.shell(
            \\k=org.gnome.desktop.interface
            \\if gsettings get $k color-scheme | grep -q dark; then
            \\  gsettings set $k color-scheme default
            \\else
            \\  gsettings set $k color-scheme prefer-dark
            \\fi
        ),
        .empty_trash => proc.spawn(&.{ "gio", "trash", "--empty" }),
    }
}

/// Window commands act on the active window: Lumen's overlay does not take
/// that role from the client, so it is still the window the user came from.
fn windowOp(ctx: Ctx, op: item_mod.WindowOp) void {
    hypr.dispatch(ctx.gpa, switch (op) {
        .toggle_floating => "togglefloating",
        .toggle_fullscreen => "fullscreen 0",
        .toggle_maximize => "fullscreen 1",
        .pin => "pin",
        .close => "killactive",
        .next_workspace => "workspace e+1",
        .prev_workspace => "workspace e-1",
        .move_next_monitor => "movewindow mon:+1",
    });
}

fn runScript(path: [:0]const u8, mode: @import("core").script_meta.Mode, title: []const u8) void {
    if (mode == .silent) {
        proc.spawn(&.{path});
        return;
    }
    // Other modes show the output: last lines as a desktop notification.
    var buf: [512:0]u8 = undefined;
    const t = std.fmt.bufPrintSentinel(&buf, "{s}", .{title}, 0) catch "Script";
    proc.spawn(&.{
        "sh",           "-c",
        \\out=$("$1" 2>&1); notify-send -a Lumen "$2" "$(printf '%s' "$out" | tail -n 5)"
        ,
        "lumen-script", path,
        t,
    });
}

/// Copies `text` with wl-copy (it keeps serving the selection after we hide).
pub fn copy(text: []const u8) void {
    proc.pipeTo(&.{"wl-copy"}, text);
}

/// Copies, then sends Ctrl+V to whatever gets focus once the window hides.
fn pasteText(text: []const u8) void {
    copy(text);
    _ = c.g_timeout_add(120, &sendPaste, null);
}

/// Runs once Lumen has hidden and the previous window has focus again: that
/// window decides the chord (terminals paste with Ctrl+Shift+V; Ctrl+V there
/// is a literal ^V or a terminal's own binding).
fn sendPaste(_: ?*anyopaque) callconv(.c) c.gboolean {
    // hyprctl's answer for one window is a few KB; larger and it is parsed
    // as unknown, which pastes with Ctrl+V.
    var buf: [64 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const class = if (hypr.activeWindow(fba.allocator())) |w| w.class else "";
    switch (pasteChord(class)) {
        .ctrl_v => proc.spawn(&.{ "wtype", "-M", "ctrl", "-k", "v", "-m", "ctrl" }),
        .ctrl_shift_v => proc.spawn(&.{ "wtype", "-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl" }),
    }
    return 0;
}

pub const Chord = enum { ctrl_v, ctrl_shift_v };

/// Terminal emulators by Wayland app id / window class (lowercased match).
pub fn pasteChord(class: []const u8) Chord {
    const terminals = [_][]const u8{ "ghostty", "kitty", "alacritty", "foot", "wezterm", "konsole", "terminal", "console", "xterm", "terminator", "tilix", "urxvt", "st-256color", "rio", "contour", "blackbox" };
    var buf: [128]u8 = undefined;
    if (class.len > buf.len) return .ctrl_v;
    const lower = std.ascii.lowerString(&buf, class);
    for (terminals) |t| if (std.mem.find(u8, lower, t) != null) return .ctrl_shift_v;
    return .ctrl_v;
}

test "editors open at a line, terminal ones inside a terminal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const []const u8, bool };
    const cases = [_]Case{
        .{ "nvim", &.{ "nvim", "+12", "/x/a.zig" }, true },
        .{ "/usr/bin/vim", &.{ "/usr/bin/vim", "+12", "/x/a.zig" }, true },
        .{ "hx", &.{ "hx", "/x/a.zig:12" }, true },
        .{ "code", &.{ "code", "-g", "/x/a.zig:12" }, false },
        .{ "zed", &.{ "zed", "/x/a.zig:12" }, false },
        .{ "kate", &.{ "kate", "-l", "12", "/x/a.zig" }, false },
        .{ "gnome-text-editor", &.{ "gnome-text-editor", "+12", "/x/a.zig" }, false },
    };
    for (cases) |case| {
        const ed = try a.dupeSentinel(u8, case[0], 0);
        const cmd = try editorCommand(a, ed, "/x/a.zig", 12);
        try std.testing.expectEqual(case[2], cmd.in_terminal);
        try std.testing.expectEqual(case[1].len, cmd.argv.len);
        for (case[1], cmd.argv) |want, got| try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectEqualStrings("start", (try terminalPrefix(a, "wezterm"))[1]);
    try std.testing.expectEqual(@as(usize, 1), (try terminalPrefix(a, "kitty")).len);
    try std.testing.expectEqualStrings("-e", (try terminalPrefix(a, "ghostty"))[1]);
}

test "terminals get Ctrl+Shift+V, everything else Ctrl+V" {
    try std.testing.expectEqual(Chord.ctrl_shift_v, pasteChord("com.mitchellh.ghostty"));
    try std.testing.expectEqual(Chord.ctrl_shift_v, pasteChord("kitty"));
    try std.testing.expectEqual(Chord.ctrl_shift_v, pasteChord("Alacritty"));
    try std.testing.expectEqual(Chord.ctrl_shift_v, pasteChord("org.wezfurlong.wezterm"));
    try std.testing.expectEqual(Chord.ctrl_shift_v, pasteChord("org.gnome.Console"));
    try std.testing.expectEqual(Chord.ctrl_v, pasteChord("discord"));
    try std.testing.expectEqual(Chord.ctrl_v, pasteChord("brave-browser"));
    try std.testing.expectEqual(Chord.ctrl_v, pasteChord(""));
}

fn now() i64 {
    return @divTrunc(c.g_get_real_time(), std.time.us_per_s);
}
