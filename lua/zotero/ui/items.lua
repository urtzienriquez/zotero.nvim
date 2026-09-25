local M = {}

local db = require("zotero.db")
local types = require("zotero.types")
local layout = require("zotero.ui.layout")
local cfg_mod = require("zotero.config")
local async_mod = require("zotero.async")
local winopt = require("zotero.ui.winopt")

local items_data = {}
local cursor_line = 1
local current_collection_id = nil
local sort_by = cfg_mod.get().default_sort or "dateAdded"
local sort_dir = cfg_mod.get().default_sort_dir or "desc"
local search_term = ""
local is_searching = false
local is_trash_mode = false
local marked_items = {}
local show_only_marked = false
-- libraryID/name of the feed being browsed, or nil for the user library.
-- Feed items are read-only here (see readonly_guard()).
local current_feed_library_id = nil
local current_feed_name = nil
-- Item-type filter; deliberately survives collection/feed/search changes.
-- mode "exclude" hides `types`, mode "include" shows only `types`.
local type_filter = {
  mode = "exclude",
  types = vim.deepcopy(cfg_mod.get().hidden_item_types or {}),
}
-- Tag filter: names of tags every listed item must have (Zotero's
-- tag-selector logic). Survives view changes like type_filter.
local tag_filter = {}
-- Zotero's colored tags ({ name, color } in key order 1-9), refreshed with
-- every list load; drives the coloured dots and t1-t9.
local colored_tags = {}
local TAG_DOT = "●"
local last_items_width = -1
local _resize_autocmd_set = false
local _render_version = nil
-- Bumped on every fetch_and_render() call; lets a superseded in-flight
-- render bail out instead of overwriting newer results.
local _fetch_generation = 0

local function sql_str(val, default)
  if type(val) ~= "string" then
    return default or ""
  end
  return val
end

local _preset_index = 0
local _compact_hl_regions = {}

local PRESETS = {
  { name = "configured" },
  { name = "compact", columns = { "__compact__" } },
  { name = "normal", columns = { "#", "title", "authors", "year", "type" } },
  { name = "full", columns = { "#", "key", "title", "authors", "year", "journal", "dateAdded", "type" } },
}

local function preset_index_by_name(name)
  for i, p in ipairs(PRESETS) do
    if p.name == name then
      return i - 1
    end
  end
  return nil
end

-- The library and feed views each remember their own column preset, so a
-- feed can default to the compact list (feed items rarely have authors,
-- journals or keys worth a column) without changing the library table.
local _preset_by_view = {
  library = 0,
  feed = preset_index_by_name(cfg_mod.get().feed_view or "compact") or 1,
}

local function is_compact_mode()
  return _preset_index == 1
end

local function line_to_idx(line)
  return is_compact_mode() and line or (line - 2)
end

local function min_cursor_line()
  return is_compact_mode() and 1 or 3
end

local function get_item_at_visible_line(line)
  local idx = line_to_idx(line)
  if idx < 1 then
    return nil
  end

  if show_only_marked then
    local n = 0
    for _, item in ipairs(items_data) do
      if marked_items[item.itemID] then
        n = n + 1
        if n == idx then
          return item
        end
      end
    end
    return nil
  end

  return items_data[idx]
end

