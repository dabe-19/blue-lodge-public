---
title: "Sovereign Reactive Event Bus & OSINT Trigger Pipeline"
description: "Architecture and implementation of the Blue Lodge reactive event bus: FIFO event stream, typed events, decoupled reactors, OSINT watchers, and alerting cascades."
subsystem: "ipc"
tags:
  - event-bus
  - osint
  - reactive
  - cron
  - searxng
  - alerts
okf_id: "urn:blue-lodge:doc:event-bus-and-osint-pipeline"
related:
  - "[[INDEX]]"
  - "[[FIFO_ASYNC_IPC_FLOWCONTROL]]"
  - "[[SEARXNG_METASEARCH]]"
  - "[[CRON_AND_SCHEDULING]]"
  - "[[RESEARCH_VERIFIER]]"
---

# Sovereign Reactive Event Bus and OSINT Trigger Pipeline

## 1. Overview and Design Intent

Blue Lodge operates two distinct but interconnected scheduling and event systems:

1. **The Autonomic Cron Daemon** (`lib/sys/cron.sh`) -- a 5-second tick loop that polls
   time-based schedules and launches jobs when their interval elapses.
2. **The Reactive Event Bus** (`lib/ipc/event_bus.sh`) -- a FIFO-backed event stream
   that dispatches typed events to registered reactors in real time.

The OSINT Watcher and Financial Analyzer sit between these two systems. A cron job
invokes the watcher on a schedule. The watcher queries SearXNG, scores results, and
emits structured events into the bus. Reactors registered on the bus respond to those
events with downstream actions (logging, notifications, dossier writes, deep fetches).

The key design question this document answers: **if a cron job already fires the sweep,
what role does the event bus play?** The answer is separation of concerns:

- The **cron daemon** answers "when does the sweep run?"
- The **watcher engine** answers "what did the sweep find?"
- The **event bus** answers "what should happen with each finding?"

This separation means you can change reactive behavior (add a Discord notification,
trigger a web scrape, update a dashboard) without modifying the watcher code or the
cron schedule. You simply register or remove reactors.

---

## 2. System Architecture

```
                           SCHEDULING LAYER
                    ┌────────────────────────────┐
                    │  Autonomic Cron Daemon      │
                    │  lib/sys/cron.sh            │
                    │  5-second tick loop         │
                    │  PID: .george/.cron.pid     │
                    └───────────┬────────────────-┘
                                │ interval elapsed
                                ▼
                    ┌────────────────────────────┐
                    │  OSINT Sweep Execution      │
                    │  commands/osint.sh          │
                    │  calls osint_watcher.py or  │
                    │  finance_analyzer.py        │
                    └───────────┬────────────────-┘
                                │ for each new result
                                ▼
                    ┌────────────────────────────┐
                    │  ANALYSIS + DEDUPLICATION   │
                    │  SHA256 seen-ledger check   │
                    │  Composite scoring          │
                    │  Category classification    │
                    └───────────┬────────────────-┘
                                │ new signal detected
                    ┌───────────┴────────────────-┐
                    │                             │
                    ▼                             ▼
         ┌──────────────────┐          ┌──────────────────┐
         │  EVENT BUS EMIT  │          │  DOSSIER APPEND   │
         │  event_bus.fifo  │          │  dossiers/*.md    │
         │  JSON envelope   │          │  Markdown table   │
         └────────┬─────────┘          └──────────────────-┘
                  │
                  ▼
         ┌──────────────────┐
         │  REACTOR DISPATCH │
         │  reactors.json    │
         │  Pattern match    │
         │  Debounce guard   │
         │  Depth limiter    │
         └────────┬─────────┘
                  │ matched reactor
                  ▼
         ┌──────────────────┐
         │  REACTION ACTION  │
         │  eval $action     │
         │  (async subshell) │
         └──────────────────-┘
```

---

## 3. The Cron Layer: When Things Run

### 3.1 Daemon Lifecycle

The cron daemon (`_cron_loop_runner`) is a detached background process that:

| Attribute       | Value                                |
| --------------- | ------------------------------------ |
| Tick interval   | 5 seconds                            |
| PID file        | `.george/.cron.pid`                  |
| Log file        | `.george/cron.log`                   |
| State file      | `.george/cron_state.json`            |
| Process model   | `setsid` detached from terminal      |
| Self-healing    | Supersedes stale daemons on startup  |

Each tick calls `cron_tick`, which iterates over built-in sweeps (sentinel, PR,
issue, discord, email, social) and custom jobs in `.george/cron_jobs/*.sh`.

### 3.2 Custom Cron Jobs

An OSINT sweep becomes a cron job by placing a script in `.george/cron_jobs/`:

```bash
#!/bin/bash
# DESC: Financial OSINT sweep across grants, VC, and bounties
# INTERVAL: 600
# ENABLED: 1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
bash "$LODGE_DIR/commands/osint.sh" "finance sweep"
```

The cron engine reads `# INTERVAL:` to determine how many seconds between runs.
It reads `# ENABLED:` to gate execution. The `cron_state.json` tracks `last_run`
timestamps per job to prevent overlapping executions.

### 3.3 What the Cron Does NOT Do

The cron daemon does not interpret results, filter signals, or decide what to do
with findings. It is a scheduler, not an analyzer. The analysis and reaction
happens downstream in the watcher engine and event bus.

---

## 4. The Event Bus Layer: What Happens With Findings

