//! Live index: the mapped base plus what inotify reports (port of `live.rs`).
//! Not thread-safe: `Service` serializes every access with its lock.
//!
//! The base store is immutable and packed in one buffer, which is what makes
//! start-up a 1 ms mmap. Rebuilding it per new file would throw that away, so
//! changes are a layer on top:
//!
//!   - Deleting zeroes the entry's mask (see `Store.tombstone`): free on the
//!     hot path, copy-on-write on a mapping.
//!   - Adding goes to a small `delta` store searched alongside the base and
//!     merged by score.
//!
//! When the delta grows or tombstones pile up, a rescan (prepared outside the
//! lock) replaces everything with one clean index.

const std = @import("std");
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Builder = store_mod.Builder;
const scan = @import("scan.zig");
const engine = @import("search.zig");
const Pool = @import("Pool.zig");
const Watcher = @import("Watcher.zig");
const sys = @import("os");

const log = std.log.scoped(.files);

const Live = @This();

/// Flush to disk at least this often if something changed. Off: a home's
/// caches change all the time, so it rescanned every 10 minutes (49 MB
/// written, ~1 s of CPU, +54 MB while it ran) to cover a crash, which the
/// rescan on every start covers anyway; a clean exit flushes.
pub const compact_interval_ns: u64 = std.math.maxInt(u64);

/// Distinguishes delta ids from base ids. inotify events arrive as (watch,
/// name) and every watch must map to *some* entry; directories created after
/// the scan only exist in the delta, so both need one id space.
const delta_bit: u32 = 1 << 31;

fn isDelta(id: u32) bool {
    return id & delta_bit != 0;
}

fn deltaIndex(id: u32) u32 {
    return id & ~delta_bit;
}

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
    delta_max: usize = 20_000,
    graves_min: usize = 1_000,
    /// Tombstones must also exceed 1/graves_div of the base (5%).
    graves_div: usize = 20,
    interval_ns: u64 = compact_interval_ns,
};

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
watcher: *Watcher,
cfg: *const scan.Config,
/// Where the index is saved after a rescan; without it the next start would
/// rescan instead of mapping.
cache_path: ?[:0]const u8,
/// Small scans (a new directory) and rescans run here.
scan_pool: *Pool,
/// The next base entry whose directory `armProgress` watches; null once
/// every one is.
arm_cursor: ?u32 = null,
/// Persistent engines: what enables refinement while typing (measured in the
/// Rust version: 503 us cold vs 14 us reusing the engine).
engine_base: engine.Engine = .empty,
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

/// The layer on top of `base`: entries inotify reported after the scan.
/// Every field is about the delta's own ids, so a rescan, which starts a new
/// delta, resets all of them in one assignment.
const Delta = struct {
    /// Searchable version of `builder`, rebuilt after each batch of changes.
    store: Store,
    builder: Builder = .empty,
    /// Absolute directory path -> its scaffolding root in the delta, so every
    /// new file of one directory hangs from the same root. Owns the keys.
    roots: std.StringHashMapUnmanaged(u32) = .empty,
    /// Delta entry -> the delta entries under it (scaffolding roots
    /// included), so finding a child or a subtree is not a walk over the
    /// whole delta.
    kids: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    /// Persistent engine over `store` (see `engine_base`).
    engine: engine.Engine = .empty,

    /// An empty delta. The only fallible step of a reset, so callers make the
    /// new one before they drop the old one.
    fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Delta {
        var empty: Builder = .empty;
        return .{ .store = try empty.finish(gpa) };
    }

    fn deinit(delta: *Delta, gpa: std.mem.Allocator) void {
        delta.store.deinit(gpa);
        delta.builder.deinit(gpa);
        var root_paths = delta.roots.keyIterator();
        while (root_paths.next()) |root_path| gpa.free(root_path.*);
        delta.roots.deinit(gpa);
        var kids_lists = delta.kids.valueIterator();
        while (kids_lists.next()) |list| list.deinit(gpa);
        delta.kids.deinit(gpa);
        delta.engine.deinit(gpa);
        delta.* = undefined;
    }
};

/// Takes a store (mapped or fresh) with no watches armed yet: searchable
/// right away, watches armed in batches by `armProgress`. Owns `base` once
/// it returns; on error `base` is still the caller's.
pub fn initUnarmed(
    gpa: std.mem.Allocator,
    base: Store,
    cfg: *const scan.Config,
    cache_path: ?[:0]const u8,
    scan_pool: *Pool,
) (std.mem.Allocator.Error || Watcher.CreateError)!Live {
    var delta: Delta = try .init(gpa);
    errdefer delta.deinit(gpa);
    const slow = try slowMountsOf(gpa, cfg);
    errdefer sys.freeList(gpa, slow);
    const watcher = try Watcher.create(gpa);
    return .{
        .slow_mounts = slow,
        .gpa = gpa,
        .base = base,
        .delta = delta,
        .watcher = watcher,
        .cfg = cfg,
        .cache_path = cache_path,
        .scan_pool = scan_pool,
        .arm_cursor = 0,
        .last_compact_ns = sys.monotonicNs(),
        .graves = base.len() - base.liveLen(),
    };
}

