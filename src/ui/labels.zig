//! Text for labels and previews: file names made safe, sizes, dates,
//! highlighted context lines.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const core = @import("core");
const os = @import("os");
const item_mod = @import("../item.zig");
const index = @import("index");
const widgets = @import("widgets.zig");

/// `path` with the home folder as "~", fit for a label.
pub fn homeRelative(arena: std.mem.Allocator, path: []const u8) [:0]const u8 {
    const home = std.mem.span(c.g_get_home_dir());
    const shown = (if (belowHome(path, home)) |rest|
        arena.print("~{s}", .{rest})
    else
        arena.dupe(u8, path)) catch return "";
    return displayText(arena, shown);
}

/// What follows `home` in `path` ("" or "/..."), when `path` is `home` or
/// below it: "/home/user2" is not below "/home/user".
fn belowHome(path: []const u8, home: []const u8) ?[]const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return null;
    const rest = path[home.len..];
    if (rest.len > 0 and rest[0] != '/') return null;
    return rest;
}

/// Text fit for a GtkLabel. Linux file names are bytes: they can hold invalid
/// UTF-8 (Pango then warns and draws garbage, and `--dump` failed outright)
/// or a newline (a two-line row). Invalid sequences become U+FFFD and
/// control characters a space, the line and paragraph separators too
/// (U+2028, U+2029: Pango breaks the line at each, MYP-578). Bidirectional
/// controls are left out: with them `invoice\u{202E}fdp.sh` showed as
/// "invoicehs.pdf"; without, text shows in the order it is stored. Only
/// for display: actions keep the raw path.
pub fn displayText(arena: std.mem.Allocator, raw: []const u8) [:0]const u8 {
    // Most text is printable ASCII, which stays as it is.
    for (raw) |byte| {
        if (byte < ascii_space or byte >= ascii_delete) break;
    } else return arena.dupeSentinel(u8, raw, 0) catch "";
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, raw.len + 1) catch return "";
    var at: usize = 0;
    while (at < raw.len) {
        const sequence_bytes = std.unicode.utf8ByteSequenceLength(raw[at]) catch 0;
        const sequence_end = at + sequence_bytes;
        const valid = sequence_bytes > 0 and sequence_end <= raw.len and
            std.unicode.utf8ValidateSlice(raw[at..sequence_end]);
        if (!valid) {
            out.appendSlice(arena, "\u{FFFD}") catch return "";
            at += 1;
            continue;
        }
        const code_point = std.unicode.utf8Decode(raw[at..sequence_end]) catch 0;
        if (shownAsSpace(code_point)) {
            out.append(arena, ' ') catch return "";
        } else if (!isBidiControl(code_point)) {
            out.appendSlice(arena, raw[at..sequence_end]) catch return "";
        }
        at = sequence_end;
    }
    return out.toOwnedSliceSentinel(arena, 0) catch "";
}

/// ASCII's control characters: below the space, and DEL.
const ascii_space = 0x20;
const ascii_delete = 0x7f;

/// Control characters (C0, DEL, C1 with NEL) and the line and paragraph
/// separators: shown as a space.
fn shownAsSpace(code_point: u21) bool {
    return switch (code_point) {
        0...ascii_space - 1, ascii_delete...0x9f, 0x2028, 0x2029 => true,
        else => false,
    };
}

/// Embeddings and overrides (U+202A–202E), isolates (U+2066–2069) and the
/// marks (U+200E, U+200F, U+061C): they reorder or place the text around
/// them and draw nothing.
fn isBidiControl(code_point: u21) bool {
    return switch (code_point) {
        0x202a...0x202e, 0x2066...0x2069, 0x200e, 0x200f, 0x061c => true,
        else => false,
    };
}

/// Lines shown after the matching one in a content preview.
pub const context_lines_after = 14;

/// Lines shown above the matching line in a content preview.
const context_lines_before = 6;
/// A line of the preview is cut to this: a minified file's one line would
/// make Pango lay out megabytes.
const context_line_bytes_max = 240;
/// The line numbers are dimmed to this opacity.
const line_number_alpha = "45%";

