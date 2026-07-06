local M = {}

function M.search_items(items, on_done)
  if not items or #items == 0 then
    vim.notify("zotero: no items to search", vim.log.levels.INFO)
    return
  end

  local be = require("zotero.backends")
  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, be.item_display(item))
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(lines, {
    prompt = "Zotero> ",
    actions = {
      ["default"] = function()
        local query = fzf.get_last_query()
        if query and query ~= "" then
          on_done(query)
        end
      end,
    },
  })
end

return M
