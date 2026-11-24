#!/usr/bin/env python3
"""
OKF SQLite Indexer & FTS5 BM25 Codebase Search Engine.
Synchronizes the Google Open Knowledge Graph (OKF) JSON-LD graph into SQLite FTS5
in .george/recall.db to enable instantaneous semantic and lexical navigation.
"""

import os
import sys
import json
import sqlite3
import argparse
from datetime import datetime, timezone

LODGE_DIR = os.environ.get("LODGE_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
GEORGE_DIR = os.environ.get("GEORGE_DIR", os.path.join(LODGE_DIR, ".george"))
DEFAULT_DB_PATH = os.environ.get("RECALL_DB", os.path.join(GEORGE_DIR, "recall.db"))
if (
    not os.environ.get("RECALL_DB")
    and not os.environ.get("GEORGE_DIR")
    and not os.path.exists(DEFAULT_DB_PATH)
):
    _host_db = os.path.expanduser("~/blue-lodge/.george/recall.db")
    if os.path.exists(_host_db):
        DEFAULT_DB_PATH = _host_db
DEFAULT_GRAPH_PATH = os.path.join(LODGE_DIR, "okf", "blue_lodge_graph.jsonld")

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS okf_modules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uri TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    subsystem TEXT NOT NULL,
    subsystem_name TEXT NOT NULL,
    language TEXT NOT NULL,
    description TEXT NOT NULL,
    exports TEXT NOT NULL,
    depends_on TEXT NOT NULL,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    indexed_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_okf_modules_path ON okf_modules(path);
CREATE INDEX IF NOT EXISTS idx_okf_modules_subsystem ON okf_modules(subsystem);

CREATE VIRTUAL TABLE IF NOT EXISTS okf_modules_fts USING fts5(
    name,
    path,
    subsystem_name,
    language,
    description,
    exports,
    depends_on,
    content='okf_modules',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS okf_modules_ai AFTER INSERT ON okf_modules BEGIN
    INSERT INTO okf_modules_fts(rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES (new.id, new.name, new.path, new.subsystem_name, new.language, new.description, new.exports, new.depends_on);
END;

CREATE TRIGGER IF NOT EXISTS okf_modules_ad AFTER DELETE ON okf_modules BEGIN
    INSERT INTO okf_modules_fts(okf_modules_fts, rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES ('delete', old.id, old.name, old.path, old.subsystem_name, old.language, old.description, old.exports, old.depends_on);
END;

CREATE TRIGGER IF NOT EXISTS okf_modules_au AFTER UPDATE ON okf_modules BEGIN
    INSERT INTO okf_modules_fts(okf_modules_fts, rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES ('delete', old.id, old.name, old.path, old.subsystem_name, old.language, old.description, old.exports, old.depends_on);
    INSERT INTO okf_modules_fts(rowid, name, path, subsystem_name, language, description, exports, depends_on)
    VALUES (new.id, new.name, new.path, new.subsystem_name, new.language, new.description, new.exports, new.depends_on);
END;

CREATE TABLE IF NOT EXISTS okf_edges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    src_uri TEXT NOT NULL,
    rel_type TEXT NOT NULL,
    dst_uri TEXT NOT NULL,
    weight REAL NOT NULL DEFAULT 1.0,
    UNIQUE(src_uri, rel_type, dst_uri)
);

CREATE INDEX IF NOT EXISTS idx_okf_edges_src ON okf_edges(src_uri);
CREATE INDEX IF NOT EXISTS idx_okf_edges_dst ON okf_edges(dst_uri);
CREATE INDEX IF NOT EXISTS idx_okf_edges_rel ON okf_edges(rel_type);
"""


def init_db(db_path=DEFAULT_DB_PATH):
    """Ensure database directory and OKF schema tables exist."""
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA_SQL)
    conn.commit()
    return conn


def load_or_generate_graph(graph_path=DEFAULT_GRAPH_PATH):
    """Load the JSON-LD graph file; trigger generation if missing."""
    if not os.path.isfile(graph_path):
        gen_script = os.path.join(LODGE_DIR, "okf", "generate_okf_graph.py")
        if os.path.isfile(gen_script):
            import subprocess
            subprocess.run([sys.executable, gen_script], check=True)

    with open(graph_path, "r", encoding="utf-8") as f:
        return json.load(f)


def index_graph(db_path=DEFAULT_DB_PATH, graph_path=DEFAULT_GRAPH_PATH):
    """Parse JSON-LD graph and synchronize all modules into SQLite FTS5."""
    data = load_or_generate_graph(graph_path)
    nodes = data.get("@graph", [])

    # Map subsystem URIs to human-readable names
    subsystem_names = {
        "urn:blue-lodge:subsystem:core": "Core Reasoning & Agent Loop",
        "urn:blue-lodge:subsystem:tools": "Tools & Native Protocol Bridges",
        "urn:blue-lodge:subsystem:ipc": "Asynchronous FIFO IPC & Flow Control",
        "urn:blue-lodge:subsystem:sys": "System, Security & Environment",
        "urn:blue-lodge:subsystem:comms": "External Communications & Social Fabrics",
        "urn:blue-lodge:subsystem:memory": "Memory, Recall & Journal",
        "urn:blue-lodge:subsystem:agents": "Autonomous Subagents, Swarm & Remediation",
        "urn:blue-lodge:subsystem:ui": "Terminal UI & Interactive Shell",
        "urn:blue-lodge:subsystem:knowledge": "Google Open Knowledge Graph (OKF) Engine",
        "urn:blue-lodge:subsystem:scripts": "Automation, Infrastructure & Model Scripts",
        "urn:blue-lodge:subsystem:commands": "Slash Command Dispatch Catalog",
        "urn:blue-lodge:subsystem:web": "Sovereign Web UI Sidecar",
        "urn:blue-lodge:core": "Blue Lodge Sovereign Core Architecture"
    }

    for node in nodes:
        types = node.get("@type", [])
        if isinstance(types, str):
            types = [types]
        if "DataCatalog" in types and "@id" in node and "name" in node:
            subsystem_names[node["@id"]] = node["name"]

    conn = init_db(db_path)
    cursor = conn.cursor()

    # Clear previous OKF module and edge entries
    cursor.execute("DELETE FROM okf_modules;")
    cursor.execute("DELETE FROM okf_edges;")
    cursor.execute("INSERT INTO okf_modules_fts(okf_modules_fts) VALUES('rebuild');")

    indexed_count = 0
    symbols_count = 0
    edges_count = 0
    now_ts = datetime.now(timezone.utc).isoformat()

    def _add_edge(src_u: str, rel: str, dst_u: str, w: float = 1.0):
        nonlocal edges_count
        if not src_u or not dst_u or src_u == dst_u:
            return
        cursor.execute(
            "INSERT OR IGNORE INTO okf_edges (src_uri, rel_type, dst_uri, weight) VALUES (?, ?, ?, ?);",
            (src_u, rel, dst_u, w),
        )
        if cursor.rowcount > 0:
            edges_count += 1

    for node in nodes:
        types = node.get("@type", [])
        if isinstance(types, str):
            types = [types]
        uri = node.get("@id", "")

        # Record structural edges for all node types (subsystems, docs, standards, modules)
        is_part = node.get("isPartOf", "")
        if isinstance(is_part, str) and is_part:
            _add_edge(uri, "isPartOf", is_part, 0.45)
            _add_edge(is_part, "hasPart", uri, 0.45)

        for std_u in node.get("standards", []) or []:
            if isinstance(std_u, str):
                _add_edge(uri, "governedBy", std_u, 0.8)
                _add_edge(std_u, "governs", uri, 0.8)

        for rel_u in node.get("related", []) or []:
            if isinstance(rel_u, str):
                _add_edge(uri, "relatedTo", rel_u, 0.75)

        if "SoftwareSourceCode" not in types:
            continue

        name = node.get("name", "")
        rel_path = node.get("path", "")
        lang = node.get("programmingLanguage", "")
        desc = node.get("description", "")
        subsystem_uri = node.get("isPartOf", "")
        subsystem_name = subsystem_names.get(subsystem_uri, subsystem_uri.split(":")[-1].replace("_", " ").title())

        exports = node.get("exports", [])
        deps = node.get("dependencies", [])

        for d_u in deps:
            if isinstance(d_u, str) and d_u:
                _add_edge(uri, "dependsOn", d_u, 1.0)
                _add_edge(d_u, "dependedOnBy", uri, 0.85)

        for d_obj in node.get("dependsOn", []) or []:
            if isinstance(d_obj, dict) and d_obj.get("@id"):
                _add_edge(uri, "dependsOn", d_obj["@id"], 1.0)
                _add_edge(d_obj["@id"], "dependedOnBy", uri, 0.85)

        symbols_count += len(exports)

        full_path = os.path.join(LODGE_DIR, rel_path) if rel_path else ""
        size_bytes = 0
        if full_path and os.path.isfile(full_path):
            try:
                size_bytes = os.path.getsize(full_path)
            except Exception:
                size_bytes = 0

        cursor.execute(
            """
            INSERT INTO okf_modules (
                uri, name, path, subsystem, subsystem_name, language, description, exports, depends_on, size_bytes, indexed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            (
                uri,
                name,
                rel_path,
                subsystem_uri,
                subsystem_name,
                lang,
                desc,
                json.dumps(exports),
                json.dumps(deps),
                size_bytes,
                now_ts
            )
        )
        indexed_count += 1

    conn.commit()
    conn.close()

    return {
        "status": "ok",
        "indexed_modules": indexed_count,
        "indexed_symbols": symbols_count,
        "indexed_edges": edges_count,
        "subsystems_tracked": len(subsystem_names),
        "db_path": db_path,
        "timestamp": now_ts
    }


def search_okf(query, subsystem=None, limit=30, db_path=DEFAULT_DB_PATH):
    """Execute FTS5 BM25 search across OKF indexed codebase modules."""
    conn = init_db(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    # Sanitize and build FTS5 prefix tokens
    import re
    tokens = [re.sub(r'[^a-zA-Z0-9_\-\.]', '', t) for t in query.strip().split()]
    tokens = [t for t in tokens if t]
    
    if not tokens:
        if subsystem:
            sql = """
                SELECT m.id, m.uri, m.name, m.path, m.subsystem, m.subsystem_name,
                       m.language, m.description, m.exports, m.depends_on, m.size_bytes,
                       0.0 AS bm25_score
                FROM okf_modules m
                WHERE (m.subsystem = ? OR m.subsystem LIKE ? OR m.subsystem_name LIKE ?)
                ORDER BY m.path ASC LIMIT ?;
            """
            cursor.execute(sql, [subsystem, f"%{subsystem}%", f"%{subsystem}%", limit])
            rows = cursor.fetchall()
        else:
            return []
    else:
        match_expr = " OR ".join(f"{t}*" for t in tokens)
        sql = """
            SELECT m.id, m.uri, m.name, m.path, m.subsystem, m.subsystem_name,
                   m.language, m.description, m.exports, m.depends_on, m.size_bytes,
                   bm25(okf_modules_fts) AS bm25_score
            FROM okf_modules m
            JOIN okf_modules_fts ON m.id = okf_modules_fts.rowid
            WHERE okf_modules_fts MATCH ?
        """
        params = [match_expr]

        if subsystem:
            sql += " AND (m.subsystem = ? OR m.subsystem_name LIKE ?)"
            params.extend([subsystem, f"%{subsystem}%"])

        sql += " ORDER BY bm25_score ASC LIMIT ?;"
        params.append(limit)

        try:
            cursor.execute(sql, params)
            rows = cursor.fetchall()
        except sqlite3.OperationalError:
            # Fallback to plain query if syntax error in MATCH
            term_clean = " ".join(tokens)
            sql_fallback = """
                SELECT m.id, m.uri, m.name, m.path, m.subsystem, m.subsystem_name,
                       m.language, m.description, m.exports, m.depends_on, m.size_bytes,
                       0.0 AS bm25_score
                FROM okf_modules m
                WHERE (m.name LIKE ? OR m.path LIKE ? OR m.description LIKE ? OR m.exports LIKE ?)
            """
            like_p = f"%{term_clean}%"
            f_params = [like_p, like_p, like_p, like_p]
            if subsystem:
                sql_fallback += " AND (m.subsystem = ? OR m.subsystem_name LIKE ?)"
                f_params.extend([subsystem, f"%{subsystem}%"])
            sql_fallback += " ORDER BY m.path ASC LIMIT ?;"
            f_params.append(limit)
            cursor.execute(sql_fallback, f_params)
            rows = cursor.fetchall()

    results = []
    for r in rows:
        try:
            exports_list = json.loads(r["exports"])
        except Exception:
            exports_list = []
        try:
            deps_list = json.loads(r["depends_on"])
        except Exception:
            deps_list = []

        results.append({
            "id": r["id"],
            "uri": r["uri"],
            "name": r["name"],
            "path": r["path"],
            "subsystem": r["subsystem"],
            "subsystem_name": r["subsystem_name"],
            "language": r["language"],
            "description": r["description"],
            "exports": exports_list,
            "exports_count": len(exports_list),
            "depends_on": deps_list,
            "size_bytes": r["size_bytes"],
            "bm25_score": round(float(r["bm25_score"]), 4)
        })

    conn.close()
    return results


def traverse_okf(seed_target, max_hops=2, alpha=0.85, limit=25, db_path=DEFAULT_DB_PATH):
    """Execute Personalized PageRank (PPR) & multi-hop neighborhood traversal over okf_edges."""
    conn = init_db(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    clean = seed_target.strip().lstrip("./")
    seed_uri = clean
    if not clean.startswith("urn:blue-lodge:"):
        row = cursor.execute(
            "SELECT uri FROM okf_modules WHERE path = ? OR name = ? OR path LIKE ? LIMIT 1;",
            (clean, clean, f"%/{clean}"),
        ).fetchone()
        if row:
            seed_uri = row["uri"]
        else:
            seed_uri = f"urn:blue-lodge:module:{clean}"

    # Load direct dependency/caller/standards/related edges (skip broad subsystem hasPart fan-out unless seed is a subsystem)
    if seed_uri.startswith("urn:blue-lodge:subsystem:"):
        edge_rows = cursor.execute("SELECT src_uri, rel_type, dst_uri, weight FROM okf_edges;").fetchall()
    else:
        edge_rows = cursor.execute(
            "SELECT src_uri, rel_type, dst_uri, weight FROM okf_edges WHERE rel_type NOT IN ('isPartOf', 'hasPart');"
        ).fetchall()

    adj = {}
    out_weight_sum = {}
    for er in edge_rows:
        u, rel, v, w = er["src_uri"], er["rel_type"], er["dst_uri"], float(er["weight"])
        adj.setdefault(u, []).append((v, rel, w))
        out_weight_sum[u] = out_weight_sum.get(u, 0.0) + w

    # Power iteration for Personalized PageRank: r^{(k+1)} = (1 - alpha) * p_0 + alpha * W^T r^{(k)}
    scores = {seed_uri: 1.0}
    hop_map = {seed_uri: 0}
    via_map = {seed_uri: "seed"}

    for hop in range(1, max(1, int(max_hops)) + 1):
        next_scores = {seed_uri: 1.0 - alpha}
        for u, s_u in scores.items():
            edges = adj.get(u, [])
            denom = out_weight_sum.get(u, 1.0) or 1.0
            for v, rel, w in edges:
                contrib = alpha * s_u * (w / denom)
                next_scores[v] = next_scores.get(v, 0.0) + contrib
                if v not in hop_map:
                    hop_map[v] = hop
                    via_map[v] = f"{rel} from {u.split(':')[-1]}"
        scores = next_scores

    ranked = sorted(
        [(u, sc) for u, sc in scores.items() if u != seed_uri],
        key=lambda x: x[1],
        reverse=True,
    )[:limit]

    neighbors = []
    for u, sc in ranked:
        mod = cursor.execute(
            "SELECT uri, name, path, subsystem, subsystem_name, language, description, exports, depends_on FROM okf_modules WHERE uri = ? LIMIT 1;",
            (u,),
        ).fetchone()
        if mod:
            try:
                exps = json.loads(mod["exports"])
            except Exception:
                exps = []
            neighbors.append({
                "uri": mod["uri"],
                "name": mod["name"],
                "path": mod["path"],
                "subsystem": mod["subsystem"],
                "language": mod["language"],
                "description": mod["description"],
                "exports": exps[:8],
                "hop": hop_map.get(u, 1),
                "via": via_map.get(u, "edge"),
                "ppr_score": round(sc, 6),
            })
        else:
            neighbors.append({
                "uri": u,
                "name": u.split(":")[-1],
                "path": "",
                "subsystem": "",
                "language": "Standard/Doc",
                "description": "",
                "exports": [],
                "hop": hop_map.get(u, 1),
                "via": via_map.get(u, "edge"),
                "ppr_score": round(sc, 6),
            })

    conn.close()
    return {
        "seed_uri": seed_uri,
        "max_hops": max_hops,
        "alpha": alpha,
        "neighbors_count": len(neighbors),
        "neighbors": neighbors,
    }


def get_okf_stats(db_path=DEFAULT_DB_PATH):
    """Retrieve indexed statistics from the database."""
    conn = init_db(db_path)
    cursor = conn.cursor()

    cursor.execute("SELECT COUNT(*) FROM okf_modules;")
    total_modules = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM okf_edges;")
    total_edges = cursor.fetchone()[0]

    cursor.execute("SELECT subsystem, subsystem_name, COUNT(*) FROM okf_modules GROUP BY subsystem ORDER BY COUNT(*) DESC;")
    subsystem_breakdown = [
        {"subsystem": r[0], "subsystem_name": r[1], "count": r[2]}
        for r in cursor.fetchall()
    ]

    cursor.execute("SELECT language, COUNT(*) FROM okf_modules GROUP BY language ORDER BY COUNT(*) DESC;")
    language_breakdown = [
        {"language": r[0], "count": r[1]}
        for r in cursor.fetchall()
    ]

    conn.close()
    return {
        "status": "ok",
        "total_modules": total_modules,
        "total_edges": total_edges,
        "subsystem_breakdown": subsystem_breakdown,
        "language_breakdown": language_breakdown
    }


def main():
    parser = argparse.ArgumentParser(description="OKF SQLite Indexer & FTS5 BM25 Codebase Search")
    parser.add_argument("--index", action="store_true", help="Index the OKF JSON-LD graph into SQLite recall.db")
    parser.add_argument("--search", type=str, help="Search the codebase using SQLite FTS5 BM25")
    parser.add_argument("--traverse", type=str, help="Traverse multi-hop neighborhood via Personalized PageRank (PPR)")
    parser.add_argument("--hops", type=int, default=2, help="Maximum hops for PPR graph traversal (default: 2)")
    parser.add_argument("--subsystem", type=str, help="Filter search by subsystem URI or name")
    parser.add_argument("--stats", action="store_true", help="Display index statistics")
    parser.add_argument("--limit", type=int, default=30, help="Maximum search results to return")
    parser.add_argument("--json", action="store_true", help="Output results formatted as JSON")
    parser.add_argument("--db", type=str, default=DEFAULT_DB_PATH, help="Path to recall.db SQLite database")

    args = parser.parse_args()

    if args.index:
        res = index_graph(db_path=args.db)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"[OKF INDEXER] Indexed {res['indexed_modules']} modules ({res['indexed_symbols']} symbols, {res.get('indexed_edges', 0)} edges) across {res['subsystems_tracked']} subsystems in {res['db_path']}.")
        return

    if args.traverse:
        res = traverse_okf(args.traverse, max_hops=args.hops, limit=args.limit, db_path=args.db)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"[OKF PPR TRAVERSAL] Seed: {res['seed_uri']} (max_hops={res['max_hops']}, neighbors={res['neighbors_count']})")
            for n in res["neighbors"]:
                print(f"  [hop={n['hop']} ppr={n['ppr_score']:.4f}] {n['path'] or n['uri']} ({n['via']})")
                if n["description"]:
                    print(f"      {n['description']}")
        return

    if args.stats:
        stats = get_okf_stats(db_path=args.db)
        if args.json:
            print(json.dumps(stats, indent=2))
        else:
            print(f"[OKF STATS] Total modules: {stats['total_modules']} | Total edges: {stats.get('total_edges', 0)}")
            print("Subsystems:")
            for s in stats["subsystem_breakdown"]:
                print(f"  - {s['subsystem_name']} ({s['subsystem']}): {s['count']} modules")
            print("Languages:")
            for l in stats["language_breakdown"]:
                print(f"  - {l['language']}: {l['count']} modules")
        return

    if args.search or args.subsystem:
        results = search_okf(args.search or "", subsystem=args.subsystem, limit=args.limit, db_path=args.db)
        if args.json:
            print(json.dumps(results, indent=2))
        else:
            q_desc = f"query '{args.search}'" if args.search else f"subsystem '{args.subsystem}'"
            print(f"[OKF BM25 SEARCH] Found {len(results)} matches for {q_desc}:")
            for r in results:
                print(f"  [{r['bm25_score']}] {r['path']} ({r['language']} | {r['subsystem_name']})")
                if r['description']:
                    print(f"      Description: {r['description']}")
                if r['exports']:
                    preview = ", ".join(r['exports'][:6]) + ("..." if len(r['exports']) > 6 else "")
                    print(f"      Exports ({r['exports_count']}): {preview}")
        return

    parser.print_help()


if __name__ == "__main__":
    main()
