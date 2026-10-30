//! Extensions in the window: their commands in the root search, the list a
//! command shows, its actions, keymaps, and reloading edited files.

const std = @import("std");
const c = @import("c");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;
const Host = @import("../ext/Host.zig");
const api = @import("../ext/api.zig");
const run = @import("../actions.zig");
const proc = @import("../sys/proc.zig");
const os = @import("os");
const themes = @import("themes.zig");
const Ui = @import("Ui.zig");
const form_view = @import("form_view.zig");

const log = std.log.scoped(.ext);

/// Starts the extension thread and loads the files. Main thread, once the
/// window exists.
pub fn start(ui: *Ui) void {
    var buf: [4096]u8 = undefined;
    const data_dir = std.mem.print(&buf, "{s}/lumen", .{
        std.mem.span(c.g_get_user_data_dir()),
    }) catch return;
    ui.ext_host = Host.start(ui.gpa, ui.io, ui.config_dir, data_dir, .{
        .ctx = ui,
        .registry = &onRegistry,
        .list = &onList,
        .act = &onAct,
        .root = &onRoot,
    }) catch |err| {
        log.warn("extensions: {t}", .{err});
        return;
    };
    ui.ext_stamp = Host.stamp(ui.config_dir, ui.settings.style);
    _ = ui.ext_host.?.setStyle(ui.settings.style);
    ui.ext_host.?.reload();
}

/// Loads the Style setting's style, if it is not the one loaded.
pub fn syncStyle(ui: *Ui) void {
    const h = ui.ext_host orelse return;
    if (h.setStyle(ui.settings.style)) h.reload();
}

/// After the GTK main loop has stopped.
pub fn shutdown(ui: *Ui) void {
    const h = ui.ext_host orelse return;
    ui.ext_host = null;
    h.shutdown();
}

/// Reloads when init.lua or an extension's files changed since the last
/// look (the window is about to open).
pub fn checkReload(ui: *Ui) void {
    const h = ui.ext_host orelse return;
    const s = Host.stamp(ui.config_dir, ui.settings.style);
    if (s == ui.ext_stamp) return;
    ui.ext_stamp = s;
    h.reload();
}

/// `lumen --reload`.
pub fn reload(ui: *Ui) void {
    const h = ui.ext_host orelse return;
    ui.ext_stamp = Host.stamp(ui.config_dir, ui.settings.style);
    h.reload();
}

pub fn command(ui: *Ui) ?*const Host.Command {
    const reg = ui.ext_registry orelse return null;
    if (ui.ext_cmd >= reg.commands.len) return null;
    return &reg.commands[ui.ext_cmd];
}

// ------------------------------------------------------------- results

fn onRegistry(reg: *Host.Registry, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    const old = ui.ext_registry;
    const old_result = ui.ext_result;
    const old_root = ui.ext_root;
    ui.ext_registry = reg;
    ui.ext_result = null;
    ui.ext_root = null;
    ui.ext_pending = false;
    ui.ext_root_pending = false;
    // Answers still on their way were asked of the old files: drop them.
    ui.ext_gen = 0;
    ui.ext_root_gen = 0;
    // What the views point at by index, found again by id (before anything
    // rebuilds them): the open view may have lost it.
    const lost = if (old) |o| remap(ui, o, reg) else false;
    themes.custom = reg.themes;
    ui.layout = reg.layout;
    ui.applyStructure();
    // Rows and theme names point into the old registry: rebuild before
    // freeing it. A theme from init.lua may be the one in use, and lumen.set
    // may have changed (or stopped changing) settings.
    ui.reloadSettings();
    // A style just chosen: its lumen.set as the new values.
    if (ui.style_defaults_pending) {
        ui.style_defaults_pending = false;
        var changed = false;
        for (reg.style_settings) |o| {
            if (ui.overridden(o.key)) continue;
            changed = ui.settings.set(o.key, o.value) or changed;
        }
        if (changed) ui.saveSettings();
    }
    if (lost or (ui.view == .ext and command(ui) == null)) {
        ui.setView(.root);
    } else if (ui.view == .ext) {
        ui.setView(.ext);
    } else {
        // Same row as before the reload (an update from Settings, say).
        ui.keepSelection();
        ui.rebuild();
    }
    if (old_result) |r| r.destroy(ui.gpa);
    if (old_root) |r| r.destroy(ui.gpa);
    if (old) |r| r.destroy(ui.gpa);
    // What an update or removal from Settings said, over the rebuilt rows.
    if (ui.after_reload_pending) {
        ui.after_reload_pending = false;
        ui.showFailure(ui.after_reload.slice());
    }
}

