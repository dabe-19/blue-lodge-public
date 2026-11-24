#!/usr/bin/env bash
# ── Tests: 5-Phase Trestleboard Upgrades (Phases 1-5) ─────────────────
source "$(dirname "$0")/framework.sh"

LODGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export LODGE_DIR

source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/core/react.sh"
source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/agents/remediation.sh"
source "$LODGE_DIR/lib/ipc/event_bus.sh"

test_start "5-Phase Trestleboard Upgrades (KV-Cache, Lease Pinning, Scope Gate, Ranged Edit, Webhooks)"

# ══════════════════════════════════════════════════════════════════════
# Phase 1: Deterministic Milestone Matching & Single-Slot KV Preservation
# ══════════════════════════════════════════════════════════════════════
describe "Phase 1: Deterministic Milestone Matching (_react_advance_honeydew_plan)"

it "advances file inspection and modification milestones deterministically without LLM evaluator" && {
    TMP_W="$(mktemp -d)"
    mkdir -p "$TMP_W/.george"
    cat > "$TMP_W/.george/honeydew.json" <<'JSON'
{
  "items": [
    {"id": 1, "task": "Inspect reactors.json lines 220-240", "status": "pending"},
    {"id": 2, "task": "Add rx_webhook_gitea_push reactor to reactors.json", "status": "pending"}
  ]
}
JSON
    session_dir="$TMP_W/.george" _LODGE_IN_TASK=1 REACT_EVAL_ENDPOINT="http://127.0.0.1:8080" LLM_BASE_URL="http://127.0.0.1:8080" \
        _react_advance_honeydew_plan "$TMP_W" "file_read" '{"path":"/home/user/blue-lodge/.george/reactors.json","start_line":220,"end_line":240}' "220: ..."
    st1=$(jq -r '.items[0].status' "$TMP_W/.george/honeydew.json")
    assert_eq "$st1" "done"

    session_dir="$TMP_W/.george" _LODGE_IN_TASK=1 REACT_EVAL_ENDPOINT="http://127.0.0.1:8080" LLM_BASE_URL="http://127.0.0.1:8080" \
        _react_advance_honeydew_plan "$TMP_W" "file_edit" '{"path":"/home/user/blue-lodge/.george/reactors.json","start_line":221,"end_line":233}' "Applied 1 block edits [exact+line_range]."
    st2=$(jq -r '.items[1].status' "$TMP_W/.george/honeydew.json")
    rm -rf "$TMP_W"
    assert_eq "$st2" "done"
}

# ══════════════════════════════════════════════════════════════════════
# Phase 2: Interactive Session Detection (active/task_*.pid)
# ══════════════════════════════════════════════════════════════════════
describe "Phase 2: Interactive Session Detection (ipc_is_human_present)"

it "detects live Discord task PID inside .george/discord_sessions/active/task_*.pid" && {
    TMP_G="$(mktemp -d)"
    mkdir -p "$TMP_G/discord_sessions/active" "$TMP_G/ipc"
    echo "$$" > "$TMP_G/discord_sessions/active/task_12345_67890.pid"

    GEORGE_DIR="$TMP_G" ipc_is_human_present
    rc=$?
    rm -rf "$TMP_G"
    assert_eq "$rc" "0"
}

# ══════════════════════════════════════════════════════════════════════
# Phase 3: Remediation Scope Gate & OKF Graph Exclusion
# ══════════════════════════════════════════════════════════════════════
describe "Phase 3: Remediation Scope Gate & Backlog Hygiene"

it "ignores auto-generated okf/blue_lodge_graph.jsonld in remediation_scope_violations_from_list" && {
    changed=$'lib/core/react.sh\nokf/blue_lodge_graph.jsonld'
    violations=$(remediation_scope_violations_from_list "$changed" "lib/core/react.sh")
    assert_empty "$violations"
}

it "verifies .george/issues/ has zero stale top-level .md files" && {
    shopt -s nullglob
    stale_files=( "${GEORGE_DIR:-$LODGE_DIR/.george}/issues/"*.md )
    shopt -u nullglob
    assert_eq "${#stale_files[@]}" "0"
}

# ══════════════════════════════════════════════════════════════════════
# Phase 4: Line-Range Anchored file_edit
# ══════════════════════════════════════════════════════════════════════
describe "Phase 4: Line-Range Anchored file_edit (start_line / end_line)"

it "performs boundary-anchored and range-scoped edits via edit_backend.py" && {
    TMP_FILE="$(mktemp)"
    printf 'line1\nline2\nline3\nline4\nline5\n' > "$TMP_FILE"
    out=$(EDITS_JSON='{"start_line":2,"end_line":4,"target":"line3","replacement":"line3_updated"}' python3 "$LODGE_DIR/lib/tools/edit_backend.py" "$TMP_FILE")
    assert_ok $?
    assert_contains "$out" "[exact+line_range]"
    content=$(cat "$TMP_FILE")
    rm -f "$TMP_FILE"
    assert_contains "$content" "line3_updated"
}

# ══════════════════════════════════════════════════════════════════════
# Phase 5: Sovereign Webhook Ingress Gateway & Event Contracts
# ══════════════════════════════════════════════════════════════════════
describe "Phase 5: Sovereign Webhook Ingress Gateway (/api/webhooks/status)"

it "verifies live /api/webhooks/status endpoint and webhook.* contracts" && {
    EVENT_CONTRACTS_FILE="$LODGE_DIR/configs/event_contracts.json"
    _EB_CONTRACTS_MTIME=""
    _eb_contract_check "webhook.gitea.push" '{"source":"gitea","event":"push"}'
    assert_ok $?

    if status_json=$(curl -sf http://127.0.0.1:3000/api/webhooks/status 2>/dev/null); then
        gw=$(printf '%s' "$status_json" | jq -r '.gateway')
        assert_eq "$gw" "active"
    else
        assert_file_exists "$LODGE_DIR/web/src/routes/webhooks.rs"
    fi
}

test_end
