//! Lumen's settings, in $XDG_CONFIG_HOME/lumen/settings.conf: plain
//! `key = value` lines a person can edit by hand, and an `[open-with]`
//! section mapping file kinds or extensions to apps. The Settings command
//! writes the same file; Lumen reads it again whenever it changed, so a hand
//! edit shows the next time the window opens.
//!
//! Anything unreadable falls back to its default: a broken file never stops
//! Lumen from starting. Unknown keys are kept and written back.

const std = @import("std");
const core = @import("core");
const sys = @import("index").sys;
const Kind = core.file_kind.Kind;

pub const default_theme = "lumen-dark";

pub const TextSize = enum { small, default, large };
pub const Position = enum { upper_third, center };

/// On/off settings.
pub const Toggle = enum { files_in_root, suggestions, clipboard };
/// Settings with a list of values to pick from.
pub const Choice = enum { text_size, opacity, position, clipboard_keep, terminal, editor };

pub const opacity_choices = [_]u8{ 100, 97, 90, 80 };
pub const keep_choices = [_]u32{ 100, 500, 1000, 5000 };

/// Terminal emulators and editors offered when installed (first word is the
/// command, the rest its display name).
pub const terminals = [_][2][:0]const u8{
    .{ "ghostty", "Ghostty" }, .{ "kitty", "Kitty" },     .{ "alacritty", "Alacritty" },           .{ "foot", "Foot" },
    .{ "wezterm", "WezTerm" }, .{ "konsole", "Konsole" }, .{ "gnome-terminal", "GNOME Terminal" }, .{ "xterm", "XTerm" },
};
pub const editors = [_][2][:0]const u8{
    .{ "nvim", "Neovim" },                         .{ "vim", "Vim" },           .{ "hx", "Helix" },     .{ "nano", "nano" },
    .{ "micro", "micro" },                         .{ "emacs", "Emacs" },       .{ "code", "VS Code" }, .{ "codium", "VSCodium" },
    .{ "zed", "Zed" },                             .{ "subl", "Sublime Text" }, .{ "kate", "Kate" },    .{ "gedit", "gedit" },
    .{ "gnome-text-editor", "GNOME Text Editor" },
};

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    theme: []const u8 = default_theme,
    text_size: TextSize = .default,
    /// Window background opacity, percent.
    opacity: u8 = 97,
    position: Position = .upper_third,
    files_in_root: bool = true,
    suggestions: bool = true,
    clipboard: bool = true,
    clipboard_keep: u32 = 1000,
    /// Command names; empty is automatic ($TERMINAL / $EDITOR, then the
    /// first one installed).
    terminal: []const u8 = "",
    editor: []const u8 = "",
    /// A kind's name ("pdf") or an extension (".log") → desktop file id.
    open_with: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// `key = value` lines this version does not know, kept as they were.
    unknown: std.ArrayList([]const u8) = .empty,
    /// Memory ran out while reading the file: some of it is missing here,
    /// so `save` refuses to write this back over it.
    incomplete: bool = false,

    pub fn init(gpa: std.mem.Allocator) Settings {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(s: *Settings) void {
        s.arena.deinit();
        s.* = undefined;
    }

    fn alloc(s: *Settings) std.mem.Allocator {
        return s.arena.allocator();
    }

    /// Settings from the text of a settings file.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) Settings {
        var s = Settings.init(gpa);
        var section_open_with = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.indexOf(u8, line, " #")) |h| line = std.mem.trimEnd(u8, line[0..h], " \t");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[') {
                section_open_with = std.mem.eql(u8, line, "[open-with]");
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (section_open_with) {
                s.setOpenWith(key, value) catch |err| switch (err) {
                    // A bad line is ignored, like a bad value anywhere else.
                    error.BadKey, error.BadApp => {},
                    error.OutOfMemory => s.incomplete = true,
                };
            } else if (!s.set(key, value)) {
                if (isToken(key)) s.keepUnknown(line) catch {
                    s.incomplete = true;
                };
            }
        }
        return s;
    }

    fn keepUnknown(s: *Settings, line: []const u8) std.mem.Allocator.Error!void {
        const a = s.alloc();
        try s.unknown.append(a, try a.dupe(u8, line));
    }

    /// Sets a top-level key from its text value. False when the key is not
    /// known; a known key with a bad value keeps its current value.
    pub fn set(s: *Settings, key: []const u8, value: []const u8) bool {
        if (std.meta.stringToEnum(Toggle, key)) |t| {
            if (parseBool(value)) |b| s.setToggle(t, b);
            return true;
        }
        if (std.meta.stringToEnum(Choice, key)) |ch| {
            _ = s.setChoice(ch, value);
            return true;
        }
        if (std.mem.eql(u8, key, "theme")) {
            if (isToken(value)) s.theme = s.alloc().dupe(u8, value) catch blk: {
                s.incomplete = true;
                break :blk s.theme;
            };
            return true;
        }
        return false;
    }

    pub fn get(s: *const Settings, t: Toggle) bool {
        return switch (t) {
            .files_in_root => s.files_in_root,
            .suggestions => s.suggestions,
            .clipboard => s.clipboard,
        };
    }

    pub fn setToggle(s: *Settings, t: Toggle, on: bool) void {
        switch (t) {
            .files_in_root => s.files_in_root = on,
            .suggestions => s.suggestions = on,
            .clipboard => s.clipboard = on,
        }
    }

    /// Sets a choice from its value's text ("large", "90", "kitty"); false
    /// when the value is not one of its values.
    pub fn setChoice(s: *Settings, ch: Choice, value: []const u8) bool {
        switch (ch) {
            .text_size => s.text_size = std.meta.stringToEnum(TextSize, value) orelse return false,
            .position => s.position = std.meta.stringToEnum(Position, value) orelse return false,
            .opacity => {
                const v = std.fmt.parseInt(u8, std.mem.trimEnd(u8, value, "%"), 10) catch return false;
                if (v < 50 or v > 100) return false;
                s.opacity = v;
            },
            .clipboard_keep => {
                const v = std.fmt.parseInt(u32, value, 10) catch return false;
                if (v < 10 or v > 100_000) return false;
                s.clipboard_keep = v;
            },
            .terminal, .editor => {
                if (value.len > 0 and !isToken(value)) return false;
                const owned = s.alloc().dupe(u8, value) catch {
                    s.incomplete = true;
                    return false;
                };
                if (ch == .terminal) s.terminal = owned else s.editor = owned;
            },
        }
        return true;
    }

    /// The current value of a choice as its text (what `setChoice` takes).
    pub fn choiceValue(s: *const Settings, ch: Choice, buf: []u8) []const u8 {
        return switch (ch) {
            .text_size => @tagName(s.text_size),
            .position => @tagName(s.position),
            .opacity => std.fmt.bufPrint(buf, "{d}", .{s.opacity}) catch "",
            .clipboard_keep => std.fmt.bufPrint(buf, "{d}", .{s.clipboard_keep}) catch "",
            .terminal => s.terminal,
            .editor => s.editor,
        };
    }

    /// `key` is a kind name or ".ext"; an empty `app` removes the entry
    /// (back to the system default).
    pub const OpenWithError = error{ BadKey, BadApp } || std.mem.Allocator.Error;

    pub fn setOpenWith(s: *Settings, key: []const u8, app: []const u8) OpenWithError!void {
        const valid_key = std.meta.stringToEnum(Kind, key) != null or
            (key.len >= 2 and key.len <= 16 and key[0] == '.' and isToken(key[1..]));
        if (!valid_key) return error.BadKey;
        var kbuf: [16]u8 = undefined;
        const k = if (key[0] == '.') std.ascii.lowerString(&kbuf, key) else key;
        if (app.len == 0) {
            _ = s.open_with.orderedRemove(k);
            return;
        }
        if (!isToken(app) or !std.mem.endsWith(u8, app, ".desktop")) return error.BadApp;
        const a = s.alloc();
        try s.open_with.put(a, try a.dupe(u8, k), try a.dupe(u8, app));
    }

    /// The app chosen for a file: its extension first, then its kind, then
    /// the kind it falls back to.
    pub fn appFor(s: *const Settings, ext_key: []const u8, kind: ?Kind) ?[]const u8 {
        if (ext_key.len > 0) if (s.open_with.get(ext_key)) |app| return app;
        var k = kind orelse return null;
        while (true) {
            if (s.open_with.get(@tagName(k))) |app| return app;
            k = k.fallback() orelse return null;
        }
    }

    pub fn write(s: *const Settings, w: *std.Io.Writer) !void {
        try w.print(
            \\# Lumen settings. Change them from Lumen (search "Settings") or here:
            \\# Lumen reads this file again when its window opens.
            \\
            \\# Appearance. Themes: search "Change Theme" in Lumen.
            \\theme = {s}
            \\# small, default, large
            \\text_size = {t}
            \\# Window background opacity, percent (50-100)
            \\opacity = {d}
            \\# upper_third, center
            \\position = {t}
            \\
            \\# Search
            \\files_in_root = {}
            \\suggestions = {}
            \\
            \\# Clipboard history, and how many entries it keeps
            \\clipboard = {}
            \\clipboard_keep = {d}
            \\
            \\# Commands; empty is automatic ($TERMINAL, $VISUAL/$EDITOR)
            \\terminal = {s}
            \\editor = {s}
            \\
        , .{ s.theme, s.text_size, s.opacity, s.position, s.files_in_root, s.suggestions, s.clipboard, s.clipboard_keep, s.terminal, s.editor });
        if (s.unknown.items.len > 0) {
            try w.writeAll("\n# Not known to this version of Lumen\n");
            for (s.unknown.items) |l| try w.print("{s}\n", .{l});
        }
        try w.writeAll(
            \\
            \\[open-with]
            \\# A file kind (folder pdf image video audio markdown html text office
            \\# archive) or an extension (.log) = the app's desktop file id
            \\
        );
        var it = s.open_with.iterator();
        while (it.next()) |e| try w.print("{s} = {s}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }

    /// Reads `path`; a missing or unreadable file gives the defaults.
    pub fn load(gpa: std.mem.Allocator, path: [*:0]const u8) Settings {
        var buf: [64 * 1024]u8 = undefined;
        return parse(gpa, sys.readHead(path, &buf));
    }

    pub const SaveError = sys.Error || std.Io.Writer.Error || error{Incomplete};

    /// Writes `path` atomically (temporary file, fsync, rename): a crash or a
    /// full disk never leaves half a file. Owner-only, like Lumen's other
    /// files.
    pub fn save(s: *const Settings, gpa: std.mem.Allocator, path: []const u8) SaveError!void {
        if (s.incomplete) return error.Incomplete;
        if (std.mem.findScalarLast(u8, path, '/')) |slash| sys.mkdirP(path[0..slash]);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try s.write(&out.writer);
        try sys.writeFileAtomic(path, out.written());
    }
};

/// A file's identity for "did it change?": modification time to the
/// nanosecond, size and inode (editors that save by renaming a new file).
pub const Stamp = struct {
    sec: i64 = -1,
    nsec: u32 = 0,
    size: u64 = 0,
    ino: u64 = 0,

    pub fn of(path: [*:0]const u8) Stamp {
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .SIZE = true, .MTIME = true, .INO = true }, &st);
        if (linux.errno(rc) != .SUCCESS) return .{};
        return .{ .sec = st.mtime.sec, .nsec = st.mtime.nsec, .size = st.size, .ino = st.ino };
    }

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.sec == b.sec and a.nsec == b.nsec and a.size == b.size and a.ino == b.ino;
    }
};

