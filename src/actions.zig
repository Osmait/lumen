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

/// Runs `op` on `item`. `item.actionsFor` offers each operation only on the
/// rows item applies to (file operations on files, clipboard ones on
/// clipboard entries): an operation on another row is a bug, asserted.
pub fn perform(context: Ctx, item: *const Item, op: item_mod.Op) Outcome {
    switch (op) {
        .open, .run => return primary(context, item),
        .open_with => return .{ .choose_app = fileOf(item).path },
        .always_use => {
            assert(item.action == .setting);
            return .{ .setting = .{ .setting = item.action.setting, .op = op } };
        },
        .copy_name => copy(item.title),
        .copy_path => switch (item.action) {
            .app => |info| {
                const desktop_app_info: *c.GDesktopAppInfo = @ptrCast(info);
                if (c.g_desktop_app_info_get_filename(desktop_app_info)) |f| copy(std.mem.span(f));
            },
            .file => |f| copy(f.path),
            else => {},
        },
        .show_in_folder => showInFolder(fileOf(item).path),
        .open_at_line => openAtLine(context, fileOf(item).path, fileOf(item).line),
        .copy_file => copyFile(context, fileOf(item).path),
        .trash => return trash(fileOf(item).path),
        .reset_ranking => {
            context.db.forget(item.key) catch return .{ .failed = "Could not reset the ranking" };
            return .stay;
        },
        .focus => focusWindow(context, item),
        .close_window => {
            assert(item.action == .focus_window);
            const address = item.action.focus_window;
            var buf: [64]u8 = undefined;
            const cmd = std.mem.print(&buf, "closewindow address:{s}", .{address}) catch
                return .stay;
            hypr.dispatch(context.gpa, cmd);
            return .refresh_view;
        },
        .clip_paste => {
            touchClip(context, item);
            pasteText(item.detail);
        },
        .clip_copy => {
            touchClip(context, item);
            copy(item.detail);
        },
        .clip_delete => {
            assert(item.action == .clip);
            context.db.deleteClip(item.action.clip) catch return .{
                .failed = "Could not delete the entry",
            };
            return .refresh_view;
        },
        .clip_clear => {
            context.db.clearClips() catch return .{ .failed = "Could not clear the history" };
            return .refresh_view;
        },
        .calc_copy, .copy_detail => copy(item.detail),
        .calc_paste => pasteText(item.detail),
        // The UI runs extension actions (ext_view.zig) and dmenu answers.
        .ext, .pick_typed => return .stay,
    }
    return .hide;
}

fn primary(context: Ctx, item: *const Item) Outcome {
    switch (item.action) {
        .app => |info| launch(info),
        .view => |v| return .{ .open_view = v },
        .system => |s| system(context, s),
        .layout => |l| hypr.applyLayout(context.gpa, l),
        .window_op => |w| windowOp(context, w),
        .focus_window => focusWindow(context, item),
        .clip => {
            touchClip(context, item);
            pasteText(item.detail);
        },
        .script => |s| runScript(s.path, s.mode, item.title),
        .calc => copy(item.detail),
        .file => |f| openFile(context, f.path, f.is_dir),
        .setting => |s| return .{ .setting = .{ .setting = s, .op = .run } },
        // The UI runs extension commands (ext_view.zig).
        .ext_command, .ext_item, .pick => return .stay,
        .ext_problem => copy(item.detail),
    }
    return .hide;
}

/// The file a file operation acts on.
fn fileOf(item: *const Item) @FieldType(item_mod.Action, "file") {
    assert(item.action == .file);
    return item.action.file;
}

