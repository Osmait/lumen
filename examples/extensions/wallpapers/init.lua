-- Your wallpapers as a grid of thumbnails. Enter sets one with the command
-- in Settings > Extensions > Wallpapers (swww by default).
local lumen = require("lumen")

local function expand(path) return (path:gsub("^~", os.getenv("HOME"))) end

return lumen.extension {
  title = "Wallpapers",
  icon = "🖼️",
  preferences = {
    { name = "folder", title = "Folder", type = "text", default = "~/Pictures/Wallpapers" },
    {
      name = "command", title = "Set With", type = "text", default = "swww img",
      description = "The command; the picture's path goes last (hyprctl hyprpaper..., feh --bg-fill...)",
    },
  },
  commands = {
    {
      name = "browse",
      title = "Wallpapers",
      grid = true,
      columns = 3,
      items = function()
        local folder = expand(lumen.preferences.folder)
        local out = lumen.exec { "find", folder, "-maxdepth", "2", "-type", "f",
          "(", "-iname", "*.jpg", "-o", "-iname", "*.jpeg", "-o", "-iname", "*.png", "-o", "-iname", "*.webp", ")" }
        local rows = {}
        for path in (out or ""):gmatch("[^\n]+") do
          local argv = {}
          for word in lumen.preferences.command:gmatch("%S+") do argv[#argv + 1] = word end
          argv[#argv + 1] = path
          rows[#rows + 1] = {
            title = path:match("([^/]+)$"),
            image = path,
            actions = {
              lumen.action.exec(argv, "Set as Wallpaper"),
              lumen.action.open(path, "Open"),
              lumen.action.copy(path, "Copy Path"),
            },
          }
        end
        table.sort(rows, function(a, b) return a.title < b.title end)
        return rows
      end,
    },
  },
}
