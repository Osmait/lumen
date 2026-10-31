//! `lumen-find`: the index from the command line, and its numbers.
//!
//!   lumen-find bench [ROOT]      scan, save, map, search latency and recall
//!   lumen-find QUERY [ROOT]      scan and print the top 20
//!   lumen-find content [ROOT] [QUERY]   build the content index, time queries
//!   lumen-find content-live      time queries through ContentService on the
//!                                daemon's saved index (PDFs included)

const std = @import("std");
const index = @import("index");
const sys = @import("os");
const Store = index.store.Store;

/// The first argument when it is not a query.
const Command = enum {
    bench,
    content,
    @"content-live",
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const first = args.next() orelse {
        std.debug.print("usage: lumen-find bench [ROOT] | lumen-find QUERY [ROOT]\n", .{});
        return;
    };
    const home = init.environ_map.get("HOME") orelse "/";
    const root: []const u8 = args.next() orelse home;

    const pool = try index.Pool.create(gpa, io, index.Pool.allCores());
    defer pool.destroy();
    // Anything else is a query.
    const command = std.meta.stringToEnum(Command, first);
    if (command == .content) return contentBench(gpa, io, pool, root, args.next());
    if (command == .@"content-live") {
        return contentLive(gpa, io, pool, init.environ_map.get("XDG_CACHE_HOME"), home);
    }

    var store = try scanRoot(gpa, pool, root);
    defer store.deinit(gpa);
    if (command != .bench) return printTop(gpa, pool, &store, first);

    // Save and map back: the start-up path.
    var temporary: TempDir = try .create();
    defer temporary.remove();
    var index_path_buffer: index.paths.Buffer = undefined;
    const index_path = try temporary.file(&index_path_buffer, "files.idx");
    var start_ns = sys.monotonicNs();
    try store.save(index_path);
    std.debug.print("save      {d:>8.1} ms\n", .{ms(sys.monotonicNs() - start_ns)});
    start_ns = sys.monotonicNs();
    var mapped = try Store.open(index_path);
    defer mapped.deinit(gpa);
    std.debug.print("map       {d:>8.3} ms\n", .{ms(sys.monotonicNs() - start_ns)});

    try coldQueries(gpa, pool, &mapped);
    try typing(gpa, pool, &mapped);
}

/// Scans `root` and prints how long it took and what it found.
fn scanRoot(gpa: std.mem.Allocator, pool: *index.Pool, root: []const u8) !Store {
    const config: index.scan.Config = .{ .roots = &.{root} };
    var stats: index.scan.Stats = .{};
    const store = try index.scan.scan(gpa, pool, &config, null, &stats);
    const scan_ms = ms(stats.elapsed_ns);
    const entries: f64 = @floatFromInt(store.len());
    const bytes: f64 = @floatFromInt(store.bytes.len);
    std.debug.print(
        "scan      {d:>8.1} ms  {d} entries ({d} dirs, {d} errors)  {d:.1} M/s  {d:.1} MB\n",
        .{
            scan_ms,
            store.len(),
            stats.dirs,
            stats.errors,
            entries / (scan_ms * 1000),
            bytes / 1e6,
        },
    );
    return store;
}

/// Searches `query` once and prints the top 20 with their scores.
fn printTop(
    gpa: std.mem.Allocator,
    pool: *index.Pool,
    store: *const Store,
    query: []const u8,
) !void {
    var engine: index.search.Engine = .empty;
    defer engine.deinit(gpa);
    var hits: std.ArrayList(index.search.Hit) = .empty;
    defer hits.deinit(gpa);
    const start_ns = sys.monotonicNs();
    try engine.search(gpa, pool, store, query, .{ .limit = 20 }, &hits);
    std.debug.print("search    {d:>8.3} ms\n", .{ms(sys.monotonicNs() - start_ns)});
    var path_buffer: index.paths.Buffer = undefined;
    for (hits.items, 1..) |hit, rank| {
        const path = store.path(hit.id, &path_buffer) orelse "?";
        std.debug.print("{d:>3}. {d:>5}  {s}\n", .{ rank, hit.score, path });
    }
}

