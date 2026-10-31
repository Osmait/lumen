//! The window's structure, from `lumen.layout { ... }` in init.lua: size,
//! place, one panel or two, where the search bar and the detail pane go, a
//! footer, and which parts of a row show. style.css styles what is there;
//! this decides what is there.

const std = @import("std");
const assert = std.debug.assert;

pub const Position = enum { top, upper_third, center, bottom };
pub const Panels = enum { split, single };
pub const Search = enum { top, bottom };
pub const Detail = enum { right, left, bottom };
/// A row's subtitle under its title, or after it on the same line. The
/// value is "inline"; the tag is `inline_` because `inline` is a keyword.
pub const Rows = enum { stacked, inline_ };
/// The search bar's pieces: the back arrow, the magnifier, the prompt, the
/// open view's name, the text field and the "Ctrl K" chip.
pub const BarPart = enum { back, icon, prompt, scope, entry, keys };
/// A row's pieces: its icon, title and subtitle, accessory, and the hint
/// of what Enter does.
pub const RowPart = enum { icon, text, accessory, hint };

/// An order of parts, some of them maybe left out.
pub fn Parts(comptime T: type) type {
    const parts_count = @typeInfo(T).@"enum".field_names.len;
    return struct {
        items: [parts_count]T = std.enums.values(T)[0..parts_count].*,
        len: u8 = parts_count,

        pub fn slice(parts: *const @This()) []const T {
            return parts.items[0..parts.len];
        }

        pub fn has(parts: *const @This(), part: T) bool {
            return std.mem.findScalar(T, parts.slice(), part) != null;
        }
    };
}

pub const Show = struct {
    /// The primary action inside the selected row ("Open ↵").
    hints: bool = true,
    subtitles: bool = true,
    accessories: bool = true,
    icons: bool = true,
    section_titles: bool = true,
    /// The "Ctrl K" chip in the search bar.
    key_hints: bool = true,
    /// The open view's name in the search bar, and the back arrow.
    scope: bool = true,
    back: bool = true,
    /// A magnifier at the start of the search bar.
    search_icon: bool = false,
};

pub const Layout = struct {
    /// Pixels; null: the Width and Height settings.
    width: ?u16 = null,
    height: ?u16 = null,
    /// Null: the Window Position setting.
    position: ?Position = null,
    /// Pixels away from where `position` puts it (down for top, centre and
    /// upper third; up for bottom).
    offset: i16 = 0,
    panels: Panels = .split,
    search: Search = .top,
    detail: Detail = .right,
    /// A bar under the results: the view, what Enter does, Actions.
    footer: bool = false,
    rows: Rows = .stacked,
    show: Show = .{},
    /// The search bar's and rows' parts, in order; those left out are not
    /// shown.
    searchbar: Parts(BarPart) = .{},
    row: Parts(RowPart) = .{},
    /// Fixed text in the search bar (rofi's "drun"); its memory belongs to
    /// the extension registry.
    prompt: [:0]const u8 = "",
    /// The empty search field's text in the root view ("Go…"); with it,
    /// other views show their name and "…". Registry memory, like prompt.
    placeholder: [:0]const u8 = "",

    pub const width_min = 360;
    pub const width_max = 2400;
    pub const height_min = 240;
    pub const height_max = 1600;
    /// Pixels either way.
    pub const offset_max = 2000;

    comptime {
        assert(width_min < width_max);
        assert(height_min < height_max);
        assert(width_max <= std.math.maxInt(u16));
        assert(height_max <= std.math.maxInt(u16));
        assert(offset_max <= std.math.maxInt(i16));
    }
};

/// The layout keys, for error messages.
pub const keys = "width, height, position, offset, panels, search, detail, footer, rows, show, searchbar, row, prompt, placeholder";
pub const show_keys = "hints, subtitles, accessories, icons, section_titles, key_hints, scope, back, search_icon";

pub const SetError = error{ UnknownKey, BadValue };

/// The keys `set` takes; the extension API reads show, searchbar, row,
/// prompt and placeholder itself.
const Key = enum { width, height, offset, position, panels, search, detail, rows, footer };

/// Sets one key from a Lua-ish value: a number, a string or a boolean.
pub fn set(layout: *Layout, key_name: []const u8, value: Value) SetError!void {
    const key = std.meta.stringToEnum(Key, key_name) orelse return error.UnknownKey;
    switch (key) {
        .width => layout.width = try pixels(value, Layout.width_min, Layout.width_max),
        .height => layout.height = try pixels(value, Layout.height_min, Layout.height_max),
        .offset => {
            const number = value.number orelse return error.BadValue;
            if (!inRange(number, -Layout.offset_max, Layout.offset_max)) return error.BadValue;
            layout.offset = @intFromFloat(number);
        },
        .position => layout.position = try enumValue(Position, value),
        .panels => layout.panels = try enumValue(Panels, value),
        .search => layout.search = try enumValue(Search, value),
        .detail => layout.detail = try enumValue(Detail, value),
        .rows => layout.rows = try rowsValue(value),
        .footer => layout.footer = value.boolean orelse return error.BadValue,
    }
}

