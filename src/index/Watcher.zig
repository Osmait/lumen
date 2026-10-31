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
const paths = @import("paths.zig");
const assert = std.debug.assert;
const linux = std.os.linux;
const sys = @import("os");

const Watcher = @This();

const log = std.log.scoped(.watcher);

fd: i32,
/// Watch descriptor -> the index entry its events are attributed to.
watch_ids: std.AutoHashMapUnmanaged(i32, u32) = .empty,
/// Directories left unwatched because the inotify limit was reached.
unwatched: u32 = 0,
events_buffer: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

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
    const result = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.Inotify;
    const fd: i32 = @intCast(result);
    errdefer sys.close(fd);
    const watcher = try gpa.create(Watcher);
    watcher.* = .{ .fd = fd };
    return watcher;
}

/// Closing a descriptor with 72k watches takes the kernel milliseconds:
/// callers do it outside any lock searches wait on.
pub fn destroy(watcher: *Watcher, gpa: std.mem.Allocator) void {
    sys.close(watcher.fd);
    watcher.watch_ids.deinit(gpa);
    gpa.destroy(watcher);
}

pub fn count(watcher: *const Watcher) usize {
    return watcher.watch_ids.count();
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
    try watcher.watch_ids.ensureUnusedCapacity(gpa, 1);
    const result = linux.inotify_add_watch(watcher.fd, path, events);
    switch (linux.errno(result)) {
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
    watcher.watch_ids.putAssumeCapacity(@intCast(result), id);
}

/// Stops watching every directory whose entry `alive` rejects. A directory
/// moved out of the tree is not deleted, so the kernel kept its watch (and
/// everything below's) until the next rescan.
pub fn prune(
    watcher: *Watcher,
    gpa: std.mem.Allocator,
    context: anytype,
    comptime alive: fn (@TypeOf(context), u32) bool,
) void {
    var dead: std.ArrayList(i32) = .empty;
    defer dead.deinit(gpa);
    var watches = watcher.watch_ids.iterator();
    while (watches.next()) |entry| {
        if (alive(context, entry.value_ptr.*)) continue;
        // Out of memory: what is not pruned now is at the next rescan.
        dead.append(gpa, entry.key_ptr.*) catch break;
    }
    for (dead.items) |descriptor| {
        // Its IN_IGNORED comes later and finds nothing to forget. EINVAL:
        // the kernel dropped the watch already (its folder was deleted).
        const removed = linux.errno(linux.inotify_rm_watch(watcher.fd, descriptor));
        if (removed != .SUCCESS and removed != .INVAL) {
            log.warn("removing a watch: {t}", .{removed});
        }
        _ = watcher.watch_ids.remove(descriptor);
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
        const events_buffer = &watcher.events_buffer;
        const bytes_read = linux.read(watcher.fd, events_buffer, events_buffer.len);
        switch (linux.errno(bytes_read)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR => continue,
            else => return error.Read,
        }
        if (bytes_read == 0) return;
        assert(bytes_read <= watcher.events_buffer.len);
        try watcher.parse(arena, bytes_read, out);
        // read() returns whole events only, so a full queue rarely fills the
        // buffer to the byte: `bytes_read < events_buffer.len` stopped after
        // one read, and an overflow at the end of the queue was seen
        // thousands of (wasted) changes later. Stop once there clearly was
        // room for more.
        const event_bytes_max = @sizeOf(linux.inotify_event) + linux.NAME_MAX + 1;
        if (bytes_read + event_bytes_max < watcher.events_buffer.len) return;
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
        const event: *align(1) const linux.inotify_event = @ptrCast(&watcher.events_buffer[offset]);
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
            _ = watcher.watch_ids.remove(event.wd);
            continue;
        }
        const id = watcher.watch_ids.get(event.wd) orelse continue;
        if (event.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
            try out.append(arena, .{ .dir_gone = id });
            continue;
        }
        if (event.len == 0) continue;
        // The name is NUL-padded up to `len`.
        const name_padded = watcher.events_buffer[name_start .. name_start + event.len];
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

const temporaryPath = sys.tmpDirAbs;

/// A syscall's result, which must be a success.
fn expectSuccess(result: usize) !void {
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
}

test "watcher: events become changes attributed to the watched entry" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    const watcher = try create(gpa);
    defer watcher.destroy(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var path_buffer: paths.Buffer = undefined;
    var other_path_buffer: paths.Buffer = undefined;
    try watcher.watch(gpa, try std.mem.printSentinel(&path_buffer, "{s}", .{directory}, 0), 7);
    try sys.writeFile(try std.mem.printSentinel(&path_buffer, "{s}/f", .{directory}, 0), "x");
    const sub = try std.mem.printSentinel(&other_path_buffer, "{s}/d", .{directory}, 0);
    try expectSuccess(linux.mkdir(sub, 0o755));
    try sys.rename(
        try std.mem.printSentinel(&path_buffer, "{s}/f", .{directory}, 0),
        try std.mem.printSentinel(&other_path_buffer, "{s}/g", .{directory}, 0),
    );
    const renamed = try std.mem.printSentinel(&path_buffer, "{s}/g", .{directory}, 0);
    try expectSuccess(linux.unlink(renamed));

    var changes: std.ArrayList(Change) = .empty;
    try watcher.drain(arena, &changes);
    try testing.expectEqual(5, changes.items.len);
    const seen = changes.items;
    try testing.expect(seen[0] == .created);
    try testing.expectEqual(7, seen[0].created.parent);
    try testing.expect(!seen[0].created.is_dir);
    try testing.expectEqualStrings("f", seen[0].created.name);
    try testing.expect(seen[1] == .created);
    try testing.expect(seen[1].created.is_dir);
    try testing.expectEqualStrings("d", seen[1].created.name);
    try testing.expect(seen[2] == .removed);
    try testing.expectEqual(7, seen[2].removed.parent);
    try testing.expectEqualStrings("f", seen[2].removed.name);
    try testing.expect(seen[3] == .created);
    try testing.expectEqualStrings("g", seen[3].created.name);
    try testing.expect(seen[4] == .removed);
    try testing.expectEqualStrings("g", seen[4].removed.name);

    // The directory itself going away, and its watch with it.
    const sub_path = try std.mem.printSentinel(&other_path_buffer, "{s}/d", .{directory}, 0);
    try watcher.watch(gpa, sub_path, 8);
    try testing.expectEqual(2, watcher.count());
    const sub_again = try std.mem.printSentinel(&other_path_buffer, "{s}/d", .{directory}, 0);
    try expectSuccess(linux.rmdir(sub_again));
    changes.clearRetainingCapacity();
    try watcher.drain(arena, &changes);
    var gone = false;
    for (changes.items) |change| gone = gone or (change == .dir_gone and change.dir_gone == 8);
    try testing.expect(gone);
    try testing.expectEqual(1, watcher.count());

    // Watching an inode again re-points it: one watch, the new id.
    try watcher.watch(gpa, try std.mem.printSentinel(&path_buffer, "{s}", .{directory}, 0), 9);
    try testing.expectEqual(1, watcher.count());
    try sys.writeFile(try std.mem.printSentinel(&path_buffer, "{s}/h", .{directory}, 0), "x");
    changes.clearRetainingCapacity();
    try watcher.drain(arena, &changes);
    try testing.expectEqual(1, changes.items.len);
    try testing.expectEqual(9, changes.items[0].created.parent);
}

test "watcher: links are never followed below a root, and prune drops watches" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    var path_buffer: paths.Buffer = undefined;
    var other_path_buffer: paths.Buffer = undefined;
    const real = try std.mem.printSentinel(&path_buffer, "{s}/real", .{directory}, 0);
    try expectSuccess(linux.mkdir(real, 0o755));
    const link = try std.mem.printSentinel(&other_path_buffer, "{s}/link", .{directory}, 0);
    try expectSuccess(linux.symlink("real", link));
    const watcher = try create(gpa);
    defer watcher.destroy(gpa);

    // Through the link: refused, and `real` keeps the id it was given.
    try watcher.watch(gpa, real, 1);
    try testing.expectError(error.Watch, watcher.watch(gpa, link, 2));
    try testing.expectEqual(1, watcher.count());
    var ids = watcher.watch_ids.valueIterator();
    try testing.expectEqual(1, ids.next().?.*);
    // A root may be a link: followed.
    try watcher.watchRoot(gpa, link, 3);
    try testing.expectEqual(1, watcher.count());
    ids = watcher.watch_ids.valueIterator();
    try testing.expectEqual(3, ids.next().?.*);

    // Pruned: gone from the map and from the kernel (no more events).
    watcher.prune(gpa, @as(u32, 3), struct {
        fn alive(dead_id: u32, id: u32) bool {
            return id != dead_id;
        }
    }.alive);
    try testing.expectEqual(0, watcher.count());
    try sys.writeFile(try std.mem.printSentinel(&path_buffer, "{s}/real/f", .{directory}, 0), "x");
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var changes: std.ArrayList(Change) = .empty;
    try watcher.drain(arena_state.allocator(), &changes);
    try testing.expectEqual(0, changes.items.len);
}

test "watcher: best effort skips what cannot be watched and reports only running out of memory" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    var directory_z_buffer: paths.Buffer = undefined;
    const directory_z = try std.mem.printSentinel(&directory_z_buffer, "{s}", .{directory}, 0);
    var gone_buffer: paths.Buffer = undefined;
    const gone = try std.mem.printSentinel(&gone_buffer, "{s}/gone", .{directory}, 0);
    const watcher = try create(gpa);
    defer watcher.destroy(gpa);

    // Out of memory before the kernel is asked: nothing half made, and the
    // caller hears of it.
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        watcher.watchBestEffort(failing.allocator(), directory_z, 2, .root),
    );
    try testing.expectEqual(0, watcher.count());

    // Gone since it was listed: skipped, not an error.
    try watcher.watchBestEffort(gpa, gone, 1, .below_root);
    try testing.expectEqual(0, watcher.count());

    try watcher.watchBestEffort(gpa, directory_z, 3, .root);
    try testing.expectEqual(1, watcher.count());
}

