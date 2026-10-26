//! Background service: keeps the index current without searches waiting on
//! anything (port of `service.rs`).
//!
//!   1. The index is searchable at once (a mapped snapshot, or empty on the
//!      very first run) and a rescan is always requested on start: a saved
//!      index is a photo, and nobody watched while Lumen was off.
//!   2. Watches are armed in batches, releasing the lock between batches.
//!   3. Waiting for events happens on the inotify fd *without* the lock.
//!   4. Rescans build outside the lock on half the cores; only the swap is
//!      locked (microseconds), and the old index is freed after unlocking.

const std = @import("std");
const Io = std.Io;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const scan = @import("scan.zig");
const engine = @import("search.zig");
const Pool = @import("Pool.zig");
const Watcher = @import("Watcher.zig");
const Live = @import("Live.zig");
const sys = @import("sys.zig");

const Service = @This();

const log = std.log.scoped(.files);

/// Watches per batch: ~2.3 us each, so a search waits ~4.6 ms at worst.
const arm_batch = 2_000;
/// How long the thread blocks on inotify before checking for `stop`.
const poll_ms = 100;
/// Pause between arming batches: without it the thread re-takes the lock at
/// once and a reader can starve for the whole arming (149 ms measured).
const arm_yield_us = 300;

gpa: std.mem.Allocator,
io: Io,
live: Live,
lock: Io.RwLock = .init,
stop: std.atomic.Value(bool) = .init(false),
thread: ?std.Thread = null,
search_pool: *Pool,
scan_pool: *Pool,
cfg: scan.Config,
roots: [1][]const u8,
cache_path: [:0]u8,
/// For `lumen --stats`, read from other threads.
rescans: std.atomic.Value(u32) = .init(0),
last_rescan_ns: std.atomic.Value(u64) = .init(0),

/// Starts on `root`, mapping `cache_path` if it exists. Thread-safe once
/// started: searches and `status` may come from any thread.
pub fn start(gpa: std.mem.Allocator, io: Io, root: []const u8, cache_path: []const u8) !*Service {
    const s = try gpa.create(Service);
    errdefer gpa.destroy(s);
    const root_copy = try gpa.dupe(u8, root);
    errdefer gpa.free(root_copy);
    const cache = try gpa.dupeZ(u8, cache_path);
    errdefer gpa.free(cache);
    const search_pool = try Pool.create(gpa, io, Pool.allCores());
    errdefer search_pool.destroy();
    const scan_pool = try Pool.create(gpa, io, Pool.halfCores());
    errdefer scan_pool.destroy();
    search_pool.nameThreads("lm-search");
    scan_pool.nameThreads("lm-scan");
    s.* = .{
        .gpa = gpa,
        .io = io,
        .live = undefined, // set below, once `cfg` has its final address
        .search_pool = search_pool,
        .scan_pool = scan_pool,
        .cfg = undefined,
        .roots = .{root_copy},
        .cache_path = cache,
    };
    s.cfg = .{ .roots = &s.roots };

    var base = Store.open(s.cache_path) catch blk: {
        var b: store_mod.Builder = .empty;
        break :blk try b.finish(gpa);
    };
    s.live = Live.initUnarmed(gpa, base, &s.cfg, s.cache_path, s.scan_pool) catch |err| {
        base.deinit(gpa);
        return err;
    };
    errdefer s.live.deinit();
    s.live.pending_resync = true;
    s.thread = try std.Thread.spawn(.{}, run, .{s});
    s.thread.?.setName(io, "lm-files") catch {};
    return s;
}

