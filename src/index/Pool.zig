//! Parallel-for over a fixed set of worker threads: Zig's stand-in for the
//! rayon calls of the Rust index. `run(count, context, callback)` calls
//! `callback(context, i)` for every `i < count`, spread over the workers and
//! the calling thread, and returns when all are done. Workers sleep on a
//! futex between runs.
//!
//! Two pools exist in the service on purpose: searches get every core, the
//! background rescan only half. Measured in the Rust version, a rescan on all
//! cores starved the search thread (worst search 0.5 ms -> 16 ms).
//!
//! A run holds the pool until its last item is done, and other callers
//! wait: work that can take seconds (content verification, extraction) gets
//! pools of its own, or the name search waits behind it.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Pool = @This();

io: Io,
gpa: std.mem.Allocator,
threads: []std.Thread,
/// Bumped to wake the workers for a new run.
generation: std.atomic.Value(u32) = .init(0),
next: std.atomic.Value(u32) = .init(0),
done: std.atomic.Value(u32) = .init(0),
/// Workers that have finished the current generation. A run returns only
/// once every worker has, so none is still inside `work` (reading `total`,
/// `context`, `callback`) when the next run rewrites them.
acked: std.atomic.Value(u32) = .init(0),
total: u32 = 0,
context: *anyopaque = undefined,
callback: *const fn (*anyopaque, usize) void = undefined,
stopping: std.atomic.Value(bool) = .init(false),
/// Held by the run in progress: one run at a time.
run_lock: Io.Mutex = .init,

pub const CreateError = std.mem.Allocator.Error || std.Thread.SpawnError;

/// `workers` extra threads; 0 runs everything on the caller.
/// Thread-safe once created: `run` serializes concurrent callers.
pub fn create(gpa: std.mem.Allocator, io: Io, workers: usize) CreateError!*Pool {
    const pool = try gpa.create(Pool);
    errdefer gpa.destroy(pool);
    const threads = try gpa.alloc(std.Thread, workers);
    errdefer gpa.free(threads);
    pool.* = .{ .io = io, .gpa = gpa, .threads = threads };
    for (threads, 0..) |*thread, started_count| {
        thread.* = std.Thread.spawn(.{}, workerMain, .{pool}) catch |err| {
            pool.stop(threads[0..started_count]);
            return err;
        };
    }
    return pool;
}

/// Linux's limit for a thread name, without its NUL.
const thread_name_bytes_max = 15;
/// What `nameThreads` keeps of the prefix: room for "-" and four digits.
const thread_name_prefix_bytes_max = 10;

comptime {
    assert(thread_name_prefix_bytes_max + "-9999".len <= thread_name_bytes_max);
}

/// Names the workers "<prefix>-<n>", so CPU per thread can be told apart in
/// /proc and top.
pub fn nameThreads(pool: *Pool, prefix: []const u8) void {
    for (pool.threads, 0..) |thread, worker_index| {
        var name_text: [thread_name_bytes_max + 1]u8 = undefined;
        const name = std.mem.print(&name_text, "{s}-{d}", .{
            prefix[0..@min(prefix.len, thread_name_prefix_bytes_max)],
            worker_index,
        }) catch continue;
        // A thread without a name works the same; only `top` shows it.
        thread.setName(pool.io, name) catch {};
    }
}

/// Workers for background work: half the cores, the caller included (at
/// least the caller).
pub fn halfCores() usize {
    const cores_count = std.Thread.getCpuCount() catch 2;
    return @max(cores_count / 2, 1) - 1;
}

/// Workers for foreground work: every core, the caller included.
pub fn allCores() usize {
    const cores_count = std.Thread.getCpuCount() catch 2;
    return @max(cores_count, 1) - 1;
}

/// Stops and joins the workers, then frees the pool. No `run` may be in
/// progress.
pub fn destroy(pool: *Pool) void {
    pool.stop(pool.threads);
    const gpa = pool.gpa;
    gpa.free(pool.threads);
    pool.* = undefined;
    gpa.destroy(pool);
}

fn stop(pool: *Pool, started: []std.Thread) void {
    pool.stopping.store(true, .release);
    _ = pool.generation.fetchAdd(1, .release);
    pool.io.futexWake(u32, &pool.generation.raw, std.math.maxInt(u32));
    for (started) |thread| thread.join();
}

/// `run` over `count` items in blocks of `block_size`: `callback(context,
/// start, end)` for each.
pub fn runBlocks(
    pool: *Pool,
    count: usize,
    comptime block_size: usize,
    context: anytype,
    comptime callback: fn (@TypeOf(context), usize, usize) void,
) void {
    comptime assert(block_size > 0);
    const Blocks = struct {
        context: @TypeOf(context),
        count: usize,

        fn one(blocks: *const @This(), block_index: usize) void {
            const start = block_index * block_size;
            assert(start < blocks.count);
            const end = @min(start + block_size, blocks.count);
            callback(blocks.context, start, end);
        }
    };
    const blocks: Blocks = .{ .context = context, .count = count };
    const blocks_count = std.math.divCeil(usize, count, block_size) catch unreachable;
    pool.run(blocks_count, &blocks, Blocks.one);
}

