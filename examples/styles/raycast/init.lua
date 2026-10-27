-- Lumen dressed as Raycast: one panel, a footer that says what Enter does,
-- subtitles beside titles, a quiet grey selection.
-- Copy this file to ~/.config/lumen/init.lua and style.css beside it
-- (or paste the lines below into your own init.lua).
local lumen = require("lumen")

lumen.theme {
  id = "raycast", name = "Raycast", dark = true,
  bg = "#1c1c1e", surface = "#26262a", fg = "#ececee", ink = "#ffffff", accent = "#ff6363",
}

lumen.set { theme = "raycast", density = "compact" }

lumen.layout {
  width = 750,
  height = 475,
  position = "upper_third",
  panels = "single",
  footer = true,
  rows = "inline",
  show = { hints = false, key_hints = false },
}
