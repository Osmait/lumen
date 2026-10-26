//! `lumen-find`: the index from the command line, and its numbers.
//!
//!   lumen-find bench [ROOT]      scan, save, map, search latency and recall
//!   lumen-find QUERY [ROOT]      scan and print the top 20
//!   lumen-find content [ROOT] [QUERY]   build the content index, time queries
//!   lumen-find content-live      time queries through ContentService on the
//!                                daemon's saved index (PDFs included)

const std = @import("std");
const index = @import("index");
const sys = index.sys;
const Store = index.store.Store;

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse {
        std.debug.print("usage: lumen-find bench [ROOT] | lumen-find QUERY [ROOT]\n", .{});
        return;
    };
    const home = init.environ_map.get("HOME") orelse "/";
    const root: []const u8 = args.next() orelse home;

    const pool = try index.Pool.create(gpa, io, index.Pool.allCores());
    defer pool.destroy();
    if (std.mem.eql(u8, cmd, "content")) return contentBench(gpa, io, pool, root, args.next());
    if (std.mem.eql(u8, cmd, "content-live")) return contentLive(gpa, io, pool, init.environ_map.get("XDG_CACHE_HOME"), home);
    const cfg: index.scan.Config = .{ .roots = &.{root} };

    var stats: index.scan.Stats = .{};
    var store = try index.scan.scan(gpa, pool, &cfg, null, &stats);
    defer store.deinit(gpa);
    std.debug.print("scan      {d:>8.1} ms  {d} entries ({d} dirs, {d} errors)  {d:.1} M/s  {d:.1} MB\n", .{
        ms(stats.ns),                                                 store.len(),                                  stats.dirs, stats.errors,
        @as(f64, @floatFromInt(store.len())) / (ms(stats.ns) * 1000), @as(f64, @floatFromInt(store.buf.len)) / 1e6,
    });

    if (!std.mem.eql(u8, cmd, "bench")) {
        var e: index.search.Engine = .empty;
        defer e.deinit(gpa);
        var hits: std.ArrayList(index.search.Hit) = .empty;
        defer hits.deinit(gpa);
        const t = sys.monotonicNs();
        try e.search(gpa, pool, &store, cmd, .{ .limit = 20 }, &hits);
        std.debug.print("search    {d:>8.3} ms\n", .{ms(sys.monotonicNs() - t)});
        var buf: [4096]u8 = undefined;
        for (hits.items, 1..) |h, i| std.debug.print("{d:>3}. {d:>5}  {s}\n", .{ i, h.score, store.path(h.id, &buf) });
        return;
    }

    // Save and map back: the start-up path.
    const path = "/tmp/lumen-find-bench.idx";
    var t = sys.monotonicNs();
    try store.save(path);
    std.debug.print("save      {d:>8.1} ms\n", .{ms(sys.monotonicNs() - t)});
    t = sys.monotonicNs();
    var mapped = try Store.open(path);
    defer mapped.deinit(gpa);
    std.debug.print("map       {d:>8.3} ms\n", .{ms(sys.monotonicNs() - t)});

    // Cold queries (fresh engine), then typed letter by letter (refinement).
    const queries = [_][]const u8{ "c", "ca", "cargo", "cargo.toml", "main.rs", "config", "readme", "confg", "mainrs", "build.zig" };
    var hits: std.ArrayList(index.search.Hit) = .empty;
    defer hits.deinit(gpa);
    var want: std.ArrayList(index.search.Hit) = .empty;
    defer want.deinit(gpa);
    std.debug.print("\n{s:<12} {s:>10} {s:>10} {s:>10} {s:>8}\n", .{ "query", "cold ms", "+recency", "exhaust.", "recall" });
    for (queries) |q| {
        var e: index.search.Engine = .empty;
        defer e.deinit(gpa);
        t = sys.monotonicNs();
        try e.search(gpa, pool, &mapped, q, .{ .limit = 20, .recency = false }, &hits);
        const cold = ms(sys.monotonicNs() - t);
        e.reset();
        t = sys.monotonicNs();
        try e.search(gpa, pool, &mapped, q, .{ .limit = 20 }, &hits);
        const rec = ms(sys.monotonicNs() - t);
        try e.search(gpa, pool, &mapped, q, .{ .limit = 20, .recency = false }, &hits);
        t = sys.monotonicNs();
        try index.search.searchExhaustive(gpa, &mapped, q, 20, &want);
        const ex = ms(sys.monotonicNs() - t);
        var same: usize = 0;
        for (want.items) |w| {
            for (hits.items) |h| if (h.id == w.id) {
                same += 1;
                break;
            };
        }
        const recall = if (want.items.len == 0) 100.0 else 100.0 * @as(f64, @floatFromInt(same)) / @as(f64, @floatFromInt(want.items.len));
        std.debug.print("{s:<12} {d:>10.3} {d:>10.3} {d:>10.1} {d:>7.0}%\n", .{ q, cold, rec, ex, recall });
    }

    std.debug.print("\ntyping \"cargo.toml\" letter by letter (engine reused):\n", .{});
    var e: index.search.Engine = .empty;
    defer e.deinit(gpa);
    const typed = "cargo.toml";
    for (1..typed.len + 1) |n| {
        t = sys.monotonicNs();
        try e.search(gpa, pool, &mapped, typed[0..n], .{ .limit = 20 }, &hits);
        std.debug.print("  {s:<12} {d:>8.3} ms\n", .{ typed[0..n], ms(sys.monotonicNs() - t) });
    }
    var buf: [4096]u8 = undefined;
    std.debug.print("\ntop 5 for \"cargo.toml\":\n", .{});
    for (hits.items[0..@min(5, hits.items.len)]) |h| std.debug.print("  {s}\n", .{mapped.path(h.id, &buf)});
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn plainText(_: *anyopaque, d: index.content.DocIn, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
    if (d.source != .plain) return false;
    return index.content.readPlain(gpa, d.path, buf);
}

