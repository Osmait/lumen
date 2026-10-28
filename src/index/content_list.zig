//! What the content index covers: text under $HOME that `rg --files` lists
//! (it honours .gitignore, skips hidden files) and that is at most
//! `content.max_text` bytes, plus PDFs and Office documents (text extracted).
//! ripgrep resolves every .gitignore of a home directory in ~70 ms.

const std = @import("std");
const linux = std.os.linux;
const content = @import("content.zig");
const extract = @import("extract.zig");

/// Package caches and build output: other people's code, or generated.
/// Globs with a slash need `**/` to match below the search root.
const excludes = [_][]const u8{
    "!**/node_modules/**", "!**/.git/**",    "!**/go/pkg/**", "!**/zig-pkg/**",
    "!**/.zig-cache/**",   "!**/zig-out/**", "!**/target/**", "!**/*cache*/**",
    "!**/vendor/**",       "!**/dist/**",    "!**/build/**",  "!*.min.js",
    "!*.map",              "!*.lock",        "!*-lock.json",  "!*.svg",
};

/// Documents to index, sorted by path (stable doc ids between builds).
/// Paths are owned by `arena`.
pub const ListError = std.process.RunError || std.mem.Allocator.Error;

pub fn list(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, root: []const u8, with_documents: bool) ListError![]content.DocIn {
    var argv: std.ArrayList([]const u8) = .empty;
    // --no-ignore-parent: ignore files above the root are not about it (and
    // a checkout's .gitignore patterns like `build/` would hit any dir
    // with that name below).
    // --null: paths end in NUL, the one byte a path cannot contain (a file
    // name with a newline was split into two bogus paths and never indexed).
    try argv.appendSlice(arena, &.{ "rg", "--files", "--null", "--no-messages", "--no-ignore-parent" });
    for (excludes) |g| try argv.appendSlice(arena, &.{ "-g", g });
    // Run inside the root and list ".": rg matches globs against the path it
    // prints, so with the root as argument a root below any excluded name
    // (a home in /srv/build, the tests' .zig-cache/tmp) listed nothing.
    try argv.append(arena, ".");
    // A hung network or FUSE mount under the root must not hang the content
    // service forever: give up after a minute and keep the current index.
    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = root },
        .stdout_limit = .limited(256 << 20),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const sep: []const u8 = if (std.mem.endsWith(u8, root, "/")) "" else "/";
    var docs: std.ArrayList(content.DocIn) = .empty;
    var it = std.mem.tokenizeScalar(u8, res.stdout, 0);
    var zbuf: [4096]u8 = undefined;
    while (it.next()) |line| {
        const rel = if (std.mem.startsWith(u8, line, "./")) line[2..] else line;
        const z = std.mem.printSentinel(&zbuf, "{s}{s}{s}", .{ root, sep, rel }, 0) catch continue;
        const p: []const u8 = z;
        const doc_kind = documentKind(p);
        if (doc_kind and !with_documents) continue;
        if (!doc_kind and binaryByName(p)) continue;
        const st = stat(z, doc_kind) orelse continue;
        try docs.append(arena, .{ .path = try arena.dupe(u8, p), .mtime = st.mtime, .size = st.size, .source = if (doc_kind) .extracted else .plain });
    }
    std.mem.sort(content.DocIn, docs.items, {}, struct {
        fn lt(_: void, a: content.DocIn, b: content.DocIn) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);
    return docs.items;
}

pub const Stat = struct { mtime: i64, size: u64 };

/// A listed file's mtime and size, or null if it is not one to index (any
/// more): not a regular file, or a size out of bounds.
pub fn stat(path: [*:0]const u8, doc_kind: bool) ?Stat {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &stx);
    if (linux.errno(rc) != .SUCCESS or stx.mode & linux.S.IFMT != linux.S.IFREG) return null;
    if (!doc_kind and (stx.size > content.max_text or stx.size < 3)) return null;
    if (doc_kind and stx.size > 64 << 20) return null;
    return .{ .mtime = stx.mtime.sec, .size = stx.size };
}

pub fn documentKind(path: []const u8) bool {
    // The extractor's own test: a document it refuses (an Office lock file,
    // `~$x.docx`) was listed as extracted, never extracted, and checked
    // again on every refresh.
    return extract.kindOf(path) != null;
}

