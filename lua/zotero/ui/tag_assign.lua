-- items_toggle_tag (tt): a checklist of all tags showing which the item(s)
-- under the cursor / in the visual selection have: [x] all of them, [~]
-- some of them, [ ] none. <CR>/<Space> toggles the tag under the cursor on
-- the item(s) straight away (Zotero's rule: if every item has it, it is
-- removed from all, otherwise added to all), so several tags can be set in
-- one go; `n` adds a new tag. Zotero's colored tags come first.
local M = {}

local async_mod = require("zotero.async")
local checklist = require("zotero.ui.checklist")
local tag_filter = require("zotero.ui.tag_filter")

-- Checkbox state of tag `name` for the items `item_ids`, given `has`
-- (itemID -> { tag_name = true }): true if every item has it, "partial" if
-- only some do, false if none.
function M.state(has, item_ids, name)
  local count = 0
  for _, id in ipairs(item_ids) do
    if has[id] and has[id][name] then
      count = count + 1
    end
  end
  if count == 0 then
    return false
  end
  return count == #item_ids or "partial"
end

function M.is_open()
  return checklist.is_open("tag_assign")
end

function M.close()
  checklist.close("tag_assign")
end

-- Opens the checklist for `list` (items from the items pane). Must be called
-- from inside an async task (it queries the tags).
function M.open(list)
  local db = require("zotero.db")
  local items = require("zotero.ui.items")
  local ids = vim.tbl_map(function(i) return i.itemID end, list)

  local t_counts = db.get_tag_counts(nil, nil)
  local t_colored = db.get_colored_tags()
  local counts = async_mod.await(t_counts) or {}
  local colored = async_mod.await(t_colored) or {}
  local names = vim.tbl_map(function(c) return c.name end, counts)
  for _, t in ipairs(colored) do
    names[#names + 1] = t.name
  end
  local has = async_mod.await(db.get_items_tags(ids, names)) or {}
  async_mod.to_main()

  require("zotero.ui.highlights").set_tag_colors(colored)
  local title
  if #list == 1 then
    local t = type(list[1].title) == "string" and list[1].title or "(no title)"
    title = " Tags: " .. require("zotero.types").truncate(t, 40) .. " "
  else
    title = " Tags of " .. #list .. " items "
  end

  -- After a colour change or delete: reopen to show the new state.
  local function reopen(ok)
    if ok then
      async_mod.run("zotero:ui.tag_assign.reopen", function()
        M.open(list)
      end)
    end
  end

  local busy = false
  checklist.open({
    id = "tag_assign",
    title = title,
    filetype = "zotero-tag-assign",
    help_tag = "zotero-tag-assign",
    empty_text = "  (no tags yet: press n to add one)",
    footer = " <CR> add/remove · n new · cc colour · dd delete · q close · g? help ",
    rows = tag_filter.rows(counts, {}, colored),
    is_checked = function(row)
      return M.state(has, ids, row.name)
    end,
    on_toggle = function(row)
      if busy then
        return -- one change at a time, so the boxes stay truthful
      end
      busy = true
      items.toggle_tag_on(list, row.name, function(ok, added)
        busy = false
        if ok then
          for _, id in ipairs(ids) do
            has[id] = has[id] or {}
            has[id][row.name] = added or nil
          end
          checklist.redraw("tag_assign")
        end
      end)
    end,
    extra_maps = {
      {
        "cc",
        function(row)
          if row then
            require("zotero.ui.tag_actions").assign_colour(row.name, reopen)
          end
        end,
        "assign tag colour",
      },
      {
        "dd",
        function(_, rows)
          local names = vim.tbl_map(function(r) return r.name end, rows)
          require("zotero.ui.tag_actions").delete_tags(names, reopen)
        end,
        "delete tag(s) from all items",
        true, -- also on a visual selection of tags
      },
      {
        "n",
        function()
          vim.ui.input({ prompt = "New tag: " }, function(name)
            name = name and vim.trim(name) or ""
            if name == "" then
              return
            end
            items.toggle_tag_on(list, name, function(ok)
              if ok then
                -- Reopen so the new tag shows up (checked) in the list.
                async_mod.run("zotero:ui.tag_assign.reopen", function()
                  M.open(list)
                end)
              end
            end)
          end)
        end,
        "add a new tag",
      },
    },
  })
end

return M
