use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::state::AppState;

fn valid_id(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() < 2 || b.len() > 49 {
        return false;
    }
    let first = b[0];
    if !(first.is_ascii_lowercase() || first.is_ascii_digit()) {
        return false;
    }
    b.iter()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_' || *c == b'-')
}

fn valid_owner(s: &str) -> bool {
    s == "heartwood" || valid_id(s)
}

#[derive(Deserialize, Default)]
pub struct SaveLoopReq {
    pub target: Option<String>, // "override" (default) | "source"
    #[serde(rename = "loop")]
    pub loop_def: Value,
}

#[derive(Deserialize, Default)]
pub struct CreateLoopReq {
    pub id: String,
    pub target: Option<String>,
    #[serde(rename = "loop")]
    pub loop_def: Value,
}

#[derive(Deserialize, Default)]
pub struct DeleteLoopQuery {
    pub target: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct RunLoopReq {
    pub params: Option<Value>,
    pub max_turns: Option<u32>,
}

async fn run_loop_schema(
    state: &AppState,
    args: &[&str],
    stdin_payload: Option<&[u8]>,
) -> Result<(bool, String, String), String> {
    let script = state.lodge_dir.join("lib").join("core").join("loop_schema.py");
    let mut cmd = Command::new("python3");
    cmd.arg(&script)
        .args(args)
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    if stdin_payload.is_some() {
        cmd.stdin(Stdio::piped());
    } else {
        cmd.stdin(Stdio::null());
    }

    let mut child = cmd.spawn().map_err(|e| format!("failed to spawn loop_schema.py: {}", e))?;
    if let Some(bytes) = stdin_payload {
        if let Some(mut sin) = child.stdin.take() {
            let _ = sin.write_all(bytes).await;
        }
    }
    let out = child
        .wait_with_output()
        .await
        .map_err(|e| format!("loop_schema.py wait error: {}", e))?;
    Ok((
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).to_string(),
        String::from_utf8_lossy(&out.stderr).to_string(),
    ))
}

/// GET /api/loops — List all Heartwood and Module declarative loops
pub async fn list_all_loops(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match run_loop_schema(&state, &["list"], None).await {
        Ok((true, stdout, _)) => {
            let val: Value = serde_json::from_str(&stdout).unwrap_or_else(|_| json!({"status": "ok", "loops": []}));
            (StatusCode::OK, Json(val))
        }
        Ok((false, stdout, stderr)) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": if stderr.is_empty() { stdout } else { stderr }})),
        ),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"status": "error", "message": e}))),
    }
}

/// GET /api/loops/:owner — List loops + available tools for one owner (`heartwood` or `<module_id>`)
pub async fn list_owner_loops(
    State(state): State<Arc<AppState>>,
    Path(owner): Path<String>,
) -> impl IntoResponse {
    if !valid_owner(&owner) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid owner id"})),
        );
    }

    let loops_res = run_loop_schema(&state, &["list", "--owner", &owner], None).await;
    let tools_res = run_loop_schema(&state, &["available-tools", &owner], None).await;

    let loops = match loops_res {
        Ok((true, stdout, _)) => serde_json::from_str::<Value>(&stdout)
            .ok()
            .and_then(|v| v.get("loops").cloned())
            .unwrap_or_else(|| json!([])),
        _ => json!([]),
    };
    let available_tools = match tools_res {
        Ok((true, stdout, _)) => serde_json::from_str::<Value>(&stdout).unwrap_or_else(|_| json!({})),
        _ => json!({}),
    };

    (
        StatusCode::OK,
        Json(json!({
            "status": "ok",
            "owner": owner,
            "loops": loops,
            "available_tools": available_tools
        })),
    )
}

