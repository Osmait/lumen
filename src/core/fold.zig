//! Accent and case folding for search: "Acción", "ACCION" and "accion" all
//! fold to "accion", so a query typed without accents (or in capitals)
//! finds the text, and the other way round.
//!
//! - ASCII letters fold to lowercase.
//! - Latin letters of Latin-1 Supplement (U+00C0-U+00FF, UTF-8 lead byte
//!   0xC3) and Latin Extended-A (U+0100-U+017F, lead bytes 0xC4/0xC5) fold
//!   to their base ASCII letter, lowercase: á->a, Ñ->n, ü->u, ç->c, ß->s,
//!   æ->a, œ->o, ø->o, ð->d, þ->t, ł->l, ı->i.
//! - Everything else is left as it is, byte for byte: symbols of those
//!   blocks (× ÷), the rest of Latin-1 (¿ ¡ « » °, lead byte 0xC2), other
//!   scripts, invalid or truncated UTF-8. A symbol never folds to a letter.
//!
//! A folded character is always ONE byte: a folded two-byte letter becomes
//! its ASCII base, and an unfolded byte stays itself. So a folded string is
//! never longer than the original, folding is idempotent, and positions in
//! folded text count characters the same way the matchers expect.

const std = @import("std");

/// Code points U+00C0..U+017F, by (lead - 0xC3) * 64 + (continuation & 0x3F):
/// the folded ASCII letter, or 0 for a symbol (× ÷), which does not fold.
const letters: *const [192]u8 =
    // U+00C0..U+00FF (lead 0xC3)
    "aaaaaaac" ++ "eeeeiiii" ++ "dnooooo\x00" ++ "ouuuuyts" ++
    "aaaaaaac" ++ "eeeeiiii" ++ "dnooooo\x00" ++ "ouuuuyty" ++
    // U+0100..U+013F (lead 0xC4)
    "aaaaaa" ++ "cccccccc" ++ "dddd" ++ "eeeeeeeeee" ++ "gggggggg" ++ "hhhh" ++
    "iiiiiiiiii" ++ "ii" ++ "jj" ++ "kkk" ++ "lllllll" ++
    // U+0140..U+017F (lead 0xC5)
    "lll" ++ "nnnnnnnnn" ++ "oooooooo" ++ "rrrrrr" ++ "ssssssss" ++ "tttttt" ++
    "uuuuuuuuuuuu" ++ "ww" ++ "yyy" ++ "zzzzzz" ++ "s";

/// Whether code point U+00C0..U+017F is an uppercase letter. Latin-1 puts
/// capitals at C0-DE; Extended-A alternates capital/small in pairs, with the
/// phase shifted by ĸ (U+0138), ŉ (U+0149) and Ÿ (U+0178).
fn upperCodePoint(cp: u21) bool {
    if (cp < 0x100) return cp >= 0xC0 and cp <= 0xDE and cp != 0xD7;
    if (cp <= 0x137) return cp % 2 == 0;
    if (cp == 0x138) return false;
    if (cp <= 0x148) return cp % 2 == 1;
    if (cp == 0x149) return false;
    if (cp <= 0x177) return cp % 2 == 0;
    if (cp == 0x178) return true;
    if (cp <= 0x17E) return cp % 2 == 1;
    return false;
}

const uppers: [192]bool = blk: {
    var t: [192]bool = undefined;
    for (&t, 0..) |*u, i| u.* = upperCodePoint(@intCast(0xC0 + i));
    break :blk t;
};

/// One folded character and what it was.
pub const Char = struct {
    /// The folded byte.
    byte: u8,
    /// The original was an uppercase letter (ASCII or accented): camelCase
    /// bonuses look at this, the folded byte has lost it.
    upper: bool,
};

/// Index into `letters` of the two-byte letter at `s[i]`, or null when the
/// bytes there are not a foldable letter.
inline fn letterAt(s: []const u8, i: usize) ?usize {
    const c = s[i];
    if (c < 0xC3 or c > 0xC5 or i + 1 >= s.len) return null;
    const d = s[i + 1];
    if (d & 0xC0 != 0x80) return null;
    const k = @as(usize, c - 0xC3) * 64 + (d & 0x3F);
    return if (letters[k] != 0) k else null;
}

