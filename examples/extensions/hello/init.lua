-- A small extension showing the three kinds of command.
-- Copy this folder to ~/.config/lumen/extensions/hello and open Lumen.
local lumen = require("lumen")

return lumen.extension {
  title = "Hello",
  icon = "👋",
  -- Settings > Extensions > Hello; read as lumen.preferences.name.
  preferences = {
    { name = "name", title = "Your Name", type = "text", description = "Used by What Time Is It" },
  },
  commands = {
    -- A list: Lumen filters it as you type.
    {
      name = "greetings",
      title = "Greetings",
      subtitle = "Hello in other languages",
      detail = true,
      items = {
        {
          title = "Hola", subtitle = "Spanish", detail = "Hola, ¿qué tal?",
          actions = { lumen.action.paste("Hola"), lumen.action.copy("Hola") },
        },
        {
          title = "Bonjour", subtitle = "French", detail = "Bonjour, ça va ?",
          actions = { lumen.action.paste("Bonjour"), lumen.action.copy("Bonjour") },
        },
        {
          title = "こんにちは", subtitle = "Japanese", keywords = "konnichiwa",
          detail = "こんにちは、元気ですか？",
          actions = { lumen.action.paste("こんにちは"), lumen.action.copy("こんにちは") },
        },
      },
    },

    -- A search: asked again for every query.
    {
      name = "shout",
      title = "Shout",
      placeholder = "Type something to shout...",
      search = function(query)
        if query == "" then return {} end
        local loud = query:upper() .. "!"
        return {
          { title = loud, actions = { lumen.action.paste(loud), lumen.action.copy(loud) } },
        }
      end,
    },

    -- No list: Enter runs it.
    {
      name = "time",
      title = "What Time Is It",
      icon = "🕒",
      run = function()
        local name = lumen.preferences.name
        lumen.notify("It is " .. os.date("%H:%M") .. (name ~= "" and ", " .. name or ""))
      end,
    },
  },
}
