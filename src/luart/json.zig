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

const max_depth = 200;

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

fn pushRoot(L: *lua.State, v: *std.json.Value) void {
    push(L, v.*, 0);
}

fn push(L: *lua.State, v: std.json.Value, depth: usize) void {
    if (depth > max_depth) lua.raise(L, "json.decode: nested too deeply", .{});
    if (c.lua_checkstack(L, 3) == 0) lua.raise(L, "json.decode: nested too deeply", .{});
    switch (v) {
        .null => c.lua_pushnil(L),
        .bool => |b| c.lua_pushboolean(L, @intFromBool(b)),
        .integer => |i| c.lua_pushinteger(L, i),
        .float => |f| c.lua_pushnumber(L, f),
        // Integers too big for i64.
        .number_string => |s| c.lua_pushnumber(L, std.fmt.parseFloat(f64, s) catch 0),
        .string => |s| lua.pushString(L, s),
        .array => |arr| {
            c.lua_createtable(L, @intCast(@min(arr.items.len, std.math.maxInt(c_int))), 0);
            for (arr.items, 1..) |item, i| {
                push(L, item, depth + 1);
                c.lua_rawseti(L, -2, @intCast(i));
            }
        },
        .object => |obj| {
            c.lua_createtable(L, 0, @intCast(@min(obj.count(), std.math.maxInt(c_int))));
            var it = obj.iterator();
            while (it.next()) |e| {
                lua.pushString(L, e.key_ptr.*);
                push(L, e.value_ptr.*, depth + 1);
                c.lua_rawset(L, -3);
            }
        },
    }
}

/// `lumen.json.encode(value)`: encodes the value at `idx` and pushes the
/// text. The walk runs under `tryCall`; the buffer is freed either way.
pub fn encode(L: *lua.State, gpa: std.mem.Allocator, idx: c_int) lua.Error!void {
    // Shared tables are written once per reference: `t = {t, t}` forty
    // times over is 2^40 values in a few bytes of Lua.
    var capped: lua.Capped = .leftIn(L, gpa);
    var out: std.Io.Writer.Allocating = .init(capped.allocator());
    defer out.deinit();
    var enc: Encoder = .{ .w = &out.writer };
    c.lua_pushvalue(L, idx);
    if (!lua.tryCall(L, Encoder, &enc, Encoder.run, 1, 0)) return error.Raise;
    var text: Text = .{ .s = out.written() };
    if (!lua.tryCall(L, Text, &text, Text.push, 0, 1)) return error.Raise;
}

const Text = struct {
    s: []const u8,
    fn push(L: *lua.State, t: *Text) void {
        lua.pushString(L, t.s);
    }
};

const Encoder = struct {
    w: *std.Io.Writer,
    /// Values written, for checking the deadline now and then.
    values: u32 = 0,

    fn run(L: *lua.State, e: *Encoder) void {
        e.value(L, 2, 0);
    }

    fn value(e: *Encoder, L: *lua.State, idx: c_int, depth: usize) void {
        if (depth > max_depth) lua.raise(L, "json.encode: nested too deeply (a cycle?)", .{});
        if (c.lua_checkstack(L, 3) == 0) lua.raise(L, "json.encode: nested too deeply", .{});
        e.values +%= 1;
        if (e.values % 4096 == 0 and lua.pastDeadline(L)) lua.raise(L, "timed out", .{});
        e.write(L, idx, depth) catch lua.raise(L, "json.encode: not enough memory", .{});
    }

    fn write(e: *Encoder, L: *lua.State, idx: c_int, depth: usize) std.Io.Writer.Error!void {
        const w = e.w;
        switch (c.lua_type(L, idx)) {
            c.LUA_TNIL => try w.writeAll("null"),
            c.LUA_TBOOLEAN => try w.writeAll(if (c.lua_toboolean(L, idx) != 0) "true" else "false"),
            c.LUA_TNUMBER => if (c.lua_isinteger(L, idx) != 0) {
                try w.print("{d}", .{c.lua_tointegerx(L, idx, null)});
            } else {
                const f = c.lua_tonumberx(L, idx, null);
                if (!std.math.isFinite(f)) lua.raise(L, "json.encode: cannot encode {d}", .{f});
                try w.print("{d}", .{f});
            },
            c.LUA_TSTRING => try writeString(w, lua.toSlice(L, idx).?),
            c.LUA_TTABLE => {
                const t = lua.absIndex(L, idx);
                const n = c.lua_rawlen(L, t);
                if (n > 0) {
                    try w.writeByte('[');
                    for (1..n + 1) |i| {
                        if (i > 1) try w.writeByte(',');
                        _ = c.lua_rawgeti(L, t, @intCast(i));
                        e.value(L, -1, depth + 1);
                        c.lua_settop(L, -2);
                    }
                    try w.writeByte(']');
                    return;
                }
                try w.writeByte('{');
                var first = true;
                c.lua_pushnil(L);
                while (c.lua_next(L, t) != 0) {
                    // Only string keys: converting a number key in place
                    // would break the traversal.
                    const key = lua.toSlice(L, -2) orelse
                        lua.raise(
                            L,
                            "json.encode: object keys must be strings, got {s}",
                            .{lua.typeName(L, -2)},
                        );
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeString(w, key);
                    try w.writeByte(':');
                    e.value(L, -1, depth + 1);
                    c.lua_settop(L, -2);
                }
                try w.writeByte('}');
            },
            else => lua.raise(L, "json.encode: cannot encode a {s}", .{lua.typeName(L, idx)}),
        }
    }
};

/// `s` as a JSON string, each byte that does not start a valid UTF-8
/// sequence as U+FFFD: std.json, like any JSON reader, refuses text that
/// is not UTF-8, and storage.json written that way could not be read back.
fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        var end = i;
        while (end < s.len) {
            if (s[end] < 0x80) {
                end += 1;
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(s[end]) catch break;
            if (end + n > s.len or !std.unicode.utf8ValidateSlice(s[end..][0..n])) break;
            end += n;
        }
        try std.json.Stringify.encodeJsonStringChars(s[i..end], .{}, w);
        if (end < s.len) {
            try w.writeAll("\u{FFFD}");
            end += 1;
        }
        i = end;
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const os = @import("os");

/// Runs `code` with `json` set to decode/encode backed by testing.allocator.
fn run(code: [:0]const u8) !?[]const u8 {
    var budget: lua.Budget = .{ .max = 16 << 20 };
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
    var budget: lua.Budget = .{ .max = 1 << 30 };
    budget.deadline_ns = os.monotonicNs() + 50 * std.time.ns_per_ms;
    const t0 = os.monotonicNs();
    const doubling = "local t = {} for i = 1, 40 do t = { t, t } end json.encode(t)";
    const msg = (try runIn(&budget, doubling)).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.find(u8, msg, "timed out") != null);
    try testing.expect(os.monotonicNs() - t0 < 5 * std.time.ns_per_s);
}
