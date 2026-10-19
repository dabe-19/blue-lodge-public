# Sovereign Dolos Node & Autonomous Cardano DEX Trading Engine Blueprint

> **Status:** Architecture Approved via /grill-me Alignment  
> **Author:** George & Antigravity IDE  
> **Target Framework:** Blue Lodge / Rust `george-web` / TxPipe Dolos / POSIX Event Bus  
> **Design Philosophy:** 100% Sovereign Ingestion, Sub-millisecond Execution, Zero Flooding, Strict Capital Protection

---

## 1. Executive Summary & Design Invariants

This document establishes the technical blueprint for migrating Blue Lodge from external cloud APIs (GeckoTerminal, Blockfrost, Koios) to a **self-sovereign, local-first Cardano node and autonomous execution infrastructure**.

### Core Invariants:
1. **Zero External Data Leakage on Hot Path:** All real-time DEX pool reserves, UTXO states, and mempool transactions are read directly from local Dolos storage (< 1ms latency). External APIs (Koios) are strictly relegated to deep historical Byron-era archive lookups (> 1 year old).
2. **Deterministic Capital Floor & Graduating Allocation:** The 10 ADA reserve floor is immutable. When spendable capital is constrained, position sizing scales dynamically via a graduating percentage allocation ($20\% - 50\%$ of spendable surplus), ensuring continuous operation without risking execution failure.
3. **Rust Sieve / Damper Pattern:** Raw P2P block and mempool streams (50+ txs/sec) are processed and filtered in Rust memory. The POSIX Event Bus (`event_bus.fifo`) receives only qualified, actionable signals (< 10 events/hour), completely preventing bus flooding.
4. **Execution Safety Interlock (`AUTO / MANUAL`):** In `MANUAL` mode, all detected arbitrage opportunities trigger dry-run Plutus simulations and stream directly to the hourly OSINT report. In `AUTO` mode, transactions are signed and submitted autonomously only when guaranteed net-positive return criteria are proven.
5. **Clean Interface Aesthetics:** Visual design follows clean text descriptors (`AUTO / MANUAL`, `DOLOS SYNCED`, `MEMPOOL ACTIVE`) with no extraneous emojis or superfluous badge styling.

---

## 2. System Architecture & Topology

```
+------------------------------------------------------------------------------------+
|                                    BLUE LODGE                                      |
|                                                                                    |
|  +------------------------+      +-----------------------+     +----------------+  |
|  | Sovereign DEX Desk     |      | 5-Phase Arbitrage     |     | OSINT Hourly   |  |
|  | (AUTO/MANUAL Cockpit)  |      | Execution Engine      |     | Signal Report  |  |
|  +-----------+------------+      +-----------+-----------+     +--------+-------+  |
|              ^                               ^                          ^          |
|              | HTTP / WS                     | Bash / Process           | Spool    |
|              v                               v                          v          |
|  +------------------------------------------------------------------------------+  |
|  |                    Rust Backend Engine (`george-web`)                        |  |
|  |                                                                              |  |
|  |  +-----------------------+  +----------------------+  +-------------------+  |  |
|  |  | Dolos gRPC / Socket   |  | In-Memory Predicate  |  | FIFO Bus Bridge   |  |  |
|  |  | Stream Ingestion      |  | Sieve & AMM Math     |  | (event_bus.fifo)  |  |  |
|  |  +-----------+-----------+  +----------+-----------+  +---------+---------+  |  |
|  +--------------|-------------------------|------------------------|------------+  |
+-----------------|-------------------------|------------------------|---------------+
                  |                         |                        |
                  | Unix Socket / gRPC      |                        | Qualified Signals
                  v                         |                        v
+------------------------------------+      |           +----------------------------+
| DOLOS DATA NODE (Local Container)  |      |           | BLUE LODGE EVENT BUS       |
| • TxPipe Dolos v1.x (Rust)         |      |           | • event_bus.fifo           |
| • Sliding Window Archive (~35 GB)  |      |           | • reactors.json            |
| • Mini-Blockfrost HTTP (:8000)     |      |           +--------------+-------------+
| • gRPC Streaming (:50051)          |      |                          |
| • RAM Footprint: ~1.8 GB           |      |                          v
+------------------------------------+      |           +----------------------------+
                                            +---------> | AUTONOMIC REACTORS         |
                                                        | • rx_dex_arbitrage         |
                                                        | • rx_stale_order_reclaim   |
                                                        | • rx_wallet_intake         |
                                                        +----------------------------+
```

---

## 3. Component Specifications

### 3.1 Dolos Node Configuration (`deploy/dolos/daemon.toml`)

```toml
[node]
network = "mainnet"
storage_profile = "sliding_window"
window_epochs = 36  # Retains ~6 months of full transaction history (~35 GB disk)

[storage]
path = "/var/lib/dolos/db"

[sync]
peer_address = "relays-new.cardano-mainnet.iohk.io:3001"

[serve.grpc]
listen_address = "0.0.0.0:50051"

[serve.minibf]
listen_address = "0.0.0.0:8000"

[serve.n2c]
socket_path = "/ipc/node.socket"
```

