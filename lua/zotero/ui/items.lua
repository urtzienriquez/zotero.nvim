local M = {}

local db = require("zotero.db")
local types = require("zotero.types")
local layout = require("zotero.ui.layout")
local cfg_mod = require("zotero.config")
local async_mod = require("zotero.async")

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
local last_items_width = -1
local _resize_autocmd_set = false
local _render_version = nil

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

local COLUMN_DEFS = {
  ["#"] = { header = "  #", width = 4, align = "right", extract = function(item, idx) return (marked_items[item.itemID] and "*" or " ") .. tostring(idx) end },
  key = { header = "Key", width = 12, extract = function(item, idx, w) return types.truncate(sql_str(item._is_collection and item._is_collection ~= 0 and "[Coll]" or item.citationKey), w or 12) end },
  title = { header = "Title", width = 60, extract = function(item, idx, w) return types.truncate(sql_str(item.title, "(no title)"), w or 60) end },
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
    local title = item.title or "(no title)"

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
    end

    if avail > 0 and vim.fn.strdisplaywidth(line) > avail then
      line = types.truncate(line, avail)
    end

    table.insert(lines, line)

    _compact_hl_regions[#lines] = regions
  end

  if #items == 0 then
    if search_term ~= "" then
      table.insert(lines, "  (no items match search)")
    elseif is_trash_mode then
      table.insert(lines, "  (trash is empty)")
    elseif current_collection_id then
      table.insert(lines, "  (no items in this collection)")
    else
      table.insert(lines, "  (no items in library)")
    end
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
      -- wide: grow title/authors from their preferred minimum to fill
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
      -- narrow: start from the preferred minimum and shrink title/authors
      -- (and only them) until the table fits the window
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
    if search_term ~= "" then
      table.insert(lines, "  (no items match search)")
    elseif is_trash_mode then
      table.insert(lines, "  (trash is empty)")
    elseif current_collection_id then
      table.insert(lines, "  (no items in this collection)")
    else
      table.insert(lines, "  (no items in library)")
    end
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
  return items
end

function M.load_items(collection_id)
  current_collection_id = collection_id
  is_trash_mode = false
  search_term = ""
  is_searching = false
  show_only_marked = false
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.load_trash()
  current_collection_id = nil
  is_trash_mode = true
  search_term = ""
  is_searching = false
  show_only_marked = false
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.load_marked()
  current_collection_id = nil
  is_trash_mode = false
  search_term = ""
  is_searching = false
  show_only_marked = true
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

function M.restore_session()
  M.fetch_and_render()
end

function M.fetch_and_render(refresh_collections)
  async_mod.run("zotero:ui.items.render", function()
    if refresh_collections then
      require("zotero.db").invalidate_cache()
    end
    local limit = show_only_marked and 100000 or nil
    local items
    if is_trash_mode then
      items = async_mod.await(db.get_trash_items(sort_by, sort_dir, limit))
    elseif current_collection_id then
      items = async_mod.await(db.get_items(current_collection_id, search_term, sort_by, sort_dir, limit))
    else
      items = async_mod.await(db.search_global(search_term, sort_by, sort_dir, limit))
    end

    items = load_authors_for_items(items)
    items_data = items

    async_mod.to_main()

    local buf = layout.get_items_buf()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end

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

function M.apply_highlights(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  if is_compact_mode() then
    return apply_highlights_compact(buf)
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

  -- highlight mark * for marked items
  for i, line in ipairs(lines) do
    if i > 2 then
      local star_pos = line:find("%*%d")
      if star_pos then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemMarker", i - 1, star_pos - 1, star_pos)
      end
    end
  end
end

function M.update_status()
  local win = layout.get_items_win()
  if not win then
    return
  end
  local info = "zotero"
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
  vim.wo[win].winbar = info
end

local function on_enter()
  local win = layout.get_items_win()
  if not win then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local item = get_item_at_visible_line(cursor[1])
  if item then
    require("zotero.ui.detail").show_item(item.itemID)
  end
end

local function move_cursor(delta)
  local win = layout.get_items_win()
  if not win then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cur = vim.api.nvim_win_get_cursor(win)
  local new_line = cur[1] + delta
  local mcl = min_cursor_line()
  if new_line < mcl then
    new_line = mcl
  end
  if new_line > #lines then
    new_line = #lines
  end
  cursor_line = new_line
  vim.api.nvim_win_set_cursor(win, { cursor_line, 0 })
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

  vim.bo[buf].modifiable = true
  local lines = format_items_table(items_data)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local mcl = min_cursor_line()
  if cursor_line > #lines then
    cursor_line = #lines
  end
  if cursor_line < mcl then
    cursor_line = #lines >= mcl and mcl or 1
  end

  M.apply_highlights(buf)
  vim.api.nvim_win_set_cursor(layout.get_items_win(), { cursor_line, 0 })
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

function M.show_results(results)
  items_data = results or {}
  search_term = ""
  is_searching = false
  cursor_line = min_cursor_line()
  current_collection_id = nil

  local buf = layout.get_items_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.bo[buf].modifiable = true
  local lines = format_items_table(items_data)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  M.apply_highlights(buf)

  if cursor_line > #lines then
    cursor_line = #lines
  end
  local mcl = min_cursor_line()
  if cursor_line < mcl then
    cursor_line = #lines >= mcl and mcl or 1
  end

  vim.api.nvim_win_set_cursor(layout.get_items_win(), { cursor_line, 0 })
  M.update_status()

  local win = layout.get_items_win()
  last_items_width = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or -1

  _render_version = db.get_data_version()
end

local function clear_search()
  search_term = ""
  is_searching = false
  cursor_line = min_cursor_line()
  M.fetch_and_render()
end

local function open_attachment()
  local win = layout.get_items_win()
  if not win then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local item = get_item_at_visible_line(cursor[1])
  if not item then
    return
  end
  async_mod.run("zotero:ui.items.open_attachment", function()
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
    if #existing == 1 then
      async_mod.to_main()
      M.open_file(existing[1])
      return
    end

    local choices = {}
    for _, a in ipairs(existing) do
      table.insert(choices, a.title or a.path or "attachment")
    end
    async_mod.to_main()
    vim.ui.select(choices, { prompt = "Open attachment:" }, function(choice, idx)
      if choice and idx then
        M.open_file(existing[idx])
      end
    end)
  end)
end

function M.open_file(attachment)
  local path = attachment.path or ""
  if path == "" then
    async_mod.notify("zotero: no path for attachment", vim.log.levels.WARN)
    return
  end

  local home = vim.uv.os_homedir()
  local storage_dir = home .. "/Zotero/storage"
  local full_path = nil

  if path:find("^storage:") then
    local rel = path:sub(9)
    -- modern Zotero: storage/{item_key}/{filename}
    if attachment.key then
      local candidate = storage_dir .. "/" .. attachment.key .. "/" .. rel
      if vim.fn.filereadable(candidate) == 1 then
        full_path = candidate
      end
    end
    -- fallback: storage/{filename}
    if not full_path then
      local candidate = storage_dir .. "/" .. rel
      if vim.fn.filereadable(candidate) == 1 then
        full_path = candidate
      end
    end
  elseif path:find("^attachments:") then
    local rel = path:sub(13)
    full_path = home .. "/Zotero/" .. rel
    if vim.fn.filereadable(full_path) == 0 then
      full_path = nil
    end
  else
    full_path = path:gsub("^~", home)
    if vim.fn.filereadable(full_path) == 0 then
      full_path = nil
    end
  end

  if not full_path then
    async_mod.notify("zotero: attachment file not found on disk", vim.log.levels.WARN)
    return
  end

  local viewer = require("zotero.config").get().pdf_viewer or "xdg-open"
  vim.fn.jobstart({ viewer, full_path }, { detach = true })
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
      local item_keys = {}
      local collection_keys = {}
      for _, item in ipairs(to_delete) do
        if item._is_collection and item._is_collection ~= 0 then
          if item._trash_key then
            collection_keys[#collection_keys + 1] = item._trash_key
          end
        else
          local key = async_mod.await(db.get_item_key(item.itemID))
          if key and key ~= "" then
            item_keys[#item_keys + 1] = key
          end
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
    local item_keys = {}
    for _, item in ipairs(to_delete) do
      local key = async_mod.await(db.get_item_key(item.itemID))
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

  map("n", "items_move_down", function()
    move_cursor(vim.v.count1)
  end, "move down")

  map("n", "items_move_up", function()
    move_cursor(-vim.v.count1)
  end, "move up")

  map("n", "items_move_down_alt", function()
    move_cursor(vim.v.count1)
  end, "move down")

  map("n", "items_move_up_alt", function()
    move_cursor(-vim.v.count1)
  end, "move up")

  map("n", "items_go_to_top", function()
    cursor_line = min_cursor_line()
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { cursor_line, 0 })
  end, "go to top")

  map("n", "items_go_to_bottom", function()
    local buf = vim.api.nvim_win_get_buf(layout.get_items_win())
    cursor_line = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { cursor_line, 0 })
  end, "go to bottom")

  map("n", "items_show_detail", on_enter, "show detail")
  map("n", "items_open_attachment", open_attachment, "open attachment")

  map("n", "items_open_url", function()
    local win = layout.get_items_win()
    if not win then return end
    local cur = vim.api.nvim_win_get_cursor(win)
    local item = get_item_at_visible_line(cur[1])
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
      local viewer = cfg_mod.get().pdf_viewer or "xdg-open"
      async_mod.to_main()
      vim.fn.jobstart({ viewer, link }, { detach = true })
    end)
  end, "open URL/DOI in browser")

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
    M.fetch_and_render(true)
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
    local mode = vim.api.nvim_get_mode().mode
    local start_line, end_line

    if mode:match("[vV\22]") then
      start_line = vim.fn.line("v")
      end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    else
      start_line = cursor_line
      end_line = cursor_line
    end

    delete_items_in_range(start_line, end_line)
  end, "delete item(s)")

  map({ "n", "x" }, "items_move_to_collection", function()
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
      local resolved = {}
      for _, item_id in ipairs(item_ids) do
        local key = async_mod.await(db.get_item_key(item_id))
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

    vim.bo[items_buf].modifiable = true
    local lines = format_items_table(items_data)
    vim.api.nvim_buf_set_lines(items_buf, 0, -1, false, lines)
    vim.bo[items_buf].modifiable = false

    M.apply_highlights(items_buf)

    if cursor_line > #lines then
      cursor_line = #lines
    end
    local mcl = min_cursor_line()
    if cursor_line < mcl then
      cursor_line = #lines >= mcl and mcl or 1
    end
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { cursor_line, 0 })
    require("zotero.ui.collections").refresh_display()
  end, "toggle mark on item(s)")

  map("n", "items_show_only_marked", toggle_show_marked, "show only marked items")

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
    local win = layout.get_items_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local item = get_item_at_visible_line(cursor[1])
    if item then
      require("zotero.edit").open_edit(item.itemID)
    end
  end, "edit item")

  map("n", "items_focus_collections", function()
    layout.focus_collections()
  end, "focus collections")

  map("n", "items_show_help", function()
    M.show_help()
  end, "help")

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
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
  local lines = {
    "zotero.nvim - Zotero Library Browser",
    "──────────────────────────────────────",
    "",
    "Items Pane:",
    "  j/k           Navigate",
    "  <CR>          Show item detail",
    "  <leader>zo    Open attachment",
    "  <leader>zb    Open URL/DOI in browser",
    "  <leader>ze    Edit item metadata",
    "  <leader>zs    Sort by title",
    "  <leader>zS    Sort by year",
    "  <leader>zd    Sort by date added",
    "  <leader>z/    Search",
    "  <leader>zc    Clear search",
    "  <leader>zr    Refresh",
    "  <leader>zv    Toggle view (compact/normal/full)",
    "  <leader>zt    Toggle collections pane",
    "  <leader>zi    Import PDF",
    "  <leader>za    Add attachment to item",
    "  <leader>zm    Toggle mark on item",
    "  <leader>zn    Add item by identifier (DOI/ISBN/etc.)",
    "  <leader>zM    Move item to collection",
    "  <leader>zl    Show only marked items",
    "  <leader>zD    Delete item (trash / permanent in Trash)",
    "  <Tab>         Focus collections",
    "",
    "Search:",
    "  <leader>zf    Fuzzy search (opens fzf/telescope picker)",
    "  <leader>zc    Clear search filter",
    "General:",
    "  g?            This help",
  }
  async_mod.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "zotero" })
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