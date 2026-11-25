#!/usr/bin/env python3
"""
lib/tools/osint_sdr_digest.py — Lightweight Multi-Domain OSINT & Local P25 SDR SIGINT Digest Builder.

Replaces the retired mock trading_bot.py dependency in scripts/cron_system/trading_reporter.sh.
Zero paid API keys, pure Python stdlib (+ optional defusedxml), safe out-of-place execution,
and graceful fallback when local SDR database is absent.
"""
from __future__ import annotations

import argparse
import html
import os
import re
import sys
import time
import urllib.request
from pathlib import Path
from typing import Dict, List, Tuple

try:
    import defusedxml.ElementTree as ET  # type: ignore
except ImportError:
    import xml.etree.ElementTree as ET  # type: ignore

# Public, keyless RSS/Atom intelligence feeds grouped by domain tag
INTEL_FEEDS: List[Tuple[str, str, str]] = [
    ("AI", "ArXiv cs.AI", "https://export.arxiv.org/rss/cs.AI"),
    ("AI-POL", "EFF Updates", "https://www.eff.org/rss/updates.xml"),
    ("TECH", "Hacker News Frontpage", "https://hnrss.org/frontpage"),
    ("MIL-TECH", "Defense One", "https://www.defenseone.com/rss/technology/"),
    ("GEO", "BBC World", "https://feeds.bbci.co.uk/news/world/rss.xml"),
    ("SCIENCE", "ScienceDaily Top", "https://www.sciencedaily.com/rss/top/science.xml"),
    ("CRYPTO", "CoinDesk", "https://www.coindesk.com/arc/outboundfeeds/rss/"),
]

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")


def _resolve_repo_root() -> Path:
    env_dir = os.environ.get("LODGE_DIR", "").strip()
    if env_dir and Path(env_dir).is_dir():
        return Path(env_dir).resolve()
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "lodge").is_file() or (parent / "lib" / "tools").is_dir():
            return parent
    return here.parent


def _clean_text(raw: str, limit: int = 160) -> str:
    txt = html.unescape(TAG_RE.sub(" ", raw or ""))
    txt = WS_RE.sub(" ", txt).strip()
    if len(txt) > limit:
        return txt[: limit - 1].rstrip() + "…"
    return txt


def fetch_feed_items(url: str, limit: int = 3, timeout: float = 6.0) -> List[Dict[str, str]]:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "BlueLodge-OSINT-Digest/1.0 (self-hosted)"},
    )
    items: List[Dict[str, str]] = []
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read(512 * 1024)
        root = ET.fromstring(data)
    except Exception:
        return items

    # RSS 2.0 <item> or Atom <entry>
    entries = root.findall(".//item")
    if not entries:
        entries = root.findall(".//{http://www.w3.org/2005/Atom}entry")

    for entry in entries[:limit]:
        title = (
            entry.findtext("title")
            or entry.findtext("{http://www.w3.org/2005/Atom}title")
            or ""
        )
        link = entry.findtext("link") or ""
        if not link:
            link_el = entry.find("{http://www.w3.org/2005/Atom}link")
            if link_el is not None:
                link = link_el.attrib.get("href", "")
        desc = (
            entry.findtext("description")
            or entry.findtext("{http://www.w3.org/2005/Atom}summary")
            or ""
        )
        t_clean = _clean_text(title, 120)
        l_clean = (link or "").strip()
        if t_clean and l_clean.startswith(("http://", "https://")):
            items.append({
                "title": t_clean,
                "url": l_clean,
                "snippet": _clean_text(desc, 160),
            })
    return items


def get_sdr_summary(repo_root: Path, hours: float = 3.0) -> str:
    tools_dir = repo_root / "lib" / "tools"
    if not (tools_dir / "sdr_ingest.py").is_file():
        return ""
    try:
        if str(tools_dir) not in sys.path:
            sys.path.insert(0, str(tools_dir))
        import sdr_ingest  # type: ignore

        fn = getattr(sdr_ingest, "generate_osint_sdr_summary_markdown", None)
        if callable(fn):
            return str(fn(hours=hours) or "").strip()
    except Exception:
        return ""
    return ""


def build_report(hours: float = 3.0, limit_per_domain: int = 2, skip_network: bool = False) -> str:
    repo_root = _resolve_repo_root()
    ts_str = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
    lines: List[str] = [
        f"# Sovereign 3-Hour OSINT & SDR SIGINT Source Feed — {ts_str}",
        "",
        "## INTEL FEED",
    ]

    total = 0
    if not skip_network:
        for tag, source_name, url in INTEL_FEEDS:
            for it in fetch_feed_items(url, limit=limit_per_domain):
                total += 1
                lines.append(f"- [{tag}] **{it['title']}** ({source_name}) — {it['url']}")
                if it["snippet"]:
                    lines.append(f"  - {it['snippet']}")
    if total == 0:
        lines.append("- (No fresh RSS items fetched this cycle; offline or quiet feed window.)")

    lines.append("")
    lines.append("## LOCAL P25 SDR SIGINT & COMMUNICATIONS TELEMETRY")
    sdr_md = get_sdr_summary(repo_root, hours=hours)
    if sdr_md:
        lines.append(sdr_md)
    else:
        lines.append("_Local P25 SDR database not active or no intelligible dispatches in the last 3 hours._")

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Build 3-hour OSINT & Local SDR SIGINT markdown source report.")
    ap.add_argument("--report", action="store_true", help="Print compiled markdown digest to stdout")
    ap.add_argument("--hours", type=float, default=3.0, help="SDR lookback window in hours (default: 3.0)")
    ap.add_argument("--limit", type=int, default=2, help="Max articles per feed domain (default: 2)")
    ap.add_argument("--offline", action="store_true", help="Skip external RSS fetches (SDR & smoke-test mode)")
    args = ap.parse_args()

    out = build_report(hours=args.hours, limit_per_domain=max(1, min(5, args.limit)), skip_network=args.offline)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