/// Cold queries (a fresh engine each), with and without recency, at the
/// UI's 60 results, and their recall against the exhaustive reference.
fn coldQueries(gpa: std.mem.Allocator, pool: *index.Pool, mapped: *const Store) !void {
    const queries = [_][]const u8{
        "c",
        "ca",
        "cargo",
        "cargo.toml",
        "main.rs",
        "config",
        "readme",
        "confg",
        "mainrs",
        "build.zig",
    };
    var hits: std.ArrayList(index.search.Hit) = .empty;
    defer hits.deinit(gpa);
    var want: std.ArrayList(index.search.Hit) = .empty;
    defer want.deinit(gpa);
    std.debug.print("\n{s:<12} {s:>10} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{
        "query",
        "cold ms",
        "+recency",
        "UI (60)",
        "exhaust.",
        "recall",
    });
    for (queries) |query| {
        var engine: index.search.Engine = .empty;
        defer engine.deinit(gpa);
        var start_ns = sys.monotonicNs();
        try engine.search(gpa, pool, mapped, query, .{ .limit = 20, .recency = false }, &hits);
        const cold_ms = ms(sys.monotonicNs() - start_ns);
        engine.reset();
        start_ns = sys.monotonicNs();
        try engine.search(gpa, pool, mapped, query, .{ .limit = 20 }, &hits);
        const recency_ms = ms(sys.monotonicNs() - start_ns);
        // What Search Files asks: 60 results, with recency.
        engine.reset();
        start_ns = sys.monotonicNs();
        try engine.search(gpa, pool, mapped, query, .{ .limit = 60 }, &hits);
        const ui_ms = ms(sys.monotonicNs() - start_ns);
        try engine.search(gpa, pool, mapped, query, .{ .limit = 20, .recency = false }, &hits);
        start_ns = sys.monotonicNs();
        try index.search.searchExhaustive(gpa, mapped, query, 20, &want);
        const exhaustive_ms = ms(sys.monotonicNs() - start_ns);
        std.debug.print("{s:<12} {d:>10.3} {d:>10.3} {d:>10.3} {d:>10.1} {d:>7.0}%\n", .{
            query,
            cold_ms,
            recency_ms,
            ui_ms,
            exhaustive_ms,
            recallPercent(want.items, hits.items),
        });
    }
}

/// How many of `want` are among `got`, in percent (100 when `want` is empty).
fn recallPercent(want: []const index.search.Hit, got: []const index.search.Hit) f64 {
    if (want.len == 0) return 100.0;
    var same: usize = 0;
    for (want) |wanted| {
        for (got) |hit| {
            if (hit.id == wanted.id) {
                same += 1;
                break;
            }
        }
    }
    const same_count: f64 = @floatFromInt(same);
    const want_count: f64 = @floatFromInt(want.len);
    return 100.0 * same_count / want_count;
}

/// "cargo.toml" typed letter by letter on one engine, as the UI does.
fn typing(gpa: std.mem.Allocator, pool: *index.Pool, mapped: *const Store) !void {
    std.debug.print(
        "\ntyping \"cargo.toml\" letter by letter (engine reused, 60 results with recency as the UI asks):\n",
        .{},
    );
    var engine: index.search.Engine = .empty;
    defer engine.deinit(gpa);
    var hits: std.ArrayList(index.search.Hit) = .empty;
    defer hits.deinit(gpa);
    const typed = "cargo.toml";
    for (1..typed.len + 1) |typed_count| {
        const start_ns = sys.monotonicNs();
        try engine.search(gpa, pool, mapped, typed[0..typed_count], .{ .limit = 60 }, &hits);
        const elapsed_ms = ms(sys.monotonicNs() - start_ns);
        std.debug.print("  {s:<12} {d:>8.3} ms\n", .{ typed[0..typed_count], elapsed_ms });
    }
    var path_buffer: index.paths.Buffer = undefined;
    std.debug.print("\ntop 5 for \"cargo.toml\":\n", .{});
    for (hits.items[0..@min(5, hits.items.len)]) |hit| {
        std.debug.print("  {s}\n", .{mapped.path(hit.id, &path_buffer) orelse "?"});
    }
}

