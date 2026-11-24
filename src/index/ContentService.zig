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
//! kept in a cache (`TextCache.zig`): extraction (a child process per
//! file) happens once per version of a document.

const std = @import("std");
const paths = @import("paths.zig");
const assert = std.debug.assert;
const Io = std.Io;
const content = @import("content.zig");
const content_list = @import("content_list.zig");
const extract = @import("extract.zig");
const TextCache = @import("TextCache.zig");
const Pool = @import("Pool.zig");
const Service = @import("Service.zig");
const sys = @import("os");

const log = std.log.scoped(.content);

const ContentService = @This();

gpa: std.mem.Allocator,
io: Io,
root: []const u8,
cache_path: [:0]u8,
text_cache: TextCache,
search_pool: *Pool,
build_pool: *Pool,
options: Options,
lock: Io.RwLock = .init,
/// The index in use, swapped under `lock`. A search takes a reference
/// (`Shared.acquire`) and lets the lock go before it reads any file: the
/// swap no longer waits for up to `candidates_verified_max` reads, nor
/// does every reader queued behind it (`status`, the next query).
index: ?*Shared = null,
/// Incremented each time `index` is published (0 while none is ready).
version: std.atomic.Value(u64) = .init(0),
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
    /// Called on the worker thread right after a new index is published, so
    /// the UI can re-run a visible query against the newer version.
    on_published: ?OnPublished = null,
    /// Minimum backoff between extraction retries for transient failures (doubles per try).
    extract_retry_backoff_ns: u64 = 5 * 60 * std.time.ns_per_s,
    /// Backoff before retrying extractions after ENOSPC/EACCES writing the text cache.
    cache_write_backoff_ns: u64 = 10 * 60 * std.time.ns_per_s,
};

pub const OnPublished = struct {
    callback: *const fn (?*anyopaque) void,
    context: ?*anyopaque = null,
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

/// Maximum extraction attempts for deterministic per-document Timeout / ToolKilled
/// before caching an empty marker until the document changes.
const extract_retries_max: u8 = 3;

const RetryEntry = struct {
    doc: content.DocIn,
    attempts: u8,
    next_retry_ns: u64,
};

/// State only the service thread reads or writes, so it needs no lock and no
/// atomics. Every function that touches it asserts the thread
/// (`assertWorkerThread`).
const Worker = struct {
    /// The service thread, set by `run` before its first check.
    thread_id: ?std.Thread.Id = null,
    /// Mount points below the root that can hang a call (NFS, sshfs, FUSE),
    /// read at the start of each check (`refresh`), in its arena: documents
    /// there are neither listed nor stat'ed, so they leave the index and
    /// are never read or extracted.
    slow_mounts: []const []const u8 = &.{},
    /// `names.nameChanges()` when files were last listed.
    listed_name_changes: ?u64 = null,
    listed_at_ns: u64 = 0,
    /// The index in use could not be saved: retried on the next check even
    /// if nothing changed.
    unsaved: bool = false,
    /// Documents whose extraction failed in passing (a timeout, a missing
    /// tool, memory): kept out of the index with attempt counts and exponential
    /// backoff so a pathological file does not thrash forever. In `retry_arena`.
    retry: []RetryEntry = &.{},
    retry_arena: std.heap.ArenaAllocator,
    /// Monotonic deadline until which cache writes reported ENOSPC/EACCES.
    cache_unwritable_until_ns: u64 = 0,
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
    var text_cache: TextCache = try .init(gpa, cache_dir);
    errdefer text_cache.deinit(gpa);
    service.* = .{
        .gpa = gpa,
        .io = io,
        .root = root_copy,
        .cache_path = cache_path,
        .text_cache = text_cache,
        .search_pool = pools.search,
        .build_pool = pools.build,
        .options = options,
        .worker = .{ .retry_arena = .init(gpa) },
    };
    // Older versions made it 0755: the cache holds the text of the user's
    // documents, so close it before anything else.
    sys.makePrivate(cache_dir);
    // Absent or unreadable: built from scratch by the first refresh.
    if (content.Index.open(service.cache_path)) |opened| {
        // Out of memory: built from scratch, as if there were none.
        if (Shared.create(gpa, opened, 1) catch null) |shared| {
            service.index = shared;
            service.version.store(1, .release);
        }
    } else |_| {}
    errdefer if (service.index) |shared| shared.release();
    service.thread = try std.Thread.spawn(.{}, run, .{service});
    // A thread without a name works the same; only `top` shows it.
    service.thread.?.setName(io, "lm-content") catch {};
    return service;
}

pub fn shutdown(service: *ContentService) void {
    service.stop.store(true, .release);
    service.poke();
    if (service.thread) |thread| thread.join();
    if (service.index) |shared| shared.release();
    service.worker.retry_arena.deinit();
    service.gpa.free(service.root);
    service.gpa.free(service.cache_path);
    service.text_cache.deinit(service.gpa);
    service.gpa.destroy(service);
}

/// An index and the references to it: the service's own, and one per
/// search reading it. The last one let go frees it.
const Shared = struct {
    index: content.Index,
    version: std.atomic.Value(u64),
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),

    /// Takes `index`; on error it is freed.
    fn create(
        gpa: std.mem.Allocator,
        index: content.Index,
        version: u64,
    ) std.mem.Allocator.Error!*Shared {
        const shared = gpa.create(Shared) catch |err| {
            var dropped = index;
            dropped.deinit(gpa);
            return err;
        };
        shared.* = .{ .index = index, .version = .init(version), .gpa = gpa };
        return shared;
    }

    /// Under `ContentService.lock` (shared at least): the index cannot be
    /// swapped and let go meanwhile.
    fn acquire(shared: *Shared) void {
        const before = shared.refs.fetchAdd(1, .monotonic);
        assert(before > 0);
    }

    fn release(shared: *Shared) void {
        const before = shared.refs.fetchSub(1, .acq_rel);
        assert(before > 0);
        if (before != 1) return;
        const gpa = shared.gpa;
        shared.index.deinit(gpa);
        gpa.destroy(shared);
    }
};

/// The index in use, for the service thread (the only one that swaps it)
/// or under `lock`.
fn current(service: *const ContentService) ?*content.Index {
    const shared = service.index orelse return null;
    return &shared.index;
}

