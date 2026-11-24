#!/usr/bin/env bash
# ── Tests: Blue Lodge Sovereign Agentic Loop Protocol (ALP v1) ───────────────
# Covers loop_schema.py, loop_engine.sh (FIFO parallel/pipe + ReAct + gates),
# layered override/source resolution, react.sh declarative tool scoping,
# Sovereign Research Studio loop config binding, and XSS/security invariants.

set -euo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

export LODGE_DIR
export GEORGE_DIR="$TEST_TMP/.george"
export FIFO_IPC_DIR="$TEST_TMP/.george/ipc"
mkdir -p "$GEORGE_DIR/modules/demo-mod/workflows" "$GEORGE_DIR/module_data/demo-mod" "$GEORGE_DIR/workflows/loops"

echo "=== Blue Lodge Sovereign Agentic Loop Protocol (ALP v1) Test Suite ==="

# 1. Packaged Heartwood loops validate cleanly & default to 200 turns
for lid in deep-research code-architect system-vitals-triage; do
    f="$LODGE_DIR/data/workflows/loops/${lid}.loop.json"
    if [ -f "$f" ] && out=$(python3 "$LODGE_DIR/lib/core/loop_schema.py" validate "$f" 2>/dev/null); then
        mt=$(printf '%s' "$out" | jq -r '.normalized.defaults.max_turns')
        [ "$mt" = "200" ] && ok "Heartwood loop '$lid' valid & defaults to 200 turns" || fail "Heartwood loop '$lid' max_turns=$mt (expected 200)"
    else
        fail "Heartwood loop '$lid' failed validation"
    fi
done

# 2. Schema rejects path traversal, shell injection in tool names, and out-of-range turns
if python3 "$LODGE_DIR/lib/core/loop_schema.py" validate - <<< '{"schema_version":1,"id":"../pwn","name":"Bad","phases":[{"id":"p1","kind":"react"}]}' >/dev/null 2>&1; then
    fail "Schema should reject path traversal id"
else
    ok "Schema rejects path traversal id"
fi

if python3 "$LODGE_DIR/lib/core/loop_schema.py" validate - <<< '{"schema_version":1,"id":"bad_tool","name":"Bad","tools":{"allow":["ok;rm -rf /"]},"phases":[{"id":"p1","kind":"react"}]}' >/dev/null 2>&1; then
    fail "Schema should reject shell-injection tool name"
else
    ok "Schema rejects shell-injection tool name"
fi

if python3 "$LODGE_DIR/lib/core/loop_schema.py" validate - <<< '{"schema_version":1,"id":"bad_turns","name":"Bad","defaults":{"max_turns":9999},"phases":[{"id":"p1","kind":"react"}]}' >/dev/null 2>&1; then
    fail "Schema should reject out-of-range max_turns"
else
    ok "Schema rejects out-of-range max_turns"
fi

# 3. Layered resolution: override wins over source, delete override reverts cleanly
ovr_json=$(python3 "$LODGE_DIR/lib/core/loop_schema.py" resolve heartwood deep-research | jq '.loop | .defaults.max_turns = 250 | .phases[3].enabled = false')
if printf '%s' "$ovr_json" | python3 "$LODGE_DIR/lib/core/loop_schema.py" save heartwood deep-research --target override >/dev/null; then
    res=$(python3 "$LODGE_DIR/lib/core/loop_schema.py" resolve heartwood deep-research)
    if [ "$(printf '%s' "$res" | jq -r '.has_override')" = "true" ] && \
       [ "$(printf '%s' "$res" | jq -r '.loop.defaults.max_turns')" = "250" ] && \
       [ "$(printf '%s' "$res" | jq -r '.loop.phases[3].enabled')" = "false" ]; then
        ok "Override layer shadows packaged deep-research loop"
    else
        fail "Override layer did not apply cleanly"
    fi
else
    fail "Failed saving override loop"
fi

if python3 "$LODGE_DIR/lib/core/loop_schema.py" delete heartwood deep-research --target override >/dev/null; then
    res=$(python3 "$LODGE_DIR/lib/core/loop_schema.py" resolve heartwood deep-research)
    if [ "$(printf '%s' "$res" | jq -r '.has_override')" = "false" ] && \
       [ "$(printf '%s' "$res" | jq -r '.loop.defaults.max_turns')" = "200" ]; then
        ok "Deleting override cleanly reverts to packaged default (200 turns)"
    else
        fail "Revert to packaged default failed"
    fi
else
    fail "Failed deleting override"
fi

