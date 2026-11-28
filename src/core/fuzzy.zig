//! Fuzzy matching for the search bar. A query matches when it is a substring
//! of the candidate, or when its letters can be taken in order from word
//! starts and runs: "vsc" finds "Visual Studio Code", "left" does not find
//! "File Manager". Case- and accent-insensitive (`fold.zig`): "configuracion"
//! finds "Configuración"; other bytes compare exactly. Queries longer than
//! `fuzzy_query_chars_max` match as substrings only.

const std = @import("std");
const assert = std.debug.assert;
const fold = @import("fold.zig");

pub const no_match: i32 = std.math.minInt(i32);

/// Longest text (and query) compared, in folded characters; the rest of a
/// longer one is ignored.
pub const text_chars_max = 2048;

/// A query folded once (`prepare`), for scoring it against many texts:
/// dmenu folded it again for every field of every line, up to 400 000
/// times per keystroke on the GTK thread.
pub const Query = struct {
    folded: []const u8,
};

/// `query` folded into `buffer`, ready for `scoreQuery` and
/// `scoreFieldsQuery`; it lives as long as `buffer`.
pub fn prepare(buffer: *[text_chars_max]u8, query: []const u8) Query {
    return .{ .folded = fold.foldInto(buffer, query) };
}

/// What each kind of match is worth. A substring starts at `substring_base`
/// and loses a point per character before it; a fuzzy match earns points per
/// letter taken.
const Score = struct {
    const substring_base = 1000;
    const substring_position_penalty_max = 200;
    const substring_prefix_bonus = 500;
    const substring_boundary_bonus = 250;
    const substring_whole_bonus = 300;

    const fuzzy_letter = 10;
    const fuzzy_boundary_bonus = 40;
    const fuzzy_run_bonus = 30;
    const fuzzy_gap_penalty_max = 20;
    const fuzzy_first_penalty_max = 50;

    /// A later field (keywords, subtitle) costs this much per position, so
    /// a title hit wins.
    const field_rank_penalty = 150;

    /// The lowest score a substring match can get.
    const substring_floor = substring_base - substring_position_penalty_max;
    /// The most one letter of a fuzzy match can earn.
    const fuzzy_letter_max = fuzzy_letter + fuzzy_boundary_bonus + fuzzy_run_bonus;
};

/// A substring match outranks every fuzzy match for queries of up to this
/// many folded characters. Longer queries are rare in a launcher, and the
/// rule is not kept for them: a fuzzy match of ten word starts or more can
/// tie with, or beat, a substring far from the start of the text.
pub const substring_outranks_fuzzy_chars_max =
    (Score.substring_floor - 1) / Score.fuzzy_letter_max;

/// Longer queries, in folded characters, match as substrings only. The
/// fuzzy alignment costs query × text: a pasted 1000-character query took
/// 8 ms per 2 KB line, and dmenu scores every line on the GTK thread.
pub const fuzzy_query_chars_max = 64;

comptime {
    assert(fuzzy_query_chars_max > substring_outranks_fuzzy_chars_max);
    assert(substring_outranks_fuzzy_chars_max >= 3);
    assert(substring_outranks_fuzzy_chars_max * Score.fuzzy_letter_max < Score.substring_floor);
    assert((substring_outranks_fuzzy_chars_max + 1) * Score.fuzzy_letter_max >=
        Score.substring_floor);
}

/// Score of `query_in` against `text_in`, or `no_match`. An empty query
/// matches everything with score 0.
pub fn score(query_in: []const u8, text_in: []const u8) i32 {
    var query_buffer: [text_chars_max]u8 = undefined;
    return scoreQuery(prepare(&query_buffer, query_in), text_in);
}

/// `score` with the query folded already.
pub fn scoreQuery(query_prepared: Query, text_in: []const u8) i32 {
    const query = query_prepared.folded;
    if (query.len == 0) return 0;
    // Both sides folded; `upper` keeps the case the folded text lost, for
    // camelCase boundaries.
    var text_buffer: [text_chars_max]u8 = undefined;
    var upper_buffer: [text_chars_max]bool = undefined;
    const text_len = fold.foldCase(&text_buffer, &upper_buffer, text_in);
    const text = text_buffer[0..text_len];
    return scoreFolded(query, text, Cased{ .upper = upper_buffer[0..text_len] });
}

