#!/usr/bin/env python3
"""Sovereign Public APIs Catalog & FTS5 Discovery Engine for Blue Lodge.

Parses, indexes, and queries the public-apis/public-apis dataset (1,900+ curated REST endpoints)
using a local zero-latency SQLite FTS5 database in data/catalog/public_apis.sqlite.
Prioritizes keyless / zero-auth APIs for immediate autonomous consumption.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sqlite3
import sys
import urllib.request
from pathlib import Path
from typing import Any

logger = logging.getLogger("public_apis")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_DB = _REPO_ROOT / "data" / "catalog" / "public_apis.sqlite"
_DEFAULT_RAW_MD = _REPO_ROOT / "data" / "catalog" / "public_apis.md"
_UPSTREAM_URL = "https://raw.githubusercontent.com/public-apis/public-apis/master/README.md"


def get_db_path(custom_path: str | None = None) -> Path:
    if custom_path:
        return Path(custom_path).resolve()
    env_path = os.getenv("PUBLIC_APIS_DB")
    if env_path:
        return Path(env_path).resolve()
    return _DEFAULT_DB


def init_database(db_path: Path) -> sqlite3.Connection:
    """Initialize SQLite database with standard tables and FTS5 virtual table."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA synchronous = NORMAL;")

    with conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS apis (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                url TEXT NOT NULL,
                description TEXT NOT NULL,
                auth TEXT NOT NULL,
                https INTEGER NOT NULL DEFAULT 1,
                cors TEXT NOT NULL DEFAULT 'Unknown',
                category TEXT NOT NULL,
                is_keyless INTEGER NOT NULL DEFAULT 0,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            );
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_apis_category ON apis(category);")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_apis_is_keyless ON apis(is_keyless);")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_apis_name ON apis(name);")

        conn.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS apis_fts USING fts5(
                name,
                category,
                description,
                auth,
                content='apis',
                content_rowid='id'
            );
        """)
    return conn


def parse_markdown_catalog(content: str) -> list[dict[str, Any]]:
    """Parse raw markdown from public-apis README into structured records."""
    apis: list[dict[str, Any]] = []
    current_category = "General"

    # Regex patterns
    # ### Category Name
    cat_pattern = re.compile(r"^###\s+([A-Za-z0-9\s&/\-_]+)")
    # Table row: | [Name](url) | Description | Auth | HTTPS | CORS |
    row_pattern = re.compile(r"^\|\s*\[([^\]]+)\]\(([^)]+)\)\s*\|\s*([^|]+)\s*\|\s*([^|]*)\|\s*([^|]*)\|\s*([^|]*)\|")

    for line in content.splitlines():
        line = line.strip()
        cat_match = cat_pattern.match(line)
        if cat_match:
            cand = cat_match.group(1).strip()
            # Ignore banner headers
            if "APILayer" not in cand and "MCP" not in cand:
                current_category = cand
            continue

        row_match = row_pattern.match(line)
        if row_match:
            name = row_match.group(1).strip()
            url = row_match.group(2).strip()
            desc = row_match.group(3).strip()
            auth = row_match.group(4).strip().replace("`", "")
            https_str = row_match.group(5).strip().lower()
            cors = row_match.group(6).strip()

            if not auth:
                auth = "No"

            is_keyless = 1 if auth.lower() in ("no", "none", "", "null") else 0
            is_https = 1 if "yes" in https_str or "true" in https_str else 0

            apis.append({
                "name": name,
                "url": url,
                "description": desc,
                "auth": auth,
                "https": is_https,
                "cors": cors or "Unknown",
                "category": current_category,
                "is_keyless": is_keyless,
            })

    return apis


def sync_catalog(source_path_or_url: str | None = None, db_path: Path | None = None) -> int:
    """Synchronize catalog from local file or upstream GitHub URL into SQLite FTS5."""
    target_db = db_path or get_db_path()
    content = ""

    # Check local snapshot first or custom path
    if source_path_or_url and os.path.exists(source_path_or_url):
        with open(source_path_or_url, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    elif not source_path_or_url and _DEFAULT_RAW_MD.exists():
        with open(_DEFAULT_RAW_MD, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
    else:
        # Download from GitHub
        url = source_path_or_url or _UPSTREAM_URL
        logger.info("Downloading public-apis dataset from %s ...", url)
        req = urllib.request.Request(url, headers={"User-Agent": "BlueLodge-Sovereign-Agent/1.0"})
        with urllib.request.urlopen(req, timeout=15.0) as resp:
            content = resp.read().decode("utf-8", errors="ignore")

        # Cache snapshot to disk
        _DEFAULT_RAW_MD.parent.mkdir(parents=True, exist_ok=True)
        with open(_DEFAULT_RAW_MD, "w", encoding="utf-8") as f:
            f.write(content)

    records = parse_markdown_catalog(content)
    if not records:
        logger.warning("No API records parsed from markdown content.")
        return 0

    conn = init_database(target_db)
    with conn:
        conn.execute("DELETE FROM apis;")
        conn.execute("DELETE FROM apis_fts;")

        for rec in records:
            cur = conn.execute(
                """
                INSERT INTO apis (name, url, description, auth, https, cors, category, is_keyless)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                (
                    rec["name"],
                    rec["url"],
                    rec["description"],
                    rec["auth"],
                    rec["https"],
                    rec["cors"],
                    rec["category"],
                    rec["is_keyless"],
                ),
            )
            row_id = cur.lastrowid
            conn.execute(
                """
                INSERT INTO apis_fts (rowid, name, category, description, auth)
                VALUES (?, ?, ?, ?, ?);
                """,
                (row_id, rec["name"], rec["category"], rec["description"], rec["auth"]),
            )

    # Ensure symlink in .george/public_apis.db
    george_db = Path(os.environ.get("GEORGE_DIR") or _REPO_ROOT / ".george") / "public_apis.db"
    george_db.parent.mkdir(parents=True, exist_ok=True)
    if not george_db.exists() and target_db.exists():
        try:
            rel_target = os.path.relpath(target_db, george_db.parent)
            os.symlink(rel_target, george_db)
        except Exception:
            pass

    logger.info("Successfully indexed %d public APIs into %s", len(records), target_db)
    return len(records)


