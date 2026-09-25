local M = {}

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

function M.setup(opts)
  require("zotero.config").set(opts)

  local cfg = require("zotero.config").get()
  if cfg.keymaps.enabled and cfg.keymaps.open_library then
    vim.keymap.set("n", cfg.keymaps.open_library, function()
      M.open_library()
    end, { desc = "toggle library browser" })
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
        async_mod.to_main()
        print(string.format("  collections: %d  items: %d", stats.collections, stats.items))
      end
    end)
  end
end

return M