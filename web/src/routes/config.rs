use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct TestConnPayload {
    pub url: Option<String>,
    pub jump_host: Option<String>,
}

#[derive(Deserialize)]
pub struct ConfigUpdate {
    pub limits_conf: Option<String>,
    pub endpoints_conf: Option<String>,
    pub keys_conf: Option<String>,
    pub lodge_conf: Option<String>,
    pub cron_conf: Option<String>,
}

#[derive(Deserialize)]
pub struct ConfigRestorePayload {
    pub limits_conf: Option<String>,
    pub endpoints_conf: Option<String>,
    pub keys_conf: Option<String>,
    pub lodge_conf: Option<String>,
    pub cron_conf: Option<String>,
}

#[derive(Deserialize)]
pub struct UpdateConfigKeyPayload {
    pub file: String,
    pub key: String,
    pub value: String,
}

pub async fn get_config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let endpoints_file = state.george_dir.join("endpoints.conf");
    let limits_file = state.george_dir.join("configs").join("limits.conf");

    let endpoints = fs::read_to_string(&endpoints_file)
        .await
        .unwrap_or_else(|_| "".into());
    let limits = fs::read_to_string(&limits_file)
        .await
        .unwrap_or_else(|_| "".into());

    Json(json!({
        "endpoints_conf": endpoints,
        "limits_conf": limits,
    }))
}

pub async fn get_config_all(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let keys_file = state.george_dir.join("keys.conf");
    let limits_file = state.george_dir.join("configs").join("limits.conf");
    let endpoints_file = state.george_dir.join("endpoints.conf");

    let keys = fs::read_to_string(&keys_file).await.unwrap_or_default();
    let limits = fs::read_to_string(&limits_file).await.unwrap_or_default();
    let endpoints = fs::read_to_string(&endpoints_file).await.unwrap_or_default();

    let mut masked_keys = Vec::new();
    for line in keys.lines() {
        if line.starts_with('#') || line.trim().is_empty() { continue; }
        if let Some((k, v)) = line.split_once('=') {
            let v_clean = v.trim().replace('"', "");
            let masked = if v_clean.len() > 6 {
                format!("{}••••••••", &v_clean[0..3])
            } else if !v_clean.is_empty() {
                "••••••••".into()
            } else {
                "".into()
            };
            masked_keys.push(json!({ "key": k.trim(), "value": masked }));
        }
    }

    Json(json!({
        "keys": masked_keys,
        "limits": limits,
        "endpoints": endpoints,
    }))
}

pub async fn test_connection(
    State(_state): State<Arc<AppState>>,
    Json(payload): Json<TestConnPayload>,
) -> impl IntoResponse {
    if let Some(target_url) = payload.url {
        let probe = format!("{}/v1/models", target_url.trim_end_matches('/'));
        let out = tokio::process::Command::new("curl")
            .args(["-sf", "--max-time", "3", &probe])
            .output()
            .await;
        match out {
            Ok(res) if res.status.success() => {
                return Json(json!({ "status": "ok", "message": "Handshake verified (HTTP 200)" }));
            }
            _ => {
                return Json(json!({ "status": "error", "message": "Connection unreachable or timed out" }));
            }
        }
    }

    if let Some(jump) = payload.jump_host {
        let out = tokio::process::Command::new("ssh")
            .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", &jump, "true"])
            .output()
            .await;
        match out {
            Ok(res) if res.status.success() => {
                return Json(json!({ "status": "ok", "message": "SSH Jump Box verified" }));
            }
            _ => {
                return Json(json!({ "status": "error", "message": "SSH Handshake failed" }));
            }
        }
    }

    Json(json!({ "status": "error", "message": "Missing test target" }))
}

pub async fn update_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ConfigUpdate>,
) -> impl IntoResponse {
    let _ = fs::create_dir_all(state.george_dir.join("configs")).await;
    if let Some(limits) = payload.limits_conf {
        let _ = fs::write(state.george_dir.join("configs").join("limits.conf"), limits).await;
    }
    if let Some(endpoints) = payload.endpoints_conf {
        let _ = fs::write(state.george_dir.join("endpoints.conf"), endpoints).await;
    }
    if let Some(keys) = payload.keys_conf {
        let p = state.george_dir.join("keys.conf");
        let _ = fs::write(&p, keys).await;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
        }
    }
    if let Some(lodge) = payload.lodge_conf {
        let _ = fs::write(state.george_dir.join("configs").join("lodge.conf"), lodge).await;
    }
    if let Some(cron) = payload.cron_conf {
        let _ = fs::write(state.george_dir.join("configs").join("cron.conf"), cron).await;
    }
    Json(json!({ "status": "saved" }))
}

