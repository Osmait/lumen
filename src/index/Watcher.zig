//! inotify watches over the indexed tree.
//!
//!   - Not recursive: one watch per directory (72k on the author's $HOME;
//!     `max_user_watches` is 524288).
//!   - The queue overflows (`max_queued_events`, 16384): then changes were
//!     lost and the only correct answer is a rescan, hence `.overflow`.
//!   - Creating a directory races with watching it: files may appear inside
//!     before the watch exists, so a new directory is scanned whole.
//!
//! fanotify with FAN_MARK_FILESYSTEM would need one mark, but requires
//! CAP_SYS_ADMIN: not for a user launcher.
//!
//! Not thread-safe: its owner (`Live`) is used under the service's lock.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sys = @import("os");

const Watcher = @This();

const log = std.log.scoped(.watcher);

fd: i32,
wd_to_id: std.AutoHashMapUnmanaged(i32, u32) = .empty,
/// Directories left unwatched because the inotify limit was reached.
unwatched: u32 = 0,
buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

/// IN_DONT_FOLLOW: a folder swapped for a link to another folder of the
/// tree re-pointed that folder's watch to the link's entry, and its events
/// went to an entry that was not there.
const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.EXCL_UNLINK | linux.IN.ONLYDIR |
    linux.IN.DONT_FOLLOW;

pub const Change = union(enum) {
    /// Something appeared in directory `parent`; a directory must be
    /// scanned whole (it may have filled before we watched it).
    created: struct { parent: u32, name: []const u8, is_dir: bool },
    /// Something left `parent` (deleted or moved away).
    removed: struct { parent: u32, name: []const u8 },
    /// The watched directory itself went away.
    dir_gone: u32,
    /// Kernel queue overflow: changes were missed. Rescan.
    overflow,
};

pub const CreateError = error{Inotify} || std.mem.Allocator.Error;

pub fn create(gpa: std.mem.Allocator) CreateError!*Watcher {
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.Inotify;
    const fd: i32 = @intCast(rc);
    errdefer sys.close(fd);
    const w = try gpa.create(Watcher);
    w.* = .{ .fd = fd };
    return w;
}

/// Closing a descriptor with 72k watches takes the kernel milliseconds:
/// callers do it outside any lock searches wait on.
pub fn destroy(watcher: *Watcher, gpa: std.mem.Allocator) void {
    sys.close(watcher.fd);
    watcher.wd_to_id.deinit(gpa);
    gpa.destroy(watcher);
}

pub fn count(watcher: *const Watcher) usize {
    return watcher.wd_to_id.count();
}

pub const WatchError = error{ WatchLimit, Watch, OutOfMemory };

/// Watches directory `path` (never a link to one), attributing its events to
/// index entry `id`. The kernel keys watches by inode: watching the same
/// directory again returns the same descriptor and only the id it maps to
/// changes. Failing is not fatal for the caller (the directory goes
/// unwatched until the next rescan); hitting the kernel's limit is counted
/// in `unwatched` and logged once.
pub fn watch(
    watcher: *Watcher,
    gpa: std.mem.Allocator,
    path: [*:0]const u8,
    id: u32,
) WatchError!void {
    return watcher.add(gpa, path, id, mask);
}

/// `watch` for a root of the index, which may be a link ($HOME often is).
pub fn watchRoot(
    watcher: *Watcher,
    gpa: std.mem.Allocator,
    path: [*:0]const u8,
    id: u32,
) WatchError!void {
    return watcher.add(gpa, path, id, mask & ~@as(u32, linux.IN.DONT_FOLLOW));
}

/// Where a directory is in the tree: `watchBestEffort` follows a link only
/// for a root.
pub const Placement = enum { root, below_root };

