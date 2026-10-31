# Contributing to Lumen

Thanks for wanting to help. Bug reports, ideas and pull requests are all
welcome.

## Reporting a bug

Open an issue with:

- what you did, what you expected and what happened;
- your distribution, compositor (and its version) and `lumen --stats` output
  if Lumen is running;
- the log, if there is one: run `lumen --quit`, then `lumen --daemon` from a
  terminal and reproduce.

Please check that screenshots and logs show nothing private (file names,
clipboard contents).

Security issues go through [SECURITY.md](SECURITY.md) instead.

## Building

You need [Zig 0.17](https://ziglang.org/download/) and the libraries listed
in the [README](README.md#requirements).

```sh
zig build                       # debug build in zig-out/bin
zig build -Doptimize=ReleaseSafe
zig build run -- --daemon       # run it (arguments after --)
```

To try a build without disturbing the Lumen you use every day, give it its
own app id and data folders:

```sh
LUMEN_APP_ID=dev.example.LumenDev XDG_CACHE_HOME=/tmp/lumen-dev/cache \
  XDG_DATA_HOME=/tmp/lumen-dev/data zig-out/bin/lumen --daemon
LUMEN_APP_ID=dev.example.LumenDev zig-out/bin/lumen
```

## Testing

```sh
zig build test      # unit and integration tests
zig build perf      # performance regressions (PERF_SCALE=2 on slower machines)
zig build e2e       # end-to-end, needs a Wayland session with the monitors on
zig fmt --check src build.zig
```

`zig build e2e` starts an isolated instance (its own app id, a fake `$HOME`
and caches) and drives it with `lumen --dump` and `lumen --key`; its window
shows on screen for a few seconds. Please run it for any change to the UI.

New behaviour comes with a test next to the code it tests. A fix comes with
the test that would have caught it.

## Code style

Lumen follows the conventions of the Zig standard library:

- `zig fmt`; TitleCase types, camelCase functions, snake_case everything else.
  A file with top-level fields is a type (`Db.zig`, `const Db = @This();`),
  any other file a snake_case namespace.
- Allocators are passed in (`gpa`, or `arena` when the result lives in one);
  containers start from `.empty`. Public functions that return memory say who
  owns it.
- Public functions name their error sets. Errors are handled where it makes
  sense and logged otherwise: no `catch {}` on anything that loses data.
  `errdefer` goes right after each acquisition.
- Each module that logs has its own `std.log.scoped`; errors print with `{t}`.
- No deprecated std APIs.
- Data read from disk or from other programs is validated before it is
  trusted; casts on it are checked.
- Comments say why, not what. Doc comments state preconditions, ownership
  and thread-safety.

On top of that, some rules from TigerBeetle's
[TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
where they fit a desktop program:

- **Assert invariants that would otherwise break silently**, both where data
  is written and where it is read: rows follow their items, a function Lua
  calls returns no more values than it pushed, the content index writes what
  its validation accepts. Not as a quota per function.
- **Validate at the boundary.** `core` and `index` are compiled ReleaseFast
  even in a ReleaseSafe build, so their assertions and overflow checks are
  gone there: data from disk, Hyprland or the database is checked where it
  comes in (`findMonitor`, `Index.validate`), and arithmetic on it
  saturates.
- **Put a limit on every loop fed from outside**: bytes read from a socket,
  reads and connections per turn of the main loop, lines from stdin, Lua
  instructions and memory. A deadline covers the whole operation, not each
  call.
- **Units in names**: `_ns`, `_ms`, `_s`, `_bytes`, `_entries`.
- **Functions of up to about 70 lines.** A longer one is split along the
  phases it already has. Tables and switches over data (the settings rows,
  the command-line flags) are exempt, and so is a hot loop that was
  measured.
- **Lines of up to 100 columns**: a trailing comma makes `zig fmt` break a
  call or initializer, the long last argument first. String literals, the
  rows of a table and test names may run over.
- **Handle every error** (see above); a bind or a write that can fail is
  checked, never discarded.
- **Prefer one copy**: when the same lines appear a third time, they become
  a function where they belong (`os` for Linux calls, `core` for pure logic,
  `luart` for Lua). Two copies that only look alike (the fuzzy scorers, the
  two tombstone walks) stay apart.

The rules above can be counted; the ones that make TigerBeetle's code easy
to read cannot, so they are spelled out too:

- **No abbreviations.** A name says what the thing is: `arena`, `query`,
  `item`, `row_index`, `host`, `width_px`, not `a`, `q`, `it`, `ri`, `h`,
  `w`. The same letter used to mean up to four things depending on the
  file. Allowed: `i` and `j` as indexes in short loops, the primitive
  arguments of a sort or a hot loop, and `L` for a `lua_State` (the Lua C
  API's own convention). Words that recur keep one name everywhere:
  `gpa` and `arena` for allocators, `query` for the typed text,
  `*_generation` for generation counters, `*_count` for counts.
- **Qualifiers go last**, most significant word first: `items_max`,
  `results_max`, `latency_ns_max`, not `max_items`. Related names then
  line up and sort together.
- **Braces on an `if` unless it fits on one line.** When `zig fmt` would
  have to break the body (`if (bad) lua.raise(` and the arguments on four
  more lines), the body goes in braces; when it would break the condition,
  the condition gets a named local first. The 100-column rule is met with
  names, not by breaking calls apart.
- **Callbacks are named after their caller**: `read` and `read_callback`,
  `list` and `list_callback`, so the call history reads off the names.
  Arguments that can be mixed up (two integers, several booleans) go in an
  options struct.
- **Order inside a type**: fields, then nested types, then functions. A
  nested type that is long becomes a top-level one (or a file).
- **Comments are sentences**, with a subject and a full stop: "An
  optional value is taken only if the next argument is not a flag.", not
  "Not the next flag.". A doc comment sits on the declaration it
  describes.
- **On-disk formats are `extern struct`s** with `comptime` assertions on
  their size and offsets, never byte offsets spelled as numbers. What a
  reader validates, the writer asserts.
- **Assert what a function assumes**: the preconditions of a public
  function, the invariant between two fields that move together, the
  relation between two constants (`comptime assert`). Split compound
  assertions (`assert(a); assert(b);`) so a failure says which one.

Not adopted, on purpose: static allocation (a launcher's working set
depends on what is on disk), a ban on recursion (the calculator and the
markdown spans are bounded, and the bounds are asserted), `u32` everywhere,
a fixed number of assertions per function, and snake_case file names (Zig
names a file after the type it is).

UI text is in English, short and specific: rows say what they do ("Open
Application"), errors say what failed ("Could not clear the history").

## Pull requests

- One change per pull request, with a short description of what and why.
- Commit messages: a short summary line (`area: what changed`), a blank line,
  then the why in plain sentences.
- The CI must pass (`zig build test`, `zig fmt --check`). If your change
  touches the UI, say that `zig build e2e` passed locally, and add a
  screenshot.

By contributing you agree that your contribution is licensed under the MIT
license of the project.
