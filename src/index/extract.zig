//! Plain text out of PDFs and Office documents, for the content index.
//!
//!   - PDF goes through poppler's `pdftotext`; writing a PDF parser (fonts,
//!     CMaps, compressed object streams) is not worth it for search.
//!   - OOXML (docx/xlsx/pptx) and ODF (odt/ods/odp) are zips of XML: `unzip -p`
//!     streams the members that hold the text, `xmlToText` strips the markup.
//!   - The document goes to the tool as its stdin, named `/dev/stdin`: unzip
//!     treats `*?[` in an archive name as a wildcard (`a*.docx` would also read
//!     `ab.docx`), and no file name can be mistaken for an option.
//!   - A pathological file must not stall the indexer: output is read up to a
//!     cap, then the tool is SIGKILLed, and what was read is kept (truncated
//!     text still indexes). Past `timeout_ms` likewise, but that is an error
//!     (`Timeout`): text cut short by a busy machine would be cached as the
//!     document's whole text for good.
//!   - The tools get an empty environment (`UNZIP=-a` and friends stay out),
//!     and unzip an empty password: an encrypted document made it ask for
//!     one on the terminal the daemon was started from, and wait for it.

const std = @import("std");
const paths = @import("paths.zig");
const linux = std.os.linux;
const sys = @import("os");

pub const Kind = enum { pdf, docx, xlsx, pptx, odt, ods, odp };

/// Wall-clock budget for one tool run.
pub const timeout_ms = 15_000;

/// Kind from the file name's extension (case-insensitive), or null if not supported.
/// Office's `~$name.docx` owner files (not zips) are not documents.
/// Office writes `~$name.docx` next to an open document: who has it open,
/// not a zip.
const office_owner_prefix = "~$";

pub fn kindOf(path: []const u8) ?Kind {
    const base = std.Io.Dir.path.basename(path);
    if (std.mem.startsWith(u8, base, office_owner_prefix)) return null;
    var buf: [4]u8 = undefined;
    const ext = @import("core").file_kind.lowerExt(&buf, base) orelse return null;
    return std.meta.stringToEnum(Kind, ext);
}

pub const ExtractError = Error || std.mem.Allocator.Error || sys.child.Error;

/// Extracted UTF-8 text of the document at `path` (absolute), owned by
/// `gpa`, at most `bytes_max` long (truncated, never failing for size).
/// An error for unreadable or corrupt files, which callers skip;
/// error.ToolMissing when pdftotext or unzip is not installed. Setting
/// `cancel` kills the tool: error.Timeout.
pub fn extractText(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: [:0]const u8,
    kind: Kind,
    bytes_max: usize,
    cancel: ?*const std.atomic.Value(bool),
) ExtractError![]u8 {
    const fd = try sys.openRegular(path);
    defer sys.close(fd);

    if (kind == .pdf) {
        const raw = try runTool(
            gpa,
            io,
            &.{ "pdftotext", "-q", "-enc", "UTF-8", "/dev/stdin", "-" },
            fd,
            bytes_max,
            &.{0},
            timeout_ms,
            cancel,
        );
        // Pages are separated by form feeds.
        std.mem.replaceScalar(u8, raw, '\x0c', '\n');
        return shrink(gpa, raw, bytes_max);
    }

    const members: []const []const u8 = switch (kind) {
        .pdf => unreachable, // handled above
        .docx => &.{ "word/document.xml", "word/footnotes.xml", "word/endnotes.xml" },
        .xlsx => &.{"xl/sharedStrings.xml"},
        .pptx => &.{"ppt/slides/slide*.xml"},
        .odt, .ods, .odp => &.{"content.xml"},
    };
    var argv: [8][]const u8 = undefined;
    // An encrypted member fails (exit 82) instead of prompting.
    const head = [_][]const u8{ "unzip", "-P", "", "-p", "/dev/stdin" };
    @memcpy(argv[0..head.len], &head);
    @memcpy(argv[head.len..][0..members.len], members);

    // Markup outweighs text several times over; the cap only guards memory.
    const xml_cap = @max(bytes_max, @min(bytes_max *| xml_per_text_max, xml_bytes_max));
    const xml = try runTool(
        gpa,
        io,
        argv[0 .. head.len + members.len],
        fd,
        xml_cap,
        &.{ unzip_exit.ok, unzip_exit.member_missing },
        timeout_ms,
        cancel,
    );
    defer gpa.free(xml);
    return shrink(gpa, try xmlToText(gpa, xml), bytes_max);
}

pub const Error = sys.Error || error{ ToolMissing, ToolFailed, Timeout };

