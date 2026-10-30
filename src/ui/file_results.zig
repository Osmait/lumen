//! Rows for the file and file-content searches.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const index = @import("index");
const stats = @import("../stats.zig");
const Ui = @import("Ui.zig");

const log = std.log.scoped(.ui);
const labels = @import("labels.zig");

// ------------------------------------------------------------- contents

/// Files whose text contains the query, with the matching line.
pub fn contentItems(self: *Ui, arena: std.mem.Allocator, query: []const u8, limit: usize) []Item {
    const t0 = stats.now();
    defer self.search_ns += stats.now() - t0;
    const service = self.contents orelse return &.{};
    var hits: std.ArrayList(index.ContentService.Hit) = .empty;
    service.search(arena, query, limit, &hits) catch return &.{};
    return itemsFromHits(self, arena, hits.items);
}

/// A content result arrived from the worker (on the GTK main loop).
pub fn onContentResult(result: *Ui.ContentSearch.Result, ctx: ?*anyopaque) void {
    const self: *Ui = @ptrCast(@alignCast(ctx.?));
    if (result.gen != self.content_gen) {
        result.destroy(self.gpa);
        return;
    }
    // Each answer is delivered once: the one shown is never handed back.
    assert(result != self.content_result);
    if (result.err) |err| log.warn("content search for \"{s}\": {t}", .{ result.query, err });
    const old = self.content_result;
    self.content_result = result;
    self.content_pending = false;
    if (self.view == .contents) {
        self.refresh();
        // Latency from the keystroke that asked, not from this rebuild.
        if (stats.pending) |*pending_stats| {
            pending_stats.t0 = result.start_ns;
            pending_stats.search = result.search_ns;
        }
    }
    if (old) |old_result| old_result.destroy(self.gpa);
}

pub fn itemsFromHits(
    ui: *Ui,
    arena: std.mem.Allocator,
    hits: []const index.ContentService.Hit,
) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (hits) |hit| {
        const path = arena.dupeSentinel(u8, hit.path, 0) catch continue;
        const slash = std.mem.findScalarLast(u8, hit.path, '/') orelse 0;
        out.append(arena, .{
            .title = labels.displayText(arena, hit.path[slash + 1 ..]),
            // The list is narrow beside the preview: the folder goes to the
            // detail pane, the name keeps the room.
            .accessory = arena.printSentinel("line {d}", .{hit.line}, 0) catch "",
            .where = labels.homeRelative(arena, hit.path[0..slash]),
            .fact = (if (hit.count > 1)
                arena.printSentinel(
                    "line {d} · {d}{s} matches",
                    .{ hit.line, hit.count, if (hit.count >= index.content.count_cap) "+" else "" },
                    0,
                )
            else
                arena.printSentinel("line {d}", .{hit.line}, 0)) catch "",
            .icon = fileIcon(ui, path, false),
            .action = .{ .file = .{
                .path = path,
                .is_dir = false,
                .line = hit.line,
                .extracted = hit.extracted,
            } },
            .detail = hit.snippet,
            .time_s = hit.mtime,
        }) catch break;
    }
    return out.items;
}

pub fn contentsHint(ui: *Ui, arena: std.mem.Allocator, typed: usize) [:0]const u8 {
    const service = ui.contents orelse return "Content index unavailable";
    const st = service.status();
    if (!st.ready) return "Indexing the text of your files...";
    if (typed > 0) return "Type at least 3 characters";
    var buf: [32]u8 = undefined;
    const count_text = core.calc.formatDisplay(&buf, @floatFromInt(st.docs));
    return arena.printSentinel("Search inside {s} files", .{count_text}, 0) catch "";
}

// ---------------------------------------------------------------- files

/// Files matching `q`, from the index, as rows.
pub fn fileItems(self: *Ui, arena: std.mem.Allocator, query: []const u8, limit: usize) []Item {
    const t0 = stats.now();
    defer self.search_ns += stats.now() - t0;
    const service = self.files orelse return &.{};
    var hits: std.ArrayList(index.Live.Hit) = .empty;
    service.search(arena, query, limit, &hits) catch return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (hits.items) |hit| {
        const path = arena.dupeSentinel(u8, hit.path, 0) catch continue;
        const slash = std.mem.findScalarLast(u8, hit.path, '/') orelse 0;
        const where = labels.homeRelative(arena, hit.path[0..slash]);
        out.append(arena, .{
            .key = arena.print("file:{s}", .{hit.path}) catch "",
            .title = labels.displayText(arena, hit.path[slash + 1 ..]),
            .subtitle = where,
            .icon = fileIcon(self, path, hit.is_dir),
            .action = .{ .file = .{ .path = path, .is_dir = hit.is_dir } },
            .score = hit.score,
        }) catch break;
    }
    return out.items;
}

/// Icon for a file's type, guessed from its name (no I/O): the extension
/// badge for code and text, the theme's icon for the rest.
pub fn fileIcon(ui: *Ui, path: [:0]const u8, is_dir: bool) item_mod.Icon {
    if (is_dir) {
        if (ui.keyIcon("file:folder")) |icon| return icon;
    } else {
        const slash = std.mem.findScalarLast(u8, path, '/');
        const name = if (slash) |slash_index| path[slash_index + 1 ..] else path;
        // lumen.icons { ["file:pdf"] = ... }, by extension.
        if (std.mem.findScalarLast(u8, name, '.')) |dot| if (name.len - dot <= 16) {
            var buf: [24]u8 = undefined;
            const key = std.mem.print(&buf, "file:{s}", .{name[dot + 1 ..]}) catch "";
            if (ui.keyIcon(std.ascii.lowerString(buf[0..key.len], key))) |icon| return icon;
        };
        if (core.file_badge.logoOf(name)) |logo| return .{ .logo = logo };
        var upper: [4]u8 = undefined;
        if (core.file_badge.of(name, &upper)) |badge| {
            const text = ui.query_arena.allocator().dupeSentinel(
                u8,
                badge.text,
                0,
            ) catch return .none;
            return .{ .badge = .{ .text = text, .color = badge.color } };
        }
    }
    const ctype = if (is_dir) null else c.g_content_type_guess(path, null, 0, null);
    defer if (ctype) |type_name| c.g_free(type_name);
    return .{ .gicon = typeIcon(
        if (ctype) |type_name| type_name else "inode/directory",
    ) orelse return .none };
}

/// One GIcon per content type, kept for good (a few dozen): the files view
/// made a new one for every row of every keystroke.
var type_icons: std.StringHashMapUnmanaged(*c.GIcon) = .empty;

fn typeIcon(ctype: [*:0]const u8) ?*c.GIcon {
    const key = std.mem.span(ctype);
    if (type_icons.get(key)) |icon| return icon;
    const icon = c.g_content_type_get_icon(ctype);
    const gpa = std.heap.c_allocator;
    const owned = gpa.dupe(u8, key) catch return null;
    type_icons.put(gpa, owned, icon) catch {
        gpa.free(owned);
        c.g_object_unref(icon);
        return null;
    };
    return icon;
}

pub fn filesHint(ui: *Ui, arena: std.mem.Allocator) [:0]const u8 {
    const service = ui.files orelse return "File index unavailable";
    const st = service.status();
    if (st.entries == 0) return "Indexing your files...";
    var buf: [32]u8 = undefined;
    const count_text = core.calc.formatDisplay(&buf, @floatFromInt(st.entries));
    return arena.printSentinel("Type to search {s} files", .{count_text}, 0) catch "";
}