/// Marks a clipboard entry as just used. Recency only: the paste or copy
/// goes ahead even if this fails, and Db logs the failure.
fn touchClip(context: Ctx, item: *const Item) void {
    assert(item.action == .clip);
    context.db.touchClip(item.action.clip, now()) catch {};
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
pub fn openFile(context: Ctx, path: [:0]const u8, is_dir: bool) void {
    const name = baseName(path);
    const mime = if (is_dir) null else c.g_content_type_guess(path, null, 0, null);
    defer if (mime) |mime_type| c.g_free(mime_type);
    const mime_text = if (mime) |mime_type| std.mem.span(mime_type) else "";
    const kind = core.file_kind.of(mime_text, name, is_dir);
    var extension_buffer: [16]u8 = undefined;
    const extension_key = if (is_dir) "" else core.file_kind.extKey(&extension_buffer, name);
    if (context.settings.appFor(extension_key, kind)) |app| {
        var app_id_buffer: [256]u8 = undefined;
        const id = std.mem.printSentinel(&app_id_buffer, "{s}", .{app}, 0) catch "";
        if (openWith(path, id)) return;
        // Uninstalled since it was chosen: the system default still works.
        log.warn("open with {s}: app not found, using the default", .{app});
    }
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const launch_context = proc.launchContext() orelse return;
    defer c.g_object_unref(launch_context);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch_default_for_uri(uri, launch_context, &err) == 0) {
        proc.warnError(.actions, err, "open {s}", .{path});
    }
}

/// Opens `path` with the app whose desktop file id is `app_id`; false when
/// there is no such app.
pub fn openWith(path: [:0]const u8, app_id: [:0]const u8) bool {
    const desktop_app_info = c.g_desktop_app_info_new(app_id) orelse return false;
    defer c.g_object_unref(desktop_app_info);
    const uri = c.g_filename_to_uri(path, null, null) orelse return false;
    defer c.g_free(uri);
    const uris = c.g_list_append(null, uri);
    defer c.g_list_free(uris);
    const launch_context = proc.launchContext() orelse return false;
    defer c.g_object_unref(launch_context);
    const app_info: *c.GAppInfo = @ptrCast(desktop_app_info);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch_uris(app_info, uris, launch_context, &err) == 0) {
        proc.warnError(.actions, err, "open with {s}", .{app_id});
    }
    return true;
}