def search_apis(
    query: str,
    category: str | None = None,
    no_auth_only: bool = False,
    limit: int = 5,
    db_path: Path | None = None,
) -> list[dict[str, Any]]:
    """Query the public APIs catalog using FTS5 BM25 search.
    
    Prioritizes keyless / zero-auth APIs at the top of results.
    """
    target_db = db_path or get_db_path()
    if not target_db.exists():
        # Auto-initialize if database does not exist yet
        sync_catalog(db_path=target_db)

    conn = sqlite3.connect(str(target_db))
    conn.row_factory = sqlite3.Row

    clean_q = query.strip()
    results: list[dict[str, Any]] = []

    # Clean FTS tokens: remove punctuation that breaks FTS5 syntax
    tokens = re.findall(r"[A-Za-z0-9_]+", clean_q)
    fts_expr = " ".join(f'"{tok}"*' for tok in tokens) if tokens else ""

    where_clauses: list[str] = []
    params: list[Any] = []

    if category and category.lower() != "all":
        where_clauses.append("a.category LIKE ?")
        params.append(f"%{category}%")

    if no_auth_only:
        where_clauses.append("a.is_keyless = 1")

    if fts_expr:
        sql = f"""
            SELECT a.id, a.name, a.url, a.description, a.auth, a.https, a.cors, a.category, a.is_keyless,
                   bm25(apis_fts) as score
            FROM apis a
            JOIN apis_fts f ON a.id = f.rowid
            WHERE apis_fts MATCH ?
            {' AND ' + ' AND '.join(where_clauses) if where_clauses else ''}
            ORDER BY a.is_keyless DESC, score ASC
            LIMIT ?;
        """
        exec_params = [fts_expr] + params + [limit]
        try:
            cursor = conn.execute(sql, exec_params)
            for row in cursor.fetchall():
                results.append(dict(row))
        except sqlite3.OperationalError:
            results = []

        # Multi-term fallback: if strict AND matched nothing, try union OR
        if not results and len(tokens) > 1:
            fts_or_expr = " OR ".join(f'"{tok}"*' for tok in tokens)
            try:
                cursor = conn.execute(sql, [fts_or_expr] + params + [limit])
                for row in cursor.fetchall():
                    results.append(dict(row))
            except sqlite3.OperationalError:
                pass

    # Fallback to LIKE search if FTS returned nothing or query had no alphanumeric tokens
    if not results and clean_q:
        like_term = f"%{clean_q}%"
        fallback_where = ["(a.name LIKE ? OR a.description LIKE ? OR a.category LIKE ?)"]
        fallback_params = [like_term, like_term, like_term] + params

        if where_clauses:
            fallback_where.extend(where_clauses)

        sql = f"""
            SELECT a.id, a.name, a.url, a.description, a.auth, a.https, a.cors, a.category, a.is_keyless,
                   0.0 as score
            FROM apis a
            WHERE {' AND '.join(fallback_where)}
            ORDER BY a.is_keyless DESC, a.name ASC
            LIMIT ?;
        """
        cursor = conn.execute(sql, fallback_params + [limit])
        for row in cursor.fetchall():
            results.append(dict(row))

    return results