/// Runs `argv` with `input` as stdin and returns at most `cap` bytes of its
/// stdout. Reaching the cap kills the tool and keeps what was read; the
/// timeout kills it and fails (what it printed may be any part of the
/// text); otherwise its exit code must be in `ok_codes`.
/// How many bytes of markup an Office document may have per byte of text
/// wanted, and the most markup read whatever the text: markup outweighs
/// text several times over, and these caps only guard memory.
const xml_per_text_max = 8;
/// The usual markup bytes per text byte, for the first allocation.
const xml_per_text_guess = 4;
const xml_bytes_max = 256 << 20;

/// unzip's exit codes that still give text. A corrupt archive is 9 and a
/// password-protected one 82: those fail.
const unzip_exit = struct {
    const ok = 0;
    /// Some member was not found: an optional one, or an xlsx without
    /// shared strings.
    const member_missing = 11;
};

fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    input: i32,
    cap: usize,
    ok_codes: []const u8,
    limit_ms: u64,
    cancel: ?*const std.atomic.Value(bool),
) ExtractError![]u8 {
    const result = sys.child.run(gpa, io, argv, .{
        .stdin = .{ .fd = input },
        .stderr = .ignore,
        .environ = .empty,
        .output_bytes_max = cap,
        .at_cap = .kill,
        .deadline_ns = sys.monotonicNs() + limit_ms * std.time.ns_per_ms,
        .cancel = cancel,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.ToolMissing,
        else => |e| e,
    };
    gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    if (result.timed_out) return error.Timeout;
    if (result.capped) return result.stdout;
    const code = result.code orelse return error.ToolFailed;
    if (std.mem.findScalar(u8, ok_codes, code) == null) return error.ToolFailed;
    return result.stdout;
}

/// `text` cut to at most `bytes_max` bytes at a UTF-8 boundary, reallocated
/// to fit.
fn shrink(gpa: std.mem.Allocator, text: []u8, bytes_max: usize) ![]u8 {
    const length = @import("core").utf8.floorBoundary(text, bytes_max);
    if (length == text.len) return text;
    if (gpa.resize(text, length)) return text[0..length];
    defer gpa.free(text);
    return gpa.dupe(u8, text[0..length]);
}

/// What a tag does to the surrounding text.
const Gap = enum(u2) { none, space, newline };

fn gapOf(local: []const u8) Gap {
    const newline = [_][]const u8{
        // w:/a:/text: paragraphs, rows, xlsx strings
        "p",         "h",          "br",   "cr",        "tr", "si",
        "table-row", "line-break", "page", "list-item",
    };
    const space = [_][]const u8{ "tab", "tc", "table-cell", "s", "c" };
    for (newline) |n| if (std.mem.eql(u8, local, n)) return .newline;
    for (space) |n| if (std.mem.eql(u8, local, n)) return .space;
    return .none;
}

/// Elements whose text is not document text: field codes, deleted text,
/// the VML copy of a text box (`mc:Fallback`), xlsx phonetic readings, ODF
/// change tracking.
fn skipped(local: []const u8) bool {
    const names = [_][]const u8{ "instrText", "delText", "Fallback", "rPh", "tracked-changes" };
    for (names) |n| if (std.mem.eql(u8, local, n)) return true;
    return false;
}

/// Text of an XML document: tags dropped, entities decoded, paragraph/row
/// boundaries as newlines and cell/tab boundaries as spaces, whitespace runs
/// collapsed, trimmed. Runs (`w:r`, `text:span`) are not boundaries: Word
/// splits words across them. Tolerates truncated input.
fn xmlToText(gpa: std.mem.Allocator, xml: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // A guess that saves most regrowth: text is a fraction of its markup.
    try out.ensureTotalCapacity(gpa, xml.len / xml_per_text_guess + 16);
    var w: TextOut = .{ .out = &out, .gpa = gpa };
    var skip: Skip = .{};
    var i: usize = 0;
    while (i < xml.len) {
        if (xml[i] != '<') {
            i = try w.charData(xml, i, skip.name != null);
            continue;
        }
        if (try w.markup(xml, i, skip.name != null)) |next| {
            i = next;
            continue;
        }
        const tag = Tag.parse(xml, i) orelse break; // truncated
        i = tag.end + 1;
        if (skip.swallow(tag)) continue;
        if (!tag.closing and !tag.self_closing and skipped(tag.local)) {
            skip = .{ .name = tag.name, .depth = 1 };
            continue;
        }
        w.sep(gapOf(tag.local));
    }
    return out.toOwnedSlice(gpa);
}

/// Text as it comes out: whitespace runs collapsed into the strongest gap
/// (a newline beats a space) between words.
const TextOut = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    gap: Gap = .none,

    /// A gap at least as wide as `gap` before the next text.
    fn sep(text_out: *TextOut, gap: Gap) void {
        if (@backingInt(gap) > @backingInt(text_out.gap)) text_out.gap = gap;
    }

    fn text(text_out: *TextOut, bytes: []const u8) !void {
        if (text_out.gap != .none and text_out.out.items.len > 0) {
            const separator: u8 = if (text_out.gap == .newline) '\n' else ' ';
            try text_out.out.append(text_out.gpa, separator);
        }
        text_out.gap = .none;
        try text_out.out.appendSlice(text_out.gpa, bytes);
    }

    /// Character data, entities not decoded (CDATA) or already decoded.
    fn raw(text_out: *TextOut, s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) {
            if (isSpace(s[i])) {
                text_out.sep(.space);
                i += 1;
                continue;
            }
            const start = i;
            while (i < s.len and !isSpace(s[i])) i += 1;
            try text_out.text(s[start..i]);
        }
    }

    /// Text from `i` up to the next tag, its entities decoded; where it
    /// ends. Dropped inside a skipped element.
    fn charData(text_out: *TextOut, xml: []const u8, i: usize, skipping: bool) !usize {
        const rest = xml[i..];
        const end = i + (std.mem.findAny(u8, rest, "<&") orelse rest.len);
        if (!skipping) try text_out.raw(xml[i..end]);
        if (end == xml.len or xml[end] != '&') return end;
        const entity = decodeEntity(xml[end..]);
        if (!skipping) {
            if (entity.len == 0) {
                try text_out.text("&");
            } else if (entity.cp) |cp| switch (cp) {
                '\n' => text_out.sep(.newline),
                ' ', '\t', '\r' => text_out.sep(.space),
                else => {
                    var buf: [4]u8 = undefined;
                    // decodeEntity returns only encodable code points.
                    try text_out.text(buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable]);
                },
            };
        }
        return end + @max(entity.len, 1);
    }

    /// A comment, CDATA section, declaration or doctype at `i`: where it
    /// ends. Null for a tag.
    fn markup(text_out: *TextOut, xml: []const u8, i: usize, skipping: bool) !?usize {
        const rest = xml[i..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const end = std.mem.findPos(u8, xml, i + "<!--".len, "-->") orelse return xml.len;
            return end + "-->".len;
        }
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const start = i + "<![CDATA[".len;
            const end = std.mem.findPos(u8, xml, start, "]]>") orelse xml.len;
            if (!skipping) try text_out.raw(xml[start..end]);
            return @min(end + "]]>".len, xml.len);
        }
        if (std.mem.startsWith(u8, rest, "<?")) {
            // A declaration starts each concatenated member (pptx slides).
            text_out.sep(.newline);
            const end = std.mem.findPos(u8, xml, i + "<?".len, "?>") orelse return xml.len;
            return end + "?>".len;
        }
        if (std.mem.startsWith(u8, rest, "<!")) {
            const end = std.mem.findScalarPos(u8, xml, i + "<!".len, '>') orelse return xml.len;
            return end + ">".len;
        }
        return null;
    }
};

