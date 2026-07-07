local M = {}

local db = require("zotero.db")
local types = require("zotero.types")

function M.open_library()
  local cfg = require("zotero.config").get()
  if not cfg.db_path then
    vim.notify("zotero: no database path configured. Set db_path in setup().", vim.log.levels.ERROR)
    return
  end

  local layout = require("zotero.ui.layout")
  if layout.is_open() then
    layout.close()
    return
  end

  require("zotero.ui.highlights").setup()

  layout.create_layout()
  layout.set_keymaps()

  require("zotero.ui.collections").render()
  require("zotero.ui.items").set_keymaps()
  require("zotero.ui.items").restore_session()

  vim.api.nvim_set_current_win(layout.get_items_win())
end

function M.fuzzy_find()
  local cfg = require("zotero.config").get()
  if not cfg.db_path then
    vim.notify("zotero: no database path configured", vim.log.levels.ERROR)
    return
  end

  if not require("zotero.ui.layout").is_open() then
    M.open_library()
  end

  local col_id = require("zotero.ui.collections").get_selected_collection_id()
  local items = col_id and db.get_items(col_id) or db.search_global("")

  -- load authors
  if #items > 0 then
    local item_ids = vim.tbl_map(function(i) return i.itemID end, items)
    local all_creators = db.get_items_authors(item_ids)
    local creators_by_item = {}
    for _, c in ipairs(all_creators) do
      creators_by_item[c.itemID] = creators_by_item[c.itemID] or {}
      table.insert(creators_by_item[c.itemID], c)
    end
    for _, item in ipairs(items) do
      item._authors = types.format_creators(creators_by_item[item.itemID] or {})
      item._authors_compact = types.format_creators_compact(creators_by_item[item.itemID] or {})
    end
  end

  require("zotero.backends").search_items(items, function(query)
    local words = vim.split(vim.trim(query), "%s+")
    local function fuzzy_find(text, pattern)
      local p = 1
      for i = 1, #pattern do
        local byte = pattern:byte(i)
        p = text:find(string.char(byte), p, true)
        if not p then
          return false
        end
        p = p + 1
      end
      return true
    end
    local results = {}
    for _, item in ipairs(items) do
      local text = ((item.title or "") .. " │ " .. (item._authors or "") .. " │ " .. tostring(item.year or "")):lower()
      local match = true
      for _, word in ipairs(words) do
        if not fuzzy_find(text, word:lower()) then
          match = false
          break
        end
      end
      if match then
        table.insert(results, item)
      end
    end
    require("zotero.ui.items").show_results(results)
  end)
end

function M.setup(opts)
  require("zotero.config").set(opts)

  local cfg = require("zotero.config").get()
  if cfg.keymaps.enabled and cfg.keymaps.open_library then
    vim.keymap.set("n", cfg.keymaps.open_library, function()
      M.open_library()
    end, { desc = "zotero: open library browser" })
  end

  vim.keymap.set("n", "<leader>zf", function()
    M.fuzzy_find()
  end, { desc = "zotero: search items" })
end

function M.debug()
  local cfg = require("zotero.config").get()
  print(string.format(
    "zotero: db_path=%s readable=%s",
    tostring(cfg.db_path),
    vim.fn.filereadable(cfg.db_path or "") == 1 and "yes" or "no"
  ))
  if cfg.db_path and vim.fn.filereadable(cfg.db_path) == 1 then
    local ok, db = pcall(require, "zotero.db")
    if ok then
      local stats = db.get_stats()
      print(string.format("  collections: %d  items: %d", stats.collections, stats.items))
    end
  end
end

return M
