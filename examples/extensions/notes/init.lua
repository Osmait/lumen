-- Quick notes Lumen keeps for you: "Add Note" to write one, "Notes" to copy
-- or delete them. Shows lumen.storage (data that stays) and preferences
-- (Settings > Extensions > Notes).
local lumen = require("lumen")

local function load() return lumen.storage.get("notes") or {} end
local function save(notes) lumen.storage.set("notes", notes) end

return lumen.extension {
  title = "Notes",
  icon = "📝",
  preferences = {
    {
      name = "order", title = "Order", type = "choice",
      choices = { { value = "newest", title = "Newest First" }, { value = "oldest", title = "Oldest First" } },
    },
    {
      name = "paste", title = "Enter Pastes", type = "toggle", default = false,
      description = "Enter pastes a note into the app you came from instead of copying it",
    },
  },
  commands = {
    {
      name = "add",
      title = "Add Note",
      placeholder = "Type a note...",
      search = function(text)
        if text == "" then return {} end
        return {
          {
            title = "Save “" .. text .. "”",
            actions = { {
              title = "Save Note",
              run = function()
                local notes = load()
                table.insert(notes, { text = text, at = os.time() })
                save(notes)
              end,
            } },
          },
        }
      end,
    },
    {
      name = "list",
      title = "Notes",
      detail = true,
      items = function()
        local rows = {}
        for _, note in ipairs(load()) do
          local enter = lumen.preferences.paste and lumen.action.paste(note.text) or lumen.action.copy(note.text)
          rows[#rows + 1] = {
            id = tostring(note.at) .. note.text,
            title = note.text:match("[^\n]*"),
            accessory = os.date("%b %d, %H:%M", note.at),
            detail = note.text,
            actions = {
              enter,
              {
                title = "Delete Note",
                run = function()
                  local notes = load()
                  for i, n in ipairs(notes) do
                    if n.at == note.at and n.text == note.text then table.remove(notes, i) break end
                  end
                  save(notes)
                  return "refresh"
                end,
              },
            },
          }
        end
        if lumen.preferences.order == "newest" then
          for i = 1, #rows // 2 do rows[i], rows[#rows - i + 1] = rows[#rows - i + 1], rows[i] end
        end
        return rows
      end,
    },
  },
}
