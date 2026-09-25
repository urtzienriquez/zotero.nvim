-- Default keymap style (two-key families, g = navigation, <family>? help)
-- and backwards compatibility with the old <leader>z... layout.
local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")
local items = require("zotero.ui.items")
local collections = require("zotero.ui.collections")

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function items_text()
  return table.concat(vim.api.nvim_buf_get_lines(layout.get_items_buf(), 0, -1, false), "\n")
end

-- Panes keep their buffers (and their keymaps) across close/open; wipe them
-- so set_keymaps() runs again under the current config.
local function fresh_layout()
  for _, buf in ipairs({ layout.get_items_buf(), layout.get_collections_buf() }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  layout.create_layout()
  layout.set_keymaps()
  items.set_keymaps()
  collections.set_keymaps()
  collections.render()
  items.load_items(nil)
  vim.wait(3000, function() return items_text():match("Origin") ~= nil end, 20)
  vim.wait(3000, function()
    return #vim.api.nvim_buf_get_lines(layout.get_collections_buf(), 0, -1, false) > 3
  end, 20)
end

describe("keymaps (real buffers, fixture db)", function()
  before_each(function()
    vim.o.columns = 200
    vim.o.lines = 50
    fixture.setup() -- resets config to defaults (plus db_path)
    fresh_layout()
  end)

  after_each(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "help" then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.wait(200, function() return false end, 20)
    layout.close()
    fixture.teardown()
  end)

  describe("plain Vim motions", function()
    local function mapped(buf, lhs)
      return vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true).buffer == 1
      end)
    end

    it("leaves <Tab>, <Esc>, j, k, gg and G to Vim in both panes", function()
      for _, buf in ipairs({ layout.get_items_buf(), layout.get_collections_buf() }) do
        for _, lhs in ipairs({ "<Tab>", "<Esc>", "j", "k", "<Down>", "<Up>", "gg", "G" }) do
          assert.is_false(mapped(buf, lhs), lhs .. " is still mapped")
        end
      end
    end)

    it("keeps the cursor off the header rows of the items table", function()
      layout.focus_items()
      local win, buf = layout.get_items_win(), layout.get_items_buf()
      -- Keys fed with "x" skip the idle step where Neovim fires CursorMoved,
      -- so fire it the way typing would.
      local function motion(keys)
        press(keys)
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
        return vim.api.nvim_win_get_cursor(win)[1]
      end
      assert.equals(vim.api.nvim_buf_line_count(buf), motion("G"))
      assert.equals(3, motion("gg")) -- first item, below header + separator
      assert.equals(3, motion("k"))
      assert.equals(5, motion("2j"))
    end)
  end)

  describe("g navigation", function()
    it("gd goes to Trash and gl back to My Library, from the items pane", function()
      layout.focus_items()
      press("gd")
      vim.wait(3000, function() return items_text():match("Old Draft") ~= nil end, 20)
      assert.matches("Old Draft", items_text())

      press("gl")
      vim.wait(3000, function() return items_text():match("Origin") ~= nil end, 20)
      assert.does_not.match("Old Draft", items_text())
    end)

    it("gd / gm from the collections pane load the view and focus the items pane", function()
      layout.focus_collections()
      press("gd")
      vim.wait(3000, function() return items_text():match("Old Draft") ~= nil end, 20)
      assert.equals(layout.get_items_win(), vim.api.nvim_get_current_win())

      layout.focus_collections()
      press("gm")
      vim.wait(3000, function() return items_text():match("Old Draft") == nil end, 20)
      assert.matches("marked only", vim.wo[layout.get_items_win()].winbar)
    end)

    it("gf puts the cursor on the Feeds header (opening it), from either pane", function()
      require("zotero.ui.collections").set_section_open("feeds", false)
      layout.focus_items()
      press("gf")
      assert.equals(layout.get_collections_win(), vim.api.nvim_get_current_win())
      assert.matches("^▼ Feeds", vim.api.nvim_get_current_line())

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      press("gf")
      assert.matches("^▼ Feeds", vim.api.nvim_get_current_line())
    end)
  end)

  it("s? opens :help at the sort keymaps", function()
    layout.focus_items()
    press("s?")
    assert.equals("help", vim.bo.buftype)
    assert.matches("%*zotero%-items%-sort%-maps%*", vim.api.nvim_get_current_line())
  end)

  it("the old <leader>z keymaps still work when configured", function()
    require("zotero.config").set({
      db_path = fixture.db_path,
      keymaps = { items_toggle_mark = "<leader>zm", items_show_only_marked = "<leader>zl" },
    })
    layout.close()
    fresh_layout()
    layout.focus_items()
    vim.api.nvim_win_set_cursor(layout.get_items_win(), { 3, 0 })

    press("<leader>zm")
    vim.wait(1000, function() return items.get_marked_count() == 1 end, 10)
    assert.equals(1, items.get_marked_count())
    press("<leader>zm")
    vim.wait(1000, function() return items.get_marked_count() == 0 end, 10)

    -- the replaced defaults are gone
    assert.equals("", vim.fn.maparg("mm", "n"))
    assert.is_true(vim.fn.maparg("<leader>zl", "n") ~= "")
  end)
end)
