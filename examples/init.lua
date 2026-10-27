-- ~/.config/lumen/init.lua: loaded when Lumen starts, and again whenever
-- it (or an extension) changes, the next time the window opens.
local lumen = require("lumen")

-- A theme of your own: pick it in Change Theme.
lumen.theme {
  id = "midnight",
  name = "Midnight",
  dark = true,
  bg = "#0f1117",
  surface = "#1a1d27",
  fg = "#e6e6e6",
  accent = "#7c9cff",
}

-- Keys that work while Lumen is open: a built-in view or a command.
lumen.keymap("ctrl+1", "clipboard")
lumen.keymap("ctrl+2", "files")
lumen.keymap("ctrl+g", "github.prs")

-- Commands of your own, without making an extension.
return lumen.extension {
  title = "My Commands",
  commands = {
    {
      name = "dotfiles",
      title = "Open Dotfiles",
      icon = "🗂️",
      run = function()
        lumen.exec { "gio", "open", os.getenv("HOME") .. "/.config" }
      end,
    },
  },
}
