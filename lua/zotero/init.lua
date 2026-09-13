local M = {}

local db = require("zotero.db")
local types = require("zotero.types")
local async_mod = require("zotero.async")

function M.open_library()
  local cfg = require("zotero.config").get()
  if not cfg.db_path then
    async_mod.notify("zotero: no database path configured. Set db_path in setup().", vim.log.levels.ERROR)
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

  local collections = require("zotero.ui.collections")
  local items = require("zotero.ui.items")

  items.set_keymaps()
  vim.api.nvim_set_current_win(layout.get_items_win())

  -- Repaint both panes synchronously from the last in-memory render so
  -- reopening is instant; only fall back to the async (re)query when the
  -- underlying data may have changed since the previous render.
  local items_fresh = items.restore_render()
  local collections_fresh = collections.restore_render()

  if not (items_fresh and collections_fresh) then
    collections.render()
    items.restore_session()
  end
end

function M.fuzzy_find()
  local cfg = require("zotero.config").get()
  if not cfg.db_path then
    async_mod.notify("zotero: no database path configured", vim.log.levels.ERROR)
    return
  end

  if not require("zotero.ui.layout").is_open() then
    M.open_library()
  end

  async_mod.run("zotero:fuzzy_find", function()
    local col_id = require("zotero.ui.collections").get_selected_collection_id()
    local items = col_id and async_mod.await(db.get_items(col_id)) or async_mod.await(db.search_global(""))

    -- load authors
    if #items > 0 then
      local item_ids = vim.tbl_map(function(i) return i.itemID end, items)
      local all_creators = async_mod.await(db.get_items_authors(item_ids))
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

    async_mod.to_main()

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
  end)
end

function M.setup(opts)
  require("zotero.config").set(opts)

  local cfg = require("zotero.config").get()
  if cfg.keymaps.enabled and cfg.keymaps.open_library then
    vim.keymap.set("n", cfg.keymaps.open_library, function()
      M.open_library()
    end, { desc = "toggle library browser" })
  end

  if cfg.keymaps.enabled and cfg.keymaps.fuzzy_find then
    vim.keymap.set("n", cfg.keymaps.fuzzy_find, function()
      M.fuzzy_find()
    end, { desc = "search items" })
  end
end

function M.debug()
  local cfg = require("zotero.config").get()
  print(string.format(
    "zotero: db_path=%s readable=%s",
    tostring(cfg.db_path),
    vim.fn.filereadable(cfg.db_path or "") == 1 and "yes" or "no"
  ))
  if cfg.db_path and vim.fn.filereadable(cfg.db_path) == 1 then
    async_mod.run("zotero:debug.stats", function()
      local ok, dbb = pcall(require, "zotero.db")
      if ok then
        local stats = async_mod.await(dbb.get_stats())
        print(string.format("  collections: %d  items: %d", stats.collections, stats.items))
      end
    end)
  end
end

return M