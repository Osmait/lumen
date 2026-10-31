//! A content query, end to end: the query's words, the candidates the
//! trigram lists give (`ContentIndex.candidates`), and verification, which
//! reads each candidate (in parallel on the pool) to check that every word
//! is really there, count the hits and cut a snippet.
//!
//! Candidates are verified best bound first: the score a document can
//! reach at most, from what is known without reading it (file name,
//! recency, depth) plus the most its text can add. The threads share the
//! best `limit` matches so far, and stop once no unread candidate's bound
//! can beat the worst of them, so a common word reads a few hundred files,
//! not thousands.

const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const Pool = @import("Pool.zig");
const sys = @import("os");
const Bytes = @import("format.zig").Bytes;
const fold = @import("core").fold;
const utf8 = @import("core").utf8;
const recency = @import("recency.zig");
const content_format = @import("content_format.zig");
const DocIn = content_format.DocIn;
const trigram_chars = content_format.trigram_chars;
const Index = @import("ContentIndex.zig");
const readPlain = @import("content_build.zig").readPlain;
const findFold = @import("content_find.zig").findFold;

pub const Match = struct {
    doc: u32,
    /// Occurrences of the first word (capped).
    count: u32,
    /// 1-based line of the first occurrence, and that line's text.
    line: u32,
    snippet: []const u8,
    score: i32,
};

/// Words of a query: split on spaces, folded (`core.fold`) into `arena`.
pub fn splitWords(
    arena: std.mem.Allocator,
    query: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, query, " \t");
    while (tokens.next()) |word| try words.append(arena, try fold.foldAlloc(arena, word));
    return words.items;
}

/// The file that holds a document's text: the document itself, or its
/// extracted text in a cache. Verification maps it instead of reading it,
/// so a hit on page 1 of a 4 MB book touches a few pages, not the book.
pub const PathFn = *const fn (context: *anyopaque, doc: DocIn, path_buffer: []u8) ?[:0]const u8;

pub const SearchOptions = struct {
    /// Matches wanted, best first.
    limit: usize,
    /// Where each document's text is read from, and its context.
    text_path: PathFn,
    text_context: *anyopaque,
    /// Set by another thread once the answer is not wanted any more (a
    /// newer query waits): verification stops at the next candidate, and
    /// the matches so far are returned.
    stop: ?*const std.atomic.Value(bool) = null,
};

/// For plain documents only (benchmarks, tests).
pub fn plainPath(_: *anyopaque, doc: DocIn, path_buffer: []u8) ?[:0]const u8 {
    if (doc.source != .plain) return null;
    return std.mem.printSentinel(path_buffer, "{s}", .{doc.path}, 0) catch null;
}

/// Full query: candidates from the trigram lists, verified in parallel by
/// reading each file, ranked. Snippets live in `arena`; at most `limit`.
pub fn search(
    index: *const Index,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pool: *Pool,
    query: []const u8,
    options: SearchOptions,
    out: *std.ArrayList(Match),
) std.mem.Allocator.Error!void {
    const limit = options.limit;
    const text_path = options.text_path;
    const text_context = options.text_context;
    out.clearRetainingCapacity();
    if (limit == 0) return;
    const words = try splitWords(arena, query);
    const phrase = try fold.foldAlloc(arena, std.mem.trim(u8, query, " \t"));
    var longest: usize = 0;
    for (words) |word| longest = @max(longest, word.len);
    // Nothing a trigram can narrow.
    if (longest < trigram_chars) return;
    var docs: std.ArrayList(u32) = .empty;
    defer docs.deinit(gpa);
    try index.candidates(gpa, words, &docs);
    if (docs.items.len == 0) return;
    const now_s = sys.nowSeconds();

    const ordered = try orderCandidates(index, gpa, words, phrase, docs.items, now_s);
    defer gpa.free(ordered);

    const tasks = pool.threads.len + 1;
    const arenas = try gpa.alloc(std.heap.ArenaAllocator, tasks);
    defer {
        for (arenas) |*task_arena| task_arena.deinit();
        gpa.free(arenas);
    }
    for (arenas) |*task_arena| task_arena.* = .init(gpa);
    const top = try gpa.alloc(Match, limit);
    defer gpa.free(top);
    var context: VerifyContext = .{
        .gpa = gpa,
        .io = pool.io,
        .index = index,
        .words = words,
        .phrase = phrase,
        .candidates = ordered[0..@min(ordered.len, candidates_verified_max)],
        .text_path = text_path,
        .text_context = text_context,
        .stop = options.stop,
        .arenas = arenas,
        .now_s = now_s,
        .top = top,
        .arena = arena,
    };
    pool.run(@min(tasks, context.candidates.len), &context, verifyTask);
    if (context.out_of_memory.load(.acquire)) return error.OutOfMemory;
    try out.appendSlice(arena, top[0..context.top_count]);
    sortMatches(out.items);
}

