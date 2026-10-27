# Extending Lumen with Lua

Lumen runs Lua 5.4 for three things:

- **Extensions**: commands of your own, with lists, search and actions, in
  `~/.config/lumen/extensions/<name>/init.lua`.
- **`init.lua`**: your configuration in `~/.config/lumen/init.lua`: themes,
  keyboard shortcuts, quick commands.
- **`style.css`**: your own CSS in `~/.config/lumen/style.css`, loaded after
  Lumen's.

Lumen draws everything itself: an extension returns data (rows, details,
actions) and it shows up like the rest of Lumen, in every theme. Lua never
runs on the window's thread, so a slow extension cannot freeze the window.

Edits take effect the next time the window opens. Lumen watches `init.lua`
and the `.lua` files directly inside each extension's folder; after editing a
file in a subfolder, or to reload at once, run `lumen --reload`.

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
list that can quit processes, quick notes (storage and preferences), and a
sample `init.lua` and `style.css`.

## Commands

An extension returns `lumen.extension { title, icon, commands }`. Its
commands show up in the root search; `title` is their subtitle by default.

Each command has one of `items`, `search` or `run`:

| | |
|---|---|
| `items` | A list of rows, or a function returning one. It runs when the command opens; Lumen filters the rows as you type. |
| `search` | `function(query)` returning rows. It runs again for every query; Lumen shows what it returns as it is. |
| `run` | `function()` with no list: Enter runs it. |

| Field | |
|---|---|
| `name` | Required. `a-z`, `0-9`, `-`, `_`. The command's id is `<extension>.<name>`. |
| `title` | Required. |
| `subtitle` | Defaults to the extension's title. |
| `icon` | See [Icons](#icons). Defaults to the extension's icon. |
| `keywords` | A string or a list of strings, also matched by the search. |
| `placeholder` | Text in the empty search bar. |
| `detail` | `true` shows a detail pane with the selected row's `detail`. |

## Rows

A row is a table, or just a string (a row with that title).

| Field | |
|---|---|
| `title` | Required. |
| `subtitle`, `accessory` | Under the title; on the right. |
| `icon` | See [Icons](#icons). Defaults to the command's icon. |
| `keywords` | Also matched when Lumen filters (`items` commands). |
| `detail` | Text for the detail pane (`detail = true` on the command). |
| `section` | Rows with the same section are grouped under it. |
| `id` | Keeps the selection on this row when the list reloads (default: the title). |
| `confirm` | `true`: the first action needs a second Enter. |
| `actions` | Up to 9. Without any, Enter copies the title. |

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
files of your own.

## Icons

- An emoji: `icon = "🐙"`.
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
| `lumen.json.encode(value)` | Lua values to JSON. A table with a sequence part is an array, else an object with string keys. |
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

`require("name")` loads `name.lua` or `name/init.lua` from the extension's
folder. The standard library is there except `os.exit`, `os.execute`,
`os.setlocale`, `io.popen`, `debug` and native modules. Use `lumen.exec` to
run programs, since it has a time limit.

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
| `.tile`, `.emoji` | Icons. |
| `.detail`, `.detail-text`, `.meta` | The detail pane. |
| `.actions` | The action panel (Ctrl+K). |
| `.kbd` | Key caps. |

```css
.search, .results-island { border-radius: 14px; }
.results > row .title { font-weight: 600; }
```

These class names are part of Lumen's interface: a change to them is noted in
the changelog.

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
| A `run` | 30 s |
| `lumen.exec` | its `timeout`, never past the limit of the call it is in |
| Memory | 64 MB per extension |
| Rows | 1000 per list |

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
