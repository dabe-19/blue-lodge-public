use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::*;
use crate::state::AppState;

#[derive(Deserialize, Debug)]
pub struct ChatPrompt {
    pub prompt: Option<String>,
    pub message: Option<String>,
    pub command: Option<String>,
    pub session_id: Option<String>,
    pub task_id: Option<String>,
    pub mode: Option<String>,
    pub max_tokens: Option<u32>,
}

#[derive(Deserialize, Debug)]
pub struct DispatchPayload {
    pub contract: Option<String>,
}

pub async fn get_session(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let session_file = state.george_dir.join("workspaces").join("web_session.jsonl");
    let mut messages = Vec::new();

    if let Ok(content) = fs::read_to_string(&session_file).await {
        for line in content.lines() {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
                messages.push(val);
            }
        }
    }

    if messages.is_empty() {
        let welcome = json!({
            "id": "welcome",
            "role": "assistant",
            "type": "welcome",
            "content": "Welcome back to the Sovereign Lodge. George is ready at the workbench. Type `/help` or select an action below.",
            "timestamp": chrono_utc_now(),
        });
        messages.push(welcome);
    }

    Json(json!({ "messages": messages }))
}

pub async fn clear_session(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let session_file = state.george_dir.join("workspaces").join("web_session.jsonl");
    let _ = fs::remove_file(&session_file).await;

    let welcome = json!({
        "id": "welcome",
        "role": "assistant",
        "type": "welcome",
        "content": "Session cleared. What shall we construct next?",
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &welcome).await;

    Json(json!({ "status": "cleared" }))
}

pub async fn append_session_message(george_dir: &PathBuf, msg: &serde_json::Value) {
    let workspaces_dir = george_dir.join("workspaces");
    let _ = fs::create_dir_all(&workspaces_dir).await;
    let session_file = workspaces_dir.join("web_session.jsonl");

    let mut line = serde_json::to_string(msg).unwrap_or_default();
    line.push('\n');

    append_to_file(&session_file, &line).await;
}

#[allow(dead_code)]
pub async fn execute_chat_tool(lodge_dir: &PathBuf, name: &str, args: &serde_json::Value) -> String {
    match name {
        "web_fetch" => {
            let url = args.get("url").and_then(|v| v.as_str()).unwrap_or("").trim();
            if url.is_empty() {
                return "Error: URL is required".into();
            }
            let lodge_str = lodge_dir.to_string_lossy();
            let cmd_str = format!("source '{}/lib/comms/web.sh' 2>/dev/null; web_fetch '{}'", lodge_str, url.replace('\'', "'\\''"));
            let out = tokio::process::Command::new("bash")
                .args(["-c", &cmd_str])
                .current_dir(lodge_dir)
                .output()
                .await;
            match out {
                Ok(res) => {
                    let s = String::from_utf8_lossy(&res.stdout);
                    if s.trim().is_empty() {
                        let err = String::from_utf8_lossy(&res.stderr);
                        if err.trim().is_empty() { "Page returned empty content.".into() } else { err.to_string() }
                    } else {
                        if s.len() > 6000 {
                            format!("{}...\n[Content truncated at 6000 characters]", &s[..6000])
                        } else {
                            s.to_string()
                        }
                    }
                }
                Err(e) => format!("Error fetching web content: {}", e),
            }
        }
        "web_search" => {
            let q = args.get("query").and_then(|v| v.as_str()).unwrap_or("").trim();
            let count = args.get("count").and_then(|v| v.as_u64()).unwrap_or(5).min(10);
            if q.is_empty() {
                return "Error: Search query is required".into();
            }
            let lodge_str = lodge_dir.to_string_lossy();
            let cmd_str = format!("source '{}/lib/comms/web.sh' 2>/dev/null; web_search '{}' {}", lodge_str, q.replace('\'', "'\\''"), count);
            let out = tokio::process::Command::new("bash")
                .args(["-c", &cmd_str])
                .current_dir(lodge_dir)
                .output()
                .await;
            match out {
                Ok(res) => {
                    let s = String::from_utf8_lossy(&res.stdout);
                    if s.trim().is_empty() { "No search results found.".into() } else { s.to_string() }
                }
                Err(e) => format!("Error running search: {}", e),
            }
        }
        "datetime_now" => {
            let out = tokio::process::Command::new("date")
                .args(["+%Y-%m-%d %H:%M:%S %Z (%A)"])
                .output()
                .await;
            match out {
                Ok(res) => String::from_utf8_lossy(&res.stdout).trim().to_string(),
                Err(_) => chrono_utc_now(),
            }
        }
        "file_read" => {
            let rel_path = args.get("path").and_then(|v| v.as_str()).unwrap_or("").trim();
            if rel_path.is_empty() {
                return "Error: file path is required".into();
            }
            let full_path = lodge_dir.join(rel_path);
            let start = args.get("start_line").and_then(|v| v.as_u64()).unwrap_or(1) as usize;
            let max_lines = args.get("max_lines").and_then(|v| v.as_u64()).unwrap_or(100).min(200) as usize;
            match tokio::fs::read_to_string(&full_path).await {
                Ok(content) => {
                    let lines: Vec<&str> = content.lines().collect();
                    if lines.is_empty() {
                        return "(empty file)".into();
                    }
                    let s_idx = if start > 0 { start - 1 } else { 0 };
                    let e_idx = (s_idx + max_lines).min(lines.len());
                    if s_idx >= lines.len() {
                        return format!("Start line {} beyond total lines ({})", start, lines.len());
                    }
                    lines[s_idx..e_idx]
                        .iter()
                        .enumerate()
                        .map(|(i, l)| format!("{:4}: {}", s_idx + i + 1, l))
                        .collect::<Vec<_>>()
                        .join("\n")
                }
                Err(e) => format!("Error reading file {}: {}", rel_path, e),
            }
        }
        "file_grep" => {
            let pat = args.get("pattern").and_then(|v| v.as_str()).unwrap_or("").trim();
            let sub = args.get("path").and_then(|v| v.as_str()).unwrap_or(".").trim();
            if pat.is_empty() {
                return "Error: search pattern is required".into();
            }
            let out = tokio::process::Command::new("grep")
                .args(["-rn", "-m", "20", "--exclude-dir=.git", "--exclude-dir=target", pat, sub])
                .current_dir(lodge_dir)
                .output()
                .await;
            match out {
                Ok(res) => {
                    let s = String::from_utf8_lossy(&res.stdout);
                    if s.trim().is_empty() { "No matches found.".into() } else { s.to_string() }
                }
                Err(e) => format!("Error searching files: {}", e),
            }
        }
        "dir_list" => {
            let rel_path = args.get("path").and_then(|v| v.as_str()).unwrap_or(".").trim();
            let full_path = lodge_dir.join(rel_path);
            match tokio::fs::read_dir(&full_path).await {
                Ok(mut entries) => {
                    let mut items = Vec::new();
                    while let Ok(Some(entry)) = entries.next_entry().await {
                        let file_name = entry.file_name().to_string_lossy().to_string();
                        let is_dir = entry.file_type().await.map(|t| t.is_dir()).unwrap_or(false);
                        items.push(format!("{}{}", file_name, if is_dir { "/" } else { "" }));
                    }
                    items.sort();
                    items.join("\n")
                }
                Err(e) => format!("Error listing directory {}: {}", rel_path, e),
            }
        }
        "recall_query" => {
            let q = args.get("query").and_then(|v| v.as_str()).unwrap_or("").trim();
            if q.is_empty() {
                return "Error: query is required".into();
            }
            let db_path = lodge_dir.join(".george").join("recall.db");
            if !db_path.exists() {
                return "Recall database is not initialized yet.".into();
            }
            let term_clean = q.replace('\'', "''");
            let sql = format!(
                "SELECT section, substr(content, 1, 300) AS snippet FROM chunks_fts WHERE chunks_fts MATCH '{}' LIMIT 3;",
                term_clean
            );
            let out = tokio::process::Command::new("sqlite3")
                .args(["-json", &db_path.to_string_lossy(), &sql])
                .output()
                .await;
            match out {
                Ok(res) => {
                    let s = String::from_utf8_lossy(&res.stdout);
                    if s.trim().is_empty() { "No memory recollections found for that query.".into() } else { s.to_string() }
                }
                Err(e) => format!("Error querying recall: {}", e),
            }
        }
        _ => format!("Tool '{}' is not recognized.", name),
    }
}

pub async fn run_lodge_task_streaming(
    lodge_bin: PathBuf,
    lodge_dir: PathBuf,
    cmd_args: Vec<String>,
    sandbox_dir: PathBuf,
) -> String {
    use tokio::fs::OpenOptions;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let traj_file = sandbox_dir.join("trajectory.log");
    let phase_file = sandbox_dir.join(".phase");

    let mut cmd = tokio::process::Command::new(lodge_bin);
    cmd.args(&cmd_args)
        .current_dir(lodge_dir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            let err_msg = format!("Failed to spawn lodge: {}", e);
            let _ = tokio::fs::write(&traj_file, format!("\n[ERROR]: {}\n", err_msg)).await;
            return err_msg;
        }
    };

    let pid_file = sandbox_dir.join(".pid");
    if let Some(pid) = child.id() {
        let _ = tokio::fs::write(&pid_file, pid.to_string()).await;
    }

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let traj_file_out = traj_file.clone();
    let phase_file_out = phase_file.clone();
    let stdout_handle = tokio::spawn(async move {
        let mut out_text = String::new();
        if let Some(stdout) = stdout {
            let mut reader = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                out_text.push_str(&line);
                out_text.push('\n');

                if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&traj_file_out).await {
                    let _ = f.write_all(format!("{}\n", line).as_bytes()).await;
                }

                let trimmed = line.trim();
                if trimmed.starts_with("Tool Call:") || trimmed.starts_with("Native Tool Call:") {
                    let tool_name = trimmed.split_whitespace().nth(2).or_else(|| trimmed.split_whitespace().nth(1)).unwrap_or("tool");
                    let _ = tokio::fs::write(&phase_file_out, format!("Tool: {}", tool_name)).await;
                } else if trimmed.contains("[digest]") {
                    let _ = tokio::fs::write(&phase_file_out, "Sub-Turn Evidence Digest").await;
                } else if trimmed.contains("[evaluator]") {
                    let _ = tokio::fs::write(&phase_file_out, "Milestone Evaluator").await;
                } else if trimmed.contains("[honeydew]") {
                    let _ = tokio::fs::write(&phase_file_out, "Honeydew DAG Advance").await;
                } else if trimmed.starts_with("[thought]") || trimmed.starts_with("Thought:") {
                    let _ = tokio::fs::write(&phase_file_out, "Reasoning & Monologue").await;
                } else if trimmed.starts_with("Executing Workflow:") {
                    let _ = tokio::fs::write(&phase_file_out, "Executing Workflow").await;
                }
            }
        }
        out_text
    });

    let traj_file_err = traj_file.clone();
    let phase_file_err = phase_file.clone();
    let stderr_handle = tokio::spawn(async move {
        let mut err_text = String::new();
        if let Some(stderr) = stderr {
            let mut reader = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                err_text.push_str(&line);
                err_text.push('\n');
                if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&traj_file_err).await {
                    let _ = f.write_all(format!("{}\n", line).as_bytes()).await;
                }
                let trimmed = line.trim();
                if trimmed.contains("[digest]") {
                    let _ = tokio::fs::write(&phase_file_err, "Sub-Turn Evidence Digest").await;
                } else if trimmed.contains("[evaluator]") {
                    let _ = tokio::fs::write(&phase_file_err, "Milestone Evaluator").await;
                } else if trimmed.contains("[honeydew]") {
                    let _ = tokio::fs::write(&phase_file_err, "Honeydew DAG Advance").await;
                }
            }
        }
        err_text
    });

    let _ = child.wait().await;
    let _ = tokio::fs::remove_file(&pid_file).await;
    let stdout_res = stdout_handle.await.unwrap_or_default();
    let stderr_res = stderr_handle.await.unwrap_or_default();

    let _ = tokio::fs::write(phase_file, "Completed").await;

    if !stdout_res.is_empty() {
        stdout_res
    } else {
        stderr_res
    }
}

