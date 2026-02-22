# George's Crypto Wallet Guide

> *"An investment in knowledge pays the best interest."* — Brother Benjamin Franklin

This is the complete operational guide for George's cryptocurrency wallet system. George can hold, check, and send **Bitcoin (BTC)**, **Cardano (ADA)**, and **Solana (SOL)** — all from the command line on your mobile device.

All private keys are stored in George's **AES-256-CBC encrypted secrets vault** (`~/.george/.vault/`). Addresses and API keys are stored there too. Nothing leaves the device unless you explicitly send a transaction.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Architecture Overview](#architecture-overview)
3. [Bitcoin (BTC)](#bitcoin-btc)
4. [Cardano (ADA)](#cardano-ada)
5. [Solana (SOL)](#solana-sol)
6. [Checking Balances](#checking-balances)
7. [Test Transactions](#test-transactions)
8. [Periodic Wallet Monitoring](#periodic-wallet-monitoring)
9. [Security Best Practices](#security-best-practices)
10. [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# 1. Switch to testnet first (always test before mainnet)
/wallet network testnet

# 2. Configure a wallet address
/wallet btc address tb1qYOUR_TESTNET_ADDRESS
/wallet sol address YOUR_SOLANA_DEVNET_ADDRESS

# 3. Check balances
/wallet balance

# 4. Check all wallets with health report
/wallet check

# 5. Run a test transaction (testnet/devnet only)
/wallet test sol 0.001
```

---

## Architecture Overview

George's wallet system is split into two layers:

### Viewing Layer (No Keys Required)
- **Balance checks**: Public REST API queries — no authentication needed for BTC/SOL
- **Transaction history**: Last 10 transactions per wallet
- **Portfolio overview**: All configured wallets at a glance

APIs used:
| Chain    | API               | Endpoint                                |
|----------|-------------------|-----------------------------------------|
| Bitcoin  | mempool.space     | `https://mempool.space/api`             |
| Cardano  | Blockfrost        | `https://cardano-mainnet.blockfrost.io` |
| Solana   | Solana JSON-RPC   | `https://api.mainnet-beta.solana.com`   |

### Transaction Layer (Keys Required)
- **Sending**: Requires private key in vault + CLI tool installed
- **Signing**: Keys are decrypted only for the duration of the transaction
- **Broadcast**: Transactions are signed locally and broadcast via API

CLI tools needed:
| Chain    | Tool           | Install Command                                                   |
|----------|----------------|-------------------------------------------------------------------|
| Bitcoin  | `bitcoin-cli`  | `apt install bitcoind` or `pip install electrum`                  |
| Cardano  | `cardano-cli`  | See [cardano.org/developers](https://developers.cardano.org)     |
| Solana   | `solana`       | `sh -c "$(curl -sSfL https://release.solana.com/stable/install)"`|

---

## Bitcoin (BTC)

### Getting a Bitcoin Address

**Option A: Generate locally with Electrum**
```bash
# Install Electrum
pip install electrum

# Create a new wallet
electrum create

# Get a receiving address
electrum getunusedaddress
```

**Option B: Use an existing wallet**
Export a receive address from any Bitcoin wallet (Sparrow, BlueWallet, Ledger, etc.)

### Setting Up in George

```bash
# Store your address (view-only, no key needed)
/wallet btc address bc1qYOUR_MAINNET_ADDRESS

# For sending capability, also store the private key (WIF format)
/wallet btc key 5JWIF_PRIVATE_KEY_HERE
```

### Funding Your Bitcoin Wallet

**Mainnet:**
- Send BTC from any exchange (Coinbase, Kraken, Cash App, Strike)
- Send from another wallet via the address shown in `/wallet status`
- Minimum recommended: 0.0001 BTC (~$10) for testing sends

**Testnet:**
```bash
# Switch to testnet
/wallet network testnet

# Set a testnet address (starts with tb1 or 2 or m/n)
/wallet btc address tb1qTESTNET_ADDRESS

# Get free testnet BTC from a faucet:
#   https://coinfaucet.eu/en/btc-testnet/
#   https://testnet-faucet.com/btc-testnet/
#   https://bitcoinfaucet.uo1.net/
```

### What George Can Do with BTC

| Command                          | Description                          | Requires Key? |
|----------------------------------|--------------------------------------|---------------|
| `/wallet btc balance`            | Check current BTC balance            | No            |
| `/wallet btc tx`                 | Show last 10 transactions            | No            |
| `/wallet btc send <addr> <amt>`  | Send BTC to another address          | Yes           |
| `/wallet btc address <addr>`     | Set/update the wallet address        | No            |
| `/wallet btc key <wif>`          | Store a private key in the vault     | N/A           |

### BTC Balance Interpretation

George reads the balance from `mempool.space`:
- **funded_txo_sum**: Total BTC ever received
- **spent_txo_sum**: Total BTC ever sent
- **Balance**: funded - spent (in satoshis, 1 BTC = 100,000,000 sat)

---

## Cardano (ADA)

### Prerequisites

Cardano requires a **Blockfrost API key** for balance queries and transaction history. This is free:

1. Go to [blockfrost.io](https://blockfrost.io)
2. Sign up (free tier = 50,000 requests/day)
3. Create a project (choose mainnet or testnet)
4. Copy the Project ID

### Getting a Cardano Address

**Option A: cardano-cli (advanced)**
```bash
# Generate payment keys
cardano-cli address key-gen \
    --verification-key-file payment.vkey \
    --signing-key-file payment.skey

# Build address
cardano-cli address build \
    --payment-verification-key-file payment.vkey \
    --mainnet \
    --out-file payment.addr

cat payment.addr
```

**Option B: Use an existing wallet**
Export a receive address from Daedalus, Yoroi, Nami, or Eternl.

### Setting Up in George

```bash
# Store your Blockfrost API key (required for all ADA operations)
/wallet ada apikey project_id_HERE

# Store your address
/wallet ada address addr1qYOUR_CARDANO_ADDRESS

# For sending, also store your signing key content
/wallet ada key "$(cat payment.skey)"
```

### Funding Your Cardano Wallet

**Mainnet:**
- Send ADA from any exchange (Coinbase, Kraken, Binance)
- Send from Daedalus, Yoroi, Nami, or any Cardano wallet
- Minimum recommended: 5 ADA (~$2-5) for testing sends

**Testnet:**
```bash
# Switch to testnet
/wallet network testnet

# Set a testnet address
/wallet ada address addr_test1qTESTNET_ADDRESS

# Set testnet Blockfrost key (create a testnet project on blockfrost.io)
/wallet ada apikey testnet_project_id_HERE

# Get free tADA from the Cardano Faucet:
#   https://docs.cardano.org/cardano-testnets/tools/faucet/
```

### What George Can Do with ADA

| Command                          | Description                          | Requires Key? | Requires API? |
|----------------------------------|--------------------------------------|---------------|---------------|
| `/wallet ada balance`            | Check ADA balance + native tokens    | No            | Yes           |
| `/wallet ada tx`                 | Show last 10 transactions            | No            | Yes           |
| `/wallet ada send <addr> <amt>`  | Send ADA to another address          | Yes           | Yes           |
| `/wallet ada address <addr>`     | Set/update the wallet address        | No            | No            |
| `/wallet ada apikey <key>`       | Store Blockfrost API key             | No            | No            |
| `/wallet ada key <skey>`         | Store signing key in the vault       | N/A           | No            |

### ADA Balance Interpretation

George reads the balance from Blockfrost:
- **lovelace**: The base unit (1 ADA = 1,000,000 lovelace)
- **Native tokens**: Any Cardano native tokens held at the address

---

## Solana (SOL)

### Getting a Solana Address

**Option A: solana-keygen (recommended)**
```bash
# Install Solana CLI
sh -c "$(curl -sSfL https://release.solana.com/stable/install)"

# Generate a new keypair
solana-keygen new --outfile ~/.config/solana/id.json

# Show your address
solana address
```

**Option B: Use an existing wallet**
Export your address from Phantom, Solflare, or any Solana wallet.

### Setting Up in George

```bash
# Store your address (view-only)
/wallet sol address YOUR_SOLANA_ADDRESS

# For sending, store your keypair JSON
/wallet sol key "$(cat ~/.config/solana/id.json)"
```

### Funding Your Solana Wallet

**Mainnet:**
- Send SOL from any exchange (Coinbase, Kraken, FTX, Phantom swap)
- Send from another Solana wallet
- Minimum recommended: 0.1 SOL (~$15-25) for testing sends

**Testnet/Devnet (George can do this himself!):**
```bash
# Switch to testnet (uses devnet)
/wallet network testnet

# Set your devnet address
/wallet sol address YOUR_DEVNET_ADDRESS

# Request a free airdrop — George does this directly via RPC!
/wallet sol airdrop 2

# Check balance
/wallet sol balance
```

**George's Airdrop Capability**: Solana devnet allows free SOL airdrops via RPC. George can request up to 2 SOL per airdrop, making Solana the easiest chain for testing.

### What George Can Do with SOL

| Command                          | Description                          | Requires Key? |
|----------------------------------|--------------------------------------|---------------|
| `/wallet sol balance`            | Check SOL balance                    | No            |
| `/wallet sol tx`                 | Show last 10 transactions            | No            |
| `/wallet sol send <addr> <amt>`  | Send SOL to another address          | Yes           |
| `/wallet sol airdrop [amount]`   | Request free devnet SOL (testnet)    | No            |
| `/wallet sol address <addr>`     | Set/update the wallet address        | No            |
| `/wallet sol key <keypair>`      | Store keypair JSON in the vault      | N/A           |

### SOL Balance Interpretation

George queries the Solana JSON-RPC directly:
- **lamports**: The base unit (1 SOL = 1,000,000,000 lamports)
- Balance is returned in lamports and converted to SOL

---

## Checking Balances

### Quick Balances

```bash
# All configured wallets at once
/wallet balance

# Individual wallet
/wallet btc balance
/wallet ada balance
/wallet sol balance
```

### Wallet Health Check

```bash
# Comprehensive check: balances + API health + vault status
/wallet check
```

The `/wallet check` command provides:
- **Balance**: Current funds for each configured wallet
- **API Health**: Whether each blockchain API is reachable
- **Vault Status**: Whether keys/addresses are properly stored
- **Network**: Current network (mainnet vs testnet)
- **Warnings**: Low balance alerts, missing keys, API issues

---

## Test Transactions

Before sending real money, always test on testnet first.

### Solana (Easiest to Test)

```bash
# Switch to devnet
/wallet network testnet

# Set up a devnet address
/wallet sol address YOUR_DEVNET_ADDRESS

# Airdrop free SOL
/wallet sol airdrop 1

# Test send (if you have a second address)
/wallet test sol 0.001

# Or manual send
/wallet sol send ANOTHER_DEVNET_ADDRESS 0.001
```

### Bitcoin Testnet

```bash
# Switch to testnet
/wallet network testnet

# Set testnet address and fund from faucet (see above)
/wallet btc address tb1qTESTNET_ADDRESS

# Check that funding arrived
/wallet btc balance

# Test send
/wallet test btc 0.0001
```

### Cardano Testnet

```bash
# Switch to testnet
/wallet network testnet

# Set testnet Blockfrost key and address
/wallet ada apikey testnet_project_id
/wallet ada address addr_test1q...

# Fund from Cardano faucet (see above)
# Test send
/wallet test ada 2
```

### The `/wallet test` Command

This is George's built-in test transaction facility:

```bash
/wallet test <btc|ada|sol> [amount]
```

What it does:
1. Verifies you're on **testnet** (refuses to run on mainnet)
2. Checks that the wallet is fully configured (address + key)
3. Sends a small test amount to **yourself** (same address)
4. Reports the transaction result

Default test amounts:
- BTC: 0.00001 (~$1)
- ADA: 1.5 (minimum UTxO + fees)
- SOL: 0.001 (~$0.15)

---

## Periodic Wallet Monitoring

George can check his wallets on a schedule to keep you informed.

### Manual Check

```bash
# Quick health check
/wallet check

# Just balances
/wallet balance
```

### What `/wallet check` Reports

```
╔══════════════════════════════════════════════╗
║  Wallet Health Check                         ║
╠══════════════════════════════════════════════╣
║  Network: testnet                            ║
║                                              ║
║  ₿ Bitcoin                                   ║
║    Address:  tb1q8sn2...  ✓                  ║
║    Balance:  0.00100000 BTC                  ║
║    API:      mempool.space ✓                 ║
║    Key:      in vault ✓                      ║
║                                              ║
║  ₳ Cardano                                   ║
║    Address:  addr_test1q...  ✓               ║
║    Balance:  45.123456 ADA                   ║
║    API:      Blockfrost ✓                    ║
║    Key:      in vault ✓                      ║
║                                              ║
║  ◎ Solana                                    ║
║    Address:  7xKXtg2...  ✓                   ║
║    Balance:  2.500000000 SOL                 ║
║    API:      Solana RPC ✓                    ║
║    Key:      in vault ✓                      ║
║                                              ║
║  Status: All wallets healthy                 ║
╚══════════════════════════════════════════════╝
```

### Automated Monitoring Tips

While George doesn't run cron jobs himself, you can set up periodic checks:

```bash
# Check every hour via Termux (on Android)
termux-job-scheduler --job-id 1 --period-ms 3600000 \
    --script "cd ~/blue-lodge && bash lodge --cmd '/wallet check'"

# Or add to your .bashrc for every new session
echo 'cd ~/blue-lodge && bash lodge --cmd "/wallet check"' >> ~/.bashrc
```

---

## Security Best Practices

### Key Management

1. **Never share private keys** — George stores them encrypted (AES-256-CBC, PBKDF2 100k iterations) but they're still your keys
2. **Use testnet first** — Always verify send functionality on testnet before mainnet
3. **Rotate vault keys periodically** — `/secret rotate` re-encrypts all secrets with a new key
4. **Back up your vault** — `~/.george/.vault/` contains encrypted secrets; back it up to secure storage
5. **Small amounts** — George runs on a mobile device; don't store life savings here

### Address Verification

Always double-check addresses before sending. George displays the address in:
- `/wallet status` — Shows first 12 characters of each address
- `/wallet <chain> balance` — Shows the full address

### Network Safety

- George defaults to **mainnet**. Always explicitly switch to testnet for testing:
  ```bash
  /wallet network testnet
  ```
- The `/wallet test` command **refuses to execute on mainnet**
- George shows the current network in every balance check

### What George Does NOT Do

- **No custodial holding** — George doesn't have his own wallet addresses. These are YOUR wallets.
- **No automatic sends** — Every send requires your explicit command
- **No key generation** — George stores keys, he doesn't create them (use wallet tools above)
- **No seed phrases** — George works with individual keys, not HD wallet seed phrases
- **No DeFi/Swaps** — George checks and sends, he doesn't interact with protocols (yet)

---

## Troubleshooting

### "No [chain] address configured"
You need to store an address first:
```bash
/wallet btc address YOUR_ADDRESS
```

### "No Blockfrost API key"
Cardano requires a free API key from [blockfrost.io](https://blockfrost.io):
```bash
/wallet ada apikey YOUR_PROJECT_ID
```

### "No [chain] private key in vault"
Sending requires a private key:
```bash
/wallet btc key 5J_YOUR_WIF_KEY
/wallet sol key "$(cat keypair.json)"
```

### "[tool] not found" on send
Install the required CLI tool:
```bash
# Bitcoin
apt install bitcoind
# OR
pip install electrum

# Solana
sh -c "$(curl -sSfL https://release.solana.com/stable/install)"

# Cardano — see https://developers.cardano.org
```

### Balance shows 0 but I sent funds
- Check you're on the right network (`/wallet network testnet` vs mainnet)
- Wait a few minutes — blockchain confirmations take time
- BTC: ~10 min per block
- ADA: ~20 sec per block
- SOL: ~0.4 sec per block

### API errors
- **mempool.space**: Rarely down, no key needed. If failing, try later.
- **Blockfrost**: Check your API key and rate limits (50k/day free tier)
- **Solana RPC**: Public RPCs have rate limits. For heavy use, set up a private RPC.

---

## Summary: George's Wallet Capabilities

| Capability        | BTC | ADA | SOL | Notes                              |
|-------------------|-----|-----|-----|------------------------------------|
| Store address     | ✓   | ✓   | ✓   | Encrypted in vault                 |
| Store private key | ✓   | ✓   | ✓   | Encrypted in vault                 |
| Check balance     | ✓   | ✓   | ✓   | Via public APIs                    |
| Transaction list  | ✓   | ✓   | ✓   | Last 10 transactions               |
| Send funds        | ✓   | ✓   | ✓   | Requires key + CLI tool            |
| Testnet support   | ✓   | ✓   | ✓   | Network toggle                     |
| Free test funds   | ✗   | ✗   | ✓   | SOL airdrop on devnet              |
| Health check      | ✓   | ✓   | ✓   | `/wallet check`                    |
| Test transaction  | ✓   | ✓   | ✓   | `/wallet test` (testnet only)      |

---

*"A penny saved is a penny earned."* — Brother Benjamin Franklin
*But a penny tested on devnet is a penny wisely spent.*
