# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The file index's format changed: the first start after updating rescans
  your home folder once. Cached document text is renamed, not extracted
  again.
- Images whose size cannot be read from their header (JPEG XL, ICO, TGA...)
  are no longer previewed, and images larger than 8192×8192 are not either.
- Extensions: one-line row fields are cut at 1 KB, `detail` and `markdown`
  at 128 KB, and a list's rows can take 16 MB in all. `setmetatable` refuses
  `__gc`, there is no standard input, and `io.open` refuses FIFOs, sockets
  and most devices. Extensions cannot be named `config` or `style`.
- Release workflows pin their actions to commits and keep no credentials.

### Fixed

- The window could freeze while the content index extracted documents or
  verified a slow search, and while a large folder was moved.
- A crash when an extension's root-search rows were replaced as you typed
  and deleted.
- Huge images (a small file declaring 20000×20000 pixels) no longer take
  gigabytes to preview, and grid pictures load off the UI thread.
- Slow copies are no longer dropped and no longer freeze the window.
- A folder replaced by a link is no longer followed, moved folders leave no
  ghost files behind, and `mv -T` over an empty folder is picked up.
- A damaged content index no longer crashes Lumen at every start.
- Building the content index over many large, varied files stays within its
  memory bound.
- PDFs and Office files that timed out or lacked a tool are tried again;
  edits within the same second are picked up; an encrypted Office file no
  longer hangs extraction for 15 s; the text cache is cleaned up.
- `lumen.storage` no longer erases storage.json after saving a file name
  that is not UTF-8, and never writes over a file it cannot read.
- `lumen.json.encode` and the `__gc` metamethod could get past an
  extension's memory and time limits.
- A preference typed during a reload could be saved to another extension.
- A failed `--install` no longer leaves a half-cloned folder behind.
- Markdown with many unclosed `**` no longer takes seconds, and a detail
  pane with invalid bytes no longer shows the previous row's text.
- Lines of several megabytes in `lumen --dmenu` no longer freeze it.
- Clipboard History no longer keeps every entry's whole text in memory.
- The clipboard database and its journal files are owner-only (0600).
- File names with Unicode direction controls can no longer disguise their
  extension.
- Script and extension notifications whose text starts with `-` are shown.
- Show in Folder works with a `'` in the path.
- Open at Line works with `$EDITOR` or `$TERMINAL` holding arguments
  (`code --wait`).
- `lumen` checks that the daemon on the socket is yours, and the daemon
  refuses a socket folder it does not own.
- `lumen` no longer dies with exit 141 when the daemon hangs up.
- install.sh restarts a daemon whose binary was replaced.
- Quitting no longer waits for ripgrep or a text extraction to finish.

## [0.1.0] - 2026-10-30

First release.

### Added

- Apps, ranked by how often you open them.
- Calculator with unit conversion.
- Clipboard history, with a preview and paste into the previous app.
- File search over your home folder, kept live with inotify, with image and
  text previews.
- Search inside files (code, notes, PDFs, Office documents) through a
  trigram index; open the editor at the matching line.
- Window search and window management for Hyprland.
- System commands: lock, power, volume, microphone, media, dark mode, trash.
- Script commands from `~/.config/lumen/scripts`.
- Settings, 13 themes plus Automatic, and default apps per kind of file.
- Close on a click outside the window.
- Extensions in Lua 5.4 (`~/.config/lumen/extensions/<name>/init.lua`):
  commands with lists Lumen filters, searches asked again for every query, or
  a single run; rows with subtitles, sections, a detail pane and up to nine
  actions (open, copy, paste, start a program, or a Lua function). Lua runs on
  its own thread, with time and memory limits. See EXTENSIONS.md.
- `~/.config/lumen/init.lua`: themes, keyboard shortcuts and commands of your
  own.
- `~/.config/lumen/style.css`, loaded after Lumen's own styles.
- `lumen --command <extension>.<command>` and `lumen --reload`.
- Layout settings: window width and height, and density (row height and icon
  size), in Settings and settings.conf.