/// Folded character at `s[i.*]`; advances `i` past it (by 1 or 2 bytes).
/// `i.*` must be < `s.len`.
pub inline fn step(s: []const u8, i: *usize) u8 {
    const c = s[i.*];
    if (c >= 0xC3 and c <= 0xC5) {
        if (letterAt(s, i.*)) |k| {
            i.* += 2;
            return letters[k];
        }
    }
    i.* += 1;
    return std.ascii.toLower(c);
}

/// Like `step`, also telling whether the original was uppercase.
pub inline fn next(s: []const u8, i: *usize) Char {
    const c = s[i.*];
    if (c >= 0xC3 and c <= 0xC5) {
        if (letterAt(s, i.*)) |k| {
            i.* += 2;
            return .{ .byte = letters[k], .upper = uppers[k] };
        }
    }
    i.* += 1;
    return .{ .byte = std.ascii.toLower(c), .upper = std.ascii.isUpper(c) };
}

/// True when the second byte of a two-byte foldable letter is at `s[i]`:
/// not the start of a folded character.
pub fn insideLetter(s: []const u8, i: usize) bool {
    return i > 0 and s[i] & 0xC0 == 0x80 and letterAt(s, i - 1) != null;
}

/// Writes the folded `s` into `buf`; returns the written part. Truncated to
/// `buf.len` folded characters if `s` folds to more.
pub fn foldInto(buf: []u8, s: []const u8) []u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) buf[n] = step(s, &i);
    return buf[0..n];
}

/// Like `foldInto`, also recording in `upper` (as long as `buf`) which
/// folded characters were uppercase letters. Returns the folded length.
pub fn foldCase(buf: []u8, upper: []bool, s: []const u8) usize {
    std.debug.assert(upper.len >= buf.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) {
        const ch = next(s, &i);
        buf[n] = ch.byte;
        upper[n] = ch.upper;
    }
    return n;
}

/// The folded string, allocated.
pub fn foldAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, s.len);
    errdefer gpa.free(buf);
    return gpa.realloc(buf, foldInto(buf, s).len);
}

/// Folded characters in `s` (its folded length).
pub fn foldedLen(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) _ = step(s, &i);
    return n;
}

/// Pure ASCII: folding is only lowercasing, byte for byte.
pub fn isAscii(s: []const u8) bool {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= s.len) : (i += 16) {
        const v: V = s[i..][0..16].*;
        if (@reduce(.Or, v) >= 0x80) return false;
    }
    var acc: u8 = 0;
    for (s[i..]) |c| acc |= c;
    return acc < 0x80;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectFold(want: []const u8, s: []const u8) !void {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(want, foldInto(&buf, s));
    try testing.expectEqual(want.len, foldedLen(s));
}

test "Latin-1 Supplement letters fold to their base letter" {
    try expectFold("aaaaaaaceeeeiiiidnoooooouuuuyts", "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞß");
    try expectFold("aaaaaaaceeeeiiiidnoooooouuuuyty", "àáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿ");
}

test "Latin Extended-A letters fold to their base letter" {
    try expectFold(
        "aaaaaa" ++ "cccccccc" ++ "dddd" ++ "eeeeeeeeee" ++ "gggggggg" ++ "hhhh" ++ "iiiiiiiiii" ++ "ii" ++ "jj" ++ "kkk" ++
            "llllllllll" ++ "nnnnnnnnn" ++ "oooooooo" ++ "rrrrrr" ++ "ssssssss" ++ "tttttt" ++ "uuuuuuuuuuuu" ++ "ww" ++ "yyy" ++ "zzzzzz" ++ "s",
        "ĀāĂăĄąĆćĈĉĊċČčĎďĐđĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħĨĩĪīĬĭĮįİıĲĳĴĵĶķĸĹĺĻļĽľĿŀŁłŃńŅņŇňŉŊŋŌōŎŏŐőŒœŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŦŧŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžſ",
    );
}

test "every code point of both blocks: one ASCII letter, or itself for × ÷" {
    var cp: u21 = 0xC0;
    while (cp <= 0x17F) : (cp += 1) {
        var enc: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &enc);
        try testing.expectEqual(@as(usize, 2), n);
        var buf: [4]u8 = undefined;
        const f = foldInto(&buf, enc[0..n]);
        if (cp == 0xD7 or cp == 0xF7) {
            try testing.expectEqualSlices(u8, enc[0..n], f);
        } else {
            try testing.expectEqual(@as(usize, 1), f.len);
            try testing.expect(f[0] >= 'a' and f[0] <= 'z');
            try testing.expect(insideLetter(enc[0..n], 1));
        }
    }
}

