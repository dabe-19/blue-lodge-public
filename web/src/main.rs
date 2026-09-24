use axum::{
    extract::{ws::{Message, WebSocket, WebSocketUpgrade}, Multipart, Path, State},
    http::StatusCode,
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Json,
    },
    routing::{delete, get, post},
    Router,
};
use futures_util::{stream::Stream, SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    convert::Infallible,
    net::SocketAddr,
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::fs;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
use tower_http::cors::{Any, CorsLayer};
use tower_http::services::ServeDir;

#[derive(Clone, Serialize, Deserialize)]
struct DockedWorkspace {
    path: PathBuf,
    mode: String,
    branch: String,
    repo_name: String,
    gitea_synced: bool,
}

#[derive(Clone)]
struct AppState {
    lodge_dir: PathBuf,
    george_dir: PathBuf,
    docked_workspace: Arc<tokio::sync::RwLock<DockedWorkspace>>,
}

#[tokio::main]
async fn main() {
    let lodge_dir = std::env::var("LODGE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
            PathBuf::from(home).join("blue-lodge")
        });
    let george_dir = lodge_dir.join(".george");

    // Mark web observability active so background scripts suppress terminal popups
    let _ = fs::write(george_dir.join(".web_observability"), "1").await;

    // Load active workspace or default to lodge_dir
    let ws_conf = george_dir.join("workspace.conf");
    let initial_ws = if let Ok(data) = fs::read_to_string(&ws_conf).await {
        serde_json::from_str::<DockedWorkspace>(&data).unwrap_or_else(|_| DockedWorkspace {
            path: lodge_dir.clone(),
            mode: "local".to_string(),
            branch: "develop".to_string(),
            repo_name: "blue-lodge".to_string(),
            gitea_synced: true,
        })
    } else {
        DockedWorkspace {
            path: lodge_dir.clone(),
            mode: "local".to_string(),
            branch: "develop".to_string(),
            repo_name: "blue-lodge".to_string(),
            gitea_synced: true,
        }
    };

    let state = Arc::new(AppState {
        lodge_dir: lodge_dir.clone(),
        george_dir: george_dir.clone(),
        docked_workspace: Arc::new(tokio::sync::RwLock::new(initial_ws)),
    });

    let static_dir = lodge_dir.join("web").join("static");

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/api/status", get(get_status))
        .route("/api/tasks", get(get_tasks))
        .route("/api/session", get(get_session).delete(clear_session))
        .route("/api/transcripts", get(get_transcripts))
        .route("/api/transcripts/:name", get(get_transcript_content).delete(delete_transcript))
        .route("/api/journal", get(get_journal).post(save_journal))
        .route("/api/sqlite/query", post(query_sqlite))
        .route("/api/memories", get(get_memories))
        .route("/api/config", get(get_config).post(update_config))
        .route("/api/config/all", get(get_config_all))
        .route("/api/config/full", get(get_config_full))
        .route("/api/config/key", post(update_config_key))
        .route("/api/config/test", post(test_connection))
        .route("/api/cron", get(get_cron_jobs).post(save_cron_job))
        .route("/api/cron/run/:name", post(run_cron_job))
        .route("/api/cron/job/:name", delete(delete_cron_job))
        .route("/api/cron/job/:name/toggle-platform", post(toggle_cron_platform))
        .route("/api/cron/job/:name/toggle-enabled", post(toggle_cron_enabled))
        .route("/api/social/gate", get(get_social_gate))
        .route("/api/social/gate/toggle", post(toggle_social_gate))
        .route("/api/cron/generate", post(generate_cron_job))
        .route("/api/cron/daemon/start", post(start_cron_daemon))
        .route("/api/cron/daemon/stop", post(stop_cron_daemon))
        .route("/api/cron/daemon/restart", post(restart_cron_daemon))
        .route("/api/tunnel/status", get(get_tunnel_status))
        .route("/api/tunnel/connect", post(connect_tunnel))
        .route("/api/tunnel/disconnect", post(disconnect_tunnel))
        .route("/api/upload", post(upload_file))
        .route("/api/chat", post(post_chat))
        .route("/api/chat/dispatch", post(post_dispatch))
        .route("/api/task/:id/input", post(post_task_input))
        .route("/api/command", post(post_chat))
        .route("/api/task/:id/pause", post(pause_task))
        .route("/api/task/:id/resume", post(resume_task))
        .route("/api/task/:id/inject", post(inject_task))
        .route("/api/task/:id/abort", post(abort_task))
        .route("/api/tasks/cull", post(cull_tasks))
        .route("/api/commands", get(get_commands))
        .route("/api/research/config", get(get_research_config).post(save_research_config))
        .route("/api/file/read", get(read_file_content))
        .route("/api/file/save", post(save_file_content))
        .route("/api/files/list", get(list_workspace_files))
        .route("/api/file/resolve-deps", get(resolve_script_deps))
        .route("/api/workspace/active", get(get_active_workspace))
        .route("/api/workspace/dock", post(dock_workspace))
        .route("/api/terminal/ws", get(terminal_ws_handler))
        .route("/api/copilot/chat", post(post_copilot_chat))
        .route("/api/node/probe", post(probe_node))
        .route("/api/node/save", post(save_node_endpoint))
        .route("/api/model/stage-pull", post(stage_model_pull))
        .route("/api/mcp/servers", get(get_mcp_servers))
        .route("/api/mcp/server/start", post(start_mcp_server))
        .route("/api/mcp/server/stop", post(stop_mcp_server))
        .route("/api/mcp/server/add", post(add_mcp_server))
        .route("/api/mcp/server/remove", post(remove_mcp_server))
        .route("/api/mcp/server/test", post(test_mcp_server_tool))
        .route("/api/mcp/catalog", get(get_mcp_catalog))
        .route("/api/mcp/catalog/install", post(install_mcp_catalog_server))
        .route("/api/mcp/server/create_custom", post(create_custom_mcp_server))
        .route("/api/stream/events", get(stream_events))
        .route("/api/stream/task/:id", get(stream_task_trajectory))
        .nest_service("/static", ServeDir::new(&static_dir))
        .fallback_service(ServeDir::new(&static_dir))
        .layer(cors)
        .with_state(state);

    let port: u16 = std::env::var("PORT")
        .or_else(|_| std::env::var("GEORGE_WEB_PORT"))
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("[george-web] Sovereign Craftsman Engine listening on http://{}", addr);
    println!("[george-web] Static asset root: {}", static_dir.display());

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind web listener");
    axum::serve(listener, app).await.expect("Server error");
}

// ── Handlers ─────────────────────────────────────────────────────────

async fn get_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut gpus = Vec::new();
    if let Ok(output) = tokio::process::Command::new("nvidia-smi")
        .args([
            "--query-gpu=index,name,power.draw,utilization.gpu,memory.used,memory.total,temperature.gpu",
            "--format=csv,noheader,nounits",
        ])
        .output()
        .await
    {
        if output.status.success() {
            if let Ok(text) = String::from_utf8(output.stdout) {
                for line in text.lines() {
                    let parts: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
                    if parts.len() >= 7 {
                        gpus.push(json!({
                            "index": parts[0],
                            "name": parts[1],
                            "power_w": parts[2],
                            "gpu_util_pct": parts[3],
                            "vram_used_mb": parts[4],
                            "vram_total_mb": parts[5],
                            "temp_c": parts[6],
                        }));
                    }
                }
            }
        }
    }

    if gpus.is_empty() {
        gpus.push(json!({
            "index": "0",
            "name": "GPU 0 (Generic Host)",
            "power_w": "0",
            "gpu_util_pct": "0",
            "vram_used_mb": "0",
            "vram_total_mb": "0",
            "temp_c": "0",
        }));
    }

    let mut slots_info = json!([]);
    let client = reqwest_lite_get("http://127.0.0.1:8080/slots").await;
    if let Ok(val) = client {
        slots_info = val;
    }

    let active_tasks_count = get_active_tasks_count(&state.lodge_dir).await;

    // Load active compute nodes from endpoints.conf across the 4-tier hardware ladder
    let mut nodes = Vec::new();
    let conf_path = state.george_dir.join("endpoints.conf");
    let mut conf_map = std::collections::HashMap::new();
    if let Ok(content) = fs::read_to_string(&conf_path).await {
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('#') || trimmed.is_empty() {
                continue;
            }
            if let Some((k, v)) = trimmed.split_once('=') {
                let clean_k = k.trim().to_string();
                let clean_v = v.trim().trim_matches('"').to_string();
                conf_map.insert(clean_k, clean_v);
            }
        }
    }

    // Tier 3: Frontier Sovereign (Mac Studio / M-Series Metal)
    let t3_url = conf_map.get("TIER3_URL").cloned().unwrap_or_else(|| "http://mac-m5.local:8080".into());
    let t3_name = conf_map.get("TIER3_NAME").cloned().unwrap_or_else(|| "frontier-sovereign".into());
    let t3_model = conf_map.get("TIER3_MODEL").cloned().unwrap_or_else(|| "glm-5.3-flash".into());
    let t3_ctx = conf_map.get("TIER3_CONTEXT").and_then(|s| s.parse::<u32>().ok()).unwrap_or(65536);
    let t3_hw = conf_map.get("TIER3_HARDWARE").cloned().unwrap_or_else(|| "Mac M5 Ultra / 256GB Unified (Metal/MLX)".into());
    let t3_enabled = conf_map.get("TIER3_ENABLED").map(|s| s == "1").unwrap_or(false);
    let t3_active = if t3_enabled { reqwest_lite_get(&format!("{}/v1/models", t3_url)).await.is_ok() } else { false };
    nodes.push(json!({
        "tier": "Tier 3",
        "role": "TIER 3 FRONTIER",
        "name": t3_name,
        "hardware": t3_hw,
        "url": t3_url,
        "model": t3_model,
        "context": t3_ctx,
        "enabled": t3_enabled,
        "active": t3_active
    }));

    // Tier 1: Primary Workhorse (Local CUDA RTX 3060)
    let t1_url = conf_map.get("TIER1_URL").cloned().unwrap_or_else(|| "http://127.0.0.1:8080".into());
    let t1_name = conf_map.get("TIER1_NAME").cloned().unwrap_or_else(|| "cuda-workhorse".into());
    let t1_model = conf_map.get("TIER1_MODEL").cloned().unwrap_or_else(|| "ternary-bonsai-27b".into());
    let t1_ctx = conf_map.get("TIER1_CONTEXT").and_then(|s| s.parse::<u32>().ok()).unwrap_or(24576);
    let t1_hw = conf_map.get("TIER1_HARDWARE").cloned().unwrap_or_else(|| "NVIDIA GeForce RTX 3060 12GB (CUDA)".into());
    let t1_enabled = conf_map.get("TIER1_ENABLED").map(|s| s != "0").unwrap_or(true);
    let t1_active = reqwest_lite_get(&format!("{}/v1/models", t1_url)).await.is_ok();
    nodes.push(json!({
        "tier": "Tier 1",
        "role": "TIER 1 MASTER",
        "name": t1_name,
        "hardware": t1_hw,
        "url": t1_url,
        "model": t1_model,
        "context": t1_ctx,
        "enabled": t1_enabled,
        "active": t1_active
    }));

    // Tier 2: Secondary Worker / Legacy (AMD Radeon RX 5700 XT)
    let t2_url = conf_map.get("TIER2_URL").cloned().unwrap_or_else(|| "http://127.0.0.1:18080".into());
    let t2_name = conf_map.get("TIER2_NAME").cloned().unwrap_or_else(|| "legacy-5700xt".into());
    let t2_model = conf_map.get("TIER2_MODEL").cloned().unwrap_or_else(|| "gemma-4-12b-agentic".into());
    let t2_ctx = conf_map.get("TIER2_CONTEXT").and_then(|s| s.parse::<u32>().ok()).unwrap_or(8192);
    let t2_hw = conf_map.get("TIER2_HARDWARE").cloned().unwrap_or_else(|| "AMD Radeon RX 5700 XT (ROCm / Vulkan)".into());
    let t2_enabled = conf_map.get("TIER2_ENABLED").map(|s| s == "1").unwrap_or(true);
    let t2_active = if t2_enabled { reqwest_lite_get(&format!("{}/v1/models", t2_url)).await.is_ok() } else { false };
    nodes.push(json!({
        "tier": "Tier 2",
        "role": "TIER 2 WORKER",
        "name": t2_name,
        "hardware": t2_hw,
        "url": t2_url,
        "model": t2_model,
        "context": t2_ctx,
        "enabled": t2_enabled,
        "active": t2_active
    }));

    // Tier 0: Edge Mobile Fallback (Galaxy Fold 7 / Termux Ollama)
    let t0_url = conf_map.get("TIER0_URL").cloned().unwrap_or_else(|| "http://127.0.0.1:11434".into());
    let t0_name = conf_map.get("TIER0_NAME").cloned().unwrap_or_else(|| "edge-mobile".into());
    let t0_model = conf_map.get("TIER0_MODEL").cloned().unwrap_or_else(|| "gemma4-e2b-inst".into());
    let t0_ctx = conf_map.get("TIER0_CONTEXT").and_then(|s| s.parse::<u32>().ok()).unwrap_or(8192);
    let t0_hw = conf_map.get("TIER0_HARDWARE").cloned().unwrap_or_else(|| "Galaxy Fold 7 / Termux (Ollama Offgrid)".into());
    let t0_enabled = conf_map.get("TIER0_ENABLED").map(|s| s == "1").unwrap_or(true);
    let t0_active = if t0_enabled { reqwest_lite_get(&format!("{}/api/tags", t0_url)).await.is_ok() || reqwest_lite_get(&format!("{}/v1/models", t0_url)).await.is_ok() } else { false };
    nodes.push(json!({
        "tier": "Tier 0",
        "role": "TIER 0 EDGE MOBILE",
        "name": t0_name,
        "hardware": t0_hw,
        "url": t0_url,
        "model": t0_model,
        "context": t0_ctx,
        "enabled": t0_enabled,
        "active": t0_active
    }));

    Json(json!({
        "engine": "George",
        "motto": "Well done is better than well said",
        "timestamp": chrono_utc_now(),
        "gpus": gpus,
        "nodes": nodes,
        "slots": slots_info,
        "active_tasks": active_tasks_count,
    }))
}