# 4. Template renderer preserves JSON arrays & default filters
cat > "$TEST_TMP/ctx.json" <<'JSON'
{
  "params": { "images": ["/tmp/a.jpg", "/tmp/b.jpg"], "brand": "Patagonia" },
  "phase": { "p1": { "ocr": { "tokens": ["RN51884"] } } },
  "result_path": "/tmp/result.json"
}
JSON
rendered=$(python3 "$LODGE_DIR/lib/core/loop_schema.py" render --context-file "$TEST_TMP/ctx.json" \
    --json-template '{"images":"{{params.images}}","brand":"{{params.brand}}","fallback":"{{params.missing | DefaultVal}}"}')
if [ "$(printf '%s' "$rendered" | jq -r '.images | length')" = "2" ] && \
   [ "$(printf '%s' "$rendered" | jq -r '.brand')" = "Patagonia" ] && \
   [ "$(printf '%s' "$rendered" | jq -r '.fallback')" = "DefaultVal" ]; then
    ok "Template renderer preserves typed JSON arrays and fallback values"
else
    fail "Template renderer unexpected output: $rendered"
fi

# 5. End-to-end FIFO parallel + FIFO pipe + ReAct + Verification Gate execution
cat > "$GEORGE_DIR/modules/demo-mod/module.json" <<'JSON'
{
  "schema_version": 1,
  "id": "demo-mod",
  "name": "Demo Mod",
  "version": "1.0.0",
  "category": "test",
  "runtime": { "venv_mode": "none" },
  "provides": { "workflows_dir": "workflows" }
}
JSON

cat > "$GEORGE_DIR/modules/demo-mod/workflows/fifo_demo.loop.json" <<'JSON'
{
  "schema_version": 1,
  "id": "fifo_demo",
  "name": "FIFO Parallel + Pipe + ReAct Demo",
  "owner": "demo-mod",
  "defaults": {
    "max_turns": 200,
    "ipc_priority": 100,
    "fifo_window": 16,
    "tool_timeout_sec": 30,
    "output_artifact": "result.json"
  },
  "tools": {
    "bundles": ["+demo"],
    "allow": ["demo_alpha", "demo_beta", "file_write"],
    "deny": ["bash_exec"]
  },
  "phases": [
    {
      "id": "gather",
      "name": "Parallel FIFO Gather",
      "kind": "fifo_parallel",
      "enabled": true,
      "continue_on_error": false,
      "timeout_sec": 20,
      "tasks": [
        { "id": "t_alpha", "tool": "demo_alpha", "args_template": { "tag": "{{params.tag}}" }, "output_key": "alpha" },
        { "id": "t_beta",  "tool": "demo_beta",  "args_template": { "tag": "{{params.tag}}" }, "output_key": "beta" }
      ]
    },
    {
      "id": "pipe_stage",
      "name": "Sequential FIFO Pipe",
      "kind": "fifo_pipe",
      "enabled": true,
      "continue_on_error": false,
      "timeout_sec": 20,
      "tasks": [
        { "id": "p_one", "tool": "demo_alpha", "args_template": { "step": "1" }, "output_key": "step1" },
        { "id": "p_two", "tool": "demo_echo_prev", "args_template": { "prev_val": "{{prev}}" }, "output_key": "step2" }
      ]
    },
    {
      "id": "reason",
      "name": "ReAct Synthesis",
      "kind": "react",
      "enabled": true,
      "max_turns": 200,
      "tool_filter": "default",
      "prompt_template": "ALPHA={{phase.gather.alpha}} BETA={{phase.gather.beta}} OUT={{result_path}}",
      "gate": {
        "type": "json_file",
        "path": "result.json",
        "required_keys": ["workflow", "status"],
        "on_fail": "fail",
        "max_retries": 0
      }
    }
  ]
}
JSON

# Run loop_engine.sh in a clean subshell with mocked native_tools_dispatch & react_run
SBOX="$TEST_TMP/sandbox_demo"
mkdir -p "$SBOX/inputs"
printf '{"tag":"alpine"}\n' > "$SBOX/inputs/params.json"
REACT_CAPTURE="$TEST_TMP/react_capture.txt"

(
    source "$LODGE_DIR/lib/core/loop_engine.sh"
    native_tools_dispatch() {
        local _cid="$1" tname="$2" targs="$3"
        case "$tname" in
            demo_alpha) printf '{"src":"alpha","args":%s}\n' "$targs" ;;
            demo_beta)  printf '{"src":"beta","args":%s}\n' "$targs" ;;
            demo_echo_prev) printf '{"chained":true,"input":%s}\n' "$targs" ;;
            *) printf '{"unknown":"%s"}\n' "$tname"; return 1 ;;
        esac
    }
    export -f native_tools_dispatch

    react_run() {
        local prompt="$1" _wd="$2" turns="$3"
        printf 'TURNS=%s\nALLOW=%s\nDENY=%s\nMOD=%s\nPROMPT=%s\n' \
            "$turns" "${LODGE_LOOP_TOOLS_ALLOW:-}" "${LODGE_LOOP_TOOLS_DENY:-}" "${LODGE_ACTIVE_MODULE:-}" "$prompt" > "$REACT_CAPTURE"
        printf '{"workflow":"fifo_demo","status":"ok"}\n' > "$SBOX/result.json"
        return 0
    }

    GEORGE_TASK_ID="test_fifo_demo" loop_run "demo-mod" "fifo_demo" "$SBOX" "$SBOX/inputs/params.json"
) >/dev/null 2>&1

