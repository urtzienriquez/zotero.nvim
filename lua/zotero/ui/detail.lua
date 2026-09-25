local M = {}

local db = require("zotero.db")
local async_mod = require("zotero.async")

local float_win = nil
local float_buf = nil
local backdrop_mod = require("zotero.ui.backdrop")
local winopt = require("zotero.ui.winopt")
local backdrop = nil
local current_item_id = nil
-- Bumped on every show_item() call so an in-flight render can detect it has
-- been superseded even by a second call for the *same* item_id (e.g. rapid
-- double-<CR>), not just a call for a different item.
local render_generation = 0

local PRIORITY_FIELDS = {
  title = "Title",
  abstractNote = "Abstract",
  publicationTitle = "Journal",
  bookTitle = "Book Title",
  proceedingsTitle = "Proceedings",
  encyclopediaTitle = "Encyclopedia",
  dictionaryTitle = "Dictionary",
  series = "Series",
  volume = "Volume",
  issue = "Issue",
  pages = "Pages",
  publisher = "Publisher",
  place = "Place",
  edition = "Edition",
  date = "Date",
  DOI = "DOI",
  ISBN = "ISBN",
  ISSN = "ISSN",
  url = "URL",
  accessDate = "Accessed",
  citationKey = "Cite Key",
  archive = "Archive",
  archiveLocation = "Archive Location",
  libraryCatalog = "Catalog",
  callNumber = "Call Number",
  language = "Language",
  rights = "Rights",
  extra = "Extra",
  PMID = "PMID",
  PMCID = "PMCID",
  university = "University",
  institution = "Institution",
  thesisType = "Thesis Type",
  reportType = "Report Type",
  reportNumber = "Report Number",
  manuscriptType = "Manuscript Type",
  mapType = "Map Type",
  patentNumber = "Patent Number",
  assignee = "Assignee",
  issuingAuthority = "Authority",
  filingDate = "Filing Date",
  issueDate = "Issue Date",
  court = "Court",
  caseName = "Case Name",
  dateDecided = "Date Decided",
  docketNumber = "Docket Number",
  reporter = "Reporter",
  reporterVolume = "Reporter Volume",
  firstPage = "First Page",
  websiteTitle = "Website",
  blogTitle = "Blog",
  programTitle = "Program",
  network = "Network",
  episodeNumber = "Episode",
  genre = "Genre",
  label = "Label",
  seriesNumber = "Series Number",
  numPages = "Num Pages",
  seriesTitle = "Series Title",
  shortTitle = "Short Title",
}

local function sanitize(val)
  if not val then
    return ""
  end
  return val:gsub("\n", " "):gsub("\r", "")
end

