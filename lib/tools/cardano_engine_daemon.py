#!/usr/bin/env python3
"""
Sovereign Cardano Unified Engine Daemon (UCOM Tier 3 Daemon)
Consolidates background operations into a single deterministic engine:
1. Passive Plutus UTxO & Resting Limit Order Lifecycle Watcher (Cardano DEX Fills)
2. Option C Auto-Consolidation & Autonomous Ladder Lower-Rung Pruning
3. Multi-Headed Pair Ticker Scraper (GeckoTerminal / DEX Pools)
4. Active Breakout Stop Reactor & Support Invalidation Disarm Traps

Supports:
  --once      : Runs a single unified cycle and exits
  --daemon    : Runs continuous background daemon with graceful signal handling
  --status    : Queries daemon health, PID, and cycle telemetry
  --stop      : Signals running daemon to terminate
"""

from __future__ import annotations

import os
import sys
import json
import time
import signal
import argparse
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and sys.executable != str(_VENV_PY):
    os.execv(str(_VENV_PY), [str(_VENV_PY)] + sys.argv)

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FINANCE_DIR = Path(os.environ.get("FINANCE_DIR", GEORGE_DIR / "finance"))
FINANCE_DIR.mkdir(parents=True, exist_ok=True)

DAEMON_PID_FILE = FINANCE_DIR / "cardano_engine_daemon.pid"
DAEMON_STATUS_FILE = FINANCE_DIR / "cardano_engine_daemon.status.json"
DAEMON_LOG_FILE = FINANCE_DIR / "cardano_engine_daemon.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [cardano_engine_daemon] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stderr),
        logging.FileHandler(str(DAEMON_LOG_FILE), mode="a"),
    ],
)
logger = logging.getLogger("cardano_engine_daemon")

from lib.tools.cardano_order_watcher import poll_order_lifecycle_once
from lib.tools.cardano_pair_ticker import (
    get_active_trigger_assets,
    scrape_pair_tick,
    get_ada_macro_stats,
)
from lib.tools.cardano_stop_reactor import process_price_tick
from lib.tools.cardano_order_manager import CardanoOrderManager, MIN_LADDER_RUNG_FLOOR_ADA
from lib.tools.cardano_maker_db import get_db_connection


def check_and_prune_filled_ladders(is_simulated: bool = False) -> List[Dict[str, Any]]:
    """Inspects recent fills to see if any completed or inventory-held rungs should prune lower rungs."""
    pruned_actions = []
    mgr = CardanoOrderManager(is_simulated=is_simulated)

    with get_db_connection(is_simulated=is_simulated) as conn:
        # Check orders that filled recently (status IN ('INVENTORY_HOLD', 'COMPLETED'))
        cur = conn.execute(
            """
            SELECT order_id, asset, capital_ada, metadata_json FROM maker_orders
            WHERE status IN ('INVENTORY_HOLD', 'COMPLETED')
              AND json_extract(metadata_json, '$.ladder_id') IS NOT NULL
              AND json_extract(metadata_json, '$.prune_checked') IS NULL
            ORDER BY updated_at DESC LIMIT 10
            """
        )
        candidates = [dict(r) for r in cur.fetchall()]

    for c in candidates:
        oid = c["order_id"]
        meta = json.loads(c.get("metadata_json") or "{}")
        ladder_id = meta.get("ladder_id")
        if not ladder_id:
            continue

        logger.info(f"Evaluating lower-rung pruning for filled ladder order {oid} (ladder: {ladder_id})...")
        p_res = mgr.prune_ladder_lower_rungs(ladder_id=ladder_id, filled_rung_id=oid)
        meta["prune_checked"] = int(time.time())
        meta["prune_result"] = p_res

        with get_db_connection(is_simulated=is_simulated) as conn:
            conn.execute(
                "UPDATE maker_orders SET metadata_json = ?, updated_at = ? WHERE order_id = ?",
                (json.dumps(meta), int(time.time()), oid),
            )
            conn.commit()

        if p_res.get("reclaimed_rungs_count", 0) > 0:
            logger.info(f"Successfully pruned {p_res['reclaimed_rungs_count']} lower rungs for ladder {ladder_id}")
            pruned_actions.append(p_res)

    return pruned_actions


