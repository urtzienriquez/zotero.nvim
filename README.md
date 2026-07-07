# zotero.nvim

Neovim plugin for browsing your Zotero library. Reads the SQLite database
directly — no exports required.

## Features

- Collections tree with expand/collapse, item counts, and section jumps
- Item table with configurable columns and column presets
- Detail panel showing full metadata, abstract, tags, notes, attachments
- Fuzzy search (fzf-lua / telescope) and literal search
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
- A local Zotero database at one of the standard locations:
  `~/Zotero/zotero.sqlite`, `~/.zotero/zotero.sqlite`,
  `~/.local/share/zotero/zotero.sqlite`
- **Zotero Connector**: In Zotero, enable *Settings → Advanced →
  Allow other applications on this computer to communicate with Zotero*
  (Required for PDF import, add-by-identifier, and metadata editing)

## Installation

```lua
-- lazy.nvim
{
  "urtzienriquez/zotero.nvim",
  config = true,
}
```

Then run `:Zotero` or press `<leader>zz` to open.

## Configuration

```lua
require("zotero").setup({
  db_path = nil,            -- auto-detected; set explicitly if needed
  default_sort = "dateAdded", -- initial sort column: "dateAdded", "year", "title"
  default_sort_dir = "desc",  -- initial sort direction: "desc" or "asc"
  max_items = 500,          -- max items loaded at once
  pdf_viewer = "xdg-open",  -- command to open PDFs (e.g. "zathura", "open")
  backend = "fzf",          -- fuzzy search backend: "fzf" or "telescope"
  columns = { "#", "key", "title", "authors", "year", "journal", "dateAdded" },
  keymaps = {
    enabled = true,                    -- register global keymaps
    open_library = "<leader>zz",       -- toggle Zotero browser
  },
})
```

Available columns: `#`, `key`, `title`, `authors`, `year`, `journal`,
`dateAdded`, `type`.

Column presets can be cycled with `<leader>zv`: configured, compact,
normal, full.

## Keymaps

### Global

| Key | Action |
|-----|--------|
| `<leader>zz` | Open/close Zotero browser |
| `<leader>zf` | Fuzzy search all items (fzf/telescope) |

### Collections Pane

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate up/down |
| `]]` / `[[` | Next / previous section |
| `<CR>` | Select collection / expand-collapse / open Trash or Marked |
| `<Tab>` | Focus items pane |
| `<leader>zt` | Toggle collections pane |
| `<leader>zN` | Create new collection |
| `<leader>zD` | Trash selected collection |

### Items Pane

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate up/down |
| `<CR>` | Show item detail |
| `<leader>zo` | Open attached file |
| `<leader>zb` | Open URL/DOI in browser |
| `<leader>ze` | Edit item metadata |
| `<leader>zi` | Import PDF (standalone) |
| `<leader>za` | Attach PDF to selected item |
| `<leader>zm` | Move item to collection |
| `<leader>zn` | Add item by identifier (DOI/ISBN/PMID/arXiv) |
| `<leader>zD` | Delete item (trash; permanent delete in Trash view) |
| `<leader>zs` | Sort by title |
| `<leader>zS` | Sort by year |
| `<leader>zd` | Sort by date added |
| `<leader>z/` | Search (literal) |
| `<leader>zc` | Clear search |
| `<leader>zr` | Refresh |
| `<leader>zv` | Toggle column preset (configured/compact/normal/full) |
| `<leader>zt` | Toggle collections pane |
| `<leader>zM` | Toggle mark on item |
| `<leader>zL` | Show only marked items |
| `<Tab>` | Focus collections pane |
| `?` | Show help popup |

### Edit Buffer

| Key | Action |
|-----|--------|
| `:ZoteroSave` / `<leader>zs` | Save changes to Zotero |
| `?` | List available fields for item type |
| `<leader>zk` | Regenerate Better BibTeX citation key |
| `q` | Close editor |

## Commands

| Command | Action |
|---------|--------|
| `:Zotero` | Open the Zotero library browser |
| `:ZoteroDebug` | Print database path and stats |
| `:ZoteroImport {path}` | Import a PDF via the Connector API |

## PDF Import & Duplicate Detection

`<leader>zi` and `:ZoteroImport` accept a file path and import the PDF
into Zotero via the Connector API (`localhost:23119`). The plugin checks
for duplicates by matching title and year (extracted from PDF metadata)
against existing items. If a potential duplicate is found, a
`vim.ui.select` prompt lets you skip, add anyway, or replace.

## Zotero Companion Plugin

Metadata editing (`<leader>ze`) and Better BibTeX key regeneration
require the companion plugin:

```bash
cd zotero_plugin
./build.sh
# Then in Zotero: Tools → Add-ons → Install From File → select the .xpi
```

After installing and restarting Zotero, open an item's edit buffer with
`<leader>ze`.

## License

GNU General Public License v3.0
