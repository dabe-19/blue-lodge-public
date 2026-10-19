"""SearXNG Metasearch & Knowledge Discovery Engine for Blue Lodge.

Provides keyless, sovereign metasearch queries across Google, Bing, DuckDuckGo,
Brave, Wikipedia, GitHub, StackOverflow, arXiv, PubMed, and RSS feeds for George
without external API keys or rate limits.
"""

from __future__ import annotations

import argparse
import html
import json
import logging
import os
import re
import socket
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from typing import Any

logger = logging.getLogger("searxng_backend")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")


def get_searxng_base_url() -> str:
    """Resolve SearXNG base URL with automatic fallback between container and host network."""
    env_url = os.getenv("SEARXNG_URL")
    if env_url:
        return env_url.rstrip("/")

    # Check container DNS inside docker network
    try:
        socket.gethostbyname("george-searxng")
        return "http://george-searxng:8080"
    except Exception:
        pass

    try:
        socket.gethostbyname("searxng")
        return "http://searxng:8080"
    except Exception:
        pass

    # Host network fallback (default mapped port 8081)
    port = os.getenv("SEARXNG_PORT", "8081")
    return f"http://127.0.0.1:{port}"


UNWANTED_DOMAINS = {
    "pinterest.com",
    "facebook.com",
    "instagram.com",
    "tiktok.com",
    "youtube.com",
    "aliexpress.com",
    "temu.com",
    "pornhub.com",
    "xhamster.com",
    "xvideos.com",
    "xnxx.com",
    "redtube.com",
    "youporn.com",
    "spankbang.com",
    "footpornx.com",
    "ponx.video",
    "onlyfans.com",
    "chaturbate.com",
    "stripchat.com",
}

ADULT_CONTENT_RE = re.compile(
    r"\b(porn|porno|xxx|fetish|onlyfans|nsfw|erotic|ponx|footjob|footpornx|"
    r"xhamster|pornhub|xvideos|xnxx|redtube|youporn|spankbang|chaturbate|"
    r"stripchat|brazzers|hentai|rule34|camgirl|sex\s+videos?|amateur\s+xxx)\b",
    re.I,
)


