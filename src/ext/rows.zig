//! An extension's rows, read from Lua tables into `Item`s, and the fields
//! rows share with commands (an icon, keywords). Runs on Host's worker,
//! inside a protected call: every check raises a Lua error that names the
//! field (`items[3].actions[2].argv`).

const std = @import("std");
const c = @import("c");
const lua = @import("luart").lua;
const core = @import("core");
const api = @import("api.zig");
const item_mod = @import("../item.zig");
const Item = item_mod.Item;

const assert = std.debug.assert;

/// The most rows one list answer takes.
pub const items_max = 1000;
/// The most actions one row takes.
pub const actions_max = 9;
/// A row's one-line texts (title, subtitle, accessory, section, id): longer
/// is unreadable in a row, and a label of megabytes takes seconds to lay out.
pub const line_bytes_max = 1024;
const keywords_bytes_max = 4096;
const path_bytes_max = 4096;
/// A row's `detail` or `markdown`.
pub const detail_bytes_max = 128 << 10;
/// Label and value pairs of a row's `metadata`.
const meta_max = item_mod.meta_max;
/// A short text that starts with a byte past ASCII is an emoji icon; any
/// other text names an icon.
const emoji_bytes_max = 32;

comptime {
    // `Entry.index` holds an action's index.
    assert(actions_max <= std.math.maxInt(@FieldType(item_mod.Entry, "index")));
    // Each of the first two actions has its keys (`keysFor`).
    assert(actions_max >= 2);
}

/// Where a list's rows came from: enough to run their actions later, and to
/// key them.
pub const RowsOrigin = struct {
    /// The request that listed them (`ExtItem.gen`).
    list_gen: u32,
    command: u16,
    from_root_search: bool = false,
    extension_id: []const u8,
};

/// One row of a list: where its list came from, its place in it, and how
/// errors name it.
const RowSource = struct {
    origin: RowsOrigin,
    /// Its position in the list, from 0.
    row_index: u32,
    /// "items[3]".
    where: []const u8,
};

pub fn parseItems(
    L: *lua.State,
    arena: std.mem.Allocator,
    rows: c_int,
    origin: RowsOrigin,
    rows_max: usize,
) []Item {
    assert(rows_max <= items_max);
    const rows_count = @min(lua.c.lua_rawlen(L, rows), rows_max);
    const items = arena.alloc(Item, rows_count) catch lua.oom(L);
    for (items, 0..) |*item, row_index| {
        const mark: lua.StackMark = .init(L);
        defer mark.restore(L);
        var where_buffer: [24]u8 = undefined;
        const where = std.mem.print(&where_buffer, "items[{d}]", .{row_index + 1}) catch "items";
        _ = lua.c.lua_rawgeti(L, rows, @intCast(row_index + 1));
        item.* = parseItem(L, arena, lua.absIndex(L, -1), .{
            .origin = origin,
            .row_index = @intCast(row_index),
            .where = where,
        });
    }
    assert(items.len <= rows_max);
    return items;
}

fn parseItem(L: *lua.State, arena: std.mem.Allocator, row: c_int, source: RowSource) Item {
    const where = source.where;
    // A plain string is a row with that title.
    if (lua.toSlice(L, row)) |text| {
        const title = arena.dupeSentinel(u8, lua.cut(text, line_bytes_max), 0) catch lua.oom(L);
        return .{
            .key = rankingKey(L, arena, source.origin.extension_id, title),
            .title = title,
            .action = .{ .ext_item = defaultActions(L, arena, source, title) },
        };
    }
    if (lua.c.lua_type(L, row) != lua.c.LUA_TTABLE) {
        const type_name = lua.typeName(L, row);
        lua.raise(L, "{s}: table or string expected, got {s}", .{ where, type_name });
    }
    const title = line(L, arena, row, "title", where) orelse
        lua.raise(L, "{s}.title is missing", .{where});
    const id = line(L, arena, row, "id", where) orelse title;
    var item: Item = .{
        .key = rankingKey(L, arena, source.origin.extension_id, id),
        .title = title,
        .subtitle = line(L, arena, row, "subtitle", where) orelse "",
        .accessory = line(L, arena, row, "accessory", where) orelse "",
        .keywords = keywords(L, arena, row, where),
        .detail = lua.fieldStringMax(L, arena, row, "detail", where, detail_bytes_max) orelse "",
        .section = line(L, arena, row, "section", where) orelse "",
        .confirm = lua.fieldBool(L, row, "confirm", false, where),
        .action = undefined,
    };
    if (fieldIcon(L, arena, row, where)) |icon| item.icon = icon;
    if (lua.fieldStringMax(L, arena, row, "markdown", where, detail_bytes_max)) |markdown| {
        var markup: std.Io.Writer.Allocating = .init(arena);
        core.markdown.toMarkup(&markup.writer, markdown) catch lua.oom(L);
        item.detail = markup.written();
        item.markup = true;
    }
    item.meta = metadata(L, arena, row, where);
    item.image = lua.fieldStringMax(L, arena, row, "image", where, path_bytes_max) orelse "";
    item.action = .{ .ext_item = rowActions(L, arena, row, source, title) };
    return item;
}

