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
const assert = std.debug.assert;

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

/// Runs `op` on `it`. `item.actionsFor` offers each operation only on the
/// rows it applies to (file operations on files, clipboard ones on
/// clipboard entries): an operation on another row is a bug, asserted.
pub fn perform(ctx: Ctx, it: *const Item, op: item_mod.Op) Outcome {
    switch (op) {
        .open, .run => return primary(ctx, it),
        .open_with => return .{ .choose_app = fileOf(it).path },
        .always_use => {
            assert(it.action == .setting);
            return .{ .setting = .{ .setting = it.action.setting, .op = op } };
        },
        .copy_name => copy(it.title),
        .copy_path => switch (it.action) {
            .app => |info| {
                const dai: *c.GDesktopAppInfo = @ptrCast(info);
                if (c.g_desktop_app_info_get_filename(dai)) |f| copy(std.mem.span(f));
            },
            .file => |f| copy(f.path),
            else => {},
        },
        .show_in_folder => showInFolder(fileOf(it).path),
        .open_at_line => openAtLine(ctx, fileOf(it).path, fileOf(it).line),
        .copy_file => copyFile(ctx, fileOf(it).path),
        .trash => return trash(fileOf(it).path),
        .reset_ranking => {
            ctx.db.forget(it.key) catch return .{ .failed = "Could not reset the ranking" };
            return .stay;
        },
        .focus => focusWindow(ctx, it),
        .close_window => {
            assert(it.action == .focus_window);
            const address = it.action.focus_window;
            var buf: [64]u8 = undefined;
            const cmd = std.mem.print(&buf, "closewindow address:{s}", .{address}) catch
                return .stay;
            hypr.dispatch(ctx.gpa, cmd);
            return .refresh_view;
        },
        .clip_paste => {
            touchClip(ctx, it);
            pasteText(it.detail);
        },
        .clip_copy => {
            touchClip(ctx, it);
            copy(it.detail);
        },
        .clip_delete => {
            assert(it.action == .clip);
            ctx.db.deleteClip(it.action.clip) catch return .{
                .failed = "Could not delete the entry",
            };
            return .refresh_view;
        },
        .clip_clear => {
            ctx.db.clearClips() catch return .{ .failed = "Could not clear the history" };
            return .refresh_view;
        },
        .calc_copy, .copy_detail => copy(it.detail),
        .calc_paste => pasteText(it.detail),
        // The UI runs extension actions (ext_view.zig) and dmenu answers.
        .ext, .pick_typed => return .stay,
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
            touchClip(ctx, it);
            pasteText(it.detail);
        },
        .script => |s| runScript(s.path, s.mode, it.title),
        .calc => copy(it.detail),
        .file => |f| openFile(ctx, f.path, f.is_dir),
        .setting => |s| return .{ .setting = .{ .setting = s, .op = .run } },
        // The UI runs extension commands (ext_view.zig).
        .ext_command, .ext_item, .pick => return .stay,
        .ext_problem => copy(it.detail),
    }
    return .hide;
}

/// The file a file operation acts on.
fn fileOf(it: *const Item) @FieldType(item_mod.Action, "file") {
    assert(it.action == .file);
    return it.action.file;
}

/// Marks a clipboard entry as just used. Recency only: the paste or copy
/// goes ahead even if this fails, and Db logs the failure.
fn touchClip(ctx: Ctx, it: *const Item) void {
    assert(it.action == .clip);
    ctx.db.touchClip(it.action.clip, now()) catch {};
}

