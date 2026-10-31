//! File index: names under $HOME, scanned in parallel, searched fuzzily and
//! kept live with inotify. The README has the measurements behind it.

pub const store = @import("store.zig");
pub const scan = @import("scan.zig");
pub const search = @import("search.zig");
pub const fine = @import("fine.zig");
pub const Pool = @import("Pool.zig");
pub const Watcher = @import("Watcher.zig");
pub const Live = @import("Live.zig");
pub const Service = @import("Service.zig");
pub const content = @import("content.zig");
pub const content_list = @import("content_list.zig");
pub const extract = @import("extract.zig");
pub const format = @import("format.zig");
pub const recency = @import("recency.zig");
pub const paths = @import("paths.zig");
pub const ContentService = @import("ContentService.zig");

extern fn malloc_trim(pad: usize) c_int;

/// Hands freed heap back to the kernel. glibc keeps freed blocks for reuse;
/// after a rebuild (hundreds of MB of temporary pairs) that is memory the
/// daemon would otherwise sit on until it exits.
pub fn trimHeap() void {
    _ = malloc_trim(0);
}

test {
    @import("std").testing.refAllDecls(@This());
}
