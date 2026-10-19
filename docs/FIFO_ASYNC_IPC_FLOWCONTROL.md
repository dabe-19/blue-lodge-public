---
title: "POSIX FIFO Async/Await, Flow Control & Reactive Event Bus Protocol (v3)"
description: "Core architectural specification and standard for the zero-daemon POSIX FIFO async IPC engine: kernel write atomicity (PIPE_BUF), sliding-window credit flow control, keeper processes, and reactive event buses."
subsystem: "ipc"
tags:
  - ipc
  - fifo
  - flow-control
  - async-await
  - event-bus
  - standards
okf_id: "urn:blue-lodge:standard:fifo-async-ipc-flowcontrol"
related:
  - "[[INDEX]]"
  - "[[EVENT_BUS_AND_OSINT_PIPELINE]]"
  - "[[MQTT]]"
  - "[[DISCORD_BRIDGE]]"
  - "[[OKF_KNOWLEDGE_GRAPH]]"
  - "[[BASH_TECHNIQUES]]"
---

# Sovereign POSIX FIFO Async/Await, Flow Control & Reactive Event Bus Protocol (v3)

> **Classification**: Core Subsystem Architectural Specification & POSIX IPC Standard  
> **Status**: Approved, Optimized & Fully Implemented in `lib/ipc/fifo_ipc.sh`, `lib/ipc/event_bus.sh`, `lib/ipc/task_sync.sh`  
> **Standards Reference**: `urn:blue-lodge:standard:fifo-async-ipc-flowcontrol`  

---

## 1. Executive Summary & Design Principles

In high-concurrency sovereign agentic environments, multiple autonomous reasoning loops, tools, and background worker subshells interact concurrently. Traditional Unix domain sockets require persistent listener daemons or complex socket bindings, while raw non-blocking POSIX pipes lack backpressure, delivery acknowledgments, multi-producer multiplexing, and dead-process reclamation. External brokers (Redis, RabbitMQ, MQTT) introduce external failure surfaces and cannot execute during intrinsic bootstrap phases.

The **Blue Lodge Sovereign POSIX FIFO Async/Await & Flow Control Protocol (v3)** provides an ultra-resilient, zero-daemon, pure POSIX filesystem-backed agentic SDK implemented strictly in Bash (5+), GAWK, and standard Linux utilities. It establishes six primary guarantees:

1. **Kernel Write Atomicity (`PIPE_BUF`)**: Strictly bounds atomic single-line NDJSON frames written to named FIFOs to $\le 3800$ bytes (well below Linux `PIPE_BUF` of 4096 bytes). Payloads exceeding `FIFO_SPILL_BYTES` are transparently spilled to disk references (`payloads/`) and rehydrated upon delivery with zero data loss or truncation.
2. **Sliding-Window Credit Flow Control**: Strict token windowing (`CREDIT`, `PAUSE`, `RESUME`, `ABORT`, `PING`) eliminates pipe buffer overflow and memory contention. Backpressure (`PAUSE`) cannot be bypassed by timeouts or self-granting.
3. **Correlation & Routing without Stream Reordering**: Multiplexed message ingestion filtered by UUID or message type uses an ordered `mailbox/` parking mechanism, guaranteeing that selective reads never corrupt or reorder the FIFO stream.
4. **Non-Blocking Async / Await Engine**: Background worker execution with process-group isolation (`set -m`), reliable exit code capture, atomic first-writer-wins promise finalization, and whole-process-group cancellation (`SIGTERM`/`SIGKILL`).
5. **Reactive Event Bus on POSIX FIFOs**: Bounded synchronous emission with durable replay spooling (`event_spool.ndjson`), causal recursion depth bounding (`EVENT_DEPTH`), per-reactor credit channels (`rx_<id>`), overflow policies (`drop`, `coalesce`, `queue`), and zero-fork regex matching.
6. **Unified Task Sync & Multi-Node Coordination**: Transport deduplication with single-transport per hop (local FIFO preferred; cluster-wide MQTT retained broadcast fallback), correlation de-duplication on `msg_id`, and cluster-wide flow control synchronization.

---

## 2. Channel Architecture & Filesystem Layout

Each IPC channel represents a bidirectional or multi-producer, single-consumer communication conduit stored under `.george/ipc/channels/<channel_id>/`.

```
.george/ipc/channels/<channel_id>/
├── data.fifo           # Primary named pipe: single-line NDJSON data frames (< PIPE_BUF)
├── ctrl.fifo           # Out-of-band control signal pipe: PAUSE, RESUME, ABORT, PING
├── state.json          # Atomic scalar JSON state table (patched in-place under flock)
├── state.lock          # Persistent POSIX flock mutex file (never unlinked to prevent inode races)
├── queue/              # Durable spillover buffer for credit-gated frames
│   ├── 000000000001_12345.frame
│   └── 000000000002_67890.frame
└── mailbox/            # Sequence-ordered parking area for non-matching filtered frames
    └── 000000000001_54321.frame
```

