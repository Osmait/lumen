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
const sys = @import("os");
const store_mod = index.store;
const content = index.content;

var failures_count: usize = 0;
var scale: f64 = 1;

fn ms(duration_ns: u64) f64 {
    return @as(f64, @floatFromInt(duration_ns)) / 1e6;
}

fn check(name: []const u8, got_ms: f64, limit_ms: f64) void {
    const limit_scaled_ms = limit_ms * scale;
    const ok = got_ms <= limit_scaled_ms;
    if (!ok) failures_count += 1;
    const verdict = if (ok) "ok  " else "FAIL";
    std.debug.print("  {s} {s:<44} {d:>9.3} ms  (limit {d:.1})\n", .{
        verdict,
        name,
        got_ms,
        limit_scaled_ms,
    });
}

fn checkMB(name: []const u8, got_mb: f64, limit_mb: f64) void {
    const limit_scaled_mb = limit_mb * scale;
    const ok = got_mb <= limit_scaled_mb;
    if (!ok) failures_count += 1;
    const verdict = if (ok) "ok  " else "FAIL";
    std.debug.print("  {s} {s:<44} {d:>9.1} MB  (limit {d:.0})\n", .{
        verdict,
        name,
        got_mb,
        limit_scaled_mb,
    });
}

fn peakRssMB() f64 {
    var status_text: index.paths.Buffer = undefined;
    const status = sys.readHead("/proc/self/status", &status_text);
    const peak_at = std.mem.find(u8, status, "VmHWM:") orelse return 0;
    var fields = std.mem.tokenizeAny(u8, status[peak_at + "VmHWM:".len ..], " \t");
    const peak_kb = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
    return @as(f64, @floatFromInt(peak_kb)) / 1024;
}

const words = [_][]const u8{
    "cargo",
    "config",
    "main",
    "readme",
    "notes",
    "src",
    "test",
    "build",
    "lib",
    "index",
    "photo",
    "draft",
    "server",
    "client",
    "handler",
    "model",
    "store",
    "query",
    "parser",
    "token",
    "window",
    "theme",
    "invoice",
    "report",
};
const extensions = [_][]const u8{
    ".toml", ".rs", ".md", ".zig", ".json", ".png", ".go", ".ts", "",
};

/// ~1M entries: 25k directories over three levels, 40 files each.
fn syntheticNames(gpa: std.mem.Allocator) !store_mod.Store {
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var builder: store_mod.Builder = .empty;
    const root = try builder.push(gpa, "/home/perf", store_mod.no_parent, store_mod.flag_dir, 0);
    var level: std.ArrayList(u32) = .empty;
    defer level.deinit(gpa);
    try level.append(gpa, root);
    var name_text: [64]u8 = undefined;
    // Directories level by level (BFS order, as the scanner produces).
    var directories: std.ArrayList(u32) = .empty;
    defer directories.deinit(gpa);
    for ([_]usize{ 30, 30, 28 }, 1..) |fan, depth| {
        var next: std.ArrayList(u32) = .empty;
        for (level.items) |parent| {
            for (0..fan) |i| {
                const name = try std.mem.print(&name_text, "{s}-{d}", .{
                    words[random.uintLessThan(usize, words.len)],
                    i,
                });
                try next.append(gpa, try builder.push(
                    gpa,
                    name,
                    parent,
                    store_mod.flag_dir,
                    @intCast(depth),
                ));
            }
        }
        try directories.appendSlice(gpa, next.items);
        level.deinit(gpa);
        level = next;
    }
    for (directories.items) |directory| {
        for (0..40) |_| {
            const name = try std.mem.print(&name_text, "{s}_{s}{s}", .{
                words[random.uintLessThan(usize, words.len)],
                words[random.uintLessThan(usize, words.len)],
                extensions[random.uintLessThan(usize, extensions.len)],
            });
            _ = try builder.push(gpa, name, directory, 0, 4);
        }
    }
    return builder.finish(gpa);
}

