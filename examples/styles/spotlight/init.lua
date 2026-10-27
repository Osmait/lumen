-- Lumen dressed as macOS Spotlight: a large search field with a magnifier,
-- one translucent panel, compact rows with only their titles, macOS blue.
-- Copy this file to ~/.config/lumen/init.lua and style.css beside it.
local lumen = require("lumen")

lumen.theme {
  id = "spotlight", name = "Spotlight", dark = true,
  bg = "#1e1e20", surface = "#2a2a2d", fg = "#f2f2f4", ink = "#ffffff", accent = "#0a84ff",
}

lumen.set { theme = "spotlight", density = "compact", opacity = 90 }

lumen.layout {
  width = 680,
  height = 460,
  position = "upper_third",
  panels = "single",
  show = {
    search_icon = true,
    hints = false,
    key_hints = false,
    subtitles = false,
  },
}
