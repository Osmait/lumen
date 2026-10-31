//! Text for labels and previews: file names made safe, sizes, dates,
//! highlighted context lines.

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const index = @import("index");
const widgets = @import("widgets.zig");

pub fn homeRelative(arena: std.mem.Allocator, dir: []const u8) [:0]const u8 {
    const home = std.mem.span(c.g_get_home_dir());
    const shown = (if (std.mem.startsWith(u8, dir, home))
        arena.print("~{s}", .{dir[home.len..]})
    else
        arena.dupe(u8, dir)) catch return "";
    return displayText(arena, shown);
}

/// Text fit for a GtkLabel. Linux file names are bytes: they can hold invalid
/// UTF-8 (Pango then warns and draws garbage, and `--dump` failed outright)
/// or a newline (a two-line row). Invalid sequences become U+FFFD and
/// control characters a space. Bidirectional controls are left out: with
/// them `invoice\u{202E}fdp.sh` showed as "invoicehs.pdf"; without, text
/// shows in the order it is stored. Only for display: actions keep the raw
/// path.
pub fn displayText(arena: std.mem.Allocator, raw: []const u8) [:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, raw.len + 1) catch return "";
    var i: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch 0;
        if (n == 0 or i + n > raw.len or !std.unicode.utf8ValidateSlice(raw[i .. i + n])) {
            out.appendSlice(arena, "\u{FFFD}") catch return "";
            i += 1;
            continue;
        }
        if (n == 1 and (raw[i] < 0x20 or raw[i] == 0x7f)) {
            out.append(arena, ' ') catch return "";
        } else if (!isBidiControl(std.unicode.utf8Decode(raw[i .. i + n]) catch 0)) {
            out.appendSlice(arena, raw[i .. i + n]) catch return "";
        }
        i += n;
    }
    return out.toOwnedSliceSentinel(arena, 0) catch "";
}

/// Embeddings and overrides (U+202A–202E), isolates (U+2066–2069) and the
/// marks (U+200E, U+200F, U+061C): they reorder or place the text around
/// them and draw nothing.
fn isBidiControl(cp: u21) bool {
    return switch (cp) {
        0x202a...0x202e, 0x2066...0x2069, 0x200e, 0x200f, 0x061c => true,
        else => false,
    };
}

/// Lines shown after the matching one in a content preview.
pub const context_after = 14;

/// Pango markup of the lines around `line` (1-based), with line numbers and
/// every occurrence of `words` highlighted.
pub fn contextMarkup(
    arena: std.mem.Allocator,
    text: []const u8,
    line: u32,
    words: []const []const u8,
    hl_open: []const u8,
) [:0]const u8 {
    const before = 6;
    const after = context_after;
    const first = if (line > before) line - before else 1;
    var out: std.ArrayList(u8) = .empty;
    var n: u32 = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (n += 1) {
        if (n < first) continue;
        if (n > line + after) break;
        const l = core.utf8.validPrefix(raw[0..@min(raw.len, 240)]);
        const num = arena.print("<span alpha=\"45%\">{d: >4}  </span>", .{n}) catch return "";
        out.appendSlice(arena, num) catch return "";
        if (n == line) out.appendSlice(arena, "<b>") catch return "";
        // Escape piece by piece, wrapping each hit.
        var pos: usize = 0;
        while (pos < l.len) {
            // Folded matches: "accion" highlights "ACCIÓN", whose length differs.
            var hit: ?index.content.Span = null;
            for (words) |w| {
                if (index.content.findFold(l, w, pos)) |m| {
                    if (hit == null or m.start < hit.?.start) hit = m;
                }
            }
            const end = if (hit) |m| m.start else l.len;
            appendEscaped(arena, &out, l[pos..end]);
            if (hit) |m| {
                out.appendSlice(arena, hl_open) catch return "";
                appendEscaped(arena, &out, l[m.start..m.end]);
                out.appendSlice(arena, "</span>") catch return "";
                pos = m.end;
            } else pos = l.len;
        }
        if (n == line) out.appendSlice(arena, "</b>") catch return "";
        out.append(arena, '\n') catch return "";
    }
    return arena.dupeSentinel(u8, out.items, 0) catch "";
}

pub fn appendEscaped(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    if (s.len == 0) return;
    const e = c.g_markup_escape_text(s.ptr, @intCast(s.len));
    defer c.g_free(e);
    out.appendSlice(arena, std.mem.span(e)) catch {};
}

