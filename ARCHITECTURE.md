# How Lumen works

Lumen is one process: a GTK4 application (`lumen-gtk`) that starts hidden
(`lumen --daemon`), keeps its indexes warm, and shows a gtk4-layer-shell
window when `lumen` is called again.

`lumen` itself is a separate, static executable without GTK or libc
(`src/client.zig`). Loading GTK4 costs a process about 40 ms (measured on
the reference machine: an empty program linked against libgtk-4 takes 41
ms, 13 of them for libGLX, which GStreamer GL pulls in), and the keyboard
shortcut used to pay that before every window. The client connects to
`$XDG_RUNTIME_DIR/lumen/<app id>.sock` (owner-only; the daemon also checks
the peer's uid), sends its arguments, prints the answer: under 1 ms. What
it cannot pass on (no daemon yet, `--daemon`, `--dmenu`, installs, unknown
flags) it hands to `lumen-gtk` with `execve`, where GApplication forwards
the command line to the running instance as before. Both paths run the
same handler in `main.zig`. The clipboard watcher runs `lumen
--clip-store` for every copy, so copies go through the socket too, into the
daemon's open database.

## Layout

```
src/main.zig      entry point: GApplication, command line, clipboard watcher
src/client.zig    `lumen`: arguments to the daemon over a socket, else lumen-gtk
src/ipc.zig       the socket's path and messages (shared by both)
src/core/         pure logic, unit tested: fuzzy matching, accent folding,
                  calculator and units, frecency, window geometry, script headers
src/index/        file index (std + Linux syscalls only): store, scan, search,
                  live updates, service; content index: content, content_list,
                  extract, ContentService
src/sys/          SQLite store (Db.zig), process spawning (GLib), hyprctl,
                  the daemon's end of the socket (ipc_server.zig)
src/providers/    apps (GIO), built-in commands, script commands
src/ext/          Lua extensions: lua.zig (the C API and its rules), Host.zig
                  (the worker thread and the registry), api.zig (the `lumen`
                  module), exec.zig, json.zig
src/ui/           the window: Ui.zig (state and flow), widgets, labels,
                  settings_view, file_results, detail_pane, backdrop, keyboard,
                  ext_view (extensions in the window), prefs_view (their
                  preferences, the input view), form_view, dmenu (lumen
                  --dmenu), installer (extensions from git), themes, the
                  stylesheet
src/actions.zig   what each action does to the system
src/settings.zig  the settings file
src/c.zig         hand-written GTK/GLib/gtk4-layer-shell bindings
```

`src/c.zig` declares only the C functions Lumen calls: Zig 0.16's
translate-c could not parse GLib's headers. Zig 0.17's can, so the bindings
could be generated now; they were kept by hand, with enum values checked
against the installed headers. SQLite and Lua go through translate-c
(`src/sqlite.h`, `src/lua.h`).

## The window

Two floating pieces on a clear layer-shell surface: the search bar and, under
it, the results, as tall as their rows. While the window shows, a clear
full-screen layer per monitor sits under it, so a click anywhere outside
hides Lumen. The selected row is filled with the theme's accent and names
what Enter does.

Themes are a handful of colours (`src/ui/themes.zig`) turned into CSS
variables in front of `style.css`. A test checks every theme's text contrast
(WCAG) and that the stylesheet uses no variable a theme does not define.

Settings live in `~/.config/lumen/settings.conf`, written atomically
(temporary file, fsync, rename) and owner-only. Lumen reads it again when its
window opens if the file's mtime (to the nanosecond), size or inode changed.
A bad value falls back to its default and an unknown key is kept as it was.

## Extensions

`src/ext/` runs `init.lua` and every `extensions/<id>/init.lua`, each in its
own Lua 5.4 state, on one worker thread (`lm-ext`). The window never waits on
Lua: it posts a request (reload, list a command's rows, run an action) and
gets the answer on the GTK main loop through `g_idle_add`, like the content
search. Answers carry a generation and the registry they were asked of; stale
ones are dropped.

What a file defines (commands, themes, keymaps) and what failed to load is a
*registry*, handed to the UI and replaced whole on reload. Rows come back as
ordinary `Item`s built on the worker, so the window draws them like any other
row. Actions that need no Lua (open, copy, paste, start a program) run in the
UI at once; the rest go back to the worker, against the list they came from.

Lua raises errors with longjmp, which skips Zig's `defer`. Lumen enters a
state only through a protected call whose frames own nothing (their memory
is an arena owned by the caller). Zig functions Lua calls return an error
union and raise only once their own frames are gone; work that must clean up
(a child process, a buffer) finishes first or runs under its own protected
call. Every state has a 64 MB allocator cap and an instruction-count hook
that stops code past its deadline. `lumen.exec` polls stdin, stdout and stderr
together until the same deadline, and waits for the exit on a pidfd.

Reloads are cheap to detect: the stat of `init.lua` and of each extension's
`.lua` files, hashed and compared when the window opens.

The tables rows come from are kept per command, one for its list and one for
its root-search rows, so their actions always run against the table they
were listed from. Root searches ask every provider in turn for the newest
query only (3 s each), and stop early once a newer query is waiting.

`lumen.preferences`, `lumen.storage` and `lumen.extension` are Lua, in a
prelude over `lumen.json` and `io`; preferences.json is written by the UI
(atomically) and the extension reloads. Forms reuse the preference fields:
the window keeps the values while the input and choose views edit them, and
`submit` gets them as a table.

Commands that need an answer later (`lumen --dmenu`, `--install`) keep a
reference to the caller's `GApplicationCommandLine`: the caller's
invocation ends, with the exit status set, when it is released. dmenu reads
stdin with GIO's async reads, so lines show as they arrive; git runs as a
`GSubprocess`, so the daemon never waits on the network.

## File index

`src/index/` keeps the names of everything under `$HOME`:

- **One buffer, same format in RAM and on disk** (struct of arrays, paths as
  name + parent id): start-up maps `~/.cache/lumen/files.idx`, then a rescan
  always runs in the background (a saved index is a photo).
- **Scan level by level** with raw `getdents64` (d_type, zero `stat`), each
  level in parallel; parents end up sorted, so children are a binary search.
- **Cascaded search**: incremental refinement → 64-bit character mask →
  greedy cheap score with a per-chunk top-K → optimal alignment (fzf-style,
  in `fine.zig`) on the finalists → recency (`statx`) on the head of the list
  only.
- **Live**: inotify watches armed in batches, deletes are a zeroed mask,
  additions go to a small delta, rescans build unlocked on half the cores and
  swap in microseconds. Events lost to an error or a queue overflow trigger a
  rescan instead.
- **Words and names**: spaces separate words (`cargo toml`), a name without
  its extension counts as exact (`readme` → `README.md`), directories named
  `*cache*` rank as noise, and after each rescan the heap copy is replaced by
  a mapping of the saved file (reclaimable page cache).

Measured on a 12-thread desktop, `$HOME` with 1.6 M entries:

| | |
|---|---|
| full scan | 353 ms (4.6 M entries/s) |
| map the saved index | 0.02 ms |
| `c` / `ca` | 3.7 / 4.1 ms |
| `cargo` / `cargo.toml` | 2.3 / 1.4 ms |
| recall vs exhaustive | 100% |

`zig build -Doptimize=ReleaseFast && zig-out/bin/lumen-find bench` measures
your machine.

## Content index

`src/index/content.zig` answers "which files contain this text" without
reading them all: ripgrep needs ~200 ms per query over a developer's home
directory (2.8 s cold) and every core.

- **What is indexed**: what `rg --files` lists under `$HOME` (honours
  `.gitignore`, skips hidden files), minus package caches and build output,
  text files up to 1 MB, plus PDFs (`pdftotext`) and docx/xlsx/pptx/odt/ods/odp
  (`unzip` + XML to text, `extract.zig`). Extracted text is cached per
  document version in `~/.cache/lumen/text/`; a document that cannot be
  extracted is remembered, a passing failure (timeout, missing tool, memory)
  is retried.
- **Format**: one mapped file (`~/.cache/lumen/content.idx`): document table
  (path, mtime, size) and segments of sorted trigram keys with varint-delta
  posting lists. Building dedups each file's trigrams with a 16M-bit map and
  radix-sorts (trigram, doc) pairs, closing a segment every 4 M pairs so
  memory stays bounded, and writes the file as segments close
  (`sys.AtomicFile`: a temporary file, the header patched in last, fsync,
  rename), so the finished index is never whole in the heap; an update
  copies the old segments from their mapping straight to the file. On 49 k
  documents the build peaked at 585 MB with 16 M-pair segments, built in
  memory and copied; it peaks at 195 MB now, with the same query times (12
  segments instead of 4, an index 8 % larger). If the cache cannot be
  written, the index is built in memory and served from there, and saving
  is retried on the next check.
- **Query**: intersect the lists of every trigram of every word (shortest
  first), then verify candidates by reading them, in parallel and in order of
  their bound: what is known without I/O (recency, depth, file name) plus the
  most reading can add. Only documents holding every trigram of the whole
  phrase (spaces included) can get the phrase bonus, so the others' bound
  leaves it out and the phrase is not looked for in them. Each thread takes
  the next candidate and offers its match to a shared top 50, whose worst
  score stops everyone once no unread candidate can beat it. "SELECT * FROM"
  read 4000 files (all it was allowed) and now reads 379: 42 → 5 ms. With several words, the exact
  phrase ranks first. Queries run on a worker thread; the newest one wins.
- **Freshness**: on start, every 5 minutes and when the window opens, the
  files are compared with the index by (path, mtime, size). Listing them
  takes ripgrep ~150 ms and ~0.45 s of CPU, so it is done only when needed:
  the name index counts names created, removed or moved outside hidden
  files and folders (idle, a home's name changes are all in .cache and
  .config), and while that count has not moved a check only stats the
  files already indexed (75 ms on one core, 49 k files), which finds edits
  in place. New files move the count, so the next check lists; it also
  lists on start, while the name index is still arming its watches or has
  folders it could not watch, and at least every 30 minutes (a .gitignore
  edited in place). Changed and new files are read and added in a segment of their own,
  the old versions and deleted files are flagged removed (queries skip
  them), and the other segments are copied as they are (`content.update`):
  two edited files cost 23 ms instead of a 1.6 s rebuild, on 49 k
  documents. Past 20 % removed or 32 segments it is rebuilt whole, which
  leaves it clean again. Either way the result is swapped in under a lock.

Measured on the same desktop: 43k files / 438 MB of text → 66 MB index, built
in 0.9 s (first run with extraction of 274 documents: ~38 s, once); queries
0.8–12 ms including verification. `zig-out/bin/lumen-find content`
reproduces it.

Every index file read from disk is validated before use (layout arithmetic is
overflow-checked, parent chains are proven to end), and fuzz tests feed them
garbage.

## Measuring

```sh
lumen --stats                      # inside the daemon: latency to painted frame
                                   # per view (p50/p95/max, search vs rows),
                                   # heap, index sizes and build times
tools/lumen-stats.sh               # + memory by kind of mapping, disk, CPU per
                                   # named thread while idle, GPU (nvidia-smi)
tools/lumen-stats.sh --scenario    # + drives the window (every view, x3) and
                                   # measures CPU and GPU during it
```

Threads are named (`lm-search-N`, `lm-scan-N`, `lm-files`, `lm-content`) so
CPU can be attributed. Latency is measured to GdkFrameClock's `after-paint`,
so it includes GTK's layout and drawing, not only the search.

What the measurements changed (12 threads, 1.06 M files and 43 k text
documents indexed):

| | before | after | what fixed it |
|---|---|---|---|
| RSS / private | 396 / 128 MB | 113 / 49 MB | fixed `M_MMAP_THRESHOLD` (glibc's dynamic threshold kept 133 MB of freed buffers), 4 malloc arenas, `malloc_trim` after rebuilds |
| peak RSS | 704 MB | 245 MB | same |
| CPU, 13 s of typing | 6.9 s | 2.35 s | content verification below |
| contents, search p50 | 106 ms | 5 ms | SIMD case-insensitive scan, stop counting at 10 hits, tight early-stop bound, map extracted texts instead of reading them |
| contents, key to frame p50 | 131 ms | 18 ms | previews clip long lines instead of wrapping |
| files, key to frame p50 | 73 ms | 23 ms | preview capped at 40 lines, no wrapping |
| CPU idle | 0 % | 0 % | nothing polls: inotify and futex waits |
| anonymous memory | 44 MB | 37 MB | glibc's malloc in release builds (Zig 0.17's ReleaseSafe default is a checking allocator mapping every allocation of 6 KB or more, so the tuning above did not apply), no 256 KB signal stack in each of 31 threads' TLS |
| disk writes, idle | ~1 GB/h | — | the name index rescanned every 10 minutes whenever caches changed (always); now only on start |
| key press to window (p50) | 58.5 ms | 7.8 ms | `lumen` without GTK: 42.8 ms of client became 0.9 ms (Hyprland's `openlayer` event, 15 runs); the focused monitor read from Hyprland's socket instead of starting `hyprctl` (daemon's show 16.3 → 6.8 ms) |
| files view, key to frame (p50) | 23.5 ms | 12 ms | only the first 14 rows are built with the keystroke's frame (the list shows ~8); the rest after it, a few per idle callback, dropped by the next keystroke. GTK laid out all 61 rows (~430 widgets) per key |
| contents view, key to frame (p50) | 15 ms | 11 ms | the same, and a keystroke that only asks the worker no longer rebuilds the rows of the previous result |
| image preview | ~100 ms on the UI thread per keystroke (24 MP photo) | off the UI thread | decoded on a GTask thread, not again for the same file |
| first show after start | ~175 ms | ~27 ms | the window's surface and Vulkan renderer created, the root view built and the full-screen backdrops made, while hidden right after start |
| GPU | | ~10 MiB VRAM while shown, none hidden | |

## Edge cases

Search ignores accents and case in all three searches (apps, file names,
file contents): "accion" finds "acción", "español" finds `espanol.txt`,
"ÑANDÚ" finds "ñandú" (`core/fold.zig` folds Latin-1 and Latin Extended-A
letters to their base; symbols like `×` stay distinct). Also handled, each
with a test:

- an indexed file replaced by a FIFO or device: opened non-blocking and
  checked to be regular (a blocking open of a FIFO froze the launcher)
- file names that are invalid UTF-8 or contain newlines: shown with U+FFFD /
  a space, searchable by content (`rg --null`), actions use the raw path
- caches and indexes are owner-only (0700 / 0600) and written atomically
- the clipboard watcher is restarted with backoff if it dies
- pasting into a terminal sends Ctrl+Shift+V
- file-name queries up to 255 bytes; a hung mount cannot block the content
  listing for more than a minute
- corrupt index files are rejected and rebuilt, never trusted
- a failed database write (clearing the history, deleting an entry) is shown
  on the row, not silently ignored
- client commands (`--stats`, `--dump`, `--quit`...) never start a daemon;
  test instances quit by themselves after five minutes

## Tests

```sh
zig build test      # unit and integration tests (index on real temp trees,
                    # inotify, extraction with real zip/pdftotext, SQLite)
zig build perf      # performance regressions on synthetic data (1M names,
                    # 3k documents): latency limits, exact recall, peak RSS;
                    # PERF_SCALE=2 relaxes the limits on slower machines
zig build e2e       # end-to-end: an isolated instance (own app id, fake $HOME,
                    # own caches) driven with --dump and --key; needs Wayland
```

The end-to-end runner (`tools/e2e.sh`) checks every view, the keyboard, the
action panel, live file changes, the clipboard store and latency, then quits
the instance and checks the indexes were saved. `lumen --dump` prints what
the window shows (rows, selection, detail, panel) and `lumen --key NAME`
presses a key, so the UI is tested without screenshots.

Fuzz tests (index files, calculator, Office XML, case-insensitive search) run
on their seed corpus as part of `zig build test`. Exploring with `--fuzz`
builds with Zig 0.17.0 but does not run yet: the test runner's input poller
panics (`start index 1 is larger than end index 0`) in every worker as soon
as fuzzing starts, in std, not in Lumen's targets. Under 0.16, with a patched
lib dir and `use_llvm = true`, 3.5M + 4.9M iterations found nothing.
