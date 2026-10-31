//! Text for labels and previews: file names made safe, sizes, dates,
//! highlighted context lines.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const index = @import("index");
const widgets = @import("widgets.zig");

/// `path` with the home folder as "~", fit for a label.
pub fn homeRelative(arena: std.mem.Allocator, path: []const u8) [:0]const u8 {
    const home = std.mem.span(c.g_get_home_dir());
    const shown = (if (std.mem.startsWith(u8, path, home))
        arena.print("~{s}", .{path[home.len..]})
    else
        arena.dupe(u8, path)) catch return "";
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
        const control = sequence_bytes == 1 and (raw[at] < ascii_space or raw[at] == ascii_delete);
        if (control) {
            out.append(arena, ' ') catch return "";
        } else if (!isBidiControl(std.unicode.utf8Decode(raw[at..sequence_end]) catch 0)) {
            out.appendSlice(arena, raw[at..sequence_end]) catch return "";
        }
        at = sequence_end;
    }
    return out.toOwnedSliceSentinel(arena, 0) catch "";
}

/// ASCII's control characters: below the space, and DEL.
const ascii_space = 0x20;
const ascii_delete = 0x7f;

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
    const first = if (line > context_lines_before) line - context_lines_before else 1;
    var out: std.ArrayList(u8) = .empty;
    var line_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_number += 1) {
        if (line_number < first) continue;
        if (line_number > line + context_lines_after) break;
        const shown = core.utf8.validPrefix(raw[0..@min(raw.len, context_line_bytes_max)]);
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

/// The time now, in seconds since the Unix epoch.
pub fn now() i64 {
    return @divTrunc(c.g_get_real_time(), std.time.us_per_s);
}

/// Today's midnight, local time, in seconds since the Unix epoch.
pub fn startOfToday() i64 {
    // Null only for a date GLib cannot represent: then everything is "Earlier".
    const date_time = c.g_date_time_new_now_local() orelse return std.math.maxInt(i64);
    defer c.g_date_time_unref(date_time);
    const midnight = c.g_date_time_new_local(
        c.g_date_time_get_year(date_time),
        c.g_date_time_get_month(date_time),
        c.g_date_time_get_day_of_month(date_time),
        0,
        0,
        0,
    ) orelse return std.math.maxInt(i64);
    defer c.g_date_time_unref(midnight);
    return c.g_date_time_to_unix(midnight);
}

/// "Today at 09:30", "Yesterday at 18:05" or "Mar 3 at 12:00" for a time
/// in seconds since the Unix epoch.
pub fn formatWhen(arena: std.mem.Allocator, time_s: i64) [:0]const u8 {
    const date_time = c.g_date_time_new_from_unix_local(time_s) orelse return "";
    defer c.g_date_time_unref(date_time);
    const today_s = startOfToday();
    const format: [*:0]const u8 = if (time_s >= today_s)
        "Today at %H:%M"
    else if (time_s >= today_s - std.time.s_per_day)
        "Yesterday at %H:%M"
    else
        "%b %e at %H:%M";
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
        const title = trimmed[0..@min(trimmed.len, clipboard_title_bytes_max)];
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
