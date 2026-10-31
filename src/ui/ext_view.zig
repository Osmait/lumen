//! Extensions in the window: their commands in the root search, the list a
//! command shows, its actions, keymaps, and reloading edited files.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const gtk = @import("gtk.zig");
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
    const host = ui.ext_host orelse return;
    if (host.setStyle(ui.settings.style)) host.reload();
}

/// After the GTK main loop has stopped.
pub fn shutdown(ui: *Ui) void {
    const host = ui.ext_host orelse return;
    ui.ext_host = null;
    host.shutdown();
}

/// Reloads when init.lua or an extension's files changed since the last
/// look (the window is about to open).
pub fn checkReload(ui: *Ui) void {
    const host = ui.ext_host orelse return;
    const stamp = Host.stamp(ui.config_dir, ui.settings.style);
    if (stamp == ui.ext_stamp) return;
    ui.ext_stamp = stamp;
    host.reload();
}

/// `lumen --reload`.
pub fn reload(ui: *Ui) void {
    const host = ui.ext_host orelse return;
    ui.ext_stamp = Host.stamp(ui.config_dir, ui.settings.style);
    host.reload();
}

pub fn command(ui: *Ui) ?*const Host.Command {
    const registry = ui.ext_registry orelse return null;
    if (ui.ext_cmd >= registry.commands.len) return null;
    return &registry.commands[ui.ext_cmd];
}

// ------------------------------------------------------------- results

