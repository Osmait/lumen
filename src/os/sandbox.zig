//! Programs run on untrusted input (pdftotext and unzip on a downloaded
//! document: `child.Options.sandbox`), started and confined here: forked
//! by hand, because std.process.spawn runs nothing in the child before exec.
//!
//! What the program gets, each part best effort (a kernel without one runs
//! the program under the others, never fails it):
//!
//!   - No new privileges (a setuid program does not gain any), which the
//!     next two need.
//!   - Landlock: no file or folder created, written, truncated, removed,
//!     renamed or linked anywhere, no TCP, no signal nor abstract socket
//!     out of the sandbox, no ioctl on a device it opens. Reads stay open:
//!     the tools load libraries, fonts and locale data from wherever the
//!     distribution (or Nix, Homebrew) put them, and what they read can
//!     only reach Lumen's pipe.
//!   - seccomp: no socket at all (TCP, the session bus: Landlock does not
//!     cover connecting to a socket file), no ptrace, io_uring, keyrings,
//!     BPF nor perf; no chmod, chown, xattrs or times (Landlock does not
//!     cover metadata), no truncate by path (Landlock covers it from ABI 3).
//!   - A session of its own (no controlling terminal to type into), its
//!     resource limits and priority set before exec, killed if Lumen dies.
//!
//! Between fork and exec the child makes raw system calls only: the daemon
//! has other threads, and a lock one of them held at the fork (malloc's)
//! would never be released in the child.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const os = @import("root.zig");
const child = @import("child.zig");

/// Searched when the environment names no PATH (glibc's default).
const default_search_path = "/usr/local/bin:/usr/bin:/bin";

/// Most of /proc/self/environ read to find PATH.
const environ_bytes_max = 1 << 20;

/// Starts `argv` confined, with an empty environment, its stdin, stdout and
/// stderr as `options` says (as `std.process.spawn` would for `child.run`),
/// in a process group of its own. The program is searched on Lumen's PATH.
pub fn spawn(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    options: *const child.Options,
) child.Error!std.process.Child {
    assert(argv.len > 0);
    assert(options.environ == .empty);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Everything the child uses is made before the fork: it allocates nothing.
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, argv_z) |argument, *slot| slot.* = (try arena.dupeSentinel(u8, argument, 0)).ptr;
    const envp = try arena.allocSentinel(?[*:0]const u8, 0, null);
    const search_path = try searchPath(arena);

    const stdin_bytes = switch (options.stdin) {
        .bytes => |bytes| bytes,
        .fd => "",
    };
    var dev_null: i32 = -1;
    defer if (dev_null >= 0) os.close(dev_null);
    const needs_dev_null = options.stderr == .ignore or
        (options.stdin == .bytes and stdin_bytes.len == 0);
    if (needs_dev_null) dev_null = try openDevNull();

    var stdin_pipe: Pipe = .{};
    defer stdin_pipe.close();
    if (stdin_bytes.len > 0) try stdin_pipe.open();
    var stdout_pipe: Pipe = .{};
    defer stdout_pipe.close();
    try stdout_pipe.open();
    var stderr_pipe: Pipe = .{};
    defer stderr_pipe.close();
    if (options.stderr == .collect) try stderr_pipe.open();
    // Closed (CLOEXEC) by the exec, or carries the errno of what failed.
    var error_pipe: Pipe = .{};
    defer error_pipe.close();
    try error_pipe.open();

    const ruleset = landlockRuleset();
    defer if (ruleset) |fd| os.close(fd);

    const setup: Setup = .{
        .argv = argv_z.ptr,
        .envp = envp.ptr,
        .search_path = search_path,
        .stdin = switch (options.stdin) {
            .fd => |fd| fd,
            .bytes => if (stdin_bytes.len > 0) stdin_pipe.read_end else dev_null,
        },
        .stdout = stdout_pipe.write_end,
        .stderr = if (options.stderr == .collect) stderr_pipe.write_end else dev_null,
        .error_fd = error_pipe.write_end,
        .limits = options.limits,
        .ruleset = ruleset orelse -1,
        .parent = linux.getpid(),
    };
    const fork_result = linux.fork();
    switch (linux.errno(fork_result)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    if (fork_result == 0) setup.runChild();
    const pid: linux.pid_t = @intCast(fork_result);

    // Only the child keeps its ends: EOF on stdout must mean it is done.
    os.close(error_pipe.write_end);
    error_pipe.write_end = -1;
    if (readChildErrno(error_pipe.read_end)) |errno| {
        reap(pid);
        return switch (errno) {
            .NOENT, .NOTDIR => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            .NOMEM, .AGAIN => error.SystemResources,
            .NOEXEC => error.InvalidExe,
            else => error.Unexpected,
        };
    }
    var spawned: std.process.Child = .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = file(stdout_pipe.takeReadEnd()),
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    if (stdin_bytes.len > 0) spawned.stdin = file(stdin_pipe.takeWriteEnd());
    if (options.stderr == .collect) spawned.stderr = file(stderr_pipe.takeReadEnd());
    return spawned;
}

