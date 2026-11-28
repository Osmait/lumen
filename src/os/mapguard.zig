//! Mapped files another process truncates (`cp` or `rsync --inplace` over
//! files.idx or content.idx, `truncate`): every read of a page past the new
//! end raises SIGBUS, which killed the daemon (MYP-556).
//!
//! The mappings `file.zig` makes are registered here, and a SIGBUS handler
//! puts a page of zeros where the access faulted, then lets it run again.
//! The reader sees zeros instead of the file's bytes, which is one more
//! way for another process to rewrite a mapped file, and every reader
//! already checks what it reads in a mapping against that (ARCHITECTURE.md:
//! "the mappings are also checked where they are read"). The mapping is
//! marked damaged so its owner can replace it (a rescan, a rebuild).
//!
//! Nothing is copied, so a mapping costs what it did (reclaimable page
//! cache), on every file system, the start-up snapshot included. A fault
//! outside the registered mappings goes to the handler that was there
//! before (Zig's, which prints a stack trace), or kills as by default.
//!
//! A mapping must be unregistered (`unmap` does it) before it is unmapped,
//! and nobody may read it then: a fault racing an unmap of the same range
//! would put the zero page over whatever is mapped there next.

const std = @import("std");
const linux = std.os.linux;

/// Mappings registered at once, at most: files.idx and content.idx (two of
/// each while one replaces the other), and the extracted texts the
/// content search's threads map while they check them. Past it a mapping is
/// left unguarded, as all were before.
const slots_max = 256;

const Slot = struct {
    /// Taken by a registration (set before `start`, cleared after it).
    taken: std.atomic.Value(bool) = .init(false),
    /// The mapping's first byte; 0: free. Set last, cleared first: the
    /// handler only looks at slots whose `start` is set.
    start: std.atomic.Value(usize) = .init(0),
    len: std.atomic.Value(usize) = .init(0),
    /// A truncation pulled pages out of it.
    damaged: std.atomic.Value(bool) = .init(false),
};

var slots: [slots_max]Slot = @splat(.{});

const State = enum(u8) { none, installing, installed };
var state: std.atomic.Value(State) = .init(.none);
/// The SIGBUS action before ours, for faults that are not ours.
var previous: linux.Sigaction = undefined;
var page_bytes: usize = 0;
/// Pages replaced with zeros, for tests and `lumen --stats`.
var replaced_pages: std.atomic.Value(u64) = .init(0);

/// Registers `bytes`, a mapping of a file: a truncation of that file then
/// costs its reader zeros, not the process. Best effort: with every slot
/// taken it stays unguarded.
pub fn register(bytes: []const u8) void {
    if (bytes.len == 0) return;
    install();
    for (&slots) |*slot| {
        if (slot.taken.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
        slot.damaged.store(false, .monotonic);
        slot.len.store(bytes.len, .monotonic);
        slot.start.store(@intFromPtr(bytes.ptr), .release);
        return;
    }
}

/// Unregisters `bytes` (registered or not), before it is unmapped.
pub fn unregister(bytes: []const u8) void {
    const slot = find(@intFromPtr(bytes.ptr)) orelse return;
    slot.start.store(0, .release);
    slot.len.store(0, .monotonic);
    slot.taken.store(false, .release);
}

/// Whether a truncation pulled pages out of mapping `bytes` (they read as
/// zeros now): its owner should replace it.
pub fn damaged(bytes: []const u8) bool {
    const slot = find(@intFromPtr(bytes.ptr)) orelse return false;
    return slot.damaged.load(.acquire);
}

/// Pages replaced with zeros since the process started.
pub fn replacedPages() u64 {
    return replaced_pages.load(.monotonic);
}

fn find(start: usize) ?*Slot {
    if (start == 0) return null;
    for (&slots) |*slot| {
        if (slot.start.load(.acquire) == start) return slot;
    }
    return null;
}

/// Installs the handler, once. Another thread installing it meanwhile is
/// waited for: a mapping must not be read unguarded once registered.
fn install() void {
    if (state.load(.acquire) == .installed) return;
    if (state.cmpxchgStrong(.none, .installing, .acquire, .acquire) == null) {
        page_bytes = std.heap.pageSize();
        const action: linux.Sigaction = .{
            .handler = .{ .sigaction = &handle },
            .mask = linux.sigemptyset(),
            // On the alternate stack where one is set (Zig sets one for its
            // own handler): a fault on a stack overflow is not ours, but
            // must still reach it.
            .flags = linux.SA.SIGINFO | linux.SA.ONSTACK | linux.SA.RESTART,
        };
        _ = linux.sigaction(.BUS, &action, &previous);
        state.store(.installed, .release);
        return;
    }
    while (state.load(.acquire) != .installed) std.atomic.spinLoopHint();
}

/// The SIGBUS handler: raw system calls and atomics only.
fn handle(signal: linux.SIG, info: *const linux.siginfo_t, context: ?*anyopaque) callconv(.c) void {
    const address = @intFromPtr(info.fields.sigfault.addr);
    if (covering(address)) |slot| {
        const page = address & ~(page_bytes - 1);
        const result = linux.mmap(
            @ptrFromInt(page),
            page_bytes,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
            -1,
            0,
        );
        if (linux.errno(result) == .SUCCESS) {
            slot.damaged.store(true, .release);
            _ = replaced_pages.fetchAdd(1, .monotonic);
            // The access runs again, on the zeros.
            return;
        }
    }
    forward(signal, info, context);
}

/// The registered mapping `address` is in, if any.
fn covering(address: usize) ?*Slot {
    for (&slots) |*slot| {
        const start = slot.start.load(.acquire);
        if (start == 0 or address < start) continue;
        if (address - start < slot.len.load(.monotonic)) return slot;
    }
    return null;
}

/// A fault that is not ours, to the action there was before this handler.
fn forward(signal: linux.SIG, info: *const linux.siginfo_t, context: ?*anyopaque) void {
    if (previous.flags & linux.SA.SIGINFO != 0) {
        if (previous.handler.sigaction) |handler| return handler(signal, info, context);
    } else if (previous.handler.handler) |handler| {
        const value = @intFromPtr(handler);
        if (value != @intFromPtr(linux.SIG.DFL) and value != @intFromPtr(linux.SIG.IGN)) {
            return handler(signal);
        }
    }
    // The default (or ignored, which a fault cannot be): back to it, and
    // the access faults again and kills.
    const default: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.BUS, &default, null);
}

