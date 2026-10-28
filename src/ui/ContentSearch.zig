//! Content searches off the UI thread.
//!
//! A content query reads files to verify its candidates: usually a few ms,
//! but nothing bounds it (a slow disk, a huge document, once a FIFO that
//! blocked forever), and on the UI thread every keystroke waited for it.
//! Here the UI posts the latest query and keeps typing; one worker runs the
//! newest query (stale ones in between are skipped) and hands the result
//! back on the GTK main loop with g_idle_add, which is thread-safe.

const std = @import("std");
const c = @import("c");
const index = @import("index");
const os = @import("os");

const ContentSearch = @This();

const log = std.log.scoped(.content_search);

/// Longer queries are cut to this many bytes; compare results against
/// `clip(query)`, not the query typed.
pub const max_query = 1024;

pub fn clip(query: []const u8) []const u8 {
    return query[0..@min(query.len, max_query)];
}

/// Owned by the receiver of `Callback`, which frees it with `destroy`.
pub const Result = struct {
    gen: u32,
    /// When the keystroke that asked for it happened (latency stats).
    t0: u64,
    search_ns: u64,
    query: []const u8,
    hits: []index.ContentService.Hit,
    /// Why the search stopped short (then `hits` may be empty or partial).
    err: ?std.mem.Allocator.Error = null,
    arena: std.heap.ArenaAllocator,

    pub fn destroy(r: *Result, gpa: std.mem.Allocator) void {
        r.arena.deinit();
        gpa.destroy(r);
    }
};

/// Called on the GTK main loop; takes ownership of `result`.
pub const Callback = *const fn (result: *Result, ctx: ?*anyopaque) void;

gpa: std.mem.Allocator,
io: std.Io,
service: *index.ContentService,
limit: usize,
on_result: Callback,
ctx: ?*anyopaque,
thread: std.Thread = undefined,
lock: std.Io.Mutex = .init,
/// Bumped by every `submit`; the worker sleeps on it.
gen: std.atomic.Value(u32) = .init(0),
stop: std.atomic.Value(bool) = .init(false),
query_buf: [max_query]u8 = undefined,
query_len: usize = 0,
query_t0: u64 = 0,

pub const StartError = std.mem.Allocator.Error || std.Thread.SpawnError;

/// Starts the worker. `service` must outlive it.
pub fn start(
    gpa: std.mem.Allocator,
    io: std.Io,
    service: *index.ContentService,
    limit: usize,
    on_result: Callback,
    ctx: ?*anyopaque,
) StartError!*ContentSearch {
    const cs = try gpa.create(ContentSearch);
    errdefer gpa.destroy(cs);
    cs.* = .{
        .gpa = gpa,
        .io = io,
        .service = service,
        .limit = limit,
        .on_result = on_result,
        .ctx = ctx,
    };
    cs.thread = try std.Thread.spawn(.{}, run, .{cs});
    cs.thread.setName(io, "lm-csearch") catch {};
    return cs;
}

/// Stops and joins the worker. Call once the GTK main loop has stopped:
/// a result still queued with g_idle_add would otherwise reach a freed `cs`.
pub fn shutdown(cs: *ContentSearch) void {
    cs.stop.store(true, .release);
    _ = cs.gen.fetchAdd(1, .release);
    cs.io.futexWake(u32, &cs.gen.raw, 1);
    cs.thread.join();
    cs.gpa.destroy(cs);
}

/// Asks for `clip(query)`; returns its generation. Results of older
/// generations still in flight should be dropped by the receiver.
/// Thread-safe.
pub fn submit(cs: *ContentSearch, query: []const u8, t0: u64) u32 {
    const q = clip(query);
    const g = blk: {
        cs.lock.lockUncancelable(cs.io);
        defer cs.lock.unlock(cs.io);
        @memcpy(cs.query_buf[0..q.len], q);
        cs.query_len = q.len;
        cs.query_t0 = t0;
        break :blk cs.gen.fetchAdd(1, .release) + 1;
    };
    cs.io.futexWake(u32, &cs.gen.raw, 1);
    return g;
}

fn run(cs: *ContentSearch) void {
    var seen: u32 = 0;
    while (true) {
        while (cs.gen.load(.acquire) == seen and !cs.stop.load(.acquire)) {
            cs.io.futexWaitUncancelable(u32, &cs.gen.raw, seen);
        }
        if (cs.stop.load(.acquire)) return;

        const r = cs.gpa.create(Result) catch {
            // Drop this query rather than spin on it: the next keystroke
            // asks again.
            seen = cs.gen.load(.acquire);
            log.warn("content search: out of memory", .{});
            continue;
        };
        r.* = .{
            .gen = 0,
            .t0 = 0,
            .search_ns = 0,
            .query = "",
            .hits = &.{},
            .arena = .init(cs.gpa),
        };
        const a = r.arena.allocator();
        {
            cs.lock.lockUncancelable(cs.io);
            defer cs.lock.unlock(cs.io);
            seen = cs.gen.load(.acquire);
            r.gen = seen;
            r.t0 = cs.query_t0;
            r.query = a.dupe(u8, cs.query_buf[0..cs.query_len]) catch |err| blk: {
                r.err = err;
                break :blk "";
            };
        }

        const t = os.monotonicNs();
        var hits: std.ArrayList(index.ContentService.Hit) = .empty;
        if (r.err == null) cs.service.search(a, r.query, cs.limit, &hits) catch |err| {
            r.err = err;
        };
        r.search_ns = os.monotonicNs() - t;
        r.hits = hits.items;
        // A newer query arrived meanwhile: this answer is already stale.
        if (cs.gen.load(.acquire) != seen) {
            r.destroy(cs.gpa);
            continue;
        }
        const hop = cs.gpa.create(Hop) catch {
            r.destroy(cs.gpa);
            continue;
        };
        hop.* = .{ .cs = cs, .result = r };
        _ = c.g_idle_add(&deliver, hop);
    }
}

const Hop = struct { cs: *ContentSearch, result: *Result };

fn deliver(data: ?*anyopaque) callconv(.c) c.gboolean {
    const hop: *Hop = @ptrCast(@alignCast(data.?));
    defer hop.cs.gpa.destroy(hop);
    hop.cs.on_result(hop.result, hop.cs.ctx);
    return 0;
}
