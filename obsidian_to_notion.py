#!/usr/bin/env python3
"""
Obsidian → Notion migration tool.

Converts an Obsidian vault (markdown files + attachments) into a Notion workspace,
preserving folder hierarchy as nested pages.

Handles: headings, lists, checkboxes, code blocks, blockquotes, callouts,
         [[wiki-links]], ![[embedded images]], inline formatting, frontmatter tags.

Two-phase approach:
  Phase 1 (scaffold): Create all pages empty → build a complete wiki_map (title → page ID)
  Phase 2 (populate): Fill pages with content and resolve inter-page links

Resume support: migration_state.json tracks completed work so interruptions are safe.

Usage:
  pip install -r requirements.txt

  # Dry run — no Notion API calls:
  python obsidian_to_notion.py --vault ~/Documents/MyVault --token secret_xxx --root-page PAGE_ID --dry-run

  # Real migration:
  python obsidian_to_notion.py --vault ~/Documents/MyVault --token secret_xxx --root-page PAGE_ID

  # Resume after interruption (re-run same command):
  python obsidian_to_notion.py --vault ~/Documents/MyVault --token secret_xxx --root-page PAGE_ID

  # Reset state and start fresh:
  python obsidian_to_notion.py ... --reset
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
import sys
import time
from pathlib import Path

try:
    import frontmatter
    from notion_client import Client
    from tqdm import tqdm
    import requests
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Run: pip install -r requirements.txt")
    sys.exit(1)

# ── Constants ──────────────────────────────────────────────────────────────────

RATE_LIMIT_DELAY = 0.35          # seconds between API calls (~3/sec Notion limit)
MAX_BLOCKS_PER_REQUEST = 100     # Notion API limit
MAX_RICH_TEXT_LENGTH = 1990      # Notion limit is 2000 chars; give a small buffer
DEFAULT_STATE_FILE = "migration_state.json"

NOTION_CODE_LANGS = {
    "abap", "arduino", "bash", "basic", "c", "clojure", "coffeescript", "cpp",
    "csharp", "css", "dart", "diff", "docker", "elixir", "elm", "erlang",
    "flow", "fortran", "fsharp", "gherkin", "glsl", "go", "graphql", "groovy",
    "haskell", "html", "java", "javascript", "json", "julia", "kotlin", "latex",
    "less", "lisp", "livescript", "lua", "makefile", "markdown", "markup",
    "matlab", "mermaid", "nix", "objective-c", "ocaml", "pascal", "perl",
    "php", "plain text", "powershell", "prolog", "protobuf", "python", "r",
    "reason", "ruby", "rust", "sass", "scala", "scheme", "scss", "shell",
    "sql", "swift", "toml", "typescript", "vb.net", "verilog", "vhdl",
    "visual basic", "webassembly", "xml", "yaml",
}

CALLOUT_ICONS: dict[str, tuple[str, str]] = {
    "note":      ("💡", "blue_background"),
    "tip":       ("🌿", "green_background"),
    "hint":      ("🌿", "green_background"),
    "important": ("🔥", "orange_background"),
    "warning":   ("⚠️", "yellow_background"),
    "caution":   ("⚠️", "yellow_background"),
    "attention": ("⚠️", "yellow_background"),
    "danger":    ("🚨", "red_background"),
    "error":     ("🚨", "red_background"),
    "bug":       ("🐛", "red_background"),
    "example":   ("📋", "purple_background"),
    "question":  ("❓", "pink_background"),
    "quote":     ("💬", "gray_background"),
    "abstract":  ("📄", "blue_background"),
    "summary":   ("📄", "blue_background"),
}


# ── Rich-text helpers ──────────────────────────────────────────────────────────

def _annotations(**kwargs) -> dict:
    base = {"bold": False, "italic": False, "strikethrough": False,
            "underline": False, "code": False, "color": "default"}
    base.update(kwargs)
    return base


def rt(content: str, **annots) -> dict:
    return {
        "type": "text",
        "text": {"content": content[:MAX_RICH_TEXT_LENGTH], "link": None},
        "annotations": _annotations(**annots),
    }


def rt_link(content: str, url: str) -> dict:
    return {
        "type": "text",
        "text": {"content": content[:MAX_RICH_TEXT_LENGTH], "link": {"url": url}},
        "annotations": _annotations(),
    }


def rt_mention(page_id: str, display: str) -> dict:
    return {
        "type": "mention",
        "mention": {"type": "page", "page": {"id": page_id}},
        "plain_text": display,
        "href": f"https://www.notion.so/{page_id.replace('-', '')}",
    }


# ── Inline markdown parser ─────────────────────────────────────────────────────

_INLINE_RE = re.compile(
    r"(\*\*\*(?P<bolditalic>.+?)\*\*\*)"         # ***bold italic***
    r"|(\*\*(?P<bold>.+?)\*\*)"                   # **bold**
    r"|(==(?P<highlight>.+?)==)"                  # ==highlight==
    r"|(~~(?P<strike>.+?)~~)"                     # ~~strikethrough~~
    r"|((?<!\*)\*(?!\*)(?P<italic>[^*]+?)(?<!\*)\*(?!\*))"  # *italic*
    r"|(_(?P<italic2>[^_\n]+?)_)"                 # _italic_
    r"|(`(?P<code>[^`\n]+?)`)"                    # `code`
    r"|(\[\[(?P<wikilink>[^\]\n]+?)\]\])"         # [[wiki-link]]
    r"|(\[(?P<linktext>[^\]\n]*)\]\((?P<linkurl>[^)\n]+)\))"  # [text](url)
    r"|(?P<plain>[^*_~`\[\n]+|\[|\n)",            # plain text or newline
    re.DOTALL,
)


def parse_inline(text: str, wiki_map: dict[str, str] | None = None) -> list[dict]:
    """Convert Obsidian inline markdown to a Notion rich_text array."""
    results: list[dict] = []

    for m in _INLINE_RE.finditer(text):
        if m.group("bolditalic"):
            results.append(rt(m.group("bolditalic"), bold=True, italic=True))
        elif m.group("bold"):
            results.append(rt(m.group("bold"), bold=True))
        elif m.group("highlight"):
            results.append(rt(m.group("highlight"), color="yellow"))
        elif m.group("strike"):
            results.append(rt(m.group("strike"), strikethrough=True))
        elif m.group("italic") or m.group("italic2"):
            results.append(rt((m.group("italic") or m.group("italic2")), italic=True))
        elif m.group("code"):
            results.append(rt(m.group("code"), code=True))
        elif m.group("wikilink"):
            raw = m.group("wikilink")
            if "|" in raw:
                target, display = raw.split("|", 1)
            else:
                target, display = raw, raw
            target_base = target.strip().split("#")[0]  # drop heading anchors
            display = display.strip()
            if wiki_map and target_base.lower() in wiki_map:
                results.append(rt_mention(wiki_map[target_base.lower()], display))
            else:
                results.append(rt(f"[[{display}]]"))
        elif m.group("linktext") is not None:
            text_part = m.group("linktext") or m.group("linkurl")
            results.append(rt_link(text_part, m.group("linkurl")))
        elif m.group("plain"):
            content = m.group("plain")
            if content:
                # Merge consecutive plain segments if possible
                if results and results[-1]["type"] == "text" and not results[-1]["text"]["link"] \
                        and results[-1]["annotations"] == _annotations():
                    existing = results[-1]["text"]["content"]
                    combined = existing + content
                    results[-1]["text"]["content"] = combined[:MAX_RICH_TEXT_LENGTH]
                else:
                    results.append(rt(content))

    return results if results else [rt("")]


# ── Block-level markdown parser ────────────────────────────────────────────────

def _block_start(line: str) -> bool:
    return bool(
        re.match(r"^#{1,6}\s", line)
        or re.match(r"^```", line)
        or re.match(r"^>\s*\[!", line)
        or line.startswith("> ") or line == ">"
        or re.match(r"^[-*_]{3,}\s*$", line)
        or re.match(r"^\s*[-*+]\s+\[[ xX]\]", line)
        or re.match(r"^\s*[-*+]\s", line)
        or re.match(r"^\s*\d+[.)]\s", line)
        or line.startswith("![[")
        or line.startswith("![")
    )


def _find_attachment(filename: str, vault_root: Path) -> Path | None:
    filename = filename.split("|")[0].strip()  # strip size hints like image.png|300
    for candidate in sorted(vault_root.rglob(filename)):
        return candidate
    return None


def _attachment_block(
    filename: str,
    vault_root: Path,
    uploader,
) -> dict:
    """Return an image/file block, or a plain-text note if the file can't be uploaded."""
    file_path = _find_attachment(filename, vault_root)
    if file_path and uploader:
        result = uploader(file_path)
        if result:
            url, notion_file_id = result
            mime, _ = mimetypes.guess_type(str(file_path))
            is_image = mime and mime.startswith("image/")
            block_type = "image" if is_image else "file"
            if notion_file_id:
                # Notion-hosted file upload
                return {
                    "object": "block",
                    "type": block_type,
                    block_type: {
                        "type": "file_upload",
                        "file_upload": {"id": notion_file_id},
                    },
                }
            else:
                # External URL fallback
                return {
                    "object": "block",
                    "type": block_type,
                    block_type: {"type": "external", "external": {"url": url}},
                }

    # Fallback: note the attachment inline
    note = f"[Attachment: {filename}]" + ("" if file_path else " (file not found)")
    return {
        "object": "block",
        "type": "paragraph",
        "paragraph": {"rich_text": [rt(note, italic=True)]},
    }


