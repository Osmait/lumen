//! The styles in this folder, built into Lumen: Change Theme lists them
//! under "Styles". Each is what a style folder in ~/.config/lumen/styles
//! holds: an init.lua (lumen.layout, lumen.theme, lumen.set) and a style.css.

pub const Style = struct {
    id: []const u8,
    name: [:0]const u8,
    description: [:0]const u8,
    lua: [:0]const u8,
    css: []const u8,
};

pub const all = [_]Style{
    .{
        .id = "lumen",
        .name = "Lumen",
        .description = "Two floating pieces, the default look",
        .lua = "lumen.set { theme = \"auto\", density = \"default\", opacity = 97 }\n",
        .css = "",
    },
    .{ .id = "raycast", .name = "Raycast", .description = "One panel, a footer, inline subtitles", .lua = @embedFile("raycast/init.lua"), .css = @embedFile("raycast/style.css") },
    .{ .id = "spotlight", .name = "Spotlight", .description = "A large search field, compact rows", .lua = @embedFile("spotlight/init.lua"), .css = @embedFile("spotlight/style.css") },
    .{ .id = "alfred", .name = "Alfred", .description = "A framed search field, tall rows", .lua = @embedFile("alfred/init.lua"), .css = @embedFile("alfred/style.css") },
    .{ .id = "minimal", .name = "Minimal", .description = "rofi-like: text only, monospace", .lua = @embedFile("minimal/init.lua"), .css = @embedFile("minimal/style.css") },
    .{ .id = "omarchy", .name = "Omarchy", .description = "Omarchy's menu, its palettes", .lua = @embedFile("omarchy/init.lua"), .css = @embedFile("omarchy/style.css") },
};

pub fn find(id: []const u8) ?*const Style {
    for (&all) |*s| if (eql(s.id, id)) return s;
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
