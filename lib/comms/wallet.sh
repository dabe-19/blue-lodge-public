#!/bin/bash
# ── George: Cryptocurrency Wallet Manager ──────────────────────
# Manages Bitcoin, Cardano, and Solana wallets with vault storage.

[ -n "${_LIB_WALLET_LOADED:-}" ] && return 0; _LIB_WALLET_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh"

MEMPOOL_API="https://mempool.space/api"
BLOCKFROST_API="${BLOCKFROST_BASE_URL:-https://cardano-mainnet.blockfrost.io/api}"
BLOCKFROST_API="${BLOCKFROST_API%/v0}/v0"
SOLANA_RPC="https://api.mainnet-beta.solana.com"

MEMPOOL_TESTNET_API="https://mempool.space/testnet/api"
BLOCKFROST_TESTNET_API="${BLOCKFROST_TESTNET_BASE_URL:-https://cardano-testnet.blockfrost.io/api}"
BLOCKFROST_TESTNET_API="${BLOCKFROST_TESTNET_API%/v0}/v0"
SOLANA_TESTNET_RPC="https://api.devnet.solana.com"

WALLET_NETWORK="${WALLET_NETWORK:-mainnet}"

wallet_set_network() {
    local net="${1:-mainnet}"
    case "$net" in
        mainnet|testnet) WALLET_NETWORK="$net"; ui_ok "Wallet network: $WALLET_NETWORK" ;;
        *) ui_err "Unknown network: $net (use mainnet or testnet)"; return 1 ;;
    esac
}

_wallet_mempool_api() { [ "$WALLET_NETWORK" = "testnet" ] && echo "$MEMPOOL_TESTNET_API" || echo "$MEMPOOL_API"; }
_wallet_blockfrost_api() { [ "$WALLET_NETWORK" = "testnet" ] && echo "$BLOCKFROST_TESTNET_API" || echo "$BLOCKFROST_API"; }
_wallet_solana_rpc() { [ "$WALLET_NETWORK" = "testnet" ] && echo "$SOLANA_TESTNET_RPC" || echo "$SOLANA_RPC"; }

_wallet_require_vault() {
    if ! declare -f secrets_set &>/dev/null; then
        ui_err "Secrets vault not loaded"; return 1
    fi
}

# ── Bitcoin ────────────────────────────────────────────────────
btc_set_address() {
    local address="$1"
    [ -z "$address" ] && { ui_err "Usage: btc_set_address <bitcoin_address>"; return 1; }
    _wallet_require_vault || return 1
    secrets_set "btc_address" "$address" && ui_ok "Bitcoin address stored"
}

btc_set_key() {
    local privkey="$1"
    [ -z "$privkey" ] && { ui_err "Usage: btc_set_key <wif_private_key>"; return 1; }
    _wallet_require_vault || return 1
    secrets_set "btc_private_key" "$privkey" && ui_ok "Bitcoin private key stored in vault"
}

btc_get_address() {
    _wallet_require_vault || return 1
    secrets_get "btc_address" 2>/dev/null
}

btc_balance() {
    local address; address=$(btc_get_address) || { ui_err "No Bitcoin address configured. Run: /wallet btc address <addr>"; return 1; }
    local api; api=$(_wallet_mempool_api)
    local response; response=$(curl -s "${api}/address/${address}")
    local funded spent
    funded=$(echo "$response" | jq -r '.chain_stats.funded_txo_sum // 0')
    spent=$(echo "$response" | jq -r '.chain_stats.spent_txo_sum // 0')
    local balance_sat=$(( funded - spent ))
    local balance_btc; balance_btc=$(echo "scale=8; $balance_sat / 100000000" | bc 2>/dev/null || echo "$balance_sat sat")
    printf "  %bBitcoin Balance:%b %s BTC (%s sat)\n" "$C_CYAN" "$C_RESET" "$balance_btc" "$balance_sat"
    printf "  %bAddress:%b        %s\n  %bNetwork:%b        %s\n" "$C_DIM" "$C_RESET" "$address" "$C_DIM" "$C_RESET" "$WALLET_NETWORK"
}

btc_transactions() {
    local address; address=$(btc_get_address) || { ui_err "No Bitcoin address configured"; return 1; }
    local api; api=$(_wallet_mempool_api)
    local response; response=$(curl -s "${api}/address/${address}/txs")
    echo "$response" | jq -r '.[:10][] | "  \(.txid[:16])...  \(.status.confirmed // false)  \(.status.block_time // "pending" | if type == "number" then (. | todate) else . end)"' 2>/dev/null
}

