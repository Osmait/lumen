//! `lumen --dump`: what the window shows, as text. The end-to-end tests
//! (tools/e2e.sh) compare it line by line, so its format is fixed: change
//! it only together with them.
//!
//! It reads the window's state and its widgets, and changes nothing but the
//! rows still queued, which it builds so every row is listed.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const row_list = @import("row_list.zig");
const search = @import("search.zig");
const window_layout = @import("window_layout.zig");
const Ui = @import("Ui.zig");

/// `lumen --dump`: what the window shows, as text (for end-to-end tests).
/// Caller owns the result, allocated with `gpa`.
pub fn dump(
    ui: *Ui,
    gpa: std.mem.Allocator,
) (std.Io.Writer.Error || std.mem.Allocator.Error)![:0]u8 {
    assert(ui.built);
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const arena = scratch_state.allocator();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;
    try dumpWindow(ui, writer);
    try dumpRows(ui, writer, arena);
    if (gtk.isVisible(ui.detail.box)) try dumpDetail(ui, writer);
    if (ui.panel.isOpen()) {
        try writer.print("panel:\n", .{});
        for (ui.panel.entries, 0..) |entry, i| try writer.print("  {s} {s} [{s}]\n", .{
            if (i == ui.panel.selected) ">" else " ",
            entry.label,
            entry.keys,
        });
    }
    return out.toOwnedSliceSentinel(0);
}

/// The dump's first lines: the view, the query, the layout and the footer.
fn dumpWindow(ui: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("view: {t}\nvisible: {}\nquery: {s}\n", .{
        ui.view,
        gtk.isVisible(ui.window),
        ui.query(),
    });
    try writer.print("title: {s}\nprimary: {s}\n", .{ ui.viewTitle(), ui.primary });
    const layout = ui.layout;
    try writer.print(
        "style: {s}\n",
        .{if (ui.settings.style.len > 0) ui.settings.style else "-"},
    );
    try writer.print("layout: {d}x{d} panels={t} search={t} detail={t} rows={t} footer={}", .{
        window_layout.panelWidth(ui),
        window_layout.panelHeight(ui),
        layout.panels,
        layout.search,
        layout.detail,
        layout.rows,
        layout.footer,
    });
    try writer.writeAll(" bar=");
    for (layout.searchbar.slice(), 0..) |part, i| {
        try writer.print("{s}{t}", .{ if (i > 0) "," else "", part });
    }
    try writer.writeAll(" row=");
    for (layout.row.slice(), 0..) |part, i| {
        try writer.print("{s}{t}", .{ if (i > 0) "," else "", part });
    }
    try writer.print(" prompt={s} placeholder={s}\n", .{ layout.prompt, layout.placeholder });
    if (layout.footer) {
        try writer.print("footer: {s} | {s}\n", .{
            c.gtk_label_get_text(ui.footer.title),
            c.gtk_label_get_text(ui.footer.action),
        });
    }
}

/// One line per row: the selection mark, the texts, the icon and the key.
fn dumpRows(ui: *Ui, writer: *std.Io.Writer, arena: std.mem.Allocator) std.Io.Writer.Error!void {
    try writer.print("rows:\n", .{});
    row_list.ensureRows(ui);
    if (ui.rows.items.len == 0) {
        try writer.print("  (empty) {s}\n", .{search.emptyText(ui, arena)});
    }
    for (ui.rows.items, 0..) |row, i| {
        const item_index = row.item orelse {
            try writer.print("  # {s}\n", .{row.section});
            continue;
        };
        const item = ui.items.items[item_index];
        const mark: []const u8 = if (ui.selected == i) ">" else " ";
        try writer.print(
            "  {s} {s} | {s} | {s} | ",
            .{ mark, item.title, item.subtitle, item.accessory },
        );
        switch (item.icon) {
            .logo => |logo| try writer.print("logo:{s}", .{logo.name}),
            .badge => |badge| try writer.print("badge:{s}", .{badge.text}),
            .tile => |tile| try writer.print("tile:{s}", .{tile.name}),
            .gicon => try writer.print("gicon", .{}),
            .emoji => |emoji| try writer.print("emoji:{s}", .{emoji}),
            .file => |file_path| try writer.print(
                "file:{s}",
                .{std.Io.Dir.path.basename(file_path)},
            ),
            .swatch => |swatch| try writer.print("swatch:{s}", .{swatch.id}),
            .named => |name| try writer.print("icon:{s}", .{name}),
            .none => try writer.print("none", .{}),
        }
        // The key, for lumen.icons (empty for rows without one). A file's is
        // its path, which need not be UTF-8: the dump must stay text.
        try writer.print(
            " | {s}\n",
            .{if (std.unicode.utf8ValidateSlice(item.key)) item.key else "?"},
        );
    }
}

/// The detail pane: an extension's first line of text, and the metadata.
fn dumpDetail(ui: *Ui, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("detail:\n", .{});
    if (ui.view == .ext) {
        const text = std.mem.span(c.gtk_label_get_text(ui.detail.text));
        try writer.print("  text = {s}\n", .{
            text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len],
        });
    }
    if (gtk.isVisible(ui.detail.meta)) {
        const detail = &ui.detail;
        for (detail.meta_lines, detail.meta_keys, detail.meta_values) |line, key, value| {
            if (!gtk.isVisible(line)) continue;
            try writer.print("  {s} = {s}\n", .{
                c.gtk_label_get_text(key),
                c.gtk_label_get_text(value),
            });
        }
    }
}
