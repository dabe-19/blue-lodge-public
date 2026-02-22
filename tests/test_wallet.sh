#!/bin/bash
# ── Tests: lib/wallet.sh ──────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"

# Create mock secrets functions for testing
declare -A _MOCK_SECRETS=()

secrets_set() { _MOCK_SECRETS["$1"]="$2"; }
secrets_get() {
    local val="${_MOCK_SECRETS[$1]:-}"
    [ -n "$val" ] && echo "$val" || return 1
}
secrets_exists() { [ -n "${_MOCK_SECRETS[$1]:-}" ]; }

source "$LODGE_DIR/lib/wallet.sh"

test_start "lib/wallet.sh — Cryptocurrency Wallet Manager"

# ── Network Toggle ─────────────────────────────────────────────
describe "wallet_set_network"

  it "defaults to mainnet" && {
    assert_eq "$WALLET_NETWORK" "mainnet"
  }

  it "switches to testnet" && {
    wallet_set_network "testnet" >/dev/null 2>&1
    assert_eq "$WALLET_NETWORK" "testnet"
    wallet_set_network "mainnet" >/dev/null 2>&1
  }

  it "rejects invalid network" && {
    wallet_set_network "fakenet" >/dev/null 2>&1
    assert_fail $?
  }

  it "restores to mainnet" && {
    wallet_set_network "mainnet" >/dev/null 2>&1
    assert_eq "$WALLET_NETWORK" "mainnet"
  }

# ── API Endpoint Helpers ──────────────────────────────────────
describe "API endpoints"

  it "mempool API uses mainnet by default" && {
    WALLET_NETWORK="mainnet"
    _url=$(_wallet_mempool_api)
    assert_eq "$_url" "https://mempool.space/api"
  }

  it "mempool API uses testnet when set" && {
    WALLET_NETWORK="testnet"
    _url=$(_wallet_mempool_api)
    assert_eq "$_url" "https://mempool.space/testnet/api"
    WALLET_NETWORK="mainnet"
  }

  it "blockfrost API uses mainnet by default" && {
    WALLET_NETWORK="mainnet"
    _url=$(_wallet_blockfrost_api)
    assert_contains "$_url" "mainnet"
  }

  it "blockfrost API uses testnet when set" && {
    WALLET_NETWORK="testnet"
    _url=$(_wallet_blockfrost_api)
    assert_contains "$_url" "testnet"
    WALLET_NETWORK="mainnet"
  }

  it "solana RPC uses mainnet by default" && {
    WALLET_NETWORK="mainnet"
    _url=$(_wallet_solana_rpc)
    assert_contains "$_url" "mainnet-beta"
  }

  it "solana RPC uses devnet for testnet" && {
    WALLET_NETWORK="testnet"
    _url=$(_wallet_solana_rpc)
    assert_contains "$_url" "devnet"
    WALLET_NETWORK="mainnet"
  }

# ── Bitcoin Address ───────────────────────────────────────────
describe "Bitcoin wallet"

  it "stores BTC address" && {
    _MOCK_SECRETS=()
    btc_set_address "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4" >/dev/null 2>&1
    _addr=$(secrets_get "btc_address")
    assert_eq "$_addr" "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
  }

  it "stores BTC private key" && {
    _MOCK_SECRETS=()
    btc_set_key "5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ" >/dev/null 2>&1
    secrets_exists "btc_private_key"
    assert_ok $?
  }

  it "retrieves stored address" && {
    _MOCK_SECRETS=()
    _MOCK_SECRETS["btc_address"]="bc1qtest"
    _addr=$(btc_get_address)
    assert_eq "$_addr" "bc1qtest"
  }

  it "btc_set_address requires address" && {
    btc_set_address "" >/dev/null 2>&1
    assert_fail $?
  }

  it "btc_set_key requires key" && {
    btc_set_key "" >/dev/null 2>&1
    assert_fail $?
  }

  it "btc_balance fails without address" && {
    _MOCK_SECRETS=()
    btc_balance >/dev/null 2>&1
    assert_fail $?
  }

# ── Cardano Address ──────────────────────────────────────────
describe "Cardano wallet"

  it "stores ADA address" && {
    _MOCK_SECRETS=()
    ada_set_address "addr1qxtest" >/dev/null 2>&1
    _addr=$(secrets_get "ada_address")
    assert_eq "$_addr" "addr1qxtest"
  }

  it "stores Blockfrost API key" && {
    _MOCK_SECRETS=()
    ada_set_api_key "testnetp1234abcd" >/dev/null 2>&1
    _key=$(secrets_get "blockfrost_key")
    assert_eq "$_key" "testnetp1234abcd"
  }

  it "stores signing key" && {
    _MOCK_SECRETS=()
    ada_set_signing_key "CBORKEY_DATA" >/dev/null 2>&1
    secrets_exists "ada_signing_key"
    assert_ok $?
  }

  it "ada_set_address requires address" && {
    ada_set_address "" >/dev/null 2>&1
    assert_fail $?
  }

  it "ada_set_api_key requires key" && {
    ada_set_api_key "" >/dev/null 2>&1
    assert_fail $?
  }

  it "ada_balance fails without address" && {
    _MOCK_SECRETS=()
    ada_balance >/dev/null 2>&1
    assert_fail $?
  }

