//! `lumen --dmenu`: pick one of the lines given on stdin, like dmenu and
//! rofi -dmenu. The choice goes to the caller's stdout (exit 0); Esc, or the
//! window hiding, exits 1 with nothing printed.
//!
//! The caller is a remote command line: its invocation finishes when the
//! daemon lets go of the GApplicationCommandLine, so the session holds a
//! reference until a choice is made. Lines are read asynchronously and show
//! as they arrive; a slow or endless producer never blocks the daemon.
//!
//! rofi's row options are understood: "text\0icon\x1fname\x1fmeta\x1fwords"
//! (also `nonselectable\x1ftrue`).

const std = @import("std");
const c = @import("c");
const core = @import("core");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const row_list = @import("row_list.zig");
const labels = @import("labels.zig");
const Ui = @import("Ui.zig");

const log = std.log.scoped(.dmenu);

/// The row options rofi reads after a line's NUL, as key and value pairs
/// separated by `rofi_option_separator` (rofi's "\x1f").
const RofiOption = enum { icon, meta, nonselectable };
const rofi_option_separator = 0x1f;
const rofi_true = "true";

/// Reading stops after this many lines, or this many bytes, of input.
const lines_max = 200_000;
const input_bytes_max = 64 << 20;
/// Bytes asked of stdin per read.
const read_chunk_bytes = 256 * 1024;
/// While lines arrive, the list is rebuilt this often (ms), and less often
/// past `rebuild_slow_lines_min`: with a query typed, a rebuild scores
/// every line read so far.
const rebuild_delay_ms = 50;
const rebuild_slow_delay_ms = 250;
const rebuild_slow_lines_min = 10_000;
/// Rows listed with nothing typed, and best matches listed when filtering
/// (as many again of non-selectable ones, MYP-473). The lines past them
/// are reached by typing: a last row says how many there are (MYP-589).
const rows_unfiltered_max = 500;
const rows_filtered_max = 200;
/// Bytes of a line, and of its meta, that filtering matches against. Each
/// keystroke scores every line on the main thread, and one multi-MB line
/// cost as much as thousands of short ones. Rows show less still
/// (`widgets.row_text_bytes_max`); the whole line is what gets printed.
const match_bytes_max = 1024;

const Line = struct {
    /// What the row shows and filtering matches: valid UTF-8, on one line
    /// (`labels.displayText`).
    text: [:0]const u8,
    /// The line's bytes as read, printed when it is chosen, when `text`
    /// shows them otherwise: not valid UTF-8 (a Latin-1 file name, shown
    /// with U+FFFD), or holding controls or line separators.
    raw: ?[]const u8 = null,
    icon: item_mod.Icon = .none,
    meta: []const u8 = "",
    selectable: bool = true,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    /// The caller's command line, referenced until it has its answer.
    caller: *c.GApplicationCommandLine,
    stream: ?*c.GInputStream,
    cancellable: *c.GCancellable,
    /// Holds the lines' text.
    arena: std.heap.ArenaAllocator,
    /// In `gpa`: grown in the arena, each larger copy left the last one
    /// there, about twice the memory for 200 000 lines.
    lines: std.ArrayList(Line) = .empty,
    /// The end of the input not yet ended by a newline.
    partial: std.ArrayList(u8) = .empty,
    bytes_read: usize = 0,
    prompt: [:0]const u8,
    /// A read is in flight; the session is freed when it returns.
    reading: bool = false,
    /// The answer was given (or the caller let down): only cleanup is left.
    finished: bool = false,
    done_reading: bool = false,
    ui: *Ui,
    /// One rebuild per `rebuildDelay` while lines arrive: rebuilding the
    /// view for every read made a slow producer keep the main thread busy.
    rebuild_timer: c_uint = 0,

    fn destroy(session: *Session) void {
        if (session.rebuild_timer != 0) _ = c.g_source_remove(session.rebuild_timer);
        if (session.stream) |stream| c.g_object_unref(stream);
        c.g_object_unref(session.cancellable);
        session.partial.deinit(session.gpa);
        session.lines.deinit(session.gpa);
        session.arena.deinit();
        session.gpa.destroy(session);
    }
};

