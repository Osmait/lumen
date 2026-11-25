//! The live index's layer on top of its base store: the entries inotify
//! reported after the scan (see `Live`). Not thread-safe: `Live` owns it and
//! `Service` serializes every access.
//!
//! The same entries are kept twice, under the same ids:
//!
//!   - `builder` is mutable and always current. Lookups made while a batch
//!     of events is applied (`child`, `alive`, the tombstone walks) read it.
//!   - `store` is the searchable copy, rebuilt from the builder after each
//!     batch (`rebuild`). Small by construction (a rescan replaces the whole
//!     delta once it grows), so rebuilding it whole is cheaper and simpler
//!     than keeping it mutable.
//!
//! The delta is not built level by level like a scanned store, so children
//! are found through `kids` instead of a binary search. An entry under a
//! base directory hangs from a scaffolding root (`root`): an entry named
//! with the directory's whole path, with mask 0, which rebuilds paths but
//! never shows up.
//!
//! Every field is about the delta's own ids, so a rescan, which starts a new
//! delta, resets all of them in one assignment.

const std = @import("std");
const paths = @import("paths.zig");
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Builder = store_mod.Builder;
const search = @import("search.zig");

const Delta = @This();

const NameKey = struct { parent: u32, name: []const u8 };

const NameContext = struct {
    builder: *const Builder,

    fn nameOf(builder: *const Builder, id: u32) []const u8 {
        const offset = builder.name_offsets.items[id];
        return builder.names.items[offset..][0..builder.name_sizes.items[id]];
    }

    pub fn hash(ctx: NameContext, id: u32) u64 {
        return hashKey(.{ .parent = ctx.builder.parents.items[id], .name = nameOf(ctx.builder, id) });
    }

    pub fn eql(ctx: NameContext, a: u32, b: u32) bool {
        if (ctx.builder.parents.items[a] != ctx.builder.parents.items[b]) return false;
        return std.mem.eql(u8, nameOf(ctx.builder, a), nameOf(ctx.builder, b));
    }

    fn hashKey(key: NameKey) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(std.mem.asBytes(&key.parent));
        h.update(key.name);
        return h.final();
    }
};

const NameAdapter = struct {
    builder: *const Builder,

    pub fn hash(_: NameAdapter, key: NameKey) u64 {
        return NameContext.hashKey(key);
    }

    pub fn eql(adapter: NameAdapter, key: NameKey, id: u32) bool {
        if (adapter.builder.parents.items[id] != key.parent) return false;
        return std.mem.eql(u8, NameContext.nameOf(adapter.builder, id), key.name);
    }
};

const NameMap = std.HashMapUnmanaged(
    u32,
    void,
    NameContext,
    std.hash_map.default_max_load_percentage,
);

/// Searchable version of `builder`, rebuilt after each batch of changes.
store: Store,
builder: Builder = .empty,
/// Absolute directory path -> its scaffolding root in the delta, so every
/// new file of one directory hangs from the same root. Owns the keys.
roots: std.StringHashMapUnmanaged(u32) = .empty,
/// Delta entry -> the delta entries under it (scaffolding roots
/// included), so finding a subtree is not a walk over the whole delta.
kids: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
/// O(1) lookup by `(parent, name)` into `builder` for live delta entries.
by_name: NameMap = .empty,
/// Persistent engine over `store` (see `Live.engine_base`).
engine: search.Engine = .empty,

/// What a tombstone walk did. Out of memory, part of a subtree may stay
/// searchable under dead paths: `complete` is false, and the caller asks
/// for a rescan.
pub const Tombstoned = struct {
    count: usize = 0,
    complete: bool = true,

    fn add(tombstoned: *Tombstoned, other: Tombstoned) void {
        tombstoned.count += other.count;
        tombstoned.complete = tombstoned.complete and other.complete;
    }
};

/// An empty delta. The only fallible step of a reset, so callers make the
/// new one before they drop the old one.
pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Delta {
    var empty: Builder = .empty;
    return .{ .store = try empty.finish(gpa) };
}

pub fn deinit(delta: *Delta, gpa: std.mem.Allocator) void {
    delta.store.deinit(gpa);
    delta.builder.deinit(gpa);
    var root_paths = delta.roots.keyIterator();
    while (root_paths.next()) |root_path| gpa.free(root_path.*);
    delta.roots.deinit(gpa);
    var kids_lists = delta.kids.valueIterator();
    while (kids_lists.next()) |list| list.deinit(gpa);
    delta.kids.deinit(gpa);
    delta.by_name.deinit(gpa);
    delta.engine.deinit(gpa);
    delta.* = undefined;
}

