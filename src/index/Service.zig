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
const paths = @import("paths.zig");
const Io = std.Io;
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const scan = @import("scan.zig");
const engine = @import("search.zig");
const Pool = @import("Pool.zig");
const Watcher = @import("Watcher.zig");
const Live = @import("Live.zig");
const ContentService = @import("ContentService.zig");
const sys = @import("os");

const Service = @This();

const log = std.log.scoped(.files);

/// Watches per batch: ~2.3 us each, so a search waits ~4.6 ms at worst.
const arm_batch_watches = 2_000;
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
/// An eventfd written by `shutdown`: the thread waits on inotify and this,
/// with no timeout (it used to wake every 100 ms to look at `stop`). Null
/// when none could be made: the thread then waits at most 100 ms at a time
/// on inotify, to look at `stop`.
wake_fd: ?i32 = null,
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
config: scan.Config,
roots: [1][]const u8,
cache_path: [:0]u8,
/// Names created, removed or moved outside hidden files and directories,
/// and anything uncertain (a queue overflow, a rescan): the content service
/// lists files again only when this moved. Idle, a home sees name changes
/// all the time, but in .cache and .config (120 in 90 s, none elsewhere).
name_changes: std.atomic.Value(u64) = .init(0),
/// For `lumen --stats`, read from other threads.
rescans: std.atomic.Value(u32) = .init(0),
rescan_ns_last: std.atomic.Value(u64) = .init(0),
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
    try service.init(gpa, io, root, cache_path);
    errdefer service.deinit();
    service.thread = try std.Thread.spawn(.{}, run, .{service});
    // A thread without a name works the same; only `top` shows it.
    service.thread.?.setName(io, "lm-files") catch {};
    return service;
}

/// Fills `service` in place, with no thread yet. In place because the
/// fields point at each other: `config` at `roots`, and `live` at `config`. On
/// error nothing is left to free.
fn init(
    service: *Service,
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    cache_path: []const u8,
) StartError!void {
    const root_copy = try gpa.dupe(u8, root);
    errdefer gpa.free(root_copy);
    const cache = try gpa.dupeSentinel(u8, cache_path, 0);
    errdefer gpa.free(cache);
    const pools: Pools = try .create(gpa, io);
    errdefer pools.destroy();

    service.* = .{
        .gpa = gpa,
        .io = io,
        // Set right below: Live keeps a pointer to `config`, and reads it
        // while it starts, so `config` must be in its place first.
        .live = undefined,
        .search_pool = pools.search,
        .scan_pool = pools.scan,
        .content_search_pool = pools.content_search,
        .content_build_pool = pools.content_build,
        .roots = .{root_copy},
        .config = .{ .roots = &service.roots },
        .cache_path = cache,
    };
    var base = Store.open(service.cache_path) catch blk: {
        var empty: store_mod.Builder = .empty;
        break :blk try empty.finish(gpa);
    };
    service.live = Live.initUnarmed(gpa, base, &service.config, service.scan_pool) catch |err| {
        base.deinit(gpa);
        return err;
    };
    // A saved index is a photo: nobody watched while Lumen was off.
    service.live.pending_resync = true;

    const linux = std.os.linux;
    const event_fd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    // Without one, `pause` looks at `stop` every 100 ms instead.
    if (linux.errno(event_fd) == .SUCCESS) service.wake_fd = @intCast(event_fd);
}

/// The pools the content index runs on, lent for the service's lifetime.
pub fn contentPools(service: *const Service) ContentService.Pools {
    return .{ .search = service.content_search_pool, .build = service.content_build_pool };
}

/// Frees what `init` made. The thread must have stopped (or never started).
fn deinit(service: *Service) void {
    if (service.wake_fd) |wake_fd| sys.close(wake_fd);
    service.live.deinit();
    const pools: Pools = .{
        .search = service.search_pool,
        .scan = service.scan_pool,
        .content_search = service.content_search_pool,
        .content_build = service.content_build_pool,
    };
    pools.destroy();
    service.gpa.free(service.roots[0]);
    service.gpa.free(service.cache_path);
}