fn parseBool(v: []const u8) ?bool {
    const yes = [_][]const u8{ "true", "on", "yes", "1" };
    const no = [_][]const u8{ "false", "off", "no", "0" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(v, y)) return true;
    for (no) |n| if (std.ascii.eqlIgnoreCase(v, n)) return false;
    return null;
}

/// One word of safe characters: values are written back into the file and
/// passed to programs, so no spaces, quotes or newlines.
fn isToken(v: []const u8) bool {
    if (v.len == 0 or v.len > 200) return false;
    for (v) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch == '+')) return false;
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "defaults, then values from the file" {
    var d = Settings.parse(testing.allocator, "");
    defer d.deinit();
    try testing.expectEqualStrings(default_theme, d.theme);
    try testing.expect(d.files_in_root and d.clipboard);
    try testing.expectEqual(@as(u32, 1000), d.clipboard_keep);

    var s = Settings.parse(testing.allocator,
        \\# comment
        \\theme = nord
        \\text_size = large
        \\opacity = 90%
        \\position = center
        \\files_in_root = off
        \\clipboard = no   # inline comment
        \\clipboard_keep = 500
        \\terminal = kitty
        \\
        \\[open-with]
        \\pdf = org.gnome.Evince.desktop
        \\.LOG = org.gnome.TextEditor.desktop
    );
    defer s.deinit();
    try testing.expectEqualStrings("nord", s.theme);
    try testing.expectEqual(TextSize.large, s.text_size);
    try testing.expectEqual(@as(u8, 90), s.opacity);
    try testing.expectEqual(Position.center, s.position);
    try testing.expect(!s.files_in_root and !s.clipboard and s.suggestions);
    try testing.expectEqual(@as(u32, 500), s.clipboard_keep);
    try testing.expectEqualStrings("kitty", s.terminal);
    try testing.expectEqualStrings("org.gnome.Evince.desktop", s.appFor("", .pdf).?);
    try testing.expectEqualStrings("org.gnome.TextEditor.desktop", s.appFor(".log", .text).?);
}

