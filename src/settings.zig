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
const sys = @import("os");
const Kind = core.file_kind.Kind;
const assert = std.debug.assert;

pub const default_theme = "lumen-dark";

pub const TextSize = enum { small, default, large };
pub const Position = enum { upper_third, center };
pub const Width = enum { narrow, default, wide };
pub const Height = enum { short, default, tall };
/// Row height and icon size.
pub const Density = enum { compact, default, comfortable };

/// On/off settings.
pub const Toggle = enum { files_in_root, suggestions, clipboard };
/// Settings whose value is one word: a theme's or a style's id.
pub const Text = enum { theme, style };
/// Settings with a list of values to pick from.
pub const Choice = enum {
    text_size,
    opacity,
    position,
    width,
    height,
    density,
    icon_theme,
    clipboard_keep,
    terminal,
    editor,
};

pub const opacity_choices = [_]u8{ 100, 97, 90, 80 };
pub const keep_choices = [_]u32{ 100, 500, 1000, 5000 };

/// What a hand-edited file may set beyond the choices Settings offers.
const opacity_percent_min = 50;
const opacity_percent_default = 97;
const opacity_percent_max = 100;
const clipboard_keep_min = 10;
const clipboard_keep_default = 1000;
const clipboard_keep_max = 100_000;
/// A value written back into the file: a word, not a paragraph.
const token_bytes_max = 200;
/// The heading of the file's second part: which app opens each kind.
const open_with_section = "[open-with]";

comptime {
    for (opacity_choices) |choice| {
        assert(choice >= opacity_percent_min);
        assert(choice <= opacity_percent_max);
    }
    for (keep_choices) |choice| {
        assert(choice >= clipboard_keep_min);
        assert(choice <= clipboard_keep_max);
    }
    // The defaults are among the choices Settings offers.
    assert(std.mem.findScalar(u8, &opacity_choices, opacity_percent_default) != null);
    assert(std.mem.findScalar(u32, &keep_choices, clipboard_keep_default) != null);
}

