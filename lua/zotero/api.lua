local M = {}

local BASE = "http://127.0.0.1:23119"

math.randomseed(os.time())

local function rand_str(len)
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local res = {}
  len = len or 32
  for _ = 1, len do
    res[#res + 1] = chars:sub(math.random(#chars), math.random(#chars))
  end
  return table.concat(res)
end

function M.ping()
  local code = vim.fn.system({ "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", BASE .. "/connector/ping" })
  return tonumber(vim.trim(code or "")) == 200
end

function M.update_item(item_key, updates)
  local payload = vim.fn.json_encode({
    itemKey = item_key,
    updates = updates,
  })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/updateItem",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: update failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local msg = body ~= "" and body or ("HTTP " .. tostring(code))
    vim.notify("zotero: update failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  if body and body ~= "" then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    if ok and type(parsed) == "table" and parsed.success then
      return true
    end
  end

  vim.notify("zotero: unexpected response", vim.log.levels.ERROR)
  return false
end

function M.regenerate_key(item_key)
  local payload = vim.fn.json_encode({ itemKey = item_key })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/regenerateKey",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: regenerate key failed (curl error)", vim.log.levels.ERROR)
    return nil
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: regenerate key failed: " .. msg, vim.log.levels.ERROR)
    return nil
  end

  local ok, parsed = pcall(vim.fn.json_decode, body)
  if ok and type(parsed) == "table" and parsed.citationKey then
    return parsed.citationKey
  end

  return nil
end

function M.create_item(item_type, fields, creators, tags)
  if not item_type then
    vim.notify("zotero: no item type provided", vim.log.levels.ERROR)
    return nil
  end

  local payload = vim.fn.json_encode({
    itemType = item_type,
    fields = fields or {},
    creators = creators or {},
    tags = tags or {},
  })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/createItem",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: create item failed (curl error)", vim.log.levels.ERROR)
    return nil
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code == 404 then
    vim.notify("zotero: create item endpoint not found — restart Zotero to reload the plugin", vim.log.levels.ERROR)
    return nil
  end
  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: create item failed: " .. msg, vim.log.levels.ERROR)
    return nil
  end

  local ok, parsed = pcall(vim.fn.json_decode, body)
  if ok and type(parsed) == "table" and parsed.key then
    return parsed.key
  end

  vim.notify("zotero: unexpected create item response", vim.log.levels.ERROR)
  return nil
end

