//! SQLite store: usage counts (frecency) and clipboard history.
//! `lumen --clip-store` writes from another process, so the database is in
//! WAL mode and every open sets a busy timeout. Not thread-safe: one Db per
//! thread (the UI uses it from the GTK main loop only).

const std = @import("std");
const c = @import("sqlite");
const frecency = @import("core").frecency;

const Db = @This();

const log = std.log.scoped(.db);

handle: *c.sqlite3,

/// Each failure is also logged with SQLite's message.
pub const Error = error{ DbOpen, DbExec, DbPrepare, DbStep };

pub fn open(path: [:0]const u8) Error!Db {
    var h: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &h) != c.SQLITE_OK) {
        if (h) |hh| {
            log.warn("open {s}: {s}", .{ path, c.sqlite3_errmsg(hh) });
            _ = c.sqlite3_close(hh);
        }
        return error.DbOpen;
    }
    var db: Db = .{ .handle = h.? };
    errdefer db.close();
    _ = c.sqlite3_busy_timeout(db.handle, 2000);
    try db.exec(
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\CREATE TABLE IF NOT EXISTS frecency (
        \\  key TEXT PRIMARY KEY,
        \\  count INTEGER NOT NULL,
        \\  last_used INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS clipboard (
        \\  id INTEGER PRIMARY KEY,
        \\  hash INTEGER NOT NULL UNIQUE,
        \\  content TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  last_copied INTEGER NOT NULL
        \\);
        \\DROP INDEX IF EXISTS clipboard_recent;
        \\CREATE INDEX IF NOT EXISTS clipboard_by_time ON clipboard(last_copied);
    );
    return db;
}

pub fn close(db: *Db) void {
    _ = c.sqlite3_close(db.handle);
    db.* = undefined;
}

pub fn exec(db: *Db, sql: [:0]const u8) Error!void {
    if (c.sqlite3_exec(db.handle, sql.ptr, null, null, null) != c.SQLITE_OK) {
        log.warn("exec: {s}", .{c.sqlite3_errmsg(db.handle)});
        return error.DbExec;
    }
}

fn prepare(db: *Db, sql: [:0]const u8) Error!*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
        log.warn("prepare: {s}", .{c.sqlite3_errmsg(db.handle)});
        return error.DbPrepare;
    }
    return stmt.?;
}

/// Runs a statement that returns no rows.
fn run(db: *Db, stmt: *c.sqlite3_stmt) Error!void {
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return db.stepFailed(rc);
}

/// The next row, or null once the statement is done (a failure is an
/// error, never a short result).
fn nextRow(db: *Db, stmt: *c.sqlite3_stmt) Error!bool {
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => |rc| db.stepFailed(rc),
    };
}

fn stepFailed(db: *Db, rc: c_int) Error {
    log.warn("step ({d}): {s}", .{ rc, c.sqlite3_errmsg(db.handle) });
    return error.DbStep;
}

// ---------------------------------------------------------------- frecency

pub fn recordUse(db: *Db, key: []const u8, now: i64) Error!void {
    const stmt = try db.prepare(
        \\INSERT INTO frecency (key, count, last_used) VALUES (?1, 1, ?2)
        \\ON CONFLICT(key) DO UPDATE SET count = count + 1, last_used = ?2
    );
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    _ = c.sqlite3_bind_int64(stmt, 2, now);
    try db.run(stmt);
}

pub fn forget(db: *Db, key: []const u8) Error!void {
    const stmt = try db.prepare("DELETE FROM frecency WHERE key = ?1");
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    try db.run(stmt);
}