/// Terminal emulators and editors offered when installed: each is its
/// command, then the name Settings shows.
pub const terminals = [_][2][:0]const u8{
    .{ "ghostty", "Ghostty" },
    .{ "kitty", "Kitty" },
    .{ "alacritty", "Alacritty" },
    .{ "foot", "Foot" },
    .{ "wezterm", "WezTerm" },
    .{ "konsole", "Konsole" },
    .{ "gnome-terminal", "GNOME Terminal" },
    .{ "xterm", "XTerm" },
};
pub const editors = [_][2][:0]const u8{
    .{ "nvim", "Neovim" },
    .{ "vim", "Vim" },
    .{ "hx", "Helix" },
    .{ "nano", "nano" },
    .{ "micro", "micro" },
    .{ "emacs", "Emacs" },
    .{ "code", "VS Code" },
    .{ "codium", "VSCodium" },
    .{ "zed", "Zed" },
    .{ "subl", "Sublime Text" },
    .{ "kate", "Kate" },
    .{ "gedit", "gedit" },
    .{ "gnome-text-editor", "GNOME Text Editor" },
};

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    theme: []const u8 = default_theme,
    text_size: TextSize = .default,
    /// Window background opacity, percent.
    opacity: u8 = opacity_percent_default,
    position: Position = .upper_third,
    width: Width = .default,
    height: Height = .default,
    density: Density = .default,
    files_in_root: bool = true,
    suggestions: bool = true,
    clipboard: bool = true,
    clipboard_keep: u32 = clipboard_keep_default,
    /// Command names; empty is automatic ($TERMINAL / $EDITOR, then the
    /// first one installed).
    terminal: []const u8 = "",
    editor: []const u8 = "",
    /// An icon theme for Lumen only; empty follows the desktop.
    icon_theme: []const u8 = "",
    /// The style in use (Change Theme > Styles): a built-in one or a folder
    /// in ~/.config/lumen/styles; empty is Lumen's own look.
    style: []const u8 = "",
    /// A kind's name ("pdf") or an extension (".log") → desktop file id.
    open_with: std.array_hash_map.String([]const u8) = .empty,
    /// `key = value` lines this version does not know, kept as they were.
    unknown: std.ArrayList([]const u8) = .empty,
    /// Memory ran out while reading the file, or it was longer than what was
    /// read: some of it is missing here, so `save` refuses to write this
    /// back over it.
    incomplete: bool = false,

    pub fn init(gpa: std.mem.Allocator) Settings {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(settings: *Settings) void {
        settings.arena.deinit();
        settings.* = undefined;
    }

    fn allocator(settings: *Settings) std.mem.Allocator {
        return settings.arena.allocator();
    }

    /// Settings from the text of a settings file.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) Settings {
        var settings = Settings.init(gpa);
        var section_open_with = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = withoutComment(std.mem.trim(u8, raw_line, " \t\r"));
            if (line.len == 0) continue;
            if (line[0] == '[') {
                section_open_with = std.mem.eql(u8, line, open_with_section);
                continue;
            }
            const equals = std.mem.findScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..equals], " \t");
            const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
            if (section_open_with) {
                settings.setOpenWith(key, value) catch |err| switch (err) {
                    // A bad line is ignored, like a bad value anywhere else.
                    error.BadKey, error.BadApp => {},
                    error.OutOfMemory => settings.incomplete = true,
                };
            } else if (!settings.set(key, value) and isToken(key)) {
                settings.keepUnknown(line) catch {
                    settings.incomplete = true;
                };
            }
        }
        return settings;
    }

    /// `line` without a comment: a whole-line one (`#`, `;`) or one after
    /// " #".
    fn withoutComment(line: []const u8) []const u8 {
        if (line.len > 0 and (line[0] == '#' or line[0] == ';')) return "";
        const comment = std.mem.find(u8, line, " #") orelse return line;
        return std.mem.trimEnd(u8, line[0..comment], " \t");
    }

    fn keepUnknown(settings: *Settings, line: []const u8) std.mem.Allocator.Error!void {
        const arena = settings.allocator();
        try settings.unknown.append(arena, try arena.dupe(u8, line));
    }

    /// Sets a top-level key from its text value. False when the key is not
    /// known; a known key with a bad value keeps its current value.
    pub fn set(settings: *Settings, key: []const u8, value: []const u8) bool {
        if (std.meta.stringToEnum(Toggle, key)) |toggle| {
            if (parseBool(value)) |on| settings.setToggle(toggle, on);
            return true;
        }
        if (std.meta.stringToEnum(Choice, key)) |choice| {
            _ = settings.setChoice(choice, value);
            return true;
        }
        if (std.meta.stringToEnum(Text, key)) |text| {
            if (textValid(text, value)) switch (text) {
                inline else => |tag| settings.setText(&@field(settings, @tagName(tag)), value),
            };
            return true;
        }
        return false;
    }

    /// Whether `value` may be written as `text`: a token. An empty style is
    /// also valid, and means Lumen's own look.
    fn textValid(text: Text, value: []const u8) bool {
        return switch (text) {
            .theme => isToken(value),
            .style => value.len == 0 or isToken(value),
        };
    }

    /// Sets `field` to a copy of `value`; out of memory, it keeps its value
    /// and the settings are marked incomplete.
    fn setText(settings: *Settings, field: *[]const u8, value: []const u8) void {
        field.* = settings.allocator().dupe(u8, value) catch {
            settings.incomplete = true;
            return;
        };
    }

    // Toggle's and Choice's tags are the names of the fields they set.

    pub fn get(settings: *const Settings, toggle: Toggle) bool {
        return switch (toggle) {
            inline else => |tag| @field(settings, @tagName(tag)),
        };
    }

    pub fn setToggle(settings: *Settings, toggle: Toggle, on: bool) void {
        switch (toggle) {
            inline else => |tag| @field(settings, @tagName(tag)) = on,
        }
    }

    /// Sets a choice from its value's text ("large", "90", "kitty"); false
    /// when the value is not one of its values.
    pub fn setChoice(settings: *Settings, choice: Choice, value: []const u8) bool {
        switch (choice) {
            inline .text_size, .position, .width, .height, .density => |tag| {
                const Field = @FieldType(Settings, @tagName(tag));
                @field(settings, @tagName(tag)) = std.meta.stringToEnum(Field, value) orelse
                    return false;
            },
            .opacity => {
                const digits = std.mem.trimEnd(u8, value, "%");
                const percent = std.fmt.parseInt(u8, digits, 10) catch return false;
                if (percent < opacity_percent_min) return false;
                if (percent > opacity_percent_max) return false;
                settings.opacity = percent;
            },
            .clipboard_keep => {
                const entries = std.fmt.parseInt(u32, value, 10) catch return false;
                if (entries < clipboard_keep_min) return false;
                if (entries > clipboard_keep_max) return false;
                settings.clipboard_keep = entries;
            },
            // The tag names the field, as in `get` and `setToggle`: a text
            // choice added here can never write another one's field.
            inline .terminal, .editor, .icon_theme => |tag| {
                if (value.len > 0 and !isToken(value)) return false;
                @field(settings, @tagName(tag)) = settings.allocator().dupe(u8, value) catch {
                    settings.incomplete = true;
                    return false;
                };
            },
        }
        return true;
    }

    /// The current value of a choice as its text (what `setChoice` takes).
    pub fn choiceValue(settings: *const Settings, choice: Choice, buf: []u8) []const u8 {
        return switch (choice) {
            inline else => |tag| {
                const value = @field(settings, @tagName(tag));
                return switch (@typeInfo(@TypeOf(value))) {
                    .@"enum" => @tagName(value),
                    .int => std.mem.print(buf, "{d}", .{value}) catch "",
                    else => value,
                };
            },
        };
    }

    pub const OpenWithError = error{ BadKey, BadApp } || std.mem.Allocator.Error;

    /// `key` is a kind name or ".ext"; an empty `app` removes the entry
    /// (back to the system default).
    /// An extension key: a dot, then a short token (".log", ".tar.gz").
    const extension_key_bytes_max = 16;

    pub fn setOpenWith(settings: *Settings, key: []const u8, app: []const u8) OpenWithError!void {
        if (!isOpenWithKey(key)) return error.BadKey;
        var lowercase_buffer: [extension_key_bytes_max]u8 = undefined;
        const key_lowercase = if (key[0] == '.')
            std.ascii.lowerString(&lowercase_buffer, key)
        else
            key;
        if (app.len == 0) {
            _ = settings.open_with.orderedRemove(key_lowercase);
            return;
        }
        if (!isToken(app)) return error.BadApp;
        if (!std.mem.endsWith(u8, app, ".desktop")) return error.BadApp;
        const arena = settings.allocator();
        const key_copy = try arena.dupe(u8, key_lowercase);
        try settings.open_with.put(arena, key_copy, try arena.dupe(u8, app));
    }

    /// A kind's name ("pdf"), or a dot and an extension (".log").
    fn isOpenWithKey(key: []const u8) bool {
        if (std.meta.stringToEnum(Kind, key) != null) return true;
        if (key.len < 2 or key.len > extension_key_bytes_max) return false;
        return key[0] == '.' and isToken(key[1..]);
    }

    /// The app chosen for a file: its extension first, then its kind, then
    /// the kind it falls back to.
    pub fn appFor(settings: *const Settings, ext_key: []const u8, kind: ?Kind) ?[]const u8 {
        if (ext_key.len > 0) {
            if (settings.open_with.get(ext_key)) |app| return app;
        }
        var kind_next = kind orelse return null;
        while (true) {
            if (settings.open_with.get(@tagName(kind_next))) |app| return app;
            kind_next = kind_next.fallback() orelse return null;
        }
    }

    pub fn write(settings: *const Settings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return settings.writeKeeping(writer, settings, &.{});
    }

    /// Where `writeKeeping` takes each value from.
    const Source = struct {
        current: *const Settings,
        file: *const Settings,
        kept_keys: []const []const u8,

        /// The value to write for `key`: the file's when init.lua sets the
        /// key, else the current one. The key is named once, so it can
        /// never write one field's value under another's name.
        fn value(source: Source, comptime key: []const u8) @FieldType(Settings, key) {
            for (source.kept_keys) |kept_key| {
                if (std.mem.eql(u8, kept_key, key)) return @field(source.file, key);
            }
            return @field(source.current, key);
        }
    };

    /// Writes `settings`, except the keys in `kept`, which keep their
    /// values from `file` (keys init.lua sets stay out of the file).
    pub fn writeKeeping(
        settings: *const Settings,
        writer: *std.Io.Writer,
        file: *const Settings,
        kept: []const []const u8,
    ) std.Io.Writer.Error!void {
        const source: Source = .{ .current = settings, .file = file, .kept_keys = kept };
        try writer.print(
            \\# Lumen settings. Change them from Lumen (search "Settings") or here:
            \\# Lumen reads this file again when its window opens.
            \\
            \\# Appearance. Themes and styles: search "Change Theme" in Lumen.
            \\style = {s}
            \\theme = {s}
            \\# small, default, large
            \\text_size = {t}
            \\# Window background opacity, percent ({d}-{d})
            \\opacity = {d}
            \\# upper_third, center
            \\position = {t}
            \\# Window size: narrow, default, wide; short, default, tall
            \\width = {t}
            \\height = {t}
            \\# Rows and icons: compact, default, comfortable
            \\density = {t}
            \\# An icon theme for Lumen only (a folder in /usr/share/icons); empty
            \\# follows the desktop
            \\icon_theme = {s}
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
        , .{
            source.value("style"),
            source.value("theme"),
            source.value("text_size"),
            opacity_percent_min,
            opacity_percent_max,
            source.value("opacity"),
            source.value("position"),
            source.value("width"),
            source.value("height"),
            source.value("density"),
            source.value("icon_theme"),
            source.value("files_in_root"),
            source.value("suggestions"),
            source.value("clipboard"),
            source.value("clipboard_keep"),
            source.value("terminal"),
            source.value("editor"),
        });
        if (settings.unknown.items.len > 0) {
            try writer.writeAll("\n# Not known to this version of Lumen\n");
            for (settings.unknown.items) |line| try writer.print("{s}\n", .{line});
        }
        try writer.writeAll("\n" ++ open_with_section ++ "\n" ++
            \\# A file kind (folder pdf image video audio markdown html text office
            \\# archive) or an extension (.log) = the app's desktop file id
            \\
        );
        var iterator = settings.open_with.iterator();
        while (iterator.next()) |entry| {
            try writer.print("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    /// Reads `path`; a missing or unreadable file gives the defaults.
    pub fn load(gpa: std.mem.Allocator, path: [*:0]const u8) Settings {
        var buffer: [64 * 1024]u8 = undefined;
        const text = sys.readHead(path, &buffer);
        var settings = parse(gpa, text);
        // Filled up: the file goes on past what was read, and saving would
        // cut it there.
        if (text.len == buffer.len) settings.incomplete = true;
        return settings;
    }

    pub const SaveError = sys.Error || std.Io.Writer.Error || error{Incomplete};

    /// Writes `path` atomically (temporary file, fsync, rename): a crash or a
    /// full disk never leaves half a file. Owner-only, like Lumen's other
    /// files. The keys in `kept` keep the values the file has now.
    pub fn save(
        settings: *const Settings,
        gpa: std.mem.Allocator,
        path: [:0]const u8,
        kept: []const []const u8,
    ) SaveError!void {
        if (settings.incomplete) return error.Incomplete;
        if (std.mem.findScalarLast(u8, path, '/')) |slash| sys.mkdirP(path[0..slash]);
        var file = if (kept.len > 0) load(gpa, path.ptr) else Settings.init(gpa);
        defer file.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try settings.writeKeeping(&out.writer, &file, kept);
        try sys.writeFileAtomic(path, out.written());
    }

    pub const Check = enum { ok, unknown_key, bad_value };

    /// Whether `key = value` would be taken (`lumen.set` reports both
    /// mistakes instead of ignoring them like a hand-edited file).
    pub fn check(key: []const u8, value: []const u8) Check {
        if (std.meta.stringToEnum(Toggle, key) != null) {
            return if (parseBool(value) != null) .ok else .bad_value;
        }
        if (std.meta.stringToEnum(Choice, key)) |choice| {
            // Checked by the setter itself, on a throwaway copy, so that the
            // two can never disagree. A value is a token of at most
            // `token_bytes_max` bytes: the buffer holds its copy.
            var buffer: [1024]u8 = undefined;
            comptime assert(buffer.len > token_bytes_max);
            var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
            var probe: Settings = .{ .arena = .init(fixed.allocator()) };
            return if (probe.setChoice(choice, value)) .ok else .bad_value;
        }
        if (std.meta.stringToEnum(Text, key)) |text| {
            return if (textValid(text, value)) .ok else .bad_value;
        }
        return .unknown_key;
    }
};

pub const Stamp = sys.Stamp;

fn parseBool(text: []const u8) ?bool {
    const yes = [_][]const u8{ "true", "on", "yes", "1" };
    const no = [_][]const u8{ "false", "off", "no", "0" };
    for (yes) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    for (no) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return false;
    }
    return null;
}

/// One word of safe characters: values are written back into the file and
/// passed to programs, so no spaces, quotes or newlines.
pub fn isToken(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text.len > token_bytes_max) return false;
    for (text) |character| {
        if (!isTokenCharacter(character)) return false;
    }
    return true;
}

