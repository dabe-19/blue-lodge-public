---
title: "Sovereign Agentic Container System Architecture Specification"
description: "Architectural blueprint for george-k3a: an agent-native container fabric built on Linux namespaces, cgroups v2, OverlayFS, and POSIX FIFO flow control."
subsystem: "sys"
tags:
  - container-architecture
  - namespaces
  - cgroups-v2
  - overlayfs
  - fifo-ipc
  - subagents
okf_id: "urn:blue-lodge:doc:agentic-container-system-design"
related:
  - "[[INDEX]]"
  - "[[DOCKER_SANDBOX]]"
  - "[[SANDBOXES]]"
  - "[[FIFO_ASYNC_IPC_FLOWCONTROL]]"
  - "[[USER_PERMISSIONING_AND_UUID_LINKING]]"
---

# Sovereign Agentic Container System Architecture Specification

> **Classification**: Next-Generation Architecture Specification  
> **Target Subsystem**: `george-k3a` (Autonomous Agentic Container Fabric)  
> **Status**: Design Blueprint & Core Integration Roadmap  

---

## 1. Executive System Vision

Modern container orchestrators like Kubernetes and k3s were designed to orchestrate stateless, long-running web microservices. They are ill-fitted for autonomous AI agents, which require:
- Ephemeral, sub-second spin-up and tear-down latencies.
- High-bandwidth, zero-copy inter-process communication for tool chaining and reasoning pipelines.
- Tight hardware coupling with local GPU inference runtimes (CUDA PRISM, llama-server).
- Native comprehension of cognitive states (Planning, ReAct Loops, Reflection, Halting, Culling).
- Built-in sovereignty: zero cloud controller dependencies, single-node resilience, and deterministic resource isolation.

The **Sovereign Agentic Container System (`george-k3a`)** is an ultra-lightweight, agent-native container fabric built from the ground up on Linux primitives (namespaces, cgroups v2, OverlayFS, POSIX named pipes) with **George embedded directly as POSIX-compliant Bash code**.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              OPERATOR & WEB COCKPIT (Port 3000)                        │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ HTTP / REST / WebSocket
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                         CONTROL PLANE: agentd (POSIX Bash & AWK)                        │
│   • Declarative Manifest Engine (.yaml / .json)    • Pod Lifecycle State Machine       │
│   • Sovereign Identity & RBAC (lib/auth.sh)        • Autonomic Reconciliation Loop     │
│   • Credit Flowcontrol Fabric (lib/fifo_ipc.sh)    • High-Speed AWK Garbage Collector  │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Namespace & Cgroup Dispatch
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              AGENT POD RUNTIME CLUSTER                                 │
│                                                                                        │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │  AGENT POD: "pod-architect-9" (Linux Namespaces: PID, MNT, NET, IPC, UTS)      │   │
│   │                                                                                │   │
│   │   ┌────────────────────────┐  ┌───────────────────────┐  ┌──────────────────┐  │   │
│   │   │  Primary Agent Loop    │  │  FIFO-IPC Sidecar     │  │ Tool Sandbox     │  │   │
│   │   │  (George ReAct Core)   │  │  (rx.fifo / tx.fifo)  │  │ (bwrap / chroot) │  │   │
│   │   │  POSIX Bash + AWK      │  │  Credit Flow Control  │  │ ast_grep, rg, git│  │   │
│   │   └───────────┬────────────┘  └───────────┬───────────┘  └────────┬─────────┘  │   │
│   │               │                           │                       │            │   │
│   │               └───────────────────────────┼───────────────────────┘            │   │
│   │                                           │                                    │   │
│   │   ┌───────────────────────────────────────┴────────────────────────────────┐   │   │
│   │   │ Rootfs Overlay: / (RO Core: lib, commands) + /scratch (RW Ephemeral)    │   │   │
│   │   │ Cgroup v2 Limits: CPU: 200%, Mem: 2048MB, PIDs: 64, OOM Guard Enabled  │   │   │
│   │   └────────────────────────────────────────────────────────────────────────┘   │   │
│   └────────────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Agent Pod Architecture & Topology

An **Agent Pod** is the atomic schedulable unit in `george-k3a`. Unlike a Kubernetes pod which wraps multiple OCI container images via dockerd or containerd, an Agent Pod is constructed directly via the Linux `unshare` and `pivot_root` syscalls, launching in $< 20\text{ms}$.

### Pod Directory & Filesystem Layout

```
.george/pods/<pod_uuid>/
├── manifest.json       # Declarative spec (role, capabilities, resources, image)
├── status.json         # Live phase: PENDING, RUNNING, REASONING, HALTED, CULLED
├── cgroup/             # Cgroup v2 slice (/sys/fs/cgroup/george/<pod_uuid>/)
│   ├── cpu.max         # Throttling limit (e.g. "200000 100000" = 2 CPU cores)
│   ├── memory.max      # Memory ceiling (e.g. "2147483648" = 2GB)
│   └── pids.max        # Process fork guard (e.g. "64")
├── rootfs/             # OverlayFS merged mountpoint
│   ├── lower/          # Read-only base runtime (BusyBox/Alpine + Bash + core tools)
│   ├── upper/          # Copy-On-Write ephemeral workspace layer
│   └── work/           # OverlayFS workdir
├── ipc/                # Bound directly to .george/ipc/channels/<channel_id>/
│   ├── rx.fifo         # Inbound command stream from agentd orchestrator
│   └── tx.fifo         # Outbound trajectory and tool telemetry
└── auth/
    ├── token.jwt       # Delegated capability token issued by lib/auth.sh
    └── linkage.json    # UUID link: session_id <-> pod_uuid <-> pid <-> user
```

