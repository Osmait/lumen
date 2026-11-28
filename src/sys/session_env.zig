//! The environment the daemon runs with, which every program it starts
//! inherits (apps, terminals, `lumen.exec`, the extension host): the
//! session's, not that of the terminal it was started or restarted from
//! (MYP-564). Fixed once, as the daemon starts:
//!
//!   - What describes a terminal or a shell (TERM, TMUX, KITTY_*, an
//!     activated virtualenv and its PATH entry, SHLVL, OLDPWD) is dropped:
//!     the daemon is attached to none, and a terminal it opens sets its own.
//!     PWD becomes $HOME, the folder the daemon works from.
//!   - A HYPRLAND_INSTANCE_SIGNATURE whose compositor is gone (a tmux
//!     server older than the login) is replaced by the running instance's,
//!     with that instance's WAYLAND_DISPLAY; one missing (a systemd user
//!     service) is set from the instance that owns WAYLAND_DISPLAY.
//!
//! Variables the session itself exported cannot be told from what a shell
//! added (an edited PATH, EDITOR): those stay as they were.
//!
//! The process environment cannot be edited in place: Zig keeps the block
//! the process started with, and unsetenv shifts that very array under it
//! (its next spawn would read past the end). So the daemon runs itself
//! again with the fixed environment (`reexecInSession`), before GTK starts.

const std = @import("std");
const linux = std.os.linux;
const os = @import("os");

const log = std.log.scoped(.session);

/// Dropped by name: the terminal or the shell the daemon was started from.
const terminal_names = [_][]const u8{
    "TERM",     "COLORTERM",           "TERM_PROGRAM",              "TERM_PROGRAM_VERSION",
    "TERMINFO", "VTE_VERSION",         "WINDOWID",                  "SHLVL",
    "OLDPWD",   "TMUX",                "STY",                       "WINDOW",
    "ZELLIJ",   "VIRTUAL_ENV",         "VIRTUAL_ENV_PROMPT",        "INSIDE_EMACS",
    "NVIM",     "NVIM_LISTEN_ADDRESS",
    // GLib sets these on what it launches: the terminal's .desktop file.
    "GIO_LAUNCHED_DESKTOP_FILE", "GIO_LAUNCHED_DESKTOP_FILE_PID",
};

/// Dropped by prefix: a terminal's or a multiplexer's own variables.
const terminal_prefixes = [_][]const u8{
    "TMUX_",    "ZELLIJ_", "KITTY_", "WEZTERM_", "ALACRITTY_", "GHOSTTY_",
    "KONSOLE_", "VSCODE_",
};

