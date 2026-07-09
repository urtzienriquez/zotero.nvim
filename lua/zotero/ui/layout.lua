local M = {}

local detail = require("zotero.ui.detail")

local state = {
  collections_buf = nil,
  items_buf = nil,
  collections_win = nil,
  items_win = nil,
  tabpage = nil,
  is_open = false,
  original_buf = nil,
}

local collections_hidden = false

function M.create_layout()
  local collections_buf = vim.api.nvim_create_buf(false, true)
  local items_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[collections_buf].filetype = "zotero-collections"
  vim.bo[items_buf].filetype = "zotero-items"

  pcall(vim.api.nvim_buf_set_name, collections_buf, "zotero://collections")
  pcall(vim.api.nvim_buf_set_name, items_buf, "zotero://items")

  vim.bo[collections_buf].buflisted = false
  vim.bo[items_buf].buflisted = false

  local total_width = vim.o.columns
  local collections_width = math.max(25, math.floor(total_width * 0.2))

  -- use current window as items pane
  local items_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_win_get_buf(items_win)
  vim.api.nvim_win_set_buf(items_win, items_buf)
  vim.wo[items_win].wrap = false
  vim.wo[items_win].spell = false
  vim.wo[items_win].signcolumn = "yes"
  vim.wo[items_win].cursorline = true
  vim.wo[items_win].cursorlineopt = "line,number"

  -- split left for collections
  local collections_win = nil
  if not collections_hidden then
    collections_win = vim.api.nvim_open_win(collections_buf, true, {
      split = "left",
      win = items_win,
      width = collections_width,
    })
    vim.wo[collections_win].spell = false
    vim.wo[collections_win].signcolumn = "yes"
    vim.wo[collections_win].cursorline = true
    vim.wo[collections_win].cursorlineopt = "line,number"
  end

  local tabpage = vim.api.nvim_win_get_tabpage(items_win)

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

  local collections_buf = state.collections_buf

  vim.keymap.set("n", "<Esc>", function()
    if state.items_win and vim.api.nvim_win_is_valid(state.items_win) then
      vim.api.nvim_set_current_win(state.items_win)
    end
  end, { buffer = collections_buf, silent = true, nowait = true, desc = "zotero: focus items" })
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
  return state.is_open
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
    vim.wo[state.collections_win].signcolumn = "yes"
    vim.wo[state.collections_win].cursorline = true
    vim.wo[state.collections_win].cursorlineopt = "line,number"
    require("zotero.ui.collections").render()
  end
end

function M.close()
  if detail.is_open() then
    detail.close()
  end

  local function buf_valid(b)
    return b and vim.api.nvim_buf_is_valid(b)
  end

  local function win_valid(w)
    return w and vim.api.nvim_win_is_valid(w)
  end

  if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
    vim.api.nvim_set_current_tabpage(state.tabpage)
  end

  local zotero_buffers = {}
  if buf_valid(state.collections_buf) then
    table.insert(zotero_buffers, state.collections_buf)
  end
  if buf_valid(state.items_buf) then
    table.insert(zotero_buffers, state.items_buf)
  end

  if win_valid(state.collections_win) then
    pcall(vim.api.nvim_win_close, state.collections_win, true)
  end

  if win_valid(state.items_win) then
    local tp = vim.api.nvim_win_get_tabpage(state.items_win)
    local all_wins = vim.api.nvim_tabpage_list_wins(tp)
    local normal_wins = 0
    for _, w in ipairs(all_wins) do
      local cfg = vim.api.nvim_win_get_config(w)
      if not cfg.relative or cfg.relative == "" then
        normal_wins = normal_wins + 1
      end
    end
    if normal_wins <= 1 then
      local target = state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf)
          and state.original_buf
        or vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(state.items_win, target)
    else
      pcall(vim.api.nvim_win_close, state.items_win, true)
    end
  end

  for _, buf in ipairs(zotero_buffers) do
    if buf_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  state.collections_buf = nil
  state.items_buf = nil
  state.collections_win = nil
  state.items_win = nil
  state.tabpage = nil
  state.original_buf = nil
  state.is_open = false
end

return M
