//! Performance regression tests: `zig build perf` (ReleaseFast).
//!
//! Synthetic, deterministic data (no dependence on this machine's files):
//! a 1M-entry name index and a 3,000-document content corpus. Each check has
//! a limit around 4-5x what it measures on the development machine (Ryzen
//! 5600X, 12 threads), so it catches regressions without flaking; scale the
//! limits with PERF_SCALE=2 (etc.) on slower machines. Latency is
//! asserted, recall is asserted exactly.

const std = @import("std");
const index = @import("index");
const sys = index.sys;
const store_mod = index.store;
const content = index.content;

var failures: usize = 0;
var scale: f64 = 1;

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn check(name: []const u8, got_ms: f64, limit_ms: f64) void {
    const limit = limit_ms * scale;
    const ok = got_ms <= limit;
    if (!ok) failures += 1;
    std.debug.print("  {s} {s:<44} {d:>9.3} ms  (limit {d:.1})\n", .{ if (ok) "ok  " else "FAIL", name, got_ms, limit });
}

fn checkMB(name: []const u8, got: f64, limit: f64) void {
    const ok = got <= limit * scale;
    if (!ok) failures += 1;
    std.debug.print("  {s} {s:<44} {d:>9.1} MB  (limit {d:.0})\n", .{ if (ok) "ok  " else "FAIL", name, got, limit * scale });
}

