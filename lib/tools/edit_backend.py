#!/usr/bin/env python3
"""
George: Surgical Edit & Multi-Tier Fuzzy Block Replace Engine
Supports:
  1. Structured JSON edits:
     - Single hunk: {"target": "...", "replacement": "...", "replace_all": false}
     - Multi-hunk batch: {"edits": [{"target": "...", "replacement": "..."}, ...]}
  2. Legacy block format:
     <<<<<<< SEARCH
     exact existing lines
     =======
     replacement lines
     >>>>>>> REPLACE
Features a 4-tier matching cascade:
  - Tier 1: Exact substring match
  - Tier 2: Line-number prefix stripping ("123: ")
  - Tier 3: Trailing-whitespace & relative-indentation normalization
  - Tier 4: Unicode typography normalization (smart quotes, em/en-dashes, nbsp)
On mismatch or ambiguity, returns actionable diagnostics (closest-match snippet
with line numbers, or exact duplicate line numbers) and performs atomic writes
via temporary file + os.replace().
"""

import difflib
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from typing import List, Optional, Tuple


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


def has_all_line_numbers(text: str) -> bool:
    non_empty = [l for l in text.split("\n") if l.strip()]
    if not non_empty:
        return False
    return all(re.match(r"^\s*\d+:\s?", l) for l in non_empty)


def build_typography_regex(text: str) -> re.Pattern:
    """Builds a regex matching text across ASCII vs Unicode smart quotes/dashes/spaces."""
    parts = []
    i = 0
    n = len(text)
    while i < n:
        if text[i : i + 2] == "--":
            parts.append(r"(?:--|\u2014|\u2013)")
            i += 2
            continue
        ch = text[i]
        if ch in ('"', "\u201c", "\u201d", "\u201e", "\u201f", "\u00ab", "\u00bb"):
            parts.append(r'["\u201c\u201d\u201e\u201f\u00ab\u00bb]')
        elif ch in ("'", "\u2018", "\u2019", "\u201a", "\u201b", "\u2032"):
            parts.append(r"['\u2018\u2019\u201a\u201b\u2032]")
        elif ch in ("-", "\u2013", "\u2014", "\u2212"):
            parts.append(r"(?:-|\u2013|\u2014|\u2212|--)")
        elif ch in (" ", "\u00a0", "\u2009", "\u202f"):
            parts.append(r"[ \u00a0\u2009\u202f]")
        elif ch == "\n":
            parts.append(r"[ \t]*\r?\n")
        else:
            parts.append(re.escape(ch))
        i += 1
    return re.compile("".join(parts))


def line_numbers_for_substring(file_content: str, sub: str) -> List[int]:
    lines = []
    start = 0
    while True:
        idx = file_content.find(sub, start)
        if idx == -1:
            break
        line_no = file_content.count("\n", 0, idx) + 1
        lines.append(line_no)
        start = idx + max(1, len(sub))
    return lines