/// A text folded once (`Text.init`), for scoring many queries against it:
/// the clipboard view folded each of up to 5,000 entries of 2,000 bytes
/// again on every keystroke (MYP-613). It scores as the text it was made
/// from does with `scoreQuery`.
pub const Text = struct {
    /// Folded, at most `text_chars_max` characters, as `scoreQuery` cuts.
    folded: []const u8,
    /// Bit `i % 64` of word `i / 64`: a word starts at `folded[i]`
    /// (`isBoundary`), worked out once from the case the folding lost.
    starts: []const u64,

    /// `text_in` folded, in `gpa`'s memory (an arena's, typically).
    pub fn init(gpa: std.mem.Allocator, text_in: []const u8) std.mem.Allocator.Error!Text {
        var text_buffer: [text_chars_max]u8 = undefined;
        var upper_buffer: [text_chars_max]bool = undefined;
        const text_len = fold.foldCase(&text_buffer, &upper_buffer, text_in);
        const folded = try gpa.dupe(u8, text_buffer[0..text_len]);
        errdefer gpa.free(folded);
        const starts = try gpa.alloc(u64, std.math.divCeil(usize, text_len, 64) catch unreachable);
        startsOf(folded, upper_buffer[0..text_len], starts);
        return .{ .folded = folded, .starts = starts };
    }

    /// `isBoundary` at each place of `text`, into `starts`' bits, 64 places
    /// at a time: one by one, it took longer than folding the text.
    fn startsOf(text: []const u8, upper: []const bool, starts: []u64) void {
        assert(upper.len == text.len);
        assert(starts.len * 64 >= text.len and starts.len * 64 < text.len + 64);
        const Bytes = @Vector(64, u8);
        const Bits = @Vector(64, u1);
        for (starts, 0..) |*word, word_index| {
            const first = word_index * 64;
            if (first == 0 or first + 64 > text.len) {
                word.* = 0;
                for (first..@min(first + 64, text.len)) |i| {
                    const start: u64 = @intFromBool(isBoundary(text, upper, i));
                    word.* |= start << @intCast(i - first);
                }
                continue;
            }
            // The character before each place, and the case of both.
            const before: Bytes = text[first - 1 ..][0..64].*;
            // In memory a bool is a byte, 0 or 1.
            const upper_bytes: [*]const u8 = @ptrCast(upper.ptr);
            const upper_before: Bits = @truncate(@as(Bytes, upper_bytes[first - 1 ..][0..64].*));
            const upper_here: Bits = @truncate(@as(Bytes, upper_bytes[first..][0..64].*));
            const lower = bitsOf(before >= @as(Bytes, @splat('a'))) &
                bitsOf(before <= @as(Bytes, @splat('z')));
            const capital = bitsOf(before >= @as(Bytes, @splat('A'))) &
                bitsOf(before <= @as(Bytes, @splat('Z')));
            const digit = bitsOf(before >= @as(Bytes, @splat('0'))) &
                bitsOf(before <= @as(Bytes, @splat('9')));
            const ascii = bitsOf(before < @as(Bytes, @splat(0x80)));
            const separator = ascii & ~(lower | capital | digit);
            const camel = lower & ~upper_before & upper_here;
            word.* = @bitCast(separator | camel);
        }
    }

    inline fn bitsOf(comparison: @Vector(64, bool)) @Vector(64, u1) {
        return @intFromBool(comparison);
    }

    pub fn deinit(text: *Text, gpa: std.mem.Allocator) void {
        gpa.free(text.folded);
        gpa.free(text.starts);
        text.* = undefined;
    }
};

/// `scoreQuery` against a text folded already.
pub fn scoreText(query_prepared: Query, text: *const Text) i32 {
    const query = query_prepared.folded;
    if (query.len == 0) return 0;
    return scoreFolded(query, text.folded, Known{ .starts = text.starts });
}

/// Word starts from the case of the original text (`isBoundary`).
const Cased = struct {
    upper: []const bool,

    inline fn at(cased: Cased, text: []const u8, index: usize) bool {
        return isBoundary(text, cased.upper, index);
    }
};

/// Word starts worked out already (`Text`).
const Known = struct {
    starts: []const u64,

    inline fn at(known: Known, _: []const u8, index: usize) bool {
        return known.starts[index / 64] >> @intCast(index % 64) & 1 != 0;
    }
};

