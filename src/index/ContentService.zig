//! Keeps the content index current in the background.
//!
//! Text changes far less often than names, so this does not watch files: it
//! lists them again (~150 ms with ripgrep) on start, every few minutes and
//! when the window opens, and compares (path, mtime, size) with the index.
//! What changed is read again and added to the index (`content.update`);
//! the rest is not touched. Once removed versions or segments pile up, it
//! is rebuilt whole (~1.1 s and ~270 MB for 49 k files). Like the name
//! index, the saved file is mapped at start so search works from the first
//! millisecond.
//!
//! PDFs and Office documents are indexed through their extracted text,
//! cached in `text_dir` as `<hash of path>-<mtime>-<size>.txt`: extraction
//! (a child process per file) happens once per version of a document.

const std = @import("std");
const Io = std.Io;
const content = @import("content.zig");
const content_list = @import("content_list.zig");
const extract = @import("extract.zig");
const Pool = @import("Pool.zig");
const Service = @import("Service.zig");
const sys = @import("os");

const log = std.log.scoped(.content);

const ContentService = @This();

pub const Options = struct {
    refresh_every_ns: u64 = 5 * 60 * std.time.ns_per_s,
    /// Opening the window asks for a refresh, at most this often.
    poke_min_ns: u64 = 30 * std.time.ns_per_s,
    /// Rebuilt whole instead of updated past this share of removed
    /// documents (in percent), or this many segments.
    max_removed_percent: u8 = 20,
    max_segments: usize = 32,
    /// The name index over the same root: while it saw no name change that
    /// could matter, a check only looks at the files already indexed
    /// (edits in place) instead of listing them all with ripgrep (~0.45 s
    /// of CPU for 49 k). Null: always list.
    names: ?*Service = null,
    /// Listed at least this often anyway (a .gitignore edited in place
    /// changes what is listed without a name change).
    list_every_ns: u64 = 30 * 60 * std.time.ns_per_s,
};
const max_extracted = content.max_extracted;

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
/// For `lumen --stats` (and tests: `checks` counts finished checks). Read
/// from other threads.
builds: std.atomic.Value(u32) = .init(0),
/// Of those, the ones that only added what changed.
updates: std.atomic.Value(u32) = .init(0),
/// Checks that listed every file (the others only looked at indexed ones).
listings: std.atomic.Value(u32) = .init(0),
/// `names.nameChanges()` when files were last listed. Service thread only.
listed_names: ?u64 = null,
last_listing_at: u64 = 0,
checks: std.atomic.Value(u32) = .init(0),
extractions: std.atomic.Value(u32) = .init(0),
last_list_ns: std.atomic.Value(u64) = .init(0),
/// The last check that looked at indexed files only.
last_stat_ns: std.atomic.Value(u64) = .init(0),
last_build_ns: std.atomic.Value(u64) = .init(0),
last_extract_ns: std.atomic.Value(u64) = .init(0),
/// The index in use could not be saved: retried on the next check even if
/// nothing changed. Service thread only.
unsaved: bool = false,
/// Documents whose extraction failed in passing (a timeout, a missing tool,
/// memory): kept out of the index, which would remember them as textless
/// for as long as they do not change, and tried again by the next check.
/// In `retry_arena`. Service thread only.
retry: []const content.DocIn = &.{},
retry_arena: std.heap.ArenaAllocator,

/// The thread pools it borrows: they must outlive the service.
pub const Pools = struct { search: *Pool, build: *Pool };

pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError;

pub fn start(
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    cache_dir: []const u8,
    pools: Pools,
) StartError!*ContentService {
    return startWith(gpa, io, root, cache_dir, pools, .{});
}

/// Starts the background thread. Borrows the pools, which must outlive it.
/// Thread-safe once started.
pub fn startWith(
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    cache_dir: []const u8,
    pools: Pools,
    opts: Options,
) StartError!*ContentService {
    const s = try gpa.create(ContentService);
    errdefer gpa.destroy(s);
    const root_copy = try gpa.dupe(u8, root);
    errdefer gpa.free(root_copy);
    const cache_path = try gpa.printSentinel("{s}/content.idx", .{cache_dir}, 0);
    errdefer gpa.free(cache_path);
    const text_dir = try gpa.print("{s}/text", .{cache_dir});
    errdefer gpa.free(text_dir);
    s.* = .{
        .gpa = gpa,
        .io = io,
        .root = root_copy,
        .cache_path = cache_path,
        .text_dir = text_dir,
        .search_pool = pools.search,
        .build_pool = pools.build,
        .opts = opts,
        .retry_arena = .init(gpa),
    };
    sys.mkdirP(s.text_dir);
    // Older versions made these 0755: the cache holds the text of the
    // user's documents, so close it before anything else.
    sys.makePrivate(cache_dir);
    sys.makePrivate(s.text_dir);
    // Absent or unreadable: built from scratch by the first refresh.
    s.index = content.Index.open(s.cache_path) catch null;
    errdefer if (s.index) |*ix| ix.deinit(gpa);
    s.thread = try std.Thread.spawn(.{}, run, .{s});
    s.thread.?.setName(io, "lm-content") catch {};
    return s;
}