def parse_markdown_to_blocks(
    content: str,
    vault_root: Path,
    wiki_map: dict[str, str] | None = None,
    uploader=None,
) -> list[dict]:
    """
    Convert Obsidian markdown to a flat list of Notion block dicts.
    uploader: callable(Path) -> (url, file_id) | None
    """
    blocks: list[dict] = []
    lines = content.splitlines()
    i = 0

    def inline(text: str) -> list[dict]:
        return parse_inline(text, wiki_map)

    while i < len(lines):
        line = lines[i]

        # ── Heading
        m = re.match(r"^(#{1,6})\s+(.*)", line)
        if m:
            level = min(len(m.group(1)), 3)
            htype = f"heading_{level}"
            blocks.append({"object": "block", "type": htype,
                           htype: {"rich_text": inline(m.group(2).rstrip())}})
            i += 1
            continue

        # ── Horizontal rule
        if re.match(r"^[-*_]{3,}\s*$", line):
            blocks.append({"object": "block", "type": "divider", "divider": {}})
            i += 1
            continue

        # ── Fenced code block
        m = re.match(r"^```(\w*)", line)
        if m:
            lang = m.group(1).lower() or "plain text"
            if lang not in NOTION_CODE_LANGS:
                lang = "plain text"
            code_lines: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                code_lines.append(lines[i])
                i += 1
            i += 1  # closing ```
            blocks.append({
                "object": "block", "type": "code",
                "code": {
                    "rich_text": [rt("\n".join(code_lines))],
                    "language": lang,
                    "caption": [],
                },
            })
            continue

        # ── Obsidian callout: > [!type] optional-title
        m = re.match(r"^>\s*\[!(\w+)\]\s*(.*)", line)
        if m:
            ctype = m.group(1).lower()
            title = m.group(2).strip()
            emoji, color = CALLOUT_ICONS.get(ctype, ("📌", "gray_background"))
            body: list[str] = []
            i += 1
            while i < len(lines) and (lines[i].startswith("> ") or lines[i] == ">"):
                body.append(lines[i][2:] if lines[i].startswith("> ") else "")
                i += 1
            full_text = title
            if body:
                full_text = (title + "\n" + "\n".join(body)).strip()
            blocks.append({
                "object": "block", "type": "callout",
                "callout": {
                    "rich_text": inline(full_text),
                    "icon": {"type": "emoji", "emoji": emoji},
                    "color": color,
                },
            })
            continue

        # ── Blockquote (plain)
        if line.startswith("> ") or line == ">":
            quote_lines: list[str] = []
            while i < len(lines) and (lines[i].startswith("> ") or lines[i] == ">"):
                quote_lines.append(lines[i][2:] if lines[i].startswith("> ") else "")
                i += 1
            blocks.append({
                "object": "block", "type": "quote",
                "quote": {"rich_text": inline(" ".join(quote_lines))},
            })
            continue

        # ── Todo checkbox
        m = re.match(r"^\s*[-*+]\s+\[([ xX])\]\s+(.*)", line)
        if m:
            checked = m.group(1).lower() == "x"
            blocks.append({
                "object": "block", "type": "to_do",
                "to_do": {"rich_text": inline(m.group(2)), "checked": checked},
            })
            i += 1
            continue

        # ── Unordered list
        m = re.match(r"^\s*[-*+]\s+(.*)", line)
        if m:
            blocks.append({
                "object": "block", "type": "bulleted_list_item",
                "bulleted_list_item": {"rich_text": inline(m.group(1))},
            })
            i += 1
            continue

        # ── Ordered list
        m = re.match(r"^\s*\d+[.)]\s+(.*)", line)
        if m:
            blocks.append({
                "object": "block", "type": "numbered_list_item",
                "numbered_list_item": {"rich_text": inline(m.group(1))},
            })
            i += 1
            continue

        # ── Embedded attachment: ![[filename]] (standalone line)
        m = re.match(r"^!\[\[(.+?)\]\]\s*$", line)
        if m:
            blocks.append(_attachment_block(m.group(1), vault_root, uploader))
            i += 1
            continue

        # ── Standard image: ![alt](path or url)
        m = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)\s*$", line)
        if m:
            url = m.group(2)
            if url.startswith("http://") or url.startswith("https://"):
                blocks.append({
                    "object": "block", "type": "image",
                    "image": {"type": "external", "external": {"url": url}},
                })
            else:
                blocks.append(_attachment_block(url, vault_root, uploader))
            i += 1
            continue

        # ── Empty line
        if line.strip() == "":
            i += 1
            continue

        # ── Paragraph (consume continuation lines)
        para_lines = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not _block_start(lines[i]):
            para_lines.append(lines[i])
            i += 1
        para_text = " ".join(para_lines)

        # Inline embed check after joining
        m = re.match(r"^!\[\[(.+?)\]\]\s*$", para_text.strip())
        if m:
            blocks.append(_attachment_block(m.group(1), vault_root, uploader))
            continue

        blocks.append({
            "object": "block", "type": "paragraph",
            "paragraph": {"rich_text": inline(para_text)},
        })

    return blocks