/// Pango markup of the lines around `line` (1-based), with line numbers and
/// every occurrence of `words` highlighted.
pub fn contextMarkup(
    arena: std.mem.Allocator,
    text: []const u8,
    line: u32,
    words: []const []const u8,
    highlight_open: []const u8,
) [:0]const u8 {
    return contextMarkupFrom(arena, text, 1, line, words, highlight_open);
}

/// Like `contextMarkup`, starting line numbering at `first_line_number`
/// (pass `line` when displaying a single-line snippet fallback).
pub fn contextMarkupFrom(
    arena: std.mem.Allocator,
    text: []const u8,
    first_line_number: u32,
    line: u32,
    words: []const []const u8,
    highlight_open: []const u8,
) [:0]const u8 {
    const start_at = @max(first_line_number, 1);
    const first = if (start_at > 1)
        start_at
    else if (line > context_lines_before)
        line - context_lines_before
    else
        1;
    var out: std.ArrayList(u8) = .empty;
    var line_number: u32 = start_at;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_number += 1) {
        if (line_number < first) continue;
        if (line_number > line +| context_lines_after) break;
        const cut_len = core.utf8.floorBoundary(raw, context_line_bytes_max);
        const shown = core.utf8.sanitizeAlloc(arena, raw[0..cut_len]) catch return "";
        const number = arena.print(
            "<span alpha=\"" ++ line_number_alpha ++ "\">{d: >4}  </span>",
            .{line_number},
        ) catch return "";
        out.appendSlice(arena, number) catch return "";
        if (line_number == line) out.appendSlice(arena, "<b>") catch return "";
        // Escape piece by piece, wrapping each hit.
        var position: usize = 0;
        while (position < shown.len) {
            // Folded matches: "accion" highlights "ACCIÓN", whose length differs.
            var hit: ?index.content.Span = null;
            for (words) |word| {
                if (index.content.findFold(shown, word, position)) |match| {
                    if (hit == null or match.start < hit.?.start) hit = match;
                }
            }
            const end = if (hit) |match| match.start else shown.len;
            appendEscaped(arena, &out, shown[position..end]) catch return "";
            if (hit) |match| {
                out.appendSlice(arena, highlight_open) catch return "";
                appendEscaped(arena, &out, shown[match.start..match.end]) catch return "";
                out.appendSlice(arena, "</span>") catch return "";
                position = match.end;
            } else position = shown.len;
        }
        if (line_number == line) out.appendSlice(arena, "</b>") catch return "";
        out.append(arena, '\n') catch return "";
    }
    return arena.dupeSentinel(u8, out.items, 0) catch "";
}

/// `text` escaped for Pango markup, appended to `out`.
pub fn appendEscaped(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) std.mem.Allocator.Error!void {
    if (text.len == 0) return;
    const escaped = c.g_markup_escape_text(text.ptr, @intCast(text.len));
    defer c.g_free(escaped);
    try out.appendSlice(arena, std.mem.span(escaped));
}

/// Content types GLib gives files it guesses wrong: media for source
/// files that share an extension with a video (.mts), and octet-stream,
/// GLib's "no idea" (no shared-mime-info data, for example).
const mime_video_prefix = "video/";
const mime_audio_prefix = "audio/";
pub const mime_unknown = "application/octet-stream";

/// "Kind" in the detail pane. GLib guesses from the extension and is wrong
/// for some source files: .zig is "unknown", .mts is a video ("MPEG-2
/// transport stream"). A file with a code badge is named after it then.
pub fn kindLabel(
    arena: std.mem.Allocator,
    path: []const u8,
    is_directory: bool,
    content_type: ?[*:0]const u8,
) [:0]const u8 {
    if (is_directory) return "Folder";
    const description = if (content_type) |content_type_z|
        c.g_content_type_get_description(content_type_z)
    else
        null;
    defer if (description) |text| c.g_free(text);
    const slash = std.mem.findScalarLast(u8, path, '/');
    const name = if (slash) |slash_index| path[slash_index + 1 ..] else path;
    var badge_text: [4]u8 = undefined;
    if (core.file_badge.of(name, &badge_text)) |badge| {
        const mime = if (content_type) |content_type_z| std.mem.span(content_type_z) else "";
        const media = std.mem.startsWith(u8, mime, mime_video_prefix) or
            std.mem.startsWith(u8, mime, mime_audio_prefix) or
            std.mem.eql(u8, mime, mime_unknown);
        const unknown = description == null or
            std.ascii.eqlIgnoreCase(std.mem.span(description.?), "unknown");
        if (media or unknown) {
            return arena.printSentinel("{s} file", .{badge.text}, 0) catch "File";
        }
    }
    const text = description orelse return "File";
    return arena.dupeSentinel(u8, std.mem.span(text), 0) catch "File";
}

