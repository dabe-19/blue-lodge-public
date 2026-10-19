#!/usr/bin/env bash
# ==============================================================================
#  BLUE LODGE: SOVEREIGN DOLOS DATA NODE BOOTSTRAPPER
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$BASE_DIR/data"
IPC_DIR="$BASE_DIR/ipc"

mkdir -p "$DATA_DIR" "$IPC_DIR"

echo "======================================================================"
echo "  BLUE LODGE: TXPIPE DOLOS CARDANO DATA NODE DEPLOYER"
echo "======================================================================"

# 1. Pre-flight Disk Check
AVAIL_GB=$(df -BG "$DATA_DIR" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
echo "[*] Available Disk Space on Target Mount: ${AVAIL_GB} GB"
if [ "$AVAIL_GB" -lt 35 ]; then
    echo "[!] WARNING: Dolos sliding window requires ~35 GB storage. Available: ${AVAIL_GB} GB."
fi

# 2. Check Docker daemon
if ! docker info >/dev/null 2>&1; then
    echo "[!] Error: Docker daemon is not running or accessible."
    exit 1
fi

# 3. Pull latest image
echo "[*] Pulling official Dolos container (ghcr.io/txpipe/dolos:latest)..."
docker pull ghcr.io/txpipe/dolos:latest || true

# 4. Start Stack
echo "[*] Starting Dolos daemon via docker compose..."
cd "$BASE_DIR"
docker compose up -d

echo "======================================================================"
echo "[+] DOLOS DATA NODE ACTIVE"
echo "    - Mini-Blockfrost HTTP: http://localhost:8000/api/v0"
echo "    - gRPC Streaming:      localhost:50051"
echo "    - N2C Socket:          $IPC_DIR/node.socket"
echo "======================================================================"