### 4.1 FIFO Transport

The event bus uses a single named pipe as its ingress:

```
.george/ipc/event_bus.fifo    (POSIX named pipe, mode 0600)
```

Events are written as single-line JSON envelopes:

```json
{
  "event_id": "evt_1790734153_12345_a1b2c3",
  "type": "finance_grant_signal",
  "source": "finance_sbir_sttr_cyber_ai",
  "payload": { ... signal data ... },
  "depth": 0,
  "timestamp": 1790734153
}
```

The bus daemon (`event_bus_dispatch_loop`) holds the FIFO open with a
bidirectional file descriptor (`exec 3<>`) so the kernel never discards the
pipe buffer between writer disconnections.

### 4.2 Reactor Registry

Reactors are stored in `.george/reactors.json`:

```json
{
  "reactors": [
    {
      "id": "log_finance_grants",
      "event_type": "finance_grant_signal",
      "pattern": ".*SBIR.*",
      "action": "echo \"[GRANT] $EVENT_PAYLOAD\" >> .george/finance_alerts.log",
      "debounce_secs": 60,
      "enabled": true
    }
  ],
  "stats": {
    "events_total": 24,
    "reactions_fired": 3
  }
}
```

### 4.3 Dispatch Algorithm

When a line arrives on `event_bus.fifo`:

1. **Parse** the JSON envelope and extract `type`, `payload`, `depth`.
2. **Circuit breaker**: if `depth >= 3`, halt. This prevents infinite loops where
   a reactor emits an event that triggers itself.
3. **Match reactors**: for each enabled reactor:
   - Compare `event_type` against reactor's `event_type` (supports shell glob).
   - If reactor has a `pattern`, match it against the payload via `grep -E`.
   - Check `debounce_secs`: skip if this reactor fired within the cooldown window.
4. **Fire reaction**: execute the reactor's `action` in an async subshell with
   the following environment variables injected:

| Variable           | Content                              |
| ------------------ | ------------------------------------ |
| `$EVENT_ID`        | Unique event identifier              |
| `$EVENT_TYPE`      | Event type string                    |
| `$EVENT_SOURCE`    | Originating system                   |
| `$EVENT_DEPTH`     | Current recursion depth + 1          |
| `$EVENT_PAYLOAD`   | Full JSON payload                    |
| `$EVENT_TIMESTAMP` | Unix epoch of original emission      |
| `$REACTOR_ID`      | ID of the reactor that matched       |

### 4.4 The Relationship Between Cron and Bus

```
CRON: "Run the OSINT sweep every 10 minutes"
                │
                ▼
WATCHER: "Query SearXNG, score results, filter duplicates"
                │
                ├──▶ SEEN LEDGER: "Already saw this URL, skip"
                │
                ├──▶ DOSSIER: "Append scored row to dossiers/finance_intel.md"
                │
                └──▶ EVENT BUS: "Emit finance_grant_signal with payload"
                                    │
                                    ▼
                         REACTOR: "Match pattern, fire action"
                                    │
                          ┌─────────┴──────────┐
                          ▼                    ▼
                     Discord notify      Deep web fetch
```

The cron is the clock. The watcher is the sensor. The event bus is the nervous
system. The reactor is the reflex.

---

## 5. Event Trigger Templates

### 5.1 OSINT Watcher Template (`config/osint_watchers.yaml.template`)

This is the base template for general web index monitoring (e-commerce listings,
threat intel, paste exposure):

```yaml
watchers:
  - id: poshmark_vintage_leica
    name: "Poshmark & Secondary Marketplace Leica Watcher"
    enabled: true
    query: 'site:poshmark.com ("leica m" OR "leica lens")'
    time_range: "day"
    categories: ["general"]
    engines: ["google", "duckduckgo", "bing"]
    match_criteria:
      title_regex: "(?i)(leica|summicron)"
      exclude_regex: "(?i)(strap|case only)"
    actions:
      emit_event: "osint_listing"
      notify_discord: true
      auto_fetch: true
      dossier_path: "dossiers/ecommerce_intel.md"
```

**Key fields:**

| Field              | Purpose                                                    |
| ------------------ | ---------------------------------------------------------- |
| `query`            | SearXNG search query. Supports `site:`, `OR`, quoted terms |
| `time_range`       | `day`, `week`, `month`, or null for all-time               |
| `engines`          | Which SearXNG backends to query                            |
| `match_criteria`   | Post-query regex filtering on title and snippet text       |
| `actions`          | What to do with matched results                            |
| `emit_event`       | Event type string emitted to the bus                       |
| `auto_fetch`       | If true, triggers `commands/web.sh fetch` on the URL       |
| `dossier_path`     | Where to append the discovery markdown table               |

### 5.2 Financial Analyzer Template (`config/finance_osint.yaml`)

This extends the base template with analysis-specific fields:

```yaml
watchers:
  - id: sbir_sttr_cyber_ai
    name: "SBIR/STTR Cybersecurity & AI Solicitations"
    enabled: true
    query: '(SBIR OR STTR) (cybersecurity OR "developer tools") solicitation'
    time_range: "month"
    relevance_keywords:
      - "open source"
      - "developer tools"
      - "AI"
    min_composite_score: 25
    actions:
      emit_event: "finance_grant_signal"
      dossier_path: "dossiers/finance_intel.md"
```

**Additional fields over base template:**

