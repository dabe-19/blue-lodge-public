# Blue Lodge Sovereign Agentic Loop Protocol (ALP v1)

**ALP v1** is the unified declarative specification, FIFO-interleaved runtime, REST API, and visual Loop Studio for multi-phase agentic workflows across both **Blue Lodge Heartwood** (including the Sovereign Research Studio) and **Lodge Guild Modules** (`mod-shop-bench`, `mod-skywatch`, `mod-hunting-buddy`, and custom modules).

---

## 1. Layered Resolution Hierarchy

Every loop is identified by `<owner>/<loop_id>` where `owner` is either `heartwood` or an installed module ID (`^[a-z0-9][a-z0-9_-]{1,48}$`).

| Owner | Packaged Source Layer (Git-tracked) | Operator Override / Custom Layer (Upgrade-safe) |
| :--- | :--- | :--- |
| `heartwood` | `data/workflows/loops/<loop_id>.loop.json` | `.george/workflows/loops/<loop_id>.loop.json` |
| `<module_id>` | `.george/modules/<module_id>/workflows/<loop_id>.loop.json` | `.george/module_data/<module_id>/workflows/<loop_id>.loop.json` |

- **Precedence**: Operator override always takes precedence over packaged source.
- **Reverting**: Deleting the override (`DELETE /api/loops/:owner/:loop_id?target=override` or clicking **Reset to Default** in the Loop Studio) restores the packaged default cleanly.
- **Authoring**: Module creators and Heartwood developers can select **Save: Module / Repo Source** (`target: "source"`) to persist changes directly into Git.

---

## 2. Standard Defaults & Turn Limits

- **`defaults.max_turns`**: Defaults to **`200`** (valid range `1..500`) across all Heartwood and Module loops, matching `AGENT_MAX_TURNS`. Arbitrary 20/28-turn caps are prohibited.
- **`defaults.ipc_priority`**: Maps directly to POSIX FIFO IPC v3 inference lease priorities (`100` Interactive, `90` Trade/Ops, `80` Research, `50` Cron, `20` Remediation).
- **`defaults.fifo_window`**: Credit window size for the loop's dedicated FIFO control/telemetry channel (`default: 16`).

---

## 3. Phase Kinds & FIFO IPC v3 Interleaving (`lib/core/loop_engine.sh`)

When `loop_engine.sh` executes a loop in `.sandboxes/<task_id>/`:

1. **Loop-Scoped FIFO Channel (`loop_<task_id>`)**: Opened via `ipc_channel_open` with deterministic `RETURN/INT/TERM` trap cleanup (`ipc_channel_close`). Emits atomic NDJSON lifecycle frames (`phase_start`, `fifo_stage_done`, `gate_pass`, `gate_retry`, `loop_complete`) and checks `ctrl.fifo` for live `ABORT` / flow control between phases.
2. **`fifo_parallel`**: Spawns every enabled tool in `phase.tasks[]` concurrently via `ipc_async` and awaits all settled results via `ipc_await_all_settled`. Large payloads spill transparently to disk and are merged into `phase_outputs/<phase_id>.json` and exposed to downstream phases via `{{phase.<phase_id>.<output_key>}}`. Use this for independent deterministic data gathering (e.g., `hunt_plan` + `hunt_weather`, `posh_tag_ocr`, `posh_brand_dossier` + `posh_comps_search`) **before** burning LLM Turn 1.
3. **`fifo_pipe`**: Runs `phase.tasks[]` sequentially via `ipc_async` + `ipc_await`, threading each stage's output into `{{prev}}`.
4. **`react`**: Renders `prompt_template` (+ optional operator `prompt_append`), exports `LODGE_ACTIVE_MODULE`, `LODGE_ACTIVE_WORKFLOW`, `LODGE_LOOP_TOOLS_ALLOW`, `LODGE_LOOP_TOOLS_DENY`, and `AGENT_IPC_PRIORITY`, and invokes `react_run` with full FIFO inference leases and per-turn parallel tool fan-out.
5. **`delegate_script`**: Bridges specialized multi-phase engines (such as Sovereign Research Studio's `research_graph.sh`) so every phase can be toggled, steered (`prompt_append`), and tuned declaratively from `deep-research.loop.json`.

### Verification Gates (`phase.gate`)
Any phase may declare a post-phase gate (`json_file`, `markdown_file`, or `research_verifier`) with `required_keys`, `min_words`, and `on_fail` (`retry`, `quarantine`, `warn`, `fail`). In `retry` mode, the engine automatically runs a targeted corrective ReAct turn with the exact missing keys/diagnostics.

---

## 4. Module Integration Contract (`module.json` + Plugin SDK)

In `module.json`:
```json
{
  "provides": {
    "tool_bundle": "+my_mod",
    "core_tools": ["vision_analyze", "web_search", "file_read", "file_write"],
    "workflows_dir": "workflows"
  }
}
```
- `lib/tools/module_audit.py` automatically validates all `workflows/*.loop.json` files during module install/audit.
- `web/src/routes/modules.rs` (`POST /api/modules/:id/task/launch`) automatically executes declarative `.loop.json` workflows through `lib/core/loop_engine.sh` (with transparent fallback to legacy `tools/workflow_prompt.sh`, also defaulting to `200` turns).
- Every mounted module panel automatically gets a **⚙ WORKFLOWS (N)** button in its top bar plus standard SDK helpers on `ctx`:
  - `ctx.listLoops()`
  - `ctx.getLoop(loopId)`
  - `ctx.saveLoop(loopId, loopDef, target)`
  - `ctx.openLoopStudio(loopId)`

---

## 5. REST API & CLI

- **REST API** (`web/src/routes/loops.rs`):
  - `GET /api/loops` — list all Heartwood + Module loops
  - `GET /api/loops/:owner` — list loops + available tools for one owner
  - `GET /api/loops/:owner/:loop_id` — resolve loop + override/source metadata
  - `POST /api/loops/:owner` — create a new custom loop
  - `PUT /api/loops/:owner/:loop_id` — validate & save loop (`target: "override" | "source"`)
  - `DELETE /api/loops/:owner/:loop_id?target=override|source` — revert override or delete custom loop
  - `POST /api/loops/:owner/:loop_id/run` — launch monitored sandbox execution (`default max_turns: 200`)
- **CLI** (`commands/workflow.sh`):
  - `/workflow loops [owner]`
  - `/workflow show-loop <owner>/<loop_id>`
  - `/workflow run-loop <owner>/<loop_id> [params_json]`
  - `/workflow validate-loop <path/to/file.loop.json>`