fn fromTerminal(name: []const u8) bool {
    for (terminal_names) |dropped| {
        if (std.mem.eql(u8, name, dropped)) return true;
    }
    for (terminal_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

/// A running Hyprland instance: its folder under $XDG_RUNTIME_DIR/hypr
/// answered on its socket.
pub const Instance = struct {
    signature: []const u8,
    /// The Wayland socket it serves (its hyprland.lock), if read.
    wayland_display: ?[]const u8,
    /// When it started (the signature's second field), 0 if unknown.
    started_s: u64,
};

const signature_name = "HYPRLAND_INSTANCE_SIGNATURE";

/// The Hyprland instance the environment should name, and the
/// WAYLAND_DISPLAY to go with it (null: leave it).
const Choice = struct { signature: []const u8, wayland_display: ?[]const u8 };

fn chooseHyprland(entries: []const []const u8, live: []const Instance) ?Choice {
    const current = get(entries, signature_name);
    if (current) |signature| for (live) |instance| {
        if (std.mem.eql(u8, instance.signature, signature)) return null;
    };
    // The instance that owns our Wayland socket is our compositor.
    if (get(entries, "WAYLAND_DISPLAY")) |display| for (live) |instance| {
        const served = instance.wayland_display orelse continue;
        if (std.mem.eql(u8, served, display)) return .{ .signature = instance.signature, .wayland_display = null };
    };
    // Neither named nor found by its socket: not under Hyprland, as far as
    // can be told.
    if (current == null) return null;
    // A stale one: the newest running instance (a login after the one it
    // names), with its socket.
    var newest: ?Instance = null;
    for (live) |instance| {
        if (newest == null or instance.started_s > newest.?.started_s) newest = instance;
    }
    const chosen = newest orelse return null;
    return .{ .signature = chosen.signature, .wayland_display = chosen.wayland_display };
}

/// The session's environment for `entries` ("NAME=value"), given the
/// Hyprland instances running; null when `entries` is it already. In
/// `arena`.
pub fn sessionEnvironment(
    arena: std.mem.Allocator,
    entries: []const []const u8,
    live: []const Instance,
) std.mem.Allocator.Error!?[]const []const u8 {
    const home = get(entries, "HOME");
    const virtual_env = get(entries, "VIRTUAL_ENV");
    const hyprland = chooseHyprland(entries, live);
    var out: std.ArrayList([]const u8) = try .initCapacity(arena, entries.len + 2);
    var changed = false;
    var signature_set = false;
    var display_set = false;
    for (entries) |entry| {
        const name = nameOf(entry);
        if (fromTerminal(name)) {
            changed = true;
            continue;
        }
        var wanted: ?[]const u8 = entry;
        if (std.mem.eql(u8, name, "PWD")) {
            wanted = if (home) |folder| try assignment(arena, name, folder) else null;
        } else if (std.mem.eql(u8, name, "PATH") and virtual_env != null) {
            const bin = try std.fmt.allocPrint(arena, "{s}/bin", .{virtual_env.?});
            wanted = try assignment(arena, name, try withoutFolder(arena, valueOf(entry), bin));
        } else if (hyprland) |choice| {
            if (std.mem.eql(u8, name, signature_name)) {
                wanted = try assignment(arena, name, choice.signature);
                signature_set = true;
            } else if (std.mem.eql(u8, name, "WAYLAND_DISPLAY")) {
                if (choice.wayland_display) |display| wanted = try assignment(arena, name, display);
                display_set = true;
            }
        }
        const kept = wanted orelse {
            changed = true;
            continue;
        };
        if (!std.mem.eql(u8, kept, entry)) changed = true;
        out.appendAssumeCapacity(kept);
    }
    if (hyprland) |choice| {
        if (!signature_set) {
            out.appendAssumeCapacity(try assignment(arena, signature_name, choice.signature));
            changed = true;
        }
        if (!display_set) if (choice.wayland_display) |display| {
            out.appendAssumeCapacity(try assignment(arena, "WAYLAND_DISPLAY", display));
            changed = true;
        };
    }
    return if (changed) out.items else null;
}

fn nameOf(entry: []const u8) []const u8 {
    const equals = std.mem.findScalar(u8, entry, '=') orelse return entry;
    return entry[0..equals];
}

fn valueOf(entry: []const u8) []const u8 {
    const equals = std.mem.findScalar(u8, entry, '=') orelse return "";
    return entry[equals + 1 ..];
}

/// The value of `name` in `entries`, null when unset or empty.
fn get(entries: []const []const u8, name: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (!std.mem.eql(u8, nameOf(entry), name)) continue;
        const value = valueOf(entry);
        return if (value.len == 0) null else value;
    }
    return null;
}

fn assignment(arena: std.mem.Allocator, name: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}={s}", .{ name, value });
}

/// `search_path` (colon-separated) without `folder` (with or without a
/// trailing slash).
fn withoutFolder(arena: std.mem.Allocator, search_path: []const u8, folder: []const u8) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, search_path, ':');
    var first = true;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, part, "/"), std.mem.trimEnd(u8, folder, "/"))) continue;
        if (!first) try kept.append(arena, ':');
        try kept.appendSlice(arena, part);
        first = false;
    }
    return kept.items;
}

