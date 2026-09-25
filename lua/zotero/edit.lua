local M = {}

local db = require("zotero.db")
local async_mod = require("zotero.async")

local HEADER = [[
// ── Zotero Item Editor ─────────────────────────────────────────────
// Key:    %s
// Type:   %s
//
// Edit the JSON below, then :w or :ZoteroSave to save changes to Zotero.
// :q! or q to discard.  K: available field names.  g?: help.
// Empty string = delete field. Remove entries from creators/tags to delete.
// ────────────────────────────────────────────────────────────────────
]]

local function build_editable(data)
  return {
    itemType = data.itemType,
    fields = data.fields,
    creators = data.creators,
    tags = data.tags,
  }
end

local function pretty_json(data)
  local parts = {}

  local function is_array(t)
    local n = 0
    for _ in pairs(t) do
      n = n + 1
    end
    return n == #t
  end

  local function encode(val, indent)
    local pad = string.rep("  ", indent)
    local pad_in = string.rep("  ", indent + 1)
    local t = type(val)
    -- vim.NIL is userdata, not a table, so it falls through to the else branch.
    if t == "table" then
      if next(val) == nil then
        parts[#parts + 1] = is_array(val) and "[]" or "{}"
      elseif is_array(val) then
        parts[#parts + 1] = "[\n"
        for i, v in ipairs(val) do
          parts[#parts + 1] = pad_in
          encode(v, indent + 1)
          parts[#parts + 1] = (i < #val) and ",\n" or "\n"
        end
        parts[#parts + 1] = pad .. "]"
      else
        local keys = vim.tbl_keys(val)
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        parts[#parts + 1] = "{\n"
        for i, k in ipairs(keys) do
          parts[#parts + 1] = pad_in .. async_mod.json_encode(tostring(k)) .. ": "
          encode(val[k], indent + 1)
          parts[#parts + 1] = (i < #keys) and ",\n" or "\n"
        end
        parts[#parts + 1] = pad .. "}"
      end
    else
      parts[#parts + 1] = async_mod.json_encode(val)
    end
  end

  encode(data, 0)
  return table.concat(parts)
end

local function write_buffer(buf, item_id, data, item_type_id, header_lines, json_lines, all_types)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local all_lines = {}
  vim.list_extend(all_lines, header_lines)
  vim.list_extend(all_lines, json_lines)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)

  local found_type_id = nil
  for _, t in ipairs(all_types) do
    if t.typeName == data.itemType then
      found_type_id = t.itemTypeID
      break
    end
  end

  vim.b[buf].zotero_original = data
  vim.b[buf].zotero_key = data.key
  vim.b[buf].zotero_item_id = item_id
  vim.b[buf].zotero_item_type_name = data.itemType
  vim.b[buf].zotero_item_type_id = found_type_id or item_type_id
  vim.b[buf].zotero_header_lines = #header_lines
  vim.bo[buf].modified = false
end

local function refresh_buffer_async(buf, item_id, item_type_id)
  local data = async_mod.await(db.get_editable_item(item_id))
  if not data then
    return
  end
  local header_text = string.format(HEADER, data.key, data.itemType)
  local json_text = pretty_json(build_editable(data))
  local all_types = async_mod.await(db.get_all_item_types())
  local header_lines = vim.split(header_text, "\n")
  local json_lines = vim.split(json_text, "\n")

  async_mod.to_main()
  write_buffer(buf, item_id, data, item_type_id, header_lines, json_lines, all_types)
end

-- :w / :ZoteroSave. Waits for the save to finish, like writing a file:
-- 'modified' is reset only once Zotero has the changes, and a :wq only
-- quits when the BufWriteCmd has reset it -- so a failed save keeps the
-- window open with your edits instead of closing and losing them.
local function write_now(buf)
  local done, saved = false, false
  M.save_edit(buf):on_complete(function(err, ok)
    done, saved = true, not err and ok == true
  end)
  local timeout = (require("zotero.config").get().http_timeout or 60000) + 5000
  vim.wait(timeout, function() return done end, 20)
  if not done then
    async_mod.notify("zotero: save still running; the edit buffer stays open", vim.log.levels.WARN)
  elseif saved and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modified = false
  end
end

-- The one edit buffer (nil when none is open). `ee` reuses its window
-- instead of stacking splits.
local edit_buf = nil

local function win_of(buf)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
end

-- The edit buffer, if one is open.
local function current_edit_buf()
  if edit_buf and vim.api.nvim_buf_is_valid(edit_buf) then
    return edit_buf
  end
  edit_buf = nil
end

function M.open_edit(item_id)
  -- Already editing: the same item just gets focus; another item waits
  -- until the open one's changes are saved or discarded.
  local open = current_edit_buf()
  if open then
    local w = win_of(open)
    if vim.b[open].zotero_item_id == item_id or vim.bo[open].modified then
      if w then
        vim.api.nvim_set_current_win(w)
      end
      if vim.b[open].zotero_item_id ~= item_id then
        async_mod.notify("zotero: unsaved changes in the edit window: save with :w or discard with :q! first",
          vim.log.levels.WARN)
      end
      return
    end
  end

  async_mod.run("zotero:edit.open", function()
    local t_item_type_id = db.get_item_type_id(item_id)
    local t_data = db.get_editable_item(item_id)
    local t_all_types = db.get_all_item_types()

    local item_type_id = async_mod.await(t_item_type_id)
    local data = async_mod.await(t_data)
    if not data then
      async_mod.notify("zotero: cannot get item data for editing", vim.log.levels.ERROR)
      return
    end
    local item_type_name = async_mod.await(db.get_item_type_name(item_type_id))

    local header_text = string.format(HEADER, data.key, data.itemType)
    local json_text = pretty_json(build_editable(data))
    local all_types = async_mod.await(t_all_types)
    local header_lines = vim.split(header_text, "\n")
    local json_lines = vim.split(json_text, "\n")

    async_mod.to_main()

    local prev_win = vim.api.nvim_get_current_win()

    -- Load into the open (unmodified) edit window, or split the current
    -- window like :split does, so 'splitbelow' decides where it goes.
    local old = current_edit_buf()
    local win = old and not vim.bo[old].modified and win_of(old)
    if win then
      prev_win = vim.b[old].zotero_prev_win or prev_win
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("split")
      win = vim.api.nvim_get_current_win()
    end
    local buf = vim.api.nvim_create_buf(true, false)
    edit_buf = buf -- before the swap: the old buffer's BufWipeout checks it
    vim.api.nvim_win_set_buf(win, buf) -- the old buffer (bufhidden=wipe) goes away
    pcall(vim.api.nvim_buf_set_name, buf, "zotero://edit/" .. data.key)

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "json"
    vim.bo[buf].modified = false

    write_buffer(buf, item_id, data, item_type_id, header_lines, json_lines, all_types)
    vim.b[buf].zotero_item_type_name = item_type_name or data.itemType

    vim.b[buf].zotero_prev_win = prev_win

    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        -- Replaced by another item's buffer: focus stays in the edit window.
        if edit_buf ~= buf then
          return
        end
        edit_buf = nil
        vim.schedule(function()
          if prev_win and vim.api.nvim_win_is_valid(prev_win) then
            vim.api.nvim_set_current_win(prev_win)
          end
        end)
      end,
    })

    local buf_id = buf

    vim.api.nvim_buf_create_user_command(buf, "ZoteroSave", function()
      write_now(buf_id)
    end, { desc = "Save changes to Zotero" })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        write_now(buf_id)
      end,
    })

    local km = require("zotero.config").get().keymaps
    local function map(name, rhs, desc)
      local lhs = km.enabled ~= false and km[name]
      if lhs then
        vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
      end
    end

    map("edit_show_help", function()
      vim.cmd.help("zotero-edit-maps")
    end, "open help at the edit-buffer maps")

    map("edit_show_fields", function()
      async_mod.run("zotero:edit.fields", function()
        local item_type_id = vim.b[buf_id].zotero_item_type_id
        local type_name = vim.b[buf_id].zotero_item_type_name or "unknown"
        local fields = async_mod.await(db.get_item_type_fields(item_type_id))
        local names = {}
        for _, f in ipairs(fields) do
          names[#names + 1] = "  " .. f.fieldName
        end
        table.sort(names)
        local help_text = "Available fields for " .. type_name .. ":\n" .. table.concat(names, "\n")

        local all_types = async_mod.await(db.get_all_item_types())
        local type_names = {}
        for _, t in ipairs(all_types) do
          type_names[#type_names + 1] = "  " .. t.typeName
        end
        help_text = help_text .. "\n\nAvailable item types:\n" .. table.concat(type_names, "\n")

        async_mod.notify(help_text, vim.log.levels.INFO, { title = "zotero: fields" })
      end)
    end, "show available fields and types")

    map("edit_regenerate_key", function()
      local key = vim.b[buf_id].zotero_key
      local api = require("zotero.api")
      async_mod.run("zotero:edit.regenerate_key", function()
        local new_key = async_mod.await(api.regenerate_key(key))
        if new_key then
          async_mod.notify("zotero: citation key regenerated: " .. new_key, vim.log.levels.INFO)
          refresh_buffer_async(buf_id, vim.b[buf_id].zotero_item_id, vim.b[buf_id].zotero_item_type_id)
        end
      end)
    end, "regenerate citation key")

    vim.api.nvim_win_set_height(win, math.min(vim.api.nvim_buf_line_count(buf) + 2, 25))
  end)
end

function M.save_edit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return async_mod.run("zotero:edit.save", function() return false end)
  end

  local api = require("zotero.api")

  -- Snapshot buffer state now: after the first await the task may resume in a
  -- fast event context where vim.b / buffer APIs are not allowed (E5560).
  local header_count = vim.b[bufnr].zotero_header_lines or 0
  local json_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, header_count, -1, false), "\n")
  local original = vim.b[bufnr].zotero_original
  local key = vim.b[bufnr].zotero_key
  local item_id = vim.b[bufnr].zotero_item_id
  local item_type_id = vim.b[bufnr].zotero_item_type_id

  -- Returns the task; it resolves to true once the changes are saved (or
  -- there were none), nil when the save was refused or failed.
  return async_mod.run("zotero:edit.save", function()
    if not async_mod.await(api.ping_async()) then
      async_mod.notify("zotero: Zotero is not running", vim.log.levels.ERROR)
      return
    end

    local ok, updated = pcall(async_mod.json_decode, json_text)
    if not ok or type(updated) ~= "table" then
      async_mod.notify("zotero: invalid JSON in edit buffer", vim.log.levels.ERROR)
      return
    end

    local lookup_type_id = item_type_id
    if updated.itemType and updated.itemType ~= original.itemType then
      local all_types = async_mod.await(db.get_all_item_types())
      local valid_types = {}
      for _, t in ipairs(all_types) do
        valid_types[t.typeName] = true
      end
      if not valid_types[updated.itemType] then
        async_mod.notify(
          "zotero: invalid item type: " .. updated.itemType .. "\nPress K to see available types",
          vim.log.levels.ERROR
        )
        return
      end
      for _, t in ipairs(all_types) do
        if t.typeName == updated.itemType then
          lookup_type_id = t.itemTypeID
          break
        end
      end
    end

    local valid_fields = {}
    local all_fields = async_mod.await(db.get_item_type_fields(lookup_type_id))
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
        async_mod.notify(
          "zotero: invalid field(s): " .. table.concat(invalid, ", ") .. "\nPress K to see available fields",
          vim.log.levels.ERROR
        )
        return
      end
    end

    local creators = updated.creators
    if creators then
      if type(creators) ~= "table" then
        async_mod.notify("zotero: 'creators' must be an array", vim.log.levels.ERROR)
        return
      end
      for i, c in ipairs(creators) do
        if type(c) ~= "table" then
          async_mod.notify("zotero: creator entry " .. i .. " must be an object", vim.log.levels.ERROR)
          return
        end
        if not c.firstName and not c.lastName then
          async_mod.notify("zotero: creator " .. i .. " missing firstName or lastName", vim.log.levels.ERROR)
          return
        end
        if not c.creatorType then
          async_mod.notify("zotero: creator " .. i .. " missing creatorType", vim.log.levels.ERROR)
          return
        end
      end
    end

    local tags = updated.tags
    if tags then
      if type(tags) ~= "table" then
        async_mod.notify("zotero: 'tags' must be an array", vim.log.levels.ERROR)
        return
      end
      for i, t in ipairs(tags) do
        if type(t) ~= "string" then
          async_mod.notify("zotero: tag " .. i .. " must be a string", vim.log.levels.ERROR)
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
      async_mod.notify("zotero: no changes to save", vim.log.levels.INFO)
      return true
    end

    local ok_result = async_mod.await(api.update_item(key, updates))

    if ok_result then
      async_mod.notify("zotero: item " .. key .. " updated", vim.log.levels.INFO)

      local items = require("zotero.ui.items")
      require("zotero.db").invalidate_cache()
      if items.fetch_and_render then
        items.fetch_and_render()
      end

      -- In its own task, so :w doesn't also wait for the re-read (the
      -- buffer may already be gone after :wq; write_buffer checks).
      async_mod.run("zotero:edit.refresh", function()
        refresh_buffer_async(bufnr, item_id, item_type_id)
      end)
      return true
    end
  end)
end

return M