/// The editor from Settings (else $VISUAL/$EDITOR, else nvim) at `line`:
/// GUI editors directly, terminal ones inside the terminal from Settings
/// (else $TERMINAL, else the first one installed).
fn openAtLine(context: Ctx, path: [:0]const u8, line: u32) void {
    var arena_state: std.heap.ArenaAllocator = .init(context.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = openAtLineArgv(arena, context.settings, path, line) catch return;
    proc.spawn(argv);
}

fn openAtLineArgv(
    arena: std.mem.Allocator,
    settings: *const Settings,
    path: [:0]const u8,
    line: u32,
) std.mem.Allocator.Error![]const [:0]const u8 {
    const editor = try words(arena, resolveEditor(settings));
    const command = try editorCommand(arena, editor, path, line);
    if (!command.in_terminal) return command.argv;
    const terminal = try words(arena, resolveTerminal(settings));
    const prefix = try terminalPrefix(arena, terminal);
    return std.mem.concat(arena, [:0]const u8, &.{ prefix, command.argv });
}

/// A command's words, split as a shell would (quotes, backslashes) though
/// no shell runs it: $EDITOR is often `code --wait` or `emacsclient -t`.
/// Text that does not split (an open quote) is one word, as before. In
/// `arena`.
pub fn words(
    arena: std.mem.Allocator,
    command: []const u8,
) std.mem.Allocator.Error![]const [:0]const u8 {
    const command_z = try arena.dupeSentinel(u8, command, 0);
    var argv: ?[*]?[*:0]u8 = null;
    if (c.g_shell_parse_argv(command_z, null, &argv, null) == 0) {
        return arena.dupe([:0]const u8, &.{command_z});
    }
    defer c.g_strfreev(argv);
    var list: std.ArrayList([:0]const u8) = .empty;
    var word_index: usize = 0;
    while (argv.?[word_index]) |word| : (word_index += 1) {
        try list.append(arena, try arena.dupeSentinel(u8, std.mem.span(word), 0));
    }
    return list.items;
}

fn resolveEditor(settings: *const Settings) []const u8 {
    return if (settings.editor.len > 0) settings.editor else autoEditor();
}

/// What "Automatic" means for the editor: $VISUAL, $EDITOR, else nvim.
pub fn autoEditor() [:0]const u8 {
    const editor_env = c.g_getenv("VISUAL") orelse c.g_getenv("EDITOR");
    return if (editor_env) |editor_command| std.mem.span(editor_command) else "nvim";
}

fn resolveTerminal(settings: *const Settings) [:0]const u8 {
    for (settings_mod.terminals) |terminal| {
        const command = terminal[0];
        if (std.mem.eql(u8, command, settings.terminal)) return command;
    }
    return autoTerminal();
}

/// What "Automatic" means for the terminal: $TERMINAL, else the first one
/// installed.
pub fn autoTerminal() [:0]const u8 {
    if (c.g_getenv("TERMINAL")) |terminal| return std.mem.span(terminal);
    for (settings_mod.terminals) |terminal| if (proc.have(terminal[0])) return terminal[0];
    return "xterm";
}

pub const EditorCommand = struct { argv: []const [:0]const u8, in_terminal: bool };

/// How an editor is told to open a file at a line.
const LineSyntax = enum {
    /// `editor -g path:line` (the VS Code family).
    goto_flag,
    /// `editor path:line`.
    path_colon_line,
    /// `editor -l line path` (Kate).
    line_flag,
    /// `editor +line path` (the vi family, nano, emacs, gedit).
    plus_line,
};

const KnownEditor = struct {
    names: []const []const u8,
    syntax: LineSyntax,
    in_terminal: bool,
};

const editors_known = [_]KnownEditor{
    .{ .names = &.{ "code", "codium", "code-oss" }, .syntax = .goto_flag, .in_terminal = false },
    .{ .names = &.{ "zed", "zeditor", "subl" }, .syntax = .path_colon_line, .in_terminal = false },
    .{ .names = &.{"kate"}, .syntax = .line_flag, .in_terminal = false },
    .{
        .names = &.{ "gedit", "gnome-text-editor", "emacs" },
        .syntax = .plus_line,
        .in_terminal = false,
    },
    .{ .names = &.{ "hx", "helix", "micro" }, .syntax = .path_colon_line, .in_terminal = true },
};

/// vi, vim, nvim, nano, and anything unknown: `+line path` in a terminal.
const editor_unknown: KnownEditor = .{ .names = &.{}, .syntax = .plus_line, .in_terminal = true };

/// How each editor is told to open a file at a line. `editor` is the
/// command's words (the program and its own arguments).
pub fn editorCommand(
    arena: std.mem.Allocator,
    editor: []const [:0]const u8,
    path: [:0]const u8,
    line: u32,
) std.mem.Allocator.Error!EditorCommand {
    const known = knownEditor(baseName(editor[0]));
    const path_at_line = try arena.printSentinel("{s}:{d}", .{ path, line }, 0);
    const line_number = try arena.printSentinel("{d}", .{line}, 0);
    const plus_line = try arena.printSentinel("+{d}", .{line}, 0);
    const Words = []const [:0]const u8;
    // Each array is used within its own expression, before it goes away.
    const argv = switch (known.syntax) {
        .goto_flag => try std.mem.concat(arena, [:0]const u8, &[_]Words{
            editor,
            &.{ "-g", path_at_line },
        }),
        .path_colon_line => try std.mem.concat(arena, [:0]const u8, &[_]Words{
            editor,
            &.{path_at_line},
        }),
        .line_flag => try std.mem.concat(arena, [:0]const u8, &[_]Words{
            editor,
            &.{ "-l", line_number, path },
        }),
        .plus_line => try std.mem.concat(arena, [:0]const u8, &[_]Words{
            editor,
            &.{ plus_line, path },
        }),
    };
    return .{ .argv = argv, .in_terminal = known.in_terminal };
}

fn knownEditor(program: []const u8) KnownEditor {
    for (editors_known) |known| {
        for (known.names) |name| {
            if (std.mem.eql(u8, program, name)) return known;
        }
    }
    return editor_unknown;
}

/// What a terminal takes before the command it is to run.
const TerminalPrefix = struct { names: []const []const u8, words: []const [:0]const u8 };

const terminal_prefixes = [_]TerminalPrefix{
    .{ .names = &.{ "kitty", "foot" }, .words = &.{} },
    .{ .names = &.{"wezterm"}, .words = &.{ "start", "--" } },
    .{ .names = &.{"gnome-terminal"}, .words = &.{"--"} },
};

/// The words that make a terminal run a command (most take `-e`), in
/// `arena`. `terminal` is the terminal command's words.
pub fn terminalPrefix(
    arena: std.mem.Allocator,
    terminal: []const [:0]const u8,
) std.mem.Allocator.Error![]const [:0]const u8 {
    const program = baseName(terminal[0]);
    const prefix: []const [:0]const u8 = for (terminal_prefixes) |known| {
        const matches = for (known.names) |name| {
            if (std.mem.eql(u8, program, name)) break true;
        } else false;
        if (matches) break known.words;
    } else &.{"-e"};
    return std.mem.concat(arena, [:0]const u8, &.{ terminal, prefix });
}

/// What follows the last slash of a program's path.
fn baseName(program: []const u8) []const u8 {
    const slash = std.mem.findScalarLast(u8, program, '/') orelse return program;
    return program[slash + 1 ..];
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
fn copyFile(context: Ctx, path: [:0]const u8) void {
    const uri = c.g_filename_to_uri(path, null, null) orelse return;
    defer c.g_free(uri);
    const list = context.gpa.print("{s}\r\n", .{uri}) catch return;
    defer context.gpa.free(list);
    proc.pipeTo(&.{ "wl-copy", "--type", "text/uri-list" }, list);
}

fn launch(info: *c.GAppInfo) void {
    const launch_context = proc.launchContext() orelse return;
    defer c.g_object_unref(launch_context);
    var err: ?*c.GError = null;
    if (c.g_app_info_launch(info, null, launch_context, &err) == 0) proc.warnError(
        .actions,
        err,
        "launch",
        .{},
    );
}

fn focusWindow(context: Ctx, item: *const Item) void {
    assert(item.action == .focus_window);
    var buffer: [64]u8 = undefined;
    const command = std.mem.print(
        &buffer,
        "focuswindow address:{s}",
        .{item.action.focus_window},
    ) catch return;
    hypr.dispatch(context.gpa, command);
}

fn system(context: Ctx, system_action: item_mod.System) void {
    switch (system_action) {
        .lock => if (proc.have("hyprlock")) proc.spawn(&.{"hyprlock"}) else proc.spawn(
            &.{ "loginctl", "lock-session" },
        ),
        .sleep => proc.spawn(&.{ "systemctl", "suspend" }),
        .restart => proc.spawn(&.{ "systemctl", "reboot" }),
        .shutdown => proc.spawn(&.{ "systemctl", "poweroff" }),
        .logout => hypr.dispatch(context.gpa, "exit"),
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
fn windowOp(context: Ctx, op: item_mod.WindowOp) void {
    hypr.dispatch(context.gpa, switch (op) {
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
    var buffer: [512:0]u8 = undefined;
    const title_z = std.mem.printSentinel(&buffer, "{s}", .{title}, 0) catch "Script";
    proc.spawn(&.{
        "sh",           "-c",
        \\out=$("$1" 2>&1); notify-send -a Lumen -- "$2" "$(printf '%s' "$out" | tail -n 5)"
        ,
        "lumen-script", path,
        title_z,
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
    var buffer: [64 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const class = if (hypr.activeWindow(fixed.allocator())) |window| window.class else "";
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
    var buffer: [128]u8 = undefined;
    if (class.len > buffer.len) return .ctrl_v;
    const lower = std.ascii.lowerString(&buffer, class);
    for (terminals) |terminal| if (std.mem.find(u8, lower, terminal) != null) return .ctrl_shift_v;
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
