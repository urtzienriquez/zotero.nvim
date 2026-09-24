local M = {}

local types = require("zotero.types")
local config_mod = require("zotero.config")
local async_mod = require("zotero.async")
local search_query = require("zotero.search_query")

local function cfg()
  return config_mod.get()
end

-- Path of the current private copy of the database. Every (re)copy goes to a
-- fresh path (db_copy_base .. "-" .. n) and only replaces db_copy once it is
-- complete, so a query already running against the previous copy is never
-- pointed at a half-written or missing file ("no such table" errors). The
-- old copy is deleted a minute later rather than immediately: a query may
-- hold its path while its sqlite3 process is still starting, and an early
-- delete would make that process open an empty database. (Neovim removes its
-- temp dir, and with it any leftover copy, on exit.)
local db_copy = nil
local db_copy_base = nil
local copy_seq = 0
local db_last_mtime = nil
local db_last_wal_mtime = nil
local copy_task = nil
local copy_lock = async_mod.semaphore(1)

-- Result cache, keyed on the DB file mtime so it auto-invalidates when Zotero
-- writes to the database. Cleared explicitly via invalidate_cache() on
-- in-plugin writes/refreshes (see ensure_db_copy()/cache_key()).
local _cache = {}
local _cache_mtime = nil
local _cache_wal_mtime = nil

-- Monotonic counter bumped whenever the DB copy may hold different data than
-- the last render (cache invalidation or a fresh copy). Used to skip the
-- background re-render on reopen when nothing changed.
local data_version = 0

-- Precomputed FTS5 search index state (see ensure_search_index() below).
-- Rebuilt lazily on first search after a copy refresh, and tracked against
-- the same mtime epoch as the copy so it's invalidated whenever db_backup()
-- overwrites the copy from scratch.
local _fts5_available = nil -- nil = unprobed this session
local index_task = nil
local index_built_in = nil -- path of the copy the index was built in
local index_lock = async_mod.semaphore(1)

-- mtime (seconds) of the sqlite -wal sidecar, or 0 when there is none. Zotero
-- runs its database in WAL mode, where fresh writes land in the -wal file until
-- a checkpoint. Copying only the main file -- and keying staleness only on its
-- mtime -- would silently miss those writes, which is why imports/edits done by
-- Zotero could stay invisible to refreshes until the next checkpoint.
local function wal_mtime(path)
  if not path then
    return 0
  end
  local wstat = vim.uv.fs_stat(path .. "-wal")
  return wstat and wstat.mtime.sec or 0
end

-- Plain `cp` of the main file plus its -wal sidecar -- deliberately not
-- sqlite's online `.backup`, whose CLI form opens its own source connection
-- that ignores the shell `.timeout`, so retrying it only sleeps through a
-- lock it can never wait out. Copying the two files as separate, non-atomic
-- steps means a copy taken mid-write can in principle be torn; the
-- mtime/wal-mtime staleness check in ensure_db_copy() re-copies on the next
-- refresh, so a torn snapshot is at worst transiently stale.
local function db_backup(live, dest)
  pcall(vim.uv.fs_unlink, dest)
  pcall(vim.uv.fs_unlink, dest .. "-wal")
  pcall(vim.uv.fs_unlink, dest .. "-shm")
  local res = async_mod.copy(live, dest)
  if res.code ~= 0 then
    return res
  end
  if vim.uv.fs_stat(live .. "-wal") then
    if async_mod.copy(live .. "-wal", dest .. "-wal").code ~= 0 then
      return { code = 1, stdout = "", stderr = "copy of -wal sidecar failed" }
    end
  end
  return { code = 0, stdout = "", stderr = "" }
end

local function ensure_db_copy()
  local path = cfg().db_path
  if not path or path == "" then
    return nil
  end
  if not db_copy_base then
    db_copy_base = vim.fn.tempname()
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil
  end
  local mtime = stat.mtime.sec
  local wmtime = wal_mtime(path)
  if db_last_mtime ~= nil and mtime == db_last_mtime and wmtime == (db_last_wal_mtime or 0) then
    return db_copy
  end
  -- Single-flight: concurrent callers share one copy task and *all* await it,
  -- so the copy always completes before any query runs and no caller bakes a
  -- torn snapshot.
  if not copy_task then
    local path_ = path
    copy_task = async_mod.run("zotero:db-copy", function()
      copy_lock:with(function()
        local s = vim.uv.fs_stat(path_)
        if not s then
          return
        end
        local m = s.mtime.sec
        local w = wal_mtime(path_)
        if m ~= (db_last_mtime or 0) or w ~= (db_last_wal_mtime or 0) then
          local ok = pcall(function()
            copy_seq = copy_seq + 1
            local dest = db_copy_base .. "-" .. copy_seq
            local out = db_backup(path_, dest)
            if out.code ~= 0 then
              async_mod.notify("zotero: failed to copy database before querying", vim.log.levels.ERROR)
              return
            end
            local old = db_copy
            db_copy = dest
            db_last_mtime = m
            db_last_wal_mtime = w
            data_version = data_version + 1
            if old then
              vim.defer_fn(function()
                for _, suffix in ipairs({ "", "-wal", "-shm" }) do
                  pcall(vim.uv.fs_unlink, old .. suffix)
                end
              end, 60000)
            end
          end)
          if not ok then
            async_mod.notify("zotero: failed to copy database before querying", vim.log.levels.ERROR)
          end
        end
      end)
    end)
  end
  async_mod.await(copy_task)
  copy_task = nil
  return db_copy
end

local function sync_cache_epoch()
  if _cache_mtime ~= db_last_mtime or _cache_wal_mtime ~= db_last_wal_mtime then
    _cache = {}
    _cache_mtime = db_last_mtime
    _cache_wal_mtime = db_last_wal_mtime
  end
end

-- Also refreshes the DB copy, so callers get a fresh dbfile to pass into
-- json_query()/raw_query() instead of each one re-deriving it.
local function cache_key(spec)
  local dbfile = ensure_db_copy()
  return dbfile, tostring(db_last_mtime) .. "|" .. tostring(db_last_wal_mtime or 0) .. "|" .. spec
end

local function cache_get(key)
  sync_cache_epoch()
  local v = _cache[key]
  if v ~= nil then
    return v, true
  end
  return nil, false
end

local function cache_set(key, value)
  -- Re-check: the query itself may have yielded while the live DB changed.
  ensure_db_copy()
  sync_cache_epoch()
  _cache[key] = value
end

function M.invalidate_cache()
  _cache = {}
  _cache_mtime = nil
  _cache_wal_mtime = nil
  -- Force the temp copy to refresh on the next query so in-plugin writes are
  -- visible immediately (previously only relied on the live file mtime).
  db_last_mtime = nil
  db_last_wal_mtime = nil
  data_version = data_version + 1
end

function M.get_data_version()
  return data_version
end

-- Synchronous, main-thread-safe staleness probe: whether the data behind a
-- render captured at `version` may differ from the current live DB. Detects
-- both in-plugin invalidations and edits made by Zotero itself (mtime change on
-- the main file or the -wal sidecar). Never copies or queries, so it is safe to
-- call without yielding.
function M.is_stale_since(version)
  local stat = vim.uv.fs_stat(cfg().db_path)
  local mtime = stat and stat.mtime.sec or -1
  local wmtime = wal_mtime(cfg().db_path)
  return mtime ~= db_last_mtime or wmtime ~= (db_last_wal_mtime or 0) or data_version > (version or 0)
end

-- Coerce a value used as a bare (unquoted) numeric literal in a hand-built SQL
-- string to an actual integer, raising instead of interpolating an arbitrary
-- string if it isn't one. All current callers only ever pass IDs read back
-- from this same database, so this should never trip in practice; it's a
-- defensive boundary check against a future caller passing untrusted input.
local function sql_int(n)
  n = tonumber(n)
  if not n then
    error("zotero.db: expected a numeric id, got " .. tostring(n), 0)
  end
  return string.format("%d", n)
