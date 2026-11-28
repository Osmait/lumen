//! SQLite store: usage counts (frecency) and clipboard history.
//! `lumen --clip-store` writes from another process, so the database is in
//! WAL mode and every open sets a busy timeout. Not thread-safe: one Db per
//! thread (the UI uses it from the GTK main loop only).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = @import("sqlite");
const frecency = @import("core").frecency;
const os = @import("os");

const Db = @This();

const log = std.log.scoped(.db);

handle: *c.sqlite3,

/// Each failure is also logged with SQLite's message.
pub const Error = error{ DbOpen, DbExec, DbPrepare, DbBind, DbStep };

/// How long a write waits for another process's (`lumen --clip-store`)
/// before it fails with SQLITE_BUSY.
const busy_timeout_ms = 2000;

pub const OpenOptions = struct {
    busy_timeout_ms: c_int = busy_timeout_ms,
};

/// SQLite's name for a database that lives in memory only (the tests').
/// It has no file to make private.
pub const in_memory = ":memory:";

pub fn open(path: [:0]const u8) Error!Db {
    return openWith(path, .{});
}

pub fn openWith(path: [:0]const u8, options: OpenOptions) Error!Db {
    if (!std.mem.eql(u8, path, in_memory)) try makePrivate(path);
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
    if (c.sqlite3_busy_timeout(db.handle, options.busy_timeout_ms) != c.SQLITE_OK) {
        log.warn("busy timeout: {s}", .{c.sqlite3_errmsg(db.handle)});
        return error.DbOpen;
    }
    try db.exec(
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\CREATE TABLE IF NOT EXISTS frecency (
        \\  key TEXT PRIMARY KEY,
        \\  score REAL NOT NULL,
        \\  last_used INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS clipboard (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  hash INTEGER NOT NULL,
        \\  content TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  last_copied INTEGER NOT NULL,
        \\  seq INTEGER NOT NULL DEFAULT 0,
        \\  UNIQUE(hash, content)
        \\);
    );
    try db.migrateFrecency();
    try db.migrateClipboard();
    try db.exec(
        \\DROP INDEX IF EXISTS clipboard_recent;
        \\DROP INDEX IF EXISTS clipboard_by_time;
        \\CREATE INDEX IF NOT EXISTS clipboard_by_recency ON clipboard(last_copied DESC, seq DESC);
    );
    return db;
}

fn hasColumn(db: *Db, table: [:0]const u8, column: []const u8) Error!bool {
    var sql_buf: [128]u8 = undefined;
    const sql = std.mem.printSentinel(&sql_buf, "PRAGMA table_info({s})", .{table}, 0) catch
        unreachable;
    const stmt = try db.prepare(sql);
    defer _ = c.sqlite3_finalize(stmt);
    while (try db.nextRow(stmt)) {
        if (std.mem.eql(u8, columnText(stmt, 1), column)) return true;
    }
    return false;
}

fn clipboardSchemaSql(db: *Db, arena: std.mem.Allocator) Error!?[]const u8 {
    const stmt = try db.prepare(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'clipboard'",
    );
    defer _ = c.sqlite3_finalize(stmt);
    if (!try db.nextRow(stmt)) return null;
    return arena.dupe(u8, columnText(stmt, 0)) catch return null;
}

fn clipboardHasModernSchema(db: *Db) Error!bool {
    var buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const sql = try db.clipboardSchemaSql(fba.allocator()) orelse return false;
    return std.ascii.findIgnoreCase(sql, "autoincrement") != null and
        std.ascii.findIgnoreCase(sql, "unique(hash, content)") != null;
}

/// Migrates legacy `frecency(key, count, last_used)` to `score REAL`.
fn migrateFrecency(db: *Db) Error!void {
    if (try db.hasColumn("frecency", "score")) return;
    try db.exec("BEGIN IMMEDIATE");
    errdefer _ = c.sqlite3_exec(db.handle, "ROLLBACK", null, null, null);
    if (!try db.hasColumn("frecency", "score")) {
        try db.exec(
            \\CREATE TABLE frecency_new (
            \\  key TEXT PRIMARY KEY,
            \\  score REAL NOT NULL,
            \\  last_used INTEGER NOT NULL
            \\);
            \\INSERT INTO frecency_new (key, score, last_used)
            \\  SELECT key, CAST(MAX(count, 0) AS REAL), last_used FROM frecency;
            \\DROP TABLE frecency;
            \\ALTER TABLE frecency_new RENAME TO frecency;
        );
    }
    try db.exec("COMMIT");
}

/// Migrates legacy `clipboard` tables without `AUTOINCREMENT`, `seq`, or
/// `UNIQUE(hash, content)`, preserving existing ids, contents, and order.
fn migrateClipboard(db: *Db) Error!void {
    const has_modern = try db.clipboardHasModernSchema();
    const has_seq = try db.hasColumn("clipboard", "seq");
    if (has_modern and has_seq) return;
    try db.exec("BEGIN IMMEDIATE");
    errdefer _ = c.sqlite3_exec(db.handle, "ROLLBACK", null, null, null);
    const now_modern = try db.clipboardHasModernSchema();
    const now_seq = try db.hasColumn("clipboard", "seq");
    if (!now_modern or !now_seq) {
        try db.exec(
            \\CREATE TABLE clipboard_new (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  hash INTEGER NOT NULL,
            \\  content TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  last_copied INTEGER NOT NULL,
            \\  seq INTEGER NOT NULL DEFAULT 0,
            \\  UNIQUE(hash, content)
            \\);
        );
        if (now_seq) {
            try db.exec(
                \\INSERT INTO clipboard_new (id, hash, content, created_at, last_copied, seq)
                \\  SELECT id, hash, content, created_at, last_copied, seq FROM clipboard;
            );
        } else {
            try db.exec(
                \\INSERT INTO clipboard_new (id, hash, content, created_at, last_copied, seq)
                \\  SELECT id, hash, content, created_at, last_copied,
                \\    ROW_NUMBER() OVER (ORDER BY last_copied ASC, id ASC)
                \\  FROM clipboard;
            );
        }
        try db.exec(
            \\DROP TABLE clipboard;
            \\ALTER TABLE clipboard_new RENAME TO clipboard;
        );
    }
    try db.exec("COMMIT");
}

/// The history holds whatever was copied, passwords too, and SQLite creates
/// its files with the umask's mode (0644 here). The database is created
/// owner-only before SQLite opens it, or made so if it exists; SQLite gives
/// the -wal and -shm it creates the database's mode, and ones left by
/// earlier versions are fixed too. A file that cannot be made owner-only
/// fails the open: copies would go on landing where others can read them.
fn makePrivate(path: [:0]const u8) Error!void {
    try makeRegularFilePrivate(path, true);
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        var side_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const side_path = std.mem.printSentinel(
            &side_path_buffer,
            "{s}{s}",
            .{ path, suffix },
            0,
        ) catch {
            log.warn("{s}{s}: path exceeds PATH_MAX", .{ path, suffix });
            return error.DbOpen;
        };
        try makeRegularFilePrivate(side_path, false);
    }
}

