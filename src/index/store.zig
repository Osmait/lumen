//! Path arena: struct-of-arrays with the same format in RAM and on disk.
//!
//! A path is not stored whole. Every entry points at its parent directory
//! (another entry), so `/home/user/Projects/x/Cargo.toml` costs "Cargo.toml"
//! plus 4 bytes. Paths are rebuilt by walking up, only for what is shown.
//!
//! The whole index is one byte buffer with the arrays laid out back to back,
//! hottest first (`masks`, scanned on every keystroke). Saving writes the
//! buffer; loading is an `mmap`: no parsing, no copy.

const std = @import("std");
const paths = @import("paths.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const sys = @import("os");
const format = @import("format.zig");
const alignUp = format.alignUp;
const Bytes = format.Bytes;
const BytesConst = format.BytesConst;
const corpusEntry = format.corpusEntry;
const fold = @import("core").fold;

pub const no_parent: u32 = std.math.maxInt(u32);
pub const flag_dir: u8 = 1 << 0;
pub const flag_symlink: u8 = 1 << 1;
pub const flag_hidden: u8 = 1 << 2;

/// 02: masks are built from folded names (accents and case, `core.fold`).
/// 03: each directory's children are sorted by name (`findChild`).
const magic = "LUMIDX03";

/// The first bytes of the file. The arrays after it are read in place, in
/// the host's byte order, and so is this: the format is little-endian, and
/// so must the host be (asserted).
const Header = extern struct {
    magic: [8]u8,
    entries_count: u64,
    names_size: u64,

    comptime {
        assert(builtin.cpu.arch.endian() == .little);
        assert(@sizeOf(Header) == 3 * @sizeOf(u64));
        assert(@offsetOf(Header, "entries_count") == 8);
        assert(@offsetOf(Header, "names_size") == 16);
    }

    fn encode(header: Header) [@sizeOf(Header)]u8 {
        assert(std.mem.eql(u8, &header.magic, magic));
        return std.mem.toBytes(header);
    }

    fn decode(bytes: *const [@sizeOf(Header)]u8) Header {
        return std.mem.bytesToValue(Header, bytes);
    }
};

/// The bits of a name's mask, in order: a bit per letter (both cases), per
/// digit and per common symbol of file names, then the rest of the bytes
/// (UTF-8 included) shared among the bits left, and `mask_non_ascii` last.
const mask_letter_first = 0;
const mask_digit_first = mask_letter_first + ('z' - 'a' + 1);
const mask_symbols = "._- +#@~";
const mask_symbol_first = mask_digit_first + ('9' - '0' + 1);
const mask_other_first = mask_symbol_first + mask_symbols.len;
const mask_non_ascii_bit = @bitSizeOf(u64) - 1;
const mask_other_count = mask_non_ascii_bit - mask_other_first;

comptime {
    // The bits found in a file are part of the format: these are the
    // positions files.idx was written with.
    assert(mask_digit_first == 26);
    assert(mask_symbol_first == 36);
    assert(mask_other_first == 44);
    assert(mask_other_count == 19);
}

/// Byte -> bit (0..63) for the mask prefilter, built at compile time.
pub const char_bit: [256]u6 = blk: {
    @setEvalBranchQuota(256 * mask_symbols.len * 8);
    var table: [256]u6 = undefined;
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        table[i] = switch (byte) {
            'a'...'z' => @intCast(mask_letter_first + (byte - 'a')),
            'A'...'Z' => @intCast(mask_letter_first + (byte - 'A')),
            '0'...'9' => @intCast(mask_digit_first + (byte - '0')),
            else => if (std.mem.findScalar(u8, mask_symbols, byte)) |symbol|
                @intCast(mask_symbol_first + symbol)
            else
                @intCast(mask_other_first + byte % mask_other_count),
        };
    }
    break :blk table;
};

/// Set when the name has a byte >= 0x80 (before folding). The cheap scorer
/// lowercases pure ASCII names in place, without looking for bytes to fold.
/// Also correct as a query bit: a query that still has such a byte after
/// folding only matches names that have it.
pub const mask_non_ascii: u64 = 1 << mask_non_ascii_bit;

