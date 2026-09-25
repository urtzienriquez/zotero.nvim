local M = {}

local db = require("zotero.db")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")
local async_mod = require("zotero.async")
local winopt = require("zotero.ui.winopt")

local collections_data = {}
local selected_collection_id = nil
local cursor_line = 1
local total_item_count = 0
local trash_count = 0
local feeds_data = {}
-- The pane is always drawn as the full tree and uses real Vim folds
-- (foldmethod=expr), so zo/zc/za/zR/zM/zj/zk... all work. fold_closed holds
-- each fold's open/closed state by id ("section:library", "section:feeds",
-- "section:tags", "col:<collectionID>"): it is read back from the window
-- before every redraw and re-applied after it, since replacing the buffer
-- lines would otherwise reset the folds. Defaults: My Library and
-- top-level collections open, Feeds, Tags and deeper collections closed.
local fold_closed = { ["section:library"] = false, ["section:feeds"] = true, ["section:tags"] = true }
-- Fold level of each buffer line (for foldexpr), matching the drawn lines.
local fold_levels = {}
-- The entries currently drawn in the buffer (their fold ids map buffer
-- lines back to fold_closed when reading the window's fold state).
local rendered_entries = {}
-- Tags section: library-wide tag counts and Zotero's colored tags.
local tag_counts = {}
local colored_tags = {}
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
  local tag_filter = items.get_tag_filter()
  local cache_key = table.concat({ _structure_version, total_item_count, trash_count, marked_count,
    table.concat(tag_filter, "\31") }, "|")
  -- feeds_data is only replaced in load_data(), which bumps _structure_version.
  if _display_lines_cache and _display_lines_cache_key == cache_key then
    return _display_lines_cache
  end

  -- Foldable lines always say ▼ in the buffer; a closed fold is displayed
  -- through foldtext(), which shows ▶ instead.
  local lines = {}
  table.insert(lines, {
    line = "▼ My Library (" .. tostring(total_item_count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_all_items = true,
    section = "library",
    fold_id = "section:library",
    fold_level = ">1",
  })

  local children_of = {}
  for _, col in ipairs(collections_data) do
    if col.parentCollectionID then
      children_of[col.parentCollectionID] = true
    end
  end

  for _, col in ipairs(collections_data) do
    -- One level deeper than the My Library header they sit under.
    local indent = string.rep("  ", col.depth + 1)
    local has_children = children_of[col.collectionID] or false
    local count_str = " (" .. tostring(col.item_count) .. ")"
    table.insert(lines, {
      line = indent .. (has_children and "▼ " or "  ") .. col.collectionName .. count_str,
      collectionID = col.collectionID,
      has_children = has_children,
      depth = col.depth,
      -- Inside My Library's fold (level 1) and its ancestors' folds; a
      -- collection with children starts a fold of its own.
      fold_id = has_children and ("col:" .. col.collectionID) or nil,
      fold_level = has_children and (">" .. (col.depth + 2)) or tostring(col.depth + 1),
    })
  end

  table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true, fold_level = "0" })

  -- Each feed is its own Zotero library (as in Zotero's own collection tree,
  -- where "Feeds" sits between the libraries and the rest). The header is
  -- always shown, even with no feeds, so collections_new (aa) on it can add the first.
  do
    local total_unread = 0
    for _, feed in ipairs(feeds_data) do
      total_unread = total_unread + (tonumber(feed.unread) or 0)
    end
    table.insert(lines, {
      line = "▼ Feeds (" .. tostring(total_unread) .. ")",
      collectionID = nil,
      has_children = false,
      depth = 0,
      is_feeds_header = true,
      section = "feeds",
      fold_id = "section:feeds",
      fold_level = ">1",
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
        fold_level = "1",
      })
    end
    table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true, fold_level = "0" })
  end

  -- Tags: colored tags first ("1 ● to-read"), then the rest. <CR> on a tag
  -- adds/removes it from the items tag filter; active ones get a ✓.
  do
    local tag_filter_mod = require("zotero.ui.tag_filter")
    local rows = tag_filter_mod.ordered(tag_counts, tag_filter, colored_tags)
    table.insert(lines, {
      line = "▼ Tags (" .. tostring(#rows) .. ")",
      collectionID = nil,
      has_children = false,
      depth = 0,
      is_tags_header = true,
      section = "tags",
      fold_id = "section:tags",
      fold_level = ">1",
    })
    local any_colored = #colored_tags > 0
    for _, row in ipairs(rows) do
      local active = vim.tbl_contains(tag_filter, row.name)
      local head = "  " .. (active and "✓ " or "  ")
      local prefix = tag_filter_mod.prefix(row.index, any_colored)
      table.insert(lines, {
        line = head .. prefix .. row.name .. " (" .. tostring(row.count) .. ")",
        collectionID = nil,
        has_children = false,
        depth = 1,
        is_tag = true,
        tag_name = row.name,
        tag_index = row.index,
        tag_active = active,
        -- byte columns for apply_highlights()
        dot_col = row.index and (#head + #(tostring(row.index) .. " ")) or nil,
        name_col = #head + #prefix,
        fold_level = "1",
      })
    end
    table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true, fold_level = "0" })
  end

  table.insert(lines, {
    line = "  Marked Items (" .. tostring(marked_count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_marked_items = true,
    fold_level = "0",
  })

  table.insert(lines, { line = "", collectionID = nil, has_children = false, depth = 0, is_separator = true, fold_level = "0" })

  table.insert(lines, {
    line = "  Trash (" .. tostring(trash_count) .. ")",
    collectionID = nil,
    has_children = false,
    depth = 0,
    is_trash = true,
    fold_level = "0",
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
  local t_tags = db.get_tag_counts(nil, nil)
  local t_colored = db.get_colored_tags()

  collections_data = async_mod.await(t_collections)
  local stats = async_mod.await(t_stats)
  total_item_count = stats.items
  trash_count = async_mod.await(t_trash_count)
  feeds_data = async_mod.await(t_feeds) or {}
  tag_counts = async_mod.await(t_tags) or {}
  colored_tags = async_mod.await(t_colored) or {}

  collection_keys_by_id = {}
  for _, col in ipairs(collections_data) do
    collection_keys_by_id[col.collectionID] = col.key
  end

  -- A collection seen for the first time gets the default: top-level ones
  -- open, deeper ones closed. Later reloads keep whatever the user did.
  for _, col in ipairs(collections_data) do
    local id = "col:" .. col.collectionID
    if fold_closed[id] == nil then
      fold_closed[id] = col.depth > 0
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

local function collections_win()
  local win = layout.get_collections_win()
  return win and vim.api.nvim_win_is_valid(win) and win or nil
end

-- foldexpr / foldtext for the collections window (see setup_folds).
function M.foldexpr(lnum)
  return fold_levels[lnum] or "0"
end

function M.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local indent, rest = line:match("^(%s*)▼ (.*)$")
  if not indent then
    return line
  end
  local name, count = rest:match("^(.-)(%s%(%d+%))$")
  return {
    { indent, "Normal" },
    { "▶ ", "ZoteroCollectionArrow" },
    { name or rest, "Normal" },
    { count or "", "ZoteroItemCount" },
  }
end

local function setup_folds(win)
  if vim.w[win].zotero_folds then
    return
  end
  winopt.set(win, "foldmethod", "expr")
  winopt.set(win, "foldexpr", "v:lua.require'zotero.ui.collections'.foldexpr(v:lnum)")
  winopt.set(win, "foldtext", "v:lua.require'zotero.ui.collections'.foldtext()")
  winopt.set(win, "foldenable", true)
  winopt.set(win, "foldminlines", 0) -- a section with a single entry can still close
  winopt.set(win, "foldlevel", 99)
  winopt.set(win, "fillchars", "fold: ")
  vim.w[win].zotero_folds = true
end

-- Reads each drawn fold's state from the window into fold_closed. A fold
-- hidden inside a closed parent can't be read and keeps its stored state.
local function read_fold_state(win)
  if not vim.w[win].zotero_folds then
    return -- a fresh window has no folds yet; nothing to read
  end
  vim.api.nvim_win_call(win, function()
    for i, entry in ipairs(rendered_entries) do
      if entry.fold_id then
        local closed_at = vim.fn.foldclosed(i)
        if closed_at == i then
          fold_closed[entry.fold_id] = true
        elseif closed_at == -1 then
          fold_closed[entry.fold_id] = false
        end
      end
    end
  end)
end

-- Re-applies fold_closed after the lines were replaced: open everything,
-- then close bottom-up so nested folds close before their parents (zc on a
-- line whose own fold is already closed would close the parent instead).
local function apply_fold_state(win)
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    vim.cmd("silent! normal! zR")
    for i = #rendered_entries, 1, -1 do
      local id = rendered_entries[i].fold_id
      if id and fold_closed[id] then
        vim.api.nvim_win_set_cursor(win, { i, 0 })
        vim.cmd("silent! normal! zc")
      end
    end
    vim.fn.winrestview(view)
  end)
end

function M.refresh_display()
  local buf = layout.get_collections_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = collections_win()
  if win then
    read_fold_state(win)
  end

  local display_lines = get_display_lines()
  local lines, levels = {}, {}
  for i, dl in ipairs(display_lines) do
    lines[i] = dl.line
    levels[i] = dl.fold_level or "0"
  end
  fold_levels = levels -- before set_lines: foldexpr reads it
  rendered_entries = display_lines
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

  if win then
    setup_folds(win)
    vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
    apply_fold_state(win)
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

  -- Tags section: coloured dots and the ✓ of tags in the active filter.
  require("zotero.ui.highlights").set_tag_colors(colored_tags)
  for i, dl in ipairs(get_display_lines()) do
    if dl.is_tag and lines[i] == dl.line then
      if dl.tag_active then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemMarker", i - 1, 2, 2 + #"✓")
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemTitle", i - 1, dl.name_col, dl.name_col + #dl.tag_name)
      end
      if dl.dot_col then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, dl.dot_col, {
          end_col = dl.dot_col + #"●",
          hl_group = "ZoteroTagColor" .. dl.tag_index,
          priority = 4200, -- above nvim_buf_add_highlight's 4096
        })
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
-- The name defaults to the feed's own title. Used by collections_new (aa) on the Feeds
-- section and by :ZoteroAddFeed without arguments.
function M.add_feed(url, name)
  local function go(u)
    if not u or vim.trim(u) == "" then
      return
    end
    async_mod.run("zotero:ui.collections.add_feed", function()
      local res = async_mod.await(require("zotero.api").add_feed(vim.trim(u), name))
      if res then
        async_mod.to_main()
        M.set_section_open("feeds", true)
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

-- Puts every fold back to its default state (My Library and top-level
-- collections open; Feeds, Tags and deeper collections closed).
function M.reset_folds()
  fold_closed = { ["section:library"] = false, ["section:feeds"] = true, ["section:tags"] = true }
  for _, col in ipairs(collections_data) do
    fold_closed["col:" .. col.collectionID] = col.depth > 0
  end
  local win = collections_win()
  if win and vim.w[win].zotero_folds then
    apply_fold_state(win)
  end
end

-- Opens/closes a top-level section ("library", "feeds" or "tags").
function M.set_section_open(name, open)
  local id = "section:" .. name
  if fold_closed[id] == nil then
    return
  end
  local win = collections_win()
  if win then
    read_fold_state(win) -- keep the other folds as the user left them
  end
  fold_closed[id] = not open
  if win and vim.w[win].zotero_folds then
    apply_fold_state(win)
  end
end

-- The line under the cursor; on a closed fold, the fold's first line (the
-- section header or collection it represents).
local function current_line(win)
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local fold_start = vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(line)
  end)
  return fold_start ~= -1 and fold_start or line
