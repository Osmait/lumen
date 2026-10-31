//! A small Markdown subset to Pango markup, for extension detail panes.
//!
//! Blocks: `#`/`##`/`###` headings, `-`/`*`/`+` and `1.` lists, `>` quotes,
//! fenced code (```), `---` rules, paragraphs. Inline: **bold**, *italic*
//! and _italic_, `code`, [links](url). Everything else is text, escaped:
//! the output is always valid markup, whatever the input (an unclosed
//! marker stays as it was typed).

const std = @import("std");
const assert = std.debug.assert;

pub const Error = std.Io.Writer.Error;

/// Writes `source` as Pango markup.
pub fn toMarkup(writer: *std.Io.Writer, source: []const u8) Error!void {
    var in_code = false;
    var first = true;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code = !in_code;
            continue;
        }
        if (!first) try writer.writeByte('\n');
        first = false;
        if (in_code) {
            try writer.writeAll("<tt>");
            try escape(writer, line);
            try writer.writeAll("</tt>");
        } else {
            try writeBlock(writer, line, trimmed);
        }
    }
}

/// One line outside a code block: a heading, a rule, a list item, a quote
/// or a paragraph line.
fn writeBlock(writer: *std.Io.Writer, line: []const u8, trimmed: []const u8) Error!void {
    if (heading(trimmed)) |title| {
        try writer.writeAll(switch (title.level) {
            1 => "<span size=\"x-large\" weight=\"bold\">",
            2 => "<span size=\"large\" weight=\"bold\">",
            else => "<span weight=\"bold\">",
        });
        try writeSpans(writer, title.text, 0);
        try writer.writeAll("</span>");
    } else if (isRule(trimmed)) {
        try writer.writeAll("<span fgalpha=\"40%\">────────────────</span>");
    } else if (bullet(trimmed)) |rest| {
        try writer.writeAll("  •  ");
        try writeSpans(writer, rest, 0);
    } else if (numbered(trimmed)) |item| {
        try writer.writeAll("  ");
        try escape(writer, item.number);
        try writer.writeAll("  ");
        try writeSpans(writer, item.text, 0);
    } else if (std.mem.startsWith(u8, trimmed, ">")) {
        try writer.writeAll("<span fgalpha=\"70%\"><i>");
        try writeSpans(writer, std.mem.trimStart(u8, trimmed[1..], " "), 0);
        try writer.writeAll("</i></span>");
    } else {
        try writeSpans(writer, line, 0);
    }
}

const Heading = struct { level: u8, text: []const u8 };

/// Markdown has six levels of heading; past the third they all look alike.
const heading_level_max = 6;

fn heading(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0) return null;
    if (level > heading_level_max) return null;
    // "#" alone, or "#title" with no space, is text.
    if (level == line.len) return null;
    if (line[level] != ' ') return null;
    return .{ .level = @min(level, 3), .text = std.mem.trim(u8, line[level..], " #") };
}

fn isRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const marker = line[0];
    if (std.mem.findScalar(u8, "-*_", marker) == null) return false;
    for (line) |char| {
        if (char != marker and char != ' ') return false;
    }
    return true;
}

fn bullet(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    if (std.mem.findScalar(u8, "-*+", line[0]) == null) return null;
    if (line[1] != ' ') return null;
    return line[2..];
}

/// A list item's number has at most this many digits: "123456789." is one,
/// a longer run of digits is a paragraph that starts with a number.
const item_number_digits_max = 9;

fn numbered(line: []const u8) ?struct { number: []const u8, text: []const u8 } {
    var digits_len: usize = 0;
    while (digits_len < line.len and std.ascii.isDigit(line[digits_len])) digits_len += 1;
    if (digits_len == 0) return null;
    if (digits_len > item_number_digits_max) return null;
    // A "." and a space after the digits, with room for both.
    if (digits_len + 1 >= line.len) return null;
    if (line[digits_len] != '.') return null;
    if (line[digits_len + 1] != ' ') return null;
    return .{ .number = line[0 .. digits_len + 1], .text = line[digits_len + 2 ..] };
}

/// Spans nest at most this deep: one ends at the next occurrence of its own
/// marker, so "**" holds no "**", "*" no "*" and "_" no "_".
const span_depth_max = 3;

