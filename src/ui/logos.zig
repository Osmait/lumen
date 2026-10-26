//! Official language logos (Devicon, MIT: icons/devicon/LICENSE), embedded
//! in the binary and turned into textures once each. GTK reads SVG through
//! glycin, so `gdk_texture_new_from_bytes` takes the files as they are.

const std = @import("std");
const c = @import("c");
const core = @import("core");

const svgs = .{
    .{ "astro", @embedFile("icons/devicon/astro.svg") },
    .{ "bash", @embedFile("icons/devicon/bash.svg") },
    .{ "c", @embedFile("icons/devicon/c.svg") },
    .{ "clojure", @embedFile("icons/devicon/clojure.svg") },
    .{ "cmake", @embedFile("icons/devicon/cmake.svg") },
    .{ "cplusplus", @embedFile("icons/devicon/cplusplus.svg") },
    .{ "csharp", @embedFile("icons/devicon/csharp.svg") },
    .{ "css3", @embedFile("icons/devicon/css3.svg") },
    .{ "dart", @embedFile("icons/devicon/dart.svg") },
    .{ "docker", @embedFile("icons/devicon/docker.svg") },
    .{ "elixir", @embedFile("icons/devicon/elixir.svg") },
    .{ "git", @embedFile("icons/devicon/git.svg") },
    .{ "go", @embedFile("icons/devicon/go.svg") },
    .{ "gradle", @embedFile("icons/devicon/gradle.svg") },
    .{ "graphql", @embedFile("icons/devicon/graphql.svg") },
    .{ "haskell", @embedFile("icons/devicon/haskell.svg") },
    .{ "html5", @embedFile("icons/devicon/html5.svg") },
    .{ "java", @embedFile("icons/devicon/java.svg") },
    .{ "javascript", @embedFile("icons/devicon/javascript.svg") },
    .{ "json", @embedFile("icons/devicon/json.svg") },
    .{ "kotlin", @embedFile("icons/devicon/kotlin.svg") },
    .{ "latex", @embedFile("icons/devicon/latex.svg") },
    .{ "lua", @embedFile("icons/devicon/lua.svg") },
    .{ "markdown", @embedFile("icons/devicon/markdown.svg") },
    .{ "nim", @embedFile("icons/devicon/nim.svg") },
    .{ "nixos", @embedFile("icons/devicon/nixos.svg") },
    .{ "ocaml", @embedFile("icons/devicon/ocaml.svg") },
    .{ "opengl", @embedFile("icons/devicon/opengl.svg") },
    .{ "php", @embedFile("icons/devicon/php.svg") },
    .{ "powershell", @embedFile("icons/devicon/powershell.svg") },
    .{ "python", @embedFile("icons/devicon/python.svg") },
    .{ "react", @embedFile("icons/devicon/react.svg") },
    .{ "ruby", @embedFile("icons/devicon/ruby.svg") },
    .{ "rust", @embedFile("icons/devicon/rust.svg") },
    .{ "sass", @embedFile("icons/devicon/sass.svg") },
    .{ "scala", @embedFile("icons/devicon/scala.svg") },
    .{ "svelte", @embedFile("icons/devicon/svelte.svg") },
    .{ "swift", @embedFile("icons/devicon/swift.svg") },
    .{ "terraform", @embedFile("icons/devicon/terraform.svg") },
    .{ "typescript", @embedFile("icons/devicon/typescript.svg") },
    .{ "vuejs", @embedFile("icons/devicon/vuejs.svg") },
    .{ "xml", @embedFile("icons/devicon/xml.svg") },
    .{ "yaml", @embedFile("icons/devicon/yaml.svg") },
    .{ "zig", @embedFile("icons/devicon/zig.svg") },
    .{ "zsh", @embedFile("icons/devicon/zsh.svg") },
};

pub fn svg(name: []const u8) ?[]const u8 {
    inline for (svgs) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

var cache: std.StringHashMapUnmanaged(*c.GdkTexture) = .empty;

/// The logo as a texture, made on first use and kept for the process.
pub fn texture(gpa: std.mem.Allocator, name: []const u8) ?*c.GdkTexture {
    if (cache.get(name)) |t| return t;
    const data = svg(name) orelse return null;
    const bytes = c.g_bytes_new_static(data.ptr, data.len);
    defer c.g_bytes_unref(bytes);
    const t = c.gdk_texture_new_from_bytes(bytes, null) orelse return null;
    cache.put(gpa, name, t) catch {};
    return t;
}

test "every logo the mapping names is embedded" {
    for (core.file_badge.logos) |l| try std.testing.expect(svg(l[1].name) != null);
    for (core.file_badge.logo_names) |l| try std.testing.expect(svg(l[1].name) != null);
}
