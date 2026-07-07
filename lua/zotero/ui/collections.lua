local M = {}

local db = require("zotero.db")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")

local collections_data = {}
local expanded = {}
local selected_collection_id = nil
local cursor_line = 1
local total_item_count = 0

local function get_display_lines()
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

  local marked_count = items.get_marked_count()
  table.insert(lines, {
    line = "  Marked Items (" .. tostring(marked_count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_marked_items = true,
  })

  table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true })

  local count = db.get_trash_count()
  table.insert(lines, {
    line = "  Trash (" .. tostring(count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_trash = true,
  })

  return lines
end

function M.render()
  local buf = layout.get_collections_buf()
  if not buf then
    return
  end

  collections_data = db.get_collections()
  local stats = db.get_stats()
  total_item_count = stats.items

  expanded["root"] = true
  for _, col in ipairs(collections_data) do
    if col.depth == 0 then
      expanded[col.collectionID] = true
    end
  end

  M.refresh_display()

  vim.api.nvim_buf_clear_namespace(buf, vim.api.nvim_create_namespace("zotero-collections"), 0, -1)

  M.set_keymaps()
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
  collections_data = db.get_collections()
  local stats = db.get_stats()
  total_item_count = stats.items
  M.refresh_display()
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

  vim.keymap.set("n", "j", function()
    move_cursor(vim.v.count1)
  end, { buffer = buf, silent = true, desc = "zotero: move down" })

  vim.keymap.set("n", "k", function()
    move_cursor(-vim.v.count1)
  end, { buffer = buf, silent = true, desc = "zotero: move up" })

  vim.keymap.set("n", "<Down>", function()
    move_cursor(vim.v.count1)
  end, { buffer = buf, silent = true, desc = "zotero: move down" })

  vim.keymap.set("n", "<Up>", function()
    move_cursor(-vim.v.count1)
  end, { buffer = buf, silent = true, desc = "zotero: move up" })

  vim.keymap.set("n", "]]", function()
    jump_section(1)
  end, { buffer = buf, silent = true, desc = "zotero: next section" })

  vim.keymap.set("n", "[[", function()
    jump_section(-1)
  end, { buffer = buf, silent = true, desc = "zotero: prev section" })

  vim.keymap.set("n", "<CR>", on_enter, { buffer = buf, silent = true, desc = "zotero: select collection" })

  vim.keymap.set("n", "<leader>zt", function()
    layout.toggle_collections()
  end, { buffer = buf, silent = true, desc = "zotero: toggle collections pane" })

  vim.keymap.set("n", "<Tab>", function()
    layout.focus_items()
  end, { buffer = buf, silent = true, desc = "zotero: focus items" })

  vim.keymap.set("n", "<leader>zN", function()
    local entry = M.get_collection_at_line(cursor_line)
    local parent_key = nil
    local parent_name = ""
    if entry and entry.collectionID and not entry.is_trash and not entry.is_separator then
      parent_key = db.get_collection_key(entry.collectionID)
      parent_name = entry.line:match("^%s*[▶▼ ]*%s*(.-)%s*%(") or ""
      if parent_name ~= "" then
        parent_name = " in '" .. parent_name .. "'"
      end
    end
    vim.ui.input({ prompt = "New collection name" .. parent_name .. ": " }, function(name)
      if name and name ~= "" then
        require("zotero.api").create_collection(vim.trim(name), parent_key)
        M.refresh_counts()
      end
    end)
  end, { buffer = buf, silent = true, desc = "zotero: create collection" })

  vim.keymap.set("n", "<leader>zD", function()
    local entry = M.get_collection_at_line(cursor_line)
    if not entry or not entry.collectionID then
      return
    end
    local name = entry.line:match("^%s*[▶▼ ]*%s*(.-)%s*%(") or "(unknown)"
    local choice = vim.fn.confirm("Move collection '" .. name .. "' to trash?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end
    local key = db.get_collection_key(entry.collectionID)
    if not key or key == "" then
      vim.notify("zotero: cannot determine collection key", vim.log.levels.ERROR)
      return
    end
    local ok = require("zotero.api").trash_collection(key)
    if ok then
      vim.notify("zotero: trashed collection '" .. name .. "'", vim.log.levels.INFO)
      M.refresh_counts()
    end
  end, { buffer = buf, silent = true, desc = "zotero: trash collection" })
end

function M.get_selected_collection_id()
  return selected_collection_id
end

function M.get_selected_collection_key()
  if not selected_collection_id then
    return nil
  end
  return db.get_collection_key(selected_collection_id)
end

return M
