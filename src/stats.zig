//! In-process numbers for `lumen --stats`: what only the daemon can see.
//! External numbers (RSS, CPU per thread, GPU) are read from /proc and
//! nvidia-smi by tools/lumen-stats.sh.
//!
//! Latency is measured to the painted frame (GdkFrameClock "after-paint"),
//! not to the end of the search: what you see is search + building rows +
//! GTK's layout and drawing.

const std = @import("std");
const c = @import("c");
const index = @import("index");
const View = @import("item.zig").View;

/// The last `cap` samples, in nanoseconds.
pub const Ring = struct {
    const cap = 512;
    buf: [cap]u64 = undefined,
    len: usize = 0,
    next: usize = 0,
    total: u64 = 0,

    pub fn add(r: *Ring, ns: u64) void {
        r.buf[r.next] = ns;
        r.next = (r.next + 1) % cap;
        r.len = @min(r.len + 1, cap);
        r.total += 1;
    }

    pub const Summary = struct { n: u64, p50: f64, p95: f64, max: f64 };

    pub fn summary(r: *const Ring) Summary {
        if (r.len == 0) return .{ .n = 0, .p50 = 0, .p95 = 0, .max = 0 };
        var sorted: [cap]u64 = undefined;
        @memcpy(sorted[0..r.len], r.buf[0..r.len]);
        std.mem.sort(u64, sorted[0..r.len], {}, std.sort.asc(u64));
        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / 1e6;
            }
        }.f;
        return .{
            .n = r.total,
            .p50 = ms(sorted[r.len / 2]),
            .p95 = ms(sorted[@min(r.len - 1, r.len * 95 / 100)]),
            .max = ms(sorted[r.len - 1]),
        };
    }
};

pub const ViewStats = struct { painted: Ring = .{}, search: Ring = .{}, rows: Ring = .{} };

const view_names = @typeInfo(View).@"enum".field_names;

// The latency figures below are written and read on the GTK main thread
// only (refresh, frame clock, `--stats`): plain globals are enough.

pub var views: [view_names.len]ViewStats = @splat(.{});
/// Window shown -> first painted frame.
pub var show: Ring = .{};
pub var started_ns: u64 = 0;
/// main() -> window built and indexes started.
pub var startup_ns: u64 = 0;

/// A refresh waiting for its frame.
pub var pending: ?struct { t0: u64, view: View, search: u64, rows: u64, is_show: bool } = null;

pub fn now() u64 {
    return index.sys.monotonicNs();
}

/// Called after every painted frame.
pub fn onPainted() void {
    const p = pending orelse return;
    pending = null;
    const dt = now() - p.t0;
    if (p.is_show) {
        show.add(dt);
        return;
    }
    const v = &views[@backingInt(p.view)];
    v.painted.add(dt);
    v.search.add(p.search);
    v.rows.add(p.rows);
}

const MallInfo2 = extern struct {
    arena: usize,
    ordblks: usize,
    smblks: usize,
    hblks: usize,
    hblkhd: usize,
    usmblks: usize,
    fsmblks: usize,
    uordblks: usize,
    fordblks: usize,
    keepcost: usize,
};
extern fn mallinfo2() MallInfo2;

fn mb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

/// `VmRSS:  1234 kB` style fields of /proc/self/status, in MB.
fn procField(status: []const u8, key: []const u8) f64 {
    const at = std.mem.find(u8, status, key) orelse return 0;
    var it = std.mem.tokenizeAny(u8, status[at + key.len ..], " \t:");
    const kb = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    return @as(f64, @floatFromInt(kb)) / 1024;
}