# ── Migrator ───────────────────────────────────────────────────────────────────

class ObsidianToNotionMigrator:
    def __init__(
        self,
        vault: Path,
        token: str,
        root_page_id: str,
        dry_run: bool = False,
        state_file: Path = Path(DEFAULT_STATE_FILE),
        skip_attachments: bool = False,
    ):
        self.vault = vault.resolve()
        self.root_page_id = root_page_id.replace("-", "")
        self.dry_run = dry_run
        self.state_file = state_file
        self.skip_attachments = skip_attachments
        self._token = token

        self.notion: Client | None = None if dry_run else Client(auth=token)
        self._last_call = 0.0

        self.state = self._load_state()
        # { "pages": {rel_path: {id, phase}}, "folders": {rel_path: id} }

        self.wiki_map: dict[str, str] = {}  # lowercase stem → page ID
        self._errors: list[tuple[str, str]] = []

    # ── State persistence ──────────────────────────────────────────────────────

    def _load_state(self) -> dict:
        if self.state_file.exists():
            with open(self.state_file) as f:
                return json.load(f)
        return {"pages": {}, "folders": {}}

    def _save(self):
        with open(self.state_file, "w") as f:
            json.dump(self.state, f, indent=2)

    # ── API helpers ────────────────────────────────────────────────────────────

    def _throttle(self):
        elapsed = time.time() - self._last_call
        if elapsed < RATE_LIMIT_DELAY:
            time.sleep(RATE_LIMIT_DELAY - elapsed)
        self._last_call = time.time()

    def _call(self, fn, *args, **kwargs):
        if self.dry_run:
            return {"id": "dry-run-id-000000000000000000000000000000"}
        self._throttle()
        for attempt in range(4):
            try:
                return fn(*args, **kwargs)
            except Exception as exc:
                msg = str(exc).lower()
                if "rate_limited" in msg or "429" in msg:
                    wait = 2 ** attempt
                    print(f"\n  Rate limited — waiting {wait}s...")
                    time.sleep(wait)
                elif attempt >= 3:
                    raise
                else:
                    time.sleep(1)

    def _create_page(self, parent_id: str, title: str, icon_emoji: str = "📄") -> str:
        result = self._call(
            self.notion.pages.create,
            parent={"type": "page_id", "page_id": parent_id},
            icon={"type": "emoji", "emoji": icon_emoji},
            properties={"title": {"title": [{"type": "text",
                                              "text": {"content": title[:2000]}}]}},
        )
        return result["id"]

    def _append_blocks(self, page_id: str, blocks: list[dict]):
        for i in range(0, len(blocks), MAX_BLOCKS_PER_REQUEST):
            chunk = blocks[i : i + MAX_BLOCKS_PER_REQUEST]
            self._call(
                self.notion.blocks.children.append,
                block_id=page_id,
                children=chunk,
            )

    # ── File upload ────────────────────────────────────────────────────────────

    def _upload_file(self, path: Path) -> tuple[str, str] | None:
        """
        Upload a local file to Notion.
        Returns (url, file_upload_id) on success, None on failure.
        Notion file upload API: https://developers.notion.com/reference/create-a-file-upload
        """
        if self.dry_run:
            return (f"https://example.com/dry-run/{path.name}", "dry-run-upload-id")
        if self.skip_attachments or not path.exists():
            return None

        size = path.stat().st_size
        if size > 20 * 1024 * 1024:
            print(f"\n  Skipping {path.name} — too large ({size // 1024 // 1024} MB)")
            return None

        mime, _ = mimetypes.guess_type(str(path))
        mime = mime or "application/octet-stream"
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Notion-Version": "2022-06-28",
        }

        try:
            self._throttle()
            # Step 1: request upload slot
            r = requests.post(
                "https://api.notion.com/v1/file_uploads",
                headers={**headers, "Content-Type": "application/json"},
                json={"filename": path.name, "content_type": mime},
                timeout=30,
            )
            if r.status_code != 200:
                return None
            data = r.json()
            upload_id = data.get("id")
            upload_url = data.get("upload_url")
            if not upload_id or not upload_url:
                return None

            # Step 2: send the file
            self._throttle()
            with open(path, "rb") as fh:
                put_r = requests.put(
                    upload_url,
                    headers={"Content-Type": mime},
                    data=fh,
                    timeout=120,
                )
            if put_r.status_code not in (200, 201, 204):
                return None

            # Return the file's hosted URL from the upload response
            hosted_url = data.get("url", "")
            return (hosted_url, upload_id)

        except Exception as exc:
            print(f"\n  Upload failed for {path.name}: {exc}")
            return None

    # ── Phase 1: scaffold ──────────────────────────────────────────────────────

    def _ensure_folder_page(self, folder: Path) -> str:
        """Recursively ensure every ancestor folder has a Notion page. Returns page ID."""
        rel = str(folder.relative_to(self.vault))
        if rel in self.state["folders"]:
            return self.state["folders"][rel]

        parts = list(Path(rel).parts)
        parent_id = self.root_page_id
        current = Path()

        for part in parts:
            current = current / part
            key = str(current)
            if key not in self.state["folders"]:
                pid = (
                    self._create_page(parent_id, part, "📁")
                    if not self.dry_run
                    else f"dry-run-folder-{key}"
                )
                self.state["folders"][key] = pid
                self._save()
            parent_id = self.state["folders"][key]

        return self.state["folders"][rel]

    def scaffold(self, md_files: list[Path]) -> None:
        print("\n=== Phase 1: Creating page structure ===")
        for md_file in tqdm(md_files, desc="Scaffolding"):
            rel = str(md_file.relative_to(self.vault))

            if rel in self.state["pages"]:
                page_id = self.state["pages"][rel]["id"]
                self.wiki_map[md_file.stem.lower()] = page_id
                continue

            if md_file.parent == self.vault:
                parent_id = self.root_page_id
            else:
                parent_id = self._ensure_folder_page(md_file.parent)

            # Extract title from frontmatter or use filename
            try:
                post = frontmatter.load(str(md_file))
                title = str(post.get("title") or md_file.stem)
            except Exception:
                title = md_file.stem

            page_id = self._create_page(parent_id, title)
            self.state["pages"][rel] = {"id": page_id, "phase": "created"}
            self.wiki_map[md_file.stem.lower()] = page_id
            self._save()

        print(f"  {len(self.state['pages'])} pages scaffolded.")

    # ── Phase 2: populate ──────────────────────────────────────────────────────

    def populate(self, md_files: list[Path]) -> None:
        print("\n=== Phase 2: Populating content ===")
        for md_file in tqdm(md_files, desc="Populating"):
            rel = str(md_file.relative_to(self.vault))
            info = self.state["pages"].get(rel)
            if not info or info.get("phase") == "populated":
                continue

            page_id = info["id"]
            try:
                post = frontmatter.load(str(md_file))
                blocks: list[dict] = []

                # Frontmatter summary block
                fm = post.metadata
                if fm:
                    lines: list[str] = []
                    tags = fm.get("tags") or fm.get("tag") or []
                    if isinstance(tags, str):
                        tags = [tags]
                    if tags:
                        lines.append("Tags: " + " ".join(f"#{t}" for t in tags))
                    for k, v in fm.items():
                        if k.lower() not in ("title", "tags", "tag", "aliases", "alias"):
                            lines.append(f"{k}: {v}")
                    if lines:
                        blocks.append({
                            "object": "block", "type": "callout",
                            "callout": {
                                "rich_text": [rt("\n".join(lines))],
                                "icon": {"type": "emoji", "emoji": "🏷️"},
                                "color": "gray_background",
                            },
                        })

                content_blocks = parse_markdown_to_blocks(
                    post.content,
                    vault_root=self.vault,
                    wiki_map=self.wiki_map,
                    uploader=self._upload_file,
                )
                blocks.extend(content_blocks)

                if blocks:
                    self._append_blocks(page_id, blocks)

                info["phase"] = "populated"
                self._save()

            except Exception as exc:
                self._errors.append((rel, str(exc)))
                print(f"\n  Error: {rel}: {exc}")

        if self._errors:
            print(f"\n{len(self._errors)} error(s):")
            for path, err in self._errors:
                print(f"  {path}: {err}")
        else:
            print("  All pages populated with no errors.")

    # ── Entry point ────────────────────────────────────────────────────────────

    def run(self) -> int:
        md_files = sorted(
            p for p in self.vault.rglob("*.md")
            if not any(part.startswith(".") for part in p.parts)
        )
        print(f"Vault: {self.vault}")
        print(f"Found {len(md_files)} markdown files.")
        if self.dry_run:
            print("DRY RUN — no Notion API calls will be made.\n")

        # Pre-populate wiki_map from any already-completed state (for resume)
        for rel, info in self.state["pages"].items():
            stem = Path(rel).stem.lower()
            self.wiki_map[stem] = info["id"]

        self.scaffold(md_files)
        self.populate(md_files)

        print(f"\nDone. State saved to: {self.state_file}")
        if self._errors:
            print(f"Completed with {len(self._errors)} error(s) — check output above.")
            return 1
        return 0


