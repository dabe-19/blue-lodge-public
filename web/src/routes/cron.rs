use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::{chrono_utc_now, reqwest_lite_post};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CronJobPayload {
    pub name: String,
    pub interval: u64,
    pub description: Option<String>,
    pub command: String,
    pub is_system: Option<bool>,
}

#[derive(Deserialize)]
pub struct TogglePlatformPayload {
    pub platform: String,
    pub enabled: bool,
}

#[derive(Deserialize)]
pub struct ToggleSocialGatePayload {
    pub target: String,
    pub enabled: bool,
}

#[derive(Deserialize)]
pub struct CronGeneratePayload {
    pub prompt: String,
}

pub async fn get_cron_jobs(State(state): State<Arc<AppState>>) -> impl IntoResponse {
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
                .stderr(std::process::Stdio::null())
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

pub async fn save_cron_job(
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

pub async fn run_cron_job(
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

pub async fn delete_cron_job(
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

pub async fn toggle_cron_platform(
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

pub async fn toggle_cron_enabled(
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

pub async fn get_social_gate(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let conf_path = state.george_dir.join("social").join("social.conf");
    let mut global_enabled = false;
    let mut x_enabled = false;
    let mut mastodon_enabled = false;
    let mut bluesky_enabled = false;
    let mut x_premium = true;

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
            } else if line.starts_with("X_PREMIUM=") {
                x_premium = line.ends_with("=1");
            }
        }
    }

    Json(json!({
        "global_enabled": global_enabled,
        "x_enabled": x_enabled,
        "mastodon_enabled": mastodon_enabled,
        "bluesky_enabled": bluesky_enabled,
        "x_premium": x_premium,
    }))
}

pub async fn toggle_social_gate(
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
    let mut x_premium = true;

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
            } else if line.starts_with("X_PREMIUM=") {
                x_premium = line.ends_with("=1");
            }
        }
    }

    match payload.target.to_lowercase().as_str() {
        "global" | "all" => global_enabled = payload.enabled,
        "x" | "twitter" => x_enabled = payload.enabled,
        "mastodon" | "masto" => mastodon_enabled = payload.enabled,
        "bluesky" | "bsky" => bluesky_enabled = payload.enabled,
        "x_premium" | "premium" => x_premium = payload.enabled,
        _ => return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Unknown target" }))).into_response(),
    }

    let conf_content = format!(
        "# George Global Social Endpoints Configuration\nGLOBAL_SOCIAL_ENABLED={}\nX_ENABLED={}\nMASTODON_ENABLED={}\nBLUESKY_ENABLED={}\nX_PREMIUM={}\n",
        if global_enabled { "1" } else { "0" },
        if x_enabled { "1" } else { "0" },
        if mastodon_enabled { "1" } else { "0" },
        if bluesky_enabled { "1" } else { "0" },
        if x_premium { "1" } else { "0" },
    );

    let _ = fs::write(&conf_path, conf_content).await;

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

pub async fn generate_cron_job(
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
            "find .sandboxes -maxdepth 1 -name \"web_session*\" -mtime +2 -exec rm -rf {} +\ndf -h . | tail -1".to_string(),
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

pub async fn start_cron_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/sys/cron.sh' && cron_start --force", state.lodge_dir.display()))
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

pub async fn stop_cron_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/sys/cron.sh' && cron_stop && cron_optout on 'workbench stop'", state.lodge_dir.display()))
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

pub async fn restart_cron_daemon(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg(format!("source '{}/lib/sys/cron.sh' && cron_stop; sleep 1; cron_start --force", state.lodge_dir.display()))
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
