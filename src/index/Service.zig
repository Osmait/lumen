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
const sys = @import("os");

const Service = @This();

const log = std.log.scoped(.files);

/// Watches per batch: ~2.3 us each, so a search waits ~4.6 ms at worst.
const arm_batch = 2_000;
/// No eventfd for `shutdown` (`wake_fd`): the thread then waits at most
/// 100 ms at a time on inotify, to look at `stop`.
const no_fd: i32 = -1;
/// Pause between arming batches: without it the thread re-takes the lock at
/// once and a reader can starve for the whole arming (149 ms measured).
const arm_yield_us = 300;
/// A rescan asked for soon after the last one waits, twice as long as the
/// previous wait, from 1 s up to a minute. Under heavy churn every rescan
/// overflowed the queue while it ran and asked for the next one at once: a
/// loop rewriting the index file.
const backoff_min_ns = 1 * std.time.ns_per_s;
const backoff_max_ns = 60 * std.time.ns_per_s;

gpa: std.mem.Allocator,
io: Io,
live: Live,
lock: Io.RwLock = .init,
stop: std.atomic.Value(bool) = .init(false),
/// Written by `shutdown`: the thread waits on inotify and this, with no
/// timeout (it used to wake every 100 ms to look at `stop`).
wake_fd: i32 = no_fd,
thread: ?std.Thread = null,
search_pool: *Pool,
scan_pool: *Pool,
/// Lent to the content index (`ContentService.Pools`), never used here.
/// It had the two above: its verification and extraction hold a pool for
/// seconds (an extractor may run 15 s), and the UI's name search, or the
/// event thread holding the lock it waits on, queued behind them (950 ms
/// measured).
content_search_pool: *Pool,
content_build_pool: *Pool,
cfg: scan.Config,
roots: [1][]const u8,
cache_path: [:0]u8,
/// Names created, removed or moved outside hidden files and directories,
/// and anything uncertain (a queue overflow, a rescan): the content service
/// lists files again only when this moved. Idle, a home sees name changes
/// all the time, but in .cache and .config (120 in 90 s, none elsewhere).
name_changes: std.atomic.Value(u64) = .init(0),
/// For `lumen --stats`, read from other threads.
rescans: std.atomic.Value(u32) = .init(0),
last_rescan_ns: std.atomic.Value(u64) = .init(0),
/// The service thread's own: when the last rescan ended, and how long the
/// last one asked for soon after it waited (see `backoff_min_ns`).
last_rescan_end_ns: ?u64 = null,
backoff_ns: u64 = 0,

pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError ||
    Watcher.CreateError;

/// Starts on `root`, mapping `cache_path` if it exists. Thread-safe once
/// started: searches and `status` may come from any thread.
pub fn start(
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    cache_path: []const u8,
) StartError!*Service {
    const service = try gpa.create(Service);
    errdefer gpa.destroy(service);
    const root_copy = try gpa.dupe(u8, root);
    errdefer gpa.free(root_copy);
    const cache = try gpa.dupeSentinel(u8, cache_path, 0);
    errdefer gpa.free(cache);
    const search_pool = try Pool.create(gpa, io, Pool.allCores());
    errdefer search_pool.destroy();
    const scan_pool = try Pool.create(gpa, io, Pool.halfCores());
    errdefer scan_pool.destroy();
    const content_search_pool = try Pool.create(gpa, io, Pool.allCores());
    errdefer content_search_pool.destroy();
    const content_build_pool = try Pool.create(gpa, io, Pool.halfCores());
    errdefer content_build_pool.destroy();
    search_pool.nameThreads("lm-search");
    scan_pool.nameThreads("lm-scan");
    content_search_pool.nameThreads("lm-csearch");
    content_build_pool.nameThreads("lm-cbuild");
    service.* = .{
        .gpa = gpa,
        .io = io,
        // Set below, once `cfg` has its final address.
        .live = undefined,
        .search_pool = search_pool,
        .scan_pool = scan_pool,
        .content_search_pool = content_search_pool,
        .content_build_pool = content_build_pool,
        .cfg = undefined,
        .roots = .{root_copy},
        .cache_path = cache,
    };
    service.cfg = .{ .roots = &service.roots };

    var base = Store.open(service.cache_path) catch blk: {
        var empty: store_mod.Builder = .empty;
        break :blk try empty.finish(gpa);
    };
    service.live = Live.initUnarmed(
        gpa,
        base,
        &service.cfg,
        service.cache_path,
        service.scan_pool,
    ) catch |err| {
        base.deinit(gpa);
        return err;
    };
    errdefer service.live.deinit();
    service.live.pending_resync = true;
    const event_fd = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    // Without one, `pause` looks at `stop` every 100 ms instead.
    if (std.os.linux.errno(event_fd) == .SUCCESS) service.wake_fd = @intCast(event_fd);
    errdefer if (service.wake_fd != no_fd) sys.close(service.wake_fd);
    service.thread = try std.Thread.spawn(.{}, run, .{service});
    // A thread without a name works the same; only `top` shows it.
    service.thread.?.setName(io, "lm-files") catch {};
    return service;
}

