use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::*;
use crate::state::AppState;

#[derive(Serialize, Deserialize)]
#[allow(dead_code)]
pub struct TaskItem {
    pub id: String,
    pub name: String,
    pub phase: String,
    pub done: bool,
    pub paused: bool,
    pub pid_alive: bool,
    pub pid: Option<u32>,
    pub mtime_secs: u64,
    pub is_subagent: bool,
    pub subagent_tier: String,
    pub subagent_obj: String,
    pub meta_cmd: String,
    pub meta_type: String,
    pub task_type: String,
    pub last_lines: Vec<String>,
}

#[derive(Deserialize)]
pub struct TaskInputPayload {
    pub input: String,
}

#[derive(Deserialize, Debug)]
pub struct TaskInjectPayload {
    pub message: Option<String>,
    pub guidance: Option<String>,
    pub input: Option<String>,
    pub priority: Option<u8>,
}

async fn resolve_task_dir(state: &AppState, clean_id: &str) -> std::path::PathBuf {
    crate::helpers::resolve_task_dir(&state.lodge_dir, &state.george_dir, clean_id).await
}

fn is_system_cron(name: &str) -> bool {
    let base = name.strip_prefix("cron_").unwrap_or(name);
    matches!(
        base,
        "sentinel_sweep"
            | "discord_sweep"
            | "pr_sweep"
            | "issue_sweep"
            | "email_sweep"
            | "x_social_sweep"
            | "mastodon_sweep"
            | "probe_local_inference_en"
            | "research_sweep"
            | "blog_sweep"
    ) || base.ends_with("_sweep")
}

fn is_user_cron(name: &str) -> bool {
    if is_system_cron(name) {
        return false;
    }
    let base = name.strip_prefix("cron_").unwrap_or(name);
    name.starts_with("cron_") || base.ends_with("_job")
}

