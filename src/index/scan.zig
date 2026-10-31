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
const paths = @import("paths.zig");
const assert = std.debug.assert;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Builder = store_mod.Builder;
const Pool = @import("Pool.zig");
const Watcher = @import("Watcher.zig");
const sys = @import("os");

pub const Config = struct {
    roots: []const []const u8,
    /// Directory names never opened. "a/b" means "b inside a dir ending in a".
    skip: []const []const u8 = &skip_default,
    /// Opened only if they do not contain CACHEDIR.TAG.
    cachedir_probe: []const []const u8 = &.{
        "target",
        "build",
        ".cache",
        "Cache",
        "cache",
        "dist",
    },
    depth_max: u16 = std.math.maxInt(u16),
    /// Whether a root may be a link to a folder ($HOME often is). Nothing
    /// below a root is ever followed; a folder that appeared after the scan
    /// is scanned as a root, and must not be followed either.
    follow_roots: bool = true,
    /// Stops after the level that passes this many entries (and says so in
    /// `Stats.truncated`): past it the caller rescans instead.
    entries_max: usize = std.math.maxInt(usize),
};

pub const skip_default = [_][]const u8{
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
    directories: u64 = 0,
    errors: u64 = 0,
    elapsed_ns: u64 = 0,
    /// Stopped at `Config.entries_max`: the store holds part of the tree.
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

    fn deinit(batch: *Batch, gpa: std.mem.Allocator) void {
        batch.names.deinit(gpa);
        batch.ends.deinit(gpa);
        batch.flags.deinit(gpa);
    }
};

const LevelContext = struct {
    gpa: std.mem.Allocator,
    config: *const Config,
    frontier: []const Frontier,
    batches: []Batch,
    /// The roots' level, with `Config.follow_roots`.
    follow: bool,
};

/// One level of the walk: how deep its entries are, and whether the
/// folders among them are read next.
const Level = struct { depth: u16, descend: bool };

/// Adds what one level's folders hold to the index, and the folders among
/// it to `next` (when the walk descends from this level).
fn addLevel(
    gpa: std.mem.Allocator,
    builder: *Builder,
    frontier: []const Frontier,
    batches: []const Batch,
    level: Level,
    next: *std.ArrayList(Frontier),
    stats: *Stats,
) std.mem.Allocator.Error!void {
    for (frontier, batches) |parent, *batch| {
        stats.errors += batch.errors;
        var start: usize = 0;
        for (batch.ends.items, batch.flags.items) |end, flags_read| {
            const name = batch.names.items[start..end];
            start = end;
            // Hidden is inherited: everything under a dot-dir is noise
            // even if its own name has no dot.
            const flags = if (parent.hidden) flags_read | store_mod.flag_hidden else flags_read;
            const id = try builder.push(gpa, name, parent.id, flags, level.depth);
            if (flags & store_mod.flag_dir == 0) {
                stats.files += 1;
                continue;
            }
            stats.directories += 1;
            if (!level.descend) continue;
            const separator = paths.separatorAfter(parent.path);
            const child = try gpa.printSentinel("{s}{s}{s}", .{ parent.path, separator, name }, 0);
            errdefer gpa.free(child);
            try next.append(gpa, .{
                .id = id,
                .path = child,
                .hidden = flags & store_mod.flag_hidden != 0,
            });
        }
    }
}

/// Scans `config.roots`. With a watcher, each directory is watched *before*
/// it is read: a change is then either in the read or arrives as an event,
/// never lost in between (scanning first and arming later leaves a blind
/// window as long as the arming).
pub fn scan(
    gpa: std.mem.Allocator,
    pool: *Pool,
    config: *const Config,
    watcher: ?*Watcher,
    stats: ?*Stats,
) std.mem.Allocator.Error!Store {
    const start_ns = sys.monotonicNs();
    var totals: Stats = .{};
    var builder: Builder = .empty;
    errdefer builder.deinit(gpa);

    var frontier: std.ArrayList(Frontier) = .empty;
    defer freeFrontier(gpa, &frontier);
    try addRoots(gpa, &builder, config.roots, &frontier, &totals);

    var depth: u16 = 1;
    while (frontier.items.len > 0 and depth <= config.depth_max) : (depth +|= 1) {
        const follow = depth == 1 and config.follow_roots;
        if (watcher) |inotify| {
            const placement: Watcher.Placement = if (follow) .root else .below_root;
            for (frontier.items) |folder| {
                try inotify.watchBestEffort(gpa, folder.path, folder.id, placement);
            }
        }
        const batches = try readLevel(gpa, pool, config, frontier.items, follow);
        defer freeBatches(gpa, batches);

        var next: std.ArrayList(Frontier) = .empty;
        errdefer freeFrontier(gpa, &next);
        const level: Level = .{ .depth = depth, .descend = depth < config.depth_max };
        try addLevel(gpa, &builder, frontier.items, batches, level, &next, &totals);
        freeFrontier(gpa, &frontier);
        frontier = next;
        if (builder.len() > config.entries_max) {
            totals.truncated = true;
            break;
        }
    }

    totals.elapsed_ns = sys.monotonicNs() - start_ns;
    if (stats) |stats_out| stats_out.* = totals;
    return builder.finish(gpa);
}