### Channel State Table (`state.json`)

The state table is updated atomically using file-locking (`flock -x`) with zero-fork scalar patching (`_ipc_state_patch`):

```json
{
  "status": "OPEN",
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
  "mode": "stream",
  "created_at": 1791060000,
  "last_activity": 1791060010
}
```

- **`mode`**: `stream` (standard data channel with non-blocking keeper) or `credit` (pure token conduit for reactor concurrency gating).
- **`backpressure`**: Set to `true` on operator/pipeline `PAUSE`. Gated senders block until `RESUME` is issued.
- **`paused_by`**: Records the PID that asserted backpressure.

---

## 3. Frame Serialization & Payload Spilling

Messages traversing the conduit are encoded as atomic, single-line Newline-Delimited JSON (NDJSON) frames.

### Frame Schema

```json
{
  "seq": 1042,
  "type": "DATA",
  "channel": "session_alpha",
  "uuid": "d4e21a88-75b2-4d2c-8cb4-0a3f749a2123",
  "timestamp": 1791060050,
  "payload": {
    "tool": "research_sandbox",
    "params": { "topic": "Cardano P2P Lending" }
  }
}
```

### Automatic Payload Spilling

When the serialized payload causes the frame to exceed `FIFO_SPILL_BYTES` (3800 bytes):
1. The payload is written to an immutable disk file: `.george/ipc/payloads/<payload_id>.payload`.
2. The frame payload is replaced by a descriptor: `{"__spillover_ref__": "<path>", "bytes": <len>, "preview": "..."}`.
3. The frame length drops to $\approx 350$ bytes, guaranteeing atomic single-`write(2)` delivery without buffer fragmentation.
4. `ipc_recv` inspects `__spillover_ref__`, validates that the path is strictly within the authorized payloads directory, rehydrates the original JSON payload, and unlinks the spill file.

---

## 4. Asynchronous Promises (`ipc_async`, `ipc_await`, `ipc_cancel`)

Asynchronous background tasks run as managed promises stored in `.george/ipc/promises/<promise_id>.*`:

```
.george/ipc/promises/
├── <prom_id>.json      # Manifest: {promise_id, status, pid, pgid, exit_code, started_at, finished_at}
├── <prom_id>.out       # Captured stdout and stderr output
├── <prom_id>.lock      # Inode mutex for atomic state transitions
└── <prom_id>.rel/      # Ephemeral token directory for exactly-once credit release
```

### Promise Lifecycle & Invariants

1. **Process Group Isolation**: Each async task is launched with `set -m` in its own subshell, establishing a dedicated process group (`pgid`).
2. **First-Writer-Wins Finalization**: Once a promise enters a terminal state (`RESOLVED`, `REJECTED`, or `CANCELED`), subsequent finalization calls or late cancel signals cannot overwrite the recorded exit code or output.
3. **Clean Process Tree Cancellation**: `ipc_cancel` signals both the parent PID and the entire process group (`kill -s <sig> -- -<pgid>`), ensuring that background worker child processes (e.g., `bash`, `python`, `curl`, `sleep`) are terminated cleanly without leaving orphaned zombies.
4. **Pipelining (`ipc_pipe`)**: Output from an upstream promise is passed safely into downstream commands via the environment variable `${IPC_PIPE_INPUT}`, completely eliminating shell code injection vulnerabilities.

---

## 5. Reactive Event Bus on POSIX FIFOs

The Blue Lodge Reactive Event Bus (`lib/ipc/event_bus.sh`) executes event-driven reflexes on top of the FIFO protocol.

### Ingress & Spool Replay
- Envelopes arrive on `.george/ipc/event_bus.fifo`.
- If the event bus daemon is stopped or saturated, envelopes are synchronously appended to `.george/ipc/event_spool.ndjson`.
- Upon daemon startup, the spool is atomically rotated and replayed in order.

### Causal Depth & Circuit Breaking
- Every event carries `depth` and optional `parent_event_id`.
- Handlers emitting new events automatically inherit `EVENT_DEPTH = parent_depth + 1`.
- If `depth >= EVENT_BUS_MAX_DEPTH` (default: 3), emission is halted with a `CIRCUIT_BREAKER` notification, preventing runaway cascade loops.

