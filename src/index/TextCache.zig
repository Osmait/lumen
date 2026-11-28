//! The extracted text of PDFs and Office documents, cached on disk so that
//! extraction (a child process per file, `extract.zig`) happens once per
//! version of a document: `<directory>/<hash of path>-<mtime>-<size>.txt`. An
//! empty file stands for a document that cannot be extracted, so it is not
//! tried again until it changes.
//!
//! The content service is the only writer, on its own thread; building and
//! verification read the files from any thread.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const paths = @import("paths.zig");
const sys = @import("os");
const content = @import("content.zig");
const extract = @import("extract.zig");
const DocIn = content.DocIn;
const Index = content.Index;

const log = std.log.scoped(.content);

const TextCache = @This();

/// The folder the texts are in, owned.
directory: []u8,

/// Room for a name: 32 hex chars of SHA-256 (128 bits), an mtime and a size
/// (20 digits each at most), two dashes and `.txt`.
const name_bytes_max = 96;

comptime {
    assert(32 + 1 + 20 + 1 + 20 + ".txt".len <= name_bytes_max);
}

/// First 128 bits of SHA-256(path) as 32 lowercase hex digits.
pub fn pathHashHex(out: *[32]u8, file_path: []const u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file_path, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..16], .lower);
    out.* = hex;
    return out;
}

/// The cache in `<cache_dir>/text`, created if missing and made private
/// (it holds the text of the user's documents). If it cannot be created,
/// nothing is cached: each document is extracted again when it is needed.
pub fn init(gpa: std.mem.Allocator, cache_dir: []const u8) std.mem.Allocator.Error!TextCache {
    const directory = try gpa.print("{s}/text", .{cache_dir});
    sys.mkdirP(directory) catch |err| {
        log.warn("{s}: {t}, extracted text is not cached", .{ directory, err });
    };
    // Older versions made it 0755.
    sys.makePrivate(directory);
    return .{ .directory = directory };
}

/// Creates the folder again, private, if it is gone: a cleaner that empties
/// ~/.cache while the service runs left every text write failing with
/// ENOENT until a restart. Before writing texts.
pub fn ensureDirectory(cache: TextCache) void {
    var directory_buffer: paths.Buffer = undefined;
    const directory = std.mem.printSentinel(&directory_buffer, "{s}", .{cache.directory}, 0) catch
        return;
    if (sys.exists(directory)) return;
    sys.mkdirP(directory) catch |err| {
        log.warn("{s}: {t}, extracted text is not cached", .{ directory, err });
        return;
    };
    sys.makePrivate(directory);
}

pub fn deinit(cache: *TextCache, gpa: std.mem.Allocator) void {
    gpa.free(cache.directory);
    cache.* = undefined;
}

/// Where a document version's extracted text is cached. Keyed by size as
/// well as mtime (whole seconds): an edit within the same second reused
/// the old text, and dropping the old version's text then deleted it.
pub fn path(cache: TextCache, path_buffer: []u8, doc: DocIn) ?[:0]const u8 {
    var name_buffer: [name_bytes_max]u8 = undefined;
    const name = nameOf(&name_buffer, doc);
    return std.mem.printSentinel(path_buffer, "{s}/{s}", .{ cache.directory, name }, 0) catch null;
}

fn nameOf(name_buffer: *[name_bytes_max]u8, doc: DocIn) []const u8 {
    var hash_hex: [32]u8 = undefined;
    // Bump xlsx and docx cache key suffix (-v2) so stale entries re-extract
    // with inlineStr worksheet text and docx header/footer support.
    const suffix = switch (extract.kindOf(doc.path) orelse .pdf) {
        .xlsx, .docx => "-v2",
        else => "",
    };
    return std.mem.print(
        name_buffer,
        "{s}-{d}-{d}{s}.txt",
        .{ pathHashHex(&hash_hex, doc.path), doc.mtime, doc.size, suffix },
    ) catch unreachable;
}

/// Reads the cached text of `doc` into `text`, up to `content.extracted_bytes_max`
/// bytes: false when there is none (not extracted yet, or nothing to
/// extract).
pub fn read(
    cache: TextCache,
    gpa: std.mem.Allocator,
    doc: DocIn,
    text: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    var path_buffer: paths.Buffer = undefined;
    const text_path = cache.path(&path_buffer, doc) orelse return false;
    text.clearRetainingCapacity();
    const fd = sys.openRegular(text_path) catch return false;
    defer sys.close(fd);
    sys.readUpTo(gpa, fd, text, content.extracted_bytes_max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Part of the text is not the document's text.
        error.ReadFailed => return false,
    };
    return text.items.len > 0;
}

/// How many bytes the cached text of `doc` has (0: none yet).
pub fn size(cache: TextCache, doc: DocIn) u64 {
    var path_buffer: paths.Buffer = undefined;
    const text_path = cache.path(&path_buffer, doc) orelse return 0;
    const info = sys.info(text_path) orelse return 0;
    return info.size;
}

