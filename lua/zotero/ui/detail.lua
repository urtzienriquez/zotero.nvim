local M = {}

local db = require("zotero.db")

local float_win = nil
local float_buf = nil
local backdrop_win = nil
local backdrop_buf = nil
local current_item_id = nil

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

local function resolve_path(attachment)
  local path = attachment.path or ""
  if path == "" then
    return nil
  end

  local storage_dir = vim.fn.expand("~") .. "/Zotero/storage"
  local full_path = nil

  if path:find("^storage:") then
    local rel = path:sub(9)
    if attachment.key then
      local candidate = storage_dir .. "/" .. attachment.key .. "/" .. rel
      if vim.fn.filereadable(candidate) == 1 then
        full_path = candidate
      end
    end
    if not full_path then
      local candidate = storage_dir .. "/" .. rel
      if vim.fn.filereadable(candidate) == 1 then
        full_path = candidate
      end
    end
  elseif path:find("^attachments:") then
    local rel = path:sub(13)
    full_path = vim.fn.expand("~") .. "/Zotero/" .. rel
    if vim.fn.filereadable(full_path) == 0 then
      full_path = nil
    end
  end

  return full_path
end

local function sanitize(val)
  if not val then
    return ""
  end
  return val:gsub("\n", " "):gsub("\r", "")
end

function M.show_item(item_id)
  M.close()

  current_item_id = item_id
  local detail = db.get_item_detail(item_id)
  local metadata = detail.metadata or {}

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

  local type_id = db.get_item_type_id(item_id)
  if type_id then
    local type_name = db.get_item_type_name(type_id)
    if type_name and type_name ~= "" then
      table.insert(lines, "  Type:     " .. type_name)
    end
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
      return resolve_path(att) ~= nil
    end, detail.attachments)

    table.insert(lines, "")
    table.insert(lines, "  Attachments (" .. tostring(#existing) .. "):")
    for _, att in ipairs(existing) do
      local full_path = resolve_path(att)
      table.insert(lines, "    " .. (sanitize(att.title) or "attachment") .. "  —  " .. full_path)
    end
  else
    table.insert(lines, "")
    table.insert(lines, "  Attachments (0):")
  end

  table.insert(lines, "  [press q to close]")

  -- backdrop
  backdrop_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[backdrop_buf].buftype = "nofile"
  backdrop_win = vim.api.nvim_open_win(backdrop_buf, false, {
    relative = "editor",
    width = vim.o.columns,
    height = vim.o.lines,
    row = 0,
    col = 0,
    style = "minimal",
    border = "none",
    zindex = 49,
    focusable = false,
  })
  vim.wo[backdrop_win].winhl = "Normal:ZoteroDetailBackdrop"
  vim.wo[backdrop_win].winblend = 60

  float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false
  vim.bo[float_buf].filetype = "zotero-detail"

  local width = math.min(120, vim.o.columns - 8)
  local height = math.min(#lines, vim.o.lines - 6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Item Details ",
    title_pos = "center",
    zindex = 50,
  })

  vim.wo[float_win].wrap = true

  M.apply_highlights(float_buf)

  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = float_buf, silent = true, nowait = true, desc = "zotero: close detail" })

  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, { buffer = float_buf, silent = true, nowait = true, desc = "zotero: close detail" })

  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = float_buf,
    once = true,
    callback = function()
      if backdrop_win and vim.api.nvim_win_is_valid(backdrop_win) then
        vim.api.nvim_win_close(backdrop_win, true)
        backdrop_win = nil
      end
      if backdrop_buf and vim.api.nvim_buf_is_valid(backdrop_buf) then
        vim.api.nvim_buf_delete(backdrop_buf, { force = true })
        backdrop_buf = nil
      end
    end,
  })
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

function M.wrap_text(text, width)
  if not text or text == "" then
    return { "" }
  end
  local result = {}
  while #text > width do
    local break_at = text:find(" ", width - 10)
    if not break_at or break_at > width + 10 then
      break_at = width
    end
    result[#result + 1] = text:sub(1, break_at - 1)
    text = text:sub(break_at + 1)
    if text == "" then
      break
    end
  end
  if text ~= "" then
    result[#result + 1] = text
  end
  if #result == 0 then
    return { "" }
  end
  return result
end

function M.close()
  if backdrop_win and vim.api.nvim_win_is_valid(backdrop_win) then
    vim.api.nvim_win_close(backdrop_win, true)
  end
  if backdrop_buf and vim.api.nvim_buf_is_valid(backdrop_buf) then
    vim.api.nvim_buf_delete(backdrop_buf, { force = true })
  end
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_win_close(float_win, true)
  end
  if float_buf and vim.api.nvim_buf_is_valid(float_buf) then
    vim.api.nvim_buf_delete(float_buf, { force = true })
  end
  backdrop_win = nil
  backdrop_buf = nil
  float_win = nil
  float_buf = nil
  current_item_id = nil
end

function M.is_open()
  return float_win ~= nil and vim.api.nvim_win_is_valid(float_win)
end

return M