/// GET /api/loops/:owner/:loop_id — Resolve single loop with override/source metadata & available tools
pub async fn get_loop_detail(
    State(state): State<Arc<AppState>>,
    Path((owner, loop_id)): Path<(String, String)>,
) -> impl IntoResponse {
    if !valid_owner(&owner) || !valid_id(&loop_id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid owner or loop id"})),
        );
    }

    match run_loop_schema(&state, &["resolve", &owner, &loop_id], None).await {
        Ok((true, stdout, _)) => {
            let val: Value = serde_json::from_str(&stdout).unwrap_or_else(|_| json!({"status": "error"}));
            (StatusCode::OK, Json(val))
        }
        Ok((false, stdout, _)) => {
            let val: Value = serde_json::from_str(&stdout)
                .unwrap_or_else(|_| json!({"status": "error", "message": "loop not found"}));
            (StatusCode::NOT_FOUND, Json(val))
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"status": "error", "message": e}))),
    }
}

/// PUT /api/loops/:owner/:loop_id — Validate and save loop to override or source layer
pub async fn save_loop(
    State(state): State<Arc<AppState>>,
    Path((owner, loop_id)): Path<(String, String)>,
    Json(req): Json<SaveLoopReq>,
) -> impl IntoResponse {
    if !valid_owner(&owner) || !valid_id(&loop_id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid owner or loop id"})),
        );
    }
    let target = match req.target.as_deref() {
        Some("source") => "source",
        _ => "override",
    };
    let payload_bytes = match serde_json::to_vec(&req.loop_def) {
        Ok(b) => b,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"status": "error", "message": format!("invalid json: {}", e)})),
            );
        }
    };

    match run_loop_schema(&state, &["save", &owner, &loop_id, "--target", target], Some(&payload_bytes)).await {
        Ok((true, stdout, _)) => {
            let val: Value = serde_json::from_str(&stdout).unwrap_or_else(|_| json!({"status": "ok"}));
            (StatusCode::OK, Json(val))
        }
        Ok((false, stdout, stderr)) => {
            let val: Value = serde_json::from_str(&stdout)
                .unwrap_or_else(|_| json!({"status": "error", "message": if stderr.is_empty() { stdout } else { stderr }}));
            (StatusCode::BAD_REQUEST, Json(val))
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"status": "error", "message": e}))),
    }
}

/// POST /api/loops/:owner — Create a new custom loop for Heartwood or a Module
pub async fn create_loop(
    State(state): State<Arc<AppState>>,
    Path(owner): Path<String>,
    Json(req): Json<CreateLoopReq>,
) -> impl IntoResponse {
    if !valid_owner(&owner) || !valid_id(&req.id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid owner or loop id (lowercase letters, digits, _ or -, 2..49 chars)"})),
        );
    }
    let target = match req.target.as_deref() {
        Some("source") => "source",
        _ => "override",
    };
    let payload_bytes = match serde_json::to_vec(&req.loop_def) {
        Ok(b) => b,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"status": "error", "message": format!("invalid json: {}", e)})),
            );
        }
    };

    match run_loop_schema(&state, &["save", &owner, &req.id, "--target", target], Some(&payload_bytes)).await {
        Ok((true, stdout, _)) => {
            let val: Value = serde_json::from_str(&stdout).unwrap_or_else(|_| json!({"status": "ok"}));
            (StatusCode::CREATED, Json(val))
        }
        Ok((false, stdout, stderr)) => {
            let val: Value = serde_json::from_str(&stdout)
                .unwrap_or_else(|_| json!({"status": "error", "message": if stderr.is_empty() { stdout } else { stderr }}));
            (StatusCode::BAD_REQUEST, Json(val))
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"status": "error", "message": e}))),
    }
}

/// DELETE /api/loops/:owner/:loop_id?target=override|source — Revert override or delete custom loop
pub async fn delete_loop(
    State(state): State<Arc<AppState>>,
    Path((owner, loop_id)): Path<(String, String)>,
    Query(q): Query<DeleteLoopQuery>,
) -> impl IntoResponse {
    if !valid_owner(&owner) || !valid_id(&loop_id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid owner or loop id"})),
        );
    }
    let target = match q.target.as_deref() {
        Some("source") => "source",
        _ => "override",
    };

    match run_loop_schema(&state, &["delete", &owner, &loop_id, "--target", target], None).await {
        Ok((true, stdout, _)) => {
            let val: Value = serde_json::from_str(&stdout).unwrap_or_else(|_| json!({"status": "ok"}));
            (StatusCode::OK, Json(val))
        }
        Ok((false, stdout, stderr)) => {
            let val: Value = serde_json::from_str(&stdout)
                .unwrap_or_else(|_| json!({"status": "error", "message": if stderr.is_empty() { stdout } else { stderr }}));
            (StatusCode::NOT_FOUND, Json(val))
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"status": "error", "message": e}))),
    }
}

