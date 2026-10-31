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

/// Content types (MIME) the detail pane tells apart.
const mime_directory = "inode/directory";
const mime_image_any = "image/*";
const mime_image_prefix = "image/";

/// An Information value asks GTK for at most this many characters of
/// width; longer values are ellipsized at the start (a path keeps its end).
const meta_value_width_chars_max = 30;

/// The selected row's preview, picture and "Information" block.
pub const DetailPane = struct {
    box: *c.GtkBox = undefined,
    text: *c.GtkLabel = undefined,
    picture: *c.GtkPicture = undefined,
    /// The "Information" block under the preview (hidden for extensions).
    meta: *c.GtkBox = undefined,
    /// One line per label and value pair; extensions show as many as they
    /// give.
    meta_lines: [item_mod.metadata_max]*c.GtkBox = undefined,
    meta_keys: [item_mod.metadata_max]*c.GtkLabel = undefined,
    meta_values: [item_mod.metadata_max]*c.GtkLabel = undefined,
    /// The image the picture shows or is loading (see detail_pane.showImage).
    image_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    image_path_length: usize = 0,
    image_mtime: i64 = 0,
};

pub fn buildDetail(ui: *Ui) void {
    ui.detail.box = widgets.vbox(0);
    gtk.addClass(ui.detail.box, "detail");
    gtk.setHexpand(ui.detail.box, true);

    // The picture shows image previews (files view).
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
    comptime std.debug.assert(keys.len == item_mod.metadata_max);
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
/// The pane's parts for `view`, before a row fills them: the Information
/// block and its labels, and whether the text wraps.
pub fn prepareFor(detail: *DetailPane, view: Ui.View) void {
    gtk.setVisible(detail.meta, view != .ext);
    for (detail.meta_lines) |meta_line| gtk.setVisible(meta_line, true);
    const keys: [4][:0]const u8 = switch (view) {
        .files => .{ "Kind", "Size", "Modified", "Where" },
        .contents => .{ "Kind", "Matches", "Modified", "Where" },
        else => .{ "Content type", "Characters", "Words", "Copied" },
    };
    for (detail.meta_keys, keys) |key_label, key| c.gtk_label_set_text(key_label, key);
    // Code previews do not wrap, they clip long lines like an editor: a
    // wrapping GtkLabel makes GTK lay its text out at several widths per frame
    // (~30 ms measured with `lumen --stats`). Clipboard text is prose: wrap.
    const wrap = view == .clipboard or view == .ext;
    c.gtk_label_set_wrap(detail.text, @intFromBool(wrap));
    c.gtk_label_set_ellipsize(
        detail.text,
        if (wrap) c.PANGO_ELLIPSIZE_NONE else c.PANGO_ELLIPSIZE_END,
    );
    gtk.setVisible(detail.picture, false);
}

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
        if (info) |file_info| file_info.mtime else 0,
        if (file.extracted) .extracted else .plain,
        file.line + labels.context_lines_after,
    ) orelse item.detail;
    const words = index.content.splitWords(arena, ui.query()) catch return;
    // The theme's accent behind matches, its text colour on top.
    const highlight_open = arena.print(
        "<span background=\"{s}\" bgalpha=\"40%\" foreground=\"{s}\">",
        .{
            std.mem.sliceTo(&ui.appearance.highlight_background, 0),
            std.mem.sliceTo(&ui.appearance.highlight_foreground, 0),
        },
    ) catch return;
    c.gtk_label_set_markup(
        ui.detail.text,
        labels.contextMarkup(arena, text, file.line, words, highlight_open).ptr,
    );

    const guessed_type = c.g_content_type_guess(file.path, null, 0, null);
    defer if (guessed_type) |type_name| c.g_free(type_name);
    setMeta(&ui.detail, .{
        labels.kindLabel(arena, file.path, false, guessed_type),
        item.fact,
        if (info) |file_info| labels.formatWhen(arena, file_info.mtime) else no_value,
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
fn showImage(detail: *DetailPane, path: [:0]const u8, mtime: i64) void {
    const shown_path = detail.image_path[0..detail.image_path_length];
    const same_image = detail.image_mtime == mtime and std.mem.eql(u8, shown_path, path);
    if (same_image) return;
    forgetImage(detail);
    if (path.len > detail.image_path.len) return;
    @memcpy(detail.image_path[0..path.len], path);
    detail.image_path_length = path.len;
    detail.image_mtime = mtime;
    pictures.requestPicture(
        path,
        preview_px,
        preview_px,
        &pictures.preview_lane,
        .front,
        &requestPictureCallback,
        detail,
    );
}

/// No image: what is on its way is dropped (before it is decoded, if it
/// has not started).
fn forgetImage(detail: *DetailPane) void {
    pictures.preview_lane.forget();
    detail.image_path_length = 0;
    c.gtk_picture_set_paintable(gtk.widget(detail.picture), null);
}

fn requestPictureCallback(context: ?*anyopaque, decoded: ?*c.GdkPixbuf, current: bool) void {
    const detail: *DetailPane = @ptrCast(@alignCast(context.?));
    if (!current) return;
    const pixbuf = decoded orelse return;
    const texture = c.gdk_texture_new_for_pixbuf(pixbuf);
    defer c.g_object_unref(texture);
    c.gtk_picture_set_paintable(gtk.widget(detail.picture), texture);
}

pub fn showFileDetail(ui: *Ui, item: *const Item) void {
    const file = item.action.file;
    var arena_instance: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const guessed_type = if (file.is_dir)
        null
    else
        c.g_content_type_guess(file.path, null, 0, null);
    defer if (guessed_type) |type_name| c.g_free(type_name);
    const content_type: [*:0]const u8 = guessed_type orelse mime_directory;

    // Only regular files: a FIFO named *.png is no picture (and the decoder
    // checks again on the descriptor it reads).
    const image_type = c.g_content_type_is_a(content_type, mime_image_any) != 0 or
        std.mem.startsWith(u8, std.mem.span(content_type), mime_image_prefix);
    const image = image_type and os.isRegular(file.path);
    const info = os.info(file.path);
    gtk.setVisible(ui.detail.picture, image);
    if (image) {
        showImage(&ui.detail, file.path, if (info) |file_info| file_info.mtime else 0);
    } else {
        forgetImage(&ui.detail);
    }

    // Text preview: the head of anything that is valid UTF-8.
    var text: []const u8 = "";
    if (!image and !file.is_dir) {
        const head = os.readHead(file.path, arena.alloc(u8, preview_head_bytes) catch return);
        const valid = core.utf8.validPrefix(head);
        // A character cut at the end of the head leaves bytes that are not
        // valid alone, at most one sequence's worth; any more invalid bytes,
        // or a NUL, and it is not text.
        const utf8_sequence_bytes_max = 4;
        const text_like = valid.len + utf8_sequence_bytes_max >= head.len and
            std.mem.findScalar(u8, valid, 0) == null;
        if (text_like) text = labels.firstLines(valid, preview_lines);
    }
    c.gtk_label_set_text(
        ui.detail.text,
        (arena.dupeSentinel(u8, text, 0) catch return).ptr,
    );

    const size_text = if (info) |file_info|
        (if (file.is_dir) no_value else labels.formatSize(arena, file_info.size))
    else
        no_value;
    setMeta(&ui.detail, .{
        labels.kindLabel(arena, file.path, file.is_dir, content_type),
        size_text,
        if (info) |file_info| labels.formatWhen(arena, file_info.mtime) else no_value,
        item.subtitle,
    });
}

/// An Information value that does not apply or could not be read.
const no_value = "—";
/// How much of a file the preview reads: enough for `preview_lines`.
const preview_head_bytes = 4096;
/// Plain detail text (a clipboard entry, an extension row) is cut to this
/// much: GTK lays the whole label out at several widths per frame.
const detail_text_bytes_max = 20_000;
/// The detail text's class while it shows an extension's markdown.
const markdown_class = "markdown";

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
    const markup = if (item) |shown| shown.markup else false;
    if (markup) {
        // Markup is shown whole: cutting it could leave a tag open.
        c.gtk_label_set_markup(label, (arena.dupeSentinel(u8, item.?.detail, 0) catch return).ptr);
        gtk.addClass(ui.detail.text, markdown_class);
    } else {
        const detail = if (item) |shown| shown.detail else "";
        const text = detail[0..@min(detail.len, detail_text_bytes_max)];
        c.gtk_label_set_text(
            label,
            (arena.dupeSentinel(u8, core.utf8.validPrefix(text), 0) catch return).ptr,
        );
        gtk.setClass(ui.detail.text, markdown_class, false);
    }
    const meta = if (item) |shown| shown.meta else &.{};
    gtk.setVisible(ui.detail.meta, meta.len > 0);
    const detail = &ui.detail;
    for (detail.meta_lines, detail.meta_keys, detail.meta_values, 0..) |line, key, value, i| {
        gtk.setVisible(line, i < meta.len);
        if (i >= meta.len) continue;
        c.gtk_label_set_text(key, meta[i].label.ptr);
        c.gtk_label_set_text(value, meta[i].value.ptr);
    }
}

/// The four values beside the keys the view set (Kind, Size, Modified,
/// Where for files; Content type, Characters, Words, Copied for copies).
fn setMeta(detail: *DetailPane, values: [item_mod.metadata_max][:0]const u8) void {
    for (detail.meta_values, values) |value_label, value| {
        c.gtk_label_set_text(value_label, value.ptr);
    }
}

/// What the detail pane shows for the selected `item` in the current view.
pub fn showDetail(ui: *Ui, item: ?*const Item) void {
    if (ui.view == .files or ui.view == .contents) {
        if (item) |shown| if (shown.action == .file) {
            if (ui.view == .contents) return showContentDetail(ui, shown);
            return showFileDetail(ui, shown);
        };
        gtk.setVisible(ui.detail.picture, false);
        c.gtk_label_set_text(ui.detail.text, "");
        setMeta(&ui.detail, @splat(""));
        return;
    }
    if (ui.view == .ext) return showExtDetail(ui, item);
    if (ui.view != .clipboard) return;
    const shown = item orelse {
        c.gtk_label_set_text(ui.detail.text, "");
        setMeta(&ui.detail, @splat(""));
        return;
    };
    var arena_instance: std.heap.ArenaAllocator = .init(ui.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    // The row holds the head of the entry; the counts are of all of it.
    const content = if (shown.action == .clip)
        (ui.db.clipContent(arena, shown.action.clip) catch null) orelse shown.detail
    else
        shown.detail;
    const text = content[0..@min(content.len, detail_text_bytes_max)];
    c.gtk_label_set_text(
        ui.detail.text,
        (arena.dupeSentinel(u8, core.utf8.validPrefix(text), 0) catch return).ptr,
    );
    const character_count = std.unicode.utf8CountCodepoints(content) catch content.len;
    var word_count: usize = 0;
    var words = std.mem.tokenizeAny(u8, content, " \t\r\n");
    while (words.next()) |_| word_count += 1;
    setMeta(&ui.detail, .{
        "Text",
        arena.printSentinel("{d}", .{character_count}, 0) catch "",
        arena.printSentinel("{d}", .{word_count}, 0) catch "",
        labels.formatWhen(arena, shown.time_s),
    });
}
