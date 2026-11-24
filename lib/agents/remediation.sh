#!/bin/bash
# ── George: Sovereign Autonomous Remediation Loop ─────────────────────
# Manages the prioritized remediation queue, isolated worktree sandboxes,
# Slot 1 inference execution, issue reconciliation & archival,
# and configurable operator notification via Email (Gmail) and Discord.
#
# State:
#   Queue:        .george/remediation/queue/
#   In Progress:  .george/remediation/in_progress/
#   Completed:    .george/remediation/completed/
#   Failed:       .george/remediation/failed/
#   Config:       .george/remediation/notifications.conf

[ -n "${_LIB_REMEDIATION_LOADED:-}" ] && return 0; _LIB_REMEDIATION_LOADED=1

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
GEORGE_DIR="${GEORGE_DIR:-${LODGE_DIR}/.george}"
REMEDIATION_DIR="${REMEDIATION_DIR:-$GEORGE_DIR/remediation}"
REMEDIATION_QUEUE_DIR="${REMEDIATION_DIR}/queue"
REMEDIATION_PROGRESS_DIR="${REMEDIATION_DIR}/in_progress"
REMEDIATION_COMPLETED_DIR="${REMEDIATION_DIR}/completed"
REMEDIATION_FAILED_DIR="${REMEDIATION_DIR}/failed"
REMEDIATION_LOGS_DIR="${REMEDIATION_DIR}/logs"
REMEDIATION_ATTEMPTS_DIR="${REMEDIATION_DIR}/attempts"
REMEDIATION_CONF="${REMEDIATION_DIR}/notifications.conf"

LODGE_ROOT="${LODGE_ROOT:-$HOME/blue-lodge}"
for _p in "$LODGE_DIR" "$LODGE_ROOT" "$HOME/blue-lodge"; do
    if [ -f "$_p/lib/ui/ui.sh" ]; then
        source "$_p/lib/ui/ui.sh" 2>/dev/null || true
        source "$_p/lib/ipc/fifo_ipc.sh" 2>/dev/null || true
        source "$_p/lib/agents/telemetry.sh" 2>/dev/null || true
        source "$_p/lib/comms/email.sh" 2>/dev/null || true
        source "$_p/lib/comms/social.sh" 2>/dev/null || true
        source "$_p/lib/comms/discord_bridge.sh" 2>/dev/null || true
        source "$_p/lib/ui/popup.sh" 2>/dev/null || true
        source "$_p/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
        source "$_p/lib/comms/mqtt.sh" 2>/dev/null || true
        source "$_p/lib/sys/sandbox.sh" 2>/dev/null || true
        break
    fi
done

declare -f ui_err &>/dev/null || ui_err() { echo "[ERR] $*" >&2; }
declare -f ui_ok &>/dev/null || ui_ok() { echo "[OK] $*"; }
declare -f ui_warn &>/dev/null || ui_warn() { echo "[WARN] $*" >&2; }
declare -f ui_step &>/dev/null || ui_step() { echo "[STEP] $*"; }
declare -f ui_info &>/dev/null || ui_info() { echo "[INFO] $*"; }
declare -f ui_dim &>/dev/null || ui_dim() { echo "[DIM] $*"; }
declare -f ui_section &>/dev/null || ui_section() { echo "=== $* ==="; }

remediation_init() {
    mkdir -p "$REMEDIATION_QUEUE_DIR" "$REMEDIATION_PROGRESS_DIR" "$REMEDIATION_COMPLETED_DIR" "$REMEDIATION_FAILED_DIR" "$REMEDIATION_LOGS_DIR" "$REMEDIATION_ATTEMPTS_DIR" 2>/dev/null || true
    declare -f mqtt_init &>/dev/null && mqtt_init || true
    remediation_notify_load_config
    remediation_sweep_sandboxes
}

# Sweeps and culls orphaned ephemeral git worktrees in .sandboxes/
remediation_sweep_sandboxes() {
    local sandboxes_dir="${LODGE_DIR}/.sandboxes"
    [ ! -d "$sandboxes_dir" ] && return 0
    local active_pid=""
    if [ -f "$REMEDIATION_DIR/.lock" ]; then
        active_pid=$(cat "$REMEDIATION_DIR/.lock" 2>/dev/null)
    fi

    local _old_nullglob
    shopt -q nullglob 2>/dev/null && _old_nullglob=1 || _old_nullglob=0
    shopt -s nullglob 2>/dev/null || true

    for sb_dir in "$sandboxes_dir"/remediation_*; do
        [ ! -d "$sb_dir" ] && continue
        # If no remediation lock or PID is not running, cull worktree
        if [ -z "$active_pid" ] || ! kill -0 "$active_pid" 2>/dev/null; then
            ui_dim "Culling orphaned ephemeral sandbox: $sb_dir"
            git -C "$LODGE_DIR" worktree remove --force "$sb_dir" >/dev/null 2>&1 || true
            rm -rf "$sb_dir" 2>/dev/null || true
        fi
    done
    [ "$_old_nullglob" -eq 0 ] && shopt -u nullglob 2>/dev/null || true
    git -C "$LODGE_DIR" worktree prune >/dev/null 2>&1 || true
}

# ── 1. Configurable Notifications (Email & Discord) ───────────────────
# Loads notification config with configurable email and discord parameters
remediation_notify_load_config() {
    # Default parameters (purely configurable, zero hardcoded identities)
    REMEDIATION_NOTIFY_EMAIL="${REMEDIATION_NOTIFY_EMAIL:-}"
    REMEDIATION_EMAIL_PROVIDER="${REMEDIATION_EMAIL_PROVIDER:-gmail}"
    REMEDIATION_NOTIFY_DISCORD="${REMEDIATION_NOTIFY_DISCORD:-}"
    REMEDIATION_DISCORD_SERVER="${REMEDIATION_DISCORD_SERVER:-}"
    REMEDIATION_NOTIFY_CHANNEL="${REMEDIATION_NOTIFY_CHANNEL:-}"
    REMEDIATION_NOTIFY_ENABLED="${REMEDIATION_NOTIFY_ENABLED:-1}"

    if [ -f "$REMEDIATION_CONF" ]; then
        # Parse simple key=value pairs safely without eval
        local _ckey _cval
        while IFS='=' read -r _ckey _cval; do
            [[ "$_ckey" =~ ^[[:space:]]*# ]] && continue
            [ -z "$_ckey" ] && continue
            _ckey=$(echo "$_ckey" | tr -d '[:space:]')
            _cval=$(echo "$_cval" | sed 's/^[[:space:]]*["'"'"']//; s/["'"'"'][[:space:]]*$//')
            case "$_ckey" in
                REMEDIATION_NOTIFY_EMAIL) REMEDIATION_NOTIFY_EMAIL="$_cval" ;;
                REMEDIATION_EMAIL_PROVIDER) REMEDIATION_EMAIL_PROVIDER="$_cval" ;;
                REMEDIATION_NOTIFY_DISCORD) REMEDIATION_NOTIFY_DISCORD="$_cval" ;;
                REMEDIATION_DISCORD_SERVER) REMEDIATION_DISCORD_SERVER="$_cval" ;;
                REMEDIATION_NOTIFY_CHANNEL) REMEDIATION_NOTIFY_CHANNEL="$_cval" ;;
                REMEDIATION_NOTIFY_ENABLED) REMEDIATION_NOTIFY_ENABLED="$_cval" ;;
            esac
        done < "$REMEDIATION_CONF"
    else
        # Seed default config file template
        remediation_notify_save_all
    fi
}

remediation_notify_save_all() {
    mkdir -p "$(dirname "$REMEDIATION_CONF")" 2>/dev/null || true
    cat << EOF > "$REMEDIATION_CONF"
# Sovereign Remediation Notification Configuration
# Update via: /remediation notify set <key> <val>
# Clear via:  /remediation notify clear <key>
REMEDIATION_NOTIFY_EMAIL="${REMEDIATION_NOTIFY_EMAIL:-}"
REMEDIATION_EMAIL_PROVIDER="${REMEDIATION_EMAIL_PROVIDER:-gmail}"
REMEDIATION_NOTIFY_DISCORD="${REMEDIATION_NOTIFY_DISCORD:-}"
REMEDIATION_DISCORD_SERVER="${REMEDIATION_DISCORD_SERVER:-}"
REMEDIATION_NOTIFY_CHANNEL="${REMEDIATION_NOTIFY_CHANNEL:-}"
REMEDIATION_NOTIFY_ENABLED="${REMEDIATION_NOTIFY_ENABLED:-1}"
EOF
}

remediation_notify_set() {
    local key="$1"
    local val="$2"
    remediation_init

    # Allow clearing/unsetting with empty string or keywords
    if [ "$val" = "none" ] || [ "$val" = "unset" ] || [ "$val" = "clear" ] || [ "$val" = "null" ]; then
        val=""
    fi

    case "$key" in
        email|mail|REMEDIATION_NOTIFY_EMAIL)
            REMEDIATION_NOTIFY_EMAIL="$val"
            ;;
        provider|email_provider|REMEDIATION_EMAIL_PROVIDER)
            REMEDIATION_EMAIL_PROVIDER="${val:-gmail}"
            ;;
        discord|user|discord_user|REMEDIATION_NOTIFY_DISCORD)
            REMEDIATION_NOTIFY_DISCORD="$val"
            ;;
        server|discord_server|guild|REMEDIATION_DISCORD_SERVER)
            REMEDIATION_DISCORD_SERVER="$val"
            ;;
        channel|discord_channel|REMEDIATION_NOTIFY_CHANNEL)
            REMEDIATION_NOTIFY_CHANNEL="$val"
            ;;
        enabled|REMEDIATION_NOTIFY_ENABLED)
            REMEDIATION_NOTIFY_ENABLED="$val"
            ;;
        *)
            ui_err "Unknown config key: $key (valid: email, provider, discord, server, channel, enabled)"
            return 1
            ;;
    esac

    remediation_notify_save_all
    ui_ok "Remediation notification updated: $key = ${val:-<cleared>}"
}

