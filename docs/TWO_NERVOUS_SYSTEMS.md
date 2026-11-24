---
title: "The Blue Lodge's Two Nervous Systems: The FIFO IPC Protocol & the Gitea Remediation Loop"
description: "Cross-subsystem technical essay and design rationale tying the zero-daemon POSIX FIFO message conduit (lib/ipc) to the autonomic cron-swept Gitea remediation loop (lib/agents). The shared 'refuse the daemon' philosophy: named pipes, atomic rename, and flock as the control-plane substrate."
subsystem: "ipc"
tags:
  - ipc
  - fifo
  - event-bus
  - remediation
  - gitea
  - design-rationale
  - essay
okf_id: "urn:blue-lodge:doc:two-nervous-systems"
related:
  - "[[INDEX]]"
  - "[[FIFO_ASYNC_IPC_FLOWCONTROL]]"
  - "[[OPERATOR_GITEA_INTAKE]]"
  - "[[EVENT_BUS_AND_OSINT_PIPELINE]]"
  - "[[GITFLOW_ARCHITECTURE]]"
  - "[[BASH_TECHNIQUES]]"
---

# The Blue Lodge's Two Nervous Systems: The FIFO IPC Protocol & the Gitea Remediation Loop

> **Classification**: Cross-Subsystem Technical Essay & Design Rationale  
> **Status**: Approved narrative companion to `urn:blue-lodge:standard:fifo-async-ipc-flowcontrol` and `[[OPERATOR_GITEA_INTAKE]]`  
> **Primary Sources**: `lib/ipc/fifo_ipc.sh` (2281 ln), `lib/ipc/event_bus.sh` (1067 ln), `lib/agents/remediation.sh` (1629 ln), `lib/sys/cron.sh`  
> **Standards Reference**: `urn:blue-lodge:standard:fifo-async-ipc-flowcontrol`  

---

There is a theme running through both of these subsystems: **refuse the daemon.** No Redis, no RabbitMQ, no persistent socket listener, no sidecar supervisor. Everything is built on the three primitives a bare POSIX filesystem guarantees — named pipes, atomic rename, and `flock` — so that the whole control plane still breathes during intrinsic bootstrap, when nothing else is up. That constraint is what shapes the elegance (and the paranoia) of both.

The Lodge's two nervous systems:

1. **The FIFO Async/IPC Protocol** (`lib/ipc/fifo_ipc.sh`, `lib/ipc/event_bus.sh`) — the sensory and motor nerves. A filesystem-backed message conduit where the *state of the world* lives in a directory, and a named FIFO is merely the fast wake-up wire.
2. **The Gitea Remediation Loop** (`lib/agents/remediation.sh`, `lib/sys/cron.sh`) — the immune system. A closed-loop, cron-swept triage → fix → verify → PR pipeline that heals the tissue and, critically, knows how to stop on command.

---

## 1. The FIFO Async/IPC Protocol — a message conduit on the filesystem

### 1.1 Why a named pipe at all?

Unix domain sockets are the obvious answer to "how do I message another process." They require a persistent listener, a bound inode, and — critically — a live peer. Raw non-blocking `pipe(2)`s give you none of backpressure, delivery acknowledgment, or multi-producer multiplexing. An external broker gives you all of those, at the price of an entirely new failure surface that cannot exist before your own code can start.

The Lodge picks the third path: a **filesystem-backed message conduit** where the *state of the world* lives in a directory, and a named FIFO is merely the fast wake-up wire. If the consumer dies and restarts, the queue, the credits, and the backpressure flag are all still there on disk — the pipe was only the courier, never the office records.

### 1.2 Channel layout — the state lives on disk

Each channel is a directory under `.george/ipc/channels/<channel_id>/`:

```
.george/ipc/channels/<channel_id>/
├── data.fifo           # named pipe: atomic single-line NDJSON data frames (< PIPE_BUF)
├── ctrl.fifo           # out-of-band control pipe: PAUSE / RESUME / ABORT / PING wake-ups
├── state.json          # authoritative scalar control plane (patched in place under flock)
├── state.lock          # persistent flock inode — NEVER unlinked (prevents inode-reuse races)
├── queue/              # durable spillover buffer for credit-gated frames
│   ├── 000000000001_12345.frame
│   └── 000000000002_67890.frame
└── mailbox/            # sequence-ordered parking area for non-matching filtered frames
    └── 000000000001_54321.frame
```

Two pipes, deliberately separated:

