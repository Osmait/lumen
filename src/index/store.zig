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
const linux = std.os.linux;
const sys = @import("os");
const format = @import("format.zig");
const align8 = format.align8;
const corpusEntry = format.corpusEntry;
const fold = @import("core").fold;

pub const no_parent: u32 = std.math.maxInt(u32);
pub const flag_dir: u8 = 1 << 0;
pub const flag_symlink: u8 = 1 << 1;
pub const flag_hidden: u8 = 1 << 2;

/// 02: masks are built from folded names (accents and case, `core.fold`).
const magic = "LUMIDX02";
const header = 24;

/// Byte -> bit (0..63) for the mask prefilter, built at compile time.
pub const char_bit: [256]u6 = blk: {
    var t: [256]u6 = undefined;
    for (0..256) |i| {
        const b: u8 = @intCast(i);
        t[i] = switch (b) {
            'a'...'z' => @intCast(b - 'a'),
            'A'...'Z' => @intCast(b - 'A'),
            '0'...'9' => @intCast(26 + (b - '0')),
            '.' => 36,
            '_' => 37,
            '-' => 38,
            ' ' => 39,
            '+' => 40,
            '#' => 41,
            '@' => 42,
            '~' => 43,
            // Everything else (UTF-8 included) shares 44..62; 63 is
            // `mask_non_ascii`.
            else => @intCast(44 + b % 19),
        };
    }
    break :blk t;
};

/// Set when the name has a byte >= 0x80 (before folding). The cheap scorer
/// lowercases pure ASCII names in place, without looking for bytes to fold.
/// Also correct as a query bit: a query that still has such a byte after
/// folding only matches names that have it.
pub const mask_non_ascii: u64 = 1 << 63;

/// 64-bit set of the characters present in `name`, folded: "español" sets
/// the bit of 'n', so the query "espanol" passes the prefilter (and the
/// other way round). Plus `mask_non_ascii`, which is why a query's mask
/// must be taken from the folded query.
pub fn charMask(name: []const u8) u64 {
    var m: u64 = 0;
    // ASCII as is (`char_bit` already maps A-Z like a-z): one pass, as fast
    // as before folding, for nearly every name.
    for (name, 0..) |b, i| {
        if (b >= 0x80) return m | mask_non_ascii | foldedMask(name[i..]);
        m |= @as(u64, 1) << char_bit[b];
    }
    return m;
}

fn foldedMask(s: []const u8) u64 {
    var m: u64 = 0;
    var i: usize = 0;
    while (i < s.len) m |= @as(u64, 1) << char_bit[fold.step(s, &i)];
    return m;
}

/// Offset of each array inside the buffer. Computed the same way when
/// building and when mapping, which is what makes both formats one.
const Layout = struct {
    n: usize,
    names_len: usize,
    masks: usize,
    name_off: usize,
    parent: usize,
    depth: usize,
    name_len: usize,
    flags: usize,
    names: usize,
    total: usize,

    fn init(n: usize, names_len: usize) Layout {
        const masks = header;
        const name_off = masks + n * 8;
        const parent = name_off + n * 4;
        const depth = parent + n * 4;
        const name_len = depth + n * 2;
        const flags = name_len + n * 2;
        const names = align8(flags + n);
        return .{
            .n = n,
            .names_len = names_len,
            .masks = masks,
            .name_off = name_off,
            .parent = parent,
            .depth = depth,
            .name_len = name_len,
            .flags = flags,
            .names = names,
            .total = names + names_len,
        };
    }
};

