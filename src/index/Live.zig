//! Live index: the mapped base plus what inotify reports (port of `live.rs`).
//! Not thread-safe: `Service` serializes every access with its lock.
//!
//! The base store is immutable and packed in one buffer, which is what makes
//! start-up a 1 ms mmap. Rebuilding it per new file would throw that away, so
//! changes are a layer on top:
//!
//!   - Deleting zeroes the entry's mask (see `Store.tombstone`): free on the
//!     hot path, copy-on-write on a mapping.
//!   - Adding goes to a small `Delta` searched alongside the base and
//!     merged by score.
//!
//! When the delta grows or tombstones pile up, a rescan (prepared outside the
//! lock) replaces everything with one clean index.
//!
//! How `Service`'s thread drives it, with the lock held unless noted:
//!
//!   1. `armProgress` until every base directory is watched.
//!   2. `apply` for each batch of `Watcher.Change`s. A new directory gets
//!      its entry at once; what it holds is read by `takeScans`,
//!      `readScans` (unlocked) and `addScans`.
//!   3. `needsCompaction`, or `pending_resync` set by an overflow or by
//!      running out of memory, asks for a rescan: `prepareCompaction`
//!      (unlocked), then `adopt`, whose returned index is freed unlocked.
//!
//! Searches (`search`) come from the UI thread between any of these.
//! Entries are named by `EntryId`, an index into the base or the delta.

const std = @import("std");
const paths = @import("paths.zig");
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Builder = store_mod.Builder;
const scan = @import("scan.zig");
const engine = @import("search.zig");
const Pool = @import("Pool.zig");
const Watcher = @import("Watcher.zig");
const Delta = @import("Delta.zig");
const sys = @import("os");

const log = std.log.scoped(.files);

const Live = @This();

gpa: std.mem.Allocator,
base: Store,
/// What was added since `base` was built. A rescan replaces it whole.
delta: Delta,
/// New directories entered by `apply` whose contents are not read yet.
scans: Scans = .empty,
/// A batch tombstoned a directory: `pruneWatches` has work.
prune_watches: bool = false,
/// Mounts under the root that can hang a stat (`sys.slowMounts`): no
/// recency for what is in them. Read on start and on every rescan.
slow_mounts: [][]u8 = &.{},
/// Directories watched by `addScans`, to list again (`Recheck`).
rechecks: Rechecks = .empty,
/// Directories skipped due to EACCES during scan/watch, retried by `Service`.
retry_dirs: [][]u8 = &.{},
watcher: *Watcher,
config: *const scan.Config,
/// Small scans (a new directory) and rescans run here.
scan_pool: *Pool,
/// The next base entry whose directory `armProgress` watches; null once
/// every one is.
arm_cursor: ?u32 = null,
/// Persistent engines: what enables refinement while typing (measured in the
/// Rust version: 503 us cold vs 14 us reusing the engine).
engine_base: engine.Engine = .empty,
/// The index may be wrong (events were lost, or a change could not be
/// applied for lack of memory): the service rescans, without the lock.
pending_resync: bool = false,
/// Changes not yet in the index file. Without this, what was learned while
/// running lived only in the delta and died with the process.
dirty: bool = false,
last_compact_ns: u64,
/// Tombstoned base entries, counted as they die: `needsCompaction` runs
/// after every batch of events, and counting 1.1 M masks there took ~1 ms
/// under the lock searches wait on.
graves: usize = 0,
stats: Stats = .{},
limits: Limits = .{},

/// Flush to disk at least this often if something changed. Off: a home's
/// caches change all the time, so it rescanned every 10 minutes (49 MB
/// written, ~1 s of CPU, +54 MB while it ran) to cover a crash, which the
/// rescan on every start covers anyway; a clean exit flushes.
pub const compact_interval_ns: u64 = std.math.maxInt(u64);

/// An entry of the live index: its index in `base`, or in the delta.
/// inotify events arrive as (watch, name) and every watch must map to
/// *some* entry; directories created after the scan only exist in the
/// delta, so both share one 32-bit space. The Watcher keeps the raw u32
/// (`raw`, `fromRaw`); everything in Live that may be either goes through
/// this type, and a plain u32 is always an index into one store.
pub const EntryId = packed struct(u32) {
    index: u31,
    in_delta: bool,

    comptime {
        // A base id is the store index itself: the scan watches with those,
        // and a store has fewer than 2^31 entries.
        assert(@as(u32, @bitCast(EntryId{ .index = 5, .in_delta = false })) == 5);
        assert(@as(u32, @bitCast(EntryId{ .index = 0, .in_delta = true })) == 1 << 31);
    }

    pub fn ofBase(index: u32) EntryId {
        assert(index <= std.math.maxInt(u31));
        return .{ .index = @intCast(index), .in_delta = false };
    }

    pub fn ofDelta(index: u32) EntryId {
        assert(index <= std.math.maxInt(u31));
        return .{ .index = @intCast(index), .in_delta = true };
    }

    /// The id a watch was registered with.
    pub fn fromRaw(raw_id: u32) EntryId {
        return @bitCast(raw_id);
    }

    pub fn raw(id: EntryId) u32 {
        return @bitCast(id);
    }
};

pub const Hit = struct { path: []const u8, score: i32, is_dir: bool };

pub const Stats = struct {
    added: usize = 0,
    removed: usize = 0,
    resyncs: usize = 0,
    watches: usize = 0,
};

/// When the layers on top are worth a rescan. A field, not constants, so
/// tests can reach the thresholds without creating 20k files.
pub const Limits = struct {
    delta_entries_max: usize = 20_000,
    graves_min: usize = 1_000,
    /// Tombstones must also exceed 1/graves_divisor of the base (5%).
    graves_divisor: usize = 20,
    interval_ns: u64 = compact_interval_ns,
    retry_dir_min_ns: u64 = 1 * std.time.ns_per_s,
    retry_dir_max_ns: u64 = 60 * std.time.ns_per_s,
};

/// A directory that appeared after the scan. Its entry is in the delta at
/// once, so a removal later in the same batch finds it; what it holds is
/// read by `readScans` without the lock, then added by `addScans`. Read
/// under the lock, a large tree moved into the index stalled every search
/// for as long as reading it took.
pub const Scan = struct {
    /// Delta index of the directory's entry.
    directory: u32,
    path: [:0]u8,
    depth: u16,
    hidden: u8,
    outcome: Outcome = .unread,
    unreadable: [][]u8 = &.{},

    /// What `readScans` found in the directory.
    pub const Outcome = union(enum) {
        /// `readScans` has not run yet.
        unread,
        /// Out of memory while reading: a rescan instead.
        failed,
        /// Over `Limits.delta_entries_max` entries: a rescan instead, which
        /// adding it would ask for anyway.
        too_big,
        /// What the directory holds, as a store whose root is the directory.
        read: Store,
    };

    fn deinit(scan_job: *Scan, gpa: std.mem.Allocator) void {
        gpa.free(scan_job.path);
        sys.freeList(gpa, scan_job.unreadable);
        if (scan_job.outcome == .read) scan_job.outcome.read.deinit(gpa);
    }
};

pub const Scans = std.ArrayList(Scan);

/// A directory `addScans` watched after `readScans` had read it: what was
/// created in it in between came with no event and is not in the read.
/// `readRechecks` lists it again once it is watched (anything later comes
/// as an event), and `applyRechecks` adds what is missing and drops ghosts.
pub const Recheck = struct {
    /// Raw `EntryId` of the directory's entry (in the delta).
    directory: u32,
    path: [:0]u8,
    status: Status = .unread,
    /// What `readRechecks` found in it.
    found: []const Found = &.{},

    pub const Status = enum { unread, read, gone, unreadable };
    pub const Found = struct { name: []const u8, is_dir: bool };
};

pub const Rechecks = std.ArrayList(Recheck);

/// What `adopt` hands back: the index and the watcher it replaced.
pub const Replaced = struct {
    base: Store,
    watcher: *Watcher,
    /// What `adopt` needs that takes a pass over the index or a read of
    /// /proc, done by `prepareCompaction` without the lock (searches wait
    /// on it): `base`'s tombstones, and the slow mounts under the roots
    /// (null: unknown, the old list stays). On the replaced index: its old
    /// list, freed with it.
    graves: usize = 0,
    slow_mounts: ?[][]u8 = null,
    retry_dirs: ?[][]u8 = null,

    pub fn deinit(replaced: Replaced, gpa: std.mem.Allocator) void {
        var base = replaced.base;
        base.deinit(gpa);
        replaced.watcher.destroy(gpa);
        if (replaced.slow_mounts) |mounts| sys.freeList(gpa, mounts);
        if (replaced.retry_dirs) |dirs| sys.freeList(gpa, dirs);
    }
};

/// Takes a store (mapped or fresh) with no watches armed yet: searchable
/// right away, watches armed in batches by `armProgress`. Owns `base` once
/// it returns; on error `base` is still the caller's.
pub fn initUnarmed(
    gpa: std.mem.Allocator,
    base: Store,
    config: *const scan.Config,
    scan_pool: *Pool,
) (std.mem.Allocator.Error || Watcher.CreateError)!Live {
    var delta: Delta = try .init(gpa);
    errdefer delta.deinit(gpa);
    const slow = try slowMountsOf(gpa, config);
    errdefer sys.freeList(gpa, slow);
    const watcher = try Watcher.create(gpa);
    return .{
        .slow_mounts = slow,
        .gpa = gpa,
        .base = base,
        .delta = delta,
        .watcher = watcher,
        .config = config,
        .scan_pool = scan_pool,
        .arm_cursor = 0,
        .last_compact_ns = sys.monotonicNs(),
        .graves = base.len() - base.liveCount(),
    };
}