def distill_search_query(query: str) -> str:
    """Sanitize and distill natural language prompts or overly long queries into dense keywords.
    Prevents search engines (Bing, Google, DuckDuckGo) from choking on parentheses, colons, or excessive length.
    """
    clean_q = query.strip()
    if not clean_q:
        return ""
    if clean_q.startswith("!"):
        return clean_q

    # Extract positive site/filetype operators; strip -site: operators so they don't trigger upstream bot tarpits
    operators = re.findall(r"(?<![-\w])(?:site:[^\s]+|filetype:[^\s]+)", clean_q)
    text = re.sub(r"(?:-site:[^\s]+|site:[^\s]+|filetype:[^\s]+)", " ", clean_q)

    # 1. Preserve ticker symbols inside parentheses before stripping: (UNH) -> UNH, (ELV) -> ELV
    text = re.sub(r"\(([A-Za-z0-9_-]{1,6})\)", r" \1 ", text)
    # 2. Strip all remaining parentheticals: (last 24-48 hours) -> ""
    text = re.sub(r"\([^)]*\)", " ", text)

    # 3. Strip prompt boilerplate / instructions
    prompt_patterns = [
        r"^(?:please\s+)?(?:run\s+(?:the\s+)?research_sandbox(?:\s+tool)?\s+(?:for\s+|on\s+)?|search\s+for\s+|find\s+(?:out\s+)?|investigate\s+|look\s+up\s+)",
        r"(?:cover\s+breaking\s+headlines|also\s+report\s+each\s+company|read\s+the\s+generated\s+dossier|send\s+a\s+concise\s+summary|prefixed\s+with\s+the\s+mention).*",
        r"\b(?:fresh\s+)?(?:daily\s+)?(?:news|updates)\s+(?:and\s+(?:breaking\s+)?(?:news|updates)\s+)?(?:for|on)?\b",
        r"\b(?:last\s+24-?48\s+hours|last\s+24\s+hours|today|recent|recently)\b",
        r"\b(?:major\s+US\s+|major\s+)?(?:health\s+insurance\s+providers|providers|companies)\s*:\s*",
    ]
    for p in prompt_patterns:
        text = re.sub(p, " ", text, flags=re.IGNORECASE)

    # 4. Strip punctuation
    text = re.sub(r"[\(\)\[\]\{\}\<\>\"\'`\/\\;:,?!]", " ", text)
    tokens = text.split()

    PROMPT_FILLER = {
        "fresh", "breaking", "daily", "major", "provider", "providers", "company", "companies",
        "update", "updates", "latest", "recent", "report", "overview", "summary"
    }

    STOPWORDS = {
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are",
        "as", "at", "be", "because", "been", "before", "being", "below", "between", "both", "but",
        "by", "could", "did", "do", "does", "doing", "down", "during", "each", "few", "for", "from",
        "further", "had", "has", "have", "having", "he", "her", "here", "hers", "herself", "him",
        "himself", "his", "how", "i", "if", "in", "into", "is", "it", "its", "itself", "just",
        "me", "more", "most", "my", "myself", "no", "nor", "not", "of", "off", "on", "once", "only",
        "or", "other", "ought", "our", "ours", "ourselves", "out", "over", "own", "same", "she",
        "should", "so", "some", "such", "than", "that", "the", "their", "theirs", "them", "themselves",
        "then", "there", "these", "they", "this", "those", "through", "to", "too", "under", "until",
        "up", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom",
        "why", "with", "would", "you", "your", "yours", "yourself", "yourselves"
    }

    # Separate high-value tokens (tickers, capitalized entities, domain terms) from low-value prompt filler
    high_value = []
    secondary = []
    for t in tokens:
        tl = t.lower()
        if tl in STOPWORDS:
            continue
        if tl in PROMPT_FILLER:
            secondary.append(t)
        else:
            high_value.append(t)

    selected = high_value[:10]
    for s in secondary:
        if len(selected) < 12 and s.lower() not in [x.lower() for x in selected]:
            selected.append(s)

    final_q = " ".join(selected)
    if operators:
        final_q = f"{final_q} {' '.join(operators[:2])}"
    return final_q.strip()


def search_searxng(
    query: str,
    categories: str = "general",
    max_results: int = 10,
    time_range: str | None = None,
    language: str | None = None,
    pageno: int = 1,
    timeout: float = 7.0,
    engines: str | None = None,
) -> list[dict[str, Any]]:
    """Execute multi-engine query against local SearXNG JSON API endpoint."""
    clean_q = distill_search_query(query)
    if not clean_q:
        return []

    base_url = get_searxng_base_url()
    params: dict[str, Any] = {
        "q": clean_q,
        "format": "json",
        "categories": categories,
        "pageno": pageno,
        "safesearch": 2,
    }
    has_bang = bool(re.search(r"(?:^|\s)![a-zA-Z0-9_-]+", clean_q))
    if engines:
        params["engines"] = engines
    elif not has_bang and categories == "general":
        params["engines"] = "duckduckgo,startpage,zapmeta,wikipedia"
    elif categories == "news":
        params["engines"] = "duckduckgo news,startpage news"
    elif categories in ("it", "code"):
        params["categories"] = "it"
    elif categories in ("science", "academic", "papers"):
        params["categories"] = "science"

    if time_range:
        params["time_range"] = time_range
    if language:
        params["language"] = language

    url = f"{base_url}/search?{urllib.parse.urlencode(params)}"
    results: list[dict[str, Any]] = []

    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "BlueLodge-Sovereign-Search/1.0",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                payload = json.loads(resp.read().decode("utf-8", errors="ignore"))
                raw_results = payload.get("results", [])

                seen_urls = set()
                for item in raw_results:
                    item_url = item.get("url", "").strip()
                    img_src = item.get("img_src") or item.get("thumbnail_src") or item.get("thumbnail") or ""

                    # For image search, allow results even if item_url is empty if img_src is present
                    if categories == "images" and img_src:
                        if not item_url:
                            item_url = img_src
                    elif not item_url or not item_url.startswith("http"):
                        continue

                    # Filter unwanted spam/junk/adult domains
                    try:
                        netloc = urllib.parse.urlparse(item_url).netloc.lower()
                        if any(d in netloc for d in UNWANTED_DOMAINS):
                            continue
                    except Exception:
                        pass

                    dedup_key = img_src if categories == "images" and img_src else item_url
                    if dedup_key in seen_urls:
                        continue
                    seen_urls.add(dedup_key)

                    title = html.unescape(item.get("title") or "Untitled").strip()
                    content = html.unescape(item.get("content") or "").strip()
                    if ADULT_CONTENT_RE.search(f"{item_url} {title} {content}"):
                        continue
                    engine = item.get("engine", "searxng")
                    score = float(item.get("score") or 1.0)

                    results.append({
                        "title": title,
                        "url": item_url,
                        "content": content,
                        "engine": engine,
                        "score": score,
                        "img_src": img_src,
                        "thumbnail": img_src,
                    })

                    if len(results) >= max_results:
                        break

                logger.debug("SearXNG returned %d vetted results for '%s'", len(results), clean_q)
                return results
    except Exception as exc:
        logger.warning("SearXNG query notice for '%s' against %s: %s", clean_q, base_url, exc)

    # Resilient fallback: Google News RSS / DuckDuckGo fallback
    if categories in ("general", "news"):
        logger.info("Engaging fallback web search for '%s'", clean_q)
        return fallback_web_search(clean_q, max_results=max_results)

    return []


