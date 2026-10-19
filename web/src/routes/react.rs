use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use tokio::process::Command;

use crate::helpers::{is_pid_alive, read_pid_from_file};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct ReactorAddPayload {
    pub id: String,
    pub event_type: String,
    pub pattern: Option<String>,
    pub action: String,
    pub debounce: Option<u64>,
}

#[derive(Deserialize)]
pub struct EmitPayload {
    pub event_type: String,
    pub payload: serde_json::Value,
}

#[derive(Deserialize)]
pub struct OsintConfigPayload {
    pub yaml: String,
}

#[derive(Deserialize)]
pub struct OsintSweepPayload {
    pub watcher_id: Option<String>,
}

pub async fn get_reactors(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let reactors_path = state.george_dir.join("reactors.json");
    if !reactors_path.exists() {
        return Json(json!({
            "status": "ok",
            "reactors": [],
            "stats": {}
        }));
    }

    match fs::read_to_string(&reactors_path).await {
        Ok(content) => match serde_json::from_str::<serde_json::Value>(&content) {
            Ok(val) => Json(val),
            Err(e) => Json(json!({"status": "error", "message": e.to_string()})),
        },
        Err(e) => Json(json!({"status": "error", "message": e.to_string()})),
    }
}

pub async fn add_reactor(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ReactorAddPayload>,
) -> impl IntoResponse {
    let rid = payload.id.trim();
    let rtype = payload.event_type.trim();
    let rpattern = payload.pattern.as_deref().unwrap_or(".*").trim();
    let raction = payload.action.trim();
    let rdebounce = payload.debounce.unwrap_or(2);

    if rid.is_empty() || rtype.is_empty() || raction.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "Missing required fields"})),
        );
    }

    let script = state.lodge_dir.join("commands").join("react.sh");
    let cmd_arg = format!(
        "add {} {} {} {} --debounce {}",
        rid, rtype, rpattern, raction, rdebounce
    );

    let output = Command::new("bash")
        .arg(&script)
        .arg(&cmd_arg)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => (
            StatusCode::OK,
            Json(json!({"status": "ok", "message": format!("Reactor '{}' registered", rid)})),
        ),
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status": "error", "message": err.to_string()})),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn delete_reactor(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("commands").join("react.sh");
    let cmd_arg = format!("remove {}", id);

    let output = Command::new("bash")
        .arg(&script)
        .arg(&cmd_arg)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => (
            StatusCode::OK,
            Json(json!({"status": "ok", "message": format!("Reactor '{}' removed", id)})),
        ),
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status": "error", "message": err.to_string()})),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn toggle_reactor(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("commands").join("react.sh");
    let cmd_arg = format!("toggle {}", id);

    let output = Command::new("bash")
        .arg(&script)
        .arg(&cmd_arg)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => (
            StatusCode::OK,
            Json(json!({"status": "ok", "message": format!("Reactor '{}' toggled", id)})),
        ),
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status": "error", "message": err.to_string()})),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn emit_event(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<EmitPayload>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("commands").join("react.sh");
    let payload_str = payload.payload.to_string();
    let cmd_arg = format!("emit {} {}", payload.event_type, payload_str);

    let output = Command::new("bash")
        .arg(&script)
        .arg(&cmd_arg)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => (
            StatusCode::OK,
            Json(json!({"status": "ok", "message": "Event emitted to bus"})),
        ),
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"status": "error", "message": err.to_string()})),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_osint_config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let cfg_path = state.george_dir.join("osint_watchers.yaml");
    let template_path = state.lodge_dir.join("config").join("osint_watchers.yaml.template");

    let content = if cfg_path.exists() {
        fs::read_to_string(&cfg_path).await.unwrap_or_default()
    } else if template_path.exists() {
        fs::read_to_string(&template_path).await.unwrap_or_default()
    } else {
        String::new()
    };

    let seen_path = state.george_dir.join("ipc").join("osint_seen.json");
    let seen_count = if seen_path.exists() {
        if let Ok(data) = fs::read_to_string(&seen_path).await {
            serde_json::from_str::<serde_json::Value>(&data)
                .ok()
                .and_then(|v| v.get("items").and_then(|i| i.as_object()).map(|o| o.len()))
                .unwrap_or(0)
        } else {
            0
        }
    } else {
        0
    };

    Json(json!({
        "status": "ok",
        "yaml": content,
        "seen_count": seen_count
    }))
}