pub fn deinit(live: *Live) void {
    live.base.deinit(live.gpa);
    live.delta.deinit(live.gpa);
    freeScans(live.gpa, &live.scans);
    freeRechecks(live.gpa, &live.rechecks);
    sys.freeList(live.gpa, live.retry_dirs);
    sys.freeList(live.gpa, live.slow_mounts);
    live.watcher.destroy(live.gpa);
    live.engine_base.deinit(live.gpa);
    live.* = undefined;
}

/// Arms up to `budget` pending watches. True if more remain. Returns a bool,
/// not a count: counting walked every entry with the lock held, per batch.
pub fn armProgress(live: *Live, budget: usize) bool {
    var id = live.arm_cursor orelse return false;
    const entries_count = live.base.len();
    const flags = live.base.flags();
    const parents = live.base.parents();
    var armed_count: usize = 0;
    var path_buffer: paths.Buffer = undefined;
    while (id < entries_count and armed_count < budget) : (id += 1) {
        if (flags[id] & store_mod.flag_dir == 0) continue;
        if (live.base.isTombstoned(id)) continue;
        if (pathZ(&live.base, id, &path_buffer)) |path| {
            const placement: Watcher.Placement =
                if (parents[id] == store_mod.no_parent) .root else .below_root;
            live.watcher.watchBestEffort(live.gpa, path, id, placement) catch {
                // Out of memory: this directory is armed on the next call.
                break;
            };
        }
        armed_count += 1;
    }
    live.stats.watches = live.watcher.count();
    if (id >= entries_count) {
        live.arm_cursor = null;
        return false;
    }
    live.arm_cursor = id;
    return true;
}

pub fn fullyArmed(live: *const Live) bool {
    return live.arm_cursor == null;
}

/// Entries a search can find, in the base and the delta. The delta's
/// scaffolding and its own tombstones are not counted.
pub fn entriesLive(live: *const Live) usize {
    // The base's from `graves`, kept as entries are tombstoned: counting its
    // live masks was a pass over ~1.6 M of them under the lock, on every
    // status. The delta is small.
    assert(live.graves <= live.base.len());
    return live.base.len() - live.graves + live.delta.store.liveCount();
}

/// Bytes the two stores take, mapped or in memory.
pub fn indexBytes(live: *const Live) usize {
    return live.base.bytes.len + live.delta.store.bytes.len;
}

/// Directories inotify could not watch (the limit was reached).
pub fn unwatched(live: *const Live) u32 {
    return live.watcher.unwatched;
}

/// New directories entered by `apply` whose contents wait to be read.
pub fn scansPending(live: *const Live) bool {
    return live.scans.items.len > 0;
}

/// Applies a batch of changes; returns how many took effect. New
/// directories are only entered: what they hold waits in `scans` (see
/// `Scan`).
pub fn apply(live: *Live, changes: []const Watcher.Change) std.mem.Allocator.Error!usize {
    // An overflow cannot be patched: something was missed. The rescan is
    // only requested here (this runs with exclusive access; ~0.3 s of
    // scanning would stall every search); the service does it unlocked.
    for (changes) |change| {
        if (change != .overflow) continue;
        live.stats.resyncs += 1;
        live.pending_resync = true;
        return changes.len;
    }
    var applied_count: usize = 0;
    for (changes) |change| switch (change) {
        .created => |created| {
            const parent: EntryId = .fromRaw(created.parent);
            const added = try live.add(parent, created.name, created.is_dir, created.moved_to);
            applied_count += @intFromBool(added);
        },
        .modified => {},
        .removed => |removed| {
            applied_count += @intFromBool(live.remove(.fromRaw(removed.parent), removed.name));
        },
        .dir_gone => |raw_id| {
            const id: EntryId = .fromRaw(raw_id);
            // The watched directory went away, and its subtree with it.
            // Unless its path is still there: a MOVE_SELF read in a later
            // batch than the move's MOVED_TO carries the id the watch was
            // re-pointed to (the rescanned destination), and tombstoning it
            // made a directory moved inside the tree vanish.
            if (!live.alive(id)) continue;
            if (live.pathExists(id)) continue;
            live.stats.removed += live.tombstoneTree(id);
            applied_count += 1;
        },
        // Returned above: an overflow resyncs instead.
        .overflow => unreachable,
    };
    assert(applied_count <= changes.len);
    if (applied_count > 0) {
        live.dirty = true;
        try live.delta.rebuild(live.gpa);
    }
    // With scans pending, `addScans` prunes once their watches re-pointed
    // the descriptors of a directory moved inside the tree.
    if (live.scans.items.len == 0) live.pruneWatches();
    return applied_count;
}

/// The delta id an event's parent maps to, if any. `add` and `remove` both
/// go through here: when they resolved parents differently, deleting
/// something added after the scan did nothing (bug found in the Rust one).
fn deltaParent(live: *Live, parent: EntryId) ?u32 {
    if (parent.in_delta) {
        if (parent.index >= live.delta.len()) return null;
        return parent.index;
    }
    var path_buffer: paths.Buffer = undefined;
    const parent_path = live.pathOf(parent, &path_buffer) orelse return null;
    return live.delta.roots.get(parent_path);
}

/// The live entry named `name` in directory `parent`. It may be in the base
/// or added to the delta after the scan.
fn childOf(live: *Live, parent: EntryId, name: []const u8) ?EntryId {
    if (!parent.in_delta and parent.index < live.base.len()) {
        if (live.base.findChild(parent.index, name)) |index| return .ofBase(index);
    }
    const delta_parent = live.deltaParent(parent) orelse return null;
    const delta_index = live.delta.child(delta_parent, name) orelse return null;
    return .ofDelta(delta_index);
}

fn remove(live: *Live, parent: EntryId, name: []const u8) bool {
    const id = live.childOf(parent, name) orelse return false;
    live.stats.removed += live.tombstoneTree(id);
    return true;
}

/// Whether entry `id` is still in the index. A directory moved out of the
/// tree keeps its watch until `pruneWatches`.
fn alive(live: *const Live, id: EntryId) bool {
    if (id.in_delta) return live.delta.alive(id.index);
    if (id.index >= live.base.len()) return false;
    return !live.base.isTombstoned(id.index);
}

/// `alive` for the Watcher, which keeps ids raw.
fn aliveWatched(live: *const Live, raw_id: u32) bool {
    return live.alive(.fromRaw(raw_id));
}

fn isDirEntry(live: *const Live, id: EntryId) bool {
    if (id.in_delta) return live.delta.isDir(id.index);
    return live.base.isDir(id.index);
}

fn pathExists(live: *const Live, id: EntryId) bool {
    var path_buffer: paths.Buffer = undefined;
    const path = live.pathOf(id, path_buffer[0 .. path_buffer.len - 1]) orelse return false;
    if (path.len == 0) return false;
    path_buffer[path.len] = 0;
    return sys.exists(path_buffer[0..path.len :0]);
}

/// Hidden as the scan sets it: by name, and inherited from the parent.
/// Without it, new files under a dot-dir ranked as the user's own until the
/// next rescan.
fn hiddenFlag(live: *const Live, parent: EntryId, name: []const u8) u8 {
    const parent_flags = if (parent.in_delta)
        live.delta.flags(parent.index)
    else
        live.base.flags()[parent.index];
    if (parent_flags & store_mod.flag_hidden != 0) return store_mod.flag_hidden;
    if (scan.hiddenByName(name)) return store_mod.flag_hidden;
    return 0;
}

/// Tombstones entry `id` and its subtree.
fn tombstoneTree(live: *Live, id: EntryId) usize {
    if (live.isDirEntry(id)) live.prune_watches = true;
    if (id.in_delta) return live.tombstonedCount(live.delta.tombstoneTree(live.gpa, id.index));
    return live.tombstoneBaseTree(id.index);
}

/// How many entries a delta tombstone walk took out. One that ran out of
/// memory may have left part of a subtree searchable: the index is rebuilt
/// instead.
fn tombstonedCount(live: *Live, tombstoned: Delta.Tombstoned) usize {
    if (!tombstoned.complete) live.pending_resync = true;
    return tombstoned.count;
}

/// Tombstones an entry and its whole subtree. Moving a directory sends one
/// event, for the directory; `path()` walks up and never checks ancestors,
/// so without this the children stay searchable under dead paths.
fn tombstoneBaseTree(live: *Live, root: u32) usize {
    var tombstoned_count: usize = if (live.base.isDir(root)) live.tombstoneDeltaUnder(root) else 0;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(live.gpa);
    // Out of memory: part of the subtree would stay searchable under dead
    // paths, so the index is rebuilt instead.
    stack.append(live.gpa, root) catch {
        live.pending_resync = true;
        return tombstoned_count;
    };
    var graves: usize = 0;
    while (stack.pop()) |id| {
        if (live.base.isTombstoned(id)) continue;
        if (live.base.isDir(id)) {
            const children = live.base.children(id);
            var child = children.lo;
            while (child < children.hi) : (child += 1) {
                stack.append(live.gpa, child) catch {
                    live.pending_resync = true;
                };
            }
        }
        live.base.tombstone(id);
        graves += 1;
    }
    live.graves += graves;
    tombstoned_count += graves;
    return tombstoned_count;
}

/// What was added after the scan below base directory `directory` (see
/// `Delta.tombstoneUnder`).
fn tombstoneDeltaUnder(live: *Live, directory: u32) usize {
    var path_buffer: paths.Buffer = undefined;
    const dir_path = live.base.path(directory, &path_buffer) orelse return 0;
    return live.tombstonedCount(live.delta.tombstoneUnder(live.gpa, dir_path));
}

