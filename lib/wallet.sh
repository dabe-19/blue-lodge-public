#!/bin/bash
# ── George: Cryptocurrency Wallet Manager ──────────────────────
# Manages Bitcoin, Cardano, and Solana wallets.
# Private keys stored in the secrets vault (lib/secrets.sh).
# Balance queries via public REST APIs (no local node needed).
# Transactions via CLI tools when available, or API broadcast.
#
# Architecture:
#   Viewing (balance, tx history) → Public REST APIs
#   Receiving → Address derivation/display
#   Sending → CLI tools (bitcoin-cli, cardano-cli, solana)
#
# Dependencies: curl, jq, lib/secrets.sh

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui.sh"

# ── API Endpoints ─────────────────────────────────────────────
MEMPOOL_API="https://mempool.space/api"
BLOCKFROST_API="https://cardano-mainnet.blockfrost.io/api/v0"
SOLANA_RPC="https://api.mainnet-beta.solana.com"

# Testnet alternatives (safer for testing)
MEMPOOL_TESTNET_API="https://mempool.space/testnet/api"
BLOCKFROST_TESTNET_API="https://cardano-testnet.blockfrost.io/api/v0"
SOLANA_TESTNET_RPC="https://api.devnet.solana.com"

# Default to mainnet (toggle with wallet_set_network)
WALLET_NETWORK="${WALLET_NETWORK:-mainnet}"

# ── Network toggle ────────────────────────────────────────────
wallet_set_network() {
    local net="${1:-mainnet}"
    case "$net" in
        mainnet|testnet)
            WALLET_NETWORK="$net"
            ui_ok "Wallet network: $WALLET_NETWORK"
            ;;
        *)
            ui_err "Unknown network: $net (use mainnet or testnet)"
            return 1
            ;;
    esac
}

_wallet_mempool_api() {
    [ "$WALLET_NETWORK" = "testnet" ] && echo "$MEMPOOL_TESTNET_API" || echo "$MEMPOOL_API"
}

_wallet_blockfrost_api() {
    [ "$WALLET_NETWORK" = "testnet" ] && echo "$BLOCKFROST_TESTNET_API" || echo "$BLOCKFROST_API"
}

_wallet_solana_rpc() {
    [ "$WALLET_NETWORK" = "testnet" ] && echo "$SOLANA_TESTNET_RPC" || echo "$SOLANA_RPC"
}