pub async fn get_config_full(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let limits_content = fs::read_to_string(state.george_dir.join("configs").join("limits.conf")).await.unwrap_or_default();
    let endpoints_content = fs::read_to_string(state.george_dir.join("endpoints.conf")).await.unwrap_or_default();
    let keys_content = fs::read_to_string(state.george_dir.join("keys.conf")).await.unwrap_or_default();
    let lodge_content = fs::read_to_string(state.george_dir.join("configs").join("lodge.conf")).await.unwrap_or_default();
    let cron_content = fs::read_to_string(state.george_dir.join("configs").join("cron.conf")).await.unwrap_or_default();

    let mut map = std::collections::HashMap::new();
    for content in [&limits_content, &endpoints_content, &keys_content, &lodge_content, &cron_content] {
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('#') || trimmed.is_empty() { continue; }
            if let Some((k, v)) = trimmed.split_once('=') {
                let val_clean = v.trim().replace('"', "");
                map.insert(k.trim().to_string(), val_clean);
            }
        }
    }

    let gauge = json!({
        "max_research_turns": map.get("MAX_RESEARCH_TURNS").cloned().unwrap_or_else(|| "25".into()),
        "llm_temperature": map.get("LLM_TEMPERATURE").cloned().unwrap_or_else(|| "0.4".into()),
        "llm_timeout": map.get("LLM_TIMEOUT").cloned().unwrap_or_else(|| "180".into()),
        "tier1_max_tokens": map.get("TIER1_MAX_TOKENS").cloned().unwrap_or_else(|| "22528".into()),
        "stream_pacing": map.get("STREAM_PACING").cloned().unwrap_or_else(|| "30".into()),
    });

    let tray_sampling = json!({
        "LLM_TOP_P": map.get("LLM_TOP_P").cloned().unwrap_or_else(|| "0.95".into()),
        "LLM_TOP_K": map.get("LLM_TOP_K").cloned().unwrap_or_else(|| "20".into()),
        "LLM_MIN_P": map.get("LLM_MIN_P").cloned().unwrap_or_else(|| "0.05".into()),
        "LLM_REPEAT_PENALTY": map.get("LLM_REPEAT_PENALTY").cloned().unwrap_or_else(|| "1.0".into()),
        "LLM_PRESENCE_PENALTY": map.get("LLM_PRESENCE_PENALTY").cloned().unwrap_or_else(|| "0.0".into()),
    });

    let tray_autonomic = json!({
        "CRON_INTERVAL_POPUP": map.get("CRON_INTERVAL_POPUP").cloned().unwrap_or_else(|| "300".into()),
        "CRON_POPUP_TERMINAL": map.get("CRON_POPUP_TERMINAL").cloned().unwrap_or_else(|| "0".into()),
        "MAX_REMEDIATION_ATTEMPTS": map.get("MAX_REMEDIATION_ATTEMPTS").cloned().unwrap_or_else(|| "3".into()),
        "SENTINEL_AUTO_HEAL": map.get("SENTINEL_AUTO_HEAL").cloned().unwrap_or_else(|| "1".into()),
        "REMEDIATION_NOTIFY_ENABLED": map.get("REMEDIATION_NOTIFY_ENABLED").cloned().unwrap_or_else(|| "1".into()),
    });

    let tray_memory = json!({
        "RECALL_USER_PREF_MAX": map.get("RECALL_USER_PREF_MAX").cloned().unwrap_or_else(|| "10".into()),
        "DECAY_VIVID_DAYS": map.get("DECAY_VIVID_DAYS").cloned().unwrap_or_else(|| "7".into()),
        "DECAY_FADING_DAYS": map.get("DECAY_FADING_DAYS").cloned().unwrap_or_else(|| "30".into()),
        "CACHE_TTL": map.get("CACHE_TTL").cloned().unwrap_or_else(|| "3600".into()),
    });

    let tray_network = json!({
        "TIER1_URL": map.get("TIER1_URL").cloned().unwrap_or_else(|| "http://127.0.0.1:8080".into()),
        "TIER2_URL": map.get("TIER2_URL").cloned().unwrap_or_else(|| "http://127.0.0.1:18080".into()),
        "TIER3_URL": map.get("TIER3_URL").cloned().unwrap_or_else(|| "http://mac-m5.local:8080".into()),
        "REMOTE_JUMP_HOST": map.get("REMOTE_JUMP_HOST").cloned().unwrap_or_default(),
        "REMOTE_SSH_TARGET": map.get("REMOTE_SSH_TARGET").cloned().unwrap_or_default(),
    });

    let tray_socials = json!({
        "LODGE_NODE_NAME": map.get("LODGE_NODE_NAME").cloned().unwrap_or_else(|| "george".into()),
        "LODGE_NODE_CALLSIGN": map.get("LODGE_NODE_CALLSIGN").cloned().unwrap_or_else(|| "george".into()),
        "LODGE_NODE_MODE": map.get("LODGE_NODE_MODE").cloned().unwrap_or_else(|| "independent".into()),
        "DISCORD_SWARM_POSTURE": map.get("DISCORD_SWARM_POSTURE").cloned().unwrap_or_else(|| "direct-on-mention".into()),
        "DISCORD_MASTER_BOT_ID": map.get("DISCORD_MASTER_BOT_ID").cloned().unwrap_or_default(),
        "DISCORD_PEER_BOT_IDS": map.get("DISCORD_PEER_BOT_IDS").cloned().unwrap_or_default(),
        "DISCORD_BOT_TOKEN": map.get("DISCORD_BOT_TOKEN").cloned().unwrap_or_default(),
        "DISCORD_OWNER_IDS": map.get("DISCORD_OWNER_IDS").cloned().unwrap_or_default(),
        "DISCORD_OWNER_USERNAMES": map.get("DISCORD_OWNER_USERNAMES").cloned().unwrap_or_default(),
        "DISCORD_DEFAULT_CHANNEL_ID": map.get("DISCORD_DEFAULT_CHANNEL_ID").cloned().unwrap_or_default(),
        "MASTODON_INSTANCE": map.get("MASTODON_INSTANCE").cloned().unwrap_or_default(),
        "MASTODON_TOKEN": map.get("MASTODON_TOKEN").cloned().unwrap_or_default(),
        "BLUESKY_HANDLE": map.get("BLUESKY_HANDLE").cloned().unwrap_or_default(),
        "BLUESKY_APP_PASSWORD": map.get("BLUESKY_APP_PASSWORD").cloned().unwrap_or_default(),
        "TELEGRAM_BOT_TOKEN": map.get("TELEGRAM_BOT_TOKEN").cloned().unwrap_or_default(),
        "TELEGRAM_CHAT_ID": map.get("TELEGRAM_CHAT_ID").cloned().unwrap_or_default(),
    });

    Json(json!({
        "chamber1_gauge": gauge,
        "chamber2_trays": {
            "sampling": tray_sampling,
            "autonomic": tray_autonomic,
            "memory": tray_memory,
            "network": tray_network,
            "socials": tray_socials,
        },
        "chamber3_raw": {
            "limits": limits_content,
            "endpoints": endpoints_content,
            "keys": keys_content,
            "lodge": lodge_content,
            "cron": cron_content,
        }
    }))
}

