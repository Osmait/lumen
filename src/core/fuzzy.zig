//! Fuzzy matching for the search bar. A query matches when it is a substring
//! of the candidate, or when its letters can be taken in order from word
//! starts and runs: "vsc" finds "Visual Studio Code", "left" does not find
//! "File Manager". Case- and accent-insensitive (`fold.zig`): "configuracion"
//! finds "Configuración"; other bytes compare exactly.

const std = @import("std");
const fold = @import("fold.zig");

pub const no_match: i32 = std.math.minInt(i32);

/// Longest text (and query) compared, in folded characters; the rest of a
/// longer one is ignored.
const max_len = 2048;

/// Score of `query` against `text`, or `no_match`. An empty query matches
/// everything with score 0.
pub fn score(query_in: []const u8, text_in: []const u8) i32 {
    if (query_in.len == 0) return 0;
    // Both sides folded; `upper` keeps the case the folded text lost, for
    // camelCase boundaries.
    var qbuf: [max_len]u8 = undefined;
    const query = fold.foldInto(&qbuf, query_in);
    var tbuf: [max_len]u8 = undefined;
    var ubuf: [max_len]bool = undefined;
    const tn = fold.foldCase(&tbuf, &ubuf, text_in);
    const text = tbuf[0..tn];
    const upper = ubuf[0..tn];
    if (query.len > text.len) return no_match;

    // A plain substring is the strongest signal; a prefix more so.
    if (std.mem.find(u8, text, query)) |at| {
        var s: i32 = 1000 - @as(i32, @intCast(@min(at, 200)));
        if (at == 0) s += 500 else if (isBoundary(text, upper, at)) s += 250;
        if (query.len == text.len) s += 300;
        return s;
    }

    var s: i32 = 0;
    var qi: usize = 0;
    var prev_match: ?usize = null;
    var first: ?usize = null;
    for (text, 0..) |ch, ti| {
        if (qi == query.len) break;
        if (ch != query[qi]) continue;
        // Letters out of the blue (not a word start, not continuing a run)
        // are what make fuzzy matching noisy; skip them.
        const run = prev_match != null and prev_match.? + 1 == ti;
        if (!run and !isBoundary(text, upper, ti)) continue;
        if (first == null) first = ti;
        s += 10;
        if (isBoundary(text, upper, ti)) s += 40;
        if (prev_match) |p| {
            if (p + 1 == ti) s += 30 else s -= @intCast(@min(ti - p, 20));
        }
        prev_match = ti;
        qi += 1;
    }
    if (qi < query.len) return no_match;
    s -= @intCast(@min(first.?, 50));
    return s;
}

/// Best score over several fields (title, keywords, subtitle). Later fields
/// count for less so a title hit wins.
pub fn scoreFields(query: []const u8, fields: []const []const u8) i32 {
    var best: i32 = no_match;
    for (fields, 0..) |f, i| {
        const raw = score(query, f);
        if (raw == no_match) continue;
        const weighted = raw - @as(i32, @intCast(i)) * 150;
        best = @max(best, weighted);
    }
    return best;
}

/// On folded `text`: after a separator, or a capital after a small letter
/// in the original ("fileManager", "ÁrbolÉpico").
fn isBoundary(text: []const u8, upper: []const bool, i: usize) bool {
    if (i == 0) return true;
    const p = text[i - 1];
    if (p == ' ' or p == '-' or p == '_' or p == '.' or p == '/') return true;
    return std.ascii.isLower(p) and !upper[i - 1] and upper[i];
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

test "letters inside a word only match as a run" {
    try std.testing.expect(score("vsc", "Visual Studio Code") > 0);
    try std.testing.expectEqual(no_match, score("vsc", "Viscous"));
}

test "title outranks subtitle" {
    const fields_title = [_][]const u8{ "Terminal", "Kitty" };
    const fields_sub = [_][]const u8{ "Kitty", "Terminal" };
    try std.testing.expect(scoreFields("term", &fields_title) > scoreFields("term", &fields_sub));
}

test "accents and case fold both ways" {
    try std.testing.expect(score("configuracion", "Configuración") > 0);
    try std.testing.expect(score("CONFIGURACIÓN", "Configuracion") > 0);
    try std.testing.expect(score("configuración", "Configuración del sistema") > 0);
    try std.testing.expectEqual(score("configuracion", "Configuración"), score("Configuración", "configuracion"));
    try std.testing.expect(score("nandu", "Ñandú") > 0);
    // Word starts survive folding: "ae" = Árbol Épico, camelCase too.
    try std.testing.expect(score("ae", "Árbol Épico") > 0);
    try std.testing.expect(score("ae", "árbolÉpico") > 0);
    try std.testing.expectEqual(no_match, score("ae", "Árbolepico"));
    // Symbols are not letters.
    try std.testing.expectEqual(no_match, score("x", "×"));
    try std.testing.expect(score("×", "3×4") > 0);
}
