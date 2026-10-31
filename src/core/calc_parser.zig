//! The calculator's expression parser: recursive descent over the text,
//! evaluating as it goes (no syntax tree), with the grammar on each parse
//! function. Numbers (with thousands separators, exponents, 0x and 0b),
//! constants and functions are read here too.

const std = @import("std");
const assert = std.debug.assert;

const Error = error{ Syntax, Domain, TooDeep };

/// Nesting allowed (parentheses, signs, exponents): the parser recurses, and
/// pasting 100k "(" must not overflow the stack.
const depth_max = 64;

/// The largest n whose n! fits an f64 (171! is inf).
const factorial_argument_max = 170;

/// Reads `source` from `offset` on; each parse function returns the value
/// of what it read and leaves `offset` after it.
pub const Parser = struct {
    source: []const u8,
    offset: usize = 0,
    /// An operator, a postfix or a function was read: "42" alone and "pi"
    /// alone are not calculations.
    saw_operator: bool = false,
    /// Parse levels entered and not yet left, up to `depth_max`.
    depth: u32 = 0,

    pub fn skipSpaces(parser: *Parser) void {
        while (parser.offset < parser.source.len and parser.source[parser.offset] == ' ') {
            parser.offset += 1;
        }
    }

    fn peek(parser: *Parser) u8 {
        parser.skipSpaces();
        return if (parser.offset < parser.source.len) parser.source[parser.offset] else 0;
    }

    fn eatWord(parser: *Parser, word: []const u8) bool {
        parser.skipSpaces();
        const end = parser.offset + word.len;
        if (end > parser.source.len) return false;
        if (!std.ascii.eqlIgnoreCase(parser.source[parser.offset..end], word)) return false;
        if (end < parser.source.len and std.ascii.isAlphabetic(parser.source[end])) return false;
        parser.offset = end;
        return true;
    }

    /// Parses `expression := term (('+' | '-') term)*`.
    pub fn parseExpression(parser: *Parser) Error!f64 {
        var value = try parser.parseTerm();
        while (true) {
            switch (parser.peek()) {
                '+' => {
                    parser.offset += 1;
                    parser.saw_operator = true;
                    value += try parser.parseTerm();
                },
                '-' => {
                    parser.offset += 1;
                    parser.saw_operator = true;
                    value -= try parser.parseTerm();
                },
                else => return value,
            }
        }
    }

    /// Parses `term := power (('*' | '/' | 'mod' | 'of' | implicit) power)*`.
    fn parseTerm(parser: *Parser) Error!f64 {
        var value = try parser.parseUnary();
        while (true) {
            const next = parser.peek();
            if (next == '*' or next == '/') {
                parser.offset += 1;
                parser.saw_operator = true;
                const operand = try parser.parseUnary();
                if (next == '*') {
                    value *= operand;
                } else {
                    if (operand == 0) return error.Domain;
                    value /= operand;
                }
            } else if (parser.eatWord("mod")) {
                parser.saw_operator = true;
                const operand = try parser.parseUnary();
                if (operand == 0) return error.Domain;
                value = @mod(value, operand);
            } else if (parser.eatWord("of")) {
                parser.saw_operator = true;
                value *= try parser.parseUnary();
            } else if (parser.startsImplicitProduct(next)) {
                // A product with no operator written, as in 2(3+1) or 2pi.
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
            parser.offset += 1;
            return -(try parser.parseUnary());
        }
        if (sign == '+') {
            parser.offset += 1;
            return parser.parseUnary();
        }
        return parser.parsePower();
    }

    /// Parses `power := postfix ('^' unary)?`, which is right associative.
    fn parsePower(parser: *Parser) Error!f64 {
        const base = try parser.parsePostfix();
        const operator_len = parser.powerOperatorLen();
        if (operator_len == 0) return base;
        parser.offset += operator_len;
        parser.saw_operator = true;
        const exponent = try parser.parseUnary();
        return std.math.pow(f64, base, exponent);
    }

    /// 1 for "^", 2 for "**", 0 when the next token is neither.
    fn powerOperatorLen(parser: *Parser) usize {
        const next = parser.peek();
        if (next == '^') return 1;
        if (next != '*') return 0;
        const after = parser.offset + 1;
        if (after < parser.source.len and parser.source[after] == '*') return 2;
        return 0;
    }

    fn parsePostfix(parser: *Parser) Error!f64 {
        var value = try parser.parsePrimary();
        while (true) {
            switch (parser.peek()) {
                '!' => {
                    parser.offset += 1;
                    parser.saw_operator = true;
                    value = try factorial(value);
                },
                '%' => {
                    parser.offset += 1;
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
            parser.offset += 1;
            const value = try parser.parseExpression();
            if (parser.peek() != ')') return error.Syntax;
            parser.offset += 1;
            return value;
        }
        if (std.ascii.isDigit(next) or next == '.') return parser.parseNumber();
        if (std.ascii.isAlphabetic(next)) return parser.parseIdentifier();
        return error.Syntax;
    }

    fn parseNumber(parser: *Parser) Error!f64 {
        const start = parser.offset;
        const rest = parser.source[parser.offset..];
        // The letter of a "0x" or "0b" prefix, or 0 when there is none.
        const radix_letter: u8 = if (rest.len >= 2 and rest[0] == '0') rest[1] else 0;
        if (radix_letter == 'x' or radix_letter == 'b') {
            const radix: u8 = if (radix_letter == 'x') 16 else 2;
            parser.offset += 2;
            const digits_start = parser.offset;
            parser.skipWhile(std.ascii.isAlphanumeric);
            const digits = parser.source[digits_start..parser.offset];
            const integer = std.fmt.parseInt(i64, digits, radix) catch return error.Syntax;
            return @floatFromInt(integer);
        }
        while (parser.offset < parser.source.len) : (parser.offset += 1) {
            const char = parser.source[parser.offset];
            if (std.ascii.isDigit(char) or char == '.' or char == '_') continue;
            // Thousands separator only when followed by exactly three digits.
            if (char == ',' and isThreeDigits(parser.source[parser.offset + 1 ..])) continue;
            if ((char == 'e' or char == 'E') and parser.startsExponent()) {
                parser.offset += 1;
                continue;
            }
            break;
        }
        var digits_buffer: [64]u8 = undefined;
        var digits_len: usize = 0;
        for (parser.source[start..parser.offset]) |char| {
            if (char == ',' or char == '_') continue;
            if (digits_len == digits_buffer.len) return error.Syntax;
            digits_buffer[digits_len] = char;
            digits_len += 1;
        }
        return std.fmt.parseFloat(f64, digits_buffer[0..digits_len]) catch error.Syntax;
    }

    /// After an "e" at `offset`: a digit or a minus sign, as in "1e3" or "1e-3".
    fn startsExponent(parser: *Parser) bool {
        const after = parser.offset + 1;
        if (after == parser.source.len) return false;
        const char = parser.source[after];
        return std.ascii.isDigit(char) or char == '-';
    }

    fn skipWhile(parser: *Parser, comptime accept: fn (u8) bool) void {
        while (parser.offset < parser.source.len and accept(parser.source[parser.offset])) {
            parser.offset += 1;
        }
    }

    fn startsFunctionOrConstant(parser: *Parser) bool {
        var end = parser.offset;
        while (end < parser.source.len and std.ascii.isAlphabetic(parser.source[end])) end += 1;
        const name = parser.source[parser.offset..end];
        return constant(name) != null or function(name) != null;
    }

    fn parseIdentifier(parser: *Parser) Error!f64 {
        const start = parser.offset;
        parser.skipWhile(std.ascii.isAlphanumeric);
        const name = parser.source[start..parser.offset];
        if (constant(name)) |value| return value;
        const apply = function(name) orelse return error.Syntax;
        if (parser.peek() != '(') return error.Syntax;
        parser.offset += 1;
        const argument = try parser.parseExpression();
        if (parser.peek() != ')') return error.Syntax;
        parser.offset += 1;
        parser.saw_operator = true;
        return apply(argument);
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

const Function = *const fn (f64) Error!f64;

fn function(name: []const u8) ?Function {
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
