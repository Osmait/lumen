# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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
- `lumen` is now a tiny static program that hands its arguments to the
  daemon over a Unix socket; the GTK program is `lumen-gtk`, installed
  beside it. With the two changes below the window opens in ~8 ms instead
  of ~58 ms, and each copy
  into the clipboard history no longer starts a GTK process. Install both
  files (see the README).
- The content index follows edits incrementally: changed files are read
  again and added, the rest is left alone (two edits: 23 ms instead of a
  1.6 s rebuild, and ~100 MB less memory at the peak). It is rebuilt whole
  once 20 % of it is outdated. The index format changes (LUMCTX03): the
  first start rebuilds it once.
- Rebuilding the content index peaks at a third of the memory (585 → 195
  MB on 49 k documents): smaller segments, and the index written to its
  file as it grows instead of built whole in memory. An update's peak:
  +26 MB. The same search times.
- Hyprland is asked for the focused monitor through its socket instead of
  by starting `hyprctl` on every show.
- The first show after the daemon starts no longer creates the window's
  renderer while you wait: that is done hidden, right after start (~175 ms
  down to ~30 ms).
- Styles in Change Theme: whole looks (layout, themes, settings and CSS)
  switched at once. The five in `examples/styles` are built in, and each
  folder in `~/.config/lumen/styles` is one more, under Custom. A style's
  `lumen.set` gives defaults instead of fixing settings.
- An Omarchy style (`examples/styles/omarchy`): its menu's look, its 23
  palettes, following Omarchy's current theme, with a theme-set hook.
- Change Theme opens scrolled to the theme in use, and a style row shows
  the theme in use instead of the last one previewed.
- `lumen.layout`'s `placeholder`: the empty search field's text.
- Settings > Extensions lists every installed extension (failed ones too),
  with its preferences, Open Folder, Update (git) and Uninstall.
- Icons: image files (PNG, SVG) wherever an icon is given; `lumen.icons`
  replaces any app's, command's or file kind's icon by its key;
  `~/.config/lumen/icons/<name>.svg` replaces an icon by name everywhere; an
  Icon Theme setting for Lumen only.
- Example extensions: GitHub (through `gh`), processes, hello.

## [0.1.0] - 2026-10-26

First public release.

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

[Unreleased]: https://github.com/Osmait/lumen/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Osmait/lumen/releases/tag/v0.1.0
