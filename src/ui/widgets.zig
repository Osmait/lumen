//! The GTK pieces rows are made of: boxes, labels, icons, result rows.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const logos = @import("logos.zig");
const themes = @import("themes.zig");
const labels = @import("labels.zig");
const index = @import("index");

/// A small picture of a theme: its background, two lines of text and an
/// accent dot. Made once per set of colours and kept (themes from init.lua
/// included, up to the cache's size).
pub fn swatchTexture(bg: u24, fg: u24, accent: u24) ?*c.GdkTexture {
    const Cache = struct {
        var keys: [64]u72 = @splat(0);
        var textures: [64]?*c.GdkTexture = @splat(null);
        var len: usize = 0;
        /// Next slot to reuse once full; images keep their own reference.
        var next: usize = 0;
    };
    const colors = (@as(u72, bg) << 48) | (@as(u72, fg) << 24) | accent;
    for (Cache.keys[0..Cache.len], Cache.textures[0..Cache.len]) |ck, t| if (ck == colors) return t;
    const n = 44;
    var px: [n * n * 4]u8 = undefined;
    const r: f32 = 10;
    for (0..n) |y| for (0..n) |x| {
        const fx: f32 = @as(f32, @floatFromInt(x)) + 0.5;
        const fy: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        // Rounded square: distance outside the inner rectangle.
        const dx = @max(@max(r - fx, fx - (n - r)), 0);
        const dy = @max(@max(r - fy, fy - (n - r)), 0);
        const d = @sqrt(dx * dx + dy * dy);
        const inside = std.math.clamp(r - d + 0.5, 0, 1);
        const edge = d > r - 1.5;
        var color = bg;
        if (y >= 12 and y < 16 and x >= 9 and x < 31) color = fg;
        if (y >= 20 and y < 24 and x >= 9 and x < 23) color = fg;
        const cx = fx - 30;
        const cy = fy - 31;
        if (cx * cx + cy * cy <= 36) color = accent;
        const o = (y * n + x) * 4;
        px[o] = @intCast(color >> 16);
        px[o + 1] = @intCast((color >> 8) & 0xff);
        px[o + 2] = @intCast(color & 0xff);
        // A faint outline so dark swatches show on a dark window.
        if (edge) {
            for (0..3) |k| px[o + k] = @intCast((@as(u16, px[o + k]) * 3 + 128) / 4);
        }
        px[o + 3] = @intFromFloat(inside * 255);
    };
    const bytes = c.g_bytes_new(&px, px.len);
    defer c.g_bytes_unref(bytes);
    const tex = c.gdk_memory_texture_new(n, n, c.GDK_MEMORY_R8G8B8A8, bytes, n * 4);
    const slot = if (Cache.len < Cache.keys.len) Cache.len else Cache.next;
    if (Cache.len < Cache.keys.len) Cache.len += 1 else Cache.next = (Cache.next + 1) % Cache.keys.len;
    if (Cache.textures[slot]) |old| c.g_object_unref(old);
    Cache.keys[slot] = colors;
    Cache.textures[slot] = tex;
    return tex;
}

/// Icon size in result rows, from the Density setting (main thread).
pub var icon_px: c_int = 32;
/// Icons replaced by name: ~/.config/lumen/icons/<name>.svg (or .png) is
/// used wherever the icon <name> would be. Name to path; the UI fills it.
pub var renamed: std.StringHashMapUnmanaged([:0]const u8) = .empty;
/// What rows show, from lumen.layout (main thread).
pub var show: @import("../layout.zig").Show = .{};
/// Subtitles after titles on the same line (lumen.layout's rows = "inline").
pub var rows_inline = false;
/// A row's parts in order (lumen.layout's row).
pub var row_parts: @import("../layout.zig").Parts(@import("../layout.zig").RowPart) = .{};

/// An image file as an icon, decoded at twice `size` (sharp on HiDPI) and
/// kept: the same few icons show again and again. Regular files only:
/// decoding blocks, and a FIFO would never answer.
fn fileTexture(path: [:0]const u8, size: c_int) ?*c.GdkTexture {
    const Cache = struct {
        var keys: [128]u64 = @splat(0);
        var textures: [128]?*c.GdkTexture = @splat(null);
        var len: usize = 0;
        var next: usize = 0;
    };
    var h: std.hash.Wyhash = .init(@intCast(size));
    h.update(path);
    const k = h.final();
    for (Cache.keys[0..Cache.len], Cache.textures[0..Cache.len]) |ck, t| if (ck == k) return t;
    if (!index.sys.isRegular(path.ptr)) return null;
    const pb = c.gdk_pixbuf_new_from_file_at_scale(path.ptr, size * 2, size * 2, 1, null) orelse return null;
    defer c.g_object_unref(pb);
    const tex = c.gdk_texture_new_for_pixbuf(pb);
    const slot = if (Cache.len < Cache.keys.len) Cache.len else Cache.next;
    if (Cache.len < Cache.keys.len) Cache.len += 1 else Cache.next = (Cache.next + 1) % Cache.keys.len;
    if (Cache.textures[slot]) |old| c.g_object_unref(old);
    Cache.keys[slot] = k;
    Cache.textures[slot] = tex;
    return tex;
}

