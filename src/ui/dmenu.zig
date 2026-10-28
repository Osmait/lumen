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
const Ui = @import("Ui.zig");

const log = std.log.scoped(.dmenu);

const max_lines = 200_000;
const max_bytes = 64 << 20;
/// Rows listed with nothing typed, and best matches listed when filtering.
const shown_all = 500;
const shown_matches = 200;

const Line = struct {
    text: [:0]const u8,
    icon: item_mod.Icon = .none,
    meta: []const u8 = "",
    selectable: bool = true,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    cmdline: *c.GApplicationCommandLine,
    stream: ?*c.GInputStream,
    cancel: *c.GCancellable,
    /// Lines and their text.
    arena: std.heap.ArenaAllocator,
    lines: std.ArrayList(Line) = .empty,
    /// The end of the input not yet ended by a newline.
    partial: std.ArrayList(u8) = .empty,
    bytes: usize = 0,
    prompt: [:0]const u8,
    /// A read is in flight; the session is freed when it returns.
    reading: bool = false,
    /// The answer was given (or the caller let down): only cleanup is left.
    finished: bool = false,
    done_reading: bool = false,
    ui: *Ui,
    /// One rebuild per 50 ms while lines arrive: rebuilding the view for
    /// every read made a slow producer keep the main thread busy.
    rebuild_timer: c_uint = 0,

    fn destroy(s: *Session) void {
        if (s.rebuild_timer != 0) _ = c.g_source_remove(s.rebuild_timer);
        if (s.stream) |st| c.g_object_unref(st);
        c.g_object_unref(s.cancel);
        s.partial.deinit(s.gpa);
        s.arena.deinit();
        s.gpa.destroy(s);
    }
};

/// Starts a session for `cmdline` and shows it. Main thread.
pub fn start(
    ui: *Ui,
    cmdline: *c.GApplicationCommandLine,
    prompt: ?[]const u8,
    query: ?[*:0]const u8,
) void {
    if (ui.picker != null) finish(ui, null);
    const s = ui.gpa.create(Session) catch {
        c.g_application_command_line_set_exit_status(cmdline, 1);
        return;
    };
    s.* = .{
        .gpa = ui.gpa,
        .cmdline = @ptrCast(c.g_object_ref(cmdline)),
        .stream = c.g_application_command_line_get_stdin(cmdline),
        .cancel = c.g_cancellable_new(),
        .arena = .init(ui.gpa),
        .prompt = "",
        .ui = ui,
    };
    s.prompt = s.arena.allocator().dupeSentinel(u8, prompt orelse "", 0) catch "";
    ui.picker = s;
    if (s.stream == null) s.done_reading = true else readMore(s);
    ui.showWith(.dmenu, query);
}

fn readMore(s: *Session) void {
    s.reading = true;
    c.g_input_stream_read_bytes_async(s.stream.?, 256 * 1024, 0, s.cancel, &onRead, s);
}

fn onRead(_: ?*c.GObject, res: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const s: *Session = @ptrCast(@alignCast(data.?));
    s.reading = false;
    var err: ?*c.GError = null;
    const bytes = c.g_input_stream_read_bytes_finish(s.stream.?, res, &err);
    defer if (bytes) |b| c.g_bytes_unref(b);
    if (err) |e| c.g_error_free(e);
    if (s.finished) return s.destroy();

    var len: usize = 0;
    const chunk: []const u8 = if (bytes) |b| if (c.g_bytes_get_data(
        b,
        &len,
    )) |p| p[0..len] else "" else "";
    if (chunk.len == 0) {
        // End of input (or an error): the last line may lack its newline.
        if (s.partial.items.len > 0) addLine(s, s.partial.items);
        s.partial.clearRetainingCapacity();
        s.done_reading = true;
    } else {
        s.bytes += chunk.len;
        var rest = chunk;
        // Out of memory, a line would be cut and could be picked and printed
        // as it is not: reading stops at the last whole line instead.
        var oom = false;
        while (std.mem.findScalar(u8, rest, '\n')) |nl| {
            if (s.partial.items.len > 0) {
                s.partial.appendSlice(s.gpa, rest[0..nl]) catch {
                    oom = true;
                    break;
                };
                addLine(s, s.partial.items);
                s.partial.clearRetainingCapacity();
            } else addLine(s, rest[0..nl]);
            rest = rest[nl + 1 ..];
        }
        if (!oom) s.partial.appendSlice(s.gpa, rest) catch {
            oom = true;
        };
        if (oom) {
            log.warn("out of memory: stopped reading after {d} lines", .{s.lines.items.len});
            s.partial.clearRetainingCapacity();
            s.done_reading = true;
        } else if (s.lines.items.len >= max_lines or s.bytes >= max_bytes) {
            log.warn("stopped reading after {d} lines", .{s.lines.items.len});
            s.done_reading = true;
        } else readMore(s);
    }
    // The first lines at once, the end at once, the rest every 50 ms.
    if (s.done_reading or s.lines.items.len <= 500) {
        if (s.rebuild_timer != 0) _ = c.g_source_remove(s.rebuild_timer);
        s.rebuild_timer = 0;
        showLines(s);
    } else if (s.rebuild_timer == 0) s.rebuild_timer = c.g_timeout_add(50, &onRebuildTimer, s);
}