/// The most candidates a query reads: past them, it gives what it found.
pub const candidates_verified_max = 4000;

/// A candidate in verification order: by `bound`, the most its score can
/// be once its text is read.
const Candidate = struct { doc: u32, bound: i32, maybe_phrase: bool };

/// The candidates, best bound first: what is known without reading them
/// (recency, depth, name) plus the most reading can add, so verification
/// stops as soon as the next one cannot beat the `limit`-th match. Owned
/// by `gpa`.
fn orderCandidates(
    index: *const Index,
    gpa: std.mem.Allocator,
    words: []const []const u8,
    phrase: []const u8,
    docs: []const u32,
    now_s: i64,
) std.mem.Allocator.Error![]Candidate {
    // Only documents holding every trigram of the whole phrase (spaces
    // included) can get its bonus: the others' bound leaves it out, so they
    // need not be read once enough better matches are in. Too short to
    // have trigrams, the phrase could be anywhere.
    const several = words.len > 1;
    var phrase_docs: std.ArrayList(u32) = .empty;
    defer phrase_docs.deinit(gpa);
    const phrase_known = several and phrase.len >= trigram_chars;
    if (phrase_known) try index.candidates(gpa, &.{phrase}, &phrase_docs);

    const ordered = try gpa.alloc(Candidate, docs.len);
    errdefer gpa.free(ordered);
    var phrase_index: usize = 0;
    for (docs, ordered) |doc, *candidate| {
        // Both lists ascend.
        const phrase_items = phrase_docs.items;
        while (phrase_index < phrase_items.len and phrase_items[phrase_index] < doc) {
            phrase_index += 1;
        }
        const phrase_has_doc = phrase_index < phrase_items.len and
            phrase_items[phrase_index] == doc;
        const maybe_phrase = several and (!phrase_known or phrase_has_doc);
        const bound_phrase: i32 = if (maybe_phrase) phrase_max else 0;
        candidate.* = .{
            .doc = doc,
            .maybe_phrase = maybe_phrase,
            .bound = staticScore(index.docIn(doc), words, now_s) + count_max + bound_phrase,
        };
    }
    std.mem.sort(Candidate, ordered, {}, struct {
        fn before(_: void, a: Candidate, b: Candidate) bool {
            return candidateRanksBefore(a, b);
        }
    }.before);
    return ordered;
}

/// Hits counted per document; more do not change the ranking.
pub const count_cap = 10;
/// Score of each hit counted.
const count_score = 20;
/// Most of the hit count's weight in the final score.
const count_max: i32 = count_cap * count_score;
/// Bonus when several words appear together, exactly as typed.
const phrase_max: i32 = 250;
/// Bonus for each word that the file's name contains.
const name_word_score = 150;
/// Penalty for each folder between the root and the file.
const depth_penalty = 5;

/// More hits, a matching file name, recent edits and shallow paths first.
fn rank(doc: DocIn, count: u32, words: []const []const u8, now_s: i64) i32 {
    const counted: i32 = @intCast(@min(count, count_cap));
    return counted * count_score + staticScore(doc, words, now_s);
}

/// The part of the score known without opening the file.
fn staticScore(doc: DocIn, words: []const []const u8, now_s: i64) i32 {
    var score: i32 = 0;
    const name = std.Io.Dir.path.basename(doc.path);
    for (words) |word| {
        if (findFold(name, word, 0) != null) score += name_word_score;
    }
    // Saturating: mtimes come from the index file, which may be damaged.
    score += recency.bonus(now_s -| doc.mtime);
    score -= @intCast(paths.depth(doc.path) * depth_penalty);
    return score;
}

