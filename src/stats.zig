//! In-process numbers for `lumen --stats`: what only the daemon can see.
//! External numbers (RSS, CPU per thread, GPU) are read from /proc and
//! nvidia-smi by tools/lumen-stats.sh.
//!
//! Latency is measured to the painted frame (GdkFrameClock "after-paint"),
//! not to the end of the search: what you see is search + building rows +
//! GTK's layout and drawing.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const index = @import("index");
const os = @import("os");
const version = @import("build_options").version;
const View = @import("item.zig").View;

/// The last `samples_max` latency samples, in nanoseconds, and how many
/// were ever added (`total`).
pub const Ring = struct {
    samples: [samples_max]u64 = undefined,
    len: usize = 0,
    next: usize = 0,
    total: u64 = 0,

    const samples_max = 512;

    pub fn add(ring: *Ring, sample_ns: u64) void {
        assert(ring.next < samples_max);
        ring.samples[ring.next] = sample_ns;
        ring.next = (ring.next + 1) % samples_max;
        ring.len = @min(ring.len + 1, samples_max);
        ring.total += 1;
        assert(ring.len <= ring.total);
    }

    pub const Summary = struct { n: u64, p50: f64, p95: f64, max: f64 };

    pub fn summary(ring: *const Ring) Summary {
        if (ring.len == 0) return .{ .n = 0, .p50 = 0, .p95 = 0, .max = 0 };
        assert(ring.len <= samples_max);
        var sorted: [samples_max]u64 = undefined;
        @memcpy(sorted[0..ring.len], ring.samples[0..ring.len]);
        std.mem.sort(u64, sorted[0..ring.len], {}, std.sort.asc(u64));
        const last = ring.len - 1;
        return .{
            .n = ring.total,
            .p50 = msFromNs(sorted[ring.len / 2]),
            .p95 = msFromNs(sorted[@min(last, ring.len * 95 / 100)]),
            .max = msFromNs(sorted[last]),
        };
    }
};

fn msFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

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

/// A refresh waiting for its frame: when it started, how long the search
/// and the rows took, and whether it was the window being shown.
pub var pending: ?Pending = null;

pub const Pending = struct {
    start_ns: u64,
    view: View,
    search_ns: u64,
    rows_ns: u64,
    is_show: bool,
};

pub fn now() u64 {
    return os.monotonicNs();
}