/// Obviously binary by extension: skips opening them at all.
fn binaryByName(path: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".mp4", ".mkv", ".mp3", ".ogg", ".wav", ".zip", ".gz", ".xz", ".zst", ".tar", ".so", ".o", ".a", ".wasm", ".ttf", ".otf", ".woff", ".woff2", ".blend", ".uasset", ".umap", ".exe", ".dll", ".class", ".jar", ".pyc", ".db", ".sqlite", ".bin", ".iso", ".avif", ".heic", ".psd", ".dds", ".ktx", ".glb", ".fbx", ".mov" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return true;
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const sys = @import("sys.zig");

/// A testing tmp dir with its absolute path (`list` takes an absolute root;
/// tests run from the build root).
pub const TestTree = struct {
    tmp: testing.TmpDir,
    abs: []u8,

    pub fn init() !TestTree {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var rel_buf: [256]u8 = undefined;
        const rel = try sys.tmpDirPath(&tmp, &rel_buf);
        const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
        defer testing.allocator.free(cwd);
        return .{ .tmp = tmp, .abs = try testing.allocator.print("{s}/{s}", .{ cwd, rel }) };
    }

    pub fn deinit(t: *TestTree) void {
        testing.allocator.free(t.abs);
        t.tmp.cleanup();
    }

    /// Absolute path of `name` (static buffer per call site is the caller's).
    pub fn path(t: *const TestTree, buf: []u8, name: []const u8) ![:0]u8 {
        return std.mem.printSentinel(buf, "{s}/{s}", .{ t.abs, name }, 0);
    }

    /// Writes `name` (creating parent dirs) with `data`.
    pub fn write(t: *const TestTree, name: []const u8, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const p = try t.path(&buf, name);
        if (std.mem.findScalarLast(u8, p, '/')) |slash| sys.mkdirP(p[0..slash]);
        try sys.writeFile(p, data);
    }

    pub fn mkdir(t: *const TestTree, name: []const u8) !void {
        var buf: [4096]u8 = undefined;
        sys.mkdirP(try t.path(&buf, name));
    }
};

/// `list` relative to the tree, or SkipZigTest without ripgrep.
fn listRel(arena: std.mem.Allocator, t: *const TestTree, with_documents: bool) ![]content.DocIn {
    return list(arena, testing.allocator, testing.io, t.abs, with_documents) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "list: what is indexed and what is excluded" {
    var t = try TestTree.init();
    defer t.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "some text\n";
    const keep = [_][]const u8{
        "notes.md",
        "src/main.zig",
        "src/deep/er/lib.rs",
        "about-cache.txt", // "cache" in a file name, not a dir: kept
        "proj/kept.txt",
        "three.txt", // written with exactly 3 bytes below
        "exactly_max.log", // exactly content.max_text bytes below
    };
    for (keep) |k| try t.write(k, text);
    try t.write("three.txt", "abc");
    const docs = [_][]const u8{ "papers/a.pdf", "reports/b.docx" };
    for (docs) |d| try t.write(d, "not really a document");

    const drop = [_][]const u8{
        "node_modules/pkg/index.js",
        "web/node_modules/pkg/index.js",
        "repo/.git/config.txt",
        // Nested: `!go/pkg/mod` (no `**/`) once excluded nothing and all of
        // ~/go got indexed.
        "home/me/go/pkg/mod/github.com/x/y.go",
        "go/pkg/mod/top.go",
        "a/zig-pkg/dep/build.zig",
        "a/.zig-cache/o/x.zig",
        "a/zig-out/bin/x.txt",
        "rust/target/debug/out.rs",
        "a/vendor/lib.go",
        "a/dist/app.js",
        "a/build/gen.c",
        "x/pip_cache_dir/pkg.py",
        "y/cache/data.txt",
        "web/app.min.js",
        "web/bundle.js.map",
        "Cargo.lock",
        "web/package-lock.json",
        "img/logo.svg",
        ".hidden.txt",
        ".config/app/settings.toml",
        "proj/ignored.txt", // in proj/.gitignore (proj is a repo)
        "proj/gen/out.txt", // gen/ in proj/.gitignore
        "two.txt", // 2 bytes
        "empty.txt",
        "img/photo.png",
        "big.log", // > max_text
    };
    for (drop) |d| try t.write(d, text);
    try t.write("two.txt", "ab");
    try t.write("empty.txt", "");
    // A .gitignore applies inside a git repo only (rg's default; outside a
    // repo it is ignored, which in a home directory is what users expect).
    try t.mkdir("proj/.git");
    try t.write("proj/.gitignore", "ignored.txt\ngen/\n");
    // Sizes without writing the bytes: sparse files.
    var buf: [4096]u8 = undefined;
    for ([_]struct { []const u8, i64 }{ .{ "big.log", content.max_text + 1 }, .{ "exactly_max.log", content.max_text } }) |e| {
        const rc = linux.open(try t.path(&buf, e[0]), .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
        const fd: i32 = @intCast(rc);
        defer sys.close(fd);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, e[1])));
    }

    const got = try listRel(arena, &t, true);

    var want: std.ArrayList([]const u8) = .empty;
    for (keep ++ docs) |k| try want.append(arena, try arena.print("{s}/{s}", .{ t.abs, k }));
    std.mem.sort([]const u8, want.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var got_paths: std.ArrayList([]const u8) = .empty;
    for (got) |d| try got_paths.append(arena, d.path);
    const joined_want = try std.mem.join(arena, "\n", want.items);
    const joined_got = try std.mem.join(arena, "\n", got_paths.items);
    try testing.expectEqualStrings(joined_want, joined_got);

    const now = sys.nowSeconds();
    for (got) |d| {
        try testing.expectEqual(documentKind(d.path), d.source == .extracted);
        try testing.expect(d.mtime > now - 3600 and d.mtime <= now + 1);
        const info = sys.info(try std.mem.printSentinel(&buf, "{s}", .{d.path}, 0)).?;
        try testing.expectEqual(info.size, d.size);
        try testing.expectEqual(info.mtime, d.mtime);
    }
    for (got) |d| {
        if (std.mem.endsWith(u8, d.path, "/exactly_max.log")) try testing.expectEqual(@as(u64, content.max_text), d.size);
    }

    // Without documents: the same minus the PDF and the docx.
    const plain = try listRel(arena, &t, false);
    try testing.expectEqual(got.len - docs.len, plain.len);
    for (plain) |d| try testing.expect(d.source == .plain);
}

test "list: a root below an excluded name still lists" {
    // Globs are matched against the path rg prints: with the root as rg's
    // argument, a root like this one (.zig-cache/tmp/...) or /srv/build/me
    // listed nothing.
    var t = try TestTree.init();
    defer t.deinit();
    try t.write("build/target/node_modules/me/note.txt", "x");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const sub = try arena_state.allocator().print("{s}/build/target/node_modules/me/", .{t.abs});
    const got = list(arena_state.allocator(), testing.allocator, testing.io, sub, true) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 0), got.len); // 1 byte: too small
    try t.write("build/target/node_modules/me/note.txt", "hello");
    const again = try list(arena_state.allocator(), testing.allocator, testing.io, sub, true);
    try testing.expectEqual(@as(usize, 1), again.len);
    // A trailing slash on the root does not double it.
    try testing.expect(std.mem.endsWith(u8, again[0].path, "/me/note.txt"));
    try testing.expect(std.mem.find(u8, again[0].path, "//") == null);
}

test "list: file names with newlines and invalid UTF-8 come back whole" {
    var t = try TestTree.init();
    defer t.deinit();
    try t.write("line1\nline2.txt", "newline in the name");
    try t.write("bad-\xff\xfe.txt", "not utf-8 in the name");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = list(arena_state.allocator(), testing.allocator, testing.io, t.abs, true) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(std.mem.endsWith(u8, got[0].path, "/bad-\xff\xfe.txt"));
    try testing.expect(std.mem.endsWith(u8, got[1].path, "/line1\nline2.txt"));
}

test "documentKind" {
    try testing.expect(documentKind("/a/b.PDF"));
    try testing.expect(documentKind("x.docx"));
    try testing.expect(documentKind("x.odp"));
    try testing.expect(!documentKind("x.doc"));
    try testing.expect(!documentKind("pdf"));
}