fn clean_task_objective(raw: &str) -> String {
    let unescaped = raw.replace("\\n", "\n").replace("\\r", "\r");
    let s = unescaped.trim();
    if s.is_empty() {
        return String::new();
    }
    if let Some(pos) = s.find("[Current Inbound Message from") {
        let after = &s[pos..];
        if let Some(msg_start) = after.find("]:") {
            let msg_body = &after[msg_start + 2..];
            let clean = if let Some(end_pos) = msg_body.find("\n=") {
                &msg_body[..end_pos]
            } else if let Some(end_pos) = msg_body.find("===") {
                &msg_body[..end_pos]
            } else {
                msg_body
            };
            let cleaned = clean.split_whitespace().collect::<Vec<_>>().join(" ");
            if !cleaned.is_empty() {
                return cleaned;
            }
        }
    }
    if let Some(pos) = s.find("[ACTIVE PRIMARY OBJECTIVE - EXECUTE THIS NOW]:") {
        let after = &s[pos + 46..];
        let clean = if let Some(end_pos) = after.find("\n=") {
            &after[..end_pos]
        } else if let Some(end_pos) = after.find("===") {
            &after[..end_pos]
        } else {
            after
        };
        let cleaned = clean.split_whitespace().collect::<Vec<_>>().join(" ");
        if !cleaned.is_empty() {
            return cleaned;
        }
    }
    let clean = s.trim_start_matches(|c| c == '=' || c == '-' || c == '*' || c == ' ' || c == '\n' || c == '\r')
                 .trim_end_matches(|c| c == '=' || c == '-' || c == '*' || c == ' ' || c == '\n' || c == '\r');
    clean.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn extract_text_content(val: Option<&serde_json::Value>) -> String {
    let Some(v) = val else { return String::new(); };
    if let Some(s) = v.as_str() {
        return s.to_string();
    }
    if let Some(arr) = v.as_array() {
        let mut combined = String::new();
        for item in arr {
            if let Some(text) = item.get("text").and_then(|t| t.as_str()) {
                if !combined.is_empty() { combined.push('\n'); }
                combined.push_str(text);
            }
        }
        return combined;
    }
    String::new()
}

fn format_messages_as_trajectory(messages_val: &serde_json::Value) -> String {
    let mut out = String::new();
    let msgs = if let Some(arr) = messages_val.as_array() {
        arr
    } else if let Some(arr) = messages_val.get("messages").and_then(|m| m.as_array()) {
        arr
    } else {
        return out;
    };

    let mut turn = 0;
    for m in msgs {
        let role = m.get("role").and_then(|r| r.as_str()).unwrap_or("");
        let raw_content = extract_text_content(m.get("content"));
        let clean_content = raw_content.trim();

        if role == "system" {
            continue;
        } else if role == "user" {
            if turn == 0 {
                out.push_str("PRIMARY OBJECTIVE:\n");
                out.push_str(clean_content);
                out.push_str("\n\n");
            } else {
                out.push_str("\n── User / Guidance ──\n");
                out.push_str(clean_content);
                out.push_str("\n\n");
            }
        } else if role == "assistant" {
            turn += 1;
            out.push_str(&format!("── Turn {} ──\n", turn));
            if !clean_content.is_empty() {
                out.push_str(clean_content);
                out.push('\n');
            }
            if let Some(tcs) = m.get("tool_calls").and_then(|tc| tc.as_array()) {
                for tc in tcs {
                    let fn_name = tc.get("function")
                        .and_then(|f| f.get("name"))
                        .and_then(|n| n.as_str())
                        .unwrap_or("tool");
                    let fn_args = tc.get("function")
                        .and_then(|f| f.get("arguments"))
                        .and_then(|a| a.as_str())
                        .unwrap_or("{}");
                    out.push_str(&format!("Tool Call: {} ({})\n", fn_name, fn_args));
                }
            }
            out.push('\n');
        } else if role == "tool" {
            out.push_str("Observation: ");
            out.push_str(clean_content);
            out.push_str("\n\n");
        }
    }

    out
}

async fn process_task_dir(
    p: &std::path::Path,
    name: &str,
    state: &Arc<AppState>,
    now: u64,
) -> Option<serde_json::Value> {
    if !p.is_dir() || name.starts_with('.') || name == "transcripts" {
        return None;
    }

    let phase_file = p.join(".phase");
    let raw_phase = fs::read_to_string(&phase_file)
        .await
        .unwrap_or_else(|_| "Active".into());
    let mut phase = raw_phase.trim().to_string();
    let mut active_step = String::new();

    if let Some(step_pos) = phase.find("Step ") {
        active_step = phase[step_pos..].trim().to_string();
        if let Some(colon_pos) = phase[..step_pos].rfind(':') {
            phase = phase[..colon_pos].trim().to_string();
        }
    }

    let mut done = p.join(".done").exists();
    let paused = p.join(".pause_requested").exists();

    let pid_file = p.join(".pid");
    let has_pid = pid_file.exists();
    let cron_pid = read_pid_from_file(&state.george_dir.join(".cron.pid"));
    let my_pid = std::process::id();
    let is_daemon_pid = |pid: u32| -> bool {
        Some(pid) == cron_pid || pid == my_pid
    };

    let raw_pid = read_pid_from_file(&pid_file);
    let mut pid_alive = match raw_pid {
        Some(pid) if !is_daemon_pid(pid) => is_pid_alive(pid),
        _ => false,
    };
    let mut pid_val = raw_pid.filter(|&pid| !is_daemon_pid(pid));
    let is_subagent = name.starts_with("sub_");

    if name.starts_with("discord_") {
        let rest = name.strip_prefix("discord_").unwrap_or("");
        let chan_id = rest.split('_').next().unwrap_or(rest);
        let session_pid_file = state
            .george_dir
            .join("discord_sessions")
            .join(format!("session_{}.pid", chan_id));
        let d_raw = state
            .george_dir
            .join("discord_sessions")
            .join(name)
            .join("raw_react.log");
        let is_current = if let Ok(tmeta) = fs::metadata(&d_raw).await {
            if let Ok(tm) = tmeta.modified() {
                if let Ok(dur) = tm.duration_since(std::time::UNIX_EPOCH) {
                    now.saturating_sub(dur.as_secs()) < 180
                } else {
                    false
                }
            } else {
                false
            }
        } else {
            false
        };

        if !done && is_current && session_pid_file.exists() {
            if let Some(spid) = read_pid_from_file(&session_pid_file) {
                if !is_daemon_pid(spid) && is_pid_alive(spid) {
                    pid_alive = true;
                    done = false;
                    pid_val = Some(spid);
                }
            }
        } else if !is_current && !pid_alive {
            done = true;
        }
    }

    if (has_pid && !pid_alive) || (!has_pid && !is_subagent) {
        done = true;
    }

    let phase_lower = phase.to_lowercase();
    if phase_lower.contains("complete")
        || phase_lower.contains("done")
        || phase_lower.contains("culled")
        || phase_lower.contains("orphaned")
        || phase_lower.contains("stopped")
        || phase_lower.contains("failed")
        || phase_lower.contains("paused_blocked")
    {
        done = true;
    }

    let mut subagent_obj = String::new();
    let mut subagent_tier = String::new();

    if is_subagent {
        let subagents_file = state.george_dir.join("subagents.json");
        if let Ok(reg_str) = fs::read_to_string(&subagents_file).await {
            if let Ok(entries) = serde_json::from_str::<Vec<serde_json::Value>>(&reg_str) {
                if let Some(entry) = entries.iter().find(|e| e.get("id").and_then(|v| v.as_str()) == Some(name)) {
                    if let Some(t) = entry.get("tier").and_then(|v| v.as_str()) {
                        subagent_tier = t.to_string();
                    } else if let Some(t_num) = entry.get("tier").and_then(|v| v.as_i64()) {
                        subagent_tier = t_num.to_string();
                    }
                    if let Some(obj) = entry.get("objective").and_then(|v| v.as_str()) {
                        subagent_obj = obj.to_string();
                    }
                    let reg_status = entry.get("status").and_then(|v| v.as_str()).unwrap_or("");
                    let reg_status_upper = reg_status.to_uppercase();
                    if !done && reg_status_upper == "RUNNING" {
                        if let Some(reg_pid) = entry.get("pid").and_then(|v| v.as_i64()) {
                            if reg_pid > 0 && is_pid_alive(reg_pid as u32) {
                                pid_alive = true;
                                done = false;
                            } else {
                                done = true;
                                pid_alive = false;
                            }
                        } else {
                            done = true;
                            pid_alive = false;
                        }
                    } else {
                        done = true;
                        pid_alive = false;
                    }
                }
            }
        }
    }

    if done {
        pid_alive = false;
    }

    let mut mtime_secs = fs::metadata(p).await.ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);

    for check_file in &["trajectory.log", "raw_react.log", "messages.json", "scratchpad.md", ".phase", ".done"] {
        let c_path = p.join(check_file);
        if let Ok(tmeta) = fs::metadata(&c_path).await {
            if let Ok(tm) = tmeta.modified() {
                if let Ok(dur) = tm.duration_since(std::time::UNIX_EPOCH) {
                    mtime_secs = mtime_secs.max(dur.as_secs());
                }
            }
        }
    }

    let discord_name = if name.starts_with("discord_") {
        Some(name.to_string())
    } else if let Some(idx) = name.find("discord_") {
        let d_part = &name[idx..];
        let parts: Vec<&str> = d_part.split('_').collect();
        if parts.len() >= 4 {
            Some(format!("{}_{}_{}", parts[0], parts[1], parts[2]))
        } else {
            Some(d_part.to_string())
        }
    } else {
        None
    };

    if let Some(d_name) = discord_name {
        let d_raw = state.george_dir.join("discord_sessions").join(&d_name).join("raw_react.log");
        if let Ok(tmeta) = fs::metadata(&d_raw).await {
            if let Ok(tm) = tmeta.modified() {
                if let Ok(dur) = tm.duration_since(std::time::UNIX_EPOCH) {
                    mtime_secs = mtime_secs.max(dur.as_secs());
                }
            }
        }
    }

    // Completed or aborted sandboxes/workspaces remain in the Autonomic Task Bay for 45s for operator inspection
    if (done && now.saturating_sub(mtime_secs) > 45)
        || (!pid_alive && now.saturating_sub(mtime_secs) > 45) {
        return None;
    }

    let meta_file = p.join("task_meta.json");
    let mut meta_cmd = String::new();
    let mut meta_type = String::new();
    let mut parent_task_id: Option<String> = None;
    let mut parent_pid: Option<u32> = None;
    if let Ok(meta_str) = fs::read_to_string(&meta_file).await {
        if let Ok(meta_json) = serde_json::from_str::<serde_json::Value>(&meta_str) {
            if let Some(cmd) = meta_json.get("command").or_else(|| meta_json.get("prompt")).or_else(|| meta_json.get("objective")).and_then(|v| v.as_str()) {
                meta_cmd = cmd.to_string();
            }
            if let Some(t) = meta_json.get("task_type").or_else(|| meta_json.get("type")).and_then(|v| v.as_str()) {
                meta_type = t.to_string();
            }
            if let Some(pid_str) = meta_json.get("parent_task_id").and_then(|v| v.as_str()) {
                if !pid_str.is_empty() {
                    parent_task_id = Some(pid_str.to_string());
                }
            }
            if let Some(ppid) = meta_json.get("parent_pid").and_then(|v| v.as_u64()) {
                if ppid > 0 {
                    parent_pid = Some(ppid as u32);
                }
            }
        }
    }

    if parent_task_id.is_none() && name.starts_with("sub_") {
        let rest = &name[4..];
        if let Some(last_underscore) = rest.rfind('_') {
            let possible_parent = &rest[..last_underscore];
            if !possible_parent.is_empty() {
                parent_task_id = Some(possible_parent.to_string());
            }
        }
    }

    if meta_cmd.is_empty() {
        if !subagent_obj.is_empty() {
            meta_cmd = subagent_obj.clone();
        } else if name.starts_with("discord_") {
            meta_cmd = format!("Discord Task: {}", name);
        } else if name.starts_with("research_") {
            meta_cmd = format!("Research Task: {}", name);
        } else if name.starts_with("cron_") {
            meta_cmd = format!("Cron Task: {}", name);
        }
    }

    let mut last_lines = Vec::new();
    if let Some(t_log) = find_trajectory_log(&p.to_path_buf()).await {
        if let Ok(content) = fs::read_to_string(&t_log).await {
            for l in content.lines().rev().take(15) {
                let trimmed = l.trim();
                if !trimmed.is_empty() {
                    last_lines.push(strip_ansi(trimmed));
                }
            }
            last_lines.reverse();
        }
    }

    let task_type = if !meta_type.is_empty() {
        meta_type
    } else if is_subagent {
        "subagent".into()
    } else if name.starts_with("cron_") {
        "cron".into()
    } else if name.starts_with("research_") {
        "research".into()
    } else if name.starts_with("discord_") {
        "discord".into()
    } else {
        "interactive".into()
    };

    let msgs_path = p.join("messages.json");
    let (context_tokens, compaction_tokens, context_limit, compaction_pct) = if msgs_path.exists() {
        let msg_len = fs::metadata(&msgs_path).await.map(|m| m.len()).unwrap_or(0);
        let ctx = (msg_len * 10 / 35) + 4000;
        let comp = 83558u64;
        let limit = 98304u64;
        let pct = ((ctx as f64 / comp as f64) * 100.0).min(100.0) as u32;
        (ctx, comp, limit, pct)
    } else {
        (0u64, 83558u64, 98304u64, 0u32)
    };

    let clean_summary = clean_task_objective(&meta_cmd);
    let final_summary = if !clean_summary.is_empty() {
        clean_summary
    } else if !meta_cmd.is_empty() {
        meta_cmd.clone()
    } else {
        name.to_string()
    };

    Some(json!({
        "id": name,
        "name": name,
        "phase": phase.trim(),
        "active_step": active_step,
        "done": done,
        "paused": paused,
        "pid_alive": pid_alive,
        "pid": pid_val,
        "path": p.to_string_lossy().to_string(),
        "mtime_secs": mtime_secs,
        "is_subagent": is_subagent,
        "subagent_tier": subagent_tier,
        "subagent_obj": subagent_obj,
        "meta_cmd": meta_cmd,
        "task_type": task_type,
        "type": task_type,
        "summary": final_summary,
        "last_lines": last_lines,
        "parent_task_id": parent_task_id,
        "parent_pid": parent_pid,
        "context_tokens": context_tokens,
        "compaction_tokens": compaction_tokens,
        "context_limit": context_limit,
        "compaction_pct": compaction_pct,
    }))
}