| Field                 | Purpose                                                 |
| --------------------- | ------------------------------------------------------- |
| `relevance_keywords`  | Boost scoring when these terms appear in results        |
| `min_composite_score` | Minimum score (0-100) to emit. Filters noise            |

**Scoring formula:**

```
composite = (relevance * 0.40) + (category_confidence * 0.30) + (urgency * 0.30)
```

- **Relevance** (0-100): matches from `relevance_keywords` plus developer context terms
- **Category confidence** (0-100): regex matches against GRANT/VC/BOUNTY/etc. dictionaries
- **Urgency** (0-100): deadline keywords, date extraction, recency signals
- **Bonuses**: +15 for extractable dollar amounts, +10 for explicit deadline dates

---

## 6. Artifact Destinations

Every component in the pipeline writes to specific, predictable locations:

### 6.1 Persistent State (Survives Reboots)

| Artifact                              | Path                                         | Format    | Purpose                                    |
| ------------------------------------- | -------------------------------------------- | --------- | ------------------------------------------ |
| OSINT seen ledger                     | `.george/ipc/osint_seen.json`                | JSON      | SHA256-keyed dedup of previously seen URLs  |
| Finance seen ledger                   | `.george/ipc/finance_osint_seen.json`        | JSON      | Same, for financial signals                 |
| OSINT watcher config                  | `.george/osint_watchers.yaml`                | YAML      | Active watcher definitions                  |
| Finance watcher config                | `.george/finance_osint.yaml`                 | YAML      | Active financial watcher definitions        |
| Reactor registry                      | `.george/reactors.json`                      | JSON      | Event type to action mappings               |
| Cron state                            | `.george/cron_state.json`                    | JSON      | Per-job last_run timestamps                 |
| Discovery dossiers                    | `dossiers/*.md`                              | Markdown  | Human-readable scored intelligence tables   |

### 6.2 Runtime State (Ephemeral, Managed by GC)

| Artifact                              | Path                                         | Format    | Purpose                                    |
| ------------------------------------- | -------------------------------------------- | --------- | ------------------------------------------ |
| Event bus FIFO                        | `.george/ipc/event_bus.fifo`                 | Named pipe| Kernel-buffered event ingress               |
| Event bus PID                         | `.george/ipc/event_bus.pid`                  | Text      | Daemon process tracking                     |
| Event bus log                         | `.george/ipc/event_bus.log`                  | Text      | Append-only emission and reaction trace     |
| Reactor cooldown timestamps           | `.george/ipc/cooldowns/*.ts`                 | Text      | Per-reactor debounce epoch tracking         |
| FIFO IPC channels                     | `.george/ipc/channels/*/`                    | Directory | Per-channel data.fifo + ctrl.fifo + state   |
| Async promises                        | `.george/ipc/promises/*.json`                | JSON      | Background task resolution tracking         |
| Cron daemon PID                       | `.george/.cron.pid`                          | Text      | Daemon lifecycle tracking                   |
| Cron daemon log                       | `.george/cron.log`                           | Text      | Sweep execution trace                       |
| Task sandboxes                        | `.sandboxes/cron_*/`                         | Directory | Per-job task envelope and trajectory log    |

### 6.3 Configuration Templates (Versioned in Git)

| Template                              | Path                                         | Copied To                            |
| ------------------------------------- | -------------------------------------------- | ------------------------------------ |
| Base OSINT watchers                   | `config/osint_watchers.yaml.template`        | `.george/osint_watchers.yaml`        |
| Financial watchers                    | `config/finance_osint.yaml`                  | `.george/finance_osint.yaml`         |
| SearXNG settings                      | `config/searxng/settings.yml`                | Docker-mounted into container        |

---

## 7. Garbage Collection

Three GC systems manage cleanup across different scopes:

### 7.1 IPC Garbage Collector (`ipc_gc` in `lib/ipc/fifo_ipc.sh`)

This is the primary GC. It sweeps **all** IPC infrastructure including the event bus:

| Pass | Target                     | Condition                                    | Action                   |
| ---- | -------------------------- | -------------------------------------------- | ------------------------ |
| 1    | FIFO channels              | Keeper PID dead, idle > 300s, or CLOSED      | `ipc_channel_close`      |
| 2    | Orphaned keeper processes  | FD points to deleted state.json              | `kill -9`                |
| 3    | Wedged flowcontrol queues  | Credits=0 and backpressure=true for >15s     | `ipc_flow_unstick`       |
| 4    | Expired promises           | Status RESOLVED/REJECTED and age > TTL       | Delete .json and .out    |
| 5    | Stale lock files           | Age > 60s and acquirable                     | Remove                   |
| 6    | Event bus PID              | PID file points to dead process              | Remove PID file          |
| 7    | Filesystem watcher PID     | PID file points to dead process              | Kill and remove          |
| 8    | Reactor cooldowns          | Age > 3600s                                  | Remove .ts file          |

Invoked via: `/react gc`, `/ipc gc`, or automatically during cron sentinel sweep.

### 7.2 Event Bus GC (`event_bus_gc` in `lib/ipc/event_bus.sh`)

A lighter-weight GC focused only on event bus resources:

| Target               | Condition                  | Action            |
| -------------------- | -------------------------- | ----------------- |
| Bus PID file         | PID dead                   | Remove            |
| Watcher PID file     | PID dead or `--force`      | Kill and remove   |
| Cooldown files       | Age > 3600s                | Remove            |
| Event bus FIFO       | `--force` only             | Remove            |

