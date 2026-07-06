# zotero.nvim

Neovim plugin for browsing your Zotero library. Reads the SQLite database
directly — no exports required.

## Requirements

- Neovim >= 0.9
- `sqlite3` CLI (e.g. `apt install sqlite3`)
- A local Zotero database at `~/Zotero/zotero.sqlite`

## Installation

```lua
-- lazy.nvim
{
  "urtzienriquez/zotero.nvim",
  config = true,
}
```

Then run `:Zotero` to open.

## Usage

| Keys | Action |
|------|--------|
| `j` / `k` | Navigate items |
| `<CR>` | Show item detail |
| `<leader>zf` | Fuzzy search |
| `<leader>z/` | Search (literal) |
| `<leader>zc` | Clear search |
| `<leader>zs` / `zS` / `zt` / `zd` | Sort by title/year/type/date |
| `<leader>zo` | Open attachment |
| `<leader>zb` | Open URL/DOI in browser |
| `<leader>zi` | Import PDF (standalone) |
| `<leader>za` | Add PDF attachment to item |
| `<leader>ze` | Edit item metadata (requires plugin) |
| `<leader>zr` | Refresh |
| `?` | Help |

In collections pane: `h`/`l` collapse/expand, `<CR>` select, `<Tab>` switch panes.

## PDF Import & Metadata Editing

PDF import works out of the box via Zotero's connector API on `localhost:23119`.

Metadata editing requires the companion Zotero plugin:

```bash
cd zotero_plugin
./build.sh
# Then in Zotero: Tools → Add-ons → Install From File → select the .xpi
```

After installing, `<leader>ze` on an item opens a JSON editor. Keymap in editor:

| Keys | Action |
|------|--------|
| `:ZoteroSave` / `<leader>zs` | Save changes |
| `?` | List available fields for item type |
| `<leader>zk` | Regenerate Better BibTeX citation key |
| `q` | Close editor |

## Configuration

```lua
require("zotero").setup({
  db_path = "~/Zotero/zotero.sqlite",   -- path to your DB
  keymap_prefix = "<leader>z",           -- prefix for global keymaps
  max_items = 500,                       -- max items per list
  columns = { "#", "key", "title", "authors", "year", "journal", "dateAdded" },
})
```
