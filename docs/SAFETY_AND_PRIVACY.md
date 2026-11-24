---
title: "Operator Safety, Feature Flags & Privacy Framework"
description: "Comprehensive guide to safety guards in Blue Lodge: operator feature flags, live-sell trade protection, the /forget privacy scrubbing command, and credential redaction."
subsystem: "sys"
tags:
  - safety
  - privacy
  - feature-flags
  - forget
  - rbac
  - security
okf_id: "urn:blue-lodge:doc:safety-and-privacy"
related:
  - "[[SECURITY_AND_SECRETS]]"
  - "[[SECRETS_VAULT]]"
  - "[[SOVEREIGN_DEX_AND_LENDING_GUIDE]]"
  - "[[MEMORY_AND_RECALL]]"
  - "[[SANDBOXES]]"
---

# Operator Safety, Feature Flags & Privacy Framework

Blue Lodge gives George extensive agentic power—bash execution, file modification, DEX trading, social posting, and subagent orchestration. To ensure that autonomous operation never compromises capital, credentials, or operator privacy, the architecture enforces strict safety gates, feature flags, and scrub protocols.

```mermaid
graph TD
    OpCommand["Operator Action / Agent Task"] --> FlagCheck{"Feature Flag Gate (data/feature_flags.json)"}

    FlagCheck -->|Live Sell Requested| LiveSellGate{"LIVE_SELL enabled?"}
    LiveSellGate -->|false (default)| RejectSell["Block Transaction & Require /flags enable live_sell"]
    LiveSellGate -->|true| ExecuteSell["Execute Sovereign DEX Sell Order"]

    FlagCheck -->|Reddit Ingest Requested| RedditGate{"GATED_REDDIT enabled?"}
    RedditGate -->|false (default)| BlockReddit["Block Reddit Ingest"]
    RedditGate -->|true| IngestReddit["Allow OSINT Gathering"]

    OpCommand -->|Privacy Scrub: /forget me| ForgetEngine["Privacy Engine (commands/forget.sh)"]
    ForgetEngine --> CleanRecall["Purge FTS5 Recall DB (recall.db)"]
    ForgetEngine --> CleanJournal["Scrub Episodic Journal (journal.md)"]
    ForgetEngine --> CleanTranscripts["Scrub Session Transcripts & Logs"]
    ForgetEngine --> CleanMemory["Clear In-Memory Working State"]
```

---

## 1. Operator Feature Flags (`data/feature_flags.json`)

High-stakes or potentially destructive behaviors are guarded behind boolean switches in `data/feature_flags.json`. Changes take effect immediately without requiring process restarts.

### Standard Flag Catalog

| Flag Key | Default | Function & Safety Rationale |
| --- | --- | --- |
| `live_sell` | `false` | **Capital Protection**: When `false`, all DEX sell swaps and order executions operate in simulation mode. Prevents accidental liquidation of treasury holdings. |
| `live_buy` | `false` | When `false`, DEX purchases and P2P loan funding require manual confirmation. |
| `gated_reddit_solver` | `false` | Prevents automated scraping or solving tasks on public Reddit forums without explicit operator consent. |
| `social_autopost` | `false` | Ensures that synthesized blog posts and social broadcasts require manual operator approval before transmission. |
| `auto_git_push` | `false` | Restricts automated remediation loops from pushing directly to remote repositories. |
| `unrestricted_bash` | `false` | Enforces command whitelisting and directory sandboxing during shell tool execution. |

### Inspecting and Toggling Flags
```bash
# View current status of all feature flags
lodge /flags

# Enable a guarded feature
lodge /flags enable live_sell

# Disable a feature
lodge /flags disable live_sell

# Reset all flags to hardened defaults
lodge /flags reset
```

---

## 2. Privacy Scrubbing: The `/forget` Protocol (`commands/forget.sh`)

Blue Lodge maintains extensive multi-tier memory (working context, episodic journal, SQLite FTS5 recall, and trajectory logs). When handling sensitive code, confidential credentials, or personal conversations, the operator can invoke the `/forget` protocol to scrub data from all persistence stores.

### Usage Modes
- `lodge /forget me`: Full identity scrub. Purges all operator names, personal identifiers, contact info, and session transcripts while preserving core codebase knowledge.
- `lodge /forget topic <keyword>`: Targeted scrub. Removes all memory entries, journal notes, and recall documents matching `<keyword>`.
- `lodge /forget credentials`: Scans all memory tiers and scrubs accidentally committed passwords, API keys, and seed phrases.

### Cryptographic Overwrite
The forget engine performs atomic multi-tier deletion:
1. **SQLite FTS5 Recall**: Executes `DELETE FROM recall WHERE content MATCH ?;` followed by `VACUUM;` to purge residual unallocated database pages.
2. **Episodic Journal**: Rewrites `journal.md`, stripping tagged entries and re-signing the journal with the operator PGP key.
3. **Trajectory Logs**: Overwrites disk sectors of affected session files in `.george/runs/` using `/dev/urandom` before unlinking.

---

## 3. Credential Redaction & Sanitization

All observation pipelines and logging streams automatically pass through regex redaction masks before writing to disk:
- Cardano private keys / seed phrases (`ed25519e_sk...`, 24-word mnemonics).
- OpenAI / Anthropic / Cloud API keys (`sk-...`, `AIzaSy...`).
- HTTP Authorization Bearer headers.
- Discord bot tokens (`MTI...`).
- System passwords and SSH private keys.

Redacted tokens are replaced in logs with `[REDACTED_SECRET:<hash>]`.

---

## 4. Related Documentation
- [[SECURITY_AND_SECRETS|Security & Secrets]] — Sovereign security architecture and trust boundaries.
- [[SECRETS_VAULT|Secrets Vault]] — Encrypted credential storage and PGP sealing.
- [[SOVEREIGN_DEX_AND_LENDING_GUIDE|Sovereign DEX & Lending Guide]] — Financial risk management and limits.
- [[MEMORY_AND_RECALL|Memory, Recall & Journal]] — Deep dive into memory persistence and decay.
- [[SANDBOXES|Sandboxes Guide]] — Filesystem and process execution isolation.