test "watcher: a flooded queue reports the overflow in one drain" {
    const gpa = testing.allocator;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: paths.Buffer = undefined;
    const directory = try temporaryPath(&temporary, &directory_buffer);
    var queued_text: [32]u8 = undefined;
    const queued_read = sys.readHead("/proc/sys/fs/inotify/max_queued_events", &queued_text);
    const queued_trimmed = std.mem.trim(u8, queued_read, " \n");
    const queued_max = std.fmt.parseInt(usize, queued_trimmed, 10) catch 16384;
    if (queued_max > 200_000) return error.SkipZigTest;

    const watcher = try create(gpa);
    defer watcher.destroy(gpa);
    var path_a_buffer: paths.Buffer = undefined;
    var path_b_buffer: paths.Buffer = undefined;
    try watcher.watch(gpa, try std.mem.printSentinel(&path_a_buffer, "{s}", .{directory}, 0), 0);
    // 48-byte events: 64 KiB is not a whole number of them, so read() never
    // fills the buffer to the byte.
    const path_a = try std.mem.printSentinel(
        &path_a_buffer,
        "{s}/rename_target_a_xx",
        .{directory},
        0,
    );
    const path_b = try std.mem.printSentinel(
        &path_b_buffer,
        "{s}/rename_target_b_xx",
        .{directory},
        0,
    );
    try sys.writeFile(path_a, "x");
    // Two events per rename, never coalesced (different cookies).
    for (0..queued_max / 2 + 100) |i| {
        if (i % 2 == 0) try sys.rename(path_a, path_b) else try sys.rename(path_b, path_a);
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var changes: std.ArrayList(Change) = .empty;
    try watcher.drain(arena_state.allocator(), &changes);
    try testing.expect(changes.items.len >= queued_max - 1);
    try testing.expect(changes.items[changes.items.len - 1] == .overflow);
}