# ── CLI ────────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Migrate an Obsidian vault to Notion.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--vault", required=True,
                    help="Path to your Obsidian vault directory")
    ap.add_argument("--token", required=True,
                    help="Notion integration token (starts with secret_)")
    ap.add_argument("--root-page", dest="root_page", required=True,
                    help="Notion page ID to migrate content into")
    ap.add_argument("--dry-run", action="store_true",
                    help="Preview without making any Notion API calls")
    ap.add_argument("--reset", action="store_true",
                    help="Delete saved state and start migration from scratch")
    ap.add_argument("--skip-attachments", action="store_true",
                    help="Skip file upload; note attachment names as text instead")
    ap.add_argument("--state-file", default=DEFAULT_STATE_FILE,
                    help=f"Path to the state file (default: {DEFAULT_STATE_FILE})")
    args = ap.parse_args()

    vault_path = Path(args.vault).expanduser().resolve()
    if not vault_path.is_dir():
        print(f"Error: vault directory not found: {vault_path}", file=sys.stderr)
        sys.exit(1)

    state_file = Path(args.state_file)
    if args.reset and state_file.exists():
        state_file.unlink()
        print(f"State reset — deleted {state_file}")

    migrator = ObsidianToNotionMigrator(
        vault=vault_path,
        token=args.token,
        root_page_id=args.root_page,
        dry_run=args.dry_run,
        state_file=state_file,
        skip_attachments=args.skip_attachments,
    )
    sys.exit(migrator.run())


if __name__ == "__main__":
    main()
