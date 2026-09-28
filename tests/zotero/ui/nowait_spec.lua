-- Keys typed for real (not fed by a test) wait 'timeoutlen' when a longer
-- mapping starts with them, e.g. a user's own global mapping. The plugin's
-- buffer-local keys must fire at once anyway (nowait). Checked in a separate
-- Neovim through its input loop, since keys fed inside a test never wait.
--
-- nowait doesn't help with key-hint plugins like mini.clue, which read the
-- keys after a trigger (g) themselves and wait while more than one mapping
-- matches. So no default key may be the start of one of Neovim's own
-- default mappings either (that's why the collections split is gb, not gc:
-- Neovim has gc/gcc for comments).
local fixture = require("tests.helpers.fixture")
local config = require("zotero.config")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")

describe("keys typed for real", function()
  before_each(function() fixture.setup() end)
  after_each(function() fixture.teardown() end)

  it("gb opens the collections split at once, even with a longer global mapping", function()
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile(vim.split(([[
      vim.opt.rtp:prepend(%q)
      vim.o.timeoutlen = 10000 -- without nowait, gb would sit waiting this long
      vim.keymap.set("n", "gbx", "<Nop>") -- a user's global mapping starting with gb
      require("zotero").setup({ db_path = %q })
      require("zotero").open_library()
      local layout = require("zotero.ui.layout")
      vim.defer_fn(function()
        vim.api.nvim_input("gb")
        vim.defer_fn(function()
          local win = layout.get_collections_win()
          io.stdout:write(win and vim.api.nvim_get_current_win() == win and "open" or "not open")
          vim.cmd("qa!")
        end, 300)
      end, 200)
    ]]):format(root, fixture.db_path), "\n"), script)
    local res = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "luafile " .. script },
      { text = true, timeout = 8000 }):wait()
    assert.equals("open", vim.trim(res.stdout or ""), res.stderr)
  end)

  it("no default key is the start of one of Neovim's own default mappings", function()
    local defaults = config.defaults.keymaps
    for _, mode in ipairs({ "n", "x" }) do
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        local global = vim.api.nvim_replace_termcodes(m.lhs, true, true, true)
        for name, lhs in pairs(defaults) do
          -- items_toggle_colored_tag is a prefix (t1..t9), not a key itself.
          if type(lhs) == "string" and name ~= "items_toggle_colored_tag" then
            local key = vim.api.nvim_replace_termcodes(lhs, true, true, true)
            assert.is_false(global ~= key and vim.startswith(global, key),
              ("%s = %q is the start of Neovim's %s-mode mapping %q"):format(name, lhs, mode, m.lhs))
          end
        end
      end
    end
  end)
end)
