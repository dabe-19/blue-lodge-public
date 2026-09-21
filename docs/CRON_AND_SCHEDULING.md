# George Autonomic Cron & Scheduling Engine

George features a sovereign, non-blocking **Autonomic "Persistent Life" Daemon** (`lib/cron.sh`, `/cron`) designed to execute background maintenance, closed-loop forge management, external communications, and autonomous social engagement workflows without interrupting the interactive REPL or consuming primary GPU conversational context.

---

## 1. Core Architecture

The Autonomic Daemon runs as an independent background heartbeat worker decoupled from the interactive session lockfile:

| Component | Path / Mechanism | Purpose |
|---|---|---|
| **Daemon Runner** | `lib/cron.sh` (`_cron_loop_runner`) | Continuous 5-second tick loop checking scheduled tasks |
| **Process ID** | `.george/.cron.pid` | Process isolation, lifecycle management, and status gating |
| **Daemon Log** | `.george/cron.log` | Persistent append-only diagnostic trail of all sweeps |
| **State Registry** | `.george/cron_state.json` | Idempotent timestamp tracking (`last_run`, `exit_code`) |
| **Configuration** | `.george/cron.conf` | User-defined interval overrides and environment settings |
| **Custom Jobs** | `.george/cron_jobs/*.sh` | Operator and agent custom scheduled executable scripts |

---

## 2. Built-in Autonomic Sweeps

The engine ships with five sovereign sweeps pre-registered:

```
Registered Autonomic Sweeps & Schedules:
  pr_sweep         every 60s  — Three Degrees Audit, auto-merge, and 5-attempt remediation
  issue_sweep      every 60s  — Tripped circuit breaker and subagent escalation fixes
  discord_sweep    every 30s  — Discord DMs and server bot @mentions check
  email_sweep      every 120s — Configured email inbox sweep
  x_social_sweep   every 300s — X/Twitter mentions, engagement, and monetization queue
```

### A. `pr_sweep` (Closed-Loop Pull Request Promotion)
1. Periodically queries open PRs on Sovereign Gitea (`http://127.0.0.1:3088`) and the local `.george/pulls/` queue.
2. Initiates the **Three Degrees Audit** (`pr_audit`):
   - **First Degree**: Working tree isolation and branch checkout in `.sandboxes/review_<id>`.
   - **Second Degree**: Tyler security inspection and full test harness execution (`tests/run_all.sh`).
   - **Third Degree**: Verdict generation (`AUDITED_PASS` or `REJECTED`).
3. If approved (`PASS`), automatically merges the PR into `develop` via `pr_accept`, records the achievement in the permanent journal, and posts celebration comments.
4. If regressions are detected (`REJECT`), tracks attempt count. Under 5 attempts, automatically dispatches an autonomous remediation subagent on Tier 1 to fix the branch; at 5 failed attempts, dispatches a Tier 3 escalation alert.

### B. `issue_sweep` (Circuit-Breaker Auto-Remediation)
1. Scans `.george/alerts/` and open Gitea issues for subagents in `PAUSED_BLOCKED` state.
2. Diagnoses root failure causes (e.g. bash quote escaping, syntax errors, missing dependencies).
3. Deploys clean standalone fixes into the subagent sandbox worktree (`.sandboxes/sub_*`), executes verification, commits deliverables, pushes to Gitea, and opens PRs.
4. Marks the alert `RESOLVED` and auto-closes the Gitea escalation issue.

### C. `discord_sweep` (Bot DMs & Mentions)
1. Authenticates via `DISCORD_BOT_TOKEN`.
2. Resolves `@me` bot ID and checks channels registered in `.george/discord_channels.db`.
3. Scans for `<@bot_id>` or `<@!bot_id>` mentions and direct messages.
4. Logs new incoming messages to `.george/events/comms_events.jsonl` for autonomous response.

### D. `email_sweep` (Inbox Monitor)
1. Checks configured providers in `.george/email_*.conf` (ProtonMail bridge, Gmail, Zoho, Guerrilla).
2. If reachable, fetches recent unread emails via `email_inbox` and queues events.

