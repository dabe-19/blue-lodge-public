use axum::{
    extract::{Query, State},
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use tokio::fs;

use crate::state::AppState;

fn valid_user_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "_.:@-".contains(c))
}

fn valid_tier_id(s: &str) -> bool {
    matches!(s, "tier_0" | "tier_1" | "tier_2" | "tier_3")
}

fn valid_preset(s: &str) -> bool {
    matches!(s, "masonic" | "standard" | "guild" | "cyber")
}

async fn run_rep_bash(lodge_dir: &Path, script: &str, envs: &[(&str, &str)]) -> Result<String, String> {
    let mut cmd = tokio::process::Command::new("bash");
    cmd.arg("-c")
        .arg(script)
        .env("LODGE_DIR", lodge_dir)
        .env("GEORGE_DIR", lodge_dir.join(".george"))
        .env("GEORGE_CONFIG_DIR", lodge_dir.join(".george"))
        .current_dir(lodge_dir);
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let out = cmd
        .output()
        .await
        .map_err(|e| format!("Failed to spawn bash: {}", e))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if out.status.success() {
        Ok(stdout)
    } else {
        Err(if !stderr.is_empty() { stderr } else { stdout })
    }
}

async fn read_policy_json(lodge_dir: &Path) -> Value {
    let active = lodge_dir.join(".george/configs/reputation_policy.json");
    let example = lodge_dir.join("configs/reputation_policy.example.json");
    let raw = if let Ok(s) = fs::read_to_string(&active).await {
        s
    } else if let Ok(s) = fs::read_to_string(&example).await {
        s
    } else {
        return json!({});
    };
    serde_json::from_str(&raw).unwrap_or_else(|_| json!({}))
}

#[derive(Deserialize)]
pub struct ReputationQuery {
    pub user_id: Option<String>,
    pub limit: Option<u32>,
}

/// GET /api/reputation — Returns active policy, user ledger, and recent audit events
pub async fn get_reputation(
    State(state): State<Arc<AppState>>,
    Query(q): Query<ReputationQuery>,
) -> impl IntoResponse {
    let limit = q.limit.unwrap_or(60).clamp(1, 200);
    let filter_uid = q.user_id.filter(|u| valid_user_id(u)).unwrap_or_default();

    // Ensure DB & policy are initialized via reputation.sh, then dump JSON via sqlite3/python3
    let py_script = r#"
source "$LODGE_DIR/lib/agents/reputation.sh"
reputation_init >/dev/null 2>&1 || true
python3 - "$REPUTATION_DB" "$REP_FILTER_UID" "$REP_LIMIT" <<'PY'
import json, os, sqlite3, sys
db_path, fuid, lim = sys.argv[1], sys.argv[2], int(sys.argv[3])
users, events = [], []
if os.path.isfile(db_path):
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    cur = con.cursor()
    try:
        for row in cur.execute("SELECT user_id, COALESCE(username,'') AS username, COALESCE(platform,'discord') AS platform, score, COALESCE(tier_id,'tier_1') AS tier_id, tier, COALESCE(last_seen,0) AS last_seen FROM reputation ORDER BY score DESC, last_seen DESC LIMIT 200"):
            users.append(dict(row))
    except Exception:
        pass
    try:
        if fuid:
            rows = cur.execute("SELECT id, created_at AS ts, user_id, delta, old_score AS score_before, new_score AS score_after, old_tier AS tier_before, new_tier AS tier_after, reason, actor FROM reputation_events WHERE user_id = ? ORDER BY id DESC LIMIT ?", (fuid, lim))
        else:
            rows = cur.execute("SELECT id, created_at AS ts, user_id, delta, old_score AS score_before, new_score AS score_after, old_tier AS tier_before, new_tier AS tier_after, reason, actor FROM reputation_events ORDER BY id DESC LIMIT ?", (lim,))
        for row in rows:
            events.append(dict(row))
    except Exception:
        pass
    con.close()
print(json.dumps({"users": users, "events": events}))
PY
"#;

    let lim_s = limit.to_string();
    let db_data = match run_rep_bash(
        &state.lodge_dir,
        py_script,
        &[("REP_FILTER_UID", &filter_uid), ("REP_LIMIT", &lim_s)],
    )
    .await
    {
        Ok(out) => serde_json::from_str::<Value>(&out).unwrap_or_else(|_| json!({"users": [], "events": []})),
        Err(e) => {
            return Json(json!({
                "status": "error",
                "message": e,
            }));
        }
    };

    let policy = read_policy_json(&state.lodge_dir).await;
    Json(json!({
        "status": "ok",
        "policy": policy,
        "users": db_data.get("users").cloned().unwrap_or_else(|| json!([])),
        "events": db_data.get("events").cloned().unwrap_or_else(|| json!([])),
        "filter_user_id": filter_uid,
    }))
}

#[derive(Deserialize)]
pub struct ReputationAdjustPayload {
    pub action: String, // "grant" | "penalize" | "quarantine" | "reset"
    pub user_id: String,
    pub username: Option<String>,
    pub delta: Option<i64>,
    pub reason: Option<String>,
}

