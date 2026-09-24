-- Builds a throwaway sqlite3 db from tests/fixtures/schema.sql and points
-- zotero.config at it.
local M = {}

local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("(.*/)")
end

local SCHEMA_PATH = script_dir() .. "../fixtures/schema.sql"

M.db_path = nil

-- Strictly increasing, so two fixtures built within the same wall-clock
-- second never collide in db.lua's mtime-based staleness checks.
local _mtime_counter = 0
local function next_mtime()
  _mtime_counter = _mtime_counter + 1
  return os.time() + 3600 * 24 * 365 + _mtime_counter
end

function M.setup()
  M.db_path = vim.fn.tempname() .. "-zotero-fixture.sqlite"
  local cmd = { "sqlite3", M.db_path }
  local schema = table.concat(vim.fn.readfile(SCHEMA_PATH), "\n")
  local result = vim.system(cmd, { stdin = schema, text = true }):wait()
  if result.code ~= 0 then
    error("failed to build fixture db: " .. (result.stderr or ""))
  end
  local mtime = next_mtime()
  vim.uv.fs_utime(M.db_path, mtime, mtime)
  require("zotero.config").set({ db_path = M.db_path })
  require("zotero.db").invalidate_cache()
  return M.db_path
end

-- Doesn't delete the file: a copy_task from this test can still be reading
-- it when the next test's setup() runs.
function M.teardown()
  M.db_path = nil
end

function M.wait_for(task)
  local done, err, results = false, nil, nil
  task:on_complete(function(e, ...)
    done = true
    err = e
    results = { ... }
  end)
  vim.wait(20000, function() return done end, 10)
  if not done then
    error("task did not complete within timeout")
  end
  if err then
    error(("task failed: %s"):format(vim.inspect(err)))
  end
  return unpack(results)
end

function M.run_sync(fn)
  return M.wait_for(require("zotero.async").run("test", fn))
end

return M