fn makeRegularFilePrivate(path: [:0]const u8, create: bool) Error!void {
    os.ensurePrivateFile(path, create) catch |err| {
        log.warn("makePrivate {s}: {t}", .{ path, err });
        return error.DbOpen;
    };
}

pub fn close(db: *Db) void {
    const rc = c.sqlite3_close_v2(db.handle);
    if (rc != c.SQLITE_OK) {
        log.warn("close: {s}", .{c.sqlite3_errmsg(db.handle)});
        if (builtin.is_test) assert(false);
    }
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
        const bind_result = switch (@typeInfo(@TypeOf(arg))) {
            .int, .comptime_int => c.sqlite3_bind_int64(stmt, parameter, arg),
            .float, .comptime_float => c.sqlite3_bind_double(stmt, parameter, arg),
            else => bindText(stmt, parameter, arg),
        };
        if (bind_result != c.SQLITE_OK) {
            log.warn("bind ?{d}: {s}", .{ parameter, c.sqlite3_errmsg(db.handle) });
            return error.DbBind;
        }
    }
}

fn bindText(stmt: *c.sqlite3_stmt, parameter: c_int, text: []const u8) c_int {
    // SQLITE_TRANSIENT: sqlite copies the bytes.
    const transient: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    return c.sqlite3_bind_text64(stmt, parameter, text.ptr, text.len, transient, c.SQLITE_UTF8);
}

