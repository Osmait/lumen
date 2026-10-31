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
const paths = @import("paths.zig");
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

gpa: std.mem.Allocator,
io: Io,
root: []const u8,
cache_path: [:0]u8,
text_dir: []u8,
search_pool: *Pool,
build_pool: *Pool,
options: Options,
lock: Io.RwLock = .init,
index: ?content.Index = null,
stop: std.atomic.Value(bool) = .init(false),
wake: std.atomic.Value(u32) = .init(0),
thread: ?std.Thread = null,
/// Written by the service thread, read by any thread (`status`).
counters: Counters = .{},
/// The service thread's own state, read and written without the lock.
worker: Worker,

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
    /// of CPU for 49 k). When it is null, every check lists.
    names: ?*Service = null,
    /// Listed at least this often anyway (a .gitignore edited in place
    /// changes what is listed without a name change).
    list_interval_ns: u64 = 30 * 60 * std.time.ns_per_s,
};

const extracted_bytes_max = content.extracted_bytes_max;
/// `readText` reads a file this much at a time, counting lines as it goes.
const text_read_bytes = 16 * 1024;

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
    check_ns_last: std.atomic.Value(u64) = .init(0),
    list_ns_last: std.atomic.Value(u64) = .init(0),
    /// The last check that looked at indexed files only.
    stat_ns_last: std.atomic.Value(u64) = .init(0),
    build_ns_last: std.atomic.Value(u64) = .init(0),
    extract_ns_last: std.atomic.Value(u64) = .init(0),
};

/// State only the service thread reads or writes, so it needs no lock and no
/// atomics. Every function that touches it asserts the thread
/// (`assertWorkerThread`).
const Worker = struct {
    /// The service thread, set by `run` before its first check.
    thread_id: ?std.Thread.Id = null,
    /// `names.nameChanges()` when files were last listed.
    listed_name_changes: ?u64 = null,
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
    options: Options,
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
        .options = options,
        .worker = .{ .retry_arena = .init(gpa) },
    };
    // Without it, extracted text is not cached: each document is extracted
    // again when it is needed.
    sys.mkdirP(service.text_dir) catch |err| {
        log.warn("{s}: {t}, extracted text is not cached", .{ service.text_dir, err });
    };
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
    if (service.thread) |thread| thread.join();
    if (service.index) |*index| index.deinit(service.gpa);
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
    list_ns_last: u64 = 0,
    stat_ns_last: u64 = 0,
    build_ns_last: u64 = 0,
    extract_ns_last: u64 = 0,
};