fn onRoot(res: *Host.RootResult, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    if (res.gen != ui.ext_root_gen) {
        res.destroy(ui.gpa);
        return;
    }
    const reg = ui.ext_registry orelse {
        res.destroy(ui.gpa);
        return;
    };
    for (res.sections) |sec| for (sec.items) |*it| {
        if (it.icon == .none and
            sec.command < reg.commands.len) it.icon = reg.commands[sec.command].icon;
    };
    ui.ext_root_pending = false;
    const old = ui.ext_root;
    const typed: ?[]const u8 = if (ui.view == .root) std.mem.trim(u8, ui.query(), " ") else null;
    switch (rootAnswer(typed, if (old) |o| o.query else null, res.query, res.sections.len > 0)) {
        .show => {
            ui.ext_root = res;
            ui.keepSelection();
            ui.refresh();
        },
        .keep => ui.ext_root = res,
        .drop => {
            res.destroy(ui.gpa);
            return;
        },
    }
    if (old) |o| o.destroy(ui.gpa);
}

const RootAnswer = enum {
    /// It answers what is typed: take it and build the rows again.
    show,
    /// Take it for later (typing that query again shows it at once).
    keep,
    /// The rows on screen are the last answer's, which must outlive them.
    drop,
};

/// What an answer to the root search for `answer` does, with `typed` in the
/// search bar (null: the root search is not showing) and the last answer,
/// for `last`, in hand. Rows copy only the Item, whose strings stay in the
/// answer: one whose rows may be on screen is freed only once they are
/// built again. (Typing "abc" then going back to "ab" before its answer came
/// showed "ab"'s rows again; freeing them for "abc"'s answer left the rows
/// pointing at freed memory.)
fn rootAnswer(
    typed: ?[]const u8,
    last: ?[]const u8,
    answer: []const u8,
    has_rows: bool,
) RootAnswer {
    const t = typed orelse return .keep;
    const last_shown = if (last) |l| std.mem.eql(u8, l, t) else false;
    if (std.mem.eql(u8, answer, t) and (has_rows or last_shown)) return .show;
    return if (last_shown) .drop else .keep;
}

/// Extension rows for the root search `q`: shown when they answer `q`,
/// asked for otherwise (they arrive with onRoot).
pub fn addRootSections(ui: *Ui, q: []const u8) void {
    const reg = ui.ext_registry orelse return;
    const h = ui.ext_host orelse return;
    var any = false;
    for (reg.commands) |cmd| any = any or cmd.root;
    if (!any or q.len < 2) return;
    if (ui.ext_root) |r| if (std.mem.eql(u8, r.query, q)) {
        for (r.sections) |sec| {
            if (sec.command >= reg.commands.len) continue;
            ui.addSection(reg.commands[sec.command].title);
            for (sec.items) |it| ui.addItem(it);
        }
        return;
    };
    const asked = ui.ext_root_pending and ui.ext_root_asked.eql(q);
    if (asked) return;
    ui.ext_root_asked.set(q);
    ui.ext_root_gen = h.root(reg.gen, q);
    ui.ext_root_pending = true;
}

fn onList(res: *Host.ListResult, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    if (res.gen != ui.ext_gen) {
        res.destroy(ui.gpa);
        return;
    }
    if (res.err) |e| log.warn("{s}: {s}", .{ if (command(ui)) |cmd| cmd.id else "?", e });
    // Rows without an icon wear their command's (the registry outlives the
    // result: a reload drops results first).
    if (command(ui)) |cmd| for (res.items) |*it| {
        if (it.icon == .none) it.icon = cmd.icon;
    };
    const old = ui.ext_result;
    ui.ext_result = res;
    ui.ext_pending = false;
    if (ui.view == .ext) {
        ui.keepSelection();
        ui.rebuild();
    }
    if (old) |o| o.destroy(ui.gpa);
}