fn file(fd: i32) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Reaps child `pid`, which has exited or is about to.
fn reap(pid: linux.pid_t) void {
    var status: i32 = 0;
    while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
}

fn openDevNull() child.Error!i32 {
    const result = linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(result) != .SUCCESS) return error.Syscall;
    return @intCast(result);
}

/// A pipe whose ends are closed on exec (each end the child needs is
/// duplicated onto 0, 1 or 2), -1 once closed or handed over.
const Pipe = struct {
    read_end: i32 = -1,
    write_end: i32 = -1,

    fn open(pipe: *Pipe) child.Error!void {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
            return error.Syscall;
        }
        pipe.* = .{ .read_end = fds[0], .write_end = fds[1] };
    }

    fn takeReadEnd(pipe: *Pipe) i32 {
        defer pipe.read_end = -1;
        return pipe.read_end;
    }

    fn takeWriteEnd(pipe: *Pipe) i32 {
        defer pipe.write_end = -1;
        return pipe.write_end;
    }

    fn close(pipe: *Pipe) void {
        if (pipe.read_end >= 0) os.close(pipe.read_end);
        if (pipe.write_end >= 0) os.close(pipe.write_end);
        pipe.* = .{};
    }
};

/// The errno the child wrote before exiting, or null when the exec closed
/// the pipe (the program runs).
fn readChildErrno(fd: i32) ?linux.E {
    var code: u32 = 0;
    const bytes: *[4]u8 = @ptrCast(&code);
    var filled: usize = 0;
    while (filled < bytes.len) {
        const result = linux.read(fd, bytes[filled..].ptr, bytes.len - filled);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) break;
                filled += result;
            },
            .INTR => continue,
            else => break,
        }
    }
    if (filled < bytes.len) return null;
    return @fromBackingInt(@intCast(code));
}

/// PATH from Lumen's environment as it started (what std.process.spawn
/// searches too), in `arena`.
fn searchPath(arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    const fd = os.openRegular("/proc/self/environ") catch return default_search_path;
    defer os.close(fd);
    var environ: std.ArrayList(u8) = .empty;
    os.readUpTo(arena, fd, &environ, environ_bytes_max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return default_search_path,
    };
    var entries = std.mem.splitScalar(u8, environ.items, 0);
    while (entries.next()) |entry| {
        if (std.mem.startsWith(u8, entry, "PATH=")) return entry["PATH=".len..];
    }
    return default_search_path;
}