fn names(gpa: std.mem.Allocator, pool: *index.Pool, directory: []const u8) !void {
    std.debug.print("name index\n", .{});
    var start_ns = sys.monotonicNs();
    var built = try syntheticNames(gpa);
    defer built.deinit(gpa);
    std.debug.print("       {d} entries built in {d:.0} ms\n", .{
        built.len(),
        ms(sys.monotonicNs() - start_ns),
    });

    var index_path_buffer: index.paths.Buffer = undefined;
    const index_path = try std.mem.printSentinel(
        &index_path_buffer,
        "{s}/names.idx",
        .{directory},
        0,
    );
    try built.save(index_path);
    start_ns = sys.monotonicNs();
    var mapped = try store_mod.Store.open(index_path);
    defer mapped.deinit(gpa);
    check("open (mmap + validate)", ms(sys.monotonicNs() - start_ns), 25);

    try coldQueries(gpa, pool, &mapped);
    // Typing: each keystroke refines the previous candidates.
    var engine: index.search.Engine = .empty;
    defer engine.deinit(gpa);
    var hits: std.ArrayList(index.search.Hit) = .empty;
    defer hits.deinit(gpa);
    const typed = "handler.rs";
    var keystroke_ns_max: u64 = 0;
    for (1..typed.len + 1) |typed_count| {
        start_ns = sys.monotonicNs();
        const options: index.search.Options = .{ .limit = 60, .recency = false };
        try engine.search(gpa, pool, &mapped, typed[0..typed_count], options, &hits);
        keystroke_ns_max = @max(keystroke_ns_max, sys.monotonicNs() - start_ns);
    }
    check("typing \"handler.rs\", worst keystroke", ms(keystroke_ns_max), 25);
}

/// Each query on a fresh engine: timed, and checked against the exhaustive
/// reference.
fn coldQueries(gpa: std.mem.Allocator, pool: *index.Pool, mapped: *const store_mod.Store) !void {
    var hits: std.ArrayList(index.search.Hit) = .empty;
    defer hits.deinit(gpa);
    var want: std.ArrayList(index.search.Hit) = .empty;
    defer want.deinit(gpa);
    // Worst cases are 1-2 letters (almost everything passes the mask).
    const cold = [_]struct { []const u8, f64 }{
        .{ "c", 20 },
        .{ "ca", 25 },
        .{ "cargo", 15 },
        .{ "cargo.toml", 10 },
        .{ "hndlr", 15 },
    };
    for (cold) |case| {
        const query, const limit_ms = case;
        var engine: index.search.Engine = .empty;
        defer engine.deinit(gpa);
        const start_ns = sys.monotonicNs();
        try engine.search(gpa, pool, mapped, query, .{ .limit = 60, .recency = false }, &hits);
        var label: [64]u8 = undefined;
        check(
            try std.mem.print(&label, "cold query \"{s}\"", .{query}),
            ms(sys.monotonicNs() - start_ns),
            limit_ms,
        );
        // Recall against the exhaustive reference: exact, not timed.
        try index.search.searchExhaustive(gpa, mapped, query, 60, &want);
        checkRecall(mapped, query, want.items, hits.items);
    }
}

/// Fails the run unless `got` scores exactly as `want`, and says what was
/// missed.
fn checkRecall(
    mapped: *const store_mod.Store,
    query: []const u8,
    want: []const index.search.Hit,
    got: []const index.search.Hit,
) void {
    var same = want.len == got.len;
    if (same) {
        for (want, got) |wanted, hit| {
            if (wanted.score != hit.score) same = false;
        }
    }
    if (same) return;
    failures_count += 1;
    var found: usize = 0;
    for (want) |wanted| {
        for (got) |hit| {
            if (hit.id == wanted.id) {
                found += 1;
                break;
            }
        }
    }
    std.debug.print("  FAIL recall for \"{s}\": {d}/{d} of the exhaustive top found\n", .{
        query,
        found,
        want.len,
    });
    for (want[0..@min(5, want.len)], 0..) |wanted, i| {
        const got_score = if (i < got.len) got[i].score else 0;
        const got_name = if (i < got.len) mapped.name(got[i].id) else "";
        std.debug.print("       want {d} {s}   got {d} {s}\n", .{
            wanted.score,
            mapped.name(wanted.id),
            got_score,
            got_name,
        });
    }
}

