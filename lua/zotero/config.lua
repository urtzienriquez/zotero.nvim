local M = {}

M.defaults = {
  db_path = nil,
  keymaps = {
    enabled = true,
    open_library = "<leader>zz",
    fuzzy_find = "<leader>zf",
    -- Items buffer
    items_move_down = "j",
    items_move_up = "k",
    items_move_down_alt = "<Down>",
    items_move_up_alt = "<Up>",
    items_go_to_top = "gg",
    items_go_to_bottom = "G",
    items_show_detail = "<CR>",
    items_open_attachment = "<leader>zo",
    items_open_url = "<leader>zb",
    items_edit_item = "<leader>ze",
    items_import_pdf = "<leader>zi",
    items_attach_pdf = "<leader>za",
    items_move_to_collection = "<leader>zM",
    items_add_by_identifier = "<leader>zn",
    items_delete = "<leader>zD",
    items_sort_title = "<leader>zs",
    items_sort_year = "<leader>zS",
    items_sort_date_added = "<leader>zd",
    items_search = "<leader>z/",
    items_clear_search = "<leader>zc",
    items_refresh = "<leader>zr",
    items_toggle_columns = "<leader>zv",
    items_toggle_collections = "<leader>zt",
    items_toggle_mark = "<leader>zm",
items_show_only_marked   = "<leader>zl",
    items_focus_collections = "<Tab>",
    items_show_help = "?",
    -- Collections buffer
    collections_move_down = "j",
    collections_move_up = "k",
    collections_move_down_alt = "<Down>",
    collections_move_up_alt = "<Up>",
    collections_next_section = "]]",
    collections_prev_section = "[[",
    collections_select = "<CR>",
    collections_toggle_pane = "<leader>zt",
    collections_focus_items = "<Tab>",
    collections_new = "<leader>zN",
    collections_delete = "<leader>zD",
    collections_focus_items_esc = "<Esc>",
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