/// POST /api/reputation/adjust — Operator adjustment (grant, penalize, quarantine, reset)
pub async fn post_reputation_adjust(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ReputationAdjustPayload>,
) -> impl IntoResponse {
    if !valid_user_id(&payload.user_id) {
        return Json(json!({ "status": "error", "message": "Invalid user_id" }));
    }
    let action = payload.action.trim().to_ascii_lowercase();
    if !matches!(action.as_str(), "grant" | "penalize" | "quarantine" | "reset") {
        return Json(json!({ "status": "error", "message": "Invalid action (use grant, penalize, quarantine, reset)" }));
    }

    let delta = payload.delta.unwrap_or(5).abs().clamp(1, 500);
    let reason = payload
        .reason
        .unwrap_or_else(|| format!("web_ui_{}", action))
        .chars()
        .filter(|c| !c.is_control())
        .take(160)
        .collect::<String>();
    let uname = payload
        .username
        .unwrap_or_default()
        .chars()
        .filter(|c| !c.is_control())
        .take(64)
        .collect::<String>();

    let script = r#"
source "$LODGE_DIR/lib/agents/reputation.sh"
reputation_init >/dev/null 2>&1 || true
if [ -n "$REP_UNAME" ]; then
    reputation_get "$REP_UID" "$REP_UNAME" >/dev/null 2>&1 || true
fi
case "$REP_ACT" in
    grant)
        reputation_add "$REP_UID" "$REP_DELTA" "$REP_REASON" "$REP_UNAME" "web_ui"
        ;;
    penalize)
        reputation_add "$REP_UID" "-$REP_DELTA" "$REP_REASON" "$REP_UNAME" "web_ui"
        ;;
    quarantine)
        reputation_quarantine "$REP_UID" "${REP_UNAME:-unknown}" "$REP_REASON" "web_ui"
        ;;
    reset)
        reputation_reset "$REP_UID" "${REP_UNAME:-unknown}" "web_ui"
        ;;
esac
"#;

    let delta_s = delta.to_string();
    match run_rep_bash(
        &state.lodge_dir,
        script,
        &[
            ("REP_ACT", &action),
            ("REP_UID", &payload.user_id),
            ("REP_UNAME", &uname),
            ("REP_DELTA", &delta_s),
            ("REP_REASON", &reason),
        ],
    )
    .await
    {
        Ok(out) => Json(json!({
            "status": "ok",
            "action": action,
            "user_id": payload.user_id,
            "result": out,
        })),
        Err(e) => Json(json!({ "status": "error", "message": e })),
    }
}

#[derive(Deserialize)]
pub struct ReputationPolicyPayload {
    pub preset: Option<String>,
    pub ledger_title: Option<String>,
    pub starting_score: Option<i64>,
    pub default_moderator_floor: Option<String>,
    pub passive_daily_cap: Option<u32>,
    pub passive_cooldown_secs: Option<u32>,
    pub passive_enabled: Option<bool>,
    pub quarantine_reply: Option<String>,
    pub discord_role_floors: Option<Value>,
    pub tiers: Option<Value>,
}