/// Starts a session for `caller` and shows it. Main thread.
pub fn start(
    ui: *Ui,
    caller: *c.GApplicationCommandLine,
    prompt: ?[]const u8,
    query: ?[*:0]const u8,
) void {
    if (ui.picker != null) finish(ui, null);
    const session = ui.gpa.create(Session) catch {
        c.g_application_command_line_set_exit_status(caller, 1);
        return;
    };
    session.* = .{
        .gpa = ui.gpa,
        .caller = @ptrCast(c.g_object_ref(caller)),
        .stream = c.g_application_command_line_get_stdin(caller),
        .cancellable = c.g_cancellable_new(),
        .arena = .init(ui.gpa),
        .prompt = "",
        .ui = ui,
    };
    // Shown in labels: whatever bytes `-p` was given, made valid UTF-8.
    session.prompt = labels.displayText(session.arena.allocator(), prompt orelse "");
    ui.picker = session;
    if (session.stream == null) session.done_reading = true else readMore(session);
    ui.showWith(.dmenu, query);
}

fn readMore(session: *Session) void {
    session.reading = true;
    c.g_input_stream_read_bytes_async(
        session.stream.?,
        read_chunk_bytes,
        0,
        session.cancellable,
        &onRead,
        session,
    );
}

fn onRead(_: ?*c.GObject, async_result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const session: *Session = @ptrCast(@alignCast(data.?));
    session.reading = false;
    var err: ?*c.GError = null;
    const bytes = c.g_input_stream_read_bytes_finish(session.stream.?, async_result, &err);
    defer if (bytes) |received| c.g_bytes_unref(received);
    if (err) |gerror| c.g_error_free(gerror);
    if (session.finished) return session.destroy();

    var length: usize = 0;
    const received_data = if (bytes) |received| c.g_bytes_get_data(received, &length) else null;
    const chunk: []const u8 = if (received_data) |chunk_start| chunk_start[0..length] else "";
    if (chunk.len == 0) {
        // End of input (or an error): the last line may lack its newline.
        if (session.partial.items.len > 0) addLine(session, session.partial.items);
        session.partial.clearRetainingCapacity();
        session.done_reading = true;
    } else {
        session.bytes_read += chunk.len;
        var rest = chunk;
        // Out of memory, a line would be cut and could be picked and printed
        // as it is not: reading stops at the last whole line instead.
        var out_of_memory = false;
        while (std.mem.findScalar(u8, rest, '\n')) |newline| {
            if (session.partial.items.len > 0) {
                session.partial.appendSlice(session.gpa, rest[0..newline]) catch {
                    out_of_memory = true;
                    break;
                };
                addLine(session, session.partial.items);
                session.partial.clearRetainingCapacity();
            } else addLine(session, rest[0..newline]);
            rest = rest[newline + 1 ..];
        }
        if (!out_of_memory) {
            session.partial.appendSlice(session.gpa, rest) catch {
                out_of_memory = true;
            };
        }
        if (out_of_memory) {
            log.warn("out of memory: stopped reading after {d} lines", .{session.lines.items.len});
            session.partial.clearRetainingCapacity();
            session.done_reading = true;
        } else if (session.lines.items.len >= lines_max or session.bytes_read >= input_bytes_max) {
            log.warn("stopped reading after {d} lines", .{session.lines.items.len});
            session.done_reading = true;
        } else readMore(session);
    }
    // The first screens at once (as many lines as the list shows with
    // nothing typed), the end at once, the rest now and then.
    if (session.done_reading or session.lines.items.len <= rows_unfiltered_max) {
        if (session.rebuild_timer != 0) _ = c.g_source_remove(session.rebuild_timer);
        session.rebuild_timer = 0;
        showLines(session);
    } else if (session.rebuild_timer == 0) {
        const delay_ms = rebuildDelay(session.lines.items.len);
        session.rebuild_timer = c.g_timeout_add(delay_ms, &onRebuildTimer, session);
    }
}

/// Milliseconds between rebuilds while `line_count` lines have arrived.
fn rebuildDelay(line_count: usize) c_uint {
    return if (line_count > rebuild_slow_lines_min) rebuild_slow_delay_ms else rebuild_delay_ms;
}

fn onRebuildTimer(data: ?*anyopaque) callconv(.c) c.gboolean {
    const session: *Session = @ptrCast(@alignCast(data.?));
    session.rebuild_timer = 0;
    if (session.finished) return 0;
    showLines(session);
    return 0;
}