/// A row's one-line text `row[name]`, cut to `line_bytes_max`.
fn line(
    L: *lua.State,
    arena: std.mem.Allocator,
    row: c_int,
    name: [:0]const u8,
    where: []const u8,
) ?[:0]const u8 {
    return lua.fieldStringMax(L, arena, row, name, where, line_bytes_max);
}

/// A row's `actions` (up to `actions_max`, Lua functions or lumen.action
/// values), or the default ones when it has none.
fn rowActions(
    L: *lua.State,
    arena: std.mem.Allocator,
    row: c_int,
    source: RowSource,
    title: [:0]const u8,
) item_mod.ExtItem {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const action_list = lua.fieldList(L, row, "actions", source.where) orelse
        return defaultActions(L, arena, source, title);
    const actions_count = @min(lua.c.lua_rawlen(L, action_list), actions_max);
    if (actions_count == 0) lua.raise(L, "{s}.actions is empty", .{source.where});
    const actions = arena.alloc(item_mod.ExtAction, actions_count) catch lua.oom(L);
    const entries = arena.alloc(item_mod.Entry, actions_count) catch lua.oom(L);
    for (actions, entries, 0..) |*action, *entry, action_index| {
        const action_mark: lua.StackMark = .init(L);
        defer action_mark.restore(L);
        var where_buffer: [48]u8 = undefined;
        const action_where = std.mem.print(
            &where_buffer,
            "{s}.actions[{d}]",
            .{ source.where, action_index + 1 },
        ) catch source.where;
        const action_table = lua.tableAt(L, action_list, action_index + 1, action_where);
        const parsed = parseAction(L, arena, action_table, action_where);
        action.* = parsed.action;
        entry.* = .{
            .label = parsed.label,
            .keys = keysFor(action_index),
            .op = .ext,
            .index = @intCast(action_index),
        };
    }
    return extItem(source, actions, entries);
}

/// A row without actions copies its title.
fn defaultActions(
    L: *lua.State,
    arena: std.mem.Allocator,
    source: RowSource,
    title: [:0]const u8,
) item_mod.ExtItem {
    const actions = arena.dupe(item_mod.ExtAction, &.{.{ .copy = title }}) catch lua.oom(L);
    const entries = arena.dupe(item_mod.Entry, &.{.{
        .label = "Copy to Clipboard",
        .keys = "↵",
        .op = .ext,
    }}) catch lua.oom(L);
    return extItem(source, actions, entries);
}

fn extItem(
    source: RowSource,
    actions: []const item_mod.ExtAction,
    entries: []const item_mod.Entry,
) item_mod.ExtItem {
    assert(actions.len == entries.len);
    assert(actions.len >= 1);
    assert(actions.len <= actions_max);
    return .{
        .command = source.origin.command,
        .root = source.origin.from_root_search,
        .gen = source.origin.list_gen,
        .index = source.row_index,
        .actions = actions,
        .entries = entries,
    };
}

/// `metadata = { { "Label", "value" }, { label = "Size", value = 42 } }`:
/// up to `meta_max` pairs for the detail pane.
fn metadata(
    L: *lua.State,
    arena: std.mem.Allocator,
    row: c_int,
    where: []const u8,
) []const item_mod.Meta {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const pairs = lua.fieldList(L, row, "metadata", where) orelse return &.{};
    const pairs_count = @min(lua.c.lua_rawlen(L, pairs), meta_max);
    const metas = arena.alloc(item_mod.Meta, pairs_count) catch lua.oom(L);
    for (metas, 1..) |*meta, pair_number| {
        const pair_mark: lua.StackMark = .init(L);
        defer pair_mark.restore(L);
        var where_buffer: [48]u8 = undefined;
        const pair_where = std.mem.print(
            &where_buffer,
            "{s}.metadata[{d}]",
            .{ where, pair_number },
        ) catch where;
        const pair = lua.tableAt(L, pairs, pair_number, pair_where);
        meta.* = .{
            .label = line(L, arena, pair, "label", pair_where) orelse
                pairPart(L, arena, pair, 1, pair_where),
            .value = line(L, arena, pair, "value", pair_where) orelse
                pairPart(L, arena, pair, 2, pair_where),
        };
    }
    assert(metas.len <= meta_max);
    return metas;
}

