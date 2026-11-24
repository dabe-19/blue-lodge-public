#!/usr/bin/env python3
"""Capability Graph & Contextual-Bandit Tool/Subagent Router.

Implements the theoretical routing architecture from:
  1. .george/research/dynamic-routing-in-heterogeneous-mixture-of-agents/dossier.md
     - Contextual-bandit Beta-Bernoulli posterior reliability
     - Soft latency penalty: s_pen_l = exp(gamma * max(0, w_l - xi * tau))
  2. .george/research/graph-neural-networks-for-real-time-memory-depende/dossier.md
     - Personalized PageRank (PPR) 2-hop propagation over okf_edges in recall.db
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import glob
import json
import math
import os
import re
import sqlite3
import sys
from typing import Any
try:
    import yaml
except ImportError:
    yaml = None  # type: ignore[assignment]

LODGE_DIR = os.environ.get(
    "LODGE_DIR",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")),
)
GEORGE_DIR = os.environ.get("GEORGE_DIR", os.path.join(LODGE_DIR, ".george"))
RECALL_DB = os.environ.get("RECALL_DB", os.path.join(GEORGE_DIR, "recall.db"))
TOOLS_FTS_DB = os.environ.get(
    "_LODGE_TOOLS_FTS_DB", os.path.join(GEORGE_DIR, "tools_fts.db")
)

# Map OKF subsystems to tool profile domains
SUBSYSTEM_TO_DOMAIN = {
    "urn:blue-lodge:subsystem:core": "code",
    "urn:blue-lodge:subsystem:tools": "code",
    "urn:blue-lodge:subsystem:ui": "code",
    "urn:blue-lodge:subsystem:web": "code",
    "urn:blue-lodge:subsystem:commands": "code",
    "urn:blue-lodge:subsystem:knowledge": "code",
    "urn:blue-lodge:subsystem:memory": "research",
    "urn:blue-lodge:subsystem:docs": "research",
    "urn:blue-lodge:subsystem:sys": "ops",
    "urn:blue-lodge:subsystem:ipc": "ops",
    "urn:blue-lodge:subsystem:scripts": "ops",
    "urn:blue-lodge:subsystem:agents": "ops",
    "urn:blue-lodge:subsystem:comms": "social",
    "urn:blue-lodge:subsystem:trading": "crypto",
    "urn:blue-lodge:subsystem:wallet": "crypto",
    "urn:blue-lodge:subsystem:quant": "crypto",
}

# Extended semantic concepts that regex heuristics often miss
DOMAIN_SYNONYMS: dict[str, set[str]] = {
    "research": {
        "monograph", "dossier", "citation", "crossref", "preprint",
        "literature", "bibliography", "benchmark", "empirical", "hypothesis",
        "theorem", "frequency", "mhz", "modulation", "sigint",
    },
    "code": {
        "axum", "tokio", "rust", "sqlite", "schema", "ast", "treesitter",
        "okf", "jsonld", "indexer", "endpoint", "handler", "router",
        "regression", "assertion", "pytest", "ruff", "shellcheck", "bash",
        "python", " worktree", "branch", "diff", "merge",
    },
    "ops": {
        "systemd", "cgroup", "namespace", "unshare", "overlayfs", "fifo",
        "telemetry", "anomaly", "remediation", "phytology", "quarantine",
        "heartbeat", "orphan", "reap", "memory", "vram", "cuda", "prism",
    },
    "social": {
        "mastodon", "bluesky", "bsky", "webhook", "broadcast", "channel",
        "thread", "announce", "notify", "dm", "inbox", "calendar", "gsuite",
    },
    "crypto": {
        "minswap", "sundaeswap", "wingriders", "plutus", "eutxo", "lovelace",
        "slippage", "orderbook", "liquidity", "amm", "cointegration",
        "johansen", "kelly", "sharpe", "drawdown", "collateral", "defi",
    },
}

STOPWORDS = {
    "the", "and", "for", "with", "that", "this", "from", "into", "your",
    "have", "what", "when", "where", "which", "will", "would", "could",
    "should", "about", "please", "can", "you", "our", "are", "was", "were",
    "how", "why", "who", "all", "any", "some", "more", "most", "other",
}


def _tokenize(text: str) -> list[str]:
    words = re.findall(r"[a-zA-Z0-9_\-\.]{2,}", text.lower())
    return [w.strip(".-_") for w in words if w.strip(".-_") and w not in STOPWORDS]


def compute_latency_penalty(
    ewma_ms: float,
    p95_ms: float,
    tau_ms: float = 2500.0,
    gamma: float = 0.0004,
    xi: float = 1.0,
) -> float:
    """Soft latency penalty s_pen_l = exp(gamma * max(0, w_l - xi * tau))."""
    w_l = 0.7 * float(ewma_ms) + 0.3 * float(p95_ms)
    excess = max(0.0, w_l - xi * float(tau_ms))
    # Cap exponent to avoid overflow on extreme outliers
    return math.exp(min(4.0, gamma * excess))


def compute_bandit_reliability(
    calls: int,
    successes: int,
    total_calls_across_tools: int = 100,
    alpha0: float = 2.0,
    beta0: float = 1.0,
    ucb_c: float = 0.08,
) -> float:
    """Beta-Bernoulli posterior mean + lightweight UCB exploration bonus."""
    post_mean = (alpha0 + max(0, successes)) / (alpha0 + beta0 + max(0, calls))
    bonus = ucb_c * math.sqrt(math.log(2.0 + max(1, total_calls_across_tools)) / (1.0 + max(0, calls)))
    return min(1.25, post_mean + bonus)


def load_tool_telemetry(recall_db: str = RECALL_DB) -> tuple[dict[str, dict[str, Any]], int]:
    stats: dict[str, dict[str, Any]] = {}
    total_calls = 0
    if not os.path.isfile(recall_db):
        return stats, 0
    try:
        conn = sqlite3.connect(recall_db)
        conn.row_factory = sqlite3.Row
        rows = conn.execute("SELECT * FROM tool_telemetry_stats;").fetchall()
        for r in rows:
            c = int(r["call_count"] or 0)
            total_calls += c
            stats[r["tool_name"]] = {
                "calls": c,
                "success": int(r["success_count"] or 0),
                "fail": int(r["fail_count"] or 0),
                "ewma_ms": float(r["ewma_latency_ms"] or 250.0),
                "p95_ms": float(r["p95_latency_ms"] or 500.0),
                "last_error": str(r["last_error_class"] or ""),
            }
        conn.close()
    except Exception:
        pass
    return stats, total_calls


def okf_ppr_context(
    query: str,
    recall_db: str = RECALL_DB,
    alpha: float = 0.85,
) -> dict[str, Any]:
    """Run BM25 seed lookup + 2-hop Personalized PageRank over okf_edges."""
    result: dict[str, Any] = {
        "module_scores": {},
        "subsystem_scores": defaultdict(float),
        "domain_scores": defaultdict(float),
        "exported_symbols": set(),
    }
    if not os.path.isfile(recall_db):
        return result

    tokens = _tokenize(query)
    if not tokens:
        return result

    try:
        conn = sqlite3.connect(recall_db)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        fts_tokens = [re.sub(r"[^a-zA-Z0-9]", "", t) for t in tokens if len(re.sub(r"[^a-zA-Z0-9]", "", t)) >= 2]
        if not fts_tokens:
            conn.close()
            return result
        match_expr = " OR ".join(f"{t}*" for t in fts_tokens[:10])
        seed_rows = cur.execute(
            """SELECT m.uri, m.subsystem, m.exports, bm25(okf_modules_fts) AS s
               FROM okf_modules m
               JOIN okf_modules_fts ON m.id = okf_modules_fts.rowid
               WHERE okf_modules_fts MATCH ?
               ORDER BY s ASC LIMIT 15;""",
            (match_expr,),
        ).fetchall()

        if not seed_rows:
            conn.close()
            return result

        p0: dict[str, float] = {}
        for idx, r in enumerate(seed_rows):
            w = 1.0 / (1.0 + 0.25 * idx)
            p0[r["uri"]] = w
        norm = sum(p0.values()) or 1.0
        p0 = {k: v / norm for k, v in p0.items()}

        # 2-hop Personalized PageRank over okf_edges
        scores = dict(p0)
        for _ in range(2):
            next_scores = {u: (1.0 - alpha) * p0.get(u, 0.0) for u in p0}
            for u, s_u in list(scores.items()):
                if s_u < 1e-4:
                    continue
                edges = cur.execute(
                    """SELECT dst_uri, weight FROM okf_edges
                       WHERE src_uri = ? AND rel_type NOT IN ('isPartOf', 'hasPart')
                       LIMIT 25;""",
                    (u,),
                ).fetchall()
                denom = sum(float(e["weight"] or 1.0) for e in edges) or 1.0
                for e in edges:
                    v = e["dst_uri"]
                    w = float(e["weight"] or 1.0)
                    next_scores[v] = next_scores.get(v, 0.0) + alpha * s_u * (w / denom)
            scores = next_scores

        result["module_scores"] = scores
        top_uris = sorted(scores.items(), key=lambda x: x[1], reverse=True)[:20]
        for uri, sc in top_uris:
            row = cur.execute(
                "SELECT subsystem, exports, path FROM okf_modules WHERE uri = ? LIMIT 1;",
                (uri,),
            ).fetchone()
            if row:
                sub = row["subsystem"]
                result["subsystem_scores"][sub] += sc
                dom = SUBSYSTEM_TO_DOMAIN.get(sub)
                # Only map general codebase hits to domain when path/uri isn't just generic core
                if dom:
                    result["domain_scores"][dom] += sc
                try:
                    for sym in json.loads(row["exports"] or "[]"):
                        result["exported_symbols"].add(str(sym))
                except Exception:
                    pass
        conn.close()
    except Exception:
        pass
    return result


def classify_profile(goal: str, recall_db: str = RECALL_DB) -> dict[str, Any]:
    """Classify a task goal into optimal tool profile(s) using lexical + OKF graph signals."""
    tokens = set(_tokenize(goal))
    g_lower = goal.lower()

    domain_scores: dict[str, float] = defaultdict(float)

    # 1. Extended domain synonym affinity
    for dom, vocab in DOMAIN_SYNONYMS.items():
        for term in vocab:
            if term in tokens or (len(term) > 4 and term in g_lower):
                domain_scores[dom] += 1.5

    # 2. OKF Graph PPR propagation signal (for explicit file/symbol/module references)
    has_code_artifact_hint = bool(
        re.search(r"\b([a-z0-9_]+\.(sh|py|rs|js|sql|jsonld|md)|urn:blue-lodge:|[a-z0-9_]+_[a-z0-9_]+)\b", g_lower)
    )
    ppr_ctx = okf_ppr_context(goal, recall_db=recall_db)
    if has_code_artifact_hint:
        for dom, sc in ppr_ctx["domain_scores"].items():
            domain_scores[dom] += sc * 2.0

    # Filter domains exceeding confidence threshold
    active = [
        (dom, sc)
        for dom, sc in domain_scores.items()
        if sc >= 1.2
    ]
    active.sort(key=lambda x: x[1], reverse=True)

    if not active:
        profile_str = "default"
    elif len(active) == 1:
        profile_str = active[0][0]
    else:
        order = ["research", "code", "ops", "social", "crypto"]
        selected = {d for d, _ in active[:3]}
        ordered = [d for d in order if d in selected]
        profile_str = ordered[0] + "".join(f", +{d}" for d in ordered[1:])

    return {
        "profile": profile_str,
        "domain_scores": {k: round(v, 4) for k, v in domain_scores.items()},
        "top_okf_modules": sorted(
            ppr_ctx["module_scores"].items(), key=lambda x: x[1], reverse=True
        )[:5],
    }


def rank_tools(
    query: str,
    limit: int = 8,
    tau_ms: float = 2500.0,
    gamma: float = 0.0004,
    xi: float = 1.0,
    tools_fts_db: str = TOOLS_FTS_DB,
    recall_db: str = RECALL_DB,
) -> dict[str, Any]:
    """Rank tools and bundles using BM25 + OKF PPR + Contextual Bandit Latency-Penalized Utility."""
    tokens = _tokenize(query)
    telemetry, total_calls = load_tool_telemetry(recall_db)
    ppr_ctx = okf_ppr_context(query, recall_db=recall_db)
    exported_syms = ppr_ctx["exported_symbols"]

    candidates: list[dict[str, Any]] = []
    if os.path.isfile(tools_fts_db) and tokens:
        try:
            conn = sqlite3.connect(tools_fts_db)
            conn.row_factory = sqlite3.Row
            fts_tokens = [re.sub(r"[^a-zA-Z0-9]", "", t) for t in tokens if len(re.sub(r"[^a-zA-Z0-9]", "", t)) >= 2]
            if fts_tokens:
                fts_q = " OR ".join(f"{t}*" for t in fts_tokens[:12])
                rows = conn.execute(
                    """SELECT name, bundle, description, tags, bm25(tools_fts) AS raw_bm25
                       FROM tools_fts
                       WHERE tools_fts MATCH ?
                       ORDER BY raw_bm25 ASC LIMIT 25;""",
                    (fts_q,),
                ).fetchall()
                for rank_i, r in enumerate(rows):
                    t_name = r["name"]
                    bundle = r["bundle"]
                    raw_bm25 = abs(float(r["raw_bm25"] or 1.0))
                    s_sem = min(1.0, raw_bm25 / (raw_bm25 + 2.0)) * (1.0 / (1.0 + 0.08 * rank_i))

                    # OKF PPR structural boost if tool or its bundle domain is activated in OKF graph
                    b_clean = bundle.lstrip("+_")
                    s_ppr = float(ppr_ctx["domain_scores"].get(b_clean, 0.0))
                    if t_name in exported_syms:
                        s_ppr += 0.5

                    t_stat = telemetry.get(t_name, {})
                    calls = int(t_stat.get("calls", 0))
                    succ = int(t_stat.get("success", 0))
                    ewma_ms = float(t_stat.get("ewma_ms", 250.0))
                    p95_ms = float(t_stat.get("p95_ms", 500.0))

                    mu_hat = compute_bandit_reliability(calls, succ, total_calls)
                    s_pen = compute_latency_penalty(ewma_ms, p95_ms, tau_ms=tau_ms, gamma=gamma, xi=xi)

                    utility = ((0.75 * s_sem + 0.25 * s_ppr) * mu_hat) / s_pen
                    candidates.append({
                        "tool": t_name,
                        "bundle": bundle,
                        "utility": round(utility, 5),
                        "semantic_score": round(s_sem, 4),
                        "okf_ppr_score": round(s_ppr, 4),
                        "bandit_reliability": round(mu_hat, 4),
                        "latency_penalty": round(s_pen, 4),
                        "ewma_latency_ms": round(ewma_ms, 1),
                        "calls": calls,
                    })
            conn.close()
        except Exception:
            pass

    candidates.sort(key=lambda x: x["utility"], reverse=True)
    top_candidates = candidates[:limit]

    # Aggregate bundle scores for non-bedrock bundles
    bundle_scores: dict[str, float] = defaultdict(float)
    for c in top_candidates:
        b = c["bundle"]
        if b and b != "_bedrock":
            bundle_scores[b] += c["utility"]

    best_bundle = ""
    if bundle_scores:
        best_bundle = max(bundle_scores.items(), key=lambda x: x[1])[0]

    return {
        "query": query,
        "best_bundle": best_bundle,
        "latency_budget_ms": tau_ms,
        "candidates": top_candidates,
    }


def parse_workflow_file(filepath: str) -> dict[str, Any]:
    """Parse YAML frontmatter and body capabilities from a .agent.md workflow file."""
    name = re.sub(r"\.(agent\.)?md$", "", os.path.basename(filepath))
    desc = f"Workflow: {name}"
    arg_hint = ""
    target = ""
    keywords: list[str] = []
    body = ""

    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except Exception:
        return {
            "name": name,
            "description": desc,
            "argument_hint": arg_hint,
            "target": target,
            "file": filepath,
        }

    if content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            fm_raw = parts[1]
            body = parts[2]
            try:
                if yaml is None:
                    raise ImportError("PyYAML not available")
                fm = yaml.safe_load(fm_raw)
                if isinstance(fm, dict):
                    if fm.get("name"):
                        name = str(fm["name"]).strip()
                    if fm.get("description"):
                        desc = str(fm["description"]).strip()
                    if fm.get("argument-hint"):
                        arg_hint = str(fm["argument-hint"]).strip()
                    if fm.get("target"):
                        target = str(fm["target"]).strip()
                    if isinstance(fm.get("keywords"), list):
                        keywords = [str(k) for k in fm["keywords"]]
            except Exception:
                # Line-by-line fallback if YAML contains unquoted colons
                for line in fm_raw.splitlines():
                    m = re.match(r"^([a-zA-Z0-9_-]+):\s*(.+)$", line.strip())
                    if m:
                        k, v = m.group(1).lower(), m.group(2).strip().strip("\"'")
                        if k == "name" and v:
                            name = v
                        elif k == "description" and v:
                            desc = v
                        elif k == "argument-hint" and v:
                            arg_hint = v
                        elif k == "target" and v:
                            target = v
    else:
        body = content

    # Extract referenced paths/commands from workflow body
    refs = set(re.findall(r"\b(?:lib/[a-zA-Z0-9_/\.-]+|commands/[a-zA-Z0-9_/\.-]+|tests/[a-zA-Z0-9_/\.-]+)\b", body))
    return {
        "name": name,
        "description": desc,
        "argument_hint": arg_hint,
        "target": target,
        "keywords": keywords,
        "referenced_paths": sorted(refs),
        "file": filepath,
    }


def select_workflow(
    query: str,
    workdir: str = LODGE_DIR,
    limit: int = 5,
    recall_db: str = RECALL_DB,
) -> dict[str, Any]:
    """Select the optimal subagent workflow (.agent.md) using capability graph & OKF PPR."""
    wf_dir = os.path.join(workdir, ".agents", "workflows")
    if not os.path.isdir(wf_dir):
        wf_dir = os.path.join(LODGE_DIR, ".agents", "workflows")

    q_tokens = set(_tokenize(query))
    q_lower = query.lower()
    ppr_ctx = okf_ppr_context(query, recall_db=recall_db)
    mod_scores = ppr_ctx["module_scores"]
    sub_scores = ppr_ctx["subsystem_scores"]

    # Map subsystems to specialist workflows
    SUBSYSTEM_TO_WORKFLOW = {
        "urn:blue-lodge:subsystem:core": "core-specialist",
        "urn:blue-lodge:subsystem:commands": "commands-specialist",
        "urn:blue-lodge:subsystem:ui": "ui-specialist",
        "urn:blue-lodge:subsystem:docs": "the-chronicler",
        "urn:blue-lodge:subsystem:sys": "quartermaster",
    }

    scored: list[dict[str, Any]] = []
    for fp in sorted(glob.glob(os.path.join(wf_dir, "*.agent.md"))):
        meta = parse_workflow_file(fp)
        w_name = meta["name"]
        stem = os.path.basename(fp).replace(".agent.md", "")
        rel_fp = os.path.relpath(fp, LODGE_DIR)
        wf_uri = f"urn:blue-lodge:module:{rel_fp}"

        score = 0.0
        reasons: list[str] = []

        # 1. Direct name / stem match
        if stem in q_lower or w_name.lower() in q_lower:
            score += 5.0
            reasons.append("direct_name_match")

        # 2. Lexical overlap with description, argument_hint, and referenced_paths
        desc_tokens = set(_tokenize(meta["description"] + " " + meta["argument_hint"] + " " + " ".join(meta["referenced_paths"])))
        overlap = q_tokens & desc_tokens
        if overlap:
            lex_sc = 0.65 * len(overlap)
            score += lex_sc
            reasons.append(f"lexical({','.join(sorted(list(overlap))[:4])})")

        # 3. OKF PPR score on the workflow node itself or its referenced codebase paths
        if wf_uri in mod_scores:
            score += mod_scores[wf_uri] * 4.0
            reasons.append("okf_workflow_node")
        for ref_p in meta["referenced_paths"]:
            ref_uri = f"urn:blue-lodge:module:{ref_p}"
            if ref_uri in mod_scores:
                score += mod_scores[ref_uri] * 3.0
                reasons.append(f"okf_dep({ref_p})")

        # 4. Subsystem-to-specialist affinity from OKF PPR
        for sub_u, sp_name in SUBSYSTEM_TO_WORKFLOW.items():
            if stem == sp_name and sub_scores.get(sub_u, 0.0) > 0:
                score += sub_scores[sub_u] * 2.5
                reasons.append(f"subsystem({sub_u.split(':')[-1]})")

        # 5. Role-specific intent boosts
        if stem in ("tester", "tests-specialist") and ({"test", "tests", "verify", "regression", "assert", "ci"} & q_tokens):
            score += 2.2
            reasons.append("testing_intent")
        elif stem == "the-architect" and ({"architecture", "design", "plan", "blueprint", "spec"} & q_tokens):
            score += 2.2
            reasons.append("architecture_intent")
        elif stem == "the-tyler" and ({"security", "audit", "vulnerability", "secret", "rbac", "auth", "pgp"} & q_tokens):
            score += 2.2
            reasons.append("security_intent")
        elif stem == "the-chronicler" and ({"doc", "docs", "documentation", "readme", "wiki", "index"} & q_tokens):
            score += 2.2
            reasons.append("docs_intent")
        elif stem == "quartermaster" and ({"dependency", "install", "docker", "env", "package", "tooling"} & q_tokens):
            score += 2.0
            reasons.append("tooling_intent")

        if score > 0:
            scored.append({
                "name": stem,
                "display_name": w_name,
                "file": fp,
                "score": round(score, 4),
                "description": meta["description"],
                "reasons": reasons,
            })

    scored.sort(key=lambda x: x["score"], reverse=True)
    if not scored:
        # Default fallback to dispatcher
        disp_fp = os.path.join(wf_dir, "dispatcher.agent.md")
        if os.path.isfile(disp_fp):
            scored.append({
                "name": "dispatcher",
                "display_name": "dispatcher",
                "file": disp_fp,
                "score": 0.1,
                "description": "Default workflow dispatcher",
                "reasons": ["default_fallback"],
            })

    return {
        "query": query,
        "selected": scored[0] if scored else None,
        "candidates": scored[:limit],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Capability Graph & Contextual-Bandit Router")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_cls = sub.add_parser("classify-profile", help="Classify task goal into tool profile(s)")
    p_cls.add_argument("goal", help="Task goal text")
    p_cls.add_argument("--json", action="store_true")

    p_rank = sub.add_parser("rank-tools", help="Rank tools and bundles using MoA bandit + OKF PPR")
    p_rank.add_argument("query", help="Tool capability search query")
    p_rank.add_argument("--limit", type=int, default=8)
    p_rank.add_argument("--latency-budget", type=float, default=2500.0)
    p_rank.add_argument("--json", action="store_true")

    p_wf = sub.add_parser("select-workflow", help="Select optimal subagent workflow for a task")
    p_wf.add_argument("query", help="Task description or role query")
    p_wf.add_argument("--workdir", default=LODGE_DIR)
    p_wf.add_argument("--limit", type=int, default=5)
    p_wf.add_argument("--json", action="store_true")

    p_meta = sub.add_parser("parse-workflow-meta", help="Parse .agent.md YAML frontmatter")
    p_meta.add_argument("file", help="Path to .agent.md file")

    args = parser.parse_args()

    if args.cmd == "classify-profile":
        res = classify_profile(args.goal)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(res["profile"])
        return 0

    if args.cmd == "rank-tools":
        res = rank_tools(args.query, limit=args.limit, tau_ms=args.latency_budget)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            for c in res["candidates"]:
                print(f"{c['bundle']}|{c['tool']}|{c['utility']}")
        return 0

    if args.cmd == "select-workflow":
        res = select_workflow(args.query, workdir=args.workdir, limit=args.limit)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            sel = res.get("selected")
            if sel:
                print(sel["file"])
            else:
                return 1
        return 0

    if args.cmd == "parse-workflow-meta":
        meta = parse_workflow_file(args.file)
        print(
            json.dumps(
                {
                    "name": meta["name"],
                    "description": meta["description"],
                    "argument_hint": meta["argument_hint"],
                    "target": meta["target"],
                    "file": meta["file"],
                }
            )
        )
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