test "case of the original letter" {
    const cases = [_]struct { s: []const u8, upper: bool }{
        .{ .s = "A", .upper = true },  .{ .s = "a", .upper = false },
        .{ .s = "É", .upper = true },
        .{ .s = "é", .upper = false },
        .{ .s = "Ñ", .upper = true },
        .{ .s = "ß", .upper = false },
        .{ .s = "Ÿ", .upper = true },
        .{ .s = "ÿ", .upper = false },
        .{ .s = "İ", .upper = true },
        .{ .s = "ı", .upper = false },
        .{ .s = "ĸ", .upper = false },
        .{ .s = "Ĺ", .upper = true },
        .{ .s = "Ł", .upper = true },
        .{ .s = "ł", .upper = false },
        .{ .s = "ŉ", .upper = false },
        .{ .s = "Ŋ", .upper = true },
        .{ .s = "Ž", .upper = true },
        .{ .s = "ž", .upper = false },
        .{ .s = "ſ", .upper = false },
        .{ .s = "Œ", .upper = true },
        .{ .s = "1", .upper = false },
    };
    for (cases) |c| {
        var i: usize = 0;
        const ch = next(c.s, &i);
        try testing.expectEqual(c.s.len, i);
        try testing.expectEqual(c.upper, ch.upper);
    }
    var buf: [16]u8 = undefined;
    var up: [16]bool = undefined;
    const n = foldCase(&buf, &up, "ÁrbolÑ");
    try testing.expectEqualStrings("arboln", buf[0..n]);
    try testing.expectEqualSlices(bool, &.{ true, false, false, false, false, true }, up[0..n]);
}

test "symbols never fold to letters" {
    for ([_][]const u8{ "×", "÷", "¿", "¡", "«", "»", "°", "ª", "µ", "€", "ж", "日本" }) |s| try expectFold(s, s);
    try expectFold("¿que?", "¿Qué?");
    try expectFold("3×4", "3×4");
}

test "invalid and truncated UTF-8 passes through" {
    try expectFold("\xC3", "\xC3");
    try expectFold("\xC3a", "\xC3A");
    try expectFold("\xC3a", "\xC3\xC3\xA1");
    try expectFold("\xA1", "\xA1");
    try expectFold("a\xC5", "Á\xC5");
    try expectFold("\xC4\xC4", "\xC4\xC4");
    try testing.expect(!insideLetter("\xA1", 0));
    try testing.expect(!insideLetter("×", 1));
}

test "folding is idempotent and never lengthens" {
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "Z", "é", "Ñ", "×", "\xC3", "\xA1", "\xC5", "ŉ", " ", "日", "ſ" };
    var s: [64]u8 = undefined;
    var once: [64]u8 = undefined;
    var twice: [64]u8 = undefined;
    for (0..5000) |_| {
        var n: usize = 0;
        while (n < 50) {
            const p = if (r.boolean()) pieces[r.uintLessThan(usize, pieces.len)] else &[_]u8{r.int(u8)};
            @memcpy(s[n .. n + p.len], p);
            n += p.len;
        }
        const f1 = foldInto(&once, s[0..n]);
        const f2 = foldInto(&twice, f1);
        try testing.expectEqualSlices(u8, f1, f2);
        try testing.expect(f1.len <= n);
        try testing.expectEqual(f1.len, foldedLen(s[0..n]));
    }
}

test "isAscii" {
    try testing.expect(isAscii(""));
    try testing.expect(isAscii("Cargo.toml"));
    try testing.expect(isAscii("a-much-longer-ascii-name_with_parts.tar.gz"));
    try testing.expect(!isAscii("español.txt"));
    try testing.expect(!isAscii("a-much-longer-ascii-name_with_parts.tar.gz\xC3"));
    try testing.expect(!isAscii("\x80"));
}

test "foldAlloc and a truncating buffer" {
    const f = try foldAlloc(testing.allocator, "ÑANDÚ y Acción");
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("nandu y accion", f);
    var small: [3]u8 = undefined;
    try testing.expectEqualStrings("acc", foldInto(&small, "Acción"));
}
