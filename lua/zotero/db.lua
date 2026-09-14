local M = {}

local types = require("zotero.types")
local config_mod = require("zotero.config")
local async_mod = require("zotero.async")

local function cfg()
  return config_mod.get()
end

local db_copy = nil
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

--------------------------------------------------------------------------------
-- Async helpers
--------------------------------------------------------------------------------

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

-- Snapshot the live Zotero sqlite database into the private temp copy. Uses
-- sqlite's online backup so the copy includes un-checkpointed WAL writes; a
-- plain `cp` of the main file alone would miss them (and would capture a hot
-- WAL mid-write if done during a write, yielding a torn, "locked" copy). Falls
-- back to copying the main file (+ -wal sidecar) in case the live database
-- rejects a backup.
--
-- Zotero briefly holds a write lock right after the library is reopened (it
-- starts checkpointing/indexing), so `.backup` must arm a busy timeout and be
-- retried -- otherwise sqlite3 bails with SQLITE_BUSY instantly and we fall
-- into the unsafe raw-copy path, which all concurrent initial queries then
-- read as "database is locked".
local function db_backup(live, dest)
  -- v0.0.2 semantics, kept: one plain copy (main + WAL sidecar), guarded by
  -- mtime upstream. No `.backup`-busy ladder — the CLI `.backup` opens its own
  -- source connection that ignores the shell `.timeout`, so retrying it only
  -- sleeps through a lock it can never wait out (byte-proven). A library at
  -- rest (the normal open-library case) copies consistently on the first
  -- attempt, so this returns immediately.
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
  if not db_copy then
    db_copy = vim.fn.tempname()
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
  -- so the copy always completes before any query runs and the first render
  -- never bakes a torn snapshot. Awaiting here is what fixes the v0.0.2 ->
  -- async migration regression (ordered copy) without the latency: the copy
  -- itself is a single plain `cp` (v0.0.2 speed, immediate at rest), no
  -- busy/validation sleep ladders.
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
            local out = db_backup(path_, db_copy)
            if out.code ~= 0 then
              async_mod.notify("zotero: failed to copy database before querying", vim.log.levels.ERROR)
              return
            end
            db_last_mtime = m
            db_last_wal_mtime = w
            data_version = data_version + 1
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

-- Monotonic version of the currently copied DB data. Bumped on cache
-- invalidation and whenever a fresh copy of the live database is made.
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
  -- Carons (Czech/Slovak/Croatian/Slovenian)
  ["š"] = "s", ["č"] = "c", ["ž"] = "z", ["ř"] = "r",
  ["ď"] = "d", ["ť"] = "t", ["ň"] = "n",
  ["Š"] = "S", ["Č"] = "C", ["Ž"] = "Z", ["Ř"] = "R",
  ["Ď"] = "D", ["Ť"] = "T", ["Ň"] = "N",
  -- Cedillas (Turkish/Romanian/Catalan)
  ["ş"] = "s", ["Ş"] = "S", ["ç"] = "c", ["Ç"] = "C",
  -- Tilde
  ["ñ"] = "n", ["Ñ"] = "N", ["ã"] = "a", ["Ã"] = "A", ["õ"] = "o", ["Õ"] = "O",
  -- Acute/Grave/Circumflex
  ["á"] = "a", ["à"] = "a", ["â"] = "a", ["Á"] = "A", ["À"] = "A", ["Â"] = "A",
  ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["É"] = "E", ["È"] = "E", ["Ê"] = "E",
  ["í"] = "i", ["ì"] = "i", ["î"] = "i", ["Í"] = "I", ["Ì"] = "I", ["Î"] = "I",
  ["ó"] = "o", ["ò"] = "o", ["ô"] = "o", ["Ó"] = "O", ["Ò"] = "O", ["Ô"] = "O",
  ["ú"] = "u", ["ù"] = "u", ["û"] = "u", ["Ú"] = "U", ["Ù"] = "U", ["Û"] = "U",
  ["ý"] = "y", ["Ý"] = "Y",
  -- Umlaut/Diaeresis
  ["ä"] = "a", ["Ä"] = "A", ["ë"] = "e", ["Ë"] = "E",
  ["ï"] = "i", ["Ï"] = "I", ["ö"] = "o", ["Ö"] = "O", ["ü"] = "u", ["Ü"] = "U",
  ["ÿ"] = "y",
  -- Ring
  ["å"] = "a", ["Å"] = "A",
  -- Slash
  ["ø"] = "o", ["Ø"] = "O", ["ł"] = "l", ["Ł"] = "L",
  -- Eth/Thorn
  ["ð"] = "d", ["Ð"] = "D", ["þ"] = "th", ["Þ"] = "TH",
  -- Dutch ĳ
  ["ĳ"] = "ij", ["Ĳ"] = "IJ",
  -- Breve
  ["ă"] = "a", ["Ă"] = "A",
  -- Double acute
  ["ő"] = "o", ["Ő"] = "O", ["ű"] = "u", ["Ű"] = "U",
}

