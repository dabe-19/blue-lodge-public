use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::*;
use crate::routes::status::is_http_url;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct ProbeNodePayload {
    pub url: String,
    pub provider: Option<String>,
}

#[derive(Deserialize)]
pub struct NodeSavePayload {
    pub tier: String,
    pub name: Option<String>,
    pub url: String,
    pub model: Option<String>,
    pub context: Option<u32>,
    pub enabled: Option<bool>,
    pub hardware: Option<String>,
    pub jump_box: Option<String>,
    pub ssh_target: Option<String>,
    pub node_mode: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct DiscoverNodePayload {
    pub ssh_target: Option<String>,
    pub jump_host: Option<String>,
}

#[derive(Deserialize)]
pub struct SwitchModelPayload {
    pub model: String,
    pub lora: Option<String>,
    pub context: Option<u32>,
    pub parallel: Option<u32>,
}

#[derive(Deserialize)]
pub struct EnrollNodePayload {
    pub ssh_target: Option<String>,
    pub jump_host: Option<String>,
    pub node_name: Option<String>,
    pub mode: Option<String>,
    pub tier: Option<String>,
}

/// Free-text fields (name/model/hardware) end up inside double quotes in a
/// file that bash sources, so only a conservative charset is accepted.
fn valid_label(s: &str) -> bool {
    let s = s.trim();
    !s.is_empty()
        && s.len() <= 128
        && s.chars().all(|c| c.is_ascii_alphanumeric() || " ._:/@()+-".contains(c))
}

/// `user@host` or `host`, optionally `:port`; no options, no spaces.
fn valid_jump_host(s: &str) -> bool {
    let s = s.trim();
    if s.is_empty() || s.len() > 253 || s.starts_with('-') {
        return false;
    }
    let (user, host) = match s.split_once('@') {
        Some((u, h)) => (Some(u), h),
        None => (None, s),
    };
    if let Some(u) = user {
        if u.is_empty() || !u.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.') {
            return false;
        }
    }
    !host.is_empty() && host.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == ':')
}

fn valid_node_mode(s: &str) -> bool {
    matches!(s.trim(), "inference" | "worker" | "hybrid")
}

fn bad_request(msg: &str) -> (StatusCode, Json<serde_json::Value>) {
    (StatusCode::BAD_REQUEST, Json(json!({ "status": "error", "message": msg })))
}

pub async fn probe_node(
    Json(payload): Json<ProbeNodePayload>,
) -> impl IntoResponse {
    let raw_url = payload.url.trim().trim_end_matches('/');
    if !is_http_url(raw_url) {
        return Json(json!({
            "status": "offline",
            "message": "Only http:// or https:// endpoint URLs can be probed."
        }));
    }

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

pub async fn save_node_endpoint(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<NodeSavePayload>,
) -> impl IntoResponse {
    let tier_digits: String = payload.tier.chars().filter(|c| c.is_ascii_digit()).collect();
    let prefix = match tier_digits.as_str() {
        "0" => "TIER0",
        "1" => "TIER1",
        "2" => "TIER2",
        "3" => "TIER3",
        _ => return bad_request("tier must be 0, 1, 2 or 3"),
    };
    let url = payload.url.trim().trim_end_matches('/');
    if !is_http_url(url) {
        return bad_request("url must be http(s)://host[:port][/path] with no quotes, spaces or shell characters");
    }
    for (label, val) in [("name", &payload.name), ("model", &payload.model), ("hardware", &payload.hardware)] {
        if let Some(v) = val {
            if !v.trim().is_empty() && !valid_label(v) {
                return bad_request(&format!("{} may only contain letters, digits, spaces and . _ : / @ ( ) + - (max 128)", label));
            }
        }
    }
    if let Some(ctx) = payload.context {
        if !(512..=4_194_304).contains(&ctx) {
            return bad_request("context must be between 512 and 4194304");
        }
    }
    if let Some(ref jump) = payload.jump_box {
        if !jump.trim().is_empty() && !valid_jump_host(jump) {
            return bad_request("jump host must look like user@host or host[:port]");
        }
    }
    if let Some(ref target) = payload.ssh_target {
        if !target.trim().is_empty() && !valid_jump_host(target) {
            return bad_request("ssh_target must look like user@host or host[:port]");
        }
    }
    if let Some(ref mode) = payload.node_mode {
        if !mode.trim().is_empty() && !valid_node_mode(mode) {
            return bad_request("node_mode must be inference, worker, or hybrid");
        }
    }

    let conf_file = state.george_dir.join("endpoints.conf");
    let mut content = fs::read_to_string(&conf_file).await.unwrap_or_default();
    content = update_conf_line_str(&content, &format!("{}_URL", prefix), &format!("\"{}\"", url));
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
        let max_tok = (ctx as f64 * 0.90) as u32;
        let compact_tok = (ctx as f64 * 0.75) as u32;
        content = update_conf_line_str(&content, &format!("{}_MAX_TOKENS", prefix), &max_tok.to_string());
        content = update_conf_line_str(&content, &format!("{}_COMPACT_TOKENS", prefix), &compact_tok.to_string());
    }
    if let Some(en) = payload.enabled {
        content = update_conf_line_str(&content, &format!("{}_ENABLED", prefix), if en { "1" } else { "0" });
    }
    let _ = fs::write(&conf_file, content).await;

    let remote_conf = state.george_dir.join("remote.conf");
    let mut r_content = fs::read_to_string(&remote_conf).await.unwrap_or_default();
    let mut remote_changed = false;
    if let Some(ref jump) = payload.jump_box {
        if !jump.trim().is_empty() {
            r_content = update_conf_line_str(&r_content, "REMOTE_JUMP_HOST", jump.trim());
            remote_changed = true;
        }
    }
    if let Some(ref target) = payload.ssh_target {
        if !target.trim().is_empty() {
            r_content = update_conf_line_str(&r_content, "REMOTE_SSH_TARGET", target.trim());
            remote_changed = true;
        }
    }
    if let Some(ref mode) = payload.node_mode {
        if !mode.trim().is_empty() {
            r_content = update_conf_line_str(&r_content, "REMOTE_NODE_MODE", mode.trim());
            remote_changed = true;
        }
    }
    if remote_changed {
        let _ = fs::write(&remote_conf, r_content).await;
    }

    (StatusCode::OK, Json(json!({ "status": "ok", "prefix": prefix })))
}

