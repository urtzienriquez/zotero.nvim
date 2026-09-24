-- <leader>zT: a small floating checklist of the item types in the current
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

local state = { buf = nil, win = nil, rows = {} }

local function render()
  local items = require("zotero.ui.items")
  local filter = items.get_type_filter()
  local name_w, count_w = 0, 0
  for _, r in ipairs(state.rows) do
    name_w = math.max(name_w, vim.fn.strdisplaywidth(r.name))
    count_w = math.max(count_w, #tostring(r.count))
  end
  local lines = {}
  for _, r in ipairs(state.rows) do
    local box = M.is_visible(filter, r.name) and "[x]" or "[ ]"
    lines[#lines + 1] = string.format(" %s %s  %s(%d) ", box, r.name .. string.rep(" ", name_w - vim.fn.strdisplaywidth(r.name)),
      string.rep(" ", count_w - #tostring(r.count)), r.count)
  end
  if #lines == 0 then
    lines = { "  (no items in this view)" }
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("zotero-type-filter")
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for i, r in ipairs(state.rows) do
    local visible = M.is_visible(filter, r.name)
    vim.api.nvim_buf_add_highlight(state.buf, ns, visible and "ZoteroItemMarker" or "ZoteroItemCount", i - 1, 1, 4)
    vim.api.nvim_buf_add_highlight(state.buf, ns, visible and "ZoteroItemTitle" or "ZoteroItemCount", i - 1, 5, 5 + #r.name)
    vim.api.nvim_buf_add_highlight(state.buf, ns, "ZoteroItemCount", i - 1, 5 + name_w, -1)
  end
  return lines
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function apply(new_filter)
  require("zotero.ui.items").set_type_filter(new_filter.mode, new_filter.types)
  render()
end

local function row_under_cursor()
  return state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
end

-- Opens the checklist for the current view. Must be called from inside an
-- async task (it queries the type counts).
function M.open()
  local items = require("zotero.ui.items")
  local ctx = items.get_view_context()
  local counts = async_mod.await(require("zotero.db").get_type_counts(ctx.collection_id, ctx.library_id)) or {}
  async_mod.to_main()

  M.close()
  state.rows = M.rows(counts, items.get_type_filter())

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "zotero-type-filter"
  local lines = render()

  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local footer = " <CR> toggle · o only · a all · q close "
  width = math.min(math.max(width, vim.fn.strdisplaywidth(footer)), vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Item types ",
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
    zindex = 50,
  })
  vim.wo[state.win].cursorline = true

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, silent = true, nowait = true, desc = desc })
  end
  local function on_row(fn)
    return function()
      local row = row_under_cursor()
      if row then
        apply(fn(items.get_type_filter(), row.name))
      end
    end
  end
  map("<CR>", on_row(M.toggle), "toggle type")
  map("<Space>", on_row(M.toggle), "toggle type")
  map("o", on_row(function(_, name) return M.only(name) end), "show only this type")
  map("a", function() apply(M.all()) end, "show all types")
  map("q", M.close, "close")
  map("<Esc>", M.close, "close")

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = state.buf,
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })
end

return M