end

local function json_query(sql, dbfile)
  dbfile = dbfile or ensure_db_copy()
  if not dbfile then
    return {}
  end
  local out = async_mod.sqlite(dbfile, { "-json", sql })
  if out.code ~= 0 then
    async_mod.notify("zotero: sqlite3 error: " .. (out.stderr ~= "" and out.stderr or "unknown"), vim.log.levels.ERROR)
    return {}
  end
  local result = out.stdout
  if result == "" then
    return {}
  end
  local ok, data = pcall(async_mod.json_decode, result)
  if not ok then
    return {}
  end
  return data
end

local function raw_query(sql, dbfile)
  dbfile = dbfile or ensure_db_copy()
  if not dbfile then
    return ""
  end
  local out = async_mod.sqlite(dbfile, { sql })
  if out.code ~= 0 then
    return ""
  end
  return vim.trim(out.stdout)
end

-- Like raw_query, but decodes the single scalar result as JSON. Used for
-- combined-view queries where one sqlite3 spawn returns a single JSON blob
-- built via json_object()/json_group_array() instead of a row array. Must NOT
-- be run with "-json" (that mode re-escapes a json_object() column as an
-- opaque JSON *string*, double-encoding it) -- raw/plain mode prints the
-- column's TEXT value as-is, which is already the JSON we want.
local function json_scalar_query(sql, dbfile)
  dbfile = dbfile or ensure_db_copy()
  if not dbfile then
    return nil
  end
  local out = async_mod.sqlite(dbfile, { sql })
  if out.code ~= 0 then
    async_mod.notify("zotero: sqlite3 error: " .. (out.stderr ~= "" and out.stderr or "unknown"), vim.log.levels.ERROR)
    return nil
  end
  local result = vim.trim(out.stdout)
  if result == "" then
    return nil
  end
  local ok, data = pcall(async_mod.json_decode, result)
  if not ok then
    return nil
  end
  return data
end

local FIELD_IDS = {
  title = 1,
  abstractNote = 2,
  date = 6,
  url = 13,
  accessDate = 14,
  rights = 15,
  extra = 16,
  volume = 19,
  place = 21,
  label = 22,
  publisher = 23,
  ISBN = 25,
  pages = 32,
  publicationTitle = 38,
  series = 41,
  seriesNumber = 42,
  edition = 43,
  numPages = 44,
  DOI = 59,
  citationKey = 64,
  issue = 76,
  journalAbbreviation = 78,
  ISSN = 79,
  section = 30,
  university = 111,
  institution = 104,
  reportNumber = 102,
  reportType = 103,
  thesisType = 110,
  proceedingsTitle = 57,
  conferenceName = 58,
  mapType = 82,
  manuscriptType = 81,
  letterType = 80,
  blogTitle = 37,
  websiteTitle = 113,
  websiteType = 39,
  encyclopediaTitle = 67,
  dictionaryTitle = 65,
  programTitle = 100,
  network = 101,
  episodeNumber = 95,
  audioFileType = 96,
  caseName = 46,
  court = 47,
  dateDecided = 48,
  docketNumber = 49,
  reporter = 50,
  reporterVolume = 51,
  firstPage = 52,
  patentNumber = 87,
  filingDate = 88,
  issueDate = 91,
  assignee = 85,
  issuingAuthority = 86,
  PMID = 120,
  PMCID = 121,
}

local ACCENT_MAP = {
  ["š"] = "s", ["č"] = "c", ["ž"] = "z", ["ř"] = "r",
  ["ď"] = "d", ["ť"] = "t", ["ň"] = "n",
  ["Š"] = "S", ["Č"] = "C", ["Ž"] = "Z", ["Ř"] = "R",
  ["Ď"] = "D", ["Ť"] = "T", ["Ň"] = "N",
  ["ş"] = "s", ["Ş"] = "S", ["ç"] = "c", ["Ç"] = "C",
  ["ñ"] = "n", ["Ñ"] = "N", ["ã"] = "a", ["Ã"] = "A", ["õ"] = "o", ["Õ"] = "O",
  ["á"] = "a", ["à"] = "a", ["â"] = "a", ["Á"] = "A", ["À"] = "A", ["Â"] = "A",
  ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["É"] = "E", ["È"] = "E", ["Ê"] = "E",
  ["í"] = "i", ["ì"] = "i", ["î"] = "i", ["Í"] = "I", ["Ì"] = "I", ["Î"] = "I",
  ["ó"] = "o", ["ò"] = "o", ["ô"] = "o", ["Ó"] = "O", ["Ò"] = "O", ["Ô"] = "O",
  ["ú"] = "u", ["ù"] = "u", ["û"] = "u", ["Ú"] = "U", ["Ù"] = "U", ["Û"] = "U",
  ["ý"] = "y", ["Ý"] = "Y",
  ["ä"] = "a", ["Ä"] = "A", ["ë"] = "e", ["Ë"] = "E",
  ["ï"] = "i", ["Ï"] = "I", ["ö"] = "o", ["Ö"] = "O", ["ü"] = "u", ["Ü"] = "U",
  ["ÿ"] = "y",
  ["å"] = "a", ["Å"] = "A",
  ["ø"] = "o", ["Ø"] = "O", ["ł"] = "l", ["Ł"] = "L",
  ["ð"] = "d", ["Ð"] = "D", ["þ"] = "th", ["Þ"] = "TH",
  ["ĳ"] = "ij", ["Ĳ"] = "IJ",
  ["ă"] = "a", ["Ă"] = "A",
  ["ő"] = "o", ["Ő"] = "O", ["ű"] = "u", ["Ű"] = "U",
}