pub fn status(service: *ContentService) Status {
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    const index: ?*const content.Index = if (service.index) |*index| index else null;
    return .{
        .docs = if (index) |present| present.live() else 0,
        .building = service.counters.building.load(.acquire),
        .ready = index != null,
        .extracted = if (index) |present| present.extractedCount() else 0,
        .segments = if (index) |present| present.segments_count else 0,
        .index_bytes = if (index) |present| present.bytes.len else 0,
        .builds = service.counters.builds.load(.acquire),
        .updates = service.counters.updates.load(.acquire),
        .listings = service.counters.listings.load(.acquire),
        .checks = service.counters.checks.load(.acquire),
        .extractions = service.counters.extractions.load(.acquire),
        .list_ns_last = service.counters.list_ns_last.load(.monotonic),
        .stat_ns_last = service.counters.stat_ns_last.load(.monotonic),
        .build_ns_last = service.counters.build_ns_last.load(.monotonic),
        .extract_ns_last = service.counters.extract_ns_last.load(.monotonic),
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
    const index = if (service.index) |*present| present else return;
    var matches: std.ArrayList(content.Match) = .empty;
    try content.search(
        index,
        service.gpa,
        arena,
        service.search_pool,
        query,
        .{ .limit = limit, .text_path = pathOf, .text_context = service, .stop = stop },
        &matches,
    );
    for (matches.items) |match| try out.append(arena, .{
        .path = try arena.dupe(u8, index.path(match.doc)),
        .line = match.line,
        .count = match.count,
        .snippet = match.snippet,
        .mtime = index.mtimes[match.doc],
        .size = index.sizes[match.doc],
        .extracted = index.sources[match.doc] == @backingInt(content.Source.extracted),
    });
}

/// The file holding a document's text, for verification (see PathFn).
fn pathOf(context: *anyopaque, doc: content.DocIn, path_buffer: []u8) ?[:0]const u8 {
    const service: *ContentService = @ptrCast(@alignCast(context));
    switch (doc.source) {
        .plain => return std.mem.printSentinel(path_buffer, "{s}", .{doc.path}, 0) catch null,
        .extracted => return service.textPath(path_buffer, doc),
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
    source: content.Source,
    lines: u32,
) ?[]const u8 {
    var path_buffer: paths.Buffer = undefined;
    const doc_path = std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0) catch return null;
    var text_path_buffer: paths.Buffer = undefined;
    const text_path: [:0]const u8 = if (source == .extracted) blk: {
        const doc_stat = content_list.stat(doc_path, .document) orelse return null;
        break :blk service.textPath(&text_path_buffer, .{
            .path = path,
            .mtime = mtime,
            .size = doc_stat.size,
            .source = .extracted,
        }) orelse return null;
    } else doc_path;
    const fd = sys.openRegular(text_path) catch return null;
    defer sys.close(fd);
    const text_bytes_max: usize = switch (source) {
        .plain => content.text_bytes_max,
        .extracted => extracted_bytes_max,
    };
    var text: std.ArrayList(u8) = .empty;
    var lines_seen: u32 = 0;
    while (text.items.len < text_bytes_max and lines_seen < lines) {
        text.ensureUnusedCapacity(arena, text_read_bytes) catch return null;
        const spare = text.unusedCapacitySlice();
        const bytes_wanted = @min(spare.len, text_bytes_max - text.items.len);
        const bytes_read = std.os.linux.read(fd, spare.ptr, bytes_wanted);
        if (std.os.linux.errno(bytes_read) != .SUCCESS or bytes_read == 0) break;
        lines_seen += @intCast(std.mem.count(u8, spare[0..bytes_read], "\n"));
        text.items.len += bytes_read;
    }
    return text.items;
}

/// Text of a document: the file itself, or its cached extraction.
fn textOf(
    context: *anyopaque,
    doc: content.DocIn,
    text: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    const service: *ContentService = @ptrCast(@alignCast(context));
    if (doc.source == .plain) return content.readPlain(gpa, doc.path, text);
    var path_buffer: paths.Buffer = undefined;
    const text_path = service.textPath(&path_buffer, doc) orelse return false;
    text.clearRetainingCapacity();
    const fd = sys.openRegular(text_path) catch return false;
    defer sys.close(fd);
    sys.readUpTo(gpa, fd, text, extracted_bytes_max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Part of the text is not the document's text.
        error.ReadFailed => return false,
    };
    return text.items.len > 0;
}

/// How many bytes the cached text of an extracted document has (0: none
/// yet), so that building reads no more of them at once than memory allows.
fn cachedTextBytes(context: *anyopaque, doc: content.DocIn) u64 {
    const service: *ContentService = @ptrCast(@alignCast(context));
    var path_buffer: paths.Buffer = undefined;
    const text_path = service.textPath(&path_buffer, doc) orelse return 0;
    const info = sys.info(text_path) orelse return 0;
    return info.size;
}

/// Where a document version's extracted text is cached. Keyed by size as
/// well as mtime (whole seconds): an edit within the same second reused
/// the old text, and dropping the old version's text then deleted it.
fn textPath(service: *ContentService, path_buffer: []u8, doc: content.DocIn) ?[:0]const u8 {
    var name_buffer: [64]u8 = undefined;
    const name = textName(&name_buffer, doc);
    return std.mem.printSentinel(path_buffer, "{s}/{s}", .{ service.text_dir, name }, 0) catch null;
}

fn textName(name_buffer: *[64]u8, doc: content.DocIn) []const u8 {
    // 16 + 1 + 20 + 1 + 20 + 4 bytes at most: always fits.
    return std.mem.print(
        name_buffer,
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
    var path_buffer: paths.Buffer = undefined;
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
        var text_path_buffer: paths.Buffer = undefined;
        var source_path_buffer: paths.Buffer = undefined;
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

/// Every file to index, listed by ripgrep; `name_changes` is what the name
/// index said before listing, so a change during the listing lists again
/// next time.
fn listAll(
    service: *ContentService,
    arena: std.mem.Allocator,
    name_changes: ?u64,
) ?[]content.DocIn {
    service.assertWorkerThread();
    const start_ns = sys.monotonicNs();
    const docs = content_list.list(arena, service.gpa, service.io, service.root, .{
        .documents = true,
        .stop = &service.stop,
    }) catch |err| {
        if (err != error.Canceled) log.warn("listing files: {t}", .{err});
        return null;
    };
    service.counters.list_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
    _ = service.counters.listings.fetchAdd(1, .release);
    service.worker.listed_name_changes = name_changes;
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
    var path_buffer: paths.Buffer = undefined;
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (index.removed(id)) continue;
        const doc = index.docIn(id);
        const path = std.mem.printSentinel(&path_buffer, "{s}", .{doc.path}, 0) catch continue;
        const stat_now = content_list.stat(path, switch (doc.source) {
            .extracted => .document,
            .plain => .text,
        });
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
        const stat = content_list.stat(path, .document) orelse continue;
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
    service.counters.check_ns_last.store(sys.monotonicNs(), .release);
    // Counted when done, so `checks` going up means its result is visible.
    defer _ = service.counters.checks.fetchAdd(1, .release);
    var arena_state: std.heap.ArenaAllocator = .init(service.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name_changes = if (service.options.names) |names| names.nameChanges() else null;
    var docs: ?[]content.DocIn = null;
    var changed = service.changes(arena, name_changes, &docs) orelse return;
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
        docs = service.listAll(arena, name_changes) orelse return;
        changed = service.diff(arena, docs.?) catch return;
    }
    var start_ns = sys.monotonicNs();
    if (whole) {
        docs = service.extractMissing(arena, docs.?) orelse return;
    } else {
        changed.added = service.extractMissing(arena, changed.added) orelse return;
    }
    service.counters.extract_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
    if (service.stop.load(.acquire)) return;
    // Only documents to retry, which failed again.
    if (!whole and changed.gone.len == 0 and changed.added.len == 0) return;
    start_ns = sys.monotonicNs();
    const input: BuildInput = if (whole) .{ .whole = docs.? } else .{ .update = changed };
    const fresh = service.buildNext(input) orelse return;
    service.counters.build_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
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
    name_changes: ?u64,
    docs: *?[]content.DocIn,
) ?Diff {
    const start_ns = sys.monotonicNs();
    if (service.listingReason(name_changes, start_ns) != null) {
        docs.* = service.listAll(arena, name_changes) orelse return null;
        return service.diff(arena, docs.*.?) catch null;
    }
    const changed = service.indexedChanges(arena) catch return null;
    service.counters.stat_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
    return changed;
}

/// Why every file must be listed again rather than only the indexed ones
/// looked at.
const ListingReason = enum { no_index, names_unknown, names_changed, listing_stale };

fn listingReason(
    service: *const ContentService,
    name_changes: ?u64,
    now_ns: u64,
) ?ListingReason {
    service.assertWorkerThread();
    if (service.index == null) return .no_index;
    const name_changes_now = name_changes orelse return .names_unknown;
    const name_changes_listed = service.worker.listed_name_changes orelse return .names_unknown;
    if (name_changes_now != name_changes_listed) return .names_changed;
    const listing_age_ns = now_ns - service.worker.listed_at_ns;
    if (listing_age_ns >= service.options.list_interval_ns) return .listing_stale;
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
    if (removed_count * 100 > docs_count * service.options.removed_percent_max) return true;
    if (index.segments_count >= service.options.segments_max) return true;
    return index.bytes.len * 100 > index.bytes_live * (100 + garbage_percent_max);
}

/// What the next index is made from.
const BuildInput = union(enum) {
    /// Every document, indexed from scratch.
    whole: []const content.DocIn,
    /// The index in use, with the documents of `Diff.gone` taken out and
    /// those of `Diff.added` put in.
    update: Diff,
};

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

fn buildStrategy(service: *const ContentService, input: BuildInput) BuildStrategy {
    service.assertWorkerThread();
    if (input == .whole) return .build_whole;
    const index = &service.index.?;
    if (index.backing != .mapped) return .rewrite_file;
    if (service.worker.unsaved) return .rewrite_file;
    return .append_to_mapped_file;
}

/// The next index, from `input`. Written to the cache file as it grows and
/// served mapped (clean page cache, never the whole index in heap); an
/// update is appended to the file the index is mapped from, or the file
/// rewritten if it is not that one any more. When the file cannot be
/// written, built in memory instead. Null (logged) when it cannot be built.
fn buildNext(service: *ContentService, input: BuildInput) ?content.Index {
    service.assertWorkerThread();
    if (input == .update) assert(service.index != null);
    const reader: content.TextReader = .{
        .read = textOf,
        .context = service,
        .extracted_bytes = cachedTextBytes,
    };
    if (std.mem.findScalarLast(u8, service.cache_path, '/')) |slash| {
        // The save below fails and says so; the index is served from memory.
        sys.mkdirP(service.cache_path[0..slash]) catch |err| {
            log.warn("{s}: {t}", .{ service.cache_path[0..slash], err });
        };
    }
    const strategy = service.buildStrategy(input);
    if (service.buildNextToFile(strategy, input, reader)) |fresh| {
        if (fresh.backing == .mapped) service.worker.unsaved = false;
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
    return service.buildNextInMemory(input, reader) catch |err| {
        log.warn("building the content index: {t}", .{err});
        return null;
    };
}

fn buildNextToFile(
    service: *ContentService,
    strategy: BuildStrategy,
    input: BuildInput,
    reader: content.TextReader,
) content.FileError!content.Index {
    const gpa = service.gpa;
    const pool = service.build_pool;
    const path = service.cache_path;
    const changed = switch (input) {
        .whole => |docs| {
            assert(strategy == .build_whole);
            return content.buildFile(gpa, pool, docs, reader, path, null);
        },
        .update => |changed| changed,
    };
    const index = &service.index.?;
    switch (strategy) {
        .build_whole => unreachable,
        .append_to_mapped_file => {
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
    return content.updateFile(gpa, pool, index, changed.gone, changed.added, reader, path, null);
}

/// `buildNext` when the cache file could not be written: the next index in
/// memory, served from there until a save succeeds (`retrySave`).
fn buildNextInMemory(
    service: *ContentService,
    input: BuildInput,
    reader: content.TextReader,
) content.BuildError!content.Index {
    return switch (input) {
        .whole => |docs| content.build(service.gpa, service.build_pool, docs, reader, null),
        .update => |changed| content.update(
            service.gpa,
            service.build_pool,
            &service.index.?,
            changed.gone,
            changed.added,
            reader,
            null,
        ),
    };
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
    var path_buffer: paths.Buffer = undefined;
    for (gone) |id| {
        if (old.sources[id] != @backingInt(content.Source.extracted)) continue;
        const text_path = service.textPath(&path_buffer, old.docIn(id)) orelse continue;
        // Left behind, it is deleted by the next whole build's sweep.
        const result = std.os.linux.unlink(text_path);
        switch (std.os.linux.errno(result)) {
            .SUCCESS, .NOENT => {},
            else => |errno| log.warn("deleting {s}: {t}", .{ text_path, errno }),
        }
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
    const index = &(service.index orelse return);
    var arena_state: std.heap.ArenaAllocator = .init(service.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A name in the cache -> the name it should have.
    var keep: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (!index.extractedLive(id)) continue;
        const doc = index.docIn(id);
        var name_buffer: [64]u8 = undefined;
        const name = arena.dupe(u8, textName(&name_buffer, doc)) catch return;
        keep.put(arena, name, name) catch return;
        const old = arena.print("{x:0>16}-{d}.txt", .{
            std.hash.Wyhash.hash(0, doc.path),
            doc.mtime,
        }) catch return;
        keep.put(arena, old, name) catch return;
    }
    var text_dir_buffer: paths.Buffer = undefined;
    const text_dir = std.mem.printSentinel(&text_dir_buffer, "{s}", .{service.text_dir}, 0) catch
        return;
    const fd = sys.openDir(text_dir) catch return;
    defer sys.close(fd);
    var iterator: sys.DirIter = .{ .fd = fd };
    while (iterator.next() catch return) |entry| {
        if (entry.kind == std.os.linux.DT.DIR) continue;
        var name_buffer: [256]u8 = undefined;
        const name = std.mem.printSentinel(&name_buffer, "{s}", .{entry.name}, 0) catch continue;
        const name_wanted = keep.get(entry.name) orelse {
            // Left behind, it is tried again by the next sweep.
            const result = std.os.linux.unlinkat(fd, name, 0);
            switch (std.os.linux.errno(result)) {
                .SUCCESS, .NOENT => {},
                else => |errno| log.warn("deleting {s}/{s}: {t}", .{ text_dir, name, errno }),
            }
            continue;
        };
        if (std.mem.eql(u8, name_wanted, entry.name)) continue;
        var wanted_buffer: [64]u8 = undefined;
        const target = std.mem.printSentinel(&wanted_buffer, "{s}", .{name_wanted}, 0) catch continue;
        // Not renamed, the text is extracted again under its new name.
        const result = std.os.linux.renameat(fd, name, fd, target);
        if (std.os.linux.errno(result) != .SUCCESS) {
            log.warn("renaming {s}/{s}: {t}", .{ text_dir, name, std.os.linux.errno(result) });
        }
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
        // the thread sooner. The wait's only error is cancelation, which
        // never comes (this thread is joined, never canceled); waking early
        // for any reason is harmless, since the loop looks at `stop` and
        // the clock either way.
        const since_check_ns = sys.monotonicNs() - service.counters.check_ns_last.load(.acquire);
        const due_ns = service.options.refresh_interval_ns -| since_check_ns;
        service.io.futexWaitTimeout(u32, &service.wake.raw, seen, .{ .duration = .{
            .raw = .fromNanoseconds(@max(due_ns, std.time.ns_per_s)),
            .clock = .awake,
        } }) catch {};
        if (service.stop.load(.acquire)) return;
        const since_ns = sys.monotonicNs() - service.counters.check_ns_last.load(.acquire);
        const wake_now = service.wake.load(.acquire);
        const poked = wake_now != seen;
        seen = wake_now;
        if (since_ns >= service.options.refresh_interval_ns) {
            service.refresh();
        } else if (poked and since_ns >= service.options.poke_interval_ns_min) {
            service.refresh();
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const linux = std.os.linux;
const TestTree = sys.TestDir;

fn haveTool(name: []const u8) bool {
    const result = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ name, "--version" },
    }) catch return false;
    testing.allocator.free(result.stdout);
    testing.allocator.free(result.stderr);
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

    fn startWith(fixture: *Fixture, options: Options) !*ContentService {
        return ContentService.startWith(
            testing.allocator,
            testing.io,
            fixture.root.abs,
            fixture.cache.abs,
            .{ .search = fixture.search_pool, .build = fixture.build_pool },
            options,
        );
    }

    fn find(fixture: *Fixture, service: *ContentService, query: []const u8) ![]Hit {
        try service.search(fixture.arena_state.allocator(), query, 10, &fixture.hits);
        return fixture.hits.items;
    }
};

fn waitChecks(service: *ContentService, checks: u32) !void {
    for (0..2000) |_| {
        if (service.status().checks >= checks) return;
        sys.sleepUs(5_000);
    }
    return error.Timeout;
}

/// What the window does on open, then waits for that check to finish.
fn pokeAndWait(service: *ContentService) !void {
    const checks_before = service.status().checks;
    service.poke();
    try waitChecks(service, checks_before + 1);
}

/// Moves a file's mtime away from "now": the index compares whole seconds.
fn setMtime(path: [:0]const u8, mtime_s: i64) !void {
    const time: linux.timespec = .{ .sec = mtime_s, .nsec = 0 };
    const times = [2]linux.timespec{ time, time };
    const result = linux.utimensat(linux.AT.FDCWD, path, &times, 0);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
}

/// Files in the text cache whose name starts with `prefix`.
fn countText(service: *ContentService, prefix: []const u8) !usize {
    var text_dir_buffer: paths.Buffer = undefined;
    const text_dir = try std.mem.printSentinel(&text_dir_buffer, "{s}", .{service.text_dir}, 0);
    const fd = try sys.openDir(text_dir);
    defer sys.close(fd);
    var iterator: sys.DirIter = .{ .fd = fd };
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        count += @intFromBool(std.mem.startsWith(u8, entry.name, prefix));
    }
    return count;
}

test "content service: finds, follows edits and deletions, rebuilds only on change, reuses the saved index" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.root.write("notes/alpha.txt", "the quick zanzibar fox\n");
    try fixture.root.write("other.md", "unrelated words here\n");

    {
        const service = try fixture.start();
        defer service.shutdown();
        try waitChecks(service, 1);
        var status_now = service.status();
        try testing.expect(status_now.ready);
        try testing.expect(!status_now.building);
        try testing.expectEqual(@as(usize, 2), status_now.docs);
        try testing.expectEqual(@as(u32, 1), status_now.builds);

        var hits = try fixture.find(service, "zanzibar");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expect(std.mem.endsWith(u8, hits[0].path, "/notes/alpha.txt"));
        try testing.expect(!hits[0].extracted);
        try testing.expectEqual(@as(u32, 1), hits[0].line);
        const text = service.readText(
            fixture.arena_state.allocator(),
            hits[0].path,
            hits[0].mtime,
            .plain,
            std.math.maxInt(u32),
        ).?;
        try testing.expectEqualStrings("the quick zanzibar fox\n", text);

        // Nothing changed: listed again, not rebuilt.
        try pokeAndWait(service);
        status_now = service.status();
        try testing.expectEqual(@as(u32, 2), status_now.checks);
        try testing.expectEqual(@as(u32, 1), status_now.builds);

        // Edited: new words found, old ones gone.
        var path_buffer: paths.Buffer = undefined;
        const alpha = try fixture.root.path(&path_buffer, "notes/alpha.txt");
        try fixture.root.write("notes/alpha.txt", "the slow kilimanjaro tortoise\n");
        const edited = sys.nowSeconds() - 100;
        try setMtime(alpha, edited);
        try pokeAndWait(service);
        try testing.expectEqual(@as(u32, 2), service.status().builds);
        try testing.expectEqual(@as(u32, 1), service.status().updates);
        hits = try fixture.find(service, "kilimanjaro");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(edited, hits[0].mtime);
        try testing.expectEqual(@as(usize, 0), (try fixture.find(service, "zanzibar")).len);

        // Deleted: out of the index.
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlink(alpha)));
        try pokeAndWait(service);
        status_now = service.status();
        try testing.expectEqual(@as(u32, 3), status_now.builds);
        try testing.expectEqual(@as(u32, 2), status_now.updates);
        try testing.expectEqual(@as(usize, 1), status_now.docs);
        try testing.expectEqual(@as(usize, 0), (try fixture.find(service, "kilimanjaro")).len);
        try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "unrelated")).len);
    }

    // Restarted on the same cache: the saved index serves at once, and the
    // start-up check finds nothing to rebuild.
    const service = try fixture.start();
    defer service.shutdown();
    try testing.expect(service.status().ready);
    try testing.expectEqual(@as(usize, 1), service.status().docs);
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "unrelated")).len);
    try waitChecks(service, 1);
    try testing.expectEqual(@as(u32, 0), service.status().builds);
}

