//! Operator utilities that predate the Model Hub: game mode (pause inference to free the GPUs)
//! and remote model-pull staging. All model discovery, download, serving and switching lives in
//! `hub.rs` (/api/hub/*) and is driven by the operator's own library; nothing here is curated.
use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct StagePullPayload {
    pub provider: String,
    pub model_name: String,
    pub destination_dir: Option<String>,
    pub ssh_host: Option<String>,
}

pub async fn stage_model_pull(
    Json(payload): Json<StagePullPayload>,
) -> impl IntoResponse {
    let dest = payload.destination_dir.unwrap_or_else(|| "/models".into());
    let provider = payload.provider.to_lowercase();
    let model = payload.model_name.trim();

    let cmd = if provider.contains("ollama") {
        format!("ollama pull {}", model)
    } else if provider.contains("vllm") {
        format!("python3 -m vllm.entrypoints.openai.api_server --model {}", model)
    } else if provider.contains("lmstudio") {
        format!("lms load {}", model)
    } else {
        if model.contains('/') && !model.ends_with(".gguf") {
            format!("huggingface-cli download {} --local-dir {}", model, dest)
        } else if model.contains('/') && model.ends_with(".gguf") {
            let parts: Vec<&str> = model.split('/').collect();
            let repo = parts[..parts.len()-1].join("/");
            let file = parts.last().unwrap_or(&"");
            format!("huggingface-cli download {} {} --local-dir {}", repo, file, dest)
        } else {
            format!("huggingface-cli download {} --local-dir {}", model, dest)
        }
    };

    Json(json!({
        "status": "staged",
        "provider": provider,
        "command": cmd,
        "ssh_dispatch_available": payload.ssh_host.as_ref().map_or(false, |h| !h.is_empty())
    }))
}

#[derive(Deserialize)]
pub struct GameModeTogglePayload {
    pub action: Option<String>,
}

pub async fn get_gamemode(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("scripts/infra/game_mode.sh");
    let out = tokio::process::Command::new("bash")
        .arg(&script).arg("json")
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

    Json(json!({
        "status": "error",
        "game_mode": false,
        "inference_status": "unknown",
        "port_8080": "unknown",
        "autonomic_daemon": false
    }))
}

pub async fn toggle_gamemode(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<GameModeTogglePayload>,
) -> impl IntoResponse {
    let requested_action = payload.action.unwrap_or_else(|| "toggle".into()).to_lowercase();

    let target_action = if requested_action == "toggle" {
        let mut is_running = false;
        if std::env::var_os("KUBERNETES_SERVICE_HOST").is_some() {
            let ns = std::env::var("K8S_NAMESPACE").unwrap_or_else(|_| "blue-lodge".into());
            let k8s_out = tokio::process::Command::new("kubectl")
                .args(["-n", &ns, "get", "deploy", "george-inference", "-o", "jsonpath={.spec.replicas}"])
                .output()
                .await;
            if let Ok(o) = k8s_out {
                let rep = String::from_utf8_lossy(&o.stdout).trim().parse::<u32>().unwrap_or(0);
                if rep > 0 {
                    is_running = true;
                }
            }
            if !is_running && crate::helpers::reqwest_lite_get("http://george-inference:8080/health").await.is_ok() {
                is_running = true;
            }
        } else {
            let check_out = tokio::process::Command::new("docker")
                .args(["inspect", "-f", "{{.State.Status}}", "george-prism-server"])
                .output()
                .await;
            if let Ok(o) = check_out {
                if o.status.success() && String::from_utf8_lossy(&o.stdout).trim() == "running" {
                    is_running = true;
                }
            }
        }
        if is_running && !state.george_dir.join(".game_mode").exists() { "pause" } else { "resume" }
    } else if requested_action == "pause" || requested_action == "game" || requested_action == "stop" {
        "pause"
    } else {
        "resume"
    };

    let script = state.lodge_dir.join("scripts/infra/game_mode.sh");
    let lodge = state.lodge_dir.clone();

    tokio::spawn(async move {
        let _ = tokio::process::Command::new("bash")
            .arg(&script).arg(target_action)
            .current_dir(&lodge)
            .output()
            .await;
    });

    let game_mode_active = target_action == "pause";
    let message = if game_mode_active {
        "Entering Game Mode: Releasing GPU VRAM for gaming..."
    } else {
        "Resuming George: Re-engaging inference server and autonomic sweeps..."
    };

    Json(json!({
        "status": "ok",
        "action": target_action,
        "game_mode": game_mode_active,
        "message": message
    }))
}

#[derive(Deserialize)]
pub struct RemediationModePayload {
    pub mode: Option<String>,
}

fn read_remediation_mode_str(george_dir: &std::path::Path) -> String {
    let path = george_dir.join("remediation").join("mode");
    if let Ok(raw) = std::fs::read_to_string(&path) {
        let m = raw.trim().to_ascii_lowercase();
        if m == "propose" {
            return "propose".to_string();
        }
    }
    "auto".to_string()
}

pub async fn get_remediation_mode(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mode = read_remediation_mode_str(&state.george_dir);
    Json(json!({
        "status": "ok",
        "mode": mode,
        "auto_merge": mode == "auto",
    }))
}

pub async fn set_remediation_mode(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<RemediationModePayload>,
) -> impl IntoResponse {
    let cur = read_remediation_mode_str(&state.george_dir);
    let req = payload
        .mode
        .unwrap_or_else(|| "toggle".to_string())
        .trim()
        .to_ascii_lowercase();
    let next_mode = match req.as_str() {
        "auto" => "auto",
        "propose" => "propose",
        "toggle" => {
            if cur == "auto" {
                "propose"
            } else {
                "auto"
            }
        }
        _ => {
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(json!({
                    "status": "error",
                    "message": "mode must be 'auto', 'propose', or 'toggle'",
                })),
            )
                .into_response();
        }
    };

    let dir = state.george_dir.join("remediation");
    if let Err(e) = std::fs::create_dir_all(&dir) {
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({
                "status": "error",
                "message": format!("failed to create remediation directory: {}", e),
            })),
        )
            .into_response();
    }
    let path = dir.join("mode");
    if let Err(e) = std::fs::write(&path, format!("{}\n", next_mode)) {
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({
                "status": "error",
                "message": format!("failed to persist remediation mode: {}", e),
            })),
        )
            .into_response();
    }

    Json(json!({
        "status": "ok",
        "mode": next_mode,
        "auto_merge": next_mode == "auto",
    }))
    .into_response()
}