- `lumen.set` in init.lua fixes settings; Settings shows them as set there.
- `lumen --dmenu [--prompt TEXT]`: pick a line of stdin, like dmenu and
  `rofi -dmenu` (row icons and `meta` words included).
- Extension preferences (text, password, choice, toggle), edited in Settings >
  Extensions and read as `lumen.preferences`; `lumen.storage` keeps an
  extension's data between runs.
- Icons named without `-symbolic` show in full colour.
- `root = function(query)` on a command: its rows show in the main search,
  asked for on every query and never waited for.
- Rows can carry `markdown` (a safe subset, rendered in the detail pane) and
  up to 4 `metadata` pairs.
- Forms: a command with `fields` and `submit`; text fields use the new input
  view, required fields are checked before submitting.
- Grids: `grid = true` shows a command's rows as cells (large icons or
  image thumbnails), with 2D arrow keys.
- `lumen --install URL [--as NAME]`, `--update [NAME]` and `--uninstall NAME`:
  extensions from git repositories.
- `lumen.layout` in init.lua: the window's size in pixels and place (top,
  upper third, centre, bottom, with an offset), one panel or two, the search
  field at the top or the bottom, the detail pane right, left or below, a
  footer with what Enter does and Actions, subtitles inline, and which parts
  of a row show.
- Four complete styles in `examples/styles`: Raycast, Spotlight, Alfred and a
  minimal rofi-like one.
- `lumen.layout`'s `searchbar` and `row` order (and leave out) the search
  bar's and the rows' parts; `prompt` adds fixed text before the search field.
- Two programs: `lumen`, a tiny static program a shortcut runs, hands its
  arguments to the daemon (`lumen-gtk`) over a Unix socket without loading
  GTK, so the window is up about 8 ms after the key press; copies reach the
  clipboard history the same way.
- `lumen --help` lists the options, grouped, without starting or asking a
  daemon. Unknown options print the same list.
- Ctrl shortcuts on a row (Ctrl X, Ctrl O, Ctrl Shift C, Ctrl Shift F) run
  the action the action panel shows with those keys; extension actions get
  the shortcuts they declare.
- Styles in Change Theme: whole looks (layout, themes, settings and CSS)
  switched at once. The five in `examples/styles` are built in, and each
  folder in `~/.config/lumen/styles` is one more, under Custom. A style's
  `lumen.set` gives defaults instead of fixing settings.
- An Omarchy style (`examples/styles/omarchy`): its menu's look, its 23
  palettes, following Omarchy's current theme, with a theme-set hook.
- Change Theme opens on the theme in use, and a style row shows the theme
  in use.
- `lumen.layout`'s `placeholder`: the empty search field's text.
- Settings > Extensions lists every installed extension (failed ones too),
  with its preferences, Open Folder, Update (git) and Uninstall.
- Icons: image files (PNG, SVG) wherever an icon is given; `lumen.icons`
  replaces any app's, command's or file kind's icon by its key;
  `~/.config/lumen/icons/<name>.svg` replaces an icon by name everywhere; an
  Icon Theme setting for Lumen only.
- Example extensions: GitHub (through `gh`), processes, hello.
- `lumen --version` prints the version, and the running daemon's.
- `install.sh`: installs or updates the latest release in `~/.local/bin`
  (`curl -fsSL https://raw.githubusercontent.com/Osmait/lumen/main/install.sh | sh`).
  Releases are x86_64 tarballs that need GTK 4.12+ and gtk4-layer-shell;
  SQLite and Lua are built in.

### Performance

Measured on a desktop with 1.1 M files under the home folder and 49 k text
files indexed: the window opens about 8 ms after the key press (27 ms the
first time after starting); typing in Search Files takes about 10 ms per key
and in Search File Contents about 11; keeping the content index current
writes about 1.5 MB per change; idle, the daemon uses next to no CPU and
about 40 MB of memory of its own.

[Unreleased]: https://github.com/Osmait/lumen/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Osmait/lumen/releases/tag/v0.1.0