/// A size in pixels, from `min` to `max`.
fn pixels(value: Value, min: u16, max: u16) SetError!u16 {
    const number = value.number orelse return error.BadValue;
    if (!inRange(number, @floatFromInt(min), @floatFromInt(max))) return error.BadValue;
    return @intFromFloat(number);
}

/// Whether `number` is from `min` to `max`. False for NaN (a Lua number
/// may be 0/0): written as `number < min or number > max`, NaN would pass,
/// and turning it into an integer is then illegal behaviour.
fn inRange(number: f64, min: f64, max: f64) bool {
    return number >= min and number <= max;
}

fn enumValue(comptime Enum: type, value: Value) SetError!Enum {
    const name = value.string orelse return error.BadValue;
    return std.meta.stringToEnum(Enum, name) orelse error.BadValue;
}

/// The names `rows` takes in Lua. `Rows` cannot use them as tags, because
/// `inline` is a keyword.
const rows_names = std.StaticStringMap(Rows).initComptime(.{
    .{ "stacked", .stacked },
    .{ "inline", .inline_ },
});

comptime {
    assert(rows_names.kvs.len == std.enums.values(Rows).len);
}

fn rowsValue(value: Value) SetError!Rows {
    const name = value.string orelse return error.BadValue;
    return rows_names.get(name) orelse error.BadValue;
}

/// Sets one `show` flag.
pub fn setShow(show: *Show, key: []const u8, on: bool) SetError!void {
    inline for (@typeInfo(Show).@"struct".field_names) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(show, name) = on;
            return;
        }
    }
    return error.UnknownKey;
}

/// Sets an order of parts from their names; it must keep `required`.
pub fn setParts(
    comptime Part: type,
    parts: *Parts(Part),
    names: []const []const u8,
    required: Part,
) SetError!void {
    if (names.len == 0 or names.len > parts.items.len) return error.BadValue;
    var parts_new: Parts(Part) = .{ .len = 0 };
    for (names) |name| {
        const part = std.meta.stringToEnum(Part, name) orelse return error.UnknownKey;
        if (parts_new.has(part)) return error.BadValue;
        parts_new.items[parts_new.len] = part;
        parts_new.len += 1;
    }
    if (!parts_new.has(required)) return error.BadValue;
    assert(parts_new.len == names.len);
    parts.* = parts_new;
}

pub const Value = struct {
    number: ?f64 = null,
    string: ?[]const u8 = null,
    boolean: ?bool = null,
};

test "orders of parts" {
    var l: Layout = .{};
    try std.testing.expect(l.searchbar.has(.keys) and l.row.has(.hint));
    try setParts(RowPart, &l.row, &.{ "text", "icon" }, .text);
    try std.testing.expectEqualSlices(RowPart, &.{ .text, .icon }, l.row.slice());
    try std.testing.expect(!l.row.has(.accessory));
    try std.testing.expectError(error.BadValue, setParts(RowPart, &l.row, &.{"icon"}, .text));
    try std.testing.expectError(error.BadValue, setParts(
        BarPart,
        &l.searchbar,
        &.{ "entry", "entry" },
        .entry,
    ));
    try std.testing.expectError(error.UnknownKey, setParts(
        BarPart,
        &l.searchbar,
        &.{ "entry", "logo" },
        .entry,
    ));
}

test "layout keys and values" {
    var l: Layout = .{};
    try set(&l, "width", .{ .number = 820 });
    try set(&l, "position", .{ .string = "bottom" });
    try set(&l, "footer", .{ .boolean = true });
    try set(&l, "offset", .{ .number = -40 });
    try std.testing.expectEqual(@as(?u16, 820), l.width);
    try std.testing.expectEqual(@as(?Position, .bottom), l.position);
    try std.testing.expect(l.footer);
    try std.testing.expectEqual(@as(i16, -40), l.offset);
    try std.testing.expectError(error.BadValue, set(&l, "width", .{ .number = 50 }));
    try std.testing.expectError(error.BadValue, set(&l, "panels", .{ .string = "triple" }));
    try std.testing.expectError(error.BadValue, set(&l, "footer", .{ .string = "yes" }));
    try std.testing.expectError(error.UnknownKey, set(&l, "colour", .{ .string = "red" }));
    try std.testing.expectError(error.BadValue, set(&l, "width", .{ .number = std.math.nan(f64) }));
    try set(&l, "rows", .{ .string = "inline" });
    try std.testing.expectEqual(Rows.inline_, l.rows);
    try std.testing.expectError(error.BadValue, set(&l, "rows", .{ .string = "inline_" }));
    try setShow(&l.show, "icons", false);
    try std.testing.expect(!l.show.icons);
    try std.testing.expectError(error.UnknownKey, setShow(&l.show, "iconz", false));
}
