#!/bin/bash
# ── Test Suite: Priorities 1-3 (Telemetry, OKF PPR Graph, MoA Router & Milestone Gates) ──

source "$(dirname "$0")/framework.sh"
LODGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$LODGE_DIR/lib/memory/recall.sh"
source "$LODGE_DIR/lib/memory/memory.sh"
source "$LODGE_DIR/lib/knowledge/okf.sh"
source "$LODGE_DIR/lib/tools/native_tools.sh"
source "$LODGE_DIR/lib/agents/workflows.sh"
source "$LODGE_DIR/lib/agents/subagents.sh"
source "$LODGE_DIR/lib/core/react_evaluator.sh"

test_start "Priorities 1-3: Telemetry Plane, OKF PPR Graph, Capability Router & Structural Gates"

describe "Priority 1: Research Housekeeping, Telemetry Wiring & Unified Lookup"
  it "preserves canonical research dossiers and supports /research prune --dry-run" && {
    out=$(bash "$LODGE_DIR/commands/research.sh" prune --dry-run 2>&1)
    assert_ok $?
    assert_contains "$out" "[DRY RUN]"
    assert_contains "$out" "canonical dossier.md"
  }

  it "records allowlisted trace, terminal outcome, evaluator snapshot, grammar compat, and tool stats in isolated recall.db" && {
    tmp_dir=$(mktemp -d /tmp/test_p1_recall_XXXXXX)
    export GEORGE_DIR="$tmp_dir"
    export RECALL_DB="$tmp_dir/recall.db"
    recall_init
    assert_file_exists "$RECALL_DB"

    recall_trace_record_allowlisted "task_test_1" '{"infeasibility_class":"none","evaluator_mode":"normal","task_outcome_class":"successful","redacted_diagnostic":"unit_test"}' >/dev/null
    assert_ok $?
    recall_record_terminal_outcome "task_test_1" "successful" "done"
    assert_ok $?
    recall_record_evaluator_snapshot "task_test_1" '{"evaluator_mode":"normal","backend":"local_inference","scenario":"step_1","token_budget":300,"output_length":64,"diagnostic_code":"COMPLETE"}' >/dev/null
    assert_ok $?
    recall_schema_compat_set "react_eval_gbnf" "compatible" 0 1 5 "COMPLETE" "tested"
    assert_ok $?
    recall_record_tool_stat "web_search" 420 0 0 ""
    assert_ok $?

    c_trace=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM routing_eval_trace;")
    c_term=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM task_terminal_outcomes;")
    c_snap=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM evaluator_diag_snapshots;")
    c_gram=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM grammar_schema_compatibility;")
    c_tool=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM tool_telemetry_stats WHERE tool_name='web_search';")

    assert_eq "$c_trace" "1"
    assert_eq "$c_term" "1"
    assert_eq "$c_snap" "1"
    assert_eq "$c_gram" "1"
    assert_eq "$c_tool" "1"

    rm -rf "$tmp_dir"
    export GEORGE_DIR="$LODGE_DIR/.george"
    export RECALL_DB="$GEORGE_DIR/recall.db"
    mkdir -p "$GEORGE_DIR"
    recall_init
    _hermetic_edges=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM okf_edges;" 2>/dev/null || echo 0)
    if [ "${_hermetic_edges:-0}" -lt 1000 ]; then
      GEORGE_DIR="$GEORGE_DIR" RECALL_DB="$RECALL_DB" python3 "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" --index >/dev/null 2>&1
    fi
    _hermetic_tstats=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM tool_telemetry_stats;" 2>/dev/null || echo 0)
    if [ "${_hermetic_tstats:-0}" -eq 0 ]; then
      recall_record_tool_stat "web_search" 250 0 0 "" >/dev/null 2>&1
    fi
    _hermetic_traces=$(sqlite3 "$RECALL_DB" "SELECT COUNT(*) FROM routing_eval_trace;" 2>/dev/null || echo 0)
    if [ "${_hermetic_traces:-0}" -eq 0 ]; then
      recall_trace_record_allowlisted "hermetic_seed" '{"infeasibility_class":"none","evaluator_mode":"normal","task_outcome_class":"successful","redacted_diagnostic":"seed"}' >/dev/null 2>&1
    fi
  }

  it "runs unified telemetry_query.py summary and cross-DB search" && {
    sum_json=$(python3 "$LODGE_DIR/lib/tools/telemetry_query.py" summary --json)
    assert_ok $?
    echo "$sum_json" | jq -e '.stores["recall.db"].tables.tool_telemetry_stats > 0' >/dev/null
    assert_ok $?
    echo "$sum_json" | jq -e '.stores["recall.db"].tables.routing_eval_trace > 0' >/dev/null
    assert_ok $?

    s_json=$(python3 "$LODGE_DIR/lib/tools/telemetry_query.py" search "fifo" --json)
    assert_ok $?
    echo "$s_json" | jq -e '(.okf_modules | length) > 0' >/dev/null
    assert_ok $?
  }

