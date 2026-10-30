//! Parallel scan of the directory tree.
//!
//!   1. Zero `stat()`: `getdents64` already says what is a directory (d_type).
//!   2. Level by level (BFS); each level read in parallel and merged in
//!      order, so ids are deterministic, parents come before children and the
//!      parent array ends up sorted (what `Store.children` relies on);
//!      each folder's entries are sorted by name (`Store.findChild`).
//!   3. Symlinks are not followed, not even a folder swapped for one between
//!      two levels (opened with O_NOFOLLOW); only a root may be a link.
//!   4. Caches are detected, not guessed: dirs with a suspicious name are
//!      skipped only if they hold a CACHEDIR.TAG.
//!
//! The Rust version measured raw getdents64 7% faster than std's read_dir and
//! dropped it for being `unsafe`; in Zig it is the natural API.

const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Builder = store_mod.Builder;
const Pool = @import("Pool.zig");
const Watcher = @import("Watcher.zig");
const sys = @import("os");

pub const Config = struct {
    roots: []const []const u8,
    /// Directory names never opened. "a/b" means "b inside a dir ending in a".
    skip: []const []const u8 = &default_skip,
    /// Opened only if they do not contain CACHEDIR.TAG.
    cachedir_probe: []const []const u8 = &.{
        "target",
        "build",
        ".cache",
        "Cache",
        "cache",
        "dist",
    },
    max_depth: u16 = std.math.maxInt(u16),
    /// Whether a root may be a link to a folder ($HOME often is). Nothing
    /// below a root is ever followed; a folder that appeared after the scan
    /// is scanned as a root, and must not be followed either.
    follow_roots: bool = true,
    /// Stops after the level that passes this many entries (and says so in
    /// `Stats.truncated`): past it the caller rescans instead.
    max_entries: usize = std.math.maxInt(usize),
};

pub const default_skip = [_][]const u8{
    ".git",               "node_modules",   "__pycache__",     ".mypy_cache",
    ".pytest_cache",      ".ruff_cache",    ".gradle",         ".rustup",
    ".venv",              "site-packages",  ".cargo/registry", ".Trash",
    ".local/share/Trash", ".zig-cache",     "zig-cache",
    // Package caches: read-only copies of other people's code.
          "go/pkg/mod",
    ".npm/_cacache",      ".m2/repository", "zig-pkg",
};

pub const Stats = struct {
    files: u64 = 0,
    dirs: u64 = 0,
    errors: u64 = 0,
    ns: u64 = 0,
    /// Stopped at `Config.max_entries`: the store holds part of the tree.
    truncated: bool = false,
};

const Frontier = struct { id: u32, path: [:0]u8, hidden: bool };

/// One directory's entries: a shared name buffer instead of one allocation
/// per file.
const Batch = struct {
    names: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(u32) = .empty,
    flags: std.ArrayList(u8) = .empty,
    errors: u64 = 0,

    fn deinit(b: *Batch, gpa: std.mem.Allocator) void {
        b.names.deinit(gpa);
        b.ends.deinit(gpa);
        b.flags.deinit(gpa);
    }
};

const LevelCtx = struct {
    gpa: std.mem.Allocator,
    cfg: *const Config,
    frontier: []const Frontier,
    batches: []Batch,
    /// The roots' level, with `Config.follow_roots`.
    follow: bool,
};

/// Scans `cfg.roots`. With a watcher, each directory is watched *before* it
/// is read: a change is then either in the read or arrives as an event,
/// never lost in between (scanning first and arming later leaves a blind
/// window as long as the arming).
/// Adds what one level's folders hold to the index, and the folders among
/// it to `next` (when the walk goes `deeper`).
fn addLevel(
    gpa: std.mem.Allocator,
    b: *Builder,
    frontier: []const Frontier,
    batches: []const Batch,
    depth: u16,
    deeper: bool,
    next: *std.ArrayList(Frontier),
    st: *Stats,
) std.mem.Allocator.Error!void {
    for (frontier, batches) |parent, *batch| {
        st.errors += batch.errors;
        var start: usize = 0;
        for (batch.ends.items, batch.flags.items) |end, fl0| {
            const name = batch.names.items[start..end];
            start = end;
            // Hidden is inherited: everything under a dot-dir is noise
            // even if its own name has no dot.
            const fl = if (parent.hidden) fl0 | store_mod.flag_hidden else fl0;
            const id = try b.push(gpa, name, parent.id, fl, depth);
            if (fl & store_mod.flag_dir == 0) {
                st.files += 1;
                continue;
            }
            st.dirs += 1;
            if (!deeper) continue;
            const sep = if (std.mem.endsWith(u8, parent.path, "/")) "" else "/";
            const child = try gpa.printSentinel("{s}{s}{s}", .{ parent.path, sep, name }, 0);
            errdefer gpa.free(child);
            try next.append(gpa, .{
                .id = id,
                .path = child,
                .hidden = fl & store_mod.flag_hidden != 0,
            });
        }
    }
}

