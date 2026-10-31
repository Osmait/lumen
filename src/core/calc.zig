//! Inline calculator for the search bar.
//!
//!   2 + 3 * 4        (1 + 2)^3       sqrt(16) + 2!      20% of 80
//!   10 km to mi      100 f in c      5 gb to mb         90 min to h
//!
//! `evaluate` returns null for anything that is not clearly a calculation, so
//! typing an app name never shows a result.

const std = @import("std");
const assert = std.debug.assert;

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

    if (splitConversion(text)) |conv| return conv;

    var parser: Parser = .{ .source = text };
    const value = parser.parseExpr() catch return null;
    // Every level parseUnary entered, it left.
    assert(parser.depth == 0);
    parser.skipSpaces();
    if (parser.pos != text.len) return null;
    if (!parser.saw_operator) return null;
    if (!std.math.isFinite(value)) return null;
    return .{ .value = value };
}

/// Formats for display: thousands separators and at most 4 decimals
/// ("1,234.5", "6.2137"). Copying uses `formatPlain`, at full precision.
/// Never writes past `buf` (32 bytes always suffice; a shorter one may get
/// a truncated result).
pub fn formatDisplay(buf: []u8, value: f64) []const u8 {
    var raw: [64]u8 = undefined;
    // Below 1e15 (where formatPlain switches to exponents) and above 1e-4,
    // fixed point with 4 decimals, rounded from the exact value.
    const fixed_point = @abs(value) >= 1e-4 and @abs(value) < 1e15;
    const plain = if (fixed_point) fixed4(&raw, value) else formatPlain(&raw, value);
    // Exponents, inf and nan are left alone.
    if (std.mem.findAny(u8, plain, "ein") != null) return copyInto(buf, plain);
    const negative = plain.len > 0 and plain[0] == '-';
    const digits = if (negative) plain[1..] else plain;
    const dot = std.mem.findScalar(u8, digits, '.') orelse digits.len;
    const commas = if (dot > 0) (dot - 1) / 3 else 0;
    if (plain.len + commas > buf.len) return copyInto(buf, plain);

    var out: usize = 0;
    if (negative) {
        buf[out] = '-';
        out += 1;
    }
    for (digits[0..dot], 0..) |ch, i| {
        if (i > 0 and (dot - i) % 3 == 0) {
            buf[out] = ',';
            out += 1;
        }
        buf[out] = ch;
        out += 1;
    }
    @memcpy(buf[out .. out + digits.len - dot], digits[dot..]);
    out += digits.len - dot;
    return buf[0..out];
}

