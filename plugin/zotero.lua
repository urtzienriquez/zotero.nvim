if vim.g.loaded_zotero == 1 then
  return
end
vim.g.loaded_zotero = 1

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
    vim.notify("zotero: max_items must be a positive integer", vim.log.levels.ERROR)
    return
  end
  require("zotero.config").options.max_items = n
  vim.notify("zotero: max_items set to " .. n, vim.log.levels.INFO)
  require("zotero.ui.items").fetch_and_render(true)
end, { nargs = 1, desc = "Set the maximum number of items to display (e.g. :ZoteroMaxItems 100)" })
