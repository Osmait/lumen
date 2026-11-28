//! Lumen's configuration applied to the window: settings.conf with
//! init.lua's `lumen.set` over it, and what it decides about how Lumen
//! looks: the theme and style CSS (plus the user's style.css), the icon
//! theme, the icons in ~/.config/lumen/icons and init.lua's `lumen.icons`,
//! and the desktop's light or dark preference for the "Automatic" theme.
//!
//! The files are read when the window opens (Ui.showWith checks their
//! stamps) and when Settings writes them; CSS is loaded into GTK only when
//! its text changed. Main thread only (GTK).

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const item_mod = @import("../item.zig");
const os = @import("os");
const styles = @import("styles");
const settings_mod = @import("../settings.zig");
const Settings = settings_mod.Settings;
const ext_view = @import("ext_view.zig");
const themes = @import("themes.zig");
const widgets = @import("widgets.zig");
const window_layout = @import("window_layout.zig");
const Ui = @import("Ui.zig");

const log = std.log.scoped(.ui);

/// Lumen's CSS and what it was built from.
pub const Appearance = struct {
    css: *c.GtkCssProvider = undefined,
    css_hash: u64 = 0,
    /// The user's style.css as last read (it is applied after Lumen's).
    user_css_stamp: settings_mod.Stamp = .none,
    /// The style folder's style.css, likewise (built-in styles have none).
    style_css_stamp: settings_mod.Stamp = .none,
    /// Search highlight colours of the theme, for Pango markup.
    highlight_foreground: [8]u8 = "#ffffff\x00".*,
    highlight_background: [8]u8 = "#ff6363\x00".*,
    /// org.gnome.desktop.interface, for the "Automatic" theme.
    interface_settings: ?*c.GSettings = null,
};

/// The settings lumen.layout can fix with its own pixels and place.
const LayoutSetting = enum { width, height, position };

/// The values `color_scheme_key` takes. "default" is the desktop's own
/// default, which is light.
const ColorScheme = enum { default, @"prefer-dark", @"prefer-light" };

/// GtkSettings' property the Icon Theme setting sets for Lumen's process.
const gtk_icon_theme_property = "gtk-icon-theme-name";

/// An icon theme's folder name; a longer one is left to GTK's default.
const icon_theme_name_bytes_max = 128;

/// Keys init.lua can fix at once: more than Settings has.
const kept_keys_max = 32;

comptime {
    assert(@typeInfo(Settings).@"struct".field_names.len <= kept_keys_max);
}

/// Where the desktop keeps its light or dark preference.
const interface_schema = "org.gnome.desktop.interface";
const color_scheme_key = "color-scheme";

pub fn loadCss(ui: *Ui) void {
    renderFontsUnhinted();
    ui.appearance.css = c.gtk_css_provider_new();
    const display = c.gdk_display_get_default() orelse return;
    c.gtk_style_context_add_provider_for_display(
        display,
        @ptrCast(ui.appearance.css),
        c.GTK_STYLE_PROVIDER_PRIORITY_USER,
    );
}

/// Reads the settings file again and applies it, init.lua's settings over it.
pub fn reloadSettings(ui: *Ui) void {
    os.assertMainThread();
    const fresh = Settings.load(ui.gpa, ui.settings_path.ptr);
    ui.settings.deinit();
    ui.settings = fresh;
    ui.settings_stamp = settings_mod.Stamp.of(ui.settings_path.ptr);
    applyOverrides(ui);
    applyAppearance(ui, null);
    window_layout.applyLayout(ui);
    applyIconTheme(ui);
    // The style may have changed in the file, or from init.lua.
    ext_view.syncStyle(ui);
    if (ui.on_settings_changed) |callback| callback();
}

/// Writes the settings; what init.lua fixes keeps its value in the file.
pub fn saveSettings(ui: *Ui) void {
    saveSettingsPatch(ui, .all);
}