pub async fn update_config_key(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UpdateConfigKeyPayload>,
) -> impl IntoResponse {
    let filename = match payload.file.as_str() {
        "endpoints" => "endpoints.conf",
        "keys" => "keys.conf",
        "lodge" => "configs/lodge.conf",
        "cron" => "configs/cron.conf",
        _ => "configs/limits.conf",
    };
    let conf_path = state.george_dir.join(filename);
    if let Some(parent) = conf_path.parent() {
        let _ = fs::create_dir_all(parent).await;
    }
    let content = fs::read_to_string(&conf_path).await.unwrap_or_default();

    let key_prefix = format!("{}=", payload.key);
    let mut replaced = false;
    let mut new_lines = Vec::new();
    let clean_val = payload.value.trim().trim_matches('"').trim_matches('\'');
    let quote_val = filename != "configs/lodge.conf" && filename != "keys.conf";
    let formatted_line = if quote_val {
        format!("{}=\"{}\"", payload.key, clean_val)
    } else {
        format!("{}={}", payload.key, clean_val)
    };

    for line in content.lines() {
        if line.trim_start().starts_with(&key_prefix) {
            new_lines.push(formatted_line.clone());
            replaced = true;
        } else {
            new_lines.push(line.to_string());
        }
    }

    if !replaced {
        new_lines.push(formatted_line);
    }

    let updated_text = new_lines.join("\n") + "\n";
    let _ = fs::write(&conf_path, updated_text).await;
    #[cfg(unix)]
    if filename == "keys.conf" {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&conf_path, std::fs::Permissions::from_mode(0o600));
    }
    Json(json!({ "status": "updated", "file": filename, "key": payload.key, "value": payload.value }))
}