def list_categories(db_path: Path | None = None) -> list[dict[str, Any]]:
    """List all categories with total API counts and keyless API counts."""
    target_db = db_path or get_db_path()
    if not target_db.exists():
        sync_catalog(db_path=target_db)

    conn = sqlite3.connect(str(target_db))
    conn.row_factory = sqlite3.Row

    cursor = conn.execute("""
        SELECT category, COUNT(*) as total_count, SUM(is_keyless) as keyless_count
        FROM apis
        GROUP BY category
        ORDER BY category ASC;
    """)
    return [dict(row) for row in cursor.fetchall()]


def get_api_info(name: str, db_path: Path | None = None) -> dict[str, Any] | None:
    """Retrieve full metadata for a specific API by exact or fuzzy name."""
    target_db = db_path or get_db_path()
    if not target_db.exists():
        sync_catalog(db_path=target_db)

    conn = sqlite3.connect(str(target_db))
    conn.row_factory = sqlite3.Row

    cursor = conn.execute(
        "SELECT * FROM apis WHERE name = ? COLLATE NOCASE LIMIT 1;", (name.strip(),)
    )
    row = cursor.fetchone()
    if row:
        return dict(row)

    cursor = conn.execute(
        "SELECT * FROM apis WHERE name LIKE ? COLLATE NOCASE ORDER BY is_keyless DESC LIMIT 1;",
        (f"%{name.strip()}%",),
    )
    row = cursor.fetchone()
    return dict(row) if row else None