/// Icon, title over subtitle, accessory, and the hidden hint that shows
/// the primary action while the row is selected.
pub const RowParts = struct { hint: ?*c.GtkWidget = null, accessory: ?*c.GtkWidget = null };

pub fn itemRow(it: Item, parts: *RowParts) *c.GtkWidget {
    const row = c.gtk_list_box_row_new();
    const box = hbox(12);
    // The parts in lumen.layout's order; those left out are not made.
    for (row_parts.slice()) |part| switch (part) {
        .icon => if (show.icons) c.gtk_box_append(@ptrCast(box), iconWidget(it.icon, icon_px)),
        .text => {
            const text = if (rows_inline) hbox(10) else vbox(1);
            c.gtk_widget_set_valign(text, c.GTK_ALIGN_CENTER);
            c.gtk_widget_set_hexpand(text, 1);
            const title = label(it.title, "title");
            c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_END);
            c.gtk_label_set_max_width_chars(@ptrCast(title), 60);
            c.gtk_box_append(@ptrCast(text), title);
            if (it.subtitle.len > 0 and show.subtitles) {
                const sub = label(it.subtitle, "subtitle");
                c.gtk_label_set_ellipsize(@ptrCast(sub), c.PANGO_ELLIPSIZE_END);
                c.gtk_label_set_max_width_chars(@ptrCast(sub), 60);
                c.gtk_box_append(@ptrCast(text), sub);
            }
            c.gtk_box_append(@ptrCast(box), text);
        },
        .accessory => if (it.accessory.len > 0 and show.accessories) {
            parts.accessory = label(it.accessory, "accessory");
            c.gtk_box_append(@ptrCast(box), parts.accessory.?);
        },
        .hint => {
            parts.hint = label("", "hint");
            c.gtk_widget_set_visible(parts.hint.?, 0);
            c.gtk_box_append(@ptrCast(box), parts.hint.?);
        },
    };
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    return row;
}