fn showLines(session: *Session) void {
    const ui = session.ui;
    if (ui.view == .dmenu) {
        ui.keepSelection();
        ui.rebuild();
    }
}

fn addLine(session: *Session, raw: []const u8) void {
    if (session.lines.items.len >= lines_max) return;
    const arena = session.arena.allocator();
    var text = raw;
    if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
    var line: Line = .{ .text = "" };
    // rofi's options: text, NUL, then key\x1fvalue pairs.
    if (std.mem.findScalar(u8, text, 0)) |nul_index| {
        var options = std.mem.splitScalar(u8, text[nul_index + 1 ..], rofi_option_separator);
        while (options.next()) |key| {
            const value = options.next() orelse break;
            // An option Lumen does not know is skipped, as rofi does.
            const option = std.meta.stringToEnum(RofiOption, key) orelse continue;
            switch (option) {
                .icon => {
                    // A first byte past ASCII starts a character, not an icon
                    // name: drawn as text, so made valid UTF-8.
                    const is_character = value.len > 0 and value[0] >= 0x80;
                    if (is_character) {
                        line.icon = .{ .emoji = labels.displayText(arena, value) };
                    } else {
                        const name = arena.dupeSentinel(u8, value, 0) catch continue;
                        line.icon = .byName(name);
                    }
                },
                .meta => line.meta = arena.dupe(u8, value) catch "",
                .nonselectable => line.selectable = !std.mem.eql(u8, value, rofi_true),
            }
        }
        text = text[0..nul_index];
    }
    // Shown made valid and on one line, printed as is: left out, `find ~ |
    // lumen --dmenu` lost every file named in Latin-1 without a word
    // (MYP-447), and a U+2029 in a line took a row two lines (MYP-578).
    line.text = labels.displayText(arena, text);
    if (line.text.len == 0 and text.len > 0) return addLineOutOfMemory();
    if (!std.mem.eql(u8, line.text, text)) {
        line.raw = arena.dupe(u8, text) catch return addLineOutOfMemory();
    }
    session.lines.append(session.gpa, line) catch return addLineOutOfMemory();
}

fn addLineOutOfMemory() void {
    log.warn("out of memory: a line of standard input is left out", .{});
}

/// Answers the caller with `choice` (null: nothing chosen, exit 1) and ends
/// the session. The window is left as it is.
pub fn finish(ui: *Ui, choice: ?[]const u8) void {
    const session = ui.picker orelse return;
    ui.picker = null;
    if (choice) |choice_text| {
        printChoice(session.gpa, session.caller, choice_text);
        c.g_application_command_line_set_exit_status(session.caller, 0);
    } else c.g_application_command_line_set_exit_status(session.caller, 1);
    // The caller's `lumen --dmenu` returns once this is released.
    c.g_object_unref(session.caller);
    session.finished = true;
    if (session.rebuild_timer != 0) {
        _ = c.g_source_remove(session.rebuild_timer);
        session.rebuild_timer = 0;
    }
    // The rows point into the session's lines.
    if (ui.view == .dmenu) row_list.clearRows(ui);
    if (session.reading) c.g_cancellable_cancel(session.cancellable) else session.destroy();
}

/// What starts a choice sent to the caller, base64 after it: a remote
/// command line's output crosses D-Bus as a string, which GLib refuses for
/// bytes that are not UTF-8 (they arrived as "[Invalid UTF-8]"), and a line
/// of stdin is printed as read (MYP-447). The caller's `lumen-gtk --dmenu`
/// decodes it (`installCallerOutput`). Starts with ESC: no line of text
/// GLib would print begins so.
const choice_marker = "\x1b]lumen-dmenu;";

/// Prints `choice` to the caller, encoded, and a newline after it.
fn printChoice(gpa: std.mem.Allocator, caller: *c.GApplicationCommandLine, choice: []const u8) void {
    const message = encodeChoice(gpa, choice) catch {
        log.warn("out of memory: the choice is not printed", .{});
        return;
    };
    defer gpa.free(message);
    c.g_application_command_line_print(caller, "%s", message.ptr);
}