/// Column `column` of the current row as text; it lives until the next
/// step or finalize.
fn columnText(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const text = c.sqlite3_column_text(stmt, column) orelse return "";
    const text_len = c.sqlite3_column_bytes(stmt, column);
    assert(text_len >= 0);
    return text[0..@intCast(text_len)];
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
    const step_result = c.sqlite3_step(stmt);
    if (step_result != c.SQLITE_DONE) return db.stepFailed(step_result);
}

/// Steps to the next row: false once the statement is done (a failure is
/// an error, never a short result).
fn nextRow(db: *Db, stmt: *c.sqlite3_stmt) Error!bool {
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => |step_result| db.stepFailed(step_result),
    };
}

fn stepFailed(db: *Db, step_result: c_int) Error {
    log.warn("step ({d}): {s}", .{ step_result, c.sqlite3_errmsg(db.handle) });
    return error.DbStep;
}

// ---------------------------------------------------------------- frecency

pub fn recordUse(db: *Db, key: []const u8, now: i64) Error!void {
    // An item without a key has no ranking; Ui.perform skips those.
    assert(key.len > 0);
    try db.exec("BEGIN IMMEDIATE");
    errdefer _ = c.sqlite3_exec(db.handle, "ROLLBACK", null, null, null);

    const select_stmt = try db.prepare(
        "SELECT score, last_used FROM frecency WHERE key = ?1",
    );
    defer _ = c.sqlite3_finalize(select_stmt);
    try db.bind(select_stmt, .{key});
    if (try db.nextRow(select_stmt)) {
        const prev_score = columnScore(select_stmt, 0);
        const prev_last = c.sqlite3_column_int64(select_stmt, 1);
        const next_score = frecency.addUse(prev_score, prev_last, now);
        const next_last = @max(now, prev_last);
        _ = c.sqlite3_reset(select_stmt);
        try db.execArgs(
            "UPDATE frecency SET score = ?2, last_used = ?3 WHERE key = ?1",
            .{ key, next_score, next_last },
        );
    } else {
        _ = c.sqlite3_reset(select_stmt);
        try db.execArgs(
            "INSERT INTO frecency (key, score, last_used) VALUES (?1, 1.0, ?2)",
            .{ key, now },
        );
    }
    try db.exec("COMMIT");
}

pub fn forget(db: *Db, key: []const u8) Error!void {
    try db.execArgs("DELETE FROM frecency WHERE key = ?1", .{key});
}

/// A frecency below this no longer moves anything in the ranking.
const frecency_negligible = 0.01;