/// 64-bit set of the characters present in `name`, folded: "español" sets
/// the bit of 'n', so the query "espanol" passes the prefilter (and the
/// other way round). Plus `mask_non_ascii`, which is why a query's mask
/// must be taken from the folded query.
pub fn charMask(name: []const u8) u64 {
    var mask: u64 = 0;
    // ASCII as is (`char_bit` already maps A-Z like a-z): one pass, as fast
    // as before folding, for nearly every name.
    for (name, 0..) |byte, i| {
        if (!std.ascii.isAscii(byte)) return mask | mask_non_ascii | foldedMask(name[i..]);
        mask |= @as(u64, 1) << char_bit[byte];
    }
    return mask;
}

fn foldedMask(name: []const u8) u64 {
    var mask: u64 = 0;
    var i: usize = 0;
    while (i < name.len) mask |= @as(u64, 1) << char_bit[fold.step(name, &i)];
    return mask;
}

/// Offset of each array inside the buffer. Computed the same way when
/// building and when mapping, which is what makes both formats one.
const Layout = struct {
    entries_count: usize,
    names_size: usize,
    masks_offset: usize,
    name_offsets_offset: usize,
    parents_offset: usize,
    depths_offset: usize,
    name_sizes_offset: usize,
    flags_offset: usize,
    names_offset: usize,
    size_total: usize,

    fn init(entries_count: usize, names_size: usize) Layout {
        // Widest first, so every array stays aligned whatever the count.
        const masks_offset = @sizeOf(Header);
        const name_offsets_offset = masks_offset + entries_count * @sizeOf(u64);
        const parents_offset = name_offsets_offset + entries_count * @sizeOf(u32);
        const depths_offset = parents_offset + entries_count * @sizeOf(u32);
        const name_sizes_offset = depths_offset + entries_count * @sizeOf(u16);
        const flags_offset = name_sizes_offset + entries_count * @sizeOf(u16);
        const names_offset = alignUp(flags_offset + entries_count * @sizeOf(u8));
        const layout: Layout = .{
            .entries_count = entries_count,
            .names_size = names_size,
            .masks_offset = masks_offset,
            .name_offsets_offset = name_offsets_offset,
            .parents_offset = parents_offset,
            .depths_offset = depths_offset,
            .name_sizes_offset = name_sizes_offset,
            .flags_offset = flags_offset,
            .names_offset = names_offset,
            .size_total = names_offset + names_size,
        };
        assert(layout.flags_offset + entries_count == @sizeOf(Header) + entries_count * entry_size);
        return layout;
    }
};

