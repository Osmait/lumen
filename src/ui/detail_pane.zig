//! The detail pane: clipboard text, file previews, content context.

const std = @import("std");
const core = @import("core");
const c = @import("c");
const gtk = @import("gtk.zig");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const index = @import("index");
const os = @import("os");
const pictures = @import("pictures.zig");
const stats = @import("../stats.zig");
const Ui = @import("Ui.zig");
const widgets = @import("widgets.zig");
const labels = @import("labels.zig");

/// An Information value asks GTK for at most this many characters of
/// width; longer values are ellipsized at the start (a path keeps its end).
const meta_value_width_chars_max = 30;

pub fn buildDetail(ui: *Ui) void {
    ui.detail.box = widgets.vbox(0);
    gtk.addClass(ui.detail.box, "detail");
    gtk.setHexpand(ui.detail.box, true);

    // Image previews (files view).
    ui.detail.picture = gtk.picture();
    c.gtk_picture_set_content_fit(ui.detail.picture, c.GTK_CONTENT_FIT_SCALE_DOWN);
    gtk.setVexpand(ui.detail.picture, true);
    gtk.addClass(ui.detail.picture, "preview");
    gtk.append(ui.detail.box, ui.detail.picture);

    const scroller = gtk.scrolledWindow();
    c.gtk_scrolled_window_set_policy(
        scroller,
        c.GTK_POLICY_NEVER,
        c.GTK_POLICY_AUTOMATIC,
    );
    gtk.setVexpand(scroller, true);
    ui.detail.text = widgets.label("", "detail-text");
    c.gtk_label_set_wrap(ui.detail.text, 1);
    c.gtk_label_set_wrap_mode(ui.detail.text, c.PANGO_WRAP_WORD_CHAR);
    // A wrapping GtkLabel asks for its unwrapped width unless told otherwise;
    // this lets the list keep its share of the row.
    c.gtk_label_set_max_width_chars(ui.detail.text, 1);
    gtk.setHexpand(ui.detail.text, true);
    c.gtk_label_set_yalign(ui.detail.text, 0);
    gtk.setValign(ui.detail.text, c.GTK_ALIGN_START);
    c.gtk_scrolled_window_set_child(scroller, gtk.widget(ui.detail.text));
    gtk.append(ui.detail.box, scroller);

    const meta = widgets.vbox(4);
    ui.detail.meta = meta;
    gtk.addClass(meta, "meta");
    gtk.append(meta, widgets.label("Information", "meta-header"));
    const keys = [_][:0]const u8{ "Content type", "Characters", "Words", "Copied" };
    comptime std.debug.assert(keys.len == item_mod.meta_max);
    for (keys, 0..) |key, i| {
        const line = widgets.hbox(12);
        ui.detail.meta_lines[i] = line;
        ui.detail.meta_keys[i] = widgets.label(key, "meta-key");
        gtk.append(line, ui.detail.meta_keys[i]);
        const spacer = widgets.hbox(0);
        gtk.setHexpand(spacer, true);
        gtk.append(line, spacer);
        ui.detail.meta_values[i] = widgets.label("", "meta-value");
        c.gtk_label_set_ellipsize(ui.detail.meta_values[i], c.PANGO_ELLIPSIZE_START);
        // The layer surface grows to its content's natural width; a long path
        // here would widen the whole window.
        c.gtk_label_set_max_width_chars(ui.detail.meta_values[i], meta_value_width_chars_max);
        gtk.append(line, ui.detail.meta_values[i]);
        gtk.append(meta, line);
    }
    gtk.append(ui.detail.box, meta);
    gtk.setVisible(ui.detail.box, false);
}