- **`data.fifo`** carries the payload — single-line NDJSON frames, each bounded to fit inside the Linux `PIPE_BUF` atomicity window.
- **`ctrl.fifo`** carries out-of-band control (backpressure and wake-ups). Control traffic never competes with payload traffic for the same wire, so a `PAUSE` can't be starved behind a burst of data.

### 1.3 State management — the authoritative control plane

The directory *is* the state. `state.json` holds the scalar control plane, patched in place under an exclusive `flock` on `state.lock`:

```json
{
  "status": "OPEN",
  "mode": "stream",
  "window_size": 5,
  "credits": 5,
  "backpressure": false,
  "paused_by": 0,
  "seq_out": 0,
  "seq_in": 0,
  "keeper_pid": 104821,
  "owner_pid": 104820,
  "consumer_pid": 104825,
  "max_idle_secs": 300,
  "created_at": 1791060000,
  "last_activity": 1791060010
}
```

The paranoid details matter:

- **`state.lock` is never unlinked.** `flock` is keyed to the *inode*, and deleting a lock file invites a second process to acquire a fresh inode and believe it holds the mutex while the first still does. Keep the inode immortal and the race disappears.
- **`mode`** selects the channel's character: `stream` (a data channel with a non-blocking keeper) or `credit` (a pure token conduit used to gate reactor concurrency).
- **`backpressure` / `paused_by`** record that a sender was told to stop and *who* told it. Backpressure cannot be bypassed by a timeout or a self-grant; `FIFO_AUTO_RECOVER` is pinned to `0` on purpose.

### 1.4 Flow control — a sliding-window credit, not a wish

Senders must acquire a credit before writing. The receiver grants credits as it drains; when the window empties the sender blocks; a `PAUSE` on `ctrl.fifo` freezes the whole conduit until a `RESUME`. The five control verbs — `CREDIT`, `PAUSE`, `RESUME`, `ABORT`, `PING` — are the entire flow-control vocabulary.

Frames that would push a single `write(2)` past the 3800-byte `FIFO_SPILL_BYTES` line are **transparently spilled**: the payload is written to an immutable `.george/ipc/payloads/<id>.payload`, the frame shrinks to a `{"__spillover_ref__": ...}` descriptor (~350 bytes), and `ipc_recv` rehydrates and unlinks it. The guarantee — *one atomic, never-fragmented write* — holds for a 64 MiB logical payload exactly as it does for a 40-byte one.

### 1.5 The async engine & the reactive event bus

Background work runs as **promises** under `.george/ipc/promises/` (manifest `.json`, captured `.out`, `.lock`, and an ephemeral `.rel/` token dir). Each task is isolated in its own process group (`set -m`), finalizes **first-writer-wins** so a late cancel can't overwrite a recorded exit code, and `ipc_cancel` signals the whole group (`kill -s <sig> -- -<pgid>`) so no orphaned `curl`/`sleep` survives.

On top of the conduit sits the **Reactive Event Bus** (`lib/ipc/event_bus.sh`): envelopes arrive on `event_bus.fifo`, spool to `event_spool.ndjson` when the daemon is down or saturated, and replay in order on restart. Every event carries a `depth`; at `EVENT_BUS_MAX_DEPTH` (default 3) the loop is cut with a `CIRCUIT_BREAKER` so a handler that re-emits cannot cascade forever. Reactors (`reactors.json`) gate concurrency with a dedicated `rx_<id>` credit channel and pick an overflow policy — `drop`, `coalesce`, or `queue`.

### 1.6 Autonomic garbage collection — the janitor is also a file

`ipc_gc` runs five daemonless phases: sweep dead/idle channels, verify keeper processes against `/proc/<pid>/cmdline` and reap orphans, transition dead promises to `REJECTED (137)`, purge stale spillover payloads, and — the quiet one — **preserve every lock inode**. No supervisor process watches the pipes; the filesystem does, and a cron sweep simply walks it.

---

## 2. The Gitea Remediation Loop — the immune system

The FIFO protocol moves messages; the remediation loop moves *trust*. A bug reported on the local Gitea forge (`http://127.0.0.1:3001`) is, to the Lodge, an infection. The loop triages it, isolates it, fixes it, verifies the fix, and either opens a PR or escalates — and it knows how to die on command.

### 2.1 Intake — cron finds the infection

There is no listener waiting for an API webhook. `lib/sys/cron.sh` sweeps on a 60-second cadence; the intake engine — `remediation_gitea_intake()` in `lib/agents/remediation.sh`, fronted by `commands/gitea.sh` and `commands/remediation.sh` — polls the forge for issues carrying the trigger label. When one appears:

