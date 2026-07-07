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

function M.add_by_identifier(identifier, collection_key)
  if not identifier or identifier == "" then
    vim.notify("zotero: no identifier provided", vim.log.levels.ERROR)
    return false
  end

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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
    local titles = {}
    if parsed.items then
      for _, item in ipairs(parsed.items) do
        titles[#titles + 1] = item.title or "(no title)"
      end
    end
    vim.notify("zotero: added " .. added .. " item(s): " .. table.concat(titles, ", "), vim.log.levels.INFO)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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

function M.import_pdf(path, collection_key)
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("zotero: file not found: " .. path, vim.log.levels.ERROR)
    return false
  end

  if not M.ping() then
    vim.notify("zotero: Zotero connector API unreachable (is Zotero running?)", vim.log.levels.ERROR)
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
      return true
    end
  end

  -- fallback
  return try_save_items(path, filename, title, collection_key)
end

return M