/// Inline spans of one line; `depth` spans around it.
fn writeSpans(writer: *std.Io.Writer, line: []const u8, depth: u8) Error!void {
    assert(depth <= span_depth_max);
    // Searches for closing markers, each picking up where the last ended.
    var bold: Finder = .{ .marker = "**", .after_text = true };
    var star: Finder = .{ .marker = "*", .after_text = true };
    var underscore: Finder = .{ .marker = "_", .after_text = true };
    var links: Link = .{};
    var pos: usize = 0;
    while (pos < line.len) {
        const char = line[pos];
        if (char == '`') {
            // Unclosed, it has no "`" after it: no later one searches again.
            if (std.mem.findScalarPos(u8, line, pos + 1, '`')) |end| {
                try writer.writeAll("<tt>");
                try escape(writer, line[pos + 1 .. end]);
                try writer.writeAll("</tt>");
                pos = end + 1;
                continue;
            }
        } else if (char == '*' and pos + 1 < line.len and line[pos + 1] == '*') {
            if (closing(line, pos + 2, &bold)) |end| {
                try writer.writeAll("<b>");
                try writeSpans(writer, line[pos + 2 .. end], depth + 1);
                try writer.writeAll("</b>");
                pos = end + 2;
                continue;
            }
        } else if (char == '*' or char == '_') {
            // Not inside a word for "_" (snake_case stays as it is).
            const word_inside = char == '_' and pos > 0 and std.ascii.isAlphanumeric(line[pos - 1]);
            const finder = if (char == '*') &star else &underscore;
            const end_maybe = if (word_inside) null else closing(line, pos + 1, finder);
            if (end_maybe) |end| {
                try writer.writeAll("<i>");
                try writeSpans(writer, line[pos + 1 .. end], depth + 1);
                try writer.writeAll("</i>");
                pos = end + 1;
                continue;
            }
        } else if (char == '[') {
            if (links.at(line, pos)) |link| {
                try writer.writeAll("<a href=\"");
                try escape(writer, link.url);
                try writer.writeAll("\">");
                try escape(writer, link.text);
                try writer.writeAll("</a>");
                pos = link.end;
                continue;
            }
        }
        // Text up to the next character that may open a span, whole: a
        // character of several bytes is escaped in one piece.
        const next = std.mem.findAnyPos(u8, line, pos + 1, "`*_[") orelse line.len;
        try escape(writer, line[pos..next]);
        pos = next;
    }
}

/// Where a span opened just before `from` closes: not right after the
/// opening, not after a space (so "a * b * c" stays text).
fn closing(line: []const u8, from: usize, marker: *Finder) ?usize {
    if (from >= line.len) return null;
    if (line[from] == ' ') return null;
    return marker.next(line, from + 1);
}

/// Searches one line for `marker` from positions that only grow (the line
/// is read left to right), each starting where the last one stopped. Every
/// unclosed marker searched the rest of the line again: quadratic, 6 s for
/// a 400 KB line, in a Lua call the time limit cannot stop.
const Finder = struct {
    marker: []const u8,
    /// Only matches right after something other than a space.
    after_text: bool = false,
    /// The first match at or after `from` (null: none), once searched.
    from: usize = 0,
    found: ?usize = null,
    searched: bool = false,

    fn next(finder: *Finder, line: []const u8, from: usize) ?usize {
        if (finder.searched) {
            assert(from >= finder.from);
            const at = finder.found orelse return null;
            if (from <= at) return at;
        }
        var pos = from;
        finder.found = while (std.mem.findPos(u8, line, pos, finder.marker)) |at| {
            if (!finder.after_text) break at;
            if (at > 0 and line[at - 1] != ' ') break at;
            pos = at + 1;
        } else null;
        finder.from = from;
        finder.searched = true;
        return finder.found;
    }
};

/// `[text](url)` links of one line, searched like `Finder`'s markers.
const Link = struct {
    close: Finder = .{ .marker = "]" },
    paren: Finder = .{ .marker = ")" },

    fn at(link: *Link, line: []const u8, start: usize) ?struct {
        text: []const u8,
        url: []const u8,
        end: usize,
    } {
        const close = link.close.next(line, start + 1) orelse return null;
        if (close + 1 >= line.len) return null;
        if (line[close + 1] != '(') return null;
        const paren = link.paren.next(line, close + 2) orelse return null;
        const url = line[close + 2 .. paren];
        if (url.len == 0) return null;
        if (std.mem.findScalar(u8, url, ' ') != null) return null;
        return .{ .text = line[start + 1 .. close], .url = url, .end = paren + 1 };
    }
};

/// Text as markup: valid UTF-8 whatever the input (U+FFFD for each byte
/// that does not start a character), without NUL. GTK refuses markup that
/// is not, and the label then keeps the text it had: the last row's.
fn escape(writer: *std.Io.Writer, text: []const u8) Error!void {
    var pos: usize = 0;
    while (pos < text.len) {
        const char = text[pos];
        if (char >= 0x80) {
            const sequence_len = validSequenceLen(text[pos..]);
            if (sequence_len > 0) {
                try writer.writeAll(text[pos..][0..sequence_len]);
                pos += sequence_len;
            } else {
                try writer.writeAll(replacement);
                pos += 1;
            }
            continue;
        }
        switch (char) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            0 => try writer.writeAll(replacement),
            else => try writer.writeByte(char),
        }
        pos += 1;
    }
}

/// The length of the UTF-8 character `text` starts with, or 0 when it does
/// not start with a whole, valid one.
fn validSequenceLen(text: []const u8) usize {
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[0]) catch return 0;
    if (sequence_len > text.len) return 0;
    if (!std.unicode.utf8ValidateSlice(text[0..sequence_len])) return 0;
    return sequence_len;
}

const replacement = "\u{FFFD}";

const testing = std.testing;

