#!/bin/bash
# ── Tests: lib/task_sync.sh & commands/task_sync.sh ───────────────────
# Unit & integration verification for task-to-task MQTT signaling,
# auto-remediation coordination, and worktree git synchronization.

source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/mqtt.sh"
source "$LODGE_DIR/lib/task_sync.sh"
source "$LODGE_DIR/commands/task_sync.sh"

test_start "lib/task_sync.sh — Inter-Task Coordination & Git Sync"

describe "task_sync_signal & task_sync_wait via MQTT"

  it "initializes task_sync and verifies local broker connection" && {
    task_sync_init
    assert_ok $?
  }

  it "signals an event and receives it via task_sync_wait" && {
    tid="test_node_$$"
    evt="heartbeat"
    payload='{"state":"ACTIVE","gpu":1,"tier":1}'

    # Background publisher with 1s delay
    (
      sleep 1
      task_sync_signal "$tid" "$evt" "$payload"
    ) &
    pub_pid=$!

    received=$(task_sync_wait "george/tasks/${tid}/${evt}" 6)
    wait $pub_pid 2>/dev/null || true

    assert_not_empty "$received"
    state=$(echo "$received" | jq -r '.state' 2>/dev/null)
    assert_eq "$state" "ACTIVE"
  }

  it "filters message on match_key and match_val" && {
    tid="test_match_$$"
    evt="resolution"
    p1='{"status":"IN_PROGRESS","step":1}'
    p2='{"status":"RESOLVED","step":2}'

    # Background publisher of two events
    (
      sleep 1
      task_sync_signal "$tid" "$evt" "$p1"
      sleep 1
      task_sync_signal "$tid" "$evt" "$p2"
    ) &
    pub_pid=$!

    received=$(task_sync_wait "george/tasks/${tid}/${evt}" 8 "status" "RESOLVED")
    wait $pub_pid 2>/dev/null || true

    assert_not_empty "$received"
    st=$(echo "$received" | jq -r '.status' 2>/dev/null)
    assert_eq "$st" "RESOLVED"
  }

  it "returns failure when wait times out" && {
    tid="test_timeout_$$"
    task_sync_wait "george/tasks/${tid}/never_sent" 2
    assert_fail $?
  }

describe "task_sync_rebase_develop"

  it "cleans up stale index.lock before rebasing" && {
    test_wt=$(test_tmpdir)
    git init "$test_wt" >/dev/null 2>&1
    touch "$test_wt/.git/index.lock"

    # task_sync_rebase_develop will clear lock and attempt fetch
    task_sync_rebase_develop "$test_wt" >/dev/null 2>&1 || true
    assert_file_not_exists "$test_wt/.git/index.lock"
    rm -rf "$test_wt" 2>/dev/null
  }

describe "Slash command /task_sync"

  it "executes /task_sync status" && {
    out=$(cmd_task_sync "status" "$PWD")
    assert_contains "$out" "Sovereign Task Synchronization Bridge"
  }

  it "executes /task_sync pub and sub" && {
    tid="cmd_test_$$"
    (
      sleep 1
      cmd_task_sync "pub $tid ping {\"ping\":\"pong\"}" "$PWD" >/dev/null 2>&1
    ) &
    pub_pid=$!

    out=$(cmd_task_sync "sub george/tasks/${tid}/ping 5" "$PWD")
    wait $pub_pid 2>/dev/null || true

    assert_contains "$out" "pong"
  }

test_end