/// Called after every painted frame.
pub fn onPainted() void {
    const refresh = pending orelse return;
    pending = null;
    const latency_ns = now() - refresh.start_ns;
    if (refresh.is_show) {
        show.add(latency_ns);
        return;
    }
    const view_stats = &views[@backingInt(refresh.view)];
    view_stats.painted.add(latency_ns);
    view_stats.search.add(refresh.search_ns);
    view_stats.rows.add(refresh.rows_ns);
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

fn mbFromBytes(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

/// `VmRSS:  1234 kB` style fields of /proc/self/status, in MB.
fn procField(status: []const u8, key: []const u8) f64 {
    const at = std.mem.find(u8, status, key) orelse return 0;
    var tokens = std.mem.tokenizeAny(u8, status[at + key.len ..], " \t:");
    const kb = std.fmt.parseInt(u64, tokens.next() orelse "0", 10) catch 0;
    return @as(f64, @floatFromInt(kb)) / 1024;
}

/// The text of a field of /proc/self/status (`Threads:   24`), or "?".
fn procText(status: []const u8, comptime key: []const u8) []const u8 {
    const field = key ++ ":";
    const at = std.mem.find(u8, status, field) orelse return "?";
    const end = std.mem.findScalarPos(u8, status, at, '\n') orelse status.len;
    return std.mem.trim(u8, status[at + field.len .. end], " \t");
}

const ReportError = std.Io.Writer.Error || std.mem.Allocator.Error;

/// The `lumen --stats` text. Caller owns the result, allocated with `gpa`.
pub fn report(
    gpa: std.mem.Allocator,
    files: ?*index.Service,
    contents: ?*index.ContentService,
) ReportError![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;
    const up_s = (now() - started_ns) / std.time.ns_per_s;
    try writer.print("Lumen {s}  pid {d}  up {d}h{d:0>2}m  started in {d:.0} ms\n\n", .{
        version,
        std.os.linux.getpid(),
        up_s / 3600,
        up_s / 60 % 60,
        msFromNs(startup_ns),
    });
    try reportMemory(writer);
    if (files) |file_service| try reportFileIndex(writer, file_service);
    if (contents) |content_service| try reportContentIndex(writer, content_service);
    try reportLatency(writer);
    return out.toOwnedSliceSentinel(0);
}

fn reportMemory(writer: *std.Io.Writer) ReportError!void {
    var status_buf: [4096]u8 = undefined;
    const status = os.readHead("/proc/self/status", &status_buf);
    const malloc_info = mallinfo2();
    try writer.print("Memory\n", .{});
    try writer.print(
        "  RSS {d:.1} MB (anon {d:.1}, files {d:.1}, shmem {d:.1})   peak {d:.1} MB   threads {s}\n",
        .{
            procField(status, "VmRSS"),
            procField(status, "RssAnon"),
            procField(status, "RssFile"),
            procField(status, "RssShmem"),
            procField(status, "VmHWM"),
            procText(status, "Threads"),
        },
    );
    try writer.print(
        "  heap: in use {d:.1} MB, free but kept by malloc {d:.1} MB, mmap'd blocks {d:.1} MB\n\n",
        .{
            mbFromBytes(malloc_info.uordblks),
            mbFromBytes(malloc_info.fordblks),
            mbFromBytes(malloc_info.hblkhd),
        },
    );
}

fn reportFileIndex(writer: *std.Io.Writer, file_service: *index.Service) ReportError!void {
    const status = file_service.status();
    try writer.print("File index\n", .{});
    try writer.print("  {d} entries, {d} inotify watches{s}, index {d:.1} MB, ", .{
        status.entries,
        status.watches,
        if (status.armed) "" else " (arming)",
        mbFromBytes(status.index_bytes),
    });
    try writer.print("{d} rescans (last {d:.0} ms)\n", .{
        status.rescans,
        msFromNs(status.last_rescan_ns),
    });
    if (status.unwatched > 0) {
        try writer.print(
            "  {d} folders unwatched: inotify limit (fs.inotify.max_user_watches)\n",
            .{status.unwatched},
        );
    }
    try writer.writeByte('\n');
}

fn reportContentIndex(
    writer: *std.Io.Writer,
    content_service: *index.ContentService,
) ReportError!void {
    const status = content_service.status();
    try writer.print(
        "Content index\n  {d} documents ({d} extracted), {d} segments, index {d:.1} MB{s}\n",
        .{
            status.docs,
            status.extracted,
            status.segments,
            mbFromBytes(status.index_bytes),
            if (status.building) ", rebuilding" else "",
        },
    );
    try writer.print("  {d} checks, {d} of them listings (last {d:.0} ms; ", .{
        status.checks,
        status.listings,
        msFromNs(status.last_list_ns),
    });
    try writer.print("indexed files only: {d:.0} ms), ", .{msFromNs(status.last_stat_ns)});
    try writer.print("{d} builds, {d} of them updates (last {d:.0} ms, ", .{
        status.builds,
        status.updates,
        msFromNs(status.last_build_ns),
    });
    try writer.print("extraction {d:.0} ms)\n\n", .{msFromNs(status.last_extract_ns)});
}

fn reportLatency(writer: *std.Io.Writer) ReportError!void {
    try writer.print("Latency, keystroke -> painted frame (ms)\n", .{});
    try writer.print("  {s:<10} {s:>6} {s:>8} {s:>8} {s:>8}   {s:>13} {s:>13}\n", .{
        "view",
        "n",
        "p50",
        "p95",
        "max",
        "search p50/95",
        "rows p50/95",
    });
    for (view_names, &views) |name, *view_stats| {
        const painted = view_stats.painted.summary();
        if (painted.n == 0) continue;
        const search = view_stats.search.summary();
        const rows = view_stats.rows.summary();
        try writer.print(
            "  {s:<10} {d:>6} {d:>8.2} {d:>8.2} {d:>8.2}   {d:>6.2}/{d:<6.2} {d:>6.2}/{d:<6.2}\n",
            .{
                name,       painted.n,  painted.p50, painted.p95, painted.max,
                search.p50, search.p95, rows.p50,    rows.p95,
            },
        );
    }
    const shown = show.summary();
    if (shown.n > 0) {
        try writer.print(
            "  {s:<10} {d:>6} {d:>8.2} {d:>8.2} {d:>8.2}   (window shown -> first frame)\n",
            .{ "show", shown.n, shown.p50, shown.p95, shown.max },
        );
    }
}

test "procText and procField read /proc/self/status fields" {
    const status = "Name:\tlumen\nVmRSS:\t  2048 kB\nThreads:\t24\n";
    try std.testing.expectEqualStrings("24", procText(status, "Threads"));
    try std.testing.expectEqualStrings("?", procText(status, "Nope"));
    try std.testing.expectEqual(@as(f64, 2), procField(status, "VmRSS"));
}

test "a ring keeps the last samples and counts them all" {
    var ring: Ring = .{};
    try std.testing.expectEqual(@as(u64, 0), ring.summary().n);
    for (0..Ring.samples_max + 10) |i| ring.add(@intCast(i * std.time.ns_per_ms));
    const summary = ring.summary();
    try std.testing.expectEqual(@as(u64, Ring.samples_max + 10), summary.n);
    try std.testing.expectEqual(@as(f64, Ring.samples_max + 9), summary.max);
}