def search_code(
    query: str,
    engines: str = "github,gitlab,stackoverflow,crates.io,pypi,npm,arch linux wiki,mdn,docker hub,huggingface",
    max_results: int = 10,
    timeout: float = 7.0,
) -> list[dict[str, Any]]:
    """Execute dedicated IT/developer search targeting code repos, packages, and technical docs."""
    return search_searxng(
        query=query,
        categories="it",
        engines=engines,
        max_results=max_results,
        timeout=timeout,
    )


def search_science(
    query: str,
    engines: str = "arxiv,pubmed,crossref,google scholar,semantic scholar,europepmc",
    time_range: str | None = None,
    max_results: int = 10,
    timeout: float = 8.0,
) -> list[dict[str, Any]]:
    """Execute dedicated scientific/academic search targeting papers, journals, and citations."""
    return search_searxng(
        query=query,
        categories="science",
        engines=engines,
        time_range=time_range,
        max_results=max_results,
        timeout=timeout,
    )


def search_news(
    query: str,
    time_range: str = "week",
    max_results: int = 8,
    timeout: float = 6.0,
) -> list[dict[str, Any]]:
    """Execute news search with recency filters across Google News, Bing News, and DuckDuckGo News."""
    return search_searxng(
        query=query,
        categories="news",
        time_range=time_range,
        max_results=max_results,
        timeout=timeout,
    )


def search_images(query: str, max_results: int = 12, timeout: float = 8.0) -> list[dict[str, Any]]:
    """Execute dedicated image search query across Google Images, Bing Images, and DuckDuckGo Images."""
    return search_searxng(
        query=query,
        categories="images",
        max_results=max_results,
        timeout=timeout,
        engines="google images,bing images,duckduckgo images",
    )