/// `pair[part_number]` as text (numbers too), cut to `line_bytes_max`.
fn pairPart(
    L: *lua.State,
    arena: std.mem.Allocator,
    pair: c_int,
    part_number: c_int,
    where: []const u8,
) [:0]const u8 {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    switch (lua.c.lua_rawgeti(L, pair, part_number)) {
        lua.c.LUA_TSTRING, lua.c.LUA_TNUMBER => {
            var len: usize = 0;
            const bytes = lua.c.lua_tolstring(L, -1, &len);
            const text = lua.cut(bytes[0..len], line_bytes_max);
            return arena.dupeSentinel(u8, text, 0) catch lua.oom(L);
        },
        else => lua.raise(L, "{s}: {{ label, value }} expected", .{where}),
    }
}

/// The key a row's use is ranked by. Raises when out of memory: an empty
/// key would merge rows' rankings.
fn rankingKey(
    L: *lua.State,
    arena: std.mem.Allocator,
    extension_id: []const u8,
    id: []const u8,
) []const u8 {
    return arena.print("x:{s}:{s}", .{ extension_id, id }) catch lua.oom(L);
}

/// The key caps shown for a row's first two actions; the rest have none.
fn keysFor(action_index: usize) [:0]const u8 {
    return switch (action_index) {
        0 => "↵",
        1 => "Ctrl ↵",
        else => "",
    };
}

const ParsedAction = struct { action: item_mod.ExtAction, label: [:0]const u8 };

/// What `lumen.action.*` makes: `kind` says which.
const ActionKind = enum { open, copy, paste, exec };

fn parseAction(
    L: *lua.State,
    arena: std.mem.Allocator,
    action_table: c_int,
    where: []const u8,
) ParsedAction {
    const title = lua.fieldString(L, arena, action_table, "title", where);
    if (actionHasRun(L, action_table, where)) {
        return .{ .action = .lua, .label = title orelse "Run" };
    }
    const kind_name = lua.fieldString(L, arena, action_table, "kind", where) orelse
        lua.raise(L, "{s}: give it a run function, or make it with lumen.action.*", .{where});
    const kind = std.meta.stringToEnum(ActionKind, kind_name) orelse
        lua.raise(L, "{s}.kind: unknown \"{s}\"", .{ where, kind_name });
    switch (kind) {
        .open => {
            const target = lua.fieldString(L, arena, action_table, "target", where) orelse
                lua.raise(L, "{s}.target is missing", .{where});
            return .{ .action = .{ .open = target }, .label = title orelse "Open" };
        },
        .copy => {
            const text = actionText(L, arena, action_table, where);
            return .{ .action = .{ .copy = text }, .label = title orelse "Copy to Clipboard" };
        },
        .paste => {
            const text = actionText(L, arena, action_table, where);
            return .{ .action = .{ .paste = text }, .label = title orelse "Paste to Active App" };
        },
        .exec => {
            const argv = actionArgv(L, arena, action_table, where);
            return .{ .action = .{ .exec = argv }, .label = title orelse "Run" };
        },
    }
}

/// Whether the action is a Lua function (`run`).
fn actionHasRun(L: *lua.State, action_table: c_int, where: []const u8) bool {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    const run_type = lua.getField(L, action_table, "run");
    if (run_type == lua.c.LUA_TFUNCTION) return true;
    if (run_type != lua.c.LUA_TNIL) {
        lua.raise(L, "{s}.run: function expected, got {s}", .{ where, lua.typeName(L, -1) });
    }
    return false;
}

fn actionText(
    L: *lua.State,
    arena: std.mem.Allocator,
    action_table: c_int,
    where: []const u8,
) [:0]const u8 {
    return lua.fieldString(L, arena, action_table, "text", where) orelse
        lua.raise(L, "{s}.text is missing", .{where});
}

/// `lumen.action.exec`'s argv: 1 to `api.argv_max` strings.
fn actionArgv(
    L: *lua.State,
    arena: std.mem.Allocator,
    action_table: c_int,
    where: []const u8,
) []const [:0]const u8 {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    if (lua.getField(L, action_table, "argv") != lua.c.LUA_TTABLE) {
        lua.raise(L, "{s}.argv: a list of strings expected", .{where});
    }
    const words = lua.absIndex(L, -1);
    const words_count = lua.c.lua_rawlen(L, words);
    if (words_count == 0 or words_count > api.argv_max) {
        lua.raise(L, "{s}.argv: 1 to {d} strings expected", .{ where, api.argv_max });
    }
    const argv = arena.alloc([:0]const u8, words_count) catch lua.oom(L);
    for (argv, 1..) |*word, word_number| {
        const word_mark: lua.StackMark = .init(L);
        defer word_mark.restore(L);
        _ = lua.c.lua_rawgeti(L, words, @intCast(word_number));
        const text = lua.toSlice(L, -1) orelse
            lua.raise(L, "{s}.argv[{d}]: string expected", .{ where, word_number });
        word.* = arena.dupeSentinel(u8, text, 0) catch lua.oom(L);
    }
    return argv;
}