/// What the child needs between fork and exec, all made before the fork.
const Setup = struct {
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    search_path: []const u8,
    stdin: i32,
    stdout: i32,
    stderr: i32,
    error_fd: i32,
    limits: ?child.Limits,
    /// Landlock ruleset to enforce, -1: none (no Landlock).
    ruleset: i32,
    /// Lumen: if it is gone already, the death signal came too early.
    parent: linux.pid_t,

    /// The child: sets itself up, confines itself, runs the program.
    fn runChild(setup: *const Setup) noreturn {
        const redirected = setup.redirect();
        if (redirected != .SUCCESS) setup.fail(redirected);
        // Its own session and process group: no controlling terminal, and
        // a run cut short kills the whole group (`kill(-pid)`).
        _ = linux.setsid();
        _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
        if (linux.getppid() != setup.parent) linux.exit_group(127);
        if (setup.limits) |limits| child.applyLimits(0, limits);
        // A blocked signal stays blocked across exec (SIGTERM, if the
        // forking thread had it blocked).
        const no_signals = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &no_signals, null);
        confine(setup.ruleset);
        setup.fail(setup.exec());
    }

    /// Puts the program's stdin, stdout and stderr on 0, 1 and 2. Each goes
    /// through a descriptor above 2 first: one of them may be 0, 1 or 2
    /// already (a daemon started with its standard streams closed).
    /// `.SUCCESS`, or the errno of the call that failed.
    fn redirect(setup: *const Setup) linux.E {
        const sources = [3]i32{ setup.stdin, setup.stdout, setup.stderr };
        var high: [3]i32 = undefined;
        for (sources, &high) |source, *copy| {
            const result = linux.fcntl(source, linux.F.DUPFD_CLOEXEC, 3);
            const errno = linux.errno(result);
            if (errno != .SUCCESS) return errno;
            copy.* = @intCast(result);
        }
        for (high, 0..) |source, target| {
            const errno = linux.errno(linux.dup2(source, @intCast(target)));
            if (errno != .SUCCESS) return errno;
        }
        return .SUCCESS;
    }

    /// Execs the program, searching `search_path` when its name has no
    /// slash; the errno of the attempt that tells most when none runs.
    fn exec(setup: *const Setup) linux.E {
        const name = std.mem.span(setup.argv[0].?);
        if (std.mem.findScalar(u8, name, '/') != null) {
            return linux.errno(linux.execve(name, setup.argv, setup.envp));
        }
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var result: linux.E = .NOENT;
        var folders = std.mem.tokenizeScalar(u8, setup.search_path, ':');
        while (folders.next()) |folder| {
            if (folder.len + 1 + name.len + 1 > path_buffer.len) continue;
            @memcpy(path_buffer[0..folder.len], folder);
            path_buffer[folder.len] = '/';
            @memcpy(path_buffer[folder.len + 1 ..][0..name.len], name);
            path_buffer[folder.len + 1 + name.len] = 0;
            const path: [*:0]const u8 = @ptrCast(&path_buffer);
            switch (linux.errno(linux.execve(path, setup.argv, setup.envp))) {
                // Found but not runnable here: tell that rather than missing.
                .ACCES, .PERM => result = .ACCES,
                .NOENT, .NOTDIR => {},
                else => |errno| return errno,
            }
        }
        return result;
    }

    /// Tells the parent why the program could not run, and exits.
    fn fail(setup: *const Setup, errno: linux.E) noreturn {
        const code: u32 = @backingInt(errno);
        const bytes: *const [4]u8 = @ptrCast(&code);
        _ = linux.write(setup.error_fd, bytes, bytes.len);
        linux.exit_group(127);
    }
};

/// No new privileges, then the Landlock `ruleset` (-1: none) and the
/// seccomp filter, on the calling process. Each is skipped where the
/// kernel lacks it. Raw system calls only (it runs between fork and exec).
fn confine(ruleset: i32) void {
    _ = linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (ruleset >= 0) _ = linux.syscall2(.landlock_restrict_self, @intCast(ruleset), 0);
    if (audit_arch == 0) return;
    const program: SockFprog = .{ .len = seccomp_filter.len, .filter = &seccomp_filter };
    _ = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &program);
}

// Landlock (include/uapi/linux/landlock.h).

const landlock_create_ruleset_version = 1 << 0;
const landlock_rule_path_beneath = 1;

