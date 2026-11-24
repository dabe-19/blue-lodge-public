#!/usr/bin/env python3
"""
Discord Outbound Markdown Formatter & Fence-Aware Chunker.
Pure Python stdlib (zero external dependencies).

Modes:
  --tables          Convert GitHub-Flavored Markdown pipe tables (outside fenced code blocks)
                    into crisp, mobile- and desktop-readable Discord layouts:
                    - 2-col key/value tables -> bold bullet list (`- **Key:** Value`)
                    - Compact 3+ col plain-text tables (width <= 56) -> aligned monospace code block
                    - Rich/wide 3+ col tables -> structured bullet cards (single-line or nested)
  --split [LIMIT]   Split long text into <= LIMIT char chunks (default 1990) at paragraph/line
                    boundaries while preserving fenced code blocks (```lang ... ```) across splits.
                    Outputs JSON array of strings.
  --split-caption [LIMIT]
                    Split a file-upload caption into [first_chunk, remainder] JSON array so the
                    file message stays <= LIMIT chars (default 1950) and the full remainder is
                    sent immediately afterward with zero truncation.
"""

import json
import re
import sys

_SEP_RE = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|?\s*$")
_FENCE_RE = re.compile(r"^\s*(```+|~~~+)(.*)$")
_MD_RICH_RE = re.compile(r"(\*\*|__|\[[^\]]+\]\([^)]+\)|`[^`]+`|<[@#][!&]?[0-9]+>)")


def _split_row(line: str):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    # Respect escaped pipes \|
    cells = re.split(r"(?<!\\)\|", s)
    return [c.replace("\\|", "|").strip() for c in cells]


def _strip_outer_bold(text: str) -> str:
    t = text.strip()
    if len(t) >= 4 and t.startswith("**") and t.endswith("**") and "**" not in t[2:-2]:
        return t[2:-2].strip()
    return t


def _render_table(headers, rows) -> list:
    ncols = len(headers)
    if ncols == 0 or not rows:
        return []

    norm_rows = []
    for r in rows:
        if len(r) < ncols:
            r = r + [""] * (ncols - len(r))
        elif len(r) > ncols:
            r = r[: ncols - 1] + [" | ".join(r[ncols - 1 :])]
        norm_rows.append(r)

    clean_headers = [_strip_outer_bold(h) for h in headers]

    # Case 1: 2-column table -> crisp key-value bullet list
    if ncols == 2:
        out = []
        for r in norm_rows:
            k = _strip_outer_bold(r[0])
            v = r[1].strip()
            if k and v:
                out.append(f"- **{k}:** {v}")
            elif k:
                out.append(f"- **{k}**")
            elif v:
                out.append(f"- {v}")
        return out

    # Case 2: 3+ columns — check if compact plain-text matrix fits in <= 56 chars monospace
    has_rich = any(_MD_RICH_RE.search(cell) for row in [clean_headers] + norm_rows for cell in row)
    col_widths = [
        max(len(clean_headers[i]), *(len(r[i]) for r in norm_rows))
        for i in range(ncols)
    ]
    total_width = sum(col_widths) + 2 * (ncols - 1)

    if not has_rich and total_width <= 56 and len(norm_rows) <= 25:
        fmt_hdr = "  ".join(clean_headers[i].ljust(col_widths[i]) for i in range(ncols)).rstrip()
        sep_line = "  ".join("-" * col_widths[i] for i in range(ncols)).rstrip()
        body = [
            "  ".join(r[i].ljust(col_widths[i]) for i in range(ncols)).rstrip()
            for r in norm_rows
        ]
        return ["```text", fmt_hdr, sep_line, *body, "```"]

    # Case 3: Rich or wide 3+ column table -> structured Discord bullet cards
    out = []
    for r in norm_rows:
        title = _strip_outer_bold(r[0]) or "(row)"
        pairs = []
        for i in range(1, ncols):
            val = r[i].strip()
            if not val or val in ("-", "—", "N/A"):
                continue
            hdr = clean_headers[i]
            pairs.append((hdr, val))
        if not pairs:
            out.append(f"- **{title}**")
            continue
        inline = f"- **{title}** — " + " · ".join(
            f"**{h}:** {v}" if h else v for h, v in pairs
        )
        if len(inline) <= 135 and len(pairs) <= 4:
            out.append(inline)
        else:
            out.append(f"- **{title}**")
            for h, v in pairs:
                if h:
                    out.append(f"  - **{h}:** {v}")
                else:
                    out.append(f"  - {v}")
    return out


