//! Built-in themes. `style.css` paints with CSS variables; a theme is the
//! handful of colours those variables come from, plus the text size and
//! opacity settings. Switching theme reloads one small block of CSS.
//!
//! Palettes follow each theme's published colours (Catppuccin, Dracula,
//! Nord...). `ink` is the colour overlays and secondary text are made of:
//! light on dark themes, dark on light ones; strong enough that text at 42%
//! of it stays legible (tested below).

const std = @import("std");
const settings = @import("../settings.zig");

pub const Theme = struct {
    id: []const u8,
    name: [:0]const u8,
    dark: bool,
    /// Window background.
    bg: u24,
    /// Raised surfaces: the action panel.
    surface: u24,
    fg: u24,
    ink: u24,
    /// Caret, selection, search highlights, warnings.
    accent: u24,
    /// Registered by the style (Change Theme lists them under its name).
    from_style: bool = false,
};

/// Follows the desktop's light/dark preference with Lumen Dark / Light.
pub const auto_id = "auto";

pub const all = [_]Theme{
    .{
        .id = "lumen-dark",
        .name = "Lumen Dark",
        .dark = true,
        .bg = 0x1b1b1e,
        .surface = 0x28282c,
        .fg = 0xececee,
        .ink = 0xffffff,
        .accent = 0xff6363,
    },
    .{
        .id = "lumen-light",
        .name = "Lumen Light",
        .dark = false,
        .bg = 0xf5f7fb,
        .surface = 0xffffff,
        .fg = 0x10131a,
        .ink = 0x000000,
        .accent = 0x3a5bd9,
    },
    .{
        .id = "catppuccin-mocha",
        .name = "Catppuccin Mocha",
        .dark = true,
        .bg = 0x1e1e2e,
        .surface = 0x313244,
        .fg = 0xcdd6f4,
        .ink = 0xcdd6f4,
        .accent = 0xcba6f7,
    },
    .{
        .id = "catppuccin-latte",
        .name = "Catppuccin Latte",
        .dark = false,
        .bg = 0xeff1f5,
        .surface = 0xe6e9ef,
        .fg = 0x4c4f69,
        .ink = 0x11111b,
        .accent = 0x8839ef,
    },
    .{
        .id = "dracula",
        .name = "Dracula",
        .dark = true,
        .bg = 0x282a36,
        .surface = 0x343746,
        .fg = 0xf8f8f2,
        .ink = 0xf8f8f2,
        .accent = 0xbd93f9,
    },
    .{
        .id = "nord",
        .name = "Nord",
        .dark = true,
        .bg = 0x2e3440,
        .surface = 0x3b4252,
        .fg = 0xeceff4,
        .ink = 0xd8dee9,
        .accent = 0x88c0d0,
    },
    .{
        .id = "gruvbox-dark",
        .name = "Gruvbox Dark",
        .dark = true,
        .bg = 0x282828,
        .surface = 0x3c3836,
        .fg = 0xebdbb2,
        .ink = 0xebdbb2,
        .accent = 0xfe8019,
    },
    .{
        .id = "gruvbox-light",
        .name = "Gruvbox Light",
        .dark = false,
        .bg = 0xfbf1c7,
        .surface = 0xf2e5bc,
        .fg = 0x3c3836,
        .ink = 0x1d2021,
        .accent = 0xaf3a03,
    },
    .{
        .id = "tokyo-night",
        .name = "Tokyo Night",
        .dark = true,
        .bg = 0x1a1b26,
        .surface = 0x24283b,
        .fg = 0xc0caf5,
        .ink = 0xc0caf5,
        .accent = 0x7aa2f7,
    },
    .{
        .id = "rose-pine",
        .name = "Rosé Pine",
        .dark = true,
        .bg = 0x191724,
        .surface = 0x1f1d2e,
        .fg = 0xe0def4,
        .ink = 0xe0def4,
        .accent = 0xebbcba,
    },
    .{
        .id = "one-dark",
        .name = "One Dark",
        .dark = true,
        .bg = 0x282c34,
        .surface = 0x2f343f,
        .fg = 0xabb2bf,
        .ink = 0xdcdfe4,
        .accent = 0x61afef,
    },
    .{
        .id = "solarized-dark",
        .name = "Solarized Dark",
        .dark = true,
        .bg = 0x002b36,
        .surface = 0x073642,
        .fg = 0x93a1a1,
        .ink = 0xfdf6e3,
        .accent = 0x268bd2,
    },
    .{
        .id = "solarized-light",
        .name = "Solarized Light",
        .dark = false,
        .bg = 0xfdf6e3,
        .surface = 0xeee8d5,
        .fg = 0x586e75,
        .ink = 0x002b36,
        .accent = 0x268bd2,
    },
};