pub fn scan(
    gpa: std.mem.Allocator,
    pool: *Pool,
    cfg: *const Config,
    watcher: ?*Watcher,
    stats: ?*Stats,
) std.mem.Allocator.Error!Store {
    const t0 = sys.monotonicNs();
    var st: Stats = .{};
    var b: Builder = .empty;
    errdefer b.deinit(gpa);

    var frontier: std.ArrayList(Frontier) = .empty;
    defer {
        for (frontier.items) |f| gpa.free(f.path);
        frontier.deinit(gpa);
    }
    // Level 0: the roots, whose "name" is their absolute path.
    for (cfg.roots) |root| {
        const id = try b.push(gpa, root, store_mod.no_parent, store_mod.flag_dir, 0);
        st.dirs += 1;
        try frontier.append(gpa, .{
            .id = id,
            .path = try gpa.dupeSentinel(u8, root, 0),
            .hidden = false,
        });
    }

    var depth: u16 = 1;
    while (frontier.items.len > 0 and depth <= cfg.max_depth) : (depth +|= 1) {
        const follow = depth == 1 and cfg.follow_roots;
        if (watcher) |w| for (frontier.items) |f| {
            (if (follow) w.watchRoot(gpa, f.path, f.id) else w.watch(gpa, f.path, f.id)) catch {};
        };

        const batches = try gpa.alloc(Batch, frontier.items.len);
        defer {
            for (batches) |*bt| bt.deinit(gpa);
            gpa.free(batches);
        }
        for (batches) |*bt| bt.* = .{};
        var ctx: LevelCtx = .{
            .gpa = gpa,
            .cfg = cfg,
            .frontier = frontier.items,
            .batches = batches,
            .follow = follow,
        };
        pool.run(frontier.items.len, &ctx, readOne);

        var next: std.ArrayList(Frontier) = .empty;
        errdefer {
            for (next.items) |f| gpa.free(f.path);
            next.deinit(gpa);
        }
        try addLevel(gpa, &b, frontier.items, batches, depth, depth < cfg.max_depth, &next, &st);
        for (frontier.items) |f| gpa.free(f.path);
        frontier.deinit(gpa);
        frontier = next;
        if (b.len() > cfg.max_entries) {
            st.truncated = true;
            break;
        }
    }

    st.ns = sys.monotonicNs() - t0;
    if (stats) |s| s.* = st;
    return b.finish(gpa);
}

fn readOne(ctx: *LevelCtx, i: usize) void {
    const batch = &ctx.batches[i];
    readDir(ctx.gpa, ctx.frontier[i].path, ctx.cfg, ctx.follow, batch) catch {
        batch.errors += 1;
    };
    sortBatch(ctx.gpa, batch) catch {
        // Unsorted, `Store.findChild` would miss names: nothing at all.
        batch.deinit(ctx.gpa);
        batch.* = .{ .errors = batch.errors + 1 };
    };
}

