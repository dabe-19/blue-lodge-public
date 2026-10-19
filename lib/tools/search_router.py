"""Unified search router for Blue Lodge (refinement P4).

One entry point for every web search George makes (web.sh web_search, research_sandbox,
osint_watcher, finance_*, reverse_image_search):

    cache -> SearXNG (keyless, local) -> Brave (BRAVE_SEARCH_API_KEY) -> Serper -> DuckDuckGo lite

* Cache: file LRU under $GEORGE_DIR/cache/search (TTL 24h default, 6h news, 7d science).
* SearXNG quality floor: >= SEARCH_MIN_RESULTS results from >= SEARCH_MIN_ENGINES engines,
  otherwise the next provider is tried and results are merged (SearXNG first).
* SearXNG `unresponsive_engines` are reported as DEGRADED (in the result, in
  $GEORGE_DIR/state/search_health.json, and as a throttled `search.engine_degraded` event).
* Serper is paid (finite credits): only for caller=operator, never from cron, budget-capped.
* Brave has a daily budget (free tier ~2000/month).
* Temporal rewrite: "today/breaking" -> time_range=day, "this week/latest" -> week, ...

Network endpoints are overridable via env for tests (SEARXNG_URL, BRAVE_API_BASE,
SERPER_API_BASE, DDG_LITE_URL). Stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

UA = "BlueLodge-Search-Router/1.0"
TTL_DEFAULT = 24 * 3600
TTL_NEWS = 6 * 3600
TTL_SCIENCE = 7 * 24 * 3600
VALID_CATEGORIES = {"general", "news", "science", "it", "images"}
VALID_TIME_RANGES = {"day", "week", "month", "year"}
VALID_CALLERS = {"operator", "agent", "cron", "discord", "eval", "test"}

# Keyless general engines.
# Note: `bing` is excluded because Microsoft Bing's bot-defense silently serves random
# decoy SERPs (including adult/porn results from its global query cache) instead of HTTP 429.
SEARXNG_GENERAL_ENGINES = "duckduckgo,startpage,zapmeta,mwmbl,marginalia,wikipedia"
SEARXNG_NEWS_ENGINES = "duckduckgo news,startpage news"

UNWANTED_DOMAINS = ("pinterest.", "facebook.com", "instagram.com", "tiktok.com",
                    "aliexpress.com", "temu.com", "pornhub.", "xhamster.", "xvideos.",
                    "xnxx.", "redtube.", "youporn.", "spankbang.", "footpornx.",
                    "ponx.video", "onlyfans.com", "chaturbate.", "stripchat.",
                    "brazzers.", "rule34.", "literotica.", "bdsmlr.", "clips4sale.")

ADULT_CONTENT_RE = re.compile(
    r"\b(porn|porno|xxx|fetish|onlyfans|nsfw|erotic|ponx|footjob|footpornx|"
    r"xhamster|pornhub|xvideos|xnxx|redtube|youporn|spankbang|chaturbate|"
    r"stripchat|brazzers|hentai|rule34|camgirl|sex\s+videos?|amateur\s+xxx)\b",
    re.I,
)


# ── paths / config ────────────────────────────────────────────────────
def _lodge_dir() -> Path:
    return Path(os.environ.get("LODGE_DIR") or Path(__file__).resolve().parents[2])


def _george_dir() -> Path:
    return Path(os.environ.get("GEORGE_DIR") or (_lodge_dir() / ".george"))


def _int_env(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _get_key(name: str) -> str:
    """Env first, then $GEORGE_DIR/keys.conf (KEY=value lines, same as api_get_key)."""
    val = os.environ.get(name, "").strip()
    if val:
        return val
    conf = _george_dir() / "keys.conf"
    try:
        for line in conf.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == name:
                return v.strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


def _http_json(url: str, headers: dict[str, str] | None = None, data: bytes | None = None,
               timeout: float = 8.0) -> Any:
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Accept": "application/json",
                                                         **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosec B310 - fixed schemes below
        return json.loads(resp.read().decode("utf-8", errors="ignore"))


def _http_text(url: str, timeout: float = 10.0) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)",
                                               "Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosec B310
        return resp.read().decode("utf-8", errors="ignore")


def _http_url_ok(url: str) -> bool:
    return url.startswith("http://") or url.startswith("https://")


# ── temporal rewrite ──────────────────────────────────────────────────
_TEMPORAL = [
    (re.compile(r"\b(today|tonight|breaking|right now|past 24 hours|last 24 hours)\b", re.I), "day"),
    (re.compile(r"\b(this week|past week|last week|latest|recent(ly)?|this weekend)\b", re.I), "week"),
    (re.compile(r"\b(this month|past month|last month)\b", re.I), "month"),
    (re.compile(r"\b(this year|past year)\b", re.I), "year"),
]


def temporal_rewrite(query: str, category: str, time_range: str | None) -> tuple[str, str, str | None]:
    """Map relative-time words to a SearXNG time_range; news-ish phrasing promotes general->news."""
    if time_range or category not in ("general", "news"):
        return query, category, time_range
    for rx, tr in _TEMPORAL:
        if rx.search(query):
            if tr == "day" and category == "general" and re.search(r"\b(breaking|news|headlines)\b", query, re.I):
                category = "news"
            return query, category, tr
    return query, category, time_range


# ── cache ─────────────────────────────────────────────────────────────
def _cache_dir() -> Path:
    return Path(os.environ.get("SEARCH_CACHE_DIR") or (_george_dir() / "cache" / "search"))


def _cache_ttl(category: str, time_range: str | None) -> int:
    if category == "news" or time_range == "day":
        return TTL_NEWS
    if category == "science":
        return TTL_SCIENCE
    return TTL_DEFAULT


def _cache_key(query: str, category: str, max_results: int, time_range: str | None, engines: str | None) -> str:
    norm = " ".join(query.lower().split())
    raw = json.dumps([norm, category, max_results, time_range or "", engines or ""])
    return hashlib.sha256(raw.encode()).hexdigest()[:32]


def cache_get(key: str, ttl: int) -> dict[str, Any] | None:
    if os.environ.get("SEARCH_NO_CACHE") == "1":
        return None
    f = _cache_dir() / f"{key}.json"
    try:
        st = f.stat()
        payload = json.loads(f.read_text(encoding="utf-8"))
        if time.time() - float(payload.get("stored_at", st.st_mtime)) > ttl:
            f.unlink(missing_ok=True)
            return None
        os.utime(f, None)  # LRU promote
        return payload
    except (OSError, ValueError):
        return None


def cache_put(key: str, payload: dict[str, Any]) -> None:
    if os.environ.get("SEARCH_NO_CACHE") == "1":
        return
    d = _cache_dir()
    try:
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / f".{key}.{os.getpid()}.tmp"
        tmp.write_text(json.dumps({**payload, "stored_at": time.time()}), encoding="utf-8")
        tmp.replace(d / f"{key}.json")
        cap = max(16, _int_env("SEARCH_CACHE_CAPACITY", 512))
        files = sorted(d.glob("*.json"), key=lambda p: p.stat().st_mtime)
        for old in files[: max(0, len(files) - cap)]:
            old.unlink(missing_ok=True)
    except OSError:
        pass


# ── budgets ───────────────────────────────────────────────────────────
def _budget_file() -> Path:
    return _george_dir() / "state" / "search_budget.json"


def _budget_load() -> dict[str, Any]:
    try:
        return json.loads(_budget_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _budget_save(b: dict[str, Any]) -> None:
    f = _budget_file()
    try:
        f.parent.mkdir(parents=True, exist_ok=True)
        tmp = f.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(b, indent=1), encoding="utf-8")
        tmp.replace(f)
    except OSError:
        pass


def budget_allows(provider: str) -> bool:
    b = _budget_load()
    today = time.strftime("%Y-%m-%d")
    used_today = int(b.get("daily", {}).get(today, {}).get(provider, 0))
    if provider == "brave":
        return used_today < _int_env("SEARCH_BRAVE_DAILY_BUDGET", 60)
    if provider == "serper":
        total = int(b.get("serper_total_used", 0))
        return (used_today < _int_env("SEARCH_SERPER_DAILY_BUDGET", 10)
                and total < _int_env("SEARCH_SERPER_TOTAL_BUDGET", 380))
    return True


def budget_charge(provider: str) -> None:
    b = _budget_load()
    today = time.strftime("%Y-%m-%d")
    daily = b.setdefault("daily", {})
    # keep 14 days of history
    for k in sorted(daily)[:-14]:
        daily.pop(k, None)
    day = daily.setdefault(today, {})
    day[provider] = int(day.get(provider, 0)) + 1
    if provider == "serper":
        b["serper_total_used"] = int(b.get("serper_total_used", 0)) + 1
    _budget_save(b)


# ── degraded engine reporting ─────────────────────────────────────────
def _report_degraded(degraded: list[dict[str, str]]) -> None:
    if not degraded:
        return
    f = _george_dir() / "state" / "search_health.json"
    now = time.time()
    try:
        state = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        state = {}
    engines = state.setdefault("engines", {})
    fresh = []
    for d in degraded:
        prev = engines.get(d["engine"], {})
        if now - float(prev.get("last_emit", 0)) > 600:
            fresh.append(d)
            prev["last_emit"] = now
        prev.update({"last_seen": now, "reason": d.get("reason", ""),
                     "count": int(prev.get("count", 0)) + 1})
        engines[d["engine"]] = prev
    state["updated"] = now
    try:
        f.parent.mkdir(parents=True, exist_ok=True)
        tmp = f.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(state, indent=1), encoding="utf-8")
        tmp.replace(f)
    except OSError:
        pass
    if fresh and os.environ.get("SEARCH_EMIT_EVENTS", "1") == "1":
        script = 'source "$1/lib/ipc/event_bus.sh" 2>/dev/null && event_bus_emit "$2" "$3" "$4"'
        try:
            subprocess.run(["bash", "-c", script, "_", str(_lodge_dir()), "search.engine_degraded",
                            json.dumps({"engines": fresh}), "search_router"],
                           check=False, timeout=5.0, capture_output=True)
        except (OSError, subprocess.SubprocessError):
            pass


# ── providers ─────────────────────────────────────────────────────────
def _norm(title: str, url: str, content: str, engine: str, provider: str, **extra: Any) -> dict[str, Any]:
    return {"title": html.unescape(title or "Untitled").strip(), "url": url.strip(),
            "content": html.unescape(re.sub(r"<[^>]+>", "", content or "")).strip(),
            "engine": engine, "provider": provider, **extra}


def _extract_site_exclusions(query: str) -> tuple[str, set[str]]:
    """Strip `-site:<domain>` tokens from upstream query string and return (clean_query, excluded_hosts).
    Sending 10+ `-site:` operators to upstream scrapers triggers bot tarpits/decoy SERPs and bloats
    query length past the 80-char distillation threshold."""
    excluded: set[str] = set()
    for m in re.finditer(r"(?:^|\s)-site:([^\s]+)", query, re.I):
        dom = m.group(1).strip().lower().rstrip(".")
        if dom:
            excluded.add(dom)
    cleaned = re.sub(r"(?:^|\s)-site:[^\s]+", " ", query, flags=re.I)
    cleaned = " ".join(cleaned.split())
    return cleaned, excluded


def _keep(url: str, title: str = "", content: str = "", excluded_hosts: set[str] | None = None) -> bool:
    if not _http_url_ok(url):
        return False
    host = urllib.parse.urlparse(url).netloc.lower()
    if any(d in host for d in UNWANTED_DOMAINS):
        return False
    if excluded_hosts and any(ex in host for ex in excluded_hosts):
        return False
    combined = f"{url} {title} {content}"
    if ADULT_CONTENT_RE.search(combined):
        return False
    return True


def _health_load() -> dict[str, Any]:
    try:
        return json.loads((_george_dir() / "state" / "search_health.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def healthy_engines(engine_csv: str) -> str:
    """Drop engines reported unresponsive within SEARCH_ENGINE_COOLDOWN seconds (default 30 min).
    Keeps at least two engines so a stale health file can never empty the request."""
    wanted = [e.strip() for e in engine_csv.split(",") if e.strip()]
    cooldown = _int_env("SEARCH_ENGINE_COOLDOWN", 1800)
    state = _health_load().get("engines", {})
    now = time.time()
    ok = [e for e in wanted if now - float(state.get(e, {}).get("last_seen", 0)) > cooldown]
    if len(ok) < 2:
        ok = wanted
    return ",".join(ok)


def provider_searxng(query: str, category: str, max_results: int, time_range: str | None,
                     engines: str | None, excluded_hosts: set[str] | None = None) -> tuple[list[dict[str, Any]], list[dict[str, str]], int]:
    """Returns (results, degraded_engines, distinct_engine_count)."""
    base = (os.environ.get("SEARXNG_URL") or "http://127.0.0.1:8081").rstrip("/")
    params: dict[str, Any] = {"q": query, "format": "json", "categories": category, "safesearch": 2}
    if engines:
        params["engines"] = engines
    elif category == "general" and not re.search(r"(?:^|\s)!\w", query):
        params["engines"] = healthy_engines(os.environ.get("SEARCH_SEARXNG_ENGINES", SEARXNG_GENERAL_ENGINES))
    elif category == "news":
        params["engines"] = healthy_engines(os.environ.get("SEARCH_SEARXNG_NEWS_ENGINES", SEARXNG_NEWS_ENGINES))
    if time_range:
        params["time_range"] = time_range
    data = _http_json(f"{base}/search?{urllib.parse.urlencode(params)}",
                      timeout=float(os.environ.get("SEARCH_SEARXNG_TIMEOUT", "9")))
    # SearXNG also lists *suspended* engines that were never queried (e.g. "google cse");
    # only engines we actually requested count as degraded for this search.
    requested = {e.strip() for e in str(params.get("engines", "")).split(",") if e.strip()}
    degraded = []
    for item in data.get("unresponsive_engines") or []:
        if isinstance(item, (list, tuple)) and item:
            name, reason = str(item[0]), (str(item[1]) if len(item) > 1 else "")
        elif isinstance(item, str):
            name, reason = item, ""
        else:
            continue
        if requested and name not in requested:
            continue
        degraded.append({"engine": name, "reason": reason})
    out, seen, engines_seen = [], set(), set()
    for it in data.get("results") or []:
        url = (it.get("url") or "").strip()
        if category == "images":
            url = url or it.get("img_src") or ""
        title_raw = it.get("title", "")
        content_raw = it.get("content", "")
        if not url or url in seen or not _keep(url, title_raw, content_raw, excluded_hosts):
            continue
        seen.add(url)
        engs = it.get("engines") or [it.get("engine") or "searxng"]
        engines_seen.update(engs)
        extra = {}
        if category == "images":
            extra = {"img_src": it.get("img_src") or "", "thumbnail": it.get("thumbnail_src") or it.get("img_src") or ""}
        if it.get("publishedDate"):
            extra["published"] = it.get("publishedDate")
        out.append(_norm(title_raw, url, content_raw, ",".join(engs), "searxng", **extra))
        if len(out) >= max_results:
            break
    return out, degraded, len(engines_seen)


def provider_brave(query: str, category: str, max_results: int, time_range: str | None,
                   excluded_hosts: set[str] | None = None) -> list[dict[str, Any]]:
    key = _get_key("BRAVE_SEARCH_API_KEY")
    if not key:
        raise LookupError("no BRAVE_SEARCH_API_KEY")
    base = (os.environ.get("BRAVE_API_BASE") or "https://api.search.brave.com/res/v1").rstrip("/")
    kind = "news" if category == "news" else "web"
    params: dict[str, Any] = {"q": query, "count": min(max(max_results, 1), 20), "safesearch": "strict"}
    fresh = {"day": "pd", "week": "pw", "month": "pm", "year": "py"}.get(time_range or "")
    if fresh:
        params["freshness"] = fresh
    data = _http_json(f"{base}/{kind}/search?{urllib.parse.urlencode(params)}",
                      headers={"X-Subscription-Token": key})
    items = (data.get("results") if kind == "news" else (data.get("web") or {}).get("results")) or []
    return [_norm(i.get("title", ""), i.get("url", ""), i.get("description", ""), "brave", "brave",
                  **({"published": i["age"]} if i.get("age") else {}))
            for i in items if _keep(i.get("url", ""), i.get("title", ""), i.get("description", ""), excluded_hosts)][:max_results]


def provider_serper(query: str, category: str, max_results: int, time_range: str | None,
                    excluded_hosts: set[str] | None = None) -> list[dict[str, Any]]:
    key = _get_key("SERPER_API_KEY") or _get_key("SERPER_API")
    if not key:
        raise LookupError("no SERPER_API_KEY")
    base = (os.environ.get("SERPER_API_BASE") or "https://google.serper.dev").rstrip("/")
    kind = "news" if category == "news" else "search"
    body: dict[str, Any] = {"q": query, "num": 10 if max_results <= 10 else 20}
    tbs = {"day": "qdr:d", "week": "qdr:w", "month": "qdr:m", "year": "qdr:y"}.get(time_range or "")
    if tbs:
        body["tbs"] = tbs
    data = _http_json(f"{base}/{kind}", headers={"X-API-KEY": key, "Content-Type": "application/json"},
                      data=json.dumps(body).encode())
    items = data.get("news" if kind == "news" else "organic") or []
    return [_norm(i.get("title", ""), i.get("link", ""), i.get("snippet", ""), "google", "serper")
            for i in items if _keep(i.get("link", ""), i.get("title", ""), i.get("snippet", ""), excluded_hosts)][:max_results]


_DDG_LINK = re.compile(r'<a[^>]+href="([^"]+)"[^>]*class=["\']result-link["\'][^>]*>(.*?)</a>'
                       r'|<a[^>]*class=["\']result-link["\'][^>]+href="([^"]+)"[^>]*>(.*?)</a>', re.S | re.I)
_DDG_SNIP = re.compile(r'<td[^>]*class=["\']result-snippet["\'][^>]*>(.*?)</td>', re.S | re.I)


def provider_ddg(query: str, category: str, max_results: int, time_range: str | None,
                 excluded_hosts: set[str] | None = None) -> list[dict[str, Any]]:
    base = os.environ.get("DDG_LITE_URL") or "https://lite.duckduckgo.com/lite/"
    params = {"q": query, "kp": "1"}
    df = {"day": "d", "week": "w", "month": "m", "year": "y"}.get(time_range or "")
    if df:
        params["df"] = df
    page = _http_text(f"{base}?{urllib.parse.urlencode(params)}")
    snippets = [re.sub(r"<[^>]+>", "", s).strip() for s in _DDG_SNIP.findall(page)]
    out = []
    for n, m in enumerate(_DDG_LINK.finditer(page)):
        href = m.group(1) or m.group(3) or ""
        title = re.sub(r"<[^>]+>", "", m.group(2) or m.group(4) or "")
        snip = snippets[n] if n < len(snippets) else ""
        if "uddg=" in href:
            href = urllib.parse.unquote(urllib.parse.parse_qs(urllib.parse.urlparse(href).query).get("uddg", [""])[0])
        if href.startswith("//"):
            href = "https:" + href
        if not _keep(href, title, snip, excluded_hosts) or "duckduckgo.com/y.js" in href:
            continue
        out.append(_norm(title, href, snip, "duckduckgo", "ddg"))
        if len(out) >= max_results:
            break
    return out


# ── router ────────────────────────────────────────────────────────────
def _resolve_caller(caller: str | None) -> str:
    if os.environ.get("LODGE_CRON_JOB"):
        return "cron"
    c = (caller or os.environ.get("SEARCH_CALLER") or "agent").lower()
    return c if c in VALID_CALLERS else "agent"


def _merge(primary: list[dict[str, Any]], extra: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    seen = {r["url"] for r in primary}
    merged = list(primary)
    for r in extra:
        if r["url"] not in seen:
            seen.add(r["url"])
            merged.append(r)
    return merged[:limit]


def search(query: str, category: str = "general", max_results: int = 8, time_range: str | None = None,
           engines: str | None = None, caller: str | None = None, use_cache: bool = True) -> dict[str, Any]:
    """Route a search. Always returns a dict; `results` may be empty (never raises on network errors)."""
    raw_query = " ".join((query or "").split())[:600]
    clean_query, excluded_hosts = _extract_site_exclusions(raw_query)
    query = clean_query[:400]
    category = {"code": "it", "academic": "science", "papers": "science"}.get(category, category)
    category = category if category in VALID_CATEGORIES else "general"
    max_results = max(1, min(int(max_results or 8), 30))
    time_range = time_range if time_range in VALID_TIME_RANGES else None
    if engines and not re.fullmatch(r"[A-Za-z0-9 ._,-]{1,200}", engines):
        engines = None
    caller = _resolve_caller(caller)
    q, category, time_range = temporal_rewrite(query, category, time_range)
    q = distill(q)

    out: dict[str, Any] = {"query": query, "category": category, "time_range": time_range,
                           "caller": caller, "provider": None, "providers_tried": [],
                           "degraded": [], "cached": False, "results": []}
    if not q:
        return out

    key = _cache_key(q, category, max_results, time_range, engines)
    if use_cache:
        hit = cache_get(key, _cache_ttl(category, time_range))
        if hit and hit.get("results"):
            filtered = [
                r for r in hit.get("results", [])
                if _keep(r.get("url", ""), r.get("title", ""), r.get("content", ""), excluded_hosts)
            ]
            if filtered:
                hit["results"] = filtered
                hit.update({"cached": True, "caller": caller})
                hit.pop("stored_at", None)
                return hit

    min_results = _int_env("SEARCH_MIN_RESULTS", 3)
    min_engines = _int_env("SEARCH_MIN_ENGINES", 2)
    results: list[dict[str, Any]] = []
    providers: list[str] = []

    def tried(name: str, status: str, count: int = 0) -> None:
        out["providers_tried"].append({"name": name, "status": status, "count": count})

    # 1. SearXNG (keyless)
    if os.environ.get("USE_SEARXNG", "1") != "0":
        try:
            sx, degraded, n_eng = provider_searxng(q, category, max_results, time_range, engines, excluded_hosts)
            out["degraded"] = degraded
            _report_degraded(degraded)
            floor_ok = len(sx) >= min(min_results, max_results) and (n_eng >= min_engines or category != "general" or bool(engines))
            tried("searxng", "ok" if floor_ok else ("thin" if sx else "empty"), len(sx))
            results = sx
            if sx:
                providers.append("searxng")
            if floor_ok:
                out.update(provider="searxng", results=results)
                cache_put(key, out)
                return out
        except (OSError, ValueError, urllib.error.URLError) as exc:
            tried("searxng", f"error: {type(exc).__name__}")
            out["degraded"] = [{"engine": "searxng", "reason": "unreachable"}]

    if category == "images":
        out.update(provider="+".join(providers) or None, results=results)
        return out

    # 2..4: Brave -> Serper (operator only, never cron) -> DDG
    chain = [("brave", provider_brave)]
    if caller == "operator" and os.environ.get("SEARCH_DISABLE_SERPER") != "1":
        chain.append(("serper", provider_serper))
    chain.append(("ddg", provider_ddg))
    for name, fn in chain:
        if name in ("brave", "serper") and not budget_allows(name):
            tried(name, "budget_exhausted")
            continue
        try:
            got = fn(q, category, max_results, time_range, excluded_hosts)
            if name in ("brave", "serper"):
                budget_charge(name)
            tried(name, "ok" if got else "empty", len(got))
            if got:
                results = _merge(results, got, max_results)
                providers.append(name)
                if len(results) >= min(min_results, max_results):
                    break
        except LookupError:
            tried(name, "no_key")
        except (OSError, ValueError, urllib.error.URLError) as exc:
            tried(name, f"error: {type(exc).__name__}")

    out.update(provider="+".join(providers) or None, results=results)
    if results:
        cache_put(key, out)
    return out


def results_list(query: str, category: str = "general", max_results: int = 8, time_range: str | None = None,
                 engines: str | None = None, caller: str | None = None) -> list[dict[str, Any]]:
    """Drop-in list-of-dicts for legacy callers (title/url/content/engine keys)."""
    return search(query, category, max_results, time_range, engines, caller)["results"]


def search_searxng_compat(query: str, categories: str = "general", max_results: int = 10,
                          time_range: str | None = None, engines: str | None = None,
                          **_ignored: Any) -> list[dict[str, Any]]:
    """Signature-compatible replacement for searxng_backend.search_searxng."""
    return results_list(query, categories, max_results, time_range, engines)


def distill(query: str) -> str:
    """Long natural-language prompts -> keyword query (reuses searxng_backend.distill_search_query)."""
    if len(query) <= 80 and not re.search(r"\b(please|search for|look up|investigate|find out)\b", query, re.I):
        return query
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from searxng_backend import distill_search_query  # noqa: E402

        return distill_search_query(query) or query
    except Exception:
        return query


def format_text(res: dict[str, Any]) -> str:
    lines = []
    for i, r in enumerate(res.get("results") or [], 1):
        lines.append(f"[{i}] {r['title']} [{r.get('engine') or r.get('provider')}]")
        lines.append(f"    {r['url']}")
        if r.get("content"):
            lines.append(f"    {r['content'][:400]}")
        lines.append("")
    meta = f"(search: provider={res.get('provider') or 'none'}"
    if res.get("cached"):
        meta += ", cached"
    if res.get("time_range"):
        meta += f", time_range={res['time_range']}"
    meta += ")"
    lines.append(meta)
    if res.get("degraded"):
        names = ",".join(d["engine"] for d in res["degraded"])
        lines.append(f"⚠ DEGRADED search engines: {names}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Blue Lodge unified search router")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search")
    s.add_argument("--query", required=True)
    s.add_argument("--category", default="general")
    s.add_argument("--max-results", type=int, default=8)
    s.add_argument("--time-range", default=None)
    s.add_argument("--engines", default=None)
    s.add_argument("--caller", default=None)
    s.add_argument("--no-cache", action="store_true")
    s.add_argument("--format", choices=["json", "text"], default="json")
    sub.add_parser("health")
    sub.add_parser("budget")
    a = ap.parse_args(argv)
    if a.cmd == "search":
        res = search(a.query, a.category, a.max_results, a.time_range, a.engines, a.caller, not a.no_cache)
        print(json.dumps(res) if a.format == "json" else format_text(res))
        return 0 if res["results"] else 1
    if a.cmd == "health":
        try:
            print((_george_dir() / "state" / "search_health.json").read_text(encoding="utf-8"))
        except OSError:
            print("{}")
        return 0
    if a.cmd == "budget":
        print(json.dumps(_budget_load(), indent=1))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
