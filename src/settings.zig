//! Lumen's settings, in $XDG_CONFIG_HOME/lumen/settings.conf: plain
//! `key = value` lines a person can edit by hand, and an `[open-with]`
//! section mapping file kinds or extensions to apps. The Settings command
//! writes the same file; Lumen reads it again whenever it changed, so a hand
//! edit shows the next time the window opens.
//!
//! Anything unreadable falls back to its default: a broken file never stops
//! Lumen from starting. A save keeps the file as it is (comments, unknown
//! keys and sections, lines it cannot read) and rewrites only what changed.

const std = @import("std");
const core = @import("core");
const sys = @import("os");
const Kind = core.file_kind.Kind;
const assert = std.debug.assert;

pub const theme_default = "lumen-dark";

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
pub const clipboard_keep_max: u32 = 5000;
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

/// A terminal emulator or an editor Settings offers when it is installed.
pub const Program = struct {
    /// What is run, and what the setting's value is.
    command: [:0]const u8,
    /// The name Settings shows.
    title: [:0]const u8,
};

/// Terminal emulators and editors offered when installed.
pub const terminals = [_]Program{
    .{ .command = "ghostty", .title = "Ghostty" },
    .{ .command = "kitty", .title = "Kitty" },
    .{ .command = "alacritty", .title = "Alacritty" },
    .{ .command = "foot", .title = "Foot" },
    .{ .command = "wezterm", .title = "WezTerm" },
    .{ .command = "konsole", .title = "Konsole" },
    .{ .command = "gnome-terminal", .title = "GNOME Terminal" },
    .{ .command = "xterm", .title = "XTerm" },
};
pub const editors = [_]Program{
    .{ .command = "nvim", .title = "Neovim" },
    .{ .command = "vim", .title = "Vim" },
    .{ .command = "hx", .title = "Helix" },
    .{ .command = "nano", .title = "nano" },
    .{ .command = "micro", .title = "micro" },
    .{ .command = "emacs", .title = "Emacs" },
    .{ .command = "code", .title = "VS Code" },
    .{ .command = "codium", .title = "VSCodium" },
    .{ .command = "zed", .title = "Zed" },
    .{ .command = "subl", .title = "Sublime Text" },
    .{ .command = "kate", .title = "Kate" },
    .{ .command = "gedit", .title = "gedit" },
    .{ .command = "gnome-text-editor", .title = "GNOME Text Editor" },
};

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    theme: []const u8 = theme_default,
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
    /// `[open-with]` lines this version does not know or whose app it does
    /// not take, and the user's comments there, kept as they were.
    unknown_open_with: std.ArrayList([]const u8) = .empty,
    /// The user's comment lines before any section, kept as they were
    /// (written after the known keys).
    comments: std.ArrayList([]const u8) = .empty,
    /// Known top-level keys whose value in the file was not recognized by
    /// this version, kept as they were until changed to a valid value.
    unrecognized_known: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Sections this version does not know (`[name]` and the lines under
    /// it), kept as they were: written back after `[open-with]`.
    unknown_sections: std.ArrayList([]const u8) = .empty,
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

    /// The part of the file a line is in: before any section, `[open-with]`,
    /// or a section this version does not know.
    const Section = enum { top, open_with, other };

    /// Settings from the text of a settings file.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) Settings {
        var settings = Settings.init(gpa);
        var section: Section = .top;
        // Known keys a line has set: a later line with a value this
        // version does not take leaves the setting as it is, and is not
        // what a save writes for it (MYP-576).
        var applied_keys: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const raw_trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (raw_trimmed.len == 0) continue;
            if (!std.unicode.utf8ValidateSlice(raw_trimmed) or
                std.mem.findScalar(u8, raw_trimmed, 0) != null) continue;
            // The user's notes and commented-out values survive a save
            // (MYP-566); the ones Lumen writes itself are written again.
            if (raw_trimmed[0] == '#' or raw_trimmed[0] == ';') {
                if (isOwnComment(raw_trimmed)) continue;
                const kept = switch (section) {
                    .top => &settings.comments,
                    .open_with => &settings.unknown_open_with,
                    .other => &settings.unknown_sections,
                };
                settings.keepLine(kept, raw_trimmed) catch {
                    settings.incomplete = true;
                };
                continue;
            }
            const line = withoutComment(raw_trimmed);
            if (line.len == 0) continue;
            if (line[0] == '[') {
                section = if (std.mem.eql(u8, line, open_with_section)) .open_with else .other;
            }
            // Another version's section: none of its keys are ours, but it
            // survives a save.
            if (section == .other) {
                settings.keepLine(&settings.unknown_sections, raw_trimmed) catch {
                    settings.incomplete = true;
                };
                continue;
            }
            if (line[0] == '[') continue;
            const equals = std.mem.findScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..equals], " \t");
            const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
            if (section == .open_with) {
                settings.setOpenWith(key, value) catch |err| switch (err) {
                    error.BadKey => if (isToken(key) and value.len > 0) {
                        settings.keepLine(&settings.unknown_open_with, raw_trimmed) catch {
                            settings.incomplete = true;
                        };
                    },
                    // Kept as it is until that kind or extension is given
                    // an app (MYP-530).
                    error.BadApp => settings.keepLine(&settings.unknown_open_with, raw_trimmed) catch {
                        settings.incomplete = true;
                    },
                    error.OutOfMemory => settings.incomplete = true,
                };
            } else {
                switch (settings.setFromFile(key, value)) {
                    .applied => applied_keys.put(settings.allocator(), key, {}) catch {
                        settings.incomplete = true;
                    },
                    .unrecognized_value => if (!applied_keys.contains(key)) {
                        settings.keepUnrecognizedKnown(key, raw_trimmed);
                    },
                    .unknown_key => if (isToken(key)) {
                        settings.keepLine(&settings.unknown, raw_trimmed) catch {
                            settings.incomplete = true;
                        };
                    },
                }
            }
        }
        return settings;
    }

    /// The comment lines `write` puts in the file itself, and those earlier
    /// versions wrote: written again by every save, they are not the
    /// user's. A test checks `write` adds no other.
    const own_comments = [_][]const u8{
        "# Lumen settings. Change them from Lumen (search \"Settings\") or here:",
        "# Lumen reads this file again when its window opens.",
        "# Appearance. Themes and styles: search \"Change Theme\" in Lumen.",
        "# Appearance. Themes: search \"Change Theme\" in Lumen.",
        "# small, default, large",
        std.fmt.comptimePrint(
            "# Window background opacity, percent ({d}-{d})",
            .{ opacity_percent_min, opacity_percent_max },
        ),
        "# upper_third, center",
        "# Window size: narrow, default, wide; short, default, tall",
        "# Rows and icons: compact, default, comfortable",
        "# An icon theme for Lumen only (a folder in /usr/share/icons); empty",
        "# follows the desktop",
        "# Search",
        "# Clipboard history, and how many entries it keeps",
        "# Commands; empty is automatic ($TERMINAL, $VISUAL/$EDITOR)",
        unknown_header,
        "# A file kind (folder pdf image video audio markdown html text office",
        "# archive) or an extension (.log) = the app's desktop file id",
    };

    const unknown_header = "# Not known to this version of Lumen";

    fn isOwnComment(line: []const u8) bool {
        for (own_comments) |own| if (std.mem.eql(u8, line, own)) return true;
        return false;
    }

    /// `line` without a comment: a whole-line one (`#`, `;`) or one after
    /// " #".
    fn withoutComment(line: []const u8) []const u8 {
        if (line.len > 0 and (line[0] == '#' or line[0] == ';')) return "";
        const comment = std.mem.find(u8, line, " #") orelse return line;
        return std.mem.trimEnd(u8, line[0..comment], " \t");
    }

    fn keepLine(
        settings: *Settings,
        lines: *std.ArrayList([]const u8),
        line: []const u8,
    ) std.mem.Allocator.Error!void {
        const arena = settings.allocator();
        try lines.append(arena, try arena.dupe(u8, line));
    }

    fn keepUnrecognizedKnown(settings: *Settings, key: []const u8, raw_line: []const u8) void {
        const arena = settings.allocator();
        const key_copy = arena.dupe(u8, key) catch {
            settings.incomplete = true;
            return;
        };
        const line_copy = arena.dupe(u8, raw_line) catch {
            settings.incomplete = true;
            return;
        };
        settings.unrecognized_known.put(arena, key_copy, line_copy) catch {
            settings.incomplete = true;
        };
    }

    const FileSetResult = enum { applied, unrecognized_value, unknown_key };

    fn setFromFile(settings: *Settings, key: []const u8, value: []const u8) FileSetResult {
        if (std.meta.stringToEnum(Toggle, key)) |toggle| {
            const enabled = parseBool(value) orelse return .unrecognized_value;
            settings.setToggle(toggle, enabled);
            return .applied;
        }
        if (std.meta.stringToEnum(Choice, key)) |choice| {
            return if (settings.setChoice(choice, value)) .applied else .unrecognized_value;
        }
        if (std.meta.stringToEnum(Text, key)) |text| {
            return if (settings.setTextValue(text, value)) .applied else .unrecognized_value;
        }
        return .unknown_key;
    }

    /// Sets a top-level key from its text value. False when the key is not
    /// known; a known key with a bad value keeps its current value.
    pub fn set(settings: *Settings, key: []const u8, value: []const u8) bool {
        if (std.meta.stringToEnum(Toggle, key)) |toggle| {
            if (parseBool(value)) |enabled| settings.setToggle(toggle, enabled);
            return true;
        }
        if (std.meta.stringToEnum(Choice, key)) |choice| {
            _ = settings.setChoice(choice, value);
            return true;
        }
        if (std.meta.stringToEnum(Text, key)) |text| {
            _ = settings.setTextValue(text, value);
            return true;
        }
        return false;
    }

    /// Sets a text setting (theme, style) to a copy of `value`. False, with
    /// the current value kept, when `value` is not one it may hold.
    pub fn setTextValue(settings: *Settings, text: Text, value: []const u8) bool {
        if (!textValid(text, value)) return false;
        switch (text) {
            inline else => |tag| {
                settings.setText(&@field(settings, @tagName(tag)), value);
                _ = settings.unrecognized_known.remove(@tagName(tag));
            },
        }
        return true;
    }

    /// Whether `value` may be written as `text`: a token. An empty style is
    /// also valid, and means Lumen's own look. "." and ".." are rejected for
    /// style names because they are joined into `<config>/styles/<style>`.
    fn textValid(text: Text, value: []const u8) bool {
        return switch (text) {
            .theme => isToken(value),
            .style => value.len == 0 or
                (isToken(value) and !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..")),
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

    pub fn setToggle(settings: *Settings, toggle: Toggle, enabled: bool) void {
        switch (toggle) {
            inline else => |tag| {
                @field(settings, @tagName(tag)) = enabled;
                _ = settings.unrecognized_known.remove(@tagName(tag));
            },
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
                _ = settings.unrecognized_known.remove(@tagName(tag));
            },
            .opacity => {
                const digits = std.mem.trimEnd(u8, value, "%");
                const percent = std.fmt.parseInt(u8, digits, 10) catch return false;
                if (percent < opacity_percent_min) return false;
                if (percent > opacity_percent_max) return false;
                settings.opacity = percent;
                _ = settings.unrecognized_known.remove("opacity");
            },
            .clipboard_keep => {
                const entries = std.fmt.parseInt(u32, value, 10) catch return false;
                if (entries < clipboard_keep_min) return false;
                if (entries > clipboard_keep_max) return false;
                settings.clipboard_keep = entries;
                _ = settings.unrecognized_known.remove("clipboard_keep");
            },
            // The tag names the field, as in `get` and `setToggle`: a text
            // choice added here can never write another one's field.
            inline .terminal, .editor, .icon_theme => |tag| {
                if (value.len > 0 and !isToken(value)) return false;
                @field(settings, @tagName(tag)) = settings.allocator().dupe(u8, value) catch {
                    settings.incomplete = true;
                    return false;
                };
                _ = settings.unrecognized_known.remove(@tagName(tag));
            },
        }
        return true;
    }

    /// The current value of a choice as its text (what `setChoice` takes).
    pub fn choiceValue(
        settings: *const Settings,
        choice: Choice,
        number_buffer: []u8,
    ) []const u8 {
        return switch (choice) {
            inline else => |tag| {
                const value = @field(settings, @tagName(tag));
                return switch (@typeInfo(@TypeOf(value))) {
                    .@"enum" => @tagName(value),
                    .int => std.mem.print(number_buffer, "{d}", .{value}) catch "",
                    else => value,
                };
            },
        };
    }

    pub const OpenWithError = error{ BadKey, BadApp } || std.mem.Allocator.Error;

    /// An extension key: a dot, then a short token (".log", ".tar.gz").
    const extension_key_bytes_max = 16;

    /// `key` is a kind name or ".ext"; an empty `app` removes the entry
    /// (back to the system default).
    pub fn setOpenWith(settings: *Settings, key: []const u8, app: []const u8) OpenWithError!void {
        if (!isOpenWithKey(key)) return error.BadKey;
        var lowercase_buffer: [extension_key_bytes_max]u8 = undefined;
        const key_lowercase = if (key[0] == '.')
            std.ascii.lowerString(&lowercase_buffer, key)
        else
            key;
        if (app.len == 0) {
            _ = settings.open_with.orderedRemove(key_lowercase);
            settings.forgetKeptOpenWith(key_lowercase);
            return;
        }
        if (!isToken(app)) return error.BadApp;
        if (!std.mem.endsWith(u8, app, ".desktop")) return error.BadApp;
        settings.forgetKeptOpenWith(key_lowercase);
        const arena = settings.allocator();
        const key_copy = try arena.dupe(u8, key_lowercase);
        try settings.open_with.put(arena, key_copy, try arena.dupe(u8, app));
    }

    /// Drops the kept `[open-with]` lines for `key` (lowercase for an
    /// extension) whose app this version did not take: the app set now is
    /// the one that counts.
    fn forgetKeptOpenWith(settings: *Settings, key: []const u8) void {
        var line_index: usize = 0;
        while (line_index < settings.unknown_open_with.items.len) {
            if (keptLineSets(settings.unknown_open_with.items[line_index], key)) {
                _ = settings.unknown_open_with.orderedRemove(line_index);
            } else {
                line_index += 1;
            }
        }
    }

    /// Whether a kept `[open-with]` line is one for `key` (lowercase for an
    /// extension).
    fn keptLineSets(line: []const u8, key: []const u8) bool {
        const equals = std.mem.findScalar(u8, line, '=') orelse return false;
        return sameOpenWithKey(std.mem.trim(u8, line[0..equals], " \t"), key);
    }

    /// Kinds match exactly, extensions in any case.
    fn sameOpenWithKey(a: []const u8, b: []const u8) bool {
        if (a.len > 0 and a[0] == '.') return std.ascii.eqlIgnoreCase(a, b);
        return std.mem.eql(u8, a, b);
    }

    /// `key` as `open_with` holds it: an extension in lowercase, in `buffer`.
    fn openWithMapKey(buffer: *[extension_key_bytes_max]u8, key: []const u8) []const u8 {
        assert(key.len <= buffer.len);
        return if (key[0] == '.') std.ascii.lowerString(buffer, key) else key;
    }

    /// Whether `a` and `b` choose the same for `key`: the same app, and both
    /// or neither keep a line this version did not take.
    fn sameOpenWith(a: *const Settings, b: *const Settings, key: []const u8) bool {
        const app_a = a.open_with.get(key);
        const app_b = b.open_with.get(key);
        if ((app_a == null) != (app_b == null)) return false;
        if (app_a != null and !std.mem.eql(u8, app_a.?, app_b.?)) return false;
        return keepsOpenWithLine(a, key) == keepsOpenWithLine(b, key);
    }

    fn keepsOpenWithLine(settings: *const Settings, key: []const u8) bool {
        for (settings.unknown_open_with.items) |line| if (keptLineSets(line, key)) return true;
        return false;
    }

    /// A kind's name ("pdf"), or a dot and an extension (".log").
    fn isOpenWithKey(key: []const u8) bool {
        if (std.meta.stringToEnum(Kind, key) != null) return true;
        if (key.len < 2 or key.len > extension_key_bytes_max) return false;
        return key[0] == '.' and isToken(key[1..]);
    }

    /// The app chosen for a file: its extension first, then its kind, then
    /// the kind it falls back to.
    pub fn appFor(settings: *const Settings, extension_key: []const u8, kind: ?Kind) ?[]const u8 {
        if (extension_key.len > 0) {
            if (settings.open_with.get(extension_key)) |app| return app;
        }
        var kind_next = kind orelse return null;
        while (true) {
            if (settings.open_with.get(@tagName(kind_next))) |app| return app;
            kind_next = kind_next.fallback() orelse return null;
        }
    }

    /// The app chosen for the file called `name`: its longest extension
    /// first (".tar.gz" before ".gz"), then as `appFor` does.
    pub fn appForName(settings: *const Settings, name: []const u8, kind: ?Kind) ?[]const u8 {
        // A leading dot starts a hidden name (".bashrc"), not an extension.
        var start: usize = 1;
        while (std.mem.findScalarPos(u8, name, start, '.')) |dot| : (start = dot + 1) {
            const suffix = name[dot..];
            if (suffix.len < 2) break;
            if (suffix.len > extension_key_bytes_max) continue;
            var lowercase_buffer: [extension_key_bytes_max]u8 = undefined;
            const key = std.ascii.lowerString(&lowercase_buffer, suffix);
            if (settings.open_with.get(key)) |app| return app;
        }
        return settings.appFor("", kind);
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
        fn owner(source: Source, key: []const u8) *const Settings {
            for (source.kept_keys) |kept_key| {
                if (std.mem.eql(u8, kept_key, key)) return source.file;
            }
            return source.current;
        }

        /// Formats `key = <value>` or returns the preserved unrecognized line from the file.
        fn line(source: Source, buf: []u8, comptime key: []const u8) []const u8 {
            const src = source.owner(key);
            if (src.unrecognized_known.get(key)) |raw| return raw;
            const field_value = @field(src, key);
            return switch (@typeInfo(@TypeOf(field_value))) {
                .@"enum" => std.fmt.bufPrint(buf, "{s} = {t}", .{ key, field_value }) catch unreachable,
                .int => std.fmt.bufPrint(buf, "{s} = {d}", .{ key, field_value }) catch unreachable,
                .bool => std.fmt.bufPrint(buf, "{s} = {}", .{ key, field_value }) catch unreachable,
                else => std.fmt.bufPrint(buf, "{s} = {s}", .{ key, field_value }) catch unreachable,
            };
        }

        /// `line` for a key named at run time; null when it is not a known
        /// one.
        fn lineFor(source: Source, buf: *[line_bytes_max]u8, key: []const u8) ?[]const u8 {
            inline for (known_keys) |known| {
                if (std.mem.eql(u8, known, key)) return source.line(buf, known);
            }
            return null;
        }

        /// The known keys a file has no line for, after the last line of its
        /// top part; whether there were any.
        fn writeMissingKnown(
            source: Source,
            writer: *std.Io.Writer,
            seen: *const [known_keys.len]bool,
            after_lines: bool,
        ) std.Io.Writer.Error!bool {
            var any = false;
            inline for (known_keys, 0..) |key, index| {
                if (!seen[index]) {
                    if (!any and after_lines) try writer.writeAll("\n");
                    any = true;
                    var buffer: [line_bytes_max]u8 = undefined;
                    try writer.print("{s}\n", .{source.line(&buffer, key)});
                }
            }
            return any;
        }
    };

    /// A `key = value` line `Source.line` formats: the longest key, " = "
    /// and a token.
    const line_bytes_max = 256;

    /// The top-level keys this version knows, in the order `writeKnown`
    /// writes them.
    const known_keys = [_][]const u8{
        "style",       "theme",     "text_size",      "opacity",    "position",
        "width",       "height",    "density",        "icon_theme", "files_in_root",
        "suggestions", "clipboard", "clipboard_keep", "terminal",   "editor",
    };

    comptime {
        @setEvalBranchQuota(20_000);
        const tags = @typeInfo(Toggle).@"enum".field_names.len +
            @typeInfo(Choice).@"enum".field_names.len + @typeInfo(Text).@"enum".field_names.len;
        assert(known_keys.len == tags);
        for (known_keys) |key| {
            assert(std.meta.stringToEnum(Toggle, key) != null or
                std.meta.stringToEnum(Choice, key) != null or
                std.meta.stringToEnum(Text, key) != null);
            assert(key.len + " = ".len + token_bytes_max <= line_bytes_max);
        }
    }

    fn knownIndex(key: []const u8) ?usize {
        for (known_keys, 0..) |known, index| if (std.mem.eql(u8, known, key)) return index;
        return null;
    }

    /// Writes `settings`, except the keys in `kept`, which keep their
    /// values from `file` (keys init.lua sets stay out of the file).
    pub fn writeKeeping(
        settings: *const Settings,
        writer: *std.Io.Writer,
        file: *const Settings,
        kept: []const []const u8,
    ) std.Io.Writer.Error!void {
        const source: Source = .{ .current = settings, .file = file, .kept_keys = kept };
        try writeKnown(writer, source);
        try settings.writeComments(writer);
        try settings.writeUnknown(writer);
        try settings.writeOpenWith(writer);
        try settings.writeUnknownSections(writer);
    }

    /// The keys this version knows, with comments that say what each takes.
    fn writeKnown(writer: *std.Io.Writer, source: Source) std.Io.Writer.Error!void {
        var b0: [256]u8 = undefined;
        var b1: [256]u8 = undefined;
        var b2: [128]u8 = undefined;
        var b3: [128]u8 = undefined;
        var b4: [128]u8 = undefined;
        var b5: [128]u8 = undefined;
        var b6: [128]u8 = undefined;
        var b7: [128]u8 = undefined;
        var b8: [256]u8 = undefined;
        var b9: [128]u8 = undefined;
        var b10: [128]u8 = undefined;
        var b11: [128]u8 = undefined;
        var b12: [128]u8 = undefined;
        var b13: [256]u8 = undefined;
        var b14: [256]u8 = undefined;
        try writer.print(
            \\# Lumen settings. Change them from Lumen (search "Settings") or here:
            \\# Lumen reads this file again when its window opens.
            \\
            \\# Appearance. Themes and styles: search "Change Theme" in Lumen.
            \\{s}
            \\{s}
            \\# small, default, large
            \\{s}
            \\# Window background opacity, percent ({d}-{d})
            \\{s}
            \\# upper_third, center
            \\{s}
            \\# Window size: narrow, default, wide; short, default, tall
            \\{s}
            \\{s}
            \\# Rows and icons: compact, default, comfortable
            \\{s}
            \\# An icon theme for Lumen only (a folder in /usr/share/icons); empty
            \\# follows the desktop
            \\{s}
            \\
            \\# Search
            \\{s}
            \\{s}
            \\
            \\# Clipboard history, and how many entries it keeps
            \\{s}
            \\{s}
            \\
            \\# Commands; empty is automatic ($TERMINAL, $VISUAL/$EDITOR)
            \\{s}
            \\{s}
            \\
        , .{
            source.line(&b0, "style"),
            source.line(&b1, "theme"),
            source.line(&b2, "text_size"),
            opacity_percent_min,
            opacity_percent_max,
            source.line(&b3, "opacity"),
            source.line(&b4, "position"),
            source.line(&b5, "width"),
            source.line(&b6, "height"),
            source.line(&b7, "density"),
            source.line(&b8, "icon_theme"),
            source.line(&b9, "files_in_root"),
            source.line(&b10, "suggestions"),
            source.line(&b11, "clipboard"),
            source.line(&b12, "clipboard_keep"),
            source.line(&b13, "terminal"),
            source.line(&b14, "editor"),
        });
    }

    /// The lines read with keys this version does not know, as they were:
    /// a newer version's settings survive a save by this one.
    fn writeUnknown(settings: *const Settings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (settings.unknown.items.len == 0) return;
        try writer.writeAll("\n" ++ unknown_header ++ "\n");
        for (settings.unknown.items) |line| try writer.print("{s}\n", .{line});
    }

    /// The user's comments read before any section, as they were.
    fn writeComments(settings: *const Settings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (settings.comments.items.len == 0) return;
        try writer.writeAll("\n");
        for (settings.comments.items) |line| try writer.print("{s}\n", .{line});
    }

    /// The sections read that this version does not know, as they were.
    fn writeUnknownSections(
        settings: *const Settings,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        for (settings.unknown_sections.items) |line| {
            if (line[0] == '[') try writer.writeAll("\n");
            try writer.print("{s}\n", .{line});
        }
    }

    /// The `[open-with]` section: the app chosen for each kind or extension.
    fn writeOpenWith(settings: *const Settings, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("\n" ++ open_with_heading);
        var iterator = settings.open_with.iterator();
        while (iterator.next()) |entry| {
            try writer.print("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        for (settings.unknown_open_with.items) |line| try writer.print("{s}\n", .{line});
    }

    const open_with_heading = open_with_section ++ "\n" ++
        \\# A file kind (folder pdf image video audio markdown html text office
        \\# archive) or an extension (.log) = the app's desktop file id
        \\
    ;

    /// The lines of a settings file, each with the part of the file it is in
    /// and the key it sets, read the way `parse` reads them.
    const FileLines = struct {
        rest: []const u8,
        section: Section = .top,

        const Line = struct {
            /// As it is in the file, without its newline.
            raw: []const u8,
            section: Section,
            /// Empty, or only spaces.
            blank: bool = false,
            /// A known top-level key, or an `[open-with]` kind or extension,
            /// the line sets; null for any other line.
            key: ?[]const u8 = null,
        };

        fn next(lines: *FileLines) ?Line {
            if (lines.rest.len == 0) return null;
            const end = std.mem.findScalar(u8, lines.rest, '\n');
            const raw = lines.rest[0 .. end orelse lines.rest.len];
            lines.rest = if (end) |newline| lines.rest[newline + 1 ..] else "";
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            if (trimmed.len == 0) return .{ .raw = raw, .section = lines.section, .blank = true };
            var line: Line = .{ .raw = raw, .section = lines.section };
            if (!std.unicode.utf8ValidateSlice(trimmed) or
                std.mem.findScalar(u8, trimmed, 0) != null) return line;
            const text = withoutComment(trimmed);
            if (text.len == 0) return line;
            if (text[0] == '[') {
                lines.section = if (std.mem.eql(u8, text, open_with_section)) .open_with else .other;
                line.section = lines.section;
                return line;
            }
            const equals = std.mem.findScalar(u8, text, '=') orelse return line;
            const key = std.mem.trim(u8, text[0..equals], " \t");
            line.key = switch (lines.section) {
                .top => if (knownIndex(key) != null) key else null,
                .open_with => if (isOpenWithKey(key)) key else null,
                .other => null,
            };
            return line;
        }
    };

    pub const WriteOverError = std.Io.Writer.Error || std.mem.Allocator.Error;

    /// Writes `settings` over the text of the file they are saved to,
    /// `original`, keeping its layout (MYP-566): every line stays where it
    /// is and as it is (comments, inline comments, lines this version cannot
    /// read), except the lines of keys whose value changed, rewritten in
    /// place with their inline comment. Known keys and `[open-with]` entries
    /// the file does not have yet go at the end of their part of it.
    /// `file` is `original` parsed; the keys in `kept` keep its values.
    pub fn writeOver(
        settings: *const Settings,
        gpa: std.mem.Allocator,
        writer: *std.Io.Writer,
        original: []const u8,
        file: *const Settings,
        kept: []const []const u8,
    ) WriteOverError!void {
        const source: Source = .{ .current = settings, .file = file, .kept_keys = kept };
        const before: Source = .{ .current = file, .file = file, .kept_keys = &.{} };
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // The `[open-with]` keys the file has a line for, as `open_with`
        // holds them.
        var open_with_in_file: std.StringHashMapUnmanaged(void) = .empty;
        var scan: FileLines = .{ .rest = original };
        while (scan.next()) |line| {
            if (line.section != .open_with) continue;
            const key = line.key orelse continue;
            var key_buffer: [extension_key_bytes_max]u8 = undefined;
            const map_key = openWithMapKey(&key_buffer, key);
            try open_with_in_file.put(arena, try arena.dupe(u8, map_key), {});
        }

        var known_seen: [known_keys.len]bool = @splat(false);
        // Changed `[open-with]` keys already written: their other lines go.
        var open_with_written: std.StringHashMapUnmanaged(void) = .empty;
        var open_with_added = false;
        var section: Section = .top;
        // Where the blank lines before the next line start: what a part of
        // the file lacks goes before the blank lines that end it.
        var blank_from: ?usize = null;
        // Whether the part of the file being written has a line yet.
        var part_written = false;
        var lines: FileLines = .{ .rest = original };
        while (lines.next()) |line| {
            const offset = @intFromPtr(line.raw.ptr) - @intFromPtr(original.ptr);
            if (line.blank) {
                if (blank_from == null) blank_from = offset;
                continue;
            }
            if (line.section != section) {
                var added = false;
                if (section == .top) {
                    added = try source.writeMissingKnown(writer, &known_seen, part_written);
                } else if (section == .open_with and !open_with_added) {
                    added = try settings.writeMissingOpenWith(writer, &open_with_in_file);
                    open_with_added = true;
                }
                // A part that ended with no blank line before the heading
                // gets one after what was added to it.
                if (added and blank_from == null) try writer.writeAll("\n");
                section = line.section;
                part_written = false;
            }
            if (blank_from) |from| try writer.writeAll(original[from..offset]);
            blank_from = null;
            part_written = true;
            const key = line.key orelse {
                try writer.print("{s}\n", .{line.raw});
                continue;
            };
            switch (line.section) {
                .top => {
                    const index = knownIndex(key).?;
                    const first = !known_seen[index];
                    known_seen[index] = true;
                    var now_buffer: [line_bytes_max]u8 = undefined;
                    var before_buffer: [line_bytes_max]u8 = undefined;
                    const now = source.lineFor(&now_buffer, key).?;
                    if (std.mem.eql(u8, now, before.lineFor(&before_buffer, key).?)) {
                        try writer.print("{s}\n", .{line.raw});
                    } else if (first) {
                        // Changed: its first line takes the new value and any
                        // other one goes (a later one would override it).
                        try writeReplaced(writer, line.raw, now);
                    }
                },
                .open_with => {
                    var key_buffer: [extension_key_bytes_max]u8 = undefined;
                    const map_key = openWithMapKey(&key_buffer, key);
                    if (sameOpenWith(settings, file, map_key)) {
                        try writer.print("{s}\n", .{line.raw});
                        continue;
                    }
                    if (open_with_written.contains(map_key)) continue;
                    try open_with_written.put(arena, try arena.dupe(u8, map_key), {});
                    // No app now: all of its lines go.
                    const app = settings.open_with.get(map_key) orelse continue;
                    var entry_buffer: [line_bytes_max]u8 = undefined;
                    const entry = std.fmt.bufPrint(&entry_buffer, "{s} = {s}", .{ key, app }) catch
                        unreachable;
                    try writeReplaced(writer, line.raw, entry);
                },
                .other => unreachable,
            }
        }
        // The end of the file ends its last part.
        if (section == .top) _ = try source.writeMissingKnown(writer, &known_seen, part_written);
        if (section == .open_with and !open_with_added) {
            _ = try settings.writeMissingOpenWith(writer, &open_with_in_file);
            open_with_added = true;
        }
        if (blank_from) |from| try writer.writeAll(original[from..]);
        if (!open_with_added and settings.hasOpenWithMissing(&open_with_in_file)) {
            try writer.writeAll("\n" ++ open_with_heading);
            _ = try settings.writeMissingOpenWith(writer, &open_with_in_file);
        }
    }

    /// `raw` with its setting replaced by `setting`, its indentation and
    /// inline comment kept.
    fn writeReplaced(
        writer: *std.Io.Writer,
        raw: []const u8,
        setting: []const u8,
    ) std.Io.Writer.Error!void {
        const unindented = std.mem.trimStart(u8, raw, " \t");
        const indent = raw[0 .. raw.len - unindented.len];
        const trimmed = std.mem.trimEnd(u8, unindented, " \t\r");
        // A value is a token, never " #": a setting with one is a line kept
        // from the file as it was, its own comment and all.
        const comment = if (std.mem.find(u8, setting, " #") == null)
            trimmed[withoutComment(trimmed).len..]
        else
            "";
        const carriage_return = if (std.mem.endsWith(u8, raw, "\r")) "\r" else "";
        try writer.print("{s}{s}{s}{s}\n", .{ indent, setting, comment, carriage_return });
    }

    /// The `[open-with]` entries the file has no line for; whether there were
    /// any.
    fn writeMissingOpenWith(
        settings: *const Settings,
        writer: *std.Io.Writer,
        in_file: *const std.StringHashMapUnmanaged(void),
    ) std.Io.Writer.Error!bool {
        var any = false;
        var iterator = settings.open_with.iterator();
        while (iterator.next()) |entry| {
            if (in_file.contains(entry.key_ptr.*)) continue;
            any = true;
            try writer.print("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return any;
    }

    fn hasOpenWithMissing(
        settings: *const Settings,
        in_file: *const std.StringHashMapUnmanaged(void),
    ) bool {
        for (settings.open_with.keys()) |key| if (!in_file.contains(key)) return true;
        return false;
    }

    /// Reads `path`; a missing or unreadable file gives the defaults. When the
    /// file exists but cannot be read (permissions, I/O error, non-regular
    /// file, or larger than the buffer), `incomplete` is set so a later `save`
    /// refuses to overwrite the user's file with defaults.
    pub fn load(gpa: std.mem.Allocator, path: [*:0]const u8) Settings {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        const read = readText(gpa, path, &text);
        var settings = parse(gpa, text.items);
        switch (read) {
            .missing, .whole => {},
            // The file goes on past what was read: saving would cut it there.
            .cut, .failed => settings.incomplete = true,
        }
        return settings;
    }

    const Read = enum { missing, whole, cut, failed };

    /// The text of `path`, up to `file_bytes_max` bytes, in `text`; nothing
    /// when it is missing or cannot be read.
    fn readText(gpa: std.mem.Allocator, path: [*:0]const u8, text: *std.ArrayList(u8)) Read {
        const fd = sys.openRegular(path) catch |err| {
            return if (err == error.NotFound) .missing else .failed;
        };
        defer sys.close(fd);
        // One byte past the limit tells a file longer than it.
        sys.readUpTo(gpa, fd, text, file_bytes_max + 1) catch {
            text.clearRetainingCapacity();
            return .failed;
        };
        if (text.items.len <= file_bytes_max) return .whole;
        text.shrinkRetainingCapacity(file_bytes_max);
        return .cut;
    }

    /// The largest settings file read: Lumen writes a few KB.
    const file_bytes_max = 64 * 1024;

    pub const KeyValue = struct { key: []const u8, value: []const u8 };

    pub const Patch = union(enum) {
        all,
        toggle: struct { key: Toggle, value: bool },
        choice: struct { key: Choice, value: []const u8 },
        text: struct { key: Text, value: []const u8 },
        open_with: struct { key: []const u8, value: []const u8 },
        keys: []const KeyValue,
    };

    fn isKeptKey(kept: []const []const u8, key: []const u8) bool {
        for (kept) |kept_key| {
            if (std.mem.eql(u8, kept_key, key)) return true;
        }
        return false;
    }

    /// Re-reads `path` before applying `patch` so external edits made while
    /// Settings was open are preserved instead of overwritten from memory.
    pub fn savePatch(
        settings: *Settings,
        gpa: std.mem.Allocator,
        path: [:0]const u8,
        kept: []const []const u8,
        patch: Patch,
    ) SaveError!void {
        if (patch == .all) return settings.save(gpa, path, kept);
        if (settings.incomplete) return error.Incomplete;
        var disk = load(gpa, path.ptr);
        errdefer disk.deinit();
        if (disk.incomplete) return error.Incomplete;
        switch (patch) {
            .all => unreachable,
            .toggle => |toggle| {
                if (!isKeptKey(kept, @tagName(toggle.key))) {
                    disk.setToggle(toggle.key, toggle.value);
                }
            },
            .choice => |choice| {
                if (!isKeptKey(kept, @tagName(choice.key))) {
                    _ = disk.setChoice(choice.key, choice.value);
                }
            },
            .text => |text| {
                if (!isKeptKey(kept, @tagName(text.key))) {
                    _ = disk.setTextValue(text.key, text.value);
                }
            },
            .open_with => |open_with| {
                disk.setOpenWith(open_with.key, open_with.value) catch |err| switch (err) {
                    error.OutOfMemory => return error.Incomplete,
                    error.BadKey, error.BadApp => {},
                };
            },
            .keys => |items| {
                for (items) |entry| {
                    if (!isKeptKey(kept, entry.key)) _ = disk.set(entry.key, entry.value);
                }
            },
        }
        if (disk.incomplete) return error.Incomplete;
        try disk.save(gpa, path, kept);
        settings.deinit();
        settings.* = disk;
    }

    pub const SaveError = sys.Error || WriteOverError || error{ Incomplete, TooLarge };

    /// Writes `path` atomically (temporary file, fsync, rename): a crash or a
    /// full disk never leaves half a file. Owner-only, like Lumen's other
    /// files. The keys in `kept` keep the values the file has now. An
    /// existing file keeps its layout and the user's comments (`writeOver`);
    /// a new or empty one is written whole, with a comment for each setting.
    pub fn save(
        settings: *const Settings,
        gpa: std.mem.Allocator,
        path: [:0]const u8,
        kept: []const []const u8,
    ) SaveError!void {
        if (settings.incomplete) return error.Incomplete;
        if (std.mem.findScalarLast(u8, path, '/')) |slash| try sys.mkdirP(path[0..slash]);
        var original: std.ArrayList(u8) = .empty;
        defer original.deinit(gpa);
        switch (readText(gpa, path.ptr, &original)) {
            .missing, .whole => {},
            .cut, .failed => return error.Incomplete,
        }
        var file = parse(gpa, original.items);
        defer file.deinit();
        if (file.incomplete) return error.Incomplete;
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        if (std.mem.trim(u8, original.items, " \t\r\n").len == 0) {
            try settings.writeKeeping(&output.writer, &file, kept);
        } else {
            try settings.writeOver(gpa, &output.writer, original.items, &file, kept);
        }
        // `load` reads no more than this: a longer file would come back
        // incomplete and refuse every later save. The file on disk stays.
        if (output.written().len > file_bytes_max) return error.TooLarge;
        // Written where a link points: the rename of the atomic write
        // replaced the link itself, and a settings.conf kept in a dotfiles
        // repository (stow, home-manager) silently became a copy.
        var target_buffer: [std.c.PATH_MAX:0]u8 = undefined;
        const target = linkTarget(path, &target_buffer) orelse path;
        try sys.writeFileAtomic(target, output.written());
    }

    /// What `path` resolves to when it is a symbolic link to an existing
    /// file, in `buffer`; null when it is not a link (or a dangling one,
    /// written over as before).
    fn linkTarget(path: [:0]const u8, buffer: *[std.c.PATH_MAX:0]u8) ?[:0]const u8 {
        var stx: std.os.linux.Statx = undefined;
        const linux = std.os.linux;
        const no_follow = linux.AT.SYMLINK_NOFOLLOW;
        const result = linux.statx(linux.AT.FDCWD, path, no_follow, .{ .TYPE = true }, &stx);
        if (linux.errno(result) != .SUCCESS) return null;
        if (stx.mode & linux.S.IFMT != linux.S.IFLNK) return null;
        const resolved = std.c.realpath(path, buffer) orelse return null;
        return std.mem.span(resolved);
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
            var probe_allocator: std.heap.FixedBufferAllocator = .init(&buffer);
            var probe: Settings = .{ .arena = .init(probe_allocator.allocator()) };
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
    const words_true = [_][]const u8{ "true", "on", "yes", "1" };
    const words_false = [_][]const u8{ "false", "off", "no", "0" };
    for (words_true) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    for (words_false) |word| {
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
    try testing.expectEqualStrings(theme_default, defaults.theme);
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
    try testing.expect(!settings.setChoice(.clipboard_keep, "5001"));
    try testing.expect(settings.setChoice(.clipboard_keep, "5000"));
    try testing.expectEqual(@as(u32, 5000), settings.clipboard_keep);
    try testing.expect(settings.files_in_root);
    try testing.expectEqualStrings("", settings.terminal);
    try testing.expectEqualStrings(theme_default, settings.theme);
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

test "unknown sections are not top-level keys, and survive a save" {
    var settings = Settings.parse(testing.allocator,
        \\editor = hx
        \\[future]
        \\editor = rm
        \\theme = other
        \\[open-with]
        \\markdown = md.desktop
    );
    defer settings.deinit();
    // The section's keys are not ours: they do not override the top level.
    try testing.expectEqualStrings("hx", settings.editor);
    try testing.expectEqualStrings(theme_default, settings.theme);
    try testing.expectEqual(@as(usize, 0), settings.unknown.items.len);
    try testing.expectEqualStrings("md.desktop", settings.appFor("", .markdown).?);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try settings.write(&out.writer);
    var back = Settings.parse(testing.allocator, out.written());
    defer back.deinit();
    try testing.expectEqualStrings("hx", back.editor);
    try testing.expectEqual(@as(usize, 3), back.unknown_sections.items.len);
    try testing.expectEqualStrings("[future]", back.unknown_sections.items[0]);
    try testing.expectEqualStrings("md.desktop", back.appFor("", .markdown).?);
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

test "a compound extension rule wins over the last extension, else the order stays" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try settings.setOpenWith("archive", "ark.desktop");
    try testing.expectEqualStrings("ark.desktop", settings.appForName("backup.tar.gz", .archive).?);
    try settings.setOpenWith(".gz", "gz.desktop");
    try testing.expectEqualStrings("gz.desktop", settings.appForName("backup.tar.gz", .archive).?);
    try settings.setOpenWith(".TAR.GZ", "example.desktop");
    try testing.expectEqualStrings(
        "example.desktop",
        settings.appForName("Backup.Tar.GZ", .archive).?,
    );
    // Only the full suffix matches: "x.gz" has no ".tar".
    try testing.expectEqualStrings("gz.desktop", settings.appForName("x.gz", .archive).?);
    try settings.setOpenWith(".tar.gz", "");
    try testing.expectEqualStrings("gz.desktop", settings.appForName("backup.tar.gz", .archive).?);
    try settings.setOpenWith(".gz", "");
    try testing.expectEqualStrings("ark.desktop", settings.appForName("backup.tar.gz", .archive).?);
    // A hidden name and a trailing dot have no extension.
    try settings.setOpenWith(".bashrc", "zed.desktop");
    try testing.expectEqual(@as(?[]const u8, null), settings.appForName(".bashrc", null));
    try testing.expectEqual(@as(?[]const u8, null), settings.appForName("notes.", null));
    try testing.expectEqualStrings("zed.desktop", settings.appForName("x.bashrc", null).?);
}

test "save is atomic and owner-only; load survives a missing file" {
    var test_dir = testing.tmpDir(.{});
    defer test_dir.cleanup();
    var dir_path_buffer: [4096]u8 = undefined;
    var path_buffer: [4096]u8 = undefined;
    const dir_path = try sys.tmpDirPath(&test_dir, &dir_path_buffer);
    const path = try std.mem.printSentinel(&path_buffer, "{s}/sub/settings.conf", .{dir_path}, 0);

    var missing = Settings.load(testing.allocator, path);
    defer missing.deinit();
    try testing.expectEqualStrings(theme_default, missing.theme);

    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expect(settings.setChoice(.text_size, "small"));
    try settings.save(testing.allocator, path, &.{});
    const before = Stamp.of(path);
    var back = Settings.load(testing.allocator, path);
    defer back.deinit();
    try testing.expectEqual(TextSize.small, back.text_size);
    const linux = std.os.linux;
    var status: linux.Statx = undefined;
    const statx_result = linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &status);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(statx_result));
    try testing.expectEqual(@as(u32, 0o600), status.mode & 0o777);

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

    // An existing unreadable / non-regular path marks `incomplete` so save()
    // never clobbers it with defaults.
    const fifo_path = try std.mem.printSentinel(&path_buffer, "{s}/settings.fifo", .{dir_path}, 0);
    try testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.mknodat(linux.AT.FDCWD, fifo_path, linux.S.IFIFO | 0o600, 0)),
    );
    var unreadable = Settings.load(testing.allocator, fifo_path);
    defer unreadable.deinit();
    try testing.expect(unreadable.incomplete);
    try testing.expectError(error.Incomplete, unreadable.save(testing.allocator, fifo_path, &.{}));
    try testing.expectError(
        error.Incomplete,
        settings.save(testing.allocator, fifo_path, &.{"width"}),
    );
}

test "save refuses an output past what load reads, the file stays" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/settings.conf", .{dir}, 0);

    // Unknown keys just under the read limit: the file loads whole, but the
    // header and generated keys a save adds take it past the limit.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    var line_index: usize = 0;
    while (text.items.len + 32 < Settings.file_bytes_max - 200) : (line_index += 1) {
        try text.print(testing.allocator, "future_key_{d:0>6} = some-value\n", .{line_index});
    }
    try sys.writeFile(path, text.items);
    var settings = Settings.load(testing.allocator, path);
    defer settings.deinit();
    try testing.expect(!settings.incomplete);
    try testing.expect(settings.setChoice(.editor, "hx"));
    try testing.expectError(error.TooLarge, settings.save(testing.allocator, path, &.{}));
    try testing.expectError(error.TooLarge, settings.savePatch(testing.allocator, path, &.{}, .{
        .choice = .{ .key = .editor, .value = "hx" },
    }));

    // The file is the one written, and still loads whole.
    var back = Settings.load(testing.allocator, path);
    defer back.deinit();
    try testing.expect(!back.incomplete);
    var stx: std.os.linux.Statx = undefined;
    _ = std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .SIZE = true }, &stx);
    try testing.expectEqual(@as(u64, text.items.len), stx.size);
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

test "saving through a link writes where it points, the link stays" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp_dir, &dir_buffer);
    var real_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real = try std.mem.printSentinel(&real_buffer, "{s}/repo-settings.conf", .{dir}, 0);
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.mem.printSentinel(&link_buffer, "{s}/settings.conf", .{dir}, 0);
    try sys.writeFile(real, "theme = dracula\n");
    // Relative to the link's folder, as a dotfiles manager makes them.
    try testing.expectEqual(@as(usize, 0), std.os.linux.symlink("repo-settings.conf", link));
    var settings = Settings.load(testing.allocator, link.ptr);
    defer settings.deinit();
    try testing.expect(settings.setChoice(.editor, "hx"));
    try settings.save(testing.allocator, link, &.{});
    var back = Settings.load(testing.allocator, real.ptr);
    defer back.deinit();
    try testing.expectEqualStrings("hx", back.editor);
    try testing.expectEqualStrings("dracula", back.theme);
    var stx: std.os.linux.Statx = undefined;
    _ = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        link,
        std.os.linux.AT.SYMLINK_NOFOLLOW,
        .{ .TYPE = true },
        &stx,
    );
    try testing.expect(stx.mode & std.os.linux.S.IFMT == std.os.linux.S.IFLNK);
}