/// The four pools a service owns. Two are its own; the content ones it only
/// lends (see `content_search_pool`).
const Pools = struct {
    search: *Pool,
    scan: *Pool,
    content_search: *Pool,
    content_build: *Pool,

    const CreateError = Pool.CreateError;

    fn create(gpa: std.mem.Allocator, io: Io) CreateError!Pools {
        const search_pool = try Pool.create(gpa, io, Pool.allCores());
        errdefer search_pool.destroy();
        const scan_pool = try Pool.create(gpa, io, Pool.halfCores());
        errdefer scan_pool.destroy();
        const content_search_pool = try Pool.create(gpa, io, Pool.allCores());
        errdefer content_search_pool.destroy();
        const content_build_pool = try Pool.create(gpa, io, Pool.halfCores());
        search_pool.nameThreads("lm-search");
        scan_pool.nameThreads("lm-scan");
        content_search_pool.nameThreads("lm-csearch");
        content_build_pool.nameThreads("lm-cbuild");
        return .{
            .search = search_pool,
            .scan = scan_pool,
            .content_search = content_search_pool,
            .content_build = content_build_pool,
        };
    }

    fn destroy(pools: Pools) void {
        pools.search.destroy();
        pools.scan.destroy();
        pools.content_search.destroy();
        pools.content_build.destroy();
    }
};

/// Stops the thread, saves what was learned if needed, frees everything.
/// The flush is what makes today's files still be there tomorrow.
pub fn shutdown(service: *Service) void {
    service.stop.store(true, .release);
    if (service.wake_fd) |wake_fd| {
        // An eventfd takes exactly one u64, the amount to add.
        const one: u64 = 1;
        const written = std.os.linux.write(wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
        // Unwoken, the thread waits on inotify until the next event.
        const errno = std.os.linux.errno(written);
        if (errno != .SUCCESS) log.warn("waking the file index thread: {t}", .{errno});
    }
    if (service.thread) |thread| thread.join();
    if (service.live.dirty or service.live.pending_resync) service.saveOnShutdown();
    service.deinit();
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
    rescan_ns_last: u64 = 0,
};

pub fn status(service: *Service) Status {
    service.lock.lockSharedUncancelable(service.io);
    defer service.lock.unlockShared(service.io);
    return .{
        .entries = service.live.entriesLive(),
        .watches = service.live.stats.watches,
        .unwatched = service.live.unwatched(),
        .armed = service.live.fullyArmed(),
        .rescanning = service.live.pending_resync,
        .index_bytes = service.live.indexBytes(),
        .rescans = service.rescans.load(.monotonic),
        .rescan_ns_last = service.rescan_ns_last.load(.monotonic),
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
    const pool = service.scan_pool;
    return Live.prepareCompaction(service.gpa, pool, &service.config, service.cache_path);
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
    if (!service.live.fullyArmed() or service.live.unwatched() > 0) return null;
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
    var path_buffer: paths.Buffer = undefined;
    const directory = service.live.pathOf(.fromRaw(parent), &path_buffer) orelse return true;
    const root = service.roots[0];
    const in_root = std.mem.startsWith(u8, directory, root);
    const relative = if (in_root) directory[root.len..] else directory;
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
        if (service.wake_fd) |wake_fd| {
            _ = sys.waitReadable(wake_fd, slice_ms);
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
        service.rescan_ns_last.store(end_ns - start_ns, .monotonic);
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
        if (!service.live.scansPending()) return service.rescanDue();
        scans = service.live.takeScans();
        entries_max = service.live.limits.delta_entries_max;
    }
    // New directories are read without the lock: a large tree moved in
    // held it, and every search with it, for as long as reading took.
    Live.readScans(service.gpa, service.scan_pool, &service.config, scans.items, entries_max);
    service.lock.lockUncancelable(service.io);
    defer service.lock.unlock(service.io);
    service.live.addScans(&scans) catch |err| {
        log.warn("applying file events: {t}", .{err});
        service.live.pending_resync = true;
    };
    return service.rescanDue();
}

/// Called with the lock held.
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
        const more = service.live.armProgress(arm_batch_watches);
        service.lock.unlock(service.io);
        if (more) {
            sys.sleepUs(arm_yield_us);
            continue;
        }

        // Phase 2: wait for events without holding the index.
        service.lock.lockSharedUncancelable(service.io);
        const fd = service.live.watcher.fd;
        service.lock.unlockShared(service.io);
        // A negative descriptor is one `poll` ignores.
        if (!sys.waitEvents(fd, service.wake_fd orelse -1)) continue;

        _ = arena_state.reset(.retain_capacity);
        if (service.applyEvents(arena_state.allocator())) service.rescan();
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn touch(directory: []const u8, name: []const u8) !void {
    var path_buffer: paths.Buffer = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ directory, name }, 0);
    try sys.writeFile(path, "x");
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
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var temporary_path_buffer: paths.Buffer = undefined;
    const temporary_path = try sys.tmpDirAbs(&temporary, &temporary_path_buffer);
    try touch(temporary_path, "first_note.md");

    var index_path_buffer: paths.Buffer = undefined;
    const index_name = .{ temporary_path, temporary.sub_path };
    const index_path = try std.mem.printSentinel(
        &index_path_buffer,
        "{s}/../lumen-test-{s}.idx",
        index_name,
        0,
    );
    // Deferred before the shutdown, so it runs after it: the shutdown saves
    // the index again.
    defer {
        const unlinked = std.os.linux.errno(std.os.linux.unlink(index_path));
        assert(unlinked == .SUCCESS or unlinked == .NOENT);
    }
    const service = try Service.start(gpa, testing.io, temporary_path, index_path);
    defer service.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The initial rescan finds what was there.
    try testing.expect(try waitFor(service, arena, "first_note", true));
    while (!service.status().armed or service.status().rescanning) sys.sleepUs(5_000);

    // A new file arrives through inotify.
    try touch(temporary_path, "zebra_quarterly.txt");
    try testing.expect(try waitFor(service, arena, "zebra_quarterly", true));

    // A new directory with content inside (scanned whole on creation).
    try makeDirectory(temporary_path, "fresh_dir");
    var directory_buffer: paths.Buffer = undefined;
    const sub = try std.mem.printSentinel(&directory_buffer, "{s}/fresh_dir", .{temporary_path}, 0);
    try touch(sub, "inner_walrus.txt");
    try testing.expect(try waitFor(service, arena, "inner_walrus", true));

    // Deleting the base file and the delta file removes both.
    try deleteFile(temporary_path, "first_note.md");
    try testing.expect(try waitFor(service, arena, "first_note", false));
    try deleteFile(sub, "inner_walrus.txt");
    try testing.expect(try waitFor(service, arena, "inner_walrus", false));
}

