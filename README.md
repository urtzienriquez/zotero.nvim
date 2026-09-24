# zotero.nvim

Neovim plugin for browsing your Zotero library. Reads the SQLite database directly — no exports required.

> [!IMPORTANT]
> **Pick the branch that matches your Neovim version:**
>
> | Your Neovim | Branch |
> | --- | --- |
> | nightly (0.13-dev) | [`main`](https://github.com/urtzienriquez/zotero.nvim/tree/main) |
> | 0.10, 0.11, 0.12 (stable releases) | [`v0`](https://github.com/urtzienriquez/zotero.nvim/tree/v0) |
>
> Both branches have the same features and keymaps. `main` uses Neovim nightly's built-in `vim.async`; `v0` ships a small stand-in for it so it runs on stable releases. Follow the [Installation](#installation) instructions of the branch you are reading.

> **Note:** This plugin is under active development. Bug reports and pull requests are very welcome.

## Features

- Collections tree with expand/collapse, item counts, and section jumps
- Item table with configurable columns and column presets
- Detail panel showing full metadata, abstract, tags, notes, attachments
- Fuzzy search (fzf-lua / telescope) and literal search (_EXPERIMENTAL_)
- Item marking system: toggle marks, filter to show only marked items
- Filter the item list by item type on the fly (`ft` / `:ZoteroFilterType`)

  `ft` opens a checklist of the item types in the current view, with
  counts. `<CR>`/`<Space>` shows or hides the type under the cursor, `o` shows
  only that type, `a` shows all types again, `q` closes. The list updates as
  you go, and the filter stays on when you switch collections or feeds.
- Read-only Feeds section with unread counts (feed items never mix into My Library)
- Tags like in Zotero: `t1`–`t9` toggle your Zotero colored tags on the item(s)
  (coloured ● dots show them in the list), `tt` opens a checklist to add or remove
  several tags at once (`cc` assigns a colour, `dd` deletes a tag), and `fT` or the
  Tags section of the collections pane filter the list by tag
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

- Neovim **>= 0.10** (this is the `v0` branch; on Neovim nightly you can also use `main`, see the note at the top)
- `sqlite3` CLI (e.g. `apt install sqlite3`)
- A local Zotero database at one of the standard locations: `~/Zotero/zotero.sqlite`, `~/.zotero/zotero.sqlite`, `~/.local/share/zotero/zotero.sqlite`
- **Zotero Connector**: In Zotero, enable _Settings → Advanced → Allow other applications on this computer to communicate with Zotero_ (required for every Connector-based feature, whether it needs the companion plugin or not)

## Installation

These instructions install the **`v0` branch** (Neovim 0.10 and newer). Then run `:Zotero` or press `<leader>zz` to open.

<details open>
<summary><strong>lazy.nvim</strong></summary>

```lua
{
  "urtzienriquez/zotero.nvim",
  branch = "v0",
  config = function()
    require("zotero").setup({
      db_path = "~/Zotero/zotero.sqlite",  -- optional, auto-detected
    })
  end,
}
```

</details>

<details>
<summary><strong>Neovim native package manager (0.12+)</strong></summary>

```lua
vim.pack.add({
  { src = "https://github.com/urtzienriquez/zotero.nvim", version = "v0" },
})

require("zotero").setup()
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
  -- Change on the fly with ft or :ZoteroFilterType.
  -- Example: { "webpage", "note" }
  hidden_item_types = {},

  -- Column preset for feeds: "compact" | "normal" | "full" | "configured".
  -- Feeds remember their own preset (tv inside a feed only changes
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

    -- Items pane (set any key to false to disable it).
    -- Want the old <leader>z... keys? See "Keeping the old keymaps" below.
    items_show_detail        = "<CR>",
    items_refresh            = "R",
    items_focus_collections  = "<Tab>",
    items_show_help          = "g?",
    items_open_attachment    = "oo",   -- o: open
    items_open_url           = "ob",
    items_edit_item          = "ee",   -- e: edit
    items_fix_attachment     = "ef",
    items_attach_pdf         = "aa",   -- a: add
    items_import_pdf         = "ai",
    items_add_by_identifier  = "an",
    items_delete             = "dd",
    items_move_to_collection = "cm",
    items_remove_from_collection = "cr",
    items_toggle_mark        = "mm",
    items_toggle_read        = "rr",
    items_yank_citation_key  = "yk",   -- y: yank
    items_yank_file_path     = "yp",
    items_sort_title         = "st",   -- s: sort
    items_sort_year          = "sy",
    items_sort_date_added    = "sd",
    items_search             = "ff",   -- f: filter
    items_clear_search       = "fc",
    items_filter_type        = "ft",
    items_filter_tag         = "fT",
    items_toggle_colored_tag = "t",    -- t1..t9: Zotero colored tag N
    items_toggle_tag         = "tt",
    items_toggle_columns     = "tv",   -- t: toggle view
    items_toggle_collections = "tc",
    toggle_statuscolumn      = "ts",
    items_help_open          = "o?",   -- <family>?: :help for that family
    items_help_edit          = "e?",
    items_help_add           = "a?",
    items_help_sort          = "s?",
    items_help_filter        = "f?",
    items_help_toggle        = "t?",
    items_help_yank          = "y?",
    items_show_only_marked   = "gm",   -- g: navigation (both panes)
    goto_library             = "gl",
    goto_feeds               = "gf",
    goto_trash               = "gd",

    -- Collections pane
    collections_move_down       = "j",
    collections_move_up         = "k",
    collections_next_section    = "]]",
    collections_prev_section    = "[[",
    collections_select          = "<CR>",
    collections_focus_items     = "<Tab>",
    collections_focus_items_esc = "<Esc>",
    collections_new             = "aa",
    collections_delete          = "dd",
    collections_tag_colour      = "cc",
    collections_refresh         = "R",
    collections_toggle_pane     = "tc",
    collections_show_help       = "g?",
  },
})
```

Column presets can be cycled with `tv`: configured, compact, normal, full. The preset determines which subset of the configured columns is shown.

By default the Zotero panes hide the statuscolumn (no signcolumn, line numbers, or relative numbers). Press `ts` in either pane to toggle the full statuscolumn on/off for both panes.

## Keymaps

### Global

| Key          | Action                                 |
| ------------ | -------------------------------------- |
| `<leader>zz` | Open/close Zotero browser              |
| `<leader>zf` | Fuzzy search all items (fzf/telescope) |

Inside the browser, keys come in short two-key families named after what they
do, in the spirit of vim-fugitive: `o` open, `e` edit, `a` add, `y` yank,
`s` sort, `f` filter, `t` toggle view. `<family>?` (e.g. `s?`) opens `:help` at that
family, and `g?` at the whole list. The `g` prefix is only used for
navigation. Every key can be remapped; see
[Keeping the old keymaps](#keeping-the-old-keymaps).

### Collections Pane

My Library, Feeds, Tags and collections with sub-collections are real Vim folds, so `zo`/`zc`/`za`/`zR`/`zM` (and the rest of Vim's fold commands) work as usual. My Library and top-level collections start open, Feeds and Tags start folded, and the pane keeps your folds when it refreshes. In the Tags section, `<CR>` on a tag adds it to or removes it from the tag filter (the cursor stays in the pane, so you can combine tags).

| Key               | Action                                                     |
| ----------------- | ---------------------------------------------------------- |
| `j` / `k`         | Navigate up/down                                           |
| `]]` / `[[`       | Next / previous section                                    |
| `<CR>`            | Select collection / expand-collapse / open feed, Trash or Marked (on Feeds: open/close it) |
| `zo` `zc` `za` `zR` `zM` … | Vim's fold commands: open/close sections and collections |
| `<Tab>` / `<Esc>` | Focus items pane                                           |
| `aa`              | Add a collection (on Feeds or a feed: add a feed)          |
| `dd`              | Trash the collection (on a feed: unsubscribe; on a tag: delete it from all items; on a visual selection of tags: delete them all) |
| `cc`              | On a tag: assign/remove its colour and number key (1–9), like Zotero's "Assign Colour…" |
| `R`               | Refresh (on a feed: fetch new items; on Feeds: all feeds)  |
| `tc` / `ts`       | Toggle collections pane / statuscolumn                     |
| `gl` `gf` `gm` `gd` | Go to My Library / Feeds / marked items / Trash          |
| `g?`              | Open `:help` at the collections-pane keymaps               |

### Items Pane

| Key         | Action                                                  |
| ----------- | ------------------------------------------------------- |
| `j` / `k`   | Navigate up/down                                        |
| `<CR>`      | Show item detail                                        |
| `R`         | Refresh (in a feed: fetch new items first)              |
| `<Tab>`     | Focus collections pane                                  |
| `oo` / `ob` | Open attached file / open URL or DOI in the browser     |
| `yk` / `yp` | Yank citation key / full path of the attached file (use `"+yk` for the clipboard) |
| `ee` / `ef` | Edit metadata / fix attachment or update from a DOI     |
| `aa`        | Attach a PDF to the item                                |
| `ai`        | Import a PDF as a new item                              |
| `an`        | Add item by identifier (DOI/ISBN/PMID/arXiv)            |
| `dd`        | Trash item(s); permanent delete in Trash                |
| `cm`        | Move item(s) to a collection                            |
| `cr`        | Remove item(s) from the collection you're viewing (they stay in My Library; needs companion plugin 1.5.0) |
| `mm`        | Toggle mark                                             |
| `rr`        | Toggle read/unread (feed items)                         |
| `st` / `sy` / `sd` | Sort by title / year / date added (again: reverse) |
| `ff` / `fc` | Search (fields, phrases, AND/OR/NOT, notes, PDF full text: `:h zotero-search`) / clear search |
| `ft`        | Item-type checklist (show/hide types, with counts)      |
| `fT`        | Tag checklist: show only items with the checked tags    |
| `t1`…`t9`   | Toggle Zotero colored tag 1–9 on the item(s) (visual selection too) |
| `tt`        | Checklist of the item(s)' tags: add/remove several at once, `n` for a new one |
| `tv`        | Toggle column preset (configured/compact/normal/full)   |
| `tc` / `ts` | Toggle collections pane / statuscolumn                  |
| `gl` `gf` `gm` `gd` | Go to My Library / Feeds / marked only / Trash  |
| `o?` `e?` `a?` `y?` `s?` `f?` `t?` | `:help` for that family         |
| `g?`        | Open `:help` at the items-pane keymaps                  |

`dd`, `cm`, `cr`, `mm` and `rr` also work on a visual selection.

### Edit Buffer

| Key                          | Action                                |
| ---------------------------- | ------------------------------------- |
| `:w` / `:ZoteroSave` / `<leader>zs` | Save changes to Zotero         |
| `K`                          | List available fields for item type   |
| `g?`                         | Open `:help` at the edit-buffer keymaps |
| `<leader>zk`                 | Regenerate Better BibTeX citation key |
| `q`                          | Close editor                          |

### Keeping the old keymaps

Earlier versions used `<leader>z` + a letter for everything. To keep those
keys, pass them to `setup()`:

```lua
require("zotero").setup({
  keymaps = {
    items_open_attachment = "<leader>zo", items_open_url = "<leader>zb",
    items_edit_item = "<leader>ze",       items_fix_attachment = "<leader>zF",
    items_attach_pdf = "<leader>za",      items_import_pdf = "<leader>zi",
    items_add_by_identifier = "<leader>zn",
    items_delete = "<leader>zD",          items_move_to_collection = "<leader>zM",
    items_toggle_mark = "<leader>zm",     items_toggle_read = "<leader>zR",
    items_sort_title = "<leader>zs",      items_sort_year = "<leader>zS",
    items_sort_date_added = "<leader>zd",
    items_search = "<leader>z/",          items_clear_search = "<leader>zc",
    items_filter_type = "<leader>zT",     items_show_only_marked = "<leader>zl",
    items_refresh = "<leader>zr",         items_toggle_columns = "<leader>zv",
    items_toggle_collections = "<leader>zt",
    toggle_statuscolumn = "<leader>zg",
    collections_new = "<leader>zN",       collections_delete = "<leader>zD",
    collections_refresh = "<leader>zr",   collections_toggle_pane = "<leader>zt",
  },
})
```

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

- `aa` on the Feeds header (or any feed) asks for a URL. Zotero checks
  that it's a real RSS/Atom feed, names it after the feed's title, fetches
  it, and uses your Zotero defaults for refresh interval and cleanup.
  `:ZoteroAddFeed {url} [name]` does the same from the command line.
- `:ZoteroImportOPML {file}` subscribes to every feed in an OPML export.
- `dd` on a feed unsubscribes (its items are removed, as in Zotero).
- `R` on a feed fetches new items now; on the Feeds header (or
  `:ZoteroRefreshFeeds`) it refreshes all feeds. `R` in the items
  pane while viewing a feed refreshes that feed.

Press `<CR>` on a feed to list its items. On a feed item, `<CR>` opens the
preview (abstract and details) and `ob` opens its link
in your browser; either one marks the item as read, as viewing it in Zotero
does. `rr` toggles read/unread (on a visual selection too: if any
selected item is unread, all are marked read). Feeds open in the compact view by
default (`feed_view`), with a `●` in front of unread items (it disappears once
read); the view you pick with `tv` in a feed is remembered separately
from the library's. Otherwise feed items are read-only (to keep one, add it
with Zotero itself or `an` by DOI).

Adding, removing and refreshing feeds and read/unread need version 1.2.1 or
later of the companion plugin (see below); toggling tags (`t1`–`t9`, `tt`)
needs 1.3.0 or later, and colouring / deleting tags (`cc`, `dd`) 1.4.0. Without it,
browsing and opening feed items still work but nothing is marked read.

## PDF Import & Duplicate Detection

`ai` and `:ZoteroImport` accept a file path and import the PDF into Zotero via the Connector API (`localhost:23119`). The plugin checks for duplicates by matching title and year (extracted from PDF metadata) against existing items. If a potential duplicate is found, a `vim.ui.select` prompt lets you skip, add anyway, or replace.

## Zotero Companion Plugin

Zotero's own built-in Connector server only implements a small, fixed set of
endpoints for the official browser extension (mainly `ping` and `saveItems`).
It has no concept of "update this item," "create a collection," "delete an
item," and so on — those aren't part of Zotero's API surface. To support
them, this plugin ships a small companion Zotero add-on (in `zotero_plugin/`)
that registers the additional endpoints directly inside Zotero.

The companion plugin is required for:

- Editing item metadata (`ee`) and Better BibTeX key regeneration (`<leader>zk`)
- Creating, moving items into, and trashing/erasing collections
- Adding items by identifier (DOI/ISBN/PMID/arXiv)
- Adding PDF attachments to existing items
- Deleting / permanently erasing items
- The "merge" option in duplicate-resolution prompts
- Full-metadata PDF import (auto-recognition of the PDF's contents)

Without it installed, PDF import (`ai` / `:ZoteroImport`) is designed
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