/// The `lumen --stats` text. Caller owns the result, allocated with `gpa`.
pub fn report(
    gpa: std.mem.Allocator,
    files: ?*index.Service,
    contents: ?*index.ContentService,
) (std.Io.Writer.Error || std.mem.Allocator.Error)![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const up_s = (now() - started_ns) / std.time.ns_per_s;
    try w.print("Lumen  pid {d}  up {d}h{d:0>2}m  started in {d:.0} ms\n\n", .{
        std.os.linux.getpid(),
        up_s / 3600,
        up_s / 60 % 60,
        @as(f64, @floatFromInt(startup_ns)) / 1e6,
    });

    var status_buf: [4096]u8 = undefined;
    const status = index.sys.readHead("/proc/self/status", &status_buf);
    const mi = mallinfo2();
    try w.print("Memory\n", .{});
    try w.print("  RSS {d:.1} MB (anon {d:.1}, files {d:.1}, shmem {d:.1})   peak {d:.1} MB   threads {s}\n", .{
        procField(status, "VmRSS"), procField(status, "RssAnon"), procField(status, "RssFile"),
        procField(
            status,
            "RssShmem",
        ),
        procField(status, "VmHWM"),
        std.mem.trim(u8, blk: {
            const at = std.mem.find(u8, status, "Threads:") orelse break :blk "?";
            const end = std.mem.findScalarPos(u8, status, at, '\n') orelse status.len;
            break :blk status[at + 8 .. end];
        }, " \t"),
    });
    try w.print(
        "  heap: in use {d:.1} MB, free but kept by malloc {d:.1} MB, mmap'd blocks {d:.1} MB\n\n",
        .{ mb(mi.uordblks), mb(mi.fordblks), mb(mi.hblkhd) },
    );

    if (files) |f| {
        const st = f.status();
        try w.print("File index\n  {d} entries, {d} inotify watches{s}, index {d:.1} MB, {d} rescans (last {d:.0} ms)\n", .{
            st.entries, st.watches, if (st.armed) "" else " (arming)",
            mb(
                st.index_bytes,
            ),
            st.rescans,
            @as(
                f64,
                @floatFromInt(st.last_rescan_ns),
            ) / 1e6,
        });
        if (st.unwatched > 0) try w.print(
            "  {d} folders unwatched: inotify limit (fs.inotify.max_user_watches)\n",
            .{st.unwatched},
        );
        try w.writeByte('\n');
    }
    if (contents) |cs| {
        const st = cs.status();
        try w.print(
            "Content index\n  {d} documents ({d} extracted), {d} segments, index {d:.1} MB{s}\n",
            .{
                st.docs,
                st.extracted,
                st.segments,
                mb(st.index_bytes),
                if (st.building) ", rebuilding" else "",
            },
        );
        try w.print("  {d} checks, {d} of them listings (last {d:.0} ms; indexed files only: {d:.0} ms), {d} builds, {d} of them updates (last {d:.0} ms, extraction {d:.0} ms)\n\n", .{
            st.checks,                                      st.listings,
            @as(
                f64,
                @floatFromInt(st.last_list_ns),
            ) / 1e6,
            @as(f64, @floatFromInt(st.last_stat_ns)) / 1e6, st.builds,
            st.updates,
            @as(
                f64,
                @floatFromInt(st.last_build_ns),
            ) / 1e6,
            @as(
                f64,
                @floatFromInt(st.last_extract_ns),
            ) / 1e6,
        });
    }

    try w.print("Latency, keystroke -> painted frame (ms)\n", .{});
    try w.print("  {s:<10} {s:>6} {s:>8} {s:>8} {s:>8}   {s:>13} {s:>13}\n", .{
        "view",
        "n",
        "p50",
        "p95",
        "max",
        "search p50/95",
        "rows p50/95",
    });
    for (view_names, 0..) |name, i| {
        const v = &views[i];
        const s = v.painted.summary();
        if (s.n > 0) {
            const se = v.search.summary();
            const ro = v.rows.summary();
            try w.print(
                "  {s:<10} {d:>6} {d:>8.2} {d:>8.2} {d:>8.2}   {d:>6.2}/{d:<6.2} {d:>6.2}/{d:<6.2}\n",
                .{ name, s.n, s.p50, s.p95, s.max, se.p50, se.p95, ro.p50, ro.p95 },
            );
        }
    }
    const sh = show.summary();
    if (sh.n > 0) try w.print(
        "  {s:<10} {d:>6} {d:>8.2} {d:>8.2} {d:>8.2}   (window shown -> first frame)\n",
        .{ "show", sh.n, sh.p50, sh.p95, sh.max },
    );
    return out.toOwnedSliceSentinel(0);
}