### 7.3 Cron Log Rotation

The cron daemon self-manages log growth:

- `cron.log`: Rotated when > 2MB (keeps last 2000 lines)
- Per-job `trajectory.log`: Rotated when > 512KB (keeps last 500 lines)

### 7.4 Seen-Ledger Growth

The seen-ledger JSON files grow unboundedly. Currently there is no automated
purge. The recommended approach is periodic manual pruning:

```bash
# View count
jq '.items | length' .george/ipc/finance_osint_seen.json

# Clear entirely
/osint seen clear

# Or prune entries older than 30 days (manual jq)
jq --argjson cutoff "$(date -d '30 days ago' +%s)" \
   '.items |= with_entries(select(.value.first_seen > $cutoff))' \
   .george/ipc/finance_osint_seen.json > /tmp/pruned.json && \
   mv /tmp/pruned.json .george/ipc/finance_osint_seen.json
```

---

## 8. Pre-Built Event Triggers and Automated Reporting

### 8.1 Shipped Event Types

These event types are emitted by the built-in watchers:

| Event Type               | Source                  | Payload Contains                           |
| ------------------------ | ----------------------- | ------------------------------------------ |
| `osint_listing`          | `osint_watcher.py`      | title, url, domain, price, snippet, engine |
| `osint_shopify_drop`     | `osint_watcher.py`      | title, url, domain, snippet                |
| `osint_threat_alert`     | `osint_watcher.py`      | title, url, domain, snippet (credential exposure) |
| `finance_grant_signal`   | `finance_analyzer.py`   | title, url, category, score, amount, deadline |
| `finance_vc_signal`      | `finance_analyzer.py`   | title, url, category, score, amount        |
| `finance_sponsor_signal` | `finance_analyzer.py`   | title, url, category, score                |
| `finance_bounty_signal`  | `finance_analyzer.py`   | title, url, category, score, amount        |
| `finance_contract_signal`| `finance_analyzer.py`   | title, url, category, score                |
| `finance_flip_signal`    | `finance_analyzer.py`   | title, url, category, score                |
| `searxng_rss`            | `react.sh` rss-test     | title, url, topic                          |
| `file_changed`           | `event_bus_watch_fs`    | path                                       |

### 8.2 Example Reactor Configurations

**Log all financial grants to a dedicated file:**
```bash
/react add log_grants finance_grant_signal '.*' \
  'echo "[$(date)] GRANT: $(echo $EVENT_PAYLOAD | jq -r .title)" >> .george/finance_alerts.log'
```

**Trigger a deep web fetch when a high-value bounty is found:**
```bash
/react add fetch_bounties finance_bounty_signal '.*bounty.*' \
  'bash commands/web.sh fetch "$(echo $EVENT_PAYLOAD | jq -r .url)"' --debounce 30
```

**Send a Discord webhook on OSINT threat alerts:**
```bash
/react add discord_threats osint_threat_alert '.*' \
  'bash commands/social.sh discord-webhook "Threat Alert: $(echo $EVENT_PAYLOAD | jq -r .title)"' --debounce 120
```

**Chain an OSINT sweep result into research graph ingestion:**
```bash
/react add research_ingest osint_listing '.*' \
  'bash commands/research.sh ingest "$(echo $EVENT_PAYLOAD | jq -r .url)"' --debounce 60
```

### 8.3 Automated Dossier Reporting

Both watcher engines automatically append findings to dossier files:

**Base OSINT** appends to simple discovery tables:

```markdown
| Timestamp | Title | Price | URL | Domain |
| --- | --- | --- | --- | --- |
| 2026-09-29 20:52:46 | [ThinkPad X1 Carbon](https://...) | $29.79 | ... | www.ebay.com |
```

**Financial Analyzer** generates scored intelligence briefs grouped by category:

```markdown
### [GRANT] (3 signals)

| Score | Title | Amount | Deadline | Domain |
| :---: | --- | --- | --- | --- |
| [HIGH] 72 | [SBIR Phase II: Cyber AI](https://...) | $750,000 - $1,500,000 | October 15, 2026 | sam.gov |
| [MED] 45 | [NLNet Open Call](https://...) | up to $50,000 | -- | nlnet.nl |
```

The dossier path is configured per-watcher in the YAML template. Multiple watchers
can write to the same dossier (the file is opened in append mode with write-locking).

---

## 9. Complete Pipeline Walkthrough

Here is the exact sequence of events when a financial OSINT sweep fires:

### Step 1: Cron Tick
The daemon's `_cron_loop_runner` wakes every 5 seconds. It calls `cron_tick`.
`cron_tick` checks `.george/cron_state.json` for the `finance_sweep` job's
`last_run` timestamp. If `(now - last_run) >= INTERVAL`, it calls `cron_run_job`.

### Step 2: Job Execution
`cron_run_job` creates a task sandbox at `.sandboxes/cron_finance_sweep/`,
writes `task_meta.json`, and executes the job script. The script calls:
`bash commands/osint.sh "finance sweep"`

### Step 3: Python Analyzer Launch
`commands/osint.sh` dispatches to `_osint_finance`, which calls `_finance_py --sweep`.
This launches `lib/tools/finance_analyzer.py` via the venv Python or `uv run`.

### Step 4: SearXNG Queries
For each enabled watcher in `.george/finance_osint.yaml`, the analyzer calls
`query_searxng()` against `http://127.0.0.1:8081/search?q=...&format=json`.
SearXNG aggregates results from Google, Bing, and DuckDuckGo.