def find_closest_match_diagnostic(file_content: str, search: str) -> str:
    """Finds the highest-similarity window in file_content and formats a numbered preview."""
    file_lines = file_content.split("\n")
    if not file_lines or (len(file_lines) == 1 and not file_lines[0]):
        return "Target file is empty."

    clean_s = strip_line_numbers(search).strip("\r\n")
    s_lines = [l.rstrip("\r") for l in clean_s.split("\n")]
    while s_lines and not s_lines[0].strip():
        s_lines.pop(0)
    while s_lines and not s_lines[-1].strip():
        s_lines.pop()
    if not s_lines:
        return ""

    win_len = max(1, min(len(s_lines), len(file_lines)))
    s_norm = "\n".join(l.strip() for l in s_lines).lower()
    first_anchor = s_lines[0].strip().lower()
    last_anchor = s_lines[-1].strip().lower()

    # Pre-filter candidate window starts on large files for speed
    n_windows = len(file_lines) - win_len + 1
    if n_windows <= 120:
        cand_starts = list(range(n_windows))
    else:
        scored = []
        for i in range(n_windows):
            fl_first = file_lines[i].strip().lower()
            fl_last = file_lines[i + win_len - 1].strip().lower()
            r1 = difflib.SequenceMatcher(None, first_anchor, fl_first).quick_ratio() if first_anchor else 0.0
            r2 = difflib.SequenceMatcher(None, last_anchor, fl_last).quick_ratio() if last_anchor else 0.0
            scored.append((max(r1, (r1 + r2) * 0.5), i))
        scored.sort(reverse=True)
        cand_starts = [idx for _, idx in scored[:30]]

    best_ratio = 0.0
    best_start = 0
    for i in cand_starts:
        win_norm = "\n".join(l.strip() for l in file_lines[i : i + win_len]).lower()
        ratio = difflib.SequenceMatcher(None, s_norm, win_norm).ratio()
        if ratio > best_ratio:
            best_ratio = ratio
            best_start = i

    # Also check single-line substring similarity if multi-line window was weak
    if best_ratio < 0.35 and first_anchor:
        for i, fl in enumerate(file_lines):
            r = difflib.SequenceMatcher(None, first_anchor, fl.strip().lower()).ratio()
            if r > best_ratio:
                best_ratio = r
                best_start = i

    if best_ratio < 0.30:
        return ""

    ctx_start = max(0, best_start - 2)
    ctx_end = min(len(file_lines), best_start + win_len + 2)
    preview_lines = [f"  {ln + 1}: {file_lines[ln]}" for ln in range(ctx_start, ctx_end)]
    pct = int(round(best_ratio * 100))
    return (
        f"Closest match in file (lines {ctx_start + 1}-{ctx_end}, {pct}% similarity):\n"
        + "\n".join(preview_lines)
        + "\n[Tip: Copy the exact lines above (without the 'NN: ' line-number prefix) into `target`.]"
    )


