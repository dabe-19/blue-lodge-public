#!/usr/bin/env bash
# ==============================================================================
#  MITHRIL FAST-BOOTSTRAP SNAPSHOT SYNCHRONIZER
#  Cardano Mainnet Certified Snapshot Downloader
# ==============================================================================
#  Standard genesis syncing takes 48–72 hours across 100M+ blocks.
#  Mithril uses stake-based multi-signatures from active Cardano SPOs to prove
#  cryptographic ledger state integrity, unpacking full chain history in ~20 min.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DB_DIR="$BASE_DIR/data/db"
BIN_DIR="$BASE_DIR/bin"

mkdir -p "$DATA_DB_DIR" "$BIN_DIR"

echo "======================================================================"
echo "  CARDANO MITHRIL FAST-BOOTSTRAP ENGINE (MAINNET)"
echo "======================================================================"

# 1. Environment Configuration for Cardano Mainnet Mithril Aggregator
export AGGREGATOR_ENDPOINT="https://aggregator.release-mainnet.api.mithril.network/aggregator"
export GENESIS_VERIFICATION_KEY="5b3132372c37332c3132342c3136312c362c3133372c3133312c3231332c3230372c3131372c3139382c38352c3137362c3139392c3136322c39322c3136382c34352c3231382c3130362c32352c32372c3135392c31372c34322c32342c3135382c38392c3233302c3138382c332c3136325d"

# 2. Check or download mithril-client binary
MITHRIL_BIN="$BIN_DIR/mithril-client"
if [ ! -x "$MITHRIL_BIN" ]; then
    echo "[*] Downloading official mithril-client binary..."
    ARCH="$(uname -m)"
    if [ "$ARCH" = "x86_64" ]; then
        MITHRIL_URL="https://github.com/input-output-hk/mithril/releases/latest/download/mithril-client-linux-x64.tar.gz"
    elif [ "$ARCH" = "aarch64" ]; then
        MITHRIL_URL="https://github.com/input-output-hk/mithril/releases/latest/download/mithril-client-linux-arm64.tar.gz"
    else
        echo "[!] Unsupported architecture: $ARCH"
        exit 1
    fi

    TMP_ARCHIVE="/tmp/mithril-client.tar.gz"
    curl -fsSL "$MITHRIL_URL" -o "$TMP_ARCHIVE"
    tar -xzf "$TMP_ARCHIVE" -C "$BIN_DIR"
    chmod +x "$MITHRIL_BIN"
    rm -f "$TMP_ARCHIVE"
    echo "[+] mithril-client installed to $MITHRIL_BIN"
fi

# 3. Check existing database
if [ -d "$DATA_DB_DIR/immutable" ] && [ "$(ls -A "$DATA_DB_DIR/immutable" 2>/dev/null)" ]; then
    echo "[!] Existing database detected in $DATA_DB_DIR."
    read -p "    Wipe and restore clean snapshot from Mithril? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "[*] Snapshot sync aborted by operator."
        exit 0
    fi
    echo "[*] Wiping old database files..."
    rm -rf "${DATA_DB_DIR:?}"/*
fi

echo "[*] Querying latest certified Cardano snapshot from Mithril Aggregator..."
"$MITHRIL_BIN" cardano-db snapshot list

echo "[*] Downloading and verifying cryptographic proof of mainnet snapshot..."
"$MITHRIL_BIN" cardano-db download latest --download-dir "$DATA_DB_DIR"

echo "======================================================================"
echo "[+] SUCCESS: Cardano immutable database verified and hydrated!"
echo "    Database Path: $DATA_DB_DIR"
echo "    You may now launch the stack: docker compose up -d"
echo "======================================================================"
