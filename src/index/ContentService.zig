//! Keeps the content index current in the background.
//!
//! Text changes far less often than names, and rebuilding is cheap (~0.9 s
//! for 43k files on half the cores), so this does not watch files: it lists
//! them again (~150 ms with ripgrep) on start, every few minutes and when the
//! window opens, compares (path, mtime, size) with the index, and rebuilds
//! only if something changed. Like the name index, the saved file is mapped
//! at start so search works from the first millisecond.
//!
//! PDFs and Office documents are indexed through their extracted text,
//! cached in `text_dir` as `<hash of path>-<mtime>.txt`: extraction (a child
//! process per file) happens once per version of a document.

const std = @import("std");
const Io = std.Io;
const content = @import("content.zig");
const content_list = @import("content_list.zig");
const extract = @import("extract.zig");
const Pool = @import("Pool.zig");
const sys = @import("sys.zig");

const ContentService = @This();

pub const Options = struct {
    refresh_every_ns: u64 = 5 * 60 * std.time.ns_per_s,
    /// Opening the window asks for a refresh, at most this often.
    poke_min_ns: u64 = 30 * std.time.ns_per_s,
};
/// Extracted text kept per document.
const max_extracted = 4 << 20;

gpa: std.mem.Allocator,
io: Io,
root: []const u8,
cache_path: [:0]u8,
text_dir: []u8,
search_pool: *Pool,
build_pool: *Pool,
opts: Options,
lock: Io.RwLock = .init,
index: ?content.Index = null,
stop: std.atomic.Value(bool) = .init(false),
wake: std.atomic.Value(u32) = .init(0),
last_check_ns: std.atomic.Value(u64) = .init(0),
thread: ?std.Thread = null,
building: std.atomic.Value(bool) = .init(false),
/// For `lumen --stats` (and tests: `checks` counts finished checks).
builds: std.atomic.Value(u32) = .init(0),
checks: std.atomic.Value(u32) = .init(0),
extractions: std.atomic.Value(u32) = .init(0),
last_list_ns: u64 = 0,
last_build_ns: u64 = 0,
last_extract_ns: u64 = 0,

pub fn start(gpa: std.mem.Allocator, io: Io, root: []const u8, cache_dir: []const u8, search_pool: *Pool, build_pool: *Pool) !*ContentService {
    return startWith(gpa, io, root, cache_dir, search_pool, build_pool, .{});
}

pub fn startWith(gpa: std.mem.Allocator, io: Io, root: []const u8, cache_dir: []const u8, search_pool: *Pool, build_pool: *Pool, opts: Options) !*ContentService {
    const s = try gpa.create(ContentService);
    errdefer gpa.destroy(s);
    s.* = .{
        .gpa = gpa,
        .io = io,
        .root = try gpa.dupe(u8, root),
        .cache_path = try std.fmt.allocPrintSentinel(gpa, "{s}/content.idx", .{cache_dir}, 0),
        .text_dir = try std.fmt.allocPrint(gpa, "{s}/text", .{cache_dir}),
        .search_pool = search_pool,
        .build_pool = build_pool,
        .opts = opts,
    };
    sys.mkdirP(s.text_dir);
    // Older versions made these 0755: the cache holds the text of the
    // user's documents, so close it before anything else.
    sys.makePrivate(cache_dir);
    sys.makePrivate(s.text_dir);
    s.index = content.Index.open(s.cache_path) catch null;
    s.thread = try std.Thread.spawn(.{}, run, .{s});
    s.thread.?.setName(io, "lm-content") catch {};
    return s;
}

pub fn shutdown(s: *ContentService) void {
    s.stop.store(true, .release);
    s.poke();
    if (s.thread) |t| t.join();
    if (s.index) |*ix| ix.deinit(s.gpa);
    s.gpa.free(s.root);
    s.gpa.free(s.cache_path);
    s.gpa.free(s.text_dir);
    s.gpa.destroy(s);
}

/// The window opened: check for changes soon (rate-limited).
pub fn poke(s: *ContentService) void {
    _ = s.wake.fetchAdd(1, .release);
    s.io.futexWake(u32, &s.wake.raw, 1);
}