/// A grid cell: a picture (an image file, scaled down as it is decoded) or
/// a large icon, and the title under it. `w` is the cell's width.
pub fn gridCell(it: Item, w: c_int) *c.GtkWidget {
    const box = vbox(6);
    c.gtk_widget_add_css_class(box, "cell");
    const pic_h = @divTrunc(w * 5, 8);
    var picture: ?*c.GtkWidget = null;
    // Only regular files: decoding blocks, and a FIFO would never answer.
    if (it.image.len > 0 and index.sys.isRegular(it.image.ptr)) {
        if (c.gdk_pixbuf_new_from_file_at_scale(it.image.ptr, w, pic_h, 1, null)) |pb| {
            defer c.g_object_unref(pb);
            const tex = c.gdk_texture_new_for_pixbuf(pb);
            defer c.g_object_unref(tex);
            const pic = c.gtk_picture_new_for_paintable(tex);
            c.gtk_picture_set_content_fit(@ptrCast(pic), c.GTK_CONTENT_FIT_COVER);
            c.gtk_widget_set_size_request(pic, -1, pic_h);
            c.gtk_widget_set_overflow(pic, c.GTK_OVERFLOW_HIDDEN);
            picture = pic;
        }
    }
    const top = picture orelse blk: {
        const icon = iconWidget(it.icon, @min(@divTrunc(w, 2), 56));
        c.gtk_widget_set_halign(icon, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_size_request(icon, -1, @min(pic_h, 64));
        break :blk icon;
    };
    c.gtk_box_append(@ptrCast(box), top);
    const title = label(it.title, "cell-title");
    c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_xalign(@ptrCast(title), 0.5);
    c.gtk_label_set_max_width_chars(@ptrCast(title), 1);
    c.gtk_widget_set_hexpand(title, 1);
    c.gtk_box_append(@ptrCast(box), title);
    c.gtk_widget_set_size_request(box, w, -1);
    return box;
}

pub fn calcRow(it: Item) *c.GtkWidget {
    const row = c.gtk_list_box_row_new();
    c.gtk_widget_add_css_class(row, "calc");
    const box = hbox(0);
    c.gtk_box_set_homogeneous(@ptrCast(box), 1);

    var buf: [80:0]u8 = undefined;
    const value = std.fmt.parseFloat(f64, it.detail) catch 0;
    const shown = core.calc.formatDisplay(&buf, value);
    buf[shown.len] = 0;

    const left_tag: [:0]const u8 = if (it.subtitle.len > 0) it.subtitle else "Expression";
    const right_tag: [:0]const u8 = if (it.accessory.len > 0) it.accessory else "Answer";
    c.gtk_box_append(@ptrCast(box), calcSide(it.title, left_tag));
    const arrow = label("→", "calc-arrow");
    c.gtk_label_set_xalign(@ptrCast(arrow), 0.5);
    c.gtk_box_append(@ptrCast(box), arrow);
    c.gtk_box_append(@ptrCast(box), calcSide(buf[0..shown.len :0], right_tag));
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    return row;
}

pub fn calcSide(value: [:0]const u8, tag: [:0]const u8) *c.GtkWidget {
    const side = vbox(10);
    c.gtk_widget_set_valign(side, c.GTK_ALIGN_CENTER);
    const v = label(value, "calc-value");
    c.gtk_label_set_xalign(@ptrCast(v), 0.5);
    c.gtk_label_set_ellipsize(@ptrCast(v), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(side), v);
    const t = label(tag, "calc-label");
    c.gtk_widget_set_halign(t, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(side), t);
    return side;
}

pub fn iconWidget(icon: item_mod.Icon, size: c_int) *c.GtkWidget {
    switch (icon) {
        .logo => |l| {
            const t = logos.texture(l.name) orelse return iconWidget(.none, size);
            const img = c.gtk_image_new_from_paintable(t);
            c.gtk_image_set_pixel_size(@ptrCast(img), if (l.on_light) size - 6 else size);
            c.gtk_widget_add_css_class(img, if (l.on_light) "logo-plate" else "logo");
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .gicon => |g| {
            const img = c.gtk_image_new_from_gicon(g);
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_add_css_class(img, "app-icon");
            return img;
        },
        .tile => |t| {
            if (renamed.get(t.name)) |path| return iconWidget(.{ .file = path }, size);
            const img = c.gtk_image_new_from_icon_name(t.name);
            c.gtk_image_set_pixel_size(@ptrCast(img), @divTrunc(size, 2) + 2);
            c.gtk_widget_add_css_class(img, "tile");
            var cls: [24:0]u8 = undefined;
            const name = std.mem.printSentinel(&cls, "tile-{t}", .{t.color}, 0) catch "tile-gray";
            c.gtk_widget_add_css_class(img, name.ptr);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .emoji => |e| return label(e, "emoji"),
        .named => |n| {
            if (renamed.get(n)) |path| return iconWidget(.{ .file = path }, size);
            const img = c.gtk_image_new_from_icon_name(n);
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_add_css_class(img, "app-icon");
            return img;
        },
        .swatch => |sw| {
            const t = swatchTexture(sw.bg, sw.fg, sw.accent) orelse return iconWidget(.none, size);
            const img = c.gtk_image_new_from_paintable(@ptrCast(t));
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .badge => |b| {
            const l = label(b.text, "badge");
            c.gtk_label_set_xalign(@ptrCast(l), 0.5);
            var cls: [24:0]u8 = undefined;
            const name = std.mem.printSentinel(&cls, "badge-{t}", .{b.color}, 0) catch "badge-gray";
            c.gtk_widget_add_css_class(l, name.ptr);
            // Longer extensions get a smaller font so the tile keeps its size.
            if (b.text.len >= 4) c.gtk_widget_add_css_class(l, "badge-long");
            c.gtk_widget_set_valign(l, c.GTK_ALIGN_CENTER);
            return l;
        },
        .file => |path| {
            const tex = fileTexture(path, size) orelse return iconWidget(.none, size);
            const img = c.gtk_image_new_from_paintable(@ptrCast(tex));
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_add_css_class(img, "file-icon");
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .none => {
            const img = c.gtk_image_new_from_icon_name("application-x-executable");
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            return img;
        },
    }
}

// -------------------------------------------------------------- helpers

pub fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = c.g_signal_connect_data(@ptrCast(instance), signal, @ptrCast(handler), data, null, 0);
}

pub fn hbox(spacing: c_int) *c.GtkWidget {
    return c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, spacing);
}

pub fn vbox(spacing: c_int) *c.GtkWidget {
    return c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, spacing);
}

pub fn label(text: [*:0]const u8, css: ?[*:0]const u8) *c.GtkWidget {
    const l = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(l), 0);
    if (css) |cls| c.gtk_widget_add_css_class(l, cls);
    return l;
}
