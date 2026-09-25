-- Window rules. Sets window options like :setlocal. `vim.wo[win].x = v` is :set, which
-- also changes the global value: the user's windows opened afterwards
-- (help, fugitive, :split…) would inherit our settings, e.g. lose their line
-- numbers and sign column. A global foldminlines change also makes
-- Neovim's treesitter folding refresh every buffer it knows, which can fail
-- on one that's already wiped ("Invalid buffer id" from
-- treesitter/_fold.lua's OptionSet handler).
local M = {}

function M.set(win, name, value)
  vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
end

-- Split windows (edit, help) open like fugitive's: across the whole width,
-- at the bottom or the top as the user's 'splitbelow' says.
function M.edge()
  return vim.o.splitbelow and "botright" or "topleft"
end

-- :help {tag} in such a window (an open help window is reused, as usual).
function M.help(tag)
  vim.cmd(M.edge() .. " help " .. tag)
end

return M