def format_discord_tables(text: str) -> str:
    if "|" not in text or "-" not in text:
        return text

    lines = text.splitlines()
    out = []
    i = 0
    n = len(lines)
    in_fence = False
    fence_char = ""

    while i < n:
        line = lines[i]
        fm = _FENCE_RE.match(line)
        if fm:
            marker = fm.group(1)[0]
            if not in_fence:
                in_fence = True
                fence_char = marker
            elif marker == fence_char:
                in_fence = False
                fence_char = ""
            out.append(line)
            i += 1
            continue

        if (
            not in_fence
            and "|" in line
            and i + 1 < n
            and _SEP_RE.match(lines[i + 1])
        ):
            headers = _split_row(line)
            sep_cells = _split_row(lines[i + 1])
            if len(headers) >= 2 and abs(len(headers) - len(sep_cells)) <= 1:
                j = i + 2
                rows = []
                while j < n and "|" in lines[j] and lines[j].strip() != "" and not _FENCE_RE.match(lines[j]):
                    rows.append(_split_row(lines[j]))
                    j += 1
                if rows:
                    rendered = _render_table(headers, rows)
                    out.extend(rendered)
                    i = j
                    continue

        out.append(line)
        i += 1

    result = "\n".join(out)
    if text.endswith("\n"):
        result += "\n"
    return result


def split_discord_message(text: str, limit: int = 1990) -> list:
    """Split text into chunks <= limit while keeping fenced code blocks balanced."""
    if len(text) <= limit:
        return [text]

    lines = text.splitlines(keepends=True)
    chunks = []
    cur = ""
    in_fence = False
    fence_header = "```\n"

    def _flush():
        nonlocal cur
        if not cur:
            return
        if in_fence:
            suffix = "\n```" if not cur.endswith("\n") else "```"
            chunks.append(cur + suffix)
            cur = fence_header
        else:
            chunks.append(cur.rstrip("\n"))
            cur = ""

    for line in lines:
        reserve = 6 if in_fence else 0
        # Handle a single ultra-long line > limit
        if len(line) + reserve > limit:
            if cur and cur != fence_header:
                _flush()
            rem = line
            while len(rem) + (6 if in_fence else 0) > limit:
                take = limit - (6 if in_fence else 0) - len(cur)
                if take <= 40:
                    _flush()
                    take = limit - (6 if in_fence else 0) - len(cur)
                # Prefer breaking at a space
                cut = rem.rfind(" ", 0, take)
                if cut < take // 2:
                    cut = take
                cur += rem[:cut]
                rem = rem[cut:].lstrip(" ")
                _flush()
            line = rem

        if cur and len(cur) + len(line) + reserve > limit:
            _flush()

        cur += line
        fm = _FENCE_RE.match(line.rstrip("\r\n"))
        if fm:
            if not in_fence:
                in_fence = True
                fence_header = line if line.endswith("\n") else line + "\n"
            else:
                in_fence = False
                fence_header = "```\n"

    if cur and (not in_fence or cur != fence_header):
        chunks.append(cur.rstrip("\n"))

    return [c for c in chunks if c.strip()]


def split_caption(text: str, limit: int = 1950) -> list:
    if len(text) <= limit:
        return [text, ""]
    parts = split_discord_message(text, limit=limit)
    if len(parts) <= 1:
        return [text[:limit], text[limit:]]
    return [parts[0], "\n".join(parts[1:])]


def main():
    args = sys.argv[1:]
    data = sys.stdin.read()
    if "--split-caption" in args:
        idx = args.index("--split-caption")
        lim = int(args[idx + 1]) if idx + 1 < len(args) and args[idx + 1].isdigit() else 1950
        if "--tables" in args:
            data = format_discord_tables(data)
        print(json.dumps(split_caption(data, lim)))
    elif "--split" in args:
        idx = args.index("--split")
        lim = int(args[idx + 1]) if idx + 1 < len(args) and args[idx + 1].isdigit() else 1990
        if "--tables" in args:
            data = format_discord_tables(data)
        print(json.dumps(split_discord_message(data, lim)))
    else:
        sys.stdout.write(format_discord_tables(data))


if __name__ == "__main__":
    main()
