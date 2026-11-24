#!/usr/bin/env python3
"""Explicit Web Fetch, Domain Scraper & Page Overview Mapper FSM for George.

Implements a deterministic 6-state Finite State Machine:
  S1_CLASSIFY_AND_ROUTE  -> Classify URL domain & select specialized adapter
  S2_DOMAIN_ADAPTER      -> Unblocked API/Syndication adapters:
                            - Reddit (.rss Atom XML primary + PoW cookie session + .json fallback)
                            - MediaWiki / Fandom / Wiki.gg / Wikipedia (/api.php?action=parse)
                            - Wowhead (WH.Gatherer.addData + WH.markup.printHtml + data.article-body)
                            - StackExchange / StackOverflow Q&A extractor
  S3_STEALTH_HTTP_FETCH  -> Coherent HTTP fetch + WAF challenge detection + Wayback snapshot rescue
  S4_EXTRACT_AND_MAP     -> Multi-tier extraction + Page Overview Header (Title, Section Map, Key Links):
                            - Tier 1: trafilatura Markdown + lxml DOM cleaner + JSON-LD / SPA state
                            - Tier 2: Zero-pip Python stdlib HTMLParser (preserves inline tags & numbers)
  S5_SNIPPET_RESCUE      -> Automatic fallback to cached search snippets on 403/WAF block
  S6_TELEMETRY_AND_EMIT  -> Per-fetch JSONL telemetry (.george/logs/web_fetch.jsonl) + output formatting

CLI Usage:
  web_scraper.py fetch <url> [--format markdown|json] [--max-chars 24000] [--no-overview]
  web_scraper.py extract-stdin [--url <url>] [--format markdown|json] [--max-chars 24000]
"""

from __future__ import annotations

import argparse
import html as html_mod
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

# Optional Tier-1 dependencies (graceful fallback to Tier-2 stdlib if absent)
try:
    import trafilatura  # type: ignore
    HAS_TRAFILATURA = True
except ImportError:
    HAS_TRAFILATURA = False

try:
    from lxml import html as lxml_html  # type: ignore
    from lxml.html.clean import Cleaner as LxmlCleaner  # type: ignore
    HAS_LXML = True
except ImportError:
    HAS_LXML = False

try:
    import defusedxml.ElementTree as SafeET  # type: ignore
except ImportError:
    import xml.etree.ElementTree as SafeET  # nosec B405 - fallback when defusedxml is absent

try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import challenge_solver as cs
except ImportError:
    cs = None  # type: ignore


# ── Constants & Headers ──────────────────────────────────────────────

FIREFOX_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Upgrade-Insecure-Requests": "1",
}

CRAWLER_HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

REDDIT_FEED_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
    "Accept": "application/atom+xml,application/xml,text/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

WAF_MARKERS = (
    "cf-chl-bypass",
    "cf-chl-widget",
    "challenge-platform",
    "_cf_chl_opt",
    "verify you are human",
    "just a moment...",
    "enable javascript and cookies",
    "please wait for verification",
    "checking your browser",
    "security verification",
    "human verification",
    "robot check",
    "vercel security checkpoint",
    "datadome",
    "perimeterx",
    "awswafintegration",
    "awswafcookiedomainlist",
    "token.awswaf.com",
    "verify that you're not a robot",
    "you've been blocked by network security",
)

NAV_LINK_BLACKLIST_RX = re.compile(
    r"(login|signin|signup|register|logout|account|password|privacy|terms|cookie|"
    r"legal|sitemap|contact|advertise|donate|subscribe|facebook\.com|twitter\.com|"
    r"x\.com|instagram\.com|discord\.gg|tiktok\.com|youtube\.com|reddit\.com/login|"
    r"javascript:|mailto:|tel:)",
    re.I,
)


def _george_dir() -> Path:
    env_dir = os.environ.get("GEORGE_CONFIG_DIR") or os.environ.get("GEORGE_DIR")
    if env_dir:
        return Path(env_dir)
    lodge_dir = os.environ.get("LODGE_DIR")
    if lodge_dir:
        return Path(lodge_dir) / ".george"
    return Path(__file__).resolve().parents[2] / ".george"


def _cookie_jar() -> Path:
    p = _george_dir() / "state" / "web_cookies.jar"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def _reddit_jar() -> Path:
    p = _george_dir() / "state" / "reddit_cookies.jar"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


# ── Low-Level HTTP Execution ─────────────────────────────────────────