fn ms(duration_ns: u64) f64 {
    return @as(f64, @floatFromInt(duration_ns)) / 1e6;
}

/// A folder of our own under /tmp for the files a bench writes: a fixed
/// name there could be anyone's (a link planted to a file of yours).
const TempDir = struct {
    /// The folder's path is `path_buffer[0..path_length]`.
    path_buffer: [64]u8 = undefined,
    path_length: usize = 0,
    files: [2][:0]const u8 = undefined,
    files_count: usize = 0,

    fn create() !TempDir {
        var temporary: TempDir = .{};
        const linux = std.os.linux;
        for (0..100) |attempt| {
            const unique = .{ linux.getpid(), sys.monotonicNs(), attempt };
            const pattern = "/tmp/lumen-find-{d}-{d}-{d}";
            const path = try std.mem.printSentinel(&temporary.path_buffer, pattern, unique, 0);
            // Fails if anything is there already, a link included.
            if (linux.errno(linux.mkdir(path, 0o700)) == .SUCCESS) {
                temporary.path_length = path.len;
                return temporary;
            }
        }
        return error.TempDir;
    }

    /// `name` inside it, removed with it.
    fn file(temporary: *TempDir, path_buffer: []u8, name: []const u8) ![:0]const u8 {
        const folder = temporary.path_buffer[0..temporary.path_length];
        const path = try std.mem.printSentinel(path_buffer, "{s}/{s}", .{ folder, name }, 0);
        temporary.files[temporary.files_count] = path;
        temporary.files_count += 1;
        return path;
    }

    /// Deletes the files and the folder. A file the bench never wrote is not
    /// there to delete; anything else left behind is said.
    fn remove(temporary: *TempDir) void {
        const linux = std.os.linux;
        for (temporary.files[0..temporary.files_count]) |path| {
            const unlinked = linux.errno(linux.unlink(path));
            if (unlinked != .SUCCESS and unlinked != .NOENT) {
                std.debug.print("could not delete {s}: {t}\n", .{ path, unlinked });
            }
        }
        const folder = temporary.path_buffer[0..temporary.path_length :0];
        const removed = linux.errno(linux.rmdir(folder));
        if (removed != .SUCCESS) {
            std.debug.print("could not delete {s}: {t}\n", .{ folder, removed });
        }
    }
};

fn plainText(
    _: *anyopaque,
    document: index.content.DocIn,
    text: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    if (document.source != .plain) return false;
    return index.content.readPlain(gpa, document.path, text);
}

fn contentBench(
    gpa: std.mem.Allocator,
    io: std.Io,
    pool: *index.Pool,
    root: []const u8,
    one_query: ?[]const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var start_ns = sys.monotonicNs();
    const documents = try index.content_list.list(arena, gpa, io, root, .{ .documents = false });
    var bytes: u64 = 0;
    for (documents) |document| bytes += document.size;
    std.debug.print("list      {d:>8.1} ms  {d} text files, {d:.0} MB\n", .{
        ms(sys.monotonicNs() - start_ns),
        documents.len,
        @as(f64, @floatFromInt(bytes)) / 1e6,
    });

    var build_stats: index.content.BuildStats = .{};
    var reader_context: u8 = 0;
    // Written to the file as it grows, as the daemon builds it.
    var temporary: TempDir = try .create();
    defer temporary.remove();
    var index_path_buffer: index.paths.Buffer = undefined;
    const index_path = try temporary.file(&index_path_buffer, "content.idx");
    const reader: index.content.TextReader = .{ .read = plainText, .ctx = &reader_context };
    var built = try index.content.buildFile(gpa, pool, documents, reader, index_path, &build_stats);
    defer built.deinit(gpa);
    std.debug.print(
        "build     {d:>8.1} ms  {d} pairs, {d} segments, index {d:.1} MB (postings {d:.1} MB)\n",
        .{
            ms(build_stats.ns),
            build_stats.pairs,
            build_stats.segments,
            @as(f64, @floatFromInt(built.buf.len)) / 1e6,
            @as(f64, @floatFromInt(built.postingBytes())) / 1e6,
        },
    );
    start_ns = sys.monotonicNs();
    var mapped = try index.content.Index.open(index_path);
    defer mapped.deinit(gpa);
    std.debug.print("map       {d:>8.3} ms\n\n", .{ms(sys.monotonicNs() - start_ns)});
    try contentQueries(gpa, arena, pool, &mapped, one_query);
}