/// Stops the thread, saves what was learned if needed, frees everything.
/// The flush is what makes today's files still be there tomorrow.
pub fn shutdown(service: *Service) void {
    service.stop.store(true, .release);
    if (service.wake_fd != no_fd) {
        const one: u64 = 1;
        _ = std.os.linux.write(service.wake_fd, std.mem.asBytes(&one), 8);
    }
    if (service.thread) |thread| thread.join();
    if (service.wake_fd != no_fd) sys.close(service.wake_fd);
    if (service.live.dirty or service.live.pending_resync) service.saveOnShutdown();
    service.live.deinit();
    service.search_pool.destroy();
    service.scan_pool.destroy();
    service.content_search_pool.destroy();
    service.content_build_pool.destroy();
    service.gpa.free(service.roots[0]);
    service.gpa.free(service.cache_path);
    service.gpa.destroy(service);
}

/// Top `limit` files for `query`; paths live in `arena`.
pub fn search(
    service: *Service,
    arena: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    out: *std.ArrayList(Live.Hit),
) std.mem.Allocator.Error!void {
    // Exclusive, not shared: a search mutates the engines' refinement cache.
    // Only the UI thread searches, so readers never queue behind each other.
    service.lock.lockUncancelable(service.io);
    defer service.lock.unlock(service.io);
    try service.live.search(arena, service.search_pool, query, .{ .limit = limit }, out);
}

pub const Status = struct {
    entries: usize,
    watches: usize,
    unwatched: u32 = 0,
    armed: bool,
    rescanning: bool,
    index_bytes: usize = 0,
    rescans: u32 = 0,
    last_rescan_ns: u64 = 0,
};

pub fn status(service: *Service) Status {
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    return .{
        // Live entries: the delta also holds scaffolding and its own graves.
        .entries = service.live.base.liveLen() + service.live.delta.store.liveLen(),
        .watches = service.live.stats.watches,
        .unwatched = service.live.watcher.unwatched,
        .armed = service.live.fullyArmed(),
        .rescanning = service.live.pending_resync,
        .index_bytes = service.live.base.buf.len + service.live.delta.store.buf.len,
        .rescans = service.rescans.load(.monotonic),
        .last_rescan_ns = service.last_rescan_ns.load(.monotonic),
    };
}

/// What `shutdown` saves: a fresh scan, adopted as a rescan would.
fn saveOnShutdown(service: *Service) void {
    const fresh = service.prepareCompaction() catch |err| {
        log.warn("saving the file index: {t}", .{err});
        return;
    };
    const old = service.live.adopt(fresh.base, fresh.watcher) catch |err| {
        log.warn("saving the file index: {t}", .{err});
        freeReplaced(service.gpa, fresh);
        return;
    };
    freeReplaced(service.gpa, old);
}

fn prepareCompaction(service: *Service) !Live.Replaced {
    return Live.prepareCompaction(service.gpa, service.scan_pool, &service.cfg, service.cache_path);
}

fn freeReplaced(gpa: std.mem.Allocator, old: Live.Replaced) void {
    var base = old.base;
    base.deinit(gpa);
    old.watcher.destroy(gpa);
}

