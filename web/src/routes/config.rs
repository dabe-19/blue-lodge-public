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
}

#[derive(Deserialize)]
pub struct UpdateConfigKeyPayload {
    pub file: String,
    pub key: String,
    pub value: String,
}

pub async fn get_config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let endpoints_file = state.george_dir.join("endpoints.conf");
    let limits_file = state.george_dir.join("limits.conf");

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
    let limits_file = state.george_dir.join("limits.conf");
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
    if let Some(limits) = payload.limits_conf {
        let _ = fs::write(state.george_dir.join("limits.conf"), limits).await;
    }
    if let Some(endpoints) = payload.endpoints_conf {
        let _ = fs::write(state.george_dir.join("endpoints.conf"), endpoints).await;
    }
    if let Some(keys) = payload.keys_conf {
        let _ = fs::write(state.george_dir.join("keys.conf"), keys).await;
    }
    Json(json!({ "status": "saved" }))
}

pub async fn get_config_full(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let limits_content = fs::read_to_string(state.george_dir.join("limits.conf")).await.unwrap_or_default();
    let endpoints_content = fs::read_to_string(state.george_dir.join("endpoints.conf")).await.unwrap_or_default();
    let keys_content = fs::read_to_string(state.george_dir.join("keys.conf")).await.unwrap_or_default();

    let mut map = std::collections::HashMap::new();
    for content in [&limits_content, &endpoints_content, &keys_content] {
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

    Json(json!({
        "chamber1_gauge": gauge,
        "chamber2_trays": {
            "sampling": tray_sampling,
            "autonomic": tray_autonomic,
            "memory": tray_memory,
            "network": tray_network,
        },
        "chamber3_raw": {
            "limits": limits_content,
            "endpoints": endpoints_content,
            "keys": keys_content,
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
        _ => "limits.conf",
    };
    let conf_path = state.george_dir.join(filename);
    let content = fs::read_to_string(&conf_path).await.unwrap_or_default();

    let key_prefix = format!("{}=", payload.key);
    let mut replaced = false;
    let mut new_lines = Vec::new();

    for line in content.lines() {
        if line.trim_start().starts_with(&key_prefix) {
            new_lines.push(format!("{}=\"{}\"", payload.key, payload.value));
            replaced = true;
        } else {
            new_lines.push(line.to_string());
        }
    }

    if !replaced {
        new_lines.push(format!("{}=\"{}\"", payload.key, payload.value));
    }

    let updated_text = new_lines.join("\n") + "\n";
    let _ = fs::write(&conf_path, updated_text).await;
    Json(json!({ "status": "updated", "file": filename, "key": payload.key, "value": payload.value }))
}