/// `query` (not empty) against `text`, both folded; `starts.at(text, k)`
/// says whether a word starts at `text[k]` (`Cased` or `Known`).
inline fn scoreFolded(query: []const u8, text: []const u8, starts: anytype) i32 {
    assert(query.len > 0);
    if (query.len > text.len) return no_match;

    // A plain substring is the strongest signal (see
    // `substring_outranks_fuzzy_chars_max`), and a prefix more so. An
    // earlier mid-word hit must not hide a word-start hit, but none after
    // the first word-start hit beats it (each is further from the start):
    // the occurrences are scored up to that one.
    if (std.mem.find(u8, text, query)) |first_start| {
        var result = scoreSubstring(text, starts, query.len, first_start);
        var substring_start = first_start;
        while (substring_start > 0 and !starts.at(text, substring_start)) {
            substring_start = std.mem.findPos(u8, text, substring_start + 1, query) orelse break;
            result = @max(result, scoreSubstring(text, starts, query.len, substring_start));
        }
        assert(result >= Score.substring_floor);
        return result;
    }
    if (query.len > fuzzy_query_chars_max) return no_match;
    // Most texts do not even hold the letters in order: one pass says so,
    // before `scoreFuzzy`'s 24 KB frame is set up.
    if (!isSubsequence(query, text)) return no_match;
    const result = scoreFuzzy(text, starts, query);
    if (result != no_match) {
        const letters: i32 = @intCast(query.len);
        assert(result <= letters * Score.fuzzy_letter_max);
    }
    return result;
}

fn scoreSubstring(
    text: []const u8,
    starts: anytype,
    query_len: usize,
    substring_start: usize,
) i32 {
    const position_penalty: i32 = @intCast(
        @min(substring_start, Score.substring_position_penalty_max),
    );
    var result: i32 = Score.substring_base - position_penalty;
    if (substring_start == 0) {
        result += Score.substring_prefix_bonus;
    } else if (starts.at(text, substring_start)) {
        result += Score.substring_boundary_bonus;
    }
    if (query_len == text.len) result += Score.substring_whole_bonus;
    return result;
}

/// The best fuzzy alignment of `query` in `text`: every letter at a word
/// start or right after the previous one (a run), scored as `Score` says.
/// Taking each letter at its first such place missed matches: "ted" in
/// "Text Editor" took the "e" of "Text" and found no "d" after it.
///
/// Dynamic programming over (query letter, text position), one row per
/// letter: the previous row holds the best score with the previous letter
/// at each place it reached. A gap costs `min(distance,
/// fuzzy_gap_penalty_max)`, so only the places reached in the last
/// `fuzzy_gap_penalty_max` positions need looking at one by one; anything
/// further costs the same, and its best is kept as it goes (`far_best`).
/// Each row visits only the places its letter is, from just after the
/// previous row's first reached one (MYP-188), and holds only the places
/// reached: a row as long as the text, cleared and walked for every
/// letter, made the clipboard's long entries cost ~50 us each (MYP-613).
///
/// Out of line: its rows are 24 KB, which every call of an inlined
/// `scoreQuery` set up, matching or not.
noinline fn scoreFuzzy(text: []const u8, starts: anytype, query: []const u8) i32 {
    assert(query.len > 0);
    assert(text.len <= text_chars_max);
    var rows: [2]Row = undefined;
    var previous = &rows[0];
    var current = &rows[1];
    previous.len = 0;
    var k_first = std.mem.findScalar(u8, text, query[0]);
    while (k_first) |k| : (k_first = std.mem.findScalarPos(u8, text, k + 1, query[0])) {
        if (!starts.at(text, k)) continue;
        const first_penalty: i32 = @intCast(@min(k, Score.fuzzy_first_penalty_max));
        previous.append(k, Score.fuzzy_letter + Score.fuzzy_boundary_bonus - first_penalty);
    }
    if (previous.len == 0) return no_match;
    for (query[1..]) |letter| {
        rowFrom(text, starts, letter, previous, current);
        // No place for this letter: none for the ones after it either.
        if (current.len == 0) return no_match;
        std.mem.swap(*Row, &previous, &current);
    }
    var result: i32 = no_match;
    for (previous.scores[0..previous.len]) |score_at| result = @max(result, score_at);
    assert(result != no_match);
    return result;
}

