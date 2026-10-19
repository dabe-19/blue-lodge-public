#!/usr/bin/env python3
"""
Canonical Cardano token registry for Blue Lodge (single source of truth).

Every module that needs a policy id / asset name / decimals MUST import from here.
Before this module existed, five files carried their own copies and three different
MIN units were in circulation (only the one below is the real Minswap MIN token).

Pure data + helpers: no network, no signing stack, safe to import from the quant layer.
"""
from __future__ import annotations

from typing import Dict, Optional

# symbol -> policy id (56 hex) + asset name (hex) + decimals
_TOKENS: Dict[str, Dict[str, object]] = {
    "SNEK":  {"policy_id": "279c909f348e533da5808898f87f9a14bb2c3dfbbacccd631d927a3f", "asset_name_hex": "534e454b", "decimals": 0},
    "MIN":   {"policy_id": "29d222ce763455e3d7a09a665ce554f00ac89d2e99a1a83d267170c6", "asset_name_hex": "4d494e", "decimals": 6},
    "WMTX":  {"policy_id": "e5a42a1a1d3d1da71b0449663c32798725888d2eb0843c4dabeca05a", "asset_name_hex": "576f726c644d6f62696c65546f6b656e58", "decimals": 6},
    "DJED":  {"policy_id": "8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61", "asset_name_hex": "446a65644d6963726f555344", "decimals": 6},
    "IAG":   {"policy_id": "5d16cc1a177b5d9ba9cfa9793b07e60f1fb70fea1f8aef064415d114", "asset_name_hex": "494147", "decimals": 6},
    "NIGHT": {"policy_id": "0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa", "asset_name_hex": "4e49474854", "decimals": 6},
    "HOSKY": {"policy_id": "a0028f350aaabe0545fdcb56b039bfb08e4bb4d8c4d7c3c7d481c235", "asset_name_hex": "484f534b59", "decimals": 0},
    "USDM":   {"policy_id": "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad", "asset_name_hex": "0014df105553444d", "decimals": 6},
    "USDCX":  {"policy_id": "1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34", "asset_name_hex": "5553444378", "decimals": 6},
    "SHEN":   {"policy_id": "8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61", "asset_name_hex": "5368656e4d6963726f555344", "decimals": 6},
    "INDY":   {"policy_id": "533bb94a8850ee3ccbe483106489399112b74c905342cb1792a797a0", "asset_name_hex": "494e4459", "decimals": 6},
    "LQ":     {"policy_id": "da8c30857834c6ae7203935b89278c532b3995245295456f993e1d24", "asset_name_hex": "4c51", "decimals": 6},
    "STRIKE": {"policy_id": "f13ac4d66b3ee19a6aa0f2a22298737bd907cc95121662fc971b5275", "asset_name_hex": "535452494b45", "decimals": 6},
    "SUNDAE": {"policy_id": "9a9693a9a37912a5097918f97918d15240c92ab729a0b7c4aa144d77", "asset_name_hex": "53554e444145", "decimals": 6},
    "FLDT":   {"policy_id": "577f0b1342f8f8f4aed3388b80a8535812950c7a892495c0ecdf0f1e", "asset_name_hex": "0014df10464c4454", "decimals": 6},
    "STUFF":  {"policy_id": "51a5e236c4de3af2b8020442e2a26f454fda3b04cb621c1294a0ef34", "asset_name_hex": "424f4f4b", "decimals": 6},
}

ALIASES: Dict[str, str] = {"USDCx": "USDCX"}

ADA_DECIMALS = 6


def symbols() -> list:
    return list(_TOKENS.keys())


def canonical(symbol: str) -> Optional[str]:
    s = ALIASES.get(symbol, symbol).upper()
    return s if s in _TOKENS else None


def get(symbol: str) -> Dict[str, object]:
    """Full record incl. 'unit' (policy_id + asset_name_hex). Raises KeyError for unknown symbols."""
    s = canonical(symbol)
    if s is None:
        raise KeyError(f"Unknown Cardano token '{symbol}'. Known: {sorted(_TOKENS)}")
    rec = dict(_TOKENS[s])
    rec["symbol"] = s
    rec["unit"] = f"{rec['policy_id']}{rec['asset_name_hex']}"
    return rec


def unit(symbol: str) -> str:
    return str(get(symbol)["unit"])


def decimals(symbol: str) -> int:
    return int(get(symbol)["decimals"])


def unit_table() -> Dict[str, Dict[str, object]]:
    """{SYMBOL: {"unit": ..., "decimals": ...}} for all known tokens."""
    return {s: {"unit": unit(s), "decimals": decimals(s)} for s in _TOKENS}


def symbol_for_unit(u: str) -> Optional[str]:
    u = (u or "").replace(".", "").lower()
    for s in _TOKENS:
        if unit(s) == u:
            return s
    return None
