use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::reqwest_lite_get;
use crate::state::AppState;

pub async fn get_tunnel_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let remote_conf = state.george_dir.join("remote.conf");
    let content = fs::read_to_string(&remote_conf).await.unwrap_or_default();
    let mut map = std::collections::HashMap::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') || trimmed.is_empty() { continue; }
        if let Some((k, v)) = trimmed.split_once('=') {
            map.insert(k.trim().to_string(), v.trim().to_string());
        }
    }

    let target = map.get("REMOTE_SSH_TARGET").cloned().unwrap_or_default();
    let jump_host = map.get("REMOTE_JUMP_HOST").cloned().unwrap_or_default();
    let forward_host = map.get("REMOTE_FORWARD_HOST").cloned().unwrap_or_else(|| "127.0.0.1".into());
    let llamacpp_port: u16 = map.get("REMOTE_LOCAL_LLAMACPP_PORT").and_then(|p| p.parse().ok()).unwrap_or(18080);
    let ollama_port: u16 = map.get("REMOTE_LOCAL_OLLAMA_PORT").and_then(|p| p.parse().ok()).unwrap_or(21434);

    let pid_file = state.george_dir.join("remote-tunnel.pid");
    let pid = fs::read_to_string(&pid_file).await.ok()
        .and_then(|s| s.trim().parse::<u32>().ok());
    let pid_alive = match pid {
        Some(p) => {
            let alive = std::process::Command::new("kill")
                .args(["-0", &p.to_string()])
                .stderr(std::process::Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if !alive {
                let _ = fs::remove_file(&pid_file).await;
            }
            alive
        }
        None => false,
    };

    let llamacpp_alive = reqwest_lite_get(&format!("http://127.0.0.1:{}/health", llamacpp_port)).await.is_ok();
    let ollama_alive = reqwest_lite_get(&format!("http://127.0.0.1:{}/api/tags", ollama_port)).await.is_ok();
    let connected = pid_alive || llamacpp_alive || ollama_alive;

    Json(json!({
        "status": "ok",
        "connected": connected,
        "pid": pid,
        "target": target,
        "jump_host": jump_host,
        "forward_host": forward_host,
        "local_llamacpp_port": llamacpp_port,
        "local_ollama_port": ollama_port,
        "llamacpp_alive": llamacpp_alive,
        "ollama_alive": ollama_alive
    }))
}

pub async fn connect_tunnel(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/sys/remote.sh' && remote_connect", state.lodge_dir.display()))
        .current_dir(&state.lodge_dir)
        .output()
        .await;
    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            let success = o.status.success();
            Json(json!({ "status": if success { "ok" } else { "error" }, "output": format!("{}{}", stdout, stderr) }))
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

pub async fn disconnect_tunnel(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/sys/remote.sh' && remote_disconnect", state.lodge_dir.display()))
        .current_dir(&state.lodge_dir)
        .output()
        .await;
    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            Json(json!({ "status": "ok", "output": stdout }))
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}
