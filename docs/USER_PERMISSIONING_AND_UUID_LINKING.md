---
title: "Sovereign User Permissioning & UUID Linking Engine Specification"
description: "Core architectural specification and standard for RFC 4122 UUID generation, capability-based RBAC, and multi-entity graph linkage."
subsystem: "core"
tags:
  - auth
  - rbac
  - uuid
  - permissions
  - security
  - standards
okf_id: "urn:blue-lodge:standard:rbac-uuid-linking"
related:
  - "[[INDEX]]"
  - "[[SECURITY_AND_SECRETS]]"
  - "[[AGENTIC_CONTAINER_SYSTEM_DESIGN]]"
  - "[[FIFO_ASYNC_IPC_FLOWCONTROL]]"
  - "[[OKF_KNOWLEDGE_GRAPH]]"
---

# Sovereign User Permissioning & UUID Linking Engine Specification

> **Classification**: Core Subsystem Architectural Specification  
> **Status**: Approved & Implemented in `lib/core/auth.sh`  
> **Standards Reference**: `urn:blue-lodge:standard:rbac-uuid-linking`  

---

## 1. Architectural Intent & Scope

As Blue Lodge evolves from a single-operator terminal utility into an autonomic, multi-agent operating system, strict boundary enforcement and traceable identity linkage become paramount. Unconstrained shell execution, unbounded tool permissions, and ambiguous process origins introduce catastrophic security and stability risks.

The **Sovereign User Permissioning & UUID Linking Engine** (`lib/auth.sh`) delivers:
1. **RFC 4122-Compliant UUIDv4 Engine**: Hardware-randomized, kernel-accelerated UUID generation with a zero-dependency POSIX AWK fallback.
2. **Granular Role-Based Access Control (RBAC)**: Hierarchical roles (`admin`, `operator`, `agent`, `guest`) mapped to explicit capability bitmasks and policy verifiers.
3. **Multi-Entity Linkage Graph**: A bidirectional, atomic filesystem-backed relational graph mapping six core agentic dimensions:
   $$\text{Session} \longleftrightarrow \text{Task} \longleftrightarrow \text{Agent} \longleftrightarrow \text{PID} \longleftrightarrow \text{IPC Channel} \longleftrightarrow \text{User}$$

This engine forms the foundational security kernel for the forthcoming **George Agentic Container System (k3s-like engine)**.

---

## 2. UUIDv4 Generation Architecture

Identity in Blue Lodge must be globally unique, collision-resistant, and instantaneous. The engine implements a tiered generation strategy in `auth_uuid_gen`:

```
┌────────────────────────────────────────────────────────┐
│                   auth_uuid_gen()                      │
└───────────────────────────┬────────────────────────────┘
                            │
              Is /proc/sys/kernel/random/uuid available?
             ┌──────────────┴──────────────┐
       [YES] │                             │ [NO]
             ▼                             ▼
   Read directly from kernel     Fallback to POSIX AWK generator
   sysctl (zero fork overhead)   (Uses /dev/urandom or awk srand)
             │                             │
             └──────────────┬──────────────┘
                            ▼
           RFC 4122 UUIDv4 String (36 chars)
           e.g. f47ac10b-58cc-4372-a567-0e02b2c3d479
```

### AWK Fallback Implementation
When operating inside unprivileged containers or minimal environments where `/proc` sysctl entries are masked, the engine invokes a single-pass `awk` script seeding from 16 random hex bytes:
- Sets version bits: `(byte[7] & 0x0f) | 0x40` (UUID Version 4).
- Sets variant bits: `(byte[9] & 0x3f) | 0x80` (Leach-Salz RFC 4122).
- Returns standard formatted string `8-4-4-4-12`.

---

## 3. RBAC Roles & Capability Matrix

The permission model departs from simple POSIX user IDs, elevating permissions into cryptographic capability tokens checked prior to tool dispatch, command execution, or IPC access.

### Role Hierarchy

```
                    ┌──────────────┐
                    │    admin     │  (Full Sovereignty, Super-Operator)
                    └──────┬───────┘
                           │ inherits
                    ┌──────▼───────┐
                    │   operator   │  (Interactive User, Human-in-the-Loop)
                    └──────┬───────┘
                           │ inherits
                    ┌──────▼───────┐
                    │    agent     │  (Autonomous ReAct Loop, Subagent)
                    └──────┬───────┘
                           │ inherits
                    ┌──────▼───────┐
                    │    guest     │  (Read-Only Observer, Public Web Viewer)
                    └──────────────┘
```