/// Verification shared by the pool's threads: each takes the next candidate
/// (no batches, so nobody waits for the slowest file of a batch) until the
/// next one's bound cannot beat the `limit`-th match so far.
const VerifyContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    index: *const Index,
    words: []const []const u8,
    phrase: []const u8,
    candidates: []const Candidate,
    text_path: PathFn,
    text_context: *anyopaque,
    stop: ?*const std.atomic.Value(bool),
    arenas: []std.heap.ArenaAllocator,
    now_s: i64,
    next: std.atomic.Value(usize) = .init(0),
    /// The worst score among the best `top.len`, once there are that many.
    floor: std.atomic.Value(i32) = .init(std.math.minInt(i32)),
    /// Under `lock`: the best matches so far, snippets in `arena`.
    lock: std.Io.Mutex = .init,
    top: []Match,
    top_count: usize = 0,
    arena: std.mem.Allocator,
    out_of_memory: std.atomic.Value(bool) = .init(false),

    fn offer(context: *VerifyContext, match: Match) void {
        context.lock.lockUncancelable(context.io);
        defer context.lock.unlock(context.io);
        assert(context.top_count <= context.top.len);
        var slot = context.top_count;
        if (context.top_count == context.top.len) {
            slot = worst(context.top);
            if (!matchRanksBefore(match, context.top[slot])) return;
        }
        var copy = match;
        copy.snippet = context.arena.dupe(u8, match.snippet) catch {
            context.out_of_memory.store(true, .release);
            return;
        };
        context.top[slot] = copy;
        if (context.top_count < context.top.len) context.top_count += 1;
        if (context.top_count == context.top.len) {
            context.floor.store(context.top[worst(context.top)].score, .release);
        }
    }
};

fn verifyTask(context: *VerifyContext, task: usize) void {
    var path_buffer: paths.Buffer = undefined;
    var plain_text: std.ArrayList(u8) = .empty;
    defer plain_text.deinit(context.gpa);
    const arena = context.arenas[task].allocator();
    while (true) {
        if (context.stop) |stop| {
            if (stop.load(.acquire)) return;
        }
        const candidate_index = context.next.fetchAdd(1, .monotonic);
        if (candidate_index >= context.candidates.len) return;
        const candidate = context.candidates[candidate_index];
        // Candidates come by bound: none after this one can enter either.
        if (candidate.bound < context.floor.load(.acquire)) {
            context.next.store(context.candidates.len, .monotonic);
            return;
        }
        defer _ = context.arenas[task].reset(.retain_capacity);
        const doc = context.index.docIn(candidate.doc);
        const text_context = context.text_context;
        const text_path = context.text_path(text_context, doc, &path_buffer) orelse continue;
        // Plain files (1 MB at most) are read into a reused buffer: cheaper
        // than map + unmap, whose TLB shootdown hits every core of a
        // 24-thread process. Extracted texts run to megabytes and usually
        // match early, so those are mapped and only touched where scanned.
        var mapped: ?Bytes = null;
        defer if (mapped) |bytes| sys.unmap(bytes);
        const text: []const u8 = switch (doc.source) {
            .plain => blk: {
                // Out of memory: this candidate is left out of the results.
                const has_text = readPlain(context.gpa, text_path, &plain_text) catch false;
                if (!has_text) continue;
                break :blk plain_text.items;
            },
            .extracted => blk: {
                mapped = sys.mapPrivate(text_path) catch continue;
                break :blk mapped.?;
            },
        };
        const maybe_phrase = candidate.maybe_phrase;
        const verified = verify(text, context.words, context.phrase, maybe_phrase, arena) orelse
            continue;
        const phrase_bonus: i32 = if (verified.phrase) phrase_max else 0;
        context.offer(.{
            .doc = candidate.doc,
            .count = verified.count,
            .line = verified.line,
            .snippet = verified.snippet,
            .score = rank(doc, verified.count, context.words, context.now_s) + phrase_bonus,
        });
    }
}

/// Ranking order: score, then doc id.
fn matchRanksBefore(a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.doc < b.doc;
}

/// Verification order: bound, then doc id.
fn candidateRanksBefore(a: Candidate, b: Candidate) bool {
    if (a.bound != b.bound) return a.bound > b.bound;
    return a.doc < b.doc;
}

fn worst(matches: []const Match) usize {
    assert(matches.len > 0);
    var worst_index: usize = 0;
    for (matches[1..], 1..) |match, match_index| {
        if (matchRanksBefore(matches[worst_index], match)) worst_index = match_index;
    }
    return worst_index;
}

