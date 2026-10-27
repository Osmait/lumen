-- "New File": a form that creates a text file where you say. Shows forms:
-- fields like preferences, and submit(values) when you are done.
local lumen = require("lumen")

local home = os.getenv("HOME")

return lumen.extension {
  title = "New File",
  icon = "📄",
  commands = {
    {
      name = "create",
      title = "New File",
      subtitle = "Create a text file",
      fields = {
        { name = "name", title = "File Name", type = "text", required = true, description = "notes.md, todo.txt..." },
        {
          name = "folder", title = "Folder", type = "choice",
          choices = {
            { value = home .. "/Documents", title = "Documents" },
            { value = home .. "/Desktop", title = "Desktop" },
            { value = home, title = "Home" },
          },
        },
        { name = "content", title = "First Line", type = "text" },
        { name = "open", title = "Open It", type = "toggle", default = true },
      },
      submit_title = "Create File",
      submit = function(values)
        local path = values.folder .. "/" .. values.name
        if io.open(path, "r") then error(values.name .. " already exists", 0) end
        local f = assert(io.open(path, "w"))
        f:write(values.content ~= "" and values.content .. "\n" or "")
        f:close()
        if values.open then lumen.exec { "gio", "open", path } end
      end,
    },
  },
}