describe "Priority 2: OKF Directed Edges, PPR Traversal & Capability Graph Router"
  it "populates okf_edges and linked dependsOn objects in blue_lodge_graph.jsonld" && {
    stats_json=$(python3 "$LODGE_DIR/lib/tools/okf_sqlite_indexer.py" --stats --json)
    assert_ok $?
    edges=$(echo "$stats_json" | jq '.total_edges // 0')
    [ "$edges" -gt 1000 ]
    assert_ok $?

    linked_cnt=$(jq '[.["@graph"][] | select(.dependsOn != null and (.dependsOn | length) > 0)] | length' "$LODGE_DIR/okf/blue_lodge_graph.jsonld")
    [ "$linked_cnt" -gt 50 ]
    assert_ok $?
  }

  it "executes multi-hop Personalized PageRank traversal via okf_traverse" && {
    trav_json=$(okf_traverse "lib/core/react.sh" --hops 2 --json)
    assert_ok $?
    echo "$trav_json" | jq -e '.seed_uri == "urn:blue-lodge:module:lib/core/react.sh"' >/dev/null
    assert_ok $?
    echo "$trav_json" | jq -e '(.neighbors | length) >= 5' >/dev/null
    assert_ok $?
    echo "$trav_json" | jq -e '.neighbors[0].ppr_score > 0' >/dev/null
    assert_ok $?
  }

  it "routes tasks to profiles, tools, and workflows via capability_graph_router.py" && {
    # Synonym + OKF graph profile classification for terms not in basic regex
    prof=$(native_tools_classify_profile "Analyze minswap pool liquidity and lovelace slippage")
    assert_eq "$prof" "crypto"

    # MoA Contextual Bandit + Latency Penalty tool ranking
    rank_json=$(native_tools_graph_rank "send notification to discord channel" 2500)
    assert_ok $?
    echo "$rank_json" | jq -e '.best_bundle == "+social"' >/dev/null
    assert_ok $?
    echo "$rank_json" | jq -e '.candidates[0].utility > 0' >/dev/null
    assert_ok $?

    # Workflow selection via OKF capability graph
    wf_core=$(workflows_select_best "Modify lib/core/react.sh and lib/core/agent_sm.sh")
    assert_contains "$wf_core" "core-specialist.agent.md"

    wf_sec=$(workflows_select_best "Perform security audit on RBAC and PGP auth")
    assert_contains "$wf_sec" "the-tyler.agent.md"
  }