pub fn shutdown(s: *ContentService) void {
    s.stop.store(true, .release);
    s.poke();
    if (s.thread) |t| t.join();
    if (s.index) |*ix| ix.deinit(s.gpa);
    s.retry_arena.deinit();
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
    updates: u32 = 0,
    listings: u32 = 0,
    checks: u32 = 0,
    /// Documents whose text was extracted (a child process each).
    extractions: u32 = 0,
    last_list_ns: u64 = 0,
    last_stat_ns: u64 = 0,
    last_build_ns: u64 = 0,
    last_extract_ns: u64 = 0,
};

pub fn status(s: *ContentService) Status {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    var extracted: usize = 0;
    if (s.index) |ix| {
        for (ix.sources, 0..) |src, i| extracted += @intFromBool(
            src == @backingInt(content.Source.extracted) and !ix.removed(@intCast(i)),
        );
    }
    return .{
        .docs = if (s.index) |ix| ix.live() else 0,
        .building = s.building.load(.acquire),
        .ready = s.index != null,
        .extracted = extracted,
        .segments = if (s.index) |ix| ix.n_segs else 0,
        .index_bytes = if (s.index) |ix| ix.buf.len else 0,
        .builds = s.builds.load(.acquire),
        .updates = s.updates.load(.acquire),
        .listings = s.listings.load(.acquire),
        .checks = s.checks.load(.acquire),
        .extractions = s.extractions.load(.acquire),
        .last_list_ns = s.last_list_ns.load(.monotonic),
        .last_stat_ns = s.last_stat_ns.load(.monotonic),
        .last_build_ns = s.last_build_ns.load(.monotonic),
        .last_extract_ns = s.last_extract_ns.load(.monotonic),
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
pub fn search(
    s: *ContentService,
    arena: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    return s.searchUntil(arena, query, limit, null, out);
}

/// `search`, cut short once `stop` is set (a newer query waits): reading
/// files to verify them stops at the next one, and the hits found so far
/// are returned. Until then it holds the search pool and the index.
pub fn searchUntil(
    s: *ContentService,
    arena: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    stop: ?*const std.atomic.Value(bool),
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    const ix = if (s.index) |*i| i else return;
    var matches: std.ArrayList(content.Match) = .empty;
    try content.search(
        ix,
        s.gpa,
        arena,
        s.search_pool,
        query,
        .{ .limit = limit, .text_path = pathOf, .text_ctx = s, .stop = stop },
        &matches,
    );
    for (matches.items) |m| try out.append(arena, .{
        .path = try arena.dupe(u8, ix.path(m.doc)),
        .line = m.line,
        .count = m.count,
        .snippet = m.snippet,
        .mtime = ix.mtimes[m.doc],
        .size = ix.sizes[m.doc],
        .extracted = ix.sources[m.doc] == @backingInt(content.Source.extracted),
    });
}

/// The file holding a document's text, for verification (see PathFn).
fn pathOf(ctx: *anyopaque, d: content.DocIn, buf: []u8) ?[:0]const u8 {
    const s: *ContentService = @ptrCast(@alignCast(ctx));
    if (d.source == .plain) return std.mem.printSentinel(buf, "{s}", .{d.path}, 0) catch null;
    return s.textPath(buf, d);
}

/// The first `lines` lines of a hit's text (for the preview), in `arena`;
/// null if it cannot be read. Reads no further than that: the preview runs
/// on the UI thread, and a match near the top of a 4 MB extraction needs a
/// few KB of it. `mtime` is the document's as it is now; so is its size,
/// which keys the text cache too.
pub fn readText(
    s: *ContentService,
    arena: std.mem.Allocator,
    path: []const u8,
    mtime: i64,
    extracted: bool,
    lines: u32,
) ?[]const u8 {
    var pbuf: [4096]u8 = undefined;
    const doc = std.mem.printSentinel(&pbuf, "{s}", .{path}, 0) catch return null;
    var tbuf: [4096]u8 = undefined;
    const p: [:0]const u8 = if (extracted) blk: {
        const st = content_list.stat(doc, true) orelse return null;
        break :blk s.textPath(&tbuf, .{
            .path = path,
            .mtime = mtime,
            .size = st.size,
            .source = .extracted,
        }) orelse return null;
    } else doc;
    const fd = sys.openRegular(p) catch return null;
    defer sys.close(fd);
    const cap: usize = if (extracted) max_extracted else content.max_text;
    var buf: std.ArrayList(u8) = .empty;
    var seen: u32 = 0;
    while (buf.items.len < cap and seen < lines) {
        buf.ensureUnusedCapacity(arena, 16 * 1024) catch return null;
        const spare = buf.unusedCapacitySlice();
        const n = std.os.linux.read(fd, spare.ptr, @min(spare.len, cap - buf.items.len));
        if (std.os.linux.errno(n) != .SUCCESS or n == 0) break;
        seen += @intCast(std.mem.count(u8, spare[0..n], "\n"));
        buf.items.len += n;
    }
    return buf.items;
}

/// Text of a document: the file itself, or its cached extraction.
fn textOf(
    ctx: *anyopaque,
    d: content.DocIn,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    const s: *ContentService = @ptrCast(@alignCast(ctx));
    if (d.source == .plain) return content.readPlain(gpa, d.path, buf);
    var pbuf: [4096]u8 = undefined;
    const p = s.textPath(&pbuf, d) orelse return false;
    buf.clearRetainingCapacity();
    const fd = sys.openRegular(p) catch return false;
    defer sys.close(fd);
    try sys.readUpTo(gpa, fd, buf, max_extracted);
    return buf.items.len > 0;
}

/// How long the cached text of an extracted document is (0: none yet), so
/// that building reads no more of them at once than memory allows.
fn textLen(ctx: *anyopaque, d: content.DocIn) u64 {
    const s: *ContentService = @ptrCast(@alignCast(ctx));
    var pbuf: [4096]u8 = undefined;
    const p = s.textPath(&pbuf, d) orelse return 0;
    return if (sys.info(p)) |i| i.size else 0;
}

/// Where a document version's extracted text is cached. Keyed by size as
/// well as mtime (whole seconds): an edit within the same second reused
/// the old text, and dropping the old version's text then deleted it.
fn textPath(s: *ContentService, buf: []u8, d: content.DocIn) ?[:0]const u8 {
    var nbuf: [64]u8 = undefined;
    return std.mem.printSentinel(buf, "{s}/{s}", .{ s.text_dir, textName(&nbuf, d) }, 0) catch null;
}

fn textName(buf: *[64]u8, d: content.DocIn) []const u8 {
    // 16 + 1 + 20 + 1 + 20 + 4 bytes at most: always fits.
    return std.mem.print(
        buf,
        "{x:0>16}-{d}-{d}.txt",
        .{ std.hash.Wyhash.hash(0, d.path), d.mtime, d.size },
    ) catch unreachable;
}

/// Extracts what is missing from the text cache, on the background pool
/// (a PDF takes 10-40 ms, a whole book up to ~0.7 s). Documents that cannot
/// be extracted (a corrupt file, a tool error) get an empty file, so they
/// are not retried every refresh. Passing failures (out of memory, a
/// timeout, a missing tool) leave nothing: those documents are taken out
/// of `docs` (what is left is returned) and into `retry`, so that the index
/// does not remember them as textless and the next check tries again.
/// Null when out of memory: nothing is to be indexed then.
fn extractMissing(
    s: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
) ?[]content.DocIn {
    var missing: std.ArrayList(usize) = .empty;
    var pbuf: [4096]u8 = undefined;
    for (docs, 0..) |d, i| {
        if (d.source != .extracted) continue;
        const tp = s.textPath(&pbuf, d) orelse continue;
        if (!sys.exists(tp)) missing.append(arena, i) catch return null;
    }
    // Nothing to extract: nothing to retry either.
    if (missing.items.len == 0) return s.leaveOut(arena, docs, &.{}, &.{});
    const failed = arena.alloc(?anyerror, missing.items.len) catch return null;
    @memset(failed, null);
    const Ctx = struct {
        s: *ContentService,
        docs: []const content.DocIn,
        missing: []const usize,
        failed: []?anyerror,
        fn one(ctx: *@This(), i: usize) void {
            const svc = ctx.s;
            if (svc.stop.load(.acquire)) return;
            const d = ctx.docs[ctx.missing[i]];
            var tbuf: [4096]u8 = undefined;
            var zbuf: [4096]u8 = undefined;
            const tp = svc.textPath(&tbuf, d) orelse return;
            const kind = extract.kindOf(d.path) orelse return;
            const src = std.mem.printSentinel(&zbuf, "{s}", .{d.path}, 0) catch return;
            const text = extract.extractText(
                svc.gpa,
                svc.io,
                src,
                kind,
                max_extracted,
                &svc.stop,
            ) catch |err| switch (err) {
                error.ToolFailed, error.NotRegular, error.Access, error.NotFound => "",
                else => {
                    ctx.failed[i] = err;
                    return;
                },
            };
            defer if (text.len > 0) svc.gpa.free(text);
            sys.writeFileAtomic(tp, text) catch |err| log.warn(
                "caching text of {s}: {t}",
                .{ d.path, err },
            );
            _ = svc.extractions.fetchAdd(1, .release);
        }
    };
    var ctx: Ctx = .{ .s = s, .docs = docs, .missing = missing.items, .failed = failed };
    s.build_pool.run(missing.items.len, &ctx, Ctx.one);
    return s.leaveOut(arena, docs, missing.items, failed);
}

/// `docs` without those whose extraction `failed` (`missing` says which),
/// which become the documents to retry. Logged when that list changes, not
/// on every check while a tool stays missing.
fn leaveOut(
    s: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
    missing: []const usize,
    failed: []const ?anyerror,
) ?[]content.DocIn {
    var n_failed: usize = 0;
    var first: ?usize = null;
    for (failed, 0..) |f, i| if (f != null) {
        n_failed += 1;
        if (first == null) first = i;
    };
    const was = s.retry.len;
    _ = s.retry_arena.reset(.retain_capacity);
    s.retry = &.{};
    if (n_failed == 0) return docs;
    const fi = first.?;
    if (n_failed != was) log.warn(
        "extracting {d} documents failed for now ({s}: {t}), will retry",
        .{ n_failed, docs[missing[fi]].path, failed[fi].? },
    );
    const ra = s.retry_arena.allocator();
    const retry = ra.alloc(content.DocIn, n_failed) catch return null;
    const drop = arena.alloc(bool, docs.len) catch return null;
    @memset(drop, false);
    var r: usize = 0;
    for (failed, missing) |f, at| if (f != null) {
        drop[at] = true;
        retry[r] = docs[at];
        retry[r].path = ra.dupe(u8, docs[at].path) catch return null;
        r += 1;
    };
    s.retry = retry;
    var w: usize = 0;
    for (docs, drop) |d, dropped| if (!dropped) {
        docs[w] = d;
        w += 1;
    };
    return docs[0..w];
}

/// How the listed documents differ from the index: ids whose document
/// changed or is gone, and the documents to index (changed or new).
const Diff = struct { gone: []u32, added: []content.DocIn };

/// Called on the service thread, the only one that replaces the index, so
/// it can read it without the lock.
fn diff(
    s: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
) std.mem.Allocator.Error!Diff {
    const ix = if (s.index) |*i| i else return .{ .gone = &.{}, .added = docs };
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    try ids.ensureTotalCapacity(arena, @intCast(ix.live()));
    for (0..ix.n_docs) |i| if (!ix.removed(@intCast(i))) ids.putAssumeCapacity(
        ix.path(@intCast(i)),
        @intCast(i),
    );
    const seen = try arena.alloc(bool, ix.n_docs);
    @memset(seen, false);
    var gone: std.ArrayList(u32) = .empty;
    var added: std.ArrayList(content.DocIn) = .empty;
    for (docs) |d| {
        if (ids.get(d.path)) |id| {
            seen[id] = true;
            if (ix.mtimes[id] == d.mtime and ix.sizes[id] == d.size and
                ix.sources[id] == @backingInt(
                    d.source,
                )) continue;
            try gone.append(arena, id);
        }
        try added.append(arena, d);
    }
    for (0..ix.n_docs) |i| if (!ix.removed(@intCast(i)) and !seen[i]) try gone.append(
        arena,
        @intCast(i),
    );
    return .{ .gone = gone.items, .added = added.items };
}

/// Every file to index, listed by ripgrep; `names` is what the name index
/// said before listing, so a change during the listing lists again next time.
fn listAll(s: *ContentService, arena: std.mem.Allocator, names: ?u64) ?[]content.DocIn {
    const t = sys.monotonicNs();
    const docs = content_list.listUntil(arena, s.gpa, s.io, s.root, true, &s.stop) catch |err| {
        if (err != error.Canceled) log.warn("listing files: {t}", .{err});
        return null;
    };
    s.last_list_ns.store(sys.monotonicNs() - t, .monotonic);
    _ = s.listings.fetchAdd(1, .release);
    s.listed_names = names;
    s.last_listing_at = t;
    return docs;
}

/// Changes to the files already indexed, without listing: edits in place
/// (mtime, size), and files gone or out of bounds; and the documents to
/// retry. New files need a name change, which makes the next check list.
/// Paths point into the index, which outlives the refresh, or `arena`.
fn indexedChanges(s: *ContentService, arena: std.mem.Allocator) std.mem.Allocator.Error!Diff {
    const ix = &s.index.?;
    var gone: std.ArrayList(u32) = .empty;
    var added: std.ArrayList(content.DocIn) = .empty;
    var zbuf: [4096]u8 = undefined;
    for (0..ix.n_docs) |i| {
        const id: u32 = @intCast(i);
        if (ix.removed(id)) continue;
        const d = ix.docIn(id);
        const z = std.mem.printSentinel(&zbuf, "{s}", .{d.path}, 0) catch continue;
        const now = content_list.stat(z, d.source == .extracted);
        if (now) |st| if (st.mtime == d.mtime and st.size == d.size) continue;
        try gone.append(arena, id);
        if (now) |st| try added.append(arena, .{
            .path = d.path,
            .mtime = st.mtime,
            .size = st.size,
            .source = d.source,
        });
    }
    // Not in the index (`extractMissing` left them out): as they are now.
    for (s.retry) |d| {
        const z = std.mem.printSentinel(&zbuf, "{s}", .{d.path}, 0) catch continue;
        const st = content_list.stat(z, true) orelse continue;
        try added.append(arena, .{
            .path = try arena.dupe(u8, d.path),
            .mtime = st.mtime,
            .size = st.size,
            .source = .extracted,
        });
    }
    return .{ .gone = gone.items, .added = added.items };
}

fn refresh(s: *ContentService) void {
    s.last_check_ns.store(sys.monotonicNs(), .release);
    // Counted when done, so `checks` going up means its result is visible.
    defer _ = s.checks.fetchAdd(1, .release);
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = if (s.opts.names) |n| n.nameChanges() else null;
    var docs: ?[]content.DocIn = null;
    var d = s.changes(arena, names, &docs) orelse return;
    if (s.stop.load(.acquire)) return;
    if (s.index != null and d.gone.len == 0 and d.added.len == 0) {
        if (s.unsaved) s.retrySave();
        return;
    }

    s.building.store(true, .release);
    defer s.building.store(false, .release);
    defer @import("root.zig").trimHeap();
    const whole = s.wantsWhole(d);
    // A whole build indexes every file: they must be listed.
    if (whole and docs == null) {
        docs = s.listAll(arena, names) orelse return;
        d = s.diff(arena, docs.?) catch return;
    }
    var t = sys.monotonicNs();
    if (whole) {
        docs = s.extractMissing(arena, docs.?) orelse return;
    } else {
        d.added = s.extractMissing(arena, d.added) orelse return;
    }
    s.last_extract_ns.store(sys.monotonicNs() - t, .monotonic);
    if (s.stop.load(.acquire)) return;
    // Only documents to retry, which failed again.
    if (!whole and d.gone.len == 0 and d.added.len == 0) return;
    t = sys.monotonicNs();
    const fresh = s.buildNext(if (whole) docs.? else null, d) orelse return;
    s.last_build_ns.store(sys.monotonicNs() - t, .monotonic);
    _ = s.builds.fetchAdd(1, .release);
    if (!whole) _ = s.updates.fetchAdd(1, .release);

    var old = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const o = s.index;
        s.index = fresh;
        break :blk o;
    };
    if (old) |*o| {
        s.dropStaleText(o, d.gone);
        o.deinit(s.gpa);
    }
    if (whole) s.sweepText();
}

/// What changed since the index was built: every file listed again (no
/// index yet, names created or removed, or the listing is old), or only
/// the indexed ones checked. A listing is left in `docs`.
fn changes(
    s: *ContentService,
    arena: std.mem.Allocator,
    names: ?u64,
    docs: *?[]content.DocIn,
) ?Diff {
    const t = sys.monotonicNs();
    const must_list = s.index == null or names == null or s.listed_names == null or
        names.? != s.listed_names.? or t - s.last_listing_at >= s.opts.list_every_ns;
    if (must_list) {
        docs.* = s.listAll(arena, names) orelse return null;
        return s.diff(arena, docs.*.?) catch null;
    }
    const r = s.indexedChanges(arena) catch return null;
    s.last_stat_ns.store(sys.monotonicNs() - t, .monotonic);
    return r;
}

/// Whole when there is nothing to update, or when what updates leave
/// behind (removed versions, small segments) has piled up.
fn wantsWhole(s: *const ContentService, d: Diff) bool {
    const ix = &(s.index orelse return true);
    const removed = ix.n_removed + d.gone.len;
    const total = ix.n_docs + d.added.len;
    return removed * 100 > total * s.opts.max_removed_percent or
        ix.n_segs >= s.opts.max_segments or
        // What updates left behind in the file: over 30 %.
        ix.buf.len * 10 > ix.live_bytes * 13;
}

/// The next index: `all` of the documents built whole, or the current one
/// updated with `d`. Written to the cache file as it grows and served
/// mapped (clean page cache, never the whole index in heap); an update is
/// appended to the file the index is mapped from, or the file rewritten if
/// it is not that one any more. Null (logged) when out of memory.
fn buildNext(s: *ContentService, all: ?[]const content.DocIn, d: Diff) ?content.Index {
    const reader: content.TextReader = .{ .read = textOf, .ctx = s, .extracted_len = textLen };
    if (std.mem.findScalarLast(u8, s.cache_path, '/')) |slash| sys.mkdirP(s.cache_path[0..slash]);
    const appended: ?content.FileError!content.Index = if (all == null and s.index.?.mapped and
        !s.unsaved)
        if (content.appendFile(
            s.gpa,
            s.build_pool,
            &s.index.?,
            d.gone,
            d.added,
            reader,
            s.cache_path,
            null,
        )) |r| (if (r) |ix| ix else null) else |err| err
    else
        null;
    const written = appended orelse if (all) |docs|
        content.buildFile(s.gpa, s.build_pool, docs, reader, s.cache_path, null)
    else
        content.updateFile(
            s.gpa,
            s.build_pool,
            &s.index.?,
            d.gone,
            d.added,
            reader,
            s.cache_path,
            null,
        );
    const fresh = written catch |file_err| blk: {
        if (file_err == error.OutOfMemory) {
            log.warn("building the content index: out of memory", .{});
            return null;
        }
        // Not written (a full disk, a read-only cache): built in memory and
        // served from there; saving is retried on the next check.
        log.warn("writing the content index: {t}", .{file_err});
        s.unsaved = true;
        break :blk (if (all) |docs|
            content.build(s.gpa, s.build_pool, docs, reader, null)
        else
            content.update(
                s.gpa,
                s.build_pool,
                &s.index.?,
                d.gone,
                d.added,
                reader,
                null,
            )) catch |err| {
            log.warn("building the content index: {t}", .{err});
            return null;
        };
    };
    if (fresh.mapped) s.unsaved = false;
    return fresh;
}

fn retrySave(s: *ContentService) void {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    const ix = s.index orelse return;
    ix.save(s.cache_path) catch |err| {
        log.warn("saving the content index: {t}", .{err});
        return;
    };
    s.unsaved = false;
}

/// Deletes the cached text of document versions that are gone (edited or
/// deleted): it is keyed by mtime, so each edit otherwise left the old
/// text in the cache for good.
fn dropStaleText(s: *ContentService, old: *const content.Index, gone: []const u32) void {
    var pbuf: [4096]u8 = undefined;
    for (gone) |id| {
        if (old.sources[id] != @backingInt(content.Source.extracted)) continue;
        const tp = s.textPath(&pbuf, old.docIn(id)) orelse continue;
        _ = std.os.linux.unlink(tp);
    }
}

/// Deletes the cached texts no live document of the index refers to: what
/// `dropStaleText` cannot know of, versions extracted and never indexed
/// (out of memory, a shutdown or a crash in between), half-written ones.
/// A text cached under the name used before sizes were part of it
/// (`<hash>-<mtime>.txt`) is renamed instead, not extracted again. On
/// start and after a whole build, on the service thread: the one that
/// writes them.
fn sweepText(s: *ContentService) void {
    const ix = &(s.index orelse return);
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A name in the cache -> the name it should have.
    var keep: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (0..ix.n_docs) |i| {
        const id: u32 = @intCast(i);
        if (ix.removed(id) or ix.sources[id] != @backingInt(content.Source.extracted)) continue;
        const d = ix.docIn(id);
        var nbuf: [64]u8 = undefined;
        const name = arena.dupe(u8, textName(&nbuf, d)) catch return;
        keep.put(arena, name, name) catch return;
        const old = arena.print("{x:0>16}-{d}.txt", .{
            std.hash.Wyhash.hash(0, d.path),
            d.mtime,
        }) catch return;
        keep.put(arena, old, name) catch return;
    }
    var dbuf: [4096]u8 = undefined;
    const dir = std.mem.printSentinel(&dbuf, "{s}", .{s.text_dir}, 0) catch return;
    const fd = sys.openDir(dir) catch return;
    defer sys.close(fd);
    var it: sys.DirIter = .{ .fd = fd };
    while (it.next() catch return) |e| {
        if (e.kind == std.os.linux.DT.DIR) continue;
        var nbuf: [256]u8 = undefined;
        const name = std.mem.printSentinel(&nbuf, "{s}", .{e.name}, 0) catch continue;
        const want = keep.get(e.name) orelse {
            _ = std.os.linux.unlinkat(fd, name, 0);
            continue;
        };
        if (std.mem.eql(u8, want, e.name)) continue;
        var wbuf: [64]u8 = undefined;
        const to = std.mem.printSentinel(&wbuf, "{s}", .{want}, 0) catch continue;
        _ = std.os.linux.renameat(fd, name, fd, to);
    }
}

fn run(s: *ContentService) void {
    // A saved index is a photo: always check it on start.
    // `seen` is read before refreshing: a poke that lands during a refresh
    // still counts afterwards (it may come after the listing).
    var seen = s.wake.load(.acquire);
    // Before the check, which would extract again what is cached under the
    // older naming.
    s.sweepText();
    s.refresh();
    while (!s.stop.load(.acquire)) {
        // Sleep until poked or until the next periodic check.
        // Canceled never happens: this thread is joined, not canceled.
        // Until the next periodic check (pokes and `stop` wake it sooner):
        // it used to wake every 5 s to see whether 5 minutes had passed.
        const due = s.opts.refresh_every_ns -| (sys.monotonicNs() - s.last_check_ns.load(.acquire));
        s.io.futexWaitTimeout(u32, &s.wake.raw, seen, .{ .duration = .{
            .raw = .fromNanoseconds(@max(due, std.time.ns_per_s)),
            .clock = .awake,
        } }) catch {};
        if (s.stop.load(.acquire)) return;
        const since = sys.monotonicNs() - s.last_check_ns.load(.acquire);
        const now_wake = s.wake.load(.acquire);
        const poked = now_wake != seen;
        seen = now_wake;
        if (since >= s.opts.refresh_every_ns or
            (poked and since >= s.opts.poke_min_ns)) s.refresh();
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const linux = std.os.linux;
const TestTree = sys.TestDir;

fn haveTool(name: []const u8) bool {
    const r = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ name, "--version" },
    }) catch return false;
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
        // Small trees: one edit is a large share, so updates are allowed
        // whatever the share (the compaction test sets its own).
        return f.startWith(.{
            .refresh_every_ns = std.math.maxInt(u64),
            .poke_min_ns = 0,
            .max_removed_percent = 100,
        });
    }

    fn startWith(f: *Fixture, opts: Options) !*ContentService {
        return ContentService.startWith(
            testing.allocator,
            testing.io,
            f.root.abs,
            f.cache.abs,
            .{ .search = f.search_pool, .build = f.build_pool },
            opts,
        );
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
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(
        linux.utimensat(linux.AT.FDCWD, path, &ts, 0),
    ));
}