btc_send() {
    local to_addr="$1" amount_btc="$2"
    [ -z "$to_addr" ] || [ -z "$amount_btc" ] && { ui_err "Usage: btc_send <to_address> <amount_btc>"; return 1; }

    if command -v bitcoin-cli &>/dev/null; then
        local privkey; privkey=$(secrets_get "btc_private_key" 2>/dev/null) || { ui_err "No Bitcoin private key in vault"; return 1; }
        ui_warn "Sending $amount_btc BTC to $to_addr via bitcoin-cli"
        bitcoin-cli importprivkey "$privkey" "" false 2>/dev/null
        local txid; txid=$(bitcoin-cli sendtoaddress "$to_addr" "$amount_btc" 2>&1)
        local status=$?; privkey=""
        if [ $status -eq 0 ]; then ui_ok "Sent! TxID: $txid"; else ui_err "Send failed: $txid"; return 1; fi
    elif command -v electrum &>/dev/null; then
        ui_warn "Sending $amount_btc BTC to $to_addr via Electrum"
        local txid; txid=$(electrum payto "$to_addr" "$amount_btc" 2>&1 | electrum broadcast - 2>&1)
        if [ $? -eq 0 ]; then ui_ok "Sent! TxID: $txid"; else ui_err "Send failed: $txid"; return 1; fi
    else
        ui_err "No Bitcoin CLI tool found (need bitcoin-cli or electrum)"; return 1
    fi
}

# ── Cardano ────────────────────────────────────────────────────
ada_set_api_key() {
    local key="$1"
    [ -z "$key" ] && { ui_err "Usage: ada_set_api_key <blockfrost_project_id>"; return 1; }
    _wallet_require_vault || return 1
    secrets_set "blockfrost_key" "$key" && ui_ok "Blockfrost API key stored"
}

ada_set_address() {
    local address="$1"
    [ -z "$address" ] && { ui_err "Usage: ada_set_address <cardano_address>"; return 1; }
    _wallet_require_vault || return 1
    secrets_set "ada_address" "$address" && ui_ok "Cardano address stored"
}

ada_set_signing_key() {
    local key_content="$1"
    [ -z "$key_content" ] && { ui_err "Usage: ada_set_signing_key <signing_key_content>"; return 1; }
    _wallet_require_vault || return 1
    secrets_set "ada_signing_key" "$key_content" && ui_ok "Cardano signing key stored in vault"
}

_ada_api_key() {
    local k
    k=$(secrets_get "blockfrost_key" 2>/dev/null || true)
    [ -z "$k" ] && k="${BLOCKFROST_PROJECT_ID:-}"
    [ -n "$k" ] && echo "$k"
}

_wallet_py() {
    if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
        echo "$LODGE_DIR/.venv/bin/python"
    else
        echo "python3"
    fi
}

wallet_receive() {
    local chain="${1:-cardano}"
    shift 2>/dev/null || true
    case "$chain" in
        ada|cardano) chain="cardano" ;;
        pol|polygon|matic) chain="polygon" ;;
        eth|ethereum) chain="ethereum" ;;
        btc|bitcoin) chain="btc" ;;
        sol|solana) chain="sol" ;;
    esac
    local py; py=$(_wallet_py)
    local out
    out=$(PYTHONPATH="$LODGE_DIR" "$py" "$LODGE_DIR/lib/tools/wallet/keystore.py" receive --chain "$chain" "$@" 2>/dev/null)
    if [ -z "$out" ] || [ "$(echo "$out" | jq -r '.status // empty' 2>/dev/null)" != "ok" ]; then
        ui_err "Receive lookup failed: $(echo "$out" | jq -r '.message // "unknown error"' 2>/dev/null)"
        return 1
    fi
    local addr uri exp qr_ansi
    addr=$(echo "$out" | jq -r '.address // empty')
    uri=$(echo "$out" | jq -r '.payment_uri // empty')
    exp=$(echo "$out" | jq -r '.explorer_url // empty')
    qr_ansi=$(echo "$out" | jq -r '.qr_ansi // empty')
    ui_section "Receive (${chain^^})"
    printf "  %bAddress:%b      %s\n" "$C_CYAN" "$C_RESET" "$addr"
    printf "  %bPayment URI:%b  %s\n" "$C_DIM" "$C_RESET" "$uri"
    [ -n "$exp" ] && printf "  %bExplorer:%b     %s\n" "$C_DIM" "$C_RESET" "$exp"
    if [ -n "$qr_ansi" ]; then
        echo ""
        echo "$qr_ansi" | sed 's/^/    /'
    fi
}

