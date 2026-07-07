local M = {}

function M.setup()
  local hl = vim.api.nvim_set_hl

  hl(0, "ZoteroDetailBackdrop", { bg = "Black" })
  hl(0, "ZoteroItemCount", { fg = "#888888" })
  hl(0, "ZoteroCollectionArrow", { fg = "#666666" })

  hl(0, "ZoteroHeader", { bold = true, fg = "#ffffff" })
  hl(0, "ZoteroLabel", { bold = true, fg = "#88aaff" })
  hl(0, "ZoteroValue", { fg = "#cccccc" })
  hl(0, "ZoteroTag", { fg = "#88ddaa" })
  hl(0, "ZoteroNoteTitle", { fg = "#ffaa88", bold = true })
  hl(0, "ZoteroAttachment", { fg = "#aaccff" })

  hl(0, "ZoteroItemTitle", { fg = "#ffffff" })
  hl(0, "ZoteroItemAuthor", { fg = "#aaaaaa" })
  hl(0, "ZoteroItemYear", { fg = "#88aaff" })
  hl(0, "ZoteroItemType", { fg = "#66dd88" })
  hl(0, "ZoteroItemKey", { fg = "#ffcc66" })
  hl(0, "ZoteroItemMarker", { fg = "#ffaa00", bold = true })
  hl(0, "ZoteroSeparator", { fg = "#444444" })
end

return M
