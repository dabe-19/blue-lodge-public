#!/usr/bin/env bash
# ==============================================================================
#  BLUE LODGE LOCAL CARDANO NODE + OGMIOS + KUPO STACK BOOTSTRAPPER
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$BASE_DIR/config"
DATA_DIR="$BASE_DIR/data"

mkdir -p "$CONFIG_DIR" "$DATA_DIR/db" "$DATA_DIR/ipc" "$DATA_DIR/kupo"

echo "======================================================================"
echo "  BLUE LODGE: CARDANO NODE + OGMIOS + KUPO SOVEREIGN STACK DEPLOYER"
echo "======================================================================"

# 1. Fetch Official Mainnet Genesis and Node Configs
BOOK_URL="https://book.play.dev.cardano.org/environments/mainnet"
FILES=(
    "config.json:mainnet-config.json"
    "topology.json:mainnet-topology.json"
    "byron-genesis.json:mainnet-byron-genesis.json"
    "shelley-genesis.json:mainnet-shelley-genesis.json"
    "alonzo-genesis.json:mainnet-alonzo-genesis.json"
    "conway-genesis.json:mainnet-conway-genesis.json"
)

echo "[*] Ensuring official Cardano Mainnet configuration files are present in $CONFIG_DIR..."
for item in "${FILES[@]}"; do
    REMOTE="${item%%:*}"
    LOCAL="${item##*:}"
    TARGET="$CONFIG_DIR/$LOCAL"
    if [ ! -f "$TARGET" ]; then
        echo "    Downloading $LOCAL..."
        curl -fsSL "$BOOK_URL/$REMOTE" -o "$TARGET"
    fi
done

# Adjust config file references in mainnet-config.json to match container layout
if [ -f "$CONFIG_DIR/mainnet-config.json" ]; then
    sed -i 's/"ByronGenesisFile": "byron-genesis.json"/"ByronGenesisFile": "\/config\/mainnet-byron-genesis.json"/g' "$CONFIG_DIR/mainnet-config.json" 2>/dev/null || true
    sed -i 's/"ShelleyGenesisFile": "shelley-genesis.json"/"ShelleyGenesisFile": "\/config\/mainnet-shelley-genesis.json"/g' "$CONFIG_DIR/mainnet-config.json" 2>/dev/null || true
    sed -i 's/"AlonzoGenesisFile": "alonzo-genesis.json"/"AlonzoGenesisFile": "\/config\/mainnet-alonzo-genesis.json"/g' "$CONFIG_DIR/mainnet-config.json" 2>/dev/null || true
    sed -i 's/"ConwayGenesisFile": "conway-genesis.json"/"ConwayGenesisFile": "\/config\/mainnet-conway-genesis.json"/g' "$CONFIG_DIR/mainnet-config.json" 2>/dev/null || true
fi

echo "[+] Configurations verified."

# 2. Check Disk Space
AVAIL_GB=$(df -BG "$DATA_DIR" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
echo "[*] Available Disk Space on Target Mount: ${AVAIL_GB} GB"
if [ "$AVAIL_GB" -lt 180 ]; then
    echo "[!] WARNING: Full mainnet sync requires ~180 GB storage. Available: ${AVAIL_GB} GB."
    echo "    Consider mounting an external NVMe SSD to $DATA_DIR/db if space is constrained."
fi

# 3. Check for existing snapshot
if [ ! -d "$DATA_DIR/db/immutable" ] || [ -z "$(ls -A "$DATA_DIR/db/immutable" 2>/dev/null)" ]; then
    echo "[!] No ledger snapshot found in $DATA_DIR/db."
    echo "    Launching Mithril fast-bootstrap synchronizer..."
    "$SCRIPT_DIR/sync_mithril.sh"
fi

# 4. Launch Docker Compose Stack
echo "[*] Launching containers via docker compose..."
cd "$BASE_DIR"
docker compose up -d

echo "======================================================================"
echo "[+] CONTAINERS INITIALIZED:"
docker compose ps

echo ""
echo "[*] Waiting for services to become healthy..."
echo "    - Ogmios HTTP/WS: http://localhost:1337"
echo "    - Kupo UTXO REST: http://localhost:1442"
echo ""
echo "To monitor logs: cd $BASE_DIR && docker compose logs -f"
echo "To switch Blue Lodge primary provider to local node, set:"
echo "    export DEFAULT_CARDANO_PROVIDER=local"
echo "======================================================================"