/// Immutable path index: built with `Builder` or mapped with `open`.
pub const Store = struct {
    bytes: Bytes,
    backing: format.Backing,
    layout: Layout,

    pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
        format.release(store.bytes, store.backing, gpa);
        store.* = undefined;
    }

    pub fn len(store: *const Store) u32 {
        return @intCast(store.layout.entries_count);
    }

    fn column(store: *const Store, comptime T: type, offset: usize) []T {
        const items: [*]T = @ptrCast(@alignCast(store.bytes.ptr + offset));
        return items[0..store.layout.entries_count];
    }

    pub fn masks(store: *const Store) []u64 {
        return store.column(u64, store.layout.masks_offset);
    }
    pub fn parents(store: *const Store) []u32 {
        return store.column(u32, store.layout.parents_offset);
    }
    pub fn depths(store: *const Store) []u16 {
        return store.column(u16, store.layout.depths_offset);
    }
    pub fn flags(store: *const Store) []u8 {
        return store.column(u8, store.layout.flags_offset);
    }

    /// Checked again on every use, not only by `validate`: a private mapping
    /// still shows what others write to the file afterwards (pages not yet
    /// copied), and a bad offset read past the buffer.
    pub fn name(store: *const Store, id: u32) []const u8 {
        assert(id < store.layout.entries_count);
        const name_offset = store.column(u32, store.layout.name_offsets_offset)[id];
        const name_size = store.column(u16, store.layout.name_sizes_offset)[id];
        if (@as(usize, name_offset) + name_size > store.layout.names_size) return "";
        const start = store.layout.names_offset + name_offset;
        return store.bytes[start .. start + name_size];
    }

    pub fn isDir(store: *const Store, id: u32) bool {
        assert(id < store.layout.entries_count);
        return store.flags()[id] & flag_dir != 0;
    }

    /// Absolute path of `id`, written into `out`; null if it does not fit
    /// (PATH_MAX is 4096, a deeper tree is possible) or its parents do not
    /// lead to a root. Two passes up the parent chain: one to measure, one
    /// to fill from the end. Both are bounded, for the same reason as
    /// `name`: a parent cycle written to the file after it was checked
    /// made the first one spin forever.
    pub fn path(store: *const Store, id: u32, out: []u8) ?[]const u8 {
        const parents_all = store.parents();
        const entries_count = store.layout.entries_count;
        var path_size: usize = 0;
        var entry = id;
        var steps: usize = 0;
        while (true) : (steps += 1) {
            if (entry >= entries_count) return null;
            if (steps >= entries_count) return null;
            path_size += store.name(entry).len;
            const parent = parents_all[entry];
            if (parent == no_parent) break;
            if (parent >= entries_count) return null;
            path_size += paths.separatorAfter(store.name(parent)).len;
            if (path_size > out.len) return null;
            entry = parent;
        }
        if (path_size > out.len) return null;
        var end = path_size;
        entry = id;
        for (0..steps + 1) |_| {
            const entry_name = store.name(entry);
            if (entry_name.len > end) return null;
            @memcpy(out[end - entry_name.len .. end], entry_name);
            end -= entry_name.len;
            const parent = parents_all[entry];
            if (parent == no_parent) {
                // The file changed between the two passes otherwise.
                if (end != 0) return null;
                return out[0..path_size];
            }
            if (parent >= entries_count) return null;
            const separator = paths.separatorAfter(store.name(parent));
            if (end < separator.len) return null;
            end -= separator.len;
            @memcpy(out[end..][0..separator.len], separator);
            entry = parent;
        }
        return null;
    }

    /// Deletes an entry without rebuilding: its mask becomes 0, and a
    /// non-empty query (at least one bit) can never pass `mask & q == q`.
    /// Free on the hot path. On a mapping this writes copy-on-write pages;
    /// the file on disk is untouched.
    pub fn tombstone(store: *Store, id: u32) void {
        assert(id < store.layout.entries_count);
        store.masks()[id] = 0;
        assert(store.isTombstoned(id));
    }

    pub fn isTombstoned(store: *const Store, id: u32) bool {
        assert(id < store.layout.entries_count);
        return store.masks()[id] == 0;
    }

    /// Roots come first, with `no_parent`.
    pub fn rootsCount(store: *const Store) u32 {
        var roots_count: u32 = 0;
        for (store.parents()) |parent| {
            if (parent != no_parent) break;
            roots_count += 1;
        }
        return roots_count;
    }

    /// Range of the direct children of `directory`. The level-by-level scan leaves
    /// the parent array non-decreasing, so children are contiguous and a
    /// binary search finds them with zero extra memory. Valid only for
    /// stores built by `scan`.
    pub fn children(store: *const Store, directory: u32) struct { lo: u32, hi: u32 } {
        assert(directory < store.layout.entries_count);
        const from = store.rootsCount();
        const tail = store.parents()[from..];
        const lo = from + lowerBound(tail, directory);
        const hi = from + upperBound(tail, directory);
        assert(lo <= hi);
        assert(hi <= store.layout.entries_count);
        return .{ .lo = @intCast(lo), .hi = @intCast(hi) };
    }

    /// Child of `directory` named `child_name`: two binary searches, one for
    /// the children and one among them by name (scan-built stores only: the
    /// scan sorts each directory's entries).
    pub fn findChild(store: *const Store, directory: u32, child_name: []const u8) ?u32 {
        const range = store.children(directory);
        var lo = range.lo;
        var hi = range.hi;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, store.name(mid), child_name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => {
                    assert(store.parents()[mid] == directory);
                    return if (store.isTombstoned(mid)) null else mid;
                },
            }
        }
        return null;
    }

    /// Same by linear scan: for stores not built level by level (the delta).
    pub fn findChildScan(store: *const Store, directory: u32, child_name: []const u8) ?u32 {
        for (store.parents(), 0..) |parent, entry| {
            const id: u32 = @intCast(entry);
            if (parent != directory) continue;
            if (store.isTombstoned(id)) continue;
            if (std.mem.eql(u8, store.name(id), child_name)) return id;
        }
        return null;
    }

    pub fn parentsSorted(store: *const Store) bool {
        const tail = store.parents()[store.rootsCount()..];
        if (tail.len < 2) return true;
        for (tail[0 .. tail.len - 1], tail[1..]) |parent, parent_next| {
            if (parent > parent_next) return false;
        }
        return true;
    }

    pub fn liveCount(store: *const Store) usize {
        var live_count: usize = 0;
        for (store.masks()) |mask| live_count += @intFromBool(mask != 0);
        return live_count;
    }

    /// Writes the buffer as is to `path_z`, atomically (a temporary file,
    /// then rename: a crash midway never leaves a corrupt index in place).
    pub fn save(store: *const Store, path_z: [:0]const u8) sys.Error!void {
        try sys.writeFileAtomic(path_z, store.bytes);
    }

    /// Maps an index file. PROT_WRITE with MAP_PRIVATE is copy-on-write, so
    /// tombstones never reach the file.
    pub fn open(path_z: [:0]const u8) (sys.Error || error{BadIndex})!Store {
        const bytes = try sys.mapPrivate(path_z);
        errdefer sys.unmap(bytes);
        return parse(bytes, .mapped);
    }

    /// Checks that `bytes` is a well-formed index and wraps it without copying.
    /// `backing` says how `deinit` releases it (munmap, or free with the
    /// allocator it is given).
    ///
    /// The file comes from disk, so it may be truncated (disk full during a
    /// save), from another version, or garbage. Everything a later access
    /// trusts is checked here, once, in linear passes (~1 ms for 1M entries):
    /// the header and layout fit the buffer exactly, every name lies inside
    /// the names blob, and every parent is `no_parent` (roots, first) or an
    /// earlier entry, so walking up from any entry ends at a root.
    pub fn parse(bytes: Bytes, backing: format.Backing) error{BadIndex}!Store {
        return .{ .bytes = bytes, .backing = backing, .layout = try validate(bytes) };
    }
};

