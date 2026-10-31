//! A query sent to a worker thread whose answer comes back later on the GTK
//! main loop: content search, an extension command's list, and the
//! extensions' rows for the root search all follow the same protocol.
//!
//! Each request gets a generation from the worker. An answer of any other
//! generation was overtaken by a newer request and is dropped. The newest
//! answer taken is `latest`; the rows on screen are built from `shown` and
//! point into it, so an answer is destroyed only once the rows built from
//! it are gone.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

/// `Result` must have a `generation` field: the generation it answers, an integer
/// or an enum (the extension host's are enums; content search's is the
/// worker's futex word, a u32).
pub fn Inflight(comptime Result: type, comptime asked_bytes_max: usize) type {
    const Generation = @FieldType(Result, "generation");
    return struct {
        /// Generation of the last request sent; answers of others are stale.
        generation: Generation = std.mem.zeroes(Generation),
        /// True from sending a request until an answer to it is taken.
        pending: bool = false,
        /// The query of the last request sent.
        asked: core.FixedStr(asked_bytes_max) = .{},
        /// The newest answer taken. Owned: replaced answers are handed back
        /// by `take` and `forget` for the caller to destroy.
        latest: ?*Result = null,
        /// The answer the rows on screen were built from (null once they are
        /// cleared). Not owned: it is `latest` or was just replaced by it.
        shown: ?*Result = null,

        const Self = @This();

        /// A request for `query` went out with `generation`.
        pub fn sent(self: *Self, generation: Generation, query: []const u8) void {
            self.generation = generation;
            self.pending = true;
            self.asked.set(query);
        }

        /// True while a request for `query` is on its way.
        pub fn asking(self: *const Self, query: []const u8) bool {
            return self.pending and self.asked.eql(query);
        }

        /// Whether `answer` answers the last request sent.
        pub fn current(self: *const Self, answer: *const Result) bool {
            return answer.generation == self.generation;
        }

        /// Takes `answer` (current) as the latest and returns the one it
        /// replaces. The caller destroys that once no row points into it.
        pub fn take(self: *Self, answer: *Result) ?*Result {
            assert(self.current(answer));
            // Each answer is delivered once: the one kept is never handed back.
            assert(answer != self.latest);
            const replaced = self.latest;
            self.latest = answer;
            self.pending = false;
            return replaced;
        }

        /// The current answer was looked at and not kept.
        pub fn answered(self: *Self) void {
            self.pending = false;
        }

        /// Forgets the requests in flight (their answers will not be
        /// current) and returns the latest answer for the caller to destroy.
        pub fn forget(self: *Self) ?*Result {
            const latest = self.latest;
            self.latest = null;
            self.pending = false;
            self.generation = std.mem.zeroes(Generation);
            return latest;
        }

        /// True when the rows on screen were built from the latest answer.
        pub fn showingLatest(self: *const Self) bool {
            return self.latest != null and self.shown == self.latest;
        }
    };
}

test "inflight: stale answers are not current, taking hands back the old one" {
    const Answer = struct { generation: u32 };
    var inflight: Inflight(Answer, 16) = .{};
    var first: Answer = .{ .generation = 1 };
    var second: Answer = .{ .generation = 2 };

    inflight.sent(1, "ab");
    try std.testing.expect(inflight.asking("ab"));
    try std.testing.expect(!inflight.asking("abc"));
    inflight.sent(2, "abc");
    try std.testing.expect(!inflight.current(&first));
    try std.testing.expect(inflight.current(&second));
    try std.testing.expectEqual(null, inflight.take(&second));
    try std.testing.expect(!inflight.pending);

    inflight.shown = inflight.latest;
    try std.testing.expect(inflight.showingLatest());
    inflight.sent(3, "abcd");
    var third: Answer = .{ .generation = 3 };
    try std.testing.expectEqual(&second, inflight.take(&third).?);
    try std.testing.expect(!inflight.showingLatest());
    try std.testing.expectEqual(&third, inflight.forget().?);
    try std.testing.expect(!inflight.current(&third));
}
