//! The detail pane: clipboard text, file previews, content context.

const std = @import("std");
const core = @import("core");
const c = @import("c");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const index = @import("index");
const os = @import("os");
const pictures = @import("pictures.zig");
const stats = @import("../stats.zig");
const Ui = @import("Ui.zig");
const widgets = @import("widgets.zig");
const labels = @import("labels.zig");

pub fn buildDetail(ui: *Ui) void {
    ui.detail = widgets.vbox(0);
    c.gtk_widget_add_css_class(ui.detail, "detail");
    c.gtk_widget_set_hexpand(ui.detail, 1);

    // Image previews (files view).
    ui.detail_picture = c.gtk_picture_new();
    c.gtk_picture_set_content_fit(@ptrCast(ui.detail_picture), c.GTK_CONTENT_FIT_SCALE_DOWN);
    c.gtk_widget_set_vexpand(ui.detail_picture, 1);
    c.gtk_widget_add_css_class(ui.detail_picture, "preview");
    c.gtk_box_append(@ptrCast(ui.detail), ui.detail_picture);

    const sc = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(sc), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_vexpand(sc, 1);
    ui.detail_text = widgets.label("", "detail-text");
    c.gtk_label_set_wrap(@ptrCast(ui.detail_text), 1);
    c.gtk_label_set_wrap_mode(@ptrCast(ui.detail_text), c.PANGO_WRAP_WORD_CHAR);
    // A wrapping GtkLabel asks for its unwrapped width unless told otherwise;
    // this lets the list keep its share of the row.
    c.gtk_label_set_max_width_chars(@ptrCast(ui.detail_text), 1);
    c.gtk_widget_set_hexpand(ui.detail_text, 1);
    c.gtk_label_set_yalign(@ptrCast(ui.detail_text), 0);
    c.gtk_widget_set_valign(ui.detail_text, c.GTK_ALIGN_START);
    c.gtk_scrolled_window_set_child(@ptrCast(sc), ui.detail_text);
    c.gtk_box_append(@ptrCast(ui.detail), sc);

    const meta = widgets.vbox(4);
    ui.detail_meta = meta;
    c.gtk_widget_add_css_class(meta, "meta");
    c.gtk_box_append(@ptrCast(meta), widgets.label("Information", "meta-header"));
    const keys = [_][:0]const u8{ "Content type", "Characters", "Words", "Copied" };
    for (keys, 0..) |key, i| {
        const line = widgets.hbox(12);
        ui.meta_lines[i] = line;
        ui.meta_keys[i] = widgets.label(key, "meta-key");
        c.gtk_box_append(@ptrCast(line), ui.meta_keys[i]);
        const spacer = widgets.hbox(0);
        c.gtk_widget_set_hexpand(spacer, 1);
        c.gtk_box_append(@ptrCast(line), spacer);
        ui.meta_values[i] = widgets.label("", "meta-value");
        c.gtk_label_set_ellipsize(@ptrCast(ui.meta_values[i]), c.PANGO_ELLIPSIZE_START);
        // The layer surface grows to its content's natural width; a long path
        // here would widen the whole window.
        c.gtk_label_set_max_width_chars(@ptrCast(ui.meta_values[i]), 30);
        c.gtk_box_append(@ptrCast(line), ui.meta_values[i]);
        c.gtk_box_append(@ptrCast(meta), line);
    }
    c.gtk_box_append(@ptrCast(ui.detail), meta);
    c.gtk_widget_set_visible(ui.detail, 0);
}