test "check tells unknown keys from bad values" {
    try testing.expectEqual(Settings.Check.ok, Settings.check("width", "wide"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("density", "compact"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("suggestions", "off"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("opacity", "90"));
    try testing.expectEqual(Settings.Check.ok, Settings.check("theme", "midnight"));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("style", ".."));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("style", "."));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("width", "huge"));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("opacity", "10"));
    try testing.expectEqual(Settings.Check.bad_value, Settings.check("clipboard", "maybe"));
    try testing.expectEqual(Settings.Check.unknown_key, Settings.check("colour", "red"));
}

test "round-trip preserves unrecognized values, # values, and unknown [open-with] keys" {
    var settings = Settings.parse(testing.allocator,
        \\accent = #88c0d0
        \\width = huge
        \\[open-with]
        \\pdf = org.gnome.Evince.desktop
        \\ebook = foliate.desktop
        \\.verylongextension = editor.desktop
    );
    defer settings.deinit();
    // In memory, width falls back to default; accent is preserved without cutting at ' #'.
    try testing.expectEqual(Width.default, settings.width);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try settings.write(&out.writer);
    const written = out.written();
    try testing.expect(std.mem.find(u8, written, "accent = #88c0d0\n") != null);
    try testing.expect(std.mem.find(u8, written, "width = huge\n") != null);
    try testing.expect(std.mem.find(u8, written, "ebook = foliate.desktop\n") != null);
    try testing.expect(std.mem.find(u8, written, ".verylongextension = editor.desktop\n") != null);

    // Modifying width with a valid value replaces the preserved line.
    try testing.expect(settings.setChoice(.width, "wide"));
    out.clearRetainingCapacity();
    try settings.write(&out.writer);
    try testing.expect(std.mem.find(u8, out.written(), "width = wide\n") != null);
    try testing.expect(std.mem.find(u8, out.written(), "width = huge") == null);
    try testing.expect(std.mem.find(u8, out.written(), "accent = #88c0d0\n") != null);
}

