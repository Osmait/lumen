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
//!     cap, then the tool is SIGKILLed; past `timeout_ms` likewise. What was
//!     read by then is kept (truncated text still indexes).
//!   - The tools get an empty environment (`UNZIP=-a` and friends stay out).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("os");

pub const Kind = enum { pdf, docx, xlsx, pptx, odt, ods, odp };

/// Wall-clock budget for one tool run.
pub const timeout_ms = 15_000;

/// Kind from the file name's extension (case-insensitive), or null if not supported.
/// Office's `~$name.docx` owner files (not zips) are not documents.
pub fn kindOf(path: []const u8) ?Kind {
    const base = path[if (std.mem.findScalarLast(u8, path, '/')) |s| s + 1 else 0..];
    if (std.mem.startsWith(u8, base, "~$")) return null;
    const dot = std.mem.findScalarLast(u8, base, '.') orelse return null;
    const ext = base[dot + 1 ..];
    if (dot == 0 or ext.len == 0 or ext.len > 4) return null;
    var buf: [4]u8 = undefined;
    return std.meta.stringToEnum(Kind, std.ascii.lowerString(&buf, ext));
}

pub const ExtractError = Error || std.mem.Allocator.Error || sys.child.Error;

/// Extracted UTF-8 text of the document at `path` (absolute), owned by
/// `gpa`, at most `max_bytes` long (truncated, never failing for size).
/// An error for unreadable or corrupt files, which callers skip;
/// error.ToolMissing when pdftotext or unzip is not installed.
pub fn extractText(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: [:0]const u8,
    kind: Kind,
    max_bytes: usize,
) ExtractError![]u8 {
    const fd = try sys.openRegular(path);
    defer sys.close(fd);

    if (kind == .pdf) {
        const raw = try runTool(
            gpa,
            io,
            &.{ "pdftotext", "-q", "-enc", "UTF-8", "/dev/stdin", "-" },
            fd,
            max_bytes,
            &.{0},
            timeout_ms,
        );
        // Pages are separated by form feeds.
        std.mem.replaceScalar(u8, raw, '\x0c', '\n');
        return shrink(gpa, raw, max_bytes);
    }

    const members: []const []const u8 = switch (kind) {
        .pdf => unreachable, // handled above
        .docx => &.{ "word/document.xml", "word/footnotes.xml", "word/endnotes.xml" },
        .xlsx => &.{"xl/sharedStrings.xml"},
        .pptx => &.{"ppt/slides/slide*.xml"},
        .odt, .ods, .odp => &.{"content.xml"},
    };
    var argv: [8][]const u8 = undefined;
    argv[0] = "unzip";
    argv[1] = "-p";
    argv[2] = "/dev/stdin";
    @memcpy(argv[3..][0..members.len], members);

    // Markup outweighs text several times over; the cap only guards memory.
    const xml_cap = @max(max_bytes, @min(max_bytes *| 8, 256 << 20));
    // unzip: 11 = some member not found (optional ones, or an xlsx without
    // strings); a corrupt archive is 9.
    const xml = try runTool(
        gpa,
        io,
        argv[0 .. 3 + members.len],
        fd,
        xml_cap,
        &.{ 0, 11 },
        timeout_ms,
    );
    defer gpa.free(xml);
    return shrink(gpa, try xmlToText(gpa, xml), max_bytes);
}

pub const Error = sys.Error || error{ ToolMissing, ToolFailed, Timeout };