/// The lines around the match, words highlighted.
pub fn showContentDetail(ui: *Ui, it: *const Item) void {
    const f = it.action.file;
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    c.gtk_widget_set_visible(ui.detail_picture, 0);

    const info = os.info(f.path);
    const service = ui.contents orelse return;
    const text = service.readText(
        a,
        f.path,
        if (info) |i| i.mtime else 0,
        f.extracted,
        f.line + labels.context_after,
    ) orelse it.detail;
    const words = index.content.splitWords(a, ui.query()) catch return;
    // The theme's accent behind matches, its text colour on top.
    const hl_open = a.print("<span background=\"{s}\" bgalpha=\"40%\" foreground=\"{s}\">", .{
        std.mem.sliceTo(&ui.hl_bg, 0),
        std.mem.sliceTo(&ui.hl_fg, 0),
    }) catch return;
    c.gtk_label_set_markup(
        @ptrCast(ui.detail_text),
        labels.contextMarkup(a, text, f.line, words, hl_open).ptr,
    );

    const ctype = c.g_content_type_guess(f.path, null, 0, null);
    defer if (ctype) |t| c.g_free(t);
    setMeta(ui, .{
        labels.kindLabel(a, f.path, false, ctype),
        it.fact,
        if (info) |i| labels.formatWhen(a, i.mtime) else "—",
        it.where,
    });
}

/// The image the preview shows or is loading. Decoding happened on the UI
/// thread for every keystroke that kept an image as the top hit (a 24 MP
/// photo: ~100 ms each); now on a worker (`pictures.requestPicture`: within
/// `picture_limits`, one at a time, a request the selection has left
/// behind dropped before it is decoded), and not again for the same file.
var image_path: [4096]u8 = undefined;
var image_len: usize = 0;
var image_mtime: i64 = 0;

/// The preview's size: sharp on a HiDPI screen, and a 24 MP photo kept as
/// 16 MB instead of 96.
const preview_px = 2048;

fn showImage(ui: *Ui, path: [:0]const u8, mtime: i64) void {
    if (image_len == path.len and image_mtime == mtime and std.mem.eql(
        u8,
        image_path[0..image_len],
        path,
    )) return;
    forgetImage(ui);
    if (path.len > image_path.len) return;
    @memcpy(image_path[0..path.len], path);
    image_len = path.len;
    image_mtime = mtime;
    pictures.requestPicture(
        path,
        preview_px,
        preview_px,
        &pictures.preview_lane,
        true,
        &onImageLoaded,
        ui,
    );
}

/// No image: what is on its way is dropped (before it is decoded, if it
/// has not started).
fn forgetImage(ui: *Ui) void {
    pictures.preview_lane.forget();
    image_len = 0;
    c.gtk_picture_set_paintable(ui.detail_picture, null);
}

fn onImageLoaded(ctx: ?*anyopaque, pb: ?*c.GdkPixbuf, current: bool) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    if (!current) return;
    const p = pb orelse return;
    const tex = c.gdk_texture_new_for_pixbuf(p);
    defer c.g_object_unref(tex);
    c.gtk_picture_set_paintable(ui.detail_picture, tex);
}

pub fn showFileDetail(ui: *Ui, it: *const Item) void {
    const f = it.action.file;
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const ctype = if (f.is_dir) null else c.g_content_type_guess(f.path, null, 0, null);
    defer if (ctype) |t| c.g_free(t);
    const ct: [*:0]const u8 = if (ctype) |t| t else "inode/directory";

    // Only regular files: a FIFO named *.png is no picture (and the decoder
    // checks again on the descriptor it reads).
    const image = (c.g_content_type_is_a(ct, "image/*") != 0 or std.mem.startsWith(
        u8,
        std.mem.span(ct),
        "image/",
    )) and os.isRegular(f.path);
    const info = os.info(f.path);
    c.gtk_widget_set_visible(ui.detail_picture, @intFromBool(image));
    if (image) showImage(ui, f.path, if (info) |i| i.mtime else 0) else forgetImage(ui);

    // Text preview: the head of anything that is valid UTF-8.
    var text: []const u8 = "";
    if (!image and !f.is_dir) {
        const head = os.readHead(f.path, a.alloc(u8, 4096) catch return);
        const valid = core.utf8.validPrefix(head);
        if (valid.len + 4 >= head.len and std.mem.findScalar(
            u8,
            valid,
            0,
        ) == null) text = labels.firstLines(
            valid,
            preview_lines,
        );
    }
    c.gtk_label_set_text(@ptrCast(ui.detail_text), (a.dupeSentinel(u8, text, 0) catch return).ptr);

    setMeta(ui, .{
        labels.kindLabel(a, f.path, f.is_dir, ct),
        if (info) |inf| (if (f.is_dir) "—" else labels.formatSize(a, inf.size)) else "—",
        if (info) |inf| labels.formatWhen(a, inf.mtime) else "—",
        it.subtitle,
    });
}