/// Forgets what decayed below any effect on the ranking: every file opened
/// adds a key, and the table is read on every show.
pub fn pruneFrecency(db: *Db, gpa: std.mem.Allocator, now: i64) Error!void {
    const select_stmt = try db.prepare("SELECT key, score, last_used FROM frecency");
    defer _ = c.sqlite3_finalize(select_stmt);
    const delete_stmt = try db.prepare("DELETE FROM frecency WHERE key = ?1");
    defer _ = c.sqlite3_finalize(delete_stmt);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stale: std.ArrayList([]u8) = .empty;
    while (try db.nextRow(select_stmt)) {
        const score = columnScore(select_stmt, 1);
        const last_used = c.sqlite3_column_int64(select_stmt, 2);
        if (frecency.value(score, last_used, now) >= frecency_negligible) continue;
        // Out of memory, a key is kept until the next prune: harmless.
        const key = arena.dupe(u8, columnText(select_stmt, 0)) catch continue;
        stale.append(arena, key) catch continue;
    }
    if (stale.items.len == 0) return;
    _ = c.sqlite3_reset(select_stmt);
    try db.exec("BEGIN IMMEDIATE");
    errdefer _ = c.sqlite3_exec(db.handle, "ROLLBACK", null, null, null);
    for (stale.items) |key| {
        // reset only repeats the result of the last step, checked by run.
        _ = c.sqlite3_reset(delete_stmt);
        try db.bind(delete_stmt, .{key});
        try db.run(delete_stmt);
    }
    try db.exec("COMMIT");
}

/// A score read from the database. Negative or non-finite values become 0.
fn columnScore(stmt: *c.sqlite3_stmt, column: c_int) f64 {
    const score = c.sqlite3_column_double(stmt, column);
    if (!(score > 0) or !std.math.isFinite(score)) return 0;
    return score;
}

/// All usage, as key -> frecency value. Keys and the map live in `arena`.
pub fn loadFrecency(
    db: *Db,
    arena: std.mem.Allocator,
    now: i64,
) (Error || std.mem.Allocator.Error)!std.StringHashMapUnmanaged(f64) {
    var map: std.StringHashMapUnmanaged(f64) = .empty;
    const stmt = try db.prepare("SELECT key, score, last_used FROM frecency");
    defer _ = c.sqlite3_finalize(stmt);
    while (try db.nextRow(stmt)) {
        const key = try arena.dupe(u8, columnText(stmt, 0));
        const score = columnScore(stmt, 1);
        const last_used = c.sqlite3_column_int64(stmt, 2);
        try map.put(arena, key, frecency.value(score, last_used, now));
    }
    return map;
}

// --------------------------------------------------------------- clipboard

/// The most entries the history can be set to keep.
pub const clip_entries_max = 5000;
/// A copy larger than this is not kept.
pub const clip_bytes_max = 1 << 20;

fn nextClipSeq(db: *Db) Error!i64 {
    const stmt = try db.prepare("SELECT COALESCE(MAX(seq), 0) + 1 FROM clipboard");
    defer _ = c.sqlite3_finalize(stmt);
    assert(try db.nextRow(stmt));
    return c.sqlite3_column_int64(stmt, 0);
}

/// Stores a copy and trims the history to the newest `keep` entries (the
/// Settings value). Empty, blank and oversized copies are ignored.
pub fn addClip(db: *Db, content: []const u8, now: i64, keep: u32) Error!void {
    if (content.len == 0) return;
    if (content.len > clip_bytes_max) return;
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) return;
    const hash: i64 = @bitCast(std.hash.Wyhash.hash(0, content));
    try db.exec("BEGIN IMMEDIATE");
    errdefer _ = c.sqlite3_exec(db.handle, "ROLLBACK", null, null, null);
    const seq = try db.nextClipSeq();
    try db.execArgs(
        \\INSERT INTO clipboard (hash, content, created_at, last_copied, seq)
        \\VALUES (?1, ?2, ?3, ?3, ?4)
        \\ON CONFLICT(hash, content) DO UPDATE SET last_copied = ?3, seq = ?4
    , .{ hash, content, now, seq });
    // What is past the newest `keep`, found through the recency index
    // (last_copied DESC, seq DESC).
    try db.execArgs(
        \\DELETE FROM clipboard WHERE id IN
        \\  (SELECT id FROM clipboard ORDER BY last_copied DESC, seq DESC LIMIT -1 OFFSET ?1)
    , .{@max(keep, 1)});
    try db.exec("COMMIT");
}