const testing = std.testing;
const os = @import("root.zig");

test "a mapped file truncated by another process reads as zeros, and is marked damaged" {
    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    const page = std.heap.pageSize();
    const data = try testing.allocator.alloc(u8, 8 * page);
    defer testing.allocator.free(data);
    @memset(data, 'x');
    try test_dir.write("mapped", data);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try test_dir.path(&path_buffer, "mapped");
    const bytes = try os.mapPrivate(path);
    defer os.unmap(bytes);
    try testing.expectEqual(@as(u8, 'x'), bytes[0]);
    try testing.expect(!damaged(bytes));

    // As `cp other mapped` does: opened with O_TRUNC, rewritten shorter.
    try os.writeFile(path, "y");
    const before = replacedPages();
    // Each page past the end used to be a SIGBUS.
    var sum: usize = 0;
    for (bytes[page..]) |byte| sum += byte;
    try testing.expectEqual(@as(usize, 0), sum);
    try testing.expect(damaged(bytes));
    try testing.expectEqual(before + 7, replacedPages());
    // The zeros are writable, as the private mapping was.
    bytes[bytes.len - 1] = 1;
}

test "a SIGBUS outside the registered mappings still kills" {
    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    const page = std.heap.pageSize();
    const data = try testing.allocator.alloc(u8, 4 * page);
    defer testing.allocator.free(data);
    @memset(data, 'x');
    try test_dir.write("unguarded", data);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try test_dir.path(&path_buffer, "unguarded");
    // Installed, as by any mapping `file.zig` makes.
    const guarded = try os.mapPrivate(path);
    os.unmap(guarded);

    const fork_result = linux.fork();
    try testing.expectEqual(.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        // Zig's handler would print a stack trace first: the default here.
        previous = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        const fd = os.openRegular(path) catch linux.exit_group(2);
        const mapped = linux.mmap(null, data.len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (linux.errno(mapped) != .SUCCESS) linux.exit_group(3);
        os.writeFile(path, "") catch linux.exit_group(4);
        const bytes: [*]const volatile u8 = @ptrFromInt(mapped);
        linux.exit_group(bytes[2 * page]);
    }
    const pid: linux.pid_t = @intCast(fork_result);
    var status: i32 = 0;
    while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
    const status_bits: u32 = @bitCast(status);
    try testing.expect(linux.W.IFSIGNALED(status_bits));
    try testing.expectEqual(linux.SIG.BUS, linux.W.TERMSIG(status_bits));
}

test "a registration is undone by unmap, and slots are reused" {
    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    try test_dir.write("small", "abc");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try test_dir.path(&path_buffer, "small");
    for (0..slots_max + 8) |_| {
        const bytes = try os.mapPrivate(path);
        try testing.expect(find(@intFromPtr(bytes.ptr)) != null);
        os.unmap(bytes);
        try testing.expect(find(@intFromPtr(bytes.ptr)) == null);
    }
}