pub const Status = struct {
    docs: usize,
    building: bool,
    ready: bool,
    extracted: usize = 0,
    segments: usize = 0,
    index_bytes: usize = 0,
    builds: u32 = 0,
    checks: u32 = 0,
    /// Documents whose text was extracted (a child process each).
    extractions: u32 = 0,
    last_list_ns: u64 = 0,
    last_build_ns: u64 = 0,
    last_extract_ns: u64 = 0,
};

pub fn status(s: *ContentService) Status {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    var extracted: usize = 0;
    if (s.index) |ix| {
        for (ix.sources) |src| extracted += @intFromBool(src == @intFromEnum(content.Source.extracted));
    }
    return .{
        .docs = if (s.index) |ix| ix.n_docs else 0,
        .building = s.building.load(.acquire),
        .ready = s.index != null,
        .extracted = extracted,
        .segments = if (s.index) |ix| ix.n_segs else 0,
        .index_bytes = if (s.index) |ix| ix.buf.len else 0,
        .builds = s.builds.load(.acquire),
        .checks = s.checks.load(.acquire),
        .extractions = s.extractions.load(.acquire),
        .last_list_ns = s.last_list_ns,
        .last_build_ns = s.last_build_ns,
        .last_extract_ns = s.last_extract_ns,
    };
}

pub const Hit = struct {
    path: []const u8,
    line: u32,
    count: u32,
    snippet: []const u8,
    mtime: i64,
    size: u64,
    extracted: bool,
};

/// Files whose text contains every word of `query` (3+ letters needed).
/// Everything returned lives in `arena`.
pub fn search(s: *ContentService, arena: std.mem.Allocator, query: []const u8, limit: usize, out: *std.ArrayList(Hit)) !void {
    out.clearRetainingCapacity();
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    const ix = if (s.index) |*i| i else return;
    var matches: std.ArrayList(content.Match) = .empty;
    try content.search(ix, s.gpa, arena, s.search_pool, query, limit, pathOf, s, &matches);
    for (matches.items) |m| try out.append(arena, .{
        .path = try arena.dupe(u8, ix.path(m.doc)),
        .line = m.line,
        .count = m.count,
        .snippet = m.snippet,
        .mtime = ix.mtimes[m.doc],
        .size = ix.sizes[m.doc],
        .extracted = ix.sources[m.doc] == @intFromEnum(content.Source.extracted),
    });
}

/// The file holding a document's text, for verification (see PathFn).
fn pathOf(ctx: *anyopaque, d: content.DocIn, buf: []u8) ?[:0]const u8 {
    const s: *ContentService = @ptrCast(@alignCast(ctx));
    if (d.source == .plain) return std.fmt.bufPrintZ(buf, "{s}", .{d.path}) catch null;
    return s.textPath(buf, d);
}

/// A hit's whole text (for the preview), in `arena`.
pub fn readText(s: *ContentService, arena: std.mem.Allocator, path: []const u8, mtime: i64, extracted: bool) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const d: content.DocIn = .{ .path = path, .mtime = mtime, .size = 0, .source = if (extracted) .extracted else .plain };
    if (!textOf(s, d, &buf, arena)) return null;
    return buf.items;
}

/// Text of a document: the file itself, or its cached extraction.
fn textOf(ctx: *anyopaque, d: content.DocIn, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) bool {
    const s: *ContentService = @ptrCast(@alignCast(ctx));
    if (d.source == .plain) return content.readPlain(gpa, d.path, buf);
    var pbuf: [4096]u8 = undefined;
    const p = s.textPath(&pbuf, d) orelse return false;
    buf.clearRetainingCapacity();
    const fd = sys.openRegular(p) catch return false;
    defer sys.close(fd);
    while (buf.items.len < max_extracted) {
        buf.ensureUnusedCapacity(gpa, 64 * 1024) catch return false;
        const spare = buf.unusedCapacitySlice();
        const n = std.os.linux.read(fd, spare.ptr, spare.len);
        if (std.os.linux.errno(n) != .SUCCESS or n == 0) break;
        buf.items.len += n;
    }
    return buf.items.len > 0;
}