_ada_api() {
    local endpoint="$1"
    local api_key; api_key=$(_ada_api_key) || { ui_err "No Blockfrost API key. Run: /wallet ada apikey <key>"; return 1; }
    curl -s -H "project_id: ${api_key}" "$(_wallet_blockfrost_api)${endpoint}"
}

ada_balance() {
    local py; py=$(_wallet_py)
    local ks_out
    ks_out=$(PYTHONPATH="$LODGE_DIR" "$py" "$LODGE_DIR/lib/tools/wallet/keystore.py" balance --id "${1:-agent-hot}" 2>/dev/null)
    if [ "$(echo "$ks_out" | jq -r '.status // empty' 2>/dev/null)" = "ok" ]; then
        local ada addr lovelace
        ada=$(echo "$ks_out" | jq -r '.ada // 0')
        lovelace=$(echo "$ks_out" | jq -r '.lovelace // 0')
        addr=$(echo "$ks_out" | jq -r '.address // ""')
        printf "  %bCardano Balance:%b %s ADA (%s lovelace)\n" "$C_CYAN" "$C_RESET" "$ada" "$lovelace"
        printf "  %bAddress:%b        %s\n  %bNetwork:%b        %s\n" "$C_DIM" "$C_RESET" "$addr" "$C_DIM" "$C_RESET" "$WALLET_NETWORK"
        local tokens
        tokens=$(echo "$ks_out" | jq -r '.tokens[]? | "    \(.symbol // .unit[:16]): \(.amount // .quantity)"' 2>/dev/null)
        [ -n "$tokens" ] && printf "  %bNative tokens:%b\n%s\n" "$C_DIM" "$C_RESET" "$tokens"
        return 0
    fi
    local address; address=$(secrets_get "ada_address" 2>/dev/null) || { ui_err "No Cardano address configured. Run: /wallet ada address <addr>"; return 1; }
    local response; response=$(_ada_api "/addresses/${address}") || return 1
    local error; error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    [ -n "$error" ] && { ui_err "Blockfrost: $(echo "$response" | jq -r '.message // "unknown"' 2>/dev/null)"; return 1; }

    local lovelace; lovelace=$(echo "$response" | jq -r '.amount[] | select(.unit == "lovelace") | .quantity // "0"' 2>/dev/null)
    [ -z "$lovelace" ] && lovelace="0"
    local ada; ada=$(echo "scale=6; ${lovelace} / 1000000" | bc 2>/dev/null || echo "${lovelace} lovelace")
    printf "  %bCardano Balance:%b %s ADA (%s lovelace)\n" "$C_CYAN" "$C_RESET" "$ada" "$lovelace"
    printf "  %bAddress:%b        %s\n  %bNetwork:%b        %s\n" "$C_DIM" "$C_RESET" "${address:0:40}..." "$C_DIM" "$C_RESET" "$WALLET_NETWORK"

    local tokens; tokens=$(echo "$response" | jq -r '.amount[] | select(.unit != "lovelace") | "    \(.unit[:16])... = \(.quantity)"' 2>/dev/null)
    [ -n "$tokens" ] && printf "  %bNative tokens:%b\n%s\n" "$C_DIM" "$C_RESET" "$tokens"
}

ada_transactions() {
    local address
    address=$(secrets_get "ada_address" 2>/dev/null || true)
    if [ -z "$address" ]; then
        local py; py=$(_wallet_py)
        address=$(PYTHONPATH="$LODGE_DIR" "$py" "$LODGE_DIR/lib/tools/wallet/keystore.py" receive --chain cardano 2>/dev/null | jq -r '.address // empty')
    fi
    [ -z "$address" ] && { ui_err "No Cardano address configured"; return 1; }
    local response; response=$(_ada_api "/addresses/${address}/transactions?count=10&order=desc") || return 1
    echo "$response" | jq -r '.[]? | "  \(.tx_hash[:16])...  block \(.block_height)  \(.block_time | todate)"' 2>/dev/null
}