pub async fn backup_config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let limits_conf = fs::read_to_string(state.george_dir.join("configs").join("limits.conf")).await.unwrap_or_default();
    let endpoints_conf = fs::read_to_string(state.george_dir.join("endpoints.conf")).await.unwrap_or_default();
    let keys_conf = fs::read_to_string(state.george_dir.join("keys.conf")).await.unwrap_or_default();
    let lodge_conf = fs::read_to_string(state.george_dir.join("configs").join("lodge.conf")).await.unwrap_or_default();
    let cron_conf = fs::read_to_string(state.george_dir.join("configs").join("cron.conf")).await.unwrap_or_default();

    let backup_dir = state.george_dir.join("backups");
    let _ = fs::create_dir_all(&backup_dir).await;
    let ts = crate::helpers::chrono_utc_now();
    let bundle = json!({
        "version": 1,
        "timestamp": ts,
        "limits_conf": limits_conf,
        "endpoints_conf": endpoints_conf,
        "keys_conf": keys_conf,
        "lodge_conf": lodge_conf,
        "cron_conf": cron_conf,
    });
    let snap_path = backup_dir.join(format!("config-backup-{}.json", ts));
    if let Ok(serialized) = serde_json::to_string_pretty(&bundle) {
        let _ = fs::write(&snap_path, &serialized).await;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&snap_path, std::fs::Permissions::from_mode(0o600));
        }
    }
    Json(bundle)
}

pub async fn restore_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ConfigRestorePayload>,
) -> impl IntoResponse {
    // Save a pre-restore snapshot first
    let _ = backup_config(State(state.clone())).await;
    update_config(
        State(state),
        Json(ConfigUpdate {
            limits_conf: payload.limits_conf,
            endpoints_conf: payload.endpoints_conf,
            keys_conf: payload.keys_conf,
            lodge_conf: payload.lodge_conf,
            cron_conf: payload.cron_conf,
        }),
    )
    .await
}