/// The places one letter of the query reached in the text, in order, and
/// the best score of the letters up to it with it there.
const Row = struct {
    places: [text_chars_max]u16,
    scores: [text_chars_max]i32,
    len: usize,

    comptime {
        assert(text_chars_max <= std.math.maxInt(u16) + 1);
    }

    inline fn append(row: *Row, place: usize, score_at: i32) void {
        assert(row.len < text_chars_max);
        assert(row.len == 0 or row.places[row.len - 1] < place);
        assert(score_at != no_match);
        row.places[row.len] = @intCast(place);
        row.scores[row.len] = score_at;
        row.len += 1;
    }
};

/// One row of `scoreFuzzy`: `letter` at each of its places in `text` after
/// the first one the previous letter reached, given that letter's row.
inline fn rowFrom(
    text: []const u8,
    starts: anytype,
    letter: u8,
    previous: *const Row,
    current: *Row,
) void {
    assert(previous.len > 0);
    const unreached = no_match;
    const gap_max = Score.fuzzy_gap_penalty_max;
    current.len = 0;
    // The best of `previous` before `far_end`, the places whose gap costs
    // the most: everything at or before `k - gap_max`.
    var far_best: i32 = unreached;
    var far_end: usize = 0;
    const start = @as(usize, previous.places[0]) + 1;
    var next = if (start < text.len) std.mem.findScalarPos(u8, text, start, letter) else null;
    while (next) |k| : (next = std.mem.findScalarPos(u8, text, k + 1, letter)) {
        while (far_end < previous.len and previous.places[far_end] + gap_max <= k) {
            far_best = @max(far_best, previous.scores[far_end]);
            far_end += 1;
        }
        const boundary = starts.at(text, k);
        var best: i32 = unreached;
        if (boundary and far_best != unreached) best = far_best - gap_max;
        // The places reached less than `gap_max` before: right before is a
        // run, 2 to gap_max - 1 before a gap, taken only at a word start.
        var near = far_end;
        while (near < previous.len and previous.places[near] < k) : (near += 1) {
            const distance = k - previous.places[near];
            if (distance == 1) {
                best = @max(best, previous.scores[near] + Score.fuzzy_run_bonus);
            } else if (boundary) {
                best = @max(best, previous.scores[near] - @as(i32, @intCast(distance)));
            }
        }
        if (best == unreached) continue;
        const boundary_bonus: i32 = if (boundary) Score.fuzzy_boundary_bonus else 0;
        current.append(k, best + Score.fuzzy_letter + boundary_bonus);
    }
}

/// Whether the letters of `query` appear in `text` in order. One search
/// per letter: a loop over the text advancing the query on each match was
/// compiled branch-free, every byte waiting on the previous comparison, and
/// made a launcher list that matches nothing 25% slower (MYP-188).
fn isSubsequence(query: []const u8, text: []const u8) bool {
    var position: usize = 0;
    for (query) |letter| {
        const found = std.mem.findScalarPos(u8, text, position, letter) orelse return false;
        position = found + 1;
    }
    return true;
}

/// Best score over several fields (title, keywords, subtitle). Later fields
/// count for less so a title hit wins.
pub fn scoreFields(query: []const u8, fields: []const []const u8) i32 {
    var query_buffer: [text_chars_max]u8 = undefined;
    return scoreFieldsQuery(prepare(&query_buffer, query), fields);
}

/// `scoreFields` with the query folded already.
pub fn scoreFieldsQuery(query: Query, fields: []const []const u8) i32 {
    var best: i32 = no_match;
    for (fields, 0..) |field, field_index| {
        const raw = scoreQuery(query, field);
        if (raw == no_match) continue;
        const rank: i32 = @intCast(field_index);
        best = @max(best, raw - rank * Score.field_rank_penalty);
    }
    return best;
}

/// On folded `text`: after a separator, or a capital after a small letter
/// in the original ("fileManager", "ÁrbolÉpico"). A separator is any ASCII
/// byte that is not a letter or digit (a tab, "(", "[", a quote, ",", "&"),
/// as the file index's matcher has it (`index/fine.zig`); bytes of UTF-8
/// sequences count as letters (MYP-550).
fn isBoundary(text: []const u8, upper: []const bool, index: usize) bool {
    if (index == 0) return true;
    const before = text[index - 1];
    if (before < 0x80 and !std.ascii.isAlphanumeric(before)) return true;
    return std.ascii.isLower(before) and !upper[index - 1] and upper[index];
}