/// Forgets what decayed below any effect on the ranking: every file opened
/// adds a key, and the table is read on every show.
pub fn pruneFrecency(db: *Db, now: i64) Error!void {
    const stmt = try db.prepare("SELECT key, count, last_used FROM frecency");
    defer _ = c.sqlite3_finalize(stmt);
    const del = try db.prepare("DELETE FROM frecency WHERE key = ?1");
    defer _ = c.sqlite3_finalize(del);
    var stale: std.ArrayList([]u8) = .empty;
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    while (try db.nextRow(stmt)) {
        const count = std.math.cast(
            u32,
            c.sqlite3_column_int64(stmt, 1),
        ) orelse std.math.maxInt(u32);
        if (frecency.value(count, c.sqlite3_column_int64(stmt, 2), now) >= 0.01) continue;
        stale.append(
            arena.allocator(),
            arena.allocator().dupe(u8, columnText(stmt, 0)) catch continue,
        ) catch continue;
    }
    for (stale.items) |key| {
        _ = c.sqlite3_reset(del);
        bindText(del, 1, key);
        try db.run(del);
    }
}

/// All usage, as key -> frecency value. Keys and the map live in `arena`.
pub fn loadFrecency(
    db: *Db,
    arena: std.mem.Allocator,
    now: i64,
) (Error || std.mem.Allocator.Error)!std.StringHashMapUnmanaged(f64) {
    var map: std.StringHashMapUnmanaged(f64) = .empty;
    const stmt = try db.prepare("SELECT key, count, last_used FROM frecency");
    defer _ = c.sqlite3_finalize(stmt);
    while (try db.nextRow(stmt)) {
        const key = try arena.dupe(u8, columnText(stmt, 0));
        // A count beyond u32 (a foreign or damaged file) saturates.
        const count = std.math.cast(
            u32,
            c.sqlite3_column_int64(stmt, 1),
        ) orelse std.math.maxInt(u32);
        const last = c.sqlite3_column_int64(stmt, 2);
        try map.put(arena, key, frecency.value(count, last, now));
    }
    return map;
}

// --------------------------------------------------------------- clipboard

pub const max_entries = 1000;
pub const max_bytes = 1 << 20;

/// Stores a copy and trims the history to the newest `keep` entries (the
/// Settings value). Empty, blank and oversized copies are ignored.
pub fn addClip(db: *Db, content: []const u8, now: i64, keep: u32) Error!void {
    if (content.len == 0 or content.len > max_bytes) return;
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return;
    const hash: i64 = @bitCast(std.hash.Wyhash.hash(0, content));
    const stmt = try db.prepare(
        \\INSERT INTO clipboard (hash, content, created_at, last_copied) VALUES (?1, ?2, ?3, ?3)
        \\ON CONFLICT(hash) DO UPDATE SET last_copied = ?3
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, hash);
    bindText(stmt, 2, content);
    _ = c.sqlite3_bind_int64(stmt, 3, now);
    try db.run(stmt);
    // What is past the newest `keep`, found through the index (scanned
    // backwards: newest first, ties by id); NOT IN read the whole table.
    const trim = try db.prepare(
        \\DELETE FROM clipboard WHERE id IN
        \\  (SELECT id FROM clipboard ORDER BY last_copied DESC, id DESC LIMIT -1 OFFSET ?1)
    );
    defer _ = c.sqlite3_finalize(trim);
    _ = c.sqlite3_bind_int64(trim, 1, @max(keep, 1));
    try db.run(trim);
}

pub const Clip = struct {
    id: i64,
    content: []const u8,
    created_at: i64,
    last_copied: i64,
};

/// Most recent first; the slice and strings live in `arena`.
pub fn recentClips(
    db: *Db,
    arena: std.mem.Allocator,
    limit: u32,
) (Error || std.mem.Allocator.Error)![]Clip {
    var list: std.ArrayList(Clip) = .empty;
    // Times have one-second resolution; the id breaks ties in copy order
    // (two copies within a second came back oldest first).
    const stmt = try db.prepare(
        "SELECT id, content, created_at, last_copied FROM clipboard ORDER BY last_copied DESC, id DESC LIMIT ?1",
    );
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, limit);
    while (try db.nextRow(stmt)) {
        try list.append(arena, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .content = try arena.dupe(u8, columnText(stmt, 1)),
            .created_at = c.sqlite3_column_int64(stmt, 2),
            .last_copied = c.sqlite3_column_int64(stmt, 3),
        });
    }
    return list.toOwnedSlice(arena);
}

