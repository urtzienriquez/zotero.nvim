-- Small floating checklist shared by the item-type filter (ft) and the tag
-- filter (fT): rows of " [x] <prefix><name>  (count) " over a dimmed
-- backdrop. <CR>/<Space> toggles the row under the cursor, `o` keeps only
-- that row, `a` resets, q/<Esc> closes, g? opens help. The callers own the
-- state; this module only draws it (via spec.is_checked, which may also
-- return "partial" for [~]) and reports actions (spec.on_toggle / on_only /
-- on_all, plus any spec.extra_maps), re-rendering after each.
local M = {}

local backdrop_mod = require("zotero.ui.backdrop")
local winopt = require("zotero.ui.winopt")

local state = { id = nil, spec = nil, buf = nil, win = nil, backdrop = nil }

local function render()
  local spec = state.spec
  local name_w, count_w = 0, 0
  for _, r in ipairs(spec.rows) do
    name_w = math.max(name_w, vim.fn.strdisplaywidth(r.name))
    count_w = math.max(count_w, #tostring(r.count))
  end

  local lines, marks = {}, {}
  for i, r in ipairs(spec.rows) do
    local state_ = spec.is_checked(r)
    local checked = state_ == true or state_ == "partial"
    local box = state_ == "partial" and "[~]" or (checked and "[x]" or "[ ]")
    local prefix = r.prefix or ""
    local name_pad = r.name .. string.rep(" ", name_w - vim.fn.strdisplaywidth(r.name))
    lines[i] = " " .. box .. " " .. prefix .. name_pad .. "  "
      .. string.rep(" ", count_w - #tostring(r.count)) .. "(" .. r.count .. ") "
    local name_col = 5 + #prefix -- byte column where the name starts
    marks[i] = { checked = checked, name_col = name_col, name_end = name_col + #r.name,
      count_col = name_col + #name_pad, prefix_hls = r.prefix_hls }
  end
  if #lines == 0 then
    lines = { spec.empty_text or "  (nothing to show)" }
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("zotero-checklist")
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for i, m in ipairs(marks) do
    local hl = m.checked and "ZoteroItemTitle" or "ZoteroItemCount"
    vim.api.nvim_buf_add_highlight(state.buf, ns, m.checked and "ZoteroItemMarker" or "ZoteroItemCount", i - 1, 1, 4)
    for _, ph in ipairs(m.prefix_hls or {}) do
      vim.api.nvim_buf_add_highlight(state.buf, ns, ph[3], i - 1, 5 + ph[1], 5 + ph[2])
    end
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl, i - 1, m.name_col, m.name_end)
    vim.api.nvim_buf_add_highlight(state.buf, ns, "ZoteroItemCount", i - 1, m.count_col, -1)
  end
  return lines
end

--- Closes the checklist if it is open (only the one with this id, if given).
function M.close(id)
  if id and state.id ~= id then
    return
  end
  backdrop_mod.close(state.backdrop)
  state.backdrop = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf, state.id, state.spec = nil, nil, nil
end

function M.is_open(id)
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win) and (id == nil or state.id == id)
end

--- Re-renders the open checklist `id` (for state that changed asynchronously).
function M.redraw(id)
  if M.is_open(id) and state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    render()
  end
end

--- Opens a checklist. Must run on the main thread. spec fields:
---   id, title, filetype, help_tag, empty_text?
---   rows: { name, count, prefix?, prefix_hls? = { {from, to, hl_group} } }
---   is_checked(row) -> true | false | "partial"
---   on_toggle(row); on_only?(row); on_all?()  (o / a only mapped if given)
---   footer?: text shown under the list (default lists the default keys)
---   extra_maps?: { { lhs, fn(row_or_nil, rows), desc, visual? }, ... }
---     visual = true also maps lhs in visual mode, with rows = the selected
---     rows (in normal mode rows = { row })
function M.open(spec)
  M.close()
  state.id, state.spec = spec.id, spec

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = spec.filetype or "zotero-checklist"
  local lines = render()

  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local footer = spec.footer or " <CR> toggle · o only · a all · q close · g? help "
  width = math.max(width, vim.fn.strdisplaywidth(footer))
  local height = #lines
  local config = backdrop_mod.center(width, height)

  -- Dim the rest of the screen, like the item preview does.
  state.backdrop = backdrop_mod.open()
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = config.width,
    height = config.height,
    row = config.row,
    col = config.col,
    style = "minimal",
    border = "rounded",
    title = spec.title,
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
    zindex = 50,
  })
  winopt.set(state.win, "cursorline", true)
  backdrop_mod.follow_resize(state.win, state.backdrop, function() return width, height end)

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, silent = true, nowait = true, desc = desc })
  end
  local function on_row(action)
    return function()
      local row = spec.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
      if row then
        action(row)
        render()
      end
    end
  end
  map("<CR>", on_row(spec.on_toggle), "toggle")
  map("<Space>", on_row(spec.on_toggle), "toggle")
  if spec.on_only then
    map("o", on_row(spec.on_only), "only this one")
  end
  if spec.on_all then
    map("a", function()
      spec.on_all()
      render()
    end, "reset")
  end
  for _, m in ipairs(spec.extra_maps or {}) do
    map(m[1], function()
      local row = spec.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
      m[2](row, { row })
    end, m[3])
    if m[4] then
      vim.keymap.set("x", m[1], function()
        local first, last = vim.fn.line("v"), vim.fn.line(".")
        if first > last then
          first, last = last, first
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
        local rows = {}
        for i = first, last do
          rows[#rows + 1] = spec.rows[i]
        end
        m[2](rows[1], rows)
      end, { buffer = state.buf, silent = true, desc = m[3] })
    end
  end
  map("q", M.close, "close")
  map("<Esc>", M.close, "close")
  map("g?", function()
    M.close()
    winopt.help(spec.help_tag)
  end, "open help")

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = state.buf,
    once = true,
    callback = function()
      vim.schedule(function()
        M.close(spec.id)
      end)
    end,
  })
end

return M
