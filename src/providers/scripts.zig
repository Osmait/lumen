//! Script commands from ~/.config/lumen/scripts.

const std = @import("std");
const c = @import("c");
const script_meta = @import("core").script_meta;
const Item = @import("../item.zig").Item;

/// ~/.config/lumen/scripts, in `a`; null only when out of memory.
pub fn dir(a: std.mem.Allocator) ?[:0]const u8 {
    const config = std.mem.span(c.g_get_user_config_dir());
    return std.fmt.allocPrintSentinel(a, "{s}/lumen/scripts", .{config}, 0) catch null;
}

/// Scans the scripts directory. Everything lives in `a`.
pub fn load(a: std.mem.Allocator) []Item {
    const path = dir(a) orelse return &.{};
    const d = c.g_dir_open(path.ptr, 0, null) orelse return &.{};
    defer c.g_dir_close(d);

    var items: std.ArrayList(Item) = .empty;
    while (c.g_dir_read_name(d)) |name_c| {
        const name = std.mem.span(name_c);
        if (name.len == 0 or name[0] == '.') continue;
        const full = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ path, name }, 0) catch continue;

        var contents_c: ?[*:0]u8 = null;
        var len: usize = 0;
        if (c.g_file_get_contents(full.ptr, &contents_c, &len, null) == 0) continue;
        const contents = contents_c orelse continue;
        defer c.g_free(contents);
        const head = contents[0..@min(len, 4096)];
        const meta = script_meta.parse(head) orelse continue;

        const emoji = meta.icon.len > 0 and meta.icon.len <= 8 and meta.icon[0] >= 0x80;
        items.append(a, .{
            .key = std.fmt.allocPrint(a, "script:{s}", .{name}) catch continue,
            .title = a.dupeZ(u8, meta.title) catch continue,
            .subtitle = a.dupeZ(u8, if (meta.package_name.len > 0) meta.package_name else "Script Command") catch continue,
            .accessory = "Script",
            .keywords = a.dupe(u8, meta.description) catch "",
            .confirm = meta.needs_confirmation,
            .icon = if (emoji)
                .{ .emoji = a.dupeZ(u8, meta.icon) catch "" }
            else
                .{ .tile = .{ .name = "utilities-terminal-symbolic", .color = .gray } },
            .action = .{ .script = .{ .path = full, .mode = meta.mode } },
        }) catch continue;
    }
    return items.toOwnedSlice(a) catch &.{};
}