/// The first `line_count_wanted` lines of `text`, without the newline
/// ending the last one.
pub fn firstLines(text: []const u8, line_count_wanted: usize) []const u8 {
    // Zero lines would be every line: the loop below never reaches 0.
    assert(line_count_wanted > 0);
    var line_count: usize = 0;
    for (text, 0..) |character, i| {
        if (character != '\n') continue;
        line_count += 1;
        if (line_count == line_count_wanted) return text[0..i];
    }
    return text;
}

/// A size for people: bytes up to a KB, then KB, MB... (binary, as file
/// managers on Linux show them) with one decimal.
pub fn formatSize(arena: std.mem.Allocator, bytes: u64) [:0]const u8 {
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB" };
    const unit_bytes = 1024;
    var amount: f64 = @floatFromInt(bytes);
    var unit_index: usize = 0;
    while (amount >= unit_bytes and unit_index + 1 < units.len) : (unit_index += 1) {
        amount /= unit_bytes;
    }
    return (if (unit_index == 0)
        arena.printSentinel("{d} bytes", .{bytes}, 0)
    else
        arena.printSentinel("{d:.1} {s}", .{ amount, units[unit_index] }, 0)) catch "";
}

pub const DayBounds = struct {
    today_start_s: i64,
    yesterday_start_s: i64,
    tomorrow_start_s: i64,
    /// This year's first second, and next year's.
    year_start_s: i64,
    next_year_start_s: i64,

    pub fn section(bounds: DayBounds, time_s: i64) [:0]const u8 {
        if (time_s >= bounds.today_start_s) return "Today";
        if (time_s >= bounds.yesterday_start_s) return "Yesterday";
        return "Earlier";
    }

    /// A file from 2019 read as this year's, and one dated in the future
    /// as today's (MYP-560): the year shows when it is not this one, and
    /// only today is "Today".
    pub fn dateFormat(bounds: DayBounds, time_s: i64) [*:0]const u8 {
        if (time_s >= bounds.today_start_s and time_s < bounds.tomorrow_start_s) {
            return "Today at %H:%M";
        }
        if (time_s >= bounds.yesterday_start_s and time_s < bounds.today_start_s) {
            return "Yesterday at %H:%M";
        }
        if (time_s >= bounds.year_start_s and time_s < bounds.next_year_start_s) {
            return "%b %e at %H:%M";
        }
        return "%b %e %Y";
    }
};

