//! Pure logic, no GTK and no system calls: testable on its own.

pub const fuzzy = @import("fuzzy.zig");
pub const fold = @import("fold.zig");
pub const calc = @import("calc.zig");
pub const frecency = @import("frecency.zig");
pub const script_meta = @import("script_meta.zig");
pub const geometry = @import("geometry.zig");
pub const file_badge = @import("file_badge.zig");
pub const file_kind = @import("file_kind.zig");
pub const markdown = @import("markdown.zig");
pub const utf8 = @import("utf8.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
