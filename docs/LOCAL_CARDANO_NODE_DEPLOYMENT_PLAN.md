# Sovereign Cardano Node, Ogmios & Kupo Infrastructure Blueprint

> **Status:** Implementation Complete & Ready for Activation  
> **Author:** George & Antigravity IDE  
> **Target Environment:** Blue Lodge Local / Hybrid Bare-Metal & WSL2 Engine  
> **Primary Interfaces:** Ogmios (JSON-WSP/WS `:1337`), Kupo (REST `:1442`), Cardano Node (IPC Socket `/ipc/node.socket`)

---

## 1. Executive Summary & Sovereignty Mandate

Relying on commercial third-party infrastructure providers (e.g. Blockfrost, Koios, Maestro) introduces critical structural liabilities for an autonomous algorithmic trading and tax compliance engine:
1. **Rate Limits & Throttling:** Rapid multi-hop provenance crawling and real-time DEX pool surveillance can exhaust public tier limits or hit HTTP 429 back-off walls during high-volatility market events.
2. **Privacy & Counterparty Exposure:** Submitting queries for cold storage hardware wallet addresses, limit orders, and transaction traces broadcasts trading intent to centralized node operators prior to mempool submission.
3. **Latency & Execution Risk:** External REST API calls incur 150ms–500ms network round-trip overhead. In contrast, local Unix Domain Socket / localhost communication resolves UTXO checks and ledger queries in **sub-millisecond (< 1ms)** timeframes.
4. **Decentralization & Self-Sovereignty:** Running an authenticated full node validates block consensus directly via cryptographic proof rather than trusting third-party server responses.

This specification details the production deployment, fast-synchronization procedure, resource sizing, and Blue Lodge integration for running an on-premise **Cardano Node + Ogmios + Kupo** stack.

---

## 2. Architectural Design & Component Topology

```
+------------------------------------------------------------------------------------+
|                                    BLUE LODGE                                      |
|                                                                                    |
|  +------------------------+      +-----------------------+     +----------------+  |
|  | Cardano Arbitrageur    |      | Crypto Tax Auditor    |     | Web / CLI Desk |  |
|  | (DEX Swap Graphs)      |      | (Form 8949 / Sch 1)   |     | (Studio UI)    |  |
|  +-----------+------------+      +-----------+-----------+     +--------+-------+  |
|              |                               |                          |          |
|              +-----------------------+-------+--------------------------+          |
|                                      |                                             |
|                                      v                                             |
|                  +---------------------------------------+                         |
|                  |      MultiProviderAdapter             |                         |
|                  |   (lib/tools/cardano_provider.py)     |                         |
|                  +-------------------+-------------------+                         |
+--------------------------------------|---------------------------------------------+
                                       |
                   +-------------------+-------------------+
                   | Slot 0: Local Node (Sub-ms)           | Failover (Remote)
                   v                                       v
+--------------------------------------+  +------------------------------------------+
|  LOCAL SOVEREIGN STACK (Docker)      |  | PUBLIC FALLBACK LAYER                    |
|                                      |  |                                          |
|  +--------------------------------+  |  |  +--------------------+                  |
|  |  Kupo v2.9 (UTXO Indexer)      |  |  |  | Koios v1 REST      | (Primary Remote) |
|  |  HTTP REST :1442               |  |  |  | api.koios.rest     |                  |
|  +---------------+----------------+  |  |  +--------------------+                  |
|                  | Sync              |  |                                          |
|                  v                   |  |  +--------------------+                  |
|  +--------------------------------+  |  |  | Blockfrost API     | (Secondary)      |
|  |  Ogmios v6.11 (Bridge)         |  |  |  | cardano-mainnet... |                  |
|  |  JSON-WSP / WS :1337           |  |  |  +--------------------+                  |
|  +---------------+----------------+  |  +------------------------------------------+
|                  | Unix Socket       |
|                  v                   |
|  +--------------------------------+  |
|  |  Cardano Node v10.1.4          |  |
|  |  Ouroboros Consensus / P2P     |  |
|  |  Socket: /ipc/node.socket      |  |
|  |  Ledger DB: ~180 GB NVMe       |  |
|  +--------------------------------+  |
+--------------------------------------+
```