/// Entries pushed since the delta started, tombstoned ones included.
pub fn len(delta: *const Delta) u32 {
    return delta.builder.len();
}

/// Whether delta entry `id` exists and is not tombstoned. Scaffolding
/// roots never are alive.
pub fn alive(delta: *const Delta, id: u32) bool {
    if (id >= delta.len()) return false;
    return delta.builder.masks.items[id] != 0;
}

pub fn flags(delta: *const Delta, id: u32) u8 {
    return delta.builder.flags.items[id];
}

pub fn isDir(delta: *const Delta, id: u32) bool {
    return delta.flags(id) & store_mod.flag_dir != 0;
}

/// Child of delta entry `directory` named `child_name`, looked up in O(1) via
/// `by_name` against `builder` (never `store`: that one is only rebuilt after
/// the batch).
pub fn child(delta: *const Delta, directory: u32, child_name: []const u8) ?u32 {
    const id = delta.by_name.getKeyAdapted(
        NameKey{ .parent = directory, .name = child_name },
        NameAdapter{ .builder = &delta.builder },
    ) orelse return null;
    assert(delta.builder.masks.items[id] != 0);
    return id;
}

/// Adds an entry under delta entry `parent`, and to its parent's `kids` and `by_name`.
/// Atomic on OOM: if updating `kids` or `by_name` fails, `delta.builder` is untouched.
pub fn push(
    delta: *Delta,
    gpa: std.mem.Allocator,
    name: []const u8,
    parent: u32,
    entry_flags: u8,
    depth: u16,
) std.mem.Allocator.Error!u32 {
    const kids = try delta.kids.getOrPut(gpa, parent);
    if (!kids.found_existing) kids.value_ptr.* = .empty;
    try kids.value_ptr.ensureUnusedCapacity(gpa, 1);
    const map_ctx: NameContext = .{ .builder = &delta.builder };
    try delta.by_name.ensureUnusedCapacityContext(gpa, 1, map_ctx);
    const id = try delta.builder.push(gpa, name, parent, entry_flags, depth);
    kids.value_ptr.appendAssumeCapacity(id);
    delta.by_name.putAssumeCapacityContext(id, {}, map_ctx);
    return id;
}

/// The scaffolding root for base directory `dir_path`, made on first use.
/// Atomic on OOM: if updating `roots` fails, `delta.builder` is untouched.
pub fn root(
    delta: *Delta,
    gpa: std.mem.Allocator,
    dir_path: []const u8,
    depth: u16,
) std.mem.Allocator.Error!u32 {
    if (delta.roots.get(dir_path)) |id| return id;
    try delta.roots.ensureUnusedCapacity(gpa, 1);
    const key = try gpa.dupe(u8, dir_path);
    errdefer gpa.free(key);
    const id = try delta.builder.pushStructural(
        gpa,
        dir_path,
        store_mod.no_parent,
        store_mod.flag_dir,
        depth,
    );
    delta.roots.putAssumeCapacity(key, id);
    return id;
}

/// Copies a freshly scanned sub-index into the delta under `directory`, the
/// entry its root stands for (scan names roots by absolute path, which here
/// would be a result that does not exist after compaction). Returns the
/// delta id of each sub-index entry; the caller frees it.
pub fn appendStore(
    delta: *Delta,
    gpa: std.mem.Allocator,
    sub: *const Store,
    directory: u32,
    base_depth: u16,
    hidden: u8,
) std.mem.Allocator.Error![]u32 {
    const map = try gpa.alloc(u32, sub.len());
    errdefer gpa.free(map);
    const parents = sub.parents();
    const sub_flags = sub.flags();
    const depths = sub.depths();
    for (0..sub.len()) |sub_index| {
        const parent = parents[sub_index];
        if (parent == store_mod.no_parent) {
            map[sub_index] = directory;
            continue;
        }
        // Parents come first: theirs is mapped already.
        assert(parent < sub_index);
        const name = sub.name(@intCast(sub_index));
        const entry_flags = sub_flags[sub_index] | hidden;
        const depth = base_depth +| depths[sub_index];
        map[sub_index] = try delta.push(gpa, name, map[parent], entry_flags, depth);
    }
    return map;
}

/// Makes `store` match `builder`. Ids stay the same (`kids` relies on it).
/// Atomic on OOM: `builder` and `store` stay untouched if allocation fails.
pub fn rebuild(delta: *Delta, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    const fresh = try delta.builder.toStore(gpa);
    delta.store.deinit(gpa);
    delta.store = fresh;
    // Ids changed: the engine's cached candidates mean nothing now.
    delta.engine.reset();
}