1. **Fetch & parse** the title, markdown body, labels, and operator comments via the Gitea API.
2. **Stage evidence**: if the body cites an incident ID (`incident_1791157134`) or crash dump, the matching files are pulled from `.george/telemetry/incidents/` into the agent's context — exact stack traces, env flags, failing inputs — so the loop never has to *guess* the repro.
3. **Provision an isolated worktree** at `.worktrees/fix-issue-<id>` on branch `remediation/issue-<id>`. The primary working tree is never touched during triage.

### 2.2 The fix loop & the Real Verification Gate

The agent runs a ReAct fix/refactor loop inside the worktree. Then comes the gate that separates a sober engineer from a hallucinating one:

- The full harness `bash tests/run_all.sh` must exit **0** in the isolated worktree.
- Any **new** regression test must have *failed before the fix* and *passes after*. A test you add and then "make pass" proves nothing.
- Only when the gate clears does George push the branch and open a Gitea PR with a structured changelog.

If the gate fails and attempts remain, the loop retries; when attempts are exhausted it escalates to the operator and posts its diagnosis on the issue rather than shipping a confident lie.

### 2.3 Close-to-cancel — the loop knows how to stop

Every active job registers its issue ID in `.george/state/active_remediations.json`. On each 60-second sweep the engine re-polls issue status. The moment the operator closes the issue, slaps on a `cancelled` label, or deletes the branch in the forge UI, George intercepts the signal, sends `SIGTERM` to the background worker, and prunes the worktree. No orphaned agent runs up a wall of diffs after the human has said *enough* — the cancellation rides the same cron wire the intake does.

### 2.4 Where the two nervous systems meet

This is the payoff of the shared design language. The sweep that finds the issue and the sweep that cancels it are **cron walking a directory tree** — the exact posture of `ipc_gc`. The isolated worktree is just another directory whose state lives on disk. And when the remediation agent needs to hand a long-running test to the background and keep reasoning, it reaches for the same `ipc_async`/`ipc_await` promises and the same credit-gated conduit the core loop uses. One substrate, two jobs: one moves messages, the other moves trust.

---

## 3. The shared soul — refuse the daemon

Both subsystems make the same three bets, and those bets are the architecture:

| Primitive | FIFO IPC | Remediation Loop |
| :--- | :--- | :--- |
| **Named pipe** | `data.fifo` / `ctrl.fifo` wake-up wire | (none needed — cron is the clock) |
| **Atomic rename / immutable file** | `state.json` patched under flock, spill files immutable | staged evidence, `active_remediations.json` |
| **`flock` on a persistent inode** | `state.lock`, `event_bus.lock` — never unlinked | worktree registration, job dedup |
| **The clock** | `ipc_gc` cron sweep | `lib/sys/cron.sh` 60s sweep |

The corollary is a failure model the Lodge is happy to live with: **if the machine loses power mid-turn, nothing in flight is lost**, because the queue, the credits, the backpressure flag, and the remediation registry all sit on a filesystem that outlives the process. Restart, and the world is exactly as it was. That is the whole point of building the control plane out of the one thing a bare POSIX box always has.

---

## 4. Where to read more

- [[FIFO_ASYNC_IPC_FLOWCONTROL|POSIX FIFO Async IPC Protocol]] — the normative standard: full tunables, promise invariants, and CLI reference.
- [[OPERATOR_GITEA_INTAKE|Operator Gitea Intake & Autonomic Remediation]] — intake workflow, close-to-cancel, and the verification gate in detail.
- [[EVENT_BUS_AND_OSINT_PIPELINE|Reactive Event Bus & OSINT Pipeline]] — event-driven reflexes and alerting.
- [[GITFLOW_ARCHITECTURE|Autonomic GitFlow Remediation]] — branch management and PR lifecycle.
- [[BASH_TECHNIQUES|Bash Techniques Reference]] — the FIFO, flock, process-substitution, and AWK state-machine patterns under the hood.

---

**Editorial note (provenance):** This essay is a narrative companion to the two normative docs above; where they disagree, the normative standard wins. The Gitea intake engine is implemented in `lib/agents/remediation.sh` (`remediation_gitea_intake`), fronted by `commands/gitea.sh` / `commands/remediation.sh` — the historical `commands/intake.sh` path cited in some earlier notes no longer exists.
