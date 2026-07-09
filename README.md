# zotero.nvim

Neovim plugin for browsing your Zotero library. Reads the SQLite database directly — no exports required.

> **Note:** This plugin is under active development. Bug reports and pull requests are very welcome.

## Features

- Collections tree with expand/collapse, item counts, and section jumps
- Item table with configurable columns and column presets
- Detail panel showing full metadata, abstract, tags, notes, attachments
- Fuzzy search (fzf-lua / telescope) and literal search (_EXPERIMENTAL_)
- Item marking system: toggle marks, filter to show only marked items
- PDF import via Zotero Connector API with duplicate detection
- Add items by identifier (DOI, ISBN, PMID, arXiv)
- Add PDF attachments to existing items
- Edit item metadata (requires companion Zotero plugin)
- Batch delete / trash with visual selection support
- Create and trash collections

## Requirements

- Neovim >= 0.9
- `sqlite3` CLI (e.g. `apt install sqlite3`)
- A local Zotero database at one of the standard locations: `~/Zotero/zotero.sqlite`, `~/.zotero/zotero.sqlite`, `~/.local/share/zotero/zotero.sqlite`
- **Zotero Connector**: In Zotero, enable _Settings → Advanced → Allow other applications on this computer to communicate with Zotero_ (Required for PDF import, add-by-identifier, and metadata editing)

## Installation

Then run `:Zotero` or press `<leader>zz` to open.

<details open>
<summary><strong>Neovim native package manager</strong></summary>

```lua
vim.pack.add({
  'https://github.com/urtzienriquez/zotero.nvim',
})

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

  -- Command to open PDF attachments.
  -- Examples: "xdg-open", "zathura", "open", "evince"
  pdf_viewer = "xdg-open",

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
    items_focus_collections  = "<Tab>",
    items_show_help          = "?",

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
    collections_focus_items_esc = "<Esc>",
  },
})
```

Column presets can be cycled with `<leader>zv`: configured, compact, normal, full. The preset determines which subset of the configured columns is shown.

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
| `<CR>`       | Select collection / expand-collapse / open Trash or Marked |
| `<Tab>`      | Focus items pane                                           |
| `<leader>zt` | Toggle collections pane                                    |
| `<leader>zN` | Create new collection                                      |
| `<leader>zD` | Trash selected collection                                  |

### Items Pane

| Key          | Action                                                |
| ------------ | ----------------------------------------------------- |
| `j` / `k`    | Navigate up/down                                      |
| `<CR>`       | Show item detail                                      |
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
| `<Tab>`      | Focus collections pane                                |
| `?`          | Show help popup                                       |

### Edit Buffer

| Key                          | Action                                |
| ---------------------------- | ------------------------------------- |
| `:ZoteroSave` / `<leader>zs` | Save changes to Zotero                |
| `?`                          | List available fields for item type   |
| `<leader>zk`                 | Regenerate Better BibTeX citation key |
| `q`                          | Close editor                          |

## Commands

| Command                | Action                             |
| ---------------------- | ---------------------------------- |
| `:Zotero`              | Open the Zotero library browser    |
| `:ZoteroDebug`         | Print database path and stats      |
| `:ZoteroImport {path}` | Import a PDF via the Connector API |

## PDF Import & Duplicate Detection

`<leader>zi` and `:ZoteroImport` accept a file path and import the PDF into Zotero via the Connector API (`localhost:23119`). The plugin checks for duplicates by matching title and year (extracted from PDF metadata) against existing items. If a potential duplicate is found, a `vim.ui.select` prompt lets you skip, add anyway, or replace.

## Zotero Companion Plugin

Metadata editing (`<leader>ze`) and Better BibTeX key regeneration require the companion plugin:

```bash
cd zotero_plugin
./build.sh
# Then in Zotero: Tools → Add-ons → Install From File → select the .xpi
```

After installing and restarting Zotero, open an item's edit buffer with `<leader>ze`.

## License

GNU General Public License v3.0
