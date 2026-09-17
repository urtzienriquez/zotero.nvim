-- Reloads config.lua to reset its module-level state between tests.
local function fresh_config()
  package.loaded["zotero.config"] = nil
  return require("zotero.config")
end

describe("config.set / config.get", function()
  it("merges user options over the defaults", function()
    local config = fresh_config()
    config.set({ max_items = 42 })
    local opts = config.get()
    assert.equals(42, opts.max_items)
    assert.equals("fzf", opts.backend) -- untouched default survives
  end)

  it("deep-merges nested tables (keymaps) instead of replacing them", function()
    local config = fresh_config()
    config.set({ keymaps = { items_search = "<leader>Q" } })
    local opts = config.get()
    assert.equals("<leader>Q", opts.keymaps.items_search)
    assert.equals("<leader>zz", opts.keymaps.open_library) -- other keymap default survives
  end)

  it("keeps an explicit db_path even if it doesn't exist on disk", function()
    local config = fresh_config()
    config.set({ db_path = "/nonexistent/path/zotero.sqlite" })
    assert.equals("/nonexistent/path/zotero.sqlite", config.get().db_path)
  end)

  it("does not mutate M.defaults across repeated set() calls", function()
    local config = fresh_config()
    config.set({ max_items = 999 })
    config.set({}) -- fresh set with no override
    assert.equals(500, config.get().max_items)
  end)
end)

describe("config auto-detection", function()
  local orig_home

  before_each(function()
    orig_home = vim.env.HOME
  end)

  after_each(function()
    vim.env.HOME = orig_home
  end)

  it("finds a readable zotero.sqlite under a candidate path", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/Zotero", "p")
    local fixture_db = tmp .. "/Zotero/zotero.sqlite"
    vim.fn.writefile({ "" }, fixture_db)

    vim.env.HOME = tmp
    local config = fresh_config()
    config.set({})
    assert.equals(fixture_db, config.get().db_path)

    vim.fn.delete(tmp, "rf")
  end)

  it("leaves db_path nil when nothing is found and none was given", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.env.HOME = tmp

    local config = fresh_config()
    config.set({})
    assert.is_nil(config.get().db_path)

    vim.fn.delete(tmp, "rf")
  end)

  it("M.get() auto-initializes with defaults when setup() was never called", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.env.HOME = tmp

    local config = fresh_config()
    -- No config.set() call at all.
    local opts = config.get()
    assert.equals(500, opts.max_items)
    assert.equals("fzf", opts.backend)

    vim.fn.delete(tmp, "rf")
  end)
end)
