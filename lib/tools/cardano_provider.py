#!/usr/bin/env python3
"""
Sovereign Cardano Multi-Provider Data Layer
Provides unified on-chain data retrieval with automatic failover across:
1. Koios v1 REST API (Primary: decentralized, free, zero API key)
2. Blockfrost API (Secondary fallback: managed API key)
3. Local Ogmios / Kupo Driver (Pluggable: 100% private local node)
"""

import os
import sys
import json
import time
import logging
import urllib.request
import urllib.error
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Optional, Any, Dict, List, Tuple

logger = logging.getLogger("cardano_provider")

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

LODGE_DIR = Path(os.environ.get("LODGE_DIR", Path.home() / "blue-lodge"))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))


def load_secrets() -> Dict[str, str]:
    secrets_file = GEORGE_DIR / "secrets.env"
    env_vars = dict(os.environ)
    if secrets_file.exists():
        with open(secrets_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env_vars[k.strip()] = v.strip().strip('"').strip("'")
    return env_vars


# ---------------------------------------------------------------------------
# Abstract Base Class
# ---------------------------------------------------------------------------

class CardanoDataProvider(ABC):
    @property
    @abstractmethod
    def name(self) -> str:
        pass

    @abstractmethod
    def is_available(self) -> bool:
        pass

    @abstractmethod
    def get_account_info(self, stake_address: str) -> Optional[Dict[str, Any]]:
        """
        Returns normalized account summary:
        {
            "stake_address": str,
            "active": bool,
            "controlled_amount_ada": float,
            "rewards_available_ada": float,
            "withdrawn_ada": float,
            "pool_id": Optional[str],
            "drep_id": Optional[str]
        }
        """
        pass

    @abstractmethod
    def get_account_rewards(self, stake_address: str, epoch_start: Optional[int] = None) -> List[Dict[str, Any]]:
        """
        Returns list of normalized staking rewards:
        [
            {
                "epoch": int,
                "amount_lovelace": int,
                "amount_ada": float,
                "pool_id": str,
                "type": str
            }, ...
        ]
        """
        pass

    @abstractmethod
    def get_account_addresses(self, stake_address: str) -> List[str]:
        """Returns list of Bech32 addresses associated with the stake credential."""
        pass

    @abstractmethod
    def get_address_transactions(self, address: str, order: str = "asc", limit: int = 100) -> List[Dict[str, Any]]:
        """
        Returns list of transactions:
        [
            {
                "tx_hash": str,
                "block_height": int,
                "block_time": int,
                "epoch": Optional[int]
            }, ...
        ]
        """
        pass

    @abstractmethod
    def get_transaction_utxos(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        """
        Returns normalized transaction UTXO model:
        {
            "tx_hash": str,
            "inputs": [
                {
                    "address": str,
                    "stake_address": Optional[str],
                    "amount_lovelace": int,
                    "amount_ada": float
                }
            ],
            "outputs": [
                {
                    "address": str,
                    "stake_address": Optional[str],
                    "amount_lovelace": int,
                    "amount_ada": float
                }
            ]
        }
        """
        pass


# ---------------------------------------------------------------------------
# Koios v1 Provider (Primary: Decentralized / Free / No API Key)
# ---------------------------------------------------------------------------

class KoiosProvider(CardanoDataProvider):
    def __init__(self, base_url: str = "https://api.koios.rest/api/v1", timeout: int = 15):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    @property
    def name(self) -> str:
        return "Koios-v1"

    def is_available(self) -> bool:
        # Quick healthcheck
        try:
            req = urllib.request.Request(
                f"{self.base_url}/tip",
                headers={"Accept": "application/json", "User-Agent": "BlueLodge-Sovereign/1.0"}
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status == 200
        except Exception:
            return False

    def _post(self, endpoint: str, payload: Dict[str, Any]) -> Any:
        url = f"{self.base_url}/{endpoint}"
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "BlueLodge-Sovereign/1.0"
            }
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def get_account_info(self, stake_address: str) -> Optional[Dict[str, Any]]:
        try:
            data = self._post("account_info", {"_stake_addresses": [stake_address]})
            if not data or not isinstance(data, list):
                return None
            acc = data[0]
            tot_bal = int(acc.get("total_balance") or 0) / 1e6
            rew_avail = int(acc.get("rewards_available") or 0) / 1e6
            withdrawn = int(acc.get("withdrawals") or 0) / 1e6
            return {
                "stake_address": stake_address,
                "active": acc.get("status") == "registered",
                "controlled_amount_ada": tot_bal,
                "rewards_available_ada": rew_avail,
                "withdrawn_ada": withdrawn,
                "pool_id": acc.get("delegated_pool"),
                "drep_id": acc.get("delegated_drep")
            }
        except Exception as e:
            logger.warning(f"Koios get_account_info error: {e}")
            return None

    def get_account_rewards(self, stake_address: str, epoch_start: Optional[int] = None) -> List[Dict[str, Any]]:
        try:
            data = self._post("account_rewards", {"_stake_addresses": [stake_address]})
            if not data or not isinstance(data, list):
                return []
            raw_rewards = data[0].get("rewards", [])
            normalized = []
            for r in raw_rewards:
                earned_ep = int(r.get("earned_epoch") or 0)
                spendable_ep = int(r.get("spendable_epoch") or earned_ep + 2)
                if epoch_start and spendable_ep < epoch_start:
                    continue
                amt_lovelace = int(r.get("amount") or 0)
                normalized.append({
                    "epoch": spendable_ep,
                    "earned_epoch": earned_ep,
                    "amount_lovelace": amt_lovelace,
                    "amount_ada": amt_lovelace / 1e6,
                    "pool_id": r.get("pool_id") or "",
                    "type": r.get("type") or "member"
                })
            normalized.sort(key=lambda x: x["epoch"])
            return normalized
        except Exception as e:
            logger.warning(f"Koios get_account_rewards error: {e}")
            return []

    def get_account_addresses(self, stake_address: str) -> List[str]:
        try:
            data = self._post("account_addresses", {"_stake_addresses": [stake_address]})
            if not data or not isinstance(data, list):
                return []
            addresses = data[0].get("addresses", [])
            return [a if isinstance(a, str) else a.get("address") for a in addresses if a]
        except Exception as e:
            logger.warning(f"Koios get_account_addresses error: {e}")
            return []

    def get_address_transactions(self, address: str, order: str = "asc", limit: int = 100) -> List[Dict[str, Any]]:
        try:
            data = self._post("address_txs", {"_addresses": [address]})
            if not data or not isinstance(data, list):
                return []
            normalized = []
            for t in data:
                normalized.append({
                    "tx_hash": t["tx_hash"],
                    "block_height": int(t.get("block_height") or 0),
                    "block_time": int(t.get("block_time") or 0),
                    "epoch": t.get("epoch_no")
                })
            normalized.sort(key=lambda x: x["block_time"], reverse=(order == "desc"))
            return normalized[:limit]
        except Exception as e:
            logger.warning(f"Koios get_address_transactions error: {e}")
            return []

    def get_transaction_utxos(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        try:
            data = self._post("tx_utxos", {"_tx_hashes": [tx_hash]})
            if not data or not isinstance(data, list):
                return None
            tx = data[0]
            inputs = []
            for inp in tx.get("inputs", []):
                pmt = inp.get("payment_addr", {})
                addr = pmt.get("bech32") if isinstance(pmt, dict) else str(pmt)
                stake = inp.get("stake_addr")
                lovelace = int(inp.get("value") or 0)
                inputs.append({
                    "address": addr or "",
                    "stake_address": stake,
                    "amount_lovelace": lovelace,
                    "amount_ada": lovelace / 1e6
                })

            outputs = []
            for out in tx.get("outputs", []):
                pmt = out.get("payment_addr", {})
                addr = pmt.get("bech32") if isinstance(pmt, dict) else str(pmt)
                stake = out.get("stake_addr")
                lovelace = int(out.get("value") or 0)
                outputs.append({
                    "address": addr or "",
                    "stake_address": stake,
                    "amount_lovelace": lovelace,
                    "amount_ada": lovelace / 1e6
                })

            return {
                "tx_hash": tx["tx_hash"],
                "inputs": inputs,
                "outputs": outputs
            }
        except Exception as e:
            logger.warning(f"Koios get_transaction_utxos error: {e}")
            return None


# ---------------------------------------------------------------------------
# Blockfrost Provider (Secondary Fallback: Managed SaaS Key)
# ---------------------------------------------------------------------------

class BlockfrostProvider(CardanoDataProvider):
    def __init__(self, project_id: Optional[str] = None, base_url: str = "https://cardano-mainnet.blockfrost.io/api/v0", timeout: int = 15):
        if not project_id:
            env = load_secrets()
            project_id = env.get("BLOCKFROST_PROJECT_ID", "")
        self.project_id = project_id
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    @property
    def name(self) -> str:
        return "Blockfrost"

    def is_available(self) -> bool:
        if not self.project_id:
            return False
        try:
            req = urllib.request.Request(
                f"{self.base_url}/health",
                headers={"project_id": self.project_id, "User-Agent": "BlueLodge-Sovereign/1.0"}
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                d = json.loads(resp.read().decode())
                return d.get("is_healthy", False)
        except Exception:
            return False

    def _get(self, endpoint: str) -> Any:
        url = f"{self.base_url}/{endpoint}"
        req = urllib.request.Request(
            url,
            headers={
                "project_id": self.project_id,
                "Accept": "application/json",
                "User-Agent": "BlueLodge-Sovereign/1.0"
            }
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def get_account_info(self, stake_address: str) -> Optional[Dict[str, Any]]:
        try:
            acc = self._get(f"accounts/{stake_address}")
            if not acc or "error" in acc:
                return None
            tot_bal = int(acc.get("controlled_amount") or 0) / 1e6
            rew_avail = int(acc.get("withdrawable_amount") or 0) / 1e6
            withdrawn = int(acc.get("withdrawals_sum") or 0) / 1e6
            return {
                "stake_address": stake_address,
                "active": acc.get("active", False),
                "controlled_amount_ada": tot_bal,
                "rewards_available_ada": rew_avail,
                "withdrawn_ada": withdrawn,
                "pool_id": acc.get("pool_id"),
                "drep_id": acc.get("drep_id")
            }
        except Exception as e:
            logger.warning(f"Blockfrost get_account_info error: {e}")
            return None

    def get_account_rewards(self, stake_address: str, epoch_start: Optional[int] = None) -> List[Dict[str, Any]]:
        try:
            data = self._get(f"accounts/{stake_address}/rewards?order=asc")
            if not data or not isinstance(data, list):
                return []
            normalized = []
            for r in data:
                ep = int(r.get("epoch") or 0)
                if epoch_start and ep < epoch_start:
                    continue
                amt_lovelace = int(r.get("amount") or 0)
                normalized.append({
                    "epoch": ep,
                    "earned_epoch": ep - 2 if ep >= 2 else 0,
                    "amount_lovelace": amt_lovelace,
                    "amount_ada": amt_lovelace / 1e6,
                    "pool_id": r.get("pool_id") or "",
                    "type": r.get("type") or "member"
                })
            return normalized
        except Exception as e:
            logger.warning(f"Blockfrost get_account_rewards error: {e}")
            return []

    def get_account_addresses(self, stake_address: str) -> List[str]:
        try:
            data = self._get(f"accounts/{stake_address}/addresses")
            if not data or not isinstance(data, list):
                return []
            return [a["address"] for a in data if "address" in a]
        except Exception as e:
            logger.warning(f"Blockfrost get_account_addresses error: {e}")
            return []

    def get_address_transactions(self, address: str, order: str = "asc", limit: int = 100) -> List[Dict[str, Any]]:
        try:
            data = self._get(f"addresses/{address}/transactions?order={order}&count={limit}")
            if not data or not isinstance(data, list):
                return []
            normalized = []
            for t in data:
                normalized.append({
                    "tx_hash": t["tx_hash"],
                    "block_height": int(t.get("block_height") or 0),
                    "block_time": int(t.get("block_time") or 0),
                    "epoch": None
                })
            return normalized
        except Exception as e:
            logger.warning(f"Blockfrost get_address_transactions error: {e}")
            return []

    def get_transaction_utxos(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        try:
            data = self._get(f"txs/{tx_hash}/utxos")
            if not data or not isinstance(data, dict):
                return None

            inputs = []
            for inp in data.get("inputs", []):
                lovelace = sum(int(x["quantity"]) for x in inp.get("amount", []) if x.get("unit") == "lovelace")
                inputs.append({
                    "address": inp.get("address", ""),
                    "stake_address": None,
                    "amount_lovelace": lovelace,
                    "amount_ada": lovelace / 1e6
                })

            outputs = []
            for out in data.get("outputs", []):
                lovelace = sum(int(x["quantity"]) for x in out.get("amount", []) if x.get("unit") == "lovelace")
                outputs.append({
                    "address": out.get("address", ""),
                    "stake_address": None,
                    "amount_lovelace": lovelace,
                    "amount_ada": lovelace / 1e6
                })

            return {
                "tx_hash": tx_hash,
                "inputs": inputs,
                "outputs": outputs
            }
        except Exception as e:
            logger.warning(f"Blockfrost get_transaction_utxos error: {e}")
            return None


# ---------------------------------------------------------------------------
# Local Node Driver (Pluggable: Ogmios WebSocket/HTTP + Kupo REST)
# ---------------------------------------------------------------------------

class OgmiosKupoProvider(CardanoDataProvider):
    def __init__(self, kupo_url: Optional[str] = None, ogmios_url: Optional[str] = None):
        self.kupo_url = (kupo_url or os.getenv("KUPO_URL", "http://localhost:1442")).rstrip("/")
        # Ogmios supports JSON-WSP over HTTP POST at its root port as well as WebSockets
        self.ogmios_http_url = (ogmios_url or os.getenv("OGMIOS_HTTP_URL", "http://localhost:1337")).rstrip("/")
        self.ogmios_ws_url = os.getenv("OGMIOS_WS_URL", "ws://localhost:1337")

    @property
    def name(self) -> str:
        return "Local-Ogmios-Kupo"

    def is_available(self) -> bool:
        try:
            req = urllib.request.Request(f"{self.kupo_url}/health", headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=1) as resp:
                return resp.status == 200
        except Exception:
            return False

    def _ogmios_rpc(self, method: str, params: Optional[Dict[str, Any]] = None) -> Optional[Any]:
        try:
            payload = {
                "jsonrpc": "2.0",
                "method": method,
                "params": params or {},
                "id": f"blue-lodge-{int(time.time()*1000)}"
            }
            data = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(
                self.ogmios_http_url,
                data=data,
                headers={"Content-Type": "application/json", "Accept": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=3) as resp:
                res = json.loads(resp.read().decode("utf-8"))
                return res.get("result")
        except Exception as e:
            logger.debug(f"Ogmios RPC ({method}) error: {e}")
            return None

    def _kupo_get(self, path: str) -> Optional[Any]:
        try:
            url = f"{self.kupo_url}/{path.lstrip('/')}"
            req = urllib.request.Request(url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            logger.debug(f"Kupo GET ({path}) error: {e}")
            return None

    def get_account_info(self, stake_address: str) -> Optional[Dict[str, Any]]:
        # Query Ogmios ledger state for stake credential summary
        try:
            res = self._ogmios_rpc("queryLedgerState/rewardAccountSummaries", {"keys": [stake_address]})
            if not res or not isinstance(res, dict):
                return None
            summary = res.get(stake_address)
            if not summary:
                return None
            rewards = int(summary.get("rewards") or 0) / 1e6
            delegate = summary.get("delegate")
            return {
                "stake_address": stake_address,
                "active": True,
                "controlled_amount_ada": rewards,
                "rewards_available_ada": rewards,
                "withdrawn_ada": 0.0,
                "pool_id": delegate if isinstance(delegate, str) else None,
                "drep_id": summary.get("voteDelegate")
            }
        except Exception as e:
            logger.warning(f"Local Ogmios get_account_info error: {e}")
            return None

    def get_account_rewards(self, stake_address: str, epoch_start: Optional[int] = None) -> List[Dict[str, Any]]:
        # Ogmios reports current available balance; historical rewards can be mapped from local ledger snapshots
        return []

    def get_account_addresses(self, stake_address: str) -> List[str]:
        # Kupo pattern matches addresses delegated to this stake credential
        try:
            data = self._kupo_get(f"matches/*@{stake_address}")
            if not data or not isinstance(data, list):
                return []
            addrs = list({u.get("address") for u in data if u.get("address")})
            return addrs
        except Exception as e:
            logger.warning(f"Local Kupo get_account_addresses error: {e}")
            return []

    def get_address_transactions(self, address: str, order: str = "asc", limit: int = 100) -> List[Dict[str, Any]]:
        # Kupo matches UTXOs at this address to collect recent transaction references
        try:
            data = self._kupo_get(f"matches/*@{address}?order={order}&limit={limit}")
            if not data or not isinstance(data, list):
                return []
            tx_map = {}
            for u in data:
                tx_id = u.get("transaction_id")
                if tx_id and tx_id not in tx_map:
                    slot = u.get("created_at", {}).get("slot_no", 0)
                    tx_map[tx_id] = {
                        "tx_hash": tx_id,
                        "block_height": slot,
                        "block_time": 1596059091 + (slot - 4492800), # slot to posix approx
                        "epoch": None
                    }
            return list(tx_map.values())[:limit]
        except Exception as e:
            logger.warning(f"Local Kupo get_address_transactions error: {e}")
            return []

    def get_transaction_utxos(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        # Kupo indexes outputs by transaction_id
        try:
            data = self._kupo_get(f"matches/{tx_hash}/*")
            if not data or not isinstance(data, list):
                return None
            outputs = []
            for out in data:
                lovelace = int(out.get("value", {}).get("coins", 0))
                outputs.append({
                    "address": out.get("address", ""),
                    "stake_address": None,
                    "amount_lovelace": lovelace,
                    "amount_ada": lovelace / 1e6
                })
            return {
                "tx_hash": tx_hash,
                "inputs": [],
                "outputs": outputs
            }
        except Exception as e:
            logger.warning(f"Local Kupo get_transaction_utxos error: {e}")
            return None



# ---------------------------------------------------------------------------
# Sovereign Dolos Provider (Mini-Blockfrost Local Daemon)
# ---------------------------------------------------------------------------

class DolosProvider(BlockfrostProvider):
    """
    Sovereign Dolos Data Node running locally with Mini-Blockfrost HTTP service.
    Zero external dependencies, zero rate limits, sub-millisecond local latency.
    """
    def __init__(self, base_url: Optional[str] = None):
        raw_url = base_url or os.getenv("DOLOS_MINIBF_URL", "http://localhost:8000")
        url = raw_url.rstrip("/").removesuffix("/api/v0")
        super().__init__(project_id="dolos-local", base_url=url)
        self.health_url = os.getenv("DOLOS_HEALTH_URL", f"{url}/health")

    @property
    def name(self) -> str:
        return "Local-Dolos-MiniBF"

    def is_available(self) -> bool:
        """Daemon is alive and responding to health/blocks."""
        try:
            req = urllib.request.Request(self.health_url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=1) as resp:
                return resp.status in (200, 204)
        except Exception:
            try:
                req = urllib.request.Request(f"{self.base_url}/blocks/latest", headers={"Accept": "application/json"})
                with urllib.request.urlopen(req, timeout=1) as resp:
                    return resp.status == 200
            except Exception:
                return False

    def is_synced(self, max_lag_seconds: int = 120) -> bool:
        """
        Check if the local Dolos node is synchronized with the Cardano L1 tip.
        Cardano slot clock advances 1 slot per second. If local block time is
        within max_lag_seconds of wall-clock time, the node is in sync.
        """
        try:
            req = urllib.request.Request(f"{self.base_url}/blocks/latest", headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=1) as resp:
                if resp.status == 200:
                    data = json.loads(resp.read().decode("utf-8"))
                    block_time = data.get("time")
                    if block_time:
                        lag = time.time() - block_time
                        return lag <= max_lag_seconds
            return False
        except Exception:
            return False


# ---------------------------------------------------------------------------
# Multi-Provider Orchestrator (Automatic Failover & Strategy Dispatcher)
# ---------------------------------------------------------------------------

class MultiProviderAdapter(CardanoDataProvider):
    """
    Transparent multi-provider adapter that prioritizes local sovereign nodes
    (Dolos Mini-Blockfrost / Ogmios+Kupo) first when synchronized, falling back
    to Koios v1 REST during sync catch-up and finally remote Blockfrost upon degradation.
    """
    def __init__(self):
        self.dolos = DolosProvider()
        self.local_node = OgmiosKupoProvider()
        self.koios = KoiosProvider()
        self.blockfrost = BlockfrostProvider()
        self.providers: List[CardanoDataProvider] = []
        
        # Priority Queue:
        # If Dolos is running AND synced, prioritize it at #1 for sub-millisecond sovereign execution.
        # If Dolos is running but catching up/syncing, keep Koios at #1 so trading & balance queries
        # never see stale historic states, with Dolos in queue for block inspection.
        if self.dolos.is_available() and self.dolos.is_synced():
            self.providers.append(self.dolos)
        elif self.local_node.is_available():
            self.providers.append(self.local_node)
        self.providers.append(self.koios)
        if self.dolos.is_available() and not self.dolos.is_synced():
            self.providers.append(self.dolos)
        if self.blockfrost.project_id and self.blockfrost.project_id != "dolos-local":
            self.providers.append(self.blockfrost)

    @property
    def name(self) -> str:
        active = [p.name for p in self.providers]
        return f"MultiProviderAdapter({'+'.join(active)})"

    def is_available(self) -> bool:
        return any(p.is_available() for p in self.providers)

    def _execute_with_fallback(self, method_name: str, *args, **kwargs) -> Any:
        last_error = None
        for p in self.providers:
            try:
                fn = getattr(p, method_name)
                res = fn(*args, **kwargs)
                if res is not None and res != []:
                    return res
            except Exception as e:
                logger.warning(f"Provider {p.name} failed for {method_name}: {e}. Trying fallback...")
                last_error = e
        if last_error:
            logger.error(f"All providers exhausted for {method_name}: {last_error}")
        return None

    def get_account_info(self, stake_address: str) -> Optional[Dict[str, Any]]:
        return self._execute_with_fallback("get_account_info", stake_address)

    def get_account_rewards(self, stake_address: str, epoch_start: Optional[int] = None) -> List[Dict[str, Any]]:
        res = self._execute_with_fallback("get_account_rewards", stake_address, epoch_start=epoch_start)
        return res or []

    def get_account_addresses(self, stake_address: str) -> List[str]:
        res = self._execute_with_fallback("get_account_addresses", stake_address)
        return res or []

    def get_address_transactions(self, address: str, order: str = "asc", limit: int = 100) -> List[Dict[str, Any]]:
        res = self._execute_with_fallback("get_address_transactions", address, order=order, limit=limit)
        return res or []

    def get_transaction_utxos(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        return self._execute_with_fallback("get_transaction_utxos", tx_hash)


_GLOBAL_PROVIDER: Optional[MultiProviderAdapter] = None

def get_cardano_provider() -> MultiProviderAdapter:
    global _GLOBAL_PROVIDER
    if _GLOBAL_PROVIDER is None:
        _GLOBAL_PROVIDER = MultiProviderAdapter()
    return _GLOBAL_PROVIDER


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    provider = get_cardano_provider()
    print(f"Initialized: {provider.name}")
    hw1_stake = os.environ.get("CARDANO_STAKE_ADDR", "")
    if not hw1_stake:
        lib_file = Path(__file__).resolve().parents[2] / ".george" / "wallets" / "wallet_library.json"
        if lib_file.exists():
            try:
                hw1_stake = json.loads(lib_file.read_text(encoding="utf-8")).get("default_stake_address", "")
            except Exception:
                pass
    if hw1_stake:
        info = provider.get_account_info(hw1_stake)
        print("Account Info via Adapter:", info)
        rewards = provider.get_account_rewards(hw1_stake)
        print(f"Total Staking Rewards: {len(rewards)}")
        if rewards:
            print("Latest Reward:", rewards[-1])
    else:
        print("Set CARDANO_STAKE_ADDR or configure .george/wallets/wallet_library.json to test staking queries.")