test "content service: a cache it cannot write still serves from memory, and saves later" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.root.write("a.txt", "an unwritable cache lemur\n");
    // A directory where the index's temporary file goes: writing it fails.
    var blocker_buffer: paths.Buffer = undefined;
    const blocker = try fixture.cache.path(&blocker_buffer, "content.idx.tmp");
    try testing.expect(linux.errno(linux.mkdir(blocker, 0o700)) == .SUCCESS);
    const service = try fixture.start();
    defer service.shutdown();
    try waitChecks(service, 1);
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "lemur")).len);
    var saved_buffer: paths.Buffer = undefined;
    const saved = try fixture.cache.path(&saved_buffer, "content.idx");
    try testing.expect(!sys.exists(saved));
    // Writable again: the next check saves it, though nothing changed.
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.rmdir(blocker)));
    try pokeAndWait(service);
    try testing.expect(sys.exists(saved));
    try testing.expectEqual(@as(u32, 1), service.status().builds);
}

test "content service: with the name index, checks without name changes only look at indexed files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.root.write("a.txt", "first apricot\n");
    var names_path_buffer: paths.Buffer = undefined;
    const names_path = try fixture.cache.path(&names_path_buffer, "files.idx");
    const names = try Service.start(testing.allocator, testing.io, fixture.root.abs, names_path);
    defer names.shutdown();
    _ = try Service.waitNames(names, null);
    const service = try fixture.startWith(.{
        .refresh_interval_ns = std.math.maxInt(u64),
        .poke_interval_ns_min = 0,
        .removed_percent_max = 100,
        .names = names,
    });
    defer service.shutdown();
    try waitChecks(service, 1);
    try testing.expectEqual(@as(u32, 1), service.status().listings);

    // Edited in place (no name change): seen without listing.
    var path_buffer: paths.Buffer = undefined;
    try fixture.root.write("a.txt", "second banana\n");
    try setMtime(try fixture.root.path(&path_buffer, "a.txt"), sys.nowSeconds() - 100);
    try pokeAndWait(service);
    var status_now = service.status();
    try testing.expectEqual(@as(u32, 1), status_now.listings);
    try testing.expectEqual(@as(u32, 1), status_now.updates);
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "banana")).len);
    try testing.expectEqual(@as(usize, 0), (try fixture.find(service, "apricot")).len);

    // A new file is a name change: the next check lists.
    const before = names.nameChanges().?;
    try fixture.root.write("b.txt", "third cherry\n");
    _ = try Service.waitNames(names, before);
    try pokeAndWait(service);
    status_now = service.status();
    try testing.expectEqual(@as(u32, 2), status_now.listings);
    try testing.expectEqual(@as(usize, 2), status_now.docs);
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "cherry")).len);
}

