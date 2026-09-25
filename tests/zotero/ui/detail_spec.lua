local fixture = require("tests.helpers.fixture")
local detail = require("zotero.ui.detail")

local function backdrop_count()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[w].winhl:find("ZoteroDetailBackdrop", 1, true) then
      n = n + 1
    end
  end
  return n
end

describe("detail.wrap_text", function()
  it("wraps long text at word boundaries within width+10 of the target", function()
    local lines = detail.wrap_text("the quick brown fox jumps over the lazy dog and then some more words after that", 20)
    assert.is_true(#lines > 1)
    for _, line in ipairs(lines) do
      assert.is_true(#line <= 30, "line too long: " .. line) -- width + 10 slack
    end
  end)

  it("returns a single-element array with an empty string for empty input", function()
    assert.same({ "" }, detail.wrap_text("", 20))
  end)

  it("returns the text unchanged (one line) when it fits", function()
    assert.same({ "short" }, detail.wrap_text("short", 20))
  end)

  it("matches a reference O(n^2) implementation across many random (text, width) pairs", function()
    -- The original O(n^2) implementation, kept only to compare against.
    local function reference_wrap(text, width)
      if not text or text == "" then return { "" } end
      local result = {}
      while #text > width do
        local break_at = text:find(" ", width - 10)
        if not break_at or break_at > width + 10 then
          break_at = width
        end
        result[#result + 1] = text:sub(1, break_at - 1)
        text = text:sub(break_at + 1)
        if text == "" then break end
      end
      if text ~= "" then result[#result + 1] = text end
      if #result == 0 then return { "" } end
      return result
    end

    math.randomseed(12345)
    local words = { "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
      "a", "of", "in", "and", "abstract", "study", "results", "significant",
      "supercalifragilisticexpialidocious", "x" }
    local function random_text(n)
      local t = {}
      for _ = 1, n do t[#t + 1] = words[math.random(#words)] end
      return table.concat(t, " ")
    end

    for _ = 1, 500 do
      local text = random_text(math.random(0, 30))
      local width = math.random(10, 80) -- >=10: see known divergence below width 10 documented at the call sites
      assert.same(reference_wrap(text, width), detail.wrap_text(text, width),
        ("mismatch for text=%q width=%d"):format(text, width))
    end
  end)
end)

describe("detail.show_item / close / is_open (real headless buffers/windows)", function()
  before_each(function() fixture.setup() end)
  after_each(function()
    detail.close()
    fixture.teardown()
  end)

  it("opens a floating window showing the item's title", function()
    detail.show_item(2)
    vim.wait(2000, function() return detail.is_open() end, 20)
    assert.is_true(detail.is_open())
  end)

  it("close() closes the window and is_open() reflects it", function()
    detail.show_item(2)
    vim.wait(2000, function() return detail.is_open() end, 20)
    assert.is_true(detail.is_open())
    assert.equals(1, backdrop_count())
    detail.close()
    assert.is_false(detail.is_open())
    assert.equals(0, backdrop_count())
  end)

  local function float_with(zindex)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" and cfg.zindex == zindex then return w, cfg end
    end
  end

  it("closes, with its backdrop, when focus leaves it", function()
    local origin = vim.api.nvim_get_current_win()
    detail.show_item(2)
    vim.wait(2000, function() return detail.is_open() end, 20)
    vim.api.nvim_set_current_win(origin)
    vim.wait(1000, function() return not detail.is_open() end, 20)
    assert.is_false(detail.is_open())
    assert.equals(0, backdrop_count())
  end)

  it("is as tall as its text once wrapped", function()
    local columns, lines_before = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 60, 50 -- narrow, so text wraps; tall, so it all fits
    detail.show_item(2)
    vim.wait(2000, function() return detail.is_open() end, 20)
    local win = float_with(50)
    local lines = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    local wrapped = vim.api.nvim_win_text_height(win, {}).all
    assert.is_true(wrapped > lines) -- something did wrap
    assert.equals(wrapped, vim.api.nvim_win_get_height(win))
    detail.close()
    vim.o.columns, vim.o.lines = columns, lines_before
  end)

  it("stays centered and the backdrop covers the screen after a resize", function()
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 200, 50
    detail.show_item(2)
    vim.wait(2000, function() return detail.is_open() end, 20)
    vim.o.columns, vim.o.lines = 90, 30
    vim.api.nvim_exec_autocmds("VimResized", {})
    local win, cfg = float_with(50)
    local w, h = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    local rows = vim.o.lines - vim.o.cmdheight
    assert.is_true(w <= 90 - 4 and h <= rows - 4)
    assert.equals(math.floor((90 - w) / 2), cfg.col)
    assert.equals(math.floor((rows - h) / 2), cfg.row)
    local bd = float_with(49)
    assert.equals(90, vim.api.nvim_win_get_width(bd))
    assert.equals(rows, vim.api.nvim_win_get_height(bd)) -- not over the command line
    detail.close()
    vim.o.columns, vim.o.lines = columns, lines
  end)

  it("a second show_item() call for the same item supersedes the first (no leaked window)", function()
    detail.show_item(2)
    detail.show_item(2) -- rapid double-call, same item_id
    vim.wait(2000, function() return detail.is_open() end, 20)
    assert.is_true(detail.is_open())
    -- Exactly one floating window should exist for the detail panel.
    local float_wins = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" and cfg.zindex == 50 then
        float_wins = float_wins + 1
      end
    end
    assert.equals(1, float_wins)
  end)
end)
