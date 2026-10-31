//! Content index: which documents contain which trigrams, like plocate and
//! Google's Code Search. For *names* trigrams were measured and
//! dropped (no help for 1-2 letters, useless for fuzzy matches, 3x the
//! memory). Text inside files is the opposite case: people search exact
//! fragments of 3+ characters, and scanning 1 GB per keystroke with ripgrep
//! costs ~200 ms on every core. Here a query reads a few posting lists and
//! then verifies a few hundred candidates.
//!
//! One file, mapped like `files.idx`:
//!
//!   header | docs (mtime, size, path offset and length, kind, flags) | paths |
//!   segments: sorted trigram keys, offsets, posting lists (varint deltas) |
//!   segment directory
//!
//! A few changed files do not rebuild it (`update`): their old versions are
//! flagged removed and skipped by queries, the new ones are appended with
//! new ids in a segment of their own. The service rebuilds it whole once
//! removed documents or segments pile up.
//!
//! Segments keep the build's memory bounded: pairs (trigram, doc) are
//! collected for a run of documents, radix-sorted, encoded, dropped. Doc ids
//! are global and increase across segments, so a trigram's full list is its
//! lists in segment order.
//!
//! This file is the module's public face; the work is in, as data flows:
//!
//!   content_build.zig    documents read in rounds into (trigram, doc) pairs:
//!                        build, update, append
//!   content_write.zig    the bytes laid out: doc table, segments, directory
//!   content_format.zig   the layout both sides share, trigrams, posting lists
//!   ContentIndex.zig     an index file, validated on open; a query's
//!                        candidates
//!   content_search.zig   a query: candidates ranked, verified in parallel
//!   content_find.zig     the folded (SIMD) substring search verifying runs
//!
//! `ContentService.zig` keeps an index current in the background and serves
//! queries from it.

const content_format = @import("content_format.zig");
const content_build = @import("content_build.zig");
const content_search = @import("content_search.zig");
const content_find = @import("content_find.zig");

// Documents.
pub const DocIn = content_format.DocIn;
pub const Source = content_format.Source;
pub const path_bytes_max = content_format.path_bytes_max;
pub const trigram_chars = content_format.trigram_chars;

// Building.
pub const text_bytes_max = content_build.text_bytes_max;
pub const extracted_bytes_max = content_build.extracted_bytes_max;
pub const TextFn = content_build.TextFn;
pub const TextReader = content_build.TextReader;
pub const readPlain = content_build.readPlain;
pub const BuildStats = content_build.BuildStats;
pub const BuildError = content_build.BuildError;
pub const FileError = content_build.FileError;
pub const build = content_build.build;
pub const buildFile = content_build.buildFile;
pub const update = content_build.update;
pub const updateFile = content_build.updateFile;
pub const appendFile = content_build.appendFile;

// Reading.
pub const Index = @import("ContentIndex.zig");

// Searching.
pub const Match = content_search.Match;
pub const SearchOptions = content_search.SearchOptions;
pub const PathFn = content_search.PathFn;
pub const plainPath = content_search.plainPath;
pub const splitWords = content_search.splitWords;
pub const search = content_search.search;
pub const Verified = content_search.Verified;
pub const verify = content_search.verify;
pub const count_cap = content_search.count_cap;
pub const candidates_verified_max = content_search.candidates_verified_max;
pub const Span = content_find.Span;
pub const findFold = content_find.findFold;
pub const findCI = content_find.findCI;

test {
    _ = content_format;
    _ = content_build;
    _ = @import("content_write.zig");
    _ = Index;
    _ = content_search;
    _ = content_find;
}