/// `name_changes`, or null while it cannot be trusted: watches not all
/// armed yet, or directories left unwatched (the inotify limit).
pub fn nameChanges(service: *Service) ?u64 {
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    if (!service.live.fullyArmed() or service.live.watcher.unwatched > 0) return null;
    return service.name_changes.load(.acquire);
}

/// Whether a change may concern the content index (see `name_changes`).
/// Under the lock, before the change is applied (its parent id resolves).
fn concernsContent(service: *Service, change: Watcher.Change) bool {
    const parent: u32, const name: []const u8 = switch (change) {
        .created => |created| .{ created.parent, created.name },
        .removed => |removed| .{ removed.parent, removed.name },
        else => return true,
    };
    if (name.len > 0 and name[0] == '.') return false;
    var buf: [4096]u8 = undefined;
    const dir = service.live.pathOf(parent, &buf) orelse return true;
    const root = service.roots[0];
    const relative = if (std.mem.startsWith(u8, dir, root)) dir[root.len..] else dir;
    var parts = std.mem.tokenizeScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (part[0] == '.') return false;
    }
    return true;
}

/// How long a rescan asked for `since_ns` after the last one ended waits,
/// `previous_ns` being the previous wait: nothing after a quiet minute,
/// else twice that.
fn backoffFor(previous_ns: u64, since_ns: u64) u64 {
    if (since_ns >= backoff_max_ns) return 0;
    return std.math.clamp(previous_ns *| 2, backoff_min_ns, backoff_max_ns);
}

/// Sleeps `duration_ns`, or less if `shutdown` is called: false then.
fn pause(service: *Service, duration_ns: u64) bool {
    const deadline_ns = sys.monotonicNs() +| duration_ns;
    while (!service.stop.load(.acquire)) {
        const left_ns = deadline_ns -| sys.monotonicNs();
        if (left_ns == 0) return true;
        // `shutdown` writes the eventfd and nothing reads it: once written
        // it stays readable. Without one, a look at `stop` every 100 ms.
        const slice_ms: i32 = @intCast(@min(left_ns / std.time.ns_per_ms + 1, 100));
        if (service.wake_fd != no_fd) {
            _ = sys.waitReadable(service.wake_fd, slice_ms);
        } else {
            sys.sleepUs(@as(u64, @intCast(slice_ms)) * std.time.us_per_ms);
        }
    }
    return false;
}

fn rescan(service: *Service) void {
    if (service.last_rescan_end_ns) |end_ns| {
        const since_ns = sys.monotonicNs() -| end_ns;
        service.backoff_ns = backoffFor(service.backoff_ns, since_ns);
        if (service.backoff_ns > since_ns) {
            // Stopping: the request stays, `shutdown` rescans.
            if (!service.pause(service.backoff_ns - since_ns)) return;
        }
    }
    const start_ns = sys.monotonicNs();
    // Nobody can tell what changed while the index is rebuilt.
    defer _ = service.name_changes.fetchAdd(1, .release);
    defer {
        const end_ns = sys.monotonicNs();
        service.last_rescan_end_ns = end_ns;
        service.last_rescan_ns.store(end_ns - start_ns, .monotonic);
        _ = service.rescans.fetchAdd(1, .monotonic);
        @import("root.zig").trimHeap();
    }
    const fresh = service.prepareCompaction() catch |err| {
        log.warn("rescan: {t}", .{err});
        // Clear the request so a failing rescan does not spin the CPU.
        service.lock.lockUncancelable(service.io);
        defer service.lock.unlock(service.io);
        service.live.pending_resync = false;
        return;
    };
    const old = blk: {
        service.lock.lockUncancelable(service.io);
        defer service.lock.unlock(service.io);
        break :blk service.live.adopt(fresh.base, fresh.watcher);
    };
    // Outside the lock: closing tens of thousands of watches is kernel time
    // no search should pay.
    if (old) |replaced| {
        freeReplaced(service.gpa, replaced);
    } else |err| {
        log.warn("rescan: {t}", .{err});
        freeReplaced(service.gpa, fresh);
    }
}

