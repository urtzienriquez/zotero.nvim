-- Pure-Lua stand-in for the part of `vim.async` zotero.nvim uses, for Neovim
-- builds without it (< 0.13). lua/zotero/async.lua picks this up only when
-- vim.async is missing, so the feature code is identical on every version.
--
-- Semantics follow $VIMRUNTIME/lua/vim/async/_core.lua for what we use:
--   * run([name], fn, ...) returns a Task. A top-level task starts right away;
--     a task created while another task runs is that task's child, starts at
--     the parent's next checkpoint (await, or the end of its function), and
--     the parent only completes once its children have.
--   * An unhandled child error (the child was never awaited / given an
--     on_complete) fails the parent.
--   * await(task) | await(fn(done)) | await(argc, fn, ...): the callback goes
--     at position argc (await(1, vim.schedule) -> vim.schedule(cb)).
--   * Tasks can't be cancelled here, so is_closing() is always false.
-- One deliberate difference: vim.async resumes a task right inside fast
-- (libuv) callbacks such as vim.system's, where nightly allows most vim.fn
-- calls. Older Neovim raises E5560 for them there, so this module moves any
-- resume that would happen in a fast context to the next main-loop tick.
-- Task code therefore never runs in a fast context on these versions.
local M = {}

local unpack = unpack or table.unpack

local function pack(...)
  return { n = select("#", ...), ... }
end

local Task = {}
Task.__index = Task

-- coroutine -> Task, to find the task that is currently running.
local task_of = setmetatable({}, { __mode = "k" })

local function current_task()
  local co = coroutine.running()
  return co and task_of[co] or nil
end

local function resume_now(task)
  local ok, err = coroutine.resume(task.co)
  if not ok and not task.done then
    -- Only reachable through a bug in this module: the task body is pcall'd.
    task:_finish(err, pack())
  end
end

-- Resumes `task`, but never inside a fast event context (see header).
local function resume(task)
  if vim.in_fast_event() then
    vim.schedule(function()
      resume_now(task)
    end)
  else
    resume_now(task)
  end
end

-- Starts children created since the task's last checkpoint.
local function start_pending(task)
  while #task.pending > 0 do
    resume(table.remove(task.pending, 1))
  end
end

-- Suspends the running task until `task` is done (without marking it
-- handled or raising its error).
local function wait_done(task)
  if task.done then
    return
  end
  local waiter = assert(current_task(), "zotero.async: await() called outside of a task")
  local suspended = false
  local resumed = false
  table.insert(task.waiters, function()
    resumed = true
    if suspended then
      resume(waiter)
    end
  end)
  if not resumed then
    suspended = true
    coroutine.yield()
  end
end

function Task:_finish(err, results)
  self.done = true
  self.err = err
  self.results = results
  local waiters = self.waiters
  self.waiters = {}
  for _, fn in ipairs(waiters) do
    fn()
  end
  -- Report errors nobody is going to see (fire-and-forget top-level tasks),
  -- like vim.async does. Checked later so an on_complete() added right after
  -- run() still counts.
  if err ~= nil and not self.parent then
    vim.schedule(function()
      if not self.handled then
        vim.notify(("zotero: task %s failed: %s"):format(self.name or "?", tostring(err)), vim.log.levels.ERROR)
      end
    end)
  end
end

--- Calls `cb(err, ...)` when the task finishes (immediately if it already has).
function Task:on_complete(cb)
  self.handled = true
  local function call()
    if self.err ~= nil then
      cb(self.err)
    else
      cb(nil, unpack(self.results, 1, self.results.n))
    end
  end
  if self.done then
    call()
  else
    table.insert(self.waiters, call)
  end
  return self
end

--- Blocks (processing events) until the task finishes; returns its results.
function Task:wait(timeout)
  self.handled = true
  vim.wait(timeout or 2 ^ 31 - 1, function()
    return self.done
  end, 10)
  if not self.done then
    error("zotero.async: timed out waiting for task " .. tostring(self.name), 2)
  end
  if self.err ~= nil then
    error(self.err, 0)
  end
  return unpack(self.results, 1, self.results.n)
end

function M.run(...)
  local name, fn, args
  if type(...) == "string" then
    name = ...
    fn = select(2, ...)
    args = pack(select(3, ...))
  else
    fn = ...
    args = pack(select(2, ...))
  end
  assert(type(fn) == "function", "zotero.async: run() expects a function")

  local task = setmetatable({
    name = name,
    done = false,
    handled = false,
    waiters = {},
    children = {},
    pending = {},
  }, Task)

  task.co = coroutine.create(function()
    local res = pack(pcall(fn, unpack(args, 1, args.n)))
    -- Structured concurrency: start any children not started yet and wait
    -- for all of them before this task completes.
    start_pending(task)
    for _, child in ipairs(task.children) do
      wait_done(child)
    end
    local err, results = nil, pack(unpack(res, 2, res.n))
    if not res[1] then
      err, results = res[2], pack()
    else
      for _, child in ipairs(task.children) do
        if child.err ~= nil and not child.handled then
          err, results = child.err, pack()
          break
        end
      end
    end
    task:_finish(err, results)
  end)
  task_of[task.co] = task

  local parent = current_task()
  if parent then
    task.parent = parent
    table.insert(parent.children, task)
    table.insert(parent.pending, task)
  else
    resume(task)
  end
  return task
end

function M.await(...)
  local task = current_task()
  if not task then
    error("zotero.async: await() called outside of a task", 2)
  end
  start_pending(task) -- await is a checkpoint

  local first = ...
  if getmetatable(first) == Task then
    first.handled = true
    wait_done(first)
    if first.err ~= nil then
      error(first.err, 0)
    end
    return unpack(first.results, 1, first.results.n)
  end

  local argc, fn, args
  if type(first) == "function" then
    argc, fn, args = 1, first, pack()
  else
    argc, fn, args = first, select(2, ...), pack(select(3, ...))
  end

  local fired, suspended, result = false, false, nil
  local call_args = {}
  for i = 1, argc - 1 do
    call_args[i] = args[i]
  end
  call_args[argc] = function(...)
    if fired then
      return
    end
    fired = true
    result = pack(...)
    if suspended then
      resume(task)
    end
  end
  fn(unpack(call_args, 1, argc))
  if not fired then
    suspended = true
    coroutine.yield()
  end
  return unpack(result, 1, result.n)
end

function M.is_closing()
  return false
end

function M.sleep(ms)
  M.await(function(done)
    vim.defer_fn(done, ms)
  end)
end

local Semaphore = {}
Semaphore.__index = Semaphore

function M.semaphore(permits)
  return setmetatable({ permits = permits or 1, queue = {} }, Semaphore)
end

function Semaphore:acquire()
  if self.permits > 0 then
    self.permits = self.permits - 1
    return
  end
  M.await(function(done)
    table.insert(self.queue, done)
  end)
end

function Semaphore:release()
  local next_waiter = table.remove(self.queue, 1)
  if next_waiter then
    next_waiter() -- hand the permit straight over
  else
    self.permits = self.permits + 1
  end
end

--- Runs `fn` while holding a permit; releases it even if `fn` errors.
function Semaphore:with(fn)
  self:acquire()
  local res = pack(pcall(fn))
  self:release()
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, res.n)
end

return M
