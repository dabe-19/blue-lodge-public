#!/usr/bin/env python3
"""
Sovereign Cardano Multi-Headed Pair Ticker Scraper
Surveys spot ratios and ADA 24h macro trends for assets with ARMED triggers,
emitting 'cardano/price_tick' to the POSIX FIFO Event Bus.
"""

from __future__ import annotations

import os
import sys
import json
import time
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

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr)
logger = logging.getLogger("cardano_pair_ticker")

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
FINANCE_DIR = Path(os.environ.get("FINANCE_DIR", GEORGE_DIR / "finance"))
EVENT_BUS_FIFO = Path(os.environ.get("EVENT_BUS_FIFO", GEORGE_DIR / "ipc" / "event_bus.fifo"))

from lib.tools.cardano_maker_db import get_db_connection, init_db, get_armed_stop_triggers
from lib.tools.quant import market_data as md
from lib.tools.cardano_order_watcher import emit_event_to_bus
from lib.tools.cardano_stop_engine import get_ada_macro_stats


def get_active_trigger_assets() -> List[str]:
    """Returns list of unique assets that have ARMED stop triggers across live and sim stores."""
    triggers_live = get_armed_stop_triggers(is_simulated=False)
    triggers_sim = get_armed_stop_triggers(is_simulated=True)
    return sorted(list({t["asset"] for t in triggers_live + triggers_sim}))


def scrape_pair_tick(asset: str, ada_macro: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Scrapes on-chain spot and macro trend for an asset."""
    asset = asset.upper()
    try:
        series = md.load_series(asset, "hour", 1)
        if series.get("status") != "ok":
            logger.warning(f"Could not load market data for {asset}: {series.get('reason')}")
            return None

        pool = series["pool"]
        spot = float(pool["price_ada"])
        now = int(time.time())

        return {
            "asset": asset,
            "spot_price_ada": spot,
            "ada_24h_change_pct": float(ada_macro.get("change_24h_pct", 0.0)),
            "ada_usd": float(ada_macro.get("price_usd", 0.0)),
            "timestamp": now,
            "pool_address": pool.get("pool_address"),
            "dex": pool.get("dex", "MinswapV2"),
        }
    except Exception as e:
        logger.error(f"Error scraping pair tick for {asset}: {e}")
        return None


def run_ticker_sweep(dry_run: bool = False, as_json: bool = False) -> List[Dict[str, Any]]:
    """Sweeps all assets with ARMED triggers and emits cardano/price_tick events."""
    assets = get_active_trigger_assets()
    if not assets:
        if not as_json:
            logger.info("No ARMED stop triggers active. Pair ticker standing down.")
        return []

    ada_macro = get_ada_macro_stats()
    ticks = []

    emit_bus = os.environ.get("CARDANO_EMIT_PRICE_TICKS", "0") == "1"
    if not emit_bus:
        try:
            reactors_path = _REPO_ROOT / ".george" / "reactors.json"
            if reactors_path.exists():
                rdata = json.loads(reactors_path.read_text(encoding="utf-8"))
                emit_bus = any(
                    r.get("event_type") == "cardano/price_tick" and r.get("enabled", True)
                    for r in rdata.get("reactors", [])
                )
        except Exception:
            emit_bus = False

    for a in assets:
        tick = scrape_pair_tick(a, ada_macro)
        if tick:
            ticks.append(tick)
            if not dry_run and emit_bus:
                # Emit to POSIX event bus only when a price_tick reactor is enabled
                emitted = emit_event_to_bus("cardano/price_tick", tick, source="cardano_pair_ticker")
                logger.info(f"Emitted cardano/price_tick for {a}: Spot={tick['spot_price_ada']:.7f} ADA (Bus={emitted})")
            elif not dry_run:
                logger.debug(f"Scraped pair tick for {a}: Spot={tick['spot_price_ada']:.7f} ADA (bus emission skipped: no enabled reactor)")
            else:
                logger.info(f"[DRY-RUN] Tick for {a}: Spot={tick['spot_price_ada']:.7f} ADA, ADA 24h={tick['ada_24h_change_pct']:+.2f}%")

    return ticks


def main():
    parser = argparse.ArgumentParser(description="Cardano Multi-Headed Pair Ticker Scraper")
    parser.add_argument("--poll", action="store_true", help="Execute single ticker scrape and emit")
    parser.add_argument("--loop", type=int, default=0, help="Continuous loop interval in seconds (e.g. 60)")
    parser.add_argument("--dry-run", action="store_true", help="Scrape without emitting events to event bus")
    parser.add_argument("--json", action="store_true", help="Output pure JSON")
    args = parser.parse_args()

    if args.loop > 0:
        logger.info(f"Starting continuous pair ticker daemon (interval: {args.loop}s)...")
        while True:
            ticks = run_ticker_sweep(dry_run=args.dry_run, as_json=args.json)
            if args.json and ticks:
                print(json.dumps(ticks))
            time.sleep(args.loop)
    else:
        ticks = run_ticker_sweep(dry_run=args.dry_run, as_json=args.json)
        if args.json:
            print(json.dumps({"status": "ok", "ticks": ticks}, indent=2))
        else:
            if not ticks:
                print("No active triggers to scrape.")
            else:
                for t in ticks:
                    print(f"Tick: {t['asset']} | Spot: {t['spot_price_ada']:.7f} ADA | ADA 24h: {t['ada_24h_change_pct']:+.2f}%")


if __name__ == "__main__":
    main()
