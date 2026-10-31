//! File-type badges: the extension written on a coloured tile ("GO" on cyan,
//! "ZIG" on orange), as editors show files. Icon themes do this
//! badly for source code (a generic page, or "?" for types GLib does not
//! know, like .zig), while for images, PDFs, office documents and archives
//! their icons say more than letters, so those get no badge.

const std = @import("std");
const lowerExt = @import("file_kind.zig").lowerExt;

pub const Color = enum { cyan, blue, yellow, orange, red, green, purple, pink, brown, gray };

pub const Badge = struct {
    /// Up to 4 uppercase characters.
    text: []const u8,
    color: Color,
};

const known = [_]struct { []const u8, Color }{
    // Programming languages.
    .{ "go", .cyan },       .{ "zig", .orange },   .{ "rs", .brown },     .{ "ts", .blue },
    .{ "tsx", .blue },      .{ "mts", .blue },     .{ "cts", .blue },     .{ "js", .yellow },
    .{ "jsx", .yellow },    .{ "mjs", .yellow },   .{ "cjs", .yellow },   .{ "py", .blue },
    .{ "c", .purple },      .{ "h", .purple },     .{ "cc", .purple },    .{ "cpp", .purple },
    .{ "hpp", .purple },    .{ "cxx", .purple },   .{ "java", .red },     .{ "kt", .purple },
    .{ "swift", .orange },  .{ "rb", .red },       .{ "php", .purple },   .{ "cs", .green },
    .{ "lua", .blue },      .{ "dart", .cyan },    .{ "ex", .purple },    .{ "exs", .purple },
    .{ "hs", .purple },     .{ "ml", .orange },    .{ "scala", .red },    .{ "clj", .green },
    .{ "nim", .yellow },    .{ "odin", .blue },    .{ "v", .blue },       .{ "sql", .yellow },
    .{ "glsl", .green },    .{ "wgsl", .green },   .{ "sh", .green },     .{ "bash", .green },
    .{ "zsh", .green },     .{ "fish", .green },   .{ "ps1", .blue },     .{ "vue", .green },
    .{ "svelte", .orange }, .{ "astro", .orange },
    // Web pages, their styles and other markup.
    .{ "html", .orange },  .{ "htm", .orange },
    .{ "css", .blue },      .{ "scss", .pink },    .{ "sass", .pink },    .{ "less", .blue },
    .{ "xml", .orange },    .{ "svg", .yellow },
    // Data and configuration.
      .{ "json", .yellow },  .{ "jsonc", .yellow },
    .{ "yaml", .red },      .{ "yml", .red },      .{ "toml", .gray },    .{ "ini", .gray },
    .{ "conf", .gray },     .{ "cfg", .gray },     .{ "env", .yellow },   .{ "csv", .green },
    .{ "tsv", .green },     .{ "proto", .blue },   .{ "graphql", .pink }, .{ "gql", .pink },
    .{ "lock", .gray },     .{ "zon", .orange },   .{ "nix", .blue },     .{ "tf", .purple },
    .{ "mk", .gray },       .{ "cmake", .green },  .{ "gradle", .cyan },  .{ "dockerfile", .blue },
    // Prose.
    .{ "md", .gray },       .{ "mdx", .gray },     .{ "txt", .gray },     .{ "rst", .gray },
    .{ "org", .green },     .{ "tex", .green },    .{ "log", .gray },     .{ "diff", .green },
    .{ "patch", .green },
};

/// Better shown with the theme's icon than with letters.
const themed = [_][]const u8{
    "png", "jpg", "jpeg", "gif",   "webp",    "bmp",      "ico",  "tif",   "tiff", "avif", "heic",
    "mp4", "mkv", "webm", "mov",   "avi",     "mp3",      "ogg",  "flac",  "wav",  "m4a",  "opus",
    "pdf", "doc", "docx", "xls",   "xlsx",    "ppt",      "pptx", "odt",   "ods",  "odp",  "epub",
    "zip", "gz",  "xz",   "zst",   "bz2",     "tar",      "7z",   "rar",   "deb",  "rpm",  "iso",
    "ttf", "otf", "woff", "woff2", "desktop", "appimage", "exe",  "blend",
};

/// Files named for their role rather than an extension.
const named = [_]struct { []const u8, []const u8, Color }{
    .{ "Makefile", "MAKE", .gray },        .{ "makefile", "MAKE", .gray },
    .{ "Dockerfile", "DOCK", .blue },      .{ "Containerfile", "DOCK", .blue },
    .{ "CMakeLists.txt", "CMAK", .green }, .{ "justfile", "JUST", .gray },
    .{ "LICENSE", "LIC", .gray },          .{ ".gitignore", "GIT", .red },
    .{ ".env", "ENV", .yellow },
};

