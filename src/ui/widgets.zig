//! The GTK pieces rows are made of: boxes, labels, icons, result rows.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const logos = @import("logos.zig");
const themes = @import("themes.zig");
const labels = @import("labels.zig");
const os = @import("os");
const pictures = @import("pictures.zig");

/// A small picture of a theme: its background, two lines of text and an
/// accent dot. Each set of colours is drawn once and cached, init.lua's
/// themes included, until the cache is full.
pub fn swatchTexture(bg: u24, fg: u24, accent: u24) ?*c.GdkTexture {
    const Cache = struct {
        var ring: TextureRing(64, u72) = .{};
    };
    const colors = (@as(u72, bg) << 48) | (@as(u72, fg) << 24) | accent;
    if (Cache.ring.get(colors)) |t| return t;
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
    Cache.ring.put(colors, tex);
    return tex;
}

/// Textures by key, the oldest replaced once full (widgets showing one keep
/// their own reference). A key can map to null: known not to load. Main
/// thread.
fn TextureRing(comptime n: usize, comptime Key: type) type {
    return struct {
        keys: [n]Key = undefined,
        textures: [n]?*c.GdkTexture = @splat(null),
        len: usize = 0,
        /// Next slot to reuse once full.
        next: usize = 0,

        /// Null: not in the ring; null inside: known not to load.
        fn get(r: *const @This(), key: Key) ??*c.GdkTexture {
            for (r.keys[0..r.len], r.textures[0..r.len]) |k, t| if (k == key) return t;
            return null;
        }

        /// Takes `tex`'s reference.
        fn put(r: *@This(), key: Key, tex: ?*c.GdkTexture) void {
            const slot = if (r.len < n) r.len else r.next;
            if (r.len < n) {
                r.len += 1;
            } else r.next = (r.next + 1) % n;
            if (r.textures[slot]) |old| c.g_object_unref(old);
            r.keys[slot] = key;
            r.textures[slot] = tex;
        }
    };
}

