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

      await item.save();

      return [200, "application/json", JSON.stringify({ success: true })];
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

        var identifiers = Zotero.Utilities.extractIdentifiers(String(identifier));
        if (!identifiers || !identifiers.length) {
          return [400, "application/json", JSON.stringify({ error: "NO_IDENTIFIER_FOUND" })];
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

    Zotero.logError("zotero-nvim-connector: startup complete");
  } catch (e) {
    Zotero.logError("zotero-nvim-connector: startup FAILED: " + (e.message || String(e)));
  }
}

function shutdown() {
  delete Zotero.Server.Endpoints["/connector/updateItem"];
  delete Zotero.Server.Endpoints["/connector/regenerateKey"];
  delete Zotero.Server.Endpoints["/connector/addAttachment"];
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
}