/// The lines around the match, words highlighted.
pub fn showContentDetail(ui: *Ui, item: *const Item) void {
    const file = item.action.file;
    var arena_instance: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    gtk.setVisible(ui.detail.picture, false);

    const info = os.info(file.path);
    const service = ui.contents orelse return;
    const text = service.readText(
        arena,
        file.path,
        if (info) |i| i.mtime else 0,
        file.extracted,
        file.line + labels.context_after,
    ) orelse item.detail;
    const words = index.content.splitWords(arena, ui.query()) catch return;
    // The theme's accent behind matches, its text colour on top.
    const hl_open = arena.print("<span background=\"{s}\" bgalpha=\"40%\" foreground=\"{s}\">", .{
        std.mem.sliceTo(&ui.appearance.highlight_bg, 0),
        std.mem.sliceTo(&ui.appearance.highlight_fg, 0),
    }) catch return;
    c.gtk_label_set_markup(
        ui.detail.text,
        labels.contextMarkup(arena, text, file.line, words, hl_open).ptr,
    );

    const ctype = c.g_content_type_guess(file.path, null, 0, null);
    defer if (ctype) |type_name| c.g_free(type_name);
    setMeta(ui, .{
        labels.kindLabel(arena, file.path, false, ctype),
        item.fact,
        if (info) |i| labels.formatWhen(arena, i.mtime) else "—",
        item.where,
    });
}

/// The preview's size: sharp on a HiDPI screen, and a 24 MP photo kept as
/// 16 MB instead of 96.
const preview_px = 2048;

/// Shows the image at `path`. Decoding happened on the UI thread for every
/// keystroke that kept an image as the top hit (a 24 MP photo: ~100 ms
/// each); now on a worker (`pictures.requestPicture`: within
/// `picture_limits`, one at a time, a request the selection has left
/// behind dropped before it is decoded), and not again for the same file.
fn showImage(ui: *Ui, path: [:0]const u8, mtime: i64) void {
    const detail = &ui.detail;
    const shown_path = detail.image_path[0..detail.image_path_len];
    const same_image = detail.image_mtime == mtime and std.mem.eql(u8, shown_path, path);
    if (same_image) return;
    forgetImage(ui);
    if (path.len > detail.image_path.len) return;
    @memcpy(detail.image_path[0..path.len], path);
    detail.image_path_len = path.len;
    detail.image_mtime = mtime;
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
    ui.detail.image_path_len = 0;
    c.gtk_picture_set_paintable(gtk.widget(ui.detail.picture), null);
}

fn onImageLoaded(ctx: ?*anyopaque, pb: ?*c.GdkPixbuf, current: bool) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    if (!current) return;
    const pixbuf = pb orelse return;
    const tex = c.gdk_texture_new_for_pixbuf(pixbuf);
    defer c.g_object_unref(tex);
    c.gtk_picture_set_paintable(gtk.widget(ui.detail.picture), tex);
}

pub fn showFileDetail(ui: *Ui, item: *const Item) void {
    const file = item.action.file;
    var arena_instance: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const ctype = if (file.is_dir) null else c.g_content_type_guess(file.path, null, 0, null);
    defer if (ctype) |type_name| c.g_free(type_name);
    const content_type: [*:0]const u8 = if (ctype) |type_name| type_name else "inode/directory";

    // Only regular files: a FIFO named *.png is no picture (and the decoder
    // checks again on the descriptor it reads).
    const image_type = c.g_content_type_is_a(content_type, "image/*") != 0 or
        std.mem.startsWith(u8, std.mem.span(content_type), "image/");
    const image = image_type and os.isRegular(file.path);
    const info = os.info(file.path);
    gtk.setVisible(ui.detail.picture, image);
    if (image) showImage(ui, file.path, if (info) |i| i.mtime else 0) else forgetImage(ui);

    // Text preview: the head of anything that is valid UTF-8.
    var text: []const u8 = "";
    if (!image and !file.is_dir) {
        const head = os.readHead(file.path, arena.alloc(u8, 4096) catch return);
        const valid = core.utf8.validPrefix(head);
        // Up to 4 bytes may be a character cut at the end of the head; any
        // more invalid bytes, or a NUL, and it is not text.
        const text_like = valid.len + 4 >= head.len and std.mem.findScalar(u8, valid, 0) == null;
        if (text_like) text = labels.firstLines(valid, preview_lines);
    }
    c.gtk_label_set_text(
        ui.detail.text,
        (arena.dupeSentinel(u8, text, 0) catch return).ptr,
    );

    setMeta(ui, .{
        labels.kindLabel(arena, file.path, file.is_dir, content_type),
        if (info) |inf| (if (file.is_dir) "—" else labels.formatSize(arena, inf.size)) else "—",
        if (info) |inf| labels.formatWhen(arena, inf.mtime) else "—",
        item.subtitle,
    });
}

