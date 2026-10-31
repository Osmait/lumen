//! Script commands: executable files whose header comments describe them,
//! like:
//!
//!   #!/bin/bash
//!   # @lumen.schemaVersion 1
//!   # @lumen.title Restart Waybar
//!   # @lumen.mode silent
//!   # @lumen.icon 🔄
//!   # @lumen.packageName System
//!
//! `@raycast.*` keys are accepted too, the same format, so script commands
//! written for other launchers work unchanged. Only the header (the first
//! lines) is read.

const std = @import("std");

pub const Mode = enum { silent, compact, full_output, @"inline", unknown };

pub const Meta = struct {
    title: []const u8 = "",
    mode: Mode = .silent,
    icon: []const u8 = "",
    package_name: []const u8 = "",
    description: []const u8 = "",
    needs_confirmation: bool = false,
};

/// Only the header is metadata: lines past this many are not read.
const header_lines_max = 40;

/// The keys Lumen reads, spelled as in the header. Others
/// (`schemaVersion`, `argument1`...) are ignored.
const Key = enum { title, mode, icon, packageName, description, needsConfirmation };

/// Parses the header of `source`. Slices point into `source`. Returns null if
/// there is no title (not a script command).
pub fn parse(source: []const u8) ?Meta {
    var meta: Meta = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_index: usize = 0;
    while (lines.next()) |line_raw| : (line_index += 1) {
        if (line_index > header_lines_max) break;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        const comment = stripComment(line) orelse continue;
        const entry = stripPrefix(comment) orelse continue;
        const key_end = std.mem.findAny(u8, entry, " \t") orelse continue;
        const key = std.meta.stringToEnum(Key, entry[0..key_end]) orelse continue;
        const value = std.mem.trim(u8, entry[key_end..], " \t");
        switch (key) {
            .title => meta.title = value,
            .mode => meta.mode = parseMode(value),
            .icon => meta.icon = value,
            .packageName => meta.package_name = value,
            .description => meta.description = value,
            .needsConfirmation => meta.needs_confirmation = parseFlag(value),
        }
    }
    if (meta.title.len == 0) return null;
    return meta;
}

/// The entry after `@lumen.` or `@raycast.`, or null on any other comment.
fn stripPrefix(comment: []const u8) ?[]const u8 {
    for ([_][]const u8{ "@lumen.", "@raycast." }) |prefix| {
        if (std.mem.startsWith(u8, comment, prefix)) return comment[prefix.len..];
    }
    return null;
}

/// Modes as headers spell them: Raycast's camelCase, not the enum's names.
const modes_by_name: std.StaticStringMap(Mode) = .initComptime(.{
    .{ "silent", .silent },
    .{ "compact", .compact },
    .{ "fullOutput", .full_output },
    .{ "inline", .@"inline" },
});

fn parseMode(value: []const u8) Mode {
    return modes_by_name.get(value) orelse .unknown;
}

/// A header flag is on only when written `true`, as Raycast reads it.
fn parseFlag(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

/// The text after a `#`, `//` or `--` comment marker; null for the shebang
/// and for lines that are not comments.
fn stripComment(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "#!")) return null;
    for ([_][]const u8{ "#", "//", "--" }) |marker| {
        if (std.mem.startsWith(u8, line, marker)) {
            return std.mem.trim(u8, line[marker.len..], " \t");
        }
    }
    return null;
}

test "header" {
    const source =
        \\#!/bin/bash
        \\
        \\# Required parameters:
        \\# @lumen.schemaVersion 1
        \\# @lumen.title Restart Waybar
        \\# @lumen.mode compact
        \\
        \\# Optional parameters:
        \\# @lumen.icon 🔄
        \\# @lumen.packageName System
        \\
        \\pkill waybar; waybar &
    ;
    const meta = parse(source).?;
    try std.testing.expectEqualStrings("Restart Waybar", meta.title);
    try std.testing.expectEqual(Mode.compact, meta.mode);
    try std.testing.expectEqualStrings("🔄", meta.icon);
    try std.testing.expectEqualStrings("System", meta.package_name);
}

test "@raycast keys and other comment styles" {
    const source =
        \\#!/usr/bin/env node
        \\// @raycast.title Say Hi
        \\// @raycast.needsConfirmation true
    ;
    const meta = parse(source).?;
    try std.testing.expectEqualStrings("Say Hi", meta.title);
    try std.testing.expect(meta.needs_confirmation);
}

test "no title, no command" {
    try std.testing.expect(parse("#!/bin/sh\necho hi\n") == null);
}

test "every mode, and modes and keys that are not known" {
    const cases = [_]struct { text: []const u8, mode: Mode }{
        .{ .text = "silent", .mode = .silent },
        .{ .text = "compact", .mode = .compact },
        .{ .text = "fullOutput", .mode = .full_output },
        .{ .text = "inline", .mode = .@"inline" },
        .{ .text = "full_output", .mode = .unknown },
        .{ .text = "loud", .mode = .unknown },
    };
    for (cases) |case| try std.testing.expectEqual(case.mode, parseMode(case.text));

    const source =
        \\# @lumen.title T
        \\# @lumen.schemaVersion 1
        \\-- @lumen.description What it does
        \\# @other.icon x
    ;
    const meta = parse(source).?;
    try std.testing.expectEqualStrings("What it does", meta.description);
    try std.testing.expectEqualStrings("", meta.icon);
}