remediation_notify_show() {
    remediation_init
    printf "\n${C_BOLD}${C_CYAN}── Remediation Notification Configuration ──────────────────${C_RESET}\n"
    printf "  Config File:    %s\n" "$REMEDIATION_CONF"
    printf "  Notifications:  %s\n" "$([ "${REMEDIATION_NOTIFY_ENABLED:-1}" = "1" ] && echo "${C_GREEN}ENABLED${C_RESET}" || echo "${C_RED}DISABLED${C_RESET}")"
    printf "  Email Target:   %s (via %s)\n" "${REMEDIATION_NOTIFY_EMAIL:-<not configured>}" "${REMEDIATION_EMAIL_PROVIDER:-gmail}"
    printf "  Discord Target: %s\n" "$([ -n "$REMEDIATION_NOTIFY_DISCORD" ] && echo "@${REMEDIATION_NOTIFY_DISCORD#@}" || echo "<not configured>")"
    printf "  Discord Server: %s\n" "${REMEDIATION_DISCORD_SERVER:-<not configured>}"
    printf "  Discord Chan:   %s\n" "${REMEDIATION_NOTIFY_CHANNEL:-<not configured>}"
    printf "${C_BOLD}${C_CYAN}────────────────────────────────────────────────────────────${C_RESET}\n\n"
}

# Dispatches notifications across configured email and discord channels
# Usage: remediation_notify_dispatch <task_id> <issue_ref> <status> <details> [extra_links]
remediation_notify_dispatch() {
    local task_id="$1"
    local issue_ref="$2"
    local status="$3"
    local details="$4"
    local extra_links="${5:-}"

    remediation_init
    [ "${REMEDIATION_NOTIFY_ENABLED:-1}" != "1" ] && return 0

    local now_ts
    now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local subject="[George Remediation] $status: $issue_ref"

    local body
    body=$(cat << EOF
George Sovereign Remediation Alert
Status:    $status
Task ID:   $task_id
Issue:     $issue_ref
Timestamp: $now_ts

Details:
$details

$extra_links

--
George (Blue Lodge Autonomous Self-Healing Sentinel)
EOF
)

    local notified=0
    local email_err=""

    # 1. Send Email Notification if configured
    if [ -n "$REMEDIATION_NOTIFY_EMAIL" ]; then
        if declare -f email_send &>/dev/null; then
            # Pre-flight check: verify email provider is configured before attempting dispatch
            local provider_configured=0
            if declare -f email_provider_configured &>/dev/null; then
                email_provider_configured "$REMEDIATION_EMAIL_PROVIDER" && provider_configured=1
            elif [ -f "${LODGE_DIR:-$HOME/blue-lodge}/.george/keys.conf" ] && grep -qE "EMAIL_${REMEDIATION_EMAIL_PROVIDER^^}_" "${LODGE_DIR:-$HOME/blue-lodge}/.george/keys.conf" 2>/dev/null; then
                provider_configured=1
            fi

            if [ "$provider_configured" -eq 1 ]; then
                ui_step "Notifying operator via email (${REMEDIATION_NOTIFY_EMAIL})..." >&2
                local send_err
                send_err=$(email_send "$REMEDIATION_EMAIL_PROVIDER" "$REMEDIATION_NOTIFY_EMAIL" "$subject" "$body" 2>&1)
                local send_rc=$?
                if [ "$send_rc" -ne 0 ]; then
                    ui_warn "Email notification dispatch failed (provider: $REMEDIATION_EMAIL_PROVIDER)" >&2
                    email_err="⚠️ *Email alert to \`${REMEDIATION_NOTIFY_EMAIL}\` failed: provider \`${REMEDIATION_EMAIL_PROVIDER}\` error.*"
                fi
                notified=1
            else
                ui_dim "Email notification skipped: provider '$REMEDIATION_EMAIL_PROVIDER' not configured (/email setup $REMEDIATION_EMAIL_PROVIDER)." >&2
            fi
        fi
    fi

    # 2. Send Discord Notification if configured
    local discord_msg="🛠️ **[George Remediation Alert]** \`${status}\`\n**Issue:** ${issue_ref}\n**Task:** \`${task_id}\`\n${details}"
    if [ -n "$email_err" ]; then
        discord_msg+="\n${email_err}"
    fi
    if [ -n "$extra_links" ]; then
        discord_msg+="\n${extra_links}"
    fi

    if [ -n "$REMEDIATION_NOTIFY_DISCORD" ]; then
        local clean_user="${REMEDIATION_NOTIFY_DISCORD#@}"
        if declare -f discord_dm &>/dev/null; then
            ui_step "Notifying operator via Discord DM (@${clean_user})..." >&2
            AGENT_FILE_EXPAND=0 discord_dm "$clean_user" "$discord_msg" >/dev/null 2>&1 || {
                ui_warn "Discord DM notification dispatch failed (user: @$clean_user)" >&2
            }
            notified=1
        fi
    fi

    if [ -n "$REMEDIATION_NOTIFY_CHANNEL" ]; then
        local clean_chan="${REMEDIATION_NOTIFY_CHANNEL###}"
        if declare -f discord_post &>/dev/null; then
            ui_step "Notifying operator via Discord channel (#${clean_chan})..." >&2
            AGENT_FILE_EXPAND=0 discord_post "$clean_chan" "$discord_msg" >/dev/null 2>&1 || {
                ui_warn "Discord channel notification dispatch failed (channel: #$clean_chan)" >&2
            }
            notified=1
        fi
    fi

    # 3. Broadcast across Sovereign MQTT Bus (Task-to-Task & Node Telemetry)
    if declare -f mqtt_publish &>/dev/null; then
        local mqtt_payload
        mqtt_payload=$(jq -n \
            --arg tid "$task_id" \
            --arg st "$status" \
            --arg is "$issue_ref" \
            --arg det "$details" \
            --arg ts "$now_ts" \
            '{ task_id: $tid, status: $st, issue: $is, details: $det, timestamp: $ts }' 2>/dev/null || echo "{\"task_id\":\"$task_id\",\"status\":\"$status\"}")
        mqtt_publish "george/remediation/events" "$mqtt_payload" >/dev/null 2>&1 || true
        mqtt_publish "george/remediation/${task_id}/status" "$mqtt_payload" >/dev/null 2>&1 || true
        notified=1
    fi

    if [ "$notified" -eq 0 ]; then
        ui_dim "No notification targets configured (run: /remediation notify set email|discord <val>)" >&2
    fi
}

# ── 2. Remediation Queue Management & Multi-Repo Module Router ─────────

# Resolves whether a defect belongs to Heartwood (blue-lodge) or an installed
# external Guild module repo (.george/modules/<id>/). Prints JSON:
#   {target_kind, module_id, repo_dir, gitea_user, gitea_repo, git_remote, base_branch}
remediation_resolve_target() {
    local title="${1:-}"
    local body="${2:-}"
    local issue_file="${3:-}"
    local lodge_root="${LODGE_DIR:-$HOME/blue-lodge}"
    local george_root="${GEORGE_DIR:-$lodge_root/.george}"
    local map_file="$george_root/cache/module_tool_map.json"
    local mods_dir="$george_root/modules"

    python3 - "$title" "$body" "$issue_file" "$lodge_root" "$map_file" "$mods_dir" <<'PY'
import json, os, re, subprocess, sys

title, body, issue_file, lodge_root, map_file, mods_dir = sys.argv[1:7]
blob = f"{title}\n{body}"
if issue_file and os.path.isfile(issue_file):
    try:
        blob += "\n" + open(issue_file, "r", encoding="utf-8", errors="replace").read()[:8000]
    except Exception:
        pass

def git_out(repo, *args):
    try:
        return subprocess.check_output(["git", "-C", repo, *args], stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""

# Resolve default local Gitea user from env or blue-lodge's gitea remote
gitea_default_user = os.environ.get("GITEA_USER", "")
if not gitea_default_user:
    gurl = git_out(lodge_root, "remote", "get-url", "gitea")
    m_gu = re.search(r"https?://(?:[^/@]+@)?[^/]+/([^/]+)/", gurl)
    gitea_default_user = m_gu.group(1) if m_gu else "george"

mod_id = ""

# 1. Explicit module path reference in stacktrace or incident dossier
m_path = re.search(r"\.george/modules/([a-z0-9][a-z0-9_-]{1,48})(?:/|\b)", blob)
if m_path:
    mod_id = m_path.group(1)

# 2. Match against .george/cache/module_tool_map.json tool names (e.g. shop_*, sky_*, hunt_*)
if not mod_id and os.path.isfile(map_file):
    try:
        tmap = json.load(open(map_file, "r", encoding="utf-8"))
        for tname, meta in tmap.items():
            if tname and re.search(r"\b" + re.escape(tname) + r"\b", blob):
                mid = (meta or {}).get("module_id") or ""
                if mid:
                    mod_id = mid
                    break
    except Exception:
        pass

# 3. Match cron_mod_<id>_* job naming convention
if not mod_id:
    m_cron = re.search(r"\b(?:cron_)?mod_([a-z0-9][a-z0-9_-]{1,48})_", blob)
    if m_cron:
        cand = m_cron.group(1).replace("_", "-")
        if os.path.isdir(os.path.join(mods_dir, cand)):
            mod_id = cand
        elif os.path.isdir(os.path.join(mods_dir, m_cron.group(1))):
            mod_id = m_cron.group(1)

if mod_id:
    mdir = os.path.join(mods_dir, mod_id)
    if os.path.isdir(os.path.join(mdir, ".git")) or os.path.isfile(os.path.join(mdir, ".git")):
        g_user = gitea_default_user
        g_repo = f"mod-{mod_id}"
        base_br = "main"
        git_rem = "gitea" if git_out(mdir, "remote", "get-url", "gitea") else "origin"
        url = git_out(mdir, "remote", "get-url", git_rem)
        m_url = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?$", url)
        if m_url:
            g_repo = m_url.group(2)
            # Only adopt owner from remote URL when it is a local/Gitea remote (not public github.com)
            if "github.com" not in url.lower():
                g_user = m_url.group(1)
        cur_br = git_out(mdir, "symbolic-ref", "--short", "HEAD")
        if cur_br:
            base_br = cur_br
        print(json.dumps({
            "target_kind": "module",
            "module_id": mod_id,
            "repo_dir": mdir,
            "gitea_user": g_user,
            "gitea_repo": g_repo,
            "git_remote": git_rem,
            "base_branch": base_br,
        }))
        sys.exit(0)

# 4. Node Ecotype target detection (target_kind = "ecotype"):
#    Route to the active ecotype/<node> branch ONLY when:
#      (a) explicitly requested via [target:ecotype] or Branch/CI reference to ecotype/<node>, OR
#      (b) the issue cites a file path that is diverged on ecotype/<node> relative to develop.
#    Otherwise default to Heartwood (develop) so node-local configs never leak into trunk PRs.
cur_lodge_br = git_out(lodge_root, "symbolic-ref", "--short", "HEAD")
ecotype_branch = ""
m_eco = re.search(r"\b(ecotype/[A-Za-z0-9._-]+)\b", blob)
if m_eco:
    cand_eco = m_eco.group(1)
    if git_out(lodge_root, "rev-parse", "--verify", cand_eco) or git_out(lodge_root, "rev-parse", "--verify", f"gitea/{cand_eco}"):
        ecotype_branch = cand_eco
elif cur_lodge_br.startswith("ecotype/"):
    if re.search(r"(?i)\[target\s*:\s*ecotype\]|\blabels?\b[^\n]*\becotype\b", blob):
        ecotype_branch = cur_lodge_br
    else:
        # Compare diverged files on ecotype/<node> vs develop (or gitea/develop)
        dev_ref = "gitea/develop" if git_out(lodge_root, "rev-parse", "--verify", "gitea/develop") else (
            "develop" if git_out(lodge_root, "rev-parse", "--verify", "develop") else ""
        )
        if dev_ref:
            div_files = [f.strip() for f in git_out(lodge_root, "diff", "--name-only", f"{dev_ref}..HEAD").splitlines() if f.strip()]
            for df in div_files:
                # Match exact repo-relative diverged file path mentioned in the issue/stacktrace
                if df in blob:
                    ecotype_branch = cur_lodge_br
                    break

if ecotype_branch:
    print(json.dumps({
        "target_kind": "ecotype",
        "module_id": "",
        "repo_dir": lodge_root,
        "gitea_user": gitea_default_user,
        "gitea_repo": os.environ.get("GITEA_REPO", "blue-lodge"),
        "git_remote": "gitea",
        "base_branch": ecotype_branch,
    }))
    sys.exit(0)

print(json.dumps({
    "target_kind": "heartwood",
    "module_id": "",
    "repo_dir": lodge_root,
    "gitea_user": gitea_default_user,
    "gitea_repo": os.environ.get("GITEA_REPO", "blue-lodge"),
    "git_remote": "gitea",
    "base_branch": "develop",
}))
PY
}

# Enqueues a new remediation task from an issue or incident
# Usage: remediation_queue_add <issue_file> [incident_dir] [priority] [title] [target_json]
remediation_queue_add() {
    local issue_file="$1"
    local inc_dir="${2:-}"
    local priority="${3:-normal}"
    local custom_title="${4:-}"
    local target_json="${5:-}"

    remediation_init

    local now
    now=$(date +%s)
    local task_id="rem_${now}_$(( RANDOM % 1000 ))"
    local queue_file="$REMEDIATION_QUEUE_DIR/${task_id}.json"

    local title="$custom_title"
    if [ -z "$title" ] && [ -f "$issue_file" ]; then
        title=$(head -n 5 "$issue_file" | grep -E '^# ' | sed 's/^# //' | head -n 1)
    fi
    [ -z "$title" ] && title="Remediate issue $(basename "$issue_file" .md)"

    local fp="" gitea_idx=""
    if [ -f "$issue_file" ]; then
        fp=$(grep -o '\[fingerprint:[^]]*\]' "$issue_file" | head -n 1 | cut -d':' -f2 | tr -d ']')
        gitea_idx=$(grep -oE '\*\*Gitea Issue:\*\* #([0-9]+)' "$issue_file" 2>/dev/null | head -n 1 | cut -d'#' -f2 || true)
    fi

    if [ -z "$target_json" ]; then
        target_json=$(remediation_resolve_target "$title" "" "$issue_file" 2>/dev/null || echo '{}')
    fi
    local t_kind t_mod t_rdir t_guser t_grepo t_remote t_base
    t_kind=$(echo "$target_json" | jq -r '.target_kind // "heartwood"' 2>/dev/null)
    t_mod=$(echo "$target_json" | jq -r '.module_id // ""' 2>/dev/null)
    t_rdir=$(echo "$target_json" | jq -r --arg d "${LODGE_DIR:-$HOME/blue-lodge}" '.repo_dir // $d' 2>/dev/null)
    t_guser=$(echo "$target_json" | jq -r '.gitea_user // "george"' 2>/dev/null)
    t_grepo=$(echo "$target_json" | jq -r '.gitea_repo // "blue-lodge"' 2>/dev/null)
    t_remote=$(echo "$target_json" | jq -r '.git_remote // "gitea"' 2>/dev/null)
    t_base=$(echo "$target_json" | jq -r '.base_branch // "develop"' 2>/dev/null)

    jq -n \
        --arg tid "$task_id" \
        --arg title "$title" \
        --arg prio "$priority" \
        --arg issue "$issue_file" \
        --arg inc "$inc_dir" \
        --arg fp "$fp" \
        --arg gitea "$gitea_idx" \
        --arg tkind "$t_kind" \
        --arg tmod "$t_mod" \
        --arg trdir "$t_rdir" \
        --arg tguser "$t_guser" \
        --arg tgrepo "$t_grepo" \
        --arg tremote "$t_remote" \
        --arg tbase "$t_base" \
        --argjson ts "$now" \
        '{
            task_id: $tid,
            title: $title,
            priority: $prio,
            issue_file: $issue,
            incident_dir: $inc,
            fingerprint: $fp,
            gitea_issue: $gitea,
            target_kind: $tkind,
            module_id: $tmod,
            repo_dir: $trdir,
            gitea_user: $tguser,
            gitea_repo: $tgrepo,
            git_remote: $tremote,
            base_branch: $tbase,
            status: "QUEUED",
            created_ts: $ts
        }' > "$queue_file"

    ui_ok "Remediation task queued: $task_id ($title) [target: ${t_kind}:${t_guser}/${t_grepo}@${t_base}]" >&2
    echo "$task_id"
}

# Lists remediation tasks in all states
remediation_queue_list() {
    remediation_init
    printf "\n${C_BOLD}${C_CYAN}── Sovereign Remediation Queue ─────────────────────────────${C_RESET}\n"

    local q_count=0
    for qf in "$REMEDIATION_QUEUE_DIR"/*.json; do
        [ ! -f "$qf" ] && continue
        local tid ttl prio
        tid=$(jq -r '.task_id' "$qf" 2>/dev/null)
        ttl=$(jq -r '.title' "$qf" 2>/dev/null)
        prio=$(jq -r '.priority' "$qf" 2>/dev/null)
        printf "  [QUEUED]      %-20s | %-8s | %s\n" "$tid" "$prio" "$ttl"
        q_count=$((q_count + 1))
    done

    for pf in "$REMEDIATION_PROGRESS_DIR"/*.json; do
        [ ! -f "$pf" ] && continue
        local tid ttl
        tid=$(jq -r '.task_id' "$pf" 2>/dev/null)
        ttl=$(jq -r '.title' "$pf" 2>/dev/null)
        printf "  ${C_YELLOW}[IN_PROGRESS]${C_RESET} %-20s | %s\n" "$tid" "$ttl"
        q_count=$((q_count + 1))
    done

    for cf in "$REMEDIATION_COMPLETED_DIR"/*.json; do
        [ ! -f "$cf" ] && continue
        local tid ttl
        tid=$(jq -r '.task_id' "$cf" 2>/dev/null)
        ttl=$(jq -r '.title' "$cf" 2>/dev/null)
        printf "  ${C_GREEN}[COMPLETED]${C_RESET}   %-20s | %s\n" "$tid" "$ttl"
        q_count=$((q_count + 1))
    done

    [ "$q_count" -eq 0 ] && echo "  (Queue is empty)"
    printf "${C_BOLD}${C_CYAN}────────────────────────────────────────────────────────────${C_RESET}\n\n"
}

# Picks next queued task (high priority first, oldest first within tier)
remediation_queue_next() {
    remediation_init
    local f high_candidate="" norm_candidate=""
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        local prio
        prio=$(jq -r '.priority // "normal"' "$f" 2>/dev/null)
        if [ "$prio" = "high" ]; then
            high_candidate="$f"
        else
            norm_candidate="$f"
        fi
    done < <(ls -1t "$REMEDIATION_QUEUE_DIR"/*.json 2>/dev/null)
    if [ -n "$high_candidate" ]; then
        echo "$high_candidate"
    else
        echo "$norm_candidate"
    fi
}

# Checks if an autonomous remediation task is currently active on Slot 1.
# Only a LIVE lock-holder counts as active. Items left in in_progress/ without
# a live runner are orphans (the runner always holds the lock while working);
# they are reclaimed here so a crashed run can never block the queue forever.
remediation_is_active() {
    remediation_init
    local lock_file="$REMEDIATION_DIR/.lock"
    if [ -f "$lock_file" ]; then
        local active_pid
        active_pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
            return 0
        fi
        # Stale lock: PID is no longer alive
        rm -f "$lock_file" 2>/dev/null || true
    fi

    remediation_reclaim_orphans >/dev/null 2>&1 || true
    return 1
}

# Reclaims orphaned in_progress items (caller guarantees no live runner).
# First-time orphans younger than REMEDIATION_ORPHAN_TTL are requeued once;
# repeat or ancient orphans are failed as ORPHANED_RECLAIMED.
# Echoes the number of reclaimed items.
remediation_reclaim_orphans() {
    remediation_init
    local ttl="${REMEDIATION_ORPHAN_TTL:-604800}" now n=0
    now=$(date +%s)
    local pf
    for pf in "$REMEDIATION_PROGRESS_DIR"/*.json; do
        [ -f "$pf" ] || continue
        local tid rc age
        tid=$(basename "$pf" .json)
        rc=$(jq -r '.reclaim_count // 0' "$pf" 2>/dev/null || echo 0)
        [[ "$rc" =~ ^[0-9]+$ ]] || rc=0
        age=$(( now - $(stat -c %Y "$pf" 2>/dev/null || echo "$now") ))
        if [ "$rc" -lt 1 ] && [ "$age" -lt "$ttl" ]; then
            jq --argjson n "$((rc + 1))" --argjson ts "$now" \
                '.status = "QUEUED" | .reclaim_count = $n | .reclaimed_at = $ts' "$pf" \
                > "$REMEDIATION_QUEUE_DIR/${tid}.json" 2>/dev/null && rm -f "$pf"
            ui_warn "Remediation: reclaimed orphaned task $tid back to queue" >&2
        else
            jq --argjson ts "$now" '.status = "ORPHANED_RECLAIMED" | .reclaimed_at = $ts' "$pf" \
                > "$REMEDIATION_FAILED_DIR/${tid}.json" 2>/dev/null && rm -f "$pf"
            ui_warn "Remediation: failed orphaned task $tid (age ${age}s, reclaims $rc)" >&2
        fi
        n=$((n + 1))
        if declare -f event_bus_emit &>/dev/null; then
            event_bus_emit "remediation.orphan_reclaimed" \
                "$(jq -nc --arg t "$tid" --argjson a "$age" --argjson r "$rc" '{task_id:$t, age_s:$a, prior_reclaims:$r}')" \
                "remediation" >/dev/null 2>&1 || true
        fi
    done
    echo "$n"
}

# Operator intake: open Gitea issues carrying the trigger label
# (REMEDIATION_INTAKE_LABEL, default "remediate") from a trusted author become
# queued remediation tasks. Trusted = login listed in REMEDIATION_INTAKE_AUTHORS
# or $REMEDIATION_DIR/intake_authors (comma/newline list); with no list, any
# Gitea site admin other than George itself (registration is disabled, so
# admins mint every account). Queued issues get the "george-queued" label;
# remove it to re-queue. Prints the number of tasks enqueued.
remediation_gitea_intake() {
    remediation_init
    declare -f gitea_issue_list &>/dev/null || { echo 0; return 0; }
    local trigger="${REMEDIATION_INTAKE_LABEL:-remediate}" done_label="george-queued"
    local issues
    [[ "$trigger" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo 0; return 0; }
    issues=$(gitea_issue_list open json "$trigger" 2>/dev/null) || { echo 0; return 0; }
    printf '%s' "$issues" | jq -e 'type == "array"' >/dev/null 2>&1 || { echo 0; return 0; }

    local authors="${REMEDIATION_INTAKE_AUTHORS:-}"
    if [ -z "$authors" ] && [ -f "$REMEDIATION_DIR/intake_authors" ]; then
        authors=$(grep -vE '^[[:space:]]*(#|$)' "$REMEDIATION_DIR/intake_authors" | tr '\n' ',')
    fi
    local candidates
    candidates=$(printf '%s' "$issues" | jq -c --arg t "$trigger" --arg d "$done_label" \
        --arg a "$authors" --arg self "${GITEA_USER:-george}" '
        ($a | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $allow
        | .[] | select(.pull_request == null)
        | ([.labels[]?.name]) as $ln
        | select(($ln | index($t)) != null and ($ln | index($d)) == null)
        | select(if ($allow | length) > 0
                 then (.user.login as $u | $allow | index($u)) != null
                 else (.user.is_admin == true and .user.login != $self) end)
        | {number, title: (.title // ""), body: (.body // ""), author: .user.login, labels: $ln}' 2>/dev/null)
    [ -z "$candidates" ] && { echo 0; return 0; }

    local issues_dir="$GEORGE_DIR/issues" n=0 c
    mkdir -p "$issues_dir"
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        local num title body author prio tid isf
        num=$(jq -r '.number' <<<"$c")
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        # Skip when a live task already tracks this issue (nullglob: an empty
        # dir must not leave a literal pattern that makes jq error out).
        local -a live_tasks=()
        local _ng; _ng=$(shopt -p nullglob); shopt -s nullglob
        live_tasks=("$REMEDIATION_QUEUE_DIR"/*.json "$REMEDIATION_PROGRESS_DIR"/*.json)
        eval "$_ng"
        if [ "${#live_tasks[@]}" -gt 0 ] && jq -r '.gitea_issue // empty | tostring' "${live_tasks[@]}" 2>/dev/null \
            | grep -qx "$num"; then
            continue
        fi
        title=$(jq -r '.title' <<<"$c" | tr -d '\000-\037' | cut -c1-200)
        body=$(jq -r '.body' <<<"$c" | tr -d '\000-\010\013-\037' | head -c 4000)
        author=$(jq -r '.author' <<<"$c" | tr -cd 'A-Za-z0-9._-')
        prio="normal"
        jq -e '.labels | map(ascii_downcase) | any(. == "priority/high" or . == "urgent" or . == "critical")' \
            <<<"$c" >/dev/null 2>&1 && prio="high"
        isf="$issues_dir/issue_gitea_${num}.md"
        {
            printf '# %s\n\n' "${title:-Gitea issue #$num}"
            printf '**Source:** operator Gitea issue (author: %s)\n' "$author"
            printf '**Gitea Issue:** #%s\n\n' "$num"
            printf '## Operator request\n\n%s\n' "$body"
        } > "$isf"
        tid=$(remediation_queue_add "$isf" "" "$prio" "${title:-Gitea issue #$num}" 2>/dev/null | tail -n 1)
        [ -z "$tid" ] && continue
        n=$((n + 1))
        gitea_issue_add_labels "$num" "$done_label" >/dev/null 2>&1 || true
        gitea_issue_comment "$num" "Queued as remediation task \`$tid\` (priority: $prio). Remove the \`$done_label\` label to re-queue." >/dev/null 2>&1 || true
        if declare -f event_bus_emit &>/dev/null; then
            event_bus_emit "remediation.intake" \
                "$(jq -nc --arg t "$tid" --argjson g "$num" --arg a "$author" --arg p "$prio" '{task_id:$t, gitea_issue:$g, author:$a, priority:$p}')" \
                "remediation" >/dev/null 2>&1 || true
        fi
    done <<<"$candidates"
    echo "$n"
}

# Operator close -> cancel: QUEUED tasks whose Gitea issue is now closed are
# moved to failed/ as CANCELLED before the worker picks them up. Running tasks
# are left alone (they hold the lock; stop them explicitly). Prints the count.
remediation_gitea_cancel_closed() {
    remediation_init
    declare -f gitea_issue_get &>/dev/null || { echo 0; return 0; }
    local n=0 qf g state tid
    for qf in "$REMEDIATION_QUEUE_DIR"/*.json; do
        [ -f "$qf" ] || continue
        g=$(jq -r '.gitea_issue // ""' "$qf" 2>/dev/null)
        [[ "$g" =~ ^[0-9]+$ ]] || continue
        state=$(gitea_issue_get "$g" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)
        [ "$state" = "closed" ] || continue
        tid=$(basename "$qf" .json)
        jq --arg r "Gitea issue #$g closed by operator" '.status = "CANCELLED" | .cancel_reason = $r' \
            "$qf" > "$REMEDIATION_FAILED_DIR/$tid.json" 2>/dev/null && rm -f "$qf" && n=$((n + 1))
    done
    echo "$n"
}

# Apply mode: "propose" (default) = diagnose, issue, branch, PR only;
# "auto" = also merge PRs into develop. Mode file: $REMEDIATION_DIR/mode
# (env REMEDIATION_APPLY_MODE overrides). Anything unrecognised -> propose.
remediation_apply_mode() {
    local m="${REMEDIATION_APPLY_MODE:-}"
    [ -z "$m" ] && [ -f "$REMEDIATION_DIR/mode" ] && m=$(head -n1 "$REMEDIATION_DIR/mode" 2>/dev/null | tr -d '[:space:]')
    case "$m" in
        auto) echo "auto" ;;
        *)    echo "propose" ;;
    esac
}

# Write-scope denylist (one glob per line in $REMEDIATION_DIR/write_denylist;
# defaults protect the files under active migration). Reads changed paths on
# stdin, echoes the ones that violate the denylist.
remediation_scope_violations_from_list() {
    local -a pats=()
    if [ -f "$REMEDIATION_DIR/write_denylist" ]; then
        mapfile -t pats < <(grep -vE '^\s*(#|$)' "$REMEDIATION_DIR/write_denylist")
    else
        pats=("lib/core/react*" "lib/core/agent*" "lib/comms/discord_bridge.sh" "lib/comms/web.sh")
    fi
    # Inviolable Three-Tier boundary: Heartwood remediation must NEVER commit
    # gitignored runtime state or external Guild module repos (.george/*) into blue-lodge.
    pats+=(".george/*" ".sandboxes/*")
    local path p
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        [ "$path" = "okf/blue_lodge_graph.jsonld" ] && continue
        for p in "${pats[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$path" == $p ]]; then echo "$path"; break; fi
        done
    done
}

# Liveness heartbeat for the Workbench / watchdog.
remediation_heartbeat() {
    remediation_init
    local now q p
    now=$(date +%s)
    q=$(find "$REMEDIATION_QUEUE_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    p=$(find "$REMEDIATION_PROGRESS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    local hb
    hb=$(jq -nc --argjson ts "$now" --argjson q "$q" --argjson p "$p" --arg mode "$(remediation_apply_mode)" \
        '{ts:$ts, queue_depth:$q, in_progress:$p, mode:$mode}')
    printf '%s\n' "$hb" > "$REMEDIATION_DIR/.heartbeat"
    if ! declare -f heartbeat_write &>/dev/null; then
        source "$LODGE_DIR/lib/sys/heartbeats.sh" 2>/dev/null || true
    fi
    declare -f heartbeat_write &>/dev/null && heartbeat_write remediation "$hb" || true
    if declare -f event_bus_emit &>/dev/null; then
        event_bus_emit "remediation.worker_heartbeat" "$hb" "remediation" >/dev/null 2>&1 || true
    fi
}

# ── 3. Cooperative Scheduling & Visual Monitoring ─────────────────────

# Probes Inference Slot 0, active Discord sessions, Game Mode, and terminal locks to yield compute
# Usage: remediation_cooperative_pause [indefinite: 0|1] [task_id]
remediation_cooperative_pause() {
    local indefinite="${1:-0}"
    local task_tag="${2:-${task_id:-${active_task_id:-$$}}}"
    local max_wait="${REMEDIATION_COOPERATIVE_MAX_WAIT:-30}"
    [ "$indefinite" -eq 1 ] && max_wait=300

    if declare -f ipc_is_human_present &>/dev/null; then
        local _hp_waited=0
        while ipc_is_human_present; do
            if [ "$_hp_waited" -eq 0 ]; then
                ui_dim "  [Pause] Yielding remediation (${task_tag}) while human operator is active..."
            fi
            sleep 3
            _hp_waited=$((_hp_waited + 3))
            if [ "$indefinite" -eq 0 ] && [ "$_hp_waited" -ge "$max_wait" ]; then
                break
            fi
        done
        return 0
    fi

    local waited=0
    while true; do
        local pause_reason=""
        # 1. Probe Slot 0 inference status on target tier (via IPC FIFO slot + /slots HTTP check)
        local target_tier="${ACTIVE_TIER:-1}"
        if declare -f ipc_tier_is_idle &>/dev/null; then
            if ! ipc_tier_is_idle "$target_tier"; then
                pause_reason="Tier ${target_tier} IPC FIFO slot busy"
            fi
        fi
        if [ -z "$pause_reason" ] && { [ "$target_tier" -eq 1 ] || [ "${TIER2_URL:-}" = "${TIER1_URL:-}" ]; }; then
            local t1_base="${TIER1_URL:-http://127.0.0.1:8080}"
            local slots_json
            slots_json=$(curl -s -m 2 "${t1_base%/}/slots" 2>/dev/null || echo "[]")
            if [ "$slots_json" != "[]" ]; then
                local s0_busy
                s0_busy=$(echo "$slots_json" | jq -r '.[0].is_processing // false' 2>/dev/null)
                [ "$s0_busy" = "true" ] && pause_reason="Slot 0 interactive user inference active"
            fi
        fi

        # 2. Probe active Discord interactive sessions
        if [ -z "$pause_reason" ]; then
            local orig_dir="${orig_lodge_dir:-${LODGE_ROOT:-$HOME/blue-lodge}}"
            for dpid_file in "$orig_dir/.george/discord_sessions"/session_*.pid "$orig_dir/.george/discord_sessions"/active/task_*.pid; do
                [ ! -f "$dpid_file" ] && continue
                local dpid
                dpid=$(head -n 1 "$dpid_file" 2>/dev/null | tr -d '[:space:]')
                if [ -n "$dpid" ] && [[ "$dpid" =~ ^[0-9]+$ ]] && kill -0 "$dpid" 2>/dev/null; then
                    pause_reason="active Discord session (PID $dpid)"
                    break
                fi
            done
        fi

        # 3. Probe Game Mode
        if [ -z "$pause_reason" ]; then
            if [ -f "${LODGE_DIR:-$HOME/blue-lodge}/.george/.game_mode" ] || [ -f "${GEORGE_DIR:-$HOME/blue-lodge/.george}/.game_mode" ]; then
                pause_reason="Game Mode is active (preserving GPU resources)"
            fi
        fi

        # 4. Probe interactive terminal lock
        if [ -z "$pause_reason" ]; then
            local ilock="${LODGE_DIR:-$HOME/blue-lodge}/.george/interactive.lock"
            if [ -f "$ilock" ]; then
                local ilock_pid
                ilock_pid=$(cat "$ilock" 2>/dev/null)
                if [ -n "$ilock_pid" ] && kill -0 "$ilock_pid" 2>/dev/null; then
                    pause_reason="active terminal REPL session (PID $ilock_pid)"
                fi
            fi
        fi

        if [ -z "$pause_reason" ]; then
            return 0
        fi

        ui_dim "Cooperative pause ($pause_reason). Yielding compute for 3s..." >&2
        sleep 3
        waited=$((waited + 3))

        if [ "$indefinite" -ne 1 ] && [ "$waited" -ge "$max_wait" ]; then
            return 0
        fi
    done
}

# Launches live companion HUD monitor in Windows Terminal (wt.exe)
remediation_launch_visual_monitor() {
    local task_id="$1"
    local title="$2"
    local log_file="$3"

    if ! command -v wt.exe &>/dev/null || [ -z "${WSL_DISTRO_NAME:-}" ]; then
        return 0
    fi

    # Clean up any lingering monitor process for this task
    local existing_mon
    existing_mon=$(pgrep -f "scripts/monitor/remediation_live_monitor.sh $task_id" 2>/dev/null || true)
    if [ -n "$existing_mon" ]; then
        kill $existing_mon 2>/dev/null || true
        sleep 0.2
    fi

    local size="${REMEDIATION_POPUP_SIZE:-110,32}"

    popup_terminal_launch "George Remediation HUD - $task_id" "$size" \
        bash ./scripts/monitor/remediation_live_monitor.sh "$task_id" "$title" "$log_file"
}

# ── Milestone Summarizer: Gitea Issue Checkpoint Comments ─────────────
# Posts concise executive markdown checkpoints (DIAGNOSIS, STAGING, VERIFICATION, DELIVERY)
# to Gitea issues without flooding with raw LLM token traces.
# Usage: remediation_post_checkpoint <gitea_idx> <phase> <summary> [details] [task_id]
remediation_post_checkpoint() {
    local gitea_idx="$1"
    local phase="$2"
    local summary="$3"
    local details="${4:-}"
    local task_id="${5:-}"

    [ -z "$gitea_idx" ] && return 0

    if ! declare -f gitea_issue_comment &>/dev/null; then
        local gitea_sh="${LODGE_DIR:-$HOME/blue-lodge}/lib/tools/mcp_server_gitea.sh"
        [ -f "$gitea_sh" ] && source "$gitea_sh" 2>/dev/null || true
    fi
    declare -f gitea_issue_comment &>/dev/null || return 0

    local icon="🛠️"
    case "$phase" in
        DIAGNOSIS)    icon="🔍" ;;
        STAGING)      icon="🏗️" ;;
        VERIFICATION) icon="🧪" ;;
        DELIVERY)     icon="🚀" ;;
    esac

    local comment_body
    comment_body="### ${icon} Remediation Checkpoint: \`${phase}\`"
    [ -n "$task_id" ] && comment_body+=" (Task: \`${task_id}\`)"
    comment_body+=$'\n\n'"**Summary:** ${summary}"

    if [ -n "$details" ]; then
        comment_body+=$'\n\n'"${details}"
    fi

    gitea_issue_comment "$gitea_idx" "$comment_body" >/dev/null 2>&1 || true
}

# ── 4. Remediation Execution with Slot 1 Isolation ────────────────────
# Executes remediation strictly on Slot 1 in an isolated git worktree sandbox.
# Cooperatively yields if Slot 0 interactive sessions (REPL/Discord) are computing.
# Usage: remediation_run [task_id]
remediation_run() {
    local target_task_id="${1:-}"
    remediation_init

    # Strict single-concurrency guard on Slot 1
    local lock_file="$REMEDIATION_DIR/.lock"
    local cur_pid="${BASHPID:-$$}"
    if [ -f "$lock_file" ]; then
        local active_pid
        active_pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$active_pid" ] && [ "$active_pid" != "$cur_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
            ui_dim "Autonomous remediation task is already active (PID $active_pid). Yielding Slot 1 until completion."
            return 0
        fi
        rm -f "$lock_file" 2>/dev/null || true
    fi

    # Acquire lock for this runner process (BASHPID: correct PID inside subshells,
    # where $$ would be the long-lived parent daemon and never look stale)
    echo "$cur_pid" > "$lock_file"

    local processed_any=0
    while true; do
        local task_file=""
        local task_id=""
        if [ -n "$target_task_id" ]; then
            task_file="$REMEDIATION_QUEUE_DIR/${target_task_id}.json"
            [ ! -f "$task_file" ] && task_file="$REMEDIATION_PROGRESS_DIR/${target_task_id}.json"
        else
            task_file=$(remediation_queue_next)
        fi

        if [ -z "$task_file" ] || [ ! -f "$task_file" ]; then
            if [ "$processed_any" -eq 0 ]; then
                ui_info "No pending remediation tasks in queue."
            fi
            break
        fi

        task_id=$(jq -r '.task_id' "$task_file")
        local title issue_file inc_dir fp
        title=$(jq -r '.title' "$task_file")
        issue_file=$(jq -r '.issue_file' "$task_file")
        inc_dir=$(jq -r '.incident_dir' "$task_file")
        fp=$(jq -r '.fingerprint' "$task_file")

        ui_section "Executing Sovereign Remediation: $task_id"
        ui_info "Title: $title"
        [ -n "$issue_file" ] && ui_dim "Issue: $issue_file"
        [ -n "$inc_dir" ] && ui_dim "Dossier: $inc_dir"

        # Move to in_progress
        local progress_file="$REMEDIATION_PROGRESS_DIR/${task_id}.json"
        mv "$task_file" "$progress_file"
        jq '.status = "IN_PROGRESS"' "$progress_file" > "${progress_file}.tmp" && mv "${progress_file}.tmp" "$progress_file"

        # Guard: check if issue_file exists. If issue_file was in /tmp and deleted, abort cleanly.
        if [ -n "$issue_file" ] && [ ! -f "$issue_file" ] && [[ "$issue_file" == /tmp/* ]]; then
            ui_warn "Issue file $issue_file no longer exists on disk (orphaned temporary file). Aborting task."
            mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
            jq '.status = "ORPHANED_CLEANUP"' "$REMEDIATION_FAILED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_FAILED_DIR/${task_id}.json" 2>/dev/null || true
            [ -n "$target_task_id" ] && break
            continue
        fi

        # Initialize task execution log & launch live companion monitor HUD
        local rem_log="$REMEDIATION_LOGS_DIR/${task_id}.log"
        : > "$rem_log"
        remediation_launch_visual_monitor "$task_id" "$title" "$rem_log"

        # Cooperative pre-flight pause
        remediation_cooperative_pause

        # Notify operator that remediation is starting
        remediation_notify_dispatch "$task_id" "$title" "STARTED" \
            "Autonomous remediation initiated on Slot 1. Isolated workspace prepared." \
            "$([ -n "$inc_dir" ] && echo "Incident Artifacts: file://$inc_dir" || echo "")"

        # Resolve Gitea issue index
        local gitea_idx
        gitea_idx=$(jq -r '.gitea_issue // empty' "$progress_file" 2>/dev/null || true)
        if [ -z "$gitea_idx" ] && [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
            gitea_idx=$(grep -oE '\*\*Gitea Issue:\*\* #([0-9]+)' "$issue_file" 2>/dev/null | head -n 1 | cut -d'#' -f2 || true)
        fi

        # Resolve multi-repo phytology target (Heartwood blue-lodge vs external Guild module repo)
        local orig_lodge_dir="${LODGE_DIR:-$HOME/blue-lodge}"
        local orig_george_dir="${GEORGE_DIR:-$orig_lodge_dir/.george}"
        local orig_tier="${ACTIVE_TIER:-1}"

        local target_kind target_mod_id target_repo_dir target_gitea_user target_gitea_repo target_git_remote target_base_branch
        target_kind=$(jq -r '.target_kind // "heartwood"' "$progress_file" 2>/dev/null || echo "heartwood")
        target_mod_id=$(jq -r '.module_id // ""' "$progress_file" 2>/dev/null || echo "")
        target_repo_dir=$(jq -r --arg d "$orig_lodge_dir" '.repo_dir // $d' "$progress_file" 2>/dev/null || echo "$orig_lodge_dir")
        target_gitea_user=$(jq -r '.gitea_user // "george"' "$progress_file" 2>/dev/null || echo "george")
        target_gitea_repo=$(jq -r '.gitea_repo // "blue-lodge"' "$progress_file" 2>/dev/null || echo "blue-lodge")
        target_git_remote=$(jq -r '.git_remote // "gitea"' "$progress_file" 2>/dev/null || echo "gitea")
        target_base_branch=$(jq -r '.base_branch // "develop"' "$progress_file" 2>/dev/null || echo "develop")

        if [ "$target_kind" = "module" ] && [ ! -d "$target_repo_dir" ]; then
            ui_warn "Target module repo '$target_repo_dir' missing; falling back to Heartwood."
            target_kind="heartwood"; target_mod_id=""; target_repo_dir="$orig_lodge_dir"; target_gitea_repo="blue-lodge"; target_git_remote="gitea"; target_base_branch="develop"
        fi

        export GITEA_USER_OVERRIDE="$target_gitea_user"
        export GITEA_REPO_OVERRIDE="$target_gitea_repo"

        # Set up isolated worktree sandbox:
        #   - heartwood: branches off gitea/develop so ecotype/* commits never hitchhike
        #   - ecotype:   branches off ecotype/<node> (preferring local node branch so local adaptations are visible)
        #   - module:    branches off the module's own base branch (or detached HEAD pinned by /app install)
        local sandbox_dir="${orig_lodge_dir}/.sandboxes/remediation_${task_id}"
        local branch_name="remediation/${task_id}"
        mkdir -p "$(dirname "$sandbox_dir")" 2>/dev/null || true

        local worktree_start_ref="HEAD"
        if [ "$target_kind" = "heartwood" ]; then
            git -C "$target_repo_dir" fetch "$target_git_remote" "$target_base_branch" >/dev/null 2>&1 || true
            if git -C "$target_repo_dir" rev-parse --verify "${target_git_remote}/${target_base_branch}" >/dev/null 2>&1; then
                worktree_start_ref="${target_git_remote}/${target_base_branch}"
            elif git -C "$target_repo_dir" rev-parse --verify "$target_base_branch" >/dev/null 2>&1; then
                worktree_start_ref="$target_base_branch"
            fi
        elif [ "$target_kind" = "ecotype" ]; then
            git -C "$target_repo_dir" fetch "$target_git_remote" "$target_base_branch" >/dev/null 2>&1 || true
            if git -C "$target_repo_dir" rev-parse --verify "$target_base_branch" >/dev/null 2>&1; then
                worktree_start_ref="$target_base_branch"
            elif git -C "$target_repo_dir" rev-parse --verify "${target_git_remote}/${target_base_branch}" >/dev/null 2>&1; then
                worktree_start_ref="${target_git_remote}/${target_base_branch}"
            fi
        else
            git -C "$target_repo_dir" fetch "$target_git_remote" "$target_base_branch" >/dev/null 2>&1 || true
            if git -C "$target_repo_dir" rev-parse --verify "$target_base_branch" >/dev/null 2>&1; then
                worktree_start_ref="$target_base_branch"
            elif git -C "$target_repo_dir" rev-parse --verify "${target_git_remote}/${target_base_branch}" >/dev/null 2>&1; then
                worktree_start_ref="${target_git_remote}/${target_base_branch}"
            else
                worktree_start_ref="HEAD"
            fi
        fi

        git -C "$target_repo_dir" branch -D "$branch_name" 2>/dev/null || true
        git -C "$target_repo_dir" worktree remove --force "$sandbox_dir" 2>/dev/null || true
        git -C "$target_repo_dir" worktree add -b "$branch_name" "$sandbox_dir" "$worktree_start_ref" 2>/dev/null || {
            ui_err "Failed to create isolated git worktree for remediation ($target_kind:$target_gitea_repo): $sandbox_dir"
            unset GITEA_USER_OVERRIDE GITEA_REPO_OVERRIDE
            mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
            remediation_notify_dispatch "$task_id" "$title" "FAILED" "Failed to provision isolated worktree $sandbox_dir"
            [ -n "$target_task_id" ] && break
            continue
        }

        # Exact base commit SHA of this worktree (works even when module repos are installed on detached HEAD)
        local worktree_base_sha
        worktree_base_sha=$(git -C "$sandbox_dir" rev-parse HEAD 2>/dev/null || echo "$target_base_branch")

        # Write Task Bay Card Metadata & Tracking Files
        mkdir -p "$sandbox_dir/.george" 2>/dev/null || true
        [ -f "$orig_george_dir/keys.conf" ] && cp -f "$orig_george_dir/keys.conf" "$sandbox_dir/.george/keys.conf" 2>/dev/null && chmod 600 "$sandbox_dir/.george/keys.conf" 2>/dev/null || true
        [ -f "$orig_george_dir/gitea.conf" ] && cp -f "$orig_george_dir/gitea.conf" "$sandbox_dir/.george/gitea.conf" 2>/dev/null && chmod 600 "$sandbox_dir/.george/gitea.conf" 2>/dev/null || true
        if [ -x "$orig_lodge_dir/scripts/ci/bootstrap_env.sh" ]; then
            LODGE_DIR="$sandbox_dir" GEORGE_DIR="$sandbox_dir/.george" RECALL_DB="$sandbox_dir/.george/recall.db" \
                bash "$orig_lodge_dir/scripts/ci/bootstrap_env.sh" --no-apt >/dev/null 2>&1 || true
        else
            [ -f "$orig_george_dir/recall.db" ] && cp -f "$orig_george_dir/recall.db" "$sandbox_dir/.george/recall.db" 2>/dev/null || true
        fi
        local rem_runtime_dir="${orig_george_dir}/runtime/remediation/${task_id}"
        mkdir -p "$rem_runtime_dir/ipc/channels" "$rem_runtime_dir/ipc/promises" "$rem_runtime_dir/ipc/payloads" "$rem_runtime_dir/ipc/locks" 2>/dev/null || true
        [ -f "$orig_george_dir/keys.conf" ] && cp -f "$orig_george_dir/keys.conf" "$rem_runtime_dir/keys.conf" 2>/dev/null || true
        [ -f "$orig_george_dir/gitea.conf" ] && cp -f "$orig_george_dir/gitea.conf" "$rem_runtime_dir/gitea.conf" 2>/dev/null || true
        if declare -f task_fsm_init &>/dev/null; then
            task_fsm_init "$sandbox_dir" "remediation_${task_id}" "remediation" "Sovereign Remediation: $title" "$branch_name" "1" "" "$cur_pid"
            task_fsm_transition "$sandbox_dir" "STAGING" "Staging" "$cur_pid"
        else
            echo "$cur_pid" > "$sandbox_dir/.pid" 2>/dev/null || true
            echo "Staging" > "$sandbox_dir/.phase" 2>/dev/null || true
        fi
        cat > "$sandbox_dir/task_meta.json" <<META_EOF
{
  "id": "remediation_${task_id}",
  "name": "remediation_${task_id}",
  "type": "remediation",
  "task_type": "remediation",
  "title": "$title",
  "command": "Sovereign Remediation: $title",
  "objective": "Sovereign Remediation: $title",
  "branch": "$branch_name",
  "phase": "Staging",
  "started_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date +'%Y-%m-%d %H:%M:%S')"
}
META_EOF
        ln -sf "$rem_log" "$sandbox_dir/trajectory.log" 2>/dev/null || true

        # Post STAGING checkpoint
        remediation_post_checkpoint "$gitea_idx" "STAGING" \
            "Isolated worktree sandbox initialized on branch \`${branch_name}\`. Workspace primed for Slot 1 execution." \
            "- **Sandbox Path:** \`${sandbox_dir}\`"$'\n'"- **Active Branch:** \`${branch_name}\`" \
            "$task_id"

        # Execute remediation loop inside sandbox (Targeting Slot 1 / Tier 2)
        ui_step "Executing remediation contract in sandbox..."
        mkdir -p "$sandbox_dir/.george/issues" "$sandbox_dir/.george/telemetry/incidents"
        [ -n "$issue_file" ] && [ -f "$issue_file" ] && cp -f "$issue_file" "$sandbox_dir/.george/issues/" 2>/dev/null || true
        [ -n "$inc_dir" ] && [ -d "$inc_dir" ] && cp -rf "$inc_dir" "$sandbox_dir/.george/telemetry/incidents/" 2>/dev/null || true
        # .george/ is gitignored, so evidence the issue cites (sentinel escalations,
        # archived issues, telemetry) is absent from the worktree. Copy cited live
        # files in (regular files only, no '..', <=1 MiB each, max 15).
        if [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
            local _rel _n_ev=0
            while IFS= read -r _rel; do
                [ "$_n_ev" -ge 15 ] && break
                case "$_rel" in .george/*) ;; *) continue ;; esac
                case "/$_rel/" in */../*) continue ;; esac
                [ -f "$orig_lodge_dir/$_rel" ] && [ ! -L "$orig_lodge_dir/$_rel" ] || continue
                [ -e "$sandbox_dir/$_rel" ] && continue
                [ "$(stat -c %s "$orig_lodge_dir/$_rel" 2>/dev/null || echo 0)" -le 1048576 ] || continue
                mkdir -p "$sandbox_dir/$(dirname "$_rel")" 2>/dev/null && \
                    cp -f "$orig_lodge_dir/$_rel" "$sandbox_dir/$_rel" 2>/dev/null && _n_ev=$((_n_ev + 1))
            done < <(grep -oE '\.george/[A-Za-z0-9_./-]+' "$issue_file" 2>/dev/null | sed -E 's/[.]+$//' | sort -u)
        fi

        local rel_issue=""
        [ -n "$issue_file" ] && rel_issue=".george/issues/$(basename "$issue_file")"
        local rel_inc=""
        [ -n "$inc_dir" ] && rel_inc=".george/telemetry/incidents/$(basename "$inc_dir")"

        local _rem_tier="${REMEDIATION_TIER:-}"
        if [ -z "$_rem_tier" ] && declare -f endpoints_resolve_for_objective &>/dev/null; then
            local _rem_res
            _rem_res=$(endpoints_resolve_for_objective "remediation" 2>/dev/null || true)
            if [ -n "$_rem_res" ]; then
                IFS='|' read -r _rem_tier _ _ _ <<< "$_rem_res"
            fi
        fi
        export ACTIVE_TIER="${_rem_tier:-1}"
        export LODGE_DIR="$sandbox_dir"
        export GEORGE_DIR="$sandbox_dir/.george"
        export GEORGE_RUNTIME_DIR="$rem_runtime_dir"
        export FIFO_IPC_DIR="$rem_runtime_dir/ipc"
        export AGENT_SOVEREIGN_REMEDIATION=1
        export AGENT_MAX_TURNS="${AGENT_REMEDIATION_MAX_TURNS:-200}"
        export AGENT_IPC_PRIORITY="${IPC_PRIO_REMEDIATION:-20}"

        # ── Pre-flight Verification Gate ──────────────────────────────────────
        # Verify whether the reported failure is already resolved on current HEAD
        # (e.g. via a merged PR or preceding commit) before launching expensive LLM turns.
        local preflight_resolved=0
        local preflight_summary=""

        if [ "${_LODGE_TESTING:-0}" -ne 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ]; then
            case "$fp" in
                ci_fail_*)
                    local pf_syntax=0 pf_cited_ok=0
                    local failed_commit="" cur_full_sha=""
                    cur_full_sha=$(git -C "$sandbox_dir" rev-parse HEAD 2>/dev/null || true)
                    if [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
                        failed_commit=$(grep -oE '\*\*Failing Commit:\*\* [0-9a-f]{7,40}' "$issue_file" 2>/dev/null | awk '{print $3}' | head -n 1)
                        if [ -z "$failed_commit" ]; then
                            failed_commit=$(grep -oE '"commit":[[:space:]]*"[0-9a-f]{7,40}"' "$issue_file" 2>/dev/null | grep -oE '[0-9a-f]{7,40}' | head -n 1)
                        fi
                    fi

                    # Never declare PREFLIGHT_RESOLVED if current HEAD is still the exact commit that failed in CI
                    if [ -n "$failed_commit" ] && [ -n "$cur_full_sha" ] && [[ "$cur_full_sha" == "${failed_commit}"* ]]; then
                        pf_syntax=0
                        pf_cited_ok=0
                    else
                        if ( cd "$sandbox_dir" && find lib commands tests -name "*.sh" -exec bash -n {} + 2>/dev/null ); then
                            pf_syntax=1
                        fi
                        local cited_tests=""
                        if [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
                            cited_tests=$(grep -oE 'tests/test_[A-Za-z0-9_]+\.sh' "$issue_file" 2>/dev/null | sort -u)
                        fi
                        if [ -n "$cited_tests" ]; then
                            pf_cited_ok=1
                            local _ct
                            while IFS= read -r _ct; do
                                [ -z "$_ct" ] && continue
                                if [ -f "$sandbox_dir/$_ct" ] && ! ( cd "$sandbox_dir" && bash "$_ct" >/dev/null 2>&1 ); then
                                    pf_cited_ok=0
                                    break
                                fi
                            done <<< "$cited_tests"
                        elif [[ "${title,,}" == *phytology* ]]; then
                            if ( cd "$sandbox_dir" && bash tests/test_phytology.sh >/dev/null 2>&1 ) && \
                               ( cd "$sandbox_dir" && bash -c "source lib/agents/phytology.sh && phytology_audit" >/dev/null 2>&1 ); then
                                pf_cited_ok=1
                            fi
                        elif [ -x "$sandbox_dir/scripts/ci/hermetic_test_runner.sh" ]; then
                            if ( cd "$sandbox_dir" && bash scripts/ci/hermetic_test_runner.sh tests/test_okf.sh tests/test_graph_and_routing_parity.sh >/dev/null 2>&1 ); then
                                pf_cited_ok=1
                                if [ -x "$sandbox_dir/scripts/ci/select_tests.sh" ]; then
                                    local _sel_suite
                                    for _sel_suite in $(cd "$sandbox_dir" && bash scripts/ci/select_tests.sh --ci 2>/dev/null); do
                                        if [ -f "$sandbox_dir/tests/${_sel_suite}.sh" ] && ! ( cd "$sandbox_dir" && bash "tests/${_sel_suite}.sh" >/dev/null 2>&1 ); then
                                            pf_cited_ok=0
                                            break
                                        fi
                                    done
                                fi
                            fi
                        fi
                    fi

                    if [ "$pf_syntax" -eq 1 ] && [ "$pf_cited_ok" -eq 1 ]; then
                        preflight_resolved=1
                        local cur_sha
                        cur_sha=$(git -C "$sandbox_dir" rev-parse --short HEAD 2>/dev/null || echo "HEAD")
                        preflight_summary="All cited CI validation gates pass cleanly on commit ${cur_sha}. Defect was already remediated by a preceding commit or PR."
                    fi
                    ;;

                phytology_*)
                    if ( cd "$sandbox_dir" && bash -c "source lib/agents/phytology.sh && phytology_audit" >/dev/null 2>&1 ); then
                        preflight_resolved=1
                        preflight_summary="Software Phytology parallel living tissue audit verified 100% healthy AST contracts on current HEAD. No corrupted tissue detected."
                    fi
                    ;;

                job_fail_*)
                    local _jf_id="${fp#job_fail_}"
                    local _jf_tlog="$orig_lodge_dir/.sandboxes/cron_${_jf_id}/trajectory.log"
                    if [ "$_jf_id" = "tyler_immune_patrol" ] && python3 "$orig_lodge_dir/lib/tools/tyler_guardian.py" immune-patrol --duration 1 >/dev/null 2>&1; then
                        preflight_resolved=1
                        preflight_summary="Scheduled job '${_jf_id}' passed live pre-flight verification cleanly. Transient defect is already resolved."
                    elif [ -f "$_jf_tlog" ] && tail -n 30 "$_jf_tlog" 2>/dev/null | grep -q '"status": "ok"'; then
                        preflight_resolved=1
                        preflight_summary="Scheduled job '${_jf_id}' succeeded on a subsequent execution after the incident. Transient defect is already resolved."
                    fi
                    ;;
            esac
        fi

        if [ "$preflight_resolved" -eq 1 ]; then
            ui_ok "Pre-flight verification: $preflight_summary"
            echo "[PREFLIGHT_RESOLVED] $preflight_summary" >> "$rem_log"

            # Post resolved checkpoint and close Gitea issue
            if [ -n "$gitea_idx" ]; then
                remediation_post_checkpoint "$gitea_idx" "VERIFICATION" \
                    "$preflight_summary" \
                    "- **Status:** Already resolved on target branch"$'\n'"- **Commit:** \`$(git -C "$sandbox_dir" rev-parse --short HEAD 2>/dev/null || echo "HEAD")\`" \
                    "$task_id"
                if declare -f gitea_issue_close &>/dev/null; then
                    gitea_issue_close "$gitea_idx" >/dev/null 2>&1 || true
                    ui_ok "Closed Sovereign Gitea Issue #${gitea_idx}"
                fi
            fi

            # Archive issue file
            if [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
                local arch_dir="${orig_george_dir}/issues/archive"
                mkdir -p "$arch_dir" 2>/dev/null || true
                mv "$issue_file" "$arch_dir/" 2>/dev/null || true
            fi

            # Move progress file to completed
            mv "$progress_file" "$REMEDIATION_COMPLETED_DIR/${task_id}.json"
            jq --arg reason "$preflight_summary" '.status = "COMPLETED" | .resolution = "PREFLIGHT_ALREADY_RESOLVED" | .details = $reason' \
                "$REMEDIATION_COMPLETED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && \
                mv "${progress_file}.tmp" "$REMEDIATION_COMPLETED_DIR/${task_id}.json" 2>/dev/null || true

            # Reset attempt counter
            local attempt_key="${fp:-$task_id}"
            rm -f "$REMEDIATION_ATTEMPTS_DIR/${attempt_key}.json" 2>/dev/null || true

            # Clean up ephemeral sandbox worktree
            ui_ok "Culling ephemeral sandbox worktree: $sandbox_dir"
            git -C "$target_repo_dir" worktree remove --force "$sandbox_dir" 2>/dev/null || true
            rm -rf "$sandbox_dir" 2>/dev/null || true
            git -C "$target_repo_dir" branch -D "$branch_name" 2>/dev/null || true
            git -C "$target_repo_dir" push "$target_git_remote" --delete "$branch_name" >/dev/null 2>&1 || true

            remediation_notify_dispatch "$task_id" "$title" "RESOLVED" "$preflight_summary"

            processed_any=$((processed_any + 1))
            [ -n "$target_task_id" ] && break
            continue
        fi

        # Update phase to Diagnosis / Active
        if declare -f task_fsm_transition &>/dev/null; then
            task_fsm_transition "$sandbox_dir" "RUNNING" "Active" "$cur_pid"
        else
            echo "Active" > "$sandbox_dir/.phase" 2>/dev/null || true
        fi

        # Post DIAGNOSIS checkpoint
        remediation_post_checkpoint "$gitea_idx" "DIAGNOSIS" \
            "Investigating root cause for defect '${title}' (Fingerprint: \`${fp:-N/A}\`). Enforcing pure POSIX shell architectural boundaries." \
            "- **Target Tier:** Tier ${ACTIVE_TIER:-1} / Cooperative Slot"$'\n'"- **Max Turns:** ${AGENT_MAX_TURNS:-200}"$'\n'"- **IPC Priority:** ${AGENT_IPC_PRIORITY}" \
            "$task_id"

        local _container_guidance="- Prefer sovereign zero-dependency native POSIX implementations (bash, jq, awk, sed)."
        if declare -f container_available &>/dev/null && container_available 2>/dev/null; then
            _container_guidance="- If a task requires heavy libraries, encapsulate execution inside an isolated container sandbox via 'container_exec' or disposable sandbox environment."
        fi

        local rem_success=1
        local rem_prompt="You are George in Sovereign Autonomous Remediation mode.
Remediate the failure documented in issue: $sandbox_dir/$rel_issue
Workspace Issue File: $rel_issue
Incident dossier: $sandbox_dir/$rel_inc
Error Fingerprint: $fp

SOVEREIGN REMEDIATION & ARCHITECTURAL INTEGRITY MANDATE:
1. Examine the failure evidence, error traces, and reproduction details.
2. OKF KNOWLEDGE GRAPH & BLAST-RADIUS ANALYSIS:
   - Before modifying any file or symbol, call 'okf_traverse(seed=\"<file_or_symbol>\")' or 'okf_query(target=\"<file>\")' (or query '.george/recall.db' tables 'okf_nodes', 'okf_edges', 'tool_telemetry_stats') to understand upstream callers, downstream dependencies ('dependsOn'), and cross-module impact so your fix is complete and introduces zero regressions.
3. ARCHITECTURAL INTEGRITY & HERMETIC CI PARITY (Tyler & Warden Review Mandate):
   - Blue Lodge is a polyglot sovereign system: Bash control plane (lib/, commands/), Python 3 intelligence/trading/quant/training tools (lib/tools/, scripts/, okf/), SQLite FTS5 (.george/recall.db), and Rust Axum Web UI (web/).
   - Never mutate the global host OS via unapproved global pip/npm installs during a run; if a CI job requires standard packages, declare them cleanly in 'scripts/ci/bootstrap_env.sh' / '.gitea/workflows/ci.yml' and guard optional Python imports with try/except fallbacks.
   ${_container_guidance}
   - Do NOT modify denylisted core files (lib/core/react*, lib/core/agent*, lib/comms/discord_bridge.sh, lib/comms/web.sh).
   - Never bypass failing tests by adding top-level 'exit 0' skip guards; verify fixes hermetically via 'bash scripts/ci/hermetic_test_runner.sh <test_file>'.
4. ADAPTIVE PATHFINDING & FALLBACKS:
   - If the failure stems from a missing external service or unconfigured provider (e.g. email, discord, gsuite), wire in graceful multi-provider fallbacks or disposable one-time adapters.
5. CODEBASE FIX & COMMIT WORKFLOW:
   - If this failure requires a permanent codebase fix, tool wrapper, or configuration change, implement and commit the fix on this remediation branch (${branch_name}).
   - Do NOT call 'gitea_pr_create' or merge the branch yourself; the Sovereign Remediation controller automatically verifies your commits, enforces write-scope gates, and proposes the Pull Request after you finish.
6. Verify your fix thoroughly by executing automated test suites before concluding."

        if declare -f react_run &>/dev/null; then
            export AGENT_SOVEREIGN_REMEDIATION=1
            export REACT_SESSION_ID="remediation_${task_id}"
            react_run "$rem_prompt" "$sandbox_dir" "${AGENT_REMEDIATION_MAX_TURNS:-200}" 1.0 "remediation_${task_id}" "remediation" 2>&1 | tee -a "$rem_log"
            local ec=${PIPESTATUS[0]}
            unset AGENT_SOVEREIGN_REMEDIATION
            unset REACT_SESSION_ID
            if [ "$ec" -eq 0 ]; then
                rem_success=0
                # Unconditional post-react syntax check on modified files (Bash, Python, JS)
                local _mod_f
                while IFS= read -r _mod_f; do
                    [ -z "$_mod_f" ] && continue
                    if [[ "$_mod_f" == *.sh ]] && [ -f "$sandbox_dir/$_mod_f" ]; then
                        if ! bash -n "$sandbox_dir/$_mod_f" 2>>"$rem_log"; then
                            echo "[verify] post-react syntax error in $_mod_f" | tee -a "$rem_log"
                            rem_success=1
                        fi
                    elif [[ "$_mod_f" == *.py ]] && [ -f "$sandbox_dir/$_mod_f" ] && command -v python3 &>/dev/null; then
                        if ! python3 -m py_compile "$sandbox_dir/$_mod_f" 2>>"$rem_log"; then
                            echo "[verify] post-react python syntax error in $_mod_f" | tee -a "$rem_log"
                            rem_success=1
                        fi
                    elif [[ "$_mod_f" == *.js ]] && [ -f "$sandbox_dir/$_mod_f" ] && command -v node &>/dev/null; then
                        if ! node --check "$sandbox_dir/$_mod_f" 2>>"$rem_log"; then
                            echo "[verify] post-react JS syntax error in $_mod_f" | tee -a "$rem_log"
                            rem_success=1
                        fi
                    fi
                done < <(git -C "$sandbox_dir" diff --name-only "${worktree_base_sha}...HEAD" 2>/dev/null)

                # External Guild module verification gate: module_audit.py + module unit tests
                if [ "$target_kind" = "module" ] && [ "$rem_success" -eq 0 ]; then
                    local _py_bin="python3"
                    local _cand_py
                    for _cand_py in "$orig_george_dir/modules/.venv/bin/python" "$orig_lodge_dir/.venv/bin/python"; do
                        [ -x "$_cand_py" ] && { _py_bin="$_cand_py"; break; }
                    done
                    if [ -f "$orig_lodge_dir/lib/tools/module_audit.py" ]; then
                        if ! "$_py_bin" "$orig_lodge_dir/lib/tools/module_audit.py" "$sandbox_dir" >>"$rem_log" 2>&1; then
                            echo "[verify] module_audit.py rejected remediation changes for module '$target_mod_id'" | tee -a "$rem_log"
                            rem_success=1
                        fi
                    fi
                    if [ "$rem_success" -eq 0 ] && [ -d "$sandbox_dir/tests" ]; then
                        local _tf
                        for _tf in "$sandbox_dir"/tests/test_*.py; do
                            [ -f "$_tf" ] || continue
                            if grep -q 'unittest\.TestCase' "$_tf" 2>/dev/null && ! grep -q '__main__' "$_tf" 2>/dev/null; then
                                if ! "$_py_bin" -m unittest discover -s "$sandbox_dir/tests" -p "$(basename "$_tf")" >>"$rem_log" 2>&1; then
                                    echo "[verify] module unittest failed: $_tf" | tee -a "$rem_log"
                                    rem_success=1
                                fi
                            else
                                if ! "$_py_bin" "$_tf" >>"$rem_log" 2>&1; then
                                    echo "[verify] module test failed: $_tf" | tee -a "$rem_log"
                                    rem_success=1
                                fi
                            fi
                        done
                    fi
                fi
            fi
        else
            # Direct verification gate
            if [ "$target_kind" = "module" ]; then
                local _py_bin="python3" _cand_py _vok=1
                for _cand_py in "$orig_george_dir/modules/.venv/bin/python" "$orig_lodge_dir/.venv/bin/python"; do
                    [ -x "$_cand_py" ] && { _py_bin="$_cand_py"; break; }
                done
                if [ -f "$orig_lodge_dir/lib/tools/module_audit.py" ]; then
                    if ! "$_py_bin" "$orig_lodge_dir/lib/tools/module_audit.py" "$sandbox_dir" >>"$rem_log" 2>&1; then
                        echo "[verify] module_audit.py failed for '$target_mod_id'" | tee -a "$rem_log"
                        _vok=0
                    fi
                fi
                if [ "$_vok" -eq 1 ] && [ -d "$sandbox_dir/tests" ]; then
                    local _tf
                    for _tf in "$sandbox_dir"/tests/test_*.py; do
                        [ -f "$_tf" ] || continue
                        if grep -q 'unittest\.TestCase' "$_tf" 2>/dev/null && ! grep -q '__main__' "$_tf" 2>/dev/null; then
                            "$_py_bin" -m unittest discover -s "$sandbox_dir/tests" -p "$(basename "$_tf")" >>"$rem_log" 2>&1 || _vok=0
                        else
                            "$_py_bin" "$_tf" >>"$rem_log" 2>&1 || _vok=0
                        fi
                    done
                fi
                [ "$_vok" -eq 1 ] && rem_success=0
            else
                local _vt=(test_telemetry test_incident_preservation test_remediation_queue) _vf _vok=1
                while IFS= read -r _vf; do
                    [ -n "$_vf" ] || continue
                    case "$_vf" in
                        *.sh) if [ -f "$sandbox_dir/$_vf" ] && ! bash -n "$sandbox_dir/$_vf" 2>>"$rem_log"; then
                                  echo "[verify] syntax error in $_vf" | tee -a "$rem_log"; _vok=0
                              fi ;;
                    esac
                    local _vb; _vb=$(basename "$_vf" .sh)
                    [ -f "$sandbox_dir/tests/test_${_vb}.sh" ] && [[ " ${_vt[*]} " != *" test_${_vb} "* ]] && _vt+=("test_${_vb}")
                done < <(git -C "$sandbox_dir" diff --name-only HEAD 2>/dev/null; git -C "$sandbox_dir" diff --name-only "${worktree_base_sha}" HEAD 2>/dev/null)
                if [ "$_vok" -eq 1 ]; then
                    bash "$sandbox_dir/tests/run_all.sh" "${_vt[@]}" 2>&1 | tee -a "$rem_log"
                    [ "${PIPESTATUS[0]}" -eq 0 ] && rem_success=0
                fi
            fi
        fi

        # Reset environment back to host lodge and close per-remediation IPC channel
        unset AGENT_SOVEREIGN_REMEDIATION
        export LODGE_DIR="$orig_lodge_dir"
        export GEORGE_DIR="$orig_george_dir"
        export ACTIVE_TIER="$orig_tier"
        if declare -f fifo_channel_close &>/dev/null; then
            fifo_channel_close "remediation_${task_id}" 2>/dev/null || true
        fi

        if declare -f task_fsm_transition &>/dev/null; then
            task_fsm_transition "$sandbox_dir" "VERIFICATION" "Verification" "$cur_pid"
        else
            echo "Verification" > "$sandbox_dir/.phase" 2>/dev/null || true
        fi

        local attempt_key="${fp:-${gitea_idx:-$task_id}}"
        local attempt_file="$REMEDIATION_ATTEMPTS_DIR/${attempt_key}.json"

        if [ "$rem_success" -eq 0 ]; then
            echo "[REMEDIATION_COMPLETE]" >> "$rem_log"
            ui_ok "Remediation verified successfully! Checking for code deliverables..."

            local commit_count=0
            commit_count=$(git -C "$sandbox_dir" rev-list --count HEAD "^${worktree_base_sha}" 2>/dev/null || echo 0)

            # Write-scope denylist: enforced on Heartwood and Ecotype remediations so denylisted core files
            # and gitignored runtime state (.george/*) are never committed into blue-lodge.
            local scope_viol=""
            if [ "$target_kind" = "heartwood" ] || [ "$target_kind" = "ecotype" ]; then
                scope_viol=$(git -C "$sandbox_dir" diff --name-only "${worktree_base_sha}...HEAD" 2>/dev/null | remediation_scope_violations_from_list)
            fi
            if [ -n "$scope_viol" ]; then
                ui_warn "Remediation touched denylisted paths; delivery blocked for operator review:"$'\n'"$scope_viol"
                echo "[SCOPE_DENYLIST_BLOCKED] $scope_viol" >> "$rem_log"
                remediation_post_checkpoint "$gitea_idx" "BLOCKED" \
                    "Fix modified denylisted paths; branch kept locally, not pushed. Operator review required." \
                    "- **Denylisted paths:** $(echo "$scope_viol" | tr '\n' ' ')" "$task_id"
                commit_count=0
            fi

            # Post VERIFICATION checkpoint
            remediation_post_checkpoint "$gitea_idx" "VERIFICATION" \
                "Verification passed cleanly. Automated test suite confirmed green in isolated sandbox." \
                "- **Target Repo:** \`${target_gitea_user}/${target_gitea_repo}@${target_base_branch}\` (${target_kind})"$'\n'"- **Sandbox Verification:** PASSED"$'\n'"- **Commit Deliverables:** ${commit_count} commit(s)" \
                "$task_id"

            local retain_local_branch=0
            [ -n "$scope_viol" ] && retain_local_branch=1

            if [ "$commit_count" -gt 0 ]; then
                ui_step "Delivering code fix: pushing branch '$branch_name' ($commit_count commits) to ${target_git_remote} (${target_gitea_user}/${target_gitea_repo})..."
                local push_ok=0
                if GIT_TERMINAL_PROMPT=0 git -C "$sandbox_dir" push --no-verify "$target_git_remote" "$branch_name" >/dev/null 2>&1 || \
                   GIT_TERMINAL_PROMPT=0 git -C "$target_repo_dir" push --no-verify "$target_git_remote" "$branch_name" >/dev/null 2>&1; then
                    push_ok=1
                elif [ "$target_kind" = "module" ]; then
                    # Fallback for public HTTPS-installed modules: push to writable local Gitea mirror if configured
                    local _g_push_base
                    _g_push_base=$(git -C "$orig_lodge_dir" remote get-url gitea 2>/dev/null | sed -E 's|/[^/]+(\.git)?$||' || true)
                    if [ -n "$_g_push_base" ] && [[ "$_g_push_base" == http* ]]; then
                        if GIT_TERMINAL_PROMPT=0 git -C "$sandbox_dir" push --no-verify "${_g_push_base}/${target_gitea_repo}.git" "$branch_name" >/dev/null 2>&1; then
                            push_ok=1
                        fi
                    fi
                fi

                if [ "$push_ok" -ne 1 ]; then
                    retain_local_branch=1
                    ui_warn "Could not push '$branch_name' (remote may be read-only public HTTPS); retaining verified local branch in $target_repo_dir."
                    echo "[LOCAL_BRANCH_READY] $target_repo_dir:$branch_name" >> "$rem_log"
                    remediation_post_checkpoint "$gitea_idx" "DELIVERY" \
                        "Verified fix committed locally on branch \`${branch_name}\`, but push to remote failed (read-only/offline remote). Local branch retained for manual review or fork push." \
                        "- **Repo Dir:** \`${target_repo_dir}\`"$'\n'"- **Branch:** \`${branch_name}\` ($commit_count commit(s))" \
                        "$task_id"
                fi

                export GITEA_CONF="$sandbox_dir/.george/gitea.conf"
                [ ! -f "$GITEA_CONF" ] && export GITEA_CONF="$orig_george_dir/gitea.conf"
                if [ "$push_ok" -eq 1 ]; then
                if ! declare -f gitea_pr_create &>/dev/null; then
                    [ -f "${orig_lodge_dir}/lib/tools/mcp_server_gitea.sh" ] && source "${orig_lodge_dir}/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
                fi
                if declare -f gitea_pr_create &>/dev/null; then
                    local git_log diff_stat
                    git_log=$(git -C "$sandbox_dir" log --oneline "${worktree_base_sha}..HEAD" 2>/dev/null | head -n 15)
                    diff_stat=$(git -C "$sandbox_dir" diff --stat "${worktree_base_sha}...HEAD" 2>/dev/null | head -n 25)

                    local pr_title="fix(remediation): $title"
                    local pr_body="## 🛠️ Sovereign Autonomous Remediation (${target_kind})

### Problem Statement
- **Issue:** ${title}
- **Target Repo:** \`${target_gitea_user}/${target_gitea_repo}\` (base: \`${target_base_branch}\`)
- **Error Fingerprint:** \`${fp:-N/A}\`
- **Task ID:** \`${task_id}\`
- **Branch:** \`${branch_name}\`
$([ -n "$gitea_idx" ] && echo "- **Resolves Gitea Issue:** #${gitea_idx}" || echo "")

### Root Cause & Remediation Summary
Automated remediation executed on Slot 1 inside an isolated git worktree sandbox. The defect was resolved in strict compliance with the Sovereign Remediation Mandate and verified cleanly.

### Delivered Commits
\`\`\`
${git_log:-No additional commits}
\`\`\`

### Modified Files & Diffstat
\`\`\`
${diff_stat:-No diff stat available}
\`\`\`

### Verification Evidence
- Automated test verification passed cleanly in isolated sandbox.
- Ephemeral worktree sandbox culled immediately upon completion.
"
                    local pr_res
                    pr_res=$(gitea_pr_create "$branch_name" "$target_base_branch" "$pr_title" "$pr_body" 2>/dev/null || true)
                    local pr_num
                    pr_num=$(echo "$pr_res" | jq -r '.number // empty' 2>/dev/null || true)
                    if [ -n "$pr_num" ]; then
                        ui_ok "Proposed Sovereign Gitea Pull Request #${pr_num} on ${target_gitea_user}/${target_gitea_repo}: $pr_title"

                        if [ "$(remediation_apply_mode)" != "auto" ]; then
                            ui_info "Apply mode 'propose': PR #${pr_num} left open for pr_sweep review and merge gate."
                        elif declare -f gitea_pr_merge &>/dev/null; then
                            ui_step "Autonomously merging PR #${pr_num} into ${target_gitea_user}/${target_gitea_repo}@${target_base_branch}..."
                            if gitea_pr_merge "$pr_num" "merge"; then
                                ui_ok "Merged PR #${pr_num} into ${target_gitea_user}/${target_gitea_repo}@${target_base_branch}."
                                git -C "$target_repo_dir" fetch "$target_git_remote" "$target_base_branch" >/dev/null 2>&1 || true
                                local cur_branch
                                cur_branch=$(git -C "$target_repo_dir" branch --show-current 2>/dev/null)
                                if [ "$cur_branch" = "$target_base_branch" ]; then
                                    git -C "$target_repo_dir" merge --ff-only "${target_git_remote}/${target_base_branch}" >/dev/null 2>&1 || \
                                    git -C "$target_repo_dir" merge -m "Merge sovereign remediation #${pr_num}" "${target_git_remote}/${target_base_branch}" >/dev/null 2>&1 || true
                                    ui_ok "Local ${target_gitea_repo}@${target_base_branch} synchronized."
                                fi
                                # If external module was remediated, rebuild merged tool cache
                                if [ "$target_kind" = "module" ] && [ -f "$orig_lodge_dir/lib/sys/modules.sh" ]; then
                                    ( source "$orig_lodge_dir/lib/sys/modules.sh" 2>/dev/null && modules_rebuild_tools_cache >/dev/null 2>&1 ) || true
                                fi
                                # Clean up remediation branch on Gitea
                                git -C "$target_repo_dir" push "$target_git_remote" --delete "$branch_name" >/dev/null 2>&1 || true
                            fi
                        fi

                        # Post DELIVERY checkpoint
                        remediation_post_checkpoint "$gitea_idx" "DELIVERY" \
                            "$([ "$(remediation_apply_mode)" = "auto" ] && echo "Sovereign PR #${pr_num} merged into ${target_gitea_user}/${target_gitea_repo}@${target_base_branch}. Issue resolved." || echo "Sovereign PR #${pr_num} proposed for automated review & merge gate (apply mode: propose).")" \
                            "- **Repo:** \`${target_gitea_user}/${target_gitea_repo}\`"$'\n'"- **PR:** #${pr_num}"$'\n'"- **Head Branch:** \`${branch_name}\`"$'\n'"- **Base:** \`${target_base_branch}\`" \
                            "$task_id"
                    fi
                fi
                fi
            fi

            # Reset attempt counter on success
            rm -f "$attempt_file" 2>/dev/null || true

            # Mark sandbox as Completed before culling
            if declare -f task_fsm_transition &>/dev/null; then
                task_fsm_transition "$sandbox_dir" "COMPLETED" "Completed" "$cur_pid" "0"
            else
                echo "Completed" > "$sandbox_dir/.phase" 2>/dev/null || true
                touch "$sandbox_dir/.done" 2>/dev/null || true
            fi

            # Immediate ephemeral worktree culling
            ui_ok "Culling ephemeral sandbox worktree and closing issue."
            git -C "$target_repo_dir" worktree remove --force "$sandbox_dir" 2>/dev/null || true
            rm -rf "$sandbox_dir" 2>/dev/null || true
            git -C "$target_repo_dir" worktree prune 2>/dev/null || true
            if [ "$retain_local_branch" -eq 0 ]; then
                git -C "$target_repo_dir" branch -D "$branch_name" 2>/dev/null || true
            fi

            # Close Sovereign Gitea issue if linked
            if [ -n "$gitea_idx" ]; then
                if ! declare -f gitea_issue_close &>/dev/null; then
                    [ -f "${orig_lodge_dir}/lib/tools/mcp_server_gitea.sh" ] && source "${orig_lodge_dir}/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
                fi
                if declare -f gitea_issue_close &>/dev/null; then
                    gitea_issue_close "$gitea_idx" "Autonomous remediation completed and verified cleanly by George on Slot 1. Task: $task_id" >/dev/null 2>&1 || true
                    ui_ok "Closed Sovereign Gitea Issue #${gitea_idx}"
                fi
            fi

            # Move to completed
            mv "$progress_file" "$REMEDIATION_COMPLETED_DIR/${task_id}.json"
            jq '.status = "COMPLETED"' "$REMEDIATION_COMPLETED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_COMPLETED_DIR/${task_id}.json" 2>/dev/null || true

            # Archive local issue
            if [ -n "$issue_file" ] && [ -f "$issue_file" ]; then
                local archive_issues_dir="$GEORGE_DIR/issues/archive"
                mkdir -p "$archive_issues_dir" 2>/dev/null || true
                mv "$issue_file" "$archive_issues_dir/" 2>/dev/null || true
                ui_dim "Archived resolved issue: $issue_file -> $archive_issues_dir/"
            fi

            # Broadcast resolution to waiting parent tasks
            if declare -f mqtt_publish &>/dev/null; then
                local res_payload
                res_payload=$(jq -n \
                    --arg tid "$task_id" \
                    --arg title "$title" \
                    --arg br "$branch_name" \
                    --arg pr "${pr_num:-}" \
                    --arg st "RESOLVED" \
                    '{ task_id: $tid, title: $title, branch: $br, pr: $pr, status: $st }' 2>/dev/null || echo "{\"task_id\":\"$task_id\",\"status\":\"RESOLVED\"}")
                mqtt_publish "george/remediation/${task_id}/resolution" "$res_payload" >/dev/null 2>&1 || true
            fi

            # Notify operator of success
            remediation_notify_dispatch "$task_id" "$title" "RESOLVED" \
                "Autonomous remediation completed and verified cleanly. Issue closed and archived."
        else
            echo "[REMEDIATION_FAILED]" >> "$rem_log"
            ui_warn "Remediation verification did not pass clean gate."

            # Mark sandbox as Failed before culling
            if declare -f task_fsm_transition &>/dev/null; then
                task_fsm_transition "$sandbox_dir" "FAILED" "Failed" "$cur_pid" "1"
            else
                echo "Failed" > "$sandbox_dir/.phase" 2>/dev/null || true
                touch "$sandbox_dir/.done" 2>/dev/null || true
            fi

            # 3-Strike failure tracking
            local attempt_count=0
            [ -f "$attempt_file" ] && attempt_count=$(jq -r '.attempts // 0' "$attempt_file" 2>/dev/null || echo 0)
            attempt_count=$((attempt_count + 1))
            local now_ts
            now_ts=$(date +%s)
            jq -n \
                --arg tid "$task_id" \
                --arg key "$attempt_key" \
                --argjson att "$attempt_count" \
                --argjson ts "$now_ts" \
                '{task_id: $tid, key: $key, attempts: $att, last_failure_ts: $ts}' > "$attempt_file" 2>/dev/null || true

            if [ "$attempt_count" -ge 3 ]; then
                ui_warn "Remediation task reached 3-strike failure ceiling ($attempt_count/3). Escalating to operator review."
                remediation_post_checkpoint "$gitea_idx" "VERIFICATION" \
                    "Automated fix attempted 3 times without passing verification gates. Automatic re-queueing halted; manual operator review required." \
                    "- **Attempts:** 3/3"$'\n'"- **Branch Retained:** \`${branch_name}\`"$'\n'"- **Fingerprint:** \`${fp:-N/A}\`" \
                    "$task_id"

                if [ -n "$gitea_idx" ]; then
                    if ! declare -f gitea_issue_label &>/dev/null; then
                        [ -f "${orig_lodge_dir}/lib/tools/mcp_server_gitea.sh" ] && source "${orig_lodge_dir}/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
                    fi
                    if declare -f gitea_issue_label &>/dev/null; then
                        gitea_issue_label "$gitea_idx" "escalation-required" >/dev/null 2>&1 || true
                    fi
                fi
                remediation_notify_dispatch "$task_id" "$title" "ESCALATED" \
                    "Autonomous remediation exceeded 3-strike failure ceiling on branch $branch_name. Re-queueing halted; operator intervention required."
                mv "$progress_file" "$REMEDIATION_FAILED_DIR/${task_id}.json"
                jq '.status = "ESCALATED_OPERATOR_REQUIRED"' "$REMEDIATION_FAILED_DIR/${task_id}.json" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$REMEDIATION_FAILED_DIR/${task_id}.json" 2>/dev/null || true
            else
                local rem_strikes=$((3 - attempt_count))
                remediation_post_checkpoint "$gitea_idx" "VERIFICATION" \
                    "Attempt ${attempt_count}/3 failed verification gates on branch \`${branch_name}\`. ${rem_strikes} attempt(s) remaining before operator escalation." \
                    "- **Attempt:** ${attempt_count}/3"$'\n'"- **Status:** RE-QUEUED" \
                    "$task_id"

                remediation_notify_dispatch "$task_id" "$title" "FAILED" \
                    "Automated fix attempted on branch $branch_name failed verification gates (Attempt ${attempt_count}/3). Re-queued for retry."
                jq --argjson att "$attempt_count" '.status = "QUEUED" | .attempts = $att' "$progress_file" > "${progress_file}.tmp" 2>/dev/null && mv "${progress_file}.tmp" "$progress_file" 2>/dev/null || true
                mv "$progress_file" "$REMEDIATION_QUEUE_DIR/${task_id}.json" 2>/dev/null || true
            fi

            # Immediate ephemeral worktree culling (retaining git branch for operator review)
            ui_dim "Culling ephemeral sandbox worktree (retaining git branch $branch_name)..."
            git -C "$target_repo_dir" worktree remove --force "$sandbox_dir" 2>/dev/null || true
            rm -rf "$sandbox_dir" 2>/dev/null || true
            git -C "$target_repo_dir" worktree prune 2>/dev/null || true
        fi

        unset GITEA_USER_OVERRIDE GITEA_REPO_OVERRIDE
        processed_any=$((processed_any + 1))
        [ -n "$target_task_id" ] && break
    done

    rm -f "$lock_file" 2>/dev/null || true
    return 0
}

# ── 5. Reactive Event Ingress ─────────────────────────────────────────
# Consumes faults and failures emitted to event_bus.fifo:
#   - system.phytology_fault
#   - ci.build_failure
#   - system.job_failure / system.cron_failure
#   - system.sentinel_fault
# Deduplicates against existing tasks and 3-strike attempts, creates Gitea issue if needed,
# and enqueues task for autonomous execution.
# Usage: remediation_event_ingress <event_type> <json_payload>
remediation_event_ingress() {
    local event_type="${1:-}"
    local event_payload="${2:-}"

    [ -z "$event_type" ] && return 1

    remediation_init

    local title="" fp="" priority="normal"
    local issue_body="" gitea_idx="" existing_issue_file=""
    local now; now=$(date +%s)

    case "$event_type" in
        system.phytology_fault)
            local invalid_count invalid_tissues issues_json
            invalid_count=$(echo "$event_payload" | jq -r '.invalid_count // 0' 2>/dev/null || echo 0)
            invalid_tissues=$(echo "$event_payload" | jq -r '(.invalid_tissues // []) | join(", ")' 2>/dev/null || echo "living_tissue")
            [ -z "$invalid_tissues" ] && invalid_tissues="living_tissue"
            issues_json=$(echo "$event_payload" | jq '.issues // []' 2>/dev/null || echo "[]")

            title="Phytology Living Tissue Degraded: ${invalid_tissues}"
            fp="phytology_$(echo -n "$invalid_tissues" | md5sum | cut -d' ' -f1 | head -c 12)"
            priority="high"

            issue_body="# Phytology Living Tissue Degraded: ${invalid_tissues}

**Status:** Degraded
**Degraded Tissues Count:** ${invalid_count}
**Tissues:** ${invalid_tissues}
[fingerprint:${fp}]

### Incident Description
Software Phytology parallel living tissue audit detected ${invalid_count} degraded tissue(s).
Living code tissue health contracts were violated during health probe evaluation.

### Issues Detected
\`\`\`json
${issues_json}
\`\`\`

### Architectural Integrity Mandate
Ensure fixes preserve polyglot module contracts (Bash, Python 3, SQLite FTS5, Rust Web) and pass hermetic verification via \`bash scripts/ci/hermetic_test_runner.sh\`.
"
            ;;

        ci.build_failure)
            local run_id run_branch run_url run_title run_commit log_tail
            run_id=$(echo "$event_payload" | jq -r '.run_id // empty' 2>/dev/null)
            run_branch=$(echo "$event_payload" | jq -r '.head_branch // .branch // "develop"' 2>/dev/null)
            run_url=$(echo "$event_payload" | jq -r '.html_url // ""' 2>/dev/null)
            run_title=$(echo "$event_payload" | jq -r '.title // "CI Run Failed"' 2>/dev/null)
            run_commit=$(echo "$event_payload" | jq -r '.commit // .head_sha // empty' 2>/dev/null)
            log_tail=$(echo "$event_payload" | jq -r '.log_tail // empty' 2>/dev/null)

            # Never file recursive remediation-of-remediation issues for PR workbranches
            case "$run_branch" in
                remediation/*|subagent/*)
                    ui_dim "Event ingress: Ignoring CI build failure on PR branch '$run_branch' (managed by pr_sweep)." >&2
                    return 0
                    ;;
            esac

            # Fallback: fetch failed job log tail directly from Gitea API if missing from event payload
            if [ -z "$log_tail" ] && [ -n "$run_commit" ] && [ "${_LODGE_TESTING:-0}" -ne 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ]; then
                if ! declare -f _gitea_load_conf &>/dev/null; then
                    [ -f "${LODGE_DIR}/lib/tools/mcp_server_gitea.sh" ] && source "${LODGE_DIR}/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
                fi
                declare -f _gitea_load_conf &>/dev/null && _gitea_load_conf 2>/dev/null || true
                if [ -n "${GITEA_TOKEN:-}" ] && [ -n "${GITEA_URL:-}" ]; then
                    local _st_json _f_job_id
                    _st_json=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_URL}/api/v1/repos/${GITEA_USER:-george}/${GITEA_REPO:-blue-lodge}/commits/${run_commit}/status" 2>/dev/null || echo "{}")
                    _f_job_id=$(echo "$_st_json" | jq -r '[.statuses[]? | select(.status == "failure") | .target_url][0] // empty' 2>/dev/null | sed -nE 's|.*/jobs/([0-9]+).*|\1|p')
                    if [ -n "$_f_job_id" ]; then
                        log_tail=$(curl -s -H "Authorization: token ${GITEA_TOKEN}" "${GITEA_URL}/api/v1/repos/${GITEA_USER:-george}/${GITEA_REPO:-blue-lodge}/actions/jobs/${_f_job_id}/logs" 2>/dev/null | tail -n 45 || true)
                    fi
                fi
            fi

            title="CI Build Failure: ${run_title} (Run #${run_id:-unknown} on ${run_branch})"
            fp="ci_fail_${run_branch//\//_}"
            [ -z "${run_branch:-}" ] && fp="ci_fail_develop"
            priority="high"

            local log_section=""
            if [ -n "$log_tail" ]; then
                log_section="
### Failed CI Job Log Tail
\`\`\`text
${log_tail}
\`\`\`
"
            fi

            issue_body="# CI Build Failure: ${run_title}

**Status:** Failed
**Run ID:** #${run_id:-unknown}
**Branch:** ${run_branch}
$([ -n "$run_commit" ] && echo "**Failing Commit:** ${run_commit}" || echo "")
$([ -n "$run_url" ] && echo "**URL:** ${run_url}" || echo "")
[fingerprint:${fp}]

### Incident Description
Gitea Actions continuous integration workflow failed during automated build or test gates.
${log_section}
### Payload Details
\`\`\`json
$(echo "$event_payload" | jq 'del(.log_tail)' 2>/dev/null || echo "$event_payload")
\`\`\`

### Architectural Mandate
Ensure fixes maintain 100% pure POSIX shell compatibility, run hermetic verification via \`bash scripts/ci/hermetic_test_runner.sh\`, and ensure all test suites pass without skipping assertions.
"
            ;;

        system.job_failure|system.cron_failure)
            # Producer contract (lib/sys/cron.sh, lib/ipc/fifo_ipc.sh): {job, exit_code, log, stderr_tail?, wall_s?}
            # Legacy keys job_id/label still accepted.
            local job_id exit_code label stderr_tail src
            job_id=$(echo "$event_payload" | jq -r '.job_id // .job // "unknown"' 2>/dev/null)
            [[ "$job_id" =~ ^[A-Za-z0-9_.-]{1,80}$ ]] || job_id="unknown"
            exit_code=$(echo "$event_payload" | jq -r '.exit_code // 1' 2>/dev/null)
            label=$(echo "$event_payload" | jq -r '.label // .job // .job_id // "unknown"' 2>/dev/null)
            stderr_tail=$(echo "$event_payload" | jq -r '.stderr_tail // empty' 2>/dev/null)
            src=$(echo "$event_payload" | jq -r '.source // empty' 2>/dev/null)

            if [ "$job_id" = "unknown" ]; then
                fp="job_fail_$(printf '%s' "${label:-${event_payload}}" | md5sum | cut -d' ' -f1 | head -c 12)"
            else
                fp="job_fail_${job_id}"
            fi
            priority="normal"

            if [ "$src" = "ipc_async" ] || [ "$src" = "ipc" ]; then
                local chan_id prom_id
                chan_id=$(echo "$event_payload" | jq -r '.channel // "ipc"' 2>/dev/null)
                prom_id=$(echo "$event_payload" | jq -r '.promise_id // empty' 2>/dev/null)
                title="Async Task Failure: ${label} (exit ${exit_code})"
                issue_body="# Async Task Failure: ${label}

**Status:** Failed (Exit code ${exit_code})
**Job ID:** ${job_id}
**Channel:** ${chan_id}
$([ -n "$prom_id" ] && echo "**Promise:** ${prom_id}" || echo "")
[fingerprint:${fp}]

### Incident Description
Asynchronous task \`${label}\` (job ID \`${job_id}\`) terminated with non-zero exit code ${exit_code}.
$([ -n "$stderr_tail" ] && printf '\n### Output tail\n```\n%s\n```\n' "$( [ "${#stderr_tail}" -gt 1500 ] && printf '%s' "${stderr_tail: -1500}" || printf '%s' "$stderr_tail")")

### Payload
\`\`\`json
$(echo "$event_payload" | jq . 2>/dev/null || echo "$event_payload")
\`\`\`
"
            else
                title="Scheduled Job Failure: ${label} (exit ${exit_code})"
                issue_body="# Scheduled Job Failure: ${label}

**Status:** Failed (Exit code ${exit_code})
**Job ID:** ${job_id}
[fingerprint:${fp}]

### Incident Description
Cron daemon executed scheduled job \`${job_id}\` (${label}) which terminated with non-zero exit code ${exit_code}.
$([ -n "$stderr_tail" ] && printf '\n### Output tail\n```\n%s\n```\n' "$( [ "${#stderr_tail}" -gt 1500 ] && printf '%s' "${stderr_tail: -1500}" || printf '%s' "$stderr_tail")")

### Payload
\`\`\`json
$(echo "$event_payload" | jq . 2>/dev/null || echo "$event_payload")
\`\`\`
"
            fi
            ;;

        system.sentinel_fault)
            title=$(echo "$event_payload" | jq -r '.title // empty' 2>/dev/null)
            fp=$(echo "$event_payload" | jq -r '.fingerprint // empty' 2>/dev/null)
            existing_issue_file=$(echo "$event_payload" | jq -r '.issue_file // empty' 2>/dev/null)
            [ -z "$title" ] && title="Sentinel Anomaly: ${fp:-unknown}"
            [ -z "$fp" ] && fp="sentinel_${now}"
            priority="high"
            if [ -n "$existing_issue_file" ] && [ -f "$existing_issue_file" ]; then
                issue_body=$(cat "$existing_issue_file" 2>/dev/null)
            else
                issue_body="# Sentinel Fault: ${title}

[fingerprint:${fp}]

### Incident Description
Autonomic Sentinel detected system anomaly requiring sovereign remediation.
"
            fi
            ;;

        *)
            title="System Fault: ${event_type}"
            fp="fault_$(echo -n "${event_type}_${event_payload}" | md5sum | cut -d' ' -f1 | head -c 12)"
            priority="normal"
            issue_body="# Fault: ${event_type}

[fingerprint:${fp}]

\`\`\`json
$(echo "$event_payload" | jq . 2>/dev/null || echo "$event_payload")
\`\`\`
"
            ;;
    esac

    # 1. Deduplication check against queue and in_progress
    local existing_task=""
    for qf in "$REMEDIATION_QUEUE_DIR"/*.json "$REMEDIATION_PROGRESS_DIR"/*.json; do
        [ ! -f "$qf" ] && continue
        local qfp
        qfp=$(jq -r '.fingerprint // empty' "$qf" 2>/dev/null)
        if [ -n "$fp" ] && [ "$qfp" = "$fp" ]; then
            existing_task=$(jq -r '.task_id' "$qf" 2>/dev/null)
            break
        fi
    done
    if [ -n "$existing_task" ]; then
        ui_info "Event ingress: Task already active/queued for fingerprint '$fp' ($existing_task). Skipping." >&2
        return 0
    fi

    # 2. Check 3-strike failure ceiling
    local attempt_file="$REMEDIATION_ATTEMPTS_DIR/${fp}.json"
    if [ -f "$attempt_file" ]; then
        local attempts
        attempts=$(jq -r '.attempts // 0' "$attempt_file" 2>/dev/null || echo 0)
        if [ "$attempts" -ge 3 ]; then
            ui_warn "Event ingress: Defect '$fp' reached 3-strike ceiling ($attempts/3). Operator review required." >&2
            return 0
        fi
    fi

    # 3. Resolve Multi-Repo Phytology Target & Create/Link Sovereign Gitea Issue
    local target_json target_gitea_user target_gitea_repo target_kind
    target_json=$(remediation_resolve_target "$title" "$issue_body" "$existing_issue_file" 2>/dev/null || echo '{}')
    target_kind=$(echo "$target_json" | jq -r '.target_kind // "heartwood"' 2>/dev/null)
    target_gitea_user=$(echo "$target_json" | jq -r '.gitea_user // "george"' 2>/dev/null)
    target_gitea_repo=$(echo "$target_json" | jq -r '.gitea_repo // "blue-lodge"' 2>/dev/null)

    if ! declare -f gitea_is_online &>/dev/null; then
        [ -f "${LODGE_DIR}/lib/tools/mcp_server_gitea.sh" ] && source "${LODGE_DIR}/lib/tools/mcp_server_gitea.sh" 2>/dev/null || true
    fi
    GITEA_USER_OVERRIDE="$target_gitea_user" GITEA_REPO_OVERRIDE="$target_gitea_repo" _gitea_load_conf 2>/dev/null || true
    if declare -f gitea_is_online &>/dev/null && gitea_is_online; then
        if [ "${_LODGE_TESTING:-0}" -ne 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ]; then
            # Check if an open Gitea issue already exists with this fingerprint in the TARGET repo
            local existing_issues
            existing_issues=$(curl -s "${GITEA_URL:-http://127.0.0.1:3088}/api/v1/repos/${target_gitea_user}/${target_gitea_repo}/issues?state=open" \
                -H "Authorization: token ${GITEA_TOKEN:-}" 2>/dev/null || echo "[]")
            if echo "$existing_issues" | jq -e 'type == "array"' &>/dev/null; then
                gitea_idx=$(echo "$existing_issues" | jq -r --arg fp "$fp" '.[] | select(.body | contains($fp)) | .number' 2>/dev/null | head -n 1)
            fi
        fi

        if [ -z "$gitea_idx" ]; then
            local gitea_res
            gitea_res=$(GITEA_USER_OVERRIDE="$target_gitea_user" GITEA_REPO_OVERRIDE="$target_gitea_repo" gitea_issue_create "$title" "$issue_body" "bug,needs-remediation,sovereign-remediation" 2>/dev/null || true)
            gitea_idx=$(echo "$gitea_res" | jq -r '.number // empty' 2>/dev/null || true)
            [ -n "$gitea_idx" ] && ui_ok "Created Sovereign Gitea Issue #${gitea_idx} on ${target_gitea_user}/${target_gitea_repo}: $title" >&2
        else
            ui_info "Found existing open Gitea Issue #${gitea_idx} on ${target_gitea_user}/${target_gitea_repo} for fingerprint '$fp'" >&2
            if [ "${_LODGE_TESTING:-0}" -ne 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ]; then
                local open_prs existing_pr
                open_prs=$(curl -s "${GITEA_URL:-http://127.0.0.1:3088}/api/v1/repos/${target_gitea_user}/${target_gitea_repo}/pulls?state=open" \
                    -H "Authorization: token ${GITEA_TOKEN:-}" 2>/dev/null || echo "[]")
                if echo "$open_prs" | jq -e 'type == "array"' &>/dev/null; then
                    existing_pr=$(echo "$open_prs" | jq -r --arg idx "#${gitea_idx}" --arg fp "$fp" '.[] | select((.body // "" | contains($idx)) or (.body // "" | contains($fp))) | .number' 2>/dev/null | head -n 1)
                    if [ -n "$existing_pr" ]; then
                        ui_info "Event ingress: Open PR #${existing_pr} already addresses Issue #${gitea_idx} ('$fp'). Deferring to pr_sweep." >&2
                        return 0
                    fi
                fi
            fi
        fi
    fi

    # 4. Create or update local issue file
    local issue_file="$existing_issue_file"
    if [ -z "$issue_file" ] || [ ! -f "$issue_file" ]; then
        local issue_dir="${GEORGE_DIR}/issues"
        mkdir -p "$issue_dir" 2>/dev/null || true
        issue_file="$issue_dir/issue_remediation_${now}_$(( RANDOM % 1000 )).md"
        cat <<EOF > "$issue_file"
${issue_body}

$([ -n "$gitea_idx" ] && echo "**Gitea Issue:** #${gitea_idx}" || echo "")
**Target Repository:** ${target_gitea_user}/${target_gitea_repo} (${target_kind})
EOF
    elif [ -n "$gitea_idx" ] && ! grep -q "Gitea Issue:" "$issue_file"; then
        echo -e "\n**Gitea Issue:** #${gitea_idx}" >> "$issue_file"
    fi

    # 5. Enqueue remediation task with resolved multi-repo target
    local queued_id
    queued_id=$(remediation_queue_add "$issue_file" "" "$priority" "$title" "$target_json")
    ui_ok "Remediation event ingress enqueued task: $queued_id" >&2

    # 6. Autonomously launch remediation execution loop in background if Slot 1 is idle
    if [ "${_LODGE_TESTING:-0}" -ne 1 ] && [ "${LODGE_TEST_MODE:-0}" -ne 1 ] && ! remediation_is_active; then
        ui_step "Triggering autonomous remediation worker on Slot 1..." >&2
        ( remediation_run ) >/dev/null 2>&1 &
        disown $! 2>/dev/null || true
    fi

    echo "$queued_id"
    return 0
}