test "bad values keep the default, bad lines are ignored" {
    var s = Settings.parse(testing.allocator,
        \\text_size = enormous
        \\opacity = 7
        \\clipboard_keep = lots
        \\files_in_root = maybe
        \\terminal = rm -rf /
        \\theme = a b
        \\no equals sign here
        \\= value without key
        \\[open-with]
        \\pdf = evil; rm -rf /
        \\nonsense = app.desktop
        \\image = not-a-desktop-id
        \\video = mpv.desktop
    ++ "\n\x00\xff garbage\n");
    defer s.deinit();
    try testing.expectEqual(TextSize.default, s.text_size);
    try testing.expectEqual(@as(u8, 97), s.opacity);
    try testing.expectEqual(@as(u32, 1000), s.clipboard_keep);
    try testing.expect(s.files_in_root);
    try testing.expectEqualStrings("", s.terminal);
    try testing.expectEqualStrings(default_theme, s.theme);
    try testing.expectEqual(@as(usize, 1), s.open_with.count());
    try testing.expectEqualStrings("mpv.desktop", s.appFor("", .video).?);
}

test "written settings read back the same, unknown keys kept" {
    var s = Settings.parse(testing.allocator,
        \\theme = dracula
        \\future_option = 42
        \\suggestions = false
        \\editor = hx
        \\[open-with]
        \\markdown = md.desktop
        \\.csv = office.desktop
    );
    defer s.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try s.write(&out.writer);
    var back = Settings.parse(testing.allocator, out.written());
    defer back.deinit();
    try testing.expectEqualStrings("dracula", back.theme);
    try testing.expect(!back.suggestions);
    try testing.expectEqualStrings("hx", back.editor);
    try testing.expectEqualStrings("md.desktop", back.appFor("", .markdown).?);
    try testing.expectEqualStrings("office.desktop", back.appFor(".csv", null).?);
    try testing.expectEqual(@as(usize, 1), back.unknown.items.len);
    try testing.expectEqualStrings("future_option = 42", back.unknown.items[0]);
}

