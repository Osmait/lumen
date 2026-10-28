//! Text kept in a fixed buffer: what a field holds without an allocator
//! (the query last asked for, the row to select again).

const std = @import("std");
const utf8 = @import("utf8.zig");

/// Up to `n` bytes, always zero-terminated. Longer text is cut between
/// characters.
pub fn FixedStr(comptime n: usize) type {
    return struct {
        buf: [n:0]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();
        pub const capacity = n;

        pub fn set(s: *Self, text: []const u8) void {
            s.len = utf8.floorBoundary(text, n);
            @memcpy(s.buf[0..s.len], text[0..s.len]);
            s.buf[s.len] = 0;
        }

        /// Formatted text; cut like `set` when it does not fit.
        pub fn print(s: *Self, comptime fmt: []const u8, args: anytype) void {
            var w: std.Io.Writer = .fixed(s.buf[0..n]);
            w.print(fmt, args) catch {};
            s.len = utf8.floorBoundary(w.buffered(), w.buffered().len);
            s.buf[s.len] = 0;
        }

        pub fn clear(s: *Self) void {
            s.set("");
        }

        pub fn slice(s: *const Self) [:0]const u8 {
            return s.buf[0..s.len :0];
        }

        pub fn eql(s: *const Self, text: []const u8) bool {
            return std.mem.eql(u8, s.slice(), text);
        }
    };
}

test "FixedStr cuts between characters and stays terminated" {
    var s: FixedStr(4) = .{};
    try std.testing.expectEqualStrings("", s.slice());
    s.set("abc");
    try std.testing.expect(s.eql("abc"));
    s.set("aé€"); // a, é (2 bytes), € (3): "aé" fits, € does not
    try std.testing.expectEqualStrings("aé", s.slice());
    try std.testing.expectEqual(@as(u8, 0), s.slice().ptr[s.len]);
    s.print("{s}:{d}", .{ "k", 12345 });
    try std.testing.expectEqualStrings("k:12", s.slice());
    s.clear();
    try std.testing.expect(s.eql(""));
}