/// Level 0: the roots, whose "name" is their absolute path. Each becomes a
/// folder of `frontier`.
fn addRoots(
    gpa: std.mem.Allocator,
    builder: *Builder,
    roots: []const []const u8,
    frontier: *std.ArrayList(Frontier),
    totals: *Stats,
) std.mem.Allocator.Error!void {
    for (roots) |root| {
        const id = try builder.push(gpa, root, store_mod.no_parent, store_mod.flag_dir, 0);
        totals.directories += 1;
        try frontier.append(gpa, .{
            .id = id,
            .path = try gpa.dupeSentinel(u8, root, 0),
            .hidden = false,
        });
    }
}

/// Frees the paths of `frontier`'s folders and the list itself.
fn freeFrontier(gpa: std.mem.Allocator, frontier: *std.ArrayList(Frontier)) void {
    for (frontier.items) |folder| gpa.free(folder.path);
    frontier.deinit(gpa);
}

/// Reads every folder of `frontier` on the pool, into one batch each, in
/// the frontier's order. The caller owns the batches: `freeBatches`.
fn readLevel(
    gpa: std.mem.Allocator,
    pool: *Pool,
    config: *const Config,
    frontier: []const Frontier,
    follow: bool,
) std.mem.Allocator.Error![]Batch {
    const batches = try gpa.alloc(Batch, frontier.len);
    for (batches) |*batch| batch.* = .{};
    var context: LevelContext = .{
        .gpa = gpa,
        .config = config,
        .frontier = frontier,
        .batches = batches,
        .follow = follow,
    };
    pool.run(frontier.len, &context, readLevelCallback);
    return batches;
}

fn freeBatches(gpa: std.mem.Allocator, batches: []Batch) void {
    for (batches) |*batch| batch.deinit(gpa);
    gpa.free(batches);
}

/// One folder of `readLevel`, on a pool thread.
fn readLevelCallback(context: *LevelContext, i: usize) void {
    const batch = &context.batches[i];
    const follow = context.follow;
    readDir(context.gpa, context.frontier[i].path, context.config, follow, batch) catch {
        batch.errors += 1;
    };
    sortBatch(context.gpa, batch) catch {
        // Unsorted, `Store.findChild` would miss names: nothing at all.
        batch.deinit(context.gpa);
        batch.* = .{ .errors = batch.errors + 1 };
    };
}

/// Orders one folder's entries by name, so that `Store.findChild` (once
/// per inotify event, under the lock) is a binary search instead of a walk
/// over every sibling (100k names per event in a folder of 100k files).
fn sortBatch(gpa: std.mem.Allocator, batch: *Batch) std.mem.Allocator.Error!void {
    const names_count = batch.ends.items.len;
    if (names_count < 2) return;
    const Order = struct {
        batch: *const Batch,
        fn name(order: @This(), i: u32) []const u8 {
            const start = if (i == 0) 0 else order.batch.ends.items[i - 1];
            return order.batch.names.items[start..order.batch.ends.items[i]];
        }
        fn lessThan(order: @This(), a: u32, b: u32) bool {
            return std.mem.order(u8, order.name(a), order.name(b)) == .lt;
        }
    };
    const order: Order = .{ .batch = batch };
    var in_order = true;
    for (1..names_count) |i| {
        in_order = in_order and !order.lessThan(@intCast(i), @intCast(i - 1));
    }
    if (in_order) return;
    const permutation = try gpa.alloc(u32, names_count);
    defer gpa.free(permutation);
    for (permutation, 0..) |*position, i| position.* = @intCast(i);
    std.mem.sort(u32, permutation, order, Order.lessThan);
    var sorted: Batch = .{ .errors = batch.errors };
    errdefer sorted.deinit(gpa);
    try sorted.names.ensureTotalCapacity(gpa, batch.names.items.len);
    try sorted.ends.ensureTotalCapacity(gpa, names_count);
    try sorted.flags.ensureTotalCapacity(gpa, names_count);
    for (permutation) |i| {
        sorted.names.appendSliceAssumeCapacity(order.name(i));
        sorted.ends.appendAssumeCapacity(@intCast(sorted.names.items.len));
        sorted.flags.appendAssumeCapacity(batch.flags.items[i]);
    }
    batch.deinit(gpa);
    batch.* = sorted;
}

