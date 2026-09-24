local fixture = require("tests.helpers.fixture")
local async_mod = require("zotero.async")
local api = require("zotero.api")
local edit = require("zotero.edit")

local function wait_until(pred, timeout)
  vim.wait(timeout or 2000, pred, 10)
end

describe("edit.open_edit (fixture db, real buffer)", function()
  before_each(function() fixture.setup() end)
  after_each(function() fixture.teardown() end)

  it("opens a split buffer with a valid-JSON body matching the item's data", function()
    local wins_before = #vim.api.nvim_list_wins()
    edit.open_edit(2) -- ART00002
    wait_until(function() return #vim.api.nvim_list_wins() > wins_before end)

    local buf = vim.api.nvim_get_current_buf()
    local header_count = vim.b[buf].zotero_header_lines
    wait_until(function() return header_count ~= nil end)
    header_count = vim.b[buf].zotero_header_lines

    assert.equals("ART00002", vim.b[buf].zotero_key)
    assert.equals(2, vim.b[buf].zotero_item_id)
    assert.equals("journalArticle", vim.b[buf].zotero_item_type_name)

    local lines = vim.api.nvim_buf_get_lines(buf, header_count, -1, false)
    local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    assert.is_true(ok)
    assert.equals("journalArticle", decoded.itemType)
    assert.equals("Nature", decoded.fields.publicationTitle)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("edit.save_edit (fixture db, mocked connector)", function()
  local orig_ping, orig_update

  before_each(function()
    fixture.setup()
    orig_ping = api.ping_async
    orig_update = api.update_item
  end)

  after_each(function()
    api.ping_async = orig_ping
    api.update_item = orig_update
    fixture.teardown()
  end)

  local function open_buffer(item_id)
    local wins_before = #vim.api.nvim_list_wins()
    edit.open_edit(item_id)
    wait_until(function() return #vim.api.nvim_list_wins() > wins_before end)
    local buf = vim.api.nvim_get_current_buf()
    wait_until(function() return vim.b[buf].zotero_header_lines ~= nil end)
    return buf
  end

  local function set_body(buf, tbl)
    local header_count = vim.b[buf].zotero_header_lines
    vim.api.nvim_buf_set_lines(buf, header_count, -1, false, vim.split(vim.json.encode(tbl), "\n"))
  end

  it("refuses to save when Zotero is not running", function()
    api.ping_async = function() return async_mod.run("stub", function() return false end) end
    local called = false
    api.update_item = function() called = true; return async_mod.run("stub2", function() return true end) end

    local buf = open_buffer(2)
    edit.save_edit(buf)
    wait_until(function() return called end, 500)
    assert.is_false(called)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("rejects invalid JSON in the buffer", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local called = false
    api.update_item = function() called = true; return async_mod.run("stub2", function() return true end) end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    vim.api.nvim_buf_set_lines(buf, header_count, -1, false, { "{not valid json" })
    edit.save_edit(buf)
    wait_until(function() return called end, 500)
    assert.is_false(called)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("reports 'no changes' and skips the update when nothing was edited", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local called = false
    api.update_item = function() called = true; return async_mod.run("stub2", function() return true end) end

    local buf = open_buffer(2)
    -- Don't touch the body at all -- it's already exactly what was loaded.
    edit.save_edit(buf)
    wait_until(function() return called end, 1000)
    assert.is_false(called)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("calls api.update_item with only the changed field when a field is edited", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local captured_updates
    api.update_item = function(_, updates)
      captured_updates = updates
      return async_mod.run("stub2", function() return true end)
    end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    local body = table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n")
    local data = vim.json.decode(body)
    data.fields.publicationTitle = "Science Weekly"
    set_body(buf, data)

    edit.save_edit(buf)
    wait_until(function() return captured_updates ~= nil end, 1000)
    assert.equals("Science Weekly", captured_updates.fields.publicationTitle)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("saves when the connector ping resumes in a fast event context", function()
    -- Real curl-backed pings resume from a libuv callback, where buffer APIs
    -- raise E5560; a timer callback reproduces that.
    api.ping_async = function()
      return async_mod.run("stub", function()
        return async_mod.await(function(done)
          local timer = vim.uv.new_timer()
          timer:start(10, 0, function()
            timer:close()
            done(true)
          end)
        end)
      end)
    end
    local captured_updates
    api.update_item = function(_, updates)
      captured_updates = updates
      return async_mod.run("stub2", function() return true end)
    end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    local data = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n"))
    data.fields.publicationTitle = "Science Weekly"
    set_body(buf, data)

    edit.save_edit(buf)
    wait_until(function() return captured_updates ~= nil end, 1000)
    assert.is_not_nil(captured_updates)
    assert.equals("Science Weekly", captured_updates.fields.publicationTitle)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("saves on :w", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local captured_updates
    api.update_item = function(_, updates)
      captured_updates = updates
      return async_mod.run("stub2", function() return true end)
    end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    local data = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n"))
    data.fields.publicationTitle = "Science Weekly"
    set_body(buf, data)

    vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
    wait_until(function() return captured_updates ~= nil end, 1000)
    assert.is_not_nil(captured_updates)
    assert.equals("Science Weekly", captured_updates.fields.publicationTitle)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("rejects an unknown itemType", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local called = false
    api.update_item = function() called = true; return async_mod.run("stub2", function() return true end) end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    local data = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n"))
    data.itemType = "not_a_real_type"
    set_body(buf, data)

    edit.save_edit(buf)
    wait_until(function() return called end, 1000)
    assert.is_false(called)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("rejects a field name not valid for the item's type", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local called = false
    api.update_item = function() called = true; return async_mod.run("stub2", function() return true end) end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    local data = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n"))
    data.fields.notARealField = "x"
    set_body(buf, data)

    edit.save_edit(buf)
    wait_until(function() return called end, 1000)
    assert.is_false(called)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("rejects a creator missing both firstName and lastName", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local called = false
    api.update_item = function() called = true; return async_mod.run("stub2", function() return true end) end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    local data = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n"))
    data.creators = { { creatorType = "author" } } -- no name fields
    set_body(buf, data)

    edit.save_edit(buf)
    wait_until(function() return called end, 1000)
    assert.is_false(called)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("rejects tags that aren't an array of strings", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local called = false
    api.update_item = function() called = true; return async_mod.run("stub2", function() return true end) end

    local buf = open_buffer(2)
    local header_count = vim.b[buf].zotero_header_lines
    local data = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n"))
    data.tags = { 123 }
    set_body(buf, data)

    edit.save_edit(buf)
    wait_until(function() return called end, 1000)
    assert.is_false(called)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("edit buffer keymaps", function()
  local config = require("zotero.config")
  local orig_regen

  before_each(function()
    fixture.setup()
    orig_regen = api.regenerate_key
  end)

  after_each(function()
    api.regenerate_key = orig_regen
    fixture.teardown()
  end)

  local function open_buffer(item_id)
    local wins_before = #vim.api.nvim_list_wins()
    edit.open_edit(item_id)
    wait_until(function() return #vim.api.nvim_list_wins() > wins_before end)
    local buf = vim.api.nvim_get_current_buf()
    wait_until(function() return vim.fn.maparg("g?", "n", false, true).buffer == 1 end)
    return buf
  end

  local function mapped(lhs)
    return vim.fn.maparg(lhs, "n", false, true).buffer == 1
  end

  it("maps gK, K and g?, but not q (use :q) nor the old <leader>zs / <leader>zk", function()
    local buf = open_buffer(2)
    assert.is_true(mapped("gK"))
    assert.is_true(mapped("K"))
    assert.is_true(mapped("g?"))
    assert.is_false(mapped("q"))
    assert.is_false(mapped("<leader>zs"))
    assert.is_false(mapped("<leader>zk"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("gK regenerates the item's citation key", function()
    local asked
    api.regenerate_key = function(key)
      asked = key
      return async_mod.run("mock", function() return nil end)
    end
    local buf = open_buffer(2)
    vim.api.nvim_feedkeys("gK", "x", false)
    wait_until(function() return asked ~= nil end)
    assert.equals("ART00002", asked)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("takes its keys from the keymaps config", function()
    config.set({ db_path = fixture.db_path, keymaps = { edit_regenerate_key = "<leader>zk", edit_show_fields = false } })
    local buf = open_buffer(2)
    assert.is_true(mapped("<leader>zk"))
    assert.is_false(mapped("gK"))
    assert.is_false(mapped("K"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("edit buffer :wq / :q (fixture db, mocked connector)", function()
  local orig_ping, orig_update

  before_each(function()
    fixture.setup()
    orig_ping, orig_update = api.ping_async, api.update_item
  end)

  after_each(function()
    api.ping_async, api.update_item = orig_ping, orig_update
    fixture.teardown()
  end)

  -- Opens the editor on item 2 and changes its publication title.
  local function open_edited()
    local wins_before = #vim.api.nvim_list_wins()
    edit.open_edit(2)
    wait_until(function() return #vim.api.nvim_list_wins() > wins_before end)
    local buf = vim.api.nvim_get_current_buf()
    wait_until(function() return vim.b[buf].zotero_header_lines ~= nil end)
    local header_count = vim.b[buf].zotero_header_lines
    local data = vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(buf, header_count, -1, false), "\n"))
    data.fields.publicationTitle = "Science Weekly"
    vim.api.nvim_buf_set_lines(buf, header_count, -1, false, vim.split(vim.json.encode(data), "\n"))
    assert.is_true(vim.bo[buf].modified)
    return buf, wins_before
  end

  it(":wq saves to Zotero and closes the editor", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    local captured
    api.update_item = function(_, updates)
      captured = updates
      return async_mod.run("stub2", function() return true end)
    end
    local buf, wins_before = open_edited()
    vim.cmd("wq")
    assert.equals("Science Weekly", captured.fields.publicationTitle)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.equals(wins_before, #vim.api.nvim_list_wins())
  end)

  it(":w saves and clears 'modified' before returning", function()
    api.ping_async = function() return async_mod.run("stub", function() return true end) end
    api.update_item = function() return async_mod.run("stub2", function() return true end) end
    local buf = open_edited()
    vim.cmd("write")
    assert.is_false(vim.bo[buf].modified)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it(":wq keeps the editor open, with the edits, when the save fails", function()
    api.ping_async = function() return async_mod.run("stub", function() return false end) end
    local buf = open_edited()
    local ok, err = pcall(vim.cmd, "wq") -- the save error surfaces as :wq's error
    assert.is_false(ok)
    assert.matches("Zotero is not running", err)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.is_true(vim.bo[buf].modified)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it(":q refuses with unsaved changes; :q! closes", function()
    local buf = open_edited()
    local ok, err = pcall(vim.cmd, "q")
    assert.is_false(ok)
    assert.matches("E37", err)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    vim.cmd("q!")
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)
end)