async fn get_tasks(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut tasks = Vec::new();
    let now = chrono_epoch_secs();

    // 1. Check sandboxes (filter out completed tasks older than 15 minutes)
    let sandboxes_dir = state.lodge_dir.join(".sandboxes");
    if let Ok(mut entries) = fs::read_dir(&sandboxes_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.is_dir() {
                let name = entry.file_name().to_string_lossy().to_string();
                let phase_file = p.join(".phase");
                let phase = fs::read_to_string(&phase_file)
                    .await
                    .unwrap_or_else(|_| "Active".into());
                let mut done = p.join(".done").exists();
                let paused = p.join(".pause_requested").exists();

                // If sandbox has .pid file, check if PID is alive
                let pid_file = p.join(".pid");
                let has_pid = pid_file.exists();
                let pid_alive = read_pid_from_file(&pid_file).map_or(false, is_pid_alive);
                if has_pid && !pid_alive {
                    done = true;
                }

                let mtime_secs = entry.metadata().await.ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);

                // Filter out stale or dead sandboxes:
                // Skip if marked done (allow copilot tasks to show for up to 45s after done),
                // if PID is dead (allow copilot tasks to show for up to 30s after exit),
                // or if no PID file and inactive for > 60s
                if (done && (!name.starts_with("copilot_") || now.saturating_sub(mtime_secs) > 45))
                    || (has_pid && !pid_alive && (!name.starts_with("copilot_") || now.saturating_sub(mtime_secs) > 30))
                    || (!has_pid && now.saturating_sub(mtime_secs) > 60) {
                    continue;
                }

                // Semantic extracted summary
                let (task_type, summary) = if name.starts_with("copilot_") {
                    let meta_file = p.join("task_meta.json");
                    let mut desc = String::new();
                    if let Ok(meta_str) = fs::read_to_string(&meta_file).await {
                        if let Ok(meta_json) = serde_json::from_str::<serde_json::Value>(&meta_str) {
                            if let Some(target) = meta_json.get("file_path").and_then(|v| v.as_str()) {
                                let fstem = target.split('/').last().unwrap_or(target);
                                desc = format!("Craftsman Co-Pilot: Refactoring {}", fstem);
                            }
                        }
                    }
                    if desc.is_empty() {
                        desc = format!("Craftsman Co-Pilot: {}", name);
                    }
                    ("copilot", desc)
                } else if name.starts_with("research_") {
                    let raw = name.strip_prefix("research_").unwrap_or(&name);
                    let topic = if let Some(idx) = raw.rfind('_') {
                        if raw[idx+1..].chars().all(|c| c.is_ascii_digit()) {
                            &raw[..idx]
                        } else {
                            raw
                        }
                    } else {
                        raw
                    };
                    let words: Vec<String> = topic.split('-').map(|w| {
                        let mut c = w.chars();
                        match c.next() {
                            None => String::new(),
                            Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                        }
                    }).collect();
                    ("research", format!("Deep Research: {}", words.join(" ")))
                } else if name.starts_with("web_session_") {
                    ("session", format!("Interactive Session: {}", name))
                } else {
                    ("sandbox", format!("Sandbox Task: {}", name))
                };

                let log_tail = read_last_lines(&p, 5).await;

                tasks.push(json!({
                    "id": name,
                    "type": task_type,
                    "summary": summary,
                    "phase": phase.trim(),
                    "done": done,
                    "paused": paused,
                    "path": p.to_string_lossy(),
                    "log_tail": log_tail,
                }));
            }
        }
    }

    // 2. Check Discord Bridge sessions (verify PID liveness & auto-reap dead pids)
    let discord_dir = state.george_dir.join("discord_sessions");
    if let Ok(mut entries) = fs::read_dir(&discord_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let fname = entry.file_name().to_string_lossy().to_string();
            if fname.ends_with(".pid") {
                if let Some(pid) = read_pid_from_file(&p) {
                    if !is_pid_alive(pid) {
                        let _ = fs::remove_file(&p).await;
                        continue;
                    }
                } else {
                    let _ = fs::remove_file(&p).await;
                    continue;
                }

                let chan_id = fname.strip_prefix("session_").and_then(|s| s.strip_suffix(".pid")).unwrap_or(&fname);
                let log_file = discord_dir.join(format!("session_{}.log", chan_id));
                let mut log_tail = Vec::new();
                if let Ok(content) = fs::read_to_string(&log_file).await {
                    log_tail = content.lines().rev().take(3).map(String::from).collect();
                    log_tail.reverse();
                }
                tasks.push(json!({
                    "id": format!("discord_{}", chan_id),
                    "type": "discord",
                    "summary": format!("Discord Channel: #{}", chan_id),
                    "phase": "Gateway Active",
                    "done": false,
                    "paused": false,
                    "path": log_file.to_string_lossy(),
                    "log_tail": log_tail,
                }));
            }
        }
    }

    // 3. Check Autonomic Cron / Sentinel daemon (verify PID liveness)
    let cron_pid_file = state.george_dir.join(".cron.pid");
    let cron_log_file = state.george_dir.join("cron.log");
    if cron_pid_file.exists() {
        if let Some(pid) = read_pid_from_file(&cron_pid_file) {
            if !is_pid_alive(pid) {
                let _ = fs::remove_file(&cron_pid_file).await;
            } else {
                let mut log_tail = Vec::new();
                if let Ok(content) = fs::read_to_string(&cron_log_file).await {
                    log_tail = content.lines().rev().take(3).map(String::from).collect();
                    log_tail.reverse();
                }
                tasks.push(json!({
                    "id": "autonomic_sentinel",
                    "type": "cron",
                    "summary": "Autonomic Sentinel: PR, Issue & Health Sweeps",
                    "phase": "Autonomic Sentinel Active",
                    "done": false,
                    "paused": false,
                    "path": cron_log_file.to_string_lossy(),
                    "log_tail": log_tail,
                }));
            }
        } else {
            let _ = fs::remove_file(&cron_pid_file).await;
        }
    }

    // 4. Check Auto-Remediation in progress
    let remed_dir = state.george_dir.join("remediation").join("in_progress");
    if let Ok(mut entries) = fs::read_dir(&remed_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let name = entry.file_name().to_string_lossy().to_string();
            tasks.push(json!({
                "id": format!("remediation_{}", name),
                "type": "remediation",
                "summary": format!("Auto-Remediation: Circuit Breaker on {}", name),
                "phase": "Autonomous Recovery Loop",
                "done": false,
                "paused": false,
                "path": entry.path().to_string_lossy(),
                "log_tail": vec!["Autonomous remediation loop active...".to_string()],
            }));
        }
    }

    // 5. Check Active Telemetry ReAct Tasks (.george/telemetry/active/*.json)
    let telem_dir = state.george_dir.join("telemetry").join("active");
    if let Ok(mut entries) = fs::read_dir(&telem_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let fname = entry.file_name().to_string_lossy().to_string();
            if fname.ends_with(".json") {
                if let Ok(content) = fs::read_to_string(&p).await {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                        let tid = val.get("task_id").and_then(|v| v.as_str()).unwrap_or(&fname).to_string();
                        let pid = val.get("pid").and_then(|v| v.as_i64()).unwrap_or(0) as u32;
                        let alive = if pid > 0 { is_pid_alive(pid) } else { true };
                        if !alive {
                            let _ = fs::remove_file(&p).await;
                            continue;
                        }
                        let ttype = val.get("type").and_then(|v| v.as_str()).unwrap_or("agentic").to_string();
                        let turn = val.get("turn").and_then(|v| v.as_i64()).unwrap_or(0);
                        let max_turns = val.get("max_turns").and_then(|v| v.as_i64()).unwrap_or(30);
                        let last_tool = val.get("last_tool").and_then(|v| v.as_str()).unwrap_or("");
                        let trans = val.get("transcript_file").and_then(|v| v.as_str()).unwrap_or("");
                        
                        let summary = if !last_tool.is_empty() {
                            format!("Executing {}", last_tool)
                        } else {
                            format!("Running Task: {}", tid)
                        };

                        let mut log_tail = Vec::new();
                        if !trans.is_empty() {
                            if let Ok(t_content) = fs::read_to_string(trans).await {
                                log_tail = t_content.lines().rev().take(3).map(String::from).collect();
                                log_tail.reverse();
                            }
                        }

                        tasks.push(json!({
                            "id": tid,
                            "type": ttype,
                            "summary": summary,
                            "phase": format!("Turn {}/{}", turn, max_turns),
                            "done": false,
                            "paused": false,
                            "path": p.to_string_lossy(),
                            "log_tail": log_tail,
                        }));
                    }
                }
            }
        }
    }

    Json(tasks)
}

// ── Cron & Scheduled Sweeps Management Suite ───────────────────────────

#[derive(Deserialize, Debug)]
struct CronJobPayload {
    name: String,
    interval: u64,
    command: String,
    description: Option<String>,
    is_system: Option<bool>,
}

#[derive(Deserialize, Debug)]
struct CronGeneratePayload {
    prompt: String,
}

async fn get_cron_jobs(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut jobs = Vec::new();
    let cron_conf_file = state.george_dir.join("cron.conf");
    let mut intervals = std::collections::HashMap::new();
    let mut disabled_jobs = std::collections::HashSet::new();

    // Default intervals in seconds
    intervals.insert("sentinel_sweep", 60u64);
    intervals.insert("pr_sweep", 60u64);
    intervals.insert("issue_sweep", 60u64);
    intervals.insert("discord_sweep", 30u64);
    intervals.insert("email_sweep", 120u64);
    intervals.insert("x_social_sweep", 300u64);
    intervals.insert("mastodon_sweep", 180u64);

    if let Ok(content) = fs::read_to_string(&cron_conf_file).await {
        for line in content.lines() {
            let line = line.trim();
            if line.starts_with('#') || line.is_empty() {
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                let k = k.trim();
                let v = v.trim().replace('"', "").replace('\'', "");
                if k == "CRON_DISABLED_JOBS" {
                    for name in v.split(',') {
                        let name = name.trim();
                        if !name.is_empty() {
                            disabled_jobs.insert(name.to_string());
                        }
                    }
                } else if let Ok(secs) = v.parse::<u64>() {
                    match k {
                        "CRON_INTERVAL_SENTINEL" => { intervals.insert("sentinel_sweep", secs); }
                        "CRON_INTERVAL_PR" => { intervals.insert("pr_sweep", secs); }
                        "CRON_INTERVAL_ISSUE" => { intervals.insert("issue_sweep", secs); }
                        "CRON_INTERVAL_DISCORD" => { intervals.insert("discord_sweep", secs); }
                        "CRON_INTERVAL_EMAIL" => { intervals.insert("email_sweep", secs); }
                        "CRON_INTERVAL_X" => { intervals.insert("x_social_sweep", secs); }
                        "CRON_INTERVAL_MASTODON" => { intervals.insert("mastodon_sweep", secs); }
                        _ => {}
                    }
                }
            }
        }
    }

    // Read cron state
    let state_file = state.george_dir.join("cron_state.json");
    let mut state_json: serde_json::Value = json!({ "jobs": {} });
    if let Ok(content) = fs::read_to_string(&state_file).await {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
            state_json = val;
        }
    }

    let system_job_defs = vec![
        ("sentinel_sweep", "PR and system vitals watchdog sweep"),
        ("discord_sweep", "Polls Discord DMs and bot mentions across servers"),
        ("pr_sweep", "Three Degrees PR audit, automated merge, and remediation"),
        ("issue_sweep", "Circuit breaker escalation and automated issue fixes"),
        ("email_sweep", "Polls configured email inboxes for dispatch commands"),
        ("x_social_sweep", "𝕏 mentions and monetization telemetry sweep"),
        ("mastodon_sweep", "Mastodon notifications, mentions, and queue sweep"),
    ];

    for (name, desc) in system_job_defs {
        let interval = intervals.get(name).copied().unwrap_or(60);
        let job_state = state_json.get("jobs").and_then(|j| j.get(name));
        let last_run = job_state.and_then(|s| s.get("last_run")).and_then(|v| v.as_u64()).unwrap_or(0);
        let exit_code = job_state.and_then(|s| s.get("exit_code")).and_then(|v| v.as_i64()).unwrap_or(0);
        let updated_at = job_state.and_then(|s| s.get("updated_at")).and_then(|v| v.as_str()).unwrap_or("Never").to_string();

        let is_disabled = disabled_jobs.contains(name) ||
            job_state.and_then(|s| s.get("enabled")).and_then(|v| v.as_bool()) == Some(false);
        let enabled = !is_disabled;

        jobs.push(json!({
            "name": name,
            "interval": interval,
            "description": desc,
            "is_system": true,
            "enabled": enabled,
            "command": format!("./commands/cron.sh run {}", name),
            "last_run": last_run,
            "exit_code": exit_code,
            "updated_at": updated_at,
        }));
    }

    // Read custom jobs in .george/cron_jobs/*.sh
    let custom_dir = state.george_dir.join("cron_jobs");
    if let Ok(mut entries) = fs::read_dir(&custom_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("sh") {
                let file_stem = path.file_stem().unwrap_or_default().to_string_lossy().to_string();
                if let Ok(script) = fs::read_to_string(&path).await {
                    let mut interval = 60u64;
                    let mut desc = format!("Custom operator job: {}", file_stem);
                    let mut enabled = true;
                    let mut publish_social = false;
                    let mut publish_x = false;
                    let mut publish_mastodon = false;
                    let mut publish_bluesky = false;

                    for line in script.lines() {
                        let trimmed = line.trim();
                        if trimmed.starts_with("# INTERVAL:") {
                            if let Some(val_str) = trimmed.strip_prefix("# INTERVAL:") {
                                if let Ok(parsed) = val_str.trim().parse::<u64>() {
                                    interval = parsed;
                                }
                            }
                        } else if trimmed.starts_with("# DESC:") {
                            if let Some(d) = trimmed.strip_prefix("# DESC:") {
                                desc = d.trim().to_string();
                            }
                        } else if trimmed.starts_with("# ENABLED:") {
                            if let Some(val_str) = trimmed.strip_prefix("# ENABLED:") {
                                let val_str = val_str.trim();
                                enabled = val_str != "0" && val_str != "false";
                            }
                        } else if trimmed.starts_with("# PUBLISH_SOCIAL:") {
                            publish_social = trimmed.contains(": 1");
                        } else if trimmed.starts_with("# PUBLISH_X:") {
                            publish_x = trimmed.contains(": 1");
                        } else if trimmed.starts_with("# PUBLISH_MASTODON:") {
                            publish_mastodon = trimmed.contains(": 1");
                        } else if trimmed.starts_with("# PUBLISH_BLUESKY:") {
                            publish_bluesky = trimmed.contains(": 1");
                        }
                    }

                    let job_state = state_json.get("jobs").and_then(|j| j.get(&file_stem));
                    let last_run = job_state.and_then(|s| s.get("last_run")).and_then(|v| v.as_u64()).unwrap_or(0);
                    let exit_code = job_state.and_then(|s| s.get("exit_code")).and_then(|v| v.as_i64()).unwrap_or(0);
                    let updated_at = job_state.and_then(|s| s.get("updated_at")).and_then(|v| v.as_str()).unwrap_or("Never").to_string();

                    if disabled_jobs.contains(&file_stem) || job_state.and_then(|s| s.get("enabled")).and_then(|v| v.as_bool()) == Some(false) {
                        enabled = false;
                    }

                    jobs.push(json!({
                        "name": file_stem,
                        "interval": interval,
                        "description": desc,
                        "is_system": false,
                        "enabled": enabled,
                        "command": script,
                        "last_run": last_run,
                        "exit_code": exit_code,
                        "updated_at": updated_at,
                        "publish_social": publish_social,
                        "publish_x": publish_x,
                        "publish_mastodon": publish_mastodon,
                        "publish_bluesky": publish_bluesky,
                    }));
                }
            }
        }
    }

    let daemon_pid = fs::read_to_string(state.george_dir.join(".cron.pid")).await.ok()
        .and_then(|s| s.trim().parse::<u32>().ok());
    let daemon_running = match daemon_pid {
        Some(pid) => {
            std::process::Command::new("kill")
                .args(["-0", &pid.to_string()])
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        }
        None => false,
    };

    Json(json!({
        "status": "ok",
        "daemon_running": daemon_running,
        "daemon_pid": daemon_pid,
        "jobs": jobs,
    }))
}

async fn save_cron_job(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CronJobPayload>,
) -> impl IntoResponse {
    let clean_name = payload.name.trim().replace(|c: char| !c.is_alphanumeric() && c != '_', "_");
    if clean_name.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Invalid job name" }))).into_response();
    }

    if payload.is_system.unwrap_or(false) {
        let conf_key = match clean_name.as_str() {
            "sentinel_sweep" => "CRON_INTERVAL_SENTINEL",
            "pr_sweep" => "CRON_INTERVAL_PR",
            "issue_sweep" => "CRON_INTERVAL_ISSUE",
            "discord_sweep" => "CRON_INTERVAL_DISCORD",
            "email_sweep" => "CRON_INTERVAL_EMAIL",
            "x_social_sweep" => "CRON_INTERVAL_X",
            "mastodon_sweep" => "CRON_INTERVAL_MASTODON",
            _ => "",
        };

        if !conf_key.is_empty() {
            let conf_file = state.george_dir.join("cron.conf");
            let existing = fs::read_to_string(&conf_file).await.unwrap_or_default();
            let new_line = format!("{}={}", conf_key, payload.interval);
            let mut found = false;
            let mut updated_lines = Vec::new();
            for line in existing.lines() {
                if line.trim().starts_with(conf_key) {
                    updated_lines.push(new_line.clone());
                    found = true;
                } else {
                    updated_lines.push(line.to_string());
                }
            }
            if !found {
                updated_lines.push(new_line);
            }
            let _ = fs::write(&conf_file, updated_lines.join("\n") + "\n").await;
        }

        return Json(json!({ "status": "ok", "name": clean_name, "is_system": true })).into_response();
    }

    let custom_dir = state.george_dir.join("cron_jobs");
    let _ = fs::create_dir_all(&custom_dir).await;
    let target_file = custom_dir.join(format!("{}.sh", clean_name));

    let desc = payload.description.unwrap_or_else(|| format!("Custom job: {}", clean_name));
    let script_body = if payload.command.starts_with("#!") {
        payload.command
    } else {
        format!(
            "#!/bin/bash\n# INTERVAL: {}\n# DESC: {}\n# CREATED: {}\n\n{}\n",
            payload.interval,
            desc,
            chrono_utc_now(),
            payload.command
        )
    };

    if let Ok(_) = fs::write(&target_file, &script_body).await {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o755);
            let _ = std::fs::set_permissions(&target_file, perms);
        }
        Json(json!({ "status": "ok", "name": clean_name, "file": target_file.to_string_lossy() })).into_response()
    } else {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": "Failed to write job script" }))).into_response()
    }
}