/// Immutable path index: built with `Builder` or mapped with `open`.
pub const Store = struct {
    buf: []align(8) u8,
    mapped: bool,
    lay: Layout,

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        format.release(s.buf, s.mapped, gpa);
        s.* = undefined;
    }

    pub fn len(s: *const Store) u32 {
        return @intCast(s.lay.n);
    }

    fn arr(s: *const Store, comptime T: type, off: usize) []T {
        const p: [*]T = @ptrCast(@alignCast(s.buf.ptr + off));
        return p[0..s.lay.n];
    }

    pub fn masks(s: *const Store) []u64 {
        return s.arr(u64, s.lay.masks);
    }
    pub fn parents(s: *const Store) []u32 {
        return s.arr(u32, s.lay.parent);
    }
    pub fn depths(s: *const Store) []u16 {
        return s.arr(u16, s.lay.depth);
    }
    pub fn flags(s: *const Store) []u8 {
        return s.arr(u8, s.lay.flags);
    }

    pub fn name(s: *const Store, id: u32) []const u8 {
        const off = s.arr(u32, s.lay.name_off)[id];
        const n = s.arr(u16, s.lay.name_len)[id];
        const start = s.lay.names + off;
        return s.buf[start .. start + n];
    }

    pub fn isDir(s: *const Store, id: u32) bool {
        return s.flags()[id] & flag_dir != 0;
    }

    /// Absolute path of `id`, written into `out`. Two passes up the parent
    /// chain: one to measure, one to fill from the end.
    pub fn path(s: *const Store, id: u32, out: []u8) []const u8 {
        const ps = s.parents();
        var total: usize = 0;
        var cur = id;
        while (true) {
            total += s.name(cur).len;
            const p = ps[cur];
            if (p == no_parent) break;
            if (!std.mem.endsWith(u8, s.name(p), "/")) total += 1;
            cur = p;
        }
        if (total > out.len) return "";
        var end = total;
        cur = id;
        while (true) {
            const n = s.name(cur);
            @memcpy(out[end - n.len .. end], n);
            end -= n.len;
            const p = ps[cur];
            if (p == no_parent) break;
            if (!std.mem.endsWith(u8, s.name(p), "/")) {
                end -= 1;
                out[end] = '/';
            }
            cur = p;
        }
        return out[0..total];
    }

    /// Deletes an entry without rebuilding: its mask becomes 0, and a
    /// non-empty query (at least one bit) can never pass `mask & q == q`.
    /// Free on the hot path. On a mapping this writes copy-on-write pages;
    /// the file on disk is untouched.
    pub fn tombstone(s: *Store, id: u32) void {
        s.masks()[id] = 0;
    }

    pub fn isTombstoned(s: *const Store, id: u32) bool {
        return s.masks()[id] == 0;
    }

    /// Roots come first, with `no_parent`.
    pub fn nRoots(s: *const Store) u32 {
        var n: u32 = 0;
        for (s.parents()) |p| {
            if (p != no_parent) break;
            n += 1;
        }
        return n;
    }

    /// Range of the direct children of `dir`. The level-by-level scan leaves
    /// the parent array non-decreasing, so children are contiguous and a
    /// binary search finds them with zero extra memory. Valid only for
    /// stores built by `scan`.
    pub fn children(s: *const Store, dir: u32) struct { lo: u32, hi: u32 } {
        const from = s.nRoots();
        const tail = s.parents()[from..];
        const lo = from + lowerBound(tail, dir);
        const hi = from + upperBound(tail, dir);
        return .{ .lo = @intCast(lo), .hi = @intCast(hi) };
    }

    /// Child of `dir` named `n`, by binary search (scan-built stores only).
    pub fn findChild(s: *const Store, dir: u32, n: []const u8) ?u32 {
        const r = s.children(dir);
        var id = r.lo;
        while (id < r.hi) : (id += 1) {
            if (!s.isTombstoned(id) and std.mem.eql(u8, s.name(id), n)) return id;
        }
        return null;
    }

    /// Same by linear scan: for stores not built level by level (the delta).
    pub fn findChildScan(s: *const Store, dir: u32, n: []const u8) ?u32 {
        const ps = s.parents();
        for (0..s.len()) |i| {
            const id: u32 = @intCast(i);
            if (ps[i] == dir and !s.isTombstoned(id) and std.mem.eql(u8, s.name(id), n)) return id;
        }
        return null;
    }

    pub fn parentsSorted(s: *const Store) bool {
        const tail = s.parents()[s.nRoots()..];
        if (tail.len < 2) return true;
        for (tail[0 .. tail.len - 1], tail[1..]) |a, b| if (a > b) return false;
        return true;
    }

    pub fn liveLen(s: *const Store) usize {
        var n: usize = 0;
        for (s.masks()) |m| n += @intFromBool(m != 0);
        return n;
    }

    /// Writes the buffer as is to `path_z`, atomically (a temporary file,
    /// then rename: a crash midway never leaves a corrupt index in place).
    pub fn save(s: *const Store, path_z: [:0]const u8) sys.Error!void {
        try sys.writeFileAtomic(path_z, s.buf);
    }

    /// Maps an index file. PROT_WRITE with MAP_PRIVATE is copy-on-write, so
    /// tombstones never reach the file.
    pub fn open(path_z: [:0]const u8) (sys.Error || error{BadIndex})!Store {
        const buf = try sys.mapPrivate(path_z);
        errdefer sys.unmap(buf);
        return parse(buf, true);
    }

    /// Checks that `buf` is a well-formed index and wraps it without copying.
    /// `mapped` says how `deinit` releases it (munmap, or free with the
    /// allocator it is given).
    ///
    /// The file comes from disk, so it may be truncated (disk full during a
    /// save), from another version, or garbage. Everything a later access
    /// trusts is checked here, once, in linear passes (~1 ms for 1M entries):
    /// the header and layout fit the buffer exactly, every name lies inside
    /// the names blob, and every parent is `no_parent` (roots, first) or an
    /// earlier entry, so walking up from any entry ends at a root.
    pub fn parse(buf: []align(8) u8, mapped: bool) error{BadIndex}!Store {
        return .{ .buf = buf, .mapped = mapped, .lay = try validate(buf) };
    }
};

