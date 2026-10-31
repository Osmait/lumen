//! What the content index covers: text under $HOME that `rg --files` lists
//! (it honours .gitignore, skips hidden files) and that is at most
//! `content.text_bytes_max` bytes, plus PDFs and Office documents (text extracted).
//! ripgrep resolves every .gitignore of a home directory in ~70 ms.

const std = @import("std");
const paths = @import("paths.zig");
const linux = std.os.linux;
const content = @import("content.zig");
const extract = @import("extract.zig");
const sys = @import("os");

/// Package caches and build output: other people's code, or generated.
/// Globs with a slash need `**/` to match below the search root.
const excludes = [_][]const u8{
    "!**/node_modules/**", "!**/.git/**",    "!**/go/pkg/**", "!**/zig-pkg/**",
    "!**/.zig-cache/**",   "!**/zig-out/**", "!**/target/**", "!**/*cache*/**",
    "!**/vendor/**",       "!**/dist/**",    "!**/build/**",  "!*.min.js",
    "!*.map",              "!*.lock",        "!*-lock.json",  "!*.svg",
};

pub const ListError = std.process.RunError || std.mem.Allocator.Error;

/// A hung network or FUSE mount under the root must not hang the content
/// service forever: ripgrep gets this long, then the current index stays.
const list_timeout_ns = 60 * std.time.ns_per_s;
/// How often a running listing looks at `stop` and the deadline.
const list_poll_ms = 100;
/// The least free room in the buffer before each read of ripgrep's output.
const list_read_bytes_min = 64;
/// The most a listing may print: paths of a few million files.
const list_output_bytes_max = 256 << 20;
/// Documents above this (PDF, Office) are not extracted: a book-sized PDF
/// gives far more text than `content.extracted_bytes_max` keeps.
const document_bytes_max = 64 << 20;

pub const ListOptions = struct {
    /// Also documents whose text is extracted (PDF, Office), not only
    /// plain text files.
    documents: bool,
    /// Once it is set, the listing is given up (error.Canceled) within
    /// ~0.1 s. Shutting down waited for ripgrep, up to its minute.
    stop: ?*const std.atomic.Value(bool) = null,
};

/// Documents to index, sorted by path (stable doc ids between builds).
/// Paths are owned by `arena`.
pub fn list(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    options: ListOptions,
) ListError![]content.DocIn {
    var argv: std.ArrayList([]const u8) = .empty;
    // --no-ignore-parent: ignore files above the root are not about it (and
    // a checkout's .gitignore patterns like `build/` would hit any dir
    // with that name below).
    // --null: paths end in NUL, the one byte a path cannot contain (a file
    // name with a newline was split into two bogus paths and never indexed).
    try argv.appendSlice(arena, &.{
        "rg",
        "--files",
        "--null",
        "--no-messages",
        "--no-ignore-parent",
    });
    for (excludes) |glob| try argv.appendSlice(arena, &.{ "-g", glob });
    // Run inside the root and list ".": rg matches globs against the path it
    // prints, so with the root as argument a root below any excluded name
    // (a home in /srv/build, the tests' .zig-cache/tmp) listed nothing.
    try argv.append(arena, ".");
    const listing = try runLister(gpa, io, argv.items, root, options.stop);
    defer gpa.free(listing);

    const separator = paths.separatorAfter(root);
    var docs: std.ArrayList(content.DocIn) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listing, 0);
    var path_buffer: paths.Buffer = undefined;
    while (lines.next()) |line| {
        const path_relative = if (std.mem.startsWith(u8, line, "./")) line[2..] else line;
        const path_z = std.mem.printSentinel(
            &path_buffer,
            "{s}{s}{s}",
            .{ root, separator, path_relative },
            0,
        ) catch continue;
        const path: []const u8 = path_z;
        const kind: Kind = if (documentKind(path)) .document else .text;
        if (kind == .document and !options.documents) continue;
        if (kind == .text and binaryByName(path)) continue;
        const file_stat = stat(path_z, kind) orelse continue;
        try docs.append(arena, .{
            .path = try arena.dupe(u8, path),
            .mtime = file_stat.mtime,
            .size = file_stat.size,
            .source = switch (kind) {
                .document => .extracted,
                .text => .plain,
            },
        });
    }
    std.mem.sort(content.DocIn, docs.items, {}, struct {
        fn lt(_: void, a: content.DocIn, b: content.DocIn) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lt);
    return docs.items;
}