/// The Hyprland instances under `runtime_dir`/hypr that answer on their
/// socket. In `arena`.
pub fn liveInstances(arena: std.mem.Allocator, runtime_dir: []const u8) []const Instance {
    const hypr_dir = std.fmt.allocPrintSentinel(arena, "{s}/hypr", .{runtime_dir}, 0) catch return &.{};
    const folders = os.subdirs(arena, hypr_dir, &anyFolder);
    var live: std.ArrayList(Instance) = .empty;
    for (folders) |signature| {
        const socket_path = std.fmt.allocPrint(arena, "{s}/{s}/.socket.sock", .{ hypr_dir, signature }) catch break;
        switch (os.unix.open(socket_path, .{})) {
            .fd => |fd| os.close(fd),
            // Alive, not answering now: still the compositor.
            .busy => {},
            .none => continue,
        }
        const lock_path = std.fmt.allocPrintSentinel(arena, "{s}/{s}/hyprland.lock", .{ hypr_dir, signature }, 0) catch break;
        var lock_buffer: [256]u8 = undefined;
        // "<pid>\n<wayland socket>\n".
        var lines = std.mem.splitScalar(u8, os.readHead(lock_path, &lock_buffer), '\n');
        _ = lines.next();
        const display = std.mem.trim(u8, lines.next() orelse "", " \t\r");
        live.append(arena, .{
            .signature = signature,
            .wayland_display = if (display.len == 0) null else arena.dupe(u8, display) catch break,
            .started_s = startedSeconds(signature),
        }) catch break;
    }
    return live.items;
}

fn anyFolder(_: []const u8) bool {
    return true;
}

/// The start time in a signature (`<hash>_<unix seconds>_<random>`), 0 if
/// there is none.
fn startedSeconds(signature: []const u8) u64 {
    var fields = std.mem.splitScalar(u8, signature, '_');
    _ = fields.next();
    const seconds = fields.next() orelse return 0;
    return std.fmt.parseInt(u64, seconds, 10) catch 0;
}

/// Runs this program again (`/proc/self/exe`, the same `argv`) with the
/// session's environment, when `environ` is not it. Returns only when it
/// is already, or when that failed (logged): the daemon then runs as it
/// was started. Before any thread that matters starts: exec ends them.
pub fn reexecInSession(gpa: std.mem.Allocator, environ: std.process.Environ, argv: []const ?[*:0]const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const block = environ.block.slice;
    const entries = arena.alloc([]const u8, block.len) catch return;
    for (block, entries) |entry, *slice| slice.* = std.mem.span(entry.?);
    const live = if (get(entries, "XDG_RUNTIME_DIR")) |runtime_dir|
        liveInstances(arena, runtime_dir)
    else
        &.{};
    const fixed = (sessionEnvironment(arena, entries, live) catch return) orelse return;

    const envp = arena.allocSentinel(?[*:0]const u8, fixed.len, null) catch return;
    for (fixed, envp) |entry, *slot| slot.* = (arena.dupeSentinel(u8, entry, 0) catch return).ptr;
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch return;
    @memcpy(argv_z, argv);
    const result = linux.execve("/proc/self/exe", argv_z.ptr, envp.ptr);
    log.warn("starting again in the session's environment: {t}", .{linux.errno(result)});
}

const testing = std.testing;

fn expectEnvironment(want: ?[]const []const u8, entries: []const []const u8, live: []const Instance) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = try sessionEnvironment(arena_state.allocator(), entries, live);
    if (want == null) return testing.expectEqual(@as(?[]const []const u8, null), got);
    try testing.expect(got != null);
    try testing.expectEqual(want.?.len, got.?.len);
    for (want.?, got.?) |expected, actual| try testing.expectEqualStrings(expected, actual);
    // Started again with it, nothing more changes: no exec loop.
    const again = try sessionEnvironment(arena_state.allocator(), got.?, live);
    try testing.expectEqual(@as(?[]const []const u8, null), again);
}