/// Drains and applies what inotify reported; true if a rescan is due.
fn applyEvents(service: *Service, arena: std.mem.Allocator) bool {
    var scans: Live.Scans = .empty;
    var entries_max: usize = 0;
    {
        service.lock.lockUncancelable(service.io);
        defer service.lock.unlock(service.io);
        var changes: std.ArrayList(Watcher.Change) = .empty;
        // Events drained from the kernel and then lost would leave the
        // index wrong for good: a failure asks for a rescan instead.
        service.live.watcher.drain(arena, &changes) catch |err| {
            log.warn("reading file events: {t}", .{err});
            service.live.pending_resync = true;
        };
        for (changes.items) |change| {
            if (!service.concernsContent(change)) continue;
            _ = service.name_changes.fetchAdd(1, .release);
            break;
        }
        _ = service.live.apply(changes.items) catch |err| {
            log.warn("applying file events: {t}", .{err});
            service.live.pending_resync = true;
        };
        if (service.live.scans.items.len == 0) return service.rescanDue();
        scans = service.live.takeScans();
        entries_max = service.live.limits.delta_max;
    }
    // New directories are read without the lock: a large tree moved in
    // held it, and every search with it, for as long as reading took.
    Live.readScans(service.gpa, service.scan_pool, &service.cfg, scans.items, entries_max);
    service.lock.lockUncancelable(service.io);
    defer service.lock.unlock(service.io);
    service.live.addScans(&scans) catch |err| {
        log.warn("applying file events: {t}", .{err});
        service.live.pending_resync = true;
    };
    return service.rescanDue();
}

/// Under the lock.
fn rescanDue(service: *const Service) bool {
    if (service.live.pending_resync) return true;
    return service.live.needsCompaction();
}