pub async fn get_tasks(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut tasks = Vec::new();
    let mut sys_cron_tasks = Vec::new();
    let mut usr_cron_tasks = Vec::new();
    let now = chrono_epoch_secs();

    // 1. Check sandboxes (.sandboxes/*)
    let sandboxes_dir = state.lodge_dir.join(".sandboxes");
    if let Ok(mut entries) = fs::read_dir(&sandboxes_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if is_system_cron(&name) {
                if let Some(task_val) = process_task_dir(&p, &name, &state, now).await {
                    sys_cron_tasks.push(task_val);
                } else {
                    let phase = fs::read_to_string(p.join(".phase")).await.unwrap_or_else(|_| "Completed".into());
                    let base_name = name.strip_prefix("cron_").unwrap_or(&name);
                    sys_cron_tasks.push(json!({
                        "id": name,
                        "name": name,
                        "job_name": base_name,
                        "phase": phase.trim(),
                        "done": true,
                        "pid_alive": false,
                    }));
                }
            } else if is_user_cron(&name) {
                if let Some(task_val) = process_task_dir(&p, &name, &state, now).await {
                    usr_cron_tasks.push(task_val);
                } else {
                    let phase = fs::read_to_string(p.join(".phase")).await.unwrap_or_else(|_| "Completed".into());
                    let base_name = name.strip_prefix("cron_").unwrap_or(&name);
                    usr_cron_tasks.push(json!({
                        "id": name,
                        "name": name,
                        "job_name": base_name,
                        "phase": phase.trim(),
                        "done": true,
                        "pid_alive": false,
                    }));
                }
            } else if let Some(task_val) = process_task_dir(&p, &name, &state, now).await {
                tasks.push(task_val);
            }
        }
    }

    // 2. Check active & recent workspaces (.george/workspaces/*)
    let workspaces_dir = state.george_dir.join("workspaces");
    if let Ok(mut entries) = fs::read_dir(&workspaces_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if tasks.iter().any(|t| t.get("id").and_then(|v| v.as_str()) == Some(&name)) || is_system_cron(&name) || is_user_cron(&name) {
                continue;
            }
            if let Some(task_val) = process_task_dir(&p, &name, &state, now).await {
                tasks.push(task_val);
            }
        }
    }

    // 3. Check active telemetry descriptors (.george/telemetry/active/*.json)
    let telem_dir = state.george_dir.join("telemetry").join("active");
    if let Ok(mut entries) = fs::read_dir(&telem_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) == Some("json") {
                if let Ok(content) = fs::read_to_string(&p).await {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                        let tid = val.get("task_id").and_then(|v| v.as_str()).unwrap_or("");
                        if tid.is_empty() {
                            continue;
                        }
                        let tpid = val.get("pid").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                        let alive = if tpid > 0 { is_pid_alive(tpid) } else { false };
                        let status = val.get("status").and_then(|v| v.as_str()).unwrap_or("RUNNING");
                        let turn = val.get("turn").and_then(|v| v.as_u64()).unwrap_or(1);
                        let max_turns = val.get("max_turns").and_then(|v| v.as_u64()).unwrap_or(200);
                        let last_tool = val.get("last_tool").and_then(|v| v.as_str()).unwrap_or("");
                        let t_type = val.get("type").and_then(|v| v.as_str()).unwrap_or("react");

                        let parent_task_id = val.get("parent_task_id").and_then(|v| v.as_str()).map(|s| s.to_string());
                        let parent_pid = val.get("parent_pid").and_then(|v| v.as_u64()).map(|v| v as u32);
                        let context_tokens = val.get("context_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
                        let compaction_tokens = val.get("compaction_tokens").and_then(|v| v.as_u64()).unwrap_or(83558);
                        let context_limit = val.get("context_limit").and_then(|v| v.as_u64()).unwrap_or(98304);
                        let compaction_pct = val.get("compaction_pct").and_then(|v| v.as_u64()).unwrap_or_else(|| {
                            if compaction_tokens > 0 && context_tokens > 0 {
                                ((context_tokens as f64 / compaction_tokens as f64) * 100.0).min(100.0) as u64
                            } else {
                                0
                            }
                        }) as u32;

                        // If already in tasks, update with active turn and tool if running
                        if let Some(existing) = tasks.iter_mut().find(|t| t.get("id").and_then(|v| v.as_str()) == Some(tid)) {
                            if alive && status == "RUNNING" {
                                if let Some(obj) = existing.as_object_mut() {
                                    obj.insert("pid_alive".into(), json!(true));
                                    obj.insert("done".into(), json!(false));
                                    if let Some(active_tools) = val.get("active_tools") {
                                        obj.insert("active_tools".into(), active_tools.clone());
                                    }
                                    if !last_tool.is_empty() {
                                        obj.insert("phase".into(), json!(format!("Turn {}/{}: [{}]", turn, max_turns, last_tool)));
                                    } else {
                                        obj.insert("phase".into(), json!(format!("Turn {}/{}", turn, max_turns)));
                                    }
                                    if parent_task_id.is_some() && obj.get("parent_task_id").and_then(|v| v.as_str()).is_none() {
                                        obj.insert("parent_task_id".into(), json!(parent_task_id));
                                    }
                                    if parent_pid.is_some() && obj.get("parent_pid").and_then(|v| v.as_u64()).is_none() {
                                        obj.insert("parent_pid".into(), json!(parent_pid));
                                    }
                                    if context_tokens > 0 {
                                        obj.insert("context_tokens".into(), json!(context_tokens));
                                        obj.insert("compaction_tokens".into(), json!(compaction_tokens));
                                        obj.insert("context_limit".into(), json!(context_limit));
                                        obj.insert("compaction_pct".into(), json!(compaction_pct));
                                    }
                                }
                            }
                        } else if alive && status == "RUNNING" {
                            // Register newly observed live telemetry task
                            let mut last_lines = Vec::new();
                            let sb_cand = crate::helpers::resolve_task_dir(&state.lodge_dir, &state.george_dir, tid).await;
                            let mut ws_traj = find_trajectory_log(&sb_cand).await;
                            if ws_traj.is_none() {
                                if let Some(l_str) = val.get("log_file").and_then(|v| v.as_str()) {
                                    if !l_str.is_empty() {
                                        let p = PathBuf::from(l_str);
                                        if p.exists() {
                                            ws_traj = Some(p);
                                        }
                                    }
                                }
                            }
                            if let Some(ref t_file) = ws_traj {
                                if let Ok(content) = fs::read_to_string(t_file).await {
                                    for l in content.lines().rev().take(15) {
                                        let trimmed = l.trim();
                                        if !trimmed.is_empty() {
                                            last_lines.push(strip_ansi(trimmed));
                                        }
                                    }
                                    last_lines.reverse();
                                }
                            }
                            let phase = if !last_tool.is_empty() {
                                format!("Turn {}/{}: [{}]", turn, max_turns, last_tool)
                            } else {
                                format!("Turn {}/{}", turn, max_turns)
                            };
                            let ws_phase = sb_cand.join(".phase");
                            let active_step = if let Ok(ph_content) = fs::read_to_string(&ws_phase).await {
                                if let Some(step_pos) = ph_content.find("Step ") {
                                    ph_content[step_pos..].trim().to_string()
                                } else {
                                    String::new()
                                }
                            } else {
                                String::new()
                            };

                            let mut meta_objective = String::new();
                            let run_cand = state.george_dir.join("runs").join(tid).join("run.json");
                            if let Ok(rc) = fs::read_to_string(&run_cand).await {
                                if let Ok(r_val) = serde_json::from_str::<serde_json::Value>(&rc) {
                                    if let Some(g) = r_val.get("goal").and_then(|v| v.as_str()) {
                                        meta_objective = g.to_string();
                                    }
                                }
                            }
                            if meta_objective.is_empty() {
                                let meta_file = sb_cand.join("task_meta.json");
                                if let Ok(mc) = fs::read_to_string(&meta_file).await {
                                    if let Ok(m_val) = serde_json::from_str::<serde_json::Value>(&mc) {
                                        if let Some(obj) = m_val.get("objective").or_else(|| m_val.get("command")).and_then(|v| v.as_str()) {
                                            meta_objective = obj.to_string();
                                        }
                                    }
                                }
                            }
                            let clean_summary = if !meta_objective.is_empty() {
                                clean_task_objective(&meta_objective)
                            } else {
                                clean_task_objective(tid)
                            };
                            let final_summary = if !clean_summary.is_empty() { clean_summary } else { format!("Autonomic Task: {}", tid) };
                            tasks.push(json!({
                                "id": tid,
                                "name": tid,
                                "phase": phase,
                                "active_step": active_step,
                                "done": false,
                                "paused": false,
                                "pid_alive": true,
                                "pid": if tpid > 0 { Some(tpid) } else { None },
                                "mtime_secs": now,
                                "is_subagent": false,
                                "subagent_tier": "1",
                                "subagent_obj": "",
                                "meta_cmd": format!("Autonomic Task: {}", tid),
                                "summary": final_summary,
                                "task_type": t_type,
                                "last_lines": last_lines,
                                "parent_task_id": parent_task_id,
                                "parent_pid": parent_pid,
                                "context_tokens": context_tokens,
                                "compaction_tokens": compaction_tokens,
                                "context_limit": context_limit,
                                "compaction_pct": compaction_pct,
                                "active_tools": val.get("active_tools").cloned().unwrap_or(json!({})),
                            }));
                        }
                    }
                }
            }
        }
    }

    // 4. Build single unified SYS Cron Sentinels Card
    let cron_pid_file = state.george_dir.join(".cron.pid");
    let cron_daemon_pid = read_pid_from_file(&cron_pid_file);
    let cron_daemon_alive = cron_daemon_pid.map_or(false, is_pid_alive);

    let sys_job_defs = [
        ("sentinel_sweep", "Sentinel Sweep"),
        ("discord_sweep", "Discord Sweep"),
        ("pr_sweep", "PR Sweep"),
        ("issue_sweep", "Issue Sweep"),
        ("email_sweep", "Email Sweep"),
        ("x_social_sweep", "X/Twitter Sweep"),
        ("mastodon_sweep", "Mastodon Sweep"),
        ("probe_local_inference_en", "Inference Probe"),
    ];

    let cron_state_file = state.george_dir.join("cron_state.json");
    let cron_state_json: Option<serde_json::Value> = if let Ok(s) = fs::read_to_string(&cron_state_file).await {
        serde_json::from_str(&s).ok()
    } else {
        None
    };

    let mut cron_jobs_summary = Vec::new();
    let mut any_running_phase = None;
    let mut latest_sys_mtime = 0u64;

    for (job_id, label) in &sys_job_defs {
        let task_id = format!("cron_{}", job_id);
        let task_val = sys_cron_tasks.iter().find(|t| {
            t.get("id").and_then(|v| v.as_str()) == Some(&task_id)
                || t.get("job_name").and_then(|v| v.as_str()) == Some(job_id)
        });

        let mut phase = "Completed".to_string();
        let mut is_active = false;
        let mut last_run = 0u64;
        let mut exit_code = 0i64;

        if let Some(t) = task_val {
            if let Some(ph) = t.get("phase").and_then(|v| v.as_str()) {
                phase = ph.to_string();
            }
            if let Some(alive) = t.get("pid_alive").and_then(|v| v.as_bool()) {
                if alive {
                    is_active = true;
                    any_running_phase = Some(format!("{}: {}", label, phase));
                }
            }
            if let Some(mt) = t.get("mtime_secs").and_then(|v| v.as_u64()) {
                latest_sys_mtime = latest_sys_mtime.max(mt);
            }
        }

        if let Some(ref cs) = cron_state_json {
            if let Some(job_obj) = cs.get("jobs").and_then(|j| j.get(job_id)) {
                if let Some(lr) = job_obj.get("last_run").and_then(|v| v.as_u64()) {
                    last_run = lr;
                    latest_sys_mtime = latest_sys_mtime.max(lr);
                }
                if let Some(ec) = job_obj.get("exit_code").and_then(|v| v.as_i64()) {
                    exit_code = ec;
                }
            }
        }

        cron_jobs_summary.push(json!({
            "id": job_id,
            "label": label,
            "phase": phase,
            "active": is_active,
            "last_run": last_run,
            "exit_code": exit_code,
        }));
    }

    let overall_phase = if let Some(r_phase) = any_running_phase {
        r_phase
    } else if cron_daemon_alive {
        format!("Daemon Active ({} Sweeps)", sys_job_defs.len())
    } else {
        "Daemon Inactive".to_string()
    };

    let mut cron_last_lines = Vec::new();
    let cron_log_path = state.george_dir.join("cron.log");
    if let Ok(content) = fs::read_to_string(&cron_log_path).await {
        for l in content.lines().rev().take(20) {
            let trimmed = l.trim();
            if !trimmed.is_empty() {
                cron_last_lines.push(strip_ansi(trimmed));
            }
        }
        cron_last_lines.reverse();
    }

    tasks.push(json!({
        "id": "sys_cron_sentinels",
        "name": "sys_cron_sentinels",
        "task_type": "sys_cron",
        "type": "sys_cron",
        "phase": overall_phase,
        "done": false,
        "paused": false,
        "pid_alive": cron_daemon_alive,
        "pid": cron_daemon_pid,
        "mtime_secs": latest_sys_mtime,
        "is_subagent": false,
        "subagent_tier": "sys",
        "meta_cmd": "SYS Cron Daemon & Sweeps",
        "summary": format!("SYS Cron: Autonomic Sweeps ({} Active)", sys_job_defs.len()),
        "cron_jobs": cron_jobs_summary,
    }));

    // 4a. Build single unified USR Cron Sentinels Card
    let mut usr_job_defs = Vec::new();
    let cron_jobs_dir = state.george_dir.join("cron_jobs");
    if let Ok(mut entries) = fs::read_dir(&cron_jobs_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("sh") {
                let fname = entry.file_name().to_string_lossy().to_string();
                let job_id = fname.strip_suffix(".sh").unwrap_or(&fname).to_string();
                if is_system_cron(&job_id) {
                    continue;
                }
                let mut desc = job_id.replace('_', " ");
                let mut interval = 60u64;
                let mut enabled = true;
                if let Ok(content) = fs::read_to_string(&path).await {
                    for line in content.lines().take(15) {
                        let trimmed = line.trim();
                        if let Some(d) = trimmed.strip_prefix("# DESC:") {
                            desc = d.trim().to_string();
                        } else if let Some(iv) = trimmed.strip_prefix("# INTERVAL:") {
                            if let Ok(secs) = iv.trim().parse::<u64>() {
                                interval = secs;
                            }
                        } else if let Some(en) = trimmed.strip_prefix("# ENABLED:") {
                            enabled = en.trim() != "0" && en.trim().to_lowercase() != "false";
                        }
                    }
                }
                let mut label_parts = Vec::new();
                for w in job_id.split('_') {
                    if !w.is_empty() {
                        let mut chars = w.chars();
                        if let Some(first) = chars.next() {
                            label_parts.push(format!("{}{}", first.to_uppercase(), chars.as_str()));
                        }
                    }
                }
                let label = if label_parts.is_empty() { job_id.clone() } else { label_parts.join(" ") };
                usr_job_defs.push((job_id, label, desc, interval, enabled));
            }
        }
    }
    usr_job_defs.sort_by(|a, b| a.0.cmp(&b.0));

    let mut usr_cron_jobs_summary = Vec::new();
    let mut any_usr_running_phase = None;
    let mut latest_usr_mtime = 0u64;

    for (job_id, label, desc, interval, enabled) in &usr_job_defs {
        let task_id = format!("cron_{}", job_id);
        let task_val = usr_cron_tasks.iter().find(|t| {
            t.get("id").and_then(|v| v.as_str()) == Some(&task_id)
                || t.get("job_name").and_then(|v| v.as_str()) == Some(job_id)
        });

        let mut phase = "Completed".to_string();
        let mut is_active = false;
        let mut last_run = 0u64;
        let mut exit_code = 0i64;

        if let Some(t) = task_val {
            if let Some(ph) = t.get("phase").and_then(|v| v.as_str()) {
                phase = ph.to_string();
            }
            if let Some(alive) = t.get("pid_alive").and_then(|v| v.as_bool()) {
                if alive {
                    is_active = true;
                    any_usr_running_phase = Some(format!("{}: {}", label, phase));
                }
            }
            if let Some(mt) = t.get("mtime_secs").and_then(|v| v.as_u64()) {
                latest_usr_mtime = latest_usr_mtime.max(mt);
            }
        }

        // Also check if .george/cron_jobs/.${job_id}.pid is alive
        let job_pid_file = state.george_dir.join("cron_jobs").join(format!(".{}.pid", job_id));
        if let Some(jpid) = read_pid_from_file(&job_pid_file) {
            if is_pid_alive(jpid) {
                is_active = true;
                if any_usr_running_phase.is_none() {
                    any_usr_running_phase = Some(format!("{}: Running", label));
                }
            }
        }

        if let Some(ref cs) = cron_state_json {
            if let Some(job_obj) = cs.get("jobs").and_then(|j| j.get(job_id)) {
                if let Some(lr) = job_obj.get("last_run").and_then(|v| v.as_u64()) {
                    last_run = lr;
                    latest_usr_mtime = latest_usr_mtime.max(lr);
                }
                if let Some(ec) = job_obj.get("exit_code").and_then(|v| v.as_i64()) {
                    exit_code = ec;
                }
            }
        }

        usr_cron_jobs_summary.push(json!({
            "id": job_id,
            "label": label,
            "desc": desc,
            "interval": interval,
            "enabled": enabled,
            "phase": phase,
            "active": is_active,
            "last_run": last_run,
            "exit_code": exit_code,
        }));
    }

    let overall_usr_phase = if let Some(r_phase) = any_usr_running_phase {
        r_phase
    } else if cron_daemon_alive {
        format!("Daemon Active ({} Jobs)", usr_job_defs.len())
    } else {
        "Daemon Inactive".to_string()
    };

    if !usr_job_defs.is_empty() || !usr_cron_tasks.is_empty() {
        tasks.push(json!({
            "id": "usr_cron_sentinels",
            "name": "usr_cron_sentinels",
            "task_type": "usr_cron",
            "type": "usr_cron",
            "phase": overall_usr_phase,
            "done": false,
            "paused": false,
            "pid_alive": cron_daemon_alive,
            "pid": cron_daemon_pid,
            "mtime_secs": latest_usr_mtime,
            "is_subagent": false,
            "subagent_tier": "usr",
            "meta_cmd": "USR Cron Jobs & Sentinels",
            "summary": format!("USR Cron: User Sentinels ({} Jobs)", usr_job_defs.len()),
            "cron_jobs": usr_cron_jobs_summary,
        }));
    }

    // 4b. Sovereign Reactive Event Bus Task
    let eb_pid_file = state.george_dir.join("ipc").join("event_bus.pid");
    let eb_pid = read_pid_from_file(&eb_pid_file);
    let eb_alive = eb_pid.map_or(false, is_pid_alive);
    let eb_reactors_file = state.george_dir.join("reactors.json");
    let mut eb_reactors = Vec::new();
    let mut eb_events_total = 0u64;
    let mut eb_reactions_total = 0u64;
    let mut eb_mtime = 0u64;
    if let Ok(content) = fs::read_to_string(&eb_reactors_file).await {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&content) {
            if let Some(r_arr) = v.get("reactors").and_then(|r| r.as_array()) {
                eb_reactors = r_arr.clone();
            }
            if let Some(stats) = v.get("stats") {
                eb_events_total = stats.get("events_total").and_then(|x| x.as_u64()).unwrap_or(0);
                eb_reactions_total = stats.get("reactions_fired").and_then(|x| x.as_u64()).unwrap_or(0);
                eb_mtime = stats.get("last_event_ts").and_then(|x| x.as_u64()).unwrap_or(0);
            }
        }
    }
    let mut eb_last_lines = Vec::new();
    let eb_log_file = state.george_dir.join("ipc").join("event_bus.log");
    if let Ok(content) = fs::read_to_string(&eb_log_file).await {
        for l in content.lines().rev().take(15) {
            let trimmed = l.trim();
            if !trimmed.is_empty() {
                eb_last_lines.push(strip_ansi(trimmed));
            }
        }
        eb_last_lines.reverse();
    }
    let eb_phase = if eb_alive {
        format!("Active ({} Events / {} Reactions)", eb_events_total, eb_reactions_total)
    } else {
        "Daemon Inactive".to_string()
    };
    tasks.push(json!({
        "id": "sys_event_bus",
        "name": "sys_event_bus",
        "task_type": "event_bus",
        "type": "event_bus",
        "phase": eb_phase,
        "done": false,
        "paused": false,
        "pid_alive": eb_alive,
        "pid": eb_pid,
        "mtime_secs": eb_mtime,
        "is_subagent": false,
        "subagent_tier": "sys",
        "meta_cmd": "Sovereign Reactive Event Bus & Autonomic Reactors",
        "summary": format!("Event Bus: {} Active Reactors ({} Events)", eb_reactors.len(), eb_events_total),
        "reactors": eb_reactors,
        "last_lines": eb_last_lines,
        "events_total": eb_events_total,
        "reactions_total": eb_reactions_total,
    }));

    // 5. Also incorporate subagents from .george/subagents.json and attach to parent tasks
    let subagents_file = state.george_dir.join("subagents.json");
    if let Ok(reg_str) = fs::read_to_string(&subagents_file).await {
        if let Ok(entries) = serde_json::from_str::<Vec<serde_json::Value>>(&reg_str) {
            for entry in &entries {
                let ppid = entry.get("parent_pid").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                if ppid > 0 {
                    for t in &mut tasks {
                        if let Some(t_pid) = t.get("pid").and_then(|v| v.as_u64()).map(|v| v as u32) {
                            if t_pid == ppid {
                                if let Some(obj) = t.as_object_mut() {
                                    let subs = obj.entry("subagents".to_string()).or_insert_with(|| json!([]));
                                    if let Some(arr) = subs.as_array_mut() {
                                        arr.push(entry.clone());
                                    }
                                }
                            }
                        }
                    }
                }
            }

            for entry in entries {
                if let Some(sub_id) = entry.get("id").and_then(|v| v.as_str()) {
                    if tasks.iter().any(|t| t.get("id").and_then(|v| v.as_str()) == Some(sub_id)) {
                        continue;
                    }
                    let status = entry.get("status").and_then(|v| v.as_str()).unwrap_or("STOPPED");
                    let sub_pid = entry.get("pid").and_then(|v| v.as_i64()).unwrap_or(0) as u32;
                    let mut pid_alive = if sub_pid > 0 { is_pid_alive(sub_pid) } else { false };
                    let status_upper = status.to_uppercase();
                    let is_ws_done = state.george_dir.join("workspaces").join(sub_id).join(".done").exists()
                        || state.lodge_dir.join(".sandboxes").join(sub_id).join(".done").exists();
                    let done = is_ws_done || status_upper == "COMPLETED" || status_upper == "FAILED" || status_upper == "CULLED" || status_upper == "ORPHANED" || status_upper == "STOPPED" || !pid_alive;
                    if done {
                        pid_alive = false;
                    }
                    let obj = entry.get("objective").and_then(|v| v.as_str()).unwrap_or("");
                    let tier = entry.get("tier").and_then(|v| v.as_str()).unwrap_or("1");

                    let out_path = state.george_dir.join("subagents").join(format!("{}.out", sub_id));
                    let mut sub_mtime = if let Ok(meta) = fs::metadata(&out_path).await {
                        meta.modified().ok()
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_secs())
                            .unwrap_or(0)
                    } else {
                        0
                    };
                    if sub_mtime == 0 {
                        let ws_done_path = state.george_dir.join("workspaces").join(sub_id).join(".done");
                        if let Ok(meta) = fs::metadata(&ws_done_path).await {
                            sub_mtime = meta.modified().ok()
                                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                                .map(|d| d.as_secs())
                                .unwrap_or(0);
                        }
                    }
                    if sub_mtime == 0 {
                        if let Some(ts_part) = sub_id.split('_').last() {
                            sub_mtime = ts_part.parse::<u64>().unwrap_or(0);
                        }
                    }

                    // If completed/dead and older than 45 seconds, omit from Autonomic Task Bay
                    if done && now.saturating_sub(sub_mtime) > 45 {
                        continue;
                    }

                    let mut last_lines = Vec::new();
                    if let Ok(content) = fs::read_to_string(&out_path).await {
                        for l in content.lines().rev().take(15) {
                            let trimmed = l.trim();
                            if !trimmed.is_empty() {
                                last_lines.push(strip_ansi(trimmed));
                            }
                        }
                        last_lines.reverse();
                    }

                    let sub_ppid = entry.get("parent_pid").and_then(|v| v.as_u64()).unwrap_or(0) as u32;

                    tasks.push(json!({
                        "id": sub_id,
                        "name": sub_id,
                        "phase": status,
                        "done": done,
                        "paused": false,
                        "pid_alive": pid_alive,
                        "pid": if sub_pid > 0 { Some(sub_pid) } else { None },
                        "mtime_secs": sub_mtime,
                        "is_subagent": true,
                        "subagent_tier": tier,
                        "subagent_obj": obj,
                        "meta_cmd": obj,
                        "task_type": "subagent",
                        "last_lines": last_lines,
                        "parent_pid": if sub_ppid > 0 { Some(sub_ppid) } else { None },
                    }));
                }
            }
        }
    }

    // 6. Group nested subtasks and child REPL tasks into parent tasks
    // If a task has a parent_task_id or parent_pid matching another task in `tasks`,
    // nest it into the parent's "subtasks" array instead of displaying duplicate rail cards.
    let mut parent_to_subtasks: std::collections::HashMap<String, Vec<serde_json::Value>> = std::collections::HashMap::new();
    let mut nested_ids = std::collections::HashSet::new();

    let task_pids: std::collections::HashMap<u32, String> = tasks
        .iter()
        .filter_map(|t| {
            let id = t.get("id").and_then(|v| v.as_str())?.to_string();
            let pid = t.get("pid").and_then(|v| v.as_u64()).map(|v| v as u32)?;
            Some((pid, id))
        })
        .collect();

    for t in &tasks {
        let child_id = match t.get("id").and_then(|v| v.as_str()) {
            Some(id) => id,
            None => continue,
        };

        let mut resolved_parent_id = None;

        if let Some(p_id) = t.get("parent_task_id").and_then(|v| v.as_str()) {
            if tasks.iter().any(|pt| pt.get("id").and_then(|v| v.as_str()) == Some(p_id)) && p_id != child_id {
                resolved_parent_id = Some(p_id.to_string());
            }
        }

        if resolved_parent_id.is_none() {
            if let Some(p_pid) = t.get("parent_pid").and_then(|v| v.as_u64()).map(|v| v as u32) {
                if let Some(p_id) = task_pids.get(&p_pid) {
                    if p_id != child_id {
                        resolved_parent_id = Some(p_id.clone());
                    }
                }
            }
        }

        if resolved_parent_id.is_none() && child_id.starts_with("sub_") {
            for other_t in &tasks {
                let other_id = other_t.get("id").and_then(|v| v.as_str()).unwrap_or("");
                if !other_id.is_empty() && other_id != child_id && child_id.starts_with(&format!("sub_{}", other_id)) {
                    resolved_parent_id = Some(other_id.to_string());
                    break;
                }
            }
        }

        if let Some(pid_str) = resolved_parent_id {
            parent_to_subtasks.entry(pid_str).or_default().push(t.clone());
            nested_ids.insert(child_id.to_string());
        }
    }

    // Attach subtasks to their parents
    for t in &mut tasks {
        if let Some(id) = t.get("id").and_then(|v| v.as_str()) {
            if let Some(subs) = parent_to_subtasks.remove(id) {
                if let Some(obj) = t.as_object_mut() {
                    let subtasks_arr = obj.entry("subtasks".to_string()).or_insert_with(|| json!([]));
                    if let Some(arr) = subtasks_arr.as_array_mut() {
                        for sub in subs {
                            arr.push(sub);
                        }
                    }
                }
            }
        }
    }

    // Filter out nested tasks whose parents are active in tasks
    tasks.retain(|t| {
        let id = t.get("id").and_then(|v| v.as_str()).unwrap_or("");
        !nested_ids.contains(id)
    });

    // Update subagent_count and subtask_count on each task
    for t in &mut tasks {
        if let Some(obj) = t.as_object_mut() {
            let sa_cnt = obj.get("subagents").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
            let st_cnt = obj.get("subtasks").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
            obj.insert("subtask_count".to_string(), json!(st_cnt));
            obj.insert("subagent_count".to_string(), json!(sa_cnt + st_cnt));
        }
    }

    tasks.sort_by(|a, b| {
        let a_alive = a.get("pid_alive").and_then(|v| v.as_bool()).unwrap_or(false);
        let b_alive = b.get("pid_alive").and_then(|v| v.as_bool()).unwrap_or(false);
        if a_alive != b_alive {
            return b_alive.cmp(&a_alive);
        }
        let a_time = a.get("mtime_secs").and_then(|v| v.as_u64()).unwrap_or(0);
        let b_time = b.get("mtime_secs").and_then(|v| v.as_u64()).unwrap_or(0);
        b_time.cmp(&a_time)
    });

    Json(tasks)
}

