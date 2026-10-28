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

    const sqlite = b.addTranslateC(.{
        .root_source_file = b.path("src/sqlite.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite.linkSystemLibrary("sqlite3", .{});

    // Lua 5.4's pkg-config name differs between distributions: lua5.4 on
    // Arch and Debian, lua on Fedora.
    const lua_pkg = b.option(
        []const u8,
        "lua-pkg",
        "pkg-config name of Lua 5.4 (default lua5.4)",
    ) orelse "lua5.4";
    const lua = b.addTranslateC(.{
        .root_source_file = b.path("src/lua.h"),
        .target = target,
        .optimize = optimize,
    });
    lua.linkSystemLibrary(lua_pkg, .{});

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
    mod.addImport("sqlite", sqlite.createModule());
    const luart = b.createModule(.{
        .root_source_file = b.path("src/luart/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    luart.addImport("lua", lua.createModule());
    luart.addImport("os", os);
    mod.addImport("luart", luart);
    // The styles in examples/styles, built in (Change Theme > Styles).
    mod.addImport("styles", b.createModule(.{
        .root_source_file = b.path("examples/styles/styles.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const exe = b.addExecutable(.{ .name = "lumen-gtk", .root_module = mod });
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