test "word starts and runs" {
    try std.testing.expect(score("mfi", "Mozilla Firefox") > 0);
    try std.testing.expect(score("vsc", "Visual Studio Code") > 0);
    try std.testing.expectEqual(no_match, score("xff", "Firefox"));
    try std.testing.expectEqual(no_match, score("left", "File Manager"));
}

test "any ASCII symbol starts a word (MYP-550)" {
    try std.testing.expect(score("st", "123\tsome text") > 0);
    try std.testing.expect(score("code insiders", "Visual Studio Code (Insiders)") > 0);
    try std.testing.expect(score("rf", "Report (final).docx") > 0);
    try std.testing.expect(score("pw", "[Proton] Witcher") > 0);
    try std.testing.expect(score("gc", "\"git commit\"") > 0);
    try std.testing.expect(score("tg", "Tom&Gerry") > 0);
    try std.testing.expect(score("ab", "a,b") > 0);
    // Letters and digits still join a word; UTF-8 bytes count as letters.
    try std.testing.expectEqual(no_match, score("ab", "a1b"));
    try std.testing.expectEqual(no_match, score("ab", "a×b"));
}

test "prefix beats middle substring beats scattered" {
    const prefix = score("fire", "Mozilla Firefox");
    const middle = score("fox", "Mozilla Firefox");
    const scattered = score("mfi", "Mozilla Firefox");
    try std.testing.expect(prefix > middle);
    try std.testing.expect(middle > scattered);
}

test "a substring outranks a fuzzy match up to the documented query length" {
    // The best fuzzy case: every letter a word start, no gaps to pay for.
    const words = "a b c d e f g h i j k l m n o p q r s t u v w x y z";
    const short = "abcdefghi"[0..substring_outranks_fuzzy_chars_max];
    // The substring as far from the start as the penalty reaches, and past.
    var far_text: [300 + short.len]u8 = undefined;
    @memset(far_text[0..300], 'x');
    @memcpy(far_text[300..], short);
    const substring_far = score(short, &far_text);
    const fuzzy_best = score(short, words);
    try std.testing.expect(substring_far > fuzzy_best);
}

test "fuzzy finds the best alignment, not the first" {
    // The "e" of "Text" is a run but leaves no "d" after it; the one of
    // "Editor" does.
    try std.testing.expect(score("ted", "Text Editor") > 0);
    try std.testing.expect(score("abc", "a_xb ab_c") > 0);
}

test "a long query matches as a substring only (MYP-463)" {
    // "a b c … a b c …": every letter at a word start.
    var word_starts: [2 * (fuzzy_query_chars_max + 1)]u8 = undefined;
    var letters: [fuzzy_query_chars_max + 1]u8 = undefined;
    for (&letters, 0..) |*letter, i| {
        letter.* = 'a' + @as(u8, @intCast(i % 26));
        word_starts[2 * i] = letter.*;
        word_starts[2 * i + 1] = ' ';
    }
    // 64 letters taken from word starts still match fuzzily, 65 do not.
    try std.testing.expect(score(letters[0..fuzzy_query_chars_max], &word_starts) > 0);
    try std.testing.expectEqual(no_match, score(&letters, &word_starts));
    // A substring of any length still matches.
    var long_query: [1000]u8 = undefined;
    @memset(&long_query, 'a');
    var long_line: [1200]u8 = undefined;
    @memset(&long_line, 'x');
    @memcpy(long_line[100..][0..long_query.len], &long_query);
    try std.testing.expect(score(&long_query, &long_line) > 0);
}

test "letters inside a word only match as a run" {
    try std.testing.expect(score("vsc", "Visual Studio Code") > 0);
    try std.testing.expectEqual(no_match, score("vsc", "Viscous"));
}

test "a prepared query scores as the raw one does" {
    var query_buffer: [text_chars_max]u8 = undefined;
    const query = prepare(&query_buffer, "CONFIGURACIÓN");
    const fields = [_][]const u8{ "Ajustes", "Configuración del sistema" };
    try std.testing.expectEqual(
        scoreFields("CONFIGURACIÓN", &fields),
        scoreFieldsQuery(query, &fields),
    );
    try std.testing.expectEqual(
        score("vsc", "Visual Studio Code"),
        scoreQuery(prepare(&query_buffer, "vsc"), "Visual Studio Code"),
    );
    try std.testing.expectEqual(@as(i32, 0), scoreQuery(prepare(&query_buffer, ""), "anything"));
}