pub async fn post_task_input(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(payload): Json<TaskInputPayload>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = resolve_task_dir(&state, &clean_id).await;
    let fifo = sandbox.join(".stdin.fifo");

    if fifo.exists() {
        use tokio::io::AsyncWriteExt;
        if let Ok(mut f) = fs::OpenOptions::new().write(true).open(&fifo).await {
            let mut line = payload.input.clone();
            if !line.ends_with('\n') {
                line.push('\n');
            }
            if f.write_all(line.as_bytes()).await.is_ok() {
                return Json(json!({ "status": "ok", "message": "Input sent to FIFO" }));
            }
        }
    }

    let input_file = sandbox.join(".user_input");
    if fs::write(&input_file, payload.input).await.is_ok() {
        Json(json!({ "status": "ok", "message": "Input staged to .user_input" }))
    } else {
        Json(json!({ "status": "error", "message": "Failed to stage input" }))
    }
}

pub async fn pause_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = resolve_task_dir(&state, &clean_id).await;
    let _ = fs::write(sandbox.join(".pause_requested"), "1").await;
    Json(json!({ "status": "paused", "id": clean_id }))
}

pub async fn resume_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = resolve_task_dir(&state, &clean_id).await;
    let _ = fs::remove_file(sandbox.join(".pause_requested")).await;
    let _ = fs::write(sandbox.join(".resume_requested"), "1").await;
    Json(json!({ "status": "resumed", "id": clean_id }))
}