/// Bytes per entry across all the arrays: mask, name offset, parent, depth,
/// name size and flags.
const entry_size = @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32) + @sizeOf(u16) + @sizeOf(u16) +
    @sizeOf(u8);

comptime {
    assert(entry_size == 21);
}

fn validate(bytes: BytesConst) error{BadIndex}!Layout {
    if (bytes.len < @sizeOf(Header)) return error.BadIndex;
    const header = Header.decode(bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.magic, magic)) return error.BadIndex;
    // Bound both before any arithmetic on them, so the layout cannot
    // overflow. Ids are u32 and `no_parent` is reserved.
    if (header.entries_count > (bytes.len - @sizeOf(Header)) / entry_size) return error.BadIndex;
    if (header.entries_count >= no_parent) return error.BadIndex;
    if (header.names_size > bytes.len) return error.BadIndex;
    const layout = Layout.init(@intCast(header.entries_count), @intCast(header.names_size));
    if (layout.size_total != bytes.len) return error.BadIndex;

    const entries_count = layout.entries_count;
    const name_offsets = viewConst(u32, bytes, layout.name_offsets_offset, entries_count);
    const name_sizes = viewConst(u16, bytes, layout.name_sizes_offset, entries_count);
    for (name_offsets, name_sizes) |name_offset, name_size| {
        if (@as(u64, name_offset) + name_size > layout.names_size) return error.BadIndex;
    }
    const parents = viewConst(u32, bytes, layout.parents_offset, entries_count);
    var roots_count: usize = 0;
    while (roots_count < entries_count and parents[roots_count] == no_parent) roots_count += 1;
    for (parents[roots_count..], roots_count..) |parent, id| {
        // Also rejects a `no_parent` after the roots.
        if (parent >= id) return error.BadIndex;
    }
    return layout;
}

fn viewConst(comptime T: type, bytes: BytesConst, offset: usize, count: usize) []const T {
    const items: [*]const T = @ptrCast(@alignCast(bytes.ptr + offset));
    return items[0..count];
}