/// Applies a single targeted change onto the latest `settings.conf` on disk so
/// external edits made while Settings is open are preserved.
pub fn saveSettingsPatch(ui: *Ui, patch: Settings.Patch) void {
    var kept: [kept_keys_max][]const u8 = undefined;
    var kept_count: usize = 0;
    if (ui.ext_registry) |registry| {
        for (registry.settings) |override| {
            var seen = false;
            for (kept[0..kept_count]) |existing| {
                if (std.mem.eql(u8, existing, override.key)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            assert(kept_count < kept.len);
            kept[kept_count] = override.key;
            kept_count += 1;
        }
    }
    ui.settings.savePatch(
        ui.gpa,
        ui.settings_path,
        kept[0..kept_count],
        patch,
    ) catch |err| {
        log.warn("saving settings: {t}", .{err});
        ui.showFailure("Could not save the settings");
    };
    applyOverrides(ui);
    ui.settings_stamp = settings_mod.Stamp.of(ui.settings_path.ptr);
    applyAppearance(ui, null);
    window_layout.applyLayout(ui);
    applyIconTheme(ui);
    if (ui.on_settings_changed) |callback| callback();
}

/// `lumen.set` in init.lua, over the file's values.
pub fn applyOverrides(ui: *Ui) void {
    const registry = ui.ext_registry orelse return;
    for (registry.settings) |override| _ = ui.settings.set(override.key, override.value);
}

/// Set by init.lua: Settings shows it but cannot change it.
pub fn overridden(ui: *const Ui, key: []const u8) bool {
    // lumen.layout's pixels and place win over these.
    if (std.meta.stringToEnum(LayoutSetting, key)) |layout_setting| {
        const fixed = switch (layout_setting) {
            .width => ui.layout.width != null,
            .height => ui.layout.height != null,
            .position => ui.layout.position != null,
        };
        if (fixed) return true;
    }
    const registry = ui.ext_registry orelse return false;
    for (registry.settings) |override| if (std.mem.eql(u8, override.key, key)) return true;
    return false;
}

/// GtkFontRendering's MANUAL: the gtk-xft-* settings are used as set.
const font_rendering_manual: c_int = 1;

/// Glyphs drawn without hinting, for Lumen's process only. GTK's automatic
/// rendering hints them slightly at scale 1, and at the calculator's 26 px
/// that lifts the top row of the digits half a pixel past the bounds GTK
/// keeps for the text: the row was drawn hard and flat (the digits looked
/// cut at the top), and when the text changed it was not repainted (marks
/// over the digits of an earlier keystroke). Unhinted, the outlines stay
/// within their bounds; the rows' small text looks the same.
fn renderFontsUnhinted() void {
    const gtk_settings = c.gtk_settings_get_default() orelse return;
    c.g_object_set(
        gtk_settings,
        "gtk-font-rendering",
        font_rendering_manual,
        "gtk-xft-hintstyle",
        "hintnone",
        @as(?*anyopaque, null),
    );
}

/// The Icon Theme setting, for Lumen's process only.
fn applyIconTheme(ui: *Ui) void {
    const gtk_settings = c.gtk_settings_get_default() orelse return;
    if (ui.settings.icon_theme.len == 0) {
        return c.gtk_settings_reset_property(gtk_settings, gtk_icon_theme_property);
    }
    var name_bytes: [icon_theme_name_bytes_max]u8 = undefined;
    const theme_name = ui.settings.icon_theme;
    const name = std.mem.printSentinel(&name_bytes, "{s}", .{theme_name}, 0) catch return;
    c.g_object_set(gtk_settings, gtk_icon_theme_property, name.ptr, @as(?*anyopaque, null));
}

fn currentTheme(ui: *Ui) *const themes.Theme {
    return themes.find(ui.settings.theme, preferDark(ui), customThemes(ui));
}

/// Theme variables + style.css + the user's style.css, reloaded only when
/// they changed. `preview` paints a theme without choosing it (moving
/// through Change Theme).
pub fn applyAppearance(ui: *Ui, preview: ?*const themes.Theme) void {
    os.assertMainThread();
    const theme = preview orelse currentTheme(ui);
    var out: std.Io.Writer.Allocating = .init(ui.gpa);
    defer out.deinit();
    themes.css(&out.writer, theme, &ui.settings) catch return;
    out.writer.writeAll(@embedFile("style.css")) catch return;
    appendStyleCss(ui, &out.writer) catch return;
    appendUserCss(ui, &out.writer) catch return;
    out.writer.writeByte(0) catch return;
    const text = out.written();
    _ = themes.hex(&ui.appearance.highlight_foreground, theme.foreground);
    _ = themes.hex(&ui.appearance.highlight_background, theme.accent);
    const hash = std.hash.Wyhash.hash(0, text);
    if (hash == ui.appearance.css_hash) return;
    ui.appearance.css_hash = hash;
    c.gtk_css_provider_load_from_string(ui.appearance.css, @ptrCast(text.ptr));
}

/// The style's CSS, between Lumen's and the user's: styles/<name>/style.css,
/// else the built-in style's.
fn appendStyleCss(ui: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    ui.appearance.style_css_stamp = .none;
    const name = ui.settings.style;
    if (name.len == 0) return;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.findScalar(u8, name, '/') != null) return;
    var folder_bytes: [4096]u8 = undefined;
    const folder = std.mem.printSentinel(
        &folder_bytes,
        "{s}/styles/{s}",
        .{ ui.config_dir, name },
        0,
    ) catch return;
    if (os.info(folder) == null) {
        const style = styles.find(name) orelse return;
        try writer.print("\n/* style {s} */\n", .{name});
        return writer.writeAll(style.css);
    }
    var path_bytes: [4096]u8 = undefined;
    const path = std.mem.printSentinel(&path_bytes, "{s}/style.css", .{folder}, 0) catch return;
    ui.appearance.style_css_stamp = settings_mod.Stamp.of(path.ptr);
    const contents = style_css_file.read(ui.gpa, path, ui.appearance.style_css_stamp) orelse return;
    try writer.print("\n/* {s} */\n", .{path});
    try writer.writeAll(contents);
    try writer.writeByte('\n');
}

/// The most CSS read from one file: a style sheet is a few KB, and the
/// whole text is parsed again on every change.
const css_bytes_max = 1 << 20;

/// What a CSS file held, kept while its stamp stays the same: moving
/// through Change Theme builds the CSS again on every arrow key, and read
/// both files from disk each time. Main thread.
const CssFile = struct {
    path_hash: u64 = 0,
    stamp: settings_mod.Stamp = .none,
    text: std.ArrayList(u8) = .empty,

    /// The text of `path`, whose stamp is `stamp`: from memory when it is
    /// the one read last, else from a descriptor checked to be a regular
    /// file (a FIFO would block the window), `css_bytes_max` at most. Null
    /// when it cannot be read or is larger.
    fn read(
        file: *CssFile,
        gpa: std.mem.Allocator,
        path: [:0]const u8,
        stamp: settings_mod.Stamp,
    ) ?[]const u8 {
        os.assertMainThread();
        const path_hash = std.hash.Wyhash.hash(0, path);
        const known = file.path_hash == path_hash and file.stamp.eql(stamp);
        if (known and !stamp.eql(.none)) return file.text.items;
        file.text.clearRetainingCapacity();
        file.path_hash = 0;
        file.stamp = .none;
        const fd = os.openRegular(path) catch return null;
        defer os.close(fd);
        // One byte past the limit tells a file over it.
        os.readUpTo(gpa, fd, &file.text, css_bytes_max + 1) catch return null;
        if (file.text.items.len > css_bytes_max) {
            log.warn("{s}: over {d} bytes, not used", .{ path, css_bytes_max });
            file.text.clearAndFree(gpa);
            return null;
        }
        file.path_hash = path_hash;
        file.stamp = stamp;
        return file.text.items;
    }
};
var style_css_file: CssFile = .{};
var user_css_file: CssFile = .{};

pub fn shutdown(gpa: std.mem.Allocator) void {
    os.assertMainThread();
    style_css_file.text.deinit(gpa);
    style_css_file = .{};
    user_css_file.text.deinit(gpa);
    user_css_file = .{};
}

/// $XDG_CONFIG_HOME/lumen/style.css, after Lumen's rules so it wins. The
/// classes it can use are listed in EXTENSIONS.md.
fn appendUserCss(ui: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var path_bytes: [4096]u8 = undefined;
    const path = std.mem.printSentinel(
        &path_bytes,
        "{s}/style.css",
        .{ui.config_dir},
        0,
    ) catch return;
    ui.appearance.user_css_stamp = settings_mod.Stamp.of(path.ptr);
    const contents = user_css_file.read(ui.gpa, path, ui.appearance.user_css_stamp) orelse return;
    try writer.writeAll("\n/* ~/.config/lumen/style.css */\n");
    try writer.writeAll(contents);
    try writer.writeByte('\n');
}

/// Whether the user's or the style's style.css changed since it was read.
pub fn userCssChanged(ui: *Ui) bool {
    var path_bytes: [4096]u8 = undefined;
    const path = std.mem.printSentinel(
        &path_bytes,
        "{s}/style.css",
        .{ui.config_dir},
        0,
    ) catch return false;
    if (!settings_mod.Stamp.of(path.ptr).eql(ui.appearance.user_css_stamp)) return true;
    if (ui.settings.style.len == 0) return false;
    const style = std.mem.printSentinel(
        &path_bytes,
        "{s}/styles/{s}/style.css",
        .{ ui.config_dir, ui.settings.style },
        0,
    ) catch return false;
    return !settings_mod.Stamp.of(style.ptr).eql(ui.appearance.style_css_stamp);
}

/// init.lua's and the style's themes (`lumen.theme`), from the registry.
pub fn customThemes(ui: *const Ui) []const themes.Theme {
    const registry = ui.ext_registry orelse return &.{};
    return registry.themes;
}

/// The desktop's light/dark preference (dark when it cannot be read, or
/// says something new).
pub fn preferDark(ui: *Ui) bool {
    const interface_settings = ui.appearance.interface_settings orelse return true;
    const value = c.g_settings_get_string(interface_settings, color_scheme_key);
    defer c.g_free(value);
    const color_scheme = std.meta.stringToEnum(ColorScheme, std.mem.span(value)) orelse {
        return true;
    };
    return switch (color_scheme) {
        .@"prefer-dark" => true,
        .default, .@"prefer-light" => false,
    };
}

pub fn watchColorScheme(ui: *Ui) void {
    os.assertMainThread();
    const source = c.g_settings_schema_source_get_default() orelse return;
    // Looking the schema up first: g_settings_new aborts on a missing one.
    const recursive = 1;
    const schema = c.g_settings_schema_source_lookup(source, interface_schema, recursive) orelse {
        return;
    };
    defer c.g_settings_schema_unref(schema);
    if (c.g_settings_schema_has_key(schema, color_scheme_key) == 0) return;
    const interface_settings = c.g_settings_new(interface_schema);
    ui.appearance.interface_settings = interface_settings;
    const signal = "changed::" ++ color_scheme_key;
    widgets.connect(interface_settings, signal, &onColorScheme, ui);
}

fn onColorScheme(_: *c.GSettings, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data));
    if (!std.mem.eql(u8, ui.settings.theme, themes.auto_id)) return;
    applyAppearance(ui, null);
    if (ui.view == .settings or ui.view == .themes) ui.rebuild();
}