def resolve_block_match(
    file_content: str, search: str, replace: str, replace_all: bool = False
) -> Tuple[str, str, str, List[int], str]:
    """
    4-tier match resolver.
    Returns (status, matched_search, resolved_replace, match_line_numbers, tier)
    where status is one of: 'ok', 'not_found', 'non_unique' and tier names the
    matching cascade level that resolved the block: 'exact', 'line_num_strip',
    'indent_norm', or 'typography_norm' ('' when the search was not applied).
    """
    # Normalize CRLF according to target file
    use_crlf = "\r\n" in file_content
    norm_search = search.replace("\r\n", "\n")
    norm_replace = replace.replace("\r\n", "\n")
    if use_crlf:
        file_lf = file_content.replace("\r\n", "\n")
    else:
        file_lf = file_content

    def _finalize(s_lf: str, r_lf: str) -> Tuple[str, str]:
        if use_crlf:
            return s_lf.replace("\n", "\r\n"), r_lf.replace("\n", "\r\n")
        return s_lf, r_lf

    def _is_mid_indent_multiline(text: str, pat: str) -> bool:
        if "\n" not in pat or not pat or pat[0] in (" ", "\t", "\n"):
            return False
        pos = text.find(pat)
        if pos <= 0:
            return False
        # Check if everything between the previous newline and pos is whitespace
        line_start = text.rfind("\n", 0, pos) + 1
        return pos > line_start and text[line_start:pos].strip(" \t") == ""

    # Tier 1: Exact match
    if norm_search in file_lf and not _is_mid_indent_multiline(file_lf, norm_search):
        cnt = file_lf.count(norm_search)
        if cnt == 1 or replace_all:
            s_out, r_out = _finalize(norm_search, norm_replace)
            return ("ok", s_out, r_out, [], "exact")
        return ("non_unique", norm_search, norm_replace, line_numbers_for_substring(file_lf, norm_search), "exact")

    # Tier 2: Strip '123: ' line-number prefixes
    cand_search = strip_line_numbers(norm_search)
    cand_replace = strip_line_numbers(norm_replace) if has_all_line_numbers(norm_replace) else norm_replace
    if cand_search != norm_search and cand_search and cand_search in file_lf and not _is_mid_indent_multiline(file_lf, cand_search):
        cnt = file_lf.count(cand_search)
        if cnt == 1 or replace_all:
            s_out, r_out = _finalize(cand_search, cand_replace)
            return ("ok", s_out, r_out, [], "line_num_strip")
        return ("non_unique", cand_search, cand_replace, line_numbers_for_substring(file_lf, cand_search), "line_num_strip")

    # Tier 3: Line-by-line trailing whitespace & relative indentation normalization
    file_lines = file_lf.split("\n")
    s_lines = cand_search.split("\n")
    n_s = len(s_lines)

    if n_s <= len(file_lines) and any(l.strip() for l in s_lines):
        # Tier 3a: Trailing whitespace insensitive, exact leading indentation
        s_rstripped = [l.rstrip(" \t") for l in s_lines]
        ws_matches = []
        for i in range(len(file_lines) - n_s + 1):
            if [file_lines[i + j].rstrip(" \t") for j in range(n_s)] == s_rstripped:
                ws_matches.append(i)
        if len(ws_matches) == 1:
            idx = ws_matches[0]
            exact_slice = "\n".join(file_lines[idx : idx + n_s])
            if file_lf.count(exact_slice) == 1 or replace_all:
                s_out, r_out = _finalize(exact_slice, cand_replace)
                return ("ok", s_out, r_out, [idx + 1], "indent_norm")
        elif len(ws_matches) > 1 and not replace_all:
            return ("non_unique", cand_search, cand_replace, [m + 1 for m in ws_matches], "indent_norm")

        # Tier 3b: Relative indentation shift normalization
        # Require either >= 2 lines or a single line with >= 10 non-whitespace chars
        if n_s >= 2 or len(s_lines[0].strip()) >= 10:
            s_stripped = [l.strip() for l in s_lines]
            indent_matches = []
            for i in range(len(file_lines) - n_s + 1):
                if [file_lines[i + j].strip() for j in range(n_s)] == s_stripped:
                    indent_matches.append(i)
            if len(indent_matches) == 1:
                idx = indent_matches[0]
                win_lines = file_lines[idx : idx + n_s]
                exact_slice = "\n".join(win_lines)
                if file_lf.count(exact_slice) == 1:
                    # Calculate leading space delta from first non-empty line
                    delta = 0
                    first_line_only_strip = False
                    non_empty_pairs = [(sl, wl) for sl, wl in zip(s_lines, win_lines) if sl.strip()]
                    if non_empty_pairs:
                        sl0, wl0 = non_empty_pairs[0]
                        s_lead = len(sl0) - len(sl0.lstrip(" "))
                        w_lead = len(wl0) - len(wl0.lstrip(" "))
                        if sl0.startswith(" " * s_lead) and wl0.startswith(" " * w_lead):
                            delta = w_lead - s_lead
                        if len(non_empty_pairs) >= 2 and s_lead == 0 and w_lead > 0:
                            sl1, wl1 = non_empty_pairs[1]
                            s1_lead = len(sl1) - len(sl1.lstrip(" "))
                            w1_lead = len(wl1) - len(wl1.lstrip(" "))
                            if s1_lead == w1_lead and s1_lead > 0:
                                first_line_only_strip = True
                    adj_replace = cand_replace
                    if delta != 0:
                        r_lines = cand_replace.split("\n")
                        if first_line_only_strip:
                            if r_lines and r_lines[0].strip() and len(r_lines[0]) == len(r_lines[0].lstrip(" ")):
                                r_lines[0] = (" " * delta) + r_lines[0]
                            adj_replace = "\n".join(r_lines)
                        else:
                            new_r_lines = []
                            for rl in r_lines:
                                if not rl.strip():
                                    new_r_lines.append(rl)
                                elif delta > 0:
                                    new_r_lines.append((" " * delta) + rl)
                                else:
                                    rem = min(-delta, len(rl) - len(rl.lstrip(" ")))
                                    new_r_lines.append(rl[rem:])
                            adj_replace = "\n".join(new_r_lines)
                    s_out, r_out = _finalize(exact_slice, adj_replace)
                    return ("ok", s_out, r_out, [idx + 1], "indent_norm")
            elif len(indent_matches) > 1 and not replace_all:
                return ("non_unique", cand_search, cand_replace, [m + 1 for m in indent_matches], "indent_norm")

    # Tier 4: Unicode typography normalization (smart quotes, dashes, nbsp)
    if cand_search.strip():
        try:
            typo_re = build_typography_regex(cand_search)
            t_matches = list(typo_re.finditer(file_lf))
            if len(t_matches) == 1 or (len(t_matches) > 1 and replace_all):
                exact_slice = t_matches[0].group(0)
                if file_lf.count(exact_slice) == 1 or replace_all:
                    s_out, r_out = _finalize(exact_slice, cand_replace)
                    return ("ok", s_out, r_out, [], "typography_norm")
            elif len(t_matches) > 1 and not replace_all:
                m_lines = [file_lf.count("\n", 0, m.start()) + 1 for m in t_matches]
                return ("non_unique", cand_search, cand_replace, m_lines, "typography_norm")
        except re.error:
            pass

    return ("not_found", cand_search, cand_replace, [], "")


