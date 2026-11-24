"""
Shared Cardano Mainnet & Minswap V2 protocol constants.
"""
from __future__ import annotations

from typing import Optional

ADA_UNIT: str = "lovelace"
LOVELACE_PER_ADA: int = 1_000_000

# API Base URLs
BLOCKFROST_MAINNET_API: str = "https://cardano-mainnet.blockfrost.io/api"
BLOCKFROST_MAINNET_V0: str = "https://cardano-mainnet.blockfrost.io/api/v0"
KOIOS_MAINNET_V1: str = "https://api.koios.rest/api/v1"
DOLOS_DEFAULT_MINIBF_V0: str = "http://127.0.0.1:8000/api/v0"
MINSWAP_AGGREGATOR_BASE: str = "https://agg-api.minswap.org/aggregator"

# Minswap V2 Mainnet script hashes, policies, and fee constants
MINSWAP_V2_ORDER_SCRIPT_HASH: str = "c3e28c36c3447315ba5a56f33da6a6ddc1770a876a8d9f0cb3a97c4c"
MINSWAP_V2_LP_POLICY: str = "f5808c2c990d86da54bfc97d89cee6efa20cd8461616359478d96b4c"
MINSWAP_V2_POOL_NFT: str = MINSWAP_V2_LP_POLICY + "4d5350"  # "MSP": one per Minswap V2 pool UTxO
MINSWAP_V2_DEPOSIT_LOVELACE: int = 2_000_000
MINSWAP_V2_MAX_BATCHER_FEE_LOVELACE: int = 2_000_000
MINSWAP_V2_FEE_DENOM: int = 10_000
MINSWAP_V2_POOL_FEE_DEFAULT: float = 0.003


def normalize_blockfrost_base_url(url: Optional[str]) -> str:
    """Normalize Blockfrost base URL for PyCardano / BlockFrostApi compatibility (ending in /api)."""
    if not url:
        return BLOCKFROST_MAINNET_API
    clean = url.rstrip("/")
    if clean.endswith("/v0"):
        clean = clean[:-3]
    if not clean.endswith("/api"):
        clean = f"{clean}/api"
    return clean