fn textPath(s: *ContentService, buf: []u8, d: content.DocIn) ?[:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{x:0>16}-{d}.txt", .{ s.text_dir, std.hash.Wyhash.hash(0, d.path), d.mtime }) catch null;
}

/// Extracts what is missing from the text cache, on the background pool
/// (a PDF takes 10-40 ms, a whole book up to ~0.7 s). Documents that fail to
/// extract get an empty file, so they are not retried every refresh.
fn extractMissing(s: *ContentService, docs: []const content.DocIn) void {
    var missing: std.ArrayList(content.DocIn) = .empty;
    defer missing.deinit(s.gpa);
    var pbuf: [4096]u8 = undefined;
    for (docs) |d| {
        if (d.source != .extracted) continue;
        const tp = s.textPath(&pbuf, d) orelse continue;
        if (!sys.exists(tp)) missing.append(s.gpa, d) catch return;
    }
    if (missing.items.len == 0) return;
    const Ctx = struct {
        s: *ContentService,
        docs: []const content.DocIn,
        fn one(ctx: *@This(), i: usize) void {
            const svc = ctx.s;
            if (svc.stop.load(.acquire)) return;
            const d = ctx.docs[i];
            var tbuf: [4096]u8 = undefined;
            var zbuf: [4096]u8 = undefined;
            const tp = svc.textPath(&tbuf, d) orelse return;
            const kind = extract.kindOf(d.path) orelse return;
            const src = std.fmt.bufPrintZ(&zbuf, "{s}", .{d.path}) catch return;
            const text = extract.extractText(svc.gpa, svc.io, src, kind, max_extracted) catch "";
            defer if (text.len > 0) svc.gpa.free(text);
            sys.writeFile(tp, text) catch {};
            _ = svc.extractions.fetchAdd(1, .release);
        }
    };
    var ctx: Ctx = .{ .s = s, .docs = missing.items };
    s.build_pool.run(missing.items.len, &ctx, Ctx.one);
}

/// True if the index already describes exactly these documents.
fn unchanged(s: *ContentService, docs: []const content.DocIn) bool {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    const ix = s.index orelse return false;
    if (ix.n_docs != docs.len) return false;
    for (docs, 0..) |d, i| {
        if (ix.mtimes[i] != d.mtime or ix.sizes[i] != d.size) return false;
        if (!std.mem.eql(u8, ix.path(@intCast(i)), d.path)) return false;
    }
    return true;
}

fn refresh(s: *ContentService) void {
    s.last_check_ns.store(sys.monotonicNs(), .release);
    // Counted when done, so `checks` going up means its result is visible.
    defer _ = s.checks.fetchAdd(1, .release);
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    var t = sys.monotonicNs();
    const docs = content_list.list(arena_state.allocator(), s.gpa, s.io, s.root, true) catch return;
    s.last_list_ns = sys.monotonicNs() - t;
    if (s.unchanged(docs)) return;

    s.building.store(true, .release);
    defer s.building.store(false, .release);
    defer sys.trimHeap();
    t = sys.monotonicNs();
    s.extractMissing(docs);
    s.last_extract_ns = sys.monotonicNs() - t;
    if (s.stop.load(.acquire)) return;
    t = sys.monotonicNs();
    var fresh = content.build(s.gpa, s.build_pool, docs, textOf, s, null) catch return;
    s.last_build_ns = sys.monotonicNs() - t;
    _ = s.builds.fetchAdd(1, .release);
    // Save, then serve the mapping of what was saved: clean page cache
    // instead of tens of MB of heap.
    if (std.mem.lastIndexOfScalar(u8, s.cache_path, '/')) |slash| sys.mkdirP(s.cache_path[0..slash]);
    if (fresh.save(s.cache_path)) |_| {
        if (content.Index.open(s.cache_path)) |mapped| {
            fresh.deinit(s.gpa);
            fresh = mapped;
        } else |_| {}
    } else |_| {}

    s.lock.lockUncancelable(s.io);
    var old = s.index;
    s.index = fresh;
    s.lock.unlock(s.io);
    if (old) |*o| {
        s.dropStaleText(o, docs);
        o.deinit(s.gpa);
    }
}

