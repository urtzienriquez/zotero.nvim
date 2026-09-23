-- Minimal synthetic Zotero-schema fixture for tests. Not a real Zotero
-- export -- just enough tables/columns/fieldIDs for lua/zotero/db.lua's
-- queries to run against, with data picked to exercise specific behaviors
-- (accented names, multi-author ordering, trashed items, empty items, a
-- standalone attachment, a note, a collection tree).
--
-- fieldIDs below (1, 2, 6, 38, 64, 13, 59) MUST match FIELD_IDS in db.lua --
-- those queries hardcode the numeric fieldID, not a name lookup.
-- itemTypeIDs 1/3/28 MUST stay note/attachment/annotation -- db.lua's
-- ITEM_TYPES_FILTER excludes exactly those three from get_all_item_types().

PRAGMA foreign_keys = OFF;

CREATE TABLE itemTypes (itemTypeID INTEGER PRIMARY KEY, typeName TEXT);
INSERT INTO itemTypes VALUES
  (1, 'note'), (3, 'attachment'), (28, 'annotation'),
  (2, 'book'), (4, 'journalArticle'), (5, 'document');

CREATE TABLE fields (fieldID INTEGER PRIMARY KEY, fieldName TEXT);
INSERT INTO fields VALUES
  (1, 'title'), (2, 'abstractNote'), (6, 'date'),
  (38, 'publicationTitle'), (64, 'citationKey'), (13, 'url'), (59, 'DOI');

CREATE TABLE itemTypeFields (itemTypeID INTEGER, fieldID INTEGER);
INSERT INTO itemTypeFields VALUES
  (2, 1), (2, 6),
  (4, 1), (4, 6), (4, 2), (4, 38), (4, 59), (4, 13), (4, 64),
  (5, 1), (5, 6), (5, 13);

-- Library 1 is the user library; everything the tests assert on lives there.
-- Library 2 is a feed and library 3 a group: their items/collections must
-- never leak into user-library queries (see db.lua's library scoping).
CREATE TABLE libraries (libraryID INTEGER PRIMARY KEY, type TEXT NOT NULL);
INSERT INTO libraries VALUES (1, 'user'), (2, 'feed'), (3, 'group');

CREATE TABLE feeds (libraryID INTEGER PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL);
INSERT INTO feeds VALUES (2, 'Journal RSS', 'https://example.org/rss');

CREATE TABLE items (
  itemID INTEGER PRIMARY KEY, itemTypeID INTEGER, libraryID INTEGER, key TEXT, dateAdded TEXT
);
INSERT INTO items VALUES
  (1, 2, 1, 'BOOK0001', '2020-01-01 00:00:00'),
  (2, 4, 1, 'ART00002', '2020-02-02 00:00:00'),
  (3, 4, 1, 'ART00003', '2020-03-03 00:00:00'),
  (4, 3, 1, 'ATT00004', '2020-02-02 00:01:00'),
  (5, 5, 1, 'DOC00005', '2020-04-04 00:00:00'),
  (6, 1, 1, 'NOTE0006', '2020-04-04 00:01:00'),
  (7, 5, 1, 'TRASH007', '2020-05-05 00:00:00'),
  (8, 5, 1, 'PLAIN008', '2020-06-06 00:00:00'),
  (9, 4, 2, 'FEED0009', '2020-07-01 00:00:00'),
  (10, 4, 2, 'FEED0010', '2020-07-02 00:00:00'),
  (11, 4, 3, 'GRP00011', '2020-07-03 00:00:00');

CREATE TABLE feedItems (itemID INTEGER PRIMARY KEY, guid TEXT NOT NULL, readTime TEXT);
INSERT INTO feedItems VALUES
  (9, 'guid-9', '2020-07-05 00:00:00'),
  (10, 'guid-10', NULL);

CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value TEXT);
INSERT INTO itemDataValues VALUES
  (1, 'On the Origin of Species'),
  (2, '1859'),
  (3, 'Microclimate effects on species-rich habitats'),
  (4, 'A study of café biodiversity in the Ñíguez region'),
  (5, '2019-05-20'),
  (6, 'Nature'),
  (7, 'Population genetics of Alcántara populations'),
  (8, '2020-01-15'),
  (9, 'Science'),
  (10, 'Field Report'),
  (11, '2021-06-01'),
  (12, 'Snapshot'),
  (13, 'Old Draft'),
  (14, 'Feed article already read'),
  (15, 'Feed article unread'),
  (16, 'Group article'),
  (17, '10.1000/dup'),
  (18, 'https://example.org/unread');

