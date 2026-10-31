//! The greedy fuzzy score, layer 3 of the name search's cascade
//! (search.zig): one pass over the name, matching each query letter at the
//! first place it fits, with bonuses for runs and word boundaries. It does
//! not find the best alignment (`fine.zig` does, over the finalists only);
//! it runs on every name that passes the mask prefilter, so it only has to
//! be cheap and not lose good candidates.

const std = @import("std");
const store_mod = @import("store.zig");
const fold = @import("core").fold;

/// The cheap score of `name` for `query`, or null when `query` is not a
/// subsequence of it.
///
/// `query` is folded (`core.fold`); the name is compared folded. Pure ASCII
/// names (nearly all of them) are lowercased on the fly; the first byte
/// >= 0x80 sends the name to a folded copy that keeps the original case
/// for camelCase. Both give the same score on an ASCII name.
pub fn score(name: []const u8, query: []const u8) ?i32 {
    if (name.len < query.len) return null;
    return scoreWith(.ascii, name, &.{}, query) catch scoreFolded(name, query);
}

/// `score` with the name's mask from the store: its `mask_non_ascii`
/// says which path to take, so an ASCII name never has its tail checked
/// after the match (measurable on "c", where nearly every name matches at
/// its first letters).
pub fn scoreMasked(name: []const u8, query: []const u8, mask: u64) ?i32 {
    if (name.len < query.len) return null;
    if (mask & store_mod.mask_non_ascii != 0) return scoreFolded(name, query);
    // The same loop as before folding existed. A damaged mapped mask could
    // only score a non-ASCII name as plain bytes: never unsafe.
    return scoreWith(
        .known_ascii,
        name,
        &.{},
        query,
    ) catch unreachable; // NonAscii comes only from .ascii mode
}

// Out of line: its 2 KB of buffers stay off the hot loop's stack frame.
noinline fn scoreFolded(name: []const u8, query: []const u8) ?i32 {
    var name_folded: [folded_bytes_max]u8 = undefined;
    var upper: [folded_bytes_max]bool = undefined;
    const folded_count = fold.foldCase(&name_folded, &upper, name);
    return scoreWith(
        .folded,
        name_folded[0..folded_count],
        upper[0..folded_count],
        query,
    ) catch unreachable; // NonAscii comes only from .ascii mode
}

/// Longest name folded for `score`; a longer non-ASCII name is scored
/// on its first `folded_bytes_max` characters (Linux names stop at 255 bytes).
const folded_bytes_max = 1024;

/// What each property of a match is worth to the cheap scorer. Together
/// they order the names the fine scorer then looks at.
const weight = struct {
    /// A matched character right after the previous match.
    const consecutive = 30;
    /// A match on the name's first character.
    const name_start = 45;
    /// A match right after a separator (`isWordSeparator`).
    const word_start = 28;
    /// A match on a camelCase boundary.
    const camel_start = 22;
    /// Taken per byte before the first match, up to `before_first_bytes_max`.
    const before_first_per_byte = 2;
    const before_first_bytes_max = 64;
    /// One point taken per this many bytes of name: shorter names first.
    const name_bytes_per_point = 4;
    /// The name is the query, with or without its extension: people type
    /// "readme" for README.md as much as for README.
    const whole_name = 120;
};

/// Whether a match right after `byte` starts a word. A switch, not a
/// search in a string: it runs once per matched byte of every candidate.
inline fn isWordSeparator(byte: u8) bool {
    return switch (byte) {
        '_', '-', '.', ' ', '/' => true,
        else => false,
    };
}

/// How `scoreWith` is given the name.
const Mode = enum {
    /// `name` is the original, known to be ASCII (its mask says so):
    /// lowercased on the fly.
    known_ascii,
    /// Same, but fails on any non-ASCII byte, before or after the match.
    ascii,
    /// `name` is already folded; `upper` says which characters were capitals.
    folded,
};

/// The one loop behind `score` and `scoreMasked`, compiled once per `Mode`.
fn scoreWith(
    comptime mode: Mode,
    name: []const u8,
    upper: []const bool,
    query: []const u8,
) error{NonAscii}!?i32 {
    const ascii = mode != .folded;
    var query_index: usize = 0;
    var total: i32 = 0;
    var hit_previous: usize = std.math.maxInt(usize);
    var hit_first: usize = std.math.maxInt(usize);
    // A `for`, not a `while` over an index: measured 8% faster on "ca"
    // over 1.6M names.
    var seen = name.len;
    for (name, 0..) |raw, i| {
        if (query_index == query.len) {
            seen = i;
            break;
        }
        if (mode == .ascii and !std.ascii.isAscii(raw)) return error.NonAscii;
        const letter = if (ascii) std.ascii.toLower(raw) else raw;
        if (letter != query[query_index]) continue;
        if (hit_first == std.math.maxInt(usize)) hit_first = i;
        if (hit_previous +% 1 == i) total += weight.consecutive;
        if (i == 0) {
            total += weight.name_start;
        } else {
            const before = name[i - 1];
            const camel_boundary = if (ascii)
                std.ascii.isLower(before) and std.ascii.isUpper(raw)
            else
                std.ascii.isLower(before) and !upper[i - 1] and upper[i];
            if (isWordSeparator(before)) {
                total += weight.word_start;
            } else if (camel_boundary) {
                total += weight.camel_start;
            }
        }
        hit_previous = i;
        query_index += 1;
    }
    if (query_index < query.len) return null;
    // The lengths below are folded lengths: an unseen tail must be ASCII
    // too for the original's to be the same.
    if (mode == .ascii and !fold.isAscii(name[seen..])) return error.NonAscii;
    const before_first: i32 = @intCast(@min(hit_first, weight.before_first_bytes_max));
    total -= before_first * weight.before_first_per_byte;
    total -= @as(i32, @intCast(name.len / weight.name_bytes_per_point));
    const stem_length = std.mem.findScalarLast(u8, name, '.') orelse name.len;
    const stem_is_query = stem_length > 0 and stem_length == query.len;
    if (name.len == query.len or stem_is_query) total += weight.whole_name;
    return total;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "an ASCII name scores the same down both paths" {
    const names = [_][]const u8{
        "Cargo.toml",
        "fileManager.rs",
        "README",
        "my_report.md",
        "a.b-c d/e",
    };
    const queries = [_][]const u8{ "c", "cargo", "fm", "readme", "mr", "abcde", "zz" };
    for (names) |name| for (queries) |query| {
        var folded: [64]u8 = undefined;
        var upper: [64]bool = undefined;
        const folded_length = fold.foldCase(&folded, &upper, name);
        try testing.expectEqual(try scoreWith(.ascii, name, &.{}, query), try scoreWith(
            .folded,
            folded[0..folded_length],
            upper[0..folded_length],
            query,
        ));
        const mask = store_mod.charMask(name);
        try testing.expectEqual(score(name, query), scoreMasked(name, query, mask));
    };
    // Same letters with accents: same score as the unaccented name.
    try testing.expectEqual(score("ArbolEpico.md", "ae"), score("ÁrbolÉpico.md", "ae"));
    try testing.expectEqual(score("configuracion.md", "configuracion"), score(
        "Configuración.md",
        "configuracion",
    ));
    // A non-ASCII byte after the match still counts in the folded length.
    try testing.expectEqual(score("ab-ene", "ab"), score("ab-eñe", "ab"));
    try testing.expectEqual(score("ab-eñe", "ab"), scoreMasked(
        "ab-eñe",
        "ab",
        store_mod.charMask("ab-eñe"),
    ));
}