def http_fetch(
    url: str,
    headers: dict[str, str] | None = None,
    cookie_jar: Path | None = None,
    timeout: float = 12.0,
    max_bytes: int = 5_000_000,
) -> tuple[int, str, str]:
    """Fetch URL via curl (or urllib fallback), returning (status, content_type, body)."""
    hdrs = headers or FIREFOX_HEADERS

    if shutil.which("curl"):
        cmd = [
            "curl",
            "-sL",
            "--compressed",
            "--connect-timeout",
            "6",
            "--max-time",
            str(max(3, int(timeout))),
            "-w",
            "\n__META_STATUS:%{http_code}|%{content_type}__\n",
        ]
        if cookie_jar is not None:
            cmd.extend(["-b", str(cookie_jar), "-c", str(cookie_jar)])
        for k, v in hdrs.items():
            cmd.extend(["-H", f"{k}: {v}"])
        cmd.append(url)
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                errors="replace",
                timeout=timeout + 3.0,
            )
            out = proc.stdout or ""
            status = 0
            ctype = ""
            body = out
            if "\n__META_STATUS:" in out:
                body, meta = out.rsplit("\n__META_STATUS:", 1)
                meta = meta.split("__", 1)[0]
                parts = meta.split("|", 1)
                try:
                    status = int(parts[0].strip())
                except ValueError:
                    status = 0
                if len(parts) > 1:
                    ctype = parts[1].strip().lower()
            return status, ctype, body[:max_bytes]
        except Exception:
            return 0, "", ""

    req = urllib.request.Request(url, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosec B310
            raw = resp.read(max_bytes)
            ctype = (resp.headers.get("Content-Type") or "").lower()
            return resp.status, ctype, raw.decode("utf-8", errors="replace")
    except urllib.error.HTTPError as he:
        return he.code, "", ""
    except Exception:
        return 0, "", ""


def is_waf_or_block(status: int, body: str) -> str:
    """Return non-empty block reason if status or body is a WAF/CAPTCHA interstitial."""
    if status in (401, 403, 407, 429, 451, 503, 520, 521, 522, 523, 525, 530, 999):
        return f"HTTP_{status}_BLOCK"
    if not body:
        return "EMPTY_BODY"
    # Real pages > 40KB that returned HTTP 200 are not pure WAF challenge interstitials
    if len(body) > 40000:
        return ""
    low = body.lower()
    if any(m in low for m in WAF_MARKERS):
        return "HTML_CHALLENGE_OR_CAPTCHA"
    if len(body) < 20000 and any(m in low for m in ("captcha", "request blocked", "bot detection", "incapsula")):
        return "HTML_CHALLENGE_OR_CAPTCHA"
    if len(body) < 5000 and any(m in low for m in ("cloudflare", "akamai", "access denied", "security check")):
        stripped = re.sub(r"<[^>]+>", " ", low)
        if any(m in stripped for m in ("cloudflare", "akamai", "access denied", "security check")):
            return "HTML_CHALLENGE_OR_CAPTCHA"
    return ""


# ── Tier 2: Pure Python Stdlib HTML -> Markdown & Structure Parser ──

class StdlibPageParser(HTMLParser):
    """Zero-dependency HTML parser that preserves inline tags/numbers and extracts headings & links."""

    SKIP_TAGS = {"script", "style", "noscript", "svg", "head", "template", "iframe", "canvas", "path"}
    BOILERPLATE_TAGS = {"nav", "footer", "aside"}
    BLOCK_TAGS = {
        "p", "div", "section", "article", "main", "blockquote",
        "ul", "ol", "li", "table", "thead", "tbody", "tr", "hr", "br", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6", "dt", "dd", "figcaption",
    }
    HEADING_TAGS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4}

    def __init__(self, base_url: str = "", strip_nav: bool = True) -> None:
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.strip_nav = strip_nav
        self.title: str = ""
        self._in_title = False
        self._skip_depth = 0
        self._nav_depth = 0
        self._in_heading: int = 0
        self._heading_buf: list[str] = []
        self._in_link_href: str = ""
        self._link_buf: list[str] = []
        self._in_td = False
        self._in_pre = False
        self.headings: list[tuple[int, str]] = []
        self.links: list[tuple[str, str]] = []
        self.images: list[str] = []
        self._lines: list[str] = []
        self._cur: list[str] = []

    def _flush_line(self) -> None:
        if not self._cur:
            return
        raw = "".join(self._cur)
        self._cur = []
        if not self._in_pre:
            line = re.sub(r"[ \t\r\n]+", " ", raw).strip()
        else:
            line = raw.rstrip()
        if line:
            self._lines.append(line)

    def _resolve(self, href: str) -> str:
        href = href.strip()
        if not href or href.startswith(("#", "javascript:", "mailto:", "tel:", "data:")):
            return ""
        if self.base_url:
            return urllib.parse.urljoin(self.base_url, href)
        return href if href.startswith("http") else ""

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        t = tag.lower()
        attr_dict = {k.lower(): (v or "") for k, v in attrs if k}

        if t == "title":
            self._in_title = True
            return

        if t == "meta":
            prop = (attr_dict.get("property") or attr_dict.get("name") or "").lower()
            content = attr_dict.get("content") or ""
            if prop in ("og:image", "twitter:image") and content:
                resolved = self._resolve(content)
                if resolved and resolved not in self.images:
                    self.images.append(resolved)
            if prop == "og:title" and content and not self.title:
                self.title = content.strip()
            return

        if t in self.SKIP_TAGS:
            self._skip_depth += 1
            return

        if self._skip_depth > 0:
            return

        if self.strip_nav:
            role = attr_dict.get("role", "").lower()
            cls_id = (attr_dict.get("class", "") + " " + attr_dict.get("id", "")).lower()
            if t in self.BOILERPLATE_TAGS or role in ("navigation", "banner", "contentinfo"):
                self._nav_depth += 1
                return
            if self._nav_depth > 0:
                if t in ("div", "section", "nav", "footer", "aside", "header"):
                    self._nav_depth += 1
                return
            if t in ("div", "section", "header") and any(
                k in cls_id for k in ("cookie-banner", "cookie-consent", "gdpr", "nav-menu", "site-header", "site-footer", "comment-box")
            ):
                self._nav_depth += 1
                return

        if t == "img":
            src = attr_dict.get("src") or attr_dict.get("data-src") or attr_dict.get("data-lazy-src") or ""
            resolved = self._resolve(src)
            if resolved and resolved not in self.images and len(self.images) < 20:
                self.images.append(resolved)
            return

        if t in self.HEADING_TAGS:
            self._flush_line()
            self._in_heading = self.HEADING_TAGS[t]
            self._heading_buf = []
            self._cur.append("#" * self._in_heading + " ")
        elif t == "li":
            self._flush_line()
            self._cur.append("- ")
        elif t == "br":
            self._flush_line()
        elif t == "tr":
            self._flush_line()
        elif t in ("td", "th"):
            if self._cur and not self._cur[-1].endswith(" | "):
                self._cur.append(" | ")
            self._in_td = True
        elif t == "pre":
            self._flush_line()
            self._in_pre = True
        elif t in self.BLOCK_TAGS:
            self._flush_line()
        elif t == "a":
            href = self._resolve(attr_dict.get("href", ""))
            if href:
                self._in_link_href = href
                self._link_buf = []
        elif t in ("b", "strong"):
            self._cur.append("**")
        elif t == "code" and not self._in_pre:
            self._cur.append("`")

    def handle_endtag(self, tag: str) -> None:
        t = tag.lower()
        if t == "title":
            self._in_title = False
            return
        if t in self.SKIP_TAGS:
            if self._skip_depth > 0:
                self._skip_depth -= 1
            return
        if self._skip_depth > 0:
            return
        if self._nav_depth > 0:
            if t in self.BOILERPLATE_TAGS or t in ("div", "section", "header"):
                self._nav_depth -= 1
            return

        if t in self.HEADING_TAGS:
            h_text = re.sub(r"\s+", " ", "".join(self._heading_buf)).strip()
            if h_text and len(h_text) < 160:
                self.headings.append((self._in_heading, h_text))
            self._in_heading = 0
            self._heading_buf = []
            self._flush_line()
        elif t == "a":
            if self._in_link_href:
                anchor = re.sub(r"\s+", " ", "".join(self._link_buf)).strip()
                if anchor and len(anchor) >= 2 and not NAV_LINK_BLACKLIST_RX.search(self._in_link_href):
                    self.links.append((anchor[:90], self._in_link_href))
            self._in_link_href = ""
            self._link_buf = []
        elif t in ("b", "strong"):
            self._cur.append("**")
        elif t == "code" and not self._in_pre:
            self._cur.append("`")
        elif t == "pre":
            self._flush_line()
            self._in_pre = False
        elif t in ("td", "th"):
            self._in_td = False
        elif t in self.BLOCK_TAGS:
            self._flush_line()

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title = (self.title + " " + data).strip()
            return
        if self._skip_depth > 0 or self._nav_depth > 0:
            return
        if self._in_heading:
            self._heading_buf.append(data)
        if self._in_link_href:
            self._link_buf.append(data)
        self._cur.append(data)

    def get_markdown(self) -> str:
        self._flush_line()
        cleaned: list[str] = []
        for line in self._lines:
            # Remove empty bold markers
            line = line.replace("****", "").strip()
            if not line:
                continue
            cleaned.append(line)
        return "\n".join(cleaned)


# ── SPA / JSON-LD / Wowhead Script State Extractor ──────────────────