def parse_block_string(content_str: str) -> List[Tuple[str, str, bool]]:
    """Parses <<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE blocks."""
    blocks: List[Tuple[str, str, bool]] = []
    if not content_str:
        return blocks

    has_start_marker = "<<<<<<<" in content_str
    current_search: List[str] = []
    current_replace: List[str] = []
    state = "outside"

    for raw_line in content_str.split("\n"):
        line = raw_line.rstrip("\r")
        if line.startswith("<<<<<<<"):
            state = "in_search"
            current_search = []
        elif line.startswith("======="):
            if state == "in_search":
                state = "in_replace"
                current_replace = []
        elif line.startswith(">>>>>>>"):
            if state == "in_replace":
                blocks.append(("\n".join(current_search), "\n".join(current_replace), False))
            state = "outside"
        else:
            if state == "in_search":
                current_search.append(line)
            elif state == "in_replace":
                current_replace.append(line)
            elif state == "outside" and not has_start_marker and line.strip():
                state = "in_search"
                current_search = [line]

    return blocks


def _parse_optional_line(val) -> Optional[int]:
    if val is None or isinstance(val, bool):
        return None
    if isinstance(val, int):
        return val
    if isinstance(val, str) and val.strip().lstrip("-").isdigit():
        return int(val.strip())
    return None


def _extract_edit_pair(
    item: dict,
    default_replace_all: bool = False,
    default_start_line: Optional[int] = None,
    default_end_line: Optional[int] = None,
) -> Optional[Tuple[str, str, bool, Optional[int], Optional[int]]]:
    start_line = _parse_optional_line(item.get("start_line", default_start_line))
    end_line = _parse_optional_line(item.get("end_line", default_end_line))
    if start_line is not None and end_line is None:
        end_line = start_line

    target = None
    for k in ("target", "old_text", "old_str", "search"):
        if k in item and item[k] is not None:
            target = str(item[k])
            break

    has_replacement_key = any(
        k in item and item[k] is not None
        for k in ("replacement", "new_text", "new_str", "replace")
    )
    if target is None:
        if start_line is not None and end_line is not None and has_replacement_key:
            target = ""
        else:
            return None

    replacement = ""
    for k in ("replacement", "new_text", "new_str", "replace"):
        if k in item and item[k] is not None:
            replacement = str(item[k])
            break

    rep_all = bool(item.get("replace_all", default_replace_all))
    return (target, replacement, rep_all, start_line, end_line)