local function deaccent_sql(column)
  local sql = column
  for acc, ascii in pairs(ACCENT_MAP) do
    sql = string.format("REPLACE(%s, '%s', '%s')", sql, acc, ascii)
  end
  return sql
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
  -- Exclude items that are children (have a parentItemID)
  -- This allows regular items AND standalone attachments/notes/annotations
  return p .. "itemID NOT IN (SELECT itemID FROM itemAttachments WHERE parentItemID IS NOT NULL)"
    .. " AND " .. p .. "itemID NOT IN (SELECT itemID FROM itemNotes WHERE parentItemID IS NOT NULL)"
    .. " AND " .. p .. "itemID NOT IN (SELECT itemID FROM itemAnnotations WHERE parentItemID IS NOT NULL)"
end

local function not_trashed()
  return "i.itemID NOT IN (SELECT itemID FROM deletedItems)"
end

function M.get_stats()
  return async_mod.run("zotero:db.get_stats", function()
    local dbfile, key = cache_key("stats")
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local collections = raw_query("SELECT COUNT(*) FROM collections", dbfile)
    local items = raw_query("SELECT COUNT(*) FROM items WHERE (" .. not_child(nil) .. ") AND itemID NOT IN (SELECT itemID FROM deletedItems)", dbfile)
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
        WHERE parentCollectionID IS NULL
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

function M.get_items(collection_id, search_term, sort_by, sort_dir, limit_override)
  return async_mod.run("zotero:db.get_items", function()
    local where = not_child("i") .. " AND " .. not_trashed()
    local params = {}

    if collection_id then
      where = where .. " AND ci.collectionID = " .. tostring(collection_id)
    end

    if search_term and search_term ~= "" then
      local words = {}
      for w in search_term:gmatch("%S+") do
        words[#words + 1] = types.escape_sql(w)
      end
      if #words > 0 then
        local clauses = {}
        for _, escaped in ipairs(words) do
          clauses[#clauses + 1] = [[(
            (t.title LIKE '%]] .. escaped .. [[%' OR ]] .. deaccent_sql("t.title") .. [[ LIKE '%]] .. escaped .. [[%')
            OR (p.publicationTitle LIKE '%]] .. escaped .. [[%' OR ]] .. deaccent_sql("p.publicationTitle") .. [[ LIKE '%]] .. escaped .. [[%')
            OR EXISTS (
              SELECT 1 FROM itemCreators ic2
              JOIN creators c2 ON ic2.creatorID = c2.creatorID
              WHERE ic2.itemID = i.itemID
              AND (c2.lastName LIKE '%]] .. escaped .. [[%'
                OR c2.firstName LIKE '%]] .. escaped .. [[%'
                OR ]] .. deaccent_sql("c2.lastName") .. [[ LIKE '%]] .. escaped .. [[%'
                OR ]] .. deaccent_sql("c2.firstName") .. [[ LIKE '%]] .. escaped .. [[%')
            )
            OR y.date_str LIKE ']] .. escaped .. [[%'
            OR EXISTS (
              SELECT 1 FROM itemData id3
              JOIN itemDataValues dv3 ON id3.valueID = dv3.valueID
              WHERE id3.itemID = i.itemID AND id3.fieldID = ]] .. FIELD_IDS.abstractNote .. [[
              AND (dv3.value LIKE '%]] .. escaped .. [[%' OR ]] .. deaccent_sql("dv3.value") .. [[ LIKE '%]] .. escaped .. [[%')
            )
            OR EXISTS (
              SELECT 1 FROM itemTags it3
              JOIN tags t3 ON it3.tagID = t3.tagID
              WHERE it3.itemID = i.itemID
              AND (t3.name LIKE '%]] .. escaped .. [[%' OR ]] .. deaccent_sql("t3.name") .. [[ LIKE '%]] .. escaped .. [[%')
            )
          )]]
        end
        where = where .. " AND (" .. table.concat(clauses, " AND ") .. ")"
      end
    end

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

    local join = collection_id and "JOIN collectionItems ci ON i.itemID = ci.itemID" or ""

    local limit = limit_override or cfg().max_items

    local sql = [[
      SELECT i.itemID, i.itemTypeID, it.typeName, i.dateAdded,
        t.title,
        y.year,
        y.date_str,
        k.citationKey,
        p.publicationTitle
      FROM items i
      JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
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

    local dbfile, key = cache_key("items|" .. tostring(collection_id) .. "|" .. tostring(search_term)
      .. "|" .. tostring(sort_by) .. "|" .. tostring(sort_dir) .. "|" .. tostring(limit))
    local cached = cache_get(key)
    if cached then
      return cached
    end
    local result = json_query(sql, dbfile)
    cache_set(key, result)
    return result
  end)
end

function M.get_trash_items(sort_by, sort_dir, limit_override)
  return async_mod.run("zotero:db.get_trash_items", function()
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
      WHERE ]] .. not_child("i") .. [[

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
    local item_count = raw_query("SELECT COUNT(*) FROM items i JOIN deletedItems d ON i.itemID = d.itemID WHERE (" .. not_child("i") .. ")", dbfile)
    local col_count = raw_query("SELECT COUNT(*) FROM deletedCollections", dbfile)
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
      WHERE ic.itemID = ]] .. tostring(item_id) .. [[
      ORDER BY ic.orderIndex
    ]]
    return json_query(sql)
  end)
