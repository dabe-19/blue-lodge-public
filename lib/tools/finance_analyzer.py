#!/usr/bin/env python3
"""Financial OSINT Analyzer for Blue Lodge.

Layers on top of the Sovereign OSINT Web Watcher to provide financial signal
extraction and funding opportunity analysis. Designed to help identify and
prioritize revenue streams for open-source development projects.

Signal Categories:
  - GRANT:      Government/foundation grants (SBIR, STTR, NSF, DARPA, NLNet)
  - VC:         Venture capital activity in developer tooling / AI infrastructure
  - SPONSOR:    Open-source sponsorship programs (GitHub Sponsors, OpenCollective)
  - BOUNTY:     Bug bounties, code bounties, and challenge prizes
  - CONTRACT:   Government / enterprise contract opportunities (SAM.gov, etc.)
  - FLIP:       Arbitrage / resale opportunities across marketplaces
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("[ERROR] PyYAML is required but not installed.", file=sys.stderr)
    sys.exit(1)

# Import the base watcher engine for shared primitives
sys.path.insert(0, str(Path(__file__).parent))
try:
    from osint_watcher import (
        emit_event_bus,
        extract_price,
        get_george_dir,
        get_lodge_dir,
        hash_item,
        load_seen_state,
        query_searxng,
        save_seen_state,
    )
except ImportError:
    print("[ERROR] osint_watcher.py must exist in the same directory.", file=sys.stderr)
    sys.exit(1)


# ── Signal Classification ────────────────────────────────────────────

CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "GRANT": [
        r"(?i)\b(grant|funding opportunity|SBIR|STTR|NSF|DARPA|NLNet|"
        r"open.?technology.?fund|prototype.?fund|sovereign.?tech|"
        r"RFA|RFP|notice of funding|FOA|BAA|solicitation|award)\b",
    ],
    "VC": [
        r"(?i)\b(series [a-d]|seed round|pre.?seed|venture capital|"
        r"raised \$|funding round|valuation|investor|accelerator|"
        r"Y.?Combinator|Techstars|a16z|sequoia|benchmark)\b",
    ],
    "SPONSOR": [
        r"(?i)\b(sponsor|open.?collective|github.?sponsors|"
        r"tidelift|thanks\.dev|stackaid|issuehunt|"
        r"open.?source.?funding|sustain|maintenance.?fund)\b",
    ],
    "BOUNTY": [
        r"(?i)\b(bounty|bug.?bounty|code.?bounty|hackathon prize|"
        r"challenge.?prize|reward|gitcoin|immunefi|hackerone|"
        r"bugcrowd|intigriti|synack)\b",
    ],
    "CONTRACT": [
        r"(?i)\b(RFQ|RFP|RFI|contract.?award|SAM\.gov|"
        r"government.?contract|procurement|bid.?opportunity|"
        r"IDIQ|BPA|task.?order|GWAC)\b",
    ],
    "FLIP": [
        r"(?i)\b(below.?market|underpriced|liquidation|"
        r"estate.?sale|bulk.?lot|wholesale|clearance|"
        r"price.?drop|reduced|going.?out.?of.?business)\b",
    ],
}

URGENCY_KEYWORDS: list[tuple[str, int]] = [
    (r"(?i)\b(deadline|closes?|due date|expires?|last day|ending soon)\b", 30),
    (r"(?i)\b(limited|few remaining|almost gone|act now)\b", 20),
    (r"(?i)\b(new|just posted|announced|launched)\b", 10),
    (r"(?i)\b(open|available|accepting)\b", 5),
]


@dataclass
class FinancialSignal:
    """A single scored financial intelligence signal."""
    watcher_id: str
    title: str
    url: str
    domain: str
    snippet: str
    category: str
    relevance_score: int
    urgency_score: int
    composite_score: int
    price_extracted: str | None
    amount_range: str | None
    deadline_hint: str | None
    discovered_at: int
    tags: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def classify_category(text: str) -> tuple[str, int]:
    """Classify text into a funding category and return confidence score."""
    best_cat = "UNKNOWN"
    best_score = 0

    for cat, patterns in CATEGORY_KEYWORDS.items():
        cat_score = 0
        for pat in patterns:
            matches = re.findall(pat, text)
            cat_score += len(matches) * 10
        if cat_score > best_score:
            best_score = cat_score
            best_cat = cat

    return best_cat, min(best_score, 100)


def compute_urgency(text: str) -> tuple[int, str | None]:
    """Compute urgency score and extract deadline hints."""
    score = 0
    deadline_hint = None

    for pattern, weight in URGENCY_KEYWORDS:
        if re.search(pattern, text):
            score += weight

    # Extract explicit deadline patterns
    deadline_patterns = [
        r"(?i)deadline[:\s]+(\w+ \d{1,2},?\s*\d{4})",
        r"(?i)closes?\s+(?:on\s+)?(\w+ \d{1,2},?\s*\d{4})",
        r"(?i)due\s+(?:by\s+)?(\d{1,2}/\d{1,2}/\d{2,4})",
        r"(?i)(?:by|before|until)\s+(\w+ \d{1,2}(?:st|nd|rd|th)?,?\s*\d{4})",
    ]
    for dp in deadline_patterns:
        m = re.search(dp, text)
        if m:
            deadline_hint = m.group(1).strip()
            score += 40
            break

    return min(score, 100), deadline_hint


def extract_amount_range(text: str) -> str | None:
    """Extract funding amount ranges from text."""
    patterns = [
        # "$50,000 - $100,000" or "$50K-$100K"
        r"\$([0-9,]+(?:\.\d+)?[KMB]?)\s*(?:to|-|through)\s*\$([0-9,]+(?:\.\d+)?[KMB]?)",
        # "up to $500,000"
        r"(?i)up\s+to\s+\$([0-9,]+(?:\.\d+)?[KMB]?)",
        # "$1.5M" or "$500K" standalone
        r"\$([0-9,]+(?:\.\d+)?)\s*([KMB])\b",
        # "$1,000,000"
        r"\$([0-9]{1,3}(?:,\d{3}){2,}(?:\.\d+)?)",
    ]

    for pat in patterns:
        m = re.search(pat, text)
        if m:
            return m.group(0).strip()
    return None


def compute_relevance(text: str, watcher_config: dict[str, Any]) -> int:
    """Score relevance based on watcher's relevance_keywords config."""
    score = 0
    relevance_kw = watcher_config.get("relevance_keywords", [])
    for kw in relevance_kw:
        if re.search(re.escape(kw), text, re.IGNORECASE):
            score += 15

    # Boost for financial terms in dev-tool/infra context
    dev_context_patterns = [
        r"(?i)\b(developer tool|devtool|infrastructure|platform|"
        r"open.?source|CLI|API|framework|automation|AI|ML|LLM)\b",
    ]
    for pat in dev_context_patterns:
        matches = re.findall(pat, text)
        score += len(matches) * 5

    return min(score, 100)