async fn run_cron_job(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> impl IntoResponse {
    let clean_name = name.replace(|c: char| !c.is_alphanumeric() && c != '_', "");
    let lodge_dir = state.lodge_dir.clone();
    let job_name = clean_name.clone();

    tokio::spawn(async move {
        let script = lodge_dir.join("commands").join("cron.sh");
        let _ = tokio::process::Command::new("bash")
            .arg(&script)
            .arg("run")
            .arg(&job_name)
            .current_dir(&lodge_dir)
            .output()
            .await;
    });

    Json(json!({ "status": "triggered", "job": clean_name }))
}

async fn delete_cron_job(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> impl IntoResponse {
    let clean_name = name.replace(|c: char| !c.is_alphanumeric() && c != '_', "");
    let target = state.george_dir.join("cron_jobs").join(format!("{}.sh", clean_name));
    if target.exists() {
        let _ = fs::remove_file(&target).await;
        Json(json!({ "status": "deleted", "job": clean_name })).into_response()
    } else {
        (StatusCode::NOT_FOUND, Json(json!({ "error": "Job not found" }))).into_response()
    }
}

#[derive(Deserialize)]
struct TogglePlatformPayload {
    platform: String,
    enabled: bool,
}

async fn toggle_cron_platform(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    Json(payload): Json<TogglePlatformPayload>,
) -> impl IntoResponse {
    let clean_name = name.replace(|c: char| !c.is_alphanumeric() && c != '_', "");
    let script_path = state.george_dir.join("cron_jobs").join(format!("{}.sh", clean_name));
    if !script_path.exists() {
        return (StatusCode::NOT_FOUND, Json(json!({ "error": "Job script not found" }))).into_response();
    }

    if let Ok(content) = fs::read_to_string(&script_path).await {
        let plat_key = match payload.platform.to_lowercase().as_str() {
            "x" | "twitter" => "PUBLISH_X",
            "masto" | "mastodon" => "PUBLISH_MASTODON",
            "bsky" | "bluesky" => "PUBLISH_BLUESKY",
            "social" => "PUBLISH_SOCIAL",
            _ => return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Unknown platform" }))).into_response(),
        };

        let env_key = match plat_key {
            "PUBLISH_X" => "AUTONOMIC_PUBLISH_X",
            "PUBLISH_MASTODON" => "AUTONOMIC_PUBLISH_MASTODON",
            "PUBLISH_BLUESKY" => "AUTONOMIC_PUBLISH_BLUESKY",
            "PUBLISH_SOCIAL" => "AUTONOMIC_PUBLISH_SOCIAL",
            _ => "",
        };

        let val_num = if payload.enabled { "1" } else { "0" };
        let mut new_lines = Vec::new();
        let mut found_hdr = false;

        for line in content.lines() {
            if line.trim().starts_with(&format!("# {}:", plat_key)) {
                new_lines.push(format!("# {}: {}", plat_key, val_num));
                found_hdr = true;
            } else if !env_key.is_empty() && line.trim().starts_with(&format!("export {}=", env_key)) {
                new_lines.push(format!("export {}=\"${{{}:-${{_hdr_{}:-{}}}}}\"", env_key, env_key, payload.platform.to_lowercase(), val_num));
            } else {
                new_lines.push(line.to_string());
            }
        }

        if !found_hdr {
            let mut inserted = false;
            let mut final_lines = Vec::new();
            for l in &new_lines {
                final_lines.push(l.clone());
                if !inserted && l.starts_with("# DESC:") {
                    final_lines.push(format!("# {}: {}", plat_key, val_num));
                    inserted = true;
                }
            }
            if !inserted {
                final_lines.insert(1, format!("# {}: {}", plat_key, val_num));
            }
            new_lines = final_lines;
        }

        let _ = fs::write(&script_path, new_lines.join("\n") + "\n").await;
        Json(json!({ "status": "ok", "job": clean_name, "platform": payload.platform, "enabled": payload.enabled })).into_response()
    } else {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": "Failed to read job script" }))).into_response()
    }
}

async fn toggle_cron_enabled(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> impl IntoResponse {
    let clean_name = name.replace(|c: char| !c.is_alphanumeric() && c != '_', "");
    let lodge_dir = state.lodge_dir.clone();
    let job_name = clean_name.clone();

    let script = lodge_dir.join("commands").join("cron.sh");
    let output = tokio::process::Command::new("bash")
        .arg(&script)
        .arg("toggle")
        .arg(&job_name)
        .current_dir(&lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let out_str = String::from_utf8_lossy(&out.stdout).to_string();
            let is_enabled = !out_str.contains("disabled");
            Json(json!({
                "status": "ok",
                "job": clean_name,
                "enabled": is_enabled,
                "output": out_str.trim()
            })).into_response()
        }
        Err(e) => {
            (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": format!("Failed to toggle cron job: {}", e) }))).into_response()
        }
    }
}

#[derive(Deserialize)]
struct ToggleSocialGatePayload {
    target: String,
    enabled: bool,
}

async fn get_social_gate(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let conf_path = state.george_dir.join("social").join("social.conf");
    let mut global_enabled = false;
    let mut x_enabled = false;
    let mut mastodon_enabled = false;
    let mut bluesky_enabled = false;

    if let Ok(content) = fs::read_to_string(&conf_path).await {
        for line in content.lines() {
            let line = line.trim();
            if line.starts_with("GLOBAL_SOCIAL_ENABLED=") {
                global_enabled = line.ends_with("=1");
            } else if line.starts_with("X_ENABLED=") {
                x_enabled = line.ends_with("=1");
            } else if line.starts_with("MASTODON_ENABLED=") {
                mastodon_enabled = line.ends_with("=1");
            } else if line.starts_with("BLUESKY_ENABLED=") {
                bluesky_enabled = line.ends_with("=1");
            }
        }
    }

    Json(json!({
        "global_enabled": global_enabled,
        "x_enabled": x_enabled,
        "mastodon_enabled": mastodon_enabled,
        "bluesky_enabled": bluesky_enabled,
    }))
}

async fn toggle_social_gate(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ToggleSocialGatePayload>,
) -> impl IntoResponse {
    let conf_dir = state.george_dir.join("social");
    let _ = fs::create_dir_all(&conf_dir).await;
    let conf_path = conf_dir.join("social.conf");

    let mut global_enabled = false;
    let mut x_enabled = false;
    let mut mastodon_enabled = false;
    let mut bluesky_enabled = false;

    if let Ok(content) = fs::read_to_string(&conf_path).await {
        for line in content.lines() {
            let line = line.trim();
            if line.starts_with("GLOBAL_SOCIAL_ENABLED=") {
                global_enabled = line.ends_with("=1");
            } else if line.starts_with("X_ENABLED=") {
                x_enabled = line.ends_with("=1");
            } else if line.starts_with("MASTODON_ENABLED=") {
                mastodon_enabled = line.ends_with("=1");
            } else if line.starts_with("BLUESKY_ENABLED=") {
                bluesky_enabled = line.ends_with("=1");
            }
        }
    }

    match payload.target.to_lowercase().as_str() {
        "global" | "all" => global_enabled = payload.enabled,
        "x" | "twitter" => x_enabled = payload.enabled,
        "mastodon" | "masto" => mastodon_enabled = payload.enabled,
        "bluesky" | "bsky" => bluesky_enabled = payload.enabled,
        _ => return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Unknown target" }))).into_response(),
    }

    let conf_content = format!(
        "# George Global Social Endpoints Configuration\nGLOBAL_SOCIAL_ENABLED={}\nX_ENABLED={}\nMASTODON_ENABLED={}\nBLUESKY_ENABLED={}\n",
        if global_enabled { "1" } else { "0" },
        if x_enabled { "1" } else { "0" },
        if mastodon_enabled { "1" } else { "0" },
        if bluesky_enabled { "1" } else { "0" },
    );

    let _ = fs::write(&conf_path, conf_content).await;

    // Synchronize research_publisher.sh headers if present
    let publisher_path = state.george_dir.join("cron_jobs").join("research_publisher.sh");
    if publisher_path.exists() {
        if let Ok(content) = fs::read_to_string(&publisher_path).await {
            let mut new_lines = Vec::new();
            for line in content.lines() {
                if line.trim().starts_with("# PUBLISH_SOCIAL:") {
                    new_lines.push(format!("# PUBLISH_SOCIAL: {}", if global_enabled { "1" } else { "0" }));
                } else if line.trim().starts_with("# PUBLISH_X:") {
                    new_lines.push(format!("# PUBLISH_X: {}", if x_enabled { "1" } else { "0" }));
                } else if line.trim().starts_with("# PUBLISH_MASTODON:") {
                    new_lines.push(format!("# PUBLISH_MASTODON: {}", if mastodon_enabled { "1" } else { "0" }));
                } else if line.trim().starts_with("# PUBLISH_BLUESKY:") {
                    new_lines.push(format!("# PUBLISH_BLUESKY: {}", if bluesky_enabled { "1" } else { "0" }));
                } else {
                    new_lines.push(line.to_string());
                }
            }
            let _ = fs::write(&publisher_path, new_lines.join("\n") + "\n").await;
        }
    }

    Json(json!({
        "status": "ok",
        "global_enabled": global_enabled,
        "x_enabled": x_enabled,
        "mastodon_enabled": mastodon_enabled,
        "bluesky_enabled": bluesky_enabled,
    })).into_response()
}

async fn generate_cron_job(
    State(_state): State<Arc<AppState>>,
    Json(payload): Json<CronGeneratePayload>,
) -> impl IntoResponse {
    let prompt = payload.prompt.trim();
    if prompt.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Prompt cannot be empty" }))).into_response();
    }

    let req_body = json!({
        "model": "ternary-bonsai-27b",
        "messages": [
            {
                "role": "system",
                "content": "You are George's system architect. The user wants to schedule a cron job or autonomic task. Output a single JSON object with keys: name (short alphanumeric snake_case), interval (integer in seconds, e.g. 60, 300, 3600), description (short string), command (valid executable bash script). Do not output markdown fences or commentary, ONLY the raw JSON object."
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        "temperature": 0.2,
        "max_tokens": 500
    });

    if let Ok(res_val) = reqwest_lite_post("http://127.0.0.1:8080/v1/chat/completions", &req_body).await {
        if let Some(content) = res_val["choices"][0]["message"]["content"].as_str() {
            let clean = content.trim().trim_start_matches("```json").trim_start_matches("```").trim_end_matches("```").trim();
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(clean) {
                return Json(json!({ "status": "ok", "job": parsed })).into_response();
            }
        }
    }

    // Heuristic Fallback
    let p_lower = prompt.to_lowercase();
    let (name, interval, desc, cmd) = if p_lower.contains("git") || p_lower.contains("commit") {
        (
            "autonomic_git_sync".to_string(),
            1800u64,
            "Autonomously verify and snapshot dirty git state".to_string(),
            "git status --short\nif [ -n \"$(git status --porcelain)\" ]; then\n  git add -A\n  git commit -m \"chore(autonomic): sync progress $(date)\" || true\nfi".to_string(),
        )
    } else if p_lower.contains("prune") || p_lower.contains("clean") || p_lower.contains("disk") {
        (
            "sandboxes_prune".to_string(),
            3600u64,
            "Prune transient sandboxes and stale web sessions older than 2 days".to_string(),
            "find .sandboxes -maxdepth 1 -name \"web_session*\" -mtime +2 -exec rm -rf {} +\ndf -h /home/wsl-ops/blue-lodge | tail -1".to_string(),
        )
    } else if p_lower.contains("health") || p_lower.contains("ping") || p_lower.contains("vitals") {
        (
            "inference_health_probe".to_string(),
            120u64,
            "Probe primary and secondary inference cluster endpoints".to_string(),
            "curl -s -f http://127.0.0.1:8080/health > /dev/null && echo \"Tier 1 OK\" || echo \"Tier 1 Unreachable\"".to_string(),
        )
    } else {
        let slug: String = prompt
            .chars()
            .take(24)
            .map(|c| if c.is_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
            .collect();
        let slug = slug.trim_matches('_').to_string();
        let final_slug = if slug.is_empty() { "custom_sweep".to_string() } else { slug };
        (
            final_slug,
            300u64,
            prompt.to_string(),
            format!("# Scheduled task: {}\necho \"Executing scheduled sweep at $(date)\"\n", prompt),
        )
    };

    Json(json!({
        "status": "ok",
        "job": {
            "name": name,
            "interval": interval,
            "description": desc,
            "command": cmd
        }
    })).into_response()
}

async fn start_cron_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/cron.sh' && cron_start", state.lodge_dir.display()))
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

async fn stop_cron_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/cron.sh' && cron_stop", state.lodge_dir.display()))
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

async fn restart_cron_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/cron.sh' && cron_stop && sleep 1 && cron_start", state.lodge_dir.display()))
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

async fn read_last_lines(sandbox: &PathBuf, max_lines: usize) -> Vec<String> {
    if let Some(log_path) = find_trajectory_log(sandbox).await {
        if let Ok(content) = fs::read_to_string(log_path).await {
            let lines: Vec<String> = content.lines().rev().take(max_lines).map(String::from).collect();
            return lines.into_iter().rev().collect();
        }
    }
    Vec::new()
}

// ── Session Ledger Persistence ────────────────────────────────────────

async fn get_session(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let session_file = state.george_dir.join("workspaces").join("web_session.jsonl");
    let mut messages = Vec::new();

    if let Ok(content) = fs::read_to_string(&session_file).await {
        for line in content.lines() {
            if let Ok(mut val) = serde_json::from_str::<serde_json::Value>(line) {
                if let Some(c) = val.get("content").and_then(|v| v.as_str()) {
                    val["content"] = json!(strip_ansi(c));
                }
                messages.push(val);
            }
        }
    }

    Json(json!({
        "status": "ok",
        "messages": messages,
    }))
}

async fn clear_session(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let session_file = state.george_dir.join("workspaces").join("web_session.jsonl");
    if let Ok(content) = fs::read_to_string(&session_file).await {
        if !content.trim().is_empty() {
            let trans_dir = state.george_dir.join("transcripts");
            let _ = fs::create_dir_all(&trans_dir).await;
            let archive_file = trans_dir.join(format!("web_session_{}.md", chrono_epoch_secs()));
            let _ = fs::write(&archive_file, &content).await;
        }
    }
    let _ = fs::write(&session_file, "").await;
    Json(json!({ "status": "cleared" }))
}

async fn append_session_message(george_dir: &PathBuf, msg: &serde_json::Value) {
    let ws_dir = george_dir.join("workspaces");
    let _ = fs::create_dir_all(&ws_dir).await;
    let session_file = ws_dir.join("web_session.jsonl");
    let line = format!("{}\n", msg.to_string());
    if let Ok(mut f) = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&session_file)
        .await
    {
        use tokio::io::AsyncWriteExt;
        let _ = f.write_all(line.as_bytes()).await;
    }
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_escape = false;
    for c in s.chars() {
        if c == '\x1b' {
            in_escape = true;
        } else if in_escape {
            if c.is_ascii_alphabetic() {
                in_escape = false;
            }
        } else {
            out.push(c);
        }
    }
    out
}

async fn execute_chat_tool(lodge_dir: &PathBuf, name: &str, args: &serde_json::Value) -> String {
    match name {
        "web_fetch" => {
            let url = args.get("url").and_then(|v| v.as_str()).unwrap_or("").trim();
            if url.is_empty() {
                return "Error: URL is required".into();
            }
            let lodge_str = lodge_dir.to_string_lossy();
            let cmd_str = format!("source '{}/lib/web.sh' 2>/dev/null; web_fetch '{}'", lodge_str, url.replace('\'', "'\\''"));
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
            let cmd_str = format!("source '{}/lib/web.sh' 2>/dev/null; web_search '{}' {}", lodge_str, q.replace('\'', "'\\''"), count);
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
                Err(e) => format!("Error listing directory: {}", e),
            }
        }
        "recall_query" => {
            let q = args.get("query").and_then(|v| v.as_str()).unwrap_or("").trim();
            if q.is_empty() {
                return "Error: query is required".into();
            }
            let lodge_str = lodge_dir.to_string_lossy();
            let cmd_str = format!("source '{}/lib/recall.sh' 2>/dev/null; recall_search_context '{}' 2>/dev/null", lodge_str, q.replace('\'', "'\\''"));
            let out = tokio::process::Command::new("bash")
                .args(["-c", &cmd_str])
                .current_dir(lodge_dir)
                .output()
                .await;
            match out {
                Ok(res) => {
                    let s = String::from_utf8_lossy(&res.stdout);
                    if s.trim().is_empty() { "No relevant recalled memories found.".into() } else { s.to_string() }
                }
                Err(e) => format!("Error querying memory recall: {}", e),
            }
        }
        _ => format!("Tool '{}' is not supported in Chat Mode.", name),
    }
}

#[derive(Deserialize, Debug)]
struct ChatPrompt {
    prompt: Option<String>,
    message: Option<String>,
    command: Option<String>,
    session_id: Option<String>,
    mode: Option<String>,
}

async fn post_chat(
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

    if raw_cmd.is_empty() {
        return Json(json!({ "status": "error", "error": "Empty prompt" }));
    }

    // Record user message to session ledger with unique ID
    let user_msg_id = format!("u_{}", chrono_epoch_secs());
    let user_msg = json!({
        "id": user_msg_id.clone(),
        "role": "user",
        "content": raw_cmd,
        "mode": mode,
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &user_msg).await;

    // Check if it's an explicit slash command
    if raw_cmd.starts_with('/') {
        let lodge_bin = state.lodge_dir.join("lodge");
        let cmd_copy = raw_cmd.clone();
        let lodge_dir_copy = state.lodge_dir.clone();

        // Run slash command synchronously
        let out = tokio::process::Command::new(lodge_bin)
            .args([&cmd_copy])
            .current_dir(lodge_dir_copy)
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

        let assistant_msg = json!({
            "id": format!("a_{}", chrono_epoch_secs()),
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
            "type": "command_blueprint",
            "reply": output_text,
        }));
    }

    // Agentic Mode: Spawns George with full ReAct loop and bedrock tools
    if mode == "agentic" {
        let lodge_bin = state.lodge_dir.join("lodge");
        let cmd_copy = raw_cmd.clone();
        let lodge_dir_copy = state.lodge_dir.clone();

        let out = tokio::process::Command::new(lodge_bin)
            .args([&cmd_copy])
            .current_dir(lodge_dir_copy)
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

        let assistant_msg = json!({
            "id": format!("a_{}", chrono_epoch_secs()),
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
            "mode": "agentic",
            "type": "agentic",
            "reply": output_text,
        }));
    }

    // Plan-Task Mode: Routes through the-architect workflow to grill requirements and draft contract
    if mode == "plan-task" {
        let lodge_bin = state.lodge_dir.join("lodge");
        let plan_arg = format!("/workflow run the-architect.agent {}", raw_cmd);
        let lodge_dir_copy = state.lodge_dir.clone();

        let out = tokio::process::Command::new(lodge_bin)
            .args([&plan_arg])
            .current_dir(lodge_dir_copy)
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

        let assistant_msg = json!({
            "id": format!("a_{}", chrono_epoch_secs()),
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
            "mode": "plan-task",
            "type": "plan-task",
            "reply": output_text,
        }));
    }

    // Chat Mode: multi-turn conversational inference with safe read-only tools and Washington/Franklin persona
    let session_file = state.george_dir.join("workspaces").join("web_session.jsonl");
    let mut history_messages: Vec<serde_json::Value> = Vec::new();
    if let Ok(content) = fs::read_to_string(&session_file).await {
        for line in content.lines() {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
                if let Some(id) = val.get("id").and_then(|v| v.as_str()) {
                    if id == user_msg_id {
                        continue;
                    }
                }
                let role = val.get("role").and_then(|v| v.as_str()).unwrap_or("");
                let c = val.get("content").and_then(|v| v.as_str()).unwrap_or("");
                if (role == "user" || role == "assistant") && !c.trim().is_empty() {
                    history_messages.push(json!({
                        "role": role,
                        "content": strip_ansi(c),
                    }));
                }
            }
        }
    }

    let history_slice = if history_messages.len() > 24 {
        &history_messages[history_messages.len() - 24..]
    } else {
        &history_messages[..]
    };

    let sys_prompt = "You are George, a thoughtful and grounded digital craftsman carrying the discipline of Washington, the wit of Franklin, and the precision of Adam Smith. Respond with quiet competence, intellectual dignity, and direct clarity without sci-fi tropes or fluff. You possess safe read-only tools to browse or fetch the web (web_search, web_fetch), inspect the workspace repository (file_read, file_grep, dir_list), query historical recall memory (recall_query), and check the current date/time (datetime_now). If the operator shares a URL, asks for real-time information, or refers to code/files, use your tools directly to investigate before answering.";

    let mut messages: Vec<serde_json::Value> = Vec::new();
    messages.push(json!({ "role": "system", "content": sys_prompt }));
    for m in history_slice {
        messages.push(m.clone());
    }
    messages.push(json!({ "role": "user", "content": raw_cmd }));

    let chat_tools = json!([
        {
            "type": "function",
            "function": {
                "name": "web_fetch",
                "description": "Fetch and extract readable text/markdown from an HTTP or HTTPS web URL. Use this when the user shares a link or asks you to check a webpage.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "url": { "type": "string", "description": "The web URL to fetch (HTTP/HTTPS)." }
                    },
                    "required": ["url"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "web_search",
                "description": "Search the live web for factual information, current events, or references.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": { "type": "string", "description": "Search query keywords." },
                        "count": { "type": "integer", "description": "Number of results to return (default 5, max 10)." }
                    },
                    "required": ["query"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "file_read",
                "description": "Read lines from a workspace file (read-only inspection).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": { "type": "string", "description": "Relative file path from project root." },
                        "start_line": { "type": "integer", "description": "Starting line number (1-indexed, default 1)." },
                        "max_lines": { "type": "integer", "description": "Number of lines to read (default 100, max 200)." }
                    },
                    "required": ["path"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "file_grep",
                "description": "Search for a regex or text pattern in files (read-only).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pattern": { "type": "string", "description": "Search pattern or query." },
                        "path": { "type": "string", "description": "Subdirectory or file to search (default \".\")." }
                    },
                    "required": ["pattern"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "dir_list",
                "description": "List files and directories in a given path (read-only).",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "path": { "type": "string", "description": "Relative directory path (default \".\")." }
                    }
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "datetime_now",
                "description": "Get current local date, time, and timezone.",
                "parameters": { "type": "object", "properties": {} }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "recall_query",
                "description": "Query George's historical memory, journal reflections, and indexed knowledge base.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": { "type": "string", "description": "Search query for memory recall." }
                    },
                    "required": ["query"]
                }
            }
        }
    ]);

    let mut reply_text = String::new();
    let max_react_turns = 5;

    for _ in 0..max_react_turns {
        let payload_body = json!({
            "messages": messages,
            "tools": chat_tools,
            "temperature": 0.4,
            "max_tokens": 2048,
            "reasoning_effort": "medium",
        });

        let llm_res = tokio::process::Command::new("curl")
            .args([
                "-s",
                "--max-time", "60",
                "http://127.0.0.1:8080/v1/chat/completions",
                "-H", "Content-Type: application/json",
                "-d", &payload_body.to_string(),
            ])
            .output()
            .await;

        let mut turn_choice = None;
        if let Ok(out) = llm_res {
            if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&out.stdout) {
                if let Some(choices) = val["choices"].as_array() {
                    if let Some(choice) = choices.get(0) {
                        turn_choice = Some(choice.clone());
                    }
                }
            }
        }

        let Some(choice) = turn_choice else {
            break;
        };

        let message = choice["message"].clone();
        let content = message.get("content").and_then(|s| s.as_str()).unwrap_or("");
        let reasoning = message.get("reasoning_content").and_then(|s| s.as_str()).unwrap_or("");
        let tool_calls = message.get("tool_calls").and_then(|t| t.as_array());

        if let Some(calls) = tool_calls {
            if !calls.is_empty() {
                // Assistant requested tool invocation
                messages.push(message.clone());
                for call in calls {
                    let call_id = call.get("id").and_then(|v| v.as_str()).unwrap_or("call_0");
                    let func_name = call.get("function").and_then(|f| f.get("name")).and_then(|n| n.as_str()).unwrap_or("");
                    let func_args_str = call.get("function").and_then(|f| f.get("arguments")).and_then(|a| a.as_str()).unwrap_or("{}");
                    let func_args: serde_json::Value = serde_json::from_str(func_args_str).unwrap_or(json!({}));

                    let tool_output = execute_chat_tool(&state.lodge_dir, func_name, &func_args).await;

                    messages.push(json!({
                        "role": "tool",
                        "tool_call_id": call_id,
                        "name": func_name,
                        "content": tool_output,
                    }));
                }
                continue;
            }
        }

        if !content.trim().is_empty() {
            reply_text = content.to_string();
        } else if !reasoning.trim().is_empty() {
            reply_text = reasoning.to_string();
        }
        break;
    }

    if reply_text.is_empty() {
        reply_text = "I am at your service at the workbench. What shall we measure or construct?".into();
    }

    let assistant_msg = json!({
        "id": format!("a_{}", chrono_epoch_secs()),
        "role": "assistant",
        "type": "chat",
        "content": reply_text,
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &assistant_msg).await;

    Json(json!({
        "status": "ok",
        "session_id": sess_id,
        "type": "chat",
        "reply": reply_text,
    }))
}