fn add(live: *Live, parent: EntryId, name: []const u8, is_dir: bool, moved_to: bool) !bool {
    // A directory moved out of the tree is still watched: what happens in
    // it now must not come back under its old path.
    if (!live.alive(parent)) return false;
    if (live.childOf(parent, name)) |known| {
        // Already indexed: an IN_MOVED_TO of something known, or what a
        // rescan read before its event came (`IN_CREATE`). No duplicate.
        // Only an `IN_MOVED_TO` directory over an existing one (`mv -T a b`)
        // replaces unknown contents and needs tombstoning + rescanning.
        if (!moved_to or !is_dir or !live.isDirEntry(known)) return false;
        live.stats.removed += live.tombstoneTree(known);
    }
    var parent_path_buffer: paths.Buffer = undefined;
    const parent_path = live.pathOf(parent, &parent_path_buffer) orelse return false;
    const depth = live.depthOf(parent) +| 1;
    const hidden = live.hiddenFlag(parent, name);
    // A parent already in the delta is used as is; a base parent gets a
    // scaffolding root.
    const root: u32 = if (parent.in_delta)
        parent.index
    else
        try live.delta.root(live.gpa, parent_path, depth -| 1);

    // Without the scan's rule, `npm install` scanned and watched the whole
    // new node_modules.
    if (is_dir and scan.shouldDescend(parent_path, name, live.config)) {
        // inotify race: files may have appeared before the watch existed, so
        // a new directory is read whole (`readScans`).
        var full_path_buffer: paths.Buffer = undefined;
        const full = std.mem.print(&full_path_buffer, "{s}{s}{s}", .{
            parent_path,
            paths.separatorAfter(parent_path),
            name,
        }) catch return false;
        const path = try live.gpa.dupeSentinel(u8, full, 0);
        errdefer live.gpa.free(path);
        try live.scans.ensureUnusedCapacity(live.gpa, 1);
        const folder_flags = store_mod.flag_dir | store_mod.flag_folder;
        const id = try live.delta.push(live.gpa, name, root, folder_flags | hidden, depth);
        live.scans.appendAssumeCapacity(.{
            .directory = id,
            .path = path,
            .depth = depth,
            .hidden = hidden,
        });
    } else {
        // A file, or a directory skipped like the scan does: searchable,
        // never opened.
        const folder: u8 = if (is_dir) store_mod.flag_folder else 0;
        _ = try live.delta.push(live.gpa, name, root, hidden | folder, depth);
    }
    live.stats.added += 1;
    return true;
}

/// Queues directory `id` at `path` for `readRechecks`. Out of memory, the
/// index may miss what it gets before it is watched: a rescan instead.
fn recheckLater(live: *Live, id: EntryId, path: []const u8) void {
    const path_owned = live.gpa.dupeSentinel(u8, path, 0) catch {
        live.pending_resync = true;
        return;
    };
    live.rechecks.append(live.gpa, .{ .directory = id.raw(), .path = path_owned }) catch {
        live.gpa.free(path_owned);
        live.pending_resync = true;
    };
}

/// The directories `addScans` watched, to list again (`readRechecks`).
pub fn takeRechecks(live: *Live) Rechecks {
    const rechecks = live.rechecks;
    live.rechecks = .empty;
    return rechecks;
}

pub fn freeRechecks(gpa: std.mem.Allocator, rechecks: *Rechecks) void {
    for (rechecks.items) |recheck| gpa.free(recheck.path);
    rechecks.deinit(gpa);
}

/// Lists each directory of `rechecks` again, names into `arena`. False
/// when they hold more than `entries_max` entries in all or memory ran
/// out: the caller rescans instead. Touches nothing of the index: runs
/// without the lock.
pub fn readRechecks(arena: std.mem.Allocator, rechecks: []Recheck, entries_max: usize) bool {
    var entries_count: usize = 0;
    for (rechecks) |*recheck| {
        const fd = sys.openDirNoFollow(recheck.path) catch |err| {
            recheck.status = switch (err) {
                error.NotFound, error.IsLink => .gone,
                else => .unreadable,
            };
            continue;
        };
        defer sys.close(fd);
        var found: std.ArrayList(Recheck.Found) = .empty;
        var entries: sys.DirIter = .{ .fd = fd };
        while (entries.next() catch null) |entry| {
            entries_count += 1;
            if (entries_count > entries_max) return false;
            var kind = entry.kind;
            if (kind == sys.Kind.unknown) {
                var name_buffer: [std.os.linux.NAME_MAX + 1]u8 = undefined;
                if (std.mem.printSentinel(&name_buffer, "{s}", .{entry.name}, 0)) |name_z| {
                    kind = sys.kindAt(fd, name_z);
                } else |_| {}
            }
            const name = arena.dupe(u8, entry.name) catch return false;
            const is_dir = kind == sys.Kind.directory;
            found.append(arena, .{ .name = name, .is_dir = is_dir }) catch return false;
        }
        recheck.found = found.items;
        recheck.status = .read;
    }
    return true;
}

/// Synchronizes `rechecks` directories: adds entries that appeared before
/// the watch existed, and removes ghost entries deleted or renamed away in
/// that same window.
pub fn applyRechecks(live: *Live, rechecks: []const Recheck) std.mem.Allocator.Error!bool {
    var changed = false;
    var present: std.StringHashMapUnmanaged(void) = .empty;
    defer present.deinit(live.gpa);
    var ghosts: std.ArrayList(u32) = .empty;
    defer ghosts.deinit(live.gpa);

    for (rechecks) |recheck| {
        const parent: EntryId = .fromRaw(recheck.directory);
        if (!live.alive(parent)) continue;
        switch (recheck.status) {
            .gone => {
                live.stats.removed += live.tombstoneTree(parent);
                changed = true;
                continue;
            },
            .unread, .unreadable => continue,
            .read => {},
        }
        for (recheck.found) |found| {
            if (live.childOf(parent, found.name) != null) continue;
            if (try live.add(parent, found.name, found.is_dir, false)) changed = true;
        }
        if (parent.in_delta) {
            present.clearRetainingCapacity();
            ghosts.clearRetainingCapacity();
            present.ensureUnusedCapacity(live.gpa, @intCast(recheck.found.len)) catch {
                live.pending_resync = true;
                continue;
            };
            for (recheck.found) |found| present.putAssumeCapacity(found.name, {});
            if (live.delta.kids.get(parent.index)) |kids| {
                const builder = &live.delta.builder;
                for (kids.items) |kid| {
                    if (builder.masks.items[kid] == 0) continue;
                    const offset = builder.name_offsets.items[kid];
                    const kid_name = builder.names.items[offset..][0..builder.name_sizes.items[kid]];
                    if (!present.contains(kid_name)) {
                        ghosts.append(live.gpa, kid) catch {
                            live.pending_resync = true;
                            break;
                        };
                    }
                }
            }
            for (ghosts.items) |kid| {
                live.stats.removed += live.tombstoneTree(.ofDelta(kid));
                changed = true;
            }
        }
    }
    if (changed) {
        live.dirty = true;
        try live.delta.rebuild(live.gpa);
        live.pruneWatches();
    }
    return changed;
}

/// The directories `apply` left to read. Between this and `addScans`
/// nothing else may change the index: the service's thread does both,
/// with only `readScans` (and searches) in between.
pub fn takeScans(live: *Live) Scans {
    const scans = live.scans;
    live.scans = .empty;
    return scans;
}

pub fn freeScans(gpa: std.mem.Allocator, scans: *Scans) void {
    for (scans.items) |*scan_job| scan_job.deinit(gpa);
    scans.deinit(gpa);
}

/// Reads what the directories in `scans` hold, never following a link
/// (one swapped in for the new folder, say to `/`, was walked whole).
/// Touches nothing of the index: runs without the lock.
pub fn readScans(
    gpa: std.mem.Allocator,
    pool: *Pool,
    config: *const scan.Config,
    scans: []Scan,
    entries_max: usize,
) void {
    // For the whole batch, not each directory: 300 new folders of 15 k
    // entries each were all read, then added under the lock.
    var entries_left = entries_max;
    for (scans) |*scan_job| {
        if (entries_left == 0) {
            scan_job.outcome = .too_big;
            continue;
        }
        var sub_config = config.*;
        const roots = [_][]const u8{scan_job.path};
        sub_config.roots = &roots;
        sub_config.follow_roots = false;
        sub_config.entries_max = entries_left;
        var scan_stats: scan.Stats = .{};
        var unreadable: std.ArrayList([]u8) = .empty;
        errdefer sys.freeList(gpa, unreadable.items);
        var sub = scan.scanCollectingUnreadable(gpa, pool, &sub_config, null, &scan_stats, &unreadable) catch {
            sys.freeList(gpa, unreadable.items);
            scan_job.outcome = .failed;
            continue;
        };
        if (scan_stats.truncated) {
            sub.deinit(gpa);
            sys.freeList(gpa, unreadable.items);
            scan_job.outcome = .too_big;
            continue;
        }
        scan_job.unreadable = unreadable.toOwnedSlice(gpa) catch blk: {
            sys.freeList(gpa, unreadable.items);
            break :blk &.{};
        };
        entries_left -|= sub.len();
        scan_job.outcome = .{ .read = sub };
    }
}

pub fn addRetryDir(live: *Live, dir: []const u8) std.mem.Allocator.Error!void {
    for (live.retry_dirs) |existing| {
        if (std.mem.eql(u8, existing, dir)) return;
    }
    const copy = try live.gpa.dupe(u8, dir);
    errdefer live.gpa.free(copy);
    const grown = try live.gpa.realloc(live.retry_dirs, live.retry_dirs.len + 1);
    grown[grown.len - 1] = copy;
    live.retry_dirs = grown;
}

