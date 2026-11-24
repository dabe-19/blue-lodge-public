#!/usr/bin/env bash
# DESC: Automated verification suite for George Co-Pilot Pair Programming Engine, Tool Forge & Agent Forge

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test framework
source "$LODGE_DIR/tests/framework.sh"

test_start "George Co-Pilot Pair Programming Suite, Tool Forge & Agent Forge"

describe "1. Co-Pilot Metadata Endpoints"
  it "lists registered tools in lib/tools/ via GET /api/copilot/tools" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/copilot/tools")
    assert_ok $?
    status=$(echo "$resp" | jq -r '.status')
    [ "$status" = "ok" ] || _test_fail "check failed at line $LINENO"
    cnt=$(echo "$resp" | jq '(.tools | length) // 0')
    [ "$cnt" -ge 25 ] || assert_fail 2
    echo "$resp" | jq -e '.tools[] | select(.name == "treesitter.sh")' >/dev/null || assert_fail 3
    echo "$resp" | jq -e '.tools[] | select(.name == "copilot_engine.py")' >/dev/null || assert_fail 4
  }

  it "lists agent personas in .agents/workflows/ via GET /api/copilot/agents" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/copilot/agents")
    assert_ok $?
    status=$(echo "$resp" | jq -r '.status')
    [ "$status" = "ok" ] || _test_fail "check failed at line $LINENO"
    cnt=$(echo "$resp" | jq '(.agents | length) // 0')
    [ "$cnt" -ge 10 ] || assert_fail 2
    echo "$resp" | jq -e '.agents[] | select(.name == "commands-specialist")' >/dev/null || assert_fail 3
    echo "$resp" | jq -e '.agents[] | select(.name == "the-architect")' >/dev/null || assert_fail 4
  }

  it "lists workflows via GET /api/copilot/workflows" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/copilot/workflows")
    assert_ok $?
    status=$(echo "$resp" | jq -r '.status')
    [ "$status" = "ok" ] || _test_fail "check failed at line $LINENO"
    cnt=$(echo "$resp" | jq '(.workflows | length) // 0')
    [ "$cnt" -ge 15 ] || assert_fail 2
  }

  it "lists sovereign coding rules via GET /api/copilot/rules" && {
    resp=$(curl -s "http://127.0.0.1:3000/api/copilot/rules")
    assert_ok $?
    status=$(echo "$resp" | jq -r '.status')
    [ "$status" = "ok" ] || _test_fail "check failed at line $LINENO"
    cnt=$(echo "$resp" | jq '(.rules | length) // 0')
    [ "$cnt" -ge 15 ] || assert_fail 2
    echo "$resp" | jq -e '.rules[] | select(.name == "general-patterns")' >/dev/null || assert_fail 3
  }

describe "2. Non-Destructive Safe Commenting Guard"
  it "injects documentation without deleting any executable logic" && {
    sample_code=$'#!/bin/bash\ncalculate_hash() {\n  local target="$1"\n  sha256sum "$target"\n}\n\nrun_probe() {\n  echo "alive"\n}\n'
    resp=$(curl -s -X POST "http://127.0.0.1:3000/api/copilot/comment" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg c "$sample_code" '{file_path: "lib/tools/probe.sh", file_content: $c, instruction: "Comment this script"}')")
    assert_ok $?
    st=$(echo "$resp" | jq -r '.status')
    [ "$st" = "ok" ] || _test_fail "check failed at line $LINENO"
    act=$(echo "$resp" | jq -r '.action')
    [ "$act" = "safe_commenting_guard" ] || assert_fail 2
    has_edit=$(echo "$resp" | jq -r '.has_edit')
    [ "$has_edit" = "true" ] || assert_fail 3
    proposed=$(echo "$resp" | jq -r '.proposed_code')
    # Must preserve original routines
    echo "$proposed" | grep -q 'calculate_hash()' || assert_fail 4
    echo "$proposed" | grep -q 'run_probe()' || assert_fail 5
    echo "$proposed" | grep -q 'sha256sum' || assert_fail 6
    # Must contain injected doc comments
    echo "$proposed" | grep -q 'Routine: calculate_hash' || assert_fail 7
  }

