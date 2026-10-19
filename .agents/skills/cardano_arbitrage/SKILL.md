---
name: cardano_arbitrage
description: Sovereign Capital & Policy-Gated Cardano Trading Desk. Covers the 4-stage Cardano trading workflow (crypto_review -> crypto_scan -> crypto_plan -> crypto_execute), Tier A/B/C policy gates, standing orders, P2P microloan underwriting, and Polymarket arbitrage surveillance.
---

# Sovereign Capital & Policy-Gated Cardano Trading Engine

## 1. Strategic Mandate & Capital Boundaries

The overarching treasury directive is **Sovereign ADA Accumulation** (`1 ADA = 1 ADA`; USD price fluctuations are irrelevant to the objective). We grow liquid ADA from a small hot wallet with strict fee discipline until order sizes pass statistical gates to scale.

### Fiduciary & Policy Invariants (`.george/finance/trading_policy.json`)
* **Hot Wallet Floor:** `40.0 ADA` hard untouchable floor (`floor_ada`). Never propose or execute an order that brings free ADA below `floor_ada + fee_buffer_ada` (`10.0 ADA` fee buffer).
* **Cold Reserve:** `2,000 ADA` on the operator's Trezor (`TREZOR_CARDANO_ADDR`). Never touch it; Gate 2 can only recommend a manual operator top-up after statistical validation.
* **Position & Concentration Caps:** Maximum `2` concurrent positions (`max_positions`). One position may use up to `90%` of working capital (`free_ada - floor_ada - fee_buffer_ada`); total exposure <= `95%` of working capital; single-order pool impact <= `0.1%` (`10 bps`).
* **Minswap V2 Round-Trip Friction:**
  * Fixed cost per leg: `~2.0 ADA` batcher fee + `~0.2 ADA` L1 network tx fee (`~4.4 ADA` per round trip).
  * Pool fee per leg: tier-dependent (`0.30%` on standard pools, `1.00%` on SNEK/ADA).
  * Every trade must have positive expected net ADA (`EV > 0`) after full round-trip fees and adverse selection cost.
* **No Automatic Stop-Loss or Averaging Down:** `no_auto_stop_loss: true`, `no_averaging_down: true`. Stuck positions (`> 5 days`) are escalated to the operator rather than panic-sold.

---

## 2. The 4-Stage Cardano Trading Workflow (Mandatory)

All Cardano DEX trading MUST flow through the 4 native policy-gated tools in order:

1. **`crypto_review`** — Inspect live wallet balances, working capital, open positions, resting on-chain orders, standing orders, gate status, and freeze state.
2. **`crypto_scan`** — Scan Minswap V2 pools, fair value models, order impact, and strategy signals (`S1_inventory_exit`, `S2_shock_fade`, `S3_stable_deviation`).
3. **`crypto_plan(intent)`** — Build a policy-checked trade plan (`P-XXXXXX`, valid for 10 minutes from presentation):
   * Supports natural intents (`"buy 20 ADA of NIGHT at 0.095"`, `"exit SNEK"`, `"reclaim"`, `"reprice <order_ref> to <price>"`, `"auto"`) as well as multi-leg allocations (`"buy 12 ADA of NIGHT at 0.095; buy 10 ADA of IAG at 0.21"` or JSON `{"kind": "batch", "orders": [...]}`) under a single `P-XXXXXX` plan ID.
   * Returns `plan_id`, `tier` (`A`, `B`, or `C`), per-action EV/fee checks, and `status` (`approved`, `proposed`, or `blocked`).
4. **`crypto_execute(plan_id)`** — Execute an approved plan:
   * **Tier A (`status: "approved"`):** Repricing same side/size within `1.5 sigma`, reclaiming stale orders (`> 6h` or `> 3%` drift), selling existing inventory at `>= break-even + margin`, or buys matching an active `crypto_standing_order` envelope. Call `crypto_execute(plan_id)` immediately and report the result.
   * **Tier B (`status: "proposed"`):** New buys, pair switches, size increases, sells below break-even, strategy unlocks, or standing order creation. **STOP immediately after `crypto_plan`**, present the plan details (`plan_id`, token, ADA size, limit price, expected EV/fees) to the operator, and ask them to reply `confirm <plan_id>`. Do NOT call `crypto_execute` on an unconfirmed Tier B plan and do NOT continue running extra analysis steps after minting the plan.
   * **Tier C (`status: "blocked"`):** Breaching the 40 ADA floor, sending funds off-wallet, or mutating policy. Never executable.

### Supporting Sovereign Desk Tools
* **`crypto_standing_order`:** List, propose (`action="create"`), or revoke (`action="revoke"`) pre-authorized standing order envelopes so matching future buys execute as Tier A.
* **`crypto_journal`:** Inspect round-trip P&L, markout curves (`5m`, `30m`, `2h`, `24h`), and Gate 1 / Gate 2 readiness math.
* **`operator_ask` / `operator_notify`:** Guarded operator escalation channel for autonomous/cron runs (include `plan_id` when requesting confirmation on a proposed plan).

---

## 3. Strategy Catalog & Statistical Promotion Gates

* **S1 — Inventory Exit (`S1_inventory_exit`, LIVE):** Places maker limit sell orders on held token inventory at or above break-even + round-trip fees + required margin (`1.5%`).
* **S2 — Shock Fade (`S2_shock_fade`, SIMULATED until Gate 1):** Mean-reversion maker bids when a liquid pool experiences a `>= 2.5 sigma` 4h dislocation without an underlying CEX/fundamental shock.
* **S3 — Stablecoin Peg Deviation (`S3_stable_deviation`, SIMULATED until Gate 1):** Captures depeg reverts (`>= 1.5%` deviation) on liquid stablecoin pools (`DJED`, `USDM`, `USDC`) when discounted sufficiently below peg to cover round-trip fees.
* **Gate 1 (Simulation -> Live Strategy Unlock):** Requires `>= 30` simulated round trips with positive post-cost mean return and 95% bootstrap lower bound `> 0`.
* **Gate 2 (Capital Scale Recommendation):** Requires `>= 20` live round trips over `>= 30` days with positive net ADA, `>= 60%` fill efficiency, and max drawdown `<= 10%`.

---

## 4. P2P Loan Underwriting & Polymarket Surveillance

* **Cardano P2P Microloan Underwriting (Read/Dry-Run Capped):**
  * Tools: `fund_treasury`, `fund_state`, `fund_opportunities`, `lending_underwrite`, `lending_book`, `lending_service`.
  * Invariants: Max LTV `<= 50.0%` (`>= 200%` collateralization), Min Hurdle APR `>= 8.0%`, verified liquid collateral only (`DJED`, `MIN`, `WMTX`, `SNEK`, `IAG`).
* **Polymarket Negative-Risk Arbitrage (Read-Only Scan):**
  * Tool: `polymarket_scan` — monitors categorical markets where the sum of mutually exclusive outcome asks is `< $0.985`.
