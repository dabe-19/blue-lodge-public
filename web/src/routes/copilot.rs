use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;
use tokio::io::AsyncBufReadExt;
use tokio::process::Command;

use crate::helpers::*;
use crate::routes::chat::append_session_message;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CopilotChatPayload {
    pub file_path: String,
    pub file_content: String,
    pub instruction: String,
    pub selection: Option<String>,
    pub task_id: Option<String>,
    pub session_id: Option<String>,
    pub agent: Option<String>,
    pub context_pills: Option<Vec<String>>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct SaveAgentPayload {
    pub name: String,
    pub description: String,
    pub rules: Option<Vec<String>>,
    pub workflow_steps: Option<Vec<String>>,
    pub argument_hint: Option<String>,
    pub raw_markdown: Option<String>,
}

#[derive(Deserialize)]
pub struct SaveWorkflowPayload {
    pub name: String,
    pub description: String,
    pub steps: Option<Vec<String>>,
    pub objective: Option<String>,
}

#[derive(Deserialize)]
pub struct BuildToolPayload {
    pub name: String,
    pub language: Option<String>,
    pub subsystem: Option<String>,
    pub description: Option<String>,
    pub code_content: Option<String>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct TestToolPayload {
    pub name: String,
    pub args: Option<Vec<String>>,
    pub timeout_secs: Option<u64>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct CommentCodePayload {
    pub file_path: String,
    pub file_content: String,
    pub instruction: Option<String>,
    pub selection: Option<String>,
}

/// Emits an event to the POSIX event bus FIFO non-blockingly.
async fn emit_posix_fifo_event(lodge_dir: &PathBuf, event_type: &str, payload: serde_json::Value) {
    let fifo_path = lodge_dir.join(".george").join("ipc").join("event_bus.fifo");
    if !fifo_path.exists() {
        return;
    }

    let ts = chrono_epoch_secs();
    let evt_id = format!("evt_{}_{}", ts, std::process::id());
    let envelope = json!({
        "event_id": evt_id,
        "type": event_type,
        "source": "copilot_gateway",
        "payload": payload,
        "depth": 0,
        "timestamp": ts,
    });

    let line = format!("{}\n", envelope);
    // Write via background shell to guarantee zero blocking on full FIFO
    let fifo_str = fifo_path.to_string_lossy().to_string();
    let _ = Command::new("bash")
        .args([
            "-c",
            "printf '%s' \"$1\" > \"$2\" 2>/dev/null &",
            "--",
            &line,
            &fifo_str,
        ])
        .spawn();
}

pub async fn post_copilot_chat(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CopilotChatPayload>,
) -> impl IntoResponse {
    let file_path = payload.file_path.trim().to_string();
    let instruction = payload.instruction.trim().to_string();

    if instruction.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "status": "error", "message": "Instruction cannot be empty" }))).into_response();
    }

    let file_stem = file_path
        .split('/')
        .last()
        .unwrap_or("file")
        .replace('.', "_");
    let task_id = payload.task_id.unwrap_or_else(|| format!("copilot_{}_{}", file_stem, chrono_epoch_secs()));
    let sess_id = payload.session_id.unwrap_or_else(|| task_id.clone());
    let agent_name = payload.agent.as_deref().unwrap_or("george");

    let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
    let _ = fs::create_dir_all(&sandbox_dir).await;
    let _ = fs::write(sandbox_dir.join(".phase"), "Internal Monologue & Reasoning").await;

    let meta = json!({
        "id": task_id,
        "type": "copilot",
        "file_path": file_path,
        "instruction": instruction,
        "agent": agent_name,
        "started_at": chrono_utc_now(),
    });
    let _ = fs::write(sandbox_dir.join("task_meta.json"), serde_json::to_string_pretty(&meta).unwrap_or_default()).await;

    // Emit event to POSIX FIFO event bus
    emit_posix_fifo_event(&state.lodge_dir, "copilot:task_started", meta.clone()).await;

    let traj_file = sandbox_dir.join("trajectory.log");
    let init_traj = format!(
        "── [AUTONOMIC TASK INITIALIZED: {}] ──\n[FILE TARGET]: {}\n[AGENT PERSONA]: {}\n[INSTRUCTION]: {}\n[PHASE]: Internal Monologue & Reasoning\n── GEORGE INTERNAL REASONING MONOLOGUE ──\n",
        task_id, file_path, agent_name, instruction
    );
    let _ = fs::write(&traj_file, &init_traj).await;

    let user_msg = json!({
        "id": format!("u_{}", chrono_epoch_secs()),
        "role": "user",
        "type": "copilot",
        "task_id": task_id,
        "file_path": file_path,
        "agent": agent_name,
        "content": instruction,
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &user_msg).await;

    // Resolve Persona Instructions from .agents/workflows/<agent>.agent.md if applicable
    let mut persona_prompt = format!(
        "You are {} (specialist persona). You adhere to Blue Lodge POSIX coding standards, OKF graph protocols, and strict non-destructive editing practices.",
        agent_name.to_uppercase()
    );

    let agent_file = state.lodge_dir.join(".agents").join("workflows").join(format!("{}.agent.md", agent_name));
    if agent_file.exists() {
        if let Ok(agent_doc) = fs::read_to_string(&agent_file).await {
            persona_prompt = format!("You are executing under the following agent contract:\n{}\n", agent_doc);
        }
    }

    let sys_prompt = format!(
        "{}\n\
CRITICAL CODE EDITING & DELETION GUARD RULES:\n\
1. DO NOT DELETE EXISTING CODE. Never truncate files or remove surrounding functions unless explicitly instructed to delete them.\n\
2. For surgical updates, output SEARCH/REPLACE blocks formatted like this:\n\
<<<<<<< SEARCH\n\
existing code to replace\n\
=======\n\
updated or commented code\n\
>>>>>>>\n\
3. When commenting code, preserve 100% of existing lines and insert comments/docstrings above functions.\n\
4. If writing the complete file, output the full content from start to finish inside a markdown code fence.\n\
5. Keep explanations direct, technical, and concise (1-2 sentences).",
        persona_prompt
    );

    let selection_ctx = payload.selection.as_ref()
        .filter(|s| !s.trim().is_empty())
        .map(|s| format!("\nUSER SELECTED CODE IN EDITOR:\n```\n{}\n```\n", s))
        .unwrap_or_default();

    let pills_ctx = payload.context_pills.as_ref()
        .filter(|p| !p.is_empty())
        .map(|p| format!("\nATTACHED CONTEXT PILLS: {}\n", p.join(", ")))
        .unwrap_or_default();

    let user_prompt = format!(
        "FILE: {}\n\nCURRENT BUFFER CONTENT:\n```\n{}\n```\n{}{}\nUSER INSTRUCTION: {}",
        file_path,
        payload.file_content,
        selection_ctx,
        pills_ctx,
        instruction
    );

    let payload_body = json!({
        "messages": [
            { "role": "system", "content": sys_prompt },
            { "role": "user", "content": user_prompt }
        ],
        "temperature": 0.4,
        "top_p": 0.95,
        "repeat_penalty": 1.15,
        "max_tokens": 4096,
        "stream": true,
    });

    let mut cmd = Command::new("curl");
    cmd.args([
        "-N", "-s",
        "--max-time", "120",
        "http://127.0.0.1:8080/v1/chat/completions",
        "-H", "Content-Type: application/json",
        "-d", &payload_body.to_string(),
    ]);
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::null());

    let mut reply_text = String::new();
    let mut reasoning_text = String::new();
    let mut aborted = false;

    if let Ok(mut child) = cmd.spawn() {
        if let Some(pid) = child.id() {
            let _ = fs::write(sandbox_dir.join(".pid"), pid.to_string()).await;
        }

        if let Some(stdout_pipe) = child.stdout.take() {
            let mut reader = tokio::io::BufReader::new(stdout_pipe).lines();
            let mut has_switched_to_content = false;
            let mut traj_buffer = String::new();

            while let Ok(Some(line)) = reader.next_line().await {
                if sandbox_dir.join(".abort").exists() {
                    let _ = child.kill().await;
                    aborted = true;
                    break;
                }

                while sandbox_dir.join(".pause_requested").exists() {
                    let _ = fs::write(sandbox_dir.join(".phase"), "PAUSED by Operator").await;
                    tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
                    if sandbox_dir.join(".abort").exists() {
                        let _ = child.kill().await;
                        aborted = true;
                        break;
                    }
                }
                if aborted {
                    break;
                }

                let line = line.trim();
                if !line.starts_with("data: ") {
                    continue;
                }
                let data_str = &line[6..];
                if data_str == "[DONE]" {
                    break;
                }

                if let Ok(val) = serde_json::from_str::<serde_json::Value>(data_str) {
                    if let Some(choices) = val.get("choices").and_then(|c| c.as_array()) {
                        if let Some(delta) = choices.get(0).and_then(|c| c.get("delta")) {
                            if let Some(r_chunk) = delta.get("reasoning_content").and_then(|s| s.as_str()) {
                                if !r_chunk.is_empty() {
                                    reasoning_text.push_str(r_chunk);
                                    traj_buffer.push_str(r_chunk);
                                    if traj_buffer.contains('\n') || traj_buffer.len() >= 60 {
                                        append_to_file(&traj_file, &traj_buffer).await;
                                        traj_buffer.clear();
                                    }
                                }
                            }
                            if let Some(c_chunk) = delta.get("content").and_then(|s| s.as_str()) {
                                if !c_chunk.is_empty() {
                                    if !has_switched_to_content {
                                        has_switched_to_content = true;
                                        if !traj_buffer.is_empty() {
                                            append_to_file(&traj_file, &traj_buffer).await;
                                            traj_buffer.clear();
                                        }
                                        append_to_file(&traj_file, "\n── SYNTHESIZING EDITS & SOLUTION ──\n").await;
                                        let _ = fs::write(sandbox_dir.join(".phase"), "Synthesizing Edits & Solution").await;
                                    }
                                    reply_text.push_str(c_chunk);
                                    traj_buffer.push_str(c_chunk);
                                    if traj_buffer.contains('\n') || traj_buffer.len() >= 60 {
                                        append_to_file(&traj_file, &traj_buffer).await;
                                        traj_buffer.clear();
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !traj_buffer.is_empty() {
                append_to_file(&traj_file, &traj_buffer).await;
            }
        }
        let _ = child.wait().await;
    }

    if aborted || sandbox_dir.join(".abort").exists() {
        append_to_file(&traj_file, "\n── [TASK ABORTED BY OPERATOR] ──\n").await;
        let _ = fs::write(sandbox_dir.join(".phase"), "Aborted").await;
        let _ = fs::write(sandbox_dir.join(".done"), "1").await;
        return Json(json!({
            "status": "aborted",
            "task_id": task_id,
            "session_id": sess_id,
            "reply": "Coding task was aborted by the operator.",
            "explanation": "Operation cancelled.",
            "has_edit": false,
            "proposed_code": null,
        })).into_response();
    }

    append_to_file(&traj_file, "\n── [TASK COMPLETED] ──\n").await;
    let _ = fs::write(sandbox_dir.join(".phase"), "Completed").await;
    let _ = fs::write(sandbox_dir.join(".done"), "1").await;

    if reply_text.is_empty() {
        if !reasoning_text.is_empty() {
            reply_text = reasoning_text.clone();
        } else {
            reply_text = "I have reviewed your request. Here are the recommended adjustments for the active file.".into();
        }
    }

    // Extract proposed code fences or SEARCH/REPLACE blocks
    let text_to_search = if reply_text.contains("```") || reply_text.contains("<<<<<<<") {
        &reply_text
    } else {
        &reasoning_text
    };

    let mut proposed_snippet = None;
    let mut explanation = reply_text.clone();

    if text_to_search.contains("<<<<<<<") {
        // Direct search/replace blocks in text
        proposed_snippet = Some(text_to_search.to_string());
    } else if let Some(start_idx) = text_to_search.find("```") {
        explanation = text_to_search[..start_idx].trim().to_string();
        let after_fence = &text_to_search[start_idx + 3..];
        if let Some(newline_idx) = after_fence.find('\n') {
            let code_body = &after_fence[newline_idx + 1..];
            if let Some(end_idx) = code_body.find("```") {
                proposed_snippet = Some(code_body[..end_idx].trim_end().to_string());
            } else {
                proposed_snippet = Some(code_body.trim_end().to_string());
            }
        }
    }

    // Run surgical patch resolution using lib/tools/copilot_engine.py
    let mut resolved_code = None;
    let mut edit_action = "none".to_string();
    let mut diff_summary = "No changes".to_string();

    if let Some(snippet) = proposed_snippet {
        let orig_tmp = sandbox_dir.join("orig.tmp");
        let prop_tmp = sandbox_dir.join("prop.tmp");
        let sel_tmp = sandbox_dir.join("sel.tmp");

        let _ = fs::write(&orig_tmp, &payload.file_content).await;
        let _ = fs::write(&prop_tmp, &snippet).await;
        if let Some(sel) = &payload.selection {
            let _ = fs::write(&sel_tmp, sel).await;
        }

        let engine_script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
        let mut py_cmd = Command::new("python3");
        py_cmd.args([
            engine_script.to_string_lossy().as_ref(),
            "resolve-patch",
            "--original-file", orig_tmp.to_string_lossy().as_ref(),
            "--proposed-file", prop_tmp.to_string_lossy().as_ref(),
            "--instruction", &instruction,
        ]);

        if payload.selection.is_some() {
            py_cmd.args(["--selection-file", sel_tmp.to_string_lossy().as_ref()]);
        }

        if let Ok(out) = py_cmd.output().await {
            if let Ok(res_json) = serde_json::from_slice::<serde_json::Value>(&out.stdout) {
                if res_json.get("success").and_then(|s| s.as_bool()).unwrap_or(false) {
                    if let Some(rc) = res_json.get("resolved_code").and_then(|s| s.as_str()) {
                        resolved_code = Some(rc.to_string());
                    }
                    if let Some(act) = res_json.get("action").and_then(|s| s.as_str()) {
                        edit_action = act.to_string();
                    }
                    if let Some(exp) = res_json.get("explanation").and_then(|s| s.as_str()) {
                        explanation = format!("{}\n\n[RESOLVER]: {}", explanation, exp);
                    }
                    if let Some(ds) = res_json.get("diff_summary").and_then(|s| s.as_str()) {
                        diff_summary = ds.to_string();
                    }
                } else if res_json.get("action").and_then(|s| s.as_str()) == Some("deletion_guard_blocked") {
                    explanation = format!(
                        "{}\n\n[DELETION GUARD]: {}",
                        explanation,
                        res_json.get("explanation").and_then(|s| s.as_str()).unwrap_or("Truncated snippet blocked to prevent code loss.")
                    );
                }
            }
        }
    }

    let has_edit = resolved_code.is_some();

    // Emit diff staged event
    if has_edit {
        emit_posix_fifo_event(&state.lodge_dir, "copilot:diff_staged", json!({
            "task_id": task_id,
            "file_path": file_path,
            "action": edit_action,
            "diff_summary": diff_summary,
        })).await;
    }

    let assistant_msg = json!({
        "id": format!("a_{}", chrono_epoch_secs()),
        "role": "assistant",
        "type": "copilot",
        "task_id": task_id,
        "file_path": file_path,
        "agent": agent_name,
        "content": reply_text,
        "reasoning": reasoning_text,
        "has_edit": has_edit,
        "action": edit_action,
        "diff_summary": diff_summary,
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &assistant_msg).await;

    Json(json!({
        "status": "ok",
        "task_id": task_id,
        "session_id": sess_id,
        "agent": agent_name,
        "reply": reply_text,
        "reasoning": reasoning_text,
        "explanation": explanation,
        "has_edit": has_edit,
        "action": edit_action,
        "diff_summary": diff_summary,
        "proposed_code": resolved_code,
    })).into_response()
}

pub async fn get_copilot_agents(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let out = Command::new("python3")
        .args([script.to_string_lossy().as_ref(), "list-agents"])
        .output()
        .await;

    match out {
        Ok(o) => {
            let agents: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!([]));
            Json(json!({ "status": "ok", "agents": agents })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn post_copilot_agent_save(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SaveAgentPayload>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let rules_json = serde_json::to_string(&payload.rules.unwrap_or_default()).unwrap_or_else(|_| "[]".into());
    let wf_json = serde_json::to_string(&payload.workflow_steps.unwrap_or_default()).unwrap_or_else(|_| "[]".into());

    let out = Command::new("python3")
        .args([
            script.to_string_lossy().as_ref(),
            "save-agent",
            "--name", &payload.name,
            "--desc", &payload.description,
            "--rules", &rules_json,
            "--workflow", &wf_json,
        ])
        .output()
        .await;

    match out {
        Ok(o) => {
            let res: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!({ "status": "error" }));
            Json(res).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn get_copilot_workflows(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let out = Command::new("python3")
        .args([script.to_string_lossy().as_ref(), "list-workflows"])
        .output()
        .await;

    match out {
        Ok(o) => {
            let workflows: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!([]));
            Json(json!({ "status": "ok", "workflows": workflows })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn post_copilot_workflow_save(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SaveWorkflowPayload>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let steps_json = serde_json::to_string(&payload.steps.unwrap_or_default()).unwrap_or_else(|_| "[]".into());

    let out = Command::new("python3")
        .args([
            script.to_string_lossy().as_ref(),
            "save-workflow",
            "--name", &payload.name,
            "--desc", &payload.description,
            "--steps", &steps_json,
            "--objective", payload.objective.as_deref().unwrap_or(""),
        ])
        .output()
        .await;

    match out {
        Ok(o) => {
            let res: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!({ "status": "error" }));
            Json(res).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn get_copilot_tools(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let out = Command::new("python3")
        .args([script.to_string_lossy().as_ref(), "list-tools"])
        .output()
        .await;

    match out {
        Ok(o) => {
            let tools: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!([]));
            Json(json!({ "status": "ok", "tools": tools })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn post_copilot_tool_build(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<BuildToolPayload>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let lang = payload.language.unwrap_or_else(|| "bash".into());
    let sub = payload.subsystem.unwrap_or_else(|| "tools".into());
    let desc = payload.description.unwrap_or_else(|| "Custom George tool".into());
    let code = payload.code_content.unwrap_or_default();

    let out = Command::new("python3")
        .args([
            script.to_string_lossy().as_ref(),
            "build-tool",
            "--name", &payload.name,
            "--lang", &lang,
            "--subsystem", &sub,
            "--desc", &desc,
            "--code", &code,
        ])
        .output()
        .await;

    match out {
        Ok(o) => {
            let res: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!({ "status": "error" }));
            Json(res).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn post_copilot_tool_test(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TestToolPayload>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let args_json = serde_json::to_string(&payload.args.unwrap_or_default()).unwrap_or_else(|_| "[]".into());
    let args = vec![
        script.to_string_lossy().to_string(),
        "test-tool".into(),
        "--name".into(),
        payload.name,
        "--args-json".into(),
        args_json,
    ];

    let out = Command::new("python3")
        .args(&args)
        .output()
        .await;

    match out {
        Ok(o) => {
            let res: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!({ "status": "error" }));
            Json(res).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn get_copilot_rules(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let out = Command::new("python3")
        .args([script.to_string_lossy().as_ref(), "list-rules"])
        .output()
        .await;

    match out {
        Ok(o) => {
            let rules: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_else(|_| json!([]));
            Json(json!({ "status": "ok", "rules": rules })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn post_copilot_comment(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CommentCodePayload>,
) -> impl IntoResponse {
    let sandbox = state.lodge_dir.join(".sandboxes").join(format!("comment_{}", chrono_epoch_secs()));
    let _ = fs::create_dir_all(&sandbox).await;
    let target_tmp = sandbox.join("target.tmp");
    let _ = fs::write(&target_tmp, &payload.file_content).await;

    let script = state.lodge_dir.join("lib").join("tools").join("copilot_engine.py");
    let out = Command::new("python3")
        .args([
            script.to_string_lossy().as_ref(),
            "safe-comment",
            "--file", target_tmp.to_string_lossy().as_ref(),
            "--instruction", payload.instruction.as_deref().unwrap_or("Add comments"),
        ])
        .output()
        .await;

    match out {
        Ok(o) => {
            let commented = String::from_utf8_lossy(&o.stdout).to_string();
            let _ = fs::remove_dir_all(&sandbox).await;
            Json(json!({
                "status": "ok",
                "file_path": payload.file_path,
                "has_edit": true,
                "action": "safe_commenting_guard",
                "proposed_code": commented,
                "diff_summary": "Injected function & inline comments with zero deletions",
                "explanation": "Safely commented functions and routines while preserving 100% of executable logic."
            })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}