pub fn deinit(live: *Live) void {
    live.base.deinit(live.gpa);
    live.delta.deinit(live.gpa);
    freeScans(live.gpa, &live.scans);
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
    var buf: [4096]u8 = undefined;
    while (id < entries_count and armed_count < budget) : (id += 1) {
        if (flags[id] & store_mod.flag_dir == 0) continue;
        if (live.base.isTombstoned(id)) continue;
        if (pathZ(&live.base, id, &buf)) |path| {
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
    return live.base.liveLen() + live.delta.store.liveLen();
}

/// Bytes the two stores take, mapped or in memory.
pub fn indexBytes(live: *const Live) usize {
    return live.base.buf.len + live.delta.store.buf.len;
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
            const added = try live.add(created.parent, created.name, created.is_dir);
            applied_count += @intFromBool(added);
        },
        .removed => |removed| {
            applied_count += @intFromBool(live.remove(removed.parent, removed.name));
        },
        .dir_gone => |id| {
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
        try live.rebuildDelta();
    }
    // With scans pending, `addScans` prunes once their watches re-pointed
    // the descriptors of a directory moved inside the tree.
    if (live.scans.items.len == 0) live.pruneWatches();
    return applied_count;
}

/// The delta id an event's parent maps to, if any. `add` and `remove` both
/// go through here: when they resolved parents differently, deleting
/// something added after the scan did nothing (bug found in the Rust one).
fn deltaParent(live: *Live, parent: u32) ?u32 {
    if (isDelta(parent)) {
        const delta_index = deltaIndex(parent);
        if (delta_index >= live.delta.builder.len()) return null;
        return delta_index;
    }
    var buf: [4096]u8 = undefined;
    const parent_path = live.pathOf(parent, &buf) orelse return null;
    return live.delta.roots.get(parent_path);
}

/// The live entry named `name` in directory `parent`, base or delta (as a
/// delta id). It may be in the base or added to the delta after the scan.
fn childOf(live: *Live, parent: u32, name: []const u8) ?u32 {
    if (!isDelta(parent) and parent < live.base.len()) {
        if (live.base.findChild(parent, name)) |id| return id;
    }
    const delta_parent = live.deltaParent(parent) orelse return null;
    const delta_index = live.deltaChild(delta_parent, name) orelse return null;
    return delta_bit | delta_index;
}

fn remove(live: *Live, parent: u32, name: []const u8) bool {
    const id = live.childOf(parent, name) orelse return false;
    live.stats.removed += live.tombstoneTree(id);
    return true;
}

/// Child of delta entry `dir` named `child_name`, looked up in the builder, not in
/// `delta`: that one is only rebuilt after the batch, so a file created and
/// deleted within one batch (an editor's temp file) was never found and
/// stayed searchable for good. Among `dir`'s `kids` only: walking the
/// whole delta made every event cost everything added since the rescan.
fn deltaChild(live: *const Live, dir: u32, child_name: []const u8) ?u32 {
    const builder = &live.delta.builder;
    const kids = live.delta.kids.get(dir) orelse return null;
    for (kids.items) |kid| {
        if (builder.masks.items[kid] == 0) continue;
        const name_offset = builder.name_offsets.items[kid];
        const kid_name = builder.names.items[name_offset..][0..builder.name_sizes.items[kid]];
        if (std.mem.eql(u8, kid_name, child_name)) return kid;
    }
    return null;
}

/// Whether entry `id` (base or delta) is still in the index. A directory
/// moved out of the tree keeps its watch until `pruneWatches`.
fn alive(live: *const Live, id: u32) bool {
    if (isDelta(id)) {
        const delta_index = deltaIndex(id);
        if (delta_index >= live.delta.builder.len()) return false;
        return live.delta.builder.masks.items[delta_index] != 0;
    }
    if (id >= live.base.len()) return false;
    return !live.base.isTombstoned(id);
}

fn isDirEntry(live: *const Live, id: u32) bool {
    if (isDelta(id)) {
        return live.delta.builder.flags.items[deltaIndex(id)] & store_mod.flag_dir != 0;
    }
    return live.base.isDir(id);
}

fn pathExists(live: *const Live, id: u32) bool {
    var buf: [4096]u8 = undefined;
    const path = live.pathOf(id, buf[0 .. buf.len - 1]) orelse return false;
    if (path.len == 0) return false;
    buf[path.len] = 0;
    return sys.exists(buf[0..path.len :0]);
}

/// Hidden as the scan sets it: by name, and inherited from the parent.
/// Without it, new files under a dot-dir ranked as the user's own until the
/// next rescan.
fn hiddenFlag(live: *const Live, parent: u32, name: []const u8) u8 {
    const parent_flags = if (isDelta(parent))
        live.delta.builder.flags.items[deltaIndex(parent)]
    else
        live.base.flags()[parent];
    if (parent_flags & store_mod.flag_hidden != 0) return store_mod.flag_hidden;
    if (scan.hiddenByName(name)) return store_mod.flag_hidden;
    return 0;
}

/// Tombstones entry `id` (base, or delta as a delta id) and its subtree.
fn tombstoneTree(live: *Live, id: u32) usize {
    if (live.isDirEntry(id)) live.prune_watches = true;
    if (isDelta(id)) return live.tombstoneDeltaTree(deltaIndex(id));
    return live.tombstoneBaseTree(id);
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

/// What was added after the scan below base directory `dir`. It hangs from
/// scaffolding roots found by path (`deltaRoot`), not from `dir`, so walking
/// the base missed it: a file created in a folder then moved away with it
/// stayed searchable under the old path for good.
fn tombstoneDeltaUnder(live: *Live, dir: u32) usize {
    var buf: [4096]u8 = undefined;
    const dir_path = live.base.path(dir, &buf) orelse return 0;
    var tombstoned_count: usize = 0;
    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(live.gpa);
    var roots = live.delta.roots.iterator();
    while (roots.next()) |root| {
        if (!engine.isUnder(root.key_ptr.*, dir_path)) continue;
        if (live.delta.kids.get(root.value_ptr.*)) |kids| {
            for (kids.items) |kid| tombstoned_count += live.tombstoneDeltaTree(kid);
        }
        // Forgotten too: a folder at that path again is another folder.
        gone.append(live.gpa, root.key_ptr.*) catch {
            live.pending_resync = true;
        };
    }
    for (gone.items) |root_path| {
        _ = live.delta.roots.remove(root_path);
        live.gpa.free(root_path);
    }
    return tombstoned_count;
}

/// Same on the delta, finding children through `kids` (the delta is not
/// built level by level, so no binary search). On the builder, for the same
/// reason as `deltaChild`.
fn tombstoneDeltaTree(live: *Live, root: u32) usize {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(live.gpa);
    stack.append(live.gpa, root) catch {
        live.pending_resync = true;
        return 0;
    };
    var tombstoned_count: usize = 0;
    const builder = &live.delta.builder;
    while (stack.pop()) |id| {
        if (builder.masks.items[id] == 0) continue;
        if (builder.flags.items[id] & store_mod.flag_dir != 0) {
            if (live.delta.kids.get(id)) |kids| {
                stack.appendSlice(live.gpa, kids.items) catch {
                    live.pending_resync = true;
                };
            }
        }
        builder.tombstone(id);
        if (id < live.delta.store.len()) live.delta.store.tombstone(id);
        tombstoned_count += 1;
    }
    return tombstoned_count;
}

fn add(live: *Live, parent: u32, name: []const u8, is_dir: bool) !bool {
    // A directory moved out of the tree is still watched: what happens in
    // it now must not come back under its old path.
    if (!live.alive(parent)) return false;
    if (live.childOf(parent, name)) |known| {
        // Already indexed: an IN_MOVED_TO of something known, or what a
        // rescan read before its event came. No duplicate. Except for a
        // directory renamed over an empty one (`mv -T a b`): same name,
        // another directory, and what came from `a` was lost, unwatched.
        if (!is_dir or !live.isDirEntry(known)) return false;
        live.stats.removed += live.tombstoneTree(known);
    }
    var parent_path_buffer: [4096]u8 = undefined;
    const parent_path = live.pathOf(parent, &parent_path_buffer) orelse return false;
    const depth = live.depthOf(parent) +| 1;
    const hidden = live.hiddenFlag(parent, name);
    // A parent already in the delta is used as is; a base parent gets a
    // scaffolding root.
    const root = if (isDelta(parent))
        deltaIndex(parent)
    else
        try live.deltaRoot(parent_path, depth -| 1);

    // Without the scan's rule, `npm install` scanned and watched the whole
    // new node_modules.
    if (is_dir and scan.shouldDescend(parent_path, name, live.cfg)) {
        // inotify race: files may have appeared before the watch existed, so
        // a new directory is read whole (`readScans`).
        var full_path_buffer: [4096]u8 = undefined;
        const full = std.mem.print(&full_path_buffer, "{s}{s}{s}", .{
            parent_path,
            if (std.mem.endsWith(u8, parent_path, "/")) "" else "/",
            name,
        }) catch return false;
        const path = try live.gpa.dupeSentinel(u8, full, 0);
        errdefer live.gpa.free(path);
        try live.scans.ensureUnusedCapacity(live.gpa, 1);
        const id = try live.deltaPush(name, root, store_mod.flag_dir | hidden, depth);
        live.scans.appendAssumeCapacity(.{
            .dir = id,
            .path = path,
            .depth = depth,
            .hidden = hidden,
        });
    } else {
        // A file, or a directory skipped like the scan does: searchable,
        // never opened.
        _ = try live.deltaPush(name, root, hidden, depth);
    }
    live.stats.added += 1;
    return true;
}

/// A directory that appeared after the scan. Its entry is in the delta at
/// once, so a removal later in the same batch finds it; what it holds is
/// read by `readScans` without the lock, then added by `addScans`. Read
/// under the lock, a large tree moved into the index stalled every search
/// for as long as reading it took.
pub const Scan = struct {
    /// Delta index of the directory's entry.
    dir: u32,
    path: [:0]u8,
    depth: u16,
    hidden: u8,
    sub: ?Store = null,
    /// Over `Limits.delta_max` entries: a rescan instead, which adding it
    /// would ask for anyway.
    too_big: bool = false,

    fn deinit(scan_job: *Scan, gpa: std.mem.Allocator) void {
        gpa.free(scan_job.path);
        if (scan_job.sub) |*sub| sub.deinit(gpa);
    }
};

pub const Scans = std.ArrayList(Scan);

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
    cfg: *const scan.Config,
    scans: []Scan,
    entries_max: usize,
) void {
    for (scans) |*scan_job| {
        var sub_cfg = cfg.*;
        const roots = [_][]const u8{scan_job.path};
        sub_cfg.roots = &roots;
        sub_cfg.follow_roots = false;
        sub_cfg.entries_max = entries_max;
        var scan_stats: scan.Stats = .{};
        // Out of memory: no store, and `addScans` asks for a rescan.
        scan_job.sub = scan.scan(gpa, pool, &sub_cfg, null, &scan_stats) catch null;
        scan_job.too_big = scan_stats.truncated;
    }
}

/// Adds what `readScans` found under each directory's entry and watches
/// the directories, then frees `scans`.
pub fn addScans(live: *Live, scans: *Scans) std.mem.Allocator.Error!void {
    defer freeScans(live.gpa, scans);
    var added = false;
    for (scans.items) |*scan_job| {
        // Removed again before it was read (later in the same batch).
        if (scan_job.dir >= live.delta.builder.len()) continue;
        if (live.delta.builder.masks.items[scan_job.dir] == 0) continue;
        const sub = if (scan_job.sub) |*sub| sub else {
            live.pending_resync = true;
            continue;
        };
        if (scan_job.too_big) {
            live.pending_resync = true;
            continue;
        }
        const map = try live.appendStore(sub, scan_job.dir, scan_job.depth, scan_job.hidden);
        defer live.gpa.free(map);
        // Watch the new directories under their delta ids, or events from
        // inside could not be attributed.
        var buf: [4096]u8 = undefined;
        for (0..sub.len()) |sub_index| {
            const id: u32 = @intCast(sub_index);
            if (!sub.isDir(id)) continue;
            const path = pathZ(sub, id, &buf) orelse continue;
            const delta_id = delta_bit | map[sub_index];
            try live.watcher.watchBestEffort(live.gpa, path, delta_id, .below_root);
        }
        live.stats.added += sub.len() - 1;
        added = true;
    }
    if (added) {
        live.dirty = true;
        try live.rebuildDelta();
    }
    live.pruneWatches();
}

/// `takeScans`, `readScans` and `addScans` with the lock held throughout,
/// for callers that hold it anyway (tests).
pub fn finishScans(live: *Live) std.mem.Allocator.Error!void {
    var scans = live.takeScans();
    readScans(live.gpa, live.scan_pool, live.cfg, scans.items, live.limits.delta_max);
    try live.addScans(&scans);
}

/// Drops the watches of directories that left the index (moved out of the
/// tree: the kernel only drops a deleted one's), once a batch tombstoned
/// one: a pass over every watch.
fn pruneWatches(live: *Live) void {
    if (!live.prune_watches) return;
    live.prune_watches = false;
    live.watcher.prune(live.gpa, @as(*const Live, live), alive);
    live.stats.watches = live.watcher.count();
}

/// Copies a freshly scanned sub-index into the delta under `dir`, the entry
/// its root stands for (scan names roots by absolute path, which here would
/// be a result that does not exist after compaction).
fn appendStore(live: *Live, sub: *const Store, dir: u32, base_depth: u16, hidden: u8) ![]u32 {
    const map = try live.gpa.alloc(u32, sub.len());
    errdefer live.gpa.free(map);
    const parents = sub.parents();
    const flags = sub.flags();
    const depths = sub.depths();
    for (0..sub.len()) |sub_index| {
        const parent = parents[sub_index];
        if (parent == store_mod.no_parent) {
            map[sub_index] = dir;
            continue;
        }
        // Parents come first: theirs is mapped already.
        assert(parent < sub_index);
        const name = sub.name(@intCast(sub_index));
        const depth = base_depth +| depths[sub_index];
        map[sub_index] = try live.deltaPush(name, map[parent], flags[sub_index] | hidden, depth);
    }
    return map;
}

/// Adds an entry to the delta and to its parent's `kids`.
fn deltaPush(live: *Live, name: []const u8, parent: u32, flags: u8, depth: u16) !u32 {
    const id = try live.delta.builder.push(live.gpa, name, parent, flags, depth);
    const kids = try live.delta.kids.getOrPut(live.gpa, parent);
    if (!kids.found_existing) kids.value_ptr.* = .empty;
    try kids.value_ptr.append(live.gpa, id);
    return id;
}

/// Scaffolding root for a directory, memoized. Its name is the whole path:
/// it rebuilds paths but never shows up (mask 0).
fn deltaRoot(live: *Live, dir_path: []const u8, depth: u16) !u32 {
    if (live.delta.roots.get(dir_path)) |id| return id;
    const id = try live.delta.builder.pushStructural(
        live.gpa,
        dir_path,
        store_mod.no_parent,
        store_mod.flag_dir,
        depth,
    );
    const key = try live.gpa.dupe(u8, dir_path);
    errdefer live.gpa.free(key);
    try live.delta.roots.put(live.gpa, key, id);
    return id;
}

pub fn pathOf(live: *const Live, id: u32, buf: []u8) ?[]const u8 {
    if (isDelta(id)) {
        const delta_index = deltaIndex(id);
        if (delta_index >= live.delta.store.len()) return null;
        return live.delta.store.path(delta_index, buf);
    }
    if (id >= live.base.len()) return null;
    return live.base.path(id, buf);
}

fn depthOf(live: *const Live, id: u32) u16 {
    if (isDelta(id)) {
        const i = deltaIndex(id);
        return if (i < live.delta.store.len()) live.delta.store.depths()[i] else 0;
    }
    return if (id < live.base.len()) live.base.depths()[id] else 0;
}

/// The delta is small by construction (compaction keeps it so): rebuilding
/// it whole is cheaper and simpler than keeping it mutable. Ids stay the
/// same (`kids` relies on it). On error the builder may be partly consumed:
/// the caller asks for a rescan.
fn rebuildDelta(live: *Live) !void {
    // Refill a builder from the new store so more can be added; scaffolding
    // stays mask 0. Both are complete before anything is replaced.
    var fresh = try live.delta.builder.finish(live.gpa);
    errdefer fresh.deinit(live.gpa);
    var refilled: Builder = .empty;
    errdefer refilled.deinit(live.gpa);
    const parents = fresh.parents();
    const flags = fresh.flags();
    const depths = fresh.depths();
    for (0..fresh.len()) |i| {
        const id: u32 = @intCast(i);
        const name = fresh.name(id);
        if (fresh.isTombstoned(id)) {
            _ = try refilled.pushStructural(live.gpa, name, parents[i], flags[i], depths[i]);
        } else {
            _ = try refilled.push(live.gpa, name, parents[i], flags[i], depths[i]);
        }
    }
    live.delta.store.deinit(live.gpa);
    live.delta.store = fresh;
    live.delta.builder = refilled;
    // Ids changed: the delta engine's cached candidates mean nothing now.
    live.delta.engine.reset();
}

/// Searches base and delta and merges by score. Paths are allocated in
/// `arena`.
pub fn search(
    live: *Live,
    arena: std.mem.Allocator,
    pool: *Pool,
    query: []const u8,
    opts: engine.Options,
    out: *std.ArrayList(Hit),
) std.mem.Allocator.Error!void {
    const limit = opts.limit;
    var o = opts;
    o.no_stat = live.slow_mounts;
    out.clearRetainingCapacity();
    var hits: std.ArrayList(engine.Hit) = .empty;
    defer hits.deinit(live.gpa);
    var buf: [4096]u8 = undefined;
    try live.engine_base.search(live.gpa, pool, &live.base, query, o, &hits);
    // A path that does not fit (deeper than PATH_MAX) cannot be opened:
    // left out, where it used to come out as "" (and dedup as one).
    for (hits.items) |h| try out.append(arena, .{
        .path = try arena.dupe(u8, live.base.path(h.id, &buf) orelse continue),
        .score = h.score,
        .is_dir = live.base.isDir(h.id),
    });
    if (live.delta.store.len() > 0) {
        try live.delta.engine.search(live.gpa, pool, &live.delta.store, query, o, &hits);
        for (hits.items) |h| try out.append(arena, .{
            .path = try arena.dupe(u8, live.delta.store.path(h.id, &buf) orelse continue),
            .score = h.score,
            .is_dir = live.delta.store.isDir(h.id),
        });
    }
    std.mem.sort(Hit, out.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score or (a.score == b.score and std.mem.order(
                u8,
                a.path,
                b.path,
            ) == .lt);
        }
    }.lt);
    // Something can be in both (created during a rescan): keep the best.
    // By set, not by neighbour: the two copies need not score the same, and
    // another hit between them left both in.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(live.gpa);
    var w: usize = 0;
    for (out.items) |h| {
        if ((try seen.getOrPut(live.gpa, h.path)).found_existing) continue;
        out.items[w] = h;
        w += 1;
    }
    out.shrinkRetainingCapacity(@min(w, limit));
}