const running: Instance = .{
    .signature = "abc_1795804276_2111466017",
    .wayland_display = "wayland-1",
    .started_s = 1795804276,
};
const older: Instance = .{
    .signature = "abc_1795000000_1",
    .wayland_display = "wayland-0",
    .started_s = 1795000000,
};

test "a daemon started from a tmux pane in a virtualenv gets the session's environment" {
    try expectEnvironment(&.{
        "HOME=/home/u",
        "PATH=/usr/local/bin:/usr/bin",
        "PWD=/home/u",
        "WAYLAND_DISPLAY=wayland-1",
        "HYPRLAND_INSTANCE_SIGNATURE=abc_1795804276_2111466017",
        "XDG_CURRENT_DESKTOP=Hyprland",
    }, &.{
        "HOME=/home/u",
        "TERM=tmux-256color",
        "TMUX=/tmp/tmux-1000/default,1234,0",
        "TMUX_PANE=%3",
        "PATH=/home/u/proj/.venv/bin:/usr/local/bin:/usr/bin",
        "VIRTUAL_ENV=/home/u/proj/.venv",
        "PWD=/run/media/u/STICK",
        "OLDPWD=/home/u",
        "SHLVL=2",
        "KITTY_WINDOW_ID=4",
        "WAYLAND_DISPLAY=wayland-1",
        "HYPRLAND_INSTANCE_SIGNATURE=abc_1795000000_1",
        "XDG_CURRENT_DESKTOP=Hyprland",
    }, &.{running});
}

test "a signature from an earlier login is replaced by the running instance's, socket too" {
    try expectEnvironment(&.{
        "HOME=/home/u",
        "WAYLAND_DISPLAY=wayland-1",
        "HYPRLAND_INSTANCE_SIGNATURE=abc_1795804276_2111466017",
    }, &.{
        "HOME=/home/u",
        "WAYLAND_DISPLAY=wayland-9",
        "HYPRLAND_INSTANCE_SIGNATURE=gone_1700000000_1",
    }, &.{ older, running });
}

test "a missing signature is set from the instance that owns WAYLAND_DISPLAY" {
    try expectEnvironment(&.{
        "WAYLAND_DISPLAY=wayland-0",
        "HYPRLAND_INSTANCE_SIGNATURE=abc_1795000000_1",
    }, &.{"WAYLAND_DISPLAY=wayland-0"}, &.{ running, older });
}

test "the session's environment is left alone" {
    // Under Hyprland, its instance alive.
    try expectEnvironment(null, &.{
        "HOME=/home/u",
        "PWD=/home/u",
        "PATH=/usr/bin",
        "WAYLAND_DISPLAY=wayland-1",
        "HYPRLAND_INSTANCE_SIGNATURE=abc_1795804276_2111466017",
    }, &.{running});
    // Another compositor: no signature, a socket no instance serves.
    try expectEnvironment(null, &.{ "WAYLAND_DISPLAY=wayland-5", "SWAYSOCK=/run/user/1000/sway.sock" }, &.{running});
    // Hyprland not running, or its socket unreadable: nothing to pick.
    try expectEnvironment(null, &.{"HYPRLAND_INSTANCE_SIGNATURE=gone_1_1"}, &.{});
    // No HOME: PWD goes, it names no folder the daemon is in.
    try expectEnvironment(&.{"USER=u"}, &.{ "USER=u", "PWD=/mnt" }, &.{});
}

test "liveInstances: a runtime folder without Hyprland has none" {
    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    // A dead instance: its folder and lock are left, its socket is not.
    try test_dir.write("hypr/dead_1_1/hyprland.lock", "1\nwayland-1\n");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), liveInstances(arena_state.allocator(), test_dir.absolute).len);
    try testing.expectEqual(@as(usize, 0), liveInstances(arena_state.allocator(), "/nonexistent-lumen").len);
    try testing.expectEqual(@as(u64, 1795804276), startedSeconds(running.signature));
    try testing.expectEqual(@as(u64, 0), startedSeconds("nounderscore"));
}