/// The current index version (0 when no index is ready yet). Thread-safe.
pub fn indexVersion(service: *const ContentService) u64 {
    return service.version.load(.acquire);
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
    const index: ?*const content.Index = service.current();
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
    _ = try service.searchUntil(arena, query, limit, null, out);
}

/// `search`, cut short once `stop` is set (a newer query waits): reading
/// files to verify them stops at the next one, and the hits found so far
/// are returned. Until then it holds the search pool and the index.
/// Returns the index version searched (0 when no index is ready yet).
pub fn searchUntil(
    service: *ContentService,
    arena: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    stop: ?*const std.atomic.Value(bool),
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!u64 {
    return service.searchUntilWith(arena, query, limit, stop, null, out);
}

/// Like `searchUntil`, also reporting whether `candidates_budget_max` stopped
/// verification while matching or higher-scoring candidates may still remain.
pub fn searchUntilWith(
    service: *ContentService,
    arena: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    stop: ?*const std.atomic.Value(bool),
    truncated_out: ?*bool,
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!u64 {
    if (truncated_out) |flag| flag.* = false;
    out.clearRetainingCapacity();
    // A reference, not the lock, keeps the index while files are read.
    const shared = blk: {
        service.lock.lockSharedUncancelable(service.io);
        defer service.lock.unlockShared(service.io);
        const shared = service.index orelse return 0;
        shared.acquire();
        break :blk shared;
    };
    defer shared.release();
    const index = &shared.index;
    var matches: std.ArrayList(content.Match) = .empty;
    try content.search(
        index,
        service.gpa,
        arena,
        service.search_pool,
        query,
        .{
            .limit = limit,
            .text_path = pathOf,
            .text_context = service,
            .stop = stop,
            .truncated = truncated_out,
        },
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
    return shared.version.load(.acquire);
}

/// The file holding a document's text, for verification (see PathFn).
fn pathOf(context: *anyopaque, doc: content.DocIn, path_buffer: []u8) ?[:0]const u8 {
    const service: *ContentService = @ptrCast(@alignCast(context));
    switch (doc.source) {
        .plain => return std.mem.printSentinel(path_buffer, "{s}", .{doc.path}, 0) catch null,
        .extracted => return service.text_cache.path(path_buffer, doc),
    }
}

/// The first `lines` lines of a hit's text (for the preview), in `arena`;
/// null if it cannot be read. Reads no further than that: the preview runs
/// on the UI thread, and a match near the top of a 4 MB extraction needs a
/// few KB of it. `mtime` and `size` are the document's as the hit has them
/// (`Hit.mtime`, `Hit.size`): they key the text cache, and taking them from
/// the hit spares the UI thread a stat.
pub fn readText(
    service: *ContentService,
    arena: std.mem.Allocator,
    path: []const u8,
    mtime: i64,
    size: u64,
    source: content.Source,
    lines: u32,
) ?[]const u8 {
    var path_buffer: paths.Buffer = undefined;
    const doc_path = std.mem.printSentinel(&path_buffer, "{s}", .{path}, 0) catch return null;
    var text_path_buffer: paths.Buffer = undefined;
    const text_path: [:0]const u8 = if (source == .extracted)
        service.text_cache.path(&text_path_buffer, .{
            .path = path,
            .mtime = mtime,
            .size = size,
            .source = .extracted,
        }) orelse return null
    else
        doc_path;
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
        switch (std.os.linux.errno(bytes_read)) {
            .SUCCESS => if (bytes_read == 0) break,
            .INTR => continue,
            else => break,
        }
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
    return switch (doc.source) {
        .plain => content.readPlain(gpa, doc.path, text),
        .extracted => service.text_cache.read(gpa, doc, text),
    };
}

/// How many bytes the cached text of an extracted document has (0: none
/// yet), so that building reads no more of them at once than memory allows.
fn cachedTextBytes(context: *anyopaque, doc: content.DocIn) u64 {
    const service: *ContentService = @ptrCast(@alignCast(context));
    return service.text_cache.size(doc);
}

/// What `extractMissing` leaves: the documents to index, and those to try
/// again at the next check.
const ExtractOutcome = struct {
    docs: []content.DocIn,
    retry: []RetryEntry,
};

fn priorRetry(service: *const ContentService, doc: content.DocIn) ?RetryEntry {
    for (service.worker.retry) |entry| {
        if (entry.doc.mtime == doc.mtime and
            entry.doc.size == doc.size and
            std.mem.eql(u8, entry.doc.path, doc.path))
        {
            return entry;
        }
    }
    return null;
}

/// Extracts what is missing from the text cache, on the background pool
/// (a PDF takes 10-40 ms, a whole book up to ~0.7 s). Documents that cannot
/// be extracted (a corrupt file, or repeatedly hitting Timeout/ToolKilled)
/// get an empty cache file so they do not thrash every refresh. Unwritable
/// caches (ENOSPC/EACCES) pause extraction for `cache_write_backoff_ns`.
fn extractMissing(
    service: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
) ?ExtractOutcome {
    const now_ns = sys.monotonicNs();
    const cache_blocked = now_ns < service.worker.cache_unwritable_until_ns;
    var missing: std.ArrayList(usize) = .empty;
    var prev_attempts: std.ArrayList(u8) = .empty;
    var deferred: std.ArrayList(RetryEntry) = .empty;
    var deferred_indices: std.ArrayList(usize) = .empty;
    var path_buffer: paths.Buffer = undefined;
    for (docs, 0..) |doc, doc_index| {
        if (doc.source != .extracted) continue;
        const text_path = service.text_cache.path(&path_buffer, doc) orelse continue;
        if (sys.exists(text_path)) continue;
        const prior = service.priorRetry(doc);
        const attempts: u8 = if (prior) |p| p.attempts else 0;
        const waiting_backoff = prior != null and now_ns < prior.?.next_retry_ns;
        if (cache_blocked or waiting_backoff) {
            const wait_until = if (waiting_backoff)
                prior.?.next_retry_ns
            else
                service.worker.cache_unwritable_until_ns;
            deferred.append(arena, .{
                .doc = doc,
                .attempts = attempts,
                .next_retry_ns = wait_until,
            }) catch {
                log.warn("extracting documents: out of memory", .{});
                return null;
            };
            deferred_indices.append(arena, doc_index) catch {
                log.warn("extracting documents: out of memory", .{});
                return null;
            };
            continue;
        }
        missing.append(arena, doc_index) catch {
            log.warn("extracting documents: out of memory", .{});
            return null;
        };
        prev_attempts.append(arena, attempts) catch {
            log.warn("extracting documents: out of memory", .{});
            return null;
        };
    }
    if (missing.items.len == 0 and deferred.items.len == 0) {
        return .{ .docs = docs, .retry = &.{} };
    }
    const failed = arena.alloc(?ExtractContext.Failure, missing.items.len) catch {
        log.warn("extracting documents: out of memory", .{});
        return null;
    };
    @memset(failed, null);
    if (missing.items.len > 0) {
        var context: ExtractContext = .{
            .service = service,
            .docs = docs,
            .missing = missing.items,
            .failed = failed,
        };
        service.build_pool.run(missing.items.len, &context, ExtractContext.extractOne);
    }
    return service.leaveOut(
        arena,
        docs,
        missing.items,
        prev_attempts.items,
        failed,
        deferred.items,
        deferred_indices.items,
        now_ns,
    );
}

/// What the build pool's workers share while `extractMissing` runs.
const ExtractContext = struct {
    const Failure = struct { err: anyerror, cache_write: bool = false };

    service: *ContentService,
    docs: []const content.DocIn,
    /// Positions in `docs` of the documents to extract.
    missing: []const usize,
    /// One per `missing`: set when extracting or caching failed.
    failed: []?Failure,
    cache_unwritable: std.atomic.Value(bool) = .init(false),

    fn extractOne(context: *ExtractContext, missing_index: usize) void {
        const service = context.service;
        if (service.stop.load(.acquire)) return;
        if (context.cache_unwritable.load(.acquire)) {
            context.failed[missing_index] = .{ .err = error.NoSpace, .cache_write = true };
            return;
        }
        const doc = context.docs[context.missing[missing_index]];
        var text_path_buffer: paths.Buffer = undefined;
        var source_path_buffer: paths.Buffer = undefined;
        const text_path = service.text_cache.path(&text_path_buffer, doc) orelse return;
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
            error.ToolFailed, error.NotRegular, error.NotFound => "",
            else => {
                context.failed[missing_index] = .{ .err = err };
                return;
            },
        };
        defer if (text.len > 0) service.gpa.free(text);
        sys.writeFileAtomic(text_path, text) catch |err| {
            log.warn("caching text of {s}: {t}", .{ doc.path, err });
            if (err == error.NoSpace or err == error.Access) {
                context.cache_unwritable.store(true, .release);
            }
            context.failed[missing_index] = .{ .err = err, .cache_write = true };
            return;
        };
        _ = service.counters.extractions.fetchAdd(1, .release);
    }
};

/// Drops failed/deferred documents from `docs` (unless permanently marked
/// empty after `extract_retries_max`) and produces updated `RetryEntry` rows.
fn leaveOut(
    service: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
    missing: []const usize,
    prev_attempts: []const u8,
    failed: []const ?ExtractContext.Failure,
    deferred: []const RetryEntry,
    deferred_indices: []const usize,
    now_ns: u64,
) ?ExtractOutcome {
    service.assertWorkerThread();
    assert(missing.len == failed.len);
    assert(missing.len == prev_attempts.len);
    assert(deferred.len == deferred_indices.len);
    const dropped = arena.alloc(bool, docs.len) catch {
        logOutOfMemory("setting documents aside to retry");
        return null;
    };
    @memset(dropped, false);

    var retry: std.ArrayList(RetryEntry) = .empty;
    var failed_first: ?usize = null;
    var failed_new_count: usize = 0;
    var cache_path_buffer: paths.Buffer = undefined;

    for (failed, missing, prev_attempts, 0..) |maybe_failure, doc_index, prev, missing_index| {
        const failure = maybe_failure orelse continue;
        const doc = docs[doc_index];
        if (failure.cache_write) {
            if (failure.err == error.NoSpace or failure.err == error.Access) {
                service.worker.cache_unwritable_until_ns =
                    now_ns +| service.options.cache_write_backoff_ns;
            }
            dropped[doc_index] = true;
            failed_new_count += 1;
            if (failed_first == null) failed_first = missing_index;
            retry.append(arena, .{
                .doc = doc,
                .attempts = prev,
                .next_retry_ns = now_ns +| service.options.cache_write_backoff_ns,
            }) catch {
                logOutOfMemory("setting documents aside to retry");
                return null;
            };
            continue;
        }
        const next_attempts: u8 = prev +| 1;
        const permanent_tool_fail =
            (failure.err == error.Timeout or failure.err == error.ToolKilled) and
            next_attempts >= extract_retries_max;
        if (permanent_tool_fail) {
            if (service.text_cache.path(&cache_path_buffer, doc)) |text_path| {
                if (sys.writeFileAtomic(text_path, "")) |_| {
                    log.warn(
                        "extraction of {s} failed {d} times ({t}); caching empty until modified",
                        .{ doc.path, next_attempts, failure.err },
                    );
                    continue;
                } else |write_err| {
                    if (write_err == error.NoSpace or write_err == error.Access) {
                        service.worker.cache_unwritable_until_ns =
                            now_ns +| service.options.cache_write_backoff_ns;
                    }
                }
            }
        }
        dropped[doc_index] = true;
        failed_new_count += 1;
        if (failed_first == null) failed_first = missing_index;
        const shift: u3 = @intCast(@min(next_attempts - 1, 4));
        const delay = service.options.extract_retry_backoff_ns <<| shift;
        retry.append(arena, .{
            .doc = doc,
            .attempts = next_attempts,
            .next_retry_ns = now_ns +| delay,
        }) catch {
            logOutOfMemory("setting documents aside to retry");
            return null;
        };
    }

    if (failed_first) |first| {
        if (failed_new_count + deferred.len != service.worker.retry.len) {
            log.warn(
                "extracting {d} documents failed for now ({s}: {t}), will retry",
                .{ failed_new_count, docs[missing[first]].path, failed[first].?.err },
            );
        }
    }

    for (deferred, deferred_indices) |entry, doc_index| {
        dropped[doc_index] = true;
        retry.append(arena, entry) catch {
            logOutOfMemory("setting documents aside to retry");
            return null;
        };
    }

    var kept_count: usize = 0;
    for (docs, dropped) |doc, doc_dropped| {
        if (doc_dropped) continue;
        docs[kept_count] = doc;
        kept_count += 1;
    }
    return .{ .docs = docs[0..kept_count], .retry = retry.items };
}

/// Persists `retry` in `worker.retry_arena` once a refresh finishes. Copied
/// into a new arena first: out of memory, the list before stays.
fn commitRetry(service: *ContentService, retry: []const RetryEntry) void {
    service.assertWorkerThread();
    var fresh_arena: std.heap.ArenaAllocator = .init(service.gpa);
    const copy = copyRetries(fresh_arena.allocator(), retry) catch {
        fresh_arena.deinit();
        logOutOfMemory("keeping the documents to retry");
        return;
    };
    service.worker.retry_arena.deinit();
    service.worker.retry_arena = fresh_arena;
    service.worker.retry = copy;
}

fn copyRetries(
    arena: std.mem.Allocator,
    entries: []const RetryEntry,
) std.mem.Allocator.Error![]RetryEntry {
    const copy = try arena.alloc(RetryEntry, entries.len);
    for (entries, copy) |entry, *dst| {
        dst.* = entry;
        dst.doc.path = try arena.dupe(u8, entry.doc.path);
    }
    return copy;
}

fn logOutOfMemory(what: []const u8) void {
    log.warn("{s}: out of memory, tried again at the next check", .{what});
}

/// How the listed documents differ from the index: ids whose document
/// changed or is gone, documents to index (changed or new), and indexed
/// documents whose cached extracted text vanished and needs re-extraction.
const Diff = struct {
    gone: []u32,
    added: []content.DocIn,
    reextract: []content.DocIn = &.{},
};

/// Called on the service thread, the only one that replaces the index, so
/// it can read it without the lock.
fn diff(
    service: *ContentService,
    arena: std.mem.Allocator,
    docs: []content.DocIn,
) std.mem.Allocator.Error!Diff {
    service.assertWorkerThread();
    const index = service.current() orelse return .{ .gone = &.{}, .added = docs };
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
    var reextract: std.ArrayList(content.DocIn) = .empty;
    for (docs) |doc| {
        if (ids.get(doc.path)) |id| {
            seen[id] = true;
            if (unchanged(index, id, doc)) {
                if (doc.source == .extracted and !service.textCached(doc)) {
                    try reextract.append(arena, doc);
                }
                continue;
            }
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
    return .{ .gone = gone.items, .added = added.items, .reextract = reextract.items };
}

/// Whether `doc` is the version of document `id` that the index holds.
fn unchanged(index: *const content.Index, id: u32, doc: content.DocIn) bool {
    if (index.mtimes[id] != doc.mtime) return false;
    if (index.sizes[id] != doc.size) return false;
    return index.sources[id] == @backingInt(doc.source);
}

const ListingStamp = struct {
    name_changes: ?u64,
    listed_at_ns: u64,
};

/// Every file to index, listed by ripgrep; `name_changes` is what the name
/// index said before listing, so a change during the listing lists again
/// next time. Recorded in `listed` and committed to `worker` only once the
/// refresh succeeds.
fn listAll(
    service: *ContentService,
    arena: std.mem.Allocator,
    name_changes: ?u64,
    listed: *?ListingStamp,
) ?[]content.DocIn {
    service.assertWorkerThread();
    const start_ns = sys.monotonicNs();
    const docs = content_list.list(arena, service.gpa, service.io, service.root, .{
        .documents = true,
        .stop = &service.stop,
        .not_under = service.worker.slow_mounts,
    }) catch |err| {
        if (err != error.Canceled) log.warn("listing files: {t}", .{err});
        return null;
    };
    service.counters.list_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
    _ = service.counters.listings.fetchAdd(1, .release);
    listed.* = .{ .name_changes = name_changes, .listed_at_ns = start_ns };
    return docs;
}

fn commitListing(service: *ContentService, listed: ?ListingStamp) void {
    service.assertWorkerThread();
    const stamp = listed orelse return;
    service.worker.listed_name_changes = stamp.name_changes;
    service.worker.listed_at_ns = stamp.listed_at_ns;
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
    const index = service.current().?;
    var gone: std.ArrayList(u32) = .empty;
    var added: std.ArrayList(content.DocIn) = .empty;
    var reextract: std.ArrayList(content.DocIn) = .empty;
    var path_buffer: paths.Buffer = undefined;
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (index.removed(id)) continue;
        const doc = index.docIn(id);
        // On a mount that can hang: out of the index, without a stat.
        if (content_list.underAny(doc.path, service.worker.slow_mounts)) {
            try gone.append(arena, id);
            continue;
        }
        const path = std.mem.printSentinel(&path_buffer, "{s}", .{doc.path}, 0) catch continue;
        const stat_now = content_list.stat(path, switch (doc.source) {
            .extracted => .document,
            .plain => .text,
        });
        if (stat_now) |stat| {
            const same = stat.mtime == doc.mtime and stat.size == doc.size;
            // Its extracted text gone from the cache (a cleaner emptied it):
            // re-extract into the cache without rebuilding the index.
            if (same) {
                if (doc.source == .extracted and !service.textCached(doc)) {
                    try reextract.append(arena, .{
                        .path = try arena.dupe(u8, doc.path),
                        .mtime = doc.mtime,
                        .size = doc.size,
                        .source = doc.source,
                    });
                }
                continue;
            }
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
    // Not in the index (`extractMissing` left them out): as they are now,
    // respecting retry backoff unless the file changed on disk.
    const now_ns = sys.monotonicNs();
    for (service.worker.retry) |entry| {
        const doc = entry.doc;
        if (content_list.underAny(doc.path, service.worker.slow_mounts)) continue;
        const path = std.mem.printSentinel(&path_buffer, "{s}", .{doc.path}, 0) catch continue;
        const stat = content_list.stat(path, .document) orelse continue;
        const same_version = stat.mtime == doc.mtime and stat.size == doc.size;
        if (same_version and (now_ns < entry.next_retry_ns or
            now_ns < service.worker.cache_unwritable_until_ns))
        {
            continue;
        }
        try added.append(arena, .{
            .path = try arena.dupe(u8, doc.path),
            .mtime = stat.mtime,
            .size = stat.size,
            .source = .extracted,
        });
    }
    return .{ .gone = gone.items, .added = added.items, .reextract = reextract.items };
}

/// Whether the extracted text of `doc` is in the text cache.
fn textCached(service: *ContentService, doc: content.DocIn) bool {
    var text_path_buffer: paths.Buffer = undefined;
    const text_path = service.text_cache.path(&text_path_buffer, doc) orelse return false;
    return sys.exists(text_path);
}

/// The service thread is the only one that replaces the index and the only
/// one that touches `worker`: what it does without the lock relies on that.
fn assertWorkerThread(service: *const ContentService) void {
    assert(service.worker.thread_id.? == std.Thread.getCurrentId());
}

/// Mount points strictly below `root` that can hang a call, in `arena`;
/// none when they cannot be read. A root that is such a mount itself (a
/// home on NFS) is still indexed: leaving it out would leave nothing.
fn slowMountsBelow(arena: std.mem.Allocator, root: []const u8) []const []const u8 {
    const mounts = sys.slowMounts(arena, root) catch return &.{};
    var below: std.ArrayList([]const u8) = .empty;
    for (mounts) |mount| {
        if (std.mem.eql(
            u8,
            std.mem.trimEnd(u8, mount, "/"),
            std.mem.trimEnd(u8, root, "/"),
        )) continue;
        below.append(arena, mount) catch return below.items;
    }
    return below.items;
}

fn refresh(service: *ContentService) void {
    service.assertWorkerThread();
    service.counters.check_ns_last.store(sys.monotonicNs(), .release);
    // Counted when done, so `checks` going up means its result is visible.
    defer _ = service.counters.checks.fetchAdd(1, .release);
    var arena_state: std.heap.ArenaAllocator = .init(service.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    service.worker.slow_mounts = slowMountsBelow(arena, service.root);
    defer service.worker.slow_mounts = &.{};
    const name_changes = if (service.options.names) |names| names.nameChanges() else null;
    var docs: ?[]content.DocIn = null;
    var listed: ?ListingStamp = null;
    var changed = service.changes(arena, name_changes, &docs, &listed) orelse return;
    if (service.stop.load(.acquire)) return;
    if (service.index != null and
        changed.gone.len == 0 and
        changed.added.len == 0 and
        changed.reextract.len == 0)
    {
        service.commitListing(listed);
        if (service.worker.unsaved) service.retrySave();
        return;
    }

    service.counters.building.store(true, .release);
    defer service.counters.building.store(false, .release);
    defer @import("root.zig").trimHeap();
    // Only missing cached texts for unchanged indexed documents: extract them
    // back into TextCache without rebuilding or deleting them via dropStale.
    if (service.index != null and changed.gone.len == 0 and changed.added.len == 0) {
        const extract_start_ns = sys.monotonicNs();
        const reextracted = service.extractMissing(arena, changed.reextract) orelse return;
        service.counters.extract_ns_last.store(sys.monotonicNs() - extract_start_ns, .monotonic);
        if (service.stop.load(.acquire)) return;
        service.commitListing(listed);
        service.commitRetry(reextracted.retry);
        if (reextracted.docs.len > 0) {
            const next_version = service.version.load(.monotonic) + 1;
            service.lock.lockUncancelable(service.io);
            service.index.?.version.store(next_version, .release);
            service.version.store(next_version, .release);
            service.lock.unlock(service.io);
            if (service.options.on_published) |hook| hook.callback(hook.context);
        }
        return;
    }
    const whole = service.wantsWhole(changed);
    // A whole build indexes every file: they must be listed.
    if (whole and docs == null) {
        docs = service.listAll(arena, name_changes, &listed) orelse return;
        changed = service.diff(arena, docs.?) catch return logOutOfMemory("comparing the listing");
    }
    var start_ns = sys.monotonicNs();
    const extracted = if (whole)
        service.extractMissing(arena, docs.?) orelse return
    else
        service.extractMissing(arena, changed.added) orelse return;
    if (whole) docs = extracted.docs else changed.added = extracted.docs;
    if (!whole and changed.reextract.len > 0) {
        _ = service.extractMissing(arena, changed.reextract);
    }
    service.counters.extract_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
    if (service.stop.load(.acquire)) return;
    // Only documents to retry, which failed again.
    if (!whole and changed.gone.len == 0 and changed.added.len == 0) {
        service.commitListing(listed);
        service.commitRetry(extracted.retry);
        return;
    }
    start_ns = sys.monotonicNs();
    const input: BuildInput = if (whole) .{ .whole = docs.? } else .{ .update = changed };
    const built = service.buildNext(input) orelse return;
    const next_version = service.version.load(.monotonic) + 1;
    const fresh = Shared.create(service.gpa, built, next_version) catch {
        log.warn("building the content index: out of memory", .{});
        return;
    };
    service.counters.build_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
    _ = service.counters.builds.fetchAdd(1, .release);
    if (!whole) _ = service.counters.updates.fetchAdd(1, .release);

    const old = blk: {
        service.lock.lockUncancelable(service.io);
        defer service.lock.unlock(service.io);
        const old = service.index;
        service.index = fresh;
        service.version.store(next_version, .release);
        break :blk old;
    };
    service.commitListing(listed);
    service.commitRetry(extracted.retry);
    if (service.options.on_published) |hook| hook.callback(hook.context);
    if (old) |old_shared| {
        // The service's reference: a search still reading it keeps it
        // until it is done.
        service.text_cache.dropStale(&old_shared.index, changed.gone, changed.added);
        old_shared.release();
    }
    if (whole) service.sweepText();
}

/// What changed since the index was built: every file listed again (no
/// index yet, names created or removed, modified unindexed file became
/// eligible, or the listing is old), or only the indexed ones checked. A
/// listing is left in `docs`.
fn changes(
    service: *ContentService,
    arena: std.mem.Allocator,
    name_changes: ?u64,
    docs: *?[]content.DocIn,
    listed: *?ListingStamp,
) ?Diff {
    const start_ns = sys.monotonicNs();
    if (service.listingReason(name_changes, start_ns) != null) {
        if (service.options.names) |names| _ = names.takeModified(arena) catch {};
        docs.* = service.listAll(arena, name_changes, listed) orelse return null;
        return service.diff(arena, docs.*.?) catch {
            logOutOfMemory("comparing the listing");
            return null;
        };
    }
    if (service.options.names) |names| {
        const modified = names.takeModified(arena) catch null;
        if (modified != null and service.shouldRelistForModified(modified.?)) {
            docs.* = service.listAll(arena, name_changes, listed) orelse return null;
            return service.diff(arena, docs.*.?) catch {
                logOutOfMemory("comparing the listing");
                return null;
            };
        }
    }
    const changed = service.indexedChanges(arena) catch {
        logOutOfMemory("checking the indexed files");
        return null;
    };
    service.counters.stat_ns_last.store(sys.monotonicNs() - start_ns, .monotonic);
    return changed;
}

/// True if an in-place modification queue overflowed or includes a file not
/// currently live in the index that is now eligible (e.g. a >1 MiB log file
/// truncated into indexable bounds).
fn shouldRelistForModified(service: *const ContentService, modified: Service.Modified) bool {
    if (modified.overflow) return true;
    const index = service.current() orelse return true;
    for (modified.paths) |mod_path| {
        if (service.isLivePath(index, mod_path)) continue;
        if (content_list.eligible(service.root, mod_path, service.worker.slow_mounts)) return true;
    }
    return false;
}

fn isLivePath(service: *const ContentService, index: *const content.Index, target: []const u8) bool {
    _ = service;
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (index.removed(id)) continue;
        if (std.mem.eql(u8, index.path(id), target)) return true;
    }
    return false;
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
    const index = service.current() orelse return true;
    const removed_count = index.docs_removed_count + changed.gone.len;
    const docs_count = index.docs_count + changed.added.len;
    if (removed_count * 100 > docs_count * service.options.removed_percent_max) return true;
    if (index.segments_count >= service.options.segments_max) return true;
    return @as(u128, index.bytes.len) * 100 >
        @as(u128, index.bytes_live) * (100 + garbage_percent_max);
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
    const index = service.current().?;
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
        .stop = &service.stop,
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
        // Shutting down: the index on disk stays the last finished one.
        error.Cancelled => return null,
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
    const index = service.current().?;
    switch (strategy) {
        .build_whole => unreachable,
        .append_to_mapped_file => {
            const appended = content.appendFile(
                gpa,
                pool,
                index,
                changed.gone,
                changed.added,
                reader,
                path,
                null,
            ) catch |err| switch (err) {
                // Appending pushed the doc table past u32 offsets (4 GiB):
                // rewrite the file from offset 64 instead of wedging updates.
                error.IndexTooLarge => null,
                else => return err,
            };
            if (appended) |fresh| return fresh;
            // The file is not the one the index was mapped from any more (or
            // grew past 4 GiB): rewritten instead.
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
            service.current().?,
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
    const index = service.current() orelse return;
    index.save(service.cache_path) catch |err| {
        log.warn("saving the content index: {t}", .{err});
        return;
    };
    service.worker.unsaved = false;
}

/// Sweeps the text cache of what the index in use does not refer to
/// (`TextCache.sweep`). On start and after a whole build, on the service
/// thread: the one that writes the cache.
fn sweepText(service: *ContentService) void {
    service.assertWorkerThread();
    const index = service.current() orelse return;
    service.text_cache.sweep(service.gpa, index);
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
            fixture.root.absolute,
            fixture.cache.absolute,
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
    const directory = service.text_cache.directory;
    const text_dir = try std.mem.printSentinel(&text_dir_buffer, "{s}", .{directory}, 0);
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
            hits[0].size,
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
    // A directory where the index file goes: renaming the temporary onto it fails.
    var saved_buffer: paths.Buffer = undefined;
    const saved = try fixture.cache.path(&saved_buffer, "content.idx");
    try testing.expect(linux.errno(linux.mkdir(saved, 0o700)) == .SUCCESS);
    const service = try fixture.start();
    defer service.shutdown();
    try waitChecks(service, 1);
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "lemur")).len);
    try testing.expect(!sys.isRegular(saved));
    // Writable again: the next check saves it, though nothing changed.
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.rmdir(saved)));
    try pokeAndWait(service);
    try testing.expect(sys.isRegular(saved));
    try testing.expectEqual(@as(u32, 1), service.status().builds);
}

test "content service: with the name index, checks without name changes only look at indexed files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.root.write("a.txt", "first apricot\n");
    var names_path_buffer: paths.Buffer = undefined;
    const names_path = try fixture.cache.path(&names_path_buffer, "files.idx");
    const root = fixture.root.absolute;
    const names = try Service.start(testing.allocator, testing.io, root, names_path);
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
    try testing.expectEqual(@as(usize, 0), service.index.?.index.docs_removed_count);
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
                .cwd = .{ .path = tree.absolute },
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

    var hash_hex: [32]u8 = undefined;
    var prefix_buffer: [40]u8 = undefined;
    const prefix = try std.mem.print(
        &prefix_buffer,
        "{s}-",
        .{TextCache.pathHashHex(&hash_hex, report)},
    );
    var legacy_prefix_buffer: [32]u8 = undefined;
    const legacy_prefix = try std.mem.print(
        &legacy_prefix_buffer,
        "{x:0>16}-",
        .{std.hash.Wyhash.hash(0, report)},
    );
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
            hits[0].size,
            .extracted,
            std.math.maxInt(u32),
        ).?;
        try testing.expectEqualStrings("Minutes about the wombat project", text);
        // Asked as plain text, the zip is not the text.
        const raw = service.readText(
            fixture.arena_state.allocator(),
            hits[0].path,
            hits[0].mtime,
            hits[0].size,
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
        fixture.cache.absolute,
        prefix,
        mtime_second,
        size,
    }, 0);
    const old_name = try std.mem.printSentinel(&old_name_buffer, "{s}/text/{s}{d}.txt", .{
        fixture.cache.absolute,
        legacy_prefix,
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

test "content service: a document whose extraction failed in passing is left out, and retried with cap and backoff" {
    var tree = try TestTree.init();
    defer tree.deinit();
    var cache_dir = try TestTree.init();
    defer cache_dir.deinit();
    try tree.write("a.pdf", "not really a pdf");
    try tree.write("b.txt", "plain words here");
    var path_buffer: paths.Buffer = undefined;
    const pdf = try tree.path(&path_buffer, "a.pdf");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pool = try Pool.create(testing.allocator, testing.io, 0);
    defer pool.destroy();
    var service: ContentService = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .root = tree.absolute,
        .cache_path = undefined,
        .text_cache = try TextCache.init(testing.allocator, cache_dir.absolute),
        .search_pool = pool,
        .build_pool = pool,
        .options = .{ .extract_retry_backoff_ns = 0, .cache_write_backoff_ns = 60 * std.time.ns_per_s },
        .worker = .{
            .thread_id = std.Thread.getCurrentId(),
            .retry_arena = .init(testing.allocator),
        },
    };
    defer service.text_cache.deinit(testing.allocator);
    defer service.worker.retry_arena.deinit();
    const docs = content_list.list(arena, testing.allocator, testing.io, tree.absolute, .{
        .documents = true,
    }) catch |err| switch (err) {
        // Without ripgrep.
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqualStrings(pdf, docs[0].path);

    // Timed out attempt 1: left out and queued for retry.
    const now = sys.monotonicNs();
    const first = service.leaveOut(
        arena,
        docs,
        &.{0},
        &.{0},
        &[_]?ExtractContext.Failure{.{ .err = error.Timeout }},
        &.{},
        &.{},
        now,
    ).?;
    service.commitRetry(first.retry);
    const kept = first.docs;
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(std.mem.endsWith(u8, kept[0].path, "/b.txt"));
    try testing.expectEqual(@as(usize, 1), service.worker.retry.len);
    try testing.expectEqual(@as(u8, 1), service.worker.retry[0].attempts);
    try testing.expectEqualStrings(pdf, service.worker.retry[0].doc.path);
    const reader: content.TextReader = .{ .read = textOf, .context = &service };
    service.index = try Shared.create(
        testing.allocator,
        try content.build(testing.allocator, pool, kept, reader, null),
        1,
    );
    defer service.index.?.release();

    // With future backoff, indexedChanges defers instead of looping every refresh.
    service.worker.retry[0].next_retry_ns = sys.monotonicNs() + 60 * std.time.ns_per_s;
    const deferred_changes = try service.indexedChanges(arena);
    try testing.expectEqual(@as(usize, 0), deferred_changes.added.len);

    // Once backoff expires, indexedChanges schedules retry again.
    service.worker.retry[0].next_retry_ns = 0;
    const changes_found = try service.indexedChanges(arena);
    try testing.expectEqual(@as(usize, 0), changes_found.gone.len);
    try testing.expectEqual(@as(usize, 1), changes_found.added.len);
    try testing.expectEqualStrings(pdf, changes_found.added[0].path);
    try testing.expectEqual(content.Source.extracted, changes_found.added[0].source);

    // Repeated deterministic timeouts up to extract_retries_max cache an empty file and stop retrying.
    const second = service.leaveOut(
        arena,
        changes_found.added,
        &.{0},
        &.{1},
        &[_]?ExtractContext.Failure{.{ .err = error.Timeout }},
        &.{},
        &.{},
        now,
    ).?;
    try testing.expectEqual(@as(usize, 1), second.retry.len);
    try testing.expectEqual(@as(u8, 2), second.retry[0].attempts);

    const third = service.leaveOut(
        arena,
        changes_found.added,
        &.{0},
        &.{2},
        &[_]?ExtractContext.Failure{.{ .err = error.Timeout }},
        &.{},
        &.{},
        now,
    ).?;
    service.commitRetry(third.retry);
    try testing.expectEqual(@as(usize, 0), service.worker.retry.len);
    try testing.expectEqual(@as(usize, 1), third.docs.len);
    try testing.expect(service.textCached(changes_found.added[0]));

    // Cache write failures (ENOSPC) arm cache_unwritable_until_ns without burning attempts.
    const enospc = service.leaveOut(
        arena,
        changes_found.added,
        &.{0},
        &.{0},
        &[_]?ExtractContext.Failure{.{ .err = error.NoSpace, .cache_write = true }},
        &.{},
        &.{},
        now,
    ).?;
    try testing.expect(service.worker.cache_unwritable_until_ns > now);
    try testing.expectEqual(@as(usize, 1), enospc.retry.len);
    try testing.expectEqual(@as(u8, 0), enospc.retry[0].attempts);
}

test "a shared index outlives the service's reference while a search holds one" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    const Empty = struct {
        fn read(
            _: *anyopaque,
            _: content.DocIn,
            _: *std.ArrayList(u8),
            _: std.mem.Allocator,
        ) std.mem.Allocator.Error!bool {
            return false;
        }
    };
    var unused: u8 = 0;
    const reader: content.TextReader = .{ .read = Empty.read, .context = &unused };
    const docs = [_]content.DocIn{.{ .path = "/a", .mtime = 1, .size = 1 }};
    const shared = try Shared.create(gpa, try content.build(gpa, pool, &docs, reader, null), 1);
    // A search takes its reference, then the service swaps and lets go of
    // its own: the index stays readable (testing.allocator would report a
    // use after free) until the search is done.
    shared.acquire();
    shared.release();
    try testing.expectEqual(@as(usize, 1), shared.index.docs_count);
    try testing.expectEqualStrings("/a", shared.index.path(0));
    shared.release();
}

test "content service: indexVersion advances on publish and searchUntil reports the version searched" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const PublishTracker = struct {
        count: std.atomic.Value(u32) = .init(0),
        fn onPublished(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.count.fetchAdd(1, .release);
        }
    };
    var tracker: PublishTracker = .{};

    // Start with a file whose extraction/listing is initially absent: simulate
    // version 0 before the first publish using an unstarted struct, then a live
    // service transitioning from initial publish (v1) to edit where file stops matching (v2).
    var empty_service: ContentService = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .root = fixture.root.absolute,
        .cache_path = undefined,
        .text_cache = undefined,
        .search_pool = fixture.search_pool,
        .build_pool = fixture.build_pool,
        .options = .{},
        .worker = .{ .retry_arena = .init(testing.allocator) },
    };
    defer empty_service.worker.retry_arena.deinit();
    var hits: std.ArrayList(Hit) = .empty;
    try testing.expectEqual(@as(u64, 0), empty_service.indexVersion());
    try testing.expectEqual(@as(u64, 0), try empty_service.searchUntil(
        fixture.arena_state.allocator(),
        "ephemeral",
        10,
        null,
        &hits,
    ));
    try testing.expectEqual(@as(usize, 0), hits.items.len);

    try fixture.root.write("doc.txt", "unique ephemeral token\n");
    var path_buffer: paths.Buffer = undefined;
    const doc_path = try fixture.root.path(&path_buffer, "doc.txt");
    try setMtime(doc_path, sys.nowSeconds() - 200);

    const service = try fixture.startWith(.{
        .refresh_interval_ns = std.math.maxInt(u64),
        .poke_interval_ns_min = 0,
        .removed_percent_max = 100,
        .on_published = .{ .callback = &PublishTracker.onPublished, .context = &tracker },
    });
    defer service.shutdown();
    try waitChecks(service, 1);

    try testing.expectEqual(@as(u64, 1), service.indexVersion());
    try testing.expectEqual(@as(u32, 1), tracker.count.load(.acquire));
    const v1 = try service.searchUntil(fixture.arena_state.allocator(), "ephemeral", 10, null, &hits);
    try testing.expectEqual(@as(u64, 1), v1);
    try testing.expectEqual(@as(usize, 1), hits.items.len);

    // File is edited so it no longer matches "ephemeral".
    try fixture.root.write("doc.txt", "completely different words\n");
    try setMtime(doc_path, sys.nowSeconds() - 100);
    try pokeAndWait(service);

    try testing.expectEqual(@as(u64, 2), service.indexVersion());
    try testing.expectEqual(@as(u32, 2), tracker.count.load(.acquire));
    const v2 = try service.searchUntil(fixture.arena_state.allocator(), "ephemeral", 10, null, &hits);
    try testing.expectEqual(@as(u64, 2), v2);
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "content service: missing cached text is re-extracted and kept instead of dropped as stale" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    if (!haveTool("zip") or !haveTool("unzip")) return error.SkipZigTest;

    var stage = try TestTree.init();
    defer stage.deinit();
    try stage.write("[Content_Types].xml", "<?xml version=\"1.0\"?><Types/>");
    try stage.write(
        "word/document.xml",
        \\<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Minutes about the okapi project</w:t></w:r></w:p></w:body></w:document>
        ,
    );

    var path_buffer: paths.Buffer = undefined;
    const report = try fixture.root.path(&path_buffer, "report.docx");
    const zip_res = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "zip", "-q", "-X", "-r", report, "." },
        .cwd = .{ .path = stage.absolute },
    });
    testing.allocator.free(zip_res.stdout);
    testing.allocator.free(zip_res.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, zip_res.term);
    try setMtime(report, sys.nowSeconds() - 200);

    const service = try fixture.start();
    defer service.shutdown();
    try waitChecks(service, 1);
    try testing.expectEqual(@as(u32, 1), service.status().extractions);
    try testing.expectEqual(@as(u32, 1), service.status().builds);
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "okapi")).len);

    // Simulate a cache cleaner deleting the cached .txt file while report.docx is unchanged.
    const stat = content_list.stat(report, .document).?;
    var cache_path_buf: paths.Buffer = undefined;
    const cached_txt = service.text_cache.path(&cache_path_buf, .{
        .path = report,
        .mtime = stat.mtime,
        .size = stat.size,
        .source = .extracted,
    }).?;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlink(cached_txt)));
    try testing.expect(!sys.exists(cached_txt));

    // Poke: must re-extract without rebuilding the index, and must NOT delete cached_txt!
    try pokeAndWait(service);
    try testing.expectEqual(@as(u32, 2), service.status().extractions);
    try testing.expectEqual(@as(u32, 1), service.status().builds);
    try testing.expect(sys.exists(cached_txt));
    try testing.expectEqual(@as(usize, 1), (try fixture.find(service, "okapi")).len);

    // Next poke: cached text is back, so nothing is extracted again.
    try pokeAndWait(service);
    try testing.expectEqual(@as(u32, 2), service.status().extractions);
}

