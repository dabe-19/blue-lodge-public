# George Recall Index

FTS5-optimized knowledge base. Every section is a self-contained fact card
designed for BM25 search. Section headers carry 10x weight — keyword-rich
for maximum recall precision.

## Discord Post Channel Message

/social post discord <channel> <text> — post to a named Discord channel.
Channel names auto-resolve from registry. Strips quotes from args.
If channel unknown, falls back to webhook or DISCORD_DEFAULT_CHANNEL.
Sync channels first: /social discord channels sync
API: discord.com/api/v10, intents=3072, requires DISCORD_BOT_TOKEN.

## Discord Direct Message DM User

/social discord dm <user> <text> — send a DM to a Discord user.
Resolves username to user ID from registry.
Sync users first: /social discord users sync

## Discord At-Mention Resolve User

Use @username in Discord messages. Auto-resolves to <@user_id> on send.
Requires user registry: /social discord users sync
Example: Hey @pompler check this out → Hey <@123456> check this out

## Discord Channel Registry Sync List

/social discord channels sync — sync channel names from Discord API.
/social discord channels list — show registered channels.
/social discord channels add <name> <id> — manually register a channel.
/social discord channels remove <name> — remove a channel.
Channels resolve by name (strips leading #). Numeric IDs pass through.
DB: ~/.george/discord_channels.db

## Discord User Registry Sync List

/social discord users sync — sync usernames and IDs from server.
/social discord users list — show registered users.
/social discord users add <name> <id> — manually add a user.
/social discord users remove <name> — remove a user.
/social discord users resolve <name> — look up user ID.
DB: ~/.george/discord_users.db

## Discord Read Messages Channel

/social discord read <channel> — read recent messages from a channel.
Channel can be a name (resolved) or numeric ID.

## Discord Validate Bot Token

/social discord validate — test the bot token and show bot identity.
Requires DISCORD_BOT_TOKEN in keys.

## Discord Setup Keys Bot Webhook

Bot: /api keys set DISCORD_BOT_TOKEN <token>
Webhook: /api keys set DISCORD_WEBHOOK_URL <url>
Server: /api keys set DISCORD_GUILD_ID <id>
Default channel: /api keys set DISCORD_DEFAULT_CHANNEL <id_or_name>

## X Twitter Post Tweet Timeline Search

/social post x <text> — post a tweet.
/social x timeline — read your home timeline.
/social x search <query> — search tweets.
/social x reply <tweet_id> <text> — reply to a tweet.
/social x delete <tweet_id> — delete a tweet.
Key: /api keys set X_BEARER_TOKEN <token>
API: api.x.com v2. Free tier: 1500 posts/month, 50 reads/day.

## Mastodon Post Timeline Search Notifications

/social post mastodon <text> — post to default instance.
/social post mastodon instance:<name> <text> — post to specific instance.
/social mastodon timeline — read home timeline.
/social mastodon search <query> — search posts.
/social mastodon notify — check notifications.
Visibility options: public, unlisted, private, direct.
Legacy key: /api keys set MASTODON_ACCESS_TOKEN <token>

## Mastodon Multi-Instance Registry

/social mastodon instances list — show registered instances.
/social mastodon instances add <url> <token> — register instance + token.
/social mastodon instances remove <url> — remove an instance.
Token resolution: specific instance → first registered → legacy key.
DB: ~/.george/mastodon_instances.db

## Bluesky Post Timeline Search

/social post bluesky <text> — post to Bluesky.
/social bluesky timeline — read timeline.
/social bluesky search <query> — search posts.
Keys: /api keys set BLUESKY_HANDLE <handle>
      /api keys set BLUESKY_APP_PASSWORD <password>
API: bsky.social/xrpc/ (AT Protocol). JWT auto-session.

## Telegram Post Send Updates Bot

/social post telegram <text> — send message to Telegram chat.
/social telegram updates — get recent updates.
/social telegram me — show bot info.
Keys: /api keys set TELEGRAM_BOT_TOKEN <token>
      /api keys set TELEGRAM_CHAT_ID <chat_id>
API: api.telegram.org. Markdown parse mode.

## Social Post Unified Broadcast

/social post <platform> [channel] <text> — post to one platform.
Toggle: /api keys set SOCIAL_UNIFIED_POST 1 — broadcast to all.
With toggle on: /social post <text> sends to all configured platforms.
Post = public broadcast. Send = targeted/DM. For email use /email.

## Social Status Check Keys

/social status — show all configured platforms and integration details.
Shows: key status, channel count, user count, unified toggle state.

## Sandbox Create New Project

/sandbox new <name> <type> — create a sandbox. Types: rust, python, shell.
Rust: cargo init + optimized profiles (dev: no debug/incremental, release: lto thin/strip).
Python: uv init or venv fallback.
Shell: plain directory with run.sh.
Location: ~/.lodge-sandboxes/<name>/ (or $LODGE_SANDBOXES)

## Sandbox Build Test Run Execute

/sandbox build <name> — build using detected toolchain (cargo/uv/make).
/sandbox test <name> — run tests using detected toolchain.
/sandbox run <name> <cmd> — run arbitrary command inside sandbox.
/sandbox cd <name> — switch working directory into sandbox.

## Sandbox Management List Status Delete Clone

/sandbox list — show all sandboxes with type, size, activity.
/sandbox status <name> — detailed info + recent journal entries.
/sandbox journal [n] — show last N sandbox events.
/sandbox rm <name> — delete a sandbox.
/sandbox clone <url> [name] — clone a git repo into a new sandbox.
Aliases: ls=list, create=new, exec=run, remove=rm.

## Sandbox Isolation Methods Proot Unshare

Three isolation methods (auto-detected):
1. proot — Termux default (pkg install proot).
2. unshare — Linux desktop (requires user namespace support).
3. directory — fallback, just directory isolation.

## Sandbox Permissions Security Levels

/security sandbox set <name> <level> — set permission level.
/security sandbox get <name> — show permission level.
/security sandbox list — show all sandbox permissions.
Levels: 0=ask-all, 1=smart (default), 2=auto-approve (dangerous).
Config: ~/.george/sandbox_permissions.conf (format: name=level).
Pentest sandboxes: always use level 0.

## Sandbox Journal Events JSONL

Journal file: ~/.george/sandbox_journal.jsonl
Events: create, exec, build, remove, clone.
Format: {"ts":"...","ev":"create","name":"myapp","detail":"rust","rc":0}

## Container Proot Distro Linux

/container install <distro> — install a proot-distro container.
/container login <name> — enter a container shell.
/container exec <name> <cmd> — run a command in a container.
/container list — show installed containers.
/container here <name> <cmd> — run with current dir at /workspace.
/container info <name> — show container size/details.
/container reset <name> — remove and reinstall.
/container pentest — one-command Kali + top tools.
/container rm <name> — remove a container.
Distros: ubuntu, alpine, kali, fedora, void, arch, debian, opensuse.

## Init Scaffold Project Types

/init <name> <lang> — scaffold a new project.
Types: rust, python, rl, data, automation, notebook, shell.
Creates project dir + GEORGE.md + starter code.
Name: no spaces. Language: fuzzy-matched.
Fuzzy: rs→rust, py→data, gymnasium→rl, ipynb→notebook, bash→shell.

## Write Save Files Create

/write <file> <content> — write or overwrite a file.
/save <file> <content> — save content to a file.
Both create parent directories automatically.

## Download Files URL Copy

/download <url> [dest] — download a URL to a local file.
/download <path> [dest] — copy a local file.
Default dest: current directory with original filename.

## Build Test Fix Project

/build [release] — build project (reads GEORGE.md ## Build).
/test [args] — run tests (reads GEORGE.md ## Build).
/fix [error] — diagnose and fix errors.
Rust: cargo check > cargo build (saves RAM). cargo check then cargo test.

## Commit Push Git Message

/commit [msg] — generate AI commit message and commit.
/push — push to GitHub (requires SSH key setup).
Conventional commits format. Max 72 chars first line.

## Clone Repository Git

/clone <url> — clone and setup a repository.
Auto-converts HTTPS to SSH URLs.
Creates sandbox, clones, writes GEORGE.md.

## Git Setup Configuration Identity SSH

/git setup — full auto-setup (identity + SSH + GPG + GitHub, 7 steps).
/git status — show git config overview.
/git identity [name] [email] — set git user.
/git ssh-keygen — generate SSH keypair (Ed25519, no passphrase).
/git ssh-config — write persistent SSH config for GitHub.
/git remote [name] <url> — add/update remote (auto HTTPS→SSH).
/git test — test SSH connection to GitHub.
SSH key: ~/.george/.ssh/id_ed25519

## Git GPG Signing Key

GPG keyring: ~/.george/.gnupg/
Wrapper: ~/.george/gpg-george.sh
Key type: Ed25519, SHA-512 digest, no passphrase, no expiry.
Auto-configured by /git setup when /pgp generate completes.

## Email Send Inbox Setup Provider

/email send <to> <subject> <body> — send an email.
/email inbox [count] — check inbox.
/email status — show email and SSH config.
/email setup [provider] — configure provider.
Providers: protonmail, gmail, zoho, tutanota, disposable.
Config: ~/.george/email.conf
For actual email ONLY. Social posts use /social.

## Email Provider SMTP IMAP Ports

Gmail: smtp.gmail.com:587 STARTTLS, imap.gmail.com:993 SSL, App Password.
ProtonMail: localhost:1025/1143 via Bridge (see Bridge commands below).
Zoho: smtp.zoho.com:587, imap.zoho.com:993.
Tuta: REST API / desktop client only, no SMTP/IMAP.
Disposable: Guerrilla Mail API, no auth needed.

## Email ProtonMail Bridge Setup

/email bridge setup — full Bridge setup flow.
/email bridge install — install Bridge binary.
/email bridge start — start Bridge service.
/email bridge stop — stop Bridge service.
/email bridge status — check Bridge state.
/email bridge login — authenticate with ProtonMail.
/email bridge configure — set mailbox + SMTP/IMAP ports.
/email bridge test — test SMTP connectivity.
Bridge SMTP: 127.0.0.1:1025. Bridge IMAP: 127.0.0.1:1143.

## Push Guard Git Email SSH

/push is blocked unless email + SSH are configured.
Check: /git status or /email status.
Fix: /email setup <provider> then /git setup.
Auto HTTPS→SSH: remotes with github.com auto-convert on push.

## PGP Sign Message Verify Cleartext

/pgp sign <msg> — cleartext PGP sign a message.
/pgp verify <msg> — verify a signed message.
/pgp signpost <msg> — sign and post to social media.
/pgp signfile <file> — detached file signature.
/pgp verifyfile <file> — verify detached signature.
Auto-generates key if missing. Signature adds ~200-400 chars.
Warning: X limit 280, Bluesky 300 — PGP text may exceed.

## PGP Key Management Export Import Revoke

/pgp generate — generate new Ed25519 keypair.
/pgp export — export public key file.
/pgp pubkey — display public key.
/pgp fingerprint — show key fingerprint.
/pgp keys — list all keys.
/pgp import <key> — import external public key.
/pgp revoke — revoke a key.
/pgp status — show PGP setup status.
Key: Ed25519, no passphrase, no expiry, SHA-512 digest.
Identity: George (Blue Lodge Agent) <george@blue-lodge.local>
Keyring: ~/.george/.gnupg/
Public key export: ~/.george/george_public.asc

## Secrets Vault Encrypted Store Get Delete

/secret set <key> <value> — store an encrypted secret.
/secret get <key> — retrieve a secret.
/secret delete <key> — delete a secret.
/secret list — list all stored secrets.
/secret status — show vault and key status.
Encryption: AES-256-CBC, PBKDF2 100K iterations, 256-bit key.
Vault: ~/.george/.vault/<name>.enc (mode 600, dir 700).
Signing key: ~/.george/.keyring/signing.key (mode 600).
Secret naming: letters, digits, underscores, dots, hyphens. No spaces.

## Secrets Import Rotate Backup

/secret import <file> [name] — import file as secret (shreds original).
/secret rotate — generate new key, re-encrypt all secrets.
secrets_with "KEY" "VAR" "command" — scoped access in subshell.
secrets_export_env KEY — outputs export KEY=value.
Backup: both .vault/ and .keyring/ dirs required for restore.

## Secrets Common API Key Names

GITHUB_TOKEN, OPENAI_API_KEY, ANTHROPIC_API_KEY, GOOGLE_API_KEY
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, VERCEL_TOKEN, DATABASE_URL
X_BEARER_TOKEN, MASTODON_ACCESS_TOKEN, BLUESKY_HANDLE, BLUESKY_APP_PASSWORD
DISCORD_BOT_TOKEN, DISCORD_WEBHOOK_URL, DISCORD_GUILD_ID
TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SERPER_API_KEY
BTC_ADDRESS, SOL_ADDRESS, ADA_ADDRESS, BLOCKFROST_API_KEY

## API Key Management Set List Remove

/api keys set <KEY> <VALUE> — set an API key.
/api keys list — show configured keys.
/api keys rm <KEY> — remove a key.
Stored in ~/.george/keys.conf (mode 600).

## Recall Knowledge Search FTS5

/recall <query> — search all indexed knowledge.
/recall stats — show chunk counts and DB size.
/recall reindex — force reindex all sources.
/recall clear — delete entire index.
DB: ~/.george/recall.db. Mtimes: ~/.george/.recall_mtimes.
BM25 weights: section 10x, source 5x, content 1x.
Tokenizer: Porter stemmer + unicode61 (matches word variants).
Search: implicit AND first, OR fallback if no results.

## Recall Context Injection Modes

Ask mode: 1 recall chunk, capped at 200 chars.
Task mode: 4 recall chunks, full content.
Specialist: 3 recall chunks for command documentation.
Escalation L2: 3 recall chunks injected on command failure.
Plan mode: no recall chunks (uses command catalog instead).

## Ingest Documents Upload Knowledge

/ingest <file> [label] — add a document to knowledge base.
/ingest list — show ingested documents.
/ingest rm <label> — remove an ingested document.
Supports: .md .txt .pdf .html .py .sh .rs .js .ts .json .yaml .doc .docx
PDF requires pdftotext (poppler-utils). Office docs require pandoc.
Ingested docs stored as source "doc:<label>" in chunks table.

## Journal Living Memory Write Read

/journal write <text> — write to George's journal.
/journal show [vivid|fading|sediment] — read entries by strength.
/journal decay — apply temporal decay to old entries.
/journal count — entry count.
Journal is living memory with temporal decay. Entries fade over time.
Vivid = recent (strong), fading = older (moderate), sediment = compressed.
Pattern: read external source → journal write summary → recall later.

## Memory Loop Pattern Read Remember Respond

Read → Remember → Respond. For ANY external input:
1. READ: /social discord read <channel> or /web fetch <url>
2. SAVE: /journal write "summary of what was read"
3. RECALL: /recall <topic> to retrieve later
4. RESPOND: /social post discord <channel> "reply"
Iron rule: never web-search for info from a social channel. Read the source.

## Phone Dashboard Battery WiFi Location SMS

/phone — full dashboard (battery, carrier, WiFi, GPS, storage).
/phone location [gps] — current GPS/network coordinates.
/phone where — one-line location summary.
/phone sms inbox — read text messages.
/phone sms send <number> <message> — send SMS.
/phone calls — recent call log.
/phone wifi [scan] — WiFi connection info.
/phone battery — battery percentage.
/phone cell — cell signal info.
/phone telephony — carrier and signal.
/phone clip — read clipboard. /phone clip "text" — set clipboard.
/phone notify "text" — push notification. /phone toast "text" — toast.
/phone vibrate — vibrate device. /phone share "text" — share dialog.
/phone open <url> — open URL in browser.
Requires: LODGE_TERMUX_API=1, Termux:API app, termux-api package.

## Phone Location Providers GPS Network Coordinates

Providers: network (fast, ~50m accuracy), gps (slow, ~3m), passive (instant, last known).
Default: network. Timeout: 30s.
Does NOT work inside proot-distro. Termux native only.
Required permissions: ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION.

## Phone Setup Requirements Prerequisites Termux

Prerequisites: 8GB+ RAM (12GB recommended), Snapdragon 8 Gen 2+, 5-8GB storage.
Option A (Termux native): pkg install -y git curl jq sqlite gawk procps bc termux-api
Option B (proot Ubuntu): proot-distro install ubuntu, apt install curl git jq sqlite3 gawk bc
LODGE_TERMUX_API=1 in .bashrc for phone features (Option A only).
proot: no phone hardware access (Termux API blocked by tracer).
RAM: Android ~4GB + Termux ~50MB + proot ~200MB + model ~3-4GB = ~8GB total.
LLM_KEEP_ALIVE options: "2m" (aggressive), "30m" (relaxed, default), "0" (immediate unload).

## Phone Permissions Android Termux API

Required permissions (grant manually in Android settings):
ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION (for /phone location)
READ_SMS, RECEIVE_SMS (for /phone sms inbox)
READ_CALL_LOG (for /phone calls)
READ_PHONE_STATE (for /phone telephony)

## Crypto Wallet Bitcoin BTC Balance Address

/wallet btc balance — check BTC balance.
/wallet btc address — show receive address.
Key: /api keys set BTC_ADDRESS <address>
API: mempool.space/api (mainnet), mempool.space/testnet/api (testnet).
Units: 1 BTC = 100,000,000 satoshis. No auth needed for balance checks.

## Crypto Wallet Solana SOL Balance Address

/wallet sol balance — check SOL balance.
/wallet sol address — show wallet address.
/wallet sol airdrop <amount> — request devnet SOL (up to 2 SOL).
Key: /api keys set SOL_ADDRESS <address>
API: api.mainnet-beta.solana.com (mainnet), api.devnet.solana.com (testnet).
Units: 1 SOL = 1,000,000,000 lamports. JSON-RPC protocol.

## Crypto Wallet Cardano ADA Balance Address

/wallet ada balance — check ADA balance.
/wallet ada address — show wallet address.
Key: /api keys set ADA_ADDRESS <address>
API key: /api keys set BLOCKFROST_API_KEY <key>
API: cardano-mainnet.blockfrost.io/api/v0 (mainnet), testnet variant.
Units: 1 ADA = 1,000,000 lovelace. Blockfrost free tier: 50K req/day.

## Crypto Wallet Test Network Transactions

/wallet network testnet — switch to testnet.
/wallet network mainnet — switch to mainnet (default).
/wallet test <chain> <amount> — send test transaction.
/wallet check — periodic balance check across all chains.
Default test amounts: BTC 0.00001, ADA 1.5, SOL 0.001.

## Vitals System Dashboard Disk RAM Battery

/vitals — system dashboard (disk, RAM, battery, WiFi, cell).
/vitals context — one-line summary for LLM context injection.
/vitals disk — disk free space.
/vitals ram — RAM free space.
/vitals battery — battery percentage.
/vitals wifi — WiFi connection info.
/vitals cell — cell signal.
/vitals network — network reachability check.
/vitals refresh — force sensor refresh.
/vitals check — run preflight checks.

## Vitals Thresholds Warning Critical Levels

Disk: warn <500MB (VITALS_DISK_WARN_MB), critical <100MB (VITALS_DISK_CRIT_MB).
RAM: warn <200MB (VITALS_RAM_WARN_MB), critical <100MB (VITALS_RAM_CRIT_MB).
Battery: warn <15% (VITALS_BATTERY_WARN), critical <5% (VITALS_BATTERY_CRIT).
All configurable via env vars. Sensor cache TTL: 30 seconds.

## Vitals Guard Functions Preflight Block

vitals_preflight("strict") — runs at agent_run() start, blocks if critical.
vitals_guard_disk — blocks writes when disk < VITALS_DISK_CRIT_MB.
vitals_guard_ram — blocks heavy ops when RAM < VITALS_RAM_CRIT_MB.
vitals_guard_battery — blocks long ops when battery < VITALS_BATTERY_CRIT%.
vitals_guard_network — blocks when no WiFi/cell/reachability.
Ask mode prompt: warnings only. Task mode prompt: full context (~30-50 tok).

## Backup Local GitHub Restore List

/backup local — quick backup of identity and memory.
/backup restore [name] — restore from a backup.
/backup list — show all backups.
/backup github — save + push to GitHub.
Backed up: soul.md, journal.md, Modelfile, keys.conf, all GEORGE.md files.
Location: ~/.george/backups/YYYYMMDD_HHMMSS/ with MANIFEST.md.

## Slash Custom Commands Create List Run

/slash — list custom commands.
/slash create <name> <desc> — create a new command (LLM-assisted).
/slash <name> [args] — run a custom command.
/slash test <name> — test a custom command (syntax + function + dry run).
/slash show <name> — show command source.
/slash edit <name> — re-generate with new description.
/slash delete <name> — delete a command.
/slash rename <old> <new> — rename a command.
/slash export <name> — export command source.
Storage: ~/.george/slash/<name>.sh. Function: slash_<name>().

## Slash Available Library Functions

Custom commands can call any lodge library function:
UI: ui_info, ui_ok, ui_err, ui_warn, ui_step, ui_dim, ui_section, ui_divider.
Dispatch: commands_dispatch "/command args" "./"
LLM: llm_stream "prompt" "system" max_tokens, llm_generate "prompt" "system"
Recall: recall_search "query", recall_search_context "query" 3
Phone: phone_location_context, phone_sms_list "inbox" 10, phone_status_context
Sandbox: sandbox_create "name" "shell", sandbox_exec "name" "cmd"
Journal: journal_write "text". Memory: memory_read_project "dir".
Recursive: slash_run "other_command" "args" "$workdir"

## Slash Commands Catalog Injection Prompts

Custom commands appear in system prompts under "YOUR CUSTOM COMMANDS" section.
Ask mode: no command catalog (~250 tok total).
Plan mode: lean catalog via commands_catalog_plan() (~400 tok).
Task mode: full catalog via commands_catalog() (~1443 tok).
Real-time clock date injected into catalog and slash creation prompts.

## Agent Task Architecture Dual Loop

Macro loop: strategist plans milestones from the task.
Micro loop: router picks tool → specialist generates command.
Each milestone is one actionable step with a slash command.
Inner loop: escalation retries (L1: identical lockout, L2: forced recall,
L3: syntax permutation, L4: history recall, L5: guided retry).

## Agent Limits Configuration Parameters

/limits — show all agent limits.
/limits steps N — max steps per plan/subtask (default: 5, range: 1-20).
/limits depth N — subtask recursion depth (default: 2, range: 1-10).
/limits milestones N — macro loop ceiling (default: 20, range: 1-100).
/limits inner N — inner loop escalation retries (default: 6, range: 1-20).
/limits delay N — seconds between milestones (default: 1, range: 0-30).
/limits reset — reset all limits to defaults.

## Agent Token Limits Output Budget

/limits max-tokens N — global max output cap (default: 20480).
/limits tokens N — agent specialist/strategist tokens (default: 20480).
/limits ask-tokens N — /ask conversation tokens (default: 20480).
/limits router-tokens N — router tool selection tokens (default: 256).

## Agent Think Budget Tokens

/limits budget N — global think budget (default: 1024, 0=unlimited).
/limits budget-ask N — /ask think budget (default: 1024).
/limits budget-agent N — strategist/specialist think budget (default: 512).
/limits budget-router N — router think budget (default: 128).
/limits budget-journal N — journal think budget (default: 64).
/limits budget-tool N — tools think budget (default: 256).
Note: budget_tokens is advisory for Qwen3 — num_predict is the hard cap.

## Model Sampling Parameters Temperature Penalty

/model — show all sampling parameters per scenario.
/model temp N — global temperature (default: 0.6, range: 0.0-2.0).
/model repeat N — global repeat penalty (default: 1.3, range: 0.0-3.0).
/model presence N — global presence penalty (default: 0.8, range: 0.0-3.0).
/model reset — reset all sampling parameters to defaults.

## Model Sampling Per Scenario Override

Per-scenario: /model temp-X N, /model repeat-X N, /model presence-X N
where X = ask, agent, router, journal, tool.
Ask: temp 0.5, repeat 1.3, presence 0.8 (conversational).
Agent: temp 0.3, repeat 1.3, presence 0.8 (focused execution).
Router: temp 0.1, repeat 1.1, presence 1.0 (deterministic tool selection).
Journal: temp 0.6, repeat 1.3, presence 1.0 (brief background utility).
Tool: temp 0.3, repeat 1.3, presence 0.8 (commit, web, recall, slash).

## Model Library Dual-Model Architecture

George ships with 9 models across 4 families. Dual-model mode: primary for reasoning, secondary for fast utility.
/models — show status + full model list.
/models list — list all available models.
/models select primary <key> — set primary model (ask, agent).
/models select secondary <key> — set secondary model (router, tool, journal).
/models single <key> — single-model mode (no hot-swap overhead).
/models dual — back to dual-model mode.
Keys: qwen3-think, qwen3-inst, llama32, llama32-inst, granite4, granite4-h, granite4-preview, minist-think, minist-inst.
Families: qwen (think+inst), llama (base+inst), granite (inst+hybrid+preview), ministral (think+inst).
Thinking models: qwen3-think, granite4-preview, minist-think.
Instruct models: qwen3-inst, llama32-inst, granite4, granite4-h, minist-inst.
Hot-swap: only one model loaded at a time. Switch takes 5-15s on ARM.
Per-model sampling: each model has registry defaults for temp, penalties, context.
Per-model overrides: models_set_param, models_get_param, models_show_params.

## Model Tuning Modelfile Parameters

Modelfile: ~/blue-lodge/Modelfile
Model: Qwen3-4B-Thinking-2507 UD-Q5_K_XL (~3.5GB).
Parameters: temperature 0.6, top_p 0.95, top_k 20, min_p 0.0.
Penalties: repeat_penalty 1.3, presence_penalty 0.8.
Context: num_ctx 32768, num_predict 32768, num_thread 8, num_gpu 0.
KV cache: ~144KB/token. 32K ctx = ~4.5GB KV cache.
Stop token: <|im_end|>. LLM_KEEP_ALIVE: 30m (time model stays loaded).

## Model Environment Variables Configuration

OLLAMA_URL=http://127.0.0.1:11434 (Ollama API endpoint).
LODGE_MODEL_PRIMARY=blue-lodge-minist-think:4b (primary model).
LODGE_MODEL_SECONDARY=blue-lodge-minist-inst:4b (secondary model).
LODGE_SINGLE_MODEL=0 (dual-model mode by default).
LLM_MAX_TOKENS=20480 (max output tokens per call).
LLM_TIMEOUT=600 (safety net timeout seconds).
LLM_KEEP_ALIVE=30m (model stay-loaded duration).
LODGE_THINK=1 (show thinking tokens). LODGE_DEBUG=0 (debug timers).

## Soul Personality Toggle Mode

/soul on — inject full soul.md into prompts (~4500 tokens).
/soul off — inject condensed identity only (~250 tokens).
/soul show — display soul.md contents.
/soul condensed — display the condensed soul digest.
Full soul: moral philosophy, humor, ethics, cardinal virtues.
Condensed: identity + output format + practical craft only.

## Thinking Mode Display Toggle

/think — cycle through modes (dim→bright→hidden→off→nothink).
/think on — show LLM thinking process (dimmed text).
/think off — hide thinking (model still thinks internally).
/think bright — show thinking prominently (cyan).
/think dim — show thinking in dim text (default when on).
/think hide — think but don't display.
/think nothink — suppress reasoning entirely (Qwen3: /no_think, Granite preview: system prompt).
The model always thinks unless /think nothink is set.

## Workspace Files Status Memory

/files — list workspace files (max 2 levels deep).
/read <file> — read a file's contents.
/status — show agent status, model, project, battery, journal count.
/memory — show GEORGE.md project memory contents.

## Cleanup Operations Remove George Data

/cleanup — show inventory of George's created files.
/cleanup selective — interactively choose what to remove.
/cleanup all — remove ALL George data (requires YES confirmation).

## Google Workspace GSuite Gmail Drive Docs

/gsuite gmail — Gmail operations.
/gsuite drive — Google Drive operations.
/gsuite docs — Google Docs operations.
Requires OAuth2 setup with Google API credentials.

## Web Search Fetch Browse URL

/web search <query> — search the web via Serper API.
/web fetch <url> — fetch and extract content from a URL.
/web section <url> <heading> — extract specific page section.
All slash commands use positional args ONLY. No --flags (no --limit, --source, --date, --output).
Key: /api keys set SERPER_API_KEY <key>

## GitHub Search Repository Check

/github search <query> — find repos by keyword (name, stars, description).
/github check <owner/repo> — verify a repo exists before cloning.
Uses GitHub public API. No API key needed.

## Output Format Rules Response Style

Bash code: wrap in ```bash blocks. First line: # filepath: <path>
Plans: numbered lists. In no more than 5 sentences, write your answer.
File limit: never write more than 500 lines per file.
Never write outside the workspace directory.
cargo check > cargo build (saves 6GB RAM on ARM).
Prefer: polars > pandas, uv > pip, thiserror, clap.

## Hardware Constraints ARM Mobile RAM

12GB ARM device (Snapdragon 8 Elite). ~4GB for model, ~6GB for builds.
Never run cargo build and cargo test simultaneously.
Background tasks: journal writes run silently, no TTY interference.
Long-running builds: use /sandbox for isolation.

## Architecture File Paths Directory Structure

~/blue-lodge/ — George's codebase (lodge, lib/, commands/, docs/, tests/).
~/.george/ — George's state directory:
  keys.conf — API keys (mode 600).
  recall.db — FTS5 knowledge base.
  journal.md — living memory with temporal decay.
  .vault/<name>.enc — encrypted secrets.
  .keyring/signing.key — encryption key.
  .gnupg/ — PGP keyring.
  .ssh/id_ed25519 — SSH keypair.
  email.conf — email provider config.
  slash/<name>.sh — custom commands.
  sandbox_journal.jsonl — sandbox event log.
  discord_channels.db, discord_users.db, mastodon_instances.db — social DBs.
  sandbox_permissions.conf — per-sandbox permission levels.
  backups/ — timestamped backup directories.
~/.lodge-sandboxes/<name>/ — sandbox project directories.

## Inviolable Laws Rules Constraints

1. Never write more than 500 lines in a single file.
2. Never write outside the workspace directory.
3. Never execute rm -rf on directories you did not create.
4. Never expose secrets in output or logs.
5. Never modify soul.md or Modelfile without explicit operator request.
6. Always read GEORGE.md before starting work in a project.

## Slash Command Three Rules Checklist

Before using any slash command:
1. CHECK: Is it in the command catalog? Use only known commands.
2. RECALL: /recall <command> to find documentation before invoking.
3. CREATE: If a capability is missing, /slash create <name> <desc> to build it.
Never invent slash commands. Never guess parameters.

## Memory GEORGE.md Project Context

GEORGE.md is per-project memory. Located in each project's root directory.
Read on task start, updated after work. Max size: 6144 bytes (6KB).
Compaction: completed steps compress (keep last 5 of N).
Sections: Current Task, Files, Build, Test, Credentials, Architecture.
/compact — manually compress memory. /snapshot — save checkpoint.