fn isTokenCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or
        character == '.' or character == '-' or character == '_' or character == '+';
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "defaults, then values from the file" {
    var defaults = Settings.parse(testing.allocator, "");
    defer defaults.deinit();
    try testing.expectEqualStrings(default_theme, defaults.theme);
    try testing.expect(defaults.files_in_root and defaults.clipboard);
    try testing.expectEqual(@as(u32, 1000), defaults.clipboard_keep);

    var settings = Settings.parse(testing.allocator,
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
    defer settings.deinit();
    try testing.expectEqualStrings("nord", settings.theme);
    try testing.expectEqual(TextSize.large, settings.text_size);
    try testing.expectEqual(@as(u8, 90), settings.opacity);
    try testing.expectEqual(Position.center, settings.position);
    try testing.expect(!settings.files_in_root and !settings.clipboard and settings.suggestions);
    try testing.expectEqual(@as(u32, 500), settings.clipboard_keep);
    try testing.expectEqualStrings("kitty", settings.terminal);
    try testing.expectEqualStrings("org.gnome.Evince.desktop", settings.appFor("", .pdf).?);
    const log_app = settings.appFor(".log", .text).?;
    try testing.expectEqualStrings("org.gnome.TextEditor.desktop", log_app);
}

test "bad values keep the default, bad lines are ignored" {
    var settings = Settings.parse(testing.allocator,
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
    defer settings.deinit();
    try testing.expectEqual(TextSize.default, settings.text_size);
    try testing.expectEqual(@as(u8, 97), settings.opacity);
    try testing.expectEqual(@as(u32, 1000), settings.clipboard_keep);
    try testing.expect(settings.files_in_root);
    try testing.expectEqualStrings("", settings.terminal);
    try testing.expectEqualStrings(default_theme, settings.theme);
    try testing.expectEqual(@as(usize, 1), settings.open_with.count());
    try testing.expectEqualStrings("mpv.desktop", settings.appFor("", .video).?);
}

test "written settings read back the same, unknown keys kept" {
    var settings = Settings.parse(testing.allocator,
        \\theme = dracula
        \\future_option = 42
        \\suggestions = false
        \\editor = hx
        \\[open-with]
        \\markdown = md.desktop
        \\.csv = office.desktop
    );
    defer settings.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try settings.write(&out.writer);
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
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try settings.setOpenWith("text", "zed.desktop");
    try testing.expectEqualStrings("zed.desktop", settings.appFor(".md", .markdown).?);
    try settings.setOpenWith("markdown", "obsidian.desktop");
    try testing.expectEqualStrings("obsidian.desktop", settings.appFor(".md", .markdown).?);
    try settings.setOpenWith(".md", "typora.desktop");
    try testing.expectEqualStrings("typora.desktop", settings.appFor(".md", .markdown).?);
    try settings.setOpenWith(".md", "");
    try settings.setOpenWith("markdown", "");
    try testing.expectEqualStrings("zed.desktop", settings.appFor(".md", .markdown).?);
    try testing.expectEqual(@as(?[]const u8, null), settings.appFor("", .pdf));
    try testing.expectError(error.BadApp, settings.setOpenWith("pdf", "x\ny.desktop"));
}

test "save is atomic and owner-only; load survives a missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rel: [4096]u8 = undefined;
    var buf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &rel);
    const path = try std.mem.printSentinel(&buf, "{s}/sub/settings.conf", .{dir}, 0);

    var missing = Settings.load(testing.allocator, path);
    defer missing.deinit();
    try testing.expectEqualStrings(default_theme, missing.theme);

    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expect(settings.setChoice(.text_size, "small"));
    try settings.save(testing.allocator, path, &.{});
    const before = Stamp.of(path);
    var back = Settings.load(testing.allocator, path);
    defer back.deinit();
    try testing.expectEqual(TextSize.small, back.text_size);
    var st: std.os.linux.Statx = undefined;
    _ = std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .MODE = true }, &st);
    try testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);

    try testing.expect(settings.setChoice(.text_size, "large"));
    try settings.save(testing.allocator, path, &.{});
    try testing.expect(!Stamp.of(path).eql(before));

    // Keys init.lua sets keep the file's values when saving.
    try testing.expect(settings.setChoice(.width, "wide"));
    try testing.expect(settings.setChoice(.text_size, "small"));
    try settings.save(testing.allocator, path, &.{"width"});
    var kept = Settings.load(testing.allocator, path);
    defer kept.deinit();
    try testing.expectEqual(Width.default, kept.width);
    try testing.expectEqual(TextSize.small, kept.text_size);
}

test "each text choice sets its own field" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expect(settings.setChoice(.terminal, "kitty"));
    try testing.expect(settings.setChoice(.editor, "hx"));
    try testing.expect(settings.setChoice(.icon_theme, "Papirus"));
    try testing.expectEqualStrings("kitty", settings.terminal);
    try testing.expectEqualStrings("hx", settings.editor);
    try testing.expectEqualStrings("Papirus", settings.icon_theme);
    try testing.expect(!settings.setChoice(.editor, "rm -rf"));
    try testing.expectEqualStrings("hx", settings.editor);
}

test "check tells unknown keys from bad values" {
    try testing.expectEqual(Settings.Check.ok, Settings.check("width", "wide"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("density", "compact"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("suggestions", "off"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("opacity", "90"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("theme", "midnight"));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("width", "huge"));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("opacity", "10"));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("clipboard", "maybe"));
    try testing.expectEqual(Settings.Check.unknown_key, Settings.check("colour", "red"));
}
