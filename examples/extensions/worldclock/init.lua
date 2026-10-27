-- The time anywhere: type "time tokyo" (or "tokyo time") in Lumen's search,
-- or open "World Clock" for every city. Shows `root`: rows in the main
-- search, next to the calculator.
local lumen = require("lumen")

local cities = {
  { "Tokyo", "Asia/Tokyo" },
  { "Sydney", "Australia/Sydney" },
  { "Berlin", "Europe/Berlin" },
  { "Madrid", "Europe/Madrid" },
  { "London", "Europe/London" },
  { "New York", "America/New_York" },
  { "Santo Domingo", "America/Santo_Domingo" },
  { "Mexico City", "America/Mexico_City" },
  { "Buenos Aires", "America/Argentina/Buenos_Aires" },
  { "Los Angeles", "America/Los_Angeles" },
}

local function row(city)
  local out = lumen.exec { "env", "TZ=" .. city[2], "date", "+%H:%M|%A %d %B" }
  local time, day = (out or ""):match("^(.-)|(.-)\n?$")
  return {
    title = time or "?",
    subtitle = city[1] .. " · " .. (day or ""),
    keywords = city[2],
    actions = { lumen.action.copy((time or "") .. " " .. city[1], "Copy Time") },
  }
end

return lumen.extension {
  title = "World Clock",
  icon = "🕐",
  commands = {
    {
      name = "clocks",
      title = "World Clock",
      items = function()
        local rows = {}
        for _, city in ipairs(cities) do rows[#rows + 1] = row(city) end
        return rows
      end,
    },
    {
      -- Only `root`: no command of its own, rows in the main search.
      name = "time",
      title = "World Clock",
      root = function(query)
        local q = query:lower()
        local wanted = q:match("^time%s+in%s+(.+)$") or q:match("^time%s+(.+)$") or q:match("^(.+)%s+time$")
        if not wanted then return nil end
        local rows = {}
        for _, city in ipairs(cities) do
          if city[1]:lower():find(wanted, 1, true) then rows[#rows + 1] = row(city) end
        end
        return rows
      end,
    },
  },
}