/// Deletes the cached text of document versions that are gone (edited or
/// deleted): it is keyed by mtime, so each edit otherwise left the old
/// text in the cache for good. Versions in `kept` share the same key (e.g.
/// a re-extracted document) and are never removed.
pub fn dropStale(
    cache: TextCache,
    old: *const Index,
    gone: []const u32,
    kept: []const DocIn,
) void {
    var path_buffer: paths.Buffer = undefined;
    for (gone) |id| {
        if (old.sources[id] != @backingInt(content.Source.extracted)) continue;
        const stale = old.docIn(id);
        var is_kept = false;
        for (kept) |doc| {
            if (doc.source == .extracted and
                doc.mtime == stale.mtime and
                doc.size == stale.size and
                std.mem.eql(u8, doc.path, stale.path))
            {
                is_kept = true;
                break;
            }
        }
        if (is_kept) continue;
        const text_path = cache.path(&path_buffer, stale) orelse continue;
        // Left behind, it is deleted by the next whole build's sweep.
        const result = linux.unlink(text_path);
        switch (linux.errno(result)) {
            .SUCCESS, .NOENT => {},
            else => |errno| log.warn("deleting {s}: {t}", .{ text_path, errno }),
        }
    }
}

/// Deletes the cached texts no live document of `index` refers to: what
/// `dropStale` cannot know of, versions extracted and never indexed (out
/// of memory, a shutdown or a crash in between), half-written ones. A text
/// cached under the name used before sizes were part of it
/// (`<hash>-<mtime>.txt`) is renamed instead, not extracted again.
pub fn sweep(cache: TextCache, gpa: std.mem.Allocator, index: *const Index) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const keep = namesKept(arena_state.allocator(), index) catch return;
    var directory_buffer: paths.Buffer = undefined;
    const directory = std.mem.printSentinel(&directory_buffer, "{s}", .{cache.directory}, 0) catch
        return;
    const fd = sys.openDir(directory) catch return;
    defer sys.close(fd);
    var iterator: sys.DirIter = .{ .fd = fd };
    while (iterator.next() catch return) |entry| {
        if (entry.kind == linux.DT.DIR) continue;
        var name_buffer: [256]u8 = undefined;
        const name = std.mem.printSentinel(&name_buffer, "{s}", .{entry.name}, 0) catch continue;
        const name_wanted = keep.get(entry.name) orelse {
            // Left behind, it is tried again by the next sweep.
            const result = linux.unlinkat(fd, name, 0);
            switch (linux.errno(result)) {
                .SUCCESS, .NOENT => {},
                else => |errno| log.warn("deleting {s}/{s}: {t}", .{ directory, name, errno }),
            }
            continue;
        };
        if (std.mem.eql(u8, name_wanted, entry.name)) continue;
        var wanted_buffer: [name_bytes_max]u8 = undefined;
        const target = std.mem.printSentinel(
            &wanted_buffer,
            "{s}",
            .{name_wanted},
            0,
        ) catch continue;
        // RENAME_NOREPLACE: never clobber a fresher cached entry already at
        // `target`. If one already exists, unlink the obsolete legacy file.
        const result = linux.renameat2(fd, name, fd, target, .{ .NOREPLACE = true });
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .EXIST => _ = linux.unlinkat(fd, name, 0),
            else => |errno| log.warn("renaming {s}/{s}: {t}", .{ directory, name, errno }),
        }
    }
}

/// The names in the cache that live documents of `index` use, each mapped
/// to the name it should have: itself, or for legacy Wyhash names (with or
/// without size), the current SHA-256 name.
fn namesKept(
    arena: std.mem.Allocator,
    index: *const Index,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged([]const u8) {
    var keep: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (0..index.docs_count) |doc_index| {
        const id: u32 = @intCast(doc_index);
        if (!index.extractedLive(id)) continue;
        const doc = index.docIn(id);
        var name_buffer: [name_bytes_max]u8 = undefined;
        const name = try arena.dupe(u8, nameOf(&name_buffer, doc));
        try keep.put(arena, name, name);
        // Legacy xlsx and docx entries missed inlineStr / headers & footers; let sweep drop them.
        const doc_kind = extract.kindOf(doc.path);
        if (doc_kind == .xlsx or doc_kind == .docx) continue;
        const legacy_hash = std.hash.Wyhash.hash(0, doc.path);
        const mtime_s = @divFloor(doc.mtime, std.time.ns_per_s);
        const legacy_with_size = try arena.print("{x:0>16}-{d}-{d}.txt", .{
            legacy_hash,
            mtime_s,
            doc.size,
        });
        try keep.put(arena, legacy_with_size, name);
        const old = try arena.print("{x:0>16}-{d}.txt", .{
            legacy_hash,
            mtime_s,
        });
        try keep.put(arena, old, name);
    }
    return keep;
}

test "xlsx and docx use versioned cache keys while other docs keep legacy rename compatibility" {
    const testing = std.testing;
    var buf: [name_bytes_max]u8 = undefined;
    const xlsx_name = nameOf(&buf, .{ .path = "/tmp/book.xlsx", .mtime = 10, .size = 20, .source = .extracted });
    try testing.expect(std.mem.endsWith(u8, xlsx_name, "-10-20-v2.txt"));
    var docx_buf: [name_bytes_max]u8 = undefined;
    const docx_name = nameOf(&docx_buf, .{ .path = "/tmp/doc.docx", .mtime = 10, .size = 20, .source = .extracted });
    try testing.expect(std.mem.endsWith(u8, docx_name, "-10-20-v2.txt"));
    var odt_buf: [name_bytes_max]u8 = undefined;
    const odt_name = nameOf(&odt_buf, .{ .path = "/tmp/doc.odt", .mtime = 10, .size = 20, .source = .extracted });
    try testing.expect(std.mem.endsWith(u8, odt_name, "-10-20.txt"));
}