fn onRebuildTimer(data: ?*anyopaque) callconv(.c) c.gboolean {
    const s: *Session = @ptrCast(@alignCast(data.?));
    s.rebuild_timer = 0;
    showLines(s);
    return 0;
}

fn showLines(s: *Session) void {
    const ui = s.ui;
    if (ui.view == .dmenu) {
        ui.keepSelection();
        ui.rebuild();
    }
}

fn addLine(s: *Session, raw: []const u8) void {
    if (s.lines.items.len >= max_lines) return;
    const a = s.arena.allocator();
    var text = raw;
    if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
    var line: Line = .{ .text = "" };
    // rofi's options: text, NUL, then key\x1fvalue pairs.
    if (std.mem.findScalar(u8, text, 0)) |nul| {
        var opts = std.mem.splitScalar(u8, text[nul + 1 ..], 0x1f);
        while (opts.next()) |key| {
            const value = opts.next() orelse break;
            if (std.mem.eql(u8, key, "icon")) {
                const name = a.dupeSentinel(u8, value, 0) catch continue;
                line.icon = if (value.len > 0 and value[0] >= 0x80) .{
                    .emoji = name,
                } else .byName(name);
            } else if (std.mem.eql(u8, key, "meta")) {
                line.meta = a.dupe(u8, value) catch "";
            } else if (std.mem.eql(u8, key, "nonselectable")) {
                line.selectable = !std.mem.eql(u8, value, "true");
            }
        }
        text = text[0..nul];
    }
    if (!std.unicode.utf8ValidateSlice(text)) return;
    line.text = a.dupeSentinel(u8, text, 0) catch return;
    s.lines.append(a, line) catch {};
}

/// Answers the caller with `choice` (null: nothing chosen, exit 1) and ends
/// the session. The window is left as it is.
pub fn finish(ui: *Ui, choice: ?[]const u8) void {
    const s = ui.picker orelse return;
    ui.picker = null;
    if (choice) |t| {
        c.g_application_command_line_print(
            s.cmdline,
            "%.*s\n",
            @as(c_int, @intCast(@min(t.len, std.math.maxInt(c_int)))),
            t.ptr,
        );
        c.g_application_command_line_set_exit_status(s.cmdline, 0);
    } else c.g_application_command_line_set_exit_status(s.cmdline, 1);
    // The caller's `lumen --dmenu` returns once this is released.
    c.g_object_unref(s.cmdline);
    s.finished = true;
    // The rows point into the session's lines.
    if (ui.view == .dmenu) ui.clearRows();
    if (s.reading) c.g_cancellable_cancel(s.cancel) else s.destroy();
}

/// Enter on a row.
pub fn choose(ui: *Ui, index: u32) void {
    const s = ui.picker orelse return;
    if (index >= s.lines.items.len) return;
    finish(ui, s.lines.items[index].text);
    ui.hide();
}

/// Ctrl+Enter, or Enter with nothing matching: what was typed.
pub fn chooseTyped(ui: *Ui) void {
    if (ui.picker == null) return;
    finish(ui, ui.query());
    ui.hide();
}

pub fn title(ui: *Ui) [*:0]const u8 {
    const s = ui.picker orelse return "Choose";
    return if (s.prompt.len > 0) s.prompt.ptr else "Choose";
}

pub fn emptyText(ui: *Ui) [:0]const u8 {
    const s = ui.picker orelse return "No Results";
    if (!s.done_reading) return "Reading...";
    return "No matches: Ctrl ↵ uses what you typed";
}

/// The rows for `q`: the first lines in order, or the best matches.
pub fn fill(ui: *Ui, a: std.mem.Allocator, q: []const u8) void {
    const s = ui.picker orelse return;
    const lines = s.lines.items;
    if (q.len == 0) {
        for (lines[0..@min(lines.len, shown_all)], 0..) |l, i| ui.addItem(
            itemOf(a, l, @intCast(i)),
        );
        return;
    }
    const Hit = struct { score: i32, i: u32 };
    var hits: std.ArrayList(Hit) = .empty;
    for (lines, 0..) |l, i| {
        const fields = [_][]const u8{ l.text, l.meta };
        const sc = core.fuzzy.scoreFields(q, &fields);
        if (sc == core.fuzzy.no_match) continue;
        hits.append(a, .{ .score = sc, .i = @intCast(i) }) catch break;
    }
    // Best first; ties keep the input's order.
    std.mem.sort(Hit, hits.items, {}, struct {
        fn gt(_: void, x: Hit, y: Hit) bool {
            return if (x.score != y.score) x.score > y.score else x.i < y.i;
        }
    }.gt);
    for (hits.items[0..@min(
        hits.items.len,
        shown_matches,
    )]) |h| ui.addItem(itemOf(a, lines[h.i], h.i));
}

fn itemOf(a: std.mem.Allocator, l: Line, i: u32) Item {
    return .{
        .key = a.print("d:{d}", .{i}) catch "",
        .title = l.text,
        .icon = l.icon,
        .keywords = l.meta,
        .action = .{ .pick = .{ .index = i, .selectable = l.selectable } },
    };
}
