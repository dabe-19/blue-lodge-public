# Sovereign Dolos Node Future Activation Runbook

This guide documents the exact procedure to activate the local sovereign Dolos data-node once dedicated storage ($\ge 400\text{ GB}$ free space on a dedicated mount or expanded WSL `.vhdx`) is attached.

---

## 1. Current Steady-State (Fallback Mode Active)

* **Autostart:** Disabled (`restart: "no"` in `docker-compose.yml`).
* **Active Routing:** 100% of Blue Lodge queries (DEX Desk, cointegration reactor, IRS tax compliance) route through **Koios v1 REST**.
* **Local Disk Consumption:** **`0 GB`**.
* **Query Latency:** **`~6.0 ms`**.

---

## 2. Pre-Flight Storage Check

Before activating the local node, verify that the host partition has **at least 350 GB – 400 GB of free space** to safely ingest the certified Mithril snapshot:

```bash
df -h ~/blue-lodge/deploy/dolos
```

If free space is under 350 GB, do **NOT** start the node or it will trigger a `No space left on device` error during snapshot decompression.

---

## 3. One-Command Mithril Bootstrap (When Ready)

Once adequate storage is available, run the bootstrap procedure to hydrate the node directly to the latest epoch in ~25 minutes:

```bash
cd ~/blue-lodge/deploy/dolos

# Step 1: Bootstrap via certified Mithril snapshot
docker run --rm \
  -v $(pwd)/daemon.toml:/etc/dolos/daemon.toml \
  -v $(pwd)/genesis:/etc/dolos/genesis \
  -v $(pwd)/data:/var/lib/dolos \
  ghcr.io/txpipe/dolos:latest \
  bootstrap mithril \
  --config /etc/dolos/daemon.toml \
  --skip-validation

# Step 2: Launch daemon in background
docker compose up -d

# Step 3: Monitor sync progression
docker logs -f --tail 30 lodge-dolos
```

---

## 4. Post-Sync Sizing & Automatic Failover

1. **Sliding Window Pruning:**
   Once Dolos reaches the chain tip, its sliding window (`max_history = 15552000`) prunes older blocks to retain strictly **36 epochs (~180 days)**, shrinking the database down to **~35 GB – 45 GB**.
   *(To retain 30 days instead, set `max_history = 2592000` in `daemon.toml` for a ~15–20 GB footprint).*

2. **Automatic Blue Lodge Promotion:**
   The instant Dolos catches up ($\text{slot\_lag} \le 120\text{s}$), Blue Lodge's `MultiProviderAdapter` automatically promotes **Local Dolos** to primary position #0, cutting query latency to `< 1ms` with 100% sovereign isolation from third-party APIs.
