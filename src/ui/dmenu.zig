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
/// Rows listed with nothing typed, and best matches listed when filtering.
const rows_unfiltered_max = 500;
const rows_filtered_max = 200;
/// Bytes of a line, and of its meta, that filtering matches against. Each
/// keystroke scores every line on the main thread, and one multi-MB line
/// cost as much as thousands of short ones. Rows show less still
/// (`widgets.row_text_bytes_max`); the whole line is what gets printed.
const match_bytes_max = 1024;

const Line = struct {
    text: [:0]const u8,
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
    /// Holds the lines and their text.
    arena: std.heap.ArenaAllocator,
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
    session.prompt = session.arena.allocator().dupeSentinel(u8, prompt orelse "", 0) catch "";
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
                    const name = arena.dupeSentinel(u8, value, 0) catch continue;
                    // A first byte past ASCII starts a character, not an icon name.
                    const is_character = value.len > 0 and value[0] >= 0x80;
                    line.icon = if (is_character) .{ .emoji = name } else .byName(name);
                },
                .meta => line.meta = arena.dupe(u8, value) catch "",
                .nonselectable => line.selectable = !std.mem.eql(u8, value, rofi_true),
            }
        }
        text = text[0..nul_index];
    }
    if (!std.unicode.utf8ValidateSlice(text)) return;
    line.text = arena.dupeSentinel(u8, text, 0) catch return addLineOutOfMemory();
    session.lines.append(arena, line) catch return addLineOutOfMemory();
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
        c.g_application_command_line_print(
            session.caller,
            "%.*s\n",
            @as(c_int, @intCast(@min(choice_text.len, std.math.maxInt(c_int)))),
            choice_text.ptr,
        );
        c.g_application_command_line_set_exit_status(session.caller, 0);
    } else c.g_application_command_line_set_exit_status(session.caller, 1);
    // The caller's `lumen --dmenu` returns once this is released.
    c.g_object_unref(session.caller);
    session.finished = true;
    // The rows point into the session's lines.
    if (ui.view == .dmenu) row_list.clearRows(ui);
    if (session.reading) c.g_cancellable_cancel(session.cancellable) else session.destroy();
}

/// Enter on a row.
pub fn choose(ui: *Ui, index: u32) void {
    const session = ui.picker orelse return;
    if (index >= session.lines.items.len) return;
    finish(ui, session.lines.items[index].text);
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
        for (lines[0..@min(lines.len, rows_unfiltered_max)], 0..) |line, i| {
            row_list.addItem(ui, itemOf(arena, line, @intCast(i)));
        }
        return;
    }
    const Hit = struct { score: i32, line_index: u32 };
    var hits: std.ArrayList(Hit) = .empty;
    for (lines, 0..) |line, i| {
        const fields = [_][]const u8{ matched(line.text), matched(line.meta) };
        const score = core.fuzzy.scoreFields(query, &fields);
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
    const best = hits.items[0..@min(hits.items.len, rows_filtered_max)];
    for (best) |hit| row_list.addItem(ui, itemOf(arena, lines[hit.line_index], hit.line_index));
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
