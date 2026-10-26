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
};

/// Follows the desktop's light/dark preference with Lumen Dark / Light.
pub const auto_id = "auto";

pub const all = [_]Theme{
    .{ .id = "lumen-dark", .name = "Lumen Dark", .dark = true, .bg = 0x121826, .surface = 0x1c2333, .fg = 0xeef1f7, .ink = 0xffffff, .accent = 0x8fe3ff },
    .{ .id = "lumen-light", .name = "Lumen Light", .dark = false, .bg = 0xf5f7fb, .surface = 0xffffff, .fg = 0x10131a, .ink = 0x000000, .accent = 0x3a5bd9 },
    .{ .id = "catppuccin-mocha", .name = "Catppuccin Mocha", .dark = true, .bg = 0x1e1e2e, .surface = 0x313244, .fg = 0xcdd6f4, .ink = 0xcdd6f4, .accent = 0xcba6f7 },
    .{ .id = "catppuccin-latte", .name = "Catppuccin Latte", .dark = false, .bg = 0xeff1f5, .surface = 0xe6e9ef, .fg = 0x4c4f69, .ink = 0x11111b, .accent = 0x8839ef },
    .{ .id = "dracula", .name = "Dracula", .dark = true, .bg = 0x282a36, .surface = 0x343746, .fg = 0xf8f8f2, .ink = 0xf8f8f2, .accent = 0xbd93f9 },
    .{ .id = "nord", .name = "Nord", .dark = true, .bg = 0x2e3440, .surface = 0x3b4252, .fg = 0xeceff4, .ink = 0xd8dee9, .accent = 0x88c0d0 },
    .{ .id = "gruvbox-dark", .name = "Gruvbox Dark", .dark = true, .bg = 0x282828, .surface = 0x3c3836, .fg = 0xebdbb2, .ink = 0xebdbb2, .accent = 0xfe8019 },
    .{ .id = "gruvbox-light", .name = "Gruvbox Light", .dark = false, .bg = 0xfbf1c7, .surface = 0xf2e5bc, .fg = 0x3c3836, .ink = 0x1d2021, .accent = 0xaf3a03 },
    .{ .id = "tokyo-night", .name = "Tokyo Night", .dark = true, .bg = 0x1a1b26, .surface = 0x24283b, .fg = 0xc0caf5, .ink = 0xc0caf5, .accent = 0x7aa2f7 },
    .{ .id = "rose-pine", .name = "Rosé Pine", .dark = true, .bg = 0x191724, .surface = 0x1f1d2e, .fg = 0xe0def4, .ink = 0xe0def4, .accent = 0xebbcba },
    .{ .id = "one-dark", .name = "One Dark", .dark = true, .bg = 0x282c34, .surface = 0x2f343f, .fg = 0xabb2bf, .ink = 0xdcdfe4, .accent = 0x61afef },
    .{ .id = "solarized-dark", .name = "Solarized Dark", .dark = true, .bg = 0x002b36, .surface = 0x073642, .fg = 0x93a1a1, .ink = 0xfdf6e3, .accent = 0x268bd2 },
    .{ .id = "solarized-light", .name = "Solarized Light", .dark = false, .bg = 0xfdf6e3, .surface = 0xeee8d5, .fg = 0x586e75, .ink = 0x002b36, .accent = 0x268bd2 },
};

/// The theme with `id`; unknown ids (a typo in the file, a theme removed)
/// get the default. `auto` resolves with `prefer_dark`.
pub fn find(id: []const u8, prefer_dark: bool) *const Theme {
    if (std.mem.eql(u8, id, auto_id)) return if (prefer_dark) &all[0] else &all[1];
    for (&all) |*t| if (std.mem.eql(u8, t.id, id)) return t;
    return &all[0];
}

/// The name shown for a theme setting value ("Auto (Lumen Dark)").
pub fn displayName(a: std.mem.Allocator, id: []const u8, prefer_dark: bool) [:0]const u8 {
    if (std.mem.eql(u8, id, auto_id))
        return std.fmt.allocPrintSentinel(a, "Automatic ({s})", .{find(id, prefer_dark).name}, 0) catch "Automatic";
    return find(id, prefer_dark).name;
}