fn sortMatches(matches: []Match) void {
    std.mem.sort(Match, matches, {}, struct {
        fn before(_: void, a: Match, b: Match) bool {
            return matchRanksBefore(a, b);
        }
    }.before);
}

pub const Verified = struct { count: u32, line: u32, snippet: []const u8, phrase: bool };

/// A hit further into its line than `snippet_lead_bytes_max` bytes starts the
/// snippet `snippet_lead_bytes` bytes before it, so that it shows.
const snippet_lead_bytes_max = 60;
const snippet_lead_bytes = 40;
const snippet_bytes_max = 200;

comptime {
    assert(snippet_lead_bytes <= snippet_lead_bytes_max);
    assert(snippet_lead_bytes < snippet_bytes_max);
}

/// Checks that `text` holds every word and describes the first hit. With
/// several words, the whole `phrase` (the query as typed) is looked for
/// first: when present, that is the hit shown. Matching is folded
/// (`findFold`); line and snippet come from the original text.
pub fn verify(
    text: []const u8,
    words: []const []const u8,
    phrase: []const u8,
    maybe_phrase: bool,
    arena: std.mem.Allocator,
) ?Verified {
    if (words.len == 0) return null;
    // The phrase holds every word: found, they need no looking for. Not
    // looked for where its trigrams are not all present (`maybe_phrase`).
    const phrase_hit = if (words.len > 1 and maybe_phrase) findFold(text, phrase, 0) else null;
    var first = phrase_hit;
    if (phrase_hit == null) {
        for (words, 0..) |word, word_index| {
            const word_hit = findFold(text, word, 0) orelse return null;
            if (word_index == 0) first = word_hit;
        }
    }
    const counted = if (phrase_hit != null) phrase else words[0];
    const hit = first.?;
    const hit_start = hit.start;
    // The ranking stops caring after `count_cap` hits; so does counting
    // (in a 4 MB book, "the" would otherwise scan the whole text).
    var count: u32 = 0;
    var occurrence = hit;
    while (count < count_cap) {
        count += 1;
        occurrence = findFold(text, counted, occurrence.end) orelse break;
    }
    const newline_before = std.mem.findScalarLast(u8, text[0..hit_start], '\n');
    const line_start = if (newline_before) |newline| newline + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, text, hit_start, '\n') orelse text.len;
    const line_number: u32 = @intCast(std.mem.count(u8, text[0..hit_start], "\n") + 1);
    // Keep the hit visible: start the snippet a little before it.
    const hit_far_into_line = hit_start - line_start > snippet_lead_bytes_max;
    const snippet_start = if (hit_far_into_line) hit_start - snippet_lead_bytes else line_start;
    const snippet_end = @min(line_end, snippet_start + snippet_bytes_max);
    const snippet = std.mem.trim(u8, text[snippet_start..snippet_end], " \t\r");
    return .{
        .count = count,
        .line = line_number,
        .snippet = arena.dupe(u8, utf8.validWindow(snippet)) catch "",
        .phrase = phrase_hit != null,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const content_build = @import("content_build.zig");
const build = content_build.build;
const TextReader = content_build.TextReader;

test "verify finds the line and counts hits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "first line\n  const a = ArenaAllocator.init(gpa);\nArenaAllocator again\n";
    const verified = verify(text, &.{"arenaallocator"}, "arenaallocator", true, arena.allocator()).?;
    try testing.expectEqual(@as(u32, 2), verified.line);
    try testing.expectEqual(@as(u32, 2), verified.count);
    try testing.expectEqualStrings("const a = ArenaAllocator.init(gpa);", verified.snippet);
    try testing.expect(
        verify(text, &.{ "arena", "missing" }, "arena missing", true, arena.allocator()) == null,
    );
    // The phrase wins over the first word's first occurrence.
    const phrase_verified = verify(
        "again here\nsee ArenaAllocator again\n",
        &.{ "arenaallocator", "again" },
        "arenaallocator again",
        true,
        arena.allocator(),
    ).?;
    try testing.expectEqual(@as(u32, 2), phrase_verified.line);
    try testing.expect(phrase_verified.phrase);
}

