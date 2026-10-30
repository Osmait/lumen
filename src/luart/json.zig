//! `lumen.json`: JSON text to Lua values and back.
//!
//! null becomes nil (absent in objects, a hole in arrays). A table encodes
//! as an array when it has a sequence part (`#t > 0`), else as an object
//! with string keys; `{}` encodes as `{}`. Strings are bytes in Lua: what
//! is not UTF-8 encodes as U+FFFD, so the text always decodes again.
//!
//! Both run in Zig, where the state's memory cap and instruction hook do
//! not reach: the memory they take outside the state is capped at what is
//! left under its cap (the result has to fit in there anyway), and a long
//! encode checks the deadline itself.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;

const depth_max = 200;

/// `lumen.json.decode(text)`: pushes the decoded value. Parsing allocates
/// from `gpa`, freed before returning; the push runs under `tryCall`.
pub fn decode(L: *lua.State, gpa: std.mem.Allocator, text: []const u8) lua.Error!void {
    var capped: lua.Capped = .leftIn(L, gpa);
    var parsed = std.json.parseFromSlice(std.json.Value, capped.allocator(), text, .{}) catch |err|
        return lua.fail(L, "json.decode: {s}", .{switch (err) {
            error.OutOfMemory => "out of memory",
            error.SyntaxError, error.UnexpectedEndOfInput => "invalid JSON",
            else => @errorName(err),
        }});
    defer parsed.deinit();
    if (!lua.tryCall(L, std.json.Value, &parsed.value, pushRoot, 0, 1)) return error.Raise;
}

fn pushRoot(L: *lua.State, value: *std.json.Value) void {
    push(L, value.*, 0);
}

fn push(L: *lua.State, value: std.json.Value, depth: usize) void {
    if (depth > depth_max) lua.raise(L, "json.decode: nested too deeply", .{});
    if (c.lua_checkstack(L, 3) == 0) lua.raise(L, "json.decode: nested too deeply", .{});
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
                push(L, item, depth + 1);
                c.lua_rawseti(L, -2, @intCast(item_number));
            }
        },
        .object => |object| {
            const fields_count = @min(object.count(), std.math.maxInt(c_int));
            c.lua_createtable(L, 0, @intCast(fields_count));
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                lua.pushString(L, entry.key_ptr.*);
                push(L, entry.value_ptr.*, depth + 1);
                c.lua_rawset(L, -3);
            }
        },
    }
}

/// `lumen.json.encode(value)`: encodes the value at `index` and pushes the
/// text. The walk runs under `tryCall`; the buffer is freed either way.
pub fn encode(L: *lua.State, gpa: std.mem.Allocator, index: c_int) lua.Error!void {
    // Shared tables are written once per reference: `t = {t, t}` forty
    // times over is 2^40 values in a few bytes of Lua.
    var capped: lua.Capped = .leftIn(L, gpa);
    var out: std.Io.Writer.Allocating = .init(capped.allocator());
    defer out.deinit();
    var encoder: Encoder = .{ .writer = &out.writer };
    c.lua_pushvalue(L, index);
    if (!lua.tryCall(L, Encoder, &encoder, Encoder.run, 1, 0)) return error.Raise;
    var text: Text = .{ .bytes = out.written() };
    if (!lua.tryCall(L, Text, &text, Text.push, 0, 1)) return error.Raise;
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
    const deadline_check_values = 4096;

    fn run(L: *lua.State, encoder: *Encoder) void {
        encoder.value(L, lua.trampoline_first_argument, 0);
    }

    fn value(encoder: *Encoder, L: *lua.State, index: c_int, depth: usize) void {
        if (depth > depth_max) lua.raise(L, "json.encode: nested too deeply (a cycle?)", .{});
        if (c.lua_checkstack(L, 3) == 0) lua.raise(L, "json.encode: nested too deeply", .{});
        encoder.values_count +%= 1;
        if (encoder.values_count % deadline_check_values == 0 and lua.pastDeadline(L)) {
            lua.raise(L, "timed out", .{});
        }
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
            c.LUA_TSTRING => try writeString(writer, lua.toSlice(L, index).?),
            c.LUA_TTABLE => {
                const table = lua.absIndex(L, index);
                const items_count = c.lua_rawlen(L, table);
                if (items_count > 0) {
                    try encoder.writeArray(L, table, items_count, depth);
                } else {
                    try encoder.writeObject(L, table, depth);
                }
            },
            else => lua.raise(L, "json.encode: cannot encode a {s}", .{lua.typeName(L, index)}),
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
            c.lua_settop(L, -2);
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
            if (!first) try encoder.writer.writeByte(',');
            first = false;
            try writeString(encoder.writer, key);
            try encoder.writer.writeByte(':');
            encoder.value(L, -1, depth + 1);
            // Pops the value; `lua_next` takes the key off next.
            c.lua_settop(L, -2);
        }
        try encoder.writer.writeByte('}');
    }
};