pub const Replaced = struct { base: Store, watcher: *Watcher };

/// Swaps in a freshly built index and returns the old one. Returning it
/// matters: dropping a watcher with 72k watches takes the kernel
/// milliseconds; done here it would be done with the lock held (worst
/// search went from 1.7 to 19.8 ms in the Rust version). On error nothing
/// changed and `base` and `watcher` are still the caller's.
pub fn adopt(live: *Live, base: Store, watcher: *Watcher) std.mem.Allocator.Error!Replaced {
    // The only fallible step, first: the new index starts with an empty delta.
    const delta: Delta = try .init(live.gpa);
    const old: Replaced = .{ .base = live.base, .watcher = live.watcher };
    live.base = base;
    live.graves = base.len() - base.liveLen();
    live.watcher = watcher;
    live.stats.watches = watcher.count();
    // A rescan's watcher was armed as it scanned.
    live.arm_cursor = null;
    live.delta.deinit(live.gpa);
    live.delta = delta;
    freeScans(live.gpa, &live.scans);
    live.scans = .empty;
    live.prune_watches = false;
    live.pending_resync = false;
    live.dirty = false;
    live.last_compact_ns = sys.monotonicNs();
    live.engine_base.reset();
    // A few lines of /proc: what was mounted since the last rescan. Out of
    // memory, the old list stays.
    if (slowMountsOf(live.gpa, live.cfg)) |m| {
        sys.freeList(live.gpa, live.slow_mounts);
        live.slow_mounts = m;
    } else |_| {}
    return old;
}