#[derive(Deserialize, Debug)]
struct DispatchPayload {
    contract: Option<String>,
}

async fn post_dispatch(
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

#[derive(Deserialize, Debug)]
struct TaskInputPayload {
    input: String,
}

async fn post_task_input(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(payload): Json<TaskInputPayload>,
) -> impl IntoResponse {
    let fifo_path = state.george_dir.join("telemetry/active").join(format!("{}.in", id));
    if let Ok(mut file) = tokio::fs::OpenOptions::new().write(true).open(&fifo_path).await {
        let _ = file.write_all(payload.input.as_bytes()).await;
        let _ = file.write_all(b"\n").await;
        Json(json!({ "status": "ok", "message": "Input sent to task" }))
    } else {
        let fallback_path = state.george_dir.join("telemetry/active").join(format!("{}.input", id));
        let _ = tokio::fs::write(&fallback_path, format!("{}\n", payload.input)).await;
        Json(json!({ "status": "ok", "message": "Input queued for task" }))
    }
}

#[derive(Deserialize, Debug)]
struct CopilotChatPayload {
    file_path: String,
    file_content: String,
    selection: Option<String>,
    instruction: String,
    session_id: Option<String>,
    task_id: Option<String>,
}

async fn post_copilot_chat(
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

    let sandbox_dir = state.lodge_dir.join(".sandboxes").join(&task_id);
    let _ = fs::create_dir_all(&sandbox_dir).await;
    let _ = fs::write(sandbox_dir.join(".phase"), "Internal Monologue & Reasoning").await;

    let meta = json!({
        "id": task_id,
        "type": "copilot",
        "file_path": file_path,
        "instruction": instruction,
        "started_at": chrono_utc_now(),
    });
    let _ = fs::write(sandbox_dir.join("task_meta.json"), serde_json::to_string_pretty(&meta).unwrap_or_default()).await;

    let traj_file = sandbox_dir.join("trajectory.log");
    let init_traj = format!(
        "── [AUTONOMIC TASK INITIALIZED: {}] ──\n[FILE TARGET]: {}\n[INSTRUCTION]: {}\n[PHASE]: Internal Monologue & Reasoning\n── GEORGE INTERNAL REASONING MONOLOGUE ──\n",
        task_id, file_path, instruction
    );
    let _ = fs::write(&traj_file, &init_traj).await;

    let user_msg = json!({
        "id": format!("u_{}", chrono_epoch_secs()),
        "role": "user",
        "type": "copilot",
        "task_id": task_id,
        "file_path": file_path,
        "content": instruction,
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &user_msg).await;

    let sys_prompt = "You are George Co-Pilot, an elite software craftsman and pair programming companion. \
The operator is editing a file in the Craftsman Workbench. \
Review the provided file context and user request. \
Respond with quiet competence and precision. \
If proposing edits, provide: \
1. A concise explanation (1-2 sentences) of what changed and why. \
2. The complete updated file content or modified function inside a markdown code fence (```bash, ```python, ```rust, etc.). \
Keep prose direct, technical, and free of filler.";

    let selection_ctx = payload.selection.as_ref()
        .filter(|s| !s.trim().is_empty())
        .map(|s| format!("\nUSER SELECTED CODE:\n```\n{}\n```\n", s))
        .unwrap_or_default();

    let user_prompt = format!(
        "FILE: {}\n\nCURRENT CONTENT:\n```\n{}\n```\n{}\nUSER REQUEST: {}",
        file_path,
        payload.file_content,
        selection_ctx,
        instruction
    );

    let payload_body = json!({
        "messages": [
            { "role": "system", "content": sys_prompt },
            { "role": "user", "content": user_prompt }
        ],
        "temperature": 0.2,
        "max_tokens": 4096,
        "stream": true,
    });

    let mut cmd = tokio::process::Command::new("curl");
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
                // Check if task was aborted by operator via /api/task/:id/abort
                if sandbox_dir.join(".abort").exists() {
                    let _ = child.kill().await;
                    aborted = true;
                    break;
                }

                // Check pause requested via /api/task/:id/pause
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
                            // Check reasoning_content
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
                            // Check content
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

    // Search for code block in reply_text, falling back to reasoning_text if needed
    let text_to_search = if reply_text.contains("```") { &reply_text } else { &reasoning_text };
    let mut proposed_code = None;
    let mut explanation = reply_text.clone();

    if let Some(start_idx) = text_to_search.find("```") {
        explanation = text_to_search[..start_idx].trim().to_string();
        let after_fence = &text_to_search[start_idx + 3..];
        if let Some(newline_idx) = after_fence.find('\n') {
            let code_body = &after_fence[newline_idx + 1..];
            if let Some(end_idx) = code_body.find("```") {
                proposed_code = Some(code_body[..end_idx].trim_end().to_string());
            } else {
                proposed_code = Some(code_body.trim_end().to_string());
            }
        }
    }

    if explanation.is_empty() {
        explanation = if proposed_code.is_some() {
            "I have refactored the file according to your instructions.".to_string()
        } else {
            reply_text.clone()
        };
    }

    let has_edit = proposed_code.is_some();
    let assistant_msg = json!({
        "id": format!("a_{}", chrono_epoch_secs()),
        "role": "assistant",
        "type": "copilot",
        "task_id": task_id,
        "file_path": file_path,
        "content": reply_text,
        "reasoning": reasoning_text,
        "has_edit": has_edit,
        "timestamp": chrono_utc_now(),
    });
    append_session_message(&state.george_dir, &assistant_msg).await;

    Json(json!({
        "status": "ok",
        "task_id": task_id,
        "session_id": sess_id,
        "reply": reply_text,
        "reasoning": reasoning_text,
        "explanation": explanation,
        "has_edit": has_edit,
        "proposed_code": proposed_code,
    })).into_response()
}

// ── Task Steering Handlers ────────────────────────────────────────────

async fn pause_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = state.lodge_dir.join(".sandboxes").join(&clean_id);
    let pause_file = sandbox.join(".pause_requested");
    let _ = fs::write(&pause_file, "1").await;
    Json(json!({ "status": "paused", "id": clean_id }))
}

async fn resume_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = state.lodge_dir.join(".sandboxes").join(&clean_id);
    let pause_file = sandbox.join(".pause_requested");
    let _ = fs::remove_file(&pause_file).await;
    Json(json!({ "status": "resumed", "id": clean_id }))
}

#[derive(Deserialize)]
struct InjectPayload {
    guidance: String,
}

async fn inject_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(payload): Json<InjectPayload>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = state.lodge_dir.join(".sandboxes").join(&clean_id);
    let steer_file = sandbox.join("operator_guidance.md");
    let entry = format!("\n\n### Operator Guidance [{}]:\n{}\n", chrono_utc_now(), payload.guidance);
    
    use tokio::io::AsyncWriteExt;
    if let Ok(mut f) = tokio::fs::OpenOptions::new().create(true).append(true).open(&steer_file).await {
        let _ = f.write_all(entry.as_bytes()).await;
    }
    let traj_file = sandbox.join("trajectory.log");
    if let Ok(mut f) = tokio::fs::OpenOptions::new().create(true).append(true).open(&traj_file).await {
        let _ = f.write_all(format!("\n[OPERATOR INJECTED GUIDANCE]: {}\n", payload.guidance).as_bytes()).await;
    }
    Json(json!({ "status": "injected", "id": clean_id }))
}

async fn abort_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let clean_id = id.replace("..", "").replace('/', "");

    if clean_id.starts_with("discord_") {
        let chan_id = clean_id.strip_prefix("discord_").unwrap_or(&clean_id);
        let pid_file = state.george_dir.join("discord_sessions").join(format!("session_{}.pid", chan_id));
        if let Some(pid) = read_pid_from_file(&pid_file) {
            kill_process_tree(pid);
        }
        let _ = fs::remove_file(&pid_file).await;
        return Json(json!({ "status": "aborted", "id": clean_id }));
    }

    if clean_id == "autonomic_sentinel" {
        let pid_file = state.george_dir.join(".cron.pid");
        if let Some(pid) = read_pid_from_file(&pid_file) {
            kill_process_tree(pid);
        }
        let _ = fs::remove_file(&pid_file).await;
        return Json(json!({ "status": "aborted", "id": clean_id }));
    }

    if clean_id.starts_with("copilot_") {
        let sandbox = state.lodge_dir.join(".sandboxes").join(&clean_id);
        let pid_file = sandbox.join(".pid");
        if let Some(pid) = read_pid_from_file(&pid_file) {
            kill_process_tree(pid);
        }
        let _ = fs::write(sandbox.join(".abort"), "1").await;
        let _ = fs::write(sandbox.join(".done"), "1").await;
        let _ = fs::write(sandbox.join(".phase"), "Terminated by Operator").await;
        let traj_file = sandbox.join("trajectory.log");
        let _ = append_to_file(&traj_file, "\n[OPERATOR TERMINATED CODING TASK]\n").await;
        return Json(json!({ "status": "aborted", "id": clean_id }));
    }

    // Sandbox task abort: kill parent + child processes, clean worktree, rm sandbox dir, clear locks
    let sandbox = state.lodge_dir.join(".sandboxes").join(&clean_id);
    let pid_file = sandbox.join(".pid");
    if let Some(pid) = read_pid_from_file(&pid_file) {
        kill_process_tree(pid);
    }

    let _ = tokio::process::Command::new("git")
        .args(&["-C", &state.lodge_dir.to_string_lossy(), "worktree", "remove", "--force", &sandbox.to_string_lossy()])
        .output()
        .await;

    let _ = fs::remove_dir_all(&sandbox).await;

    let lock_file = state.lodge_dir.join(".lodge.lock");
    let _ = fs::remove_file(&lock_file).await;

    Json(json!({ "status": "aborted", "id": clean_id }))
}

