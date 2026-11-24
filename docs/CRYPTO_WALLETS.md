---
title: "Crypto Wallets, Encrypted Keystore, Send & Receive Guide"
description: "Operational guide for George's sovereign multi-chain crypto wallet system: Cardano (ADA + Native Tokens), Polygon/Ethereum EVM (POL/USDC/ETH), Bitcoin (BTC), and Solana (SOL), scrypt+AES-256-GCM encrypted keystore, agent-hot auto-unlock, QR/URI Receive, and Tier B policy-gated Send."
subsystem: "crypto"
tags:
  - wallet
  - crypto
  - cardano
  - polygon
  - ethereum
  - bitcoin
  - solana
  - hot-wallet
  - keystore
okf_id: "urn:blue-lodge:doc:crypto-wallets"
related:
  - "[[INDEX]]"
  - "[[SOVEREIGN_DEX_AND_LENDING_GUIDE]]"
  - "[[SECRETS_VAULT]]"
  - "[[SAFETY_AND_PRIVACY]]"
---

# George's Sovereign Crypto Wallet & Encrypted Keystore Guide

> *"An investment in knowledge pays the best interest."* — Brother Benjamin Franklin

This guide covers George's sovereign multi-chain cryptocurrency wallet architecture across **Cardano Mainnet (ADA + Native Tokens)**, **Polygon PoS & Ethereum L1 (POL, USDC, USDC.e, ETH)**, **Bitcoin (BTC)**, and **Solana (SOL)**.

---

## 1. Security Architecture & Encrypted Keystore (`lib/tools/wallet/keystore.py`)

### 1.1 Encryption at Rest (`scrypt` + `AES-256-GCM`)
All hot wallet signing keys and BIP-39 mnemonics are encrypted at rest inside `.george/wallets/keystore/<wallet-id>.json` (`0600` permissions):
- **Key Derivation**: `scrypt(N=2^15, r=8, p=1, dklen=32)` with a 16-byte random salt per encryption.
- **Authenticated Encryption**: `AES-256-GCM` with a 12-byte random nonce and Additional Authenticated Data (`AAD`) binding the ciphertext to `george-keystore-v1:<wallet_id>:<chain>`.
- **Zero Plaintext Key Files**: Legacy plaintext `.skey` and `.key` files are migrated via `python3 lib/tools/wallet/keystore.py migrate-agent` into encrypted keystore records (`agent-hot.json` and `agent-evm.json`).

### 1.2 Auto-Unlockable Agent Keystore (`agent-hot` & `agent-evm`)
So that George's background daemons (the order watcher, Tier A stale-order reclaims, and S1 inventory exits) can operate unattended without leaving plaintext `.skey` files on disk:
- `.george/secrets/agent_keystore.key` (`0600`) holds a 256-bit machine-local keyfile (auto-generated on first run by `./scripts/infra/init_secrets.sh`).
- `agent-hot` (Cardano) and `agent-evm` (Polygon/Ethereum) are encrypted with this passphrase and marked `"auto_unlock": true`.
- Operator-created personal wallets (`create` / `import`) are encrypted with the operator's chosen passphrase (minimum 12 characters, never written to disk) and require interactive passphrase unlock per action.

### 1.3 Untracked Archivable Wallet Library (`.george/wallets/wallet_library.json`)
All personal wallet addresses, stake keys (`stake1u...`), and historical cold-storage funding lot TX hashes are stored in `.george/wallets/wallet_library.json` and `.george/secrets.env` (both git-ignored, `0600` permissions, and included in encrypted operator backups). A public template is provided at `configs/wallets/wallet_library.example.json`.

---

## 2. Receiving Funds (`receive` CLI, Web UI & `wallet_receive` Tool)

George provides first-class **Receive** across CLI, Web Desk, and Discord/Agent tools with pure-Python ISO/IEC 18004 QR code generation (`lib/tools/wallet/qr.py` — zero external binary dependencies, producing both SVG for the Web UI and half-block ANSI for terminal/Discord).

### 2.1 CLI Usage
```bash
# Show Cardano receive address, CIP-13 payment URI (web+cardano:...), and ANSI QR code
/wallet receive ada
/wallet receive cardano --amount 25 --token ADA --memo "Invoice 42"

# Show Polygon / Ethereum EVM receive address, EIP-681 URI, and ANSI QR code
/wallet receive pol --amount 50 --token USDC
/wallet receive eth --amount 0.05

# Direct keystore CLI (JSON output + incoming transaction check)
.venv/bin/python lib/tools/wallet/keystore.py receive --chain cardano --amount 25 --check-incoming
```

### 2.2 Web Desk (`RECEIVE` Tab)
In the Craftsman Workbench (**Sovereign DEX Desk → Wallets → RECEIVE**):
1. Select any Cardano or EVM wallet from the dropdown (or click **RECEIVE** on any wallet card).
2. Optionally enter an **Amount**, **Token** (`ADA`, `SNEK`, `POL`, `USDC`, `ETH`), and **Memo**.
3. Click **QR / URI** to render the scannable SVG QR code, **COPY ADDR** / **COPY URI** to copy to clipboard, or **CHECK TXS** to inspect the latest 5 incoming on-chain transactions.

