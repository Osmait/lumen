//! Lumen's command line: one table of flags for `lumen` (which of them go
//! to a running daemon over its socket), lumen-gtk (which never start a
//! daemon of their own) and the usage text, so the three cannot disagree.
//! No GTK, no libc: the client reads it too.

const std = @import("std");

pub const Flag = enum {
    toggle,
    show,
    hide,
    daemon,
    quit,
    view,
    query,
    command,
    stats,
    help,
    version,
    reload,
    install,
    as,
    update,
    uninstall,
    dmenu,
    prompt,
    dump,
    key,
    text,
    clip_store,
};

pub const Value = enum { none, required, optional };

const Group = enum { window, extensions, dmenu, tests, hidden };

pub const Spec = struct {
    value: Value = .none,
    /// What the usage shows after the flag.
    arg: []const u8 = "",
    /// Lines broken with \n.
    help: []const u8 = "",
    group: Group,
    /// `lumen` hands it to a running daemon; the others run lumen-gtk.
    socket: bool = false,
    /// Only asks a running daemon: lumen-gtk must not become one for it
    /// (`lumen --stats` would start a daemon and never return).
    needs_daemon: bool = false,
};

/// The views `--view` opens (lumen-gtk accepts the inner ones too, which
/// the tests use).
pub const views = "root, clipboard, windows, files, contents,\nsettings, themes, default_apps";

pub const specs: std.enums.EnumArray(Flag, Spec) = .init(.{
    .toggle = .{
        .group = .window,
        .socket = true,
        .help = "Show the window, or hide it if shown (the default)",
    },
    .show = .{ .group = .window, .socket = true, .help = "Show the window" },
    .hide = .{ .group = .window, .socket = true, .needs_daemon = true, .help = "Hide the window" },
    .daemon = .{ .group = .window, .help = "Start in the background with the window hidden" },
    .quit = .{ .group = .window, .socket = true, .needs_daemon = true, .help = "Stop the daemon" },
    .view = .{
        .group = .window,
        .value = .required,
        .arg = "VIEW",
        .socket = true,
        .help = "Open a view: " ++ views,
    },
    .query = .{
        .group = .window,
        .value = .required,
        .arg = "TEXT",
        .socket = true,
        .help = "Open with TEXT typed in the search bar",
    },
    .command = .{
        .group = .window,
        .value = .required,
        .arg = "EXT.CMD",
        .socket = true,
        .help = "Open an extension's command",
    },
    .stats = .{
        .group = .window,
        .socket = true,
        .needs_daemon = true,
        .help = "Print memory, index and latency numbers",
    },
    .help = .{ .group = .window, .help = "Print this help" },
    .version = .{ .group = .window, .help = "Print the version, and the running daemon's" },
    .reload = .{
        .group = .extensions,
        .socket = true,
        .needs_daemon = true,
        .help = "Load init.lua and the extensions again",
    },
    .install = .{
        .group = .extensions,
        .value = .required,
        .arg = "URL",
        .needs_daemon = true,
        .help = "Install an extension from git",
    },
    .as = .{
        .group = .extensions,
        .value = .required,
        .arg = "NAME",
        .help = "With --install: the name to give it",
    },
    .update = .{
        .group = .extensions,
        .value = .optional,
        .arg = "[NAME]",
        .needs_daemon = true,
        .help = "Update an extension from git, or every one",
    },
    .uninstall = .{
        .group = .extensions,
        .value = .required,
        .arg = "NAME",
        .needs_daemon = true,
        .help = "Remove an extension",
    },
    .dmenu = .{
        .group = .dmenu,
        .needs_daemon = true,
        .help = "Show the lines read from stdin, print the one picked",
    },
    .prompt = .{
        .group = .dmenu,
        .value = .required,
        .arg = "TEXT",
        .help = "With --dmenu: what the empty search bar says",
    },
    .dump = .{
        .group = .tests,
        .socket = true,
        .needs_daemon = true,
        .help = "Print what the window shows",
    },
    .key = .{
        .group = .tests,
        .value = .required,
        .arg = "KEY",
        .socket = true,
        .needs_daemon = true,
        .help = "Press KEY in the window (down, enter, ctrl+k, ...)",
    },
    .text = .{
        .group = .tests,
        .value = .required,
        .arg = "TEXT",
        .socket = true,
        .needs_daemon = true,
        .help = "Type TEXT into the search bar",
    },
    // wl-paste runs it for every copy; not for people.
    .clip_store = .{ .group = .hidden },
});

/// "--clip-store" for .clip_store.
pub fn name(flag: Flag) []const u8 {
    return names.get(flag);
}

const names: std.enums.EnumArray(Flag, []const u8) = blk: {
    var out: std.enums.EnumArray(Flag, []const u8) = .initUndefined();
    for (std.enums.values(Flag)) |f| {
        var n: [@tagName(f).len]u8 = @tagName(f).*;
        std.mem.replaceScalar(u8, &n, '_', '-');
        const final = n;
        out.set(f, "--" ++ &final);
    }
    break :blk out;
};

/// The flag `arg` names, or null.
pub fn parse(arg: []const u8) ?Flag {
    for (std.enums.values(Flag)) |f| if (std.mem.eql(u8, arg, name(f))) return f;
    return null;
}

const help_indent: [23]u8 = @splat(' ');

pub const usage: [:0]const u8 = blk: {
    @setEvalBranchQuota(20_000);
    var text: []const u8 = "usage: lumen [OPTION]...\n";
    for ([_]struct { Group, []const u8 }{
        .{ .window, "" },
        .{ .extensions, "\nExtensions:\n" },
        .{ .dmenu, "\nAs dmenu (lumen --dmenu < lines):\n" },
        .{ .tests, "\nFor tests:\n" },
    }) |g| {
        text = text ++ g[1];
        for (std.enums.values(Flag)) |f| {
            const s = specs.get(f);
            if (s.group != g[0]) continue;
            const left = name(f) ++ (if (s.arg.len > 0) " " ++ s.arg else "");
            // Continuation lines start under the first one.
            var help: []const u8 = "";
            var lines = std.mem.splitScalar(u8, s.help, '\n');
            help = help ++ lines.first();
            while (lines.next()) |l| help = help ++ "\n" ++ &help_indent ++ l;
            text = text ++ std.fmt.comptimePrint("  {s:<20} {s}\n", .{ left, help });
        }
    }
    break :blk std.fmt.comptimePrint("{s}", .{text});
};

test "names, parsing and the usage" {
    try std.testing.expectEqualStrings("--clip-store", name(.clip_store));
    try std.testing.expectEqual(Flag.clip_store, parse("--clip-store").?);
    try std.testing.expectEqual(Flag.view, parse("--view").?);
    try std.testing.expect(parse("--nope") == null);
    try std.testing.expect(parse("view") == null);
    var lines = std.mem.splitScalar(u8, usage, '\n');
    while (lines.next()) |l| try std.testing.expect(l.len <= 80);
    // Every flag people use is in the usage, the internal one is not.
    for (std.enums.values(Flag)) |f| {
        const listed = std.mem.find(u8, usage, name(f)) != null;
        try std.testing.expectEqual(specs.get(f).group != .hidden, listed);
    }
    // A value the client passes on is never optional: it could not tell
    // a value from the next flag the way lumen-gtk does.
    for (std.enums.values(Flag)) |f| {
        const s = specs.get(f);
        if (s.socket) try std.testing.expect(s.value != .optional);
    }
}
