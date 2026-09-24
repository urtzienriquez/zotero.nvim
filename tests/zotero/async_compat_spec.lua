-- Tests the pure-Lua vim.async stand-in directly, so it runs on every Neovim
-- version (including nightly, where the plugin itself uses vim.async).
local compat = require("zotero.async_compat")

local function wait(task)
  local done, err, results = false, nil, nil
  task:on_complete(function(e, ...)
    done, err, results = true, e, { ... }
  end)
  vim.wait(5000, function() return done end, 5)
  assert(done, "task did not complete")
  return err, unpack(results)
end

describe("async_compat", function()
  it("starts a top-level task immediately, up to its first await", function()
    local log = {}
    local task = compat.run("t", function()
      log[#log + 1] = "start"
      compat.sleep(10)
      log[#log + 1] = "end"
      return 42
    end)
    assert.same({ "start" }, log)
    assert.same({ nil, 42 }, { wait(task) })
    assert.same({ "start", "end" }, log)
  end)

  it("await(fn) returns the callback's arguments, also when it fires synchronously", function()
    local err, a, b, c = wait(compat.run(function()
      local x, y = compat.await(function(done) vim.defer_fn(function() done(1, 2) end, 5) end)
      local z = compat.await(function(done) done(3) end)
      return x, y, z
    end))
    assert.is_nil(err)
    assert.same({ 1, 2, 3 }, { a, b, c })
  end)

  it("await(argc, fn, ...) puts the callback at position argc", function()
    local _, v = wait(compat.run(function()
      return compat.await(2, function(n, cb) cb(n * 2) end, 21)
    end))
    assert.equals(42, v)
  end)

  it("await(task) returns its results, for several awaiters and after it finished", function()
    local shared = compat.run(function()
      compat.sleep(10)
      return "shared"
    end)
    local a = compat.run(function() return compat.await(shared) end)
    local b = compat.run(function() return compat.await(shared) end)
    assert.same({ nil, "shared" }, { wait(a) })
    assert.same({ nil, "shared" }, { wait(b) })
    local late = compat.run(function() return compat.await(shared) end) -- already finished
    assert.same({ nil, "shared" }, { wait(late) })
  end)

  it("propagates errors to awaiters and to on_complete", function()
    local failing = compat.run(function()
      compat.sleep(5)
      error("boom", 0)
    end)
    local caught = compat.run(function()
      local ok, e = pcall(compat.await, failing)
      return ok, e
    end)
    local _, ok, e = wait(caught)
    assert.is_false(ok)
    assert.equals("boom", e)
    assert.equals("boom", (wait(failing)))
  end)

  it("starts children at the parent's next checkpoint and finishes the parent after them", function()
    local log = {}
    local parent = compat.run(function()
      compat.run(function()
        log[#log + 1] = "child start"
        compat.sleep(20)
        log[#log + 1] = "child end"
      end)
      log[#log + 1] = "parent before checkpoint"
      compat.sleep(1)
      log[#log + 1] = "parent returns"
    end)
    wait(parent)
    assert.same({ "parent before checkpoint", "child start", "parent returns", "child end" }, log)
  end)

  it("fails the parent when a child fails and nobody handled it", function()
    local parent = compat.run(function()
      compat.run(function()
        error("child failed", 0)
      end)
    end)
    assert.equals("child failed", (wait(parent)))
  end)

  it("never resumes a task inside a fast event context", function()
    local _, fast_after = wait(compat.run(function()
      compat.await(function(done) vim.system({ "true" }, {}, done) end)
      return vim.in_fast_event()
    end))
    assert.is_false(fast_after)
  end)

  it("semaphore:with() lets one holder run at a time and releases on error", function()
    local sem = compat.semaphore(1)
    local inside, max_inside = 0, 0
    local tasks = {}
    for i = 1, 3 do
      tasks[i] = compat.run(function()
        sem:with(function()
          inside = inside + 1
          max_inside = math.max(max_inside, inside)
          compat.sleep(5)
          inside = inside - 1
          if i == 2 then
            error("in critical section", 0)
          end
        end)
      end)
    end
    wait(tasks[1])
    assert.equals("in critical section", (wait(tasks[2])))
    assert.is_nil((wait(tasks[3]))) -- still got the permit after task 2 failed
    assert.equals(1, max_inside)
  end)

  describe("system (vim.system stand-in for Neovim 0.10)", function()
    local function run_system(cmd, opts)
      local result
      compat.system(cmd, opts or { text = true }, function(out) result = out end)
      vim.wait(10000, function() return result ~= nil end, 5)
      assert(result, "command did not finish")
      return result
    end

    it("returns exit code, stdout and stderr", function()
      local out = run_system({ "sh", "-c", "printf out; printf err >&2; exit 3" })
      assert.equals(3, out.code)
      assert.equals("out", out.stdout)
      assert.equals("err", out.stderr)
    end)

    it("raises when the executable does not exist", function()
      assert.has_error(function()
        compat.system({ "zotero-nvim-no-such-binary" }, {}, function() end)
      end)
    end)

    it("kills the process on timeout and reports code 124", function()
      local out = run_system({ "sleep", "5" }, { timeout = 100 })
      assert.equals(124, out.code)
    end)

    -- Regression test for neovim#30846: Neovim 0.10's vim.system dropped
    -- output still in the pipe when the exit event came first.
    it("never loses output, even for many concurrent commands", function()
      local total, bad, finished = 200, 0, 0
      for _ = 1, total do
        compat.system({ "sh", "-c", "head -c 500 /dev/zero | tr '\\0' x" }, { text = true }, function(out)
          if out.code ~= 0 or #out.stdout ~= 500 then
            bad = bad + 1
          end
          finished = finished + 1
        end)
      end
      vim.wait(60000, function() return finished == total end, 5)
      assert.equals(total, finished)
      assert.equals(0, bad)
    end)
  end)

  it("raises when await is called outside a task", function()
    assert.has_error(function()
      compat.await(function(done) done() end)
    end)
  end)
end)