test "title outranks subtitle" {
    const fields_title = [_][]const u8{ "Terminal", "Kitty" };
    const fields_subtitle = [_][]const u8{ "Kitty", "Terminal" };
    const title_score = scoreFields("term", &fields_title);
    try std.testing.expect(title_score > scoreFields("term", &fields_subtitle));
}

test "accents and case fold both ways" {
    try std.testing.expect(score("configuracion", "Configuración") > 0);
    try std.testing.expect(score("CONFIGURACIÓN", "Configuracion") > 0);
    try std.testing.expect(score("configuración", "Configuración del sistema") > 0);
    const folded_one_way = score("configuracion", "Configuración");
    const folded_other_way = score("Configuración", "configuracion");
    try std.testing.expectEqual(folded_one_way, folded_other_way);
    try std.testing.expect(score("nandu", "Ñandú") > 0);
    // Word starts survive folding: "ae" = Árbol Épico, camelCase too.
    try std.testing.expect(score("ae", "Árbol Épico") > 0);
    try std.testing.expect(score("ae", "árbolÉpico") > 0);
    try std.testing.expectEqual(no_match, score("ae", "Árbolepico"));
    // Symbols are not letters.
    try std.testing.expectEqual(no_match, score("x", "×"));
    try std.testing.expect(score("×", "3×4") > 0);
}

test "substring scoring picks the strongest occurrence" {
    try std.testing.expect(score("test", "src/latest/test_main.zig") > score("test", "src/contest.zig"));
    try std.testing.expect(score("code", "Xcode Code") > score("code", "Xcode mode"));
}

test "a text folded once scores as the text does (MYP-613)" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(613);
    const random = prng.random();
    // Capitals, accents (two bytes, folded to one), separators, and texts
    // past `text_chars_max`, which both cut alike.
    const pieces = [_][]const u8{ "a", "b", "C", "é", "É", "ñ", " ", "-", "/", "x", "Ab", "×" };
    const query_letters = "abcexn ";
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..3_000) |round| {
        raw.clearRetainingCapacity();
        const pieces_count = if (round % 100 == 0)
            text_chars_max + random.uintAtMost(usize, 64)
        else
            random.uintAtMost(usize, 60);
        for (0..pieces_count) |_| {
            try raw.appendSlice(gpa, pieces[random.uintLessThan(usize, pieces.len)]);
        }
        var text: Text = try .init(gpa, raw.items);
        defer text.deinit(gpa);
        var query_raw: [5]u8 = undefined;
        const query_len = random.intRangeAtMost(usize, 1, query_raw.len);
        for (query_raw[0..query_len]) |*char| {
            char.* = query_letters[random.uintLessThan(usize, query_letters.len)];
        }
        var query_buffer: [text_chars_max]u8 = undefined;
        const query = prepare(&query_buffer, query_raw[0..query_len]);
        try std.testing.expectEqual(scoreQuery(query, raw.items), scoreText(query, &text));
    }
    var empty: Text = try .init(gpa, "");
    defer empty.deinit(gpa);
    var query_buffer: [text_chars_max]u8 = undefined;
    try std.testing.expectEqual(no_match, scoreText(prepare(&query_buffer, "a"), &empty));
    try std.testing.expectEqual(@as(i32, 0), scoreText(prepare(&query_buffer, ""), &empty));
}

test "a substring scores its best occurrence, looked for up to the first word start" {
    var prng = std.Random.DefaultPrng.init(6130);
    const random = prng.random();
    const alphabet = "abAB _";
    for (0..20_000) |_| {
        var raw: [40]u8 = undefined;
        const raw_len = random.uintAtMost(usize, raw.len);
        for (raw[0..raw_len]) |*char| char.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        var query_raw: [3]u8 = undefined;
        const query_len = random.intRangeAtMost(usize, 1, query_raw.len);
        for (query_raw[0..query_len]) |*char| char.* = "ab"[random.uintLessThan(usize, 2)];
        const query = query_raw[0..query_len];
        // Every occurrence scored, as before the search stopped early.
        var text_buffer: [text_chars_max]u8 = undefined;
        var upper_buffer: [text_chars_max]bool = undefined;
        const text_len = fold.foldCase(&text_buffer, &upper_buffer, raw[0..raw_len]);
        const text = text_buffer[0..text_len];
        const cased: Cased = .{ .upper = upper_buffer[0..text_len] };
        var expected: i32 = no_match;
        var from: usize = 0;
        while (std.mem.findPos(u8, text, from, query)) |start| : (from = start + 1) {
            expected = @max(expected, scoreSubstring(text, cased, query.len, start));
        }
        if (expected == no_match) continue;
        try std.testing.expectEqual(expected, score(query, raw[0..raw_len]));
    }
}