def format_search_results(results: list[dict[str, Any]], fmt: str = "text") -> str:
    """Format search results in text, markdown, or json format."""
    if fmt == "json":
        return json.dumps(results, indent=2)

    if not results:
        return "No public APIs found matching query."

    lines = []
    if fmt == "markdown":
        lines.append("| API | Category | Auth | HTTPS | CORS | Description |")
        lines.append("|:---|:---|:---|:---|:---|:---|")
        for r in results:
            auth_tag = "No Auth (Keyless)" if r.get("is_keyless") else f"`{r.get('auth')}`"
            https_tag = "Yes" if r.get("https") else "No"
            lines.append(
                f"| [{r.get('name')}]({r.get('url')}) | {r.get('category')} | {auth_tag} | {https_tag} | {r.get('cors')} | {r.get('description')} |"
            )
        return "\n".join(lines)

    # Standard clean CLI text output
    for i, r in enumerate(results, start=1):
        auth_tag = "[KEYLESS - No Auth]" if r.get("is_keyless") else f"[Auth: {r.get('auth')}]"
        lines.append(f"[{i}] {r.get('name')} {auth_tag} — {r.get('category')}")
        lines.append(f"    URL:         {r.get('url')}")
        lines.append(f"    Description: {r.get('description')}")
        lines.append(f"    Features:    HTTPS={'Yes' if r.get('https') else 'No'} | CORS={r.get('cors')}")
        lines.append("")
    return "\n".join(lines).rstrip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Blue Lodge Public APIs Discovery Engine")
    subparsers = parser.add_subparsers(dest="command", help="Subcommand")

    # search
    p_search = subparsers.add_parser("search", help="Search public APIs by keywords")
    p_search.add_argument("--query", "-q", required=True, help="Search query keywords")
    p_search.add_argument("--category", "-c", default=None, help="Filter by category")
    p_search.add_argument("--no-auth", action="store_true", default=False, help="Filter to keyless APIs only")
    p_search.add_argument("--limit", "-n", type=int, default=5, help="Max results")
    p_search.add_argument("--format", choices=["text", "markdown", "json"], default="text", help="Output format")

    # categories
    p_cat = subparsers.add_parser("categories", help="List all categories and API counts")
    p_cat.add_argument("--format", choices=["text", "json"], default="text", help="Output format")

    # info
    p_info = subparsers.add_parser("info", help="Get details for an API")
    p_info.add_argument("--name", required=True, help="API name")
    p_info.add_argument("--format", choices=["text", "json"], default="text", help="Output format")

    # sync
    p_sync = subparsers.add_parser("sync", help="Synchronize catalog from upstream")
    p_sync.add_argument("--source", default=None, help="Source path or URL")

    # stats
    subparsers.add_parser("stats", help="Show database statistics")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return 1

    if args.command == "sync":
        count = sync_catalog(args.source)
        print(f"Catalog synchronized: {count} APIs indexed.")
        return 0

    if args.command == "search":
        res = search_apis(
            query=args.query,
            category=args.category,
            no_auth_only=args.no_auth,
            limit=args.limit,
        )
        print(format_search_results(res, fmt=args.format))
        return 0

    if args.command == "categories":
        cats = list_categories()
        if args.format == "json":
            print(json.dumps(cats, indent=2))
        else:
            print(f"{'Category':<32} {'Total':<8} {'Keyless':<8}")
            print("─" * 48)
            for c in cats:
                print(f"{c['category']:<32} {c['total_count']:<8} {c['keyless_count']:<8}")
        return 0

    if args.command == "info":
        info = get_api_info(args.name)
        if not info:
            print(f"No API found matching '{args.name}'.")
            return 1
        if args.format == "json":
            print(json.dumps(info, indent=2))
        else:
            print(f"API:         {info['name']}")
            print(f"URL:         {info['url']}")
            print(f"Category:    {info['category']}")
            print(f"Auth:        {info['auth']} (Keyless: {'Yes' if info['is_keyless'] else 'No'})")
            print(f"HTTPS:       {'Yes' if info['https'] else 'No'}")
            print(f"CORS:        {info['cors']}")
            print(f"Description: {info['description']}")
        return 0

    if args.command == "stats":
        target_db = get_db_path()
        if not target_db.exists():
            print(f"Database does not exist at {target_db}.")
            return 1
        conn = sqlite3.connect(str(target_db))
        total = conn.execute("SELECT count(*) FROM apis;").fetchone()[0]
        keyless = conn.execute("SELECT count(*) FROM apis WHERE is_keyless = 1;").fetchone()[0]
        cats = conn.execute("SELECT count(distinct category) FROM apis;").fetchone()[0]
        db_size_kb = target_db.stat().st_size / 1024
        print(f"Database:     {target_db}")
        print(f"File Size:    {db_size_kb:.1f} KB")
        print(f"Total APIs:   {total}")
        print(f"Keyless APIs: {keyless} ({(keyless/total*100):.1f}%)")
        print(f"Categories:   {cats}")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
