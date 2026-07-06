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
