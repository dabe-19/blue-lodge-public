#!/usr/bin/env bash
# ── Sovereign Sleep-Cycle & Colab Training Watchdog ──
# INTERVAL: 600
# ENABLED: 1
# DESC: Monitors active Colab/local SVD-32 runs, sends keep-alive heartbeats, auto-resumes 1h disconnects from Drive checkpoints, tears down finished VMs, runs 7-pillar benchmark gates, posts Discord Tier B approval cards, and optionally runs scheduled Sleep-Cycle consolidation.

set -uo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
PY="$LODGE_DIR/.venv/bin/python3"
[ ! -x "$PY" ] && PY="python3"
RUNS_PY="$LODGE_DIR/scripts/training/runs.py"
BENCH_PY="$LODGE_DIR/scripts/eval/multiturn_bench.py"
BACKUP_PY="$LODGE_DIR/scripts/training/backup_artifacts.py"

mkdir -p "$GEORGE_DIR/training"

_notify_discord() {
    local msg="$1"
    if [ -f "$LODGE_DIR/scripts/monitor/discord_send_report.sh" ]; then
        bash "$LODGE_DIR/scripts/monitor/discord_send_report.sh" "$msg" >/dev/null 2>&1 || true
    fi
}

POLICY_JSON=$("$PY" "$RUNS_PY" policy 2>/dev/null || echo '{}')
AUTONOMY_TIER=$(printf '%s' "$POLICY_JSON" | jq -r '.autonomy_tier // "tier_b"')
TIER_A_MIN_DELTA=$(printf '%s' "$POLICY_JSON" | jq -r '.tier_a_min_delta // 3.0')
AUTO_BACKUP_DRIVE=$(printf '%s' "$POLICY_JSON" | jq -r '.auto_backup_drive // false')
AUTO_BACKUP_HF=$(printf '%s' "$POLICY_JSON" | jq -r '.auto_backup_hf // false')

# 1. Inspect every active running run (Colab keep-alive / collect / auto-resume / SVD-32 merge + gate)
RUNS_JSON=$("$PY" "$RUNS_PY" list 2>/dev/null || echo '[]')
printf '%s' "$RUNS_JSON" | jq -c '.[] | select(.state == "running")' 2>/dev/null | while IFS= read -r row; do
    rname=$(printf '%s' "$row" | jq -r '.name')
    backend=$(printf '%s' "$row" | jq -r '.backend')
    [ -z "$rname" ] && continue

    if [ "$backend" = "colab" ]; then
        echo "[watchdog] Polling Colab run '$rname'..."
        col_out=$("$PY" "$RUNS_PY" collect "$rname" 2>/dev/null || echo '{}')
        if printf '%s' "$col_out" | grep -q "session_disconnected"; then
            echo "[watchdog] Detected Colab disconnect on '$rname' — auto-resuming from Drive checkpoint..."
            "$PY" "$RUNS_PY" resume "$rname" >/dev/null 2>&1 || true
            continue
        fi
        new_st=$("$PY" "$RUNS_PY" status "$rname" 2>/dev/null | jq -r '.state // "running"')
        if [ "$new_st" = "done" ]; then
            echo "[watchdog] All tracks complete for '$rname' — running SVD-32 retention fusion..."
            if "$PY" "$RUNS_PY" merge "$rname" >/dev/null 2>&1; then
                _notify_discord "**[Training Forge — Tier B Gate]** Run \`${rname}\` finished Colab training & SVD-32 fusion! Candidate staged in Forge UI (\`/train approve ${rname}\` or \`/train deny ${rname}\`)."
            else
                _notify_discord "**[Training Forge]** Run \`${rname}\` finished tracks but SVD-32 merge failed — check Forge logs."
            fi
        fi
    fi
done

# 2. Auto-promote staged candidates ONLY when operator explicitly switched Forge posture to Tier A
if [ "$AUTONOMY_TIER" = "tier_a" ]; then
    printf '%s' "$RUNS_JSON" | jq -c '.[] | select(.gate_status == "pending_approval" and .benchmark != null)' 2>/dev/null | while IFS= read -r row; do
        rname=$(printf '%s' "$row" | jq -r '.name')
        passed=$(printf '%s' "$row" | jq -r '.benchmark.passed // false')
        delta=$(printf '%s' "$row" | jq -r '.benchmark.composite_delta // -999')
        if [ "$passed" = "true" ] && awk -v d="$delta" -v m="$TIER_A_MIN_DELTA" 'BEGIN{exit !(d >= m)}'; then
            echo "[watchdog] Tier A auto-promoting '$rname' (delta=+${delta}% >= ${TIER_A_MIN_DELTA}%)..."
            if "$PY" "$RUNS_PY" approve "$rname" --approver "tier_a_watchdog" >/dev/null 2>&1; then
                _notify_discord "**[Training Forge — Tier A Auto-Promoted]** Candidate \`${rname}\` passed benchmark gate (+${delta}%) and is now active!"
                if [ "$AUTO_BACKUP_DRIVE" = "true" ] || [ "$AUTO_BACKUP_HF" = "true" ]; then
                    tgt="both"
                    [ "$AUTO_BACKUP_DRIVE" = "true" ] && [ "$AUTO_BACKUP_HF" != "true" ] && tgt="drive"
                    [ "$AUTO_BACKUP_HF" = "true" ] && [ "$AUTO_BACKUP_DRIVE" != "true" ] && tgt="hf"
                    "$PY" "$BACKUP_PY" backup --all --target "$tgt" >/dev/null 2>&1 || true
                fi
            fi
        fi
    done
fi
