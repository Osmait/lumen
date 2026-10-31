//! The GTK pieces rows are made of: boxes, labels, icons, result rows.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const logos = @import("logos.zig");
const themes = @import("themes.zig");
const labels = @import("labels.zig");
const os = @import("os");
const pictures = @import("pictures.zig");
const layout_mod = @import("../layout.zig");

/// A small picture of a theme: its background, two lines of text and an
/// accent dot. Each set of colours is drawn once and cached, init.lua's
/// themes included, until the cache is full.
pub fn swatchTexture(background: u24, foreground: u24, accent: u24) ?*c.GdkTexture {
    const Cache = struct {
        var ring: TextureRing(swatch.cache_entries, u72) = .{};
    };
    const colors = (@as(u72, background) << 48) | (@as(u72, foreground) << 24) | accent;
    if (Cache.ring.get(colors)) |texture| return texture;
    const size = swatch.size_px;
    var pixels: [size * size * swatch.bytes_per_pixel]u8 = undefined;
    const radius = swatch.corner_radius_px;
    for (0..size) |y| for (0..size) |x| {
        const center_x: f32 = @as(f32, @floatFromInt(x)) + 0.5;
        const center_y: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        // Rounded square: distance outside the inner rectangle.
        const outside_x = @max(@max(radius - center_x, center_x - (size - radius)), 0);
        const outside_y = @max(@max(radius - center_y, center_y - (size - radius)), 0);
        const distance = @sqrt(outside_x * outside_x + outside_y * outside_y);
        const coverage = std.math.clamp(radius - distance + 0.5, 0, 1);
        const edge = distance > radius - swatch.outline_px;
        var color = background;
        for (swatch.line_tops_px, swatch.line_rights_px) |top, right| {
            const on_line = y >= top and y < top + swatch.line_height_px and
                x >= swatch.line_left_px and x < right;
            if (on_line) color = foreground;
        }
        const dot_x = center_x - swatch.dot_center_x_px;
        const dot_y = center_y - swatch.dot_center_y_px;
        if (dot_x * dot_x + dot_y * dot_y <= swatch.dot_radius_px * swatch.dot_radius_px) {
            color = accent;
        }
        const offset = (y * size + x) * swatch.bytes_per_pixel;
        pixels[offset] = @intCast(color >> 16);
        pixels[offset + 1] = @intCast((color >> 8) & 0xff);
        pixels[offset + 2] = @intCast(color & 0xff);
        // A faint outline so dark swatches show on a dark window: three
        // quarters of the colour and a quarter of mid grey.
        if (edge) {
            for (pixels[offset..][0..3]) |*channel| {
                channel.* = @intCast((@as(u16, channel.*) * 3 + 128) / 4);
            }
        }
        pixels[offset + 3] = @intFromFloat(coverage * 255);
    };
    const bytes = c.g_bytes_new(&pixels, pixels.len);
    defer c.g_bytes_unref(bytes);
    const stride = size * swatch.bytes_per_pixel;
    const texture = c.gdk_memory_texture_new(size, size, c.GDK_MEMORY_R8G8B8A8, bytes, stride);
    Cache.ring.put(colors, texture);
    return texture;
}

/// The theme swatch's drawing, in px of its square: two lines of "text" in
/// the foreground colour and an accent dot on the background.
const swatch = struct {
    const size_px = 44;
    const bytes_per_pixel = 4;
    const corner_radius_px: f32 = 10;
    const outline_px: f32 = 1.5;
    const line_left_px = 9;
    const line_height_px = 4;
    const line_tops_px = [_]usize{ 12, 20 };
    /// Where each line ends: the second is shorter, like a last line.
    const line_rights_px = [_]usize{ 31, 23 };
    const dot_center_x_px: f32 = 30;
    const dot_center_y_px: f32 = 31;
    const dot_radius_px: f32 = 6;
    /// Swatches kept: every built-in theme and a good number of init.lua's.
    const cache_entries = 64;

    comptime {
        std.debug.assert(line_tops_px.len == line_rights_px.len);
        for (line_rights_px) |right| std.debug.assert(right < size_px);
        std.debug.assert(dot_center_x_px + dot_radius_px < size_px);
    }
};

