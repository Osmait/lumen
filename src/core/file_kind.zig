//! File kinds for "Default Apps": the groups a person picks an app for
//! ("PDF Documents", "Images"), decided from the MIME type GLib guesses and
//! the file name. Pure: the caller does the guessing.

const std = @import("std");
const file_badge = @import("file_badge.zig");

pub const Kind = enum {
    folder,
    pdf,
    image,
    video,
    audio,
    markdown,
    html,
    text,
    office,
    archive,

    pub fn title(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .folder => "Folders",
            .pdf => "PDF Documents",
            .image => "Images",
            .video => "Videos",
            .audio => "Audio",
            .markdown => "Markdown",
            .html => "Web Pages",
            .text => "Text & Code",
            .office => "Office Documents",
            .archive => "Archives",
        };
    }

    /// A MIME type every app for this kind handles, to ask GIO for them.
    pub fn sampleMime(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .folder => "inode/directory",
            .pdf => "application/pdf",
            .image => "image/png",
            .video => "video/mp4",
            .audio => "audio/mpeg",
            .markdown => "text/markdown",
            .html => "text/html",
            .text => "text/plain",
            .office => "application/vnd.oasis.opendocument.text",
            .archive => "application/zip",
        };
    }

    pub fn icon(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .folder => "folder-symbolic",
            .pdf => "x-office-document-symbolic",
            .image => "image-x-generic-symbolic",
            .video => "video-x-generic-symbolic",
            .audio => "audio-x-generic-symbolic",
            .markdown => "text-x-generic-symbolic",
            .html => "text-html-symbolic",
            .text => "text-editor-symbolic",
            .office => "x-office-spreadsheet-symbolic",
            .archive => "package-x-generic-symbolic",
        };
    }

    /// Where to look when this kind has no app of its own: Markdown is
    /// text too.
    pub fn fallback(kind: Kind) ?Kind {
        return if (kind == .markdown) .text else null;
    }
};

/// The kind of a file, or null when it is none of the groups (then the
/// system default opens it).
/// What a path names, when the caller already knows it is a folder.
pub const Entry = enum { file, folder };

pub fn of(mime: []const u8, name: []const u8, entry: Entry) ?Kind {
    if (entry == .folder) return .folder;
    if (std.mem.eql(u8, mime, "inode/directory")) return .folder;
    if (std.mem.eql(u8, mime, "text/markdown")) return .markdown;
    if (hasExt(name, &.{ ".md", ".markdown" })) return .markdown;
    if (isAny(mime, &.{ "text/html", "application/xhtml+xml" })) return .html;
    if (std.mem.eql(u8, mime, "application/pdf")) return .pdf;
    if (std.mem.startsWith(u8, mime, "image/")) return .image;
    if (std.mem.startsWith(u8, mime, "audio/")) return .audio;
    // GLib calls some source files videos (.ts "MPEG transport stream",
    // .mts): a code badge wins over that guess.
    const code = file_badge.isKnown(name);
    if (std.mem.startsWith(u8, mime, "video/")) return if (code) .text else .video;
    if (isOffice(mime)) return .office;
    const archives = [_][]const u8{
        "application/zip",
        "application/x-tar",
        "application/gzip",
        "application/x-compressed-tar",
        "application/x-7z-compressed",
        "application/vnd.rar",
        "application/x-rar",
        "application/x-xz",
        "application/x-xz-compressed-tar",
        "application/zstd",
        "application/x-zstd-compressed-tar",
        "application/x-bzip2",
        "application/x-bzip2-compressed-tar",
    };
    if (isAny(mime, &archives)) return .archive;
    if (std.mem.startsWith(u8, mime, "text/")) return .text;
    if (code) return .text;
    const texty = [_][]const u8{
        "application/json",
        "application/xml",
        "application/x-shellscript",
        "application/javascript",
        "application/toml",
        "application/x-yaml",
        "application/yaml",
        "application/sql",
        "application/x-desktop",
    };
    if (isAny(mime, &texty)) return .text;
    return null;
}

fn isOffice(mime: []const u8) bool {
    const families = [_][]const u8{
        "application/vnd.oasis.opendocument.",
        "application/vnd.openxmlformats-officedocument.",
    };
    for (families) |family| {
        if (std.mem.startsWith(u8, mime, family)) return true;
    }
    return isAny(mime, &.{
        "application/msword",
        "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint",
        "application/rtf",
    });
}

