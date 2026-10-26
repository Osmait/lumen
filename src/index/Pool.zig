//! Parallel-for over a fixed set of worker threads: Zig's stand-in for the
//! rayon calls of the Rust index. `run(n, ctx, f)` calls `f(ctx, i)` for every
//! `i < n`, spread over the workers and the calling thread, and returns when
//! all are done. Workers sleep on a futex between runs.
//!
//! Two pools exist in the service on purpose: searches get every core, the
//! background rescan only half. Measured in the Rust version, a rescan on all
//! cores starved the search thread (worst search 0.5 ms -> 16 ms).

const std = @import("std");
const Io = std.Io;

const Pool = @This();

io: Io,
gpa: std.mem.Allocator,
threads: []std.Thread,
/// Bumped to wake the workers for a new run.
generation: std.atomic.Value(u32) = .init(0),
next: std.atomic.Value(u32) = .init(0),
done: std.atomic.Value(u32) = .init(0),
total: u32 = 0,
ctx: *anyopaque = undefined,
func: *const fn (*anyopaque, usize) void = undefined,
stopping: std.atomic.Value(bool) = .init(false),
/// One run at a time.
run_lock: Io.Mutex = .init,

/// `workers` extra threads; 0 runs everything on the caller.
pub fn create(gpa: std.mem.Allocator, io: Io, workers: usize) !*Pool {
    const pool = try gpa.create(Pool);
    pool.* = .{ .io = io, .gpa = gpa, .threads = try gpa.alloc(std.Thread, workers) };
    for (pool.threads, 0..) |*t, i| {
        t.* = std.Thread.spawn(.{}, workerMain, .{pool}) catch |err| {
            pool.threads = pool.threads[0..i];
            pool.destroy();
            return err;
        };
    }
    return pool;
}

/// Names the workers "<prefix>-<n>" (15 bytes max, Linux's limit), so CPU
/// per thread can be told apart in /proc and top.
pub fn nameThreads(pool: *Pool, prefix: []const u8) void {
    for (pool.threads, 0..) |t, i| {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}-{d}", .{ prefix[0..@min(prefix.len, 10)], i }) catch continue;
        t.setName(pool.io, name) catch {};
    }
}

/// Half the cores (at least one thread in total): for background work.
pub fn halfCores() usize {
    const n = std.Thread.getCpuCount() catch 2;
    return @max(n / 2, 1) - 1;
}

/// Every core: the caller plus one worker per remaining core.
pub fn allCores() usize {
    const n = std.Thread.getCpuCount() catch 2;
    return @max(n, 1) - 1;
}

pub fn destroy(pool: *Pool) void {
    pool.stopping.store(true, .release);
    _ = pool.generation.fetchAdd(1, .release);
    pool.io.futexWake(u32, &pool.generation.raw, std.math.maxInt(u32));
    for (pool.threads) |t| t.join();
    const all = pool.threads.ptr[0..pool.threads.len];
    pool.gpa.free(all);
    pool.gpa.destroy(pool);
}

pub fn run(pool: *Pool, n: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize) void) void {
    if (n == 0) return;
    const Ctx = @TypeOf(ctx);
    const Wrap = struct {
        fn call(p: *anyopaque, i: usize) void {
            f(@as(Ctx, @ptrCast(@alignCast(p))), i);
        }
    };
    if (pool.threads.len == 0 or n == 1) {
        for (0..n) |i| f(ctx, i);
        return;
    }
    pool.run_lock.lockUncancelable(pool.io);
    defer pool.run_lock.unlock(pool.io);

    pool.ctx = @ptrCast(@constCast(ctx));
    pool.func = Wrap.call;
    pool.total = @intCast(n);
    pool.done.store(0, .seq_cst);
    pool.next.store(0, .seq_cst);
    _ = pool.generation.fetchAdd(1, .seq_cst);
    pool.io.futexWake(u32, &pool.generation.raw, std.math.maxInt(u32));

    pool.work();
    while (true) {
        const d = pool.done.load(.seq_cst);
        if (d == pool.total) break;
        pool.io.futexWaitUncancelable(u32, &pool.done.raw, d);
    }
}

fn work(pool: *Pool) void {
    while (true) {
        const i = pool.next.fetchAdd(1, .seq_cst);
        if (i >= pool.total) return;
        pool.func(pool.ctx, i);
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
    }
}

test "every index runs exactly once" {
    const pool = try Pool.create(std.testing.allocator, std.testing.io, 3);
    defer pool.destroy();
    var hits: [1000]std.atomic.Value(u32) = undefined;
    for (&hits) |*h| h.* = .init(0);
    for (0..20) |_| {
        pool.run(hits.len, &hits, struct {
            fn f(h: *[1000]std.atomic.Value(u32), i: usize) void {
                _ = h[i].fetchAdd(1, .monotonic);
            }
        }.f);
    }
    for (hits) |h| try std.testing.expectEqual(@as(u32, 20), h.load(.monotonic));
}
