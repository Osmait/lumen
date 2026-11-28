//! `lumen.json`: JSON text to Lua values and back.
//!
//! null becomes nil (absent in objects, a hole in arrays). A table encodes
//! as an array when it has a sequence part (`#t > 0`) and only integer keys
//! in `1..#t`, else as an object with string keys when `#t == 0`; mixed tables
//! fail cleanly, and `{}` encodes as `{}`. Strings are bytes in Lua: what
//! is not UTF-8 encodes as U+FFFD, so the text always decodes again.
//!
//! Both run in Zig, where the state's memory cap and instruction hook do
//! not reach: the memory they take outside the state is charged directly to
//! the state's live budget, and both check the deadline incrementally.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;

const depth_max = 200;

/// Scanner wrapper checking `lua.pastDeadline` incrementally so deeply
/// duplicated JSON keys or huge token streams cannot overrun the deadline.
const DeadlineScanner = struct {
    inner: *std.json.Scanner,
    L: *lua.State,
    tokens_count: u32 = 0,

    const tokens_per_deadline_check = 4096;

    pub const NextError = std.json.Scanner.NextError || error{TimedOut};
    pub const PeekError = std.json.Scanner.PeekError;
    pub const AllocError = std.json.Scanner.AllocError || error{TimedOut};

    pub fn next(self: *DeadlineScanner) NextError!std.json.Token {
        self.tokens_count +%= 1;
        if (self.tokens_count % tokens_per_deadline_check == 0 and lua.pastDeadline(self.L)) {
            return error.TimedOut;
        }
        return self.inner.next();
    }

    pub fn nextAllocMax(
        self: *DeadlineScanner,
        allocator: std.mem.Allocator,
        when: std.json.AllocWhen,
        max_value_len: usize,
    ) AllocError!std.json.Token {
        self.tokens_count +%= 1;
        if (self.tokens_count % tokens_per_deadline_check == 0 and lua.pastDeadline(self.L)) {
            return error.TimedOut;
        }
        return self.inner.nextAllocMax(allocator, when, max_value_len);
    }
};

/// `lumen.json.decode(text)`: pushes the decoded value. Parsing allocates
/// from `gpa`, freed before returning; the push runs under `tryCall`.
pub fn decode(L: *lua.State, gpa: std.mem.Allocator, text: []const u8) lua.Error!void {
    if (lua.pastDeadline(L)) return lua.fail(L, "timed out", .{});
    // Why parsing failed: pushed once the scanner is freed, as pushing may
    // raise (out of memory) and a raise skips the `defer`s.
    const Outcome = union(enum) {
        pushed: lua.TryCallResult,
        timed_out,
        failed: []const u8,
    };
    const outcome: Outcome = blk: {
        var capped: lua.Capped = .chargedTo(L, gpa);
        var scanner = std.json.Scanner.initCompleteInput(capped.allocator(), text);
        defer scanner.deinit();
        var deadline_scanner: DeadlineScanner = .{ .inner = &scanner, .L = L };
        var parsed = std.json.parseFromTokenSource(
            std.json.Value,
            capped.allocator(),
            &deadline_scanner,
            .{
                .duplicate_field_behavior = .use_last,
                .max_value_len = text.len,
                .allocate = .alloc_if_needed,
            },
        ) catch |err| break :blk switch (err) {
            error.TimedOut => .timed_out,
            error.OutOfMemory => .{ .failed = "out of memory" },
            error.SyntaxError, error.UnexpectedEndOfInput => .{ .failed = "invalid JSON" },
            else => .{ .failed = @errorName(err) },
        };
        defer parsed.deinit();
        var decoder: Decoder = .{ .root = parsed.value };
        break :blk .{ .pushed = lua.tryCall(L, Decoder, &decoder, Decoder.run, 0, 1) };
    };
    return switch (outcome) {
        .pushed => |status| switch (status) {
            .ok => {},
            .raised => error.Raise,
            .stack_overflow => lua.fail(L, "Lua stack overflow", .{}),
        },
        .timed_out => lua.fail(L, "timed out", .{}),
        .failed => |reason| lua.fail(L, "json.decode: {s}", .{reason}),
    };
}

