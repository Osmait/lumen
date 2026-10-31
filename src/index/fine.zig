//! Optimal-alignment fuzzy score, in the style of fzf's V2 algorithm. It plays
//! nucleo's role in the Rust cascade: too slow to run over a million names
//! (O(name × query)), cheap over the ~800 finalists the earlier layers leave.
//!
//! Unlike the greedy `cheap` scorer it finds the best placement of every
//! query letter: "conf" in "config.conf" scores the word-start match, not the
//! first letters that happen to fit.

const std = @import("std");
const fold = @import("core").fold;

const score_match = 16;
const gap_start = -3;
const gap_extension = -1;
const bonus_boundary = score_match / 2;
const bonus_non_word = score_match / 2;
const bonus_camel = bonus_boundary + gap_extension;
const bonus_consecutive = -(gap_start + gap_extension);
const bonus_boundary_white = bonus_boundary + 2;
const bonus_boundary_delimiter = bonus_boundary + 1;
const first_char_multiplier = 2;

/// Longer names are not scored (Linux names stop at 255 bytes).
const name_bytes_max = 256;
/// Longer queries get no fine score (null): the cheap score alone ranks them.
pub const query_letters_max = 64;
/// A cell no alignment reaches. Half of the minimum, so adding a score to it
/// cannot overflow.
const unreached: i32 = std.math.minInt(i32) / 2;

const Class = enum(u3) { white, non_word, delimiter, lower, upper, number };

fn classOf(letter: u8) Class {
    return switch (letter) {
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        '0'...'9' => .number,
        ' ', '\t' => .white,
        '/', ',', ':', ';', '|' => .delimiter,
        // Non-ASCII bytes are parts of letters.
        0x80...0xff => .lower,
        else => .non_word,
    };
}

fn bonusFor(class_before: Class, class: Class) i32 {
    const word = class == .lower or class == .upper or class == .number;
    if (word) {
        switch (class_before) {
            .white => return bonus_boundary_white,
            .delimiter => return bonus_boundary_delimiter,
            .non_word => return bonus_boundary,
            else => {},
        }
    }
    if (class_before == .lower and class == .upper) return bonus_camel;
    if (class_before != .number and class == .number) return bonus_camel;
    return switch (class) {
        .non_word, .delimiter => bonus_non_word,
        .white => bonus_boundary_white,
        else => 0,
    };
}

/// One row of the alignment table: for a query letter and each name position
/// j, the best score with that letter matched exactly at j (`matched`), the
/// best with it matched at or before j minus the gap since (`gapped`), and
/// the bonus of the run's first letter (`run_bonus`).
const Row = struct {
    matched: [name_bytes_max]i32,
    gapped: [name_bytes_max]i32,
    run_bonus: [name_bytes_max]i32,
};

/// A cell's score with its letter matched there, and the bonus its run keeps.
const Cell = struct { score: i32, run_bonus: i32 };

