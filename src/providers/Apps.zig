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
    if (self.list) |l| c.g_list_free_full(l, &c.g_object_unref);
    self.arena.deinit();
    self.* = undefined;
}

/// Frees the lists `reload` replaced; call once nothing points into them.
pub fn dropStale(self: *Apps) void {
    for (self.stale.items) |*g| {
        if (g.list) |l| c.g_list_free_full(l, &c.g_object_unref);
        g.arena.deinit();
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
            if (self.list) |l| c.g_list_free_full(l, &c.g_object_unref);
            _ = self.arena.reset(.retain_capacity);
        }
    }
    self.list = c.g_app_info_get_all();
    const a = self.arena.allocator();

    var items: std.ArrayList(Item) = .empty;
    var dropped: usize = 0;
    defer if (dropped > 0) log.warn("{d} apps left out: out of memory", .{dropped});
    var node = self.list;
    while (node) |n| : (node = n.next) {
        const info: *c.GAppInfo = @ptrCast(@alignCast(n.data));
        if (c.g_app_info_should_show(info) == 0) continue;
        const id = std.mem.span(c.g_app_info_get_id(info) orelse continue);
        const name = std.mem.span(c.g_app_info_get_display_name(info) orelse continue);
        const dai: *c.GDesktopAppInfo = @ptrCast(info);

        var generic: [:0]const u8 = "";
        if (c.g_desktop_app_info_get_generic_name(dai)) |g| generic = std.mem.span(g);

        items.append(a, .{
            .key = std.fmt.allocPrint(a, "app:{s}", .{id}) catch {
                dropped += 1;
                continue;
            },
            .title = name,
            .subtitle = generic,
            .accessory = "Application",
            .icon = if (c.g_app_info_get_icon(info)) |icon| .{ .gicon = icon } else .none,
            .keywords = keywords(a, dai, info),
            .action = .{ .app = info },
        }) catch {
            dropped += 1;
            continue;
        };
    }
    self.items = items.toOwnedSlice(a) catch items.items;
}

/// Icon of the app that owns windows of `class` (Hyprland's class is the
/// Wayland app_id: usually the desktop id or its StartupWMClass).
pub fn iconForClass(self: *const Apps, class: []const u8) ?*c.GIcon {
    if (class.len == 0) return null;
    for (self.items) |item| {
        const info = item.action.app;
        const dai: *c.GDesktopAppInfo = @ptrCast(info);
        if (c.g_desktop_app_info_get_startup_wm_class(dai)) |wm| {
            if (std.ascii.eqlIgnoreCase(std.mem.span(wm), class)) return iconOf(item);
        }
        const id = std.mem.span(c.g_app_info_get_id(info) orelse continue);
        const stem = if (std.mem.endsWith(u8, id, ".desktop")) id[0 .. id.len - 8] else id;
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
        .gicon => |g| g,
        else => null,
    };
}

/// Keywords, executable name and categories, space separated.
fn keywords(a: std.mem.Allocator, dai: *c.GDesktopAppInfo, info: *c.GAppInfo) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (c.g_desktop_app_info_get_keywords(dai)) |kw| {
        var i: usize = 0;
        while (kw[i]) |k| : (i += 1) {
            out.appendSlice(a, std.mem.span(k)) catch break;
            out.append(a, ' ') catch break;
        }
    }
    if (c.g_app_info_get_executable(info)) |exe| {
        const e = std.mem.span(exe);
        const base = if (std.mem.findScalarLast(u8, e, '/')) |s| e[s + 1 ..] else e;
        out.appendSlice(a, base) catch {};
    }
    return out.items;
}
