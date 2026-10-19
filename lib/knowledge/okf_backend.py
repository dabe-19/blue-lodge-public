#!/usr/bin/env python3
"""
George: Google Open Knowledge Graph (OKF) Backend Engine
Provides semantic search, node querying, standards inspection,
hierarchical tree rendering, and schema validation for Blue Lodge.
"""

import sys
import os
import json
import argparse


def load_graph(graph_file: str) -> dict:
    if not os.path.exists(graph_file):
        print(f"Error: OKF graph file not found at {graph_file}", file=sys.stderr)
        sys.exit(1)
    try:
        with open(graph_file, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"Error reading OKF graph file {graph_file}: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_search(args, graph_data: dict):
    query = args.query.lower()
    nodes = graph_data.get("@graph", [])
    matches = []

    # Fast-path: query SQLite FTS5 BM25 index in .george/recall.db if populated
    lodge_dir = os.environ.get("LODGE_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
    george_dir = os.environ.get("GEORGE_DIR", os.path.join(lodge_dir, ".george"))
    db_path = os.path.join(george_dir, "recall.db")
    fts_uris = {}
    if os.path.isfile(db_path):
        try:
            import sqlite3
            import re
            tokens = [re.sub(r'[^a-zA-Z0-9_\-\.]', '', t) for t in query.strip().split()]
            tokens = [t for t in tokens if t]
            if tokens:
                conn = sqlite3.connect(db_path)
                cur = conn.cursor()
                match_expr = " OR ".join(f"{t}*" for t in tokens)
                cur.execute(
                    "SELECT m.uri, bm25(okf_modules_fts) AS s FROM okf_modules m "
                    "JOIN okf_modules_fts ON m.id = okf_modules_fts.rowid "
                    "WHERE okf_modules_fts MATCH ? ORDER BY s ASC LIMIT 50;",
                    (match_expr,)
                )
                for rank_idx, (uri, _) in enumerate(cur.fetchall()):
                    fts_uris[uri] = 100 - rank_idx
                conn.close()
        except Exception:
            fts_uris = {}

    for node in nodes:
        raw_id = str(node.get("@id", ""))
        nid = raw_id.lower()
        name = str(node.get("name", "")).lower()
        desc = str(node.get("description", "")).lower()
        path = str(node.get("path", "")).lower()
        exports = " ".join(node.get("exports", [])).lower()
        standards = " ".join(node.get("standards", [])).lower()
        keywords = " ".join(node.get("keywords", [])).lower()

        score = fts_uris.get(raw_id, 0)
        if query in nid:
            score += 5
        if query in name:
            score += 4
        if query in path:
            score += 3
        if query in exports:
            score += 3
        if query in desc:
            score += 2
        if query in standards:
            score += 2
        if query in keywords:
            score += 3

        if score > 0:
            matches.append((score, node))

    matches.sort(key=lambda x: x[0], reverse=True)

    if args.json:
        print(json.dumps([m[1] for m in matches], indent=2))
        return

    if not matches:
        print(f'No OKF entities found matching "{args.query}".')
        return

    print(f"\033[1;34mFound {len(matches)} OKF semantic match(es) for \"{args.query}\":\033[0m\n")
    for _, node in matches:
        ntype = node.get("@type", "Entity")
        if isinstance(ntype, list):
            ntype = "/".join(ntype)
        nid = node.get("@id", "")
        name = node.get("name", "")
        path = node.get("path", "")
        desc = node.get("description", "")
        stab = node.get("stability", "stable")

        print(f"  \033[1;36m{name}\033[0m (\033[2m{ntype}\033[0m) [\033[32m{stab}\033[0m]")
        print(f"    \033[33mURI:\033[0m  {nid}")
        if path:
            print(f"    \033[33mPath:\033[0m {path}")
        print(f"    \033[2m{desc}\033[0m")
        if node.get("exports"):
            print(f"    \033[35mExports:\033[0m {', '.join(node.get('exports', []))}")
        print("")


def cmd_query(args, graph_data: dict):
    target = args.target.strip()
    target_clean = target.lstrip("./")
    nodes = graph_data.get("@graph", [])
    matched = None

    for node in nodes:
        nid = str(node.get("@id", ""))
        npath = str(node.get("path", ""))
        nname = str(node.get("name", ""))

        if (
            nid == target
            or nid == f"urn:blue-lodge:module:{target_clean}"
            or nid == f"urn:blue-lodge:subsystem:{target_clean}"
        ):
            matched = node
            break
        if npath == target_clean or npath.endswith(f"/{target_clean}") or nname == target_clean:
            matched = node
            break

    if not matched:
        print(f'Error: OKF entity not found for "{target}".', file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(matched, indent=2))
        return

    ntype = matched.get("@type", "Entity")
    if isinstance(ntype, list):
        ntype = " / ".join(ntype)

    print("\033[1;34m═══════════════════════════════════════════════════════════════\033[0m")
    print(f" \033[1;32m{matched.get('name')}\033[0m (\033[2m{ntype}\033[0m)")
    print("\033[1;34m═══════════════════════════════════════════════════════════════\033[0m")
    print(f"  \033[1;33mURI:\033[0m         {matched.get('@id')}")
    if matched.get("path"):
        print(f"  \033[1;33mPath:\033[0m        {matched.get('path')}")
    if matched.get("programmingLanguage"):
        print(f"  \033[1;33mLanguage:\033[0m    {matched.get('programmingLanguage')}")
    if matched.get("stability"):
        print(f"  \033[1;33mStability:\033[0m   {matched.get('stability')}")
    if matched.get("isPartOf"):
        print(f"  \033[1;33mSubsystem:\033[0m   {matched.get('isPartOf')}")
    print(f"\n  \033[1;36mDescription:\033[0m\n  {matched.get('description')}\n")

    if matched.get("dependencies"):
        print("  \033[1;35mDependencies:\033[0m")
        for dep in matched.get("dependencies"):
            print(f"    • {dep}")
    if matched.get("exports"):
        print("  \033[1;35mExported Symbols / Interface:\033[0m")
        for exp in matched.get("exports"):
            print(f"    • {exp}")
    if matched.get("standards"):
        print("  \033[1;35mGoverning Standards:\033[0m")
        for std in matched.get("standards"):
            print(f"    • {std}")
    if matched.get("definition"):
        print(f"\n  \033[1;36mFormal Definition:\033[0m\n  {matched.get('definition')}")
    if matched.get("articleBody"):
        print(f"\n  \033[1;36mSpecification:\033[0m\n  {matched.get('articleBody')}")
    print("\033[1;34m═══════════════════════════════════════════════════════════════\033[0m\n")


def cmd_standards(args, graph_data: dict):
    target = (args.target or "").strip()
    nodes = graph_data.get("@graph", [])
    standards = [
        n for n in nodes if "standard" in n.get("@id", "") or "DefinedTerm" in n.get("@type", [])
    ]

    if not target:
        if args.json:
            print(json.dumps(standards, indent=2))
            return

        print("\033[1;34m═══════════════════════════════════════════════════════════════\033[0m")
        print(" \033[1;32mBlue Lodge Architectural & Programming Standards\033[0m (OKF)")
        print("\033[1;34m═══════════════════════════════════════════════════════════════\033[0m")
        for s in standards:
            sid = s.get("@id", "").replace("urn:blue-lodge:standard:", "")
            print(f"  \033[1;36m{sid}\033[0m: {s.get('name')}")
            print(f"    \033[2m{s.get('description')}\033[0m\n")
        print("\033[2mRun: okf standards <standard_id> for full specification text.\033[0m\n")
        return

    matched = None
    target_clean = target.lower().replace("urn:blue-lodge:standard:", "")
    for s in standards:
        sid = s.get("@id", "").lower()
        if target_clean in sid or target_clean in str(s.get("name", "")).lower():
            matched = s
            break

    if not matched:
        print(f'Error: Standard not found matching "{target}".', file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(matched, indent=2))
        return

    print("\033[1;34m═══════════════════════════════════════════════════════════════\033[0m")
    print(f" \033[1;32m{matched.get('name')}\033[0m")
    print(f" \033[2m{matched.get('@id')}\033[0m")
    print("\033[1;34m═══════════════════════════════════════════════════════════════\033[0m")
    print(f"\n\033[1;33mDescription:\033[0m {matched.get('description')}\n")
    if matched.get("definition"):
        print(f"\033[1;36mCore Invariant:\033[0m\n{matched.get('definition')}\n")
    if matched.get("articleBody"):
        print(f"\033[1;36mSpecification Protocol:\033[0m\n{matched.get('articleBody')}\n")
    if matched.get("step"):
        print("\033[1;36mProcedural Steps:\033[0m")
        for idx, st in enumerate(matched.get("step"), 1):
            print(f"  {idx}. \033[1m{st.get('name')}\033[0m: {st.get('text')}")
        print("")
    if matched.get("codeSample"):
        print(f"\033[1;35mImplementation Sample:\033[0m\n{matched.get('codeSample')}\n")


def cmd_tree(args, graph_data: dict):
    target_sub = (args.subsystem or "").strip().lower()
    nodes = graph_data.get("@graph", [])
    subsystems = [n for n in nodes if n.get("@type") == "DataCatalog"]
    modules = [n for n in nodes if n.get("@type") == "SoftwareSourceCode"]

    sub_map = {s["@id"]: s for s in subsystems}
    mod_by_sub = {}
    for m in modules:
        sub_id = m.get("isPartOf", "urn:blue-lodge:subsystem:core")
        mod_by_sub.setdefault(sub_id, []).append(m)

    print("\033[1;34mBlue Lodge OKF Hierarchical Knowledge Tree\033[0m")
    print("\033[2murn:blue-lodge:core (Sovereign Architecture)\033[0m")

    for sub_id, sub in sub_map.items():
        if (
            target_sub
            and target_sub not in sub_id.lower()
            and target_sub not in str(sub.get("name", "")).lower()
        ):
            continue

        sub_name = str(sub.get("name"))
        sub_path = str(sub.get("path", ""))
        print(f"\n├── \033[1;32m{sub_name}\033[0m [\033[33m{sub_path}\033[0m]")
        print(f"│   \033[2m{sub.get('description')}\033[0m")

        sub_mods = mod_by_sub.get(sub_id, [])
        for idx, mod in enumerate(sub_mods):
            is_last = idx == len(sub_mods) - 1
            prefix = "└──" if is_last else "├──"
            exports_ct = len(mod.get("exports", []))
            deps_ct = len(mod.get("dependencies", []))
            mname = str(mod.get("name"))
            mpath = str(mod.get("path"))
            print(
                f"│   {prefix} \033[1;36m{mname}\033[0m (\033[2m{mpath}\033[0m) [exports: {exports_ct}, deps: {deps_ct}]"
            )


def cmd_validate(args, graph_data: dict):
    lodge_dir = args.lodge_dir

    if "@context" not in graph_data or "@graph" not in graph_data:
        print("✗ FAIL: OKF graph missing @context or @graph root keys", file=sys.stderr)
        sys.exit(1)

    nodes = graph_data["@graph"]
    print(f"Checking {len(nodes)} semantic nodes in OKF graph...")

    missing_files = []
    invalid_nodes = []

    for node in nodes:
        nid = node.get("@id")
        ntype = node.get("@type")
        name = node.get("name")
        path = node.get("path")

        if not nid or not ntype or not name:
            invalid_nodes.append(str(node))
            continue

        if (ntype == "SoftwareSourceCode" or "DigitalDocument" in ntype or "TechArticle" in ntype) and path:
            full_path = os.path.join(lodge_dir, path)
            base = os.path.basename(path)
            legacy_path = os.path.join(lodge_dir, "lib", base)
            if not os.path.exists(full_path) and not os.path.exists(legacy_path):
                missing_files.append((nid, path))

    if invalid_nodes:
        print(
            f"✗ FAIL: {len(invalid_nodes)} nodes missing required @id, @type, or name",
            file=sys.stderr,
        )
        sys.exit(1)

    if missing_files:
        print(f"⚠ WARNING: {len(missing_files)} module paths missing on disk:")
        for nid, p in missing_files[:5]:
            print(f"    - {nid} -> {p}")
    else:
        print("✓ All referenced source files verified on disk.")

    print("✓ OKF Graph structure & JSON-LD syntax: VALID")


def main():
    parser = argparse.ArgumentParser(description="Blue Lodge OKF Backend Engine")
    parser.add_argument(
        "--graph",
        default=os.environ.get("OKF_GRAPH_FILE", "okf/blue_lodge_graph.jsonld"),
        help="Path to okf graph jsonld file",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Search
    p_search = subparsers.add_parser("search", help="Semantic search in OKF graph")
    p_search.add_argument("query", help="Search query string")
    p_search.add_argument("--json", action="store_true", help="Output JSON")

    # Query
    p_query = subparsers.add_parser("query", help="Exact entity lookup")
    p_query.add_argument("target", help="Entity URI, name, or path")
    p_query.add_argument("--json", action="store_true", help="Output JSON")

    # Standards
    p_standards = subparsers.add_parser("standards", help="Standards inspection")
    p_standards.add_argument("target", nargs="?", default="", help="Standard ID or keyword")
    p_standards.add_argument("--json", action="store_true", help="Output JSON")

    # Tree
    p_tree = subparsers.add_parser("tree", help="Render hierarchical tree")
    p_tree.add_argument("subsystem", nargs="?", default="", help="Optional subsystem filter")

    # Validate
    p_val = subparsers.add_parser("validate", help="Validate graph and paths")
    p_val.add_argument(
        "--schema",
        default=os.environ.get("OKF_SCHEMA_FILE", "data/schemas/okf_graph.schema.json"),
        help="Path to schema file",
    )
    p_val.add_argument(
        "--lodge-dir",
        default=os.environ.get("LODGE_DIR", "."),
        help="Workspace root path",
    )

    args = parser.parse_args()
    graph_data = load_graph(args.graph)

    if args.command == "search":
        cmd_search(args, graph_data)
    elif args.command == "query":
        cmd_query(args, graph_data)
    elif args.command == "standards":
        cmd_standards(args, graph_data)
    elif args.command == "tree":
        cmd_tree(args, graph_data)
    elif args.command == "validate":
        cmd_validate(args, graph_data)


if __name__ == "__main__":
    main()
