//! Case- and accent-insensitive substring search (`core.fold`), the hot
//! loop of a content query: verification runs it over every candidate's
//! whole text, so it looks for the needle's first character 32 bytes at a
//! time (SIMD) and compares the rest only where that matches. Results are
//! positions in the original text, which snippets and the UI's highlighting
//! are cut from.

const std = @import("std");
const assert = std.debug.assert;
const fold = @import("core").fold;

/// Where a folded match lies in the ORIGINAL text: [start, end). Folding
/// changes lengths ("acción" is 7 bytes, its folded "accion" 6), so the end
/// is not start + needle.len.
pub const Span = struct { start: usize, end: usize };

/// Case- and accent-insensitive search (`core.fold`) for `needle` in `hay`,
/// from `from`: "accion", "ACCIÓN" and "acción" all find "Acción". Matches
/// start at a character, never inside a two-byte letter.
///
/// Verification reads whole documents (extracted PDFs run to megabytes), so
/// this is the hot loop of a content query. It looks for the needle's first
/// folded character 32 bytes at a time: either case of it when it is a
/// letter, plus the lead bytes of accented letters (0xC3-0xC5); the full
/// needle is compared, folded, only at those positions.
pub fn findFold(hay: []const u8, needle: []const u8, from: usize) ?Span {
    if (needle.len == 0) return null;
    // Folded once here, so the comparisons below read one byte per
    // character. An ASCII folded needle (nearly every query) gets the
    // tightest loop; a long one is folded on the fly instead.
    var needle_folded_buffer: [256]u8 = undefined;
    if (needle.len <= needle_folded_buffer.len) {
        const needle_folded = fold.foldInto(&needle_folded_buffer, needle);
        const count = needle_folded.len;
        if (fold.isAscii(needle_folded)) {
            return findFoldImpl(.ascii, hay, needle_folded, count, from);
        }
        return findFoldImpl(.folded, hay, needle_folded, count, from);
    }
    return findFoldImpl(.raw, hay, needle, fold.foldedLen(needle), from);
}

const NeedleKind = enum {
    /// Folded, every byte < 0x80.
    ascii,
    /// Folded: one byte per character.
    folded,
    /// As given: folded on the fly.
    raw,
};

/// Bytes of `hay` compared at once by `findFoldImpl`'s vector loop.
const vector_bytes = 32;
/// Set in a lower-case ASCII letter, clear in its capital.
const ascii_case_bit = 0x20;
/// The UTF-8 lead bytes of the accented letters `core.fold` folds (Latin-1
/// Supplement and Latin Extended-A).
const folded_lead_first = fold.lead_first;
const folded_lead_last = fold.lead_last;

comptime {
    assert('a' | ascii_case_bit == 'a');
    assert('A' | ascii_case_bit == 'a');
    // One mask bit per byte of the vector.
    assert(vector_bytes == @bitSizeOf(u32));
}

fn findFoldImpl(
    comptime kind: NeedleKind,
    hay: []const u8,
    needle: []const u8,
    needle_folded_count: usize,
    from: usize,
) ?Span {
    // Each folded character takes at least one byte of `hay`.
    if (hay.len < needle_folded_count) return null;
    if (from > hay.len - needle_folded_count) return null;
    var j: usize = 0;
    const first = fold.step(needle, &j);
    const letter = first >= 'a' and first <= 'z';
    const start_last = hay.len - needle_folded_count;
    const Chunk = @Vector(vector_bytes, u8);
    var i = from;
    while (i + vector_bytes <= start_last + 1) : (i += vector_bytes) {
        const chunk: Chunk = hay[i..][0..vector_bytes].*;
        var mask: u32 = undefined;
        if (letter) {
            // For a letter, `chunk | ascii_case_bit == first` holds exactly
            // for its two cases (cheaper than folding A-Z first); plus every
            // lead byte of an accented letter (one unsigned compare).
            const lower: Chunk = chunk | @as(Chunk, @splat(ascii_case_bit));
            const cases: u32 = @bitCast(lower == @as(Chunk, @splat(first)));
            const lead_offset = chunk -% @as(Chunk, @splat(folded_lead_first));
            const lead_span: Chunk = @splat(folded_lead_last - folded_lead_first);
            const lead: u32 = @bitCast(lead_offset <= lead_span);
            mask = cases | lead;
        } else {
            // Nothing else folds: the byte itself.
            mask = @bitCast(chunk == @as(Chunk, @splat(first)));
        }
        while (mask != 0) {
            const start = i + @ctz(mask);
            if (matchAt(kind, hay, start, needle, from)) |end| {
                return .{ .start = start, .end = end };
            }
            mask &= mask - 1;
        }
    }
    while (i <= start_last) : (i += 1) {
        const byte = hay[i];
        const candidate = std.ascii.toLower(byte) == first or
            (letter and byte >= folded_lead_first and byte <= folded_lead_last);
        if (!candidate) continue;
        if (matchAt(kind, hay, i, needle, from)) |end| return .{ .start = i, .end = end };
    }
    return null;
}