def run_engine_cycle(dry_run: bool = False) -> Dict[str, Any]:
    """Executes a single unified pass across all Cardano trade engines:
    1. UTxO & Resting Limit Order Fills
    2. Ladder Lower-Rung Pruning
    3. Pair Ticker Scrapes & Stop/Invalidation Evaluation
    """
    cycle_start = time.time()
    ts = int(cycle_start)

    # 1. Poll Plutus Limit Order Lifecycles
    try:
        lifecycle_report = poll_order_lifecycle_once()
    except Exception as e:
        logger.error(f"Error polling order lifecycle: {e}", exc_info=True)
        lifecycle_report = {"status": "error", "message": str(e), "pending_count": 0, "fills_detected": 0}

    # 2. Check for Ladder Pruning on both Live and Sim
    pruned_live = []
    pruned_sim = []
    try:
        pruned_live = check_and_prune_filled_ladders(is_simulated=False)
        pruned_sim = check_and_prune_filled_ladders(is_simulated=True)
    except Exception as e:
        logger.error(f"Error during ladder pruning sweep: {e}")

    # 3. Ticker Sweep & Stop Triggers
    trigger_assets = get_active_trigger_assets()
    evaluated_triggers = []
    ticks = []

    if trigger_assets:
        try:
            ada_macro = get_ada_macro_stats()
            for asset in trigger_assets:
                tick = scrape_pair_tick(asset, ada_macro)
                if tick:
                    ticks.append(tick)
                    # Evaluate stops directly (breakout triggers, invalidation disarm trap)
                    ev_res = process_price_tick(tick)
                    evaluated_triggers.append({"asset": asset, "result": ev_res})
        except Exception as e:
            logger.error(f"Error evaluating stop triggers: {e}", exc_info=True)

    duration_ms = int((time.time() - cycle_start) * 1000)

    summary = {
        "timestamp": ts,
        "duration_ms": duration_ms,
        "mode": "DRY_RUN" if dry_run else "LIVE_L1_CHAIN",
        "orders_polled": lifecycle_report.get("pending_count", 0),
        "fills_detected": lifecycle_report.get("fills_detected", 0),
        "pruned_ladders": len(pruned_live) + len(pruned_sim),
        "ticks_scraped": len(ticks),
        "triggers_evaluated": len(evaluated_triggers),
        "lifecycle_summary": lifecycle_report,
        "ticks": ticks,
        "trigger_actions": evaluated_triggers,
    }

    # Write status snapshot
    try:
        DAEMON_STATUS_FILE.write_text(json.dumps(summary, indent=2))
    except Exception:
        pass

    return summary


def daemon_status() -> Dict[str, Any]:
    """Returns daemon execution status and telemetry."""
    is_running = False
    pid = None

    if DAEMON_PID_FILE.exists():
        try:
            pid = int(DAEMON_PID_FILE.read_text().strip())
            # Check if process is alive
            os.kill(pid, 0)
            is_running = True
        except (ValueError, OSError):
            is_running = False

    last_cycle = {}
    if DAEMON_STATUS_FILE.exists():
        try:
            last_cycle = json.loads(DAEMON_STATUS_FILE.read_text())
        except Exception:
            pass

    return {
        "status": "RUNNING" if is_running else "STOPPED",
        "pid": pid if is_running else None,
        "pid_file": str(DAEMON_PID_FILE),
        "log_file": str(DAEMON_LOG_FILE),
        "last_cycle": last_cycle,
    }