const vocabulary = [_][]const u8{
    "const",
    "return",
    "struct",
    "allocator",
    "buffer",
    "index",
    "query",
    "token",
    "parser",
    "window",
    "render",
    "TODO",
    "error",
    "result",
    "value",
    "string",
    "async",
    "await",
    "import",
    "export",
    "function",
    "useState",
    "SELECT",
    "FROM",
    "WHERE",
    "zebrafish",
    "the",
    "and",
    "for",
};

fn plainText(
    _: *anyopaque,
    document: content.DocIn,
    text: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    return content.readPlain(gpa, document.path, text);
}

fn contents(gpa: std.mem.Allocator, pool: *index.Pool, directory: []const u8) !void {
    std.debug.print("content index\n", .{});
    var prng = std.Random.DefaultPrng.init(2);
    const random = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var documents: std.ArrayList(content.DocIn) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var text_bytes: usize = 0;
    for (0..3000) |i| {
        text.clearRetainingCapacity();
        const lines = random.intRangeAtMost(usize, 20, 400);
        for (0..lines) |_| {
            for (0..random.intRangeAtMost(usize, 3, 12)) |_| {
                try text.appendSlice(arena, vocabulary[random.uintLessThan(usize, vocabulary.len)]);
                try text.append(arena, ' ');
            }
            try text.append(arena, '\n');
        }
        const document_path = try arena.printSentinel("{s}/doc{d:0>5}.txt", .{ directory, i }, 0);
        try sys.writeFile(document_path, text.items);
        text_bytes += text.items.len;
        try documents.append(arena, .{
            .path = document_path,
            .mtime = 1_700_000_000 + @as(i64, @intCast(i)),
            .size = text.items.len,
        });
    }
    std.debug.print("       {d} documents, {d:.1} MB of text\n", .{
        documents.items.len,
        @as(f64, @floatFromInt(text_bytes)) / 1e6,
    });

    var reader_context: u8 = 0;
    var start_ns = sys.monotonicNs();
    const reader: content.TextReader = .{ .read = plainText, .ctx = &reader_context };
    var built = try content.build(gpa, pool, documents.items, reader, null);
    defer built.deinit(gpa);
    check("build", ms(sys.monotonicNs() - start_ns), 1500);

    var matches: std.ArrayList(content.Match) = .empty;
    const queries = [_]struct { []const u8, f64 }{
        .{ "zebrafish", 30 },
        .{ "allocator", 40 },
        .{ "the", 40 },
        .{ "useState return", 40 },
        .{ "SELECT FROM WHERE", 50 },
        .{ "nothinghere", 5 },
    };
    for (queries) |case| {
        const query, const limit_ms = case;
        start_ns = sys.monotonicNs();
        try content.search(
            &built,
            gpa,
            arena,
            pool,
            query,
            .{ .limit = 50, .text_path = content.plainPath, .text_ctx = &reader_context },
            &matches,
        );
        var label: [64]u8 = undefined;
        check(
            try std.mem.print(&label, "search \"{s}\" ({d} hits)", .{ query, matches.items.len }),
            ms(sys.monotonicNs() - start_ns),
            limit_ms,
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    if (init.environ_map.get("PERF_SCALE")) |scale_text| {
        scale = std.fmt.parseFloat(f64, scale_text) catch 1;
    }
    const pool = try index.Pool.create(gpa, init.io, index.Pool.allCores());
    defer pool.destroy();

    var directory_buffer: [256]u8 = undefined;
    const pid = std.os.linux.getpid();
    const directory = try std.mem.print(&directory_buffer, "/tmp/lumen-perf-{d}", .{pid});
    try sys.mkdirP(directory);
    defer {
        const argv = [_][]const u8{ "rm", "-rf", directory };
        if (std.process.run(gpa, init.io, .{ .argv = &argv })) |result| {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        } else |err| {
            std.debug.print("could not delete {s}: {t}\n", .{ directory, err });
        }
    }

    try names(gpa, pool, directory);
    try contents(gpa, pool, directory);
    std.debug.print("memory\n", .{});
    checkMB("peak RSS of the whole run", peakRssMB(), 1200);

    if (failures_count > 0) {
        std.debug.print("\n{d} performance check(s) failed\n", .{failures_count});
        std.process.exit(1);
    }
    std.debug.print("\nall performance checks passed\n", .{});
}