### 2.3 Agent Tool (`wallet_receive`)
George can call `wallet_receive(chain='cardano', amount=25, token='ADA', check_incoming=True)` (Tier A read-only) whenever you ask in Discord or chat for a deposit address, payment request URI, or whether an incoming transfer has landed.

---

## 3. Sending Funds (`send` CLI, Web UI & Tier B `wallet_send_preview`)

### 3.1 CLI Usage (Dry-Run by Default)
Every send builds and validates the transaction locally first (showing exact network fees and transaction hash) and only broadcasts when `--execute` is passed:

```bash
# Cardano: Send 15 ADA (dry-run preview first, then broadcast with --execute)
/wallet ada send addr1q... 15
/wallet ada send addr1q... 15 --message "Thanks!" --execute

# Cardano Native Tokens: Send 1000 SNEK (automatically attaches 1.5 ADA min-UTxO companion)
/wallet ada send addr1q... 1000 --token SNEK --execute

# Polygon PoS: Send native POL or ERC-20 USDC
/wallet pol send 0xRecipientAddress... 25 --token USDC --execute
/wallet pol send 0xRecipientAddress... 5 --token POL --execute

# Ethereum Mainnet: Send ETH or ERC-20 USDC
/wallet eth send 0xRecipientAddress... 0.02 --token ETH --execute
```

### 3.2 Web Desk (`SEND` Tab)
In **Sovereign DEX Desk → Wallets → SEND**:
1. Choose the **From** wallet (`agent-hot`, `agent-evm`, or any imported wallet).
2. Enter the **To** address (`addr1...` for Cardano or `0x...` for Polygon/Ethereum), **Amount**, optional **Token** (`ADA`, `SNEK`, `MIN`, `NIGHT`, `POL`, `USDC`, `ETH`), and optional CIP-20 **Memo**.
3. Click **DRY RUN** to build the transaction and preview exact network fees.
4. Click **SEND…** and type `BROADCAST` in the confirmation modal to submit on-chain.

### 3.3 Agent Tool (`wallet_send_preview` + Tier B Operator Confirmation)
George **never** broadcasts an outbound transfer autonomously:
1. When you ask George to send funds (e.g., *"Send 25 ADA to addr1..."*), George calls `wallet_send_preview` (or `crypto_plan` with intent `"send 25 ADA to addr1..."`).
2. The policy engine checks the `40 ADA` reserve floor (`floor_ada`) and `10 ADA` fee buffer (`fee_buffer_ada`). Any transfer that would breach the floor is immediately blocked as **Tier C**.
3. Valid transfers produce a **Tier B** plan `P-XXXXXX` (10-minute TTL, SHA-256 content-bound).
4. You reply `confirm P-XXXXXX` in Discord (verified against your Discord user ID via the Discord REST API) or click **CONFIRM** in the Web Desk to mint a single-use confirmation token and broadcast the transaction.

---

## 4. Creating & Importing Wallets (`keystore.py`)

```bash
# Create a new 24-word Cardano CIP-1852 wallet (encrypted with your passphrase)
LODGE_WALLET_PASSPHRASE="your-strong-passphrase" \
  .venv/bin/python lib/tools/wallet/keystore.py create --chain cardano --label "Operator Vault" --words 24

# Create a new 12-word EVM (BIP-44) wallet
LODGE_WALLET_PASSPHRASE="your-strong-passphrase" \
  .venv/bin/python lib/tools/wallet/keystore.py create --chain evm --label "Polygon Desk" --words 12

# List all wallets in the keystore
.venv/bin/python lib/tools/wallet/keystore.py list

# Check live on-chain balances for a wallet
.venv/bin/python lib/tools/wallet/keystore.py balance --id agent-hot
.venv/bin/python lib/tools/wallet/keystore.py balance --id agent-evm

# Sign & verify messages (CIP-8 COSE_Sign1 for Cardano, EIP-191 personal_sign for EVM)
.venv/bin/python lib/tools/wallet/keystore.py sign --id agent-hot --message "Blue Lodge proof of control"
```

---

## 5. Summary of Capabilities

| Capability | Cardano (ADA + Tokens) | Polygon / Ethereum (EVM) | Bitcoin (BTC) | Solana (SOL) |
| :--- | :---: | :---: | :---: | :---: |
| **Encrypted Keystore (`scrypt` + `AES-GCM`)** | ✓ (`CIP-1852` / `skey`) | ✓ (`BIP-44` / `privkey`) | Vault (`.vault`) | Vault (`.vault`) |
| **Auto-Unlock Daemon Support (`0600` keyfile)** | ✓ (`agent-hot`) | ✓ (`agent-evm`) | — | — |
| **Receive QR Code (SVG + ANSI) & Payment URI** | ✓ (`CIP-13`) | ✓ (`EIP-681`) | ✓ (`BIP-21`) | ✓ (`Solana Pay`) |
| **Send Native Currency + Tokens** | ✓ (`ADA` + `SNEK`/`MIN`/etc.) | ✓ (`POL`/`ETH`/`USDC`) | ✓ (`BTC`) | ✓ (`SOL`) |
| **Tier B Operator Confirmation (`confirm P-XXXXXX`)** | ✓ | ✓ | — | — |
| **Message Signing & Verification** | ✓ (`CIP-8`) | ✓ (`EIP-191`) | — | — |
