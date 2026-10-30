# Extending Lumen with Lua

Lumen runs Lua 5.4 for three things:

- **Extensions**: commands of your own, with lists, search and actions, in
  `~/.config/lumen/extensions/<name>/init.lua`.
- **`init.lua`**: your configuration in `~/.config/lumen/init.lua`: themes,
  keyboard shortcuts, quick commands.
- **`style.css`**: your own CSS in `~/.config/lumen/style.css`, loaded after
  Lumen's.
- **`lumen.layout`**: the window's structure (size, place, one panel or
  two, a footer...), in `init.lua`. With `style.css` it can make Lumen look
  like Raycast, Spotlight, Alfred or rofi: see [`examples/styles`](examples/styles).
- **Styles**: a whole look (an `init.lua` with the above and a `style.css`)
  in `~/.config/lumen/styles/<name>/`, chosen in Change Theme.

Lumen draws everything itself: an extension returns data (rows, details,
actions) and it shows up like the rest of Lumen, in every theme. Lua never
runs on the window's thread, so a slow extension cannot freeze the window.

Edits take effect the next time the window opens. Lumen watches `init.lua`
and the `.lua` files directly inside each extension's and style's folder;
after editing a file in a subfolder, or to reload at once, run
`lumen --reload`.

## A first extension

`~/.config/lumen/extensions/hello/init.lua`:

```lua
local lumen = require("lumen")

return lumen.extension {
  title = "Hello",
  icon = "👋",
  commands = {
    {
      name = "greetings",
      title = "Greetings",
      items = {
        { title = "Hola", subtitle = "Spanish", actions = { lumen.action.paste("Hola") } },
        { title = "Bonjour", subtitle = "French", actions = { lumen.action.paste("Bonjour") } },
      },
    },
  },
}
```

Open Lumen and type "greetings". [`examples/`](examples) has more: a GitHub
extension (pull requests, issues and repositories through `gh`), a process
list that can quit processes, quick notes (storage and preferences), a world
clock that answers "time tokyo" in the main search, a "New File" form, an
emoji picker and a wallpaper browser (grids), and a sample `init.lua` and
`style.css`.

## Commands

An extension returns `lumen.extension { title, icon, commands }`. Its
commands show up in the root search; `title` is their subtitle by default.

Each command has one of `items`, `search` or `run`:

| | |
|---|---|
| `items` | A list of rows, or a function returning one. It runs when the command opens; Lumen filters the rows as you type. |
| `search` | `function(query)` returning rows. It runs again for every query; Lumen shows what it returns as it is. |
| `run` | `function()` with no list: Enter runs it. |
| `fields` + `submit` | A form: see [Forms](#forms). |

A command can also have `root = function(query)`: its rows then show in the
main search, in a section of their own right after the calculator, while you
type. Return nil when the query is not for you; at most 8 rows show. Lumen asks
for each query (2 characters or more) and never waits: rows appear when they
are ready, and a newer query replaces an older one. A command with only `root`
is not listed as a command itself.

```lua
{ name = "time", title = "World Clock", root = function(query)
    local city = query:match("^time%s+(.+)$")
    if not city then return nil end
    return { { title = clock(city), subtitle = city } }
  end }
```

| Field | |
|---|---|
| `name` | Required. `a-z`, `0-9`, `-`, `_`. The command's id is `<extension>.<name>`. |
| `title` | Required. |
| `subtitle` | Defaults to the extension's title. |
| `icon` | See [Icons](#icons). Defaults to the extension's icon. |
| `keywords` | A string or a list of strings, also matched by the search. |
| `placeholder` | Text in the empty search bar. |
| `detail` | `true` shows a detail pane with the selected row's `detail`. |
| `grid` | `true` shows the rows as a grid of cells: a large icon or an `image`, and the title. Arrows move in two directions. |
| `columns` | Cells to a line in a grid, 2 to 10 (default 5). |

## Rows

A row is a table, or just a string (a row with that title).

| Field | |
|---|---|
| `title` | Required. |
| `subtitle`, `accessory` | Under the title; on the right. |
| `icon` | See [Icons](#icons). Defaults to the command's icon. |
| `keywords` | Also matched when Lumen filters (`items` commands). |
| `detail` | Text for the detail pane (`detail = true` on the command). |
| `markdown` | Instead of `detail`: formatted text (see below). |
| `metadata` | Up to 4 `{ "Label", "value" }` pairs under the detail, in an *Information* block. |
| `image` | A picture file for the row's grid cell (scaled down as it loads). |
| `section` | Rows with the same section are grouped under it. |
| `id` | Keeps the selection on this row when the list reloads (default: the title). |
| `confirm` | `true`: the first action needs a second Enter. |
| `actions` | Up to 9. Without any, Enter copies the title. |

### Markdown in the detail pane

`markdown` understands a small, safe subset: `#`, `##` and `###` headings,
**bold**, *italic*, `` `code` ``, fenced code blocks, `-` and `1.` lists,
`>` quotes, `---` rules and `[links](https://...)`. Anything else shows as
typed.

```lua
{
  title = "lumen",
  markdown = "## lumen\n\nA fast launcher. **MIT** licensed.\n\n```\nzig build\n```",
  metadata = { { "Stars", 120 }, { "Language", "Zig" } },
}
```

## Actions

The first action is Enter, the second Ctrl+Enter, and Ctrl+K lists them all.

Lumen runs these itself, at once:

| | |
|---|---|
| `lumen.action.open(target [, title])` | A URL, or a file or folder (`~/` works), opened the way Lumen opens files, Default Apps included. |
| `lumen.action.copy(text [, title])` | Copies to the clipboard. |
| `lumen.action.paste(text [, title])` | Pastes into the app you came from. |
| `lumen.action.exec(argv [, title])` | Starts a program (`{ "kitty", "-e", "htop" }`) without waiting for it. |

Any action can instead be a Lua function:

```lua
{ title = "Delete", run = function(row)
    lumen.exec { "rm", row.detail }
    return "refresh"
  end }
```

`run` gets the row's table. What it returns decides what happens next:

| | |
|---|---|
| nothing, or `"close"` | The window closes. |
| `"stay"` | The window stays as it is. |
| `"refresh"` | The command's rows load again; the selection is kept. |

If it fails, the error shows on the row. A command's own `run` works the same
way.

## Preferences

An extension can ask for settings: an API token, a folder, an option. They
show in Lumen's Settings under *Extensions*, and the extension reads them from
`lumen.preferences`:

```lua
return lumen.extension {
  title = "Weather",
  preferences = {
    { name = "city", title = "City", type = "text", default = "Madrid" },
    { name = "units", title = "Units", type = "choice",
      choices = { { value = "metric", title = "Celsius" }, { value = "imperial", title = "Fahrenheit" } } },
    { name = "token", title = "API Key", type = "password" },
    { name = "details", title = "Show Details", type = "toggle", default = true },
  },
  commands = { ... uses lumen.preferences.city ... },
}
```

| Field | |
|---|---|
| `name` | Required; the key in `lumen.preferences`. |
| `title`, `description` | What Settings shows. |
| `type` | `text` (the default), `password` (typed unseen), `choice` or `toggle`. |
| `choices` | For `choice`: strings, or `{ value, title }` tables. |
| `default` | Until it is set: `""`, `false`, or the first choice. |

Toggles read as `true`/`false`, the rest as strings. `lumen.preferences` is
read-only; changing a preference in Settings reloads the extension. Values are
kept in `~/.local/share/lumen/extensions/<id>/preferences.json`.

## Storage

`lumen.storage` keeps values between runs and reloads, per extension:

```lua
local seen = lumen.storage.get("seen") or {}
seen[#seen + 1] = id
lumen.storage.set("seen", seen)
```

| | |
|---|---|
| `lumen.storage.get(key)` | The value, or nil. |
| `lumen.storage.set(key, value)` | Saves it at once (anything `lumen.json.encode` takes). |
| `lumen.storage.remove(key)` | |
| `lumen.storage.all()` | A copy of everything. |

Keys are strings. It is a JSON file written atomically, in
`~/.local/share/lumen/extensions/<id>/storage.json`, so keep it to settings,
lists and small caches, not megabytes. `lumen.data_dir` is that folder, for
files of your own. If `storage.json` is there but cannot be read, `set` and
`remove` raise an error instead of writing over it.

## Forms

A command with `fields` and `submit` is a form: a row per field showing its
value, and a last row that submits. Fields take the same keys as
[preferences](#preferences), plus `required = true`. Enter on a text field
opens a box to type in, on a choice lists its values, on a toggle flips it.

```lua
{
  name = "create", title = "New File",
  fields = {
    { name = "name", title = "File Name", required = true },
    { name = "folder", title = "Folder", type = "choice", choices = { "Documents", "Desktop" } },
    { name = "open", title = "Open It", type = "toggle", default = true },
  },
  submit_title = "Create File",   -- the last row, "Submit" by default
  submit = function(values)
    -- values.name, values.folder (strings), values.open (a boolean)
  end,
}
```

`submit` returns like an action's `run`: nothing closes the window, `"stay"`
keeps it, `"refresh"` clears the form for another one. An error shows on the
row and keeps what was typed.

## Icons

Anywhere an icon is given (commands, rows, `lumen.icons`):

- An emoji: `icon = "🐙"`.
- An image file, PNG or SVG: `icon = "~/icons/fox.svg"` (or an absolute path).
- An icon from your icon theme, in full colour: `icon = "firefox"`.
- A symbolic icon (its name ends in `-symbolic`), on a grey tile:
  `icon = "folder-symbolic"`.
- An icon name on a coloured tile: `icon = { name = "folder-symbolic", color = "blue" }`.
  The colours are red, orange, yellow, green, blue, purple, pink and gray.

## The `lumen` module

`local lumen = require("lumen")`, also available as the global `lumen`.

| | |
|---|---|
| `lumen.extension(spec)` | What `init.lua` returns. |
| `lumen.exec(argv [, opts])` | Runs a program and waits for it. Returns `stdout, code, stderr`, or `nil, message` when it cannot run or times out. `opts.stdin` is written to its input; `opts.timeout` is in seconds. It inherits Lumen's environment and searches `PATH`. |
| `lumen.json.decode(text)` | JSON to Lua values; null becomes nil. |
| `lumen.json.encode(value)` | Lua values to JSON. A table with a sequence part is an array, else an object with string keys. Bytes that are not UTF-8 become U+FFFD. |
| `lumen.notify(title [, body])` | A desktop notification. |
| `lumen.log(...)`, `print(...)` | To Lumen's log, tagged with the extension. |
| `lumen.dir` | The extension's folder. |
| `lumen.data_dir` | Its data folder (storage, preferences, your own files). |
| `lumen.preferences` | Its [preferences](#preferences). |
| `lumen.storage` | Its [storage](#storage). |
| `lumen.id` | The extension's id (`"config"` for `init.lua`). |
| `lumen.theme(spec)` | Adds a theme (see [init.lua](#initlua)). |
| `lumen.keymap(keys, target)` | Adds a shortcut (see [init.lua](#initlua)). |
| `lumen.set(settings)` | Fixes settings (see [init.lua](#initlua)). |
| `lumen.layout(options)` | The window's structure (see [Layout](#layout)). |

`require("name")` loads `name.lua` or `name/init.lua` from the extension's
folder. The standard library is there except `os.exit`, `os.execute`,
`os.setlocale`, `io.popen`, `debug` and native modules. Use `lumen.exec` to
run programs, since it has a time limit. There is no standard input
(`io.stdin` is gone, `io.read()` reads nothing), and `io.open` and the
functions that open files refuse FIFOs, sockets and devices other than
`/dev/null`, `zero`, `full`, `random` and `urandom`: reading one could block
past any limit. `setmetatable` refuses a metatable with `__gc`, since
finalizers run where no limit can stop them.

An extension's commands share one Lua state. A table they all `require` (or a
global) keeps values between calls until the files are reloaded.

## init.lua

`~/.config/lumen/init.lua` runs like an extension whose id is `config`. It can
return `lumen.extension { ... }` with commands of its own, and it is the place
for themes and shortcuts:

```lua
local lumen = require("lumen")

-- Pick it in Change Theme ("Your Themes").
lumen.theme {
  id = "midnight", name = "Midnight", dark = true,
  bg = "#0f1117", fg = "#e6e6e6", accent = "#7c9cff",
  surface = "#1a1d27", -- optional: the action panel; defaults to bg
  ink = "#ffffff",     -- optional: lines and secondary text; defaults to fg
}

-- Shortcuts while the window is open: a command id or a view name
-- (clipboard, windows, files, contents, settings, themes, default_apps).
lumen.keymap("ctrl+1", "clipboard")
lumen.keymap("ctrl+g", "github.prs")

-- Settings, as in settings.conf.
lumen.set {
  theme = "midnight",
  width = "wide",          -- narrow, default, wide
  height = "tall",         -- short, default, tall
  density = "compact",     -- compact, default, comfortable
  position = "center",     -- upper_third, center
  text_size = "default",   -- small, default, large
  opacity = 97,
  suggestions = true,
  files_in_root = true,
}
```

A setting `lumen.set` fixes shows as *Set in init.lua* in Settings and cannot
be changed there; `settings.conf` keeps its own value for it, which is used
again if you take it out of `init.lua`. A key or value Lumen does not know is
an error, so typos do not go unnoticed.

Keys are written as modifiers then a key, `+` between them: `ctrl+g`,
`alt+shift+F5`, `super+space`. Each needs ctrl, alt or super, since plain keys
type into the search. Lumen's own keys (arrows, Enter, Esc, Ctrl+K, Ctrl+N/P/J,
Ctrl+X, Ctrl+O, Ctrl+Shift+C/F) come first.

## Layout

`lumen.layout` in `init.lua` decides what the window is made of; `style.css`
then styles it. Every key is optional, and several calls add up.

```lua
lumen.layout {
  width = 750, height = 475,      -- pixels (else the Width/Height settings)
  position = "upper_third",       -- top, upper_third, center, bottom
  offset = 0,                     -- pixels away from there
  panels = "single",              -- "split": search bar and results apart
  search = "top",                 -- or "bottom"
  detail = "right",               -- the detail pane: right, left, bottom
  footer = true,                  -- a bar: the view, what Enter does, Actions
  rows = "inline",                -- subtitles beside titles ("stacked": under)
  prompt = "run",                 -- fixed text in the search bar, like rofi's
  placeholder = "Go…",            -- the empty search field's text ("<view>…" elsewhere)
  searchbar = { "back", "icon", "prompt", "scope", "entry", "keys" },
  row = { "icon", "text", "accessory", "hint" },
  show = {                        -- all true by default, except search_icon
    hints = false,                -- "Open ↵" in the selected row
    subtitles = true, accessories = true, icons = true, section_titles = true,
    key_hints = false,            -- the "Ctrl K" chip in the search bar
    scope = true, back = true,    -- the view's name and the back arrow
    search_icon = false,          -- a magnifier before the text
  },
}
```

| | |
|---|---|
| `width`, `height` | 360–2400 and 240–1600 pixels. Settings shows Window Width and Height as *Set in init.lua*. |
| `position`, `offset` | `bottom` anchors to the bottom of the screen; `offset` moves it (down from the top, up from the bottom). |
| `panels` | `split` (Lumen's own look): the search bar and the results float apart. `single`: one panel, the pieces touching. |
| `search` | `bottom` puts the search field under the results, as many rofi themes do. |
| `detail` | Where the detail pane goes beside (or under) the list. |
| `footer` | With a footer, the action panel opens above it, by its Actions key. |
| `searchbar` | The search bar's parts, in order: `back` (the arrow inside a view), `icon` (the magnifier, with `show.search_icon`), `prompt`, `scope` (the view's name), `entry` (the text, required), `keys` (the Ctrl K chip). Parts left out are not shown. |
| `row` | A row's parts, in order: `icon`, `text` (title and subtitle, required), `accessory`, `hint` (what Enter does). `{ "text", "accessory", "icon" }` puts icons on the right. |
| `prompt` | Text before the search field (`.prompt` in style.css). |
| `placeholder` | What the empty search field says at the root; inside a view it then says the view's name and "…" (Omarchy's menu does this). |

A key or value Lumen does not know is an error shown in the root search.

## Replacing Lumen's icons

Three ways, from the broadest:

- **Icon Theme** in Settings (or `icon_theme = Papirus` in settings.conf, or
  `lumen.set { icon_theme = "Papirus" }`): a different icon theme for Lumen
  only; the rest of the desktop keeps its own.
- **`~/.config/lumen/icons/<name>.svg`** (or `.png`) replaces the icon called
  `<name>` everywhere in Lumen. The built-in commands use symbolic icons such
  as `edit-paste-symbolic` (Clipboard History), `folder-saved-search-symbolic`
  (Search Files) or `system-lock-screen-symbolic` (Lock Screen); `lumen --dump`
  prints each row's icon name.
- **`lumen.icons`** in init.lua replaces the icon of one item, by its key:

```lua
lumen.icons {
  ["app:firefox"] = "~/icons/firefox.svg",   -- an app, by its .desktop file
  ["cmd:clipboard"] = "📋",                   -- a built-in command
  ["sys:lock"] = { name = "changes-prevent-symbolic", color = "red" },
  ["ext:github.prs"] = "🐙",                  -- an extension's command
  ["script:backup.sh"] = "💾",                -- a script command
  ["file:pdf"] = "~/icons/pdf.png",           -- files of a kind, by extension
  ["file:folder"] = "📁",                     -- folders
}
```

Keys: `app:<desktop id>` (with or without `.desktop`), `cmd:` (clipboard,
files, contents, settings, themes, default_apps, windows), `sys:` (lock,
sleep, restart, shutdown, logout, dark, trash, volup, voldown, mute, mic,
play, next, prev), `win:` (window management: left, right, maximize...),
`script:<file name>`, `ext:<extension>.<command>`, and `file:<extension>` or
`file:folder`. `lumen --dump` prints each row's icon and, last, its key.

## Styles

A style is a look you switch to in Change Theme, under **Styles** (the ones
in [`examples/styles`](examples/styles), built in) and **Custom** (each
folder in `~/.config/lumen/styles`, which may hold an `init.lua`, a
`style.css` or both; one named like a built-in style replaces it). The
choice is the `style` setting in `settings.conf`.

The style's `init.lua` runs before yours, so yours can adjust it, and its
`style.css` comes between Lumen's rules and yours. Inside it:

- `lumen.layout` and `lumen.theme` work as in `init.lua`; its themes are
  listed under the style's name.
- `lumen.set` gives the values the settings take when the style is
  chosen, without fixing them: they can be changed afterwards in Settings
  and Change Theme. (In `init.lua`, `lumen.set` fixes them.) Set the same
  keys in every style you switch between (`theme`, `density`, `opacity`), or
  one style's value stays in the next.

```lua
-- ~/.config/lumen/styles/paper/init.lua
local lumen = require("lumen")
lumen.theme { id = "paper", name = "Paper", dark = false,
  bg = "#f7f3ea", fg = "#2b2b2b", accent = "#c2410c" }
lumen.set { theme = "paper", density = "comfortable", opacity = 100 }
lumen.layout { width = 640, panels = "single", show = { key_hints = false } }
```

## style.css

`~/.config/lumen/style.css` is GTK CSS, loaded after Lumen's own rules, so it
can change anything Lumen draws. The theme's colours are variables: `--bg`,
`--surface`, `--fg`, `--ink`, `--accent`, `--accent-soft`, `--on-accent`,
`--shadow`. The sizes are `--font`, `--font-query` and `--font-small`.

| Class | |
|---|---|
| `.search` | The search bar; `.query` is the text inside it. |
| `.scope` | The name of the open view, in the search bar. |
| `.results-island` | The piece holding the results and the detail pane. |
| `.results > row` | A row; `:selected` is the highlighted one. |
| `.title`, `.subtitle`, `.accessory`, `.hint` | The parts of a row. |
| `.section-title` | A section header. |
| `.tile`, `.emoji`, `.app-icon`, `.file-icon` | Icons: symbolic ones on tiles, emoji, theme icons, image files. |
| `.detail`, `.detail-text`, `.meta` | The detail pane. |
| `.actions` | The action panel (Ctrl+K). |
| `.grid`, `.grid > flowboxchild`, `.cell-title` | Grids and their cells. |
| `.footer`, `.footer-title`, `.footer-action`, `.footer-sep` | The footer (`lumen.layout`). |
| `.search-icon` | The magnifier (`show.search_icon`). |
| `.prompt` | The prompt (`lumen.layout`'s `prompt`). |
| `.shell.single`, `.search-bottom`, `.with-footer`, `.alone` | Classes on the window's pieces for each layout: one panel, search at the bottom, a footer, only the search bar showing. |
| `.results-island.detail-left`, `.detail-bottom` | The detail pane's place. |
| `.kbd` | Key caps. |

```css
.search, .results-island { border-radius: 14px; }
.results > row .title { font-weight: 600; }
```

These class names are part of Lumen's interface: a change to them is noted in
the changelog.

## Sharing and installing extensions

An extension is a folder with an `init.lua`, so a git repository whose root
holds one can be installed with a command:

```sh
lumen --install https://github.com/someone/lumen-weather    # → extensions/weather
lumen --install git@host:me/tools.git --as tools           # pick the name
lumen --update weather                                      # git pull it
lumen --update                                              # every git extension
lumen --uninstall weather
```

Settings > Extensions lists every installed extension, those that failed
to load included: its preferences, its folder, Update (for git checkouts)
and Uninstall.

The name comes from the repository (`lumen-`, `lumen-ext-` and `-lumen` are
dropped) unless `--as` gives one; `config` and `style` are taken. A
repository without an `init.lua` is refused. Lumen loads the extension at once, and it runs as you: read its
`init.lua` first, as you would a script.

To publish one, push the folder (with its `init.lua` at the root) to any git
host. Naming the repository `lumen-<name>` makes it easy to find.

## From the command line

```sh
lumen --command github.prs          # open a command (or run it)
lumen --command hello.shout --query hi
lumen --reload                      # load init.lua and the extensions again
```

So a Hyprland key can open a command directly:

```ini
bind = ALT SHIFT, G, exec, lumen --command github.prs
```

## Limits

| | |
|---|---|
| Loading a file | 5 s |
| Listing rows (`items`, `search`) | 10 s |
| Root search rows (`root`) | 3 s |
| A `run` | 30 s |
| `lumen.exec` | its `timeout`, never past the limit of the call it is in |
| Memory | 64 MB per extension, `lumen.json` included |
| Rows | 1000 per list, 16 MB in all |
| A row's fields | 1 KB for one-line fields (title, subtitle...), 4 KB for `keywords` and `image`, 128 KB for `detail` and `markdown`; longer ones are cut |

Code still running at its limit is stopped with an error. Lists run one at a
time, and a newer query replaces one that has not started yet.

## When something goes wrong

- A file that fails to load shows up in the root search as *Extension "name"
  failed to load*, with the error. Enter copies it. The other extensions load
  anyway.
- An error while listing shows in place of the rows. An error in an action
  shows on the row.
- `print` and `lumen.log` go to Lumen's log. To see it, stop the daemon
  (`lumen --quit`) and start it in a terminal (`lumen --daemon`).

## Safety

Extensions run as you, inside Lumen. The missing functions above keep a bug
from taking Lumen down, and the limits stop runaway code. They do not make a
malicious extension safe: `lumen.exec` can run anything. Install extensions
you have read, as you would a shell script.
