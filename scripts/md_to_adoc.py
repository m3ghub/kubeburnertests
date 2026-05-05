#!/usr/bin/env python3
"""
Convert Markdown test docs to AsciiDoc format.
Handles the specific patterns used in the kube-burner docs.
"""

import re
from pathlib import Path


def inline(line: str) -> str:
    """Apply inline markup conversions to a line."""
    # Bold+italic ***text*** → *_text_*
    line = re.sub(r'\*\*\*(.+?)\*\*\*', r'*_\1_*', line)
    # Bold **text** → *text*
    line = re.sub(r'\*\*(.+?)\*\*', r'*\1*', line)
    # Italic _text_ (underscores) — leave as-is, AsciiDoc uses same
    # Italic *text* — only when surrounded by non-word chars (avoid list bullets)
    line = re.sub(r'(?<![*\w])\*([^*\n]+?)\*(?![*\w])', r'_\1_', line)
    # Links [text](url) → link:url[text]
    line = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'link:\2[\1]', line)
    return line


def convert(md: str) -> str:
    lines = md.split("\n")
    out = []
    i = 0

    # Collect leading blockquote metadata block (title card at top of each doc)
    # These are lines like: > **Key:** Value
    # Convert them to an AsciiDoc sidebar block for clean rendering
    leading_meta = []
    j = 0
    # Skip blank lines at very start
    while j < len(lines) and lines[j].strip() == "":
        j += 1
    # Check if first non-blank non-heading content is blockquote metadata
    # (we handle them inline below, so just let the main loop deal with it)

    while i < len(lines):
        line = lines[i]

        # ── Fenced code blocks ────────────────────────────────────────────
        fence_match = re.match(r'^(`{3,})(\w*)\s*$', line)
        if fence_match:
            lang = fence_match.group(2)
            if lang:
                out.append(f"[source,{lang}]")
            out.append("----")
            i += 1
            while i < len(lines):
                inner = lines[i]
                if re.match(r'^`{3,}\s*$', inner):
                    out.append("----")
                    break
                out.append(inner)
                i += 1
            i += 1
            continue

        # ── Headings ─────────────────────────────────────────────────────
        h_match = re.match(r'^(#{1,6})\s+(.*)', line)
        if h_match:
            level = len(h_match.group(1))
            text = inline(h_match.group(2))
            out.append("=" * level + " " + text)
            i += 1
            continue

        # ── Horizontal rules ─────────────────────────────────────────────
        if re.match(r'^---+\s*$', line):
            out.append("'''")
            i += 1
            continue

        # ── Blockquotes ───────────────────────────────────────────────────
        # Detect a block of consecutive > lines (metadata card or admonition)
        if line.startswith(">"):
            # Collect all consecutive blockquote lines
            bq_lines = []
            while i < len(lines) and (lines[i].startswith(">") or lines[i].strip() == ""):
                if lines[i].startswith(">"):
                    bq_lines.append(lines[i])
                    i += 1
                else:
                    # stop at blank line that isn't inside the block
                    break

            if len(bq_lines) == 1:
                # Single blockquote — choose admonition type by emoji/keyword
                content = re.sub(r'^>\s*', '', bq_lines[0])
                content = inline(content)
                low = content.lower()
                if any(k in low for k in ["⚠", "warning", "caution"]):
                    out.append(f"WARNING: {re.sub(r'^\*\*.*?\*\*:?\s*', '', content)}")
                elif any(k in low for k in ["⚡", "tip", "pre-flight", "preflight"]):
                    out.append(f"TIP: {re.sub(r'^\*\*.*?\*\*:?\s*', '', content)}")
                elif any(k in low for k in ["note", "info", "ℹ"]):
                    out.append(f"NOTE: {re.sub(r'^\*\*.*?\*\*:?\s*', '', content)}")
                else:
                    out.append(f"NOTE: {content}")
            else:
                # Multi-line blockquote → AsciiDoc sidebar block
                out.append("[sidebar]")
                out.append("****")
                for bql in bq_lines:
                    content = re.sub(r'^>\s*', '', bql)
                    out.append(inline(content))
                out.append("****")
            continue

        # ── Markdown tables → AsciiDoc tables ────────────────────────────
        if line.startswith("|") and i + 1 < len(lines) and re.match(r'^\|[-| ]+\|', lines[i + 1]):
            table_lines = []
            while i < len(lines) and lines[i].startswith("|"):
                table_lines.append(lines[i])
                i += 1
            header = table_lines[0]
            body = table_lines[2:] if len(table_lines) > 2 else []
            cols = len([c for c in header.split("|") if c.strip()])
            out.append(f'[cols="{",".join(["1"] * cols)}", options="header"]')
            out.append("|===")
            cells = [inline(c.strip()) for c in header.split("|") if c.strip()]
            out.append("| " + " | ".join(cells))
            out.append("")
            for row in body:
                cells = [inline(c.strip()) for c in row.split("|") if c.strip()]
                out.append("| " + " | ".join(cells))
            out.append("|===")
            continue

        # ── Checkboxes ────────────────────────────────────────────────────
        line = re.sub(r'^- \[ \]', '* [ ]', line)
        line = re.sub(r'^- \[x\]', '* [x]', line)

        # ── Inline markup ─────────────────────────────────────────────────
        line = inline(line)

        out.append(line)
        i += 1

    return "\n".join(out)


def main():
    src_dir = Path("docs/tests/markdown")
    dst_dir = Path("docs/tests/asciidoc")
    dst_dir.mkdir(parents=True, exist_ok=True)

    files = sorted(src_dir.glob("*.md"))
    for md_path in files:
        adoc_path = dst_dir / md_path.with_suffix(".adoc").name
        md_text = md_path.read_text(encoding="utf-8")
        adoc_text = convert(md_text)
        adoc_path.write_text(adoc_text, encoding="utf-8")
        print(f"  {md_path.name} → {adoc_path.name}")

    print(f"\nDone. {len(files)} files converted to {dst_dir}/")


if __name__ == "__main__":
    main()
