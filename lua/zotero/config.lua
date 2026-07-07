local M = {}

M.defaults = {
  db_path = nil,
  keymaps = {
    enabled = true,
    open_library = "<leader>zz",
  },
  default_sort = "dateAdded",
  default_sort_dir = "desc",
  pdf_viewer = "xdg-open",
  backend = "fzf",
  max_items = 500,
  columns = { "#", "key", "title", "authors", "year", "journal", "dateAdded" },
}

M.options = nil
local _initialized = false

local function auto_detect_db()
  local home = vim.fn.expand("~")
  local candidates = {
    home .. "/Zotero/zotero.sqlite",
    home .. "/.zotero/zotero.sqlite",
    home .. "/.local/share/zotero/zotero.sqlite",
    home .. "/snap/zotero/current/.zotero/zotero.sqlite",
    home .. "/.var/app/org.zotero.Zotero/data/zotero.sqlite",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
  return nil
end

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if not M.options.db_path then
    M.options.db_path = auto_detect_db()
  end
  if not M.options.db_path then
    vim.notify("zotero: could not auto-detect zotero.sqlite. Set db_path in setup().", vim.log.levels.WARN)
  elseif vim.fn.filereadable(M.options.db_path) == 0 then
    vim.notify("zotero: db_path '" .. M.options.db_path .. "' not readable.", vim.log.levels.ERROR)
  end
  _initialized = true
end

function M.get()
  if not _initialized then
    M.options = vim.deepcopy(M.defaults)
    M.options.db_path = auto_detect_db()
    _initialized = true
    if not M.options.db_path then
      vim.schedule(function()
        vim.notify("zotero: setup() not called and auto-detect failed. Set db_path explicitly.", vim.log.levels.WARN)
      end)
    end
  end
  return M.options
end

return M