local ACCENT_MAP_VALUES
do
  local rows = {}
  local rn = 0
  for acc, ascii in pairs(ACCENT_MAP) do
    rows[#rows + 1] = string.format("(%d,'%s','%s')", rn, types.escape_sql(acc), types.escape_sql(ascii))
    rn = rn + 1
  end
  ACCENT_MAP_VALUES = table.concat(rows, ",")
end

-- A recursive CTE, not nested REPLACE() calls: a flat ~70-deep chain can
-- overflow some sqlite3 builds' parser stack (confirmed on Ubuntu 3.45.1).
local _deaccent_sql_cache = {}
local function deaccent_sql(column)
  local cached = _deaccent_sql_cache[column]
  if cached then
    return cached
  end
  local expr = string.format(
    [[(
      WITH RECURSIVE
        accent_map(rn, acc, ascii) AS (VALUES %s),
        steps(rn, val) AS (
          SELECT -1, %s
          UNION ALL
          SELECT s.rn + 1, REPLACE(s.val, am.acc, am.ascii)
          FROM steps s JOIN accent_map am ON am.rn = s.rn + 1
        )
      SELECT val FROM steps ORDER BY rn DESC LIMIT 1
    )]],
    ACCENT_MAP_VALUES, column
  )
  _deaccent_sql_cache[column] = expr
  return expr
end

-- Same folding as deaccent_sql, applied to a search word instead of a
-- column, so the fallback LIKE path is accent-insensitive in both
-- directions (deaccent_sql(col) alone only normalizes the content side).
local function deaccent_word(w)
  for acc, ascii in pairs(ACCENT_MAP) do
    w = w:gsub(acc, ascii)
  end
  return w
end

-- Probes whether the local sqlite3 binary supports the FTS5 trigram
-- tokenizer (with accent-folding), which the search index below relies on.
-- Run once against a throwaway :memory: database -- never touches the real
-- copy -- and cached for the whole Neovim session, since the binary's
-- capabilities can't change mid-session.
local function detect_fts5()
  if _fts5_available ~= nil then
    return _fts5_available
  end
  local out = async_mod.sys({
    "sqlite3", ":memory:",
    "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram');",
  })
  _fts5_available = out.code == 0
  return _fts5_available
end

-- Builds (or reuses) a precomputed FTS5 trigram search index inside the
-- private DB copy: one row per item, one column per searchable field (so
-- `author:` etc. can MATCH a single column), with accents folded in by
-- `remove_diacritics`. Several creators/tags are joined with "; " so a
-- phrase can't run from one name into the next.
-- A second table, zn_notes, holds one row per note / annotation keyed on the
-- top-level item it belongs to, for `note:` searches.
-- Rebuilt lazily (only when a search actually runs, once per copy),
-- mirroring the copy_task/copy_lock single-flight pattern in
-- ensure_db_copy(). The index lives inside the copy, so it is keyed on the
-- copy's path: every re-copy is a new file and gets its index rebuilt.
local function ensure_search_index(dbfile)
  if not detect_fts5() then
    return false
  end
  if index_built_in == dbfile then
    return true
  end
  if not index_task then
    index_task = async_mod.run("zotero:db-index-build", function()
      index_lock:with(function()
        if index_built_in == dbfile then
          return
        end
        local build_sql = string.format(
          [[
          DROP TABLE IF EXISTS zn_search;
          CREATE VIRTUAL TABLE zn_search USING fts5(
            itemid UNINDEXED, title, pub, abstract, date, creators, tags, doi, citekey,
            tokenize='trigram remove_diacritics 1'
          );
          INSERT INTO zn_search(itemid, title, pub, abstract, date, creators, tags, doi, citekey)
          SELECT i.itemID, t.value, p.value, ab.value, dt.value, cr.names, tg.names, doi.value, ck.value
          FROM items i
          LEFT JOIN (SELECT id.itemID, dv.value FROM itemData id JOIN itemDataValues dv ON id.valueID=dv.valueID WHERE id.fieldID=%d) t  ON t.itemID = i.itemID
          LEFT JOIN (SELECT id.itemID, dv.value FROM itemData id JOIN itemDataValues dv ON id.valueID=dv.valueID WHERE id.fieldID=%d) p  ON p.itemID = i.itemID
          LEFT JOIN (SELECT id.itemID, dv.value FROM itemData id JOIN itemDataValues dv ON id.valueID=dv.valueID WHERE id.fieldID=%d) ab ON ab.itemID = i.itemID
          LEFT JOIN (SELECT id.itemID, dv.value FROM itemData id JOIN itemDataValues dv ON id.valueID=dv.valueID WHERE id.fieldID=%d) dt ON dt.itemID = i.itemID
          LEFT JOIN (SELECT id.itemID, dv.value FROM itemData id JOIN itemDataValues dv ON id.valueID=dv.valueID WHERE id.fieldID=%d) doi ON doi.itemID = i.itemID
          LEFT JOIN (SELECT id.itemID, dv.value FROM itemData id JOIN itemDataValues dv ON id.valueID=dv.valueID WHERE id.fieldID=%d) ck ON ck.itemID = i.itemID
          LEFT JOIN (
            SELECT ic.itemID, group_concat(TRIM(COALESCE(c.firstName,'') || ' ' || COALESCE(c.lastName,'')), '; ') AS names
            FROM itemCreators ic JOIN creators c ON ic.creatorID = c.creatorID GROUP BY ic.itemID
          ) cr ON cr.itemID = i.itemID
          LEFT JOIN (
            SELECT it2.itemID, group_concat(tg2.name, '; ') AS names
            FROM itemTags it2 JOIN tags tg2 ON it2.tagID = tg2.tagID GROUP BY it2.itemID
          ) tg ON tg.itemID = i.itemID;
          DROP TABLE IF EXISTS zn_notes;
          CREATE VIRTUAL TABLE zn_notes USING fts5(itemid UNINDEXED, body, tokenize='trigram remove_diacritics 1');
          INSERT INTO zn_notes(itemid, body)
          SELECT COALESCE(n.parentItemID, n.itemID), n.note FROM itemNotes n WHERE n.note IS NOT NULL
          UNION ALL
          SELECT COALESCE(att.parentItemID, att.itemID), COALESCE(a.text,'') || ' ' || COALESCE(a.comment,'')
          FROM itemAnnotations a JOIN itemAttachments att ON a.parentItemID = att.itemID;
          ]],
          FIELD_IDS.title, FIELD_IDS.publicationTitle, FIELD_IDS.abstractNote, FIELD_IDS.date,
          FIELD_IDS.DOI, FIELD_IDS.citationKey
        )
        local out = async_mod.sqlite(dbfile, { build_sql })
        if out.code ~= 0 then
          async_mod.notify("zotero: failed to build search index, falling back to slower search", vim.log.levels.WARN)
          _fts5_available = false -- stop retrying every search this session
          return
        end
        index_built_in = dbfile
      end)
    end)
  end
  async_mod.await(index_task)
  index_task = nil
  return index_built_in == dbfile
end

local ITEM_TYPES_FILTER = { 1, 3, 28 }

local function item_type_filter()
  local ids = {}
  for _, v in ipairs(ITEM_TYPES_FILTER) do
    ids[#ids + 1] = tostring(v)
  end
  return table.concat(ids, ",")
end

local function not_child(t)
  local p = t and (t .. ".") or ""
  -- Allows regular items AND standalone attachments/notes/annotations --
  -- only excludes ones that are children of another item.
  return p .. "itemID NOT IN (SELECT itemID FROM itemAttachments WHERE parentItemID IS NOT NULL)"
    .. " AND " .. p .. "itemID NOT IN (SELECT itemID FROM itemNotes WHERE parentItemID IS NOT NULL)"
    .. " AND " .. p .. "itemID NOT IN (SELECT itemID FROM itemAnnotations WHERE parentItemID IS NOT NULL)"
end

local function not_trashed()
  return "i.itemID NOT IN (SELECT itemID FROM deletedItems)"
end

-- Zotero keeps the user library, each group and each feed as separate
-- libraries in the same tables. Everything this plugin shows as "My Library"
-- (and everything the connector writes to -- see zotero_plugin/bootstrap.js,
-- which always targets Zotero.Libraries.userLibraryID) is the user library,
-- so queries must be scoped to it or feed/group items leak in. Must be called
-- from inside an async task.
local function user_library_id()
  local dbfile, key = cache_key("user_lib")
  local cached = cache_get(key)
  if cached then
    return cached
  end
  local id = tonumber(raw_query("SELECT libraryID FROM libraries WHERE type = 'user' LIMIT 1", dbfile)) or 1
  cache_set(key, id)
  return id
end

local function in_library(alias, library_id)
  local p = alias and (alias .. ".") or ""
  return p .. "libraryID = " .. sql_int(library_id)
end

-- SQL list literal ('a','b') from a list of item type names.
local function type_list(names)
  local quoted = {}
  for _, n in ipairs(names) do
    quoted[#quoted + 1] = "'" .. types.escape_sql(n) .. "'"
  end
  return "(" .. table.concat(quoted, ",") .. ")"
end

-- ---------------------------------------------------------------------------
-- Search (`ff`): see lua/zotero/search_query.lua for the syntax.

-- `col LIKE '%text%'`, accent-insensitive in both directions: the column is
-- folded by deaccent_sql, the query text by deaccent_word.
local function like_folded(col, text)
  return "(" .. col .. " LIKE '%" .. types.escape_sql(text) .. "%' OR " .. deaccent_sql(col)
    .. " LIKE '%" .. types.escape_sql(deaccent_word(text)) .. "%')"
end

local function item_field_like(field_id, text)
  return "EXISTS (SELECT 1 FROM itemData idf JOIN itemDataValues dvf ON idf.valueID = dvf.valueID"
    .. " WHERE idf.itemID = i.itemID AND idf.fieldID = " .. field_id .. " AND " .. like_folded("dvf.value", text) .. ")"
end

-- The metadata fields a search can be limited to with a prefix
-- (`author:huey`); a plain word matches any of them. `column` is the field's
-- zn_search column, `like` its fallback for when the index can't be used
-- (older sqlite3 builds, a failed index build, a term too short for trigram
-- MATCH). Relies on the t/p/y/k joins of get_items' query.
local META_FIELDS = {
  { scope = "title", column = "title", like = function(x) return like_folded("t.title", x) end },
  { scope = "pub", column = "pub", like = function(x) return like_folded("p.publicationTitle", x) end },
  { scope = "author", column = "creators", like = function(x)
    return "EXISTS (SELECT 1 FROM itemCreators icf JOIN creators cf ON icf.creatorID = cf.creatorID"
      .. " WHERE icf.itemID = i.itemID AND "
      .. like_folded("TRIM(COALESCE(cf.firstName,'') || ' ' || COALESCE(cf.lastName,''))", x) .. ")"
  end },
  { scope = "date", column = "date", like = function(x) return "y.date_str LIKE '" .. types.escape_sql(x) .. "%'" end },
  { scope = "citekey", column = "citekey", like = function(x) return like_folded("k.citationKey", x) end },
  { scope = "abstract", column = "abstract", like = function(x) return item_field_like(FIELD_IDS.abstractNote, x) end },
  { scope = "doi", column = "doi", like = function(x) return item_field_like(FIELD_IDS.DOI, x) end },
  { scope = "tag", column = "tags", like = function(x)
    return "EXISTS (SELECT 1 FROM itemTags itf JOIN tags tf ON itf.tagID = tf.tagID"
      .. " WHERE itf.itemID = i.itemID AND " .. like_folded("tf.name", x) .. ")"
  end },
}
local META_BY_SCOPE = {}
for _, f in ipairs(META_FIELDS) do
  META_BY_SCOPE[f.scope] = f
end

-- MATCH (not LIKE) against the index: remove_diacritics only folds accents
-- for the MATCH/tokenizer path. Wrapped as a quoted FTS5 phrase so
-- punctuation/operators are treated literally; `column` limits it to one
-- field.
local function index_match(text, column)
  local phrase = '"' .. text:gsub('"', '""') .. '"'
  if column then
    phrase = column .. " : " .. phrase
  end
  return "i.itemID IN (SELECT itemid FROM zn_search WHERE zn_search MATCH '" .. types.escape_sql(phrase) .. "')"
end

-- A metadata term: one field (`field` from META_FIELDS) or, with nil, any of
-- them plus an exact item-key match.
local function meta_predicate(text, use_index, field)
  local pred
  if use_index and vim.fn.strchars(text) >= 3 then
    pred = index_match(text, field and field.column)
  elseif field then
    pred = field.like(text)
  else
    local ors = {}
    for _, f in ipairs(META_FIELDS) do
      ors[#ors + 1] = f.like(text)
    end
    pred = "(" .. table.concat(ors, " OR ") .. ")"
  end
  -- Zotero item keys are 8 upper-case alphanumerics; match one exactly, as
  -- Zotero's own quick search does.
  if not field and text:match("^%w%w%w%w%w%w%w%w$") then
    pred = "(" .. pred .. " OR i.key = '" .. text:upper() .. "')"
  end
  return pred
end

-- `year:2019` or a range, `year:2010-2020` (either end may be left open:
-- `year:2015-`, `year:-1990`). Anything else is matched against the start
-- of the date.
local function year_predicate(text)
  local from, to = text:match("^(%d*)%-(%d*)$")
  if from and (from ~= "" or to ~= "") then
    local conds = {}
    if from ~= "" then
      conds[#conds + 1] = "y.year >= " .. sql_int(from)
    end
    if to ~= "" then
      conds[#conds + 1] = "y.year <= " .. sql_int(to)
    end
    return table.concat(conds, " AND ")
  end
  return "y.date_str LIKE '" .. types.escape_sql(text) .. "%'"
end

-- Child notes and PDF annotations (text and comment), matched to the
-- top-level item they belong to. A standalone note matches itself.
local function note_predicate(text, use_index)
  if use_index and vim.fn.strchars(text) >= 3 then
    local phrase = '"' .. text:gsub('"', '""') .. '"'
    return "i.itemID IN (SELECT itemid FROM zn_notes WHERE zn_notes MATCH '" .. types.escape_sql(phrase) .. "')"
  end
  local like = "LIKE '%" .. types.escape_sql(text) .. "%'"
  return "i.itemID IN (SELECT COALESCE(n.parentItemID, n.itemID) FROM itemNotes n WHERE n.note " .. like .. ")"
    .. " OR i.itemID IN (SELECT COALESCE(att.parentItemID, att.itemID) FROM itemAnnotations a"
    .. " JOIN itemAttachments att ON a.parentItemID = att.itemID"
    .. " WHERE a.text " .. like .. " OR a.comment " .. like .. ")"
end

-- Zotero keeps the full text of indexed PDFs in a separate database next to
-- zotero.sqlite: an FTS5 table whose rowid is the attachment's itemID. Zotero
-- holds a lock on it, so it's opened `immutable` (read without locking);
-- a read that races one of Zotero's writes just errors and matches nothing.
local _fulltext_warned = false
local function fulltext_attachment_ids(value)
  local path = vim.fs.joinpath(vim.fs.dirname(cfg().db_path), "fulltext.sqlite")
  local function warn(msg)
    if not _fulltext_warned then
      _fulltext_warned = true
      async_mod.notify("zotero: " .. msg, vim.log.levels.WARN)
    end
  end
  if not vim.uv.fs_stat(path) then
    warn("no full-text index (" .. path .. "); ft: matches nothing")
    return {}
  end
  local uri = "file:" .. path:gsub("[%%?#]", function(c) return string.format("%%%02X", c:byte()) end) .. "?immutable=1"
  -- A bare word also matches as a prefix (`clim` finds "climate"), like
  -- Zotero's own full-text search; a quoted phrase must match exactly.
  local match = '"' .. value.text:gsub('"', '""') .. '"' .. (value.phrase and "" or "*")
  local out = async_mod.sqlite(uri, {
    "SELECT rowid FROM fulltextContent WHERE fulltextContent MATCH '" .. types.escape_sql(match) .. "'",
  })
  if out.code ~= 0 then
    warn("full-text search failed: " .. vim.trim(out.stderr or ""))
    return {}
  end
  local ids = {}
  for id in out.stdout:gmatch("%d+") do
    ids[#ids + 1] = id
  end
  return ids
end

local function fulltext_predicate(value)
  local ids = fulltext_attachment_ids(value)
  if #ids == 0 then
    return "0"
  end
  return "i.itemID IN (SELECT COALESCE(fa.parentItemID, fa.itemID) FROM itemAttachments fa WHERE fa.itemID IN ("
    .. table.concat(ids, ",") .. "))"
end

-- The WHERE fragment for a search string, or nil when it has no terms.
-- Relies on the t/p/y/k joins of get_items' query. Every term is wrapped in
-- COALESCE(…, 0) so a NULL column can't turn `NOT` into "exclude everything".
-- `dbfile` must be the copy the query will run against, since the index
-- lives inside it.
local function search_clause(search_term, dbfile)
  local groups = search_query.parse(search_term)
  if #groups == 0 then
    return nil
  end
  local use_index = dbfile and ensure_search_index(dbfile)
  local ands = {}
  for _, group in ipairs(groups) do
    local ors = {}
    for _, term in ipairs(group) do
      -- `author:"huey OR kearney"`: one term, several values, any of which
      -- may match (and `-` leaves out all of them).
      local alts = {}
      for _, value in ipairs(term.values) do
        local pred
        if term.scope == "ft" then
          pred = fulltext_predicate(value)
        elseif term.scope == "note" then
          pred = note_predicate(value.text, use_index)
        elseif term.scope == "year" then
          pred = year_predicate(value.text)
        else
          pred = meta_predicate(value.text, use_index, META_BY_SCOPE[term.scope])
        end
        alts[#alts + 1] = "(" .. pred .. ")"
      end
      local pred = "COALESCE((" .. table.concat(alts, " OR ") .. "), 0)"
      ors[#ors + 1] = term.negate and ("NOT " .. pred) or pred
    end
    ands[#ands + 1] = "(" .. table.concat(ors, " OR ") .. ")"
  end
  return "(" .. table.concat(ands, " AND ") .. ")"
end

function M.get_stats()
  return async_mod.run("zotero:db.get_stats", function()
    local dbfile, key = cache_key("stats")
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local lib = user_library_id()
    local collections = raw_query("SELECT COUNT(*) FROM collections WHERE " .. in_library(nil, lib), dbfile)
    local items = raw_query("SELECT COUNT(*) FROM items WHERE (" .. not_child(nil) .. ") AND itemID NOT IN (SELECT itemID FROM deletedItems) AND "
      .. in_library(nil, lib), dbfile)
    local result = {
      collections = tonumber(collections) or 0,
      items = tonumber(items) or 0,
    }
    cache_set(key, result)
    return result
  end)
end

function M.get_collections()
  return async_mod.run("zotero:db.get_collections", function()
    local dbfile, key = cache_key("collections")
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local sql = [[
      WITH RECURSIVE col_tree AS (
        SELECT
          collectionID,
          collectionName,
          parentCollectionID,
          key,
          collectionName AS path,
          0 AS depth
        FROM collections
        WHERE parentCollectionID IS NULL AND ]] .. in_library(nil, user_library_id()) .. [[
        UNION ALL
        SELECT
          c.collectionID,
          c.collectionName,
          c.parentCollectionID,
          c.key,
          ct.path || ' / ' || c.collectionName,
          ct.depth + 1
        FROM collections c
        JOIN col_tree ct ON c.parentCollectionID = ct.collectionID
      ),
      item_counts AS (
        SELECT ci.collectionID, COUNT(*) AS cnt
        FROM collectionItems ci
        JOIN items i ON ci.itemID = i.itemID
        WHERE ]] .. not_child("i") .. [[
          AND i.itemID NOT IN (SELECT itemID FROM deletedItems)
        GROUP BY ci.collectionID
      )
      SELECT
        ct.collectionID,
        ct.collectionName,
        ct.parentCollectionID,
        ct.key,
        ct.depth,
        COALESCE(ic.cnt, 0) AS item_count
      FROM col_tree ct
      LEFT JOIN item_counts ic ON ct.collectionID = ic.collectionID
      ORDER BY ct.path COLLATE NOCASE
    ]]
    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

local function sort_order(sort_by, sort_dir)
  local order = "i.itemID"
  if sort_by == "title" then
    order = "t.title COLLATE NOCASE DESC"
  elseif sort_by == "year" then
    order = "y.year DESC, t.title COLLATE NOCASE"
  elseif sort_by == "type" then
    order = "it.typeName DESC"
  elseif sort_by == "dateAdded" then
    order = "i.dateAdded DESC"
  end
  if sort_dir == "asc" then
    order = order:gsub(" DESC", "") .. " ASC"
  end
  return order
end

-- opts (all optional):
--   library_id     library to list (default: the user library); pass a feed's
--                  libraryID to list that feed's items
--   exclude_types  list of itemTypes.typeName to hide
--   include_types  list of itemTypes.typeName to show exclusively
function M.get_items(collection_id, search_term, sort_by, sort_dir, limit_override, opts)
  opts = opts or {}
  return async_mod.run("zotero:db.get_items", function()
    local library_id = opts.library_id or user_library_id()
    local where = not_child("i") .. " AND " .. not_trashed() .. " AND " .. in_library("i", library_id)

    local include_types = opts.include_types or {}
    local exclude_types = opts.exclude_types or {}
    if #include_types > 0 then
      where = where .. " AND it.typeName IN " .. type_list(include_types)
    end
    if #exclude_types > 0 then
      where = where .. " AND it.typeName NOT IN " .. type_list(exclude_types)
    end
    -- Tag filter: the item must have every listed tag (Zotero's tag-selector
    -- logic).
    local tags = opts.tags or {}
    for _, tag in ipairs(tags) do
      where = where .. " AND i.itemID IN (SELECT itg.itemID FROM itemTags itg JOIN tags tg ON itg.tagID = tg.tagID"
        .. " WHERE tg.name = '" .. types.escape_sql(tag) .. "')"
    end

    if collection_id then
      where = where .. " AND ci.collectionID = " .. sql_int(collection_id)
    end

    -- Checked before building the search clause: an `ft:` term queries the
    -- full-text database, which a cache hit shouldn't redo.
    local limit = limit_override or cfg().max_items
    local dbfile, key = cache_key("items|" .. tostring(collection_id) .. "|" .. tostring(search_term)
      .. "|" .. tostring(sort_by) .. "|" .. tostring(sort_dir) .. "|" .. tostring(limit)
      .. "|" .. tostring(library_id) .. "|+" .. table.concat(include_types, ",")
      .. "|-" .. table.concat(exclude_types, ",") .. "|#" .. table.concat(tags, "\31"))
    local cached = cache_get(key)
    if cached then
      return cached
    end

    if search_term and search_term ~= "" then
      local clause = search_clause(search_term, dbfile)
      if clause then
        where = where .. " AND " .. clause
      end
    end

    local order = sort_order(sort_by, sort_dir)

    local join = collection_id and "JOIN collectionItems ci ON i.itemID = ci.itemID" or ""

    local sql = [[
      SELECT i.itemID, i.itemTypeID, it.typeName, i.dateAdded,
        t.title,
        y.year,
        y.date_str,
        k.citationKey,
        p.publicationTitle,
        CASE WHEN fi.itemID IS NULL THEN NULL WHEN fi.readTime IS NULL THEN 1 ELSE 0 END AS unread
      FROM items i
      JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
      LEFT JOIN feedItems fi ON i.itemID = fi.itemID
      ]] .. join .. [[
      LEFT JOIN (
        SELECT id.itemID, dv.value AS title
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.title .. [[
      ) t ON i.itemID = t.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS date_str,
          CAST(substr(dv.value, 1, 4) AS INTEGER) AS year
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.date .. [[
      ) y ON i.itemID = y.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS citationKey
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.citationKey .. [[
      ) k ON i.itemID = k.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS publicationTitle
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.publicationTitle .. [[
      ) p ON i.itemID = p.itemID
      WHERE ]] .. where .. [[
      ORDER BY ]] .. order .. [[
      LIMIT ]] .. tostring(limit) .. [[
    ]]

    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

function M.get_trash_items(sort_by, sort_dir, limit_override)
  return async_mod.run("zotero:db.get_trash_items", function()
    local order = sort_order(sort_by, sort_dir)
    local lib = user_library_id()

    local limit = limit_override or cfg().max_items

    local sql = [[
      SELECT i.itemID, i.itemTypeID, it.typeName, i.dateAdded,
        t.title,
        y.year,
        y.date_str,
        k.citationKey,
        p.publicationTitle,
        0 AS _is_collection,
        '' AS _trash_key
      FROM items i
      JOIN deletedItems d ON i.itemID = d.itemID
      JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS title
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.title .. [[
      ) t ON i.itemID = t.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS date_str,
          CAST(substr(dv.value, 1, 4) AS INTEGER) AS year
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.date .. [[
      ) y ON i.itemID = y.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS citationKey
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.citationKey .. [[
      ) k ON i.itemID = k.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS publicationTitle
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = ]] .. FIELD_IDS.publicationTitle .. [[
      ) p ON i.itemID = p.itemID
      WHERE ]] .. not_child("i") .. [[ AND ]] .. in_library("i", lib) .. [[

      UNION ALL

      SELECT
        -c.collectionID AS itemID,
        0 AS itemTypeID,
        'Collection' AS typeName,
        0 AS dateAdded,
        c.collectionName AS title,
        NULL AS year,
        NULL AS date_str,
        NULL AS citationKey,
        NULL AS publicationTitle,
        1 AS _is_collection,
        c.key AS _trash_key
      FROM deletedCollections dc
      JOIN collections c ON dc.collectionID = c.collectionID
      WHERE ]] .. in_library("c", lib) .. [[

      ORDER BY ]] .. order .. [[
      LIMIT ]] .. tostring(limit) .. [[
    ]]

    local dbfile, key = cache_key("trash|" .. tostring(sort_by) .. "|" .. tostring(sort_dir) .. "|" .. tostring(limit))
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

function M.get_trash_count()
  return async_mod.run("zotero:db.get_trash_count", function()
    local dbfile, key = cache_key("trash_count")
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local lib = user_library_id()
    local item_count = raw_query("SELECT COUNT(*) FROM items i JOIN deletedItems d ON i.itemID = d.itemID WHERE ("
      .. not_child("i") .. ") AND " .. in_library("i", lib), dbfile)
    local col_count = raw_query("SELECT COUNT(*) FROM deletedCollections dc JOIN collections c ON dc.collectionID = c.collectionID WHERE "
      .. in_library("c", lib), dbfile)
    local result = (tonumber(item_count) or 0) + (tonumber(col_count) or 0)
    cache_set(key, result)
    return result
  end)
end

function M.get_item_authors(item_id)
  return async_mod.run("zotero:db.get_item_authors", function()
    local sql = [[
      SELECT ic.itemID, c.firstName, c.lastName, c.fieldMode, ct.creatorType, ic.orderIndex
      FROM itemCreators ic
      JOIN creators c ON ic.creatorID = c.creatorID
      JOIN creatorTypes ct ON ic.creatorTypeID = ct.creatorTypeID
      WHERE ic.itemID = ]] .. sql_int(item_id) .. [[
      ORDER BY ic.orderIndex
    ]]
    return json_query(sql)
  end)
end

-- Zotero's colored tags ("Assign Colour" in its tag selector): a list of
-- { name, color } for the user library, in key order (1-9). Stored by Zotero
-- as JSON in syncedSettings.tagColors.
function M.get_colored_tags()
  return async_mod.run("zotero:db.get_colored_tags", function()
    local dbfile, key = cache_key("colored_tags")
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local rows = json_query("SELECT value FROM syncedSettings WHERE setting = 'tagColors' AND "
      .. in_library(nil, user_library_id()), dbfile)
    local result = {}
    local ok, list = pcall(async_mod.json_decode, rows[1] and rows[1].value or "[]")
    if ok and type(list) == "table" then
      for _, t in ipairs(list) do
        if type(t) == "table" and type(t.name) == "string" and #result < 9 then
          result[#result + 1] = { name = t.name, color = type(t.color) == "string" and t.color or nil }
        end
      end
    end
    cache_set(key, result)
    return result
  end)
end

-- Which of `names` each of `item_ids` has: itemID -> { name = true, ... }.
-- One query for the whole visible list (used for the colored-tag dots).
function M.get_items_tags(item_ids, names)
  return async_mod.run("zotero:db.get_items_tags", function()
    if not item_ids or #item_ids == 0 or not names or #names == 0 then
      return {}
    end
    local ids = table.concat(vim.tbl_map(sql_int, item_ids), ",")
    local sql = "SELECT itg.itemID, tg.name FROM itemTags itg JOIN tags tg ON itg.tagID = tg.tagID"
      .. " WHERE itg.itemID IN (" .. ids .. ") AND tg.name IN " .. type_list(names)
    local dbfile, key = cache_key("items_tags|" .. ids .. "|" .. table.concat(names, "\31"))
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local map = {}
    for _, r in ipairs(json_query(sql, dbfile)) do
      map[r.itemID] = map[r.itemID] or {}
      map[r.itemID][r.name] = true
    end
    cache_set(key, map)
    return map
  end)
end

function M.get_items_authors(item_ids)
  return async_mod.run("zotero:db.get_items_authors", function()
    if not item_ids or #item_ids == 0 then
      return {}
    end
    local ids = table.concat(vim.tbl_map(sql_int, item_ids), ",")
    local sql = [[
      SELECT ic.itemID, c.firstName, c.lastName, c.fieldMode, ct.creatorType, ic.orderIndex
      FROM itemCreators ic
      JOIN creators c ON ic.creatorID = c.creatorID
      JOIN creatorTypes ct ON ic.creatorTypeID = ct.creatorTypeID
      WHERE ic.itemID IN (]] .. ids .. [[)
      ORDER BY ic.itemID, ic.orderIndex
    ]]
    local dbfile, key = cache_key("authors|" .. ids)
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

function M.get_item_metadata(item_id)
  return async_mod.run("zotero:db.get_item_metadata", function()
    local sql = [[
      SELECT f.fieldName, dv.value
      FROM itemData id
      JOIN fields f ON id.fieldID = f.fieldID
      JOIN itemDataValues dv ON id.valueID = dv.valueID
      WHERE id.itemID = ]] .. sql_int(item_id) .. [[
    ]]
    return json_query(sql)
  end)
end

function M.get_item_tags(item_id)
  return async_mod.run("zotero:db.get_item_tags", function()
    local sql = [[
      SELECT t.name
      FROM itemTags itag
      JOIN tags t ON itag.tagID = t.tagID
      WHERE itag.itemID = ]] .. sql_int(item_id) .. [[
      ORDER BY t.name
    ]]
    return json_query(sql)
  end)
end

function M.get_item_notes(item_id)
  return async_mod.run("zotero:db.get_item_notes", function()
    local sql = [[
      SELECT i.itemID, n.title, n.note
      FROM items i
      JOIN itemNotes n ON i.itemID = n.itemID
      WHERE n.parentItemID = ]] .. sql_int(item_id) .. [[
      ORDER BY i.dateAdded
    ]]
    return json_query(sql)
  end)
end

function M.get_item_attachments(item_id)
  return async_mod.run("zotero:db.get_item_attachments", function()
    local sql = [[
      SELECT i.itemID, i.key, a.linkMode, a.contentType, a.path,
        COALESCE(t.value, a.path) AS title
      FROM items i
      JOIN itemAttachments a ON i.itemID = a.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = 1
      ) t ON i.itemID = t.itemID
      WHERE a.parentItemID = ]] .. sql_int(item_id) .. [[
      ORDER BY i.dateAdded
    ]]
    return json_query(sql)
  end)
end

function M.get_attachment(item_id)
  return async_mod.run("zotero:db.get_attachment", function()
    local sql = [[
      SELECT i.itemID, i.key, a.linkMode, a.contentType, a.path,
        COALESCE(t.value, a.path) AS title
      FROM items i
      JOIN itemAttachments a ON i.itemID = a.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = 1
      ) t ON i.itemID = t.itemID
      WHERE i.itemID = ]] .. sql_int(item_id) .. [[
    ]]
    local results = json_query(sql)
    return results[1]
  end)
end

function M.resolve_attachment_path(attachment)
  local path = attachment.path or ""
  if path == "" then
    return nil
  end

  local home = vim.uv.os_homedir()

  local function exists(p)
    return vim.uv.fs_stat(p) ~= nil
  end

  local storage_dir = home .. "/Zotero/storage"
  local full_path = nil

  if path:find("^storage:") then
    local rel = path:sub(9)
    if attachment.key then
      local candidate = storage_dir .. "/" .. attachment.key .. "/" .. rel
      if exists(candidate) then
        full_path = candidate
      end
    end
    if not full_path then
      local candidate = storage_dir .. "/" .. rel
      if exists(candidate) then
        full_path = candidate
      end
    end
  elseif path:find("^attachments:") then
    local rel = path:sub(13)
    full_path = home .. "/Zotero/" .. rel
    if not exists(full_path) then
      full_path = nil
    end
  else
    full_path = path:gsub("^~", home)
    if not exists(full_path) then
      full_path = nil
    end
  end

  return full_path
end

function M.get_item_detail(item_id)
  return async_mod.run("zotero:db.get_item_detail", function()
    local id = sql_int(item_id)
    -- One combined query (one sqlite3 spawn) instead of 5 separate spawns for
    -- metadata/authors/tags/notes/attachments. Each sub-select below is the
    -- same body as get_item_metadata/get_item_authors/get_item_tags/
    -- get_item_notes/get_item_attachments, just wrapped for json_object().
    local sql = [[
      SELECT json_object(
        'metadata', COALESCE((
          SELECT json_group_array(json_object('fieldName', fieldName, 'value', value))
          FROM (
            SELECT f.fieldName AS fieldName, dv.value AS value
            FROM itemData id
            JOIN fields f ON id.fieldID = f.fieldID
            JOIN itemDataValues dv ON id.valueID = dv.valueID
            WHERE id.itemID = ]] .. id .. [[
          )
        ), json_array()),
        'authors', COALESCE((
          SELECT json_group_array(json_object(
            'itemID', itemID, 'firstName', firstName, 'lastName', lastName,
            'fieldMode', fieldMode, 'creatorType', creatorType, 'orderIndex', orderIndex
          ))
          FROM (
            SELECT ic.itemID AS itemID, c.firstName AS firstName, c.lastName AS lastName,
              c.fieldMode AS fieldMode, ct.creatorType AS creatorType, ic.orderIndex AS orderIndex
            FROM itemCreators ic
            JOIN creators c ON ic.creatorID = c.creatorID
            JOIN creatorTypes ct ON ic.creatorTypeID = ct.creatorTypeID
            WHERE ic.itemID = ]] .. id .. [[
            ORDER BY ic.orderIndex
          )
        ), json_array()),
        'tags', COALESCE((
          SELECT json_group_array(json_object('name', name))
          FROM (
            SELECT t.name AS name
            FROM itemTags itag
            JOIN tags t ON itag.tagID = t.tagID
            WHERE itag.itemID = ]] .. id .. [[
            ORDER BY t.name
          )
        ), json_array()),
        'notes', COALESCE((
          SELECT json_group_array(json_object('itemID', itemID, 'title', title, 'note', note))
          FROM (
            SELECT i.itemID AS itemID, n.title AS title, n.note AS note
            FROM items i
            JOIN itemNotes n ON i.itemID = n.itemID
            WHERE n.parentItemID = ]] .. id .. [[
            ORDER BY i.dateAdded
          )
        ), json_array()),
        'attachments', COALESCE((
          SELECT json_group_array(json_object(
            'itemID', itemID, 'key', key, 'linkMode', linkMode,
            'contentType', contentType, 'path', path, 'title', title
          ))
          FROM (
            SELECT i.itemID AS itemID, i.key AS key, a.linkMode AS linkMode, a.contentType AS contentType,
              a.path AS path, COALESCE(t.value, a.path) AS title
            FROM items i
            JOIN itemAttachments a ON i.itemID = a.itemID
            LEFT JOIN (
              SELECT id.itemID, dv.value
              FROM itemData id
              JOIN itemDataValues dv ON id.valueID = dv.valueID
              WHERE id.fieldID = 1
            ) t ON i.itemID = t.itemID
            WHERE a.parentItemID = ]] .. id .. [[
            ORDER BY i.dateAdded
          )
        ), json_array())
      )
    ]]

    local data = json_scalar_query(sql)
    if not data then
      return { metadata = {}, authors = {}, tags = {}, notes = {}, attachments = {} }
    end

    local detail = {}
    for _, m in ipairs(data.metadata or {}) do
      detail[m.fieldName] = m.value
    end

    return {
      metadata = detail,
      authors = data.authors or {},
      tags = data.tags or {},
      notes = data.notes or {},
      attachments = data.attachments or {},
    }
  end)
end

-- Item counts per itemTypes.typeName for a view (a collection, a feed's
-- library via library_id, or the whole user library), ignoring any type
-- filter. Feeds the item-type checklist (ft).
-- Tags with item counts (top-level, non-trashed items) for a view: a
-- collection, a feed's library via library_id, or (both nil) the whole user
-- library. Used by the Tags section and the fT checklist.
function M.get_tag_counts(collection_id, library_id)
  return async_mod.run("zotero:db.get_tag_counts", function()
    local lib = library_id or user_library_id()
    local join = collection_id and "JOIN collectionItems ci ON i.itemID = ci.itemID" or ""
    local where = not_child("i") .. " AND " .. not_trashed() .. " AND " .. in_library("i", lib)
    if collection_id then
      where = where .. " AND ci.collectionID = " .. sql_int(collection_id)
    end
    local dbfile, key = cache_key("tag_counts|" .. tostring(collection_id) .. "|" .. tostring(lib))
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local sql = [[
      SELECT tg.name, COUNT(DISTINCT i.itemID) AS count
      FROM items i
      JOIN itemTags itg ON itg.itemID = i.itemID
      JOIN tags tg ON tg.tagID = itg.tagID
      ]] .. join .. [[
      WHERE ]] .. where .. [[
      GROUP BY tg.name
      ORDER BY tg.name COLLATE NOCASE
    ]]
    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

function M.get_type_counts(collection_id, library_id)
  return async_mod.run("zotero:db.get_type_counts", function()
    local lib = library_id or user_library_id()
    local join = collection_id and "JOIN collectionItems ci ON i.itemID = ci.itemID" or ""
    local where = not_child("i") .. " AND " .. not_trashed() .. " AND " .. in_library("i", lib)
    if collection_id then
      where = where .. " AND ci.collectionID = " .. sql_int(collection_id)
    end
    local dbfile, key = cache_key("type_counts|" .. tostring(collection_id) .. "|" .. tostring(lib))
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local sql = [[
      SELECT it.typeName, COUNT(*) AS count
      FROM items i
      JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
      ]] .. join .. [[
      WHERE ]] .. where .. [[
      GROUP BY it.typeName
      ORDER BY count DESC, it.typeName COLLATE NOCASE
    ]]
    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

function M.search_global(search_term, sort_by, sort_dir, limit_override, opts)
  return M.get_items(nil, search_term, sort_by, sort_dir, limit_override, opts)
end

-- One row per subscribed feed (each feed is its own library), with its
-- unread/total item counts. Read state lives in feedItems.readTime.
function M.get_feeds()
  return async_mod.run("zotero:db.get_feeds", function()
    local dbfile, key = cache_key("feeds")
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local sql = [[
      SELECT
        f.libraryID,
        f.name,
        COALESCE(SUM(CASE WHEN i.itemID IS NOT NULL AND fi.readTime IS NULL THEN 1 ELSE 0 END), 0) AS unread,
        COUNT(i.itemID) AS total
      FROM feeds f
      LEFT JOIN items i ON i.libraryID = f.libraryID
        AND i.itemID NOT IN (SELECT itemID FROM deletedItems)
      LEFT JOIN feedItems fi ON fi.itemID = i.itemID
      GROUP BY f.libraryID, f.name
      ORDER BY f.name COLLATE NOCASE
    ]]
    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

function M.get_item_type_name(item_type_id)
  return async_mod.run("zotero:db.get_item_type_name", function()
    return raw_query("SELECT typeName FROM itemTypes WHERE itemTypeID = " .. sql_int(item_type_id))
  end)
end

function M.get_item_type_id(item_id)
  return async_mod.run("zotero:db.get_item_type_id", function()
    return tonumber(raw_query("SELECT itemTypeID FROM items WHERE itemID = " .. sql_int(item_id)))
  end)
end

function M.get_item_key(item_id)
  return async_mod.run("zotero:db.get_item_key", function()
    return raw_query("SELECT key FROM items WHERE itemID = " .. sql_int(item_id))
  end)
end

-- Bulk key lookup: one subprocess spawn instead of one per item. Returns a
-- map of itemID -> key.
function M.get_item_keys(item_ids)
  return async_mod.run("zotero:db.get_item_keys", function()
    if not item_ids or #item_ids == 0 then
      return {}
    end
    local ids = table.concat(vim.tbl_map(sql_int, item_ids), ",")
    local sql = "SELECT itemID, key FROM items WHERE itemID IN (" .. ids .. ")"
    local rows = json_query(sql)
    local map = {}
    for _, r in ipairs(rows) do
      map[r.itemID] = r.key
    end
    return map
  end)
end

function M.get_collection_key(collection_id)
  return async_mod.run("zotero:db.get_collection_key", function()
    return raw_query("SELECT key FROM collections WHERE collectionID = " .. sql_int(collection_id))
  end)
end

function M.get_editable_item(item_id)
  return async_mod.run("zotero:db.get_editable_item", function()
    local id = sql_int(item_id)
    -- One combined query (one sqlite3 spawn) instead of 4 separate spawns for
    -- the header/metadata/authors/tags. A missing item naturally yields zero
    -- outer rows, so json_scalar_query returns nil, matching the old
    -- "header == 0 rows" nil-return case.
    local sql = [[
      SELECT json_object(
        'key', i.key,
        'itemType', it.typeName,
        'fields', COALESCE((
          SELECT json_group_array(json_object('fieldName', fieldName, 'value', value))
          FROM (
            SELECT f.fieldName AS fieldName, dv.value AS value
            FROM itemData id
            JOIN fields f ON id.fieldID = f.fieldID
            JOIN itemDataValues dv ON id.valueID = dv.valueID
            WHERE id.itemID = i.itemID
          )
        ), json_array()),
        'creators', COALESCE((
          SELECT json_group_array(json_object(
            'firstName', firstName, 'lastName', lastName, 'creatorType', creatorType
          ))
          FROM (
            SELECT c.firstName AS firstName, c.lastName AS lastName, ct.creatorType AS creatorType
            FROM itemCreators ic
            JOIN creators c ON ic.creatorID = c.creatorID
            JOIN creatorTypes ct ON ic.creatorTypeID = ct.creatorTypeID
            WHERE ic.itemID = i.itemID
            ORDER BY ic.orderIndex
          )
        ), json_array()),
        'tags', COALESCE((
          SELECT json_group_array(json_object('name', name))
          FROM (
            SELECT t.name AS name
            FROM itemTags itag
            JOIN tags t ON itag.tagID = t.tagID
            WHERE itag.itemID = i.itemID
            ORDER BY t.name
          )
        ), json_array())
      )
      FROM items i
      JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
      WHERE i.itemID = ]] .. id

    local raw = json_scalar_query(sql)
    if not raw then
      return nil
    end

    local data = {
      key = raw.key,
      itemType = raw.itemType,
      fields = {},
      creators = {},
      tags = {},
    }

    for _, m in ipairs(raw.fields or {}) do
      if m.fieldName and m.value and m.value ~= "" then
        data.fields[m.fieldName] = m.value
      end
    end

    for _, a in ipairs(raw.creators or {}) do
      data.creators[#data.creators + 1] = {
        firstName = a.firstName or "",
        lastName = a.lastName or "",
        creatorType = a.creatorType or "author",
      }
    end

    for _, t in ipairs(raw.tags or {}) do
      if t.name and t.name ~= "" then
        data.tags[#data.tags + 1] = t.name
      end
    end

    return data
  end)
end

function M.get_item_type_fields(item_type_id)
  return async_mod.run("zotero:db.get_item_type_fields", function()
    local sql = [[
      SELECT f.fieldName
      FROM itemTypeFields itf
      JOIN fields f ON itf.fieldID = f.fieldID
      WHERE itf.itemTypeID = ]] .. sql_int(item_type_id) .. [[
      ORDER BY f.fieldName
    ]]
    return json_query(sql)
  end)
end

function M.get_all_item_types()
  return async_mod.run("zotero:db.get_all_item_types", function()
    local sql = [[
      SELECT typeName, itemTypeID
      FROM itemTypes
      WHERE itemTypeID NOT IN (]] .. item_type_filter() .. [[)
      ORDER BY typeName COLLATE NOCASE
    ]]
    return json_query(sql)
  end)
end

function M.get_items_by_field_value(field_name, value)
  return async_mod.run("zotero:db.get_items_by_field_value", function()
    local field_id = FIELD_IDS[field_name]
    if not field_id then
      return {}
    end
    local sql = [[
      SELECT i.itemID, i.key, t.value AS title
      FROM itemData id
      JOIN itemDataValues dv ON id.valueID = dv.valueID
      JOIN items i ON id.itemID = i.itemID
      LEFT JOIN (
        SELECT id2.itemID, dv2.value AS value
        FROM itemData id2
        JOIN itemDataValues dv2 ON id2.valueID = dv2.valueID
        WHERE id2.fieldID = 1
      ) t ON i.itemID = t.itemID
      WHERE id.fieldID = ]] .. field_id .. [[
        AND dv.value = ']] .. types.escape_sql(value) .. [['
        AND (]] .. not_child("i") .. [[)
        AND ]] .. not_trashed() .. [[
        AND ]] .. in_library("i", user_library_id()) .. [[
    ]]
    return json_query(sql)
  end)
end

function M.get_item_by_key(key)
  return async_mod.run("zotero:db.get_item_by_key", function()
    local sql = [[
      SELECT i.itemID, i.key, t.value AS title
      FROM items i
      LEFT JOIN (
        SELECT id.itemID, dv.value AS value
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = 1
      ) t ON i.itemID = t.itemID
      WHERE i.key = ']] .. types.escape_sql(key) .. [['
        AND ]] .. in_library("i", user_library_id()) .. [[
    ]]
    local results = json_query(sql)
    return results[1]
  end)
end

function M.get_item_field_value(key, field_name)
  return async_mod.run("zotero:db.get_item_field_value", function()
    local field_id = FIELD_IDS[field_name]
    if not field_id then
      return nil
    end
    local sql = [[
      SELECT dv.value
      FROM itemData id
      JOIN itemDataValues dv ON id.valueID = dv.valueID
      JOIN items i ON id.itemID = i.itemID
      WHERE i.key = ']] .. types.escape_sql(key) .. [['
        AND id.fieldID = ]] .. field_id .. [[
        AND ]] .. in_library("i", user_library_id()) .. [[
    ]]
    local results = json_query(sql)
    if results and #results > 0 then
      return results[1].value
    end
    return nil
  end)
end

function M.get_parent_item_by_attachment_key(attachment_key)
  return async_mod.run("zotero:db.get_parent_item_by_attachment_key", function()
    local sql = [[
      SELECT p.itemID, p.key, t.value AS title
      FROM items a
      JOIN itemAttachments att ON a.itemID = att.itemID
      JOIN items p ON att.parentItemID = p.itemID
      LEFT JOIN (
        SELECT id.itemID, dv.value AS value
        FROM itemData id
        JOIN itemDataValues dv ON id.valueID = dv.valueID
        WHERE id.fieldID = 1
      ) t ON p.itemID = t.itemID
      WHERE a.key = ']] .. types.escape_sql(attachment_key) .. [['
        AND ]] .. in_library("a", user_library_id()) .. [[
    ]]
    local results = json_query(sql)
    return results[1]
  end)
end

return M