---

## 3. The Embedded George POSIX Bash Core

The runtime inside the container is not a heavy Python or Node.js environment; it is **George embedded as POSIX-compliant Bash**.

### Design Principles:
1. **Zero Runtime Overhead**: Starts immediately without V8 engine startup time or Python interpreter warmups (~2ms vs ~350ms).
2. **Deterministic Execution**: Pure standard Unix stream semantics: stdin, stdout, stderr, and named pipe signals.
3. **Intrinsic Tool Ergonomics**: Operating systems and command-line developer utilities (`git`, `awk`, `grep`, `sed`, `patch`, `curl`) are first-class language constructs in Bash.
4. **AWK Data Plane Acceleration**: All JSON manipulation, frame parsing, and metric aggregation use single-pass AWK scripts, keeping process forks to an absolute minimum.

---

## 4. Declarative Manifest Specification

Pods are declared via JSON/YAML manifests processed by `agentd`.

```json
{
  "apiVersion": "george.sovereign/v1alpha1",
  "kind": "AgentPod",
  "metadata": {
    "name": "phytology-sentinel",
    "uuid": "4c3b9e1a-821f-4b47-9dc5-d142857091aa",
    "owner": "usr-admin-01"
  },
  "spec": {
    "role": "agent",
    "capabilities": [
      "workspace:read",
      "workspace:write",
      "tools:exec",
      "ipc:send",
      "ipc:recv"
    ],
    "resources": {
      "limits": {
        "cpu": "2.0",
        "memory": "2048Mi",
        "pids": 64
      },
      "gpu": {
        "access": false
      }
    },
    "ipc": {
      "channel": "chan-sentinel-01",
      "window_size": 16,
      "flow_control": "sliding_window"
    },
    "lifecycle": {
      "auto_cull_on_complete": true,
      "max_runtime_secs": 1800,
      "keep_transcripts_days": 7
    }
  }
}
```

---

## 5. Control Plane & Autonomic Reconciliation Loop (`agentd`)

The orchestrator daemon `agentd` executes a continuous reconciliation loop every 500ms:

$$\text{Reconciliation}(\text{Target State}, \text{Current State}) \longrightarrow \text{State Transition Actions}$$

```
                ┌──────────────────────────────────────────────┐
                │          agentd Reconciliation Loop          │
                └──────────────────────┬───────────────────────┘
                                       │
                      ┌────────────────┴────────────────┐
                      ▼                                 ▼
             [ Desired State ]                   [ Live State ]
          Read all manifests in              Scan .george/pods/*/
          .george/manifests/*.json           Inspect /proc, cgroups, FIFOs
                      │                                 │
                      └────────────────┬────────────────┘
                                       │
                         Reconciliation Diff Engine
                                       │
         ┌─────────────────────────────┼─────────────────────────────┐
         ▼                             ▼                             ▼
    [ Missing Pod ]             [ Divergent State ]           [ Dead / Stale Pod ]
• Invoke unshare & cgroup     • Adjust cgroup memory/CPU    • Trigger ipc_gc sweep
• Mount OverlayFS rootfs      • Flush wedged FIFO queues    • Revoke auth token
• Generate UUID via auth.sh   • Restart crashed keeper      • Unlink graph & archive
• Exec embedded George        • Send RESUME credit frame    • Clean cgroup directory
```

---

## 6. Integration with Subsystems

1. **FIFO-IPC Protocol (`lib/fifo_ipc.sh`)**:
   - Each Pod's stdin/stdout is tied to an IPC channel.
   - The orchestrator throttles pod transmission via credit grants.
   - If a pod attempts an unbounded recursive fork bomb or buffer overflow, the sliding window halts transmission before memory exhaustion occurs.

2. **User Permissioning & Linkage Engine (`lib/auth.sh`)**:
   - Pod creation requires a valid session token.
   - The pod is registered in `.george/auth/links/<session_id>.json`, linking operator, pod UUID, container PID, IPC channel, and task ID.
   - Unauthorized attempts by an `agent` pod to execute `shell:exec` (host-level root shell) are rejected at the capability gate.

3. **Garbage Collection (`ipc_gc`)**:
   - Stale pods (dead PID, completed phase, or expired TTL) are automatically culled.
   - Orphaned named pipes and dangling lock directories are reclaimed in $< 15\text{ms}$ via single-pass AWK.

---

## 7. Implementation Roadmap

| Milestone | Target Component | Description |
| :--- | :--- | :--- |
| **Phase 1** (Complete) | `lib/fifo_ipc.sh` | Flow-controlled asynchronous FIFO channels and AWK GC engine. |
| **Phase 2** (Complete) | `lib/auth.sh` | RFC 4122 UUIDv4 generator, RBAC capability matrix, and linkage graph. |
| **Phase 3** (Next) | `lib/pod.sh` | Lightweight Linux namespace (`unshare`) and cgroups v2 pod isolation wrapper. |
| **Phase 4** | `bin/agentd` | Autonomic reconciliation loop daemon with manifest watcher. |
| **Phase 5** | Web Dashboard | Native Pod telemetry, memory/CPU graphs, and live shell streaming in Craftsman UI. |