def extract_embedded_script_content(raw_html: str, url: str) -> tuple[str, list[tuple[str, str]]]:
    """Extract content hidden inside <script> tags (Wowhead BBCode, JSON-LD, __NEXT_DATA__)."""
    extra_sections: list[str] = []
    extra_links: list[tuple[str, str]] = []

    # 1. Wowhead WH.Gatherer.addData + WH.markup.printHtml + data.article-body-*
    if "wowhead.com" in url.lower() or "WH.markup.printHtml" in raw_html or "data.article-body" in raw_html:
        gatherer_names: dict[str, str] = {}
        gatherer_urls: dict[str, str] = {}
        dec = json.JSONDecoder()
        for m in re.finditer(r"WH\.Gatherer\.addData\(\s*(\d+)\s*,\s*(\d+)\s*,\s*\{", raw_html):
            try:
                data_obj, _ = dec.raw_decode(raw_html, m.end() - 1)
                if isinstance(data_obj, dict):
                    for k, v in data_obj.items():
                        if isinstance(v, dict):
                            nm = v.get("name_enus") or v.get("name") or ""
                            if nm:
                                gatherer_names[str(k)] = str(nm)
                            u = v.get("url") or ""
                            if u:
                                full_u = urllib.parse.urljoin(url, str(u))
                                gatherer_urls[str(k)] = full_u
                                if nm:
                                    extra_links.append((str(nm), full_u))
            except Exception:
                pass

        raw_bbcode_chunks: list[str] = []
        # Check <script type="application/json" id="data....">
        for m in re.finditer(
            r'<script[^>]*type="application/json"[^>]*id="(data\.[^"]*)"[^>]*>(.*?)</script>',
            raw_html,
            re.S | re.I,
        ):
            sid = m.group(1)
            if any(skip in sid for skip in ("pageMeta", "newsletter", "aboutTheAuthor")):
                continue
            try:
                val = json.loads(m.group(2))
                if isinstance(val, str) and len(val) > 200:
                    raw_bbcode_chunks.append(val)
            except Exception:
                pass

        # Check inline WH.markup.printHtml("...")
        for m in re.finditer(r'WH\.markup\.printHtml\(\s*"', raw_html):
            try:
                val, _ = dec.raw_decode(raw_html, m.end() - 1)
                if isinstance(val, str) and len(val) > 200:
                    raw_bbcode_chunks.append(val)
            except Exception:
                pass

        if raw_bbcode_chunks:
            converted = _convert_wowhead_bbcode("\n\n".join(raw_bbcode_chunks), gatherer_names, gatherer_urls, url)
            if len(converted) > 150:
                extra_sections.append(converted)

    # 2. JSON-LD (application/ld+json) Schema.org articleBody / FAQ / Product
    for m in re.finditer(
        r'<script[^>]*type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        raw_html,
        re.S | re.I,
    ):
        try:
            ld = json.loads(m.group(1).strip())
            items = ld if isinstance(ld, list) else [ld]
            for item in items:
                if not isinstance(item, dict):
                    continue
                if "@graph" in item and isinstance(item["@graph"], list):
                    items.extend(item["@graph"])
                body = item.get("articleBody") or item.get("text") or ""
                if isinstance(body, str) and len(body) > 200:
                    extra_sections.append(html_mod.unescape(body))
                # FAQPage support
                if item.get("@type") == "FAQPage" and isinstance(item.get("mainEntity"), list):
                    faq_lines = ["## Frequently Asked Questions"]
                    for q_item in item["mainEntity"]:
                        if isinstance(q_item, dict):
                            q_name = q_item.get("name", "")
                            ans = (q_item.get("acceptedAnswer") or {}).get("text", "")
                            if q_name and ans:
                                clean_ans = re.sub(r"<[^>]+>", " ", html_mod.unescape(str(ans))).strip()
                                faq_lines.append(f"### Q: {q_name}\n{clean_ans}")
                    if len(faq_lines) > 1:
                        extra_sections.append("\n\n".join(faq_lines))
        except Exception:
            pass

    return "\n\n".join(extra_sections), extra_links


def _convert_wowhead_bbcode(
    bb: str,
    names: dict[str, str],
    urls: dict[str, str],
    base_url: str,
) -> str:
    """Convert Wowhead BBCode & embedded HTML into clean Markdown with resolved IDs."""
    text = bb
    # Resolve [url guide=8202]Text[/url] or [url=/classic/...]Text[/url]
    def _repl_url(m: re.Match[str]) -> str:
        attr = m.group(1).strip()
        label = m.group(2).strip()
        g_match = re.search(r"guide=(\d+)", attr)
        if g_match:
            gid = g_match.group(1)
            target = urls.get(gid, f"https://www.wowhead.com/classic/guide={gid}")
            return f"[{label or names.get(gid, gid)}]({target})"
        href = attr.lstrip("=").strip().strip('"').strip("'")
        if href:
            return f"[{label}]({urllib.parse.urljoin(base_url, href)})"
        return label

    text = re.sub(r"\[url([^\]]*)\](.*?)\[/url\]", _repl_url, text, flags=re.I | re.S)

    # Resolve [spell=1234], [item=1234], [npc=1234], [quest=1234], [zone=1234]
    def _repl_entity(m: re.Match[str]) -> str:
        kind = m.group(1).lower()
        eid = m.group(2)
        resolved = names.get(eid)
        if resolved:
            return f"**{resolved}** ({kind} #{eid})"
        return f"[{kind}={eid}]"

    text = re.sub(r"\[(spell|item|npc|quest|zone|achievement)=(\d+)\]", _repl_entity, text, flags=re.I)

    # Convert headings & formatting tags
    text = re.sub(r"\[h1[^\]]*\](.*?)\[/h1\]", r"\n# \1\n", text, flags=re.I | re.S)
    text = re.sub(r"\[h2[^\]]*\](.*?)\[/h2\]", r"\n## \1\n", text, flags=re.I | re.S)
    text = re.sub(r"\[h3[^\]]*\](.*?)\[/h3\]", r"\n### \1\n", text, flags=re.I | re.S)
    text = re.sub(r"\[h4[^\]]*\](.*?)\[/h4\]", r"\n#### \1\n", text, flags=re.I | re.S)
    text = re.sub(r"\[b\](.*?)\[/b\]", r"**\1**", text, flags=re.I | re.S)
    text = re.sub(r"\[i\](.*?)\[/i\]", r"*\1*", text, flags=re.I | re.S)
    text = re.sub(r"\[li\]", "\n- ", text, flags=re.I)
    text = re.sub(r"\[/li\]", "", text, flags=re.I)
    text = re.sub(r"\[/?(ul|ol|table|tbody|thead|center|pad|div|p|br|hr|color|db|menu|html|toc|toggler|box|icon|class|race)[^\]]*\]", " ", text, flags=re.I)
    text = re.sub(r"\[tr\](.*?)\[/tr\]", r"\n\1", text, flags=re.I | re.S)
    text = re.sub(r"\[td[^\]]*\](.*?)\[/td\]", r" | \1", text, flags=re.I | re.S)

    # If HTML tags remain inside [html]...[/html], parse with StdlibPageParser
    if "<div" in text or "<a " in text or "<ul" in text or "<p" in text:
        p = StdlibPageParser(base_url=base_url, strip_nav=False)
        try:
            p.feed(text)
            text = p.get_markdown()
        except Exception:
            text = re.sub(r"<[^>]+>", " ", text)

    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.splitlines()]
    return "\n".join(ln for ln in lines if ln)


# ── S4: Multi-Tier HTML Extraction & Page Overview Builder ───────────

