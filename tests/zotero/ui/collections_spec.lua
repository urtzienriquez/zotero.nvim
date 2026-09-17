local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local collections = require("zotero.ui.collections")

local function render_sync()
  collections.render()
  vim.wait(3000, function()
    local buf = layout.get_collections_buf()
    if not buf then return false end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return #lines > 1
  end, 20)
end

describe("collections (real buffers, fixture db)", function()
  before_each(function()
    fixture.setup()
    layout.create_layout()
  end)

  after_each(function()
    layout.close()
    fixture.teardown()
  end)

  it("renders the collection tree with item counts and a nested child expanded by default", function()
    render_sync()
    local buf = layout.get_collections_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.matches("My Library %(5%)", text) -- 5 top-level items per fixture
    assert.matches("Root A %(2%)", text)
    assert.matches("Child of A %(1%)", text) -- visible: depth-0 parents start expanded
    assert.matches("Root B %(0%)", text)
    assert.matches("Trash %(2%)", text) -- 1 trashed item + 1 trashed collection
  end)

  it("get_collection_at_line resolves the line under the cursor to a collection entry", function()
    render_sync()
    local buf = layout.get_collections_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local root_a_line = nil
    for i, l in ipairs(lines) do
      if l:match("Root A") then root_a_line = i end
    end
    assert.is_not_nil(root_a_line)
    local entry = collections.get_collection_at_line(root_a_line)
    assert.matches("Root A", entry.line)
    assert.is_true(entry.has_children)
  end)

  it("get_collection_at_line returns nil out of range", function()
    render_sync()
    assert.is_nil(collections.get_collection_at_line(0))
    assert.is_nil(collections.get_collection_at_line(100000))
  end)

  it("selecting a collection (Enter) loads its items and sets get_selected_collection_id", function()
    render_sync()
    layout.focus_collections()
    local buf = layout.get_collections_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local target_line = nil
    for i, l in ipairs(lines) do
      -- "Child of A" has no children of its own, so <CR> selects it directly
      -- instead of toggling expand/collapse first.
      if l:match("Child of A") then target_line = i end
    end
    assert.is_not_nil(target_line)
    vim.api.nvim_win_set_cursor(layout.get_collections_win(), { target_line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    vim.wait(2000, function() return collections.get_selected_collection_id() ~= nil end, 20)
    assert.equals(2, collections.get_selected_collection_id()) -- "Child of A" is collectionID 2
  end)

  it("collapsing a collection with children hides its child rows", function()
    render_sync()
    layout.focus_collections()
    local function line_count()
      return #vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)
    end
    local before = line_count()

    local function find_line(pattern)
      local lines = vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)
      for i, l in ipairs(lines) do
        if l:match(pattern) then return i end
      end
    end

    vim.api.nvim_win_set_cursor(layout.get_collections_win(), { find_line("Root A"), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false) -- collapse (Root A has children, starts expanded)
    vim.wait(2000, function() return line_count() < before end, 20)
    assert.is_nil(find_line("Child of A"))

    vim.api.nvim_win_set_cursor(layout.get_collections_win(), { find_line("Root A"), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false) -- re-expand
    vim.wait(2000, function() return find_line("Child of A") ~= nil end, 20)
    assert.is_not_nil(find_line("Child of A"))
  end)

  it("refresh_counts() re-queries and re-renders without error", function()
    render_sync()
    assert.has_no.errors(function()
      collections.refresh_counts()
      vim.wait(2000, function() return true end, 10)
    end)
  end)

  it("restore_render() repaints synchronously from in-memory data", function()
    render_sync()
    layout.close()
    layout.create_layout()
    local fresh = collections.restore_render()
    assert.is_boolean(fresh)
    local lines = vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)
    assert.is_true(#lines > 1)
  end)
end)