def analyze_result(
    result: dict[str, Any],
    watcher_config: dict[str, Any],
) -> FinancialSignal:
    """Run full financial analysis pipeline on a single search result."""
    title = result.get("title", "")
    url = result.get("url", "")
    snippet = result.get("content", "")
    domain = result.get("parsed_url", ["", ""])[1] if result.get("parsed_url") else ""
    if not domain:
        from urllib.parse import urlparse
        domain = urlparse(url).netloc

    combined_text = f"{title} {snippet}"

    category, cat_confidence = classify_category(combined_text)
    urgency, deadline_hint = compute_urgency(combined_text)
    relevance = compute_relevance(combined_text, watcher_config)
    price = extract_price(combined_text)
    amount_range = extract_amount_range(combined_text)

    # Composite score: weighted blend
    composite = int(
        relevance * 0.40
        + cat_confidence * 0.30
        + urgency * 0.30
    )

    # Bonus for extractable dollar amounts (actionable signals)
    if amount_range:
        composite = min(composite + 15, 100)
    if deadline_hint:
        composite = min(composite + 10, 100)

    # Build tags
    tags = []
    if amount_range:
        tags.append(f"amount:{amount_range}")
    if deadline_hint:
        tags.append(f"deadline:{deadline_hint}")
    if price:
        tags.append(f"price:{price}")

    # Engine tag
    engine = result.get("engine", "")
    if engine:
        tags.append(f"engine:{engine}")

    return FinancialSignal(
        watcher_id=watcher_config.get("id", "unknown"),
        title=title,
        url=url,
        domain=domain,
        snippet=snippet[:300],
        category=category,
        relevance_score=relevance,
        urgency_score=urgency,
        composite_score=composite,
        price_extracted=price,
        amount_range=amount_range,
        deadline_hint=deadline_hint,
        discovered_at=int(time.time()),
        tags=tags,
    )


