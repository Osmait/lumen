//! The GTK pieces rows are made of: boxes, labels, icons, result rows.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const logos = @import("logos.zig");
const themes = @import("themes.zig");
const labels = @import("labels.zig");

/// A small picture of a theme: its background, two lines of text and an
/// accent dot. Made once per theme and kept.
pub fn swatchTexture(id: []const u8, bg: u24, fg: u24, accent: u24) ?*c.GdkTexture {
    const Cache = struct {
        var textures: [themes.all.len + 1]?*c.GdkTexture = @splat(null);
    };
    var slot: usize = themes.all.len;
    for (themes.all, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) {
        slot = i;
        break;
    };
    if (slot < themes.all.len) if (Cache.textures[slot]) |t| return t;
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
    if (slot < themes.all.len) Cache.textures[slot] = tex;
    return tex;
}

/// Icon, title over subtitle, accessory, and the hidden hint that shows
/// the primary action while the row is selected.
pub const RowParts = struct { hint: ?*c.GtkWidget = null, accessory: ?*c.GtkWidget = null };

pub fn itemRow(it: Item, parts: *RowParts) *c.GtkWidget {
    const row = c.gtk_list_box_row_new();
    const box = hbox(12);
    c.gtk_box_append(@ptrCast(box), iconWidget(it.icon, 32));
    const text = vbox(1);
    c.gtk_widget_set_valign(text, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_hexpand(text, 1);
    const title = label(it.title, "title");
    c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_END);
    c.gtk_label_set_max_width_chars(@ptrCast(title), 60);
    c.gtk_box_append(@ptrCast(text), title);
    if (it.subtitle.len > 0) {
        const sub = label(it.subtitle, "subtitle");
        c.gtk_label_set_ellipsize(@ptrCast(sub), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(sub), 60);
        c.gtk_box_append(@ptrCast(text), sub);
    }
    c.gtk_box_append(@ptrCast(box), text);
    if (it.accessory.len > 0) {
        parts.accessory = label(it.accessory, "accessory");
        c.gtk_box_append(@ptrCast(box), parts.accessory.?);
    }
    parts.hint = label("", "hint");
    c.gtk_widget_set_visible(parts.hint.?, 0);
    c.gtk_box_append(@ptrCast(box), parts.hint.?);
    c.gtk_list_box_row_set_child(@ptrCast(row), box);
    return row;
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
            const img = c.gtk_image_new_from_icon_name(t.name);
            c.gtk_image_set_pixel_size(@ptrCast(img), @divTrunc(size, 2) + 2);
            c.gtk_widget_add_css_class(img, "tile");
            var cls: [24:0]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&cls, "tile-{t}", .{t.color}, 0) catch "tile-gray";
            c.gtk_widget_add_css_class(img, name.ptr);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .emoji => |e| return label(e, "emoji"),
        .swatch => |sw| {
            const t = swatchTexture(sw.id, sw.bg, sw.fg, sw.accent) orelse return iconWidget(.none, size);
            const img = c.gtk_image_new_from_paintable(@ptrCast(t));
            c.gtk_image_set_pixel_size(@ptrCast(img), size);
            c.gtk_widget_set_valign(img, c.GTK_ALIGN_CENTER);
            return img;
        },
        .badge => |b| {
            const l = label(b.text, "badge");
            c.gtk_label_set_xalign(@ptrCast(l), 0.5);
            var cls: [24:0]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&cls, "badge-{t}", .{b.color}, 0) catch "badge-gray";
            c.gtk_widget_add_css_class(l, name.ptr);
            // Longer extensions get a smaller font so the tile keeps its size.
            if (b.text.len >= 4) c.gtk_widget_add_css_class(l, "badge-long");
            c.gtk_widget_set_valign(l, c.GTK_ALIGN_CENTER);
            return l;
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