def parse_structured_edits(
    edits_json_str: str,
) -> Tuple[List[Tuple[str, str, bool, Optional[int], Optional[int]]], Optional[str]]:
    """
    Parses structured JSON edits.
    Returns (blocks, fallback_expression).
    """
    blocks: List[Tuple[str, str, bool, Optional[int], Optional[int]]] = []
    if not edits_json_str or not edits_json_str.strip():
        return blocks, None

    try:
        data = json.loads(edits_json_str)
    except Exception:
        return blocks, None

    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                pair = _extract_edit_pair(item, False)
                if pair is not None:
                    blocks.append(pair)
        return blocks, None

    if isinstance(data, dict):
        default_rep_all = bool(data.get("replace_all", False))
        default_sl = _parse_optional_line(data.get("start_line"))
        default_el = _parse_optional_line(data.get("end_line"))
        if isinstance(data.get("edits"), list) and len(data["edits"]) > 0:
            for item in data["edits"]:
                if isinstance(item, dict):
                    pair = _extract_edit_pair(item, default_rep_all)
                    if pair is not None:
                        blocks.append(pair)
            if blocks:
                return blocks, None

        pair = _extract_edit_pair(data, default_rep_all, default_sl, default_el)
        if pair is not None:
            # What if the model put <<<<<<< SEARCH inside 'target' with empty 'replacement'?
            t_str, r_str, r_all, sl, el = pair
            if not r_str and "<<<<<<<" in t_str and "=======" in t_str and ">>>>>>>" in t_str:
                legacy = parse_block_string(t_str)
                return [(s, r, ra, sl, el) for (s, r, ra) in legacy], None
            blocks.append(pair)
            return blocks, None

        expr = data.get("expression")
        if isinstance(expr, str) and expr:
            legacy = parse_block_string(expr)
            return [(s, r, ra, default_sl, default_el) for (s, r, ra) in legacy], expr

    return blocks, None


