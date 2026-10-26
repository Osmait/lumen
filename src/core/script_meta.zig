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

pub const Mode = enum { silent, compact, fullOutput, inline_, unknown };

pub const Meta = struct {
    title: []const u8 = "",
    mode: Mode = .silent,
    icon: []const u8 = "",
    package_name: []const u8 = "",
    description: []const u8 = "",
    needs_confirmation: bool = false,
};

/// Parses the header of `source`. Slices point into `source`. Returns null if
/// there is no title (not a script command).
pub fn parse(source: []const u8) ?Meta {
    var meta: Meta = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| : (n += 1) {
        if (n > 40) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        const body = stripComment(line) orelse continue;
        const key_start = if (std.mem.startsWith(u8, body, "@raycast."))
            "@raycast.".len
        else if (std.mem.startsWith(u8, body, "@lumen."))
            "@lumen.".len
        else
            continue;
        const rest = body[key_start..];
        const sp = std.mem.indexOfAny(u8, rest, " \t") orelse continue;
        const key = rest[0..sp];
        const value = std.mem.trim(u8, rest[sp..], " \t");

        if (std.mem.eql(u8, key, "title")) meta.title = value else if (std.mem.eql(u8, key, "mode")) {
            meta.mode = if (std.mem.eql(u8, value, "silent")) .silent else if (std.mem.eql(u8, value, "compact")) .compact else if (std.mem.eql(u8, value, "fullOutput")) .fullOutput else if (std.mem.eql(u8, value, "inline")) .inline_ else .unknown;
        } else if (std.mem.eql(u8, key, "icon")) meta.icon = value else if (std.mem.eql(u8, key, "packageName")) meta.package_name = value else if (std.mem.eql(u8, key, "description")) meta.description = value else if (std.mem.eql(u8, key, "needsConfirmation")) meta.needs_confirmation = std.mem.eql(u8, value, "true");
    }
    if (meta.title.len == 0) return null;
    return meta;
}

/// The text after a `#`, `//` or `--` comment marker.
fn stripComment(line: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "#", "//", "--" };
    for (markers) |m| {
        if (std.mem.startsWith(u8, line, m)) {
            if (std.mem.startsWith(u8, line, "#!")) return null;
            return std.mem.trim(u8, line[m.len..], " \t");
        }
    }
    return null;
}

test "header" {
    const src =
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
    const m = parse(src).?;
    try std.testing.expectEqualStrings("Restart Waybar", m.title);
    try std.testing.expectEqual(Mode.compact, m.mode);
    try std.testing.expectEqualStrings("🔄", m.icon);
    try std.testing.expectEqualStrings("System", m.package_name);
}

test "@raycast keys and other comment styles" {
    const src =
        \\#!/usr/bin/env node
        \\// @raycast.title Say Hi
        \\// @raycast.needsConfirmation true
    ;
    const m = parse(src).?;
    try std.testing.expectEqualStrings("Say Hi", m.title);
    try std.testing.expect(m.needs_confirmation);
}

test "no title, no command" {
    try std.testing.expect(parse("#!/bin/sh\necho hi\n") == null);
}