/// Orders one folder's entries by name, so that `Store.findChild` (once
/// per inotify event, under the lock) is a binary search instead of a walk
/// over every sibling (100k names per event in a folder of 100k files).
fn sortBatch(gpa: std.mem.Allocator, batch: *Batch) std.mem.Allocator.Error!void {
    const n = batch.ends.items.len;
    if (n < 2) return;
    const Order = struct {
        b: *const Batch,
        fn name(o: @This(), i: u32) []const u8 {
            const start = if (i == 0) 0 else o.b.ends.items[i - 1];
            return o.b.names.items[start..o.b.ends.items[i]];
        }
        fn lt(o: @This(), x: u32, y: u32) bool {
            return std.mem.order(u8, o.name(x), o.name(y)) == .lt;
        }
    };
    const o: Order = .{ .b = batch };
    var sorted = true;
    for (1..n) |i| sorted = sorted and !o.lt(@intCast(i), @intCast(i - 1));
    if (sorted) return;
    const perm = try gpa.alloc(u32, n);
    defer gpa.free(perm);
    for (perm, 0..) |*p, i| p.* = @intCast(i);
    std.mem.sort(u32, perm, o, Order.lt);
    var out: Batch = .{ .errors = batch.errors };
    errdefer out.deinit(gpa);
    try out.names.ensureTotalCapacity(gpa, batch.names.items.len);
    try out.ends.ensureTotalCapacity(gpa, n);
    try out.flags.ensureTotalCapacity(gpa, n);
    for (perm) |i| {
        out.names.appendSliceAssumeCapacity(o.name(i));
        out.ends.appendAssumeCapacity(@intCast(out.names.items.len));
        out.flags.appendAssumeCapacity(batch.flags.items[i]);
    }
    batch.deinit(gpa);
    batch.* = out;
}

fn readDir(
    gpa: std.mem.Allocator,
    path: [:0]const u8,
    cfg: *const Config,
    follow: bool,
    batch: *Batch,
) !void {
    const open = if (follow) &sys.openDir else &sys.openDirNoFollow;
    const fd = open(path) catch {
        batch.errors += 1;
        return;
    };
    defer sys.close(fd);
    var it: sys.DirIter = .{ .fd = fd };
    while (try it.next()) |e| {
        var kind = e.kind;
        if (kind == sys.Kind.unknown) {
            var buf: [4096]u8 = undefined;
            const full = std.mem.printSentinel(
                &buf,
                "{s}/{s}",
                .{ path, e.name },
                0,
            ) catch continue;
            kind = sys.kindOf(full);
        }
        var fl: u8 = 0;
        // Dot-dirs and caches are noise: searchable, ranked low, and the
        // flag is inherited by everything below ("~/orca/skein-zig-pkg-cache"
        // READMEs outranked the user's own).
        if (e.name[0] == '.' or std.ascii.findIgnoreCase(
            e.name,
            "cache",
        ) != null) fl |= store_mod.flag_hidden;
        if (kind == sys.Kind.symlink) fl |= store_mod.flag_symlink;
        // A skipped directory is still indexed (searchable), just not opened.
        if (kind == sys.Kind.dir and shouldDescend(path, e.name, cfg)) fl |= store_mod.flag_dir;
        try batch.names.appendSlice(gpa, e.name);
        try batch.ends.append(gpa, @intCast(batch.names.items.len));
        try batch.flags.append(gpa, fl);
    }
}