def extract_html_and_map(
    raw_html: str,
    url: str,
    adapter_name: str = "general_web",
) -> dict[str, Any]:
    """Run S4_EXTRACT_AND_MAP on raw HTML and return structured dict with Page Overview + Markdown."""
    parser = StdlibPageParser(base_url=url, strip_nav=True)
    try:
        parser.feed(raw_html)
    except Exception:
        pass

    stdlib_md = parser.get_markdown()
    title = parser.title.strip()
    headings = parser.headings
    links = parser.links
    images = parser.images

    # Check embedded script state (Wowhead / JSON-LD / Next.js)
    script_md, script_links = extract_embedded_script_content(raw_html, url)
    if script_links:
        links = script_links + links

    # Tier 1: Trafilatura Markdown extraction (if installed)
    trafilatura_md = ""
    tier_used = "tier2_stdlib_htmlparser"
    if HAS_TRAFILATURA:
        try:
            extracted = trafilatura.extract(
                raw_html,
                url=url,
                output_format="markdown",
                include_links=True,
                include_tables=True,
                favor_recall=True,
                deduplicate=True,
            )
            if extracted and len(extracted.strip()) >= 120:
                trafilatura_md = extracted.strip()
                tier_used = f"{adapter_name}:tier1_trafilatura"
        except Exception:
            pass

    # Choose best representation:
    # If script_md (e.g. Wowhead guide payload) is significantly richer than DOM text, combine them
    primary_md = trafilatura_md if len(trafilatura_md) >= len(stdlib_md) * 0.5 and len(trafilatura_md) >= 150 else stdlib_md
    if not trafilatura_md and primary_md:
        tier_used = f"{adapter_name}:tier2_stdlib_parser"

    if script_md and len(script_md) > len(primary_md):
        primary_md = script_md + ("\n\n" + primary_md if primary_md and len(primary_md) > 200 else "")
        tier_used = f"{adapter_name}:spa_script_extractor"

    # Extract markdown headings from primary_md (including BBCode/Trafilatura headings)
    if primary_md:
        md_headings: list[tuple[int, str]] = []
        for line in primary_md.splitlines():
            hm = re.match(r"^(#{1,4})\s+(.+)$", line.strip())
            if hm:
                md_headings.append((len(hm.group(1)), hm.group(2).strip()[:120]))
        if len(md_headings) > len(headings):
            headings = md_headings + headings

    # Deduplicate headings & links
    dedup_headings: list[str] = []
    seen_h: set[str] = set()
    for lvl, htxt in headings:
        key = htxt.lower()
        if key not in seen_h and len(htxt) >= 2:
            seen_h.add(key)
            dedup_headings.append(f"[H{lvl}] {htxt}")
        if len(dedup_headings) >= 18:
            break

    dedup_links: list[dict[str, str]] = []
    seen_u: set[str] = set()
    for anchor, href in links:
        if href not in seen_u and href != url:
            seen_u.add(href)
            dedup_links.append({"text": anchor, "url": href})
        if len(dedup_links) >= 12:
            break

    words = len(primary_md.split())
    return {
        "url": url,
        "title": title or url,
        "adapter": tier_used,
        "word_count": words,
        "section_map": dedup_headings,
        "links": dedup_links,
        "images": images[:15],
        "content": primary_md,
        "blocked": False,
        "block_reason": "",
        "http_status": 200,
    }


# ── S2: Domain-Specific Unblocked Adapters ───────────────────────────

def _urllib_fetch(url: str, headers: dict[str, str], timeout: float = 10.0) -> tuple[int, str]:
    """Direct HTTP/1.1 fetch via urllib.request (avoids curl HTTP/2 ALPN fingerprinting on Reddit /svc/shreddit/)."""
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(5_000_000).decode("utf-8", errors="ignore")
    except urllib.error.HTTPError as he:
        try:
            body = he.read(500_000).decode("utf-8", errors="ignore")
        except Exception:
            body = ""
        return he.code, body
    except Exception:
        return 0, ""


def _extract_shreddit_thread(url: str, sub: str, post_id: str, slug_title: str = "") -> dict[str, Any] | None:
    """High-throughput (200 req/window) Reddit thread + live upvote score extractor via /svc/shreddit/ + Arctic Shift."""
    sub_name = f"r/{sub}"
    shreddit_hdrs = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
        "Accept": "text/vnd.reddit.partial+html, text/html;q=0.9",
        "Accept-Language": "en-US,en;q=0.9",
    }

    # 1. Fetch OP metadata (title, selftext, score, author, media url) from Arctic Shift (zero rate-limit)
    op_title = slug_title.replace("_", " ").strip().title() or f"Thread {post_id}"
    op_author = "unknown"
    op_score: int | str = "N/A"
    op_num_comments: int | str = "N/A"
    op_selftext = ""
    op_ext_url = ""
    media_images: list[str] = []

    as_status, as_body = _urllib_fetch(
        f"https://arctic-shift.photon-reddit.com/api/posts/ids?ids={post_id}",
        headers={"User-Agent": "BlueLodge/1.0", "Accept": "application/json"},
        timeout=6.0,
    )
    if as_status == 200 and as_body:
        try:
            as_data = json.loads(as_body).get("data") or []
            if as_data and isinstance(as_data[0], dict):
                p = as_data[0]
                op_title = p.get("title") or op_title
                op_author = p.get("author") or op_author
                op_score = p.get("score", op_score)
                op_num_comments = p.get("num_comments", op_num_comments)
                op_selftext = (p.get("selftext") or "").strip()
                op_ext_url = (p.get("url") or "").strip()
                if op_ext_url and any(x in op_ext_url.lower() for x in (".jpg", ".jpeg", ".png", ".gif", ".webp", "i.redd.it", "preview.redd.it")):
                    media_images.append(op_ext_url)
        except Exception:
            pass

    # 2. Fetch live comments + live upvote counts from /svc/shreddit/comments/
    sh_url = f"https://www.reddit.com/svc/shreddit/comments/r/{sub}/t3_{post_id}?render-mode=partial"
    sh_status, sh_html = _urllib_fetch(sh_url, headers=shreddit_hdrs, timeout=10.0)
    comments_list: list[dict[str, Any]] = []

    if sh_status == 200 and sh_html and "<shreddit-comment" in sh_html:
        if HAS_LXML:
            try:
                doc = lxml_html.fromstring(sh_html)
                tree_el = doc.xpath("//shreddit-comment-tree")
                if tree_el:
                    tc = tree_el[0].attrib.get("totalcomments")
                    if tc:
                        op_num_comments = tc
                for c_el in doc.xpath("//shreddit-comment")[:30]:
                    c_author = c_el.attrib.get("author") or "anon"
                    c_score_raw = c_el.attrib.get("score") or "0"
                    try:
                        c_score = int(c_score_raw)
                    except ValueError:
                        c_score = 0
                    c_depth = c_el.attrib.get("depth") or "0"
                    slot_divs = c_el.xpath(".//*[@slot='comment']")
                    if slot_divs:
                        c_text = "\n".join(line.strip() for line in slot_divs[0].itertext() if line.strip())
                    else:
                        c_text = ""
                    c_text = re.sub(r"\n{3,}", "\n\n", c_text).strip()
                    if c_text and c_author not in ("[deleted]", "AutoModerator"):
                        comments_list.append({
                            "author": c_author,
                            "score": c_score,
                            "depth": c_depth,
                            "body": c_text,
                        })
            except Exception:
                pass
        else:
            # Tier 2 stdlib regex fallback for <shreddit-comment>
            for m in re.finditer(
                r'<shreddit-comment\b([^>]*)>(.*?)</shreddit-comment>',
                sh_html,
                flags=re.DOTALL | re.IGNORECASE,
            ):
                attrs, inner = m.group(1), m.group(2)
                au_m = re.search(r'author="([^"]+)"', attrs)
                sc_m = re.search(r'score="([^"]+)"', attrs)
                slot_m = re.search(r'slot="comment"[^>]*>(.*?)</div>', inner, flags=re.DOTALL | re.IGNORECASE)
                c_txt = re.sub(r"<[^>]+>", " ", slot_m.group(1) if slot_m else inner)
                c_txt = html_mod.unescape(re.sub(r"\s+", " ", c_txt)).strip()
                if c_txt:
                    comments_list.append({
                        "author": au_m.group(1) if au_m else "anon",
                        "score": int(sc_m.group(1)) if (sc_m and sc_m.group(1).lstrip("-").isdigit()) else 0,
                        "depth": "0",
                        "body": c_txt,
                    })

    # Sort comments by score descending so top-upvoted reactions come first
    comments_list.sort(key=lambda x: x.get("score", 0), reverse=True)

    if not comments_list and not op_selftext and op_author == "unknown":
        return None

    sections = [
        f"# [{sub_name}] {op_title}",
        f"**Author**: u/{op_author} | **Post Upvotes**: {op_score} | **Total Comments**: {op_num_comments}",
    ]
    if op_ext_url and "reddit.com/r/" not in op_ext_url:
        sections.append(f"**Media / External Link**: {op_ext_url}")
    sections.append("\n## Original Post\n" + (op_selftext if op_selftext else f"(Link/Image Post: {op_ext_url or op_title})"))

    headings = [f"[H1] {op_title}", "[H2] Original Post"]
    if comments_list:
        top_n = comments_list[:20]
        sections.append(f"\n## Top Community Comments ({len(top_n)} sorted by upvotes)")
        headings.append(f"[H2] Top Community Comments ({len(top_n)})")
        for idx, c in enumerate(top_n, 1):
            sections.append(f"\n### Comment {idx} — u/{c['author']} ({c['score']} upvotes)\n{c['body']}")

    full_md = "\n".join(sections)
    return {
        "url": url,
        "title": f"[{sub_name}] {op_title}",
        "adapter": "adapter_reddit_shreddit",
        "word_count": len(full_md.split()),
        "section_map": headings,
        "links": [{"text": "Media/External Link", "url": op_ext_url}] if op_ext_url else [],
        "images": media_images[:15],
        "content": full_md,
        "blocked": False,
        "block_reason": "",
        "http_status": 200,
    }