async fn cull_tasks(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut culled = 0;

    // 1. Cull dead Discord sessions
    let discord_dir = state.george_dir.join("discord_sessions");
    if let Ok(mut entries) = fs::read_dir(&discord_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.extension().map_or(false, |ext| ext == "pid") {
                if let Some(pid) = read_pid_from_file(&p) {
                    if !is_pid_alive(pid) {
                        let _ = fs::remove_file(&p).await;
                        culled += 1;
                    }
                } else {
                    let _ = fs::remove_file(&p).await;
                    culled += 1;
                }
            }
        }
    }

    // 2. Cull dead Cron PID
    let cron_pid_file = state.george_dir.join(".cron.pid");
    if cron_pid_file.exists() {
        if let Some(pid) = read_pid_from_file(&cron_pid_file) {
            if !is_pid_alive(pid) {
                let _ = fs::remove_file(&cron_pid_file).await;
                culled += 1;
            }
        } else {
            let _ = fs::remove_file(&cron_pid_file).await;
            culled += 1;
        }
    }

    // 3. Cull stale sandboxes older than 5 minutes if done, or older than 15 minutes if dead
    let sandboxes_dir = state.lodge_dir.join(".sandboxes");
    let now = chrono_epoch_secs();
    if let Ok(mut entries) = fs::read_dir(&sandboxes_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.is_dir() {
                let done = p.join(".done").exists();
                let pid_file = p.join(".pid");
                let has_pid = pid_file.exists();
                let pid_alive = read_pid_from_file(&pid_file).map_or(false, is_pid_alive);

                let mtime = entry.metadata().await.ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);

                if !pid_alive || done || (!has_pid && now.saturating_sub(mtime) > 30) {
                    let _ = tokio::process::Command::new("git")
                        .args(&["-C", &state.lodge_dir.to_string_lossy(), "worktree", "remove", "--force", &p.to_string_lossy()])
                        .output()
                        .await;
                    let _ = fs::remove_dir_all(&p).await;
                    culled += 1;
                }
            }
        }
    }

    // 4. Stale lock cleanup
    let lock_file = state.lodge_dir.join(".lodge.lock");
    if lock_file.exists() {
        if let Some(pid) = read_pid_from_file(&lock_file) {
            if !is_pid_alive(pid) {
                let _ = fs::remove_file(&lock_file).await;
                culled += 1;
            }
        }
    }

    Json(json!({ "status": "ok", "culled_count": culled }))
}

async fn get_commands(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut list = Vec::new();
    let cmd_dir = state.lodge_dir.join("commands");
    if let Ok(mut entries) = fs::read_dir(&cmd_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.extension().map_or(false, |ext| ext == "sh") {
                let stem = p.file_stem().unwrap_or_default().to_string_lossy().to_string();
                let mut desc = String::new();
                let mut usage = format!("/{}", stem);

                if let Ok(content) = fs::read_to_string(&p).await {
                    for line in content.lines().take(25) {
                        let trimmed = line.trim();
                        if let Some(d) = trimmed.strip_prefix("# DESC:") {
                            desc = d.trim().to_string();
                        } else if let Some(u) = trimmed.strip_prefix("# Usage:") {
                            usage = u.trim().to_string();
                        }
                    }
                }

                if desc.is_empty() {
                    desc = format!("Execute /{} command", stem);
                }

                list.push(json!({
                    "name": stem,
                    "command": format!("/{}", stem),
                    "usage": usage,
                    "desc": desc,
                }));
            }
        }
    }

    list.sort_by(|a, b| a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or("")));
    Json(list)
}

#[derive(Deserialize)]
struct ResearchConfigPayload {
    candidate_topics: Vec<String>,
    directives: String,
    temperature: f64,
    max_tokens: u32,
    publish_social: bool,
}

async fn get_research_config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let conf_path = state.george_dir.join("research.conf");
    let mut topics = vec![
        "Low-rank matrix factorizations and loss landscapes in consumer GPU GEMM".into(),
        "Claude Shannon entropy bounds in calibrated 4-bit KV cache quantization".into(),
        "Continuous state-space models and selective state representations in edge compute".into(),
        "Memory-bandwidth thermodynamics and register scheduling in local inference".into(),
        "Next-generation reservoir computing and nonlinear vector autoregression".into(),
        "Sparse mixture-of-experts routing stability and expert collapse dynamics".into(),
        "Kernel fusion and SRAM occupancy optimization for flash attention on consumer Ada Lovelace".into(),
        "Hardware-software co-design for sub-1-bit ternary weight representations".into(),
    ];
    let mut directives = "Ground every section strictly in concrete equations, hardware bounds, benchmark metrics, and arXiv citations. Strictly forbid superficial filler.".into();
    let mut temperature = 0.3;
    let mut max_tokens = 4500;
    let mut publish_social = true;

    if let Ok(content) = fs::read_to_string(&conf_path).await {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&content) {
            if let Some(t) = parsed["candidate_topics"].as_array() {
                topics = t.iter().filter_map(|v| v.as_str().map(String::from)).collect();
            }
            if let Some(d) = parsed["directives"].as_str() {
                directives = d.to_string();
            }
            if let Some(temp) = parsed["temperature"].as_f64() {
                temperature = temp;
            }
            if let Some(mt) = parsed["max_tokens"].as_u64() {
                max_tokens = mt as u32;
            }
            if let Some(ps) = parsed["publish_social"].as_bool() {
                publish_social = ps;
            }
        }
    }

    Json(json!({
        "candidate_topics": topics,
        "directives": directives,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "publish_social": publish_social,
        "phases": [
            { "phase": 1, "name": "ReAct Sandbox Investigation", "desc": "Multi-turn ReAct search, arXiv PDF download, pdftotext extraction, vision diagram analysis" },
            { "phase": 2, "name": "Evidence Audit & Gap Analysis", "desc": "Citation density threshold gate (>2 verified sources) and PDF ingestion check" },
            { "phase": 3, "name": "Monograph Synthesis", "desc": "Authoring authoritative dossier.md grounded in equations, bounds, and benchmarks" },
            { "phase": 4, "name": "Editorial Critique & Revision", "desc": "Refinement pass eliminating speculative boilerplate and verifying technical consistency" },
            { "phase": 5, "name": "PGP Archival & Social Syndication", "desc": "Ed25519/PGP signature, research_index.jsonl registration, and Mastodon/Bluesky/X queueing" }
        ]
    }))
}

async fn save_research_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ResearchConfigPayload>,
) -> impl IntoResponse {
    let conf_path = state.george_dir.join("research.conf");
    let doc = json!({
        "candidate_topics": payload.candidate_topics,
        "directives": payload.directives,
        "temperature": payload.temperature,
        "max_tokens": payload.max_tokens,
        "publish_social": payload.publish_social,
        "updated_at": chrono_utc_now(),
    });

    if let Ok(serialized) = serde_json::to_string_pretty(&doc) {
        let _ = fs::write(&conf_path, serialized).await;
    }

    Json(json!({ "status": "saved" }))
}

// ── In-Browser File & Script Editor with Syntax Lint Gate ─────────────

fn normalize_path(path: &std::path::Path) -> PathBuf {
    use std::path::Component;
    let mut normalized = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::Prefix(p) => normalized.push(Component::Prefix(p)),
            Component::RootDir => normalized.push(Component::RootDir),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(c) => normalized.push(c),
        }
    }
    normalized
}

fn validate_bounded_path(
    candidate: &std::path::Path,
    state: &AppState,
    docked_path: &std::path::Path,
    allow_creation: bool,
) -> Result<PathBuf, (StatusCode, Json<serde_json::Value>)> {
    if candidate.to_string_lossy().contains('\0') {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({ "status": "error", "message": "Invalid path: null byte detected" })),
        ));
    }

    let canonical_lodge = state.lodge_dir.canonicalize().unwrap_or_else(|_| state.lodge_dir.clone());
    let canonical_george = state.george_dir.canonicalize().unwrap_or_else(|_| state.george_dir.clone());
    let canonical_docked = docked_path.canonicalize().unwrap_or_else(|_| docked_path.to_path_buf());

    // 1. Lexical normalization & strict prefix check (Defense layer 1)
    let norm = normalize_path(candidate);
    let allowed_lexical = norm.starts_with(&canonical_lodge)
        || norm.starts_with(&state.lodge_dir)
        || norm.starts_with(&canonical_george)
        || norm.starts_with(&state.george_dir)
        || norm.starts_with(&canonical_docked)
        || norm.starts_with(docked_path);

    if !allowed_lexical {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "status": "error", "message": "Access outside workspace denied" })),
        ));
    }

    // 2. Canonicalization check (Defense layer 2 - symlink resolution)
    if norm.exists() {
        match norm.canonicalize() {
            Ok(canonical) => {
                let allowed_canonical = canonical.starts_with(&canonical_lodge)
                    || canonical.starts_with(&canonical_george)
                    || canonical.starts_with(&canonical_docked);
                if allowed_canonical {
                    Ok(canonical)
                } else {
                    Err((
                        StatusCode::FORBIDDEN,
                        Json(json!({ "status": "error", "message": "Access outside workspace denied (symlink escape)" })),
                    ))
                }
            }
            Err(e) => Err((
                StatusCode::NOT_FOUND,
                Json(json!({ "status": "error", "message": e.to_string() })),
            )),
        }
    } else if allow_creation {
        let mut ancestor = norm.as_path();
        while !ancestor.exists() {
            if let Some(parent) = ancestor.parent() {
                ancestor = parent;
            } else {
                break;
            }
        }
        if ancestor.exists() {
            match ancestor.canonicalize() {
                Ok(canonical_ancestor) => {
                    let allowed_ancestor = canonical_ancestor.starts_with(&canonical_lodge)
                        || canonical_ancestor.starts_with(&canonical_george)
                        || canonical_ancestor.starts_with(&canonical_docked);
                    if allowed_ancestor {
                        Ok(norm)
                    } else {
                        Err((
                            StatusCode::FORBIDDEN,
                            Json(json!({ "status": "error", "message": "Access outside workspace denied" })),
                        ))
                    }
                }
                Err(e) => Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "status": "error", "message": e.to_string() })),
                )),
            }
        } else {
            Err((
                StatusCode::FORBIDDEN,
                Json(json!({ "status": "error", "message": "Root directory does not exist" })),
            ))
        }
    } else {
        Err((
            StatusCode::NOT_FOUND,
            Json(json!({ "status": "error", "message": "File not found" })),
        ))
    }
}

#[derive(Deserialize)]
struct ReadFileQuery {
    path: String,
}

async fn read_file_content(
    State(state): State<Arc<AppState>>,
    axum::extract::Query(q): axum::extract::Query<ReadFileQuery>,
) -> impl IntoResponse {
    let docked = state.docked_workspace.read().await.clone();
    let raw_target = if q.path.starts_with('/') {
        PathBuf::from(&q.path)
    } else {
        docked.path.join(&q.path)
    };

    let target = match validate_bounded_path(&raw_target, &state, &docked.path, false) {
        Ok(t) => t,
        Err(err_resp) => return err_resp.into_response(),
    };

    match fs::read_to_string(&target).await {
        Ok(content) => Json(json!({ "status": "ok", "path": target.to_string_lossy(), "content": content })).into_response(),
        Err(e) => (StatusCode::NOT_FOUND, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

#[derive(Deserialize)]
struct SaveFilePayload {
    path: String,
    content: String,
}

async fn save_file_content(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SaveFilePayload>,
) -> impl IntoResponse {
    let docked = state.docked_workspace.read().await.clone();
    let raw_target = if payload.path.starts_with('/') {
        PathBuf::from(&payload.path)
    } else {
        docked.path.join(&payload.path)
    };

    let target = match validate_bounded_path(&raw_target, &state, &docked.path, true) {
        Ok(t) => t,
        Err(err_resp) => return err_resp.into_response(),
    };

    // Safety gate: Execute bash -n on shell scripts before saving to avoid corrupting sweeps!
    let is_shell_script = target.extension().map_or(false, |ext| ext == "sh")
        || payload.content.starts_with("#!/bin/")
        || payload.content.starts_with("#!/usr/bin/env bash");

    if is_shell_script {
        let temp_file = state.george_dir.join(format!(".syntax_test_{}.sh", chrono_epoch_secs()));
        if let Ok(_) = fs::write(&temp_file, &payload.content).await {
            let check = tokio::process::Command::new("bash")
                .args(["-n", &temp_file.to_string_lossy()])
                .output()
                .await;
            let _ = fs::remove_file(&temp_file).await;

            if let Ok(out) = check {
                if !out.status.success() {
                    let err_msg = String::from_utf8_lossy(&out.stderr).to_string();
                    return Json(json!({
                        "status": "syntax_error",
                        "message": format!("Bash syntax validation failed:\n{}", err_msg.trim())
                    })).into_response();
                }
            }
        }
    }

    if let Some(parent) = target.parent() {
        let _ = fs::create_dir_all(parent).await;
    }

    match fs::write(&target, &payload.content).await {
        Ok(_) => {
            #[cfg(unix)]
            {
                if is_shell_script {
                    use std::os::unix::fs::PermissionsExt;
                    let perms = std::fs::Permissions::from_mode(0o755);
                    let _ = std::fs::set_permissions(&target, perms);
                }
            }
            Json(json!({ "status": "ok", "path": target.to_string_lossy() })).into_response()
        },
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

async fn list_blue_lodge_files(state: &AppState) -> axum::response::Response {
    let mut files = Vec::new();
    let lodge_dir = &state.lodge_dir;
    let george_dir = &state.george_dir;

    // 1. lib/*.sh
    let lib_dir = lodge_dir.join("lib");
    if let Ok(mut entries) = fs::read_dir(&lib_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "sh") {
                let rel = format!("lib/{}", path.file_name().unwrap_or_default().to_string_lossy());
                files.push(json!({
                    "path": rel,
                    "name": path.file_name().unwrap_or_default().to_string_lossy(),
                    "category": "Libraries (lib/)",
                    "ext": "sh"
                }));
            }
        }
    }

    // 2. commands/*.sh
    let cmd_dir = lodge_dir.join("commands");
    if let Ok(mut entries) = fs::read_dir(&cmd_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "sh") {
                let rel = format!("commands/{}", path.file_name().unwrap_or_default().to_string_lossy());
                files.push(json!({
                    "path": rel,
                    "name": path.file_name().unwrap_or_default().to_string_lossy(),
                    "category": "Commands (commands/)",
                    "ext": "sh"
                }));
            }
        }
    }

    // 3. .george/cron_jobs/*.sh
    let cron_dir = george_dir.join("cron_jobs");
    if let Ok(mut entries) = fs::read_dir(&cron_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "sh") {
                let rel = format!(".george/cron_jobs/{}", path.file_name().unwrap_or_default().to_string_lossy());
                files.push(json!({
                    "path": rel,
                    "name": path.file_name().unwrap_or_default().to_string_lossy(),
                    "category": "Cron Sweeps (.george/cron_jobs/)",
                    "ext": "sh"
                }));
            }
        }
    }

    // 4. .george/*.conf and *.json configs
    if let Ok(mut entries) = fs::read_dir(george_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "conf" || ext == "json") {
                let rel = format!(".george/{}", path.file_name().unwrap_or_default().to_string_lossy());
                files.push(json!({
                    "path": rel,
                    "name": path.file_name().unwrap_or_default().to_string_lossy(),
                    "category": "Configs & State (.george/)",
                    "ext": path.extension().unwrap_or_default().to_string_lossy()
                }));
            }
        }
    }

    // 5. Documentation *.md
    if let Ok(mut entries) = fs::read_dir(lodge_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.extension().map_or(false, |ext| ext == "md") {
                let rel = path.file_name().unwrap_or_default().to_string_lossy().to_string();
                files.push(json!({
                    "path": rel,
                    "name": path.file_name().unwrap_or_default().to_string_lossy(),
                    "category": "Documentation (*.md)",
                    "ext": "md"
                }));
            }
        }
    }

    files.sort_by(|a, b| a["path"].as_str().unwrap_or("").cmp(b["path"].as_str().unwrap_or("")));
    Json(json!({ "status": "ok", "root": lodge_dir.to_string_lossy(), "files": files })).into_response()
}

