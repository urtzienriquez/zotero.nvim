-- g? in each buffer jumps to a help tag; make sure every tag the code
-- references exists, and that pressing g? really lands there.
local fixture = require("tests.helpers.fixture")
local layout = require("zotero.ui.layout")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function help_tags_in_code()
  local tags = {}
  for _, file in ipairs(vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)) do
    for _, line in ipairs(vim.fn.readfile(file)) do
      local tag = line:match('vim%.cmd%.help%("([^"]+)"%)')
      if tag then
        tags[tag] = true
      end
      -- tags kept in tables (e.g. the <family>? help keys)
      for maps_tag in line:gmatch('"(zotero%-[%w%-]+%-maps)"') do
        tags[maps_tag] = true
      end
    end
  end
  return vim.tbl_keys(tags)
end

describe("g? help tags", function()
  it("every tag used with vim.cmd.help exists in doc/tags", function()
    local tags_file = table.concat(vim.fn.readfile(root .. "/doc/tags"), "\n")
    local used = help_tags_in_code()
    assert.is_true(#used >= 10)
    for _, tag in ipairs(used) do
      assert.is_truthy(("\n" .. tags_file):find("\n" .. tag .. "\t", 1, true), "missing help tag: " .. tag)
    end
  end)
end)

describe("g? in the browser buffers", function()
  before_each(function()
    fixture.setup()
    layout.create_layout()
  end)

  after_each(function()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "help" then
        vim.api.nvim_win_close(win, true)
      end
    end
    layout.close()
    fixture.teardown()
  end)

  local function press_g_help()
    vim.api.nvim_feedkeys("g?", "x", false)
    assert.equals("help", vim.bo.buftype)
    return vim.api.nvim_get_current_line()
  end

  it("items pane opens :help at the items keymaps", function()
    require("zotero.ui.items").set_keymaps()
    layout.focus_items()
    assert.matches("%*zotero%-items%-maps%*", press_g_help())
  end)

  it("collections pane opens :help at the collections keymaps", function()
    require("zotero.ui.collections").set_keymaps()
    layout.focus_collections()
    assert.matches("%*zotero%-collections%-maps%*", press_g_help())
  end)
end)
