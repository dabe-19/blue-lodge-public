#!/bin/bash
# ── Tests: Operator Gitea intake -> remediation queue (hermetic, mocked Gitea) ─────
source "$(dirname "$0")/framework.sh"

_t=""
_setup() {
    _t=$(test_tmpdir)
    export LODGE_DIR="$_t" GEORGE_DIR="$_t/.george"
    export REMEDIATION_DIR="$GEORGE_DIR/remediation"
    export REMEDIATION_QUEUE_DIR="$REMEDIATION_DIR/queue"
    export REMEDIATION_PROGRESS_DIR="$REMEDIATION_DIR/in_progress"
    export REMEDIATION_COMPLETED_DIR="$REMEDIATION_DIR/completed"
    export REMEDIATION_FAILED_DIR="$REMEDIATION_DIR/failed"
    export REMEDIATION_CONF="$REMEDIATION_DIR/notifications.conf"
    export GITEA_USER="george"
    unset REMEDIATION_INTAKE_AUTHORS REMEDIATION_INTAKE_LABEL
    source "$GEORGE_TEST_REPO/lib/agents/remediation.sh"
    remediation_init
    : > "$_t/labels.log"; : > "$_t/comments.log"; : > "$_t/list_args.log"
    # Mock Gitea: issues fixture in $_t/issues.json
    gitea_issue_list() { echo "$*" >> "$_t/list_args.log"; cat "$_t/issues.json"; }
    gitea_issue_add_labels() { echo "$1 $2" >> "$_t/labels.log"; }
    gitea_issue_comment() { echo "$1" >> "$_t/comments.log"; }
    gitea_issue_get() { jq -c --argjson n "$1" '.[] | select(.number == $n)' "$_t/states.json"; }
}
_teardown() { unset -f gitea_issue_list gitea_issue_add_labels gitea_issue_comment gitea_issue_get; rm -rf "$_t"; }

_fixture() {
    cat > "$_t/issues.json" <<'EOF'
[
 {"number": 10, "title": "Fix the cron parser", "body": "Steps: run /cron list", "user": {"login": "operator-19", "is_admin": true}, "labels": [{"name": "remediate"}, {"name": "urgent"}]},
 {"number": 11, "title": "Self-filed by george", "body": "x", "user": {"login": "george", "is_admin": true}, "labels": [{"name": "remediate"}]},
 {"number": 12, "title": "Random user", "body": "x", "user": {"login": "mallory", "is_admin": false}, "labels": [{"name": "remediate"}]},
 {"number": 13, "title": "Already queued", "body": "x", "user": {"login": "operator-19", "is_admin": true}, "labels": [{"name": "remediate"}, {"name": "george-queued"}]},
 {"number": 14, "title": "No trigger label", "body": "x", "user": {"login": "operator-19", "is_admin": true}, "labels": [{"name": "bug"}]},
 {"number": 15, "title": "A PR", "body": "x", "user": {"login": "operator-19", "is_admin": true}, "labels": [{"name": "remediate"}], "pull_request": {"merged": false}}
]
EOF
}

test_start "Remediation Gitea Intake"

describe "remediation_gitea_intake"

  it "enqueues only trusted, labelled, un-queued issues (admin fallback, never george)" && {
      _setup; _fixture
      n=$(remediation_gitea_intake 2>/dev/null)
      assert_eq "$n" "1"
      qf=$(ls "$REMEDIATION_QUEUE_DIR"/*.json | head -1)
      assert_eq "$(jq -r .gitea_issue "$qf")" "10"
      assert_eq "$(jq -r .priority "$qf")" "high"
      assert_contains "$(cat "$_t/labels.log")" "10 george-queued"
      assert_contains "$(cat "$_t/list_args.log")" "open json remediate"
      assert_file_exists "$GEORGE_DIR/issues/issue_gitea_10.md"
      assert_contains "$(cat "$GEORGE_DIR/issues/issue_gitea_10.md")" "author: operator-19"
      _teardown
  }

  it "is idempotent while a task tracks the issue" && {
      _setup; _fixture
      remediation_gitea_intake >/dev/null 2>&1
      n=$(remediation_gitea_intake 2>/dev/null)
      assert_eq "$n" "0"
      assert_eq "$(ls "$REMEDIATION_QUEUE_DIR"/*.json | wc -l | tr -d ' ')" "1"
      _teardown
  }

  it "respects an explicit author allow-list over the admin fallback" && {
      _setup; _fixture
      export REMEDIATION_INTAKE_AUTHORS="mallory"
      n=$(remediation_gitea_intake 2>/dev/null)
      assert_eq "$n" "1"
      assert_eq "$(jq -r .gitea_issue "$REMEDIATION_QUEUE_DIR"/*.json)" "12"
      unset REMEDIATION_INTAKE_AUTHORS
      _teardown
  }

  it "returns 0 when Gitea returns garbage" && {
      _setup; echo "ERROR: offline" > "$_t/issues.json"
      n=$(remediation_gitea_intake 2>/dev/null)
      assert_eq "$n" "0"
      _teardown
  }

describe "remediation_gitea_cancel_closed"

  it "cancels queued tasks whose issue is closed and keeps open ones" && {
      _setup
      echo '[{"number": 20, "state": "closed"}, {"number": 21, "state": "open"}]' > "$_t/states.json"
      for g in 20 21; do
          printf '# t%s\n\n**Gitea Issue:** #%s\n' "$g" "$g" > "$_t/i$g.md"
          remediation_queue_add "$_t/i$g.md" "" normal "t$g" >/dev/null 2>&1
          sleep 1
      done
      n=$(remediation_gitea_cancel_closed 2>/dev/null)
      assert_eq "$n" "1"
      assert_eq "$(jq -r .gitea_issue "$REMEDIATION_QUEUE_DIR"/*.json)" "21"
      f=$(ls "$REMEDIATION_FAILED_DIR"/*.json | head -1)
      assert_eq "$(jq -r .status "$f")" "CANCELLED"
      _teardown
  }

describe "cron wiring"

  it "issue_sweep runs cancel + intake before picking the next task" && {
      src=$(sed -n '/issue_sweep)/,/;;/p' "$GEORGE_TEST_REPO/lib/sys/cron.sh")
      assert_contains "$src" "remediation_gitea_cancel_closed"
      assert_contains "$src" "remediation_gitea_intake"
  }

test_end
