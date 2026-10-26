//! SQLite store: usage counts (frecency) and clipboard history.
//! `lumen --clip-store` writes from another process, so the database is in
//! WAL mode and every open sets a busy timeout.

const std = @import("std");
const c = @import("sqlite");
const frecency = @import("core").frecency;

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var h: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &h) != c.SQLITE_OK) {
            if (h) |hh| _ = c.sqlite3_close(hh);
            return error.DbOpen;
        }
        var db: Db = .{ .handle = h.? };
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
            \\CREATE INDEX IF NOT EXISTS clipboard_recent ON clipboard(last_copied DESC);
        );
        return db;
    }

    pub fn close(db: *Db) void {
        _ = c.sqlite3_close(db.handle);
    }

    pub fn exec(db: *Db, sql: [:0]const u8) !void {
        if (c.sqlite3_exec(db.handle, sql.ptr, null, null, null) != c.SQLITE_OK) {
            std.log.err("sqlite: {s}", .{c.sqlite3_errmsg(db.handle)});
            return error.DbExec;
        }
    }

    fn prepare(db: *Db, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            std.log.err("sqlite prepare: {s}", .{c.sqlite3_errmsg(db.handle)});
            return error.DbPrepare;
        }
        return stmt.?;
    }

    // ------------------------------------------------------------ frecency

    pub fn recordUse(db: *Db, key: []const u8, now: i64) void {
        const stmt = db.prepare(
            \\INSERT INTO frecency (key, count, last_used) VALUES (?1, 1, ?2)
            \\ON CONFLICT(key) DO UPDATE SET count = count + 1, last_used = ?2
        ) catch return;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key);
        _ = c.sqlite3_bind_int64(stmt, 2, now);
        _ = c.sqlite3_step(stmt);
    }

    pub fn forget(db: *Db, key: []const u8) void {
        const stmt = db.prepare("DELETE FROM frecency WHERE key = ?1") catch return;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, key);
        _ = c.sqlite3_step(stmt);
    }

    /// All usage, as key -> frecency value. Keys are owned by `gpa`.
    pub fn loadFrecency(db: *Db, gpa: std.mem.Allocator, now: i64) !std.StringHashMapUnmanaged(f64) {
        var map: std.StringHashMapUnmanaged(f64) = .empty;
        const stmt = try db.prepare("SELECT key, count, last_used FROM frecency");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const key = try gpa.dupe(u8, columnText(stmt, 0));
            const count: u32 = @intCast(c.sqlite3_column_int64(stmt, 1));
            const last = c.sqlite3_column_int64(stmt, 2);
            try map.put(gpa, key, frecency.value(count, last, now));
        }
        return map;
    }

    // ----------------------------------------------------------- clipboard

    pub const max_entries = 1000;
    pub const max_bytes = 1 << 20;

    /// Stores a copy and trims the history to the newest `keep` entries
    /// (the Settings value).
    pub fn addClip(db: *Db, content: []const u8, now: i64, keep: u32) void {
        if (content.len == 0 or content.len > max_bytes) return;
        if (std.mem.trim(u8, content, " \t\r\n").len == 0) return;
        const hash: i64 = @bitCast(std.hash.Wyhash.hash(0, content));
        const stmt = db.prepare(
            \\INSERT INTO clipboard (hash, content, created_at, last_copied) VALUES (?1, ?2, ?3, ?3)
            \\ON CONFLICT(hash) DO UPDATE SET last_copied = ?3
        ) catch return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, hash);
        bindText(stmt, 2, content);
        _ = c.sqlite3_bind_int64(stmt, 3, now);
        _ = c.sqlite3_step(stmt);
        const trim = db.prepare(
            \\DELETE FROM clipboard WHERE id NOT IN
            \\  (SELECT id FROM clipboard ORDER BY last_copied DESC, id DESC LIMIT ?1)
        ) catch return;
        defer _ = c.sqlite3_finalize(trim);
        _ = c.sqlite3_bind_int64(trim, 1, @max(keep, 1));
        _ = c.sqlite3_step(trim);
    }

    pub const Clip = struct {
        id: i64,
        content: []const u8,
        created_at: i64,
        last_copied: i64,
    };

    /// Most recent first; strings are owned by `arena`.
    pub fn recentClips(db: *Db, arena: std.mem.Allocator, limit: u32) ![]Clip {
        var list: std.ArrayList(Clip) = .empty;
        // Times have one-second resolution; the id breaks ties in copy order
        // (two copies within a second came back oldest first).
        const stmt = try db.prepare("SELECT id, content, created_at, last_copied FROM clipboard ORDER BY last_copied DESC, id DESC LIMIT ?1");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(arena, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .content = try arena.dupe(u8, columnText(stmt, 1)),
                .created_at = c.sqlite3_column_int64(stmt, 2),
                .last_copied = c.sqlite3_column_int64(stmt, 3),
            });
        }
        return list.toOwnedSlice(arena);
    }

    pub fn touchClip(db: *Db, id: i64, now: i64) void {
        const stmt = db.prepare("UPDATE clipboard SET last_copied = ?2 WHERE id = ?1") catch return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, id);
        _ = c.sqlite3_bind_int64(stmt, 2, now);
        _ = c.sqlite3_step(stmt);
    }

    pub fn deleteClip(db: *Db, id: i64) void {
        const stmt = db.prepare("DELETE FROM clipboard WHERE id = ?1") catch return;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, id);
        _ = c.sqlite3_step(stmt);
    }

    pub fn clearClips(db: *Db) void {
        db.exec("DELETE FROM clipboard") catch {};
    }
};

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) void {
    // SQLITE_TRANSIENT: sqlite copies the bytes.
    const transient: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    _ = c.sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), transient);
}

fn columnText(stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
    const p = c.sqlite3_column_text(stmt, col) orelse return "";
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return p[0..n];
}

test "clipboard dedupes and orders by recency" {
    var db = try Db.open(":memory:");
    defer db.close();
    db.addClip("one", 1, Db.max_entries);
    db.addClip("two", 2, Db.max_entries);
    db.addClip("one", 3, Db.max_entries);
    db.addClip("   ", 4, Db.max_entries);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 2), clips.len);
    try std.testing.expectEqualStrings("one", clips[0].content);
}

test "copies within the same second keep their order" {
    var db = try Db.open(":memory:");
    defer db.close();
    db.addClip("first", 50, Db.max_entries);
    db.addClip("second", 50, Db.max_entries);
    db.addClip("third", 50, Db.max_entries);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
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
        db.addClip(try std.fmt.bufPrint(&buf, "clip {d}", .{i}), @intCast(i), 5);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 100);
    try std.testing.expectEqual(@as(usize, 5), clips.len);
    try std.testing.expectEqualStrings("clip 7", clips[0].content);
    try std.testing.expectEqualStrings("clip 3", clips[4].content);
}

test "frecency accumulates" {
    var db = try Db.open(":memory:");
    defer db.close();
    db.recordUse("app:a", 100);
    db.recordUse("app:a", 100);
    db.recordUse("app:b", 100);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = try db.loadFrecency(arena.allocator(), 100);
    try std.testing.expect(map.get("app:a").? > map.get("app:b").?);
    _ = &map;
}
