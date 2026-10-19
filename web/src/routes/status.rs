use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::*;
use crate::state::AppState;

// nvidia-smi under WSL2/WDDM can take many seconds while the GPUs are saturated.
// The Workbench polls /api/status every 2 s, so cache the result and serialise
// callers: at most one nvidia-smi process at a time, refreshed every 10 s.
static GPU_CACHE: std::sync::OnceLock<tokio::sync::Mutex<(Option<std::time::Instant>, Vec<serde_json::Value>)>> =
    std::sync::OnceLock::new();
const GPU_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(10);
const GPU_QUERY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(4);

async fn query_nvidia_smi() -> Vec<serde_json::Value> {
    let mut gpus = Vec::new();
    let smi_bin = if std::path::Path::new("/usr/lib/wsl/lib/nvidia-smi").exists() {
        "/usr/lib/wsl/lib/nvidia-smi"
    } else {
        "nvidia-smi"
    };
    let fut = tokio::process::Command::new(smi_bin)
        .args([
            "--query-gpu=index,name,power.draw,utilization.gpu,memory.used,memory.total,temperature.gpu",
            "--format=csv,noheader,nounits",
        ])
        .kill_on_drop(true)
        .output();
    if let Ok(Ok(output)) = tokio::time::timeout(GPU_QUERY_TIMEOUT, fut).await {
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
    gpus
}

async fn gpu_snapshot() -> Vec<serde_json::Value> {
    let cell = GPU_CACHE.get_or_init(|| tokio::sync::Mutex::new((None, Vec::new())));
    let mut guard = cell.lock().await;
    if let Some(t) = guard.0 {
        if t.elapsed() < GPU_CACHE_TTL {
            return guard.1.clone();
        }
    }
    let fresh = query_nvidia_smi().await;
    guard.0 = Some(std::time::Instant::now());
    if !fresh.is_empty() {
        guard.1 = fresh;
    }
    guard.1.clone()
}

pub async fn get_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    // No synthetic GPU entry when nvidia-smi is unavailable: an empty list is
    // the truth, and the Rack renders "no local GPU" for it.
    let gpus = gpu_snapshot().await;
    let heartbeats = read_heartbeats(&state.george_dir).await;

    let conf_map = read_kv_conf(&state.george_dir.join("endpoints.conf")).await;
    let remote_map = read_kv_conf(&state.george_dir.join("remote.conf")).await;
    let tunnel_ports: Vec<u16> = ["REMOTE_LOCAL_LLAMACPP_PORT", "REMOTE_LOCAL_OLLAMA_PORT"]
        .iter()
        .filter_map(|k| remote_map.get(*k).and_then(|v| v.parse().ok()))
        .collect();
    let has_tunnel = remote_map.get("REMOTE_SSH_TARGET").map(|v| !v.is_empty()).unwrap_or(false);

    let mut slots_info = json!([]);
    if let Some(t1) = conf_map.get("TIER1_URL").filter(|u| is_http_url(u)) {
        if let Ok(val) = reqwest_lite_get(&format!("{}/slots", t1.trim_end_matches('/'))).await {
            slots_info = val;
        }
    }

    let active_tasks_count = get_active_tasks_count(&state.lodge_dir).await;

    // Compute nodes come only from endpoints.conf. Nothing is invented: an
    // unconfigured tier is omitted, and unset name/model/hardware stay empty.
    // All enabled tiers are probed concurrently so one dead host can't stall
    // the 2 s poll.
    const LADDER: [(u8, &str, &str); 4] = [
        (3, "Frontier / Architecture", "#bf5af2"),
        (1, "Primary Workhorse", "#00ffff"),
        (2, "Worker / Subagents", "#30d158"),
        (0, "Edge Fallback", "#ffd60a"),
    ];
    let mut probes = Vec::new();
    for (tier, role, color) in LADDER {
        let key = |s: &str| format!("TIER{}_{}", tier, s);
        let url = match conf_map.get(&key("URL")) {
            Some(u) if !u.trim().is_empty() => u.trim().trim_end_matches('/').to_string(),
            _ => continue,
        };
        let enabled = conf_map
            .get(&key("ENABLED"))
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let name = conf_map.get(&key("NAME")).cloned().unwrap_or_default();
        let model = conf_map.get(&key("MODEL")).cloned().unwrap_or_default();
        let hardware = conf_map.get(&key("HARDWARE")).cloned().unwrap_or_default();
        let ctx: Option<u32> = conf_map.get(&key("CONTEXT")).and_then(|v| v.parse().ok());
        let roles = conf_map.get(&key("ROLES")).cloned().unwrap_or_default();
        let path = classify_path(&url, &tunnel_ports, has_tunnel);
        let valid = is_http_url(&url);
        probes.push(async move {
            let (alive, live_ctx, live_model, live_details) = if enabled && valid {
                probe_live_node(&url).await
            } else {
                (false, None, None, None)
            };
            json!({
                "tier": format!("Tier {}", tier),
                "name": name,
                "role": if roles.is_empty() { role.to_string() } else { roles.clone() },
                "roles": roles,
                "url": url,
                "path": path,
                "model": live_model.clone().unwrap_or(model),
                "context": live_ctx.or(ctx),
                "live_ctx": live_ctx,
                "live_details": live_details,
                "enabled": enabled,
                "active": alive,
                "status": if !valid { "invalid" } else if alive { "online" } else if enabled { "offline" } else { "disabled" },
                "color": color,
                "hardware": hardware,
            })
        });
    }
    let nodes: Vec<serde_json::Value> = futures_join_all(probes).await;

    let docked_ws = state.docked_workspace.read().await.clone();

    let container_status = match tokio::process::Command::new("docker")
        .args(["inspect", "-f", "{{.State.Status}}", "george-prism-server"])
        .output()
        .await
    {
        Ok(out) if out.status.success() => {
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        }
        _ => "not found".to_string(),
    };
    let is_game_mode = container_status != "running";

    Json(json!({
        "status": "online",
        "timestamp": chrono_utc_now(),
        "gpus": gpus,
        "active_tasks_count": active_tasks_count,
        "slots": slots_info,
        "nodes": nodes,
        "docked_workspace": docked_ws,
        "game_mode": is_game_mode,
        "inference_container_status": container_status,
        "heartbeats": heartbeats,
    }))
}