const access_fs = struct {
    const write_file = 1 << 1;
    const remove_dir = 1 << 4;
    const remove_file = 1 << 5;
    const make_char = 1 << 6;
    const make_dir = 1 << 7;
    const make_reg = 1 << 8;
    const make_sock = 1 << 9;
    const make_fifo = 1 << 10;
    const make_block = 1 << 11;
    const make_sym = 1 << 12;
    /// ABI 2.
    const refer = 1 << 13;
    /// ABI 3.
    const truncate = 1 << 14;
    /// ABI 5.
    const ioctl_dev = 1 << 15;
};

/// ABI 4.
const access_net_bind_tcp = 1 << 0;
const access_net_connect_tcp = 1 << 1;
/// ABI 6.
const scope_abstract_unix_socket = 1 << 0;
const scope_signal = 1 << 1;

const RulesetAttr = extern struct {
    handled_access_fs: u64,
    /// ABI 4; zero before (the kernel takes a longer struct whose tail is zero).
    handled_access_net: u64 = 0,
    /// ABI 6.
    scoped: u64 = 0,
};

const PathBeneathAttr = extern struct {
    allowed_access: u64 align(1),
    parent_fd: i32 align(1),
};

/// Landlock's ABI version, 0 when the kernel has none (or it is disabled).
pub fn landlockAbi() u32 {
    const result = linux.syscall3(.landlock_create_ruleset, 0, 0, landlock_create_ruleset_version);
    if (linux.errno(result) != .SUCCESS) return 0;
    return @intCast(result);
}

/// What the confined program may not do, as far as this kernel's Landlock
/// can say it: an open ruleset (closed by the caller), null without
/// Landlock. Reading and running files are not handled, so stay allowed.
fn landlockRuleset() ?i32 {
    const abi = landlockAbi();
    if (abi == 0) return null;
    var handled_fs: u64 = access_fs.write_file | access_fs.remove_dir | access_fs.remove_file |
        access_fs.make_char | access_fs.make_dir | access_fs.make_reg | access_fs.make_sock |
        access_fs.make_fifo | access_fs.make_block | access_fs.make_sym;
    if (abi >= 2) handled_fs |= access_fs.refer;
    if (abi >= 3) handled_fs |= access_fs.truncate;
    if (abi >= 5) handled_fs |= access_fs.ioctl_dev;
    var attr: RulesetAttr = .{ .handled_access_fs = handled_fs };
    if (abi >= 4) attr.handled_access_net = access_net_bind_tcp | access_net_connect_tcp;
    if (abi >= 6) attr.scoped = scope_abstract_unix_socket | scope_signal;
    const result = linux.syscall3(
        .landlock_create_ruleset,
        @intFromPtr(&attr),
        @sizeOf(RulesetAttr),
        0,
    );
    if (linux.errno(result) != .SUCCESS) return null;
    const ruleset: i32 = @intCast(result);
    // Writing to /dev/null is no harm, and some programs open it to drop
    // what they print. Without the rule they get EACCES, nothing worse.
    const null_result = linux.open("/dev/null", .{ .PATH = true, .CLOEXEC = true }, 0);
    if (linux.errno(null_result) == .SUCCESS) {
        const null_fd: i32 = @intCast(null_result);
        defer os.close(null_fd);
        const rule: PathBeneathAttr = .{ .allowed_access = access_fs.write_file, .parent_fd = null_fd };
        _ = linux.syscall4(
            .landlock_add_rule,
            @intCast(ruleset),
            landlock_rule_path_beneath,
            @intFromPtr(&rule),
            0,
        );
    }
    return ruleset;
}

// seccomp: a classic BPF program over `struct seccomp_data` (nr at 0,
// arch at 4).

const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

