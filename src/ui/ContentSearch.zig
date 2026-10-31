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

pub fn clip(query: []const u8) []const u8 {
    return query[0..core.utf8.floorBoundary(query, query_bytes_max)];
}

/// Owned by the receiver of `Callback`, which frees it with `destroy`.
pub const Result = struct {
    /// The request it answers. A plain u32, unlike the extension host's
    /// generations: it is the worker's futex word as well (`submit` bumps
    /// it and wakes the worker on it).
    gen: u32,
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
pub const Callback = *const fn (result: *Result, ctx: ?*anyopaque) void;

gpa: std.mem.Allocator,
io: std.Io,
service: *index.ContentService,
limit: usize,
on_result: Callback,
ctx: ?*anyopaque,
thread: std.Thread = undefined,
lock: std.Io.Mutex = .init,
/// Bumped by every `submit`; the worker sleeps on it.
gen: std.atomic.Value(u32) = .init(0),
/// Set by `submit` (and `shutdown`), cleared by the worker when it takes
/// the query: the query running is stale.
newer: std.atomic.Value(bool) = .init(false),
stop: std.atomic.Value(bool) = .init(false),
query: core.FixedStr(query_bytes_max) = .{},
query_start_ns: u64 = 0,

pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError;

/// Starts the worker. `service` must outlive it.
pub fn start(
    gpa: std.mem.Allocator,
    io: std.Io,
    service: *index.ContentService,
    limit: usize,
    on_result: Callback,
    ctx: ?*anyopaque,
) StartError!*ContentSearch {
    const content_search = try gpa.create(ContentSearch);
    errdefer gpa.destroy(content_search);
    content_search.* = .{
        .gpa = gpa,
        .io = io,
        .service = service,
        .limit = limit,
        .on_result = on_result,
        .ctx = ctx,
    };
    content_search.thread = try std.Thread.spawn(.{}, run, .{content_search});
    // The name only shows in tools like top: a thread without one works.
    content_search.thread.setName(io, "lm-csearch") catch {};
    return content_search;
}

/// Stops and joins the worker. Call once the GTK main loop has stopped:
/// a result still queued with g_idle_add would otherwise reach a freed `cs`.
pub fn shutdown(content_search: *ContentSearch) void {
    content_search.stop.store(true, .release);
    content_search.newer.store(true, .release);
    _ = content_search.gen.fetchAdd(1, .release);
    content_search.io.futexWake(u32, &content_search.gen.raw, 1);
    content_search.thread.join();
    content_search.gpa.destroy(content_search);
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
        break :blk content_search.gen.fetchAdd(1, .release) + 1;
    };
    content_search.io.futexWake(u32, &content_search.gen.raw, 1);
    return generation;
}

fn run(content_search: *ContentSearch) void {
    var seen: u32 = 0;
    while (true) {
        while (content_search.gen.load(.acquire) == seen and !content_search.stop.load(.acquire)) {
            content_search.io.futexWaitUncancelable(u32, &content_search.gen.raw, seen);
        }
        if (content_search.stop.load(.acquire)) return;

        const result = content_search.gpa.create(Result) catch {
            // Drop this query rather than spin on it: the next keystroke
            // asks again.
            seen = content_search.gen.load(.acquire);
            log.warn("content search: out of memory", .{});
            continue;
        };
        result.* = .{
            .gen = 0,
            .start_ns = 0,
            .search_ns = 0,
            .query = "",
            .hits = &.{},
            .arena = .init(content_search.gpa),
        };
        const arena = result.arena.allocator();
        {
            content_search.lock.lockUncancelable(content_search.io);
            defer content_search.lock.unlock(content_search.io);
            seen = content_search.gen.load(.acquire);
            // Unless shutting down, which may have set it just before.
            content_search.newer.store(content_search.stop.load(.acquire), .release);
            result.gen = seen;
            result.start_ns = content_search.query_start_ns;
            result.query = arena.dupe(u8, content_search.query.slice()) catch |err| blk: {
                result.err = err;
                break :blk "";
            };
        }

        const now_ns = os.monotonicNs();
        var hits: std.ArrayList(index.ContentService.Hit) = .empty;
        if (result.err == null) {
            content_search.service.searchUntil(
                arena,
                result.query,
                content_search.limit,
                &content_search.newer,
                &hits,
            ) catch |err| {
                result.err = err;
            };
        }
        result.search_ns = os.monotonicNs() - now_ns;
        result.hits = hits.items;
        // A newer query arrived meanwhile: this answer is already stale.
        if (content_search.gen.load(.acquire) != seen) {
            result.destroy(content_search.gpa);
            continue;
        }
        const hop = content_search.gpa.create(Hop) catch {
            result.destroy(content_search.gpa);
            continue;
        };
        hop.* = .{ .content_search = content_search, .result = result };
        _ = c.g_idle_add(&deliver, hop);
    }
}

const Hop = struct { content_search: *ContentSearch, result: *Result };

fn deliver(data: ?*anyopaque) callconv(.c) c.gboolean {
    const hop: *Hop = @ptrCast(@alignCast(data.?));
    defer hop.content_search.gpa.destroy(hop);
    hop.content_search.on_result(hop.result, hop.content_search.ctx);
    return 0;
}