ada_send() {
    local to_addr="$1" amount_ada="$2"
    shift 2 2>/dev/null || true
    [ -z "$to_addr" ] || [ -z "$amount_ada" ] && {
        ui_err "Usage: /wallet ada send <to_address> <amount> [--token SYM] [--message MSG] [--execute]"
        return 1
    }
    local py; py=$(_wallet_py)
    local out
    out=$(PYTHONPATH="$LODGE_DIR" "$py" "$LODGE_DIR/lib/tools/wallet/keystore.py" send --chain cardano --to "$to_addr" --ada "$amount_ada" "$@" 2>/dev/null)
    if [ "$(echo "$out" | jq -r '.status // empty' 2>/dev/null)" = "ok" ]; then
        local tx_id fee dry
        tx_id=$(echo "$out" | jq -r '.tx_id // empty')
        fee=$(echo "$out" | jq -r '.fee_ada // empty')
        dry=$(echo "$out" | jq -r '.dry_run // true')
        if [ "$dry" = "true" ]; then
            ui_ok "Dry-run TX built! TxID: $tx_id (Fee: ${fee} ADA) — pass --execute to broadcast"
        else
            ui_ok "Broadcast Cardano TX! TxID: $tx_id (Fee: ${fee} ADA)"
        fi
        return 0
    fi
    ui_err "Cardano send failed: $(echo "$out" | jq -r '.message // "unknown error"' 2>/dev/null)"
    return 1
}

evm_balance() {
    local net="${1:-polygon}"
    local py; py=$(_wallet_py)
    local ks_out
    ks_out=$(PYTHONPATH="$LODGE_DIR" "$py" "$LODGE_DIR/lib/tools/wallet/keystore.py" balance --id agent-evm 2>/dev/null)
    if [ "$(echo "$ks_out" | jq -r '.status // empty' 2>/dev/null)" = "ok" ]; then
        local addr pol eth usdc
        addr=$(echo "$ks_out" | jq -r '.address // ""')
        pol=$(echo "$ks_out" | jq -r '.polygon.POL // 0')
        usdc=$(echo "$ks_out" | jq -r '.polygon.USDC_total // 0')
        eth=$(echo "$ks_out" | jq -r '.ethereum.ETH // 0')
        printf "  %bEVM Wallet:%b     %s\n" "$C_CYAN" "$C_RESET" "$addr"
        printf "    %bPolygon:%b      %s POL | %s USDC\n" "$C_DIM" "$C_RESET" "$pol" "$usdc"
        printf "    %bEthereum:%b     %s ETH\n" "$C_DIM" "$C_RESET" "$eth"
        return 0
    fi
    ui_err "No EVM wallet configured in keystore"
    return 1
}

evm_send() {
    local net="${1:-polygon}" to_addr="$2" amount="$3"
    shift 3 2>/dev/null || true
    [ -z "$to_addr" ] || [ -z "$amount" ] && {
        ui_err "Usage: /wallet ${net} send <to_address> <amount> [--token POL|USDC|ETH] [--execute]"
        return 1
    }
    local py; py=$(_wallet_py)
    local out
    out=$(PYTHONPATH="$LODGE_DIR" "$py" "$LODGE_DIR/lib/tools/wallet/keystore.py" send --chain "$net" --to "$to_addr" --ada "$amount" "$@" 2>/dev/null)
    if [ "$(echo "$out" | jq -r '.status // empty' 2>/dev/null)" = "ok" ]; then
        local tx_id fee dry
        tx_id=$(echo "$out" | jq -r '.tx_id // empty')
        fee=$(echo "$out" | jq -r '.fee_native // empty')
        dry=$(echo "$out" | jq -r '.dry_run // true')
        if [ "$dry" = "true" ]; then
            ui_ok "Dry-run EVM TX signed! TxID: $tx_id (Est. gas: ${fee}) — pass --execute to broadcast"
        else
            ui_ok "Broadcast EVM TX! TxID: $tx_id"
        fi
        return 0
    fi
    ui_err "EVM send failed: $(echo "$out" | jq -r '.message // "unknown error"' 2>/dev/null)"
    return 1
}

# ── Solana ─────────────────────────────────────────────────────
sol_set_address() {
    local address="$1"
    [ -z "$address" ] && { ui_err "Usage: sol_set_address <solana_address>"; return 1; }
    _wallet_require_vault || return 1
    secrets_set "sol_address" "$address" && ui_ok "Solana address stored"
}

