#!/usr/bin/env bash
# ── George Golden-Task Eval Harness ──────────────────────────────────
# Replays tests/eval/golden_tasks.json through the REAL Discord bridge
# entrypoint (discord_generate_response) in DRY-RUN mode, then scores.
#
# Dry-run isolation:
#   * All social egress tokens are overridden via env with invalid values
#     (api_get_key checks env first) -> nothing is posted anywhere.
#   * Discord session/history/media dirs + reputation/profile DBs are
#     redirected into the eval run dir (copies of live DBs, so tiers match).
#   * Cron jobs created during a task are moved out of .george/cron_jobs into
#     the task dir; new cron_state.json keys are removed; eval job names are
#     temporarily disabled in cron.conf so the daemon never fires them.
#   * fs_guard tasks snapshot the guarded dir and restore it afterwards.
#
# Usage: tests/eval/run_golden.sh [--label NAME] [--tier smoke|full] [--timeout SECS] [--force]
#                                 [--resume RUN_DIR] [TASK_ID ...]
#   --tier:    smoke = fast subset (~15-20 min), full = every task (default)
#   --timeout: override every task's timeout (default: per-category from golden_tasks.json)
#   --force:   run even when evals are disabled (.george/state/eval.disabled; see /eval off)
#   --resume: continue a crashed run in place; tasks that already have meta.json are skipped.
# Output: .george/eval/<ts>_<label>/{<task>/..., metrics.json, summary.md}
set -uo pipefail

LODGE_DIR="${LODGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export LODGE_DIR
GEORGE_DIR_LIVE="${EVAL_GEORGE_DIR:-$LODGE_DIR/.george}"
TASKS_FILE="$LODGE_DIR/tests/eval/golden_tasks.json"
PY="$LODGE_DIR/.venv/bin/python"; [ -x "$PY" ] || PY=python3

LABEL="run"; TASK_TIMEOUT="${EVAL_TASK_TIMEOUT:-}"; SELECT=(); RESUME=""; TIER="full"; FORCE=0; LIST_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --timeout) TASK_TIMEOUT="$2"; shift 2 ;;
        --tier) TIER="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --resume) RESUME="$2"; shift 2 ;;
        *) SELECT+=("$1"); shift ;;
    esac
done
[[ "$LABEL" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || { echo "invalid --label" >&2; exit 2; }
[ -z "$TASK_TIMEOUT" ] || [[ "$TASK_TIMEOUT" =~ ^[0-9]{2,5}$ ]] || { echo "invalid --timeout" >&2; exit 2; }
case "$TIER" in smoke|full) ;; *) echo "invalid --tier (smoke|full)" >&2; exit 2 ;; esac

# ── Kill switch (resource-heavy on a shared GPU) ──────────────────────────────
if [ -f "$GEORGE_DIR_LIVE/state/eval.disabled" ] && [ "$FORCE" -ne 1 ]; then
    echo "[eval] evals are disabled ($(head -c 200 "$GEORGE_DIR_LIVE/state/eval.disabled" 2>/dev/null)). Use /eval on, or --force."
    exit 0
fi

# Per-task timeout: --timeout override, else category_timeouts[category], else 1500.
task_timeout_for() {
    if [ -n "$TASK_TIMEOUT" ]; then echo "$TASK_TIMEOUT"; return; fi
    jq -r --arg c "$1" '.category_timeouts[$c] // 1500' "$TASKS_FILE"
}

if [ "$LIST_ONLY" -eq 1 ]; then
    total=0
    while IFS=$'\t' read -r id cat; do
        [ "${#SELECT[@]}" -gt 0 ] && [[ " ${SELECT[*]} " != *" $id "* ]] && continue
        t=$(task_timeout_for "$cat"); total=$((total + t))
        printf '%s\t%s\t%s\n' "$id" "$cat" "$t"
    done < <(jq -r --arg tier "$TIER" '.tasks[] | select($tier == "full" or (.tier // "full") == $tier) | [.id, .category] | @tsv' "$TASKS_FILE")
    echo "max_wall_s	$total"
    exit 0
fi

