local M = {}
local async_mod = require("zotero.async")

local detail = require("zotero.ui.detail")
local winopt = require("zotero.ui.winopt")

local state = {
  collections_buf = nil,
  items_buf = nil,
  collections_win = nil,
  items_win = nil,
  tabpage = nil,
  is_open = false,
}

local collections_hidden = false

local statuscolumn_visible = false

local function apply_statuscolumn(win)
  local wins = {}
  if win and vim.api.nvim_win_is_valid(win) then
    table.insert(wins, win)
  else
    if state.collections_win and vim.api.nvim_win_is_valid(state.collections_win) then
      table.insert(wins, state.collections_win)
    end
    if state.items_win and vim.api.nvim_win_is_valid(state.items_win) then
      table.insert(wins, state.items_win)
    end
  end
  for _, w in ipairs(wins) do
    if statuscolumn_visible then
      winopt.set(w, "signcolumn", "yes")
      winopt.set(w, "number", true)
      winopt.set(w, "relativenumber", true)
      winopt.set(w, "statuscolumn", "")
    else
      winopt.set(w, "signcolumn", "no")
      winopt.set(w, "number", false)
      winopt.set(w, "relativenumber", false)
      winopt.set(w, "statuscolumn", "")
    end
  end
end

function M.toggle_statuscolumn()
  statuscolumn_visible = not statuscolumn_visible
  apply_statuscolumn()
  async_mod.notify("zotero: statuscolumn " .. (statuscolumn_visible and "shown" or "hidden"), vim.log.levels.INFO)
end

function M.create_layout()
  -- Reuse the previous session's buffers when they are still alive so a
  -- reopen can repaint instantly instead of showing empty windows.
  local collections_buf = state.collections_buf
  local items_buf = state.items_buf
  local reuse = collections_buf and vim.api.nvim_buf_is_valid(collections_buf)
    and items_buf and vim.api.nvim_buf_is_valid(items_buf)

  if not reuse then
    collections_buf = vim.api.nvim_create_buf(false, true)
    items_buf = vim.api.nvim_create_buf(false, true)

    vim.bo[collections_buf].filetype = "zotero-collections"
    vim.bo[items_buf].filetype = "zotero-items"

    pcall(vim.api.nvim_buf_set_name, collections_buf, "zotero://collections")
    pcall(vim.api.nvim_buf_set_name, items_buf, "zotero://items")

    vim.bo[collections_buf].buflisted = false
    vim.bo[items_buf].buflisted = false
  end

  local total_width = vim.o.columns
  local collections_width = math.max(25, math.floor(total_width * 0.2))

  vim.cmd("tabnew")
  local items_win = vim.api.nvim_get_current_win()
  local scratch_buf = vim.api.nvim_win_get_buf(items_win)
  vim.api.nvim_win_set_buf(items_win, items_buf)
  -- tabnew leaves an empty [No Name] buffer behind; drop it so it doesn't
  -- linger as a listed buffer (e.g. in fzf-lua)
  if scratch_buf ~= items_buf and vim.api.nvim_buf_is_valid(scratch_buf)
      and vim.api.nvim_buf_get_name(scratch_buf) == "" then
    pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
  end
  local tabpage = vim.api.nvim_win_get_tabpage(items_win)
  winopt.set(items_win, "wrap", false)
  winopt.set(items_win, "spell", false)
  winopt.set(items_win, "cursorline", true)
  apply_statuscolumn(items_win)

  local collections_win = nil
  if not collections_hidden then
    collections_win = vim.api.nvim_open_win(collections_buf, true, {
      split = "left",
      win = items_win,
      width = collections_width,
    })
    winopt.set(collections_win, "spell", false)
    winopt.set(collections_win, "cursorline", true)
    apply_statuscolumn(collections_win)
  end

  state.collections_buf = collections_buf
  state.items_buf = items_buf
  state.collections_win = collections_win
  state.items_win = items_win
  state.tabpage = tabpage
  state.is_open = true
end