fn trash(path: [:0]const u8) Outcome {
    const file = c.g_file_new_for_path(path);
    defer c.g_object_unref(file);
    var err: ?*c.GError = null;
    if (c.g_file_trash(file, null, &err) == 0) {
        proc.warnError(.actions, err, "trash {s}", .{path});
        return .{ .failed = "Could not move it to the trash" };
    }
    return .refresh_view;
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
        const id = std.mem.printSentinel(&idbuf, "{s}", .{app}, 0) catch "";
        if (openWith(path, id)) return;
        // Uninstalled since it was chosen: the system default still works.
        log.warn("open with {s}: app not found, using the default", .{app});
    }
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const lctx = proc.launchContext() orelse return;
    defer c.g_object_unref(lctx);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch_default_for_uri(uri, lctx, &err) == 0)
        proc.warnError(.actions, err, "open {s}", .{path});
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
    const lctx = proc.launchContext() orelse return false;
    defer c.g_object_unref(lctx);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch_uris(@ptrCast(dai), uris, lctx, &err) == 0)
        proc.warnError(.actions, err, "open with {s}", .{app_id});
    return true;
}

/// The editor from Settings (else $VISUAL/$EDITOR, else nvim) at `line`:
/// GUI editors directly, terminal ones inside the terminal from Settings
/// (else $TERMINAL, else the first one installed).
fn openAtLine(ctx: Ctx, path: [:0]const u8, line: u32) void {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const editor = words(a, resolveEditor(ctx.settings)) catch return;
    var argv: std.ArrayList([:0]const u8) = .empty;
    const cmd = editorCommand(a, editor, path, line) catch return;
    if (cmd.in_terminal) argv.appendSlice(
        a,
        terminalPrefix(a, words(a, resolveTerminal(ctx.settings)) catch return) catch return,
    ) catch return;
    argv.appendSlice(a, cmd.argv) catch return;
    proc.spawn(argv.items);
}

/// A command's words, split as a shell would (quotes, backslashes) though
/// no shell runs it: $EDITOR is often `code --wait` or `emacsclient -t`.
/// Text that does not split (an open quote) is one word, as before. In `a`.
pub fn words(a: std.mem.Allocator, cmd: []const u8) std.mem.Allocator.Error![]const [:0]const u8 {
    const z = try a.dupeSentinel(u8, cmd, 0);
    var argv: ?[*]?[*:0]u8 = null;
    if (c.g_shell_parse_argv(z, null, &argv, null) == 0) return a.dupe([:0]const u8, &.{z});
    defer c.g_strfreev(argv);
    var list: std.ArrayList([:0]const u8) = .empty;
    var i: usize = 0;
    while (argv.?[i]) |w| : (i += 1) try list.append(a, try a.dupeSentinel(u8, std.mem.span(w), 0));
    return list.items;
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

/// How each editor is told to open a file at a line. `editor` is the
/// command's words (the program and its own arguments).
pub fn editorCommand(
    a: std.mem.Allocator,
    editor: []const [:0]const u8,
    path: [:0]const u8,
    line: u32,
) std.mem.Allocator.Error!EditorCommand {
    const base = baseName(editor[0]);
    const at = try a.printSentinel("{s}:{d}", .{ path, line }, 0);
    const plus = try a.printSentinel("+{d}", .{line}, 0);
    const n = try a.printSentinel("{d}", .{line}, 0);
    const is = struct {
        fn any(x: []const u8, names: []const []const u8) bool {
            for (names) |name| if (std.mem.eql(u8, x, name)) return true;
            return false;
        }
    }.any;
    if (is(base, &.{ "code", "codium", "code-oss" })) return .{
        .argv = try std.mem.concat(a, [:0]const u8, &.{ editor, &.{ "-g", at } }),
        .in_terminal = false,
    };
    if (is(base, &.{ "zed", "zeditor", "subl" })) return .{
        .argv = try std.mem.concat(a, [:0]const u8, &.{ editor, &.{at} }),
        .in_terminal = false,
    };
    if (is(base, &.{"kate"})) return .{
        .argv = try std.mem.concat(a, [:0]const u8, &.{ editor, &.{ "-l", n, path } }),
        .in_terminal = false,
    };
    if (is(base, &.{ "gedit", "gnome-text-editor", "emacs" })) return .{
        .argv = try std.mem.concat(a, [:0]const u8, &.{ editor, &.{ plus, path } }),
        .in_terminal = false,
    };
    if (is(base, &.{ "hx", "helix", "micro" })) return .{
        .argv = try std.mem.concat(a, [:0]const u8, &.{ editor, &.{at} }),
        .in_terminal = true,
    };
    // vi, vim, nvim, nano, and anything unknown: `+LINE path` in a terminal.
    return .{
        .argv = try std.mem.concat(a, [:0]const u8, &.{ editor, &.{ plus, path } }),
        .in_terminal = true,
    };
}

/// The words that make a terminal run a command (most take `-e`), in `a`.
/// `term` is the terminal command's words.
pub fn terminalPrefix(
    a: std.mem.Allocator,
    term: []const [:0]const u8,
) std.mem.Allocator.Error![]const [:0]const u8 {
    const base = baseName(term[0]);
    const more: []const [:0]const u8 = if (std.mem.eql(u8, base, "kitty") or
        std.mem.eql(u8, base, "foot"))
        &.{}
    else if (std.mem.eql(u8, base, "wezterm"))
        &.{ "start", "--" }
    else if (std.mem.eql(u8, base, "gnome-terminal"))
        &.{"--"}
    else
        &.{"-e"};
    return std.mem.concat(a, [:0]const u8, &.{ term, more });
}

/// What follows the last slash of a program's path.
fn baseName(prog: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, prog, '/')) |s| prog[s + 1 ..] else prog;
}