### Reactor Concurrency & Overflow Policies
Each reactor registered in `.george/reactors.json` specifies:
- **`max_concurrency`**: Gated by a dedicated credit channel (`rx_<reactor_id>`).
- **`overflow`**:
  - `drop`: Discards events arriving while in debounce cooldown or at max concurrency (default).
  - `coalesce`: Retains the newest event while busy, firing once on the trailing edge.
  - `queue`: Queues events in `.george/ipc/pending/<reactor_id>/` and drains them sequentially in strict FIFO order.

---

## 6. Protocol Configuration & Tunables (`.george/ipc.conf`)

Configuration parameters are loaded as defaults from `.george/ipc.conf`. Variables already exported in the shell environment take precedence:

| Tunable | Default | Description |
| :--- | :--- | :--- |
| `FIFO_DEFAULT_WINDOW` | `5` | Initial credit token window for newly opened channels. |
| `FIFO_SPILL_BYTES` | `3800` | Byte threshold at which payloads spill to disk for `PIPE_BUF` atomicity. |
| `FIFO_MAX_PAYLOAD_BYTES` | `67108864` | Maximum allowable logical payload (64 MiB cap). |
| `FIFO_PIPE_CAPACITY` | `65536` | Linux pipe buffer capacity guard. |
| `FIFO_AUTO_RECOVER` | `0` | Auto-recovery flag (strictly 0 by default; backpressure must not be bypassed). |
| `FIFO_POLL_INTERVAL` | `0.05` | Polling sleep interval for async await and flow loops. |
| `FIFO_LOCK_TIMEOUT` | `2` | Timeout in seconds for atomic `flock` acquisition. |
| `FIFO_GC_MAX_IDLE` | `300` | Idle timeout before unused channels are reaped by garbage collection. |
| `FIFO_GC_PROMISE_TTL` | `1800` | TTL in seconds for completed promise artifacts. |
| `FIFO_GC_WEDGE_SECS` | `15` | Window before an abandoned credit-exhausted channel is unsticked by GC. |
| `FIFO_QUEUE_MAX` | `10000` | Maximum frames held in a channel's spill queue. |

---

## 7. Garbage Collection & Autonomic Supervisor (`ipc_gc`)

The garbage collection engine operates in five autonomous phases without external daemons:

1. **Channel Sweep**: Closes channels whose keepers are dead or have exceeded `max_idle_secs`. Unwedges stalled channels only when no active consumer and no operator pause exist.
2. **Keeper Process Verification**: Verifies keeper process authenticity (`/proc/$pid/cmdline`) and terminates orphaned keeper processes.
3. **Promise Reaping**: Transitions dead worker promises to `REJECTED (137)` and deletes expired promise records and sidecar artifacts (`.out`, `.lock`, `.rel`).
4. **Payload Storage Sweep**: Purges unreferenced spillover payload files older than `FIFO_GC_PROMISE_TTL`.
5. **State Lock Preservation**: Channel lock files (`state.lock`, `event_bus.lock`) are permanently preserved to prevent flock-inode reuse races.

---

## 8. CLI & Developer Command Reference

### Shell Functions (`lib/ipc/fifo_ipc.sh`)

```bash
# Channels & Flow Control
ipc_channel_open <cid> [window] [max_idle] [priority] [mode]
ipc_channel_close <cid>
ipc_channel_is_open <cid>
ipc_flow_acquire <cid> [timeout_s]
ipc_flow_grant <cid> [amount]
ipc_flow_pause <cid>
ipc_flow_resume <cid>

# Framing & Messaging
ipc_send <cid> <type> <payload_json> [uuid] [timeout_s]
ipc_recv <cid> [timeout_s] [filter_type] [filter_uuid] [auto_grant]

# Async Promises
ipc_async <cid> <command_line>
ipc_await <promise_id> [timeout_s]
ipc_await_all <timeout_s> <prom_id_1> [prom_id_2...]
ipc_cancel <promise_id> [signal]
ipc_pipe <prom_id> <cid> <command_line> [timeout_s]

# Maintenance
ipc_gc [--dry-run] [--force] [--ttl <seconds>]
```

### Slash Commands

- `/ipc list` — Show active channels, window sizes, and queue depths.
- `/ipc open <cid> [window]` — Open a new flow-controlled FIFO conduit.
- `/ipc send <cid> <payload>` — Send an atomic frame adhering to credit limits.
- `/ipc recv <cid> [timeout]` — Read next frame from conduit.
- `/ipc gc [--force]` — Execute garbage collection sweep.
- `/react status` — Inspect Reactive Event Bus throughput, inflight promises, and spool backlog.
- `/react list` — List registered reactors with debounce, overflow policy, and concurrency limits.
- `/react add <id> <type> <pattern> <action> [--debounce N] [--overflow drop|coalesce|queue] [--concurrency N]`
- `/react set <id> <field> <value>` — Live tuning of reactor parameters.