/// `sys.slowMounts` under every root.
fn slowMountsOf(gpa: std.mem.Allocator, cfg: *const scan.Config) std.mem.Allocator.Error![][]u8 {
    var all: std.ArrayList([]u8) = .empty;
    errdefer {
        for (all.items) |m| gpa.free(m);
        all.deinit(gpa);
    }
    for (cfg.roots) |r| {
        const list = try sys.slowMounts(gpa, r);
        defer gpa.free(list);
        all.ensureUnusedCapacity(gpa, list.len) catch |err| {
            for (list) |m| gpa.free(m);
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
    const lim = live.limits;
    if (live.delta.store.len() > lim.delta_max or
        (graves > lim.graves_min and graves > live.base.len() / lim.graves_div)) return true;
    return live.dirty and sys.monotonicNs() -| live.last_compact_ns >= lim.interval_ns;
}

/// Builds the replacement index without touching the current one: the
/// expensive part runs unlocked, alongside searches. Watching while scanning
/// means nothing that changes meanwhile is lost.
pub fn prepareCompaction(
    gpa: std.mem.Allocator,
    pool: *Pool,
    cfg: *const scan.Config,
    cache_path: ?[:0]const u8,
) (std.mem.Allocator.Error || Watcher.CreateError)!Replaced {
    const w = try Watcher.create(gpa);
    errdefer w.destroy(gpa);
    var base = try scan.scan(gpa, pool, cfg, w, null);
    errdefer base.deinit(gpa);
    if (cache_path) |p| {
        if (std.mem.findScalarLast(u8, p, '/')) |slash| sys.mkdirP(p[0..slash]);
        base.save(p) catch |err| {
            // Served from memory; the next rescan saves again.
            log.warn("saving the file index: {t}", .{err});
            return .{ .base = base, .watcher = w };
        };
        // Swap the heap copy for a mapping of what was just written: same
        // bytes, but clean page cache the kernel can reclaim instead of
        // ~80 MB of anonymous memory.
        if (Store.open(p)) |mapped| {
            base.deinit(gpa);
            base = mapped;
        } else |_| {}
    }
    return .{ .base = base, .watcher = w };
}

fn pathZ(store: *const Store, id: u32, buf: *[4096]u8) ?[*:0]const u8 {
    const p = store.path(id, buf[0 .. buf.len - 1]) orelse return null;
    if (p.len == 0) return null;
    buf[p.len] = 0;
    return buf[0..p.len :0];
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
    tmp: testing.TmpDir,
    dir_buf: [4096]u8 = undefined,
    /// Absolute path of the temp dir.
    dir: []const u8 = "",
    root_buf: [4096]u8 = undefined,
    root: []const u8 = "",
    roots: [1][]const u8 = undefined,
    cfg: scan.Config = undefined,
    pool: *Pool,
    live: Live = undefined,
    arena: std.heap.ArenaAllocator,
    hits: std.ArrayList(Hit) = .empty,

    /// `entries` are relative to the root; a trailing '/' makes a directory.
    fn create(entries: []const []const u8) !*Tree {
        const gpa = testing.allocator;
        const t = try gpa.create(Tree);
        errdefer gpa.destroy(t);
        t.* = .{
            .tmp = testing.tmpDir(.{}),
            .pool = try Pool.create(gpa, testing.io, 2),
            .arena = .init(gpa),
        };
        t.dir = try sys.tmpDirAbs(&t.tmp, &t.dir_buf);
        t.root = try std.mem.print(&t.root_buf, "{s}/root", .{t.dir});
        t.roots = .{t.root};
        t.cfg = .{ .roots = &t.roots };
        t.mkAbs("root/");
        t.mkAbs("outside/");
        for (entries) |e| t.mk(e);
        const base = try scan.scan(gpa, t.pool, &t.cfg, null, null);
        t.live = try Live.initUnarmed(gpa, base, &t.cfg, null, t.pool);
        while (t.live.armProgress(1000)) {}
        return t;
    }

    fn destroy(tree: *Tree) void {
        tree.live.deinit();
        tree.pool.destroy();
        tree.arena.deinit();
        tree.tmp.cleanup();
        testing.allocator.destroy(tree);
    }

    /// Absolute path of `rel`, relative to the temp dir.
    fn abs(tree: *Tree, rel: []const u8, buf: *[4096]u8) [:0]const u8 {
        return std.mem.printSentinel(
            buf,
            "{s}/{s}",
            .{ tree.dir, std.mem.trimEnd(u8, rel, "/") },
            0,
        ) catch unreachable;
    }

    fn mkAbs(tree: *Tree, rel: []const u8) void {
        var buf: [4096]u8 = undefined;
        if (std.mem.endsWith(u8, rel, "/")) {
            sys.mkdirP(tree.abs(rel, &buf));
        } else {
            if (std.mem.findScalarLast(u8, rel, '/')) |slash| sys.mkdirP(
                tree.abs(rel[0..slash], &buf),
            );
            sys.writeFile(tree.abs(rel, &buf), "x") catch unreachable;
        }
    }

    /// Creates `rel` (relative to the root), parents included.
    fn mk(tree: *Tree, rel: []const u8) void {
        var buf: [4096]u8 = undefined;
        tree.mkAbs(std.mem.print(&buf, "root/{s}", .{rel}) catch unreachable);
    }

    /// Deletes `rel` (relative to the root): a file, or an empty directory.
    fn rm(tree: *Tree, rel: []const u8) void {
        var rb: [4096]u8 = undefined;
        var buf: [4096]u8 = undefined;
        const p = tree.abs(std.mem.print(&rb, "root/{s}", .{rel}) catch unreachable, &buf);
        if (std.mem.endsWith(u8, rel, "/")) _ = linux.rmdir(p) else _ = linux.unlink(p);
    }

    /// Renames, both paths relative to the temp dir.
    fn mv(tree: *Tree, from: []const u8, to: []const u8) void {
        var a: [4096]u8 = undefined;
        var b: [4096]u8 = undefined;
        sys.rename(tree.abs(from, &a), tree.abs(to, &b)) catch unreachable;
    }

    /// Drains and applies everything pending; returns how many took effect.
    fn sync(tree: *Tree) !usize {
        var n: usize = 0;
        while (true) {
            var changes: std.ArrayList(Watcher.Change) = .empty;
            try tree.live.watcher.drain(tree.arena.allocator(), &changes);
            if (changes.items.len == 0) return n;
            n += try tree.live.apply(changes.items);
            try tree.live.finishScans();
        }
    }

    fn searchOpts(tree: *Tree, query: []const u8, opts: engine.Options) ![]const Hit {
        try tree.live.search(tree.arena.allocator(), tree.pool, query, opts, &tree.hits);
        return tree.hits.items;
    }

    /// Hits for `query` whose path ends in "<root>/<rel>".
    fn count(tree: *Tree, query: []const u8, rel: []const u8) !usize {
        var buf: [4096]u8 = undefined;
        const want = try std.mem.print(&buf, "{s}/{s}", .{ tree.root, rel });
        var n: usize = 0;
        for (try tree.searchOpts(query, .{
            .limit = 50,
            .recency = false,
        })) |h| n += @intFromBool(std.mem.eql(u8, h.path, want));
        return n;
    }

    fn found(tree: *Tree, query: []const u8, rel: []const u8) !bool {
        return try tree.count(query, rel) > 0;
    }

    /// Hits whose path is anywhere under the temp dir's `rel`. The root
    /// entry is left out: its name is its whole path, which a short query
    /// can match by chance.
    fn under(tree: *Tree, query: []const u8, rel: []const u8) !usize {
        var buf: [4096]u8 = undefined;
        const prefix = try std.mem.print(&buf, "{s}/{s}", .{ tree.dir, rel });
        var n: usize = 0;
        for (try tree.searchOpts(query, .{ .limit = 50, .recency = false })) |h| {
            n += @intFromBool(
                std.mem.startsWith(u8, h.path, prefix) and !std.mem.eql(u8, h.path, tree.root),
            );
        }
        return n;
    }

    /// Stands in for `Service.rescan`, without the lock to release.
    fn compact(tree: *Tree) !void {
        const fresh = try prepareCompaction(testing.allocator, tree.pool, &tree.cfg, null);
        const old = try tree.live.adopt(fresh.base, fresh.watcher);
        var b = old.base;
        b.deinit(testing.allocator);
        old.watcher.destroy(testing.allocator);
    }

    fn scoreOf(tree: *Tree, query: []const u8, rel: []const u8) !?i32 {
        var buf: [4096]u8 = undefined;
        const want = try std.mem.print(&buf, "{s}/{s}", .{ tree.root, rel });
        for (try tree.searchOpts(query, .{
            .limit = 50,
            .recency = false,
        })) |h| if (std.mem.eql(u8, h.path, want)) return h.score;
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
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    try testing.expect(try t.found("hoja", "modulo/interno/hoja.rs"));
    const watches = t.live.watcher.count();

    // One IN_MOVED_FROM, for the directory: the whole subtree must go.
    t.mv("root/modulo", "outside/modulo");
    _ = try t.sync();
    try testing.expectEqual(0, try t.under("hoja", "root/modulo"));
    try testing.expectEqual(0, try t.under("raiz", "root/modulo"));
    try testing.expectEqual(0, try t.under("interno", "root/modulo"));
    try testing.expect(try t.found("main", "src/main.rs"));
    // Its watches and its folder's went with it: modulo and interno.
    try testing.expectEqual(watches - 2, t.live.watcher.count());
    try testing.expectEqual(watches - 2, t.live.stats.watches);

    // What happens out there now must not come back under the old path.
    t.mkAbs("outside/modulo/despues.rs");
    t.mkAbs("outside/modulo/interno/tambien.rs");
    t.mkAbs("outside/modulo/nuevo_dir/");
    _ = try t.sync();
    try testing.expectEqual(0, try t.under("despues", ""));
    try testing.expectEqual(0, try t.under("tambien", ""));
    try testing.expectEqual(0, try t.under("nuevo_dir", ""));
}

test "live: moving a directory inside the tree reindexes it at the new path" {
    const t = try Tree.create(&(sample_tree ++ [_][]const u8{"otro/"}));
    defer t.destroy();
    const watches = t.live.watcher.count();

    t.mv("root/modulo", "root/otro/renombrado");
    _ = try t.sync();
    try testing.expect(try t.found("hoja", "otro/renombrado/interno/hoja.rs"));
    try testing.expect(try t.found("raiz", "otro/renombrado/raiz.rs"));
    try testing.expectEqual(0, try t.under("hoja", "root/modulo"));
    try testing.expectEqual(0, try t.under("raiz", "root/modulo"));

    // Watches are per inode: the rescanned destination re-points the same
    // descriptors, none leak, and the inside is still watched.
    try testing.expectEqual(watches, t.live.watcher.count());
    t.mk("otro/renombrado/interno/posterior.rs");
    _ = try t.sync();
    try testing.expect(try t.found("posterior", "otro/renombrado/interno/posterior.rs"));
    t.rm("otro/renombrado/interno/posterior.rs");
    _ = try t.sync();
    try testing.expect(!try t.found("posterior", "otro/renombrado/interno/posterior.rs"));
}

test "live: a MOVE_SELF read after the move was applied keeps the destination" {
    // The kernel queues MOVED_FROM, MOVED_TO and MOVE_SELF together, but a
    // drain can stop between them. Then MOVE_SELF is parsed after the watch
    // was re-pointed to the destination's delta entry.
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    t.mv("root/modulo", "root/renombrado");
    _ = try t.sync();
    try testing.expect(try t.found("hoja", "renombrado/interno/hoja.rs"));

    var dest: ?u32 = null;
    var it = t.live.watcher.wd_to_id.valueIterator();
    var buf: [4096]u8 = undefined;
    var want_buf: [4096]u8 = undefined;
    const want = try std.mem.print(&want_buf, "{s}/renombrado", .{t.root});
    while (it.next()) |id| {
        if (isDelta(id.*) and std.mem.eql(
            u8,
            t.live.pathOf(id.*, &buf) orelse "",
            want,
        )) dest = id.*;
    }
    try testing.expect(dest != null);
    _ = try t.live.apply(&.{.{ .dir_gone = dest.? }});
    try testing.expect(try t.found("hoja", "renombrado/interno/hoja.rs"));
    try testing.expect(try t.found("renombrado", "renombrado"));
}

test "live: what was added after the scan can be deleted" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();

    // A file in the delta, under a base directory.
    t.mk("src/efimero.rs");
    _ = try t.sync();
    try testing.expect(try t.found("efimero", "src/efimero.rs"));
    t.rm("src/efimero.rs");
    _ = try t.sync();
    try testing.expect(!try t.found("efimero", "src/efimero.rs"));

    // A file inside a directory that only exists in the delta.
    t.mk("creado/");
    _ = try t.sync();
    try testing.expect(try t.found("creado", "creado"));
    t.mk("creado/posterior.rs");
    _ = try t.sync();
    try testing.expect(try t.found("posterior", "creado/posterior.rs"));
    t.rm("creado/posterior.rs");
    _ = try t.sync();
    try testing.expect(!try t.found("posterior", "creado/posterior.rs"));

    // And the delta directory itself, moved away with content inside.
    t.mk("creado/sub/hondo.rs");
    _ = try t.sync();
    try testing.expect(try t.found("hondo", "creado/sub/hondo.rs"));
    t.mv("root/creado", "outside/creado");
    _ = try t.sync();
    try testing.expectEqual(0, try t.under("hondo", "root"));
    try testing.expectEqual(0, try t.under("creado", "root"));
}

test "live: created and deleted within one batch leaves no ghost" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    t.mk("src/temporal.swp");
    t.rm("src/temporal.swp");
    t.mk("fugaz_dir/");
    t.rm("fugaz_dir/");
    _ = try t.sync();
    try testing.expect(!try t.found("temporal", "src/temporal.swp"));
    try testing.expect(!try t.found("fugaz_dir", "fugaz_dir"));

    // Created, deleted, created again: there, once.
    t.mk("src/vuelve.rs");
    t.rm("src/vuelve.rs");
    t.mk("src/vuelve.rs");
    _ = try t.sync();
    try testing.expectEqual(1, try t.count("vuelve", "src/vuelve.rs"));
}

test "live: a directory created with its content at once is indexed whole" {
    // The inotify race: everything below exists before any watch on it.
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    t.mk("nuevo/interno/escondido.rs");
    t.mk("nuevo/arriba.rs");
    _ = try t.sync();
    try testing.expect(try t.found("escondido", "nuevo/interno/escondido.rs"));
    try testing.expect(try t.found("arriba", "nuevo/arriba.rs"));
    try testing.expect(try t.found("interno", "nuevo/interno"));
    try testing.expect(try t.found("nuevo", "nuevo"));

    // And the new directories are watched from then on.
    t.mk("nuevo/interno/luego.rs");
    _ = try t.sync();
    try testing.expect(try t.found("luego", "nuevo/interno/luego.rs"));
}

test "live: an event for something already indexed adds no duplicate" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    const gpa = testing.allocator;

    // The rescan watches a directory, the file appears, then the directory
    // is read: it is in the scan *and* queued as an event.
    const w = try Watcher.create(gpa);
    var buf: [4096]u8 = undefined;
    try w.watch(gpa, try std.mem.printSentinel(&buf, "{s}", .{t.root}, 0), 0);
    t.mk("durante.rs");
    const base = try scan.scan(gpa, t.pool, &t.cfg, w, null);
    const old = try t.live.adopt(base, w);
    var ob = old.base;
    ob.deinit(gpa);
    old.watcher.destroy(gpa);

    try testing.expectEqual(0, try t.sync());
    try testing.expectEqual(1, try t.count("durante", "durante.rs"));
    // An IN_MOVED_TO of something known, base or delta.
    try testing.expectEqual(0, try t.live.apply(&.{.{ .created = .{
        .parent = 0,
        .name = "Cargo.toml",
        .is_dir = false,
    } }}));
    t.mk("despues.rs");
    try testing.expectEqual(1, try t.sync());
    try testing.expectEqual(0, try t.live.apply(&.{.{ .created = .{
        .parent = 0,
        .name = "despues.rs",
        .is_dir = false,
    } }}));
    try testing.expectEqual(1, try t.count("despues", "despues.rs"));
    try testing.expectEqual(1, try t.count("cargo", "Cargo.toml"));
}