/// Stops the thread, saves what was learned if needed, frees everything.
/// The flush is what makes today's files still be there tomorrow.
pub fn shutdown(s: *Service) void {
    s.stop.store(true, .release);
    if (s.thread) |t| t.join();
    if (s.live.dirty or s.live.pending_resync) {
        if (Live.prepareCompaction(s.gpa, s.scan_pool, &s.cfg, s.cache_path)) |fresh| {
            if (s.live.adopt(fresh.base, fresh.watcher)) |old| freeReplaced(s.gpa, old) else |err| {
                log.warn("saving the file index: {t}", .{err});
                freeReplaced(s.gpa, fresh);
            }
        } else |err| log.warn("saving the file index: {t}", .{err});
    }
    s.live.deinit();
    s.search_pool.destroy();
    s.scan_pool.destroy();
    s.gpa.free(s.roots[0]);
    s.gpa.free(s.cache_path);
    s.gpa.destroy(s);
}

/// Top `limit` files for `query`; paths live in `arena`.
pub fn search(s: *Service, arena: std.mem.Allocator, query: []const u8, limit: usize, out: *std.ArrayList(Live.Hit)) !void {
    // Exclusive, not shared: a search mutates the engines' refinement cache.
    // Only the UI thread searches, so readers never queue behind each other.
    s.lock.lockUncancelable(s.io);
    defer s.lock.unlock(s.io);
    try s.live.search(arena, s.search_pool, query, .{ .limit = limit }, out);
}

pub const Status = struct { entries: usize, watches: usize, unwatched: u32 = 0, armed: bool, rescanning: bool, index_bytes: usize = 0, rescans: u32 = 0, last_rescan_ns: u64 = 0 };

pub fn status(s: *Service) Status {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    return .{
        // Live entries: the delta also holds scaffolding and its own graves.
        .entries = s.live.base.liveLen() + s.live.delta.liveLen(),
        .watches = s.live.stats.watches,
        .unwatched = s.live.watcher.unwatched,
        .armed = s.live.fullyArmed(),
        .rescanning = s.live.pending_resync,
        .index_bytes = s.live.base.buf.len + s.live.delta.buf.len,
        .rescans = s.rescans.load(.monotonic),
        .last_rescan_ns = s.last_rescan_ns.load(.monotonic),
    };
}

fn freeReplaced(gpa: std.mem.Allocator, old: Live.Replaced) void {
    var b = old.base;
    b.deinit(gpa);
    old.watcher.destroy(gpa);
}

fn rescan(s: *Service) void {
    const t0 = sys.monotonicNs();
    defer {
        s.last_rescan_ns.store(sys.monotonicNs() - t0, .monotonic);
        _ = s.rescans.fetchAdd(1, .monotonic);
        sys.trimHeap();
    }
    const fresh = Live.prepareCompaction(s.gpa, s.scan_pool, &s.cfg, s.cache_path) catch |err| {
        log.warn("rescan: {t}", .{err});
        // Clear the request so a failing rescan does not spin the CPU.
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        s.live.pending_resync = false;
        return;
    };
    const old = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        break :blk s.live.adopt(fresh.base, fresh.watcher);
    };
    // Outside the lock: closing tens of thousands of watches is kernel time
    // no search should pay.
    if (old) |o| freeReplaced(s.gpa, o) else |err| {
        log.warn("rescan: {t}", .{err});
        freeReplaced(s.gpa, fresh);
    }
}