test "content service: file truncated below text_bytes_max is indexed promptly via CLOSE_WRITE" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    // Create a >1 MiB file so the initial build excludes it.
    var log_buf: paths.Buffer = undefined;
    const log_path = try fixture.root.path(&log_buf, "huge.log");
    try fixture.root.write("huge.log", "initially too big\n");
    {
        const fd_res = linux.open(log_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(fd_res));
        const fd: i32 = @intCast(fd_res);
        defer sys.close(fd);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, content.text_bytes_max + 100)));
    }

    var names_path_buffer: paths.Buffer = undefined;
    const names_path = try fixture.cache.path(&names_path_buffer, "files.idx");
    const names = try Service.start(testing.allocator, testing.io, fixture.root.absolute, names_path);
    defer names.shutdown();
    _ = try Service.waitNames(names, null);

    const service = try fixture.startWith(.{
        .refresh_interval_ns = std.math.maxInt(u64),
        .poke_interval_ns_min = 0,
        .list_interval_ns = 30 * 60 * std.time.ns_per_s,
        .removed_percent_max = 100,
        .names = names,
    });
    defer service.shutdown();
    try waitChecks(service, 1);
    try testing.expectEqual(@as(usize, 0), service.status().docs);

    // Edit in-place (same inode) shrinking below text_bytes_max -> IN_CLOSE_WRITE triggers indexing.
    try fixture.root.write("huge.log", "truncated capybara log line\n");
    // Give inotify thread a moment to drain IN_CLOSE_WRITE.
    var indexed = false;
    for (0..100) |_| {
        try pokeAndWait(service);
        if ((try fixture.find(service, "capybara")).len == 1) {
            indexed = true;
            break;
        }
        sys.sleepUs(10_000);
    }
    try testing.expect(indexed);
}