fn contentBench(gpa: std.mem.Allocator, io: std.Io, pool: *index.Pool, root: []const u8, one_query: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t = sys.monotonicNs();
    const docs = try index.content_list.list(arena, gpa, io, root, false);
    var bytes: u64 = 0;
    for (docs) |d| bytes += d.size;
    std.debug.print("list      {d:>8.1} ms  {d} text files, {d:.0} MB\n", .{ ms(sys.monotonicNs() - t), docs.len, @as(f64, @floatFromInt(bytes)) / 1e6 });

    var st: index.content.BuildStats = .{};
    var dummy: u8 = 0;
    var ix = try index.content.build(gpa, pool, docs, .{ .read = plainText, .ctx = &dummy }, &st);
    defer ix.deinit(gpa);
    std.debug.print("build     {d:>8.1} ms  {d} pairs, {d} segments, index {d:.1} MB (postings {d:.1} MB)\n", .{ ms(st.ns), st.pairs, st.segments, @as(f64, @floatFromInt(ix.buf.len)) / 1e6, @as(f64, @floatFromInt(ix.postingBytes())) / 1e6 });
    const path = "/tmp/lumen-content-bench.idx";
    try ix.save(path);
    t = sys.monotonicNs();
    var mapped = try index.content.Index.open(path);
    defer mapped.deinit(gpa);
    std.debug.print("map       {d:>8.3} ms\n\n", .{ms(sys.monotonicNs() - t)});

    const queries: []const []const u8 = if (one_query) |q| &.{q} else &.{ "ArenaAllocator", "fn main", "TODO", "hyprland", "layerrule", "zzqxjv", "the", "useState", "SELECT * FROM", "launcher extension" };
    var matches: std.ArrayList(index.content.Match) = .empty;
    var cands: std.ArrayList(u32) = .empty;
    defer cands.deinit(gpa);
    std.debug.print("{s:<20} {s:>9} {s:>9} {s:>9}\n", .{ "query", "cands", "matches", "ms" });
    for (queries) |q| {
        const words = try index.content.splitWords(arena, q);
        try mapped.candidates(gpa, words, &cands);
        t = sys.monotonicNs();
        try index.content.search(&mapped, gpa, arena, pool, q, .{ .limit = 50, .text_path = index.content.plainPath, .text_ctx = &dummy }, &matches);
        std.debug.print("{s:<20} {d:>9} {d:>9} {d:>9.2}\n", .{ q, cands.items.len, matches.items.len, ms(sys.monotonicNs() - t) });
    }
    if (one_query != null) {
        for (matches.items[0..@min(10, matches.items.len)]) |m| std.debug.print("  {s}:{d}  {s}\n", .{ mapped.path(m.doc), m.line, m.snippet });
    }
}

/// Same path as the daemon: ContentService over ~/.cache/lumen, extracted
/// documents included, every query timed with a breakdown.
fn contentLive(gpa: std.mem.Allocator, io: std.Io, pool: *index.Pool, xdg_cache: ?[]const u8, home: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const cache = if (xdg_cache) |x| try std.fmt.bufPrint(&buf, "{s}/lumen", .{x}) else try std.fmt.bufPrint(&buf, "{s}/.cache/lumen", .{home});
    const build_pool = try index.Pool.create(gpa, io, index.Pool.halfCores());
    defer build_pool.destroy();
    const cs = try index.ContentService.start(gpa, io, home, cache, .{ .search = pool, .build = build_pool });
    defer cs.shutdown();
    while (!cs.status().ready) sys.sleepUs(10_000);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var hits: std.ArrayList(index.ContentService.Hit) = .empty;
    const queries = [_][]const u8{ "Arena", "ArenaAlloc", "ArenaAllocator", "TODO", "useState", "fn main", "the", "binary search", "zzqxjv" };
    std.debug.print("{s:<16} {s:>9} {s:>9} {s:>9}\n", .{ "query", "hits", "1st ms", "2nd ms" });
    for (queries) |q| {
        _ = arena_state.reset(.retain_capacity);
        // Its buffer lived in the arena just reset.
        hits = .empty;
        var t = sys.monotonicNs();
        try cs.search(arena_state.allocator(), q, 50, &hits);
        const first = ms(sys.monotonicNs() - t);
        t = sys.monotonicNs();
        try cs.search(arena_state.allocator(), q, 50, &hits);
        std.debug.print("{s:<16} {d:>9} {d:>9.2} {d:>9.2}\n", .{ q, hits.items.len, first, ms(sys.monotonicNs() - t) });
    }
}