const temporaryPath = sys.tmpDirAbs;

/// Waits until the thread has nothing pending: armed and not rescanning.
fn settle(service: *Service) !void {
    for (0..wait_tries) |_| {
        const status_now = service.status();
        if (status_now.armed and !status_now.rescanning) return;
        sys.sleepUs(20_000);
    }
    return error.NeverSettled;
}

fn has(service: *Service, arena: std.mem.Allocator, query: []const u8, suffix: []const u8) !bool {
    var hits: std.ArrayList(Live.Hit) = .empty;
    try service.search(arena, query, 50, &hits);
    for (hits.items) |hit| {
        if (std.mem.endsWith(u8, hit.path, suffix)) return true;
    }
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

fn makeDirectory(directory: []const u8, name: []const u8) !void {
    var path_buffer: paths.Buffer = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ directory, name }, 0);
    const linux = std.os.linux;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdir(path, 0o755)));
}

fn deleteFile(directory: []const u8, name: []const u8) !void {
    var path_buffer: paths.Buffer = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ directory, name }, 0);
    const linux = std.os.linux;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.unlink(path)));
}

test "service: a flooded queue ends in a rescan that finds everything" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var queued_text: [32]u8 = undefined;
    const queued_read = sys.readHead("/proc/sys/fs/inotify/max_queued_events", &queued_text);
    const queued_trimmed = std.mem.trim(u8, queued_read, " \n");
    const queued_max = std.fmt.parseInt(usize, queued_trimmed, 10) catch 16384;
    if (queued_max > 100_000) return error.SkipZigTest;

    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    try makeDirectory(directory, "root");
    var root_buffer: paths.Buffer = undefined;
    const root = try std.mem.print(&root_buffer, "{s}/root", .{directory});
    try makeDirectory(root, "flood");
    var index_path_buffer: paths.Buffer = undefined;
    const service = try Service.start(gpa, testing.io, root, try std.mem.print(
        &index_path_buffer,
        "{s}/files.idx",
        .{directory},
    ));
    defer service.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try settle(service);
    const rescans = service.status().rescans;

    // Holding the index stalls the thread before it drains: the queue
    // overflows for real.
    var file_path_buffer: paths.Buffer = undefined;
    const flood = try std.mem.print(&file_path_buffer, "{s}/flood", .{root});
    const files_count = queued_max + 1_000;
    service.lock.lockUncancelable(service.io);
    for (0..files_count) |i| {
        var name_text: [32]u8 = undefined;
        touch(flood, try std.mem.print(&name_text, "n{d:0>5}.txt", .{i})) catch |err| {
            service.lock.unlock(service.io);
            return err;
        };
    }
    service.lock.unlock(service.io);

    for (0..2_000) |_| {
        if (service.status().rescans > rescans) break;
        sys.sleepUs(5_000);
    }
    try settle(service);
    service.lock.lockSharedUncancelable(service.io);
    const resyncs = service.live.stats.resyncs;
    service.lock.unlockShared(service.io);
    try testing.expect(resyncs >= 1);
    try testing.expect(service.status().entries >= files_count + 2);
    try testing.expect(try has(service, arena, "n00000", "/flood/n00000.txt"));
    try testing.expect(try has(service, arena, "n08191", "/flood/n08191.txt"));
    var last: [32]u8 = undefined;
    try testing.expect(try has(
        service,
        arena,
        try std.mem.print(&last, "n{d:0>5}", .{files_count - 1}),
        try arena.print("/flood/n{d:0>5}.txt", .{files_count - 1}),
    ));
}

