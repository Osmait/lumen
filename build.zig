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
    // The bundled C libraries (SQLite, Lua) are built optimized in a
    // ReleaseSafe build: their checks are their own. Lumen's modules keep
    // Zig's safety checks in every safe build, core and index included:
    // without them an assertion or a bound broken by a corrupt index file
    // was undefined behaviour instead of a panic. They cost ~25% on the
    // name search and the fuzzy scorer's hot loops (MYP-189 measured it;
    // the earlier "no difference" came from a `perf` built ReleaseFast).
    const c_optimize: std.builtin.OptimizeMode = if (optimize == .safe) .fast else optimize;

    // The version both binaries print (`lumen --version`).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", resolveVersion(b));
    build_options.addOption(
        bool,
        "checked_alloc",
        b.option(bool, "checked-alloc", "Use Zig's checking allocator in release builds") orelse false,
    );

    const base = baseModules(b, target, optimize);
    const c_options = CLibrariesOptions.fromCommandLine(b);
    const libraries = cLibraries(b, .{
        .target = target,
        .optimize = optimize,
        .hot = c_optimize,
        .options = c_options,
    });
    const luart = luartModule(b, target, optimize, libraries.lua, base.os);
    const daemon = daemonModule(b, .{
        .target = target,
        .optimize = optimize,
        .base = base,
        .sqlite = libraries.sqlite,
        .luart = luart,
        .build_options = build_options,
    });
    const executable = daemonExecutable(b, target, optimize, daemon);
    const client = clientModule(b, target, optimize, build_options);
    toolSteps(b, .{
        .target = target,
        .optimize = optimize,
        .executable = executable,
        .base = base,
        .c_options = c_options,
    });

    const test_step = b.step("test", "Run unit tests");
    const tested = [_]*std.Build.Module{ base.core, base.os, base.index, luart, daemon, client };
    for (tested) |module| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
}

const BaseModules = struct {
    core: *std.Build.Module,
    os: *std.Build.Module,
    index: *std.Build.Module,
};