EVAL_ROOT="$GEORGE_DIR_LIVE/eval"
if [ -n "$RESUME" ]; then
    RUN_DIR="$(cd "$RESUME" 2>/dev/null && pwd)" || { echo "invalid --resume dir" >&2; exit 2; }
    case "$RUN_DIR" in "$EVAL_ROOT"/*) ;; *) echo "--resume must be under $EVAL_ROOT" >&2; exit 2 ;; esac
else
    RUN_DIR="$EVAL_ROOT/$(date +%Y%m%d_%H%M%S)_${LABEL}"
fi
mkdir -p "$RUN_DIR"
PIDFILE="$EVAL_ROOT/.harness.pid"

# ── Single-instance guard (never two George eval runs on the GPU) ─────
if [ -f "$PIDFILE" ]; then
    old=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        echo "[eval] stale harness PID $old running — terminating it first"
        kill -TERM -- "-$old" 2>/dev/null || kill -TERM "$old" 2>/dev/null || true
        sleep 3
    fi
fi
echo $$ > "$PIDFILE"

# ── Cron daemon protection ───────────────────────────────────────────
CRON_CONF="$GEORGE_DIR_LIVE/cron.conf"
CRON_CONF_BAK="$RUN_DIR/.cron.conf.bak"
EVAL_CRON_NAMES=$(jq -r '[.tasks[].expect.cron_job // empty] | join(",")' "$TASKS_FILE")

# Quarantine eval_* cron jobs/state left behind by a crashed harness (host OOM, reboot).
sweep_eval_leftovers() {
    local dest="$RUN_DIR/.leftovers" f n=0
    mkdir -p "$dest"
    for f in "$GEORGE_DIR_LIVE"/cron_jobs/eval_*.sh; do
        [ -f "$f" ] || continue
        mv "$f" "$dest/" && n=$((n+1))
    done
    if [ -f "$GEORGE_DIR_LIVE/cron_state.json" ] && \
       jq -e '(.jobs // {}) | keys | any(startswith("eval_"))' "$GEORGE_DIR_LIVE/cron_state.json" >/dev/null 2>&1; then
        jq '.jobs |= with_entries(select(.key | startswith("eval_") | not))' "$GEORGE_DIR_LIVE/cron_state.json" \
            > "$GEORGE_DIR_LIVE/cron_state.json.evaltmp" && mv "$GEORGE_DIR_LIVE/cron_state.json.evaltmp" "$GEORGE_DIR_LIVE/cron_state.json"
        n=$((n+1))
    fi
    [ "$n" -gt 0 ] && echo "[eval] quarantined $n eval_* leftover(s) into $dest"
    return 0
}
sweep_eval_leftovers
# On resume, prefer the original pre-run cron.conf backup (the crash may have left eval names disabled).
[ -f "$CRON_CONF" ] && [ ! -f "$CRON_CONF_BAK" ] && cp -p "$CRON_CONF" "$CRON_CONF_BAK"
[ -f "$CRON_CONF_BAK" ] && cp -p "$CRON_CONF_BAK" "$CRON_CONF"
if [ -n "$EVAL_CRON_NAMES" ]; then
    cur=$(grep -E '^CRON_DISABLED_JOBS=' "$CRON_CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    newval="${cur:+$cur,}$EVAL_CRON_NAMES"
    if grep -qE '^CRON_DISABLED_JOBS=' "$CRON_CONF" 2>/dev/null; then
        sed -i "s|^CRON_DISABLED_JOBS=.*|CRON_DISABLED_JOBS=\"$newval\"|" "$CRON_CONF"
    else
        echo "CRON_DISABLED_JOBS=\"$newval\"" >> "$CRON_CONF"
    fi
fi

cleanup() {
    sweep_eval_leftovers
    [ -f "$CRON_CONF_BAK" ] && cp -p "$CRON_CONF_BAK" "$CRON_CONF"
    rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM

# ── Isolation env ────────────────────────────────────────────────────
ISO="$RUN_DIR/.iso"; mkdir -p "$ISO/discord_sessions/history" "$ISO/discord_media"
[ -f "$ISO/reputation.db" ] || cp -p "$GEORGE_DIR_LIVE/reputation.db" "$ISO/reputation.db" 2>/dev/null || true
[ -f "$ISO/discord_profiles.db" ] || cp -p "$GEORGE_DIR_LIVE/discord_profiles.db" "$ISO/discord_profiles.db" 2>/dev/null || true
export LODGE_EVAL=1 LODGE_NONINTERACTIVE=1 DISCORD_STATUS_ENABLED=0 DISCORD_API_BASE="http://127.0.0.1:9/eval-dry-run"
export DISCORD_SESSIONS_DIR="$ISO/discord_sessions" DISCORD_HISTORY_DIR="$ISO/discord_sessions/history"
export DISCORD_MEDIA_DIR="$ISO/discord_media" REPUTATION_DB="$ISO/reputation.db" DISCORD_PROFILES_DB="$ISO/discord_profiles.db"
for k in DISCORD_BOT_TOKEN TELEGRAM_BOT_TOKEN MASTODON_ACCESS_TOKEN X_BEARER_TOKEN X_ACCESS_TOKEN \
         X_ACCESS_TOKEN_SECRET X_API_KEY X_API_SECRET X_AUTH_TOKEN X_CONSUMER_KEY X_CONSUMER_SECRET X_CT; do
    export "$k=eval-dry-run-invalid"
done
export DISCORD_WEBHOOK_URL="http://127.0.0.1:9/eval-dry-run"

OP_NAME=$(jq -r '.operator_author.name' "$TASKS_FILE"); OP_ID=$(jq -r '.operator_author.id' "$TASKS_FILE")
if [ "$OP_ID" = "@owner" ]; then
    _owners="${DISCORD_OWNER_IDS:-$(sed -n 's/^DISCORD_OWNER_IDS=//p' "${GEORGE_DIR_LIVE:-$LODGE_DIR/.george}/keys.conf" 2>/dev/null | tr -d "\"' ")}"
    OP_ID="${_owners%%,*}"
    [ -n "$OP_ID" ] || { echo "run_golden: operator_author.id is @owner but DISCORD_OWNER_IDS is not set" >&2; exit 2; }
fi
ST_NAME=$(jq -r '.stranger_author.name' "$TASKS_FILE"); ST_ID=$(jq -r '.stranger_author.id' "$TASKS_FILE")
EVAL_CHANNEL="000000000000000001"

git -C "$LODGE_DIR" rev-parse --short HEAD > "$RUN_DIR/git_rev" 2>/dev/null || true
cp -p "$TASKS_FILE" "$RUN_DIR/golden_tasks.json"

# Names of background cron jobs currently running (they share the single-slot LLM with the agent)
background_cron_jobs() {
    pgrep -af "$GEORGE_DIR_LIVE/cron_jobs/" 2>/dev/null | grep -oE 'cron_jobs/[A-Za-z0-9_.-]+\.sh' \
        | sed 's|cron_jobs/||; s|\.sh$||' | grep -v '^eval_' | sort -u
}

run_task() {
    local tid="$1" tdir="$RUN_DIR/$1"
    mkdir -p "$tdir/cron_created"
    local prompt author author_id cat fs_guard
    prompt=$(jq -r --arg id "$tid" '.tasks[] | select(.id==$id) | .prompt' "$TASKS_FILE")
    cat=$(jq -r --arg id "$tid" '.tasks[] | select(.id==$id) | .category' "$TASKS_FILE")
    local tto; tto=$(task_timeout_for "$cat")
    fs_guard=$(jq -r --arg id "$tid" '.tasks[] | select(.id==$id) | .expect.fs_guard // empty' "$TASKS_FILE")
    if [ "$(jq -r --arg id "$tid" '.tasks[] | select(.id==$id) | .author' "$TASKS_FILE")" = "stranger" ]; then
        author="$ST_NAME"; author_id="$ST_ID"
    else
        author="$OP_NAME"; author_id="$OP_ID"
    fi

    # Snapshots
    ls -1 "$GEORGE_DIR_LIVE/cron_jobs" 2>/dev/null | sort > "$tdir/.cron_before"
    jq -r '(.jobs // {}) | keys[]' "$GEORGE_DIR_LIVE/cron_state.json" 2>/dev/null | sort > "$tdir/.cronstate_before" || true
    local guard_tar="" guard_sum_before=""
    if [ -n "$fs_guard" ] && [ -d "$LODGE_DIR/$fs_guard" ]; then
        guard_tar="$tdir/.fs_guard.tar"
        tar -C "$LODGE_DIR" -cf "$guard_tar" "$fs_guard" 2>/dev/null
        # Damage = pre-existing files deleted or truncated. Normal memory writes
        # (new/modified files) during the run are not damage. NUL-delimited: memory filenames can contain newlines.
        find "$LODGE_DIR/$fs_guard" -type f -size +0 -print0 2>/dev/null | sort -z > "$tdir/.fs_guard_before"
        guard_sum_before=$(tr -cd '\0' < "$tdir/.fs_guard_before" | wc -c)
    fi

    echo "[eval] ▶ $tid ($cat) — timeout ${tto}s"
    local t0; t0=$(date +%s.%N)
    # The agent gets a wall budget 60 s under the hard kill so it converges and replies
    # instead of being killed mid-research (react.sh: advisory at 70%, final turn at 85%).
    REACT_WALL_BUDGET_S=$(( tto > 120 ? tto - 60 : tto )) setsid bash -c '
        source "$LODGE_DIR/lib/comms/discord_bridge.sh" 2>/dev/null
        source "$LODGE_DIR/lib/core/context_engine.sh" 2>/dev/null
        discord_bridge_init >/dev/null 2>&1 || true
        discord_generate_response "$1" "$2" "$3" "" "$4" "$5" "$6"
    ' _ "$prompt" "$EVAL_CHANNEL" "$author" "$tdir/session.log" "$author_id" "$tdir/reply.txt" \
        > "$tdir/stdout.log" 2>&1 &
    local pid=$! timed_out=false deadline contention=""
    deadline=$(( $(date +%s) + tto ))
    while kill -0 "$pid" 2>/dev/null; do
        contention=$(printf '%s\n%s\n' "$contention" "$(background_cron_jobs)" | grep -v '^$' | sort -u)
        if [ "$(date +%s)" -ge "$deadline" ]; then
            timed_out=true
            kill -TERM -- "-$pid" 2>/dev/null; sleep 10; kill -KILL -- "-$pid" 2>/dev/null
            break
        fi
        sleep 5
    done
    wait "$pid" 2>/dev/null
    local rc=$?
    local wall; wall=$(echo "$(date +%s.%N) - $t0" | bc)

    # Collect raw react log for this session (bridge writes it under DISCORD_SESSIONS_DIR/<uuid>/)
    local raw; raw=$(find "$DISCORD_SESSIONS_DIR" -maxdepth 2 -name raw_react.log -newer "$tdir/.cron_before" 2>/dev/null | head -1)
    [ -n "$raw" ] && cp "$raw" "$tdir/raw_react.log"

    # Quarantine cron side effects
    ls -1 "$GEORGE_DIR_LIVE/cron_jobs" 2>/dev/null | sort > "$tdir/.cron_after"
    local syntax_json="{}"
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        mv "$GEORGE_DIR_LIVE/cron_jobs/$f" "$tdir/cron_created/" 2>/dev/null || continue
        local ok=false; bash -n "$tdir/cron_created/$f" 2>/dev/null && ok=true
        syntax_json=$(echo "$syntax_json" | jq --arg k "${f%.sh}" --argjson v "$ok" '. + {($k): $v}')
    done < <(comm -13 "$tdir/.cron_before" "$tdir/.cron_after")
    jq -r '(.jobs // {}) | keys[]' "$GEORGE_DIR_LIVE/cron_state.json" 2>/dev/null | sort > "$tdir/.cronstate_after" || true
    local newkeys; newkeys=$(comm -13 "$tdir/.cronstate_before" "$tdir/.cronstate_after" | jq -R . | jq -sc .)
    if [ "$newkeys" != "[]" ] && [ -f "$GEORGE_DIR_LIVE/cron_state.json" ]; then
        jq --argjson ks "$newkeys" '.jobs |= with_entries(select(.key as $k | ($ks | index($k)) | not))' \
            "$GEORGE_DIR_LIVE/cron_state.json" > "$GEORGE_DIR_LIVE/cron_state.json.evaltmp" \
            && mv "$GEORGE_DIR_LIVE/cron_state.json.evaltmp" "$GEORGE_DIR_LIVE/cron_state.json"
    fi

    # fs_guard verification + restore
    local damaged=false
    if [ -n "$guard_tar" ]; then
        local lost=0 f
        while IFS= read -r -d '' f; do
            [ -s "$f" ] || lost=$((lost + 1))
        done < "$tdir/.fs_guard_before"
        if [ "$lost" -gt 0 ]; then
            damaged=true
            echo "[eval] ⚠ fs_guard: $lost of $guard_sum_before pre-existing files in $fs_guard deleted/truncated — restoring snapshot"
            tar -C "$LODGE_DIR" -xf "$guard_tar" 2>/dev/null
        fi
        rm -f "$guard_tar" "$tdir/.fs_guard_before"
    fi

    jq -n --arg id "$tid" --argjson wall "$wall" --argjson to "$timed_out" --argjson rc "$rc" --argjson tto "$tto" \
          --argjson syn "$syntax_json" --argjson dmg "$damaged" --argjson newkeys "$newkeys" \
          --argjson cont "$(printf '%s' "$contention" | jq -R . | jq -sc 'map(select(length>0))')" \
          '{id:$id, wall_s:($wall|floor), timeout_s:$tto, timed_out:$to, exit:$rc, cron_syntax:$syn, fs_guard_damaged:$dmg, cron_state_keys_removed:$newkeys, llm_contention:$cont}' \
          > "$tdir/meta.json"
    echo "[eval] ■ $tid done in ${wall%.*}s (timed_out=$timed_out)"
}

mapfile -t ALL_IDS < <(jq -r --arg tier "$TIER" '.tasks[] | select($tier == "full" or (.tier // "full") == $tier) | .id' "$TASKS_FILE")
IDS=("${SELECT[@]:-${ALL_IDS[@]}}")
echo "$TIER" > "$RUN_DIR/tier"
echo "[eval] tier=$TIER tasks=${#IDS[@]}"
for tid in "${IDS[@]}"; do
    jq -e --arg id "$tid" '.tasks[] | select(.id==$id)' "$TASKS_FILE" >/dev/null || { echo "[eval] unknown task $tid"; continue; }
    if [ -n "$RESUME" ] && [ -s "$RUN_DIR/$tid/meta.json" ]; then
        echo "[eval] ↷ $tid already collected — skipping (resume)"; continue
    fi
    # Yield to live Discord sessions (shared GPU)
    while [ "$(bash -c 'source "$0/lib/comms/discord_bridge.sh" 2>/dev/null; DISCORD_SESSIONS_DIR="$1" discord_get_active_task_count' "$LODGE_DIR" "$GEORGE_DIR_LIVE/discord_sessions" 2>/dev/null || echo 0)" -gt 0 ]; do
        echo "[eval] live Discord task active — waiting 60s"; sleep 60
    done
    # cron_tick defers new sweeps while this harness is alive; wait (bounded) for jobs already in flight
    _cw=0
    while [ -n "$(background_cron_jobs)" ] && [ "$_cw" -lt "${EVAL_CRON_WAIT_S:-900}" ]; do
        [ "$_cw" -eq 0 ] && echo "[eval] waiting for in-flight cron job(s): $(background_cron_jobs | tr '\n' ' ')"
        sleep 15; _cw=$((_cw + 15))
    done
    run_task "$tid"
done

"$PY" "$LODGE_DIR/tests/eval/score_golden.py" "$RUN_DIR" "$TASKS_FILE" "$GEORGE_DIR_LIVE/keys.conf"
echo "[eval] results: $RUN_DIR/summary.md"