test "savePatch preserves external edits to settings.conf made after load" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/settings.conf", .{dir}, 0);

    try sys.writeFile(path, "width = default\nsuggestions = true\n");
    var settings = Settings.load(testing.allocator, path);
    defer settings.deinit();
    try testing.expectEqual(Width.default, settings.width);
    try testing.expect(settings.suggestions);

    // External edit happens while Settings is open.
    try sys.writeFile(path, "width = wide\nsuggestions = true\nfuture_manual = preserve-me\n");

    settings.setToggle(.suggestions, false);
    try settings.savePatch(testing.allocator, path, &.{}, .{
        .toggle = .{ .key = .suggestions, .value = false },
    });

    var reloaded = Settings.load(testing.allocator, path);
    defer reloaded.deinit();
    try testing.expectEqual(Width.wide, reloaded.width);
    try testing.expect(!reloaded.suggestions);
    try testing.expectEqualStrings("future_manual = preserve-me", reloaded.unknown.items[0]);
}

/// `settings` written, read back and written again: the second text.
fn writeTwice(settings: *const Settings, first: *std.Io.Writer.Allocating) !Settings {
    try settings.write(&first.writer);
    return Settings.parse(testing.allocator, first.written());
}

test "a later bad value for a key already set is not what a save writes (MYP-576)" {
    var settings = Settings.parse(testing.allocator,
        \\clipboard = off
        \\clipboard = disabled
        \\theme = nord
        \\theme = not a token
        \\width = huge
        \\width = wide
    );
    defer settings.deinit();
    try testing.expect(!settings.clipboard);
    try testing.expectEqualStrings("nord", settings.theme);
    try testing.expectEqual(Width.wide, settings.width);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var back = try writeTwice(&settings, &out);
    defer back.deinit();
    try testing.expect(std.mem.find(u8, out.written(), "clipboard = false\n") != null);
    try testing.expect(std.mem.find(u8, out.written(), "disabled") == null);
    try testing.expect(!back.clipboard);
    try testing.expectEqualStrings("nord", back.theme);
    try testing.expectEqual(Width.wide, back.width);
}

