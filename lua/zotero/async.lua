local M = {}

-- v0 branch: fall back to a pure-Lua implementation of the same API on
-- Neovim builds without vim.async (< 0.13).
local async = vim.async or require("zotero.async_compat")

-- Neovim 0.10's vim.system can drop a command's output under load
-- (neovim#30846, fixed in 0.11); use the stand-in there.
local system = vim.fn.has("nvim-0.11") == 1 and vim.system or require("zotero.async_compat").system

local function cfg()
  return require("zotero.config").get()
end

function M.run(name, fn)
  return async.run(name, fn)
end

function M.await(...)
  return async.await(...)
end

function M.is_closing()
  return async.is_closing()
end

function M.sleep(ms)
  return async.sleep(ms)
end

function M.semaphore(n)
  return async.semaphore(n)
end

-- Closure form because the arg-position await form would replace {opts} with
-- the callback.
function M.sys(cmd, opts)
  opts = opts or {}
  local sys_opts = vim.tbl_extend("force", {
    text = true,
    timeout = opts.timeout or cfg().process_timeout or 30000,
  }, opts)
  local out = async.await(function(done)
    system(cmd, sys_opts, done)
  end)
  if not out or out.code == nil then
    error(("zotero: failed to run '%s'"):format(cmd[1] or "?"), 0)
  end
  return {
    code = out.code,
    stdout = out.stdout or "",
    stderr = out.stderr or "",
  }
end

-- args are curl arguments without the leading "curl"; add "-X", "-d", "-o"
-- etc. as usual. A trailing "%{http_code}" is appended to stdout and peeled
-- off. Returns { code, body, http_code } where code is curl's exit status.
function M.http(args, opts)
  opts = opts or {}
  local cmd = { "curl", "-sS", "-w", "%{http_code}" }
  vim.list_extend(cmd, args)
  local out = M.sys(cmd, {
    timeout = opts.timeout or cfg().http_timeout or cfg().process_timeout or 60000,
  })
  local stdout = out.stdout
  local tail = stdout:sub(-3)
  if tail:match("^%d%d%d$") then
    if #stdout == 3 then
      return { code = out.code, body = "", http_code = tonumber(tail) or 0, stderr = out.stderr }
    end
    -- stdout = raw body immediately followed by the %{http_code} digit run. The
    -- body may or may not end in a newline; only peel the code when it is a
    -- clean 3-digit run that isn't glued to body digits.
    if not stdout:sub(-4, -4):match("%d") then
      return {
        code = out.code,
        body = stdout:sub(1, -4):gsub("%s+$", ""),
        http_code = tonumber(tail) or 0,
        stderr = out.stderr,
      }
    end
  end
  return { code = out.code, body = stdout:gsub("%s+$", ""), http_code = 0, stderr = out.stderr }
end

-- .timeout: wait (up to 5 s) instead of failing with "database is locked"
-- when several queries hit a freshly copied database at once -- the first
-- sqlite3 to open a copy that has a -wal file briefly locks it to replay it.
function M.sqlite(db_path, args)
  local cmd = { "sqlite3", "-cmd", ".timeout 5000", db_path }
  vim.list_extend(cmd, args)
  return M.sys(cmd)
end

function M.copy(src, dst)
  return M.sys({ "cp", src, dst })
end

--- Re-align onto the main thread before mutating buffers/windows.
function M.to_main()
  async.await(1, vim.schedule)
end

function M.json_decode(s)
  return vim.json.decode(s)
end

function M.json_encode(obj)
  return vim.json.encode(obj)
end

--- vim.notify that is safe to call while a task is resumed in a fast event
--- context; hops to the main thread when necessary.
function M.notify(msg, level, opts)
  if vim.in_fast_event() then
    vim.schedule(function()
      vim.notify(msg, level or vim.log.levels.INFO, opts)
    end)
    return
  end
  vim.notify(msg, level or vim.log.levels.INFO, opts)
end

function M.select(items, opts)
  return async.await(function(done)
    vim.ui.select(items, opts, done)
  end)
end

return M