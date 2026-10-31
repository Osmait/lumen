//! What both on-disk formats (store.zig, content.zig) are made of.

const std = @import("std");
const sys = @import("os");

/// Every array in both formats starts on a multiple of this, so a mapped
/// file is read as typed slices in place (u64 and i64 columns included).
pub const alignment_bytes = 8;

/// An index file's bytes, mapped or on the heap.
pub const Bytes = []align(alignment_bytes) u8;
pub const BytesConst = []align(alignment_bytes) const u8;

comptime {
    std.debug.assert(alignment_bytes >= @alignOf(u64));
    std.debug.assert(std.math.isPowerOfTwo(alignment_bytes));
    // A mapped file is used in place as `Bytes`.
    std.debug.assert(sys.mapping_alignment_bytes >= alignment_bytes);
}

/// `size` rounded up to the next multiple of `alignment_bytes`.
pub fn alignUp(size: usize) usize {
    return std.mem.alignForward(usize, size, alignment_bytes);
}

/// Where an index's buffer lives, which says how it is given back.
pub const Backing = enum {
    /// A mapping of its file.
    mapped,
    /// Heap memory: built in memory, or the file could not be written.
    heap,
};

/// Gives back an index's buffer.
pub fn release(bytes: Bytes, backing: Backing, gpa: std.mem.Allocator) void {
    switch (backing) {
        .mapped => sys.unmap(bytes),
        .heap => gpa.free(bytes),
    }
}

/// Smith input for a fuzz test that starts with one `slice()`: the length
/// as a little-endian u32, then the bytes.
pub fn corpusEntry(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const length_bytes = @sizeOf(u32);
    const entry = try gpa.alloc(u8, length_bytes + bytes.len);
    std.mem.writeInt(u32, entry[0..length_bytes], @intCast(bytes.len), .little);
    @memcpy(entry[length_bytes..], bytes);
    return entry;
}