test "an [open-with] app this version does not take is kept until one is set (MYP-530)" {
    var settings = Settings.parse(testing.allocator,
        \\[open-with]
        \\pdf = org.gnome.Evince
        \\.LOG = some future format
        \\video = mpv.desktop
    );
    defer settings.deinit();
    try testing.expect(settings.appFor("", .pdf) == null);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var back = try writeTwice(&settings, &out);
    defer back.deinit();
    try testing.expect(std.mem.find(u8, out.written(), "pdf = org.gnome.Evince\n") != null);
    try testing.expect(std.mem.find(u8, out.written(), ".LOG = some future format\n") != null);
    try testing.expect(std.mem.find(u8, out.written(), "video = mpv.desktop\n") != null);

    // An app chosen for the kind or extension replaces the kept line.
    try back.setOpenWith("pdf", "org.gnome.Evince.desktop");
    try back.setOpenWith(".log", "");
    out.clearRetainingCapacity();
    try back.write(&out.writer);
    try testing.expect(std.mem.find(u8, out.written(), "pdf = org.gnome.Evince\n") == null);
    try testing.expect(std.mem.find(u8, out.written(), "pdf = org.gnome.Evince.desktop\n") != null);
    try testing.expect(std.mem.find(u8, out.written(), ".LOG") == null);
}

