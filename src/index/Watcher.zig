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

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const Watcher = @This();

const log = std.log.scoped(.watcher);

fd: i32,
wd_to_id: std.AutoHashMapUnmanaged(i32, u32) = .empty,
/// Directories left unwatched because the inotify limit was reached.
unwatched: u32 = 0,
buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.EXCL_UNLINK | linux.IN.ONLYDIR;

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

pub fn create(gpa: std.mem.Allocator) !*Watcher {
    const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.Inotify;
    const w = try gpa.create(Watcher);
    w.* = .{ .fd = @intCast(rc) };
    return w;
}

/// Closing a descriptor with 72k watches takes the kernel milliseconds:
/// callers do it outside any lock searches wait on.
pub fn destroy(w: *Watcher, gpa: std.mem.Allocator) void {
    sys.close(w.fd);
    w.wd_to_id.deinit(gpa);
    gpa.destroy(w);
}

pub fn count(w: *const Watcher) usize {
    return w.wd_to_id.count();
}

/// Watches `path`, attributing its events to index entry `id`. The kernel
/// keys watches by inode: watching the same directory again returns the same
/// descriptor and only the id it maps to changes.
/// Watches `path` as entry `id`. Failing is not fatal for the caller (the
/// directory just goes unwatched until the next rescan), but hitting the
/// kernel's limit is counted in `unwatched` and logged once.
pub fn watch(w: *Watcher, gpa: std.mem.Allocator, path: [*:0]const u8, id: u32) error{ WatchLimit, Watch, OutOfMemory }!void {
    const rc = linux.inotify_add_watch(w.fd, path, mask);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOSPC => {
            if (w.unwatched == 0) log.warn("inotify watch limit reached: raise fs.inotify.max_user_watches to watch every folder", .{});
            w.unwatched += 1;
            return error.WatchLimit;
        },
        // Gone since it was listed, or not ours to read: nothing to watch.
        else => return error.Watch,
    }
    try w.wd_to_id.put(gpa, @intCast(rc), id);
}

/// Reads everything pending without waiting. Names live in `arena`.
pub fn drain(w: *Watcher, arena: std.mem.Allocator, out: *std.ArrayList(Change)) !void {
    while (true) {
        const rc = linux.read(w.fd, &w.buf, w.buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR => continue,
            else => return error.Read,
        }
        if (rc == 0) return;
        try w.parse(arena, rc, out);
        // read() returns whole events only, so a full queue rarely fills the
        // buffer to the byte: `rc < buf.len` stopped after one read, and an
        // overflow at the end of the queue was seen thousands of (wasted)
        // changes later. Stop once there clearly was room for more.
        if (rc + @sizeOf(linux.inotify_event) + 256 < w.buf.len) return;
    }
}