fn onAct(res: *Host.ActResult, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    defer res.destroy(ui.gpa);
    if (res.gen != ui.ext_act_gen) return;
    ui.ext_act_gen = 0;
    if (res.err) |e| {
        log.warn("action: {s}", .{e});
        ui.showFailure(firstLine(ui.query_arena.allocator(), e));
        return;
    }
    switch (res.outcome) {
        .close => ui.hide(),
        .stay => ui.select(ui.selected),
        .refresh => if (ui.view == .ext) {
            ui.keepSelection();
            ui.setView(.ext);
        } else if (ui.view == .form) {
            // A form "refreshes" by starting over, ready for the next one.
            form_view.reset(ui);
            ui.rebuild();
        },
    }
}

fn find(reg: *const Host.Registry, id: []const u8) ?u16 {
    for (reg.commands, 0..) |cmd, i| if (std.mem.eql(u8, cmd.id, id)) return @intCast(i);
    return null;
}

/// An index no registry has: what a view held that a reload took away.
/// Lookups by it find nothing (the host keeps commands under maxInt(u16)).
const gone = std.math.maxInt(u16);

/// The open command and form, the preference or field being typed or
/// chosen: indexes into `old`, moved to `new` by id (Enter would otherwise
/// save into another extension's preferences, or submit another form).
/// True when the open view lost what it shows. Call with `new` in place.
fn remap(ui: *Ui, old: *const Host.Registry, new: *const Host.Registry) bool {
    ui.ext_cmd = sameCommand(old, new, ui.ext_cmd) orelse gone;
    const form = sameCommand(old, new, ui.form_cmd);
    // A form whose fields changed starts over: values are kept by position.
    const same_form = if (form) |i|
        sameFields(old.commands[ui.form_cmd].fields, new.commands[i].fields)
    else
        false;
    ui.form_cmd = form orelse gone;
    if (form != null and !same_form) form_view.reset(ui);
    switch (ui.input) {
        .pref => |i| ui.input = .{ .pref = samePref(old, new, i) orelse gone },
        .field => if (!same_form) {
            ui.input = .{ .field = gone };
        },
    }
    switch (ui.choosing) {
        .pref => |i| ui.choosing = .{ .pref = samePref(old, new, i) orelse gone },
        .field => if (!same_form) {
            ui.choosing = .{ .field = gone };
        },
        else => {},
    }
    return switch (ui.view) {
        .ext => ui.ext_cmd == gone,
        .form => ui.form_cmd == gone,
        .input => switch (ui.input) {
            .pref, .field => |i| i == gone,
        },
        .choose => switch (ui.choosing) {
            .pref, .field => |i| i == gone,
            else => false,
        },
        else => false,
    };
}

/// Command `i` of `old` in `new`, by id.
fn sameCommand(old: *const Host.Registry, new: *const Host.Registry, i: u16) ?u16 {
    if (i >= old.commands.len) return null;
    return find(new, old.commands[i].id);
}

/// Preference `i` of `old` in `new`: the same extension, name and kind.
fn samePref(old: *const Host.Registry, new: *const Host.Registry, i: u16) ?u16 {
    if (i >= old.prefs.len) return null;
    const p = old.prefs[i];
    for (new.prefs, 0..) |q, j| {
        if (std.mem.eql(u8, q.ext, p.ext) and std.mem.eql(u8, q.name, p.name) and
            q.kind == p.kind) return @intCast(j);
    }
    return null;
}

fn sameFields(a: []const Host.Pref, b: []const Host.Pref) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.name, y.name) or x.kind != y.kind) return false;
    return true;
}

/// The first line of an error (the rest is the traceback), in `a`.
fn firstLine(a: std.mem.Allocator, msg: []const u8) [:0]const u8 {
    const end = std.mem.findScalar(u8, msg, '\n') orelse msg.len;
    return a.dupeSentinel(u8, msg[0..@min(end, 200)], 0) catch "Failed";
}

// ----------------------------------------------------------------- rows

