//! The window's structure, from `lumen.layout { ... }` in init.lua: size,
//! place, one panel or two, where the search bar and the detail pane go, a
//! footer, and which parts of a row show. style.css styles what is there;
//! this decides what is there.

const std = @import("std");

pub const Position = enum { top, upper_third, center, bottom };
pub const Panels = enum { split, single };
pub const Search = enum { top, bottom };
pub const Detail = enum { right, left, bottom };
/// A row's subtitle under its title, or after it on the same line.
pub const Rows = enum { stacked, inline_ };
/// The search bar's pieces: the back arrow, the magnifier, the prompt, the
/// open view's name, the text field and the "Ctrl K" chip.
pub const BarPart = enum { back, icon, prompt, scope, entry, keys };
/// A row's pieces: its icon, title and subtitle, accessory, and the hint
/// of what Enter does.
pub const RowPart = enum { icon, text, accessory, hint };

/// An order of parts, some of them maybe left out.
pub fn Parts(comptime T: type) type {
    return struct {
        items: [@typeInfo(T).@"enum".field_names.len]T = std.enums.values(T)[0..@typeInfo(T).@"enum".field_names.len].*,
        len: u8 = @typeInfo(T).@"enum".field_names.len,

        pub fn slice(p: *const @This()) []const T {
            return p.items[0..p.len];
        }
        pub fn has(p: *const @This(), part: T) bool {
            return std.mem.findScalar(T, p.slice(), part) != null;
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

    pub const min_width = 360;
    pub const max_width = 2400;
    pub const min_height = 240;
    pub const max_height = 1600;
};

/// The layout keys, for error messages.
pub const keys = "width, height, position, offset, panels, search, detail, footer, rows, show, searchbar, row, prompt";
pub const show_keys = "hints, subtitles, accessories, icons, section_titles, key_hints, scope, back, search_icon";

pub const SetError = error{ UnknownKey, BadValue };

/// Sets one key from a Lua-ish value: a number, a string or a boolean.
pub fn set(l: *Layout, key: []const u8, value: Value) SetError!void {
    const eql = std.mem.eql;
    if (eql(u8, key, "width") or eql(u8, key, "height")) {
        const n = value.number orelse return error.BadValue;
        const lo: f64 = if (key[0] == 'w') Layout.min_width else Layout.min_height;
        const hi: f64 = if (key[0] == 'w') Layout.max_width else Layout.max_height;
        if (!(n >= lo and n <= hi)) return error.BadValue;
        const px: u16 = @intFromFloat(n);
        if (key[0] == 'w') l.width = px else l.height = px;
    } else if (eql(u8, key, "offset")) {
        const n = value.number orelse return error.BadValue;
        if (!(n >= -2000 and n <= 2000)) return error.BadValue;
        l.offset = @intFromFloat(n);
    } else if (eql(u8, key, "position")) {
        l.position = std.meta.stringToEnum(Position, value.string orelse return error.BadValue) orelse return error.BadValue;
    } else if (eql(u8, key, "panels")) {
        l.panels = std.meta.stringToEnum(Panels, value.string orelse return error.BadValue) orelse return error.BadValue;
    } else if (eql(u8, key, "search")) {
        l.search = std.meta.stringToEnum(Search, value.string orelse return error.BadValue) orelse return error.BadValue;
    } else if (eql(u8, key, "detail")) {
        l.detail = std.meta.stringToEnum(Detail, value.string orelse return error.BadValue) orelse return error.BadValue;
    } else if (eql(u8, key, "rows")) {
        const v = value.string orelse return error.BadValue;
        l.rows = if (eql(u8, v, "stacked")) .stacked else if (eql(u8, v, "inline")) .inline_ else return error.BadValue;
    } else if (eql(u8, key, "footer")) {
        l.footer = value.boolean orelse return error.BadValue;
    } else return error.UnknownKey;
}

/// Sets one `show` flag.
pub fn setShow(s: *Show, key: []const u8, on: bool) SetError!void {
    inline for (@typeInfo(Show).@"struct".field_names) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(s, name) = on;
            return;
        }
    }
    return error.UnknownKey;
}

/// Sets an order of parts from their names; it must keep `required`.
pub fn setParts(comptime T: type, p: *Parts(T), names: []const []const u8, required: T) SetError!void {
    if (names.len == 0 or names.len > p.items.len) return error.BadValue;
    var out: Parts(T) = .{ .len = 0 };
    for (names) |n| {
        const part = std.meta.stringToEnum(T, n) orelse return error.UnknownKey;
        if (out.has(part)) return error.BadValue;
        out.items[out.len] = part;
        out.len += 1;
    }
    if (!out.has(required)) return error.BadValue;
    p.* = out;
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
    try std.testing.expectError(error.BadValue, setParts(BarPart, &l.searchbar, &.{ "entry", "entry" }, .entry));
    try std.testing.expectError(error.UnknownKey, setParts(BarPart, &l.searchbar, &.{ "entry", "logo" }, .entry));
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
    try setShow(&l.show, "icons", false);
    try std.testing.expect(!l.show.icons);
    try std.testing.expectError(error.UnknownKey, setShow(&l.show, "iconz", false));
}