test "content service: rebuilt whole once removed versions pile up" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (0..10) |i| {
        var name_buffer: [32]u8 = undefined;
        try fixture.root.write(try std.mem.print(&name_buffer, "n{d}.txt", .{i}), "plain words\n");
    }
    const service = try fixture.startWith(.{
        .refresh_interval_ns = std.math.maxInt(u64),
        .poke_interval_ns_min = 0,
        .removed_percent_max = 20,
    });
    defer service.shutdown();
    try waitChecks(service, 1);
    var path_buffer: paths.Buffer = undefined;
    // One of ten edited: updated.
    try fixture.root.write("n0.txt", "first edit marmalade\n");
    try setMtime(try fixture.root.path(&path_buffer, "n0.txt"), sys.nowSeconds() - 100);
    try pokeAndWait(service);
    try testing.expectEqual(@as(u32, 1), service.status().updates);
    // Three more: 4 removed of 14 is past 20 %, so rebuilt whole.
    for (1..4) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.mem.print(&name_buffer, "n{d}.txt", .{i});
        try fixture.root.write(name, "later edit quokka\n");
        try setMtime(try fixture.root.path(&path_buffer, name), sys.nowSeconds() - 50);
    }
    try pokeAndWait(service);
    const status_now = service.status();
    try testing.expectEqual(@as(u32, 3), status_now.builds);
    try testing.expectEqual(@as(u32, 1), status_now.updates);
    try testing.expectEqual(@as(usize, 10), status_now.docs);
    try testing.expectEqual(@as(usize, 3), (try fixture.find(service, "quokka")).len);
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "marmalade")).len);
    // Whole again: nothing removed is left.
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    try testing.expectEqual(@as(usize, 0), service.index.?.docs_removed_count);
}

