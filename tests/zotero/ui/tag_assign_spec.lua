local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")
local assign = require("zotero.ui.tag_assign")

describe("tag_assign.state", function()
  local has = { [1] = { a = true, b = true }, [2] = { a = true } }
  it("is true when every item has the tag, partial when some do, false when none", function()
    assert.is_true(assign.state(has, { 1, 2 }, "a"))
    assert.equals("partial", assign.state(has, { 1, 2 }, "b"))
    assert.is_false(assign.state(has, { 1, 2 }, "c"))
    assert.is_true(assign.state(has, { 1 }, "b"))
  end)
end)

describe("tt tag checklist (real buffers, fixture db, mocked connector)", function()
  local api = require("zotero.api")
  local orig_toggle, calls, next_added

  local function items_lines()
    return vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false)
  end

  local function line_of(pattern)
    for i, l in ipairs(items_lines()) do
      if l:match(pattern) then return i end
    end
  end

  local function float_text()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function cursor_to(pattern)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:match(pattern) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    error("no line matching " .. pattern)
  end

  local function open_on(keys)
    press(keys)
    vim.wait(3000, function() return assign.is_open() end, 20)
    assert.is_true(assign.is_open())
  end

  before_each(function()
    vim.o.columns = 200
    vim.o.lines = 50
    fixture.setup()
    layout.create_layout()
    items.set_keymaps()
    items.load_items(nil)
    vim.wait(3000, function()
      return vim.wo[layout.get_items_win()].winbar:match(" 5 items") ~= nil
    end, 20)
    layout.focus_items()
    calls, next_added = {}, true
    orig_toggle = api.toggle_tag
    api.toggle_tag = function(keys, tag)
      table.sort(keys)
      calls[#calls + 1] = { keys = keys, tag = tag }
      local added = next_added
      return require("zotero.async").run("mock", function() return true, added end)
    end
  end)

  after_each(function()
    api.toggle_tag = orig_toggle
    assign.close()
    vim.wait(300, function() return false end, 20)
    layout.close()
    fixture.teardown()
  end)

  it("shows which tags the item has, colored tags first", function()
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Microclimate"), 0 })
    open_on("tt")
    local text = float_text()
    assert.matches("%[x%] 1 ● ecology", text)
    assert.matches("%[ %] 2 ● genetics", text)
  end)

  it("<CR> adds and removes tags one after another without closing", function()
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Microclimate"), 0 })
    open_on("tt")

    cursor_to("genetics")
    next_added = true
    press("<CR>")
    vim.wait(3000, function() return float_text():match("%[x%] 2 ● genetics") ~= nil end, 20)
    assert.matches("%[x%] 2 ● genetics", float_text())

    cursor_to("ecology")
    next_added = false
    press("<CR>")
    vim.wait(3000, function() return float_text():match("%[ %] 1 ● ecology") ~= nil end, 20)
    assert.matches("%[ %] 1 ● ecology", float_text())

    assert.is_true(assign.is_open())
    assert.same({
      { keys = { "ART00002" }, tag = "genetics" },
      { keys = { "ART00002" }, tag = "ecology" },
    }, calls)
  end)

  it("shows [~] for tags only some selected items have, and applies to all of them", function()
    -- Two adjacent rows, whatever the sort order; pick ones where exactly one has ecology.
    local a = line_of("Microclimate")
    local b = (a > 3) and a - 1 or a + 1
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { math.min(a, b), 0 })
    open_on("Vjtt")
    assert.matches("%[~%] 1 ● ecology", float_text())
    cursor_to("ecology")
    press("<CR>")
    vim.wait(3000, function() return #calls == 1 end, 20)
    assert.equals(2, #calls[1].keys)
    assert.equals("ecology", calls[1].tag)
  end)

  it("n adds a new tag to the item(s)", function()
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Origin of Species"), 0 })
    open_on("tt")
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb) cb("  to-read  ") end
    press("n")
    vim.ui.input = orig_input
    vim.wait(3000, function() return #calls == 1 end, 20)
    assert.same({ keys = { "BOOK0001" }, tag = "to-read" }, calls[1])
  end)

  it("cc / dd act on the tag under the cursor", function()
    local actions = require("zotero.ui.tag_actions")
    local orig_colour, orig_delete = actions.assign_colour, actions.delete_tags
    local called = {}
    actions.assign_colour = function(name) called[#called + 1] = { "colour", name } end
    actions.delete_tags = function(names) called[#called + 1] = { "delete", names } end
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Microclimate"), 0 })
    open_on("tt")
    cursor_to("genetics")
    press("cc")
    press("dd")
    cursor_to("ecology")
    press("Vjdd") -- visual: ecology and genetics
    actions.assign_colour, actions.delete_tags = orig_colour, orig_delete
    assert.same({
      { "colour", "genetics" },
      { "delete", { "genetics" } },
      { "delete", { "ecology", "genetics" } },
    }, called)
  end)

  it("q closes it", function()
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { line_of("Origin of Species"), 0 })
    open_on("tt")
    press("q")
    assert.is_false(assign.is_open())
  end)
end)
