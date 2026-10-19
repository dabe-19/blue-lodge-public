#!/usr/bin/env bash
# Storage retention janitor (refinement P1/1.9)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/framework.sh"
LODGE_DIR="$GEORGE_TEST_REPO"; export LODGE_DIR
unset _LIB_JANITOR_LOADED _LIB_RUN_LEDGER_LOADED
source "$LODGE_DIR/lib/sys/janitor.sh"

test_start "janitor"
assert_fn_defined janitor_run

G="$GEORGE_DIR"; old=$(( $(date +%s) - 40*86400 )); mid=$(( $(date +%s) - 10*86400 ))
_age() { touch -d "@$2" "$1"; }

# runs: one old finished, one old RUNNING (must survive), one fresh
mkdir -p "$G/runs/old_done" "$G/runs/old_running" "$G/runs/fresh"
echo "{\"status\":\"FINISHED\",\"ended_epoch\":$old}" > "$G/runs/old_done/run.json"
echo "{\"status\":\"RUNNING\",\"started_epoch\":$old}" > "$G/runs/old_running/run.json"
echo "{\"status\":\"FINISHED\",\"ended_epoch\":$(date +%s)}" > "$G/runs/fresh/run.json"
# transcripts: old (delete), mid (gzip), fresh (keep)
mkdir -p "$G/transcripts"
echo old > "$G/transcripts/2026-08-01_00-00-00.md"; _age "$G/transcripts/2026-08-01_00-00-00.md" "$old"
echo mid > "$G/transcripts/2026-09-24_00-00-00.md"; _age "$G/transcripts/2026-09-24_00-00-00.md" "$mid"
echo new > "$G/transcripts/2026-10-04_00-00-00.md"
# workspaces: old done (delete), old not done (keep), fresh done (keep)
mkdir -p "$G/workspaces/ws_old_done" "$G/workspaces/ws_old_live" "$G/workspaces/ws_new"
touch "$G/workspaces/ws_old_done/.done" "$G/workspaces/ws_new/.done"
_age "$G/workspaces/ws_old_done/.done" "$old"; _age "$G/workspaces/ws_old_done" "$old"; _age "$G/workspaces/ws_old_live" "$old"
echo '{"x":1}' > "$G/workspaces/web_session.jsonl"; _age "$G/workspaces/web_session.jsonl" "$old"
# discord_sessions: old per-session dir (delete), bridge.log (keep)
mkdir -p "$G/discord_sessions/0d1e2f-old"; _age "$G/discord_sessions/0d1e2f-old" "$old"
echo log > "$G/discord_sessions/bridge.log"; _age "$G/discord_sessions/bridge.log" "$old"

describe "dry run changes nothing"
out=$(JANITOR_DRY_RUN=1 janitor_run 30 7)
assert_contains "$out" "dry_run"
assert_file_exists "$G/runs/old_done/run.json"
assert_file_exists "$G/transcripts/2026-08-01_00-00-00.md"

describe "real run"
out=$(janitor_run 30 7)
assert_file_not_exists "$G/runs/old_done/run.json"
assert_file_exists "$G/runs/old_running/run.json"
assert_file_exists "$G/runs/fresh/run.json"
assert_file_not_exists "$G/transcripts/2026-08-01_00-00-00.md"
assert_file_exists "$G/transcripts/2026-09-24_00-00-00.md.gz"
assert_file_not_exists "$G/transcripts/2026-09-24_00-00-00.md"
assert_eq "$(gzip -dc "$G/transcripts/2026-09-24_00-00-00.md.gz")" "mid"
assert_file_exists "$G/transcripts/2026-10-04_00-00-00.md"
assert_file_not_exists "$G/workspaces/ws_old_done/.done"
[ -d "$G/workspaces/ws_old_live" ]; assert_eq "$?" "0" "unfinished workspace kept"
assert_file_exists "$G/workspaces/ws_new/.done"
assert_file_exists "$G/workspaces/web_session.jsonl"
assert_file_not_exists "$G/discord_sessions/0d1e2f-old"
assert_file_exists "$G/discord_sessions/bridge.log"
assert_eq "$(printf '%s' "$out" | jq -r '.runs_pruned')" "1"
assert_eq "$(printf '%s' "$out" | jq -r '.transcripts_gzipped')" "1"
assert_eq "$(printf '%s' "$out" | jq -r '.transcripts_deleted')" "1"

describe "old gz transcripts are deleted too"
_age "$G/transcripts/2026-09-24_00-00-00.md.gz" "$old"
janitor_run 30 7 >/dev/null
assert_file_not_exists "$G/transcripts/2026-09-24_00-00-00.md.gz"

describe "cron job wired"
assert_file_exists "$LODGE_DIR/.george/cron_jobs/storage_janitor.sh"
assert_contains "$(cat "$LODGE_DIR/.george/cron_jobs/storage_janitor.sh")" "janitor_run"

test_end