### 3.2 Rust Sieve & Event Bus Damper (`web/src/dolos/`)

The Rust server connects directly to Dolos via gRPC (`tonic`) or Unix domain socket.
- **In-Memory Predicate:** Evaluates incoming mempool and block transactions against registered pools and wallet addresses.
- **AMM Math Invariant:** Computes reserve ratios for watched pairs (e.g., ADA/IAG, ADA/SNEK, ADA/WMTX).
- **FIFO Egress:** If $Spread \ge Hurdle$, formats a single-line NDJSON envelope $< PIPE\_BUF$ (4096 bytes) and writes atomically to `.george/ipc/event_bus.fifo`.

```json
{"topic":"cardano.dex.spread_detected","asset":"IAG","buy_pool":"minswap_v2","sell_pool":"sundae_v3","gross_spread_pct":2.14,"net_return_ada":1.842,"timestamp":1791334800}
```

---

## 4. Capital Allocation & Stale Order Engine

### 4.1 Graduating Percentage Capital Model
When wallet capital is below the full allocation ceiling (e.g. 100 ADA), the allocator dynamically adjusts position size:

$$\text{Spendable Balance} = \max(0, \text{Total Balance} - \text{Floor Reserve (10.0 ADA)})$$

$$\text{Position Size} = \min\left(\text{Max Policy Cap}, \text{Spendable Balance} \times \alpha\right)$$

Where $\alpha$ scales with available capital:
- If $\text{Spendable} \le 20 \text{ ADA} \implies \alpha = 0.25$ (Trade size: $2.5 - 5.0 \text{ ADA}$)
- If $20 < \text{Spendable} \le 50 \text{ ADA} \implies \alpha = 0.35$ (Trade size: $7.0 - 17.5 \text{ ADA}$)
- If $\text{Spendable} > 50 \text{ ADA} \implies \alpha = 0.50$ (Up to max policy cap)

**Safety Rule:** If $\text{Net Expected Return} \le \text{Total Fees} + 0.50 \text{ ADA}$, the trade is halted immediately regardless of sizing.

### 4.2 Automated Stale Order Reclaimer
1. **Trigger Condition:** Orders sitting in script addresses for $> 48\text{ hours}$ or where spot price has drifted $> \pm 3.5\%$ from limit trigger.
2. **Reclaim Action:** George constructs the cancellation transaction, claims the locked UTXO and refundable deposit (~2.0 ADA), and routes capital back into the spendable pool.
3. **Re-listing:** If the market structure remains favorable, George calculates the updated fair-market entry and posts a refreshed order.

---

## 5. Sovereign Charting Architecture

### 5.1 Elimination of GeckoTerminal
[`lib/tools/chart_data.py`](lib/tools/chart_data.py) is rewritten to query Dolos Mini-Blockfrost and local SQLite reserves.
- Historical OHLCV bars are constructed from on-chain pool swaps.
- Current spot is derived directly from the active pool UTXO $(x \cdot y = k)$.

### 5.2 Cardano-Native Overlays
Built on top of the vendored `LightweightCharts` canvas:
1. **Constant-Product Liquidity Curve:** Visualizes price impact and slippage boundaries for trade sizes $10 - 500 \text{ ADA}$.
2. **Batcher Queue Pressure Bar:** Measures unconfirmed swap UTXOs waiting at the DEX script address to predict execution lag.
3. **Arbitrage Spread Corridor:** Plots real-time spread bands between Minswap V2 and secondary AMMs.

---

## 6. Phased Implementation Roadmap

| Phase | Milestone | Deliverables | Verification Gate |
| :--- | :--- | :--- | :--- |
| **Phase 1** | **Dolos Container Deployment** | `deploy/dolos/docker-compose.yml`, `daemon.toml`, bootstrap script | Dolos synced to tip, port 8000 (MiniBF) and 50051 (gRPC) active |
| **Phase 2** | **Rust Sieve & Event Bus Bridge** | `web/src/dolos/` module, FIFO emitter | Filtered spread signals appear in `.george/ipc/event_bus.fifo` |
| **Phase 3** | **Capital Allocator & Stale Reclaimer** | Updated `cardano_arbitrage_graph.sh` & `cardano_orders.py` | Graduating percentage dry-run passes test harness |
| **Phase 4** | **Sovereign Chart Data Pipeline** | Updated `chart_data.py` (Local Dolos/SQLite feed) | Chart renders live without any internet / GeckoTerminal calls |
| **Phase 5** | **Desk Cockpit UI & AUTO/MANUAL** | `web/static/index.html` & `desk.js` controls | Toggle switches between dry-run OSINT logging and live execution |

---

## 7. Operational Cockpit Specification

The DEX Desk interface will feature clean text descriptors:
- **Operating Mode:** `[AUTO]` / `[MANUAL]` switch with confirmation modal before arming live execution.
- **Node Status Indicator:** `DOLOS MAINNET · SYNCED 100% · LATENCY 0.4ms`
- **Mempool Stream:** Real-time counter of pending transactions across target AMMs.
- **Stale Orders:** One-click `[RECLAIM & RE-LIST]` action per stale UTXO.