/// The file manager, with the file selected (org.freedesktop.FileManager1,
/// spoken by Dolphin, Nautilus, Thunar...). The URI goes as a D-Bus value,
/// never through text a parser reads (a quote in a file name broke that).
fn showInFolder(path: [:0]const u8) void {
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const uris = [_][*:0]const u8{uri};
    const args = [_]*c.GVariant{ c.g_variant_new_strv(&uris, 1), c.g_variant_new_string("") };
    // Kept until the bus is there: the call takes it then.
    const params = c.g_variant_ref_sink(c.g_variant_new_tuple(&args, args.len));
    c.g_bus_get(c.G_BUS_TYPE_SESSION, null, &onSessionBus, params);
}

fn onSessionBus(_: ?*c.GObject, res: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const params: *c.GVariant = @ptrCast(data.?);
    defer c.g_variant_unref(params);
    var err: ?*c.GError = null;
    const bus = c.g_bus_get_finish(res, &err) orelse
        return proc.warnError(.actions, err, "show in folder", .{});
    defer c.g_object_unref(bus);
    c.g_dbus_connection_call(
        bus,
        "org.freedesktop.FileManager1",
        "/org/freedesktop/FileManager1",
        "org.freedesktop.FileManager1",
        "ShowItems",
        params,
        null,
        c.G_DBUS_CALL_FLAGS_NONE,
        -1,
        null,
        &onShown,
        null,
    );
}

fn onShown(source: ?*c.GObject, res: *c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    var err: ?*c.GError = null;
    const reply = c.g_dbus_connection_call_finish(@ptrCast(source.?), res, &err) orelse
        return proc.warnError(.actions, err, "show in folder", .{});
    c.g_variant_unref(reply);
}

/// Puts the file itself on the clipboard (paste it in a file manager or a
/// chat), as a text/uri-list.
fn copyFile(ctx: Ctx, path: [:0]const u8) void {
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const list = ctx.gpa.print("{s}\r\n", .{uri}) catch return;
    defer ctx.gpa.free(list);
    proc.pipeTo(&.{ "wl-copy", "--type", "text/uri-list" }, list);
}

fn launch(info: *c.GAppInfo) void {
    const ctx = proc.launchContext() orelse return;
    defer c.g_object_unref(ctx);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch(info, null, ctx, &err) == 0) proc.warnError(
        .actions,
        err,
        "launch",
        .{},
    );
}

fn focusWindow(ctx: Ctx, it: *const Item) void {
    assert(it.action == .focus_window);
    var buf: [64]u8 = undefined;
    const cmd = std.mem.print(
        &buf,
        "focuswindow address:{s}",
        .{it.action.focus_window},
    ) catch return;
    hypr.dispatch(ctx.gpa, cmd);
}