test "the user's comments survive a save, Lumen's own are not doubled (MYP-566)" {
    var settings = Settings.parse(testing.allocator,
        \\# my notes: nord at night
        \\# theme = nord
        \\theme = dracula # an inline note (writeOver keeps it)
        \\; an ini-style comment
        \\[open-with]
        \\# evince is too slow
        \\pdf = zathura.desktop
        \\[future]
        \\# about the future section
        \\key = value
    );
    defer settings.deinit();
    var first: std.Io.Writer.Allocating = .init(testing.allocator);
    defer first.deinit();
    var back = try writeTwice(&settings, &first);
    defer back.deinit();
    for ([_][]const u8{
        "# my notes: nord at night\n",
        "# theme = nord\n",
        "; an ini-style comment\n",
        "# evince is too slow\n",
        "[future]\n# about the future section\nkey = value\n",
    }) |kept| try testing.expect(std.mem.find(u8, first.written(), kept) != null);
    try testing.expectEqualStrings("dracula", back.theme);
    try testing.expectEqualStrings("zathura.desktop", back.appFor("", .pdf).?);
    // Written again, the file is the same: nothing is added twice.
    var second: std.Io.Writer.Allocating = .init(testing.allocator);
    defer second.deinit();
    try back.write(&second.writer);
    try testing.expectEqualStrings(first.written(), second.written());
}