/// Files in the text cache whose name starts with `prefix`.
fn countText(s: *ContentService, prefix: []const u8) !usize {
    var buf: [4096]u8 = undefined;
    const fd = try sys.openDir(try std.mem.printSentinel(&buf, "{s}", .{s.text_dir}, 0));
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
        const text = s.readText(
            f.arena_state.allocator(),
            hits[0].path,
            hits[0].mtime,
            false,
            std.math.maxInt(u32),
        ).?;
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
        try testing.expectEqual(@as(u32, 1), s.status().updates);
        hits = try f.find(s, "kilimanjaro");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(edited, hits[0].mtime);
        try testing.expectEqual(@as(usize, 0), (try f.find(s, "zanzibar")).len);

        // Deleted: out of the index.
        _ = linux.unlink(alpha);
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 3), st.builds);
        try testing.expectEqual(@as(u32, 2), st.updates);
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

test "content service: a cache it cannot write still serves from memory, and saves later" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.root.write("a.txt", "an unwritable cache lemur\n");
    // A directory where the index's temporary file goes: writing it fails.
    var bbuf: [4096]u8 = undefined;
    const blocker = try std.mem.printSentinel(&bbuf, "{s}/content.idx.tmp", .{f.cache.abs}, 0);
    try testing.expect(linux.errno(linux.mkdir(blocker, 0o700)) == .SUCCESS);
    const s = try f.start();
    defer s.shutdown();
    try waitChecks(s, 1);
    try testing.expectEqual(@as(usize, 1), (try f.find(s, "lemur")).len);
    var ibuf: [4096]u8 = undefined;
    const saved = try std.mem.printSentinel(&ibuf, "{s}/content.idx", .{f.cache.abs}, 0);
    try testing.expect(!sys.exists(saved));
    // Writable again: the next check saves it, though nothing changed.
    _ = linux.rmdir(blocker);
    try pokeAndWait(s);
    try testing.expect(sys.exists(saved));
    try testing.expectEqual(@as(u32, 1), s.status().builds);
}

