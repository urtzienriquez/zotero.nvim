local M = {}

function M.item_display(item)
  local title = item.title or "(no title)"
  local authors = item._authors or ""
  local year = item.year or ""
  local parts = { title }
  if authors ~= "" then
    table.insert(parts, authors)
  end
  if year ~= "" then
    table.insert(parts, tostring(year))
  end
  return table.concat(parts, " | ")
end

function M.search_items(items, on_done)
  local cfg = require("zotero.config").get()
  local backend = cfg.backend
  if not backend then
    vim.ui.input({ prompt = "Search Zotero: " }, function(input)
      if input then
        on_done(input)
      end
    end)
    return
  end
  local ok, mod = pcall(require, "zotero.backends." .. backend)
  if not ok then
    vim.notify("zotero: backend '" .. backend .. "' not found", vim.log.levels.ERROR)
    return
  end
  mod.search_items(items, on_done)
end

return M
