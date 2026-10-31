//! SQLite store: usage counts (frecency) and clipboard history.
//! `lumen --clip-store` writes from another process, so the database is in
//! WAL mode and every open sets a busy timeout. Not thread-safe: one Db per
//! thread (the UI uses it from the GTK main loop only).

const std = @import("std");
const assert = std.debug.assert;
const c = @import("sqlite");
const frecency = @import("core").frecency;

const Db = @This();

const log = std.log.scoped(.db);

handle: *c.sqlite3,

/// Each failure is also logged with SQLite's message.
pub const Error = error{ DbOpen, DbExec, DbPrepare, DbBind, DbStep };

/// How long a write waits for another process's (`lumen --clip-store`)
/// before it fails with SQLITE_BUSY.
const busy_timeout_ms = 2000;

/// SQLite's name for a database that lives in memory only (the tests').
/// It has no file to make private.
pub const in_memory = ":memory:";

pub fn open(path: [:0]const u8) Error!Db {
    if (!std.mem.eql(u8, path, in_memory)) makePrivate(path);
    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &handle) != c.SQLITE_OK) {
        // SQLite gives a handle even when opening fails, but not when it
        // runs out of memory first.
        if (handle) |failed_handle| {
            log.warn("open {s}: {s}", .{ path, c.sqlite3_errmsg(failed_handle) });
            _ = c.sqlite3_close(failed_handle);
        }
        return error.DbOpen;
    }
    var db: Db = .{ .handle = handle.? };
    errdefer db.close();
    if (c.sqlite3_busy_timeout(db.handle, busy_timeout_ms) != c.SQLITE_OK) {
        log.warn("busy timeout: {s}", .{c.sqlite3_errmsg(db.handle)});
        return error.DbOpen;
    }
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

/// The history holds whatever was copied, passwords too, and SQLite creates
/// its files with the umask's mode (0644 here). The database is created
/// owner-only before SQLite opens it, or made so if it exists; SQLite gives
/// the -wal and -shm it creates the database's mode, and ones left by
/// earlier versions are fixed too.
fn makePrivate(path: [:0]const u8) void {
    const linux = std.os.linux;
    const rc = linux.open(
        path,
        .{ .ACCMODE = .RDONLY, .CREAT = true, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true },
        0o600,
    );
    if (linux.errno(rc) == .SUCCESS) {
        const fd: i32 = @intCast(rc);
        _ = linux.fchmod(fd, 0o600);
        _ = linux.close(fd);
    }
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        var buf: [4096]u8 = undefined;
        const side = std.mem.printSentinel(&buf, "{s}{s}", .{ path, suffix }, 0) catch continue;
        _ = linux.chmod(side, 0o600);
    }
}

pub fn close(db: *Db) void {
    // SQLITE_BUSY here means a statement was left unfinalized: a bug, not
    // an operating error.
    assert(c.sqlite3_close(db.handle) == c.SQLITE_OK);
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

/// Binds `args` to ?1, ?2... in order: integers as int64, byte slices as
/// text. A bind that fails would run the statement with NULL instead.
fn bind(db: *Db, stmt: *c.sqlite3_stmt, args: anytype) Error!void {
    comptime assert(args.len > 0);
    // As many arguments as the SQL has parameters: one left out would be
    // bound as NULL without a word.
    assert(c.sqlite3_bind_parameter_count(stmt) == args.len);
    inline for (args, 0..) |arg, arg_index| {
        const parameter: c_int = arg_index + 1;
        const rc = switch (@typeInfo(@TypeOf(arg))) {
            .int, .comptime_int => c.sqlite3_bind_int64(stmt, parameter, arg),
            else => bindText(stmt, parameter, arg),
        };
        if (rc != c.SQLITE_OK) {
            log.warn("bind ?{d}: {s}", .{ parameter, c.sqlite3_errmsg(db.handle) });
            return error.DbBind;
        }
    }
}

/// Prepares `sql`, binds `args` and runs it (no rows).
fn execArgs(db: *Db, sql: [:0]const u8, args: anytype) Error!void {
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    try db.bind(stmt, args);
    try db.run(stmt);
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
    try db.execArgs(
        \\INSERT INTO frecency (key, count, last_used) VALUES (?1, 1, ?2)
        \\ON CONFLICT(key) DO UPDATE SET count = count + 1, last_used = ?2
    , .{ key, now });
}

pub fn forget(db: *Db, key: []const u8) Error!void {
    try db.execArgs("DELETE FROM frecency WHERE key = ?1", .{key});
}

/// A frecency below this no longer moves anything in the ranking.
const frecency_negligible = 0.01;

/// Forgets what decayed below any effect on the ranking: every file opened
/// adds a key, and the table is read on every show.
pub fn pruneFrecency(db: *Db, now: i64) Error!void {
    const select_stmt = try db.prepare("SELECT key, count, last_used FROM frecency");
    defer _ = c.sqlite3_finalize(select_stmt);
    const delete_stmt = try db.prepare("DELETE FROM frecency WHERE key = ?1");
    defer _ = c.sqlite3_finalize(delete_stmt);
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stale: std.ArrayList([]u8) = .empty;
    while (try db.nextRow(select_stmt)) {
        const count = columnCount(select_stmt, 1);
        const last_used = c.sqlite3_column_int64(select_stmt, 2);
        if (frecency.value(count, last_used, now) >= frecency_negligible) continue;
        // Out of memory, a key is kept until the next prune: harmless.
        const key = arena.dupe(u8, columnText(select_stmt, 0)) catch continue;
        stale.append(arena, key) catch continue;
    }
    for (stale.items) |key| {
        // reset only repeats the result of the last step, checked by run.
        _ = c.sqlite3_reset(delete_stmt);
        try db.bind(delete_stmt, .{key});
        try db.run(delete_stmt);
    }
}

/// A use count read from the database. A count beyond u32 (a foreign or
/// damaged file) saturates.
fn columnCount(stmt: *c.sqlite3_stmt, column: c_int) u32 {
    const count = c.sqlite3_column_int64(stmt, column);
    return std.math.cast(u32, count) orelse std.math.maxInt(u32);
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
        const count = columnCount(stmt, 1);
        const last_used = c.sqlite3_column_int64(stmt, 2);
        try map.put(arena, key, frecency.value(count, last_used, now));
    }
    return map;
}

