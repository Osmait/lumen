//! The clipboard filter off the GTK thread (MYP-613).
//!
//! A long query over a full history (5,000 entries of 2,000 bytes) took up
//! to ~145 ms to score, and the GTK thread waited for it on every
//! keystroke. Here the UI posts the latest query and keeps typing; one
//! worker scores the newest (`ClipFilter.run`), skipping those in between,
//! and hands the result back on the GTK main loop (g_idle_add), as
//! ContentSearch does. A query still being scored when a newer one comes
//! stops within a few entries.
//!
//! A request holds a reference to the corpus it scores: the view can load
//! its entries again (an entry deleted) while the worker reads the old ones.

const std = @import("std");
const assert = std.debug.assert;
const os = @import("os");
const MainLoopQueue = @import("../sys/MainLoopQueue.zig").MainLoopQueue;
const ClipFilter = @import("ClipFilter.zig");
const Corpus = ClipFilter.Corpus;
const ClipId = @import("../sys/Db.zig").ClipId;

const ClipSearch = @This();

const log = std.log.scoped(.clip_search);

gpa: std.mem.Allocator,
io: std.Io,
/// Hits a result holds at most.
results_max: usize,
on_result: Callback,
/// Handed back to `on_result` with each result.
context: ?*anyopaque,
thread: std.Thread = undefined,
deliveries: MainLoopQueue(*Result) = undefined,
/// Bumped by every `submit` and `cancel`; the worker sleeps on it.
generation: std.atomic.Value(u32) = .init(0),
/// Set by `submit`, `cancel` and `shutdown`, cleared by the worker when it
/// takes the request: the query being scored is stale.
newer: ClipFilter.Cancel = .init(false),
stop: std.atomic.Value(bool) = .init(false),
/// The request, under `lock`.
lock: std.Io.Mutex = .init,
/// A reference, given to the worker with the request; null: nothing to do.
corpus: ?*Corpus = null,
query: std.ArrayList(u8) = .empty,
beyond: std.ArrayList(ClipId) = .empty,
start_ns: u64 = 0,

