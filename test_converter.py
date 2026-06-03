"""
Unit tests for obsidian_to_notion.py — covers inline parser, block parser,
attachment handling, and frontmatter extraction. No Notion API calls made.
"""

import pytest
from pathlib import Path
from unittest.mock import MagicMock
from obsidian_to_notion import (
    parse_inline,
    parse_markdown_to_blocks,
    rt,
    rt_link,
    rt_mention,
    _find_attachment,
    CALLOUT_ICONS,
)


# ── Inline parser ──────────────────────────────────────────────────────────────

class TestParseInline:
    def test_plain_text(self):
        result = parse_inline("hello world")
        assert len(result) == 1
        assert result[0]["text"]["content"] == "hello world"
        assert result[0]["annotations"]["bold"] is False

    def test_bold(self):
        result = parse_inline("**bold text**")
        assert any(r["annotations"]["bold"] for r in result)
        bold_text = next(r for r in result if r["annotations"]["bold"])
        assert bold_text["text"]["content"] == "bold text"

    def test_italic_asterisk(self):
        result = parse_inline("*italic*")
        assert any(r["annotations"]["italic"] for r in result)

    def test_italic_underscore(self):
        result = parse_inline("_italic_")
        assert any(r["annotations"]["italic"] for r in result)

    def test_bold_italic(self):
        result = parse_inline("***both***")
        combined = next(r for r in result if r["annotations"]["bold"] and r["annotations"]["italic"])
        assert combined["text"]["content"] == "both"

    def test_strikethrough(self):
        result = parse_inline("~~deleted~~")
        assert any(r["annotations"]["strikethrough"] for r in result)

    def test_inline_code(self):
        result = parse_inline("`some code`")
        code_part = next(r for r in result if r["annotations"]["code"])
        assert code_part["text"]["content"] == "some code"

    def test_highlight(self):
        result = parse_inline("==highlighted==")
        hi = next(r for r in result if r["annotations"].get("color") == "yellow")
        assert hi["text"]["content"] == "highlighted"

    def test_standard_link(self):
        result = parse_inline("[Click here](https://example.com)")
        link = next(r for r in result if r["text"]["link"])
        assert link["text"]["link"]["url"] == "https://example.com"
        assert link["text"]["content"] == "Click here"

    def test_wiki_link_resolved(self):
        wiki_map = {"my note": "abc123"}
        result = parse_inline("[[My Note]]", wiki_map=wiki_map)
        mention = next(r for r in result if r["type"] == "mention")
        assert mention["mention"]["page"]["id"] == "abc123"

    def test_wiki_link_with_display(self):
        wiki_map = {"target": "page-id-x"}
        result = parse_inline("[[Target|Custom Label]]", wiki_map=wiki_map)
        mention = next(r for r in result if r["type"] == "mention")
        assert mention["plain_text"] == "Custom Label"

    def test_wiki_link_unresolved(self):
        result = parse_inline("[[NonExistent]]", wiki_map={})
        plain = next(r for r in result if r["type"] == "text")
        assert "[[NonExistent]]" in plain["text"]["content"]

    def test_wiki_link_heading_anchor_stripped(self):
        wiki_map = {"note": "note-id"}
        result = parse_inline("[[Note#Section]]", wiki_map=wiki_map)
        mention = next(r for r in result if r["type"] == "mention")
        assert mention["mention"]["page"]["id"] == "note-id"

    def test_mixed_inline(self):
        result = parse_inline("Hello **world** and *italics*")
        contents = [r["text"]["content"] for r in result if r["type"] == "text"]
        assert "world" in contents or any("world" in c for c in contents)

    def test_empty_string(self):
        result = parse_inline("")
        assert result == [rt("")]

    def test_no_wiki_map_none(self):
        result = parse_inline("[[Some Link]]", wiki_map=None)
        assert any("Some Link" in r["text"]["content"] for r in result if r["type"] == "text")


# ── Block-level parser ─────────────────────────────────────────────────────────

