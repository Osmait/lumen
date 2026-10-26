//! Inline calculator for the search bar.
//!
//!   2 + 3 * 4        (1 + 2)^3       sqrt(16) + 2!      20% of 80
//!   10 km to mi      100 f in c      5 gb to mb         90 min to h
//!
//! `evaluate` returns null for anything that is not clearly a calculation, so
//! typing an app name never shows a result.

const std = @import("std");

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

    var p: Parser = .{ .src = text };
    const v = p.parseExpr() catch return null;
    p.skipSpaces();
    if (p.pos != text.len) return null;
    if (!p.saw_operator) return null;
    if (std.math.isNan(v) or std.math.isInf(v)) return null;
    return .{ .value = v };
}

/// Formats for display: thousands separators and at most 4 decimals
/// ("1,234.5", "6.2137"). Copying uses `formatPlain`, at full precision.
/// Never writes past `buf` (32 bytes always suffice; a shorter one may get
/// a truncated result).
pub fn formatDisplay(buf: []u8, v: f64) []const u8 {
    var raw: [64]u8 = undefined;
    // Below 1e15 (where formatPlain switches to exponents) and above 1e-4,
    // fixed point with 4 decimals, rounded from the exact value.
    const plain = if (@abs(v) >= 1e-4 and @abs(v) < 1e15) fixed4(&raw, v) else formatPlain(&raw, v);
    // Exponents, inf and nan are left alone.
    if (std.mem.findAny(u8, plain, "ein") != null) return copyInto(buf, plain);
    const neg = plain.len > 0 and plain[0] == '-';
    const digits = if (neg) plain[1..] else plain;
    const dot = std.mem.findScalar(u8, digits, '.') orelse digits.len;
    const commas = if (dot > 0) (dot - 1) / 3 else 0;
    if (plain.len + commas > buf.len) return copyInto(buf, plain);

    var out: usize = 0;
    if (neg) {
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
fn fixed4(buf: []u8, v: f64) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch return "?";
    var end = s.len;
    if (std.mem.findScalar(u8, s, '.') != null) {
        while (s[end - 1] == '0') end -= 1;
        if (s[end - 1] == '.') end -= 1;
    }
    // -0.00004 rounds to "-0".
    if (std.mem.eql(u8, s[0..end], "-0")) return "0";
    return s[0..end];
}

/// Formats for copying: no separators, no trailing zeros: "1234.5".
pub fn formatPlain(buf: []u8, v: f64) []const u8 {
    const r = if (@abs(v) < 1e-12) 0 else v;
    if (r == @trunc(r) and @abs(r) < 1e15) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(r))}) catch "?";
    }
    if (@abs(r) >= 1e15 or @abs(r) < 1e-6) {
        return std.fmt.bufPrint(buf, "{e:.6}", .{r}) catch "?";
    }
    const s = std.fmt.bufPrint(buf, "{d:.10}", .{r}) catch return "?";
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn hasDigit(s: []const u8) bool {
    for (s) |c| if (std.ascii.isDigit(c)) return true;
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
    .{ .names = &.{ "mm", "millimeter", "millimeters", "millimetre" }, .dim = .length, .factor = 0.001 },
    .{ .names = &.{ "cm", "centimeter", "centimeters", "centimetre" }, .dim = .length, .factor = 0.01 },
    .{ .names = &.{ "m", "meter", "meters", "metre", "metres" }, .dim = .length, .factor = 1 },
    .{ .names = &.{ "km", "kilometer", "kilometers", "kilometre" }, .dim = .length, .factor = 1000 },
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
    .{ .names = &.{ "gb", "gib", "gigabyte", "gigabytes" }, .dim = .data, .factor = 1024 * 1024 * 1024 },
    .{ .names = &.{ "tb", "tib", "terabyte", "terabytes" }, .dim = .data, .factor = 1024 * 1024 * 1024 * 1024 },
    // temperature, base kelvin
    .{ .names = &.{ "c", "celsius", "°c" }, .dim = .temperature, .factor = 1, .offset = 273.15 },
    .{ .names = &.{ "f", "fahrenheit", "°f" }, .dim = .temperature, .factor = 5.0 / 9.0, .offset = 273.15 - 32.0 * 5.0 / 9.0 },
    .{ .names = &.{ "k", "kelvin" }, .dim = .temperature, .factor = 1 },
    // volume, base litre
    .{ .names = &.{ "ml", "milliliter", "milliliters", "millilitre" }, .dim = .volume, .factor = 0.001 },
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
    for (&units) |*u| {
        for (u.names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return u;
    }
    return null;
}

/// "<expr> <unit> to|in <unit>"
fn splitConversion(text: []const u8) ?Result {
    const seps = [_][]const u8{ " to ", " in ", " as " };
    for (seps) |sep| {
        const at = lastIndexOfIgnoreCase(text, sep) orelse continue;
        const left = std.mem.trim(u8, text[0..at], " ");
        const target_name = std.mem.trim(u8, text[at + sep.len ..], " ");
        const target = findUnit(target_name) orelse continue;

        // The source unit is the trailing word of the left side; it may be
        // glued to the number ("10km").
        var split = left.len;
        while (split > 0 and !std.ascii.isDigit(left[split - 1]) and left[split - 1] != ' ' and left[split - 1] != ')') split -= 1;
        const source_name = std.mem.trim(u8, left[split..], " ");
        const source = findUnit(source_name) orelse continue;
        if (source.dim != target.dim) continue;

        const expr = std.mem.trim(u8, left[0..split], " ");
        var p: Parser = .{ .src = expr };
        const amount = p.parseExpr() catch continue;
        p.skipSpaces();
        if (p.pos != expr.len) continue;

        const base = amount * source.factor + source.offset;
        const converted = (base - target.offset) / target.factor;
        // "1e308 km to mm" overflows; "(-1)^0.5 m to ft" is nan.
        if (!std.math.isFinite(converted)) return null;
        return .{ .value = converted, .unit = target.names[0], .from_unit = source.names[0] };
    }
    return null;
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
const max_depth = 64;

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    saw_operator: bool = false,
    depth: u32 = 0,

    fn skipSpaces(p: *Parser) void {
        while (p.pos < p.src.len and p.src[p.pos] == ' ') p.pos += 1;
    }

    fn peek(p: *Parser) u8 {
        p.skipSpaces();
        return if (p.pos < p.src.len) p.src[p.pos] else 0;
    }

    fn eatWord(p: *Parser, word: []const u8) bool {
        p.skipSpaces();
        const end = p.pos + word.len;
        if (end > p.src.len) return false;
        if (!std.ascii.eqlIgnoreCase(p.src[p.pos..end], word)) return false;
        if (end < p.src.len and std.ascii.isAlphabetic(p.src[end])) return false;
        p.pos = end;
        return true;
    }

    // expr := term (('+' | '-') term)*
    fn parseExpr(p: *Parser) Error!f64 {
        var v = try p.parseTerm();
        while (true) {
            switch (p.peek()) {
                '+' => {
                    p.pos += 1;
                    p.saw_operator = true;
                    v += try p.parseTerm();
                },
                '-' => {
                    p.pos += 1;
                    p.saw_operator = true;
                    v -= try p.parseTerm();
                },
                else => return v,
            }
        }
    }

    // term := power (('*' | '/' | 'x' | 'mod' | 'of' | implicit) power)*
    fn parseTerm(p: *Parser) Error!f64 {
        var v = try p.parseUnary();
        while (true) {
            const c = p.peek();
            if (c == '*' or c == '/') {
                p.pos += 1;
                p.saw_operator = true;
                const r = try p.parseUnary();
                if (c == '*') v *= r else {
                    if (r == 0) return error.Domain;
                    v /= r;
                }
            } else if (p.eatWord("mod")) {
                p.saw_operator = true;
                const r = try p.parseUnary();
                if (r == 0) return error.Domain;
                v = @mod(v, r);
            } else if (p.eatWord("of")) {
                p.saw_operator = true;
                v *= try p.parseUnary();
            } else if (c == '(' or (std.ascii.isAlphabetic(c) and p.startsFunctionOrConstant())) {
                // Implicit multiplication: 2(3+1), 2pi
                p.saw_operator = true;
                v *= try p.parseUnary();
            } else return v;
        }
    }

    /// Every recursive path (parentheses, function arguments, signs,
    /// exponents) goes through here, so the depth is counted here.
    fn parseUnary(p: *Parser) Error!f64 {
        if (p.depth >= max_depth) return error.TooDeep;
        p.depth += 1;
        defer p.depth -= 1;
        const c = p.peek();
        if (c == '-') {
            p.pos += 1;
            return -(try p.parseUnary());
        }
        if (c == '+') {
            p.pos += 1;
            return p.parseUnary();
        }
        return p.parsePower();
    }

    // power := postfix ('^' unary)?   (right associative)
    fn parsePower(p: *Parser) Error!f64 {
        const base = try p.parsePostfix();
        if (p.peek() == '^' or (p.peek() == '*' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == '*')) {
            p.pos += if (p.src[p.pos] == '^') 1 else 2;
            p.saw_operator = true;
            const exp = try p.parseUnary();
            return std.math.pow(f64, base, exp);
        }
        return base;
    }

    fn parsePostfix(p: *Parser) Error!f64 {
        var v = try p.parsePrimary();
        while (true) {
            const c = p.peek();
            if (c == '!') {
                p.pos += 1;
                p.saw_operator = true;
                v = try factorial(v);
            } else if (c == '%') {
                p.pos += 1;
                p.saw_operator = true;
                v /= 100;
            } else return v;
        }
    }

    fn parsePrimary(p: *Parser) Error!f64 {
        const c = p.peek();
        if (c == '(') {
            p.pos += 1;
            const v = try p.parseExpr();
            if (p.peek() != ')') return error.Syntax;
            p.pos += 1;
            return v;
        }
        if (std.ascii.isDigit(c) or c == '.') return p.parseNumber();
        if (std.ascii.isAlphabetic(c)) return p.parseIdent();
        return error.Syntax;
    }

    fn parseNumber(p: *Parser) Error!f64 {
        const start = p.pos;
        if (p.pos + 1 < p.src.len and p.src[p.pos] == '0' and (p.src[p.pos + 1] == 'x' or p.src[p.pos + 1] == 'b')) {
            const radix: u8 = if (p.src[p.pos + 1] == 'x') 16 else 2;
            p.pos += 2;
            const ds = p.pos;
            while (p.pos < p.src.len and std.ascii.isAlphanumeric(p.src[p.pos])) p.pos += 1;
            const n = std.fmt.parseInt(i64, p.src[ds..p.pos], radix) catch return error.Syntax;
            return @floatFromInt(n);
        }
        while (p.pos < p.src.len) : (p.pos += 1) {
            const ch = p.src[p.pos];
            if (std.ascii.isDigit(ch) or ch == '.' or ch == '_') continue;
            // Thousands separator only when followed by exactly three digits.
            if (ch == ',' and p.pos + 3 < p.src.len + 1 and isThreeDigits(p.src[p.pos + 1 ..])) continue;
            if ((ch == 'e' or ch == 'E') and p.pos + 1 < p.src.len and
                (std.ascii.isDigit(p.src[p.pos + 1]) or p.src[p.pos + 1] == '-'))
            {
                p.pos += 1;
                continue;
            }
            break;
        }
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (p.src[start..p.pos]) |ch| {
            if (ch == ',' or ch == '_') continue;
            if (n == buf.len) return error.Syntax;
            buf[n] = ch;
            n += 1;
        }
        return std.fmt.parseFloat(f64, buf[0..n]) catch error.Syntax;
    }

    fn startsFunctionOrConstant(p: *Parser) bool {
        var end = p.pos;
        while (end < p.src.len and std.ascii.isAlphabetic(p.src[end])) end += 1;
        const name = p.src[p.pos..end];
        return constant(name) != null or function(name) != null;
    }

    fn parseIdent(p: *Parser) Error!f64 {
        const start = p.pos;
        while (p.pos < p.src.len and std.ascii.isAlphanumeric(p.src[p.pos])) p.pos += 1;
        const name = p.src[start..p.pos];
        if (constant(name)) |v| return v;
        const f = function(name) orelse return error.Syntax;
        if (p.peek() != '(') return error.Syntax;
        p.pos += 1;
        const arg = try p.parseExpr();
        if (p.peek() != ')') return error.Syntax;
        p.pos += 1;
        p.saw_operator = true;
        return f(arg);
    }
};

fn isThreeDigits(s: []const u8) bool {
    if (s.len < 3) return false;
    for (s[0..3]) |c| if (!std.ascii.isDigit(c)) return false;
    return s.len == 3 or !std.ascii.isDigit(s[3]);
}

fn factorial(v: f64) Error!f64 {
    if (v < 0 or v != @trunc(v) or v > 170) return error.Domain;
    var r: f64 = 1;
    var i: f64 = 2;
    while (i <= v) : (i += 1) r *= i;
    return r;
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
    const r = evaluate(input) orelse {
        std.debug.print("no result for '{s}'\n", .{input});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectApproxEqRel(want, r.value, 1e-9);
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

/// `s` repeated `n` times, at comptime (Zig 0.17 has no `**`).
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const done = comptime blk: {
        @setEvalBranchQuota(n * 10 + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
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
    try std.testing.expectEqualStrings("123,456,789,012.3456", formatDisplay(&buf, 123456789012.3456));
    try std.testing.expectEqualStrings("-999,999,999,999,999.9", formatDisplay(&buf, -999999999999999.9));
    try std.testing.expectEqualStrings("0.00005", formatDisplay(&buf, 0.00005));
    // A buffer too small gets a truncated result, never an overflow.
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("1234", formatDisplay(&tiny, 1234567));
}

fn fuzzEvaluate(_: void, smith: *std.testing.Smith) anyerror!void {
    // Mostly the calculator's own alphabet, so the fuzzer forms expressions.
    const w: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, '0', '9', 8), .value(u8, '+', 4), .value(u8, '-', 4), .value(u8, '*', 4),
        .value(u8, '/', 4),            .value(u8, '^', 4), .value(u8, '(', 4), .value(u8, ')', 4),
        .value(u8, '!', 3),            .value(u8, '%', 3), .value(u8, '.', 3), .value(u8, ',', 3),
        .value(u8, ' ', 4),            .value(u8, 'e', 3), .value(u8, 'x', 2), .rangeAtMost(u8, 'a', 'z', 1),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var in: [200]u8 = undefined;
    const s = in[0..smith.sliceWeightedBytes(&in, w)];
    if (evaluate(s)) |r| {
        try std.testing.expect(std.math.isFinite(r.value));
        var buf: [32]u8 = undefined;
        _ = formatDisplay(&buf, r.value);
        _ = formatPlain(&buf, r.value);
    }
}

test "fuzz: evaluate never crashes and only returns finite values" {
    const P = struct {
        fn lp(comptime s: []const u8) []const u8 {
            const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, s.len));
            return &len ++ s;
        }
    };
    try std.testing.fuzz({}, fuzzEvaluate, .{ .corpus = &.{
        comptime P.lp("2 + 3 * 4"),           comptime P.lp("(1 + 2)^3"),       comptime P.lp("sqrt(16) + 2!"),
        comptime P.lp("20% of 80"),           comptime P.lp("0xff + 0b101"),    comptime P.lp("10 km to mi"),
        comptime P.lp("100 f in c"),          comptime P.lp("1,000.5e3 mod 7"), comptime P.lp("2pi - ln(e)"),
        comptime P.lp("1e308 * 10 kg to lb"),
    } });
}

fn fuzzFormat(_: void, smith: *std.testing.Smith) anyerror!void {
    const v: f64 = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => smith.value(f64), // any bit pattern: nan, inf, subnormals, -0
        1 => @floatFromInt(smith.value(i64)),
        2 => @as(f64, @floatFromInt(smith.value(i32))) / 10000.0,
        else => std.math.pow(f64, 10, @floatFromInt(smith.valueRangeAtMost(i16, -330, 330))) * if (smith.value(bool)) @as(f64, -1) else 1,
    };
    // Every buffer size, down to none: never a write past the end.
    var big: [64]u8 = undefined;
    const n = smith.valueRangeAtMost(u8, 0, 64);
    const d = formatDisplay(big[0..n], v);
    const p = formatPlain(big[0..n], v);
    try std.testing.expect(d.len <= @max(n, 1) and p.len <= @max(n, 1));
    // The buffers the UI uses always hold the whole number.
    var b32: [32]u8 = undefined;
    const full = formatDisplay(&b32, v);
    var raw: [64]u8 = undefined;
    const plain = formatPlain(&raw, v);
    try std.testing.expect(full.len < b32.len and plain.len < raw.len and !std.mem.eql(u8, plain, "?"));
    // What is copied reads back as the value.
    if (std.math.isFinite(v)) {
        const back = try std.fmt.parseFloat(f64, plain);
        try std.testing.expect(@abs(back - v) <= @max(@abs(v) * 1e-6, 1e-10));
    }
}

test "fuzz: formatting any f64 fits its buffer" {
    try std.testing.fuzz({}, fuzzFormat, .{});
}
