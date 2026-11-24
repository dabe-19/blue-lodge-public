#!/bin/bash
# ── Sovereign 3-Hour OSINT & SDR SIGINT Intel Digest (ReAct-summarized) ──
# INTERVAL: 10800
# ENABLED: 1
# SCOPE: system
# DESC: Every-3-hours capture of the multi-domain OSINT intel feed (AI, AI-POL, MIL,
#       MIL-TECH, GEO-UA, GEO-ME, CRYPTO, SCIENCE, TECH) + Local P25 SDR SIGINT
#       (statistical communications telemetry & Gemma-4 E4B multimodal cleaned
#       transcriptions/summaries from sdr_intel.db), then kicks off a sandboxed
#       one-shot ReAct agentic run that curates and delivers a concise summarized
#       digest to the operator's Discord DM.
# NOTE (remediation 80cfc3d933bb): the digest character cap is enforced
#       deterministically by lib/tools/digest_check.sh (validate/trim loop).

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SECRETS_FILE="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/secrets.env"
KEYS_FILE="${GEORGE_CONFIG_DIR:-${LODGE_DIR}/.george}/keys.conf"
[ -f "$SECRETS_FILE" ] && set -a && . "$SECRETS_FILE" 2>/dev/null && set +a || true
[ -f "$KEYS_FILE" ] && set -a && . "$KEYS_FILE" 2>/dev/null && set +a || true
TARGET_DM_USER="${DISCORD_OPERATOR_ID:-${DISCORD_DM_USER_ID:-operator}}"
SDR_LABEL="${SDR_SYSTEM_LABEL:-Local P25}"
LOG_FILE="${CRON_JOB_LOG:-$LODGE_DIR/.george/logs/cron/trading_reporter.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
REPORT_FILE="/tmp/osint_digest_src_$(date +%Y%m%d_%H%M).md"

# 1. Capture fresh market + multi-domain intel articles + 3-hour SDR SIGINT summary
# Use venv python (has PyYAML); system python3 may lack it (incident 2026-11-02 23:33 UTC: 0-byte capture)
CAP_PY="$LODGE_DIR/.venv/bin/python"
[ -x "$CAP_PY" ] || CAP_PY="python3"
echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Capturing 3-hour OSINT & SDR SIGINT intel feed -> $REPORT_FILE" >>"$LOG_FILE" 2>&1
if [ -f "$LODGE_DIR/lib/tools/trading_bot.py" ]; then
    "$CAP_PY" "$LODGE_DIR/lib/tools/trading_bot.py" --report > "$REPORT_FILE" 2>>"$LOG_FILE"
else
    echo "Sovereign OSINT Digest — $(date -u +%FT%TZ)" > "$REPORT_FILE"
fi

# Keep the log bounded (retain last 150 lines so real errors are inspectable)
tail -n 150 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE"

# 2. Workspace lock guard: wait up to 900s if another lodge task holds .lodge.lock
#    (prevents immediate RC=1 lock-collision fallback dumps).
LOCK_FILE="${GEORGE_CONFIG_DIR:-$LODGE_DIR/.george}/.lodge.lock"
LOCK_WAIT_MAX="${TRADING_REPORTER_LOCK_WAIT:-900}"
LOCK_POLL_SECS=15
LOCK_ELAPSED=0
while [ -f "$LOCK_FILE" ]; do
    lock_owner="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [ -z "$lock_owner" ] || ! kill -0 "$lock_owner" 2>/dev/null; then
        rm -f "$LOCK_FILE" 2>/dev/null || true
        break
    fi
    if [ "$LOCK_ELAPSED" -ge "$LOCK_WAIT_MAX" ]; then
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [WARN] Workspace lock still held by PID $lock_owner after ${LOCK_WAIT_MAX}s" >>"$LOG_FILE" 2>&1
        break
    fi
    sleep "$LOCK_POLL_SECS"
    LOCK_ELAPSED=$((LOCK_ELAPSED + LOCK_POLL_SECS))
done

# 3. Kick off a sandboxed one-shot agentic ReAct execution via the /lodge binary.
TASK="You are generating the 3-Hour OSINT & SDR SIGINT Intel Digest for the Blue Lodge operator. Step 1: Read the captured OSINT + SDR report at '${REPORT_FILE}' (markdown). Step 2: From the 'INTEL FEED' section, select the 5 to 8 most important articles across ALL domain tags (AI, AI-POL, MIL, MIL-TECH, GEO-UA, GEO-ME, CRYPTO, SCIENCE, TECH) — prioritize items with strategic significance, hard numbers, or cross-domain signal. Step 3: Read the 'LOCAL P25 SDR SIGINT & COMMUNICATIONS TELEMETRY' section and include a dedicated '📻 Local SDR SIGINT (${SDR_LABEL})' block containing: (a) 1-line statistical summary (total transmissions, intelligible voice vs filtered bursts, total airtime, active radio units, top channels) and (b) 2 to 4 bullet lines of the most notable intelligible dispatches using their Gemma-4 E4B tactical summary and cleaned transcript (never include unintelligible carrier bursts). Step 4: Compose the curated digest (a 2-3 line 'Key themes' takeaway at the top, the selected global OSINT items formatted as '[TAG] 1-sentence summary — [headline](url)', and the '📻 Local SDR SIGINT' block at the bottom) and send it ONCE to the operator's Discord DM (target: '${TARGET_DM_USER}') using the discord_send tool with target '${TARGET_DM_USER}', prefixed with '⚔️ 3-Hour OSINT & SDR SIGINT Digest — <HH:MM UTC>'. Note: discord_send automatically splits messages over 2,000 characters on line boundaries, so do NOT count characters, run trim scripts, or rewrite drafts to fit a character limit."

RUN_OUT="/tmp/osint_digest_run_$(date +%Y%m%d_%H%M)_$$.log"
"$LODGE_DIR/lodge" "$TASK" >"$RUN_OUT" 2>&1
RC=$?
cat "$RUN_OUT" >>"$LOG_FILE" 2>/dev/null || true

# 4. Fallback safety net: ONLY if the ReAct digest run failed AND did not already
#    deliver the digest to Discord during the run, ship a compact fallback digest.
if [ "$RC" -ne 0 ] && ! grep -q "Sent to Discord" "$RUN_OUT" 2>/dev/null; then
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [FALLBACK] ReAct digest run failed before delivery (rc=$RC) — shipping compact fallback via --send-dm" >>"$LOG_FILE" 2>&1
    "$CAP_PY" "$LODGE_DIR/lib/tools/trading_bot.py" --send-dm --user "$TARGET_DM_USER" >>"$LOG_FILE" 2>&1
fi
rm -f "$RUN_OUT" 2>/dev/null || true
