local fixture = require("tests.helpers.fixture")
local db = require("zotero.db")

local function await(task)
  return fixture.wait_for(task)
end

describe("db (against fixture sqlite db)", function()
  before_each(function()
    fixture.setup()
  end)

  after_each(function()
    fixture.teardown()
  end)

  describe("get_stats / get_collections / get_trash_count", function()
    it("counts top-level (non-child, non-trashed) items", function()
      local stats = await(db.get_stats())
      assert.equals(5, stats.items) -- 1,2,3,5,8 top-level; 4,6 are children; 7 trashed
      assert.equals(3, stats.collections)
    end)

    it("returns the collection tree with depth and item counts", function()
      local cols = await(db.get_collections())
      local by_name = {}
      for _, c in ipairs(cols) do
        by_name[c.collectionName] = c
      end
      assert.equals(0, by_name["Root A"].depth)
      assert.equals(1, by_name["Child of A"].depth)
      assert.equals(2, by_name["Root A"].item_count) -- items 1 and 2
      assert.equals(1, by_name["Child of A"].item_count) -- item 2 only
      assert.equals(0, by_name["Root B"].item_count)
    end)

    it("counts trashed items plus trashed collections", function()
      assert.equals(2, await(db.get_trash_count())) -- item 7 + collection Root B
    end)
  end)

  describe("get_items", function()
    it("returns only non-child, non-trashed items by default", function()
      local items = await(db.get_items(nil, "", "dateAdded", "desc"))
      local ids = {}
      for _, i in ipairs(items) do ids[#ids + 1] = i.itemID end
      table.sort(ids)
      assert.same({ 1, 2, 3, 5, 8 }, ids)
    end)

    it("filters by collection", function()
      local items = await(db.get_items(1, "", "dateAdded", "desc")) -- Root A
      local ids = {}
      for _, i in ipairs(items) do ids[#ids + 1] = i.itemID end
      table.sort(ids)
      assert.same({ 1, 2 }, ids)
    end)

    it("filters by a nested collection independently of its parent", function()
      local items = await(db.get_items(2, "", "dateAdded", "desc")) -- Child of A
      assert.equals(1, #items)
      assert.equals(2, items[1].itemID)
    end)

    it("sorts by title in both directions", function()
      local desc = await(db.get_items(nil, "", "title", "desc"))
      local asc = await(db.get_items(nil, "", "title", "asc"))
      assert.equals(desc[1].title, asc[#asc].title)
      assert.equals(desc[#desc].title, asc[1].title)
    end)

    it("sorts by year", function()
      local items = await(db.get_items(nil, "", "year", "desc"))
      local years = {}
      for _, i in ipairs(items) do years[#years + 1] = i.year end
      -- No-date items decode as vim.NIL (JSON null), not Lua nil.
      local seen = {}
      for _, y in ipairs(years) do
        if y ~= nil and y ~= vim.NIL then seen[#seen + 1] = y end
      end
      for i = 2, #seen do
        assert.is_true(seen[i - 1] >= seen[i])
      end
    end)

    it("sorts by dateAdded", function()
      local items = await(db.get_items(nil, "", "dateAdded", "asc"))
      assert.equals(1, items[1].itemID) -- earliest dateAdded
    end)

    it("respects limit_override", function()
      local items = await(db.get_items(nil, "", "dateAdded", "desc", 2))
      assert.equals(2, #items)
    end)

    it("searches by title (plain ASCII)", function()
      local items = await(db.get_items(nil, "Microclimate", "dateAdded", "desc"))
      assert.equals(1, #items)
      assert.equals(2, items[1].itemID)
    end)

    it("searches case-insensitively", function()
      local items = await(db.get_items(nil, "MICROCLIMATE", "dateAdded", "desc"))
      assert.equals(1, #items)
    end)

    it("searches by publicationTitle", function()
      local items = await(db.get_items(nil, "Nature", "dateAdded", "desc"))
      assert.equals(1, #items)
      assert.equals(2, items[1].itemID)
    end)

    it("searches by tag name", function()
      local items = await(db.get_items(nil, "genetics", "dateAdded", "desc"))
      assert.equals(1, #items)
      assert.equals(3, items[1].itemID)
    end)

    it("searches by abstract text", function()
      local items = await(db.get_items(nil, "biodiversity", "dateAdded", "desc"))
      assert.equals(1, #items)
      assert.equals(2, items[1].itemID)
    end)

    it("is accent-insensitive: unaccented query finds accented content", function()
      local items = await(db.get_items(nil, "Niguez", "dateAdded", "desc")) -- creator "Ñíguez"
      assert.equals(1, #items)
      assert.equals(2, items[1].itemID)
    end)

    it("is accent-insensitive: accented query finds unaccented content", function()
      local items = await(db.get_items(nil, "café", "dateAdded", "desc")) -- abstract has "café"
      assert.equals(1, #items)
      local items2 = await(db.get_items(nil, "cafe", "dateAdded", "desc"))
      assert.equals(1, #items2)
      assert.equals(items[1].itemID, items2[1].itemID)
    end)

    it("matches short (<3 char) search terms via the fallback path", function()
      local items = await(db.get_items(nil, "Da", "dateAdded", "desc")) -- "Darwin"
      local ids = {}
      for _, i in ipairs(items) do ids[#ids + 1] = i.itemID end
      assert.is_true(vim.tbl_contains(ids, 1))
    end)

    it("ANDs multiple search words together", function()
      local items = await(db.get_items(nil, "Population Alcantara", "dateAdded", "desc"))
      assert.equals(1, #items)
      assert.equals(3, items[1].itemID)

      local none = await(db.get_items(nil, "Population Nature", "dateAdded", "desc"))
      assert.equals(0, #none)
    end)

    it("returns nothing for a search term matching no item", function()
      local items = await(db.get_items(nil, "zzz_no_such_thing_zzz", "dateAdded", "desc"))
      assert.equals(0, #items)
    end)

    it("rejects a non-numeric collection_id defensively", function()
      assert.has_error(function()
        await(db.get_items("'; DROP TABLE items; --", "", "dateAdded", "desc"))
      end)
    end)
  end)

  describe("get_trash_items", function()
    it("returns the trashed item plus a synthetic row for the trashed collection", function()
      local items = await(db.get_trash_items("dateAdded", "desc"))
      local has_item, has_collection = false, false
      for _, i in ipairs(items) do
        if i.itemID == 7 then has_item = true end
        if i._is_collection == 1 and i.title == "Root B" then has_collection = true end
      end
      assert.is_true(has_item)
      assert.is_true(has_collection)
    end)
  end)

  describe("per-item detail queries", function()
    it("get_item_authors returns creators in orderIndex order", function()
      local authors = await(db.get_item_authors(3))
      assert.equals(5, #authors)
      assert.equals("First", authors[1].lastName)
      assert.equals("Fifth", authors[5].lastName)
    end)

    it("get_items_authors bulk-loads authors for multiple items at once", function()
      local by_item = await(db.get_items_authors({ 1, 2 }))
      local ids = {}
      for _, a in ipairs(by_item) do ids[#ids + 1] = a.itemID end
      table.sort(ids)
      assert.same({ 1, 2, 2 }, ids) -- 1 author for item 1, 2 for item 2
    end)

    it("get_items_authors returns empty for an empty id list", function()
      assert.same({}, await(db.get_items_authors({})))
    end)

    it("get_item_metadata returns fieldName/value pairs", function()
      local meta = await(db.get_item_metadata(2))
      local by_field = {}
      for _, m in ipairs(meta) do by_field[m.fieldName] = m.value end
      assert.equals("Microclimate effects on species-rich habitats", by_field.title)
      assert.equals("Nature", by_field.publicationTitle)
    end)

    it("get_item_tags returns tag names sorted", function()
      local tags = await(db.get_item_tags(2))
      assert.same({ "ecology" }, vim.tbl_map(function(t) return t.name end, tags))
    end)

    it("get_item_notes returns child notes", function()
      local notes = await(db.get_item_notes(5))
      assert.equals(1, #notes)
      assert.equals("Note Title", notes[1].title)
    end)

    it("get_item_attachments returns child attachments with resolved title", function()
      local atts = await(db.get_item_attachments(2))
      assert.equals(1, #atts)
      assert.equals("Snapshot", atts[1].title)
    end)

    it("get_attachment returns a single attachment row by its own itemID", function()
      local att = await(db.get_attachment(4))
      assert.equals(4, att.itemID)
      assert.equals("Snapshot", att.title)
    end)
  end)

  describe("get_item_detail (combined query)", function()
    it("assembles metadata/authors/tags/notes/attachments for a normal item", function()
      local detail = await(db.get_item_detail(2))
      assert.equals("Microclimate effects on species-rich habitats", detail.metadata.title)
      assert.equals(2, #detail.authors)
      assert.equals(1, #detail.tags)
      assert.equals(0, #detail.notes)
      assert.equals(1, #detail.attachments)
    end)

    it("returns empty (not nil) arrays for an item with no related rows", function()
      local detail = await(db.get_item_detail(8)) -- PLAIN008, nothing at all
      assert.same({}, detail.authors)
      assert.same({}, detail.tags)
      assert.same({}, detail.notes)
      assert.same({}, detail.attachments)
      assert.same({}, detail.metadata)
    end)

    it("preserves creator orderIndex ordering for many authors", function()
      local detail = await(db.get_item_detail(3))
      assert.equals(5, #detail.authors)
      assert.equals("First", detail.authors[1].lastName)
      assert.equals("Fifth", detail.authors[5].lastName)
    end)

    it("works for a standalone attachment item (itself has no authors/tags/notes)", function()
      local detail = await(db.get_item_detail(4))
      assert.equals("Snapshot", detail.metadata.title)
      assert.same({}, detail.authors)
      assert.same({}, detail.tags)
      assert.same({}, detail.notes)
      assert.same({}, detail.attachments)
    end)
  end)

  describe("get_editable_item", function()
    it("returns key/itemType/fields/creators/tags for an existing item", function()
      local data = await(db.get_editable_item(2))
      assert.equals("ART00002", data.key)
      assert.equals("journalArticle", data.itemType)
      assert.equals("Nature", data.fields.publicationTitle)
      assert.equals(2, #data.creators)
      assert.equals("author", data.creators[1].creatorType)
      assert.same({ "ecology" }, data.tags)
    end)

    it("returns nil for a nonexistent item id", function()
      assert.is_nil(await(db.get_editable_item(999999)))
    end)

    it("omits empty-string field values", function()
      local data = await(db.get_editable_item(8))
      assert.same({}, data.fields)
    end)
  end)

  describe("lookups by type/key", function()
    it("get_item_type_name / get_item_type_id round-trip", function()
      local type_id = await(db.get_item_type_id(2))
      local type_name = await(db.get_item_type_name(type_id))
      assert.equals("journalArticle", type_name)
    end)

    it("get_item_key returns the item's key", function()
      assert.equals("BOOK0001", await(db.get_item_key(1)))
    end)

    it("get_item_keys bulk-resolves a list of ids", function()
      local map = await(db.get_item_keys({ 1, 2 }))
      assert.equals("BOOK0001", map[1])
      assert.equals("ART00002", map[2])
    end)

    it("get_collection_key returns the collection's key", function()
      assert.equals("COLLA001", await(db.get_collection_key(1)))
    end)

    it("get_item_by_key finds an item by its Zotero key", function()
      local item = await(db.get_item_by_key("ART00002"))
      assert.equals(2, item.itemID)
    end)

    it("get_item_field_value looks up a single field by key", function()
      assert.equals("Nature", await(db.get_item_field_value("ART00002", "publicationTitle")))
      assert.is_nil(await(db.get_item_field_value("ART00002", "nonexistentField")))
    end)

    it("get_parent_item_by_attachment_key resolves the parent item", function()
      local parent = await(db.get_parent_item_by_attachment_key("ATT00004"))
      assert.equals(2, parent.itemID)
    end)

    it("get_items_by_field_value finds items matching a field value", function()
      local items = await(db.get_items_by_field_value("publicationTitle", "Nature"))
      assert.equals(1, #items)
      assert.equals(2, items[1].itemID)
    end)
  end)

  describe("item types", function()
    it("get_all_item_types excludes note/attachment/annotation", function()
      local types_list = await(db.get_all_item_types())
      local names = vim.tbl_map(function(t) return t.typeName end, types_list)
      assert.is_false(vim.tbl_contains(names, "note"))
      assert.is_false(vim.tbl_contains(names, "attachment"))
      assert.is_false(vim.tbl_contains(names, "annotation"))
      assert.is_true(vim.tbl_contains(names, "book"))
      assert.is_true(vim.tbl_contains(names, "journalArticle"))
    end)

    it("get_item_type_fields returns the fields registered for a type", function()
      local fields = await(db.get_item_type_fields(4)) -- journalArticle
      local names = vim.tbl_map(function(f) return f.fieldName end, fields)
      assert.is_true(vim.tbl_contains(names, "publicationTitle"))
      assert.is_true(vim.tbl_contains(names, "DOI"))
    end)
  end)

  describe("caching / invalidation", function()
    it("get_data_version / is_stale_since reflect invalidate_cache()", function()
      await(db.get_stats()) -- prime db_last_mtime; is_stale_since does no I/O of its own
      local v1 = db.get_data_version()
      assert.is_false(db.is_stale_since(v1))
      db.invalidate_cache()
      assert.is_true(db.is_stale_since(v1))
    end)

    it("returns cached results across repeated calls without error", function()
      local a = await(db.get_items(nil, "", "dateAdded", "desc"))
      local b = await(db.get_items(nil, "", "dateAdded", "desc"))
      assert.equals(#a, #b)
    end)

    it("invalidate_cache() picks up changes made directly to the live db file", function()
      local before = await(db.get_stats())
      local h = io.popen(("sqlite3 '%s' \"UPDATE items SET key='CHANGED' WHERE itemID=1\""):format(fixture.db_path))
      h:close()
      db.invalidate_cache()
      local item = await(db.get_item_by_key("CHANGED"))
      assert.equals(1, item.itemID)
      assert.equals(before.items, (await(db.get_stats())).items)
    end)
  end)
end)
