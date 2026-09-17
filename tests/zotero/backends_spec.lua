local function fresh_config()
  package.loaded["zotero.config"] = nil
  return require("zotero.config")
end

local function fresh_backends()
  package.loaded["zotero.backends"] = nil
  return require("zotero.backends")
end

describe("backends.item_display", function()
  it("shows title only when there are no authors/year", function()
    local backends = fresh_backends()
    assert.equals("Some Title", backends.item_display({ title = "Some Title" }))
  end)

  it("includes authors and year when present", function()
    local backends = fresh_backends()
    local out = backends.item_display({ title = "T", _authors = "A. One", year = 2020 })
    assert.equals("T | A. One | 2020", out)
  end)

  it("falls back to '(no title)' when title is missing", function()
    local backends = fresh_backends()
    assert.equals("(no title)", backends.item_display({}))
  end)
end)

describe("backends.search_items dispatch", function()
  local orig_notify

  before_each(function()
    orig_notify = require("zotero.async").notify
  end)

  after_each(function()
    require("zotero.async").notify = orig_notify
    package.loaded["zotero.backends.fzf"] = nil
  end)

  it("falls back to vim.ui.input when no backend is configured, regardless of item count", function()
    local config = fresh_config()
    config.set({ backend = false })
    local backends = fresh_backends()

    local orig_input = vim.ui.input
    local captured_prompt
    vim.ui.input = function(opts, on_confirm)
      captured_prompt = opts.prompt
      on_confirm("typed query")
    end

    local got
    backends.search_items({}, function(q) got = q end) -- empty items list on purpose
    vim.ui.input = orig_input

    assert.equals("Search Zotero: ", captured_prompt)
    assert.equals("typed query", got)
  end)

  it("notifies and does not call the backend when items is empty and a backend IS configured", function()
    local config = fresh_config()
    config.set({ backend = "fzf" })
    local backends = fresh_backends()

    local notified
    require("zotero.async").notify = function(msg) notified = msg end

    local called = false
    package.loaded["zotero.backends.fzf"] = { search_items = function() called = true end }

    backends.search_items({}, function() end)

    assert.is_false(called)
    assert.matches("no items to search", notified)
  end)

  it("dispatches to the configured backend module when items are present", function()
    local config = fresh_config()
    config.set({ backend = "fzf" })
    local backends = fresh_backends()

    local received_items, received_on_done
    package.loaded["zotero.backends.fzf"] = {
      search_items = function(items, on_done)
        received_items = items
        received_on_done = on_done
      end,
    }

    local items = { { itemID = 1, title = "X" } }
    local on_done = function() end
    backends.search_items(items, on_done)

    assert.equals(items, received_items)
    assert.equals(on_done, received_on_done)
  end)

  it("notifies an error when the configured backend module can't be found", function()
    local config = fresh_config()
    config.set({ backend = "nonexistent_backend_xyz" })
    local backends = fresh_backends()

    local notified
    require("zotero.async").notify = function(msg) notified = msg end

    backends.search_items({ { itemID = 1 } }, function() end)
    assert.matches("not found", notified)
  end)
end)
