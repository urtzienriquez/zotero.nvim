local fixture = require("tests.helpers.fixture")
local async_mod = require("zotero.async")

local function run_sync(fn)
  return fixture.run_sync(fn)
end

describe("async.sys", function()
  it("runs a command and captures stdout", function()
    local out = run_sync(function()
      return async_mod.sys({ "echo", "-n", "hello" })
    end)
    assert.equals(0, out.code)
    assert.equals("hello", out.stdout)
  end)

  it("captures a non-zero exit code and stderr", function()
    local out = run_sync(function()
      return async_mod.sys({ "sh", "-c", "echo oops 1>&2; exit 3" })
    end)
    assert.equals(3, out.code)
    assert.equals("oops", vim.trim(out.stderr))
  end)

  it("raises if the executable does not exist", function()
    assert.has_error(function()
      run_sync(function()
        return async_mod.sys({ "this-command-does-not-exist-zotero-test" })
      end)
    end)
  end)
end)

describe("async.json_encode / json_decode", function()
  it("round-trips a table", function()
    local encoded = async_mod.json_encode({ a = 1, b = "two", c = { 1, 2, 3 } })
    local decoded = async_mod.json_decode(encoded)
    assert.equals(1, decoded.a)
    assert.equals("two", decoded.b)
    assert.same({ 1, 2, 3 }, decoded.c)
  end)

  it("raises on invalid JSON (callers are expected to pcall this)", function()
    assert.has_error(function()
      async_mod.json_decode("{not valid json")
    end)
  end)
end)

describe("async.sqlite / async.copy", function()
  before_each(function() fixture.setup() end)
  after_each(function() fixture.teardown() end)

  it("runs a query against a real sqlite file", function()
    local out = run_sync(function()
      return async_mod.sqlite(fixture.db_path, { "-json", "SELECT itemID FROM items WHERE itemID = 1" })
    end)
    assert.equals(0, out.code)
    local rows = vim.json.decode(out.stdout)
    assert.equals(1, rows[1].itemID)
  end)

  it("copies a file", function()
    local dst = vim.fn.tempname()
    local out = run_sync(function()
      return async_mod.copy(fixture.db_path, dst)
    end)
    assert.equals(0, out.code)
    assert.equals(1, vim.fn.filereadable(dst))
    vim.fn.delete(dst)
  end)
end)

describe("async.http", function()
  local server_job, port

  if vim.fn.executable("python3") == 0 then
    it("skipped: python3 not available to run the local test HTTP server", function() end)
    return
  end

  before_each(function()
    port = 18000 + math.random(1, 900)
    local docroot = vim.fn.tempname()
    vim.fn.mkdir(docroot, "p")
    vim.fn.writefile({ '{"ok":true}' }, docroot .. "/data.json")
    server_job = vim.system(
      { "python3", "-m", "http.server", tostring(port), "--bind", "127.0.0.1", "--directory", docroot },
      { detach = false }
    )
    vim.wait(1000, function()
      return vim.system({ "curl", "-s", "-o", "/dev/null", "http://127.0.0.1:" .. port .. "/" }):wait().code == 0
    end, 50)
  end)

  after_each(function()
    if server_job then
      server_job:kill(15)
      server_job:wait(2000)
    end
  end)

  it("parses a 200 response with a JSON body", function()
    local res = run_sync(function()
      return async_mod.http({ "http://127.0.0.1:" .. port .. "/data.json" })
    end)
    assert.equals(0, res.code)
    assert.equals(200, res.http_code)
    assert.equals('{"ok":true}', res.body)
  end)

  it("parses a 404 response", function()
    local res = run_sync(function()
      return async_mod.http({ "http://127.0.0.1:" .. port .. "/nonexistent" })
    end)
    assert.equals(0, res.code)
    assert.equals(404, res.http_code)
  end)

  it("reports a curl transport failure for an unreachable host", function()
    local res = run_sync(function()
      return async_mod.http({ "http://127.0.0.1:1/nope", "--max-time", "2" })
    end)
    assert.is_not.equal(0, res.code)
  end)
end)

describe("async.notify", function()
  it("does not error when called outside a fast event context", function()
    assert.has_no.errors(function()
      async_mod.notify("test message", vim.log.levels.INFO)
    end)
  end)
end)

describe("async.to_main", function()
  it("can be awaited from inside a task without error", function()
    local ok = run_sync(function()
      async_mod.to_main()
      return true
    end)
    assert.is_true(ok)
  end)
end)

describe("async.semaphore", function()
  it("serializes access: only one holder runs the critical section at a time", function()
    local sem = async_mod.semaphore(1)
    local active, max_active = 0, 0
    local order = {}

    local function worker(id)
      return async_mod.run("worker-" .. id, function()
        sem:with(function()
          active = active + 1
          max_active = math.max(max_active, active)
          async_mod.sleep(10)
          table.insert(order, id)
          active = active - 1
        end)
      end)
    end

    local t1 = worker(1)
    local t2 = worker(2)
    fixture.wait_for(t1)
    fixture.wait_for(t2)
    assert.equals(1, max_active)
    assert.same({ 1, 2 }, order)
  end)
end)
