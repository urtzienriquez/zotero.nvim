local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local collections = require("zotero.ui.collections")

local function render_sync()
  -- layout reuses the collections buffer across tests, so blank it first:
  -- otherwise the wait below is satisfied by the previous test's lines
  -- before this render has landed.
  local b = layout.get_collections_buf()
  if b and vim.api.nvim_buf_is_valid(b) then
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, {})
    vim.bo[b].modifiable = false
  end
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

    layout.focus_collections() -- <CR> on a collection moves focus to the items pane
    vim.api.nvim_win_set_cursor(layout.get_collections_win(), { find_line("Root A"), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false) -- re-expand
    vim.wait(2000, function() return find_line("Child of A") ~= nil end, 20)
    assert.is_not_nil(find_line("Child of A"))
  end)

  it("renders a Feeds section with unread counts, separate from My Library", function()
    render_sync()
    local text = table.concat(vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false), "\n")
    assert.matches("Feeds %(1%)", text)
    assert.matches("Journal RSS %(1%)", text)
    assert.does_not.match("Group Col", text) -- group-library collection stays out
  end)

  it("selecting a feed (Enter) lists that feed's items", function()
    vim.o.columns = 200 -- headless default is too narrow, truncates titles
    layout.close()
    layout.create_layout()
    render_sync()
    layout.focus_collections()
    local lines = vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)
    local target_line = nil
    for i, l in ipairs(lines) do
      if l:match("Journal RSS") then target_line = i end
    end
    assert.is_not_nil(target_line)
    local entry = collections.get_collection_at_line(target_line)
    assert.is_true(entry.is_feed)
    assert.equals(2, entry.feed_library_id)

    vim.api.nvim_win_set_cursor(layout.get_collections_win(), { target_line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    local items_text = function()
      return table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    end
    vim.wait(3000, function() return items_text():match("Feed article unread") ~= nil end, 20)
    assert.matches("Feed article unread", items_text())
    assert.does_not.match("Origin of Species", items_text())
    assert.is_true(require("zotero.ui.items").is_feed_mode())
    assert.is_nil(collections.get_selected_collection_id())
    require("zotero.ui.items").load_items(nil) -- leave items.lua in library mode for later specs
  end)

  describe("managing feeds", function()
    local api = require("zotero.api")
    local orig = {}
    local calls

    before_each(function()
      calls = {}
      for _, name in ipairs({ "add_feed", "delete_feed", "refresh_feeds" }) do
        orig[name] = api[name]
        api[name] = function(...)
          calls[#calls + 1] = { name, ... }
          return require("zotero.async").run("mock", function() return true end)
        end
      end
      orig.input, orig.confirm = vim.ui.input, vim.fn.confirm
      vim.ui.input = function(_, cb) cb("https://example.org/new.xml") end
      vim.fn.confirm = function() return 1 end
    end)

    after_each(function()
      for name, fn in pairs(orig) do
        if name == "input" then vim.ui.input = fn
        elseif name == "confirm" then vim.fn.confirm = fn
        else api[name] = fn end
      end
    end)

    local function press_on(pattern, keys)
      layout.focus_collections()
      local lines = vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)
      for i, l in ipairs(lines) do
        if l:match(pattern) then
          vim.api.nvim_win_set_cursor(layout.get_collections_win(), { i, 0 })
          break
        end
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
      vim.wait(2000, function() return #calls > 0 end, 20)
    end

    it("shows 'Feeds (0)' even when there are no feeds", function()
      local h = io.popen(("sqlite3 '%s' 'DELETE FROM feeds'"):format(fixture.db_path))
      h:close()
      require("zotero.db").invalidate_cache()
      render_sync()
      local text = table.concat(vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false), "\n")
      assert.matches("Feeds %(0%)", text)
      assert.does_not.match("Journal RSS", text)
    end)

    it("aa on the Feeds header prompts for a URL and adds a feed", function()
      render_sync()
      press_on("^  Feeds", "aa")
      assert.same({ "add_feed", "https://example.org/new.xml" }, calls[1])
    end)

    it("aa on a collection still creates a collection, not a feed", function()
      render_sync()
      local orig_create = api.create_collection
      api.create_collection = function(...)
        calls[#calls + 1] = { "create_collection", ... }
        return require("zotero.async").run("mock", function() return false end)
      end
      press_on("Root B", "aa")
      api.create_collection = orig_create
      assert.equals("create_collection", calls[1][1])
    end)

    it("dd on a feed unsubscribes from it", function()
      render_sync()
      press_on("Journal RSS", "dd")
      assert.same({ "delete_feed", 2 }, calls[1])
    end)

    it("R refreshes one feed on a feed line, all feeds on the header", function()
      render_sync()
      press_on("Journal RSS", "R")
      assert.same({ "refresh_feeds", 2 }, calls[1])
      calls = {}
      press_on("^  Feeds", "R")
      assert.same({ "refresh_feeds" }, calls[1]) -- library_id nil = all feeds
    end)
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
