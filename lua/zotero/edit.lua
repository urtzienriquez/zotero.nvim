local M = {}

local db = require("zotero.db")

local HEADER = [[
// ── Zotero Item Editor ─────────────────────────────────────────────
// Key:    %s
// Type:   %s
//
// Edit the JSON below, then :ZoteroSave to save changes to Zotero.
// :q! or q to discard.  ? to see available field names.
// Empty string = delete field. Remove entries from creators/tags to delete.
// ────────────────────────────────────────────────────────────────────
]]

local function pretty_json(data)
  local json_str = vim.fn.json_encode(data)
  local result = vim.fn.system({ "python3", "-m", "json.tool" }, json_str)
  if vim.v.shell_error ~= 0 then
    return json_str
  end
  return vim.trim(result)
end

local function fill_buffer(buf, data, item_id)
  local header_text = string.format(HEADER, data.key, data.itemType)
  local editable = {
    itemType = data.itemType,
    fields = data.fields,
    creators = data.creators,
    tags = data.tags,
  }
  local json_text = pretty_json(editable)
  local header_lines = vim.split(header_text, "\n")
  local json_lines = vim.split(json_text, "\n")
  local all_lines = {}
  vim.list_extend(all_lines, header_lines)
  vim.list_extend(all_lines, json_lines)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

  vim.b[buf].zotero_original = data
  vim.b[buf].zotero_key = data.key
  vim.b[buf].zotero_item_id = item_id
  vim.b[buf].zotero_item_type_name = data.itemType

  local all_types = db.get_all_item_types()
  for _, t in ipairs(all_types) do
    if t.typeName == data.itemType then
      vim.b[buf].zotero_item_type_id = t.itemTypeID
      break
    end
  end

  vim.b[buf].zotero_header_lines = #header_lines
  vim.bo[buf].modified = false
end

