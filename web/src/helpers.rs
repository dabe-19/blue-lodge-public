use std::path::{Path, PathBuf};
use std::time::SystemTime;
use tokio::fs;
use tokio::io::AsyncWriteExt;

pub fn chrono_utc_now() -> String {
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    format!("{}", now)
}

pub fn chrono_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub fn is_pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    Path::new(&format!("/proc/{}", pid)).exists()
}

pub fn read_pid_from_file(path: &Path) -> Option<u32> {
    let pid = std::fs::read_to_string(path).ok().and_then(|s| s.trim().parse::<u32>().ok());
    if let Some(p) = pid {
        if !is_pid_alive(p) {
            let _ = std::fs::remove_file(path);
            return None;
        }
    }
    pid
}

pub fn kill_process_tree(pid: u32) {
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

pub async fn append_to_file(path: &PathBuf, text: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path).await {
        let _ = f.write_all(text.as_bytes()).await;
    }
}

pub async fn resolve_task_dir(lodge_dir: &PathBuf, george_dir: &PathBuf, clean_id: &str) -> PathBuf {
    // 1. Direct sandbox
    let sb = lodge_dir.join(".sandboxes").join(clean_id);
    if sb.exists() {
        return sb;
    }

    // 2. Direct workspace
    let ws = george_dir.join("workspaces").join(clean_id);
    if ws.exists() {
        return ws;
    }

    // 3. Run ledger workspace (.george/runs/<clean_id>/run.json)
    let run_json = george_dir.join("runs").join(clean_id).join("run.json");
    if let Ok(content) = fs::read_to_string(&run_json).await {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
            if let Some(ws_str) = val.get("workspace").and_then(|v| v.as_str()) {
                let p = PathBuf::from(ws_str);
                if p.exists() {
                    return p;
                }
            }
        }
    }

    // 4. Active telemetry descriptor (.george/telemetry/active/<clean_id>.json)
    let telem_json = george_dir.join("telemetry").join("active").join(format!("{}.json", clean_id));
    if let Ok(content) = fs::read_to_string(&telem_json).await {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
            if let Some(log_str) = val.get("log_file").and_then(|v| v.as_str()) {
                if !log_str.is_empty() {
                    let log_p = PathBuf::from(log_str);
                    if log_p.exists() {
                        if let Some(parent) = log_p.parent() {
                            return parent.to_path_buf();
                        }
                    }
                }
            }
            if let Some(workdir_str) = val.get("workdir").and_then(|v| v.as_str()) {
                if !workdir_str.is_empty() {
                    let cand = PathBuf::from(workdir_str).join(".george").join("workspaces").join(clean_id);
                    if cand.exists() {
                        return cand;
                    }
                }
            }
        }
    }

    // 5. Prefix stripping (sub_ and sub_sub_)
    if let Some(stripped) = clean_id.strip_prefix("sub_") {
        let sb_strip = lodge_dir.join(".sandboxes").join(stripped);
        if sb_strip.exists() {
            return sb_strip;
        }
        let ws_strip = george_dir.join("workspaces").join(stripped);
        if ws_strip.exists() {
            return ws_strip;
        }
        let run_strip = george_dir.join("runs").join(stripped).join("run.json");
        if let Ok(content) = fs::read_to_string(&run_strip).await {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(ws_str) = val.get("workspace").and_then(|v| v.as_str()) {
                    let p = PathBuf::from(ws_str);
                    if p.exists() {
                        return p;
                    }
                }
            }
        }
        if stripped.starts_with("sub_") {
            if let Some(stripped2) = stripped.strip_prefix("sub_") {
                let sb_strip2 = lodge_dir.join(".sandboxes").join(stripped2);
                if sb_strip2.exists() {
                    return sb_strip2;
                }
                let ws_strip2 = george_dir.join("workspaces").join(stripped2);
                if ws_strip2.exists() {
                    return ws_strip2;
                }
            }
        }
    }

    // 6. Check .george/runs/<clean_id> if it has trajectory.log or run.json
    let run_dir = george_dir.join("runs").join(clean_id);
    if run_dir.join("trajectory.log").exists() || run_dir.join("run.json").exists() {
        return run_dir;
    }

    // 7. Research subdirectories check
    for sub in &["quarantine", "active"] {
        let r_dir = george_dir.join("research").join(sub);
        if let Ok(mut entries) = fs::read_dir(&r_dir).await {
            while let Ok(Some(entry)) = entries.next_entry().await {
                let cand = entry.path().join(".george").join("workspaces").join(clean_id);
                if cand.exists() {
                    return cand;
                }
            }
        }
    }

    sb
}