/// A clipboard entry's rowid, so it cannot be passed where a time (the
/// other i64 these functions take) is meant. SQLite rowids are signed 64-bit
/// integers (normally >= 1, though foreign/damaged rows may have any i64).
pub const ClipId = enum(i64) {
    _,

    fn of(row: i64) ClipId {
        return @fromBackingInt(row);
    }

    fn rowid(id: ClipId) i64 {
        return @backingInt(id);
    }
};

pub const Clip = struct {
    id: ClipId,
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
    // Times have one-second resolution; `seq` breaks ties in copy/recopy order.
    const stmt = try db.prepare(
        \\SELECT id, substr(content, 1, ?2), created_at, last_copied FROM clipboard
        \\ORDER BY last_copied DESC, seq DESC LIMIT ?1
    );
    defer _ = c.sqlite3_finalize(stmt);
    try db.bind(stmt, .{ limit, head_chars });
    while (try db.nextRow(stmt)) {
        // SQLite's LIMIT holds: never more rows than asked for.
        assert(list.items.len < limit);
        try list.append(arena, .{
            .id = .of(c.sqlite3_column_int64(stmt, 0)),
            .head = try arena.dupe(u8, columnText(stmt, 1)),
            .created_at = c.sqlite3_column_int64(stmt, 2),
            .last_copied = c.sqlite3_column_int64(stmt, 3),
        });
    }
    return list.toOwnedSlice(arena);
}

/// The entries of more than `scored_bytes` bytes that hold `needle`
/// anywhere (ASCII case aside), in `arena`. The clipboard filter scores
/// only the first bytes of each entry's head: a match further on hid the
/// entry (MYP-491).
pub fn clipsContaining(
    db: *Db,
    arena: std.mem.Allocator,
    needle: []const u8,
    scored_bytes: usize,
) (Error || std.mem.Allocator.Error)![]ClipId {
    // LIKE's wildcards in the needle stand for themselves.
    var pattern: std.ArrayList(u8) = .empty;
    try pattern.ensureTotalCapacity(arena, 2 * needle.len + 2);
    pattern.appendAssumeCapacity('%');
    for (needle) |byte| {
        if (byte == '%' or byte == '_' or byte == '\\') pattern.appendAssumeCapacity('\\');
        pattern.appendAssumeCapacity(byte);
    }
    pattern.appendAssumeCapacity('%');
    const stmt = try db.prepare(
        \\SELECT id FROM clipboard
        \\WHERE length(CAST(content AS BLOB)) > ?2 AND content LIKE ?1 ESCAPE '\'
    );
    defer _ = c.sqlite3_finalize(stmt);
    try db.bind(stmt, .{ pattern.items, std.math.cast(i64, scored_bytes) orelse std.math.maxInt(i64) });
    var ids: std.ArrayList(ClipId) = .empty;
    while (try db.nextRow(stmt)) try ids.append(arena, .of(c.sqlite3_column_int64(stmt, 0)));
    return ids.toOwnedSlice(arena);
}

/// All of entry `id`, in `arena`; null when it is gone.
pub fn clipContent(
    db: *Db,
    arena: std.mem.Allocator,
    id: ClipId,
) (Error || std.mem.Allocator.Error)!?[]const u8 {
    const stmt = try db.prepare("SELECT content FROM clipboard WHERE id = ?1");
    defer _ = c.sqlite3_finalize(stmt);
    try db.bind(stmt, .{id.rowid()});
    if (!try db.nextRow(stmt)) return null;
    return try arena.dupe(u8, columnText(stmt, 0));
}

pub fn touchClip(db: *Db, id: ClipId, now_s: i64) Error!void {
    try db.exec("BEGIN IMMEDIATE");
    errdefer _ = c.sqlite3_exec(db.handle, "ROLLBACK", null, null, null);
    const seq = try db.nextClipSeq();
    try db.execArgs(
        "UPDATE clipboard SET last_copied = ?2, seq = ?3 WHERE id = ?1",
        .{ id.rowid(), now_s, seq },
    );
    try db.exec("COMMIT");
}

