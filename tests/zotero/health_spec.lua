-- :checkhealth zotero, with Zotero's HTTP answers simulated.
local fixture = require("tests.helpers.fixture")
local health = require("zotero.health")

describe("health", function()
  local report, orig = nil, {}

  before_each(function()
    fixture.setup()
    report = {}
    for _, kind in ipairs({ "start", "ok", "warn", "error", "info" }) do
      orig[kind] = vim.health[kind]
      vim.health[kind] = function(msg, advice)
        report[#report + 1] = { kind = kind, msg = msg, advice = advice and table.concat(
          type(advice) == "table" and advice or { advice }, " ") or "" }
      end
    end
    orig.http = health.http_status
  end)

  after_each(function()
    for kind, fn in pairs(orig) do
      if kind == "http" then health.http_status = fn else vim.health[kind] = fn end
    end
    fixture.teardown()
  end)

  -- `answers` maps a path prefix to the HTTP status Zotero returns; nil
  -- (the default) means Zotero couldn't be reached.
  local function run(answers)
    health.http_status = function(path)
      if not answers then return nil end
      local best, status = -1, 404 -- the longest matching prefix wins
      for prefix, s in pairs(answers) do
        if path:sub(1, #prefix) == prefix and #prefix > best then best, status = #prefix, s end
      end
      return status
    end
    health.check()
  end

  local function find(kind, pattern)
    for _, r in ipairs(report) do
      if r.kind == kind and (r.msg .. " " .. r.advice):match(pattern) then return r end
    end
  end

  local function sections()
    local out = {}
    for _, r in ipairs(report) do
      if r.kind == "start" then out[#out + 1] = r.msg end
    end
    return out
  end

  it("reports the database, and says browsing works when Zotero isn't running", function()
    run(nil)
    assert.is_not_nil(find("ok", "Database: " .. vim.pesc(fixture.db_path)))
    local w = find("warn", "Zotero isn't running")
    assert.is_not_nil(w)
    assert.matches("ignore this if you only browse", w.msg)
    assert.matches("editing items", w.advice)
    -- Without Zotero, the add-on and Better BibTeX can't be checked at all.
    assert.same({ "Neovim", "External tools", "Zotero database", "Zotero application" }, sections())
  end)

  it("with Zotero running, finds an up-to-date add-on and Better BibTeX", function()
    run({ ["/connector/"] = 400, ["/connector/ping"] = 200, ["/better-bibtex/"] = 200 })
    assert.is_not_nil(find("ok", "Zotero is running"))
    assert.is_not_nil(find("ok", "Installed, version 1%.5%.0 or later"))
    assert.is_not_nil(find("ok", "Better BibTeX is installed"))
  end)

  it("names what an outdated add-on can't do yet", function()
    run({ ["/connector/ping"] = 200, ["/connector/toggleTag"] = 400, ["/connector/setFeedItemsRead"] = 400,
      ["/connector/updateItem"] = 400 })
    local w = find("warn", "outdated")
    assert.is_not_nil(w)
    assert.matches("version 1%.3%.0", w.msg)
    assert.matches("removing items from a collection", w.msg)
    assert.matches("colouring and deleting tags", w.msg)
    assert.does_not.match("toggling tags", w.msg)
  end)

  it("warns when the add-on or Better BibTeX is missing", function()
    run({ ["/connector/ping"] = 200 })
    assert.is_not_nil(find("warn", "Not installed"))
    assert.is_not_nil(find("warn", "Better BibTeX not found"))
  end)

  it("errors when the database can't be read", function()
    require("zotero.config").options.db_path = "/no/such/zotero.sqlite"
    run(nil)
    assert.is_not_nil(find("error", "isn't readable"))
  end)
end)
