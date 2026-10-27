-- GitHub through the gh CLI (https://cli.github.com), after `gh auth login`.
local lumen = require("lumen")

-- Runs gh and decodes its JSON; errors show in Lumen's list.
local function gh(args)
  table.insert(args, 1, "gh")
  local out, code, err = lumen.exec(args, { timeout = 20 })
  if not out then error(code, 0) end -- could not run: `code` is the message
  if code ~= 0 then error(err ~= "" and err or "gh exited with " .. code, 0) end
  return lumen.json.decode(out)
end

local function links(url, title)
  return {
    lumen.action.open(url, "Open in Browser"),
    lumen.action.copy(url, "Copy URL"),
    lumen.action.copy(title, "Copy Title"),
  }
end

return lumen.extension {
  title = "GitHub",
  icon = { name = "system-users-symbolic", color = "gray" },
  commands = {
    {
      name = "prs",
      title = "My Pull Requests",
      keywords = { "pr", "review" },
      items = function()
        local rows = {}
        for _, pr in ipairs(gh { "search", "prs", "--author=@me", "--state=open", "--limit=50",
          "--json", "title,url,number,repository" }) do
          rows[#rows + 1] = {
            title = pr.title,
            subtitle = pr.repository.nameWithOwner .. " #" .. pr.number,
            actions = links(pr.url, pr.title),
          }
        end
        return rows
      end,
    },
    {
      name = "issues",
      title = "Issues Assigned to Me",
      items = function()
        local rows = {}
        for _, issue in ipairs(gh { "search", "issues", "--assignee=@me", "--state=open", "--limit=50",
          "--json", "title,url,number,repository" }) do
          rows[#rows + 1] = {
            title = issue.title,
            subtitle = issue.repository.nameWithOwner .. " #" .. issue.number,
            actions = links(issue.url, issue.title),
          }
        end
        return rows
      end,
    },
    {
      name = "repos",
      title = "My Repositories",
      detail = true,
      items = function()
        local rows = {}
        for _, repo in ipairs(gh { "repo", "list", "--limit=200",
          "--json", "name,description,url,isPrivate,stargazerCount,primaryLanguage,updatedAt" }) do
          rows[#rows + 1] = {
            title = repo.name,
            subtitle = repo.description,
            accessory = repo.isPrivate and "Private" or "",
            markdown = "## " .. repo.name .. "\n\n" .. (repo.description or "*No description*")
              .. "\n\n[" .. repo.url .. "](" .. repo.url .. ")",
            metadata = {
              { "Visibility", repo.isPrivate and "Private" or "Public" },
              { "Stars", repo.stargazerCount },
              { "Language", repo.primaryLanguage and repo.primaryLanguage.name or "—" },
              { "Updated", (repo.updatedAt or ""):sub(1, 10) },
            },
            actions = {
              lumen.action.open(repo.url, "Open in Browser"),
              lumen.action.copy("git clone " .. repo.url .. ".git", "Copy Clone Command"),
            },
          }
        end
        return rows
      end,
    },
  },
}
