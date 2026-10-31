//! Inline calculator for the search bar.
//!
//!   2 + 3 * 4        (1 + 2)^3       sqrt(16) + 2!      20% of 80
//!   10 km to mi      100 f in c      5 gb to mb         90 min to h
//!
//! `evaluate` returns null for anything that is not clearly a calculation, so
//! typing an app name never shows a result. Text goes through a conversion
//! ("<expression> <unit> to <unit>", units in calc_units.zig) or straight to
//! the expression parser (calc_parser.zig); the value comes back as a
//! `Result`, shown with `formatDisplay` and copied with `formatPlain`.

const std = @import("std");
const assert = std.debug.assert;
const Parser = @import("calc_parser.zig").Parser;
const units = @import("calc_units.zig");

pub const Result = struct {
    value: f64,
    /// Unit of the result when it was a conversion ("mi"), else empty.
    unit: []const u8 = "",
    /// Unit of the input of a conversion ("km"), else empty.
    from_unit: []const u8 = "",
};

pub fn evaluate(input: []const u8) ?Result {
    const text = std.mem.trim(u8, input, " \t");
    if (text.len == 0 or !hasDigit(text)) return null;

    if (splitConversion(text)) |conversion| return conversion;

    var parser: Parser = .{ .source = text };
    const value = parser.parseExpression() catch return null;
    // Every level parseUnary entered, it left.
    assert(parser.depth == 0);
    parser.skipSpaces();
    if (parser.offset != text.len) return null;
    if (!parser.saw_operator) return null;
    if (!std.math.isFinite(value)) return null;
    return .{ .value = value };
}