def comb_rss_feeds(query: str, max_results: int = 10, timeout: float = 5.0) -> list[dict[str, Any]]:
    """Comb Google News RSS feeds and return parsed, timestamped articles without rate limits."""
    results: list[dict[str, Any]] = []
    clean_q = query.strip()
    if not clean_q:
        return []

    safe_q = urllib.parse.quote(clean_q)
    news_url = f"https://news.google.com/rss/search?q={safe_q}&hl=en-US&gl=US&ceid=US:en"

    try:
        req = urllib.request.Request(
            news_url,
            headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            xml_data = resp.read()
            root = ET.fromstring(xml_data)
            for item in root.findall(".//item")[:max_results]:
                t = item.find("title").text if item.find("title") is not None else ""
                l = item.find("link").text if item.find("link") is not None else ""
                desc = item.find("description").text if item.find("description") is not None else ""
                pub_date = item.find("pubDate").text if item.find("pubDate") is not None else ""
                source = item.find("source").text if item.find("source") is not None else "Google News RSS"

                if t and l:
                    clean_desc = html.unescape(re.sub(r"<[^>]+>", " ", desc or "").strip())
                    results.append({
                        "title": t.strip(),
                        "url": l.strip(),
                        "content": clean_desc,
                        "engine": f"rss:{source.lower()}",
                        "score": 1.0,
                        "published": pub_date,
                    })
    except Exception as exc:
        logger.debug("RSS feed comb notice for '%s': %s", clean_q, exc)

    return results


def search_arxiv(
    query: str,
    max_results: int = 10,
    sort_by: str = "relevance",
    timeout: float = 10.0,
) -> list[dict[str, Any]]:
    """Execute direct scientific research search against the official arXiv Atom API.

    Extracts paper title, abstract, published date, authors, arXiv identifier, and PDF link.
    Falls back gracefully to SearXNG science search if arXiv API is unreachable.
    """
    clean_q = query.strip()
    if not clean_q:
        return []

    # Check persistent SQLite cache first
    arxiv_cache = None
    try:
        from lib.tools.arxiv_cache import get_arxiv_cache
        arxiv_cache = get_arxiv_cache()
    except Exception:
        try:
            from arxiv_cache import get_arxiv_cache
            arxiv_cache = get_arxiv_cache()
        except Exception:
            arxiv_cache = None

    if arxiv_cache:
        cached_res = arxiv_cache.get_search(clean_q, max_results=max_results, sort_by=sort_by)
        if cached_res is not None:
            logger.debug("Cache hit for arXiv search query: %s", clean_q)
            return cached_res

    results: list[dict[str, Any]] = []
    safe_q = urllib.parse.quote(clean_q)
    arxiv_url = f"https://export.arxiv.org/api/query?search_query=all:{safe_q}&start=0&max_results={max_results}&sortBy={sort_by}"

    try:
        req = urllib.request.Request(
            arxiv_url,
            headers={"User-Agent": "GeorgeResearchBot/1.0 (academic research)"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            xml_data = resp.read()
            root = ET.fromstring(xml_data)
            ns = {"atom": "http://www.w3.org/2005/Atom"}
            for entry in root.findall("atom:entry", ns):
                title_elem = entry.find("atom:title", ns)
                id_elem = entry.find("atom:id", ns)
                summary_elem = entry.find("atom:summary", ns)
                published_elem = entry.find("atom:published", ns)

                title = title_elem.text.strip().replace("\n", " ") if title_elem is not None and title_elem.text else "Untitled"
                entry_id = id_elem.text.strip() if id_elem is not None and id_elem.text else ""
                summary = summary_elem.text.strip().replace("\n", " ") if summary_elem is not None and summary_elem.text else ""
                published = published_elem.text[:10] if published_elem is not None and published_elem.text else ""

                authors = []
                for a in entry.findall("atom:author", ns):
                    name_elem = a.find("atom:name", ns)
                    if name_elem is not None and name_elem.text:
                        authors.append(name_elem.text.strip())

                pdf_url = ""
                if "arxiv.org/abs/" in entry_id:
                    pdf_url = entry_id.replace("/abs/", "/pdf/") + ".pdf"

                results.append({
                    "title": title,
                    "url": entry_id,
                    "pdf_url": pdf_url,
                    "arxiv_id": entry_id.split("/abs/")[-1] if "/abs/" in entry_id else entry_id,
                    "content": summary,
                    "authors": authors,
                    "published": published,
                    "engine": "arxiv",
                    "score": 1.0,
                })
        if results and arxiv_cache:
            arxiv_cache.set_search(clean_q, results, max_results=max_results, sort_by=sort_by)
    except Exception as exc:
        if arxiv_cache:
            stale = arxiv_cache.get_search(clean_q, max_results=max_results, sort_by=sort_by, max_age_days=365.0)
            if stale:
                logger.info("Serving stale cached arXiv search results for '%s' following error: %s", clean_q, exc)
                return stale
        logger.warning("Direct arXiv API search failed (%s), falling back to SearXNG science search", exc)
        fallback = search_science(query=clean_q, engines="arxiv", max_results=max_results, timeout=timeout)
        if fallback:
            if arxiv_cache:
                arxiv_cache.set_search(clean_q, fallback, max_results=max_results, sort_by=sort_by)
            return fallback

    return results


def search_hn(
    query: str,
    max_results: int = 10,
    timeout: float = 8.0,
) -> list[dict[str, Any]]:
    """Execute practitioner discussion search on Hacker News via the Algolia API.

    Safely handles empty responses and falls back to SearXNG if the endpoint is blocked.
    """
    clean_q = query.strip()
    if not clean_q:
        return []

    results: list[dict[str, Any]] = []
    safe_q = urllib.parse.quote(clean_q)
    hn_url = f"https://hn.algolia.com/api/v1/search?query={safe_q}&tags=story&hitsPerPage={max_results}"

    try:
        req = urllib.request.Request(
            hn_url,
            headers={"User-Agent": "GeorgeResearchBot/1.0 (HN search)"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw_body = resp.read().decode("utf-8", errors="ignore")
            data = json.loads(raw_body)
            hits = data.get("hits", [])
            for hit in hits:
                title = hit.get("title") or hit.get("story_title") or "Untitled Story"
                url = hit.get("url")
                obj_id = hit.get("objectID", "")
                hn_item_url = f"https://news.ycombinator.com/item?id={obj_id}" if obj_id else ""
                if not url:
                    url = hn_item_url

                points = hit.get("points", 0)
                comments = hit.get("num_comments", 0)
                author = hit.get("author", "unknown")
                created_at = (hit.get("created_at") or "")[:10]

                content = f"Points: {points} | Comments: {comments} | Author: {author} | Discussion: {hn_item_url}"
                results.append({
                    "title": title,
                    "url": url,
                    "discussion_url": hn_item_url,
                    "content": content,
                    "points": points,
                    "num_comments": comments,
                    "author": author,
                    "published": created_at,
                    "engine": "hackernews",
                    "score": 1.0,
                })
    except Exception as exc:
        logger.warning("Hacker News Algolia search failed (%s), falling back to SearXNG", exc)
        fallback = search_searxng(query=f"site:news.ycombinator.com {clean_q}", max_results=max_results, timeout=timeout)
        if fallback:
            return fallback

    return results


def fallback_web_search(query: str, max_results: int = 5) -> list[dict[str, Any]]:
    """Fallback search using Google News RSS when SearXNG container is unavailable."""
    return comb_rss_feeds(query, max_results=max_results)


def get_available_engines(category: str | None = None) -> list[dict[str, Any]]:
    """Fetch active engines, shortcuts, and categories from SearXNG /config endpoint."""
    base_url = get_searxng_base_url()
    try:
        req = urllib.request.Request(f"{base_url}/config", headers={"User-Agent": "BlueLodge-Sovereign-Search/1.0"})
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                engines = data.get("engines", [])
                out = []
                for e in engines:
                    cats = e.get("categories", [])
                    if category and category not in cats:
                        continue
                    out.append({
                        "name": e.get("name"),
                        "shortcut": e.get("shortcut"),
                        "categories": cats,
                        "disabled": e.get("disabled", False),
                    })
                return out
    except Exception as e:
        logger.debug("Failed to query SearXNG config: %s", e)
    return []


def check_searxng_health() -> dict[str, Any]:
    """Check health and probe status of SearXNG instance."""
    base_url = get_searxng_base_url()
    probe_url = f"{base_url}/search?q=test&format=json"
    try:
        req = urllib.request.Request(probe_url, headers={"User-Agent": "BlueLodge-HealthCheck/1.0"})
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                res_count = len(data.get("results", []))
                return {
                    "status": "healthy",
                    "base_url": base_url,
                    "results_count": res_count,
                    "engines_operational": True,
                }
    except Exception as e:
        return {
            "status": "unreachable",
            "base_url": base_url,
            "error": str(e),
            "engines_operational": False,
        }
    return {"status": "error", "base_url": base_url, "engines_operational": False}


def main():
    parser = argparse.ArgumentParser(description="SearXNG Metasearch & Knowledge Discovery Engine for Blue Lodge")
    subparsers = parser.add_subparsers(dest="command", help="Subcommand to execute")

    # Search
    search_parser = subparsers.add_parser("search", help="Execute general or category search")
    search_parser.add_argument("--query", "-q", required=True, help="Search query")
    search_parser.add_argument("--category", "-c", default="general", choices=["general", "it", "science", "news", "images", "files", "social media"])
    search_parser.add_argument("--engines", "-e", default=None, help="Comma-separated engines to query")
    search_parser.add_argument("--max-results", "-m", type=int, default=8, help="Max results")
    search_parser.add_argument("--time-range", "-t", default=None, choices=["day", "week", "month", "year"])
    search_parser.add_argument("--language", "-l", default=None, help="Language code (e.g. en)")
    search_parser.add_argument("--page", "-p", type=int, default=1, help="Page number")
    search_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # Code / IT
    code_parser = subparsers.add_parser("code", help="Execute IT/developer search (GitHub, StackOverflow, crates, pypi)")
    code_parser.add_argument("--query", "-q", required=True, help="Code / IT search query")
    code_parser.add_argument("--engines", "-e", default="github,gitlab,stackoverflow,crates.io,pypi,npm,arch linux wiki,mdn,docker hub,huggingface")
    code_parser.add_argument("--max-results", "-m", type=int, default=8, help="Max results")
    code_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # Science / Papers
    science_parser = subparsers.add_parser("science", help="Execute scientific paper search (arXiv, PubMed, Crossref)")
    science_parser.add_argument("--query", "-q", required=True, help="Research / paper search query")
    science_parser.add_argument("--engines", "-e", default="arxiv,pubmed,crossref,google scholar,semantic scholar,europepmc")
    science_parser.add_argument("--time-range", "-t", default=None, choices=["day", "week", "month", "year"])
    science_parser.add_argument("--max-results", "-m", type=int, default=8, help="Max results")
    science_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # arXiv Direct Atom API
    arxiv_parser = subparsers.add_parser("arxiv", help="Execute primary arXiv preprint search")
    arxiv_parser.add_argument("--query", "-q", required=True, help="arXiv search query")
    arxiv_parser.add_argument("--max-results", "-m", type=int, default=10, help="Max results")
    arxiv_parser.add_argument("--sort-by", "-s", default="relevance", choices=["relevance", "submittedDate", "lastUpdatedDate"])
    arxiv_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # Hacker News Discussions
    hn_parser = subparsers.add_parser("hn", help="Execute Hacker News discussion search")
    hn_parser.add_argument("--query", "-q", required=True, help="HN search query")
    hn_parser.add_argument("--max-results", "-m", type=int, default=10, help="Max results")
    hn_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # News
    news_parser = subparsers.add_parser("news", help="Execute news category search")
    news_parser.add_argument("--query", "-q", required=True, help="News search query")
    news_parser.add_argument("--time-range", "-t", default="week", choices=["day", "week", "month"])
    news_parser.add_argument("--max-results", "-m", type=int, default=8, help="Max results")
    news_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # Images
    img_parser = subparsers.add_parser("images", help="Execute image search")
    img_parser.add_argument("--query", "-q", required=True, help="Image search query")
    img_parser.add_argument("--max-results", "-m", type=int, default=10, help="Max image results")
    img_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # RSS
    rss_parser = subparsers.add_parser("rss", help="Comb RSS feeds for breaking news")
    rss_parser.add_argument("--query", "-q", required=True, help="News query for RSS feed")
    rss_parser.add_argument("--max-results", "-m", type=int, default=8, help="Max articles")
    rss_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # Engines
    engines_parser = subparsers.add_parser("engines", help="List active SearXNG engines and shortcuts")
    engines_parser.add_argument("--category", "-c", default=None, help="Filter by category (it, science, general)")
    engines_parser.add_argument("--format", "-f", default="text", choices=["text", "json", "markdown"])

    # Health
    subparsers.add_parser("health", help="Check SearXNG container status")

    args = parser.parse_args()

    if not args.command or args.command == "health":
        h = check_searxng_health()
        print(json.dumps(h, indent=2))
        return

    if args.command == "engines":
        engines = get_available_engines(args.category)
        if args.format == "json":
            print(json.dumps(engines, indent=2))
        elif args.format == "markdown":
            print(f"# Active SearXNG Engines ({len(engines)} total)\n")
            print("| Name | Shortcut | Categories |")
            print("| :--- | :--- | :--- |")
            for e in engines:
                print(f"| {e['name']} | `!{e['shortcut']}` | {', '.join(e['categories'])} |")
        else:
            for e in engines:
                print(f"- {e['name']} (!{e['shortcut']}) [{', '.join(e['categories'])}]")
        return

    if args.command == "search":
        res = search_searxng(
            query=args.query,
            categories=args.category,
            engines=args.engines,
            max_results=args.max_results,
            time_range=args.time_range,
            language=args.language,
            pageno=args.page,
        )
    elif args.command == "code":
        res = search_code(
            query=args.query,
            engines=args.engines,
            max_results=args.max_results,
        )
    elif args.command == "science":
        res = search_science(
            query=args.query,
            engines=args.engines,
            time_range=args.time_range,
            max_results=args.max_results,
        )
    elif args.command == "arxiv":
        res = search_arxiv(
            query=args.query,
            max_results=args.max_results,
            sort_by=getattr(args, "sort_by", "relevance"),
        )
    elif args.command == "hn":
        res = search_hn(
            query=args.query,
            max_results=args.max_results,
        )
    elif args.command == "news":
        res = search_news(
            query=args.query,
            time_range=args.time_range,
            max_results=args.max_results,
        )
    elif args.command == "images":
        res = search_images(query=args.query, max_results=args.max_results)
    elif args.command == "rss":
        res = comb_rss_feeds(query=args.query, max_results=args.max_results)
    else:
        res = []

    if args.format == "json":
        print(json.dumps(res, indent=2))
    elif args.format == "markdown":
        query_str = getattr(args, 'query', '')
        print(f"### 🔍 Search Results: `{query_str}` ({len(res)} hits)\n")
        for i, item in enumerate(res, 1):
            engine = item.get('engine', 'searxng')
            print(f"<details>")
            print(f"<summary><b>{i}. {item['title']}</b> <code>[{engine}]</code></summary>\n")
            print(f"- **URL**: [{item['url']}]({item['url']})")
            if item.get("pdf_url"):
                print(f"- **PDF**: [{item['pdf_url']}]({item['pdf_url']})")
            if item.get("discussion_url"):
                print(f"- **Discussion**: [{item['discussion_url']}]({item['discussion_url']})")
            if item.get("authors"):
                print(f"- **Authors**: {', '.join(item['authors'][:5])}")
            if item.get("published"):
                print(f"- **Published**: {item['published']}")
            if item.get("img_src"):
                print(f"- **Image**: [Direct Link]({item['img_src']})")
            if item.get("content"):
                print(f"- **Snippet**: {item['content']}")
            print("</details>\n")
    else:
        is_tty = sys.stdout.isatty() and not os.getenv("NO_COLOR")
        C_GOLD = "\033[38;5;220m" if is_tty else ""
        C_CYAN = "\033[38;5;117m" if is_tty else ""
        C_BLUE = "\033[38;5;75m" if is_tty else ""
        C_WHITE = "\033[1;37m" if is_tty else ""
        C_DIM = "\033[38;5;245m" if is_tty else ""
        C_RESET = "\033[0m" if is_tty else ""

        for i, item in enumerate(res, 1):
            engine = item.get('engine', 'searxng')
            print(f" {C_GOLD}[ {i} ]{C_RESET} {C_WHITE}{item['title']}{C_RESET} {C_CYAN}[{engine}]{C_RESET}")
            print(f"       {C_BLUE}{item['url']}{C_RESET}")
            if item.get("content"):
                snippet = item['content'].strip()
                if len(snippet) > 220:
                    snippet = snippet[:220] + "..."
                print(f"       {C_DIM}{snippet}{C_RESET}")
            print()


if __name__ == "__main__":
    main()
