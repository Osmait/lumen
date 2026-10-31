//! Path pieces shared by the scan, the live index, the stores and the
//! content index: the separator, how a child's path is joined to its
//! parent's, and the buffer a whole path fits in.

const std = @import("std");
const assert = std.debug.assert;

pub const separator = std.Io.Dir.path.sep;
pub const separator_str = std.Io.Dir.path.sep_str;

/// Room for any path Linux accepts (PATH_MAX, the terminating NUL
/// included). Paths that do not fit are left out where they are rebuilt.
pub const Buffer = [std.Io.Dir.max_path_bytes]u8;

comptime {
    assert(separator == '/');
    // The paths of files.idx and content.idx were bounded by this.
    assert(std.Io.Dir.max_path_bytes == 4096);
}

/// What goes between `parent` and a child's name: nothing when `parent`
/// already ends in the separator (the root "/"), else the separator.
pub fn separatorAfter(parent: []const u8) []const u8 {
    if (std.mem.endsWith(u8, parent, separator_str)) return "";
    return separator_str;
}

/// How many separators `path` has: its depth below "/".
pub fn depth(path: []const u8) usize {
    return std.mem.count(u8, path, separator_str);
}

test separatorAfter {
    try std.testing.expectEqualStrings("", separatorAfter("/"));
    try std.testing.expectEqualStrings("/", separatorAfter("/home"));
    try std.testing.expectEqual(3, depth("/home/user/notes.md"));
}