const Decoder = struct {
    root: std.json.Value,
    values_count: u32 = 0,

    const values_per_deadline_check = 4096;

    fn run(L: *lua.State, decoder: *Decoder) void {
        decoder.push(L, decoder.root, 0);
    }

    fn push(decoder: *Decoder, L: *lua.State, value: std.json.Value, depth: usize) void {
        if (depth > depth_max) lua.raise(L, "json.decode: nested too deeply", .{});
        if (c.lua_checkstack(L, 3) == 0) lua.raise(L, "json.decode: nested too deeply", .{});
        decoder.values_count +%= 1;
        if (decoder.values_count % values_per_deadline_check == 0 and lua.pastDeadline(L)) {
            lua.raise(L, "timed out", .{});
        }
        const mark: lua.StackMark = .init(L);
        defer mark.expectPushed(L, 1);
        switch (value) {
            .null => c.lua_pushnil(L),
            .bool => |boolean| c.lua_pushboolean(L, @intFromBool(boolean)),
            .integer => |integer| c.lua_pushinteger(L, integer),
            .float => |float| c.lua_pushnumber(L, float),
            // Integers too big for i64.
            .number_string => |digits| {
                c.lua_pushnumber(L, std.fmt.parseFloat(f64, digits) catch 0);
            },
            .string => |string| lua.pushString(L, string),
            .array => |array| {
                const items_count = @min(array.items.len, std.math.maxInt(c_int));
                c.lua_createtable(L, @intCast(items_count), 0);
                for (array.items, 1..) |item, item_number| {
                    decoder.push(L, item, depth + 1);
                    c.lua_rawseti(L, -2, @intCast(item_number));
                }
            },
            .object => |object| {
                const fields_count = @min(object.count(), std.math.maxInt(c_int));
                c.lua_createtable(L, 0, @intCast(fields_count));
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    lua.pushString(L, entry.key_ptr.*);
                    decoder.push(L, entry.value_ptr.*, depth + 1);
                    c.lua_rawset(L, -3);
                }
            },
        }
    }
};

/// `lumen.json.encode(value)`: encodes the value at `index` and pushes the
/// text. The walk runs under `tryCall`; the buffer is freed either way.
pub fn encode(L: *lua.State, gpa: std.mem.Allocator, index: c_int) lua.Error!void {
    if (lua.pastDeadline(L)) return lua.fail(L, "timed out", .{});
    // Shared tables are written once per reference: `t = {t, t}` forty
    // times over is 2^40 values in a few bytes of Lua.
    const status: lua.TryCallResult = blk: {
        var capped: lua.Capped = .chargedTo(L, gpa);
        var output: std.Io.Writer.Allocating = .init(capped.allocator());
        defer output.deinit();
        var encoder: Encoder = .{ .writer = &output.writer };
        c.lua_pushvalue(L, index);
        const encoded = lua.tryCall(L, Encoder, &encoder, Encoder.run, 1, 0);
        if (encoded != .ok) break :blk encoded;
        var text: Text = .{ .bytes = output.written() };
        break :blk lua.tryCall(L, Text, &text, Text.push, 0, 1);
    };
    return switch (status) {
        .ok => {},
        .raised => error.Raise,
        .stack_overflow => lua.fail(L, "Lua stack overflow", .{}),
    };
}

const Text = struct {
    bytes: []const u8,

    fn push(L: *lua.State, text: *Text) void {
        lua.pushString(L, text.bytes);
    }
};

