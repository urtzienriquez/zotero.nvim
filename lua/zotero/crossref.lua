local M = {}

local TYPE_MAP = {
  ["journal-article"] = "journalArticle",
  ["article"] = "journalArticle",
  ["book-chapter"] = "bookSection",
  ["book"] = "book",
  ["proceedings-article"] = "conferencePaper",
  ["report"] = "report",
  ["report-series"] = "report",
  ["dissertation"] = "thesis",
  ["thesis"] = "thesis",
  ["posted-content"] = "preprint",
  ["monograph"] = "book",
  ["reference-book"] = "book",
  ["edited-book"] = "book",
  ["dataset"] = "document",
  ["component"] = "document",
  ["standard"] = "document",
  ["other"] = "document",
}

local function format_date(date_parts)
  if not date_parts or #date_parts == 0 then
    return nil
  end
  local parts = date_parts[1]
  if not parts or #parts == 0 then
    return nil
  end
  if #parts == 1 then
    return tostring(parts[1])
  elseif #parts == 2 then
    return string.format("%d-%02d", parts[1], parts[2])
  else
    return string.format("%d-%02d-%02d", parts[1], parts[2], parts[3])
  end
end

local function parse_authors(authors)
  if not authors or #authors == 0 then
    return {}
  end
  local result = {}
  for _, a in ipairs(authors) do
    local first = a.given or ""
    local last = a.family or ""
    if last ~= "" or first ~= "" then
      result[#result + 1] = {
        firstName = first,
        lastName = last,
        creatorType = "author",
      }
    end
  end
  return result
end

function M.fetch_metadata(doi)
  if not doi or doi == "" then
    return nil, "no DOI provided"
  end

  local url = "https://api.crossref.org/works/" .. doi:gsub("^10%.", "10.") .. "?mailto=zotero.nvim@user"
  local cmd = { "curl", "-s", "-L", "-w", "%{http_code}", url }

  local res = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, "curl failed"
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    if code == 404 then
      return nil, "DOI not found"
    end
    return nil, "CrossRef returned HTTP " .. tostring(code)
  end

  local ok, parsed = pcall(vim.fn.json_decode, body)
  if not ok or not parsed or parsed.status ~= "ok" then
    return nil, "failed to parse CrossRef response"
  end

  local msg = parsed.message
  if not msg then
    return nil, "no message in CrossRef response"
  end

  local titles = msg.title
  local title = (titles and #titles > 0) and titles[1] or nil

  local authors = parse_authors(msg.author)

  local containers = msg["container-title"]
  local journal = (containers and #containers > 0) and containers[1] or nil

  local date_str = format_date(msg["published-print"] and msg["published-print"]["date-parts"])
    or format_date(msg["published-online"] and msg["published-online"]["date-parts"])
    or format_date(msg["issued"] and msg["issued"]["date-parts"])

  local crossref_type = msg.type or ""
  local item_type = TYPE_MAP[crossref_type] or "journalArticle"

  local fields = {
    title = title or "",
    publicationTitle = journal or "",
    date = date_str or "",
    volume = msg.volume or "",
    issue = msg.issue or "",
    pages = msg.page or "",
    publisher = msg.publisher or "",
    DOI = msg.DOI or doi,
    url = msg.URL or "",
    abstractNote = msg.abstract or "",
  }

  local function is_empty(v)
    return v == nil or v == ""
  end

  for k, v in pairs(fields) do
    if is_empty(v) then
      fields[k] = nil
    end
  end

  return {
    itemType = item_type,
    fields = fields,
    creators = authors,
    tags = {},
  }, nil
end

return M