test "verify: folded matches, line and snippet from the original text" {
    const text = "Primera línea\nUna ACCIÓN rápida\nel Ñandú corre\n3×4 y 3x4\n";
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "accion", "ACCIÓN", "acción" }) |query| {
        const words = try splitWords(arena, query);
        const verified = verify(text, words, words[0], true, arena).?;
        try testing.expectEqual(@as(u32, 2), verified.line);
        try testing.expectEqualStrings("Una ACCIÓN rápida", verified.snippet);
    }
    const verified = verify(
        text,
        try splitWords(arena, "nandu corre"),
        try fold.foldAlloc(arena, "nandu corre"),
        true,
        arena,
    ).?;
    try testing.expectEqual(@as(u32, 3), verified.line);
    try testing.expect(verified.phrase);
    // Two hits of different lengths, counted without overlap.
    try testing.expectEqual(
        @as(u32, 3),
        verify("acción accion ACCIÓN", &.{"accion"}, "accion", true, arena).?.count,
    );
}

const FileDocs = struct {
    fn readText(
        _: *anyopaque,
        doc: DocIn,
        text: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!bool {
        return readPlain(gpa, doc.path, text);
    }
};

test "search: the top matches equal reading every document and ranking them all" {
    const gpa = testing.allocator;
    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Few words, so documents share them, phrases occur by chance, and
    // scores tie (recency and depth vary too).
    const vocab = [_][]const u8{
        "select", "from", "where", "fn", "main", "the", "lumen", "index", "*", "use", "state",
        "café",
    };
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    const docs_count = 400;
    var docs: [docs_count]DocIn = undefined;
    const now = sys.nowSeconds();
    try test_dir.mkdir("deep/er");
    for (&docs, 0..) |*doc, i| {
        var text: std.ArrayList(u8) = .empty;
        for (0..random.intRangeAtMost(usize, 3, 40)) |_| {
            try text.appendSlice(arena, vocab[random.uintLessThan(usize, vocab.len)]);
            try text.append(arena, if (random.uintLessThan(u8, 6) == 0) '\n' else ' ');
        }
        const folder = if (i % 3 == 0) "/deep/er" else "";
        const path = try arena.print("{s}{s}/{s}{d}.txt", .{
            test_dir.absolute,
            folder,
            if (i % 7 == 0) "main" else "doc",
            i,
        });
        var path_buffer: paths.Buffer = undefined;
        try sys.writeFile(try std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0), text.items);
        const ages_days = [_]i64{ 0, 3, 20, 100, 300, 900 };
        const age_s = ages_days[i % ages_days.len] * std.time.s_per_day;
        doc.* = .{ .path = path, .mtime = now - age_s, .size = text.items.len };
    }
    const pool = try Pool.create(gpa, testing.io, 3);
    defer pool.destroy();
    var dummy: u8 = 0;
    const reader: TextReader = .{ .read = FileDocs.readText, .context = &dummy };
    var index = try build(gpa, pool, &docs, reader, null);
    defer index.deinit(gpa);

    var out: std.ArrayList(Match) = .empty;
    var want: std.ArrayList(Match) = .empty;
    var doc_text: std.ArrayList(u8) = .empty;
    defer doc_text.deinit(gpa);
    const queries = [_][]const u8{
        "select * from", "fn main",           "use state", "the lumen", "lumen", "where",
        "café index",
        "main",          "from where select",
    };
    for (queries) |query| for ([_]usize{ 5, 20 }) |limit| {
        try search(
            &index,
            gpa,
            arena,
            pool,
            query,
            .{ .limit = limit, .text_path = plainPath, .text_context = &dummy },
            &out,
        );
        // Every document read and ranked.
        want.clearRetainingCapacity();
        const words = try splitWords(arena, query);
        const phrase = try fold.foldAlloc(arena, std.mem.trim(u8, query, " \t"));
        for (docs, 0..) |doc, i| {
            if (!try readPlain(gpa, doc.path, &doc_text)) continue;
            const verified = verify(doc_text.items, words, phrase, true, arena) orelse continue;
            const bonus: i32 = if (verified.phrase) phrase_max else 0;
            try want.append(arena, .{
                .doc = @intCast(i),
                .count = verified.count,
                .line = verified.line,
                .snippet = verified.snippet,
                .score = rank(doc, verified.count, words, now) + bonus,
            });
        }
        sortMatches(want.items);
        want.shrinkRetainingCapacity(@min(want.items.len, limit));
        try testing.expectEqual(want.items.len, out.items.len);
        for (want.items, out.items) |wanted, found| {
            try testing.expectEqual(wanted.doc, found.doc);
            try testing.expectEqual(wanted.score, found.score);
            try testing.expectEqual(wanted.line, found.line);
            try testing.expectEqualStrings(wanted.snippet, found.snippet);
        }
    };
}