-- Title prefixed with one ● per colored tag the item has (coloured by
-- highlight_tag_dots()), like the dots in Zotero's item list.
local function title_with_dots(item)
  local title = sql_str(item.title, "(no title)")
  if item._tag_dots then
    return string.rep(TAG_DOT, #item._tag_dots) .. " " .. title
  end
  return title
end

local COLUMN_DEFS = {
  ["#"] = { header = "  #", width = 4, align = "right", extract = function(item, idx) return (marked_items[item.itemID] and "*" or " ") .. tostring(idx) end },
  key = { header = "Key", width = 12, extract = function(item, idx, w) return types.truncate(sql_str(item._is_collection and item._is_collection ~= 0 and "[Coll]" or item.citationKey), w or 12) end },
  title = { header = "Title", width = 60, extract = function(item, idx, w) return types.truncate(title_with_dots(item), w or 60) end },
  authors = { header = "Authors", width = 23, extract = function(item, idx, w) return types.truncate(sql_str(item._authors), w or 23) end },
  year = { header = "Year", width = 4, extract = function(item) return (item._is_collection and item._is_collection ~= 0) and "" or ((item.year and item.year ~= vim.NIL) and tostring(item.year) or (type(item.date_str) == "string" and types.extract_year(item.date_str) or "")) end },
  journal = { header = "Journal", width = 30, extract = function(item, idx, w) return types.truncate(sql_str(item.publicationTitle), w or 30) end },
  dateAdded = { header = "Added", width = 12, extract = function(item, idx, w) return types.truncate(sql_str(item.dateAdded), w or 12) end },
  type = { header = "Type", width = 14, extract = function(item, idx, w) return types.truncate(sql_str(item.typeName), w or 14) end },
}

local COLUMN_HL = {
  ["#"] = nil,
  key = "ZoteroItemKey",
  title = "ZoteroItemTitle",
  authors = "ZoteroItemAuthor",
  year = "ZoteroItemYear",
  journal = "ZoteroValue",
  dateAdded = "ZoteroItemCount",
  type = "ZoteroItemType",
}

local function get_active_columns()
  local preset = PRESETS[_preset_index + 1]
  if preset.columns then
    return preset.columns
  end
  local cfg = cfg_mod.get()
  return cfg.columns or { "#", "title", "authors", "year", "type" }
end

local function empty_message()
  if search_term ~= "" then
    return "  (no items match search)"
  elseif is_trash_mode then
    return "  (trash is empty)"
  elseif current_collection_id then
    return "  (no items in this collection)"
  else
    return "  (no items in library)"
  end
end

local function format_items_compact(items)
  local lines = {}
  _compact_hl_regions = {}

  local win = layout.get_items_win()
  local avail = win and vim.api.nvim_win_is_valid(win) and vim.fn.winwidth(win) or 80

  for idx, item in ipairs(items) do
    local author = item._authors_compact or ""
    local year = ""
    if item.year and item.year ~= vim.NIL then
      year = tostring(item.year)
    elseif type(item.date_str) == "string" then
      year = types.extract_year(item.date_str)
    end
    year = year or ""
    local title = title_with_dots(item)

    local line
    if author ~= "" and year ~= "" then
      line = author .. " " .. year .. "  " .. title
    elseif author ~= "" then
      line = author .. "  " .. title
    elseif year ~= "" then
      line = year .. "  " .. title
    else
      line = title
    end

    local regions = {}
    local pos = 0
    if author ~= "" then
      regions[#regions + 1] = { pos, pos + #author, "ZoteroItemAuthor" }
      pos = pos + #author + 1
    end
    if year ~= "" then
      local year_end = pos + #year
      regions[#regions + 1] = { pos, year_end, "ZoteroItemYear" }
      pos = year_end + 2
    elseif author ~= "" then
      pos = pos + 1
    end
    regions[#regions + 1] = { pos, pos + #title, "ZoteroItemTitle" }

    if marked_items[item.itemID] then
      line = "* " .. line
      for _, r in ipairs(regions) do
        r[1] = r[1] + 2
        r[2] = r[2] + 2
      end
    elseif current_feed_library_id then
      -- Feed view: unread dot in front; read items just lose the dot.
      local unread = item.unread == 1
      local prefix = unread and "● " or "  "
      line = prefix .. line
      for _, r in ipairs(regions) do
        r[1] = r[1] + #prefix
        r[2] = r[2] + #prefix
      end
      if unread then
        table.insert(regions, 1, { 0, #"●", "ZoteroFeedUnread" })
      end
    end

    if avail > 0 and vim.fn.strdisplaywidth(line) > avail then
      line = types.truncate(line, avail)
    end

    table.insert(lines, line)

    _compact_hl_regions[#lines] = regions
  end

  if #items == 0 then
    table.insert(lines, empty_message())
  end

  return lines
end

local function apply_highlights_compact(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local ns = vim.api.nvim_create_namespace("zotero-items-hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local lnum = i - 1

    if line:match("^%s*%(") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemCount", lnum, 0, -1)
    else
      local regions = _compact_hl_regions[i]
      if regions then
        for _, region in ipairs(regions) do
          local end_c = region[2] >= 0 and region[2] or -1
          vim.api.nvim_buf_add_highlight(buf, ns, region[3], lnum, region[1], end_c)
        end
      end
    end
  end

  for i, line in ipairs(lines) do
    if line:match("^%* ") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemMarker", i - 1, 0, 1)
    end
  end
end

local function format_items_table(items)
  if show_only_marked then
    local filtered = {}
    for _, item in ipairs(items) do
      if marked_items[item.itemID] then
        filtered[#filtered + 1] = item
      end
    end
    items = filtered
  end

  if is_compact_mode() then
    return format_items_compact(items)
  end
  local active_cols = get_active_columns()

  local win = layout.get_items_win()
  local available = win and vim.api.nvim_win_is_valid(win) and vim.fn.winwidth(win) or 80

  local function compute_widths()
    local widths = {}
    for _, key in ipairs(active_cols) do
      local def = COLUMN_DEFS[key]
      widths[key] = (def and (def.width or 15)) or 15
    end
    -- "#" holds the mark ("*") plus the row number: wide enough for the
    -- last one, so row 1400 isn't cut to "140".
    if widths["#"] then
      widths["#"] = math.max(widths["#"], 1 + #tostring(#items))
    end

    local MIN = 3
    local flex = { title = 20, authors = 12 }

    local sep_total = (#active_cols - 1) * 3
    local content_budget = math.max(0, available - sep_total)

    local fixed_total = 0
    for _, key in ipairs(active_cols) do
      if not flex[key] then
        fixed_total = fixed_total + (widths[key] or 0)
      end
    end

    local function flex_total()
      local t = 0
      for k, v in pairs(flex) do
        if widths[k] then
          t = t + v
        end
      end
      return t
    end

    -- Only title/authors expand or contract; the column metadata
    -- (#, key, year, journal, dateAdded, type) keeps its fixed width.
    if fixed_total + flex_total() <= content_budget then
      local surplus = content_budget - fixed_total - flex_total()
      local w1 = (flex.title and flex.title * 2) or 0
      local w2 = (flex.authors and flex.authors) or 0
      local denom = w1 + w2
      local s1 = (denom > 0) and math.floor(surplus * w1 / denom) or 0
      local s2 = surplus - s1
      if widths.title then
        widths.title = flex.title + s1
      end
      if widths.authors then
        widths.authors = flex.authors + s2
      end
    else
      for k, v in pairs(flex) do
        if widths[k] then
          widths[k] = v
        end
      end
      local total = fixed_total + flex_total()
      local it = 0
      while total > content_budget and it < 200 do
        it = it + 1
        local shrank = false
        for k, _ in pairs(flex) do
          if widths[k] and widths[k] > MIN then
            widths[k] = widths[k] - 1
            total = total - 1
            shrank = true
          end
        end
        if not shrank then
          break
        end
      end
    end
    return widths
  end

  local widths = compute_widths()

  local lines = {}

  local header_parts = {}
  for i, key in ipairs(active_cols) do
    local def = COLUMN_DEFS[key]
    if not def then
      def = { header = key, width = 15, align = "left" }
    end
    local w = widths[key] or (def.width or 15)
    local hdr = types.truncate(def.header, w)
    local padded = def.align == "right" and types.pad_left(hdr, w) or types.pad_right(hdr, w)
    table.insert(header_parts, padded)
  end
  local header_line = table.concat(header_parts, " │ ")
  table.insert(lines, header_line)

  local sep = string.rep("─", vim.fn.strdisplaywidth(header_line))
  table.insert(lines, sep)

  for idx, item in ipairs(items) do
    local parts = {}
    for _, key in ipairs(active_cols) do
      local def = COLUMN_DEFS[key]
      if not def then
        table.insert(parts, string.rep(" ", 15))
      else
        local w = widths[key] or def.width
        local val = types.truncate(def.extract(item, idx, w), w)
        local padded = def.align == "right" and types.pad_left(val, w) or types.pad_right(val, w)
        table.insert(parts, padded)
      end
    end
    table.insert(lines, table.concat(parts, " │ "))
  end

  if #items == 0 then
    table.insert(lines, empty_message())
  end

  return lines
end

local function load_authors_for_items(items)
  if #items == 0 then
    return items
  end
  local item_ids = vim.tbl_map(function(i) return i.itemID end, items)
  local all_creators = async_mod.await(db.get_items_authors(item_ids))
  local creators_by_item = {}
  for _, c in ipairs(all_creators) do
    creators_by_item[c.itemID] = creators_by_item[c.itemID] or {}
    table.insert(creators_by_item[c.itemID], c)
  end
  for _, item in ipairs(items) do
    local creators = creators_by_item[item.itemID] or {}
    item._authors = types.format_creators(creators)
    item._authors_compact = types.format_creators_compact(creators)
  end

  -- Colored-tag dots (not in feeds, where ● already means "unread").
  colored_tags = async_mod.await(db.get_colored_tags()) or {}
  if #colored_tags > 0 and not current_feed_library_id then
    local names = vim.tbl_map(function(t) return t.name end, colored_tags)
    local has = async_mod.await(db.get_items_tags(item_ids, names)) or {}
    for _, item in ipairs(items) do
      local dots = {}
      for i, name in ipairs(names) do
        if has[item.itemID] and has[item.itemID][name] then
          dots[#dots + 1] = i
        end
      end
      item._tag_dots = #dots > 0 and dots or nil
    end
  end
  return items
end

-- Switches between the library view and a feed's view, swapping in the
-- column preset that view last used.
local function set_feed(library_id, name)
  local old_view = current_feed_library_id and "feed" or "library"
  local new_view = library_id and "feed" or "library"
  if old_view ~= new_view then
    _preset_by_view[old_view] = _preset_index
    _preset_index = _preset_by_view[new_view]
    _compact_hl_regions = {}
  end
  current_feed_library_id = library_id
  current_feed_name = name
end

function M.load_items(collection_id)
  current_collection_id = collection_id
  set_feed(nil, nil)
  is_trash_mode = false
  search_term = ""
  is_searching = false
  show_only_marked = false
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.load_trash()
  current_collection_id = nil
  set_feed(nil, nil)
  is_trash_mode = true
  search_term = ""
  is_searching = false
  show_only_marked = false
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.load_marked()
  current_collection_id = nil
  set_feed(nil, nil)
  is_trash_mode = false
  search_term = ""
  is_searching = false
  show_only_marked = true
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.load_feed(library_id, name)
  current_collection_id = nil
  set_feed(library_id, name)
  is_trash_mode = false
  search_term = ""
  is_searching = false
  show_only_marked = false
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.is_feed_mode()
  return current_feed_library_id ~= nil
end

function M.get_feed_library_id()
  return current_feed_library_id
end

-- Feed items live in their own library, and the connector (like Zotero's
-- own UI) only edits the user library, so write actions are refused here.
-- Returns true (and notifies) when the caller should bail out.
function M.readonly_guard()
  if current_feed_library_id then
    async_mod.notify("zotero: feed items are read-only", vim.log.levels.WARN)
    return true
  end
  return false
end

local function type_filter_opts()
  local opts = { library_id = current_feed_library_id }
  if #tag_filter > 0 then
    opts.tags = tag_filter
  end
  if #type_filter.types > 0 then
    if type_filter.mode == "include" then
      opts.include_types = type_filter.types
    else
      opts.exclude_types = type_filter.types
    end
  end
  return opts
end

function M.get_type_filter()
  return vim.deepcopy(type_filter)
end

-- mode: "include" | "exclude"; types: list of itemTypes.typeName ({} = no filter).
function M.set_type_filter(mode, types_list)
  type_filter = { mode = mode or "exclude", types = types_list or {} }
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.get_tag_filter()
  return vim.deepcopy(tag_filter)
end

-- names: tags every listed item must have ({} = no tag filter).
function M.set_tag_filter(names)
  tag_filter = names or {}
  cursor_line = min_cursor_line()
  M.fetch_and_render()
  -- The collections pane marks the active tags in its Tags section.
  pcall(function()
    require("zotero.ui.collections").refresh_display()
  end)
end

function M.get_colored_tags()
  return vim.deepcopy(colored_tags)
end

-- The view the type checklist counts types in: a collection, a feed, or the
-- whole user library (also used for trash/marked, which the filter doesn't
-- narrow further).
function M.get_view_context()
  return { collection_id = current_collection_id, library_id = current_feed_library_id }
end

-- Type names for :ZoteroFilterType completion: whatever is in the loaded
-- list plus whatever the filter currently references. Synchronous (no DB
-- query), since command-line completion can't await.
function M.known_type_names()
  local seen, names = {}, {}
  local function add(n)
    if n and n ~= "" and not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  for _, item in ipairs(items_data) do
    add(item.typeName)
  end
  for _, t in ipairs(type_filter.types) do
    add(t)
  end
  table.sort(names)
  return names
end

function M.pick_type_filter()
  async_mod.run("zotero:ui.items.pick_type_filter", function()
    require("zotero.ui.type_filter").open()
  end)
end

function M.pick_tag_filter()
  async_mod.run("zotero:ui.items.pick_tag_filter", function()
    require("zotero.ui.tag_filter").open()
  end)
end

function M.restore_session()
  M.fetch_and_render()
end

-- Shared render-commit sequence: paints `items` into `buf`, clamps and
-- restores the cursor, and reapplies highlights. Callers still handle their
-- own status-bar/width-tracking calls afterward, since those differ per site.
local function commit_render(buf, items)
  vim.bo[buf].modifiable = true
  local lines = format_items_table(items)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  if cursor_line > #lines then
    cursor_line = #lines
  end
  local mcl = min_cursor_line()
  if cursor_line < mcl then
    cursor_line = #lines >= mcl and mcl or 1
  end

  M.apply_highlights(buf)
  vim.api.nvim_win_set_cursor(layout.get_items_win(), { cursor_line, 0 })

  return lines
end

function M.fetch_and_render(refresh_collections)
  _fetch_generation = _fetch_generation + 1
  local generation = _fetch_generation
  async_mod.run("zotero:ui.items.render", function()
    if refresh_collections then
      require("zotero.db").invalidate_cache()
    end
    local limit = show_only_marked and 100000 or nil
    local items
    if is_trash_mode then
      items = async_mod.await(db.get_trash_items(sort_by, sort_dir, limit))
    elseif current_collection_id then
      items = async_mod.await(db.get_items(current_collection_id, search_term, sort_by, sort_dir, limit, type_filter_opts()))
    else
      items = async_mod.await(db.search_global(search_term, sort_by, sort_dir, limit, type_filter_opts()))
    end

    items = load_authors_for_items(items)

    if generation ~= _fetch_generation then
      return
    end
    items_data = items

    async_mod.to_main()
    if generation ~= _fetch_generation then
      return
    end

    local buf = layout.get_items_buf()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    commit_render(buf, items)

    M.update_status()

    local win = layout.get_items_win()
    last_items_width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or -1

    if refresh_collections then
      require("zotero.ui.collections").refresh_counts()
    end

    _render_version = db.get_data_version()
  end)
end

-- Synchronously repopulate the items buffer from the last in-memory render
-- (no IPC, no event-loop hops) so an open after close is instant. Returns
-- true when the rendered data is still fresh, so the caller can skip the
-- background (re)query entirely.
function M.restore_render()
  local buf = layout.get_items_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if #items_data == 0 then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  (loading Zotero items…)" })
    vim.bo[buf].modifiable = false
    return false
  end
  M.rerender()
  return not db.is_stale_since(_render_version)
end

-- Colours each item's colored-tag dots (see title_with_dots) with the tag's
-- ZoteroTagColor<N> group. The title under them is highlighted with
-- nvim_buf_add_highlight, whose priority is 4096, so the dots must be higher.
local TAG_DOT_PRIORITY = 4200
local function highlight_tag_dots(buf)
  if #colored_tags == 0 then
    return
  end
  require("zotero.ui.highlights").set_tag_colors(colored_tags)
  local ns = vim.api.nvim_create_namespace("zotero-items-hl")
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local item = get_item_at_visible_line(i)
    if item and item._tag_dots then
      local start = line:find(string.rep(TAG_DOT, #item._tag_dots) .. " ", 1, true)
      if start then
        for k, index in ipairs(item._tag_dots) do
          local col = start - 1 + (k - 1) * #TAG_DOT
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, col, {
            end_col = col + #TAG_DOT,
            hl_group = "ZoteroTagColor" .. index,
            priority = TAG_DOT_PRIORITY,
          })
        end
      end
    end
  end
end

function M.apply_highlights(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  if is_compact_mode() then
    apply_highlights_compact(buf)
    highlight_tag_dots(buf)
    return
  end

  local ns = vim.api.nvim_create_namespace("zotero-items-hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local active_cols = get_active_columns()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    if i == 1 then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroHeader", i - 1, 0, -1)
    elseif i == 2 then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroSeparator", i - 1, 0, -1)
    else
      if line:match("^%s*%(") then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemCount", i - 1, 0, -1)
      else
        local pipes = {}
        for pos in line:gmatch("()│") do
          table.insert(pipes, pos - 1)
        end
        if #pipes >= #active_cols - 1 then
          for j, col_key in ipairs(active_cols) do
            local hl_group = COLUMN_HL[col_key]
            if hl_group then
              local start_c = (j == 1) and 0 or (pipes[j - 1] + 4)
              local end_c = (j == #active_cols) and -1 or (pipes[j] - 1)
              vim.api.nvim_buf_add_highlight(buf, ns, hl_group, i - 1, start_c, end_c)
            end
          end
        end
      end
    end
  end

  for i, line in ipairs(lines) do
    if i > 2 then
      local star_pos = line:find("%*%d")
      if star_pos then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemMarker", i - 1, star_pos - 1, star_pos)
      end
    end
  end

  highlight_tag_dots(buf)
end

function M.update_status()
  local win = layout.get_items_win()
  if not win then
    return
  end
  local info = "zotero"
  if current_feed_name then
    info = info .. "  feed: " .. current_feed_name
  end
  if #type_filter.types > 0 then
    info = info .. (type_filter.mode == "include" and "  types: only " or "  types: hiding ")
      .. table.concat(type_filter.types, ", ")
  end
  if #tag_filter > 0 then
    info = info .. "  tags: " .. table.concat(tag_filter, " + ")
  end
  if search_term ~= "" then
    info = info .. "  search: " .. search_term
  end
  info = info .. "  sort: " .. sort_by .. " (" .. sort_dir .. ")  " .. tostring(#items_data) .. " items"
  if _preset_index > 0 then
    info = info .. "  view: " .. PRESETS[_preset_index + 1].name
  end
  if show_only_marked then
    info = info .. "  [marked only]"
  end
  winopt.set(win, "winbar", info)
end

local function item_under_cursor()
  local win = layout.get_items_win()
  if not win then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  return get_item_at_visible_line(cursor[1])
end

local function show_detail()
  local item = item_under_cursor()
  if item then
    require("zotero.ui.detail").show_item(item.itemID, item.typeName)
  end
end

-- Opens the item's URL, falling back to its DOI, in the browser.
function M.open_item_url(item)
  if not item then
    return
  end
  async_mod.run("zotero:ui.items.open_url", function()
    local metadata = async_mod.await(db.get_item_metadata(item.itemID))
    local url = nil
    local doi = nil
    for _, m in ipairs(metadata) do
      if m.fieldName == "url" and m.value and m.value ~= "" then
        url = m.value
      elseif m.fieldName == "DOI" and m.value and m.value ~= "" then
        doi = m.value
      end
    end
    local link = url or (doi and "https://doi.org/" .. doi)
    if not link then
      async_mod.notify("zotero: no URL or DOI for this item", vim.log.levels.INFO)
      return
    end
    async_mod.to_main()
    M.open_external(link)
  end)
end

-- Sets the read state of feed items through the companion plugin, then
-- re-renders (list + unread counts). `quiet` is for the automatic
-- mark-as-read on open: it skips items that are already read and doesn't
-- report a missing companion plugin.
function M.set_items_read(items_list, read, quiet)
  local library_id = current_feed_library_id
  if not library_id then
    return
  end
  local targets = vim.tbl_filter(function(item)
    return item and item.itemID and (not quiet or (item.unread == 1) == read)
  end, items_list)
  if #targets == 0 then
    return
  end
  async_mod.run("zotero:ui.items.set_read", function()
    local key_map = async_mod.await(db.get_item_keys(vim.tbl_map(function(i) return i.itemID end, targets)))
    local keys = vim.tbl_values(key_map)
    if #keys == 0 then
      return
    end
    local ok = async_mod.await(require("zotero.api").set_feed_items_read(library_id, keys, read, { quiet = quiet }))
    if ok and current_feed_library_id == library_id then
      async_mod.to_main()
      M.fetch_and_render(true)
    end
  end)
end

-- Viewing a feed item marks it read, as selecting it does in Zotero.
local function mark_read_on_open(item)
  if item and current_feed_library_id and item.unread == 1 then
    M.set_items_read({ item }, true, true)
  end
end

-- <CR>: detail/preview panel.
local function on_enter()
  local item = item_under_cursor()
  show_detail()
  mark_read_on_open(item)
end

-- items_open_url: open the item's URL/DOI in the browser.
local function open_link()
  local item = item_under_cursor()
  M.open_item_url(item)
  mark_read_on_open(item)
end

local function toggle_sort(field)
  if sort_by == field then
    sort_dir = sort_dir == "desc" and "asc" or "desc"
  else
    sort_by = field
    sort_dir = "desc"
  end
  M.fetch_and_render()
end

local function rerender()
  local buf = layout.get_items_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  commit_render(buf, items_data)
  M.update_status()

  local win = layout.get_items_win()
  last_items_width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or -1
end

local function apply_preset(index)
  _preset_index = index
  _compact_hl_regions = {}
  cursor_line = min_cursor_line()
  rerender()
end

local function toggle_columns()
  local choices = {}
  for i, p in ipairs(PRESETS) do
    local label = p.name
    if i - 1 == _preset_index then
      label = label .. " (current)"
    end
    choices[#choices + 1] = label
  end

  vim.ui.select(choices, { prompt = "zotero view: " }, function(_, idx)
    if idx and idx - 1 ~= _preset_index then
      apply_preset(idx - 1)
    end
  end)
end

local function toggle_show_marked()
  show_only_marked = not show_only_marked
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

local function start_search()
  vim.ui.input({ prompt = "Search Zotero: " }, function(input)
    if input then
      search_term = input
      is_searching = true
      cursor_line = min_cursor_line()
      M.fetch_and_render()
    end
  end)
end

local function clear_search()
  search_term = ""
  is_searching = false
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

-- Calls `fn(attachment)` on the main thread with the item's attachment whose
-- file exists on disk, asking which one when there are several (`prompt`).
local function with_attachment_on_disk(item, prompt, fn)
  async_mod.run("zotero:ui.items.pick_attachment", function()
    local attachments = async_mod.await(db.get_item_attachments(item.itemID))
    if #attachments == 0 then
      async_mod.notify("zotero: no attachments for this item", vim.log.levels.INFO)
      return
    end
    local existing = vim.tbl_filter(function(a)
      return db.resolve_attachment_path(a) ~= nil
    end, attachments)
    if #existing == 0 then
      async_mod.notify("zotero: no attachment files found on disk for this item", vim.log.levels.INFO)
      return
    end
    async_mod.to_main()
    if #existing == 1 then
      fn(existing[1])
      return
    end

    local choices = {}
    for _, a in ipairs(existing) do
      table.insert(choices, a.title or a.path or "attachment")
    end
    vim.ui.select(choices, { prompt = prompt }, function(choice, idx)
      if choice and idx then
        fn(existing[idx])
      end
    end)
  end)
end

local function open_attachment()
  local item = item_under_cursor()
  if item then
    with_attachment_on_disk(item, "Open attachment:", M.open_file)
  end
end

-- Puts `text` in register `reg`: the one the mapping was called with
-- ("+yk -> the clipboard), or the default register, like a normal yank.
local function yank(reg, text, what)
  vim.fn.setreg(reg, text)
  async_mod.notify(("zotero: yanked %s: %s"):format(what, text), vim.log.levels.INFO)
end

local function yank_citation_key()
  local item = item_under_cursor()
  if not item then
    return
  end
  local key = sql_str(item.citationKey)
  if key == "" then
    async_mod.notify("zotero: this item has no citation key", vim.log.levels.INFO)
    return
  end
  yank(vim.v.register, key, "citation key")
end

local function yank_file_path()
  local item = item_under_cursor()
  if not item then
    return
  end
  -- Captured now: vim.v.register is only valid while the mapping runs, and
  -- picking among several attachments finishes later.
  local reg = vim.v.register
  with_attachment_on_disk(item, "Yank path of:", function(attachment)
    yank(reg, db.resolve_attachment_path(attachment), "file path")
  end)
end

function M.open_file(attachment)
  local full_path = db.resolve_attachment_path(attachment)
  if not full_path then
    async_mod.notify("zotero: attachment file not found on disk", vim.log.levels.WARN)
    return
  end

  M.open_external(full_path)
end

-- Opens a file or URL with the configured `pdf_viewer`, or the OS default
-- handler (vim.ui.open: open on macOS, xdg-open on Linux, start on Windows)
-- when none is configured.
function M.open_external(target)
  local viewer = require("zotero.config").get().pdf_viewer
  if viewer and viewer ~= "" then
    vim.fn.jobstart({ viewer, target }, { detach = true })
    return
  end
  local _, err = vim.ui.open(target)
  if err then
    async_mod.notify("zotero: failed to open " .. target .. ": " .. err, vim.log.levels.ERROR)
  end
end

local function get_visual_lines()
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("[vV\22]") then
    local start_line = vim.fn.line("v")
    local end_line = vim.fn.line(".")
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    return start_line, end_line
  end
end

local function delete_items_in_range(start_line, end_line)
  local seen = {}
  local to_delete = {}
  for line = start_line, end_line do
    local item = get_item_at_visible_line(line)
    if item and not seen[item.itemID] then
      seen[item.itemID] = true
      to_delete[#to_delete + 1] = item
    end
  end

  if #to_delete == 0 then
    return
  end

  local count = #to_delete
  local single = count == 1

  if is_trash_mode then
    local msg = single
      and ("Permanently delete '" .. (to_delete[1].title or "(no title)") .. "'? This cannot be undone.")
      or ("Permanently delete " .. count .. " items? This cannot be undone.")
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end

    async_mod.run("zotero:ui.items.erase", function()
      local collection_keys = {}
      local item_ids = {}
      for _, item in ipairs(to_delete) do
        if item._is_collection and item._is_collection ~= 0 then
          if item._trash_key then
            collection_keys[#collection_keys + 1] = item._trash_key
          end
        else
          item_ids[#item_ids + 1] = item.itemID
        end
      end

      -- One bulk lookup instead of one sqlite3 spawn per selected item.
      local key_map = async_mod.await(db.get_item_keys(item_ids))
      local item_keys = {}
      for _, id in ipairs(item_ids) do
        local key = key_map[id]
        if key and key ~= "" then
          item_keys[#item_keys + 1] = key
        end
      end

      local ok = async_mod.await(require("zotero.api").erase_items(item_keys, collection_keys))
      if ok then
        async_mod.notify("zotero: permanently deleted " .. count .. " item(s)", vim.log.levels.INFO)
        async_mod.to_main()
        M.fetch_and_render(true)
      end
    end)
    return
  end

  -- Normal mode: trash items
  local msg = single
    and ("Move '" .. (to_delete[1].title or "(no title)") .. "' to trash?")
    or ("Move " .. count .. " items to trash?")
  local choice = vim.fn.confirm(msg, "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end

  async_mod.run("zotero:ui.items.trash", function()
    -- One bulk lookup instead of one sqlite3 spawn per selected item.
    local item_ids = vim.tbl_map(function(item) return item.itemID end, to_delete)
    local key_map = async_mod.await(db.get_item_keys(item_ids))
    local item_keys = {}
    for _, id in ipairs(item_ids) do
      local key = key_map[id]
      if key and key ~= "" then
        item_keys[#item_keys + 1] = key
      end
    end

    local ok = async_mod.await(require("zotero.api").delete_items(item_keys))
    if ok then
      async_mod.notify("zotero: trashed " .. count .. " item(s)", vim.log.levels.INFO)
      async_mod.to_main()
      M.fetch_and_render(true)
    end
  end)
end

-- Items under the cursor, or in the visual selection (which it ends).
local function selected_items()
  local start_line, end_line = get_visual_lines()
  if not start_line then
    start_line = vim.api.nvim_win_get_cursor(0)[1]
    end_line = start_line
  end
  local list, seen = {}, {}
  for line = start_line, end_line do
    local item = get_item_at_visible_line(line)
    if item and item.itemID and not seen[item.itemID] and not (item._is_collection and item._is_collection ~= 0) then
      seen[item.itemID] = true
      list[#list + 1] = item
    end
  end
  return list
end

-- Runs a user-triggered tag action as a task and reports any error: nightly's
-- vim.async doesn't surface errors from tasks nobody awaits.
local function run_tag_action(name, fn, label)
  async_mod.run(name, function()
    local ok, err = pcall(fn)
    if not ok then
      async_mod.notify("zotero: " .. (label or "tag action") .. " failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

-- Toggles `tag` on `list` like Zotero's colored-tag keys (removed from all
-- if every item has it, otherwise added to all), then re-renders. Calls
-- `on_done(ok, added)` on the main thread when finished, if given.
function M.toggle_tag_on(list, tag, on_done)
  run_tag_action("zotero:ui.items.toggle_tag", function()
    local key_map = async_mod.await(db.get_item_keys(vim.tbl_map(function(i) return i.itemID end, list)))
    local keys = vim.tbl_values(key_map)
    local ok, added = false, false
    if #keys == 0 then
      async_mod.notify("zotero: could not resolve item keys", vim.log.levels.ERROR)
    else
      ok, added = async_mod.await(require("zotero.api").toggle_tag(keys, tag))
    end
    async_mod.to_main()
    if ok then
      M.fetch_and_render(true)
    end
    if on_done then
      on_done(ok == true, added == true)
    end
  end)
end

-- t1..t9: toggle Zotero's colored tag number n.
local function toggle_colored_tag(n)
  if M.readonly_guard() then
    return
  end
  local list = selected_items()
  if #list == 0 then
    return
  end
  run_tag_action("zotero:ui.items.toggle_colored_tag", function()
    local tag = (async_mod.await(db.get_colored_tags()) or {})[n]
    if not tag then
      async_mod.notify(("zotero: no colored tag %d"):format(n), vim.log.levels.INFO)
      return
    end
    M.toggle_tag_on(list, tag.name)
  end)
end

-- cr: remove the item(s) from the collection being viewed, keeping them in
-- the library (Zotero's "Remove Item from Collection…").
local function remove_from_collection()
  if M.readonly_guard() then
    return
  end
  local collection_id = current_collection_id
  if not collection_id or is_trash_mode or show_only_marked then
    async_mod.notify("zotero: open a collection first; this removes items from the collection you're viewing",
      vim.log.levels.INFO)
    return
  end
  local list = selected_items()
  if #list == 0 then
    return
  end
  local what = #list == 1 and ("'" .. sql_str(list[1].title, "(no title)") .. "'") or (#list .. " items")
  if vim.fn.confirm("Remove " .. what .. " from this collection? (It stays in My Library.)", "&Yes\n&No", 2) ~= 1 then
    return
  end
  run_tag_action("zotero:ui.items.remove_from_collection", function()
    local key_map = async_mod.await(db.get_item_keys(vim.tbl_map(function(i) return i.itemID end, list)))
    local collection_key = async_mod.await(db.get_collection_key(collection_id))
    local keys = vim.tbl_values(key_map)
    if #keys == 0 or not collection_key or collection_key == "" then
      async_mod.notify("zotero: could not resolve item or collection keys", vim.log.levels.ERROR)
      return
    end
    if async_mod.await(require("zotero.api").remove_from_collection(keys, collection_key)) then
      async_mod.to_main()
      M.fetch_and_render(true)
    end
  end, "removing from the collection")
end

-- tt: a checklist of all tags showing which the item(s) have; toggle as
-- many as you like in one go (see ui/tag_assign.lua).
local function pick_tag_to_toggle()
  if M.readonly_guard() then
    return
  end
  local list = selected_items()
  if #list == 0 then
    return
  end
  run_tag_action("zotero:ui.items.tag_assign", function()
    require("zotero.ui.tag_assign").open(list)
  end)
end

function M.set_keymaps()
  local buf = layout.get_items_buf()
  if not buf then
    return
  end

  if vim.b[buf].zotero_items_setup then
    return
  end
  vim.b[buf].zotero_items_setup = true

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

  map("n", "items_show_detail", on_enter, "show detail")
  map("n", "items_open_attachment", open_attachment, "open attachment")
  map("n", "items_yank_citation_key", yank_citation_key, "yank citation key")
  map("n", "items_yank_file_path", yank_file_path, "yank attachment file path")

  map("n", "items_open_url", open_link, "open URL/DOI in browser")

  map({ "n", "x" }, "items_toggle_read", function()
    if not current_feed_library_id then
      async_mod.notify("zotero: read/unread only applies to feed items", vim.log.levels.INFO)
      return
    end
    local start_line, end_line = get_visual_lines()
    if not start_line then
      start_line = vim.api.nvim_win_get_cursor(0)[1]
      end_line = start_line
    end
    local selected = {}
    for line = start_line, end_line do
      local item = get_item_at_visible_line(line)
      if item then
        selected[#selected + 1] = item
      end
    end
    if #selected == 0 then
      return
    end
    -- Like Zotero: if any selected item is unread, mark all read; else unread.
    local any_unread = false
    for _, item in ipairs(selected) do
      if item.unread == 1 then
        any_unread = true
      end
    end
    M.set_items_read(selected, any_unread, false)
  end, "toggle read/unread (feeds)")

  map("n", "items_sort_title", function()
    toggle_sort("title")
  end, "sort by title")

  map("n", "items_sort_year", function()
    toggle_sort("year")
  end, "sort by year")

  map("n", "items_toggle_collections", function()
    layout.toggle_collections()
  end, "toggle collections pane")

  map("n", "items_sort_date_added", function()
    toggle_sort("dateAdded")
  end, "sort by date added")

  map("n", "items_search", start_search, "search")
  map("n", "items_clear_search", function()
    if is_searching then
      clear_search()
    end
  end, "cancel search")

  map("n", "items_refresh", function()
    if current_feed_library_id then
      -- In a feed, also ask Zotero to fetch new items first.
      require("zotero.ui.collections").refresh_feeds(current_feed_library_id)
    else
      M.fetch_and_render(true)
    end
  end, "refresh")

  map("n", "items_toggle_columns", toggle_columns, "toggle column view")

  map("n", "items_import_pdf", function()
    vim.ui.input({ prompt = "Import PDF: ", completion = "file" }, function(path)
      if path and path ~= "" then
        local col_key = require("zotero.ui.collections").get_selected_collection_key()
        async_mod.run("zotero:ui.items.import_pdf", function()
          local ok = async_mod.await(require("zotero.api").import_pdf(vim.fn.expand(vim.trim(path)), col_key))
          if ok then
            async_mod.to_main()
            M.fetch_and_render(true)
          end
        end)
      end
    end)
  end, "import PDF")

  map("n", "items_attach_pdf", function()
    if M.readonly_guard() then return end
    local win = layout.get_items_win()
    if not win then return end
    local cur = vim.api.nvim_win_get_cursor(win)
    local item = get_item_at_visible_line(cur[1])
    if not item then
      return
    end
    async_mod.run("zotero:ui.items.attach_pdf", function()
      local item_key = async_mod.await(db.get_item_key(item.itemID))
      if not item_key or item_key == "" then
        async_mod.notify("zotero: cannot determine item key", vim.log.levels.ERROR)
        return
      end
      async_mod.to_main()
      vim.ui.input({ prompt = "Attach PDF: ", completion = "file" }, function(path)
        if path and path ~= "" then
          async_mod.run("zotero:ui.items.attach_pdf.go", function()
            local ok = async_mod.await(require("zotero.api").add_attachment(item_key, vim.fn.expand(vim.trim(path))))
            if ok then
              async_mod.to_main()
              M.fetch_and_render(true)
            end
          end)
        end
      end)
    end)
  end, "add attachment to item")

  map("n", "items_fix_attachment", function()
    if M.readonly_guard() then return end
    local win = layout.get_items_win()
    if not win then return end
    local cur = vim.api.nvim_win_get_cursor(win)
    local item = get_item_at_visible_line(cur[1])
    if not item then
      return
    end
    local api = require("zotero.api")
    async_mod.run("zotero:ui.items.fix_attachment", function()
      local attachment = async_mod.await(db.get_attachment(item.itemID))
      if attachment then
        async_mod.to_main()
        vim.ui.input({ prompt = "DOI for attachment: " }, function(doi)
          if doi and doi ~= "" then
            async_mod.run("zotero:ui.items.fix_attachment.go", function()
              local ok = async_mod.await(api.fix_attachment_with_doi(attachment, vim.trim(doi)))
              if ok then
                async_mod.to_main()
                M.fetch_and_render(true)
              end
            end)
          end
        end)
      else
        local item_key = async_mod.await(db.get_item_key(item.itemID))
        if not item_key or item_key == "" then
          async_mod.notify("zotero: cannot determine item key", vim.log.levels.ERROR)
          return
        end
        local metadata = async_mod.await(db.get_item_metadata(item.itemID))
        local current_identifier = ""
        for _, m in ipairs(metadata) do
          if m.fieldName == "DOI" and m.value and m.value ~= "" then
            current_identifier = m.value
            break
          end
        end
        async_mod.to_main()
        vim.ui.input({ prompt = "Identifier (DOI/URL): ", default = current_identifier }, function(identifier)
          if identifier and identifier ~= "" then
            async_mod.run("zotero:ui.items.update_identifier", function()
              local ok = async_mod.await(api.update_item_from_identifier(item_key, vim.trim(identifier)))
              if ok then
                async_mod.to_main()
                M.fetch_and_render(true)
              end
            end)
          end
        end)
      end
    end)
  end, "fix or update item with DOI")

  map({ "n", "x" }, "items_delete", function()
    if M.readonly_guard() then return end
    local start_line, end_line = get_visual_lines()
    if not start_line then
      start_line = cursor_line
      end_line = cursor_line
    end

    delete_items_in_range(start_line, end_line)
  end, "delete item(s)")

  map({ "n", "x" }, "items_move_to_collection", function()
    if M.readonly_guard() then return end
    local start_line, end_line = get_visual_lines()
    if not start_line then
      start_line = cursor_line
      end_line = cursor_line
    end

    local item_ids = {}
    local titles = {}
    for line = start_line, end_line do
      local item = get_item_at_visible_line(line)
      if item and item.itemID then
        item_ids[#item_ids + 1] = item.itemID
        titles[#titles + 1] = item.title or "(no title)"
      end
    end

    if #item_ids == 0 then
      return
    end

    async_mod.run("zotero:ui.items.move_to_collection", function()
      -- One bulk lookup instead of one sqlite3 spawn per selected item.
      local key_map = async_mod.await(db.get_item_keys(item_ids))
      local resolved = {}
      for _, item_id in ipairs(item_ids) do
        local key = key_map[item_id]
        if key and key ~= "" then
          resolved[#resolved + 1] = key
        end
      end
      if #resolved == 0 then
        async_mod.notify("zotero: could not resolve item keys", vim.log.levels.ERROR)
        return
      end

      local collections = async_mod.await(db.get_collections())
      if not collections or #collections == 0 then
        async_mod.notify("zotero: no collections available", vim.log.levels.INFO)
        return
      end

      local names = {}
      for _, col in ipairs(collections) do
        local indent = string.rep("  ", col.depth or 0)
        table.insert(names, indent .. col.collectionName)
      end

      local prompt = #resolved == 1 and "Move '" .. titles[1] .. "' to:"
        or "Move " .. #resolved .. " items to:"

      async_mod.to_main()
      vim.ui.select(names, { prompt = prompt }, function(_, selected_idx)
        if selected_idx and collections[selected_idx] then
          local key = collections[selected_idx].key
          local name = collections[selected_idx].collectionName
          async_mod.run("zotero:ui.items.move_to_collection.go", function()
            local api = require("zotero.api")
            local count = 0
            for _, item_key in ipairs(resolved) do
              if async_mod.await(api.add_to_collection(item_key, key)) then
                count = count + 1
              end
            end
            async_mod.notify("zotero: added " .. count .. " item(s) to '" .. name .. "'", vim.log.levels.INFO)
            require("zotero.ui.collections").refresh_counts()
          end)
        end
      end)
    end)
  end, "move item(s) to collection")

  map({ "n", "x" }, "items_toggle_mark", function()
    if M.readonly_guard() then return end
    local start_line, end_line = get_visual_lines()
    if not start_line then
      start_line = cursor_line
      end_line = cursor_line
    end

    local items = {}
    for line = start_line, end_line do
      local item = get_item_at_visible_line(line)
      if item and item.itemID then
        items[#items + 1] = item
      end
    end
    if #items == 0 then
      return
    end

    for _, item in ipairs(items) do
      if marked_items[item.itemID] then
        marked_items[item.itemID] = nil
      else
        marked_items[item.itemID] = true
      end
    end

    cursor_line = start_line

    local items_buf = layout.get_items_buf()
    if not items_buf or not vim.api.nvim_buf_is_valid(items_buf) then
      return
    end

    commit_render(items_buf, items_data)
    require("zotero.ui.collections").refresh_display()
  end, "toggle mark on item(s)")

  map("n", "items_show_only_marked", toggle_show_marked, "show only marked items")

  map("n", "items_filter_type", M.pick_type_filter, "filter by item type")
  map("n", "items_filter_tag", M.pick_tag_filter, "filter by tag")
  map({ "n", "x" }, "items_remove_from_collection", remove_from_collection, "remove item(s) from this collection")
  map({ "n", "x" }, "items_toggle_tag", pick_tag_to_toggle, "toggle a tag on item(s)")
  -- t1..t9 (with the default prefix): toggle Zotero's colored tag N.
  local tag_prefix = km.items_toggle_colored_tag
  if tag_prefix then
    for n = 1, 9 do
      vim.keymap.set({ "n", "x" }, tag_prefix .. n, function()
        toggle_colored_tag(n)
      end, { buffer = buf, silent = true, desc = "toggle colored tag " .. n })
    end
  end

  -- g: navigation (collections.lua maps the same keys in its pane)
  map("n", "goto_library", function()
    M.load_items(nil)
  end, "go to My Library")
  map("n", "goto_trash", M.load_trash, "go to Trash")
  map("n", "goto_feeds", function()
    require("zotero.ui.collections").focus_feeds()
  end, "go to Feeds")

  -- <family>?: :help at that family's section
  for name, tag in pairs({
    items_help_open = "zotero-items-open-maps",
    items_help_edit = "zotero-items-edit-maps",
    items_help_add = "zotero-items-add-maps",
    items_help_sort = "zotero-items-sort-maps",
    items_help_filter = "zotero-items-filter-maps",
    items_help_toggle = "zotero-items-toggle-maps",
    items_help_yank = "zotero-items-yank-maps",
  }) do
    map("n", name, function()
      winopt.help(tag)
    end, "help: " .. tag)
  end

  map("n", "items_add_by_identifier", function()
    vim.ui.input({ prompt = "Add by identifier (DOI/ISBN/PMID/arXiv): " }, function(input)
      if input and input ~= "" then
        local col_key = require("zotero.ui.collections").get_selected_collection_key()
        async_mod.run("zotero:ui.items.add_by_identifier", function()
          local ok = async_mod.await(require("zotero.api").add_by_identifier(vim.trim(input), col_key))
          if ok then
            async_mod.to_main()
            M.fetch_and_render(true)
          end
        end)
      end
    end)
  end, "add item by identifier")

  map("n", "items_edit_item", function()
    if M.readonly_guard() then return end
    local win = layout.get_items_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local item = get_item_at_visible_line(cursor[1])
    if item then
      require("zotero.edit").open_edit(item.itemID)
    end
  end, "edit item")

  map("n", "items_show_help", function()
    M.show_help()
  end, "help")

  -- Vim's own motions move the cursor; this only keeps it off the header
  -- rows (gg, k, <C-u>, a click…) and remembers it for the next redraw.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local mcl = min_cursor_line()
      if cursor[1] < mcl and vim.api.nvim_buf_line_count(buf) >= mcl then
        vim.api.nvim_win_set_cursor(0, { mcl, cursor[2] })
        cursor[1] = mcl
      end
      cursor_line = cursor[1]
    end,
  })

  if not _resize_autocmd_set then
    _resize_autocmd_set = true
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      callback = function()
        local win = layout.get_items_win()
        if not win or not vim.api.nvim_win_is_valid(win) then
          return
        end
        local w = vim.api.nvim_win_get_width(win)
        if w ~= last_items_width then
          last_items_width = w
          rerender()
        end
      end,
    })
  end
end

function M.show_help()
  winopt.help("zotero-items-maps")
end

function M.get_current_item()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return get_item_at_visible_line(cursor[1])
end

function M.get_marked_count()
  local count = 0
  for _, _ in pairs(marked_items) do
    count = count + 1
  end
  return count
end

function M.rerender()
  rerender()
end

return M