/// Deletes entry `id`; returns false if it was already removed (e.g. by
/// another process).
pub fn deleteClip(db: *Db, id: ClipId) Error!bool {
    try db.execArgs("DELETE FROM clipboard WHERE id = ?1", .{id.rowid()});
    return c.sqlite3_changes(db.handle) > 0;
}

pub fn clearClips(db: *Db) Error!void {
    try db.exec("DELETE FROM clipboard");
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
        var content_buffer: [16]u8 = undefined;
        const content = try std.mem.print(&content_buffer, "clip {d}", .{i});
        try db.addClip(content, @intCast(i), 5);
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
    try std.testing.expect(try db.deleteClip(clips[0].id));
    try std.testing.expect(try db.clipContent(allocator, clips[0].id) == null);
    try std.testing.expect(!(try db.deleteClip(clips[0].id)));
}

test "a long entry is found by text past its head (MYP-491)" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const long = try allocator.alloc(u8, head_chars + 1 + "\nQuokka_Suffix".len);
    @memset(long[0 .. head_chars + 1], 'a');
    @memcpy(long[head_chars + 1 ..], "\nQuokka_Suffix");
    try db.addClip(long, 1, Db.clip_entries_max);
    try db.addClip("short quokka_suffix", 2, Db.clip_entries_max);
    const clips = try db.recentClips(allocator, 10);
    const long_id = clips[1].id;
    const found = try db.clipsContaining(allocator, "quokka_suffix", head_chars);
    try std.testing.expectEqualSlices(ClipId, &.{long_id}, found);
    // "_" and "%" are not wildcards.
    try std.testing.expectEqual(0, (try db.clipsContaining(allocator, "quokka%suffix", head_chars)).len);
    try std.testing.expectEqual(0, (try db.clipsContaining(allocator, "quokkaxsuffix", head_chars)).len);
    // Only entries longer than the bytes scored are looked at.
    try std.testing.expectEqual(0, (try db.clipsContaining(allocator, "quokka", long.len)).len);
}

test "the database and its -wal and -shm are owner-only" {
    const linux = std.os.linux;
    var test_dir: @import("os").TestDir = try .init();
    defer test_dir.deinit();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // Made world-readable, as earlier versions left it.
    try test_dir.write("lumen.db", "");
    const chmod_result = linux.chmod(try test_dir.path(&path_buffer, "lumen.db"), 0o644);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(chmod_result));
    var db = try Db.open(try test_dir.path(&path_buffer, "lumen.db"));
    defer db.close();
    try db.addClip("a password", 1, Db.clip_entries_max);
    for ([_][]const u8{ "lumen.db", "lumen.db-wal", "lumen.db-shm" }) |name| {
        var stx: linux.Statx = undefined;
        const path = try test_dir.path(&path_buffer, name);
        const statx_result = linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &stx);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(statx_result));
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
    try db.pruneFrecency(std.testing.allocator, now);
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
    try std.testing.expectError(error.DbStep, db.deleteClip(.of(1)));
    try std.testing.expectError(error.DbExec, db.clearClips());
    // Trimming failure rolls back the insert atomically.
    try std.testing.expectError(error.DbStep, db.addClip("second", 2, 1));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 1), clips.len);
    try std.testing.expectEqualStrings("secret", clips[0].head);
}

