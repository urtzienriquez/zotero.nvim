local M = {}

M.defaults = {
  db_path = nil,
  -- Buffer-local keys follow the fugitive/sessman style: two-key mnemonic
  -- families (o = open, e = edit, a = add, s = sort, f = filter, t = toggle
  -- view, ...), <family>? opens help for that family, and the g prefix is
  -- navigation only. Every entry can be remapped (or set to false); see
  -- README "Keeping the old keymaps" for the previous <leader>z... layout.
  keymaps = {
    enabled = true,
    -- Global
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
    items_refresh = "R",
    items_focus_collections = "<Tab>",
    items_show_help = "g?",
    -- o: open
    items_open_attachment = "oo",
    items_open_url = "ob",
    -- e: edit
    items_edit_item = "ee",
    items_fix_attachment = "ef",
    -- a: add
    items_attach_pdf = "aa",
    items_import_pdf = "ai",
    items_add_by_identifier = "an",
    -- single actions (also work on a visual selection)
    items_delete = "dd",
    items_move_to_collection = "cm",
    items_remove_from_collection = "cr",
    items_toggle_mark = "mm",
    items_toggle_read = "rr",
    -- y: yank (into the register given, e.g. "+yk for the clipboard)
    items_yank_citation_key = "yk",
    items_yank_file_path = "yp",
    -- s: sort
    items_sort_title = "st",
    items_sort_year = "sy",
    items_sort_date_added = "sd",
    -- f: filter
    items_search = "ff",
    items_clear_search = "fc",
    items_filter_type = "ft",
    -- tags: t1..t9 toggle Zotero's colored tag N (this is the prefix), tt
    -- toggles any tag, fT filters by tag
    items_toggle_colored_tag = "t",
    items_toggle_tag = "tt",
    items_filter_tag = "fT",
    -- t: toggle view (tc/ts work in the collections pane too)
    items_toggle_columns = "tv",
    items_toggle_collections = "tc",
    toggle_statuscolumn = "ts",
    -- <family>?: :help at that family's section
    items_help_open = "o?",
    items_help_edit = "e?",
    items_help_add = "a?",
    items_help_sort = "s?",
    items_help_filter = "f?",
    items_help_toggle = "t?",
    items_help_yank = "y?",
    -- g: navigation (both panes)
    items_show_only_marked = "gm",
    goto_library = "gl",
    goto_feeds = "gf",
    goto_trash = "gd",
    -- Collections buffer
    collections_move_down = "j",
    collections_move_up = "k",
    collections_move_down_alt = "<Down>",
    collections_move_up_alt = "<Up>",
    collections_next_section = "]]",
    collections_prev_section = "[[",
    collections_select = "<CR>",
    collections_focus_items = "<Tab>",
    collections_focus_items_esc = "<Esc>",
    collections_new = "aa",
    collections_delete = "dd",
    collections_tag_colour = "cc",
    collections_refresh = "R",
    collections_toggle_pane = "tc",
    collections_show_help = "g?",
  },
  default_sort = "dateAdded",
  default_sort_dir = "desc",
  -- Command used to open attachments and URLs. nil uses the OS default
  -- handler via vim.ui.open() (open on macOS, xdg-open on Linux, start on
  -- Windows).
  pdf_viewer = nil,
  -- Item types (itemTypes.typeName, e.g. "webpage") hidden from the items
  -- list at startup. Change on the fly with ft or :ZoteroFilterType.
  hidden_item_types = {},
  -- Column preset used when browsing a feed: "compact" | "normal" | "full" |
  -- "configured" (the `columns` below). Toggling with tv inside a
  -- feed only changes the feed view.
  feed_view = "compact",
  backend = "fzf",
  max_items = 500,
  columns = { "#", "key", "title", "authors", "year", "journal", "dateAdded" },
  process_timeout = 30000,
  -- Zotero can take a while to process imports, so keep this generous.
  http_timeout = 60000,
}

M.options = nil
local _initialized = false

if not vim.async then
  local msg = "zotero.nvim: this version requires a Neovim build with vim.async (master). "
    .. "For Neovim < 0.13, install the latest tagged release of zotero.nvim instead."
  vim.notify(msg, vim.log.levels.ERROR, { title = "zotero" })
end

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