/// Today's, yesterday's and tomorrow's local calendar midnights in `tz` for
/// `now_s`, and the year's bounds. Using `GDateTime` +
/// `g_date_time_add_days` instead of subtracting 86400 s keeps "Yesterday"
/// aligned with calendar midnight across 23 h / 25 h DST days.
pub fn dayBoundsInZone(now_s: i64, tz: *c.GTimeZone) DayBounds {
    const fallback: DayBounds = .{
        .today_start_s = std.math.maxInt(i64),
        .yesterday_start_s = std.math.maxInt(i64),
        .tomorrow_start_s = std.math.maxInt(i64),
        .year_start_s = std.math.maxInt(i64),
        .next_year_start_s = std.math.maxInt(i64),
    };
    const utc_now = c.g_date_time_new_from_unix_utc(now_s) orelse return fallback;
    defer c.g_date_time_unref(utc_now);
    const local_now = c.g_date_time_to_timezone(utc_now, tz) orelse return fallback;
    defer c.g_date_time_unref(local_now);
    const today_midnight = c.g_date_time_new(
        tz,
        c.g_date_time_get_year(local_now),
        c.g_date_time_get_month(local_now),
        c.g_date_time_get_day_of_month(local_now),
        0,
        0,
        0,
    ) orelse return fallback;
    defer c.g_date_time_unref(today_midnight);
    const yesterday_midnight = c.g_date_time_add_days(today_midnight, -1) orelse return fallback;
    defer c.g_date_time_unref(yesterday_midnight);
    const tomorrow_midnight = c.g_date_time_add_days(today_midnight, 1) orelse return fallback;
    defer c.g_date_time_unref(tomorrow_midnight);
    const year = c.g_date_time_get_year(local_now);
    const year_start = c.g_date_time_new(tz, year, 1, 1, 0, 0, 0) orelse return fallback;
    defer c.g_date_time_unref(year_start);
    const next_year_start = c.g_date_time_add_years(year_start, 1) orelse return fallback;
    defer c.g_date_time_unref(next_year_start);
    return .{
        .today_start_s = c.g_date_time_to_unix(today_midnight),
        .yesterday_start_s = c.g_date_time_to_unix(yesterday_midnight),
        .tomorrow_start_s = c.g_date_time_to_unix(tomorrow_midnight),
        .year_start_s = c.g_date_time_to_unix(year_start),
        .next_year_start_s = c.g_date_time_to_unix(next_year_start),
    };
}

/// Today's, yesterday's and tomorrow's local calendar midnights, and the
/// year's bounds, in Unix seconds.
pub fn dayBounds() DayBounds {
    const tz = c.g_time_zone_new_local();
    defer c.g_time_zone_unref(tz);
    return dayBoundsInZone(os.nowSeconds(), tz);
}

/// "Today at 09:30", "Yesterday at 18:05", "Mar 3 at 12:00" or, from
/// another year, "Mar 3 2019" for a time in seconds since the Unix epoch.
pub fn formatWhen(arena: std.mem.Allocator, time_s: i64) [:0]const u8 {
    const date_time = c.g_date_time_new_from_unix_local(time_s) orelse return "";
    defer c.g_date_time_unref(date_time);
    const format = dayBounds().dateFormat(time_s);
    const formatted = c.g_date_time_format(date_time, format) orelse return "";
    defer c.g_free(formatted);
    return arena.dupeSentinel(u8, std.mem.span(formatted), 0) catch "";
}

/// A clipboard row's title is its first line, cut to this.
const clipboard_title_bytes_max = 120;

/// First non-blank line, collapsed and capped, for a clipboard row title
/// (made safe like a file name: copied text can hold anything).
pub fn firstLine(arena: std.mem.Allocator, text: []const u8) [:0]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const cut = core.utf8.floorBoundary(trimmed, clipboard_title_bytes_max);
        return displayText(arena, trimmed[0..cut]);
    }
    return "";
}

test "only paths at or below home are shown from ~" {
    try std.testing.expectEqualStrings("", belowHome("/home/user", "/home/user").?);
    try std.testing.expectEqualStrings("/a.txt", belowHome("/home/user/a.txt", "/home/user").?);
    try std.testing.expect(belowHome("/home/user2/a.txt", "/home/user") == null);
    try std.testing.expect(belowHome("/etc", "/home/user") == null);
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
    try std.testing.expectEqualStrings("plain name.txt", displayText(arena, "plain name.txt"));
    try std.testing.expectEqualStrings("a b", displayText(arena, "a\x7fb"));
    // Line and paragraph separators, NEL and C1 controls: one line, as a
    // newline is (MYP-578).
    try std.testing.expectEqualStrings(
        "report.pdf .sh",
        displayText(arena, "report.pdf\u{2029}.sh"),
    );
    try std.testing.expectEqualStrings("a b c d", displayText(arena, "a\u{2028}b\u{85}c\u{9b}d"));
    try std.testing.expectEqualStrings("\u{a0}é", displayText(arena, "\u{a0}é"));
}

