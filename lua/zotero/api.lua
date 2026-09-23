local M = {}

local BASE = "http://127.0.0.1:23119"

local async_mod = require("zotero.async")
local db = require("zotero.db")

math.randomseed(os.time())

local function rand_str(len)
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local res = {}
  len = len or 32
  for _ = 1, len do
    local i = math.random(#chars)
    res[#res + 1] = chars:sub(i, i)
  end
  return table.concat(res)
end

local function m_run(name, fn)
  return async_mod.run("zotero:api." .. name, fn)
end

-- Human-readable reason for a failed connector request (`res` from M.http).
-- curl exits non-zero on transport errors; stderr carries the detail.
local CURL_EXIT = {
  [6] = "could not resolve host",
  [7] = "connection refused (is Zotero running with the connector enabled?)",
  [28] = "timed out (http_timeout exceeded?)",
  [35] = "SSL connect error",
  [52] = "empty reply from server",
  [56] = "connection reset by peer",
  [58] = "problem reading local certificate",
  [60] = "SSL certificate problem",
  [77] = "could not read CA certificate",
  [127] = "curl not found",
  [255] = "curl exited abnormally",
}

local function curl_fail(res)
  local code = res and res.code
  local reason = (type(code) == "number" and CURL_EXIT[code]) or ("curl exited with status " .. tostring(code))
  local stderr = ""
  if res and res.stderr and res.stderr ~= "" then
    stderr = res.stderr:gsub("%s+$", ""):gsub("\n", " ")
    if #stderr > 120 then
      stderr = stderr:sub(1, 120) .. "…"
    end
    stderr = "; " .. stderr
  end
  return string.format("exit %d (%s)%s", code or -1, reason, stderr)
end

-- Publisher landing-page suffixes that follow the DOI in article URLs.
local DOI_URL_SUFFIXES = { "full", "abstract", "abs", "pdf", "epdf", "html", "fulltext" }

--- Pull a DOI out of a bare DOI or any URL that embeds one in its path
--- (doi.org/10.x, /doi/10.x, /doi/full/10.x, ...). Query strings and
--- fragments (e.g. Wiley's ?casa_token=) are dropped.
function M.extract_doi(identifier)
  if not identifier then
    return nil
  end
  local s = vim.trim(identifier)
  if s:match("^10%.%d+/.") then
    return s
  end
  if not s:match("^https?://") then
    return nil
  end
  local doi = s:gsub("[?#].*$", ""):match("/(10%.%d+/.+)$")
  if not doi then
    return nil
  end
  doi = vim.uri_decode(doi):gsub("/+$", "")
  for _, suffix in ipairs(DOI_URL_SUFFIXES) do
    local stripped = doi:match("^(.+)/" .. suffix .. "$")
    if stripped then
      doi = stripped
      break
    end
  end
  return doi
end

function M.ping_async()
  return m_run("ping", function()
    local res = async_mod.http({ "-o", "/dev/null", BASE .. "/connector/ping" })
    return res.http_code == 200
  end)
end

-- Poll a freshly-created item until it shows up in the synced DB copy, so the
-- duplicate checks can run against the post-write state.
local function wait_for_item(item_key, timeout_ms)
  local deadline = vim.uv.now() + (timeout_ms or 5000)
  while true do
    if async_mod.await(db.get_item_by_key(item_key)) then
      return true
    end
    if vim.uv.now() >= deadline or async_mod.is_closing() then
      return false
    end
    async_mod.sleep(300)
  end
end

function M.update_item(item_key, updates)
  return m_run("update_item", function()
    db.invalidate_cache()
    local payload = async_mod.json_encode({
      itemKey = item_key,
      updates = updates,
    })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/updateItem",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: update failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local msg = res.body ~= "" and res.body or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: update failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    if res.body and res.body ~= "" then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      if ok and type(parsed) == "table" and parsed.success then
        return true
      end
    end

    async_mod.notify("zotero: unexpected response", vim.log.levels.ERROR)
    return false
  end)
end

function M.regenerate_key(item_key)
  return m_run("regenerate_key", function()
    db.invalidate_cache()
    local payload = async_mod.json_encode({ itemKey = item_key })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/regenerateKey",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: regenerate key failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return nil
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: regenerate key failed: " .. msg, vim.log.levels.ERROR)
      return nil
    end

    local ok, parsed = pcall(async_mod.json_decode, res.body)
    if ok and type(parsed) == "table" and parsed.citationKey then
      return parsed.citationKey
    end

    return nil
  end)
end

function M.create_item(item_type, fields, creators, tags)
  return m_run("create_item", function()
    db.invalidate_cache()
    if not item_type then
      async_mod.notify("zotero: no item type provided", vim.log.levels.ERROR)
      return nil
    end

    local payload = async_mod.json_encode({
      itemType = item_type,
      fields = fields or {},
      creators = creators or {},
      tags = tags or {},
    })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/createItem",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: create item failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return nil
    end

    local code = res.http_code
    if code == 404 then
      async_mod.notify("zotero: create item endpoint not found — restart Zotero to reload the plugin", vim.log.levels.ERROR)
      return nil
    end
    if code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
      async_mod.notify("zotero: create item failed: " .. msg, vim.log.levels.ERROR)
      return nil
    end

    local ok, parsed = pcall(async_mod.json_decode, res.body)
    if ok and type(parsed) == "table" and parsed.key then
      return parsed.key
    end

    async_mod.notify("zotero: unexpected create item response", vim.log.levels.ERROR)
    return nil
  end)
end

function M.fix_attachment_with_doi(attachment_item, doi)
  return m_run("fix_attachment_with_doi", function()
    db.invalidate_cache()
    if not attachment_item or not doi then
      async_mod.notify("zotero: missing attachment item or DOI", vim.log.levels.ERROR)
      return false
    end

    async_mod.notify("zotero: fetching metadata for DOI " .. doi .. "...", vim.log.levels.INFO)

    local crossref = require("zotero.crossref")
    local meta, err = async_mod.await(crossref.fetch_metadata(doi))
    if not meta then
      async_mod.notify("zotero: could not fetch DOI metadata: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return false
    end

    async_mod.notify("zotero: creating item from metadata...", vim.log.levels.INFO)
    local new_key = async_mod.await(M.create_item(meta.itemType, meta.fields, meta.creators, meta.tags))
    if not new_key then
      async_mod.notify("zotero: failed to create item from metadata", vim.log.levels.ERROR)
      return false
    end

    local file_path = db.resolve_attachment_path(attachment_item)
    if file_path then
      async_mod.notify("zotero: attaching PDF to new item...", vim.log.levels.INFO)
      local ok = async_mod.await(M.add_attachment(new_key, file_path))
      if not ok then
        async_mod.notify("zotero: created item but failed to attach PDF (path: " .. tostring(file_path) .. ")", vim.log.levels.WARN)
      end
    else
      async_mod.notify("zotero: could not find PDF file to attach", vim.log.levels.WARN)
    end

    local item_key = async_mod.await(db.get_item_key(attachment_item.itemID))
    if item_key and item_key ~= "" then
      async_mod.notify("zotero: removing old standalone attachment...", vim.log.levels.INFO)
      async_mod.await(M.delete_item(item_key))
    end

    async_mod.notify("zotero: item created from DOI successfully", vim.log.levels.INFO)
    return true
  end)
end

function M.fetch_metadata(identifier)
  return m_run("fetch_metadata", function()
    if not identifier or identifier == "" then
      return nil, "no identifier provided"
    end

    -- For DOIs, try CrossRef first (fast, no Zotero side effects)
    local doi = M.extract_doi(identifier)
    if doi then
      local crossref = require("zotero.crossref")
      local meta = async_mod.await(crossref.fetch_metadata(doi))
      if meta then
        return meta, nil
      end
    end

    -- Send the clean DOI when we have one: Zotero's cleanDOI keeps any query
    -- string glued to the DOI, which makes the lookup fail.
    local payload = async_mod.json_encode({ identifier = doi or identifier })
    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/fetchMetadata",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      return nil, "curl failed"
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) or ("HTTP " .. tostring(res.http_code))
      return nil, "fetch failed: " .. msg
    end

    local ok, parsed = pcall(async_mod.json_decode, res.body)
    if ok and type(parsed) == "table" and parsed.success and parsed.metadata then
      return parsed.metadata, nil
    end

    return nil, "unexpected response"
  end)
end

function M.set_date_added(item_key, date_added)
  return m_run("set_date_added", function()
    if not item_key or not date_added then
      async_mod.notify("zotero: missing item key or date", vim.log.levels.ERROR)
      return false
    end
    return async_mod.await(M.update_item(item_key, { dateAdded = date_added }))
  end)
end

function M.set_date_modified(item_key, date_modified)
  return m_run("set_date_modified", function()
    if not item_key or not date_modified then
      async_mod.notify("zotero: missing item key or date", vim.log.levels.ERROR)
      return false
    end
    return async_mod.await(M.update_item(item_key, { dateModified = date_modified }))
  end)
end

function M.update_item_from_identifier(item_key, identifier)
  return m_run("update_item_from_identifier", function()
    db.invalidate_cache()
    if not item_key or not identifier then
      async_mod.notify("zotero: missing item key or identifier", vim.log.levels.ERROR)
      return false
    end

    async_mod.notify("zotero: fetching metadata for '" .. identifier .. "'...", vim.log.levels.INFO)

    local meta, err = async_mod.await(M.fetch_metadata(identifier))
    if not meta then
      async_mod.notify("zotero: could not fetch metadata: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return false
    end

    async_mod.notify("zotero: updating item with metadata...", vim.log.levels.INFO)

    local updates = {}
    if meta.fields and next(meta.fields) then
      updates.fields = meta.fields
    end
    if meta.creators and #meta.creators > 0 then
      updates.creators = meta.creators
    end
    if meta.tags and #meta.tags > 0 then
      updates.tags = meta.tags
    end

    local ok = async_mod.await(M.update_item(item_key, updates))
    if not ok then
      async_mod.notify("zotero: failed to update item from metadata", vim.log.levels.ERROR)
      return false
    end

    async_mod.notify("zotero: item updated from identifier successfully", vim.log.levels.INFO)
    return true
  end)
end

function M.add_attachment(item_key, file_path)
  return m_run("add_attachment", function()
    db.invalidate_cache()
    local payload = async_mod.json_encode({
      itemKey = item_key,
      filePath = file_path,
    })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/addAttachment",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: add attachment failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: add attachment failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

local function try_save_items(path, filename, title, collection_key)
  local session_id = rand_str(32)
  local item_id = rand_str(8)

  local collections = {}
  if collection_key then
    collections = { collection_key }
  end

  local payload = {
    sessionID = session_id,
    uri = "file://" .. path,
    items = {
      {
        id = item_id,
        itemType = "document",
        title = title,
        creators = {},
        tags = {},
        collections = collections,
      },
    },
  }

  local function do_save()
    return async_mod.http({
      "-X", "POST",
      BASE .. "/connector/saveItems",
      "-H", "Content-Type: application/json",
      "-d", async_mod.json_encode(payload),
    })
  end

  -- Returns (success, error_message, parsed_body). A curl transport failure
  -- or a non-200 response is always treated as a failure, not just a JSON
  -- body with an "error" field.
  local function save_once()
    local ok, res = pcall(do_save)
    if not ok then
      return false, "curl error: " .. tostring(res)
    end
    if res.code ~= 0 then
      return false, "curl error: " .. curl_fail(res)
    end
    local parsed_ok, parsed = pcall(async_mod.json_decode, res.body)
    if res.http_code ~= 200 then
      local msg = (parsed_ok and parsed and parsed.error) or ("HTTP " .. tostring(res.http_code))
      return false, msg
    end
    if parsed_ok and type(parsed) == "table" and parsed.error then
      return false, parsed.error, parsed
    end
    return true
  end

  local success, err, parsed = save_once()
  if not success and parsed and parsed.error == "SESSION_EXISTS" then
    session_id = rand_str(32)
    payload.sessionID = session_id
    success, err = save_once()
  end

  if not success then
    async_mod.notify("zotero: import failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  async_mod.notify("zotero: imported '" .. filename .. "' (document only; add file via Zotero UI to get metadata)", vim.log.levels.INFO)
  return true
end

local function detect_identifier_type(identifier)
  if not identifier or identifier == "" then
    return nil
  end
  if M.extract_doi(identifier) then
    return "DOI"
  end
  local cleaned = identifier:gsub("[%-]", "")
  if cleaned:match("^%d%d%d%d%d%d%d%d%d%d$") or cleaned:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
    return "ISBN"
  end
  local lower = identifier:lower()
  if lower:match("^pmid") then
    return "PMID"
  end
  if lower:match("^pmc") then
    return "PMCID"
  end
  return nil
end

-- Shared by both duplicate-detection flows below: notify about `existing`
-- duplicates, let the user resolve against `new_keys`, then act on the
-- choice. `message_fn(existing_titles)` builds the notify body.
local function resolve_duplicates(existing, new_keys, message_fn, prompt, keep_new_label)
  local existing_titles = {}
  for _, m in ipairs(existing) do
    existing_titles[#existing_titles + 1] = m.title or "(no title)"
  end

  async_mod.notify(message_fn(existing_titles), vim.log.levels.WARN, { title = "zotero" })

  async_mod.to_main()
  local choice = async_mod.select({
    keep_new_label,
    "Keep the existing item(s) (delete new)",
    "Merge all items into one",
    "Do nothing (leave duplicates)",
  }, {
    prompt = prompt,
  })
  if choice == keep_new_label then
    local old_keys = vim.tbl_map(function(m) return m.key end, existing)
    if async_mod.await(M.delete_items(old_keys)) then
      async_mod.notify("zotero: deleted " .. #old_keys .. " old duplicate(s)", vim.log.levels.INFO)
    end
  elseif choice == "Keep the existing item(s) (delete new)" then
    if async_mod.await(M.erase_items(new_keys)) then
      async_mod.notify("zotero: deleted " .. #new_keys .. " new duplicate(s)", vim.log.levels.INFO)
    end
  elseif choice == "Merge all items into one" then
    local other_keys = vim.tbl_map(function(m) return m.key end, existing)
    async_mod.await(M.merge_items(new_keys[1], other_keys))
  end
end

local function check_duplicates_after_add(identifier, new_keys)
  local dbx = require("zotero.db")

  local id_type = detect_identifier_type(identifier)
  if not id_type then
    return
  end

  local search_value = identifier
  if id_type == "DOI" then
    local extracted = M.extract_doi(identifier)
    if extracted then
      search_value = extracted
    end
  end

  local matches = async_mod.await(dbx.get_items_by_field_value(id_type, search_value))
  if #matches <= 1 then
    return
  end

  local new_set = {}
  for _, k in ipairs(new_keys) do
    new_set[k] = true
  end

  local existing = {}
  for _, m in ipairs(matches) do
    if not new_set[m.key] then
      existing[#existing + 1] = m
    end
  end

  if #existing == 0 then
    return
  end

  local new_titles = {}
  for _, m in ipairs(matches) do
    if new_set[m.key] then
      new_titles[#new_titles + 1] = m.title or "(no title)"
    end
  end

  resolve_duplicates(existing, new_keys, function(existing_titles)
    return string.format(
      "Duplicate items detected!\nNew:  %s\nExisting:  %s",
      table.concat(new_titles, ", "),
      table.concat(existing_titles, ", ")
    )
  end, "Duplicate items found. What do you want to do?", "Keep the newly added item (delete old)")
end

local function check_duplicates_after_import(filename, new_key)
  if not new_key then
    return
  end

  local dbx = require("zotero.db")

  local parent = async_mod.await(dbx.get_parent_item_by_attachment_key(new_key))
  local search_key = new_key
  if parent then
    search_key = parent.key
  end

  local matches = {}
  local search_title = (parent and parent.title) or nil

  local doi = async_mod.await(dbx.get_item_field_value(search_key, "DOI"))
  if doi then
    matches = async_mod.await(dbx.get_items_by_field_value("DOI", doi))
  end

  if #matches <= 1 and search_title then
    matches = async_mod.await(dbx.get_items_by_field_value("title", search_title))
  end

  if #matches <= 1 then
    return
  end

  local existing = {}
  for _, m in ipairs(matches) do
    if m.key ~= search_key then
      existing[#existing + 1] = m
    end
  end

  if #existing == 0 then
    return
  end

  resolve_duplicates(existing, { search_key }, function(existing_titles)
    return "Duplicate items detected!\nExisting: " .. table.concat(existing_titles, ", ")
  end, "Possible duplicate items found. What do you want to do?", "Keep the newly imported item (delete old)")
end

function M.add_by_identifier(identifier, collection_key)
  return m_run("add_by_identifier", function()
    db.invalidate_cache()
    if not identifier or identifier == "" then
      async_mod.notify("zotero: no identifier provided", vim.log.levels.ERROR)
      return false
    end

    local data = { identifier = identifier }
    if collection_key then
      data.collectionKey = collection_key
    end
    local payload = async_mod.json_encode(data)

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/addByIdentifier",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: lookup failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: lookup failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    local ok, parsed = pcall(async_mod.json_decode, res.body)
    if ok and type(parsed) == "table" and parsed.success then
      local added = parsed.added or 0
      local new_keys = {}
      local titles = {}
      if parsed.items then
        for _, item in ipairs(parsed.items) do
          titles[#titles + 1] = item.title or "(no title)"
          new_keys[#new_keys + 1] = item.key
        end
      end
      async_mod.notify("zotero: added " .. added .. " item(s): " .. table.concat(titles, ", "), vim.log.levels.INFO)

      if #new_keys > 0 and wait_for_item(new_keys[1]) then
        check_duplicates_after_add(identifier, new_keys)
      end

      return true
    end

    async_mod.notify("zotero: unexpected response", vim.log.levels.ERROR)
    return false
  end)
end

function M.delete_item(item_key)
  return m_run("delete_item", function()
    db.invalidate_cache()
    if not item_key or item_key == "" then
      async_mod.notify("zotero: no item key provided", vim.log.levels.ERROR)
      return false
    end

    local payload = async_mod.json_encode({ itemKey = item_key })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/deleteItem",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: delete failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: delete failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.erase_item(item_key)
  return m_run("erase_item", function()
    db.invalidate_cache()
    if not item_key or item_key == "" then
      async_mod.notify("zotero: no item key provided", vim.log.levels.ERROR)
      return false
    end

    local payload = async_mod.json_encode({ itemKey = item_key })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/eraseItem",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: permanent delete failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: permanent delete failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.delete_items(item_keys)
  return m_run("delete_items", function()
    db.invalidate_cache()
    if not item_keys or #item_keys == 0 then
      return false
    end

    local payload = async_mod.json_encode({ itemKeys = item_keys })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/deleteItems",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: batch trash failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: batch trash failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.erase_items(item_keys, collection_keys)
  return m_run("erase_items", function()
    db.invalidate_cache()
    if (not item_keys or #item_keys == 0) and (not collection_keys or #collection_keys == 0) then
      return false
    end

    local data = {}
    if item_keys and #item_keys > 0 then
      data.itemKeys = item_keys
    end
    if collection_keys and #collection_keys > 0 then
      data.collectionKeys = collection_keys
    end

    local payload = async_mod.json_encode(data)

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/eraseItems",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: batch erase failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: batch erase failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.create_collection(name, parent_collection_key)
  return m_run("create_collection", function()
    db.invalidate_cache()
    if not name or name == "" then
      async_mod.notify("zotero: no name provided", vim.log.levels.ERROR)
      return false
    end

    local data = { name = name }
    if parent_collection_key and parent_collection_key ~= "" then
      data.parentCollectionKey = parent_collection_key
    end

    local payload = async_mod.json_encode(data)

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/createCollection",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: create collection failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: create collection failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.add_to_collection(item_key, collection_key)
  return m_run("add_to_collection", function()
    db.invalidate_cache()
    if not item_key or not collection_key then
      async_mod.notify("zotero: missing item key or collection key", vim.log.levels.ERROR)
      return false
    end

    local payload = async_mod.json_encode({ itemKey = item_key, collectionKey = collection_key })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/addToCollection",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: add to collection failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: add to collection failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.trash_collection(collection_key)
  return m_run("trash_collection", function()
    db.invalidate_cache()
    if not collection_key or collection_key == "" then
      async_mod.notify("zotero: no collection key provided", vim.log.levels.ERROR)
      return false
    end

    local payload = async_mod.json_encode({ collectionKey = collection_key })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/trashCollection",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: trash collection failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: trash collection failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.erase_collection(collection_key)
  return m_run("erase_collection", function()
    db.invalidate_cache()
    if not collection_key or collection_key == "" then
      async_mod.notify("zotero: no collection key provided", vim.log.levels.ERROR)
      return false
    end

    local payload = async_mod.json_encode({ collectionKey = collection_key })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/eraseCollection",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: permanent delete collection failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: permanent delete collection failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    return true
  end)
end

function M.merge_items(item_key, other_keys)
  return m_run("merge_items", function()
    db.invalidate_cache()
    if not item_key or not other_keys or #other_keys == 0 then
      async_mod.notify("zotero: missing item key or other keys for merge", vim.log.levels.ERROR)
      return false
    end

    local payload = async_mod.json_encode({
      itemKey = item_key,
      otherItemKeys = other_keys,
    })

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/mergeItems",
      "-H", "Content-Type: application/json",
      "-d", payload,
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: merge failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code ~= 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(res.http_code))
      async_mod.notify("zotero: merge failed: " .. msg, vim.log.levels.ERROR)
      return false
    end

    async_mod.notify("zotero: items merged successfully", vim.log.levels.INFO)
    return true
  end)
end

function M.import_pdf(path, collection_key)
  return m_run("import_pdf", function()
    db.invalidate_cache()
    if vim.fn.filereadable(path) ~= 1 then
      async_mod.notify("zotero: file not found: " .. path, vim.log.levels.ERROR)
      return false
    end

    local filename = vim.fn.fnamemodify(path, ":t")
    local title = filename:gsub("%.pdf$", "", 1)

    local data = { filePath = path }
    if collection_key then
      data.collectionKey = collection_key
    end

    local res = async_mod.http({
      "-X", "POST",
      BASE .. "/connector/importFile",
      "-H", "Content-Type: application/json",
      "-d", async_mod.json_encode(data),
    })

    if res.code ~= 0 then
      async_mod.notify("zotero: import failed (curl error: " .. curl_fail(res) .. ")", vim.log.levels.ERROR)
      return false
    end

    if res.http_code == 200 then
      local ok, parsed = pcall(async_mod.json_decode, res.body)
      if ok and type(parsed) == "table" then
        if parsed.canRecognize then
          async_mod.notify("zotero: imported '" .. filename .. "' with auto-extracted metadata", vim.log.levels.INFO)
        else
          async_mod.notify("zotero: imported '" .. filename .. "' (no metadata found in PDF)", vim.log.levels.INFO)
        end
        if parsed.itemKey and wait_for_item(parsed.itemKey) then
          check_duplicates_after_import(filename, parsed.itemKey)
        end
        return true
      end
    end

    return try_save_items(path, filename, title, collection_key)
  end)
end

return M