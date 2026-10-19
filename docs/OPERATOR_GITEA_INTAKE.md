---
title: "Operator Gitea Intake & Autonomic Remediation"
description: "Architecture and workflows for Blue Lodge Gitea issue intake, close-to-cancel lifecycle, staged evidence analysis, and automated verification gates."
subsystem: "agents"
tags:
  - gitea
  - intake
  - remediation
  - gitflow
  - autonomic
  - ci-cd
okf_id: "urn:blue-lodge:doc:operator-gitea-intake"
related:
  - "[[GITFLOW_ARCHITECTURE]]"
  - "[[CRON_AND_SCHEDULING]]"
  - "[[DOCKER_SANDBOX]]"
  - "[[MCP]]"
  - "[[ARCHITECTURE]]"
---

# Operator Gitea Intake & Autonomic Remediation

The **Operator Gitea Intake** system (`commands/intake.sh`, `lib/agents/remediation.sh`) enables George to autonomously triage, reproduce, repair, and verify bugs or feature requests filed on the local Gitea instance (`http://127.0.0.1:3001`).

```mermaid
graph TD
    Issue["Operator Files Issue / PR in Gitea (:3001)"] --> CronSweep["Autonomic Remediation Sweep (lib/sys/cron.sh)"]

    CronSweep --> Intake["Intake Engine (commands/intake.sh)"]
    Intake --> Evidence["Stage Cited .george Incident Evidence"]

    Evidence --> Worktree["Spawn Isolated Git Worktree (lib/agents/subagents.sh)"]

    Worktree --> Loop["ReAct Fix & Refactor Loop"]

    Loop --> TestGate{"Real Verification Gate (tests/run_all.sh)"}

    TestGate -->|Tests Fail| Retry{"Attempts < Max?"}
    Retry -->|Yes| Loop
    Retry -->|No| Escalate["Escalate to Operator & Post Diagnosis on Issue"]

    TestGate -->|Tests Pass (Exit 0)| OpenPR["Create Gitea Pull Request with Diff"]
    OpenPR --> Notify["Notify Operator & Close Issue"]

    OperatorCancel["Operator Closes / Cancels Issue in UI"] -.->|Close-to-Cancel Signal| CancelWorktree["Immediately Terminate Agent Task & Prune Worktree"]
```

---

## 1. Local Forge Integration

Blue Lodge can run a sovereign Gitea forge and Docker-based CI runner (`act-runner`) completely offline:
```bash
# Start local Gitea and CI runner
docker compose --profile forge up -d
```
The instance is reachable at `http://127.0.0.1:3001` with API tokens managed securely in `.george/secrets.env`.

---

## 2. The Intake Workflow (`commands/intake.sh`)

When an issue or pull request review is requested:
1. **Fetch & Parse**: `commands/intake.sh <issue_id>` retrieves issue title, markdown body, labels, and operator comments via the Gitea API.
2. **Evidence Staging**:
   - If the issue body references an incident ID (e.g., `incident_1791157134`) or crash dump, the intake engine automatically stages the corresponding files from `.george/telemetry/incidents/` into the agent's working context.
   - Eliminates manual reproduction steps by providing the agent with exact stack traces, environment flags, and failing inputs.
3. **Isolated Worktree Provisioning**:
   - George spawns a dedicated git worktree (`.worktrees/fix-issue-<id>`) on a new branch: `remediation/issue-<id>`.
   - The primary working repository is never modified directly during triage.

---

## 3. The Close-to-Cancel Protocol

To prevent runaway agent loops or unwanted background execution:
- Every active remediation job registers its Gitea issue ID in the process registry (`.george/state/active_remediations.json`).
- On every cron sweep (every 60 seconds), the intake engine polls Gitea issue statuses.
- **Immediate Cancellation**: If the operator closes an issue, applies a `cancelled` label, or deletes the branch in Gitea, George immediately intercepts the signal, terminates the background worker process (`SIGTERM`), and removes the temporary git worktree.

---

## 4. The Real Verification Gate

Naïve agents often assume an issue is fixed simply because their code edit succeeded. Blue Lodge enforces a **Real Verification Gate**:
- The agent must execute the project test harness (`bash tests/run_all.sh`) inside the isolated worktree.
- The command must exit with code `0`.
- If new unit tests were added for the bug, they must fail before the fix and pass after the fix.
- Only when this gate is cleared does George push the branch and open a Gitea Pull Request with a structured changelog.

---

## 5. CLI Operation

```bash
# Manually intake a Gitea issue
lodge /intake 42

# List all issues currently in the autonomous remediation queue
lodge /remediation queue

# Force run a remediation on a specific issue
lodge /remediation run 42

# Clear stale or aborted remediation worktrees
lodge /remediation sweep
```

---

## 6. Related Documentation
- [[GITFLOW_ARCHITECTURE|GitFlow Architecture]] — Autonomic branching and PR lifecycle.
- [[CRON_AND_SCHEDULING|Cron & Scheduling]] — Background sweep intervals and sentinel monitors.
- [[DOCKER_SANDBOX|Docker Sandbox]] — Running CI runner containers and test execution.
- [[MCP|Model Context Protocol Guide]] — Gitea MCP server tools (`mcp_server_gitea.sh`).
- [[ARCHITECTURE|Blue Lodge Architecture]] — Overall system design and specialist agent roles.