/// core, os and index, compiled in `optimize` (the program's, or always
/// optimized for the performance checks).
fn baseModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) BaseModules {
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

/// Lua for extensions (src/luart), over `lua` (`cLibraries`).
fn luartModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lua: *std.Build.Module,
    os: *std.Build.Module,
) *std.Build.Module {
    const luart = b.createModule(.{
        .root_source_file = b.path("src/luart/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    luart.addImport("lua", lua);
    luart.addImport("os", os);
    return luart;
}

const CLibraries = struct { sqlite: *std.Build.Module, lua: *std.Build.Module };

/// Where SQLite and Lua come from, read once from the command line: the
/// app and `zig build perf` each build their own.
const CLibrariesOptions = struct {
    system_libraries: bool,
    lua_package: []const u8,

    fn fromCommandLine(b: *std.Build) CLibrariesOptions {
        return .{
            // SQLite and Lua are built in, so a release binary does not
            // depend on how each distribution names Lua 5.4
            // (liblua5.4.so.5.4 on Arch, liblua5.4.so.0 on Debian, gone from
            // Fedora for 5.5). Packagers who want the system's: -Dsystem-libs.
            .system_libraries = b.option(
                bool,
                "system-libs",
                "Link the system's SQLite and Lua 5.4 instead of the bundled ones",
            ) orelse false,
            // Lua 5.4's pkg-config name differs between distributions:
            // lua5.4 on Arch and Debian, lua on Fedora.
            .lua_package = b.option(
                []const u8,
                "lua-pkg",
                "With -Dsystem-libs: pkg-config name of Lua 5.4 (default lua5.4)",
            ) orelse "lua5.4",
        };
    }
};

/// SQLite and Lua through translate-c, with their libraries: built in from
/// build.zig.zon's sources (in `hot` mode), or the system's.
fn cLibraries(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    hot: std.builtin.OptimizeMode,
    options: CLibrariesOptions,
}) CLibraries {
    const target = options.target;
    const optimize = options.optimize;
    const hot = options.hot;
    const system_libraries = options.options.system_libraries;
    const lua_package = options.options.lua_package;
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
    // System libraries are linked to the translation before its module is
    // made, because the module takes them when it is created.
    if (system_libraries) {
        sqlite.linkSystemLibrary("sqlite3", .{});
        lua.linkSystemLibrary(lua_package, .{});
    }
    const libraries: CLibraries = .{ .sqlite = sqlite.createModule(), .lua = lua.createModule() };
    const luart_c = luartCLibrary(b, target, optimize, hot);
    libraries.lua.linkLibrary(luart_c);
    if (system_libraries) {
        luart_c.root_module.linkSystemLibrary(lua_package, .{});
        return libraries;
    }

    const sqlite_source = b.dependency("sqlite", .{});
    sqlite.addIncludePath(sqlite_source.path(""));
    libraries.sqlite.linkLibrary(cLibrary(b, .{
        .target = target,
        .optimize = hot,
        .name = "sqlite3",
        .root = sqlite_source.path(""),
        .files = &.{"sqlite3.c"},
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    }));
    const lua_source = b.dependency("lua", .{});
    lua.addIncludePath(lua_source.path("src"));
    libraries.lua.addIncludePath(lua_source.path("src"));
    luart_c.root_module.addIncludePath(lua_source.path("src"));
    libraries.lua.linkLibrary(cLibrary(b, .{
        .target = target,
        .optimize = hot,
        .name = "lua",
        .root = lua_source.path("src"),
        .files = &lua_sources,
        .flags = &.{ "-DLUA_USE_LINUX", "-DLUA_COMPAT_5_3" },
    }));
    return libraries;
}

/// Lumen's C beside Lua: pattern matching with deadline checks (the
/// extensions' string.find/match/gmatch/gsub, lstrmatch.c) and io.open /
/// io.tmpfile close-on-exec and counted per state (lfiles.c). Public API
/// only, so it builds against the system's Lua as well as the bundled one;
/// compiled with UBSan in Debug/tests and without UBSan in optimized builds
/// (`hot`), where UBSan made patterns 23-39% slower than Lua's own (MYP-186).
fn luartCLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    hot: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return cLibrary(b, .{
        .target = target,
        .optimize = hot,
        .name = "luart_c",
        .root = b.path("src/luart"),
        .files = &.{ "lstrmatch.c", "lfiles.c" },
        .flags = &.{"-DLUA_COMPAT_5_3"},
        .sanitize_c = if (optimize == .debug) .full else .off,
    });
}

/// The daemon's root module (src/main.zig) with everything it imports.
fn daemonModule(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    base: BaseModules,
    sqlite: *std.Build.Module,
    luart: *std.Build.Module,
    build_options: *std.Build.Step.Options,
}) *std.Build.Module {
    // GTK & co. are declared by hand in src/c.zig: Zig 0.16's translate-c
    // could not parse GLib's headers (0.17's can, so this could move).
    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    for ([_][]const u8{ "gtk4", "gtk4-layer-shell-0", "gio-unix-2.0" }) |library| {
        c_module.linkSystemLibrary(library, .{});
    }

    const daemon = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    daemon.addImport("core", options.base.core);
    daemon.addImport("os", options.base.os);
    daemon.addImport("index", options.base.index);
    daemon.addImport("c", c_module);
    daemon.addImport("sqlite", options.sqlite);
    daemon.addImport("luart", options.luart);
    daemon.addOptions("build_options", options.build_options);
    // The styles in examples/styles, built in (Change Theme > Styles).
    daemon.addImport("styles", b.createModule(.{
        .root_source_file = b.path("examples/styles/styles.zig"),
        .target = options.target,
        .optimize = options.optimize,
    }));
    return daemon;
}

/// lumen-gtk, installed.
fn daemonExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    daemon: *std.Build.Module,
) *std.Build.Step.Compile {
    // LLD links only the libraries used (--as-needed) in release builds: Zig's
    // own linker also records every one pkg-config lists for GTK (vulkan,
    // harfbuzz, graphene...), which a binary meant for other systems must not
    // ask for. Zig 0.17's self-hosted Debug backend does not support LLD, so
    // Debug uses Zig's default linker.
    const executable = b.addExecutable(.{
        .name = "lumen-gtk",
        .root_module = daemon,
        .use_lld = if (optimize != .debug) true else null,
    });
    // Built for an older glibc (a release, -Dtarget=x86_64-linux-gnu.2.36),
    // it links against this machine's GTK, built for a newer one; where it
    // runs, the libraries are that system's own.
    if (!target.query.isNative()) executable.linker_allow_shlib_undefined = true;
    b.installArtifact(executable);
    return executable;
}

/// `lumen`, what the shortcut runs, installed. Loading GTK costs a process
/// ~40 ms, so the client reaches the daemon over the socket without it.
fn clientModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
) *std.Build.Module {
    const client = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        .strip = optimize != .debug,
    });
    client.addOptions("build_options", build_options);
    // An os module of its own, so the client keeps its build mode and stays
    // libc-free.
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
    return client;
}