/// POST /api/loops/:owner/:loop_id/run — Execute any declarative loop in a monitored sandbox
pub async fn run_loop(
    State(state): State<Arc<AppState>>,
    Path((owner, loop_id)): Path<(String, String)>,
    Json(req): Json<RunLoopReq>,
) -> impl IntoResponse {
    if !valid_owner(&owner) || !valid_id(&loop_id) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"status": "error", "message": "invalid owner or loop id"})),
        );
    }

    // Verify loop exists and read its default max_turns (defaults to 200)
    let resolved = match run_loop_schema(&state, &["resolve", &owner, &loop_id], None).await {
        Ok((true, stdout, _)) => serde_json::from_str::<Value>(&stdout).ok(),
        _ => None,
    };
    let Some(res_val) = resolved else {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({"status": "error", "message": format!("loop '{}/{}' not found", owner, loop_id)})),
        );
    };

    let loop_default_turns = res_val
        .pointer("/loop/defaults/max_turns")
        .and_then(|v| v.as_u64())
        .unwrap_or(200) as u32;
    let max_turns = req.max_turns.unwrap_or(loop_default_turns).clamp(1, 500);
    let loop_name = res_val
        .pointer("/loop/name")
        .and_then(|v| v.as_str())
        .unwrap_or(&loop_id)
        .to_string();

    let epoch = crate::helpers::chrono_epoch_secs();
    let task_id = if owner == "heartwood" {
        format!("loop_heartwood_{}_{}", loop_id.replace('-', "_"), epoch)
    } else {
        format!("mod_{}_{}_{}", owner.replace('-', "_"), loop_id.replace('-', "_"), epoch)
    };
    let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
    let inputs_dir = sandbox_dir.join("inputs");
    if let Err(e) = tokio::fs::create_dir_all(&inputs_dir).await {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": format!("failed to create sandbox: {}", e)})),
        );
    }

    let mut params_val = req.params.unwrap_or_else(|| json!({}));
    if !params_val.is_object() {
        params_val = json!({"value": params_val});
    }
    if let Some(obj) = params_val.as_object_mut() {
        obj.insert("sandbox_dir".to_string(), json!(sandbox_dir.to_string_lossy().to_string()));
        obj.insert("task_id".to_string(), json!(task_id.clone()));
    }
    let params_path = inputs_dir.join("params.json");
    let _ = tokio::fs::write(
        &params_path,
        serde_json::to_string_pretty(&params_val).unwrap_or_else(|_| "{}".into()),
    )
    .await;

    let display_cmd = format!("[{}/{}] {}", owner, loop_id, loop_name);
    let meta = json!({
        "id": task_id.clone(),
        "type": if owner == "heartwood" { "loop_workflow" } else { "module_workflow" },
        "module_id": if owner == "heartwood" { Value::Null } else { json!(owner.clone()) },
        "owner": owner.clone(),
        "workflow": loop_id.clone(),
        "command": display_cmd,
        "max_turns": max_turns,
        "started_at": crate::helpers::chrono_utc_now(),
    });
    let _ = tokio::fs::write(
        sandbox_dir.join("task_meta.json"),
        serde_json::to_string_pretty(&meta).unwrap_or_default(),
    )
    .await;
    let _ = tokio::fs::write(
        sandbox_dir.join(".phase"),
        format!("Initializing {}/{}", owner, loop_id),
    )
    .await;
    let traj_file = sandbox_dir.join("trajectory.log");
    let _ = tokio::fs::write(
        &traj_file,
        format!(
            "── [AGENTIC LOOP INITIALIZED: {}] ──\n[LOOP]: {}/{} ({})\n[MAX_TURNS]: {}\n[SANDBOX]: {}\n",
            task_id, owner, loop_id, loop_name, max_turns, sandbox_dir.display()
        ),
    )
    .await;

    let loop_engine = state.lodge_dir.join("lib").join("core").join("loop_engine.sh");
    let lodge_dir_bg = state.lodge_dir.clone();
    let george_dir_bg = state.george_dir.clone();
    let sandbox_bg = sandbox_dir.clone();
    let params_bg = params_path.clone();
    let owner_bg = owner.clone();
    let loop_id_bg = loop_id.clone();
    let task_id_bg = task_id.clone();

    tokio::spawn(async move {
        let traj_path = sandbox_bg.join("trajectory.log");
        let phase_path = sandbox_bg.join(".phase");
        let pid_path = sandbox_bg.join(".pid");
        let done_path = sandbox_bg.join(".done");

        let mut cmd = Command::new("bash");
        #[cfg(unix)]
        cmd.process_group(0);

        // Redirect stdout/stderr directly to trajectory.log instead of Stdio::piped()
        // so active ALP v1 loops survive george-web restarts without SIGPIPE.
        let (out_stdio, err_stdio) = match std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&traj_path)
        {
            Ok(f) => match f.try_clone() {
                Ok(f2) => (Stdio::from(f), Stdio::from(f2)),
                Err(_) => (Stdio::from(f), Stdio::null()),
            },
            Err(_) => (Stdio::null(), Stdio::null()),
        };

        cmd.arg(&loop_engine)
            .arg("run")
            .arg(&owner_bg)
            .arg(&loop_id_bg)
            .arg(&sandbox_bg)
            .arg(&params_bg)
            .arg(max_turns.to_string())
            .current_dir(&lodge_dir_bg)
            .env("LODGE_DIR", &lodge_dir_bg)
            .env("GEORGE_DIR", &george_dir_bg)
            .env("GEORGE_WEB_INTERACTIVE", "1")
            .env("AGENT_IPC_PRIORITY", "100")
            .env("LODGE_NO_LOCK", "1")
            .env("LODGE_SKIP_MCP_AUTOSTART", "1")
            .env("LODGE_ACTIVE_WORKFLOW", &loop_id_bg)
            .env("LODGE_SANDBOX_DIR", &sandbox_bg)
            .env("GEORGE_TASK_ID", &task_id_bg)
            .stdin(Stdio::null())
            .stdout(out_stdio)
            .stderr(err_stdio);

        if owner_bg != "heartwood" {
            cmd.env("LODGE_ACTIVE_MODULE", &owner_bg);
        }

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                let _ = crate::helpers::append_to_file(&traj_path, &format!("\n[ERROR]: Failed to spawn loop_engine.sh: {}\n", e)).await;
                let _ = tokio::fs::write(&phase_path, "Failed").await;
                let _ = tokio::fs::write(&done_path, "1").await;
                return;
            }
        };

        if let Some(pid) = child.id() {
            let _ = tokio::fs::write(&pid_path, pid.to_string()).await;
        }

        let wait_res = child.wait().await;
        let _ = tokio::fs::remove_file(&pid_path).await;

        if let Ok(raw_traj) = tokio::fs::read_to_string(&traj_path).await {
            let clean_out = crate::helpers::strip_ansi(&raw_traj);
            let _ = tokio::fs::write(sandbox_bg.join("output.txt"), &clean_out).await;
        }

        let final_phase = match wait_res {
            Ok(st) if st.success() => "Completed".to_string(),
            Ok(st) => format!("Failed (exit {})", st.code().unwrap_or(-1)),
            Err(_) => "Failed".to_string(),
        };
        let _ = tokio::fs::write(&phase_path, &final_phase).await;
        let _ = tokio::fs::write(&done_path, "1").await;
    });

    (
        StatusCode::OK,
        Json(json!({
            "status": "ok",
            "task_id": task_id,
            "owner": owner,
            "loop_id": loop_id,
            "max_turns": max_turns,
            "stream_url": format!("/api/tasks/{}/stream", task_id),
        })),
    )
}