# ── Dossier Generation ───────────────────────────────────────────────

def write_finance_dossier(
    signals: list[FinancialSignal],
    dossier_path: Path,
    watcher_name: str,
) -> None:
    """Write a structured financial intelligence dossier."""
    dossier_path.parent.mkdir(parents=True, exist_ok=True)

    ts_str = time.strftime("%Y-%m-%d %H:%M:%S")
    header_exists = dossier_path.exists()

    with open(dossier_path, "a", encoding="utf-8") as f:
        if not header_exists:
            f.write(f"# Financial OSINT Intelligence Brief: {watcher_name}\n\n")
            f.write(f"Generated by Sovereign Financial Analyzer\n\n")
            f.write("---\n\n")

        # Group by category
        by_cat: dict[str, list[FinancialSignal]] = {}
        for sig in signals:
            by_cat.setdefault(sig.category, []).append(sig)

        f.write(f"\n## Sweep: {ts_str}\n\n")
        f.write(f"**Signals Detected:** {len(signals)}\n\n")

        for cat in ["GRANT", "VC", "SPONSOR", "BOUNTY", "CONTRACT", "FLIP", "UNKNOWN"]:
            cat_signals = by_cat.get(cat, [])
            if not cat_signals:
                continue

            # Sort by composite score descending
            cat_signals.sort(key=lambda s: s.composite_score, reverse=True)

            f.write(f"### [{cat}] ({len(cat_signals)} signals)\n\n")
            f.write("| Score | Title | Amount | Deadline | Domain |\n")
            f.write("| :---: | --- | --- | --- | --- |\n")

            for sig in cat_signals:
                score_bar = _score_bar(sig.composite_score)
                amount = sig.amount_range or sig.price_extracted or "--"
                deadline = sig.deadline_hint or "--"
                f.write(
                    f"| {score_bar} {sig.composite_score} "
                    f"| [{sig.title[:80]}]({sig.url}) "
                    f"| {amount} "
                    f"| {deadline} "
                    f"| {sig.domain} |\n"
                )

            f.write("\n")


def _score_bar(score: int) -> str:
    """Render a text-based priority indicator."""
    if score >= 70:
        return "[HIGH]"
    elif score >= 40:
        return "[MED]"
    else:
        return "[LOW]"


# ── Sovereign LLM Synthesis Pipeline ─────────────────────────────────

