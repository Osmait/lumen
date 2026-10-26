# Lumen

A fast, native launcher for Linux (Wayland/Hyprland), written in Zig with
GTK4 and gtk4-layer-shell: apps, calculator, clipboard history, file and
file-content search, windows, window management, system commands and script
commands, behind one keystroke.

## Features

| | |
|---|---|
| **Apps** | every `.desktop` app, fuzzy search (word starts and runs), ranked by frecency |
| **Calculator** | `2+3*4`, `(1+2)^3`, `sqrt(16)`, `5!`, `20% of 80`, `0xff`; units: `10 km to mi`, `100 f in c`, `5 gb to mb`, `90 min in h` |
| **Clipboard History** | text copies stored in SQLite (password-manager copies skipped), detail pane, paste into the previous app |
| **Search Files** | all of `$HOME` indexed and kept live with inotify; fuzzy, multi-word (`cargo toml`), previews of images and text; open, show in folder, copy path/file, trash |
| **Search File Contents** | text inside ~43k files (code, notes, docs, PDFs, Office) through a trigram index; phrase-aware ranking, context preview with highlights, open the editor at the matching line |
| **Search Windows** | every Hyprland window with its app icon; switch or close |
| **Window Management** | halves, thirds, maximize, almost maximize, center, floating, fullscreen, pin, next display / workspace |
| **System** | lock, sleep, restart, shut down, log out, volume, mic, media keys, dark mode, empty trash |
| **Script Commands** | executables in `~/.config/lumen/scripts` described by `# @lumen.title`-style header comments (`@raycast.*` keys work too) |
| **Settings** | theme, text size, opacity, window position, files in the main search, suggestions, clipboard history on/off and size, terminal, editor for Open at Line |
| **Themes** | 13 built in (Lumen Dark/Light, Catppuccin Mocha/Latte, Dracula, Nord, Gruvbox Dark/Light, Tokyo Night, Rosé Pine, One Dark, Solarized Dark/Light) plus Automatic (follows the desktop's light/dark); previewed live as you move through them |
| **Default Apps** | an app per file kind (folders, PDF, images, video, audio, Markdown, web pages, text & code, Office, archives) or per extension, used when Lumen opens a file; `Ctrl+O` is Open With for one file (`Ctrl+↵` there: and always use it) |

The window is two floating pieces over a clear surface: the search bar and,
under it, the results, as tall as their rows. The selected row is filled
with the theme's accent and says what Enter does there.

Keys: `↑↓` / `Ctrl+N/P` move, `↵` primary action, `Ctrl+↵` secondary,
`Ctrl+K` action panel, `Esc` clears / goes back / hides, `Backspace` on an
empty search goes back, `Ctrl+X` deletes a clipboard entry, `Ctrl+O` Open
With on a file.

## Settings file

Everything in Settings lives in `~/.config/lumen/settings.conf`, plain
`key = value` lines with comments, written atomically and owner-only. It can
be edited by hand: Lumen reads it again the next time its window opens (it
compares the file's mtime to the nanosecond, size and inode). A bad value
falls back to its default, an unknown key is kept, and nothing in the file can
stop Lumen from starting. Extensions can be mapped only here:

```ini
theme = catppuccin-mocha
text_size = large
clipboard_keep = 500
terminal = kitty

[open-with]
pdf = org.gnome.Papers.desktop
.log = org.gnome.TextEditor.desktop
```

Themes are a few colours (`src/ui/themes.zig`) turned into CSS variables in
front of `style.css`; a test checks every theme's text contrast (WCAG) and
that the stylesheet uses no variable a theme does not define.

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
  swap in microseconds.
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
reading them all: ripgrep needs ~200 ms per query over a developer's home directory
(2.8 s cold) and every core.

- **What is indexed**: what `rg --files` lists under `$HOME` (honours
  `.gitignore`, skips hidden files), minus package caches and build output,
  text files up to 1 MB, plus PDFs (`pdftotext`) and docx/xlsx/pptx/odt/ods/odp
  (`unzip` + XML to text, `extract.zig`). Extracted text is cached per
  document version in `~/.cache/lumen/text/`.
- **Format**: one mapped file (`~/.cache/lumen/content.idx`): document table
  (path, mtime, size) and segments of sorted trigram keys with varint-delta
  posting lists. Building dedups each file's trigrams with a 16M-bit map and
  radix-sorts (trigram, doc) pairs, closing a segment every 16 M pairs so
  memory stays bounded.
- **Query**: intersect the lists of every trigram of every word (shortest
  first), then verify candidates by reading them, in parallel and in order of
  what is known without I/O (recency, depth, file name), stopping once no
  unread candidate can still enter the top 50. With several words, the exact
  phrase ranks first.
- **Freshness**: re-listing takes ~150 ms; on start, every 5 minutes and when
  the window opens, changed (path, mtime, size) trigger a rebuild in the
  background, swapped in under a lock.

Measured on the same desktop: 43k files / 438 MB of text → 66 MB index, built in 0.9 s
(first run with extraction of 274 documents: ~38 s, once); queries 0.8–12 ms
including verification. `zig-out/bin/lumen-find content` reproduces it.

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

What the measurements changed (RTX 5060 Ti, 12 threads, 1.06 M files and
43 k text documents indexed):

| | before | after | what fixed it |
|---|---|---|---|
| RSS / private | 396 / 128 MB | 113 / 49 MB | fixed `M_MMAP_THRESHOLD` (glibc's dynamic threshold kept 133 MB of freed buffers), 4 malloc arenas, `malloc_trim` after rebuilds |
| peak RSS | 704 MB | 245 MB | same |
| CPU, 13 s of typing | 6.9 s | 2.35 s | content verification below |
| contents, search p50 | 106 ms | 5 ms | SIMD case-insensitive scan, stop counting at 10 hits, tight early-stop bound, map extracted texts instead of reading them |
| contents, key to frame p50 | 131 ms | 18 ms | previews clip long lines instead of wrapping |
| files, key to frame p50 | 73 ms | 23 ms | preview capped at 40 lines, no wrapping |
| CPU idle | 0 % | 0 % | nothing polls: inotify and futex waits |
| GPU | | ~10 MiB VRAM while shown, none hidden, SM ~0 % | |

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
- content queries run on a worker thread, newest query wins; the UI never
  waits on a slow disk or a large document
- caches and indexes are owner-only (0700 / 0600)
- the clipboard watcher is restarted with backoff if it dies
- pasting into a terminal sends Ctrl+Shift+V
- file-name queries up to 255 bytes; a hung mount cannot block the content
  listing for more than a minute
- corrupt index files are rejected and rebuilt, never trusted
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

Fuzz tests (index files, calculator, Office XML, case-insensitive search) run
on their seed corpus as part of `zig build test`. Exploring with `--fuzz`
does not work with Zig 0.16.0 as shipped: its test runner does not compile in
fuzz mode (`writeStackTrace` called with an error trace) and the self-hosted
x86 backend has no coverage instrumentation; a patched lib dir and
`use_llvm = true` make it run (3.5M + 4.9M iterations found nothing).

The end-to-end runner (`tools/e2e.sh`) checks every view, the keyboard, the
action panel, live file changes, the clipboard store and latency, then quits
the instance and checks the indexes were saved. `lumen --dump` prints what
the window shows (rows, selection, detail, panel) and `lumen --key NAME`
presses a key, so the UI is tested without screenshots.

## Build

Needs Zig 0.16, `gtk4`, `gtk4-layer-shell`, `sqlite`, and at run time
`wl-clipboard`, `wtype`, `hyprctl`, `wpctl`, `playerctl`, `rg`, and for
documents `pdftotext` (poppler) and `unzip`.

```sh
zig build test
zig build -Doptimize=ReleaseSafe
install -Dm755 zig-out/bin/lumen ~/.local/bin/lumen
```

## Hyprland

```ini
exec-once = lumen --daemon
bind = ALT, SPACE, exec, lumen
layerrule = blur true,match:namespace lumen
layerrule = ignore_alpha 0.45,match:namespace lumen
```

`ignore_alpha` keeps the blur behind the search bar and the results only:
at 0 the soft shadows around them are blurred too, which shows as a
frosted halo on the clear part of the surface.

## Command line

```
lumen                       toggle the window (starts the daemon if needed)
lumen --daemon              start hidden
lumen --view clipboard      open a view: root, clipboard, windows
lumen --query "10 km to mi" open with text typed
lumen --show | --hide | --quit
lumen --stats               memory, index and latency numbers
lumen --dump                what the window shows, as text (tests)
lumen --key down            press a key (tests)
```

## Layout

```
src/core/       pure logic, unit tested: fuzzy, calc, frecency, geometry, script headers
src/index/      file index (std + Linux syscalls only): store, scan, search, live, service;
                content index: content, content_list, extract, ContentService
src/sys/        SQLite store, process spawning (GLib), hyprctl
src/providers/  apps (GIO), built-in commands, script commands
src/ui/         the GTK window (Ui.zig) and its stylesheet
src/actions.zig what each action does
src/c.zig       hand-written GTK/GLib bindings (Zig 0.16's translate-c chokes on GLib)
```

## License

MIT, see [LICENSE](LICENSE). The language logos in `src/ui/icons/devicon/`
come from [Devicon](https://devicon.dev) (MIT, see its LICENSE there).