fn run(s: *Service) void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    while (!s.stop.load(.acquire)) {
        // A pending rescan goes first: arming watches on an index about to be
        // replaced is wasted work.
        s.lock.lockSharedUncancelable(s.io);
        const resync = s.live.pending_resync;
        s.lock.unlockShared(s.io);
        if (resync) {
            s.rescan();
            continue;
        }

        // Phase 1: finish arming, yielding the index between batches.
        s.lock.lockUncancelable(s.io);
        const more = s.live.armProgress(arm_batch);
        s.lock.unlock(s.io);
        if (more) {
            sys.sleepUs(arm_yield_us);
            continue;
        }

        // Phase 2: wait for events without holding the index.
        s.lock.lockSharedUncancelable(s.io);
        const fd = s.live.watcher.fd;
        s.lock.unlockShared(s.io);
        if (!sys.waitReadable(fd, poll_ms)) continue;

        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var changes: std.ArrayList(Watcher.Change) = .empty;
        const needs = blk: {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            // Events drained from the kernel and then lost would leave the
            // index wrong for good: a failure asks for a rescan instead.
            s.live.watcher.drain(arena, &changes) catch |err| {
                log.warn("reading file events: {t}", .{err});
                s.live.pending_resync = true;
            };
            _ = s.live.apply(changes.items) catch |err| {
                log.warn("applying file events: {t}", .{err});
                s.live.pending_resync = true;
            };
            break :blk s.live.pending_resync or s.live.needsCompaction();
        };
        if (needs) s.rescan();
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn touch(dir: []const u8, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const p = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    try sys.writeFile(p, "x");
}

fn waitFor(s: *Service, arena: std.mem.Allocator, query: []const u8, want: bool) !bool {
    var hits: std.ArrayList(Live.Hit) = .empty;
    for (0..300) |_| {
        try s.search(arena, query, 10, &hits);
        if ((hits.items.len > 0) == want) return true;
        sys.sleepUs(10_000);
    }
    return false;
}

test "live: new, nested and deleted files show up without a rescan" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rel_buf: [4096]u8 = undefined;
    const rel = try sys.tmpDirPath(&tmp, &rel_buf);
    var cwd_buf: [4096]u8 = undefined;
    const cwd_rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd = std.mem.sliceTo(cwd_buf[0..cwd_rc], 0);
    var abs_buf: [4096]u8 = undefined;
    const abs = try std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ cwd, rel });
    try touch(abs, "first_note.md");

    var idx_buf: [4096]u8 = undefined;
    const idx = try std.fmt.bufPrint(&idx_buf, "{s}/../lumen-test-{s}.idx", .{ abs, tmp.sub_path });
    const s = try Service.start(gpa, testing.io, abs, idx);
    defer s.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The initial rescan finds what was there.
    try testing.expect(try waitFor(s, arena, "first_note", true));
    while (!s.status().armed or s.status().rescanning) sys.sleepUs(5_000);

    // A new file arrives through inotify.
    try touch(abs, "zebra_quarterly.txt");
    try testing.expect(try waitFor(s, arena, "zebra_quarterly", true));

    // A new directory with content inside (scanned whole on creation).
    var dbuf: [4096]u8 = undefined;
    const sub = try std.fmt.bufPrintSentinel(&dbuf, "{s}/fresh_dir", .{abs}, 0);
    _ = std.os.linux.mkdir(sub, 0o755);
    try touch(sub, "inner_walrus.txt");
    try testing.expect(try waitFor(s, arena, "inner_walrus", true));

    // Deleting the base file and the delta file removes both.
    var fbuf: [4096]u8 = undefined;
    _ = std.os.linux.unlink(try std.fmt.bufPrintSentinel(&fbuf, "{s}/first_note.md", .{abs}, 0));
    try testing.expect(try waitFor(s, arena, "first_note", false));
    _ = std.os.linux.unlink(try std.fmt.bufPrintSentinel(&fbuf, "{s}/inner_walrus.txt", .{sub}, 0));
    try testing.expect(try waitFor(s, arena, "inner_walrus", false));

    var cbuf: [4096]u8 = undefined;
    _ = std.os.linux.unlink(try std.fmt.bufPrintSentinel(&cbuf, "{s}", .{idx}, 0));
}

/// Absolute path of a testing tmp dir.
fn tmpAbs(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.mem.sliceTo(cwd_buf[0..std.os.linux.getcwd(&cwd_buf, cwd_buf.len)], 0);
    var rel_buf: [4096]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ cwd, try sys.tmpDirPath(tmp, &rel_buf) });
}

/// Waits until the thread has nothing pending: armed and not rescanning.
fn settle(s: *Service) !void {
    for (0..2_000) |_| {
        const st = s.status();
        if (st.armed and !st.rescanning) return;
        sys.sleepUs(5_000);
    }
    return error.NeverSettled;
}

