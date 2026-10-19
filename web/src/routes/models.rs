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
        let check_out = tokio::process::Command::new("docker")
            .args(["inspect", "-f", "{{.State.Status}}", "george-prism-server"])
            .output()
            .await;
        let is_running = match check_out {
            Ok(o) if o.status.success() => {
                String::from_utf8_lossy(&o.stdout).trim() == "running"
            }
            _ => false,
        };
        if is_running { "pause" } else { "resume" }
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