/// Dynamically probes a remote SSH node (hardware, GPUs, GGUFs, LoRA adapters, worker status)
/// using `remote_discover_node` with zero static assumptions.
pub async fn discover_remote_node(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<DiscoverNodePayload>>,
) -> impl IntoResponse {
    let p = payload.map(|Json(v)| v).unwrap_or_default();
    let mut target_arg = String::new();
    let mut jump_arg = String::new();

    if let Some(ref t) = p.ssh_target {
        let t = t.trim();
        if !t.is_empty() {
            if !valid_jump_host(t) {
                return bad_request("Invalid ssh_target format");
            }
            target_arg = t.to_string();
        }
    }
    if let Some(ref j) = p.jump_host {
        let j = j.trim();
        if !j.is_empty() {
            if !valid_jump_host(j) {
                return bad_request("Invalid jump_host format");
            }
            jump_arg = j.to_string();
        }
    }

    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg("source \"$LODGE_DIR/lib/sys/remote.sh\" && _remote_load_config && remote_discover_node \"$1\" \"$2\"")
        .arg("_")
        .arg(&target_arg)
        .arg(&jump_arg)
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(stdout.trim()) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse remote node discovery output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "status": "error", "message": e.to_string() })),
        ),
    }
}

/// Dynamically switches the active GGUF model & optional LoRA adapter on the remote node
/// and updates `endpoints.conf` automatically.
pub async fn switch_remote_model(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SwitchModelPayload>,
) -> impl IntoResponse {
    let model = payload.model.trim();
    if !valid_label(model) {
        return bad_request("Invalid model identifier or path");
    }
    let lora = payload.lora.as_deref().unwrap_or("").trim();
    if !lora.is_empty() && !valid_label(lora) {
        return bad_request("Invalid lora identifier or path");
    }
    let ctx = payload.context.unwrap_or(12288);
    if !(512..=131_072).contains(&ctx) {
        return bad_request("context must be between 512 and 131072");
    }
    let parallel = payload.parallel.unwrap_or(1);
    if !(1..=16).contains(&parallel) {
        return bad_request("parallel slots must be between 1 and 16");
    }

    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg("source \"$LODGE_DIR/lib/core/endpoints.sh\" && source \"$LODGE_DIR/lib/sys/remote.sh\" && _remote_load_config && remote_switch_model \"$1\" \"$2\" \"$3\" \"$4\"")
        .arg("_")
        .arg(model)
        .arg(lora)
        .arg(ctx.to_string())
        .arg(parallel.to_string())
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            let ok = o.status.success();
            let state_file = state.george_dir.join("remote-node-state.json");
            let state_json = fs::read_to_string(&state_file)
                .await
                .ok()
                .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
            (
                if ok { StatusCode::OK } else { StatusCode::INTERNAL_SERVER_ERROR },
                Json(json!({
                    "status": if ok { "ok" } else { "error" },
                    "output": format!("{}{}", stdout, stderr),
                    "node_state": state_json,
                })),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "status": "error", "message": e.to_string() })),
        ),
    }
}