const icons_dir_entries_max = 1024;

/// ~/.config/lumen/icons/<name>.svg|png replaces the icon <name> everywhere
/// (row_look.renamed). Read when the window opens only when the folder's stamp
/// changed (capped at `icons_dir_entries_max` entries).
pub fn scanIconDir(ui: *Ui) void {
    os.assertMainThread();
    var icons_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const icons_path = std.mem.printSentinel(
        &icons_path_buf,
        "{s}/icons",
        .{ui.config_dir},
        0,
    ) catch return;
    const dir_stamp = os.Stamp.of(icons_path.ptr);
    if (ui.icon_dir_scanned and dir_stamp.eql(ui.icon_dir_stamp)) return;
    ui.icon_dir_stamp = dir_stamp;
    ui.icon_dir_scanned = true;
    ui.row_look.renamed = .empty;
    if (ui.icon_arena) |*icon_arena| {
        _ = icon_arena.reset(.retain_capacity);
    } else {
        ui.icon_arena = .init(ui.gpa);
    }
    const arena = ui.icon_arena.?.allocator();
    const icons_folder = c.g_dir_open(icons_path.ptr, 0, null) orelse return;
    defer c.g_dir_close(icons_folder);
    var entries_seen: usize = 0;
    while (c.g_dir_read_name(icons_folder)) |name_z| {
        if (entries_seen >= icons_dir_entries_max) break;
        entries_seen += 1;
        const name = std.mem.span(name_z);
        const dot = std.mem.findScalarLast(u8, name, '.') orelse continue;
        const extension = name[dot + 1 ..];
        const svg = std.ascii.eqlIgnoreCase(extension, "svg");
        const png = std.ascii.eqlIgnoreCase(extension, "png");
        if (!svg and !png) continue;
        const path = arena.printSentinel("{s}/{s}", .{ icons_path, name }, 0) catch continue;
        ui.row_look.renamed.put(
            arena,
            arena.dupe(u8, name[0..dot]) catch continue,
            path,
        ) catch continue;
    }
}

/// The icon init.lua gave the item with `key` (lumen.icons), if any.
pub fn keyIcon(ui: *const Ui, key: []const u8) ?item_mod.Icon {
    const registry = ui.ext_registry orelse return null;
    if (key.len == 0) return null;
    for (registry.icons) |override| if (std.mem.eql(u8, override.key, key)) return override.icon;
    return null;
}