/// Commands, and the files that failed to load, for the root search.
pub fn rootItems(ui: *Ui, a: std.mem.Allocator) []const Item {
    const reg = ui.ext_registry orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (reg.commands, 0..) |cmd, i| {
        if (cmd.mode == .provider) continue;
        out.append(a, .{
            .key = a.print("ext:{s}", .{cmd.id}) catch continue,
            .title = cmd.title,
            .subtitle = cmd.subtitle,
            .accessory = "Command",
            .icon = cmd.icon,
            .keywords = cmd.keywords,
            .action = .{ .ext_command = .{ .index = @intCast(i), .run = cmd.mode == .run } },
        }) catch break;
    }
    for (reg.problems) |p| {
        out.append(a, .{
            .title = a.printSentinel(
                "Extension \"{s}\" failed to load",
                .{p.ext},
                0,
            ) catch continue,
            .subtitle = firstLine(a, p.message),
            .accessory = "Error",
            .icon = .{ .tile = .{ .name = "dialog-warning-symbolic", .color = .red } },
            .action = .ext_problem,
            .detail = p.message,
        }) catch break;
    }
    return out.items;
}

/// The open command's rows before filtering.
pub fn base(ui: *Ui) []Item {
    const r = ui.ext_result orelse return &.{};
    return if (r.command == ui.ext_cmd and r.err == null) r.items else &.{};
}

/// Before the ext view shows: list commands are asked once here.
pub fn enter(ui: *Ui) void {
    const cmd = command(ui) orelse return;
    if (cmd.mode == .list) ask(ui, "");
}

/// A search command's next keystroke: while its answer is on its way, the
/// rows on screen are the last answer's and stay as they are (rebuilding
/// them cost a frame per keystroke; `onList` rebuilds when it comes). True
/// when the request is made and nothing else is to be done.
pub fn waitingForSearch(ui: *Ui, q: []const u8) bool {
    const cmd = command(ui) orelse return false;
    if (cmd.mode != .search) return false;
    const r = ui.ext_result orelse return false;
    if (r != ui.ext_shown) return false;
    if (r.command == ui.ext_cmd and std.mem.eql(u8, r.query, q)) return false;
    _ = prepare(ui, q);
    return true;
}

/// On each refresh: search commands ask for the query typed, unless it is
/// already answered or on its way. True when the rows are local (filtered
/// by Lumen).
pub fn prepare(ui: *Ui, q: []const u8) bool {
    const cmd = command(ui) orelse return true;
    if (cmd.mode != .search) return true;
    const answered = if (ui.ext_result) |r| r.command == ui.ext_cmd and std.mem.eql(
        u8,
        r.query,
        q,
    ) else false;
    const asked = ui.ext_pending and ui.ext_asked.eql(q);
    if (!answered and !asked) ask(ui, q);
    return false;
}

fn ask(ui: *Ui, q: []const u8) void {
    const h = ui.ext_host orelse return;
    const reg = ui.ext_registry orelse return;
    ui.ext_asked.set(q);
    ui.ext_gen = h.list(reg.gen, ui.ext_cmd, q);
    ui.ext_pending = true;
}

pub fn emptyText(ui: *Ui, a: std.mem.Allocator, q: []const u8) [:0]const u8 {
    const cmd = command(ui) orelse return "No Results";
    if (ui.ext_result) |r| if (r.command == ui.ext_cmd) if (r.err) |e|
        return a.printSentinel("Error: {s}", .{firstLine(a, e)}, 0) catch "Error";
    if (ui.ext_pending) return "Loading...";
    if (cmd.mode == .search and q.len == 0) return "Type to search";
    return "No Results";
}

pub fn placeholder(ui: *Ui, buf: []u8) [*:0]const u8 {
    const cmd = command(ui) orelse return "Search...";
    if (cmd.placeholder.len > 0) return cmd.placeholder;
    // "Search Emoji" reads "Search Emoji...", not "Search Search Emoji...".
    const verb = if (std.mem.startsWith(u8, cmd.title, "Search ")) "" else "Search ";
    const text = std.mem.printSentinel(
        buf,
        "{s}{s}...",
        .{ verb, cmd.title },
        0,
    ) catch return "Search...";
    return text.ptr;
}

// -------------------------------------------------------------- actions