test "search: unaccented and capital queries find accented text" {
    const gpa = testing.allocator;
    var test_dir = try sys.TestDir.init();
    defer test_dir.deinit();
    const texts = [_][]const u8{
        "notas\nLa acción empieza aquí.\nfin\n",
        "el ÑANDÚ es un ave\n",
        "nothing to see\naccidental cion\n",
        "Configuración del sistema\n",
    };
    var test_paths: [texts.len][]u8 = undefined;
    var docs: [texts.len]DocIn = undefined;
    for (texts, 0..) |text, i| {
        test_paths[i] = try gpa.print("{s}/doc{d}.txt", .{ test_dir.absolute, i });
        var path_buffer: paths.Buffer = undefined;
        const path = try std.mem.printSentinel(&path_buffer, "{s}", .{test_paths[i]}, 0);
        try sys.writeFile(path, text);
        docs[i] = .{ .path = test_paths[i], .mtime = 0, .size = text.len };
    }
    defer for (test_paths) |path| gpa.free(path);
    const pool = try Pool.create(gpa, testing.io, 2);
    defer pool.destroy();
    var dummy: u8 = 0;
    const reader: TextReader = .{ .read = FileDocs.readText, .context = &dummy };
    var index = try build(gpa, pool, &docs, reader, null);
    defer index.deinit(gpa);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(Match) = .empty;
    const cases = [_]struct { query: []const u8, doc: u32, line: u32, snippet: []const u8 }{
        .{ .query = "accion", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .query = "ACCIÓN", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .query = "acción", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
        .{ .query = "nandu", .doc = 1, .line = 1, .snippet = "el ÑANDÚ es un ave" },
        .{ .query = "ñandú ave", .doc = 1, .line = 1, .snippet = "el ÑANDÚ es un ave" },
        .{ .query = "configuracion", .doc = 3, .line = 1, .snippet = "Configuración del sistema" },
        .{ .query = "aqui", .doc = 0, .line = 2, .snippet = "La acción empieza aquí." },
    };
    for (cases) |case| {
        try search(
            &index,
            gpa,
            arena.allocator(),
            pool,
            case.query,
            .{ .limit = 10, .text_path = plainPath, .text_context = &dummy },
            &out,
        );
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(case.doc, out.items[0].doc);
        try testing.expectEqual(case.line, out.items[0].line);
        try testing.expectEqualStrings(case.snippet, out.items[0].snippet);
    }
    try search(
        &index,
        gpa,
        arena.allocator(),
        pool,
        "×yz",
        .{ .limit = 10, .text_path = plainPath, .text_context = &dummy },
        &out,
    );
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // Not wanted any more (a newer query waits): no file is read.
    var stop: std.atomic.Value(bool) = .init(true);
    try search(
        &index,
        gpa,
        arena.allocator(),
        pool,
        "accion",
        .{ .limit = 10, .text_path = plainPath, .text_context = &dummy, .stop = &stop },
        &out,
    );
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

fn fuzzVerify(_: void, smith: *testing.Smith) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const weights: []const testing.Smith.Weight = &.{
        .value(u8, 'a', 20),
        .value(u8, 'b', 10),
        .value(u8, ' ', 8),
        .value(u8, '\n', 4),
        .rangeAtMost(u8, 0x80, 0xff, 1),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var text: [600]u8 = undefined;
    var query: [16]u8 = undefined;
    const text_used = text[0..smith.sliceWeightedBytes(&text, weights)];
    const query_used = query[0..smith.sliceWeightedBytes(&query, weights)];
    const words = try splitWords(arena, query_used);
    const phrase = try fold.foldAlloc(arena, std.mem.trim(u8, query_used, " \t"));
    if (verify(text_used, words, phrase, true, arena)) |verified| {
        try testing.expect(std.unicode.utf8ValidateSlice(verified.snippet));
        try testing.expect(verified.count >= 1);
        try testing.expect(verified.count <= count_cap);
        try testing.expect(verified.line >= 1);
    }
}

test "fuzz: verify on arbitrary text and queries" {
    try testing.fuzz({}, fuzzVerify, .{ .corpus = &.{
        "\x0d\x00\x00\x00ab\nxx ab ab b" ++ "\x05\x00\x00\x00ab  b",
    } });
}
