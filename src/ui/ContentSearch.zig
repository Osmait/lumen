//! Content searches off the UI thread.
//!
//! A content query reads files to verify its candidates: usually a few ms,
//! but nothing bounds it (a slow disk, a huge document, once a FIFO that
//! blocked forever), and on the UI thread every keystroke waited for it.
//! Here the UI posts the latest query and keeps typing; one worker runs the
//! newest query (stale ones in between are skipped) and hands the result
//! back on the GTK main loop with g_idle_add, which is thread-safe. A query
//! still verifying when a newer one comes stops at its next file: it held
//! the search threads and the index for an answer nobody would see.

const std = @import("std");
const c = @import("c");
const index = @import("index");
const core = @import("core");
const os = @import("os");

const ContentSearch = @This();

const log = std.log.scoped(.content_search);

/// Longer queries are cut to this many bytes; compare results against
/// `clip(query)`, not the query typed.
pub const query_bytes_max = 1024;

gpa: std.mem.Allocator,
io: std.Io,
service: *index.ContentService,
/// Hits a search returns at most.
hits_max: usize,
on_result: Callback,
/// Handed back to `on_result` with each result.
context: ?*anyopaque,
thread: std.Thread = undefined,
lock: std.Io.Mutex = .init,
delivery_lock: std.Io.Mutex = .init,
pending_hops: ?*Hop = null,
/// Bumped by every `submit`; the worker sleeps on it.
generation: std.atomic.Value(u32) = .init(0),
/// Set by `submit` (and `shutdown`), cleared by the worker when it takes
/// the query: the query running is stale.
newer: std.atomic.Value(bool) = .init(false),
stop: std.atomic.Value(bool) = .init(false),
query: core.FixedStr(query_bytes_max) = .{},
query_start_ns: u64 = 0,

/// Owned by the receiver of `Callback`, which frees it with `destroy`.
pub const Result = struct {
    /// The request it answers. A plain u32, unlike the extension host's
    /// generations: it is the worker's futex word as well (`submit` bumps
    /// it and wakes the worker on it).
    generation: u32,
    /// `ContentService.indexVersion()` when this result was searched (0 when
    /// no index was ready yet).
    index_version: u64 = 0,
    /// When the keystroke that asked for it happened (latency stats).
    start_ns: u64,
    search_ns: u64,
    query: []const u8,
    hits: []index.ContentService.Hit,
    /// Why the search stopped short (then `hits` may be empty or partial).
    err: ?std.mem.Allocator.Error = null,
    arena: std.heap.ArenaAllocator,

    pub fn destroy(result: *Result, gpa: std.mem.Allocator) void {
        result.arena.deinit();
        gpa.destroy(result);
    }
};

/// Called on the GTK main loop; takes ownership of `result`.
pub const Callback = *const fn (result: *Result, context: ?*anyopaque) void;

pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError;

const Hop = struct {
    content_search: *ContentSearch,
    result: *Result,
    source_id: c_uint = 0,
    prev: ?*Hop = null,
    next: ?*Hop = null,
};

/// The part of `query` a search runs: whole UTF-8 characters, at most
/// `query_bytes_max` bytes.
pub fn clip(query: []const u8) []const u8 {
    return query[0..core.utf8.floorBoundary(query, query_bytes_max)];
}

/// Starts the worker. `service` must outlive it.
pub fn start(
    gpa: std.mem.Allocator,
    io: std.Io,
    service: *index.ContentService,
    hits_max: usize,
    on_result: Callback,
    context: ?*anyopaque,
) StartError!*ContentSearch {
    const content_search = try gpa.create(ContentSearch);
    errdefer gpa.destroy(content_search);
    content_search.* = .{
        .gpa = gpa,
        .io = io,
        .service = service,
        .hits_max = hits_max,
        .on_result = on_result,
        .context = context,
    };
    content_search.thread = try std.Thread.spawn(.{}, run, .{content_search});
    // The name only shows in tools like top: a thread without one works.
    content_search.thread.setName(io, "lm-csearch") catch {};
    return content_search;
}

/// Stops and joins the worker, and cancels any results still queued on
/// the GTK main loop. Main thread only.
pub fn shutdown(content_search: *ContentSearch) void {
    content_search.stop.store(true, .release);
    content_search.newer.store(true, .release);
    _ = content_search.generation.fetchAdd(1, .release);
    content_search.io.futexWake(u32, &content_search.generation.raw, 1);
    content_search.thread.join();
    var cursor = content_search.pending_hops;
    content_search.pending_hops = null;
    while (cursor) |hop| {
        const next = hop.next;
        if (hop.source_id != 0) _ = c.g_source_remove(hop.source_id);
        hop.result.destroy(content_search.gpa);
        content_search.gpa.destroy(hop);
        cursor = next;
    }
    content_search.gpa.destroy(content_search);
}

fn unlinkHop(content_search: *ContentSearch, hop: *Hop) void {
    if (hop.prev) |prev| {
        prev.next = hop.next;
    } else if (content_search.pending_hops == hop) {
        content_search.pending_hops = hop.next;
    }
    if (hop.next) |next| next.prev = hop.prev;
    hop.prev = null;
    hop.next = null;
}

