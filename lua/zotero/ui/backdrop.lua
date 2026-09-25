-- Full-screen dimmed window placed just under a floating window (zindex 49,
-- floats use 50), plus the sizing rules the centered floats share. Used by
-- the item preview and the checklists.
local M = {}
local winopt = require("zotero.ui.winopt")

-- Screen area floats may use: the whole editor except the command line.
local function screen()
  return vim.o.columns, math.max(1, vim.o.lines - vim.o.cmdheight)
end

-- Window config for a float of (at most) width x height centered on the
-- screen, shrunk to fit with a margin for its border.
function M.center(width, height)
  local cols, rows = screen()
  width = math.max(1, math.min(width, cols - 4))
  height = math.max(1, math.min(height, rows - 4))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((rows - height) / 2),
    col = math.floor((cols - width) / 2),
  }
end

-- Returns a handle to pass to M.close() / M.resize().
function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  local cols, rows = screen()
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = cols,
    height = rows,
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

-- Fits the backdrop to the current screen size.
function M.resize(handle)
  if handle and handle.win and vim.api.nvim_win_is_valid(handle.win) then
    local cols, rows = screen()
    vim.api.nvim_win_set_config(handle.win, { relative = "editor", width = cols, height = rows, row = 0, col = 0 })
  end
end

-- Keeps float `win` centered (and its backdrop covering the screen) when
-- the terminal is resized, until `win` closes. size() returns the float's
-- wanted width and height.
function M.follow_resize(win, handle, size)
  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return true -- the float is gone: drop this autocmd
      end
      vim.api.nvim_win_set_config(win, M.center(size()))
      M.resize(handle)
    end,
  })
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