test "the DP scores as the one that visited every position (MYP-188)" {
    var prng = std.Random.DefaultPrng.init(188);
    const random = prng.random();
    const alphabet = "aabbcdeAEB -_./";
    const query_letters = "abcde";
    for (0..20_000) |_| {
        var raw: [48]u8 = undefined;
        const raw_len = random.uintAtMost(usize, raw.len);
        for (raw[0..raw_len]) |*char| char.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        var query_buffer: [6]u8 = undefined;
        const query_len = random.intRangeAtMost(usize, 1, query_buffer.len);
        for (query_buffer[0..query_len]) |*char| {
            char.* = query_letters[random.uintLessThan(usize, query_letters.len)];
        }
        const query = query_buffer[0..query_len];
        var text_buffer: [text_chars_max]u8 = undefined;
        var upper_buffer: [text_chars_max]bool = undefined;
        const text_len = fold.foldCase(&text_buffer, &upper_buffer, raw[0..raw_len]);
        const text = text_buffer[0..text_len];
        const upper = upper_buffer[0..text_len];
        if (query.len > text.len or !isSubsequence(query, text)) continue;
        try std.testing.expectEqual(
            scoreFuzzyReference(text, upper, query),
            scoreFuzzy(text, Cased{ .upper = upper }, query),
        );
    }
}

/// `scoreFuzzy` before MYP-188, visiting every position: the reference
/// the faster one must match.
fn scoreFuzzyReference(text: []const u8, upper: []const bool, query: []const u8) i32 {
    assert(query.len > 0);
    assert(text.len <= text_chars_max);
    // Most texts do not even hold the letters in order: one pass says so.
    if (!isSubsequence(query, text)) return no_match;
    const unreached = no_match;
    var rows: [2][text_chars_max]i32 = undefined;
    var previous = &rows[0];
    var current = &rows[1];
    for (text, 0..) |char, k| {
        previous[k] = unreached;
        if (char != query[0] or !isBoundary(text, upper, k)) continue;
        const first_penalty: i32 = @intCast(@min(k, Score.fuzzy_first_penalty_max));
        previous[k] = Score.fuzzy_letter + Score.fuzzy_boundary_bonus - first_penalty;
    }
    const gap_max = Score.fuzzy_gap_penalty_max;
    for (query[1..]) |letter| {
        var far_best: i32 = unreached;
        var reached = false;
        for (text, 0..) |char, k| {
            // `j = k - gap_max` joins the positions whose gap costs the most.
            if (k >= gap_max) far_best = @max(far_best, previous[k - gap_max]);
            current[k] = unreached;
            if (char != letter) continue;
            var best: i32 = unreached;
            if (k > 0 and previous[k - 1] != unreached) {
                best = previous[k - 1] + Score.fuzzy_run_bonus;
            }
            const boundary = isBoundary(text, upper, k);
            if (boundary) {
                if (far_best != unreached) best = @max(best, far_best - gap_max);
                // Gaps of 2 to gap_max - 1 (a gap of 1 is a run).
                var distance: usize = 2;
                while (distance < gap_max and distance <= k) : (distance += 1) {
                    const before = previous[k - distance];
                    if (before == unreached) continue;
                    best = @max(best, before - @as(i32, @intCast(distance)));
                }
            }
            if (best == unreached) continue;
            const boundary_bonus: i32 = if (boundary) Score.fuzzy_boundary_bonus else 0;
            current[k] = best + Score.fuzzy_letter + boundary_bonus;
            reached = true;
        }
        // No place for this letter: none for the ones after it either.
        if (!reached) return no_match;
        std.mem.swap(*[text_chars_max]i32, &previous, &current);
    }
    var result: i32 = unreached;
    for (previous[0..text.len]) |score_at| result = @max(result, score_at);
    return result;
}