function M.show_item(item_id, type_name_hint)
  M.close()

  current_item_id = item_id
  render_generation = render_generation + 1
  local my_generation = render_generation

  async_mod.run("zotero:ui.detail.show", function()
    local detail = async_mod.await(db.get_item_detail(item_id))
    local metadata = detail.metadata or {}
    local type_name = type_name_hint
    if not type_name then
      local type_id = async_mod.await(db.get_item_type_id(item_id))
      if type_id then
        type_name = async_mod.await(db.get_item_type_name(type_id))
      end
    end

    local lines = {}

    table.insert(lines, "")
    table.insert(lines, "  " .. sanitize(metadata.title or "(no title)"))
    table.insert(lines, "")

    if detail.authors and #detail.authors > 0 then
      local author_names = {}
      for _, a in ipairs(detail.authors) do
        local name = a.fieldMode == 0
          and ((a.firstName or "") .. " " .. (a.lastName or ""))
          or (a.lastName or "")
        table.insert(author_names, name)
      end
      table.insert(lines, "  Authors:  " .. table.concat(author_names, "; "))
    end

    local citation_key = metadata.citationKey
    if citation_key and citation_key ~= "" then
      table.insert(lines, "  Key:      @" .. citation_key)
    end

    if type_name and type_name ~= "" then
      table.insert(lines, "  Type:     " .. type_name)
    end

    table.insert(lines, "")
    table.insert(lines, "  " .. string.rep("─", 60))
    table.insert(lines, "")

    local ordered_fields = {
      "publicationTitle", "bookTitle", "proceedingsTitle", "encyclopediaTitle",
      "dictionaryTitle", "series", "seriesNumber", "seriesTitle", "shortTitle",
      "volume", "issue", "pages", "publisher", "place", "edition", "date",
      "DOI", "ISBN", "ISSN", "url", "accessDate",
      "archive", "archiveLocation", "libraryCatalog", "callNumber",
      "university", "institution", "thesisType",
      "reportType", "reportNumber",
      "patentNumber", "assignee", "issuingAuthority", "filingDate", "issueDate",
      "court", "caseName", "dateDecided", "docketNumber", "reporter", "reporterVolume", "firstPage",
      "websiteTitle", "blogTitle", "programTitle", "network", "episodeNumber",
      "conferenceName", "section",
      "language", "rights", "extra", "PMID", "PMCID",
      "label", "manuscriptType", "mapType", "letterType", "audioFileType", "numPages",
    }

    for _, field in ipairs(ordered_fields) do
      local val = metadata[field]
      if val and val ~= "" then
        local label = PRIORITY_FIELDS[field] or field
        table.insert(lines, "  " .. label .. ":  " .. sanitize(val))
      end
    end

    local abstract = metadata.abstractNote
    if abstract and abstract ~= "" then
      table.insert(lines, "")
      table.insert(lines, "  Abstract:")
      local cleaned = abstract:gsub("\r\n?", "\n")
      for _, a_line in ipairs(vim.split(cleaned, "\n")) do
        local trimmed = a_line:gsub("^%s+", "")
        if trimmed ~= "" then
          local wrapped = M.wrap_text(trimmed, 56)
          for _, wline in ipairs(wrapped) do
            table.insert(lines, "    " .. wline)
          end
        end
      end
    end

    if detail.tags and #detail.tags > 0 then
      table.insert(lines, "")
      table.insert(lines, "  Tags:  " .. table.concat(
        vim.tbl_map(function(t) return "#" .. t.name end, detail.tags), "  "
      ))
    end

    if detail.notes and #detail.notes > 0 then
      table.insert(lines, "")
      table.insert(lines, "  " .. string.rep("─", 60))
      table.insert(lines, "  Notes (" .. tostring(#detail.notes) .. "):")
      for _, note in ipairs(detail.notes) do
        table.insert(lines, "")
        table.insert(lines, "    " .. (note.title or "Note"))
        if note.note then
          local plain = note.note:gsub("<[^>]+>", "")
          local cleaned = plain:gsub("\r\n?", "\n")
          for _, n_line in ipairs(vim.split(cleaned, "\n")) do
            local trimmed = n_line:gsub("^%s+", "")
            if trimmed ~= "" then
              local wrapped = M.wrap_text(trimmed, 52)
              for _, wline in ipairs(wrapped) do
                table.insert(lines, "      " .. wline)
              end
            end
          end
        end
      end
    end

    if detail.attachments and #detail.attachments > 0 then
      local existing = vim.tbl_filter(function(att)
        return db.resolve_attachment_path(att) ~= nil
      end, detail.attachments)

      table.insert(lines, "")
      table.insert(lines, "  Attachments (" .. tostring(#existing) .. "):")
      for _, att in ipairs(existing) do
        local full_path = db.resolve_attachment_path(att)
        table.insert(lines, "    " .. (sanitize(att.title) or "attachment") .. "  —  " .. full_path)
      end
    else
      table.insert(lines, "")
      table.insert(lines, "  Attachments (0):")
    end

    table.insert(lines, "  [press q to close]")

    async_mod.to_main()

    if my_generation ~= render_generation then
      return
    end

    backdrop = backdrop_mod.open()

    float_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[float_buf].modifiable = true
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
    vim.bo[float_buf].modifiable = false
    vim.bo[float_buf].filetype = "zotero-detail"

    local config = backdrop_mod.center(120, #lines)
    config.style, config.border, config.zindex = "minimal", "rounded", 50
    config.title, config.title_pos = " Item Details ", "center"
    float_win = vim.api.nvim_open_win(float_buf, true, config)
    winopt.set(float_win, "wrap", true)

    -- As tall as the text once wrapped (long abstracts wrap), within the
    -- screen; recomputed when the terminal is resized.
    local win = float_win
    local function size()
      local width = backdrop_mod.center(120, 1).width
      vim.api.nvim_win_set_config(win, { width = width }) -- the wrapped height depends on it
      return width, vim.api.nvim_win_text_height(win, {}).all
    end
    vim.api.nvim_win_set_config(win, backdrop_mod.center(size()))
    backdrop_mod.follow_resize(win, backdrop, size)

    M.apply_highlights(float_buf)

    vim.keymap.set("n", "q", function()
      M.close()
    end, { buffer = float_buf, silent = true, nowait = true, desc = "close detail" })

    vim.keymap.set("n", "<Esc>", function()
      M.close()
    end, { buffer = float_buf, silent = true, nowait = true, desc = "close detail" })

    vim.api.nvim_create_autocmd("WinClosed", {
      buffer = float_buf,
      once = true,
      callback = function()
        backdrop_mod.close(backdrop)
        backdrop = nil
      end,
    })

    -- Leaving the preview (<C-w>w, a click) closes it, like the checklists,
    -- instead of leaving it and its backdrop over the panes.
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = float_buf,
      once = true,
      callback = function()
        vim.schedule(function()
          if float_win == win then
            M.close()
          end
        end)
      end,
    })
  end)
end

function M.apply_highlights(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local ns = vim.api.nvim_create_namespace("zotero-detail-hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local in_abstract = false
  local in_notes = false
  local in_attachments = false

  for i, line in ipairs(lines) do
    local lnum = i - 1

    if line:match("^%s*[" .. string.rep("─", 10) .. "]+%s*$") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroSeparator", lnum, 0, -1)
      in_abstract = false
    elseif line:match("^%s*Abstract:%s*$") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroLabel", lnum, 2, -1)
      in_abstract = true
    elseif line:match("^%s*Tags:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroLabel", lnum, 2, 7)
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroTag", lnum, 8, -1)
      in_abstract = false
      in_notes = false
      in_attachments = false
    elseif line:match("^%s*Notes %(") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroNoteTitle", lnum, 2, -1)
      in_notes = true
      in_abstract = false
      in_attachments = false
    elseif line:match("^%s*Attachments %(") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroAttachment", lnum, 2, -1)
      in_attachments = true
      in_abstract = false
      in_notes = false
    elseif line:match("^%s*%[press q to close%]") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemCount", lnum, 0, -1)
    elseif in_abstract then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroValue", lnum, 0, -1)
    elseif in_notes then
      local note_title = line:match("^%s+%S")
      if note_title and line:match("^      ") == nil then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroNoteTitle", lnum, 0, -1)
      end
    elseif in_attachments then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroAttachment", lnum, 0, -1)
    elseif lnum == 1 then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemTitle", lnum, 2, -1)
    elseif line:match("^%s*Authors:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroLabel", lnum, 2, 11)
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroValue", lnum, 12, -1)
    elseif line:match("^%s*Key:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroLabel", lnum, 2, 7)
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemKey", lnum, 8, -1)
    elseif line:match("^%s*Type:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroLabel", lnum, 2, 8)
      vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroItemType", lnum, 9, -1)
    elseif line:match("^  %S+:") and line:match("─") == nil then
      local colon_pos = line:find(":")
      if colon_pos then
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroLabel", lnum, 2, colon_pos)
        vim.api.nvim_buf_add_highlight(buf, ns, "ZoteroValue", lnum, colon_pos + 1, -1)
      end
    end
  end
end

-- Replicates string.find's init-clamping rule (relative to a string of length
-- `remaining_len`): >=1 used as-is, 0 treated as 1, negative counts back from
-- the end and is then clamped up to 1 if still too small.
local function clamp_find_init(remaining_len, rel_init)
  if rel_init >= 1 then
    return rel_init
  elseif rel_init == 0 then
    return 1
  else
    return math.max(remaining_len + rel_init + 1, 1)
  end
end

function M.wrap_text(text, width)
  if not text or text == "" then
    return { "" }
  end
  local result = {}
  local len = #text
  -- Offset into the original `text` (not a re-sliced copy), to avoid an
  -- O(n^2) re-slice per loop on long strings; `find` uses an absolute init
  -- position (see clamp_find_init) to search as if on the remainder.
  local offset = 0
  while len - offset > width do
    local remaining_len = len - offset
    local search_from = offset + clamp_find_init(remaining_len, width - 10)
    local break_at = text:find(" ", search_from)
    if not break_at or break_at - offset > width + 10 then
      break_at = offset + width
    end
    result[#result + 1] = text:sub(offset + 1, break_at - 1)
    offset = break_at
    if offset >= len then
      break
    end
  end
  local rest = text:sub(offset + 1)
  if rest ~= "" then
    result[#result + 1] = rest
  end
  if #result == 0 then
    return { "" }
  end
  return result
end

function M.close()
  backdrop_mod.close(backdrop)
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_win_close(float_win, true)
  end
  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    vim.api.nvim_buf_delete(float_buf, { force = true })
  end
  backdrop = nil
  float_win = nil
  float_buf = nil
  current_item_id = nil
end

function M.is_open()
  return float_win ~= nil and vim.api.nvim_win_is_valid(float_win)
end

return M