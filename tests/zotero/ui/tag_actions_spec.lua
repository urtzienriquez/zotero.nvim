local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local actions = require("zotero.ui.tag_actions")

local colored = { { name = "ecology", color = "#FF6666" }, { name = "genetics", color = "#5FB236" } }

describe("tag_actions choices", function()
  it("offers Zotero's 9 colours, marks the current one, and 'Remove colour' only for colored tags", function()
    local choices = actions.colour_choices("ecology", colored)
    assert.equals(10, #choices)
    assert.matches("#FF6666  %(current%)", choices[1].label)
    assert.is_true(choices[10].remove)
    assert.equals(9, #actions.colour_choices("draft", colored))
  end)

  it("lets a new colored tag take any number up to one past the last, defaulting to the end", function()
    local positions, default = actions.position_choices("draft", colored)
    assert.same({ "t1  (now: ecology)", "t2  (now: genetics)", "t3" }, vim.tbl_map(function(p) return p.label end, positions))
    assert.equals(3, default)
  end)

  it("lets an existing colored tag move among the existing numbers, defaulting to its own", function()
    local positions, default = actions.position_choices("genetics", colored)
    assert.equals(2, #positions)
    assert.equals("t2  (current)", positions[2].label)
    assert.equals(2, default)
  end)
end)

describe("tag_actions flows (fixture db, mocked connector)", function()
  local api = require("zotero.api")
  local db = require("zotero.db")
  local items = require("zotero.ui.items")
  local orig = {}
  local calls, notes

  before_each(function()
    fixture.setup()
    layout.create_layout()
    calls, notes = {}, {}
    orig.set, orig.del = api.set_tag_color, api.delete_tag
    orig.select, orig.confirm, orig.fetch = vim.ui.select, vim.fn.confirm, items.fetch_and_render
    orig.notify = require("zotero.async").notify
    api.set_tag_color = function(...)
      calls[#calls + 1] = { "set", ... }
      return require("zotero.async").run("mock", function() return true end)
    end
    api.delete_tag = function(name)
      calls[#calls + 1] = { "delete", name }
      return require("zotero.async").run("mock", function() return true end)
    end
    items.fetch_and_render = function() end
    require("zotero.async").notify = function(m) notes[#notes + 1] = m end
  end)

  after_each(function()
    api.set_tag_color, api.delete_tag = orig.set, orig.del
    vim.ui.select, vim.fn.confirm, items.fetch_and_render = orig.select, orig.confirm, orig.fetch
    require("zotero.async").notify = orig.notify
    layout.close()
    fixture.teardown()
  end)

  it("cc: picks a colour then a number key and sends both", function()
    local prompts = {}
    vim.ui.select = function(choices, opts, cb)
      prompts[#prompts + 1] = opts.prompt
      if #prompts == 1 then
        for _, c in ipairs(choices) do
          if c.hex == "#2EA8E5" then return cb(c) end -- Blue
        end
      else
        cb(choices[1]) -- the default (next free number) is listed first
      end
    end
    actions.assign_colour("draft")
    vim.wait(3000, function() return #calls == 1 end, 20)
    assert.same({ "set", "draft", "#2EA8E5", 3 }, calls[1])
    assert.equals(2, #prompts)
  end)

  it("cc: 'Remove colour' clears it", function()
    vim.ui.select = function(choices, _, cb) cb(choices[#choices]) end
    actions.assign_colour("ecology")
    vim.wait(3000, function() return #calls == 1 end, 20)
    assert.same({ "set", "ecology" }, calls[1]) -- colour and position nil
  end)

  it("cc: refuses a 10th colored tag", function()
    local orig_get = db.get_colored_tags
    local nine = {}
    for i = 1, 9 do nine[i] = { name = "t" .. i, color = "#FF6666" } end
    db.get_colored_tags = function() return require("zotero.async").run("mock", function() return nine end) end
    local asked = false
    vim.ui.select = function() asked = true end
    actions.assign_colour("draft")
    vim.wait(2000, function() return #notes > 0 end, 20)
    db.get_colored_tags = orig_get
    assert.is_false(asked)
    assert.same({}, calls)
    assert.matches("at most 9 colored tags", notes[1])
  end)

  it("dd: deletes after confirming, and drops the tag from the tag filter", function()
    local orig_set_filter, filter_set_to = items.set_tag_filter, nil
    local orig_get_filter = items.get_tag_filter
    items.get_tag_filter = function() return { "ecology", "genetics" } end
    items.set_tag_filter = function(f) filter_set_to = f end
    vim.fn.confirm = function() return 1 end
    actions.delete_tag("ecology")
    vim.wait(3000, function() return #calls == 1 end, 20)
    vim.wait(1000, function() return filter_set_to ~= nil end, 20)
    items.set_tag_filter, items.get_tag_filter = orig_set_filter, orig_get_filter
    assert.same({ "delete", "ecology" }, calls[1])
    assert.same({ "genetics" }, filter_set_to)
  end)

  it("dd on several tags: one confirmation, each deleted, one summary", function()
    local questions = {}
    vim.fn.confirm = function(q) questions[#questions + 1] = q return 1 end
    actions.delete_tags({ "ecology", "genetics" })
    vim.wait(3000, function() return #calls == 2 end, 20)
    vim.wait(1000, function()
      for _, n in ipairs(notes) do if n:match("deleted 2 tag") then return true end end
    end, 20)
    assert.equals(1, #questions)
    assert.matches("Delete these 2 tags.*ecology, genetics", questions[1])
    assert.same({ { "delete", "ecology" }, { "delete", "genetics" } }, calls)
    local summary = vim.tbl_filter(function(n) return n:match("deleted 2 tag%(s%): ecology, genetics") end, notes)
    assert.equals(1, #summary)
  end)

  it("dd: does nothing when not confirmed", function()
    vim.fn.confirm = function() return 2 end
    actions.delete_tag("ecology")
    vim.wait(300, function() return false end, 20)
    assert.same({}, calls)
  end)
end)

describe("cc / dd keys", function()
  local collections = require("zotero.ui.collections")
  local orig_colour, orig_delete, called

  before_each(function()
    fixture.setup()
    layout.create_layout()
    called = {}
    orig_colour, orig_delete = actions.assign_colour, actions.delete_tags
    actions.assign_colour = function(name) called[#called + 1] = { "colour", name } end
    actions.delete_tags = function(names) called[#called + 1] = { "delete", names } end
  end)

  after_each(function()
    actions.assign_colour, actions.delete_tags = orig_colour, orig_delete
    layout.close()
    fixture.teardown()
  end)

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  -- The buffer always holds every tag (the pane uses real folds, and it is
  -- reused between tests), so wait until the line is actually visible: this
  -- test's render has landed and opened the Tags fold.
  local function wait_visible(pattern)
    local ok = vim.wait(3000, function()
      local win = layout.get_collections_win()
      for i, l in ipairs(vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false)) do
        if l:match(pattern) then
          return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(i) end) == -1
        end
      end
      return false
    end, 20)
    assert(ok, pattern .. " never became visible")
  end

  it("in the collections Tags section, act on the tag under the cursor", function()
    collections.set_section_open("tags", true)
    collections.render()
    local buf = layout.get_collections_buf()
    wait_visible("ecology")
    layout.focus_collections()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:match("ecology") then vim.api.nvim_win_set_cursor(0, { i, 0 }) end
    end
    press("cc")
    press("dd")
    assert.same({ { "colour", "ecology" }, { "delete", { "ecology" } } }, called)
    collections.set_section_open("tags", false)
  end)

  it("in the Tags section, visual dd deletes all selected tags (and only tags)", function()
    collections.set_section_open("tags", true)
    collections.render()
    local buf = layout.get_collections_buf()
    wait_visible("genetics")
    layout.focus_collections()
    local header
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:match("Tags %(") then header = i end
    end
    -- From the header line down over both tags: the header isn't a tag.
    vim.api.nvim_win_set_cursor(0, { header, 0 })
    press("V2jdd")
    assert.same({ { "delete", { "ecology", "genetics" } } }, called)
    collections.set_section_open("tags", false)
  end)
end)