class TestParseMarkdownToBlocks:
    def blocks(self, text: str, wiki_map=None, uploader=None) -> list[dict]:
        return parse_markdown_to_blocks(
            text,
            vault_root=Path("/nonexistent"),
            wiki_map=wiki_map or {},
            uploader=uploader,
        )

    def test_heading_1(self):
        result = self.blocks("# Hello")
        assert result[0]["type"] == "heading_1"
        assert result[0]["heading_1"]["rich_text"][0]["text"]["content"] == "Hello"

    def test_heading_2(self):
        result = self.blocks("## Sub")
        assert result[0]["type"] == "heading_2"

    def test_heading_3(self):
        result = self.blocks("### Sub-sub")
        assert result[0]["type"] == "heading_3"

    def test_heading_capped_at_3(self):
        result = self.blocks("#### Level 4")
        assert result[0]["type"] == "heading_3"

    def test_paragraph(self):
        result = self.blocks("Just some text.")
        assert result[0]["type"] == "paragraph"
        assert "Just some text." in result[0]["paragraph"]["rich_text"][0]["text"]["content"]

    def test_horizontal_rule(self):
        result = self.blocks("---")
        assert result[0]["type"] == "divider"

    def test_horizontal_rule_asterisks(self):
        result = self.blocks("***")
        assert result[0]["type"] == "divider"

    def test_code_block(self):
        result = self.blocks("```python\nprint('hi')\n```")
        assert result[0]["type"] == "code"
        assert result[0]["code"]["language"] == "python"
        assert "print('hi')" in result[0]["code"]["rich_text"][0]["text"]["content"]

    def test_code_block_unknown_lang_defaults_to_plain(self):
        result = self.blocks("```brainfuck\n++++\n```")
        assert result[0]["code"]["language"] == "plain text"

    def test_blockquote(self):
        result = self.blocks("> Some quote")
        assert result[0]["type"] == "quote"

    def test_callout_note(self):
        result = self.blocks("> [!NOTE] This is a note")
        assert result[0]["type"] == "callout"
        assert result[0]["callout"]["icon"]["emoji"] == "💡"

    def test_callout_warning(self):
        result = self.blocks("> [!WARNING] Watch out")
        assert result[0]["callout"]["color"] == "yellow_background"

    def test_callout_multiline(self):
        text = "> [!TIP] Title\n> Line 1\n> Line 2"
        result = self.blocks(text)
        assert result[0]["type"] == "callout"
        content = result[0]["callout"]["rich_text"][0]["text"]["content"]
        assert "Line 1" in content
        assert "Line 2" in content

    def test_checkbox_unchecked(self):
        result = self.blocks("- [ ] Todo item")
        assert result[0]["type"] == "to_do"
        assert result[0]["to_do"]["checked"] is False

    def test_checkbox_checked(self):
        result = self.blocks("- [x] Done")
        assert result[0]["to_do"]["checked"] is True

    def test_checkbox_checked_uppercase(self):
        result = self.blocks("- [X] Done")
        assert result[0]["to_do"]["checked"] is True

    def test_unordered_list_dash(self):
        result = self.blocks("- item one\n- item two")
        assert all(b["type"] == "bulleted_list_item" for b in result)
        assert len(result) == 2

    def test_unordered_list_asterisk(self):
        result = self.blocks("* item")
        assert result[0]["type"] == "bulleted_list_item"

    def test_ordered_list(self):
        result = self.blocks("1. First\n2. Second")
        assert all(b["type"] == "numbered_list_item" for b in result)

    def test_ordered_list_dot_or_paren(self):
        result_dot = self.blocks("1. item")
        result_paren = self.blocks("1) item")
        assert result_dot[0]["type"] == "numbered_list_item"
        assert result_paren[0]["type"] == "numbered_list_item"

    def test_embedded_image_notfound(self):
        result = self.blocks("![[missing.png]]")
        # File not found → fallback paragraph with note
        assert result[0]["type"] == "paragraph"
        content = result[0]["paragraph"]["rich_text"][0]["text"]["content"]
        assert "missing.png" in content

    def test_external_image_url(self):
        result = self.blocks("![alt](https://example.com/img.png)")
        assert result[0]["type"] == "image"
        assert result[0]["image"]["external"]["url"] == "https://example.com/img.png"

    def test_empty_content(self):
        result = self.blocks("")
        assert result == []

    def test_empty_lines_skipped(self):
        result = self.blocks("\n\n\n")
        assert result == []

    def test_multiple_blocks(self):
        text = "# Title\n\nSome paragraph.\n\n- item"
        result = self.blocks(text)
        types = [b["type"] for b in result]
        assert "heading_1" in types
        assert "paragraph" in types
        assert "bulleted_list_item" in types

    def test_wiki_link_in_paragraph(self):
        wiki_map = {"target": "page-id-123"}
        result = self.blocks("See [[Target]] for more.", wiki_map=wiki_map)
        para = result[0]
        assert para["type"] == "paragraph"
        mentions = [r for r in para["paragraph"]["rich_text"] if r["type"] == "mention"]
        assert len(mentions) == 1
        assert mentions[0]["mention"]["page"]["id"] == "page-id-123"