test "content service: with the name index, checks without name changes only look at indexed files" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.root.write("a.txt", "first apricot\n");
    var ibuf: [4096]u8 = undefined;
    const idx = try std.mem.printSentinel(&ibuf, "{s}/files.idx", .{f.cache.abs}, 0);
    const names = try Service.start(testing.allocator, testing.io, f.root.abs, idx);
    defer names.shutdown();
    _ = try Service.waitNames(names, null);
    const s = try f.startWith(.{
        .refresh_every_ns = std.math.maxInt(u64),
        .poke_min_ns = 0,
        .max_removed_percent = 100,
        .names = names,
    });
    defer s.shutdown();
    try waitChecks(s, 1);
    try testing.expectEqual(@as(u32, 1), s.status().listings);

    // Edited in place (no name change): seen without listing.
    var pbuf: [4096]u8 = undefined;
    try f.root.write("a.txt", "second banana\n");
    try setMtime(try f.root.path(&pbuf, "a.txt"), sys.nowSeconds() - 100);
    try pokeAndWait(s);
    var st = s.status();
    try testing.expectEqual(@as(u32, 1), st.listings);
    try testing.expectEqual(@as(u32, 1), st.updates);
    try testing.expectEqual(@as(usize, 1), (try f.find(s, "banana")).len);
    try testing.expectEqual(@as(usize, 0), (try f.find(s, "apricot")).len);

    // A new file is a name change: the next check lists.
    const before = names.nameChanges().?;
    try f.root.write("b.txt", "third cherry\n");
    _ = try Service.waitNames(names, before);
    try pokeAndWait(s);
    st = s.status();
    try testing.expectEqual(@as(u32, 2), st.listings);
    try testing.expectEqual(@as(usize, 2), st.docs);
    try testing.expectEqual(@as(usize, 1), (try f.find(s, "cherry")).len);
}

