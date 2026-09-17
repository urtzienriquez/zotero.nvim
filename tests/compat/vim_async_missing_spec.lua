-- Runs on Neovim builds without vim.async (e.g. current stable). The rest of
-- the suite requires vim.async and only runs on nightly.
if vim.async then
  describe("zotero.async on a Neovim build without vim.async", function()
    it("skipped: this Neovim build has vim.async", function() end)
  end)
  return
end

describe("zotero.async on a Neovim build without vim.async", function()
  it("raises the documented error instead of crashing on first use", function()
    local async_mod = require("zotero.async")
    local ok, err = pcall(function() return async_mod.run end)
    assert.is_false(ok)
    assert.matches("requires a Neovim build with vim.async", err)
  end)
end)

describe("zotero.config on a Neovim build without vim.async", function()
  it("still loads and returns usable defaults", function()
    package.loaded["zotero.config"] = nil
    local config = require("zotero.config")
    config.set({})
    assert.equals(500, config.get().max_items)
  end)
end)