def _extract_shreddit_subreddit(url: str, sub: str, sort: str = "hot") -> dict[str, Any] | None:
    """High-throughput (200 req/window) Subreddit listing extractor with live upvote counts and media URLs."""
    sub_name = f"r/{sub}"
    shreddit_hdrs = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36",
        "Accept": "text/vnd.reddit.partial+html, text/html;q=0.9",
        "Accept-Language": "en-US,en;q=0.9",
    }
    sort_clean = sort if sort in ("hot", "new", "top", "rising") else "hot"
    sh_url = f"https://www.reddit.com/svc/shreddit/community-more-posts/{sort_clean}/?t=WEEK&name={sub}"
    sh_status, sh_html = _urllib_fetch(sh_url, headers=shreddit_hdrs, timeout=10.0)
    if sh_status != 200 or not sh_html or "<shreddit-post" not in sh_html:
        return None

    posts_data: list[dict[str, Any]] = []
    media_images: list[str] = []
    out_links: list[dict[str, str]] = []

    if HAS_LXML:
        try:
            doc = lxml_html.fromstring(sh_html)
            for p_el in doc.xpath("//shreddit-post")[:25]:
                p_title = (p_el.attrib.get("post-title") or "").strip()
                p_author = (p_el.attrib.get("author") or "anon").strip()
                p_score = p_el.attrib.get("score") or "0"
                p_comments = p_el.attrib.get("comment-count") or "0"
                p_perm = p_el.attrib.get("permalink") or ""
                p_href = f"https://www.reddit.com{p_perm}" if p_perm.startswith("/") else p_perm
                p_media = (p_el.attrib.get("content-href") or "").strip()
                p_created = (p_el.attrib.get("created-timestamp") or "")[:16]
                tb_el = p_el.xpath(".//*[@slot='text-body']")
                p_body = ""
                if tb_el:
                    p_body = " ".join(x.strip() for x in tb_el[0].itertext() if x.strip())[:350]
                if p_media and any(x in p_media.lower() for x in (".jpg", ".jpeg", ".png", ".gif", ".webp", "i.redd.it", "preview.redd.it")):
                    if p_media not in media_images:
                        media_images.append(p_media)
                if p_title:
                    posts_data.append({
                        "title": p_title,
                        "author": p_author,
                        "score": p_score,
                        "comments": p_comments,
                        "url": p_href,
                        "media": p_media,
                        "created": p_created,
                        "body": p_body,
                    })
                    if p_href:
                        out_links.append({"text": f"[{p_score} pts] {p_title[:70]}", "url": p_href})
        except Exception:
            pass

    if not posts_data:
        return None

    sections = [f"# [{sub_name}] Subreddit Feed — {sort_clean.upper()} ({len(posts_data)} Posts)"]
    for idx, p in enumerate(posts_data, 1):
        lines = [
            f"\n### [{idx}] {p['title']}",
            f"- **Upvotes**: {p['score']} | **Comments**: {p['comments']} | **Author**: u/{p['author']} | **Posted**: {p['created']}",
            f"- **Thread URL**: {p['url']}",
        ]
        if p["media"] and p["media"] != p["url"]:
            lines.append(f"- **Media / Content URL**: {p['media']}")
        if p["body"]:
            lines.append(f"- **Excerpt**: {p['body']}")
        sections.append("\n".join(lines))

    full_md = "\n".join(sections)
    return {
        "url": url,
        "title": f"[{sub_name}] {sort_clean.title()} Posts",
        "adapter": "adapter_reddit_shreddit",
        "word_count": len(full_md.split()),
        "section_map": [f"[H1] {sub_name} {sort_clean.title()} Posts ({len(posts_data)})"],
        "links": out_links[:12],
        "images": media_images[:15],
        "content": full_md,
        "blocked": False,
        "block_reason": "",
        "http_status": 200,
    }