pub async fn inject_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(payload): Json<TaskInjectPayload>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = resolve_task_dir(&state, &clean_id).await;
    let msg = payload
        .guidance
        .or(payload.message)
        .or(payload.input)
        .unwrap_or_default();
    if msg.trim().is_empty() {
        return (axum::http::StatusCode::BAD_REQUEST, Json(json!({ "error": "empty guidance message" }))).into_response();
    }
    let priority = payload.priority.unwrap_or(1);
    let formatted = if priority == 1 {
        format!("[CRITICAL OPERATOR DIRECTIVE - PRIORITY 1]: {}", msg.trim())
    } else {
        msg.trim().to_string()
    };
    let inject_file = sandbox.join(".guidance_injection");
    let _ = fs::write(&inject_file, formatted).await;
    Json(json!({ "status": "injected", "id": clean_id, "priority": priority })).into_response()
}

pub async fn compact_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = resolve_task_dir(&state, &clean_id).await;
    let compact_file = sandbox.join(".compact_requested");
    let _ = fs::write(&compact_file, "1").await;
    Json(json!({ "status": "compact_requested", "id": clean_id })).into_response()
}

pub async fn abort_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = resolve_task_dir(&state, &clean_id).await;

    // 1. Mark .abort and .done
    let _ = fs::write(sandbox.join(".abort"), "1").await;
    let _ = fs::write(sandbox.join(".done"), "1").await;
    let _ = fs::write(sandbox.join(".phase"), "Aborted by Operator").await;

    // 2. Kill PID if present (guarding against killing daemon processes like cron or self)
    let pid_file = sandbox.join(".pid");
    if let Some(pid) = read_pid_from_file(&pid_file) {
        let cron_pid = read_pid_from_file(&state.george_dir.join(".cron.pid"));
        let my_pid = std::process::id();
        let is_daemon = Some(pid) == cron_pid || pid == my_pid;
        if !is_daemon {
            kill_process_tree(pid);
        }
        let _ = fs::remove_file(&pid_file).await;
    }

    // Clean up active telemetry descriptor if present
    let telem_file = state.george_dir.join("telemetry/active").join(format!("{}.json", clean_id));
    if telem_file.exists() {
        let _ = fs::remove_file(&telem_file).await;
    }

    // 3. If subagent, also notify subagent registry
    if clean_id.starts_with("sub_") {
        let script = format!(
            "source '{}/lib/agents/subagents.sh' 2>/dev/null && subagents_kill '{}'",
            state.lodge_dir.display(),
            clean_id
        );
        let _ = tokio::process::Command::new("bash")
            .args(["-c", &script])
            .current_dir(&state.lodge_dir)
            .output()
            .await;
    }

    Json(json!({ "status": "aborted", "id": clean_id }))
}

