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
  -- Wait for this render itself: an items load left over from a previous
  -- test can redraw the split (its Viewing: line) with older data first.
  fixture.wait_for(collections.render())
  -- A newer refresh (e.g. one a previous test's action started) supersedes
  -- this render, which then skips drawing: wait for whichever draws.
  vim.wait(3000, function()
    return vim.api.nvim_buf_line_count(layout.get_collections_buf()) > 1
  end, 20)
end

-- The Viewing:/Filter:/Help: lines at the top repeat names (the viewed
-- collection or feed, filtered tags), so tests that look for an entry by
-- its text skip them.
local function is_header(lnum)
  local entry = collections.get_collection_at_line(lnum)
  return entry ~= nil and entry.is_header == true
end

-- The tree's lines (without the header), as { lnum, text }.
local function tree_lines()
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)) do
    if not is_header(i) then out[#out + 1] = { i, l } end
  end
  return out
end

local function tree_text()
  return table.concat(vim.tbl_map(function(x) return x[2] end, tree_lines()), "\n")
end

-- What the collections window actually shows: the pane uses real Vim
-- folds, so a closed fold is displayed as its foldtext and the lines inside
-- it are hidden (the buffer itself always holds the full tree).
local function screen_text()
  local win = layout.get_collections_win()
  local shown = {}
  vim.api.nvim_win_call(win, function()
    local l, n = 1, vim.api.nvim_buf_line_count(0)
    while l <= n do
      if is_header(l) then
        l = l + 1
      elseif vim.fn.foldclosed(l) ~= -1 then
        shown[#shown + 1] = vim.fn.foldtextresult(l)
        l = vim.fn.foldclosedend(l) + 1
      else
        shown[#shown + 1] = vim.fn.getline(l)
        l = l + 1
      end
    end
  end)
  return table.concat(shown, "\n")
end

describe("collections (real buffers, fixture db)", function()
  before_each(function()
    fixture.setup()
    layout.create_layout()
    layout.open_collections() -- the split gb opens
    -- Fold state is module-level; start every test from the defaults.
    collections.reset_folds()
    -- Only when needed: set_tag_filter() starts an items reload, which would
    -- race tests that edit the fixture db directly.
    local items = require("zotero.ui.items")
    if #items.get_tag_filter() > 0 then
      items.set_tag_filter({})
    end
  end)

  after_each(function()
    vim.wait(300, function() return false end, 20) -- let trailing async work settle
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

  it("<CR> on a collection loads it and closes the split, back to the items", function()
    render_sync()
    layout.focus_collections()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)) do
      if l:match("Root A") then vim.api.nvim_win_set_cursor(layout.get_collections_win(), { i, 0 }) end
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.equals(1, collections.get_selected_collection_id()) -- Root A
    assert.is_nil(layout.get_collections_win())
    assert.equals(layout.get_items_win(), vim.api.nvim_get_current_win())
    -- Its folds are unchanged: <CR> selects, za folds.
    layout.open_collections()
    assert.matches("Child of A", screen_text())
  end)

  describe("fugitive/sessman-style header", function()
    local items = require("zotero.ui.items")
    local function header()
      local out = {}
      for i, l in ipairs(vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)) do
        if not is_header(i) then break end
        out[#out + 1] = l
      end
      return out
    end

    after_each(function()
      items.set_tag_filter({})
      items.load_items(nil)
      vim.wait(200)
    end)

    it("shows Viewing: and Help:, then the tree; the cursor starts on My Library", function()
      items.load_items(nil)
      render_sync()
      collections.refresh_display()
      assert.same({ "Viewing: My Library", "Help:    g?" }, header())
      -- Where a fresh split starts (line 1 is a header line): on My Library.
      vim.api.nvim_win_set_cursor(layout.get_collections_win(), { 1, 0 })
      layout.close_collections()
      layout.open_collections()
      local cur = vim.api.nvim_win_get_cursor(layout.get_collections_win())[1]
      assert.matches("^▼ My Library", vim.api.nvim_buf_get_lines(layout.get_collections_buf(), cur - 1, cur, false)[1])
    end)

    it("follows the view, and shows Filter: only while something narrows the list", function()
      items.load_items(1) -- Root A
      items.set_tag_filter({ "ecology" })
      render_sync()
      collections.refresh_display()
      assert.same({ "Viewing: Root A", "Filter:  tags ecology", "Help:    g?" }, header())
      items.set_tag_filter({})
      items.load_trash()
      vim.wait(300)
      collections.refresh_display()
      assert.same({ "Viewing: Trash", "Help:    g?" }, header())
    end)

    it("keeps Marked and Trash together at the end", function()
      render_sync()
      local lines = vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)
      assert.same({ "  Marked (0)", "  Trash (2)" }, { lines[#lines - 1], lines[#lines] })
    end)

    it("uses the standard groups fugitive and sessman use, unless the user set their own", function()
      require("zotero.ui.highlights").setup()
      for group, link in pairs({ ZoteroCollectionsLabel = "Label", ZoteroCollectionsHeading = "PreProc",
        ZoteroCollectionsCount = "Comment", ZoteroCollectionsHelp = "Tag" }) do
        assert.equals(link, vim.api.nvim_get_hl(0, { name = group }).link)
      end
      vim.api.nvim_set_hl(0, "ZoteroCollectionsHeading", { fg = "#ff0000" })
      require("zotero.ui.highlights").setup()
      assert.is_nil(vim.api.nvim_get_hl(0, { name = "ZoteroCollectionsHeading" }).link)
      vim.api.nvim_set_hl(0, "ZoteroCollectionsHeading", { link = "PreProc" })
    end)
  end)

  it("renders a Feeds section with unread counts, separate from My Library", function()
    render_sync()
    collections.set_section_open("feeds", true)
    local text = tree_text()
    assert.matches("Feeds %(1%)", text)
    assert.matches("Journal RSS %(1%)", text)
    assert.does_not.match("Group Col", text) -- group-library collection stays out
  end)

  describe("foldable sections (real Vim folds)", function()
    local text = screen_text
    local function press_on(pattern, keys)
      layout.focus_collections()
      for _, x in ipairs(tree_lines()) do
        if x[2]:match(pattern) then
          vim.api.nvim_win_set_cursor(layout.get_collections_win(), { x[1], 0 })
          break
        end
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end

    it("sets its fold options only for its window, never the global ones", function()
      local global_minlines, global_method = vim.go.foldminlines, vim.go.foldmethod
      local types = {}
      local au = vim.api.nvim_create_autocmd("OptionSet", {
        pattern = "foldminlines",
        callback = function() types[#types + 1] = vim.v.option_type end,
      })
      render_sync()
      vim.api.nvim_del_autocmd(au)
      local win = layout.get_collections_win()
      assert.equals(0, vim.wo[win].foldminlines)
      assert.equals("expr", vim.wo[win].foldmethod)
      assert.equals(global_minlines, vim.go.foldminlines)
      assert.equals(global_method, vim.go.foldmethod)
      -- A "global" OptionSet makes Neovim's treesitter folding refresh every
      -- buffer it knows, which fails on one that's already wiped.
      assert.is_false(vim.tbl_contains(types, "global"))
    end)

    it("starts with My Library open (collections shown) and Feeds folded", function()
      render_sync()
      assert.matches("▼ My Library %(5%)", text())
      assert.matches("Root A %(2%)", text())
      assert.matches("▶ Feeds %(1%)", text())
      assert.does_not.match("Journal RSS", text())
    end)

    it("za folds and unfolds My Library without loading items", function()
      render_sync()
      local items = require("zotero.ui.items")
      local loaded = false
      local orig = items.load_items
      items.load_items = function() loaded = true end
      press_on("My Library", "za")
      assert.matches("▶ My Library", text())
      assert.does_not.match("Root A", text())
      press_on("My Library", "za")
      assert.matches("▼ My Library", text())
      assert.matches("Root A", text())
      items.load_items = orig
      assert.is_false(loaded)
    end)

    it("<CR> on My Library loads its items and closes the split, without folding it", function()
      render_sync()
      local items = require("zotero.ui.items")
      local loaded_with = "not called"
      local orig = items.load_items
      items.load_items = function(id) loaded_with = id end
      press_on("My Library", "<CR>")
      items.load_items = orig
      assert.is_nil(loaded_with) -- load_items(nil) = the whole library
      assert.is_nil(layout.get_collections_win())
      layout.open_collections()
      assert.matches("▼ My Library", text())
      assert.matches("Root A", text())
    end)

    it("<CR> and za both open and close Feeds", function()
      render_sync()
      press_on("Feeds %(", "<CR>")
      assert.matches("▼ Feeds", text())
      assert.matches("Journal RSS %(1%)", text())
      press_on("Feeds %(", "za")
      assert.matches("▶ Feeds", text())
      assert.does_not.match("Journal RSS", text())
    end)

    it("has a Tags section, folded by default, with colored tags first", function()
      render_sync()
      assert.matches("▶ Tags %(2%)", text())
      assert.does_not.match("ecology", text())
      press_on("Tags %(", "<CR>")
      assert.matches("▼ Tags", text())
      assert.matches("1 ● ecology %(1%)", text())
      assert.matches("2 ● genetics %(1%)", text())
    end)

    it("<CR> on a tag filters the items by it and closes the split; the tag shows as marked", function()
      render_sync()
      local items = require("zotero.ui.items")
      collections.set_section_open("tags", true)
      press_on("ecology", "<CR>")
      assert.same({ "ecology" }, items.get_tag_filter())
      assert.is_nil(layout.get_collections_win())
      layout.open_collections()
      vim.wait(2000, function() return text():match("✓ 1 ● ecology") ~= nil end, 20)
      assert.matches("✓ 1 ● ecology", text())
      press_on("ecology", "<CR>") -- again: removed from the filter
      assert.same({}, items.get_tag_filter())
      layout.open_collections()
      vim.wait(2000, function() return text():match("✓") == nil end, 20)
      assert.does_not.match("✓", text())
    end)

    it("zR opens every fold and zM closes them all, like in any buffer", function()
      render_sync()
      press_on("My Library", "zR")
      assert.matches("Journal RSS", text())
      assert.matches("genetics", text())
      assert.matches("Child of A", text())
      press_on("My Library", "zM")
      assert.matches("▶ My Library", text())
      assert.matches("▶ Feeds", text())
      assert.matches("▶ Tags", text())
      assert.does_not.match("Root A", text())
    end)

    it("keeps the folds as you left them when the pane is redrawn", function()
      render_sync()
      press_on("Feeds %(", "zo")
      press_on("Root A", "zc")
      collections.refresh_counts()
      vim.wait(1000, function() return false end, 20)
      assert.matches("Journal RSS", text()) -- Feeds still open
      assert.matches("▶ Root A", text()) -- Root A still closed
      assert.does_not.match("Child of A", text())
    end)

    it("za on a collection with children folds it without selecting it", function()
      render_sync()
      press_on("Root A", "za")
      assert.does_not.match("Child of A", text())
      assert.is_nil(collections.get_selected_collection_id())
      press_on("Root A", "za")
      assert.matches("Child of A", text())
    end)
  end)

  it("selecting a feed (Enter) lists that feed's items", function()
    vim.o.columns = 200 -- headless default is too narrow, truncates titles
    layout.close()
    layout.create_layout()
    render_sync()
    collections.set_section_open("feeds", true)
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
      collections.set_section_open("feeds", true) -- these tests act on feed lines
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
      for _, x in ipairs(tree_lines()) do
        if x[2]:match(pattern) then
          vim.api.nvim_win_set_cursor(layout.get_collections_win(), { x[1], 0 })
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
      local text = tree_text()
      assert.matches("Feeds %(0%)", text)
      assert.does_not.match("Journal RSS", text)
    end)

    it("aa on the Feeds header prompts for a URL and adds a feed", function()
      render_sync()
      press_on("Feeds %(", "aa")
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
      press_on("Feeds %(", "R")
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