/// Times each query on the content index `mapped`; with `one_query`, that
/// query alone and its first ten matches.
fn contentQueries(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    pool: *index.Pool,
    mapped: *index.content.Index,
    one_query: ?[]const u8,
) !void {
    const queries: []const []const u8 = if (one_query) |query| &.{query} else &.{
        "ArenaAllocator",
        "fn main",
        "TODO",
        "hyprland",
        "layerrule",
        "zzqxjv",
        "the",
        "useState",
        "SELECT * FROM",
        "launcher extension",
    };
    var path_context: u8 = 0;
    var matches: std.ArrayList(index.content.Match) = .empty;
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(gpa);
    std.debug.print("{s:<20} {s:>9} {s:>9} {s:>9}\n", .{ "query", "cands", "matches", "ms" });
    for (queries) |query| {
        const words = try index.content.splitWords(arena, query);
        try mapped.candidates(gpa, words, &candidates);
        const start_ns = sys.monotonicNs();
        try index.content.search(
            mapped,
            gpa,
            arena,
            pool,
            query,
            .{ .limit = 50, .text_path = index.content.plainPath, .text_ctx = &path_context },
            &matches,
        );
        std.debug.print("{s:<20} {d:>9} {d:>9} {d:>9.2}\n", .{
            query,
            candidates.items.len,
            matches.items.len,
            ms(sys.monotonicNs() - start_ns),
        });
    }
    if (one_query != null) {
        for (matches.items[0..@min(10, matches.items.len)]) |match| {
            const document_path = mapped.path(match.doc);
            std.debug.print("  {s}:{d}  {s}\n", .{ document_path, match.line, match.snippet });
        }
    }
}

/// Same path as the daemon: ContentService over ~/.cache/lumen, extracted
/// documents included, every query timed with a breakdown.
fn contentLive(
    gpa: std.mem.Allocator,
    io: std.Io,
    pool: *index.Pool,
    xdg_cache: ?[]const u8,
    home: []const u8,
) !void {
    var cache_buffer: index.paths.Buffer = undefined;
    const cache = if (xdg_cache) |cache_home|
        try std.mem.print(&cache_buffer, "{s}/lumen", .{cache_home})
    else
        try std.mem.print(&cache_buffer, "{s}/.cache/lumen", .{home});
    const build_pool = try index.Pool.create(gpa, io, index.Pool.halfCores());
    defer build_pool.destroy();
    const service = try index.ContentService.start(gpa, io, home, cache, .{
        .search = pool,
        .build = build_pool,
    });
    defer service.shutdown();
    while (!service.status().ready) sys.sleepUs(10_000);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var hits: std.ArrayList(index.ContentService.Hit) = .empty;
    const queries = [_][]const u8{
        "Arena",
        "ArenaAlloc",
        "ArenaAllocator",
        "TODO",
        "useState",
        "fn main",
        "the",
        "binary search",
        "zzqxjv",
    };
    std.debug.print("{s:<16} {s:>9} {s:>9} {s:>9}\n", .{ "query", "hits", "1st ms", "2nd ms" });
    for (queries) |query| {
        _ = arena_state.reset(.retain_capacity);
        // Its buffer lived in the arena just reset.
        hits = .empty;
        var start_ns = sys.monotonicNs();
        try service.search(arena_state.allocator(), query, 50, &hits);
        const first_ms = ms(sys.monotonicNs() - start_ns);
        start_ns = sys.monotonicNs();
        try service.search(arena_state.allocator(), query, 50, &hits);
        std.debug.print("{s:<16} {d:>9} {d:>9.2} {d:>9.2}\n", .{
            query,
            hits.items.len,
            first_ms,
            ms(sys.monotonicNs() - start_ns),
        });
    }
}
