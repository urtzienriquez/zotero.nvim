-- nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/zotero"

vim.o.swapfile = false
vim.o.shadafile = "NONE"

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

-- Lets require("tests.helpers.fixture") resolve; tests/ isn't a `lua/` dir.
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local plenary_path = vim.env.PLENARY_PATH or (root .. "/tests/deps/plenary.nvim")
if vim.fn.isdirectory(plenary_path) == 0 then
  error("plenary.nvim not found at " .. plenary_path .. " -- run scripts/test.sh, or set $PLENARY_PATH")
end
vim.opt.runtimepath:prepend(plenary_path)

vim.cmd("runtime plugin/plenary.vim")