pub async fn cull_tasks(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let cron_pid = read_pid_from_file(&state.george_dir.join(".cron.pid"));
    let my_pid = std::process::id();
    let is_daemon_pid = |pid: u32| -> bool {
        Some(pid) == cron_pid || pid == my_pid
    };

    let sandboxes_dir = state.lodge_dir.join(".sandboxes");
    let mut culled = 0;
    if let Ok(mut entries) = fs::read_dir(&sandboxes_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.is_dir() {
                let done = p.join(".done").exists();
                let pid_file = p.join(".pid");
                let pid_alive = match read_pid_from_file(&pid_file) {
                    Some(pid) if !is_daemon_pid(pid) => is_pid_alive(pid),
                    _ => false,
                };
                let phase_file = p.join(".phase");
                let phase = fs::read_to_string(&phase_file).await.unwrap_or_default().to_lowercase();
                let is_phase_done = phase.contains("complete") || phase.contains("done") || phase.contains("culled") || phase.contains("orphaned");
                if done || !pid_alive || is_phase_done {
                    if fs::remove_dir_all(&p).await.is_ok() {
                        culled += 1;
                    }
                }
            }
        }
    }

    let workspaces_dir = state.george_dir.join("workspaces");
    if let Ok(mut entries) = fs::read_dir(&workspaces_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if !p.is_dir() || name.starts_with('.') || name == "web_session.jsonl" || name == "last_search.json" {
                continue;
            }
            let done = p.join(".done").exists();
            let pid_file = p.join(".pid");
            let pid_alive = match read_pid_from_file(&pid_file) {
                Some(pid) if !is_daemon_pid(pid) => is_pid_alive(pid),
                _ => false,
            };
            let phase_file = p.join(".phase");
            let phase = fs::read_to_string(&phase_file).await.unwrap_or_default().to_lowercase();
            let is_phase_done = phase.contains("complete") || phase.contains("done") || phase.contains("culled") || phase.contains("orphaned");
            if done || is_phase_done || !pid_alive {
                if fs::remove_dir_all(&p).await.is_ok() {
                    culled += 1;
                }
            }
        }
    }

    // Prune stale/dead subagents from .george/subagents.json
    let subagents_file = state.george_dir.join("subagents.json");
    if let Ok(reg_str) = fs::read_to_string(&subagents_file).await {
        if let Ok(entries) = serde_json::from_str::<Vec<serde_json::Value>>(&reg_str) {
            let active_entries: Vec<serde_json::Value> = entries.into_iter().filter(|entry| {
                let id = entry.get("id").and_then(|v| v.as_str()).unwrap_or("");
                let status = entry.get("status").and_then(|v| v.as_str()).unwrap_or("").to_uppercase();
                if status != "RUNNING" {
                    return false;
                }
                let is_ws_done = state.george_dir.join("workspaces").join(id).join(".done").exists()
                    || state.lodge_dir.join(".sandboxes").join(id).join(".done").exists();
                if is_ws_done {
                    return false;
                }
                let sub_pid = entry.get("pid").and_then(|v| v.as_i64()).unwrap_or(0) as u32;
                sub_pid > 0 && is_pid_alive(sub_pid)
            }).collect();
            if let Ok(new_json) = serde_json::to_string_pretty(&active_entries) {
                let _ = fs::write(&subagents_file, new_json).await;
            }
        }
    }

    // Run POSIX FIFO IPC garbage collector
    let gc_script = format!("source '{}/lib/ipc/fifo_ipc.sh' 2>/dev/null; ipc_gc --force 2>/dev/null || true", state.lodge_dir.display());
    let _ = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(gc_script)
        .output()
        .await;

    Json(json!({ "status": "ok", "culled_count": culled }))
}

