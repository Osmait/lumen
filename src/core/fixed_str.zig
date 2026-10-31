//! Text kept in a fixed buffer: what a field holds without an allocator
//! (the query last asked for, the row to select again).

const std = @import("std");
const assert = std.debug.assert;
const utf8 = @import("utf8.zig");

/// Up to `capacity_bytes` bytes, always zero-terminated. Longer text is cut
/// between characters.
pub fn FixedStr(comptime capacity_bytes: usize) type {
    return struct {
        bytes: [capacity_bytes:0]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();
        pub const capacity = capacity_bytes;

        pub fn set(fixed: *Self, text: []const u8) void {
            fixed.len = utf8.floorBoundary(text, capacity_bytes);
            @memcpy(fixed.bytes[0..fixed.len], text[0..fixed.len]);
            fixed.bytes[fixed.len] = 0;
            fixed.assertValid();
        }

        /// Formatted text; cut like `set` when it does not fit.
        pub fn print(fixed: *Self, comptime fmt: []const u8, args: anytype) void {
            var writer: std.Io.Writer = .fixed(fixed.bytes[0..capacity_bytes]);
            writer.print(fmt, args) catch |err| switch (err) {
                // Full: what fit is kept, cut below like `set` cuts.
                error.WriteFailed => {},
            };
            fixed.len = utf8.floorBoundary(writer.buffered(), writer.buffered().len);
            fixed.bytes[fixed.len] = 0;
            fixed.assertValid();
        }

        pub fn clear(fixed: *Self) void {
            fixed.set("");
        }

        pub fn slice(fixed: *const Self) [:0]const u8 {
            return fixed.bytes[0..fixed.len :0];
        }

        pub fn eql(fixed: *const Self, text: []const u8) bool {
            return std.mem.eql(u8, fixed.slice(), text);
        }

        fn assertValid(fixed: *const Self) void {
            assert(fixed.len <= capacity_bytes);
            assert(fixed.bytes[fixed.len] == 0);
        }
    };
}

test "FixedStr cuts between characters and stays terminated" {
    var fixed: FixedStr(4) = .{};
    try std.testing.expectEqualStrings("", fixed.slice());
    fixed.set("abc");
    try std.testing.expect(fixed.eql("abc"));
    // "é" takes 2 bytes and "€" 3: "aé" fits in 4, "€" does not.
    fixed.set("aé€");
    try std.testing.expectEqualStrings("aé", fixed.slice());
    try std.testing.expectEqual(@as(u8, 0), fixed.slice().ptr[fixed.len]);
    fixed.print("{s}:{d}", .{ "k", 12345 });
    try std.testing.expectEqualStrings("k:12", fixed.slice());
    fixed.clear();
    try std.testing.expect(fixed.eql(""));
}