end

-- Toggles the fold of the header/collection under the cursor (like za).
local function toggle_fold_at_cursor(win)
  vim.api.nvim_win_call(win, function()
    vim.cmd("silent! normal! za")
  end)
end

-- Focuses the collections pane (showing it if hidden) with the cursor on
-- the Feeds header. Used by goto_feeds (gf) in both panes.
function M.focus_feeds()
  if not layout.get_collections_win() or not vim.api.nvim_win_is_valid(layout.get_collections_win()) then
    layout.toggle_collections()
  end
  layout.focus_collections()
  M.set_section_open("feeds", true)
  for i, dl in ipairs(get_display_lines()) do
    if dl.is_feeds_header then
      cursor_line = i
      vim.api.nvim_win_set_cursor(layout.get_collections_win(), { i, 0 })
      return
    end
  end
end

local function on_enter()
  local win = layout.get_collections_win()
  if not win then
    return
  end
  cursor_line = current_line(win)
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

  -- Feeds / Tags have no item view of their own: <CR> opens/closes them.
  if entry.is_feeds_header or entry.is_tags_header then
    toggle_fold_at_cursor(win)
    return
  end

  -- A tag: add it to / remove it from the items tag filter. Focus stays here
  -- so several tags can be combined, like Zotero's tag selector.
  if entry.is_tag then
    local filter = items.get_tag_filter()
    items.set_tag_filter(require("zotero.ui.tag_filter").toggle(filter, entry.tag_name))
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
    toggle_fold_at_cursor(win)
  end

  selected_collection_id = entry.collectionID
  items.load_items(entry.collectionID)
  layout.focus_items()
