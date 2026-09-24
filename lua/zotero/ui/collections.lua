local M = {}

local db = require("zotero.db")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")
local async_mod = require("zotero.async")

local collections_data = {}
local expanded = {}
local seen_roots = {}
local selected_collection_id = nil
local cursor_line = 1
local total_item_count = 0
local trash_count = 0
local feeds_data = {}
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
  -- feeds_data is only replaced in load_data(), which bumps _structure_version.
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

  -- Each feed is its own Zotero library (as in Zotero's own collection tree,
  -- where "Feeds" sits between the libraries and the rest). The header is
  -- always shown, even with no feeds, so <leader>zN on it can add the first.
  do
    local total_unread = 0
    for _, feed in ipairs(feeds_data) do
      total_unread = total_unread + (tonumber(feed.unread) or 0)
    end
    table.insert(lines, {
      line = "  Feeds (" .. tostring(total_unread) .. ")",
      collectionID = nil,
      has_children = false,
      depth = 0,
      is_feeds_header = true,
    })
    for _, feed in ipairs(feeds_data) do
      table.insert(lines, {
        line = "    " .. feed.name .. " (" .. tostring(feed.unread or 0) .. ")",
        collectionID = nil,
        has_children = false,
        depth = 1,
        is_feed = true,
        feed_library_id = feed.libraryID,
        feed_name = feed.name,
      })
    end
    table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true })
  end

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
  -- Launched before awaiting so the queries run concurrently.
  local t_collections = db.get_collections()
  local t_stats = db.get_stats()
  local t_trash_count = db.get_trash_count()
  local t_feeds = db.get_feeds()

  collections_data = async_mod.await(t_collections)
  local stats = async_mod.await(t_stats)
  total_item_count = stats.items
  trash_count = async_mod.await(t_trash_count)
  feeds_data = async_mod.await(t_feeds) or {}

  collection_keys_by_id = {}
  for _, col in ipairs(collections_data) do
    collection_keys_by_id[col.collectionID] = col.key
  end

  expanded["root"] = true
  -- Top-level collections start expanded, but only the first time they're
  -- seen: re-expanding on every reload would undo the user's collapses
  -- whenever counts refresh (and race a collapse made mid-render).
  for _, col in ipairs(collections_data) do
    if col.depth == 0 and not seen_roots[col.collectionID] then
      seen_roots[col.collectionID] = true
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

-- Prompts for a feed URL and subscribes to it through the companion plugin.
-- The name defaults to the feed's own title. Used by <leader>zN on the Feeds
-- section and by :ZoteroAddFeed without arguments.
function M.add_feed(url, name)
  local function go(u)
    if not u or vim.trim(u) == "" then
      return
    end
    async_mod.run("zotero:ui.collections.add_feed", function()
      local res = async_mod.await(require("zotero.api").add_feed(vim.trim(u), name))
      if res then
        M.refresh_counts()
      end
    end)
  end
  if url then
    go(url)
  else
    vim.ui.input({ prompt = "Feed URL (RSS/Atom): " }, go)
  end
end

-- Refreshes one feed (library_id) or all feeds (nil) in Zotero, then
-- re-renders counts, and the item list if it's showing a refreshed feed.
function M.refresh_feeds(library_id)
  async_mod.notify("zotero: refreshing " .. (library_id and "feed" or "all feeds") .. "…", vim.log.levels.INFO)
  async_mod.run("zotero:ui.collections.refresh_feeds", function()
    async_mod.await(require("zotero.api").refresh_feeds(library_id))
    async_mod.to_main()
    M.refresh_counts()
    local shown = items.get_feed_library_id()
    if shown and (library_id == nil or shown == library_id) then
      items.fetch_and_render(true)
    end
  end)
end

local function delete_feed(entry)
  local choice = vim.fn.confirm("Unsubscribe from feed '" .. entry.feed_name .. "'? Its items will be removed.", "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  async_mod.run("zotero:ui.collections.delete_feed", function()
    local ok = async_mod.await(require("zotero.api").delete_feed(entry.feed_library_id))
    if not ok then
      return
    end
    async_mod.to_main()
    if items.get_feed_library_id() == entry.feed_library_id then
      items.load_items(nil)
    end
    M.refresh_counts()
  end)
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

  if entry.is_separator or entry.is_feeds_header then
    return
  end

  if entry.is_feed then
    selected_collection_id = nil
    items.load_feed(entry.feed_library_id, entry.feed_name)
    layout.focus_items()
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
      if line.is_all_items or line.is_feeds_header or line.is_marked_items or line.is_trash then
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
    local entry = M.get_collection_at_line(vim.api.nvim_win_get_cursor(0)[1])
    if entry and (entry.is_feeds_header or entry.is_feed) then
      M.add_feed()
      return
    end
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
    local entry = M.get_collection_at_line(vim.api.nvim_win_get_cursor(0)[1])
    if entry and entry.is_feed then
      delete_feed(entry)
      return
    end
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

  map("n", "collections_refresh", function()
    local entry = M.get_collection_at_line(vim.api.nvim_win_get_cursor(0)[1])
    if entry and entry.is_feed then
      M.refresh_feeds(entry.feed_library_id)
    elseif entry and entry.is_feeds_header then
      M.refresh_feeds(nil)
    else
      M.refresh_counts()
    end
  end, "refresh (feed: fetch new items)")

  map("n", "collections_show_help", M.show_help, "help")
end

function M.show_help()
  vim.cmd.help("zotero-collections-maps")
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