#!/bin/bash
# ── Nightly golden eval (refinement plan) ──
# INTERVAL: 3600
# ENABLED: 0
# DESC: Nightly 03:00 smoke-tier golden eval (dry-run Discord bridge); ships OFF — /eval nightly on
#
# Install/enable: /eval nightly on   (kill switch: /eval off)
# Never named eval_* (run_golden.sh quarantines eval_* cron jobs).
# Launches the harness detached so the cron loop is not blocked for hours.

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
STAMP="$GEORGE_DIR/state/nightly_eval.last"
HOUR="${NIGHTLY_EVAL_HOUR:-03}"

[ "$(date +%H)" = "$HOUR" ] || exit 0
[ "$(cat "$STAMP" 2>/dev/null)" = "$(date +%F)" ] && exit 0
[ -f "$GEORGE_DIR/state/eval.disabled" ] && { echo "[nightly_eval] evals disabled — skipping"; exit 0; }

# Never pre-empt a running eval (the harness would kill it) or a live Discord task.
pid=$(cat "$GEORGE_DIR/eval/.harness.pid" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "[nightly_eval] eval already running (pid $pid) — skipping"; exit 0
fi
active=$(bash -c 'source "$0/lib/comms/discord_bridge.sh" 2>/dev/null; DISCORD_SESSIONS_DIR="$1" discord_get_active_task_count' \
    "$LODGE_DIR" "$GEORGE_DIR/discord_sessions" 2>/dev/null || echo 0)
if [ "${active:-0}" -gt 0 ]; then
    echo "[nightly_eval] live Discord task active — retry next tick"; exit 0
fi

mkdir -p "$GEORGE_DIR/state"
date +%F > "$STAMP"
unset LODGE_CRON_JOB   # harness isolates its own env; keep run labels clean
setsid nohup bash "$LODGE_DIR/tests/eval/run_golden.sh" --tier "${NIGHTLY_EVAL_TIER:-smoke}" --label nightly \
    </dev/null >> "$GEORGE_DIR/eval/nightly.log" 2>&1 &
echo "[nightly_eval] launched golden eval (pid $!)"
