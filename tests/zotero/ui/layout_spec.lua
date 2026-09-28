local layout = require("zotero.ui.layout")

describe("layout", function()
  after_each(function()
    if layout.is_open() then
      layout.close()
    end
  end)

  it("is_open() is false before create_layout()", function()
    assert.is_false(layout.is_open())
  end)

  it("create_layout() opens a new tab with only the items window", function()
    local tabs_before = #vim.api.nvim_list_tabpages()
    layout.create_layout()
    assert.is_true(layout.is_open())
    assert.equals(tabs_before + 1, #vim.api.nvim_list_tabpages())
    assert.is_true(vim.api.nvim_win_is_valid(layout.get_items_win()))
    assert.is_nil(layout.get_collections_win())
    assert.same({ layout.get_items_win() }, vim.api.nvim_tabpage_list_wins(0))
  end)

  it("sets its window options only on its own windows, so new windows keep the user's", function()
    local saved = { vim.go.number, vim.go.relativenumber, vim.go.signcolumn, vim.go.cursorline, vim.go.wrap }
    vim.go.number, vim.go.relativenumber, vim.go.signcolumn = true, true, "yes"
    vim.go.cursorline, vim.go.wrap = false, true
    layout.create_layout()
    local items_win = layout.get_items_win()
    assert.is_false(vim.wo[items_win].number) -- the pane itself hides them
    assert.is_true(vim.go.number)
    assert.is_true(vim.go.relativenumber)
    assert.equals("yes", vim.go.signcolumn)
    assert.is_false(vim.go.cursorline)
    assert.is_true(vim.go.wrap)
    -- A window opened from inside the pane starts from the user's settings.
    vim.api.nvim_set_current_win(items_win)
    vim.cmd("new")
    assert.is_true(vim.wo.number)
    assert.equals("yes", vim.wo.signcolumn)
    vim.cmd("close")
    vim.go.number, vim.go.relativenumber, vim.go.signcolumn, vim.go.cursorline, vim.go.wrap = unpack(saved)
  end)

  it("close() closes the tab and resets is_open()", function()
    layout.create_layout()
    layout.close()
    assert.is_false(layout.is_open())
  end)

  it("focus_items() / focus_collections() move the cursor between panes", function()
    layout.create_layout()
    layout.focus_collections()
    assert.equals(layout.get_collections_win(), vim.api.nvim_get_current_win())
    layout.focus_items()
    assert.equals(layout.get_items_win(), vim.api.nvim_get_current_win())
  end)

  it("open_collections() opens a full-width split, below or above as 'splitbelow' says", function()
    local saved = vim.o.splitbelow
    for _, below in ipairs({ true, false }) do
      vim.o.splitbelow = below
      layout.create_layout()
      layout.open_collections()
      local win = layout.get_collections_win()
      assert.equals(win, vim.api.nvim_get_current_win())
      assert.equals(layout.get_collections_buf(), vim.api.nvim_win_get_buf(win))
      assert.equals(vim.o.columns, vim.api.nvim_win_get_width(win))
      local row = vim.api.nvim_win_get_position(win)[1]
      local items_row = vim.api.nvim_win_get_position(layout.get_items_win())[1]
      assert.equals(below, row > items_row)
      layout.close()
    end
    vim.o.splitbelow = saved
  end)

  it("open_collections() again just focuses it; close_collections() closes it and focuses items", function()
    layout.create_layout()
    layout.open_collections()
    local win = layout.get_collections_win()
    layout.focus_items()
    layout.open_collections()
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    layout.close_collections()
    assert.is_nil(layout.get_collections_win())
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.equals(layout.get_items_win(), vim.api.nvim_get_current_win())
  end)

  it("forgets the split when it's closed with :q", function()
    layout.create_layout()
    layout.open_collections()
    vim.cmd("close")
    assert.is_nil(layout.get_collections_win())
  end)

  it("reuses the same buffers across a close+reopen", function()
    layout.create_layout()
    local items_buf = layout.get_items_buf()
    layout.close()
    layout.create_layout()
    assert.equals(items_buf, layout.get_items_buf())
  end)

  it("is_open() detects and recovers from the tab being closed externally", function()
    layout.create_layout()
    vim.api.nvim_set_current_tabpage(layout.get_items_win() and vim.api.nvim_win_get_tabpage(layout.get_items_win()))
    vim.cmd("tabclose")
    assert.is_false(layout.is_open())
    -- A subsequent create_layout() should start fresh without erroring.
    layout.create_layout()
    assert.is_true(layout.is_open())
  end)

  it("toggle_statuscolumn() does not error with no layout open", function()
    assert.has_no.errors(function() layout.toggle_statuscolumn() end)
    layout.toggle_statuscolumn() -- toggle back to avoid bleeding state into other tests
  end)
end)