end

function M.get_items_authors(item_ids)
  return async_mod.run("zotero:db.get_items_authors", function()
    if not item_ids or #item_ids == 0 then
      return {}
    end
    local ids = table.concat(vim.tbl_map(tostring, item_ids), ",")
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
      WHERE id.itemID = ]] .. tostring(item_id) .. [[
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
      WHERE itag.itemID = ]] .. tostring(item_id) .. [[
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
      WHERE n.parentItemID = ]] .. tostring(item_id) .. [[
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
      WHERE a.parentItemID = ]] .. tostring(item_id) .. [[
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
      WHERE i.itemID = ]] .. tostring(item_id) .. [[
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
    -- Launched before awaiting so the 5 queries run concurrently.
    local t_metadata = M.get_item_metadata(item_id)
    local t_authors = M.get_item_authors(item_id)
    local t_tags = M.get_item_tags(item_id)
    local t_notes = M.get_item_notes(item_id)
    local t_attachments = M.get_item_attachments(item_id)

    local metadata = async_mod.await(t_metadata)
    local authors = async_mod.await(t_authors)
    local tags = async_mod.await(t_tags)
    local notes = async_mod.await(t_notes)
    local attachments = async_mod.await(t_attachments)

    local detail = {}
    for _, m in ipairs(metadata) do
      detail[m.fieldName] = m.value
    end

    return {
      metadata = detail,
      authors = authors,
      tags = tags,
      notes = notes,
      attachments = attachments,
    }
  end)
end

function M.search_global(search_term, sort_by, sort_dir, limit_override)
  return M.get_items(nil, search_term, sort_by, sort_dir, limit_override)
end

function M.get_item_type_name(item_type_id)
  return async_mod.run("zotero:db.get_item_type_name", function()
    return raw_query("SELECT typeName FROM itemTypes WHERE itemTypeID = " .. tostring(item_type_id))
  end)
end

function M.get_item_type_id(item_id)
  return async_mod.run("zotero:db.get_item_type_id", function()
    return tonumber(raw_query("SELECT itemTypeID FROM items WHERE itemID = " .. tostring(item_id)))
  end)
end

function M.get_item_key(item_id)
  return async_mod.run("zotero:db.get_item_key", function()
    return raw_query("SELECT key FROM items WHERE itemID = " .. tostring(item_id))
  end)
end

-- Bulk key lookup: one subprocess spawn instead of one per item. Returns a
-- map of itemID -> key.
function M.get_item_keys(item_ids)
  return async_mod.run("zotero:db.get_item_keys", function()
    if not item_ids or #item_ids == 0 then
      return {}
    end
    local ids = table.concat(vim.tbl_map(tostring, item_ids), ",")
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
    return raw_query("SELECT key FROM collections WHERE collectionID = " .. tostring(collection_id))
  end)
end

function M.get_editable_item(item_id)
  return async_mod.run("zotero:db.get_editable_item", function()
    -- Launched before the header query so all four run concurrently.
    local t_metadata = M.get_item_metadata(item_id)
    local t_authors = M.get_item_authors(item_id)
    local t_tags = M.get_item_tags(item_id)

    local sql = [[
      SELECT i.key, it.typeName AS itemType
      FROM items i
      JOIN itemTypes it ON i.itemTypeID = it.itemTypeID
      WHERE i.itemID = ]] .. tostring(item_id)
    local header = json_query(sql)
    if not header or #header == 0 then
      return nil
    end

    local data = {
      key = header[1].key,
      itemType = header[1].itemType,
      fields = {},
      creators = {},
      tags = {},
    }

    local metadata = async_mod.await(t_metadata)
    for _, m in ipairs(metadata) do
      if m.fieldName and m.value and m.value ~= "" then
        data.fields[m.fieldName] = m.value
      end
    end

    local authors = async_mod.await(t_authors)
    for _, a in ipairs(authors) do
      data.creators[#data.creators + 1] = {
        firstName = a.firstName or "",
        lastName = a.lastName or "",
        creatorType = a.creatorType or "author",
      }
    end

    local tags = async_mod.await(t_tags)
    for _, t in ipairs(tags) do
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
      WHERE itf.itemTypeID = ]] .. tostring(item_type_id) .. [[
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
    ]]
    local results = json_query(sql)
    return results[1]
  end)
end

return M