describe "3. Tool Builder: Scaffolding & Sandbox Testing"
  it "scaffolds and registers a new tool via POST /api/copilot/tool/build" && {
    tool_content=$'#!/usr/bin/env bash\n# DESC: Test automated string multiplier\ncount="${1:-1}"\nmsg="${2:-ping}"\nfor ((i=0; i<count; i++)); do\n  echo -n "$msg "\ndone\necho ""\n'
    resp=$(curl -s -X POST "http://127.0.0.1:3000/api/copilot/tool/build" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg code "$tool_content" '{
        name: "test_multiplier_temp.sh",
        language: "bash",
        subsystem: "tools",
        description: "Test multiplier for copilot verification",
        code_content: $code
      }')")
    assert_ok $?
    succ=$(echo "$resp" | jq -r '.success')
    [ "$succ" = "true" ] || _test_fail "check failed at line $LINENO"
    [ -f "$LODGE_DIR/lib/tools/test_multiplier_temp.sh" ] || assert_fail 2
  }

  it "executes sandboxed tool run via POST /api/copilot/tool/test" && {
    resp=$(curl -s -X POST "http://127.0.0.1:3000/api/copilot/tool/test" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "test_multiplier_temp.sh",
        "args": ["3", "craftsman"]
      }')
    assert_ok $?
    succ=$(echo "$resp" | jq -r '.success')
    [ "$succ" = "true" ] || _test_fail "check failed at line $LINENO"
    exit_code=$(echo "$resp" | jq -r '.exit_code')
    [ "$exit_code" = "0" ] || assert_fail 2
    out=$(echo "$resp" | jq -r '.stdout')
    echo "$out" | grep -q "craftsman craftsman craftsman" || assert_fail 3

    # Cleanup temporary tool
    rm -f "$LODGE_DIR/lib/tools/test_multiplier_temp.sh"
  }

describe "4. Agent & Workflow Forge Endpoints"
  it "forges and saves an agent persona via POST /api/copilot/agent/save" && {
    resp=$(curl -s -X POST "http://127.0.0.1:3000/api/copilot/agent/save" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "test-telemetry-scout",
        "description": "Autonomous signal telemetry scout for radio sweeps",
        "rules": [".agents/rules/architecture/general-patterns.instructions.md"],
        "workflow": ["Read telemetry", "Filter noise", "Report metrics"]
      }')
    assert_ok $?
    succ=$(echo "$resp" | jq -r '.success')
    [ "$succ" = "true" ] || _test_fail "check failed at line $LINENO"
    target_path="$LODGE_DIR/.agents/workflows/test-telemetry-scout.agent.md"
    [ -f "$target_path" ] || assert_fail 2
    grep -q "name: test-telemetry-scout" "$target_path" || assert_fail 3
    grep -q "Autonomous signal telemetry scout" "$target_path" || assert_fail 4

    # Cleanup temporary agent
    rm -f "$target_path"
  }

  it "saves a multi-agent workflow guide via POST /api/copilot/workflow/save" && {
    resp=$(curl -s -X POST "http://127.0.0.1:3000/api/copilot/workflow/save" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "test-sweep-pipeline",
        "description": "Multi-agent RF spectrum sweep workflow",
        "objective": "Survey signal bands and log anomalies",
        "steps": ["Step 1: Init SDR node", "Step 2: Collect IQ samples", "Step 3: Transcribe audio"]
      }')
    assert_ok $?
    succ=$(echo "$resp" | jq -r '.success')
    [ "$succ" = "true" ] || _test_fail "check failed at line $LINENO"
    target_wf="$LODGE_DIR/.agents/workflows/test-sweep-pipeline.workflow.md"
    [ -f "$target_wf" ] || assert_fail 2
    grep -q "Multi-agent RF spectrum sweep workflow" "$target_wf" || assert_fail 3
    grep -q "Survey signal bands and log anomalies" "$target_wf" || assert_fail 4

    # Cleanup temporary workflow
    rm -f "$target_wf"
  }

describe "5. Co-Pilot UI Elements & Layout Verification"
  it "contains Co-Pilot drawer and subtabs in index.html" && {
    grep -q 'id="scriptCopilotPanel"' "$LODGE_DIR/web/static/index.html" || _test_fail "check failed at line $LINENO"
    grep -q 'id="copilotSubnavTabs"' "$LODGE_DIR/web/static/index.html" || assert_fail 2
    grep -q 'id="copilotTabChat"' "$LODGE_DIR/web/static/index.html" || assert_fail 3
    grep -q 'id="copilotTabToolBuilder"' "$LODGE_DIR/web/static/index.html" || assert_fail 4
    grep -q 'id="copilotTabAgentForge"' "$LODGE_DIR/web/static/index.html" || assert_fail 5
    grep -q 'id="copilotTabWorkflows"' "$LODGE_DIR/web/static/index.html" || assert_fail 6
    grep -q 'id="copilotTabContext"' "$LODGE_DIR/web/static/index.html" || assert_fail 7
  }

  it "contains Co-Pilot logic and event wiring in app.js" && {
    grep -q 'initCopilotPanel' "$LODGE_DIR/web/static/app.js" || _test_fail "check failed at line $LINENO"
    grep -q 'loadToolBuilderData' "$LODGE_DIR/web/static/app.js" || assert_fail 2
    grep -q 'loadAgentForgeData' "$LODGE_DIR/web/static/app.js" || assert_fail 3
    grep -q 'loadWorkflowsData' "$LODGE_DIR/web/static/app.js" || assert_fail 4
    grep -q 'loadContextData' "$LODGE_DIR/web/static/app.js" || assert_fail 5
  }

test_end