/// Bytes per entry across all the arrays (mask, name_off, parent, depth,
/// name_len, flags).
const entry_bytes = 8 + 4 + 4 + 2 + 2 + 1;

fn validate(buf: []align(8) const u8) error{BadIndex}!Layout {
    if (buf.len < header or !std.mem.eql(u8, buf[0..8], magic)) return error.BadIndex;
    const n64 = std.mem.readInt(u64, buf[8..16], .little);
    const names_len64 = std.mem.readInt(u64, buf[16..24], .little);
    // Bound both before any arithmetic on them, so the layout cannot
    // overflow. Ids are u32 and `no_parent` is reserved.
    if (n64 > (buf.len - header) / entry_bytes or n64 >= no_parent) return error.BadIndex;
    if (names_len64 > buf.len) return error.BadIndex;
    const lay = Layout.init(@intCast(n64), @intCast(names_len64));
    if (lay.total != buf.len) return error.BadIndex;

    const n = lay.n;
    const name_off = viewConst(u32, buf, lay.name_off, n);
    const name_len = viewConst(u16, buf, lay.name_len, n);
    for (name_off, name_len) |off, l| {
        if (@as(u64, off) + l > lay.names_len) return error.BadIndex;
    }
    const parents = viewConst(u32, buf, lay.parent, n);
    var i: usize = 0;
    while (i < n and parents[i] == no_parent) i += 1;
    for (parents[i..], i..) |p, id| {
        if (p >= id) return error.BadIndex; // also rejects a late no_parent
    }
    return lay;
}

fn viewConst(comptime T: type, buf: []align(8) const u8, off: usize, n: usize) []const T {
    const p: [*]const T = @ptrCast(@alignCast(buf.ptr + off));
    return p[0..n];
}

