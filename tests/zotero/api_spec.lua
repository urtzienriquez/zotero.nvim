-- Mocks async_mod.http/sys since real calls go to a live Zotero connector.
local fixture = require("tests.helpers.fixture")
local async_mod = require("zotero.async")
local db = require("zotero.db")
local api = require("zotero.api")

local function run(task)
  return fixture.wait_for(task)
end

local function url_of(args)
  for _, a in ipairs(args) do
    if type(a) == "string" and a:match("^https?://") then
      return a
    end
  end
end

describe("api (mocked connector)", function()
  local orig_http, orig_sys, orig_invalidate

  before_each(function()
    orig_http = async_mod.http
    orig_sys = async_mod.sys
    orig_invalidate = db.invalidate_cache
    db.invalidate_cache = function() end -- avoid touching the real db module state here
  end)

  after_each(function()
    async_mod.http = orig_http
    async_mod.sys = orig_sys
    db.invalidate_cache = orig_invalidate
  end)

  describe("M.ping_async", function()
    it("returns true for HTTP 200", function()
      async_mod.http = function() return { code = 0, http_code = 200, body = "" } end
      assert.is_true(run(api.ping_async()))
    end)

    it("returns false when Zotero is unreachable", function()
      async_mod.http = function() return { code = 7, http_code = 0, body = "", stderr = "connection refused" } end
      assert.is_false(run(api.ping_async()))
    end)
  end)

  describe("M.set_feed_items_read", function()
    it("posts the feed library, keys and read flag", function()
      local captured, url
      async_mod.http = function(args)
        url = url_of(args)
        for i, a in ipairs(args) do
          if a == "-d" then captured = vim.json.decode(args[i + 1]) end
        end
        return { code = 0, http_code = 200, body = vim.json.encode({ success = true, updated = 1 }) }
      end
      assert.is_true(run(api.set_feed_items_read(2, { "FEED0010" }, true)))
      assert.matches("/connector/setFeedItemsRead$", url)
      assert.same({ libraryID = 2, itemKeys = { "FEED0010" }, read = true }, captured)
    end)

    it("when quiet, reports only the first failure of the session", function()
      async_mod.http = function()
        return { code = 0, http_code = 500, body = vim.json.encode({ error = "'itemData' not loaded" }) }
      end
      local orig_notify, msgs = async_mod.notify, {}
      async_mod.notify = function(m) msgs[#msgs + 1] = m end
      local ok1 = run(api.set_feed_items_read(2, { "X" }, true, { quiet = true }))
      local ok2 = run(api.set_feed_items_read(2, { "Y" }, true, { quiet = true }))
      async_mod.notify = orig_notify
      assert.is_false(ok1)
      assert.is_false(ok2)
      assert.equals(1, #msgs)
      assert.matches("itemData", msgs[1])
    end)
  end)

  describe("feed management", function()
    local captured_body, captured_url
    before_each(function()
      captured_body, captured_url = nil, nil
    end)

    local function mock_http(response)
      async_mod.http = function(args)
        captured_url = url_of(args)
        for i, a in ipairs(args) do
          if a == "--data-binary" then
            local path = args[i + 1]:sub(2)
            local fd = io.open(path, "rb")
            captured_body = vim.json.decode(fd:read("*a"))
            fd:close()
          end
        end
        return response
      end
    end

    local function ok(body)
      body.success = true
      return { code = 0, http_code = 200, body = vim.json.encode(body) }
    end

    it("add_feed posts url and optional name and returns the new feed", function()
      mock_http(ok({ libraryID = 7, name = "My Feed" }))
      local res = run(api.add_feed("https://example.org/rss", "My Feed"))
      assert.matches("/connector/addFeed$", captured_url)
      assert.same({ url = "https://example.org/rss", name = "My Feed" }, captured_body)
      assert.equals(7, res.libraryID)
    end)

    it("add_feed reports the endpoint's error and returns nil", function()
      mock_http({ code = 0, http_code = 409, body = vim.json.encode({ error = "Already subscribed to this feed" }) })
      local msgs = {}
      local orig_notify = async_mod.notify
      async_mod.notify = function(m) msgs[#msgs + 1] = m end
      local res = run(api.add_feed("https://example.org/rss"))
      async_mod.notify = orig_notify
      assert.is_nil(res)
      assert.matches("Already subscribed", msgs[1])
    end)

    it("tells the user to update the companion plugin when the endpoint is missing", function()
      mock_http({ code = 0, http_code = 404, body = "No endpoint found" })
      local msgs = {}
      local orig_notify = async_mod.notify
      async_mod.notify = function(m) msgs[#msgs + 1] = m end
      run(api.refresh_feeds(nil))
      async_mod.notify = orig_notify
      assert.matches("companion plugin to 1%.2%.1", msgs[1])
    end)

    it("delete_feed and refresh_feeds send the feed's libraryID", function()
      mock_http(ok({ name = "X" }))
      assert.is_true(run(api.delete_feed(2)))
      assert.matches("/connector/deleteFeed$", captured_url)
      assert.same({ libraryID = 2 }, captured_body)

      mock_http(ok({ refreshed = 1, errors = {} }))
      assert.is_true(run(api.refresh_feeds(2)))
      assert.matches("/connector/refreshFeeds$", captured_url)
      assert.same({ libraryID = 2 }, captured_body)
    end)

    it("import_opml sends the file's contents and returns the number added", function()
      local path = vim.fn.tempname() .. ".opml"
      local opml = '<?xml version="1.0"?><opml><body><outline type="rss" xmlUrl="https://e.org/a"/></body></opml>'
      vim.fn.writefile({ opml }, path)
      mock_http(ok({ added = 1 }))
      assert.equals(1, run(api.import_opml(path)))
      assert.matches("/connector/importOPML$", captured_url)
      assert.equals(opml .. "\n", captured_body.opml)
      vim.fn.delete(path)
    end)
  end)

  describe("M.update_item", function()
    it("returns true on a successful connector response", function()
      async_mod.http = function()
        return { code = 0, http_code = 200, body = vim.json.encode({ success = true }) }
      end
      assert.is_true(run(api.update_item("KEY1", { fields = { title = "New" } })))
    end)

    it("sends the item key and updates in the JSON payload", function()
      local captured
      async_mod.http = function(args)
        for i, a in ipairs(args) do
          if a == "-d" then captured = args[i + 1] end
        end
        return { code = 0, http_code = 200, body = vim.json.encode({ success = true }) }
      end
      run(api.update_item("KEY1", { fields = { title = "New" } }))
      local payload = vim.json.decode(captured)
      assert.equals("KEY1", payload.itemKey)
      assert.equals("New", payload.updates.fields.title)
    end)

    it("returns false on a curl transport failure", function()
      async_mod.http = function() return { code = 7, http_code = 0, body = "", stderr = "connection refused" } end
      assert.is_false(run(api.update_item("KEY1", {})))
    end)

    it("returns false on a non-200 HTTP response", function()
      async_mod.http = function() return { code = 0, http_code = 500, body = "server error" } end
      assert.is_false(run(api.update_item("KEY1", {})))
    end)

    it("returns false when the response body doesn't indicate success", function()
      async_mod.http = function() return { code = 0, http_code = 200, body = vim.json.encode({ success = false }) } end
      assert.is_false(run(api.update_item("KEY1", {})))
    end)
  end)

  describe("M.set_date_added / M.set_date_modified", function()
    it("reject missing arguments without making a request", function()
      local called = false
      async_mod.http = function() called = true; return { code = 0, http_code = 200, body = "" } end
      assert.is_false(run(api.set_date_added(nil, "2020-01-01")))
      assert.is_false(run(api.set_date_modified("KEY1", nil)))
      assert.is_false(called)
    end)

    it("delegate to update_item with the right field name", function()
      local captured
      async_mod.http = function(args)
        for i, a in ipairs(args) do
          if a == "-d" then captured = args[i + 1] end
        end
        return { code = 0, http_code = 200, body = vim.json.encode({ success = true }) }
      end
      run(api.set_date_added("KEY1", "2020-01-01"))
      assert.equals("2020-01-01", vim.json.decode(captured).updates.dateAdded)
    end)
  end)

  describe("M.delete_item", function()
    it("rejects an empty item key without making a request", function()
      local called = false
      async_mod.http = function() called = true; return { code = 0, http_code = 200 } end
      assert.is_false(run(api.delete_item("")))
      assert.is_false(called)
    end)

    it("returns true on success", function()
      async_mod.http = function() return { code = 0, http_code = 200, body = "" } end
      assert.is_true(run(api.delete_item("KEY1")))
    end)

    it("returns false and surfaces the connector's error message on failure", function()
      async_mod.http = function()
        return { code = 0, http_code = 400, body = vim.json.encode({ error = "Item does not exist" }) }
      end
      assert.is_false(run(api.delete_item("KEY1")))
    end)
  end)

  describe("M.import_pdf", function()
    local tmp_pdf

    before_each(function()
      tmp_pdf = vim.fn.tempname() .. ".pdf"
      vim.fn.writefile({ "%PDF-1.4 fake" }, tmp_pdf)
    end)

    after_each(function()
      vim.fn.delete(tmp_pdf)
    end)

    it("fails fast for a nonexistent file without any HTTP call", function()
      local called = false
      async_mod.http = function() called = true; return { code = 0, http_code = 200 } end
      assert.is_false(run(api.import_pdf("/no/such/file.pdf")))
      assert.is_false(called)
    end)

    it("succeeds when Zotero recognizes metadata (no itemKey to poll for)", function()
      async_mod.http = function()
        return { code = 0, http_code = 200, body = vim.json.encode({ canRecognize = true }) }
      end
      assert.is_true(run(api.import_pdf(tmp_pdf)))
    end)

    it("polls the db for the new item and checks duplicates when itemKey is returned", function()
      async_mod.http = function()
        return { code = 0, http_code = 200, body = vim.json.encode({ canRecognize = true, itemKey = "NEWKEY1" }) }
      end
      -- "no parent, no DOI" short-circuits check_duplicates_after_import early.
      local stub = function(v)
        return function() return async_mod.run("stub", function() return v end) end
      end
      local origs = {
        get_item_by_key = db.get_item_by_key,
        get_parent_item_by_attachment_key = db.get_parent_item_by_attachment_key,
        get_item_field_value = db.get_item_field_value,
      }
      db.get_item_by_key = stub({ itemID = 1, key = "NEWKEY1" })
      db.get_parent_item_by_attachment_key = stub(nil)
      db.get_item_field_value = stub(nil)

      assert.is_true(run(api.import_pdf(tmp_pdf)))

      for name, fn in pairs(origs) do db[name] = fn end
    end)

    it("reports failure on a curl transport error, without falling back", function()
      async_mod.http = function() return { code = 7, http_code = 0, body = "", stderr = "refused" } end
      assert.is_false(run(api.import_pdf(tmp_pdf)))
    end)

    it("falls back to try_save_items (document-only) when the connector returns no usable metadata", function()
      local saveitems_payload
      async_mod.http = function(args)
        local url = url_of(args)
        if url:match("importFile") then
          return { code = 0, http_code = 500, body = "" } -- forces the fallback branch
        end
        for i, a in ipairs(args) do
          if a == "-d" then saveitems_payload = args[i + 1] end
        end
        return { code = 0, http_code = 200, body = "" }
      end
      assert.is_true(run(api.import_pdf(tmp_pdf, "COLLKEY1")))
      local payload = vim.json.decode(saveitems_payload)
      assert.equals(32, #payload.sessionID)
      assert.matches("^[a-z0-9]+$", payload.sessionID) -- rand_str's charset
      assert.same({ "COLLKEY1" }, payload.items[1].collections)
      assert.equals("document", payload.items[1].itemType)
    end)

    it("retries the fallback save with a new session id on SESSION_EXISTS", function()
      local attempt = 0
      local session_ids = {}
      async_mod.http = function(args)
        local url = url_of(args)
        if url:match("importFile") then
          return { code = 0, http_code = 500, body = "" }
        end
        attempt = attempt + 1
        local d
        for i, a in ipairs(args) do
          if a == "-d" then d = args[i + 1] end
        end
        session_ids[#session_ids + 1] = vim.json.decode(d).sessionID
        if attempt == 1 then
          return { code = 0, http_code = 200, body = vim.json.encode({ error = "SESSION_EXISTS" }) }
        end
        return { code = 0, http_code = 200, body = "" }
      end
      assert.is_true(run(api.import_pdf(tmp_pdf)))
      assert.equals(2, attempt)
      assert.is_not.equal(session_ids[1], session_ids[2])
    end)

    it("fails the fallback save when every attempt errors", function()
      async_mod.http = function(args)
        local url = url_of(args)
        if url:match("importFile") then
          return { code = 0, http_code = 500, body = "" }
        end
        return { code = 0, http_code = 400, body = vim.json.encode({ error = "Some other failure" }) }
      end
      assert.is_false(run(api.import_pdf(tmp_pdf)))
    end)
  end)
end)

describe("api.extract_doi", function()
  it("accepts a bare DOI", function()
    assert.equals("10.1111/gcb.15266", api.extract_doi("10.1111/gcb.15266"))
  end)

  it("extracts the DOI from doi.org and /doi/ URLs", function()
    assert.equals("10.1111/gcb.15266", api.extract_doi("https://doi.org/10.1111/gcb.15266"))
    assert.equals("10.1111/gcb.15266", api.extract_doi("https://onlinelibrary.wiley.com/doi/10.1111/gcb.15266"))
  end)

  it("handles publisher view segments, query strings and percent-encoding", function()
    assert.equals(
      "10.1111/gcb.15266",
      api.extract_doi(
        "https://onlinelibrary.wiley.com/doi/full/10.1111/gcb.15266?casa_token=gldBBaULxp4AAAAA%3AHFIn-iHzgLTUPP"
      )
    )
    assert.equals("10.1111/gcb.15266", api.extract_doi("https://onlinelibrary.wiley.com/doi/epdf/10.1111/gcb.15266#x"))
    assert.equals("10.3389/fpls.2020.00001", api.extract_doi("https://www.frontiersin.org/articles/10.3389/fpls.2020.00001/full"))
    assert.equals("10.1000/a(b)", api.extract_doi("https://doi.org/10.1000/a%28b%29"))
  end)

  it("returns nil when there is no DOI", function()
    assert.is_nil(api.extract_doi("https://example.com/article/123"))
    assert.is_nil(api.extract_doi("978-3-16-148410-0"))
    assert.is_nil(api.extract_doi(nil))
  end)
end)

describe("api.fetch_metadata", function()
  local orig_http

  before_each(function() orig_http = async_mod.http end)
  after_each(function() async_mod.http = orig_http end)

  it("looks up the clean DOI on CrossRef for a Wiley URL with a query string", function()
    local requested
    async_mod.http = function(args)
      requested = url_of(args)
      return {
        code = 0,
        http_code = 200,
        body = vim.json.encode({ status = "ok", message = { DOI = "10.1111/gcb.15266", title = { "T" } } }),
      }
    end
    local meta = run(api.fetch_metadata(
      "https://onlinelibrary.wiley.com/doi/full/10.1111/gcb.15266?casa_token=gldBBaULxp4AAAAA%3AHFIn"
    ))
    assert.is_truthy(requested:find("api.crossref.org/works/10.1111", 1, true))
    assert.is_nil(requested:find("casa_token", 1, true))
    assert.equals("T", meta.fields.title)
  end)
end)
