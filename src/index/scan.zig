//! Parallel scan of the directory tree.
//!
//!   1. Zero `stat()`: `getdents64` already says what is a directory (d_type).
//!   2. Level by level (BFS); each level read in parallel and merged in
//!      order, so ids are deterministic, parents come before children and the
//!      parent array ends up sorted (what `Store.children` relies on).
//!   3. Symlinks are not followed.
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
const sys = @import("sys.zig");

pub const Config = struct {
    roots: []const []const u8,
    /// Directory names never opened. "a/b" means "b inside a dir ending in a".
    skip: []const []const u8 = &default_skip,
    /// Opened only if they do not contain CACHEDIR.TAG.
    cachedir_probe: []const []const u8 = &.{ "target", "build", ".cache", "Cache", "cache", "dist" },
    max_depth: u16 = std.math.maxInt(u16),
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

pub const Stats = struct { files: u64 = 0, dirs: u64 = 0, errors: u64 = 0, ns: u64 = 0 };

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
};

/// Scans `cfg.roots`. With a watcher, each directory is watched *before* it
/// is read: a change is then either in the read or arrives as an event,
/// never lost in between (scanning first and arming later leaves a blind
/// window as long as the arming).
pub fn scan(gpa: std.mem.Allocator, pool: *Pool, cfg: *const Config, watcher: ?*Watcher, stats: ?*Stats) std.mem.Allocator.Error!Store {
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
        try frontier.append(gpa, .{ .id = id, .path = try gpa.dupeZ(u8, root), .hidden = false });
    }

    var depth: u16 = 1;
    while (frontier.items.len > 0 and depth <= cfg.max_depth) : (depth +|= 1) {
        if (watcher) |w| {
            for (frontier.items) |f| w.watch(gpa, f.path, f.id) catch {};
        }

        const batches = try gpa.alloc(Batch, frontier.items.len);
        defer {
            for (batches) |*bt| bt.deinit(gpa);
            gpa.free(batches);
        }
        for (batches) |*bt| bt.* = .{};
        var ctx: LevelCtx = .{ .gpa = gpa, .cfg = cfg, .frontier = frontier.items, .batches = batches };
        pool.run(frontier.items.len, &ctx, readOne);

        var next: std.ArrayList(Frontier) = .empty;
        errdefer {
            for (next.items) |f| gpa.free(f.path);
            next.deinit(gpa);
        }
        for (frontier.items, batches) |parent, *batch| {
            st.errors += batch.errors;
            var start: usize = 0;
            for (batch.ends.items, batch.flags.items) |end, fl0| {
                const name = batch.names.items[start..end];
                start = end;
                // Hidden is inherited: everything under a dot-dir is noise
                // even if its own name has no dot.
                const fl = if (parent.hidden) fl0 | store_mod.flag_hidden else fl0;
                const id = try b.push(gpa, name, parent.id, fl, depth);
                if (fl & store_mod.flag_dir != 0) {
                    st.dirs += 1;
                    if (depth < cfg.max_depth) {
                        const child = try std.fmt.allocPrintSentinel(gpa, "{s}{s}{s}", .{ parent.path, if (std.mem.endsWith(u8, parent.path, "/")) "" else "/", name }, 0);
                        try next.append(gpa, .{ .id = id, .path = child, .hidden = fl & store_mod.flag_hidden != 0 });
                    }
                } else st.files += 1;
            }
        }
        for (frontier.items) |f| gpa.free(f.path);
        frontier.deinit(gpa);
        frontier = next;
    }

    st.ns = sys.monotonicNs() - t0;
    if (stats) |s| s.* = st;
    return b.finish(gpa);
}

fn readOne(ctx: *LevelCtx, i: usize) void {
    readDir(ctx.gpa, ctx.frontier[i].path, ctx.cfg, &ctx.batches[i]) catch {
        ctx.batches[i].errors += 1;
    };
}

fn readDir(gpa: std.mem.Allocator, path: [:0]const u8, cfg: *const Config, batch: *Batch) !void {
    const fd = sys.openDir(path) catch {
        batch.errors += 1;
        return;
    };
    defer sys.close(fd);
    var it: sys.DirIter = .{ .fd = fd };
    while (try it.next()) |e| {
        var kind = e.kind;
        if (kind == sys.Kind.unknown) {
            var buf: [4096]u8 = undefined;
            const full = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ path, e.name }, 0) catch continue;
            kind = sys.kindOf(full);
        }
        var fl: u8 = 0;
        // Dot-dirs and caches are noise: searchable, ranked low, and the
        // flag is inherited by everything below ("~/orca/skein-zig-pkg-cache"
        // READMEs outranked the user's own).
        if (e.name[0] == '.' or std.ascii.findIgnoreCase(e.name, "cache") != null) fl |= store_mod.flag_hidden;
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
            if (std.mem.eql(u8, rule[slash + 1 ..], name) and std.mem.endsWith(u8, parent, rule[0..slash])) return false;
        } else if (std.mem.eql(u8, rule, name)) return false;
    }
    for (cfg.cachedir_probe) |probe| {
        if (!std.mem.eql(u8, probe, name)) continue;
        // One stat, only for the handful of suspicious names.
        var buf: [4096]u8 = undefined;
        const tag = std.fmt.bufPrintSentinel(&buf, "{s}/{s}/CACHEDIR.TAG", .{ parent, name }, 0) catch return true;
        if (sys.exists(tag)) return false;
    }
    return true;
}