fn encodeChoice(gpa: std.mem.Allocator, choice: []const u8) std.mem.Allocator.Error![:0]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(choice.len);
    const message = try gpa.allocSentinel(u8, choice_marker.len + encoded_len + 1, 0);
    @memcpy(message[0..choice_marker.len], choice_marker);
    _ = encoder.encode(message[choice_marker.len..][0..encoded_len], choice);
    message[message.len - 1] = '\n';
    return message;
}

/// The choice `message` carries, with its newline, or null when it is not
/// one (then it is printed as it is).
fn decodeChoice(gpa: std.mem.Allocator, message: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, message, choice_marker)) return null;
    if (!std.mem.endsWith(u8, message, "\n")) return null;
    const encoded = message[choice_marker.len .. message.len - 1];
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return null;
    const choice = gpa.alloc(u8, decoded_len + 1) catch return null;
    decoder.decode(choice[0..decoded_len], encoded) catch {
        gpa.free(choice);
        return null;
    };
    choice[decoded_len] = '\n';
    return choice;
}

/// In the process `lumen --dmenu` runs (a launcher, or the primary instance
/// when no daemon runs): GLib prints a remote's output with g_print, and
/// this handler writes a choice back as the bytes it was.
pub fn installCallerOutput() void {
    _ = c.g_set_print_handler(&printToStdout);
}

fn printToStdout(message: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(message);
    const gpa = std.heap.page_allocator;
    if (decodeChoice(gpa, text)) |choice| {
        defer gpa.free(choice);
        writeStdout(choice);
    } else writeStdout(text);
}

fn writeStdout(bytes: []const u8) void {
    const linux = std.os.linux;
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(1, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => written += result,
            .INTR => {},
            else => return,
        }
    }
}

/// Enter on a row.
pub fn choose(ui: *Ui, index: u32) void {
    const session = ui.picker orelse return;
    if (index >= session.lines.items.len) return;
    const line = session.lines.items[index];
    if (!line.selectable) return;
    finish(ui, line.raw orelse line.text);
    ui.hide();
}

/// Ctrl+Enter, or Enter when no row matches: answers with the typed text.
pub fn chooseTyped(ui: *Ui) void {
    if (ui.picker == null) return;
    finish(ui, ui.query());
    ui.hide();
}

pub fn title(ui: *Ui) [*:0]const u8 {
    const session = ui.picker orelse return "Choose";
    return if (session.prompt.len > 0) session.prompt.ptr else "Choose";
}

pub fn emptyText(ui: *Ui) [:0]const u8 {
    const session = ui.picker orelse return "No Results";
    if (!session.done_reading) return "Reading...";
    return "No matches: Ctrl ↵ uses what you typed";
}

/// The rows for `query`: the first lines in order, or the best matches.
pub fn fill(ui: *Ui, arena: std.mem.Allocator, query: []const u8) void {
    const session = ui.picker orelse return;
    const lines = session.lines.items;
    if (query.len == 0) {
        const shown = @min(lines.len, rows_unfiltered_max);
        for (lines[0..shown], 0..) |line, i| {
            row_list.addItem(ui, itemOf(arena, line, @intCast(i)));
        }
        if (moreRow(arena, lines.len - shown, "lines")) |more| row_list.addItem(ui, more);
        return;
    }
    var hits: std.ArrayList(Hit) = .empty;
    // Folded once: up to 200 000 lines, two fields each, per keystroke.
    var query_buffer: [core.fuzzy.text_chars_max]u8 = undefined;
    const query_prepared = core.fuzzy.prepare(&query_buffer, query);
    for (lines, 0..) |line, i| {
        const fields = [_][]const u8{ matched(line.text), matched(line.meta) };
        const score = core.fuzzy.scoreFieldsQuery(query_prepared, &fields);
        if (score == core.fuzzy.no_match) continue;
        hits.append(arena, .{ .score = score, .line_index = @intCast(i) }) catch break;
    }
    // Best first; ties keep the input's order.
    std.mem.sort(Hit, hits.items, {}, struct {
        fn better(_: void, x: Hit, y: Hit) bool {
            if (x.score != y.score) return x.score > y.score;
            return x.line_index < y.line_index;
        }
    }.better);
    const best = keepBest(hits.items, lines);
    for (best.kept) |hit| row_list.addItem(ui, itemOf(arena, lines[hit.line_index], hit.line_index));
    if (moreRow(arena, best.left_out, "matches")) |more| row_list.addItem(ui, more);
}

