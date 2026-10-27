-- An emoji picker: a grid you search by name; Enter pastes, Ctrl+Enter copies.
local lumen = require("lumen")

local emoji = {
  { "😀", "grinning face smile happy" }, { "😂", "joy tears laughing" }, { "🥲", "smiling tear" },
  { "😊", "blush smile" }, { "😍", "heart eyes love" }, { "😘", "kiss" }, { "😎", "cool sunglasses" },
  { "🤔", "thinking hmm" }, { "🙄", "eye roll" }, { "😴", "sleeping tired" }, { "😅", "sweat smile" },
  { "😭", "crying sob" }, { "😡", "angry mad" }, { "🤯", "mind blown" }, { "🥳", "party celebrate" },
  { "😱", "scream shock" }, { "🤗", "hug" }, { "🤝", "handshake deal" }, { "👍", "thumbs up yes ok" },
  { "👎", "thumbs down no" }, { "👏", "clap applause" }, { "🙌", "raised hands hooray" }, { "🙏", "pray please thanks" },
  { "💪", "muscle strong" }, { "👀", "eyes look" }, { "👋", "wave hello bye" }, { "✌️", "victory peace" },
  { "🤞", "fingers crossed luck" }, { "👌", "ok hand perfect" }, { "❤️", "red heart love" }, { "💔", "broken heart" },
  { "🔥", "fire hot lit" }, { "✨", "sparkles magic" }, { "⭐", "star" }, { "🌟", "glowing star" },
  { "⚡", "lightning zap" }, { "💯", "hundred perfect" }, { "✅", "check done yes" }, { "❌", "cross no wrong" },
  { "⚠️", "warning" }, { "❓", "question" }, { "❗", "exclamation" }, { "💡", "idea bulb" },
  { "🎉", "tada party" }, { "🎂", "birthday cake" }, { "🎁", "gift present" }, { "🏆", "trophy winner" },
  { "🚀", "rocket launch ship" }, { "💻", "laptop computer" }, { "🖥️", "desktop computer" }, { "⌨️", "keyboard" },
  { "🐛", "bug" }, { "🔧", "wrench fix" }, { "🔨", "hammer build" }, { "⚙️", "gear settings" },
  { "📦", "package box" }, { "📝", "memo note write" }, { "📌", "pin" }, { "📎", "paperclip attach" },
  { "🔒", "lock secure" }, { "🔑", "key" }, { "📅", "calendar date" }, { "⏰", "alarm clock" },
  { "☕", "coffee" }, { "🍕", "pizza" }, { "🍔", "burger" }, { "🍺", "beer" }, { "🍷", "wine" },
  { "🍎", "apple" }, { "🥑", "avocado" }, { "🌮", "taco" }, { "🍣", "sushi" }, { "🍩", "doughnut" },
  { "🐶", "dog" }, { "🐱", "cat" }, { "🦊", "fox" }, { "🐼", "panda" }, { "🦄", "unicorn" },
  { "🐧", "penguin linux" }, { "🦀", "crab rust" }, { "🐍", "snake python" }, { "🦎", "lizard zig" },
  { "🌍", "earth world globe" }, { "🌙", "moon night" }, { "☀️", "sun" }, { "🌈", "rainbow" },
  { "☔", "umbrella rain" }, { "❄️", "snowflake cold" }, { "🌊", "wave ocean" }, { "🌴", "palm tree" },
  { "🏠", "house home" }, { "✈️", "airplane travel" }, { "🚗", "car" }, { "⚽", "soccer football" },
  { "🎵", "music note" }, { "🎮", "video game" }, { "📷", "camera photo" }, { "🎬", "movie film" },
}

return lumen.extension {
  title = "Emoji",
  icon = "😀",
  commands = {
    {
      name = "pick",
      title = "Search Emoji",
      grid = true,
      columns = 8,
      items = function()
        local rows = {}
        for _, e in ipairs(emoji) do
          local name = e[2]:match("^%S+ ?%S*")
          rows[#rows + 1] = {
            title = name,
            icon = e[1],
            keywords = e[2],
            actions = { lumen.action.paste(e[1]), lumen.action.copy(e[1]) },
          }
        end
        return rows
      end,
    },
  },
}
