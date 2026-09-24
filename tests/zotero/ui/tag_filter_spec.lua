local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")
local tagf = require("zotero.ui.tag_filter")

local function backdrop_count()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[w].winhl:find("ZoteroDetailBackdrop", 1, true) then
      n = n + 1
    end
  end
  return n
end

describe("tag_filter helpers", function()
  it("toggle / only / all build the list of required tags", function()
    assert.same({ "a" }, tagf.toggle({}, "a"))
    assert.same({ "a", "b" }, tagf.toggle({ "a" }, "b"))
    assert.same({ "b" }, tagf.toggle({ "a", "b" }, "a"))
    assert.same({ "x" }, tagf.only("x"))
    assert.same({}, tagf.all())
  end)

  it("ordered lists colored tags first (always, in key order), then the rest, then filtered leftovers", function()
    local counts = { { name = "alpha", count = 3 }, { name = "to-read", count = 5 } }
    local colored = { { name = "to-read", color = "#ff0000" }, { name = "unused", color = "#00ff00" } }
    assert.same({
      { name = "to-read", count = 5, index = 1 },
      { name = "unused", count = 0, index = 2 },
      { name = "alpha", count = 3 },
      { name = "gone", count = 0 },
    }, tagf.ordered(counts, { "gone" }, colored))
  end)

  it("prefix gives colored tags their number and a dot, others matching padding", function()
    local p, hls = tagf.prefix(1, true)
    assert.equals("1 ● ", p)
    assert.same({ { 2, 2 + #"●", "ZoteroTagColor1" } }, hls)
    assert.equals("    ", (tagf.prefix(nil, true)))
    assert.equals("", (tagf.prefix(nil, false)))
  end)
end)

describe("tag_filter checklist (real buffers, fixture db)", function()
  local function text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function items_text()
    return text(layout.get_items_buf())
  end

  local function open_checklist()
    items.pick_tag_filter()
    vim.wait(3000, function() return tagf.is_open() end, 20)
    assert.is_true(tagf.is_open())
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

  local function winbar()
    return vim.wo[layout.get_items_win()].winbar
  end

  before_each(function()
    vim.o.columns = 200
    vim.o.lines = 50
    fixture.setup()
    layout.create_layout()
    items.set_keymaps()
    items.set_tag_filter({})
    items.load_items(nil)
    vim.wait(3000, function() return items_text():match("Origin") ~= nil end, 20)
    layout.focus_items()
  end)

  after_each(function()
    tagf.close()
    items.set_tag_filter({})
    vim.wait(300, function() return false end, 20)
    layout.close()
    fixture.teardown()
  end)

  it("lists the view's tags, colored ones first with their number, none checked", function()
    local buf = open_checklist()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.matches("^ %[ %] 1 ● ecology%s+%(1%)", lines[1])
    assert.matches("^ %[ %] 2 ● genetics%s+%(1%)", lines[2])
    assert.equals(1, backdrop_count())
  end)

  it("<CR> requires a tag (items list filtered, winbar shows it); a clears", function()
    local buf = open_checklist()
    cursor_to("ecology")
    press("<CR>")
    vim.wait(3000, function() return winbar():match("tags: ecology") ~= nil end, 20)
    assert.matches("%[x%] 1 ● ecology", text(buf))
    assert.matches("Microclimate", items_text())
    assert.does_not.match("Origin", items_text())
    assert.same({ "ecology" }, items.get_tag_filter())

    press("a")
    vim.wait(3000, function() return winbar():match("tags:") == nil end, 20)
    assert.same({}, items.get_tag_filter())
  end)

  it("o keeps only the tag under the cursor", function()
    items.set_tag_filter({ "ecology" })
    open_checklist()
    cursor_to("genetics")
    press("o")
    assert.same({ "genetics" }, items.get_tag_filter())
  end)

  it("q closes it together with the backdrop", function()
    open_checklist()
    press("q")
    assert.is_false(tagf.is_open())
    assert.equals(0, backdrop_count())
  end)
end)