test "content service: Office documents are extracted once per version" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    if (!haveTool("zip") or !haveTool("unzip")) return error.SkipZigTest;
    // Staged outside the root, so document.xml is not indexed as plain text.
    var stage = try TestTree.init();
    defer stage.deinit();
    try stage.write("[Content_Types].xml", "<?xml version=\"1.0\"?><Types/>");

    var path_buffer: paths.Buffer = undefined;
    const report = try fixture.root.path(&path_buffer, "docs/report.docx");
    try fixture.root.mkdir("docs");
    const zipDoc = struct {
        fn run(tree: *TestTree, out: [:0]const u8, word: []const u8) !void {
            var xml_buffer: [512]u8 = undefined;
            try tree.write("word/document.xml", try std.mem.print(&xml_buffer,
                \\<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Minutes about the {s} project</w:t></w:r></w:p></w:body></w:document>
            , .{word}));
            // Zip would add to an old one.
            const unlinked = linux.errno(linux.unlink(out));
            try testing.expect(unlinked == .SUCCESS or unlinked == .NOENT);
            const result = try std.process.run(testing.allocator, testing.io, .{
                .argv = &.{ "zip", "-q", "-X", "-r", out, "." },
                .cwd = .{ .path = tree.abs },
            });
            testing.allocator.free(result.stdout);
            testing.allocator.free(result.stderr);
            try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        }
    }.run;
    try zipDoc(&stage, report, "wombat");
    try setMtime(report, sys.nowSeconds() - 200);
    // Not a zip: extraction fails, leaving an empty text so it is not retried.
    try fixture.root.write("docs/broken.docx", "garbage, not a zip");

    var prefix_buffer: [32]u8 = undefined;
    const prefix = try std.mem.print(&prefix_buffer, "{x:0>16}-", .{std.hash.Wyhash.hash(0, report)});
    const mtime_second = sys.nowSeconds() - 100;

    {
        const service = try fixture.start();
        defer service.shutdown();
        try waitChecks(service, 1);
        var status_now = service.status();
        try testing.expectEqual(@as(usize, 2), status_now.docs);
        try testing.expectEqual(@as(usize, 2), status_now.extracted);
        try testing.expectEqual(@as(u32, 2), status_now.extractions);
        try testing.expectEqual(@as(usize, 2), try countText(service, ""));
        try testing.expectEqual(@as(usize, 1), try countText(service, prefix));

        var hits = try fixture.find(service, "wombat");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqualStrings(report, hits[0].path);
        try testing.expect(hits[0].extracted);
        const text = service.readText(
            fixture.arena_state.allocator(),
            hits[0].path,
            hits[0].mtime,
            .extracted,
            std.math.maxInt(u32),
        ).?;
        try testing.expectEqualStrings("Minutes about the wombat project", text);
        // Asked as plain text, the zip is not the text.
        const raw = service.readText(
            fixture.arena_state.allocator(),
            hits[0].path,
            hits[0].mtime,
            .plain,
            std.math.maxInt(u32),
        );
        if (raw) |zip| try testing.expect(std.mem.find(u8, zip, "wombat") == null);

        // Unchanged: neither extracted nor rebuilt again (the broken one too).
        try pokeAndWait(service);
        status_now = service.status();
        try testing.expectEqual(@as(u32, 2), status_now.extractions);
        try testing.expectEqual(@as(u32, 1), status_now.builds);

        // A new version: extracted once more, the old version's text dropped.
        try zipDoc(&stage, report, "platypus");
        try setMtime(report, mtime_second);
        try pokeAndWait(service);
        status_now = service.status();
        try testing.expectEqual(@as(u32, 3), status_now.extractions);
        try testing.expectEqual(@as(u32, 2), status_now.builds);
        try testing.expectEqual(@as(usize, 1), try countText(service, prefix));
        var name_buffer: [64]u8 = undefined;
        const name = try std.mem.print(&name_buffer, "{s}{d}-", .{ prefix, mtime_second });
        try testing.expectEqual(@as(usize, 1), try countText(service, name));
        try testing.expectEqual(@as(usize, 0), (try fixture.find(service, "wombat")).len);
        hits = try fixture.find(service, "platypus");
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expect(hits[0].extracted);

        // Edited again within the same second (the same mtime, another
        // size): the old text was reused, then the current one deleted as
        // the old version's.
        try zipDoc(&stage, report, "echidna, and a much longer sentence");
        try setMtime(report, mtime_second);
        try pokeAndWait(service);
        try testing.expectEqual(@as(u32, 4), service.status().extractions);
        try testing.expectEqual(@as(usize, 0), (try fixture.find(service, "platypus")).len);
        try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "echidna")).len);
        try testing.expectEqual(@as(usize, 1), try countText(service, prefix));
    }

    // Texts no document refers to: a version never indexed (a crash in
    // between), the old naming, a write cut short. Swept on start.
    try fixture.cache.write("text/0123456789abcdef-1700000000-99.txt", "stale");
    try fixture.cache.write("text/0123456789abcdef-1700000000.txt", "old name");
    try fixture.cache.write("text/0123456789abcdef-1-2.txt.tmp", "half");
    // And the current version's text under the naming before sizes: renamed
    // on start, not extracted again.
    var now_name_buffer: paths.Buffer = undefined;
    var old_name_buffer: paths.Buffer = undefined;
    const size = sys.info(report).?.size;
    const now_name = try std.mem.printSentinel(&now_name_buffer, "{s}/text/{s}{d}-{d}.txt", .{
        fixture.cache.abs,
        prefix,
        mtime_second,
        size,
    }, 0);
    const old_name = try std.mem.printSentinel(&old_name_buffer, "{s}/text/{s}{d}.txt", .{
        fixture.cache.abs,
        prefix,
        mtime_second,
    }, 0);
    try sys.rename(now_name, old_name);

    // Restarted: the extracted text is reused, nothing is extracted again.
    // (Its text is found once renamed: the start's sweep, then the check.)
    const service = try fixture.start();
    defer service.shutdown();
    try waitChecks(service, 1);
    try testing.expectEqual(@as(u32, 0), service.status().extractions);
    try testing.expectEqual(@as(u32, 0), service.status().builds);
    try testing.expectEqual(@as(usize, 0), try countText(service, "0123456789abcdef-"));
    // Both documents' texts stay (the broken one's is empty).
    try testing.expectEqual(@as(usize, 2), try countText(service, ""));
    try testing.expect(sys.exists(now_name));
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "echidna")).len);

    // Deleted: its text goes with it.
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlink(report)));
    try pokeAndWait(service);
    try testing.expectEqual(@as(usize, 0), try countText(service, prefix));
    try testing.expectEqual(@as(usize, 1), service.status().docs);
}

