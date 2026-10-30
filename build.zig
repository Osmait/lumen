//! Modules:
//!
//!   core   pure logic (fuzzy, calculator, frecency, layouts, script headers)
//!   os     the Linux calls made directly: files, time, sockets, children
//!          (std only, no libc: the client uses it too)
//!   index  file index: scan, mmap store, cascaded search, inotify
//!          -> core, os
//!   c      hand-written GLib/GIO/GTK4/gtk4-layer-shell bindings
//!   sqlite SQLite through translate-c
//!   lua    Lua 5.4 through translate-c
//!   luart  Lua for extensions: the C API with longjmp-safe rules, JSON
//!          -> lua, os
//!   main   the daemon: providers, actions, extensions and the window
//!          -> core, os, index, c, sqlite, luart (the lumen-gtk executable)
//!   client `lumen`, what the shortcut runs: passes its arguments to the
//!          daemon over a socket, or runs lumen-gtk (no GTK, no libc)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The search loops (fuzzy and folded matching, trigram lists, the
    // content scan) are 10-25 % faster without safety checks (lumen-find,
    // measured). The index validates what it maps from disk on open, and its
    // decoders never read past their input, so a ReleaseSafe build compiles
    // these two modules ReleaseFast; the rest keeps its checks.
    const safe_index = b.option(
        bool,
        "safe-index",
        "Keep safety checks in the core and index modules in ReleaseSafe",
    ) orelse false;
    const hot = if (optimize == .safe and !safe_index) .fast else optimize;

    // The version both binaries print (`lumen --version`).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", resolveVersion(b));

    const base = baseModules(b, target, hot);
    const core = base.core;
    const os = base.os;
    const index = base.index;

    // GTK & co. are declared by hand in src/c.zig: Zig 0.16's translate-c
    // could not parse GLib's headers (0.17's can, so this could move).
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for ([_][]const u8{
        "gtk4",
        "gtk4-layer-shell-0",
        "gio-unix-2.0",
    }) |lib| c_mod.linkSystemLibrary(lib, .{});

    // SQLite and Lua are built in, so a release binary does not depend on
    // how each distribution names Lua 5.4 (liblua5.4.so.5.4 on Arch,
    // liblua5.4.so.0 on Debian, gone from Fedora for 5.5). Packagers who
    // want the system's: -Dsystem-libs.
    const system_libs = b.option(
        bool,
        "system-libs",
        "Link the system's SQLite and Lua 5.4 instead of the bundled ones",
    ) orelse false;
    // Lua 5.4's pkg-config name differs between distributions: lua5.4 on
    // Arch and Debian, lua on Fedora.
    const lua_pkg = b.option(
        []const u8,
        "lua-pkg",
        "With -Dsystem-libs: pkg-config name of Lua 5.4 (default lua5.4)",
    ) orelse "lua5.4";
    const sqlite = b.addTranslateC(.{
        .root_source_file = b.path("src/sqlite.h"),
        .target = target,
        .optimize = optimize,
    });
    const lua = b.addTranslateC(.{
        .root_source_file = b.path("src/lua.h"),
        .target = target,
        .optimize = optimize,
    });
    // What distributions build Lua with: extensions may use 5.3's names.
    lua.defineCMacro("LUA_COMPAT_5_3", null);
    // Linked to the translation before its module is made: the module
    // takes the translation's system libraries when it is created.
    if (system_libs) {
        sqlite.linkSystemLibrary("sqlite3", .{});
        lua.linkSystemLibrary(lua_pkg, .{});
    }
    const sqlite_mod = sqlite.createModule();
    const lua_mod = lua.createModule();
    if (!system_libs) {
        const sqlite_src = b.dependency("sqlite", .{});
        sqlite.addIncludePath(sqlite_src.path(""));
        sqlite_mod.linkLibrary(cLibrary(b, target, hot, "sqlite3", sqlite_src.path(""), &.{"sqlite3.c"}, &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
        }));
        const lua_src = b.dependency("lua", .{});
        lua.addIncludePath(lua_src.path("src"));
        lua_mod.linkLibrary(cLibrary(b, target, hot, "lua", lua_src.path("src"), &lua_sources, &.{
            "-DLUA_USE_LINUX",
            "-DLUA_COMPAT_5_3",
        }));
    }

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("core", core);
    mod.addImport("os", os);
    mod.addImport("index", index);
    mod.addImport("c", c_mod);
    mod.addImport("sqlite", sqlite_mod);
    const luart = b.createModule(.{
        .root_source_file = b.path("src/luart/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    luart.addImport("lua", lua_mod);
    luart.addImport("os", os);
    mod.addImport("luart", luart);
    // The styles in examples/styles, built in (Change Theme > Styles).
    mod.addOptions("build_options", build_options);
    mod.addImport("styles", b.createModule(.{
        .root_source_file = b.path("examples/styles/styles.zig"),
        .target = target,
        .optimize = optimize,
    }));

    // LLD links only the libraries used (--as-needed): Zig's own linker
    // also records every one pkg-config lists for GTK (vulkan, harfbuzz,
    // graphene...), which a binary meant for other systems must not ask for.
    const exe = b.addExecutable(.{ .name = "lumen-gtk", .root_module = mod, .use_lld = true });
    // Built for an older glibc (a release, -Dtarget=x86_64-linux-gnu.2.36),
    // it links against this machine's GTK, built for a newer one; where it
    // runs, the libraries are that system's own.
    if (!target.query.isNative()) exe.linker_allow_shlib_undefined = true;
    b.installArtifact(exe);

    // Loading GTK costs a process ~40 ms; the shortcut runs this instead.
    const client = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .strip = optimize != .debug,
    });
    // Its own instance: the client keeps its build mode and stays libc-free.
    client.addOptions("build_options", build_options);
    client.addImport("os", b.createModule(.{
        .root_source_file = b.path("src/os/root.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.installArtifact(b.addExecutable(.{
        .name = "lumen",
        .root_module = client,
        .linkage = .static,
    }));

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run lumen").dependOn(&run.step);

    // `lumen-find`: the file index from the command line, and its numbers.
    const find_mod = b.createModule(.{
        .root_source_file = b.path("src/index/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    find_mod.addImport("index", index);
    find_mod.addImport("os", os);
    b.installArtifact(b.addExecutable(.{ .name = "lumen-find", .root_module = find_mod }));

    // Performance regression checks, always optimized: `zig build perf`.
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/index/perf.zig"),
        .target = target,
        .optimize = .fast,
        .link_libc = true,
    });
    const perf_base = baseModules(b, target, .fast);
    perf_mod.addImport("index", perf_base.index);
    perf_mod.addImport("os", perf_base.os);
    const perf_run = b.addRunArtifact(b.addExecutable(.{
        .name = "lumen-perf",
        .root_module = perf_mod,
    }));
    perf_run.has_side_effects = true;
    b.step(
        "perf",
        "Performance regression checks (PERF_SCALE=2 to relax)",
    ).dependOn(&perf_run.step);

    // End-to-end: an isolated instance driven through --dump/--key. Needs a
    // Wayland session; the window shows for a few seconds.
    // `lumen` as installed, with lumen-gtk beside it.
    const e2e_run = b.addSystemCommand(&.{ "bash", "tools/e2e.sh" });
    e2e_run.addArg("zig-out/bin/lumen");
    e2e_run.step.dependOn(b.getInstallStep());
    e2e_run.has_side_effects = true;
    b.step("e2e", "End-to-end tests against an isolated instance").dependOn(&e2e_run.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ core, os, index, luart, mod, client }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}

/// core, os and index, compiled in `optimize` (the program's, or always
/// optimized for the performance checks).
fn baseModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) struct { core: *std.Build.Module, os: *std.Build.Module, index: *std.Build.Module } {
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const os = b.createModule(.{
        .root_source_file = b.path("src/os/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const index = b.createModule(.{
        .root_source_file = b.path("src/index/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Accent and case folding (core.fold) is shared by every search.
    index.addImport("core", core);
    index.addImport("os", os);
    return .{ .core = core, .os = os, .index = index };
}

/// build.zig.zon's version, made precise by git between releases: "0.2.0-dev"
/// 14 commits after the v0.1.0 tag is "0.2.0-dev.14+a1b2c3d4e". A release is
/// built from its tag, whose name must be "v" and that version. Without git
/// (a source tarball) it is the zon's as it is; -Dversion-string overrides.
fn resolveVersion(b: *std.Build) []const u8 {
    if (b.option([]const u8, "version-string", "Version to report (builds without git)")) |v| return v;
    const base: []const u8 = @import("build.zig.zon").version;
    var code: u8 = 0;
    const root = b.root.toString(b.graph.arena) catch @panic("OOM");
    const out = b.runAllowFail(&.{
        "git",      "-C",     root,
        "describe", "--tags", "--match",
        "v*.*.*",   "--long", "--abbrev=9",
    }, &code, .ignore) catch return base;
    // v0.1.0-14-ga1b2c3d4e
    const described = std.mem.trim(u8, out, " \r\n");
    var parts = std.mem.splitBackwardsScalar(u8, described, '-');
    const hash = parts.next() orelse return base;
    const commits = parts.next() orelse return base;
    const tag = parts.rest();
    if (hash.len < 2 or hash[0] != 'g' or tag.len < 2) return base;
    const dev = std.mem.endsWith(u8, base, "-dev");
    if (std.mem.eql(u8, commits, "0") and !dev) {
        if (!std.mem.eql(u8, tag[1..], base))
            std.process.fatal("tag {s} does not match build.zig.zon's version {s}", .{ tag, base });
        return base;
    }
    return if (dev)
        b.fmt("{s}.{s}+{s}", .{ base, commits, hash[1..] })
    else
        b.fmt("{s}+{s}.{s}", .{ base, commits, hash[1..] });
}

/// Lua 5.4's library: everything in src/ but the two programs.
const lua_sources = [_][]const u8{
    "lapi.c",     "lcode.c",    "lctype.c",  "ldebug.c",   "ldo.c",      "ldump.c",
    "lfunc.c",    "lgc.c",      "llex.c",    "lmem.c",     "lobject.c",  "lopcodes.c",
    "lparser.c",  "lstate.c",   "lstring.c", "ltable.c",   "ltm.c",      "lundump.c",
    "lvm.c",      "lzio.c",     "lauxlib.c", "lbaselib.c", "lcorolib.c", "ldblib.c",
    "liolib.c",   "lmathlib.c", "loadlib.c", "loslib.c",   "lstrlib.c",  "ltablib.c",
    "lutf8lib.c", "linit.c",
};

/// A static library of C sources from a dependency. Their own code: built
/// optimized and without Zig's C sanitizer, as their makefiles do.
fn cLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root: std.Build.LazyPath,
    files: []const []const u8,
    flags: []const []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = if (optimize == .debug) .safe else optimize,
            .link_libc = true,
            .sanitize_c = .off,
        }),
    });
    lib.root_module.addCSourceFiles(.{ .root = root, .files = files, .flags = flags });
    return lib;
}