/// The first position in `sorted` whose value is not below `value`.
fn lowerBound(sorted: []const u32, value: u32) usize {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] < value) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The first position in `sorted` whose value is above `value`.
fn upperBound(sorted: []const u32, value: u32) usize {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] <= value) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Collects entries, then lays them out in the final buffer.
pub const Builder = struct {
    pub const empty: Builder = .{};

    names: std.ArrayList(u8) = .empty,
    name_offsets: std.ArrayList(u32) = .empty,
    name_sizes: std.ArrayList(u16) = .empty,
    parents: std.ArrayList(u32) = .empty,
    flags: std.ArrayList(u8) = .empty,
    masks: std.ArrayList(u64) = .empty,
    depths: std.ArrayList(u16) = .empty,

    pub fn deinit(builder: *Builder, gpa: std.mem.Allocator) void {
        inline for (.{
            "names",
            "name_offsets",
            "name_sizes",
            "parents",
            "flags",
            "masks",
            "depths",
        }) |column| @field(builder, column).deinit(gpa);
        // Reusable: `finish` leaves an empty builder.
        builder.* = .empty;
    }

    pub fn len(builder: *const Builder) u32 {
        return @intCast(builder.name_offsets.items.len);
    }

    /// Adds an entry under `parent` (an earlier entry, or `no_parent` for a
    /// root). A name longer than a u16 can measure is cut (Linux names stop
    /// at 255 bytes; a root is a whole path, at most 4096).
    pub fn push(
        builder: *Builder,
        gpa: std.mem.Allocator,
        entry_name: []const u8,
        parent: u32,
        flags: u8,
        depth: u16,
    ) std.mem.Allocator.Error!u32 {
        const id = builder.len();
        assert(id < no_parent);
        // The pair of `validate`'s check, except for the delta's scaffolding
        // roots, which come after other entries.
        if (parent != no_parent) assert(parent < id);
        const short = entry_name[0..@min(entry_name.len, std.math.maxInt(u16))];
        try builder.name_offsets.append(gpa, @intCast(builder.names.items.len));
        try builder.names.appendSlice(gpa, short);
        try builder.name_sizes.append(gpa, @intCast(short.len));
        try builder.parents.append(gpa, parent);
        try builder.flags.append(gpa, flags);
        try builder.masks.append(gpa, charMask(short));
        try builder.depths.append(gpa, depth);
        return id;
    }

    /// Scaffolding: rebuilds paths but never shows up (mask 0, like a
    /// tombstone; `path()` does not look at masks).
    pub fn pushStructural(
        builder: *Builder,
        gpa: std.mem.Allocator,
        entry_name: []const u8,
        parent: u32,
        flags: u8,
        depth: u16,
    ) std.mem.Allocator.Error!u32 {
        const id = try builder.push(gpa, entry_name, parent, flags, depth);
        builder.masks.items[id] = 0;
        return id;
    }

    pub fn tombstone(builder: *Builder, id: u32) void {
        builder.masks.items[id] = 0;
    }

    /// Builds the store and empties the builder. On error the builder is
    /// left as it was.
    pub fn finish(builder: *Builder, gpa: std.mem.Allocator) std.mem.Allocator.Error!Store {
        const layout = Layout.init(builder.len(), builder.names.items.len);
        assert(layout.entries_count < no_parent);
        assert(layout.names_size <= std.math.maxInt(u32));
        const bytes = try gpa.alignedAlloc(u8, .@"8", layout.size_total);
        defer builder.deinit(gpa);
        @memset(bytes, 0);
        const header: Header = .{
            .magic = magic.*,
            .entries_count = layout.entries_count,
            .names_size = layout.names_size,
        };
        @memcpy(bytes[0..@sizeOf(Header)], &header.encode());
        put(bytes, layout.masks_offset, builder.masks.items);
        put(bytes, layout.name_offsets_offset, builder.name_offsets.items);
        put(bytes, layout.parents_offset, builder.parents.items);
        put(bytes, layout.depths_offset, builder.depths.items);
        put(bytes, layout.name_sizes_offset, builder.name_sizes.items);
        put(bytes, layout.flags_offset, builder.flags.items);
        put(bytes, layout.names_offset, builder.names.items);
        return .{ .bytes = bytes, .backing = .heap, .layout = layout };
    }
};

fn put(destination: []u8, offset: usize, column: anytype) void {
    const source = std.mem.sliceAsBytes(column);
    @memcpy(destination[offset .. offset + source.len], source);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn sample(gpa: std.mem.Allocator) !Store {
    var builder: Builder = .empty;
    const root = try builder.push(gpa, "/home/u", no_parent, flag_dir, 0);
    const project = try builder.push(gpa, "proj", root, flag_dir, 1);
    _ = try builder.push(gpa, "notes.md", root, 0, 1);
    _ = try builder.push(gpa, "Cargo.toml", project, 0, 2);
    _ = try builder.push(gpa, "src", project, flag_dir, 2);
    return builder.finish(gpa);
}

test "char_bit gives every byte the bit files.idx 03 was written with" {
    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        const written: u6 = switch (byte) {
            'a'...'z' => @intCast(byte - 'a'),
            'A'...'Z' => @intCast(byte - 'A'),
            '0'...'9' => @intCast(26 + (byte - '0')),
            '.' => 36,
            '_' => 37,
            '-' => 38,
            ' ' => 39,
            '+' => 40,
            '#' => 41,
            '@' => 42,
            '~' => 43,
            else => @intCast(44 + byte % 19),
        };
        try testing.expectEqual(written, char_bit[byte]);
    }
}

