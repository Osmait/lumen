//! Cutting text that should be UTF-8 without splitting a character.

const std = @import("std");
const assert = std.debug.assert;

/// Longest prefix of `text` that is valid UTF-8: everything before the
/// first sequence that is not. One pass (trying shorter and shorter
/// prefixes was quadratic: ~4M steps for a 4 KB preview with a stray byte
/// midway).
pub fn validPrefix(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[end]) catch break;
        if (end + sequence_len > text.len) break;
        if (!std.unicode.utf8ValidateSlice(text[end..][0..sequence_len])) break;
        end += sequence_len;
    }
    return text[0..end];
}

/// A UTF-8 character is at most four bytes: a window cut inside one starts
/// with at most three of its continuation bytes.
const continuation_bytes_max = 3;

/// A window cut out of UTF-8 text at arbitrary bytes, made valid: without
/// the continuation bytes of a character cut at its start, then its valid
/// prefix.
pub fn validWindow(text: []const u8) []const u8 {
    var skip: usize = 0;
    while (skip < text.len and skip < continuation_bytes_max and isContinuation(text[skip])) {
        skip += 1;
    }
    return validPrefix(text[skip..]);
}

/// The longest length up to `len_max` that ends `text` between characters.
pub fn floorBoundary(text: []const u8, len_max: usize) usize {
    if (len_max >= text.len) return text.len;
    var end = len_max;
    // Cut before the lead byte of the character `len_max` falls in.
    while (end > 0 and isContinuation(text[end])) end -= 1;
    assert(end <= len_max);
    assert(!isContinuation(text[end]));
    return end;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// What validPrefix replaced, kept as the reference it must agree with.
fn validPrefixNaive(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
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
    const random = prng.random();
    const pieces = [_][]const u8{ "a", "é", "€", "😀", "\x80", "\xc3", "\xe2\x82", "\xff", "\xed\xa0\x80" };
    var text_buffer: [64]u8 = undefined;
    for (0..5000) |_| {
        var text_len: usize = 0;
        while (true) {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            if (text_len + piece.len > text_buffer.len) break;
            @memcpy(text_buffer[text_len..][0..piece.len], piece);
            text_len += piece.len;
            if (random.uintLessThan(u8, 8) == 0) break;
        }
        const text = text_buffer[0..text_len];
        try std.testing.expectEqualStrings(validPrefixNaive(text), validPrefix(text));
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