pub async fn find_trajectory_log(sandbox: &PathBuf) -> Option<PathBuf> {
    let raw_react = sandbox.join("raw_react.log");
    if raw_react.exists() {
        return Some(raw_react);
    }
    if let Some(fname) = sandbox.file_name().and_then(|n| n.to_str()) {
        let parent_george = if sandbox.to_string_lossy().contains(".george") {
            let s = sandbox.to_string_lossy();
            let idx = s.find(".george").unwrap();
            PathBuf::from(&s[..idx + 7])
        } else {
            sandbox.parent().and_then(|p| p.parent()).map(|p| p.join(".george")).unwrap_or_else(|| PathBuf::from(".george"))
        };

        // Check Discord sessions (both direct discord_* and sub_discord_* or nested)
        let discord_target = if fname.starts_with("discord_") {
            Some(fname.to_string())
        } else if let Some(idx) = fname.find("discord_") {
            let d_part = &fname[idx..];
            let parts: Vec<&str> = d_part.split('_').collect();
            if parts.len() >= 4 {
                Some(format!("{}_{}_{}", parts[0], parts[1], parts[2]))
            } else {
                Some(d_part.to_string())
            }
        } else {
            None
        };

        if let Some(d_name) = discord_target {
            let d_raw = parent_george.join("discord_sessions").join(&d_name).join("raw_react.log");
            if d_raw.exists() {
                return Some(d_raw);
            }
            if let Some(rest) = d_name.strip_prefix("discord_") {
                let chan_id = rest.split('_').next().unwrap_or(rest);
                let s_log = parent_george.join("discord_sessions").join(format!("session_{}.log", chan_id));
                if s_log.exists() {
                    return Some(s_log);
                }
            }
        }

        if fname.starts_with("sub_") {
            let sub_out = parent_george.join("subagents").join(format!("{}.out", fname));
            if sub_out.exists() {
                return Some(sub_out);
            }
            let sub_log = parent_george.join("subagents").join(format!("{}.log", fname));
            if sub_log.exists() {
                return Some(sub_log);
            }
            if let Some(stripped) = fname.strip_prefix("sub_") {
                if stripped.starts_with("sub_") {
                    let s_out = parent_george.join("subagents").join(format!("{}.out", stripped));
                    if s_out.exists() {
                        return Some(s_out);
                    }
                    let s_log = parent_george.join("subagents").join(format!("{}.log", stripped));
                    if s_log.exists() {
                        return Some(s_log);
                    }
                }
            }
        }
    }
    let direct = sandbox.join("trajectory.log");
    if direct.exists() {
        return Some(direct);
    }
    let direct_transcript = sandbox.join("transcript.md");
    if direct_transcript.exists() {
        return Some(direct_transcript);
    }
    let ws_root = sandbox.join(".george").join("workspaces");
    if let Ok(mut entries) = fs::read_dir(&ws_root).await {
        let mut candidates = Vec::new();
        while let Ok(Some(entry)) = entries.next_entry().await {
            let candidate_raw = entry.path().join("raw_react.log");
            if candidate_raw.exists() {
                let mtime = fs::metadata(&candidate_raw).await.ok().and_then(|m| m.modified().ok());
                candidates.push((candidate_raw, mtime));
            } else {
                let candidate = entry.path().join("trajectory.log");
                if candidate.exists() {
                    let mtime = fs::metadata(&candidate).await.ok().and_then(|m| m.modified().ok());
                    candidates.push((candidate, mtime));
                }
            }
        }
        candidates.sort_by(|a, b| b.1.cmp(&a.1));
        if let Some((p, _)) = candidates.into_iter().next() {
            return Some(p);
        }
    }
    None
}