/// Badge for a file name, or null when the theme icon fits better (media,
/// documents, archives, no extension at all). Unknown short extensions get a
/// gray badge: still more telling than a blank page.
pub fn of(name: []const u8, text_buffer: *[4]u8) ?Badge {
    for (named) |entry| {
        const file_name, const text, const color = entry;
        if (std.mem.eql(u8, name, file_name)) return .{ .text = text, .color = color };
    }
    var extension_buffer: [16]u8 = undefined;
    const lower = lowerExt(&extension_buffer, name) orelse return null;
    const extension = name[name.len - lower.len ..];
    for (themed) |themed_extension| {
        if (std.mem.eql(u8, lower, themed_extension)) return null;
    }
    const color = knownColor(lower);
    if (color == null and extension.len > text_buffer.len) return null;
    // Only letters and digits make a badge: "tar.gz~" or "c++" do not.
    for (extension[0..@min(extension.len, text_buffer.len)]) |char| {
        if (!std.ascii.isAlphanumeric(char)) return null;
    }
    const text_len = @min(extension.len, text_buffer.len);
    _ = std.ascii.upperString(text_buffer[0..text_len], extension[0..text_len]);
    return .{ .text = text_buffer[0..text_len], .color = color orelse .gray };
}

fn knownColor(lower_extension: []const u8) ?Color {
    for (known) |entry| {
        const known_extension, const color = entry;
        if (std.mem.eql(u8, lower_extension, known_extension)) return color;
    }
    return null;
}

/// A language or text format Lumen knows by name, not merely a short
/// extension (those get a gray badge but may be anything, binaries too).
pub fn isKnown(name: []const u8) bool {
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return true;
    }
    var extension_buffer: [16]u8 = undefined;
    const lower = lowerExt(&extension_buffer, name) orelse return false;
    return knownColor(lower) != null;
}

test "languages get their colour and short uppercase text" {
    var text_buffer: [4]u8 = undefined;
    const badge = of("handler_test.go", &text_buffer).?;
    try std.testing.expectEqualStrings("GO", badge.text);
    try std.testing.expectEqual(Color.cyan, badge.color);
    try std.testing.expectEqualStrings("ZIG", of("Ui.zig", &text_buffer).?.text);
    try std.testing.expectEqualStrings("JSON", of("package.JSON", &text_buffer).?.text);
    try std.testing.expectEqualStrings("SWIF", of("App.swift", &text_buffer).?.text);
}

test "themed types, odd names and no extension get no badge" {
    var text_buffer: [4]u8 = undefined;
    try std.testing.expect(of("photo.PNG", &text_buffer) == null);
    try std.testing.expect(of("book.pdf", &text_buffer) == null);
    try std.testing.expect(of("README", &text_buffer) == null);
    try std.testing.expect(of(".bashrc", &text_buffer) == null);
    try std.testing.expect(of("data.verylongext", &text_buffer) == null);
    try std.testing.expectEqualStrings("MAKE", of("Makefile", &text_buffer).?.text);
    // Unknown but short: gray.
    try std.testing.expectEqual(Color.gray, of("notes.foo", &text_buffer).?.color);
}

// ------------------------------------------------------------------ logos

/// A language's official logo (Devicon), when it has one.
pub const Logo = struct {
    /// Devicon name; the SVG is src/ui/icons/devicon/<name>.svg.
    name: []const u8,
    /// Dark logo (black or navy): shown on a light plate to stay visible on
    /// Lumen's dark panel without altering its colours.
    on_light: bool = false,
};