test "live: a rescan watches before reading, so nothing after it is lost" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    const fresh = try prepareCompaction(testing.allocator, t.pool, &t.cfg, null);
    // Changes between the scan and the swap wait in the new watcher.
    t.mk("src/entre.rs");
    t.rm("Cargo.toml");
    const old = try t.live.adopt(fresh.base, fresh.watcher);
    var ob = old.base;
    ob.deinit(testing.allocator);
    old.watcher.destroy(testing.allocator);
    _ = try t.sync();
    try testing.expect(try t.found("entre", "src/entre.rs"));
    try testing.expect(!try t.found("cargo", "Cargo.toml"));
}

test "live: an overflow requests a rescan and does not do it" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    try testing.expect(!t.live.pending_resync);
    const t0 = sys.monotonicNs();
    // Whatever else came with it is moot: a rescan follows.
    _ = try t.live.apply(&.{
        .{ .created = .{ .parent = 0, .name = "nunca.rs", .is_dir = false } },
        .overflow,
    });
    try testing.expect(sys.monotonicNs() - t0 < 50 * std.time.ns_per_ms);
    try testing.expect(t.live.pending_resync);
    try testing.expectEqual(1, t.live.stats.resyncs);
    try testing.expectEqual(0, t.live.delta.store.len());

    try t.compact();
    try testing.expect(!t.live.pending_resync);
    try testing.expect(try t.found("main", "src/main.rs"));
}