### Capability Matrix

| Capability String | Description | `admin` | `operator` | `agent` | `guest` |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **`*`** | Universal root capability bypass | **YES** | NO | NO | NO |
| **`system:admin`** | Reconfigure system, manage secrets, edit core | **YES** | NO | NO | NO |
| **`system:restart`**| Restart web daemon, inference servers, containers | **YES** | NO | NO | NO |
| **`shell:exec`** | Unrestricted host shell command execution | **YES** | **YES** | NO | NO |
| **`workspace:write`**| Modify, delete, or create workspace files | **YES** | **YES** | **YES** | NO |
| **`workspace:read`** | Inspect files, directories, git history | **YES** | **YES** | **YES** | **YES** |
| **`tools:exec`** | Dispatch ReAct sandbox tools (ripgrep, ast_grep) | **YES** | **YES** | **YES** | NO |
| **`agent:spawn`** | Spawn autonomic subagents or background tasks | **YES** | **YES** | **YES** | NO |
| **`agent:kill`** | Terminate running tasks or cull sandboxes | **YES** | **YES** | NO | NO |
| **`ipc:admin`** | Create/delete IPC channels, flush queues, run GC | **YES** | **YES** | NO | NO |
| **`ipc:send`** | Publish frames to authorized channel | **YES** | **YES** | **YES** | NO |
| **`ipc:recv`** | Subscribe/read frames from channel | **YES** | **YES** | **YES** | NO |
| **`telemetry:read`** | View task transcripts, vitals, logs, metrics | **YES** | **YES** | **YES** | **YES** |

### Policy Enforcement Gate (`auth_check_perm`)

Prior to running any tool or dispatching a command from the web UI, ReAct engine, or IPC conduit, the runtime invokes:
```bash
if ! auth_check_perm "$user_or_token" "shell:exec"; then
    echo "ERROR: Permission denied for capability 'shell:exec'" >&2
    return 13
fi
```
The check uses single-pass `awk` resolution against `.george/auth/users/<user_id>.json` or `.george/auth/tokens/<token>.json`.

---

## 4. Multi-Entity UUID Linkage Graph

To ensure complete accountability, auditing, and clean garbage collection, every operation in the system is tied into a 6-node relational linkage graph stored under `.george/auth/links/<session_id>.json`.

### Linkage Data Schema

```json
{
  "uuid": "8a3e721a-6df4-4c8d-b941-5dfc1e0f39bc",
  "session_id": "sess-91a03d",
  "task_id": "task-6627",
  "agent_id": "agent-george-core",
  "pid": 2135843,
  "channel_id": "chan-react-repl",
  "user_id": "usr-admin-01",
  "created_at": 1790651800,
  "updated_at": 1790651800,
  "status": "ACTIVE"
}
```

### Relational Navigation Operations

The linkage graph supports $O(1)$ lookups via bidirectional indexing:

1. **`auth_link_register`**: Atomically creates the linkage record and updates secondary indices:
   - `.george/auth/indices/by_pid/<pid> -> <session_id>`
   - `.george/auth/indices/by_task/<task_id> -> <session_id>`
   - `.george/auth/indices/by_channel/<channel_id> -> <session_id>`
2. **`auth_link_get <session_id>`**: Returns the full JSON linkage record.
3. **`auth_link_lookup <dimension> <value>`**: Resolves any dimension (e.g. `pid 2135843` or `task task-6627`) directly to its parent linkage object.
4. **`auth_link_unlink <session_id>`**: Cleans the record and all associated secondary indices upon task completion or GC sweep.

---

## 5. Security & Isolation Invariants

1. **Token Invalidation on Termination**: When an agent task finishes or is culled, its temporary session token and capability delegation are revoked automatically.
2. **Dangling Process Prevention**: When a task is culled, the linkage graph provides the exact `pid` and `channel_id` required for total resource reclamation.
3. **Tamper Resistance**: Auth metadata directories (`.george/auth/`) are enforced with filesystem permissions `0700` restricted exclusively to the sovereign host owner.