/// `zig build run`, `perf` and `e2e`, and the lumen-find tool.
fn toolSteps(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    executable: *std.Build.Step.Compile,
    base: BaseModules,
    c_options: CLibrariesOptions,
}) void {
    const run = b.addRunArtifact(options.executable);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run lumen").dependOn(&run.step);

    // `lumen-find`: the file index from the command line, and its numbers.
    const find = b.createModule(.{
        .root_source_file = b.path("src/index/bench.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    find.addImport("index", options.base.index);
    find.addImport("os", options.base.os);
    b.installArtifact(b.addExecutable(.{ .name = "lumen-find", .root_module = find }));

    // Performance regression checks: `zig build perf`. Built as a release
    // is, whatever -Doptimize says: Lumen's modules ReleaseSafe, the C
    // libraries optimized. Built ReleaseFast, it measured code that never
    // ships and missed what safety checks cost (MYP-189).
    const perf = b.createModule(.{
        .root_source_file = b.path("src/index/perf.zig"),
        .target = options.target,
        .optimize = .safe,
        .link_libc = true,
    });
    const perf_base = baseModules(b, options.target, .safe);
    const perf_libraries = cLibraries(b, .{
        .target = options.target,
        .optimize = .safe,
        .hot = .fast,
        .options = options.c_options,
    });
    perf.addImport("index", perf_base.index);
    perf.addImport("os", perf_base.os);
    perf.addImport("core", perf_base.core);
    perf.addImport(
        "luart",
        luartModule(b, options.target, .safe, perf_libraries.lua, perf_base.os),
    );
    const perf_run = b.addRunArtifact(b.addExecutable(.{
        .name = "lumen-perf",
        .root_module = perf,
    }));
    perf_run.has_side_effects = true;
    b.step(
        "perf",
        "Performance regression checks (PERF_SCALE=2 to relax)",
    ).dependOn(&perf_run.step);

    // End-to-end: an isolated instance driven through --dump/--key, with
    // `lumen` as installed and lumen-gtk beside it. It needs a Wayland
    // session, and the window shows for a few seconds. The binary is the
    // one just installed, under --prefix too (zig-out may hold an older one).
    const e2e_run = b.addSystemCommand(&.{ "bash", "tools/e2e.sh" });
    e2e_run.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "lumen" } });
    e2e_run.step.dependOn(b.getInstallStep());
    e2e_run.has_side_effects = true;
    b.step("e2e", "End-to-end tests against an isolated instance").dependOn(&e2e_run.step);
}

/// build.zig.zon's version, made precise by git between releases: "0.2.0-dev"
/// 14 commits after the v0.1.0 tag is "0.2.0-dev.14+a1b2c3d4e". A release is
/// built from its tag, whose name must be "v" and that version. Without git
/// (a source tarball) it is the zon's as it is; -Dversion-string overrides.
fn resolveVersion(b: *std.Build) []const u8 {
    const version_override = b.option(
        []const u8,
        "version-string",
        "Version to report (builds without git)",
    );
    if (version_override) |version| return version;
    const base: []const u8 = @import("build.zig.zon").version;
    var exit_code: u8 = 0;
    const root = b.root.toString(b.graph.arena) catch @panic("OOM");
    const described_output = b.runAllowFail(&.{
        "git",      "-C",     root,
        "describe", "--tags", "--match",
        "v*.*.*",   "--long", "--abbrev=9",
    }, &exit_code, .ignore) catch return base;
    // For example "v0.1.0-14-ga1b2c3d4e": the tag, the commits since, the hash.
    const described = std.mem.trim(u8, described_output, " \r\n");
    var parts = std.mem.splitBackwardsScalar(u8, described, '-');
    const hash = parts.next() orelse return base;
    const commits = parts.next() orelse return base;
    const tag = parts.rest();
    if (hash.len < 2 or hash[0] != 'g' or tag.len < 2) return base;
    const is_dev = std.mem.endsWith(u8, base, "-dev");
    if (std.mem.eql(u8, commits, "0") and !is_dev) {
        if (!std.mem.eql(u8, tag[1..], base)) {
            std.process.fatal("tag {s} does not match build.zig.zon's version {s}", .{ tag, base });
        }
        return base;
    }
    if (is_dev) return b.fmt("{s}.{s}+{s}", .{ base, commits, hash[1..] });
    return b.fmt("{s}+{s}.{s}", .{ base, commits, hash[1..] });
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

/// A static library of C sources. Third-party dependencies keep UBSan off and
/// compile optimized (Debug becomes ReleaseSafe), while Lumen's own C sources
/// can opt into `sanitize_c = .full` in Debug/tests.
fn cLibrary(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root: std.Build.LazyPath,
    files: []const []const u8,
    flags: []const []const u8,
    sanitize_c: std.zig.SanitizeC = .off,
}) *std.Build.Step.Compile {
    const library = b.addLibrary(.{
        .name = options.name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = if (options.optimize == .debug and options.sanitize_c == .off)
                .safe
            else
                options.optimize,
            .link_libc = true,
            .sanitize_c = options.sanitize_c,
        }),
    });
    library.root_module.addCSourceFiles(.{
        .root = options.root,
        .files = options.files,
        .flags = options.flags,
    });
    return library;
}