pub async fn get_active_tasks_count(lodge_dir: &PathBuf) -> usize {
    let mut count = 0;
    let now = chrono_epoch_secs();
    let sandboxes = lodge_dir.join(".sandboxes");
    if let Ok(mut entries) = fs::read_dir(&sandboxes).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if !p.is_dir() || p.join(".done").exists() {
                continue;
            }
            let pid_file = p.join(".pid");
            let has_pid = pid_file.exists();
            let pid_alive = read_pid_from_file(&pid_file).map_or(false, is_pid_alive);
            let mtime_secs = entry.metadata().await.ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);

            if (has_pid && pid_alive) || (!has_pid && now.saturating_sub(mtime_secs) <= 120) {
                count += 1;
            }
        }
    }
    count
}

pub async fn reqwest_lite_get(url: &str) -> Result<serde_json::Value, ()> {
    if let Ok(out) = tokio::process::Command::new("curl")
        .args(["-s", "--connect-timeout", "1", "--max-time", "2", url])
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

pub async fn reqwest_lite_post(url: &str, body: &serde_json::Value) -> Result<serde_json::Value, ()> {
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

pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_escape = false;
    for c in s.chars() {
        if c == '\x1b' {
            in_escape = true;
        } else if in_escape {
            if c == 'm' || c == 'K' || c == 'H' || c == 'J' {
                in_escape = false;
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[allow(dead_code)]
pub fn strip_reasoning_monologue(raw: &str) -> String {
    let mut cleaned_lines = Vec::new();
    for line in raw.lines() {
        let trimmed = line.trim();
        let lower = trimmed.to_lowercase();
        if lower.starts_with("the user is asking")
            || lower.starts_with("the user wants")
            || lower.starts_with("the user asked")
            || lower.starts_with("let me think")
            || lower.starts_with("let's think")
            || lower.starts_with("i need to")
            || lower.starts_with("i should")
            || lower.starts_with("this is a simple")
            || lower.starts_with("this is a somewhat")
            || lower.starts_with("this question asks")
            || lower.starts_with("this is straightforward")
        {
            continue;
        }
        if !trimmed.is_empty() {
            cleaned_lines.push(trimmed);
        }
    }
    let mut deduped = Vec::new();
    for l in cleaned_lines {
        if deduped.last().map(|s: &&str| *s) != Some(l) {
            deduped.push(l);
        }
    }
    let res = deduped.join("\n\n");
    if res.trim().is_empty() {
        "I have considered your inquiry with care. Allow me to state my view directly.".to_string()
    } else {
        res
    }
}

pub fn normalize_path(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            Component::Prefix(..) => components.push(component),
            Component::RootDir => components.push(component),
            Component::CurDir => {}
            Component::ParentDir => {
                if let Some(Component::Normal(_)) = components.last() {
                    components.pop();
                } else if components.iter().all(|c| matches!(c, Component::ParentDir)) {
                    components.push(component);
                }
            }
            Component::Normal(_) => components.push(component),
        }
    }
    components.into_iter().collect()
}

#[allow(dead_code)]
pub fn validate_bounded_path(
    candidate: &Path,
    bound_dir: &Path,
) -> Result<PathBuf, String> {
    let resolved = if candidate.is_absolute() {
        normalize_path(candidate)
    } else {
        normalize_path(&bound_dir.join(candidate))
    };

    let bound_normalized = normalize_path(bound_dir);
    if resolved.starts_with(&bound_normalized) {
        Ok(resolved)
    } else {
        Err(format!(
            "Access denied: path '{}' escapes repository root '{}'",
            candidate.display(),
            bound_dir.display()
        ))
    }
}

pub fn update_conf_line_str(content: &str, key: &str, new_val: &str) -> String {
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