function M.fix_attachment_with_doi(attachment_item, doi)
  if not attachment_item or not doi then
    vim.notify("zotero: missing attachment item or DOI", vim.log.levels.ERROR)
    return false
  end

  vim.notify("zotero: fetching metadata for DOI " .. doi .. "...", vim.log.levels.INFO)

  local crossref = require("zotero.crossref")
  local meta, err = crossref.fetch_metadata(doi)
  if not meta then
    vim.notify("zotero: could not fetch DOI metadata: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return false
  end

  vim.notify("zotero: creating item from metadata...", vim.log.levels.INFO)
  local new_key = M.create_item(meta.itemType, meta.fields, meta.creators, meta.tags)
  if not new_key then
    vim.notify("zotero: failed to create item from metadata", vim.log.levels.ERROR)
    return false
  end

  local db = require("zotero.db")
  local file_path = db.resolve_attachment_path(attachment_item)
  if file_path then
    vim.notify("zotero: attaching PDF to new item...", vim.log.levels.INFO)
    local ok = M.add_attachment(new_key, file_path)
    if not ok then
      vim.notify("zotero: created item but failed to attach PDF (path: " .. tostring(file_path) .. ")", vim.log.levels.WARN)
    end
  else
    vim.notify("zotero: could not find PDF file to attach", vim.log.levels.WARN)
  end

  local item_key = db.get_item_key(attachment_item.itemID)
  if item_key and item_key ~= "" then
    vim.notify("zotero: removing old standalone attachment...", vim.log.levels.INFO)
    M.delete_item(item_key)
  end

  vim.notify("zotero: item created from DOI successfully", vim.log.levels.INFO)
  return true
end

function M.add_attachment(item_key, file_path)
  local payload = vim.fn.json_encode({
    itemKey = item_key,
    filePath = file_path,
  })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/addAttachment",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: add attachment failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: add attachment failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
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
    local res = vim.fn.system({
      "curl", "-s", "-X", "POST",
      BASE .. "/connector/saveItems",
      "-H", "Content-Type: application/json",
      "-d", vim.fn.json_encode(payload),
    })
    return res
  end

  local res = do_save()

  if res and res ~= "" then
    local ok, parsed = pcall(vim.fn.json_decode, res)
    if ok and type(parsed) == "table" then
      if parsed.error == "SESSION_EXISTS" then
        session_id = rand_str(32)
        payload.sessionID = session_id
        res = do_save()
        if res and res ~= "" then
          local ok2, parsed2 = pcall(vim.fn.json_decode, res)
          if ok2 and type(parsed2) == "table" and parsed2.error then
            vim.notify("zotero: import failed: " .. res, vim.log.levels.ERROR)
            return false
          end
        end
      elseif parsed.error then
        vim.notify("zotero: import failed: " .. res, vim.log.levels.ERROR)
        return false
      end
    end
  end

  vim.notify("zotero: imported '" .. filename .. "' (document only; add file via Zotero UI to get metadata)", vim.log.levels.INFO)
  return true
end

local function detect_identifier_type(identifier)
  if not identifier or identifier == "" then
    return nil
  end
  if identifier:match("^10%.") then
    return "DOI"
  end
  local doi_url_match = identifier:match("^https?://[^/]+/doi[^/]*/(10%..+)$")
  if doi_url_match then
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

local function extract_doi(identifier)
  if not identifier then return nil end
  local bare = identifier:match("^(10%..+)$")
  if bare then return bare end
  return identifier:match("^https?://[^/]+/doi[^/]*/(10%..+)$")
end

local function check_duplicates_after_add(identifier, new_keys)
  local db = require("zotero.db")

  local id_type = detect_identifier_type(identifier)
  if not id_type then
    return
  end

  local search_value = identifier
  if id_type == "DOI" then
    local extracted = extract_doi(identifier)
    if extracted then
      search_value = extracted
    end
  end

  local matches = db.get_items_by_field_value(id_type, search_value)
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

  local existing_titles = {}
  for _, m in ipairs(existing) do
    existing_titles[#existing_titles + 1] = m.title or "(no title)"
  end

  vim.notify(
    string.format(
      "Duplicate items detected!\nNew:  %s\nExisting:  %s",
      table.concat(new_titles, ", "),
      table.concat(existing_titles, ", ")
    ),
    vim.log.levels.WARN,
    { title = "zotero" }
  )

  vim.schedule(function()
    vim.ui.select({
      "Keep the newly added item (delete old)",
      "Keep the existing item(s) (delete new)",
      "Merge all items into one",
      "Do nothing (leave duplicates)",
    }, {
      prompt = "Duplicate items found. What do you want to do?",
    }, function(choice)
      if choice == "Keep the newly added item (delete old)" then
        local old_keys = vim.tbl_map(function(m) return m.key end, existing)
        if M.delete_items(old_keys) then
          vim.notify("zotero: deleted " .. #old_keys .. " old duplicate(s)", vim.log.levels.INFO)
        end
      elseif choice == "Keep the existing item(s) (delete new)" then
        if M.erase_items(new_keys) then
          vim.notify("zotero: deleted " .. #new_keys .. " new duplicate(s)", vim.log.levels.INFO)
        end
      elseif choice == "Merge all items into one" then
        local other_keys = vim.tbl_map(function(m) return m.key end, existing)
        M.merge_items(new_keys[1], other_keys)
      end
    end)
  end)
end

local function check_duplicates_after_import(filename, new_key)
  if not new_key then
    return
  end

  local db = require("zotero.db")

  local parent = db.get_parent_item_by_attachment_key(new_key)
  local search_key = new_key
  if parent then
    search_key = parent.key
  end

  local matches = {}
  local search_title = (parent and parent.title) or nil

  local doi = db.get_item_field_value(search_key, "DOI")
  if doi then
    matches = db.get_items_by_field_value("DOI", doi)
  end

  if #matches <= 1 and search_title then
    matches = db.get_items_by_field_value("title", search_title)
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

  local existing_titles = {}
  for _, m in ipairs(existing) do
    existing_titles[#existing_titles + 1] = m.title or "(no title)"
  end

  vim.notify(
    "Duplicate items detected!\nExisting: " .. table.concat(existing_titles, ", "),
    vim.log.levels.WARN,
    { title = "zotero" }
  )

  vim.schedule(function()
    vim.ui.select({
      "Keep the newly imported item (delete old)",
      "Keep the existing item(s) (delete new)",
      "Merge all items into one",
      "Do nothing (leave duplicates)",
    }, {
      prompt = "Possible duplicate items found. What do you want to do?",
    }, function(choice)
      if choice == "Keep the newly imported item (delete old)" then
        local old_keys = vim.tbl_map(function(m) return m.key end, existing)
        if M.delete_items(old_keys) then
          vim.notify("zotero: deleted " .. #old_keys .. " old duplicate(s)", vim.log.levels.INFO)
        end
      elseif choice == "Keep the existing item(s) (delete new)" then
        M.erase_items({ (parent and parent.key) or new_key })
      elseif choice == "Merge all items into one" then
        local other_keys = vim.tbl_map(function(m) return m.key end, existing)
        M.merge_items((parent and parent.key) or new_key, other_keys)
      end
    end)
  end)
end

function M.add_by_identifier(identifier, collection_key)
  if not identifier or identifier == "" then
    vim.notify("zotero: no identifier provided", vim.log.levels.ERROR)
    return false
  end


  local data = { identifier = identifier }
  if collection_key then
    data.collectionKey = collection_key
  end
  local payload = vim.fn.json_encode(data)

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/addByIdentifier",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: lookup failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: lookup failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  local ok, parsed = pcall(vim.fn.json_decode, body)
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
    vim.notify("zotero: added " .. added .. " item(s): " .. table.concat(titles, ", "), vim.log.levels.INFO)

    if #new_keys > 0 then
      vim.defer_fn(function()
        check_duplicates_after_add(identifier, new_keys)
      end, 600)
    end

    return true
  end

  vim.notify("zotero: unexpected response", vim.log.levels.ERROR)
  return false
end

function M.delete_item(item_key)
  if not item_key or item_key == "" then
    vim.notify("zotero: no item key provided", vim.log.levels.ERROR)
    return false
  end


  local payload = vim.fn.json_encode({ itemKey = item_key })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/deleteItem",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: delete failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: delete failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.erase_item(item_key)
  if not item_key or item_key == "" then
    vim.notify("zotero: no item key provided", vim.log.levels.ERROR)
    return false
  end


  local payload = vim.fn.json_encode({ itemKey = item_key })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/eraseItem",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: permanent delete failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: permanent delete failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.delete_items(item_keys)
  if not item_keys or #item_keys == 0 then
    return false
  end


  local payload = vim.fn.json_encode({ itemKeys = item_keys })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/deleteItems",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: batch trash failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: batch trash failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.erase_items(item_keys, collection_keys)
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

  local payload = vim.fn.json_encode(data)

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/eraseItems",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: batch erase failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: batch erase failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.create_collection(name, parent_collection_key)
  if not name or name == "" then
    vim.notify("zotero: no name provided", vim.log.levels.ERROR)
    return false
  end


  local data = { name = name }
  if parent_collection_key and parent_collection_key ~= "" then
    data.parentCollectionKey = parent_collection_key
  end

  local payload = vim.fn.json_encode(data)

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/createCollection",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: create collection failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: create collection failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.add_to_collection(item_key, collection_key)
  if not item_key or not collection_key then
    vim.notify("zotero: missing item key or collection key", vim.log.levels.ERROR)
    return false
  end


  local payload = vim.fn.json_encode({ itemKey = item_key, collectionKey = collection_key })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/addToCollection",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: add to collection failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: add to collection failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.trash_collection(collection_key)
  if not collection_key or collection_key == "" then
    vim.notify("zotero: no collection key provided", vim.log.levels.ERROR)
    return false
  end


  local payload = vim.fn.json_encode({ collectionKey = collection_key })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/trashCollection",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: trash collection failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: trash collection failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.erase_collection(collection_key)
  if not collection_key or collection_key == "" then
    vim.notify("zotero: no collection key provided", vim.log.levels.ERROR)
    return false
  end


  local payload = vim.fn.json_encode({ collectionKey = collection_key })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/eraseCollection",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: permanent delete collection failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: permanent delete collection failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.merge_items(item_key, other_keys)
  if not item_key or not other_keys or #other_keys == 0 then
    vim.notify("zotero: missing item key or other keys for merge", vim.log.levels.ERROR)
    return false
  end


  local payload = vim.fn.json_encode({
    itemKey = item_key,
    otherItemKeys = other_keys,
  })

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/mergeItems",
    "-H", "Content-Type: application/json",
    "-d", payload,
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: merge failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code ~= 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    local msg = (ok and parsed and parsed.error) and parsed.error or ("HTTP " .. tostring(code))
    vim.notify("zotero: merge failed: " .. msg, vim.log.levels.ERROR)
    return false
  end

  vim.notify("zotero: items merged successfully", vim.log.levels.INFO)
  return true
end

function M.import_pdf(path, collection_key)
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("zotero: file not found: " .. path, vim.log.levels.ERROR)
    return false
  end


  local filename = vim.fn.fnamemodify(path, ":t")
  local title = filename:gsub("%.pdf$", "", 1)

  local data = { filePath = path }
  if collection_key then
    data.collectionKey = collection_key
  end

  local res = vim.fn.system({
    "curl", "-s", "-w", "%{http_code}",
    "-X", "POST",
    BASE .. "/connector/importFile",
    "-H", "Content-Type: application/json",
    "-d", vim.fn.json_encode(data),
  })

  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: import failed (curl error)", vim.log.levels.ERROR)
    return false
  end

  local code = tonumber(res:sub(-3))
  local body = #res > 3 and res:sub(1, -4) or ""

  if code == 200 then
    local ok, parsed = pcall(vim.fn.json_decode, body)
    if ok and type(parsed) == "table" then
      if parsed.canRecognize then
        vim.notify("zotero: imported '" .. filename .. "' with auto-extracted metadata", vim.log.levels.INFO)
      else
        vim.notify("zotero: imported '" .. filename .. "' (no metadata found in PDF)", vim.log.levels.INFO)
      end
      vim.defer_fn(function()
        check_duplicates_after_import(filename, parsed.itemKey)
      end, 600)
      return true
    end
  end

  -- fallback
  return try_save_items(path, filename, title, collection_key)
end

return M
