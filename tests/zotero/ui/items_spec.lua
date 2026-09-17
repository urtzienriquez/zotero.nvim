local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- Unlike fetch_and_render(), this resets items.lua's filter state to a
-- clean top-level view -- that state persists across it() blocks.
local function fetch_sync()
  items.load_items(nil)
  vim.wait(3000, function()
    local buf = layout.get_items_buf()
    if not buf then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return text:match("Origin") ~= nil -- present in every top-level fetch
  end, 20)
end

describe("items (real buffers, fixture db)", function()
  before_each(function()
    vim.o.columns = 200 -- headless default is too narrow, truncates titles
    vim.o.lines = 50
    fixture.setup()
    layout.create_layout()
    items.set_keymaps() -- fetch_and_render()/load_items() don't do this themselves
  end)

  after_each(function()
    vim.wait(300, function() return false end, 20) -- let trailing async work settle
    layout.close()
    fixture.teardown()
  end)

  it("fetch_and_render() shows all top-level items with a header row", function()
    fetch_sync()
    local buf = layout.get_items_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.is_true(#lines >= 3) -- header + separator + at least one item
    local text = table.concat(lines, "\n")
    assert.matches("Title", text)
  end)

  it("show_results(empty) renders the configured empty-library message", function()
    items.show_results({})
    local lines = vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false)
    assert.matches("no items in library", table.concat(lines, "\n"))
  end)

  it("show_results(items) renders the given items without querying the db", function()
    items.show_results({ { itemID = 1, title = "Custom Result", _authors = "", year = "" } })
    local lines = vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false)
    assert.matches("Custom Result", table.concat(lines, "\n"))
  end)

  it("load_items(collection_id) filters by collection", function()
    items.load_items(1) -- Root A: items 1, 2
    vim.wait(2000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
      return text:match("Origin") ~= nil
    end, 20)
    local text = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    assert.matches("On the Origin of Species", text)
    assert.matches("Microclimate", text)
    assert.does_not.match("Population genetics", text)
  end)

  it("load_trash() shows trashed items", function()
    items.load_trash()
    vim.wait(2000, function()
      local text = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
      return text:match("Old Draft") ~= nil
    end, 20)
    local text = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    assert.matches("Old Draft", text)
    assert.matches("Root B", text) -- the synthetic trashed-collection row
  end)

  it("get_current_item() returns the item under the cursor", function()
    fetch_sync()
    layout.focus_items()
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { 3, 0 }) -- first data row
    local item = items.get_current_item()
    assert.is_not_nil(item)
    assert.is_not_nil(item.itemID)
  end)

  it("items_toggle_mark keymap marks/unmarks the current item and get_marked_count reflects it", function()
    fetch_sync()
    layout.focus_items()
    assert.equals(0, items.get_marked_count())
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { 3, 0 })
    feed("<leader>zm")
    vim.wait(1000, function() return items.get_marked_count() == 1 end, 10)
    assert.equals(1, items.get_marked_count())

    feed("<leader>zm") -- toggle back off
    vim.wait(1000, function() return items.get_marked_count() == 0 end, 10)
    assert.equals(0, items.get_marked_count())
  end)

  it("items_sort_title keymap re-sorts the list", function()
    fetch_sync()
    layout.focus_items()
    local before = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    feed("<leader>zs")
    vim.wait(2000, function()
      local after = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
      return after ~= before
    end, 20)
    local after = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    assert.is_not.equal(before, after)
  end)

  it("restore_render() repaints synchronously and reports staleness via is_stale_since", function()
    fetch_sync()
    layout.close()
    layout.create_layout()
    local fresh = items.restore_render()
    assert.is_boolean(fresh)
    assert.is_true(#vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false) > 1)
  end)

  describe("compact column mode", function()
    it("switches to the compact renderer (no table header/pipes) via items_toggle_columns", function()
      fetch_sync()
      layout.focus_items()
      local table_text = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
      assert.matches("│", table_text) -- table mode uses column separators

      local orig_select = vim.ui.select
      vim.ui.select = function(choices, _, on_choice) -- pick preset #2 ("compact")
        on_choice(choices[2], 2)
      end

      feed("<leader>zv")
      vim.wait(2000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
        return not text:match("│")
      end, 20)

      vim.ui.select = orig_select

      local compact_text = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
      assert.does_not.match("│", compact_text)
      assert.matches("On the Origin of Species", compact_text)
    end)
  end)
end)