fn readDir(
    gpa: std.mem.Allocator,
    path: [:0]const u8,
    config: *const Config,
    follow: bool,
    batch: *Batch,
) !void {
    const open = if (follow) &sys.openDir else &sys.openDirNoFollow;
    const fd = open(path) catch {
        batch.errors += 1;
        return;
    };
    defer sys.close(fd);
    var entries: sys.DirIter = .{ .fd = fd };
    while (try entries.next()) |entry| {
        var kind = entry.kind;
        if (kind == sys.Kind.unknown) {
            var full_path_buffer: paths.Buffer = undefined;
            const full_path = std.mem.printSentinel(
                &full_path_buffer,
                "{s}/{s}",
                .{ path, entry.name },
                0,
            ) catch continue;
            kind = sys.kindOf(full_path);
        }
        var flags: u8 = 0;
        // Dot-dirs and caches are noise: searchable, ranked low, and the
        // flag is inherited by everything below ("~/orca/skein-zig-pkg-cache"
        // READMEs outranked the user's own).
        if (hiddenByName(entry.name)) flags |= store_mod.flag_hidden;
        if (kind == sys.Kind.symlink) flags |= store_mod.flag_symlink;
        // A skipped directory is still indexed (searchable), just not opened.
        const descend = kind == sys.Kind.dir and shouldDescend(path, entry.name, config);
        if (descend) flags |= store_mod.flag_dir;
        try batch.names.appendSlice(gpa, entry.name);
        try batch.ends.append(gpa, @intCast(batch.names.items.len));
        try batch.flags.append(gpa, flags);
    }
}
/// Whether `name` hides itself and what is below it: a dot-name, or one
/// that says "cache". The scan sets `flag_hidden` by it, and so does `Live`
/// for what appears after the scan.
/// A name with this in it, in any case, is hidden: "cache", "Cache",
/// "ShaderCache", "__pycache__".
const hidden_word = "cache";

pub fn hiddenByName(name: []const u8) bool {
    assert(name.len > 0);
    if (name[0] == '.') return true;
    return std.ascii.findIgnoreCase(name, hidden_word) != null;
}

