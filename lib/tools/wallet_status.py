#!/usr/bin/env python3
"""Sovereign Real-Time On-Chain Wallet Status Provider for Blue Lodge.

Delegates to lib.tools.sovereign_multichain_wallet to query Cardano, Polygon, and Ethereum
balances and outputs unified JSON for the Craftsman Workbench UI and telemetry pipelines.
"""
from __future__ import annotations

import argparse
import json
import sys
import warnings
from pathlib import Path
from typing import Any

warnings.filterwarnings("ignore")

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools.sovereign_multichain_wallet import (
    get_cardano_status,
    get_ethereum_status,
    get_polygon_status,
    get_unified_multichain_portfolio as get_unified_wallet_status,
)

__all__ = [
    "get_cardano_status",
    "get_polygon_status",
    "get_ethereum_status",
    "get_unified_wallet_status",
]


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign On-Chain Wallet Status Provider")
    parser.add_argument("--json", action="store_true", help="Output raw JSON (default)")
    parser.parse_args()
    status = get_unified_wallet_status()
    print(json.dumps(status, indent=2))


if __name__ == "__main__":
    main()