/// Tombstones delta entry `root_id` and its subtree, in the builder and
/// in `store` (for the same reason as `child`).
pub fn tombstoneTree(delta: *Delta, gpa: std.mem.Allocator, root_id: u32) Tombstoned {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    stack.append(gpa, root_id) catch return .{ .complete = false };
    var tombstoned: Tombstoned = .{};
    const builder = &delta.builder;
    while (stack.pop()) |id| {
        if (builder.masks.items[id] == 0) continue;
        if (builder.flags.items[id] & store_mod.flag_dir != 0) {
            if (delta.kids.get(id)) |kids| {
                stack.appendSlice(gpa, kids.items) catch {
                    tombstoned.complete = false;
                };
            }
        }
        const adapter: NameAdapter = .{ .builder = builder };
        _ = delta.by_name.removeAdapted(
            NameKey{ .parent = builder.parents.items[id], .name = NameContext.nameOf(builder, id) },
            adapter,
        );
        builder.tombstone(id);
        if (id < delta.store.len()) delta.store.tombstone(id);
        tombstoned.count += 1;
    }
    return tombstoned;
}

/// Tombstones what was added below base directory `dir_path`. It hangs
/// from scaffolding roots found by path, not from the base entry, so a walk
/// over the base missed it: a file created in a folder then moved away with
/// it stayed searchable under the old path for good.
pub fn tombstoneUnder(delta: *Delta, gpa: std.mem.Allocator, dir_path: []const u8) Tombstoned {
    var tombstoned: Tombstoned = .{};
    var gone: std.ArrayList([]const u8) = .empty;
    defer gone.deinit(gpa);
    var roots = delta.roots.iterator();
    while (roots.next()) |root_entry| {
        if (!paths.isUnder(root_entry.key_ptr.*, dir_path)) continue;
        if (delta.kids.get(root_entry.value_ptr.*)) |kids| {
            for (kids.items) |kid| tombstoned.add(delta.tombstoneTree(gpa, kid));
        }
        // Forgotten too: a folder at that path again is another folder.
        gone.append(gpa, root_entry.key_ptr.*) catch {
            tombstoned.complete = false;
        };
    }
    for (gone.items) |root_path| {
        _ = delta.roots.remove(root_path);
        gpa.free(root_path);
    }
    return tombstoned;
}

test "Delta.push and Delta.root leave delta.builder untouched on OOM" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var delta = try Delta.init(testing.allocator);
    defer delta.deinit(testing.allocator);

    // Every OOM point during root() leaves builder length unchanged.
    for (0..4) |fail_step| {
        failing.fail_index = failing.alloc_index + fail_step;
        _ = delta.root(gpa, "/tmp/root_a", 0) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), delta.builder.len());
            continue;
        };
        break;
    }
    failing.fail_index = std.math.maxInt(usize);
    const root_id = try delta.root(testing.allocator, "/tmp/root_b", 0);
    const len_before_push = delta.builder.len();

    // Fail on the kids allocation inside push(): builder must not keep a ghost entry.
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, delta.push(gpa, "ghost.txt", root_id, 0, 1));
    try testing.expectEqual(len_before_push, delta.builder.len());
    try testing.expectEqual(@as(?u32, null), delta.child(root_id, "ghost.txt"));
}

test "Delta.child remains O(1) across many entries in one folder" {
    const testing = std.testing;
    var delta = try Delta.init(testing.allocator);
    defer delta.deinit(testing.allocator);
    const dir_id = try delta.root(testing.allocator, "/tmp/many", 0);

    var name_buf: [32]u8 = undefined;
    var ids: [2000]u32 = undefined;
    for (0..2000) |i| {
        const name = try std.mem.print(&name_buf, "file_{d}.txt", .{i});
        ids[i] = try delta.push(testing.allocator, name, dir_id, 0, 1);
    }
    try testing.expectEqual(@as(?u32, ids[0]), delta.child(dir_id, "file_0.txt"));
    try testing.expectEqual(@as(?u32, ids[1999]), delta.child(dir_id, "file_1999.txt"));
    _ = delta.tombstoneTree(testing.allocator, ids[0]);
    try testing.expectEqual(@as(?u32, null), delta.child(dir_id, "file_0.txt"));
    try testing.expectEqual(@as(?u32, ids[1]), delta.child(dir_id, "file_1.txt"));
}