/// Whether directory `name` in `parent` is opened, or only indexed: the
/// `skip` rules, and caches marked by a CACHEDIR.TAG. The scan decides by
/// it, and so does `Live` for a directory created after the scan.
pub fn shouldDescend(parent: []const u8, name: []const u8, config: *const Config) bool {
    for (config.skip) |rule| {
        if (std.mem.findScalarLast(u8, rule, '/')) |slash| {
            // "a/b": a directory `b` inside one whose path ends in `a`.
            const rule_name = rule[slash + 1 ..];
            const rule_parent = rule[0..slash];
            if (!std.mem.eql(u8, rule_name, name)) continue;
            if (std.mem.endsWith(u8, parent, rule_parent)) return false;
        } else {
            if (std.mem.eql(u8, rule, name)) return false;
        }
    }
    for (config.cachedir_probe) |probe| {
        if (!std.mem.eql(u8, probe, name)) continue;
        // One stat, only for the handful of suspicious names.
        var tag_path_buffer: paths.Buffer = undefined;
        const tag = std.mem.printSentinel(
            &tag_path_buffer,
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
    temporary: testing.TmpDir,
    /// The temp dir's absolute path is `root_path[0..root_length]` (a
    /// length, not a slice: the struct is returned by value).
    root_path: paths.Buffer = undefined,
    root_length: usize = 0,

    fn init() !ScanTree {
        var tree: ScanTree = .{ .temporary = testing.tmpDir(.{}) };
        tree.root_length = (try sys.tmpDirAbs(&tree.temporary, &tree.root_path)).len;
        return tree;
    }

    fn path(tree: *const ScanTree, path_buffer: []u8, relative: []const u8) [:0]const u8 {
        const directory = tree.root_path[0..tree.root_length];
        const parts = .{ directory, relative };
        return std.mem.printSentinel(path_buffer, "{s}/{s}", parts, 0) catch unreachable;
    }

    fn file(tree: *const ScanTree, relative: []const u8) void {
        var path_buffer: paths.Buffer = undefined;
        const file_path = tree.path(&path_buffer, relative);
        const parent_length = std.mem.findScalarLast(u8, file_path, '/') orelse 0;
        sys.mkdirP(file_path[0..parent_length]) catch unreachable;
        sys.writeFile(file_path, "x") catch unreachable;
    }

    fn scanOf(
        tree: *const ScanTree,
        root: []const u8,
        config_template: Config,
        stats: ?*Stats,
    ) !Store {
        const pool = try Pool.create(testing.allocator, testing.io, 2);
        defer pool.destroy();
        var path_buffer: paths.Buffer = undefined;
        const roots = [_][]const u8{tree.path(&path_buffer, root)};
        var config = config_template;
        config.roots = &roots;
        return scan(testing.allocator, pool, &config, null, stats);
    }

    /// Entries named `name` anywhere in `store`.
    fn named(store: *const Store, name: []const u8) usize {
        var count: usize = 0;
        for (0..store.len()) |i| {
            count += @intFromBool(std.mem.eql(u8, store.name(@intCast(i)), name));
        }
        return count;
    }
};

test "scan: a root may be a link, nothing below one is followed" {
    var tree = try ScanTree.init();
    defer tree.temporary.cleanup();
    tree.file("real/inside.txt");
    tree.file("other/secret.txt");
    var target_buffer: paths.Buffer = undefined;
    var link_buffer: paths.Buffer = undefined;
    const linux = std.os.linux;
    const home = linux.symlink(tree.path(&target_buffer, "real"), tree.path(&link_buffer, "home"));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(home));
    const to_other = tree.path(&link_buffer, "real/to_other");
    const inside = linux.symlink(tree.path(&target_buffer, "other"), to_other);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(inside));

    var store = try tree.scanOf("home", .{ .roots = &.{} }, null);
    defer store.deinit(testing.allocator);
    try testing.expectEqual(1, ScanTree.named(&store, "inside.txt"));
    // The link inside is an entry, not a folder.
    const link = store.findChild(0, "to_other").?;
    try testing.expect(!store.isDir(link));
    try testing.expect(store.flags()[link] & store_mod.flag_symlink != 0);
    try testing.expectEqual(0, ScanTree.named(&store, "secret.txt"));

    // Not even the root, when it is a folder that appeared after the scan.
    var stats: Stats = .{};
    var unfollowed = try tree.scanOf("home", .{ .roots = &.{}, .follow_roots = false }, &stats);
    defer unfollowed.deinit(testing.allocator);
    try testing.expectEqual(1, unfollowed.len());
    try testing.expectEqual(1, stats.errors);
}

test "scan: each folder's entries come sorted by name" {
    var tree = try ScanTree.init();
    defer tree.temporary.cleanup();
    const names = [_][]const u8{ "zeta", "Alpha", "mid.rs", "beta", "_x", "Zeta", "a" };
    for (names) |name| {
        var relative: [256]u8 = undefined;
        tree.file(try std.mem.print(&relative, "r/{s}", .{name}));
        tree.file(try std.mem.print(&relative, "r/sub/{s}", .{name}));
    }
    var store = try tree.scanOf("r", .{ .roots = &.{} }, null);
    defer store.deinit(testing.allocator);
    const sub = store.findChild(0, "sub").?;
    for ([_]u32{ 0, sub }) |directory| {
        const range = store.children(directory);
        var id = range.lo + 1;
        while (id < range.hi) : (id += 1) {
            try testing.expect(std.mem.order(u8, store.name(id - 1), store.name(id)) == .lt);
        }
        for (names) |name| {
            const child = store.findChild(directory, name).?;
            try testing.expectEqualStrings(name, store.name(child));
        }
    }
}

test "scan: stops past entries_max and says so" {
    var tree = try ScanTree.init();
    defer tree.temporary.cleanup();
    tree.file("r/a/b/c/d/deep.txt");
    tree.file("r/one.txt");
    tree.file("r/two.txt");
    var stats: Stats = .{};
    var store = try tree.scanOf("r", .{ .roots = &.{}, .entries_max = 3 }, &stats);
    defer store.deinit(testing.allocator);
    try testing.expect(stats.truncated);
    // The root and its three entries.
    try testing.expectEqual(4, store.len());
    var all_stats: Stats = .{};
    var all = try tree.scanOf("r", .{ .roots = &.{} }, &all_stats);
    defer all.deinit(testing.allocator);
    try testing.expect(!all_stats.truncated);
    try testing.expectEqual(1, ScanTree.named(&all, "deep.txt"));
}