def stop_daemon() -> Dict[str, Any]:
    """Stops the running daemon process."""
    if not DAEMON_PID_FILE.exists():
        return {"status": "not_running", "message": "No PID file found"}

    try:
        pid = int(DAEMON_PID_FILE.read_text().strip())
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.5)
        if DAEMON_PID_FILE.exists():
            DAEMON_PID_FILE.unlink(missing_ok=True)
        return {"status": "stopped", "pid": pid}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def start_daemon(interval_sec: int = 60, dry_run: bool = False):
    """Starts the continuous daemon loop."""
    # Check if already running
    st = daemon_status()
    if st["status"] == "RUNNING":
        logger.warning(f"Daemon already running with PID {st['pid']}. Exiting.")
        sys.exit(0)

    # Write current PID
    my_pid = os.getpid()
    DAEMON_PID_FILE.write_text(str(my_pid))
    logger.info(f"Cardano Engine Daemon started (PID: {my_pid}, Interval: {interval_sec}s, Mode: {'DRY_RUN' if dry_run else 'LIVE'})")

    running = True

    def _sig_handler(signum, frame):
        nonlocal running
        logger.info(f"Received termination signal ({signum}). Shutting down daemon gracefully...")
        running = False

    signal.signal(signal.SIGTERM, _sig_handler)
    signal.signal(signal.SIGINT, _sig_handler)

    try:
        while running:
            try:
                cycle_res = run_engine_cycle(dry_run=dry_run)
                logger.info(
                    f"Cycle completed in {cycle_res['duration_ms']}ms: "
                    f"Orders={cycle_res['orders_polled']} | Fills={cycle_res['fills_detected']} | "
                    f"Ticks={cycle_res['ticks_scraped']} | Triggers={cycle_res['triggers_evaluated']}"
                )
            except Exception as e:
                logger.error(f"Unexpected error in engine cycle: {e}", exc_info=True)

            # Sleep in 1-second chunks for responsive SIGTERM handling
            for _ in range(interval_sec):
                if not running:
                    break
                time.sleep(1)
    finally:
        logger.info("Cleaning up daemon PID file...")
        DAEMON_PID_FILE.unlink(missing_ok=True)
        logger.info("Cardano Engine Daemon stopped.")


def main():
    parser = argparse.ArgumentParser(description="Sovereign Cardano Unified Engine Daemon (UCOM)")
    parser.add_argument("--once", action="store_true", help="Execute single unified cycle and exit")
    parser.add_argument("--daemon", action="store_true", help="Run as continuous background daemon")
    parser.add_argument("--interval", type=int, default=60, help="Daemon cycle interval in seconds (default 60)")
    parser.add_argument("--status", action="store_true", help="Check daemon running status and telemetry")
    parser.add_argument("--stop", action="store_true", help="Stop running daemon")
    parser.add_argument("--dry-run", action="store_true", help="Run without broadcasting mainnet transactions")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    if args.status:
        st = daemon_status()
        if args.json:
            print(json.dumps(st, indent=2))
        else:
            print(f"Daemon Status: {st['status']}")
            if st["pid"]:
                print(f"PID:           {st['pid']}")
            print(f"Log:           {st['log_file']}")
            if st.get("last_cycle"):
                lc = st["last_cycle"]
                print(f"Last Cycle:    {lc.get('timestamp')} ({lc.get('duration_ms', 0)}ms)")
                print(f"Orders Polled: {lc.get('orders_polled', 0)} | Fills: {lc.get('fills_detected', 0)} | Ticks: {lc.get('ticks_scraped', 0)}")
        return

    if args.stop:
        res = stop_daemon()
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Stop result: {res['status']} ({res.get('message', '')})")
        return

    if args.daemon:
        start_daemon(interval_sec=args.interval, dry_run=args.dry_run)
        return

    # Default to single cycle (--once or default invocation)
    res = run_engine_cycle(dry_run=args.dry_run)
    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"\n=======================================================")
        print(f" CARDANO ENGINE DAEMON CYCLE: {res['mode']}")
        print(f"=======================================================")
        print(f"Duration:           {res['duration_ms']} ms")
        print(f"Resting Orders:     {res['orders_polled']} polled ({res['fills_detected']} fills)")
        print(f"Pruned Ladders:     {res['pruned_ladders']}")
        print(f"Ticks Scraped:      {res['ticks_scraped']}")
        print(f"Triggers Evaluated: {res['triggers_evaluated']}")
        if res["ticks"]:
            print("\nMarket Ticks:")
            for t in res["ticks"]:
                print(f"  • {t['asset']}: {t['spot_price_ada']:.7f} ADA (ADA 24h: {t['ada_24h_change_pct']:+.2f}%)")
        print("")


if __name__ == "__main__":
    main()