### Step 5: Deduplication
Each result URL is hashed with SHA256 (after stripping fragments and trailing slashes).
The hash is checked against `.george/ipc/finance_osint_seen.json`. If the hash exists,
the result is skipped.

### Step 6: Analysis
New results pass through the scoring pipeline:
- `classify_category()` -- regex-based category assignment (GRANT, VC, BOUNTY, etc.)
- `compute_urgency()` -- deadline and time-pressure signal extraction
- `compute_relevance()` -- keyword match against watcher's `relevance_keywords`
- `extract_amount_range()` -- dollar amount parsing from title and snippet
- Composite score computation with bonuses

### Step 7: Event Emission
For each signal that passes the `min_composite_score` threshold, the analyzer calls
`emit_event_bus()` from `osint_watcher.py`. This function:
1. Attempts a non-blocking `os.open(O_WRONLY | O_NONBLOCK)` on `event_bus.fifo`
2. Writes a single-line JSON envelope
3. On `BlockingIOError`, falls back to `subprocess` calling the bash `event_bus_emit`

### Step 8: Dossier Write
If the watcher has a `dossier_path`, the analyzer calls `write_finance_dossier()`,
which appends a scored markdown table section to the specified file.

### Step 9: Seen-Ledger Update
After all watchers complete, if any new signals were emitted, the seen-ledger is
atomically updated via `save_seen_state()` (write to `.tmp`, then `os.replace`).

### Step 10: Reactor Dispatch
Meanwhile, the event bus daemon (if running) reads the envelope from `event_bus.fifo`.
It iterates registered reactors in `.george/reactors.json`, matches event types and
patterns, checks debounce cooldowns, and fires matching actions in async subshells.

### Step 11: GC Sweep
Periodically (or on next sentinel sweep), `ipc_gc` runs and cleans up:
- Stale cooldown files from fired reactors
- Dead event bus PID references
- Expired promises from unrelated async tasks

---

## 10. CLI Reference

### OSINT Commands

| Command                              | Description                                  |
| ------------------------------------ | -------------------------------------------- |
| `/osint status`                      | Show watcher count and seen-ledger size      |
| `/osint sweep [id]`                  | Run base OSINT sweep (all or specific)       |
| `/osint test <id>`                   | Dry-run a specific watcher                   |
| `/osint list`                        | List configured watchers                     |
| `/osint template [restore]`          | View or restore base OSINT template          |
| `/osint seen [clear]`               | Inspect or clear seen-ledger                  |
| `/osint finance status`              | Show financial watcher status                |
| `/osint finance sweep [id]`          | Run financial sweep                          |
| `/osint finance test <id>`           | Dry-run a financial watcher                  |
| `/osint finance init`                | Copy finance template to .george/            |
| `/osint finance brief`               | Sweep and print human-readable brief         |

### Event Bus Commands

| Command                              | Description                                  |
| ------------------------------------ | -------------------------------------------- |
| `/react status`                      | Show bus daemon PID and throughput stats      |
| `/react start`                       | Start event bus daemon                       |
| `/react stop`                        | Stop event bus daemon                        |
| `/react list`                        | List registered reactors                     |
| `/react add <id> <type> <pat> <act>` | Register a reactor                           |
| `/react remove <id>`                 | Delete a reactor                             |
| `/react toggle <id>`                 | Enable/disable a reactor                     |
| `/react emit <type> <payload>`       | Manually emit an event                       |
| `/react logs [n]`                    | View event bus log                           |
| `/react api-search <query>`          | Search keyless API database for triggers     |
| `/react api-categories`              | List keyless API catalog categories          |
| `/react api-presets`                 | List pre-configured API trigger recipes      |
| `/react api-build <preset>`          | Deploy an API trigger & register reactor     |

### Trading & Market Commands

| Command                                                    | Description                                            |
| ---------------------------------------------------------- | ------------------------------------------------------ |
| `/trading status`                                          | Show paper portfolio value, cash, and +/- P&L          |
| `/trading report`                                          | Generate live 10-minute performance & trajectory brief |
| `/trading send-dm [user]`                                  | Stream report directly to Discord DM (default: operator)   |
| `/trading markets`                                         | Live active Polymarket prediction odds (zero-auth)     |
| `/trading trade <BUY\|SELL> <BTC\|ADA> <usd> [rationale]`   | Execute simulated spot cryptocurrency trade            |
| `/trading bet <YES\|NO> <market_id> <usd> [rationale]`     | Place simulated Polymarket prediction bet              |
| `/trading reset`                                           | Reset paper trading portfolio to $10k cash             |

### SDR Radio Lab Commands

| Command                     | Description                                           |
| --------------------------- | ----------------------------------------------------- |
| `/sdr status`               | Show SDR ingest status, spool directory, and gateway  |
| `/sdr ingest`               | Process pending P25 calls in local spool              |
| `/sdr sync`                 | Rsync recordings from remote SDR gateway over SSH     |
| `/sdr simulate`             | Generate synthetic routine P25 patrol call            |
| `/sdr simulate emergency`   | Generate synthetic P25 SWAT/pursuit emergency broadcast|
| `/sdr dossier`              | View recent SDR radio OSINT intelligence entries      |

### Cron Commands