test "every comment write adds is one of Lumen's own" {
    var settings = Settings.parse(testing.allocator, "future_option = 1\n");
    defer settings.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var back = try writeTwice(&settings, &out);
    defer back.deinit();
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '#') try testing.expect(Settings.isOwnComment(line));
    }
    try testing.expectEqual(@as(usize, 0), back.comments.items.len);
    try testing.expectEqual(@as(usize, 0), back.unknown_open_with.items.len);
}

/// `original` written over by its settings after `change`: the new text.
fn savedOver(
    out: *std.Io.Writer.Allocating,
    original: []const u8,
    kept: []const []const u8,
    change: *const fn (*Settings) anyerror!void,
) !void {
    var file = Settings.parse(testing.allocator, original);
    defer file.deinit();
    var settings = Settings.parse(testing.allocator, original);
    defer settings.deinit();
    try change(&settings);
    try settings.writeOver(testing.allocator, &out.writer, original, &file, kept);
}

fn noChange(_: *Settings) !void {}

test "a save keeps the file's layout, comments and lines it cannot read (MYP-566)" {
    const original =
        "# my notes: nord at night\n" ++
        "# theme = nord\n" ++
        "theme = dracula   # nord is too blue\n" ++
        "  clipboard = off\r\n" ++
        "my key = 1\n" ++
        "bad \xff utf-8\n" ++
        "future_option = 42 # from 2.0\n" ++
        "\n" ++
        "[open-with]\n" ++
        "# evince is too slow\n" ++
        "pdf = zathura.desktop # fast\n" ++
        ".LOG = some future format\n" ++
        "\n" ++
        "[future]\n" ++
        "theme = other # not ours\n";
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // Nothing changed: the same file, with only the keys it lacks added at
    // the end of its top part.
    try savedOver(&out, original, &.{}, noChange);
    const unchanged = out.written();
    const top_end = std.mem.find(u8, original, "\n\n[open-with]").? + 1;
    try testing.expectStringStartsWith(unchanged, original[0..top_end]);
    try testing.expectStringEndsWith(unchanged, original[top_end..]);
    try testing.expect(std.mem.find(u8, unchanged, "\nstyle = \n") != null);
    try testing.expect(std.mem.find(u8, unchanged, "\neditor = \n") != null);
    // Added once: saved again, nothing more is added.
    var again: std.Io.Writer.Allocating = .init(testing.allocator);
    defer again.deinit();
    try savedOver(&again, unchanged, &.{}, noChange);
    try testing.expectEqualStrings(unchanged, again.written());

    // Changed values are rewritten in place, inline comment, indentation
    // and line ending kept.
    var changed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer changed.deinit();
    try savedOver(&changed, unchanged, &.{}, struct {
        fn change(settings: *Settings) !void {
            try testing.expect(settings.setTextValue(.theme, "nord"));
            settings.setToggle(.clipboard, true);
            try settings.setOpenWith("pdf", "org.gnome.Evince.desktop");
            try settings.setOpenWith(".log", "zed.desktop");
            try settings.setOpenWith("image", "imv.desktop");
        }
    }.change);
    try testing.expectStringStartsWith(changed.written(), "# my notes: nord at night\n" ++
        "# theme = nord\n" ++
        "theme = nord   # nord is too blue\n" ++
        "  clipboard = true\r\n" ++
        "my key = 1\n" ++
        "bad \xff utf-8\n" ++
        "future_option = 42 # from 2.0\n");
    try testing.expect(std.mem.find(u8, changed.written(), "\n[open-with]\n" ++
        "# evince is too slow\n" ++
        "pdf = org.gnome.Evince.desktop # fast\n" ++
        ".LOG = zed.desktop\n" ++
        "image = imv.desktop\n" ++
        "\n[future]\ntheme = other # not ours\n") != null);
    var back = Settings.parse(testing.allocator, changed.written());
    defer back.deinit();
    try testing.expectEqualStrings("nord", back.theme);
    try testing.expect(back.clipboard);
    try testing.expectEqualStrings("zed.desktop", back.appFor(".log", null).?);
    try testing.expectEqualStrings("imv.desktop", back.appFor("", .image).?);
}