/// Adds what `readScans` found under each directory's entry and watches
/// the directories, then frees `scans`. Every scan went through
/// `readScans`.
pub fn addScans(live: *Live, scans: *Scans) std.mem.Allocator.Error!void {
    defer freeScans(live.gpa, scans);
    var added = false;
    for (scans.items) |*scan_job| {
        for (scan_job.unreadable) |dir| live.addRetryDir(dir) catch {};
        // Removed again before it was read (later in the same batch).
        if (!live.delta.alive(scan_job.directory)) continue;
        const sub = switch (scan_job.outcome) {
            .read => |*sub| sub,
            .failed, .too_big => {
                live.pending_resync = true;
                continue;
            },
            .unread => unreachable,
        };
        const map = try live.delta.appendStore(
            live.gpa,
            sub,
            scan_job.directory,
            scan_job.depth,
            scan_job.hidden,
        );
        defer live.gpa.free(map);
        // Watch the new directories under their delta ids, or events from
        // inside could not be attributed.
        var path_buffer: paths.Buffer = undefined;
        for (0..sub.len()) |sub_index| {
            const id: u32 = @intCast(sub_index);
            if (!sub.isDir(id)) continue;
            const path = pathZ(sub, id, &path_buffer) orelse continue;
            const delta_id: EntryId = .ofDelta(map[sub_index]);
            try live.watcher.watchBestEffort(live.gpa, path, delta_id.raw(), .below_root);
            live.recheckLater(delta_id, std.mem.span(path));
        }
        live.stats.added += sub.len() - 1;
        added = true;
    }
    if (added) {
        live.dirty = true;
        try live.delta.rebuild(live.gpa);
    }
    live.pruneWatches();
}

/// `takeScans`, `readScans` and `addScans` with the lock held throughout,
/// for callers that hold it anyway (tests).
pub fn finishScans(live: *Live) std.mem.Allocator.Error!void {
    while (true) {
        if (live.scans.items.len > 0) {
            var scans = live.takeScans();
            const entries_max = live.limits.delta_entries_max;
            readScans(live.gpa, live.scan_pool, live.config, scans.items, entries_max);
            try live.addScans(&scans);
        }
        var rechecks = live.takeRechecks();
        defer freeRechecks(live.gpa, &rechecks);
        if (rechecks.items.len == 0) return;
        var arena_state: std.heap.ArenaAllocator = .init(live.gpa);
        defer arena_state.deinit();
        const entries_max = live.limits.delta_entries_max;
        if (!readRechecks(arena_state.allocator(), rechecks.items, entries_max)) {
            live.pending_resync = true;
            return;
        }
        _ = try live.applyRechecks(rechecks.items);
    }
}

/// Drops the watches of directories that left the index (moved out of the
/// tree: the kernel only drops a deleted one's), once a batch tombstoned
/// one: a pass over every watch.
fn pruneWatches(live: *Live) void {
    if (!live.prune_watches) return;
    live.prune_watches = false;
    live.watcher.prune(live.gpa, @as(*const Live, live), aliveWatched);
    live.stats.watches = live.watcher.count();
}

/// The path of entry `id`, or null if it is gone or does not fit
/// `path_buffer`. Reads `delta.builder` for delta entries so paths created
/// earlier in the same `apply()` batch resolve before `delta.rebuild()`.
pub fn pathOf(live: *const Live, id: EntryId, path_buffer: []u8) ?[]const u8 {
    if (id.in_delta) return live.delta.builder.path(id.index, path_buffer);
    if (id.index >= live.base.len()) return null;
    return live.base.path(id.index, path_buffer);
}

fn depthOf(live: *const Live, id: EntryId) u16 {
    if (id.in_delta) {
        if (id.index >= live.delta.len()) return 0;
        return live.delta.builder.depths.items[id.index];
    }
    if (id.index >= live.base.len()) return 0;
    return live.base.depths()[id.index];
}

/// Searches base and delta and merges by score. Paths are allocated in
/// `arena`.
pub fn search(
    live: *Live,
    arena: std.mem.Allocator,
    pool: *Pool,
    query: []const u8,
    options: engine.Options,
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    const limit = options.limit;
    var engine_options = options;
    engine_options.no_stat = live.slow_mounts;
    out.clearRetainingCapacity();
    var hits: std.ArrayList(engine.Hit) = .empty;
    defer hits.deinit(live.gpa);
    var path_buffer: paths.Buffer = undefined;
    try live.engine_base.search(live.gpa, pool, &live.base, query, engine_options, &hits);
    // A path that does not fit (deeper than PATH_MAX) cannot be opened:
    // left out, where it used to come out as "" (and dedup as one).
    for (hits.items) |hit| try out.append(arena, .{
        .path = try arena.dupe(u8, live.base.path(hit.id, &path_buffer) orelse continue),
        .score = hit.score,
        .is_dir = live.base.isFolder(hit.id),
    });
    if (live.delta.store.len() > 0) {
        const delta = &live.delta;
        try delta.engine.search(live.gpa, pool, &delta.store, query, engine_options, &hits);
        for (hits.items) |hit| try out.append(arena, .{
            .path = try arena.dupe(u8, live.delta.store.path(hit.id, &path_buffer) orelse continue),
            .score = hit.score,
            .is_dir = live.delta.store.isFolder(hit.id),
        });
    }
    std.mem.sort(Hit, out.items, {}, hitBefore);
    // Something can be in both (created during a rescan): keep the best.
    // By set, not by neighbour: the two copies need not score the same, and
    // another hit between them left both in.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(live.gpa);
    var kept_count: usize = 0;
    for (out.items) |hit| {
        if ((try seen.getOrPut(live.gpa, hit.path)).found_existing) continue;
        out.items[kept_count] = hit;
        kept_count += 1;
    }
    out.shrinkRetainingCapacity(@min(kept_count, limit));
    assert(out.items.len <= limit);
    if (out.items.len > 1) {
        for (out.items[0 .. out.items.len - 1], out.items[1..]) |better, worse| {
            assert(!hitBefore({}, worse, better));
        }
    }
}