CREATE TABLE itemData (itemID INTEGER, fieldID INTEGER, valueID INTEGER);
INSERT INTO itemData VALUES
  (1, 1, 1), (1, 6, 2),
  (2, 1, 3), (2, 2, 4), (2, 6, 5), (2, 38, 6),
  (3, 1, 7), (3, 6, 8), (3, 38, 9),
  (5, 1, 10), (5, 6, 11),
  (4, 1, 12),
  (7, 1, 13),
  (9, 1, 14), (9, 59, 17),
  (10, 1, 15), (10, 13, 18),
  (11, 1, 16), (11, 59, 17);
  -- item 8 (PLAIN008) deliberately has no itemData rows at all.

CREATE TABLE creatorTypes (creatorTypeID INTEGER PRIMARY KEY, creatorType TEXT);
INSERT INTO creatorTypes VALUES (1, 'author'), (2, 'editor');

CREATE TABLE creators (
  creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT, fieldMode INTEGER
);
INSERT INTO creators VALUES
  (1, 'Charles', 'Darwin', 0),
  (2, 'Andrés', 'Ñíguez', 0),
  (3, 'Jane', 'Smith', 0),
  (4, 'A.', 'First', 0),
  (5, 'B.', 'Second', 0),
  (6, 'C.', 'Third', 0),
  (7, 'D.', 'Fourth', 0),
  (8, 'E.', 'Fifth', 0);

CREATE TABLE itemCreators (
  itemID INTEGER, creatorID INTEGER, creatorTypeID INTEGER, orderIndex INTEGER
);
INSERT INTO itemCreators VALUES
  (1, 1, 1, 0),
  (2, 2, 1, 0), (2, 3, 1, 1),
  (3, 4, 1, 0), (3, 5, 1, 1), (3, 6, 1, 2), (3, 7, 1, 3), (3, 8, 1, 4);

CREATE TABLE tags (tagID INTEGER PRIMARY KEY, name TEXT);
INSERT INTO tags VALUES (1, 'ecology'), (2, 'genetics'), (3, 'draft');

CREATE TABLE itemTags (itemID INTEGER, tagID INTEGER);
INSERT INTO itemTags VALUES (2, 1), (3, 2), (7, 3);

CREATE TABLE itemNotes (itemID INTEGER, parentItemID INTEGER, title TEXT, note TEXT);
INSERT INTO itemNotes VALUES (6, 5, 'Note Title', '<p>Some note content</p>');

CREATE TABLE itemAttachments (
  itemID INTEGER, parentItemID INTEGER, linkMode INTEGER, contentType TEXT, path TEXT
);
INSERT INTO itemAttachments VALUES (4, 2, 2, 'application/pdf', 'attachments:snapshot.pdf');

CREATE TABLE itemAnnotations (itemID INTEGER, parentItemID INTEGER);
-- none seeded; table just needs to exist for not_child()'s subquery.

CREATE TABLE collections (
  collectionID INTEGER PRIMARY KEY, collectionName TEXT, parentCollectionID INTEGER,
  libraryID INTEGER, key TEXT
);
INSERT INTO collections VALUES
  (1, 'Root A', NULL, 1, 'COLLA001'),
  (2, 'Child of A', 1, 1, 'COLLA002'),
  (3, 'Root B', NULL, 1, 'COLLB001'),
  (4, 'Group Col', NULL, 3, 'COLLG001');

CREATE TABLE collectionItems (collectionID INTEGER, itemID INTEGER);
INSERT INTO collectionItems VALUES (1, 1), (1, 2), (2, 2), (4, 11);

CREATE TABLE deletedItems (itemID INTEGER);
INSERT INTO deletedItems VALUES (7);

CREATE TABLE deletedCollections (collectionID INTEGER, dateDeleted TEXT);
INSERT INTO deletedCollections VALUES (3, '2020-07-07 00:00:00');