/// What `argv` (ripgrep, run in `root`) prints, read in slices of 100 ms so
/// that `stop` and the deadline are looked at while it runs.
fn runLister(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    root: []const u8,
    stop: ?*const std.atomic.Value(bool),
) ListError![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var streams: std.Io.File.MultiReader.Buffer(1) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, streams.toStreams(), &.{child.stdout.?});
    defer reader.deinit();
    const deadline_ns = sys.monotonicNs() + list_timeout_ns;
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .fromMilliseconds(list_poll_ms), .clock = .awake },
    };
    while (true) {
        reader.fill(list_read_bytes_min, poll_timeout) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {},
            else => |other| return other,
        };
        if (stop) |stop_flag| if (stop_flag.load(.acquire)) return error.Canceled;
        if (sys.monotonicNs() >= deadline_ns) return error.Timeout;
        if (reader.reader(0).buffered().len > list_output_bytes_max) return error.StreamTooLong;
    }
    try reader.checkAnyError();
    _ = try child.wait(io);
    return reader.toOwnedSlice(0);
}

pub const Stat = struct { mtime: i64, size: u64 };

/// What a listed file is indexed as: its own bytes, or extracted text.
/// Their size bounds differ.
pub const Kind = enum { text, document };

/// A listed file's mtime and size, or null if it is not one to index (any
/// more): not a regular file, or a size out of bounds for its `kind`.
pub fn stat(path: [*:0]const u8, kind: Kind) ?Stat {
    var statx: linux.Statx = undefined;
    const result = linux.statx(
        linux.AT.FDCWD,
        path,
        0,
        .{ .TYPE = true, .SIZE = true, .MTIME = true },
        &statx,
    );
    if (linux.errno(result) != .SUCCESS) return null;
    if (statx.mode & linux.S.IFMT != linux.S.IFREG) return null;
    switch (kind) {
        // Shorter than a trigram: no query can find anything in it.
        .text => {
            if (statx.size > content.text_bytes_max) return null;
            if (statx.size < content.trigram_chars) return null;
        },
        .document => if (statx.size > document_bytes_max) return null,
    }
    return .{ .mtime = statx.mtime.sec, .size = statx.size };
}

pub fn documentKind(path: []const u8) bool {
    // The extractor's own test: a document it refuses (an Office lock file,
    // `~$x.docx`) was listed as extracted, never extracted, and checked
    // again on every refresh.
    return extract.kindOf(path) != null;
}

/// Obviously binary by extension: skips opening them at all.
fn binaryByName(path: []const u8) bool {
    const extensions = [_][]const u8{
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".webp",
        ".ico",
        ".mp4",
        ".mkv",
        ".mp3",
        ".ogg",
        ".wav",
        ".zip",
        ".gz",
        ".xz",
        ".zst",
        ".tar",
        ".so",
        ".o",
        ".a",
        ".wasm",
        ".ttf",
        ".otf",
        ".woff",
        ".woff2",
        ".blend",
        ".uasset",
        ".umap",
        ".exe",
        ".dll",
        ".class",
        ".jar",
        ".pyc",
        ".db",
        ".sqlite",
        ".bin",
        ".iso",
        ".avif",
        ".heic",
        ".psd",
        ".dds",
        ".ktx",
        ".glb",
        ".fbx",
        ".mov",
    };
    for (extensions) |extension| if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const TestTree = sys.TestDir;

/// `list` relative to the tree, or SkipZigTest without ripgrep.
fn listRel(arena: std.mem.Allocator, tree: *const TestTree, documents: bool) ![]content.DocIn {
    return list(
        arena,
        testing.allocator,
        testing.io,
        tree.abs,
        .{ .documents = documents },
    ) catch |err| switch (err) {
        error.FileNotFound => error.SkipZigTest,
        else => err,
    };
}

test "list: what is indexed and what is excluded" {
    var tree = try TestTree.init();
    defer tree.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "some text\n";
    const keep = [_][]const u8{
        "notes.md",
        "src/main.zig",
        "src/deep/er/lib.rs",
        "about-cache.txt", // "cache" in a file name, not a dir: kept.
        "proj/kept.txt",
        "three.txt", // Written with exactly 3 bytes below.
        "exactly_max.log", // Exactly content.text_bytes_max bytes below.
    };
    for (keep) |name| try tree.write(name, text);
    try tree.write("three.txt", "abc");
    const docs = [_][]const u8{ "papers/a.pdf", "reports/b.docx" };
    for (docs) |name| try tree.write(name, "not really a document");

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
        "proj/gen/out.txt", // `gen/` is in proj/.gitignore.
        "two.txt", // 2 bytes.
        "empty.txt",
        "img/photo.png",
        "big.log", // > text_bytes_max.
    };
    for (drop) |name| try tree.write(name, text);
    try tree.write("two.txt", "ab");
    try tree.write("empty.txt", "");
    // A .gitignore applies inside a git repo only (rg's default; outside a
    // repo it is ignored, which in a home directory is what users expect).
    try tree.mkdir("proj/.git");
    try tree.write("proj/.gitignore", "ignored.txt\ngen/\n");
    // Sizes without writing the bytes: sparse files.
    var path_buffer: paths.Buffer = undefined;
    const sparse = [_]struct { name: []const u8, size: i64 }{
        .{ .name = "big.log", .size = content.text_bytes_max + 1 },
        .{ .name = "exactly_max.log", .size = content.text_bytes_max },
    };
    for (sparse) |file| {
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
        const result = linux.open(try tree.path(&path_buffer, file.name), flags, 0);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
        const fd: i32 = @intCast(result);
        defer sys.close(fd);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, file.size)));
    }

    const got = try listRel(arena, &tree, true);

    var want: std.ArrayList([]const u8) = .empty;
    for (keep ++ docs) |name| try want.append(arena, try arena.print("{s}/{s}", .{ tree.abs, name }));
    std.mem.sort([]const u8, want.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var got_paths: std.ArrayList([]const u8) = .empty;
    for (got) |doc| try got_paths.append(arena, doc.path);
    const joined_want = try std.mem.join(arena, "\n", want.items);
    const joined_got = try std.mem.join(arena, "\n", got_paths.items);
    try testing.expectEqualStrings(joined_want, joined_got);

    const now = sys.nowSeconds();
    for (got) |doc| {
        try testing.expectEqual(documentKind(doc.path), doc.source == .extracted);
        try testing.expect(doc.mtime > now - 3600);
        try testing.expect(doc.mtime <= now + 1);
        const info = sys.info(try std.mem.printSentinel(&path_buffer, "{s}", .{doc.path}, 0)).?;
        try testing.expectEqual(info.size, doc.size);
        try testing.expectEqual(info.mtime, doc.mtime);
    }
    for (got) |doc| {
        if (!std.mem.endsWith(u8, doc.path, "/exactly_max.log")) continue;
        try testing.expectEqual(@as(u64, content.text_bytes_max), doc.size);
    }

    // Without documents: the same minus the PDF and the docx.
    const plain = try listRel(arena, &tree, false);
    try testing.expectEqual(got.len - docs.len, plain.len);
    for (plain) |doc| try testing.expect(doc.source == .plain);
}