test "damaged rows (negative score, non-positive clip id) and symlinks are handled safely" {
    const linux = std.os.linux;
    var db = try Db.open(Db.in_memory);
    defer db.close();
    try db.exec("INSERT INTO frecency (key, score, last_used) VALUES ('neg', -5.0, 100);");
    try db.exec("INSERT INTO clipboard (id, hash, content, created_at, last_copied, seq) VALUES (-1, 1, 'bad', 1, 1, 0);");
    try db.addClip("good", 2, Db.clip_entries_max);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const map = try db.loadFrecency(arena.allocator(), 100);
    try std.testing.expectEqual(@as(f64, 0), map.get("neg").?);
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 2), clips.len);
    try std.testing.expectEqualStrings("good", clips[0].head);
    try std.testing.expectEqualStrings("bad", clips[1].head);
    try std.testing.expectEqualStrings(
        "bad",
        (try db.clipContent(arena.allocator(), clips[1].id)).?,
    );
    _ = try db.deleteClip(clips[1].id);

    var test_dir: @import("os").TestDir = try .init();
    defer test_dir.deinit();
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try test_dir.write("victim", "");
    const target = try test_dir.path(&target_buf, "victim");
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.chmod(target, 0o644)));
    const link = try test_dir.path(&link_buf, "lumen.db");
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlink(target, link)));
    try std.testing.expectError(error.DbOpen, Db.open(link));
    var stx: linux.Statx = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.statx(linux.AT.FDCWD, target, 0, .{ .MODE = true }, &stx)),
    );
    try std.testing.expectEqual(@as(u16, 0o644), stx.mode & 0o777);
}

test "frecency decays per use so one new use does not resurrect old history" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    const day = 86_400;
    const now: i64 = 1000 * day;
    for (0..200) |_| try db.recordUse("app:abandoned", now - 365 * day);
    try db.recordUse("app:abandoned", now);
    for (0..20) |_| try db.recordUse("app:daily", now - 2 * day);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const map = try db.loadFrecency(arena.allocator(), now);
    try std.testing.expect(map.get("app:abandoned").? < 1.001);
    try std.testing.expect(map.get("app:daily").? > 15.0);
    try std.testing.expect(map.get("app:daily").? > map.get("app:abandoned").?);
}

test "same-second recopy ordering and retention keep the recopied entry" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    // A -> B -> A within the same second puts A first.
    try db.addClip("A", 50, 10);
    try db.addClip("B", 50, 10);
    try db.addClip("A", 50, 10);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqualStrings("A", clips[0].head);
    try std.testing.expectEqualStrings("B", clips[1].head);

    // Touch promotes within the same second.
    try db.touchClip(clips[1].id, 50);
    clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqualStrings("B", clips[0].head);

    // Retention with 10 entries in the same second: recopying oldest ("e0")
    // then inserting "e10" must evict "e1", not "e0".
    try db.clearClips();
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        try db.addClip(try std.mem.print(&buf, "e{d}", .{i}), 100, 10);
    }
    try db.addClip("e0", 100, 10);
    try db.addClip("e10", 100, 10);
    clips = try db.recentClips(arena.allocator(), 20);
    try std.testing.expectEqual(@as(usize, 10), clips.len);
    try std.testing.expectEqualStrings("e10", clips[0].head);
    try std.testing.expectEqualStrings("e0", clips[1].head);
    for (clips) |clip| try std.testing.expect(!std.mem.eql(u8, "e1", clip.head));
}

test "clipboard IDs are never reused after delete or clear across connections" {
    var test_dir: @import("os").TestDir = try .init();
    defer test_dir.deinit();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try test_dir.path(&path_buf, "shared.db");

    var db_a = try Db.open(path);
    defer db_a.close();
    var db_b = try Db.open(path);
    defer db_b.close();

    try db_a.addClip("alpha", 10, Db.clip_entries_max);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips_a = try db_a.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 1), clips_a.len);
    const alpha_id = clips_a[0].id;

    // Another connection clears the history and adds "bravo".
    try db_b.clearClips();
    try db_b.addClip("bravo", 11, Db.clip_entries_max);

    // Stale UI handle from A cannot read or delete "bravo".
    try std.testing.expect(try db_a.clipContent(arena.allocator(), alpha_id) == null);
    try std.testing.expect(!(try db_a.deleteClip(alpha_id)));
    const clips_b = try db_b.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 1), clips_b.len);
    try std.testing.expectEqualStrings("bravo", clips_b[0].head);
    try std.testing.expect(clips_b[0].id != alpha_id);
}

