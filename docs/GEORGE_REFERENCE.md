# George Quick Reference

FTS5-optimized knowledge cards. Each section is a self-contained fact.

## Discord Post to Channel

/social post discord <channel> <text> — post to a named Discord channel.
Channel names auto-resolve from registry. Strips quotes from args.
If channel unknown, falls back to webhook or DISCORD_DEFAULT_CHANNEL.
Sync channels first: /social discord channels sync

Examples:
  /social post discord general Good morning everyone
  /social post discord lunkers Just caught a 5lb bass at Cedar Lake

## Discord Direct Message

/social discord dm <user> <text> — send a DM to a Discord user.
Resolves username to user ID from registry.
Sync users first: /social discord users sync

Examples:
  /social discord dm pompler Hey, check out that repo I found
  /social discord dm jake Meeting at 3pm today

## Discord At-Mention Users

Use @username in Discord messages. Auto-resolves to <@user_id> on send.
Requires user registry: /social discord users sync
Example text: Hey @pompler check this out → Hey <@123456> check this out

## Discord Channel Registry

/social discord channels sync — sync channel names from Discord API.
/social discord channels list — show registered channels.
/social discord channels add <name> <id> — manually register a channel.
/social discord channels remove <name> — remove a channel.
Channels resolve by name (strips leading #). Numeric IDs pass through.

## Discord User Registry

/social discord users sync — sync usernames and IDs from server.
/social discord users list — show registered users.
/social discord users add <name> <id> — manually add a user.
/social discord users remove <name> — remove a user.
/social discord users resolve <name> — look up user ID.

## Discord Read Messages

/social discord read <channel> — read recent messages from a channel.
Channel can be a name (resolved) or numeric ID.

## Discord Validate Bot

/social discord validate — test the bot token and show bot identity.
Requires DISCORD_BOT_TOKEN in keys.

## Discord Setup Keys

Bot: /api keys set DISCORD_BOT_TOKEN <token>
Webhook: /api keys set DISCORD_WEBHOOK_URL <url>
Server: /api keys set DISCORD_GUILD_ID <id>
Default channel: /api keys set DISCORD_DEFAULT_CHANNEL <id_or_name>

## Post to X Twitter

/social post x <text> — post a tweet.
/social x timeline — read your home timeline.
/social x search <query> — search tweets.
/social x reply <tweet_id> <text> — reply to a tweet.
/social x delete <tweet_id> — delete a tweet.
Key: /api keys set X_BEARER_TOKEN <token>

## Post to Mastodon

/social post mastodon <text> — post to default Mastodon instance.
/social post mastodon instance:<name> <text> — post to specific instance.
/social mastodon timeline — read home timeline.
/social mastodon search <query> — search posts.
/social mastodon notify — check notifications.

## Mastodon Multi-Instance

/social mastodon instances list — show registered instances.
/social mastodon instances add <url> <token> — register instance + token.
/social mastodon instances remove <url> — remove an instance.
Token resolution: specific instance → first registered → legacy key.
Legacy key: /api keys set MASTODON_ACCESS_TOKEN <token>

## Post to Bluesky

/social post bluesky <text> — post to Bluesky.
/social bluesky timeline — read timeline.
/social bluesky search <query> — search posts.
Keys: /api keys set BLUESKY_HANDLE <handle>
      /api keys set BLUESKY_APP_PASSWORD <password>

## Post to Telegram

/social post telegram <text> — send message to Telegram chat.
/social telegram updates — get recent updates.
/social telegram me — show bot info.
Keys: /api keys set TELEGRAM_BOT_TOKEN <token>
      /api keys set TELEGRAM_CHAT_ID <chat_id>

## Social Post Unified Toggle

/social post <platform> [channel] <text> — post to one platform.
Default: requires explicit platform name.
Toggle: /api keys set SOCIAL_UNIFIED_POST 1 — enables broadcast to all.
With toggle on: /social post <text> sends to all configured platforms.

## Social Status Check

/social status — show all configured social platforms and integration details.
Shows: key status, channel count, user count, unified toggle state.

## Sandbox Create New

/sandbox new <name> <type> — create a sandbox. Types: rust, python, shell.
Rust: runs cargo init with optimized profiles.
Python: creates venv with uv or pip.
Shell: plain directory with bin/.

Examples:
  /sandbox new url-shortener rust
  /sandbox new data-pipeline python
  /sandbox new backup-script shell

## Sandbox Build Test Run

/sandbox build <name> — build using detected toolchain (cargo/uv/make).
/sandbox test <name> — run tests using detected toolchain.
/sandbox run <name> <cmd> — run arbitrary command inside sandbox.
/sandbox cd <name> — switch working directory into sandbox.

## Sandbox Management

/sandbox list — show all sandboxes with type, size, activity.
/sandbox status <name> — detailed info + recent journal entries.
/sandbox journal [n] — show last N sandbox events.
/sandbox rm <name> — delete a sandbox.
/sandbox clone <url> [name] — clone a git repo into a new sandbox.

## Init Scaffold Project

/init <name> <lang> — scaffold a new project.
Types: rust, python, rl, data, automation, notebook, shell.
Creates project dir + GEORGE.md + starter code.
Name must have no spaces. Language is fuzzy-matched.

Examples:
  /init task-manager rust
  /init sentiment-analyzer python
  /init deploy-helper shell

## Write Save Files

/write <file> <content> — write or overwrite a file (creates dirs).
/save <file> <content> — save content to a file (creates parent dirs).
Both create parent directories automatically.

## Download Files

/download <url> [dest] — download a URL to a local file.
/download <path> [dest] — copy a local file.
Default dest: current directory with original filename.

## Build Test Fix Commit Push

/build [release] — build project (reads GEORGE.md ## Build).
/test [args] — run tests (reads GEORGE.md ## Build).
/fix [error] — diagnose and fix errors.
/commit [msg] — generate AI commit message and commit.
/push — push to GitHub (requires SSH key setup).

## Clone Repository

/clone <url> — clone and setup a repository.
Auto-converts HTTPS to SSH URLs.
Creates sandbox, clones, writes GEORGE.md.

## Git Setup Configuration

/git setup — full auto-setup (identity + SSH + GPG + GitHub).
/git status — show git config overview.
/git identity [name] [email] — set git user.
/git ssh-keygen — generate SSH keypair.
/git ssh-config — write persistent SSH config for GitHub.
/git remote [name] <url> — add/update remote (auto HTTPS→SSH).
/git test — test SSH connection to GitHub.

## Web Search Fetch Images

/web search <query> — search the web via Serper API. Returns URLs + snippets.
/web fetch <url> — read a webpage's text content. Needs a URL (NOT a query).
/web images <query> — image search via Serper (returns direct image URLs). Key: SERPER_API_KEY.
/web scrape-images <url> — extract image URLs embedded in a page (no API key needed).
Key: /api keys set SERPER_API_KEY <key>

IMAGE WORKFLOW (finding + describing images):
  Step 1: Find image URLs → /web search <topic> OR /web scrape-images <page_url>
  Step 2: Analyze image   → /vision <image_url> [prompt]
  /vision accepts image URLs directly — NO /download step needed.
  Do NOT use /web fetch on image URLs (that's for webpages, not images).

VISION NOTE: /vision requires a vision-capable model. If current model lacks vision:
  Switch first: /models single minist-inst
  Then: /vision <image_url> [prompt]

Examples:
  /web search rust async tutorial 2025
  /web fetch https://docs.rs/tokio/latest
  /web images landscape wallpaper 4k
  /web scrape-images https://unsplash.com/s/photos/mountain
  /vision https://example.com/photo.jpg describe this building

## GitHub Search Check

/github search <query> — find repos by keyword (name, stars, description).
/github check <owner/repo> — verify a repo exists before cloning.
Uses GitHub public API. No key needed.

## Email Send Inbox

/email send <provider> <recipient> s=subject words b=body words — send an email.
  provider: gmail, protonmail, zoho. Recipient goes right after provider.
  Use s= and b= for subject and body. Also accepts subject= and body= as aliases.
  Optional: to=addr (only if recipient not given positionally).

Examples:
  /email send gmail user@example.com s=Hello there b=How are you today?
  /email send protonmail boss@work.com s=Weekly Report b=All tasks completed this week
  /email send zoho friend@mail.com s=Lunch tomorrow? b=Want to grab lunch at noon?
/email inbox <provider> [count] — check inbox.
/email status — show email and SSH config.
/email setup [provider] — configure (protonmail/zoho/tuta/disposable).
For actual email ONLY. Social posts use /social, not /email.

## PGP Sign Messages

/pgp sign <msg> — PGP-sign a message for authenticity.
/pgp signpost <msg> — sign and post to social media.
/pgp export — export your public key.
Auto-generates key if missing. Uses GPG.

## Encrypted Secrets Vault

/secret set <key> <value> — store an encrypted secret.
/secret get <key> — retrieve a secret.
AES-256-CBC encryption with PBKDF2 key derivation.
Master password set on first use.

## API Key Management

/api keys set <KEY> <VALUE> — set an API key.
/api keys list — show configured keys.
/api keys rm <KEY> — remove a key.
Stored in ~/.george/keys.conf.

## Recall Knowledge Search

/recall <query> — search all indexed knowledge.
/recall stats — show chunk counts and DB size.
/recall reindex — force reindex all sources.
/recall clear — delete entire index.
Uses FTS5 BM25 ranking. Porter stemming matches word variants.

## Ingest Documents

/ingest <file> [label] — add a document to knowledge base.
/ingest list — show ingested documents.
/ingest rm <label> — remove an ingested document.
Supports: .md .txt .pdf .html .py .sh .rs .js .ts .json .yaml

## Journal Living Memory

/journal write <text> — write to George's journal (living memory).
/journal read — read recent journal entries.
Use journal to persist facts from external sources.
Pattern: read source → journal write summary → recall later.

Examples:
  /journal write Learned that Cedar Lake is stocked with trout every April
  /journal write Discord user pompler prefers to be contacted after 5pm

## Phone Dashboard

/phone — full dashboard (battery, carrier, WiFi, GPS, storage).
/phone location — current GPS/network coordinates.
/phone where — one-line location summary.
/phone sms inbox — read text messages.
/phone sms send <number> <message> — send SMS.
/phone calls — recent call log.
/phone wifi — WiFi connection info.

## Crypto Wallet Bitcoin

/wallet btc balance — check BTC balance.
/wallet btc address — show receive address.
Key: /api keys set BTC_ADDRESS <address>
Uses mempool.space public API. No auth needed for balance checks.

## Crypto Wallet Solana

/wallet sol balance — check SOL balance.
/wallet sol address — show wallet address.
Key: /api keys set SOL_ADDRESS <address>
Uses Solana JSON-RPC public endpoints.

## Crypto Wallet Cardano

/wallet ada balance — check ADA balance.
/wallet ada address — show wallet address.
Key: /api keys set ADA_ADDRESS <address>
Uses Blockfrost API: /api keys set BLOCKFROST_API_KEY <key>

## Container Proot Distro

/container install <distro> — install a proot-distro container.
/container login <name> — enter a container shell.
/container exec <name> <cmd> — run a command in a container.
/container list — list installed containers.
/container here <name> <cmd> — run with current dir at /workspace.
/container info <name> — show container size/details.
/container reset <name> — remove and reinstall.
/container pentest — one-command Kali + top tools.
/container rm <name> — remove a container.
Distros: ubuntu, alpine, kali, fedora, void, arch, debian, opensuse.
Full Linux environment via proot-distro.

## Vitals System Dashboard

/vitals — system dashboard (disk, RAM, CPU, battery, WiFi, cell).
/vitals context — one-line summary for LLM context injection.
Shows warning thresholds: disk <500MB, RAM <200MB, battery <15%.

## Backup Operations

/backup local — quick backup of identity and memory.
/backup restore [name] — restore from a backup.
/backup list — show all backups.
/backup github — save + push to GitHub.

## Slash Custom Commands

/slash — list custom commands.
/slash create <name> <desc> — create a new custom command (LLM-assisted).
/slash <name> [args] — run a custom command.
/slash test <name> — test a custom command.
Stored in ~/.george/commands/. Uses available lib functions.

## Memory Loop Pattern

Read → Remember → Respond. For ANY external input:
1. READ: /social discord read <channel> or /web fetch <url>
2. SAVE: /journal write "summary of what was read"
3. RECALL: /recall <topic> to retrieve later
4. RESPOND: /social post discord <channel> "reply"
Never web-search for info from a social channel. Read the source.

## Tuning Model Parameters

George uses a dual-model architecture with 9 models across 4 families.
Primary model handles /ask and agent tasks. Secondary handles routing, tools, journal.
Use /models to switch. Use /model to adjust sampling.
Global defaults: temperature 0.6, repeat_penalty 1.3, presence_penalty 0.8.
Per-scenario overrides: ask (0.5), agent (0.3), router (0.1), journal (0.6), tool (0.3).
Set via: /model temp 0.3, /model temp-ask 0.7, /model reset.
Environment: LLM_TEMPERATURE, LLM_REPEAT_PENALTY, LLM_PRESENCE_PENALTY.
Per-scenario env: LLM_TEMP_ASK, LLM_PRESENCE_ROUTER, etc.

## Soul Personality Toggle

/soul on — inject full soul.md into prompts (~4500 tokens).
/soul off — inject condensed identity + Practical Craft only.
Full soul includes moral philosophy, humor, ethics.

## Model Library Management

/models — show status + full model list.
/models list — list all 9 available models.
/models status — show current mode, slots, details.
/models select primary <key> — set primary model.
/models select secondary <key> — set secondary model.
/models single <key> — single-model mode.
/models dual — back to dual-model mode.
Families: qwen (think+inst), llama (base+inst), granite (inst+hybrid+preview), ministral (think+inst).
Models: qwen3-think, qwen3-inst, llama32, llama32-inst, granite4, granite4-h, granite4-preview, minist-think, minist-inst.

## Thinking Mode Display

The model always thinks internally. `/think` controls visibility:

/think — cycle through modes (dim→bright→hidden→off→nothink).
/think on — show LLM thinking process (dimmed).
/think off — hide thinking (default).
/think bright — show thinking prominently.
/think dim — show thinking in dim text.
/think hide — think but don't display.
/think nothink — suppress reasoning entirely (Qwen3: /no_think suffix, Granite preview: system prompt, Ministral: no effect).

## Agent Task Execution

George uses a dual-loop architecture:
Macro loop: strategist plans milestones from the task.
Micro loop: router picks tool → specialist generates command.
Each milestone is one actionable step with a slash command.

## Meta-Commands (Self-Tuning Authority)

George has full authority to adjust his own hyper-parameters and system
controls during task execution. These are exposed as slash commands so
he can reason about and tune his own behavior.

Sampling: /model temp 0.3, /model temp-agent 0.4, /model repeat-ask 1.5, /model reset.
Planning: /limits steps 8, /limits depth 3, /limits tokens 16384.
Thinking: /think on, /think dim, /think hide, /think nothink.
Identity: /soul on (full personality, ~4500 tok), /soul off (condensed, ~250 tok).
Persistence: /config save (persist current settings), /config show, /config reset.
Backend: /backend auto, /backend ollama, /backend llamacpp.
GPU: /gpu <layers> (set GPU offload for llama-server).
Debug: /debug on, /debug off.

These commands are safe for edge devices — they only adjust in-memory
variables or write small config files. No heavy I/O or network calls.
On constrained hardware (Snapdragon 8 Gen 4/5, 12GB RAM), George
should prefer low temperatures (0.2-0.4) for agent mode and keep
context injection lean (/soul off, reduced /limits tokens).

## Workspace Files & Navigation

/ls [path] [depth] — list files as indented tree. Default: current dir, depth 3.
/ls src — list the src/ directory tree (depth 3).
/ls . 5 — list current dir at depth 5 (reaches deeply nested files).
/ls src/api 2 — list src/api/ at depth 2.
/files [path] [depth] — alias for /ls (backward compat).
/cd <dir> — change working directory.
/read <file> — read a file's contents (first 100 lines).
/status — show agent status and current project.
/memory — show GEORGE.md project memory.

Depth range: 1-8. Excludes: .git, target, node_modules, __pycache__, .venv.
Max entries: 80 (prevents runaway output on large projects).

Examples:
  /ls                → tree of current workspace at depth 3
  /ls . 1            → just immediate children (files + dirs)
  /ls src/api 4      → API module tree 4 levels deep
  /ls tests          → see what tests exist

## Cleanup Operations

/cleanup — show inventory of George's created files.
/cleanup selective — interactively choose what to remove.
/cleanup all — remove ALL George data (requires YES confirm).

## Google Workspace

/gsuite gmail — Gmail operations.
/gsuite drive — Google Drive operations.
/gsuite docs — Google Docs operations.
Requires OAuth setup with Google API credentials.