fn expectMarkup(md: []const u8, want: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try toMarkup(&out.writer, md);
    try testing.expectEqualStrings(want, out.written());
}

test "inline spans" {
    try expectMarkup("**bold** and *it* and _it_", "<b>bold</b> and <i>it</i> and <i>it</i>");
    try expectMarkup("run `zig build` now", "run <tt>zig build</tt> now");
    try expectMarkup(
        "see [docs](https://ziglang.org)",
        "see <a href=\"https://ziglang.org\">docs</a>",
    );
    try expectMarkup("**bold _and it_**", "<b>bold <i>and it</i></b>");
    try expectMarkup("`<b>` is & stays", "<tt>&lt;b&gt;</tt> is &amp; stays");
}

test "blocks" {
    try expectMarkup(
        "# Title\n## Sub\ntext",
        "<span size=\"x-large\" weight=\"bold\">Title</span>\n<span size=\"large\" weight=\"bold\">Sub</span>\ntext",
    );
    try expectMarkup("- one\n2. two", "  •  one\n  2.  two");
    try expectMarkup("> quoted", "<span fgalpha=\"70%\"><i>quoted</i></span>");
    try expectMarkup("```\nlet x = <1>;\n```\nafter", "<tt>let x = &lt;1&gt;;</tt>\nafter");
    try expectMarkup("---", "<span fgalpha=\"40%\">────────────────</span>");
}

test "unclosed or stray markers stay as text" {
    try expectMarkup("2 * 3 * 4", "2 * 3 * 4");
    try expectMarkup("**open", "**open");
    try expectMarkup("snake_case_name", "snake_case_name");
    try expectMarkup("[not a link] (x)", "[not a link] (x)");
    try expectMarkup("`open", "`open");
    try expectMarkup("#nohash", "#nohash");
    try expectMarkup("a < b > c \"q\"", "a &lt; b &gt; c &quot;q&quot;");
}

test "the markup is valid UTF-8 without NUL, whatever the bytes" {
    try expectMarkup("caf\xc3 \xff**b\x00**", "caf\u{FFFD} \u{FFFD}<b>b\u{FFFD}</b>");
    try expectMarkup(
        "ok é `\xe2\x82` [x\xff](u)",
        "ok é <tt>\u{FFFD}\u{FFFD}</tt> <a href=\"u\">x\u{FFFD}</a>",
    );
    // Characters of several bytes around markers stay whole.
    try expectMarkup("*ñ*_ü_", "<i>ñ</i><i>ü</i>");
}

/// What closing searched before Finder: every search from scratch.
fn closingNaive(line: []const u8, from: usize, marker: []const u8) ?usize {
    if (from >= line.len or line[from] == ' ') return null;
    var pos = from + 1;
    while (std.mem.findPos(u8, line, pos, marker)) |at| {
        if (line[at - 1] != ' ') return at;
        pos = at + 1;
    }
    return null;
}

test "searches that pick up where the last ended find what a fresh one does" {
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    const alphabet = "**_ a";
    var line: [64]u8 = undefined;
    for (0..2000) |_| {
        for (&line) |*char| char.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        inline for (.{ "**", "*", "_" }) |marker| {
            var finder: Finder = .{ .marker = marker, .after_text = true };
            var from: usize = 0;
            while (from < line.len) : (from += 1 + random.uintLessThan(usize, 4)) {
                const want = closingNaive(&line, from, marker);
                try testing.expectEqual(want, closing(&line, from, &finder));
            }
        }
    }
}

test "a long line of unclosed markers takes linear time" {
    // Each pattern opened a span the rest of the line could not close: a
    // search to the end of the line for every marker (minutes, not ms, at
    // this size).
    const patterns = [_][]const u8{ "*a ", "**a ", "_a ", "[", "[a](", "x`" };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (patterns) |pattern| {
        const repeats = 200_000 / pattern.len;
        const source = try testing.allocator.alloc(u8, repeats * pattern.len);
        defer testing.allocator.free(source);
        for (0..repeats) |k| @memcpy(source[k * pattern.len ..][0..pattern.len], pattern);
        out.clearRetainingCapacity();
        try toMarkup(&out.writer, source);
        try testing.expect(out.written().len >= source.len);
    }
}

test "spans nest no deeper than span_depth_max, whatever the input" {
    // Every way to open spans inside spans, many times over: the depth
    // assertion in writeSpans holds (a deeper recursion would trip it).
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    const pieces = [_][]const u8{ "**", "*", "_", "x", " ", "`", "[a](b)" };
    var source: [256]u8 = undefined;
    var out: [8192]u8 = undefined;
    for (0..3000) |_| {
        var len: usize = 0;
        while (len < 240) {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            @memcpy(source[len..][0..piece.len], piece);
            len += piece.len;
        }
        var writer: std.Io.Writer = .fixed(&out);
        // The output buffer may fill: what matters is that nothing crashes.
        toMarkup(&writer, source[0..len]) catch |err| switch (err) {
            error.WriteFailed => {},
        };
    }
}
