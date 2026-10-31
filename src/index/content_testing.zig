//! Fixtures for the content index's tests: documents whose text is kept in
//! memory, a small real index, and a walk over everything a reader of an
//! index touches. Only tests import this file.

const std = @import("std");
const testing = std.testing;
const Pool = @import("Pool.zig");
const content = @import("content.zig");
const DocIn = content.DocIn;
const Source = content.Source;
const Index = content.Index;
const strictlyAscending = @import("content_format.zig").strictlyAscending;

/// Texts by document: a document's path is the index of its text.
pub const TestDocs = struct {
    texts: []const []const u8,

    pub fn readText(
        context: *anyopaque,
        doc: DocIn,
        text: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!bool {
        const test_docs: *TestDocs = @ptrCast(@alignCast(context));
        const text_index = std.fmt.parseInt(usize, doc.path, 10) catch return false;
        text.clearRetainingCapacity();
        try text.appendSlice(gpa, test_docs.texts[text_index]);
        return true;
    }
};

/// A small real index: 60 documents from a fixed vocabulary.
pub fn smallIndex(gpa: std.mem.Allocator) !Index {
    const vocab = [_][]const u8{
        "arena", "allocator", "Config", "trigram", "posting", "lumen", "zig", "parser", "token",
        "élan",
    };
    var texts: [60][]const u8 = undefined;
    var test_paths: [60][]const u8 = undefined;
    var docs: [60]DocIn = undefined;
    var made_count: usize = 0;
    defer for (texts[0..made_count], test_paths[0..made_count]) |text, path| {
        gpa.free(text);
        gpa.free(path);
    };
    var prng = std.Random.DefaultPrng.init(5);
    const random = prng.random();
    for (0..texts.len) |i| {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        for (0..random.intRangeAtMost(usize, 1, 6)) |_| {
            try text.appendSlice(gpa, vocab[random.uintLessThan(usize, vocab.len)]);
            try text.append(gpa, ' ');
        }
        const path = try gpa.print("{d}", .{i});
        texts[i] = text.toOwnedSlice(gpa) catch |err| {
            gpa.free(path);
            return err;
        };
        test_paths[i] = path;
        made_count += 1;
        docs[i] = .{
            .path = path,
            .mtime = @intCast(i),
            .size = i,
            .source = if (i % 7 == 0) .extracted else .plain,
        };
    }
    const pool = try Pool.create(gpa, testing.io, 1);
    defer pool.destroy();
    var test_docs: TestDocs = .{ .texts = &texts };
    const reader: content.TextReader = .{ .read = TestDocs.readText, .context = &test_docs };
    return content.build(gpa, pool, &docs, reader, null);
}

/// Touches everything a reader of an index may touch: must never crash on
/// an index that `parse` accepted.
pub fn exerciseIndex(index: *const Index, gpa: std.mem.Allocator) !void {
    const queries = [_][]const []const u8{
        &.{"arena"}, &.{ "zig", "token" }, &.{"lumen config"},
        &.{"élan"},
        &.{"xyzzy"}, &.{ "pos", "ing" },
    };
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    var sum: usize = index.postingBytes();
    for (queries) |words| {
        try index.candidates(gpa, words, &got);
        try testing.expect(strictlyAscending(u32, got.items));
        for (got.items) |doc| {
            try testing.expect(doc < index.docs_count);
            const source: Source = @fromBackingInt(@intCast(index.sources[doc]));
            sum +%= index.path(doc).len +% @as(
                usize,
                @bitCast(index.mtimes[doc]),
            ) +% index.sizes[doc] +% @backingInt(source);
        }
    }
    for (0..index.docs_count) |doc| sum +%= index.path(@intCast(doc)).len;
    std.mem.doNotOptimizeAway(sum);
}