/// "{d:.4}" without trailing zeros: "1234.5", "6.2137", "-3".
fn fixed4(buf: []u8, value: f64) []const u8 {
    const text = std.mem.print(buf, "{d:.4}", .{value}) catch return "?";
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
pub fn formatPlain(buf: []u8, value: f64) []const u8 {
    // Below 1e-12 is a zero the arithmetic did not reach exactly.
    const rounded = if (@abs(value) < 1e-12) 0 else value;
    if (rounded == @trunc(rounded) and @abs(rounded) < 1e15) {
        return std.mem.print(buf, "{d}", .{@as(i64, @intFromFloat(rounded))}) catch "?";
    }
    if (@abs(rounded) >= 1e15 or @abs(rounded) < 1e-6) {
        return std.mem.print(buf, "{e:.6}", .{rounded}) catch "?";
    }
    const text = std.mem.print(buf, "{d:.10}", .{rounded}) catch return "?";
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

fn copyInto(buf: []u8, text: []const u8) []const u8 {
    const copied = @min(text.len, buf.len);
    @memcpy(buf[0..copied], text[0..copied]);
    return buf[0..copied];
}

fn hasDigit(text: []const u8) bool {
    for (text) |char| {
        if (std.ascii.isDigit(char)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- units

const Dim = enum { length, mass, time, data, temperature, volume, speed, area };

const Unit = struct {
    names: []const []const u8,
    dim: Dim,
    /// Value in the base unit of `dim` for 1 of this unit.
    factor: f64,
    /// Added after scaling (temperature only; base is kelvin).
    offset: f64 = 0,
};

const units = [_]Unit{
    // length, base metre
    .{
        .names = &.{ "mm", "millimeter", "millimeters", "millimetre" },
        .dim = .length,
        .factor = 0.001,
    },
    .{
        .names = &.{ "cm", "centimeter", "centimeters", "centimetre" },
        .dim = .length,
        .factor = 0.01,
    },
    .{ .names = &.{ "m", "meter", "meters", "metre", "metres" }, .dim = .length, .factor = 1 },
    .{
        .names = &.{ "km", "kilometer", "kilometers", "kilometre" },
        .dim = .length,
        .factor = 1000,
    },
    .{ .names = &.{ "in", "inch", "inches" }, .dim = .length, .factor = 0.0254 },
    .{ .names = &.{ "ft", "foot", "feet" }, .dim = .length, .factor = 0.3048 },
    .{ .names = &.{ "yd", "yard", "yards" }, .dim = .length, .factor = 0.9144 },
    .{ .names = &.{ "mi", "mile", "miles" }, .dim = .length, .factor = 1609.344 },
    // mass, base kilogram
    .{ .names = &.{ "mg", "milligram", "milligrams" }, .dim = .mass, .factor = 1e-6 },
    .{ .names = &.{ "g", "gram", "grams" }, .dim = .mass, .factor = 0.001 },
    .{ .names = &.{ "kg", "kilogram", "kilograms", "kilo", "kilos" }, .dim = .mass, .factor = 1 },
    .{ .names = &.{ "t", "ton", "tons", "tonne", "tonnes" }, .dim = .mass, .factor = 1000 },
    .{ .names = &.{ "oz", "ounce", "ounces" }, .dim = .mass, .factor = 0.028349523125 },
    .{ .names = &.{ "lb", "lbs", "pound", "pounds" }, .dim = .mass, .factor = 0.45359237 },
    // time, base second
    .{ .names = &.{ "ms", "millisecond", "milliseconds" }, .dim = .time, .factor = 0.001 },
    .{ .names = &.{ "s", "sec", "second", "seconds" }, .dim = .time, .factor = 1 },
    .{ .names = &.{ "min", "minute", "minutes" }, .dim = .time, .factor = 60 },
    .{ .names = &.{ "h", "hr", "hour", "hours" }, .dim = .time, .factor = 3600 },
    .{ .names = &.{ "d", "day", "days" }, .dim = .time, .factor = 86400 },
    .{ .names = &.{ "wk", "week", "weeks" }, .dim = .time, .factor = 604800 },
    .{ .names = &.{ "yr", "year", "years" }, .dim = .time, .factor = 31557600 },
    // data, base byte (binary multiples, as file managers show them)
    .{ .names = &.{ "b", "byte", "bytes" }, .dim = .data, .factor = 1 },
    .{ .names = &.{ "kb", "kib", "kilobyte", "kilobytes" }, .dim = .data, .factor = 1024 },
    .{ .names = &.{ "mb", "mib", "megabyte", "megabytes" }, .dim = .data, .factor = 1024 * 1024 },
    .{
        .names = &.{ "gb", "gib", "gigabyte", "gigabytes" },
        .dim = .data,
        .factor = 1024 * 1024 * 1024,
    },
    .{
        .names = &.{ "tb", "tib", "terabyte", "terabytes" },
        .dim = .data,
        .factor = 1024 * 1024 * 1024 * 1024,
    },
    // temperature, base kelvin
    .{ .names = &.{ "c", "celsius", "°c" }, .dim = .temperature, .factor = 1, .offset = 273.15 },
    .{
        .names = &.{ "f", "fahrenheit", "°f" },
        .dim = .temperature,
        .factor = 5.0 / 9.0,
        .offset = 273.15 - 32.0 * 5.0 / 9.0,
    },
    .{ .names = &.{ "k", "kelvin" }, .dim = .temperature, .factor = 1 },
    // volume, base litre
    .{
        .names = &.{ "ml", "milliliter", "milliliters", "millilitre" },
        .dim = .volume,
        .factor = 0.001,
    },
    .{ .names = &.{ "l", "liter", "liters", "litre", "litres" }, .dim = .volume, .factor = 1 },
    .{ .names = &.{ "gal", "gallon", "gallons" }, .dim = .volume, .factor = 3.785411784 },
    .{ .names = &.{ "cup", "cups" }, .dim = .volume, .factor = 0.2365882365 },
    .{ .names = &.{ "floz", "fl oz" }, .dim = .volume, .factor = 0.0295735295625 },
    // speed, base m/s
    .{ .names = &.{ "kmh", "km/h", "kph" }, .dim = .speed, .factor = 1000.0 / 3600.0 },
    .{ .names = &.{"mph"}, .dim = .speed, .factor = 0.44704 },
    .{ .names = &.{ "m/s", "mps" }, .dim = .speed, .factor = 1 },
    .{ .names = &.{ "kn", "knot", "knots" }, .dim = .speed, .factor = 0.514444 },
    // area, base m²
    .{ .names = &.{ "m2", "sqm" }, .dim = .area, .factor = 1 },
    .{ .names = &.{ "km2", "sqkm" }, .dim = .area, .factor = 1e6 },
    .{ .names = &.{ "ft2", "sqft" }, .dim = .area, .factor = 0.09290304 },
    .{ .names = &.{ "ha", "hectare", "hectares" }, .dim = .area, .factor = 10000 },
    .{ .names = &.{ "acre", "acres" }, .dim = .area, .factor = 4046.8564224 },
};

fn findUnit(name: []const u8) ?*const Unit {
    for (&units) |*unit| {
        for (unit.names) |unit_name| {
            if (std.ascii.eqlIgnoreCase(unit_name, name)) return unit;
        }
    }
    return null;
}

/// "<expr> <unit> to|in|as <unit>"
fn splitConversion(text: []const u8) ?Result {
    const separators = [_][]const u8{ " to ", " in ", " as " };
    for (separators) |separator| {
        const at = lastIndexOfIgnoreCase(text, separator) orelse continue;
        const left = std.mem.trim(u8, text[0..at], " ");
        const target_name = std.mem.trim(u8, text[at + separator.len ..], " ");
        const target = findUnit(target_name) orelse continue;

        // The source unit is the trailing word of the left side; it may be
        // glued to the number ("10km").
        var split = left.len;
        while (split > 0 and !endsAmount(left[split - 1])) {
            split -= 1;
        }
        const source_name = std.mem.trim(u8, left[split..], " ");
        const source = findUnit(source_name) orelse continue;
        if (source.dim != target.dim) continue;

        const expr = std.mem.trim(u8, left[0..split], " ");
        var parser: Parser = .{ .source = expr };
        const amount = parser.parseExpr() catch continue;
        parser.skipSpaces();
        if (parser.pos != expr.len) continue;

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

// --------------------------------------------------------------- parser

const Error = error{ Syntax, Domain, TooDeep };

/// Nesting allowed (parentheses, signs, exponents): the parser recurses, and
/// pasting 100k "(" must not overflow the stack.
const depth_max = 64;

/// The largest n whose n! fits an f64 (171! is inf).
const factorial_argument_max = 170;

const Parser = struct {
    source: []const u8,
    pos: usize = 0,
    saw_operator: bool = false,
    depth: u32 = 0,

    fn skipSpaces(parser: *Parser) void {
        while (parser.pos < parser.source.len and parser.source[parser.pos] == ' ') parser.pos += 1;
    }

    fn peek(parser: *Parser) u8 {
        parser.skipSpaces();
        return if (parser.pos < parser.source.len) parser.source[parser.pos] else 0;
    }

    fn eatWord(parser: *Parser, word: []const u8) bool {
        parser.skipSpaces();
        const end = parser.pos + word.len;
        if (end > parser.source.len) return false;
        if (!std.ascii.eqlIgnoreCase(parser.source[parser.pos..end], word)) return false;
        if (end < parser.source.len and std.ascii.isAlphabetic(parser.source[end])) return false;
        parser.pos = end;
        return true;
    }

    // expr := term (('+' | '-') term)*
    fn parseExpr(parser: *Parser) Error!f64 {
        var value = try parser.parseTerm();
        while (true) {
            switch (parser.peek()) {
                '+' => {
                    parser.pos += 1;
                    parser.saw_operator = true;
                    value += try parser.parseTerm();
                },
                '-' => {
                    parser.pos += 1;
                    parser.saw_operator = true;
                    value -= try parser.parseTerm();
                },
                else => return value,
            }
        }
    }

    // term := power (('*' | '/' | 'x' | 'mod' | 'of' | implicit) power)*
    fn parseTerm(parser: *Parser) Error!f64 {
        var value = try parser.parseUnary();
        while (true) {
            const next = parser.peek();
            if (next == '*' or next == '/') {
                parser.pos += 1;
                parser.saw_operator = true;
                const rhs = try parser.parseUnary();
                if (next == '*') {
                    value *= rhs;
                } else {
                    if (rhs == 0) return error.Domain;
                    value /= rhs;
                }
            } else if (parser.eatWord("mod")) {
                parser.saw_operator = true;
                const rhs = try parser.parseUnary();
                if (rhs == 0) return error.Domain;
                value = @mod(value, rhs);
            } else if (parser.eatWord("of")) {
                parser.saw_operator = true;
                value *= try parser.parseUnary();
            } else if (parser.startsImplicitProduct(next)) {
                // Implicit multiplication: 2(3+1), 2pi
                parser.saw_operator = true;
                value *= try parser.parseUnary();
            } else {
                return value;
            }
        }
    }

    /// A factor right after another with no operator between: "(" or the
    /// name of a function or a constant.
    fn startsImplicitProduct(parser: *Parser, next: u8) bool {
        if (next == '(') return true;
        return std.ascii.isAlphabetic(next) and parser.startsFunctionOrConstant();
    }

    /// Every recursive path (parentheses, function arguments, signs,
    /// exponents) goes through here, so the depth is counted here.
    fn parseUnary(parser: *Parser) Error!f64 {
        if (parser.depth == depth_max) return error.TooDeep;
        assert(parser.depth < depth_max);
        parser.depth += 1;
        defer {
            assert(parser.depth > 0);
            parser.depth -= 1;
        }
        const sign = parser.peek();
        if (sign == '-') {
            parser.pos += 1;
            return -(try parser.parseUnary());
        }
        if (sign == '+') {
            parser.pos += 1;
            return parser.parseUnary();
        }
        return parser.parsePower();
    }

    // power := postfix ('^' unary)?   (right associative)
    fn parsePower(parser: *Parser) Error!f64 {
        const base = try parser.parsePostfix();
        const operator_len = parser.powerOperatorLen();
        if (operator_len == 0) return base;
        parser.pos += operator_len;
        parser.saw_operator = true;
        const exponent = try parser.parseUnary();
        return std.math.pow(f64, base, exponent);
    }

    /// 1 for "^", 2 for "**", 0 when the next token is neither.
    fn powerOperatorLen(parser: *Parser) usize {
        const next = parser.peek();
        if (next == '^') return 1;
        if (next != '*') return 0;
        const after = parser.pos + 1;
        if (after < parser.source.len and parser.source[after] == '*') return 2;
        return 0;
    }

    fn parsePostfix(parser: *Parser) Error!f64 {
        var value = try parser.parsePrimary();
        while (true) {
            switch (parser.peek()) {
                '!' => {
                    parser.pos += 1;
                    parser.saw_operator = true;
                    value = try factorial(value);
                },
                '%' => {
                    parser.pos += 1;
                    parser.saw_operator = true;
                    value /= 100;
                },
                else => return value,
            }
        }
    }

    fn parsePrimary(parser: *Parser) Error!f64 {
        const next = parser.peek();
        if (next == '(') {
            parser.pos += 1;
            const value = try parser.parseExpr();
            if (parser.peek() != ')') return error.Syntax;
            parser.pos += 1;
            return value;
        }
        if (std.ascii.isDigit(next) or next == '.') return parser.parseNumber();
        if (std.ascii.isAlphabetic(next)) return parser.parseIdent();
        return error.Syntax;
    }

    fn parseNumber(parser: *Parser) Error!f64 {
        const start = parser.pos;
        const rest = parser.source[parser.pos..];
        // The letter of a "0x" or "0b" prefix, or 0 when there is none.
        const radix_letter: u8 = if (rest.len >= 2 and rest[0] == '0') rest[1] else 0;
        if (radix_letter == 'x' or radix_letter == 'b') {
            const radix: u8 = if (radix_letter == 'x') 16 else 2;
            parser.pos += 2;
            const digits_start = parser.pos;
            parser.skipWhile(std.ascii.isAlphanumeric);
            const digits = parser.source[digits_start..parser.pos];
            const integer = std.fmt.parseInt(i64, digits, radix) catch return error.Syntax;
            return @floatFromInt(integer);
        }
        while (parser.pos < parser.source.len) : (parser.pos += 1) {
            const char = parser.source[parser.pos];
            if (std.ascii.isDigit(char) or char == '.' or char == '_') continue;
            // Thousands separator only when followed by exactly three digits.
            if (char == ',' and isThreeDigits(parser.source[parser.pos + 1 ..])) continue;
            if ((char == 'e' or char == 'E') and parser.startsExponent()) {
                parser.pos += 1;
                continue;
            }
            break;
        }
        var digits_buffer: [64]u8 = undefined;
        var digits_len: usize = 0;
        for (parser.source[start..parser.pos]) |char| {
            if (char == ',' or char == '_') continue;
            if (digits_len == digits_buffer.len) return error.Syntax;
            digits_buffer[digits_len] = char;
            digits_len += 1;
        }
        return std.fmt.parseFloat(f64, digits_buffer[0..digits_len]) catch error.Syntax;
    }

    /// After an "e" at `pos`: a digit or a minus sign, as in "1e3" or "1e-3".
    fn startsExponent(parser: *Parser) bool {
        const after = parser.pos + 1;
        if (after == parser.source.len) return false;
        const char = parser.source[after];
        return std.ascii.isDigit(char) or char == '-';
    }

    fn skipWhile(parser: *Parser, comptime accept: fn (u8) bool) void {
        while (parser.pos < parser.source.len and accept(parser.source[parser.pos])) {
            parser.pos += 1;
        }
    }

    fn startsFunctionOrConstant(parser: *Parser) bool {
        var end = parser.pos;
        while (end < parser.source.len and std.ascii.isAlphabetic(parser.source[end])) end += 1;
        const name = parser.source[parser.pos..end];
        return constant(name) != null or function(name) != null;
    }

    fn parseIdent(parser: *Parser) Error!f64 {
        const start = parser.pos;
        parser.skipWhile(std.ascii.isAlphanumeric);
        const name = parser.source[start..parser.pos];
        if (constant(name)) |value| return value;
        const apply = function(name) orelse return error.Syntax;
        if (parser.peek() != '(') return error.Syntax;
        parser.pos += 1;
        const arg = try parser.parseExpr();
        if (parser.peek() != ')') return error.Syntax;
        parser.pos += 1;
        parser.saw_operator = true;
        return apply(arg);
    }
};

/// Exactly three digits at the start of `text`, and no fourth.
fn isThreeDigits(text: []const u8) bool {
    if (text.len < 3) return false;
    for (text[0..3]) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return text.len == 3 or !std.ascii.isDigit(text[3]);
}

fn factorial(argument: f64) Error!f64 {
    if (argument < 0) return error.Domain;
    if (argument != @trunc(argument)) return error.Domain;
    if (argument > factorial_argument_max) return error.Domain;
    var product: f64 = 1;
    var factor: f64 = 2;
    while (factor <= argument) : (factor += 1) product *= factor;
    assert(std.math.isFinite(product));
    return product;
}

fn constant(name: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(name, "pi")) return std.math.pi;
    if (std.ascii.eqlIgnoreCase(name, "e")) return std.math.e;
    if (std.ascii.eqlIgnoreCase(name, "tau")) return std.math.tau;
    return null;
}

const Fn = *const fn (f64) Error!f64;

fn function(name: []const u8) ?Fn {
    const table = .{
        .{ "sqrt", fnSqrt },   .{ "abs", fnAbs },   .{ "ln", fnLn },
        .{ "log", fnLog10 },   .{ "log2", fnLog2 }, .{ "sin", fnSin },
        .{ "cos", fnCos },     .{ "tan", fnTan },   .{ "round", fnRound },
        .{ "floor", fnFloor }, .{ "ceil", fnCeil }, .{ "exp", fnExp },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return null;
}

fn fnSqrt(x: f64) Error!f64 {
    if (x < 0) return error.Domain;
    return @sqrt(x);
}
fn fnAbs(x: f64) Error!f64 {
    return @abs(x);
}
fn fnLn(x: f64) Error!f64 {
    if (x <= 0) return error.Domain;
    return @log(x);
}
fn fnLog10(x: f64) Error!f64 {
    if (x <= 0) return error.Domain;
    return @log10(x);
}
fn fnLog2(x: f64) Error!f64 {
    if (x <= 0) return error.Domain;
    return @log2(x);
}
fn fnSin(x: f64) Error!f64 {
    return @sin(x);
}
fn fnCos(x: f64) Error!f64 {
    return @cos(x);
}
fn fnTan(x: f64) Error!f64 {
    return @tan(x);
}
fn fnRound(x: f64) Error!f64 {
    return @round(x);
}
fn fnFloor(x: f64) Error!f64 {
    return @floor(x);
}
fn fnCeil(x: f64) Error!f64 {
    return @ceil(x);
}
fn fnExp(x: f64) Error!f64 {
    return @exp(x);
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
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1,234,567", formatDisplay(&buf, 1234567));
    try std.testing.expectEqualStrings("-1,234.5", formatDisplay(&buf, -1234.5));
    try std.testing.expectEqualStrings("6.2137", formatDisplay(&buf, 6.2137119223733395));
    try std.testing.expectEqualStrings("0.3333333333", formatPlain(&buf, 1.0 / 3.0));
    try std.testing.expectEqualStrings("42", formatPlain(&buf, 42));
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

    var buf: [32]u8 = undefined;
    // Large values used to round through v * 1e4, which overflowed to inf.
    try std.testing.expectEqualStrings("1.000000e305", formatDisplay(&buf, 1e305));
    try std.testing.expectEqualStrings("inf", formatDisplay(&buf, std.math.inf(f64)));
    try std.testing.expectEqualStrings("-inf", formatDisplay(&buf, -std.math.inf(f64)));
    try std.testing.expectEqualStrings("nan", formatDisplay(&buf, std.math.nan(f64)));
    try std.testing.expectEqualStrings("0", formatDisplay(&buf, -0.0));
    try std.testing.expectEqualStrings("0", formatPlain(&buf, -0.0));
    // At most 4 decimals even where binary noise shows at the 5th.
    try std.testing.expectEqualStrings(
        "123,456,789,012.3456",
        formatDisplay(&buf, 123456789012.3456),
    );
    try std.testing.expectEqualStrings(
        "-999,999,999,999,999.9",
        formatDisplay(&buf, -999999999999999.9),
    );
    try std.testing.expectEqualStrings("0.00005", formatDisplay(&buf, 0.00005));
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
        var buf: [32]u8 = undefined;
        _ = formatDisplay(&buf, result.value);
        _ = formatPlain(&buf, result.value);
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
            const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, seed.len));
            entry.* = &len ++ seed;
        }
        break :blk entries;
    };
    try std.testing.fuzz({}, fuzzEvaluate, .{ .corpus = &corpus });
}

fn fuzzFormat(_: void, smith: *std.testing.Smith) anyerror!void {
    const value: f64 = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => smith.value(f64), // any bit pattern: nan, inf, subnormals, -0
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