/// `watch` or `watchRoot` for a caller to whom a directory that cannot be
/// watched is not an error: one that is gone, not ours to read or past the
/// kernel's limit stays unwatched until the next rescan. Only running out of
/// memory is returned, so that the caller can try again or give up loudly.
pub fn watchBestEffort(
    watcher: *Watcher,
    gpa: std.mem.Allocator,
    path: [*:0]const u8,
    id: u32,
    placement: Placement,
) std.mem.Allocator.Error!void {
    const result = switch (placement) {
        .root => watcher.watchRoot(gpa, path, id),
        .below_root => watcher.watch(gpa, path, id),
    };
    result catch |err| switch (err) {
        error.WatchLimit, error.Watch => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn add(
    watcher: *Watcher,
    gpa: std.mem.Allocator,
    path: [*:0]const u8,
    id: u32,
    events: u32,
) WatchError!void {
    // Room first: a watch the kernel made but the map could not hold would
    // report events nobody can attribute.
    try watcher.wd_to_id.ensureUnusedCapacity(gpa, 1);
    const rc = linux.inotify_add_watch(watcher.fd, path, events);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOSPC => {
            if (watcher.unwatched == 0) {
                log.warn(
                    "inotify watch limit reached: raise fs.inotify.max_user_watches to watch every folder",
                    .{},
                );
            }
            watcher.unwatched += 1;
            return error.WatchLimit;
        },
        // Gone since it was listed, or not ours to read: nothing to watch.
        else => return error.Watch,
    }
    watcher.wd_to_id.putAssumeCapacity(@intCast(rc), id);
}

/// Stops watching every directory whose entry `alive` rejects. A directory
/// moved out of the tree is not deleted, so the kernel kept its watch (and
/// everything below's) until the next rescan.
pub fn prune(
    watcher: *Watcher,
    gpa: std.mem.Allocator,
    ctx: anytype,
    comptime alive: fn (@TypeOf(ctx), u32) bool,
) void {
    var dead: std.ArrayList(i32) = .empty;
    defer dead.deinit(gpa);
    var watches = watcher.wd_to_id.iterator();
    while (watches.next()) |entry| {
        if (alive(ctx, entry.value_ptr.*)) continue;
        // Out of memory: what is not pruned now is at the next rescan.
        dead.append(gpa, entry.key_ptr.*) catch break;
    }
    for (dead.items) |wd| {
        // Its IN_IGNORED comes later and finds nothing to forget.
        _ = linux.inotify_rm_watch(watcher.fd, wd);
        _ = watcher.wd_to_id.remove(wd);
    }
}

/// Reads everything pending without waiting. Names live in `arena`.
pub const DrainError = error{Read} || std.mem.Allocator.Error;

pub fn drain(
    watcher: *Watcher,
    arena: std.mem.Allocator,
    out: *std.ArrayList(Change),
) DrainError!void {
    while (true) {
        const rc = linux.read(watcher.fd, &watcher.buf, watcher.buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR => continue,
            else => return error.Read,
        }
        if (rc == 0) return;
        assert(rc <= watcher.buf.len);
        try watcher.parse(arena, rc, out);
        // read() returns whole events only, so a full queue rarely fills the
        // buffer to the byte: `rc < buf.len` stopped after one read, and an
        // overflow at the end of the queue was seen thousands of (wasted)
        // changes later. Stop once there clearly was room for more.
        if (rc + @sizeOf(linux.inotify_event) + linux.NAME_MAX + 1 < watcher.buf.len) return;
    }
}

fn parse(
    watcher: *Watcher,
    arena: std.mem.Allocator,
    bytes_read: usize,
    out: *std.ArrayList(Change),
) !void {
    const event_head_size = @sizeOf(linux.inotify_event);
    var offset: usize = 0;
    while (offset + event_head_size <= bytes_read) {
        const event: *align(1) const linux.inotify_event = @ptrCast(&watcher.buf[offset]);
        const name_start = offset + event_head_size;
        if (name_start + event.len > bytes_read) break;
        defer offset = name_start + event.len;

        if (event.mask & linux.IN.Q_OVERFLOW != 0) {
            try out.append(arena, .overflow);
            continue;
        }
        // The kernel dropped the watch (directory deleted): forget it, or
        // `count` kept growing with every directory ever removed.
        if (event.mask & linux.IN.IGNORED != 0) {
            _ = watcher.wd_to_id.remove(event.wd);
            continue;
        }
        const id = watcher.wd_to_id.get(event.wd) orelse continue;
        if (event.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
            try out.append(arena, .{ .dir_gone = id });
            continue;
        }
        if (event.len == 0) continue;
        // The name is NUL-padded up to `len`.
        const name_padded = watcher.buf[name_start .. name_start + event.len];
        const name = std.mem.sliceTo(name_padded, 0);
        if (name.len == 0) continue;
        const owned = try arena.dupe(u8, name);
        if (event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
            try out.append(arena, .{ .created = .{
                .parent = id,
                .name = owned,
                .is_dir = event.mask & linux.IN.ISDIR != 0,
            } });
        } else if (event.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0) {
            try out.append(arena, .{ .removed = .{ .parent = id, .name = owned } });
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const tmpAbs = sys.tmpDirAbs;

test "watcher: events become changes attributed to the watched entry" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    const w = try create(gpa);
    defer w.destroy(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    try w.watch(gpa, try std.mem.printSentinel(&b1, "{s}", .{dir}, 0), 7);
    try sys.writeFile(try std.mem.printSentinel(&b1, "{s}/f", .{dir}, 0), "x");
    const d = try std.mem.printSentinel(&b2, "{s}/d", .{dir}, 0);
    _ = linux.mkdir(d, 0o755);
    try sys.rename(
        try std.mem.printSentinel(&b1, "{s}/f", .{dir}, 0),
        try std.mem.printSentinel(&b2, "{s}/g", .{dir}, 0),
    );
    _ = linux.unlink(try std.mem.printSentinel(&b1, "{s}/g", .{dir}, 0));

    var changes: std.ArrayList(Change) = .empty;
    try w.drain(arena, &changes);
    try testing.expectEqual(5, changes.items.len);
    const c = changes.items;
    try testing.expect(c[0] == .created and c[0].created.parent == 7 and !c[0].created.is_dir);
    try testing.expectEqualStrings("f", c[0].created.name);
    try testing.expect(c[1] == .created and c[1].created.is_dir);
    try testing.expectEqualStrings("d", c[1].created.name);
    try testing.expect(c[2] == .removed and c[2].removed.parent == 7);
    try testing.expectEqualStrings("f", c[2].removed.name);
    try testing.expect(c[3] == .created);
    try testing.expectEqualStrings("g", c[3].created.name);
    try testing.expect(c[4] == .removed);
    try testing.expectEqualStrings("g", c[4].removed.name);

    // The directory itself going away, and its watch with it.
    try w.watch(gpa, try std.mem.printSentinel(&b2, "{s}/d", .{dir}, 0), 8);
    try testing.expectEqual(2, w.count());
    _ = linux.rmdir(try std.mem.printSentinel(&b2, "{s}/d", .{dir}, 0));
    changes.clearRetainingCapacity();
    try w.drain(arena, &changes);
    var gone = false;
    for (changes.items) |ch| gone = gone or (ch == .dir_gone and ch.dir_gone == 8);
    try testing.expect(gone);
    try testing.expectEqual(1, w.count());

    // Watching an inode again re-points it: one watch, the new id.
    try w.watch(gpa, try std.mem.printSentinel(&b1, "{s}", .{dir}, 0), 9);
    try testing.expectEqual(1, w.count());
    try sys.writeFile(try std.mem.printSentinel(&b1, "{s}/h", .{dir}, 0), "x");
    changes.clearRetainingCapacity();
    try w.drain(arena, &changes);
    try testing.expect(changes.items.len == 1 and changes.items[0].created.parent == 9);
}

test "watcher: links are never followed below a root, and prune drops watches" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    const real = try std.mem.printSentinel(&b1, "{s}/real", .{dir}, 0);
    _ = linux.mkdir(real, 0o755);
    const link = try std.mem.printSentinel(&b2, "{s}/link", .{dir}, 0);
    _ = linux.symlink("real", link);
    const w = try create(gpa);
    defer w.destroy(gpa);

    // Through the link: refused, and `real` keeps the id it was given.
    try w.watch(gpa, real, 1);
    try testing.expectError(error.Watch, w.watch(gpa, link, 2));
    try testing.expectEqual(1, w.count());
    var it = w.wd_to_id.valueIterator();
    try testing.expectEqual(1, it.next().?.*);
    // A root may be a link: followed.
    try w.watchRoot(gpa, link, 3);
    try testing.expectEqual(1, w.count());
    it = w.wd_to_id.valueIterator();
    try testing.expectEqual(3, it.next().?.*);

    // Pruned: gone from the map and from the kernel (no more events).
    w.prune(gpa, @as(u32, 3), struct {
        fn alive(dead_id: u32, id: u32) bool {
            return id != dead_id;
        }
    }.alive);
    try testing.expectEqual(0, w.count());
    try sys.writeFile(try std.mem.printSentinel(&b1, "{s}/real/f", .{dir}, 0), "x");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var changes: std.ArrayList(Change) = .empty;
    try w.drain(arena_state.allocator(), &changes);
    try testing.expectEqual(0, changes.items.len);
}

test "watcher: best effort skips what cannot be watched and reports only running out of memory" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dir_buffer);
    var dir_z_buffer: [4096]u8 = undefined;
    const dir_z = try std.mem.printSentinel(&dir_z_buffer, "{s}", .{dir}, 0);
    var gone_buffer: [4096]u8 = undefined;
    const gone = try std.mem.printSentinel(&gone_buffer, "{s}/gone", .{dir}, 0);
    const watcher = try create(gpa);
    defer watcher.destroy(gpa);

    // Out of memory before the kernel is asked: nothing half made, and the
    // caller hears of it.
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        watcher.watchBestEffort(failing.allocator(), dir_z, 2, .root),
    );
    try testing.expectEqual(0, watcher.count());

    // Gone since it was listed: skipped, not an error.
    try watcher.watchBestEffort(gpa, gone, 1, .below_root);
    try testing.expectEqual(0, watcher.count());

    try watcher.watchBestEffort(gpa, dir_z, 3, .root);
    try testing.expectEqual(1, watcher.count());
}