test "open-with: extension beats kind, Markdown falls back to text" {
    var s = Settings.init(testing.allocator);
    defer s.deinit();
    try s.setOpenWith("text", "zed.desktop");
    try testing.expectEqualStrings("zed.desktop", s.appFor(".md", .markdown).?);
    try s.setOpenWith("markdown", "obsidian.desktop");
    try testing.expectEqualStrings("obsidian.desktop", s.appFor(".md", .markdown).?);
    try s.setOpenWith(".md", "typora.desktop");
    try testing.expectEqualStrings("typora.desktop", s.appFor(".md", .markdown).?);
    try s.setOpenWith(".md", "");
    try s.setOpenWith("markdown", "");
    try testing.expectEqualStrings("zed.desktop", s.appFor(".md", .markdown).?);
    try testing.expectEqual(@as(?[]const u8, null), s.appFor("", .pdf));
    try testing.expectError(error.BadApp, s.setOpenWith("pdf", "x\ny.desktop"));
}

test "save is atomic and owner-only; load survives a missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rel: [4096]u8 = undefined;
    var buf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &rel);
    const path = try std.fmt.bufPrintZ(&buf, "{s}/sub/settings.conf", .{dir});

    var missing = Settings.load(testing.allocator, path);
    defer missing.deinit();
    try testing.expectEqualStrings(default_theme, missing.theme);

    var s = Settings.init(testing.allocator);
    defer s.deinit();
    try testing.expect(s.setChoice(.text_size, "small"));
    try s.save(testing.allocator, path);
    const before = Stamp.of(path);
    var back = Settings.load(testing.allocator, path);
    defer back.deinit();
    try testing.expectEqual(TextSize.small, back.text_size);
    var st: std.os.linux.Statx = undefined;
    _ = std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .MODE = true }, &st);
    try testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);

    try testing.expect(s.setChoice(.text_size, "large"));
    try s.save(testing.allocator, path);
    try testing.expect(!Stamp.of(path).eql(before));
}