test "live: adopt leaves a clean index that finds the same" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    t.mk("src/agregado.rs");
    t.mk("dir_nuevo/dentro.rs");
    t.rm("Cargo.toml");
    t.rm("modulo/raiz.rs");
    _ = try t.sync();
    try testing.expect(t.live.dirty);
    try testing.expect(t.live.delta.store.len() > 0);
    try testing.expect(t.live.base.liveLen() < t.live.base.len());

    const arena = t.arena.allocator();
    var before: std.ArrayList([]const u8) = .empty;
    for (try t.searchOpts("rs", .{
        .limit = 50,
        .recency = false,
    })) |h| try before.append(arena, h.path);
    try t.compact();

    try testing.expectEqual(0, t.live.delta.store.len());
    try testing.expectEqual(t.live.base.len(), t.live.base.liveLen());
    try testing.expect(!t.live.dirty);
    try testing.expect(t.live.fullyArmed());
    const after = try t.searchOpts("rs", .{ .limit = 50, .recency = false });
    try testing.expectEqual(before.items.len, after.len);
    for (before.items, after) |a, b| try testing.expectEqualStrings(a, b.path);
    try testing.expect(try t.found("agregado", "src/agregado.rs"));
    try testing.expect(try t.found("dentro", "dir_nuevo/dentro.rs"));
    try testing.expect(!try t.found("cargo", "Cargo.toml"));

    // The new watcher works: changes after the swap still arrive.
    t.mk("dir_nuevo/despues.rs");
    _ = try t.sync();
    try testing.expect(try t.found("despues", "dir_nuevo/despues.rs"));
}