test "service: files created while the first rescan runs are not lost" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    try makeDirectory(directory, "root");
    var root_buffer: paths.Buffer = undefined;
    const root = try std.mem.print(&root_buffer, "{s}/root", .{directory});
    // Enough to keep the scan busy a few levels deep.
    for (0..40) |i| {
        var sub_buffer: paths.Buffer = undefined;
        const sub = try std.mem.print(&sub_buffer, "{s}/d{d}", .{ root, i });
        try sys.mkdirP(sub);
        var deeper_buffer: paths.Buffer = undefined;
        try sys.mkdirP(try std.mem.print(&deeper_buffer, "{s}/deep/deeper", .{sub}));
        for (0..40) |j| {
            var name_text: [32]u8 = undefined;
            try touch(sub, try std.mem.print(&name_text, "old_{d}.txt", .{j}));
        }
    }
    var index_path_buffer: paths.Buffer = undefined;
    const service = try Service.start(gpa, testing.io, root, try std.mem.print(
        &index_path_buffer,
        "{s}/files.idx",
        .{directory},
    ));
    defer service.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Right away, while the thread scans: before, during and after each
    // directory is read.
    const files_count = 200;
    for (0..files_count) |i| {
        var deeper_buffer: paths.Buffer = undefined;
        var name_text: [32]u8 = undefined;
        try touch(
            try std.mem.print(&deeper_buffer, "{s}/d{d}/deep/deeper", .{ root, i % 40 }),
            try std.mem.print(&name_text, "late_{d}.txt", .{i}),
        );
    }
    try settle(service);
    for (0..files_count) |i| {
        const query = try arena.print("late_{d}", .{i});
        const want = try arena.print("/d{d}/deep/deeper/late_{d}.txt", .{ i % 40, i });
        try testing.expect(try waitHas(service, arena, query, want));
    }
}

test "service: shutdown saves what was learned and the next start maps it" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    try makeDirectory(directory, "root");
    var root_buffer: paths.Buffer = undefined;
    const root = try std.mem.print(&root_buffer, "{s}/root", .{directory});
    try touch(root, "Cargo.toml");
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try std.mem.printSentinel(
        &index_path_buffer,
        "{s}/files.idx",
        .{directory},
        0,
    );
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        const service = try Service.start(gpa, testing.io, root, index_path);
        defer service.shutdown();
        try settle(service);
        try touch(root, "de_la_sesion.rs");
        try testing.expect(try waitHas(service, arena, "de_la_sesion", "/de_la_sesion.rs"));
        // Learned through inotify only: in the delta, not yet in the file.
        service.lock.lockSharedUncancelable(service.io);
        const dirty = service.live.dirty;
        service.lock.unlockShared(service.io);
        try testing.expect(dirty);
    }

    // The file alone has it.
    var saved = try Store.open(index_path);
    defer saved.deinit(gpa);
    const pool = try Pool.create(gpa, testing.io, 0);
    defer pool.destroy();
    var engine_saved: engine.Engine = .empty;
    defer engine_saved.deinit(gpa);
    var hits: std.ArrayList(engine.Hit) = .empty;
    defer hits.deinit(gpa);
    const options: engine.Options = .{ .limit = 10, .recency = false };
    try engine_saved.search(gpa, pool, &saved, "de_la_sesion", options, &hits);
    var path_buffer: paths.Buffer = undefined;
    try testing.expect(hits.items.len > 0);
    const top_path = saved.path(hits.items[0].id, &path_buffer).?;
    try testing.expect(std.mem.endsWith(u8, top_path, "/de_la_sesion.rs"));

    // And a new start finds it on its first search, before any rescan.
    const service_again = try Service.start(gpa, testing.io, root, index_path);
    defer service_again.shutdown();
    try testing.expect(try has(service_again, arena, "de_la_sesion", "/de_la_sesion.rs"));
}