/// Await a batch of futures concurrently, preserving order (no extra crate).
async fn futures_join_all<F, T>(futs: Vec<F>) -> Vec<T>
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let handles: Vec<_> = futs.into_iter().map(tokio::spawn).collect();
    let mut out = Vec::with_capacity(handles.len());
    for h in handles {
        if let Ok(v) = h.await {
            out.push(v);
        }
    }
    out
}

async fn read_kv_conf(path: &std::path::Path) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    if let Ok(content) = fs::read_to_string(path).await {
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('#') || trimmed.is_empty() {
                continue;
            }
            let trimmed = trimmed.strip_prefix("export ").unwrap_or(trimmed);
            if let Some((k, v)) = trimmed.split_once('=') {
                map.insert(k.trim().to_string(), v.trim().trim_matches('"').trim_matches('\'').to_string());
            }
        }
    }
    map
}

pub(crate) fn is_http_url(url: &str) -> bool {
    let rest = if let Some(r) = url.strip_prefix("http://") {
        r
    } else if let Some(r) = url.strip_prefix("https://") {
        r
    } else {
        return false;
    };
    let host_port = rest.split('/').next().unwrap_or("");
    !host_port.is_empty()
        && host_port.len() <= 253
        && host_port.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == ':')
        && !url.chars().any(|c| c.is_whitespace() || c == '"' || c == '\'' || c == '`' || c == '$' || c == '\\')
}

/// local / tunnel / lan / remote: where the bytes actually travel.
fn classify_path(url: &str, tunnel_ports: &[u16], has_tunnel: bool) -> &'static str {
    let rest = url.split("://").nth(1).unwrap_or("");
    let host_port = rest.split('/').next().unwrap_or("");
    let (host, port) = match host_port.rsplit_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().ok()),
        None => (host_port, None),
    };
    let host = host.to_ascii_lowercase();
    if host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0" {
        if has_tunnel && port.map(|p| tunnel_ports.contains(&p)).unwrap_or(false) {
            return "tunnel";
        }
        return "local";
    }
    if host.ends_with(".local") || host.ends_with(".lan") {
        return "lan";
    }
    if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
        if ip.is_private() || ip.is_link_local() {
            return "lan";
        }
    }
    "remote"
}