fn peakRssMB() f64 {
    var buf: [4096]u8 = undefined;
    const status = sys.readHead("/proc/self/status", &buf);
    const at = std.mem.find(u8, status, "VmHWM:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, status[at + 6 ..], " \t");
    return @as(f64, @floatFromInt(std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0)) / 1024;
}

const words = [_][]const u8{ "cargo", "config", "main", "readme", "notes", "src", "test", "build", "lib", "index", "photo", "draft", "server", "client", "handler", "model", "store", "query", "parser", "token", "window", "theme", "invoice", "report" };
const exts = [_][]const u8{ ".toml", ".rs", ".md", ".zig", ".json", ".png", ".go", ".ts", "" };

/// ~1M entries: 25k directories over three levels, 40 files each.
fn syntheticNames(gpa: std.mem.Allocator) !store_mod.Store {
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var b: store_mod.Builder = .empty;
    const root = try b.push(gpa, "/home/perf", store_mod.no_parent, store_mod.flag_dir, 0);
    var level: std.ArrayList(u32) = .empty;
    defer level.deinit(gpa);
    try level.append(gpa, root);
    var nb: [64]u8 = undefined;
    // Directories level by level (BFS order, as the scanner produces).
    var all_dirs: std.ArrayList(u32) = .empty;
    defer all_dirs.deinit(gpa);
    for ([_]usize{ 30, 30, 28 }, 1..) |fan, depth| {
        var next: std.ArrayList(u32) = .empty;
        for (level.items) |parent| {
            for (0..fan) |i| {
                const n = try std.mem.print(&nb, "{s}-{d}", .{ words[r.uintLessThan(usize, words.len)], i });
                try next.append(gpa, try b.push(gpa, n, parent, store_mod.flag_dir, @intCast(depth)));
            }
        }
        try all_dirs.appendSlice(gpa, next.items);
        level.deinit(gpa);
        level = next;
    }
    for (all_dirs.items) |d| {
        for (0..40) |_| {
            const n = try std.mem.print(&nb, "{s}_{s}{s}", .{ words[r.uintLessThan(usize, words.len)], words[r.uintLessThan(usize, words.len)], exts[r.uintLessThan(usize, exts.len)] });
            _ = try b.push(gpa, n, d, 0, 4);
        }
    }
    return b.finish(gpa);
}

fn names(gpa: std.mem.Allocator, pool: *index.Pool, dir: []const u8) !void {
    std.debug.print("name index\n", .{});
    var t = sys.monotonicNs();
    var s = try syntheticNames(gpa);
    defer s.deinit(gpa);
    std.debug.print("       {d} entries built in {d:.0} ms\n", .{ s.len(), ms(sys.monotonicNs() - t) });

    var pbuf: [4096]u8 = undefined;
    const path = try std.mem.printSentinel(&pbuf, "{s}/names.idx", .{dir}, 0);
    try s.save(path);
    t = sys.monotonicNs();
    var m = try store_mod.Store.open(path);
    defer m.deinit(gpa);
    check("open (mmap + validate)", ms(sys.monotonicNs() - t), 25);

    var hits: std.ArrayList(index.search.Hit) = .empty;
    defer hits.deinit(gpa);
    var want: std.ArrayList(index.search.Hit) = .empty;
    defer want.deinit(gpa);
    // Worst cases are 1-2 letters (almost everything passes the mask).
    const cold = [_]struct { []const u8, f64 }{ .{ "c", 20 }, .{ "ca", 25 }, .{ "cargo", 15 }, .{ "cargo.toml", 10 }, .{ "hndlr", 15 } };
    for (cold) |q| {
        var e: index.search.Engine = .empty;
        defer e.deinit(gpa);
        t = sys.monotonicNs();
        try e.search(gpa, pool, &m, q[0], .{ .limit = 60, .recency = false }, &hits);
        var label: [64]u8 = undefined;
        check(try std.mem.print(&label, "cold query \"{s}\"", .{q[0]}), ms(sys.monotonicNs() - t), q[1]);
        // Recall against the exhaustive reference: exact, not timed.
        try index.search.searchExhaustive(gpa, &m, q[0], 60, &want);
        var same = want.items.len == hits.items.len;
        if (same) for (want.items, hits.items) |w, h| {
            if (w.score != h.score) same = false;
        };
        if (!same) {
            failures += 1;
            var found: usize = 0;
            for (want.items) |w| {
                for (hits.items) |h| if (h.id == w.id) {
                    found += 1;
                    break;
                };
            }
            std.debug.print("  FAIL recall for \"{s}\": {d}/{d} of the exhaustive top found\n", .{ q[0], found, want.items.len });
            for (want.items[0..@min(5, want.items.len)], 0..) |w, i| {
                var b1: [256]u8 = undefined;
                var b2: [256]u8 = undefined;
                std.debug.print("       want {d} {s}   got {d} {s}\n", .{ w.score, m.name(w.id), if (i < hits.items.len) hits.items[i].score else 0, if (i < hits.items.len) m.name(hits.items[i].id) else "" });
                _ = &b1;
                _ = &b2;
            }
        }
    }
    // Typing: each keystroke refines the previous candidates.
    var e: index.search.Engine = .empty;
    defer e.deinit(gpa);
    const typed = "handler.rs";
    var worst: u64 = 0;
    for (1..typed.len + 1) |n| {
        t = sys.monotonicNs();
        try e.search(gpa, pool, &m, typed[0..n], .{ .limit = 60, .recency = false }, &hits);
        worst = @max(worst, sys.monotonicNs() - t);
    }
    check("typing \"handler.rs\", worst keystroke", ms(worst), 25);
}

const vocab = [_][]const u8{ "const", "return", "struct", "allocator", "buffer", "index", "query", "token", "parser", "window", "render", "TODO", "error", "result", "value", "string", "async", "await", "import", "export", "function", "useState", "SELECT", "FROM", "WHERE", "zebrafish", "the", "and", "for" };

fn plainText(_: *anyopaque, d: content.DocIn, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) std.mem.Allocator.Error!bool {
    return content.readPlain(gpa, d.path, buf);
}

fn contents(gpa: std.mem.Allocator, pool: *index.Pool, dir: []const u8) !void {
    std.debug.print("content index\n", .{});
    var prng = std.Random.DefaultPrng.init(2);
    const r = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var docs: std.ArrayList(content.DocIn) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var total: usize = 0;
    for (0..3000) |i| {
        text.clearRetainingCapacity();
        const lines = r.intRangeAtMost(usize, 20, 400);
        for (0..lines) |_| {
            for (0..r.intRangeAtMost(usize, 3, 12)) |_| {
                try text.appendSlice(a, vocab[r.uintLessThan(usize, vocab.len)]);
                try text.append(a, ' ');
            }
            try text.append(a, '\n');
        }
        const p = try a.printSentinel("{s}/doc{d:0>5}.txt", .{ dir, i }, 0);
        try sys.writeFile(p, text.items);
        total += text.items.len;
        try docs.append(a, .{ .path = p, .mtime = 1_700_000_000 + @as(i64, @intCast(i)), .size = text.items.len });
    }
    std.debug.print("       {d} documents, {d:.1} MB of text\n", .{ docs.items.len, @as(f64, @floatFromInt(total)) / 1e6 });

    var dummy: u8 = 0;
    var t = sys.monotonicNs();
    var ix = try content.build(gpa, pool, docs.items, .{ .read = plainText, .ctx = &dummy }, null);
    defer ix.deinit(gpa);
    check("build", ms(sys.monotonicNs() - t), 1500);

    var matches: std.ArrayList(content.Match) = .empty;
    const queries = [_]struct { []const u8, f64 }{ .{ "zebrafish", 30 }, .{ "allocator", 40 }, .{ "the", 40 }, .{ "useState return", 40 }, .{ "SELECT FROM WHERE", 50 }, .{ "nothinghere", 5 } };
    for (queries) |q| {
        t = sys.monotonicNs();
        try content.search(&ix, gpa, a, pool, q[0], .{ .limit = 50, .text_path = content.plainPath, .text_ctx = &dummy }, &matches);
        var label: [64]u8 = undefined;
        check(try std.mem.print(&label, "search \"{s}\" ({d} hits)", .{ q[0], matches.items.len }), ms(sys.monotonicNs() - t), q[1]);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    if (init.environ_map.get("PERF_SCALE")) |s| scale = std.fmt.parseFloat(f64, s) catch 1;
    const pool = try index.Pool.create(gpa, init.io, index.Pool.allCores());
    defer pool.destroy();

    var dbuf: [256]u8 = undefined;
    const dir = try std.mem.print(&dbuf, "/tmp/lumen-perf-{d}", .{std.os.linux.getpid()});
    sys.mkdirP(dir);
    defer {
        const argv = [_][]const u8{ "rm", "-rf", dir };
        if (std.process.run(gpa, init.io, .{ .argv = &argv })) |res| {
            gpa.free(res.stdout);
            gpa.free(res.stderr);
        } else |_| {}
    }

    try names(gpa, pool, dir);
    try contents(gpa, pool, dir);
    std.debug.print("memory\n", .{});
    checkMB("peak RSS of the whole run", peakRssMB(), 1200);

    if (failures > 0) {
        std.debug.print("\n{d} performance check(s) failed\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nall performance checks passed\n", .{});
}
