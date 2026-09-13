local M = {}

local async = vim.async

if not async then
  return setmetatable({}, {
    __index = function()
      error(
        "zotero.nvim: this version requires a Neovim build with vim.async (master). "
          .. "For Neovim < 0.13, install the latest tagged release of zotero.nvim instead.",
        2
      )
    end,
  })
end

local function cfg()
  return require("zotero.config").get()
end

--- Run an async function as a named task. Returns a vim.async Task handle.
function M.run(name, fn)
  return async.run(name, fn)
end

function M.await(...)
  return async.await(...)
end

function M.pawait(...)
  return async.pawait(...)
end

function M.checkpoint()
  return async.checkpoint()
end

function M.is_closing()
  return async.is_closing()
end

function M.sleep(ms)
  return async.sleep(ms)
end

function M.iter(tasks)
  return async.iter(tasks)
end

function M.wrap(argc, fn)
  return async.wrap(argc, fn)
end

function M.semaphore(n)
  return async.semaphore(n)
end

function M.timeout(ms, task)
  return async.timeout(ms, task)
end

--- Awaited subprocess. Returns { code, stdout, stderr } where code is the exit
--- status. Raises if the process could not be started or was killed. Runs via
--- vim.system so the event loop is never blocked. Done in closure form because
--- the arg-position await form would replace {opts} with the callback.
function M.sys(cmd, opts)
  opts = opts or {}
  local sys_opts = vim.tbl_extend("force", {
    text = true,
    timeout = opts.timeout or cfg().process_timeout or 30000,
  }, opts)
  local out = async.await(function(done)
    vim.system(cmd, sys_opts, done)
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

--- Awaited curl request. args are curl arguments without the leading "curl";
--- add "-X", "-d", "-o" etc. as usual. A trailing "%{http_code}" is appended to
--- stdout by default (and peeled off), unless args already contain "-w" (raw
--- body mode). Returns { code, body, http_code } where code is curl's exit status.
function M.http(args, opts)
  opts = opts or {}
  local has_w = false
  for _, a in ipairs(args) do
    if a == "-w" then
      has_w = true
      break
    end
  end
  local cmd = { "curl", "-sS" }
  if not has_w then
    vim.list_extend(cmd, { "-w", "%{http_code}" })
  end
  vim.list_extend(cmd, args)
  local out = M.sys(cmd, {
    timeout = opts.timeout or cfg().http_timeout or cfg().process_timeout or 60000,
  })
  local stdout = out.stdout
  if has_w then
    return { code = out.code, body = stdout, http_code = 0, stderr = out.stderr }
  end
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

--- Awaited sqlite3 query. Returns { code, stdout, stderr }.
function M.sqlite(db_path, args)
  local cmd = { "sqlite3", db_path }
  vim.list_extend(cmd, args)
  return M.sys(cmd)
end

--- Awaited copy of the live Zotero sqlite file to a private temp copy.
function M.copy(src, dst)
  return M.sys({ "cp", src, dst })
end

--- Re-align onto the main thread before mutating buffers/windows.
function M.to_main()
  async.await(1, vim.schedule)
end

--- Synchronously wait for a Task (used by call paths that must stay sync).
function M.sync(task, timeout)
  return task:wait(timeout or cfg().wait_timeout or 30000)
end

--- JSON decoding safe in fast event contexts (i.e. right after an awaited
--- I/O op inside a task, where vim.fn.json_decode is rejected). Prefers the
--- pure-Lua vim.json and falls back to vim.fn.json_decode on the main thread.
function M.json_decode(s)
  if vim.json and vim.json.decode then
    return vim.json.decode(s)
  end
  M.to_main()
  return vim.fn.json_decode(s)
end

--- JSON encoding safe in fast event contexts (see M.json_decode).
function M.json_encode(obj)
  if vim.json and vim.json.encode then
    return vim.json.encode(obj)
  end
  M.to_main()
  return vim.fn.json_encode(obj)
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

--- Awaited vim.ui.select invocation; returns (choice, idx).
function M.select(items, opts)
  return async.await(function(done)
    vim.ui.select(items, opts, done)
  end)
end

return M