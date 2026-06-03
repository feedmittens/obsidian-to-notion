# obsidian-to-notion

Migrate an Obsidian vault to Notion — markdown files, attachments, folder hierarchy, wiki-links, and all.

## What it does

- Walks your vault and recreates the folder tree as nested Notion pages
- Converts Obsidian-flavored markdown: `[[wiki-links]]`, `![[embedded images]]`, callouts (`> [!NOTE]`), checkboxes, code blocks, inline formatting
- Uploads local attachments (images, PDFs) to Notion via the file upload API
- Resolves cross-note links after all pages are created (two-pass approach)
- Resumes from where it left off if interrupted — re-running the same command is safe
- Dry-run mode prints exactly what would happen without touching Notion

## What's not supported

- **Canvas files** (`.canvas`) — Obsidian's graph format has no Notion equivalent; these are skipped
- **Dataview queries** — rendered as raw code blocks
- **Plugin-specific syntax** (Excalidraw, Templater, etc.) — treated as plain text
- **Nested list indentation** — Notion's API flattens nested lists; indented items become top-level
- **Tables** — basic markdown tables are passed through as paragraphs (Notion table API is complex; PRs welcome)
- **Files > 20 MB** — Notion's upload API limit

## Quick start

Download the installer for your platform and run it — it handles everything else.

**macOS**
```bash
curl -fsSL https://raw.githubusercontent.com/feedmittens/obsidian-to-notion/main/install.sh -o migrate.sh
chmod +x migrate.sh && ./migrate.sh
```

**Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/feedmittens/obsidian-to-notion/main/install-linux.sh -o migrate.sh
chmod +x migrate.sh && ./migrate.sh
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/feedmittens/obsidian-to-notion/main/install.ps1" -OutFile migrate.ps1
.\migrate.ps1
```

> **Windows note:** if scripts are blocked, first run:
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

Each installer will:
1. Check for Python 3.10+ and tell you how to install it if missing
2. Download and set up the tool automatically
3. Auto-detect your Obsidian vaults
4. Walk you through creating a Notion integration token and picking a root page
5. Run a dry-run preview before touching anything
6. Run the real migration, saving progress so it can resume if interrupted

---

## Prerequisites (manual / developer setup)

If you'd rather not use the installer:

### 1. Notion integration

1. Go to [notion.so/my-integrations](https://www.notion.so/my-integrations)
2. Click **New integration**, give it a name, and copy the **Internal Integration Token** (`secret_...`)
3. Open Notion, create or navigate to the page you want to migrate into
4. Click `···` → **Connect to** → select your integration
5. Copy the page ID from the URL: `notion.so/PAGE_ID` (the 32-character hex string)

### 2. Python 3.10+

```bash
python3 --version   # need 3.10 or newer
```

### 3. Install dependencies

```bash
git clone https://github.com/feedmittens/obsidian-to-notion.git
cd obsidian-to-notion
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

## Usage

### Dry run first — always

```bash
python obsidian_to_notion.py \
  --vault ~/Documents/MyVault \
  --token secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  --root-page abcdef1234567890abcdef1234567890 \
  --dry-run
```

This prints what would be created without making any Notion API calls. Good sanity check before committing.

### Real migration

```bash
python obsidian_to_notion.py \
  --vault ~/Documents/MyVault \
  --token secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  --root-page abcdef1234567890abcdef1234567890
```

Progress is saved to `migration_state.json` as it runs. If interrupted, re-run the same command to pick up where it left off.

### Skip attachment uploads

```bash
python obsidian_to_notion.py \
  --vault ~/Documents/MyVault \
  --token secret_xxx \
  --root-page PAGE_ID \
  --skip-attachments
```

Attachment references are kept as inline notes (`[Attachment: filename.png]`) so you can find and replace them later.

### Start over

```bash
python obsidian_to_notion.py \
  --vault ~/Documents/MyVault \
  --token secret_xxx \
  --root-page PAGE_ID \
  --reset
```

Deletes `migration_state.json` and starts fresh. If the previous run already created pages in Notion, clean those up manually first to avoid duplicates.

## All options

| Flag | Default | Description |
|------|---------|-------------|
| `--vault` | required | Path to your Obsidian vault directory |
| `--token` | required | Notion integration token (`secret_...`) |
| `--root-page` | required | Notion page ID to migrate content into |
| `--dry-run` | off | Preview without any API calls |
| `--skip-attachments` | off | Skip file uploads; note filenames as text |
| `--reset` | off | Delete state file and restart from scratch |
| `--state-file` | `migration_state.json` | Custom path for the resume state file |

## How it works

**Phase 1 — Scaffold:** Every `.md` file and folder gets a corresponding empty Notion page created in the right place. A `wiki_map` (lowercase note title → Notion page ID) is built from this pass.

**Phase 2 — Populate:** Each page is filled with content. Inline `[[wiki-links]]` are resolved using the `wiki_map` built in Phase 1, so cross-note links work regardless of what order notes are processed.

Attachments referenced by `![[filename]]` are located by searching the vault recursively, then uploaded via the Notion file upload API. If upload fails (plan limit, network error, etc.) the block is replaced with a text note.

## Rate limiting

Notion's API allows ~3 requests per second. The tool enforces a 350ms delay between calls and retries with exponential backoff on 429 responses. A 1000-note vault takes roughly 10–15 minutes.

## Development

```bash
# Run tests (no Notion account needed)
source .venv/bin/activate
pytest test_converter.py -v

# 52 tests cover: inline parser, block parser, attachment resolution,
# callout mapping, frontmatter extraction, cross-link resolution
```

## Contributing

Bug reports and PRs welcome. The most wanted improvements:

- Table support (Notion table block API)
- Nested list children (Notion supports children blocks)
- Canvas file conversion (maybe as a list of linked pages?)

## License

MIT

---

## Changelog

### v0.5.0 — 2026-06-03
- Linux installer (`install-linux.sh`) with distro-aware Python hints and `xdg-open` browser support
- Windows PowerShell installer (`install.ps1`) with `winget`/`choco` hints and native vault detection
- Platform tab picker on landing page — auto-selects macOS/Linux/Windows based on visitor OS

### v0.4.0 — 2026-06-03
- Corkscrew Consulting Group SVG logo (`docs/logo-ccg.svg`)
- Footer branding linking to corkscrew-consulting.net

### v0.3.0 — 2026-06-03
- Interactive macOS installer wizard (`install.sh`)
- Auto-detects Obsidian vaults from `~/Library/Application Support/obsidian`
- Guides through Notion integration setup, dry-run, and migration in one flow
- Resume support: saves config to `~/.config/obsidian-to-notion/` (token never committed)

### v0.2.0 — 2026-06-03
- GitHub Pages landing page (`docs/index.html`)
- Dark-themed with feature grid, support matrix, and styled terminal install block

### v0.1.0 — 2026-06-03
- Initial release: two-phase Obsidian → Notion migration
- 52 unit tests (inline parser, block converter, attachment resolution, cross-link resolution)
- Dry-run mode, resume support, rate limiting with exponential backoff
- Handles: headings, lists, checkboxes, code blocks, callouts, wiki-links, embedded images, frontmatter