/// Deletes the cached text of document versions that are gone (edited or
/// deleted): it is keyed by mtime, so each edit otherwise left the old
/// text in the cache for good. Both lists are sorted by path.
fn dropStaleText(s: *ContentService, old: *const content.Index, docs: []const content.DocIn) void {
    var j: usize = 0;
    var pbuf: [4096]u8 = undefined;
    for (0..old.n_docs) |i| {
        if (old.sources[i] != @intFromEnum(content.Source.extracted)) continue;
        const p = old.path(@intCast(i));
        while (j < docs.len and std.mem.order(u8, docs[j].path, p) == .lt) j += 1;
        if (j < docs.len and std.mem.eql(u8, docs[j].path, p) and docs[j].mtime == old.mtimes[i]) continue;
        const tp = s.textPath(&pbuf, .{ .path = p, .mtime = old.mtimes[i], .size = 0, .source = .extracted }) orelse continue;
        _ = std.os.linux.unlink(tp);
    }
}

fn run(s: *ContentService) void {
    // A saved index is a photo: always check it on start.
    // `seen` is read before refreshing: a poke that lands during a refresh
    // still counts afterwards (it may come after the listing).
    var seen = s.wake.load(.acquire);
    s.refresh();
    while (!s.stop.load(.acquire)) {
        // Sleep until poked or until the next periodic check.
        var ts: std.os.linux.timespec = .{ .sec = 5, .nsec = 0 };
        _ = std.os.linux.futex_4arg(&s.wake.raw, .{ .cmd = .WAIT, .private = true }, seen, &ts);
        if (s.stop.load(.acquire)) return;
        const since = sys.monotonicNs() - s.last_check_ns.load(.acquire);
        const now_wake = s.wake.load(.acquire);
        const poked = now_wake != seen;
        seen = now_wake;
        if (since >= s.opts.refresh_every_ns or (poked and since >= s.opts.poke_min_ns)) s.refresh();
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const linux = std.os.linux;
const TestTree = content_list.TestTree;

fn haveTool(name: []const u8) bool {
    const r = std.process.run(testing.allocator, testing.io, .{ .argv = &.{ name, "--version" } }) catch return false;
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);
    return true;
}

const Fixture = struct {
    root: TestTree,
    cache: TestTree,
    search_pool: *Pool,
    build_pool: *Pool,
    arena_state: std.heap.ArenaAllocator,
    hits: std.ArrayList(Hit) = .empty,

    fn init(f: *Fixture) !void {
        if (!haveTool("rg")) return error.SkipZigTest;
        f.root = try TestTree.init();
        errdefer f.root.deinit();
        f.cache = try TestTree.init();
        errdefer f.cache.deinit();
        f.search_pool = try Pool.create(testing.allocator, testing.io, 1);
        errdefer f.search_pool.destroy();
        f.build_pool = try Pool.create(testing.allocator, testing.io, 1);
        f.arena_state = .init(testing.allocator);
        f.hits = .empty;
    }

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
        f.build_pool.destroy();
        f.search_pool.destroy();
        f.cache.deinit();
        f.root.deinit();
    }

    /// Refreshes only when poked (no rate limit) and once at start.
    fn start(f: *Fixture) !*ContentService {
        return startWith(testing.allocator, testing.io, f.root.abs, f.cache.abs, f.search_pool, f.build_pool, .{
            .refresh_every_ns = std.math.maxInt(u64),
            .poke_min_ns = 0,
        });
    }

    fn find(f: *Fixture, s: *ContentService, query: []const u8) ![]Hit {
        try s.search(f.arena_state.allocator(), query, 10, &f.hits);
        return f.hits.items;
    }
};