/// The theme with `id`, among the built-in ones and `custom` (init.lua's
/// and the style's `lumen.theme`); unknown ids (a typo in the file, a
/// theme removed) get the default. `auto` resolves with `prefer_dark`.
pub fn find(id: []const u8, prefer_dark: bool, custom: []const Theme) *const Theme {
    if (std.mem.eql(u8, id, auto_id)) return if (prefer_dark) &all[0] else &all[1];
    for (&all) |*t| if (std.mem.eql(u8, t.id, id)) return t;
    for (custom) |*t| if (std.mem.eql(u8, t.id, id)) return t;
    return &all[0];
}

/// The name shown for a theme setting value ("Auto (Lumen Dark)").
pub fn displayName(
    arena: std.mem.Allocator,
    id: []const u8,
    prefer_dark: bool,
    custom: []const Theme,
) [:0]const u8 {
    if (std.mem.eql(u8, id, auto_id)) {
        return arena.printSentinel(
            "Automatic ({s})",
            .{find(id, prefer_dark, custom).name},
            0,
        ) catch "Automatic";
    }
    return find(id, prefer_dark, custom).name;
}

/// The variables block `style.css` is painted with.
pub fn css(
    writer: *std.Io.Writer,
    theme: *const Theme,
    settings_now: *const settings.Settings,
) std.Io.Writer.Error!void {
    const scale = textScale(settings_now.text_size);
    const opacity = @as(f32, @floatFromInt(settings_now.opacity)) / 100;
    try writer.writeAll(":root {\n");
    try rgba(writer, "bg", theme.bg, opacity);
    try rgba(writer, "surface", theme.surface, @min(1, opacity + surface_opacity_extra));
    try rgba(writer, "fg", theme.fg, 1);
    try rgba(writer, "ink", theme.ink, 1);
    try rgba(writer, "accent", theme.accent, 1);
    try rgba(writer, "accent-soft", theme.accent, accent_soft_opacity);
    try rgba(writer, "on-accent", onAccent(theme), 1);
    const shadow_opacity = if (theme.dark) shadow_opacity_dark else shadow_opacity_light;
    try rgba(writer, "shadow", 0, shadow_opacity);
    for (font_sizes) |font| {
        try writer.print("  --{s}: {d:.1}px;\n", .{ font.variable, font.size_px * scale });
    }
    const density = densitySizes(settings_now.density);
    try writer.print(
        "  --row-h: {d}px;\n  --icon: {d}px;\n",
        .{ density.row_height_px, density.icon_px },
    );
    try writer.writeAll("}\n");
}

/// The surface (the detail pane, chips) is a shade more opaque than the
/// background it sits on, so it reads as a layer of its own when the window
/// is translucent.
const surface_opacity_extra: f32 = 0.01;
/// The selection's soft tint and the shadows, as opacities.
const accent_soft_opacity: f32 = 0.35;
const shadow_opacity_dark: f32 = 0.45;
const shadow_opacity_light: f32 = 0.18;

/// The font sizes style.css uses, at the default text size.
const font_sizes = [_]struct { variable: []const u8, size_px: f32 }{
    .{ .variable = "font", .size_px = 14 },
    .{ .variable = "font-query", .size_px = 18 },
    .{ .variable = "font-small", .size_px = 13 },
    .{ .variable = "font-tiny", .size_px = 12 },
    .{ .variable = "font-mono", .size_px = 12.5 },
    .{ .variable = "font-calc", .size_px = 26 },
    .{ .variable = "font-emoji", .size_px = 17 },
};

/// How much the Text Size setting scales every font size.
fn textScale(text_size: @FieldType(settings.Settings, "text_size")) f32 {
    return switch (text_size) {
        .small => 0.9,
        .default => 1,
        .large => 1.15,
    };
}

pub const Density = @FieldType(settings.Settings, "density");

/// A result row's height and its icon's size for the Density setting. The
/// stylesheet gets them as `--row-h` and `--icon`, and the row builders ask
/// GTK for icons of `icon_px`.
pub const DensitySizes = struct { row_height_px: u8, icon_px: u8 };

pub fn densitySizes(density: Density) DensitySizes {
    return switch (density) {
        .compact => .{ .row_height_px = 40, .icon_px = 26 },
        .default => .{ .row_height_px = 48, .icon_px = 32 },
        .comfortable => .{ .row_height_px = 58, .icon_px = 38 },
    };
}

fn rgba(writer: *std.Io.Writer, name: []const u8, color: u24, alpha: f32) !void {
    try writer.print("  --{s}: rgba({d}, {d}, {d}, {d:.2});\n", .{
        name,
        color >> 16,
        (color >> 8) & 0xff,
        color & 0xff,
        alpha,
    });
}

/// Text on an accent fill (the selected row): near-black or white,
/// whichever reads better.
pub fn onAccent(theme: *const Theme) u24 {
    const near_black: u24 = 0x10131a;
    const white: u24 = 0xffffff;
    const black_contrast = contrast(theme.accent, near_black);
    return if (black_contrast >= contrast(theme.accent, white)) near_black else white;
}