fn scan_repository_files<'a>(
    base: &'a PathBuf,
    current: PathBuf,
    depth: usize,
    files: &'a mut Vec<serde_json::Value>,
) -> futures_util::future::BoxFuture<'a, ()> {
    Box::pin(async move {
        if depth > 3 || files.len() >= 250 {
            return;
        }
        let mut entries = match fs::read_dir(&current).await {
            Ok(e) => e,
            Err(_) => return,
        };
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            let file_name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
            if file_name.starts_with('.') && file_name != ".george" {
                continue;
            }
            if file_name == "node_modules" || file_name == "target" || file_name == "build" || file_name == "dist" || file_name == "__pycache__" || file_name == ".venv" {
                continue;
            }
            if let Ok(file_type) = entry.file_type().await {
                if file_type.is_dir() {
                    scan_repository_files(base, path, depth + 1, files).await;
                } else if file_type.is_file() {
                    let rel = path.strip_prefix(base).unwrap_or(&path).to_string_lossy().to_string();
                    let ext = path.extension().unwrap_or_default().to_string_lossy().to_string();
                    let category = if rel.starts_with("src/") {
                        "Source (src/)"
                    } else if rel.starts_with("lib/") {
                        "Libraries (lib/)"
                    } else if rel.starts_with("tests/") || rel.starts_with("test/") {
                        "Tests"
                    } else if rel.starts_with("commands/") {
                        "Commands"
                    } else if rel.starts_with(".george/") {
                        "George System (.george/)"
                    } else if ext == "md" {
                        "Documentation (*.md)"
                    } else if ext == "conf" || ext == "json" || ext == "toml" || ext == "yaml" || ext == "yml" {
                        "Configuration"
                    } else {
                        "Files"
                    };
                    files.push(json!({
                        "path": rel,
                        "full_path": path.to_string_lossy(),
                        "name": file_name,
                        "category": category,
                        "ext": ext
                    }));
                }
            }
        }
    })
}

#[derive(Deserialize)]
struct FilesListQuery {
    root: Option<String>,
}

async fn list_workspace_files(
    State(state): State<Arc<AppState>>,
    axum::extract::Query(q): axum::extract::Query<FilesListQuery>,
) -> impl IntoResponse {
    let docked = state.docked_workspace.read().await.clone();
    let query_root = q.root.map(PathBuf::from);
    let raw_target_root = query_root.unwrap_or(docked.path.clone());

    let target_root = match validate_bounded_path(&raw_target_root, &state, &docked.path, false) {
        Ok(t) if t.is_dir() => t,
        _ => return (StatusCode::FORBIDDEN, Json(json!({ "status": "error", "message": "Access outside workspace denied" }))).into_response(),
    };

    let canonical_lodge = state.lodge_dir.canonicalize().unwrap_or_else(|_| state.lodge_dir.clone());
    if target_root == canonical_lodge || target_root == state.lodge_dir {
        return list_blue_lodge_files(&state).await;
    }

    let mut files = Vec::new();
    scan_repository_files(&target_root, target_root.clone(), 0, &mut files).await;
    files.sort_by(|a, b| a["path"].as_str().unwrap_or("").cmp(b["path"].as_str().unwrap_or("")));

    Json(json!({
        "status": "ok",
        "root": target_root.to_string_lossy(),
        "files": files
    })).into_response()
}

#[derive(Deserialize)]
struct DockWorkspacePayload {
    path: String,
    mode: Option<String>,
}

async fn get_active_workspace(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let ws = state.docked_workspace.read().await.clone();
    let recent_file = state.george_dir.join("workspaces_recent.json");
    let mut recent: Vec<serde_json::Value> = Vec::new();
    if let Ok(data) = fs::read_to_string(&recent_file).await {
        if let Ok(parsed) = serde_json::from_str::<Vec<serde_json::Value>>(&data) {
            recent = parsed;
        }
    }
    if recent.is_empty() {
        recent.push(json!({
            "path": state.lodge_dir.to_string_lossy(),
            "name": "blue-lodge",
            "mode": "local",
            "branch": "develop"
        }));
    }
    Json(json!({
        "status": "ok",
        "workspace": ws,
        "recent": recent
    }))
}

async fn dock_workspace(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<DockWorkspacePayload>,
) -> impl IntoResponse {
    let raw_path = payload.path.trim();
    if raw_path.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "status": "error", "message": "Path cannot be empty" }))).into_response();
    }
    let target_path = PathBuf::from(raw_path);
    if !target_path.exists() || !target_path.is_dir() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "status": "error", "message": format!("Directory not found: {}", raw_path) }))).into_response();
    }

    let mode = payload.mode.unwrap_or_else(|| "local".to_string());
    let repo_name = target_path.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "workspace".to_string());

    // Detect git branch
    let git_check = tokio::process::Command::new("git")
        .args(["-C", target_path.to_str().unwrap_or("."), "branch", "--show-current"])
        .output()
        .await;

    let branch = match git_check {
        Ok(out) if out.status.success() => {
            let b = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if b.is_empty() { "main".to_string() } else { b }
        }
        _ => "main".to_string(),
    };

    let actual_path = if mode == "shadow" {
        let shadow_dir = state.george_dir.join("workspaces").join(&repo_name);
        let _ = fs::create_dir_all(&shadow_dir).await;
        let shadow_git = shadow_dir.join(".git");
        if !shadow_git.exists() {
            let _ = tokio::process::Command::new("git")
                .args(["clone", target_path.to_str().unwrap_or("."), shadow_dir.to_str().unwrap_or(".")])
                .output()
                .await;
        }
        shadow_dir
    } else {
        target_path.clone()
    };

    let ws = DockedWorkspace {
        path: actual_path.clone(),
        mode: mode.clone(),
        branch: branch.clone(),
        repo_name: repo_name.clone(),
        gitea_synced: true,
    };

    *state.docked_workspace.write().await = ws.clone();

    // Persist active workspace configuration
    let conf_path = state.george_dir.join("workspace.conf");
    let _ = fs::write(&conf_path, serde_json::to_string_pretty(&ws).unwrap_or_default()).await;

    // Update recent workspaces
    let recent_file = state.george_dir.join("workspaces_recent.json");
    let mut recent: Vec<serde_json::Value> = Vec::new();
    if let Ok(data) = fs::read_to_string(&recent_file).await {
        if let Ok(parsed) = serde_json::from_str::<Vec<serde_json::Value>>(&data) {
            recent = parsed;
        }
    }
    recent.retain(|item| item["path"].as_str() != Some(actual_path.to_str().unwrap_or("")));
    recent.insert(0, json!({
        "path": actual_path.to_string_lossy(),
        "name": repo_name,
        "mode": mode,
        "branch": branch
    }));
    if recent.len() > 10 {
        recent.truncate(10);
    }
    let _ = fs::write(&recent_file, serde_json::to_string_pretty(&recent).unwrap_or_default()).await;

    Json(json!({
        "status": "ok",
        "workspace": ws,
        "recent": recent
    })).into_response()
}

#[derive(Deserialize)]
struct TerminalWsQuery {
    file: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
}

async fn terminal_ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
    axum::extract::Query(q): axum::extract::Query<TerminalWsQuery>,
) -> impl IntoResponse {
    let lodge_dir = state.lodge_dir.clone();
    let docked = state.docked_workspace.read().await.clone();
    let file_arg = if let Some(f) = q.file {
        if f.starts_with('/') {
            f
        } else {
            docked.path.join(f).to_string_lossy().to_string()
        }
    } else {
        String::new()
    };
    let cols = q.cols.unwrap_or(100);
    let rows = q.rows.unwrap_or(30);

    ws.on_upgrade(move |socket| handle_terminal_socket(socket, lodge_dir, file_arg, cols, rows))
}

async fn handle_terminal_socket(socket: WebSocket, lodge_dir: PathBuf, file_arg: String, cols: u16, rows: u16) {
    let (mut sender, mut receiver) = socket.split();
    let pty_script = lodge_dir.join("lib").join("nvim_pty.py");

    let mut cmd = tokio::process::Command::new("python3");
    cmd.arg(&pty_script)
       .arg(&file_arg)
       .arg(cols.to_string())
       .arg(rows.to_string())
       .stdin(std::process::Stdio::piped())
       .stdout(std::process::Stdio::piped())
       .stderr(std::process::Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            let _ = sender.send(Message::Text(format!("Failed to spawn nvim: {}", e))).await;
            return;
        }
    };

    let mut stdin = child.stdin.take().expect("Child stdin unavailable");
    let mut stdout = child.stdout.take().expect("Child stdout unavailable");

    let send_task = tokio::spawn(async move {
        let mut buf = [0u8; 4096];
        loop {
            match stdout.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if sender.send(Message::Binary(buf[..n].to_vec())).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = receiver.next().await {
            match msg {
                Message::Text(text) => {
                    if text.contains("\"resize\"") {
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                            if v.get("type").and_then(|t| t.as_str()) == Some("resize") {
                                if let (Some(c), Some(r)) = (v["cols"].as_u64(), v["rows"].as_u64()) {
                                    let resize_pkt = format!("\x1b]RESIZE:{}:{}\x07", c, r);
                                    let _ = stdin.write_all(resize_pkt.as_bytes()).await;
                                    let _ = stdin.flush().await;
                                    continue;
                                }
                            }
                        }
                    }
                    if stdin.write_all(text.as_bytes()).await.is_err() {
                        break;
                    }
                    let _ = stdin.flush().await;
                }
                Message::Binary(bin) => {
                    if stdin.write_all(&bin).await.is_err() {
                        break;
                    }
                    let _ = stdin.flush().await;
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
    });

    tokio::select! {
        _ = send_task => {},
        _ = recv_task => {},
    }

    let _ = child.kill().await;
}

#[derive(Deserialize)]
struct ResolveDepsQuery {
    path: String,
}

async fn resolve_script_deps(
    State(state): State<Arc<AppState>>,
    axum::extract::Query(q): axum::extract::Query<ResolveDepsQuery>,
) -> impl IntoResponse {
    let docked = state.docked_workspace.read().await.clone();
    let raw_target = if q.path.starts_with('/') {
        PathBuf::from(&q.path)
    } else {
        state.lodge_dir.join(&q.path)
    };

    let target = match validate_bounded_path(&raw_target, &state, &docked.path, false) {
        Ok(t) => t,
        Err(err_resp) => return err_resp.into_response(),
    };

    let content = match fs::read_to_string(&target).await {
        Ok(c) => c,
        Err(_) => return Json(json!({ "status": "ok", "source_file": q.path, "deps": [] })).into_response(),
    };

    let mut deps = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') {
            continue;
        }

        // Check for `source ...` or `. ...`
        let raw_target = if let Some(rest) = trimmed.strip_prefix("source ") {
            Some(rest.trim())
        } else if let Some(rest) = trimmed.strip_prefix(". ") {
            Some(rest.trim())
        } else {
            None
        };

        if let Some(mut token_str) = raw_target {
            // Strip trailing redirects e.g. `2>/dev/null || true`
            if let Some(pos) = token_str.find(" 2>") {
                token_str = &token_str[..pos];
            } else if let Some(pos) = token_str.find(" ||") {
                token_str = &token_str[..pos];
            }
            let clean_token = token_str.trim().trim_matches('"').trim_matches('\'').trim();

            // Normalize path: handle "$LODGE_DIR/", "${LODGE_DIR}/", "${LODGE_DIR:-.}/", etc.
            let mut resolved = clean_token.to_string();
            let prefixes_to_strip = [
                "$LODGE_DIR/",
                "${LODGE_DIR}/",
                "${LODGE_DIR:-.}/",
                "$HOME/blue-lodge/",
                "/home/wsl-ops/blue-lodge/",
                "./",
            ];
            for p in prefixes_to_strip {
                if resolved.starts_with(p) {
                    resolved = resolved.strip_prefix(p).unwrap_or(&resolved).to_string();
                }
            }

            if !resolved.is_empty() && !seen.contains(&resolved) {
                seen.insert(resolved.clone());
                let file_path = state.lodge_dir.join(&resolved);
                let exists = file_path.exists();
                let filename = PathBuf::from(&resolved).file_name().unwrap_or_default().to_string_lossy().to_string();
                deps.push(json!({
                    "raw": trimmed,
                    "path": resolved,
                    "name": filename,
                    "exists": exists,
                }));
            }
        }
    }

    Json(json!({ "status": "ok", "source_file": q.path, "deps": deps })).into_response()
}

// ── Node Probe & Model Pull Staging ───────────────────────────────────

#[derive(Deserialize)]
struct ProbeNodePayload {
    url: String,
    provider: Option<String>,
}

async fn probe_node(
    Json(payload): Json<ProbeNodePayload>,
) -> impl IntoResponse {
    let raw_url = payload.url.trim_end_matches('/');

    // 1. Probe for llama.cpp props
    if let Ok(props) = reqwest_lite_get(&format!("{}/props", raw_url)).await {
        let models = reqwest_lite_get(&format!("{}/v1/models", raw_url)).await.unwrap_or(json!([]));
        return Json(json!({
            "status": "online",
            "provider": "llama.cpp",
            "props": props,
            "models": models,
        }));
    }

    // 2. Probe for Ollama tags
    if let Ok(tags) = reqwest_lite_get(&format!("{}/api/tags", raw_url)).await {
        return Json(json!({
            "status": "online",
            "provider": "ollama",
            "tags": tags,
        }));
    }

    // 3. Probe for generic OpenAI v1/models (vLLM, LM Studio, etc.)
    if let Ok(models) = reqwest_lite_get(&format!("{}/v1/models", raw_url)).await {
        return Json(json!({
            "status": "online",
            "provider": payload.provider.unwrap_or_else(|| "openai-compatible".into()),
            "models": models,
        }));
    }

    Json(json!({
        "status": "offline",
        "message": format!("Unable to establish HTTP handshake with endpoint at {}", raw_url)
    }))
}

#[derive(Deserialize)]
struct StagePullPayload {
    provider: String,
    model_name: String,
    destination_dir: Option<String>,
    ssh_host: Option<String>,
}