test "paths are rebuilt from parents" {
    var store = try sample(testing.allocator);
    defer store.deinit(testing.allocator);
    var path_buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/proj/Cargo.toml", store.path(3, &path_buffer).?);
    try testing.expectEqualStrings("/home/u", store.path(0, &path_buffer).?);
}

test "children by binary search and tombstones" {
    var store = try sample(testing.allocator);
    defer store.deinit(testing.allocator);
    try testing.expect(store.parentsSorted());
    const range = store.children(1);
    try testing.expectEqual(@as(u32, 3), range.lo);
    try testing.expectEqual(@as(u32, 5), range.hi);
    try testing.expectEqual(@as(?u32, 4), store.findChild(1, "src"));
    store.tombstone(4);
    try testing.expectEqual(@as(?u32, null), store.findChild(1, "src"));
    try testing.expectEqual(@as(usize, 4), store.liveCount());
}

test "findChild: a binary search among a directory's sorted children" {
    const gpa = testing.allocator;
    var builder: Builder = .empty;
    const root = try builder.push(gpa, "/r", no_parent, flag_dir, 0);
    const subdirectory = try builder.push(gpa, "a", root, flag_dir, 1);
    const names = [_][]const u8{ "Z", "b", "c.txt", "d", "e", "f", "g" };
    for (names) |child_name| _ = try builder.push(gpa, child_name, root, 0, 1);
    for (names) |child_name| _ = try builder.push(gpa, child_name, subdirectory, 0, 2);
    var store = try builder.finish(gpa);
    defer store.deinit(gpa);
    for (names) |child_name| {
        const id = store.findChild(root, child_name).?;
        try testing.expectEqualStrings(child_name, store.name(id));
        try testing.expectEqual(root, store.parents()[id]);
        const nested = store.findChild(subdirectory, child_name).?;
        try testing.expectEqual(subdirectory, store.parents()[nested]);
    }
    try testing.expectEqual(@as(?u32, null), store.findChild(root, "c"));
    try testing.expectEqual(@as(?u32, null), store.findChild(root, "zz"));
    store.tombstone(store.findChild(subdirectory, "e").?);
    try testing.expectEqual(@as(?u32, null), store.findChild(subdirectory, "e"));
}

test "a mapping written to after it was checked never hangs or reads out of bounds" {
    // What `validate` accepted, changed underneath (a private mapping shows
    // writes to pages it has not copied yet).
    var store = try sample(testing.allocator);
    defer store.deinit(testing.allocator);
    var path_buffer: [256]u8 = undefined;
    const parents = store.parents();
    // proj -> Cargo.toml -> proj: a cycle.
    parents[1] = 3;
    try testing.expectEqual(@as(?[]const u8, null), store.path(3, &path_buffer));
    // Out of range.
    parents[1] = 99;
    try testing.expectEqual(@as(?[]const u8, null), store.path(3, &path_buffer));
    parents[1] = 0;
    store.column(u32, store.layout.name_offsets_offset)[2] = std.math.maxInt(u32);
    try testing.expectEqualStrings("", store.name(2));
    try testing.expectEqualStrings("/home/u/proj/Cargo.toml", store.path(3, &path_buffer).?);
    // Too long for the buffer: no path, not an empty one.
    try testing.expectEqual(@as(?[]const u8, null), store.path(3, path_buffer[0..10]));
}

test "save and map give the same index; tombstones stay in memory" {
    var store = try sample(testing.allocator);
    defer store.deinit(testing.allocator);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try sys.tmpDirPath(&temporary, &directory_buffer);
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try std.mem.printSentinel(&index_path_buffer, "{s}/idx", .{directory}, 0);
    try store.save(index_path);

    var mapped = try Store.open(index_path);
    defer mapped.deinit(testing.allocator);
    try testing.expectEqual(store.len(), mapped.len());
    var path_buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/proj/Cargo.toml", mapped.path(3, &path_buffer).?);
    mapped.tombstone(3);

    var again = try Store.open(index_path);
    defer again.deinit(testing.allocator);
    try testing.expect(!again.isTombstoned(3));
}

test "mask prefilter" {
    const query_mask = charMask("cgo");
    try testing.expect(charMask("Cargo.toml") & query_mask == query_mask);
    try testing.expect(charMask("README") & query_mask != query_mask);
}