/// Bumps `counter` with wraparound, skipping 0 (which `Inflight.forget()`
/// reserves as its cleared sentinel).
fn nextGeneration(counter: *std.atomic.Value(u32)) u32 {
    while (true) {
        const current = counter.load(.monotonic);
        var next = current +% 1;
        if (next == 0) next = 1;
        if (counter.cmpxchgWeak(current, next, .release, .monotonic) == null) return next;
    }
}

/// Asks for `clip(query)`; returns its generation. Results of older
/// generations still in flight should be dropped by the receiver.
/// Thread-safe.
pub fn submit(content_search: *ContentSearch, query: []const u8, start_ns: u64) u32 {
    const query_clipped = clip(query);
    const generation = blk: {
        content_search.lock.lockUncancelable(content_search.io);
        defer content_search.lock.unlock(content_search.io);
        content_search.query.set(query_clipped);
        content_search.query_start_ns = start_ns;
        content_search.newer.store(true, .release);
        break :blk nextGeneration(&content_search.generation);
    };
    content_search.io.futexWake(u32, &content_search.generation.raw, 1);
    return generation;
}

fn run(content_search: *ContentSearch) void {
    var seen: u32 = 0;
    while (true) {
        while (content_search.generation.load(.acquire) == seen) {
            if (content_search.stop.load(.acquire)) break;
            content_search.io.futexWaitUncancelable(u32, &content_search.generation.raw, seen);
        }
        if (content_search.stop.load(.acquire)) return;

        const result = content_search.gpa.create(Result) catch {
            // Drop this query rather than spin on it: the next keystroke
            // asks again.
            seen = content_search.generation.load(.acquire);
            log.warn("content search: out of memory", .{});
            continue;
        };
        result.* = .{
            .generation = 0,
            .start_ns = 0,
            .search_ns = 0,
            .query = "",
            .hits = &.{},
            .arena = .init(content_search.gpa),
        };
        const arena = result.arena.allocator();
        seen = content_search.takeQuery(result);

        const now_ns = os.monotonicNs();
        var hits: std.ArrayList(index.ContentService.Hit) = .empty;
        if (result.err == null) {
            result.index_version = content_search.service.searchUntil(
                arena,
                result.query,
                content_search.hits_max,
                &content_search.newer,
                &hits,
            ) catch |err| blk: {
                result.err = err;
                break :blk 0;
            };
        }
        result.search_ns = os.monotonicNs() - now_ns;
        result.hits = hits.items;
        // A newer query arrived meanwhile, or shutdown began: drop it.
        const superseded = content_search.generation.load(.acquire) != seen;
        if (content_search.stop.load(.acquire) or superseded) {
            result.destroy(content_search.gpa);
            continue;
        }
        if (!content_search.handOver(result)) return;
    }
}

/// The query asked for, into `result` (its generation, start, text); the
/// generation it is, which the worker has now seen.
fn takeQuery(content_search: *ContentSearch, result: *Result) u32 {
    const arena = result.arena.allocator();
    content_search.lock.lockUncancelable(content_search.io);
    defer content_search.lock.unlock(content_search.io);
    const seen = content_search.generation.load(.acquire);
    // Unless shutting down, which may have set it just before.
    content_search.newer.store(content_search.stop.load(.acquire), .release);
    result.generation = seen;
    result.start_ns = content_search.query_start_ns;
    result.query = arena.dupe(u8, content_search.query.slice()) catch |err| blk: {
        result.err = err;
        break :blk "";
    };
    return seen;
}

/// Hands `result` to the GTK main loop (`deliver`), or drops it. False
/// once shutdown has begun: the worker is to return.
fn handOver(content_search: *ContentSearch, result: *Result) bool {
    const hop = content_search.gpa.create(Hop) catch {
        result.destroy(content_search.gpa);
        return true;
    };
    hop.* = .{ .content_search = content_search, .result = result };
    content_search.delivery_lock.lockUncancelable(content_search.io);
    defer content_search.delivery_lock.unlock(content_search.io);
    if (content_search.stop.load(.acquire)) {
        result.destroy(content_search.gpa);
        content_search.gpa.destroy(hop);
        return false;
    }
    hop.next = content_search.pending_hops;
    if (content_search.pending_hops) |head| head.prev = hop;
    content_search.pending_hops = hop;
    const source_id = c.g_idle_add(&deliver, hop);
    hop.source_id = source_id;
    if (source_id == 0) {
        content_search.unlinkHop(hop);
        result.destroy(content_search.gpa);
        content_search.gpa.destroy(hop);
    }
    return true;
}

fn deliver(data: ?*anyopaque) callconv(.c) c.gboolean {
    const hop: *Hop = @ptrCast(@alignCast(data.?));
    const content_search = hop.content_search;
    content_search.delivery_lock.lockUncancelable(content_search.io);
    content_search.unlinkHop(hop);
    const stopped = content_search.stop.load(.acquire);
    content_search.delivery_lock.unlock(content_search.io);
    defer content_search.gpa.destroy(hop);
    if (stopped) {
        hop.result.destroy(content_search.gpa);
        return 0;
    }
    content_search.on_result(hop.result, content_search.context);
    return 0;
}

test "nextGeneration wraps u32 without overflowing or hitting sentinel 0" {
    var counter: std.atomic.Value(u32) = .init(std.math.maxInt(u32) - 1);
    try std.testing.expectEqual(std.math.maxInt(u32), nextGeneration(&counter));
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(&counter));
    try std.testing.expectEqual(@as(u32, 2), nextGeneration(&counter));
}