const bpf_ld_w_abs = 0x00 | 0x00 | 0x20;
const bpf_jeq_k = 0x05 | 0x10 | 0x00;
const bpf_jge_k = 0x05 | 0x30 | 0x00;
const bpf_ret_k = 0x06 | 0x00;
const seccomp_data_nr_offset = 0;
const seccomp_data_arch_offset = 4;
/// x32 system calls on x86_64 (a second table, bit 30 set).
const x32_syscall_bit = 0x40000000;

/// Refused with EACCES. Each where this architecture has it (aarch64 has
/// no chmod, only fchmodat).
const denied_syscalls = [_][]const u8{
    // Sockets: the network, the session bus (its systemd starts anything,
    // unconfined), any Unix socket.
    "socket",
    // Other processes and the kernel's larger surfaces. io_uring would also
    // open sockets past this filter.
    "ptrace",
    "process_vm_readv",
    "process_vm_writev",
    "io_uring_setup",
    "io_uring_enter",
    "io_uring_register",
    "keyctl",
    "add_key",
    "request_key",
    "bpf",
    "perf_event_open",
    "userfaultfd",
    // What Landlock does not cover: metadata, and truncate by path before
    // its ABI 3.
    "truncate",
    "chmod",
    "fchmod",
    "fchmodat",
    "fchmodat2",
    "chown",
    "fchown",
    "lchown",
    "fchownat",
    "utime",
    "utimes",
    "futimesat",
    "utimensat",
    "setxattr",
    "lsetxattr",
    "fsetxattr",
    "setxattrat",
    "removexattr",
    "lremovexattr",
    "fremovexattr",
    "removexattrat",
};

const denied_numbers = blk: {
    var numbers: []const u32 = &.{};
    for (denied_syscalls) |name| {
        if (@hasField(linux.SYS, name)) {
            numbers = numbers ++ .{@as(u32, @intCast(@backingInt(@field(linux.SYS, name))))};
        }
    }
    break :blk numbers;
};

const check_x32 = builtin.cpu.arch == .x86_64;

/// AUDIT_ARCH_* of this build (std's `AUDIT.ARCH.current` does not compile in
/// 0.17.1): the ELF machine, 64-bit and little-endian. Elsewhere no filter.
const audit_arch: u32 = switch (builtin.cpu.arch) {
    .x86_64 => 62 | 0xC0000000,
    .aarch64 => 183 | 0xC0000000,
    .riscv64 => 243 | 0xC0000000,
    else => 0,
};

const seccomp_filter = blk: {
    const head = 4;
    const count = head + @as(usize, @intFromBool(check_x32)) + denied_numbers.len + 2;
    const deny = count - 1;
    var filter: [count]SockFilter = undefined;
    // Another architecture's system calls (i386's through int 0x80) have
    // other numbers: all refused.
    filter[0] = statement(bpf_ld_w_abs, seccomp_data_arch_offset);
    filter[1] = jump(bpf_jeq_k, audit_arch, 1, 0);
    filter[2] = statement(bpf_ret_k, linux.SECCOMP.RET.ERRNO | @as(u32, @backingInt(linux.E.PERM)));
    filter[3] = statement(bpf_ld_w_abs, seccomp_data_nr_offset);
    var at = head;
    if (check_x32) {
        filter[at] = jump(bpf_jge_k, x32_syscall_bit, deny - at - 1, 0);
        at += 1;
    }
    for (denied_numbers) |number| {
        filter[at] = jump(bpf_jeq_k, number, deny - at - 1, 0);
        at += 1;
    }
    filter[at] = statement(bpf_ret_k, linux.SECCOMP.RET.ALLOW);
    filter[deny] = statement(bpf_ret_k, linux.SECCOMP.RET.ERRNO | @as(u32, @backingInt(linux.E.ACCES)));
    break :blk filter;
};

fn statement(code: u16, k: u32) SockFilter {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}