fn parse(w: *Watcher, arena: std.mem.Allocator, n: usize, out: *std.ArrayList(Change)) !void {
    const head = @sizeOf(linux.inotify_event);
    var off: usize = 0;
    while (off + head <= n) {
        const ev: *align(1) const linux.inotify_event = @ptrCast(&w.buf[off]);
        const name_start = off + head;
        if (name_start + ev.len > n) break;
        defer off = name_start + ev.len;

        if (ev.mask & linux.IN.Q_OVERFLOW != 0) {
            try out.append(arena, .overflow);
            continue;
        }
        // The kernel dropped the watch (directory deleted): forget it, or
        // `count` kept growing with every directory ever removed.
        if (ev.mask & linux.IN.IGNORED != 0) {
            _ = w.wd_to_id.remove(ev.wd);
            continue;
        }
        const id = w.wd_to_id.get(ev.wd) orelse continue;
        if (ev.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
            try out.append(arena, .{ .dir_gone = id });
            continue;
        }
        if (ev.len == 0) continue;
        // The name is NUL-padded up to `len`.
        const raw = w.buf[name_start .. name_start + ev.len];
        const name = std.mem.sliceTo(raw, 0);
        if (name.len == 0) continue;
        const owned = try arena.dupe(u8, name);
        if (ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
            try out.append(arena, .{ .created = .{ .parent = id, .name = owned, .is_dir = ev.mask & linux.IN.ISDIR != 0 } });
        } else if (ev.mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0) {
            try out.append(arena, .{ .removed = .{ .parent = id, .name = owned } });
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn tmpAbs(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.mem.sliceTo(cwd_buf[0..linux.getcwd(&cwd_buf, cwd_buf.len)], 0);
    var rel_buf: [4096]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ cwd, try sys.tmpDirPath(tmp, &rel_buf) });
}

test "watcher: events become changes attributed to the watched entry" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    const w = try create(gpa);
    defer w.destroy(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    try w.watch(gpa, try std.fmt.bufPrintZ(&b1, "{s}", .{dir}), 7);
    try sys.writeFile(try std.fmt.bufPrintZ(&b1, "{s}/f", .{dir}), "x");
    const d = try std.fmt.bufPrintZ(&b2, "{s}/d", .{dir});
    _ = linux.mkdir(d, 0o755);
    try sys.rename(try std.fmt.bufPrintZ(&b1, "{s}/f", .{dir}), try std.fmt.bufPrintZ(&b2, "{s}/g", .{dir}));
    _ = linux.unlink(try std.fmt.bufPrintZ(&b1, "{s}/g", .{dir}));

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
    try w.watch(gpa, try std.fmt.bufPrintZ(&b2, "{s}/d", .{dir}), 8);
    try testing.expectEqual(2, w.count());
    _ = linux.rmdir(try std.fmt.bufPrintZ(&b2, "{s}/d", .{dir}));
    changes.clearRetainingCapacity();
    try w.drain(arena, &changes);
    var gone = false;
    for (changes.items) |ch| gone = gone or (ch == .dir_gone and ch.dir_gone == 8);
    try testing.expect(gone);
    try testing.expectEqual(1, w.count());

    // Watching an inode again re-points it: one watch, the new id.
    try w.watch(gpa, try std.fmt.bufPrintZ(&b1, "{s}", .{dir}), 9);
    try testing.expectEqual(1, w.count());
    try sys.writeFile(try std.fmt.bufPrintZ(&b1, "{s}/h", .{dir}), "x");
    changes.clearRetainingCapacity();
    try w.drain(arena, &changes);
    try testing.expect(changes.items.len == 1 and changes.items[0].created.parent == 9);
}

test "watcher: a flooded queue reports the overflow in one drain" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [4096]u8 = undefined;
    const dir = try tmpAbs(&tmp, &dbuf);
    var qbuf: [32]u8 = undefined;
    const max_queued = std.fmt.parseInt(usize, std.mem.trim(u8, sys.readHead("/proc/sys/fs/inotify/max_queued_events", &qbuf), " \n"), 10) catch 16384;
    if (max_queued > 200_000) return error.SkipZigTest;

    const w = try create(gpa);
    defer w.destroy(gpa);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    try w.watch(gpa, try std.fmt.bufPrintZ(&a, "{s}", .{dir}), 0);
    // 48-byte events: 64 KiB is not a whole number of them, so read() never
    // fills the buffer to the byte.
    const pa = try std.fmt.bufPrintZ(&a, "{s}/rename_target_a_xx", .{dir});
    const pb = try std.fmt.bufPrintZ(&b, "{s}/rename_target_b_xx", .{dir});
    try sys.writeFile(pa, "x");
    // Two events per rename, never coalesced (different cookies).
    for (0..max_queued / 2 + 100) |i| {
        if (i % 2 == 0) try sys.rename(pa, pb) else try sys.rename(pb, pa);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var changes: std.ArrayList(Change) = .empty;
    try w.drain(arena_state.allocator(), &changes);
    try testing.expect(changes.items.len >= max_queued - 1);
    try testing.expect(changes.items[changes.items.len - 1] == .overflow);
}