const Hit = struct { score: i32, line_index: u32 };

/// The best of `hits` (sorted best first), moved to its front: up to
/// `rows_filtered_max` lines that can be chosen, and the non-selectable
/// ones (headers) ranked among them, up to as many again. Counted
/// together, 200 matching headers hid every line to choose, and Enter
/// printed the query (MYP-473). `left_out` counts the lines to choose that
/// did not fit.
fn keepBest(hits: []Hit, lines: []const Line) struct { kept: []Hit, left_out: usize } {
    var kept: usize = 0;
    var selectable: usize = 0;
    var headers: usize = 0;
    var left_out: usize = 0;
    for (hits) |hit| {
        if (lines[hit.line_index].selectable) {
            if (selectable == rows_filtered_max) {
                left_out += 1;
                continue;
            }
            selectable += 1;
        } else {
            // Past the last line listed, a header heads nothing.
            if (headers == rows_filtered_max or selectable == rows_filtered_max) continue;
            headers += 1;
        }
        hits[kept] = hit;
        kept += 1;
    }
    return .{ .kept = hits[0..kept], .left_out = left_out };
}

/// A last row, not selectable, saying that `count` more `what` are left
/// out and typing finds them; null when none are.
fn moreRow(arena: std.mem.Allocator, count: usize, what: []const u8) ?Item {
    if (count == 0) return null;
    const text = arena.printSentinel("… {d} more {s}: type to filter", .{ count, what }, 0) catch
        return null;
    return .{
        .title = text,
        .action = .{ .pick = .{ .index = std.math.maxInt(u32), .selectable = false } },
    };
}

/// The part of `text` filtering looks at.
fn matched(text: []const u8) []const u8 {
    return text[0..core.utf8.floorBoundary(text, match_bytes_max)];
}

test "a long line is matched by its head and printed whole" {
    var long: [3 * match_bytes_max]u8 = @splat('a');
    @memcpy(long[long.len - 6 ..], "needle");
    try std.testing.expectEqual(match_bytes_max, matched(&long).len);
    const score = core.fuzzy.scoreFields("needle", &.{matched(&long)});
    try std.testing.expect(score == core.fuzzy.no_match);
    try std.testing.expectEqualStrings("short", matched("short"));
    // A cut never splits a character.
    var accents: [match_bytes_max + 1]u8 = undefined;
    accents[0] = 'x';
    for (0..match_bytes_max / 2) |i| @memcpy(accents[1 + 2 * i ..][0..2], "é");
    try std.testing.expectEqual(match_bytes_max - 1, matched(&accents).len);
}

/// The row for line `line_index` of the input.
fn itemOf(arena: std.mem.Allocator, line: Line, line_index: u32) Item {
    return .{
        .key = arena.print("d:{d}", .{line_index}) catch "",
        .title = line.text,
        .icon = line.icon,
        .keywords = line.meta,
        .action = .{ .pick = .{ .index = line_index, .selectable = line.selectable } },
    };
}

