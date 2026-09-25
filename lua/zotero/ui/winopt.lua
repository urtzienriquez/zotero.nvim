-- Sets window options like :setlocal. `vim.wo[win].x = v` is :set, which
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

return M
