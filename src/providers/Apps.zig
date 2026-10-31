//! Installed applications, from the .desktop files GIO knows about.

const std = @import("std");
const c = @import("c");
const Item = @import("../item.zig").Item;

/// The app list. Main thread only (GIO).
const Apps = @This();

const log = std.log.scoped(.apps);

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
list: ?*c.GList = null,
items: []Item = &.{},
/// Lists replaced by `reload` that views may still point into (their items'
/// strings, GAppInfo and GIcon pointers): freed by `dropStale` once every
/// view's items were built again.
stale: std.ArrayList(Generation) = .empty,

const Generation = struct { arena: std.heap.ArenaAllocator, list: ?*c.GList };

pub fn init(gpa: std.mem.Allocator) Apps {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *Apps) void {
    self.dropStale();
    self.stale.deinit(self.gpa);
    if (self.list) |list| c.g_list_free_full(list, &c.g_object_unref);
    self.arena.deinit();
    self.* = undefined;
}

/// Frees the lists `reload` replaced; call once nothing points into them.
pub fn dropStale(self: *Apps) void {
    for (self.stale.items) |*generation| {
        if (generation.list) |list| c.g_list_free_full(list, &c.g_object_unref);
        generation.arena.deinit();
    }
    self.stale.clearRetainingCapacity();
}

/// Reads the installed apps again. Earlier `items` and the GAppInfo
/// pointers in them stay valid until `dropStale`.
pub fn reload(self: *Apps) void {
    if (self.list != null or self.items.len > 0) {
        if (self.stale.append(self.gpa, .{ .arena = self.arena, .list = self.list })) {
            self.arena = .init(self.gpa);
        } else |_| {
            // No room to keep them: free now, as before (rare and racy).
            if (self.list) |list| c.g_list_free_full(list, &c.g_object_unref);
            _ = self.arena.reset(.retain_capacity);
        }
    }
    self.list = c.g_app_info_get_all();
    const arena = self.arena.allocator();

    var items: std.ArrayList(Item) = .empty;
    var dropped: usize = 0;
    defer if (dropped > 0) log.warn("{d} apps left out: out of memory", .{dropped});
    var node = self.list;
    while (node) |list_node| : (node = list_node.next) {
        const info: *c.GAppInfo = @ptrCast(@alignCast(list_node.data));
        if (c.g_app_info_should_show(info) == 0) continue;
        const item = (itemOf(arena, info) catch {
            dropped += 1;
            continue;
        }) orelse continue;
        items.append(arena, item) catch {
            dropped += 1;
            continue;
        };
    }
    self.items = items.toOwnedSlice(arena) catch items.items;
}

/// The row for `info`, its strings in `arena`; null for an app without an
/// id or a name.
fn itemOf(arena: std.mem.Allocator, info: *c.GAppInfo) std.mem.Allocator.Error!?Item {
    const id = std.mem.span(c.g_app_info_get_id(info) orelse return null);
    const name = std.mem.span(c.g_app_info_get_display_name(info) orelse return null);
    const desktop_info: *c.GDesktopAppInfo = @ptrCast(info);
    var generic_name: [:0]const u8 = "";
    if (c.g_desktop_app_info_get_generic_name(desktop_info)) |generic_name_z| {
        generic_name = std.mem.span(generic_name_z);
    }
    return .{
        .key = try arena.print("app:{s}", .{id}),
        .title = name,
        .subtitle = generic_name,
        .accessory = "Application",
        .icon = if (c.g_app_info_get_icon(info)) |icon| .{ .gicon = icon } else .none,
        .keywords = try keywords(arena, desktop_info, info),
        .action = .{ .app = info },
    };
}

/// Icon of the app that owns windows of `class` (Hyprland's class is the
/// Wayland app_id: usually the desktop id or its StartupWMClass).
pub fn iconForClass(self: *const Apps, class: []const u8) ?*c.GIcon {
    if (class.len == 0) return null;
    for (self.items) |item| {
        const info = item.action.app;
        const desktop_info: *c.GDesktopAppInfo = @ptrCast(info);
        if (c.g_desktop_app_info_get_startup_wm_class(desktop_info)) |wm_class| {
            if (std.ascii.eqlIgnoreCase(std.mem.span(wm_class), class)) return iconOf(item);
        }
        const id = std.mem.span(c.g_app_info_get_id(info) orelse continue);
        const suffix = ".desktop";
        const stem = if (std.mem.endsWith(u8, id, suffix)) id[0 .. id.len - suffix.len] else id;
        if (std.ascii.eqlIgnoreCase(stem, class)) return iconOf(item);
        // Reverse-DNS ids: org.mozilla.firefox vs class "firefox".
        if (std.mem.findScalarLast(u8, stem, '.')) |dot| {
            if (std.ascii.eqlIgnoreCase(stem[dot + 1 ..], class)) return iconOf(item);
        }
    }
    return null;
}

fn iconOf(item: Item) ?*c.GIcon {
    return switch (item.icon) {
        .gicon => |gicon| gicon,
        else => null,
    };
}

/// Keywords and the executable's name, space separated, in `arena`.
fn keywords(
    arena: std.mem.Allocator,
    desktop_info: *c.GDesktopAppInfo,
    info: *c.GAppInfo,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (c.g_desktop_app_info_get_keywords(desktop_info)) |keywords_z| {
        var keyword_index: usize = 0;
        while (keywords_z[keyword_index]) |keyword| : (keyword_index += 1) {
            try out.appendSlice(arena, std.mem.span(keyword));
            try out.append(arena, ' ');
        }
    }
    if (c.g_app_info_get_executable(info)) |executable_z| {
        const executable = std.mem.span(executable_z);
        const slash = std.mem.findScalarLast(u8, executable, '/');
        const base = if (slash) |at| executable[at + 1 ..] else executable;
        try out.appendSlice(arena, base);
    }
    return out.items;
}