test "mask prefilter folds accents and case, both ways" {
    // Same letters; only the original's non-ASCII marker differs.
    try testing.expectEqual(charMask("espanol.txt") | mask_non_ascii, charMask("español.txt"));
    try testing.expectEqual(charMask("configuracion") | mask_non_ascii, charMask("CONFIGURACIÓN"));
    try testing.expect(charMask("español.txt") & charMask("espanol") == charMask("espanol"));
    // Queries are folded first (as `search` does): "ñu" -> "nu".
    var query_folded: [8]u8 = undefined;
    const query_mask = charMask(fold.foldInto(&query_folded, "ñu"));
    try testing.expect(charMask("Ñandú") & query_mask == query_mask);
    try testing.expect(charMask("nandu") & query_mask == query_mask);
    // A symbol is not a letter: "×" does not set the bit of 'x'.
    try testing.expect(charMask("3×4") & charMask("x") != charMask("x"));
    try testing.expect(charMask("español") & mask_non_ascii != 0);
    try testing.expect(charMask("espanol") & mask_non_ascii == 0);
    for (0..256) |byte| try testing.expect(char_bit[byte] != 63);
}

// ------------------------------------------------- corrupt indexes, fuzzing

/// Touches everything a reader of a store may touch: must never crash on a
/// store that `parse` accepted.
fn exercise(store: *const Store) void {
    var path_buffer: [512]u8 = undefined;
    var sum: usize = store.rootsCount() + @intFromBool(store.parentsSorted()) + store.liveCount();
    for (0..store.len()) |i| {
        const id: u32 = @intCast(i);
        const path_length = if (store.path(id, &path_buffer)) |path| path.len else 0;
        sum +%= store.name(id).len + path_length + @intFromBool(store.isDir(id));
        const range = store.children(id);
        assert(range.lo <= range.hi);
        assert(range.hi <= store.len());
        if (store.findChild(id, "x")) |child| sum +%= child;
        if (store.findChildScan(id, "x")) |child| sum +%= child;
    }
    std.mem.doNotOptimizeAway(sum);
}

fn sampleBytes(gpa: std.mem.Allocator) !Bytes {
    const store = try sample(gpa);
    // Owned by the caller now.
    return store.bytes;
}

test "corrupt indexes are rejected, not trusted" {
    const gpa = testing.allocator;
    const good = try sampleBytes(gpa);
    defer gpa.free(good);
    _ = try Store.parse(good, .heap);

    const bad = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(bad);
    const layout = (try Store.parse(good, .heap)).layout;

    // Truncated anywhere (a save interrupted by a full disk), or empty.
    for (0..good.len) |cut| try testing.expectError(
        error.BadIndex,
        Store.parse(good[0..cut], .heap),
    );

    // Wrong magic (another version).
    @memcpy(bad, good);
    bad[7] = '1';
    try testing.expectError(error.BadIndex, Store.parse(bad, .heap));

    // Entry count so large the layout arithmetic would overflow.
    @memcpy(bad, good);
    std.mem.writeInt(u64, bad[8..16], std.math.maxInt(u64), .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, .heap));
    std.mem.writeInt(u64, bad[8..16], std.math.maxInt(u64) / 8 + 1, .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, .heap));

    // Names blob length that does not match the file.
    @memcpy(bad, good);
    std.mem.writeInt(u64, bad[16..24], std.math.maxInt(u64), .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, .heap));

    // A name past the end of the names blob.
    @memcpy(bad, good);
    const name_offset_bad: u32 = @intCast(layout.names_size - 3);
    const name_offset_at = layout.name_offsets_offset + 4 * 2;
    std.mem.writeInt(u32, bad[name_offset_at..][0..4], name_offset_bad, .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, .heap));
    @memcpy(bad, good);
    const name_size_bad = std.math.maxInt(u16);
    std.mem.writeInt(u16, bad[layout.name_sizes_offset + 2 * 4 ..][0..2], name_size_bad, .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, .heap));

    // A parent out of range, a cycle (path() would loop forever), a parent
    // after its child, and a root that is not at the start.
    for ([_]struct { id: usize, parent: u32 }{
        .{ .id = 3, .parent = 99 },
        .{ .id = 1, .parent = 1 },
        .{ .id = 1, .parent = 3 },
        .{ .id = 2, .parent = no_parent },
    }) |corruption| {
        @memcpy(bad, good);
        const parent_at = layout.parents_offset + 4 * corruption.id;
        std.mem.writeInt(u32, bad[parent_at..][0..4], corruption.parent, .little);
        try testing.expectError(error.BadIndex, Store.parse(bad, .heap));
    }
}

