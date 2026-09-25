-- Startup must stay cheap: setup() and plugin/zotero.lua only load the
-- plugin's entry module and its config; everything else loads on first use.
local fixture = require("tests.helpers.fixture")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

-- Runs `lua_code` in a clean `nvim -u NONE` that has loaded zotero.nvim the
-- way a user's config does, and returns what it printed.
local function in_fresh_nvim(lua_code)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(([[
    vim.opt.rtp:prepend(%q)
    require("zotero").setup({ db_path = %q })
    vim.cmd.runtime("plugin/zotero.lua")
    local function loaded()
      local names = {}
      for name in pairs(package.loaded) do
        if name == "zotero" or name:match("^zotero%%.") then names[#names + 1] = name end
      end
      table.sort(names)
      return table.concat(names, " ")
    end
  ]]):format(root, fixture.db_path) .. lua_code, "\n"), script)
  local res = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, { text = true }):wait()
  return vim.trim((res.stdout or "") .. (res.stderr or ""))
end

describe("lazy loading", function()
  before_each(function() fixture.setup() end)
  after_each(function() fixture.teardown() end)

  it("setup() and the plugin file load only zotero and zotero.config", function()
    assert.equals("zotero zotero.config", in_fresh_nvim([[io.write(loaded())]]))
  end)

  it("still defines the commands", function()
    assert.equals("2 2 2", in_fresh_nvim([[
      io.write(vim.fn.exists(":Zotero") .. " " .. vim.fn.exists(":ZoteroImport") .. " " .. vim.fn.exists(":ZoteroFilterType"))
    ]]))
  end)

  it("loads the rest on first use", function()
    local out = in_fresh_nvim([[
      pcall(vim.cmd, "ZoteroMaxItems 0") -- rejected with an error notification: needs zotero.async
      io.write(loaded())
    ]])
    assert.matches("zotero%.async", out)
  end)
end)