/// CSS classes style.css styles and more than one file sets.
pub const css_class = struct {
    /// A key or key combination shown as a chip ("Ctrl K", "↵").
    pub const keys = "kbd";
    /// A destructive action waiting for its second Enter.
    pub const warn = "warn";
    /// An application's icon (its own shadow and size).
    pub const app_icon = "app-icon";
};

/// Icons decoded from files, and grid pictures, kept for the next build:
/// the same few show again and again.
const file_icon_cache_entries = 128;
const grid_picture_cache_entries = 128;
/// A row's title and subtitle ask GTK for at most this many characters of
/// width. The layer surface grows to its content's natural width, so an
/// unbounded label would widen the whole window for one long title.
const row_text_width_chars_max = 60;
/// A grid cell's picture is this wide for each 5 of its height (8:5).
const grid_picture_width_parts = 8;
const grid_picture_height_parts = 5;
/// A cell without a picture shows its icon at half the cell's width, up to
/// this; and keeps at most this much height for it.
const grid_icon_px_max = 56;
const grid_icon_height_px_max = 64;

/// Textures by key, the oldest replaced once full (widgets showing one keep
/// their own reference). A key can map to null: known not to load. Main
/// thread.
fn TextureRing(comptime capacity: usize, comptime Key: type) type {
    return struct {
        keys: [capacity]Key = undefined,
        textures: [capacity]?*c.GdkTexture = @splat(null),
        count: usize = 0,
        /// Next slot to reuse once full.
        next: usize = 0,

        const Ring = @This();

        /// Null: not in the ring; null inside: known not to load.
        fn get(ring: *const Ring, key: Key) ??*c.GdkTexture {
            for (ring.keys[0..ring.count], ring.textures[0..ring.count]) |slot_key, texture| {
                if (slot_key == key) return texture;
            }
            return null;
        }

        /// Takes `texture`'s reference.
        fn put(ring: *Ring, key: Key, texture: ?*c.GdkTexture) void {
            assert(ring.count <= capacity);
            const slot = if (ring.count < capacity) ring.count else ring.next;
            if (ring.count < capacity) {
                ring.count += 1;
            } else {
                ring.next = (ring.next + 1) % capacity;
            }
            if (ring.textures[slot]) |old| c.g_object_unref(old);
            ring.keys[slot] = key;
            ring.textures[slot] = texture;
        }
    };
}

/// A key for what `path` holds now, decoded at that size: an edited file gets
/// a new one (mtime to the nanosecond, size, inode). Null when it is gone.
fn fileKey(path: [*:0]const u8, width_px: c_int, height_px: c_int) ?u64 {
    const stamp = os.Stamp.of(path);
    if (stamp.eql(.none)) return null;
    var hash: std.hash.Wyhash = .init(0);
    hash.update(std.mem.span(path));
    const parts = [_]i64{
        stamp.sec,
        stamp.nsec,
        @bitCast(stamp.size),
        @bitCast(stamp.ino),
        width_px,
        height_px,
    };
    hash.update(std.mem.asBytes(&parts));
    return hash.final();
}

/// How result rows look, from the Density setting and lumen.layout. Ui
/// keeps one (applyLayout, applyStructure, scanIconDir fill it) and hands
/// it to the row builders.
pub const RowLook = struct {
    /// Icon size, from the Density setting.
    icon_px: c_int = themes.densitySizes(.default).icon_px,
    /// Icons replaced by name: ~/.config/lumen/icons/<name>.svg (or .png)
    /// is used wherever the icon <name> would be. Name to path, both in
    /// Ui.icon_arena.
    renamed: std.StringHashMapUnmanaged([:0]const u8) = .empty,
    /// What rows show.
    show: layout_mod.Show = .{},
    /// Subtitles after titles on the same line (rows = "inline").
    rows_inline: bool = false,
    /// A row's parts in order.
    parts: layout_mod.Parts(layout_mod.RowPart) = .{},
};

