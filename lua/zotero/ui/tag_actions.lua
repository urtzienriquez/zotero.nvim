-- Library-wide tag actions, like the right-click menu of Zotero's tag
-- selector: assign/remove a tag's colour (and its 1-9 number key), and
-- delete a tag from every item. Used by `cc` / `dd` in the collections
-- pane's Tags section and in the tt window. Need companion plugin 1.4.0+.
local M = {}

local async_mod = require("zotero.async")

M.MAX_COLORED = 9

-- The palette of Zotero's "Assign Colour" dialog (elements/colorPicker.js).
M.PALETTE = {
  { name = "Red", hex = "#FF6666" },
  { name = "Orange", hex = "#FF8C19" },
  { name = "Gray", hex = "#999999" },
  { name = "Green", hex = "#5FB236" },
  { name = "Teal", hex = "#009980" },
  { name = "Blue", hex = "#2EA8E5" },
  { name = "Indigo", hex = "#576DD9" },
  { name = "Lavender", hex = "#A28AE5" },
  { name = "Plum", hex = "#A6507B" },
}

-- Re-render the items list (dots) and, through it, the collections pane
-- (Tags section), re-reading the database.
local function refresh()
  require("zotero.ui.items").fetch_and_render(true)
end

-- Colour choices for tag `name` given the current colored tags: the palette,
-- plus "Remove colour" when it already has one. Pure (for tests).
function M.colour_choices(name, colored)
  local current
  for _, t in ipairs(colored) do
    if t.name == name then
      current = t
    end
  end
  local choices = {}
  for _, c in ipairs(M.PALETTE) do
    local is_current = current and current.color and current.color:upper() == c.hex
    choices[#choices + 1] = { hex = c.hex, label = ("● %-8s %s%s"):format(c.name, c.hex, is_current and "  (current)" or "") }
  end
  if current then
    choices[#choices + 1] = { remove = true, label = "Remove colour" }
  end
  return choices
end

-- Number-key choices (1..n) for tag `name`: a colored tag can move among
-- the existing positions, a new one can also go at the end. Each label says
-- which tag holds that number now. Pure (for tests).
function M.position_choices(name, colored)
  local current_index
  for i, t in ipairs(colored) do
    if t.name == name then
      current_index = i
    end
  end
  local max = current_index and #colored or (#colored + 1)
  local choices = {}
  for p = 1, max do
    local holder = colored[p] and colored[p].name
    local note = (p == current_index and "  (current)") or (holder and ("  (now: " .. holder .. ")")) or ""
    choices[#choices + 1] = { position = p, label = ("t%d%s"):format(p, note) }
  end
  return choices, current_index or max
end

--- `cc`: pick a colour (or "Remove colour") and a number key for tag `name`.
--- `on_done(ok)` runs on the main thread after a change was sent.
function M.assign_colour(name, on_done)
  async_mod.run("zotero:tag_actions.colour", function()
    local colored = async_mod.await(require("zotero.db").get_colored_tags()) or {}
    async_mod.to_main()

    local is_colored = false
    for _, t in ipairs(colored) do
      is_colored = is_colored or t.name == name
    end
    if not is_colored and #colored >= M.MAX_COLORED then
      async_mod.notify(("zotero: Zotero allows at most %d colored tags; remove a colour first"):format(M.MAX_COLORED),
        vim.log.levels.WARN)
      return
    end

    local function apply(hex, position)
      async_mod.run("zotero:tag_actions.colour.apply", function()
        local ok = async_mod.await(require("zotero.api").set_tag_color(name, hex, position))
        async_mod.to_main()
        if ok then
          refresh()
        end
        if on_done then
          on_done(ok)
        end
      end)
    end

    vim.ui.select(M.colour_choices(name, colored), {
      prompt = "Colour for tag '" .. name .. "':",
      format_item = function(c) return c.label end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.remove then
        apply(nil, nil)
        return
      end
      local positions, default = M.position_choices(name, colored)
      if #positions == 1 then
        apply(choice.hex, 1)
        return
      end
      -- Put the default (current or next free number) first.
      table.sort(positions, function(a, b)
        if (a.position == default) ~= (b.position == default) then
          return a.position == default
        end
        return a.position < b.position
      end)
      vim.ui.select(positions, {
        prompt = "Number key for '" .. name .. "':",
        format_item = function(c) return c.label end,
      }, function(pos)
        if pos then
          apply(choice.hex, pos.position)
        end
      end)
    end)
  end)
end

--- `dd`: delete tags `names` from every item in the library (after one
--- confirmation), like "Delete Tag…" in Zotero; several at once from a
--- visual selection. `on_done(ok)` runs on the main thread (ok = all deleted).
function M.delete_tags(names, on_done)
  if #names == 0 then
    return
  end
  local question = #names == 1 and ("Delete tag '%s' from all items in your library?"):format(names[1])
    or ("Delete these %d tags from all items in your library?\n  %s"):format(#names, table.concat(names, ", "))
  if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then
    return
  end
  async_mod.run("zotero:tag_actions.delete", function()
    local api = require("zotero.api")
    local deleted = {}
    for _, name in ipairs(names) do
      -- One at a time, quietly (errors still show); one summary at the end.
      if async_mod.await(api.delete_tag(name, { quiet = #names > 1 })) then
        deleted[#deleted + 1] = name
      end
    end
    async_mod.to_main()
    if #deleted > 0 then
      if #names > 1 then
        async_mod.notify(("zotero: deleted %d tag(s): %s"):format(#deleted, table.concat(deleted, ", ")),
          vim.log.levels.INFO)
      end
      -- Don't keep filtering by tags that no longer exist.
      local items = require("zotero.ui.items")
      local filter = items.get_tag_filter()
      local kept = vim.tbl_filter(function(t) return not vim.tbl_contains(deleted, t) end, filter)
      if #kept ~= #filter then
        items.set_tag_filter(kept)
      end
      refresh()
    end
    if on_done then
      on_done(#deleted == #names)
    end
  end)
end

function M.delete_tag(name, on_done)
  M.delete_tags({ name }, on_done)
end

return M
