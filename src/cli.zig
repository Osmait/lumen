//! Lumen's command line: one table of flags for `lumen` (which of them go
//! to a running daemon over its socket), lumen-gtk (which never start a
//! daemon of their own) and the usage text, so the three cannot disagree.
//! No GTK, no libc: the client reads it too.

const std = @import("std");
const assert = std.debug.assert;

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
    value_name: []const u8 = "",
    /// Help text; "\n" starts a continuation line, indented under the
    /// first.
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
    .daemon = .{
        .group = .window,
        .help = "Run the daemon here, with the window hidden\n(without a daemon, `lumen` starts one apart)",
    },
    .quit = .{ .group = .window, .socket = true, .needs_daemon = true, .help = "Stop the daemon" },
    .view = .{
        .group = .window,
        .value = .required,
        .value_name = "VIEW",
        .socket = true,
        .help = "Open a view: " ++ views,
    },
    .query = .{
        .group = .window,
        .value = .required,
        .value_name = "TEXT",
        .socket = true,
        .help = "Open with TEXT typed in the search bar",
    },
    .command = .{
        .group = .window,
        .value = .required,
        .value_name = "EXT.CMD",
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
        .value_name = "URL",
        .needs_daemon = true,
        .help = "Install an extension from git",
    },
    .as = .{
        .group = .extensions,
        .value = .required,
        .value_name = "NAME",
        .help = "With --install: the name to give it",
    },
    .update = .{
        .group = .extensions,
        .value = .optional,
        .value_name = "[NAME]",
        .needs_daemon = true,
        .help = "Update an extension from git, or every one",
    },
    .uninstall = .{
        .group = .extensions,
        .value = .required,
        .value_name = "NAME",
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
        .value_name = "TEXT",
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
        .value_name = "KEY",
        .socket = true,
        .needs_daemon = true,
        .help = "Press KEY in the window (down, enter, ctrl+k, ...)",
    },
    .text = .{
        .group = .tests,
        .value = .required,
        .value_name = "TEXT",
        .socket = true,
        .needs_daemon = true,
        .help = "Type TEXT into the search bar",
    },
    // wl-paste runs it for every copy; not for people.
    .clip_store = .{ .group = .hidden },
});

comptime {
    for (std.enums.values(Flag)) |flag| {
        const spec = specs.get(flag);
        // A value the client passes on is never optional: it could not
        // tell a value from the next flag the way lumen-gtk does.
        if (spec.socket) assert(spec.value != .optional);
        // What the usage shows after a flag is the name of its value.
        if (spec.value == .none) assert(spec.value_name.len == 0);
    }
}

/// "--clip-store" for .clip_store.
pub fn name(flag: Flag) []const u8 {
    return names.get(flag);
}

const names: std.enums.EnumArray(Flag, []const u8) = blk: {
    var flag_names: std.enums.EnumArray(Flag, []const u8) = .initUndefined();
    for (std.enums.values(Flag)) |flag| {
        var dashed: [@tagName(flag).len]u8 = @tagName(flag).*;
        std.mem.replaceScalar(u8, &dashed, '_', '-');
        const final = dashed;
        flag_names.set(flag, "--" ++ &final);
    }
    break :blk flag_names;
};

/// The flag `text` names, or null.
pub fn parse(text: []const u8) ?Flag {
    for (std.enums.values(Flag)) |flag| {
        if (std.mem.eql(u8, text, name(flag))) return flag;
    }
    return null;
}

/// Whether any flag of `arguments` (without the program's name; `[:0]const
/// u8` or `[*:0]const u8` each) only asks a running daemon, wherever it is
/// (`--prompt X --dmenu`, `--show --stats`). Values are skipped as lumen-gtk
/// reads them (`--query --stats` asks for nothing of the kind); words that
/// are not flags are left to the parse that refuses them.
pub fn needsDaemon(arguments: anytype) bool {
    var argument_index: usize = 0;
    while (argument_index < arguments.len) : (argument_index += 1) {
        const flag = parse(argumentText(arguments[argument_index])) orelse continue;
        const spec = specs.get(flag);
        if (spec.needs_daemon) return true;
        switch (spec.value) {
            .none => {},
            .required => argument_index += 1,
            // Taken only when the next argument is not itself a flag.
            .optional => {
                const next_index = argument_index + 1;
                if (next_index < arguments.len and
                    !std.mem.startsWith(u8, argumentText(arguments[next_index]), "-"))
                {
                    argument_index = next_index;
                }
            },
        }
    }
    return false;
}

fn argumentText(argument: anytype) []const u8 {
    return if (@TypeOf(argument) == [*:0]const u8) std.mem.span(argument) else argument;
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
    }) |section| {
        const group, const heading = section;
        text = text ++ heading;
        for (std.enums.values(Flag)) |flag| {
            const spec = specs.get(flag);
            if (spec.group != group) continue;
            const value_shown = if (spec.value_name.len > 0) " " ++ spec.value_name else "";
            const left = name(flag) ++ value_shown;
            // Continuation lines start under the first one.
            var help: []const u8 = "";
            var lines = std.mem.splitScalar(u8, spec.help, '\n');
            help = help ++ lines.first();
            while (lines.next()) |line| help = help ++ "\n" ++ &help_indent ++ line;
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
    while (lines.next()) |line| try std.testing.expect(line.len <= 80);
    // Every flag people use is in the usage, the internal one is not.
    for (std.enums.values(Flag)) |flag| {
        const listed = std.mem.find(u8, usage, name(flag)) != null;
        try std.testing.expectEqual(specs.get(flag).group != .hidden, listed);
    }
}

test "needsDaemon looks at every flag, not just the first" {
    const Args = []const [:0]const u8;
    try std.testing.expect(needsDaemon(@as(Args, &.{ "--prompt", "Pick:", "--dmenu" })));
    try std.testing.expect(needsDaemon(@as(Args, &.{ "--query", "foo", "--dmenu" })));
    try std.testing.expect(needsDaemon(@as(Args, &.{ "--as", "x", "--install", "https://e/x" })));
    try std.testing.expect(needsDaemon(@as(Args, &.{ "--show", "--stats" })));
    try std.testing.expect(needsDaemon(@as(Args, &.{"--hide"})));
    // Values are not flags.
    try std.testing.expect(!needsDaemon(@as(Args, &.{ "--query", "--stats" })));
    try std.testing.expect(!needsDaemon(@as(Args, &.{ "--prompt", "--dmenu" })));
    try std.testing.expect(!needsDaemon(@as(Args, &.{ "--view", "files", "--query", "x" })));
    try std.testing.expect(!needsDaemon(@as(Args, &.{})));
    try std.testing.expect(!needsDaemon(@as(Args, &.{"--daemon"})));
    // --update needs a daemon whether or not it takes the next word.
    try std.testing.expect(needsDaemon(@as(Args, &.{ "--update", "--show" })));
    const pointers = [_][*:0]const u8{ "--show", "--reload" };
    try std.testing.expect(needsDaemon(@as([]const [*:0]const u8, &pointers)));
}