test "content service: rebuilt whole once removed versions pile up" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for (0..10) |i| {
        var nbuf: [32]u8 = undefined;
        try f.root.write(try std.mem.print(&nbuf, "n{d}.txt", .{i}), "plain words\n");
    }
    const s = try f.startWith(.{
        .refresh_every_ns = std.math.maxInt(u64),
        .poke_min_ns = 0,
        .max_removed_percent = 20,
    });
    defer s.shutdown();
    try waitChecks(s, 1);
    var pbuf: [4096]u8 = undefined;
    // One of ten edited: updated.
    try f.root.write("n0.txt", "first edit marmalade\n");
    try setMtime(try f.root.path(&pbuf, "n0.txt"), sys.nowSeconds() - 100);
    try pokeAndWait(s);
    try testing.expectEqual(@as(u32, 1), s.status().updates);
    // Three more: 4 removed of 14 is past 20 %, so rebuilt whole.
    for (1..4) |i| {
        var nbuf: [32]u8 = undefined;
        const name = try std.mem.print(&nbuf, "n{d}.txt", .{i});
        try f.root.write(name, "later edit quokka\n");
        try setMtime(try f.root.path(&pbuf, name), sys.nowSeconds() - 50);
    }
    try pokeAndWait(s);
    const st = s.status();
    try testing.expectEqual(@as(u32, 3), st.builds);
    try testing.expectEqual(@as(u32, 1), st.updates);
    try testing.expectEqual(@as(usize, 10), st.docs);
    try testing.expectEqual(@as(usize, 3), (try f.find(s, "quokka")).len);
    try testing.expectEqual(@as(usize, 1), (try f.find(s, "marmalade")).len);
    // Whole again: nothing removed is left.
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    try testing.expectEqual(@as(usize, 0), s.index.?.n_removed);
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
            try st.write("word/document.xml", try std.mem.print(&xbuf,
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
    const prefix = try std.mem.print(&hash_buf, "{x:0>16}-", .{std.hash.Wyhash.hash(0, report)});
    const v2 = sys.nowSeconds() - 100;

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
        const text = s.readText(
            f.arena_state.allocator(),
            hits[0].path,
            hits[0].mtime,
            true,
            std.math.maxInt(u32),
        ).?;
        try testing.expectEqualStrings("Minutes about the wombat project", text);
        // Asked as plain text, the zip is not the text.
        if (s.readText(
            f.arena_state.allocator(),
            hits[0].path,
            hits[0].mtime,
            false,
            std.math.maxInt(u32),
        )) |raw| {
            try testing.expect(std.mem.find(u8, raw, "wombat") == null);
        }

        // Unchanged: neither extracted nor rebuilt again (the broken one too).
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 2), st.extractions);
        try testing.expectEqual(@as(u32, 1), st.builds);

        // A new version: extracted once more, the old version's text dropped.
        try zipDoc(&stage, report, "platypus");
        try setMtime(report, v2);
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 3), st.extractions);
        try testing.expectEqual(@as(u32, 2), st.builds);
        try testing.expectEqual(@as(usize, 1), try countText(s, prefix));
        var nbuf: [64]u8 = undefined;
        const name = try std.mem.print(&nbuf, "{s}{d}-", .{ prefix, v2 });
        try testing.expectEqual(@as(usize, 1), try countText(s, name));
        try testing.expectEqual(@as(usize, 0), (try f.find(s, "wombat")).len);
        hits = try f.find(s, "platypus");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expect(hits[0].extracted);

        // Edited again within the same second (the same mtime, another
        // size): the old text was reused, then the current one deleted as
        // the old version's.
        try zipDoc(&stage, report, "echidna, and a much longer sentence");
        try setMtime(report, v2);
        try pokeAndWait(s);
        try testing.expectEqual(@as(u32, 4), s.status().extractions);
        try testing.expectEqual(@as(usize, 0), (try f.find(s, "platypus")).len);
        try testing.expectEqual(@as(usize, 1), (try f.find(s, "echidna")).len);
        try testing.expectEqual(@as(usize, 1), try countText(s, prefix));
    }

    // Texts no document refers to: a version never indexed (a crash in
    // between), the old naming, a write cut short. Swept on start.
    try f.cache.write("text/0123456789abcdef-1700000000-99.txt", "stale");
    try f.cache.write("text/0123456789abcdef-1700000000.txt", "old name");
    try f.cache.write("text/0123456789abcdef-1-2.txt.tmp", "half");
    // And the current version's text under the naming before sizes: renamed
    // on start, not extracted again.
    var nbuf: [4096]u8 = undefined;
    var obuf: [4096]u8 = undefined;
    const size = sys.info(report).?.size;
    const now_name = try std.mem.printSentinel(&nbuf, "{s}/text/{s}{d}-{d}.txt", .{
        f.cache.abs,
        prefix,
        v2,
        size,
    }, 0);
    const old_name = try std.mem.printSentinel(&obuf, "{s}/text/{s}{d}.txt", .{
        f.cache.abs,
        prefix,
        v2,
    }, 0);
    try sys.rename(now_name, old_name);

    // Restarted: the extracted text is reused, nothing is extracted again.
    // (Its text is found once renamed: the start's sweep, then the check.)
    const s = try f.start();
    defer s.shutdown();
    try waitChecks(s, 1);
    try testing.expectEqual(@as(u32, 0), s.status().extractions);
    try testing.expectEqual(@as(u32, 0), s.status().builds);
    try testing.expectEqual(@as(usize, 0), try countText(s, "0123456789abcdef-"));
    // Both documents' texts stay (the broken one's is empty).
    try testing.expectEqual(@as(usize, 2), try countText(s, ""));
    try testing.expect(sys.exists(now_name));
    try testing.expectEqual(@as(usize, 1), (try f.find(s, "echidna")).len);

    // Deleted: its text goes with it.
    _ = linux.unlink(report);
    try pokeAndWait(s);
    try testing.expectEqual(@as(usize, 0), try countText(s, prefix));
    try testing.expectEqual(@as(usize, 1), s.status().docs);
}