sol_set_key() {
    local key="$1"
    [ -z "$key" ] && { ui_err "Usage: sol_set_key <private_key_or_keypair_json>"; return 1; }
    _wallet_require_vault || return 1
    secrets_set "sol_private_key" "$key" && ui_ok "Solana private key stored in vault"
}

_sol_rpc() {
    local method="$1"; shift; local params="$*"
    local _payload; _payload=$(jq -n -c --arg method "$method" --argjson params "[${params}]" '{"jsonrpc":"2.0","id":1,"method":$method,"params":$params}')
    curl -s -X POST "$(_wallet_solana_rpc)" -H "Content-Type: application/json" -d "$_payload"
}

sol_balance() {
    local address; address=$(secrets_get "sol_address" 2>/dev/null) || { ui_err "No Solana address configured. Run: /wallet sol address <addr>"; return 1; }
    local response; response=$(_sol_rpc "getBalance" "\"${address}\"")
    local lamports; lamports=$(echo "$response" | jq -r '.result.value // 0' 2>/dev/null)
    local sol; sol=$(echo "scale=9; ${lamports} / 1000000000" | bc 2>/dev/null || echo "${lamports} lamports")
    printf "  %bSolana Balance:%b  %s SOL (%s lamports)\n" "$C_CYAN" "$C_RESET" "$sol" "$lamports"
    printf "  %bAddress:%b        %s\n  %bNetwork:%b        %s\n" "$C_DIM" "$C_RESET" "$address" "$C_DIM" "$C_RESET" "$WALLET_NETWORK"
}

sol_transactions() {
    local address; address=$(secrets_get "sol_address" 2>/dev/null) || { ui_err "No Solana address configured"; return 1; }
    local response; response=$(_sol_rpc "getSignaturesForAddress" "\"${address}\",{\"limit\":10}")
    echo "$response" | jq -r '.result[]? | "  \(.signature[:16])...  slot \(.slot)  \(.confirmationStatus)"' 2>/dev/null
}

sol_send() {
    local to_addr="$1" amount_sol="$2"
    [ -z "$to_addr" ] || [ -z "$amount_sol" ] && { ui_err "Usage: sol_send <to_address> <amount_sol>"; return 1; }
    command -v solana &>/dev/null || { ui_err "solana CLI not found"; return 1; }

    local privkey; privkey=$(secrets_get "sol_private_key" 2>/dev/null) || { ui_err "No Solana private key in vault"; return 1; }
    local tmp_key; tmp_key=$(mktemp)
    echo "$privkey" > "$tmp_key"; chmod 600 "$tmp_key"
    ui_warn "Sending $amount_sol SOL to $to_addr"
    local result; result=$(solana transfer --keypair "$tmp_key" --url "$(_wallet_solana_rpc)" "$to_addr" "$amount_sol" --allow-unfunded-recipient 2>&1)
    local status=$?
    shred -u "$tmp_key" 2>/dev/null || rm -f "$tmp_key"; privkey=""
    if [ $status -eq 0 ]; then ui_ok "Sent! $result"; else ui_err "Send failed: $result"; return 1; fi
}

sol_airdrop() {
    local amount="${1:-1}"
    local address; address=$(secrets_get "sol_address" 2>/dev/null) || { ui_err "No Solana address configured"; return 1; }
    [ "$WALLET_NETWORK" = "mainnet" ] && { ui_err "Airdrop only available on testnet/devnet"; return 1; }
    local lamports; lamports=$(echo "$amount * 1000000000 / 1" | bc)
    local response; response=$(_sol_rpc "requestAirdrop" "\"${address}\",${lamports}")
    local sig; sig=$(echo "$response" | jq -r '.result // empty' 2>/dev/null)
    if [ -n "$sig" ]; then ui_ok "Airdrop requested: $amount SOL (sig: ${sig:0:20}...)"; else ui_err "Airdrop failed: $(echo "$response" | jq -r '.error.message // "unknown"' 2>/dev/null)"; return 1; fi
}