def adapter_reddit(url: str) -> dict[str, Any] | None:
    """Multi-channel Reddit scraper:
    1. Primary: /svc/shreddit/ partial HTML + Arctic Shift API (200 req/min, includes exact live upvote scores & media URLs)
    2. Secondary: PoshTracker Atom XML (.rss) + PoW session cookie jar
    3. Tertiary: challenge_solver.py reddit-json
    """
    parsed = urllib.parse.urlparse(url)
    clean_path = re.sub(r"/?\.(rss|json)$", "", parsed.path.rstrip("/")).rstrip("/")
    if not clean_path or clean_path == "":
        return None

    # Channel 1: High-throughput /svc/shreddit/ + Arctic Shift (includes live upvote counts on posts & comments)
    m_thread = re.match(r"^/r/([a-zA-Z0-9_]+)/comments/([a-z0-9]+)(?:/([^/]*))?", clean_path, re.IGNORECASE)
    if m_thread:
        sh_res = _extract_shreddit_thread(url, m_thread.group(1), m_thread.group(2), m_thread.group(3) or "")
        if sh_res and sh_res.get("word_count", 0) > 10:
            return sh_res
    else:
        m_sub = re.match(r"^/r/([a-zA-Z0-9_]+)(?:/(hot|new|top|rising))?$", clean_path, re.IGNORECASE)
        if m_sub:
            sh_sub = _extract_shreddit_subreddit(url, m_sub.group(1), (m_sub.group(2) or "hot").lower())
            if sh_sub and sh_sub.get("word_count", 0) > 10:
                return sh_sub

    # Channel 2: Atom XML (.rss) + PoW session cookie jar
    rss_url = f"https://www.reddit.com{clean_path}/.rss"
    html_url = f"https://www.reddit.com{clean_path}/"
    jar = _reddit_jar()

    status, _, raw_xml = http_fetch(rss_url, headers=REDDIT_FEED_HEADERS, cookie_jar=jar, timeout=10.0)
    if (status != 200 or "<?xml" not in raw_xml) and cs is not None:
        xml_via_cs = cs.fetch_reddit_rss(html_url)
        if xml_via_cs:
            status = 200
            raw_xml = xml_via_cs

    is_thread = "/comments/" in clean_path
    sub_match = re.search(r"/r/([a-zA-Z0-9_]+)", clean_path)
    sub_name = f"r/{sub_match.group(1)}" if sub_match else "Reddit"

    if status == 200 and raw_xml and "<?xml" in raw_xml:
        try:
            root = SafeET.fromstring(raw_xml)
            ns = {"atom": "http://www.w3.org/2005/Atom"}
            feed_title = root.findtext("atom:title", namespaces=ns) or sub_name
            entries = root.findall("atom:entry", ns)
            if entries:
                sections: list[str] = []
                out_links: list[dict[str, str]] = []
                headings: list[str] = []
                media_images: list[str] = []

                if is_thread:
                    op = entries[0]
                    op_title = op.findtext("atom:title", namespaces=ns) or feed_title
                    op_author = op.findtext("atom:author/atom:name", namespaces=ns) or "/u/unknown"
                    op_updated = op.findtext("atom:updated", namespaces=ns) or ""
                    op_html = op.findtext("atom:content", namespaces=ns) or ""
                    op_parser = StdlibPageParser(base_url=url, strip_nav=False)
                    op_parser.feed(op_html)
                    op_body = op_parser.get_markdown()
                    ext_match = re.search(r'href="([^"]+)"[^>]*>\[link\]<', op_html)
                    ext_url = html_mod.unescape(ext_match.group(1)) if ext_match else ""
                    for im in op_parser.images:
                        if im not in media_images:
                            media_images.append(im)
                    if ext_url and any(ext_url.lower().endswith(x) or x in ext_url.lower() for x in (".jpg", ".jpeg", ".png", ".gif", ".webp", "i.redd.it", "preview.redd.it")):
                        if ext_url not in media_images:
                            media_images.insert(0, ext_url)

                    sections.append(f"# [{sub_name}] {op_title}")
                    sections.append(f"**Author**: {op_author} | **Updated**: {op_updated}")
                    if ext_url and "reddit.com/r/" not in ext_url:
                        sections.append(f"**Media / External Link**: {ext_url}")
                    sections.append("\n## Original Post\n" + (op_body or op_title))
                    headings.append(f"[H1] {op_title}")
                    headings.append("[H2] Original Post")

                    comment_entries = entries[1:25]
                    if comment_entries:
                        sections.append(f"\n## Top Community Comments ({len(comment_entries)})")
                        headings.append(f"[H2] Top Community Comments ({len(comment_entries)})")
                        for idx, ce in enumerate(comment_entries, 1):
                            c_author = ce.findtext("atom:author/atom:name", namespaces=ns) or "/u/anon"
                            c_html = ce.findtext("atom:content", namespaces=ns) or ""
                            cp = StdlibPageParser(base_url=url, strip_nav=False)
                            cp.feed(c_html)
                            c_body = cp.get_markdown()
                            if c_body:
                                sections.append(f"\n### Comment {idx} by {c_author}\n{c_body}")
                else:
                    sections.append(f"# [{sub_name}] Subreddit Feed ({len(entries[:20])} Posts)")
                    headings.append(f"[H1] {sub_name} Top Posts")
                    for idx, pe in enumerate(entries[:20], 1):
                        p_title = pe.findtext("atom:title", namespaces=ns) or "Untitled"
                        p_author = pe.findtext("atom:author/atom:name", namespaces=ns) or "/u/anon"
                        p_updated = pe.findtext("atom:updated", namespaces=ns) or ""
                        p_link_el = pe.find("atom:link", ns)
                        p_href = p_link_el.attrib.get("href", "") if p_link_el is not None else ""
                        p_html = pe.findtext("atom:content", namespaces=ns) or ""
                        ext_m = re.search(r'href="([^"]+)"[^>]*>\[link\]<', p_html)
                        ext_u = html_mod.unescape(ext_m.group(1)) if ext_m else ""
                        pp = StdlibPageParser(base_url=url, strip_nav=False)
                        pp.feed(p_html)
                        for im in pp.images:
                            if im not in media_images:
                                media_images.append(im)
                        if ext_u and any(ext_u.lower().endswith(x) or x in ext_u.lower() for x in (".jpg", ".jpeg", ".png", ".gif", ".webp", "i.redd.it", "preview.redd.it")):
                            if ext_u not in media_images:
                                media_images.append(ext_u)
                        p_snip = pp.get_markdown()[:350]
                        media_line = f"\nMedia/External Link: {ext_u}" if (ext_u and "reddit.com/r/" not in ext_u) else ""
                        sections.append(f"\n### [{idx}] {p_title} (by {p_author}, {p_updated[:10]})\nThread URL: {p_href}{media_line}\n{p_snip}")
                        if p_href:
                            out_links.append({"text": p_title[:80], "url": p_href})

                full_md = "\n".join(sections)
                return {
                    "url": url,
                    "title": f"[{sub_name}] {feed_title}",
                    "adapter": "adapter_reddit_rss_atom",
                    "word_count": len(full_md.split()),
                    "section_map": headings,
                    "links": out_links[:12],
                    "images": media_images[:15],
                    "content": full_md,
                    "blocked": False,
                    "block_reason": "",
                    "http_status": 200,
                }
        except Exception:
            pass

    # Fallback to Reddit JSON via challenge_solver
    if cs is not None:
        j_raw = cs.fetch_reddit_json(f"https://www.reddit.com{clean_path}.json")
        if j_raw:
            try:
                j_data = json.loads(j_raw)
                if isinstance(j_data, list) and len(j_data) >= 2:
                    post = j_data[0]["data"]["children"][0]["data"]
                    title = post.get("title", "Reddit Thread")
                    author = post.get("author", "unknown")
                    score = post.get("score", 0)
                    selftext = post.get("selftext", "")
                    lines = [
                        f"# [{sub_name}] {title}",
                        f"By u/{author} | Score: {score}",
                        "\n## Original Post\n" + (selftext or post.get("url", "")),
                        "\n## Top Comments",
                    ]
                    for idx, c in enumerate(j_data[1].get("data", {}).get("children", [])[:20], 1):
                        cd = c.get("data", {})
                        cb = (cd.get("body") or "").strip()
                        if cb and cb not in ("[deleted]", "[removed]"):
                            lines.append(f"\n### Comment {idx} by u/{cd.get('author', 'anon')} ({cd.get('score', 0)} pts)\n{cb}")
                    md = "\n".join(lines)
                    return {
                        "url": url,
                        "title": f"[{sub_name}] {title}",
                        "adapter": "adapter_reddit_json",
                        "word_count": len(md.split()),
                        "section_map": [f"[H1] {title}", "[H2] Original Post", "[H2] Top Comments"],
                        "links": [],
                        "images": [],
                        "content": md,
                        "blocked": False,
                        "block_reason": "",
                        "http_status": 200,
                    }
            except Exception:
                pass
    return None