| Command                              | Description                                  |
| ------------------------------------ | -------------------------------------------- |
| `/cron start`                        | Start autonomic daemon                       |
| `/cron stop`                         | Stop autonomic daemon                        |
| `/cron status`                       | Show daemon status and job schedules         |
| `/cron add <name> <interval> <cmd>`  | Register a custom cron job                   |
| `/cron run <name>`                   | Manually trigger a job                       |
| `/cron logs`                         | View daemon log                              |

---

## 11. Subagent Synthesis Pipeline & Autonomic Task Bay Integration

The intelligence synthesis pipeline adheres to the Open Knowledge Format standards:
- [Subagent Sandbox Lifecycle Standard](okf/standards/subagent_sandbox_lifecycle.jsonld)
- [FIFO Async IPC Flowcontrol Protocol](okf/standards/fifo_async_ipc_protocol.jsonld)

### Architecture

```
                    ┌────────────────────────────┐
                    │  finance_analyzer.py       │
                    │  (Detects High-Score Items)│
                    └─────────────┬──────────────┘
                                  │ delegates synthesis
                                  ▼
                    ┌────────────────────────────┐
                    │  lib/agents/synthesis_     │
                    │  worker.sh                 │
                    └──────┬──────────────┬──────┘
                           │              │
        Registers Subagent │              │ Opens POSIX FIFO Channel
                           ▼              ▼
        ┌─────────────────────┐   ┌─────────────────────────────┐
        │ .george/subagents.  │   │ .george/ipc/channels/       │
        │ json                │   │ synth_<id>/                 │
        │ Live in Autonomic   │   │ - data.fifo                 │
        │ Task Bay UI         │   │ - ctrl.fifo                 │
        └─────────────────────┘   └──────────────┬──────────────┘
                                                 │
                                                 ▼
                                  ┌─────────────────────────────┐
                                  │ Streaming Execution Trace:  │
                                  │ .george/subagents/<id>.log  │
                                  │ .george/subagents/<id>.out  │
                                  └──────────────┬──────────────┘
                                                 │
                                                 ▼
                                  ┌─────────────────────────────┐
                                  │ Emit to Event Bus:          │
                                  │ - finance_synthesis_complete│
                                  │ - finance_opportunity_alert │
                                  └─────────────────────────────┘
```

1. **Autonomic Task Bay Visibility**: When a sweep discovers opportunities, `synthesis_worker.sh` immediately registers an active subagent in `.george/subagents.json`. The Craftsman's Workbench web UI (`web/src/routes/tasks.rs`) detects the subagent and renders an active task card in the Autonomic Task Bay with phase transitions: `[ANALYZING] -> [SYNTHESIZING] -> [DOSSIER] -> [COMPLETED]`.
2. **POSIX FIFO IPC Flow Control**: Communication occurs over a named channel under `.george/ipc/channels/synth_<id>/`, utilizing sliding-window credit tokens and kernel atomic FIFO buffers.
3. **Streamed Logs**: Live generation traces stream into `.george/subagents/<id>.log` and `.out`.
4. **Resilient Synthesis**: The worker queries the local LLM inference fabric (`llama-server` on `http://127.0.0.1:8080` or Ollama on `http://127.0.0.1:11434`), falling back to structured deterministic synthesis if inference services are temporarily unreachable.

---

## 12. Keyless API Database Integration

Blue Lodge indexes 930+ curated zero-auth, keyless REST endpoints in `data/catalog/public_apis.sqlite` across Cryptocurrency, Finance, News, Government, and Security.

The API Trigger Building Engine (`lib/tools/api_trigger_builder.py`) allows operators to:
1. Search endpoints: `/react api-search <query>`
2. Deploy pre-configured recipes: `/react api-build <preset>`
   - `coinbase_btc`: Real-time Bitcoin spot USD price streamer
   - `coinbase_ada`: Real-time Cardano spot USD price streamer
   - `polymarket_active`: Polymarket high-volume prediction markets watcher
   - `mempool_fee_rate`: Bitcoin on-chain fee pressure monitor
   - `hackernews_top`: Developer tech intelligence watcher
3. Deploy custom polling scripts directly to `.george/cron_jobs/api_<id>.sh` with automatic SHA-256 deduplication and Event Bus emission.

---

## 13. Mock Trading Bot & Polymarket Simulator

The autonomous paper trading engine (`lib/tools/trading_bot.py`) simulates cryptocurrency positions and prediction market bets triggered by intelligence signals.

### Features:
- **Zero-Key Real-Time Market Data**: Fetches live BTC/ADA spot prices via public Coinbase/Kraken endpoints, and live prediction questions/odds via the Polymarket Gamma API (`https://gamma-api.polymarket.com/markets`).
- **SQLite Ledger**: Persists portfolio balances, active positions, realized/unrealized P&L, and catalyst rationales in `.george/trading/portfolio.db`.
- **Autonomic Event Reactor**: Automatically triggers position entries when receiving high-confidence OSINT events (`finance_crypto_signal`, `finance_opportunity_alert`, `polymarket_sentiment_signal`).
- **10-Minute Streaming Performance Reporter**: Formats a high-density intelligence report containing portfolio net equity, +/- P&L, live mark-to-market positions, trade rationales, and market trajectories.
- **Discord DM Delivery**: The autonomic cron job (`.george/cron_jobs/trading_reporter.sh`) runs every 600 seconds, updating mark-to-market prices and streaming the performance brief to Discord DM (`operator`) via `lib/comms/social.sh`.
- **Crypto Wallet Readiness**: Pre-wired with `lib/comms/wallet.sh` (`btc_balance`, `ada_balance`, testnet support) so the system seamlessly transitions from mock simulation to testnet/mainnet execution.