const Tag = struct {
    name: []const u8,
    /// Without its namespace prefix.
    local: []const u8,
    closing: bool,
    self_closing: bool,
    /// Index of its `>`.
    end: usize,

    /// The tag starting at `xml[i]` ('<'); null when the input ends inside
    /// it. `>` may appear inside quoted attribute values.
    fn parse(xml: []const u8, i: usize) ?Tag {
        var tag_end = i + 1;
        var quote: u8 = 0;
        while (tag_end < xml.len) : (tag_end += 1) {
            const byte = xml[tag_end];
            if (quote != 0) {
                if (byte == quote) quote = 0;
            } else if (byte == '"' or byte == '\'') {
                quote = byte;
            } else if (byte == '>') break;
        }
        if (tag_end >= xml.len) return null;
        const closing = xml[i + 1] == '/';
        const name_start = i + 1 + @intFromBool(closing);
        var name_end = name_start;
        while (name_end < tag_end) : (name_end += 1) {
            if (isSpace(xml[name_end]) or xml[name_end] == '/') break;
        }
        const name = xml[name_start..name_end];
        return .{
            .name = name,
            .local = name[if (std.mem.findScalarLast(u8, name, ':')) |c| c + 1 else 0..],
            .closing = closing,
            .self_closing = xml[tag_end - 1] == '/',
            .end = tag_end,
        };
    }
};

