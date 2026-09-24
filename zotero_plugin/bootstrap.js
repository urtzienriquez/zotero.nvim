function install() {}
function uninstall() {}

async function startup({ id, version, resourceURI, rootURI }) {
  try {
    await Zotero.initializationPromise;
    Zotero.logError("zotero-nvim-connector: startup starting");

    Zotero.Server.Endpoints["/connector/updateItem"] = function () {};
    Zotero.Server.Endpoints["/connector/updateItem"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
      var data = requestData.data;
      var itemKey = data.itemKey;
      var updates = data.updates;

      if (!itemKey) {
        return [400, "application/json", JSON.stringify({ error: "MISSING_ITEM_KEY" })];
      }

      var libraryID = Zotero.Libraries.userLibraryID;
      var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKey);
      if (!item) {
        return [404, "application/json", JSON.stringify({ error: "ITEM_NOT_FOUND" })];
      }

      if (updates.fields) {
        for (var field in updates.fields) {
          if (Object.prototype.hasOwnProperty.call(updates.fields, field)) {
            item.setField(field, updates.fields[field]);
          }
        }
      }
      if (updates.creators) {
        item.setCreators(updates.creators);
      }
      if (updates.tags) {
        var newTags = updates.tags.map(function (t) {
          if (typeof t === "string") return { tag: t, type: 0 };
          return { tag: t.tag || t, type: t.type || 0 };
        });
        item.setTags(newTags);
      }
      if (updates.itemType) {
        var typeID = Zotero.ItemTypes.getID(updates.itemType);
        if (typeID && typeID !== item.itemTypeID) {
          item.setType(typeID);
        }
      }
      if (updates.dateAdded != null) {
        item.setField("dateAdded", String(updates.dateAdded).trim());
      }
      if (updates.dateModified != null) {
        item.setField("dateModified", String(updates.dateModified).trim());
      }

      await item.save();

      return [200, "application/json", JSON.stringify({ success: true })];
      } catch (e) {
        Zotero.logError("updateItem error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/regenerateKey"] = function () {};
  Zotero.Server.Endpoints["/connector/regenerateKey"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKey = data.itemKey;

        if (!itemKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_ITEM_KEY" })];
        }

        if (!Zotero.BetterBibTeX) {
          return [400, "application/json", JSON.stringify({ error: "Better BibTeX not installed" })];
        }

        await Zotero.BetterBibTeX.ready;
        if (!Zotero.BetterBibTeX.KeyManager) {
          return [500, "application/json", JSON.stringify({ error: "BBT KeyManager not found" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKey);
        if (!item) {
          return [404, "application/json", JSON.stringify({ error: "ITEM_NOT_FOUND" })];
        }

        // BBT KeyManager.fill with replace: true regenerates the key
        await Zotero.BetterBibTeX.KeyManager.fill([item.id], { replace: true });

        var citationKey = item.getField("citationKey") || "";
        return [200, "application/json", JSON.stringify({ citationKey: citationKey })];
      } catch (e) {
        Zotero.logError("regenerateKey error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/addAttachment"] = function () {};
  Zotero.Server.Endpoints["/connector/addAttachment"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKey = data.itemKey;
        var filePath = data.filePath;

        if (!itemKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_ITEM_KEY" })];
        }
        if (!filePath) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_FILE_PATH" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKey);
        if (!item) {
          return [404, "application/json", JSON.stringify({ error: "ITEM_NOT_FOUND" })];
        }

        var imported = await Zotero.Attachments.importFromFile({
          file: filePath,
          parentItemID: item.id,
        });

        return [200, "application/json", JSON.stringify({
          success: true,
          attachmentKey: imported.key,
        })];
      } catch (e) {
        Zotero.logError("addAttachment error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/createItem"] = function () {};
  Zotero.Server.Endpoints["/connector/createItem"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemType = data.itemType;
        var fields = data.fields || {};
        var creators = data.creators || [];
        var tags = data.tags || [];

        if (!itemType) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_ITEM_TYPE" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var item = new Zotero.Item(itemType);
        item.libraryID = libraryID;

        for (var field in fields) {
          if (Object.prototype.hasOwnProperty.call(fields, field)) {
            item.setField(field, fields[field]);
          }
        }

        if (creators.length > 0) {
          item.setCreators(creators);
        }

        var tagObjects = tags.map(function (t) {
          if (typeof t === "string") return { tag: t, type: 0 };
          return { tag: t.tag || t, type: t.type || 0 };
        });
        item.setTags(tagObjects);

        await item.save();

        return [200, "application/json", JSON.stringify({
          success: true,
          key: item.key,
        })];
      } catch (e) {
        Zotero.logError("createItem error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/fetchMetadata"] = function () {};
  Zotero.Server.Endpoints["/connector/fetchMetadata"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var identifier = data.identifier;

        if (!identifier) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_IDENTIFIER" })];
        }

        var newItems = [];
        var idStr = String(identifier);

        if (/^https?:\/\//i.test(idStr)) {
          var doi = Zotero.Utilities.cleanDOI(idStr);
          if (doi) {
            var translate = new Zotero.Translate.Search();
            translate.setIdentifier({ DOI: doi });
            var translators = await translate.getTranslators();
            if (translators && translators.length) {
              translate.setTranslator(translators);
              var items = await translate.translate({ libraryID: false });
              for (var j = 0; j < items.length; j++) {
                newItems.push(items[j]);
              }
            }
          } else {
            var req = await Zotero.HTTP.request("GET", idStr, { responseType: "document" });
            var doc = req.response;
            if (!doc) {
              return [400, "application/json", JSON.stringify({ error: "URL_FETCH_FAILED" })];
            }
            doc = Zotero.HTTP.wrapDocument(doc, idStr);
            var translate = new Zotero.Translate.Web();
            translate.setDocument(doc);
            translate.setLocation(idStr);
            var translators = await translate.getTranslators();
            if (!translators || !translators.length) {
              return [400, "application/json", JSON.stringify({ error: "NO_TRANSLATOR_FOUND" })];
            }
            translate.setTranslator(translators);
            var items = await translate.translate({ libraryID: false });
            for (var j = 0; j < items.length; j++) {
              newItems.push(items[j]);
            }
          }
        } else {
          var identifiers = Zotero.Utilities.extractIdentifiers(idStr);
          if (!identifiers || !identifiers.length) {
            return [400, "application/json", JSON.stringify({ error: "NO_IDENTIFIER_FOUND" })];
          }

          for (var i = 0; i < identifiers.length; i++) {
            var translate = new Zotero.Translate.Search();
            translate.setIdentifier(identifiers[i]);
            var translators = await translate.getTranslators();
            if (!translators || !translators.length) {
              continue;
            }
            translate.setTranslator(translators);
            var items = await translate.translate({ libraryID: false });
            for (var j = 0; j < items.length; j++) {
              newItems.push(items[j]);
            }
          }
        }

        if (!newItems.length) {
          return [400, "application/json", JSON.stringify({ error: "NO_TRANSLATOR_FOUND" })];
        }

        var item = newItems[0];
        var itemType = item.itemType;
        var itemTypeID = item.itemTypeID || Zotero.ItemTypes.getID(itemType);
        var fields = {};

        var typeFields = Zotero.ItemFields.getItemTypeFields(itemTypeID);
        for (var f = 0; f < typeFields.length; f++) {
          var fieldName = Zotero.ItemFields.getName(typeFields[f]);
          var val = item[fieldName];
          if (val !== false && val !== null && val !== undefined && val !== "") {
            fields[fieldName] = val;
          }
        }

        var creators = [];
        var rawCreators = item.creators || [];
        for (var c = 0; c < rawCreators.length; c++) {
          creators.push({
            firstName: rawCreators[c].firstName || "",
            lastName: rawCreators[c].lastName || "",
            creatorType: rawCreators[c].creatorType || "author",
          });
        }

        var tags = [];
        var rawTags = item.tags || [];
        for (var t = 0; t < rawTags.length; t++) {
          var tag = rawTags[t];
          tags.push((typeof tag === "string") ? tag : tag.tag);
        }

        return [200, "application/json", JSON.stringify({
          success: true,
          metadata: {
            itemType: itemType,
            fields: fields,
            creators: creators,
            tags: tags,
          },
        })];
      } catch (e) {
        Zotero.logError("fetchMetadata error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/addByIdentifier"] = function () {};
  Zotero.Server.Endpoints["/connector/addByIdentifier"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var identifier = data.identifier;

        if (!identifier) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_IDENTIFIER" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var collectionKey = data.collectionKey;
        var translateOptions = {
          libraryID: libraryID,
          saveAttachments: true,
        };
        if (collectionKey) {
          translateOptions.collections = [collectionKey];
        }
        var newItems = [];
        var idStr = String(identifier);

        if (/^https?:\/\//i.test(idStr)) {
          var doi = Zotero.Utilities.cleanDOI(idStr);
          if (doi) {
            var translate = new Zotero.Translate.Search();
            translate.setIdentifier({ DOI: doi });
            var translators = await translate.getTranslators();
            if (translators && translators.length) {
              translate.setTranslator(translators);
              var items = await translate.translate(translateOptions);
              for (var j = 0; j < items.length; j++) {
                newItems.push(items[j]);
              }
            }
          } else {
            var req = await Zotero.HTTP.request("GET", idStr, { responseType: "document" });
            var doc = req.response;
            if (!doc) {
              return [400, "application/json", JSON.stringify({ error: "URL_FETCH_FAILED" })];
            }
            doc = Zotero.HTTP.wrapDocument(doc, idStr);
            var translate = new Zotero.Translate.Web();
            translate.setDocument(doc);
            translate.setLocation(idStr);
            var translators = await translate.getTranslators();
            if (!translators || !translators.length) {
              return [400, "application/json", JSON.stringify({ error: "NO_TRANSLATOR_FOUND" })];
            }
            translate.setTranslator(translators);
            var items = await translate.translate(translateOptions);
            for (var j = 0; j < items.length; j++) {
              newItems.push(items[j]);
            }
          }
        } else {
          var identifiers = Zotero.Utilities.extractIdentifiers(idStr);
          if (!identifiers || !identifiers.length) {
            return [400, "application/json", JSON.stringify({ error: "NO_IDENTIFIER_FOUND" })];
          }

          for (var i = 0; i < identifiers.length; i++) {
            var translate = new Zotero.Translate.Search();
            translate.setIdentifier(identifiers[i]);
            var translators = await translate.getTranslators();
            if (!translators || !translators.length) {
              continue;
            }
            translate.setTranslator(translators);
            var items = await translate.translate(translateOptions);
            for (var j = 0; j < items.length; j++) {
              newItems.push(items[j]);
            }
          }
        }

        if (!newItems.length) {
          return [400, "application/json", JSON.stringify({ error: "NO_TRANSLATOR_FOUND" })];
        }

        return [200, "application/json", JSON.stringify({
          success: true,
          added: newItems.length,
          items: newItems.map(function(item) {
            return { key: item.key, title: item.getField("title") || "" };
          }),
        })];
      } catch (e) {
        Zotero.logError("addByIdentifier error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/deleteItems"] = function () {};
  Zotero.Server.Endpoints["/connector/deleteItems"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKeys = data.itemKeys;
        var collectionKeys = data.collectionKeys;

        var libraryID = Zotero.Libraries.userLibraryID;
        var itemIDs = [];
        var collectionIDs = [];

        if (itemKeys) {
          for (var i = 0; i < itemKeys.length; i++) {
            var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKeys[i]);
            if (item) {
              itemIDs.push(item.id);
            }
          }
        }
        if (collectionKeys) {
          for (var i = 0; i < collectionKeys.length; i++) {
            var col = Zotero.Collections.getByLibraryAndKey(libraryID, collectionKeys[i]);
            if (col) {
              collectionIDs.push(col.id);
            }
          }
        }

        if (itemIDs.length > 0) {
          await Zotero.Items.trashTx(itemIDs);
        }
        if (collectionIDs.length > 0) {
          await Zotero.DB.executeTransaction(async function () {
            for (var i = 0; i < collectionIDs.length; i++) {
              var col = await Zotero.Collections.getAsync(collectionIDs[i]);
              if (col) {
                col.deleted = true;
                await col.save();
              }
            }
          }.bind(this));
        }

        return [200, "application/json", JSON.stringify({
          success: true,
          trashed: itemIDs.length + collectionIDs.length,
        })];
      } catch (e) {
        Zotero.logError("deleteItems error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/eraseItems"] = function () {};
  Zotero.Server.Endpoints["/connector/eraseItems"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKeys = data.itemKeys;
        var collectionKeys = data.collectionKeys;

        var libraryID = Zotero.Libraries.userLibraryID;
        var itemIDs = [];
        var collectionIDs = [];

        if (itemKeys) {
          for (var i = 0; i < itemKeys.length; i++) {
            var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKeys[i]);
            if (item) {
              itemIDs.push(item.id);
            }
          }
        }
        if (collectionKeys) {
          for (var i = 0; i < collectionKeys.length; i++) {
            var col = Zotero.Collections.getByLibraryAndKey(libraryID, collectionKeys[i]);
            if (col) {
              collectionIDs.push(col.id);
            }
          }
        }

        if (itemIDs.length > 0) {
          await Zotero.Items.erase(itemIDs);
        }
        if (collectionIDs.length > 0) {
          await Zotero.Collections.erase(collectionIDs);
        }

        return [200, "application/json", JSON.stringify({
          success: true,
          erased: itemIDs.length + collectionIDs.length,
        })];
      } catch (e) {
        Zotero.logError("eraseItems error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/deleteItem"] = function () {};
  Zotero.Server.Endpoints["/connector/deleteItem"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKey = data.itemKey;

        if (!itemKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_ITEM_KEY" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKey);
        if (!item) {
          return [404, "application/json", JSON.stringify({ error: "ITEM_NOT_FOUND" })];
        }

        await Zotero.Items.trashTx([item.id]);

        return [200, "application/json", JSON.stringify({ success: true })];
      } catch (e) {
        Zotero.logError("deleteItem error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/eraseItem"] = function () {};
  Zotero.Server.Endpoints["/connector/eraseItem"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKey = data.itemKey;

        if (!itemKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_ITEM_KEY" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKey);
        if (!item) {
          return [404, "application/json", JSON.stringify({ error: "ITEM_NOT_FOUND" })];
        }

        await Zotero.Items.erase([item.id]);

        return [200, "application/json", JSON.stringify({ success: true })];
      } catch (e) {
        Zotero.logError("eraseItem error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/createCollection"] = function () {};
  Zotero.Server.Endpoints["/connector/createCollection"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var name = data.name;

        if (!name) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_NAME" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var collection = new Zotero.Collection();
        collection.libraryID = libraryID;
        collection.name = name;

        var parentCollectionKey = data.parentCollectionKey;
        if (parentCollectionKey) {
          var parent = Zotero.Collections.getByLibraryAndKey(libraryID, parentCollectionKey);
          if (parent) {
            collection.parentID = parent.id;
          }
        }

        await collection.save();

        return [200, "application/json", JSON.stringify({
          success: true,
          collectionKey: collection.key,
        })];
      } catch (e) {
        Zotero.logError("createCollection error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/addToCollection"] = function () {};
  Zotero.Server.Endpoints["/connector/addToCollection"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKey = data.itemKey;
        var collectionKey = data.collectionKey;

        if (!itemKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_ITEM_KEY" })];
        }
        if (!collectionKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_COLLECTION_KEY" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var collection = Zotero.Collections.getByLibraryAndKey(libraryID, collectionKey);
        if (!collection) {
          return [404, "application/json", JSON.stringify({ error: "COLLECTION_NOT_FOUND" })];
        }

        var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKey);
        if (!item) {
          return [404, "application/json", JSON.stringify({ error: "ITEM_NOT_FOUND" })];
        }

        await Zotero.DB.executeTransaction(async function () {
          await collection.addItem(item.id);
        }.bind(this));

        return [200, "application/json", JSON.stringify({ success: true })];
      } catch (e) {
        Zotero.logError("addToCollection error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/trashCollection"] = function () {};
  Zotero.Server.Endpoints["/connector/trashCollection"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var collectionKey = data.collectionKey;

        if (!collectionKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_COLLECTION_KEY" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var collection = Zotero.Collections.getByLibraryAndKey(libraryID, collectionKey);
        if (!collection) {
          return [404, "application/json", JSON.stringify({ error: "COLLECTION_NOT_FOUND" })];
        }

        await Zotero.DB.executeTransaction(async function () {
          collection.deleted = true;
        await collection.save();

        try {
          var zp = Zotero.getActiveZoteroPane();
          if (zp) {
            await zp.collectionsView.selectLibrary(libraryID);
          }
        } catch (e) {
          Zotero.logError("Failed to reset collection focus: " + (e.message || String(e)));
        }
        }.bind(this));

        return [200, "application/json", JSON.stringify({ success: true })];
      } catch (e) {
        Zotero.logError("trashCollection error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/eraseCollection"] = function () {};
  Zotero.Server.Endpoints["/connector/eraseCollection"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var collectionKey = data.collectionKey;

        if (!collectionKey) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_COLLECTION_KEY" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var collection = Zotero.Collections.getByLibraryAndKey(libraryID, collectionKey);
        if (!collection) {
          return [404, "application/json", JSON.stringify({ error: "COLLECTION_NOT_FOUND" })];
        }

        await Zotero.Collections.erase([collection.id]);

        return [200, "application/json", JSON.stringify({ success: true })];
      } catch (e) {
        Zotero.logError("eraseCollection error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/importFile"] = function () {};
  Zotero.Server.Endpoints["/connector/importFile"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var filePath = data.filePath;
        var collectionKey = data.collectionKey;

        if (!filePath) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_FILE_PATH" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var file = Zotero.File.pathToFile(filePath);
        var leafName = file.leafName;

        var options = {
          file: filePath,
          libraryID: libraryID,
          title: leafName.replace(/\.pdf$/, ""),
        };

        if (collectionKey) {
          var col = Zotero.Collections.getByLibraryAndKey(libraryID, collectionKey);
          if (col) {
            options.collections = [col.id];
          }
        }

        var item = await Zotero.Attachments.importFromFile(options);
        var canRecognize = Zotero.RecognizeDocument.canRecognize(item);
        if (canRecognize) {
          await Zotero.RecognizeDocument.autoRecognizeItems([item]);
        }

        return [200, "application/json", JSON.stringify({
          success: true,
          canRecognize: canRecognize,
          itemKey: item.key,
        })];
      } catch (e) {
        Zotero.logError("importFile error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/mergeItems"] = function () {};
  Zotero.Server.Endpoints["/connector/mergeItems"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var itemKey = data.itemKey;
        var otherItemKeys = data.otherItemKeys;

        if (!itemKey || !otherItemKeys || !otherItemKeys.length) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_KEYS" })];
        }

        var libraryID = Zotero.Libraries.userLibraryID;
        var masterItem = Zotero.Items.getByLibraryAndKey(libraryID, itemKey);
        if (!masterItem) {
          return [404, "application/json", JSON.stringify({ error: "MASTER_ITEM_NOT_FOUND" })];
        }

        var otherItems = [];
        for (var i = 0; i < otherItemKeys.length; i++) {
          var item = Zotero.Items.getByLibraryAndKey(libraryID, otherItemKeys[i]);
          if (item) {
            otherItems.push(item);
          }
        }

        if (!otherItems.length) {
          return [400, "application/json", JSON.stringify({ error: "NO_OTHER_ITEMS_FOUND" })];
        }

        var { mergeItems } = ChromeUtils.importESModule(
          "chrome://zotero/content/mergeItems.mjs"
        );
        await mergeItems(masterItem, otherItems);

        return [200, "application/json", JSON.stringify({ success: true })];
      } catch (e) {
        Zotero.logError("mergeItems error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  // Feed items live in their feed's own library (not the user library), so
  // unlike the endpoints above this one takes an explicit libraryID -- and
  // only ever touches items that really are feed items in a feed library.
  Zotero.Server.Endpoints["/connector/setFeedItemsRead"] = function () {};
  Zotero.Server.Endpoints["/connector/setFeedItemsRead"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var libraryID = data.libraryID;
        var itemKeys = data.itemKeys;
        var read = data.read !== false;

        if (!libraryID || !itemKeys || !itemKeys.length) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_LIBRARY_OR_KEYS" })];
        }
        var feed = Zotero.Feeds.get(libraryID);
        if (!feed) {
          return [404, "application/json", JSON.stringify({ error: "FEED_NOT_FOUND" })];
        }
        // Feed item data is loaded lazily (Zotero's own UI waits for it
        // before showing a feed); saving an unloaded FeedItem throws
        // "'itemData' not loaded for feedItem".
        await feed.waitForDataLoad("item");

        var updated = 0;
        for (var i = 0; i < itemKeys.length; i++) {
          var item = Zotero.Items.getByLibraryAndKey(libraryID, itemKeys[i]);
          if (item && item.isFeedItem) {
            // toggleRead() saves and refreshes the feed's unread count.
            await item.toggleRead(read);
            updated++;
          }
        }

        return [200, "application/json", JSON.stringify({ success: true, updated: updated })];
      } catch (e) {
        Zotero.logError("setFeedItemsRead error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  // Subscribes to a feed the way Zotero's "New Feed > From URL" dialog does
  // (feedSettings.js + ZoteroPane.newFeedFromURL): parse it with FeedReader
  // first so only real RSS/Atom URLs get saved, default the name to the
  // feed's own title, then save and do the first fetch. Refresh/cleanup
  // settings fall back to the user's Zotero feed preferences in _initSave.
  Zotero.Server.Endpoints["/connector/addFeed"] = function () {};
  Zotero.Server.Endpoints["/connector/addFeed"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var data = requestData.data;
        var url = (data.url || "").trim();
        if (!url) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_URL" })];
        }
        if (!/^https?:\/\//i.test(url)) {
          return [400, "application/json", JSON.stringify({ error: "URL must start with http:// or https://" })];
        }
        if (Zotero.Feeds.existsByURL(url)) {
          return [409, "application/json", JSON.stringify({ error: "Already subscribed to this feed" })];
        }

        var props;
        var reader = new Zotero.FeedReader(url);
        try {
          await reader.process();
          props = reader.feedProperties;
        } catch (e) {
          return [422, "application/json", JSON.stringify({ error: "Not a valid RSS/Atom feed: " + (e.message || String(e)) })];
        } finally {
          try { reader.terminate("done"); } catch (_) {}
        }

        var feed = new Zotero.Feed();
        feed.url = url;
        feed.name = (data.name && data.name.trim()) || props.title || url;
        if (props.ttl) {
          feed.refreshInterval = props.ttl;
        }
        await feed.saveTx();
        await feed.updateFeed();

        return [200, "application/json", JSON.stringify({
          success: true,
          libraryID: feed.libraryID,
          name: feed.name,
          lastCheckError: feed.lastCheckError || null,
        })];
      } catch (e) {
        Zotero.logError("addFeed error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  Zotero.Server.Endpoints["/connector/deleteFeed"] = function () {};
  Zotero.Server.Endpoints["/connector/deleteFeed"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var feed = Zotero.Feeds.get(requestData.data.libraryID);
        if (!feed) {
          return [404, "application/json", JSON.stringify({ error: "FEED_NOT_FOUND" })];
        }
        var name = feed.name;
        await feed.eraseTx();
        return [200, "application/json", JSON.stringify({ success: true, name: name })];
      } catch (e) {
        Zotero.logError("deleteFeed error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  // Refreshes one feed ({libraryID}) or every feed. Uses updateFeed() per
  // feed rather than Zotero.Feeds.updateFeeds(), which skips feeds that
  // aren't due yet -- same as the "Refresh" action in Zotero's feed menu.
  Zotero.Server.Endpoints["/connector/refreshFeeds"] = function () {};
  Zotero.Server.Endpoints["/connector/refreshFeeds"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var libraryID = requestData.data && requestData.data.libraryID;
        var feeds;
        if (libraryID) {
          var one = Zotero.Feeds.get(libraryID);
          if (!one) {
            return [404, "application/json", JSON.stringify({ error: "FEED_NOT_FOUND" })];
          }
          feeds = [one];
        } else {
          feeds = Zotero.Feeds.getAll();
        }
        var errors = [];
        for (var i = 0; i < feeds.length; i++) {
          // Same lazy-load requirement as above; Zotero.Feeds.updateFeeds()
          // does this too before _updateFeed().
          await feeds[i].waitForDataLoad("item");
          await feeds[i].updateFeed();
          if (feeds[i].lastCheckError) {
            errors.push({ name: feeds[i].name, error: feeds[i].lastCheckError });
          }
        }
        return [200, "application/json", JSON.stringify({ success: true, refreshed: feeds.length, errors: errors })];
      } catch (e) {
        Zotero.logError("refreshFeeds error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

  // Imports feeds from OPML text (the caller reads the file). Zotero's own
  // importFromOPML() skips already-subscribed URLs and refreshes afterwards;
  // report how many feeds it actually added.
  Zotero.Server.Endpoints["/connector/importOPML"] = function () {};
  Zotero.Server.Endpoints["/connector/importOPML"].prototype = {
    supportedMethods: ["POST"],
    supportedDataTypes: ["application/json"],
    init: async function (requestData) {
      try {
        var opml = requestData.data.opml;
        if (!opml) {
          return [400, "application/json", JSON.stringify({ error: "MISSING_OPML" })];
        }
        var before = Zotero.Feeds.getAll().length;
        var ok = await Zotero.Feeds.importFromOPML(opml);
        if (!ok) {
          return [422, "application/json", JSON.stringify({ error: "Could not parse OPML" })];
        }
        var added = Zotero.Feeds.getAll().length - before;
        return [200, "application/json", JSON.stringify({ success: true, added: added })];
      } catch (e) {
        Zotero.logError("importOPML error: " + (e.message || String(e)));
        return [500, "application/json", JSON.stringify({ error: e.message || String(e) })];
      }
    },
  };

    Zotero.logError("zotero-nvim-connector: startup complete");
  } catch (e) {
    Zotero.logError("zotero-nvim-connector: startup FAILED: " + (e.message || String(e)));
  }
}

function shutdown() {
  delete Zotero.Server.Endpoints["/connector/updateItem"];
  delete Zotero.Server.Endpoints["/connector/regenerateKey"];
  delete Zotero.Server.Endpoints["/connector/addAttachment"];
  delete Zotero.Server.Endpoints["/connector/createItem"];
  delete Zotero.Server.Endpoints["/connector/fetchMetadata"];
  delete Zotero.Server.Endpoints["/connector/addByIdentifier"];
  delete Zotero.Server.Endpoints["/connector/deleteItem"];
  delete Zotero.Server.Endpoints["/connector/deleteItems"];
  delete Zotero.Server.Endpoints["/connector/eraseItem"];
  delete Zotero.Server.Endpoints["/connector/eraseItems"];
  delete Zotero.Server.Endpoints["/connector/createCollection"];
  delete Zotero.Server.Endpoints["/connector/addToCollection"];
  delete Zotero.Server.Endpoints["/connector/trashCollection"];
  delete Zotero.Server.Endpoints["/connector/eraseCollection"];
  delete Zotero.Server.Endpoints["/connector/importFile"];
  delete Zotero.Server.Endpoints["/connector/mergeItems"];
  delete Zotero.Server.Endpoints["/connector/setFeedItemsRead"];
  delete Zotero.Server.Endpoints["/connector/addFeed"];
  delete Zotero.Server.Endpoints["/connector/deleteFeed"];
  delete Zotero.Server.Endpoints["/connector/refreshFeeds"];
  delete Zotero.Server.Endpoints["/connector/importOPML"];
}