# ── Check secret vault availability ──────────────────────────
_wallet_require_vault() {
    if ! declare -f secrets_set &>/dev/null; then
        ui_err "Secrets vault not loaded"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# Bitcoin
# ═══════════════════════════════════════════════════════════════

# ── Store Bitcoin wallet address ──────────────────────────────
btc_set_address() {
    local address="$1"
    if [ -z "$address" ]; then
        ui_err "Usage: btc_set_address <bitcoin_address>"
        return 1
    fi
    _wallet_require_vault || return 1
    secrets_set "btc_address" "$address"
    ui_ok "Bitcoin address stored"
}

# ── Store Bitcoin private key (WIF format) ────────────────────
btc_set_key() {
    local privkey="$1"
    if [ -z "$privkey" ]; then
        ui_err "Usage: btc_set_key <wif_private_key>"
        return 1
    fi
    _wallet_require_vault || return 1
    secrets_set "btc_private_key" "$privkey"
    ui_ok "Bitcoin private key stored in vault"
}

# ── Get stored address ────────────────────────────────────────
btc_get_address() {
    _wallet_require_vault || return 1
    secrets_get "btc_address" 2>/dev/null
}

# ── Query BTC balance (via mempool.space) ─────────────────────
btc_balance() {
    local address
    address=$(btc_get_address) || {
        ui_err "No Bitcoin address configured. Run: /wallet btc address <addr>"
        return 1
    }

    local api
    api=$(_wallet_mempool_api)
    local response
    response=$(curl -s "${api}/address/${address}")

    local funded spent
    funded=$(echo "$response" | jq -r '.chain_stats.funded_txo_sum // 0')
    spent=$(echo "$response" | jq -r '.chain_stats.spent_txo_sum // 0')

    local balance_sat=$(( funded - spent ))
    local balance_btc
    balance_btc=$(echo "scale=8; $balance_sat / 100000000" | bc 2>/dev/null || echo "$balance_sat sat")

    printf "  %bBitcoin Balance:%b %s BTC (%s sat)\n" "$C_CYAN" "$C_RESET" "$balance_btc" "$balance_sat"
    printf "  %bAddress:%b        %s\n" "$C_DIM" "$C_RESET" "$address"
    printf "  %bNetwork:%b        %s\n" "$C_DIM" "$C_RESET" "$WALLET_NETWORK"
}

# ── BTC transaction history ──────────────────────────────────
btc_transactions() {
    local address
    address=$(btc_get_address) || {
        ui_err "No Bitcoin address configured"
        return 1
    }

    local api
    api=$(_wallet_mempool_api)
    local response
    response=$(curl -s "${api}/address/${address}/txs")

    echo "$response" | jq -r '
        .[:10][] |
        "  \(.txid[:16])...  \(.status.confirmed // false)  \(.status.block_time // "pending" | if type == "number" then (. | todate) else . end)"
    ' 2>/dev/null
}

# ── BTC Send (requires bitcoin-cli or electrum) ──────────────
btc_send() {
    local to_addr="$1"
    local amount_btc="$2"

    if [ -z "$to_addr" ] || [ -z "$amount_btc" ]; then
        ui_err "Usage: btc_send <to_address> <amount_btc>"
        return 1
    fi

    # Check for CLI tools
    if command -v bitcoin-cli &>/dev/null; then
        local privkey
        privkey=$(secrets_get "btc_private_key" 2>/dev/null) || {
            ui_err "No Bitcoin private key in vault"
            return 1
        }

        ui_warn "Sending $amount_btc BTC to $to_addr via bitcoin-cli"
        ui_warn "This requires a running bitcoind with the wallet loaded"

        # Import key, create tx, sign, broadcast
        bitcoin-cli importprivkey "$privkey" "" false 2>/dev/null
        local txid
        txid=$(bitcoin-cli sendtoaddress "$to_addr" "$amount_btc" 2>&1)

        if [ $? -eq 0 ]; then
            ui_ok "Sent! TxID: $txid"
            # Clear privkey from memory
            privkey=""
        else
            ui_err "Send failed: $txid"
            privkey=""
            return 1
        fi

    elif command -v electrum &>/dev/null; then
        ui_warn "Sending $amount_btc BTC to $to_addr via Electrum"
        local txid
        txid=$(electrum payto "$to_addr" "$amount_btc" 2>&1 | electrum broadcast - 2>&1)
        if [ $? -eq 0 ]; then
            ui_ok "Sent! TxID: $txid"
        else
            ui_err "Send failed: $txid"
            return 1
        fi
    else
        ui_err "No Bitcoin CLI tool found (need bitcoin-cli or electrum)"
        ui_dim "  Install: apt install bitcoind  OR  pip install electrum"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# Cardano (ADA)
# ═══════════════════════════════════════════════════════════════

# ── Store Blockfrost API key ──────────────────────────────────
ada_set_api_key() {
    local key="$1"
    if [ -z "$key" ]; then
        ui_err "Usage: ada_set_api_key <blockfrost_project_id>"
        ui_dim "  Get one free at https://blockfrost.io"
        return 1
    fi
    _wallet_require_vault || return 1
    secrets_set "blockfrost_key" "$key"
    ui_ok "Blockfrost API key stored"
}

# ── Store Cardano address ─────────────────────────────────────
ada_set_address() {
    local address="$1"
    if [ -z "$address" ]; then
        ui_err "Usage: ada_set_address <cardano_address>"
        return 1
    fi
    _wallet_require_vault || return 1
    secrets_set "ada_address" "$address"
    ui_ok "Cardano address stored"
}

# ── Store Cardano signing key path ────────────────────────────
ada_set_signing_key() {
    local key_content="$1"
    if [ -z "$key_content" ]; then
        ui_err "Usage: ada_set_signing_key <signing_key_content>"
        return 1
    fi
    _wallet_require_vault || return 1
    secrets_set "ada_signing_key" "$key_content"
    ui_ok "Cardano signing key stored in vault"
}

_ada_api_key() {
    secrets_get "blockfrost_key" 2>/dev/null
}

# ── Cardano API call ──────────────────────────────────────────
_ada_api() {
    local endpoint="$1"
    local api_key
    api_key=$(_ada_api_key) || {
        ui_err "No Blockfrost API key. Run: /wallet ada apikey <key>"
        return 1
    }

    local api
    api=$(_wallet_blockfrost_api)

    curl -s -H "project_id: ${api_key}" "${api}${endpoint}"
}

# ── ADA balance ───────────────────────────────────────────────
ada_balance() {
    local address
    address=$(secrets_get "ada_address" 2>/dev/null) || {
        ui_err "No Cardano address configured. Run: /wallet ada address <addr>"
        return 1
    }

    local response
    response=$(_ada_api "/addresses/${address}") || return 1

    local error
    error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$error" ]; then
        ui_err "Blockfrost: $(echo "$response" | jq -r '.message // "unknown"' 2>/dev/null)"
        return 1
    fi

    local lovelace
    lovelace=$(echo "$response" | jq -r '
        .amount[] | select(.unit == "lovelace") | .quantity // "0"
    ' 2>/dev/null)
    [ -z "$lovelace" ] && lovelace="0"

    local ada
    ada=$(echo "scale=6; ${lovelace} / 1000000" | bc 2>/dev/null || echo "${lovelace} lovelace")

    printf "  %bCardano Balance:%b %s ADA (%s lovelace)\n" "$C_CYAN" "$C_RESET" "$ada" "$lovelace"
    printf "  %bAddress:%b        %s\n" "$C_DIM" "$C_RESET" "${address:0:40}..."
    printf "  %bNetwork:%b        %s\n" "$C_DIM" "$C_RESET" "$WALLET_NETWORK"

    # Show native tokens if any
    local tokens
    tokens=$(echo "$response" | jq -r '
        .amount[] | select(.unit != "lovelace") | "    \(.unit[:16])... = \(.quantity)"
    ' 2>/dev/null)
    if [ -n "$tokens" ]; then
        printf "  %bNative tokens:%b\n" "$C_DIM" "$C_RESET"
        echo "$tokens"
    fi
}

# ── ADA transaction history ──────────────────────────────────
ada_transactions() {
    local address
    address=$(secrets_get "ada_address" 2>/dev/null) || {
        ui_err "No Cardano address configured"
        return 1
    }

    local response
    response=$(_ada_api "/addresses/${address}/transactions?count=10&order=desc") || return 1

    echo "$response" | jq -r '.[]? | "  \(.tx_hash[:16])...  block \(.block_height)  \(.block_time | todate)"' 2>/dev/null
}

# ── ADA Send (requires cardano-cli) ──────────────────────────
ada_send() {
    local to_addr="$1"
    local amount_ada="$2"

    if [ -z "$to_addr" ] || [ -z "$amount_ada" ]; then
        ui_err "Usage: ada_send <to_address> <amount_ada>"
        return 1
    fi

    if ! command -v cardano-cli &>/dev/null; then
        ui_err "cardano-cli not found"
        ui_dim "  Install: See https://developers.cardano.org/docs/get-started/installing-cardano-node/"
        return 1
    fi

    local from_addr signing_key lovelace
    from_addr=$(secrets_get "ada_address" 2>/dev/null) || { ui_err "No Cardano address"; return 1; }
    signing_key=$(secrets_get "ada_signing_key" 2>/dev/null) || { ui_err "No signing key in vault"; return 1; }
    lovelace=$(echo "$amount_ada * 1000000 / 1" | bc)

    ui_warn "Sending $amount_ada ADA ($lovelace lovelace) to $to_addr"

    # Write signing key to temp file (cleared after use)
    local tmp_key
    tmp_key=$(mktemp)
    echo "$signing_key" > "$tmp_key"
    chmod 600 "$tmp_key"

    # Query UTxOs
    local utxos
    utxos=$(_ada_api "/addresses/${from_addr}/utxos") || { rm -f "$tmp_key"; return 1; }

    local tx_hash tx_ix input_lovelace
    tx_hash=$(echo "$utxos" | jq -r '.[0].tx_hash // empty')
    tx_ix=$(echo "$utxos" | jq -r '.[0].tx_index // empty')
    input_lovelace=$(echo "$utxos" | jq -r '.[0].amount[] | select(.unit=="lovelace") | .quantity // "0"' | head -1)

    if [ -z "$tx_hash" ]; then
        ui_err "No UTxOs available"
        rm -f "$tmp_key"
        return 1
    fi

    # Build, sign, submit (simplified — production would need proper fee calculation)
    local fee=200000
    local change_lovelace=$(( input_lovelace - lovelace - fee ))

    if [ "$change_lovelace" -lt 0 ]; then
        ui_err "Insufficient funds"
        rm -f "$tmp_key"
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    cardano-cli transaction build-raw \
        --tx-in "${tx_hash}#${tx_ix}" \
        --tx-out "${to_addr}+${lovelace}" \
        --tx-out "${from_addr}+${change_lovelace}" \
        --fee "$fee" \
        --out-file "${tmp_dir}/tx.raw" 2>/dev/null

    cardano-cli transaction sign \
        --tx-body-file "${tmp_dir}/tx.raw" \
        --signing-key-file "$tmp_key" \
        --out-file "${tmp_dir}/tx.signed" 2>/dev/null

    if [ -f "${tmp_dir}/tx.signed" ]; then
        # Submit via Blockfrost
        local submit_response
        local api_key
        api_key=$(_ada_api_key) || { rm -rf "$tmp_dir" "$tmp_key"; return 1; }
        submit_response=$(curl -s -X POST "$(_wallet_blockfrost_api)/tx/submit" \
            -H "project_id: ${api_key}" \
            -H "Content-Type: application/cbor" \
            --data-binary "@${tmp_dir}/tx.signed")

        local tx_id
        tx_id=$(echo "$submit_response" | jq -r '. // empty' 2>/dev/null)
        if [ -n "$tx_id" ] && [[ ! "$tx_id" =~ error ]]; then
            ui_ok "Sent! TxID: $tx_id"
        else
            ui_err "Submit failed: $submit_response"
        fi
    else
        ui_err "Transaction signing failed"
    fi

    # Cleanup
    rm -rf "$tmp_dir"
    shred -u "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
    signing_key=""
}

# ═══════════════════════════════════════════════════════════════
# Solana (SOL)
# ═══════════════════════════════════════════════════════════════

# ── Store Solana address ──────────────────────────────────────
sol_set_address() {
    local address="$1"
    if [ -z "$address" ]; then
        ui_err "Usage: sol_set_address <solana_address>"
        return 1
    fi
    _wallet_require_vault || return 1
    secrets_set "sol_address" "$address"
    ui_ok "Solana address stored"
}

# ── Store Solana private key (base58 or JSON keypair) ─────────
sol_set_key() {
    local key="$1"
    if [ -z "$key" ]; then
        ui_err "Usage: sol_set_key <private_key_or_keypair_json>"
        return 1
    fi
    _wallet_require_vault || return 1
    secrets_set "sol_private_key" "$key"
    ui_ok "Solana private key stored in vault"
}

# ── Solana RPC call ───────────────────────────────────────────
_sol_rpc() {
    local method="$1"
    shift
    local params="$*"

    local rpc
    rpc=$(_wallet_solana_rpc)

    curl -s -X POST "$rpc" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":[${params}]}"
}

# ── SOL balance ───────────────────────────────────────────────
sol_balance() {
    local address
    address=$(secrets_get "sol_address" 2>/dev/null) || {
        ui_err "No Solana address configured. Run: /wallet sol address <addr>"
        return 1
    }

    local response
    response=$(_sol_rpc "getBalance" "\"${address}\"")

    local lamports
    lamports=$(echo "$response" | jq -r '.result.value // 0' 2>/dev/null)

    local sol
    sol=$(echo "scale=9; ${lamports} / 1000000000" | bc 2>/dev/null || echo "${lamports} lamports")

    printf "  %bSolana Balance:%b  %s SOL (%s lamports)\n" "$C_CYAN" "$C_RESET" "$sol" "$lamports"
    printf "  %bAddress:%b        %s\n" "$C_DIM" "$C_RESET" "$address"
    printf "  %bNetwork:%b        %s\n" "$C_DIM" "$C_RESET" "$WALLET_NETWORK"
}

# ── SOL transaction history ──────────────────────────────────
sol_transactions() {
    local address
    address=$(secrets_get "sol_address" 2>/dev/null) || {
        ui_err "No Solana address configured"
        return 1
    }

    local response
    response=$(_sol_rpc "getSignaturesForAddress" "\"${address}\",{\"limit\":10}")

    echo "$response" | jq -r '.result[]? | "  \(.signature[:16])...  slot \(.slot)  \(.confirmationStatus)"' 2>/dev/null
}

# ── SOL Send (requires solana CLI) ───────────────────────────
sol_send() {
    local to_addr="$1"
    local amount_sol="$2"

    if [ -z "$to_addr" ] || [ -z "$amount_sol" ]; then
        ui_err "Usage: sol_send <to_address> <amount_sol>"
        return 1
    fi

    if ! command -v solana &>/dev/null; then
        ui_err "solana CLI not found"
        ui_dim "  Install: sh -c \"\$(curl -sSfL https://release.solana.com/stable/install)\""
        return 1
    fi

    local privkey
    privkey=$(secrets_get "sol_private_key" 2>/dev/null) || {
        ui_err "No Solana private key in vault"
        return 1
    }

    # Write keypair to temp file
    local tmp_key
    tmp_key=$(mktemp)
    echo "$privkey" > "$tmp_key"
    chmod 600 "$tmp_key"

    local rpc_url
    rpc_url=$(_wallet_solana_rpc)

    ui_warn "Sending $amount_sol SOL to $to_addr"

    local result
    result=$(solana transfer \
        --keypair "$tmp_key" \
        --url "$rpc_url" \
        "$to_addr" "$amount_sol" \
        --allow-unfunded-recipient \
        2>&1)

    if [ $? -eq 0 ]; then
        ui_ok "Sent! $result"
    else
        ui_err "Send failed: $result"
    fi

    # Cleanup
    shred -u "$tmp_key" 2>/dev/null || rm -f "$tmp_key"
    privkey=""
}

# ── SOL airdrop (testnet/devnet only) ────────────────────────
sol_airdrop() {
    local amount="${1:-1}"
    local address
    address=$(secrets_get "sol_address" 2>/dev/null) || {
        ui_err "No Solana address configured"
        return 1
    }

    if [ "$WALLET_NETWORK" = "mainnet" ]; then
        ui_err "Airdrop only available on testnet/devnet"
        return 1
    fi

    local response
    local lamports=$(echo "$amount * 1000000000 / 1" | bc)
    response=$(_sol_rpc "requestAirdrop" "\"${address}\",${lamports}")

    local sig
    sig=$(echo "$response" | jq -r '.result // empty' 2>/dev/null)

    if [ -n "$sig" ]; then
        ui_ok "Airdrop requested: $amount SOL (sig: ${sig:0:20}...)"
    else
        ui_err "Airdrop failed: $(echo "$response" | jq -r '.error.message // "unknown"' 2>/dev/null)"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# Portfolio / Status
# ═══════════════════════════════════════════════════════════════

wallet_status() {
    ui_section "Cryptocurrency Wallets"
    printf "  %bNetwork:%b %s\n\n" "$C_CYAN" "$C_RESET" "$WALLET_NETWORK"

    # Bitcoin
    local btc_addr
    btc_addr=$(secrets_get "btc_address" 2>/dev/null)
    if [ -n "$btc_addr" ]; then
        printf "  %b₿ Bitcoin:%b     configured (%s...)\n" "$C_WHITE" "$C_RESET" "${btc_addr:0:12}"
        local btc_key_status="no key"
        secrets_exists "btc_private_key" 2>/dev/null && btc_key_status="key in vault"
        printf "    %bSigning:%b     %s\n" "$C_DIM" "$C_RESET" "$btc_key_status"
    else
        printf "  %b₿ Bitcoin:%b     not configured\n" "$C_DIM" "$C_RESET"
    fi

    # Cardano
    local ada_addr
    ada_addr=$(secrets_get "ada_address" 2>/dev/null)
    if [ -n "$ada_addr" ]; then
        printf "  %b₳ Cardano:%b    configured (%s...)\n" "$C_WHITE" "$C_RESET" "${ada_addr:0:12}"
        local ada_api="no API key"
        secrets_exists "blockfrost_key" 2>/dev/null && ada_api="Blockfrost ✓"
        local ada_key_status="no key"
        secrets_exists "ada_signing_key" 2>/dev/null && ada_key_status="key in vault"
        printf "    %bAPI:%b         %s\n" "$C_DIM" "$C_RESET" "$ada_api"
        printf "    %bSigning:%b     %s\n" "$C_DIM" "$C_RESET" "$ada_key_status"
    else
        printf "  %b₳ Cardano:%b    not configured\n" "$C_DIM" "$C_RESET"
    fi

    # Solana
    local sol_addr
    sol_addr=$(secrets_get "sol_address" 2>/dev/null)
    if [ -n "$sol_addr" ]; then
        printf "  %b◎ Solana:%b     configured (%s...)\n" "$C_WHITE" "$C_RESET" "${sol_addr:0:12}"
        local sol_key_status="no key"
        secrets_exists "sol_private_key" 2>/dev/null && sol_key_status="key in vault"
        printf "    %bSigning:%b     %s\n" "$C_DIM" "$C_RESET" "$sol_key_status"
    else
        printf "  %b◎ Solana:%b     not configured\n" "$C_DIM" "$C_RESET"
    fi

    echo ""
    ui_dim "  Use /wallet <btc|ada|sol> balance for live balances"
}

# ── Convenience: show all balances ────────────────────────────
wallet_balances() {
    ui_section "Portfolio Balances"
    local has_any=false

    if secrets_exists "btc_address" 2>/dev/null; then
        btc_balance
        has_any=true
    fi

    if secrets_exists "ada_address" 2>/dev/null; then
        ada_balance
        has_any=true
    fi

    if secrets_exists "sol_address" 2>/dev/null; then
        sol_balance
        has_any=true
    fi

    if [ "$has_any" = "false" ]; then
        ui_dim "  No wallets configured. Use /wallet <btc|ada|sol> address <addr>"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Health Check — comprehensive wallet diagnostic
# ═══════════════════════════════════════════════════════════════

# ── Check if an API endpoint is reachable ─────────────────────
_wallet_api_healthy() {
    local url="$1"
    local headers="${2:-}"
    local status
    if [ -n "$headers" ]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" -H "$headers" "$url" 2>/dev/null)
    else
        status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    fi
    [[ "$status" =~ ^2[0-9][0-9]$ ]]
}

wallet_check() {
    ui_section "Wallet Health Check"
    printf "  %bNetwork:%b %s\n\n" "$C_CYAN" "$C_RESET" "$WALLET_NETWORK"

    local issues=0
    local configured=0

    # ── Bitcoin ────────────────────────────────────────────────
    local btc_addr
    btc_addr=$(secrets_get "btc_address" 2>/dev/null)
    if [ -n "$btc_addr" ]; then
        (( configured++ ))
        printf "  %b₿ Bitcoin%b\n" "$C_WHITE" "$C_RESET"
        printf "    Address:  %s...  ✓\n" "${btc_addr:0:12}"

        # API health
        local api
        api=$(_wallet_mempool_api)
        if _wallet_api_healthy "${api}/blocks/tip/height"; then
            printf "    API:      mempool.space ✓\n"

            # Live balance
            local response funded spent balance_sat balance_btc
            response=$(curl -s "${api}/address/${btc_addr}" 2>/dev/null)
            funded=$(echo "$response" | jq -r '.chain_stats.funded_txo_sum // 0' 2>/dev/null)
            spent=$(echo "$response" | jq -r '.chain_stats.spent_txo_sum // 0' 2>/dev/null)
            balance_sat=$(( funded - spent ))
            balance_btc=$(echo "scale=8; $balance_sat / 100000000" | bc 2>/dev/null || echo "${balance_sat} sat")
            printf "    Balance:  %s BTC\n" "$balance_btc"

            if [ "$balance_sat" -eq 0 ]; then
                printf "    %b⚠ Zero balance%b\n" "$C_YELLOW" "$C_RESET"
                (( issues++ ))
            fi
        else
            printf "    API:      mempool.space %b✗ unreachable%b\n" "$C_RED" "$C_RESET"
            (( issues++ ))
        fi

        # Key status
        if secrets_exists "btc_private_key" 2>/dev/null; then
            printf "    Key:      in vault ✓\n"
        else
            printf "    Key:      %bnot stored%b (view-only)\n" "$C_YELLOW" "$C_RESET"
        fi
        echo ""
    fi

    # ── Cardano ────────────────────────────────────────────────
    local ada_addr
    ada_addr=$(secrets_get "ada_address" 2>/dev/null)
    if [ -n "$ada_addr" ]; then
        (( configured++ ))
        printf "  %b₳ Cardano%b\n" "$C_WHITE" "$C_RESET"
        printf "    Address:  %s...  ✓\n" "${ada_addr:0:12}"

        # API key check
        local ada_key
        ada_key=$(_ada_api_key 2>/dev/null)
        if [ -n "$ada_key" ]; then
            local api
            api=$(_wallet_blockfrost_api)
            if _wallet_api_healthy "${api}/" "project_id: ${ada_key}"; then
                printf "    API:      Blockfrost ✓\n"

                # Live balance
                local response lovelace ada_bal
                response=$(curl -s -H "project_id: ${ada_key}" "${api}/addresses/${ada_addr}" 2>/dev/null)
                lovelace=$(echo "$response" | jq -r '.amount[]? | select(.unit == "lovelace") | .quantity // "0"' 2>/dev/null)
                [ -z "$lovelace" ] && lovelace="0"
                ada_bal=$(echo "scale=6; ${lovelace} / 1000000" | bc 2>/dev/null || echo "${lovelace} lovelace")
                printf "    Balance:  %s ADA\n" "$ada_bal"

                if [ "$lovelace" = "0" ]; then
                    printf "    %b⚠ Zero balance%b\n" "$C_YELLOW" "$C_RESET"
                    (( issues++ ))
                fi
            else
                printf "    API:      Blockfrost %b✗ unreachable or invalid key%b\n" "$C_RED" "$C_RESET"
                (( issues++ ))
            fi
        else
            printf "    API:      %b✗ No Blockfrost key%b\n" "$C_RED" "$C_RESET"
            (( issues++ ))
        fi

        # Key status
        if secrets_exists "ada_signing_key" 2>/dev/null; then
            printf "    Key:      in vault ✓\n"
        else
            printf "    Key:      %bnot stored%b (view-only)\n" "$C_YELLOW" "$C_RESET"
        fi
        echo ""
    fi

    # ── Solana ─────────────────────────────────────────────────
    local sol_addr
    sol_addr=$(secrets_get "sol_address" 2>/dev/null)
    if [ -n "$sol_addr" ]; then
        (( configured++ ))
        printf "  %b◎ Solana%b\n" "$C_WHITE" "$C_RESET"
        printf "    Address:  %s...  ✓\n" "${sol_addr:0:12}"

        # API health
        local rpc
        rpc=$(_wallet_solana_rpc)
        local health_resp
        health_resp=$(curl -s -X POST "$rpc" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' 2>/dev/null)
        local health_result
        health_result=$(echo "$health_resp" | jq -r '.result // empty' 2>/dev/null)

        if [ "$health_result" = "ok" ]; then
            printf "    API:      Solana RPC ✓\n"

            # Live balance
            local bal_resp lamports sol_bal
            bal_resp=$(_sol_rpc "getBalance" "\"${sol_addr}\"")
            lamports=$(echo "$bal_resp" | jq -r '.result.value // 0' 2>/dev/null)
            sol_bal=$(echo "scale=9; ${lamports} / 1000000000" | bc 2>/dev/null || echo "${lamports} lamports")
            printf "    Balance:  %s SOL\n" "$sol_bal"

            if [ "$lamports" -eq 0 ] 2>/dev/null; then
                printf "    %b⚠ Zero balance%b\n" "$C_YELLOW" "$C_RESET"
                (( issues++ ))
            fi
        else
            printf "    API:      Solana RPC %b✗ unhealthy%b\n" "$C_RED" "$C_RESET"
            (( issues++ ))
        fi

        # Key status
        if secrets_exists "sol_private_key" 2>/dev/null; then
            printf "    Key:      in vault ✓\n"
        else
            printf "    Key:      %bnot stored%b (view-only)\n" "$C_YELLOW" "$C_RESET"
        fi
        echo ""
    fi

    # ── Summary ────────────────────────────────────────────────
    if [ "$configured" -eq 0 ]; then
        ui_dim "  No wallets configured. Use /wallet <btc|ada|sol> address <addr>"
        return 0
    fi

    if [ "$issues" -eq 0 ]; then
        printf "  %bStatus:%b All %d wallet(s) healthy ✓\n" "$C_GREEN" "$C_RESET" "$configured"
    else
        printf "  %bStatus:%b %d issue(s) found across %d wallet(s)\n" "$C_YELLOW" "$C_RESET" "$issues" "$configured"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Test Transaction — safe self-send on testnet only
# ═══════════════════════════════════════════════════════════════

wallet_test_transaction() {
    local chain="${1:-}"
    local amount="${2:-}"

    if [ -z "$chain" ]; then
        ui_err "Usage: /wallet test <btc|ada|sol> [amount]"
        return 1
    fi

    # Safety: testnet only
    if [ "$WALLET_NETWORK" != "testnet" ]; then
        ui_err "Test transactions are only allowed on testnet"
        ui_dim "  Switch with: /wallet network testnet"
        return 1
    fi

    case "$chain" in
        btc|bitcoin)
            local addr
            addr=$(btc_get_address) || { ui_err "No Bitcoin address configured"; return 1; }
            amount="${amount:-0.00001}"
            ui_info "Test: sending $amount BTC to self ($addr)"
            btc_send "$addr" "$amount"
            ;;
        ada|cardano)
            local addr
            addr=$(secrets_get "ada_address" 2>/dev/null) || { ui_err "No Cardano address configured"; return 1; }
            amount="${amount:-1.5}"
            ui_info "Test: sending $amount ADA to self ($addr)"
            ada_send "$addr" "$amount"
            ;;
        sol|solana)
            local addr
            addr=$(secrets_get "sol_address" 2>/dev/null) || { ui_err "No Solana address configured"; return 1; }
            amount="${amount:-0.001}"
            ui_info "Test: sending $amount SOL to self ($addr)"
            sol_send "$addr" "$amount"
            ;;
        *)
            ui_err "Unknown chain: $chain (use btc, ada, or sol)"
            return 1
            ;;
    esac
}