/// An image file as an icon, decoded at twice `size` (sharp on HiDPI) and
/// kept until the file changes: the same few icons show again and again.
/// Decoded on the UI thread, so within the small `pictures.icon_limits`.
fn fileTexture(path: [:0]const u8, size: c_int) ?*c.GdkTexture {
    const Cache = struct {
        var ring: TextureRing(file_icon_cache_entries, u64) = .{};
    };
    const key = fileKey(path.ptr, size * 2, size * 2) orelse return null;
    if (Cache.ring.get(key)) |texture| return texture;
    const decoded = pictures.decodeImage(path.ptr, size * 2, size * 2, pictures.icon_limits);
    defer if (decoded) |pixbuf| c.g_object_unref(pixbuf);
    const texture = if (decoded) |pixbuf| c.gdk_texture_new_for_pixbuf(pixbuf) else null;
    Cache.ring.put(key, texture);
    return texture;
}

/// Icon, title over subtitle, accessory, and the hidden hint that shows
/// the primary action while the row is selected.
pub const RowParts = struct { hint: ?*c.GtkLabel = null, accessory: ?*c.GtkWidget = null };

pub fn itemRow(look: *const RowLook, item: Item, parts: *RowParts) *c.GtkListBoxRow {
    const row = gtk.listBoxRow();
    const box = hbox(12);
    // The parts in lumen.layout's order; those left out are not made.
    for (look.parts.slice()) |part| switch (part) {
        .icon => if (look.show.icons) gtk.append(box, iconWidget(look, item.icon, look.icon_px)),
        .text => {
            const text = if (look.rows_inline) hbox(10) else vbox(1);
            gtk.setValign(text, c.GTK_ALIGN_CENTER);
            gtk.setHexpand(text, true);
            const title = shortLabel(item.title, "title");
            c.gtk_label_set_ellipsize(title, c.PANGO_ELLIPSIZE_END);
            c.gtk_label_set_max_width_chars(title, row_text_width_chars_max);
            gtk.append(text, title);
            if (item.subtitle.len > 0 and look.show.subtitles) {
                const subtitle = shortLabel(item.subtitle, "subtitle");
                c.gtk_label_set_ellipsize(subtitle, c.PANGO_ELLIPSIZE_END);
                c.gtk_label_set_max_width_chars(subtitle, row_text_width_chars_max);
                gtk.append(text, subtitle);
            }
            gtk.append(box, text);
        },
        .accessory => if (item.accessory.len > 0 and look.show.accessories) {
            parts.accessory = gtk.widget(shortLabel(item.accessory, "accessory"));
            gtk.append(box, parts.accessory.?);
        },
        .hint => {
            parts.hint = label("", "hint");
            gtk.setVisible(parts.hint.?, false);
            gtk.append(box, parts.hint.?);
        },
    };
    c.gtk_list_box_row_set_child(row, gtk.widget(box));
    return row;
}