async fn probe_live_node(url: &str) -> (bool, Option<u32>, Option<String>, Option<String>) {
    let mut alive = false;
    let mut live_ctx = None;
    let mut live_details = Vec::new();
    let mut live_model = None;

    if let Ok(props) = reqwest_lite_get(&format!("{}/props", url)).await {
        alive = true;
        if let Some(n_ctx) = props.get("default_generation_settings").and_then(|s| s.get("n_ctx")).and_then(|v| v.as_u64()) {
            live_ctx = Some(n_ctx as u32);
        }
        if let Some(params) = props.get("default_generation_settings").and_then(|s| s.get("params")) {
            let temp = params.get("temperature").and_then(|v| v.as_f64()).map(|t| format!("{:.1}", t)).unwrap_or_else(|| "1.0".into());
            let top_p = params.get("top_p").and_then(|v| v.as_f64()).map(|p| format!("{:.2}", p)).unwrap_or_else(|| "0.95".into());
            live_details.push(format!("temp: {}, top_p: {}", temp, top_p));
        }
        if let Some(mp) = props.get("model_path").and_then(|v| v.as_str()) {
            let name = mp.rsplit('/').next().unwrap_or(mp).trim_end_matches(".gguf");
            if name != "base" {
                live_model = Some(name.to_string());
            }
        }
    } else if reqwest_lite_get(&format!("{}/health", url)).await.is_ok() {
        alive = true;
    }

    if alive {
        if let Ok(models) = reqwest_lite_get(&format!("{}/v1/models", url)).await {
            if let Some(arr) = models.get("data").and_then(|d| d.as_array()) {
                if let Some(first) = arr.first() {
                    if let Some(ft) = first.get("meta").and_then(|m| m.get("ftype")).and_then(|v| v.as_str()) {
                        live_details.insert(0, ft.to_string());
                    }
                    if live_model.is_none() {
                        if let Some(id) = first.get("id").and_then(|v| v.as_str()) {
                            let name = id.rsplit('/').next().unwrap_or(id).trim_end_matches(".gguf");
                            if name != "base" {
                                live_model = Some(name.to_string());
                            }
                        }
                    }
                }
            }
        }
        if live_model.is_none() {
            if let Ok(target) = std::fs::read_link(format!("{}/active/current/base.gguf", std::env::var("MODELS_DIR").unwrap_or_else(|_| format!("{}/models", std::env::var("HOME").unwrap_or_default())))) {
                if let Some(fname) = target.file_name().and_then(|n| n.to_str()) {
                    live_model = Some(fname.trim_end_matches(".gguf").to_string());
                }
            }
        }
    }

    let details_str = if live_details.is_empty() {
        None
    } else {
        Some(live_details.join(" · "))
    };

    (alive, live_ctx, live_model, details_str)
}

const HEARTBEAT_STALE_SECS: i64 = 1800;

/// Reads .george/heartbeats/<name>.json (written by lib/sys/heartbeats.sh).
async fn read_heartbeats(george_dir: &std::path::Path) -> Vec<serde_json::Value> {
    let mut out = Vec::new();
    let dir = george_dir.join("heartbeats");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    if let Ok(mut rd) = fs::read_dir(&dir).await {
        while let Ok(Some(entry)) = rd.next_entry().await {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            if let Ok(text) = fs::read_to_string(&path).await {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                    let name = v.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string();
                    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                        continue;
                    }
                    let ts = v.get("ts").and_then(|t| t.as_i64()).unwrap_or(0);
                    let age = (now - ts).max(0);
                    out.push(json!({
                        "name": name,
                        "ts": ts,
                        "age_s": age,
                        "stale": age > HEARTBEAT_STALE_SECS,
                    }));
                }
            }
        }
    }
    out.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    out
}