# ── Status & Check ─────────────────────────────────────────────
wallet_status() {
    ui_section "Cryptocurrency Wallets"
    printf "  %bNetwork:%b %s\n\n" "$C_CYAN" "$C_RESET" "$WALLET_NETWORK"

    local py; py=$(_wallet_py)
    local ks_list
    ks_list=$(PYTHONPATH="$LODGE_DIR" "$py" "$LODGE_DIR/lib/tools/wallet/keystore.py" list 2>/dev/null)
    if [ "$(echo "$ks_list" | jq -r '.status // empty' 2>/dev/null)" = "ok" ]; then
        echo "$ks_list" | jq -r '.wallets[]? | "  • [\(.id)] \(.label) (\(.chain)) — \(.addresses.primary[:28])... [encrypted=\(.encrypted)]"' 2>/dev/null
        echo ""
    fi

    local btc_addr; btc_addr=$(secrets_get "btc_address" 2>/dev/null)
    if [ -n "$btc_addr" ]; then
        local bks="no key"; secrets_exists "btc_private_key" 2>/dev/null && bks="key in vault"
        printf "  %b₿ Bitcoin:%b     configured (%s...)\n    %bSigning:%b     %s\n" "$C_WHITE" "$C_RESET" "${btc_addr:0:12}" "$C_DIM" "$C_RESET" "$bks"
    fi

    local sol_addr; sol_addr=$(secrets_get "sol_address" 2>/dev/null)
    if [ -n "$sol_addr" ]; then
        local sks="no key"; secrets_exists "sol_private_key" 2>/dev/null && sks="key in vault"
        printf "  %b◎ Solana:%b     configured (%s...)\n    %bSigning:%b     %s\n" "$C_WHITE" "$C_RESET" "${sol_addr:0:12}" "$C_DIM" "$C_RESET" "$sks"
    fi
    ui_dim "  Use /wallet <ada|pol|btc|sol> balance | /wallet receive [chain] | /wallet <chain> send"
}

wallet_balances() {
    ui_section "Portfolio Balances"
    local has_any=false
    if ada_balance 2>/dev/null; then has_any=true; fi
    if evm_balance 2>/dev/null; then has_any=true; fi
    if secrets_exists "btc_address" 2>/dev/null; then btc_balance; has_any=true; fi
    if secrets_exists "sol_address" 2>/dev/null; then sol_balance; has_any=true; fi
    [ "$has_any" = "false" ] && ui_dim "  No wallets configured. Use /wallet <ada|pol|btc|sol> receive or address"
}