test "a changed key's other lines go, an unchanged one's stay (MYP-566, MYP-576)" {
    const original =
        \\clipboard = off
        \\clipboard = disabled
        \\width = huge
        \\width = wide
        \\[open-with]
        \\pdf = a.desktop
        \\pdf = b.desktop
        \\video = mpv.desktop
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try savedOver(&out, original, &.{}, struct {
        fn change(settings: *Settings) !void {
            settings.setToggle(.clipboard, true);
            try settings.setOpenWith("pdf", "c.desktop");
            try settings.setOpenWith("video", "");
        }
    }.change);
    const written = out.written();
    try testing.expectStringStartsWith(written, "clipboard = true\nwidth = huge\nwidth = wide\n");
    try testing.expect(std.mem.find(u8, written, "disabled") == null);
    try testing.expectStringEndsWith(written, "\n[open-with]\npdf = c.desktop\n");
    var back = Settings.parse(testing.allocator, written);
    defer back.deinit();
    try testing.expect(back.clipboard);
    try testing.expectEqual(Width.wide, back.width);
    try testing.expectEqualStrings("c.desktop", back.appFor("", .pdf).?);
    try testing.expect(back.appFor("", .video) == null);
}

test "keys init.lua sets keep the file's lines; a file without [open-with] gets one" {
    const original = "width = narrow # mine\n";
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try savedOver(&out, original, &.{"width"}, struct {
        fn change(settings: *Settings) !void {
            try testing.expect(settings.setChoice(.width, "wide"));
            try settings.setOpenWith(".md", "obsidian.desktop");
        }
    }.change);
    const written = out.written();
    try testing.expectStringStartsWith(written, original ++ "\n");
    try testing.expectStringEndsWith(
        written,
        "\n" ++ Settings.open_with_heading ++ ".md = obsidian.desktop\n",
    );
    var back = Settings.parse(testing.allocator, written);
    defer back.deinit();
    try testing.expectEqual(Width.narrow, back.width);
    try testing.expectEqualStrings("obsidian.desktop", back.appFor(".md", null).?);
}

