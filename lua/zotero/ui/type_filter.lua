-- items_filter_type (ft): a small floating checklist of the item types in the current
-- view. Each type is either visible ([x]) or hidden ([ ]); changes apply to
-- the items list immediately.
--
-- The filter itself stays items.lua's { mode, types }: "exclude" hides
-- `types`, "include" shows only `types`. The checklist hides that
-- distinction -- the pure helpers below map checkbox actions onto it.
local M = {}

local async_mod = require("zotero.async")

-- Whether `name` is currently shown under `filter`.
function M.is_visible(filter, name)
  local listed = vim.tbl_contains(filter.types, name)
  if filter.mode == "include" and #filter.types > 0 then
    return listed
  end
  return not listed
end

-- Filter after flipping `name`'s visibility.
function M.toggle(filter, name)
  local types = vim.deepcopy(filter.types)
  local listed = vim.tbl_contains(types, name)
  if listed then
    types = vim.tbl_filter(function(t) return t ~= name end, types)
  else
    types[#types + 1] = name
  end
  if filter.mode == "include" and #filter.types > 0 then
    -- Unchecking the last visible type means "no restriction", not "nothing".
    if #types == 0 then
      return { mode = "exclude", types = {} }
    end
    return { mode = "include", types = types }
  end
  return { mode = "exclude", types = types }
end

function M.only(name)
  return { mode = "include", types = { name } }
end

function M.all()
  return { mode = "exclude", types = {} }
end

-- Rows for the checklist: every type present in the view (with its count),
-- plus any type the filter mentions that isn't present (count 0) so it can
-- still be unchecked/rechecked. `counts` is db.get_type_counts() output,
-- already ordered by count.
function M.rows(counts, filter)
  local rows, seen = {}, {}
  for _, c in ipairs(counts) do
    rows[#rows + 1] = { name = c.typeName, count = c.count }
    seen[c.typeName] = true
  end
  for _, t in ipairs(filter.types) do
    if not seen[t] then
      rows[#rows + 1] = { name = t, count = 0 }
      seen[t] = true
    end
  end
  return rows
end

local checklist = require("zotero.ui.checklist")

function M.close()
  checklist.close("type_filter")
end

function M.is_open()
  return checklist.is_open("type_filter")
end

-- Opens the checklist for the current view. Must be called from inside an
-- async task (it queries the type counts).
function M.open()
  local items = require("zotero.ui.items")
  local ctx = items.get_view_context()
  local counts = async_mod.await(require("zotero.db").get_type_counts(ctx.collection_id, ctx.library_id)) or {}
  async_mod.to_main()

  local function apply(filter)
    items.set_type_filter(filter.mode, filter.types)
  end
  checklist.open({
    id = "type_filter",
    title = " Item types ",
    filetype = "zotero-type-filter",
    help_tag = "zotero-type-filter",
    empty_text = "  (no items in this view)",
    rows = M.rows(counts, items.get_type_filter()),
    is_checked = function(row)
      return M.is_visible(items.get_type_filter(), row.name)
    end,
    on_toggle = function(row)
      apply(M.toggle(items.get_type_filter(), row.name))
    end,
    on_only = function(row)
      apply(M.only(row.name))
    end,
    on_all = function()
      apply(M.all())
    end,
  })
end

return M