/// Best score first; equal scores by path, so the order is stable.
fn hitBefore(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Swaps in a freshly built index and returns the old one. Returning it
/// matters: dropping a watcher with 72k watches takes the kernel
/// milliseconds; done here it would be done with the lock held (worst
/// search went from 1.7 to 19.8 ms in the Rust version). On error nothing
/// changed and `base` and `watcher` are still the caller's.
pub fn adopt(live: *Live, fresh: Replaced) std.mem.Allocator.Error!Replaced {
    // The only fallible step, first: the new index starts with an empty delta.
    const delta: Delta = try .init(live.gpa);
    var old: Replaced = .{ .base = live.base, .watcher = live.watcher };
    live.base = fresh.base;
    live.graves = fresh.graves;
    const watcher = fresh.watcher;
    live.watcher = watcher;
    live.stats.watches = watcher.count();
    // A rescan's watcher was armed as it scanned.
    live.arm_cursor = null;
    live.delta.deinit(live.gpa);
    live.delta = delta;
    freeScans(live.gpa, &live.scans);
    live.scans = .empty;
    freeRechecks(live.gpa, &live.rechecks);
    live.rechecks = .empty;
    live.prune_watches = false;
    live.pending_resync = false;
    live.dirty = false;
    live.last_compact_ns = sys.monotonicNs();
    live.engine_base.reset();
    // What was mounted since the last rescan; the old list goes with the
    // old index, freed outside the lock.
    if (fresh.slow_mounts) |mounts| {
        old.slow_mounts = live.slow_mounts;
        live.slow_mounts = mounts;
    }
    if (fresh.retry_dirs) |dirs| {
        old.retry_dirs = live.retry_dirs;
        live.retry_dirs = dirs;
    }
    return old;
}

/// `sys.slowMounts` under every root.
fn slowMountsOf(gpa: std.mem.Allocator, config: *const scan.Config) std.mem.Allocator.Error![][]u8 {
    var all: std.ArrayList([]u8) = .empty;
    errdefer {
        for (all.items) |mount| gpa.free(mount);
        all.deinit(gpa);
    }
    for (config.roots) |root| {
        const list = try sys.slowMounts(gpa, root);
        defer gpa.free(list);
        all.ensureUnusedCapacity(gpa, list.len) catch |err| {
            for (list) |mount| gpa.free(mount);
            return err;
        };
        all.appendSliceAssumeCapacity(list);
    }
    return all.toOwnedSlice(gpa);
}

/// True when the layers on top weigh enough to be worth a rescan, or when
/// changes have been waiting too long to reach the file.
pub fn needsCompaction(live: *const Live) bool {
    const graves = live.graves;
    const limits = live.limits;
    const delta_full = live.delta.store.len() > limits.delta_entries_max;
    const graves_share = live.base.len() / limits.graves_divisor;
    const graves_many = graves > limits.graves_min and graves > graves_share;
    if (delta_full or graves_many) return true;
    return live.dirty and sys.monotonicNs() -| live.last_compact_ns >= limits.interval_ns;
}

/// Builds the replacement index without touching the current one: the
/// expensive part runs unlocked, alongside searches. Watching while scanning
/// means nothing that changes meanwhile is lost.
pub fn prepareCompaction(
    gpa: std.mem.Allocator,
    pool: *Pool,
    config: *const scan.Config,
    cache_path: ?[:0]const u8,
) (std.mem.Allocator.Error || Watcher.CreateError)!Replaced {
    const watcher = try Watcher.create(gpa);
    errdefer watcher.destroy(gpa);
    var unreadable: std.ArrayList([]u8) = .empty;
    errdefer {
        for (unreadable.items) |dir| gpa.free(dir);
        unreadable.deinit(gpa);
    }
    const base = try scanSavedCollecting(gpa, pool, config, watcher, cache_path, &unreadable);
    return .{
        .base = base,
        .watcher = watcher,
        .graves = base.len() - base.liveCount(),
        // Out of memory: unknown, the list before stays.
        .slow_mounts = slowMountsOf(gpa, config) catch null,
        .retry_dirs = try unreadable.toOwnedSlice(gpa),
    };
}

/// A fresh scan, saved to `cache_path` when there is one and mapped
/// directly from our own written descriptor so concurrent writers cannot
/// swap the backing index behind the watcher. With no `watcher`, nothing is
/// watched: what a shutdown saves is never served (arming ~72 k inotify
/// watches only to drop them took seconds).
pub fn scanSaved(
    gpa: std.mem.Allocator,
    pool: *Pool,
    config: *const scan.Config,
    watcher: ?*Watcher,
    cache_path: ?[:0]const u8,
) std.mem.Allocator.Error!Store {
    return scanSavedCollecting(gpa, pool, config, watcher, cache_path, null);
}

fn scanSavedCollecting(
    gpa: std.mem.Allocator,
    pool: *Pool,
    config: *const scan.Config,
    watcher: ?*Watcher,
    cache_path: ?[:0]const u8,
    unreadable: ?*std.ArrayList([]u8),
) std.mem.Allocator.Error!Store {
    var base = if (unreadable) |list|
        try scan.scanCollectingUnreadable(gpa, pool, config, watcher, null, list)
    else
        try scan.scan(gpa, pool, config, watcher, null);
    errdefer base.deinit(gpa);
    if (cache_path) |path| {
        if (std.mem.findScalarLast(u8, path, '/')) |slash| {
            // The save below fails and says so.
            sys.mkdirP(path[0..slash]) catch |err| log.warn("{s}: {t}", .{ path[0..slash], err });
        }
        // Save and map via the open descriptor before closing so concurrent
        // writers replacing `path` cannot mismatch `base` and `watcher`.
        if (base.saveAndMap(path)) |mapped| {
            base.deinit(gpa);
            base = mapped;
        } else |err| {
            log.warn("saving the file index: {t}", .{err});
        }
    }
    return base;
}

fn pathZ(store: *const Store, id: u32, path_buffer: *paths.Buffer) ?[*:0]const u8 {
    const path = store.path(id, path_buffer[0 .. path_buffer.len - 1]) orelse return null;
    if (path.len == 0) return null;
    path_buffer[path.len] = 0;
    return path_buffer[0..path.len :0];
}

// ---------------------------------------------------------------- tests
//
// Driven by hand, no thread: inotify queues events inside the syscall that
// causes them, so after a mutation one `sync` (drain + apply) sees it all.

const testing = std.testing;
const linux = std.os.linux;

/// A temp dir with the indexed tree at `<tmp>/root` (so there is an outside
/// on the same filesystem to move things to) and a live index over it.
const Tree = struct {
    temporary: testing.TmpDir,
    temporary_path_buffer: paths.Buffer = undefined,
    /// Absolute path of the temp dir.
    temporary_path: []const u8 = "",
    root_buffer: paths.Buffer = undefined,
    root: []const u8 = "",
    roots: [1][]const u8 = undefined,
    config: scan.Config = undefined,
    pool: *Pool,
    live: Live = undefined,
    arena: std.heap.ArenaAllocator,
    hits: std.ArrayList(Hit) = .empty,

    /// `entries` are relative to the root; a trailing '/' makes a directory.
    fn create(entries: []const []const u8) !*Tree {
        const gpa = testing.allocator;
        const tree = try gpa.create(Tree);
        errdefer gpa.destroy(tree);
        tree.* = .{
            .temporary = testing.tmpDir(.{}),
            .pool = try Pool.create(gpa, testing.io, 2),
            .arena = .init(gpa),
        };
        tree.temporary_path = try sys.tmpDirAbs(&tree.temporary, &tree.temporary_path_buffer);
        tree.root = try std.mem.print(&tree.root_buffer, "{s}/root", .{tree.temporary_path});
        tree.roots = .{tree.root};
        tree.config = .{ .roots = &tree.roots };
        tree.makeAbsolute("root/");
        tree.makeAbsolute("outside/");
        for (entries) |entry| tree.make(entry);
        const base = try scan.scan(gpa, tree.pool, &tree.config, null, null);
        tree.live = try Live.initUnarmed(gpa, base, &tree.config, tree.pool);
        while (tree.live.armProgress(1000)) {}
        return tree;
    }

    fn destroy(tree: *Tree) void {
        tree.live.deinit();
        tree.pool.destroy();
        tree.arena.deinit();
        tree.temporary.cleanup();
        testing.allocator.destroy(tree);
    }

    /// Absolute path of `relative`, relative to the temp dir.
    fn absolute(tree: *Tree, relative: []const u8, path_buffer: *paths.Buffer) [:0]const u8 {
        return std.mem.printSentinel(
            path_buffer,
            "{s}/{s}",
            .{ tree.temporary_path, std.mem.trimEnd(u8, relative, "/") },
            0,
        ) catch unreachable;
    }

    fn makeAbsolute(tree: *Tree, relative: []const u8) void {
        var path_buffer: paths.Buffer = undefined;
        if (std.mem.endsWith(u8, relative, "/")) {
            sys.mkdirP(tree.absolute(relative, &path_buffer)) catch unreachable;
        } else {
            if (std.mem.findScalarLast(u8, relative, '/')) |slash| {
                sys.mkdirP(tree.absolute(relative[0..slash], &path_buffer)) catch unreachable;
            }
            sys.writeFile(tree.absolute(relative, &path_buffer), "x") catch unreachable;
        }
    }

    /// Creates `relative` (relative to the root), parents included.
    fn make(tree: *Tree, relative: []const u8) void {
        var path_buffer: paths.Buffer = undefined;
        tree.makeAbsolute(std.mem.print(&path_buffer, "root/{s}", .{relative}) catch unreachable);
    }

    /// Deletes `relative` (relative to the root): a file, or an empty directory.
    fn remove(tree: *Tree, relative: []const u8) void {
        var relative_buffer: paths.Buffer = undefined;
        var path_buffer: paths.Buffer = undefined;
        const in_root = std.mem.print(&relative_buffer, "root/{s}", .{relative}) catch unreachable;
        const path = tree.absolute(in_root, &path_buffer);
        const directory = std.mem.endsWith(u8, relative, "/");
        const result = if (directory) linux.rmdir(path) else linux.unlink(path);
        assert(linux.errno(result) == .SUCCESS);
    }

    /// Renames, both paths relative to the temp dir.
    fn move(tree: *Tree, source: []const u8, destination: []const u8) void {
        var source_buffer: paths.Buffer = undefined;
        var destination_buffer: paths.Buffer = undefined;
        const source_path = tree.absolute(source, &source_buffer);
        sys.rename(source_path, tree.absolute(destination, &destination_buffer)) catch unreachable;
    }

    /// Drains and applies everything pending; returns how many took effect.
    fn sync(tree: *Tree) !usize {
        var applied_count: usize = 0;
        while (true) {
            var changes: std.ArrayList(Watcher.Change) = .empty;
            try tree.live.watcher.drain(tree.arena.allocator(), &changes);
            if (changes.items.len == 0) return applied_count;
            applied_count += try tree.live.apply(changes.items);
            try tree.live.finishScans();
        }
    }

    fn searchWith(tree: *Tree, query: []const u8, options: engine.Options) ![]const Hit {
        try tree.live.search(tree.arena.allocator(), tree.pool, query, options, &tree.hits);
        return tree.hits.items;
    }

    /// Hits for `query` whose path ends in "<root>/<relative>".
    fn count(tree: *Tree, query: []const u8, relative: []const u8) !usize {
        var path_buffer: paths.Buffer = undefined;
        const want = try std.mem.print(&path_buffer, "{s}/{s}", .{ tree.root, relative });
        var matches: usize = 0;
        const hits = try tree.searchWith(query, .{ .limit = 50, .recency = false });
        for (hits) |hit| matches += @intFromBool(std.mem.eql(u8, hit.path, want));
        return matches;
    }

    fn found(tree: *Tree, query: []const u8, relative: []const u8) !bool {
        return try tree.count(query, relative) > 0;
    }

    /// Hits whose path is anywhere under the temp dir's `relative`. The root
    /// entry is left out: its name is its whole path, which a short query
    /// can match by chance.
    fn under(tree: *Tree, query: []const u8, relative: []const u8) !usize {
        var path_buffer: paths.Buffer = undefined;
        const parts = .{ tree.temporary_path, relative };
        const prefix = try std.mem.print(&path_buffer, "{s}/{s}", parts);
        var matches: usize = 0;
        for (try tree.searchWith(query, .{ .limit = 50, .recency = false })) |hit| {
            const below = std.mem.startsWith(u8, hit.path, prefix);
            matches += @intFromBool(below and !std.mem.eql(u8, hit.path, tree.root));
        }
        return matches;
    }

    /// Stands in for `Service.rescan`, without the lock to release.
    fn compact(tree: *Tree) !void {
        const fresh = try prepareCompaction(testing.allocator, tree.pool, &tree.config, null);
        const old = try tree.live.adopt(fresh);
        old.deinit(testing.allocator);
    }

    fn scoreOf(tree: *Tree, query: []const u8, relative: []const u8) !?i32 {
        var path_buffer: paths.Buffer = undefined;
        const want = try std.mem.print(&path_buffer, "{s}/{s}", .{ tree.root, relative });
        const hits = try tree.searchWith(query, .{ .limit = 50, .recency = false });
        for (hits) |hit| {
            if (std.mem.eql(u8, hit.path, want)) return hit.score;
        }
        return null;
    }
};

const sample_tree = [_][]const u8{
    "src/main.rs",
    "Cargo.toml",
    "modulo/interno/hoja.rs",
    "modulo/raiz.rs",
};

test "live: moving a directory out of the tree leaves no ghost paths" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    try testing.expect(try tree.found("hoja", "modulo/interno/hoja.rs"));
    const watches = tree.live.watcher.count();

    // One IN_MOVED_FROM, for the directory: the whole subtree must go.
    tree.move("root/modulo", "outside/modulo");
    _ = try tree.sync();
    try testing.expectEqual(0, try tree.under("hoja", "root/modulo"));
    try testing.expectEqual(0, try tree.under("raiz", "root/modulo"));
    try testing.expectEqual(0, try tree.under("interno", "root/modulo"));
    try testing.expect(try tree.found("main", "src/main.rs"));
    // Its watches and its folder's went with it: modulo and interno.
    try testing.expectEqual(watches - 2, tree.live.watcher.count());
    try testing.expectEqual(watches - 2, tree.live.stats.watches);

    // What happens out there now must not come back under the old path.
    tree.makeAbsolute("outside/modulo/despues.rs");
    tree.makeAbsolute("outside/modulo/interno/tambien.rs");
    tree.makeAbsolute("outside/modulo/nuevo_dir/");
    _ = try tree.sync();
    try testing.expectEqual(0, try tree.under("despues", ""));
    try testing.expectEqual(0, try tree.under("tambien", ""));
    try testing.expectEqual(0, try tree.under("nuevo_dir", ""));
}

