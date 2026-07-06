local M = {}

function M.search_items(items, on_done)
  if not items or #items == 0 then
    vim.notify("zotero: no items to search", vim.log.levels.INFO)
    return
  end

  local be = require("zotero.backends")
  local tel = require("telescope")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local finders = require("telescope.finders")
  local pickers = require("telescope.pickers")

  local entries = {}
  for _, item in ipairs(items) do
    table.insert(entries, {
      value = item,
      display = be.item_display(item),
      ordinal = item.title or "",
    })
  end

  local picker = pickers.new({}, {
    prompt_title = "Zotero",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e) return e end,
    }),
    sorter = require("telescope.config").values.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local prompt = action_state.get_current_picker(prompt_bufnr):get_prompt()
        actions.close(prompt_bufnr)
        if prompt and prompt ~= "" then
          on_done(prompt)
        end
      end)
      return true
    end,
  })
  picker:find()
end

return M