test "legacy database migrates frecency score and clipboard autoincrement+seq" {
    var test_dir: @import("os").TestDir = try .init();
    defer test_dir.deinit();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try test_dir.path(&path_buf, "legacy.db");

    // Create a file database using the old schema before migrating.
    {
        var raw_handle: ?*c.sqlite3 = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(path.ptr, &raw_handle));
        var legacy: Db = .{ .handle = raw_handle.? };
        defer legacy.close();
        try legacy.exec(
            \\CREATE TABLE frecency (
            \\  key TEXT PRIMARY KEY,
            \\  count INTEGER NOT NULL,
            \\  last_used INTEGER NOT NULL
            \\);
            \\CREATE TABLE clipboard (
            \\  id INTEGER PRIMARY KEY,
            \\  hash INTEGER NOT NULL UNIQUE,
            \\  content TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  last_copied INTEGER NOT NULL
            \\);
            \\INSERT INTO frecency VALUES ('app:old', 5, 100), ('app:bad', -2, 100);
            \\INSERT INTO clipboard (id, hash, content, created_at, last_copied)
            \\  VALUES (1, 11, 'first', 50, 50), (2, 22, 'second', 50, 50);
        );
    }

    var db = try Db.open(path);
    defer db.close();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const map = try db.loadFrecency(arena.allocator(), 100);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), map.get("app:old").?, 1e-9);
    try std.testing.expectEqual(@as(f64, 0), map.get("app:bad").?);

    var clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 2), clips.len);
    try std.testing.expectEqualStrings("second", clips[0].head);
    try std.testing.expectEqualStrings("first", clips[1].head);

    // Same-second recopy of 'first' now promotes it past 'second'.
    try db.addClip("first", 50, 10);
    clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqualStrings("first", clips[0].head);

    // Clearing and inserting assigns a fresh id strictly greater than 2.
    try db.clearClips();
    try db.addClip("third", 51, 10);
    clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 1), clips.len);
    try std.testing.expect(clips[0].id.rowid() > 2);
}

test "openWith supports shorter UI busy timeout" {
    var db = try Db.openWith(in_memory, .{ .busy_timeout_ms = 50 });
    db.close();
}

test "clipboard hash collision preserves distinct entries and long sidecar path fails open" {
    var db = try Db.open(Db.in_memory);
    defer db.close();
    // Same hash with distinct content creates two distinct rows instead of overwriting.
    try db.exec(
        \\INSERT INTO clipboard (hash, content, created_at, last_copied, seq)
        \\VALUES (12345, 'colliding-a', 10, 10, 1)
    );
    try db.exec(
        \\INSERT INTO clipboard (hash, content, created_at, last_copied, seq)
        \\VALUES (12345, 'colliding-b', 11, 11, 2)
        \\ON CONFLICT(hash, content) DO UPDATE SET last_copied = 11, seq = 2
    );
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const clips = try db.recentClips(arena.allocator(), 10);
    try std.testing.expectEqual(@as(usize, 2), clips.len);

    // A path that exceeds max_path_bytes for "-wal" fails open instead of ignoring permissions.
    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    var long_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memset(&long_buf, 'x');
    const prefix = test_dir.absolute;
    @memcpy(long_buf[0..prefix.len], prefix);
    long_buf[prefix.len] = '/';
    long_buf[std.Io.Dir.max_path_bytes - 2] = 0;
    const long_path = long_buf[0 .. std.Io.Dir.max_path_bytes - 2 :0];
    try std.testing.expectError(error.DbOpen, makePrivate(long_path));
}