def atomic_write_file(fullpath: str, new_content: str) -> None:
    abs_path = os.path.abspath(fullpath)
    parent_dir = os.path.dirname(abs_path) or "."
    orig_mode = None
    if os.path.exists(abs_path):
        try:
            orig_mode = stat.S_IMODE(os.stat(abs_path).st_mode)
        except OSError:
            orig_mode = None

    fd, tmp_path = tempfile.mkstemp(prefix=".george_edit_", dir=parent_dir, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(new_content)
            f.flush()
            os.fsync(f.fileno())
        if orig_mode is not None:
            try:
                os.chmod(tmp_path, orig_mode)
            except OSError:
                pass
        os.replace(tmp_path, abs_path)
    except Exception:
        try:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError:
            pass
        raise


def apply_ranged_block(
    working_content: str,
    search: str,
    replace: str,
    replace_all: bool,
    start_line: int,
    end_line: int,
) -> Tuple[str, str, List[int], str, str]:
    """
    Applies a line-range anchored edit (1-indexed inclusive [start_line .. end_line]).
    Returns (status, new_working_content, match_lines, tier, err_detail).
    """
    use_crlf = "\r\n" in working_content
    file_lf = working_content.replace("\r\n", "\n") if use_crlf else working_content
    has_trailing_nl = file_lf.endswith("\n")
    body_lf = file_lf[:-1] if has_trailing_nl else file_lf
    lines = body_lf.split("\n") if body_lf else []
    total_lines = len(lines)

    if start_line < 1 or end_line < start_line or start_line > max(1, total_lines):
        return (
            "range_error",
            working_content,
            [],
            "",
            f"Invalid line range start_line={start_line}, end_line={end_line} (file has {total_lines} lines).",
        )

    eff_end = min(total_lines, end_line)
    norm_replace = replace.replace("\r\n", "\n")
    if norm_replace.endswith("\n") and not search.endswith("\n"):
        norm_replace = norm_replace[:-1]

    # Case A: Boundary-anchored slice replacement (target omitted / empty)
    if not search:
        rep_lines = norm_replace.split("\n") if norm_replace != "" else []
        new_lines = lines[: start_line - 1] + rep_lines + lines[eff_end:]
        out_lf = "\n".join(new_lines) + ("\n" if has_trailing_nl and new_lines else "")
        out_content = out_lf.replace("\n", "\r\n") if use_crlf else out_lf
        return ("ok", out_content, [start_line], "line_range", "")

    # Case B: Scoped 4-tier search inside [start_line .. end_line] (with ±3 line tolerance halo fallback)
    for win_s, win_e in (
        (start_line - 1, eff_end),
        (max(0, start_line - 4), min(total_lines, eff_end + 3)),
    ):
        slice_str = "\n".join(lines[win_s:win_e])
        status, matched_s, resolved_r, m_lines, tier = resolve_block_match(
            slice_str, search, replace, replace_all=replace_all
        )
        if status == "ok":
            if replace_all:
                new_slice = slice_str.replace(matched_s, resolved_r)
            else:
                new_slice = slice_str.replace(matched_s, resolved_r, 1)
            new_slice_lines = new_slice.split("\n")
            new_lines = lines[:win_s] + new_slice_lines + lines[win_e:]
            out_lf = "\n".join(new_lines) + ("\n" if has_trailing_nl else "")
            out_content = out_lf.replace("\n", "\r\n") if use_crlf else out_lf
            return ("ok", out_content, [win_s + 1], f"{tier}+line_range", "")
        if status == "non_unique":
            abs_lines = [win_s + ln for ln in m_lines]
            return ("non_unique", working_content, abs_lines, f"{tier}+line_range", "")

    return ("not_found", working_content, [], "", "")


def apply_edit(
    fullpath: str,
    content_str: str = "",
    edits_json_str: str = "",
) -> int:
    if not os.path.exists(fullpath):
        print(f"Error: Target file not found: {fullpath}", file=sys.stderr)
        return 1

    raw_blocks = []
    if edits_json_str:
        raw_blocks, fallback_expr = parse_structured_edits(edits_json_str)
        if not raw_blocks and fallback_expr and not content_str:
            content_str = fallback_expr

    if not raw_blocks and content_str:
        raw_blocks = parse_block_string(content_str)

    if not raw_blocks:
        print(
            "Error: Edit rejected — invalid block-replace format. Could not parse any search/replace blocks.",
            file=sys.stderr,
        )
        return 1

    norm_blocks: List[Tuple[int, str, str, bool, Optional[int], Optional[int]]] = []
    top_sl, top_el = None, None
    if edits_json_str:
        try:
            _top_data = json.loads(edits_json_str)
            if isinstance(_top_data, dict):
                top_sl = _parse_optional_line(_top_data.get("start_line", _top_data.get("startLine")))
                top_el = _parse_optional_line(_top_data.get("end_line", _top_data.get("endLine")))
                if top_sl is not None and top_el is None:
                    top_el = top_sl
                elif top_el is not None and top_sl is None:
                    top_sl = top_el
        except Exception:
            pass
    for idx, b in enumerate(raw_blocks):
        if len(b) == 5:
            s, r, ra, sl, el = b
        else:
            s, r, ra = b
            sl, el = (top_sl, top_el) if len(raw_blocks) == 1 else (None, None)
        norm_blocks.append((idx, s, r, ra, sl, el))

    # If multiple blocks specify start_line, apply ranged blocks in descending start_line
    # order so earlier top-of-file edits never shift line numbers for bottom-of-file edits.
    if sum(1 for b in norm_blocks if b[4] is not None) > 1:
        ranged = sorted(
            [b for b in norm_blocks if b[4] is not None],
            key=lambda x: (x[4] or 0, x[5] or 0),
            reverse=True,
        )
        unranged = [b for b in norm_blocks if b[4] is None]
        exec_order = ranged + unranged
    else:
        exec_order = norm_blocks

    # Acquire per-file advisory lock across the read-verify-replace cycle
    abs_target = os.path.realpath(fullpath)
    lock_dir = os.path.join(
        os.environ.get("FIFO_IPC_DIR", "/tmp/blue_lodge_ipc"), "file_locks"
    )
    try:
        os.makedirs(lock_dir, exist_ok=True)
    except OSError:
        lock_dir = "/tmp"
    lock_hash = hashlib.sha256(abs_target.encode("utf-8")).hexdigest()[:32]
    lock_path = os.path.join(lock_dir, f"{lock_hash}.lock")

    lock_fd = None
    if os.environ.get("LODGE_FILE_LOCK_HELD") != lock_path:
        try:
            lock_fd = open(lock_path, "a+", encoding="utf-8")
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
        except OSError:
            pass

    try:
        try:
            with open(fullpath, "r", encoding="utf-8") as f:
                file_content = f.read()
        except Exception as e:
            print(f"Error reading file {fullpath}: {e}", file=sys.stderr)
            return 1

        working_content = file_content
        applied_count = 0
        tier_by_idx = {}

        for idx, search, replace, replace_all, start_line, end_line in exec_order:
            if start_line is not None and end_line is not None:
                status, new_wc, match_lines, tier, err_detail = apply_ranged_block(
                    working_content, search, replace, replace_all, start_line, end_line
                )
                if status == "range_error":
                    print(f"Error: {err_detail} (block {idx + 1}).", file=sys.stderr)
                    return 1
                if status == "not_found":
                    diag = find_closest_match_diagnostic(working_content, search)
                    msg = f"Error: Search pattern not found in lines {start_line}-{end_line} of target file (block {idx + 1})."
                    if diag:
                        msg = f"{msg}\n{diag}"
                    print(msg, file=sys.stderr)
                    return 1
                if status == "non_unique":
                    loc_str = (
                        f" at lines {', '.join(str(n) for n in match_lines[:10])}"
                        if match_lines
                        else ""
                    )
                    print(
                        f"Error: Search pattern is not unique within lines {start_line}-{end_line} (found multiple matches{loc_str}) in block {idx + 1}.",
                        file=sys.stderr,
                    )
                    return 1
                working_content = new_wc
                applied_count += 1
                if tier:
                    tier_by_idx[idx] = tier
                continue

            if not search:
                print(f"Error: Empty search pattern in block {idx + 1}.", file=sys.stderr)
                return 1

            status, matched_search, resolved_replace, match_lines, tier = resolve_block_match(
                working_content, search, replace, replace_all=replace_all
            )

            if status == "not_found":
                diag = find_closest_match_diagnostic(working_content, search)
                msg = f"Error: Search pattern not found in target file (block {idx + 1})."
                if diag:
                    msg = f"{msg}\n{diag}"
                print(msg, file=sys.stderr)
                return 1

            if status == "non_unique":
                loc_str = (
                    f" at lines {', '.join(str(n) for n in match_lines[:10])}"
                    if match_lines
                    else ""
                )
                print(
                    f"Error: Search pattern is not unique (found multiple matches{loc_str}) in block {idx + 1}. "
                    "Include 1-2 surrounding context lines in `target` to disambiguate, pass `start_line` and `end_line`, or set `replace_all: true`.",
                    file=sys.stderr,
                )
                return 1

            if replace_all:
                working_content = working_content.replace(matched_search, resolved_replace)
            else:
                working_content = working_content.replace(matched_search, resolved_replace, 1)
            applied_count += 1
            if tier:
                tier_by_idx[idx] = tier

        matched_tiers = [tier_by_idx[i] for i in sorted(tier_by_idx.keys())]

        try:
            atomic_write_file(fullpath, working_content)
        except Exception as e:
            print(f"Error writing file {fullpath}: {e}", file=sys.stderr)
            return 1

        if matched_tiers:
            print(f"Applied {applied_count} block edits [{', '.join(matched_tiers)}].")
        else:
            print(f"Applied {applied_count} block edits.")
        return 0
    finally:
        if lock_fd is not None:
            try:
                fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
                lock_fd.close()
            except OSError:
                pass


def main():
    if len(sys.argv) < 2:
        print("Usage: edit_backend.py <fullpath> [content_str]", file=sys.stderr)
        sys.exit(1)

    fullpath = sys.argv[1]
    if len(sys.argv) >= 3:
        content_str = sys.argv[2]
    else:
        content_str = os.environ.get("CONTENT", "")

    edits_json_str = os.environ.get("EDITS_JSON", "")
    rc = apply_edit(fullpath, content_str=content_str, edits_json_str=edits_json_str)
    sys.exit(rc)


if __name__ == "__main__":
    main()