test "list: a root below an excluded name still lists" {
    // Globs are matched against the path rg prints: with the root as rg's
    // argument, a root like this one (.zig-cache/tmp/...) or /srv/build/me
    // listed nothing.
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("build/target/node_modules/me/note.txt", "x");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const root_nested = try arena_state.allocator().print(
        "{s}/build/target/node_modules/me/",
        .{tree.abs},
    );
    const got = list(
        arena_state.allocator(),
        testing.allocator,
        testing.io,
        root_nested,
        .{ .documents = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 0), got.len); // 1 byte: too small.
    try tree.write("build/target/node_modules/me/note.txt", "hello");
    const again = try list(arena_state.allocator(), testing.allocator, testing.io, root_nested, .{
        .documents = true,
    });
    try testing.expectEqual(@as(usize, 1), again.len);
    // A trailing slash on the root does not double it.
    try testing.expect(std.mem.endsWith(u8, again[0].path, "/me/note.txt"));
    try testing.expect(std.mem.find(u8, again[0].path, "//") == null);
}

test "list: file names with newlines and invalid UTF-8 come back whole" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("line1\nline2.txt", "newline in the name");
    try tree.write("bad-\xff\xfe.txt", "not utf-8 in the name");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = list(
        arena_state.allocator(),
        testing.allocator,
        testing.io,
        tree.abs,
        .{ .documents = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(std.mem.endsWith(u8, got[0].path, "/bad-\xff\xfe.txt"));
    try testing.expect(std.mem.endsWith(u8, got[1].path, "/line1\nline2.txt"));
}

test "listing gives up soon after stop is set" {
    var tree = try TestTree.init();
    defer tree.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    const setter = try std.Thread.spawn(.{}, struct {
        fn later(stop_flag: *std.atomic.Value(bool)) void {
            sys.sleepUs(100_000);
            stop_flag.store(true, .release);
        }
    }.later, .{&stop});
    defer setter.join();
    // A lister stuck on a hung mount: silent, alive.
    const start_ns = sys.monotonicNs();
    try testing.expectError(error.Canceled, runLister(
        testing.allocator,
        testing.io,
        &.{ "sh", "-c", "exec sleep 30" },
        tree.abs,
        &stop,
    ));
    try testing.expect(sys.monotonicNs() - start_ns < 5 * std.time.ns_per_s);
}

test "documentKind" {
    try testing.expect(documentKind("/a/b.PDF"));
    try testing.expect(documentKind("x.docx"));
    try testing.expect(documentKind("x.odp"));
    try testing.expect(!documentKind("x.doc"));
    try testing.expect(!documentKind("pdf"));
}