pub fn touchClip(db: *Db, id: i64, now: i64) Error!void {
    const stmt = try db.prepare("UPDATE clipboard SET last_copied = ?2 WHERE id = ?1");
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    _ = c.sqlite3_bind_int64(stmt, 2, now);
    try db.run(stmt);
}

pub fn deleteClip(db: *Db, id: i64) Error!void {
    const stmt = try db.prepare("DELETE FROM clipboard WHERE id = ?1");
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    try db.run(stmt);
}

pub fn clearClips(db: *Db) Error!void {
    try db.exec("DELETE FROM clipboard");
}

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) void {
    // SQLITE_TRANSIENT: sqlite copies the bytes.
    const transient: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    _ = c.sqlite3_bind_text64(stmt, idx, text.ptr, text.len, transient, c.SQLITE_UTF8);
}

fn columnText(stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
    const p = c.sqlite3_column_text(stmt, col) orelse return "";
    // Never negative: sqlite3_column_bytes returns a size.
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return p[0..n];
}

test "clipboard dedupes and orders by recency" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.addClip("one", 1, Db.max_entries);
    try db.addClip("two", 2, Db.max_entries);
    try db.addClip("one", 3, Db.max_entries);
    try db.addClip("   ", 4, Db.max_entries);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 2), clips.len);
    try std.testing.expectEqualStrings("one", clips[0].content);
}

test "copies within the same second keep their order" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.addClip("first", 50, Db.max_entries);
    try db.addClip("second", 50, Db.max_entries);
    try db.addClip("third", 50, Db.max_entries);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqualStrings("third", clips[0].content);
    try std.testing.expectEqualStrings("first", clips[2].content);
}

test "the history keeps as many entries as the setting says" {
    var db = try Db.open(":memory:");
    defer db.close();
    for (0..8) |i| {
        var buf: [16]u8 = undefined;
        try db.addClip(try std.mem.print(&buf, "clip {d}", .{i}), @intCast(i), 5);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 100);
    try std.testing.expectEqual(@as(usize, 5), clips.len);
    try std.testing.expectEqualStrings("clip 7", clips[0].content);
    try std.testing.expectEqualStrings("clip 3", clips[4].content);
}

test "frecency accumulates" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.recordUse("app:a", 100);
    try db.recordUse("app:a", 100);
    try db.recordUse("app:b", 100);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var map = try db.loadFrecency(arena.allocator(), 100);
    try std.testing.expect(map.get("app:a").? > map.get("app:b").?);
    _ = &map;
}

test "frecency forgets what decayed to nothing, keeps the rest" {
    var db = try Db.open(":memory:");
    defer db.close();
    const day = 86_400;
    const now: i64 = 1000 * day;
    try db.recordUse("file:/old", now - 100 * day);
    try db.recordUse("app:recent", now - 2 * day);
    for (0..50) |_| try db.recordUse("app:much-used", now - 40 * day);
    try db.pruneFrecency(now);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const map = try db.loadFrecency(arena.allocator(), now);
    try std.testing.expect(map.get("file:/old") == null);
    try std.testing.expect(map.get("app:recent") != null);
    // 50 uses 40 days ago still weigh 0.96.
    try std.testing.expect(map.get("app:much-used") != null);
}

test "a failed write is an error, not silence" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec(
        "CREATE TRIGGER no_delete BEFORE DELETE ON clipboard BEGIN SELECT RAISE(ABORT, 'locked'); END;",
    );
    try db.addClip("secret", 1, Db.max_entries);
    try std.testing.expectError(error.DbStep, db.deleteClip(1));
    try std.testing.expectError(error.DbExec, db.clearClips());
}