fn run(service: *Service) void {
    var arena_state: std.heap.ArenaAllocator = .init(service.gpa);
    defer arena_state.deinit();
    while (!service.stop.load(.acquire)) {
        // A pending rescan goes first: arming watches on an index about to be
        // replaced is wasted work.
        service.lock.lockSharedUncancelable(service.io);
        const resync = service.live.pending_resync;
        service.lock.unlockShared(service.io);
        if (resync) {
            service.rescan();
            continue;
        }

        // Phase 1: finish arming, yielding the index between batches.
        service.lock.lockUncancelable(service.io);
        const more = service.live.armProgress(arm_batch);
        service.lock.unlock(service.io);
        if (more) {
            sys.sleepUs(arm_yield_us);
            continue;
        }

        // Phase 2: wait for events without holding the index.
        service.lock.lockSharedUncancelable(service.io);
        const fd = service.live.watcher.fd;
        service.lock.unlockShared(service.io);
        if (!sys.waitEvents(fd, service.wake_fd)) continue;

        _ = arena_state.reset(.retain_capacity);
        if (service.applyEvents(arena_state.allocator())) service.rescan();
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn touch(dir: []const u8, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const p = try std.mem.printSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    try sys.writeFile(p, "x");
}

/// Ceilings, not expectations: the whole test suite runs at once, every
/// test with its own thread pool, and a loaded machine is slow.
const wait_tries = 1000;

fn waitFor(service: *Service, arena: std.mem.Allocator, query: []const u8, want: bool) !bool {
    var hits: std.ArrayList(Live.Hit) = .empty;
    for (0..wait_tries) |_| {
        try service.search(arena, query, 10, &hits);
        if ((hits.items.len > 0) == want) return true;
        sys.sleepUs(10_000);
    }
    return false;
}

test "live: new, nested and deleted files show up without a rescan" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var abs_buf: [4096]u8 = undefined;
    const abs = try sys.tmpDirAbs(&tmp, &abs_buf);
    try touch(abs, "first_note.md");

    var idx_buf: [4096]u8 = undefined;
    const idx = try std.mem.print(&idx_buf, "{s}/../lumen-test-{s}.idx", .{ abs, tmp.sub_path });
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
    const sub = try std.mem.printSentinel(&dbuf, "{s}/fresh_dir", .{abs}, 0);
    _ = std.os.linux.mkdir(sub, 0o755);
    try touch(sub, "inner_walrus.txt");
    try testing.expect(try waitFor(s, arena, "inner_walrus", true));

    // Deleting the base file and the delta file removes both.
    var fbuf: [4096]u8 = undefined;
    _ = std.os.linux.unlink(try std.mem.printSentinel(&fbuf, "{s}/first_note.md", .{abs}, 0));
    try testing.expect(try waitFor(s, arena, "first_note", false));
    _ = std.os.linux.unlink(try std.mem.printSentinel(&fbuf, "{s}/inner_walrus.txt", .{sub}, 0));
    try testing.expect(try waitFor(s, arena, "inner_walrus", false));

    var cbuf: [4096]u8 = undefined;
    _ = std.os.linux.unlink(try std.mem.printSentinel(&cbuf, "{s}", .{idx}, 0));
}

const tmpAbs = sys.tmpDirAbs;

/// Waits until the thread has nothing pending: armed and not rescanning.
fn settle(service: *Service) !void {
    for (0..wait_tries) |_| {
        const st = service.status();
        if (st.armed and !st.rescanning) return;
        sys.sleepUs(20_000);
    }
    return error.NeverSettled;
}

fn has(service: *Service, arena: std.mem.Allocator, query: []const u8, suffix: []const u8) !bool {
    var hits: std.ArrayList(Live.Hit) = .empty;
    try service.search(arena, query, 50, &hits);
    for (hits.items) |h| if (std.mem.endsWith(u8, h.path, suffix)) return true;
    return false;
}

fn waitHas(
    service: *Service,
    arena: std.mem.Allocator,
    query: []const u8,
    suffix: []const u8,
) !bool {
    for (0..wait_tries) |_| {
        if (try has(service, arena, query, suffix)) return true;
        sys.sleepUs(10_000);
    }
    return false;
}

fn mkdirAbs(dir: []const u8, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    _ = std.os.linux.mkdir(try std.mem.printSentinel(&buf, "{s}/{s}", .{ dir, name }, 0), 0o755);
}

test "service: a flooded queue ends in a rescan that finds everything" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var qbuf: [32]u8 = undefined;
    const queued_max = std.fmt.parseInt(
        usize,
        std.mem.trim(u8, sys.readHead("/proc/sys/fs/inotify/max_queued_events", &qbuf), " \n"),
        10,
    ) catch 16384;
    if (queued_max > 100_000) return error.SkipZigTest;

    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.mem.print(&rbuf, "{s}/root", .{dir});
    try mkdirAbs(root, "flood");
    var ibuf: [4096]u8 = undefined;
    const s = try Service.start(gpa, testing.io, root, try std.mem.print(
        &ibuf,
        "{s}/files.idx",
        .{dir},
    ));
    defer s.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try settle(s);
    const rescans = s.status().rescans;

    // Holding the index stalls the thread before it drains: the queue
    // overflows for real.
    var fbuf: [4096]u8 = undefined;
    const flood = try std.mem.print(&fbuf, "{s}/flood", .{root});
    const n = queued_max + 1_000;
    s.lock.lockUncancelable(s.io);
    for (0..n) |i| {
        var nb: [32]u8 = undefined;
        touch(flood, try std.mem.print(&nb, "n{d:0>5}.txt", .{i})) catch |e| {
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
    try testing.expect(try has(
        s,
        arena,
        try std.mem.print(&last, "n{d:0>5}", .{n - 1}),
        try arena.print("/flood/n{d:0>5}.txt", .{n - 1}),
    ));
}

test "service: files created while the first rescan runs are not lost" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.mem.print(&rbuf, "{s}/root", .{dir});
    // Enough to keep the scan busy a few levels deep.
    for (0..40) |i| {
        var p: [4096]u8 = undefined;
        const sub = try std.mem.print(&p, "{s}/d{d}", .{ root, i });
        sys.mkdirP(sub);
        var q: [4096]u8 = undefined;
        sys.mkdirP(try std.mem.print(&q, "{s}/deep/deeper", .{sub}));
        for (0..40) |j| {
            var nb: [32]u8 = undefined;
            try touch(sub, try std.mem.print(&nb, "old_{d}.txt", .{j}));
        }
    }
    var ibuf: [4096]u8 = undefined;
    const s = try Service.start(gpa, testing.io, root, try std.mem.print(
        &ibuf,
        "{s}/files.idx",
        .{dir},
    ));
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
        try touch(
            try std.mem.print(&p, "{s}/d{d}/deep/deeper", .{ root, i % 40 }),
            try std.mem.print(&nb, "late_{d}.txt", .{i}),
        );
    }
    try settle(s);
    for (0..n) |i| {
        const q = try arena.print("late_{d}", .{i});
        const want = try arena.print("/d{d}/deep/deeper/late_{d}.txt", .{ i % 40, i });
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
    const root = try std.mem.print(&rbuf, "{s}/root", .{dir});
    try touch(root, "Cargo.toml");
    var ibuf: [4096]u8 = undefined;
    const idx = try std.mem.printSentinel(&ibuf, "{s}/files.idx", .{dir}, 0);
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
    try testing.expect(hits.items.len > 0 and std.mem.endsWith(
        u8,
        saved.path(hits.items[0].id, &pbuf).?,
        "/de_la_sesion.rs",
    ));

    // And a new start finds it on its first search, before any rescan.
    const s2 = try Service.start(gpa, testing.io, root, idx);
    defer s2.shutdown();
    try testing.expect(try has(s2, arena, "de_la_sesion", "/de_la_sesion.rs"));
}

/// Waits until `nameChanges` differs from `from` (or, `from` null, is known).
pub fn waitNames(service: *Service, from: ?u64) error{NoNameChange}!u64 {
    for (0..wait_tries) |_| {
        if (service.nameChanges()) |n| if (from == null or n != from.?) return n;
        sys.sleepUs(10_000);
    }
    return error.NoNameChange;
}

test "service: name changes are counted outside hidden files and folders" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.mem.print(&rbuf, "{s}/root", .{dir});
    try mkdirAbs(root, ".hidden");
    var hbuf: [4096]u8 = undefined;
    const hidden = try std.mem.print(&hbuf, "{s}/.hidden", .{root});
    var ibuf: [4096]u8 = undefined;
    const idx = try std.mem.printSentinel(&ibuf, "{s}/files.idx", .{dir}, 0);

    const s = try Service.start(gpa, testing.io, root, idx);
    defer s.shutdown();
    try settle(s);
    const before = try waitNames(s, null);
    try touch(root, ".dotfile");
    try touch(hidden, "inside.txt");
    sys.sleepUs(300_000);
    try testing.expectEqual(before, s.nameChanges().?);
    try touch(root, "visible.txt");
    _ = try waitNames(s, before);
}