test "content service: a document whose extraction failed in passing is left out, and retried" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("a.pdf", "not really a pdf");
    try tree.write("b.txt", "plain words here");
    var path_buffer: paths.Buffer = undefined;
    const pdf = try tree.path(&path_buffer, "a.pdf");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pool = try Pool.create(testing.allocator, testing.io, 0);
    defer pool.destroy();
    // Only what retrying touches: no thread, no cache.
    var service: ContentService = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .root = tree.abs,
        .cache_path = undefined,
        .text_dir = undefined,
        .search_pool = pool,
        .build_pool = pool,
        .options = .{},
        .worker = .{
            .thread_id = std.Thread.getCurrentId(),
            .retry_arena = .init(testing.allocator),
        },
    };
    defer service.worker.retry_arena.deinit();
    const docs = content_list.list(arena, testing.allocator, testing.io, tree.abs, .{
        .documents = true,
    }) catch |err| switch (err) {
        // Without ripgrep.
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqualStrings(pdf, docs[0].path);

    // Timed out: left out (indexed, it stayed textless until it changed).
    const kept = service.leaveOut(arena, docs, &.{0}, &[_]?anyerror{error.Timeout}).?;
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(std.mem.endsWith(u8, kept[0].path, "/b.txt"));
    try testing.expectEqual(@as(usize, 1), service.worker.retry.len);
    try testing.expectEqualStrings(pdf, service.worker.retry[0].path);
    const reader: content.TextReader = .{ .read = textOf, .context = &service };
    service.index = try content.build(testing.allocator, pool, kept, reader, null);
    defer service.index.?.deinit(testing.allocator);

    // The next check, though it lists nothing, tries it again.
    const changes_found = try service.indexedChanges(arena);
    try testing.expectEqual(@as(usize, 0), changes_found.gone.len);
    try testing.expectEqual(@as(usize, 1), changes_found.added.len);
    try testing.expectEqualStrings(pdf, changes_found.added[0].path);
    try testing.expectEqual(content.Source.extracted, changes_found.added[0].source);
    // Extracted this time: indexed, nothing left to retry.
    const all = service.leaveOut(arena, changes_found.added, &.{0}, &[_]?anyerror{null}).?;
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqual(@as(usize, 0), service.worker.retry.len);
}
