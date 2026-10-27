-- Lumen dressed as Alfred: a framed search field inside one panel, tall
-- rows with large icons and their subtitles under them, no footer.
-- Copy this file to ~/.config/lumen/init.lua and style.css beside it.
local lumen = require("lumen")

lumen.theme {
  id = "alfred", name = "Alfred", dark = true,
  bg = "#262628", surface = "#303033", fg = "#f0f0f0", ink = "#ffffff", accent = "#5a5a60",
}

lumen.set { theme = "alfred", density = "comfortable", opacity = 100 }

lumen.layout {
  width = 680,
  height = 520,
  position = "upper_third",
  panels = "single",
  show = { hints = false, key_hints = false, section_titles = false, accessories = false },
}