fn jump(code: u16, k: u32, jt: u8, jf: u8) SockFilter {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

/// Whether this kernel takes seccomp filters that return an errno.
pub fn seccompAvailable() bool {
    if (audit_arch == 0) return false;
    const errno_action: u32 = linux.SECCOMP.RET.ERRNO;
    const result = linux.seccomp(linux.SECCOMP.GET_ACTION_AVAIL, 0, &errno_action);
    return linux.errno(result) == .SUCCESS;
}

const testing = std.testing;

fn deadline(duration_ms: u64) u64 {
    return os.monotonicNs() + duration_ms * std.time.ns_per_ms;
}

/// `child.run` of `sh -c script` in the sandbox, as the extractors run.
fn runConfined(script: []const u8) !child.Result {
    return child.run(testing.allocator, testing.io, &.{ "sh", "-c", script }, .{
        .deadline_ns = deadline(5000),
        .environ = .empty,
        .sandbox = true,
        .limits = .{ .memory_bytes_max = 1 << 30, .cpu_s_max = 5 },
    });
}

test "a confined program cannot create, write, empty or remove files" {
    if (landlockAbi() == 0) return error.SkipZigTest;
    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    try test_dir.write("victim.txt", "keep");
    try test_dir.write("other.txt", "keep too");
    try test_dir.mkdir("folder");
    var script_buffer: [2048]u8 = undefined;
    const dir = test_dir.absolute;
    const script = try std.mem.print(&script_buffer,
        \\echo new > '{0s}/new.txt'
        \\true > '{0s}/other.txt'
        \\rm -f '{0s}/victim.txt'
        \\mv '{0s}/other.txt' '{0s}/moved.txt'
        \\mkdir '{0s}/made'
        \\rmdir '{0s}/folder'
        \\ln -s /etc/passwd '{0s}/link'
        \\echo done
    , .{dir});
    var result = try runConfined(script);
    defer result.deinit(testing.allocator);
    // Each command failed and the script went on: it ran confined.
    try testing.expectEqualStrings("done\n", result.stdout);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var head_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("keep", os.readHead(try test_dir.path(&path_buffer, "victim.txt"), &head_buffer));
    try testing.expectEqualStrings("keep too", os.readHead(try test_dir.path(&path_buffer, "other.txt"), &head_buffer));
    for ([_][]const u8{ "new.txt", "moved.txt", "made", "link" }) |name| {
        try testing.expect(!os.exists(try test_dir.path(&path_buffer, name)));
    }
    try testing.expect(os.exists(try test_dir.path(&path_buffer, "folder")));
}

test "a confined program cannot open a socket" {
    if (!seccompAvailable()) return error.SkipZigTest;
    // The confinement as the child gets it, then sockets tried: the exit
    // code has a bit for each that opened.
    const fork_result = linux.fork();
    try testing.expectEqual(.SUCCESS, linux.errno(fork_result));
    if (fork_result == 0) {
        const ruleset = landlockRuleset();
        confine(ruleset orelse -1);
        var opened: u8 = 0;
        const families = [_]u32{ linux.AF.INET, linux.AF.INET6, linux.AF.UNIX, linux.AF.NETLINK };
        for (families, 0..) |family, bit| {
            const result = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(result) == .SUCCESS) opened |= @as(u8, 1) << @intCast(bit);
        }
        linux.exit_group(opened);
    }
    const pid: linux.pid_t = @intCast(fork_result);
    var status: i32 = 0;
    while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
    const status_bits: u32 = @bitCast(status);
    try testing.expect(linux.W.IFEXITED(status_bits));
    try testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(status_bits));
}