/// POST /api/reputation/policy — Switch theme preset or update custom role names, thresholds, caps & moderator floor
pub async fn post_reputation_policy(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ReputationPolicyPayload>,
) -> impl IntoResponse {
    // Ensure policy file exists
    let _ = run_rep_bash(
        &state.lodge_dir,
        r#"source "$LODGE_DIR/lib/agents/reputation.sh"; reputation_init >/dev/null 2>&1 || true"#,
        &[],
    )
    .await;

    let mut policy = read_policy_json(&state.lodge_dir).await;
    if !policy.is_object() {
        return Json(json!({ "status": "error", "message": "Unable to load base reputation policy" }));
    }

    // 1. Optional preset switch first
    if let Some(ref preset) = payload.preset {
        let p = preset.trim().to_ascii_lowercase();
        if !valid_preset(&p) {
            return Json(json!({ "status": "error", "message": "Unknown preset (use masonic, standard, guild, cyber)" }));
        }
        let names = policy
            .get("presets")
            .and_then(|pr| pr.get(&p))
            .and_then(|po| po.get("names"))
            .and_then(|n| n.as_array())
            .cloned();
        let title = policy
            .get("presets")
            .and_then(|pr| pr.get(&p))
            .and_then(|po| po.get("ledger_title"))
            .and_then(|t| t.as_str())
            .map(|s| s.to_string());

        if let Some(obj) = policy.as_object_mut() {
            obj.insert("theme".to_string(), json!(p));
            if let Some(t) = title {
                obj.insert("ledger_title".to_string(), json!(t));
            }
            if let (Some(n_arr), Some(tiers_obj)) = (names, obj.get_mut("tiers").and_then(|v| v.as_object_mut())) {
                let ids = ["tier_0", "tier_1", "tier_2", "tier_3"];
                for (i, tid) in ids.iter().enumerate() {
                    if let (Some(nm), Some(tobj)) = (
                        n_arr.get(i).and_then(|v| v.as_str()),
                        tiers_obj.get_mut(*tid).and_then(|v| v.as_object_mut()),
                    ) {
                        tobj.insert("name".to_string(), json!(nm));
                    }
                }
            }
        }
    }

    // 2. Custom field overrides
    if let Some(ref title) = payload.ledger_title {
        let clean: String = title.chars().filter(|c| !c.is_control()).take(96).collect();
        if !clean.trim().is_empty() {
            policy["ledger_title"] = json!(clean.trim());
        }
    }
    if let Some(sc) = payload.starting_score {
        policy["starting_score"] = json!(sc.clamp(0, 100));
    }
    if let Some(ref floor) = payload.default_moderator_floor {
        let f = floor.trim().to_ascii_lowercase();
        if !matches!(f.as_str(), "tier_1" | "tier_2" | "tier_3") {
            return Json(json!({ "status": "error", "message": "default_moderator_floor must be tier_1, tier_2, or tier_3" }));
        }
        policy["default_moderator_floor"] = json!(f);
    }
    if let Some(cap) = payload.passive_daily_cap {
        policy["passive_reward"]["daily_cap"] = json!(cap.clamp(0, 100));
    }
    if let Some(cd) = payload.passive_cooldown_secs {
        policy["passive_reward"]["cooldown_secs"] = json!(cd.clamp(0, 86400));
    }
    if let Some(en) = payload.passive_enabled {
        policy["passive_reward"]["enabled"] = json!(en);
    }
    if let Some(ref qr) = payload.quarantine_reply {
        let clean: String = qr.chars().filter(|c| !c.is_control()).take(320).collect();
        if !clean.trim().is_empty() {
            policy["quarantine_reply"] = json!(clean.trim());
        }
    }
    if let Some(Value::Object(map)) = payload.discord_role_floors {
        let mut clean_map = serde_json::Map::new();
        for (k, v) in map {
            let ks = k.trim().to_string();
            let vs = v.as_str().unwrap_or("").trim().to_ascii_lowercase();
            if !ks.is_empty()
                && ks.len() <= 32
                && ks.chars().all(|c| c.is_ascii_alphanumeric() || "_-".contains(c))
                && matches!(vs.as_str(), "tier_1" | "tier_2" | "tier_3")
            {
                clean_map.insert(ks, json!(vs));
            }
        }
        policy["discord_role_floors"] = Value::Object(clean_map);
    }
    if let Some(Value::Object(tmap)) = payload.tiers {
        let mut custom_changed = false;
        for (tid, tval) in tmap {
            if !valid_tier_id(&tid) {
                continue;
            }
            if let Some(src) = tval.as_object() {
                if let Some(name_v) = src.get("name").and_then(|v| v.as_str()) {
                    let clean: String = name_v.chars().filter(|c| !c.is_control()).take(48).collect();
                    if !clean.trim().is_empty() {
                        policy["tiers"][&tid]["name"] = json!(clean.trim());
                        custom_changed = true;
                    }
                }
                if tid != "tier_0" {
                    if let Some(ms) = src.get("min_score").and_then(|v| v.as_i64()) {
                        policy["tiers"][&tid]["min_score"] = json!(ms.clamp(0, 10000));
                    }
                }
                if let Some(desc_v) = src.get("description").and_then(|v| v.as_str()) {
                    let clean: String = desc_v.chars().filter(|c| !c.is_control()).take(220).collect();
                    if !clean.trim().is_empty() {
                        policy["tiers"][&tid]["description"] = json!(clean.trim());
                    }
                }
            }
        }
        if custom_changed && payload.preset.is_none() {
            policy["theme"] = json!("custom");
        }
    }

    // Write policy atomically to .george/configs/reputation_policy.json
    let cfg_dir = state.lodge_dir.join(".george/configs");
    let _ = fs::create_dir_all(&cfg_dir).await;
    let target = cfg_dir.join("reputation_policy.json");
    let tmp = cfg_dir.join("reputation_policy.json.tmp");
    let serialized = match serde_json::to_string_pretty(&policy) {
        Ok(s) => s + "\n",
        Err(e) => return Json(json!({ "status": "error", "message": format!("Serialize failed: {}", e) })),
    };
    if let Err(e) = fs::write(&tmp, serialized.as_bytes()).await {
        return Json(json!({ "status": "error", "message": format!("Write failed: {}", e) }));
    }
    if let Err(e) = fs::rename(&tmp, &target).await {
        return Json(json!({ "status": "error", "message": format!("Rename failed: {}", e) }));
    }

    // Re-sync existing DB tier labels to match updated policy
    let _ = run_rep_bash(
        &state.lodge_dir,
        r#"source "$LODGE_DIR/lib/agents/reputation.sh"; reputation_sync_tier_labels >/dev/null 2>&1 || true"#,
        &[],
    )
    .await;

    Json(json!({
        "status": "ok",
        "policy": policy,
    }))
}