/// Enrolls a remote SSH node in `inference`, `worker`, or `hybrid` mode via `swarm_enroll_remote`.
pub async fn enroll_remote_node(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<EnrollNodePayload>,
) -> impl IntoResponse {
    let target = payload.ssh_target.as_deref().unwrap_or("").trim();
    if !target.is_empty() && !valid_jump_host(target) {
        return bad_request("Invalid ssh_target");
    }
    let jump = payload.jump_host.as_deref().unwrap_or("").trim();
    if !jump.is_empty() && !valid_jump_host(jump) {
        return bad_request("Invalid jump_host");
    }
    let name = payload.node_name.as_deref().unwrap_or("").trim();
    if !name.is_empty() && !valid_label(name) {
        return bad_request("Invalid node_name");
    }
    let mode = payload.mode.as_deref().unwrap_or("hybrid").trim();
    if !valid_node_mode(mode) {
        return bad_request("mode must be inference, worker, or hybrid");
    }
    let tier: String = payload.tier.as_deref().unwrap_or("2").chars().filter(|c| c.is_ascii_digit()).collect();
    let tier = if matches!(tier.as_str(), "0" | "1" | "2" | "3") { tier } else { "2".to_string() };

    let out = tokio::process::Command::new("bash")
        .arg("-c")
        .arg("source \"$LODGE_DIR/lib/core/endpoints.sh\" && source \"$LODGE_DIR/lib/sys/remote.sh\" && source \"$LODGE_DIR/lib/agents/swarm.sh\" && _remote_load_config && swarm_enroll_remote \"$1\" \"$2\" \"$3\" \"$4\" \"$5\"")
        .arg("_")
        .arg(target)
        .arg(jump)
        .arg(name)
        .arg(mode)
        .arg(&tier)
        .env("LODGE_DIR", &state.lodge_dir)
        .env("GEORGE_DIR", &state.george_dir)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match out {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout).to_string();
            let stderr = String::from_utf8_lossy(&o.stderr).to_string();
            let ok = o.status.success();
            (
                if ok { StatusCode::OK } else { StatusCode::INTERNAL_SERVER_ERROR },
                Json(json!({
                    "status": if ok { "ok" } else { "error" },
                    "output": format!("{}{}", stdout, stderr),
                })),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "status": "error", "message": e.to_string() })),
        ),
    }
}

/// Returns the live Swarm registry (`nodes.json`) and FIFO flow-control channel states.
pub async fn get_swarm_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let reg_path = state.george_dir.join("swarm").join("nodes.json");
    let nodes: serde_json::Value = fs::read_to_string(&reg_path)
        .await
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!([]));

    let remote_state_path = state.george_dir.join("remote-node-state.json");
    let remote_state: serde_json::Value = fs::read_to_string(&remote_state_path)
        .await
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!(null));

    let mut channels = Vec::new();
    let chan_dir = state.george_dir.join("ipc").join("channels");
    if let Ok(mut entries) = fs::read_dir(&chan_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let st_path = entry.path().join("state.json");
            if let Ok(raw) = fs::read_to_string(&st_path).await {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(&raw) {
                    channels.push(val);
                }
            }
        }
    }

    Json(json!({
        "status": "ok",
        "nodes": nodes,
        "fifo_channels": channels,
        "remote_state": remote_state,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_reject_shell_metacharacters() {
        assert!(valid_label("cuda-dual rtx3060 (24GB)"));
        assert!(!valid_label("x\"; rm -rf ~; \""));
        assert!(!valid_label("$(id)"));
        assert!(!valid_label("a`b`"));
        assert!(!valid_label(&"a".repeat(129)));
    }

    #[test]
    fn jump_hosts() {
        assert!(valid_jump_host("operator@192.0.2.10"));
        assert!(valid_jump_host("bastion.lan:2222"));
        assert!(!valid_jump_host("-oProxyCommand=sh"));
        assert!(!valid_jump_host("a@b c"));
        assert!(!valid_jump_host("a@$(id)"));
    }

    #[test]
    fn urls() {
        assert!(is_http_url("http://127.0.0.1:8080"));
        assert!(is_http_url("https://mac-m5.local:8080/v1"));
        assert!(!is_http_url("file:///etc/passwd"));
        assert!(!is_http_url("http://x\"; id; \""));
        assert!(!is_http_url("http://$(id)"));
        assert!(!is_http_url("gopher://x"));
    }
}
