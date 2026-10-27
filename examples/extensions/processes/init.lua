-- The processes using the most memory; quit one from Lumen.
local lumen = require("lumen")

local function processes()
  local out = lumen.exec { "ps", "-eo", "pid,rss,pcpu,comm,args", "--sort=-rss", "--no-headers" }
  local rows = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local pid, rss, cpu, name, args = line:match("^%s*(%d+)%s+(%d+)%s+([%d.]+)%s+(%S+)%s+(.*)$")
    if pid then
      rows[#rows + 1] = {
        id = pid,
        title = name,
        subtitle = "PID " .. pid .. " · " .. cpu .. "% CPU",
        accessory = string.format("%.0f MB", rss / 1024),
        keywords = args,
        markdown = "**" .. name .. "**\n\n```\n" .. args .. "\n```",
        metadata = {
          { "PID", pid },
          { "Memory", string.format("%.1f MB", rss / 1024) },
          { "CPU", cpu .. "%" },
        },
        -- Quitting needs a second Enter.
        confirm = true,
        actions = {
          { title = "Quit Process", run = function() lumen.exec { "kill", pid } return "refresh" end },
          { title = "Force Quit", run = function() lumen.exec { "kill", "-9", pid } return "refresh" end },
          lumen.action.copy(pid, "Copy PID"),
        },
      }
      if #rows == 60 then break end
    end
  end
  return rows
end

return lumen.extension {
  title = "Processes",
  icon = { name = "utilities-system-monitor-symbolic", color = "green" },
  commands = {
    { name = "top", title = "Top Processes", subtitle = "By memory", detail = true, items = processes },
  },
}