/// The variables block `style.css` is painted with.
pub fn css(w: *std.Io.Writer, t: *const Theme, s: *const settings.Settings) !void {
    const scale: f32 = switch (s.text_size) {
        .small => 0.9,
        .default => 1,
        .large => 1.15,
    };
    const alpha = @as(f32, @floatFromInt(s.opacity)) / 100;
    try w.writeAll(":root {\n");
    try rgba(w, "bg", t.bg, alpha);
    try rgba(w, "surface", t.surface, @min(1, alpha + 0.01));
    try rgba(w, "fg", t.fg, 1);
    try rgba(w, "ink", t.ink, 1);
    try rgba(w, "accent", t.accent, 1);
    try rgba(w, "accent-soft", t.accent, 0.35);
    try rgba(w, "accent-ring", t.accent, 0.18);
    try rgba(w, "on-accent", onAccent(t), 1);
    try rgba(w, "shadow", 0, if (t.dark) 0.45 else 0.18);
    const sizes = [_]struct { []const u8, f32 }{ .{ "font", 14 }, .{ "font-query", 18 }, .{ "font-small", 13 }, .{ "font-tiny", 12 }, .{ "font-mono", 12.5 }, .{ "font-calc", 26 }, .{ "font-emoji", 17 } };
    for (sizes) |sz| try w.print("  --{s}: {d:.1}px;\n", .{ sz[0], sz[1] * scale });
    try w.writeAll("}\n");
}

fn rgba(w: *std.Io.Writer, name: []const u8, color: u24, a: f32) !void {
    try w.print("  --{s}: rgba({d}, {d}, {d}, {d:.2});\n", .{ name, color >> 16, (color >> 8) & 0xff, color & 0xff, a });
}

/// Text on an accent fill (the selected row): near-black or white,
/// whichever reads better.
pub fn onAccent(t: *const Theme) u24 {
    const dark: u24 = 0x10131a;
    return if (contrast(t.accent, dark) >= contrast(t.accent, 0xffffff)) dark else 0xffffff;
}

/// "#rrggbb" for Pango markup.
pub fn hex(buf: *[8]u8, color: u24) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "#{x:0>6}", .{color}) catch "#ffffff";
}

/// WCAG contrast ratio between two colours (1 to 21).
pub fn contrast(x: u24, y: u24) f64 {
    const lx = luminance(x);
    const ly = luminance(y);
    return (@max(lx, ly) + 0.05) / (@min(lx, ly) + 0.05);
}

fn luminance(color: u24) f64 {
    var sum: f64 = 0;
    const weights = [_]f64{ 0.2126, 0.7152, 0.0722 };
    for (weights, 0..) |wt, i| {
        const shift: u5 = @intCast(16 - 8 * i);
        const v = @as(f64, @floatFromInt((color >> shift) & 0xff)) / 255;
        const lin = if (v <= 0.03928) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
        sum += wt * lin;
    }
    return sum;
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

fn mix(top: u24, under: u24, a: f64) u24 {
    var out: u24 = 0;
    for (0..3) |i| {
        const shift: u5 = @intCast(16 - 8 * i);
        const x: f64 = @floatFromInt((top >> shift) & 0xff);
        const y: f64 = @floatFromInt((under >> shift) & 0xff);
        out |= @as(u24, @intFromFloat(@round(x * a + y * (1 - a)))) << shift;
    }
    return out;
}

test "ids are unique and lookups fall back" {
    for (all, 0..) |x, i| for (all[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.id, y.id));
    try std.testing.expectEqualStrings("nord", find("nord", true).id);
    try std.testing.expectEqualStrings("lumen-dark", find("no-such-theme", false).id);
    try std.testing.expectEqualStrings("lumen-dark", find(auto_id, true).id);
    try std.testing.expectEqualStrings("lumen-light", find(auto_id, false).id);
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
    while (std.mem.indexOfPos(u8, style, pos, "var(--")) |at| {
        const start = at + 4;
        const end = std.mem.indexOfScalarPos(u8, style, start, ')') orelse break;
        var buf: [64]u8 = undefined;
        const decl = try std.fmt.bufPrint(&buf, "{s}:", .{style[start..end]});
        if (std.mem.indexOf(u8, vars, decl) == null) {
            std.debug.print("style.css uses undefined {s}\n", .{style[start..end]});
            return error.UndefinedVariable;
        }
        used += 1;
        pos = end;
    }
    try std.testing.expect(used > 20);
    // No hard-coded text colours left behind: they would ignore the theme.
    try std.testing.expect(std.mem.indexOf(u8, style, "rgba(255, 255, 255") == null);
}

test "text size and opacity reach the CSS" {
    var s = settings.Settings.init(std.testing.allocator);
    defer s.deinit();
    s.text_size = .large;
    s.opacity = 80;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try css(&out.writer, find("nord", true), &s);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--bg: rgba(46, 52, 64, 0.80);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--font: 16.1px;") != null);
}
