-- items_filter_tag (fT): a checklist of the tags in the current view. Checked
-- tags are required: the items list shows only items that have all of them
-- (Zotero's tag-selector logic). The filter itself is items.lua's tag_filter
-- (a list of tag names); this module draws it and maps checklist actions.
local M = {}

local async_mod = require("zotero.async")
local checklist = require("zotero.ui.checklist")

M.DOT = "●"

-- Filter (list of required tag names) after flipping `name`.
function M.toggle(filter, name)
  if vim.tbl_contains(filter, name) then
    return vim.tbl_filter(function(t) return t ~= name end, filter)
  end
  local new = vim.deepcopy(filter)
  new[#new + 1] = name
  return new
end

function M.only(name)
  return { name }
end

function M.all()
  return {}
end

-- Tags in display order: Zotero's colored tags first, in key order (always
-- listed, like Zotero's tag selector, so t1-t9 stay discoverable), then the
-- rest as given (db.get_tag_counts is name-sorted), then filter tags that
-- have no items here so they can still be unchecked.
-- Returns { name, count, index? } where index is the colored tag's key.
function M.ordered(counts, filter, colored)
  local count_of, rows, seen = {}, {}, {}
  for _, c in ipairs(counts) do
    count_of[c.name] = c.count
  end
  for i, t in ipairs(colored or {}) do
    rows[#rows + 1] = { name = t.name, count = count_of[t.name] or 0, index = i }
    seen[t.name] = true
  end
  for _, c in ipairs(counts) do
    if not seen[c.name] then
      rows[#rows + 1] = { name = c.name, count = c.count }
      seen[c.name] = true
    end
  end
  for _, name in ipairs(filter or {}) do
    if not seen[name] then
      rows[#rows + 1] = { name = name, count = 0 }
      seen[name] = true
    end
  end
  return rows
end

-- "1 ● " (dot in the tag's colour) for colored tags, blank padding of the
-- same width for the others so names line up. Returns prefix, prefix_hls.
function M.prefix(index, any_colored)
  if index then
    local head = tostring(index) .. " "
    return head .. M.DOT .. " ", { { #head, #head + #M.DOT, "ZoteroTagColor" .. index } }
  end
  return any_colored and "    " or "", nil
end

-- Checklist rows: M.ordered() plus the "1 ● " prefix.
function M.rows(counts, filter, colored)
  local rows = M.ordered(counts, filter, colored)
  local any_colored = colored and #colored > 0
  for _, r in ipairs(rows) do
    r.prefix, r.prefix_hls = M.prefix(r.index, any_colored)
  end
  return rows
end

function M.close()
  checklist.close("tag_filter")
end

function M.is_open()
  return checklist.is_open("tag_filter")
end

-- Opens the checklist for the current view. Must be called from inside an
-- async task (it queries the tag counts).
function M.open()
  local items = require("zotero.ui.items")
  local db = require("zotero.db")
  local ctx = items.get_view_context()
  local t_counts = db.get_tag_counts(ctx.collection_id, ctx.library_id)
  local t_colored = db.get_colored_tags()
  local counts = async_mod.await(t_counts) or {}
  local colored = async_mod.await(t_colored) or {}
  async_mod.to_main()

  require("zotero.ui.highlights").set_tag_colors(colored)
  checklist.open({
    id = "tag_filter",
    title = " Tags ",
    filetype = "zotero-tag-filter",
    help_tag = "zotero-tag-filter",
    empty_text = "  (no tags in this view)",
    rows = M.rows(counts, items.get_tag_filter(), colored),
    is_checked = function(row)
      return vim.tbl_contains(items.get_tag_filter(), row.name)
    end,
    on_toggle = function(row)
      items.set_tag_filter(M.toggle(items.get_tag_filter(), row.name))
    end,
    on_only = function(row)
      items.set_tag_filter(M.only(row.name))
    end,
    on_all = function()
      items.set_tag_filter(M.all())
    end,
  })
end

return M
