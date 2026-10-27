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

    pub const min_width = 360;
    pub const max_width = 2400;
    pub const min_height = 240;
    pub const max_height = 1600;
};

/// The layout keys, for error messages.
pub const keys = "width, height, position, offset, panels, search, detail, footer, rows, show";
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

pub const Value = struct {
    number: ?f64 = null,
    string: ?[]const u8 = null,
    boolean: ?bool = null,
};

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