/// Lines of a file preview. The pane shows ~14; GTK wraps and measures all
/// of the label's text at several widths, and 4 KB (~100 lines) of it cost
/// ~50 ms per frame (measured with `lumen --stats`).
const preview_lines = 40;

/// An extension row: its text or markdown, and up to 4 metadata pairs.
fn showExtDetail(ui: *Ui, it: ?*const Item) void {
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const label: *c.GtkLabel = @ptrCast(ui.detail_text);
    const markup = if (it) |i| i.markup else false;
    if (markup) {
        // Whole: cutting markup could leave a tag open.
        c.gtk_label_set_markup(label, (a.dupeSentinel(u8, it.?.detail, 0) catch return).ptr);
        c.gtk_widget_add_css_class(ui.detail_text, "markdown");
    } else {
        const text = if (it) |i| i.detail[0..@min(i.detail.len, 20_000)] else "";
        c.gtk_label_set_text(
            label,
            (a.dupeSentinel(u8, core.utf8.validPrefix(text), 0) catch return).ptr,
        );
        c.gtk_widget_remove_css_class(ui.detail_text, "markdown");
    }
    const meta = if (it) |i| i.meta else &.{};
    c.gtk_widget_set_visible(ui.detail_meta, @intFromBool(meta.len > 0));
    for (ui.meta_lines, ui.meta_keys, ui.meta_values, 0..) |line, k, v, i| {
        c.gtk_widget_set_visible(line, @intFromBool(i < meta.len));
        if (i >= meta.len) continue;
        c.gtk_label_set_text(@ptrCast(k), meta[i].label.ptr);
        c.gtk_label_set_text(@ptrCast(v), meta[i].value.ptr);
    }
}

/// The four values beside the keys the view set (Kind, Size, Modified,
/// Where for files; Content type, Characters, Words, Copied for copies).
fn setMeta(ui: *Ui, values: [4][:0]const u8) void {
    for (ui.meta_values, values) |w, v| c.gtk_label_set_text(@ptrCast(w), v.ptr);
}

pub fn showDetail(ui: *Ui, it: ?*const Item) void {
    if (ui.view == .files or ui.view == .contents) {
        if (it) |i| if (i.action == .file) {
            return if (ui.view == .contents) showContentDetail(ui, i) else showFileDetail(ui, i);
        };
        c.gtk_widget_set_visible(ui.detail_picture, 0);
        c.gtk_label_set_text(@ptrCast(ui.detail_text), "");
        setMeta(ui, @splat(""));
        return;
    }
    if (ui.view == .ext) return showExtDetail(ui, it);
    if (ui.view != .clipboard) return;
    const i = it orelse {
        c.gtk_label_set_text(@ptrCast(ui.detail_text), "");
        setMeta(ui, @splat(""));
        return;
    };
    var arena: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The row holds the head of the entry; the counts are of all of it.
    const content = if (i.action == .clip)
        (ui.db.clipContent(a, i.action.clip) catch null) orelse i.detail
    else
        i.detail;
    const text = content[0..@min(content.len, 20_000)];
    c.gtk_label_set_text(
        @ptrCast(ui.detail_text),
        (a.dupeSentinel(u8, core.utf8.validPrefix(text), 0) catch return).ptr,
    );
    const chars = std.unicode.utf8CountCodepoints(content) catch content.len;
    var words: usize = 0;
    var tok = std.mem.tokenizeAny(u8, content, " \t\r\n");
    while (tok.next()) |_| words += 1;
    setMeta(ui, .{
        "Text",
        a.printSentinel("{d}", .{chars}, 0) catch "",
        a.printSentinel("{d}", .{words}, 0) catch "",
        labels.formatWhen(a, i.time_s),
    });
}
