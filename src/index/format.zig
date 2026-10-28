//! What both on-disk formats (store.zig, content.zig) are made of.

const std = @import("std");
const sys = @import("os");

pub fn align8(x: usize) usize {
    return (x + 7) & ~@as(usize, 7);
}

/// Gives back an index's buffer: a mapping of its file, or heap memory
/// (built in memory, or the file could not be written).
pub fn release(buf: []align(8) u8, mapped: bool, gpa: std.mem.Allocator) void {
    if (mapped) sys.unmap(buf) else gpa.free(buf);
}

/// Smith input for a fuzz test that starts with one `slice()`.
pub fn corpusEntry(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const e = try gpa.alloc(u8, 4 + bytes.len);
    std.mem.writeInt(u32, e[0..4], @intCast(bytes.len), .little);
    @memcpy(e[4..], bytes);
    return e;
}
