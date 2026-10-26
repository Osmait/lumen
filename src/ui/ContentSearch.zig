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

const ContentSearch = @This();

pub const Result = struct {
    gen: u32,
    /// When the keystroke that asked for it happened (latency stats).
    t0: u64,
    search_ns: u64,
    query: []const u8,
    hits: []index.ContentService.Hit,
    arena: std.heap.ArenaAllocator,

    pub fn destroy(r: *Result, gpa: std.mem.Allocator) void {
        r.arena.deinit();
        gpa.destroy(r);
    }
};

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
query_buf: [1024]u8 = undefined,
query_len: usize = 0,
query_t0: u64 = 0,

pub fn start(gpa: std.mem.Allocator, io: std.Io, service: *index.ContentService, limit: usize, on_result: Callback, ctx: ?*anyopaque) !*ContentSearch {
    const cs = try gpa.create(ContentSearch);
    cs.* = .{ .gpa = gpa, .io = io, .service = service, .limit = limit, .on_result = on_result, .ctx = ctx };
    cs.thread = try std.Thread.spawn(.{}, run, .{cs});
    cs.thread.setName(io, "lm-csearch") catch {};
    return cs;
}

pub fn shutdown(cs: *ContentSearch) void {
    cs.stop.store(true, .release);
    _ = cs.gen.fetchAdd(1, .release);
    cs.io.futexWake(u32, &cs.gen.raw, 1);
    cs.thread.join();
    cs.gpa.destroy(cs);
}

/// Asks for `query`; returns its generation. Results of older generations
/// still in flight should be dropped by the receiver.
pub fn submit(cs: *ContentSearch, query: []const u8, t0: u64) u32 {
    cs.lock.lockUncancelable(cs.io);
    const n = @min(query.len, cs.query_buf.len);
    @memcpy(cs.query_buf[0..n], query[0..n]);
    cs.query_len = n;
    cs.query_t0 = t0;
    const g = cs.gen.fetchAdd(1, .release) + 1;
    cs.lock.unlock(cs.io);
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

        const r = cs.gpa.create(Result) catch continue;
        r.* = .{ .gen = 0, .t0 = 0, .search_ns = 0, .query = "", .hits = &.{}, .arena = std.heap.ArenaAllocator.init(cs.gpa) };
        const a = r.arena.allocator();
        cs.lock.lockUncancelable(cs.io);
        seen = cs.gen.load(.acquire);
        r.gen = seen;
        r.t0 = cs.query_t0;
        r.query = a.dupe(u8, cs.query_buf[0..cs.query_len]) catch "";
        cs.lock.unlock(cs.io);

        const t = index.sys.monotonicNs();
        var hits: std.ArrayList(index.ContentService.Hit) = .empty;
        cs.service.search(a, r.query, cs.limit, &hits) catch {};
        r.search_ns = index.sys.monotonicNs() - t;
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