test "a date shows its year unless it is this year's, and only today is Today (MYP-560)" {
    const utc = c.g_time_zone_new_identifier("UTC") orelse return error.SkipZigTest;
    defer c.g_time_zone_unref(utc);
    // 2026-11-27 12:00 UTC.
    const now_s: i64 = 1795780800;
    const bounds = dayBoundsInZone(now_s, utc);
    try std.testing.expectEqualStrings("Today at %H:%M", std.mem.span(bounds.dateFormat(now_s)));
    const day_s = std.time.s_per_day;
    try std.testing.expectEqualStrings(
        "Yesterday at %H:%M",
        std.mem.span(bounds.dateFormat(now_s - day_s)),
    );
    // Earlier this year (2026-03-03), and in 2019.
    try std.testing.expectEqualStrings("%b %e at %H:%M", std.mem.span(bounds.dateFormat(1772539200)));
    try std.testing.expectEqualStrings("%b %e %Y", std.mem.span(bounds.dateFormat(1551614400)));
    // Tomorrow is not today, and next year shows its year.
    try std.testing.expectEqualStrings("%b %e at %H:%M", std.mem.span(bounds.dateFormat(now_s + day_s)));
    try std.testing.expectEqualStrings("%b %e %Y", std.mem.span(bounds.dateFormat(now_s + 60 * day_s)));
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
    try std.testing.expectEqualStrings(
        "Caf\u{FFFD} meeting",
        firstLine(arena, "Caf\xe9 meeting"),
    );
    const markup = contextMarkupFrom(
        arena,
        "Caf\xe9 /* funci\xf3n buscar */",
        50,
        50,
        &.{"buscar"},
        "<span>",
    );
    try std.testing.expect(std.mem.find(u8, markup, "50") != null);
    try std.testing.expect(std.mem.find(u8, markup, "<b>") != null);
    try std.testing.expect(std.mem.find(u8, markup, "<span>buscar</span>") != null);
    try std.testing.expect(std.mem.find(u8, markup, "Caf\u{FFFD}") != null);
}

test "dayBoundsInZone aligns Yesterday with calendar midnight across DST transitions" {
    const ny = c.g_time_zone_new_identifier("America/New_York") orelse
        return error.SkipZigTest;
    defer c.g_time_zone_unref(ny);

    // US Spring Forward: 2026-03-08 is 23 hours long (EST -05 -> EDT -04).
    // On 2026-03-09 12:00 EDT:
    //   2026-03-09 00:00 EDT = 1773028800
    //   2026-03-08 00:00 EST = 1772946000 (82800 s earlier)
    const spring_now: i64 = 1773072000;
    const spring_bounds = dayBoundsInZone(spring_now, ny);
    try std.testing.expectEqual(@as(i64, 1773028800), spring_bounds.today_start_s);
    try std.testing.expectEqual(@as(i64, 1772946000), spring_bounds.yesterday_start_s);
    // 2026-03-07 23:30 EST (1772944200) must be "Earlier", not "Yesterday".
    try std.testing.expectEqualStrings("Earlier", spring_bounds.section(1772944200));
    try std.testing.expectEqualStrings("Yesterday", spring_bounds.section(1772946000));

    // US Fall Back: 2026-11-01 is 25 hours long (EDT -04 -> EST -05).
    // On 2026-11-02 12:00 EST:
    //   2026-11-02 00:00 EST = 1793595600
    //   2026-11-01 00:00 EDT = 1793505600 (90000 s earlier)
    const fall_now: i64 = 1793638800;
    const fall_bounds = dayBoundsInZone(fall_now, ny);
    try std.testing.expectEqual(@as(i64, 1793595600), fall_bounds.today_start_s);
    try std.testing.expectEqual(@as(i64, 1793505600), fall_bounds.yesterday_start_s);
    // 2026-11-01 00:30 EDT (1793507400) must be "Yesterday", not "Earlier".
    try std.testing.expectEqualStrings("Yesterday", fall_bounds.section(1793507400));
    try std.testing.expectEqualStrings("Earlier", fall_bounds.section(1793505599));
}