def synthesize_signals_with_llm(
    signals: list[FinancialSignal],
    settings: dict[str, Any],
) -> dict[str, Any]:
    """Delegate synthesis to the Sovereign Financial & OSINT Synthesis Subagent.
    
    Conforms to the Open Knowledge Format standard (okf/standards/subagent_sandbox_lifecycle.jsonld)
    and POSIX FIFO async IPC protocol (okf/standards/fifo_async_ipc_protocol.jsonld).
    Registers execution in .george/subagents.json for full observability in the Autonomic Task Bay.
    """
    synth_cfg = settings.get("synthesis", {})
    max_signals = synth_cfg.get("max_signals_to_analyze", 6)
    
    # Filter to highest composite score opportunities
    top_candidates = sorted(signals, key=lambda s: s.composite_score, reverse=True)[:max_signals]
    if not top_candidates:
        return {
            "narrative": "No signals met threshold for synthesis analysis.",
            "top_targets": [],
            "source": "none",
        }

    # Format structured signals payload
    payload = [s.to_dict() for s in top_candidates]
    worker_script = get_lodge_dir() / "lib" / "agents" / "synthesis_worker.sh"
    
    output = ""
    source_used = "sovereign_subagent_fifo"

    if worker_script.exists():
        import tempfile
        import subprocess
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
            json.dump(payload, tf)
            spool_file = tf.name

        try:
            cmd = ["bash", str(worker_script), spool_file]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            output = proc.stdout.strip()
            if not output and proc.stderr:
                output = proc.stderr.strip()
        except Exception as e:
            output = f"Synthesis subagent execution error: {e}"
            source_used = "subagent_error"
        finally:
            try:
                os.remove(spool_file)
            except OSError:
                pass
    else:
        output = "synthesis_worker.sh not found"
        source_used = "error"

    return {
        "narrative": output,
        "source": source_used,
        "top_targets": [
            {
                "title": s.title,
                "score": s.composite_score,
                "category": s.category,
                "amount": s.amount_range or s.price_extracted,
                "deadline": s.deadline_hint,
                "url": s.url
            }
            for s in top_candidates
        ]
    }


def append_synthesis_to_dossier(
    dossier_path: Path,
    synthesis_data: dict[str, Any],
    signal_count: int,
) -> None:
    """Append executive synthesis brief to the intelligence dossier (handled by subagent worker)."""
    pass


# ── Sweep Orchestration ──────────────────────────────────────────────

