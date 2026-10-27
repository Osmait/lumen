//! A small Markdown subset to Pango markup, for extension detail panes.
//!
//! Blocks: `#`/`##`/`###` headings, `-`/`*`/`+` and `1.` lists, `>` quotes,
//! fenced code (```), `---` rules, paragraphs. Inline: **bold**, *italic*
//! and _italic_, `code`, [links](url). Everything else is text, escaped:
//! the output is always valid markup, whatever the input (an unclosed
//! marker stays as it was typed).

const std = @import("std");

pub const Error = std.Io.Writer.Error;

/// Writes `md` as Pango markup.
pub fn toMarkup(w: *std.Io.Writer, md: []const u8) Error!void {
    var in_code = false;
    var first = true;
    var lines = std.mem.splitScalar(u8, md, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_code = !in_code;
            continue;
        }
        if (!first) try w.writeByte('\n');
        first = false;
        if (in_code) {
            try w.writeAll("<tt>");
            try escape(w, line);
            try w.writeAll("</tt>");
            continue;
        }
        if (heading(trimmed)) |h| {
            try w.writeAll(switch (h.level) {
                1 => "<span size=\"x-large\" weight=\"bold\">",
                2 => "<span size=\"large\" weight=\"bold\">",
                else => "<span weight=\"bold\">",
            });
            try inline_(w, h.text);
            try w.writeAll("</span>");
        } else if (isRule(trimmed)) {
            try w.writeAll("<span fgalpha=\"40%\">────────────────</span>");
        } else if (bullet(trimmed)) |rest| {
            try w.writeAll("  •  ");
            try inline_(w, rest);
        } else if (numbered(trimmed)) |n| {
            try w.writeAll("  ");
            try escape(w, n.number);
            try w.writeAll("  ");
            try inline_(w, n.text);
        } else if (std.mem.startsWith(u8, trimmed, ">")) {
            try w.writeAll("<span fgalpha=\"70%\"><i>");
            try inline_(w, std.mem.trimStart(u8, trimmed[1..], " "));
            try w.writeAll("</i></span>");
        } else {
            try inline_(w, line);
        }
    }
}

const Heading = struct { level: u8, text: []const u8 };

fn heading(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = @min(level, 3), .text = std.mem.trim(u8, line[level..], " #") };
}

fn isRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (line) |x| if (x != ch and x != ' ') return false;
    return true;
}

fn bullet(line: []const u8) ?[]const u8 {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') return line[2..];
    return null;
}

fn numbered(line: []const u8) ?struct { number: []const u8, text: []const u8 } {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i == 0 or i > 9 or i + 1 >= line.len or line[i] != '.' or line[i + 1] != ' ') return null;
    return .{ .number = line[0 .. i + 1], .text = line[i + 2 ..] };
}

/// Inline spans of one line.
fn inline_(w: *std.Io.Writer, s: []const u8) Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == '`') {
            if (std.mem.findScalarPos(u8, s, i + 1, '`')) |end| {
                try w.writeAll("<tt>");
                try escape(w, s[i + 1 .. end]);
                try w.writeAll("</tt>");
                i = end + 1;
                continue;
            }
        } else if (ch == '*' and i + 1 < s.len and s[i + 1] == '*') {
            if (closing(s, i + 2, "**")) |end| {
                try w.writeAll("<b>");
                try inline_(w, s[i + 2 .. end]);
                try w.writeAll("</b>");
                i = end + 2;
                continue;
            }
        } else if (ch == '*' or ch == '_') {
            // Not inside a word for "_" (snake_case stays as it is).
            const word_inside = ch == '_' and i > 0 and std.ascii.isAlphanumeric(s[i - 1]);
            if (!word_inside) if (closing(s, i + 1, s[i .. i + 1])) |end| {
                try w.writeAll("<i>");
                try inline_(w, s[i + 1 .. end]);
                try w.writeAll("</i>");
                i = end + 1;
                continue;
            };
        } else if (ch == '[') {
            if (link(s, i)) |l| {
                try w.writeAll("<a href=\"");
                try escape(w, l.url);
                try w.writeAll("\">");
                try escape(w, l.text);
                try w.writeAll("</a>");
                i = l.end;
                continue;
            }
        }
        try escape(w, s[i .. i + 1]);
        i += 1;
    }
}

/// Where `marker` closes a span opened just before `from`: not right after
/// the opening, not after a space (so "a * b * c" stays text).
fn closing(s: []const u8, from: usize, marker: []const u8) ?usize {
    if (from >= s.len or s[from] == ' ') return null;
    var pos = from + 1;
    while (std.mem.findPos(u8, s, pos, marker)) |at| {
        if (s[at - 1] != ' ') return at;
        pos = at + 1;
    }
    return null;
}

fn link(s: []const u8, start: usize) ?struct { text: []const u8, url: []const u8, end: usize } {
    const close = std.mem.findScalarPos(u8, s, start + 1, ']') orelse return null;
    if (close + 1 >= s.len or s[close + 1] != '(') return null;
    const paren = std.mem.findScalarPos(u8, s, close + 2, ')') orelse return null;
    const url = s[close + 2 .. paren];
    if (url.len == 0 or std.mem.findScalar(u8, url, ' ') != null) return null;
    return .{ .text = s[start + 1 .. close], .url = url, .end = paren + 1 };
}

fn escape(w: *std.Io.Writer, s: []const u8) Error!void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(ch),
    };
}

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
    try expectMarkup("see [docs](https://ziglang.org)", "see <a href=\"https://ziglang.org\">docs</a>");
    try expectMarkup("**bold _and it_**", "<b>bold <i>and it</i></b>");
    try expectMarkup("`<b>` is & stays", "<tt>&lt;b&gt;</tt> is &amp; stays");
}

test "blocks" {
    try expectMarkup("# Title\n## Sub\ntext", "<span size=\"x-large\" weight=\"bold\">Title</span>\n<span size=\"large\" weight=\"bold\">Sub</span>\ntext");
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
