//! Performance regression tests: `zig build perf`, built as a release is
//! (Lumen's modules ReleaseSafe, the C libraries optimized).
//!
//! Synthetic, deterministic data (no dependence on this machine's files):
//! a 1M-entry name index, a 3,000-document content corpus, a 26k-entry
//! tree on disk to scan, 50k launcher lines to fuzzy-score and Lua pattern
//! work. Each check has a limit around 4-5x what it measures on the
//! development machine (Ryzen 5600X, 12 threads), so it catches gross
//! regressions without flaking; scale the limits with PERF_SCALE=2 (etc.)
//! on slower machines. Latency is asserted, recall is asserted exactly.
//! Smaller regressions are what `tools/perf-compare.sh` is for: the same
//! checks on two commits, side by side.

const std = @import("std");
const index = @import("index");
const sys = @import("os");
const core = @import("core");
const lua = @import("luart").lua;
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

/// The median of `runs` timings of `work(context)`: one sample is at the
/// mercy of whatever else the machine does.
fn medianNs(
    comptime runs: usize,
    context: anytype,
    comptime work: fn (@TypeOf(context)) anyerror!void,
) !u64 {
    var times: [runs]u64 = undefined;
    for (&times) |*time| {
        const start_ns = sys.monotonicNs();
        try work(context);
        time.* = sys.monotonicNs() - start_ns;
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    return times[runs / 2];
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

/// One synthetic folder's entries, sorted by name before they are pushed:
/// what the scanner leaves (`Store` checks it).
const FolderEntries = struct {
    const entries_max = 70;
    const name_bytes_max = 64;
    const Entry = struct { name: []const u8, is_dir: bool };
    texts: [entries_max][name_bytes_max]u8 = undefined,
    entries: [entries_max]Entry = undefined,
    count: usize = 0,

    fn add(folder: *FolderEntries, is_dir: bool, comptime fmt: []const u8, args: anytype) void {
        std.debug.assert(folder.count < entries_max);
        const text = &folder.texts[folder.count];
        const name = std.mem.print(text, fmt, args) catch unreachable;
        folder.entries[folder.count] = .{ .name = name, .is_dir = is_dir };
        folder.count += 1;
    }

    fn sorted(folder: *FolderEntries) []const Entry {
        const entries = folder.entries[0..folder.count];
        std.mem.sort(Entry, entries, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        return entries;
    }
};

const files_per_directory = 40;

/// ~1.07M entries in the shape of a real home: 26k folders over three
/// levels, each with 40 files next to its subfolders, so files sit at every
/// depth. In the order the scanner leaves: level by level, each folder's
/// names sorted (`Store` checks both).
fn syntheticNames(gpa: std.mem.Allocator) !store_mod.Store {
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var builder: store_mod.Builder = .empty;
    const root = try builder.push(gpa, "/home/perf", store_mod.no_parent, store_mod.flag_dir, 0);
    var level: std.ArrayList(u32) = .empty;
    defer level.deinit(gpa);
    try level.append(gpa, root);
    // Subfolders per folder at each depth; the deepest folders hold files only.
    const fans = [_]usize{ 30, 30, 28, 0 };
    for (fans, 1..) |fan, depth| {
        var next: std.ArrayList(u32) = .empty;
        errdefer next.deinit(gpa);
        for (level.items) |parent| {
            var folder: FolderEntries = .{};
            for (0..fan) |i| folder.add(
                true,
                "{s}-{d}",
                .{ words[random.uintLessThan(usize, words.len)], i },
            );
            for (0..files_per_directory) |_| folder.add(false, "{s}_{s}{s}", .{
                words[random.uintLessThan(usize, words.len)],
                words[random.uintLessThan(usize, words.len)],
                extensions[random.uintLessThan(usize, extensions.len)],
            });
            for (folder.sorted()) |entry| {
                const folder_flags = store_mod.flag_dir | store_mod.flag_folder;
                const flags: u8 = if (entry.is_dir) folder_flags else 0;
                const id = try builder.push(gpa, entry.name, parent, flags, @intCast(depth));
                if (entry.is_dir) try next.append(gpa, id);
            }
        }
        level.deinit(gpa);
        level = next;
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
        const Cold = struct {
            gpa: std.mem.Allocator,
            pool: *index.Pool,
            mapped: *const store_mod.Store,
            query: []const u8,
            hits: *std.ArrayList(index.search.Hit),

            fn run(cold_query: *const @This()) !void {
                var engine: index.search.Engine = .empty;
                defer engine.deinit(cold_query.gpa);
                const options: index.search.Options = .{ .limit = 60, .recency = false };
                try engine.search(
                    cold_query.gpa,
                    cold_query.pool,
                    cold_query.mapped,
                    cold_query.query,
                    options,
                    cold_query.hits,
                );
            }
        };
        const cold_query: Cold = .{
            .gpa = gpa,
            .pool = pool,
            .mapped = mapped,
            .query = query,
            .hits = &hits,
        };
        const duration_ns = try medianNs(7, &cold_query, Cold.run);
        var label: [64]u8 = undefined;
        check(
            try std.mem.print(&label, "cold query \"{s}\"", .{query}),
            ms(duration_ns),
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
) std.mem.Allocator.Error!content.ReadOutcome {
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
            .mtime = (1_700_000_000 + @as(i64, @intCast(i))) * std.time.ns_per_s,
            .size = text.items.len,
        });
    }
    std.debug.print("       {d} documents, {d:.1} MB of text\n", .{
        documents.items.len,
        @as(f64, @floatFromInt(text_bytes)) / 1e6,
    });

    var reader_context: u8 = 0;
    var start_ns = sys.monotonicNs();
    const reader: content.TextReader = .{ .read = plainText, .context = &reader_context };
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
            .{ .limit = 50, .text_path = content.plainPath, .text_context = &reader_context },
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

/// A tree to scan, written to disk: 40 folders of 40, 15 files in each of
/// the 1,600 (~26k entries). Many small folders: what a folder costs
/// (open, read, close) is what changes most from one scanner to another.
fn scanning(gpa: std.mem.Allocator, pool: *index.Pool, directory: []const u8) !void {
    std.debug.print("scan\n", .{});
    var root_buffer: index.paths.Buffer = undefined;
    const root = try std.mem.print(&root_buffer, "{s}/tree", .{directory});
    var path_buffer: index.paths.Buffer = undefined;
    for (0..40) |i| for (0..40) |j| {
        const folder = try std.mem.printSentinel(
            &path_buffer,
            "{s}/{s}-{d}/{s}-{d}",
            .{ root, words[i % words.len], i, words[j % words.len], j },
            0,
        );
        try sys.mkdirP(folder);
        for (0..15) |k| {
            var file_buffer: index.paths.Buffer = undefined;
            const file = try std.mem.printSentinel(
                &file_buffer,
                "{s}/{s}_{d}{s}",
                .{ folder, words[k % words.len], k, extensions[k % extensions.len] },
                0,
            );
            try sys.writeFile(file, "");
        }
    };
    const Scan = struct {
        gpa: std.mem.Allocator,
        pool: *index.Pool,
        config: index.scan.Config,
        entries: usize = 0,

        fn run(scan: *@This()) !void {
            var store = try index.scan.scan(scan.gpa, scan.pool, &scan.config, null, null);
            defer store.deinit(scan.gpa);
            scan.entries = store.len();
        }
    };
    var scan: Scan = .{ .gpa = gpa, .pool = pool, .config = .{ .roots = &.{root} } };
    const duration_ns = try medianNs(5, &scan, Scan.run);
    std.debug.print("       {d} entries\n", .{scan.entries});
    check("scan a 26k-entry tree", ms(duration_ns), 12);
}

/// `core.fuzzy` over 50k lines, the scale of a large `dmenu` list: one
/// keystroke's work on the GTK thread.
fn fuzzyScoring(gpa: std.mem.Allocator) !void {
    std.debug.print("fuzzy (launcher, dmenu)\n", .{});
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    const lines = try arena.alloc([]const u8, 50_000);
    for (lines, 0..) |*line, i| {
        var text: std.ArrayList(u8) = .empty;
        // A third look like applications, the rest like paths.
        const application = i % 3 == 0;
        if (!application) try text.appendSlice(arena, "/home/u");
        for (0..@as(usize, if (application) 3 else 5)) |_| {
            try text.appendSlice(arena, if (application) " " else "/");
            try text.appendSlice(arena, words[random.uintLessThan(usize, words.len)]);
        }
        if (!application) try text.appendSlice(arena, "_Text Editor.zig");
        line.* = text.items;
    }
    const Score = struct {
        lines: []const []const u8,
        query: []const u8,
        matched: usize = 0,

        fn run(scoring: *@This()) !void {
            scoring.matched = 0;
            for (scoring.lines) |line| {
                const score = core.fuzzy.scoreFields(scoring.query, &.{line});
                scoring.matched += @intFromBool(score != core.fuzzy.no_match);
            }
        }
    };
    // Substring, scattered word starts, no match, and a long query.
    const queries = [_]struct { []const u8, f64 }{
        .{ "c", 30 },
        .{ "ted", 80 },
        .{ "xyz", 50 },
        .{ "homeuconfigmain", 50 },
    };
    for (queries) |case| {
        const query, const limit_ms = case;
        var scoring: Score = .{ .lines = lines, .query = query };
        const duration_ns = try medianNs(5, &scoring, Score.run);
        var label: [64]u8 = undefined;
        check(
            try std.mem.print(&label, "50k lines \"{s}\" ({d} match)", .{ query, scoring.matched }),
            ms(duration_ns),
            limit_ms,
        );
    }
}

/// Lua's pattern matching as extensions use it, through Lumen's copy with
/// deadline checks (lstrmatch.c).
fn luaPatterns(gpa: std.mem.Allocator) !void {
    std.debug.print("lua (extensions)\n", .{});
    var budget: lua.Budget = .{ .bytes_max = 64 << 20 };
    const L = lua.newState(&budget) orelse return error.OutOfMemory;
    defer lua.c.lua_close(L);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const Run = struct {
        L: *lua.State,
        arena: std.mem.Allocator,
        code: [:0]const u8,

        fn open(state: *lua.State, _: *@This()) void {
            lua.openLibs(state);
        }

        fn call(state: *lua.State, run: *@This()) void {
            if (lua.c.luaL_loadstring(state, run.code.ptr) != lua.c.LUA_OK) {
                _ = lua.c.lua_error(state);
            }
            lua.c.lua_callk(state, 0, 0, 0, null);
        }

        fn timed(run: *@This()) !void {
            if (lua.protect(run.L, run.arena, @This(), run, call)) |message| {
                std.debug.print("lua: {s}\n", .{message});
                return error.LuaFailed;
            }
        }
    };
    var opener: Run = .{ .L = L, .arena = arena_state.allocator(), .code = "" };
    if (lua.protect(L, opener.arena, Run, &opener, Run.open)) |message| {
        std.debug.print("lua: {s}\n", .{message});
        return error.LuaFailed;
    }
    const cases = [_]struct { []const u8, [:0]const u8, f64 }{
        .{
            "find, match",
            \\local s = string.rep('lorem ipsum dolor sit amet, key=value; ', 20)
            \\for i = 1, 20000 do
            \\  local a = s:find('amet', 1, true)
            \\  local k, v = s:match('(%w+)=(%w+)')
            \\end
            ,
            120,
        },
        .{
            "gmatch",
            \\local s = string.rep('alpha beta gamma delta ', 500)
            \\for r = 1, 40 do for w in s:gmatch('%a+') do end end
            ,
            30,
        },
        .{
            "gsub",
            \\local s = string.rep('Hello World foo_bar ', 500)
            \\for r = 1, 60 do local t = s:gsub('%u', string.lower):gsub('_', '-') end
            ,
            60,
        },
    };
    for (cases) |case| {
        const name, const code, const limit_ms = case;
        var run: Run = .{ .L = L, .arena = arena_state.allocator(), .code = code };
        const duration_ns = try medianNs(5, &run, Run.timed);
        var label: [64]u8 = undefined;
        check(try std.mem.print(&label, "patterns: {s}", .{name}), ms(duration_ns), limit_ms);
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
    try scanning(gpa, pool, directory);
    try fuzzyScoring(gpa);
    try luaPatterns(gpa);
    std.debug.print("memory\n", .{});
    checkMB("peak RSS of the whole run", peakRssMB(), 1200);

    if (failures_count > 0) {
        std.debug.print("\n{d} performance check(s) failed\n", .{failures_count});
        std.process.exit(1);
    }
    std.debug.print("\nall performance checks passed\n", .{});
}
