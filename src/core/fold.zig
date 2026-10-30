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
    var table: [192]bool = undefined;
    for (&table, 0..) |*upper, i| upper.* = upperCodePoint(@intCast(0xC0 + i));
    break :blk table;
};

/// The UTF-8 lead bytes of the letters that fold: U+00C0..U+017F.
const lead_first = 0xC3;
const lead_last = 0xC5;

comptime {
    // Every continuation byte of every foldable lead has its entry.
    std.debug.assert(letters.len == (lead_last - lead_first + 1) * 64);
}

/// One folded character and what it was.
pub const Char = struct {
    /// The folded byte.
    byte: u8,
    /// The original was an uppercase letter (ASCII or accented): camelCase
    /// bonuses look at this, the folded byte has lost it.
    upper: bool,
};

fn isFoldableLead(byte: u8) bool {
    return byte >= lead_first and byte <= lead_last;
}

/// Index into `letters` of the two-byte letter at `text[pos]`, or null when
/// the bytes there are not a foldable letter.
inline fn letterAt(text: []const u8, pos: usize) ?usize {
    const lead = text[pos];
    if (!isFoldableLead(lead)) return null;
    if (pos + 1 == text.len) return null;
    const continuation = text[pos + 1];
    if (continuation & 0xC0 != 0x80) return null;
    const letter_index = @as(usize, lead - lead_first) * 64 + (continuation & 0x3F);
    return if (letters[letter_index] != 0) letter_index else null;
}

/// Folded character at `text[pos.*]`; advances `pos` past it (by 1 or 2
/// bytes). `pos.*` must be < `text.len`.
pub inline fn step(text: []const u8, pos: *usize) u8 {
    const byte = text[pos.*];
    if (isFoldableLead(byte)) {
        if (letterAt(text, pos.*)) |letter_index| {
            pos.* += 2;
            return letters[letter_index];
        }
    }
    pos.* += 1;
    return std.ascii.toLower(byte);
}

/// Like `step`, also telling whether the original was uppercase.
pub inline fn next(text: []const u8, pos: *usize) Char {
    const byte = text[pos.*];
    if (isFoldableLead(byte)) {
        if (letterAt(text, pos.*)) |letter_index| {
            pos.* += 2;
            return .{ .byte = letters[letter_index], .upper = uppers[letter_index] };
        }
    }
    pos.* += 1;
    return .{ .byte = std.ascii.toLower(byte), .upper = std.ascii.isUpper(byte) };
}

/// True when the second byte of a two-byte foldable letter is at
/// `text[pos]`: not the start of a folded character.
pub fn insideLetter(text: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    if (text[pos] & 0xC0 != 0x80) return false;
    return letterAt(text, pos - 1) != null;
}

/// Writes the folded `text` into `buf`; returns the written part. Truncated
/// to `buf.len` folded characters if `text` folds to more.
pub fn foldInto(buf: []u8, text: []const u8) []u8 {
    var pos: usize = 0;
    var folded_len: usize = 0;
    while (pos < text.len and folded_len < buf.len) : (folded_len += 1) {
        buf[folded_len] = step(text, &pos);
    }
    // A folded character is never longer than the original one.
    std.debug.assert(folded_len <= text.len);
    return buf[0..folded_len];
}

/// Like `foldInto`, also recording in `upper` (as long as `buf`) which
/// folded characters were uppercase letters. Returns the folded length.
pub fn foldCase(buf: []u8, upper: []bool, text: []const u8) usize {
    std.debug.assert(upper.len >= buf.len);
    var pos: usize = 0;
    var folded_len: usize = 0;
    while (pos < text.len and folded_len < buf.len) : (folded_len += 1) {
        const char = next(text, &pos);
        buf[folded_len] = char.byte;
        upper[folded_len] = char.upper;
    }
    std.debug.assert(folded_len <= text.len);
    return folded_len;
}

/// The folded string. Caller owns it.
pub fn foldAlloc(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try gpa.alloc(u8, text.len);
    errdefer gpa.free(buf);
    return gpa.realloc(buf, foldInto(buf, text).len);
}

/// Folded characters in `text` (its folded length).
pub fn foldedLen(text: []const u8) usize {
    var pos: usize = 0;
    var folded_len: usize = 0;
    while (pos < text.len) : (folded_len += 1) _ = step(text, &pos);
    return folded_len;
}

/// Pure ASCII: folding is only lowercasing, byte for byte.
pub fn isAscii(text: []const u8) bool {
    const Block = @Vector(16, u8);
    var pos: usize = 0;
    while (pos + 16 <= text.len) : (pos += 16) {
        const block: Block = text[pos..][0..16].*;
        if (@reduce(.Or, block) >= 0x80) return false;
    }
    var bits: u8 = 0;
    for (text[pos..]) |byte| bits |= byte;
    return bits < 0x80;
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
    for ([_][]const u8{
        "×",
        "÷",
        "¿",
        "¡",
        "«",
        "»",
        "°",
        "ª",
        "µ",
        "€",
        "ж",
        "日本",
    }) |s| try expectFold(s, s);
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
    const random = prng.random();
    const pieces = [_][]const u8{ "a", "Z", "é", "Ñ", "×", "\xC3", "\xA1", "\xC5", "ŉ", " ", "日", "ſ" };
    var text: [64]u8 = undefined;
    var once: [64]u8 = undefined;
    var twice: [64]u8 = undefined;
    for (0..5000) |_| {
        var len: usize = 0;
        while (len < 50) {
            var random_byte: [1]u8 = undefined;
            const piece = if (random.boolean()) blk: {
                break :blk pieces[random.uintLessThan(usize, pieces.len)];
            } else blk: {
                random_byte[0] = random.int(u8);
                break :blk &random_byte;
            };
            @memcpy(text[len .. len + piece.len], piece);
            len += piece.len;
        }
        const folded_once = foldInto(&once, text[0..len]);
        const folded_twice = foldInto(&twice, folded_once);
        try testing.expectEqualSlices(u8, folded_once, folded_twice);
        try testing.expect(folded_once.len <= len);
        try testing.expectEqual(folded_once.len, foldedLen(text[0..len]));
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