if [ -f "$SBOX/phase_outputs/gather.json" ] && \
   [ "$(jq -r '.alpha.src' "$SBOX/phase_outputs/gather.json")" = "alpha" ] && \
   [ "$(jq -r '.beta.src' "$SBOX/phase_outputs/gather.json")" = "beta" ]; then
    ok "fifo_parallel settled both concurrent FIFO promises into phase_outputs/gather.json"
else
    fail "fifo_parallel phase outputs missing or malformed"
fi

if [ -f "$SBOX/phase_outputs/pipe_stage.json" ] && \
   [ "$(jq -r '.step2.chained' "$SBOX/phase_outputs/pipe_stage.json")" = "true" ]; then
    ok "fifo_pipe chained sequential stage outputs via {{prev}}"
else
    fail "fifo_pipe chaining failed"
fi

if grep -q '^TURNS=200$' "$REACT_CAPTURE" && \
   grep -q '^ALLOW=demo_alpha,demo_beta,file_write$' "$REACT_CAPTURE" && \
   grep -q '^DENY=bash_exec$' "$REACT_CAPTURE" && \
   grep -q '^MOD=demo-mod$' "$REACT_CAPTURE" && \
   grep -q 'ALPHA=.*alpha' "$REACT_CAPTURE"; then
    ok "react phase received 200 turns, declarative allow/deny tools, and FIFO pre-flight context"
else
    fail "react phase capture mismatch: $(cat "$REACT_CAPTURE" 2>/dev/null || true)"
fi

if [ -f "$SBOX/result.json" ] && ! [ -f "$SBOX/quarantine_report.md" ]; then
    ok "json_file verification gate passed cleanly"
else
    fail "json_file verification gate unexpectedly failed"
fi

# Verify FIFO channel was closed cleanly on loop exit (no orphan OPEN channel)
if [ ! -f "$FIFO_IPC_DIR/channels/loop_test_fifo_demo/state.json" ] || \
   ! grep -q '"status":[[:space:]]*"OPEN"' "$FIFO_IPC_DIR/channels/loop_test_fifo_demo/state.json" 2>/dev/null; then
    ok "Loop-scoped FIFO channel closed cleanly with zero leaked OPEN state"
else
    fail "Loop-scoped FIFO channel left OPEN after loop_run returned"
fi

# 6. Declarative _react_scope_tools_for_step integration (LODGE_LOOP_TOOLS_ALLOW & DENY)
scoped_tools=$(
    source "$LODGE_DIR/lib/core/react.sh"
    sample='[{"function":{"name":"file_read"}},{"function":{"name":"file_write"}},{"function":{"name":"posh_appraise"}},{"function":{"name":"bash_exec"}}]'
    LODGE_LOOP_TOOLS_ALLOW="posh_appraise,file_read" \
    LODGE_LOOP_TOOLS_DENY="bash_exec" \
    _react_scope_tools_for_step "$sample" "Run custom loop" 1
)
if printf '%s' "$scoped_tools" | jq -e 'any(.[]; .function.name == "posh_appraise")' >/dev/null 2>&1 && \
   printf '%s' "$scoped_tools" | jq -e 'all(.[]; .function.name != "bash_exec")' >/dev/null 2>&1; then
    ok "_react_scope_tools_for_step honors LODGE_LOOP_TOOLS_ALLOW and strips LODGE_LOOP_TOOLS_DENY"
else
    fail "_react_scope_tools_for_step did not apply allow/deny cleanly: $scoped_tools"
fi

# 7. Security & Turn-Cap Regression Checks (excluding single-line comments)
if grep -hv '^[[:space:]]*//' "$LODGE_DIR/web/static/js/loop_studio.js" "$LODGE_DIR/web/static/js/modules.js" | \
   grep -qE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|\balert\s*\(|\bconfirm\s*\(|\bprompt\s*\('; then
    fail "Unsafe DOM sink or native dialog found in loop_studio.js / modules.js"
else
    ok "loop_studio.js and modules.js have zero unsafe DOM sinks or native dialogs"
fi

if grep -q 'options\.maxTurns || 20' "$LODGE_DIR/web/static/js/modules.js" || \
   grep -q 'unwrap_or(28)' "$LODGE_DIR/web/src/routes/modules.rs"; then
    fail "Legacy 20/28 turn cap still present in modules.js or modules.rs"
else
    ok "Legacy 20/28 module turn caps removed (defaults to 200)"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