/// `text` as a JSON string, each byte that does not start a valid UTF-8
/// sequence as U+FFFD: std.json, like any JSON reader, refuses text that
/// is not UTF-8, and storage.json written that way could not be read back.
fn writeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var start: usize = 0;
    while (start < text.len) {
        const end = validUtf8End(text, start);
        try std.json.Stringify.encodeJsonStringChars(text[start..end], .{}, writer);
        if (end < text.len) {
            try writer.writeAll("\u{FFFD}");
            start = end + 1;
        } else {
            start = end;
        }
    }
    try writer.writeByte('"');
}

/// Where the valid UTF-8 that starts at `start` ends: the first byte that
/// does not start a valid sequence, or the end of `text`.
fn validUtf8End(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len) {
        if (text[end] < 0x80) {
            end += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[end]) catch break;
        if (end + sequence_len > text.len) break;
        if (!std.unicode.utf8ValidateSlice(text[end..][0..sequence_len])) break;
        end += sequence_len;
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
    const Ctx = struct {
        code: [:0]const u8,
        fn go(Ls: *lua.State, ctx: *@This()) void {
            lua.openLibs(Ls);
            c.lua_createtable(Ls, 0, 2);
            c.lua_pushcclosure(Ls, lua.wrap(dec), 0);
            c.lua_setfield(Ls, -2, "decode");
            c.lua_pushcclosure(Ls, lua.wrap(enc), 0);
            c.lua_setfield(Ls, -2, "encode");
            c.lua_setglobal(Ls, "json");
            if (c.luaL_loadstring(Ls, ctx.code.ptr) != c.LUA_OK) _ = c.lua_error(Ls);
            c.lua_callk(Ls, 0, 0, 0, null);
        }
        fn dec(Ls: *lua.State) lua.Error!c_int {
            try decode(Ls, testing.allocator, try lua.argString(Ls, 1, "decode"));
            return 1;
        }
        fn enc(Ls: *lua.State) lua.Error!c_int {
            try encode(Ls, testing.allocator, 1);
            return 1;
        }
    };
    var ctx: Ctx = .{ .code = code };
    const msg = lua.protect(L, arena.allocator(), Ctx, &ctx, Ctx.go) orelse return null;
    return try testing.allocator.dupe(u8, msg);
}

fn expectOk(code: [:0]const u8) !void {
    if (try run(code)) |msg| {
        defer testing.allocator.free(msg);
        std.debug.print("{s}\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

fn expectError(code: [:0]const u8, want: []const u8) !void {
    const msg = (try run(code)) orelse return error.TestExpectedError;
    defer testing.allocator.free(msg);
    if (std.mem.find(u8, msg, want) == null) {
        std.debug.print("{s}\n", .{msg});
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

test "json encodes any bytes as text that decodes again" {
    try expectOk(
        \\local s = "ok \xff\xfe é \xc3 \xed\xa0\x80 \0 end"
        \\local text = json.encode({ [s] = s, list = { s } })
        \\local back = json.decode(text)
        \\local want = "ok \u{FFFD}\u{FFFD} é \u{FFFD} \u{FFFD}\u{FFFD}\u{FFFD} \0 end"
        \\assert(back.list[1] == want and back[want] == want, text)
        \\assert(json.encode("é\xff") == '"é\u{FFFD}"')
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
    const t0 = os.monotonicNs();
    const doubling = "local t = {} for i = 1, 40 do t = { t, t } end json.encode(t)";
    const msg = (try runIn(&budget, doubling)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.find(u8, msg, "timed out") != null);
    try testing.expect(os.monotonicNs() - t0 < 5 * std.time.ns_per_s);
}
