# zotero.nvim

Neovim plugin for browsing your Zotero library. Reads the SQLite database directly — no exports required.

> **Note:** This plugin is under active development. Bug reports and pull requests are very welcome.

## Features

- Collections tree with expand/collapse, item counts, and section jumps
- Item table with configurable columns and column presets
- Detail panel showing full metadata, abstract, tags, notes, attachments
- Fuzzy search (fzf-lua / telescope) and literal search (_EXPERIMENTAL_)
- Item marking system: toggle marks, filter to show only marked items
- Filter the item list by item type on the fly (`<leader>zT` / `:ZoteroFilterType`)

  `<leader>zT` opens a checklist of the item types in the current view, with
  counts. `<CR>`/`<Space>` shows or hides the type under the cursor, `o` shows
  only that type, `a` shows all types again, `q` closes. The list updates as
  you go, and the filter stays on when you switch collections or feeds.
- Read-only Feeds section with unread counts (feed items never mix into My Library)
- PDF import via Zotero Connector API with duplicate detection
- Add items by identifier (DOI, ISBN, PMID, arXiv)
- Add PDF attachments to existing items
- Edit item metadata
- Batch delete / trash with visual selection support
- Create collections, move items into them, and trash/erase them

> Browsing and searching work out of the box. Everything above that *writes*
> to your library — editing, creating/deleting items or collections, adding
> by identifier, attaching files, full-metadata PDF import — requires a small
> companion Zotero plugin. See [Zotero Companion Plugin](#zotero-companion-plugin).

## Requirements

- Neovim **nightly** (`vim.async` is used to keep the UI responsive while reading the database or talking to the connector)
  - **Neovim < 0.13:** the `vim.async` API is not available there. Pin your install to `v0.0.2`.
- `sqlite3` CLI (e.g. `apt install sqlite3`)
- A local Zotero database at one of the standard locations: `~/Zotero/zotero.sqlite`, `~/.zotero/zotero.sqlite`, `~/.local/share/zotero/zotero.sqlite`
- **Zotero Connector**: In Zotero, enable _Settings → Advanced → Allow other applications on this computer to communicate with Zotero_ (required for every Connector-based feature, whether it needs the companion plugin or not)

## Installation

Then run `:Zotero` or press `<leader>zz` to open.

<details open>
<summary><strong>Neovim native package manager</strong></summary>

```lua
vim.pack.add({
  'https://github.com/urtzienriquez/zotero.nvim',
})

-- if you are not on neovim nightly, installed v0.0.2
-- where there is not vim.async:
-- vim.pack.add({{ src = gh("urtzienriquez/zotero.nvim"), version = "v0.0.2" },})

require("zotero").setup()
```

</details>

<details>
<summary><strong>lazy.nvim</strong></summary>

```lua
{
  "urtzienriquez/zotero.nvim",
  config = function()
    require("zotero").setup({
      db_path = "~/Zotero/zotero.sqlite",  -- optional, auto-detected
    })
  end,
}
```

</details>

## Configuration

All options have defaults. Call `setup()` to override anything you need.

```lua
require("zotero").setup({

  -- Path to zotero.sqlite. Auto-detected if not set.
  -- Searches: ~/Zotero/, ~/.zotero/, ~/.local/share/zotero/, etc.
  db_path = nil,

  -- Initial sort column.
  -- Available: "dateAdded" | "year" | "title" | "dateModified"
  default_sort = "dateAdded",

  -- Initial sort direction.
  default_sort_dir = "desc",

  -- Max items loaded at once (prevents lag with huge libraries).
  max_items = 500,

  -- Command to open attachments and URLs/DOIs.
  -- nil (default) uses the OS handler via vim.ui.open()
  -- (open on macOS, xdg-open on Linux, start on Windows).
  -- Examples: "zathura", "evince", "sioyek"
  pdf_viewer = nil,

  -- Item types hidden from the items list at startup (itemTypes.typeName).
  -- Change on the fly with <leader>zT or :ZoteroFilterType.
  -- Example: { "webpage", "note" }
  hidden_item_types = {},

  -- Column preset for feeds: "compact" | "normal" | "full" | "configured".
  -- Feeds remember their own preset (<leader>zv inside a feed only changes
  -- the feed view).
  feed_view = "compact",

  -- Fuzzy search backend.
  -- Valid: "fzf" | "telescope"
  backend = "fzf",

  -- Columns to display in the items table.
  -- Available: "#", "key", "title", "authors", "year", "journal",
  --            "dateAdded", "type"
  columns = { "#", "key", "title", "authors", "year", "journal", "dateAdded" },

  keymaps = {
    enabled      = true,           -- master switch; false disables all keymaps
    open_library = "<leader>zz",   -- toggle Zotero browser
    fuzzy_find   = "<leader>zf",   -- fuzzy search items

    -- Items pane keymaps (set nil or false to disable individual keymaps)
    items_show_detail        = "<CR>",
    items_toggle_read        = "<leader>zR",
    items_open_attachment    = "<leader>zo",
    items_open_url           = "<leader>zb",
    items_edit_item          = "<leader>ze",
    items_import_pdf         = "<leader>zi",
    items_attach_pdf         = "<leader>za",
    items_move_to_collection = "<leader>zM",
    items_add_by_identifier  = "<leader>zn",
    items_delete             = "<leader>zD",
    items_sort_title         = "<leader>zs",
    items_sort_year          = "<leader>zS",
    items_sort_date_added    = "<leader>zd",
    items_search             = "<leader>z/",
    items_clear_search       = "<leader>zc",
    items_refresh            = "<leader>zr",
    items_toggle_columns     = "<leader>zv",
    items_toggle_collections = "<leader>zt",
    items_toggle_mark        = "<leader>zm",
    items_show_only_marked   = "<leader>zl",
    items_filter_type        = "<leader>zT",
    toggle_statuscolumn      = "<leader>zg",
    items_focus_collections  = "<Tab>",
    items_show_help          = "g?",

    -- Collections pane keymaps
    collections_move_down       = "j",
    collections_move_up         = "k",
    collections_next_section    = "]]",
    collections_prev_section    = "[[",
    collections_select          = "<CR>",
    collections_toggle_pane     = "<leader>zt",
    collections_focus_items     = "<Tab>",
    collections_new             = "<leader>zN",
    collections_delete          = "<leader>zD",
    collections_refresh         = "<leader>zr",
    collections_focus_items_esc = "<Esc>",
    collections_show_help       = "g?",
  },
})
```

Column presets can be cycled with `<leader>zv`: configured, compact, normal, full. The preset determines which subset of the configured columns is shown.

By default the Zotero panes hide the statuscolumn (no signcolumn, line numbers, or relative numbers). Press `<leader>zg` in either pane to toggle the full statuscolumn on/off for both panes.

## Keymaps

### Global

| Key          | Action                                 |
| ------------ | -------------------------------------- |
| `<leader>zz` | Open/close Zotero browser              |
| `<leader>zf` | Fuzzy search all items (fzf/telescope) |

### Collections Pane

| Key          | Action                                                     |
| ------------ | ---------------------------------------------------------- |
| `j` / `k`    | Navigate up/down                                           |
| `]]` / `[[`  | Next / previous section                                    |
| `<CR>`       | Select collection / expand-collapse / open feed, Trash or Marked |
| `<Tab>`      | Focus items pane                                           |
| `<leader>zt` | Toggle collections pane                                    |
| `<leader>zN` | Create new collection (on Feeds or a feed: add a feed)     |
| `<leader>zD` | Trash selected collection (on a feed: unsubscribe)         |
| `<leader>zr` | Refresh (on a feed: fetch new items; on Feeds: all feeds)  |
| `g?`         | Open `:help` at the collections-pane keymaps               |

### Items Pane

| Key          | Action                                                |
| ------------ | ----------------------------------------------------- |
| `j` / `k`    | Navigate up/down                                      |
| `<CR>`       | Show item detail                                      |
| `<leader>zR` | Toggle read/unread (feed items; works on a selection) |
| `<leader>zo` | Open attached file                                    |
| `<leader>zb` | Open URL/DOI in browser                               |
| `<leader>ze` | Edit item metadata                                    |
| `<leader>zi` | Import PDF (standalone)                               |
| `<leader>za` | Attach PDF to selected item                           |
| `<leader>zM` | Move item to collection                               |
| `<leader>zn` | Add item by identifier (DOI/ISBN/PMID/arXiv)          |
| `<leader>zD` | Delete item (trash; permanent delete in Trash view)   |
| `<leader>zs` | Sort by title                                         |
| `<leader>zS` | Sort by year                                          |
| `<leader>zd` | Sort by date added                                    |
| `<leader>z/` | Search (literal)                                      |
| `<leader>zc` | Clear search                                          |
| `<leader>zr` | Refresh                                               |
| `<leader>zv` | Toggle column preset (configured/compact/normal/full) |
| `<leader>zt` | Toggle collections pane                               |
| `<leader>zm` | Toggle mark on item                                   |
| `<leader>zl` | Show only marked items                                |
| `<leader>zT` | Item-type checklist (show/hide types, with counts)    |
| `<leader>zg` | Toggle statuscolumn (signcolumn, numbers)             |
| `<Tab>`      | Focus collections pane                                |
| `g?`         | Open `:help` at the items-pane keymaps                |

### Edit Buffer

| Key                          | Action                                |
| ---------------------------- | ------------------------------------- |
| `:w` / `:ZoteroSave` / `<leader>zs` | Save changes to Zotero         |
| `K`                          | List available fields for item type   |
| `g?`                         | Open `:help` at the edit-buffer keymaps |
| `<leader>zk`                 | Regenerate Better BibTeX citation key |
| `q`                          | Close editor                          |

## Commands

| Command                | Action                             |
| ---------------------- | ---------------------------------- |
| `:Zotero`              | Open the Zotero library browser    |
| `:ZoteroDebug`         | Print database path and stats      |
| `:ZoteroImport {path}` | Import a PDF via the Connector API |
| `:ZoteroAddFeed [url] [name]` | Subscribe to an RSS/Atom feed (prompts for the URL when omitted; name defaults to the feed's title) |
| `:ZoteroImportOPML {file}` | Import feeds from an OPML file (already-subscribed URLs are skipped) |
| `:ZoteroRefreshFeeds` | Fetch new items for all feeds |
| `:ZoteroFilterType [all \| type... \| -type...]` | Filter items by type: no args opens the checklist, `all` clears, `book thesis` shows only those, `-webpage -note` hides those |

## Feeds

Zotero stores every feed (and every group) as its own library. zotero.nvim
shows only your personal library under **My Library**; subscribed feeds get
their own **Feeds** section in the collections pane, with unread counts
(shown as `Feeds (0)` until you subscribe to one).

Managing feeds works like in Zotero's *New Feed → From URL*:

- `<leader>zN` on the Feeds header (or any feed) asks for a URL. Zotero checks
  that it's a real RSS/Atom feed, names it after the feed's title, fetches
  it, and uses your Zotero defaults for refresh interval and cleanup.
  `:ZoteroAddFeed {url} [name]` does the same from the command line.
- `:ZoteroImportOPML {file}` subscribes to every feed in an OPML export.
- `<leader>zD` on a feed unsubscribes (its items are removed, as in Zotero).
- `<leader>zr` on a feed fetches new items now; on the Feeds header (or
  `:ZoteroRefreshFeeds`) it refreshes all feeds. `<leader>zr` in the items
  pane while viewing a feed refreshes that feed.

Press `<CR>` on a feed to list its items. On a feed item, `<CR>` opens the
preview (abstract and details) and `<leader>zb` opens its link
in your browser; either one marks the item as read, as viewing it in Zotero
does. `<leader>zR` toggles read/unread (on a visual selection too: if any
selected item is unread, all are marked read). Feeds open in the compact view by
default (`feed_view`), with a `●` in front of unread items (it disappears once
read); the view you pick with `<leader>zv` in a feed is remembered separately
from the library's. Otherwise feed items are read-only (to keep one, add it
with Zotero itself or `<leader>zn` by DOI).

Adding, removing and refreshing feeds and read/unread need version 1.2.1 or
later of the companion plugin (see below). Without it,
browsing and opening feed items still work but nothing is marked read.

## PDF Import & Duplicate Detection

`<leader>zi` and `:ZoteroImport` accept a file path and import the PDF into Zotero via the Connector API (`localhost:23119`). The plugin checks for duplicates by matching title and year (extracted from PDF metadata) against existing items. If a potential duplicate is found, a `vim.ui.select` prompt lets you skip, add anyway, or replace.

## Zotero Companion Plugin

Zotero's own built-in Connector server only implements a small, fixed set of
endpoints for the official browser extension (mainly `ping` and `saveItems`).
It has no concept of "update this item," "create a collection," "delete an
item," and so on — those aren't part of Zotero's API surface. To support
them, this plugin ships a small companion Zotero add-on (in `zotero_plugin/`)
that registers the additional endpoints directly inside Zotero.

The companion plugin is required for:

- Editing item metadata (`<leader>ze`) and Better BibTeX key regeneration (`<leader>zk`)
- Creating, moving items into, and trashing/erasing collections
- Adding items by identifier (DOI/ISBN/PMID/arXiv)
- Adding PDF attachments to existing items
- Deleting / permanently erasing items
- The "merge" option in duplicate-resolution prompts
- Full-metadata PDF import (auto-recognition of the PDF's contents)

Without it installed, PDF import (`<leader>zi` / `:ZoteroImport`) is designed
to fall back to Zotero's native `saveItems` endpoint and create a bare item
(filename as the title, no extracted metadata) rather than fail outright —
that's the one write path built entirely on Zotero's native API.

Install the companion plugin with:

```bash
cd zotero_plugin
./build.sh
# Then in Zotero: Tools → Add-ons → Install From File → select the .xpi
```

After installing and restarting Zotero, the features above become available.

## License

GNU General Public License v3.0