/// Lines of a file preview. The pane shows ~14; GTK wraps and measures all
/// of the label's text at several widths, and 4 KB (~100 lines) of it cost
/// ~50 ms per frame (measured with `lumen --stats`).
const preview_lines = 40;

/// An extension row: its text or markdown, and up to 4 metadata pairs.
fn showExtDetail(ui: *Ui, item: ?*const Item) void {
    var arena_instance: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const label: *c.GtkLabel = ui.detail.text;
    const markup = if (item) |i| i.markup else false;
    if (markup) {
        // Markup is shown whole: cutting it could leave a tag open.
        c.gtk_label_set_markup(label, (arena.dupeSentinel(u8, item.?.detail, 0) catch return).ptr);
        gtk.addClass(ui.detail.text, "markdown");
    } else {
        const text = if (item) |i| i.detail[0..@min(i.detail.len, 20_000)] else "";
        c.gtk_label_set_text(
            label,
            (arena.dupeSentinel(u8, core.utf8.validPrefix(text), 0) catch return).ptr,
        );
        c.gtk_widget_remove_css_class(gtk.widget(ui.detail.text), "markdown");
    }
    const meta = if (item) |i| i.meta else &.{};
    gtk.setVisible(ui.detail.meta, meta.len > 0);
    for (ui.detail.meta_lines, ui.detail.meta_keys, ui.detail.meta_values, 0..) |line, k, v, i| {
        gtk.setVisible(line, i < meta.len);
        if (i >= meta.len) continue;
        c.gtk_label_set_text(k, meta[i].label.ptr);
        c.gtk_label_set_text(v, meta[i].value.ptr);
    }
}

/// The four values beside the keys the view set (Kind, Size, Modified,
/// Where for files; Content type, Characters, Words, Copied for copies).
fn setMeta(ui: *Ui, values: [4][:0]const u8) void {
    for (ui.detail.meta_values, values) |value_label, value| {
        c.gtk_label_set_text(value_label, value.ptr);
    }
}

pub fn showDetail(ui: *Ui, item: ?*const Item) void {
    if (ui.view == .files or ui.view == .contents) {
        if (item) |i| if (i.action == .file) {
            return if (ui.view == .contents) showContentDetail(ui, i) else showFileDetail(ui, i);
        };
        gtk.setVisible(ui.detail.picture, false);
        c.gtk_label_set_text(ui.detail.text, "");
        setMeta(ui, @splat(""));
        return;
    }
    if (ui.view == .ext) return showExtDetail(ui, item);
    if (ui.view != .clipboard) return;
    const i = item orelse {
        c.gtk_label_set_text(ui.detail.text, "");
        setMeta(ui, @splat(""));
        return;
    };
    var arena_instance: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // The row holds the head of the entry; the counts are of all of it.
    const content = if (i.action == .clip)
        (ui.db.clipContent(arena, i.action.clip) catch null) orelse i.detail
    else
        i.detail;
    const text = content[0..@min(content.len, 20_000)];
    c.gtk_label_set_text(
        ui.detail.text,
        (arena.dupeSentinel(u8, core.utf8.validPrefix(text), 0) catch return).ptr,
    );
    const chars = std.unicode.utf8CountCodepoints(content) catch content.len;
    var words: usize = 0;
    var tok = std.mem.tokenizeAny(u8, content, " \t\r\n");
    while (tok.next()) |_| words += 1;
    setMeta(ui, .{
        "Text",
        arena.printSentinel("{d}", .{chars}, 0) catch "",
        arena.printSentinel("{d}", .{words}, 0) catch "",
        labels.formatWhen(arena, i.time_s),
    });
}
