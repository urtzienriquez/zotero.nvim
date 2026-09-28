local M = {}

function M.setup()
  local hl = vim.api.nvim_set_hl

  hl(0, "ZoteroDetailBackdrop", { bg = "Black" })
  hl(0, "ZoteroItemCount", { fg = "#888888" })
  -- The collections split looks like fugitive's status window and sessman's
  -- pane, with the same standard groups, so it follows the colorscheme.
  -- `default`: a user's own definition wins.
  hl(0, "ZoteroCollectionArrow", { link = "Comment", default = true })
  hl(0, "ZoteroCollectionsLabel", { link = "Label", default = true }) -- Viewing: Filter: Help:
  hl(0, "ZoteroCollectionsValue", { link = "Directory", default = true })
  hl(0, "ZoteroCollectionsFilter", { link = "WarningMsg", default = true })
  hl(0, "ZoteroCollectionsHelp", { link = "Tag", default = true })
  hl(0, "ZoteroCollectionsHeading", { link = "PreProc", default = true }) -- My Library, Feeds, Tags
  hl(0, "ZoteroCollectionsCount", { link = "Comment", default = true })

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
  hl(0, "ZoteroFeedUnread", { fg = "#88aaff", bold = true })
end

-- ZoteroTagColor1..9: one highlight group per Zotero colored tag, using the
-- colour assigned in Zotero (tag selector -> Assign Colour). `colored` is
-- db.get_colored_tags() output; the index is the tag's number key.
function M.set_tag_colors(colored)
  for i, tag in ipairs(colored or {}) do
    local color = type(tag.color) == "string" and tag.color:match("^#%x%x%x%x%x%x$") and tag.color or nil
    vim.api.nvim_set_hl(0, "ZoteroTagColor" .. i, color and { fg = color, bold = true } or { link = "ZoteroItemMarker" })
  end
end

return M
