//! The Linux calls Lumen makes itself, straight through `std.os.linux`. No
//! libc, so the static `lumen` client uses it too.
//!
//! Callers see one namespace (`os.openDir`, `os.monotonicNs`); the code is
//! grouped by topic, one file each:
//!
//! - `syscall.zig`: a raw result checked into `Error`; closing a descriptor.
//! - `stat.zig`: what a path is (kind, size, mtime) and whether it changed.
//! - `folder.zig`: folders read straight from getdents64, made, owner-only.
//! - `file.zig`: regular files read and written whole, replaced atomically,
//!   grown in place, mapped.
//! - `mounts.zig`: mount points whose file system can hang a `stat`.
//! - `time.zig`: clocks and sleeping.
//! - `wait.zig`: waiting on a descriptor or for a child to exit.
//! - `unix.zig`: Unix sockets, reads and writes with a deadline.
//! - `child.zig`: programs run to a deadline, fed stdin, output collected.
//! - `test_dir.zig`: temporary folders for tests.

const syscall = @import("syscall.zig");
const stat = @import("stat.zig");
const folder = @import("folder.zig");
const file = @import("file.zig");
const mounts = @import("mounts.zig");
const time = @import("time.zig");
const wait = @import("wait.zig");
const test_dir = @import("test_dir.zig");

pub const unix = @import("unix.zig");
pub const child = @import("child.zig");

pub const Error = syscall.Error;
pub const close = syscall.close;

pub const Stamp = stat.Stamp;
pub const Kind = stat.Kind;
pub const kindOf = stat.kindOf;
pub const isRegular = stat.isRegular;
pub const exists = stat.exists;
pub const mtime = stat.mtime;
pub const Info = stat.Info;
pub const info = stat.info;

pub const openDir = folder.openDir;
pub const openDirNoFollow = folder.openDirNoFollow;
pub const DirIter = folder.DirIter;
pub const subdirs = folder.subdirs;
pub const mkdirP = folder.mkdirP;
pub const makePrivate = folder.makePrivate;

pub const openRegular = file.openRegular;
pub const readHead = file.readHead;
pub const ReadUpToError = file.ReadUpToError;
pub const readUpTo = file.readUpTo;
pub const writeFile = file.writeFile;
pub const writeAll = file.writeAll;
pub const writeAllAt = file.writeAllAt;
pub const rename = file.rename;
pub const writeFileAtomic = file.writeFileAtomic;
pub const AtomicFile = file.AtomicFile;
pub const AppendFile = file.AppendFile;
pub const mapping_alignment_bytes = file.mapping_alignment_bytes;
pub const MappedBytes = file.MappedBytes;
pub const mapPrivate = file.mapPrivate;
pub const unmap = file.unmap;

pub const slowMounts = mounts.slowMounts;
pub const freeList = mounts.freeList;

pub const nowSeconds = time.nowSeconds;
pub const monotonicNs = time.monotonicNs;
pub const sleepUs = time.sleepUs;

pub const waitExit = wait.waitExit;
pub const waitEvents = wait.waitEvents;
pub const waitReadable = wait.waitReadable;

pub const TestDir = test_dir.TestDir;
pub const tmpDirAbs = test_dir.tmpDirAbs;
pub const tmpDirPath = test_dir.tmpDirPath;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    // Each topic file, so that its tests run too.
    std.testing.refAllDecls(syscall);
    std.testing.refAllDecls(stat);
    std.testing.refAllDecls(folder);
    std.testing.refAllDecls(file);
    std.testing.refAllDecls(mounts);
    std.testing.refAllDecls(time);
    std.testing.refAllDecls(wait);
    std.testing.refAllDecls(test_dir);
}