fn isAny(mime: []const u8, mimes: []const []const u8) bool {
    for (mimes) |candidate| {
        if (std.mem.eql(u8, mime, candidate)) return true;
    }
    return false;
}

/// "log" for "server.LOG", in `buf`: null when the name has none (no dot,
/// only a leading one, a trailing one) or it is longer than `buf`.
pub fn lowerExt(buf: []u8, name: []const u8) ?[]const u8 {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return null;
    const ext = name[dot + 1 ..];
    if (dot == 0 or ext.len == 0 or ext.len > buf.len) return null;
    return std.ascii.lowerString(buf, ext);
}

/// ".log" for "server.LOG": the key an extension override is stored under
/// (lowercase, with the dot). Empty when the name has no extension.
pub fn extKey(buf: []u8, name: []const u8) []const u8 {
    if (buf.len < 2) return "";
    const ext = lowerExt(buf[1..], name) orelse return "";
    buf[0] = '.';
    return buf[0 .. 1 + ext.len];
}

fn hasExt(name: []const u8, extensions: []const []const u8) bool {
    for (extensions) |extension| {
        // The name must be more than the extension: ".md" alone is not one.
        if (name.len > extension.len and std.ascii.endsWithIgnoreCase(name, extension)) {
            return true;
        }
    }
    return false;
}

test "kinds from MIME type and name" {
    const t = std.testing;
    try t.expectEqual(Kind.folder, of("", "Projects", .folder));
    try t.expectEqual(Kind.pdf, of("application/pdf", "a.pdf", .file));
    try t.expectEqual(Kind.image, of("image/jpeg", "a.jpg", .file));
    try t.expectEqual(Kind.video, of("video/mp4", "a.mp4", .file));
    try t.expectEqual(Kind.audio, of("audio/flac", "a.flac", .file));
    try t.expectEqual(Kind.markdown, of("text/markdown", "README.md", .file));
    try t.expectEqual(Kind.markdown, of("application/octet-stream", "notes.MD", .file));
    try t.expectEqual(Kind.html, of("text/html", "index.html", .file));
    try t.expectEqual(Kind.text, of("text/plain", "a.txt", .file));
    try t.expectEqual(Kind.text, of("text/rust", "lib.rs", .file));
    try t.expectEqual(Kind.text, of("application/json", "a.json", .file));
    try t.expectEqual(Kind.office, of(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "a.docx",
        .file,
    ));
    try t.expectEqual(Kind.archive, of("application/zip", "a.zip", .file));
    // GLib's guesses for code it does not know.
    try t.expectEqual(Kind.text, of("application/octet-stream", "main.zig", .file));
    try t.expectEqual(Kind.text, of("video/mp2t", "app.ts", .file));
    try t.expectEqual(@as(?Kind, null), of("application/x-executable", "a.out", .file));
    try t.expectEqual(@as(?Kind, null), of("application/octet-stream", "firmware.bin", .file));
    try t.expectEqual(Kind.text, Kind.markdown.fallback().?);
}

test "extension keys" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings(".log", extKey(&buf, "server.LOG"));
    try std.testing.expectEqualStrings(".gz", extKey(&buf, "a.tar.gz"));
    try std.testing.expectEqualStrings("", extKey(&buf, ".bashrc"));
    try std.testing.expectEqualStrings("", extKey(&buf, "Makefile"));
    try std.testing.expectEqualStrings("", extKey(&buf, "trailing."));
}

test "lowerExt and extKey" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("log", lowerExt(&buf, "server.LOG").?);
    try std.testing.expectEqualStrings("gz", lowerExt(&buf, "a.tar.gz").?);
    for ([_][]const u8{ "README", ".bashrc", "trailing.", "x.toolongext" }) |n|
        try std.testing.expect(lowerExt(&buf, n) == null);
    try std.testing.expectEqualStrings(".log", extKey(&buf, "server.LOG"));
    try std.testing.expectEqualStrings("", extKey(&buf, ".bashrc"));
    try std.testing.expectEqualStrings("", extKey(buf[0..4], "x.abcd"));
}