/// Enter on a command in the root search: opens its list, or runs it.
pub fn activate(ui: *Ui, i: u16) void {
    const reg = ui.ext_registry orelse return;
    if (i >= reg.commands.len) return;
    switch (reg.commands[i].mode) {
        .run => {
            const h = ui.ext_host orelse return;
            ui.ext_act_gen = h.act(reg.gen, i, false, 0, null, 0);
            ui.showRunning();
        },
        .form => form_view.open(ui, i),
        .provider => {},
        .list, .search => {
            ui.ext_cmd = i;
            ui.navigate(.ext);
        },
    }
}

/// Action `index` of the selected extension row.
pub fn perform(ui: *Ui, index_: u8) void {
    const it = ui.selectedItem() orelse return;
    if (it.action != .ext_item) return;
    const x = it.action.ext_item;
    if (index_ >= x.actions.len) return;
    if (it.confirm and index_ == 0 and ui.needsConfirm(it)) return;
    ui.closePanel();
    switch (x.actions[index_]) {
        .lua => {
            const h = ui.ext_host orelse return;
            const reg = ui.ext_registry orelse return;
            ui.ext_act_gen = h.act(reg.gen, x.command, x.root, x.gen, x.index, index_);
            ui.showRunning();
            return;
        },
        .open => |target| open(ui, target),
        .copy => |text| run.copy(text),
        .paste => |text| run.pasteText(text),
        .exec => |argv| proc.spawn(argv),
    }
    ui.hide();
}

/// A URL in the default app; a path ("~/" allowed) the way Lumen opens
/// files, Default Apps included.
fn open(ui: *Ui, target: [:0]const u8) void {
    if (std.mem.find(u8, target, "://") != null or std.mem.startsWith(u8, target, "mailto:")) {
        const lctx = proc.launchContext() orelse return;
        defer c.g_object_unref(lctx);
        var err: ?*c.GError = null;
        if (c.g_app_info_launch_default_for_uri(target.ptr, lctx, &err) == 0)
            proc.warnError(.ext, err, "open {s}", .{target});
        return;
    }
    var buf: [4096]u8 = undefined;
    const path = if (std.mem.startsWith(u8, target, "~/"))
        std.mem.printSentinel(
            &buf,
            "{s}/{s}",
            .{ std.mem.span(c.g_get_home_dir()), target[2..] },
            0,
        ) catch return
    else
        target;
    const info = os.info(path) orelse {
        log.warn("open {s}: no such file", .{path});
        return;
    };
    run.openFile(ui.actionCtx(), path, info.is_dir);
}

// --------------------------------------------------------------- keymaps

/// A keymap from init.lua or an extension: opens its command or view.
pub fn keymap(ui: *Ui, keyval: c_uint, state: c.GdkModifierType) bool {
    const reg = ui.ext_registry orelse return false;
    const mask = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK | c.GDK_SHIFT_MASK | c.GDK_SUPER_MASK;
    const key = c.gdk_keyval_to_lower(keyval);
    for (reg.keymaps) |k| {
        if (k.keyval != key or k.mods != state & mask) continue;
        if (!openTarget(ui, k.target, null)) log.warn(
            "keymap {s} ({s}): no command or view \"{s}\"",
            .{ k.keys, k.ext, k.target },
        );
        return true;
    }
    return false;
}

/// Opens a command by id ("github.prs") or a built-in view by name, with
/// `text` typed. False when there is no such thing.
pub fn openTarget(ui: *Ui, target: []const u8, text: ?[*:0]const u8) bool {
    if (ui.ext_registry) |reg| if (find(reg, target)) |i| {
        switch (reg.commands[i].mode) {
            .provider => return false,
            .run => {
                activate(ui, i);
                return true;
            },
            .form => {
                if (c.gtk_widget_get_visible(ui.window) == 0) ui.show();
                form_view.open(ui, i);
                return true;
            },
            .list, .search => {},
        }
        ui.ext_cmd = i;
        if (c.gtk_widget_get_visible(ui.window) == 0) {
            ui.showWith(.ext, text);
        } else {
            ui.navigate(.ext);
            if (text) |t| c.gtk_editable_set_text(@ptrCast(ui.entry), t);
        }
        return true;
    };
    const view = std.meta.stringToEnum(item_mod.View, target) orelse return false;
    if (view == .ext or view == .choose) return false;
    if (c.gtk_widget_get_visible(ui.window) == 0) ui.showWith(view, text) else ui.navigate(view);
    return true;
}