_wallet_api_healthy() {
    local url="$1" headers="${2:-}" status
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
    local issues=0 configured=0

    local btc_addr; btc_addr=$(secrets_get "btc_address" 2>/dev/null)
    if [ -n "$btc_addr" ]; then
        (( configured++ ))
        printf "  %b₿ Bitcoin%b\n    Address:  %s...  ✓\n" "$C_WHITE" "$C_RESET" "${btc_addr:0:12}"
        local api; api=$(_wallet_mempool_api)
        if _wallet_api_healthy "${api}/blocks/tip/height"; then
            printf "    API:      mempool.space ✓\n"
            local resp funded spent bal_sat bal_btc
            resp=$(curl -s "${api}/address/${btc_addr}" 2>/dev/null)
            funded=$(echo "$resp" | jq -r '.chain_stats.funded_txo_sum // 0' 2>/dev/null)
            spent=$(echo "$resp" | jq -r '.chain_stats.spent_txo_sum // 0' 2>/dev/null)
            bal_sat=$(( funded - spent ))
            bal_btc=$(echo "scale=8; $bal_sat / 100000000" | bc 2>/dev/null || echo "${bal_sat} sat")
            printf "    Balance:  %s BTC\n" "$bal_btc"
            [ "$bal_sat" -eq 0 ] && { printf "    %b⚠ Zero balance%b\n" "$C_YELLOW" "$C_RESET"; (( issues++ )); }
        else
            printf "    API:      mempool.space %b✗ unreachable%b\n" "$C_RED" "$C_RESET"; (( issues++ ))
        fi
        if secrets_exists "btc_private_key" 2>/dev/null; then printf "    Key:      in vault ✓\n"; else printf "    Key:      %bnot stored%b (view-only)\n" "$C_YELLOW" "$C_RESET"; fi
        echo ""
    fi

    local ada_addr; ada_addr=$(secrets_get "ada_address" 2>/dev/null)
    if [ -n "$ada_addr" ]; then
        (( configured++ ))
        printf "  %b₳ Cardano%b\n    Address:  %s...  ✓\n" "$C_WHITE" "$C_RESET" "${ada_addr:0:12}"
        local ada_key; ada_key=$(_ada_api_key 2>/dev/null)
        if [ -n "$ada_key" ]; then
            local api; api=$(_wallet_blockfrost_api)
            if _wallet_api_healthy "${api}/" "project_id: ${ada_key}"; then
                printf "    API:      Blockfrost ✓\n"
                local resp lovelace ada_bal
                resp=$(curl -s -H "project_id: ${ada_key}" "${api}/addresses/${ada_addr}" 2>/dev/null)
                lovelace=$(echo "$resp" | jq -r '.amount[]? | select(.unit == "lovelace") | .quantity // "0"' 2>/dev/null)
                [ -z "$lovelace" ] && lovelace="0"
                ada_bal=$(echo "scale=6; ${lovelace} / 1000000" | bc 2>/dev/null || echo "${lovelace} lovelace")
                printf "    Balance:  %s ADA\n" "$ada_bal"
                [ "$lovelace" = "0" ] && { printf "    %b⚠ Zero balance%b\n" "$C_YELLOW" "$C_RESET"; (( issues++ )); }
            else
                printf "    API:      Blockfrost %b✗ unreachable or invalid key%b\n" "$C_RED" "$C_RESET"; (( issues++ ))
            fi
        else
            printf "    API:      %b✗ No Blockfrost key%b\n" "$C_RED" "$C_RESET"; (( issues++ ))
        fi
        if secrets_exists "ada_signing_key" 2>/dev/null; then printf "    Key:      in vault ✓\n"; else printf "    Key:      %bnot stored%b (view-only)\n" "$C_YELLOW" "$C_RESET"; fi
        echo ""
    fi

    local sol_addr; sol_addr=$(secrets_get "sol_address" 2>/dev/null)
    if [ -n "$sol_addr" ]; then
        (( configured++ ))
        printf "  %b◎ Solana%b\n    Address:  %s...  ✓\n" "$C_WHITE" "$C_RESET" "${sol_addr:0:12}"
        local rpc; rpc=$(_wallet_solana_rpc)
        local h_resp; h_resp=$(curl -s -X POST "$rpc" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' 2>/dev/null)
        if [ "$(echo "$h_resp" | jq -r '.result // empty' 2>/dev/null)" = "ok" ]; then
            printf "    API:      Solana RPC ✓\n"
            local bal_resp lamports sol_bal
            bal_resp=$(_sol_rpc "getBalance" "\"${sol_addr}\"")
            lamports=$(echo "$bal_resp" | jq -r '.result.value // 0' 2>/dev/null)
            sol_bal=$(echo "scale=9; ${lamports} / 1000000000" | bc 2>/dev/null || echo "${lamports} lamports")
            printf "    Balance:  %s SOL\n" "$sol_bal"
            [ "$lamports" -eq 0 ] 2>/dev/null && { printf "    %b⚠ Zero balance%b\n" "$C_YELLOW" "$C_RESET"; (( issues++ )); }
        else
            printf "    API:      Solana RPC %b✗ unhealthy%b\n" "$C_RED" "$C_RESET"; (( issues++ ))
        fi
        if secrets_exists "sol_private_key" 2>/dev/null; then printf "    Key:      in vault ✓\n"; else printf "    Key:      %bnot stored%b (view-only)\n" "$C_YELLOW" "$C_RESET"; fi
        echo ""
    fi

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

wallet_test_transaction() {
    local chain="${1:-}" amount="${2:-}"
    [ -z "$chain" ] && { ui_err "Usage: /wallet test <btc|ada|sol> [amount]"; return 1; }
    if [ "$WALLET_NETWORK" != "testnet" ]; then
        ui_err "Test transactions are only allowed on testnet"
        ui_dim "  Switch with: /wallet network testnet"
        return 1
    fi
    case "$chain" in
        btc|bitcoin)
            local addr; addr=$(btc_get_address) || { ui_err "No Bitcoin address configured"; return 1; }
            amount="${amount:-0.00001}"
            ui_info "Test: sending $amount BTC to self ($addr)"
            btc_send "$addr" "$amount"
            ;;
        ada|cardano)
            local addr; addr=$(secrets_get "ada_address" 2>/dev/null) || { ui_err "No Cardano address configured"; return 1; }
            amount="${amount:-1.5}"
            ui_info "Test: sending $amount ADA to self ($addr)"
            ada_send "$addr" "$amount"
            ;;
        sol|solana)
            local addr; addr=$(secrets_get "sol_address" 2>/dev/null) || { ui_err "No Solana address configured"; return 1; }
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