fn has(s: *Service, arena: std.mem.Allocator, query: []const u8, suffix: []const u8) !bool {
    var hits: std.ArrayList(Live.Hit) = .empty;
    try s.search(arena, query, 50, &hits);
    for (hits.items) |h| if (std.mem.endsWith(u8, h.path, suffix)) return true;
    return false;
}

fn waitHas(s: *Service, arena: std.mem.Allocator, query: []const u8, suffix: []const u8) !bool {
    for (0..500) |_| {
        if (try has(s, arena, query, suffix)) return true;
        sys.sleepUs(10_000);
    }
    return false;
}

fn mkdirAbs(dir: []const u8, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    _ = std.os.linux.mkdir(try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0), 0o755);
}

test "service: a flooded queue ends in a rescan that finds everything" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var qbuf: [32]u8 = undefined;
    const max_queued = std.fmt.parseInt(usize, std.mem.trim(u8, sys.readHead("/proc/sys/fs/inotify/max_queued_events", &qbuf), " \n"), 10) catch 16384;
    if (max_queued > 100_000) return error.SkipZigTest;

    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.fmt.bufPrint(&rbuf, "{s}/root", .{dir});
    try mkdirAbs(root, "flood");
    var ibuf: [4096]u8 = undefined;
    const s = try Service.start(gpa, testing.io, root, try std.fmt.bufPrint(&ibuf, "{s}/files.idx", .{dir}));
    defer s.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try settle(s);
    const rescans = s.status().rescans;

    // Holding the index stalls the thread before it drains: the queue
    // overflows for real.
    var fbuf: [4096]u8 = undefined;
    const flood = try std.fmt.bufPrint(&fbuf, "{s}/flood", .{root});
    const n = max_queued + 1_000;
    s.lock.lockUncancelable(s.io);
    for (0..n) |i| {
        var nb: [32]u8 = undefined;
        touch(flood, try std.fmt.bufPrint(&nb, "n{d:0>5}.txt", .{i})) catch |e| {
            s.lock.unlock(s.io);
            return e;
        };
    }
    s.lock.unlock(s.io);

    for (0..2_000) |_| {
        if (s.status().rescans > rescans) break;
        sys.sleepUs(5_000);
    }
    try settle(s);
    s.lock.lockSharedUncancelable(s.io);
    const resyncs = s.live.stats.resyncs;
    s.lock.unlockShared(s.io);
    try testing.expect(resyncs >= 1);
    try testing.expect(s.status().entries >= n + 2);
    try testing.expect(try has(s, arena, "n00000", "/flood/n00000.txt"));
    try testing.expect(try has(s, arena, "n08191", "/flood/n08191.txt"));
    var last: [32]u8 = undefined;
    try testing.expect(try has(s, arena, try std.fmt.bufPrint(&last, "n{d:0>5}", .{n - 1}), try std.fmt.allocPrint(arena, "/flood/n{d:0>5}.txt", .{n - 1})));
}

test "service: files created while the first rescan runs are not lost" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.fmt.bufPrint(&rbuf, "{s}/root", .{dir});
    // Enough to keep the scan busy a few levels deep.
    for (0..40) |i| {
        var p: [4096]u8 = undefined;
        const sub = try std.fmt.bufPrint(&p, "{s}/d{d}", .{ root, i });
        sys.mkdirP(sub);
        var q: [4096]u8 = undefined;
        sys.mkdirP(try std.fmt.bufPrint(&q, "{s}/deep/deeper", .{sub}));
        for (0..40) |j| {
            var nb: [32]u8 = undefined;
            try touch(sub, try std.fmt.bufPrint(&nb, "old_{d}.txt", .{j}));
        }
    }
    var ibuf: [4096]u8 = undefined;
    const s = try Service.start(gpa, testing.io, root, try std.fmt.bufPrint(&ibuf, "{s}/files.idx", .{dir}));
    defer s.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Right away, while the thread scans: before, during and after each
    // directory is read.
    const n = 200;
    for (0..n) |i| {
        var p: [4096]u8 = undefined;
        var nb: [32]u8 = undefined;
        try touch(try std.fmt.bufPrint(&p, "{s}/d{d}/deep/deeper", .{ root, i % 40 }), try std.fmt.bufPrint(&nb, "late_{d}.txt", .{i}));
    }
    try settle(s);
    for (0..n) |i| {
        const q = try std.fmt.allocPrint(arena, "late_{d}", .{i});
        const want = try std.fmt.allocPrint(arena, "/d{d}/deep/deeper/late_{d}.txt", .{ i % 40, i });
        try testing.expect(try waitHas(s, arena, q, want));
    }
}

