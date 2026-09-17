local M = {}

local db = require("zotero.db")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")
local async_mod = require("zotero.async")

local collections_data = {}
local expanded = {}
local selected_collection_id = nil
local cursor_line = 1
local total_item_count = 0
local trash_count = 0
local collection_keys_by_id = {}
local _render_version = nil
-- Bumped by M.render()/M.refresh_counts(); lets a superseded in-flight
-- render bail out instead of overwriting newer results.
local _render_generation = 0

-- Bumped when collections_data/expanded change shape, so get_display_lines()
-- can skip rebuilding on pure cursor-navigation calls that touch neither.
local _structure_version = 0
local _display_lines_cache = nil
local _display_lines_cache_key = nil

local function get_display_lines()
  local marked_count = items.get_marked_count()
  local cache_key = table.concat({ _structure_version, total_item_count, trash_count, marked_count }, "|")
  if _display_lines_cache and _display_lines_cache_key == cache_key then
    return _display_lines_cache
  end

  local lines = {}
  table.insert(lines, {
    line = "  My Library (" .. tostring(total_item_count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_all_items = true,
  })

  local children_of = {}
  for _, col in ipairs(collections_data) do
    if col.parentCollectionID then
      children_of[col.parentCollectionID] = true
    end
  end

  for _, col in ipairs(collections_data) do
    local show = false
    if col.depth == 0 or expanded[col.parentCollectionID] then
      show = true
    end

    if show then
      local indent = string.rep("  ", col.depth)
      local has_children = children_of[col.collectionID] or false
      local arrow = has_children and (expanded[col.collectionID] and "▼ " or "▶ ") or "  "
      local count_str = " (" .. tostring(col.item_count) .. ")"
      local line = indent .. arrow .. col.collectionName .. count_str
      table.insert(lines, {
        line = line,
        collectionID = col.collectionID,
        has_children = has_children,
        depth = col.depth,
      })
    end
  end

  table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true })

  table.insert(lines, {
    line = "  Marked Items (" .. tostring(marked_count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_marked_items = true,
  })

  table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true })

  table.insert(lines, {
    line = "  Trash (" .. tostring(trash_count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_trash = true,
  })

  _display_lines_cache = lines
  _display_lines_cache_key = cache_key
  return lines
end

local function load_data()
  -- Launched before awaiting so the 3 queries run concurrently.
  local t_collections = db.get_collections()
  local t_stats = db.get_stats()
  local t_trash_count = db.get_trash_count()

  collections_data = async_mod.await(t_collections)
  local stats = async_mod.await(t_stats)
  total_item_count = stats.items
  trash_count = async_mod.await(t_trash_count)

  collection_keys_by_id = {}
  for _, col in ipairs(collections_data) do
    collection_keys_by_id[col.collectionID] = col.key
  end

  expanded["root"] = true
  for _, col in ipairs(collections_data) do
    if col.depth == 0 then
      expanded[col.collectionID] = true
    end
  end

  _structure_version = _structure_version + 1
end

function M.render()
  _render_generation = _render_generation + 1
  local generation = _render_generation
  async_mod.run("zotero:ui.collections.render", function()
    load_data()

    if generation ~= _render_generation then
      return
    end
    async_mod.to_main()
    if generation ~= _render_generation then
      return
    end

    local buf = layout.get_collections_buf()
    if not buf then
      return
    end

    M.refresh_display()

    M.set_keymaps()

    _render_version = db.get_data_version()
  end)
end

-- Synchronously repopulate the collections buffer from the last in-memory
-- data (no IPC, no event-loop hops) so an open after close is instant.
-- Returns true when the rendered data is still fresh, so the caller can skip
-- the background (re)query entirely.
function M.restore_render()
  local buf = layout.get_collections_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if #collections_data == 0 then
    return false
  end
  M.refresh_display()
  M.set_keymaps()
  return not db.is_stale_since(_render_version)
end

function M.refresh_display()
  local buf = layout.get_collections_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local display_lines = get_display_lines()
  local lines = {}
  for _, dl in ipairs(display_lines) do
    table.insert(lines, dl.line)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  if cursor_line > #lines then
    cursor_line = #lines
  end
  if cursor_line < 1 then
    cursor_line = 1
  end

  M.apply_highlights(buf)

  local win = layout.get_collections_win()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
  end
end

function M.apply_highlights(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local ns = vim.api.nvim_create_namespace("zotero-collections-hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local count = line:match("%((%d+)%)%s*$")
    if count then
      local count_start = line:find("%(" .. count .. "%)%s*$")
      if count_start then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemCount", i - 1, count_start - 1, -1)
      end
    end

    local arrow = line:match("^%s*([▶▼])")
    if arrow then
      local arrow_pos = line:find("[▶▼]")
      if arrow_pos then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroCollectionArrow", i - 1, arrow_pos - 1, arrow_pos)
      end
    end
  end
end

function M.refresh_counts()
  _render_generation = _render_generation + 1
  local generation = _render_generation
  async_mod.run("zotero:ui.collections.refresh_counts", function()
    require("zotero.db").invalidate_cache()
    load_data()

    if generation ~= _render_generation then
      return
    end
    async_mod.to_main()
    if generation ~= _render_generation then
      return
    end
    M.refresh_display()
    _render_version = db.get_data_version()
  end)
end

function M.get_collection_at_line(line)
  local display_lines = get_display_lines()
  if line < 1 or line > #display_lines then
    return nil
  end
  return display_lines[line]
end

local function on_enter()
  local win = layout.get_collections_win()
  if not win then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  cursor_line = cursor[1]
  local entry = M.get_collection_at_line(cursor_line)
  if not entry then
    return
  end

  if entry.is_trash then
    items.load_trash()
    layout.focus_items()
    return
  end

  if entry.is_marked_items then
    items.load_marked()
    layout.focus_items()
    return
  end

  if entry.is_separator then
    return
  end

  if entry.is_all_items then
    selected_collection_id = nil
    items.load_items(nil)
    layout.focus_items()
    return
  end

  if entry.has_children then
    if expanded[entry.collectionID] then
      expanded[entry.collectionID] = nil
    else
      expanded[entry.collectionID] = true
    end
    _structure_version = _structure_version + 1
    M.refresh_display()
  end

  selected_collection_id = entry.collectionID
  items.load_items(entry.collectionID)
  layout.focus_items()
end

local function move_cursor(delta)
  local win = layout.get_collections_win()
  if not win then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local new_line = cursor_line + delta
  if new_line < 1 then
    new_line = 1
  end
  if new_line > line_count then
    new_line = line_count
  end
  cursor_line = new_line
  vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
end

local function jump_section(direction)
  local display_lines = get_display_lines()
  local target = cursor_line + direction
  while target >= 1 and target <= #display_lines do
    local line = display_lines[target]
    if not line.is_separator and line.line ~= "" then
      if line.is_all_items or line.is_marked_items or line.is_trash then
        cursor_line = target
        local win = layout.get_collections_win()
        if win then
          vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
        end
        return
      end
    end
    target = target + direction
  end
end

function M.set_keymaps()
  local buf = layout.get_collections_buf()
  if not buf then
    return
  end

  if vim.b[buf].zotero_collections_setup then
    return
  end
  vim.b[buf].zotero_collections_setup = true

  local cfg = require("zotero.config").get()
  local km = cfg.keymaps
  if not km.enabled then
    return
  end

  local function map(mode, name, rhs, desc)
    local lhs = km[name]
    if not lhs then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end

  map("n", "collections_move_down", function()
    move_cursor(vim.v.count1)
  end, "move down")

  map("n", "collections_move_up", function()
    move_cursor(-vim.v.count1)
  end, "move up")

  map("n", "collections_move_down_alt", function()
    move_cursor(vim.v.count1)
  end, "move down")

  map("n", "collections_move_up_alt", function()
    move_cursor(-vim.v.count1)
  end, "move up")

  map("n", "collections_next_section", function()
    jump_section(1)
  end, "next section")

  map("n", "collections_prev_section", function()
    jump_section(-1)
  end, "prev section")

  map("n", "collections_select", on_enter, "select collection")

  map("n", "collections_toggle_pane", function()
    layout.toggle_collections()
  end, "toggle collections pane")

  map("n", "collections_focus_items", function()
    layout.focus_items()
  end, "focus items")

  map("n", "collections_new", function()
    local entry = M.get_collection_at_line(cursor_line)
    local parent_key = nil
    local parent_name = ""
    if entry and entry.collectionID and not entry.is_trash and not entry.is_separator then
      parent_key = collection_keys_by_id[entry.collectionID]
      parent_name = entry.line:match("^%s*[▶▼ ]*%s*(.-)%s*%(") or ""
      if parent_name ~= "" then
        parent_name = " in '" .. parent_name .. "'"
      end
    end
    vim.ui.input({ prompt = "Collection name" .. parent_name .. ": " }, function(name)
      if name and name ~= "" then
        async_mod.run("zotero:ui.collections.new", function()
          local ok = async_mod.await(require("zotero.api").create_collection(vim.trim(name), parent_key))
          if ok then
            M.refresh_counts()
          end
        end)
      end
    end)
  end, "create collection")

  map("n", "collections_delete", function()
    local entry = M.get_collection_at_line(cursor_line)
    if not entry or not entry.collectionID then
      return
    end
    local name = entry.line:match("^%s*[▶▼ ]*%s*(.-)%s*%(") or "(unknown)"
    local choice = vim.fn.confirm("Move collection '" .. name .. "' to trash?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
    async_mod.run("zotero:ui.collections.trash", function()
      local key = collection_keys_by_id[entry.collectionID]
      if not key or key == "" then
        async_mod.notify("zotero: cannot determine collection key", vim.log.levels.ERROR)
        return
      end
      local ok = async_mod.await(require("zotero.api").trash_collection(key))
      if ok then
        async_mod.notify("zotero: trashed collection '" .. name .. "'", vim.log.levels.INFO)
        M.refresh_counts()
      end
    end)
  end, "trash collection")

  map("n", "collections_show_help", M.show_help, "help")
end

function M.show_help()
  async_mod.notify(table.concat({
    "zotero.nvim - Collections",
    "─────────────────────────",
    "  j/k           Navigate",
    "  <Up>/<Down>   Navigate (alternative)",
    "  ]] / [[       Next / prev section",
    "  <CR>          Select collection / Trash",
    "  <Tab>         Focus items pane",
    "  <leader>zt    Toggle collections pane",
    "  <leader>zN    Create collection",
    "  <leader>zD    Trash collection",
    "  g?            This help",
  }, "\n"), vim.log.levels.INFO, { title = "zotero" })
end

function M.get_selected_collection_id()
  return selected_collection_id
end

function M.get_selected_collection_key()
  if not selected_collection_id then
    return nil
  end
  return collection_keys_by_id[selected_collection_id]
end

return M