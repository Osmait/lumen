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
//! cached in `text_dir` as `<hash of path>-<mtime>.txt`: extraction (a child
//! process per file) happens once per version of a document.

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
        .{ .limit = limit, .text_path = pathOf, .text_ctx = s },
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
/// few KB of it.
pub fn readText(
    s: *ContentService,
    arena: std.mem.Allocator,
    path: []const u8,
    mtime: i64,
    extracted: bool,
    lines: u32,
) ?[]const u8 {
    var pbuf: [4096]u8 = undefined;
    const p: [:0]const u8 = if (extracted)
        s.textPath(&pbuf, .{
            .path = path,
            .mtime = mtime,
            .size = 0,
            .source = .extracted,
        }) orelse return null
    else
        std.mem.printSentinel(&pbuf, "{s}", .{path}, 0) catch return null;
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

fn textPath(s: *ContentService, buf: []u8, d: content.DocIn) ?[:0]const u8 {
    return std.mem.printSentinel(
        buf,
        "{s}/{x:0>16}-{d}.txt",
        .{ s.text_dir, std.hash.Wyhash.hash(0, d.path), d.mtime },
        0,
    ) catch null;
}

/// Extracts what is missing from the text cache, on the background pool
/// (a PDF takes 10-40 ms, a whole book up to ~0.7 s). Documents that cannot
/// be extracted (a corrupt file, a tool error) get an empty file, so they
/// are not retried every refresh; passing failures (out of memory, a
/// timeout, a missing tool) leave nothing, so the next refresh tries again.
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
            const src = std.mem.printSentinel(&zbuf, "{s}", .{d.path}, 0) catch return;
            const text = extract.extractText(
                svc.gpa,
                svc.io,
                src,
                kind,
                max_extracted,
            ) catch |err| switch (err) {
                error.ToolFailed, error.NotRegular, error.Access, error.NotFound => "",
                else => {
                    log.warn("extracting {s}: {t}, will retry", .{ d.path, err });
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
    var ctx: Ctx = .{ .s = s, .docs = missing.items };
    s.build_pool.run(missing.items.len, &ctx, Ctx.one);
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
            if (ix.mtimes[id] == d.mtime and ix.sizes[id] == d.size and ix.sources[id] == @backingInt(
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
    const docs = content_list.list(arena, s.gpa, s.io, s.root, true) catch |err| {
        log.warn("listing files: {t}", .{err});
        return null;
    };
    s.last_list_ns.store(sys.monotonicNs() - t, .monotonic);
    _ = s.listings.fetchAdd(1, .release);
    s.listed_names = names;
    s.last_listing_at = t;
    return docs;
}

/// Changes to the files already indexed, without listing: edits in place
/// (mtime, size), and files gone or out of bounds. New files need a name
/// change, which makes the next check list. Paths point into the index,
/// which outlives the refresh.
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
    return .{ .gone = gone.items, .added = added.items };
}

fn refresh(s: *ContentService) void {
    s.last_check_ns.store(sys.monotonicNs(), .release);
    // Counted when done, so `checks` going up means its result is visible.
    defer _ = s.checks.fetchAdd(1, .release);
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t = sys.monotonicNs();
    const names = if (s.opts.names) |n| n.nameChanges() else null;
    const must_list = s.index == null or names == null or s.listed_names == null or
        names.? != s.listed_names.? or t - s.last_listing_at >= s.opts.list_every_ns;
    var docs: ?[]content.DocIn = null;
    var d = if (must_list) blk: {
        docs = s.listAll(arena, names) orelse return;
        break :blk s.diff(arena, docs.?) catch return;
    } else blk: {
        const r = s.indexedChanges(arena) catch return;
        s.last_stat_ns.store(sys.monotonicNs() - t, .monotonic);
        break :blk r;
    };
    if (s.index != null and d.gone.len == 0 and d.added.len == 0) {
        if (s.unsaved) s.retrySave();
        return;
    }

    s.building.store(true, .release);
    defer s.building.store(false, .release);
    defer @import("root.zig").trimHeap();
    // Whole when there is nothing to update, or when what updates leave
    // behind (removed versions, small segments) has piled up.
    const whole = if (s.index) |*ix| blk: {
        const removed = ix.n_removed + d.gone.len;
        const total = ix.n_docs + d.added.len;
        break :blk removed * 100 > total * s.opts.max_removed_percent or ix.n_segs >= s.opts.max_segments or
            // What updates left behind in the file: over 30 %.
            ix.buf.len * 10 > ix.live_bytes * 13;
    } else true;
    // A whole build indexes every file: they must be listed.
    if (whole and docs == null) {
        docs = s.listAll(arena, names) orelse return;
        d = s.diff(arena, docs.?) catch return;
    }
    t = sys.monotonicNs();
    s.extractMissing(if (whole) docs.? else d.added);
    s.last_extract_ns.store(sys.monotonicNs() - t, .monotonic);
    if (s.stop.load(.acquire)) return;
    t = sys.monotonicNs();
    const reader: content.TextReader = .{ .read = textOf, .ctx = s };
    if (std.mem.findScalarLast(u8, s.cache_path, '/')) |slash| sys.mkdirP(s.cache_path[0..slash]);
    // Written to the cache file as it grows and served mapped: clean page
    // cache, never the whole index in heap.
    // An update is appended to the file the index is mapped from; rewritten
    // whole if that file is not what the index was mapped from.
    const appended: ?content.FileError!content.Index = if (!whole and s.index.?.mapped and !s.unsaved)
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
    const written = appended orelse if (whole)
        content.buildFile(s.gpa, s.build_pool, docs.?, reader, s.cache_path, null)
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
            return;
        }
        // Not written (a full disk, a read-only cache): built in memory and
        // served from there; saving is retried on the next check.
        log.warn("writing the content index: {t}", .{file_err});
        s.unsaved = true;
        break :blk (if (whole)
            content.build(s.gpa, s.build_pool, docs.?, reader, null)
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
            return;
        };
    };
    if (fresh.mapped) s.unsaved = false;
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
        const tp = s.textPath(&pbuf, .{
            .path = old.path(id),
            .mtime = old.mtimes[id],
            .size = 0,
            .source = .extracted,
        }) orelse continue;
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
        if (since >= s.opts.refresh_every_ns or (poked and since >= s.opts.poke_min_ns)) s.refresh();
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
        const v2 = sys.nowSeconds() - 100;
        try setMtime(report, v2);
        try pokeAndWait(s);
        st = s.status();
        try testing.expectEqual(@as(u32, 3), st.extractions);
        try testing.expectEqual(@as(u32, 2), st.builds);
        try testing.expectEqual(@as(usize, 1), try countText(s, prefix));
        var nbuf: [64]u8 = undefined;
        const name = try std.mem.print(&nbuf, "{s}{d}.txt", .{ prefix, v2 });
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