/// "Kind" in the detail pane. GLib guesses from the extension and is wrong
/// for some source files: .zig is "unknown", .mts is a video ("MPEG-2
/// transport stream"). A file with a code badge is named after it then.
pub fn kindLabel(
    arena: std.mem.Allocator,
    path: []const u8,
    is_dir: bool,
    ctype: ?[*:0]const u8,
) [:0]const u8 {
    if (is_dir) return "Folder";
    const desc = if (ctype) |t| c.g_content_type_get_description(t) else null;
    defer if (desc) |d| c.g_free(d);
    const name = if (std.mem.findScalarLast(u8, path, '/')) |s| path[s + 1 ..] else path;
    var upper: [4]u8 = undefined;
    if (core.file_badge.of(name, &upper)) |b| {
        const t = if (ctype) |t| std.mem.span(t) else "";
        // octet-stream is GLib's "no idea" (e.g. no shared-mime-info data).
        const media = std.mem.startsWith(
            u8,
            t,
            "video/",
        ) or std.mem.startsWith(u8, t, "audio/") or std.mem.eql(
            u8,
            t,
            "application/octet-stream",
        );
        const unknown = desc == null or std.ascii.eqlIgnoreCase(std.mem.span(desc.?), "unknown");
        if (media or unknown) return arena.printSentinel("{s} file", .{b.text}, 0) catch "File";
    }
    return if (desc) |d| arena.dupeSentinel(u8, std.mem.span(d), 0) catch "File" else "File";
}

pub fn firstLines(text: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch != '\n') continue;
        count += 1;
        if (count == n) return text[0..i];
    }
    return text;
}

pub fn formatSize(arena: std.mem.Allocator, bytes: u64) [:0]const u8 {
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    return (if (u == 0)
        arena.printSentinel("{d} bytes", .{bytes}, 0)
    else
        arena.printSentinel("{d:.1} {s}", .{ v, units[u] }, 0)) catch "";
}

pub fn now() i64 {
    return @divTrunc(c.g_get_real_time(), std.time.us_per_s);
}

pub fn startOfToday() i64 {
    // Null only for a date GLib cannot represent: then everything is "Earlier".
    const dt = c.g_date_time_new_now_local() orelse return std.math.maxInt(i64);
    defer c.g_date_time_unref(dt);
    const midnight = c.g_date_time_new_local(
        c.g_date_time_get_year(dt),
        c.g_date_time_get_month(dt),
        c.g_date_time_get_day_of_month(dt),
        0,
        0,
        0,
    ) orelse return std.math.maxInt(i64);
    defer c.g_date_time_unref(midnight);
    return c.g_date_time_to_unix(midnight);
}

pub fn formatWhen(arena: std.mem.Allocator, unix: i64) [:0]const u8 {
    const dt = c.g_date_time_new_from_unix_local(unix) orelse return "";
    defer c.g_date_time_unref(dt);
    const today = startOfToday();
    const fmt: [*:0]const u8 = if (unix >= today)
        "Today at %H:%M"
    else if (unix >= today - std.time.s_per_day)
        "Yesterday at %H:%M"
    else
        "%b %e at %H:%M";
    const s = c.g_date_time_format(dt, fmt) orelse return "";
    defer c.g_free(s);
    return arena.dupeSentinel(u8, std.mem.span(s), 0) catch "";
}

/// A clipboard row's title is its first line, cut to this.
const clipboard_title_bytes_max = 120;

/// First non-blank line, collapsed and capped, for a clipboard row title
/// (made safe like a file name: copied text can hold anything).
pub fn firstLine(arena: std.mem.Allocator, text: []const u8) [:0]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len == 0) continue;
        const title = t[0..@min(t.len, clipboard_title_bytes_max)];
        return displayText(arena, core.utf8.validPrefix(title));
    }
    return "";
}

test "displayText makes any file name safe for a label" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    try std.testing.expectEqualStrings(
        "bad-\u{FFFD}\u{FFFD}-name.txt",
        displayText(arena, "bad-\xff\xfe-name.txt"),
    );
    try std.testing.expectEqualStrings("line1 line2.txt", displayText(arena, "line1\nline2.txt"));
    try std.testing.expectEqualStrings("acción ñandú 🔊", displayText(arena, "acción ñandú 🔊"));
    try std.testing.expectEqualStrings("trunc\u{FFFD}", displayText(arena, "trunc\xc3"));
}

test "bidirectional controls cannot disguise a name" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    try std.testing.expectEqualStrings(
        "invoicefdp.sh",
        displayText(arena, "invoice\u{202E}fdp.sh"),
    );
    try std.testing.expectEqualStrings(
        "abc.txt",
        displayText(arena, "\u{2066}a\u{200E}b\u{200F}c\u{061C}\u{2069}.txt"),
    );
    // Right-to-left text itself stays.
    try std.testing.expectEqualStrings("שלום.txt", displayText(arena, "שלום.txt"));
    // Clipboard titles go the same way.
    const title = firstLine(arena, "\n  pay \u{202E}fdp.exe\nmore");
    try std.testing.expectEqualStrings("pay fdp.exe", title);
    try std.testing.expectEqualStrings("a b", firstLine(arena, "a\tb"));
}
