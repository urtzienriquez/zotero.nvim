if vim.g.loaded_zotero == 1 then
  return
end
vim.g.loaded_zotero = 1

-- Modules load on first use (a command run), not at startup: indexing one of
-- these proxies requires the real module then.
local function lazy(name)
  return setmetatable({}, { __index = function(_, k) return require(name)[k] end })
end
local async_mod = lazy("zotero.async")
local db = lazy("zotero.db")

vim.api.nvim_create_user_command("Zotero", function()
  require("zotero").open_library()
end, { desc = "Open Zotero library browser" })

vim.api.nvim_create_user_command("ZoteroDebug", function()
  require("zotero").debug()
end, { desc = "Zotero debug info" })

vim.api.nvim_create_user_command("ZoteroImport", function(opts)
  async_mod.run("zotero:cmd.import_pdf", function()
    local ok = async_mod.await(require("zotero.api").import_pdf(opts.args))
    if ok then
      async_mod.to_main()
      require("zotero.ui.items").fetch_and_render(true)
    end
  end)
end, { desc = "Import a PDF into Zotero", nargs = 1, complete = "file" })

vim.api.nvim_create_user_command("ZoteroMaxItems", function(opts)
  local n = tonumber(opts.args)
  if not n or n < 1 then
    async_mod.notify("zotero: max_items must be a positive integer", vim.log.levels.ERROR)
    return
  end
  require("zotero.config").options.max_items = n
  async_mod.notify("zotero: max_items set to " .. n, vim.log.levels.INFO)
  require("zotero.ui.items").fetch_and_render(true)
end, { nargs = 1, desc = "Set the maximum number of items to display (e.g. :ZoteroMaxItems 100)" })

local function set_date_cmd(postfix, label, fn)
  return function(opts)
    local items = require("zotero.ui.items")
    if items.readonly_guard() then
      return
    end
    local item = items.get_current_item()
    if not item then
      async_mod.notify("zotero: no item under cursor", vim.log.levels.ERROR)
      return
    end
    local function apply(input)
      if input and input ~= "" then
        async_mod.run("zotero:set_date", function()
          local item_key = async_mod.await(db.get_item_key(item.itemID))
          if not item_key or item_key == "" then
            async_mod.notify("zotero: cannot determine item key", vim.log.levels.ERROR)
            return
          end
          async_mod.await(fn(item_key, vim.trim(input)))
          async_mod.to_main()
          items.fetch_and_render(true)
        end)
      end
    end
    if opts.args and opts.args ~= "" then
      apply(opts.args)
    else
      vim.ui.input({ prompt = label }, apply)
    end
  end
end

vim.api.nvim_create_user_command("ZoteroSetDateAdded",
  set_date_cmd("DateAdded", "Date added (YYYY-MM-DD): ",
    function(k, v) require("zotero.api").set_date_added(k, v) end),
  { nargs = "?", desc = "Set the date added for the item under cursor" })

vim.api.nvim_create_user_command("ZoteroSetDateModified",
  set_date_cmd("DateModified", "Date modified (YYYY-MM-DD): ",
    function(k, v) require("zotero.api").set_date_modified(k, v) end),
  { nargs = "?", desc = "Set the date modified for the item under cursor" })

-- :ZoteroFilterType                 open the type picker
-- :ZoteroFilterType all             clear the filter
-- :ZoteroFilterType book thesis     show only these types
-- :ZoteroFilterType -webpage -note  hide these types
vim.api.nvim_create_user_command("ZoteroFilterType", function(opts)
  local items = require("zotero.ui.items")
  local args = opts.fargs
  if #args == 0 then
    items.pick_type_filter()
    return
  end
  if #args == 1 and args[1] == "all" then
    items.set_type_filter("exclude", {})
    return
  end
  local hide, only = {}, {}
  for _, a in ipairs(args) do
    if a:sub(1, 1) == "-" then
      hide[#hide + 1] = a:sub(2)
    else
      only[#only + 1] = a
    end
  end
  if #hide > 0 and #only > 0 then
    async_mod.notify("zotero: use either type names (show only) or -type names (hide), not both", vim.log.levels.ERROR)
    return
  end
  if #only > 0 then
    items.set_type_filter("include", only)
  else
    items.set_type_filter("exclude", hide)
  end
end, {
  nargs = "*",
  desc = "Filter the items list by item type (all | type... | -type...)",
  complete = function(arg_lead)
    local candidates = { "all" }
    for _, name in ipairs(require("zotero.ui.items").known_type_names()) do
      candidates[#candidates + 1] = name
      candidates[#candidates + 1] = "-" .. name
    end
    return vim.tbl_filter(function(c)
      return c:sub(1, #arg_lead) == arg_lead
    end, candidates)
  end,
})

-- :ZoteroAddFeed                   prompt for a feed URL
-- :ZoteroAddFeed {url} [name...]   subscribe (name defaults to the feed's title)
vim.api.nvim_create_user_command("ZoteroAddFeed", function(opts)
  local url = opts.fargs[1]
  local name = #opts.fargs > 1 and table.concat(vim.list_slice(opts.fargs, 2), " ") or nil
  require("zotero.ui.collections").add_feed(url, name)
end, { nargs = "*", desc = "Subscribe to an RSS/Atom feed in Zotero" })

vim.api.nvim_create_user_command("ZoteroImportOPML", function(opts)
  local path = vim.fn.expand(opts.args)
  async_mod.run("zotero:cmd.import_opml", function()
    local added = async_mod.await(require("zotero.api").import_opml(path))
    if added then
      async_mod.to_main()
      require("zotero.ui.collections").refresh_counts()
    end
  end)
end, { nargs = 1, complete = "file", desc = "Import feeds into Zotero from an OPML file" })

vim.api.nvim_create_user_command("ZoteroRefreshFeeds", function()
  require("zotero.ui.collections").refresh_feeds(nil)
end, { desc = "Fetch new items for all Zotero feeds" })
