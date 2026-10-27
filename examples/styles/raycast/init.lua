-- Lumen dressed as Raycast: one panel, a footer that says what Enter does,
-- subtitles beside titles, a quiet grey selection.
-- Built into Lumen: pick it in Change Theme > Styles. To change it, copy
-- this folder to ~/.config/lumen/styles/raycast and edit it there.
local lumen = require("lumen")

lumen.theme {
  id = "raycast", name = "Raycast", dark = true,
  bg = "#1c1c1e", surface = "#26262a", fg = "#ececee", ink = "#ffffff", accent = "#ff6363",
}

lumen.set { theme = "raycast", density = "compact", opacity = 97 }

lumen.layout {
  width = 750,
  height = 475,
  position = "upper_third",
  panels = "single",
  footer = true,
  rows = "inline",
  show = { hints = false, key_hints = false },
}
