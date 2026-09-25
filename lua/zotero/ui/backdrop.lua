-- Full-screen dimmed window placed just under a floating window (zindex 49,
-- floats use 50). Shared by the item preview and the item-type checklist.
local M = {}
local winopt = require("zotero.ui.winopt")

-- Returns a handle to pass to M.close().
function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = vim.o.columns,
    height = vim.o.lines,
    row = 0,
    col = 0,
    style = "minimal",
    border = "none",
    zindex = 49,
    focusable = false,
  })
  winopt.set(win, "winhl", "Normal:ZoteroDetailBackdrop")
  winopt.set(win, "winblend", 60)
  return { win = win, buf = buf }
end

-- Safe to call more than once, or with nil.
function M.close(handle)
  if not handle then
    return
  end
  if handle.win and vim.api.nvim_win_is_valid(handle.win) then
    vim.api.nvim_win_close(handle.win, true)
  end
  if handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
    vim.api.nvim_buf_delete(handle.buf, { force = true })
  end
  handle.win, handle.buf = nil, nil
end

return M