fn lowerBound(xs: []const u32, v: u32) usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (xs[mid] < v) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn upperBound(xs: []const u32, v: u32) usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (xs[mid] <= v) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Collects entries, then lays them out in the final buffer.
pub const Builder = struct {
    pub const empty: Builder = .{};

    names: std.ArrayList(u8) = .empty,
    name_off: std.ArrayList(u32) = .empty,
    name_len: std.ArrayList(u16) = .empty,
    parent: std.ArrayList(u32) = .empty,
    flags: std.ArrayList(u8) = .empty,
    masks: std.ArrayList(u64) = .empty,
    depth: std.ArrayList(u16) = .empty,

    pub fn deinit(b: *Builder, gpa: std.mem.Allocator) void {
        inline for (.{
            "names",
            "name_off",
            "name_len",
            "parent",
            "flags",
            "masks",
            "depth",
        }) |f| @field(b, f).deinit(gpa);
        b.* = .empty; // reusable: `finish` leaves an empty builder
    }

    pub fn len(b: *const Builder) u32 {
        return @intCast(b.name_off.items.len);
    }

    pub fn push(
        b: *Builder,
        gpa: std.mem.Allocator,
        n: []const u8,
        parent: u32,
        fl: u8,
        depth: u16,
    ) std.mem.Allocator.Error!u32 {
        const id = b.len();
        const short = n[0..@min(n.len, std.math.maxInt(u16))];
        try b.name_off.append(gpa, @intCast(b.names.items.len));
        try b.names.appendSlice(gpa, short);
        try b.name_len.append(gpa, @intCast(short.len));
        try b.parent.append(gpa, parent);
        try b.flags.append(gpa, fl);
        try b.masks.append(gpa, charMask(short));
        try b.depth.append(gpa, depth);
        return id;
    }

    /// Scaffolding: rebuilds paths but never shows up (mask 0, like a
    /// tombstone; `path()` does not look at masks).
    pub fn pushStructural(
        b: *Builder,
        gpa: std.mem.Allocator,
        n: []const u8,
        parent: u32,
        fl: u8,
        depth: u16,
    ) std.mem.Allocator.Error!u32 {
        const id = try b.push(gpa, n, parent, fl, depth);
        b.masks.items[id] = 0;
        return id;
    }

    pub fn tombstone(b: *Builder, id: u32) void {
        b.masks.items[id] = 0;
    }

    /// Builds the store and empties the builder. On error the builder is
    /// left as it was.
    pub fn finish(b: *Builder, gpa: std.mem.Allocator) std.mem.Allocator.Error!Store {
        const lay = Layout.init(b.len(), b.names.items.len);
        const buf = try gpa.alignedAlloc(u8, .@"8", lay.total);
        defer b.deinit(gpa);
        @memset(buf, 0);
        @memcpy(buf[0..8], magic);
        std.mem.writeInt(u64, buf[8..16], lay.n, .little);
        std.mem.writeInt(u64, buf[16..24], lay.names_len, .little);
        put(buf, lay.masks, b.masks.items);
        put(buf, lay.name_off, b.name_off.items);
        put(buf, lay.parent, b.parent.items);
        put(buf, lay.depth, b.depth.items);
        put(buf, lay.name_len, b.name_len.items);
        put(buf, lay.flags, b.flags.items);
        put(buf, lay.names, b.names.items);
        return .{ .buf = buf, .mapped = false, .lay = lay };
    }
};

fn put(buf: []u8, off: usize, src: anytype) void {
    const bytes = std.mem.sliceAsBytes(src);
    @memcpy(buf[off .. off + bytes.len], bytes);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn sample(gpa: std.mem.Allocator) !Store {
    var b: Builder = .empty;
    const root = try b.push(gpa, "/home/u", no_parent, flag_dir, 0);
    const proj = try b.push(gpa, "proj", root, flag_dir, 1);
    _ = try b.push(gpa, "notes.md", root, 0, 1);
    _ = try b.push(gpa, "Cargo.toml", proj, 0, 2);
    _ = try b.push(gpa, "src", proj, flag_dir, 2);
    return b.finish(gpa);
}

test "paths are rebuilt from parents" {
    var s = try sample(testing.allocator);
    defer s.deinit(testing.allocator);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/proj/Cargo.toml", s.path(3, &buf));
    try testing.expectEqualStrings("/home/u", s.path(0, &buf));
}

test "children by binary search and tombstones" {
    var s = try sample(testing.allocator);
    defer s.deinit(testing.allocator);
    try testing.expect(s.parentsSorted());
    const r = s.children(1);
    try testing.expectEqual(@as(u32, 3), r.lo);
    try testing.expectEqual(@as(u32, 5), r.hi);
    try testing.expectEqual(@as(?u32, 4), s.findChild(1, "src"));
    s.tombstone(4);
    try testing.expectEqual(@as(?u32, null), s.findChild(1, "src"));
    try testing.expectEqual(@as(usize, 4), s.liveLen());
}

test "save and map give the same index; tombstones stay in memory" {
    var s = try sample(testing.allocator);
    defer s.deinit(testing.allocator);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dir_buf);
    var p_buf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&p_buf, "{s}/idx", .{dir}, 0);
    try s.save(p);

    var m = try Store.open(p);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(s.len(), m.len());
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/proj/Cargo.toml", m.path(3, &buf));
    m.tombstone(3);

    var again = try Store.open(p);
    defer again.deinit(testing.allocator);
    try testing.expect(!again.isTombstoned(3));
}

