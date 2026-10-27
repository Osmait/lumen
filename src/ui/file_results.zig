//! Rows for the file and file-content searches.

const std = @import("std");
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
pub fn contentItems(self: *Ui, a: std.mem.Allocator, q: []const u8, limit: usize) []Item {
    const t0 = stats.now();
    defer self.search_ns += stats.now() - t0;
    const service = self.contents orelse return &.{};
    var hits: std.ArrayList(index.ContentService.Hit) = .empty;
    service.search(a, q, limit, &hits) catch return &.{};
    return itemsFromHits(self, a, hits.items);
}

/// A content result arrived from the worker (on the GTK main loop).
pub fn onContentResult(result: *Ui.ContentSearch.Result, ctx: ?*anyopaque) void {
    const self: *Ui = @ptrCast(@alignCast(ctx.?));
    if (result.gen != self.content_gen) {
        result.destroy(self.gpa);
        return;
    }
    if (result.err) |err| log.warn("content search for \"{s}\": {t}", .{ result.query, err });
    const old = self.content_result;
    self.content_result = result;
    self.content_pending = false;
    if (self.view == .contents) {
        self.refresh();
        // Latency from the keystroke that asked, not from this rebuild.
        if (stats.pending) |*p| {
            p.t0 = result.t0;
            p.search = result.search_ns;
        }
    }
    if (old) |o| o.destroy(self.gpa);
}

pub fn itemsFromHits(ui: *Ui, a: std.mem.Allocator, hits: []const index.ContentService.Hit) []Item {
    var out: std.ArrayList(Item) = .empty;
    for (hits) |h| {
        const path = a.dupeSentinel(u8, h.path, 0) catch continue;
        const slash = std.mem.findScalarLast(u8, h.path, '/') orelse 0;
        out.append(a, .{
            .title = labels.displayText(a, h.path[slash + 1 ..]),
            // The list is narrow beside the preview: the folder goes to the
            // detail pane, the name keeps the room.
            .accessory = std.fmt.allocPrintSentinel(a, "line {d}", .{h.line}, 0) catch "",
            .where = labels.homeRelative(a, h.path[0..slash]),
            .fact = (if (h.count > 1)
                std.fmt.allocPrintSentinel(a, "line {d} · {d}{s} matches", .{ h.line, h.count, if (h.count >= index.content.count_cap) "+" else "" }, 0)
            else
                std.fmt.allocPrintSentinel(a, "line {d}", .{h.line}, 0)) catch "",
            .icon = fileIcon(ui, path, false),
            .action = .{ .file = .{ .path = path, .is_dir = false, .line = h.line, .extracted = h.extracted } },
            .detail = h.snippet,
            .score = std.math.lossyCast(i32, h.mtime),
        }) catch break;
    }
    return out.items;
}

pub fn contentsHint(ui: *Ui, a: std.mem.Allocator, typed: usize) [:0]const u8 {
    const service = ui.contents orelse return "Content index unavailable";
    const st = service.status();
    if (!st.ready) return "Indexing the text of your files...";
    if (typed > 0) return "Type at least 3 characters";
    var buf: [32]u8 = undefined;
    const n = core.calc.formatDisplay(&buf, @floatFromInt(st.docs));
    return std.fmt.allocPrintSentinel(a, "Search inside {s} files", .{n}, 0) catch "";
}

// ---------------------------------------------------------------- files

/// Files matching `q`, from the index, as rows.
pub fn fileItems(self: *Ui, a: std.mem.Allocator, q: []const u8, limit: usize) []Item {
    const t0 = stats.now();
    defer self.search_ns += stats.now() - t0;
    const service = self.files orelse return &.{};
    var hits: std.ArrayList(index.Live.Hit) = .empty;
    service.search(a, q, limit, &hits) catch return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (hits.items) |h| {
        const path = a.dupeSentinel(u8, h.path, 0) catch continue;
        const slash = std.mem.findScalarLast(u8, h.path, '/') orelse 0;
        const where = labels.homeRelative(a, h.path[0..slash]);
        out.append(a, .{
            .key = std.fmt.allocPrint(a, "file:{s}", .{h.path}) catch "",
            .title = labels.displayText(a, h.path[slash + 1 ..]),
            .subtitle = where,
            .icon = fileIcon(self, path, h.is_dir),
            .action = .{ .file = .{ .path = path, .is_dir = h.is_dir } },
            .score = h.score,
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
        const name = if (slash) |s| path[s + 1 ..] else path;
        // lumen.icons { ["file:pdf"] = ... }, by extension.
        if (std.mem.findScalarLast(u8, name, '.')) |dot| if (name.len - dot <= 16) {
            var buf: [24]u8 = undefined;
            const k = std.fmt.bufPrint(&buf, "file:{s}", .{name[dot + 1 ..]}) catch "";
            if (ui.keyIcon(std.ascii.lowerString(buf[0..k.len], k))) |icon| return icon;
        };
        if (core.file_badge.logoOf(name)) |l| return .{ .logo = l };
        var upper: [4]u8 = undefined;
        if (core.file_badge.of(name, &upper)) |b| {
            const text = ui.query_arena.allocator().dupeSentinel(u8, b.text, 0) catch return .none;
            return .{ .badge = .{ .text = text, .color = b.color } };
        }
    }
    const ctype = if (is_dir) null else c.g_content_type_guess(path, null, 0, null);
    defer if (ctype) |t| c.g_free(t);
    const icon = c.g_content_type_get_icon(if (ctype) |t| t else "inode/directory");
    ui.icons.append(ui.gpa, icon) catch {
        c.g_object_unref(icon);
        return .none;
    };
    return .{ .gicon = icon };
}

pub fn filesHint(ui: *Ui, a: std.mem.Allocator) [:0]const u8 {
    const service = ui.files orelse return "File index unavailable";
    const st = service.status();
    if (st.entries == 0) return "Indexing your files...";
    var buf: [32]u8 = undefined;
    const n = core.calc.formatDisplay(&buf, @floatFromInt(st.entries));
    return std.fmt.allocPrintSentinel(a, "Type to search {s} files", .{n}, 0) catch "";
}