test "service: the delta threshold triggers a compaction" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    try mkdirAbs(dir, "root");
    var rbuf: [4096]u8 = undefined;
    const root = try std.mem.print(&rbuf, "{s}/root", .{dir});
    var ibuf: [4096]u8 = undefined;
    const s = try Service.start(gpa, testing.io, root, try std.mem.print(
        &ibuf,
        "{s}/files.idx",
        .{dir},
    ));
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
        try touch(root, try std.mem.print(&nb, "umbral_{d}.txt", .{i}));
    }
    for (0..wait_tries) |_| {
        if (s.status().rescans > rescans) break;
        sys.sleepUs(20_000);
    }
    try settle(s);
    try testing.expect(s.status().rescans > rescans);
    for (0..5) |i| {
        const q = try arena.print("umbral_{d}", .{i});
        try testing.expect(try waitHas(s, arena, q, try arena.print("/umbral_{d}.txt", .{i})));
    }
    s.lock.lockSharedUncancelable(s.io);
    const delta_live = s.live.delta.store.liveLen();
    s.lock.unlockShared(s.io);
    try testing.expect(delta_live < 5);
}

test "service: rescans asked for in a row wait longer each time" {
    const s = std.time.ns_per_s;
    // The first one, and any after a quiet minute: at once.
    try testing.expectEqual(0, backoffFor(0, std.math.maxInt(u64)));
    try testing.expectEqual(0, backoffFor(8 * s, 61 * s));
    // In a row: 1, 2, 4... seconds, never past a minute.
    var wait: u64 = 0;
    for ([_]u64{ 1, 2, 4, 8, 16, 32, 60, 60 }) |want| {
        wait = backoffFor(wait, 0);
        try testing.expectEqual(want * s, wait);
    }
}