/// "#rrggbb" for Pango markup.
pub fn hex(buf: *[8]u8, color: u24) [:0]const u8 {
    return std.mem.printSentinel(buf, "#{x:0>6}", .{color}, 0) catch "#ffffff";
}

/// WCAG contrast ratio between two colours (1 to 21).
pub fn contrast(x: u24, y: u24) f64 {
    const luminance_x = luminance(x);
    const luminance_y = luminance(y);
    const lighter = @max(luminance_x, luminance_y) + wcag_flare;
    const darker = @min(luminance_x, luminance_y) + wcag_flare;
    return lighter / darker;
}

/// WCAG 2's allowance for ambient light on the screen, added to both
/// luminances so black on black is a ratio of 1, not a division by zero.
const wcag_flare = 0.05;

/// WCAG 2's relative luminance: each sRGB channel made linear, then
/// weighted (red, green, blue) by how bright the eye sees it.
fn luminance(color: u24) f64 {
    const weights = [_]f64{ 0.2126, 0.7152, 0.0722 };
    var sum: f64 = 0;
    for (weights, 0..) |weight, channel_index| {
        const shift: u5 = @intCast(16 - 8 * channel_index);
        const channel = @as(f64, @floatFromInt((color >> shift) & 0xff)) / 255;
        sum += weight * srgbToLinear(channel);
    }
    return sum;
}

/// The sRGB transfer function undone, with WCAG 2's constants.
fn srgbToLinear(channel: f64) f64 {
    const linear_segment_end = 0.03928;
    if (channel <= linear_segment_end) return channel / 12.92;
    return std.math.pow(f64, (channel + 0.055) / 1.055, 2.4);
}

test "every theme is readable" {
    for (all) |t| {
        // Body text: WCAG AA for normal text.
        try std.testing.expect(contrast(t.fg, t.bg) >= 4.5);
        // The selected row is an accent fill with text on it.
        try std.testing.expect(contrast(onAccent(&t), t.accent) >= 4.5);
        // The caret and highlights must stand out from the background.
        try std.testing.expect(contrast(t.accent, t.bg) >= 2.5);
        // Secondary text is ink at 42%: it must still be legible.
        try std.testing.expect(contrast(mix(t.ink, t.bg, 0.42), t.bg) >= 2.4);
        try std.testing.expect(t.dark == (luminance(t.bg) < 0.2));
    }
}

fn mix(top: u24, under: u24, alpha: f64) u24 {
    var out: u24 = 0;
    for (0..3) |i| {
        const shift: u5 = @intCast(16 - 8 * i);
        const x: f64 = @floatFromInt((top >> shift) & 0xff);
        const y: f64 = @floatFromInt((under >> shift) & 0xff);
        out |= @as(u24, @intFromFloat(@round(x * alpha + y * (1 - alpha)))) << shift;
    }
    return out;
}

test "ids are unique and lookups fall back" {
    for (all, 0..) |x, i| for (all[i + 1 ..]) |y| try std.testing.expect(
        !std.mem.eql(u8, x.id, y.id),
    );
    try std.testing.expectEqualStrings("nord", find("nord", true, &.{}).id);
    try std.testing.expectEqualStrings("lumen-dark", find("no-such-theme", false, &.{}).id);
    try std.testing.expectEqualStrings("lumen-dark", find(auto_id, true, &.{}).id);
    try std.testing.expectEqualStrings("lumen-light", find(auto_id, false, &.{}).id);
}

test "style.css only uses variables the themes define" {
    var s = settings.Settings.init(std.testing.allocator);
    defer s.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try css(&out.writer, &all[0], &s);
    const vars = out.written();
    const style = @embedFile("style.css");
    var pos: usize = 0;
    var used: usize = 0;
    while (std.mem.findPos(u8, style, pos, "var(--")) |at| {
        const start = at + 4;
        const end = std.mem.findScalarPos(u8, style, start, ')') orelse break;
        var buf: [64]u8 = undefined;
        const decl = try std.mem.print(&buf, "{s}:", .{style[start..end]});
        if (std.mem.find(u8, vars, decl) == null) {
            std.debug.print("style.css uses undefined {s}\n", .{style[start..end]});
            return error.UndefinedVariable;
        }
        used += 1;
        pos = end;
    }
    try std.testing.expect(used > 20);
    // No hard-coded text colours left behind: they would ignore the theme.
    try std.testing.expect(std.mem.find(u8, style, "rgba(255, 255, 255") == null);
}

test "text size and opacity reach the CSS" {
    var s = settings.Settings.init(std.testing.allocator);
    defer s.deinit();
    s.text_size = .large;
    s.opacity = 80;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try css(&out.writer, find("nord", true, &.{}), &s);
    try std.testing.expect(
        std.mem.find(u8, out.written(), "--bg: rgba(46, 52, 64, 0.80);") != null,
    );
    try std.testing.expect(std.mem.find(u8, out.written(), "--font: 16.1px;") != null);
}