/// `lumen --key ctrl+g` for keys that are not built in.
pub fn parseKey(name: []const u8) ?api.Keys {
    return api.parseKeys(name);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "an answer whose rows may be on screen outlives them" {
    // "ab" shown, "abc" asked, back to "ab" before "abc" was answered: "ab"'s
    // rows are on screen again, so its answer stays.
    try testing.expectEqual(RootAnswer.drop, rootAnswer("ab", "ab", "abc", true));
    try testing.expectEqual(RootAnswer.show, rootAnswer("abc", "ab", "abc", true));
    // An empty answer to what is typed: rows from the last one, when they
    // answer the same, are built again before it is freed.
    try testing.expectEqual(RootAnswer.show, rootAnswer("ab", "ab", "ab", false));
    try testing.expectEqual(RootAnswer.keep, rootAnswer("abc", "ab", "abc", false));
    try testing.expectEqual(RootAnswer.keep, rootAnswer("abcd", "ab", "abc", true));
    try testing.expectEqual(RootAnswer.keep, rootAnswer("ab", null, "abc", true));
    // Another view shows no root rows.
    try testing.expectEqual(RootAnswer.keep, rootAnswer(null, "ab", "abc", true));
}

fn testCommand(id: [:0]const u8, fields: []const Host.Pref) Host.Command {
    return .{
        .id = id,
        .title = id,
        .subtitle = "",
        .icon = .none,
        .keywords = "",
        .placeholder = "",
        .mode = if (fields.len > 0) .form else .list,
        .detail = false,
        .root = false,
        .fields = fields,
    };
}

fn testPref(ext: [:0]const u8, name: [:0]const u8, kind: Host.PrefKind) Host.Pref {
    return .{
        .ext = ext,
        .ext_title = ext,
        .file = "",
        .name = name,
        .title = name,
        .description = "",
        .kind = kind,
        .default = "",
    };
}

test "indexes into the registry follow their ids across a reload" {
    const name = [_]Host.Pref{testPref("notes", "name", .text)};
    const renamed = [_]Host.Pref{testPref("notes", "title", .text)};
    const old_cmds = [_]Host.Command{
        testCommand("a.list", &.{}),
        testCommand("notes.new", &name),
        testCommand("b.gone", &.{}),
    };
    // An extension added before them shifts every index.
    const new_cmds = [_]Host.Command{
        testCommand("aaa.first", &.{}),
        testCommand("a.list", &.{}),
        testCommand("notes.new", &renamed),
    };
    const old_prefs = [_]Host.Pref{
        testPref("a", "token", .password),
        testPref("b", "key", .password),
    };
    const new_prefs = [_]Host.Pref{
        testPref("aaa", "token", .password),
        testPref("a", "token", .password),
        testPref("b", "key", .text),
    };
    const old: Host.Registry = .{
        .gen = 1,
        .commands = &old_cmds,
        .prefs = &old_prefs,
        .arena = undefined,
    };
    const new: Host.Registry = .{
        .gen = 2,
        .commands = &new_cmds,
        .prefs = &new_prefs,
        .arena = undefined,
    };
    try testing.expectEqual(@as(?u16, 1), sameCommand(&old, &new, 0));
    try testing.expectEqual(@as(?u16, 2), sameCommand(&old, &new, 1));
    try testing.expectEqual(@as(?u16, null), sameCommand(&old, &new, 2));
    try testing.expectEqual(@as(?u16, null), sameCommand(&old, &new, gone));
    // Not "aaa"'s token, which took its place.
    try testing.expectEqual(@as(?u16, 1), samePref(&old, &new, 0));
    // Now a text: typing a password for it would show it.
    try testing.expectEqual(@as(?u16, null), samePref(&old, &new, 1));
    try testing.expect(sameFields(&name, &name));
    try testing.expect(!sameFields(&name, &renamed));
    try testing.expect(!sameFields(&name, &.{}));
}