const Encoder = struct {
    writer: *std.Io.Writer,
    /// Values written, for checking the deadline now and then.
    values_count: u32 = 0,

    /// The deadline is checked once per this many values: often enough to
    /// stop within milliseconds, rarely enough to cost nothing.
    const values_per_deadline_check = 4096;

    fn run(L: *lua.State, encoder: *Encoder) void {
        encoder.value(L, lua.trampoline_first_argument, 0);
    }

    fn countValue(encoder: *Encoder, L: *lua.State) void {
        encoder.values_count +%= 1;
        if (encoder.values_count % values_per_deadline_check == 0 and lua.pastDeadline(L)) {
            lua.raise(L, "timed out", .{});
        }
    }

    fn value(encoder: *Encoder, L: *lua.State, index: c_int, depth: usize) void {
        if (depth > depth_max) lua.raise(L, "json.encode: nested too deeply (a cycle?)", .{});
        if (c.lua_checkstack(L, 3) == 0) lua.raise(L, "json.encode: nested too deeply", .{});
        encoder.countValue(L);
        const mark: lua.StackMark = .init(L);
        encoder.write(L, index, depth) catch lua.raise(L, "json.encode: not enough memory", .{});
        mark.expectPushed(L, 0);
    }

    fn write(
        encoder: *Encoder,
        L: *lua.State,
        index: c_int,
        depth: usize,
    ) std.Io.Writer.Error!void {
        const writer = encoder.writer;
        switch (c.lua_type(L, index)) {
            c.LUA_TNIL => try writer.writeAll("null"),
            c.LUA_TBOOLEAN => {
                const boolean = c.lua_toboolean(L, index) != 0;
                try writer.writeAll(if (boolean) "true" else "false");
            },
            c.LUA_TNUMBER => if (c.lua_isinteger(L, index) != 0) {
                try writer.print("{d}", .{c.lua_tointegerx(L, index, null)});
            } else {
                const number = c.lua_tonumberx(L, index, null);
                if (!std.math.isFinite(number)) {
                    lua.raise(L, "json.encode: cannot encode {d}", .{number});
                }
                try writer.print("{d}", .{number});
            },
            c.LUA_TSTRING => try writeString(L, writer, lua.toSlice(L, index).?),
            c.LUA_TTABLE => {
                const table = lua.absIndex(L, index);
                const items_count = c.lua_rawlen(L, table);
                if (items_count > 0) {
                    encoder.ensurePureArray(L, table, items_count);
                    try encoder.writeArray(L, table, items_count, depth);
                } else {
                    try encoder.writeObject(L, table, depth);
                }
            },
            else => lua.raise(L, "json.encode: cannot encode a {s}", .{lua.typeName(L, index)}),
        }
    }

    /// Rejects mixed tables (`{ "item", label = "x" }` or sparse keys outside `1..items_count`)
    /// so JSON encoding never silently drops keys.
    fn ensurePureArray(encoder: *Encoder, L: *lua.State, table: c_int, items_count: u64) void {
        if (c.lua_checkstack(L, 2) == 0) lua.raise(L, "json.encode: nested too deeply", .{});
        c.lua_pushnil(L);
        while (c.lua_next(L, table) != 0) {
            encoder.countValue(L);
            if (c.lua_type(L, -2) != c.LUA_TNUMBER or c.lua_isinteger(L, -2) == 0) {
                lua.pop(L, 2);
                lua.raise(L, "json.encode: cannot encode mixed table (array and object keys)", .{});
            }
            const key = c.lua_tointegerx(L, -2, null);
            if (key < 1 or @as(u64, @intCast(key)) > items_count) {
                lua.pop(L, 2);
                lua.raise(
                    L,
                    "json.encode: cannot encode mixed table (array and non-sequence keys)",
                    .{},
                );
            }
            lua.pop(L, 1);
        }
    }

    /// A table with a sequence part: its items 1 to `items_count`.
    fn writeArray(
        encoder: *Encoder,
        L: *lua.State,
        table: c_int,
        items_count: u64,
        depth: usize,
    ) std.Io.Writer.Error!void {
        try encoder.writer.writeByte('[');
        for (1..items_count + 1) |item_number| {
            if (item_number > 1) try encoder.writer.writeByte(',');
            _ = c.lua_rawgeti(L, table, @intCast(item_number));
            encoder.value(L, -1, depth + 1);
            lua.pop(L, 1);
        }
        try encoder.writer.writeByte(']');
    }

    /// A table without a sequence part: its string keys and their values.
    fn writeObject(
        encoder: *Encoder,
        L: *lua.State,
        table: c_int,
        depth: usize,
    ) std.Io.Writer.Error!void {
        try encoder.writer.writeByte('{');
        var first = true;
        c.lua_pushnil(L);
        while (c.lua_next(L, table) != 0) {
            // Only string keys: converting a number key in place would
            // break the traversal.
            const key = lua.toSlice(L, -2) orelse {
                const type_name = lua.typeName(L, -2);
                lua.raise(L, "json.encode: object keys must be strings, got {s}", .{type_name});
            };
            if (!std.unicode.utf8ValidateSlice(key)) {
                lua.raise(L, "json.encode: object keys must be valid UTF-8", .{});
            }
            if (!first) try encoder.writer.writeByte(',');
            first = false;
            try writeString(L, encoder.writer, key);
            try encoder.writer.writeByte(':');
            encoder.value(L, -1, depth + 1);
            // Pops the value; `lua_next` takes the key off next.
            lua.pop(L, 1);
        }
        try encoder.writer.writeByte('}');
    }
};

