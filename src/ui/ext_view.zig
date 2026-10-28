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
    // The open command, found again by its id in the new registry.
    const open_id: ?[]const u8 = if (ui.view == .ext) if (command(ui)) |cmd| cmd.id else null else null;

    const old_root = ui.ext_root;
    ui.ext_registry = reg;
    ui.ext_result = null;
    ui.ext_root = null;
    ui.ext_pending = false;
    ui.ext_root_pending = false;
    // Answers still on their way were asked of the old files: drop them.
    ui.ext_gen = 0;
    ui.ext_root_gen = 0;
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
    if (ui.view != .ext) {
        // Same row as before the reload (an update from Settings, say).
        ui.keepSelection();
        ui.rebuild();
    } else if (if (open_id) |id| find(reg, id) else null) |i| {
        ui.ext_cmd = i;
        ui.setView(.ext);
    } else ui.setView(.root);
    if (old_result) |r| r.destroy(ui.gpa);
    if (old_root) |r| r.destroy(ui.gpa);
    if (old) |r| r.destroy(ui.gpa);
    // What an update or removal from Settings said, over the rebuilt rows.
    if (ui.after_reload_pending) {
        ui.after_reload_pending = false;
        ui.showFailure(ui.after_reload[0..ui.after_reload_len :0]);
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
        if (it.icon == .none and sec.command < reg.commands.len) it.icon = reg.commands[sec.command].icon;
    };
    const old = ui.ext_root;
    ui.ext_root = res;
    ui.ext_root_pending = false;
    // Answers for a query typed over meanwhile change nothing on screen.
    if (ui.view == .root and res.sections.len > 0 and std.mem.eql(
        u8,
        res.query,
        std.mem.trim(u8, ui.query(), " "),
    )) {
        ui.keepSelection();
        ui.refresh();
    }
    if (old) |o| o.destroy(ui.gpa);
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
    const asked = ui.ext_root_pending and std.mem.eql(
        u8,
        ui.ext_root_asked[0..ui.ext_root_asked_len],
        q,
    );
    if (asked) return;
    const n = @min(q.len, ui.ext_root_asked.len);
    @memcpy(ui.ext_root_asked[0..n], q[0..n]);
    ui.ext_root_asked_len = n;
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
    const asked = ui.ext_pending and std.mem.eql(u8, ui.ext_asked[0..ui.ext_asked_len], q);
    if (!answered and !asked) ask(ui, q);
    return false;
}

fn ask(ui: *Ui, q: []const u8) void {
    const h = ui.ext_host orelse return;
    const reg = ui.ext_registry orelse return;
    const n = @min(q.len, ui.ext_asked.len);
    @memcpy(ui.ext_asked[0..n], q[0..n]);
    ui.ext_asked_len = n;
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
        const lctx = c.gdk_display_get_app_launch_context(
            c.gdk_display_get_default() orelse return,
        );
        defer c.g_object_unref(lctx);
        var err: ?*c.GError = null;
        if (c.g_app_info_launch_default_for_uri(
            target.ptr,
            @ptrCast(lctx),
            &err,
        ) == 0) if (err) |e| {
            log.warn("open {s}: {s}", .{ target, e.message });
            c.g_error_free(e);
        };
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
