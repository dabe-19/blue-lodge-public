use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use tokio::process::Command;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct SdrConfigPayload {
    pub remote_gateway: Option<String>,
    pub remote_sdr_host: Option<String>,
    pub remote_recordings_path: Option<String>,
    pub emergency_keywords: Option<Vec<String>>,
}

#[derive(Deserialize, Default)]
pub struct SimulatePayload {
    pub emergency: Option<bool>,
}

fn get_python_bin(state: &AppState) -> String {
    let venv_py = state.lodge_dir.join(".venv").join("bin").join("python");
    if venv_py.exists() {
        venv_py.to_string_lossy().to_string()
    } else {
        "python3".to_string()
    }
}

pub async fn get_sdr_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sdr_ingest.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse SDR ingest JSON output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn save_sdr_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SdrConfigPayload>,
) -> impl IntoResponse {
    let cfg_file = state.george_dir.join("sdr_config.json");
    let mut current_config: serde_json::Value = if cfg_file.exists() {
        fs::read_to_string(&cfg_file)
            .await
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| json!({}))
    } else {
        json!({})
    };

    if let Some(gw) = payload.remote_gateway {
        current_config["remote_gateway"] = json!(gw);
    }
    if let Some(host) = payload.remote_sdr_host {
        current_config["remote_sdr_host"] = json!(host);
    }
    if let Some(path) = payload.remote_recordings_path {
        current_config["remote_recordings_path"] = json!(path);
    }
    if let Some(kw) = payload.emergency_keywords {
        current_config["emergency_keywords"] = json!(kw);
    }

    match fs::write(&cfg_file, serde_json::to_string_pretty(&current_config).unwrap_or_default()).await {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "message": "Saved SDR config", "config": current_config})),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn sync_sdr_gateway(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sdr_ingest.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--sync")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "raw_output": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn ingest_sdr_spool(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sdr_ingest.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--ingest")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "raw_output": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn simulate_sdr_call(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SimulatePayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sdr_ingest.py");

    let is_emergency = payload.emergency.unwrap_or(false);
    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script).arg("--simulate");
    if is_emergency {
        cmd.arg("--emergency");
    }
    cmd.current_dir(&state.lodge_dir);

    let output = cmd.output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            (
                StatusCode::OK,
                Json(json!({
                    "status": "ok",
                    "emergency": is_emergency,
                    "output": stdout.trim().to_string()
                })),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_sdr_dossier(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let dossier_path = state.lodge_dir.join("dossiers").join("sdr_osint.md");
    if !dossier_path.exists() {
        return Json(json!({
            "status": "ok",
            "content": "# SDR OSINT & Public Radio Intelligence Log\n\nNo transmissions recorded yet.",
            "path": dossier_path.to_string_lossy().to_string()
        }));
    }

    match fs::read_to_string(&dossier_path).await {
        Ok(content) => Json(json!({
            "status": "ok",
            "content": content,
            "path": dossier_path.to_string_lossy().to_string()
        })),
        Err(e) => Json(json!({"status": "error", "message": e.to_string()})),
    }
}

pub async fn transcribe_sdr_spool(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sdr_transcribe.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--spool")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "message": "Transcription finished", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_sdr_node_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sdr_transcribe.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--node-status")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "hardware": "Dynamic Remote Node", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_sdr_audio(
    State(state): State<Arc<AppState>>,
    axum::extract::Path(call_id): axum::extract::Path<String>,
) -> impl IntoResponse {
    // Sanitize call_id against path traversal
    let safe_id: String = call_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_' || *c == '.')
        .collect();
    if safe_id.is_empty() || safe_id.contains("..") {
        return (
            StatusCode::BAD_REQUEST,
            [(axum::http::header::CONTENT_TYPE, "text/plain")],
            Vec::new(),
        );
    }

    let stem = safe_id
        .trim_end_matches(".m4a")
        .trim_end_matches(".wav")
        .trim_end_matches(".mp3");

    let search_dirs = [
        state.george_dir.join("sdr").join("archive"),
        state.george_dir.join("sdr").join("spool"),
        state.george_dir.join("sdr").join("audio"),
    ];

    for dir in &search_dirs {
        for (ext, mime) in [(".m4a", "audio/mp4"), (".wav", "audio/wav"), (".mp3", "audio/mpeg")] {
            let candidate = dir.join(format!("{}{}", stem, ext));
            if candidate.exists() {
                if let Ok(bytes) = fs::read(&candidate).await {
                    return (
                        StatusCode::OK,
                        [(axum::http::header::CONTENT_TYPE, mime)],
                        bytes,
                    );
                }
            }
        }
    }

    (
        StatusCode::NOT_FOUND,
        [(axum::http::header::CONTENT_TYPE, "text/plain")],
        b"Audio recording not found".to_vec(),
    )
}

