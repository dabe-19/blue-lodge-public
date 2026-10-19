#!/usr/bin/env python3
"""Sovereign OSINT Web Watcher & Index Sentinel for Blue Lodge.

Queries SearXNG across search engines for web index events (e.g. secondary marketplace
listings on Poshmark, eBay, Shopify, or threat intel leaks), maintains an atomic
SHA256 seen-ledger, and emits reactive events into the Sovereign Event Bus.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("[ERROR] PyYAML is required but not installed.", file=sys.stderr)
    sys.exit(1)


def get_lodge_dir() -> Path:
    return Path(os.getenv("LODGE_DIR", str(Path.home() / "blue-lodge")))


def get_george_dir() -> Path:
    lodge_dir = get_lodge_dir()
    return Path(os.getenv("GEORGE_DIR", str(lodge_dir / ".george")))


def load_config(config_path: Path | None = None) -> dict[str, Any]:
    if config_path and config_path.exists():
        with open(config_path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    george_cfg = get_george_dir() / "osint_watchers.yaml"
    if george_cfg.exists():
        with open(george_cfg, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    template_cfg = get_lodge_dir() / "config" / "osint_watchers.yaml.template"
    if template_cfg.exists():
        with open(template_cfg, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    return {"version": 1, "watchers": []}


def load_seen_state(state_path: Path) -> dict[str, Any]:
    if not state_path.exists():
        return {"version": 1, "items": {}}
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"version": 1, "items": {}}


def save_seen_state(state_path: Path, state: dict[str, Any]) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = state_path.with_suffix(f".tmp.{os.getpid()}")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp_path, state_path)


def hash_item(url: str, title: str = "") -> str:
    clean_url = url.split("#")[0].rstrip("/")
    return hashlib.sha256(clean_url.encode("utf-8")).hexdigest()


def extract_price(text: str) -> str | None:
    match = re.search(r"\$([0-9,]+(?:\.[0-9]{2})?)", text)
    if match:
        return f"${match.group(1)}"
    match_cur = re.search(r"([0-9,]+(?:\.[0-9]{2})?)\s*(USD|EUR|GBP)", text, re.IGNORECASE)
    if match_cur:
        return f"{match_cur.group(1)} {match_cur.group(2).upper()}"
    return None


def query_searxng(
    base_url: str,
    query: str,
    time_range: str | None = None,
    categories: list[str] | None = None,
    engines: list[str] | None = None,
    timeout: float = 8.0,
) -> list[dict[str, Any]]:
    """Watcher search — delegates to the unified search router (refinement P4).

    Watchers run unattended, so caller=cron: keyless SearXNG -> Brave (budgeted) -> DDG,
    never paid Serper. Result dicts keep the legacy keys (title/url/content/engine).
    """
    os.environ.setdefault("SEARXNG_URL", base_url.rstrip("/"))
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import search_router  # noqa: E402

        cat = (categories or ["general"])[0]
        return search_router.results_list(
            query, category=cat, max_results=20, time_range=time_range,
            engines=",".join(engines) if engines else None, caller="cron",
        )
    except Exception as e:  # router must never crash a watcher sweep
        print(f"[WARN] search router failed for '{query}': {e}", file=sys.stderr)
        return []


_PIPE_BUF_SAFE = 3900  # envelopes must stay below PIPE_BUF (4096) for atomic FIFO writes


def _bash_emit(event_type: str, payload: dict[str, Any], source: str) -> bool:
    """Injection-safe fallback: values are passed as positional args, never interpolated.
    event_bus_emit handles spill-to-disk for large payloads and spools when the bus is down."""
    script = 'source "$1/lib/ipc/event_bus.sh" 2>/dev/null && event_bus_emit "$2" "$3" "$4"'
    try:
        r = subprocess.run(
            ["bash", "-c", script, "_", str(get_lodge_dir()), event_type, json.dumps(payload), source],
            check=False, timeout=5.0, capture_output=True,
        )
        return r.returncode == 0
    except Exception:
        return False


def emit_event_bus(event_type: str, payload: dict[str, Any], source: str = "osint_watcher") -> bool:
    george_dir = get_george_dir()
    fifo_path = Path(os.getenv("EVENT_BUS_FIFO", str(george_dir / "ipc" / "event_bus.fifo")))

    ts = int(time.time())
    evt_id = f"evt_{ts}_{os.getpid()}_{hashlib.md5(str(payload).encode()).hexdigest()[:6]}"
    try:
        depth = int(os.getenv("EVENT_DEPTH", "0"))
    except ValueError:
        depth = 0
    envelope: dict[str, Any] = {
        "event_id": evt_id,
        "type": event_type,
        "source": source,
        "payload": payload,
        "depth": depth,
        "timestamp": ts,
    }
    if os.getenv("EVENT_ID"):
        envelope["parent_event_id"] = os.environ["EVENT_ID"]
    data = (json.dumps(envelope, separators=(",", ":")) + "\n").encode("utf-8")

    # Fast path: one atomic write(2) of a complete line. Oversized envelopes or a
    # missing/saturated bus go through event_bus_emit (spill + durable spool).
    if len(data) <= _PIPE_BUF_SAFE and fifo_path.exists():
        try:
            fd = os.open(str(fifo_path), os.O_WRONLY | os.O_NONBLOCK)
            try:
                if os.write(fd, data) == len(data):
                    return True
            finally:
                os.close(fd)
        except (BlockingIOError, OSError):
            pass
    return _bash_emit(event_type, payload, source)


def append_to_dossier(dossier_rel: str, item: dict[str, Any], watcher_name: str) -> None:
    lodge_dir = get_lodge_dir()
    dossier_path = lodge_dir / dossier_rel
    dossier_path.parent.mkdir(parents=True, exist_ok=True)

    file_exists = dossier_path.exists()
    ts_str = time.strftime("%Y-%m-%d %H:%M:%S")

    deal_info = item.get("compute_eval")
    grade_str = "--"
    unit_cost_str = "--"
    if deal_info:
        verif = deal_info.get("verification") or item.get("verification")
        if verif and not verif.get("is_authentic"):
            grade_str = f"~~[{deal_info['deal_grade']} {deal_info['discount_pct']:+.1f}%]~~ ⚠️ {verif.get('verdict')}"
        elif deal_info.get("is_deal"):
            v_badge = " [VERIFIED]" if (verif and verif.get("is_authentic")) else ""
            grade_str = f"**[{deal_info['deal_grade']} {deal_info['discount_pct']:+.1f}%]{v_badge}**"
        else:
            grade_str = f"({deal_info['deal_grade']})"
        unit_cost_str = f"${deal_info['unit_cost']:.2f}/GB"

    with open(dossier_path, "a", encoding="utf-8") as f:
        if not file_exists:
            f.write(f"# OSINT Discovery Dossier: {watcher_name}\n\n")
            f.write("| Timestamp | Grade | Title | Price | Unit Cost | Listing Link | Domain |\n")
            f.write("| --- | --- | --- | --- | --- | --- | --- |\n")
        price = item.get("price") or "N/A"
        f.write(f"| {ts_str} | {grade_str} | [{item['title']}]({item['url']}) | {price} | {unit_cost_str} | [Open Listing]({item['url']}) | {item.get('domain', 'N/A')} |\n")


def run_sweep(config: dict[str, Any], target_id: str | None = None, dry_run: bool = False) -> dict[str, Any]:
    settings = config.get("settings", {})
    base_url = settings.get("searxng_url", "http://127.0.0.1:8081")
    state_rel = settings.get("state_file", ".george/ipc/osint_seen.json")
    state_path = get_lodge_dir() / state_rel

    seen_state = load_seen_state(state_path)
    seen_items = seen_state.setdefault("items", {})

    watchers = config.get("watchers", [])
    results_summary: list[dict[str, Any]] = []

    total_new_events = 0

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
        criteria = w.get("match_criteria", {})
        title_regex = criteria.get("title_regex")
        exclude_regex = criteria.get("exclude_regex")
        actions = w.get("actions", {})
        emit_event_type = actions.get("emit_event", "osint_listing")
        dossier_path = actions.get("dossier_path")
        auto_fetch = actions.get("auto_fetch", False)

        raw_results = query_searxng(
            base_url,
            query,
            time_range=time_range,
            categories=categories,
            engines=engines,
        )

        matched_new: list[dict[str, Any]] = []

        for r in raw_results:
            title = r.get("title", "")
            url = r.get("url", "")
            snippet = r.get("content", "")
            if not url or not title:
                continue

            # Check criteria
            if title_regex and not re.search(title_regex, title):
                continue
            if exclude_regex and re.search(exclude_regex, f"{title} {snippet}"):
                continue

            h = hash_item(url, title)
            if h in seen_items and not dry_run:
                continue

            parsed_url = urllib.parse.urlparse(url)
            domain = parsed_url.netloc
            price = extract_price(f"{title} {snippet}")

            # Compute valuation and spec extraction
            price_val = None
            if price:
                try:
                    price_val = float(re.sub(r"[^\d.]", "", price))
                except Exception:
                    pass

            deal_info = None
            if price_val:
                try:
                    from event_store import evaluate_compute_listing
                    deal_info = evaluate_compute_listing(title, price_val, url, source=domain, snippet=snippet)
                except Exception:
                    pass

            item_payload = {
                "watcher_id": w_id,
                "watcher_name": w.get("name", w_id),
                "title": title,
                "url": url,
                "domain": domain,
                "snippet": snippet,
                "price": price,
                "compute_eval": deal_info,
                "is_deal": bool(deal_info and deal_info.get("is_deal")),
                "deal_grade": deal_info.get("deal_grade", "NONE") if deal_info else "NONE",
                "engine": r.get("engine", "searxng"),
                "discovered_at": int(time.time()),
            }

            matched_new.append(item_payload)

            if not dry_run:
                seen_items[h] = {
                    "watcher_id": w_id,
                    "url": url,
                    "title": title,
                    "first_seen": int(time.time()),
                }

                # Emit primary event to Event Bus
                emit_event_bus(emit_event_type, item_payload, source=f"osint_{w_id}")
                total_new_events += 1

                # If evaluated as high-alpha deal, execute Agentic Deal Verification Graph
                if deal_info and deal_info.get("is_deal"):
                    try:
                        from deal_verifier import verify_deal_candidate
                        v_res = verify_deal_candidate(
                            hardware_id=deal_info["hardware_id"],
                            model_name=deal_info["model"],
                            price=deal_info["observed_price_usd"],
                            target_fmv=deal_info["target_fmv_usd"],
                            url=url,
                            raw_title=title,
                            deal_alert_id=deal_info.get("deal_alert_id"),
                            observation_id=deal_info.get("observation_id"),
                        )
                        v_dict = {
                            "is_authentic": v_res.is_authentic,
                            "verdict": v_res.verdict,
                            "confidence": v_res.confidence,
                            "reasoning": v_res.reasoning,
                        }
                        deal_info["verification"] = v_dict
                        item_payload["verification"] = v_dict

                        # Only broadcast high-priority compute_deal_alert if verified authentic
                        if v_res.is_authentic:
                            emit_event_bus("compute_deal_alert", deal_info, source=f"osint_{w_id}")
                        else:
                            print(f"[VERIFIER REJECTED] {deal_info['model']} at ${deal_info['observed_price_usd']:.2f}: {v_res.verdict} ({v_res.reasoning})", file=sys.stderr)
                    except Exception as e:
                        # Fallback: emit alert if verification graph fails
                        emit_event_bus("compute_deal_alert", deal_info, source=f"osint_{w_id}")

                # Dossier Append
                if dossier_path:
                    append_to_dossier(dossier_path, item_payload, w.get("name", w_id))

                # Optional Deep Fetch via Lodge Web Command
                if auto_fetch:
                    fetch_cmd = f"bash {get_lodge_dir()}/commands/web.sh fetch '{url}' >/dev/null 2>&1 &"
                    subprocess.Popen(fetch_cmd, shell=True)

        results_summary.append({
            "watcher_id": w_id,
            "query": query,
            "raw_count": len(raw_results),
            "new_count": len(matched_new),
            "items": matched_new,
        })

    if not dry_run and total_new_events > 0:
        save_seen_state(state_path, seen_state)

    return {
        "status": "ok",
        "dry_run": dry_run,
        "total_new_events": total_new_events,
        "watchers_evaluated": len(results_summary),
        "results": results_summary,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign OSINT Web Watcher")
    parser.add_argument("--config", type=Path, help="Path to osint_watchers.yaml")
    parser.add_argument("--sweep", action="store_true", help="Execute sweep across active watchers")
    parser.add_argument("--test", type=str, help="Test a specific watcher ID without committing state")
    parser.add_argument("--status", action="store_true", help="Display watcher and seen items status")
    parser.add_argument("--init-template", action="store_true", help="Initialize active YAML config from template")

    args = parser.parse_args()

    if args.init_template:
        george_cfg = get_george_dir() / "osint_watchers.yaml"
        template_cfg = get_lodge_dir() / "config" / "osint_watchers.yaml.template"
        if not template_cfg.exists():
            print(f"[ERROR] Template not found at {template_cfg}", file=sys.stderr)
            sys.exit(1)
        george_cfg.parent.mkdir(parents=True, exist_ok=True)
        george_cfg.write_text(template_cfg.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"[OK] Initialized {george_cfg}")
        sys.exit(0)

    config = load_config(args.config)

    if args.status:
        watchers = config.get("watchers", [])
        state_rel = config.get("settings", {}).get("state_file", ".george/ipc/osint_seen.json")
        state_path = get_lodge_dir() / state_rel
        seen_state = load_seen_state(state_path)
        total_seen = len(seen_state.get("items", {}))

        print(f"Configured Watchers: {len(watchers)}")
        print(f"Total Seen Items:   {total_seen}")
        for w in watchers:
            status = "ENABLED" if w.get("enabled", True) else "DISABLED"
            print(f"  - [{status}] {w.get('id')}: {w.get('name')} (query: {w.get('query')})")
        sys.exit(0)

    if args.test:
        summary = run_sweep(config, target_id=args.test, dry_run=True)
        print(json.dumps(summary, indent=2))
        sys.exit(0)

    if args.sweep:
        summary = run_sweep(config, dry_run=False)
        print(json.dumps(summary, indent=2))
        sys.exit(0)

    # Default action: run sweep
    summary = run_sweep(config, dry_run=False)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