fn waitChecks(s: *ContentService, n: u32) !void {
    for (0..2000) |_| {
        if (s.status().checks >= n) return;
        sys.sleepUs(5_000);
    }
    return error.Timeout;
}

/// What the window does on open, then waits for that check to finish.
fn pokeAndWait(s: *ContentService) !void {
    const n = s.status().checks;
    s.poke();
    try waitChecks(s, n + 1);
}

/// Moves a file's mtime away from "now": the index compares whole seconds.
fn setMtime(path: [:0]const u8, sec: i64) !void {
    const ts = [2]linux.timespec{ .{ .sec = sec, .nsec = 0 }, .{ .sec = sec, .nsec = 0 } };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.utimensat(linux.AT.FDCWD, path, &ts, 0)));
}

/// Files in the text cache whose name starts with `prefix`.
fn countText(s: *ContentService, prefix: []const u8) !usize {
    var buf: [4096]u8 = undefined;
    const fd = try sys.openDir(try std.fmt.bufPrintZ(&buf, "{s}", .{s.text_dir}));
    defer sys.close(fd);
    var it: sys.DirIter = .{ .fd = fd };
    var n: usize = 0;
    while (try it.next()) |e| n += @intFromBool(std.mem.startsWith(u8, e.name, prefix));
    return n;
}

test "content service: finds, follows edits and deletions, rebuilds only on change, reuses the saved index" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.root.write("notes/alpha.txt", "the quick zanzibar fox\n");
    try f.root.write("other.md", "unrelated words here\n");

    {
        const s = try f.start();
        defer s.shutdown();
        try waitChecks(s, 1);
        var st = s.status();
        try testing.expect(st.ready);
        try testing.expect(!st.building);
        try testing.expectEqual(@as(usize, 2), st.docs);
        try testing.expectEqual(@as(u32, 1), st.builds);

        var hits = try f.find(s, "zanzibar");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expect(std.mem.endsWith(u8, hits[0].path, "/notes/alpha.txt"));
        try testing.expect(!hits[0].extracted);
        try testing.expectEqual(@as(u32, 1), hits[0].line);
        const text = s.readText(f.arena_state.allocator(), hits[0].path, hits[0].mtime, false).?;
        try testing.expectEqualStrings("the quick zanzibar fox\n", text);

        // Nothing changed: listed again, not rebuilt.
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 2), st.checks);
        try testing.expectEqual(@as(u32, 1), st.builds);

        // Edited: new words found, old ones gone.
        var pbuf: [4096]u8 = undefined;
        const alpha = try f.root.path(&pbuf, "notes/alpha.txt");
        try f.root.write("notes/alpha.txt", "the slow kilimanjaro tortoise\n");
        const edited = sys.nowSeconds() - 100;
        try setMtime(alpha, edited);
        try pokeAndWait(s);
        try testing.expectEqual(@as(u32, 2), s.status().builds);
        hits = try f.find(s, "kilimanjaro");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(edited, hits[0].mtime);
        try testing.expectEqual(@as(usize, 0), (try f.find(s, "zanzibar")).len);

        // Deleted: out of the index.
        _ = linux.unlink(alpha);
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 3), st.builds);
        try testing.expectEqual(@as(usize, 1), st.docs);
        try testing.expectEqual(@as(usize, 0), (try f.find(s, "kilimanjaro")).len);
        try testing.expectEqual(@as(usize, 1), (try f.find(s, "unrelated")).len);
    }

    // Restarted on the same cache: the saved index serves at once, and the
    // start-up check finds nothing to rebuild.
    const s = try f.start();
    defer s.shutdown();
    try testing.expect(s.status().ready);
    try testing.expectEqual(@as(usize, 1), s.status().docs);
    try testing.expectEqual(@as(usize, 1), (try f.find(s, "unrelated")).len);
    try waitChecks(s, 1);
    try testing.expectEqual(@as(u32, 0), s.status().builds);
}