test "a truncated index file fails to open" {
    const gpa = testing.allocator;
    const good = try sampleBytes(gpa);
    defer gpa.free(good);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try sys.tmpDirPath(&temporary, &directory_buffer);
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try std.mem.printSentinel(&index_path_buffer, "{s}/idx", .{directory}, 0);
    try sys.writeFile(index_path, good[0 .. good.len - 5]);
    try testing.expectError(error.BadIndex, Store.open(index_path));
    try sys.writeFile(index_path, "not an index at all, just text");
    try testing.expectError(error.BadIndex, Store.open(index_path));
}

test "random byte flips never crash" {
    const gpa = testing.allocator;
    const good = try sampleBytes(gpa);
    defer gpa.free(good);
    const bad = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(bad);
    var prng = std.Random.DefaultPrng.init(17);
    const random = prng.random();
    var accepted: usize = 0;
    for (0..20_000) |_| {
        @memcpy(bad, good);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            bad[random.uintLessThan(usize, bad.len)] = random.int(u8);
        }
        const cut_short = random.uintLessThan(u8, 8) == 0;
        const cut = if (cut_short) random.uintAtMost(usize, bad.len) else bad.len;
        if (Store.parse(bad[0..cut], .heap)) |store| {
            exercise(&store);
            accepted += 1;
        } else |_| {}
    }
    // Flips in masks, depths, flags and names are harmless: many pass.
    try testing.expect(accepted > 0);
}

fn fuzzParse(_: void, smith: *testing.Smith) anyerror!void {
    var input: [1024]u8 align(format.alignment_bytes) = undefined;
    const bytes = input[0..smith.slice(&input)];
    // Often give it a plausible header, so the fuzzer gets past the magic
    // and the length check to the per-entry ones.
    if (bytes.len >= @sizeOf(Header) and smith.value(bool)) {
        @memcpy(bytes[0..8], magic);
        const entries_fit = (bytes.len - @sizeOf(Header)) / entry_size;
        const entries_count = smith.valueRangeAtMost(u32, 0, @intCast(entries_fit));
        const fixed = Layout.init(entries_count, 0).size_total;
        std.mem.writeInt(u64, bytes[8..16], entries_count, .little);
        std.mem.writeInt(u64, bytes[16..24], bytes.len -| fixed, .little);
    }
    if (Store.parse(bytes, .heap)) |store| exercise(&store) else |_| {}
}

test "fuzz: parsing arbitrary bytes never crashes" {
    const gpa = testing.allocator;
    const good = try sampleBytes(gpa);
    defer gpa.free(good);
    const seed = try corpusEntry(gpa, good);
    defer gpa.free(seed);
    try testing.fuzz({}, fuzzParse, .{ .corpus = &.{ seed, "\x08\x00\x00\x00" ++ magic } });
}

fn fuzzBuilt(_: void, smith: *testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var builder: Builder = .empty;
    defer builder.deinit(gpa);
    const roots = smith.valueRangeAtMost(u8, 1, 3);
    for (0..roots) |_| _ = try builder.push(gpa, "/r", no_parent, flag_dir, 0);
    var name_letters: [40]u8 = undefined;
    while (builder.len() < 300 and !smith.eosWeightedSimple(15, 1)) {
        const entry_name = name_letters[0..smith.slice(&name_letters)];
        const parent = smith.valueRangeLessThan(u32, 0, builder.len());
        _ = try builder.push(gpa, entry_name, parent, smith.value(u8), smith.value(u16));
    }
    var built = try builder.finish(gpa);
    defer built.deinit(gpa);
    // What the builder writes, the validator must accept, unchanged.
    const parsed = try Store.parse(built.bytes, .heap);
    var path_built: paths.Buffer = undefined;
    var path_parsed: paths.Buffer = undefined;
    for (0..built.len()) |i| try testing.expectEqualStrings(
        built.path(@intCast(i), &path_built) orelse "",
        parsed.path(@intCast(i), &path_parsed) orelse "",
    );
    exercise(&parsed);
}

test "fuzz: every index the builder writes is accepted" {
    try testing.fuzz({}, fuzzBuilt, .{});
}