/// `keywords`: a string, or a list of strings joined with spaces; up to
/// `keywords_bytes_max`.
pub fn keywords(L: *lua.State, arena: std.mem.Allocator, table: c_int, where: []const u8) []const u8 {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    switch (lua.getField(L, table, "keywords")) {
        lua.c.LUA_TNIL => return "",
        lua.c.LUA_TSTRING => {
            const text = lua.cut(lua.toSlice(L, -1).?, keywords_bytes_max);
            return arena.dupe(u8, text) catch lua.oom(L);
        },
        lua.c.LUA_TTABLE => return keywordsJoined(L, arena, lua.absIndex(L, -1), where),
        else => {
            const type_name = lua.typeName(L, -1);
            lua.raise(L, "{s}.keywords: string or list expected, got {s}", .{ where, type_name });
        },
    }
}

/// The strings of the list at `keyword_list`, joined with spaces, as many
/// as fit in `keywords_bytes_max`.
fn keywordsJoined(
    L: *lua.State,
    arena: std.mem.Allocator,
    keyword_list: c_int,
    where: []const u8,
) []const u8 {
    var joined: std.ArrayList(u8) = .empty;
    const keywords_count = lua.c.lua_rawlen(L, keyword_list);
    for (1..keywords_count + 1) |keyword_number| {
        const mark: lua.StackMark = .init(L);
        defer mark.restore(L);
        _ = lua.c.lua_rawgeti(L, keyword_list, @intCast(keyword_number));
        const keyword = lua.toSlice(L, -1) orelse
            lua.raise(L, "{s}.keywords[{d}]: string expected", .{ where, keyword_number });
        if (joined.items.len + 1 + keyword.len > keywords_bytes_max) break;
        if (joined.items.len > 0) joined.append(arena, ' ') catch lua.oom(L);
        joined.appendSlice(arena, keyword) catch lua.oom(L);
    }
    assert(joined.items.len <= keywords_bytes_max);
    return joined.items;
}

/// `table.icon` (see `parseIcon`), or null when it has none.
pub fn fieldIcon(
    L: *lua.State,
    arena: std.mem.Allocator,
    table: c_int,
    where: []const u8,
) ?item_mod.Icon {
    const mark: lua.StackMark = .init(L);
    defer mark.restore(L);
    _ = lua.getField(L, table, "icon");
    return parseIcon(L, arena, -1, where);
}

/// An icon: an emoji ("🐙"), an icon name ("folder-symbolic") on a grey
/// tile, or `{ name = ..., color = "blue" }`. Null for nil. Leaves the
/// stack as it found it.
pub fn parseIcon(
    L: *lua.State,
    arena: std.mem.Allocator,
    index: c_int,
    where: []const u8,
) ?item_mod.Icon {
    const mark: lua.StackMark = .init(L);
    defer mark.expectPushed(L, 0);
    const icon = lua.absIndex(L, index);
    switch (lua.c.lua_type(L, icon)) {
        lua.c.LUA_TNIL => return null,
        lua.c.LUA_TSTRING => {
            const text = lua.toSlice(L, icon).?;
            // "~/icons/x.svg": a file in the home folder.
            const in_home = std.mem.startsWith(u8, text, "~/");
            const copy = if (in_home)
                arena.printSentinel("{s}/{s}", .{ std.mem.span(c.g_get_home_dir()), text[2..] }, 0)
            else
                arena.dupeSentinel(u8, text, 0);
            const name = copy catch lua.oom(L);
            const is_emoji = text.len > 0 and text.len <= emoji_bytes_max and text[0] >= 0x80;
            if (is_emoji) return .{ .emoji = name };
            return .byName(name);
        },
        lua.c.LUA_TTABLE => {
            const name = lua.fieldString(L, arena, icon, "name", where) orelse
                lua.raise(L, "{s}.icon.name is missing", .{where});
            const color_name = lua.fieldString(L, arena, icon, "color", where) orelse "gray";
            const color = std.meta.stringToEnum(item_mod.Color, color_name) orelse lua.raise(
                L,
                "{s}.icon.color: one of red, orange, yellow, green, blue, purple, pink, gray (got \"{s}\")",
                .{ where, color_name },
            );
            return .{ .tile = .{ .name = name, .color = color } };
        },
        else => {
            const type_name = lua.typeName(L, icon);
            lua.raise(L, "{s}.icon: string or table expected, got {s}", .{ where, type_name });
        },
    }
}
