-- Lumen dressed as Omarchy's menu (Super+Space in Omarchy 4): one square
-- card with a 2px border in the text colour, no shadow, monospace, a plain
-- search line saying "Go…", and the selected row lifted a little, its text
-- in the accent colour. The whole screen dims behind it.
--
-- On Omarchy it follows the theme you pick there (it reads
-- ~/.local/state/omarchy/current/theme/colors.toml); elsewhere it starts on
-- Tokyo Night. All 23 Omarchy palettes are in Change Theme ("Your Themes").
--
-- Copy this file to ~/.config/lumen/init.lua and style.css beside it.
local lumen = require("lumen")

-- A palette to always use ("omarchy-nord", "omarchy-gruvbox"...), or nil:
-- Omarchy's current theme, else Tokyo Night.
local pick = nil

-- Omarchy's palettes: id, name, dark, background, lighter background
-- (the action panel), foreground, accent. From omacom/omarchy's
-- themes/*/colors.toml.
local palettes = {
  { "catppuccin-latte", "Catppuccin Latte", false, "#eff1f5", "#dce0e8", "#4c4f69", "#1e66f5" },
  { "catppuccin", "Catppuccin", true, "#1e1e2e", "#313244", "#cdd6f4", "#89b4fa" },
  { "ethereal", "Ethereal", true, "#060b1e", "#131a3a", "#ffcead", "#7d82d9" },
  { "everforest", "Everforest", true, "#2d353b", "#343f44", "#d3c6aa", "#7fbbb3" },
  { "flexoki-light", "Flexoki Light", false, "#fffcf0", "#e6e4d9", "#100f0f", "#205ea6" },
  { "gruvbox", "Gruvbox", true, "#282828", "#3c3836", "#d4be98", "#7daea3" },
  { "hackerman", "Hackerman", true, "#0b0c16", "#151828", "#ddf7ff", "#82fb9c" },
  { "jade-horse", "Jade Horse", true, "#142620", "#203b31", "#dfede5", "#8bcbb1" },
  { "kanagawa", "Kanagawa", true, "#1f1f28", "#223249", "#dcd7ba", "#dcd7ba" },
  { "last-horizon", "Last Horizon", true, "#0c0b0c", "#0c0b0c", "#fafcfb", "#b59790" },
  { "lumon", "Lumon", true, "#16242d", "#1b2d40", "#d6e2ee", "#8bc9eb" },
  { "lupine", "Lupine", false, "#fafafa", "#f5f5f5", "#212121", "#3264eb" },
  { "matte-black", "Matte Black", true, "#121212", "#1e1e1e", "#bebebe", "#e68e0d" },
  { "miasma", "Miasma", true, "#222222", "#2c2c2c", "#c2c2b0", "#78824b" },
  { "nord", "Nord", true, "#2e3440", "#3b4252", "#d8dee9", "#81a1c1" },
  { "retro-82", "Retro 82", true, "#05182e", "#0a2540", "#f6dcac", "#faa968" },
  { "ristretto", "Ristretto", true, "#2c2525", "#3d2f2a", "#e6d9db", "#f38d70" },
  { "rose-pine", "Rosé Pine", false, "#faf4ed", "#f2e9e1", "#575279", "#56949f" },
  { "solitude", "Solitude", true, "#101315", "#101315", "#cacccc", "#798186" },
  { "starship", "Starship", true, "#1c1c1e", "#2c2c2e", "#f5f5f7", "#ff9f0a" },
  { "tokyo-night", "Tokyo Night", true, "#1a1b26", "#24283b", "#a9b1d6", "#7aa2f7" },
  { "vantablack", "Vantablack", true, "#000000", "#1a1a1a", "#ffffff", "#8d8d8d" },
  { "white", "White", false, "#ffffff", "#c0c0c0", "#000000", "#6e6e6e" },
}

for _, p in ipairs(palettes) do
  lumen.theme {
    id = "omarchy-" .. p[1], name = "Omarchy " .. p[2], dark = p[3],
    bg = p[4], surface = p[5], fg = p[6], ink = p[6], accent = p[7],
  }
end

-- The theme Omarchy is using now, as "Omarchy (current)".
local function current()
  local f = io.open(os.getenv("HOME") .. "/.local/state/omarchy/current/theme/colors.toml", "r")
  if not f then return nil end
  local c = {}
  for line in f:lines() do
    local key, value = line:match('^%s*([%w_]+)%s*=%s*"(#%x%x%x%x%x%x)"')
    if key then c[key] = value:lower() end
  end
  f:close()
  if not (c.background and c.foreground and c.accent) then return nil end
  lumen.theme {
    id = "omarchy", name = "Omarchy (current)", dark = c.mode ~= "light",
    bg = c.background, surface = c.lighter_background or c.background,
    fg = c.foreground, ink = c.foreground, accent = c.accent,
  }
  return "omarchy"
end

lumen.set {
  theme = pick or current() or "omarchy-tokyo-night",
  density = "default",
  opacity = 100,
}

lumen.layout {
  width = 760,
  height = 520,
  position = "center",
  panels = "single",
  placeholder = "Go…",
  show = {
    hints = false,
    key_hints = false,
    accessories = false,
    section_titles = false,
    scope = false,
    back = false,
  },
}