def adapter_mediawiki(url: str) -> dict[str, Any] | None:
    """Bypass Cloudflare HTML challenges on Fandom/Wiki.gg/Wikipedia via MediaWiki Action API."""
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc.lower()
    path = parsed.path

    m = re.match(r"^/(?:([a-z]{2,3})/)?wiki/(.+)$", path)
    if not m:
        return None
    lang_prefix = f"/{m.group(1)}" if m.group(1) else ""
    page_slug = urllib.parse.unquote(m.group(2))

    # Build candidate API endpoints (including Wowpedia mirror when warcraft.wiki.gg is CF-challenged)
    api_candidates: list[str] = []
    if "wikipedia.org" in host or "wikimedia.org" in host or "uesp.net" in host or "bulbagarden.net" in host:
        api_candidates.append(f"https://{host}/w/api.php")
    api_candidates.append(f"https://{host}{lang_prefix}/api.php")
    if "warcraft.wiki.gg" in host or "wowwiki" in host:
        api_candidates.append("https://wowpedia.fandom.com/api.php")

    for api_base in api_candidates:
        params = urllib.parse.urlencode({
            "action": "parse",
            "page": page_slug,
            "prop": "text|sections|displaytitle",
            "format": "json",
            "redirects": "1",
        })
        api_url = f"{api_base}?{params}"
        status, _, body = http_fetch(api_url, headers=FIREFOX_HEADERS, timeout=10.0)
        if status != 200 or not body:
            continue
        try:
            data = json.loads(body)
            parse_obj = data.get("parse")
            if not isinstance(parse_obj, dict):
                continue
            page_title = re.sub(r"<[^>]+>", "", parse_obj.get("title") or page_slug)
            html_content = (parse_obj.get("text") or {}).get("*", "")
            if not html_content:
                continue

            res = extract_html_and_map(html_content, url, adapter_name="adapter_mediawiki_api")
            res["title"] = page_title

            # Populate clean section map from MediaWiki's native sections array
            mw_sections = parse_obj.get("sections") or []
            if isinstance(mw_sections, list) and mw_sections:
                sec_list: list[str] = []
                for s in mw_sections[:20]:
                    if isinstance(s, dict):
                        lvl = s.get("toclevel", 1)
                        line_txt = re.sub(r"<[^>]+>", "", str(s.get("line", ""))).strip()
                        num = s.get("number", "")
                        if line_txt:
                            sec_list.append(f"[H{lvl + 1}] {num} {line_txt}".strip())
                if sec_list:
                    res["section_map"] = sec_list
            return res
        except Exception:
            continue
    return None


# ── S5: Snippet Rescue & Wayback Machine Fallback ────────────────────

def try_wayback_rescue(url: str) -> dict[str, Any] | None:
    """Query Internet Archive Wayback Machine for the closest unblocked snapshot."""
    avail_url = f"https://archive.org/wayback/available?url={urllib.parse.quote(url, safe='')}"
    status, _, body = http_fetch(avail_url, timeout=6.0)
    if status != 200 or not body:
        return None
    try:
        data = json.loads(body)
        snap = ((data.get("archived_snapshots") or {}).get("closest") or {})
        snap_url = snap.get("url") or ""
        if not snap_url:
            return None
        # Request id_ raw snapshot to avoid Wayback toolbar HTML injection
        raw_snap_url = re.sub(r"/web/(\d+)/", r"/web/\1id_/", snap_url.replace("http://", "https://"))
        s2, _, snap_html = http_fetch(raw_snap_url, timeout=10.0)
        if s2 == 200 and snap_html and len(snap_html) > 300:
            res = extract_html_and_map(snap_html, url, adapter_name="wayback_archive_rescue")
            if res.get("word_count", 0) >= 30:
                return res
    except Exception:
        pass
    return None


def try_snippet_rescue(url: str, block_reason: str = "BLOCKED") -> dict[str, Any] | None:
    """Rescue cached search snippet from session workspace or .george/search_results.md."""
    ws = os.environ.get("AGENT_TASK_WORKSPACE") or str(_george_dir() / "workspaces")
    ws_path = Path(ws)

    # 1. Check session search_snippets.jsonl and last_search.json
    candidates = [
        ws_path / "search_snippets.jsonl",
        ws_path / "last_search.json",
        _george_dir() / "workspaces" / "last_search.json",
    ]
    for cfile in candidates:
        if not cfile.exists():
            continue
        try:
            text = cfile.read_text(encoding="utf-8", errors="ignore")
            for line in reversed(text.splitlines()):
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                results = obj.get("results", [obj]) if isinstance(obj, dict) else []
                for item in results:
                    if isinstance(item, dict) and item.get("url") == url:
                        title = item.get("title") or "Cached Search Result"
                        snip = item.get("snippet") or item.get("content") or ""
                        if snip:
                            msg = (
                                f"[SYSTEM NOTE: Domain is grey-listed for direct curls ({block_reason}). "
                                f"Serving cached search engine snippet instead of hitting the live server.]\n\n{snip}"
                            )
                            return {
                                "url": url,
                                "title": title,
                                "adapter": "snippet_rescue",
                                "word_count": len(snip.split()),
                                "section_map": ["[H1] Cached Search Snippet (Snippet Rescue)"],
                                "links": [],
                                "images": [],
                                "content": msg,
                                "blocked": False,
                                "block_reason": block_reason,
                                "http_status": 200,
                            }
        except Exception:
            pass

    # 2. Check .george/search_results.md journal
    journal = _george_dir() / "search_results.md"
    if journal.exists():
        try:
            j_lines = journal.read_text(encoding="utf-8", errors="ignore").splitlines()
            for i, ln in enumerate(j_lines):
                if url in ln and not ln.strip().startswith("## Web Search:") and not ln.strip().startswith("URL:"):
                    title = j_lines[i - 1].strip() if i > 0 else "Cached Search Result"
                    snip = j_lines[i + 1].strip() if i + 1 < len(j_lines) else ""
                    if snip and not snip.startswith("Provider:") and not snip.startswith("Extractor:"):
                        msg = (
                            f"[SYSTEM NOTE: Domain is grey-listed for direct curls ({block_reason}). "
                            f"Serving cached search engine snippet instead of hitting the live server.]\n\n{snip}"
                        )
                        return {
                            "url": url,
                            "title": title,
                            "adapter": "snippet_rescue_journal",
                            "word_count": len(snip.split()),
                            "section_map": ["[H1] Cached Search Snippet (Journal Rescue)"],
                            "links": [],
                            "images": [],
                            "content": msg,
                            "blocked": False,
                            "block_reason": block_reason,
                            "http_status": 200,
                        }
        except Exception:
            pass
    return None


# ── Output Formatting & Telemetry ────────────────────────────────────

