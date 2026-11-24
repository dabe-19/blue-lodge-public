#!/bin/bash
# ── Tests for Autonomous CI/CD, Remediation & PR Approval Evolution (Pillars 1-5) ──

source "$(dirname "$0")/framework.sh"
LODGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$LODGE_DIR/lib/ipc/fifo_ipc.sh"
source "$LODGE_DIR/lib/agents/pr.sh"
source "$LODGE_DIR/lib/agents/remediation.sh"

test_start "Autonomous CI/CD, Remediation & PR Approval Evolution (Pillars 1-5)"

describe "Pillar 1: CI-Host Parity Bootstrap, Test Selector & Hermetic Runner"
  it "bootstraps a cold ephemeral GEORGE_DIR with recall.db, OKF edges, and telemetry seeds" && {
    tmp_b=$(mktemp -d /tmp/test_bootstrap_XXXXXX)
    GEORGE_DIR="$tmp_b/.george" RECALL_DB="$tmp_b/.george/recall.db" \
      bash "$LODGE_DIR/scripts/ci/bootstrap_env.sh" --no-apt
    assert_ok $?
    assert_file_exists "$tmp_b/.george/recall.db"

    edges=$(sqlite3 "$tmp_b/.george/recall.db" "SELECT COUNT(*) FROM okf_edges;" 2>/dev/null || echo 0)
    [ "${edges:-0}" -gt 1000 ]
    assert_ok $?

    tstats=$(sqlite3 "$tmp_b/.george/recall.db" "SELECT COUNT(*) FROM tool_telemetry_stats;" 2>/dev/null || echo 0)
    [ "${tstats:-0}" -ge 1 ]
    assert_ok $?
    rm -rf "$tmp_b"
  }

  it "maps changed files to targeted test suites via scripts/ci/select_tests.sh" && {
    sel_out=$(printf '%s\n' "okf/blue_lodge_graph.jsonld" "lib/ipc/fifo_ipc.sh" "lib/agents/pr.sh" | bash "$LODGE_DIR/scripts/ci/select_tests.sh" --stdin)
    assert_contains "$sel_out" "test_okf"
    assert_contains "$sel_out" "test_graph_and_routing_parity"
    assert_contains "$sel_out" "test_fifo_ipc"
    assert_contains "$sel_out" "test_ci_cd_evolution"
  }

  it "executes test_okf.sh inside an isolated ephemeral GEORGE_DIR via hermetic_test_runner.sh" && {
    out=$(bash "$LODGE_DIR/scripts/ci/hermetic_test_runner.sh" tests/test_okf.sh 2>&1)
    assert_ok $?
    assert_contains "$out" "21 passed"
  }

  it "includes standard Dockerfile.cuda-sandbox CLI dependencies (ripgrep, zstd, poppler-utils, procps) in bootstrap_env.sh and pre-push test gate" && {
    boot_src=$(cat "$LODGE_DIR/scripts/ci/bootstrap_env.sh")
    assert_contains "$boot_src" "ripgrep"
    assert_contains "$boot_src" "zstd"
    assert_contains "$boot_src" "poppler-utils"
    assert_contains "$boot_src" "procps"

    hook_src=$(cat "$LODGE_DIR/.githooks/pre-push")
    assert_contains "$hook_src" "select_tests.sh"
    assert_contains "$hook_src" "hermetic_test_runner.sh"
  }

