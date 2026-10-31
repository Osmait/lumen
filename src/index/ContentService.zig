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
const assert = std.debug.assert;
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
    refresh_interval_ns: u64 = 5 * 60 * std.time.ns_per_s,
    /// Opening the window asks for a refresh, at most this often.
    poke_interval_ns_min: u64 = 30 * std.time.ns_per_s,
    /// Rebuilt whole instead of updated past this share of removed
    /// documents (in percent), or this many segments.
    removed_percent_max: u8 = 20,
    segments_max: usize = 32,
    /// The name index over the same root: while it saw no name change that
    /// could matter, a check only looks at the files already indexed
    /// (edits in place) instead of listing them all with ripgrep (~0.45 s
    /// of CPU for 49 k). Null: always list.
    names: ?*Service = null,
    /// Listed at least this often anyway (a .gitignore edited in place
    /// changes what is listed without a name change).
    list_interval_ns: u64 = 30 * 60 * std.time.ns_per_s,
};
const extracted_bytes_max = content.extracted_bytes_max;

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
thread: ?std.Thread = null,
/// Written by the service thread, read by any thread (`status`).
counters: Counters = .{},
/// The service thread's own state, read and written without the lock.
worker: Worker,

/// What the service thread counts and times, for `lumen --stats` and for
/// tests (`checks` counts finished checks). Only the service thread writes
/// them; any thread reads them through `status`, so they are atomics.
pub const Counters = struct {
    building: std.atomic.Value(bool) = .init(false),
    builds: std.atomic.Value(u32) = .init(0),
    /// Of the builds, the ones that only added what changed.
    updates: std.atomic.Value(u32) = .init(0),
    /// Checks that listed every file (the others only looked at indexed
    /// ones).
    listings: std.atomic.Value(u32) = .init(0),
    checks: std.atomic.Value(u32) = .init(0),
    /// Documents whose text was extracted (a child process each).
    extractions: std.atomic.Value(u32) = .init(0),
    /// When the last check started, for the rate limit of `poke`.
    last_check_ns: std.atomic.Value(u64) = .init(0),
    last_list_ns: std.atomic.Value(u64) = .init(0),
    /// The last check that looked at indexed files only.
    last_stat_ns: std.atomic.Value(u64) = .init(0),
    last_build_ns: std.atomic.Value(u64) = .init(0),
    last_extract_ns: std.atomic.Value(u64) = .init(0),
};

/// State only the service thread reads or writes, so it needs no lock and no
/// atomics. Every function that touches it asserts the thread
/// (`assertWorkerThread`).
const Worker = struct {
    /// The service thread, set by `run` before its first check.
    thread_id: ?std.Thread.Id = null,
    /// `names.nameChanges()` when files were last listed.
    listed_names: ?u64 = null,
    listed_at_ns: u64 = 0,
    /// The index in use could not be saved: retried on the next check even
    /// if nothing changed.
    unsaved: bool = false,
    /// Documents whose extraction failed in passing (a timeout, a missing
    /// tool, memory): kept out of the index, which would remember them as
    /// textless for as long as they do not change, and tried again by the
    /// next check. In `retry_arena`.
    retry: []const content.DocIn = &.{},
    retry_arena: std.heap.ArenaAllocator,
};

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
    const service = try gpa.create(ContentService);
    errdefer gpa.destroy(service);
    const root_copy = try gpa.dupe(u8, root);
    errdefer gpa.free(root_copy);
    const cache_path = try gpa.printSentinel("{s}/content.idx", .{cache_dir}, 0);
    errdefer gpa.free(cache_path);
    const text_dir = try gpa.print("{s}/text", .{cache_dir});
    errdefer gpa.free(text_dir);
    service.* = .{
        .gpa = gpa,
        .io = io,
        .root = root_copy,
        .cache_path = cache_path,
        .text_dir = text_dir,
        .search_pool = pools.search,
        .build_pool = pools.build,
        .opts = opts,
        .worker = .{ .retry_arena = .init(gpa) },
    };
    sys.mkdirP(service.text_dir);
    // Older versions made these 0755: the cache holds the text of the
    // user's documents, so close it before anything else.
    sys.makePrivate(cache_dir);
    sys.makePrivate(service.text_dir);
    // Absent or unreadable: built from scratch by the first refresh.
    service.index = content.Index.open(service.cache_path) catch null;
    errdefer if (service.index) |*index| index.deinit(gpa);
    service.thread = try std.Thread.spawn(.{}, run, .{service});
    // A thread without a name works the same; only `top` shows it.
    service.thread.?.setName(io, "lm-content") catch {};
    return service;
}