test "live: compaction thresholds" {
    var files: [40][]const u8 = undefined;
    var names: [40][16]u8 = undefined;
    for (&files, &names, 0..) |*f, *n, i| f.* = try std.mem.print(n, "f{d}.txt", .{i});
    const t = try Tree.create(&files);
    defer t.destroy();
    // A long interval, so only the size thresholds speak.
    t.live.limits.interval_ns = std.math.maxInt(u64);
    try testing.expect(!t.live.needsCompaction());

    // Delta: strictly more than the limit.
    t.live.limits.delta_max = 3;
    t.mk("a.txt");
    t.mk("b.txt");
    _ = try t.sync();
    // Scaffolding root + 2 files.
    try testing.expectEqual(3, t.live.delta.store.len());
    try testing.expect(!t.live.needsCompaction());
    t.mk("c.txt");
    _ = try t.sync();
    try testing.expect(t.live.needsCompaction());
    t.live.limits.delta_max = 20_000;

    // Tombstones: over the minimum *and* over 5% of the base (41 entries:
    // root and 40 files -> 5% is 2).
    try testing.expectEqual(41, t.live.base.len());
    t.rm("f0.txt");
    t.rm("f1.txt");
    _ = try t.sync();
    t.live.limits.graves_min = 1;
    try testing.expect(!t.live.needsCompaction()); // 2 graves, not > 5%
    t.rm("f2.txt");
    _ = try t.sync();
    try testing.expect(t.live.needsCompaction());
    t.live.limits.graves_min = 1_000;
    try testing.expect(!t.live.needsCompaction()); // > 5%, not > 1000

    // Time: only with something to flush.
    t.live.limits.interval_ns = 0;
    try testing.expect(t.live.needsCompaction());
    try t.compact();
    t.live.limits.interval_ns = 0;
    try testing.expect(!t.live.needsCompaction());
}

test "live: tombstones on a mapped index never reach the file" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    const gpa = testing.allocator;
    var pbuf: [4096]u8 = undefined;
    const idx = t.abs("files.idx", &pbuf);
    try t.live.base.save(idx);
    var before_buf: [64 * 1024]u8 = undefined;
    const before = sys.readHead(idx, &before_buf);
    try testing.expect(before.len > 0 and before.len < before_buf.len);

    // Same entries, same ids: the armed watches stay valid.
    const mapped = try Store.open(idx);
    t.live.base.deinit(gpa);
    t.live.base = mapped;
    t.live.engine_base.reset();

    t.rm("Cargo.toml");
    t.mv("root/modulo", "outside/modulo");
    _ = try t.sync();
    try testing.expect(!try t.found("cargo", "Cargo.toml"));
    try testing.expect(t.live.base.liveLen() < t.live.base.len());

    var after_buf: [64 * 1024]u8 = undefined;
    try testing.expectEqualSlices(u8, before, sys.readHead(idx, &after_buf));
    var again = try Store.open(idx);
    defer again.deinit(gpa);
    try testing.expectEqual(again.len(), again.liveLen());
}

test "live: recency on a file deleted but not yet applied" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    t.rm("src/main.rs");
    // The event is still queued: the stale entry is stat'ed and must just
    // get no bonus.
    var any = false;
    for (try t.searchOpts("main", .{ .limit = 50 })) |h| any = any or std.mem.endsWith(
        u8,
        h.path,
        "/src/main.rs",
    );
    try testing.expect(any);
    _ = try t.sync();
    for (try t.searchOpts("main", .{ .limit = 50 })) |h| try testing.expect(
        !std.mem.endsWith(u8, h.path, "/src/main.rs"),
    );
}

test "live: one path in base and delta comes out once" {
    const t = try Tree.create(&.{ "dup.txt", "dupe.txt" });
    defer t.destroy();
    // A second copy of dup.txt in the delta, scoring far lower (hidden), so
    // dupe.txt sorts between the two.
    const r = try t.live.deltaRoot(t.root, 0);
    _ = try t.live.delta.builder.push(testing.allocator, "dup.txt", r, store_mod.flag_hidden, 1);
    try t.live.rebuildDelta();
    // The root entry is left out. Its name is its whole path, and the temp
    // folder's random name can hold "d", "u" and "p" in order, which made
    // the fuzzy query find it in about one run in fifteen.
    var paths: [4][]const u8 = undefined;
    var paths_count: usize = 0;
    for (try t.searchOpts("dup", .{ .limit = 50, .recency = false })) |hit| {
        if (std.mem.eql(u8, hit.path, t.root)) continue;
        try testing.expect(paths_count < paths.len);
        paths[paths_count] = hit.path;
        paths_count += 1;
    }
    try testing.expectEqual(2, paths_count);
    try testing.expect(std.mem.endsWith(u8, paths[0], "/dup.txt"));
    try testing.expect(std.mem.endsWith(u8, paths[1], "/dupe.txt"));
}