test "a confined program cannot connect over TCP, an unconfined one can" {
    if (!seccompAvailable()) return error.SkipZigTest;
    // bash's /dev/tcp; no bash, no test (the fork test above still runs).
    var probe = child.run(testing.allocator, testing.io, &.{ "bash", "-c", "true" }, .{
        .deadline_ns = deadline(5000),
    }) catch return error.SkipZigTest;
    probe.deinit(testing.allocator);

    const listener_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(listener_result));
    const listener: i32 = @intCast(listener_result);
    defer os.close(listener);
    var address: linux.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var address_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try testing.expectEqual(.SUCCESS, linux.errno(linux.bind(listener, @ptrCast(&address), address_len)));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.listen(listener, 8)));
    try testing.expectEqual(.SUCCESS, linux.errno(linux.getsockname(listener, @ptrCast(&address), &address_len)));
    const port = std.mem.bigToNative(u16, address.port);

    var script_buffer: [256]u8 = undefined;
    const script = try std.mem.print(
        &script_buffer,
        "if : 3<>/dev/tcp/127.0.0.1/{d} 2>/dev/null; then echo connected; else echo refused; fi",
        .{port},
    );
    var free = try child.run(testing.allocator, testing.io, &.{ "bash", "-c", script }, .{
        .deadline_ns = deadline(5000),
        .environ = .empty,
    });
    defer free.deinit(testing.allocator);
    try testing.expectEqualStrings("connected\n", free.stdout);
    var confined = try child.run(testing.allocator, testing.io, &.{ "bash", "-c", script }, .{
        .deadline_ns = deadline(5000),
        .environ = .empty,
        .sandbox = true,
    });
    defer confined.deinit(testing.allocator);
    try testing.expectEqualStrings("refused\n", confined.stdout);
}

test "a confined program still reads its input, writes its output and gets its limits" {
    var test_dir: os.TestDir = try .init();
    defer test_dir.deinit();
    try test_dir.write("input.txt", "document text");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const input = try os.openRegular(try test_dir.path(&path_buffer, "input.txt"));
    defer os.close(input);
    var result = try child.run(testing.allocator, testing.io, &.{
        "sh",
        "-c",
        "cat /dev/stdin; echo; cat /proc/self/limits; echo oops >&2; echo x > /dev/null && echo null-ok",
    }, .{
        .stdin = .{ .fd = input },
        .deadline_ns = deadline(5000),
        .environ = .empty,
        .sandbox = true,
        .limits = .{ .memory_bytes_max = 512 << 20, .cpu_s_max = 7 },
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 0), result.code);
    try testing.expect(std.mem.startsWith(u8, result.stdout, "document text\n"));
    try testing.expect(std.mem.find(u8, result.stdout, "536870912") != null);
    try testing.expect(std.mem.endsWith(u8, result.stdout, "null-ok\n"));
    try testing.expectEqualStrings("oops\n", result.stderr);

    // Bytes on stdin, through a pipe, as for a program that is not confined.
    var fed = try child.run(testing.allocator, testing.io, &.{ "wc", "-c" }, .{
        .stdin = .{ .bytes = "12345" },
        .deadline_ns = deadline(5000),
        .environ = .empty,
        .sandbox = true,
    });
    defer fed.deinit(testing.allocator);
    try testing.expectEqualStrings("5", std.mem.trim(u8, fed.stdout, " \n"));
}

test "a confined program that is missing is error.FileNotFound" {
    try testing.expectError(error.FileNotFound, child.run(
        testing.allocator,
        testing.io,
        &.{"lumen-no-such-program-xyz"},
        .{ .deadline_ns = deadline(1000), .environ = .empty, .sandbox = true },
    ));
}

test "a confined run cut short kills what it started" {
    const start_ns = os.monotonicNs();
    var result = try child.run(testing.allocator, testing.io, &.{ "sh", "-c", "sleep 30 & sleep 30" }, .{
        .deadline_ns = deadline(150),
        .environ = .empty,
        .sandbox = true,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(result.timed_out);
    try testing.expect(os.monotonicNs() - start_ns < 2 * std.time.ns_per_s);
}

test "the seccomp filter jumps land on its last instruction" {
    const deny = seccomp_filter.len - 1;
    for (seccomp_filter, 0..) |instruction, at| {
        if (instruction.code != bpf_jeq_k and instruction.code != bpf_jge_k) continue;
        if (at == 1) continue; // The architecture check skips one.
        try testing.expectEqual(deny, at + 1 + instruction.jt);
    }
    try testing.expect(denied_numbers.len >= 20);
}