/// Best alignment score of `query` (already folded: `core.fold`) in `name`,
/// or null when it does not match or is too long to score here.
///
/// The name is folded first ("Configuración" -> "configuracion"), and the
/// classes behind the bonuses come from the original letters: an accented
/// capital is still a camelCase boundary.
pub fn score(name: []const u8, query: []const u8) ?i32 {
    if (query.len == 0 or query.len > query_letters_max or name.len < query.len) return null;
    // One more than fits, to tell "too long" from "exactly name_bytes_max".
    var folded_letters: [name_bytes_max + 1]u8 = undefined;
    var upper: [name_bytes_max + 1]bool = undefined;
    const folded_length = fold.foldCase(&folded_letters, &upper, name);
    if (folded_length < query.len or folded_length > name_bytes_max) return null;
    const folded = folded_letters[0..folded_length];

    var bonus: [name_bytes_max]i32 = undefined;
    var class_before: Class = .white;
    for (folded, 0..) |letter, j| {
        const class: Class = if (upper[j]) .upper else classOf(letter);
        bonus[j] = bonusFor(class_before, class);
        class_before = class;
    }

    // The rows of the previous query letter and of the current one.
    var previous: Row = undefined;
    var current: Row = undefined;
    for (0..query.len) |i| {
        var gapped: i32 = unreached;
        var in_gap = false;
        for (0..folded_length) |j| {
            const cell: Cell = if (folded[j] == query[i])
                matchCell(&previous, bonus[j], i, j)
            else
                .{ .score = unreached, .run_bonus = 0 };
            current.matched[j] = cell.score;
            current.run_bonus[j] = cell.run_bonus;
            const gap_penalty: i32 = if (in_gap) gap_extension else gap_start;
            const decayed = if (gapped > unreached) gapped + gap_penalty else unreached;
            if (cell.score >= decayed) {
                gapped = cell.score;
                in_gap = false;
            } else {
                gapped = decayed;
                in_gap = true;
            }
            current.gapped[j] = gapped;
        }
        @memcpy(previous.matched[0..folded_length], current.matched[0..folded_length]);
        @memcpy(previous.gapped[0..folded_length], current.gapped[0..folded_length]);
        @memcpy(previous.run_bonus[0..folded_length], current.run_bonus[0..folded_length]);
    }

    var best: i32 = unreached;
    for (previous.matched[0..folded_length]) |matched| best = @max(best, matched);
    return if (best > unreached) best else null;
}

/// The score of matching query letter `i` at name position `j`, whose bonus
/// is `bonus`, given the row of the previous query letter. Part of the
/// measured hot loop of `score`, hence inline.
inline fn matchCell(previous: *const Row, bonus: i32, i: usize, j: usize) Cell {
    if (i == 0) return .{ .score = score_match + bonus * first_char_multiplier, .run_bonus = bonus };
    var cell: Cell = .{ .score = unreached, .run_bonus = 0 };
    if (j == 0) return cell;
    // Continue a run: the run keeps the bonus of its first letter, or
    // restarts at a stronger boundary.
    if (previous.matched[j - 1] > unreached) {
        var consecutive: i32 = @max(previous.run_bonus[j - 1], bonus_consecutive);
        var run_bonus = previous.run_bonus[j - 1];
        if (bonus >= bonus_boundary and bonus > consecutive) {
            consecutive = bonus;
            run_bonus = bonus;
        }
        const continued = previous.matched[j - 1] + score_match + @max(consecutive, bonus);
        if (continued > cell.score) cell = .{ .score = continued, .run_bonus = run_bonus };
    }
    // Or come after a gap.
    if (previous.gapped[j - 1] > unreached) {
        const after_gap = previous.gapped[j - 1] + score_match + bonus;
        if (after_gap > cell.score) cell = .{ .score = after_gap, .run_bonus = bonus };
    }
    return cell;
}
test "matches and prefers word starts" {
    try std.testing.expect(score("Cargo.toml", "cargo") != null);
    try std.testing.expect(score("README", "xyz") == null);
    // "mr" at "main.rs" boundaries beats "mr" inside "amrfoo".
    try std.testing.expect(score("main.rs", "mr").? < score("main.rs", "main").?);
    try std.testing.expect(score("my_report.md", "mr").? > score("amrfoo.md", "mr").?);
}

test "finds the best placement, not the first" {
    // Greedy would take the "c" of "abc" and scatter the rest.
    try std.testing.expect(score("abc_config", "config").? > score("cxoxnxfxixg", "config").?);
}

test "accents and case fold, bonuses follow the original letters" {
    try std.testing.expectEqual(score("Configuracion.md", "configuracion"), score(
        "Configuración.md",
        "configuracion",
    ));
    try std.testing.expect(score("español.txt", "espanol") != null);
    try std.testing.expect(score("espanol.txt", "espanol") != null);
    // "ÁrbolÉpico": É is a camelCase boundary, like "ArbolEpico".
    try std.testing.expectEqual(score("ArbolEpico", "ae"), score("ÁrbolÉpico", "ae"));
    try std.testing.expect(score("ÁrbolÉpico", "ae").? > score("Árbolepico", "ae").?);
    try std.testing.expect(score("3×4", "x") == null);
}
