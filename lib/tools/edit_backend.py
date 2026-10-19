#!/usr/bin/env python3
"""
George: Block Replace & Fuzzy Edit Backend Engine
Applies <<<<<<< / ======= / >>>>>>> search and replace blocks to files,
cleaning line numbers and guaranteeing unique match safety.
"""

import sys
import os
import re


def strip_line_numbers(text: str) -> str:
    lines = text.split("\n")
    cleaned_lines = []
    for line in lines:
        m = re.match(r"^\s*\d+:\s?(.*)", line)
        if m:
            cleaned_lines.append(m.group(1))
        else:
            cleaned_lines.append(line)
    return "\n".join(cleaned_lines)


def apply_edit(fullpath: str, content_str: str) -> int:
    if not os.path.exists(fullpath):
        print(f"Error: Target file not found: {fullpath}", file=sys.stderr)
        return 1

    # Parse blocks
    blocks = []
    current_search = []
    current_replace = []
    state = "outside"

    for line in content_str.split("\n"):
        line = line.rstrip("\r")
        if line.startswith("<<<<<<<"):
            state = "in_search"
            current_search = []
        elif line.startswith("======="):
            state = "in_replace"
            current_replace = []
        elif line.startswith(">>>>>>>"):
            if state == "in_replace":
                blocks.append(("\n".join(current_search), "\n".join(current_replace)))
            state = "outside"
        else:
            if state == "in_search":
                current_search.append(line)
            elif state == "in_replace":
                current_replace.append(line)
            elif state == "outside" and line.strip():
                state = "in_search"
                current_search = [line]

    if not blocks:
        print(
            "Error: Edit rejected — invalid block-replace format. Could not parse any search/replace blocks.",
            file=sys.stderr,
        )
        return 1

    try:
        with open(fullpath, "r", encoding="utf-8") as f:
            file_content = f.read()
    except Exception as e:
        print(f"Error reading file {fullpath}: {e}", file=sys.stderr)
        return 1

    # Clean and verify blocks
    cleaned_blocks = []
    for idx, (search, replace) in enumerate(blocks):
        if not search:
            print(f"Error: Empty search pattern in block {idx + 1}.", file=sys.stderr)
            return 1

        cleaned_search = search
        cleaned_replace = replace
        if search not in file_content:
            candidate_search = strip_line_numbers(search)
            if candidate_search in file_content:
                cleaned_search = candidate_search
                cleaned_replace = strip_line_numbers(replace)

        if cleaned_search not in file_content:
            print(
                f"Error: Search pattern not found in target file (block {idx + 1}).",
                file=sys.stderr,
            )
            return 1
        if file_content.count(cleaned_search) > 1:
            print(
                f"Error: Search pattern is not unique (found multiple matches) in block {idx + 1}.",
                file=sys.stderr,
            )
            return 1
        cleaned_blocks.append((cleaned_search, cleaned_replace))

    # Apply all replacements
    new_content = file_content
    for search, replace in cleaned_blocks:
        new_content = new_content.replace(search, replace)

    try:
        with open(fullpath, "w", encoding="utf-8") as f:
            f.write(new_content)
    except Exception as e:
        print(f"Error writing file {fullpath}: {e}", file=sys.stderr)
        return 1

    print(f"Applied {len(cleaned_blocks)} block edits.")
    return 0


def main():
    if len(sys.argv) < 2:
        print("Usage: edit_backend.py <fullpath> [content_str]", file=sys.stderr)
        sys.exit(1)

    fullpath = sys.argv[1]
    if len(sys.argv) >= 3:
        content_str = sys.argv[2]
    else:
        content_str = os.environ.get("CONTENT", "")

    rc = apply_edit(fullpath, content_str)
    sys.exit(rc)


if __name__ == "__main__":
    main()