/// `text` as a JSON string, each byte that does not start a valid UTF-8
/// sequence as U+FFFD: std.json, like any JSON reader, refuses text that
/// is not UTF-8, and storage.json written that way could not be read back.
fn writeString(L: *lua.State, writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    const chunk_bytes = 64 << 10;
    var start: usize = 0;
    var checked_at: usize = 0;
    while (start < text.len) {
        if (start - checked_at >= chunk_bytes) {
            checked_at = start;
            if (lua.pastDeadline(L)) lua.raise(L, "timed out", .{});
        }
        const end = validUtf8End(text, start, start +| chunk_bytes);
        if (end > start) {
            try std.json.Stringify.encodeJsonStringChars(text[start..end], .{}, writer);
            start = end;
        } else {
            try writer.writeAll("\u{FFFD}");
            start += 1;
        }
    }
    try writer.writeByte('"');
}

/// Where the valid UTF-8 that starts at `start` ends (capped at `limit`):
/// the first byte that does not start a valid sequence, `limit`, or `text.len`.
fn validUtf8End(text: []const u8, start: usize, limit: usize) usize {
    var end = start;
    while (end < text.len and end < limit) {
        if (text[end] < 0x80) {
            end += 1;
            continue;
        }
        const sequence_bytes = std.unicode.utf8ByteSequenceLength(text[end]) catch break;
        if (end + sequence_bytes > text.len) break;
        if (!std.unicode.utf8ValidateSlice(text[end..][0..sequence_bytes])) break;
        end += sequence_bytes;
    }
    return end;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const os = @import("os");

/// Runs `code` with `json` set to decode/encode backed by testing.allocator.
fn run(code: [:0]const u8) !?[]const u8 {
    var budget: lua.Budget = .{ .bytes_max = 16 << 20 };
    return runIn(&budget, code);
}

fn runIn(budget: *lua.Budget, code: [:0]const u8) !?[]const u8 {
    const L = lua.newState(budget) orelse return error.OutOfMemory;
    defer c.lua_close(L);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Context = struct {
        code: [:0]const u8,
        fn run(state: *lua.State, context: *@This()) void {
            lua.openLibs(state);
            c.lua_createtable(state, 0, 2);
            c.lua_pushcclosure(state, lua.wrap(jsonDecode), 0);
            c.lua_setfield(state, -2, "decode");
            c.lua_pushcclosure(state, lua.wrap(jsonEncode), 0);
            c.lua_setfield(state, -2, "encode");
            c.lua_setglobal(state, "json");
            const loaded = c.luaL_loadstring(state, context.code.ptr);
            if (loaded != c.LUA_OK) _ = c.lua_error(state);
            c.lua_callk(state, 0, 0, 0, null);
        }
        fn jsonDecode(state: *lua.State) lua.Error!c_int {
            try decode(state, testing.allocator, try lua.argString(state, 1, "decode"));
            return 1;
        }
        fn jsonEncode(state: *lua.State) lua.Error!c_int {
            try encode(state, testing.allocator, 1);
            return 1;
        }
    };
    var context: Context = .{ .code = code };
    const message = lua.protect(L, arena.allocator(), Context, &context, Context.run) orelse
        return null;
    return try testing.allocator.dupe(u8, message);
}

fn expectOk(code: [:0]const u8) !void {
    if (try run(code)) |message| {
        defer testing.allocator.free(message);
        std.debug.print("{s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

fn expectError(code: [:0]const u8, want: []const u8) !void {
    const message = (try run(code)) orelse return error.TestExpectedError;
    defer testing.allocator.free(message);
    if (std.mem.find(u8, message, want) == null) {
        std.debug.print("{s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

test "json decodes to tables and encodes back" {
    try expectOk(
        \\local v = json.decode('{"n": 3, "f": 1.5, "s": "héllo \\"q\\"", "a": [1, "two", true], "o": {"k": null}}')
        \\assert(v.n == 3 and math.type(v.n) == "integer" and v.f == 1.5)
        \\assert(v.s == 'héllo "q"' and #v.a == 3 and v.a[2] == "two" and v.a[3] == true)
        \\assert(type(v.o) == "table" and v.o.k == nil)
        \\assert(json.encode({1, 2, "x"}) == '[1,2,"x"]')
        \\assert(json.encode({}) == '{}')
        \\assert(json.encode({a = {b = false}}) == '{"a":{"b":false}}')
        \\assert(json.encode("tab\there") == '"tab\\there"')
        \\assert(json.decode(json.encode({x = 0.25})).x == 0.25)
    );
}

test "json reports bad input instead of crashing" {
    try expectError("json.decode('{nope')", "invalid JSON");
    try expectError("json.encode({f = print})", "cannot encode a function");
    try expectError("json.encode({[{}] = 1})", "keys must be strings");
    try expectError("local t = {} t.t = t json.encode(t)", "nested too deeply");
    try expectError("json.encode(0/0)", "cannot encode");
    try expectError(
        "json.decode(string.rep('[', 1000) .. string.rep(']', 1000))",
        "nested too deeply",
    );
}

test "json encodes string values as valid UTF-8, rejects non-UTF-8 keys, and decodes duplicate keys" {
    try expectOk(
        \\local s = "ok \xff\xfe é \xc3 \xed\xa0\x80 \0 end"
        \\local text = json.encode({ val = s, list = { s } })
        \\local back = json.decode(text)
        \\local want = "ok \u{FFFD}\u{FFFD} é \u{FFFD} \u{FFFD}\u{FFFD}\u{FFFD} \0 end"
        \\assert(back.list[1] == want and back.val == want, text)
        \\assert(json.encode("é\xff") == '"é\u{FFFD}"')
        \\assert(json.decode('{"a":1,"a":2}').a == 2)
    );
    try expectError(
        "json.encode({ ['caf\\xe9'] = 1, ['caf\\xe8'] = 2 })",
        "keys must be valid UTF-8",
    );
}

test "json stops at the memory left and at the deadline" {
    // Shared tables are written out in full each time: 2^40 values.
    try expectError(
        "local t = {} for i = 1, 40 do t = { t, t } end json.encode(t)",
        "not enough memory",
    );
    // Decoding takes memory outside the state for its tree: capped too.
    try expectError(
        "json.decode('[' .. string.rep('[],', 1e6) .. '[]]')",
        "out of memory",
    );
    // With memory to spare, the deadline stops it.
    var budget: lua.Budget = .{ .bytes_max = 1 << 30 };
    budget.deadline_ns = os.monotonicNs() + 50 * std.time.ns_per_ms;
    const start_ns = os.monotonicNs();
    const doubling = "local t = {} for i = 1, 40 do t = { t, t } end json.encode(t)";
    const message = (try runIn(&budget, doubling)).?;
    defer testing.allocator.free(message);
    try testing.expect(std.mem.find(u8, message, "timed out") != null);
    try testing.expect(os.monotonicNs() - start_ns < 5 * std.time.ns_per_s);
}

test "json.decode shares Lua Budget across parse tree and pushed Lua values" {
    var budget: lua.Budget = .{ .bytes_max = 256 << 10 };
    // Even ~110 KB of strings already held plus an encoded JSON array (~60 KB parse tree
    // + ~60 KB Lua values) stays well within 256 KB individually, yet exceeds 256 KB
    // combined while both `parsed` and the pushed Lua table coexist.
    const message = (try runIn(&budget,
        \\local hold = string.rep("x", 110000)
        \\local arr = '[' .. string.rep('"abcdef",', 2000) .. '"abcdef"]'
        \\json.decode(arr)
        \\assert(hold)
    )).?;
    defer testing.allocator.free(message);
    try testing.expect(
        std.mem.find(u8, message, "out of memory") != null or
            std.mem.find(u8, message, "not enough memory") != null,
    );
}

test "json.encode rejects mixed tables so array encoding never drops keys" {
    try expectError("json.encode({ 'item', label = 'user label' })", "mixed table");
    try expectError("json.encode({ [1] = 'a', [0] = 'z' })", "mixed table");
    try expectError("json.encode({ [1] = 'a', [100] = 'far' })", "mixed table");
    try expectOk(
        \\assert(json.encode({ 1, nil, 3 }) == '[1,null,3]')
        \\assert(json.encode({ [1] = 'a', [2] = 'b' }) == '["a","b"]')
        \\assert(json.encode({ a = 1, b = 2 }) ~= nil)
    );
}

test "json.decode and json.encode stop at the deadline on huge duplicate keys and long strings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var decode_budget: lua.Budget = .{ .bytes_max = 1 << 30 };
    decode_budget.deadline_ns = os.monotonicNs() + 40 * std.time.ns_per_ms;
    const decode_start_ns = os.monotonicNs();
    const decode_msg = (try runIn(
        &decode_budget,
        "local s = '{' .. string.rep('\"a\":1,', 100000) .. '\"a\":1}' while true do json.decode(s) end",
    )).?;
    defer testing.allocator.free(decode_msg);
    try testing.expect(std.mem.find(u8, decode_msg, "timed out") != null);
    try testing.expect(os.monotonicNs() - decode_start_ns < 2 * std.time.ns_per_s);

    var encode_budget: lua.Budget = .{ .bytes_max = 1 << 30 };
    encode_budget.deadline_ns = os.monotonicNs() + 40 * std.time.ns_per_ms;
    const encode_start_ns = os.monotonicNs();
    const encode_msg = (try runIn(
        &encode_budget,
        "local s = string.rep('\\x01', 2000000) while true do pcall(json.encode, s) end",
    )).?;
    defer testing.allocator.free(encode_msg);
    try testing.expect(std.mem.find(u8, encode_msg, "timed out") != null);
    try testing.expect(os.monotonicNs() - encode_start_ns < 2 * std.time.ns_per_s);
}

test "json.encode shares Lua Budget across output buffer and pushed Lua string" {
    var budget: lua.Budget = .{ .bytes_max = 256 << 10 };
    const message = (try runIn(&budget,
        \\local hold = string.rep("x", 100000)
        \\local big = string.rep("a", 90000)
        \\json.encode(big)
        \\assert(hold)
    )).?;
    defer testing.allocator.free(message);
    try testing.expect(
        std.mem.find(u8, message, "not enough memory") != null or
            std.mem.find(u8, message, "out of memory") != null,
    );
}

test "json.decode frees its scanner when its error message does not fit" {
    var budget: lua.Budget = .{ .bytes_max = 16 << 20 };
    const L = lua.newState(&budget) orelse return error.OutOfMemory;
    defer c.lua_close(L);
    const Bad = struct {
        fn decodeBad(state: ?*lua.State) callconv(.c) c_int {
            decode(state.?, testing.allocator, "{\"key\": nope") catch return c.lua_error(state);
            return 1;
        }
    };
    // From no room at all up: at some point the scanner fits, the parse
    // after it does not, and neither does the message then pushed. A raise
    // there skipped the scanner's `defer`, and testing.allocator reports
    // what it held.
    const room = budget.bytes_max;
    var slack: usize = 0;
    while (slack < 4096) : (slack += 8) {
        // The message is made anew each time, not found interned.
        _ = c.lua_gc(L, c.LUA_GCCOLLECT);
        c.lua_pushcclosure(L, &Bad.decodeBad, 0);
        budget.bytes_max = budget.used_bytes + slack;
        const status = c.lua_pcallk(L, 0, 1, 0, 0, null);
        budget.bytes_max = room;
        try testing.expect(status != c.LUA_OK);
        c.lua_settop(L, 0);
    }
}
