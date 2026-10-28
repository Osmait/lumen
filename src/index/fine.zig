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

const max_name = 256;
const max_query = 64;
const neg: i32 = std.math.minInt(i32) / 2;

const Class = enum(u3) { white, non_word, delimiter, lower, upper, number };

fn classOf(c: u8) Class {
    return switch (c) {
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

fn bonusFor(prev: Class, cur: Class) i32 {
    const word = cur == .lower or cur == .upper or cur == .number;
    if (word) {
        switch (prev) {
            .white => return bonus_boundary_white,
            .delimiter => return bonus_boundary_delimiter,
            .non_word => return bonus_boundary,
            else => {},
        }
    }
    if (prev == .lower and cur == .upper) return bonus_camel;
    if (prev != .number and cur == .number) return bonus_camel;
    return switch (cur) {
        .non_word, .delimiter => bonus_non_word,
        .white => bonus_boundary_white,
        else => 0,
    };
}

/// Best alignment score of `q` (already folded: `core.fold`) in `name`, or
/// null when it does not match or is too long to score here.
///
/// The name is folded first ("Configuración" -> "configuracion"), and the
/// classes behind the bonuses come from the original letters: an accented
/// capital is still a camelCase boundary.
pub fn score(name_in: []const u8, q: []const u8) ?i32 {
    const m = q.len;
    if (m == 0 or m > max_query or name_in.len < m) return null;
    // One more than fits, to tell "too long" from "exactly max_name".
    var name_buf: [max_name + 1]u8 = undefined;
    var upper: [max_name + 1]bool = undefined;
    const n = fold.foldCase(&name_buf, &upper, name_in);
    if (n < m or n > max_name) return null;
    const name = name_buf[0..n];

    var bonus: [max_name]i32 = undefined;
    var prev_class: Class = .white;
    for (name, 0..) |ch, j| {
        const cl: Class = if (upper[j]) .upper else classOf(ch);
        bonus[j] = bonusFor(prev_class, cl);
        prev_class = cl;
    }

    // Rows for the previous query letter: best score with it matched exactly
    // at j (`m_prev`), best with it matched at or before j minus the gap since
    // (`p_prev`), and the bonus of the run's first letter (`rb_prev`).
    var m_prev: [max_name]i32 = undefined;
    var p_prev: [max_name]i32 = undefined;
    var rb_prev: [max_name]i32 = undefined;
    var m_cur: [max_name]i32 = undefined;
    var p_cur: [max_name]i32 = undefined;
    var rb_cur: [max_name]i32 = undefined;

    for (0..m) |i| {
        var p_row: i32 = neg;
        var in_gap = false;
        for (0..n) |j| {
            var ms: i32 = neg;
            var rb: i32 = 0;
            if (name[j] == q[i]) {
                const b = bonus[j];
                if (i == 0) {
                    ms = score_match + b * first_char_multiplier;
                    rb = b;
                } else if (j > 0) {
                    // Continue a run: the run keeps the bonus of its first
                    // letter, or restarts at a stronger boundary.
                    if (m_prev[j - 1] > neg) {
                        var cb: i32 = @max(rb_prev[j - 1], bonus_consecutive);
                        var run_b = rb_prev[j - 1];
                        if (b >= bonus_boundary and b > cb) {
                            cb = b;
                            run_b = b;
                        }
                        const s = m_prev[j - 1] + score_match + @max(cb, b);
                        if (s > ms) {
                            ms = s;
                            rb = run_b;
                        }
                    }
                    // Or come after a gap.
                    if (p_prev[j - 1] > neg) {
                        const s = p_prev[j - 1] + score_match + b;
                        if (s > ms) {
                            ms = s;
                            rb = b;
                        }
                    }
                }
            }
            m_cur[j] = ms;
            rb_cur[j] = rb;
            const decayed = if (p_row > neg) p_row + (if (in_gap) @as(
                i32,
                gap_extension,
            ) else gap_start) else neg;
            if (ms >= decayed) {
                p_row = ms;
                in_gap = false;
            } else {
                p_row = decayed;
                in_gap = true;
            }
            p_cur[j] = p_row;
        }
        @memcpy(m_prev[0..n], m_cur[0..n]);
        @memcpy(p_prev[0..n], p_cur[0..n]);
        @memcpy(rb_prev[0..n], rb_cur[0..n]);
    }

    var best: i32 = neg;
    for (m_prev[0..n]) |s| best = @max(best, s);
    return if (best > neg) best else null;
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
