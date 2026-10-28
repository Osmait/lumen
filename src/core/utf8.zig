//! Cutting text that should be UTF-8 without splitting a character.

const std = @import("std");

/// Longest prefix of `s` that is valid UTF-8: everything before the first
/// sequence that is not. One pass (trying shorter and shorter prefixes
/// was quadratic: ~4M steps for a 4 KB preview with a stray byte midway).
pub fn validPrefix(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (i + n > s.len or !std.unicode.utf8ValidateSlice(s[i..][0..n])) break;
        i += n;
    }
    return s[0..i];
}

/// A window cut out of UTF-8 text at arbitrary bytes, made valid: without
/// the continuation bytes of a character cut at its start (at most three),
/// then its valid prefix.
pub fn validWindow(s: []const u8) []const u8 {
    var lo: usize = 0;
    while (lo < s.len and lo < 3 and isContinuation(s[lo])) lo += 1;
    return validPrefix(s[lo..]);
}

/// The longest length up to `max` that ends `s` between characters.
pub fn floorBoundary(s: []const u8, max: usize) usize {
    if (max >= s.len) return s.len;
    var n = max;
    // Cut before the lead byte of the character `max` falls in.
    while (n > 0 and isContinuation(s[n])) n -= 1;
    return n;
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// What validPrefix replaced, kept as the reference it must agree with.
fn validPrefixNaive(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(s[0..end])) end -= 1;
    return s[0..end];
}

test "validPrefix stops at the first invalid sequence" {
    try std.testing.expectEqualStrings("", validPrefix(""));
    try std.testing.expectEqualStrings("héllo", validPrefix("héllo"));
    try std.testing.expectEqualStrings("caf", validPrefix("caf\xc3"));
    try std.testing.expectEqualStrings("ab", validPrefix("ab\xffcd"));
    // Overlong and surrogate encodings are invalid, as std says.
    try std.testing.expectEqualStrings("a", validPrefix("a\xc0\x80"));
    try std.testing.expectEqualStrings("a", validPrefix("a\xed\xa0\x80"));
}

test "validPrefix agrees with the longest valid prefix on random bytes" {
    var prng: std.Random.DefaultPrng = .init(0x7e57);
    const r = prng.random();
    const pieces = [_][]const u8{ "a", "é", "€", "😀", "\x80", "\xc3", "\xe2\x82", "\xff", "\xed\xa0\x80" };
    var buf: [64]u8 = undefined;
    for (0..5000) |_| {
        var len: usize = 0;
        while (true) {
            const p = pieces[r.uintLessThan(usize, pieces.len)];
            if (len + p.len > buf.len) break;
            @memcpy(buf[len..][0..p.len], p);
            len += p.len;
            if (r.uintLessThan(u8, 8) == 0) break;
        }
        const s = buf[0..len];
        try std.testing.expectEqualStrings(validPrefixNaive(s), validPrefix(s));
    }
}

test "validWindow and floorBoundary never split a character" {
    // "€" is e2 82 ac: a window starting inside it drops the rest of it.
    try std.testing.expectEqualStrings("x", validWindow("\x82\xacx"));
    try std.testing.expectEqualStrings("x€", validWindow("x€\xe2"));
    try std.testing.expectEqual(@as(usize, 1), floorBoundary("x€", 2));
    try std.testing.expectEqual(@as(usize, 1), floorBoundary("x€", 3));
    try std.testing.expectEqual(@as(usize, 4), floorBoundary("x€", 4));
    try std.testing.expectEqual(@as(usize, 4), floorBoundary("x€", 9));
}