/// A key for what `path` holds now, decoded at `w`×`h`: an edited file gets
/// a new one (mtime to the nanosecond, size, inode). Null when it is gone.
fn fileKey(path: [*:0]const u8, width_px: c_int, height_px: c_int) ?u64 {
    const st = os.Stamp.of(path);
    if (st.eql(.none)) return null;
    var hash: std.hash.Wyhash = .init(0);
    hash.update(std.mem.span(path));
    const parts = [_]i64{ st.sec, st.nsec, @bitCast(st.size), @bitCast(
        st.ino,
    ), width_px, height_px };
    hash.update(std.mem.asBytes(&parts));
    return hash.final();
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
/// kept until the file changes: the same few icons show again and again.
/// Decoded on the UI thread, so within the small `pictures.icon_limits`.
fn fileTexture(path: [:0]const u8, size: c_int) ?*c.GdkTexture {
    const Cache = struct {
        var ring: TextureRing(128, u64) = .{};
    };
    const key = fileKey(path.ptr, size * 2, size * 2) orelse return null;
    if (Cache.ring.get(key)) |texture| return texture;
    const pb = pictures.decodeImage(path.ptr, size * 2, size * 2, pictures.icon_limits);
    defer if (pb) |pixbuf| c.g_object_unref(pixbuf);
    const tex = if (pb) |pixbuf| c.gdk_texture_new_for_pixbuf(pixbuf) else null;
    Cache.ring.put(key, tex);
    return tex;
}

/// Icon, title over subtitle, accessory, and the hidden hint that shows
/// the primary action while the row is selected.
pub const RowParts = struct { hint: ?*c.GtkWidget = null, accessory: ?*c.GtkWidget = null };

pub fn itemRow(item: Item, parts: *RowParts) *c.GtkWidget {
    const row = c.gtk_list_box_row_new();
    const box = hbox(12);
    // The parts in lumen.layout's order; those left out are not made.
    for (row_parts.slice()) |part| switch (part) {
        .icon => if (show.icons) c.gtk_box_append(@ptrCast(box), iconWidget(item.icon, icon_px)),
        .text => {
            const text = if (rows_inline) hbox(10) else vbox(1);
            c.gtk_widget_set_valign(text, c.GTK_ALIGN_CENTER);
            c.gtk_widget_set_hexpand(text, 1);
            const title = shortLabel(item.title, "title");
            c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_END);
            c.gtk_label_set_max_width_chars(@ptrCast(title), 60);
            c.gtk_box_append(@ptrCast(text), title);
            if (item.subtitle.len > 0 and show.subtitles) {
                const sub = shortLabel(item.subtitle, "subtitle");
                c.gtk_label_set_ellipsize(@ptrCast(sub), c.PANGO_ELLIPSIZE_END);
                c.gtk_label_set_max_width_chars(@ptrCast(sub), 60);
                c.gtk_box_append(@ptrCast(text), sub);
            }
            c.gtk_box_append(@ptrCast(box), text);
        },
        .accessory => if (item.accessory.len > 0 and show.accessories) {
            parts.accessory = shortLabel(item.accessory, "accessory");
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
pub fn gridCell(item: Item, width_px: c_int) *c.GtkWidget {
    const box = vbox(6);
    c.gtk_widget_add_css_class(box, "cell");
    const pic_h = @divTrunc(width_px * 5, 8);
    const key = if (item.image.len > 0) fileKey(item.image.ptr, width_px, pic_h) else null;
    const cached = if (key) |cache_key| GridPictures.ring.get(cache_key) else null;
    const top = if (cached) |cached_texture| (if (cached_texture) |tex| cellPicture(
        tex,
        pic_h,
    ) else null) else null;
    const decode = key != null and cached == null;
    const shown = top orelse blk: {
        const icon = iconWidget(item.icon, @min(@divTrunc(width_px, 2), 56));
        c.gtk_widget_set_halign(icon, c.GTK_ALIGN_CENTER);
        // As tall as the picture on its way, so the cell keeps its size
        // when it comes.
        c.gtk_widget_set_size_request(icon, -1, if (decode) pic_h else @min(pic_h, 64));
        break :blk icon;
    };
    c.gtk_box_append(@ptrCast(box), shown);
    const title = shortLabel(item.title, "cell-title");
    c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_xalign(@ptrCast(title), 0.5);
    c.gtk_label_set_max_width_chars(@ptrCast(title), 1);
    c.gtk_widget_set_hexpand(title, 1);
    c.gtk_box_append(@ptrCast(box), title);
    c.gtk_widget_set_size_request(box, width_px, -1);
    if (decode) GridPictures.request(item.image, width_px, pic_h, key.?, box, shown);
    return box;
}

fn cellPicture(tex: *c.GdkTexture, height_px: c_int) *c.GtkWidget {
    const pic = c.gtk_picture_new_for_paintable(tex);
    c.gtk_picture_set_content_fit(@ptrCast(pic), c.GTK_CONTENT_FIT_COVER);
    c.gtk_widget_set_size_request(pic, -1, height_px);
    c.gtk_widget_set_overflow(pic, c.GTK_OVERFLOW_HIDDEN);
    return pic;
}

/// Grid pictures. Every cell decoded its image on the UI thread, uncached,
/// each time the grid was built (every keystroke): a 20000×20000 PNG cost
/// 2 s and 1.2 GB per key. Now a cell shows its icon until its picture,
/// decoded on a worker (`pictures.requestPicture`), replaces it; they are kept
/// for the next build. A new build drops what the last one asked for and
/// was not decoded yet.
const GridPictures = struct {
    var ring: TextureRing(128, u64) = .{};

    /// A cell waiting for its picture; its widgets are referenced until then.
    const Wait = struct { key: u64, h: c_int, box: *c.GtkWidget, icon: *c.GtkWidget };

    fn request(
        path: []const u8,
        w: c_int,
        h: c_int,
        key: u64,
        box: *c.GtkWidget,
        icon: *c.GtkWidget,
    ) void {
        const wait = std.heap.c_allocator.create(Wait) catch return;
        wait.* = .{
            .key = key,
            .h = h,
            .box = @ptrCast(c.g_object_ref(box)),
            .icon = @ptrCast(c.g_object_ref(icon)),
        };
        pictures.requestPicture(path, w, h, &pictures.grid_lane, false, &done, wait);
    }

    fn done(ctx: ?*anyopaque, pb: ?*c.GdkPixbuf, current: bool) void {
        const wait: *Wait = @ptrCast(@alignCast(ctx.?));
        defer {
            c.g_object_unref(wait.box);
            c.g_object_unref(wait.icon);
            std.heap.c_allocator.destroy(wait);
        }
        // Dropped for a newer build before it was decoded: nothing learnt.
        if (pb == null and !current) return;
        const tex = if (pb) |pixbuf| c.gdk_texture_new_for_pixbuf(pixbuf) else null;
        ring.put(wait.key, tex);
        // The cell may be gone (another keystroke): the new build's cell
        // for the same picture finds it in the ring.
        const texture = tex orelse return;
        if (c.gtk_widget_get_parent(wait.icon) != wait.box) return;
        c.gtk_box_remove(@ptrCast(wait.box), wait.icon);
        c.gtk_box_prepend(@ptrCast(wait.box), cellPicture(texture, wait.h));
    }
};

/// The grid is being built again: what its last build asked for and is
/// not decoded yet is not wanted any more.
pub fn forgetGridPictures() void {
    pictures.grid_lane.forget();
}

pub fn calcRow(item: Item) *c.GtkWidget {
    const row = c.gtk_list_box_row_new();
    c.gtk_widget_add_css_class(row, "calc");
    const box = hbox(0);
    c.gtk_box_set_homogeneous(@ptrCast(box), 1);

    var buf: [80:0]u8 = undefined;
    const value = std.fmt.parseFloat(f64, item.detail) catch 0;
    const shown = core.calc.formatDisplay(&buf, value);
    buf[shown.len] = 0;

    const left_tag: [:0]const u8 = if (item.subtitle.len > 0) item.subtitle else "Expression";
    const right_tag: [:0]const u8 = if (item.accessory.len > 0) item.accessory else "Answer";
    c.gtk_box_append(@ptrCast(box), calcSide(item.title, left_tag));
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
    const value_label = label(value, "calc-value");
    c.gtk_label_set_xalign(@ptrCast(value_label), 0.5);
    c.gtk_label_set_ellipsize(@ptrCast(value_label), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(side), value_label);
    const tag_label = label(tag, "calc-label");
    c.gtk_widget_set_halign(tag_label, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(side), tag_label);
    return side;
}

pub fn iconWidget(icon: item_mod.Icon, size: c_int) *c.GtkWidget {
    switch (icon) {
        .logo => |logo| {
            const texture = logos.texture(logo.name) orelse return iconWidget(.none, size);
            const img = c.gtk_image_new_from_paintable(texture);
            c.gtk_image_set_pixel_size(@ptrCast(img), if (logo.on_light) size - 6 else size);
            c.gtk_widget_add_css_class(img, if (logo.on_light) "logo-plate" else "logo");
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .gicon => |gicon| {
            const img = c.gtk_image_new_from_gicon(gicon);
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_add_css_class(img, "app-icon");
            return img;
        },
        .tile => |tile| {
            if (renamed.get(tile.name)) |path| return iconWidget(.{ .file = path }, size);
            const img = c.gtk_image_new_from_icon_name(tile.name);
            c.gtk_image_set_pixel_size(@ptrCast(img), @divTrunc(size, 2) + 2);
            c.gtk_widget_add_css_class(img, "tile");
            var cls: [24:0]u8 = undefined;
            const name = std.mem.printSentinel(
                &cls,
                "tile-{t}",
                .{tile.color},
                0,
            ) catch "tile-gray";
            c.gtk_widget_add_css_class(img, name.ptr);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .emoji => |emoji| return label(emoji, "emoji"),
        .named => |name| {
            if (renamed.get(name)) |path| return iconWidget(.{ .file = path }, size);
            const img = c.gtk_image_new_from_icon_name(name);
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_add_css_class(img, "app-icon");
            return img;
        },
        .swatch => |sw| {
            const texture = swatchTexture(sw.bg, sw.fg, sw.accent) orelse return iconWidget(
                .none,
                size,
            );
            const img = c.gtk_image_new_from_paintable(@ptrCast(texture));
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .badge => |badge| {
            const badge_label = label(badge.text, "badge");
            c.gtk_label_set_xalign(@ptrCast(badge_label), 0.5);
            var cls: [24:0]u8 = undefined;
            const name = std.mem.printSentinel(
                &cls,
                "badge-{t}",
                .{badge.color},
                0,
            ) catch "badge-gray";
            c.gtk_widget_add_css_class(badge_label, name.ptr);
            // Longer extensions get a smaller font so the tile keeps its size.
            if (badge.text.len >= 4) c.gtk_widget_add_css_class(badge_label, "badge-long");
            c.gtk_widget_set_valign(badge_label, c.GTK_ALIGN_CENTER);
            return badge_label;
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
    const label_widget = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(label_widget), 0);
    if (css) |cls| c.gtk_widget_add_css_class(label_widget, cls);
    return label_widget;
}

/// Bytes of a row's title, subtitle or accessory given to its label. A row
/// shows about 60 characters, but Pango lays out and measures all of the
/// text, several times per frame: a 1 MB line from `lumen --dmenu` took
/// 324 ms each time. The item keeps all of it (dmenu prints the whole line).
pub const row_text_bytes_max = 512;

/// A label for row text, cut to `row_text_bytes_max` bytes on a character boundary.
fn shortLabel(text: [:0]const u8, css: ?[*:0]const u8) *c.GtkWidget {
    if (text.len <= row_text_bytes_max) return label(text, css);
    var buf: [row_text_bytes_max + 1]u8 = undefined;
    const length = core.utf8.floorBoundary(text, row_text_bytes_max);
    @memcpy(buf[0..length], text[0..length]);
    buf[length] = 0;
    return label(buf[0..length :0], css);
}

test {
    _ = @import("pictures.zig");
}