/// Runs `argv` with `input` as stdin and returns at most `cap` bytes of its
/// stdout. Reaching the cap or the timeout kills the tool and keeps what was
/// read; otherwise its exit code must be in `ok_codes`.
fn runTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    input: i32,
    cap: usize,
    ok_codes: []const u8,
    limit_ms: u64,
) ExtractError![]u8 {
    const r = sys.child.run(gpa, io, argv, .{
        .stdin = .{ .fd = input },
        .stderr = .ignore,
        .environ = .empty,
        .max_output_bytes = cap,
        .at_cap = .kill,
        .deadline_ns = sys.monotonicNs() + limit_ms * std.time.ns_per_ms,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.ToolMissing,
        else => |e| e,
    };
    gpa.free(r.stderr);
    errdefer gpa.free(r.stdout);
    if (r.timed_out or r.capped) {
        if (r.stdout.len == 0) return error.Timeout;
        return r.stdout;
    }
    const code = r.code orelse return error.ToolFailed;
    if (std.mem.findScalar(u8, ok_codes, code) == null) return error.ToolFailed;
    return r.stdout;
}

/// `s` cut to at most `max` bytes at a UTF-8 boundary, reallocated to fit.
fn shrink(gpa: std.mem.Allocator, s: []u8, max: usize) ![]u8 {
    const n = @import("core").utf8.floorBoundary(s, max);
    if (n == s.len) return s;
    if (gpa.resize(s, n)) return s[0..n];
    defer gpa.free(s);
    return gpa.dupe(u8, s[0..n]);
}

/// What a tag does to the surrounding text.
const Gap = enum(u2) { none, space, newline };

fn gapOf(local: []const u8) Gap {
    const newline = [_][]const u8{
        "p",         "h",          "br",   "cr",        "tr", "si", // w:/a:/text: paragraphs, rows, xlsx strings
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
    try out.ensureTotalCapacity(gpa, xml.len / 4 + 16);

    const W = struct {
        out: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        gap: Gap = .none,

        fn sep(w: *@This(), g: Gap) void {
            if (@backingInt(g) > @backingInt(w.gap)) w.gap = g;
        }
        fn text(w: *@This(), s: []const u8) !void {
            if (w.gap != .none and w.out.items.len > 0)
                try w.out.append(w.gpa, if (w.gap == .newline) '\n' else ' ');
            w.gap = .none;
            try w.out.appendSlice(w.gpa, s);
        }
        /// Character data, entities not decoded (CDATA) or already decoded.
        fn raw(w: *@This(), s: []const u8) !void {
            var i: usize = 0;
            while (i < s.len) {
                if (isSpace(s[i])) {
                    w.sep(.space);
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < s.len and !isSpace(s[i])) i += 1;
                try w.text(s[start..i]);
            }
        }
    };
    var w: W = .{ .out = &out, .gpa = gpa };

    var skip_name: ?[]const u8 = null;
    var skip_depth: usize = 0;
    var i: usize = 0;
    while (i < xml.len) {
        const rest = xml[i..];
        if (rest[0] != '<') {
            const end = i + (std.mem.findAny(u8, rest, "<&") orelse rest.len);
            if (skip_name == null) try w.raw(xml[i..end]);
            i = end;
            if (i < xml.len and xml[i] == '&') {
                const r = decodeEntity(xml[i..]);
                if (skip_name == null) {
                    if (r.len == 0) {
                        try w.text("&");
                    } else if (r.cp) |cp| {
                        var buf: [4]u8 = undefined;
                        switch (cp) {
                            '\n' => w.sep(.newline),
                            ' ', '\t', '\r' => w.sep(.space),
                            else => try w.text(
                                buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable],
                            ), // decodeEntity returns only encodable code points
                        }
                    }
                }
                i += @max(r.len, 1);
            }
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<!--")) {
            i = if (std.mem.findPos(u8, xml, i + 4, "-->")) |e| e + 3 else xml.len;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            const e = std.mem.findPos(u8, xml, i + 9, "]]>") orelse xml.len;
            if (skip_name == null) try w.raw(xml[i + 9 .. e]);
            i = @min(e + 3, xml.len);
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<?")) {
            // A declaration starts each concatenated member (pptx slides).
            w.sep(.newline);
            i = if (std.mem.findPos(u8, xml, i + 2, "?>")) |e| e + 2 else xml.len;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<!")) {
            i = if (std.mem.findScalarPos(u8, xml, i + 2, '>')) |e| e + 1 else xml.len;
            continue;
        }

        // A tag; `>` may appear inside quoted attribute values.
        var e = i + 1;
        var quote: u8 = 0;
        while (e < xml.len) : (e += 1) {
            const c = xml[e];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (c == '>') break;
        }
        if (e >= xml.len) break; // truncated
        const closing = xml[i + 1] == '/';
        const self_closing = xml[e - 1] == '/';
        const name_start = i + 1 + @intFromBool(closing);
        var name_end = name_start;
        while (name_end < e and !isSpace(xml[name_end]) and xml[name_end] != '/') name_end += 1;
        const name = xml[name_start..name_end];
        const local = name[if (std.mem.findScalarLast(u8, name, ':')) |c| c + 1 else 0..];
        i = e + 1;

        if (skip_name) |s| {
            if (std.mem.eql(u8, name, s)) {
                if (closing) {
                    skip_depth -= 1;
                    if (skip_depth == 0) skip_name = null;
                } else if (!self_closing) skip_depth += 1;
            }
            continue;
        }
        if (!closing and !self_closing and skipped(local)) {
            skip_name = name;
            skip_depth = 1;
            continue;
        }
        w.sep(gapOf(local));
    }
    return out.toOwnedSlice(gpa);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `&...;` at the start of `s`: bytes consumed (0 if not an entity) and the
/// code point (null for an invalid numeric reference, which is dropped).
fn decodeEntity(s: []const u8) struct { len: usize, cp: ?u21 } {
    const semi = std.mem.findScalar(
        u8,
        s[0..@min(s.len, 12)],
        ';',
    ) orelse return .{ .len = 0, .cp = null };
    const body = s[1..semi];
    const named = [_]struct { []const u8, u21 }{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{
        "quot",
        '"',
    }, .{
        "apos",
        '\'',
    } };
    for (named) |n| if (std.mem.eql(u8, body, n[0])) return .{ .len = semi + 1, .cp = n[1] };
    if (body.len < 2 or body[0] != '#') return .{ .len = 0, .cp = null };
    const v = if (body[1] == 'x' or body[1] == 'X')
        std.fmt.parseInt(u32, body[2..], 16)
    else
        std.fmt.parseInt(u32, body[1..], 10);
    const n = v catch return .{ .len = 0, .cp = null };
    const valid = n != 0 and n <= 0x10FFFF and !(n >= 0xD800 and n <= 0xDFFF);
    return .{ .len = semi + 1, .cp = if (valid) @intCast(n) else null };
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
    tmp: testing.TmpDir,
    rel: []const u8,
    abs: []const u8,
    rel_buf: [128]u8,

    fn init(td: *TestDir) !void {
        td.tmp = testing.tmpDir(.{});
        td.rel = try sys.tmpDirPath(&td.tmp, &td.rel_buf);
        const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
        defer testing.allocator.free(cwd);
        td.abs = try testing.allocator.print("{s}/{s}", .{ cwd, td.rel });
    }
    fn deinit(td: *TestDir) void {
        testing.allocator.free(td.abs);
        td.tmp.cleanup();
    }
    fn write(td: *TestDir, name: []const u8, data: []const u8) !void {
        var buf: [512]u8 = undefined;
        const p = try std.mem.printSentinel(&buf, "{s}/{s}", .{ td.rel, name }, 0);
        if (std.mem.findScalarLast(u8, p, '/')) |s| sys.mkdirP(p[0..s]);
        try sys.writeFile(p, data);
    }
    fn absZ(td: *TestDir, name: []const u8) ![:0]u8 {
        return testing.allocator.printSentinel("{s}/{s}", .{ td.abs, name }, 0);
    }
    fn extract(td: *TestDir, name: []const u8, max: usize) ![]u8 {
        const p = try td.absZ(name);
        defer testing.allocator.free(p);
        return extractText(
            testing.allocator,
            testing.io,
            p,
            kindOf(name).?,
            max,
        ) catch |err| switch (err) {
            error.ToolMissing => error.SkipZigTest,
            else => err,
        };
    }
};

fn expectExtract(td: *TestDir, name: []const u8, want: []const u8) !void {
    const got = try td.extract(name, 1 << 20);
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

/// Zips the contents of `dir` (relative member names) into `name` at the
/// test dir's top level.
/// Zips `dir` into `name`, members in name order. `unzip -p` prints members in
/// archive order, and `zip -r` would follow readdir's order, which differs
/// between file systems (Office writes the body first; sorted names do too).
fn zipInto(td: *TestDir, dir: []const u8, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const rel = try std.mem.print(&buf, "{s}/{s}", .{ td.rel, dir });
    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.mem.print(
        &cmd_buf,
        "find . -type f | LC_ALL=C sort | zip -q -X -@ '../{s}'",
        .{name},
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

    // Truncation, not failure, past max_bytes.
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
    const yes = try runTool(gpa, testing.io, &.{ "sh", "-c", "exec yes" }, in, 1000, &.{0}, 10_000);
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
    ));
    try testing.expect(sys.monotonicNs() - t1 < 5 * std.time.ns_per_s);

    // Output, then stuck: what came out is kept.
    const partial = try runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "echo hi; exec sleep 30" },
        in,
        1000,
        &.{0},
        200,
    );
    defer gpa.free(partial);
    try testing.expectEqualStrings("hi\n", partial);

    // Exit codes.
    try testing.expectError(error.ToolFailed, runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "exit 3" },
        in,
        1000,
        &.{0},
        10_000,
    ));
    const ok = try runTool(
        gpa,
        testing.io,
        &.{ "sh", "-c", "exit 11" },
        in,
        1000,
        &.{ 0, 11 },
        10_000,
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
    ));
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