test "service: shutdown saves what was learned and the next start maps it" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.fmt.bufPrint(&rbuf, "{s}/root", .{dir});
    try touch(root, "Cargo.toml");
    var ibuf: [4096]u8 = undefined;
    const idx = try std.fmt.bufPrintSentinel(&ibuf, "{s}/files.idx", .{dir}, 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        const s = try Service.start(gpa, testing.io, root, idx);
        defer s.shutdown();
        try settle(s);
        try touch(root, "de_la_sesion.rs");
        try testing.expect(try waitHas(s, arena, "de_la_sesion", "/de_la_sesion.rs"));
        // Learned through inotify only: in the delta, not yet in the file.
        s.lock.lockSharedUncancelable(s.io);
        const dirty = s.live.dirty;
        s.lock.unlockShared(s.io);
        try testing.expect(dirty);
    }

    // The file alone has it.
    var saved = try Store.open(idx);
    defer saved.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 0);
    defer pool.destroy();
    var e: engine.Engine = .empty;
    defer e.deinit(gpa);
    var hits: std.ArrayList(engine.Hit) = .empty;
    defer hits.deinit(gpa);
    try e.search(gpa, pool, &saved, "de_la_sesion", .{ .limit = 10, .recency = false }, &hits);
    var pbuf: [4096]u8 = undefined;
    try testing.expect(hits.items.len > 0 and std.mem.endsWith(u8, saved.path(hits.items[0].id, &pbuf), "/de_la_sesion.rs"));

    // And a new start finds it on its first search, before any rescan.
    const s2 = try Service.start(gpa, testing.io, root, idx);
    defer s2.shutdown();
    try testing.expect(try has(s2, arena, "de_la_sesion", "/de_la_sesion.rs"));
}

test "service: the delta threshold triggers a compaction" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.fmt.bufPrint(&rbuf, "{s}/root", .{dir});
    var ibuf: [4096]u8 = undefined;
    const s = try Service.start(gpa, testing.io, root, try std.fmt.bufPrint(&ibuf, "{s}/files.idx", .{dir}));
    defer s.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try settle(s);

    s.lock.lockUncancelable(s.io);
    s.live.limits.delta_max = 3;
    s.lock.unlock(s.io);
    const rescans = s.status().rescans;
    for (0..5) |i| {
        var nb: [32]u8 = undefined;
        try touch(root, try std.fmt.bufPrint(&nb, "umbral_{d}.txt", .{i}));
    }
    for (0..1_000) |_| {
        if (s.status().rescans > rescans) break;
        sys.sleepUs(5_000);
    }
    try settle(s);
    try testing.expect(s.status().rescans > rescans);
    for (0..5) |i| {
        const q = try std.fmt.allocPrint(arena, "umbral_{d}", .{i});
        try testing.expect(try waitHas(s, arena, q, try std.fmt.allocPrint(arena, "/umbral_{d}.txt", .{i})));
    }
    s.lock.lockSharedUncancelable(s.io);
    const delta_live = s.live.delta.liveLen();
    s.lock.unlockShared(s.io);
    try testing.expect(delta_live < 5);
}