/// The element whose content is being dropped (`skipped`), and how deep
/// same-named elements nest inside it.
const Skip = struct {
    name: ?[]const u8 = null,
    depth: usize = 0,

    /// True while inside it (this tag included), counting nesting.
    fn swallow(skip: *Skip, tag: Tag) bool {
        const name = skip.name orelse return false;
        if (std.mem.eql(u8, tag.name, name)) {
            if (tag.closing) {
                skip.depth -= 1;
                if (skip.depth == 0) skip.* = .{};
            } else if (!tag.self_closing) skip.depth += 1;
        }
        return true;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `&...;` at the start of `s`: bytes consumed (0 if not an entity) and the
/// code point (null for an invalid numeric reference, which is dropped).
fn decodeEntity(text: []const u8) struct { len: usize, cp: ?u21 } {
    const semi = std.mem.findScalar(
        u8,
        text[0..@min(text.len, 12)],
        ';',
    ) orelse return .{ .len = 0, .cp = null };
    const body = text[1..semi];
    const named = [_]struct { []const u8, u21 }{
        .{ "amp", '&' },
        .{ "lt", '<' },
        .{ "gt", '>' },
        .{ "quot", '"' },
        .{ "apos", '\'' },
    };
    for (named) |entity| {
        if (std.mem.eql(u8, body, entity[0])) return .{ .len = semi + 1, .cp = entity[1] };
    }
    if (body.len < 2 or body[0] != '#') return .{ .len = 0, .cp = null };
    const parsed = if (body[1] == 'x' or body[1] == 'X')
        std.fmt.parseInt(u32, body[2..], 16)
    else
        std.fmt.parseInt(u32, body[1..], 10);
    const code_point = parsed catch return .{ .len = 0, .cp = null };
    const surrogate = code_point >= 0xD800 and code_point <= 0xDFFF;
    const valid = code_point != 0 and code_point <= 0x10FFFF and !surrogate;
    return .{ .len = semi + 1, .cp = if (valid) @intCast(code_point) else null };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectText(xml: []const u8, want: []const u8) !void {
    const got = try xmlToText(testing.allocator, xml);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "kindOf" {
    try testing.expectEqual(Kind.pdf, kindOf("/home/u/a.pdf").?);
    try testing.expectEqual(Kind.pdf, kindOf("/home/u/A.PDF").?);
    try testing.expectEqual(Kind.docx, kindOf("/x/Report.final.DocX").?);
    try testing.expectEqual(Kind.xlsx, kindOf("b.xlsx").?);
    try testing.expectEqual(Kind.pptx, kindOf("/s/talk.pptx").?);
    try testing.expectEqual(Kind.odt, kindOf("/s/n.odt").?);
    try testing.expectEqual(Kind.ods, kindOf("/s/n.ODS").?);
    try testing.expectEqual(Kind.odp, kindOf("/s/n.odp").?);
    try testing.expect(kindOf("/s/n.doc") == null);
    try testing.expect(kindOf("/s/n.txt") == null);
    try testing.expect(kindOf("/s/pdf") == null);
    try testing.expect(kindOf("/s/.pdf") == null);
    try testing.expect(kindOf("/s/n.") == null);
    try testing.expect(kindOf("/a.pdf/notes") == null);
    try testing.expect(kindOf("/s/n.pdfx") == null);
    try testing.expect(kindOf("/s/~$report.docx") == null);
    try testing.expect(kindOf("") == null);
}

test "xmlToText: Word paragraphs, runs split mid-word, tabs, breaks" {
    try expectText(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
    ++ "<w:p><w:pPr><w:pStyle w:val=\"Title\"/></w:pPr><w:r><w:t>Hel</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>lo</w:t></w:r>" ++
        "<w:r><w:t xml:space=\"preserve\"> big </w:t></w:r><w:r><w:t>world</w:t></w:r></w:p>" ++
        "<w:p><w:r><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t></w:r></w:p>" ++
        "<w:p/><w:p><w:r><w:t>end</w:t></w:r></w:p></w:body></w:document>",
        "Hello big world\na b\nc\nend",
    );
}

test "xmlToText: entities and numeric references" {
    try expectText("<t>a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;</t>", "a & b <c> \"d\" 'e'");
    try expectText("<t>&#65;&#x42;&#X43; &#233;t&#xE9; &#x1F600;</t>", "ABC été \u{1F600}");
    // Invalid references vanish; unknown or malformed ones stay literal.
    try expectText("<t>x&#0;y&#xD800;z&#x110000;w</t>", "xyzw");
    try expectText("<t>R&D &nbsp; &#; &#xZZ; a&b</t>", "R&D &nbsp; &#; &#xZZ; a&b");
    // Whitespace references count as whitespace.
    try expectText("<t>a&#10;&#10;b&#32;&#32;c&#9;d</t>", "a\nb c d");
    // Non-breaking space is text, not whitespace.
    try expectText("<t>1&#160;kg</t>", "1\u{A0}kg");
}

test "xmlToText: multibyte UTF-8 passes through" {
    try expectText(
        "<w:p><w:r><w:t>Ñandú — 日本語 “quoted” 🙂</w:t></w:r></w:p><w:p><w:r><w:t>Ünïcödé</w:t></w:r></w:p>",
        "Ñandú — 日本語 “quoted” 🙂\nÜnïcödé",
    );
}

test "xmlToText: whitespace collapsing and trimming" {
    try expectText("  <a>  x \n\n  y\t\tz  </a>  ", "x y z");
    try expectText("<p>a</p>\n\n<p>  </p>\n<p>b</p>", "a\nb");
    try expectText("", "");
    try expectText("<a><b/></a>", "");
}

test "xmlToText: comments, CDATA, PIs, doctype, quoted >" {
    try expectText(
        "<!DOCTYPE x><!-- <p>hidden</p> --><t>a<![CDATA[ <b>&amp; ]]>c</t>",
        "a <b>&amp; c",
    );
    try expectText("<a:p><a:r><a:t attr=\"x>y\" b='>'>ok</a:t></a:r></a:p>", "ok");
}

test "xmlToText: pptx, xlsx, ODF shapes" {
    // Two slides concatenated by unzip, each with its declaration.
    try expectText(
        "<?xml version=\"1.0\"?><p:sld><p:txBody><a:p><a:r><a:t>Slide</a:t></a:r><a:r><a:t>One</a:t></a:r></a:p></p:txBody></p:sld>" ++
            "<?xml version=\"1.0\"?><p:sld><a:p><a:r><a:t>Two</a:t></a:r></a:p></p:sld>",
        "SlideOne\nTwo",
    );
    try expectText(
        "<sst><si><t>alpha</t></si><si><r><t>be</t></r><r><t>ta</t></r><rPh><t>ベータ</t></rPh></si></sst>",
        "alpha\nbeta",
    );
    try expectText(
        "<office:text><text:h>Title</text:h><text:p>one<text:s/>two<text:tab/>three<text:line-break/>four</text:p>" ++
            "<text:p>sp<text:span text:style-name=\"T1\">an</text:span>ned</text:p></office:text>",
        "Title\none two three\nfour\nspanned",
    );
    try expectText(
        "<table:table><table:table-row><table:table-cell><text:p>a1</text:p></table:table-cell><table:table-cell><text:p>b1</text:p></table:table-cell></table:table-row>" ++
            "<table:table-row><table:table-cell><text:p>a2</text:p></table:table-cell></table:table-row></table:table>",
        "a1\nb1\na2",
    );
}

test "xmlToText: skipped elements" {
    try expectText(
        "<w:p><w:r><w:instrText> HYPERLINK \"x\" </w:instrText></w:r><w:r><w:t>link</w:t></w:r>" ++
            "<w:del><w:r><w:delText>gone</w:delText></w:r></w:del></w:p>",
        "link",
    );
    try expectText(
        "<mc:AlternateContent><mc:Choice><w:t>box</w:t></mc:Choice><mc:Fallback><v:x><mc:Fallback>in</mc:Fallback><w:t>box</w:t></v:x></mc:Fallback></mc:AlternateContent><w:t>after</w:t>",
        "boxafter",
    );
}

test "xmlToText: truncated input" {
    try expectText("<w:p><w:t>abc</w:t></w:p><w:p><w:t>de", "abc\nde");
    try expectText("<w:p><w:t>abc</w:t></w:p><w:p attr=\"x", "abc");
    try expectText("<t>a &am", "a &am");
    try expectText("<t>a<![CDATA[bc", "abc");
}

test "shrink cuts at a UTF-8 boundary" {
    const gpa = testing.allocator;
    const s = try gpa.dupe(u8, "aé日🙂");
    const r = try shrink(gpa, s, 5); // "a" + "é" (2) + 2 of 3 bytes of 日
    defer gpa.free(r);
    try testing.expectEqualStrings("aé", r);
    const t = try shrink(gpa, try gpa.dupe(u8, "abc"), 10);
    defer gpa.free(t);
    try testing.expectEqualStrings("abc", t);
}

const TestDir = struct {
    t: sys.TestDir,
    abs: []const u8,

    fn init(test_dir: *TestDir) !void {
        test_dir.t = try .init();
        test_dir.abs = test_dir.t.abs;
    }
    fn deinit(test_dir: *TestDir) void {
        test_dir.t.deinit();
    }
    fn write(test_dir: *TestDir, name: []const u8, data: []const u8) !void {
        try test_dir.t.write(name, data);
    }
    fn absZ(test_dir: *TestDir, name: []const u8) ![:0]u8 {
        return testing.allocator.printSentinel("{s}/{s}", .{ test_dir.abs, name }, 0);
    }
    fn extract(test_dir: *TestDir, name: []const u8, max: usize) ![]u8 {
        const p = try test_dir.absZ(name);
        defer testing.allocator.free(p);
        return extractText(
            testing.allocator,
            testing.io,
            p,
            kindOf(name).?,
            max,
            null,
        ) catch |err| switch (err) {
            error.ToolMissing => error.SkipZigTest,
            else => err,
        };
    }
};

fn expectExtract(test_dir: *TestDir, name: []const u8, want: []const u8) !void {
    const got = try test_dir.extract(name, 1 << 20);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "extract docx, xlsx, pptx (OOXML)" {
    var td: TestDir = undefined;
    try td.init();
    defer td.deinit();

    try td.write("d/[Content_Types].xml", "<?xml version=\"1.0\"?><Types/>");
    try td.write("d/word/document.xml",
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Quarterly</w:t></w:r><w:r><w:t xml:space="preserve"> report</w:t></w:r></w:p><w:p><w:r><w:t>Ingresos &amp; gastos — año</w:t></w:r></w:p></w:body></w:document>
    );
    try td.write(
        "d/word/footnotes.xml",
        "<?xml version=\"1.0\"?><w:footnotes><w:footnote><w:p><w:r><w:t>A footnote</w:t></w:r></w:p></w:footnote></w:footnotes>",
    );
    try zipInto(&td, "d", "doc.docx");
    try expectExtract(&td, "doc.docx", "Quarterly report\nIngresos & gastos — año\nA footnote");

    try td.write(
        "x/xl/sharedStrings.xml",
        "<?xml version=\"1.0\"?><sst count=\"2\"><si><t>Revenue</t></si><si><t>Coste unitario</t></si></sst>",
    );
    try td.write("x/xl/workbook.xml", "<workbook/>");
    try zipInto(&td, "x", "book.xlsx");
    try expectExtract(&td, "book.xlsx", "Revenue\nCoste unitario");

    // Numbers only: no sharedStrings.xml (unzip exits 11): empty, not an error.
    try td.write("y/xl/workbook.xml", "<workbook/>");
    try zipInto(&td, "y", "nums.xlsx");
    try expectExtract(&td, "nums.xlsx", "");

    try td.write(
        "p/ppt/slides/slide1.xml",
        "<?xml version=\"1.0\"?><p:sld><a:p><a:r><a:t>First slide</a:t></a:r></a:p></p:sld>",
    );
    try td.write(
        "p/ppt/slides/slide2.xml",
        "<?xml version=\"1.0\"?><p:sld><a:p><a:r><a:t>Second slide</a:t></a:r></a:p></p:sld>",
    );
    try td.write(
        "p/ppt/slides/_rels/slide1.xml.rels",
        "<Relationships><Relationship Target=\"nope\"/></Relationships>",
    );
    try td.write(
        "p/ppt/presentation.xml",
        "<p:presentation><a:t>not a slide</a:t></p:presentation>",
    );
    try zipInto(&td, "p", "deck.pptx");
    try expectExtract(&td, "deck.pptx", "First slide\nSecond slide");

    // A wildcard in the file name must not reach unzip as a pattern.
    try zipInto(&td, "x", "bo*.xlsx");
    try expectExtract(&td, "bo*.xlsx", "Revenue\nCoste unitario");
}

/// Zips `dir` into `name` at the test dir's top level, members (relative
/// names) in name order. `unzip -p` prints members in
/// archive order, and `zip -r` would follow readdir's order, which differs
/// between file systems (Office writes the body first; sorted names do too).
fn zipInto(test_dir: *TestDir, dir: []const u8, name: []const u8) !void {
    return zipWith(test_dir, dir, name, "");
}

/// `zipInto` with more options for zip.
fn zipWith(test_dir: *TestDir, dir: []const u8, name: []const u8, options: []const u8) !void {
    var buf: [256]u8 = undefined;
    const rel = try std.mem.print(&buf, "{s}/{s}", .{ test_dir.abs, dir });
    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.mem.print(
        &cmd_buf,
        "find . -type f | LC_ALL=C sort | zip -q -X {s} -@ '../{s}'",
        .{ options, name },
    );
    const r = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "sh", "-c", cmd },
        .cwd = .{ .path = rel },
    });
    defer testing.allocator.free(r.stdout);
    defer testing.allocator.free(r.stderr);
    // 127: zip is not installed.
    if (std.meta.eql(r.term, std.process.Child.Term{ .exited = 127 })) return error.SkipZigTest;
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

test "extract odt, ods (ODF)" {
    var td: TestDir = undefined;
    try td.init();
    defer td.deinit();

    try td.write("t/mimetype", "application/vnd.oasis.opendocument.text");
    try td.write("t/content.xml",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:h text:outline-level="1">Acta de reunión</text:h><text:p>Asistentes:<text:s/>Ana<text:tab/>Luis</text:p><text:p>Pro<text:span text:style-name="T1">yec</text:span>to Lumen</text:p></office:text></office:body></office:document-content>
    );
    try td.write(
        "t/styles.xml",
        "<office:document-styles><text:p>not content</text:p></office:document-styles>",
    );
    try zipInto(&td, "t", "minutes.odt");
    try expectExtract(&td, "minutes.odt", "Acta de reunión\nAsistentes: Ana Luis\nProyecto Lumen");

    try td.write("s/content.xml",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<office:document-content><office:body><office:spreadsheet><table:table table:name="H1"><table:table-row><table:table-cell office:value-type="string"><text:p>Item</text:p></table:table-cell><table:table-cell office:value-type="float" office:value="3"><text:p>3</text:p></table:table-cell></table:table-row><table:table-row><table:table-cell><text:p>Tornillo</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>
    );
    try zipInto(&td, "s", "sheet.ODS");
    // Each cell holds a text:p, so cells come out one per line.
    try expectExtract(&td, "sheet.ODS", "Item\n3\nTornillo");
}

/// A one-page PDF drawing `text` with Helvetica, xref offsets computed.
fn minimalPdf(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(gpa);
    const stream = try gpa.print("BT /F1 24 Tf 72 700 Td ({s}) Tj ET", .{text});
    defer gpa.free(stream);
    var offsets: [5]usize = undefined;
    try pdf.appendSlice(gpa, "%PDF-1.4\n");
    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    };
    for (objs, 0..) |o, k| {
        offsets[k] = pdf.items.len;
        if (k == 3) {
            try pdf.print(
                gpa,
                "4 0 obj\n<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n",
                .{ stream.len, stream },
            );
        } else {
            try pdf.print(gpa, "{d} 0 obj\n{s}\nendobj\n", .{ k + 1, o });
        }
    }
    const xref = pdf.items.len;
    try pdf.appendSlice(gpa, "xref\n0 6\n0000000000 65535 f \n");
    for (offsets) |off| try pdf.print(gpa, "{d:0>10} 00000 n \n", .{off});
    try pdf.print(gpa, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref});
    return pdf.toOwnedSlice(gpa);
}

test "extract pdf" {
    var td: TestDir = undefined;
    try td.init();
    defer td.deinit();

    const pdf = try minimalPdf(testing.allocator, "Hello Lumen PDF");
    defer testing.allocator.free(pdf);
    try td.write("hello.pdf", pdf);
    const got = try td.extract("hello.pdf", 1 << 20);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Hello Lumen PDF", std.mem.trim(u8, got, " \n"));

    // Truncation, not failure, past bytes_max.
    const short = try td.extract("hello.pdf", 5);
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("Hello", short);
}

test "extract errors: missing, corrupt, not a regular file" {
    var td: TestDir = undefined;
    try td.init();
    defer td.deinit();

    try testing.expectError(error.NotFound, td.extract("absent.pdf", 1024));
    try td.write("bad.pdf", "%PDF-1.4 this is not a pdf");
    try testing.expectError(error.ToolFailed, td.extract("bad.pdf", 1024));
    try td.write("bad.docx", "PK\x03\x04 truncated zip");
    try testing.expectError(error.ToolFailed, td.extract("bad.docx", 1024));
    try td.write("dir.odt/x", "");
    try testing.expectError(error.NotRegular, td.extract("dir.odt", 1024));
}

test "extract: a password-protected document fails at once, asking nobody" {
    var td: TestDir = undefined;
    try td.init();
    defer td.deinit();
    try td.write("e/word/document.xml", "<w:p><w:t>secret</w:t></w:p>");
    try zipWith(&td, "e", "locked.docx", "-P hunter2");
    try td.write("x/xl/sharedStrings.xml", "<sst><si><t>secret</t></si></sst>");
    try zipWith(&td, "x", "locked.xlsx", "-P hunter2");
    // unzip asked for the password on /dev/tty (the terminal the daemon was
    // started from, or this test) and waited out the timeout.
    const t0 = sys.monotonicNs();
    // Bad password (82); with members missing too, unzip says 11 instead:
    // no text, which is what there is to index.
    try testing.expectError(error.ToolFailed, td.extract("locked.xlsx", 1024));
    const none = try td.extract("locked.docx", 1024);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("", none);
    try testing.expect(sys.monotonicNs() - t0 < 5 * std.time.ns_per_s);
}

test "extract truncates xml documents at a UTF-8 boundary" {
    var td: TestDir = undefined;
    try td.init();
    defer td.deinit();

    try td.write("t/content.xml", "<office:text><text:p>ñññññ</text:p></office:text>");
    try zipInto(&td, "t", "n.odt");
    const got = try td.extract("n.odt", 5);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ññ", got);
}

test "runTool: size cap and timeout kill the tool" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotRegular, sys.openRegular("/dev/null"));
    var td: TestDir = undefined;
    try td.init();
    defer td.deinit();
    try td.write("in", "");
    const in_path = try td.absZ("in");
    defer gpa.free(in_path);
    const in = try sys.openRegular(in_path);
    defer sys.close(in);

    // Endless output: cut at the cap, the tool killed and reaped.
    const yes = try runTool(gpa, testing.io, &.{ "sh", "-c", "exec yes" }, in, 1000, &.{0}, 10_000, null);
    defer gpa.free(yes);
    try testing.expectEqual(@as(usize, 1000), yes.len);

    // Silent and stuck: a timeout error.
    const t0 = sys.monotonicNs();
    try testing.expectError(error.Timeout, runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "exec sleep 30" },
        in,
        1000,
        &.{0},
        200,
        null,
    ));
    try testing.expect(sys.monotonicNs() - t0 < 5 * std.time.ns_per_s);

    // Its output closed, alive: not waited for past the limit either.
    const t1 = sys.monotonicNs();
    try testing.expectError(error.Timeout, runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "exec >&-; exec sleep 30" },
        in,
        1000,
        &.{0},
        200,
        null,
    ));
    try testing.expect(sys.monotonicNs() - t1 < 5 * std.time.ns_per_s);

    // Output, then stuck: a timeout too. What came out was cached as the
    // whole text of the document, for good.
    try testing.expectError(error.Timeout, runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "echo hi; exec sleep 30" },
        in,
        1000,
        &.{0},
        200,
        null,
    ));

    // Exit codes.
    try testing.expectError(error.ToolFailed, runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "exit 3" },
        in,
        1000,
        &.{0},
        10_000,
        null,
    ));
    const ok = try runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "exit 11" },
        in,
        1000,
        &.{ 0, 11 },
        10_000,
        null,
    );
    defer gpa.free(ok);
    try testing.expectError(error.ToolMissing, runTool(
        gpa,
        testing.io,
        &.{"lumen-no-such-tool"},
        in,
        1000,
        &.{0},
        10_000,
        null,
    ));

    // Cancelled (the service is stopping): killed at once, running or with
    // its output closed, long before its own limit.
    var cancel: std.atomic.Value(bool) = .init(true);
    for ([_][]const u8{ "exec sleep 30", "exec >&-; exec sleep 30" }) |script| {
        const t2 = sys.monotonicNs();
        try testing.expectError(error.Timeout, runTool(
            gpa,
            testing.io,
            &.{ "sh", "-c", script },
            in,
            1000,
            &.{0},
            60_000,
            &cancel,
        ));
        try testing.expect(sys.monotonicNs() - t2 < 2 * std.time.ns_per_s);
    }
}