# ── Callout icon mapping ───────────────────────────────────────────────────────

class TestCalloutIcons:
    def test_known_types_have_entries(self):
        for key in ("note", "tip", "warning", "danger", "error", "bug", "example"):
            assert key in CALLOUT_ICONS

    def test_icon_is_tuple_of_two(self):
        for key, val in CALLOUT_ICONS.items():
            assert isinstance(val, tuple) and len(val) == 2, f"Bad entry for {key}"

    def test_colors_end_in_background(self):
        for key, (emoji, color) in CALLOUT_ICONS.items():
            assert color.endswith("_background"), f"Expected _background suffix for {key}"


# ── Attachment search ──────────────────────────────────────────────────────────

class TestFindAttachment:
    def test_not_found_returns_none(self, tmp_path):
        result = _find_attachment("ghost.png", tmp_path)
        assert result is None

    def test_finds_file_in_root(self, tmp_path):
        img = tmp_path / "photo.png"
        img.write_bytes(b"\x89PNG")
        result = _find_attachment("photo.png", tmp_path)
        assert result == img

    def test_finds_file_in_subdir(self, tmp_path):
        subdir = tmp_path / "assets"
        subdir.mkdir()
        img = subdir / "diagram.png"
        img.write_bytes(b"\x89PNG")
        result = _find_attachment("diagram.png", tmp_path)
        assert result == img

    def test_strips_size_hint(self, tmp_path):
        img = tmp_path / "photo.jpg"
        img.write_bytes(b"\xff\xd8")
        result = _find_attachment("photo.jpg|400", tmp_path)
        assert result == img


# ── Integration: full file parse ───────────────────────────────────────────────

class TestIntegration:
    def test_frontmatter_and_content(self, tmp_path):
        """Full end-to-end parse of a realistic note."""
        import frontmatter

        note = tmp_path / "test_note.md"
        note.write_text(
            "---\n"
            "title: Test Note\n"
            "tags: [python, testing]\n"
            "---\n"
            "# Introduction\n\n"
            "This is a **bold** statement with *italic* flair.\n\n"
            "- First item\n"
            "- Second item\n\n"
            "```python\nprint('hello')\n```\n"
        )

        post = frontmatter.load(str(note))
        assert post.get("title") == "Test Note"
        assert "python" in (post.get("tags") or [])

        blocks = parse_markdown_to_blocks(
            post.content,
            vault_root=tmp_path,
            wiki_map={},
            uploader=None,
        )
        types = [b["type"] for b in blocks]
        assert "heading_1" in types
        assert "paragraph" in types
        assert "bulleted_list_item" in types
        assert "code" in types

    def test_cross_link_resolution(self):
        wiki_map = {"home": "home-page-id", "about": "about-page-id"}
        text = "See [[Home]] and [[About]] for context."
        blocks = parse_markdown_to_blocks(
            text, vault_root=Path("/none"), wiki_map=wiki_map
        )
        rich_text = blocks[0]["paragraph"]["rich_text"]
        mentions = [r for r in rich_text if r["type"] == "mention"]
        page_ids = {m["mention"]["page"]["id"] for m in mentions}
        assert "home-page-id" in page_ids
        assert "about-page-id" in page_ids

    def test_attachment_uploader_called(self, tmp_path):
        img = tmp_path / "screenshot.png"
        img.write_bytes(b"\x89PNG\r\n")

        called_with = []

        def fake_uploader(path):
            called_with.append(path)
            return ("https://notion.so/file/screenshot.png", "upload-id-123")

        blocks = parse_markdown_to_blocks(
            "![[screenshot.png]]",
            vault_root=tmp_path,
            wiki_map={},
            uploader=fake_uploader,
        )
        assert len(called_with) == 1
        assert called_with[0] == img
        assert blocks[0]["type"] == "image"