---

## 14. SDR Radio Lab & TrunkRecorder Hook

Connects remote or local SDR TrunkRecorder captures (P25 trunked & public broadcasts) into the OSINT intelligence pipeline.

### Features:
- **P25 Capture Ingestion**: Ingests TrunkRecorder JSON call metadata and audio files (`.wav`, `.m4a`).
- **Gateway Rsync Sync**: Integrates with the remote SDR server via jumpbox gateway (`192.168.1.20` / `george-home`), pulling captures into the local spool.
- **Emergency Priority Detection**: Automatically tags emergency calls (SWAT, high-speed pursuit, structure fire, mayday) based on emergency flags and incident keywords.
- **Event Bus Emissions**: Emits `sdr_p25_call` and `sdr_emergency` into `event_bus.fifo`.
- **Dossier Logging**: Appends structured call logs to `dossiers/sdr_osint.md`.
- **Offline Simulation**: Supports `--simulate [--emergency]` to generate realistic P25 calls for testing when the radio lab is idle.

---

---

## 15. Global Rolling Event Store & Compute Alpha Valuation Engine

The Sovereign Global Event Store (`.george/events.db`, managed via `lib/tools/event_store.py` and `commands/events.sh`) acts as a queriable timeseries and historical ledger for all events and reactions flowing through the reactive event bus.

### Core Architecture:
- **Global Event Ledger (`events`)**: Every event envelope flowing through `event_bus.fifo` is logged non-blockingly with timestamp, source subsystem, recursion depth, and raw JSON payload.
- **Reaction Firing Outcomes (`reactions`)**: Tracks each reactor execution, exit code, execution latency in milliseconds, and status (`EXECUTED`, `CIRCUIT_BREAKER_HALTED`, `DEBOUNCED`).
- **FTS5 Full-Text Search (`events_fts`)**: SQLite FTS5 index synchronized via triggers for lightning-fast search across all historical event envelopes and payloads (`/events search <query>`).
- **90-Day Rolling Retention Policy**: Automated rolling pruner (`/events prune [days]`) purges records exceeding their retention window (30-90 days per contract) while preserving active deal alerts.
- **Automated Compaction**: Periodic SQLite `VACUUM` and WAL checkpoints (`.george/cron_jobs/events_compaction.sh`, every 12 hours) reclaim disk space and prevent file fragmentation.
- **Typed Info Models & Contracts (`event_contracts`)**: Defines domain, schema version, and retention parameters for all event types (`compute_deal_alert`, `crypto_price_tick`, `finance_opportunity_alert`, `polymarket_market_shift`, `searxng_rss`, `sdr_osint`, `system_telemetry`).

### High-Alpha Compute Market Sentinels (GPU & RAM):
- **E-Commerce Sentinels**: Specialized watchers monitor eBay and secondary markets for high-value AI compute hardware:
  - **GPUs**: NVIDIA RTX 3090, RTX 4090, A100 (40GB/80GB), RTX A6000, AMD RX 7900 XTX.
  - **RAM**: High-density server/workstation DDR5 ECC RDIMMs (64GB, 128GB, 256GB) and DDR4 ECC RDIMMs (64GB, 128GB).
- **Valuation & Arbitrage Engine**:
  - **Accessory & Box Filtering**: Hard price floors discard empty boxes, coolers, shrouds, and waterblocks.
  - **Unit Economics**: Normalizes $/GB VRAM for GPUs and $/GB RAM for memory kits.
  - **14-Day Rolling Median**: Dynamically computes 14-day trailing median market prices, anchored to baseline Fair Market Value (FMV).
  - **Deal Classification**:
    - **STEAL**: $\ge 30\%$ discount below benchmark FMV.
    - **DEAL**: $\ge 20\%$ discount below benchmark FMV.
    - **FAIR / OVERPRICED**: Within expected bands.
- **Streaming Telemetry & Discord Reporting**: Top compute deals are injected into the 10-minute streaming report and Discord DM under `[COMPUTE]` tags.

---

## 16. Agentic Deal Verification Graph & Forensic Auditing

Secondary marketplace scrapers frequently ingest listings that look like high-alpha deals on paper (e.g., *[DEAL -27%] GeForce RTX 3090 at $499 ($20.79/GB)*) but turn out to be broken/for-parts hardware, empty retail boxes, off-platform scams, or low auction starting bids.

To solve this, Blue Lodge introduces the **Agentic Deal Verification Graph** (`lib/tools/deal_verifier.py`, `lib/agents/deal_verifier_worker.sh`), an autonomic 5-node pipeline that pulls down candidate listing websites, performs forensic auditing, invokes local LLM semantic evaluation, and verifies authenticity before any alert is dispatched.