function M.open_edit(item_id)
  local item_type_id = db.get_item_type_id(item_id)
  local data = db.get_editable_item(item_id)
  if not data then
    vim.notify("zotero: cannot get item data for editing", vim.log.levels.ERROR)
    return
  end

  -- Remember focused window (items pane)
  local prev_win = vim.api.nvim_get_current_win()

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, buf)

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "json"
  vim.bo[buf].modified = false

  fill_buffer(buf, data, item_id)

  vim.b[buf].zotero_prev_win = prev_win
  vim.b[buf].zotero_item_type_id = item_type_id
  vim.b[buf].zotero_item_type_name = db.get_item_type_name(item_type_id)

  -- On close, restore focus to items pane
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if prev_win and vim.api.nvim_win_is_valid(prev_win) then
          vim.api.nvim_set_current_win(prev_win)
        end
      end)
    end,
  })

  local buf_id = buf

  -- :ZoteroSave
  vim.api.nvim_buf_create_user_command(buf, "ZoteroSave", function()
    M.save_edit(buf_id)
  end, { desc = "Save changes to Zotero" })

  -- <leader>zs to save
  vim.keymap.set("n", "<leader>zs", function()
    M.save_edit(buf_id)
  end, { buffer = buf, silent = true, desc = "zotero: save changes" })

  -- q to close
  vim.keymap.set("n", "q", function()
    local pw = vim.b[buf_id].zotero_prev_win
    if pw and vim.api.nvim_win_is_valid(pw) then
      vim.api.nvim_set_current_win(pw)
    end
    vim.api.nvim_buf_delete(buf_id, { force = true })
  end, { buffer = buf, silent = true, desc = "zotero: close editor" })

  -- ? to show available fields and item types
  vim.keymap.set("n", "?", function()
    local item_type_id = vim.b[buf_id].zotero_item_type_id
    local type_name = vim.b[buf_id].zotero_item_type_name or "unknown"
    local fields = db.get_item_type_fields(item_type_id)
    local names = {}
    for _, f in ipairs(fields) do
      names[#names + 1] = "  " .. f.fieldName
    end
    table.sort(names)
    local help_text = "Available fields for " .. type_name .. ":\n" .. table.concat(names, "\n")

    local all_types = db.get_all_item_types()
    local type_names = {}
    for _, t in ipairs(all_types) do
      type_names[#type_names + 1] = "  " .. t.typeName
    end
    help_text = help_text .. "\n\nAvailable item types:\n" .. table.concat(type_names, "\n")

    vim.notify(help_text, vim.log.levels.INFO, { title = "zotero: fields" })
  end, { buffer = buf, silent = true, desc = "zotero: show available fields and types" })

  -- <leader>zk to regenerate Better BibTeX citation key
  vim.keymap.set("n", "<leader>zk", function()
    local key = vim.b[buf_id].zotero_key
    local api = require("zotero.api")
    local new_key = api.regenerate_key(key)
    if new_key then
      vim.notify("zotero: citation key regenerated: " .. new_key, vim.log.levels.INFO)
      local new_data = db.get_editable_item(vim.b[buf_id].zotero_item_id)
      if new_data then
        fill_buffer(buf_id, new_data, vim.b[buf_id].zotero_item_id)
      end
    end
  end, { buffer = buf, silent = true, desc = "zotero: regenerate citation key" })

  vim.api.nvim_win_set_height(win, math.min(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) + 2, 25))
end

function M.save_edit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local api = require("zotero.api")
  if not api.ping() then
    vim.notify("zotero: Zotero is not running", vim.log.levels.ERROR)
    return
  end

  local header_count = vim.b[bufnr].zotero_header_lines or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, header_count, -1, false)
  local json_text = table.concat(lines, "\n")

  local ok, updated = pcall(vim.fn.json_decode, json_text)
  if not ok or type(updated) ~= "table" then
    vim.notify("zotero: invalid JSON in edit buffer", vim.log.levels.ERROR)
    return
  end

  local original = vim.b[bufnr].zotero_original
  local key = vim.b[bufnr].zotero_key
  local item_id = vim.b[bufnr].zotero_item_id

  -- Validate itemType if changed
  if updated.itemType and updated.itemType ~= original.itemType then
    local all_types = db.get_all_item_types()
    local valid_types = {}
    for _, t in ipairs(all_types) do
      valid_types[t.typeName] = true
    end
    if not valid_types[updated.itemType] then
      vim.notify(
        "zotero: invalid item type: " .. updated.itemType .. "\nPress ? to see available types",
        vim.log.levels.ERROR
      )
      return
    end
  end

  -- Validate fields against allowed field names (use new type if changed)
  local lookup_type_id = vim.b[bufnr].zotero_item_type_id
  if updated.itemType and updated.itemType ~= original.itemType then
    local all_types = db.get_all_item_types()
    for _, t in ipairs(all_types) do
      if t.typeName == updated.itemType then
        lookup_type_id = t.itemTypeID
        break
      end
    end
  end
  local valid_fields = {}
  local all_fields = db.get_item_type_fields(lookup_type_id)
  for _, f in ipairs(all_fields) do
    valid_fields[f.fieldName] = true
  end

  if updated.fields then
    local type_changed = updated.itemType and updated.itemType ~= original.itemType
    local invalid = {}
    for field, _ in pairs(updated.fields) do
      if not valid_fields[field] then
        if type_changed then
          local orig_val = original and original.fields[field]
          if orig_val == nil or tostring(updated.fields[field]) ~= tostring(orig_val) then
            invalid[#invalid + 1] = field
          end
        else
          invalid[#invalid + 1] = field
        end
      end
    end
    if #invalid > 0 then
      vim.notify(
        "zotero: invalid field(s): " .. table.concat(invalid, ", ") .. "\nPress ? to see available fields",
        vim.log.levels.ERROR
      )
      return
    end
  end

  -- Validate creators format
  local creators = updated.creators
  if creators then
    if type(creators) ~= "table" then
      vim.notify("zotero: 'creators' must be an array", vim.log.levels.ERROR)
      return
    end
    for i, c in ipairs(creators) do
      if type(c) ~= "table" then
        vim.notify("zotero: creator entry " .. i .. " must be an object", vim.log.levels.ERROR)
        return
      end
      if not c.firstName and not c.lastName then
        vim.notify("zotero: creator " .. i .. " missing firstName or lastName", vim.log.levels.ERROR)
        return
      end
      if not c.creatorType then
        vim.notify("zotero: creator " .. i .. " missing creatorType", vim.log.levels.ERROR)
        return
      end
    end
  end

  -- Validate tags format
  local tags = updated.tags
  if tags then
    if type(tags) ~= "table" then
      vim.notify("zotero: 'tags' must be an array", vim.log.levels.ERROR)
      return
    end
    for i, t in ipairs(tags) do
      if type(t) ~= "string" then
        vim.notify("zotero: tag " .. i .. " must be a string", vim.log.levels.ERROR)
        return
      end
    end
  end

  local updates = {
    fields = {},
    creators = updated.creators or {},
    tags = updated.tags or {},
  }

  if updated.fields then
    for field, value in pairs(updated.fields) do
      local orig_val = original and original.fields[field]
      if tostring(value) ~= tostring(orig_val) then
        updates.fields[field] = value
      end
    end
  end

  if original then
    for field, _ in pairs(original.fields) do
      if not updated.fields or updated.fields[field] == nil then
        updates.fields[field] = ""
      end
    end
  end

  if updated.itemType and updated.itemType ~= original.itemType then
    updates.itemType = updated.itemType
  end

  local has_changes = false
  if next(updates.fields) then
    has_changes = true
  end
  if updates.itemType then
    has_changes = true
  end
  if original and #updates.creators ~= #original.creators then
    has_changes = true
  else
    for i, c in ipairs(updates.creators) do
      local oc = original and original.creators[i]
      if not oc or c.firstName ~= oc.firstName or c.lastName ~= oc.lastName or c.creatorType ~= oc.creatorType then
        has_changes = true
        break
      end
    end
  end
  if not has_changes and original then
    if #updates.tags ~= #original.tags then
      has_changes = true
    else
      for i, t in ipairs(updates.tags) do
        if t ~= original.tags[i] then
          has_changes = true
          break
        end
      end
    end
  end

  if not has_changes then
    vim.notify("zotero: no changes to save", vim.log.levels.INFO)
    return
  end

  local ok_result = api.update_item(key, updates)

  if ok_result then
    vim.notify("zotero: item " .. key .. " updated", vim.log.levels.INFO)

    -- Refresh items list
    local items = require("zotero.ui.items")
    if items.fetch_and_render then
      items.fetch_and_render()
    end

    -- Reload buffer with fresh data
    local new_data = db.get_editable_item(item_id)
    if new_data then
      fill_buffer(bufnr, new_data, item_id)
    end
  end
end

return M