test "live: moving a directory inside the tree reindexes it at the new path" {
    const tree = try Tree.create(&(sample_tree ++ [_][]const u8{"otro/"}));
    defer tree.destroy();
    const watches = tree.live.watcher.count();

    tree.move("root/modulo", "root/otro/renombrado");
    _ = try tree.sync();
    try testing.expect(try tree.found("hoja", "otro/renombrado/interno/hoja.rs"));
    try testing.expect(try tree.found("raiz", "otro/renombrado/raiz.rs"));
    try testing.expectEqual(0, try tree.under("hoja", "root/modulo"));
    try testing.expectEqual(0, try tree.under("raiz", "root/modulo"));

    // Watches are per inode: the rescanned destination re-points the same
    // descriptors, none leak, and the inside is still watched.
    try testing.expectEqual(watches, tree.live.watcher.count());
    tree.make("otro/renombrado/interno/posterior.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("posterior", "otro/renombrado/interno/posterior.rs"));
    tree.remove("otro/renombrado/interno/posterior.rs");
    _ = try tree.sync();
    try testing.expect(!try tree.found("posterior", "otro/renombrado/interno/posterior.rs"));
}

test "live: a MOVE_SELF read after the move was applied keeps the destination" {
    // The kernel queues MOVED_FROM, MOVED_TO and MOVE_SELF together, but a
    // drain can stop between them. Then MOVE_SELF is parsed after the watch
    // was re-pointed to the destination's delta entry.
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.move("root/modulo", "root/renombrado");
    _ = try tree.sync();
    try testing.expect(try tree.found("hoja", "renombrado/interno/hoja.rs"));

    var destination: ?u32 = null;
    var watch_ids = tree.live.watcher.watch_ids.valueIterator();
    var path_buffer: paths.Buffer = undefined;
    var want_buffer: paths.Buffer = undefined;
    const want = try std.mem.print(&want_buffer, "{s}/renombrado", .{tree.root});
    while (watch_ids.next()) |raw_id| {
        const id: EntryId = .fromRaw(raw_id.*);
        if (!id.in_delta) continue;
        const path = tree.live.pathOf(id, &path_buffer) orelse "";
        if (std.mem.eql(u8, path, want)) destination = raw_id.*;
    }
    try testing.expect(destination != null);
    _ = try tree.live.apply(&.{.{ .dir_gone = destination.? }});
    try testing.expect(try tree.found("hoja", "renombrado/interno/hoja.rs"));
    try testing.expect(try tree.found("renombrado", "renombrado"));
}

test "live: what a new directory gets between its read and its watch is kept" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.make("fresco/primero.rs");
    var changes: std.ArrayList(Watcher.Change) = .empty;
    try tree.live.watcher.drain(tree.arena.allocator(), &changes);
    _ = try tree.live.apply(changes.items);
    var scans = tree.live.takeScans();
    try testing.expect(scans.items.len > 0);
    const entries_max = tree.live.limits.delta_entries_max;
    readScans(tree.live.gpa, tree.live.scan_pool, tree.live.config, scans.items, entries_max);
    // Read, not watched yet: no event will tell of these.
    tree.make("fresco/tardio.rs");
    tree.make("fresco/sub/hondo.rs");
    try tree.live.addScans(&scans);
    try tree.live.finishScans();
    _ = try tree.sync();
    try testing.expect(try tree.found("primero", "fresco/primero.rs"));
    try testing.expect(try tree.found("tardio", "fresco/tardio.rs"));
    try testing.expect(try tree.found("hondo", "fresco/sub/hondo.rs"));
    // And what comes after the watch arrives once, not twice.
    tree.make("fresco/sub/despues.rs");
    _ = try tree.sync();
    try testing.expectEqual(1, try tree.under("despues", "root"));
}

test "live: what was added after the scan can be deleted" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();

    // A file in the delta, under a base directory.
    tree.make("src/efimero.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("efimero", "src/efimero.rs"));
    tree.remove("src/efimero.rs");
    _ = try tree.sync();
    try testing.expect(!try tree.found("efimero", "src/efimero.rs"));

    // A file inside a directory that only exists in the delta.
    tree.make("creado/");
    _ = try tree.sync();
    try testing.expect(try tree.found("creado", "creado"));
    tree.make("creado/posterior.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("posterior", "creado/posterior.rs"));
    tree.remove("creado/posterior.rs");
    _ = try tree.sync();
    try testing.expect(!try tree.found("posterior", "creado/posterior.rs"));

    // And the delta directory itself, moved away with content inside.
    tree.make("creado/sub/hondo.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("hondo", "creado/sub/hondo.rs"));
    tree.move("root/creado", "outside/creado");
    _ = try tree.sync();
    try testing.expectEqual(0, try tree.under("hondo", "root"));
    try testing.expectEqual(0, try tree.under("creado", "root"));
}

test "live: created and deleted within one batch leaves no ghost" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.make("src/temporal.swp");
    tree.remove("src/temporal.swp");
    tree.make("fugaz_dir/");
    tree.remove("fugaz_dir/");
    _ = try tree.sync();
    try testing.expect(!try tree.found("temporal", "src/temporal.swp"));
    try testing.expect(!try tree.found("fugaz_dir", "fugaz_dir"));

    // Created, deleted, created again: there, once.
    tree.make("src/vuelve.rs");
    tree.remove("src/vuelve.rs");
    tree.make("src/vuelve.rs");
    _ = try tree.sync();
    try testing.expectEqual(1, try tree.count("vuelve", "src/vuelve.rs"));
}

test "live: a directory created with its content at once is indexed whole" {
    // The inotify race: everything below exists before any watch on it.
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.make("nuevo/interno/escondido.rs");
    tree.make("nuevo/arriba.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("escondido", "nuevo/interno/escondido.rs"));
    try testing.expect(try tree.found("arriba", "nuevo/arriba.rs"));
    try testing.expect(try tree.found("interno", "nuevo/interno"));
    try testing.expect(try tree.found("nuevo", "nuevo"));

    // And the new directories are watched from then on.
    tree.make("nuevo/interno/luego.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("luego", "nuevo/interno/luego.rs"));
}

test "live: an event for something already indexed adds no duplicate" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    const gpa = testing.allocator;

    // The rescan watches a directory, the file appears, then the directory
    // is read: it is in the scan *and* queued as an event.
    const watcher = try Watcher.create(gpa);
    var path_buffer: paths.Buffer = undefined;
    try watcher.watch(gpa, try std.mem.printSentinel(&path_buffer, "{s}", .{tree.root}, 0), 0);
    tree.make("durante.rs");
    const base = try scan.scan(gpa, tree.pool, &tree.config, watcher, null);
    const graves = base.len() - base.liveCount();
    const old = try tree.live.adopt(.{ .base = base, .watcher = watcher, .graves = graves });
    old.deinit(gpa);

    try testing.expectEqual(0, try tree.sync());
    try testing.expectEqual(1, try tree.count("durante", "durante.rs"));
    // An IN_MOVED_TO of something known, base or delta.
    try testing.expectEqual(0, try tree.live.apply(&.{.{ .created = .{
        .parent = 0,
        .name = "Cargo.toml",
        .is_dir = false,
    } }}));
    tree.make("despues.rs");
    try testing.expectEqual(1, try tree.sync());
    try testing.expectEqual(0, try tree.live.apply(&.{.{ .created = .{
        .parent = 0,
        .name = "despues.rs",
        .is_dir = false,
    } }}));
    try testing.expectEqual(1, try tree.count("despues", "despues.rs"));
    try testing.expectEqual(1, try tree.count("cargo", "Cargo.toml"));
}

test "live: a rescan watches before reading, so nothing after it is lost" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    const fresh = try prepareCompaction(testing.allocator, tree.pool, &tree.config, null);
    // Changes between the scan and the swap wait in the new watcher.
    tree.make("src/entre.rs");
    tree.remove("Cargo.toml");
    const old = try tree.live.adopt(fresh);
    old.deinit(testing.allocator);
    _ = try tree.sync();
    try testing.expect(try tree.found("entre", "src/entre.rs"));
    try testing.expect(!try tree.found("cargo", "Cargo.toml"));
}

test "live: an overflow requests a rescan and does not do it" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    try testing.expect(!tree.live.pending_resync);
    const start_ns = sys.monotonicNs();
    // Whatever else came with it is moot: a rescan follows.
    _ = try tree.live.apply(&.{
        .{ .created = .{ .parent = 0, .name = "nunca.rs", .is_dir = false } },
        .overflow,
    });
    // A rescan done here would show in the stats below; the bound only
    // catches one that blocks, with room for a loaded machine.
    try testing.expect(sys.monotonicNs() - start_ns < 500 * std.time.ns_per_ms);
    try testing.expect(tree.live.pending_resync);
    try testing.expectEqual(1, tree.live.stats.resyncs);
    try testing.expectEqual(0, tree.live.delta.store.len());

    try tree.compact();
    try testing.expect(!tree.live.pending_resync);
    try testing.expect(try tree.found("main", "src/main.rs"));
}

