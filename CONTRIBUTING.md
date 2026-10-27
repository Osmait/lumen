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
zig build e2e       # end-to-end, needs a Wayland session
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