pub const logos = [_]struct { []const u8, Logo }{
    .{ "go", .{ .name = "go" } },                         .{ "zig", .{ .name = "zig" } },
    .{ "zon", .{ .name = "zig" } },
    .{ "rs", .{
        .name = "rust",
        .on_light = true,
    } },
    .{ "ts", .{ .name = "typescript" } },                 .{ "mts", .{ .name = "typescript" } },
    .{ "cts", .{ .name = "typescript" } },                .{ "tsx", .{ .name = "react" } },
    .{ "jsx", .{ .name = "react" } },                     .{ "js", .{ .name = "javascript" } },
    .{ "mjs", .{ .name = "javascript" } },                .{ "cjs", .{ .name = "javascript" } },
    .{ "py", .{ .name = "python" } },                     .{ "c", .{ .name = "c" } },
    .{ "h", .{ .name = "c" } },                           .{ "cpp", .{ .name = "cplusplus" } },
    .{ "cc", .{ .name = "cplusplus" } },                  .{ "cxx", .{ .name = "cplusplus" } },
    .{ "hpp", .{ .name = "cplusplus" } },                 .{ "java", .{ .name = "java" } },
    .{ "kt", .{ .name = "kotlin" } },                     .{ "swift", .{ .name = "swift" } },
    .{ "rb", .{ .name = "ruby" } },                       .{ "php", .{ .name = "php" } },
    .{ "cs", .{ .name = "csharp" } },
    .{ "lua", .{
        .name = "lua",
        .on_light = true,
    } },
    .{ "dart", .{ .name = "dart" } },                     .{ "ex", .{ .name = "elixir" } },
    .{ "exs", .{ .name = "elixir" } },                    .{ "hs", .{ .name = "haskell" } },
    .{ "ml", .{ .name = "ocaml" } },                      .{ "scala", .{ .name = "scala" } },
    .{ "clj", .{ .name = "clojure" } },                   .{ "nim", .{ .name = "nim" } },
    .{ "sh", .{ .name = "bash", .on_light = true } },
    .{ "bash", .{
        .name = "bash",
        .on_light = true,
    } },
    .{ "zsh", .{ .name = "zsh", .on_light = true } },     .{ "ps1", .{ .name = "powershell" } },
    .{ "vue", .{ .name = "vuejs" } },                     .{ "svelte", .{ .name = "svelte" } },
    .{ "astro", .{ .name = "astro", .on_light = true } }, .{ "html", .{ .name = "html5" } },
    .{ "htm", .{ .name = "html5" } },                     .{ "css", .{ .name = "css3" } },
    .{ "scss", .{ .name = "sass" } },                     .{ "sass", .{ .name = "sass" } },
    .{ "xml", .{ .name = "xml" } },                       .{ "json", .{ .name = "json" } },
    .{ "jsonc", .{ .name = "json" } },
    .{ "yaml", .{
        .name = "yaml",
        .on_light = true,
    } },
    .{ "yml", .{ .name = "yaml", .on_light = true } },
    .{ "md", .{
        .name = "markdown",
        .on_light = true,
    } },
    .{ "mdx", .{
        .name = "markdown",
        .on_light = true,
    } },
    .{ "tex", .{ .name = "latex", .on_light = true } },   .{ "graphql", .{ .name = "graphql" } },
    .{ "gql", .{ .name = "graphql" } },                   .{ "nix", .{ .name = "nixos" } },
    .{ "tf", .{ .name = "terraform" } },                  .{ "cmake", .{ .name = "cmake" } },
    .{ "gradle", .{
        .name = "gradle",
        .on_light = true,
    } },
    .{ "glsl", .{ .name = "opengl" } },                   .{ "dockerfile", .{ .name = "docker" } },
};

pub const logo_names = [_]struct { []const u8, Logo }{
    .{ "Dockerfile", .{ .name = "docker" } },    .{ "Containerfile", .{ .name = "docker" } },
    .{ "CMakeLists.txt", .{ .name = "cmake" } }, .{ ".gitignore", .{ .name = "git" } },
    .{ ".gitattributes", .{ .name = "git" } },   .{ ".gitmodules", .{ .name = "git" } },
};

/// The official logo for a file name, or null (then `of` gives a badge).
pub fn logoOf(name: []const u8) ?Logo {
    for (logo_names) |entry| {
        const file_name, const logo = entry;
        if (std.mem.eql(u8, name, file_name)) return logo;
    }
    var extension_buffer: [16]u8 = undefined;
    const lower = lowerExt(&extension_buffer, name) orelse return null;
    for (logos) |entry| {
        const logo_extension, const logo = entry;
        if (std.mem.eql(u8, lower, logo_extension)) return logo;
    }
    return null;
}

test "logos for languages, badges stay for the rest" {
    try std.testing.expectEqualStrings("go", logoOf("main_test.go").?.name);
    try std.testing.expectEqualStrings("typescript", logoOf("vitest.config.mts").?.name);
    try std.testing.expect(logoOf("lib.rs").?.on_light);
    try std.testing.expectEqualStrings("docker", logoOf("Dockerfile").?.name);
    try std.testing.expect(logoOf("Cargo.toml") == null);
    try std.testing.expect(logoOf("photo.png") == null);
}