pub async fn post_chat(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ChatPrompt>,
) -> impl IntoResponse {
    let raw_cmd = payload
        .prompt
        .or(payload.message)
        .or(payload.command)
        .unwrap_or_default()
        .trim()
        .to_string();
    let sess_id = payload
        .session_id
        .unwrap_or_else(|| format!("web_{}", chrono_epoch_secs()));
    let mode = payload.mode.as_deref().unwrap_or("agentic").to_string();
    let _output_max_tokens = payload.max_tokens.unwrap_or(16384);

    if raw_cmd.is_empty() {
        return Json(json!({ "status": "error", "error": "Empty prompt" }));
    }

    let task_id = payload.task_id.unwrap_or_else(|| {
        if mode == "plan-task" {
            format!("plan_{}", chrono_epoch_secs())
        } else if mode == "agentic" {
            format!("agentic_{}", chrono_epoch_secs())
        } else {
            format!("cmd_{}", chrono_epoch_secs())
        }
    });

    let user_msg_id = format!("u_{}", chrono_epoch_secs());
    let user_msg = json!({
        "id": user_msg_id.clone(),
        "role": "user",
        "content": raw_cmd,
        "mode": mode,
        "task_id": task_id.clone(),
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &user_msg).await;

    if raw_cmd.starts_with('/') && mode != "plan-task" {
        let lodge_bin = state.lodge_dir.join("lodge");
        let lodge_dir_copy = state.lodge_dir.clone();
        let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
        let _ = fs::create_dir_all(&sandbox_dir).await;
        let _ = fs::write(sandbox_dir.join(".phase"), "Command Execution").await;
        let meta = json!({
            "id": task_id.clone(),
            "type": "command_blueprint",
            "command": raw_cmd.clone(),
            "started_at": chrono_utc_now(),
        });
        let _ = fs::write(sandbox_dir.join("task_meta.json"), serde_json::to_string_pretty(&meta).unwrap_or_default()).await;
        let init_traj = format!("── [COMMAND INITIALIZED: {}] ──\n[COMMAND]: {}\n", task_id, raw_cmd);
        let _ = fs::write(sandbox_dir.join("trajectory.log"), &init_traj).await;

        let raw_output = run_lodge_task_streaming(lodge_bin, lodge_dir_copy, vec![raw_cmd.clone()], sandbox_dir).await;
        let output_text = strip_ansi(&raw_output);

        let assistant_msg = json!({
            "id": format!("a_{}", chrono_epoch_secs()),
            "task_id": task_id.clone(),
            "role": "assistant",
            "type": "command_blueprint",
            "command": raw_cmd,
            "content": output_text,
            "timestamp": chrono_utc_now(),
        });
        append_session_message(&state.george_dir, &assistant_msg).await;

        return Json(json!({
            "status": "ok",
            "session_id": sess_id,
            "task_id": task_id,
            "type": "command_blueprint",
            "reply": output_text,
        }));
    }

    if mode == "agentic" {
        let lodge_bin = state.lodge_dir.join("lodge");
        let lodge_dir_copy = state.lodge_dir.clone();
        let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
        let _ = fs::create_dir_all(&sandbox_dir).await;
        let _ = fs::write(sandbox_dir.join(".phase"), "Autonomous ReAct Loop").await;
        let meta = json!({
            "id": task_id.clone(),
            "type": "agentic",
            "command": raw_cmd.clone(),
            "started_at": chrono_utc_now(),
        });
        let _ = fs::write(sandbox_dir.join("task_meta.json"), serde_json::to_string_pretty(&meta).unwrap_or_default()).await;
        let init_traj = format!("── [AGENTIC TASK INITIALIZED: {}] ──\n[TASK]: {}\n", task_id, raw_cmd);
        let _ = fs::write(sandbox_dir.join("trajectory.log"), &init_traj).await;

        let max_turns_val = std::env::var("AGENTIC_WEB_MAX_TURNS").unwrap_or_else(|_| "200".to_string());
        let raw_output = run_lodge_task_streaming(lodge_bin, lodge_dir_copy, vec!["--turns".to_string(), max_turns_val, raw_cmd.clone()], sandbox_dir).await;
        let output_text = strip_ansi(&raw_output);

        let assistant_msg = json!({
            "id": format!("a_{}", chrono_epoch_secs()),
            "task_id": task_id.clone(),
            "role": "assistant",
            "type": "agentic",
            "command": raw_cmd,
            "content": output_text,
            "timestamp": chrono_utc_now(),
        });
        append_session_message(&state.george_dir, &assistant_msg).await;

        return Json(json!({
            "status": "ok",
            "session_id": sess_id,
            "task_id": task_id,
            "mode": "agentic",
            "type": "agentic",
            "reply": output_text,
        }));
    }

    if mode == "plan-task" {
        let lodge_bin = state.lodge_dir.join("lodge");
        let lodge_dir_copy = state.lodge_dir.clone();
        let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
        let _ = fs::create_dir_all(&sandbox_dir).await;
        let _ = fs::write(sandbox_dir.join(".phase"), "Architect Planning").await;
        let meta = json!({
            "id": task_id.clone(),
            "type": "plan-task",
            "command": raw_cmd.clone(),
            "started_at": chrono_utc_now(),
        });
        let _ = fs::write(sandbox_dir.join("task_meta.json"), serde_json::to_string_pretty(&meta).unwrap_or_default()).await;
        let init_traj = format!("── [PLANNING TASK INITIALIZED: {}] ──\n[OBJECTIVE]: {}\n", task_id, raw_cmd);
        let _ = fs::write(sandbox_dir.join("trajectory.log"), &init_traj).await;

        let plan_arg = format!("/workflow run the-architect.agent {}", raw_cmd);
        let raw_output = run_lodge_task_streaming(lodge_bin, lodge_dir_copy, vec![plan_arg], sandbox_dir).await;
        let output_text = strip_ansi(&raw_output);

        let assistant_msg = json!({
            "id": format!("a_{}", chrono_epoch_secs()),
            "task_id": task_id.clone(),
            "role": "assistant",
            "type": "plan-task",
            "command": raw_cmd,
            "content": output_text,
            "timestamp": chrono_utc_now(),
        });
        append_session_message(&state.george_dir, &assistant_msg).await;

        return Json(json!({
            "status": "ok",
            "session_id": sess_id,
            "task_id": task_id,
            "mode": "plan-task",
            "type": "plan-task",
            "reply": output_text,
        }));
    }

    // Interactive Chat Mode: Delegate directly to pure POSIX chat_loop.sh
    let chat_script = state.lodge_dir.join("lib").join("core").join("chat_loop.sh");
    let session_file = state.george_dir.join("workspaces").join("web_session.jsonl");

    let out = tokio::process::Command::new("bash")
        .arg(&chat_script)
        .arg(&raw_cmd)
        .arg(&session_file)
        .arg("5")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    let reply_text = match out {
        Ok(res) => {
            let stdout = String::from_utf8_lossy(&res.stdout).trim().to_string();
            if !stdout.is_empty() {
                stdout
            } else {
                let stderr = String::from_utf8_lossy(&res.stderr).trim().to_string();
                if !stderr.is_empty() {
                    stderr
                } else {
                    "I am at your service at the workbench. What shall we measure or construct?".into()
                }
            }
        }
        Err(e) => format!("Execution error in chat loop: {}", e),
    };

    return Json(json!({
        "status": "ok",
        "session_id": sess_id,
        "type": "chat",
        "reply": reply_text,
    }));
}

pub async fn post_dispatch(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<DispatchPayload>,
) -> impl IntoResponse {
    let lodge_bin = state.lodge_dir.join("lodge");
    let contract_arg = payload.contract.unwrap_or_default();
    let dispatch_cmd = if contract_arg.is_empty() {
        "/dispatch".to_string()
    } else {
        format!("/dispatch {}", contract_arg)
    };

    let out = tokio::process::Command::new(lodge_bin)
        .args([&dispatch_cmd])
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    let raw_output = match out {
        Ok(res) => {
            let stdout = String::from_utf8_lossy(&res.stdout).to_string();
            let stderr = String::from_utf8_lossy(&res.stderr).to_string();
            if !stdout.is_empty() { stdout } else { stderr }
        }
        Err(e) => format!("Execution error: {}", e),
    };
    let output_text = strip_ansi(&raw_output);

    Json(json!({
        "status": "ok",
        "reply": output_text,
    }))
}
