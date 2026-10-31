//! Positions in a registry's lists, as types of their own: a command's, a
//! preference's, and a form field's (in its command's `fields`). The window
//! keeps them to name what it shows, so one cannot be used for another.

const std = @import("std");
const assert = std.debug.assert;

pub const CommandIndex = Index(.command);
pub const PreferenceIndex = Index(.preference);
pub const FieldIndex = Index(.field);

/// A distinct u16 position type per `list`. The type keeps `list` as a
/// declaration: without it, the three would be one and the same type (Zig
/// interns a type that does not depend on its parameter).
fn Index(comptime list: enum { command, preference, field }) type {
    return enum(u16) {
        pub const list_name = list;
        /// A position no registry has: what a view held that a reload took
        /// away. Lookups by it find nothing (the host keeps every list
        /// shorter than this).
        gone = std.math.maxInt(u16),
        _,

        const Self = @This();

        pub fn from(offset: usize) Self {
            assert(offset < @backingInt(Self.gone));
            return @fromBackingInt(@as(u16, @intCast(offset)));
        }

        pub fn position(index: Self) usize {
            return @backingInt(index);
        }

        /// `items[index]`, or null when the list has no such position
        /// (the registry it was taken from was replaced by a shorter one).
        pub fn in(index: Self, comptime T: type, items: []const T) ?*const T {
            if (index.position() >= items.len) return null;
            return &items[index.position()];
        }
    };
}

test "indexes of different lists are different types" {
    try std.testing.expect(CommandIndex != PreferenceIndex);
    try std.testing.expect(PreferenceIndex != FieldIndex);
    const items = [_]u8{ 7, 8 };
    try std.testing.expectEqual(@as(u8, 8), CommandIndex.from(1).in(u8, &items).?.*);
    try std.testing.expectEqual(null, CommandIndex.from(2).in(u8, &items));
}