test "save keeps an existing file's comments, a new one is written whole (MYP-566)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp_dir, &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/settings.conf", .{dir}, 0);

    var settings = Settings.load(testing.allocator, path);
    defer settings.deinit();
    try settings.save(testing.allocator, path, &.{});
    var whole: std.Io.Writer.Allocating = .init(testing.allocator);
    defer whole.deinit();
    try settings.write(&whole.writer);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try testing.expectEqual(Settings.Read.whole, Settings.readText(testing.allocator, path, &text));
    try testing.expectEqualStrings(whole.written(), text.items);

    // A comment and an inline one added by hand survive a change from
    // Settings, and the rest of the file stays the same.
    const edited = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        text.items,
        "theme = lumen-dark\n",
        "# nord at night\ntheme = lumen-dark # for now\n",
    );
    defer testing.allocator.free(edited);
    try sys.writeFile(path, edited);
    try settings.savePatch(testing.allocator, path, &.{}, .{
        .text = .{ .key = .theme, .value = "nord" },
    });
    text.clearRetainingCapacity();
    try testing.expectEqual(Settings.Read.whole, Settings.readText(testing.allocator, path, &text));
    const expected = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        edited,
        "theme = lumen-dark # for now\n",
        "theme = nord # for now\n",
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, text.items);
    try testing.expectEqualStrings("nord", settings.theme);
}