/// A grid cell: a picture (an image file, scaled down as it is decoded) or
/// a large icon, and the title under it. `width_px` is the cell's width.
pub fn gridCell(look: *const RowLook, item: Item, width_px: c_int) *c.GtkWidget {
    // Ui keeps a cell at least a pixel wide, however narrow the layout.
    assert(width_px > 0);
    const box = vbox(6);
    gtk.addClass(box, "cell");
    const picture_height_px = @max(
        @divTrunc(width_px * grid_picture_height_parts, grid_picture_width_parts),
        1,
    );
    const key = if (item.image.len > 0)
        fileKey(item.image.ptr, width_px, picture_height_px)
    else
        null;
    const cached = if (key) |cache_key| GridPictures.ring.get(cache_key) else null;
    // Cached as null: the picture did not decode, and the icon shows instead.
    const cached_texture = cached orelse null;
    const top = if (cached_texture) |texture| cellPicture(texture, picture_height_px) else null;
    const decode = key != null and cached == null;
    const shown = top orelse blk: {
        const icon = iconWidget(look, item.icon, @min(@divTrunc(width_px, 2), grid_icon_px_max));
        gtk.setHalign(icon, c.GTK_ALIGN_CENTER);
        // As tall as the picture on its way, so the cell keeps its size
        // when it comes.
        const icon_height_px = if (decode)
            picture_height_px
        else
            @min(picture_height_px, grid_icon_height_px_max);
        gtk.setSizeRequest(icon, -1, icon_height_px);
        break :blk icon;
    };
    gtk.append(box, shown);
    const title = shortLabel(item.title, "cell-title");
    c.gtk_label_set_ellipsize(title, c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_xalign(title, 0.5);
    c.gtk_label_set_max_width_chars(title, 1);
    gtk.setHexpand(title, true);
    gtk.append(box, title);
    gtk.setSizeRequest(box, width_px, -1);
    if (decode) GridPictures.request(item.image, width_px, picture_height_px, key.?, box, shown);
    return gtk.widget(box);
}

/// A grid cell's picture: `texture` cropped to fill the cell's width.
fn cellPicture(texture: *c.GdkTexture, height_px: c_int) *c.GtkWidget {
    const picture = gtk.pictureFromPaintable(texture);
    c.gtk_picture_set_content_fit(picture, c.GTK_CONTENT_FIT_COVER);
    gtk.setSizeRequest(picture, -1, height_px);
    c.gtk_widget_set_overflow(gtk.widget(picture), c.GTK_OVERFLOW_HIDDEN);
    return gtk.widget(picture);
}

/// Grid pictures. Every cell decoded its image on the UI thread, uncached,
/// each time the grid was built (every keystroke): a 20000×20000 PNG cost
/// 2 s and 1.2 GB per key. Now a cell shows its icon until its picture,
/// decoded on a worker (`pictures.requestPicture`), replaces it; they are kept
/// for the next build. A new build drops what the last one asked for and
/// was not decoded yet.
const GridPictures = struct {
    var ring: TextureRing(grid_picture_cache_entries, u64) = .{};

    /// A cell waiting for its picture; its widgets are referenced until then.
    const Wait = struct { key: u64, height_px: c_int, box: *c.GtkBox, icon: *c.GtkWidget };

    fn request(
        path: []const u8,
        width_px: c_int,
        height_px: c_int,
        key: u64,
        box: *c.GtkBox,
        icon: *c.GtkWidget,
    ) void {
        const wait = std.heap.c_allocator.create(Wait) catch return;
        _ = c.g_object_ref(box);
        _ = c.g_object_ref(icon);
        wait.* = .{ .key = key, .height_px = height_px, .box = box, .icon = icon };
        const lane = &pictures.grid_lane;
        pictures.requestPicture(path, width_px, height_px, lane, .back, &requestCallback, wait);
    }

    fn requestCallback(context: ?*anyopaque, decoded: ?*c.GdkPixbuf, current: bool) void {
        const wait: *Wait = @ptrCast(@alignCast(context.?));
        defer {
            c.g_object_unref(wait.box);
            c.g_object_unref(wait.icon);
            std.heap.c_allocator.destroy(wait);
        }
        // Dropped for a newer build before it was decoded: nothing learnt.
        if (decoded == null and !current) return;
        const texture_or_none = if (decoded) |pixbuf|
            c.gdk_texture_new_for_pixbuf(pixbuf)
        else
            null;
        ring.put(wait.key, texture_or_none);
        // The cell may be gone (another keystroke): the new build's cell
        // for the same picture finds it in the ring.
        const texture = texture_or_none orelse return;
        if (c.gtk_widget_get_parent(wait.icon) != gtk.widget(wait.box)) return;
        c.gtk_box_remove(wait.box, wait.icon);
        c.gtk_box_prepend(wait.box, cellPicture(texture, wait.height_px));
    }
};

/// The grid is being built again: what its last build asked for and is
/// not decoded yet is not wanted any more.
pub fn forgetGridPictures() void {
    pictures.grid_lane.forget();
}

pub fn calcRow(item: Item) *c.GtkListBoxRow {
    const row = gtk.listBoxRow();
    gtk.addClass(row, "calc");
    const box = hbox(0);
    c.gtk_box_set_homogeneous(box, 1);

    var answer_bytes: [80:0]u8 = undefined;
    const value = std.fmt.parseFloat(f64, item.detail) catch 0;
    const answer = core.calc.formatDisplay(&answer_bytes, value);
    answer_bytes[answer.len] = 0;

    const left_tag: [:0]const u8 = if (item.subtitle.len > 0) item.subtitle else "Expression";
    const right_tag: [:0]const u8 = if (item.accessory.len > 0) item.accessory else "Answer";
    gtk.append(box, calcSide(item.title, left_tag));
    const arrow = label("→", "calc-arrow");
    c.gtk_label_set_xalign(arrow, 0.5);
    gtk.append(box, arrow);
    gtk.append(box, calcSide(answer_bytes[0..answer.len :0], right_tag));
    c.gtk_list_box_row_set_child(row, gtk.widget(box));
    return row;
}

pub fn calcSide(value: [:0]const u8, tag: [:0]const u8) *c.GtkWidget {
    const side = vbox(10);
    gtk.setValign(side, c.GTK_ALIGN_CENTER);
    const value_label = label(value, "calc-value");
    c.gtk_label_set_xalign(value_label, 0.5);
    c.gtk_label_set_ellipsize(value_label, c.PANGO_ELLIPSIZE_END);
    gtk.append(side, value_label);
    const tag_label = label(tag, "calc-label");
    gtk.setHalign(tag_label, c.GTK_ALIGN_CENTER);
    gtk.append(side, tag_label);
    return gtk.widget(side);
}

pub fn iconWidget(look: *const RowLook, icon: item_mod.Icon, size: c_int) *c.GtkWidget {
    switch (icon) {
        .logo => |logo| {
            const texture = logos.texture(logo.name) orelse return iconWidget(look, .none, size);
            const image = gtk.imageFromPaintable(texture);
            c.gtk_image_set_pixel_size(image, if (logo.on_light) size - 6 else size);
            gtk.addClass(image, if (logo.on_light) "logo-plate" else "logo");
            gtk.setValign(image, c.GTK_ALIGN_CENTER);
            return gtk.widget(image);
        },
        .gicon => |gicon| {
            const image = gtk.imageFromGicon(gicon);
            c.gtk_image_set_pixel_size(image, size);
            gtk.addClass(image, css_class.app_icon);
            return gtk.widget(image);
        },
        .tile => |tile| {
            if (look.renamed.get(tile.name)) |path| {
                return iconWidget(look, .{ .file = path }, size);
            }
            return tileIcon(tile, size);
        },
        .emoji => |emoji| return gtk.widget(label(emoji, "emoji")),
        .named => |name| {
            if (look.renamed.get(name)) |path| return iconWidget(look, .{ .file = path }, size);
            const image = gtk.imageFromIconName(name);
            c.gtk_image_set_pixel_size(image, size);
            gtk.addClass(image, css_class.app_icon);
            return gtk.widget(image);
        },
        .swatch => |colors| {
            const texture = swatchTexture(colors.bg, colors.fg, colors.accent) orelse {
                return iconWidget(look, .none, size);
            };
            const image = gtk.imageFromPaintable(texture);
            c.gtk_image_set_pixel_size(image, size);
            gtk.setValign(image, c.GTK_ALIGN_CENTER);
            return gtk.widget(image);
        },
        .badge => |badge| return badgeIcon(badge),
        .file => |path| {
            const texture = fileTexture(path, size) orelse return iconWidget(look, .none, size);
            const image = gtk.imageFromPaintable(texture);
            c.gtk_image_set_pixel_size(image, size);
            gtk.addClass(image, "file-icon");
            gtk.setValign(image, c.GTK_ALIGN_CENTER);
            return gtk.widget(image);
        },
        .none => {
            const image = gtk.imageFromIconName("application-x-executable");
            c.gtk_image_set_pixel_size(image, size);
            return gtk.widget(image);
        },
    }
}

/// A symbolic icon on a tile of the tile's colour, half the icon's size.
fn tileIcon(tile: @FieldType(item_mod.Icon, "tile"), size: c_int) *c.GtkWidget {
    const image = gtk.imageFromIconName(tile.name);
    c.gtk_image_set_pixel_size(image, @divTrunc(size, 2) + 2);
    gtk.addClass(image, "tile");
    var class_bytes: [24:0]u8 = undefined;
    const class = std.mem.printSentinel(
        &class_bytes,
        "tile-{t}",
        .{tile.color},
        0,
    ) catch "tile-gray";
    gtk.addClass(image, class.ptr);
    gtk.setValign(image, c.GTK_ALIGN_CENTER);
    return gtk.widget(image);
}

/// A file extension's text on a tile of the badge's colour.
fn badgeIcon(badge: @FieldType(item_mod.Icon, "badge")) *c.GtkWidget {
    const badge_label = label(badge.text, "badge");
    c.gtk_label_set_xalign(badge_label, 0.5);
    var class_bytes: [24:0]u8 = undefined;
    const class = std.mem.printSentinel(
        &class_bytes,
        "badge-{t}",
        .{badge.color},
        0,
    ) catch "badge-gray";
    gtk.addClass(badge_label, class.ptr);
    // Longer extensions get a smaller font so the tile keeps its size.
    if (badge.text.len >= 4) gtk.addClass(badge_label, "badge-long");
    gtk.setValign(badge_label, c.GTK_ALIGN_CENTER);
    return gtk.widget(badge_label);
}

// -------------------------------------------------------------- helpers

pub fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = c.g_signal_connect_data(@ptrCast(instance), signal, @ptrCast(handler), data, null, 0);
}