async fn stage_model_pull(
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
        // llama.cpp GGUF download via huggingface-cli
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

// ── SSH Tunnel Management (for Remote GPUs / 5700XT) ───────────────────

async fn get_tunnel_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
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
    let forward_host = map.get("REMOTE_FORWARD_HOST").cloned().unwrap_or_else(|| "192.168.30.10".into());
    let llamacpp_port: u16 = map.get("REMOTE_LOCAL_LLAMACPP_PORT").and_then(|p| p.parse().ok()).unwrap_or(18080);
    let ollama_port: u16 = map.get("REMOTE_LOCAL_OLLAMA_PORT").and_then(|p| p.parse().ok()).unwrap_or(21434);

    let pid_file = state.george_dir.join("remote-tunnel.pid");
    let pid = fs::read_to_string(&pid_file).await.ok()
        .and_then(|s| s.trim().parse::<u32>().ok());
    let pid_alive = match pid {
        Some(p) => std::process::Command::new("kill").args(["-0", &p.to_string()]).status().map(|s| s.success()).unwrap_or(false),
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

async fn connect_tunnel(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/remote.sh' && remote_connect", state.lodge_dir.display()))
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

async fn disconnect_tunnel(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/remote.sh' && remote_disconnect", state.lodge_dir.display()))
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

// ── Compute Node Persistence ──────────────────────────────────────────

#[derive(Deserialize)]
struct NodeSavePayload {
    tier: String,
    name: Option<String>,
    url: String,
    model: Option<String>,
    context: Option<u32>,
    enabled: Option<bool>,
    hardware: Option<String>,
    jump_box: Option<String>,
}

fn update_conf_line_str(content: &str, key: &str, new_val: &str) -> String {
    let mut lines: Vec<String> = content.lines().map(|s| s.to_string()).collect();
    let mut found = false;
    for line in lines.iter_mut() {
        let trimmed = line.trim();
        if trimmed.starts_with(key) {
            if let Some((k, _)) = trimmed.split_once('=') {
                if k.trim() == key {
                    *line = format!("{}={}", key, new_val);
                    found = true;
                    break;
                }
            }
        }
    }
    if !found {
        lines.push(format!("{}={}", key, new_val));
    }
    lines.join("\n") + "\n"
}

async fn save_node_endpoint(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<NodeSavePayload>,
) -> impl IntoResponse {
    let prefix = if payload.tier.contains('3') {
        "TIER3"
    } else if payload.tier.contains('1') {
        "TIER1"
    } else if payload.tier.contains('2') {
        "TIER2"
    } else {
        "TIER0"
    };

    let conf_file = state.george_dir.join("endpoints.conf");
    let mut content = fs::read_to_string(&conf_file).await.unwrap_or_default();
    content = update_conf_line_str(&content, &format!("{}_URL", prefix), &format!("\"{}\"", payload.url.trim()));
    if let Some(ref name) = payload.name {
        if !name.trim().is_empty() {
            content = update_conf_line_str(&content, &format!("{}_NAME", prefix), &format!("\"{}\"", name.trim()));
        }
    }
    if let Some(ref model) = payload.model {
        if !model.trim().is_empty() {
            content = update_conf_line_str(&content, &format!("{}_MODEL", prefix), &format!("\"{}\"", model.trim()));
        }
    }
    if let Some(ref hw) = payload.hardware {
        if !hw.trim().is_empty() {
            content = update_conf_line_str(&content, &format!("{}_HARDWARE", prefix), &format!("\"{}\"", hw.trim()));
        }
    }
    if let Some(ctx) = payload.context {
        content = update_conf_line_str(&content, &format!("{}_CONTEXT", prefix), &ctx.to_string());
    }
    if let Some(en) = payload.enabled {
        content = update_conf_line_str(&content, &format!("{}_ENABLED", prefix), if en { "1" } else { "0" });
    }
    let _ = fs::write(&conf_file, content).await;

    if let Some(ref jump) = payload.jump_box {
        if !jump.trim().is_empty() {
            let remote_conf = state.george_dir.join("remote.conf");
            let mut r_content = fs::read_to_string(&remote_conf).await.unwrap_or_default();
            r_content = update_conf_line_str(&r_content, "REMOTE_JUMP_HOST", jump.trim());
            let _ = fs::write(&remote_conf, r_content).await;
        }
    }

    Json(json!({ "status": "ok", "prefix": prefix }))
}


// ── Memories & Transcripts ────────────────────────────────────────────

async fn get_memories(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let reg_path = state.george_dir.join("memories").join("registry.json");
    if let Ok(content) = fs::read_to_string(&reg_path).await {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
            return Json(val);
        }
    }
    Json(json!({}))
}

async fn get_transcripts(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut list = Vec::new();
    let trans_dir = state.george_dir.join("transcripts");
    if let Ok(mut entries) = fs::read_dir(&trans_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.extension().map_or(false, |ext| ext == "md") {
                let meta = entry.metadata().await.ok();
                let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
                list.push(json!({
                    "name": entry.file_name().to_string_lossy(),
                    "size_bytes": size,
                    "path": p.to_string_lossy(),
                }));
            }
        }
    }
    list.sort_by(|a, b| b["name"].as_str().unwrap_or("").cmp(a["name"].as_str().unwrap_or("")));
    Json(list)
}

async fn get_transcript_content(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> impl IntoResponse {
    let clean_name = name.replace("..", "").replace('/', "");
    let path = state.george_dir.join("transcripts").join(clean_name);
    match fs::read_to_string(&path).await {
        Ok(content) => (StatusCode::OK, content).into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "Transcript not found").into_response(),
    }
}

async fn delete_transcript(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> impl IntoResponse {
    let clean_name = name.replace("..", "").replace('/', "");
    let mut deleted = false;
    let path = state.george_dir.join("transcripts").join(&clean_name);
    if path.exists() && fs::remove_file(&path).await.is_ok() {
        deleted = true;
    }
    let ws_path = state.george_dir.join("workspaces").join(&clean_name);
    if ws_path.exists() && fs::remove_file(&ws_path).await.is_ok() {
        deleted = true;
    }
    if deleted {
        Json(json!({ "status": "deleted", "name": clean_name }))
    } else {
        Json(json!({ "status": "not_found", "name": clean_name }))
    }
}

async fn get_journal(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let george_path = state.lodge_dir.join("GEORGE.md");
    let george_content = fs::read_to_string(&george_path).await.unwrap_or_default();

    let recall_db = state.george_dir.join("recall.db");
    let mut journal_entries = Vec::new();
    if recall_db.exists() {
        let out = tokio::process::Command::new("sqlite3")
            .args(["-json", &recall_db.to_string_lossy(), "SELECT id, section, substr(content, 1, 200) as snippet, indexed_at FROM chunks WHERE source = 'journal' ORDER BY id DESC LIMIT 15;"])
            .output()
            .await;
        if let Ok(res) = out {
            if let Ok(rows) = serde_json::from_slice::<serde_json::Value>(&res.stdout) {
                journal_entries = rows.as_array().cloned().unwrap_or_default();
            }
        }
    }

    Json(json!({
        "george_md": george_content,
        "journal_entries": journal_entries,
    }))
}

#[derive(Deserialize)]
struct SaveJournalPayload {
    george_md: Option<String>,
}

async fn save_journal(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SaveJournalPayload>,
) -> impl IntoResponse {
    if let Some(content) = payload.george_md {
        let path = state.lodge_dir.join("GEORGE.md");
        let _ = fs::write(&path, content).await;
    }
    Json(json!({ "status": "saved" }))
}

#[derive(Deserialize)]
struct SqliteQueryPayload {
    query: Option<String>,
    search: Option<String>,
    db: Option<String>,
}

async fn query_sqlite(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SqliteQueryPayload>,
) -> impl IntoResponse {
    let db_name = payload.db.unwrap_or_else(|| "recall".into());
    let db_path = match db_name.as_str() {
        "discord_channels" => state.george_dir.join("discord_channels.db"),
        "discord_profiles" => state.george_dir.join("discord_profiles.db"),
        "reputation" => state.george_dir.join("reputation.db"),
        "mastodon" => state.george_dir.join("mastodon_instances.db"),
        _ => state.george_dir.join("recall.db"),
    };

    if !db_path.exists() {
        return Json(json!({ "status": "error", "error": format!("Database {} not found", db_path.display()) }));
    }

    let sql_to_run = if let Some(search_term) = payload.search {
        let term_clean = search_term.replace('\'', "''");
        format!(
            "SELECT rowid, source, section, substr(content, 1, 300) AS snippet, bm25(chunks_fts) AS bm25_score FROM chunks_fts WHERE chunks_fts MATCH '{}' ORDER BY bm25_score LIMIT 25;",
            term_clean
        )
    } else if let Some(raw_q) = payload.query {
        let trimmed = raw_q.trim();
        let upper = trimmed.to_uppercase();
        if !upper.starts_with("SELECT") && !upper.starts_with("PRAGMA") && !upper.starts_with(".SCHEMA") && !upper.starts_with("EXPLAIN") {
            return Json(json!({ "status": "error", "error": "Only read-only queries (SELECT, PRAGMA, .schema) are permitted." }));
        }
        trimmed.to_string()
    } else {
        return Json(json!({ "status": "error", "error": "Empty query or search term" }));
    };

    let out = tokio::process::Command::new("sqlite3")
        .args(["-json", &db_path.to_string_lossy(), &sql_to_run])
        .output()
        .await;

    match out {
        Ok(res) => {
            let stdout = String::from_utf8_lossy(&res.stdout).to_string();
            let stderr = String::from_utf8_lossy(&res.stderr).to_string();
            if !res.status.success() || stdout.trim().is_empty() {
                if !stderr.is_empty() {
                    return Json(json!({ "status": "error", "error": stderr.trim() }));
                }
                return Json(json!({ "status": "ok", "rows": [], "count": 0 }));
            }
            if let Ok(rows) = serde_json::from_str::<serde_json::Value>(&stdout) {
                let count = rows.as_array().map(|a| a.len()).unwrap_or(0);
                Json(json!({ "status": "ok", "rows": rows, "count": count }))
            } else {
                Json(json!({ "status": "ok", "raw": stdout, "count": 0 }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "error": e.to_string() })),
    }
}

// ── Configuration & Connection Testing ───────────────────────────────

async fn get_config(State(state): State<Arc<AppState>>) -> impl IntoResponse {
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

async fn get_config_all(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let keys_file = state.george_dir.join("keys.conf");
    let limits_file = state.george_dir.join("limits.conf");
    let endpoints_file = state.george_dir.join("endpoints.conf");

    let keys = fs::read_to_string(&keys_file).await.unwrap_or_default();
    let limits = fs::read_to_string(&limits_file).await.unwrap_or_default();
    let endpoints = fs::read_to_string(&endpoints_file).await.unwrap_or_default();

    // Mask secret keys for safe display
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

#[derive(Deserialize)]
struct TestConnPayload {
    url: Option<String>,
    jump_host: Option<String>,
}

async fn test_connection(
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

#[derive(Deserialize)]
struct ConfigUpdate {
    limits_conf: Option<String>,
    endpoints_conf: Option<String>,
}

async fn update_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ConfigUpdate>,
) -> impl IntoResponse {
    if let Some(limits) = payload.limits_conf {
        let _ = fs::write(state.george_dir.join("limits.conf"), limits).await;
    }
    if let Some(endpoints) = payload.endpoints_conf {
        let _ = fs::write(state.george_dir.join("endpoints.conf"), endpoints).await;
    }
    Json(json!({ "status": "saved" }))
}

async fn get_config_full(State(state): State<Arc<AppState>>) -> impl IntoResponse {
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

#[derive(Deserialize)]
struct UpdateConfigKeyPayload {
    file: String,
    key: String,
    value: String,
}

async fn update_config_key(
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

async fn upload_file(
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    let upload_dir = state.lodge_dir.join("artifacts");
    let _ = fs::create_dir_all(&upload_dir).await;

    let mut uploaded_files = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let file_name = field
            .file_name()
            .map(String::from)
            .unwrap_or_else(|| format!("upload_{}", chrono_epoch_secs()));

        let safe_name = file_name.replace("..", "").replace('/', "_");
        let dest = upload_dir.join(&safe_name);

        if let Ok(data) = field.bytes().await {
            if fs::write(&dest, &data).await.is_ok() {
                let cmd_stage = if safe_name.ends_with(".png")
                    || safe_name.ends_with(".jpg")
                    || safe_name.ends_with(".jpeg")
                    || safe_name.ends_with(".svg")
                {
                    format!("/vision artifacts/{}", safe_name)
                } else {
                    format!("cat artifacts/{}", safe_name)
                };

                uploaded_files.push(json!({
                    "name": safe_name,
                    "path": format!("artifacts/{}", safe_name),
                    "staged_command": cmd_stage,
                }));
            }
        }
    }

    Json(json!({ "uploaded": uploaded_files }))
}

// ── Server-Sent Events (SSE) ──────────────────────────────────────────

async fn stream_events(
    State(state): State<Arc<AppState>>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let stream = async_stream::stream! {
        loop {
            let active = get_active_tasks_count(&state.lodge_dir).await;
            let payload = json!({
                "type": "telemetry",
                "timestamp": chrono_utc_now(),
                "active_tasks": active,
            });
            yield Ok(Event::default().event("telemetry").data(payload.to_string()));
            tokio::time::sleep(Duration::from_millis(2000)).await;
        }
    };

    Sse::new(stream).keep_alive(KeepAlive::default())
}

async fn stream_task_trajectory(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let clean_id = id.replace("..", "").replace('/', "");
    let sandbox = state.lodge_dir.join(".sandboxes").join(&clean_id);
    let telem_file = state.george_dir.join("telemetry").join("active").join(format!("{}.json", clean_id));

    let stream = async_stream::stream! {
        let mut last_pos: u64 = 0;
        let mut traj_log = find_trajectory_log(&sandbox).await;
        let mut in_obs = false;
        let mut obs_hidden = 0;
        let mut obs_printed = 0;

        loop {
            // If traj_log not in sandbox, check active telemetry transcript_file
            if traj_log.is_none() {
                if let Ok(content) = fs::read_to_string(&telem_file).await {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
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

            if let Some(ref p) = traj_log {
                if let Ok(mut f) = fs::File::open(p).await {
                    if let Ok(meta) = f.metadata().await {
                        let len = meta.len();
                        if len > last_pos {
                            let mut buf = Vec::new();
                            let _ = f.read_to_end(&mut buf).await;
                            let new_text = String::from_utf8_lossy(&buf[last_pos as usize..len as usize]);
                            last_pos = len;
                            for line in new_text.lines() {
                                let trimmed = line.trim();
                                if trimmed.is_empty() {
                                    continue;
                                }
                                if trimmed.starts_with("**observation") || trimmed.starts_with("observation:") {
                                    in_obs = true;
                                    obs_hidden = 0;
                                    obs_printed = 0;
                                    yield Ok(Event::default().event("log").data(line.to_string()));
                                } else if in_obs {
                                    if trimmed == "```" || trimmed.starts_with("```") {
                                        if obs_hidden > 0 {
                                            yield Ok(Event::default().event("log").data(format!("  ↳ [... {} lines folded for live monitor]", obs_hidden)));
                                        }
                                        in_obs = false;
                                        obs_hidden = 0;
                                        obs_printed = 0;
                                        yield Ok(Event::default().event("log").data(line.to_string()));
                                    } else {
                                        if obs_printed < 4 {
                                            obs_printed += 1;
                                            yield Ok(Event::default().event("log").data(line.to_string()));
                                        } else {
                                            obs_hidden += 1;
                                        }
                                    }
                                } else {
                                    yield Ok(Event::default().event("log").data(line.to_string()));
                                }
                            }
                        }
                    }
                }
            }

            let phase = fs::read_to_string(sandbox.join(".phase")).await.unwrap_or_default();
            if !phase.is_empty() {
                yield Ok(Event::default().event("phase").data(phase.trim().to_string()));
            } else if let Ok(content) = fs::read_to_string(&telem_file).await {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                    let turn = val.get("turn").and_then(|v| v.as_i64()).unwrap_or(0);
                    let max_turns = val.get("max_turns").and_then(|v| v.as_i64()).unwrap_or(30);
                    let tool = val.get("last_tool").and_then(|v| v.as_str()).unwrap_or("");
                    let ph = if !tool.is_empty() {
                        format!("Turn {}/{} ({})", turn, max_turns, tool)
                    } else {
                        format!("Turn {}/{}", turn, max_turns)
                    };
                    yield Ok(Event::default().event("phase").data(ph));
                }
            }

            let telem_alive = if telem_file.exists() {
                if let Ok(content) = fs::read_to_string(&telem_file).await {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                        let pid = val.get("pid").and_then(|v| v.as_i64()).unwrap_or(0) as u32;
                        if pid > 0 { is_pid_alive(pid) } else { true }
                    } else { false }
                } else { false }
            } else { false };

            if sandbox.join(".done").exists() || (!sandbox.exists() && !telem_alive) {
                yield Ok(Event::default().event("done").data("completed"));
                break;
            }

            tokio::time::sleep(Duration::from_millis(1000)).await;
        }
    };

    Sse::new(stream).keep_alive(KeepAlive::default())
}

// ── MCP (Model Context Protocol) Management Endpoints ───────────

#[derive(Deserialize)]
struct McpServerOpPayload {
    name: String,
}

#[derive(Deserialize)]
struct McpServerAddPayload {
    name: String,
    command: String,
    #[serde(default)]
    description: String,
}

#[derive(Deserialize)]
struct McpServerTestPayload {
    server: String,
    tool: String,
    #[serde(default)]
    arguments: serde_json::Value,
}

#[derive(Deserialize)]
struct McpCatalogInstallPayload {
    id: String,
    name: Option<String>,
    command: Option<String>,
    description: Option<String>,
}

#[derive(Deserialize)]
struct McpCustomServerPayload {
    name: String,
    #[serde(default)]
    description: String,
    code: String,
}

async fn get_mcp_servers(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let servers_conf = state.george_dir.join("mcp").join("servers.conf");
    let content = fs::read_to_string(&servers_conf).await.unwrap_or_default();
    let run_dir = state.george_dir.join("mcp").join("run");

    let mut servers = Vec::new();

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        if parts.is_empty() {
            continue;
        }
        let name = parts[0].trim().to_string();
        let command = parts.get(1).unwrap_or(&"").trim().to_string();
        let description = parts.get(2).unwrap_or(&"").trim().to_string();

        let srv_rundir = run_dir.join(&name);
        let pid_file = srv_rundir.join("pid");
        let ready_file = srv_rundir.join("ready");
        let capabilities_file = srv_rundir.join("capabilities.json");

        let pid = read_pid_from_file(&pid_file);
        let is_alive = pid.map(is_pid_alive).unwrap_or(false);
        let is_ready = ready_file.exists();

        let status = if is_alive && is_ready {
            "online"
        } else if is_alive {
            "starting"
        } else {
            "stopped"
        };

        let server_type = if command.contains("python") {
            "python"
        } else if command.contains("npx") || command.contains("node") {
            "node"
        } else if command.contains("bash") || command.contains(".sh") {
            "bash"
        } else {
            "external"
        };

        // If online, discover tools
        let mut tools = serde_json::Value::Array(Vec::new());
        if is_alive && is_ready {
            let script = format!(
                "source '{}/lib/mcp.sh' && mcp_tools_list '{}'",
                state.lodge_dir.display(),
                name
            );
            if let Ok(out) = tokio::time::timeout(
                Duration::from_millis(2000),
                tokio::process::Command::new("bash")
                    .arg("-c")
                    .arg(script)
                    .current_dir(&state.lodge_dir)
                    .output(),
            )
            .await
            {
                if let Ok(output) = out {
                    if output.status.success() {
                        if let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                            tools = parsed;
                        }
                    }
                }
            }
        }

        let capabilities = if capabilities_file.exists() {
            fs::read_to_string(&capabilities_file)
                .await
                .ok()
                .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        } else {
            None
        };

        servers.push(json!({
            "name": name,
            "command": command,
            "description": description,
            "status": status,
            "pid": pid,
            "ready": is_ready,
            "server_type": server_type,
            "tools": tools,
            "capabilities": capabilities,
        }));
    }

    Json(json!({ "status": "ok", "servers": servers }))
}

async fn start_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerOpPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/mcp.sh' && mcp_start '{}'",
        state.lodge_dir.display(),
        payload.name
    );
    let out = tokio::time::timeout(
        Duration::from_secs(20),
        tokio::process::Command::new("bash")
            .arg("-c")
            .arg(script)
            .current_dir(&state.lodge_dir)
            .output(),
    )
    .await;

    match out {
        Ok(Ok(o)) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            if o.status.success() {
                Json(json!({ "status": "ok", "message": format!("Server '{}' started", payload.name) }))
            } else {
                Json(json!({ "status": "error", "message": format!("{}{}", stderr, stdout) }))
            }
        }
        Ok(Err(e)) => Json(json!({ "status": "error", "message": e.to_string() })),
        Err(_) => Json(json!({ "status": "error", "message": "Timed out waiting for MCP server handshake" })),
    }
}

async fn stop_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerOpPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/mcp.sh' && mcp_stop '{}'",
        state.lodge_dir.display(),
        payload.name
    );
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "message": format!("Server '{}' stopped", payload.name) }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