pub async fn get_task_trajectory(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");

    if clean_id == "sys_cron_sentinels" || clean_id == "sys_cron" || clean_id == "usr_cron_sentinels" || clean_id == "usr_cron" {
        let cron_log = state.george_dir.join("cron.log");
        let content = if let Ok(c) = fs::read_to_string(&cron_log).await {
            let lines: Vec<&str> = c.lines().collect();
            let start = lines.len().saturating_sub(1000);
            lines[start..].join("\n")
        } else {
            "Cron log empty or not found.".to_string()
        };
        return Json(json!({
            "status": "ok",
            "id": clean_id,
            "trajectory": content,
            "phase": "Daemon Active",
            "done": false
        })).into_response();
    }

    if clean_id == "sys_event_bus" || clean_id == "event_bus" {
        let eb_log = state.george_dir.join("ipc").join("event_bus.log");
        let content = if let Ok(c) = fs::read_to_string(&eb_log).await {
            let lines: Vec<&str> = c.lines().collect();
            let start = lines.len().saturating_sub(1000);
            lines[start..].join("\n")
        } else {
            "Event bus log empty or not found.".to_string()
        };
        return Json(json!({
            "status": "ok",
            "id": clean_id,
            "trajectory": content,
            "phase": "Event Bus Active",
            "done": false
        })).into_response();
    }

    let mut sandbox = resolve_task_dir(&state, &clean_id).await;
    let mut traj_log = find_trajectory_log(&sandbox).await;

    let discord_target = if clean_id.starts_with("discord_") {
        Some(clean_id.clone())
    } else if let Some(idx) = clean_id.find("discord_") {
        let d_part = &clean_id[idx..];
        let parts: Vec<&str> = d_part.split('_').collect();
        if parts.len() >= 4 {
            Some(format!("{}_{}_{}", parts[0], parts[1], parts[2]))
        } else {
            Some(d_part.to_string())
        }
    } else {
        None
    };

    if traj_log.is_none() {
        if let Some(ref d_name) = discord_target {
            let d_raw = state.george_dir.join("discord_sessions").join(d_name).join("raw_react.log");
            if d_raw.exists() {
                traj_log = Some(d_raw);
            } else {
                let rest = d_name.strip_prefix("discord_").unwrap_or(d_name);
                let chan_id = rest.split('_').next().unwrap_or(rest);
                let s_log = state.george_dir.join("discord_sessions").join(format!("session_{}.log", chan_id));
                if s_log.exists() {
                    traj_log = Some(s_log);
                }
            }
        }
    }

    if traj_log.is_none() && clean_id.starts_with("sub_") {
        let sub_out = state.george_dir.join("subagents").join(format!("{}.out", clean_id));
        if sub_out.exists() {
            traj_log = Some(sub_out);
        } else {
            let sub_log = state.george_dir.join("subagents").join(format!("{}.log", clean_id));
            if sub_log.exists() {
                traj_log = Some(sub_log);
            } else if let Some(stripped) = clean_id.strip_prefix("sub_") {
                if stripped.starts_with("sub_") {
                    let s_out = state.george_dir.join("subagents").join(format!("{}.out", stripped));
                    if s_out.exists() {
                        traj_log = Some(s_out);
                    } else {
                        let s_log = state.george_dir.join("subagents").join(format!("{}.log", stripped));
                        if s_log.exists() {
                            traj_log = Some(s_log);
                        }
                    }
                }
            }
        }
    }

    if traj_log.is_none() {
        let run_traj = state.george_dir.join("runs").join(&clean_id).join("trajectory.log");
        if run_traj.exists() {
            traj_log = Some(run_traj);
        }
    }

    if traj_log.is_none() {
        let telem_file = state.george_dir.join("telemetry").join("active").join(format!("{}.json", clean_id));
        if let Ok(content) = fs::read_to_string(&telem_file).await {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(log_str) = val.get("log_file").and_then(|v| v.as_str()) {
                    if !log_str.is_empty() {
                        let p = PathBuf::from(log_str);
                        if p.exists() {
                            traj_log = Some(p);
                        }
                    }
                }
                if traj_log.is_none() {
                    if let Some(trans) = val.get("transcript_file").and_then(|v| v.as_str()) {
                        if !trans.is_empty() {
                            let p = PathBuf::from(trans);
                            if p.exists() {
                                traj_log = Some(p);
                            }
                        }
                    }
                }
            }
        }
    }

    if traj_log.is_none() {
        let direct_trans = state.george_dir.join("transcripts").join(format!("{}.md", clean_id));
        if direct_trans.exists() {
            traj_log = Some(direct_trans);
        }
    }

    if traj_log.is_none() {
        let run_traj = state.george_dir.join("runs").join(&clean_id).join("trajectory.log");
        if run_traj.exists() {
            traj_log = Some(run_traj);
        }
    }

    if traj_log.is_none() {
        let run_dir = state.george_dir.join("runs").join(&clean_id);
        let msgs_file = run_dir.join("messages.json");
        if msgs_file.exists() {
            if let Ok(content) = fs::read_to_string(&msgs_file).await {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                    let mut traj = format_messages_as_trajectory(&val);
                    let final_reply = run_dir.join("final_reply.md");
                    if let Ok(fr) = fs::read_to_string(&final_reply).await {
                        traj.push_str("\n✓ Task Complete!\n");
                        traj.push_str(&fr);
                        traj.push('\n');
                    }
                    if !traj.trim().is_empty() {
                        return Json(json!({
                            "status": "ok",
                            "id": clean_id,
                            "trajectory": traj,
                            "phase": "Completed",
                            "done": true
                        })).into_response();
                    }
                }
            }
        }
        let final_reply = run_dir.join("final_reply.md");
        if let Ok(fr) = fs::read_to_string(&final_reply).await {
            if !fr.trim().is_empty() {
                return Json(json!({
                    "status": "ok",
                    "id": clean_id,
                    "trajectory": format!("✓ Task Complete!\n\n{}", fr),
                    "phase": "Completed",
                    "done": true
                })).into_response();
            }
        }
    }

    if traj_log.is_none() {
        let session_file = state.george_dir.join("workspaces").join("web_session.jsonl");
        if let Ok(content) = fs::read_to_string(&session_file).await {
            for line in content.lines().rev() {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
                    let msg_id = val.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    let msg_task_id = val.get("task_id").and_then(|v| v.as_str()).unwrap_or("");
                    if msg_id == clean_id || msg_task_id == clean_id {
                        if !msg_task_id.is_empty() && msg_task_id != clean_id {
                            let sb = state.lodge_dir.join(".sandboxes").join(msg_task_id);
                            if let Some(tl) = find_trajectory_log(&sb).await {
                                sandbox = sb;
                                traj_log = Some(tl);
                                break;
                            }
                        }
                        if let Some(msg_content) = val.get("content").and_then(|v| v.as_str()) {
                            if !msg_content.trim().is_empty() {
                                return Json(json!({
                                    "status": "ok",
                                    "id": clean_id,
                                    "trajectory": msg_content,
                                    "phase": "Completed",
                                    "done": true
                                })).into_response();
                            }
                        }
                    }
                }
            }
        }
    }

    let mut phase = fs::read_to_string(sandbox.join(".phase")).await.unwrap_or_else(|_| "Active".into());
    let mut done = sandbox.join(".done").exists() || phase.trim() == "Completed";

    let run_file = state.george_dir.join("runs").join(&clean_id).join("run.json");
    if let Ok(content) = fs::read_to_string(&run_file).await {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
            let status = val.get("status").and_then(|v| v.as_str()).unwrap_or("");
            if status == "FINISHED" {
                done = true;
                if phase == "Active" || phase.is_empty() {
                    phase = "Completed".into();
                }
            } else if status == "RUNNING" {
                done = false;
            }
        }
    }

    if !done {
        let pid_file = sandbox.join(".pid");
        if let Some(spid) = read_pid_from_file(&pid_file) {
            if is_pid_alive(spid) {
                done = false;
            }
        }

        if let Some(ref d_name) = discord_target {
            let rest = d_name.strip_prefix("discord_").unwrap_or(d_name);
            let chan_id = rest.split('_').next().unwrap_or(rest);
            let session_pid_file = state.george_dir.join("discord_sessions").join(format!("session_{}.pid", chan_id));
            if session_pid_file.exists() {
                if let Some(spid) = read_pid_from_file(&session_pid_file) {
                    if is_pid_alive(spid) {
                        done = false;
                    }
                }
            }
        }
    }

    if let Some(log_path) = traj_log {
        match fs::read_to_string(&log_path).await {
            Ok(content) => Json(json!({
                "status": "ok",
                "id": clean_id,
                "trajectory": content,
                "phase": phase.trim(),
                "done": done
            })).into_response(),
            Err(e) => (StatusCode::NOT_FOUND, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
        }
    } else {
        (StatusCode::NOT_FOUND, Json(json!({ "status": "error", "message": "Trajectory log not found" }))).into_response()
    }
}
