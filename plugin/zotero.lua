if vim.g.loaded_zotero == 1 then
  return
end
vim.g.loaded_zotero = 1

local async_mod = require("zotero.async")
local db = require("zotero.db")

vim.api.nvim_create_user_command("Zotero", function()
  require("zotero").open_library()
end, { desc = "Open Zotero library browser" })

vim.api.nvim_create_user_command("ZoteroDebug", function()
  require("zotero").debug()
end, { desc = "Zotero debug info" })

vim.api.nvim_create_user_command("ZoteroImport", function(opts)
  require("zotero.api").import_pdf(opts.args)
end, { desc = "Import a PDF into Zotero", nargs = 1, complete = "file" })

vim.api.nvim_create_user_command("ZoteroMaxItems", function(opts)
  local n = tonumber(opts.args)
  if not n or n < 1 then
    async_mod.notify("zotero: max_items must be a positive integer", vim.log.levels.ERROR)
    return
  end
  require("zotero.config").options.max_items = n
  async_mod.notify("zotero: max_items set to " .. n, vim.log.levels.INFO)
  require("zotero.ui.items").fetch_and_render(true)
end, { nargs = 1, desc = "Set the maximum number of items to display (e.g. :ZoteroMaxItems 100)" })

local function set_date_cmd(postfix, label, fn)
  return function(opts)
    local items = require("zotero.ui.items")
    local item = items.get_current_item()
    if not item then
      async_mod.notify("zotero: no item under cursor", vim.log.levels.ERROR)
      return
    end
    local function apply(input)
      if input and input ~= "" then
        async_mod.run("zotero:set_date", function()
          local item_key = async_mod.await(db.get_item_key(item.itemID))
          if not item_key or item_key == "" then
            async_mod.notify("zotero: cannot determine item key", vim.log.levels.ERROR)
            return
          end
          async_mod.await(fn(item_key, vim.trim(input)))
          async_mod.to_main()
          items.fetch_and_render(true)
        end)
      end
    end
    if opts.args and opts.args ~= "" then
      apply(opts.args)
    else
      vim.ui.input({ prompt = label }, apply)
    end
  end
end

vim.api.nvim_create_user_command("ZoteroSetDateAdded",
  set_date_cmd("DateAdded", "Date added (YYYY-MM-DD): ",
    function(k, v) require("zotero.api").set_date_added(k, v) end),
  { nargs = "?", desc = "Set the date added for the item under cursor" })

vim.api.nvim_create_user_command("ZoteroSetDateModified",
  set_date_cmd("DateModified", "Date modified (YYYY-MM-DD): ",
    function(k, v) require("zotero.api").set_date_modified(k, v) end),
  { nargs = "?", desc = "Set the date modified for the item under cursor" })