async fn add_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerAddPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/mcp.sh' && mcp_server_add '{}' '{}' '{}'",
        state.lodge_dir.display(),
        payload.name.replace('\'', "\\'"),
        payload.command.replace('\'', "\\'"),
        payload.description.replace('\'', "\\'")
    );
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": payload.name }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

async fn remove_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerOpPayload>,
) -> impl IntoResponse {
    let script = format!(
        "source '{}/lib/mcp.sh' && mcp_server_remove '{}'",
        state.lodge_dir.display(),
        payload.name
    );
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": payload.name }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

async fn test_mcp_server_tool(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpServerTestPayload>,
) -> impl IntoResponse {
    let args_str = payload.arguments.to_string();
    let script = format!(
        "source '{}/lib/mcp.sh' && mcp_tool_call '{}' '{}' '{}'",
        state.lodge_dir.display(),
        payload.server.replace('\'', "\\'"),
        payload.tool.replace('\'', "\\'"),
        args_str.replace('\'', "\\'")
    );

    let out = tokio::time::timeout(
        Duration::from_secs(35),
        tokio::process::Command::new("bash")
            .arg("-c")
            .arg(script)
            .current_dir(&state.lodge_dir)
            .output(),
    )
    .await;

    match out {
        Ok(Ok(o)) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            if o.status.success() {
                Json(json!({ "status": "ok", "output": stdout }))
            } else {
                Json(json!({ "status": "error", "message": format!("{}{}", stderr, stdout) }))
            }
        }
        Ok(Err(e)) => Json(json!({ "status": "error", "message": e.to_string() })),
        Err(_) => Json(json!({ "status": "error", "message": "Tool execution timed out" })),
    }
}

async fn get_mcp_catalog(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let servers_conf = state.george_dir.join("mcp").join("servers.conf");
    let installed_conf = fs::read_to_string(&servers_conf).await.unwrap_or_default();
    let installed_names: Vec<String> = installed_conf
        .lines()
        .filter_map(|l| {
            let l = l.trim();
            if l.is_empty() || l.starts_with('#') {
                None
            } else {
                l.split('|').next().map(|s| s.trim().to_string())
            }
        })
        .collect();

    // Check system prerequisites
    let has_node = tokio::process::Command::new("node")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);
    let has_npx = tokio::process::Command::new("npx")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);
    let has_python3 = tokio::process::Command::new("python3")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);
    let has_gcloud = tokio::process::Command::new("gcloud")
        .arg("--version")
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false);

    let lodge_display = state.lodge_dir.display().to_string();

    let catalog_items = vec![
        json!({
            "id": "playwright",
            "name": "Playwright Browser Automation",
            "category": "Browser & Accessibility",
            "command": "npx -y @automata-ai/mcp-playwright",
            "description": "Full Chromium browser automation over MCP. Enables George to navigate pages, capture screenshots, evaluate DOM, perform click/fill accessibility flows, and troubleshoot web apps.",
            "prerequisites": "Node.js & npx. On WSL/Linux, run `npx playwright install chromium` to install browser binaries.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"playwright".to_string()),
            "author": "Community / Microsoft",
            "tags": ["browser", "accessibility", "testing", "web"]
        }),
        json!({
            "id": "autodesk-fusion",
            "name": "Autodesk Fusion 360 Bridge",
            "category": "CAD & Physical Fabrication",
            "command": format!("python3 {}/lib/mcp_server_fusion.py", lodge_display),
            "description": "3D parametric modeling bridge connecting George directly to Autodesk Fusion. Generate generative sketches, extrusions, revolves, and export STLs for 3D printing.",
            "prerequisites": "Python 3 and Autodesk Fusion 360 with local API socket bridge active.",
            "prereq_satisfied": has_python3,
            "installed": installed_names.contains(&"autodesk-fusion".to_string()),
            "author": "Autodesk / George Community",
            "tags": ["cad", "3d-printing", "fusion360", "hardware"]
        }),
        json!({
            "id": "chrome-devtools",
            "name": "Chrome DevTools & Puppeteer",
            "category": "Web Debugging & Diagnostics",
            "command": "npx -y @modelcontextprotocol/server-puppeteer",
            "description": "Direct DevTools instrumentation for live web diagnostics. Inspect console logs, network waterfalls, layout trees, and diagnose web interface regressions.",
            "prerequisites": "Node.js & npx.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"chrome-devtools".to_string()) || installed_names.contains(&"puppeteer".to_string()),
            "author": "Model Context Protocol",
            "tags": ["devtools", "debugging", "console", "network"]
        }),
        json!({
            "id": "gcloud",
            "name": "Google Cloud Platform (gcloud)",
            "category": "Cloud Infrastructure",
            "command": format!("bash {}/lib/mcp_server_gcloud.sh", lodge_display),
            "description": "Manage Google Cloud instances, Cloud Run services, Storage buckets, and project configurations through pure-bash JSON-RPC wrappers over gcloud CLI.",
            "prerequisites": "gcloud CLI installed on WSL/Linux and authenticated via `gcloud auth login`.",
            "prereq_satisfied": has_gcloud,
            "installed": installed_names.contains(&"gcloud".to_string()),
            "author": "George Craftsman / Google Cloud",
            "tags": ["gcloud", "cloud-run", "compute", "gcp"]
        }),
        json!({
            "id": "filesystem",
            "name": "Filesystem Scope Access",
            "category": "Workspace & Storage",
            "command": format!("npx -y @modelcontextprotocol/server-filesystem {}", lodge_display),
            "description": "Scoped filesystem access for external directories, repositories, and local asset inspection outside the immediate sandbox.",
            "prerequisites": "Node.js & npx.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"filesystem".to_string()),
            "author": "Model Context Protocol",
            "tags": ["filesystem", "workspace", "io"]
        }),
        json!({
            "id": "sqlite",
            "name": "SQLite Inspector",
            "category": "Data & Persistence",
            "command": format!("npx -y @modelcontextprotocol/server-sqlite --db {}/.george/george.db", lodge_display),
            "description": "Query database tables, inspect schema definitions, and run analytical queries over the local SQLite database.",
            "prerequisites": "Node.js & npx.",
            "prereq_satisfied": has_npx,
            "installed": installed_names.contains(&"sqlite".to_string()),
            "author": "Model Context Protocol",
            "tags": ["sqlite", "database", "sql"]
        }),
        json!({
            "id": "george-fetch",
            "name": "George Fetch (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/mcp_server_fetch.sh", lodge_display),
            "description": "Zero-dependency semantic web scraper, article extractor, PDF reader, Reddit API parser, and multi-provider search provider.",
            "prerequisites": "curl, jq (installed).",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-fetch".to_string()),
            "author": "George Core Engine",
            "tags": ["fetch", "search", "pdf", "pure-bash"]
        }),
        json!({
            "id": "george-git",
            "name": "George Git & GitHub (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/mcp_server_git.sh", lodge_display),
            "description": "Git operations, status inspections, branch tracking, diff analysis, and GitHub repository integration without Node.js.",
            "prerequisites": "git, jq (installed).",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-git".to_string()),
            "author": "George Core Engine",
            "tags": ["git", "github", "vcs", "pure-bash"]
        }),
        json!({
            "id": "george-inference",
            "name": "George Remote Inference (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/mcp_server_inference.sh", lodge_display),
            "description": "Remote GPU model catalog, active instance ps checks, model pull orchestration, and keep-alive configuration.",
            "prerequisites": "curl, jq (installed).",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-inference".to_string()),
            "author": "George Core Engine",
            "tags": ["gpu", "inference", "llama", "pure-bash"]
        }),
        json!({
            "id": "george-x",
            "name": "George 𝕏 / Twitter (Pure Bash)",
            "category": "Built-In Bash",
            "command": format!("bash {}/lib/mcp_server_x.sh", lodge_display),
            "description": "𝕏 / Twitter API v2 thread publication, status checking, and tweet deletion via OAuth 1.0a.",
            "prerequisites": "curl, jq, OAuth keys configured.",
            "prereq_satisfied": true,
            "installed": installed_names.contains(&"george-x".to_string()),
            "author": "George Core Engine",
            "tags": ["x", "social", "twitter", "pure-bash"]
        }),
    ];

    Json(json!({
        "status": "ok",
        "system": {
            "node": has_node,
            "npx": has_npx,
            "python3": has_python3,
            "gcloud": has_gcloud,
        },
        "catalog": catalog_items,
    }))
}

async fn install_mcp_catalog_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpCatalogInstallPayload>,
) -> impl IntoResponse {
    let name = payload.name.unwrap_or(payload.id.clone());
    let command = payload.command.unwrap_or_else(|| {
        match payload.id.as_str() {
            "playwright" => "npx -y @automata-ai/mcp-playwright".to_string(),
            "chrome-devtools" => "npx -y @modelcontextprotocol/server-puppeteer".to_string(),
            "filesystem" => format!("npx -y @modelcontextprotocol/server-filesystem {}", state.lodge_dir.display()),
            "sqlite" => format!("npx -y @modelcontextprotocol/server-sqlite --db {}/.george/george.db", state.lodge_dir.display()),
            "george-fetch" => format!("bash {}/lib/mcp_server_fetch.sh", state.lodge_dir.display()),
            "george-git" => format!("bash {}/lib/mcp_server_git.sh", state.lodge_dir.display()),
            "george-inference" => format!("bash {}/lib/mcp_server_inference.sh", state.lodge_dir.display()),
            "george-x" => format!("bash {}/lib/mcp_server_x.sh", state.lodge_dir.display()),
            "gcloud" => format!("bash {}/lib/mcp_server_gcloud.sh", state.lodge_dir.display()),
            "autodesk-fusion" => format!("python3 {}/lib/mcp_server_fusion.py", state.lodge_dir.display()),
            _ => "echo 'Custom MCP'".to_string(),
        }
    });
    let description = payload.description.unwrap_or_else(|| format!("MCP Server: {}", name));

    let script = format!(
        "source '{}/lib/mcp.sh' && mcp_server_add '{}' '{}' '{}'",
        state.lodge_dir.display(),
        name.replace('\'', "\\'"),
        command.replace('\'', "\\'"),
        description.replace('\'', "\\'")
    );

    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": name, "command": command }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

async fn create_custom_mcp_server(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<McpCustomServerPayload>,
) -> impl IntoResponse {
    let servers_dir = state.george_dir.join("mcp").join("custom");
    let _ = fs::create_dir_all(&servers_dir).await;

    let clean_name = payload.name.trim().replace(|c: char| !c.is_alphanumeric() && c != '-' && c != '_', "");
    if clean_name.is_empty() {
        return Json(json!({ "status": "error", "message": "Server name must be alphanumeric" }));
    }

    let script_path = servers_dir.join(format!("{}.sh", clean_name));
    if let Err(e) = fs::write(&script_path, &payload.code).await {
        return Json(json!({ "status": "error", "message": format!("Failed to write script: {}", e) }));
    }

    let _ = tokio::process::Command::new("chmod")
        .args(["+x", &script_path.display().to_string()])
        .output()
        .await;

    let cmd = format!("bash {}", script_path.display());
    let desc = if payload.description.trim().is_empty() {
        format!("Custom bash MCP server: {}", clean_name)
    } else {
        payload.description.trim().to_string()
    };

    let script = format!(
        "source '{}/lib/mcp.sh' && mcp_server_add '{}' '{}' '{}'",
        state.lodge_dir.display(),
        clean_name,
        cmd.replace('\'', "\\'"),
        desc.replace('\'', "\\'")
    );

    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            if o.status.success() {
                Json(json!({ "status": "ok", "name": clean_name, "path": script_path.display().to_string() }))
            } else {
                let stderr = String::from_utf8_lossy(&o.stderr).to_string();
                Json(json!({ "status": "error", "message": stderr }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "message": e.to_string() })),
    }
}

// ── Helpers ───────────────────────────────────────────────────────────

async fn find_trajectory_log(sandbox: &PathBuf) -> Option<PathBuf> {
    let direct = sandbox.join("trajectory.log");
    if direct.exists() {
        return Some(direct);
    }
    let ws_root = sandbox.join(".george").join("workspaces");
    if let Ok(mut entries) = fs::read_dir(&ws_root).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let candidate = entry.path().join("trajectory.log");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    None
}

async fn append_to_file(path: &PathBuf, text: &str) {
    use tokio::io::AsyncWriteExt;
    if let Ok(mut f) = tokio::fs::OpenOptions::new().create(true).append(true).open(path).await {
        let _ = f.write_all(text.as_bytes()).await;
    }
}

async fn get_active_tasks_count(lodge_dir: &PathBuf) -> usize {
    let mut count = 0;
    let sandboxes = lodge_dir.join(".sandboxes");
    if let Ok(mut entries) = fs::read_dir(&sandboxes).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            if !entry.path().join(".done").exists() {
                count += 1;
            }
        }
    }
    count
}

fn chrono_utc_now() -> String {
    use std::time::SystemTime;
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}", now)
}

fn chrono_epoch_secs() -> u64 {
    use std::time::SystemTime;
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn is_pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    std::path::Path::new(&format!("/proc/{}", pid)).exists()
}

fn read_pid_from_file(path: &std::path::Path) -> Option<u32> {
    std::fs::read_to_string(path).ok().and_then(|s| s.trim().parse::<u32>().ok())
}

fn kill_process_tree(pid: u32) {
    if pid == 0 {
        return;
    }
    let pid_str = pid.to_string();
    let _ = std::process::Command::new("pkill")
        .args(["-TERM", "-P", &pid_str])
        .output();
    let _ = std::process::Command::new("kill")
        .args(["-TERM", &pid_str])
        .output();
    std::thread::sleep(std::time::Duration::from_millis(100));
    let _ = std::process::Command::new("pkill")
        .args(["-KILL", "-P", &pid_str])
        .output();
    let _ = std::process::Command::new("kill")
        .args(["-KILL", &pid_str])
        .output();
}

async fn reqwest_lite_get(url: &str) -> Result<serde_json::Value, ()> {
    if let Ok(out) = tokio::process::Command::new("curl")
        .args(["-s", "--max-time", "1", url])
        .output()
        .await
    {
        if out.status.success() {
            if let Ok(val) = serde_json::from_slice(&out.stdout) {
                return Ok(val);
            }
        }
    }
    Err(())
}

async fn reqwest_lite_post(url: &str, body: &serde_json::Value) -> Result<serde_json::Value, ()> {
    let body_str = body.to_string();
    if let Ok(out) = tokio::process::Command::new("curl")
        .args(["-s", "--max-time", "10", "-X", "POST", "-H", "Content-Type: application/json", "-d", &body_str, url])
        .output()
        .await
    {
        if out.status.success() {
            if let Ok(val) = serde_json::from_slice(&out.stdout) {
                return Ok(val);
            }
        }
    }
    Err(())
}
