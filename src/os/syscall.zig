//! What the other files of `os` share: a raw syscall result turned into
//! `Error`, and closing a descriptor.

const linux = @import("std").os.linux;

pub const Error = error{
    Syscall,
    NotFound,
    Access,
    NotRegular,
    NameTooLong,
    /// A symbolic link where none is followed (O_NOFOLLOW): refused, not
    /// an I/O error.
    IsLink,
    /// The disk or the user's quota is full.
    NoSpace,
};

/// The result of a raw syscall, or the `Error` its errno stands for.
pub fn check(result: usize) Error!usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        .NOENT, .NOTDIR => error.NotFound,
        .ACCES, .PERM => error.Access,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP => error.IsLink,
        .NOSPC, .DQUOT => error.NoSpace,
        else => error.Syscall,
    };
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}
