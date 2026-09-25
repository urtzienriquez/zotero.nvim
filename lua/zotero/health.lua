-- :checkhealth zotero
local M = {}

local h = vim.health
local BASE = "http://127.0.0.1:23119"

-- Endpoints of the companion add-on, newest first, with the add-on version
-- that added each and what needs it. Probed with GET: Zotero answers 400
-- ("does not support method") for an endpoint that exists and 404 for one
-- that doesn't, without ever running it.
local ADDON_LEVELS = {
  { version = "1.5.0", path = "/connector/removeFromCollection", needs = "removing items from a collection (`cr`)" },
  { version = "1.4.0", path = "/connector/setTagColor", needs = "colouring and deleting tags (`cc`, `dd` on a tag)" },
  { version = "1.3.0", path = "/connector/toggleTag", needs = "toggling tags (`t1`-`t9`, `tt`)" },
  { version = "1.2.1", path = "/connector/setFeedItemsRead", needs = "managing feeds and their read state" },
  { version = "1.0.0", path = "/connector/updateItem", needs = "editing items, collections, trash" },
}

-- HTTP status of a GET to Zotero's local server, or nil when it can't be
-- reached (Zotero not running). Replaceable in tests.
function M.http_status(path)
  local ok, res = pcall(function()
    return vim.system({ "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", BASE .. path },
      { text = true }):wait(3000)
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return tonumber(res.stdout)
end

-- The add-on version bundled with this checkout of the plugin.
local function bundled_addon_version()
  local file = vim.api.nvim_get_runtime_file("zotero_plugin/manifest.json", false)[1]
  if not file then
    return nil
  end
  local ok, manifest = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
  return ok and type(manifest) == "table" and manifest.version or nil
end

local function check_neovim()
  h.start("Neovim")
  if vim.async then
    h.ok("Neovim " .. tostring(vim.version()) .. " with `vim.async`")
  else
    h.error("Neovim " .. tostring(vim.version()) .. " has no `vim.async`: this `main` branch needs Neovim nightly (0.13-dev)",
      { "On Neovim 0.10-0.12, install the `v0` branch instead (same features)." })
  end
end

local function check_tools()
  h.start("External tools")
  if vim.fn.executable("sqlite3") == 1 then
    local out = vim.system({ "sqlite3", "--version" }, { text = true }):wait()
    local version = (out.stdout or ""):match("^(%d+%.%d+%.%d+)") or "?"
    h.ok("`sqlite3` " .. version)
    local fts5 = vim.system({ "sqlite3", ":memory:", "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram');" },
      { text = true }):wait()
    if fts5.code == 0 then
      h.ok("`sqlite3` supports FTS5 (fast search, `ft:` full-text search)")
    else
      h.warn("`sqlite3` has no FTS5: `ff` still works but is slower, and `ft:` (PDF full text) matches nothing", {
        "macOS's built-in sqlite3 lacks FTS5: `brew install sqlite` and put `$(brew --prefix sqlite)/bin` first on your PATH.",
        "See :h zotero-search",
      })
    end
    if vim.version.lt(version, "3.43.0") then
      h.warn("`ft:` needs sqlite3 3.43 or newer to read Zotero's full-text index; this one is " .. version)
    end
  else
    h.error("`sqlite3` not found: the library can't be read", { "Install it, e.g. `sudo apt install sqlite3`" })
  end

  if vim.fn.executable("curl") == 1 then
    h.ok("`curl` found")
  else
    h.error("`curl` not found: nothing can be sent to Zotero (editing, importing, tags, feeds...)")
  end

  local viewer = require("zotero.config").get().pdf_viewer
  if viewer and viewer ~= "" then
    local cmd = viewer -- run as `{ pdf_viewer, file }` (see items.open_external)
    if vim.fn.executable(cmd) == 1 then
      h.ok("`pdf_viewer` (`" .. cmd .. "`) found")
    else
      h.error("`pdf_viewer` is set to `" .. cmd .. "`, which isn't executable: `oo` / `ob` won't open anything")
    end
  else
    h.ok("Attachments and URLs open with the system handler (`vim.ui.open`)")
  end
end

local function check_database()
  h.start("Zotero database")
  local path = require("zotero.config").get().db_path
  if not path or path == "" then
    h.error("No Zotero database found", { "Set `db_path` in setup(), e.g. `~/Zotero/zotero.sqlite`" })
    return
  end
  if vim.fn.filereadable(path) == 0 then
    h.error("`db_path` isn't readable: " .. path)
    return
  end
  h.ok("Database: " .. path)
  local fulltext = vim.fs.joinpath(vim.fs.dirname(path), "fulltext.sqlite")
  if vim.fn.filereadable(fulltext) == 1 then
    h.ok("Full-text index: " .. fulltext)
  else
    h.info("No full-text index next to the database: `ft:` searches will match nothing")
  end
end

-- Returns whether Zotero answered, so the add-on checks can be skipped.
local function check_zotero_running()
  h.start("Zotero application")
  local status = M.http_status("/connector/ping")
  if status == 200 then
    h.ok("Zotero is running and accepts connections (" .. BASE .. ")")
    return true
  end
  h.warn("Zotero isn't running, or doesn't accept connections from other applications. "
    .. "You can ignore this if you only browse and search the library: that works without it.", {
    "Everything that changes your library needs Zotero running: editing items (`ee`), adding and importing"
      .. " (`aa`, `ai`, `an`), trashing (`dd`), collections (`cm`, `cr`, `aa`/`dd` in the collections pane),"
      .. " tags (`t1`-`t9`, `tt`, `cc`, `dd` on a tag), feeds (`R`, read state, adding/removing),"
      .. " and regenerating citation keys (`gK`).",
    "In Zotero: Settings > Advanced > \"Allow other applications on this computer to communicate with Zotero\".",
  })
  return false
end

local function check_addon()
  h.start("Companion add-on (zotero_plugin/)")
  local bundled = bundled_addon_version()
  local found
  for _, level in ipairs(ADDON_LEVELS) do
    local status = M.http_status(level.path)
    if status and status ~= 404 then
      found = level
      break
    end
  end
  if not found then
    h.warn("Not installed: editing items, collections, trash, tags and feeds won't work", {
      "Install `zotero_plugin/zotero-nvim-connector@urtzi.xpi` in Zotero (Tools > Add-ons), see :h zotero-companion-plugin",
    })
    return
  end
  local missing = {}
  for _, level in ipairs(ADDON_LEVELS) do
    if vim.version.gt(level.version, found.version) then
      missing[#missing + 1] = level.needs .. " (" .. level.version .. ")"
    end
  end
  if #missing == 0 then
    h.ok("Installed, version " .. found.version .. " or later" .. (bundled and (" (bundled: " .. bundled .. ")") or ""))
  else
    h.warn("Installed but outdated (version " .. found.version .. "; bundled: " .. (bundled or "?")
      .. "). Missing: " .. table.concat(missing, "; "), {
      "Reinstall `zotero_plugin/zotero-nvim-connector@urtzi.xpi` in Zotero (Tools > Add-ons)",
    })
  end
end

local function check_better_bibtex()
  h.start("Better BibTeX")
  if M.http_status("/better-bibtex/cayw?probe=true") == 200 then
    h.ok("Better BibTeX is installed")
  else
    h.warn("Better BibTeX not found: `gK` (regenerate citation key) won't work", {
      "Citation keys Zotero already stores still show and yank (`yk`). Install Better BibTeX to generate them.",
    })
  end
end

function M.check()
  check_neovim()
  check_tools()
  check_database()
  if check_zotero_running() then
    check_addon()
    check_better_bibtex()
  end
end

return M