def format_page_overview_markdown(res: dict[str, Any], max_chars: int = 24000, include_overview: bool = True) -> str:
    """Format the structured Page Overview Header ('Site Map') + Markdown body."""
    content = (res.get("content") or "").strip()
    if not include_overview or content.startswith("[SYSTEM NOTE:"):
        return content[:max_chars]

    title = res.get("title") or res.get("url") or "Untitled Page"
    url = res.get("url") or ""
    adapter = res.get("adapter") or "web_scraper"
    words = res.get("word_count") or len(content.split())
    sections = res.get("section_map") or []
    links = res.get("links") or []

    header_lines = [
        "=== PAGE OVERVIEW ===",
        f"Title: {title}",
        f"URL: {url}",
        f"Extractor: {adapter} | Words: {words}",
    ]
    if sections:
        header_lines.append("Section Map (Outline):")
        for s in sections[:14]:
            header_lines.append(f"  - {s}")
    if links:
        header_lines.append("Key Outbound / Subpage Links:")
        for idx, lk in enumerate(links[:10], 1):
            header_lines.append(f"  {idx}. [{lk.get('text', 'Link')}]({lk.get('url', '')})")
    header_lines.append("=== CONTENT ===")

    header_block = "\n".join(header_lines) + "\n"
    budget = max(500, max_chars - len(header_block))
    if len(content) > budget:
        trimmed = content[:budget]
        if "\n" in trimmed:
            trimmed = trimmed.rsplit("\n", 1)[0]
        content = trimmed
    return header_block + content


def log_fetch_telemetry(res: dict[str, Any], elapsed_ms: int) -> None:
    """Write structured audit entry to .george/logs/web_fetch.jsonl."""
    try:
        log_dir = _george_dir() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        url = res.get("url") or ""
        host = urllib.parse.urlparse(url).netloc.lower()
        record = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "url": url,
            "domain": host,
            "adapter": res.get("adapter", "unknown"),
            "http_status": res.get("http_status", 0),
            "blocked": bool(res.get("blocked", False)),
            "block_reason": res.get("block_reason", ""),
            "word_count": int(res.get("word_count", 0)),
            "section_count": len(res.get("section_map") or []),
            "link_count": len(res.get("links") or []),
            "elapsed_ms": elapsed_ms,
        }
        with (log_dir / "web_fetch.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
    except Exception:
        pass


# ── Explicit 6-State Web Fetch FSM ───────────────────────────────────

def run_fetch_fsm(url: str) -> dict[str, Any]:
    """Execute the explicit 6-state Web Fetch & Page Mapper state machine."""
    t0 = time.monotonic()
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc.lower()

    # S1: URL_CLASSIFY_AND_ROUTE -> S2: DOMAIN_ADAPTER_FETCH
    if re.search(r"(^|\.)reddit\.com$|(^|\.)redd\.it$", host):
        rd = adapter_reddit(url)
        if rd and rd.get("word_count", 0) > 5:
            log_fetch_telemetry(rd, int((time.monotonic() - t0) * 1000))
            return rd

    if any(w in host for w in ("fandom.com", "wiki.gg", "wikipedia.org", "wikimedia.org", "uesp.net", "bulbagarden.net", "wowwiki")):
        mw = adapter_mediawiki(url)
        if mw and mw.get("word_count", 0) > 15:
            log_fetch_telemetry(mw, int((time.monotonic() - t0) * 1000))
            return mw

    # S3: STEALTH_HTTP_FETCH
    # Use crawler headers directly for sites known to use AWS WAF (e.g. wowhead.com)
    primary_hdrs = CRAWLER_HEADERS if "wowhead.com" in host else FIREFOX_HEADERS
    status, ctype, body = http_fetch(url, headers=primary_hdrs, timeout=12.0)
    block_reason = is_waf_or_block(status, body)

    # Retry once with Crawler UA if Firefox UA hit a WAF challenge or 403
    if block_reason and primary_hdrs is not CRAWLER_HEADERS:
        s2, ct2, b2 = http_fetch(url, headers=CRAWLER_HEADERS, timeout=10.0)
        if not is_waf_or_block(s2, b2) and len(b2) > 500:
            status, ctype, body, block_reason = s2, ct2, b2, ""

    # S4: EXTRACT_AND_MAP (when HTTP fetch succeeded)
    if not block_reason and body:
        if "application/json" in ctype or url.lower().endswith(".json"):
            try:
                pretty = json.dumps(json.loads(body), indent=2)[:20000]
            except Exception:
                pretty = body[:20000]
            res = {
                "url": url,
                "title": f"JSON Resource ({host})",
                "adapter": "json_passthrough",
                "word_count": len(pretty.split()),
                "section_map": ["[H1] JSON Payload"],
                "links": [],
                "images": [],
                "content": pretty,
                "blocked": False,
                "block_reason": "",
                "http_status": status or 200,
            }
            log_fetch_telemetry(res, int((time.monotonic() - t0) * 1000))
            return res

        res = extract_html_and_map(body, url, adapter_name="stealth_http")
        if res.get("word_count", 0) >= 15:
            log_fetch_telemetry(res, int((time.monotonic() - t0) * 1000))
            return res
        block_reason = "EMPTY_OR_BOILERPLATE_ONLY"

    # S5: SNIPPET_RESCUE & WAYBACK FALLBACK
    snip = try_snippet_rescue(url, block_reason=block_reason or f"HTTP_{status}")
    if snip:
        log_fetch_telemetry(snip, int((time.monotonic() - t0) * 1000))
        return snip

    wb = try_wayback_rescue(url)
    if wb:
        log_fetch_telemetry(wb, int((time.monotonic() - t0) * 1000))
        return wb

    # S6: Terminal Blocked State
    err_res = {
        "url": url,
        "title": "",
        "adapter": "blocked",
        "word_count": 0,
        "section_map": [],
        "links": [],
        "images": [],
        "content": "",
        "blocked": True,
        "block_reason": block_reason or f"HTTP_{status}",
        "http_status": status or 0,
    }
    log_fetch_telemetry(err_res, int((time.monotonic() - t0) * 1000))
    return err_res


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="George Explicit Web Scraper & Page Mapper FSM")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch", help="Fetch URL through the 6-state scraper FSM")
    p_fetch.add_argument("url", help="Target URL")
    p_fetch.add_argument("--format", choices=("markdown", "json"), default="markdown")
    p_fetch.add_argument("--max-chars", type=int, default=int(os.environ.get("WEB_CONTENT_MAX_CHARS", "24000")))
    p_fetch.add_argument("--no-overview", action="store_true")

    p_stdin = sub.add_parser("extract-stdin", help="Extract & map raw HTML from stdin")
    p_stdin.add_argument("--url", default="https://local.page/")
    p_stdin.add_argument("--format", choices=("markdown", "json"), default="markdown")
    p_stdin.add_argument("--max-chars", type=int, default=int(os.environ.get("WEB_CONTENT_MAX_CHARS", "24000")))
    p_stdin.add_argument("--no-overview", action="store_true")

    args = ap.parse_args(argv)

    if args.cmd == "extract-stdin":
        raw_html = sys.stdin.read()
        if not raw_html.strip():
            return 1
        res = extract_html_and_map(raw_html, args.url, adapter_name="stdin_html")
        if args.format == "json":
            print(json.dumps(res))
        else:
            out = format_page_overview_markdown(res, max_chars=args.max_chars, include_overview=not args.no_overview)
            if not out.strip():
                return 1
            print(out)
        return 0

    if args.cmd == "fetch":
        res = run_fetch_fsm(args.url)
        if args.format == "json":
            print(json.dumps(res))
            return 0 if not res.get("blocked") else 1
        if res.get("blocked") or not res.get("content"):
            return 1
        print(format_page_overview_markdown(res, max_chars=args.max_chars, include_overview=not args.no_overview))
        return 0

    return 2


if __name__ == "__main__":
    import signal
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