def run_finance_sweep(
    config: dict[str, Any],
    target_id: str | None = None,
    dry_run: bool = False,
    force_synthesize: bool = False,
) -> dict[str, Any]:
    """Execute a full financial OSINT sweep with analysis."""
    settings = config.get("settings", {})
    base_url = settings.get("searxng_url", "http://127.0.0.1:8081")
    state_rel = settings.get("state_file", ".george/ipc/finance_osint_seen.json")
    state_path = get_lodge_dir() / state_rel

    seen_state = load_seen_state(state_path)
    seen_items = seen_state.setdefault("items", {})

    watchers = config.get("watchers", [])
    all_signals: list[FinancialSignal] = []
    results_summary: list[dict[str, Any]] = []
    total_new = 0

    for w in watchers:
        w_id = w.get("id", "unnamed")
        if target_id and w_id != target_id:
            continue
        if not w.get("enabled", True):
            continue

        query = w.get("query", "")
        if not query:
            continue

        time_range = w.get("time_range")
        categories = w.get("categories", ["general"])
        engines = w.get("engines")

        raw_results = query_searxng(
            base_url,
            query,
            time_range=time_range,
            categories=categories,
            engines=engines,
        )

        watcher_signals: list[FinancialSignal] = []

        for r in raw_results:
            url = r.get("url", "")
            title = r.get("title", "")
            if not url or not title:
                continue

            h = hash_item(url, title)
            if h in seen_items and not dry_run:
                continue

            signal = analyze_result(r, w)

            # Apply minimum score threshold
            min_score = w.get("min_composite_score", 0)
            if signal.composite_score < min_score:
                continue

            watcher_signals.append(signal)

            if not dry_run:
                seen_items[h] = {
                    "watcher_id": w_id,
                    "url": url,
                    "title": title,
                    "category": signal.category,
                    "score": signal.composite_score,
                    "first_seen": int(time.time()),
                }

                # Emit typed event to the bus
                event_type = w.get("actions", {}).get("emit_event", "finance_signal")
                emit_event_bus(
                    event_type,
                    signal.to_dict(),
                    source=f"finance_{w_id}",
                )
                total_new += 1

        # Write to dossier
        dossier_rel = w.get("actions", {}).get("dossier_path")
        if dossier_rel and watcher_signals and not dry_run:
            dossier_path = get_lodge_dir() / dossier_rel
            write_finance_dossier(watcher_signals, dossier_path, w.get("name", w_id))

        all_signals.extend(watcher_signals)
        results_summary.append({
            "watcher_id": w_id,
            "query": query,
            "raw_count": len(raw_results),
            "signals_count": len(watcher_signals),
            "top_signals": [
                {
                    "title": s.title[:120],
                    "score": s.composite_score,
                    "category": s.category,
                    "amount": s.amount_range,
                    "url": s.url,
                }
                for s in sorted(watcher_signals, key=lambda x: x.composite_score, reverse=True)[:5]
            ],
        })

    if not dry_run and total_new > 0:
        save_seen_state(state_path, seen_state)

    # Sovereign LLM Synthesis Pipeline
    synth_cfg = settings.get("synthesis", {})
    synth_enabled = synth_cfg.get("enabled", True) or force_synthesize
    synthesis_result: dict[str, Any] | None = None

    if synth_enabled and all_signals:
        synthesis_result = synthesize_signals_with_llm(all_signals, settings)
        
        # Append narrative to main financial dossier
        if not dry_run:
            main_dossier = get_lodge_dir() / "dossiers" / "finance_intel.md"
            append_synthesis_to_dossier(main_dossier, synthesis_result, len(all_signals))

            # Emit synthesis event to event bus
            emit_event_bus(
                "finance_synthesis_complete",
                {
                    "synthesis": synthesis_result.get("narrative", ""),
                    "source": synthesis_result.get("source", ""),
                    "signals_count": len(all_signals),
                    "top_targets": synthesis_result.get("top_targets", []),
                    "timestamp": int(time.time()),
                },
                source="finance_analyzer",
            )

            # High-priority alert if highest score >= 60
            top_opp = max(all_signals, key=lambda s: s.composite_score) if all_signals else None
            if top_opp and top_opp.composite_score >= 60:
                emit_event_bus(
                    "finance_opportunity_alert",
                    {
                        "title": top_opp.title,
                        "category": top_opp.category,
                        "score": top_opp.composite_score,
                        "amount": top_opp.amount_range or top_opp.price_extracted or "Undisclosed",
                        "deadline": top_opp.deadline_hint or "None",
                        "url": top_opp.url,
                        "executive_summary": synthesis_result.get("narrative", "")[:300],
                        "timestamp": int(time.time()),
                    },
                    source="finance_analyzer",
                )

    # Build summary brief
    cat_counts: dict[str, int] = {}
    for s in all_signals:
        cat_counts[s.category] = cat_counts.get(s.category, 0) + 1

    return {
        "status": "ok",
        "dry_run": dry_run,
        "total_new_signals": total_new,
        "watchers_evaluated": len(results_summary),
        "category_breakdown": cat_counts,
        "synthesis": synthesis_result,
        "top_opportunities": [
            {
                "title": s.title[:120],
                "score": s.composite_score,
                "category": s.category,
                "amount": s.amount_range,
                "deadline": s.deadline_hint,
                "url": s.url,
            }
            for s in sorted(all_signals, key=lambda x: x.composite_score, reverse=True)[:10]
        ],
        "results": results_summary,
    }


# ── CLI ──────────────────────────────────────────────────────────────