// --------------------------------------------------------------- clipboard

/// The most entries the history can be set to keep.
pub const clip_entries_max = 1000;
/// A copy larger than this is not kept.
pub const clip_bytes_max = 1 << 20;

/// Stores a copy and trims the history to the newest `keep` entries (the
/// Settings value). Empty, blank and oversized copies are ignored.
pub fn addClip(db: *Db, content: []const u8, now: i64, keep: u32) Error!void {
    if (content.len == 0) return;
    if (content.len > clip_bytes_max) return;
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return;
    const hash: i64 = @bitCast(std.hash.Wyhash.hash(0, content));
    try db.execArgs(
        \\INSERT INTO clipboard (hash, content, created_at, last_copied) VALUES (?1, ?2, ?3, ?3)
        \\ON CONFLICT(hash) DO UPDATE SET last_copied = ?3
    , .{ hash, content, now });
    // What is past the newest `keep`, found through the index (scanned
    // backwards: newest first, ties by id); NOT IN read the whole table.
    try db.execArgs(
        \\DELETE FROM clipboard WHERE id IN
        \\  (SELECT id FROM clipboard ORDER BY last_copied DESC, id DESC LIMIT -1 OFFSET ?1)
    , .{@max(keep, 1)});
}

pub const Clip = struct {
    id: i64,
    /// The first `head_chars` characters; `clipContent` has all of it.
    head: []const u8,
    created_at: i64,
    last_copied: i64,
};

/// Characters of each entry `recentClips` loads: what a row shows and
/// searches. The list loaded every entry whole, up to 500 of up to 1 MiB.
pub const head_chars = 2000;

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
        \\SELECT id, substr(content, 1, ?2), created_at, last_copied FROM clipboard
        \\ORDER BY last_copied DESC, id DESC LIMIT ?1
    );
    defer _ = c.sqlite3_finalize(stmt);
    try db.bind(stmt, .{ limit, head_chars });
    while (try db.nextRow(stmt)) {
        try list.append(arena, .{
            .id = c.sqlite3_column_int64(stmt, 0),
            .head = try arena.dupe(u8, columnText(stmt, 1)),
            .created_at = c.sqlite3_column_int64(stmt, 2),
            .last_copied = c.sqlite3_column_int64(stmt, 3),
        });
    }
    return list.toOwnedSlice(arena);
}

/// All of entry `id`, in `arena`; null when it is gone.
pub fn clipContent(
    db: *Db,
    arena: std.mem.Allocator,
    id: i64,
) (Error || std.mem.Allocator.Error)!?[]const u8 {
    const stmt = try db.prepare("SELECT content FROM clipboard WHERE id = ?1");
    defer _ = c.sqlite3_finalize(stmt);
    try db.bind(stmt, .{id});
    if (!try db.nextRow(stmt)) return null;
    return try arena.dupe(u8, columnText(stmt, 0));
}