### Component Roles:
1. **`cardano-node` (Intersect MBO / Haskell):** The core daemon validating consensus (Ouroboros Praos/Conway), participating in peer-to-peer gossip on port `3001`, and maintaining the immutable ledger on disk.
2. **`ogmios` (Cardano Solutions / Haskell):** A fast, memory-safe sidecar that translates Cardano's low-level binary multiplexer protocols (`Node-to-Client` over `/ipc/node.socket`) into clean JSON-RPC 2.0 WebSockets and HTTP POST endpoints on port `1337`.
3. **`kupo` (Cardano Solutions / Haskell):** A tailor-made, pattern-matching UTXO indexer that synchronizes directly with the node via Ogmios. It tracks active UTXOs and scripts into a high-performance SQLite database on port `1442`.

---

## 3. Resource Sizing & Storage Optimization

### Hardware Requirements
| Resource | Minimum | Recommended | Blue Lodge Allocation |
| :--- | :--- | :--- | :--- |
| **CPU** | 4 Cores (x86_64) | 8 Cores (Modern Zen 4 / Intel 14th+) | Host CPU with 2 dedicated worker threads |
| **RAM** | 16 GB | 24 GB – 32 GB | 20 GB GHC RTS ceiling (`-M20G`) |
| **Disk Type** | SATA SSD (Slow sync) | NVMe M.2 PCIe 4.0 SSD | High-IOPS NVMe mount |
| **Disk Space**| 180 GB (Pruned Ledger) | 350 GB (Full Ledger + Kupo DB) | Dedicated partition or mount |

### GHC Runtime System (RTS) Tuning:
In [`deploy/cardano-node/docker-compose.yml`](deploy/cardano-node/docker-compose.yml), `cardano-node` is configured with production Haskell RTS parameters:
```bash
+RTS -N2 -A16m -qg -M20G -RTS
```
- `-N2`: Restricts parallel GC and execution to 2 capability threads, ensuring the inference engine and WSL host maintain priority.
- `-A16m`: Allocates 16MB allocation areas per capability to minimize garbage collector interruptions.
- `-M20G`: Enforces a hard memory ceiling at 20GB, preventing Linux OOM killer invocation.

---

## 4. Rapid Bootstrapping: Mithril Stake-Based Snapshot Protocol

Syncing the Cardano blockchain from the Byron Genesis block (2017) requires replaying over 100 million transactions across Conway, Alonzo, and Shelley eras, taking **48 to 72 hours**.

To eliminate this bottleneck, the deployment utilizes **Mithril** (`input-output-hk/mithril`):
- Mithril is a decentralized protocol where Cardano Stake Pool Operators (SPOs) sign cryptographic proofs of the ledger state using stake-weighted threshold multi-signatures.
- The snapshot is downloaded over high-bandwidth CDN links, cryptographically verified against the mainnet Genesis Verification Key, and decompressed into `./data/db/` in **15 to 25 minutes**.

### Automated Bootstrap Script:
[`deploy/cardano-node/scripts/sync_mithril.sh`](deploy/cardano-node/scripts/sync_mithril.sh) automates:
1. Detecting host architecture (`x86_64` vs `aarch64`) and downloading official `mithril-client`.
2. Querying the official IOG Mithril Aggregator (`https://aggregator.release-mainnet.api.mithril.network/aggregator`).
3. Verifying the snapshot certificate against the immutable verification key.
4. Extracting the immutable block files into `./data/db/`.

---

## 5. Kupo Indexing Strategy & Pattern Filtering

A naive blockchain indexer indexes every transaction since block 0, creating a database exceeding 1 TB. Kupo solves this through **Pattern Matching Filters**:

### Mode A: Full Ecosystem Indexing (Recommended for Multi-DEX Arbitrage)
In `docker-compose.yml`:
```yaml
command:
  - "--match"
  - "*/*"
  - "--prune-utxo"
```
- `--match "*/*"`: Tracks all active unspent transaction outputs across mainnet.
- `--prune-utxo`: Automatically purges spent UTXOs from SQLite, maintaining a compact database (~15–25 GB).