end

-- Native j/k, so closed folds are skipped like in any buffer.
local function move_cursor(delta)
  local win = layout.get_collections_win()
  if not win then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd(("silent! normal! %d%s"):format(math.abs(delta), delta > 0 and "j" or "k"))
  end)
  cursor_line = vim.api.nvim_win_get_cursor(win)[1]
end

local function jump_section(direction)
  local display_lines = get_display_lines()
  local win = layout.get_collections_win()
  if win and vim.api.nvim_win_is_valid(win) then
    cursor_line = current_line(win)
  end
  local target = cursor_line + direction
  while target >= 1 and target <= #display_lines do
    local line = display_lines[target]
    if not line.is_separator and line.line ~= "" then
      if line.is_all_items or line.is_feeds_header or line.is_tags_header or line.is_marked_items or line.is_trash then
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
    local entry = M.get_collection_at_line(current_line(vim.api.nvim_get_current_win()))
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
    local entry = M.get_collection_at_line(current_line(vim.api.nvim_get_current_win()))
    if entry and entry.is_feed then
      delete_feed(entry)
      return
    end
    if entry and entry.is_tag then
      require("zotero.ui.tag_actions").delete_tag(entry.tag_name)
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

  -- dd on a visual selection in the Tags section: delete all selected tags.
  map("x", "collections_delete", function()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    local names = {}
    for line = first, last do
      local entry = M.get_collection_at_line(line)
      -- Only tags you can see: a closed Tags fold in the selection would
      -- otherwise select every tag.
      if entry and entry.is_tag and vim.fn.foldclosed(line) == -1 then
        names[#names + 1] = entry.tag_name
      end
    end
    if #names == 0 then
      async_mod.notify("zotero: select tags in the Tags section to delete them", vim.log.levels.INFO)
      return
    end
    require("zotero.ui.tag_actions").delete_tags(names)
  end, "delete selected tags")

  -- cc on a tag: assign/remove its colour and number key (Zotero's
  -- "Assign Colour…").
  map("n", "collections_tag_colour", function()
    local entry = M.get_collection_at_line(current_line(vim.api.nvim_get_current_win()))
    if entry and entry.is_tag then
      require("zotero.ui.tag_actions").assign_colour(entry.tag_name)
    else
      async_mod.notify("zotero: put the cursor on a tag in the Tags section", vim.log.levels.INFO)
    end
  end, "assign tag colour")

  map("n", "collections_refresh", function()
    local entry = M.get_collection_at_line(current_line(vim.api.nvim_get_current_win()))
    if entry and entry.is_feed then
      M.refresh_feeds(entry.feed_library_id)
    elseif entry and entry.is_feeds_header then
      M.refresh_feeds(nil)
    else
      M.refresh_counts()
    end
  end, "refresh (feed: fetch new items)")

  map("n", "collections_show_help", M.show_help, "help")

  -- g: navigation, same keys as in the items pane
  map("n", "goto_library", function()
    selected_collection_id = nil
    items.load_items(nil)
    layout.focus_items()
  end, "go to My Library")
  map("n", "items_show_only_marked", function()
    items.load_marked()
    layout.focus_items()
  end, "go to marked items")
  map("n", "goto_trash", function()
    items.load_trash()
    layout.focus_items()
  end, "go to Trash")
  map("n", "goto_feeds", M.focus_feeds, "go to Feeds")
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