pub async fn validate_socials(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("commands/social.sh");
    let out = tokio::process::Command::new("bash")
        .arg(&script)
        .arg("validate")
        .env("LODGE_DIR", &state.lodge_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;
    match out {
        Ok(res) => {
            let stdout = crate::helpers::strip_ansi(&String::from_utf8_lossy(&res.stdout));
            let stderr = crate::helpers::strip_ansi(&String::from_utf8_lossy(&res.stderr));
            Json(json!({
                "status": if res.status.success() { "ok" } else { "warn" },
                "output": format!("{}{}", stdout, stderr).trim(),
            }))
        }
        Err(e) => Json(json!({ "status": "error", "output": format!("Validation error: {}", e) })),
    }
}

pub async fn sync_discord(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg("source lib/comms/social.sh && discord_validate && discord_channel_list && discord_user_list")
        .env("LODGE_DIR", &state.lodge_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;
    match out {
        Ok(res) => {
            let stdout = crate::helpers::strip_ansi(&String::from_utf8_lossy(&res.stdout));
            let stderr = crate::helpers::strip_ansi(&String::from_utf8_lossy(&res.stderr));
            Json(json!({
                "status": if res.status.success() { "ok" } else { "warn" },
                "output": format!("{}{}", stdout, stderr).trim(),
            }))
        }
        Err(e) => Json(json!({ "status": "error", "output": format!("Discord sync error: {}", e) })),
    }
}

#[derive(Deserialize)]
pub struct EcotypeActionPayload {
    pub action: String, // "init" | "sync" | "backup" | "backup-cloud" | "promote"
    pub node_name: Option<String>,
    pub title: Option<String>,
    pub paths: Option<Vec<String>>,
    pub push_origin: Option<bool>,
}

#[derive(Deserialize)]
pub struct InstallReactorTemplatePayload {
    pub id: String,
}

pub async fn get_ecotype_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("commands/ecotype.sh");
    let out = tokio::process::Command::new("bash")
        .arg(&script)
        .arg("status --json")
        .env("LODGE_DIR", &state.lodge_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;
    match out {
        Ok(res) if res.status.success() => {
            if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&res.stdout) {
                return Json(val);
            }
        }
        _ => {}
    }
    Json(json!({ "status": "error", "message": "Failed to read ecotype status" }))
}

pub async fn post_ecotype_action(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<EcotypeActionPayload>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("commands/ecotype.sh");
    let cmd_str = match payload.action.as_str() {
        "init" => {
            let n = payload.node_name.unwrap_or_default();
            let clean: String = n.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
            if clean.is_empty() { "init".to_string() } else { format!("init {}", clean) }
        }
        "sync" => "sync".to_string(),
        "backup" => "backup".to_string(),
        "backup-cloud" => "backup --cloud".to_string(),
        "promote" => {
            let title = payload.title.unwrap_or_else(|| "Promote heartwood update".into())
                .replace('"', "")
                .replace('`', "")
                .replace('$', "");
            let paths: Vec<String> = payload.paths.unwrap_or_default()
                .into_iter()
                .filter(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_alphanumeric() || "/._-".contains(c)))
                .collect();
            if paths.is_empty() {
                return Json(json!({ "status": "error", "output": "Select at least one Heartwood file path to promote." }));
            }
            let origin_flag = if payload.push_origin.unwrap_or(false) { "--push-origin " } else { "" };
            format!("promote --title \"{}\" {}-- {}", title, origin_flag, paths.join(" "))
        }
        _ => return Json(json!({ "status": "error", "output": "Unknown ecotype action" })),
    };

    let out = tokio::process::Command::new("bash")
        .arg(&script)
        .arg(&cmd_str)
        .env("LODGE_DIR", &state.lodge_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(res) => {
            let stdout = crate::helpers::strip_ansi(&String::from_utf8_lossy(&res.stdout));
            let stderr = crate::helpers::strip_ansi(&String::from_utf8_lossy(&res.stderr));
            Json(json!({
                "status": if res.status.success() { "ok" } else { "error" },
                "output": format!("{}{}", stdout, stderr).trim(),
            }))
        }
        Err(e) => Json(json!({ "status": "error", "output": format!("Execution failed: {}", e) })),
    }
}

pub async fn get_reactor_templates(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let tpl_path = state.lodge_dir.join("configs/reactor_templates.json");
    if let Ok(content) = fs::read_to_string(&tpl_path).await {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
            return Json(val);
        }
    }
    Json(json!({ "templates": [] }))
}

pub async fn install_reactor_template(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<InstallReactorTemplatePayload>,
) -> impl IntoResponse {
    let tpl_path = state.lodge_dir.join("configs/reactor_templates.json");
    let Ok(content) = fs::read_to_string(&tpl_path).await else {
        return Json(json!({ "status": "error", "message": "reactor_templates.json not found" }));
    };
    let Ok(doc) = serde_json::from_str::<serde_json::Value>(&content) else {
        return Json(json!({ "status": "error", "message": "Invalid reactor_templates.json" }));
    };
    let Some(tpl) = doc.get("templates")
        .and_then(|t| t.as_array())
        .and_then(|arr| arr.iter().find(|item| item.get("id").and_then(|v| v.as_str()) == Some(payload.id.as_str())))
    else {
        return Json(json!({ "status": "error", "message": "Template ID not found" }));
    };

    let rid = tpl.get("id").and_then(|v| v.as_str()).unwrap_or("");
    let rtype = tpl.get("event_type").and_then(|v| v.as_str()).unwrap_or("");
    let rpat = tpl.get("pattern").and_then(|v| v.as_str()).unwrap_or(".*");
    let ract = tpl.get("action").and_then(|v| v.as_str()).unwrap_or("");
    let rdeb = tpl.get("debounce").and_then(|v| v.as_u64()).unwrap_or(5);

    let script = state.lodge_dir.join("commands/react.sh");
    let cmd_arg = format!("add {} {} {} {} --debounce {}", rid, rtype, rpat, ract, rdeb);
    let out = tokio::process::Command::new("bash")
        .arg(&script)
        .arg(&cmd_arg)
        .env("LODGE_DIR", &state.lodge_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(res) if res.status.success() => Json(json!({ "status": "ok", "message": format!("Installed reactor template '{}'", rid) })),
        Ok(res) => Json(json!({ "status": "error", "message": String::from_utf8_lossy(&res.stderr).trim().to_string() })),
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}