/// Calls `callback(context, i)` for every `i < count` and returns when all
/// calls are done. Callers on other threads wait their turn.
pub fn run(
    pool: *Pool,
    count: usize,
    context: anytype,
    comptime callback: fn (@TypeOf(context), usize) void,
) void {
    if (count == 0) return;
    const Context = @TypeOf(context);
    const Erased = struct {
        fn call(context_erased: *anyopaque, i: usize) void {
            callback(@as(Context, @ptrCast(@alignCast(context_erased))), i);
        }
    };
    if (pool.threads.len == 0 or count == 1) {
        for (0..count) |i| callback(context, i);
        return;
    }
    // `total`, `next` and `done` are u32.
    assert(count <= std.math.maxInt(u32));
    pool.run_lock.lockUncancelable(pool.io);
    defer pool.run_lock.unlock(pool.io);

    pool.context = @ptrCast(@constCast(context));
    pool.callback = Erased.call;
    pool.total = @intCast(count);
    pool.done.store(0, .seq_cst);
    pool.next.store(0, .seq_cst);
    pool.acked.store(0, .seq_cst);
    _ = pool.generation.fetchAdd(1, .seq_cst);
    pool.io.futexWake(u32, &pool.generation.raw, std.math.maxInt(u32));

    pool.work();
    while (true) {
        const done_count = pool.done.load(.seq_cst);
        if (done_count == pool.total) break;
        assert(done_count < pool.total);
        pool.io.futexWaitUncancelable(u32, &pool.done.raw, done_count);
    }
    // Every worker wakes for every generation (none can skip one: the next
    // run waits here first), so this count always reaches the total.
    const workers: u32 = @intCast(pool.threads.len);
    while (true) {
        const acked_count = pool.acked.load(.seq_cst);
        if (acked_count == workers) break;
        assert(acked_count < workers);
        pool.io.futexWaitUncancelable(u32, &pool.acked.raw, acked_count);
    }
    // Every item was taken, and done once.
    assert(pool.next.load(.seq_cst) >= pool.total);
    assert(pool.done.load(.seq_cst) == pool.total);
}

fn work(pool: *Pool) void {
    while (true) {
        const item = pool.next.fetchAdd(1, .seq_cst);
        if (item >= pool.total) return;
        pool.callback(pool.context, item);
        if (pool.done.fetchAdd(1, .seq_cst) + 1 == pool.total) {
            pool.io.futexWake(u32, &pool.done.raw, 1);
        }
    }
}

fn workerMain(pool: *Pool) void {
    var seen: u32 = 0;
    while (true) {
        while (pool.generation.load(.acquire) == seen) {
            pool.io.futexWaitUncancelable(u32, &pool.generation.raw, seen);
        }
        seen = pool.generation.load(.acquire);
        if (pool.stopping.load(.acquire)) return;
        pool.work();
        if (pool.acked.fetchAdd(1, .seq_cst) + 1 == pool.threads.len) {
            pool.io.futexWake(u32, &pool.acked.raw, 1);
        }
    }
}

test "every index runs exactly once" {
    const pool = try Pool.create(std.testing.allocator, std.testing.io, 3);
    defer pool.destroy();
    var hits: [1000]std.atomic.Value(u32) = undefined;
    for (&hits) |*hit| hit.* = .init(0);
    for (0..20) |_| {
        pool.run(hits.len, &hits, struct {
            fn count(counts: *[1000]std.atomic.Value(u32), i: usize) void {
                _ = counts[i].fetchAdd(1, .monotonic);
            }
        }.count);
    }
    for (hits) |hit| try std.testing.expectEqual(@as(u32, 20), hit.load(.monotonic));
}

test "runs from two threads back to back never overlap" {
    // The pools are shared (UI and content search, two services): a worker
    // still finishing one run must not pick up indices of the next. Jobs of
    // different sizes: with equal ones a late worker's stale claim always
    // fails the bound check, and the race stays hidden.
    const pool = try Pool.create(std.testing.allocator, std.testing.io, 3);
    defer pool.destroy();
    const rounds = 3000;
    const Job = struct {
        hits: []std.atomic.Value(u32),
        fn count(job: *@This(), i: usize) void {
            _ = job.hits[i].fetchAdd(1, .monotonic);
        }
        fn loop(pool_shared: *Pool, job: *@This()) void {
            for (0..rounds) |_| pool_shared.run(job.hits.len, job, count);
        }
    };
    var small: [3]std.atomic.Value(u32) = @splat(.init(0));
    var big: [256]std.atomic.Value(u32) = @splat(.init(0));
    var small_job: Job = .{ .hits = &small };
    var big_job: Job = .{ .hits = &big };
    const thread = try std.Thread.spawn(.{}, Job.loop, .{ pool, &small_job });
    Job.loop(pool, &big_job);
    thread.join();
    for (small) |hit| try std.testing.expectEqual(@as(u32, rounds), hit.load(.monotonic));
    for (big) |hit| try std.testing.expectEqual(@as(u32, rounds), hit.load(.monotonic));
}