# ── Solana Address ────────────────────────────────────────────
describe "Solana wallet"

  it "stores SOL address" && {
    _MOCK_SECRETS=()
    sol_set_address "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU" >/dev/null 2>&1
    _addr=$(secrets_get "sol_address")
    assert_eq "$_addr" "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"
  }

  it "stores SOL private key" && {
    _MOCK_SECRETS=()
    sol_set_key "[1,2,3,4,5]" >/dev/null 2>&1
    secrets_exists "sol_private_key"
    assert_ok $?
  }

  it "sol_set_address requires address" && {
    sol_set_address "" >/dev/null 2>&1
    assert_fail $?
  }

  it "sol_set_key requires key" && {
    sol_set_key "" >/dev/null 2>&1
    assert_fail $?
  }

  it "sol_balance fails without address" && {
    _MOCK_SECRETS=()
    sol_balance >/dev/null 2>&1
    assert_fail $?
  }

  it "sol_airdrop fails on mainnet" && {
    _MOCK_SECRETS=()
    _MOCK_SECRETS["sol_address"]="test_addr"
    WALLET_NETWORK="mainnet"
    sol_airdrop 1 >/dev/null 2>&1
    assert_fail $?
  }

# ── Send Validation ──────────────────────────────────────────
describe "Send validation"

  it "btc_send requires to_address and amount" && {
    btc_send "" "" >/dev/null 2>&1
    assert_fail $?
  }

  it "ada_send requires to_address and amount" && {
    ada_send "" "" >/dev/null 2>&1
    assert_fail $?
  }

  it "sol_send requires to_address and amount" && {
    sol_send "" "" >/dev/null 2>&1
    assert_fail $?
  }

# ── Wallet Status ─────────────────────────────────────────────
describe "wallet_status"

  it "runs without error" && {
    _MOCK_SECRETS=()
    wallet_status >/dev/null 2>&1
    assert_ok $?
  }

  it "shows configured wallet" && {
    _MOCK_SECRETS=()
    _MOCK_SECRETS["btc_address"]="bc1qtest123"
    _output=$(wallet_status 2>/dev/null)
    assert_contains "$_output" "configured"
  }

  it "shows all unconfigured state" && {
    _MOCK_SECRETS=()
    _output=$(wallet_status 2>/dev/null)
    assert_contains "$_output" "not configured"
  }

# ── Function Existence ─────────────────────────────────────────
describe "Function existence"

  it "wallet_balances is defined" && {
    declare -f wallet_balances &>/dev/null
    assert_ok $?
  }

  it "btc_transactions is defined" && {
    declare -f btc_transactions &>/dev/null
    assert_ok $?
  }

  it "ada_transactions is defined" && {
    declare -f ada_transactions &>/dev/null
    assert_ok $?
  }

  it "sol_transactions is defined" && {
    declare -f sol_transactions &>/dev/null
    assert_ok $?
  }

  it "_sol_rpc is defined" && {
    declare -f _sol_rpc &>/dev/null
    assert_ok $?
  }

  it "_ada_api is defined" && {
    declare -f _ada_api &>/dev/null
    assert_ok $?
  }

# ── Wallet Check (Health Check) ───────────────────────────────
describe "wallet_check"

  it "wallet_check is defined" && {
    declare -f wallet_check &>/dev/null
    assert_ok $?
  }

  it "runs without error (no wallets configured)" && {
    _MOCK_SECRETS=()
    wallet_check >/dev/null 2>&1
    assert_ok $?
  }

  it "shows no wallets message when empty" && {
    _MOCK_SECRETS=()
    _output=$(wallet_check 2>/dev/null)
    assert_contains "$_output" "No wallets configured"
  }

  it "_wallet_api_healthy is defined" && {
    declare -f _wallet_api_healthy &>/dev/null
    assert_ok $?
  }

# ── Test Transaction ──────────────────────────────────────────
describe "wallet_test_transaction"

  it "wallet_test_transaction is defined" && {
    declare -f wallet_test_transaction &>/dev/null
    assert_ok $?
  }

  it "requires a chain argument" && {
    wallet_test_transaction "" >/dev/null 2>&1
    assert_fail $?
  }

  it "refuses on mainnet" && {
    WALLET_NETWORK="mainnet"
    wallet_test_transaction "sol" >/dev/null 2>&1
    assert_fail $?
  }

  it "rejects unknown chain" && {
    WALLET_NETWORK="testnet"
    wallet_test_transaction "dogecoin" >/dev/null 2>&1
    assert_fail $?
    WALLET_NETWORK="mainnet"
  }

  it "btc test fails without address" && {
    WALLET_NETWORK="testnet"
    _MOCK_SECRETS=()
    wallet_test_transaction "btc" >/dev/null 2>&1
    assert_fail $?
    WALLET_NETWORK="mainnet"
  }

  it "ada test fails without address" && {
    WALLET_NETWORK="testnet"
    _MOCK_SECRETS=()
    wallet_test_transaction "ada" >/dev/null 2>&1
    assert_fail $?
    WALLET_NETWORK="mainnet"
  }

  it "sol test fails without address" && {
    WALLET_NETWORK="testnet"
    _MOCK_SECRETS=()
    wallet_test_transaction "sol" >/dev/null 2>&1
    assert_fail $?
    WALLET_NETWORK="mainnet"
  }

test_end
