local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")
local tf = require("zotero.ui.type_filter")

local function backdrop_count()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[w].winhl:find("ZoteroDetailBackdrop", 1, true) then
      n = n + 1
    end
  end
  return n
end

describe("type_filter helpers", function()
  local none = { mode = "exclude", types = {} }

  it("is_visible follows exclude/include semantics", function()
    assert.is_true(tf.is_visible(none, "book"))
    assert.is_false(tf.is_visible({ mode = "exclude", types = { "book" } }, "book"))
    assert.is_true(tf.is_visible({ mode = "include", types = { "book" } }, "book"))
    assert.is_false(tf.is_visible({ mode = "include", types = { "book" } }, "thesis"))
  end)

  it("toggle hides and re-shows a type", function()
    local hidden = tf.toggle(none, "webpage")
    assert.same({ mode = "exclude", types = { "webpage" } }, hidden)
    assert.same(none, tf.toggle(hidden, "webpage"))
  end)

  it("toggle in 'only' mode adds/removes shown types, and never ends up showing nothing", function()
    local only = tf.only("book")
    assert.same({ mode = "include", types = { "book", "thesis" } }, tf.toggle(only, "thesis"))
    assert.same(tf.all(), tf.toggle(only, "book"))
  end)

  it("rows lists present types with counts plus filtered types that aren't present", function()
    local rows = tf.rows({ { typeName = "journalArticle", count = 3 }, { typeName = "book", count = 1 } },
      { mode = "exclude", types = { "webpage" } })
    assert.same({
      { name = "journalArticle", count = 3 },
      { name = "book", count = 1 },
      { name = "webpage", count = 0 },
    }, rows)
  end)
end)

describe("type_filter checklist (real buffers, fixture db)", function()
  local function text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function items_text()
    return text(layout.get_items_buf())
  end

  local function open_checklist()
    items.pick_type_filter()
    vim.wait(3000, function() return tf.is_open() end, 20)
    assert.is_true(tf.is_open())
    return vim.api.nvim_get_current_buf()
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

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  before_each(function()
    vim.o.columns = 200
    vim.o.lines = 50
    fixture.setup()
    layout.create_layout()
    items.set_keymaps()
    items.set_type_filter("exclude", {})
    items.load_items(nil)
    vim.wait(3000, function() return items_text():match("Origin") ~= nil end, 20)
    layout.focus_items()
  end)

  after_each(function()
    tf.close()
    items.set_type_filter("exclude", {})
    vim.wait(300, function() return false end, 20)
    layout.close()
    fixture.teardown()
  end)

  it("lists the view's types with counts, all checked", function()
    local buf = open_checklist()
    local t = text(buf)
    assert.matches("%[x%] journalArticle%s+%(2%)", t)
    assert.matches("%[x%] book%s+%(1%)", t)
    assert.matches("%[x%] document%s+%(2%)", t)
  end)

  it("<CR> unchecks a type and hides it from the items list; <CR> again brings it back", function()
    local buf = open_checklist()
    cursor_to("book")
    press("<CR>")
    vim.wait(3000, function() return items_text():match("Origin") == nil end, 20)
    assert.matches("%[ %] book", text(buf))
    assert.does_not.match("Origin of Species", items_text())
    assert.is_true(tf.is_open()) -- stays open for more toggles

    press("<CR>")
    vim.wait(3000, function() return items_text():match("Origin") ~= nil end, 20)
    assert.matches("%[x%] book", text(buf))
  end)

  it("o shows only the type under the cursor, a shows everything again", function()
    local buf = open_checklist()
    cursor_to("book")
    press("o")
    vim.wait(3000, function() return items_text():match("Microclimate") == nil end, 20)
    assert.matches("%[x%] book", text(buf))
    assert.matches("%[ %] journalArticle", text(buf))
    assert.same({ mode = "include", types = { "book" } }, items.get_type_filter())

    press("a")
    vim.wait(3000, function() return items_text():match("Microclimate") ~= nil end, 20)
    assert.same({ mode = "exclude", types = {} }, items.get_type_filter())
  end)

  it("dims the background while open, and q closes both", function()
    open_checklist()
    assert.equals(1, backdrop_count())
    press("q")
    assert.is_false(tf.is_open())
    assert.equals(0, backdrop_count())
  end)

  it("stays on screen and centered after a resize", function()
    open_checklist()
    local win = vim.api.nvim_get_current_win()
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 30, 12
    vim.api.nvim_exec_autocmds("VimResized", {})
    local cfg = vim.api.nvim_win_get_config(win)
    local w, h = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    local rows = vim.o.lines - vim.o.cmdheight
    assert.is_true(w <= 30 - 4 and h <= rows - 4)
    assert.equals(math.floor((30 - w) / 2), cfg.col)
    assert.equals(math.floor((rows - h) / 2), cfg.row)
    press("q")
    vim.o.columns, vim.o.lines = columns, lines
  end)

  it("removes the backdrop when focus leaves the checklist", function()
    open_checklist()
    layout.focus_items()
    vim.wait(1000, function() return not tf.is_open() end, 20)
    assert.is_false(tf.is_open())
    assert.equals(0, backdrop_count())
  end)
end)