/// Owned by the receiver of `Callback`, which frees it with `destroy`.
pub const Result = struct {
    /// The request it answers.
    generation: u32,
    /// The corpus it scored (`Corpus.serial`).
    serial: u64,
    /// When the keystroke that asked for it happened (latency stats).
    start_ns: u64,
    search_ns: u64 = 0,
    query: []const u8 = "",
    /// Best first.
    hits: []const ClipFilter.Hit = &.{},
    /// Why `hits` is empty.
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

/// Starts the worker.
pub fn start(
    gpa: std.mem.Allocator,
    io: std.Io,
    results_max: usize,
    on_result: Callback,
    context: ?*anyopaque,
) StartError!*ClipSearch {
    const clip_search = try gpa.create(ClipSearch);
    errdefer gpa.destroy(clip_search);
    clip_search.* = .{
        .gpa = gpa,
        .io = io,
        .results_max = results_max,
        .on_result = on_result,
        .context = context,
    };
    clip_search.deliveries = .{
        .gpa = gpa,
        .io = io,
        .stop = &clip_search.stop,
        .context = clip_search,
        .deliver_fn = &deliver,
        .destroy_fn = &destroyResult,
    };
    clip_search.thread = try std.Thread.spawn(.{}, run, .{clip_search});
    // The name only shows in tools like top: a thread without one works.
    clip_search.thread.setName(io, "lm-clipsearch") catch {};
    return clip_search;
}

/// Stops and joins the worker (it stops scoring within a few entries), and
/// drops the results still queued on the GTK main loop. Main thread only.
pub fn shutdown(clip_search: *ClipSearch) void {
    clip_search.stop.store(true, .release);
    clip_search.wake(null);
    clip_search.thread.join();
    clip_search.deliveries.drain();
    if (clip_search.corpus) |corpus| corpus.release();
    clip_search.query.deinit(clip_search.gpa);
    clip_search.beyond.deinit(clip_search.gpa);
    clip_search.gpa.destroy(clip_search);
}

/// Asks for `query_text` (not empty) scored against `corpus`, `beyond` as
/// `ClipFilter.Job.beyond`; returns its generation. Results of other
/// generations should be dropped by the receiver. Main thread only.
pub fn submit(
    clip_search: *ClipSearch,
    corpus: *Corpus,
    query_text: []const u8,
    beyond: []const ClipId,
    start_ns: u64,
) std.mem.Allocator.Error!u32 {
    assert(query_text.len > 0);
    const generation = blk: {
        clip_search.lock.lockUncancelable(clip_search.io);
        defer clip_search.lock.unlock(clip_search.io);
        try clip_search.query.ensureTotalCapacity(clip_search.gpa, query_text.len);
        try clip_search.beyond.ensureTotalCapacity(clip_search.gpa, beyond.len);
        clip_search.query.clearRetainingCapacity();
        clip_search.query.appendSliceAssumeCapacity(query_text);
        clip_search.beyond.clearRetainingCapacity();
        clip_search.beyond.appendSliceAssumeCapacity(beyond);
        clip_search.start_ns = start_ns;
        corpus.retain();
        break :blk clip_search.replace(corpus);
    };
    clip_search.io.futexWake(u32, &clip_search.generation.raw, 1);
    return generation;
}

/// Drops the request: the query being scored stops, and nothing answers it.
/// Main thread only.
pub fn cancel(clip_search: *ClipSearch) void {
    clip_search.wake(null);
}

fn wake(clip_search: *ClipSearch, corpus: ?*Corpus) void {
    {
        clip_search.lock.lockUncancelable(clip_search.io);
        defer clip_search.lock.unlock(clip_search.io);
        _ = clip_search.replace(corpus);
    }
    clip_search.io.futexWake(u32, &clip_search.generation.raw, 1);
}

/// The request is for `corpus` now (its reference taken); the next
/// generation. Under `lock`.
fn replace(clip_search: *ClipSearch, corpus: ?*Corpus) u32 {
    if (clip_search.corpus) |replaced| replaced.release();
    clip_search.corpus = corpus;
    clip_search.newer.store(true, .release);
    return nextGeneration(&clip_search.generation);
}

/// Bumps `counter` with wraparound, skipping 0 (which `Inflight.forget()`
/// reserves as its cleared sentinel). Under `lock`.
fn nextGeneration(counter: *std.atomic.Value(u32)) u32 {
    var next = counter.load(.monotonic) +% 1;
    if (next == 0) next = 1;
    counter.store(next, .release);
    return next;
}

/// What the worker takes from a request.
const Taken = struct {
    generation: u32,
    corpus: ?*Corpus,
    start_ns: u64,
};

fn run(clip_search: *ClipSearch) void {
    var seen: u32 = 0;
    // The request's query and entries, swapped with the request's lists.
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(clip_search.gpa);
    var beyond: std.ArrayList(ClipId) = .empty;
    defer beyond.deinit(clip_search.gpa);
    while (true) {
        while (clip_search.generation.load(.acquire) == seen) {
            if (clip_search.stop.load(.acquire)) break;
            clip_search.io.futexWaitUncancelable(u32, &clip_search.generation.raw, seen);
        }
        if (clip_search.stop.load(.acquire)) return;
        const taken = clip_search.take(&query, &beyond);
        seen = taken.generation;
        const corpus = taken.corpus orelse continue;
        defer corpus.release();
        const result = clip_search.score(corpus, taken, query.items, beyond.items) orelse continue;
        // A newer query arrived meanwhile, or shutdown began: drop it.
        const superseded = clip_search.generation.load(.acquire) != seen;
        if (clip_search.stop.load(.acquire) or superseded) {
            result.destroy(clip_search.gpa);
            continue;
        }
        if (!clip_search.deliveries.post(result) and clip_search.stop.load(.acquire)) return;
    }
}

fn take(
    clip_search: *ClipSearch,
    query: *std.ArrayList(u8),
    beyond: *std.ArrayList(ClipId),
) Taken {
    clip_search.lock.lockUncancelable(clip_search.io);
    defer clip_search.lock.unlock(clip_search.io);
    // Unless shutting down, which may have set it just before.
    clip_search.newer.store(clip_search.stop.load(.acquire), .release);
    std.mem.swap(std.ArrayList(u8), query, &clip_search.query);
    std.mem.swap(std.ArrayList(ClipId), beyond, &clip_search.beyond);
    const taken: Taken = .{
        .generation = clip_search.generation.load(.acquire),
        .corpus = clip_search.corpus,
        .start_ns = clip_search.start_ns,
    };
    clip_search.corpus = null;
    return taken;
}

/// The result of scoring the request taken; null when it was stopped (or
/// no memory for a result at all).
fn score(
    clip_search: *ClipSearch,
    corpus: *Corpus,
    taken: Taken,
    query: []const u8,
    beyond: []const ClipId,
) ?*Result {
    const result = clip_search.gpa.create(Result) catch {
        log.warn("clipboard search: out of memory", .{});
        return null;
    };
    result.* = .{
        .generation = taken.generation,
        .serial = corpus.serial,
        .start_ns = taken.start_ns,
        .arena = .init(clip_search.gpa),
    };
    const arena = result.arena.allocator();
    const start_ns = os.monotonicNs();
    result.query = arena.dupe(u8, query) catch |err| {
        result.err = err;
        return result;
    };
    result.hits = ClipFilter.run(corpus, arena, .{
        .query_text = query,
        .beyond = beyond,
        .results_max = clip_search.results_max,
        .cancel = &clip_search.newer,
    }) catch |err| switch (err) {
        error.Canceled => {
            result.destroy(clip_search.gpa);
            return null;
        },
        error.OutOfMemory => blk: {
            result.err = error.OutOfMemory;
            break :blk &.{};
        },
    };
    result.search_ns = os.monotonicNs() - start_ns;
    return result;
}

fn destroyResult(gpa: std.mem.Allocator, result: *Result) void {
    result.destroy(gpa);
}

fn deliver(context: *anyopaque, result: *Result) void {
    const clip_search: *ClipSearch = @ptrCast(@alignCast(context));
    clip_search.on_result(result, clip_search.context);
}

// ----------------------------------------------------------------- tests

const testing = std.testing;
const c = @import("c");

/// Takes the results the worker delivers on the main loop.
const Probe = struct {
    results: std.ArrayList(*Result) = .empty,

    fn onResult(result: *Result, context: ?*anyopaque) void {
        const probe: *Probe = @ptrCast(@alignCast(context.?));
        probe.results.append(testing.allocator, result) catch result.destroy(testing.allocator);
    }

    /// Pumps the main loop until the result of `generation` comes (10 s
    /// at most); the others delivered meanwhile are dropped (stale).
    fn waitFor(probe: *Probe, generation: u32) !*Result {
        const until_ns = os.monotonicNs() + 10 * std.time.ns_per_s;
        while (true) {
            while (probe.results.pop()) |result| {
                if (result.generation == generation) return result;
                result.destroy(testing.allocator);
            }
            if (os.monotonicNs() > until_ns) return error.Timeout;
            if (c.g_main_context_iteration(null, 0) == 0) {
                _ = std.os.linux.poll(&[0]std.os.linux.pollfd{}, 0, 1);
            }
        }
    }

    /// Pumps the main loop for `ms`.
    fn pump(probe: *Probe, ms: u64) void {
        _ = probe;
        const until_ns = os.monotonicNs() + ms * std.time.ns_per_ms;
        while (os.monotonicNs() < until_ns) {
            if (c.g_main_context_iteration(null, 0) == 0) {
                _ = std.os.linux.poll(&[0]std.os.linux.pollfd{}, 0, 1);
            }
        }
    }

    fn deinit(probe: *Probe) void {
        for (probe.results.items) |result| result.destroy(testing.allocator);
        probe.results.deinit(testing.allocator);
    }
};

test "the worker answers as the filter scores in place, the newest query only (MYP-613)" {
    const gpa = testing.allocator;
    const corpus = try ClipFilter.testCorpus(gpa, 300, 613);
    defer corpus.release();
    var probe: Probe = .{};
    defer probe.deinit();
    const results_max = 25;
    const clip_search = try start(gpa, testing.io, results_max, &Probe.onResult, &probe);
    defer clip_search.shutdown();
    const beyond = [_]ClipId{ @fromBackingInt(4), @fromBackingInt(51), @fromBackingInt(300) };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One at a time, each answered: narrowed from the one before.
    for (ClipFilter.test_typed) |typed_query| {
        const generation = try clip_search.submit(corpus, typed_query, &beyond, 7);
        const result = try probe.waitFor(generation);
        defer result.destroy(gpa);
        try testing.expectEqualStrings(typed_query, result.query);
        try testing.expectEqual(corpus.serial, result.serial);
        try testing.expectEqual(@as(u64, 7), result.start_ns);
        const want = try ClipFilter.plainHits(
            arena,
            corpus.items,
            ClipFilter.test_detail_bytes_max,
            typed_query,
            &beyond,
            results_max,
        );
        try ClipFilter.expectHits(want, result.hits);
    }

    // Typed fast: each query supersedes the one before; whatever comes of
    // those is older than the last, which answers as in place.
    var last_generation: u32 = 0;
    for (ClipFilter.test_typed) |typed_query| {
        last_generation = try clip_search.submit(corpus, typed_query, &beyond, 0);
    }
    const last = try probe.waitFor(last_generation);
    defer last.destroy(gpa);
    const last_query = ClipFilter.test_typed[ClipFilter.test_typed.len - 1];
    try testing.expectEqualStrings(last_query, last.query);
    const want = try ClipFilter.plainHits(
        arena,
        corpus.items,
        ClipFilter.test_detail_bytes_max,
        last_query,
        &beyond,
        results_max,
    );
    try ClipFilter.expectHits(want, last.hits);
    // Nothing newer than the last comes after it.
    probe.pump(20);
    for (probe.results.items) |result| try testing.expect(result.generation != last_generation);
}

test "entries the view loads again stay for the worker scoring them (MYP-613)" {
    const gpa = testing.allocator;
    var probe: Probe = .{};
    defer probe.deinit();
    const clip_search = try start(gpa, testing.io, 50, &Probe.onResult, &probe);
    defer clip_search.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    // The view lets go of the entries (an entry deleted, the view loaded
    // again) right after asking: the worker still reads them.
    const corpus = try ClipFilter.testCorpus(gpa, 3000, 11);
    const generation = try clip_search.submit(corpus, "user tok", &.{}, 0);
    corpus.release();
    const result = try probe.waitFor(generation);
    defer result.destroy(gpa);
    const again = try ClipFilter.testCorpus(gpa, 3000, 11);
    defer again.release();
    const want = try ClipFilter.plainHits(
        arena_state.allocator(),
        again.items,
        ClipFilter.test_detail_bytes_max,
        "user tok",
        &.{},
        50,
    );
    try ClipFilter.expectHits(want, result.hits);

    // Dropped: nothing answers, and the entries go with the request.
    const dropped = try ClipFilter.testCorpus(gpa, 3000, 12);
    _ = try clip_search.submit(dropped, "request zig", &.{}, 0);
    dropped.release();
    clip_search.cancel();
}

test "shutting down with a query being scored or answered is clean (MYP-613)" {
    const gpa = testing.allocator;
    for ([_]u64{ 0, 50 }) |wait_ms| {
        var probe: Probe = .{};
        defer probe.deinit();
        const clip_search = try start(gpa, testing.io, 200, &Probe.onResult, &probe);
        const corpus = try ClipFilter.testCorpus(gpa, 5000, 3);
        _ = try clip_search.submit(corpus, "cfg tok req", &.{}, 0);
        corpus.release();
        // Not delivered: an answer left on the main loop is dropped.
        if (wait_ms > 0) _ = std.os.linux.poll(&[0]std.os.linux.pollfd{}, 0, @intCast(wait_ms));
        clip_search.shutdown();
        probe.pump(5);
        try testing.expectEqual(@as(usize, 0), probe.results.items.len);
    }
}
