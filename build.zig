//! Modules:
//!
//!   core   pure logic (fuzzy, calculator, frecency, layouts, script headers)
//!   index  file index: scan, mmap store, cascaded search, inotify (std + core)
//!   c      hand-written GLib/GIO/GTK4/gtk4-layer-shell bindings
//!   sqlite SQLite through translate-c
//!   main   the daemon: providers, actions and the window -> core, c, sqlite

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
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

    // Zig 0.16's translate-c cannot parse GLib's headers, so GTK & co. are
    // declared by hand in src/c.zig.
    const c_mod = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for ([_][]const u8{ "gtk4", "gtk4-layer-shell-0", "gio-unix-2.0" }) |lib| c_mod.linkSystemLibrary(lib, .{});

    const sqlite = b.addTranslateC(.{
        .root_source_file = b.path("src/sqlite.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite.linkSystemLibrary("sqlite3", .{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("core", core);
    mod.addImport("index", index);
    mod.addImport("c", c_mod);
    mod.addImport("sqlite", sqlite.createModule());

    const exe = b.addExecutable(.{ .name = "lumen", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run lumen").dependOn(&run.step);

    // `lumen-find`: the file index from the command line, and its numbers.
    const find_mod = b.createModule(.{
        .root_source_file = b.path("src/index/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    find_mod.addImport("index", index);
    b.installArtifact(b.addExecutable(.{ .name = "lumen-find", .root_module = find_mod }));

    // Performance regression checks, always optimized: `zig build perf`.
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/index/perf.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const perf_index = b.createModule(.{
        .root_source_file = b.path("src/index/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    perf_index.addImport("core", b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    perf_mod.addImport("index", perf_index);
    const perf_run = b.addRunArtifact(b.addExecutable(.{ .name = "lumen-perf", .root_module = perf_mod }));
    perf_run.has_side_effects = true;
    b.step("perf", "Performance regression checks (PERF_SCALE=2 to relax)").dependOn(&perf_run.step);

    // End-to-end: an isolated instance driven through --dump/--key. Needs a
    // Wayland session; the window shows for a few seconds.
    const e2e_run = b.addSystemCommand(&.{ "bash", "tools/e2e.sh" });
    e2e_run.addArtifactArg(exe);
    e2e_run.has_side_effects = true;
    b.step("e2e", "End-to-end tests against an isolated instance").dependOn(&e2e_run.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ core, index, mod }) |m| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}
