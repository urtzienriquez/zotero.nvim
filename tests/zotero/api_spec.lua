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