test "content service: a document whose extraction failed in passing is left out, and retried" {
    var t = try TestTree.init();
    defer t.deinit();
    try t.write("a.pdf", "not really a pdf");
    try t.write("b.txt", "plain words here");
    var pbuf: [4096]u8 = undefined;
    const pdf = try t.path(&pbuf, "a.pdf");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pool = try Pool.create(testing.allocator, testing.io, 0);
    defer pool.destroy();
    // Only what retrying touches: no thread, no cache.
    var s: ContentService = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .root = t.abs,
        .cache_path = undefined,
        .text_dir = undefined,
        .search_pool = pool,
        .build_pool = pool,
        .opts = .{},
        .retry_arena = .init(testing.allocator),
    };
    defer s.retry_arena.deinit();
    const docs = content_list.list(arena, testing.allocator, testing.io, t.abs, true) catch |err|
        return switch (err) {
            error.FileNotFound => error.SkipZigTest, // no ripgrep
            else => err,
        };
    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqualStrings(pdf, docs[0].path);

    // Timed out: left out (indexed, it stayed textless until it changed).
    const kept = s.leaveOut(arena, docs, &.{0}, &[_]?anyerror{error.Timeout}).?;
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(std.mem.endsWith(u8, kept[0].path, "/b.txt"));
    try testing.expectEqual(@as(usize, 1), s.retry.len);
    try testing.expectEqualStrings(pdf, s.retry[0].path);
    const reader: content.TextReader = .{ .read = textOf, .ctx = &s };
    s.index = try content.build(testing.allocator, pool, kept, reader, null);
    defer s.index.?.deinit(testing.allocator);

    // The next check, though it lists nothing, tries it again.
    const d = try s.indexedChanges(arena);
    try testing.expectEqual(@as(usize, 0), d.gone.len);
    try testing.expectEqual(@as(usize, 1), d.added.len);
    try testing.expectEqualStrings(pdf, d.added[0].path);
    try testing.expectEqual(content.Source.extracted, d.added[0].source);
    // Extracted this time: indexed, nothing left to retry.
    const all = s.leaveOut(arena, d.added, &.{0}, &[_]?anyerror{null}).?;
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqual(@as(usize, 0), s.retry.len);
}