fn system(ctx: Ctx, s: item_mod.System) void {
    switch (s) {
        .lock => if (proc.have("hyprlock")) proc.spawn(&.{"hyprlock"}) else proc.spawn(
            &.{ "loginctl", "lock-session" },
        ),
        .sleep => proc.spawn(&.{ "systemctl", "suspend" }),
        .restart => proc.spawn(&.{ "systemctl", "reboot" }),
        .shutdown => proc.spawn(&.{ "systemctl", "poweroff" }),
        .logout => hypr.dispatch(ctx.gpa, "exit"),
        .volume_up => proc.spawn(&.{
            "wpctl",
            "set-volume",
            "-l",
            "1.5",
            "@DEFAULT_AUDIO_SINK@",
            "5%+",
        }),
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
    // After `--`, a title or an output line starting with "-" is text, not
    // an option of notify-send's.
    var buf: [512:0]u8 = undefined;
    const t = std.mem.printSentinel(&buf, "{s}", .{title}, 0) catch "Script";
    proc.spawn(&.{
        "sh",           "-c",
        \\out=$("$1" 2>&1); notify-send -a Lumen -- "$2" "$(printf '%s' "$out" | tail -n 5)"
        ,
        "lumen-script", path,
        t,
    });
}

/// Copies `text` with wl-copy (it keeps serving the selection after we hide).
pub fn copy(text: []const u8) void {
    proc.pipeTo(&.{"wl-copy"}, text);
}

/// Copies, then sends Ctrl+V to whatever gets focus once the window hides:
/// as soon as Hyprland says the focus moved (~2 ms), else after 120 ms.
pub fn pasteText(text: []const u8) void {
    copy(text);
    hypr.afterFocusChange(&pasteNow, 120);
}

fn pasteNow() void {
    _ = sendPaste(null);
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
        .ctrl_shift_v => proc.spawn(&.{
            "wtype",
            "-M",
            "ctrl",
            "-M",
            "shift",
            "-k",
            "v",
            "-m",
            "shift",
            "-m",
            "ctrl",
        }),
    }
    return 0;
}

pub const Chord = enum { ctrl_v, ctrl_shift_v };

/// Terminal emulators by Wayland app id / window class (lowercased match).
pub fn pasteChord(class: []const u8) Chord {
    const terminals = [_][]const u8{
        "ghostty",
        "kitty",
        "alacritty",
        "foot",
        "wezterm",
        "konsole",
        "terminal",
        "console",
        "xterm",
        "terminator",
        "tilix",
        "urxvt",
        "st-256color",
        "rio",
        "contour",
        "blackbox",
    };
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
        // $EDITOR with its own arguments, or a path with a space.
        .{ "code --wait", &.{ "code", "--wait", "-g", "/x/a.zig:12" }, false },
        .{ "emacsclient -t", &.{ "emacsclient", "-t", "+12", "/x/a.zig" }, true },
        .{ "'/opt/my vim/vim'", &.{ "/opt/my vim/vim", "+12", "/x/a.zig" }, true },
        // Does not split: one word, as it is.
        .{ "vim 'x", &.{ "vim 'x", "+12", "/x/a.zig" }, true },
    };
    for (cases) |case| {
        const cmd = try editorCommand(a, try words(a, case[0]), "/x/a.zig", 12);
        try std.testing.expectEqual(case[2], cmd.in_terminal);
        try std.testing.expectEqual(case[1].len, cmd.argv.len);
        for (case[1], cmd.argv) |want, got| try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectEqualStrings("start", (try terminalPrefix(a, &.{"wezterm"}))[1]);
    try std.testing.expectEqual(@as(usize, 1), (try terminalPrefix(a, &.{"kitty"})).len);
    try std.testing.expectEqualStrings("-e", (try terminalPrefix(a, &.{"ghostty"}))[1]);
    const kitty = try terminalPrefix(a, try words(a, "/usr/bin/kitty --single-instance"));
    try std.testing.expectEqual(@as(usize, 2), kitty.len);
    try std.testing.expectEqualStrings("--single-instance", kitty[1]);
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