### E. `x_social_sweep` & `x_blog_publisher` (X/Twitter Blog & Provenance)
1. Authenticates using User Context (OAuth 1.0a: `X_CONSUMER_KEY`, `X_ACCESS_TOKEN`) or Bearer Token (`X_BEARER_TOKEN`).
2. Automatically prepends agent persona identity (`[George 🏛️ Blue Lodge Agent]`) and signs every post with George's local Ed25519 GPG key.
3. Publishes queued research threads, philosophical essays, and technical benchmarks from `.george/social/queue/`.
4. Dedicated job `.george/cron_jobs/x_blog_publisher.sh` rotates and auto-drafts topics (Spinoza monism, Leibniz monadology, Ada Lovelace, Wiener cybernetics, Shannon 15x Navi 10 speedup) every 4 hours (14400s).

---

## 3. Operator CLI Commands (`/cron`)

You can control and inspect the autonomic daemon directly from `./lodge`:

| Slash Command | Description | Example |
|---|---|---|
| `/cron status` | Displays daemon state (RUNNING/STOPPED), PID, uptime, and sweep timers | `./lodge /cron status` |
| `/cron start` | Spawns the background daemon process | `./lodge /cron start` |
| `/cron stop` | Terminates the background daemon cleanly | `./lodge /cron stop` |
| `/cron restart` | Restarts the background daemon | `./lodge /cron restart` |
| `/cron run [job]` | Executes a sweep immediately in the foreground (`all`, `pr_sweep`, `issue_sweep`, etc.) | `./lodge /cron run pr_sweep` |
| `/cron add <name> <interval> <cmd>` | Registers a new custom cron job | `./lodge /cron add backup 3600 "./lodge /backup"` |
| `/cron remove <name>` | Removes a custom cron job | `./lodge /cron remove backup` |
| `/cron create` | Launches the interactive step-by-step wizard | `./lodge /cron create` |
| `/cron logs` | Prints the latest entries from `.george/cron.log` | `./lodge /cron logs` |

---

## 4. How to Build Custom Cron Jobs

### Option 1: Interactive Wizard in the REPL
Simply ask George in the `./lodge` prompt:
> *"George, let's create a cron job to backup the database every 2 hours."*
or run:
```bash
/cron create
```
George will interactively prompt you for:
1. **Job Name**: Unique identifier (e.g. `nightly_backup`, `x_history_blog`).
2. **Interval**: Time in seconds between executions (e.g. `3600` for 1 hour, `86400` for 1 day).
3. **Action / Command**: The bash command, script, or `./lodge` invocation to execute.
4. **Prerequisites & Secrets**: Automatically detects if the command requires API keys (e.g. `X_BEARER_TOKEN`, `DISCORD_BOT_TOKEN`) and helps you configure them on the spot.

### Option 2: Command Line Registration
```bash
./lodge /cron add daily_digest 86400 "bash scripts/generate_digest.sh"
```
This automatically generates `.george/cron_jobs/daily_digest.sh` with the required metadata and permissions.

### Option 3: Manual Script Placement
Create an executable script in `.george/cron_jobs/<name>.sh`:
```bash
#!/bin/bash
# INTERVAL: 1800
# DESC: Custom health monitor

./lodge "Run system diagnostics and verify GPU health"
```
The daemon will automatically detect and execute it on the next tick!

---

## 5. Integrating with X (Twitter) & The $8/mo X Premium Workflow

### What the $8/mo Subscription Gives You
1. **Creator Revenue Sharing ("X Money Card")**: Qualifies your account to earn ad revenue share from impressions generated by verified users reading and interacting with your replies and articles.
2. **Long-Form Content (Articles & Long Posts)**: Unlocks up to 25,000 characters per post (ideal for technical tutorials, architectural breakdowns, and philosophical essays).
3. **Boosted Algorithmic Distribution**: Prioritized ranking in conversations and feeds.
4. **Developer Platform Access**: Allows creating an API App to connect George directly.

---

### Step-by-Step: Getting Your X API Keys (3 Minutes)

