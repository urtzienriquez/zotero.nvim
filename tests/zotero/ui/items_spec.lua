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
    feed("mm")
    vim.wait(1000, function() return items.get_marked_count() == 1 end, 10)
    assert.equals(1, items.get_marked_count())

    feed("mm") -- toggle back off
    vim.wait(1000, function() return items.get_marked_count() == 0 end, 10)
    assert.equals(0, items.get_marked_count())
  end)

  it("items_sort_title keymap re-sorts the list", function()
    fetch_sync()
    layout.focus_items()
    local before = table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    feed("st")
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

  describe("feeds", function()
    after_each(function()
      items.load_items(nil)
    end)

    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    end

    it("load_feed() lists only that feed's items and shows the feed in the winbar", function()
      items.load_feed(2, "Journal RSS")
      vim.wait(3000, function() return text():match("Feed article") ~= nil end, 20)
      assert.matches("Feed article unread", text())
      assert.matches("Feed article already read", text())
      assert.does_not.match("Origin of Species", text())
      assert.matches("feed: Journal RSS", vim.wo[layout.get_items_win()].winbar)
    end)

    it("refuses write actions on feed items", function()
      items.load_feed(2, "Journal RSS")
      vim.wait(3000, function() return text():match("Feed article") ~= nil end, 20)
      assert.is_true(items.readonly_guard())
      layout.focus_items()
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { 1, 0 }) -- compact view: first row is an item
      feed("mm") -- marking is a write-ish action too
      vim.wait(200, function() return false end, 20)
      assert.equals(0, items.get_marked_count())
    end)

    it("uses the compact view for feeds, with unread items marked", function()
      items.load_feed(2, "Journal RSS")
      vim.wait(3000, function() return text():match("Feed article") ~= nil end, 20)
      local lines = vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false)
      assert.does_not.match("│", text()) -- no table columns
      local unread_line, read_line
      for _, l in ipairs(lines) do
        if l:match("Feed article unread") then unread_line = l end
        if l:match("Feed article already read") then read_line = l end
      end
      assert.matches("^● ", unread_line)
      assert.matches("^  ", read_line)
      assert.matches("view: compact", vim.wo[layout.get_items_win()].winbar)
    end)

    it("restores the library's table view when leaving the feed", function()
      items.load_feed(2, "Journal RSS")
      vim.wait(3000, function() return text():match("Feed article") ~= nil end, 20)
      fetch_sync()
      assert.matches("│", text())
      assert.does_not.match("view: compact", vim.wo[layout.get_items_win()].winbar)
    end)

    describe("opening feed items", function()
      local api = require("zotero.api")
      local orig_open, orig_set_read, opened, read_calls
      before_each(function()
        orig_open = items.open_external
        orig_set_read = api.set_feed_items_read
        opened, read_calls = {}, {}
        items.open_external = function(target) opened[#opened + 1] = target end
        api.set_feed_items_read = function(library_id, keys, read, opts)
          read_calls[#read_calls + 1] = { library_id = library_id, keys = keys, read = read, quiet = opts and opts.quiet }
          return vim.async.run(function() return false end) -- skip the re-render
        end
      end)
      after_each(function()
        items.open_external = orig_open
        api.set_feed_items_read = orig_set_read
        pcall(require("zotero.ui.detail").close)
      end)

      local function line_of(pattern)
        for i, l in ipairs(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false)) do
          if l:match(pattern) then return i end
        end
      end

      local function open_feed()
        -- The items buffer is reused across tests; blank it so the wait below
        -- can't be satisfied by the previous test's feed rows before this
        -- render (and its items_data) has landed.
        local b = layout.get_items_buf()
        vim.bo[b].modifiable = true
        vim.api.nvim_buf_set_lines(b, 0, -1, false, {})
        vim.bo[b].modifiable = false
        items.load_feed(2, "Journal RSS")
        vim.wait(3000, function() return text():match("Feed article") ~= nil end, 20)
        layout.focus_items()
      end

      it("ob opens the URL, falling back to the DOI", function()
        open_feed()
        vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Feed article unread"), 0 })
        feed("ob")
        vim.wait(2000, function() return #opened == 1 end, 20)
        assert.same({ "https://example.org/unread" }, opened)

        layout.focus_items()
        vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Feed article already read"), 0 })
        feed("ob")
        vim.wait(2000, function() return #opened == 2 end, 20)
        assert.equals("https://doi.org/10.1000/dup", opened[2])
      end)

      it("<CR> shows the preview instead of opening the browser", function()
        open_feed()
        vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Feed article unread"), 0 })
        feed("<CR>")
        vim.wait(300, function() return false end, 20)
        assert.same({}, opened)
        assert.are_not.equal(layout.get_items_win(), vim.api.nvim_get_current_win()) -- focus is in the float
      end)

      it("opening an unread item marks it read (quietly); a read one sends nothing", function()
        open_feed()
        vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Feed article unread"), 0 })
        feed("ob")
        vim.wait(2000, function() return #read_calls == 1 end, 20)
        assert.same({ library_id = 2, keys = { "FEED0010" }, read = true, quiet = true }, read_calls[1])

        layout.focus_items()
        vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Feed article already read"), 0 })
        feed("ob")
        vim.wait(300, function() return false end, 20)
        assert.equals(1, #read_calls)
      end)

      it("rr toggles read state", function()
        open_feed()
        vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Feed article already read"), 0 })
        feed("rr")
        vim.wait(2000, function() return #read_calls == 1 end, 20)
        assert.same({ library_id = 2, keys = { "FEED0009" }, read = false, quiet = false }, read_calls[1])
      end)

      it("<CR> in the library shows the preview and never calls the connector", function()
        fetch_sync()
        layout.focus_items()
        vim.api.nvim_win_set_cursor(layout.get_items_win(), { 3, 0 })
        feed("<CR>")
        vim.wait(300, function() return false end, 20)
        assert.same({}, opened)
        assert.same({}, read_calls)
      end)
    end)

    it("load_items() leaves feed mode", function()
      items.load_feed(2, "Journal RSS")
      fetch_sync()
      assert.is_false(items.is_feed_mode())
      assert.is_false(items.readonly_guard())
    end)
  end)

  describe("type filter", function()
    after_each(function()
      items.set_type_filter("exclude", {})
    end)

    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    end

    it("hides a type and keeps the filter across collection changes", function()
      fetch_sync()
      items.set_type_filter("exclude", { "book" })
      vim.wait(3000, function() return text():match("Origin") == nil end, 20)
      assert.does_not.match("Origin of Species", text())
      assert.matches("Microclimate", text())
      assert.matches("types: hiding book", vim.wo[layout.get_items_win()].winbar)

      items.load_items(1) -- Root A holds items 1 (book) and 2 (article)
      vim.wait(3000, function() return text():match("Microclimate") ~= nil end, 20)
      assert.does_not.match("Origin of Species", text())
      assert.same({ mode = "exclude", types = { "book" } }, items.get_type_filter())
    end)

    it("shows only the chosen type", function()
      fetch_sync()
      items.set_type_filter("include", { "book" })
      vim.wait(3000, function() return text():match("Microclimate") == nil end, 20)
      assert.matches("Origin of Species", text())
      assert.does_not.match("Microclimate", text())
      assert.matches("types: only book", vim.wo[layout.get_items_win()].winbar)
    end)
  end)

  describe("tags", function()
    local api = require("zotero.api")
    local orig_toggle, calls, notes, orig_notify

    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
    end

    local function line_of(pattern)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false)) do
        if l:match(pattern) then return i end
      end
    end

    before_each(function()
      calls, notes = {}, {}
      orig_toggle = api.toggle_tag
      api.toggle_tag = function(keys, tag)
        table.sort(keys)
        calls[#calls + 1] = { keys = keys, tag = tag }
        return require("zotero.async").run("mock", function() return false end) -- skip the re-render
      end
      local async_mod = require("zotero.async")
      orig_notify = async_mod.notify
      async_mod.notify = function(msg, ...)
        notes[#notes + 1] = msg
        return orig_notify(msg, ...)
      end
      items.set_tag_filter({})
      -- Blank the buffer, then wait until the full, unfiltered library is
      -- actually rendered: the buffer and the (new) window's winbar can still
      -- show a previous test's view, and the line numbers below must match
      -- what the keys act on.
      local buf = layout.get_items_buf()
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      vim.bo[buf].modifiable = false
      items.load_items(nil)
      local ready = vim.wait(10000, function()
        local t = text()
        return t:match("Origin") and t:match("Microclimate") and t:match("Population") and t:match("Field Report")
      end, 20)
      assert(ready, "the full library did not render")
      layout.focus_items()
    end)

    after_each(function()
      api.toggle_tag = orig_toggle
      require("zotero.async").notify = orig_notify
      items.set_tag_filter({})
    end)

    it("shows a coloured dot for each colored tag an item has, and its colour wins", function()
      local line = line_of("Microclimate")
      assert.matches("● Microclimate", text())
      local dot_col = vim.api.nvim_buf_get_lines(layout.get_items_buf(), line - 1, line, false)[1]:find("●", 1, true) - 1
      -- Of all highlights covering the dot, the one with the highest priority
      -- is what's shown: it must be the tag colour, not the title's.
      local ns = vim.api.nvim_create_namespace("zotero-items-hl")
      local top, top_priority = nil, -1
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(layout.get_items_buf(), ns, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
        local d = m[4]
        local end_col = d.end_col or math.huge
        if d.hl_group and m[3] <= dot_col and dot_col < end_col and (d.priority or 0) > top_priority then
          top, top_priority = d.hl_group, d.priority or 0
        end
      end
      assert.equals("ZoteroTagColor1", top) -- ecology = colored tag 1
      assert.equals("#ff6666", string.format("#%06x", vim.api.nvim_get_hl(0, { name = "ZoteroTagColor1" }).fg))
    end)

    it("reports an error from a tag action instead of failing silently", function()
      api.toggle_tag = function() error("boom from the connector", 0) end
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Origin of Species"), 0 })
      feed("t1")
      vim.wait(2000, function()
        for _, n in ipairs(notes) do
          if n:match("tag action failed") then return true end
        end
      end, 20)
      local found = false
      for _, n in ipairs(notes) do
        if n:match("tag action failed: boom from the connector") then found = true end
      end
      assert.is_true(found)
    end)

    it("t1 toggles colored tag 1 on the item under the cursor", function()
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Origin of Species"), 0 })
      feed("t1")
      vim.wait(2000, function() return #calls == 1 end, 20)
      assert.same({ keys = { "BOOK0001" }, tag = "ecology" }, calls[1])
    end)

    it("t2 in visual mode toggles colored tag 2 on every selected item", function()
      -- The first two rows, whatever the current sort order (earlier tests
      -- change it); expected keys come from the titles on those rows.
      local key_of_title = { Population = "ART00003", Origin = "BOOK0001", Microclimate = "ART00002",
        Field = "DOC00005", ["no title"] = "PLAIN008" }
      local lines = vim.api.nvim_buf_get_lines(layout.get_items_buf(), 2, 4, false)
      local expected = {}
      for _, l in ipairs(lines) do
        for word, key in pairs(key_of_title) do
          if l:find(word, 1, true) then expected[#expected + 1] = key end
        end
      end
      table.sort(expected)
      assert.equals(2, #expected)

      vim.api.nvim_win_set_cursor(layout.get_items_win(), { 3, 0 })
      feed("Vjt2")
      vim.wait(2000, function() return #calls == 1 end, 20)
      assert.same({ keys = expected, tag = "genetics" }, calls[1])
    end)

    it("t3 without a third colored tag explains where to assign one and sends nothing", function()
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Origin of Species"), 0 })
      feed("t3")
      vim.wait(1000, function() return #notes > 0 end, 20)
      assert.same({}, calls)
      assert.matches("no colored tag 3", notes[#notes])
    end)

    it("refuses to toggle tags on feed items", function()
      items.load_feed(2, "Journal RSS")
      vim.wait(3000, function() return text():match("Feed article") ~= nil end, 20)
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { 1, 0 })
      feed("t1")
      vim.wait(300, function() return false end, 20)
      assert.same({}, calls)
      items.load_items(nil)
    end)

    it("the tag filter survives switching collection and shows in the winbar", function()
      items.set_tag_filter({ "ecology" })
      vim.wait(3000, function() return not text():match("Origin") end, 20)
      items.load_items(1) -- Root A has items 1 and 2; only 2 has "ecology"
      vim.wait(3000, function() return text():match("Microclimate") ~= nil end, 20)
      assert.does_not.match("Origin", text())
      assert.matches("tags: ecology", vim.wo[layout.get_items_win()].winbar)
    end)
  end)

  describe("yank keys", function()
    local function line_of(pattern)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false)) do
        if l:match(pattern) then return i end
      end
    end

    it("yk yanks the citation key into the given register", function()
      items.show_results({ { itemID = 2, title = "Some Paper", citationKey = "darwin1859", _authors = "", year = "" } })
      layout.focus_items()
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Some Paper"), 0 })
      feed('"ayk')
      assert.equals("darwin1859", vim.fn.getreg("a"))
    end)

    it("yk leaves the register alone when the item has no citation key", function()
      items.show_results({ { itemID = 2, title = "No Key Paper", _authors = "", year = "" } })
      layout.focus_items()
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("No Key Paper"), 0 })
      vim.fn.setreg("b", "untouched")
      feed('"byk')
      assert.equals("untouched", vim.fn.getreg("b"))
    end)

    it("yp yanks the full path of the item's attached file", function()
      -- Item 2's attachment is "attachments:snapshot.pdf", resolved under ~/Zotero.
      local home = vim.fn.tempname()
      vim.fn.mkdir(home .. "/Zotero", "p")
      local pdf = home .. "/Zotero/snapshot.pdf"
      vim.fn.writefile({ "%PDF" }, pdf)
      local orig_home = vim.env.HOME
      vim.env.HOME = home

      fetch_sync()
      layout.focus_items()
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Microclimate"), 0 })
      vim.fn.setreg("c", "")
      feed('"cyp')
      vim.wait(3000, function() return vim.fn.getreg("c") ~= "" end, 20)

      vim.env.HOME = orig_home
      assert.equals(vim.uv.fs_realpath(pdf), vim.uv.fs_realpath(vim.fn.getreg("c")))
      vim.fn.delete(home, "rf")
    end)

    it("yp does nothing for an item without attachments", function()
      fetch_sync()
      layout.focus_items()
      vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Origin of Species"), 0 })
      vim.fn.setreg("d", "untouched")
      feed('"dyp')
      vim.wait(300, function() return false end, 20)
      assert.equals("untouched", vim.fn.getreg("d"))
    end)
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

      feed("tv")
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