test "watcher: a flooded queue reports the overflow in one drain" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    var qbuf: [32]u8 = undefined;
    const max_queued = std.fmt.parseInt(
        usize,
        std.mem.trim(u8, sys.readHead("/proc/sys/fs/inotify/max_queued_events", &qbuf), " \n"),
        10,
    ) catch 16384;
    if (max_queued > 200_000) return error.SkipZigTest;

    const w = try create(gpa);
    defer w.destroy(gpa);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    try w.watch(gpa, try std.mem.printSentinel(&a, "{s}", .{dir}, 0), 0);
    // 48-byte events: 64 KiB is not a whole number of them, so read() never
    // fills the buffer to the byte.
    const pa = try std.mem.printSentinel(&a, "{s}/rename_target_a_xx", .{dir}, 0);
    const pb = try std.mem.printSentinel(&b, "{s}/rename_target_b_xx", .{dir}, 0);
    try sys.writeFile(pa, "x");
    // Two events per rename, never coalesced (different cookies).
    for (0..max_queued / 2 + 100) |i| {
        if (i % 2 == 0) try sys.rename(pa, pb) else try sys.rename(pb, pa);
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var changes: std.ArrayList(Change) = .empty;
    try w.drain(arena_state.allocator(), &changes);
    try testing.expect(changes.items.len >= max_queued - 1);
    try testing.expect(changes.items[changes.items.len - 1] == .overflow);
}