def load_finance_config(config_path: Path | None = None) -> dict[str, Any]:
    """Load finance-specific OSINT config."""
    if config_path and config_path.exists():
        with open(config_path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    george_cfg = get_george_dir() / "finance_osint.yaml"
    if george_cfg.exists():
        with open(george_cfg, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    template_cfg = get_lodge_dir() / "config" / "finance_osint.yaml"
    if template_cfg.exists():
        with open(template_cfg, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    return {"version": 1, "watchers": []}


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign Financial OSINT Analyzer")
    parser.add_argument("--config", type=Path, help="Path to finance_osint.yaml")
    parser.add_argument("--sweep", action="store_true", help="Execute financial sweep")
    parser.add_argument("--test", type=str, help="Dry-run a specific watcher ID")
    parser.add_argument("--status", action="store_true", help="Show finance watcher status")
    parser.add_argument(
        "--init-template", action="store_true",
        help="Copy default finance config template to .george/",
    )
    parser.add_argument("--brief", action="store_true", help="Print condensed intelligence brief")
    parser.add_argument("--synthesize", action="store_true", help="Force execute LLM synthesis pipeline")

    args = parser.parse_args()

    if args.init_template:
        george_cfg = get_george_dir() / "finance_osint.yaml"
        template_cfg = get_lodge_dir() / "config" / "finance_osint.yaml"
        if not template_cfg.exists():
            print(f"[ERROR] Template not found at {template_cfg}", file=sys.stderr)
            sys.exit(1)
        george_cfg.parent.mkdir(parents=True, exist_ok=True)
        george_cfg.write_text(template_cfg.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"[OK] Initialized {george_cfg}")
        sys.exit(0)

    config = load_finance_config(args.config)

    if args.status:
        watchers = config.get("watchers", [])
        state_rel = config.get("settings", {}).get(
            "state_file", ".george/ipc/finance_osint_seen.json"
        )
        state_path = get_lodge_dir() / state_rel
        seen_state = load_seen_state(state_path)
        total_seen = len(seen_state.get("items", {}))

        # Category breakdown of seen items
        cat_counts: dict[str, int] = {}
        for item in seen_state.get("items", {}).values():
            cat = item.get("category", "UNKNOWN")
            cat_counts[cat] = cat_counts.get(cat, 0) + 1

        print(f"Financial OSINT Watchers: {len(watchers)}")
        print(f"Total Indexed Signals:   {total_seen}")
        if cat_counts:
            print("Category Breakdown:")
            for cat, count in sorted(cat_counts.items()):
                print(f"  {cat}: {count}")
        print()
        for w in watchers:
            status = "ENABLED" if w.get("enabled", True) else "DISABLED"
            print(f"  - [{status}] {w.get('id')}: {w.get('name')} (query: {w.get('query', '')[:60]}...)")
        sys.exit(0)

    if args.test:
        summary = run_finance_sweep(config, target_id=args.test, dry_run=True, force_synthesize=args.synthesize)
        print(json.dumps(summary, indent=2))
        sys.exit(0)

    if args.sweep or args.brief or args.synthesize:
        summary = run_finance_sweep(config, dry_run=False, force_synthesize=args.synthesize)
        if args.brief:
            _print_brief(summary)
        else:
            print(json.dumps(summary, indent=2))
        sys.exit(0)

    # Default: sweep
    summary = run_finance_sweep(config, dry_run=False, force_synthesize=args.synthesize)
    print(json.dumps(summary, indent=2))


def _print_brief(summary: dict[str, Any]) -> None:
    """Print a condensed human-readable intelligence brief."""
    print("=" * 72)
    print("  FINANCIAL OSINT INTELLIGENCE BRIEF")
    print("=" * 72)
    print(f"  Timestamp:    {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  New Signals:  {summary.get('total_new_signals', 0)}")
    print(f"  Watchers Run: {summary.get('watchers_evaluated', 0)}")
    print()

    cats = summary.get("category_breakdown", {})
    if cats:
        print("  Category Breakdown:")
        for cat, count in sorted(cats.items(), key=lambda x: -x[1]):
            print(f"    {cat:12s}  {count}")
        print()

    top = summary.get("top_opportunities", [])
    if top:
        print("  Top Opportunities (by composite score):")
        print("  " + "-" * 68)
        for i, opp in enumerate(top, 1):
            score = opp.get("score", 0)
            cat = opp.get("category", "?")
            title = opp.get("title", "?")[:60]
            amount = opp.get("amount") or "--"
            deadline = opp.get("deadline") or "--"
            print(f"  {i:2d}. [{cat:8s}] (score: {score:3d}) {title}")
            if amount != "--" or deadline != "--":
                print(f"      Amount: {amount}  |  Deadline: {deadline}")
            print(f"      {opp.get('url', '')}")
            print()
    else:
        print("  No new opportunities detected in this sweep.")

    synth = summary.get("synthesis")
    if synth and synth.get("narrative"):
        print("  " + "=" * 68)
        print(f"  STRATEGIC SYNTHESIS ({synth.get('source', 'analysis')})")
        print("  " + "=" * 68)
        for line in synth.get("narrative", "").split("\n"):
            print(f"  {line}")
        print()

    print("=" * 72)


if __name__ == "__main__":
    main()