test "live: adopt leaves a clean index that finds the same" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.make("src/agregado.rs");
    tree.make("dir_nuevo/dentro.rs");
    tree.remove("Cargo.toml");
    tree.remove("modulo/raiz.rs");
    _ = try tree.sync();
    try testing.expect(tree.live.dirty);
    try testing.expect(tree.live.delta.store.len() > 0);
    try testing.expect(tree.live.base.liveCount() < tree.live.base.len());
    // The count kept from `graves` is the one a pass over the masks gives.
    const counted = tree.live.base.liveCount() + tree.live.delta.store.liveCount();
    try testing.expectEqual(counted, tree.live.entriesLive());

    const arena = tree.arena.allocator();
    var before: std.ArrayList([]const u8) = .empty;
    for (try tree.searchWith("rs", .{ .limit = 50, .recency = false })) |hit| {
        try before.append(arena, hit.path);
    }
    try tree.compact();

    try testing.expectEqual(0, tree.live.delta.store.len());
    try testing.expectEqual(tree.live.base.len(), tree.live.base.liveCount());
    try testing.expect(!tree.live.dirty);
    try testing.expect(tree.live.fullyArmed());
    const after = try tree.searchWith("rs", .{ .limit = 50, .recency = false });
    try testing.expectEqual(before.items.len, after.len);
    for (before.items, after) |path, hit| try testing.expectEqualStrings(path, hit.path);
    try testing.expect(try tree.found("agregado", "src/agregado.rs"));
    try testing.expect(try tree.found("dentro", "dir_nuevo/dentro.rs"));
    try testing.expect(!try tree.found("cargo", "Cargo.toml"));

    // The new watcher works: changes after the swap still arrive.
    tree.make("dir_nuevo/despues.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("despues", "dir_nuevo/despues.rs"));
}

test "live: compaction thresholds" {
    var files: [40][]const u8 = undefined;
    var names: [40][16]u8 = undefined;
    for (&files, &names, 0..) |*file, *name, i| file.* = try std.mem.print(name, "f{d}.txt", .{i});
    const tree = try Tree.create(&files);
    defer tree.destroy();
    // A long interval, so only the size thresholds speak.
    tree.live.limits.interval_ns = std.math.maxInt(u64);
    try testing.expect(!tree.live.needsCompaction());

    // Delta: strictly more than the limit.
    tree.live.limits.delta_entries_max = 3;
    tree.make("a.txt");
    tree.make("b.txt");
    _ = try tree.sync();
    // Scaffolding root + 2 files.
    try testing.expectEqual(3, tree.live.delta.store.len());
    try testing.expect(!tree.live.needsCompaction());
    tree.make("c.txt");
    _ = try tree.sync();
    try testing.expect(tree.live.needsCompaction());
    tree.live.limits.delta_entries_max = 20_000;

    // Tombstones: over the minimum *and* over 5% of the base (41 entries:
    // root and 40 files -> 5% is 2).
    try testing.expectEqual(41, tree.live.base.len());
    tree.remove("f0.txt");
    tree.remove("f1.txt");
    _ = try tree.sync();
    tree.live.limits.graves_min = 1;
    // 2 graves, not > 5%.
    try testing.expect(!tree.live.needsCompaction());
    tree.remove("f2.txt");
    _ = try tree.sync();
    try testing.expect(tree.live.needsCompaction());
    tree.live.limits.graves_min = 1_000;
    // > 5%, not > 1000.
    try testing.expect(!tree.live.needsCompaction());

    // Time: only with something to flush.
    tree.live.limits.interval_ns = 0;
    try testing.expect(tree.live.needsCompaction());
    try tree.compact();
    tree.live.limits.interval_ns = 0;
    try testing.expect(!tree.live.needsCompaction());
}

test "live: tombstones on a mapped index never reach the file" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    const gpa = testing.allocator;
    var index_path_buffer: paths.Buffer = undefined;
    const index_path = tree.absolute("files.idx", &index_path_buffer);
    try tree.live.base.save(index_path);
    var before_buffer: [64 * 1024]u8 = undefined;
    const before = sys.readHead(index_path, &before_buffer);
    try testing.expect(before.len > 0);
    try testing.expect(before.len < before_buffer.len);

    // Same entries, same ids: the armed watches stay valid.
    const mapped = try Store.open(index_path);
    tree.live.base.deinit(gpa);
    tree.live.base = mapped;
    tree.live.engine_base.reset();

    tree.remove("Cargo.toml");
    tree.move("root/modulo", "outside/modulo");
    _ = try tree.sync();
    try testing.expect(!try tree.found("cargo", "Cargo.toml"));
    try testing.expect(tree.live.base.liveCount() < tree.live.base.len());

    var after_buffer: [64 * 1024]u8 = undefined;
    try testing.expectEqualSlices(u8, before, sys.readHead(index_path, &after_buffer));
    var again = try Store.open(index_path);
    defer again.deinit(gpa);
    try testing.expectEqual(again.len(), again.liveCount());
}

test "live: recency on a file deleted but not yet applied" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.remove("src/main.rs");
    // The event is still queued: the stale entry is stat'ed and must just
    // get no bonus.
    var any = false;
    for (try tree.searchWith("main", .{ .limit = 50 })) |hit| {
        any = any or std.mem.endsWith(u8, hit.path, "/src/main.rs");
    }
    try testing.expect(any);
    _ = try tree.sync();
    for (try tree.searchWith("main", .{ .limit = 50 })) |hit| {
        try testing.expect(!std.mem.endsWith(u8, hit.path, "/src/main.rs"));
    }
}

test "live: one path in base and delta comes out once" {
    const tree = try Tree.create(&.{ "dup.txt", "dupe.txt" });
    defer tree.destroy();
    // A second copy of dup.txt in the delta, scoring far lower (hidden), so
    // dupe.txt sorts between the two.
    const root = try tree.live.delta.root(testing.allocator, tree.root, 0);
    const builder = &tree.live.delta.builder;
    _ = try builder.push(testing.allocator, "dup.txt", root, store_mod.flag_hidden, 1);
    try tree.live.delta.rebuild(testing.allocator);
    // The root entry is left out. Its name is its whole path, and the temp
    // folder's random name can hold "d", "u" and "p" in order, which made
    // the fuzzy query find it in about one run in fifteen.
    var test_paths: [4][]const u8 = undefined;
    var paths_count: usize = 0;
    for (try tree.searchWith("dup", .{ .limit = 50, .recency = false })) |hit| {
        if (std.mem.eql(u8, hit.path, tree.root)) continue;
        try testing.expect(paths_count < test_paths.len);
        test_paths[paths_count] = hit.path;
        paths_count += 1;
    }
    try testing.expectEqual(2, paths_count);
    try testing.expect(std.mem.endsWith(u8, test_paths[0], "/dup.txt"));
    try testing.expect(std.mem.endsWith(u8, test_paths[1], "/dupe.txt"));
}

test "live: new entries under a dot-dir rank like scanned ones" {
    const tree = try Tree.create(&(sample_tree ++ [_][]const u8{".config/app/"}));
    defer tree.destroy();
    tree.make(".config/zorro_nuevo.txt");
    tree.make(".config/app/zorro_dir/zorro_hondo.txt");
    tree.make(".zorro_punto.txt");
    tree.make("my_cache/");
    tree.make("my_cache/zorro_cacheado.txt");
    _ = try tree.sync();
    const cases = [_][2][]const u8{
        .{ "zorro_nuevo", ".config/zorro_nuevo.txt" },
        .{ "zorro_hondo", ".config/app/zorro_dir/zorro_hondo.txt" },
        .{ "zorro_dir", ".config/app/zorro_dir" },
        .{ "zorro_punto", ".zorro_punto.txt" },
        .{ "zorro_cacheado", "my_cache/zorro_cacheado.txt" },
    };
    var live_scores: [cases.len]i32 = undefined;
    for (cases, &live_scores) |case, *score| score.* = (try tree.scoreOf(case[0], case[1])).?;
    try tree.compact();
    for (cases, live_scores) |case, score| {
        try testing.expectEqual(score, (try tree.scoreOf(case[0], case[1])).?);
    }
}

test "live: a new skipped directory is indexed but not opened" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    const watches = tree.live.watcher.count();
    tree.make("node_modules/paquete/indice.js");
    _ = try tree.sync();
    try testing.expect(try tree.found("node_modules", "node_modules"));
    try testing.expect(!try tree.found("indice", "node_modules/paquete/indice.js"));
    try testing.expectEqual(watches, tree.live.watcher.count());
    // Same as the scan.
    try tree.compact();
    try testing.expect(try tree.found("node_modules", "node_modules"));
    try testing.expect(!try tree.found("indice", "node_modules/paquete/indice.js"));
}