fn hasDigit(text: []const u8) bool {
    for (text) |char| {
        if (std.ascii.isDigit(char)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- conversions

/// A conversion, "<expression> <unit> to|in|as <unit>", or null.
fn splitConversion(text: []const u8) ?Result {
    const separators = [_][]const u8{ " to ", " in ", " as " };
    for (separators) |separator| {
        const separator_start = lastIndexOfIgnoreCase(text, separator) orelse continue;
        const left = std.mem.trim(u8, text[0..separator_start], " ");
        const target_start = separator_start + separator.len;
        const target_name = std.mem.trim(u8, text[target_start..], " ");
        const target = units.find(target_name) orelse continue;

        // The source unit is the trailing word of the left side; it may be
        // glued to the number ("10km").
        var split = left.len;
        while (split > 0 and !endsAmount(left[split - 1])) {
            split -= 1;
        }
        const source_name = std.mem.trim(u8, left[split..], " ");
        const source = units.find(source_name) orelse continue;
        if (source.dimension != target.dimension) continue;

        const expression = std.mem.trim(u8, left[0..split], " ");
        var parser: Parser = .{ .source = expression };
        const amount = parser.parseExpression() catch continue;
        parser.skipSpaces();
        if (parser.offset != expression.len) continue;

        const base = amount * source.factor + source.offset;
        const converted = (base - target.offset) / target.factor;
        // "1e308 km to mm" overflows; "(-1)^0.5 m to ft" is nan.
        if (!std.math.isFinite(converted)) return null;
        return .{ .value = converted, .unit = target.names[0], .from_unit = source.names[0] };
    }
    return null;
}

/// A character that ends the amount before a unit name: "10 km", "10km",
/// "(5 + 5) km".
fn endsAmount(char: u8) bool {
    return std.ascii.isDigit(char) or char == ' ' or char == ')';
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i = haystack.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ---------------------------------------------------------------- formatting

/// Formats for display: thousands separators and at most 4 decimals
/// ("1,234.5", "6.2137"). Copying uses `formatPlain`, at full precision.
/// Never writes past `display_buffer` (32 bytes always suffice; a shorter
/// one may get a truncated result).
pub fn formatDisplay(display_buffer: []u8, value: f64) []const u8 {
    var raw: [64]u8 = undefined;
    // Below 1e15 (where formatPlain switches to exponents) and above 1e-4,
    // fixed point with 4 decimals, rounded from the exact value.
    const fixed_point = @abs(value) >= 1e-4 and @abs(value) < 1e15;
    const plain = if (fixed_point) fixed4(&raw, value) else formatPlain(&raw, value);
    // Exponents, inf and nan are left alone.
    if (std.mem.findAny(u8, plain, "ein") != null) return copyInto(display_buffer, plain);
    const negative = plain.len > 0 and plain[0] == '-';
    const digits = if (negative) plain[1..] else plain;
    const dot = std.mem.findScalar(u8, digits, '.') orelse digits.len;
    const commas = if (dot > 0) (dot - 1) / 3 else 0;
    if (plain.len + commas > display_buffer.len) return copyInto(display_buffer, plain);

    var written: usize = 0;
    if (negative) {
        display_buffer[written] = '-';
        written += 1;
    }
    for (digits[0..dot], 0..) |digit, i| {
        if (i > 0 and (dot - i) % 3 == 0) {
            display_buffer[written] = ',';
            written += 1;
        }
        display_buffer[written] = digit;
        written += 1;
    }
    @memcpy(display_buffer[written .. written + digits.len - dot], digits[dot..]);
    written += digits.len - dot;
    return display_buffer[0..written];
}

/// "{d:.4}" without trailing zeros: "1234.5", "6.2137", "-3".
fn fixed4(text_buffer: []u8, value: f64) []const u8 {
    const text = std.mem.print(text_buffer, "{d:.4}", .{value}) catch return "?";
    var end = text.len;
    if (std.mem.findScalar(u8, text, '.') != null) {
        while (text[end - 1] == '0') end -= 1;
        if (text[end - 1] == '.') end -= 1;
    }
    // -0.00004 rounds to "-0".
    if (std.mem.eql(u8, text[0..end], "-0")) return "0";
    return text[0..end];
}

/// Formats for copying: no separators, no trailing zeros: "1234.5".
pub fn formatPlain(plain_buffer: []u8, value: f64) []const u8 {
    // Below 1e-12 is a zero the arithmetic did not reach exactly.
    const rounded = if (@abs(value) < 1e-12) 0 else value;
    if (rounded == @trunc(rounded) and @abs(rounded) < 1e15) {
        return std.mem.print(plain_buffer, "{d}", .{@as(i64, @intFromFloat(rounded))}) catch "?";
    }
    if (@abs(rounded) >= 1e15 or @abs(rounded) < 1e-6) {
        return std.mem.print(plain_buffer, "{e:.6}", .{rounded}) catch "?";
    }
    const text = std.mem.print(plain_buffer, "{d:.10}", .{rounded}) catch return "?";
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

fn copyInto(destination: []u8, text: []const u8) []const u8 {
    const copied = @min(text.len, destination.len);
    @memcpy(destination[0..copied], text[0..copied]);
    return destination[0..copied];
}

// ---------------------------------------------------------------- tests

fn expectValue(input: []const u8, want: f64) !void {
    const result = evaluate(input) orelse {
        std.debug.print("no result for '{s}'\n", .{input});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectApproxEqRel(want, result.value, 1e-9);
}

test "arithmetic and precedence" {
    try expectValue("2 + 3 * 4", 14);
    try expectValue("(1 + 2)^3", 27);
    try expectValue("2^3^2", 512);
    try expectValue("-2^2", -4);
    try expectValue("10 / 4", 2.5);
    try expectValue("7 mod 3", 1);
    try expectValue("1,000 * 2", 2000);
}

test "functions, constants, postfix" {
    try expectValue("sqrt(16) + 2", 6);
    try expectValue("5!", 120);
    try expectValue("2pi", 2 * std.math.pi);
    try expectValue("20% of 80", 16);
    try expectValue("0xff + 1", 256);
}

test "not a calculation" {
    try std.testing.expect(evaluate("firefox") == null);
    try std.testing.expect(evaluate("42") == null);
    try std.testing.expect(evaluate("pi") == null);
    try std.testing.expect(evaluate("2 +") == null);
    try std.testing.expect(evaluate("1/0") == null);
    try std.testing.expect(evaluate("code 2") == null);
}

test "unit conversions" {
    try expectValue("10 km to mi", 6.2137119223733395);
    try expectValue("100 f in c", 37.77777777777778);
    try expectValue("0 c to k", 273.15);
    try expectValue("1 gb to mb", 1024);
    try expectValue("90 min in h", 1.5);
    try expectValue("2*5kg to lb", 22.046226218487757);
    try std.testing.expect(evaluate("10 km to kg") == null);
    try std.testing.expectEqualStrings("mi", evaluate("1 km to miles").?.unit);
}

test "formatting" {
    var text_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1,234,567", formatDisplay(&text_buffer, 1234567));
    try std.testing.expectEqualStrings("-1,234.5", formatDisplay(&text_buffer, -1234.5));
    try std.testing.expectEqualStrings("6.2137", formatDisplay(&text_buffer, 6.2137119223733395));
    try std.testing.expectEqualStrings("0.3333333333", formatPlain(&text_buffer, 1.0 / 3.0));
    try std.testing.expectEqualStrings("42", formatPlain(&text_buffer, 42));
}

/// `text` repeated `count` times, at comptime (Zig 0.17 has no `**`).
fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    const done = comptime blk: {
        @setEvalBranchQuota(count * 10 + 1000);
        var out: [text.len * count]u8 = undefined;
        for (0..count) |i| @memcpy(out[i * text.len ..][0..text.len], text);
        break :blk out;
    };
    return &done;
}

test "hostile input: deep nesting, overflowing conversions, huge values" {
    // Pasting thousands of "(" or "-" must not overflow the stack.
    const deep = repeat("(", 5000) ++ "1+1" ++ repeat(")", 5000);
    try std.testing.expect(evaluate(deep) == null);
    try std.testing.expect(evaluate(repeat("-", 5000) ++ "1+1") == null);
    try std.testing.expect(evaluate("2" ++ repeat("^2", 5000)) == null);
    try expectValue(repeat("(", 20) ++ "1+1" ++ repeat(")", 20), 2);
    // Conversions whose result is not finite are not results.
    try std.testing.expect(evaluate("1e308 km to mm") == null);
    try std.testing.expect(evaluate("(-8)^(1/3) m to ft") == null);

    var text_buffer: [32]u8 = undefined;
    // Large values used to round through v * 1e4, which overflowed to inf.
    try std.testing.expectEqualStrings("1.000000e305", formatDisplay(&text_buffer, 1e305));
    try std.testing.expectEqualStrings("inf", formatDisplay(&text_buffer, std.math.inf(f64)));
    try std.testing.expectEqualStrings("-inf", formatDisplay(&text_buffer, -std.math.inf(f64)));
    try std.testing.expectEqualStrings("nan", formatDisplay(&text_buffer, std.math.nan(f64)));
    try std.testing.expectEqualStrings("0", formatDisplay(&text_buffer, -0.0));
    try std.testing.expectEqualStrings("0", formatPlain(&text_buffer, -0.0));
    // At most 4 decimals even where binary noise shows at the 5th.
    try std.testing.expectEqualStrings(
        "123,456,789,012.3456",
        formatDisplay(&text_buffer, 123456789012.3456),
    );
    try std.testing.expectEqualStrings(
        "-999,999,999,999,999.9",
        formatDisplay(&text_buffer, -999999999999999.9),
    );
    try std.testing.expectEqualStrings("0.00005", formatDisplay(&text_buffer, 0.00005));
    // A buffer too small gets a truncated result, never an overflow.
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("1234", formatDisplay(&tiny, 1234567));
}

fn fuzzEvaluate(_: void, smith: *std.testing.Smith) anyerror!void {
    // Mostly the calculator's own alphabet, so the fuzzer forms expressions.
    const weights: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, '0', '9', 8),
        .value(u8, '+', 4),
        .value(u8, '-', 4),
        .value(u8, '*', 4),
        .value(u8, '/', 4),
        .value(u8, '^', 4),
        .value(u8, '(', 4),
        .value(u8, ')', 4),
        .value(u8, '!', 3),
        .value(u8, '%', 3),
        .value(u8, '.', 3),
        .value(u8, ',', 3),
        .value(u8, ' ', 4),
        .value(u8, 'e', 3),
        .value(u8, 'x', 2),
        .rangeAtMost(u8, 'a', 'z', 1),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var input_buffer: [200]u8 = undefined;
    const input = input_buffer[0..smith.sliceWeightedBytes(&input_buffer, weights)];
    if (evaluate(input)) |result| {
        try std.testing.expect(std.math.isFinite(result.value));
        var text_buffer: [32]u8 = undefined;
        _ = formatDisplay(&text_buffer, result.value);
        _ = formatPlain(&text_buffer, result.value);
    }
}

test "fuzz: evaluate never crashes and only returns finite values" {
    const seeds = [_][]const u8{
        "2 + 3 * 4",
        "(1 + 2)^3",
        "sqrt(16) + 2!",
        "20% of 80",
        "0xff + 0b101",
        "10 km to mi",
        "100 f in c",
        "1,000.5e3 mod 7",
        "2pi - ln(e)",
        "1e308 * 10 kg to lb",
    };
    // The fuzzer reads each corpus entry as a u32 length and the bytes.
    const corpus = comptime blk: {
        var entries: [seeds.len][]const u8 = undefined;
        for (seeds, &entries) |seed, *entry| {
            const seed_len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, seed.len));
            entry.* = &seed_len ++ seed;
        }
        break :blk entries;
    };
    try std.testing.fuzz({}, fuzzEvaluate, .{ .corpus = &corpus });
}

fn fuzzFormat(_: void, smith: *std.testing.Smith) anyerror!void {
    const value: f64 = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        // Any bit pattern: nan, inf, subnormals and -0 among them.
        0 => smith.value(f64),
        1 => @floatFromInt(smith.value(i64)),
        2 => @as(f64, @floatFromInt(smith.value(i32))) / 10000.0,
        else => blk: {
            const exponent: f64 = @floatFromInt(smith.valueRangeAtMost(i16, -330, 330));
            const sign: f64 = if (smith.value(bool)) -1 else 1;
            break :blk sign * std.math.pow(f64, 10, exponent);
        },
    };
    // Every buffer size, down to none: never a write past the end.
    var big: [64]u8 = undefined;
    const size = smith.valueRangeAtMost(u8, 0, 64);
    const display_short = formatDisplay(big[0..size], value);
    const plain_short = formatPlain(big[0..size], value);
    try std.testing.expect(display_short.len <= @max(size, 1));
    try std.testing.expect(plain_short.len <= @max(size, 1));
    // The buffers the UI uses always hold the whole number.
    var display_buffer: [32]u8 = undefined;
    const display = formatDisplay(&display_buffer, value);
    var plain_buffer: [64]u8 = undefined;
    const plain = formatPlain(&plain_buffer, value);
    try std.testing.expect(display.len < display_buffer.len);
    try std.testing.expect(plain.len < plain_buffer.len);
    try std.testing.expect(!std.mem.eql(u8, plain, "?"));
    // What is copied reads back as the value.
    if (std.math.isFinite(value)) {
        const back = try std.fmt.parseFloat(f64, plain);
        try std.testing.expect(@abs(back - value) <= @max(@abs(value) * 1e-6, 1e-10));
    }
}

test "fuzz: formatting any f64 fits its buffer" {
    try std.testing.fuzz({}, fuzzFormat, .{});
}