describe "Pillar 2: Gitea CI Commit Status Gate & Diagnostic Remediation Ingress"
  it "evaluates Gitea CI commit statuses (success, pending, failure) via _pr_check_gitea_ci_status" && {
    _PR_TEST_CI_STATE="success" _pr_check_gitea_ci_status "528" "abc1234"
    assert_eq "$?" "0"

    rc_pend=0
    _PR_TEST_CI_STATE="pending" _pr_check_gitea_ci_status "528" "abc1234" || rc_pend=$?
    assert_eq "$rc_pend" "2"

    rc_fail=0
    _PR_TEST_CI_STATE="failure" _PR_TEST_CI_LOG="AssertionError: expected 93 passed" \
      _pr_check_gitea_ci_status "528" "abc1234" || rc_fail=$?
    assert_eq "$rc_fail" "1"
    assert_contains "$_PR_CI_FAILURE_LOG" "AssertionError: expected 93 passed"
    unset _PR_TEST_CI_STATE _PR_TEST_CI_LOG
  }

  it "drops recursive ci.build_failure events for remediation/* and subagent/* branches while embedding log_tail for develop" && {
    tmp_rem=$(mktemp -d /tmp/test_rem_ingress_XXXXXX)
    (
      export GEORGE_DIR="$tmp_rem/.george"
      export REMEDIATION_DIR="$GEORGE_DIR/remediation"
      export REMEDIATION_QUEUE_DIR="$REMEDIATION_DIR/queue"
      export REMEDIATION_PROGRESS_DIR="$REMEDIATION_DIR/in_progress"
      export REMEDIATION_COMPLETED_DIR="$REMEDIATION_DIR/completed"
      export REMEDIATION_FAILED_DIR="$REMEDIATION_DIR/failed"
      export REMEDIATION_ATTEMPTS_DIR="$REMEDIATION_DIR/attempts"
      export REMEDIATION_LOGS_DIR="$REMEDIATION_DIR/logs"
      export _LODGE_TESTING=1
      remediation_init

      # 1. remediation/* branch must be ignored
      remediation_event_ingress "ci.build_failure" '{"run_id":"901","branch":"remediation/rem_123","title":"CI Run Failed","log_tail":"boom"}' 2>/dev/null
      q_cnt=$(find "$REMEDIATION_QUEUE_DIR" -name "*.json" | wc -l)
      [ "$q_cnt" -eq 0 ] || exit 1

      # 2. develop branch must be enqueued and include Failed CI Job Log Tail in issue markdown
      remediation_event_ingress "ci.build_failure" '{"run_id":"902","branch":"develop","title":"CI Run Failed","log_tail":"jq: command not found in test_okf.sh"}' 2>/dev/null
      q_cnt2=$(find "$REMEDIATION_QUEUE_DIR" -name "*.json" | wc -l)
      [ "$q_cnt2" -eq 1 ] || exit 2
      iss_f=$(jq -r '.issue_file' "$REMEDIATION_QUEUE_DIR"/*.json)
      grep -q "Failed CI Job Log Tail" "$iss_f" || exit 3
      grep -q "jq: command not found in test_okf.sh" "$iss_f" || exit 4
    )
    assert_ok $?
    rm -rf "$tmp_rem"
  }

describe "Pillar 3: Anti-Evasion Guardrails in pr_audit"
  it "rejects PRs that inject top-level 'exit 0' before test_start in test files" && {
    tmp_repo=$(mktemp -d /tmp/test_pr_evasion_XXXXXX)
    (
      cd "$tmp_repo" || exit 1
      git init -q -b develop
      git config user.email "test@bluelodge.local"
      git config user.name "Test Runner"
      mkdir -p tests .george/pulls
      cp "$LODGE_DIR/tests/framework.sh" tests/framework.sh
      cat > tests/run_all.sh <<'EOF'
#!/bin/bash
for s in "$@"; do
  bash "tests/${s}.sh" || exit $?
done
EOF
      chmod +x tests/run_all.sh
      cat > tests/test_demo.sh <<'EOF'
#!/bin/bash
source "$(dirname "$0")/framework.sh"
test_start "Demo Suite"
describe "Demo"
  it "passes" && {
    assert_eq "1" "1"
  }
test_end
EOF
      git add -A && git commit -q -m "init"

      # Create an evasive PR branch that adds 'exit 0' before test_start
      git checkout -q -b remediation/evasive_pr
      cat > tests/test_demo.sh <<'EOF'
#!/bin/bash
source "$(dirname "$0")/framework.sh"
if [ ! -f "$LODGE_DIR/.george/recall.db" ]; then
  exit 0
fi
test_start "Demo Suite"
describe "Demo"
  it "passes" && {
    assert_eq "1" "1"
  }
test_end
EOF
      git commit -q -am "evasive skip"
      git checkout -q develop

      export LODGE_DIR="$tmp_repo"
      export GEORGE_DIR="$tmp_repo/.george"
      export PR_DIR="$GEORGE_DIR/pulls"
      export _LODGE_TESTING=1
      cat > "$PR_DIR/PR-999.json" <<'EOF'
{"id":"PR-999","title":"Evasive PR","source_branch":"remediation/evasive_pr","target_branch":"develop","status":"PROPOSED"}
EOF
      if pr_audit "PR-999" >/dev/null 2>&1; then
        exit 1
      fi
      grep -q "TEST EVASION FAIL" "$PR_DIR/PR-999.audit.log" || exit 2
    )
    assert_ok $?
    rm -rf "$tmp_repo"
  }

describe "Pillar 4 & 5: Control-Plane Runtime Isolation, Vanished-Promise Guard & CI Wiring"
  it "aborts ipc_await immediately with IPC_ERR_NOTFOUND if promise file vanishes mid-await" && {
    tmp_ipc=$(mktemp -d /tmp/test_ipc_vanish_XXXXXX)
    (
      export GEORGE_RUNTIME_DIR="$tmp_ipc/runtime"
      export FIFO_IPC_DIR="$GEORGE_RUNTIME_DIR/ipc"
      ipc_init "$FIFO_IPC_DIR"
      prom_id="prom_vanish_1"
      cat > "$FIFO_IPC_DIR/promises/${prom_id}.json" <<EOF
{"id":"$prom_id","channel":"ch","status":"PENDING","pid":1,"pgid":1,"exit_code":null,"created_at":$(date +%s)}
EOF
      ( sleep 0.15 && rm -f "$FIFO_IPC_DIR/promises/${prom_id}.json" ) &
      rc=0
      ipc_await "$prom_id" 5 >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq "$IPC_ERR_NOTFOUND" ] || exit 1
    )
    assert_ok $?
    rm -rf "$tmp_ipc"
  }

  it "wires bootstrap_env.sh, full-repo py_compile, dynamic select_tests.sh --ci, and main branch triggers into .gitea/workflows/ci.yml" && {
    grep -q "scripts/ci/bootstrap_env.sh --install-deps" "$LODGE_DIR/.gitea/workflows/ci.yml"
    assert_ok $?
    grep -q 'find lib scripts okf -name "\*.py" -not -path "\*/archive/\*" -exec python3 -m py_compile' "$LODGE_DIR/.gitea/workflows/ci.yml"
    assert_ok $?
    grep -q "scripts/ci/select_tests.sh --ci" "$LODGE_DIR/.gitea/workflows/ci.yml"
    assert_ok $?
    grep -q "polyglot sovereign system" "$LODGE_DIR/lib/agents/remediation.sh"
    assert_ok $?
  }

test_end