describe "Priority 3: Deterministic Milestone Pre/Post-Condition Gates, Flock & Schema Parity"
  it "enforces required_files, required_tools, and verify_cmd in react_eval_check_gates" && {
    tmp_sdir=$(mktemp -d /tmp/test_gates_XXXXXX)
    cat > "$tmp_sdir/honeydew.json" << 'EOF'
{
  "task_type": "ops",
  "items": [
    {
      "id": 1,
      "task": "Generate digest and validate via digest_check.sh validate then send via discord_send",
      "status": "pending",
      "required_files": ["digest.md"],
      "required_tools": ["discord_send"],
      "verify_cmd": "grep -q 'VALIDATED_OK' digest.md"
    }
  ]
}
EOF
    # Gate 1: missing required file digest.md
    g1=$(react_eval_check_gates "$tmp_sdir" 1 "Step 1")
    assert_fail $?
    assert_contains "$g1" "required file 'digest.md' is missing"

    # Create file without VALIDATED_OK and without discord_send tool call
    echo "draft content" > "$tmp_sdir/digest.md"
    g2=$(react_eval_check_gates "$tmp_sdir" 1 "Step 1")
    assert_fail $?
    assert_contains "$g2" "required tool 'discord_send' has not been invoked"

    # Record discord_send in messages.json, now verify_cmd should be checked
    echo '[{"role":"tool","name":"discord_send","content":"sent"}]' > "$tmp_sdir/messages.json"
    g3=$(react_eval_check_gates "$tmp_sdir" 1 "Step 1")
    assert_fail $?
    assert_contains "$g3" "verification command failed"

    # Satisfy verify_cmd
    echo "VALIDATED_OK" >> "$tmp_sdir/digest.md"
    g4=$(react_eval_check_gates "$tmp_sdir" 1 "Step 1")
    assert_ok $?

    rm -rf "$tmp_sdir"
  }

  it "serializes subagent registry updates cleanly with _subagents_atomic_jq" && {
    tmp_reg_dir=$(mktemp -d /tmp/test_subreg_XXXXXX)
    export GEORGE_DIR="$tmp_reg_dir"
    export SUBAGENTS_REGISTRY="$tmp_reg_dir/subagents.json"
    subagents_init
    subagents_register "sub_1" "12345" "$$" "1" "test-model" "Test obj" "br-1" "$tmp_reg_dir" "10"
    subagents_update_status "sub_1" "COMPLETED" "3" "Done"
    st=$(jq -r '.[0].status' "$SUBAGENTS_REGISTRY")
    assert_eq "$st" "COMPLETED"
    rm -rf "$tmp_reg_dir"
    export GEORGE_DIR="$LODGE_DIR/.george"
    export SUBAGENTS_REGISTRY="$GEORGE_DIR/subagents.json"
  }

  it "verifies every workflow in .agents/workflows parses valid metadata JSON" && {
    wf_dir=$(workflows_dir "$LODGE_DIR")
    invalid_wf=0
    for wf in "$wf_dir"/*.agent.md; do
      [ -f "$wf" ] || continue
      meta=$(workflows_parse_meta "$wf")
      if ! echo "$meta" | jq -e '.name != "" and .description != ""' >/dev/null 2>&1; then
        echo "Invalid metadata for $wf: $meta"
        invalid_wf=$((invalid_wf + 1))
      fi
    done
    assert_eq "$invalid_wf" "0"
  }

  it "verifies schema-to-dispatch parity for all native tools in native_tools.sh" && {
    missing_dispatch=$(python3 - "$LODGE_DIR/lib/tools/native_tools.sh" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()

# Extract schema names defined in native_tools_get_all_schemas
schema_section = txt.split("native_tools_dispatch()", 1)[0]
schema_names = set(re.findall(r'"name":\s*"([a-zA-Z0-9_]+)"', schema_section))

dispatch_section = txt.split("native_tools_dispatch()", 1)[1]
missing = []
for name in sorted(schema_names):
    if name not in dispatch_section:
        missing.append(name)

print(",".join(missing))
PYEOF
)
    assert_empty "$missing_dispatch"
  }

describe "Phase 2 Roadmap: Modular Dispatch, Prefix-Hash Compaction, DAG Readiness & Web Routes"
  it "loads modular domain dispatchers (lib/tools/dispatch/crypto.sh and git_code.sh)" && {
    assert_file_exists "$LODGE_DIR/lib/tools/dispatch/crypto.sh"
    assert_file_exists "$LODGE_DIR/lib/tools/dispatch/git_code.sh"
    declare -f _native_dispatch_crypto >/dev/null
    assert_ok $?
    declare -f _native_dispatch_git_code >/dev/null
    assert_ok $?
  }

  it "deduplicates long instructions via SHA-256 prefix-hash compaction and losslessly hydrates" && {
    tmp_cdir=$(mktemp -d /tmp/test_prefix_compact_XXXXXX)
    mkdir -p "$tmp_cdir/transcripts"
    long_inst=$(python3 -c 'print("SYSTEM MANDATE: " + "alpha beta gamma delta " * 30)')
    python3 - "$tmp_cdir/transcripts/trajectories.jsonl" "$long_inst" << 'PYEOF'
import json, sys
p, inst = sys.argv[1], sys.argv[2]
with open(p, "w", encoding="utf-8") as f:
    for i in range(5):
        f.write(json.dumps({"timestamp": f"2026-10-31T00:00:0{i}Z", "instruction": inst, "thinking": "t", "action": "a", "observation": "o"}) + "\n")
PYEOF
    comp_res=$(python3 - "$LODGE_DIR/lib/tools/telemetry_query.py" "$tmp_cdir" "$long_inst" << 'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("tq", sys.argv[1])
tq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tq)
gdir, orig_inst = sys.argv[2], sys.argv[3]
stats = tq.compact_trajectories(george_dir=gdir, dry_run=False)
assert stats["compacted_records"] == 5, f"Expected 5, got {stats}"
assert stats["unique_prefixes"] == 1, f"Expected 1 prefix, got {stats}"
assert stats["reclaimed_bytes"] > 1000, f"Expected >1000 bytes reclaimed, got {stats}"
prefixes = {}
with open(f"{gdir}/transcripts/prompt_prefixes.jsonl", "r", encoding="utf-8") as pf:
    for line in pf:
        obj = json.loads(line)
        prefixes[obj["ref"]] = obj["instruction"]
with open(f"{gdir}/transcripts/trajectories.jsonl", "r", encoding="utf-8") as tf:
    first_rec = json.loads(tf.readline())
hydrated = tq.hydrate_trajectory_record(first_rec, prefixes)
assert hydrated["instruction"] == orig_inst, "Hydrated instruction mismatch"
print("PREFIX_COMPACT_OK")
PYEOF
)
    assert_contains "$comp_res" "PREFIX_COMPACT_OK"
    rm -rf "$tmp_cdir"
  }

  it "breaks DAG cycles, computes dag_depth, and identifies parallel ready waves in honeydew_strategist.py" && {
    tmp_dag=$(mktemp -d /tmp/test_dag_XXXXXX)
    cat > "$tmp_dag/honeydew.json" << 'EOF'
{
  "task_type": "code",
  "items": [
    {"id": 1, "task": "Inspect core schema", "status": "done", "depends_on": [3]},
    {"id": 2, "task": "Update lib/core/react.sh", "status": "pending", "depends_on": [1]},
    {"id": 3, "task": "Update commands/okf.sh", "status": "pending", "depends_on": [1]},
    {"id": 4, "task": "Run integration tests", "status": "pending", "depends_on": [2, 3]}
  ]
}
EOF
    ready_out=$(python3 "$LODGE_DIR/lib/tools/honeydew_strategist.py" --ready "$tmp_dag/honeydew.json")
    assert_ok $?
    echo "$ready_out" | jq -e '.is_parallel_wave == true' >/dev/null
    assert_ok $?
    echo "$ready_out" | jq -e '(.ready_ids | sort) == [2, 3]' >/dev/null
    assert_ok $?
    echo "$ready_out" | jq -e '.blocked_ids == [4]' >/dev/null
    assert_ok $?
    rm -rf "$tmp_dag"
  }

  it "registers /api/okf/traverse and /api/okf/telemetry in Rust Web UI router" && {
    grep -q '/api/okf/traverse' "$LODGE_DIR/web/src/routes/mod.rs"
    assert_ok $?
    grep -q '/api/okf/telemetry' "$LODGE_DIR/web/src/routes/mod.rs"
    assert_ok $?
    grep -q 'pub async fn traverse_okf_graph' "$LODGE_DIR/web/src/routes/okf.rs"
    assert_ok $?
    grep -q 'pub async fn get_okf_telemetry' "$LODGE_DIR/web/src/routes/okf.rs"
    assert_ok $?
  }

describe "Phase 3: Comms Tool Gating, FIFO Waiter Queue, PRISM Kernels & Training Forge"
  it "gates unconfigured telegram_send out of +social during Discord sessions and redirects safely" && {
    export _DISCORD_IN_SESSION=1
    soc_bundle=$(native_tools_bundle_tools "+social")
    echo "$soc_bundle" | grep -q "telegram_send"
    assert_fail $?
    echo "$soc_bundle" | grep -q "discord_send"
    assert_ok $?

    tg_resp=$(native_tools_dispatch "call_tg_1" "telegram_send" '{"message":"test"}' "$PWD")
    assert_ok $?
    echo "$tg_resp" | jq -r '.content' | grep -q "NOTICE: Telegram is not configured or you are in an active Discord session"
    assert_ok $?
    unset _DISCORD_IN_SESSION
  }

  it "pins sensitive objectives to Tier 1 (27B) and manages FIFO priority waiter queue cleanly" && {
    unset OBJECTIVE_SUBAGENTS OBJECTIVE_PHYTOLOGY OBJECTIVE_INTERACTIVE
    source "$LODGE_DIR/lib/core/endpoints.sh"
    endpoints_init
    assert_eq "$OBJECTIVE_SUBAGENTS" "1,3"
    assert_eq "$OBJECTIVE_PHYTOLOGY" "1,3"

    tmp_ipc=$(mktemp -d /tmp/test_fifo_waiters_XXXXXX)
    export FIFO_IPC_DIR="$tmp_ipc"
    source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
    ipc_acquire_inference_lease 100 "test_interactive_turn" 5
    assert_ok $?
    assert_file_exists "$tmp_ipc/inference_slots/slot_0/lease.json"
    holder_pid=$(jq -r '.holder_pid' "$tmp_ipc/inference_slots/slot_0/lease.json")
    assert_eq "$holder_pid" "${BASHPID:-$$}"
    kill -0 "$holder_pid" 2>/dev/null
    assert_ok $?
    ipc_release_inference_lease "test_interactive_turn"
    assert_ok $?
    rm -rf "$tmp_ipc"
    export FIFO_IPC_DIR="$LODGE_DIR/.george/ipc"
  }

  it "configures display-safe CUDA MMQ & KV cache-reuse flags in start_inference.sh" && {
    grep -q 'GGML_CUDA_BATCH_INVARIANT' "$LODGE_DIR/scripts/infra/start_inference.sh"
    assert_ok $?
    grep -q 'MTMD_BACKEND_DEVICE="CUDA0"' "$LODGE_DIR/scripts/infra/start_inference.sh"
    assert_ok $?
    grep -q -- '--no-cache-idle-slots' "$LODGE_DIR/scripts/infra/start_inference.sh"
    assert_fail $?
  }

  it "hydrates prefix-compacted instructions in export_lora_dataset.py and plans GGUF LoRA baking in runs.py" && {
    tmp_fdir=$(mktemp -d /tmp/test_forge_p3_XXXXXX)
    mkdir -p "$tmp_fdir/transcripts"
    cat > "$tmp_fdir/transcripts/prompt_prefixes.jsonl" << 'EOF'
{"ref":"sha256:0123456789abcdef","instruction":"Full hydrated instruction for fine-tuning verification."}
EOF
    cat > "$tmp_fdir/transcripts/trajectories.jsonl" << 'EOF'
{"timestamp":"2026-10-31T08:00:00Z","instruction":"[PREFIX_REF:sha256:0123456789abcdef] Short...","instruction_ref":"sha256:0123456789abcdef","thinking":"plan","action":"file_read({\"path\":\"README.md\"})","observation":"ok"}
EOF
    python3 "$LODGE_DIR/scripts/training/export_lora_dataset.py" --george-dir "$tmp_fdir" --out "$tmp_fdir/out" >/dev/null
    assert_ok $?
    grep -q "Full hydrated instruction for fine-tuning verification." "$tmp_fdir/out/steps.jsonl"
    assert_ok $?

    # Test runs.py bake --dry-run
    touch "$tmp_fdir/base.gguf" "$tmp_fdir/adapter.gguf"
    bake_out=$(python3 "$LODGE_DIR/scripts/training/runs.py" bake "$tmp_fdir/adapter.gguf" --base "$tmp_fdir/base.gguf" --dry-run)
    assert_ok $?
    echo "$bake_out" | jq -e '.status == "planned" and (.output_gguf | endswith("-Merged.gguf"))' >/dev/null
    assert_ok $?
    rm -rf "$tmp_fdir"
  }

  it "defines cron_is_running and spares re-parented Discord/cron tasks in cron_sweep_stale_daemons" && {
    unset _LIB_CRON_LOADED
    source "$LODGE_DIR/lib/sys/cron.sh"
    declare -f cron_is_running >/dev/null
    assert_ok $?
    declare -f _cron_pid_is_protected_task >/dev/null
    assert_ok $?
    grep -q 'george-discord-session' "$LODGE_DIR/lib/comms/discord_bridge.sh"
    assert_ok $?
  }

  it "wires okf_traverse, okf_query, and okf_search into remediation, worker, pr_reviewer, and code profiles" && {
    unset _LIB_NATIVE_TOOLS_LOADED _LIB_CONTEXT_ENGINE_LOADED
    source "$LODGE_DIR/lib/tools/native_tools.sh"
    source "$LODGE_DIR/lib/core/context_engine.sh"

    for prof in remediation worker pr_reviewer code; do
      prof_schemas=$(native_tools_resolve_profile "$prof")
      echo "$prof_schemas" | jq -e 'any(.[]; .function.name == "okf_traverse") and any(.[]; .function.name == "okf_query") and any(.[]; .function.name == "okf_search")' >/dev/null
      assert_ok $?
    done

    # Remediation profile must exclude social broadcast tools
    rem_schemas=$(native_tools_resolve_profile "remediation")
    echo "$rem_schemas" | jq -e 'any(.[]; .function.name == "discord_send" or .function.name == "telegram_send" or .function.name == "social_post")' >/dev/null
    assert_fail $?

    # Dispatch okf_traverse via native_tools_dispatch
    trav_out=$(native_tools_dispatch "call_okf_1" "okf_traverse" '{"seed":"lib/core/react.sh","max_hops":2,"top_k":5}' "$LODGE_DIR")
    assert_ok $?
    echo "$trav_out" | jq -r '.content' | jq -e '.seed_uri == "urn:blue-lodge:module:lib/core/react.sh" and (.neighbors | length > 0)' >/dev/null
    assert_ok $?

    # Verify worker and pr_reviewer context prompts include okf_traverse guidance
    w_ctx=$(context_engine_build "Fix bug" "$LODGE_DIR" 1 "worker")
    assert_contains "$w_ctx" "okf_traverse"
    r_ctx=$(context_engine_build "Review PR" "$LODGE_DIR" 1 "pr_reviewer")
    assert_contains "$r_ctx" "okf_traverse"
  }

  it "supports explicit-step 0ms DAG extraction, milestone_complete prune_ids, standing-order superseding, and reflexive recall.db telemetry" && {
    # 1. Explicit-step 0ms DAG extraction in honeydew_strategist.py
    exp_dag=$(python3 "$LODGE_DIR/lib/tools/honeydew_strategist.py" "Step 1: Inspect config. Step 2: Run tests. Step 3: Report results.")
    assert_ok $?
    echo "$exp_dag" | jq -e '.source == "explicit_steps" and (.items | length == 3)' >/dev/null
    assert_ok $?

    # 2. Elastic conditional pruning via milestone_complete(prune_ids=[2, 3])
    tmp_prune=$(mktemp -d /tmp/test_prune_XXXXXX)
    mkdir -p "$tmp_prune/.george"
    cat > "$tmp_prune/.george/honeydew.json" << 'EOF'
{"items":[{"id":1,"task":"Evaluate orders","status":"pending"},{"id":2,"task":"Reclaim if invalid","status":"pending"},{"id":3,"task":"Remint if invalid","status":"pending"},{"id":4,"task":"Synthesize report","status":"pending"}]}
EOF
    AGENT_ACTIVE_SESSION_DIR="$tmp_prune/.george" CURRENT_ACTIVE_MILESTONE_ID=1 \
      native_tools_dispatch "call_mc_1" "milestone_complete" '{"status":"success","summary":"Orders valid","prune_ids":[2,3]}' "$tmp_prune" >/dev/null
    assert_ok $?
    jq -e '([.items[] | select(.skipped == true) | .id] | sort) == [2, 3]' "$tmp_prune/.george/honeydew.json" >/dev/null
    assert_ok $?
    rm -rf "$tmp_prune"

    # 3. Standing-order atomic supersede & evaluate_standing_orders in plans.py (private alpha)
    if [ -f "$LODGE_DIR/lib/tools/trading/plans.py" ]; then
        _test_py="$LODGE_DIR/.venv/bin/python"
        [ -x "$_test_py" ] || _test_py="python3"
        so_res=$(PYTHONPATH="$LODGE_DIR" "$_test_py" - << 'PYEOF'
import sqlite3, time
from lib.tools.trading import store, policy, plans
con = sqlite3.connect(":memory:")
con.row_factory = sqlite3.Row
con.executescript(store._SCHEMA)
pol = policy.load_policy()
now = int(time.time())
con.execute(
    "INSERT INTO standing_orders (so_id, created_at, expires_at, strategy, asset, side, max_ada, used_ada, price_min, price_max, status) "
    "VALUES ('SO-AAA111', ?, ?, 'manual', 'IAG', 'buy', 180.0, 0.0, 0.070, 0.072, 'active')",
    (now - 10800, now + 86400),
)
con.commit()
# Evaluate against synthetic drifted market (spot=0.090, sigma_24h=0.03)
evals = plans.evaluate_standing_orders(con, pol, market={"IAG": {"spot": 0.090, "sigma_24h": 0.03, "fee_bps": 75.0}}, now=now)
assert len(evals) == 1 and evals[0]["health"] == "needs_recalibration", f"Expected needs_recalibration, got {evals}"
# 1. Execute non-overlapping standing_order_create -> coexists as multi-corridor ladder
r_ladder = plans._run_action(con, {"type": "standing_order_create", "strategy": "manual", "asset": "IAG", "side": "buy",
                                   "max_ada": 100.0, "price_min": 0.084, "price_max": 0.087, "expires_at": now + 86400},
                             pol, live=False, actor="test", plan_id="P-TEST01")
assert r_ladder["status"] == "ok" and r_ladder.get("superseded_so_ids") == [] and "SO-AAA111" in r_ladder.get("coexisting_so_ids", []), f"Ladder failed: {r_ladder}"
assert con.execute("SELECT status FROM standing_orders WHERE so_id='SO-AAA111'").fetchone()[0] == "active"
# 2. Execute recalibration / overlapping standing_order_create -> selectively supersedes SO-AAA111 while keeping ladder rung active
r_sup = plans._run_action(con, {"type": "standing_order_create", "strategy": "manual", "asset": "IAG", "side": "buy",
                                "max_ada": 180.0, "price_min": 0.071, "price_max": 0.074, "expires_at": now + 86400,
                                "reason": "recalibrate SO-AAA111"},
                          pol, live=False, actor="test", plan_id="P-TEST02")
assert r_sup["status"] == "ok" and r_sup.get("superseded_so_ids") == ["SO-AAA111"], f"Supersede failed: {r_sup}"
old_st = con.execute("SELECT status FROM standing_orders WHERE so_id='SO-AAA111'").fetchone()[0]
assert old_st == "superseded", f"Expected superseded, got {old_st}"
ladder_st = con.execute("SELECT status FROM standing_orders WHERE so_id=?", (r_ladder["so_id"],)).fetchone()[0]
assert ladder_st == "active", f"Expected non-overlapping ladder rung to stay active, got {ladder_st}"
print("SO_LIFECYCLE_OK")
PYEOF
)
        assert_contains "$so_res" "SO_LIFECYCLE_OK"
    fi

    # 4. Reflexive learning loop enabled and wired to recall.db
    source "$LODGE_DIR/lib/core/reflexive.sh"
    assert_eq "$REFLEXIVE_PROMPT_LEARN" "1"
    assert_eq "$REFLEXIVE_SELF_MODEL" "1"
    s_rate=$(reflexive_prompt_success_rate)
    [[ "$s_rate" =~ ^[0-9]+\.[0-9]+$ ]]
    assert_ok $?
  }

test_end
