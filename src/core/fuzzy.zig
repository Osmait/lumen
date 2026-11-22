//! Fuzzy matching for the search bar. A query matches when it is a substring
//! of the candidate, or when its letters can be taken in order from word
//! starts and runs: "vsc" finds "Visual Studio Code", "left" does not find
//! "File Manager". Case- and accent-insensitive (`fold.zig`): "configuracion"
//! finds "Configuración"; other bytes compare exactly.

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

comptime {
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
    const upper = upper_buffer[0..text_len];
    if (query.len > text.len) return no_match;

    // A plain substring is the strongest signal (see
    // `substring_outranks_fuzzy_chars_max`), and a prefix more so.
    if (std.mem.find(u8, text, query)) |substring_start| {
        const result = scoreSubstring(text, upper, query.len, substring_start);
        assert(result >= Score.substring_floor);
        return result;
    }
    // Most texts do not even hold the letters in order: one pass says so,
    // before `scoreFuzzy`'s 16 KB frame is set up.
    if (!isSubsequence(query, text)) return no_match;
    const result = scoreFuzzy(text, upper, query);
    if (result != no_match) {
        const letters: i32 = @intCast(query.len);
        assert(result <= letters * Score.fuzzy_letter_max);
    }
    return result;
}

fn scoreSubstring(
    text: []const u8,
    upper: []const bool,
    query_len: usize,
    substring_start: usize,
) i32 {
    const position_penalty: i32 = @intCast(
        @min(substring_start, Score.substring_position_penalty_max),
    );
    var result: i32 = Score.substring_base - position_penalty;
    if (substring_start == 0) {
        result += Score.substring_prefix_bonus;
    } else if (isBoundary(text, upper, substring_start)) {
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
/// letter: `previous[j]` is the best score with the previous letter at `j`.
/// A gap costs `min(distance, fuzzy_gap_penalty_max)`, so only the last
/// `fuzzy_gap_penalty_max` positions need looking at one by one; anything
/// further costs the same, and its best is kept as it goes (`far_best`).
/// Each row visits only the places its letter is, from just after the
/// previous row's first reached one (MYP-188).
///
/// Out of line: its rows are 16 KB, which every call of an inlined
/// `scoreQuery` set up, matching or not.
noinline fn scoreFuzzy(text: []const u8, upper: []const bool, query: []const u8) i32 {
    assert(query.len > 0);
    assert(text.len <= text_chars_max);
    const unreached = no_match;
    var rows: [2][text_chars_max]i32 = undefined;
    var previous = &rows[0];
    var current = &rows[1];
    @memset(previous[0..text.len], unreached);
    // The first position any letter of the previous row reached.
    var previous_first: usize = text.len;
    var k_first = std.mem.findScalar(u8, text, query[0]);
    while (k_first) |k| : (k_first = std.mem.findScalarPos(u8, text, k + 1, query[0])) {
        if (!isBoundary(text, upper, k)) continue;
        const first_penalty: i32 = @intCast(@min(k, Score.fuzzy_first_penalty_max));
        previous[k] = Score.fuzzy_letter + Score.fuzzy_boundary_bonus - first_penalty;
        previous_first = @min(previous_first, k);
    }
    if (previous_first == text.len) return no_match;
    for (query[1..]) |letter| {
        @memset(current[0..text.len], unreached);
        const first = rowFrom(text, upper, letter, previous, current, previous_first + 1);
        // No place for this letter: none for the ones after it either.
        if (first == text.len) return no_match;
        previous_first = first;
        std.mem.swap(*[text_chars_max]i32, &previous, &current);
    }
    var result: i32 = unreached;
    for (previous[previous_first..text.len]) |score_at| result = @max(result, score_at);
    return result;
}

/// One row of `scoreFuzzy`: `letter` at each of its places in `text` from
/// `start` on, given the previous letter's row. Returns the first position
/// reached, or `text.len` for none.
inline fn rowFrom(
    text: []const u8,
    upper: []const bool,
    letter: u8,
    previous: *const [text_chars_max]i32,
    current: *[text_chars_max]i32,
    start: usize,
) usize {
    const unreached = no_match;
    const gap_max = Score.fuzzy_gap_penalty_max;
    var first: usize = text.len;
    // The best of `previous[0..far_end]`, the places whose gap costs the
    // most: everything at or before `k - gap_max`.
    var far_best: i32 = unreached;
    var far_end: usize = 0;
    var next = if (start < text.len) std.mem.findScalarPos(u8, text, start, letter) else null;
    while (next) |k| : (next = std.mem.findScalarPos(u8, text, k + 1, letter)) {
        if (k >= gap_max) {
            while (far_end <= k - gap_max) : (far_end += 1) {
                far_best = @max(far_best, previous[far_end]);
            }
        }
        var best: i32 = unreached;
        if (previous[k - 1] != unreached) best = previous[k - 1] + Score.fuzzy_run_bonus;
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
        first = @min(first, k);
    }
    return first;
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
/// in the original ("fileManager", "ÁrbolÉpico").
fn isBoundary(text: []const u8, upper: []const bool, index: usize) bool {
    if (index == 0) return true;
    const before = text[index - 1];
    if (std.mem.findScalar(u8, " -_./", before) != null) return true;
    return std.ascii.isLower(before) and !upper[index - 1] and upper[index];
}

test "word starts and runs" {
    try std.testing.expect(score("mfi", "Mozilla Firefox") > 0);
    try std.testing.expect(score("vsc", "Visual Studio Code") > 0);
    try std.testing.expectEqual(no_match, score("xff", "Firefox"));
    try std.testing.expectEqual(no_match, score("left", "File Manager"));
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
            scoreFuzzy(text, upper, query),
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