pub const hbox = gtk.hbox;
pub const vbox = gtk.vbox;

/// A label aligned to the start, with the CSS class `css`.
pub fn label(text: [*:0]const u8, css: ?[*:0]const u8) *c.GtkLabel {
    const label_widget = gtk.label(text);
    c.gtk_label_set_xalign(label_widget, 0);
    if (css) |class| gtk.addClass(label_widget, class);
    return label_widget;
}

/// Bytes of a row's title, subtitle or accessory given to its label. A row
/// shows about 60 characters, but Pango lays out and measures all of the
/// text, several times per frame: a 1 MB line from `lumen --dmenu` took
/// 324 ms each time. The item keeps all of it (dmenu prints the whole line).
pub const row_text_bytes_max = 512;

/// A label for row text, cut to `row_text_bytes_max` bytes on a character boundary.
fn shortLabel(text: [:0]const u8, css: ?[*:0]const u8) *c.GtkLabel {
    if (text.len <= row_text_bytes_max) return label(text, css);
    var shown: [row_text_bytes_max + 1]u8 = undefined;
    const length = core.utf8.floorBoundary(text, row_text_bytes_max);
    @memcpy(shown[0..length], text[0..length]);
    shown[length] = 0;
    return label(shown[0..length :0], css);
}

test {
    _ = @import("pictures.zig");
}