/// End in `hay` of `needle` matched, folded, at `start`; null if it does
/// not match there or `start` is inside a two-byte letter (`from` starts a
/// character by definition).
inline fn matchAt(
    comptime kind: NeedleKind,
    hay: []const u8,
    start: usize,
    needle: []const u8,
    from: usize,
) ?usize {
    var i = start;
    var j: usize = 0;
    while (j < needle.len) {
        if (i >= hay.len) return null;
        switch (kind) {
            .ascii => {
                const byte = hay[i];
                if (std.ascii.isAscii(byte)) {
                    if (std.ascii.toLower(byte) != needle[j]) return null;
                    i += 1;
                } else if (fold.step(hay, &i) != needle[j]) return null;
                j += 1;
            },
            .folded => {
                if (fold.step(hay, &i) != needle[j]) return null;
                j += 1;
            },
            .raw => if (fold.step(hay, &i) != fold.step(needle, &j)) return null,
        }
    }
    if (start > from and fold.insideLetter(hay, start)) return null;
    return i;
}

/// `findFold`, start only.
pub fn findCI(hay: []const u8, needle: []const u8, from: usize) ?usize {
    const span = findFold(hay, needle, from) orelse return null;
    return span.start;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Reference for `findFold`: fold `hay[from..]` whole (remembering where
/// each folded character came from) and look for the folded needle in it.
fn findFoldNaive(gpa: std.mem.Allocator, hay: []const u8, needle: []const u8, from: usize) !?Span {
    if (needle.len == 0 or from > hay.len) return null;
    var folded: std.ArrayList(u8) = .empty;
    defer folded.deinit(gpa);
    var origin: std.ArrayList(usize) = .empty;
    defer origin.deinit(gpa);
    var i = from;
    while (i < hay.len) {
        try origin.append(gpa, i);
        try folded.append(gpa, fold.step(hay, &i));
    }
    try origin.append(gpa, hay.len);
    const needle_folded = try fold.foldAlloc(gpa, needle);
    defer gpa.free(needle_folded);
    const folded_start = std.mem.find(u8, folded.items, needle_folded) orelse return null;
    const folded_end = folded_start + needle_folded.len;
    return .{ .start = origin.items[folded_start], .end = origin.items[folded_end] };
}

test "SIMD findFold agrees with the naive folded scan" {
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    var hay: [400]u8 = undefined;
    // ASCII, accented letters (two bytes), a symbol, and stray UTF-8 bytes.
    const pieces = [_][]const u8{
        "a",    "b",    "c", "A", "B", " ", "C", "\n", ".", "z", "Z",
        "á",
        "Á",
        "ñ",
        "Ñ",
        "×",
        "\xC3", "\xA1", "n",
    };
    for (0..150) |_| {
        const want = random.intRangeAtMost(usize, 0, hay.len - 2);
        var hay_length: usize = 0;
        while (hay_length < want) {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            @memcpy(hay[hay_length .. hay_length + piece.len], piece);
            hay_length += piece.len;
        }
        const needles = [_][]const u8{
            "a",    "ab",   "AbC",      "zz", "c\n.", "B C a",
            "á",
            "ÁB",
            "n",
            "ñ a",
            "×",
            "\xA1", "\xC3", "aaaaaaaa",
            "ÑAN",
        };
        for (needles) |needle| {
            var from: usize = 0;
            while (from <= hay_length) : (from += 37) {
                try testing.expectEqual(
                    try findFoldNaive(testing.allocator, hay[0..hay_length], needle, from),
                    findFold(hay[0..hay_length], needle, from),
                );
            }
        }
    }
}

/// `pattern` repeated `count` times, at comptime (Zig 0.17 has no `**`).
fn repeat(comptime pattern: []const u8, comptime count: usize) *const [pattern.len * count]u8 {
    const done = comptime blk: {
        @setEvalBranchQuota(count * 10 + 1000);
        var out: [pattern.len * count]u8 = undefined;
        for (0..count) |i| @memcpy(out[i * pattern.len ..][0..pattern.len], pattern);
        break :blk out;
    };
    return &done;
}

test "folded search: accents and case, both ways, positions in the original" {
    const text = "Primera línea\nUna ACCIÓN rápida\nel Ñandú corre\n3×4 y 3x4\n";
    for ([_][]const u8{ "accion", "ACCIÓN", "acción", "Accion" }) |query| {
        const span = findFold(text, query, 0).?;
        try testing.expectEqualStrings("ACCIÓN", text[span.start..span.end]);
    }
    try testing.expectEqualStrings("Ñandú", blk: {
        const span = findFold(text, "nandu", 0).?;
        break :blk text[span.start..span.end];
    });
    try testing.expectEqualStrings("Ñandú", blk: {
        const span = findFold(text, "ÑANDÚ", 0).?;
        break :blk text[span.start..span.end];
    });
    try testing.expectEqualStrings("linea", blk: {
        const span = findFold("linea", "línea", 0).?;
        break :blk "linea"[span.start..span.end];
    });
    // A symbol is not a letter.
    const times = findFold(text, "×", 0).?;
    try testing.expectEqualStrings("×", text[times.start..times.end]);
    try testing.expectEqual(@as(?Span, null), findFold("3×4", "x", 0));
    try testing.expectEqual(@as(?Span, null), findFold("3x4", "×", 0));
    // Never from inside a two-byte letter.
    try testing.expectEqual(@as(?Span, null), findFold("á", "\xA1", 0));
    // A needle too long to fold up front (> 256 bytes) is folded on the fly.
    const long_needle = repeat("Á", 150) ++ "B";
    const long_hay = repeat("x", 40) ++ repeat("a", 160) ++ "b" ++ repeat("á", 150) ++ "b";
    try testing.expectEqual(
        try findFoldNaive(testing.allocator, long_hay, long_needle, 0),
        findFold(long_hay, long_needle, 0),
    );
    try testing.expectEqual(
        @as(?Span, .{ .start = 50, .end = 201 }),
        findFold(long_hay, long_needle, 0),
    );
    try testing.expectEqual(
        @as(?Span, .{ .start = 201, .end = long_hay.len }),
        findFold(long_hay, long_needle, 51),
    );
}

fn fuzzFindFold(_: void, smith: *testing.Smith) anyerror!void {
    // Few distinct bytes, mixed case, and the bytes of accented letters
    // (0xC3 + 0xA1 = á, 0x81 = Á, 0x97 = ×), so folded matches are common.
    const weights: []const testing.Smith.Weight = &.{
        .value(u8, 'a', 20),
        .value(u8, 'A', 20),
        .value(u8, 'b', 10),
        .value(u8, 'B', 10),
        .value(u8, ' ', 5),
        .value(u8, '\n', 3),
        .value(u8, 0xC3, 10),
        .value(u8, 0xA1, 6),
        .value(u8, 0x81, 4),
        .value(u8, 0x97, 2),
        .value(u8, 0xC5, 2),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var hay: [300]u8 = undefined;
    var needle: [12]u8 = undefined;
    const hay_used = hay[0..smith.sliceWeightedBytes(&hay, weights)];
    const needle_used = needle[0..smith.sliceWeightedBytes(&needle, weights)];
    const from = smith.valueRangeAtMost(u32, 0, @intCast(hay_used.len + 2));
    try testing.expectEqual(
        try findFoldNaive(testing.allocator, hay_used, needle_used, from),
        findFold(hay_used, needle_used, from),
    );
}

test "fuzz: findFold agrees with the naive folded scan" {
    try testing.fuzz({}, fuzzFindFold, .{ .corpus = &.{
        "\x40\x00\x00\x00" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaAb" ++ "\x02\x00\x00\x00ab",
        "\x40\x00\x00\x00" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xC3\x81\xC3\xA1b \xC3\x97" ++ "\x03\x00\x00\x00aAb",
        "\x10\x00\x00\x00" ++ "xx\xC3\xA1\xC3\xA1\xC3\x97\xA1\xC3\xC3\xA1bb" ++ "\x02\x00\x00\x00\xC3\x97",
    } });
}
