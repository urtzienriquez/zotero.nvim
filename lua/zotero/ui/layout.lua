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

local statuscolumn_visible = false

-- The items window hides the sign/number columns unless toggled with ts.
-- The collections split doesn't touch them: like fugitive's status window
-- and sessman's pane, it keeps the user's own settings.
local function apply_statuscolumn(win)
  local wins = {}
  win = win or state.items_win
  if win and vim.api.nvim_win_is_valid(win) then
    table.insert(wins, win)
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

  -- Only the items window: the collections list opens on demand as a
  -- split (gb, see M.open_collections).
  state.collections_buf = collections_buf
  state.items_buf = items_buf
  state.collections_win = nil
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

  local items_buf = state.items_buf

  local toggle_lhs = km.toggle_statuscolumn
  if toggle_lhs then
    vim.keymap.set("n", toggle_lhs, M.toggle_statuscolumn, {
      buffer = items_buf,
      silent = true,
      nowait = true,
      desc = "toggle statuscolumn",
    })
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

-- Opens the collections list, like fugitive's status window or sessman's
-- pane: a split across the whole width, at the bottom or the top as
-- 'splitbelow' says. Already open: just moves the cursor there.
function M.open_collections()
  if state.collections_win and vim.api.nvim_win_is_valid(state.collections_win) then
    vim.api.nvim_set_current_win(state.collections_win)
    return
  end
  if not (state.collections_buf and vim.api.nvim_buf_is_valid(state.collections_buf)) then
    return
  end
  if state.items_win and vim.api.nvim_win_is_valid(state.items_win) then
    vim.api.nvim_set_current_win(state.items_win)
  end
  vim.cmd(winopt.edge() .. " split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.collections_buf)
  winopt.set(win, "wrap", false)
  winopt.set(win, "spell", false)
  winopt.set(win, "cursorline", true)
  -- :split copied the items window's hidden columns (and Neovim may restore
  -- what this buffer had last time): give the split the user's own sign and
  -- number columns, as fugitive's and sessman's windows have.
  for _, name in ipairs({ "signcolumn", "number", "relativenumber", "statuscolumn", "foldcolumn" }) do
    winopt.set(win, name, vim.api.nvim_get_option_value(name, { scope = "global" }))
  end
  state.collections_win = win
  -- However it closes (<CR>, gq, :q), keep its folds and cursor for next time.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      require("zotero.ui.collections").save_view(win)
      if state.collections_win == win then
        state.collections_win = nil
      end
    end,
  })
  -- Sets up the folds for this window and puts the cursor back where it was.
  require("zotero.ui.collections").refresh_display()
end

-- Closes the collections split (gq, or after picking an entry) and goes
-- back to the items window.
function M.close_collections()
  local win = state.collections_win
  state.collections_win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  M.focus_items()
end

M.focus_collections = M.open_collections

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