fn shouldDescend(parent: []const u8, name: []const u8, cfg: *const Config) bool {
    for (cfg.skip) |rule| {
        if (std.mem.findScalarLast(u8, rule, '/')) |slash| {
            if (std.mem.eql(
                u8,
                rule[slash + 1 ..],
                name,
            ) and std.mem.endsWith(u8, parent, rule[0..slash])) return false;
        } else if (std.mem.eql(u8, rule, name)) return false;
    }
    for (cfg.cachedir_probe) |probe| {
        if (!std.mem.eql(u8, probe, name)) continue;
        // One stat, only for the handful of suspicious names.
        var buf: [4096]u8 = undefined;
        const tag = std.mem.printSentinel(
            &buf,
            "{s}/{s}/CACHEDIR.TAG",
            .{ parent, name },
            0,
        ) catch return true;
        if (sys.exists(tag)) return false;
    }
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const ScanTree = struct {
    tmp: testing.TmpDir,
    /// The temp dir's absolute path is `buf[0..len]` (a length, not a
    /// slice: the struct is returned by value).
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn init() !ScanTree {
        var t: ScanTree = .{ .tmp = testing.tmpDir(.{}) };
        t.len = (try sys.tmpDirAbs(&t.tmp, &t.buf)).len;
        return t;
    }

    fn path(t: *const ScanTree, buf: []u8, rel: []const u8) [:0]const u8 {
        const dir = t.buf[0..t.len];
        return std.mem.printSentinel(buf, "{s}/{s}", .{ dir, rel }, 0) catch unreachable;
    }

    fn file(t: *const ScanTree, rel: []const u8) void {
        var buf: [4096]u8 = undefined;
        const p = t.path(&buf, rel);
        sys.mkdirP(p[0 .. std.mem.findScalarLast(u8, p, '/') orelse 0]);
        sys.writeFile(p, "x") catch unreachable;
    }

    fn scanOf(t: *const ScanTree, root: []const u8, cfg_in: Config, st: ?*Stats) !Store {
        const pool = try Pool.create(testing.allocator, testing.io, 2);
        defer pool.destroy();
        var buf: [4096]u8 = undefined;
        const roots = [_][]const u8{t.path(&buf, root)};
        var cfg = cfg_in;
        cfg.roots = &roots;
        return scan(testing.allocator, pool, &cfg, null, st);
    }

    /// Entries named `name` anywhere in `s`.
    fn named(s: *const Store, name: []const u8) usize {
        var n: usize = 0;
        for (0..s.len()) |i| n += @intFromBool(std.mem.eql(u8, s.name(@intCast(i)), name));
        return n;
    }
};

test "scan: a root may be a link, nothing below one is followed" {
    var t = try ScanTree.init();
    defer t.tmp.cleanup();
    t.file("real/inside.txt");
    t.file("other/secret.txt");
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    _ = std.os.linux.symlink(t.path(&a, "real"), t.path(&b, "home"));
    _ = std.os.linux.symlink(t.path(&a, "other"), t.path(&b, "real/to_other"));

    var s = try t.scanOf("home", .{ .roots = &.{} }, null);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(1, ScanTree.named(&s, "inside.txt"));
    // The link inside is an entry, not a folder.
    const link = s.findChild(0, "to_other").?;
    try testing.expect(!s.isDir(link) and s.flags()[link] & store_mod.flag_symlink != 0);
    try testing.expectEqual(0, ScanTree.named(&s, "secret.txt"));

    // Not even the root, when it is a folder that appeared after the scan.
    var st: Stats = .{};
    var n = try t.scanOf("home", .{ .roots = &.{}, .follow_roots = false }, &st);
    defer n.deinit(testing.allocator);
    try testing.expectEqual(1, n.len());
    try testing.expectEqual(1, st.errors);
}

test "scan: each folder's entries come sorted by name" {
    var t = try ScanTree.init();
    defer t.tmp.cleanup();
    const names = [_][]const u8{ "zeta", "Alpha", "mid.rs", "beta", "_x", "Zeta", "a" };
    for (names) |n| {
        var buf: [256]u8 = undefined;
        t.file(try std.mem.print(&buf, "r/{s}", .{n}));
        t.file(try std.mem.print(&buf, "r/sub/{s}", .{n}));
    }
    var s = try t.scanOf("r", .{ .roots = &.{} }, null);
    defer s.deinit(testing.allocator);
    const sub = s.findChild(0, "sub").?;
    for ([_]u32{ 0, sub }) |dir| {
        const r = s.children(dir);
        var id = r.lo + 1;
        while (id < r.hi) : (id += 1) try testing.expect(
            std.mem.order(u8, s.name(id - 1), s.name(id)) == .lt,
        );
        for (names) |n| try testing.expectEqualStrings(n, s.name(s.findChild(dir, n).?));
    }
}

test "scan: stops past max_entries and says so" {
    var t = try ScanTree.init();
    defer t.tmp.cleanup();
    t.file("r/a/b/c/d/deep.txt");
    t.file("r/one.txt");
    t.file("r/two.txt");
    var st: Stats = .{};
    var s = try t.scanOf("r", .{ .roots = &.{}, .max_entries = 3 }, &st);
    defer s.deinit(testing.allocator);
    try testing.expect(st.truncated);
    try testing.expectEqual(4, s.len()); // the root and its three entries
    var all_st: Stats = .{};
    var all = try t.scanOf("r", .{ .roots = &.{} }, &all_st);
    defer all.deinit(testing.allocator);
    try testing.expect(!all_st.truncated);
    try testing.expectEqual(1, ScanTree.named(&all, "deep.txt"));
}
