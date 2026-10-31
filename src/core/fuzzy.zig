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
const text_chars_max = 2048;

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
    if (query_in.len == 0) return 0;
    // Both sides folded; `upper` keeps the case the folded text lost, for
    // camelCase boundaries.
    var query_buffer: [text_chars_max]u8 = undefined;
    const query = fold.foldInto(&query_buffer, query_in);
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

fn scoreFuzzy(text: []const u8, upper: []const bool, query: []const u8) i32 {
    var result: i32 = 0;
    var query_index: usize = 0;
    var previous_match: ?usize = null;
    var first_match: ?usize = null;
    for (text, 0..) |char, text_index| {
        if (query_index == query.len) break;
        if (char != query[query_index]) continue;
        // Letters out of the blue (not a word start, not continuing a run)
        // are what make fuzzy matching noisy; skip them.
        const boundary = isBoundary(text, upper, text_index);
        const run = previous_match != null and previous_match.? + 1 == text_index;
        if (!run and !boundary) continue;
        if (first_match == null) first_match = text_index;
        result += Score.fuzzy_letter;
        if (boundary) result += Score.fuzzy_boundary_bonus;
        if (previous_match) |previous| {
            if (run) {
                result += Score.fuzzy_run_bonus;
            } else {
                result -= @intCast(@min(text_index - previous, Score.fuzzy_gap_penalty_max));
            }
        }
        previous_match = text_index;
        query_index += 1;
    }
    if (query_index < query.len) return no_match;
    result -= @intCast(@min(first_match.?, Score.fuzzy_first_penalty_max));
    return result;
}

/// Best score over several fields (title, keywords, subtitle). Later fields
/// count for less so a title hit wins.
pub fn scoreFields(query: []const u8, fields: []const []const u8) i32 {
    var best: i32 = no_match;
    for (fields, 0..) |field, field_index| {
        const raw = score(query, field);
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

test "letters inside a word only match as a run" {
    try std.testing.expect(score("vsc", "Visual Studio Code") > 0);
    try std.testing.expectEqual(no_match, score("vsc", "Viscous"));
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
