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
