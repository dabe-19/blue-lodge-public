#!/usr/bin/env python3
"""Persistent SQLite cache for direct arXiv Atom queries and paper identifiers.

Eliminates redundant network round-trips and HTTP 429 rate-limit fallback warnings
by caching query search results and per-paper metadata locally.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
import time
from typing import Any, Optional

logger = logging.getLogger("arxiv_cache")


def get_default_db_path() -> str:
    """Return default path to .george/cache/arxiv_queries.sqlite."""
    custom = os.environ.get("ARXIV_CACHE_DB")
    if custom:
        return custom
    lodge_dir = os.environ.get("LODGE_DIR", os.path.expanduser("~/blue-lodge"))
    george_dir = os.environ.get("GEORGE_DIR", os.path.join(lodge_dir, ".george"))
    cache_dir = os.path.join(george_dir, "cache")
    return os.path.join(cache_dir, "arxiv_queries.sqlite")


def normalize_arxiv_id(raw_id: str) -> str:
    """Normalize arXiv identifier (remove URL prefixes and trailing version suffixes)."""
    cleaned = raw_id.strip()
    if "/abs/" in cleaned:
        cleaned = cleaned.split("/abs/")[-1]
    elif "/pdf/" in cleaned:
        cleaned = cleaned.split("/pdf/")[-1].replace(".pdf", "")
    # Remove version suffix e.g. 2307.08691v2 -> 2307.08691
    return re.sub(r"v[0-9]+$", "", cleaned)


def make_search_key(query: str, max_results: int = 10, sort_by: str = "relevance") -> str:
    """Produce deterministic key for search query parameters."""
    norm_q = re.sub(r"\s+", " ", query.strip().lower())
    return f"{norm_q}::max={max_results}::sort={sort_by}"


class ArxivCacheDB:
    """Thread-safe SQLite connection and cache manager."""

    def __init__(self, db_path: Optional[str] = None):
        self.db_path = db_path or get_default_db_path()
        self._initialized = False
        self._ensure_init()

    def _get_connection(self) -> sqlite3.Connection:
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        conn = sqlite3.connect(self.db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row
        return conn

    def _ensure_init(self) -> None:
        if self._initialized:
            return
        try:
            with self._get_connection() as conn:
                conn.execute("PRAGMA journal_mode=WAL;")
                conn.execute("PRAGMA synchronous=NORMAL;")
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS arxiv_searches (
                        query_key TEXT PRIMARY KEY,
                        query_text TEXT,
                        max_results INTEGER,
                        sort_by TEXT,
                        results_json TEXT,
                        timestamp REAL,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)
                conn.execute("""
                    CREATE TABLE IF NOT EXISTS arxiv_papers (
                        arxiv_id TEXT PRIMARY KEY,
                        title TEXT,
                        summary TEXT,
                        authors_json TEXT,
                        published TEXT,
                        pdf_url TEXT,
                        entry_json TEXT,
                        timestamp REAL,
                        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    );
                """)
                conn.execute("CREATE INDEX IF NOT EXISTS idx_arxiv_searches_ts ON arxiv_searches(timestamp);")
                conn.execute("CREATE INDEX IF NOT EXISTS idx_arxiv_papers_ts ON arxiv_papers(timestamp);")
                conn.commit()
            self._initialized = True
        except Exception as exc:
            logger.warning("Failed to initialize arxiv SQLite cache at %s: %s", self.db_path, exc)

    def get_search(
        self,
        query: str,
        max_results: int = 10,
        sort_by: str = "relevance",
        max_age_days: float = 30.0,
    ) -> Optional[list[dict[str, Any]]]:
        """Fetch cached search results if within max_age_days."""
        key = make_search_key(query, max_results, sort_by)
        try:
            with self._get_connection() as conn:
                cursor = conn.execute(
                    "SELECT results_json, timestamp FROM arxiv_searches WHERE query_key = ?",
                    (key,),
                )
                row = cursor.fetchone()
                if row:
                    ts = row["timestamp"]
                    if time.time() - ts <= (max_age_days * 86400.0):
                        return json.loads(row["results_json"])
        except Exception as exc:
            logger.debug("Error reading search cache: %s", exc)
        return None

    def set_search(
        self,
        query: str,
        results: list[dict[str, Any]],
        max_results: int = 10,
        sort_by: str = "relevance",
    ) -> None:
        """Store search results and also index individual paper entries."""
        key = make_search_key(query, max_results, sort_by)
        now = time.time()
        try:
            with self._get_connection() as conn:
                conn.execute(
                    """
                    INSERT OR REPLACE INTO arxiv_searches 
                    (query_key, query_text, max_results, sort_by, results_json, timestamp)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (key, query.strip(), max_results, sort_by, json.dumps(results), now),
                )
                # Populate individual paper entries
                for r in results:
                    raw_id = r.get("arxiv_id") or r.get("url", "")
                    clean_id = normalize_arxiv_id(raw_id)
                    if clean_id and re.match(r"^[0-9]{4}\.[0-9]{4,5}$", clean_id):
                        authors_j = json.dumps(r.get("authors", []))
                        entry_j = json.dumps(r)
                        conn.execute(
                            """
                            INSERT OR REPLACE INTO arxiv_papers
                            (arxiv_id, title, summary, authors_json, published, pdf_url, entry_json, timestamp)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            (
                                clean_id,
                                r.get("title", ""),
                                r.get("content", ""),
                                authors_j,
                                r.get("published", ""),
                                r.get("pdf_url", ""),
                                entry_j,
                                now,
                            ),
                        )
                conn.commit()
        except Exception as exc:
            logger.debug("Error writing search cache: %s", exc)

    def get_paper(self, raw_id: str) -> Optional[dict[str, Any]]:
        """Fetch cached paper metadata by normalized arXiv identifier."""
        clean_id = normalize_arxiv_id(raw_id)
        if not clean_id:
            return None
        try:
            with self._get_connection() as conn:
                cursor = conn.execute(
                    "SELECT entry_json, title, summary, authors_json, published, pdf_url FROM arxiv_papers WHERE arxiv_id = ?",
                    (clean_id,),
                )
                row = cursor.fetchone()
                if row:
                    if row["entry_json"]:
                        return json.loads(row["entry_json"])
                    return {
                        "found": True,
                        "id": clean_id,
                        "title": row["title"],
                        "summary": row["summary"],
                        "authors": json.loads(row["authors_json"]) if row["authors_json"] else [],
                        "published": row["published"],
                        "pdf_url": row["pdf_url"],
                    }
        except Exception as exc:
            logger.debug("Error reading paper cache for %s: %s", clean_id, exc)
        return None

    def set_paper(self, raw_id: str, paper_data: dict[str, Any]) -> None:
        """Store metadata for a single paper."""
        clean_id = normalize_arxiv_id(raw_id)
        if not clean_id:
            return
        now = time.time()
        try:
            authors = paper_data.get("authors", [])
            authors_j = json.dumps(authors)
            entry_j = json.dumps(paper_data)
            with self._get_connection() as conn:
                conn.execute(
                    """
                    INSERT OR REPLACE INTO arxiv_papers
                    (arxiv_id, title, summary, authors_json, published, pdf_url, entry_json, timestamp)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        clean_id,
                        paper_data.get("title", ""),
                        paper_data.get("summary") or paper_data.get("content", ""),
                        authors_j,
                        paper_data.get("published") or paper_data.get("pub_date", ""),
                        paper_data.get("pdf_url", ""),
                        entry_j,
                        now,
                    ),
                )
                conn.commit()
        except Exception as exc:
            logger.debug("Error writing paper cache for %s: %s", clean_id, exc)

    def stats(self) -> dict[str, int]:
        """Return counts of cached searches and papers."""
        try:
            with self._get_connection() as conn:
                n_searches = conn.execute("SELECT COUNT(*) FROM arxiv_searches").fetchone()[0]
                n_papers = conn.execute("SELECT COUNT(*) FROM arxiv_papers").fetchone()[0]
                return {"searches": n_searches, "papers": n_papers}
        except Exception:
            return {"searches": 0, "papers": 0}


# Global singleton helper instance
_GLOBAL_CACHE: Optional[ArxivCacheDB] = None


def get_arxiv_cache() -> ArxivCacheDB:
    global _GLOBAL_CACHE
    if _GLOBAL_CACHE is None:
        _GLOBAL_CACHE = ArxivCacheDB()
    return _GLOBAL_CACHE