test "mask prefilter" {
    const q = charMask("cgo");
    try testing.expect(charMask("Cargo.toml") & q == q);
    try testing.expect(charMask("README") & q != q);
}

test "mask prefilter folds accents and case, both ways" {
    // Same letters; only the original's non-ASCII marker differs.
    try testing.expectEqual(charMask("espanol.txt") | mask_non_ascii, charMask("español.txt"));
    try testing.expectEqual(charMask("configuracion") | mask_non_ascii, charMask("CONFIGURACIÓN"));
    try testing.expect(charMask("español.txt") & charMask("espanol") == charMask("espanol"));
    // Queries are folded first (as `search` does): "ñu" -> "nu".
    var qb: [8]u8 = undefined;
    const q = charMask(fold.foldInto(&qb, "ñu"));
    try testing.expect(charMask("Ñandú") & q == q);
    try testing.expect(charMask("nandu") & q == q);
    // A symbol is not a letter: "×" does not set the bit of 'x'.
    try testing.expect(charMask("3×4") & charMask("x") != charMask("x"));
    try testing.expect(charMask("español") & mask_non_ascii != 0);
    try testing.expect(charMask("espanol") & mask_non_ascii == 0);
    for (0..256) |b| try testing.expect(char_bit[b] != 63);
}

// ------------------------------------------------- corrupt indexes, fuzzing

/// Touches everything a reader of a store may touch: must never crash on a
/// store that `parse` accepted.
fn exercise(s: *const Store) void {
    var buf: [512]u8 = undefined;
    var sum: usize = s.nRoots() + @intFromBool(s.parentsSorted()) + s.liveLen();
    for (0..s.len()) |i| {
        const id: u32 = @intCast(i);
        sum +%= s.name(id).len + s.path(id, &buf).len + @intFromBool(s.isDir(id));
        const r = s.children(id);
        std.debug.assert(r.lo <= r.hi and r.hi <= s.len());
        if (s.findChild(id, "x")) |c| sum +%= c;
        if (s.findChildScan(id, "x")) |c| sum +%= c;
    }
    std.mem.doNotOptimizeAway(sum);
}

fn sampleBytes(gpa: std.mem.Allocator) ![]align(8) u8 {
    const s = try sample(gpa);
    return s.buf; // owned by the caller now
}

test "corrupt indexes are rejected, not trusted" {
    const gpa = testing.allocator;
    const good = try sampleBytes(gpa);
    defer gpa.free(good);
    _ = try Store.parse(good, false);

    const bad = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(bad);
    const lay = (try Store.parse(good, false)).lay;

    // Truncated anywhere (a save interrupted by a full disk), or empty.
    for (0..good.len) |cut| try testing.expectError(
        error.BadIndex,
        Store.parse(good[0..cut], false),
    );

    // Wrong magic (another version).
    @memcpy(bad, good);
    bad[7] = '1';
    try testing.expectError(error.BadIndex, Store.parse(bad, false));

    // Entry count so large the layout arithmetic would overflow.
    @memcpy(bad, good);
    std.mem.writeInt(u64, bad[8..16], std.math.maxInt(u64), .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, false));
    std.mem.writeInt(u64, bad[8..16], std.math.maxInt(u64) / 8 + 1, .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, false));

    // Names blob length that does not match the file.
    @memcpy(bad, good);
    std.mem.writeInt(u64, bad[16..24], std.math.maxInt(u64), .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, false));

    // A name past the end of the names blob.
    @memcpy(bad, good);
    std.mem.writeInt(u32, bad[lay.name_off + 4 * 2 ..][0..4], @intCast(lay.names_len - 3), .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, false));
    @memcpy(bad, good);
    std.mem.writeInt(u16, bad[lay.name_len + 2 * 4 ..][0..2], std.math.maxInt(u16), .little);
    try testing.expectError(error.BadIndex, Store.parse(bad, false));

    // A parent out of range, a cycle (path() would loop forever), a parent
    // after its child, and a root that is not at the start.
    for ([_]struct { id: usize, parent: u32 }{
        .{ .id = 3, .parent = 99 },
        .{ .id = 1, .parent = 1 },
        .{ .id = 1, .parent = 3 },
        .{ .id = 2, .parent = no_parent },
    }) |c| {
        @memcpy(bad, good);
        std.mem.writeInt(u32, bad[lay.parent + 4 * c.id ..][0..4], c.parent, .little);
        try testing.expectError(error.BadIndex, Store.parse(bad, false));
    }
}

