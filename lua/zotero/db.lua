local M = {}

local types = require("zotero.types")

local function db_path()
  return require("zotero.config").get().db_path
end

local db_copy = nil

local function get_db()
  local path = db_path()
  if not path then
    return nil
  end
  if not db_copy then
    db_copy = vim.fn.tempname()
  end
  vim.fn.system({ "cp", path, db_copy })
  return db_copy
end

local function json_query(sql)
  local dbfile = get_db()
  if not dbfile then
    return {}
  end
  local cmd = { "sqlite3", "-json", dbfile, sql }
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("zotero: sqlite3 error: " .. (result or "unknown"), vim.log.levels.ERROR)
    return {}
  end
  if result == "" then
    return {}
  end
  local ok, data = pcall(vim.fn.json_decode, result)
  if not ok then
    return {}
  end
  return data
end

local function raw_query(sql)
  local dbfile = get_db()
  if not dbfile then
    return ""
  end
  local cmd = { "sqlite3", dbfile, sql }
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return ""
  end
  return vim.trim(result)
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

local ITEM_TYPES_FILTER = { 1, 3, 28 }

local function item_type_filter()
  local ids = {}
  for _, v in ipairs(ITEM_TYPES_FILTER) do
    ids[#ids + 1] = tostring(v)
  end
  return table.concat(ids, ",")
end

local function not_trashed()
  return "i.itemID NOT IN (SELECT itemID FROM deletedItems)"
end

function M.get_stats()
  local collections = raw_query("SELECT COUNT(*) FROM collections")
  local items = raw_query("SELECT COUNT(*) FROM items WHERE itemTypeID NOT IN (" .. item_type_filter() .. ") AND itemID NOT IN (SELECT itemID FROM deletedItems)")
  return {
    collections = tonumber(collections) or 0,
    items = tonumber(items) or 0,
  }
end

function M.get_collections()
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
      WHERE i.itemTypeID NOT IN (]] .. item_type_filter() .. [[)
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
  return json_query(sql)
end

function M.get_items(collection_id, search_term, sort_by, sort_dir)
  local where = "i.itemTypeID NOT IN (" .. item_type_filter() .. ") AND " .. not_trashed()
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
          t.title LIKE '%]] .. escaped .. [[%'
          OR p.publicationTitle LIKE '%]] .. escaped .. [[%'
          OR EXISTS (
            SELECT 1 FROM itemCreators ic2
            JOIN creators c2 ON ic2.creatorID = c2.creatorID
            WHERE ic2.itemID = i.itemID
            AND (c2.lastName LIKE '%]] .. escaped .. [[%' OR c2.firstName LIKE '%]] .. escaped .. [[%')
          )
          OR y.date_str LIKE ']] .. escaped .. [[%'
          OR EXISTS (
            SELECT 1 FROM itemData id3
            JOIN itemDataValues dv3 ON id3.valueID = dv3.valueID
            WHERE id3.itemID = i.itemID AND id3.fieldID = ]] .. FIELD_IDS.abstractNote .. [[
            AND dv3.value LIKE '%]] .. escaped .. [[%'
          )
          OR EXISTS (
            SELECT 1 FROM itemTags it3
            JOIN tags t3 ON it3.tagID = t3.tagID
            WHERE it3.itemID = i.itemID
            AND t3.name LIKE '%]] .. escaped .. [[%'
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

  local limit = require("zotero.config").get().max_items

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

  return json_query(sql)
end

function M.get_trash_items(sort_by, sort_dir)
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

  local limit = require("zotero.config").get().max_items

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
    WHERE i.itemTypeID NOT IN (]] .. item_type_filter() .. [[)

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

  return json_query(sql)
end

function M.get_trash_count()
  local item_count = raw_query("SELECT COUNT(*) FROM items i JOIN deletedItems d ON i.itemID = d.itemID WHERE i.itemTypeID NOT IN (" .. item_type_filter() .. ")")
  local col_count = raw_query("SELECT COUNT(*) FROM deletedCollections")
  return (tonumber(item_count) or 0) + (tonumber(col_count) or 0)
end

function M.get_item_authors(item_id)
  local sql = [[
    SELECT ic.itemID, c.firstName, c.lastName, c.fieldMode, ct.creatorType, ic.orderIndex
    FROM itemCreators ic
    JOIN creators c ON ic.creatorID = c.creatorID
    JOIN creatorTypes ct ON ic.creatorTypeID = ct.creatorTypeID
    WHERE ic.itemID = ]] .. tostring(item_id) .. [[
    ORDER BY ic.orderIndex
  ]]
  return json_query(sql)
end

function M.get_items_authors(item_ids)
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
  return json_query(sql)
end

function M.get_item_metadata(item_id)
  local sql = [[
    SELECT f.fieldName, dv.value
    FROM itemData id
    JOIN fields f ON id.fieldID = f.fieldID
    JOIN itemDataValues dv ON id.valueID = dv.valueID
    WHERE id.itemID = ]] .. tostring(item_id) .. [[
  ]]
  return json_query(sql)
end

function M.get_item_tags(item_id)
  local sql = [[
    SELECT t.name
    FROM itemTags itag
    JOIN tags t ON itag.tagID = t.tagID
    WHERE itag.itemID = ]] .. tostring(item_id) .. [[
    ORDER BY t.name
  ]]
  return json_query(sql)
end

function M.get_item_notes(item_id)
  local sql = [[
    SELECT i.itemID, n.title, n.note
    FROM items i
    JOIN itemNotes n ON i.itemID = n.itemID
    WHERE n.parentItemID = ]] .. tostring(item_id) .. [[
    ORDER BY i.dateAdded
  ]]
  return json_query(sql)
end

function M.get_item_attachments(item_id)
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
end

function M.get_item_detail(item_id)
  local metadata = M.get_item_metadata(item_id)
  local authors = M.get_item_authors(item_id)
  local tags = M.get_item_tags(item_id)
  local notes = M.get_item_notes(item_id)
  local attachments = M.get_item_attachments(item_id)

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
end

function M.search_global(search_term, sort_by, sort_dir)
  return M.get_items(nil, search_term, sort_by, sort_dir)
end

function M.get_item_type_name(item_type_id)
  local result = raw_query("SELECT typeName FROM itemTypes WHERE itemTypeID = " .. tostring(item_type_id))
  return result
end

function M.get_item_type_id(item_id)
  local result = raw_query("SELECT itemTypeID FROM items WHERE itemID = " .. tostring(item_id))
  return tonumber(result)
end

function M.get_item_key(item_id)
  return raw_query("SELECT key FROM items WHERE itemID = " .. tostring(item_id))
end

function M.get_collection_key(collection_id)
  return raw_query("SELECT key FROM collections WHERE collectionID = " .. tostring(collection_id))
end

function M.get_editable_item(item_id)
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

  local metadata = M.get_item_metadata(item_id)
  for _, m in ipairs(metadata) do
    if m.fieldName and m.value and m.value ~= "" then
      data.fields[m.fieldName] = m.value
    end
  end

  local authors = M.get_item_authors(item_id)
  for _, a in ipairs(authors) do
    data.creators[#data.creators + 1] = {
      firstName = a.firstName or "",
      lastName = a.lastName or "",
      creatorType = a.creatorType or "author",
    }
  end

  local tags = M.get_item_tags(item_id)
  for _, t in ipairs(tags) do
    if t.name and t.name ~= "" then
      data.tags[#data.tags + 1] = t.name
    end
  end

  return data
end

function M.get_item_type_fields(item_type_id)
  local sql = [[
    SELECT f.fieldName
    FROM itemTypeFields itf
    JOIN fields f ON itf.fieldID = f.fieldID
    WHERE itf.itemTypeID = ]] .. tostring(item_type_id) .. [[
    ORDER BY f.fieldName
  ]]
  return json_query(sql)
end

function M.get_all_item_types()
  local sql = [[
    SELECT typeName, itemTypeID
    FROM itemTypes
    WHERE itemTypeID NOT IN (]] .. item_type_filter() .. [[)
    ORDER BY typeName COLLATE NOCASE
  ]]
  return json_query(sql)
end

return M