pub async fn save_osint_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<OsintConfigPayload>,
) -> impl IntoResponse {
    let cfg_path = state.george_dir.join("osint_watchers.yaml");
    if let Some(parent) = cfg_path.parent() {
        let _ = fs::create_dir_all(parent).await;
    }

    match fs::write(&cfg_path, &payload.yaml).await {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "message": "Saved osint_watchers.yaml"})),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn run_osint_sweep(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<OsintSweepPayload>,
) -> impl IntoResponse {
    let py_script = state.lodge_dir.join("lib").join("tools").join("osint_watcher.py");
    let venv_py = state.lodge_dir.join(".venv").join("bin").join("python");
    let py_bin = if venv_py.exists() {
        venv_py.to_string_lossy().to_string()
    } else {
        "python3".to_string()
    };

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&py_script);
    cmd.current_dir(&state.lodge_dir);

    if let Some(target) = payload.watcher_id {
        cmd.arg("--test").arg(target);
    } else {
        cmd.arg("--sweep");
    }

    match cmd.output().await {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({
                        "status": "ok",
                        "raw_output": stdout.to_string()
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

#[derive(Deserialize, Default)]
pub struct ApiSearchQuery {
    pub query: Option<String>,
    pub category: Option<String>,
}

#[derive(Deserialize)]
pub struct ApiBuildPayload {
    pub preset: Option<String>,
    pub id: Option<String>,
    pub name: Option<String>,
    pub url: Option<String>,
    pub event_type: Option<String>,
    pub interval: Option<u64>,
    pub filter: Option<String>,
    pub action: Option<String>,
}

fn get_python_bin(state: &AppState) -> String {
    let venv_py = state.lodge_dir.join(".venv").join("bin").join("python");
    if venv_py.exists() {
        venv_py.to_string_lossy().to_string()
    } else {
        "python3".to_string()
    }
}

pub async fn get_api_presets(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("api_trigger_builder.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--presets")
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
                    Json(json!({"status": "error", "message": "Failed to parse API presets JSON"})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn search_api_catalog(
    State(state): State<Arc<AppState>>,
    Query(params): Query<ApiSearchQuery>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("api_trigger_builder.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script).arg("--json");

    if let Some(q) = params.query {
        if !q.trim().is_empty() {
            cmd.arg("--search").arg(q.trim());
        }
    }
    if let Some(cat) = params.category {
        if !cat.trim().is_empty() {
            cmd.arg("--category").arg(cat.trim());
        }
    }
    cmd.current_dir(&state.lodge_dir);

    match cmd.output().await {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "results": []})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn build_api_trigger(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ApiBuildPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("api_trigger_builder.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script).arg("--json");

    if let Some(preset) = payload.preset {
        cmd.arg("--build-preset").arg(preset);
        if let Some(action) = payload.action {
            cmd.arg("--action").arg(action);
        }
    } else if let (Some(id), Some(url), Some(event_type)) = (payload.id, payload.url, payload.event_type) {
        cmd.arg("--build-custom")
            .arg("--id").arg(id)
            .arg("--url").arg(url)
            .arg("--event-type").arg(event_type);
        if let Some(name) = payload.name {
            cmd.arg("--name").arg(name);
        }
        if let Some(interval) = payload.interval {
            cmd.arg("--interval").arg(interval.to_string());
        }
        if let Some(filter) = payload.filter {
            cmd.arg("--filter").arg(filter);
        }
        if let Some(action) = payload.action {
            cmd.arg("--action").arg(action);
        }
    } else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "Specify 'preset' or ('id', 'url', 'event_type')"})),
        );
    }

    cmd.current_dir(&state.lodge_dir);

    match cmd.output().await {
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

pub async fn start_event_bus_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/ipc/event_bus.sh' && event_bus_start", state.lodge_dir.display()))
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

pub async fn stop_event_bus_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/ipc/event_bus.sh' && event_bus_stop", state.lodge_dir.display()))
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

pub async fn restart_event_bus_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/ipc/event_bus.sh' && event_bus_stop && sleep 1 && event_bus_start", state.lodge_dir.display()))
        .current_dir(&state.lodge_dir)
        .output()
        .await;
    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            Json(json!({ "status": "ok", "output": format!("{}{}", stdout, stderr) }))
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

pub async fn get_event_bus_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let pid_file = state.george_dir.join("ipc").join("event_bus.pid");
    let pid = read_pid_from_file(&pid_file);
    let alive = pid.map_or(false, is_pid_alive);
    let reactors_file = state.george_dir.join("reactors.json");
    let mut reactors_count = 0;
    let mut events_total = 0u64;
    let mut reactions_total = 0u64;
    if let Ok(content) = fs::read_to_string(&reactors_file).await {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&content) {
            if let Some(r_arr) = v.get("reactors").and_then(|r| r.as_array()) {
                reactors_count = r_arr.len();
            }
            if let Some(stats) = v.get("stats") {
                events_total = stats.get("events_total").and_then(|x| x.as_u64()).unwrap_or(0);
                reactions_total = stats.get("reactions_fired").and_then(|x| x.as_u64()).unwrap_or(0);
            }
        }
    }
    Json(json!({
        "status": "ok",
        "alive": alive,
        "pid": pid,
        "phase": if alive { format!("Active ({} Events / {} Reactions)", events_total, reactions_total) } else { "Daemon Inactive".to_string() },
        "reactors_count": reactors_count,
        "events_total": events_total,
        "reactions_total": reactions_total
    }))
}

