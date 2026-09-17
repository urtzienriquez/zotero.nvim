-- Mocks async_mod.http instead of hitting the real CrossRef API.
local fixture = require("tests.helpers.fixture")
local async_mod = require("zotero.async")
local crossref = require("zotero.crossref")

local function mock_http(fn)
  async_mod.http = fn
end

local function fetch(doi)
  return fixture.run_sync(function()
    return async_mod.await(crossref.fetch_metadata(doi))
  end)
end

describe("crossref.fetch_metadata", function()
  local orig_http

  before_each(function() orig_http = async_mod.http end)
  after_each(function() async_mod.http = orig_http end)

  it("returns an error for a nil/empty DOI without making any request", function()
    local called = false
    mock_http(function() called = true; return { code = 0, http_code = 200, body = "{}" } end)
    local meta, err = fetch(nil)
    assert.is_nil(meta)
    assert.equals("no DOI provided", err)
    assert.is_false(called)
  end)

  it("percent-encodes the DOI in the request URL but keeps '/' unescaped", function()
    local captured_url
    mock_http(function(args)
      captured_url = args[2]
      return { code = 0, http_code = 200, body = vim.json.encode({ status = "ok", message = { title = { "T" } } }) }
    end)
    fetch("10.1000/some path#frag")
    assert.matches("^https://api%.crossref%.org/works/10%.1000/some%%20path%%23frag", captured_url)
  end)

  it("parses title, authors, journal, and maps the CrossRef type", function()
    mock_http(function()
      return {
        code = 0,
        http_code = 200,
        body = vim.json.encode({
          status = "ok",
          message = {
            title = { "A Great Paper" },
            author = { { given = "Jane", family = "Smith" }, { given = "", family = "Doe" } },
            ["container-title"] = { "Journal of Things" },
            type = "journal-article",
            volume = "12",
            issue = "3",
            page = "1-10",
            publisher = "Acme",
            DOI = "10.1000/xyz",
            URL = "https://example.com",
          },
        }),
      }
    end)
    local meta, err = fetch("10.1000/xyz")
    assert.is_nil(err)
    assert.equals("journalArticle", meta.itemType)
    assert.equals("A Great Paper", meta.fields.title)
    assert.equals("Journal of Things", meta.fields.publicationTitle)
    assert.equals("12", meta.fields.volume)
    assert.equals(2, #meta.creators)
    assert.equals("Jane", meta.creators[1].firstName)
    assert.equals("Smith", meta.creators[1].lastName)
    assert.equals("author", meta.creators[1].creatorType)
  end)

  it("falls back through published-print -> published-online -> issued for the date", function()
    mock_http(function()
      return {
        code = 0, http_code = 200,
        body = vim.json.encode({
          status = "ok",
          message = { title = { "T" }, ["published-online"] = { ["date-parts"] = { { 2019, 5 } } } },
        }),
      }
    end)
    local meta = fetch("10.1/x")
    assert.equals("2019-05", meta.fields.date)
  end)

  it("formats a full year-month-day date", function()
    mock_http(function()
      return {
        code = 0, http_code = 200,
        body = vim.json.encode({
          status = "ok",
          message = { title = { "T" }, issued = { ["date-parts"] = { { 2019, 5, 20 } } } },
        }),
      }
    end)
    local meta = fetch("10.1/x")
    assert.equals("2019-05-20", meta.fields.date)
  end)

  it("maps unknown CrossRef types to journalArticle by default", function()
    mock_http(function()
      return {
        code = 0, http_code = 200,
        body = vim.json.encode({ status = "ok", message = { title = { "T" }, type = "some-unknown-type" } }),
      }
    end)
    local meta = fetch("10.1/x")
    assert.equals("journalArticle", meta.itemType)
  end)

  it("strips empty-string fields instead of including them", function()
    mock_http(function()
      return {
        code = 0, http_code = 200,
        body = vim.json.encode({ status = "ok", message = { title = { "T" } } }),
      }
    end)
    local meta = fetch("10.1/x")
    assert.is_nil(meta.fields.publicationTitle)
    assert.is_nil(meta.fields.volume)
    assert.equals("T", meta.fields.title)
  end)

  it("uses the queried DOI as the DOI field when CrossRef doesn't echo one back", function()
    mock_http(function()
      return { code = 0, http_code = 200, body = vim.json.encode({ status = "ok", message = { title = { "T" } } }) }
    end)
    local meta = fetch("10.1/queried-doi")
    assert.equals("10.1/queried-doi", meta.fields.DOI)
  end)

  it("returns a 'DOI not found' error on HTTP 404", function()
    mock_http(function() return { code = 0, http_code = 404, body = "" } end)
    local meta, err = fetch("10.1/missing")
    assert.is_nil(meta)
    assert.equals("DOI not found", err)
  end)

  it("returns an error for other non-200 statuses", function()
    mock_http(function() return { code = 0, http_code = 500, body = "" } end)
    local _, err = fetch("10.1/x")
    assert.matches("HTTP 500", err)
  end)

  it("returns an error when curl itself fails", function()
    mock_http(function() return { code = 7, http_code = 0, body = "" } end)
    local _, err = fetch("10.1/x")
    assert.equals("curl failed", err)
  end)

  it("returns an error for malformed JSON", function()
    mock_http(function() return { code = 0, http_code = 200, body = "{not json" } end)
    local _, err = fetch("10.1/x")
    assert.equals("failed to parse CrossRef response", err)
  end)

  it("returns an error when status is not 'ok'", function()
    mock_http(function() return { code = 0, http_code = 200, body = vim.json.encode({ status = "not-ok" }) } end)
    local _, err = fetch("10.1/x")
    assert.equals("failed to parse CrossRef response", err)
  end)
end)