test "addLine parses rofi options and marks nonselectable rows" {
    var session: Session = .{
        .gpa = std.testing.allocator,
        .caller = undefined,
        .stream = null,
        .cancellable = undefined,
        .arena = .init(std.testing.allocator),
        .prompt = "",
        .ui = undefined,
    };
    defer session.arena.deinit();
    defer session.lines.deinit(std.testing.allocator);

    addLine(&session, "Section\x00nonselectable\x1ftrue");
    addLine(&session, "First\x00icon\x1ffolder\x1fmeta\x1fwork docs\r");
    addLine(&session, "Emoji\x00icon\x1f🚀");
    addLine(&session, "Invalid\xffline");

    try std.testing.expectEqual(@as(usize, 4), session.lines.items.len);
    const header = session.lines.items[0];
    try std.testing.expectEqualStrings("Section", header.text);
    try std.testing.expect(!header.selectable);
    try std.testing.expect(!row_list.isSelectable(itemOf(session.arena.allocator(), header, 0)));

    const first = session.lines.items[1];
    try std.testing.expectEqualStrings("First", first.text);
    try std.testing.expect(first.selectable);
    try std.testing.expectEqualStrings("work docs", first.meta);
    try std.testing.expectEqualStrings("folder", first.icon.named);
    try std.testing.expect(row_list.isSelectable(itemOf(session.arena.allocator(), first, 1)));

    const emoji = session.lines.items[2];
    try std.testing.expectEqualStrings("Emoji", emoji.text);
    try std.testing.expectEqualStrings("🚀", emoji.icon.emoji);
    try std.testing.expect(emoji.raw == null);

    // Not UTF-8: shown with U+FFFD, chosen as the bytes read (MYP-447).
    const invalid = session.lines.items[3];
    try std.testing.expectEqualStrings("Invalid\u{FFFD}line", invalid.text);
    try std.testing.expectEqualStrings("Invalid\xffline", invalid.raw.?);

    // A paragraph separator: one row, the line printed as read (MYP-578).
    addLine(&session, "report.pdf\u{2029}.sh");
    const separated = session.lines.items[4];
    try std.testing.expectEqualStrings("report.pdf .sh", separated.text);
    try std.testing.expectEqualStrings("report.pdf\u{2029}.sh", separated.raw.?);
}

test "headers do not take the room of the lines to choose (MYP-473)" {
    var lines: [rows_filtered_max + 3]Line = undefined;
    var hits: [lines.len]Hit = undefined;
    // 201 matching headers ranked first, then two lines to choose.
    for (lines[0 .. lines.len - 2], hits[0 .. lines.len - 2], 0..) |*line, *hit, i| {
        line.* = .{ .text = "header", .selectable = false };
        hit.* = .{ .score = 100, .line_index = @intCast(i) };
    }
    lines[lines.len - 2] = .{ .text = "heading to choose" };
    hits[lines.len - 2] = .{ .score = 50, .line_index = lines.len - 2 };
    lines[lines.len - 1] = .{ .text = "heading too" };
    hits[lines.len - 1] = .{ .score = 40, .line_index = lines.len - 1 };
    const best = keepBest(&hits, &lines);
    try std.testing.expectEqual(@as(usize, rows_filtered_max + 2), best.kept.len);
    try std.testing.expectEqual(@as(usize, 0), best.left_out);
    try std.testing.expectEqual(@as(u32, lines.len - 2), best.kept[rows_filtered_max].line_index);
    try std.testing.expectEqual(@as(u32, lines.len - 1), best.kept[rows_filtered_max + 1].line_index);
}

test "lines past the limit are counted and said, headers after them dropped (MYP-589)" {
    var lines: [rows_filtered_max + 7]Line = undefined;
    var hits: [lines.len]Hit = undefined;
    for (&lines, &hits, 0..) |*line, *hit, i| {
        line.* = .{ .text = "line" };
        hit.* = .{ .score = 10, .line_index = @intCast(i) };
    }
    lines[lines.len - 1].selectable = false;
    const best = keepBest(&hits, &lines);
    try std.testing.expectEqual(@as(usize, rows_filtered_max), best.kept.len);
    try std.testing.expectEqual(@as(usize, 6), best.left_out);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(moreRow(arena, 0, "lines") == null);
    const more = moreRow(arena, 500, "lines").?;
    try std.testing.expectEqualStrings("… 500 more lines: type to filter", more.title);
    try std.testing.expect(!row_list.isSelectable(more));
}

test "a choice crosses to the caller as the bytes it was, UTF-8 or not" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "caf\xe9", "plain", "", "emoji \u{2b50}", "\x00\xff\x1b]lumen-dmenu;x" }) |choice| {
        const message = try encodeChoice(gpa, choice);
        defer gpa.free(message);
        try std.testing.expect(std.unicode.utf8ValidateSlice(message));
        const decoded = decodeChoice(gpa, message).?;
        defer gpa.free(decoded);
        try std.testing.expectEqualStrings(choice, decoded[0 .. decoded.len - 1]);
        try std.testing.expectEqual(@as(u8, '\n'), decoded[decoded.len - 1]);
    }
    // Anything else is printed as it is.
    try std.testing.expect(decodeChoice(gpa, "lumen: not running\n") == null);
    try std.testing.expect(decodeChoice(gpa, choice_marker ++ "!!!\n") == null);
}