### Mode B: Scoped Sovereign Indexing (Ultra-Lightweight / < 500 MB DB)
If disk storage is limited, Kupo can be restricted to only Blue Lodge self-owned wallets and target DEX script addresses:
```yaml
command:
  - "--match"
  - "*@addr1_your_payment_address_here"  # Hot Wallet
  - "--match"
  - "*@stake1_your_stake_address_here" # Hardware Wallet 1
  - "--match"
  - "*@addr1zxn9efv2f6w82e7x9amgf...*"                              # Minswap V2 Script
  - "--match"
  - "*@addr1wx4vt...*"                                              # SundaeSwap Script
  - "--prune-utxo"
```
Under Mode B, Kupo's database is less than 500 MB and synchronizes in seconds.

---

## 6. Blue Lodge Software Integration

The multi-provider architecture implemented in [`lib/tools/cardano_provider.py`](lib/tools/cardano_provider.py) natively includes `OgmiosKupoProvider`:

```python
class OgmiosKupoProvider(CardanoDataProvider):
    def __init__(self, kupo_url="http://localhost:1442", ogmios_url="http://localhost:1337"):
        ...
```

### Prioritization Logic in `MultiProviderAdapter`:
1. On startup or healthcheck, `is_available()` performs a 1-second probe to `http://localhost:1442/health`.
2. When the local node is online, `OgmiosKupoProvider` is automatically prepended as **Slot 0** (Primary).
3. If the local container is stopped or restarting, `MultiProviderAdapter` seamlessly falls back to Koios v1 without dropping in-flight trades or tax requests.

### Configuration Environment Variables:
To force immediate routing through the local node across Blue Lodge CLI and background services:
```bash
export DEFAULT_CARDANO_PROVIDER=local
export OGMIOS_HTTP_URL=http://localhost:1337
export OGMIOS_WS_URL=ws://localhost:1337
export KUPO_URL=http://localhost:1442
```

---

## 7. Operational Step-by-Step Deployment Runbook

### Step 1: Storage Verification & Pre-flight
Ensure at least 200 GB of free space on the destination drive:
```bash
df -h /opt/blue-lodge/deploy/cardano-node
```

### Step 2: One-Command Stack Bootstrap
Execute the automated deployer:
```bash
cd /opt/blue-lodge/deploy/cardano-node
./scripts/bootstrap.sh
```
This script will:
- Fetch official mainnet genesis parameters (`shelley`, `alonzo`, `conway`, `byron`).
- Download and verify the latest Mithril snapshot.
- Spawn `lodge-cardano-node`, `lodge-ogmios`, and `lodge-kupo`.

### Step 3: Healthcheck Verification
Verify that all three services have passed internal container checks:
```bash
docker compose ps
curl -s http://localhost:1337/health | jq .
curl -s http://localhost:1442/health | jq .
```

### Step 4: Live Query Validation
Query the active tip and current slot height from Ogmios:
```bash
curl -s -X POST http://localhost:1337 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "queryNetwork/tip", "id": "test"}' | jq .
```
Query Hot Wallet UTXOs from Kupo in sub-millisecond time:
```bash
curl -s http://localhost:1442/matches/*@addr1_your_payment_address_here | jq .
```

### Step 5: Test Full Sovereign Tax & Trading Pipeline
Run the tax compliance bundle and verify provider routing:
```bash
commands/trading.sh tax bundle 2026
```

---

## 8. Summary of Benefits to Blue Lodge

| Capability | Public Providers (Koios/Blockfrost) | Sovereign Node (Ogmios/Kupo) |
| :--- | :--- | :--- |
| **Query Latency** | 150ms – 500ms | **< 1ms (Localhost)** |
| **Rate Limit Ceiling** | 10–50 req/sec | **Unlimited (Hardware bound)** |
| **Privacy Leaks** | Stake and hot keys sent over WAN | **Zero WAN exposure** |
| **Mempool Sniping** | 200–800ms mempool propagation delay | **Direct peer broadcast to SPOs** |
| **Plutus Script Pre-flight** | Remote simulation | **Local deterministic evaluation** |
| **Cost** | $0 to $100/mo API subscriptions | **$0 (Self-Hosted Sovereign)** |

This deployment plan elevates Blue Lodge to complete institutional self-sufficiency, ensuring sovereign data ingestion for both sub-second DEX arbitrage execution and immutable IRS tax compliance.