pub fn touchClip(db: *Db, id: i64, now: i64) Error!void {
    try db.execArgs("UPDATE clipboard SET last_copied = ?2 WHERE id = ?1", .{ id, now });
}

pub fn deleteClip(db: *Db, id: i64) Error!void {
    try db.execArgs("DELETE FROM clipboard WHERE id = ?1", .{id});
}

pub fn clearClips(db: *Db) Error!void {
    try db.exec("DELETE FROM clipboard");
}

fn bindText(stmt: *c.sqlite3_stmt, parameter: c_int, text: []const u8) c_int {
    // SQLITE_TRANSIENT: sqlite copies the bytes.
    const transient: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    return c.sqlite3_bind_text64(stmt, parameter, text.ptr, text.len, transient, c.SQLITE_UTF8);
}

fn columnText(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const text = c.sqlite3_column_text(stmt, column) orelse return "";
    const text_len = c.sqlite3_column_bytes(stmt, column);
    assert(text_len >= 0);
    return text[0..@intCast(text_len)];
}

test "clipboard dedupes and orders by recency" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    try db.addClip("one", 1, Db.clip_entries_max);
    try db.addClip("two", 2, Db.clip_entries_max);
    try db.addClip("one", 3, Db.clip_entries_max);
    try db.addClip("   ", 4, Db.clip_entries_max);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 2), clips.len);
    try std.testing.expectEqualStrings("one", clips[0].head);
}

test "copies within the same second keep their order" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    try db.addClip("first", 50, Db.clip_entries_max);
    try db.addClip("second", 50, Db.clip_entries_max);
    try db.addClip("third", 50, Db.clip_entries_max);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqualStrings("third", clips[0].head);
    try std.testing.expectEqualStrings("first", clips[2].head);
}

test "the history keeps as many entries as the setting says" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    for (0..8) |i| {
        var buf: [16]u8 = undefined;
        try db.addClip(try std.mem.print(&buf, "clip {d}", .{i}), @intCast(i), 5);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 100);
    try std.testing.expectEqual(@as(usize, 5), clips.len);
    try std.testing.expectEqualStrings("clip 7", clips[0].head);
    try std.testing.expectEqualStrings("clip 3", clips[4].head);
}

test "the list loads each entry's head, the entry is read whole by id" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Two bytes a character: the head is cut by characters, never mid-one.
    const long = try allocator.alloc(u8, 2 * (head_chars + 500));
    for (0..head_chars + 500) |i| @memcpy(long[2 * i ..][0..2], "é");
    try db.addClip(long, 1, Db.clip_entries_max);
    const clips = try db.recentClips(allocator, 10);
    try std.testing.expectEqual(2 * head_chars, clips[0].head.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clips[0].head));
    try std.testing.expectEqualStrings(long, (try db.clipContent(allocator, clips[0].id)).?);
    try db.deleteClip(clips[0].id);
    try std.testing.expect(try db.clipContent(allocator, clips[0].id) == null);
}

test "the database and its -wal and -shm are owner-only" {
    const linux = std.os.linux;
    var dir: @import("os").TestDir = try .init();
    defer dir.deinit();
    var buf: [4096]u8 = undefined;
    // Made world-readable, as earlier versions left it.
    try dir.write("lumen.db", "");
    _ = linux.chmod(try dir.path(&buf, "lumen.db"), 0o644);
    var db = try Db.open(try dir.path(&buf, "lumen.db"));
    defer db.close();
    try db.addClip("a password", 1, Db.clip_entries_max);
    for ([_][]const u8{ "lumen.db", "lumen.db-wal", "lumen.db-shm" }) |name| {
        var stx: linux.Statx = undefined;
        const path = try dir.path(&buf, name);
        const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &stx);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        try std.testing.expectEqual(@as(u16, 0o600), stx.mode & 0o777);
    }
}

test "frecency accumulates" {
    var db = try Db.open(Db.in_memory);
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
    var db = try Db.open(Db.in_memory);
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
    var db = try Db.open(Db.in_memory);
    defer db.close();
    try db.exec(
        "CREATE TRIGGER no_delete BEFORE DELETE ON clipboard BEGIN SELECT RAISE(ABORT, 'locked'); END;",
    );
    try db.addClip("secret", 1, Db.clip_entries_max);
    try std.testing.expectError(error.DbStep, db.deleteClip(1));
    try std.testing.expectError(error.DbExec, db.clearClips());
}
