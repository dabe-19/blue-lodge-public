#!/usr/bin/env python3
"""
P1 data-foundation checks (offline). Each check prints "<name> PASS|FAIL <detail>".

Uses the real Minswap V2 batch transactions captured in
lib/tools/fixtures/minswap_v2_pool_batches_snek.json; no network.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
os.environ.setdefault("CARDANO_TEST_MODE", "1")
_TMP = tempfile.mkdtemp(prefix="george-p1-")
os.environ["MARKET_DB_PATH"] = str(Path(_TMP) / "market.db")

from lib.tools.quant import market_db as mdb  # noqa: E402
from lib.tools.quant import pool_recorder as pr  # noqa: E402

FX = json.loads((REPO / "lib/tools/fixtures/minswap_v2_pool_batches_snek.json").read_text())
LP = FX["lp_unit"]
UNIT = FX["unit"]
RESULTS = []


def check(name):
    def deco(fn):
        try:
            ok, detail = fn()
        except Exception as e:
            ok, detail = False, f"{type(e).__name__}: {e}"
        RESULTS.append(ok)
        print(f"{name} {'PASS' if ok else 'FAIL'} {detail}")
        return fn
    return deco


def fresh_con():
    p = Path(_TMP) / f"m{time.time_ns()}.db"
    os.environ["MARKET_DB_PATH"] = str(p)
    return mdb.connect(p)


@check("bech32_payment_credentials")
def _():
    o = pr.address_payment_cred("addr1w8p79rpkcdz8x9d6tft0x0dx5mwuzac2sa4gm8cvkw5hcnqst2ctf")
    p = pr.address_payment_cred("addr1z84q0denmyep98ph3tmzwsmw0j7zau9ljmsqx6a4rvaau66j2c79gy9l76sdg0xwhd7r0c0kna0tycz4y5s6mlenh8pq777e2a")
    ok = o == pr.ORDER_SCRIPT_HASH and p == "ea07b733d932129c378af627436e7cbc2ef0bf96e0036bb51b3bde6b"
    return ok, f"order={o} pool={p}"


@check("pool_datum_exact_reserves_and_fee_tier")
def _():
    tx = FX["tx_utxos"]["bfab160f99af70f476df3b0b2ea2d79716b536c722c3fc7187078ad0bfd90f04"]
    out = next(o for o in tx["outputs"] if o.get("inline_datum") and pr._qty(o, pr.POOL_NFT) == 1)
    d = pr.decode_pool_datum(out["inline_datum"])
    ok = (d and d["asset_a"] == "" and d["asset_b"] == UNIT and d["fee_a_bps"] == 100.0
          and d["reserve_a"] > 2e12 and d["reserve_b"] > 6e8)
    return ok, json.dumps(d)


@check("batch_decomposition_and_measured_batcher_fee")
def _():
    h = "ae245188cba37258ba165219c1def6d0122ec66f7bfc881167e66a4e80e5f8b2"
    r = pr.parse_batch(FX["tx_utxos"][h], "SNEK", LP[56:], UNIT, 0, 1791937830)
    rows = r["rows"]
    orders = [x for x in rows if x["kind"] == "order"]
    buy = next(x for x in orders if x["side"] == "buy")
    ok = (rows[0]["kind"] == "batch" and rows[0]["side"] == "sell" and len(orders) == 2
          and abs(buy["batcher_fee_ada"] - 2.0) < 1e-9 and buy["owner"].startswith("stake:")
          and abs(r["post_spot"] - r["reserve_ada"] / r["reserve_tok"]) < 1e-12 and rows[0]["impact_pct"] < 0)
    return ok, f"n_orders={len(orders)} fee={buy['batcher_fee_ada']} impact={rows[0]['impact_pct']:.3f}%"


@check("liquidity_only_spend_is_not_a_trade")
def _():
    h = "14860f74f999d88a6714f69543abd0630496c86e37c8299957519edee7c9149e"
    r = pr.parse_batch(FX["tx_utxos"][h], "SNEK", LP[56:], UNIT, 0, 1791936684)
    return r["rows"][0]["kind"] == "liquidity" and r["rows"][0]["eff_price"] is None, r["rows"][0]["kind"]


class FakeSource(pr._Source):
    name = "blockfrost"

    def __init__(self, con, listing):
        super().__init__(con)
        self.listing = listing

    def asset_txs(self, lp_unit, count=20, page=1, order="desc", after_height=None):
        self._log("/assets/{h}/transactions", True)
        return list(self.listing)

    def tx_utxos(self, h):
        self._log("/txs/{h}/utxos", True)
        return FX["tx_utxos"].get(h)


def _seed_pool(con):
    con.execute("INSERT OR REPLACE INTO recorder_state(pool, asset, dex, lp_unit, unit, decimals, info) VALUES (?,?,?,?,?,?,?)",
                (LP, "SNEK", "MinswapV2", LP, UNIT, 0, json.dumps({"seen": []})))
    con.commit()


@check("recorder_incremental_poll_records_only_new_txs")
def _():
    con = fresh_con()
    _seed_pool(con)
    txs = FX["asset_transactions"]  # newest first
    src = FakeSource(con, txs[2:])
    cfg = pr.load_config()
    a = pr.poll_pool(con, src, "SNEK", cfg)  # first contact: newest only
    src.listing = txs
    b = pr.poll_pool(con, src, "SNEK", cfg)  # two newer txs appeared
    c = pr.poll_pool(con, src, "SNEK", cfg)  # nothing new: listing call only
    n_snap = con.execute("SELECT COUNT(*) FROM pool_snapshots").fetchone()[0]
    calls = mdb.calls_today(con, "blockfrost")
    ok = a["new_txs"] == 1 and b["new_txs"] == 2 and c["new_txs"] == 0 and n_snap == 3 and calls == 3 + 3
    return ok, f"a={a['new_txs']} b={b['new_txs']} c={c['new_txs']} snaps={n_snap} calls={calls}"


@check("budget_degrades_then_hands_over")
def _():
    con = fresh_con()
    now = int(time.time())
    for _ in range(50):
        con.execute("INSERT INTO api_calls(ts, provider, endpoint, ok) VALUES (?,?,?,1)", (now - 10, "blockfrost", "x"))
    con.commit()
    st_hi = mdb.budget_status(con, "blockfrost", 100, now=now)   # 50 used, high hourly rate -> degrade
    st_out = mdb.budget_status(con, "blockfrost", 40, now=now)   # over limit -> stop
    cfg = {"providers": ["blockfrost", "koios"], "budgets": {"blockfrost": 40, "koios": 10}}
    src, mult, _rep = pr.pick_source(con, cfg)
    ok = st_hi["cadence_multiplier"] == 5 and st_out["cadence_multiplier"] == 0 and src is not None and src.name == "koios"
    return ok, f"hi={st_hi['cadence_multiplier']} out={st_out['cadence_multiplier']} picked={src.name if src else None}"


@check("janitor_downsamples_and_enforces_retention")
def _():
    con = fresh_con()
    now = int(time.time())
    for i in range(12):  # 2 days old: rolled into bars, kept raw
        mdb.record_snapshot(con, now - 2 * 86400 + i * 30, LP, "SNEK", 1000 + i, 300000)
    mdb.record_snapshot(con, now - 40 * 86400, LP, "SNEK", 1000, 300000)  # past raw retention
    mdb.record_cex_tick(con, now - 40 * 86400, "ADA-USD", 0.3)
    con.execute("INSERT INTO api_calls(ts, provider, endpoint, ok) VALUES (?,?,?,1)", (now - 9 * 86400, "blockfrost", "x"))
    con.commit()
    res = mdb.downsample(con, now)
    raw = con.execute("SELECT COUNT(*) FROM pool_snapshots").fetchone()[0]
    bars = con.execute("SELECT COUNT(*) FROM pool_bars_5m").fetchone()[0]
    ok = raw == 12 and bars >= 2 and res["raw_cex_deleted"] == 1 and res["api_rows_deleted"] == 1
    return ok, f"raw={raw} bars={bars} {res}"


@check("size_cap_prunes_oldest_bars_first")
def _():
    p = Path(_TMP) / "cap.db"
    con = mdb.connect(p)
    now = int(time.time())
    rows = [(now - 300 * i - (now % 300), LP, "SNEK", 1, 1, 1, 1, 1, 1, 1) for i in range(20000)]
    con.executemany("INSERT OR REPLACE INTO pool_bars_5m VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
    con.commit()
    before = con.execute("SELECT MIN(bucket) FROM pool_bars_5m").fetchone()[0]
    res = mdb.enforce_cap(con, max_bytes=400_000, path=p)
    after = con.execute("SELECT MIN(bucket), COUNT(*) FROM pool_bars_5m").fetchone()
    ok = res["size_bytes"] <= 400_000 and after[0] > before and bool(res["pruned"])
    return ok, f"size={res['size_bytes']} kept={after[1]} pruned={len(res['pruned'])}"


@check("spot_series_forward_fills_and_cex_gaps_when_stale")
def _():
    con = fresh_con()
    t0 = 1_800_000_000 - 1_800_000_000 % 300
    mdb.record_snapshot(con, t0 + 10, LP, "SNEK", 1000, 100000)
    mdb.record_snapshot(con, t0 + 1300, LP, "SNEK", 1100, 100000)
    mdb.record_cex_tick(con, t0 + 5, "ADA-USD", 0.25)
    con.commit()
    s = mdb.spot_series(con, "SNEK", t0, t0 + 1800)
    c = mdb.cex_series(con, "ADA-USD", t0, t0 + 1800)
    ok = (len(s) == 6 and abs(s[0][1] - 0.01) < 1e-12 and abs(s[-1][1] - 0.011) < 1e-12
          and len(c) == 3)  # tick valid for 15 min only
    return ok, f"spot_pts={len(s)} cex_pts={len(c)}"


@check("dimensions_use_exact_recorder_fee_tier")
def _():
    con = fresh_con()
    _seed_pool(con)
    con.execute("UPDATE recorder_state SET last_checked=?", (int(time.time()),))
    mdb.record_snapshot(con, int(time.time()) - 100, LP, "SNEK", 2_276_309.64, 653_439_699, 100.0, "tx")
    con.commit()
    con.close()
    from lib.tools import cardano_market_dimensions as dim
    saved = dim.md.load_series
    dim.md.load_series = lambda *a, **k: {"status": "unavailable", "reason": "offline test"}
    try:
        cur = dim.compute_cpmm_curve("SNEK", [100.0])
        bq = dim.inspect_batcher_queue("SNEK")
    finally:
        dim.md.load_series = saved
    ok = (cur["status"] == "ok" and cur["reserve_source"] == "pool_recorder_exact" and abs(cur["pool_fee_pct"] - 1.0) < 1e-9
          and cur["curve"][0]["slippage_pct"] > 1.0 and bq["status"] in ("FLOWING", "IDLE"))
    return ok, f"fee={cur.get('pool_fee_pct')} slip={cur['curve'][0]['slippage_pct'] if cur.get('curve') else None} bq={bq['status']}"


@check("ohlcv_series_and_recent_swaps")
def _():
    con = fresh_con()
    _seed_pool(con)
    t0 = 1_800_000_000 - (1_800_000_000 % 3600)
    for i in range(24):
        ts = t0 + i * 300 + 15
        ada_r = 100_000.0 + (i % 5) * 250.0 - (i % 3) * 150.0
        tok_r = 10_000_000.0
        spot = ada_r / tok_r
        mdb.record_snapshot(con, ts, LP, "SNEK", ada_r, tok_r, 30.0, f"tx_{i}")
        side = "buy" if i % 2 == 0 else "sell"
        con.execute(
            "INSERT OR REPLACE INTO swaps(tx, idx, ts, pool, asset, kind, side, ada_amt, tok_amt, eff_price, pre_spot, post_spot, impact_pct, owner, batcher_fee_ada, n_orders) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (f"tx_{i}", 0, ts, LP, "SNEK", "batch", side, 120.0 + i * 5, 12000.0, spot, spot * 0.999, spot, 0.25, "", 0.65, 1),
        )
    con.commit()
    s5 = mdb.ohlcv_series(con, "SNEK", step_s=300, since=t0, until=t0 + 24 * 300 - 1)
    s15 = mdb.ohlcv_series(con, "SNEK", step_s=900, since=t0, until=t0 + 24 * 300 - 1)
    s1h = mdb.ohlcv_series(con, "SNEK", step_s=3600, since=t0, until=t0 + 24 * 300 - 1)
    sw = mdb.recent_swaps(con, "SNEK", limit=10)
    con.close()
    ok = (s5["status"] == "ok" and len(s5["bars"]) == 24
          and s15["status"] == "ok" and len(s15["bars"]) == 8
          and s1h["status"] == "ok" and len(s1h["bars"]) == 2
          and s15["bars"][0]["buy_volume"] > 0 and s15["bars"][0]["sell_volume"] > 0
          and len(sw) == 10 and sw[0]["tx_hash"].startswith("tx_"))
    return ok, f"bars_5m={len(s5['bars'])} bars_15m={len(s15['bars'])} bars_1h={len(s1h['bars'])} swaps={len(sw)}"


@check("chart_overlays_kalman_vrvp_and_order_book")
def _():
    import math
    from lib.tools.quant import fair_value as fv
    from lib.tools import chart_data as cd
    y = [math.log(0.10 + 0.002 * math.sin(i * 0.3)) for i in range(80)]
    ll = fv.local_level(y, k=4, include_series=True)
    rvr = fv.rolling_variance_ratio(y, k=4, window=24)
    candles = [
        {"time": 1700000000 + i * 3600, "open": math.exp(y[i]), "high": math.exp(y[i]) * 1.005,
         "low": math.exp(y[i]) * 0.995, "close": math.exp(y[i])}
        for i in range(80)
    ]
    volume = [
        {"time": 1700000000 + i * 3600, "value": 500.0 + i * 10, "buy_volume": 300.0, "sell_volume": 200.0 + i * 10}
        for i in range(80)
    ]
    vp = cd._compute_volume_profile(candles, volume, n_bins=24)
    ob = cd._build_real_order_book("IAG", 0.10, 250_000.0, 30.0, "minswap-v2", [], [], [], [])
    ok = (len(ll.get("mu_series", [])) == 80 and len(ll.get("z_series", [])) == 80
          and len(rvr) == 80 and rvr[-1] is not None
          and len(vp.get("bins", [])) == 24 and vp["poc_price"] > 0 and vp["vah_price"] >= vp["poc_price"] >= vp["val_price"]
          and len(ob.get("asks", [])) == 6 and len(ob.get("bids", [])) == 6
          and all(r["venue"] == "MINSWAP-V2" for r in ob["asks"]))
    return ok, f"kalman_len={len(ll.get('mu_series', []))} vp_poc={vp.get('poc_price')} ob_spread={ob.get('spread_pct')}%"


print(f"SUMMARY {sum(RESULTS)}/{len(RESULTS)}")
sys.exit(0 if all(RESULTS) else 1)
