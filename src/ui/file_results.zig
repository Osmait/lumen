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
pub fn contentItems(ui: *Ui, arena: std.mem.Allocator, query: []const u8, limit: usize) []Item {
    const search_start_ns = stats.now();
    defer ui.search_ns += stats.now() - search_start_ns;
    const service = ui.contents orelse return &.{};
    var hits: std.ArrayList(index.ContentService.Hit) = .empty;
    service.search(arena, query, limit, &hits) catch return &.{};
    return itemsFromHits(ui, arena, hits.items);
}

/// A content result arrived from the worker (on the GTK main loop).
pub fn onContentResult(result: *Ui.ContentSearch.Result, context: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(context.?));
    if (!ui.content_query.current(result)) {
        result.destroy(ui.gpa);
        return;
    }
    if (result.err) |err| log.warn("content search for \"{s}\": {t}", .{ result.query, err });
    const replaced = ui.content_query.take(result);
    if (ui.view == .contents) {
        ui.refresh();
        // Latency from the keystroke that asked, not from this rebuild.
        if (stats.pending) |*pending_stats| {
            pending_stats.start_ns = result.start_ns;
            pending_stats.search_ns = result.search_ns;
        }
    }
    if (replaced) |replaced_result| replaced_result.destroy(ui.gpa);
}

/// A row per content hit: the file's name, the matching line and how many
/// lines match.
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

/// What the content search asks for while the query is too short to look
/// up, from the same minimum the search uses.
const type_more_hint = std.fmt.comptimePrint(
    "Type at least {d} characters",
    .{Ui.content_query_bytes_min},
);

/// The contents view's empty row, by how much is typed (`typed_bytes`).
pub fn contentsHint(ui: *Ui, arena: std.mem.Allocator, typed_bytes: usize) [:0]const u8 {
    const service = ui.contents orelse return "Content index unavailable";
    const status = service.status();
    if (!status.ready) return "Indexing the text of your files...";
    if (typed_bytes > 0) return type_more_hint;
    var count_bytes: [32]u8 = undefined;
    const count_text = core.calc.formatDisplay(&count_bytes, @floatFromInt(status.docs));
    return arena.printSentinel("Search inside {s} files", .{count_text}, 0) catch "";
}

// ---------------------------------------------------------------- files

/// Files matching `query`, from the index, as rows.
pub fn fileItems(ui: *Ui, arena: std.mem.Allocator, query: []const u8, limit: usize) []Item {
    const search_start_ns = stats.now();
    defer ui.search_ns += stats.now() - search_start_ns;
    const service = ui.files orelse return &.{};
    var hits: std.ArrayList(index.Live.Hit) = .empty;
    service.search(arena, query, limit, &hits) catch return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (hits.items) |hit| {
        const path = arena.dupeSentinel(u8, hit.path, 0) catch continue;
        const slash = std.mem.findScalarLast(u8, hit.path, '/') orelse 0;
        const where = labels.homeRelative(arena, hit.path[0..slash]);
        out.append(arena, .{
            .key = arena.print(file_key_prefix ++ "{s}", .{hit.path}) catch "",
            .title = labels.displayText(arena, hit.path[slash + 1 ..]),
            .subtitle = where,
            .icon = fileIcon(ui, path, hit.is_dir),
            .action = .{ .file = .{ .path = path, .is_dir = hit.is_dir } },
            .score = hit.score,
        }) catch break;
    }
    return out.items;
}

/// A file's item key is this and its path; lumen.icons names file types
/// with it too: this and "folder", or this and an extension. An extension
/// is looked up only when it is this short, dot included (a dot late in a
/// long name does not start an extension).
const file_key_prefix = "file:";
const extension_bytes_max = 16;

/// Icon for a file's type, guessed from its name (no I/O): the extension
/// badge for code and text, the theme's icon for the rest.
pub fn fileIcon(ui: *Ui, path: [:0]const u8, is_directory: bool) item_mod.Icon {
    if (is_directory) {
        if (ui.keyIcon(file_key_prefix ++ "folder")) |icon| return icon;
    } else {
        const slash = std.mem.findScalarLast(u8, path, '/');
        const name = if (slash) |slash_index| path[slash_index + 1 ..] else path;
        // lumen.icons { ["file:pdf"] = ... }, by extension.
        const dot = std.mem.findScalarLast(u8, name, '.');
        if (dot != null and name.len - dot.? <= extension_bytes_max) {
            var key_bytes: [file_key_prefix.len + extension_bytes_max]u8 = undefined;
            const extension = name[dot.? + 1 ..];
            const key = std.mem.print(&key_bytes, file_key_prefix ++ "{s}", .{extension}) catch "";
            if (ui.keyIcon(std.ascii.lowerString(key_bytes[0..key.len], key))) |icon| return icon;
        }
        if (core.file_badge.logoOf(name)) |logo| return .{ .logo = logo };
        var badge_text: [4]u8 = undefined;
        if (core.file_badge.of(name, &badge_text)) |badge| {
            const text = ui.query_arena.allocator().dupeSentinel(
                u8,
                badge.text,
                0,
            ) catch return .none;
            return .{ .badge = .{ .text = text, .color = badge.color } };
        }
    }
    const guessed_type = if (is_directory) null else c.g_content_type_guess(path, null, 0, null);
    defer if (guessed_type) |type_name| c.g_free(type_name);
    const content_type = guessed_type orelse "inode/directory";
    return .{ .gicon = typeIcon(content_type) orelse return .none };
}

/// One GIcon per content type, kept for good (a few dozen): the files view
/// made a new one for every row of every keystroke.
var type_icons: std.StringHashMapUnmanaged(*c.GIcon) = .empty;

fn typeIcon(content_type: [*:0]const u8) ?*c.GIcon {
    const key = std.mem.span(content_type);
    if (type_icons.get(key)) |icon| return icon;
    const icon = c.g_content_type_get_icon(content_type);
    const gpa = std.heap.c_allocator;
    const owned = gpa.dupe(u8, key) catch return null;
    type_icons.put(gpa, owned, icon) catch {
        gpa.free(owned);
        c.g_object_unref(icon);
        return null;
    };
    return icon;
}

/// The files view's empty row with nothing typed.
pub fn filesHint(ui: *Ui, arena: std.mem.Allocator) [:0]const u8 {
    const service = ui.files orelse return "File index unavailable";
    const status = service.status();
    if (status.entries == 0) return "Indexing your files...";
    var count_bytes: [32]u8 = undefined;
    const count_text = core.calc.formatDisplay(&count_bytes, @floatFromInt(status.entries));
    return arena.printSentinel("Type to search {s} files", .{count_text}, 0) catch "";
}