test "a truncated index file fails to open" {
    const gpa = testing.allocator;
    const good = try sampleBytes(gpa);
    defer gpa.free(good);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [4096]u8 = undefined;
    const dir = try sys.tmpDirPath(&tmp, &dir_buf);
    var p_buf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&p_buf, "{s}/idx", .{dir}, 0);
    try sys.writeFile(p, good[0 .. good.len - 5]);
    try testing.expectError(error.BadIndex, Store.open(p));
    try sys.writeFile(p, "not an index at all, just text");
    try testing.expectError(error.BadIndex, Store.open(p));
}

test "random byte flips never crash" {
    const gpa = testing.allocator;
    const good = try sampleBytes(gpa);
    defer gpa.free(good);
    const bad = try gpa.alignedAlloc(u8, .@"8", good.len);
    defer gpa.free(bad);
    var prng = std.Random.DefaultPrng.init(17);
    const r = prng.random();
    var accepted: usize = 0;
    for (0..20_000) |_| {
        @memcpy(bad, good);
        for (0..r.intRangeAtMost(usize, 1, 4)) |_| bad[r.uintLessThan(usize, bad.len)] = r.int(u8);
        const cut = if (r.uintLessThan(u8, 8) == 0) r.uintAtMost(usize, bad.len) else bad.len;
        if (Store.parse(bad[0..cut], false)) |s| {
            exercise(&s);
            accepted += 1;
        } else |_| {}
    }
    // Flips in masks, depths, flags and names are harmless: many pass.
    try testing.expect(accepted > 0);
}

fn fuzzParse(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [1024]u8 align(8) = undefined;
    const b = buf[0..smith.slice(&buf)];
    // Often give it a plausible header, so the fuzzer gets past the magic
    // and the length check to the per-entry ones.
    if (b.len >= header and smith.value(bool)) {
        @memcpy(b[0..8], magic);
        const n = smith.valueRangeAtMost(u32, 0, @intCast((b.len - header) / entry_bytes));
        const fixed = Layout.init(n, 0).total;
        std.mem.writeInt(u64, b[8..16], n, .little);
        std.mem.writeInt(u64, b[16..24], b.len -| fixed, .little);
    }
    if (Store.parse(b, false)) |s| exercise(&s) else |_| {}
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
    var b: Builder = .empty;
    defer b.deinit(gpa);
    const roots = smith.valueRangeAtMost(u8, 1, 3);
    for (0..roots) |_| _ = try b.push(gpa, "/r", no_parent, flag_dir, 0);
    var nb: [40]u8 = undefined;
    while (b.len() < 300 and !smith.eosWeightedSimple(15, 1)) {
        const n = nb[0..smith.slice(&nb)];
        const parent = smith.valueRangeLessThan(u32, 0, b.len());
        _ = try b.push(gpa, n, parent, smith.value(u8), smith.value(u16));
    }
    var s = try b.finish(gpa);
    defer s.deinit(gpa);
    // What the builder writes, the validator must accept, unchanged.
    const m = try Store.parse(s.buf, false);
    var p1: [4096]u8 = undefined;
    var p2: [4096]u8 = undefined;
    for (0..s.len()) |i| try testing.expectEqualStrings(
        s.path(@intCast(i), &p1),
        m.path(@intCast(i), &p2),
    );
    exercise(&m);
}

test "fuzz: every index the builder writes is accepted" {
    try testing.fuzz({}, fuzzBuilt, .{});
}