pub fn shutdown(service: *ContentService) void {
    service.stop.store(true, .release);
    service.poke();
    if (service.thread) |t| t.join();
    if (service.index) |*ix| ix.deinit(service.gpa);
    service.worker.retry_arena.deinit();
    service.gpa.free(service.root);
    service.gpa.free(service.cache_path);
    service.gpa.free(service.text_dir);
    service.gpa.destroy(service);
}

/// The window opened: check for changes soon (rate-limited).
pub fn poke(service: *ContentService) void {
    _ = service.wake.fetchAdd(1, .release);
    service.io.futexWake(u32, &service.wake.raw, 1);
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

pub fn status(service: *ContentService) Status {
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    var extracted: usize = 0;
    if (service.index) |ix| {
        for (ix.sources, 0..) |src, i| extracted += @intFromBool(
            src == @backingInt(content.Source.extracted) and !ix.removed(@intCast(i)),
        );
    }
    return .{
        .docs = if (service.index) |ix| ix.live() else 0,
        .building = service.counters.building.load(.acquire),
        .ready = service.index != null,
        .extracted = extracted,
        .segments = if (service.index) |ix| ix.segments_count else 0,
        .index_bytes = if (service.index) |ix| ix.buf.len else 0,
        .builds = service.counters.builds.load(.acquire),
        .updates = service.counters.updates.load(.acquire),
        .listings = service.counters.listings.load(.acquire),
        .checks = service.counters.checks.load(.acquire),
        .extractions = service.counters.extractions.load(.acquire),
        .last_list_ns = service.counters.last_list_ns.load(.monotonic),
        .last_stat_ns = service.counters.last_stat_ns.load(.monotonic),
        .last_build_ns = service.counters.last_build_ns.load(.monotonic),
        .last_extract_ns = service.counters.last_extract_ns.load(.monotonic),
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
    service: *ContentService,
    arena: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    return service.searchUntil(arena, query, limit, null, out);
}

/// `search`, cut short once `stop` is set (a newer query waits): reading
/// files to verify them stops at the next one, and the hits found so far
/// are returned. Until then it holds the search pool and the index.
pub fn searchUntil(
    service: *ContentService,
    arena: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    stop: ?*const std.atomic.Value(bool),
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    const ix = if (service.index) |*i| i else return;
    var matches: std.ArrayList(content.Match) = .empty;
    try content.search(
        ix,
        service.gpa,
        arena,
        service.search_pool,
        query,
        .{ .limit = limit, .text_path = pathOf, .text_ctx = service, .stop = stop },
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
fn pathOf(ctx: *anyopaque, doc: content.DocIn, buf: []u8) ?[:0]const u8 {
    const service: *ContentService = @ptrCast(@alignCast(ctx));
    switch (doc.source) {
        .plain => return std.mem.printSentinel(buf, "{s}", .{doc.path}, 0) catch null,
        .extracted => return service.textPath(buf, doc),
    }
}

/// The first `lines` lines of a hit's text (for the preview), in `arena`;
/// null if it cannot be read. Reads no further than that: the preview runs
/// on the UI thread, and a match near the top of a 4 MB extraction needs a
/// few KB of it. `mtime` is the document's as it is now; so is its size,
/// which keys the text cache too.
pub fn readText(
    service: *ContentService,
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
        break :blk service.textPath(&tbuf, .{
            .path = path,
            .mtime = mtime,
            .size = st.size,
            .source = .extracted,
        }) orelse return null;
    } else doc;
    const fd = sys.openRegular(p) catch return null;
    defer sys.close(fd);
    const cap: usize = if (extracted) extracted_bytes_max else content.text_bytes_max;
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
    doc: content.DocIn,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    const service: *ContentService = @ptrCast(@alignCast(ctx));
    if (doc.source == .plain) return content.readPlain(gpa, doc.path, buf);
    var path_buffer: [4096]u8 = undefined;
    const text_path = service.textPath(&path_buffer, doc) orelse return false;
    buf.clearRetainingCapacity();
    const fd = sys.openRegular(text_path) catch return false;
    defer sys.close(fd);
    try sys.readUpTo(gpa, fd, buf, extracted_bytes_max);
    return buf.items.len > 0;
}

/// How long the cached text of an extracted document is (0: none yet), so
/// that building reads no more of them at once than memory allows.
fn textLen(ctx: *anyopaque, doc: content.DocIn) u64 {
    const service: *ContentService = @ptrCast(@alignCast(ctx));
    var path_buffer: [4096]u8 = undefined;
    const text_path = service.textPath(&path_buffer, doc) orelse return 0;
    const info = sys.info(text_path) orelse return 0;
    return info.size;
}

/// Where a document version's extracted text is cached. Keyed by size as
/// well as mtime (whole seconds): an edit within the same second reused
/// the old text, and dropping the old version's text then deleted it.
fn textPath(service: *ContentService, buf: []u8, doc: content.DocIn) ?[:0]const u8 {
    var name_buffer: [64]u8 = undefined;
    const name = textName(&name_buffer, doc);
    return std.mem.printSentinel(buf, "{s}/{s}", .{ service.text_dir, name }, 0) catch null;
}

fn textName(buf: *[64]u8, doc: content.DocIn) []const u8 {
    // 16 + 1 + 20 + 1 + 20 + 4 bytes at most: always fits.
    return std.mem.print(
        buf,
        "{x:0>16}-{d}-{d}.txt",
        .{ std.hash.Wyhash.hash(0, doc.path), doc.mtime, doc.size },
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
    service: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
) ?[]content.DocIn {
    var missing: std.ArrayList(usize) = .empty;
    var path_buffer: [4096]u8 = undefined;
    for (docs, 0..) |doc, doc_index| {
        if (doc.source != .extracted) continue;
        const text_path = service.textPath(&path_buffer, doc) orelse continue;
        if (sys.exists(text_path)) continue;
        missing.append(arena, doc_index) catch {
            log.warn("extracting documents: out of memory", .{});
            return null;
        };
    }
    // Nothing to extract: nothing to retry either.
    if (missing.items.len == 0) return service.leaveOut(arena, docs, &.{}, &.{});
    const failed = arena.alloc(?anyerror, missing.items.len) catch {
        log.warn("extracting documents: out of memory", .{});
        return null;
    };
    @memset(failed, null);
    var context: ExtractContext = .{
        .service = service,
        .docs = docs,
        .missing = missing.items,
        .failed = failed,
    };
    service.build_pool.run(missing.items.len, &context, ExtractContext.extractOne);
    return service.leaveOut(arena, docs, missing.items, failed);
}

/// What the build pool's workers share while `extractMissing` runs.
const ExtractContext = struct {
    service: *ContentService,
    docs: []const content.DocIn,
    /// Positions in `docs` of the documents to extract.
    missing: []const usize,
    /// One per `missing`: set when extracting it failed in passing.
    failed: []?anyerror,

    fn extractOne(context: *ExtractContext, missing_index: usize) void {
        const service = context.service;
        if (service.stop.load(.acquire)) return;
        const doc = context.docs[context.missing[missing_index]];
        var text_path_buffer: [4096]u8 = undefined;
        var source_path_buffer: [4096]u8 = undefined;
        const text_path = service.textPath(&text_path_buffer, doc) orelse return;
        const kind = extract.kindOf(doc.path) orelse return;
        const source_path = std.mem.printSentinel(
            &source_path_buffer,
            "{s}",
            .{doc.path},
            0,
        ) catch return;
        const text = extract.extractText(
            service.gpa,
            service.io,
            source_path,
            kind,
            extracted_bytes_max,
            &service.stop,
        ) catch |err| switch (err) {
            // For good: an empty text, so that it is not tried again until
            // the document changes.
            error.ToolFailed, error.NotRegular, error.Access, error.NotFound => "",
            else => {
                context.failed[missing_index] = err;
                return;
            },
        };
        defer if (text.len > 0) service.gpa.free(text);
        sys.writeFileAtomic(text_path, text) catch |err| {
            log.warn("caching text of {s}: {t}", .{ doc.path, err });
        };
        _ = service.counters.extractions.fetchAdd(1, .release);
    }
};

/// `docs` without those whose extraction `failed` (`missing` says which),
/// which become the documents to retry. Logged when that list changes, not
/// on every check while a tool stays missing.
fn leaveOut(
    service: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
    missing: []const usize,
    failed: []const ?anyerror,
) ?[]content.DocIn {
    service.assertWorkerThread();
    assert(missing.len == failed.len);
    var failed_count: usize = 0;
    var failed_first: ?usize = null;
    for (failed, 0..) |failure, missing_index| {
        if (failure == null) continue;
        failed_count += 1;
        if (failed_first == null) failed_first = missing_index;
    }
    const retry_count_before = service.worker.retry.len;
    _ = service.worker.retry_arena.reset(.retain_capacity);
    service.worker.retry = &.{};
    if (failed_count == 0) return docs;

    const first = failed_first.?;
    if (failed_count != retry_count_before) {
        log.warn(
            "extracting {d} documents failed for now ({s}: {t}), will retry",
            .{ failed_count, docs[missing[first]].path, failed[first].? },
        );
    }
    const retry_arena = service.worker.retry_arena.allocator();
    const retry = retry_arena.alloc(content.DocIn, failed_count) catch return null;
    const dropped = arena.alloc(bool, docs.len) catch return null;
    @memset(dropped, false);
    var retry_index: usize = 0;
    for (failed, missing) |failure, doc_index| {
        if (failure == null) continue;
        dropped[doc_index] = true;
        retry[retry_index] = docs[doc_index];
        retry[retry_index].path = retry_arena.dupe(u8, docs[doc_index].path) catch return null;
        retry_index += 1;
    }
    assert(retry_index == failed_count);
    service.worker.retry = retry;

    var kept_count: usize = 0;
    for (docs, dropped) |doc, doc_dropped| {
        if (doc_dropped) continue;
        docs[kept_count] = doc;
        kept_count += 1;
    }
    assert(kept_count + failed_count == docs.len);
    return docs[0..kept_count];
}

/// How the listed documents differ from the index: ids whose document
/// changed or is gone, and the documents to index (changed or new).
const Diff = struct { gone: []u32, added: []content.DocIn };

/// Called on the service thread, the only one that replaces the index, so
/// it can read it without the lock.
fn diff(
    service: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
) std.mem.Allocator.Error!Diff {
    service.assertWorkerThread();
    const index = if (service.index) |*index| index else return .{ .gone = &.{}, .added = docs };
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    try ids.ensureTotalCapacity(arena, @intCast(index.live()));
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (index.removed(id)) continue;
        ids.putAssumeCapacity(index.path(id), id);
    }
    const seen = try arena.alloc(bool, index.docs_count);
    @memset(seen, false);
    var gone: std.ArrayList(u32) = .empty;
    var added: std.ArrayList(content.DocIn) = .empty;
    for (docs) |doc| {
        if (ids.get(doc.path)) |id| {
            seen[id] = true;
            if (unchanged(index, id, doc)) continue;
            try gone.append(arena, id);
        }
        try added.append(arena, doc);
    }
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (index.removed(id)) continue;
        if (seen[id]) continue;
        try gone.append(arena, id);
    }
    return .{ .gone = gone.items, .added = added.items };
}

/// Whether `doc` is the version of document `id` that the index holds.
fn unchanged(index: *const content.Index, id: u32, doc: content.DocIn) bool {
    if (index.mtimes[id] != doc.mtime) return false;
    if (index.sizes[id] != doc.size) return false;
    return index.sources[id] == @backingInt(doc.source);
}

/// Every file to index, listed by ripgrep; `names` is what the name index
/// said before listing, so a change during the listing lists again next time.
fn listAll(service: *ContentService, arena: std.mem.Allocator, names: ?u64) ?[]content.DocIn {
    service.assertWorkerThread();
    const start_ns = sys.monotonicNs();
    const docs = content_list.listUntil(
        arena,
        service.gpa,
        service.io,
        service.root,
        true,
        &service.stop,
    ) catch |err| {
        if (err != error.Canceled) log.warn("listing files: {t}", .{err});
        return null;
    };
    service.counters.last_list_ns.store(sys.monotonicNs() - start_ns, .monotonic);
    _ = service.counters.listings.fetchAdd(1, .release);
    service.worker.listed_names = names;
    service.worker.listed_at_ns = start_ns;
    return docs;
}

/// Changes to the files already indexed, without listing: edits in place
/// (mtime, size), and files gone or out of bounds; and the documents to
/// retry. New files need a name change, which makes the next check list.
/// Paths point into the index, which outlives the refresh, or `arena`.
fn indexedChanges(
    service: *ContentService,
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!Diff {
    service.assertWorkerThread();
    const index = &service.index.?;
    var gone: std.ArrayList(u32) = .empty;
    var added: std.ArrayList(content.DocIn) = .empty;
    var path_buffer: [4096]u8 = undefined;
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (index.removed(id)) continue;
        const doc = index.docIn(id);
        const path = std.mem.printSentinel(&path_buffer, "{s}", .{doc.path}, 0) catch continue;
        const stat_now = content_list.stat(path, doc.source == .extracted);
        if (stat_now) |stat| {
            if (stat.mtime == doc.mtime and stat.size == doc.size) continue;
        }
        try gone.append(arena, id);
        // Gone, or out of bounds now: only removed.
        const stat = stat_now orelse continue;
        try added.append(arena, .{
            .path = doc.path,
            .mtime = stat.mtime,
            .size = stat.size,
            .source = doc.source,
        });
    }
    // Not in the index (`extractMissing` left them out): as they are now.
    for (service.worker.retry) |doc| {
        const path = std.mem.printSentinel(&path_buffer, "{s}", .{doc.path}, 0) catch continue;
        const stat = content_list.stat(path, true) orelse continue;
        try added.append(arena, .{
            .path = try arena.dupe(u8, doc.path),
            .mtime = stat.mtime,
            .size = stat.size,
            .source = .extracted,
        });
    }
    return .{ .gone = gone.items, .added = added.items };
}

/// The service thread is the only one that replaces the index and the only
/// one that touches `worker`: what it does without the lock relies on that.
fn assertWorkerThread(service: *const ContentService) void {
    assert(service.worker.thread_id.? == std.Thread.getCurrentId());
}

fn refresh(service: *ContentService) void {
    service.assertWorkerThread();
    service.counters.last_check_ns.store(sys.monotonicNs(), .release);
    // Counted when done, so `checks` going up means its result is visible.
    defer _ = service.counters.checks.fetchAdd(1, .release);
    var arena_state: std.heap.ArenaAllocator = .init(service.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = if (service.opts.names) |names| names.nameChanges() else null;
    var docs: ?[]content.DocIn = null;
    var changed = service.changes(arena, names, &docs) orelse return;
    if (service.stop.load(.acquire)) return;
    if (service.index != null and changed.gone.len == 0 and changed.added.len == 0) {
        if (service.worker.unsaved) service.retrySave();
        return;
    }

    service.counters.building.store(true, .release);
    defer service.counters.building.store(false, .release);
    defer @import("root.zig").trimHeap();
    const whole = service.wantsWhole(changed);
    // A whole build indexes every file: they must be listed.
    if (whole and docs == null) {
        docs = service.listAll(arena, names) orelse return;
        changed = service.diff(arena, docs.?) catch return;
    }
    var start_ns = sys.monotonicNs();
    if (whole) {
        docs = service.extractMissing(arena, docs.?) orelse return;
    } else {
        changed.added = service.extractMissing(arena, changed.added) orelse return;
    }
    service.counters.last_extract_ns.store(sys.monotonicNs() - start_ns, .monotonic);
    if (service.stop.load(.acquire)) return;
    // Only documents to retry, which failed again.
    if (!whole and changed.gone.len == 0 and changed.added.len == 0) return;
    start_ns = sys.monotonicNs();
    const fresh = service.buildNext(if (whole) docs.? else null, changed) orelse return;
    service.counters.last_build_ns.store(sys.monotonicNs() - start_ns, .monotonic);
    _ = service.counters.builds.fetchAdd(1, .release);
    if (!whole) _ = service.counters.updates.fetchAdd(1, .release);

    var old = blk: {
        service.lock.lockUncancelable(service.io);
        defer service.lock.unlock(service.io);
        const old = service.index;
        service.index = fresh;
        break :blk old;
    };
    if (old) |*old_index| {
        service.dropStaleText(old_index, changed.gone);
        old_index.deinit(service.gpa);
    }
    if (whole) service.sweepText();
}

/// What changed since the index was built: every file listed again (no
/// index yet, names created or removed, or the listing is old), or only
/// the indexed ones checked. A listing is left in `docs`.
fn changes(
    service: *ContentService,
    arena: std.mem.Allocator,
    names: ?u64,
    docs: *?[]content.DocIn,
) ?Diff {
    const start_ns = sys.monotonicNs();
    if (service.listingReason(names, start_ns) != null) {
        docs.* = service.listAll(arena, names) orelse return null;
        return service.diff(arena, docs.*.?) catch null;
    }
    const changed = service.indexedChanges(arena) catch return null;
    service.counters.last_stat_ns.store(sys.monotonicNs() - start_ns, .monotonic);
    return changed;
}

/// Why every file must be listed again rather than only the indexed ones
/// looked at.
const ListingReason = enum { no_index, names_unknown, names_changed, listing_stale };

fn listingReason(service: *const ContentService, names: ?u64, now_ns: u64) ?ListingReason {
    service.assertWorkerThread();
    if (service.index == null) return .no_index;
    const names_now = names orelse return .names_unknown;
    const names_listed = service.worker.listed_names orelse return .names_unknown;
    if (names_now != names_listed) return .names_changed;
    if (now_ns - service.worker.listed_at_ns >= service.opts.list_interval_ns) return .listing_stale;
    return null;
}

/// What updates may leave behind in the file (old doc tables, merged
/// segments) before the index is rebuilt whole, in percent of what is in use.
const garbage_percent_max = 30;

/// Whole when there is nothing to update, or when what updates leave
/// behind (removed versions, small segments, unused bytes) has piled up.
fn wantsWhole(service: *const ContentService, changed: Diff) bool {
    const index = &(service.index orelse return true);
    const removed_count = index.docs_removed_count + changed.gone.len;
    const docs_count = index.docs_count + changed.added.len;
    if (removed_count * 100 > docs_count * service.opts.removed_percent_max) return true;
    if (index.segments_count >= service.opts.segments_max) return true;
    return index.buf.len * 100 > index.bytes_live * (100 + garbage_percent_max);
}

/// How `buildNext` gets the next index to the cache file.
const BuildStrategy = enum {
    /// Every document, into a new file.
    build_whole,
    /// Only what changed, after the file the index is mapped from.
    append_to_mapped_file,
    /// The index with what changed, into a new file: the index in use is
    /// not mapped from the file (it was built in memory, or not saved).
    rewrite_file,
};

fn buildStrategy(service: *const ContentService, docs_all: ?[]const content.DocIn) BuildStrategy {
    service.assertWorkerThread();
    if (docs_all != null) return .build_whole;
    const index = &service.index.?;
    if (!index.mapped) return .rewrite_file;
    if (service.worker.unsaved) return .rewrite_file;
    return .append_to_mapped_file;
}

/// The next index: `docs_all` built whole, or the current one updated with
/// `changed`. Written to the cache file as it grows and served mapped
/// (clean page cache, never the whole index in heap); an update is
/// appended to the file the index is mapped from, or the file rewritten if
/// it is not that one any more. Null (logged) when it cannot be built.
fn buildNext(
    service: *ContentService,
    docs_all: ?[]const content.DocIn,
    changed: Diff,
) ?content.Index {
    service.assertWorkerThread();
    const reader: content.TextReader = .{
        .read = textOf,
        .ctx = service,
        .extracted_len = textLen,
    };
    if (std.mem.findScalarLast(u8, service.cache_path, '/')) |slash| {
        sys.mkdirP(service.cache_path[0..slash]);
    }
    const strategy = service.buildStrategy(docs_all);
    if (service.buildNextToFile(strategy, docs_all, changed, reader)) |fresh| {
        if (fresh.mapped) service.worker.unsaved = false;
        return fresh;
    } else |err| switch (err) {
        error.OutOfMemory => {
            log.warn("building the content index: out of memory", .{});
            return null;
        },
        // Building it in memory instead would not make it smaller.
        error.IndexTooLarge => {
            log.err("building the content index: too many documents or paths for u32 ids", .{});
            return null;
        },
        // Not written (a full disk, a read-only cache): built in memory and
        // served from there; saving is retried on the next check.
        else => {
            log.warn("writing the content index: {t}", .{err});
            service.worker.unsaved = true;
        },
    }
    const fresh = if (docs_all) |docs|
        content.build(service.gpa, service.build_pool, docs, reader, null)
    else
        content.update(
            service.gpa,
            service.build_pool,
            &service.index.?,
            changed.gone,
            changed.added,
            reader,
            null,
        );
    return fresh catch |err| {
        log.warn("building the content index: {t}", .{err});
        return null;
    };
}

fn buildNextToFile(
    service: *ContentService,
    strategy: BuildStrategy,
    docs_all: ?[]const content.DocIn,
    changed: Diff,
    reader: content.TextReader,
) content.FileError!content.Index {
    const gpa = service.gpa;
    const pool = service.build_pool;
    const path = service.cache_path;
    switch (strategy) {
        .build_whole => return content.buildFile(gpa, pool, docs_all.?, reader, path, null),
        .append_to_mapped_file => {
            const index = &service.index.?;
            const appended = try content.appendFile(
                gpa,
                pool,
                index,
                changed.gone,
                changed.added,
                reader,
                path,
                null,
            );
            if (appended) |fresh| return fresh;
            // The file is not the one the index was mapped from any more:
            // rewritten instead.
        },
        .rewrite_file => {},
    }
    return content.updateFile(
        gpa,
        pool,
        &service.index.?,
        changed.gone,
        changed.added,
        reader,
        path,
        null,
    );
}

fn retrySave(service: *ContentService) void {
    service.assertWorkerThread();
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    const index = service.index orelse return;
    index.save(service.cache_path) catch |err| {
        log.warn("saving the content index: {t}", .{err});
        return;
    };
    service.worker.unsaved = false;
}

/// Deletes the cached text of document versions that are gone (edited or
/// deleted): it is keyed by mtime, so each edit otherwise left the old
/// text in the cache for good.
fn dropStaleText(service: *ContentService, old: *const content.Index, gone: []const u32) void {
    var path_buffer: [4096]u8 = undefined;
    for (gone) |id| {
        if (old.sources[id] != @backingInt(content.Source.extracted)) continue;
        const text_path = service.textPath(&path_buffer, old.docIn(id)) orelse continue;
        _ = std.os.linux.unlink(text_path);
    }
}

/// Deletes the cached texts no live document of the index refers to: what
/// `dropStaleText` cannot know of, versions extracted and never indexed
/// (out of memory, a shutdown or a crash in between), half-written ones.
/// A text cached under the name used before sizes were part of it
/// (`<hash>-<mtime>.txt`) is renamed instead, not extracted again. On
/// start and after a whole build, on the service thread: the one that
/// writes them.
fn sweepText(service: *ContentService) void {
    const ix = &(service.index orelse return);
    var arena_state: std.heap.ArenaAllocator = .init(service.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A name in the cache -> the name it should have.
    var keep: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (0..ix.docs_count) |i| {
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
    const dir = std.mem.printSentinel(&dbuf, "{s}", .{service.text_dir}, 0) catch return;
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

fn run(service: *ContentService) void {
    service.worker.thread_id = std.Thread.getCurrentId();
    // A saved index is a photo: always check it on start.
    // `seen` is read before refreshing: a poke that lands during a refresh
    // still counts afterwards (it may come after the listing).
    var seen = service.wake.load(.acquire);
    // Before the check, which would extract again what is cached under the
    // older naming.
    service.sweepText();
    service.refresh();
    while (!service.stop.load(.acquire)) {
        // Sleep until the next periodic check; `poke` and `shutdown` wake
        // the thread sooner. The wait cannot be canceled: this thread is
        // joined, never canceled.
        const since_check_ns = sys.monotonicNs() - service.counters.last_check_ns.load(.acquire);
        const due_ns = service.opts.refresh_interval_ns -| since_check_ns;
        service.io.futexWaitTimeout(u32, &service.wake.raw, seen, .{ .duration = .{
            .raw = .fromNanoseconds(@max(due_ns, std.time.ns_per_s)),
            .clock = .awake,
        } }) catch {};
        if (service.stop.load(.acquire)) return;
        const since_ns = sys.monotonicNs() - service.counters.last_check_ns.load(.acquire);
        const wake_now = service.wake.load(.acquire);
        const poked = wake_now != seen;
        seen = wake_now;
        if (since_ns >= service.opts.refresh_interval_ns) {
            service.refresh();
        } else if (poked and since_ns >= service.opts.poke_interval_ns_min) {
            service.refresh();
        }
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

    fn init(fixture: *Fixture) !void {
        if (!haveTool("rg")) return error.SkipZigTest;
        fixture.root = try TestTree.init();
        errdefer fixture.root.deinit();
        fixture.cache = try TestTree.init();
        errdefer fixture.cache.deinit();
        fixture.search_pool = try Pool.create(testing.allocator, testing.io, 1);
        errdefer fixture.search_pool.destroy();
        fixture.build_pool = try Pool.create(testing.allocator, testing.io, 1);
        fixture.arena_state = .init(testing.allocator);
        fixture.hits = .empty;
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena_state.deinit();
        fixture.build_pool.destroy();
        fixture.search_pool.destroy();
        fixture.cache.deinit();
        fixture.root.deinit();
    }

    /// Refreshes only when poked (no rate limit) and once at start.
    fn start(fixture: *Fixture) !*ContentService {
        // Small trees: one edit is a large share, so updates are allowed
        // whatever the share (the compaction test sets its own).
        return fixture.startWith(.{
            .refresh_interval_ns = std.math.maxInt(u64),
            .poke_interval_ns_min = 0,
            .removed_percent_max = 100,
        });
    }

    fn startWith(fixture: *Fixture, opts: Options) !*ContentService {
        return ContentService.startWith(
            testing.allocator,
            testing.io,
            fixture.root.abs,
            fixture.cache.abs,
            .{ .search = fixture.search_pool, .build = fixture.build_pool },
            opts,
        );
    }

    fn find(fixture: *Fixture, service: *ContentService, query: []const u8) ![]Hit {
        try service.search(fixture.arena_state.allocator(), query, 10, &fixture.hits);
        return fixture.hits.items;
    }
};

fn waitChecks(service: *ContentService, n: u32) !void {
    for (0..2000) |_| {
        if (service.status().checks >= n) return;
        sys.sleepUs(5_000);
    }
    return error.Timeout;
}

/// What the window does on open, then waits for that check to finish.
fn pokeAndWait(service: *ContentService) !void {
    const n = service.status().checks;
    service.poke();
    try waitChecks(service, n + 1);
}

/// Moves a file's mtime away from "now": the index compares whole seconds.
fn setMtime(path: [:0]const u8, sec: i64) !void {
    const ts = [2]linux.timespec{ .{ .sec = sec, .nsec = 0 }, .{ .sec = sec, .nsec = 0 } };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(
        linux.utimensat(linux.AT.FDCWD, path, &ts, 0),
    ));
}

/// Files in the text cache whose name starts with `prefix`.
fn countText(service: *ContentService, prefix: []const u8) !usize {
    var buf: [4096]u8 = undefined;
    const fd = try sys.openDir(try std.mem.printSentinel(&buf, "{s}", .{service.text_dir}, 0));
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
        .refresh_interval_ns = std.math.maxInt(u64),
        .poke_interval_ns_min = 0,
        .removed_percent_max = 100,
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
        .refresh_interval_ns = std.math.maxInt(u64),
        .poke_interval_ns_min = 0,
        .removed_percent_max = 20,
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
    try testing.expectEqual(@as(usize, 0), s.index.?.docs_removed_count);
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
        fn run(tree: *TestTree, out: [:0]const u8, word: []const u8) !void {
            var xbuf: [512]u8 = undefined;
            try tree.write("word/document.xml", try std.mem.print(&xbuf,
                \\<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Minutes about the {s} project</w:t></w:r></w:p></w:body></w:document>
            , .{word}));
            _ = linux.unlink(out); // zip would add to an old one
            const r = try std.process.run(testing.allocator, testing.io, .{
                .argv = &.{ "zip", "-q", "-X", "-r", out, "." },
                .cwd = .{ .path = tree.abs },
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
        .worker = .{
            .thread_id = std.Thread.getCurrentId(),
            .retry_arena = .init(testing.allocator),
        },
    };
    defer s.worker.retry_arena.deinit();
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
    try testing.expectEqual(@as(usize, 1), s.worker.retry.len);
    try testing.expectEqualStrings(pdf, s.worker.retry[0].path);
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
    try testing.expectEqual(@as(usize, 0), s.worker.retry.len);
}