test "content service: Office documents are extracted once per version" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    if (!haveTool("zip") or !haveTool("unzip")) return error.SkipZigTest;
    // Staged outside the root, so document.xml is not indexed as plain text.
    var stage = try TestTree.init();
    defer stage.deinit();
    try stage.write("[Content_Types].xml", "<?xml version=\"1.0\"?><Types/>");

    var pbuf: [4096]u8 = undefined;
    const report = try f.root.path(&pbuf, "docs/report.docx");
    try f.root.mkdir("docs");
    const zipDoc = struct {
        fn run(st: *TestTree, out: [:0]const u8, word: []const u8) !void {
            var xbuf: [512]u8 = undefined;
            try st.write("word/document.xml", try std.fmt.bufPrint(&xbuf,
                \\<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Minutes about the {s} project</w:t></w:r></w:p></w:body></w:document>
            , .{word}));
            _ = linux.unlink(out); // zip would add to an old one
            const r = try std.process.run(testing.allocator, testing.io, .{
                .argv = &.{ "zip", "-q", "-X", "-r", out, "." },
                .cwd = .{ .path = st.abs },
            });
            testing.allocator.free(r.stdout);
            testing.allocator.free(r.stderr);
            try testing.expect(r.term == .exited and r.term.exited == 0);
        }
    }.run;
    try zipDoc(&stage, report, "wombat");
    try setMtime(report, sys.nowSeconds() - 200);
    // Not a zip: extraction fails, leaving an empty text so it is not retried.
    try f.root.write("docs/broken.docx", "garbage, not a zip");

    var hash_buf: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&hash_buf, "{x:0>16}-", .{std.hash.Wyhash.hash(0, report)});

    {
        const s = try f.start();
        defer s.shutdown();
        try waitChecks(s, 1);
        var st = s.status();
        try testing.expectEqual(@as(usize, 2), st.docs);
        try testing.expectEqual(@as(usize, 2), st.extracted);
        try testing.expectEqual(@as(u32, 2), st.extractions);
        try testing.expectEqual(@as(usize, 2), try countText(s, ""));
        try testing.expectEqual(@as(usize, 1), try countText(s, prefix));

        var hits = try f.find(s, "wombat");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqualStrings(report, hits[0].path);
        try testing.expect(hits[0].extracted);
        const text = s.readText(f.arena_state.allocator(), hits[0].path, hits[0].mtime, true).?;
        try testing.expectEqualStrings("Minutes about the wombat project", text);
        // Asked as plain text, the zip is not the text.
        if (s.readText(f.arena_state.allocator(), hits[0].path, hits[0].mtime, false)) |raw| {
            try testing.expect(std.mem.indexOf(u8, raw, "wombat") == null);
        }

        // Unchanged: neither extracted nor rebuilt again (the broken one too).
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 2), st.extractions);
        try testing.expectEqual(@as(u32, 1), st.builds);

        // A new version: extracted once more, the old version's text dropped.
        try zipDoc(&stage, report, "platypus");
        const v2 = sys.nowSeconds() - 100;
        try setMtime(report, v2);
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 3), st.extractions);
        try testing.expectEqual(@as(u32, 2), st.builds);
        try testing.expectEqual(@as(usize, 1), try countText(s, prefix));
        var nbuf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&nbuf, "{s}{d}.txt", .{ prefix, v2 });
        try testing.expectEqual(@as(usize, 1), try countText(s, name));
        try testing.expectEqual(@as(usize, 0), (try f.find(s, "wombat")).len);
        hits = try f.find(s, "platypus");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expect(hits[0].extracted);
    }

    // Restarted: the extracted text is reused, nothing is extracted again.
    const s = try f.start();
    defer s.shutdown();
    try testing.expectEqual(@as(usize, 1), (try f.find(s, "platypus")).len);
    try waitChecks(s, 1);
    try testing.expectEqual(@as(u32, 0), s.status().extractions);
    try testing.expectEqual(@as(u32, 0), s.status().builds);

    // Deleted: its text goes with it.
    _ = linux.unlink(report);
    try pokeAndWait(s);
    try testing.expectEqual(@as(usize, 0), try countText(s, prefix));
    try testing.expectEqual(@as(usize, 1), s.status().docs);
}