test "live: new entries under a dot-dir rank like scanned ones" {
    const t = try Tree.create(&(sample_tree ++ [_][]const u8{".config/app/"}));
    defer t.destroy();
    t.mk(".config/zorro_nuevo.txt");
    t.mk(".config/app/zorro_dir/zorro_hondo.txt");
    t.mk(".zorro_punto.txt");
    t.mk("my_cache/");
    t.mk("my_cache/zorro_cacheado.txt");
    _ = try t.sync();
    const cases = [_][2][]const u8{
        .{ "zorro_nuevo", ".config/zorro_nuevo.txt" },
        .{ "zorro_hondo", ".config/app/zorro_dir/zorro_hondo.txt" },
        .{ "zorro_dir", ".config/app/zorro_dir" },
        .{ "zorro_punto", ".zorro_punto.txt" },
        .{ "zorro_cacheado", "my_cache/zorro_cacheado.txt" },
    };
    var live_scores: [cases.len]i32 = undefined;
    for (cases, &live_scores) |c, *s| s.* = (try t.scoreOf(c[0], c[1])).?;
    try t.compact();
    for (cases, live_scores) |c, s| try testing.expectEqual(s, (try t.scoreOf(c[0], c[1])).?);
}

test "live: a new skipped directory is indexed but not opened" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    const watches = t.live.watcher.count();
    t.mk("node_modules/paquete/indice.js");
    _ = try t.sync();
    try testing.expect(try t.found("node_modules", "node_modules"));
    try testing.expect(!try t.found("indice", "node_modules/paquete/indice.js"));
    try testing.expectEqual(watches, t.live.watcher.count());
    // Same as the scan.
    try t.compact();
    try testing.expect(try t.found("node_modules", "node_modules"));
    try testing.expect(!try t.found("indice", "node_modules/paquete/indice.js"));
}

test "live: files added after the scan leave with their folder" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    // In the delta, under scaffolding roots for modulo and modulo/interno,
    // and in a folder created after the scan.
    t.mk("modulo/tras_scan.rs");
    t.mk("modulo/interno/tras_scan_hondo.rs");
    t.mk("modulo/creada/tras_scan_creada.rs");
    _ = try t.sync();
    try testing.expect(try t.found("tras_scan", "modulo/tras_scan.rs"));
    try testing.expect(try t.found("tras_scan_hondo", "modulo/interno/tras_scan_hondo.rs"));

    t.mv("root/modulo", "outside/modulo");
    _ = try t.sync();
    try testing.expectEqual(0, try t.under("tras_scan", "root"));
    try testing.expectEqual(0, try t.under("creada", "root"));
    // Their scaffolding is forgotten with them.
    var it = t.live.delta.roots.keyIterator();
    while (it.next()) |k| try testing.expect(!std.mem.endsWith(u8, k.*, "/modulo") and
        std.mem.find(u8, k.*, "/modulo/") == null);

    // Back again: there once, at the old path.
    t.mv("outside/modulo", "root/modulo");
    _ = try t.sync();
    for ([_][2][]const u8{
        .{ "tras_scan", "modulo/tras_scan.rs" },
        .{ "tras_scan_hondo", "modulo/interno/tras_scan_hondo.rs" },
        .{ "tras_scan_creada", "modulo/creada/tras_scan_creada.rs" },
    }) |c| try testing.expectEqual(1, try t.count(c[0], c[1]));
}

test "live: a directory renamed over an empty one keeps what it holds" {
    // `mv -T modulo vacio`: one MOVED_FROM, one MOVED_TO of a name already
    // indexed, and the old vacio's DELETE_SELF while its path exists.
    const t = try Tree.create(&(sample_tree ++ [_][]const u8{"vacio/"}));
    defer t.destroy();
    t.mv("root/modulo", "root/vacio");
    _ = try t.sync();
    try testing.expectEqual(1, try t.count("hoja", "vacio/interno/hoja.rs"));
    try testing.expectEqual(1, try t.count("raiz", "vacio/raiz.rs"));
    try testing.expectEqual(1, try t.count("vacio", "vacio"));
    try testing.expectEqual(0, try t.under("hoja", "root/modulo"));
    // And watched: what changes in it shows up.
    t.mk("vacio/interno/despues.rs");
    _ = try t.sync();
    try testing.expect(try t.found("despues", "vacio/interno/despues.rs"));
}

test "live: a folder swapped for a link is never followed" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    t.mkAbs("outside/secreto/clave.txt");
    const watches = t.live.watcher.count();
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    // `mkdir x; rmdir x; ln -s ... x` faster than the events are read: the
    // CREATE of a directory comes for what is a link by then. One link out
    // of the tree, one to a folder inside it.
    _ = linux.symlink(t.abs("outside/secreto", &a), t.abs("root/afuera", &b));
    _ = linux.symlink(t.abs("root/modulo", &a), t.abs("root/adentro", &b));
    _ = try t.live.apply(&.{
        .{ .created = .{ .parent = 0, .name = "afuera", .is_dir = true } },
        .{ .created = .{ .parent = 0, .name = "adentro", .is_dir = true } },
    });
    try t.live.finishScans();
    _ = try t.sync();
    try testing.expectEqual(0, try t.under("clave", ""));
    try testing.expectEqual(0, try t.under("hoja", "root/adentro"));
    try testing.expectEqual(watches, t.live.watcher.count());

    // modulo's watches still point at modulo: its changes show up there.
    t.mk("modulo/interno/sigue.rs");
    _ = try t.sync();
    try testing.expectEqual(1, try t.count("sigue", "modulo/interno/sigue.rs"));
    try testing.expectEqual(1, try t.under("sigue", ""));
}

test "live: a large directory moved in asks for a rescan instead" {
    const t = try Tree.create(&sample_tree);
    defer t.destroy();
    t.live.limits.delta_max = 4;
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |n| {
        var buf: [64]u8 = undefined;
        t.mkAbs(try std.mem.print(&buf, "outside/grande/sub/pieza_{s}.txt", .{n}));
    }
    t.mv("outside/grande", "root/grande");
    _ = try t.sync();
    // Read up to the level past the limit and dropped: a rescan follows.
    try testing.expect(t.live.pending_resync);
    try testing.expectEqual(0, try t.under("pieza", ""));
    try t.compact();
    try testing.expectEqual(6, try t.under("pieza", "root/grande"));
}

test "live: paths too long to open are left out, not shown empty" {
    const gpa = testing.allocator;
    var b: Builder = .empty;
    var parent = try b.push(gpa, "/r", store_mod.no_parent, store_mod.flag_dir, 0);
    const long: [250]u8 = @splat('d');
    for (0..20) |i| parent = try b.push(gpa, &long, parent, store_mod.flag_dir, @intCast(i + 1));
    _ = try b.push(gpa, "profundo_uno.txt", parent, 0, 21);
    _ = try b.push(gpa, "profundo_dos.txt", parent, 0, 21);
    const base = try b.finish(gpa);
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    const roots = [_][]const u8{"/r"};
    const cfg: scan.Config = .{ .roots = &roots };
    var l = try Live.initUnarmed(gpa, base, &cfg, null, pool);
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var hits: std.ArrayList(Hit) = .empty;
    try l.search(arena.allocator(), pool, "profundo", .{ .limit = 10, .recency = false }, &hits);
    try testing.expectEqual(0, hits.items.len);
}