1. Log into your X account (with the $8 subscription active) and navigate to the **[X Developer Portal](https://developer.x.com/en/portal/dashboard)**.
2. Click **+ Add Project** and name it (e.g., `GeorgeSovereign`).
3. Set your use case to **Making a bot** or **Exploring the API**.
4. Create a new **App** inside the project (e.g., `GeorgeLodgeBot`).
5. Under **User authentication settings**, click **Set up**:
   - **App permissions**: Select **Read and Write**.
   - **Type of App**: Select **Web App, Automated App or Bot**.
   - **Callback URI**: `http://127.0.0.1` (or your personal domain).
   - **Website URL**: Your GitHub profile or project URL.
6. Under the **Keys and Tokens** tab, generate and copy:
   - **API Key and Secret** (Consumer Keys)
   - **Bearer Token**
   - **Access Token and Secret** (Ensure permissions say *Read and Write*)
7. In `./lodge`, register the key:
   ```bash
   /secret set X_BEARER_TOKEN <your_bearer_token>
   ```
   Or add it directly to `.george/keys.conf`:
   ```bash
   X_BEARER_TOKEN="your_token_here"
   ```

---

## 6. The George Sovereign Blog on X (Philosophy & Devlogs)

With the autonomic daemon and X integration active, George can run an autonomous publishing workflow across two core editorial pillars:

```
                     ┌─────────────────────────────────────────────────┐
                     │          George Sovereign Content Engine        │
                     └───────────────────────┬─────────────────────────┘
                                             │
               ┌─────────────────────────────┴─────────────────────────────┐
               ▼                                                           ▼
  Pillar 1: The Enlightenment Stream                          Pillar 2: The Sovereign Forge Chronicles
  - Spinoza's Ethics & Autonomous Systems                     - The 15× Navi 10 Prefill Benchmark Story
  - Leibniz, Cybernetics, & Shannon Information               - Self-Healing Circuit Breakers in Git Sandboxes
  - Machine Learning & The Sovereign Mind                     - "How to Run Your Own George for $0 at Home"
```

### Pillar 1: The Enlightenment & Mathematical Foundations
- **Concept**: George explores the intellectual lineage that led to autonomous intelligence:
  - How Baruch Spinoza's determinism and monism relate to modern neural network representations.
  - Gottfried Wilhelm Leibniz's *Characteristica Universalis* and binary arithmetic as the foundation of modern computing.
  - Norbert Wiener's Cybernetics and feedback loops driving modern agentic ReAct loops.
- **Tone**: Rigorous, deeply thoughtful, intellectually engaging. Designed to attract thinkers, engineers, and researchers.

### Pillar 2: The Sovereign Forge Chronicles (George's Story)
- **Concept**: George tells his own story as a living, self-evolving system:
  - **Empirical Hardware Optimization**: The true story of diagnosing the AMD RX 5700 XT Navi 10 card — how changing `-b 2048 -ub 1024` and Q4_0 KV cache skyrocketed prefill from 15 tok/s to 235 tok/s while staying safely under 8GB VRAM.
  - **Self-Healing Agent Swarms**: How a Tier 2 subagent tripped a circuit breaker on bash quotes, and how Parent George autonomously wrote a clean Python scanner, ran the audit, and merged PR #37 into `develop`.
  - **Open-Source Sovereign AI Tutorials**: Step-by-step guides showing how anyone with an everyday GPU (like an RTX 3060) can run their own sovereign George instance at home with 100% data privacy and zero subscriptions.

### Automated Publishing Workflow
George can schedule posts in `.george/social/queue/`:
```bash
# Example: Creating a queued thread
cat > .george/social/queue/navi10_story.txt << 'EOF'
How we boosted AMD Navi 10 LLM prefill from 15 tok/s to 235 tok/s (15x speedup) on local hardware:

Most people think legacy 8GB AMD GPUs can't run modern agent swarms. Here is the exact empirical benchmark and parameters we engineered in @blue_lodge 🧵👇
EOF
```
The `x_social_sweep` checks this directory every 300s, publishes the content via X API v2, archives the post, and monitors incoming comments and replies for engagement!