```
                  CANDIDATE DEAL INGESTION
             (is_deal >= 20% discount below FMV)
                             │
                             ▼
                ┌─────────────────────────┐
                │      NODE 1: FETCH      │
                │  Browser Fingerprinting │
                │  Anti-Bot Challenge Det │
                └────────────┬────────────┘
                             │
                             ▼
                ┌─────────────────────────┐
                │     NODE 2: EXTRACT     │
                │  Title, Actual Price    │
                │  Condition, Seller Rep  │
                │  BIN vs. Auction Format │
                └────────────┬────────────┘
                             │
                             ▼
                ┌─────────────────────────┐
                │  NODE 3: FORENSIC AUDIT │
                │  - Parts/Broken Trap    │
                │  - Empty Box/Shroud     │
                │  - Off-Platform Scam    │
                │  - Auction Starting Bid │
                │  - Unconfirmed State    │
                └────────────┬────────────┘
                             │
                             ▼
                ┌─────────────────────────┐
                │   NODE 4: AGENTIC EVAL  │
                │  Sovereign LLM Prompt   │
                │  (llama.cpp port 8080)  │
                │  or Deterministic Fall  │
                └────────────┬────────────┘
                             │
                             ▼
                ┌─────────────────────────┐
                │  NODE 5: DISPATCH & DB  │
                │  deal_verifications log │
                │  compute_deal_alerts    │
                │  Event Bus Emitted:     │
                │  - compute_deal_verified│
                │  - compute_deal_rejected│
                └─────────────────────────┘
```

### Forensic Audit Red Flags:
1. **`PARTS_OR_DEFECTIVE`**: Catches "for parts or not working", "broken", "artifacting", "code 43", "no video output", "liquid damage", or "sold as-is". Discards immediately with 99% confidence.
2. **`ACCESSORY_TRAP`**: Catches "box only", "packaging only", "shroud only", "cooler only", "waterblock", or "poster/photo". Prevents empty box arbitrage scams.
3. **`SCAM_SUSPECTED`**: Catches off-platform payment solicitations ("WhatsApp", "Telegram", "Zelle only", "do not pay on eBay") or 0-feedback sellers offering extreme (>40%) discounts.
4. **`AUCTION_NOT_BIN`**: Catches low starting bids (e.g. $100 starting bid with 15 bids and reserve not met) masquerading as Buy It Now deals.
5. **`UNCONFIRMED_CONDITION`**: Withholds verified status when listing condition is ambiguous ("UNKNOWN") and does not explicitly confirm functional/working state.

### Hyperlinks in Reports & Dossiers:
- **Streaming 10-Minute Reports**: Formats active compute deals with clickable markdown hyperlinks:
  `[STEAL -36%] [64GB DDR5 ECC Registered RDIMM](https://ebay.com/itm/67890) at $119 ($1.86/GB) (Verified)`
- **Detailed Markdown Dossiers** (`dossiers/finance_intel.md`): Formats links as `[Open Listing](url)` and badges listings:
  `**[STEAL -35.7%][VERIFIED]**` for authentic deals, and strikes out rejected deals (`~~[DEAL -26.6%]~~ ⚠️ PARTS_OR_DEFECTIVE`).
- **Active Deals Filtering**: `query_active_deals()` automatically excludes listings with `verification_status = 'REJECTED'`, ensuring operators never see fake deals.

### CLI & Subagent Commands:
- `/events verify [id|all]` — Launches subagent worker `lib/agents/deal_verifier_worker.sh` to audit pending candidate deals.
- `/events audit` — Displays the forensic audit ledger with verdicts, confidence scores, and reasoning.
- `/events deals [GPU|RAM]` — Lists verified active compute deals with direct clickable hyperlinks.

---

## 17. Source File Index

| File                                  | Role                                                 |
| ------------------------------------- | ---------------------------------------------------- |
| `lib/ipc/event_bus.sh`               | Event bus daemon, emission, SQLite auto-ingestion    |
| `lib/ipc/fifo_ipc.sh`               | FIFO channel engine, flow control, GC                |
| `lib/tools/event_store.py`           | Global SQLite event store, FTS5, compute deal engine |
| `lib/tools/deal_verifier.py`         | Agentic Deal Verification Graph (fetch, audit, eval) |
| `lib/agents/deal_verifier_worker.sh` | OKF subagent worker for deal verification lifecycle  |
| `lib/tools/osint_watcher.py`         | OSINT web scraper, deal evaluator, bus emitter       |
| `lib/tools/trading_bot.py`           | Mock trading bot, Polymarket simulator, P&L reporter |
| `lib/tools/api_trigger_builder.py`   | Keyless API catalog discovery and trigger builder    |
| `lib/tools/sdr_ingest.py`            | TrunkRecorder P25 & emergency broadcast hook         |
| `commands/events.sh`                 | CLI dispatcher for `/events` store, deals, search    |
| `commands/osint.sh`                  | CLI dispatcher for `/osint` watchers & deals         |
| `commands/react.sh`                  | CLI dispatcher for event bus & `/react events`       |
| `commands/trading.sh`                | CLI dispatcher for trading bot & Polymarket bets     |
| `commands/sdr.sh`                    | CLI dispatcher for SDR radio lab & P25 triggers      |
| `commands/cron.sh`                   | CLI dispatcher for cron operations                   |
| `.george/cron_jobs/events_compaction.sh` | 12-hour 90-day retention prune & VACUUM cron job |
| `.george/cron_jobs/trading_reporter.sh`| 10-minute autonomic trading report cron job         |
| `tests/test_deal_verifier.sh`        | Automated test suite for deal verifier graph (23 tests)|
| `tests/test_event_store.sh`          | Automated test suite for event store & deals (29 tests)|
| `tests/test_event_bus.sh`            | Reactive event bus and IPC test suite (42 tests)     |
| `tests/test_advanced_event_pipeline.sh`| Automated verification test suite (43 tests)       |