fn onRegistry(registry: *Host.Registry, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    const old = ui.ext_registry;
    ui.ext_registry = registry;
    // Answers still in flight come from the old files: forgetting the
    // requests drops them when they arrive.
    const old_result = ui.ext_list.forget();
    const old_root = ui.ext_root_search.forget();
    // What the views point at by index, found again by id (before anything
    // rebuilds them): the open view may have lost it.
    const lost = if (old) |old_value| remap(ui, old_value, registry) else false;
    ui.layout = registry.layout;
    ui.applyStructure();
    // Rows and theme names point into the old registry: rebuild before
    // freeing it. A theme from init.lua may be the one in use, and lumen.set
    // may have changed (or stopped changing) settings.
    ui.reloadSettings();
    // A style just chosen: its lumen.set as the new values.
    if (ui.style_defaults_pending) {
        ui.style_defaults_pending = false;
        var changed = false;
        for (registry.style_settings) |old_value| {
            if (ui.overridden(old_value.key)) continue;
            changed = ui.settings.set(old_value.key, old_value.value) or changed;
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

fn onRoot(answer: *Host.RootResult, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    if (!ui.ext_root_search.current(answer)) {
        answer.destroy(ui.gpa);
        return;
    }
    const registry = ui.ext_registry orelse {
        answer.destroy(ui.gpa);
        return;
    };
    for (answer.sections) |sec| for (sec.items) |*item| {
        if (item.icon == .none and
            sec.command < registry.commands.len) item.icon = registry.commands[sec.command].icon;
    };
    const last = ui.ext_root_search.latest;
    const typed: ?[]const u8 = if (ui.view == .root) std.mem.trim(u8, ui.query(), " ") else null;
    const decision = rootAnswer(
        typed,
        if (last) |last_answer| last_answer.query else null,
        answer.query,
        answer.sections.len > 0,
    );
    switch (decision) {
        .show, .keep => {
            const replaced = ui.ext_root_search.take(answer);
            if (decision == .show) {
                ui.keepSelection();
                ui.refresh();
            }
            if (replaced) |replaced_answer| replaced_answer.destroy(ui.gpa);
        },
        .drop => {
            ui.ext_root_search.answered();
            answer.destroy(ui.gpa);
        },
    }
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
    const typed_query = typed orelse return .keep;
    const last_shown = if (last) |last_query| std.mem.eql(u8, last_query, typed_query) else false;
    if (std.mem.eql(u8, answer, typed_query) and (has_rows or last_shown)) return .show;
    return if (last_shown) .drop else .keep;
}

/// Extension rows for the root search `q`: shown when they answer `q`,
/// asked for otherwise (they arrive with onRoot).
pub fn addRootSections(ui: *Ui, query: []const u8) void {
    const registry = ui.ext_registry orelse return;
    const host = ui.ext_host orelse return;
    var any = false;
    for (registry.commands) |cmd| any = any or cmd.root;
    if (!any or query.len < 2) return;
    if (ui.ext_root_search.latest) |r| if (std.mem.eql(u8, r.query, query)) {
        for (r.sections) |sec| {
            if (sec.command >= registry.commands.len) continue;
            ui.addSection(registry.commands[sec.command].title);
            for (sec.items) |item| ui.addItem(item);
        }
        return;
    };
    if (ui.ext_root_search.asking(query)) return;
    ui.ext_root_search.sent(host.root(registry.gen, query), query);
}

fn onList(answer: *Host.ListResult, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    if (!ui.ext_list.current(answer)) {
        answer.destroy(ui.gpa);
        return;
    }
    if (answer.err) |e| log.warn("{s}: {s}", .{ if (command(ui)) |cmd| cmd.id else "?", e });
    // Rows without an icon take their command's. The icon points into the
    // registry, which outlives the result: a reload destroys results first.
    if (command(ui)) |cmd| for (answer.items) |*item| {
        if (item.icon == .none) item.icon = cmd.icon;
    };
    const old = ui.ext_list.take(answer);
    if (ui.view == .ext) {
        ui.keepSelection();
        ui.rebuild();
    }
    if (old) |old_value| old_value.destroy(ui.gpa);
}

fn onAct(answer: *Host.ActResult, ctx: ?*anyopaque) void {
    const ui: *Ui = @ptrCast(@alignCast(ctx.?));
    defer answer.destroy(ui.gpa);
    if (answer.gen != ui.ext_act_gen) return;
    ui.ext_act_gen = 0;
    if (answer.err) |e| {
        log.warn("action: {s}", .{e});
        ui.showFailure(firstLine(ui.query_arena.allocator(), e));
        return;
    }
    switch (answer.outcome) {
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

fn find(registry: *const Host.Registry, id: []const u8) ?u16 {
    for (registry.commands, 0..) |cmd, i| if (std.mem.eql(u8, cmd.id, id)) return @intCast(i);
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
    const preference = old.prefs[i];
    for (new.prefs, 0..) |query, j| {
        if (std.mem.eql(u8, query.ext, preference.ext) and std.mem.eql(
            u8,
            query.name,
            preference.name,
        ) and
            query.kind == preference.kind) return @intCast(j);
    }
    return null;
}

fn sameFields(fields_old: []const Host.Pref, fields_new: []const Host.Pref) bool {
    if (fields_old.len != fields_new.len) return false;
    for (fields_old, fields_new) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or x.kind != y.kind) return false;
    }
    return true;
}

/// The first line of an error (the rest is the traceback), in `a`.
fn firstLine(arena: std.mem.Allocator, msg: []const u8) [:0]const u8 {
    const end = std.mem.findScalar(u8, msg, '\n') orelse msg.len;
    return arena.dupeSentinel(u8, msg[0..@min(end, 200)], 0) catch "Failed";
}

// ----------------------------------------------------------------- rows

/// Commands, and the files that failed to load, for the root search.
pub fn rootItems(ui: *Ui, arena: std.mem.Allocator) []const Item {
    const registry = ui.ext_registry orelse return &.{};
    var out: std.ArrayList(Item) = .empty;
    for (registry.commands, 0..) |cmd, i| {
        if (cmd.mode == .provider) continue;
        out.append(arena, .{
            .key = arena.print("ext:{s}", .{cmd.id}) catch continue,
            .title = cmd.title,
            .subtitle = cmd.subtitle,
            .accessory = "Command",
            .icon = cmd.icon,
            .keywords = cmd.keywords,
            .action = .{ .ext_command = .{ .index = @intCast(i), .run = cmd.mode == .run } },
        }) catch break;
    }
    for (registry.problems) |problem| {
        out.append(arena, .{
            .title = arena.printSentinel(
                "Extension \"{s}\" failed to load",
                .{problem.ext},
                0,
            ) catch continue,
            .subtitle = firstLine(arena, problem.message),
            .accessory = "Error",
            .icon = .{ .tile = .{ .name = "dialog-warning-symbolic", .color = .red } },
            .action = .ext_problem,
            .detail = problem.message,
        }) catch break;
    }
    return out.items;
}

/// The open command's rows before filtering.
pub fn base(ui: *Ui) []Item {
    const r = ui.ext_list.latest orelse return &.{};
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
pub fn waitingForSearch(ui: *Ui, query: []const u8) bool {
    const cmd = command(ui) orelse return false;
    if (cmd.mode != .search) return false;
    if (!ui.ext_list.showingLatest()) return false;
    const r = ui.ext_list.latest.?;
    if (r.command == ui.ext_cmd and std.mem.eql(u8, r.query, query)) return false;
    _ = prepare(ui, query);
    return true;
}

/// On each refresh: search commands ask for the query typed, unless it is
/// already answered or on its way. True when the rows are local (filtered
/// by Lumen).
pub fn prepare(ui: *Ui, query: []const u8) bool {
    const cmd = command(ui) orelse return true;
    if (cmd.mode != .search) return true;
    const answered = if (ui.ext_list.latest) |result|
        result.command == ui.ext_cmd and std.mem.eql(u8, result.query, query)
    else
        false;
    if (!answered and !ui.ext_list.asking(query)) ask(ui, query);
    return false;
}

fn ask(ui: *Ui, query: []const u8) void {
    const host = ui.ext_host orelse return;
    const registry = ui.ext_registry orelse return;
    ui.ext_list.sent(host.list(registry.gen, ui.ext_cmd, query), query);
}

pub fn emptyText(ui: *Ui, arena: std.mem.Allocator, query: []const u8) [:0]const u8 {
    const cmd = command(ui) orelse return "No Results";
    if (ui.ext_list.latest) |r| if (r.command == ui.ext_cmd) if (r.err) |e|
        return arena.printSentinel("Error: {s}", .{firstLine(arena, e)}, 0) catch "Error";
    if (ui.ext_list.pending) return "Loading...";
    if (cmd.mode == .search and query.len == 0) return "Type to search";
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
    const registry = ui.ext_registry orelse return;
    if (i >= registry.commands.len) return;
    switch (registry.commands[i].mode) {
        .run => {
            const host = ui.ext_host orelse return;
            ui.ext_act_gen = host.act(registry.gen, i, .command_run);
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

/// Action `action_index` of the selected extension row.
pub fn perform(ui: *Ui, action_index: u8) void {
    const item = ui.selectedItem() orelse return;
    if (item.action != .ext_item) return;
    const row = item.action.ext_item;
    if (action_index >= row.actions.len) return;
    if (item.confirm and action_index == 0 and ui.needsConfirm(item)) return;
    ui.panel.close();
    switch (row.actions[action_index]) {
        .lua => {
            const host = ui.ext_host orelse return;
            const registry = ui.ext_registry orelse return;
            ui.ext_act_gen = host.act(registry.gen, row.command, .{ .row_action = .{
                .from_root_search = row.root,
                .list_gen = row.gen,
                .row_index = row.index,
                .action_index = action_index,
            } });
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
    const registry = ui.ext_registry orelse return false;
    const mask = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK | c.GDK_SHIFT_MASK | c.GDK_SUPER_MASK;
    const key = c.gdk_keyval_to_lower(keyval);
    for (registry.keymaps) |binding| {
        if (binding.keyval != key or binding.mods != state & mask) continue;
        if (!openTarget(ui, binding.target, null)) {
            log.warn(
                "keymap {s} ({s}): no command or view \"{s}\"",
                .{ binding.keys, binding.ext, binding.target },
            );
        }
        return true;
    }
    return false;
}

/// Opens a command by id ("github.prs") or a built-in view by name, with
/// `text` typed. False when there is no such thing.
pub fn openTarget(ui: *Ui, target: []const u8, text: ?[*:0]const u8) bool {
    if (ui.ext_registry) |registry| if (find(registry, target)) |i| {
        switch (registry.commands[i].mode) {
            .provider => return false,
            .run => {
                activate(ui, i);
                return true;
            },
            .form => {
                if (!gtk.isVisible(ui.window)) ui.show();
                form_view.open(ui, i);
                return true;
            },
            .list, .search => {},
        }
        ui.ext_cmd = i;
        if (!gtk.isVisible(ui.window)) {
            ui.showWith(.ext, text);
        } else {
            ui.navigate(.ext);
            if (text) |t| c.gtk_editable_set_text(gtk.editable(ui.search_bar.entry), t);
        }
        return true;
    };
    const view = std.meta.stringToEnum(item_mod.View, target) orelse return false;
    if (view == .ext or view == .choose) return false;
    if (!gtk.isVisible(ui.window)) ui.showWith(view, text) else ui.navigate(view);
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