fn fuzzXml(_: void, smith: *testing.Smith) anyerror!void {
    // Markup bytes weigh more, so the fuzzer forms tags, entities, comments.
    const w: []const testing.Smith.Weight = &.{
        .value(
            u8,
            '<',
            10,
        ),
        .value(u8, '>', 10),
        .value(u8, '/', 6),
        .value(u8, '&', 6),
        .value(
            u8,
            ';',
            6,
        ),
        .value(u8, '#', 4),
        .value(u8, 'x', 4),
        .value(u8, '!', 3),
        .value(
            u8,
            '-',
            3,
        ),
        .value(u8, '[', 2),
        .value(u8, ']', 2),
        .value(u8, '?', 3),
        .value(
            u8,
            '"',
            3,
        ),
        .value(u8, ' ', 4),
        .value(u8, ':', 3),
        .value(u8, 'p', 4),
        .value(u8, 'w', 4),
        .value(u8, 't', 4),
        .rangeAtMost(u8, '0', '9', 1),
        .rangeAtMost(
            u8,
            0x80,
            0xff,
            1,
        ),
        .rangeAtMost(u8, 0, 255, 1),
    };
    var in: [1024]u8 = undefined;
    const xml = in[0..smith.sliceWeightedBytes(&in, w)];
    const text = try xmlToText(testing.allocator, xml);
    defer testing.allocator.free(text);
    // Text is cut only at ASCII markup, and entities decode to valid code
    // points: valid UTF-8 in, valid UTF-8 out.
    if (std.unicode.utf8ValidateSlice(xml)) try testing.expect(std.unicode.utf8ValidateSlice(text));
    try testing.expect(text.len <= xml.len * 2 + 4);
}

test "fuzz: xmlToText on arbitrary bytes" {
    const P = struct {
        fn lp(comptime s: []const u8) []const u8 {
            const len: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, s.len));
            return &len ++ s;
        }
    };
    try testing.fuzz({}, fuzzXml, .{ .corpus = &.{
        comptime P.lp(
            "<?xml version=\"1.0\"?><w:document><w:body><w:p><w:r><w:t>Hel</w:t></w:r><w:r><w:t>lo &amp; caf&#xE9;</w:t></w:r></w:p></w:body></w:document>",
        ),
        comptime P.lp(
            "<a:p><a:t>x &#128512; &#0; &#xD800; &bogus; &</a:t></a:p><!-- c --><![CDATA[<raw>]]><!DOCTYPE x><t a=\"1>2\">y</t><w:instrText>skip</w:instrText>",
        ),
        comptime P.lp(
            "<text:p>é\u{00a0}ü<text:span>日本</text:span></text:p><table:table-cell>1</table:table-cell><",
        ),
    } });
}