test "live: files added after the scan leave with their folder" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    // In the delta, under scaffolding roots for modulo and modulo/interno,
    // and in a folder created after the scan.
    tree.make("modulo/tras_scan.rs");
    tree.make("modulo/interno/tras_scan_hondo.rs");
    tree.make("modulo/creada/tras_scan_creada.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("tras_scan", "modulo/tras_scan.rs"));
    try testing.expect(try tree.found("tras_scan_hondo", "modulo/interno/tras_scan_hondo.rs"));

    tree.move("root/modulo", "outside/modulo");
    _ = try tree.sync();
    try testing.expectEqual(0, try tree.under("tras_scan", "root"));
    try testing.expectEqual(0, try tree.under("creada", "root"));
    // Their scaffolding is forgotten with them.
    var root_paths = tree.live.delta.roots.keyIterator();
    while (root_paths.next()) |root_path| {
        try testing.expect(!std.mem.endsWith(u8, root_path.*, "/modulo"));
        try testing.expect(std.mem.find(u8, root_path.*, "/modulo/") == null);
    }

    // Back again: there once, at the old path.
    tree.move("outside/modulo", "root/modulo");
    _ = try tree.sync();
    for ([_][2][]const u8{
        .{ "tras_scan", "modulo/tras_scan.rs" },
        .{ "tras_scan_hondo", "modulo/interno/tras_scan_hondo.rs" },
        .{ "tras_scan_creada", "modulo/creada/tras_scan_creada.rs" },
    }) |case| try testing.expectEqual(1, try tree.count(case[0], case[1]));
}

test "live: a directory renamed over an empty one keeps what it holds" {
    // `mv -T modulo vacio`: one MOVED_FROM, one MOVED_TO of a name already
    // indexed, and the old vacio's DELETE_SELF while its path exists.
    const tree = try Tree.create(&(sample_tree ++ [_][]const u8{"vacio/"}));
    defer tree.destroy();
    tree.move("root/modulo", "root/vacio");
    _ = try tree.sync();
    try testing.expectEqual(1, try tree.count("hoja", "vacio/interno/hoja.rs"));
    try testing.expectEqual(1, try tree.count("raiz", "vacio/raiz.rs"));
    try testing.expectEqual(1, try tree.count("vacio", "vacio"));
    try testing.expectEqual(0, try tree.under("hoja", "root/modulo"));
    // And watched: what changes in it shows up.
    tree.make("vacio/interno/despues.rs");
    _ = try tree.sync();
    try testing.expect(try tree.found("despues", "vacio/interno/despues.rs"));
}

test "live: a folder swapped for a link is never followed" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.makeAbsolute("outside/secreto/clave.txt");
    const watches = tree.live.watcher.count();
    var target_buffer: paths.Buffer = undefined;
    var link_buffer: paths.Buffer = undefined;
    // `mkdir x; rmdir x; ln -s ... x` faster than the events are read: the
    // CREATE of a directory comes for what is a link by then. One link out
    // of the tree, one to a folder inside it.
    const outside = tree.absolute("outside/secreto", &target_buffer);
    const out_link = linux.symlink(outside, tree.absolute("root/afuera", &link_buffer));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(out_link));
    const inside = tree.absolute("root/modulo", &target_buffer);
    const in_link = linux.symlink(inside, tree.absolute("root/adentro", &link_buffer));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(in_link));
    _ = try tree.live.apply(&.{
        .{ .created = .{ .parent = 0, .name = "afuera", .is_dir = true } },
        .{ .created = .{ .parent = 0, .name = "adentro", .is_dir = true } },
    });
    try tree.live.finishScans();
    _ = try tree.sync();
    try testing.expectEqual(0, try tree.under("clave", ""));
    try testing.expectEqual(0, try tree.under("hoja", "root/adentro"));
    try testing.expectEqual(watches, tree.live.watcher.count());

    // modulo's watches still point at modulo: its changes show up there.
    tree.make("modulo/interno/sigue.rs");
    _ = try tree.sync();
    try testing.expectEqual(1, try tree.count("sigue", "modulo/interno/sigue.rs"));
    try testing.expectEqual(1, try tree.under("sigue", ""));
}

test "live: a large directory moved in asks for a rescan instead" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    tree.live.limits.delta_entries_max = 4;
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |letter| {
        var path_buffer: [64]u8 = undefined;
        const path = try std.mem.print(&path_buffer, "outside/grande/sub/pieza_{s}.txt", .{letter});
        tree.makeAbsolute(path);
    }
    tree.move("outside/grande", "root/grande");
    _ = try tree.sync();
    // Read up to the level past the limit and dropped: a rescan follows.
    try testing.expect(tree.live.pending_resync);
    try testing.expectEqual(0, try tree.under("pieza", ""));
    try tree.compact();
    try testing.expectEqual(6, try tree.under("pieza", "root/grande"));
}

test "live: paths too long to open are left out, not shown empty" {
    const gpa = testing.allocator;
    var builder: Builder = .empty;
    var parent = try builder.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    const long: [250]u8 = @splat('d');
    for (0..20) |i| {
        parent = try builder.push(gpa, &long, parent, store_mod.flag_dir, @intCast(i + 1));
    }
    _ = try builder.push(gpa, "profundo_uno.txt", parent, 0, 21);
    _ = try builder.push(gpa, "profundo_dos.txt", parent, 0, 21);
    const base = try builder.finish(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    const roots = [_][]const u8{"/r"};
    const config: scan.Config = .{ .roots = &roots };
    var live = try Live.initUnarmed(gpa, base, &config, pool);
    defer live.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var hits: std.ArrayList(Hit) = .empty;
    try live.search(arena.allocator(), pool, "profundo", .{ .limit = 10, .recency = false }, &hits);
    try testing.expectEqual(0, hits.items.len);
}

test "live: adopt frees pending rechecks from the replaced delta" {
    const gpa = testing.allocator;
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    const roots = [_][]const u8{"/r"};
    const config: scan.Config = .{ .roots = &roots };

    var b1: Builder = .empty;
    _ = try b1.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    const base1 = try b1.finish(gpa);
    var live = try Live.initUnarmed(gpa, base1, &config, pool);
    defer live.deinit();

    const stale_path = try gpa.dupeSentinel(u8, "/r/new_dir", 0);
    const delta_id = EntryId{ .in_delta = true, .index = 0 };
    try live.rechecks.append(gpa, .{ .directory = delta_id.raw(), .path = stale_path });

    var b2: Builder = .empty;
    _ = try b2.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    const base2 = try b2.finish(gpa);
    const watcher2 = try Watcher.create(gpa);
    const old = try live.adopt(.{ .base = base2, .watcher = watcher2 });
    old.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), live.rechecks.items.len);
}

test "live: rechecks remove files renamed or deleted between readScans and watching" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();

    tree.make("fresh/temporal.part");
    tree.make("fresh/gone_dir/inside.txt");
    // Simulate directory creation reported by inotify, then run readScans.
    _ = try tree.live.apply(&.{
        .{ .created = .{ .parent = 0, .name = "fresh", .is_dir = true } },
    });
    var scans = tree.live.takeScans();
    readScans(testing.allocator, tree.pool, &tree.config, scans.items, 1000);

    // Mutate inside `fresh` before addScans watches and rechecks it.
    tree.move("root/fresh/temporal.part", "root/fresh/final.pdf");
    tree.remove("fresh/gone_dir/inside.txt");
    tree.remove("fresh/gone_dir/");

    try tree.live.addScans(&scans);
    try tree.live.finishScans();
    _ = try tree.sync();

    try testing.expect(!tree.live.pending_resync);
    try testing.expect(try tree.found("final", "fresh/final.pdf"));
    try testing.expectEqual(@as(usize, 0), try tree.under("temporal", ""));
    try testing.expectEqual(@as(usize, 0), try tree.under("gone_dir", ""));
    try testing.expectEqual(@as(usize, 0), try tree.under("inside", ""));
}

test "live: saveAndMap maps our own inode even when shared path is replaced by another writer" {
    const gpa = testing.allocator;
    var tmp = try sys.TestDir.init();
    defer tmp.deinit();
    var cache_buf: paths.Buffer = undefined;
    const shared_cache = try tmp.path(&cache_buf, "files.idx");

    try tmp.write("left/left_only.txt", "x");
    try tmp.write("right/right_only.txt", "y");
    var left_buf: paths.Buffer = undefined;
    var right_buf: paths.Buffer = undefined;
    const left_root = try tmp.path(&left_buf, "left");
    const right_root = try tmp.path(&right_buf, "right");

    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    const left_cfg: scan.Config = .{ .roots = &.{left_root} };
    const right_cfg: scan.Config = .{ .roots = &.{right_root} };

    // Left builds, saves atomically & maps its own fd via saveAndMap.
    var left_store = try scanSaved(gpa, pool, &left_cfg, null, shared_cache);
    defer left_store.deinit(gpa);
    // Right immediately overwrites shared_cache.
    var right_built = try scan.scan(gpa, pool, &right_cfg, null, null);
    defer right_built.deinit(gpa);
    try right_built.save(shared_cache);
    var right_store = try Store.open(shared_cache);
    defer right_store.deinit(gpa);

    var pbuf: paths.Buffer = undefined;
    // Left's mapped store must still contain `left_only.txt`, never right's contents.
    var saw_left = false;
    for (0..left_store.len()) |i| {
        const p = left_store.path(@intCast(i), &pbuf) orelse continue;
        if (std.mem.endsWith(u8, p, "/left_only.txt")) saw_left = true;
        try testing.expect(!std.mem.endsWith(u8, p, "/right_only.txt"));
    }
    try testing.expect(saw_left);
}

test "live: IN_CREATE for an already-indexed directory keeps its subtree without tombstoning" {
    const tree = try Tree.create(&sample_tree);
    defer tree.destroy();
    const graves_before = tree.live.graves;
    const applied = try tree.live.apply(&.{
        .{ .created = .{ .parent = 0, .name = "modulo", .is_dir = true, .moved_to = false } },
    });
    try testing.expectEqual(@as(usize, 0), applied);
    try testing.expectEqual(graves_before, tree.live.graves);
    try testing.expectEqual(@as(usize, 1), try tree.count("hoja", "modulo/interno/hoja.rs"));
}