/// Waits until `nameChanges` differs from `from` (or, `from` null, is known).
pub fn waitNames(service: *Service, from: ?u64) error{NoNameChange}!u64 {
    for (0..wait_tries) |_| {
        if (service.nameChanges()) |changes| {
            if (from == null or changes != from.?) return changes;
        }
        sys.sleepUs(10_000);
    }
    return error.NoNameChange;
}

test "service: name changes are counted outside hidden files and folders" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    try makeDirectory(directory, "root");
    var root_buffer: paths.Buffer = undefined;
    const root = try std.mem.print(&root_buffer, "{s}/root", .{directory});
    try makeDirectory(root, ".hidden");
    var hidden_buffer: paths.Buffer = undefined;
    const hidden = try std.mem.print(&hidden_buffer, "{s}/.hidden", .{root});
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = try std.mem.printSentinel(
        &index_path_buffer,
        "{s}/files.idx",
        .{directory},
        0,
    );

    const service = try Service.start(gpa, testing.io, root, index_path);
    defer service.shutdown();
    try settle(service);
    const before = try waitNames(service, null);
    try touch(root, ".dotfile");
    try touch(hidden, "inside.txt");
    sys.sleepUs(300_000);
    try testing.expectEqual(before, service.nameChanges().?);
    try touch(root, "visible.txt");
    _ = try waitNames(service, before);
}

test "service: the delta threshold triggers a compaction" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    try makeDirectory(directory, "root");
    var root_buffer: paths.Buffer = undefined;
    const root = try std.mem.print(&root_buffer, "{s}/root", .{directory});
    var index_path_buffer: paths.Buffer = undefined;
    const service = try Service.start(gpa, testing.io, root, try std.mem.print(
        &index_path_buffer,
        "{s}/files.idx",
        .{directory},
    ));
    defer service.shutdown();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try settle(service);

    service.lock.lockUncancelable(service.io);
    service.live.limits.delta_entries_max = 3;
    service.lock.unlock(service.io);
    const rescans = service.status().rescans;
    for (0..5) |i| {
        var name_text: [32]u8 = undefined;
        try touch(root, try std.mem.print(&name_text, "umbral_{d}.txt", .{i}));
    }
    for (0..wait_tries) |_| {
        if (service.status().rescans > rescans) break;
        sys.sleepUs(20_000);
    }
    try settle(service);
    try testing.expect(service.status().rescans > rescans);
    for (0..5) |i| {
        const query = try arena.print("umbral_{d}", .{i});
        const want = try arena.print("/umbral_{d}.txt", .{i});
        try testing.expect(try waitHas(service, arena, query, want));
    }
    service.lock.lockSharedUncancelable(service.io);
    const delta_live = service.live.delta.store.liveCount();
    service.lock.unlockShared(service.io);
    try testing.expect(delta_live < 5);
}

test "service: rescans asked for in a row wait longer each time" {
    const second = std.time.ns_per_s;
    // The first one, and any after a quiet minute: at once.
    try testing.expectEqual(0, backoffFor(0, std.math.maxInt(u64)));
    try testing.expectEqual(0, backoffFor(8 * second, 61 * second));
    // In a row: 1, 2, 4... seconds, never past a minute.
    var wait: u64 = 0;
    for ([_]u64{ 1, 2, 4, 8, 16, 32, 60, 60 }) |want| {
        wait = backoffFor(wait, 0);
        try testing.expectEqual(want * second, wait);
    }
}