function M.set_keymaps()
  if not state.collections_buf or not vim.api.nvim_buf_is_valid(state.collections_buf) then
    return
  end
  if not state.items_buf or not vim.api.nvim_buf_is_valid(state.items_buf) then
    return
  end

  local cfg = require("zotero.config").get()
  local km = cfg.keymaps
  if not km.enabled then
    return
  end

  local collections_buf = state.collections_buf
  local items_buf = state.items_buf

  local lhs = km.collections_focus_items_esc
  if lhs then
    vim.keymap.set("n", lhs, function()
      if state.items_win and vim.api.nvim_win_is_valid(state.items_win) then
        vim.api.nvim_set_current_win(state.items_win)
      end
    end, { buffer = collections_buf, silent = true, nowait = true, desc = "focus items" })
  end

  local toggle_lhs = km.toggle_statuscolumn
  if toggle_lhs then
    for _, buf in ipairs({ collections_buf, items_buf }) do
      -- No nowait: the default (ts) shares the t prefix with tc/tv.
      vim.keymap.set("n", toggle_lhs, M.toggle_statuscolumn, {
        buffer = buf,
        silent = true,
        desc = "toggle statuscolumn",
      })
    end
  end
end

function M.get_collections_buf()
  return state.collections_buf
end

function M.get_items_buf()
  return state.items_buf
end

function M.get_collections_win()
  return state.collections_win
end

function M.get_items_win()
  return state.items_win
end

function M.focus_collections()
  if state.collections_win and vim.api.nvim_win_is_valid(state.collections_win) then
    vim.api.nvim_set_current_win(state.collections_win)
  end
end

function M.focus_items()
  if state.items_win and vim.api.nvim_win_is_valid(state.items_win) then
    vim.api.nvim_set_current_win(state.items_win)
  end
end

function M.is_open()
  if not state.is_open then
    return false
  end
  -- The state can go stale if the tab was closed externally (e.g. :q). Detect
  -- that, delete any leftover zotero buffers, and clear out the stale handles
  -- so the next open starts fresh.
  local tab_ok = state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage)
  local buf_ok = state.items_buf and vim.api.nvim_buf_is_valid(state.items_buf)
  if not (tab_ok and buf_ok) then
    for _, b in ipairs({ state.collections_buf, state.items_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    state.collections_buf = nil
    state.items_buf = nil
    state.collections_win = nil
    state.items_win = nil
    state.tabpage = nil
    state.is_open = false
    return false
  end
  return true
end

function M.toggle_collections()
  if not state.items_win or not vim.api.nvim_win_is_valid(state.items_win) then
    return
  end

  if state.collections_win and vim.api.nvim_win_is_valid(state.collections_win) then
    vim.api.nvim_win_close(state.collections_win, true)
    state.collections_win = nil
    collections_hidden = true
  else
    local total_width = vim.o.columns
    local collections_width = math.max(25, math.floor(total_width * 0.2))
    state.collections_win = vim.api.nvim_open_win(state.collections_buf, true, {
      split = "left",
      win = state.items_win,
      width = collections_width,
    })
    collections_hidden = false
    winopt.set(state.collections_win, "cursorline", true)
    apply_statuscolumn(state.collections_win)
    require("zotero.ui.collections").render()
  end

  require("zotero.ui.items").rerender()
end

function M.close()
  if detail.is_open() then
    detail.close()
  end

  if not (state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage)) then
    state.is_open = false
    return
  end

  -- Make the Zotero tab current and close it; the previously active tab is
  -- focused automatically. Note: some builds lack vim.api.nvim_tabpage_close,
  -- so use the always-available :tabclose ex command instead.
  vim.api.nvim_set_current_tabpage(state.tabpage)
  pcall(vim.cmd, "tabclose")

  -- Note: buffers are intentionally kept alive so a reopen can repaint from
  -- memory instantly. They are scratch (buflisted=false) and get deleted via
  -- is_open() when the tab is closed externally instead.
  state.collections_win = nil
  state.items_win = nil
  state.tabpage = nil
  state.is_open = false
end

return M
