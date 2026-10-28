//! Lua 5.4 for Lumen's extensions: the C API with the rules that keep Lua's
//! longjmp errors from breaking Zig code (lua.zig), and JSON both ways
//! (json.zig). Nothing of Lumen's in it: the extension host builds on it.

pub const lua = @import("lua.zig");
pub const json = @import("json.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
