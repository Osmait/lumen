-- A minimal, rofi-like Lumen: text only, square, monospace, the search
-- field at the bottom, in the middle of the screen.
-- Copy this file to ~/.config/lumen/init.lua and style.css beside it.
local lumen = require("lumen")

lumen.theme {
  id = "minimal", name = "Minimal", dark = true,
  bg = "#0f0f10", surface = "#18181a", fg = "#d7d7d7", ink = "#d7d7d7", accent = "#8fbcbb",
}

lumen.set { theme = "minimal", density = "compact", opacity = 100 }

lumen.layout {
  width = 560,
  height = 420,
  position = "center",
  panels = "single",
  search = "bottom",
  detail = "bottom",
  show = {
    icons = false,
    subtitles = false,
    accessories = false,
    section_titles = false,
    hints = false,
    key_hints = false,
    scope = false,
  },
}
